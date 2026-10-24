"""Installer regressions: preserving existing config and safe reversible writes."""
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
spec = importlib.util.spec_from_file_location("manage", ROOT / "tools/manage.py")
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


class InstallerTests(unittest.TestCase):
    def test_preserve_existing_patch_and_other_roots(self):
        original = '# personal\npatch:\n  menu/page_size: 9\nother: keep\n'
        merged = manage.merge_patch(original)
        self.assertIn('  menu/page_size: 9\n', merged)
        self.assertTrue(merged.endswith('other: keep\n'))
        self.assertEqual(manage.merge_patch(merged), merged)
        self.assertEqual(merged.count(manage.BEGIN), 1)

    def test_reject_inline_map_and_nonstandard_indent(self):
        for text in ('patch: {menu/page_size: 9}\n', 'patch:\n    menu/page_size: 9\n'):
            with self.assertRaises(ValueError):
                manage.merge_patch(text)

    def test_reject_existing_list_patch_collision(self):
        for key in ('engine/filters/@next', 'engine/processors/@before 0', 'switches/@next'):
            with self.assertRaises(ValueError):
                manage.merge_patch(f'patch:\n  "{key}": other_plugin\n')

    def test_install_rollback_preserves_user_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            rime = Path(directory)
            (rime/'double_pinyin_sogou.schema.yaml').write_text('schema: {}\n')
            original = b'patch:\n  menu/page_size: 9\n'
            (rime/'double_pinyin_sogou.custom.yaml').write_bytes(original)
            (rime/'default.custom.yaml').write_text('user defaults\n')
            (rime/'squirrel.custom.yaml').write_text('user style\n')
            (rime/'en_gloss').mkdir()
            custom = b'custom\tmy translation\n'
            (rime/'en_gloss/custom.tsv').write_bytes(custom)
            manage.install(SimpleNamespace(rime_dir=rime, schema='double_pinyin_sogou', no_reload=True))
            self.assertEqual((rime/'default.custom.yaml').read_text(), 'user defaults\n')
            self.assertEqual((rime/'squirrel.custom.yaml').read_text(), 'user style\n')
            self.assertEqual((rime/'en_gloss/custom.tsv').read_bytes(), custom)
            backup = next((rime/'en_gloss-backups').iterdir())
            manage.rollback(SimpleNamespace(backup=backup, no_reload=True))
            self.assertEqual((rime/'double_pinyin_sogou.custom.yaml').read_bytes(), original)
            self.assertFalse((rime/'lua/en_gloss.lua').exists())
            self.assertEqual((rime/'en_gloss/custom.tsv').read_bytes(), custom)

    def test_rollback_refuses_later_user_changes_before_touching_files(self):
        with tempfile.TemporaryDirectory() as directory:
            rime = Path(directory)
            (rime/'double_pinyin_sogou.schema.yaml').write_text('schema: {}\n')
            manage.install(SimpleNamespace(rime_dir=rime, schema='double_pinyin_sogou', no_reload=True))
            backup = next((rime/'en_gloss-backups').iterdir())
            changed = rime/'double_pinyin_sogou.custom.yaml'
            changed.write_text(changed.read_text()+'  custom_option: 1\n')
            with self.assertRaises(ValueError):
                manage.rollback(SimpleNamespace(backup=backup, no_reload=True))
            self.assertTrue((rime/'lua/en_gloss.lua').exists())
            self.assertTrue(changed.read_text().endswith('  custom_option: 1\n'))


if __name__ == '__main__':
    unittest.main()
