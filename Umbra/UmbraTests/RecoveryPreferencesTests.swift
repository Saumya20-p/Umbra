import Foundation
import Testing
@testable import Umbra

struct RecoveryPreferencesTests {
    @Test @MainActor func prepareStoresIntentWithoutArmingAutomaticConnection() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let backend = FakeRecoveryBackend()
        let preferences = RecoveryPreferences(url: url) { try await backend.apply($0) }

        let request = try await preferences.prepare()

        #expect(request.enabled)
        #expect(try RecoveryPreferences.read(url).id == request.id)
        #expect(try RecoveryPreferences.read(url).enabled)
        #expect(backend.changes == ["prepare"])
        #expect(!backend.onDemandEnabled)
    }

    @Test @MainActor func armDisarmsBeforeItEnablesAutomaticConnection() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let backend = FakeRecoveryBackend()
        let preferences = RecoveryPreferences(url: url) { try await backend.apply($0) }
        let request = try await preferences.prepare()

        try await preferences.arm(request.id)

        #expect(backend.changes == ["prepare", "disarm", "arm"])
        #expect(backend.onDemandEnabled)
    }

    @Test @MainActor func disarmPersistsItsVetoBeforeBackendFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let backend = FakeRecoveryBackend()
        let preferences = RecoveryPreferences(url: url) { try await backend.apply($0) }
        let original = try await preferences.prepare()
        var requestSeenByBackend: RecoveryRequest?
        backend.onDisarm = { requestSeenByBackend = try RecoveryPreferences.read(url) }
        backend.failDisarm = true

        await #expect(throws: RecoveryTestError.expected) {
            try await preferences.disarm(failure: .upstream)
        }

        let saved = try RecoveryPreferences.read(url)
        #expect(requestSeenByBackend?.enabled == false)
        #expect(requestSeenByBackend?.failure == .upstream)
        #expect(!saved.enabled)
        #expect(saved.failure == .upstream)
        #expect(saved.id != original.id)
    }

    @Test @MainActor func staleExpectedIDCannotDisarmANewerRequest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let backend = FakeRecoveryBackend()
        let preferences = RecoveryPreferences(url: url) { try await backend.apply($0) }
        let old = try await preferences.prepare()
        let current = try await preferences.prepare()

        try await preferences.disarm(expectedID: old.id, failure: .network)

        let saved = try RecoveryPreferences.read(url)
        #expect(saved.id == current.id)
        #expect(saved.enabled)
        #expect(saved.failure == nil)
        #expect(backend.changes == ["prepare", "prepare"])
    }

    @Test @MainActor func disableDuringAnInFlightArmWinsWhenArmFinishes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let backend = FakeRecoveryBackend()
        let disarmGate = ContinuationGate()
        backend.disarmGate = disarmGate
        let preferences = RecoveryPreferences(url: url) { try await backend.apply($0) }
        let request = try await preferences.prepare()

        let armTask = Task { @MainActor in try await preferences.arm(request.id) }
        await disarmGate.waitUntilEntered()
        let disableStarted = ContinuationSignal()
        let disableTask = Task { @MainActor in
            disableStarted.signal()
            try await preferences.disarm(expectedID: request.id)
        }
        await disableStarted.wait()

        disarmGate.release()
        try await armTask.value
        try await disableTask.value

        await #expect(throws: CancellationError.self) {
            try await preferences.arm(request.id)
        }
        #expect(backend.changes == ["prepare", "disarm", "arm", "disarm"])
        #expect(!backend.onDemandEnabled)
        let saved = try RecoveryPreferences.read(url)
        #expect(!saved.enabled)
    }

    @Test @MainActor func separateInstancesShareTheLeaseAcrossSuspendedApply() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery.json")
        let gate = ContinuationGate()
        let firstBackend = FakeRecoveryBackend()
        firstBackend.prepareGate = gate
        let secondBackend = FakeRecoveryBackend()
        let first = RecoveryPreferences(url: url) { try await firstBackend.apply($0) }
        let second = RecoveryPreferences(url: url) { try await secondBackend.apply($0) }

        let firstTask = Task { @MainActor in try await first.prepare() }
        await gate.waitUntilEntered()
        let secondStarted = ContinuationSignal()
        let secondTask = Task { @MainActor in
            secondStarted.signal()
            return try await second.prepare()
        }
        await secondStarted.wait()

        #expect(secondBackend.changes.isEmpty)
        gate.release()
        let firstRequest = try await firstTask.value
        let secondRequest = try await secondTask.value

        #expect(firstBackend.changes == ["prepare"])
        #expect(secondBackend.changes == ["prepare"])
        #expect(firstRequest.id != secondRequest.id)
        #expect(try RecoveryPreferences.read(url).id == secondRequest.id)
    }
}

@MainActor
private final class FakeRecoveryBackend {
    private(set) var changes: [String] = []
    private(set) var onDemandEnabled = false
    var failDisarm = false
    var onDisarm: (() throws -> Void)?
    var prepareGate: ContinuationGate?
    var disarmGate: ContinuationGate?
    private var didPauseOnDisarm = false

    func apply(_ change: RecoveryPreferences.Change) async throws {
        switch change {
        case .prepare:
            changes.append("prepare")
            onDemandEnabled = false
            if let prepareGate { await prepareGate.pause() }
        case .arm:
            changes.append("arm")
            onDemandEnabled = true
        case .disarm:
            changes.append("disarm")
            onDemandEnabled = false
            if let disarmGate, !didPauseOnDisarm {
                didPauseOnDisarm = true
                await disarmGate.pause()
            }
            try onDisarm?()
            if failDisarm { throw RecoveryTestError.expected }
        }
    }
}

@MainActor
private final class ContinuationGate {
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        let waiters = enteredContinuations
        enteredContinuations.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuations.append($0) }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class ContinuationSignal {
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private enum RecoveryTestError: Error {
    case expected
}

@MainActor
private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
