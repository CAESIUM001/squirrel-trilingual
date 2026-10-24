#!/usr/bin/env python3
"""Native installer tests in disposable homes; no activation or user hooks.

SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', type=Path, default=here.parent/'build/root/Library/Application Support/Squirrel Trilingual/Current')
    args = parser.parse_args()
    payload = args.payload.resolve()
    helper = payload/'SquirrelInstaller'
    checks = 0

    def check(condition, name):
        nonlocal checks
        if not condition:
            raise AssertionError(name)
        checks += 1

    def put(home, relative, text):
        path = home/relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def install(home, success=True):
        process = subprocess.run([str(helper), '--install', '--payload', str(payload),
                                  '--home', str(home), '--no-activate'], text=True, capture_output=True, timeout=45)
        check((process.returncode == 0) == success, f'install expected success={success}: {process.stdout} {process.stderr}')
        return process

    def snapshot(root):
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob('*') if p.is_file() and not p.is_symlink()}

    with tempfile.TemporaryDirectory(prefix='squirrel-installer-tests-', dir='/private/tmp') as temporary:
        base = Path(temporary)
        fresh = base/'fresh'
        fresh.mkdir()
        install(fresh)
        rime = fresh/'Library/Rime'
        defaults = (rime/'default.custom.yaml').read_text()
        check('schema_list:\n    - schema: rime_ice' in defaults, 'fresh defaults select full pinyin')
        for line in ('menu/page_size: 9', 'Shift_L: commit_code', 'Shift_R: commit_code'):
            check(line in defaults, f'fresh default includes {line}')
        style = (rime/'squirrel.custom.yaml').read_text()
        check('style/candidate_list_layout: linear' in style and 'style/comment_placement: below' in style,
              'fresh horizontal stacked layout')
        check('previously_selected_schema: rime_ice' in (rime/'user.yaml').read_text(), 'fresh selected full pinyin')
        check('lua_processor@*en_gloss*processor' in (rime/'rime_ice.custom.yaml').read_text(), 'full-pinyin French and English hotkey processor installed')
        check((rime/'lua/en_gloss.lua').read_bytes() == (payload/'Rime/lua/en_gloss.lua').read_bytes(), 'delivered Lua installed')
        check((rime/'en_gloss/glossary-en.tsv').is_file(), 'English glossary installed')
        check(not (rime/'build').exists(), 'test mode never runs deployment')
        record = json.loads((fresh/'Library/Application Support/Squirrel Trilingual/last-install.json').read_text())
        check(record['activated'] is False, 'test mode explicitly did not activate')
        manifest = json.loads((Path(record['backup'])/'manifest.json').read_text())
        check(manifest['rime_existed'] is False and manifest['app_existed'] is False, 'fresh state backed up in manifest')

        existing = base/'existing'
        config = '''# Keep this user's comments.
patch:
  schema_list:
    - schema: double_pinyin_sogou
    - schema: my_personal_schema
  menu:
    alternative_select_keys: "asdfghjkl"
    page_size: 5
  ascii_composer:
    good_old_caps_lock: true
    switch_key:
      Control_L: noop
  key_binder/bindings:
    - { when: always, accept: Control+Shift+f, toggle: traditionalization }
'''
        put(existing, 'Library/Rime/default.custom.yaml', config)
        put(existing, 'Library/Rime/squirrel.custom.yaml', '''patch:
  style:
    color_scheme: my_personal_color
    font_point: 23
  app_options:
    org.example.Editor:
      ascii_mode: true
''')
        put(existing, 'Library/Rime/user.yaml', '''installation_id: PERSONAL_FIXTURE_ONLY
var:
  previously_selected_schema: double_pinyin_sogou
  schema_access_time:
    double_pinyin_sogou: 123
''')
        put(existing, 'Library/Rime/rime_ice.custom.yaml', 'patch:\n  translator/enable_sentence: false\n')
        put(existing, 'Library/Rime/en_gloss/custom.tsv', '我自己的词\tmy own words\n')
        put(existing, 'Library/Rime/custom_phrase.txt', '个人短语\tgrdy\n')
        put(existing, 'Library/Rime/my_personal_schema.schema.yaml', 'schema:\n  schema_id: my_personal_schema\n')
        put(existing, 'Library/Rime/rime_ice.userdb/000001.log', 'PRIVATE_FIXTURE_USERDB_BYTES\n')
        put(existing, 'Library/Rime/lua/personal.lua', '-- personal extension\n')
        put(existing, 'Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel', 'ORIGINAL_APP_FIXTURE\n')
        original = snapshot(existing/'Library/Rime')
        install(existing)
        updated = existing/'Library/Rime'
        text = (updated/'default.custom.yaml').read_text()
        check(text.index('schema: rime_ice') < text.index('schema: double_pinyin_sogou') < text.index('schema: my_personal_schema'),
              'full pinyin first with all existing schemas retained')
        for retained in ('alternative_select_keys: "asdfghjkl"', 'good_old_caps_lock: true', 'Control_L: noop', 'toggle: traditionalization'):
            check(retained in text, f'nested user setting preserved: {retained}')
        check('my_personal_color' in (updated/'squirrel.custom.yaml').read_text(), 'personal theme retained')
        check('org.example.Editor:' in (updated/'squirrel.custom.yaml').read_text(), 'app input overrides retained')
        check('installation_id: PERSONAL_FIXTURE_ONLY' in (updated/'user.yaml').read_text(), 'local user identity preserved locally')
        check('previously_selected_schema: rime_ice' in (updated/'user.yaml').read_text(), 'existing session starts full pinyin')
        check('double_pinyin_sogou: 123' in (updated/'user.yaml').read_text(), 'prior schema history retained')
        check('translator/enable_sentence: false' in (updated/'rime_ice.custom.yaml').read_text(), 'custom translator preferences retained')
        for name in ('en_gloss/custom.tsv', 'custom_phrase.txt', 'my_personal_schema.schema.yaml', 'rime_ice.userdb/000001.log', 'lua/personal.lua'):
            check(hashlib.sha256((updated/name).read_bytes()).hexdigest() == original[name], f'personal file unchanged: {name}')
        record = json.loads((existing/'Library/Application Support/Squirrel Trilingual/last-install.json').read_text())
        backup = Path(record['backup'])
        check(snapshot(backup/'Rime') == original, 'full original Rime backup matches byte for byte')
        check((backup/'Squirrel.app/Contents/MacOS/Squirrel').read_text() == 'ORIGINAL_APP_FIXTURE\n', 'original input method backed up')
        before_second = snapshot(updated)
        install(existing)
        check(snapshot(updated) == before_second, 'repeated installation is idempotent for all Rime files')

        fallback = base/'fallback'
        put(fallback, 'Library/Rime/default.yaml', 'schema_list:\n  - schema: my_custom_default\n  - schema: double_pinyin_sogou\n')
        install(fallback)
        text = (fallback/'Library/Rime/default.custom.yaml').read_text()
        check('schema: my_custom_default' in text and 'schema: double_pinyin_sogou' in text, 'base default.yaml schemas preserved without custom schema_list')

        invalid = base/'unsupported-yaml'
        put(invalid, 'Library/Rime/default.custom.yaml', 'patch:\n    schema_list:\n      - schema: personal\n')
        before = snapshot(invalid)
        failed = install(invalid, False)
        check('two-space indentation' in failed.stderr and snapshot(invalid) == before, 'unsupported YAML fails before any mutation')
        check(not (invalid/'Library/Application Support').exists(), 'unsupported configuration does not create backup or run installer')

        symlink_home = base/'home-link'
        symlink_home.symlink_to(fallback, target_is_directory=True)
        before = snapshot(fallback)
        failed = install(symlink_home, False)
        check('alternate home' in failed.stderr and snapshot(fallback) == before, 'symlink alternate home rejected without mutation')

        rollback = base/'rollback'
        put(rollback, 'Library/Rime/default.custom.yaml', 'patch:\n  menu/page_size: 7\n')
        put(rollback, 'Library/Rime/private.userdb/record', 'keep this user database\n')
        put(rollback, 'Library/Input Methods', 'a file, intentionally blocking the app directory\n')
        before = snapshot(rollback/'Library/Rime')
        failed = install(rollback, False)
        check('previous files were restored' in failed.stderr, 'failure reports successful checked recovery')
        check(snapshot(rollback/'Library/Rime') == before, 'post-mutation failure restores every original Rime byte')
        backups = list((rollback/'Library/Application Support/Squirrel Trilingual/Backups').iterdir())
        check(len(backups) == 1 and snapshot(backups[0]/'Rime') == before, 'rollback backup remains recoverable')
    result = {'status': 'passed', 'assertions': checks,
              'helper_sha256': hashlib.sha256(helper.read_bytes()).hexdigest(),
              'scope': 'Disposable temporary homes; no input-source registration, GUI activation, user hooks, or privileged package installation.'}
    (here/'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
