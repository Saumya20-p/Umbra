import Foundation
import Testing
@testable import Umbra

struct DNSProbePacketTests {
    @Test func requestAndLocalDenialReply() {
        let query = DNSProbePacket.query(host: "d.applovin.com", id: 0xabcd)
        #expect(query.prefix(6) == Data([0xab, 0xcd, 1, 0, 0, 1]))
        #expect(query.suffix(5) == Data([0, 0, 1, 0, 1]))
        var response = query
        response[2] = 0x81
        response[3] = 0x83
        #expect(DNSProbePacket.describe(response, for: query) == "NXDOMAIN, 0 answers")
        response[2] |= 2
        #expect(DNSProbePacket.describe(response, for: query).contains("truncated"))
    }

    @Test func refusesMalformedOrUnrelatedReplies() {
        let query = DNSProbePacket.query(host: "d.applovin.com", id: 42)
        var response = query
        response[2] = 0x81
        for length in [0, 1, 11, query.count - 1] {
            #expect(DNSProbePacket.describe(Data(response.prefix(length)), for: query).hasPrefix("Invalid"))
        }
        for offset in [0, 1, 4, 5, 12, query.count - 1] {
            var changed = response
            changed[offset] ^= 1
            #expect(DNSProbePacket.describe(changed, for: query).hasPrefix("Invalid"))
        }
        #expect(DNSProbePacket.describe(query, for: query).hasPrefix("Invalid"))
        response[3] = 2
        #expect(DNSProbePacket.describe(response, for: query) == "RCODE 2, 0 answers")
    }

    @Test func aaaaQuestionAndReplyMustMatch() {
        let query = DNSProbePacket.query(host: "example.com", type: 28, id: 42)
        #expect(query.suffix(5) == Data([0, 0, 28, 0, 1]))
        var response = query
        response[2] = 0x81
        #expect(DNSProbePacket.describe(response, for: query) == "NOERROR, 0 answers")
        response[response.count - 3] = 1
        #expect(DNSProbePacket.describe(response, for: query).hasPrefix("Invalid"))
    }

    @Test(arguments: [UInt16(512), 1232])
    func ednsDNSKEYQuestionAndOptionalReplyOPT(payload: UInt16) {
        let query = DNSProbePacket.query(host: "org", type: 48, id: 42,
                                        ednsPayloadSize: payload, dnssecOK: true)
        #expect(query[10] == 0 && query[11] == 1)
        #expect(query.suffix(16) == Data([0, 0, 48, 0, 1, 0, 0, 41,
                                        UInt8(payload >> 8), UInt8(payload & 255), 0, 0, 0x80, 0, 0, 0]))
        var response = Data(query.dropLast(11))
        response[2] = 0x83
        response[11] = 0
        #expect(DNSProbePacket.describe(response, for: query, includeReplySize: true)
                == "NOERROR, 0 answers, truncated, \(response.count) bytes")
        #expect(DNSProbePacket.replyMetadata(response, for: query)?.truncated == true)
        response.append(contentsOf: [0, 0, 41, 4, 208, 0, 0, 0x80, 0, 0, 0])
        response[11] = 1
        #expect(DNSProbePacket.describe(response, for: query, includeReplySize: true)
                == "NOERROR, 0 answers, truncated, \(response.count) bytes")
        response[16] = 1
        #expect(DNSProbePacket.replyMetadata(response, for: query) == nil)
    }

    @Test func ednsWithoutDOLeavesFlagClear() {
        let query = DNSProbePacket.query(host: "org", type: 48, id: 42, ednsPayloadSize: 1232)
        #expect(query.suffix(6) == Data(repeating: 0, count: 6))
    }

    @Test func rejectsIncompleteOrMalformedQuestions() {
        for query in [Data(repeating: 0, count: 11),
                      Data([0, 42, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 64]),
                      Data([0, 42, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3, 111, 114, 103])] {
            #expect(DNSProbePacket.replyMetadata(query, for: query) == nil)
        }
    }

    @Test func tcpFrameHandlesSplitPrefixAndLargeSplitBody() {
        let query = DNSProbePacket.query(host: "org", type: 48, id: 42,
                                        ednsPayloadSize: 1232, dnssecOK: true)
        var response = Data(query.dropLast(11))
        response[2] = 0x81
        response[7] = 1
        response[11] = 0
        // Synthetic DNSKEY RDATA exercises framing size, not DNSSEC verification.
        response.append(contentsOf: [0xc0, 0x0c, 0, 48, 0, 1, 0, 0, 0, 60, 5, 0xe0, 1, 1, 3, 8])
        response.append(Data(repeating: 0xa5, count: 1500))
        #expect(response.count > 1232)
        let frame = Data([UInt8(response.count >> 8), UInt8(response.count & 255)]) + response
        var decoder = DNSProbeTCPFrameDecoder()
        #expect(decoder.append(Data(frame.prefix(1)), complete: false) == .waiting)
        #expect(decoder.append(Data(frame[1..<100]), complete: false) == .waiting)
        #expect(decoder.append(Data(frame[100..<900]), complete: false) == .waiting)
        #expect(decoder.append(Data(frame[900...]), complete: true) == .reply(response))
        #expect(DNSProbePacket.describe(response, for: query, includeReplySize: true)
                == "NOERROR, 1 answers, \(response.count) bytes")
    }

    @Test(arguments: [0, 1, 2, 10, 13])
    func tcpFrameRejectsEarlyClose(length: Int) {
        let frame = Data([0, 12]) + Data(repeating: 0, count: 12)
        var decoder = DNSProbeTCPFrameDecoder()
        #expect(decoder.append(Data(frame.prefix(length)), complete: true) == .incomplete)
    }

    @Test(arguments: [UInt8(0), 1, 11])
    func tcpFrameRejectsTooShortDeclaredSize(size: UInt8) {
        var decoder = DNSProbeTCPFrameDecoder()
        #expect(decoder.append(Data([0, size]), complete: false) == .invalid)
    }

    @Test func olderSavedSnapshotRemainsReadable() throws {
        let saved = Data(#"{"phase":"running","verifiedLocalDenial":false}"#.utf8)
        let snapshot = try JSONDecoder().decode(ProtectionSnapshot.self, from: saved)
        #expect(snapshot.phase == .running)
        #expect(snapshot.diagnostics == nil)
    }
}
