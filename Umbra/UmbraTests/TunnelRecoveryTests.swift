import Foundation
import Synchronization
import Testing
@testable import Umbra

struct TunnelRecoveryTests {
    @Test func physicalInterfaceAddressesAreNumericAndUnknownInterfacesAreEmpty() {
        #expect(PhysicalNetworkIdentity.addresses(interface: "lo0").contains("127.0.0.1"))
        #expect(PhysicalNetworkIdentity.addresses(interface: "umbra-no-such-interface").isEmpty)
    }
    @Test func pathLossAndReturnInvalidateOlderAttempts() {
        var recovery = TunnelRecovery()
        recovery.begin()
        let wifi = TunnelRecovery.Path(interface: "wifi", ipv6: true, revision: 1)

        let initialPathChanged = recovery.updatePath(wifi)
        #expect(initialPathChanged)
        let firstToken = recovery.generation
        let firstAttemptBecameRunning = recovery.running(firstToken)
        #expect(firstAttemptBecameRunning)
        #expect(recovery.phase == .running)
        let duplicatePathChanged = recovery.updatePath(wifi)
        #expect(!duplicatePathChanged)

        let revisedWifi = TunnelRecovery.Path(interface: "wifi", ipv6: true, revision: 2)
        let revisionChanged = recovery.updatePath(revisedWifi)
        #expect(revisionChanged)
        #expect(recovery.phase == .recovering)
        #expect(recovery.path == revisedWifi)
        #expect(recovery.generation != firstToken)
        let staleAttemptBecameRunning = recovery.running(firstToken)
        #expect(!staleAttemptBecameRunning)
        let revisedAttemptBecameRunning = recovery.running(recovery.generation)
        #expect(revisedAttemptBecameRunning)

        let revisedToken = recovery.generation
        let pathWasLost = recovery.updatePath(nil)
        #expect(pathWasLost)
        #expect(recovery.phase == .waiting)
        let pathLossAttemptBecameRunning = recovery.running(revisedToken)
        #expect(!pathLossAttemptBecameRunning)
        let pathReturned = recovery.updatePath(wifi)
        #expect(pathReturned)
        #expect(recovery.phase == .recovering)
    }

    @Test func retriesBackOffAndThenExhaust() {
        var recovery = TunnelRecovery()
        recovery.begin()
        let pathChanged = recovery.updatePath(.init(interface: "wifi", ipv6: false, revision: 1))
        #expect(pathChanged)

        let firstRetry = recovery.retry()
        let secondRetry = recovery.retry()
        let thirdRetry = recovery.retry()
        #expect(firstRetry == 1)
        #expect(secondRetry == 2)
        #expect(thirdRetry == 4)
        #expect(recovery.retries == 3)
        let exhaustedRetry = recovery.retry()
        #expect(exhaustedRetry == nil)
        #expect(recovery.phase == .failed)
        let retryAfterFailure = recovery.retry()
        #expect(retryAfterFailure == nil)
    }

    private var failedLookup: DNSRequestVerdict {
        DNSRequestVerdict(blockingReason: 0, ownedFilterMatched: false, isException: false,
                          responseStatus: "SERVFAIL", failed: true)
    }

    private var permittedLookup: DNSRequestVerdict {
        DNSRequestVerdict(blockingReason: 0, ownedFilterMatched: false, isException: false,
                          responseStatus: "NOERROR", failed: false)
    }

    private func runningRecovery() -> TunnelRecovery {
        var recovery = TunnelRecovery()
        recovery.begin(now: 0)
        _ = recovery.updatePath(.init(interface: "wifi", ipv6: true, revision: 1), now: 0)
        _ = recovery.running(recovery.generation, now: 0)
        return recovery
    }

    @Test func isolatedFailuresDoNotRebuildAndExpiredFailuresDoNotAccumulate() {
        var recovery = runningRecovery()
        let token = recovery.generation
        let first = recovery.observe(failedLookup, freshSuccess: false, token: token, now: 1)
        let second = recovery.observe(failedLookup, freshSuccess: false, token: token, now: 32)
        #expect(!first && !second)
        #expect(recovery.phase == .running)
        #expect(recovery.generation == token)
        #expect(recovery.health == .degraded)
        #expect(recovery.diagnostic(at: 32).recentFailures == 1)
        #expect(recovery.diagnostic(at: 63).recentFailures == 0)
    }

