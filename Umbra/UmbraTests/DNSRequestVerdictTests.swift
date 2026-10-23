import Testing
@testable import Umbra

struct DNSRequestVerdictTests {
    @Test func emptyQuestionDecodeErrorDoesNotDisableFiltering() {
        let malformed = DNSRequestVerdict(blockingReason: 0, ownedFilterMatched: false,
            isException: false, responseStatus: "SERVFAIL", failed: true, hasQuestion: false)
        let upstream = DNSRequestVerdict(blockingReason: 0, ownedFilterMatched: false,
            isException: false, responseStatus: "SERVFAIL", failed: true, hasQuestion: true)
        #expect(!malformed.isUpstreamFailure)
        #expect(upstream.isUpstreamFailure)
    }
    @Test(arguments: [4, 5, 6, 7])
    func ownedRuleDenialsCount(reason: Int) {
        #expect(DNSRequestVerdict(blockingReason: reason, ownedFilterMatched: true,
            isException: false, responseStatus: "NXDOMAIN", failed: false).isLocalDenial)
    }

    @Test(arguments: [
        DNSRequestVerdict(blockingReason: 0, ownedFilterMatched: false, isException: false, responseStatus: "NXDOMAIN", failed: false),
        DNSRequestVerdict(blockingReason: 4, ownedFilterMatched: true, isException: true, responseStatus: "NOERROR", failed: false),
        DNSRequestVerdict(blockingReason: 4, ownedFilterMatched: true, isException: false, responseStatus: "NOERROR", failed: false),
        DNSRequestVerdict(blockingReason: 4, ownedFilterMatched: true, isException: false, responseStatus: "NXDOMAIN", failed: true),
        DNSRequestVerdict(blockingReason: 4, ownedFilterMatched: false, isException: false, responseStatus: "NXDOMAIN", failed: false),
        DNSRequestVerdict(blockingReason: 3, ownedFilterMatched: false, isException: false, responseStatus: "NOERROR", failed: false)
    ])
    func unrelatedEventsDoNotCount(verdict: DNSRequestVerdict) {
        #expect(!verdict.isLocalDenial)
    }
}
