import Foundation

nonisolated enum ProtectionPhase: String, Codable, Sendable {
    case stopped, starting, running, waiting, recovering, failed
}

nonisolated enum ProtectionFailure: String, Codable, Sendable {
    case setup, engine, storage, upstream, network, preferences
}

nonisolated struct ProtectionSnapshot: Codable, Sendable {
    var phase: ProtectionPhase = .stopped
    var failure: ProtectionFailure?
    var blockedToday: Int64?
    var lastProcessedAt: Date?
    var verifiedLocalDenial = false
    var diagnostics: TunnelDiagnostics?
    var automaticReconnect: Bool?
    var validationMode: String?
    var sampledAt: Date?

    var persisted: Self {
        var saved = self
        saved.lastProcessedAt = nil
        saved.blockedToday = nil
        saved.diagnostics = nil
        saved.validationMode = nil
        saved.sampledAt = nil
        return saved
    }
}

// Session aggregates are returned live only; never retain per-request or domain records.
nonisolated struct TunnelDiagnostics: Codable, Sendable {
    var session = UUID()
    var received = 0
    var processed = 0
    var denied = 0
    var committed = 0
    var pending = 0
    var upstreamBytesSent = 0
    var physicalIPv4: Bool?
    var physicalIPv6: Bool?
    var selectedUpstreamFamily: String?
    var recovery: RecoveryDiagnostic?
}

nonisolated enum UpstreamHealth: String, Codable, Sendable { case unverified, responding, degraded }
nonisolated enum RecoveryTrigger: String, Codable, Sendable { case networkChange, settingsFailure, requestFailures }
nonisolated enum RecoveryStep: String, Codable, Sendable {
    case stopped, waiting, clearingSettings, buildingEngine, applyingSettings, attachingListener, backoff, running, failed
}

nonisolated struct RecoveryDiagnostic: Codable, Sendable {
    let generation: UUID
    let pathRevision: UInt64?
    let step: RecoveryStep
    let stepSeconds: TimeInterval
    let trigger: RecoveryTrigger?
    let retries: Int
    let health: UpstreamHealth
    let recentFailures: Int
    let totalFailures: Int
    let freshSuccesses: Int
    let lastSuccessSecondsAgo: TimeInterval?
    let slowestStep: RecoveryStep?
    let slowestStepSeconds: TimeInterval

    var summary: String {
        let age = lastSuccessSecondsAgo.map { "\(Int($0)) s ago" } ?? "unobserved"
        var text = "Generation \(generation). Path revision \(pathRevision.map(String.init) ?? "none"). Step: \(step.rawValue), \(Int(stepSeconds)) s. Trigger: \(trigger?.rawValue ?? "none"). Retries: \(retries)/3. Upstream: \(health.rawValue); recent failures: \(recentFailures), total failures: \(totalFailures), fresh successes: \(freshSuccesses), last success: \(age)."
        if let slowestStep {
            text += " Slowest setup step: \(slowestStep.rawValue), \(Int(slowestStepSeconds)) s."
        }
        return text
    }
}

nonisolated enum ProtectionConfiguration {
    static let providerBundleIdentifier = "saumyapatel.Umbra.Tunnel"
    static let appGroup = "group.saumyapatel.Umbra"

    static func containerURL() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = container.appendingPathComponent("Diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }

    static func counterURL() throws -> URL {
        try containerURL().appendingPathComponent("daily.sqlite")
    }

    static func snapshotURL() throws -> URL {
        try containerURL().appendingPathComponent("status.json")
    }
}

nonisolated struct DNSRequestVerdict: Sendable {
    let blockingReason: Int
    let ownedFilterMatched: Bool
    let isException: Bool
    let responseStatus: String
    let failed: Bool
    var hasQuestion: Bool = true

    var isLocalDenial: Bool {
        guard !failed, !isException else { return false }
        switch blockingReason {
        case 1: return responseStatus == "NXDOMAIN" // Engine's Mozilla DoH discovery denial.
        case 2: return responseStatus == "NOERROR" // Engine's empty DDR policy response.
        case 4...7: return ownedFilterMatched && responseStatus == "NXDOMAIN"
        default: return false
        }
    }

    var isUpstreamFailure: Bool { failed && hasQuestion }
}
