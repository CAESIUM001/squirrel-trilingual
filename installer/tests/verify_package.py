#!/usr/bin/env python3
"""Expand and inspect a pkg without installing it. SPDX-License-Identifier: GPL-3.0-or-later"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('expanded', type=Path, help='New directory for pkgutil --expand-full')
    args = parser.parse_args()
    subprocess.run(['pkgutil', '--expand-full', str(args.package), str(args.expanded)], check=True)
    info = ET.parse(args.expanded/'Squirrel-Trilingual-component.pkg/PackageInfo').getroot()
    distribution = ET.parse(args.expanded/'Distribution').getroot()
    checks = 0

    def check(condition, label):
        nonlocal checks
        if not condition:
            raise AssertionError(label)
        checks += 1

    check(info.get('relocatable') == 'false', 'package must not relocate bundles')
    check(info.find('relocate') is not None and len(info.find('relocate')) == 0, 'no relocate instructions')
    prefix = './Library/Application Support/Squirrel Trilingual/Current/'
    bundles = info.findall('bundle')
    check(bool(bundles) and all(bundle.get('path', '').startswith(prefix) for bundle in bundles), 'all app bundles staged at fixed payload path')
    check(len(info.find('bundle-version')) == 0, 'exact staged app versions always replace old staged payload')
    check({entry.get('id') for entry in info.findall('strict-identifier/bundle')} == {entry.get('id') for entry in bundles},
          'strict bundle identity for every embedded bundle')
    check(distribution.find('options').get('hostArchitectures') == 'arm64', 'arm64 installation restriction')
    check(distribution.find('allowed-os-versions/os-version').get('min') == '15.0', 'macOS 15 minimum')
    payload = args.expanded/'Squirrel-Trilingual-component.pkg/Payload/Library/Application Support/Squirrel Trilingual/Current'
    for name in ('Squirrel.app', 'Translation Setup.app', 'SquirrelInstaller'):
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(payload/name)], check=True)
        check(True, f'extracted signature: {name}')
    manifest = json.loads((payload/'payload-manifest.json').read_text())
    for relative, expected in manifest['files'].items():
        check(hashlib.sha256((payload/relative).read_bytes()).hexdigest() == expected, f'payload checksum: {relative}')
    licenses = payload/'licenses/third_party'
    provenance = json.loads((licenses/'sources.json').read_text())
    check(len(provenance['files']) == 13, 'all thirteen runtime copyright/license files included')
    for entry in provenance['files']:
        check(hashlib.sha256((licenses/entry['file']).read_bytes()).hexdigest() == entry['sha256'], f'license checksum: {entry["file"]}')
    script = args.expanded/'Squirrel-Trilingual-component.pkg/Scripts/postinstall'
    subprocess.run(['/bin/sh', '-n', str(script)], check=True)
    check('launchctl asuser' in script.read_text() and 'sudo -H -u' in script.read_text(), 'native helper runs as console user')
    check('python' not in script.read_text().lower(), 'recipient needs no Python')
    result = {'status': 'passed', 'assertions': checks,
              'package_sha256': hashlib.sha256(args.package.read_bytes()).hexdigest(),
              'helper_sha256': hashlib.sha256((payload/'SquirrelInstaller').read_bytes()).hexdigest(),
              'relocatable': False, 'signed_package': False, 'notarized': False,
              'scope': 'Package expansion and content/signature verification only; package not installed.'}
    (Path(__file__).parent/'package-results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))
    print(f'Extracted payload: {payload.resolve()}')


if __name__ == '__main__':
    main()
