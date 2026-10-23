import Foundation
import Synchronization
import CryptoKit
import Darwin
import Network
import Testing
@preconcurrency import AGDnsProxy
@testable import Umbra

private final class RequestTally: Sendable {
    let value = Mutex(0)
}

// This harness never installs networking settings or contacts a public resolver.
@MainActor
private final class EngineHarness {
    let proxy: AGDnsProxy
    let denials = RequestTally()
    let upstreamFailures = RequestTally()
    let upstreamBytesSent = RequestTally()

    init(filterFile: URL? = nil, memoryLimit: UInt = 4 * 1_024 * 1_024, upstreamAddress: String = "tls://127.0.0.1:9", upstreamTimeoutMs: UInt = 50) throws {
        AGDnsLogger.setCallback { @Sendable _, _, _ in }
        let config = AGDnsProxyConfig.getDefault()!
        let upstream = AGDnsUpstream()
        upstream.address = upstreamAddress
        upstream.bootstrap = []
        upstream.outboundInterfaceName = "lo0"
        config.upstreams = [upstream]
        config.upstreamTimeoutMs = upstreamTimeoutMs
        config.enableServfailOnUpstreamsFailure = true
        config.fallbacks = []
        config.fallbackDomains = []
        config.detectSearchDomains = false
        config.enableFallbackOnUpstreamsFailure = false
        config.enableRetransmissionHandling = false
        config.listeners = []
        config.dnsCacheSize = 256
        config.blockIpv6 = false
        config.ipv6Available = true
        config.hostsRulesBlockingMode = .init(rawValue: 1)!
        config.adblockRulesBlockingMode = .init(rawValue: 1)!
        config.filtersMemoryLimitBytes = memoryLimit
        let filter = AGDnsFilterParams()
        filter.id = 1
        filter.data = filterFile?.path ?? "0.0.0.0 blocked.example\n192.0.2.8 allowed.example\n"
        filter.inMemory = filterFile == nil
        config.filters = [filter]
        let events = AGDnsProxyEvents()
        let denials = denials
        let upstreamFailures = upstreamFailures
        let upstreamBytesSent = upstreamBytesSent
        events.onRequestProcessed = { @Sendable event in
            guard let event else { return }
            let verdict = DNSRequestVerdict(
                blockingReason: event.blockingReason,
                ownedFilterMatched: event.filterListIds?.contains(1) == true,
                isException: event.whitelist,
                responseStatus: event.status ?? "",
                failed: !(event.error ?? "").isEmpty,
                hasQuestion: !(event.domain ?? "").isEmpty && !(event.type ?? "").isEmpty
            )
            if verdict.isLocalDenial { denials.value.withLock { $0 += 1 } }
            if verdict.isUpstreamFailure { upstreamFailures.value.withLock { $0 += 1 } }
            upstreamBytesSent.value.withLock { $0 += max(0, event.bytesSent) }
        }
        var error: NSError?
        let proxy = AGDnsProxy(config: config, handler: events, error: &error)
        if let error { proxy?.stop(); throw error }
        self.proxy = try #require(proxy)
    }

    func process(_ query: Data, info: AGDnsMessageInfo? = nil) async -> Data? {
        await withCheckedContinuation { continuation in
            proxy.handleMessage(query, with: info) { @Sendable reply in
                continuation.resume(returning: reply)
            }
        }
    }

    func stop() { proxy.stop() }

    func drainEvents() async {
        proxy.stop()
        _ = await process(Data())
    }
}

private func bundledBlocklist() throws -> URL {
    let plugIns = try #require(Bundle.main.builtInPlugInsURL)
    let extensionBundle = try #require(Bundle(url: plugIns.appendingPathComponent("UmbraTunnel.appex")))
    try #require(extensionBundle.bundleIdentifier == ProtectionConfiguration.providerBundleIdentifier)
    return try #require(extensionBundle.url(forResource: "blocked-hosts", withExtension: "txt"))
}

private func candidateBlocklist() throws -> URL {
    try #require(Bundle(for: TestBundleMarker.self).url(forResource: "hagezi-pro-mini", withExtension: "txt"))
}

private final class TestBundleMarker: NSObject {}

private func baselineBlocklist() throws -> URL {
    try #require(Bundle(for: TestBundleMarker.self).url(forResource: "steven-black-baseline", withExtension: "txt"))
}

private struct BenchmarkCases: Decodable {
    struct Case: Decodable {
        let domain: String
        let baselineBlocked: Bool
        let candidateBlocked: Bool
    }
    let cases: [Case]
}

