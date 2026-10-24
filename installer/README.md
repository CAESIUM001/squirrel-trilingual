# macOS full-pinyin installer

This directory builds the self-contained Apple Silicon / macOS 15+ PKG for Squirrel Trilingual. Python and Xcode are required on the build Mac only. The installed helper is a native Swift executable.

From the repository root, after building both app bundles:

```sh
python3 installer/build.py \
  --version 0.4.0 \
  --squirrel-app "frontend/source/build/Build/Products/Release/Squirrel.app" \
  --setup-app "Translation Setup.app" \
  --output installer/dist
```

Use `--stage-only` to inspect the payload without producing the final PKG. The build includes the static Rime Ice configuration, translation resources, both apps, source/data notices, full third-party license files, and a payload hash manifest. The PKG is unsigned and not notarized; embedded binaries use ad-hoc signatures. It does not alter Gatekeeper policy.

The package places its shared payload at `/Library/Application Support/Squirrel Trilingual/Current`. Its post-install script runs the helper as the active ordinary console user; it rejects the login window and system users. The helper backs up the user's Rime directory and user-level Squirrel app, merges the full-pinyin profile and feature defaults, then registers and deploys the actual installed path.

Backups are retained under `~/Library/Application Support/Squirrel Trilingual/Backups/`. Installation failures attempt checked automatic recovery and retain the backup. There is no public `--restore` operation in this version; [manual recovery instructions](../docs/INSTALLATION.md#恢复安装前状态) explain how to preserve the current state first.

The native helper's normal invocation, used by the package script, is:

```sh
"/Library/Application Support/Squirrel Trilingual/Current/SquirrelInstaller" \
  --install \
  --payload "/Library/Application Support/Squirrel Trilingual/Current"
```

This is a real installation command, not a dry run. For isolated tests, the helper accepts `--home /private/tmp/<test-home> --no-activate`; these options require a temporary, non-symlink home distinct from the real home and skip input-source activation. See [build and validation documentation](../docs/BUILD.md) for the rest of the product checks.

A fresh full-pinyin payload can be tested without system registration:

```sh
python3 tests/native/full_pinyin.py \
  --payload "installer/build/root/Library/Application Support/Squirrel Trilingual/Current" \
  --results tests/native/full-pinyin-results.json
```

This uses the native helper plus real Rime deployment/engine in a temporary home. It does not prove that every application's input field accepts the installed input method.

Configuration-preservation and failure-recovery checks use the same payload:

```sh
python3 installer/tests/test_installer.py \
  --payload "installer/build/root/Library/Application Support/Squirrel Trilingual/Current"
```

The recorded 45 checks cover fresh installation, preserved personal data/settings, complete backup, idempotent reinstallation, default-schema fallback, unsupported YAML/symlink rejection, and failure recovery. They run only in disposable temporary homes, not through a privileged PKG installation. Results and the tested helper hash are in `tests/results.json`.
