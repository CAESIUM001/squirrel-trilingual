# Local arm64 frontend build

This source export is based on official Squirrel 1.1.2, commit `876adebaf2f612951dcdca8a591de65401222b9a`. It contains vendored snapshots of the matching librime and Sparkle source/header trees; **no Git submodule checkout is required for this build path**. Their licenses and fixed revisions are retained. Non-build Sparkle binary test archives are omitted as documented in the project NOTICE.

The build recompiles the modified Squirrel frontend while reusing matching official Squirrel 1.1.2 runtime libraries, plugins, and dictionaries. It does not rebuild librime or Sparkle. `frontend/source/LOCAL-DEPENDENCIES.json` records source revisions and runtime hashes.

Requirements: Apple Silicon, Python 3, Xcode 26.2 (the verified build toolchain), and an extracted official Squirrel 1.1.2 application. Full translation features require macOS 15 or later at runtime.

From the **repository root**, run:

```sh
python3 frontend/source/scripts/build-local.py \
  --official-app "/path/to/official/Squirrel.app" \
  --configuration Release
```

The output is `frontend/source/build/Build/Products/Release/Squirrel.app`. The script performs ad-hoc signing, `codesign --verify --deep --strict`, and a `--help` dynamic-link smoke test. The latter exits before input-server creation. These checks are not Developer ID signing, notarization, or host-application keyboard validation.

The script does not install the application, explicitly register a TIS input source, or launch it normally. Xcode can automatically update LaunchServices for its build output. **Never run `lsregister -u` on a build sharing the installed input method's bundle ID**: this can invalidate the installed app's mapping. Use the installer to register the final installed path through `--register-input-source`.

That custom registration command derives its path from `Bundle.main.bundleURL`, forces `LSRegisterURL`, calls `TISRegisterInputSource`, and reports status as JSON. It preserves a nonempty enabled-mode set; an empty pre-registration state restores the default Hans mode. The advanced Python installer checks independent system snapshots and repairs delayed registration loss. Layout tests use a separate panel-only host rather than a system IMK server.

If a restricted build environment blocks resource compilation or macOS build services, inspect `frontend/source/build-local-release.log` before treating it as a Swift compiler failure.

For the language setup helper, PKG build, tests, and installation boundaries, see the [complete build guide](../../docs/BUILD.md).