private func footprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    try #require(result == KERN_SUCCESS)
    return info.phys_footprint
}

@MainActor
private func resourceSample(_ file: URL, label: String) throws {
    let before = try footprint()
    let start = ContinuousClock.now
    let engine = try EngineHarness(filterFile: file)
    defer { engine.stop() }
    let elapsed = start.duration(to: .now)
    let after = try footprint()
    // Test-host samples, not extension peak RAM or a battery measurement.
    print("UMBRA_FILTER_SAMPLE \(label) init=\(elapsed) before=\(before) after=\(after) delta=\(Int64(after) - Int64(before)) limit=4194304")
}

private func query(_ name: String, type: UInt16 = 1, id: UInt16 = 42) -> Data {
    var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
    for label in name.split(separator: ".") {
        bytes.append(UInt8(label.utf8.count))
        bytes.append(contentsOf: label.utf8)
    }
    bytes.append(contentsOf: [0, UInt8(type >> 8), UInt8(type & 255), 0, 1])
    return Data(bytes)
}

@Suite("Offline DnsLibs evaluation", .timeLimit(.minutes(1)))
struct DNSFilteringEngineTests {
    @Test(arguments: [false, true])
    @MainActor func transportMetadataControlsUDPSizeIncludingCachedReplies(tcpFirst: Bool) async throws {
        let upstream = try LargeReplyFixture()
        let port = try await upstream.start()
        defer { upstream.stop() }
        let engine = try EngineHarness(upstreamAddress: "127.0.0.1:\(port.rawValue)", upstreamTimeoutMs: 1_000)
        defer { engine.stop() }
        // Seed the native cache through the UDP-only fixture before comparing client protocols.
        let seedInfo = AGDnsMessageInfo()
        seedInfo.isTcp = false
        seedInfo.transparent = false
        let seed = DNSProbePacket.query(host: "large.umbra.test", type: 16, id: 41, ednsPayloadSize: 4096)
        let full = try #require(await engine.process(seed, info: seedInfo))
        try #require(full.count > 1232 && full[3] & 15 == 0)
        let transports: [Bool?] = tcpFirst ? [true, false, nil] : [nil, false, true]
        for payload: UInt16? in [nil, 512, 1232] {
            let request = DNSProbePacket.query(host: "large.umbra.test", type: 16, id: 42, ednsPayloadSize: payload)
            for transport in transports {
                let info = transport.map { tcp in
                    let info = AGDnsMessageInfo()
                    info.isTcp = tcp
                    info.transparent = false
                    return info
                }
                let response = try #require(await engine.process(request, info: info))
                try #require(response.count >= 12)
                #expect(response[3] & 15 == 0)
                if transport == false {
                    #expect(response.count <= Int(payload ?? 512))
                    #expect(response[2] & 2 != 0)
                } else {
                    // Characterize the current nil-info defect, while preserving full TCP replies.
                    #expect(response.count > 1232)
                    #expect(response[2] & 2 == 0)
                }
            }
        }
        await engine.drainEvents()
        #expect(engine.denials.value.withLock { $0 } == 0)
        #expect(engine.upstreamFailures.value.withLock { $0 } == 0)
    }

