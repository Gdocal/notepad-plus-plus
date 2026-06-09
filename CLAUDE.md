# CLAUDE.md — Notepad++ Fork: Lazy Session Load

**For any future Claude session: READ THIS FIRST.** It tells you the
project goal, the binding constraints, how to test, how to release,
and which mistakes to never repeat.

---

## 1. Project goal

This is a personal fork of `notepad-plus-plus/notepad-plus-plus`
maintained on the `feature/lazy-session-load` branch.

The user has a session with 300+ tabs (often including untitled
snapshot-backup tabs, WSL paths, mapped network drives). Stock NPP
takes 15–20 s to become interactive on cold start. Our patches give
sub-second time-to-interactive while preserving stock behaviour for
file change detection and data integrity.

The fork is **NOT intended for upstream merge** — maintainer `donho`
explicitly rejected it on PR #17963 citing thread complexity and
breadth of changes. We maintain it for the user's personal use.

---

## 2. Hard constraints (DO NOT VIOLATE)

These have caused real bugs or wasted time in previous sessions:

1. **Never call `doesFileExist` / `GetFileAttributesExW` /
   `getFileAttributesExWithTimeout` on a SESSION FILENAME from the
   startup hot path.** A session may contain unreachable paths
   (`\\wsl.localhost\…` with WSL stopped, disconnected UNC shares,
   spun-down external drives). On such paths the stat blocks the
   main thread for the SMB / NFS timeout (15–30 s) and re-introduces
   the freeze we are trying to eliminate. The pump in
   `processSessionInsertStep` must decide tab type from the session
   filename string alone (`PathIsRelativeW`).

2. **Backup paths are safe to stat.** They always live under the
   NPP config dir (local). The check is needed for two donho-reported
   bugs (see §6).

3. **Never set `setDirty(true)` based on backup-path presence
   alone.** Always gate it on the backup file actually existing on
   disk. The eager snapshot-restore path does this; we must mirror
   it. Failing this gives wrong tab icons and the "Your backup file
   cannot be found" prompt storm on shutdown.

4. **Never `updateTimeStamp()` after loading content in
   `applyLazyContent` / `resolveLazyBuffer`.** Keep `_timeStamp =
   session._originalFileLastModifTimestamp` so `checkFileState`
   detects externally-modified files and raises the stock reload
   prompt (R15).

5. **Worker thread shutdown: detach, do not join.** A worker stuck
   inside `ReadFile` on an unreachable path would otherwise gate
   process exit on a 15-second SMB timeout. The worker holds no
   pointers into NPP state after PostMessage, so detach is safe.

6. **`std::thread::native_handle_type` is HANDLE on the MSVC STL but
   `pthread_t` on MinGW-w64 with winpthreads.** Do not pass it to
   `WaitForSingleObject` directly — this breaks the MinGW32 / MinGW64
   / CLANG64 CI jobs.

---

## 3. Branch structure

- `master` — upstream tracking, not modified locally.
- `feature/lazy-session-load` — our patches. Rebased onto
  upstream/master weekly (see §7). Force-pushed to the fork.

Local remotes:
- `origin` → `Gdocal/notepad-plus-plus` (our fork)
- `upstream` → `notepad-plus-plus/notepad-plus-plus`

---

## 4. Build

MSBuild for Visual Studio Build Tools 2022 with the "Desktop
development with C++" workload installed at default path. To build
release x64 manually:

```powershell
& 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe' `
  'F:\Projects\NotepadPlusPlus\PowerEditor\visual.net\notepadPlus.sln' `
  /p:Configuration=Release /p:Platform=x64 /m /nologo
```

Output: `PowerEditor\bin64\notepad++.exe`.

All 4 MSVC configs (Release/Debug × x64/Win32) must build with 0
errors before declaring a release ready. Existing pre-existing
warnings in code not touched by us are OK; new warnings introduced
by our changes are NOT.

---

## 5. Verification — REQUIRED before any release

### 5.0 GOLDEN RULE — always diff against stock

Before claiming any user-visible behaviour is "stock NPP doing X",
verify it. The procedure is mechanical:

