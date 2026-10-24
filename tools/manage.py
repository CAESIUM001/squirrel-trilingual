#!/usr/bin/env python3
"""Install or remove only this extension; preserve existing Rime preferences.

SPDX-License-Identifier: GPL-3.0-or-later
Uses Python's standard library. No network access or third-party dependencies.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from datetime import datetime
from build_index import build_index

ROOT = Path(__file__).resolve().parents[1]
BEGIN = "  # BEGIN rime-english-gloss (managed block)"
END = "  # END rime-english-gloss"
MANAGED = (
    "lua/en_gloss.lua",
    "en_gloss/glossary-en.tsv",
    "en_gloss/glossary-en.idx",
    "en_gloss/UPSTREAM-README.md",
    "en_gloss/provenance.json",
    "en_gloss/LICENSE",
)


def digest(content):
    return hashlib.sha256(content).hexdigest()


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        stream.write(content)
        temporary = Path(stream.name)
    try:
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def patch_block():
    source = (ROOT / "schema-patch.yaml").read_text()
    body = source.split("patch:\n", 1)[1]
    return BEGIN + "\n" + body + END + "\n"


def merge_patch(existing):
    block = patch_block()
    if not existing.strip():
        return "patch:\n" + block
    if BEGIN in existing or END in existing:
        if existing.count(BEGIN) != 1 or existing.count(END) != 1:
            raise ValueError("The managed block markers are damaged; no files changed.")
        start, end = existing.index(BEGIN), existing.index(END) + len(END)
        if end < start:
            raise ValueError("The managed block markers are out of order.")
        return existing[:start] + block.rstrip("\n") + existing[end:]
    if "en_gloss" in existing or "english_gloss" in existing:
        raise ValueError("An unmanaged en_gloss configuration already exists; merge it manually.")
    # Be conservative about arbitrary YAML: a block-style top-level patch map
    # is supported, but inline maps, anchors and scalar patches are not guessed.
    lines = existing.splitlines(keepends=True)
    roots = [i for i, line in enumerate(lines)
             if re.match(r"^patch:\s*(?:#.*)?$", line.rstrip("\n"))]
    if len(roots) != 1:
        raise ValueError("Expected a single block-style 'patch:' map; merge schema-patch.yaml manually.")
    position = roots[0] + 1
    while position < len(lines):
        line = lines[position]
        if line.strip() and not line[0].isspace() and not line.startswith("#"):
            break
        position += 1
    section = lines[roots[0]+1:position]
    meaningful = [line for line in section if line.strip() and not line.lstrip().startswith("#")]
    if meaningful:
        if any("\t" in line[:len(line)-len(line.lstrip())] for line in meaningful):
            raise ValueError("Tabs in YAML indentation; merge the patch manually.")
        if min(len(line)-len(line.lstrip()) for line in meaningful) != 2:
            raise ValueError("Existing patch must use two-space map indentation; merge it manually.")
    for key in ("engine/processors/@before 0", "engine/filters/@next", "switches/@next", "en_gloss"):
        pattern = r"^  [\"']?" + re.escape(key) + r"[\"']?\s*:"
        if any(re.match(pattern, line) for line in section):
            raise ValueError(f"Existing patch already uses {key}; merge it manually to avoid overwriting it.")
    head = "".join(lines[:position])
    if not head.endswith("\n"):
        head += "\n"
    return head + block + "".join(lines[position:])


def squirrel_executable():
    for base in (Path.home() / "Library/Input Methods", Path("/Library/Input Methods")):
        path = base / "Squirrel.app/Contents/MacOS/Squirrel"
        if path.is_file():
            return path
    return None


def reload_squirrel(skip):
    executable = squirrel_executable()
    if not skip and executable:
        subprocess.run([str(executable), "--reload"], check=True)
        print("Requested Squirrel redeployment; verify the compiled build before use.")


def install(args):
    rime = args.rime_dir.expanduser().resolve()
    schema_path = rime / (args.schema + ".schema.yaml")
    if not schema_path.is_file():
        raise ValueError(f"Rime schema not found: {schema_path}")
    custom = rime / (args.schema + ".custom.yaml")
    original = custom.read_bytes() if custom.exists() else None
    replacement = merge_patch(original.decode("utf-8") if original else "").encode()
    provenance = json.loads((ROOT / "en_gloss/provenance.json").read_text())
    glossary = (ROOT / "en_gloss/glossary-en.tsv").read_bytes()
    expected = provenance["files"]["glossary-en.tsv"]["sha256"]
    if digest(glossary) != expected:
        raise ValueError("Bundled dictionary checksum mismatch; nothing installed.")
    if (ROOT / "en_gloss/glossary-en.idx").read_bytes() != build_index(glossary):
        raise ValueError("Bundled dictionary index mismatch; nothing installed.")

    payload = {relative: (ROOT / ("LICENSE" if relative.endswith("/LICENSE") else relative)).read_bytes()
               for relative in MANAGED}
    payload[custom.name] = replacement
    if not (rime / "en_gloss/custom.tsv").exists():
        payload["en_gloss/custom.tsv"] = (ROOT / "en_gloss/custom.tsv").read_bytes()
    backup = rime / "en_gloss-backups" / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup.mkdir(parents=True)
    manifest = {"schema": args.schema, "rime_dir": str(rime), "files": {}}
    for relative, content in payload.items():
        path = rime / relative
        if path.is_symlink():
            raise ValueError(f"Refusing to replace a symlink: {path}")
        existed = path.exists()
        if existed:
            saved = backup / relative
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, saved)
        manifest["files"][relative] = {"existed": existed, "installed_sha256": digest(content)}
    atomic_write(backup / "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2).encode())
    written = []
    try:
        for relative, content in payload.items():
            atomic_write(rime / relative, content)
            written.append(relative)
    except Exception:
        for relative in reversed(written):
            info = manifest["files"][relative]
            if info["existed"]:
                atomic_write(rime / relative, (backup / relative).read_bytes())
            else:
                (rime / relative).unlink(missing_ok=True)
        raise
    print(f"Installed for {args.schema}; offline English entries: {provenance['entries']}")
    print(f"Backup: {backup}")
    reload_squirrel(args.no_reload)


def rollback(args):
    backup = args.backup.expanduser().resolve()
    manifest = json.loads((backup / "manifest.json").read_text())
    rime = Path(manifest["rime_dir"])
    # Validate every path and hash before making any rollback change.
    for relative, info in manifest["files"].items():
        rel = Path(relative)
        if rel.is_absolute() or ".." in rel.parts:
            raise ValueError("Invalid path in backup manifest")
        path = rime / relative
        if path.is_symlink():
            raise ValueError(f"Refusing to replace a symlink: {path}")
        if path.exists() and digest(path.read_bytes()) != info["installed_sha256"]:
            raise ValueError(f"File changed since install; preserve your edits before rollback: {path}")
        if info["existed"] and not (backup / relative).is_file():
            raise ValueError(f"Missing backup: {relative}")
    for relative, info in manifest["files"].items():
        path = rime / relative
        if info["existed"]:
            atomic_write(path, (backup / relative).read_bytes())
        else:
            path.unlink(missing_ok=True)
    print("Restored the pre-install files. The backup itself was retained.")
    reload_squirrel(args.no_reload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("install")
    add.add_argument("--rime-dir", type=Path, default=Path.home() / "Library/Rime")
    add.add_argument("--schema", default="double_pinyin_sogou")
    add.add_argument("--no-reload", action="store_true")
    remove = commands.add_parser("rollback")
    remove.add_argument("backup", type=Path)
    remove.add_argument("--no-reload", action="store_true")
    args = parser.parse_args()
    if getattr(args, "schema", "") and not re.fullmatch(r"[A-Za-z0-9_-]+", args.schema):
        parser.error("Invalid schema name")
    try:
        (install if args.command == "install" else rollback)(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
