import Foundation
import Network
import dnssd

// Fixed diagnostic requests only; this is not the production DNS implementation.
nonisolated enum DNSProbePacket {
    static let hosts = ["pagead2.googlesyndication.com", "googleads.g.doubleclick.net", "auction.unityads.unity3d.com", "example.com"]

    static func query(host: String, type: UInt16 = 1, id: UInt16,
                      ednsPayloadSize: UInt16? = nil, dnssecOK: Bool = false) -> Data {
        let labels = host.split(separator: ".")
        precondition(!labels.isEmpty && labels.allSatisfy { !$0.isEmpty && $0.utf8.count <= 63 }
                     && host.utf8.count < 254)
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in labels {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes += [0, UInt8(type >> 8), UInt8(type & 255), 0, 1]
        if let ednsPayloadSize {
            bytes[11] = 1
            bytes += [0, 0, 41, UInt8(ednsPayloadSize >> 8), UInt8(ednsPayloadSize & 255),
                      0, 0, dnssecOK ? 0x80 : 0, 0, 0, 0]
        }
        return Data(bytes)
    }

    static func describe(_ response: Data, for query: Data, includeReplySize: Bool = false) -> String {
        guard let metadata = replyMetadata(response, for: query) else {
            return "Invalid or mismatched DNS reply\(includeReplySize ? ", \(response.count) bytes" : "")"
        }
        let name = metadata.code == 3 ? "NXDOMAIN" : metadata.code == 0 ? "NOERROR" : "RCODE \(metadata.code)"
        return "\(name), \(metadata.answers) answers\(metadata.truncated ? ", truncated" : "")\(includeReplySize ? ", \(response.count) bytes" : "")"
    }

    static func replyMetadata(_ response: Data, for query: Data) -> (code: UInt8, answers: Int, truncated: Bool)? {
        let bytes = Array(response)
        let request = Array(query)
        guard request.count >= 12, request[4] == 0, request[5] == 1 else { return nil }
        // Compare only the question: a resolver need not echo the request's OPT record.
        var end = 12
        while end < request.count, request[end] != 0 {
            let length = Int(request[end])
            guard length <= 63, end + length + 1 < request.count else { return nil }
            end += length + 1
        }
        guard end < request.count, end + 5 <= request.count else { return nil }
        end += 5
        guard bytes.count >= end,
              bytes[0...1] == request[0...1], bytes[2] & 0xf8 == 0x80,
              bytes[4] == 0, bytes[5] == 1,
              bytes[12..<end] == request[12..<end] else { return nil }
        return (bytes[3] & 15, Int(bytes[6]) * 256 + Int(bytes[7]), bytes[2] & 2 != 0)
    }
}

// One DNS-over-TCP message; framing only, with no resource-record interpretation.
nonisolated struct DNSProbeTCPFrameDecoder {
    enum Output: Equatable {
        case waiting
        case reply(Data)
        case invalid
        case incomplete
    }

    private var buffer = Data()

    mutating func append(_ data: Data, complete: Bool) -> Output {
        buffer.append(data)
        if buffer.count >= 2 {
            let size = Int(buffer[0]) * 256 + Int(buffer[1])
            guard size >= 12 else { return .invalid }
            if buffer.count >= size + 2 { return .reply(Data(buffer[2..<(size + 2)])) }
        }
        return complete ? .incomplete : .waiting
    }
}

@MainActor
enum DNSPathProbe {
    static func run(tunnelRunning: Bool, shouldContinue: () -> Bool, report: (String) -> Void) async {
        for host in DNSProbePacket.hosts {
            guard shouldContinue() else { report("Stopped: tunnel state changed."); return }
            report("\(host) — \(host == "example.com" ? "permitted control" : "listed")")
            // Run system lookup first, so direct probes cannot seed its cache.
            for ipv6 in [false, true] {
                guard shouldContinue() else { report("Stopped: tunnel state changed."); return }
                let system = await SystemDNSProbe().resolve(host, ipv6: ipv6)
                report("System \(ipv6 ? "AAAA" : "A"): \(system)")
            }
            if tunnelRunning {
                for (server, family) in [("198.18.0.2", "IPv4"), ("fd75:6d62:7261::2", "IPv6")] {
                    guard shouldContinue() else { report("Stopped: tunnel state changed."); return }
                    for type in [UInt16(1), 28] {
                        guard shouldContinue() else { report("Stopped: tunnel state changed."); return }
                        let query = DNSProbePacket.query(host: host, type: type, id: UInt16.random(in: 0...UInt16.max))
                        let udp = await DirectDNSProbe().resolve(query, server: server, tcp: false)
                        report("Direct \(family) UDP \(type == 1 ? "A" : "AAAA"): \(udp)")
                        if host == DNSProbePacket.hosts[0] || host == "example.com" {
                            guard shouldContinue() else { report("Stopped: tunnel state changed."); return }
                            let tcp = await DirectDNSProbe().resolve(query, server: server, tcp: true)
                            report("Direct \(family) TCP \(type == 1 ? "A" : "AAAA"): \(tcp)")
                        }
                    }
                }
            }
        }
    }

    static func runExtended(shouldContinue: () -> Bool, report: (String) -> Void) async {
        report("org DNSKEY — permitted size/transport diagnostic; DNSSEC validation is not measured.")
        for (server, family) in [("198.18.0.2", "IPv4"), ("fd75:6d62:7261::2", "IPv6")] {
            for payload in [UInt16(512), 1232] {
                guard shouldContinue() else { report("Stopped: tunnel state changed."); return }
                let query = DNSProbePacket.query(host: "org", type: 48, id: UInt16.random(in: 0...UInt16.max),
                                                 ednsPayloadSize: payload, dnssecOK: true)
                let label = "Direct \(family) DNSKEY EDNS \(payload) DO"
                let probe = DirectDNSProbe()
                let udp = await probe.resolve(query, server: server, tcp: false, includeReplySize: true)
                report("\(label) UDP: \(udp)")
                if probe.truncated {
                    guard shouldContinue() else { report("Stopped: tunnel state changed."); return }
                    report("\(label): TC received; explicit TCP retry")
                    let retry = await DirectDNSProbe().resolve(query, server: server, tcp: true, includeReplySize: true)
                    report("\(label) TCP retry: \(retry)")
                }
                guard shouldContinue() else { report("Stopped: tunnel state changed."); return }
                let tcp = await DirectDNSProbe().resolve(query, server: server, tcp: true, includeReplySize: true)
                report("\(label) TCP comparison: \(tcp)")
            }
        }
    }
}

@MainActor
private final class DirectDNSProbe {
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<String, Never>?
    private var timeout: Task<Void, Never>?
    private var query = Data()
    private var decoder = DNSProbeTCPFrameDecoder()
    private var includeReplySize = false
    private(set) var truncated = false

    func resolve(_ query: Data, server: String, tcp: Bool, includeReplySize: Bool = false) async -> String {
        self.query = query
        self.includeReplySize = includeReplySize
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: tcp ? .tcp : .udp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.continuation != nil else { return }
                    switch state {
                    case .ready:
                        var message = query
                        if tcp { message = Data([UInt8(query.count >> 8), UInt8(query.count & 255)]) + query }
                        connection.send(content: message, completion: .contentProcessed { [weak self] error in
                            Task { @MainActor in
                                guard let self, self.continuation != nil else { return }
                                if error != nil { self.finish("Send failed") }
                                else { self.receive(tcp: tcp) }
                            }
                        })
                    case .failed: self.finish("Connection failed")
                    case .cancelled: self.finish("Cancelled")
                    default: break
                    }
                }
            }
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                self?.finish("Timed out — not proof of blocking")
            }
            connection.start(queue: .main)
        }
    }

    private func receive(tcp: Bool) {
        guard let connection, continuation != nil else { return }
        if tcp {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_537) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self, self.continuation != nil else { return }
                    switch self.decoder.append(data ?? Data(), complete: complete || error != nil) {
                    case .reply(let response): self.finishResponse(response)
                    case .invalid: self.finish("Invalid TCP DNS frame")
                    case .incomplete: self.finish("Incomplete TCP DNS reply")
                    case .waiting: self.receive(tcp: true)
                    }
                }
            }
        } else {
            connection.receiveMessage { [weak self] data, _, _, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let data, error == nil {
                        self.finishResponse(data)
                    } else { self.finish("No DNS reply") }
                }
            }
        }
    }

    private func finishResponse(_ response: Data) {
        truncated = DNSProbePacket.replyMetadata(response, for: query)?.truncated ?? false
        finish(DNSProbePacket.describe(response, for: query, includeReplySize: includeReplySize))
    }

    private func finish(_ result: String) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        continuation.resume(returning: result)
    }
}

