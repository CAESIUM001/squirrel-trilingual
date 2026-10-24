#!/usr/bin/env python3
"""Build the local settings helper; no install, launch, or language download.

SPDX-License-Identifier: GPL-3.0-or-later
Requires Xcode Command Line Tools / SDK with Apple's Translation framework.
"""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    output = (args.output or source.parent / "Translation Setup.app").resolve()
    executable = output / "Contents/MacOS/TranslationSetup"
    executable.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="translation-setup-swift-") as cache:
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-O", "-target", "arm64-apple-macos13.0",
            "-module-cache-path", cache,
            str(source / "SquirrelSentenceTranslator.swift"),
            str(source / "TranslationSetupMain.swift"), "-o", str(executable)
        ], check=True)
    info = {
        "CFBundleExecutable": "TranslationSetup",
        "CFBundleIdentifier": "org.rime.english-gloss.translation-setup",
        "CFBundleName": "Translation Setup",
        "CFBundleDisplayName": "中英法离线翻译设置",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.4.0",
        "CFBundleVersion": "4",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    (output / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(output)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(output)], check=True)
    print(output)


if __name__ == "__main__":
    main()
