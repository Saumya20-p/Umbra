// swift-tools-version: 6.0
import PackageDescription

// Pinned local transport repair; not approved for distribution. See BUILD.md.
let package = Package(
    name: "DnsLibsEvaluation",
    platforms: [.iOS("27.0")],
    products: [.library(name: "AGDnsProxy", targets: ["AGDnsProxy"])],
    targets: [
        .binaryTarget(
            name: "AGDnsProxy",
            path: "Artifacts/AGDnsProxy-2.8.45-umbra-transport1.xcframework"
        )
    ]
)
