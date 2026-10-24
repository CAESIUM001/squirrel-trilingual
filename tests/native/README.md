# Native Squirrel integration tests

This test loads the installed Squirrel `librime.1.dylib` and `librime-lua.dylib` in a standalone command-line process. It compiles `probe.c` with Xcode Command Line Tools, copies dictionaries and configuration to a fresh directory under `work`, deploys the plugin there, and tests the actual Rime API. It does not start a Squirrel UI process, change the macOS input source, or open the real user databases.

From the project directory, run:

```sh
python3 tests/native/integration.py \
  --work-root "$PWD/work" \
  --source-user "/path/to/test/Rime" \
  --bundle "/path/to/matching/Squirrel.app"
```

Defaults: `~/Library/Input Methods/Squirrel.app`, `~/Library/Rime`, and `double_pinyin_sogou`. Override paths with `--bundle`, `--source-user`, and `--project`. The test requires the user's Rime Ice configuration, the default 9-candidate Sogou double-pinyin scheme, and both Shift keys configured to toggle ASCII. Its expected dictionary entries refer to the bundled glossary.

The result is written to `tests/native/results.json` (or `--results PATH`). Failed assertions are collected in its `failures` list and cause a nonzero exit. It records the tested Lua module hash, synthetic inputs, candidate comments, committed text, per-action latency, and the isolated directory. Temporary copies are preserved for investigation; they contain copied local configuration and dictionaries and should remain local. No real `*.userdb` is copied. `elapsed_ms` for the initial event includes schema/dictionary initialization; key events include candidate retrieval. These are diagnostic single-run times, not a benchmark.

Tests cover Chinese selection, the first and second English meanings, Option digits with both macOS keycode forms, page-relative selection, retained unconverted suffixes and selected Chinese prefixes, caret movement, traditional characters, the gloss toggle, both Shift keys, absent translations, and key release behavior. This verifies the actual engine pipeline; it does not verify appearance or keyboard events in every macOS application.

`probe.c` is project test code. `rime_api.h` is unmodified from librime 1.16.0: https://github.com/rime/librime/blob/1.16.0/src/rime_api.h . Its BSD license is included in `LICENSE.librime`.

## Fresh full-pinyin installer payload

After staging or building the installer, run from the repository root:

```sh
python3 tests/native/full_pinyin.py \
  --payload "installer/build/root/Library/Application Support/Squirrel Trilingual/Current" \
  --results tests/native/full-pinyin-results.json
```

This separate 11-check path runs the native installation helper inside a temporary home, deploys `rime_ice` with the actual Rime deployer, and validates full-pinyin composition, English gloss/Option selection, normal Chinese commit, a complete sentence, both Shift keys, nine-candidate/layout settings, and the bundled French dictionary hash. It skips input-source registration and activation and does not exercise host application UI. Recorded results are in `full-pinyin-results.json`.
