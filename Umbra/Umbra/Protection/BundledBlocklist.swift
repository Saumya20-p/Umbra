import Foundation

struct BundledBlocklist: Decodable {
    let name: String
    let source: URL
    let revision: String
    let license: String

    static func bundle() throws -> Bundle {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let bundle = Bundle(url: plugins.appendingPathComponent("UmbraTunnel.appex")),
              bundle.bundleIdentifier == ProtectionConfiguration.providerBundleIdentifier else {
            throw CocoaError(.fileNoSuchFile)
        }
        return bundle
    }

    static func load() throws -> Self {
        guard let url = try bundle().url(forResource: "BlocklistSource", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    static func licenseText() throws -> String {
        guard let url = try bundle().url(forResource: "BlocklistLicense", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
