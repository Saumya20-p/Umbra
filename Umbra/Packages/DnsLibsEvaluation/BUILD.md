# Native transport build — 2.8.45-umbra-transport1

This is an experimental source rebuild, not a production/distribution approval. The package now uses the local XCFramework; the original official URL/checksum remain in README.md for rollback. Provider code must be rolled back with the binary because its new initializer is additive.

## Recorded inputs

- DnsLibs source: `e0654ab8c53109c6cca7a706b6c1166f96f0a3c4` plus `patches/0001-preserve-tun-transport.patch`.
- Public NativeLibsCommon recipe checkout: `b9ec3cc2305061641009cfdf5b2a63d1aec983e9`; its 8.0.27 source maps to `9458af4b1cb0a1ac2302a3a02270ef013a286eed`.
- Python 3.14.6, Conan 2.21.0, CMake 3.31.6; Conan build requirements select CMake 3.31.12. AppleClang 21.0.0.21000334, Apple SDK 27.1.
- `baseline-macos.lock` pins all 19 host recipe revisions and build requirements. `NativeBuild.json` additionally records resolved host package IDs/revisions for macOS, device, arm64 Simulator and x86_64 Simulator, plus patch/lock hashes. These include test requirements; they are not an exhaustive linked-symbol SBOM.
- `scripts/profiles/` retains actual build profiles. Isolated Conan settings explicitly add compiler 21 and iOS 27.0 instead of pretending an older compiler. Build outputs use Release, C++20 and libc++; Umbra stays Swift 6/minimum iOS 27.0.
- `ArtifactHashes.json` identifies every assembled XCFramework file. Existing notices/source license inventory remain applicable to these dependency versions; legal review is still pending.

## Build settings and issues resolved

Dependencies compile with their supported Unix Makefiles generator **inside an XcodeBuildMCP aggregate build**. Forcing Xcode on every dependency failed nghttp2 documentation and ada single-header custom-command generation. No dependency version was substituted. The macOS preparation disables nghttp2 documentation via a forced BOOL cache variable.

Set `CMAKE_INSTALL_PREFIX` to a path containing literal `conan2`. Upstream uses this guard to bypass downloading a floating Conan provider/nested installs. Conan itself uses an isolated `conan2-home`; no global profile is changed.

Frameworks use CMake's Xcode generator, `TARGET_OS=macos`/`ios`, the appropriate locked dependency toolchain, and explicit SDK/architecture/deployment target. macOS proof uses 12.0 because Xcode 27 rejects upstream's default 10.15. Device/Simulator use iOS 27.0. Set `CMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE` to each framework build directory: upstream's postbuild Modules symlink expects the framework there. Do not override global `CONFIGURATION_BUILD_DIR`, which relocates static archives away from CMake's link paths.

A build-only deferred target property sets `AGDnsProxy`'s `CXX_VISIBILITY_PRESET` to `default`. Xcode otherwise applies C++ hidden visibility to ObjC++ despite upstream's ObjC++ default setting, leaving public ObjC classes unexported. Dependency visibility stays unchanged. Packaging asserts exported proxy/listener classes and correct Mach-O platform/architectures.

Use these MCP build arguments (structured tool arguments, not a shell string):

```text
CODE_SIGNING_ALLOWED=NO
GCC_TREAT_WARNINGS_AS_ERRORS=NO
OTHER_CPLUSPLUSFLAGS=$(inherited) -Wno-error=shorten-64-to-32
```

Upstream's Performiks signing identity is bypassed; Umbra signs the embedded framework normally. Existing narrowing warnings remain visible, as do legacy bitcode warnings. No networking logic is changed by these build settings.

## Reproduce

Use a fresh scratch root with Python 3.14.6. Setup downloads tools/public pinned source and exports the exact recipes; it does not compile libraries:

```sh
python3 scripts/build-native.py --work-root /private/tmp/umbra-native-repeat prepare
```

Then use XcodeBuildMCP `session_set_defaults` on `prep-xcode/UmbraNativePreparation.xcodeproj`, Release, and `build_macos({extraArgs:["CODE_SIGNING_ALLOWED=NO"]})` with these schemes:

1. `Dependencies-macos`, `Dependencies-ios`, `Dependencies-sim-arm`, `Dependencies-sim-x86`. Run individually to stay within MCP's five-minute call timeout. `PrepareDependencies` is the combined alternative; the original combined call timed out, but logs showed all three iOS installs completed afterward.
2. `ConfigureBaseline`, then the generated `framework-macos-baseline/dnsproxy_framework.xcodeproj`, scheme `AGDnsProxy`, via MCP `build_macos` with the arguments above. Require this fresh unmodified build to pass.
3. `ConfigurePatched`, only after the baseline gate. Build generated macOS and device projects with `build_macos`/`build_device`, and arm64 Simulator with `build_sim`, scheme `AGDnsProxy`, same arguments.
4. Use the preparation project's `BuildIntelSimulator` aggregate for x86_64. This compiles through CMake/Xcode under MCP without needing a runnable Intel simulator destination. `NativeTransportTests` builds/runs only the offline `TunListenerTest.*` cases. Do not run the vendor's general network suite: it contains unauthorized public resolver endpoints.
5. Assemble already-built slices with `python3 scripts/package-native.py /private/tmp/umbra-native-repeat`. This copies framework bundles, merges only the two Simulator Mach-O binaries using lipo, writes standard XCFramework metadata and hashes, and marks the patch ID. It refuses to overwrite an artifact. Compare/review hashes before replacing an existing artifact. No binary byte slicing or DNS parsing is involved.
6. Restore MCP defaults to `Umbra/Umbra.xcodeproj`, scheme `Umbra`, Debug. Run Simulator tests, physical-device unit tests, Release build, signature/embedding checks, then install/run the diagnostic build and complete live acceptance.

The helper's syntax, pinned-source/recipe checks, lock SHA and patch apply-check passed. Packaging assertions and a second assembly produced identical hashes. A fresh end-to-end run of the durable helper is **NOT RUN**; the recorded builds used equivalent preparation commands in temporary projects.

## Results and remaining gates

- Fresh unmodified macOS baseline: passed, 16.4 s; log `build_macos_2026-10-22T07-02-41-757Z_pid83180_49453df7.log`. Earlier global-output-dir attempt relied on stale archives and is not the clean gate.
- Patched macOS, iPhone arm64, Simulator arm64/x86_64: compiled. Final iOS artifacts expose the public ObjC classes. Intel Simulator was compiled, not executed.
- Native listener tests: **5 passed**, log `build_macos_2026-10-22T07-04-40-263Z_pid83180_caed67ba.log`.
- Umbra full Simulator suite: **62 passed**, including UDP limits/TC, full TCP responses, both cache orders, filtering/counter/recovery, embedded patch ID and UI checks; result `test_sim_2026-10-22T14-42-04-994Z_pid83180_7798d7cb.xcresult`.
- Release device build: passed, 11.5 s, log `build_device_2026-10-22T07-14-29-752Z_pid83180_6d2d4b19.log`. App/extension/embedded framework strict signatures pass; patch ID present; DEBUG failure-command strings absent from Release executables.
- Physical-device tests/install: pending. First attempt waited on a locked phone and later lost its runner; retry found the device disconnected. Neither is a test pass. The owner chose to finish with installation pending.
- Live UDP truncation/TC-driven TCP fallback, actual native callback mapping on the phone, DNSSEC validation, fragmentation, IPv6-only/NAT64 and controlled efficiency remain unverified. Offline engine behavior is not tunnel acceptance or Apple support evidence.
