# Umbra

Experimental iPhone app for local DNS filtering, built with SwiftUI and Swift 6. Minimum iOS: **27.0**.

## Build and test

Open `Umbra/Umbra.xcodeproj`, scheme **Umbra**. Use XcodeBuildMCP for builds, runs and tests. Select your signing team and appropriate Network Extension/App Group provisioning for physical-device builds. Keep Derived Data outside the repository.

The Simulator supports app/unit/UI tests but cannot activate the tunnel. A signed physical iPhone is required to install the experimental VPN configuration and validate filtering. Disable the experiment in-app or in Settings to restore ordinary connectivity.

## Included components

- `Umbra/Umbra/`: diagnostic app, shared recovery logic and daily counter.
- `Umbra/UmbraTunnel/`: packet-tunnel extension and bundled blocklist.
- `Umbra/UmbraTests/` and `Umbra/UmbraUITests/`: automated tests and fixtures.
- `Umbra/Packages/DnsLibsEvaluation/`: required pinned XCFramework, transport patch, reproducible-build helpers, provenance and third-party notices.

The bundled engine is DnsLibs 2.8.45 with the local `umbra-transport1` patch. The experimental blocklist is HaGeZi Multi PRO mini. Their licenses and attribution accompany the package and extension resources; retain them when redistributing these components.

## Experimental status

“Blocked today” counts actual locally denied requests, not unique ads. The app stores daily aggregate totals without retaining domain histories. Abrupt extension termination can lose uncommitted events.

This packet-tunnel DNS experiment does not establish Apple support or App Store eligibility. Provider permission, licensing/distribution review, broader compatibility and controlled battery measurements remain unresolved. A working development build is not distribution approval.