    @Test func alternatingSuccessesAndFailuresStillReachTheThreshold() {
        var recovery = runningRecovery()
        let token = recovery.generation
        for time in [1.0, 10.0] {
            let failed = recovery.observe(failedLookup, freshSuccess: false, token: token, now: time)
            let succeeded = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: time + 1)
            #expect(!failed && !succeeded)
        }
        let threshold = recovery.observe(failedLookup, freshSuccess: false, token: token, now: 31)
        #expect(threshold) // The 30-second boundary is included.
        #expect(recovery.diagnostic(at: 31).recentFailures == 3)
    }

    @Test func intermittentSuccessCannotKeepResettingRecoveryRetries() {
        var recovery = runningRecovery()
        var now = 1.0
        for expected in [1, 2, 4] {
            let token = recovery.generation
            for _ in 0..<2 {
                _ = recovery.observe(failedLookup, freshSuccess: false, token: token, now: now)
                _ = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: now + 1)
                now += 2
            }
            let threshold = recovery.observe(failedLookup, freshSuccess: false, token: token, now: now)
            #expect(threshold)
            let delay = recovery.retry(now: now)
            #expect(delay == expected)
            now += Double(expected)
            _ = recovery.running(recovery.generation, now: now)
            _ = recovery.observe(permittedLookup, freshSuccess: true, token: recovery.generation, now: now)
        }
        let exhausted = recovery.retry(now: now)
        #expect(exhausted == nil)
        #expect(recovery.phase == .failed)
    }

    @Test func onlyQualifiedFreshHealthResetsTheBudget() {
        var recovery = runningRecovery()
        let oldToken = recovery.generation
        _ = recovery.retry(now: 1)
        let token = recovery.generation
        _ = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: 2) // Not running.
        _ = recovery.running(token, now: 3)
        _ = recovery.observe(permittedLookup, freshSuccess: true, token: oldToken, now: 3) // Stale.
        _ = recovery.observe(permittedLookup, freshSuccess: false, token: token, now: 100) // Cache.
        let denial = DNSRequestVerdict(blockingReason: 4, ownedFilterMatched: true,
                                      isException: false, responseStatus: "NXDOMAIN", failed: false)
        _ = recovery.observe(denial, freshSuccess: true, token: token, now: 100)
        #expect(recovery.retries == 1)
        #expect(recovery.diagnostic(at: 100).freshSuccesses == 0)
        _ = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: 101)
        _ = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: 160)
        #expect(recovery.retries == 1)
        _ = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: 161)
        #expect(recovery.retries == 0)
    }

    @Test func failureRestartsTheHealthyObservationInterval() {
        var recovery = runningRecovery()
        _ = recovery.retry(now: 0)
        let token = recovery.generation
        _ = recovery.running(token, now: 1)
        _ = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: 2)
        _ = recovery.observe(failedLookup, freshSuccess: false, token: token, now: 61)
        _ = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: 62)
        #expect(recovery.retries == 1)
        _ = recovery.observe(permittedLookup, freshSuccess: true, token: token, now: 122)
        #expect(recovery.retries == 0)
    }

    @Test func pathChangesPreserveBudgetButExplicitEnableStartsFresh() {
        var recovery = runningRecovery()
        _ = recovery.retry(now: 1)
        let oldToken = recovery.generation
        _ = recovery.updatePath(nil, now: 2)
        _ = recovery.updatePath(.init(interface: "cellular", ipv6: true, revision: 3), now: 3)
        #expect(recovery.retries == 1)
        #expect(recovery.health == .unverified)
        let stale = recovery.observe(failedLookup, freshSuccess: false, token: oldToken, now: 4)
        #expect(!stale)
        #expect(recovery.diagnostic(at: 4).totalFailures == 0)
        recovery.begin(now: 5)
        #expect(recovery.retries == 0)
    }

    @Test func malformedRequestsDoNotAffectHealthAndStopRejectsLateResults() {
        var recovery = runningRecovery()
        let token = recovery.generation
        var malformed = failedLookup
        malformed.hasQuestion = false
        for time in 0..<5 {
            let retry = recovery.observe(malformed, freshSuccess: false, token: token, now: Double(time))
            #expect(!retry)
        }
        #expect(recovery.health == .unverified)
        recovery.stop()
        _ = recovery.observe(failedLookup, freshSuccess: false, token: token, now: 6)
        #expect(recovery.diagnostic(at: 6).totalFailures == 0)
    }

    @Test func setupFinishesWithoutTrafficAndReportsTheSlowStep() {
        var recovery = TunnelRecovery()
        recovery.begin(now: 0)
        _ = recovery.updatePath(.init(interface: "cellular", ipv6: true, revision: 2), now: 1)
        recovery.markStep(.buildingEngine, now: 2)
        recovery.markStep(.applyingSettings, now: 3)
        let waiting = recovery.diagnostic(at: 40)
        #expect(waiting.step == .applyingSettings)
        #expect(waiting.stepSeconds == 37)
        recovery.markStep(.attachingListener, now: 41)
        let finished = recovery.running(recovery.generation, now: 42)
        #expect(finished)
        let report = recovery.diagnostic(at: 45)
        #expect(report.health == .unverified)
        #expect(report.slowestStep == .applyingSettings)
        #expect(report.slowestStepSeconds == 38)
        #expect(report.freshSuccesses == 0)
    }

    @Test func stopInvalidatesPathAndRetryCallbacks() {
        var recovery = TunnelRecovery()
        recovery.begin()
        let pathChanged = recovery.updatePath(.init(interface: "wifi", ipv6: true, revision: 9))
        #expect(pathChanged)
        let retryDelay = recovery.retry()
        #expect(retryDelay == 1)
        let pendingRetryToken = recovery.generation

        recovery.stop()

        #expect(recovery.phase == .stopped)
        #expect(recovery.path == nil)
        let staleRetryBecameRunning = recovery.running(pendingRetryToken)
        #expect(!staleRetryBecameRunning)
        let pathAfterStopChanged = recovery.updatePath(.init(interface: "wifi", ipv6: true, revision: 10))
        #expect(!pathAfterStopChanged)
        let retryAfterStop = recovery.retry()
        #expect(retryAfterStop == nil)
    }

    @Test func settingsQueueKeepsOneWriteInFlightAndLetsStopReplacePendingUpdates() async {
        let queue = DispatchQueue(label: "Umbra.TunnelSettingsQueueTests")
        let setter = ControlledSettingsSetter()
        let results = SettingsCompletionLog()
        let settings = TunnelSettingsQueue(queue: queue) { configured, completion in
            setter.start(configured, completion: completion)
        }

        await perform(on: queue) {
            settings.set(true) { results.record("stale apply", error: $0) }
            settings.set(true) { results.record("superseded", error: $0) }
            settings.set(false) { results.record("stop", error: $0) }
        }
        #expect(setter.calls == [true])
        #expect(setter.maximumInFlight == 1)
        #expect(results.values.map(\.label) == ["superseded"])
        #expect(results.values[0].wasCancelled)

        setter.completeNext()
        await perform(on: queue) {}
        #expect(setter.calls == [true, false])
        #expect(setter.maximumInFlight == 1)
        #expect(results.values.map(\.label) == ["superseded", "stale apply"])
        #expect(!results.values[1].hadError)

        setter.completeNext()
        await perform(on: queue) {}
        #expect(results.values.map(\.label) == ["superseded", "stale apply", "stop"])
        #expect(!results.values[2].hadError)
    }
}

