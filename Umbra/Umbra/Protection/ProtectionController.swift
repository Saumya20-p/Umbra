import Foundation
import NetworkExtension
import Observation

@Observable
@MainActor
final class ProtectionController {
    static var requiresDevice: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private(set) var hasConfiguration = false
    private(set) var status: NEVPNStatus = .invalid
    private(set) var isBusy = false
    private(set) var isRefreshing = false
    private(set) var blockedToday: Int64?
    private(set) var snapshot: ProtectionSnapshot?
    private(set) var actionError: String?
    private(set) var diagnosticError: String?
    private(set) var counterError: String?
    private(set) var hasLiveSnapshot = false
    private(set) var automaticReconnect: Bool?
    private(set) var recoveryRequested = false
    private(set) var isProbing = false
    private(set) var probeReport = ""
    #if DEBUG
    private(set) var validationMessage: String?
    #endif
    private var manager: NETunnelProviderManager?
    private var snapshotRequest = UUID()
    private var counterRequest = UUID()
    private let counterURL: URL?

    init(counterURL: URL? = nil) {
        self.counterURL = counterURL
    }

    var canDisable: Bool {
        !isBusy && manager != nil && (recoveryRequested || automaticReconnect == true
            || [.connected, .connecting, .reasserting].contains(status))
    }

    var canEnable: Bool {
        !Self.requiresDevice && hasConfiguration && !isBusy && !isRefreshing && !isProbing
            && [.disconnected, .invalid].contains(status)
    }

    var statusText: String {
        if Self.requiresDevice { return "Device required" }
        switch status {
        case .invalid: return hasConfiguration ? "Unavailable" : "Not configured"
        case .disconnected: return "Off"
        case .connecting: return "Starting"
        case .connected, .reasserting:
            if hasLiveSnapshot, snapshot?.phase == .waiting { return "Waiting for network" }
            if hasLiveSnapshot, snapshot?.phase == .recovering { return "Recovering" }
            return status == .connected ? (hasLiveSnapshot ? "Running" : "Connected; engine unverified") : "Recovering"
        case .disconnecting: return "Stopping"
        @unknown default: return "Unavailable"
        }
    }

    var filteringDescription: String {
        if hasLiveSnapshot, [.connected, .reasserting].contains(status), snapshot?.phase == .waiting || snapshot?.phase == .recovering {
            return "Filtering is temporarily off while the network recovers. Ordinary system DNS may be used."
        }
        if status == .connected {
            if hasLiveSnapshot, snapshot?.diagnostics?.recovery?.health == .degraded {
                return "The engine is running, but recent upstream DNS requests failed."
            }
            if hasLiveSnapshot, snapshot?.verifiedLocalDenial == true {
                return "A local denial was observed. Coverage across apps and DNS paths remains unverified."
            }
            return "The tunnel is running. Filtering has not been independently verified."
        }
        return "This diagnostic build does not establish working protection."
    }

    var engineStatusText: String {
        guard let snapshot else { return "Unavailable" }
        let source = hasLiveSnapshot ? "Provider" : (snapshot.sampledAt == nil ? "Last saved" : "Previous sample")
        let sampled = snapshot.sampledAt.map { " at \($0.formatted(.dateTime.hour().minute().second()))" } ?? ""
        return "\(source): \(snapshot.phase.rawValue)\(sampled)"
    }

    var recoveryDetails: String? { snapshot?.diagnostics?.recovery?.summary }

    var failureDescription: String? {
        switch snapshot?.failure {
        case .setup: return "The experiment could not configure the tunnel."
        case .engine: return "The local filtering engine failed."
        case .storage: return "The daily counter could not be stored reliably. The saved total may be incomplete."
        case .upstream: return "Encrypted upstream resolution failed."
        case .network: return "The tunnel network failed."
        case .preferences: return "Automatic reconnection could not be verified. Filtering may work in this session, but automatic restart is unavailable or unverified."
        case nil: return nil
        }
    }

    func refresh() async {
        guard !isBusy, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard !Self.requiresDevice else { return }

        diagnosticError = nil
        do {
            manager = try await ownedManager()
            updateConnectionStatus()
        } catch {
            diagnosticError = "The VPN configuration could not be read. You can still disable a known active connection."
        }
        await readDiagnostics()
    }

    func install() async {
        guard !Self.requiresDevice, !isBusy, !isRefreshing else { return }
        isBusy = true
        actionError = nil
        do {
            let configuration: NETunnelProviderManager
            if let existing = try await ownedManager() {
                configuration = existing
            } else {
                configuration = NETunnelProviderManager()
                let tunnelProtocol = NETunnelProviderProtocol()
                tunnelProtocol.providerBundleIdentifier = ProtectionConfiguration.providerBundleIdentifier
                tunnelProtocol.serverAddress = "Local DNS experiment"
                configuration.protocolConfiguration = tunnelProtocol
                configuration.localizedDescription = "Umbra experiment"
            }
            configuration.isOnDemandEnabled = false
            configuration.onDemandRules = []
            configuration.isEnabled = true
            try await configuration.saveToPreferences()
            try await configuration.loadFromPreferences()
            manager = configuration
            updateConnectionStatus()
        } catch {
            actionError = "The experimental configuration could not be installed. Check signing and Network Extension entitlements on the device."
        }
        isBusy = false
        await refresh()
    }

