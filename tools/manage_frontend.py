#!/usr/bin/env python3
"""Install/restore the locally built multilingual Squirrel frontend with a backup.

SPDX-License-Identifier: GPL-3.0-or-later
Refreshes the installed bundle's LS/TIS registration while preserving input modes.
Does not change Chinese dictionaries.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

from manage import atomic_write
from register_legacy_frontend import refresh_legacy_registration, read_input_source_status

BEGIN = "  # BEGIN rime-english-gloss frontend"
END = "  # END rime-english-gloss frontend"
BLOCK = BEGIN + "\n  style/comment_placement: below\n  style/stacked_comment_max_width: 220\n" + END


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tree_hash(path):
    digest = hashlib.sha256()
    for item in sorted(path.rglob("*")):
        relative = str(item.relative_to(path))
        if item.is_symlink():
            content = b"symlink:" + os.readlink(item).encode()
        elif item.is_file():
            content = item.read_bytes()
        else:
            continue
        digest.update(relative.encode() + b"\0" + hashlib.sha256(content).digest())
    return digest.hexdigest()


def merged_style(text):
    if BEGIN in text or END in text:
        if text.count(BEGIN) != 1 or text.count(END) != 1 or text.index(END) < text.index(BEGIN):
            raise ValueError("Frontend configuration markers are damaged")
        return text[:text.index(BEGIN)] + BLOCK + text[text.index(END) + len(END):]
    if not text.strip():
        return "patch:\n" + BLOCK + "\n"
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if re.fullmatch(r"patch:\s*(?:#.*)?\n?", line)]
    if len(starts) != 1:
        raise ValueError("Expected a block-style patch map; no changes made")
    end = starts[0] + 1
    while end < len(lines) and (not lines[end].strip() or lines[end][0].isspace() or lines[end].startswith("#")):
        end += 1
    meaningful = [line for line in lines[starts[0]+1:end] if line.strip() and not line.lstrip().startswith("#")]
    if meaningful and min(len(line)-len(line.lstrip()) for line in meaningful) != 2:
        raise ValueError("Expected two-space patch indentation")
    if any(re.search(r"comment_placement|stacked_comment_max_width", line) for line in meaningful):
        raise ValueError("Existing custom comment layout requires manual merge")
    head = "".join(lines[:end]).rstrip("\n")
    return head + "\n" + BLOCK + "\n" + "".join(lines[end:])


def verify_bundle(path):
    if path.is_symlink():
        raise ValueError("Refusing a symlink app path")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "im.rime.inputmethod.Squirrel":
        raise ValueError("Not the expected Squirrel application bundle")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)], check=True)


def stop(app):
    executable = app / "Contents/MacOS/Squirrel"
    subprocess.run([str(executable), "--quit"], check=True)
    pattern = "^" + re.escape(str(executable)) + "($| )"
    for _ in range(40):
        status = subprocess.run(["/usr/bin/pgrep", "-f", pattern], capture_output=True)
        if status.returncode == 1:
            return
        if status.returncode != 0:
            raise RuntimeError("Could not confirm that Squirrel stopped")
        time.sleep(0.1)
    raise RuntimeError("Squirrel did not stop; existing app was left intact")


def validate_registration(result, app):
    expected_modes = {"im.rime.inputmethod.Squirrel.Hans", "im.rime.inputmethod.Squirrel.Hant"}
    before = set(result.get("enabledModesBefore", [])) if isinstance(result, dict) else set()
    desired_enabled = before or {"im.rime.inputmethod.Squirrel.Hans"}
    valid = (isinstance(result, dict) and result.get("protocolVersion") == 1
             and result.get("success") is True
             and result.get("launchServicesStatus") == 0
             and result.get("textInputSourceStatus") == 0
             and Path(result.get("appPath", "")).resolve() == app.resolve()
             and set(result.get("registeredModes", [])) == expected_modes
             and before <= expected_modes
             and set(result.get("expectedEnabledModes", [])) == desired_enabled
             and set(result.get("enabledModesAfter", [])) == desired_enabled
             and result.get("selectedSourceBefore") == result.get("selectedSourceAfter"))
    if not valid:
        raise RuntimeError("Input-source registration failed verification: " + json.dumps(result, ensure_ascii=False))


def register(app, legacy=False):
    if legacy:
        result = refresh_legacy_registration(app)
    else:
        process = subprocess.run([str(app / "Contents/MacOS/Squirrel"), "--register-input-source"],
                                 capture_output=True, text=True)
        try:
            result = json.loads(process.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError("Registration command did not return a verifiable JSON result") from error
        if process.returncode:
            raise RuntimeError("Input-source registration failed: " + json.dumps(result, ensure_ascii=False))
    validate_registration(result, app)
    if not result["enabledModesBefore"]:
        print("Recovered and verified the default Hans mode from an empty registration snapshot.")
    print("Verified LS/TIS registration for installed app: " + str(app))
    return result


def verify_registration_in_fresh_process(app, expected_enabled):
    helper = Path(__file__).with_name("register_legacy_frontend.py")
    expected_modes = {"im.rime.inputmethod.Squirrel.Hans", "im.rime.inputmethod.Squirrel.Hant"}
    stable = 0
    latest = None
    for _ in range(20):
        # Each check starts a new interpreter: a successful registration process
        # can still retain stale TIS records that other applications cannot see.
        process = subprocess.run([sys.executable, str(helper), "status", str(app)],
                                 capture_output=True, text=True)
        if process.returncode:
            raise RuntimeError("Independent TIS inspection failed: " + process.stderr.strip())
        try:
            latest = json.loads(process.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError("Independent TIS inspection did not return JSON") from error
        valid = (isinstance(latest, dict) and latest.get("protocolVersion") == 1
                 and latest.get("bundleID") == "im.rime.inputmethod.Squirrel"
                 and Path(latest.get("appPath", "")).resolve() == app.resolve()
                 and set(latest.get("registeredModes", [])) == expected_modes
                 and set(latest.get("enabledModes", [])) == set(expected_enabled))
        stable = stable + 1 if valid else 0
        if stable == 2:
            print("Verified input modes in two independent processes after launch.")
            return latest
        time.sleep(0.1)
    raise RuntimeError("Post-launch input modes did not remain visible across processes: " + json.dumps(latest))


def start(app, legacy_registration=False):
    register(app, legacy=legacy_registration)
    subprocess.run(["/usr/bin/open", "-a", str(app)], check=True)
    executable = app / "Contents/MacOS/Squirrel"
    pattern = "^" + re.escape(str(executable)) + "($| )"
    for _ in range(50):
        process = subprocess.run(["/usr/bin/pgrep", "-f", pattern], capture_output=True)
        if process.returncode == 0:
            break
        if process.returncode != 1:
            raise RuntimeError("Could not verify the installed Squirrel process")
        time.sleep(0.1)
    else:
        raise RuntimeError("Installed Squirrel process did not start")
    subprocess.run([str(app / "Contents/MacOS/Squirrel"), "--reload"], check=True)
    # Initial launch/reload can refresh LaunchServices after our pre-launch
    # registration. Refresh the installed path again, then verify independently.
    time.sleep(0.5)
    result = register(app, legacy=legacy_registration)
    verify_registration_in_fresh_process(app, result["expectedEnabledModes"])
    stabilize_registration(app, result["expectedEnabledModes"], legacy_registration)
    print("Verified installed process and requested redeployment.")


def stabilize_registration(app, expected_enabled, legacy_registration=False):
    # Bundle-replacement notifications can arrive after immediate checks pass.
    # Observe independent processes for at least 30 seconds; repair only this
    # installed bundle if the delayed update removes its input-source records.
    stable = 0
    for attempt in range(30):
        time.sleep(2)
        try:
            verify_registration_in_fresh_process(app, expected_enabled)
            stable += 1
        except RuntimeError:
            register(app, legacy=legacy_registration)
            stable = 0
        if attempt >= 14 and stable >= 3:
            print("Input-source registration remained available after delayed system updates.")
            return
    raise RuntimeError("Input-source registration did not stabilize after bundle replacement")


def install(args):
    source, target = args.app.expanduser().resolve(), args.target.expanduser().absolute()
    rime = args.rime_dir.expanduser().resolve()
    if source == target:
        raise ValueError("Build source must be different from installed app")
    verify_bundle(source)
    verify_bundle(target)
    style = rime / "squirrel.custom.yaml"
    if style.is_symlink():
        raise ValueError("Refusing a symlink style configuration")
    original = style.read_bytes() if style.exists() else None
    replacement = merged_style(original.decode() if original else "").encode()
    backup = rime / "en_gloss-backups" / ("frontend-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    backup.mkdir(parents=True)
    if original is not None:
        atomic_write(backup / "squirrel.custom.yaml", original)
    staging = Path(tempfile.mkdtemp(prefix="squirrel-stage-")) / "Squirrel.app"
    if staging.parent.stat().st_dev != target.parent.stat().st_dev:
        shutil.rmtree(staging.parent)
        raise ValueError("Staging must share a filesystem with the installed app for atomic replacement")
    moved = False
    try:
        subprocess.run(["/usr/bin/ditto", str(source), str(staging)], check=True)
        verify_bundle(staging)
        manifest = {"target": str(target), "rime_dir": str(rime), "style_existed": original is not None,
                    "installed_style_sha256": sha(replacement), "installed_app_sha256": tree_hash(staging),
                    "original_app_sha256": tree_hash(target)}
        atomic_write(backup / "frontend-manifest.json", json.dumps(manifest, indent=2).encode())
        if not args.no_restart:
            stop(target)
        os.replace(target, backup / "original-app")
        moved = True
        os.replace(staging, target)
        atomic_write(style, replacement)
        # Remove the temporary container before the final registration checks.
        staging.parent.rmdir()
        if not args.no_restart:
            start(target)
    except Exception:
        if moved:
            if target.exists():
                # A post-launch registration failure leaves the replacement
                # process alive. Stop it before restoring the same app path:
                # otherwise open/pgrep can mistake it for the restored binary.
                if not args.no_restart:
                    try:
                        stop(target)
                    except Exception as stop_error:
                        raise RuntimeError(
                            "Installation failed and the replacement Squirrel could not be stopped; "
                            f"the installed files and original backup were preserved at {backup}"
                        ) from stop_error
                shutil.rmtree(target)
            os.replace(backup / "original-app", target)
            if original is None:
                style.unlink(missing_ok=True)
            else:
                atomic_write(style, original)
            if not args.no_restart:
                start(target, legacy_registration=True)
        raise
    finally:
        shutil.rmtree(staging.parent, ignore_errors=True)
    print(f"Installed multilingual frontend. Backup: {backup}")
    print("Language models must be enabled in the sentence translation setup window.")


def rollback(args):
    backup = args.backup.expanduser().resolve()
    manifest = json.loads((backup / "frontend-manifest.json").read_text())
    target, rime = Path(manifest["target"]), Path(manifest["rime_dir"])
    original = backup / "original-app"
    style = rime / "squirrel.custom.yaml"
    if target.is_symlink() or style.is_symlink():
        raise ValueError("Refusing symlink replacement")
    if tree_hash(target) != manifest["installed_app_sha256"] or sha(style.read_bytes()) != manifest["installed_style_sha256"]:
        raise ValueError("App or settings changed after installation; preserve later changes before rollback")
    if tree_hash(original) != manifest["original_app_sha256"]:
        raise ValueError("Original app backup checksum mismatch")
    verify_bundle(original)
    if not args.no_restart:
        stop(target)
    os.replace(target, backup / "removed-frontend")
    os.replace(original, target)
    if manifest["style_existed"]:
        atomic_write(style, (backup / "squirrel.custom.yaml").read_bytes())
    else:
        style.unlink(missing_ok=True)
    if not args.no_restart:
        start(target, legacy_registration=True)
    print("Original Squirrel app and candidate style restored; Lua glossary retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("install")
    add.add_argument("app", type=Path)
    add.add_argument("--target", type=Path, default=Path.home()/"Library/Input Methods/Squirrel.app")
    add.add_argument("--rime-dir", type=Path, default=Path.home()/"Library/Rime")
    add.add_argument("--no-restart", action="store_true", help="For isolated copies only")
    remove = commands.add_parser("rollback")
    remove.add_argument("backup", type=Path)
    remove.add_argument("--no-restart", action="store_true", help="For isolated copies only")
    args = parser.parse_args()
    try:
        (install if args.command == "install" else rollback)(args)
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
