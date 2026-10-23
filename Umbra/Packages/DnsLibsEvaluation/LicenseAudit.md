# DnsLibs 2.8.45 source and license audit

Binary: AGDnsProxy-apple-2.8.45.zip from official GitHub v2.8.45@swift-5 release; SHA256 f9d0495427909b19376bfe6fead93af6c9acc401880fddf29de3dd89244c552b verified after download.
Swift manifest revision: 5570e10e4883f9fe770a291b4025449127185f88.
Source tag revision: e0654ab8c53109c6cca7a706b6c1166f96f0a3c4.
Source conandata 2.8.45 recipe maps to b178ef332ce193351951a3019a38d7a39152d9f8.
NLC 8.0.27 source revision: 9458af4b1cb0a1ac2302a3a02270ef013a286eed, mapped by historical conandata at b9ec3cc2305061641009cfdf5b2a63d1aec983e9 (there is no v8.0.27 public tag).

Known runtime/source components: DnsLibs Apache-2.0; NLC Apache-2.0; cxxopts 3.1.1 MIT; libevent 2.1.11 BSD/ISC/MIT; libsodium 1.0.18 ISC; libuv 1.41.0 MIT/BSD/ISC; klib e1b2a40de8e2a46c05cc5dac9c6e5e8d15ae722c MIT; ldns 7128ef56649e0737f236bc5d5d640de38ff0036d BSD/ISC/IBM/public-domain; magic_enum .9.5 MIT; ngtcp2 1.0.1 MIT; PCRE2 10.37 BSD-3-Clause with binary exemption; tldregistry 2022-12-26 Apache/Chromium BSD; BoringSSL 58f3bc83230d2958bb9710bc910972c4f5d382dc OpenSSL/SSLeay/ISC/MIT; ada 2.7.4 MIT (selected from dual license); fmt 12.1.0 MIT with exception; llhttp 9.1.3 MIT; nghttp2 1.56.0 MIT; nghttp3 1.0.0 MIT; bundled lwIP BSD; pcap_savefile BSD-4-Clause.

THIRD-PARTY-NOTICES.txt combines unmodified downloaded license texts with extracted copyright/license blocks. It includes a conservative set of lwIP core and headers copyright/license blocks, including code that may be disabled. sources.json records primary URLs. Source copies ending in -source.* are investigative inputs and do not need shipping.

Redistribution obligations: ship license and copyright texts; retain non-endorsement terms. BoringSSL's legacy OpenSSL/SSLeay conditions and pcap BSD-4-Clause include acknowledgment/advertising clauses. Required text includes: "This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/)"; "This product includes cryptographic software written by Eric Young (eay@cryptsoft.com)"; and the pcap acknowledgment to the Computer Systems Engineering Group at Lawrence Berkeley Laboratory. Review marketing copy against these exact license texts before distribution.

These permissive terms do not require opening Umbra's proprietary source. This is a source/dependency license inventory, not a publisher-provided SBOM or proof that the downloaded binary was built from exactly this graph. The upstream archive includes only DnsLibs LICENSE, no transitive notices or SBOM. No linked third-party dynamic dependencies appear in otool -L. Only Apple system frameworks/libraries are dynamically linked.

The local compiled-engine experiment can carry these notices. Release readiness still requires a final distribution/license review, a current engine binary or accepted version maintenance decision, signed-device DNS tests, and performance/battery measurement. No workspace changes or external messages were made in this audit.

## Local transport build — October 22

The active package now uses the local source build identified as `2.8.45-umbra-transport1`; the official binary above is rollback history. `NativeBuild.json` records resolved host package IDs/revisions for all four build profiles, and `ArtifactHashes.json` identifies the assembled files. Existing source-based notices cover the same pinned dependency versions; this does not establish final legal clearance or an exhaustive linked-symbol SBOM. The additive patch changes DnsLibs under Apache-2.0 and preserves its upstream license. List GPL aggregation and Apple/provider distribution gates remain separate.