    func enable() async {
        #if DEBUG
        validationMessage = nil
        #endif
        await start()
    }

    #if DEBUG
    func enableUnavailableUpstream() async {
        validationMessage = "DEBUG: intentionally unavailable encrypted upstream for this session. Generate a permitted lookup to exercise recovery."
        await start(options: [TunnelValidation.upstreamOption: NSNumber(value: true)])
    }

    func armCounterWriteFailure() async {
        guard !isBusy, !isRefreshing, !isProbing, status == .connected else { return }
        isBusy = true
        let reply = await providerReply(for: TunnelValidation.counterCommand)
        validationMessage = reply == Data("armed".utf8)
            ? "DEBUG: armed. Next actual local denial will fail persistence and stop filtering. Existing totals are preserved; this test intentionally leaves a denial uncommitted."
            : "Counter fault was not acknowledged. Refresh diagnostics before retrying."
        isBusy = false
        await refresh()
    }
    #endif

    private func start(options: [String: NSObject]? = nil) async {
        guard canEnable, let manager else { return }
        invalidateLiveSnapshot()
        isBusy = true
        actionError = nil
        do {
            _ = try await RecoveryPreferences.live().prepare()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel(options: options)
            updateConnectionStatus()
        } catch {
            actionError = "The experiment could not start. Check the device configuration and refresh diagnostics."
        }
        isBusy = false
        await refresh()
    }

    func disable() async {
        guard canDisable else { return }
        invalidateLiveSnapshot()
        isBusy = true
        actionError = nil
        do {
            try await RecoveryPreferences.live().disarm()
            automaticReconnect = false
            recoveryRequested = false
            manager?.connection.stopVPNTunnel()
        } catch {
            manager?.connection.stopVPNTunnel()
            actionError = "Automatic reconnection could not be disabled reliably. Turn off Connect On Demand in Settings → VPN; the experiment may otherwise try to reconnect."
        }
        isBusy = false
        await refresh()
    }

    func connectionDidChange() {
        // Preference reads can post notifications without a connection transition.
        guard let current = manager?.connection.status, current != status else { return }
        updateConnectionStatus()
        Task { await refresh() }
    }

    func runDNSProbe(extended: Bool = false) async {
        guard !Self.requiresDevice, !isProbing, !isBusy, !isRefreshing else { return }
        isProbing = true
        defer { isProbing = false }
        await refresh()
        let initialStatus = status
        if extended && initialStatus != .connected {
            probeReport = "Enable the experiment before running extended transport checks."
            return
        }
        guard [.connected, .disconnected, .invalid].contains(initialStatus) else {
            probeReport = "Wait until the tunnel finishes starting or stopping."
            return
        }
        probeReport = "DNS path check — \(Date.now.formatted())\nTunnel at start: \(statusText)\n"
        probeReport += "Engine build: 2.8.45-umbra-transport1 (UDP/TCP metadata repair).\n"
        if let list = try? BundledBlocklist.load() {
            probeReport += "Bundled candidate: \(list.name), revision \(list.revision). Restart after updating to activate it.\n"
        }
        let before = await liveProbeSnapshot()
        appendProbeSnapshot(before, label: "Before")
        if extended {
            probeReport += "Extended transport check: fixed org DNSKEY with DNSSEC requested. Actual response sizes vary.\n"
            await DNSPathProbe.runExtended(shouldContinue: {
                (self.manager?.connection.status ?? .invalid) == initialStatus
            }) { self.probeReport += "\n\($0)" }
        } else {
            await DNSPathProbe.run(tunnelRunning: initialStatus == .connected, shouldContinue: {
                (self.manager?.connection.status ?? .invalid) == initialStatus
            }) { self.probeReport += "\n\($0)" }
        }
        var after = await liveProbeSnapshot()
        // Allow already-observed denials to commit; never manufacture a count delta.
        for _ in 0..<5 {
            guard let pending = after?.diagnostics?.pending, pending > 0 else { break }
            try? await Task.sleep(for: .milliseconds(100))
            after = await liveProbeSnapshot()
        }
        appendProbeSnapshot(after, label: "After")
        if initialStatus != manager?.connection.status
            || (before?.diagnostics?.session != after?.diagnostics?.session) {
            probeReport += "\nTunnel changed or provider session restarted; do not compare these totals."
        }
        probeReport += "\nSession aggregates include other apps and resolver discovery. Daily totals and session metrics are sampled separately. NXDOMAIN/timeouts alone do not establish an Umbra denial."
        await refresh()
    }

