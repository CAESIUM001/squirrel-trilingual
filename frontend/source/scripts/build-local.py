#!/usr/bin/env python3
"""Build a local Squirrel app using matching official runtime dependencies.

SPDX-License-Identifier: GPL-3.0-or-later
This script never installs, launches normally, or explicitly registers an input source.
Xcode may automatically update LaunchServices for the generated bundle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(app):
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    version = info.get("CFBundleShortVersionString", info.get("CFBundleVersion"))
    if version != "1.1.2":
        raise ValueError(f"Expected official Squirrel 1.1.2 runtime, found {version!r}")
    for path in (ROOT / "librime/src/rime_api_stdbool.h", ROOT / "Sparkle/Sparkle/Sparkle.h"):
        if not path.is_file():
            raise ValueError("The vendored Sparkle/librime headers are missing; obtain the complete source checkout or archive.")
    for directory in (ROOT / "bin", ROOT / "lib"):
        directory.mkdir(exist_ok=True)
    framework = ROOT / "Frameworks/Sparkle.framework"
    framework.parent.mkdir(exist_ok=True)
    # This generated dependency copy contains symlinks; replace the workspace
    # copy so repeating preparation is safe and cannot retain stale headers.
    if framework.exists():
        shutil.rmtree(framework)
    shutil.copytree(contents / "Frameworks/Sparkle.framework", framework,
                    symlinks=True, dirs_exist_ok=True)
    headers = framework / "Versions/B/Headers"
    headers.mkdir(exist_ok=True)
    for source in (ROOT / "Sparkle/Sparkle").glob("*.h"):
        shutil.copy2(source, headers / source.name)
    modules = framework / "Versions/B/Modules"
    modules.mkdir(exist_ok=True)
    (modules / "module.modulemap").write_text(
        'framework module Sparkle {\n  umbrella header "Sparkle.h"\n'
        '  export *\n  module * { export * }\n}\n')
    for name in ("Headers", "Modules"):
        link = framework / name
        if not link.exists():
            link.symlink_to("Versions/Current/" + name)
    shutil.copy2(contents / "Frameworks/librime.1.dylib", ROOT / "lib/librime.1.dylib")
    shutil.copytree(contents / "Frameworks/rime-plugins", ROOT / "lib/rime-plugins", dirs_exist_ok=True)
    for name in ("rime_deployer", "rime_dict_manager", "rime-install"):
        shutil.copy2(contents / "MacOS" / name, ROOT / "bin" / name)
    (ROOT / "data/plum").mkdir(exist_ok=True)
    for source in (contents / "SharedSupport").iterdir():
        if source.is_file() and source.name != "squirrel.yaml":
            shutil.copy2(source, ROOT / "data/plum" / source.name)
    shutil.copytree(contents / "SharedSupport/opencc", ROOT / "data/opencc", dirs_exist_ok=True)
    provenance = {
        "source": "https://github.com/rime/squirrel/tree/1.1.2",
        "squirrel_commit": "876adebaf2f612951dcdca8a591de65401222b9a",
        "librime_commit": "a251145d3aafa33871824a40bbec04c966bd8b56",
        "sparkle_commit": "41847a58cdef7506b257591fcca6f9495df591d4",
        "official_runtime_version": version,
        "runtime_sha256": {
            "librime.1.dylib": sha256(contents / "Frameworks/librime.1.dylib"),
            "Sparkle": sha256(contents / "Frameworks/Sparkle.framework/Versions/B/Sparkle"),
        },
    }
    (ROOT / "LOCAL-DEPENDENCIES.json").write_text(json.dumps(provenance, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--official-app", type=Path,
                        default=Path.home() / "Library/Input Methods/Squirrel.app")
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Release")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    prepare(args.official_app)
    if args.prepare_only:
        print("Prepared matching official libraries and headers.")
        return
    log = ROOT / ("build-local-" + args.configuration.lower() + ".log")
    command = ["xcodebuild", "-project", "Squirrel.xcodeproj", "-scheme", "Squirrel",
               "-configuration", args.configuration, "-derivedDataPath", "build",
               "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO",
               "COMPILER_INDEX_STORE_ENABLE=NO", "build"]
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    built = ROOT / "build/Build/Products" / args.configuration / "Squirrel.app"
    if result.returncode:
        lines = log.read_text(errors="replace").splitlines()
        errors = [line for line in lines if "error:" in line]
        print("\n".join(errors[-20:] or [line[:300] for line in lines[-12:]]))
        raise SystemExit(f"Build failed; inspect {log}")
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(built)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements",
                    str(ROOT / "resources/Squirrel.entitlements"), str(built)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(built)], check=True)
    # --help returns before input server creation and does not touch user data.
    subprocess.run([str(built / "Contents/MacOS/Squirrel"), "--help"], check=True,
                   stdout=subprocess.DEVNULL)
    print(f"Built and ad-hoc signed: {built}")
    print(f"Build log: {log}")
    print("Xcode may have refreshed LaunchServices for this build. After installation, "
          "run the installed app's --register-input-source command; never unregister "
          "a same-bundle-ID build with lsregister -u.")


if __name__ == "__main__":
    main()