1. `git checkout upstream/master` (detached HEAD is fine).
2. Build Release x64.
3. Save the binary as `F:\NppBackups\stock_<version>_notepad++.exe`.
4. Run it in `F:\NppBackups\stock_test\` (a portable env using a
   copy of the user's real session.xml + backup/ dir — never the
   originals).
5. Observe / count what you want to test (dialogs, icons, exit
   time).
6. `git checkout feature/lazy-session-load` (with `git stash pop` if
   you stashed) and build our binary.
7. Run in the same portable env. Diff the observations.
8. Any divergence is a regression; do NOT explain it away as
   "stock works that way too" without the stock binary in front of
   you.

**This rule exists because of a real failure.** A previous session
shipped the R15 fix that called `checkFileState()` after lazy load
on the false premise that "stock NPP also prompts about externally
modified files at startup". Empirically it does NOT (when
`_fileAutoDetection == cdEnabledNew`, which is the default). The
"fix" caused a startup prompt storm regression that the user only
caught by manually closing dialogs. The R15-related
`checkFileState()` calls have since been removed from
`applyLazyContent` and `resolveLazyBuffer`. Don't re-introduce.

### 5.1 The smoke test

**ALL verification is automated. Never ask the user to manually
check icons / click prompts / observe startup time.** Run
`tools/smoke_test.ps1` (see §8). It:

1. Launches the build in a portable test directory (`test_lazy\`)
   with the user's real session.xml (copied, never the original).
2. Times init() via the `NPP_STARTUP_TRACE` flag (set to 1 only for
   verification builds, off in releases).
3. Detects "not responding" stalls via `SendMessageTimeout` probes.
4. Counts dialog windows (`#32770`) that appear after startup or
   during close.
5. Auto-dismisses dialogs with "No" so the run completes.
6. Verifies the post-test session.xml has the same file count as
   before (no data loss — R2 guard).
7. Reports pass/fail with metrics.

The script must exit 0 only if all checks pass. CI uses the same
script.

