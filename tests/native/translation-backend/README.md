# Translation backend regression checks

These 32 checks compile the real `SquirrelSentenceTranslator.swift`. They do not
register or replace an input method, access Rime state, use the clipboard, or
read real keyboard input.

Run on an Apple silicon Mac with macOS 15 or later, Xcode, a logged-in GUI
session, and the Chinese, English and French Apple Translation models installed:

From the repository root:

```sh
python3 tests/native/translation-backend/run.py \
  --source frontend/source/sources/SquirrelSentenceTranslator.swift
```

The source argument is optional when the working repository or packaged frontend
source exists in its usual location. A restricted shell may block Apple's GUI
or translation service; run with normal desktop-session access. The test never
requests a model download.

- `BackendChecks.swift`: 12 checks against real offline Apple Translation,
  including prioritized first result, cumulative progress, duplicate inputs,
  synchronous memory hits, cancellation from a progress callback, stale request
  IDs, retention of completed partial results, and independent English/French
  requests.
- `DictionaryChecks.swift`: 20 checks against a temporary synthetic TSV fixture,
  including exact lookup, traditional-to-simplified fallback, language isolation,
  missing or invalid inputs, and the 1,024-entry / 2 MiB LRU memory limits. The
  fixture is generated in a temporary app bundle and removed after the run.

The adjacent JSON files record the successful checks from 2026-10-24. The runner
rewrites those results, or writes elsewhere when `--output` is supplied. These
checks establish backend behavior; they do not claim that a host application's
keyboard routing or candidate window was exercised.
