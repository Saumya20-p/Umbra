# TUN transport metadata patch (experimental integration)

Base: DnsLibs **2.8.45**, commit `e0654ab8c53109c6cca7a706b6c1166f96f0a3c4`.
Artifact: `patches/0001-preserve-tun-transport.patch`.

**Gate passed:** fresh unmodified macOS baseline compilation succeeded before the package switch. Patched macOS, iPhone arm64 and Simulator arm64/x86_64 frameworks compile. The package now links the locally assembled artifact and the provider uses its transport callback. Live device acceptance is still pending. See [BUILD.md](BUILD.md) for build inputs and limits.

Interfaces:

- C++: adds `TunListener::RequestCallbackWithProtocol(Uint8View, utils::TransportProtocol, Completion)` and a corresponding `init` overload. The original `RequestCallback`/`init` remain as a forwarding wrapper. A `std::nullptr_t` overload preserves legacy null-literal calls and their validation.
- Objective-C: adds `AGDnsTunListenerTransportMessageHandler(NSData *, BOOL isTcp, AGDnsTunListenerReplyHandler)` and `initWithTunFd:orTunnelFlow:mtu:transportMessageHandler:error:`. The existing `messageHandler:` initializer remains as a wrapper.
- The existing `process_request` transport value reaches the new native callback unchanged. The ObjC bridge maps `TP_TCP` to `YES`, UDP to `NO`. The preferred examples pass it through the existing `AGDnsMessageInfo.isTcp` or `DnsMessageInfo.proto` interfaces. `AGDnsProxy` itself is unchanged.

DNS payloads, completion ownership/threading, native TCP framing, parsing and the TCP/IP stack are unchanged. No packet parser, reply slicing, truncation workaround or endpoint is added. The patch only makes existing transport metadata available; it does not prove that missing metadata caused the observed UDP-size failure.

Validation:

- `git diff --check`: passed in the isolated editing checkout.
- `git apply --check` against the pristine pinned checkout: passed (nonmutating).
- Adds native GTest regressions for protocol-callback parameter validation and legacy null-literal calls. All five targeted listener tests **passed** through an MCP aggregate. The existing double-deinit test uses direct calls because the framework disables C++ exceptions; production exception flags are unchanged.
- Patched macOS arm64 framework compilation through XcodeBuildMCP: passed in approximately 15.7 seconds, using the exact artifact in a separate checkout. This checks native compilation, not transport behavior.
- No transport mapping fixture was added: the existing native listener tests have no packet/handshake fixture or callback injection seam. The patched framework passes all 62 Umbra Simulator tests, including explicit UDP/TCP sizing and cache-order cases. Native callback mapping through a real tunnel, EDNS truncation/TCP retry on the phone and signed-device acceptance remain **NOT RUN**. Do not infer those passes from offline tests.

Applicability can be rechecked without modifying the source:

```sh
git -C /path/to/pristine/DnsLibs2845 apply --check /absolute/path/to/0001-preserve-tun-transport.patch
```

Apply only to a separate checkout of the exact base. Keep the original pinned source and binary rollback metadata. Framework build settings expose only the framework target’s ObjC++ classes, retain dependency visibility settings, keep conversion warnings visible and disable upstream signing. No networking source other than the transport callback is changed.
