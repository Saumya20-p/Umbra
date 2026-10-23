import Foundation
import Observation
import NetworkExtension
import Synchronization
import Testing
@testable import Umbra

struct ProtectionControllerTests {
    @Test @MainActor func dailyRefreshRollsOverWithoutNewTrafficAndRetainsEarlierTotals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("daily.sqlite")
        let store = try DailyCounterStore(url: url)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let before = try #require(ISO8601DateFormatter().date(from: "2026-10-22T03:59:59Z"))
        let after = before.addingTimeInterval(1)
        _ = try await store.recordDenial(at: before, calendar: calendar)
        _ = try await store.recordDenial(at: before, calendar: calendar)
        let controller = ProtectionController(counterURL: url)

        await controller.refreshDailyTotal(at: before, calendar: calendar)
        #expect(controller.blockedToday == 2)
        await controller.refreshDailyTotal(at: after, calendar: calendar)
        #expect(controller.blockedToday == 0)
        #expect(controller.counterError == nil)

        let relaunched = ProtectionController(counterURL: url)
        await relaunched.refreshDailyTotal(at: after, calendar: calendar)
        #expect(relaunched.blockedToday == 0)
        await relaunched.refreshDailyTotal(at: before, calendar: calendar)
        #expect(relaunched.blockedToday == 2)
    }

    @Test @MainActor func timezoneRefreshSelectsExistingDayWithoutWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("daily.sqlite")
        let store = try DailyCounterStore(url: url)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-22T01:00:00Z"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var newYork = utc
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        _ = try await store.recordDenial(at: date, calendar: newYork)
        let controller = ProtectionController(counterURL: url)

        await controller.refreshDailyTotal(at: date, calendar: newYork)
        #expect(controller.blockedToday == 1)
        await controller.refreshDailyTotal(at: date, calendar: utc)
        #expect(controller.blockedToday == 0)
        await controller.refreshDailyTotal(at: date, calendar: newYork)
        #expect(controller.blockedToday == 1)
    }

    @Test @MainActor func missingCounterIsUnavailableAndCanRecoverAfterStorageReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("daily.sqlite")
        let controller = ProtectionController(counterURL: url)
        await controller.refreshDailyTotal()
        #expect(controller.blockedToday == nil)
        #expect(controller.counterError != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let store = try DailyCounterStore(url: url)
        let date = Date.now
        _ = try await store.recordDenial(at: date)
        await controller.refreshDailyTotal(at: date)
        #expect(controller.blockedToday == 1)
        #expect(controller.counterError == nil)
    }

    @Test @MainActor func lateAndMalformedRepliesCannotReplaceNewerLiveDiagnostics() throws {
        let controller = ProtectionController()
        let oldRequest = controller.beginSnapshotRequest()
        let newRequest = controller.beginSnapshotRequest()
        let running = try JSONEncoder().encode(ProtectionSnapshot(phase: .running, verifiedLocalDenial: true))
        let waiting = try JSONEncoder().encode(ProtectionSnapshot(phase: .waiting))
        controller.receiveSnapshot(running, request: newRequest, connectionStatus: .connected)
        controller.receiveSnapshot(waiting, request: oldRequest, connectionStatus: .connected)
        controller.receiveSnapshot(Data("invalid".utf8), request: newRequest, connectionStatus: .connected)
        controller.receiveSnapshot(nil, request: newRequest, connectionStatus: .connected)
        #expect(controller.hasLiveSnapshot)
        #expect(controller.snapshot?.phase == .running)
        #expect(controller.snapshot?.verifiedLocalDenial == true)
        #expect(controller.blockedToday == nil)
    }

    @Test @MainActor func refreshingMarksPreviousSamplesStaleWithoutTouchingTheCounter() throws {
        let controller = ProtectionController()
        let first = controller.beginSnapshotRequest()
        let sample = ProtectionSnapshot(phase: .recovering, sampledAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(sample)
        controller.receiveSnapshot(data, request: first, connectionStatus: .reasserting)
        #expect(controller.hasLiveSnapshot)
        #expect(controller.engineStatusText.hasPrefix("Provider:"))
        let second = controller.beginSnapshotRequest()
        #expect(!controller.hasLiveSnapshot)
        #expect(controller.engineStatusText.hasPrefix("Previous sample:"))
        controller.receiveSnapshot(data, request: first, connectionStatus: .connected)
        controller.receiveSnapshot(nil, request: second, connectionStatus: .connected)
        #expect(!controller.hasLiveSnapshot)
        #expect(controller.snapshot?.sampledAt == sample.sampledAt)
        #expect(controller.blockedToday == nil)
    }

    @Test @MainActor func disconnectOrDisableInvalidatesRepliesEvenIfConnectionHasReturned() throws {
        let controller = ProtectionController()
        let oldRequest = controller.beginSnapshotRequest()
        let data = try JSONEncoder().encode(ProtectionSnapshot(phase: .running))
        controller.invalidateLiveSnapshot()
        controller.receiveSnapshot(data, request: oldRequest, connectionStatus: .connected)
        #expect(!controller.hasLiveSnapshot)
        #expect(controller.snapshot == nil)

        let newRequest = controller.beginSnapshotRequest()
        controller.receiveSnapshot(data, request: newRequest, connectionStatus: .disconnected)
        #expect(!controller.hasLiveSnapshot)
        controller.receiveSnapshot(data, request: newRequest, connectionStatus: .reasserting)
        #expect(controller.hasLiveSnapshot)
    }

    @Test @MainActor func notificationsWithoutAnOwnedTransitionDoNotStartRefreshes() async throws {
        let controller = ProtectionController()
        let refreshed = Mutex(false)
        withObservationTracking {
            _ = controller.isRefreshing
        } onChange: {
            refreshed.withLock { $0 = true }
        }

        for _ in 0..<20 { controller.connectionDidChange() }
        // Allow incorrectly scheduled refresh tasks to run; this is a negative event check.
        try await Task.sleep(for: .milliseconds(100))

        #expect(!refreshed.withLock { $0 })
        #expect(!controller.isRefreshing)
    }
}
