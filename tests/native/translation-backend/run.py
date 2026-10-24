#!/usr/bin/env python3
"""Run 32 targeted translation-backend checks without touching Rime or real input.

Requires macOS 15+, Xcode, a logged-in GUI session, and installed Chinese,
French and English Apple Translation models. No language download is requested.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="SquirrelSentenceTranslator.swift to compile")
    parser.add_argument("--output", type=Path, help="Result directory (defaults beside this script)")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    package = here.parents[2]
    candidates = [package / "frontend/source/sources/SquirrelSentenceTranslator.swift"]
    source = args.source or next((path for path in candidates if path.exists()), None)
    if source is None or not source.is_file():
        parser.error("Specify the current SquirrelSentenceTranslator.swift using --source")
    output = (args.output or here).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rime-translation-backend-") as temporary:
        temp = Path(temporary)
        app = temp / "DictionaryChecks.app/Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "Resources").mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "DictionaryChecks",
            "CFBundleIdentifier": "org.rime.tests.dictionary-checks",
            "CFBundlePackageType": "APPL",
        }))
        # Fixture words exercise both exact lookup and traditional-to-simplified
        # fallback. Oversized total fixture values force the 2 MiB LRU limit.
        fixture = "# temporary test fixture only\n学习\tÉtude\n图书馆\tBibliothèque\n"
        fixture += "".join(f"测试字{index}\t" + "bonjour " * 265 + "\n" for index in range(1100))
        (app / "Resources/glossary-fr.tsv").write_text(fixture, encoding="utf-8")
        cases = [
            ("DictionaryChecks.swift", app / "MacOS/DictionaryChecks", "dictionary-checks.json", 20),
            ("BackendChecks.swift", temp / "BackendChecks", "backend-checks.json", 12),
        ]
        for test, executable, filename, expected in cases:
            subprocess.run([
                "xcrun", "swiftc", "-parse-as-library", "-O", "-target", "arm64-apple-macos13.0",
                "-module-cache-path", str(temp / "module-cache"), str(source.resolve()),
                str(here / test), "-o", str(executable),
            ], check=True)
            process = subprocess.run([str(executable)], text=True, capture_output=True, timeout=40)
            records = [json.loads(line) for line in process.stdout.splitlines() if line.startswith("{")]
            if not records:
                raise RuntimeError(f"{test}: no result; {process.stdout}\n{process.stderr}")
            result = records[-1]
            (output / filename).write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            if process.returncode or result.get("assertions") != expected or result.get("failures"):
                raise RuntimeError(f"{test} failed: {result}\n{process.stderr}")
            print(f"{test}: {expected} assertions passed")
    print(f"All 32 checks passed; results: {output}")


if __name__ == "__main__":
    main()