    @Test @MainActor func candidateIsPinnedAndEveryRuleIsValid() throws {
        let data = try Data(contentsOf: candidateBlocklist())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "bce3daf388f70464947fbb06c8255f589b6d935ec7b7b1a78d0d2da94a3cb247")
        let rules = try #require(String(data: data, encoding: .utf8)).split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("!") && !$0.hasPrefix("[") }
        #expect(rules.count == 80_303)
        for rule in rules {
            try #require(AGDnsProxy.isValidRule(String(rule)), "Invalid published rule")
        }
    }

    @Test @MainActor func baselineResourceSample() throws {
        try resourceSample(baselineBlocklist(), label: "StevenBlack-baseline")
    }

    @Test @MainActor func candidateResourceSample() throws {
        try resourceSample(candidateBlocklist(), label: "HaGeZi-Pro-mini")
    }

    @Test @MainActor func partialCandidateLoadIsRejected() throws {
        do {
            _ = try EngineHarness(filterFile: candidateBlocklist(), memoryLimit: 1_024)
            Issue.record("Partial filter loading must be rejected")
        } catch let error as NSError {
            #expect(error.domain == AGDnsProxyErrorDomain)
            #expect(error.code == AGDnsProxyInitError.AGDPE_MEM_LIMIT_REACHED.rawValue)
        }
    }

    @Test(arguments: [false, true])
    @MainActor func benchmarkDomainsMatchNativeEngine(candidate: Bool) async throws {
        let fixture = try #require(Bundle(for: TestBundleMarker.self).url(forResource: "benchmark-domain-cases", withExtension: "json"))
        let cases = try JSONDecoder().decode(BenchmarkCases.self, from: Data(contentsOf: fixture)).cases
        try #require(cases.count == 478)
        let engine = try EngineHarness(filterFile: candidate ? candidateBlocklist() : baselineBlocklist())
        defer { engine.stop() }
        var expectedDenials = 0
        for item in cases {
            let blocked = candidate ? item.candidateBlocked : item.baselineBlocked
            let response = try #require(await engine.process(query(item.domain)))
            try #require(response.count >= 12)
            #expect(response[3] & 0x0f == (blocked ? 3 : 2), "Native result differs for \(item.domain)")
            if blocked { expectedDenials += 1 }
        }
        await engine.drainEvents()
        #expect(expectedDenials == (candidate ? 378 : 40))
        #expect(engine.denials.value.withLock { $0 } == expectedDenials)
        #expect(engine.upstreamFailures.value.withLock { $0 } == 478 - expectedDenials)
        print("UMBRA_BENCHMARK \(candidate ? "HaGeZi-Pro-mini" : "StevenBlack-baseline") denied=\(expectedDenials)/478; offline engine fixture, not website score")
    }

    @Test(arguments: ["pagead2.googlesyndication.com", "googleads.g.doubleclick.net",
                      "auction.unityads.unity3d.com", "umbra-probe.googlesyndication.com",
                      "telemetry.001-studio.com", "3cdn.net", "zzzperform.com"],
          [UInt16(1), UInt16(28), UInt16(65)])
    @MainActor func candidateDeniesAdsSubdomainsAndListAnchors(domain: String, type: UInt16) async throws {
        let engine = try EngineHarness(filterFile: candidateBlocklist())
        defer { engine.stop() }
        let response = try #require(await engine.process(query(domain, type: type)))
        try #require(response.count >= 12)
        #expect(response[3] & 0x0f == 3)
        await engine.drainEvents()
        #expect(engine.denials.value.withLock { $0 } == 1)
        #expect(engine.upstreamBytesSent.value.withLock { $0 } == 0)
    }

    @Test @MainActor func candidatePreservesControlsAndCountsRepeatedDenials() async throws {
        let engine = try EngineHarness(filterFile: candidateBlocklist())
        defer { engine.stop() }
        for host in ["example.com", "apple.com", "icloud.com", "apps.apple.com", "itunes.apple.com"] {
            for type: UInt16 in [1, 28, 65] {
                let response = try #require(await engine.process(query(host, type: type)))
                try #require(response.count >= 12)
                #expect(response[3] & 0x0f == 2) // Offline upstream reached, not local denial.
            }
        }
        for id: UInt16 in [1, 2, 3] {
            _ = await engine.process(query("pagead2.googlesyndication.com", id: id))
        }
        await engine.drainEvents()
        #expect(engine.denials.value.withLock { $0 } == 3)
        #expect(engine.upstreamFailures.value.withLock { $0 } == 15)
    }

    @Test(arguments: ["ads30.adcolony.com", "d.applovin.com", "rt.applovin.com"],
          [UInt16(1), UInt16(28), UInt16(65)])
    @MainActor func bundledBlocklistDeniesGameAdDomains(domain: String, type: UInt16) async throws {
        let engine = try EngineHarness(filterFile: bundledBlocklist())
        defer { engine.stop() }
        let response = try #require(await engine.process(query(domain, type: type)))
        try #require(response.count >= 12)
        #expect(response[0] == 0 && response[1] == 42)
        #expect(response[2] & 0x80 != 0)
        #expect(response[3] & 0x0f == 3)
        await engine.drainEvents()
        #expect(engine.denials.value.withLock { $0 } == 1)
        #expect(engine.upstreamFailures.value.withLock { $0 } == 0)
        #expect(engine.upstreamBytesSent.value.withLock { $0 } == 0)
    }

    @Test(arguments: [UInt16(1), UInt16(28), UInt16(65)])
    @MainActor func bundledBlocklistLeavesUnlistedControlToUpstream(type: UInt16) async throws {
        let engine = try EngineHarness(filterFile: bundledBlocklist())
        defer { engine.stop() }
        let response = try #require(await engine.process(query("umbra-unlisted-control.example", type: type)))
        try #require(response.count >= 12)
        #expect(response[3] & 0x0f == 2)
        await engine.drainEvents()
        #expect(engine.denials.value.withLock { $0 } == 0)
        #expect(engine.upstreamFailures.value.withLock { $0 } == 1)
    }

    @Test(arguments: [UInt16(1), UInt16(28), UInt16(65)])
    @MainActor func localDenials(type: UInt16) async throws {
        let engine = try EngineHarness()
        defer { engine.stop() }
        let response = try #require(await engine.process(query("BlOcKeD.example.", type: type)))
        #expect(response.count >= 12)
        #expect(response[0] == 0 && response[1] == 42)
        #expect(response[2] & 0x80 != 0)
        #expect(response[3] & 0x0f == 3)
    }

    @Test @MainActor func localRewriteIsNotDenial() async throws {
        let engine = try EngineHarness()
        defer { engine.stop() }
        let response = try #require(await engine.process(query("allowed.example")))
        #expect(response[3] & 0x0f == 0)
        #expect(response.suffix(4) == Data([192, 0, 2, 8]))
        #expect(engine.denials.value.withLock { $0 } == 0)
    }

    @Test @MainActor func repeatedRequestsHaveSeparateDenials() async throws {
        let engine = try EngineHarness()
        defer { engine.stop() }
        for id: UInt16 in [1, 2, 3] {
            let response = try #require(await engine.process(query("blocked.example", id: id)))
            #expect(response[3] & 0x0f == 3)
        }
        await engine.drainEvents()
        #expect(engine.denials.value.withLock { $0 } == 3)
    }

    @Test @MainActor func upstreamFailureIsNotDenial() async throws {
        let engine = try EngineHarness()
        defer { engine.stop() }
        let response = try #require(await engine.process(query("permitted.example")))
        #expect(response[3] & 0x0f == 2)
        #expect(engine.denials.value.withLock { $0 } == 0)
    }

    @Test @MainActor func builtInResolverDiscoveryDenialsCount() async throws {
        let engine = try EngineHarness()
        defer { engine.stop() }
        let mozilla = try #require(await engine.process(query("use-application-dns.net")))
        let ddr = try #require(await engine.process(query("_dns.resolver.arpa", type: 64)))
        #expect(mozilla[3] & 0x0f == 3)
        #expect(ddr[3] & 0x0f == 0)
        await engine.drainEvents()
        #expect(engine.denials.value.withLock { $0 } == 2)
    }

    @Test(arguments: [
        Data(), Data([0]), Data(repeating: 0, count: 11), Data([0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Data([0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xc0, 0x0c, 0, 1, 0, 1]),
        Data([0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 63, 97])
    ])
    @MainActor func malformedInputIsNotCounted(message: Data) async throws {
        let engine = try EngineHarness()
        defer { engine.stop() }
        _ = await engine.process(message)
        #expect(engine.denials.value.withLock { $0 } == 0)
    }
}


// Test-only, loopback-only fixed response source. No public resolver or general DNS server.
@MainActor
private final class LargeReplyFixture {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<NWEndpoint.Port, Error>?
    private var deadline: Task<Void, Never>?
    private let question = DNSProbePacket.query(host: "large.umbra.test", type: 16, id: 0)
    private var response: Data

    init() throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        response = question
        response[2] = 0x81
        response[3] = 0x80
        response[7] = 8
        for index in 0..<8 {
            response.append(contentsOf: [0xc0, 0x0c, 0, 16, 0, 1, 0, 0, 0, 60, 0, 221, 220])
            response.append(Data(repeating: UInt8(65 + index), count: 220))
        }
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener.port { self.finishStart(.success(port)) }
                    case .failed(let error): self.finishStart(.failure(error))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection)
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.finishStart(.failure(CocoaError(.fileReadUnknown)))
            }
            listener.start(queue: .main)
        }
    }

    private func finishStart(_ result: Result<NWEndpoint.Port, Error>) {
        guard let ready else { return }
        self.ready = nil
        deadline?.cancel()
        deadline = nil
        ready.resume(with: result)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, error == nil, let data, data.count >= self.question.count,
                      data[12..<self.question.count] == self.question[12...] else { return }
                var reply = self.response
                reply[0] = data[0]
                reply[1] = data[1]
                connection.send(content: reply, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in
                        if error == nil { self?.receive(connection) }
                    }
                })
            }
        }
    }

    func stop() {
        deadline?.cancel()
        deadline = nil
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}
