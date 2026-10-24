#!/usr/bin/env python3
"""Build a self-contained macOS pkg. Python is needed only on the build Mac.

SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import xml.sax.saxutils as xml


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    here = Path(__file__).resolve().parent
    repo = here.parent
    workspace = here.parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='0.4.0')
    parser.add_argument('--squirrel-app', type=Path,
                        default=workspace/'outputs/rime-english-gloss/frontend/Squirrel.app')
    parser.add_argument('--setup-app', type=Path,
                        default=workspace/'outputs/rime-english-gloss/Translation Setup.app')
    parser.add_argument('--output', type=Path, default=here/'dist')
    parser.add_argument('--stage-only', action='store_true')
    args = parser.parse_args()
    if not args.version or any(c not in '0123456789.' for c in args.version):
        parser.error('version must contain only digits and dots')
    build = here/'build'
    if build.exists():
        shutil.rmtree(build)
    build.mkdir()
    root = build/'root'
    payload = root/'Library/Application Support/Squirrel Trilingual/Current'
    payload.mkdir(parents=True)
    for source, name in ((args.squirrel_app, 'Squirrel.app'), (args.setup_app, 'Translation Setup.app')):
        source = source.expanduser().resolve()
        if not source.is_dir():
            raise SystemExit(f'Missing {source}; use --squirrel-app / --setup-app with built app bundles.')
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', source)
        run('/usr/bin/ditto', source, payload/name)
    rime = payload/'Rime'
    shutil.copytree(here/'assets/Rime', rime)
    shutil.copy2(repo/'lua/en_gloss.lua', rime/'lua/en_gloss.lua')
    shutil.copytree(repo/'en_gloss', rime/'en_gloss')
    shutil.copy2(repo/'LICENSE', rime/'en_gloss/LICENSE')
    # Full source/data licences accompany the binary installer, even when
    # upstream app resources contain only a shorter subset of notices.
    licenses = payload/'licenses'
    licenses.mkdir()
    for name in ('LICENSE', 'NOTICE.md'):
        if not (repo/name).is_file():
            raise SystemExit(f'Required distribution notice missing: {repo/name}')
        shutil.copy2(repo/name, licenses/name)
    shutil.copy2(here/'assets/Rime/LICENSE', licenses/'Rime-Ice-LICENSE')
    third_party = repo/'third_party'
    if not (third_party/'sources.json').is_file() or not (third_party/'licenses').is_dir():
        raise SystemExit('Required runtime dependency licenses are missing from third_party/.')
    shutil.copytree(third_party, licenses/'third_party')
    frontend = repo/'frontend/source'
    for source in frontend.rglob('*'):
        if source.is_file() and ('license' in source.name.lower() or source.name.lower().startswith('copying')):
            destination = licenses/'frontend'/source.relative_to(frontend)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    helper = payload/'SquirrelInstaller'
    run('xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macos15.0',
        '-module-cache-path', build/'module-cache', here/'Installer.swift', '-o', helper)
    run('/usr/bin/codesign', '--force', '--sign', '-', helper)
    run('/usr/bin/codesign', '--verify', '--strict', helper)
    shutil.copy2(here/'assets/Rime-provenance.json', payload/'Rime-provenance.json')
    inventory = {}
    for file in payload.rglob('*'):
        if file.is_file() and not file.is_symlink():
            inventory[str(file.relative_to(payload))] = hashlib.sha256(file.read_bytes()).hexdigest()
    (payload/'payload-manifest.json').write_text(json.dumps({'version': args.version, 'files': inventory},
                                                          ensure_ascii=False, indent=2)+'\n')
    (build/'stage.json').write_text(json.dumps({'payload': str(payload), 'version': args.version}, indent=2)+'\n')
    print(f'Staged payload: {payload}', flush=True)
    if args.stage_only:
        return
    args.output.mkdir(parents=True, exist_ok=True)
    scripts = build/'scripts'
    shutil.copytree(here/'scripts', scripts)
    for script in scripts.iterdir():
        script.chmod(0o755)
    component = build/'Squirrel-Trilingual-component.pkg'
    components = build/'components.plist'
    run('/usr/bin/pkgbuild', '--analyze', '--root', root, components)
    entries = plistlib.loads(components.read_bytes())
    def fixed_locations(value):
        if isinstance(value, dict):
            if 'RootRelativeBundlePath' in value:
                value['BundleIsRelocatable'] = False
                value['BundleIsVersionChecked'] = False
                value['BundleHasStrictIdentifier'] = True
                value['BundleOverwriteAction'] = 'upgrade'
            for child in value.values():
                fixed_locations(child)
        elif isinstance(value, list):
            for child in value:
                fixed_locations(child)
    fixed_locations(entries)
    components.write_bytes(plistlib.dumps(entries))
    run('/usr/bin/pkgbuild', '--root', root, '--scripts', scripts,
        '--component-plist', components,
        '--identifier', 'org.rime.squirrel.trilingual.fullpinyin', '--version', args.version,
        '--install-location', '/', '--ownership', 'recommended', component)
    # Restrict to the architecture/runtime actually built and tested. Apple
    # Translation is unavailable before macOS 15.
    distribution = build/'Distribution.xml'
    distribution.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>鼠须管伴词 · 全拼</title>
  <options customize="never" require-scripts="true" hostArchitectures="arm64"/>
  <allowed-os-versions><os-version min="15.0"/></allowed-os-versions>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <license file="LICENSE"/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" visible="false"><pkg-ref id="org.rime.squirrel.trilingual.fullpinyin"/></choice>
  <pkg-ref id="org.rime.squirrel.trilingual.fullpinyin" version="{xml.escape(args.version)}" onConclusion="none">{component.name}</pkg-ref>
</installer-gui-script>
''')
    resources = build/'resources'
    resources.mkdir()
    shutil.copy2(repo/'LICENSE', resources/'LICENSE')
    output = args.output/f'Squirrel-Trilingual-{args.version}-macOS-arm64.pkg'
    run('/usr/bin/productbuild', '--distribution', distribution, '--resources', resources,
        '--package-path', build, output)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    (args.output/(output.name+'.sha256')).write_text(f'{digest}  {output.name}\n')
    print(json.dumps({'package': str(output), 'sha256': digest, 'signed': False,
                      'notarized': False, 'architecture': 'arm64', 'minimum_macos': '15.0'}))


if __name__ == '__main__':
    main()
