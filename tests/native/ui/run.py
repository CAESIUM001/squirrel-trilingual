#!/usr/bin/env python3
"""Render the actual frontend UI offscreen; --live adds real Apple translation.
SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
test = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--live", action="store_true")
parser.add_argument("--sources", type=Path, default=root / "frontend/source/sources")
args = parser.parse_args()
source = args.sources.resolve()
(root / "preview").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="squirrel-panel-check-") as folder:
    folder = Path(folder)
    helpers = (source / "BridgingFunctions.swift").read_text()
    (folder / "Helpers.swift").write_text("import AppKit\n" + helpers[helpers.index("infix operator ?="):])
    panel = (source / "SquirrelPanel.swift").read_text().replace(
        "orderFront(nil)", "// Offscreen test only; do not activate a candidate window.")
    (folder / "SquirrelPanel.swift").write_text(panel)
    files = [folder / "Helpers.swift", test / "Support.swift", folder / "SquirrelPanel.swift",
             source / "SquirrelView.swift", source / "SquirrelTheme.swift"]
    if args.live:
        files += [source / "SquirrelSentenceTranslator.swift", test / "LiveTranslationPanelProbe.swift"]
    else:
        files.append(test / "main.swift")
    subprocess.run(["xcrun", "swiftc", "-enable-bare-slash-regex", "-module-cache-path",
                    str(folder / "module-cache"), *map(str, files), "-o", str(folder / "probe")], check=True)
    subprocess.run([str(folder / "probe")], cwd=root, check=True)
