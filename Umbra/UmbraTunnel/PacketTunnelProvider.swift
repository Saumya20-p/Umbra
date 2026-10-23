import Foundation
import Network
@preconcurrency import NetworkExtension
@preconcurrency import AGDnsProxy

// The native API permits replies from any thread; lock access and consume its block once.
private final class DNSReply: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: AGDnsTunListenerReplyHandler?

    init(_ callback: @escaping AGDnsTunListenerReplyHandler) {
        self.callback = callback
    }

    func send(_ response: Data?) {
        lock.withLock {
            callback?(response)
            callback = nil
        }
    }
}

// Mutable lifecycle state is confined to queue; native callbacks enqueue immutable verdicts only.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Umbra.tunnel")
    private var monitor: NWPathMonitor?
    private var proxy: AGDnsProxy?
    private var listener: AGDnsTunListener?
    private var serializedFlow: SerializedPacketFlow?
    private var counter: DailyCounterStore?
    private var snapshot = ProtectionSnapshot()
    private var startCompletion: (@Sendable (Error?) -> Void)?
    private var recovery = TunnelRecovery()
    private var generation: UUID { recovery.generation }
    private var lastPathSignature: String?
    private var pathRevision: UInt64 = 0
    private var requestID: UUID?
    private var retryWork: DispatchWorkItem?
    private var automaticArmStarted = false
    private lazy var settingsWriter = TunnelSettingsQueue(queue: queue) { [weak self] configured, completion in
        guard let self else { completion(CancellationError()); return }
        self.setTunnelNetworkSettings(configured ? Self.networkSettings() : nil, completionHandler: completion)
    }
    private var stopCompletion: (@Sendable () -> Void)?
    private var diagnostics = TunnelDiagnostics()
    private var shutdown = TunnelShutdown()
    #if DEBUG
    private var validation = TunnelValidation()
    #endif

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping @Sendable (Error?) -> Void) {
        #if DEBUG
        let unavailable = (options?[TunnelValidation.upstreamOption] as? NSNumber)?.boolValue == true
        #endif
        queue.async { [self] in
            #if DEBUG
            validation = TunnelValidation(upstreamUnavailable: unavailable)
            #endif
            recovery.begin()
            snapshot = ProtectionSnapshot(phase: .starting)
            automaticArmStarted = false
            requestID = nil
            lastPathSignature = nil
            pathRevision = 0
            diagnostics = TunnelDiagnostics()
            startCompletion = completionHandler
            do {
                let request = try RecoveryPreferences.read(ProtectionConfiguration.containerURL().appendingPathComponent("recovery.json"))
                requestID = request.id
                guard request.enabled else { fail(.preferences); return }
                counter = try DailyCounterStore(url: ProtectionConfiguration.counterURL())
                try saveStatus()
            } catch {
                fail(.storage)
                return
            }
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self, weak monitor] path in
                self?.queue.async { [weak self, weak monitor] in
                    guard let self, let monitor, self.monitor === monitor else { return }
                    self.pathChanged(path)
                }
            }
            monitor.start(queue: queue)
        }
    }

    private func pathChanged(_ path: NWPath) {
        guard recovery.phase != .stopped, recovery.phase != .failed, !shutdown.pending else { return }
        guard requested() else { fail(.preferences); return }
        let usable = path.status == .satisfied
            ? path.availableInterfaces.first(where: { path.usesInterfaceType($0.type) }) : nil
        // Exclude our own DNS settings from identity, or clear/apply can cause a rebuild loop.
        let signature = usable.map { interface in
            [interface.name, String(interface.index), String(path.supportsIPv4), String(path.supportsIPv6),
             String(path.isExpensive), String(path.isConstrained),
             path.gateways.map(\.debugDescription).sorted().joined(separator: ","),
             PhysicalNetworkIdentity.addresses(interface: interface.name).joined(separator: ",")].joined(separator: "|")
        }
        if signature == lastPathSignature, pathRevision > 0 { return }
        lastPathSignature = signature
        pathRevision &+= 1
        let next = usable.map { TunnelRecovery.Path(interface: $0.name, ipv6: path.supportsIPv6, revision: pathRevision) }
        diagnostics.physicalIPv4 = path.status == .satisfied ? path.supportsIPv4 : nil
        diagnostics.physicalIPv6 = path.status == .satisfied ? path.supportsIPv6 : nil
        diagnostics.selectedUpstreamFamily = usable == nil ? nil : (path.supportsIPv6 ? "IPv6" : "IPv4")
        let changed = recovery.updatePath(next)
        guard changed || (next == nil && startCompletion != nil) else { return }
        retryWork?.cancel()
        retryWork = nil
        stopEngine()
        snapshot.phase = recovery.phase
        snapshot.failure = nil
        snapshot.verifiedLocalDenial = false
        reasserting = startCompletion == nil
        let token = generation
        do { try saveStatus() } catch { fail(.storage); return }
        settingsWriter.set(false) { [weak self] error in
            guard let self, self.generation == token, !self.shutdown.pending else { return }
            guard error == nil else { self.fail(.setup); return }
            if next == nil {
                self.finishInitialStart()
                self.reasserting = true
            } else { self.attemptRecovery(token: token) }
        }
    }

    private func requested() -> Bool {
        requestID.map { RecoveryPreferences.isEnabled($0) } ?? false
    }

    private func attemptRecovery(token: UUID) {
        guard generation == token, recovery.phase == .recovering, !shutdown.pending,
              let path = recovery.path else { return }
        guard requested() else { fail(.preferences); return }
        recovery.markStep(.buildingEngine)
        do { try configureProxy(interface: path.interface, ipv6: path.ipv6) }
        catch { fail(.engine); return }
        recovery.markStep(.applyingSettings)
        settingsWriter.set(true) { [weak self] error in
            guard let self, self.generation == token, !self.shutdown.pending else { return }
            guard self.requested() else { self.fail(.preferences); return }
            guard error == nil else { self.retryRecovery(.setup); return }
            do {
                self.recovery.markStep(.attachingListener)
                try self.attachListener(token: token)
                guard self.recovery.running(token) else { return }
                self.snapshot.phase = .running
                self.snapshot.failure = nil
                self.reasserting = false
                try self.saveStatus()
                self.finishInitialStart()
            } catch { self.fail(.engine) }
        }
    }

    private func retryRecovery(_ reason: ProtectionFailure) {
        guard !shutdown.pending, recovery.phase != .stopped, recovery.phase != .failed else { return }
        guard let delay = recovery.retry(reason: reason == .setup ? .settingsFailure : .requestFailures) else { fail(reason); return }
        stopEngine()
        snapshot.phase = .recovering
        snapshot.failure = reason
        snapshot.verifiedLocalDenial = false
        reasserting = startCompletion == nil
        let token = generation
        do { try saveStatus() } catch { fail(.storage); return }
        settingsWriter.set(false) { [weak self] error in
            guard let self, self.generation == token, !self.shutdown.pending else { return }
            guard error == nil else { self.fail(.setup); return }
            self.recovery.markStep(.backoff)
            let work = DispatchWorkItem { [weak self] in self?.attemptRecovery(token: token) }
            self.retryWork = work
            self.queue.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
        }
    }

    private func finishInitialStart() {
        let completion = startCompletion
        startCompletion = nil
        completion?(nil)
        guard !automaticArmStarted, let id = requestID else { return }
        automaticArmStarted = true
        Task { @MainActor [weak self] in
            let enabled: Bool?
            do { try await RecoveryPreferences.live().arm(id); enabled = true }
            catch { enabled = nil }
            self?.queue.async { [weak self] in
                guard let self, self.requestID == id, self.requested(),
                      !self.shutdown.pending, self.recovery.phase != .stopped, self.recovery.phase != .failed else { return }
                self.snapshot.automaticReconnect = enabled
                if enabled == nil { self.snapshot.failure = .preferences }
                try? self.saveStatus()
            }
        }
    }

    private func disarmAutomatic(_ reason: ProtectionFailure?) {
        // A provider that never read its request must not disable a newer host request.
        guard let id = requestID else { return }
        shutdown.preferenceWrites += 1
        Task { @MainActor [self] in
            let disabled: Bool
            do { try await RecoveryPreferences.live().disarm(expectedID: id, failure: reason); disabled = true }
            catch { disabled = false }
            self.queue.async { [self] in
                self.shutdown.preferenceWrites -= 1
                self.snapshot.automaticReconnect = disabled ? false : nil
                try? self.saveStatus()
                self.finishStopIfReady()
            }
        }
    }

    private func configureProxy(interface: String, ipv6: Bool) throws {
        AGDnsLogger.setCallback { @Sendable _, _, _ in }
        guard let list = Bundle.main.url(forResource: "blocked-hosts", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let settings = EngineConfiguration.make(interface: interface, ipv6: ipv6, filterURL: list)
        #if DEBUG
        if validation.upstreamUnavailable {
            let unavailable = AGDnsUpstream()
            unavailable.address = "tls://127.0.0.1:9"
            unavailable.bootstrap = []
            unavailable.outboundInterfaceName = "lo0"
            unavailable.id = 1
            settings.upstreams = [unavailable]
            diagnostics.selectedUpstreamFamily = "IPv4 (DEBUG loopback)"
        }
        #endif
        let events = AGDnsProxyEvents()
        let token = generation
        events.onRequestProcessed = { @Sendable [weak self] event in
            guard let event else { return }
            let verdict = DNSRequestVerdict(
                blockingReason: event.blockingReason,
                ownedFilterMatched: event.filterListIds?.contains(1) == true,
                isException: event.whitelist,
                responseStatus: event.status ?? "",
                failed: !(event.error ?? "").isEmpty,
                hasQuestion: !(event.domain ?? "").isEmpty && !(event.type ?? "").isEmpty
            )
            let date = Date(timeIntervalSince1970: (Double(event.startTime) + Double(event.elapsed)) / 1_000)
            let calendar = Calendar.current
            let upstreamBytes = max(0, event.bytesSent)
            let upstreamSucceeded = !event.cacheHit && event.upstreamId != nil && !verdict.failed
                && ["NOERROR", "NXDOMAIN"].contains(verdict.responseStatus)
            self?.queue.async { [weak self] in
                self?.diagnostics.upstreamBytesSent += upstreamBytes
                self?.processed(verdict, at: date, calendar: calendar, token: token, upstreamSucceeded: upstreamSucceeded)
            }
        }
        var error: NSError?
        let proxy = AGDnsProxy(config: settings, handler: events, error: &error)
        guard error == nil, let proxy else {
            proxy?.stop()
            throw CocoaError(.featureUnsupported)
        }
        self.proxy = proxy
    }

    private func attachListener(token: UUID) throws {
        let flow = SerializedPacketFlow(flow: packetFlow, queue: queue)
        serializedFlow = flow
        listener = try AGDnsTunListener(
            tunFd: nil, orTunnelFlow: flow, mtu: 1_500,
            transportMessageHandler: { @Sendable [weak self] request, isTcp, reply in
                let response = DNSReply(reply)
                self?.queue.async { [weak self] in
                    guard let self, self.generation == token, let proxy = self.proxy else {
                        response.send(nil)
                        return
                    }
                    let info = AGDnsMessageInfo()
                    info.isTcp = isTcp
                    info.transparent = false
                    self.diagnostics.received += 1
                    let callbackQueue = self.queue
                    proxy.handleMessage(request, with: info) { @Sendable data in
                        callbackQueue.async { response.send(data) }
                    }
                }
            }
        )
    }

    private func processed(_ verdict: DNSRequestVerdict, at date: Date, calendar: Calendar, token: UUID, upstreamSucceeded: Bool) {
        diagnostics.processed += 1
        // Old-generation denials still happened; persist them even after a path change/stop.
        if verdict.isLocalDenial, let counter {
            diagnostics.denied += 1
            if shutdown.counterWrites >= 128 { fail(.storage) }
            shutdown.counterWrites += 1
            // shortcut: abrupt termination can lose uncommitted verdicts; require durable engine delivery for crash-perfect totals.
            #if DEBUG
            let injectedFailure = validation.takeCounterWriteFailure()
            #endif
            Task {
                do {
                    #if DEBUG
                    if injectedFailure { throw CocoaError(.fileWriteUnknown) }
                    #endif
                    _ = try await counter.recordDenial(at: date, calendar: calendar)
                    queue.async { [self] in
                        shutdown.counterWrites -= 1
                        diagnostics.committed += 1
                        if generation == token { snapshot.verifiedLocalDenial = true }
                        finishStopIfReady()
                    }
                } catch {
                    queue.async { [self] in
                        shutdown.counterWrites -= 1
                        fail(.storage)
                        finishStopIfReady()
                    }
                }
            }
        }
        guard generation == token, snapshot.phase == .running else { return }
        snapshot.lastProcessedAt = date
        if recovery.observe(verdict, freshSuccess: upstreamSucceeded, token: token) {
            retryRecovery(.upstream)
        }
    }

    private func saveStatus() throws {
        let status = snapshot.persisted
        try JSONEncoder().encode(status).write(
            to: ProtectionConfiguration.snapshotURL(),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func stopEngine() {
        serializedFlow?.invalidate()
        listener?.stop()
        listener = nil
        serializedFlow = nil
        if let retiringProxy = proxy {
            shutdown.nativeDrains += 1
            retiringProxy.stop()
            // The native queue may still hold verdict callbacks queued during deinit.
            retiringProxy.handleMessage(Data(), with: nil) { @Sendable [self] _ in
                queue.async { [self] in
                    shutdown.nativeDrains -= 1
                    finishStopIfReady()
                }
            }
        }
        proxy = nil
    }

    private func fail(_ reason: ProtectionFailure) {
        guard snapshot.phase != .failed else { return }
        recovery.stop(failed: true)
        retryWork?.cancel()
        retryWork = nil
        snapshot.phase = .failed
        snapshot.failure = reason
        monitor?.cancel()
        monitor = nil
        lastPathSignature = nil
        stopEngine()
        try? saveStatus()
        reasserting = false
        disarmAutomatic(reason)
        if !shutdown.pending {
            shutdown.pending = true
            shutdown.settingsCleared = false
            clearNetworkSettings()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            recovery.stop()
            retryWork?.cancel()
            retryWork = nil
            stopCompletion = completionHandler
            shutdown.pending = true
            shutdown.settingsCleared = false
            monitor?.cancel()
            monitor = nil
            stopEngine()
            if snapshot.phase != .failed {
                snapshot.phase = .stopped
                snapshot.failure = nil
            }
            try? saveStatus()
            lastPathSignature = nil
            if [.userInitiated, .configurationDisabled, .configurationRemoved, .providerDisabled, .superceded].contains(reason) {
                disarmAutomatic(nil)
            }
            reasserting = false
            clearNetworkSettings()
        }
    }

    private func clearNetworkSettings() {
        let token = generation
        settingsWriter.set(false) { [self] error in
                guard generation == token, shutdown.pending else { return }
                if error != nil, snapshot.failure == nil {
                    snapshot.phase = .failed
                    snapshot.failure = .setup
                    try? saveStatus()
                }
                shutdown.settingsCleared = true
                finishStopIfReady()
        }
    }

    private func finishStopIfReady() {
        guard shutdown.finishIfReady() else { return }
        let completion = stopCompletion
        stopCompletion = nil
        let start = startCompletion
        startCompletion = nil
        let error = NSError(domain: "Umbra.Tunnel", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: snapshot.failure?.rawValue ?? "stopped"])
        start?(error)
        if let completion { completion() }
        else if start == nil, snapshot.phase == .failed { cancelTunnelWithError(error) }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: (@Sendable (Data?) -> Void)?) {
        #if DEBUG
        if messageData == TunnelValidation.counterCommand {
            queue.async { [self] in
                guard recovery.phase == .running, !shutdown.pending, requested(),
                      !validation.counterWriteArmed else { completionHandler?(nil); return }
                validation.counterWriteArmed = true
                completionHandler?(Data("armed".utf8))
            }
            return
        }
        #endif
        guard messageData == Data("snapshot".utf8), let completionHandler else {
            completionHandler?(nil)
            return
        }
        queue.async { [self] in
            var status = snapshot
            diagnostics.pending = shutdown.counterWrites
            diagnostics.recovery = recovery.diagnostic()
            status.diagnostics = diagnostics
            status.sampledAt = .now
            #if DEBUG
            status.validationMode = validation.label
            #endif
            let counter = counter
            Task {
                status.blockedToday = try? await counter?.total()
                completionHandler(try? JSONEncoder().encode(status))
            }
        }
    }

    private static func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        settings.mtu = 1_500
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "198.18.0.2", subnetMask: "255.255.255.255")]
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: ["fd75:6d62:7261::1"], networkPrefixLengths: [128])
        ipv6.includedRoutes = [NEIPv6Route(destinationAddress: "fd75:6d62:7261::2", networkPrefixLength: 128)]
        settings.ipv6Settings = ipv6
        let dns = NEDNSSettings(servers: ["198.18.0.2", "fd75:6d62:7261::2"])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        settings.dnsSettings = dns
        return settings
    }
}
