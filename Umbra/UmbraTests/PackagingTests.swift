import Foundation
import Testing
import CryptoKit
@testable import Umbra

struct PackagingTests {
    @Test @MainActor func experimentalCandidateIncludesPinnedSourceAndLicense() throws {
        let source = try BundledBlocklist.load()
        #expect(source.name == "HaGeZi Multi PRO mini")
        #expect(source.revision == "a1922493099f56bc5b0cf1f7bfa060921be421ee")
        #expect(source.license == "GPL-3.0")
        let license = try BundledBlocklist.licenseText()
        #expect(license.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(license.contains("Version 3, 29 June 2007"))
        let file = try #require(try BundledBlocklist.bundle().url(forResource: "blocked-hosts", withExtension: "txt"))
        let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "bce3daf388f70464947fbb06c8255f589b6d935ec7b7b1a78d0d2da94a3cb247")
    }

    @Test func hostEmbedsFrameworkNeededByTunnel() throws {
        let framework = Bundle.main.bundleURL
            .appendingPathComponent("Frameworks/AGDnsProxy.framework/AGDnsProxy")
        #expect(FileManager.default.fileExists(atPath: framework.path))
        let bundle = try #require(Bundle(url: framework.deletingLastPathComponent()))
        #expect(bundle.object(forInfoDictionaryKey: "UmbraEnginePatchIdentifier") as? String == "2.8.45-umbra-transport1")
    }
}
