import Foundation
import Darwin
@preconcurrency import NetworkExtension

nonisolated struct RecoveryRequest: Codable, Sendable {
    var id = UUID()
    var enabled = false
    var failure: ProtectionFailure?
}

// App and provider both edit VPN preferences; the file lease serializes those transactions.
@MainActor
struct RecoveryPreferences {
    enum Change { case prepare, arm, disarm }
    let url: URL
    let apply: (Change) async throws -> Void

    init(url: URL, apply: @escaping (Change) async throws -> Void = Self.applyLive) {
        self.url = url
        self.apply = apply
    }

    static func live() throws -> Self {
        Self(url: try ProtectionConfiguration.containerURL().appendingPathComponent("recovery.json"))
    }

    nonisolated static func read(_ url: URL) throws -> RecoveryRequest {
        guard FileManager.default.fileExists(atPath: url.path) else { return RecoveryRequest() }
        return try JSONDecoder().decode(RecoveryRequest.self, from: Data(contentsOf: url))
    }

    nonisolated static func isEnabled(_ id: UUID) -> Bool {
        guard let directory = try? ProtectionConfiguration.containerURL(),
              let request = try? read(directory.appendingPathComponent("recovery.json")) else { return false }
        return request.id == id && request.enabled
    }

    func prepare() async throws -> RecoveryRequest {
        try await transaction {
            try await apply(.prepare)
            let request = RecoveryRequest(enabled: true)
            try write(request)
            return request
        }
    }

    func arm(_ id: UUID) async throws {
        try await transaction {
            let request = try Self.read(url)
            guard request.id == id, request.enabled else { throw CancellationError() }
            // Verify the signed provider can persist its own settings before enabling On Demand.
            try await apply(.disarm)
            do { try await apply(.arm) }
            catch {
                try? await apply(.disarm)
                throw error
            }
        }
    }

    func disarm(expectedID: UUID? = nil, failure: ProtectionFailure? = nil) async throws {
        try await transaction {
            let current = try Self.read(url)
            if let expectedID, current.id != expectedID { return }
            // Persist the veto first, so even a preference-save failure cannot revive filtering.
            try write(RecoveryRequest(failure: failure))
            try await apply(.disarm)
        }
    }

    private func write(_ request: RecoveryRequest) throws {
        try JSONEncoder().encode(request).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func transaction<T>(_ body: () async throws -> T) async throws -> T {
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        var acquired = false
        for _ in 0..<100 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw CocoaError(.fileWriteUnknown) }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard acquired else { throw CocoaError(.fileLocking) }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try await body()
    }

    static func ownedManager() async throws -> NETunnelProviderManager? {
        let owned = try await NETunnelProviderManager.loadAllFromPreferences().filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == ProtectionConfiguration.providerBundleIdentifier
        }
        return owned.first(where: {
            [.connected, .connecting, .reasserting, .disconnecting].contains($0.connection.status)
        }) ?? owned.first
    }

    private static func applyLive(_ change: Change) async throws {
        guard let manager = try await ownedManager() else { throw CocoaError(.fileNoSuchFile) }
        if change == .prepare { manager.isEnabled = true }
        let enabled = change == .arm
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        manager.onDemandRules = change == .disarm ? [] : [rule]
        manager.isOnDemandEnabled = enabled
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        guard manager.isOnDemandEnabled == enabled,
              !enabled || manager.onDemandRules?.count == 1 else { throw CocoaError(.featureUnsupported) }
    }
}
