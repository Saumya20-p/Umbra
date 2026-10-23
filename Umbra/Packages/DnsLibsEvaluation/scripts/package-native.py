#!/usr/bin/env python3
"""Assemble already-built Apple slices; compilation remains an XcodeBuildMCP step."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

PACKAGE = Path(__file__).resolve().parents[1]
PATCH_ID = "2.8.45-umbra-transport1"


def assemble(root):
    output = PACKAGE / "Artifacts" / f"AGDnsProxy-{PATCH_ID}.xcframework"
    assert not output.exists(), f"Refusing to replace {output}"
    libraries = []
    for identifier, targets, arches in [
        ("ios-arm64", ["ios"], ["arm64"]),
        ("ios-arm64_x86_64-simulator", ["sim-arm", "sim-x86"], ["arm64", "x86_64"]),
    ]:
        sources = [root / f"framework-{target}-patched/AGDnsProxy.framework" for target in targets]
        for source, arch, target in zip(sources, arches, targets):
            actual = subprocess.check_output(["/usr/bin/lipo", "-archs", source / "AGDnsProxy"], text=True).split()
            assert actual == [arch], (source, actual)
            symbols = subprocess.check_output(["/usr/bin/nm", "-gU", source / "AGDnsProxy"], text=True)
            assert "_OBJC_CLASS_$_AGDnsProxy" in symbols and "_OBJC_CLASS_$_AGDnsTunListener" in symbols, "Public ObjC classes are hidden"
            commands = subprocess.check_output(["/usr/bin/otool", "-l", source / "AGDnsProxy"], text=True)
            assert ("platform 2" if target == "ios" else "platform 7") in commands, "Wrong binary platform"
        headers = [{p.name: p.read_bytes() for p in source.glob("Headers/*.h")} for source in sources]
        assert all(h == headers[0] for h in headers), "Slice headers differ"
        framework = output / identifier / "AGDnsProxy.framework"
        shutil.copytree(sources[0], framework, symlinks=True)
        if len(sources) > 1:
            binary = framework / "AGDnsProxy"
            binary.unlink()
            subprocess.run(["/usr/bin/lipo", "-create", *[s / "AGDnsProxy" for s in sources], "-output", binary], check=True)
        info = plistlib.loads((framework / "Info.plist").read_bytes())
        info.update(CFBundleShortVersionString="2.8.45", CFBundleVersion="2845.1", UmbraEnginePatchIdentifier=PATCH_ID)
        info.pop("UIRequiredDeviceCapabilities", None)
        (framework / "Info.plist").write_bytes(plistlib.dumps(info))
        library = dict(LibraryIdentifier=identifier, LibraryPath="AGDnsProxy.framework", SupportedArchitectures=arches, SupportedPlatform="ios")
        if len(sources) > 1:
            library["SupportedPlatformVariant"] = "simulator"
        libraries.append(library)
    (output / "Info.plist").write_bytes(plistlib.dumps(dict(AvailableLibraries=libraries, CFBundlePackageType="XFWK", XCFrameworkFormatVersion="1.0")))
    hashes = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(output.rglob("*")) if p.is_file()}
    (PACKAGE / "ArtifactHashes.json").write_text(json.dumps(dict(patchID=PATCH_ID, files=hashes), indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_root", type=Path)
    assemble(parser.parse_args().build_root.resolve())
