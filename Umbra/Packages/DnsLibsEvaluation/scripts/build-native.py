#!/usr/bin/env python3
"""Prepare pinned native inputs; run dependencies/configuration through the MCP aggregate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import venv

PACKAGE = Path(__file__).resolve().parents[1]
SOURCE_PIN = "e0654ab8c53109c6cca7a706b6c1166f96f0a3c4"
RECIPE_PIN = "b9ec3cc2305061641009cfdf5b2a63d1aec983e9"
LOCK = PACKAGE / "baseline-macos.lock"
PATCH = PACKAGE / "patches/0001-preserve-tun-transport.patch"
# These are the exact public recipe directories exported in the successful evaluation.
EXPORTS = {
    "libevent": "2.1.11", "libsodium": "1.0.18", "libuv": "1.41.0",
    "klib": "2021-04-06", "ldns": "2021-03-29", "boringssl": "boring-2024-09-13",
    "pcre2": "10.37", "tldregistry": "2022-12-26", "llhttp-9.1.3": "9.1.3",
    "nghttp2-1.56.0": "1.56.0", "nghttp3-1.0.0": "1.0.0", "ngtcp2-1.0.1": "1.0.1",
}
TARGETS = {
    "macos": ("macosx", "arm64", "12.0"),
    "ios": ("iphoneos", "arm64", "27.0"),
    "sim-arm": ("iphonesimulator", "arm64", "27.0"),
    "sim-x86": ("iphonesimulator", "x86_64", "27.0"),
}


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def pin(path, expected):
    actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    assert actual == expected, f"Unexpected source pin: {path}: {actual}"
    dirty = subprocess.check_output(
        ["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"], text=True)
    assert not dirty, f"Tracked source modifications: {path}"


def clone(url, path, commit):
    if not path.exists():
        run(["git", "clone", "--no-checkout", url, path])
        run(["git", "-C", path, "checkout", "--detach", commit])
    pin(path, commit)


def check(root):
    assert not sys.flags.optimize, "Assertions must remain enabled"
    assert json.loads(LOCK.read_text())["version"] == "0.5"
    assert hashlib.sha256(LOCK.read_bytes()).hexdigest() == "0b560c921f5aae509985124e88a23b31603c44607fa092b839f13a518006efe4"
    pin(root / "source-baseline", SOURCE_PIN)
    pin(root / "recipes", RECIPE_PIN)
    run(["git", "-C", root / "source-baseline", "apply", "--check", PATCH])


def environment(root):
    env = os.environ.copy()
    env["CONAN_HOME"] = str(root / "conan2-home")
    env["PATH"] = str(root / "venv/bin") + os.pathsep + env["PATH"]
    return env


def prepare(root):
    assert sys.version_info[:3] == (3, 14, 6), "Use the recorded Python 3.14.6 interpreter"
    root.mkdir(parents=True, exist_ok=True)
    clone("https://github.com/AdguardTeam/DnsLibs.git", root / "source-baseline", SOURCE_PIN)
    clone("https://github.com/AdguardTeam/NativeLibsCommon.git", root / "recipes", RECIPE_PIN)
    check(root)
    venv.EnvBuilder(with_pip=True).create(root / "venv")
    run([root / "venv/bin/python", "-m", "pip", "install", "conan==2.21.0", "cmake==3.31.6"])
    env = environment(root)
    conan = root / "venv/bin/conan"
    run([conan, "profile", "detect", "--force"], env=env)
    # Conan 2.21 predates these actual compiler/deployment settings.
    run([root / "venv/bin/python", "-c", """
import os, pathlib, yaml
p = pathlib.Path(os.environ['CONAN_HOME']) / 'settings.yml'
d = yaml.safe_load(p.read_text())
for values, value in [(d['compiler']['apple-clang']['version'], '21'), (d['os']['iOS']['version'], '27.0')]:
    if value not in values:
        values.append(value)
