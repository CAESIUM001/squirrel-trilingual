#!/usr/bin/env python3
"""Verify the staged installer using a temporary home and the real Rime engine.

Does not register, launch, or replace the current user's input method.
Requires the build Mac's Xcode command line tools, not the recipient Mac.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', required=True, type=Path)
    parser.add_argument('--results', required=True, type=Path)
    args = parser.parse_args()
    payload = args.payload.resolve()
    native = Path(__file__).resolve().parent
    checks = []

    def check(value, description):
        checks.append({'check': description, 'passed': bool(value)})
        if not value:
            raise AssertionError(description)

    with tempfile.TemporaryDirectory(prefix='squirrel-full-pinyin-', dir='/private/tmp') as temporary:
        work = Path(temporary) / 'work'
        work.mkdir()
        home = work / 'home'
        home.mkdir()
        installed = subprocess.run([str(payload / 'SquirrelInstaller'), '--install', '--payload', str(payload),
                                    '--home', str(home), '--no-activate'], capture_output=True, text=True)
        if installed.returncode:
            raise RuntimeError(installed.stdout + installed.stderr)
        rime = home / 'Library/Rime'
        app = home / 'Library/Input Methods/Squirrel.app'
        shared = app / 'Contents/SharedSupport'
        frameworks = app / 'Contents/Frameworks'
        deployed = subprocess.run([str(app / 'Contents/MacOS/rime_deployer'), '--build',
                                  str(rime), str(shared), str(rime / 'build')],
                                 capture_output=True, text=True, check=True)
        check('Error loading module' not in deployed.stderr, 'fresh Rime deployment loads Lua')
        probe = work / 'probe'
        subprocess.run(['clang', '-std=c11', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra',
                        str(native / 'probe.c'), '-o', str(probe)], check=True)
        environment = dict(os.environ, RIME_PROBE_FRAMEWORKS=str(frameworks))

        def run(*actions):
            process = subprocess.run([str(probe), str(rime), str(shared), 'rime_ice', *actions],
                                     env=environment, text=True, capture_output=True, check=True)
            return [json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]

        rows = run('input:beijing', 'key:49:8')
        check(rows[0]['schema'] == 'rime_ice', 'full-pinyin schema loads')
        check(rows[1]['page_size'] == 9, 'nine candidates')
        check(rows[1]['candidates'][0] == {'text': '北京', 'comment': 'n. Beijing'},
              'full-pinyin Beijing has English gloss')
        check(rows[2].get('commit') == 'Beijing', 'Option+1 commits English')
        rows = run('input:nihao', 'key:32:0')
        check(rows[-1].get('commit') == '你好', 'normal full-pinyin Chinese commit')
        rows = run('input:jintianxiawuwomenyiqiqutushuguan')
        check(rows[-1]['candidates'][0]['text'] == '今天下午我们一起去图书馆',
              'complete sentence composes using full pinyin')
        rows = run('key:65505:1', 'key:65505:1073741824',
                   'key:65506:1', 'key:65506:1073741824')
        check(rows[2]['ascii'] is True and rows[4]['ascii'] is False,
              'both Shift keys toggle Chinese/English')
        style = (rime / 'squirrel.custom.yaml').read_text()
        check('style/candidate_list_layout: linear' in style and 'style/comment_placement: below' in style,
              'horizontal candidates and stacked translations configured')
        french = app / 'Contents/Resources/glossary-fr.tsv'
        check(french.is_file(), 'offline French glossary bundled')
        check(hashlib.sha256(french.read_bytes()).hexdigest() ==
              '27da5a13c1841eea403fdc0aab15d0e1ee6c5cbffd3302cfbcd9d9ad2d30f45f',
              'French glossary matches the validated 5000-entry asset')
    result = {'status': 'passed', 'assertions': len(checks), 'checks': checks,
              'helper_sha256': hashlib.sha256((payload / 'SquirrelInstaller').read_bytes()).hexdigest(),
              'frontend_sha256': hashlib.sha256((payload / 'Squirrel.app/Contents/MacOS/Squirrel').read_bytes()).hexdigest(),
              'scope': 'isolated installer plus real Rime engine; no system registration or host UI'}
    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.results.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