Acceptance thresholds:
- init() ≤ 300 ms
- sustained-responsive moment ≤ 1500 ms after launch
- pre-existing-bug regression: 0 unexpected dialogs at startup
  (excludes the stock reload-externally-modified prompts which are
  the user's auto-update preference responsibility)
- session count unchanged after close

---

## 6. Known bugs to never re-introduce

Each is described in detail in
[`LAZY_SESSION_RISKS.md`](LAZY_SESSION_RISKS.md). Every entry below
**must** have a corresponding automated check in
`tools/smoke_test.ps1`. When a new bug is discovered (by the user,
by maintainer feedback, or by a release sanity run), append it
here AND add a check to the smoke test BEFORE shipping the next
release.

### Active checklist

| ID | Symptom | Guard | Automated check |
|---|---|---|---|
| R1 | Active tab placed at tab-bar index 0 | `DocTabView::addBufferAt` with explicit `sessionIndex` | smoke test compares `session.xml` order pre/post launch |
| R2 | Closing during pump drops 300+ tabs from session.xml | `getCurrentOpenedFiles` drains `_pendingSessionInserts` first | smoke test session-count integrity check |
| R3/R4 | Crash on null `_doc` | All `getDocument()` callers must guard; `closeBuffer` guards `SCI_RELEASEDOCUMENT` | smoke test launches + closes; non-zero exit on crash |
| R5 | Find in all open misses lazy tabs | `findInOpenedFiles` resolves before `SCI_SETDOCPOINTER` | TODO: scripted Ctrl+Shift+F search for known string |
| R6 | Plugins at NPPN_READY see incomplete file list | `NPPM_GETNB(OPEN)FILES` includes pending entries | TODO: SendMessage probe of these IDs at startup |
| R7 | Dirty icon delayed | `addBuffer(At)` computes correct icon at insert | smoke test pixel-diff vs stock at +5 s |
| R9 | Windows-dialog Size column shows 0 for lazy | falls back to on-disk / backup file size | TODO: scripted open of Windows dialog + parse |
| R11 | `WM_SETREDRAW` stuck on exception | `BatchInsertGuard` RAII | static (compile-time RAII) — no runtime test |
| R13 | Wait cursor for full pump duration | session-insert pump uses `SetTimer`, lowest priority | smoke test `SendMessageTimeout(50 ms)` samples |
| R14 | Click on cold tab freezes UI | worker thread reads bytes off-main | smoke test launches + sends Ctrl+PgDn at +3 s, expects no >50 ms stall |
| R15 | Startup prompt storm "This file has been modified by another program" | **revert reflex**: do NOT call `checkFileState()` in `applyLazyContent` / `resolveLazyBuffer`. Stock NPP does not check at load when `cdEnabledNew`. | smoke test counts startup `#32770` dialogs; must equal stock baseline |
| donho-1 | All inactive tabs red even when clean | gate `setDirty(true)` on `doesFileExist(backupPath)` in pump | smoke test pixel-diff vs stock at +5 s (same as R7) |
| donho-2 | "Your backup file cannot be found" storm on quit | same gate as donho-1 | smoke test counts close-time `#32770` dialogs |

### How to add a new entry

When the user (or a maintainer review, or a smoke-test failure)
surfaces a new misbehaviour:

1. Reproduce it deterministically (the GOLDEN RULE — diff against
   stock).
2. Add a row to the table above.
3. Add a row to `LAZY_SESSION_RISKS.md` with the full analysis.
4. Add a check to `tools/smoke_test.ps1` that fails when the bug
   is present and passes when it is fixed. Run the new check
   against the stock baseline AND our current build to make sure
   the threshold is set correctly.
5. Fix the bug.
6. Re-run the smoke test — all rows in this table must now pass.
7. Commit fix + check + doc updates in a single commit.

### Don't-do list (each was tried and broke something)

- **`std::thread::native_handle()` + `WaitForSingleObject`** —
  HANDLE on MSVC, `pthread_t` on MinGW-w64. Breaks the MinGW32 /
  MinGW64 / CLANG64 CI jobs. Detach the worker thread instead.
- **`doesFileExist` / `GetFileAttributesExW` in the
  session-insert pump on the SESSION FILENAME** — blocks the main
  thread for the SMB timeout on stopped WSL distros / disconnected
  UNC shares.
- **`setDirty(true)` based on `_backupFilePath != ""`** — must
  also check that the backup file exists, otherwise icons and the
  close-time prompt regress (donho-1 / donho-2).
- **`PostMessage`-to-self pump loop for content load** — makes
  Windows mark the app "not responding" and pops the wait cursor
  even though message dispatch is happening. Use `SetTimer` with
  `USER_TIMER_MINIMUM` or move IO off the main thread entirely.
- **`checkFileState()` after `applyLazyContent` /
  `resolveLazyBuffer`** — causes the R15 reload-prompt storm.
  Stock NPP does NOT check file state at load.

---

## 7. Weekly upstream sync

`.github/workflows/weekly-sync.yml` runs each Sunday on the fork.
Steps:

1. Checkout `feature/lazy-session-load`.
2. Add upstream remote and fetch.
3. `git rebase upstream/master`.
4. On conflict: open an Issue titled
   `Weekly sync conflict YYYY-MM-DD` with the conflicted files and
   stop. Manual intervention required (a new Claude session reads
   THIS doc and fixes).
5. Build Release x64.
6. Run `tools/smoke_test.ps1` against a sanitized test session.
7. On success: create a GitHub Release named `npp-lazy-<date>` with
   `notepad++.exe` attached.
8. Force-push the rebased branch.

If anything fails, the workflow leaves the previous Release intact —
the user keeps their working build.

---

## 8. Tools (in `tools/` directory)

- `tools/smoke_test.ps1` — automated verification (§5).
- `tools/install_to_npp.ps1` — backs up the user's installed
  `notepad++.exe` and replaces it with the latest build. Only
  touches the exe; never modifies config, session, plugins, or
  AppData.
- `tools/user_updater.ps1` — Windows scheduled-task script that
  checks the fork's GitHub Releases hourly and, if a newer build is
  available, runs `install_to_npp.ps1`.

---

## 9. Repro environments

Three portable test directories under the repo root, **never
commit** them (`.gitignore` has them):

- `test_lazy\` — full real-session repro for runtime testing.
  Contains a copy of the user's session.xml + a copy of their
  backup\ directory. Reset by `smoke_test.ps1` before each run.
- `test_repro\` — 10-file synthetic session for bug repro
  (clean files + bogus backup refs → triggers donho-1 / donho-2 on
  buggy builds).
- `test_minimal\` — empty session for verifying startup time on
  cold/empty conditions.

---

## 10. Pull request status

PR #17962 / #17963 on upstream are CLOSED. Do not reopen. The
maintainer explicitly rejected the threaded approach. The fork
exists for the user's personal use only.

---

## 11. Helpful invariants when rebasing

If a rebase brings in upstream changes to any of these files, audit
carefully for regressions:

- `PowerEditor/src/NppIO.cpp` — our `loadSession` rewrites
- `PowerEditor/src/Notepad_plus.cpp` — worker thread + queue
- `PowerEditor/src/Notepad_plus_Window.cpp` — `ShowWindow` order
- `PowerEditor/src/NppBigSwitch.cpp` — WM_TIMER + worker WM_APP
- `PowerEditor/src/ScintillaComponent/Buffer.cpp` — lazy ctor flag,
  `applyLazyContent`, `resolveLazyBuffer`
- `PowerEditor/src/ScintillaComponent/Buffer.h` — `_isLazyPending`,
  lazy doc factory declarations
- `PowerEditor/src/ScintillaComponent/DocTabView.cpp` — `addBufferAt`,
  `BatchInsertGuard`
- `PowerEditor/src/Parameters.cpp` / `.h` — `_isLazySessionLoad` GUI
- `PowerEditor/src/WinControls/WindowsDlg/WindowsDlg.cpp` — Size column
- `PowerEditor/src/resource.h` — `NPPM_INTERNAL_SESSIONINSERTNEXT`
  and `NPPM_INTERNAL_LAZYLOADWORKERDONE` IDs

If upstream renames any function we touched or changes a signature,
the rebase will conflict. The conflict must be resolved by hand
keeping OUR behaviour intact AND the upstream change intact.