private final class ControlledSettingsSetter: Sendable {
    typealias Completion = TunnelSettingsQueue.Completion

    private struct State: Sendable {
        var calls: [Bool] = []
        var active = 0
        var maximumInFlight = 0
        var completions: [Completion] = []
    }

    private let state = Mutex(State())

    var calls: [Bool] { state.withLock { $0.calls } }
    var maximumInFlight: Int { state.withLock { $0.maximumInFlight } }

    func start(_ configured: Bool, completion: @escaping Completion) {
        state.withLock {
            $0.calls.append(configured)
            $0.active += 1
            $0.maximumInFlight = max($0.maximumInFlight, $0.active)
            $0.completions.append(completion)
        }
    }

    func completeNext(_ error: Error? = nil) {
        let completion = state.withLock { state -> Completion? in
            guard !state.completions.isEmpty else { return nil }
            state.active -= 1
            return state.completions.removeFirst()
        }
        completion?(error)
    }
}

private final class SettingsCompletionLog: Sendable {
    struct Value: Sendable {
        let label: String
        let wasCancelled: Bool
        let hadError: Bool
    }

    private let valuesStorage = Mutex<[Value]>([])
    var values: [Value] { valuesStorage.withLock { $0 } }

    func record(_ label: String, error: Error?) {
        valuesStorage.withLock {
            $0.append(Value(label: label, wasCancelled: error is CancellationError, hadError: error != nil))
        }
    }
}

private func perform(on queue: DispatchQueue, _ operation: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async {
            operation()
            continuation.resume()
        }
    }
}
