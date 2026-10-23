import Testing
@testable import Umbra

// Uses the OS resolver, unlike the offline filtering-engine tests.
@Suite("System resolver diagnostic", .timeLimit(.minutes(1)))
struct SystemDNSProbeTests {
    @Test(arguments: [false, true])
    @MainActor func negativeAnswerIsReportedRatherThanTimingOut(ipv6: Bool) async {
        let result = await SystemDNSProbe().resolve("umbra-diagnostic.invalid.", ipv6: ipv6)
        #expect(result == "No address (not independently attributed)")
    }
}
