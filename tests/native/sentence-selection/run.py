#!/usr/bin/env python3
"""Compile focused state/controller tests; never launch/register an input method.

SPDX-License-Identifier: GPL-3.0-or-later
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frontend", type=Path, default=Path(__file__).resolve().parents[3]/"frontend/source")
    parser.add_argument("--work-root", type=Path, default=Path.cwd()/"work")
    parser.add_argument("--source-user", type=Path, default=Path.home()/"Library/Rime")
    parser.add_argument("--bundle", type=Path, default=Path.home()/"Library/Input Methods/Squirrel.app")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    front = args.frontend.resolve()
    work = args.work_root.resolve()
    if work.name != "work":
        raise SystemExit("Use a dedicated directory named work")
    work.mkdir(exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="sentence-selection-", dir=work))
    source = front/"sources"
    compiler = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                "-module-cache-path", str(run/"module-cache")]
    state = run/"state-tests"
    subprocess.run(compiler + [str(source/"SquirrelSentenceSelection.swift"),
        str(root/"SelectionTests.swift"), "-o", str(state)], check=True)
    pure = subprocess.check_output([str(state), str(root/"fixtures")], text=True)
    print(pure.strip())
    # Keep every controller method exactly as delivered. Replace only its IMK
    # import so a small in-process host/client test double can stand in for IMK.
    controller = (source/"SquirrelInputController.swift").read_text()
    assert controller.count("import InputMethodKit") == 1
    (run/"SquirrelInputController.swift").write_text(controller.replace("import InputMethodKit", "import AppKit\nimport Carbon"))
    bundle = args.bundle.resolve()
    framework = bundle/"Contents/Frameworks"
    executable = run/"controller-tests"
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    subprocess.run(compiler + [
        "-I", str(front/"librime/src"), "-I", str(front/"librime/include"),
        "-I", str(Path(sdk)/"System/Library/Frameworks/Tk.framework/Headers"),
        "-import-objc-header", str(source/"Squirrel-Bridging-Header.h"),
        str(source/"BridgingFunctions.swift"), str(source/"MacOSKeyCodes.swift"),
        str(source/"SquirrelSentenceSelection.swift"), str(run/"SquirrelInputController.swift"),
        str(root/"ControllerSupport.swift"), str(root/"ControllerTests.swift"),
        str(framework/"librime.1.dylib"), "-Xlinker", "-rpath", "-Xlinker", str(framework),
        "-o", str(executable)], check=True)
    user = run/"user"
    user.mkdir()
    for name in ("build", "lua", "opencc", "en_gloss"):
        shutil.copytree(args.source_user/name, user/name)
    # Exercise the plugin being delivered, not an older installed copy.
    shutil.copy2(root.parents[2]/"lua/en_gloss.lua", user/"lua/en_gloss.lua")
    for pattern in ("*.yaml", "*.txt"):
        for file in args.source_user.glob(pattern):
            shutil.copy2(file, user/file.name)
    command = [str(executable), str(user), str(bundle/"Contents/SharedSupport"),
               str(framework/"rime-plugins/librime-lua.dylib"), str(root/"fixtures")]
    process = subprocess.run(command, capture_output=True, text=True, timeout=30)
    (run/"controller.stdout").write_text(process.stdout)
    (run/"controller.stderr").write_text(process.stderr)
    if process.returncode:
        print(process.stdout)
        print(process.stderr[-8000:])
        raise SystemExit(process.returncode)
    result = json.loads(next(line for line in process.stdout.splitlines() if line.startswith('{"')))
    print(json.dumps(result, ensure_ascii=False))
    report = {"status": "passed", "state": json.loads(pure), "controller": result,
              "lua_sha256": hashlib.sha256((root.parents[2]/"lua/en_gloss.lua").read_bytes()).hexdigest(),
              "source_sha256": {name: hashlib.sha256((source/name).read_bytes()).hexdigest()
                                for name in ("SquirrelInputController.swift", "SquirrelSentenceSelection.swift")}}
    (root/"results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")


if __name__ == "__main__":
    main()
