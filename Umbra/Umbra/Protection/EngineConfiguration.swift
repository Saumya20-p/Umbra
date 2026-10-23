import Foundation
@preconcurrency import AGDnsProxy

// Shared production settings; tests inspect the same configuration used by the provider.
nonisolated enum EngineConfiguration {
    static func make(interface: String, ipv6: Bool, filterURL: URL) -> AGDnsProxyConfig {
        let settings = AGDnsProxyConfig.getDefault()!
        let upstream = AGDnsUpstream()
        upstream.address = "https://dns10.quad9.net/dns-query"
        upstream.bootstrap = []
        // Connect to a service IP while validating the DoH hostname; never use plaintext bootstrap.
        upstream.serverIp = ipv6
            ? Data([0x26, 0x20, 0x00, 0xfe, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10])
            : Data([9, 9, 9, 10])
        upstream.outboundInterfaceName = interface
        upstream.id = 1
        settings.upstreams = [upstream]
        settings.fallbacks = []
        settings.fallbackDomains = []
        settings.detectSearchDomains = false
        settings.enableFallbackOnUpstreamsFailure = false
        settings.enableParallelUpstreamQueries = false
        settings.enableRetransmissionHandling = false
        settings.enableServfailOnUpstreamsFailure = true
        settings.enableHttp3 = false
        settings.listeners = []
        settings.blockIpv6 = false
        settings.ipv6Available = ipv6
        settings.hostsRulesBlockingMode = .init(rawValue: 1)!
        settings.adblockRulesBlockingMode = .init(rawValue: 1)!
        settings.blockedResponseTtlSecs = 1
        settings.dnsCacheSize = 256
        settings.optimisticCache = false
        settings.upstreamTimeoutMs = 5_000
        settings.filtersMemoryLimitBytes = 4 * 1_024 * 1_024
        let filter = AGDnsFilterParams()
        filter.id = 1
        filter.data = filterURL.path
        filter.inMemory = false
        settings.filters = [filter]
        return settings
    }
}

#if DEBUG
nonisolated struct TunnelValidation {
    static let upstreamOption = "umbra.validation.unavailableUpstream"
    static let counterCommand = Data("validation.fail-next-counter-write".utf8)
    var upstreamUnavailable = false
    var counterWriteArmed = false
    private(set) var counterWriteFailed = false

    var label: String? {
        if upstreamUnavailable { return "DEBUG: encrypted loopback upstream intentionally unavailable" }
        if counterWriteFailed { return "DEBUG: a real denial intentionally failed persistence; total is incomplete" }
        if counterWriteArmed { return "DEBUG: next real denial will fail persistence; total may be incomplete" }
        return nil
    }

    mutating func takeCounterWriteFailure() -> Bool {
        let armed = counterWriteArmed
        counterWriteArmed = false
        if armed { counterWriteFailed = true }
        return armed
    }
}
#endif