    private func appendProbeSnapshot(_ snapshot: ProtectionSnapshot?, label: String) {
        guard let snapshot, let metrics = snapshot.diagnostics else {
            probeReport += "\n\(label): live provider diagnostics unavailable."
            return
        }
        probeReport += "\n\(label) session: \(metrics.session). Observed path capabilities IPv4: \(metrics.physicalIPv4.map(String.init) ?? "unknown"), IPv6: \(metrics.physicalIPv6.map(String.init) ?? "unknown"). Configured upstream family: \(metrics.selectedUpstreamFamily ?? "unknown") (not independent reachability proof)."
        if let validation = snapshot.validationMode { probeReport += "\n\(validation)" }
        probeReport += "\n\(label): received \(metrics.received), processed \(metrics.processed), locally denied \(metrics.denied), committed \(metrics.committed), pending writes \(metrics.pending)."
        probeReport += " Engine-reported upstream bytes sent: \(metrics.upstreamBytesSent)."
        if let sampled = snapshot.sampledAt { probeReport += " Sampled: \(sampled.formatted())." }
        if let recovery = metrics.recovery { probeReport += "\n\(label) recovery: \(recovery.summary)" }
        probeReport += "\nAutomatic reconnection preference: \(automaticReconnect.map { $0 ? "On" : "Off" } ?? "unverified"); provider arming report: \(snapshot.automaticReconnect.map { $0 ? "On" : "Off" } ?? "unverified")."
        if let total = snapshot.blockedToday { probeReport += " Daily total: \(total)." }
    }

    private func liveProbeSnapshot() async -> ProtectionSnapshot? {
        guard let data = await providerReply(for: Data("snapshot".utf8)) else { return nil }
        return try? JSONDecoder().decode(ProtectionSnapshot.self, from: data)
    }

    private func providerReply(for message: Data) async -> Data? {
        guard let status = manager?.connection.status, [.connected, .reasserting].contains(status),
              let session = manager?.connection as? NETunnelProviderSession else { return nil }
        let (stream, continuation) = AsyncStream<Data?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        do {
            try session.sendProviderMessage(message) { data in
                continuation.yield(data)
                continuation.finish()
            }
        } catch { return nil }
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                for await result in stream { return result }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func ownedManager() async throws -> NETunnelProviderManager? {
        try await RecoveryPreferences.ownedManager()
    }

    private func updateConnectionStatus() {
        hasConfiguration = manager != nil
        status = manager?.connection.status ?? .invalid
        automaticReconnect = manager?.isOnDemandEnabled
        if let preferences = try? RecoveryPreferences.live(), let request = try? RecoveryPreferences.read(preferences.url) {
            recoveryRequested = request.enabled
        }
        if status != .connected {
            invalidateLiveSnapshot()
        }
    }

    func refreshDailyTotal(at date: Date = .now, calendar: Calendar = .autoupdatingCurrent) async {
        guard !Self.requiresDevice || counterURL != nil else { return }
        let request = UUID()
        counterRequest = request
        do {
            let counter = try DailyCounterStore(url: counterURL ?? ProtectionConfiguration.counterURL(), readOnly: true)
            let total = try await counter.total(at: date, calendar: calendar)
            guard counterRequest == request else { return }
            blockedToday = total
            counterError = nil
        } catch {
            guard counterRequest == request else { return }
            blockedToday = nil
            counterError = "The daily counter is unavailable. No count is estimated."
        }
    }

    func invalidateLiveSnapshot() {
        hasLiveSnapshot = false
        snapshotRequest = UUID()
    }

    func beginSnapshotRequest() -> UUID {
        hasLiveSnapshot = false
        snapshotRequest = UUID()
        return snapshotRequest
    }

    func receiveSnapshot(_ data: Data?, request: UUID, connectionStatus: NEVPNStatus) {
        guard snapshotRequest == request, !isBusy,
              [.connected, .reasserting].contains(connectionStatus), let data,
              let reply = try? JSONDecoder().decode(ProtectionSnapshot.self, from: data) else { return }
        snapshot = reply
        hasLiveSnapshot = true
    }

    private func readDiagnostics() async {
        if snapshot == nil {
            snapshot = try? JSONDecoder().decode(
                ProtectionSnapshot.self,
                from: Data(contentsOf: ProtectionConfiguration.snapshotURL())
            )
        }
        await refreshDailyTotal()

        guard [.connected, .reasserting].contains(status) else { return }
        let request = beginSnapshotRequest()
        let data = await providerReply(for: Data("snapshot".utf8))
        guard snapshotRequest == request else { return }
        receiveSnapshot(data, request: request, connectionStatus: manager?.connection.status ?? .invalid)
        if !hasLiveSnapshot {
            diagnosticError = diagnosticError ?? "The provider did not return new live diagnostics within two seconds. The displayed sample may be stale."
        }
    }
}
