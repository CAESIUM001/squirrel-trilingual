#!/usr/bin/env python3
"""Build a deterministic sparse byte-offset index for the unchanged glossary.

SPDX-License-Identifier: GPL-3.0-or-later
"""
import hashlib
from pathlib import Path

BLOCK_ROWS = 128


def build_index(data, block_rows=BLOCK_ROWS):
    if block_rows < 1:
        raise ValueError("block_rows must be positive")
    rows = data.splitlines(keepends=True)
    result = [f"# en-gloss-index-v1\t{hashlib.sha256(data).hexdigest()}\t{len(data)}\n"]
    offset, previous = 0, None
    for position in range(0, len(rows), block_rows):
        chunk = rows[position:position + block_rows]
        words = []
        for row in chunk:
            if row.startswith(b"#"):
                continue
            if not row.endswith(b"\n") or b"\t" not in row or b"\r" in row:
                raise ValueError("Expected LF-terminated TSV rows")
            word = row.split(b"\t", 1)[0]
            word.decode("utf-8")
            if not word or (previous is not None and word <= previous):
                raise ValueError("Glossary keys must be unique and sorted by UTF-8 bytes")
            previous = word
            words.append(word)
        size = sum(map(len, chunk))
        if size > 65536:
            raise ValueError("Index block exceeds the runtime read limit")
        if not words:
            raise ValueError("A glossary block must contain a data entry")
        first = words[0].decode("utf-8")
        result.append(f"{first}\t{offset}\t{size}\n")
        offset += size
    return "".join(result).encode("utf-8")


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    source = root / "en_gloss/glossary-en.tsv"
    destination = source.with_suffix(".idx")
    destination.write_bytes(build_index(source.read_bytes()))
    print(f"Wrote {destination.name}")