p.write_text(yaml.safe_dump(d, sort_keys=False))
"""], env=env)
    for profile in (PACKAGE / "scripts/profiles").iterdir():
        shutil.copyfile(profile, root / "conan2-home/profiles" / profile.name)
    recipes = root / "recipes"
    run([conan, "export", recipes, "--version=8.0.27", "--user=adguard", "--channel=oss"], env=env)
    for directory, version in EXPORTS.items():
        run([conan, "export", recipes / "conan/recipes" / directory,
             "--version=" + version, "--user=adguard", "--channel=oss"], env=env)
    project = root / "prep-project"
    project.mkdir(exist_ok=True)
    script = Path(__file__).resolve()
    lines = ["cmake_minimum_required(VERSION 3.24)", "project(UmbraNativePreparation NONE)"]
    for target, action, variant in [
        ("PrepareDependencies", "dependencies", "baseline"),
        ("ConfigureBaseline", "configure", "baseline"),
        ("ConfigurePatched", "configure", "patched"),
        ("BuildIntelSimulator", "build-intel", "patched"),
        ("NativeTransportTests", "listener-tests", "patched"),
    ]:
        args = [root / "venv/bin/python", script, "--work-root", root, action, "--variant", variant]
        quoted = " ".join('"' + str(x).replace('\\', '/').replace('"', '\\"') + '"' for x in args)
        lines.append(f"add_custom_target({target} COMMAND {quoted} USES_TERMINAL VERBATIM)")
    for target in TARGETS:
        lines.append(f'add_custom_target(Dependencies-{target} COMMAND "{root / "venv/bin/python"}" "{script}" --work-root "{root}" dependencies --target {target} USES_TERMINAL VERBATIM)')
    (project / "CMakeLists.txt").write_text("\n".join(lines) + "\n")
    run([root / "venv/bin/cmake", "-G", "Xcode", "-S", project, "-B", root / "prep-xcode"], env=env)
    print("Prepared inputs. Use XcodeBuildMCP on prep-xcode/UmbraNativePreparation.xcodeproj.")


def dependencies(root, selected):
    assert os.environ.get("XCODE_VERSION_ACTUAL"), "Run this stage through the XcodeBuildMCP aggregate"
    check(root)
    env = environment(root)
    for target in TARGETS:
        if selected and target != selected:
            continue
        args = [root / "venv/bin/conan", "install", root / "source-baseline",
                "-of", root / ("deps-" + target), "--build=missing", "--lockfile", LOCK,
                "-pr:h", "default" if target == "macos" else target, "-pr:b", "default",
                "-c", "tools.build:jobs=4", "-c", "tools.cmake.cmaketoolchain:generator=Unix Makefiles"]
        if target == "macos":
            args += ["-c", "nghttp2/*:tools.cmake.cmaketoolchain:extra_variables={'ENABLE_DOC': {'value': False, 'cache': True, 'type': 'BOOL', 'force': True}}"]
        run(args, env=env)


def configure(root, variant):
    assert os.environ.get("XCODE_VERSION_ACTUAL"), "Run this stage through the XcodeBuildMCP aggregate"
    check(root)
    source = root / ("source-" + variant)
    exports = root / "framework-exports.cmake"
    # Xcode's ObjC++ generation otherwise inherits the C++ hidden visibility preset.
    exports.write_text("cmake_language(DEFER CALL set_property TARGET AGDnsProxy PROPERTY CXX_VISIBILITY_PRESET default)\n")
    if variant == "patched":
        assert (root / "framework-macos-baseline/AGDnsProxy.framework/AGDnsProxy").exists(), "Build the clean baseline first"
        assert not source.exists(), "Use a fresh patched checkout"
        run(["git", "clone", "--no-checkout", root / "source-baseline", source])
        run(["git", "-C", source, "checkout", "--detach", SOURCE_PIN])
        run(["git", "-C", source, "apply", PATCH])
    for target, (sdk, arch, deployment) in TARGETS.items():
        build = root / f"framework-{target}-{variant}"
        assert not build.exists(), f"Use a fresh build directory: {build}"
        run([root / "venv/bin/cmake", "-G", "Xcode", "-S", source / "platform/mac/framework", "-B", build,
             "-DCMAKE_TOOLCHAIN_FILE=" + str(root / f"deps-{target}/build/Release/generators/conan_toolchain.cmake"),
             "-DCMAKE_INSTALL_PREFIX=" + str(root / "conan2-install"),
             "-DTARGET_OS=" + ("macos" if target == "macos" else "ios"),
             "-DCMAKE_OSX_SYSROOT=" + sdk, "-DCMAKE_OSX_ARCHITECTURES=" + arch,
             "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + deployment,
             "-DCMAKE_LIBRARY_OUTPUT_DIRECTORY_RELEASE=" + str(build),
             "-DCMAKE_PROJECT_dnsproxy_framework_INCLUDE=" + str(exports),
             "-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO"], env=environment(root))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-root", required=True, type=Path)
    parser.add_argument("action", choices=["prepare", "self-check", "dependencies", "configure", "build-intel", "listener-tests"])
    parser.add_argument("--variant", choices=["baseline", "patched"], default="baseline")
    parser.add_argument("--target", choices=list(TARGETS))
    args = parser.parse_args()
    root = args.work_root.expanduser().resolve()
    if args.action == "prepare":
        prepare(root)
    elif args.action == "self-check":
        check(root)
    elif args.action == "dependencies":
        dependencies(root, args.target)
    elif args.action == "configure":
        configure(root, args.variant)
    else:
        assert os.environ.get("XCODE_VERSION_ACTUAL"), "Run builds/tests through the XcodeBuildMCP aggregate"
        check(root)
        target = "sim-x86" if args.action == "build-intel" else "macos"
        scheme = "AGDnsProxy" if args.action == "build-intel" else "tun_listener_test"
        build = root / f"framework-{target}-patched"
        run([root / "venv/bin/cmake", "--build", build, "--config", "Release", "--target", scheme, "--",
             "CODE_SIGNING_ALLOWED=NO", "GCC_TREAT_WARNINGS_AS_ERRORS=NO",
             "OTHER_CPLUSPLUSFLAGS=$(inherited) -Wno-error=shorten-64-to-32"], env=environment(root))
        if args.action == "listener-tests":
            run([build / "proxy/Release/tun_listener_test", "--gtest_filter=TunListenerTest.*"])


if __name__ == "__main__":
    main()
