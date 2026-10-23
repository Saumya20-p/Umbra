import Foundation
import Darwin

nonisolated enum PhysicalNetworkIdentity {
    static func addresses(interface: String) -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var current = first
        var results: [String] = []
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == interface,
                  let address = item.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                results.append(host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
            }
        }
        return results.sorted()
    }
}

nonisolated struct TunnelRecovery {
    struct Path: Equatable, Sendable {
        let interface: String
        let ipv6: Bool
        let revision: UInt64
    }
    private(set) var phase: ProtectionPhase = .stopped
    private(set) var generation = UUID()
    private(set) var path: Path?
    private(set) var retries = 0
    private(set) var health: UpstreamHealth = .unverified
    private var failures: [TimeInterval] = []
    private var healthySince: TimeInterval?
    private var lastSuccess: TimeInterval?
    private var freshSuccesses = 0
    private var totalFailures = 0
    private var step: RecoveryStep = .stopped
    private var stepStarted: TimeInterval = 0
    private var trigger: RecoveryTrigger?
    private var slowestStep: RecoveryStep?
    private var slowestSeconds: TimeInterval = 0

    mutating func begin(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self = Self()
        phase = .waiting
        generation = UUID()
        markStep(.waiting, now: now)
    }

    mutating func updatePath(_ next: Path?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard phase != .stopped, phase != .failed else { return false }
        guard path != next || (next != nil && phase == .waiting) else { return false }
        path = next
        clearPathHealth()
        generation = UUID()
        slowestStep = nil
        slowestSeconds = 0
        stepStarted = now
        trigger = .networkChange
        phase = next == nil ? .waiting : .recovering
        markStep(next == nil ? .waiting : .clearingSettings, now: now)
        return true
    }

    mutating func retry(reason: RecoveryTrigger = .requestFailures, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int? {
        guard phase != .stopped, phase != .failed, path != nil else { return nil }
        generation = UUID()
        guard retries < 3 else { phase = .failed; return nil }
        let delay = [1, 2, 4][retries]
        retries += 1
        clearPathHealth()
        trigger = reason
        markStep(.clearingSettings, now: now)
        phase = .recovering
        return delay
    }

    mutating func running(_ token: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard generation == token, phase == .recovering else { return false }
        phase = .running
        markStep(.running, now: now)
        return true
    }

    // Only fresh network results affect health; denials and stale callbacks still use the counter path.
    mutating func observe(_ verdict: DNSRequestVerdict, freshSuccess: Bool, token: UUID,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard generation == token, phase == .running else { return false }
        failures.removeAll { now - $0 > 30 }
        if verdict.isUpstreamFailure {
            totalFailures += 1
            if failures.count < 3 { failures.append(now) }
            healthySince = nil
            health = .degraded
            return failures.count >= 3
        }
        if freshSuccess, verdict.hasQuestion, !verdict.failed, !verdict.isLocalDenial {
            freshSuccesses += 1
            lastSuccess = now
            health = failures.isEmpty ? .responding : .degraded
            if let healthySince, now - healthySince >= 60 { retries = 0 }
            else if healthySince == nil { healthySince = now }
        }
        return false
    }

    mutating func markStep(_ next: RecoveryStep, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if [.clearingSettings, .buildingEngine, .applyingSettings, .attachingListener, .backoff].contains(step),
           now - stepStarted > slowestSeconds {
            slowestStep = step
            slowestSeconds = now - stepStarted
        }
        step = next
        stepStarted = now
    }

    func diagnostic(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RecoveryDiagnostic {
        RecoveryDiagnostic(generation: generation, pathRevision: path?.revision, step: step,
                           stepSeconds: max(0, now - stepStarted), trigger: trigger, retries: retries,
                           health: health, recentFailures: failures.filter { now - $0 <= 30 }.count,
                           totalFailures: totalFailures, freshSuccesses: freshSuccesses,
                           lastSuccessSecondsAgo: lastSuccess.map { max(0, now - $0) },
                           slowestStep: slowestStep, slowestStepSeconds: slowestSeconds)
    }

    private mutating func clearPathHealth() {
        failures.removeAll(keepingCapacity: true)
        healthySince = nil
        lastSuccess = nil
        health = .unverified
    }

    mutating func stop(failed: Bool = false) {
        phase = failed ? .failed : .stopped
        generation = UUID()
        path = nil
        markStep(failed ? .failed : .stopped)
    }
}

// Queue-confined; serialize OS settings writes and replace obsolete pending updates.
nonisolated final class TunnelSettingsQueue: @unchecked Sendable {
    typealias Completion = @Sendable (Error?) -> Void
    private let queue: DispatchQueue
    private let setter: @Sendable (Bool, @escaping Completion) -> Void
    private var busy = false
    private var pending: (Bool, Completion)?

    init(queue: DispatchQueue, setter: @escaping @Sendable (Bool, @escaping Completion) -> Void) {
        self.queue = queue
        self.setter = setter
    }

    func set(_ configured: Bool, completion: @escaping Completion) {
        dispatchPrecondition(condition: .onQueue(queue))
        let superseded = pending
        pending = (configured, completion)
        superseded?.1(CancellationError())
        pump()
    }

    private func pump() {
        guard !busy, let update = pending else { return }
        pending = nil
        busy = true
        setter(update.0) { [self] error in
            queue.async { [self] in
                busy = false
                update.1(error)
                pump()
            }
        }
    }
}

// Queue-confined shutdown barrier; a stop cannot finish before all emitted work drains.
nonisolated struct TunnelShutdown {
    var pending = false
    var settingsCleared = false
    var nativeDrains = 0
    var counterWrites = 0
    var preferenceWrites = 0

    mutating func finishIfReady() -> Bool {
        guard pending, settingsCleared, nativeDrains == 0, counterWrites == 0, preferenceWrites == 0 else { return false }
        pending = false
        return true
    }
}
