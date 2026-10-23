import Foundation
import Testing
@preconcurrency import AGDnsProxy
@testable import Umbra

struct EngineConfigurationTests {
    @Test(arguments: [false, true]) func productionSettingsKeepEncryptedPinnedResolverAndLocalFilter(ipv6: Bool) throws {
        let url = URL(fileURLWithPath: "/fixture/blocked-hosts.txt")
        let settings = EngineConfiguration.make(interface: "fixture-interface", ipv6: ipv6, filterURL: url)
        #expect(settings.upstreams.count == 1)
        let upstream = try #require(settings.upstreams.first)
        #expect(upstream.address == "https://dns10.quad9.net/dns-query")
        #expect(upstream.bootstrap.isEmpty)
        #expect(upstream.outboundInterfaceName == "fixture-interface")
        #expect(upstream.id == 1)
        let expected = ipv6
            ? Data([0x26, 0x20, 0x00, 0xfe, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10])
            : Data([9, 9, 9, 10])
        #expect(upstream.serverIp == expected)
        #expect(settings.fallbacks.isEmpty)
        #expect(settings.fallbackDomains.isEmpty)
        #expect(settings.listeners.isEmpty)
        #expect(!settings.detectSearchDomains)
        #expect(!settings.enableFallbackOnUpstreamsFailure)
        #expect(!settings.enableParallelUpstreamQueries)
        #expect(!settings.enableRetransmissionHandling)
        #expect(settings.enableServfailOnUpstreamsFailure)
        #expect(!settings.enableHttp3)
        #expect(!settings.blockIpv6)
        #expect(settings.ipv6Available == ipv6)
        #expect(settings.dns64Settings == nil)
        #expect(settings.dnsCacheSize == 256)
        #expect(!settings.optimisticCache)
        #expect(settings.blockedResponseTtlSecs == 1)
        #expect(settings.upstreamTimeoutMs == 5_000)
        #expect(settings.filtersMemoryLimitBytes == 4 * 1_024 * 1_024)
        #expect(settings.hostsRulesBlockingMode.rawValue == 1)
        #expect(settings.adblockRulesBlockingMode.rawValue == 1)
        #expect(settings.filters.count == 1)
        let filter = try #require(settings.filters.first)
        #expect(filter.data == url.path)
        #expect(!filter.inMemory)
        #expect(filter.id == 1)
    }

    #if DEBUG
    @Test func counterFaultIsOneShotAndNewSessionHasNoFault() {
        var validation = TunnelValidation()
        #expect(validation.label == nil)
        let unarmed = validation.takeCounterWriteFailure()
        #expect(!unarmed)
        validation.counterWriteArmed = true
        #expect(validation.label?.contains("next real denial") == true)
        let armed = validation.takeCounterWriteFailure()
        let consumed = validation.takeCounterWriteFailure()
        #expect(armed)
        #expect(!consumed)
        #expect(validation.counterWriteFailed)
        #expect(validation.label?.contains("incomplete") == true)
        validation = TunnelValidation()
        #expect(!validation.upstreamUnavailable)
        #expect(!validation.counterWriteArmed)
        #expect(!validation.counterWriteFailed)
        #expect(validation.label == nil)
    }
    #endif

    @Test func savedStatusExcludesLiveValidationAndNetworkMetrics() throws {
        var snapshot = ProtectionSnapshot(phase: .failed, failure: .storage, blockedToday: 123,
                                          lastProcessedAt: .now, diagnostics: TunnelDiagnostics(),
                                          validationMode: "fixture validation")
        snapshot.diagnostics?.physicalIPv6 = true
        snapshot.sampledAt = .now
        snapshot.diagnostics?.recovery = TunnelRecovery().diagnostic()
        let data = try JSONEncoder().encode(snapshot.persisted)
        let saved = try JSONDecoder().decode(ProtectionSnapshot.self, from: data)
        #expect(saved.phase == .failed)
        #expect(saved.failure == .storage)
        #expect(saved.blockedToday == nil)
        #expect(saved.lastProcessedAt == nil)
        #expect(saved.diagnostics == nil)
        #expect(saved.validationMode == nil)
        #expect(saved.sampledAt == nil)
        #expect(snapshot.diagnostics?.physicalIPv6 == true)
    }

    @Test func olderDiagnosticsDecodeAndNewDiagnosticsRoundTrip() throws {
        let older = Data("{\"phase\":\"running\",\"verifiedLocalDenial\":false,\"diagnostics\":{\"session\":\"00000000-0000-0000-0000-000000000001\",\"received\":0,\"processed\":0,\"denied\":0,\"committed\":0,\"pending\":0,\"upstreamBytesSent\":0}}".utf8)
        var snapshot = try JSONDecoder().decode(ProtectionSnapshot.self, from: older)
        #expect(snapshot.sampledAt == nil)
        #expect(snapshot.diagnostics?.recovery == nil)
        var recovery = TunnelRecovery()
        recovery.begin(now: 0)
        _ = recovery.updatePath(.init(interface: "cellular", ipv6: true, revision: 4), now: 1)
        snapshot.sampledAt = Date(timeIntervalSince1970: 1_000)
        snapshot.diagnostics?.recovery = recovery.diagnostic(at: 40)
        let decoded = try JSONDecoder().decode(ProtectionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.sampledAt == snapshot.sampledAt)
        #expect(decoded.diagnostics?.recovery?.step == .clearingSettings)
        #expect(decoded.diagnostics?.recovery?.stepSeconds == 39)
        #expect(decoded.diagnostics?.recovery?.pathRevision == 4)
    }
}

struct TunnelShutdownTests {
    @Test(arguments: [false, true]) func delayedNativeAndCounterWorkPreventEarlyOrRepeatedStop(nativeFirst: Bool) {
        var shutdown = TunnelShutdown(pending: true, settingsCleared: false, nativeDrains: 1,
                                      counterWrites: 2, preferenceWrites: 1)
        var finished = shutdown.finishIfReady()
        #expect(!finished)
        shutdown.settingsCleared = true
        shutdown.preferenceWrites = 0
        if nativeFirst { shutdown.nativeDrains = 0 } else { shutdown.counterWrites = 0 }
        finished = shutdown.finishIfReady()
        #expect(!finished)
        if nativeFirst {
            shutdown.counterWrites = 1
            finished = shutdown.finishIfReady()
            #expect(!finished)
            shutdown.counterWrites = 0
        } else { shutdown.nativeDrains = 0 }
        finished = shutdown.finishIfReady()
        #expect(finished)
        finished = shutdown.finishIfReady()
        #expect(!finished)
    }

    @Test func preferenceWriteAndSettingsCompletionAreAlsoRequired() {
        var shutdown = TunnelShutdown(pending: true, preferenceWrites: 1)
        var finished = shutdown.finishIfReady()
        #expect(!finished)
        shutdown.settingsCleared = true
        finished = shutdown.finishIfReady()
        #expect(!finished)
        shutdown.preferenceWrites = 0
        finished = shutdown.finishIfReady()
        #expect(finished)
    }
}