@MainActor
final class SystemDNSProbe {
    private var service: DNSServiceRef?
    private var continuation: CheckedContinuation<String, Never>?
    private var timeout: Task<Void, Never>?

    func resolve(_ host: String, ipv6: Bool) async -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let error = DNSServiceGetAddrInfo(
                // Without this flag DNS-SD suppresses NXDOMAIN callbacks until our deadline.
                &service, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0,
                DNSServiceProtocol(ipv6 ? kDNSServiceProtocol_IPv6 : kDNSServiceProtocol_IPv4), host,
                { _, _, _, error, _, _, _, context in
                    guard let context else { return }
                    // DNSServiceSetDispatchQueue below guarantees this callback runs on main.
                    MainActor.assumeIsolated {
                        let probe = Unmanaged<SystemDNSProbe>.fromOpaque(context).takeUnretainedValue()
                        if error == kDNSServiceErr_NoSuchRecord { probe.finish("No address (not independently attributed)") }
                        else if error == kDNSServiceErr_NoError { probe.finish("Address resolved (may be cached)") }
                        else { probe.finish("Resolver error \(error) — not proof of blocking") }
                    }
                }, Unmanaged.passUnretained(self).toOpaque()
            )
            guard error == kDNSServiceErr_NoError, let service else {
                finish("Could not start resolver (\(error))")
                return
            }
            let scheduled = DNSServiceSetDispatchQueue(service, .main)
            guard scheduled == kDNSServiceErr_NoError else {
                finish("Could not schedule resolver (\(scheduled))")
                return
            }
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(6)) } catch { return }
                self?.finish("Timed out — not proof of blocking")
            }
        }
    }

    private func finish(_ result: String) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
        continuation.resume(returning: result)
    }
}
