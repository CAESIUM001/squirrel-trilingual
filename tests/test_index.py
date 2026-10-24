"""Sparse-index boundary and corruption checks.

SPDX-License-Identifier: GPL-3.0-or-later
"""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from build_index import build_index


class IndexTests(unittest.TestCase):
    def test_every_block_covers_exact_original_rows(self):
        data = (ROOT / "en_gloss/glossary-en.tsv").read_bytes()
        expected = build_index(data)
        self.assertEqual((ROOT / "en_gloss/glossary-en.idx").read_bytes(), expected)
        reconstructed = []
        for line in expected.splitlines()[1:]:
            word, offset, length = line.split(b"\t")
            block = data[int(offset):int(offset) + int(length)]
            first = next(row for row in block.splitlines() if not row.startswith(b"#"))
            self.assertEqual(word, first.split(b"\t", 1)[0])
            self.assertLessEqual(len(block.splitlines()), 128)
            reconstructed.append(block)
        self.assertEqual(b"".join(reconstructed), data)

    def test_reject_unsorted_duplicate_and_invalid_rows(self):
        for data in (b"b\tB\na\tA\n", b"a\tA\na\tB\n", b"a\tA",
                     b"a\tA\r\n", b"a\n"):
            with self.assertRaises(ValueError):
                build_index(data)


if __name__ == "__main__":
    unittest.main()
