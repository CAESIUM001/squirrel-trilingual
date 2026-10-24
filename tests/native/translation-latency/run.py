#!/usr/bin/env python3
"""Measure actual on-device translation with the shipped static dictionary.

Uses a separate helper bundle; never launches or registers the input method.
SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

test = Path(__file__).resolve().parent
root = test.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sources', type=Path, default=root/'frontend/source/sources')
parser.add_argument('--glossary', type=Path, default=root/'frontend/source/resources/glossary-fr.tsv')
args = parser.parse_args()
source = args.sources.resolve()/'SquirrelSentenceTranslator.swift'
with tempfile.TemporaryDirectory(prefix='squirrel-french-latency-') as temp:
    temp = Path(temp)
    app = temp/'LatencyProbe.app'
    executable = app/'Contents/MacOS/LatencyProbe'
    executable.parent.mkdir(parents=True)
    resources = app/'Contents/Resources'
    resources.mkdir()
    shutil.copy2(args.glossary, resources/'glossary-fr.tsv')
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier':'org.rime.french-latency-probe',
        'CFBundleExecutable':'LatencyProbe', 'CFBundlePackageType':'APPL',
        'LSUIElement':True, 'LSMinimumSystemVersion':'15.0'}))
    subprocess.run(['xcrun','swiftc','-parse-as-library','-O','-D','OPTIMIZED',
                    '-module-cache-path',str(temp/'module-cache'),str(source),
                    str(test/'LatencyProbe.swift'),'-o',str(executable)],check=True)
    process = subprocess.run([str(executable)],capture_output=True,text=True,timeout=50)
    if process.returncode:
        raise SystemExit(process.stderr + process.stdout)
    result = json.loads(process.stdout)
    assert result['cases'][0]['cached_count'] == 9
    assert result['cases'][1]['cached_count'] == 8
    assert result['cases'][2]['cached_count'] == 9
    result['scope'] = 'Fixed examples, actual Apple model and shipped dictionary; excludes controller debounce and host-app rendering. Model service may already be warm.'
    result['source_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
    result['glossary_sha256'] = hashlib.sha256(args.glossary.read_bytes()).hexdigest()
    (test/'results.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps(result,indent=2,ensure_ascii=False))
