---
task_id: 294bf604
stage: FIX_REVIEW
reviewer: harness-architect
verdict: pass
---

# Fix Review — `verify-update-managed-assets.ps1` scratch-root noise

Scope: review fix `605dac8a` against the four scoped checkpoints. Confirms
the change is bounded to scratch-root / cleanup noise control and does
not touch the script-under-test or its main logic.

## Verdict

**no findings** — the four scoped questions all resolve cleanly.

## Scoped checkpoint results

### 1. Was the fix limited to scratch-root / cleanup noise control?
**Yes.**

`git status --short` shows only `tests/verify-update-managed-assets.ps1`
modified for this fix. `git diff HEAD -- scripts/update-managed-assets.ps1
install.ps1` is empty — both untouched.

The diff against `tests/verify-update-managed-assets.ps1` consists
entirely of:
- `Add-Warning` helper + `$script:Warnings = @()` initialization
- `Remove-DirectoryWithRetry` helper (retry-with-warning, no throw)
- Scratch-root location moved from `$RepoRoot\tmp\update-managed-assets-regression`
  (workspace-rooted, fixed name) to `$env:TEMP\update-managed-assets-regression-<GUID>`
  (system temp, GUID-unique)
- Removal of the eager pre-cleanup `if (Test-Path) { Remove-Item -Force }`
  block (no longer needed once the path is GUID-unique)
- `try { ... } finally { Remove-DirectoryWithRetry -Path $scratchRoot }`
  wrapper around the existing case bodies
- New `Warnings:` output section between `Checks:` and `Failures:`

Test case bodies (`workflow-protocol-drift-is-repaired`,
`cwd-autodetect-pass`, `decision-needed-template-drift-is-repaired`)
and the `Invoke-ManagedAssetsCase` helper are byte-identical apart from
the four-space indent shift caused by the surrounding `try { ... }`.

### 2. Does GUID-unique scratch root + retry/finally cleanup keep both current workspace and clean-copy stable?
**Yes.**

- `[System.IO.Path]::GetTempPath()` plus `[guid]::NewGuid().ToString('N')`
  guarantees a fresh path on every invocation, so a stale or in-use
  scratch root from a previous failed run cannot collide with the
  current run.
- The new path lives outside `$RepoRoot`, so cwd / workspace-rooted
  policies do not apply (no risk of the test polluting the working
  tree, and no risk of an SCM ignore gap leaking the scratch tree
  into git status).
- The `try { ... } finally { Remove-DirectoryWithRetry ... }` ensures
  cleanup runs even if a case body throws; the retry loop (10 attempts,
  200 ms pause = up to 2 s) absorbs the typical Windows handle-release
  lag without bubbling up as a failure. A live run on the current
  workspace produced exactly:
  ```
  Checks:
  - workflow-protocol-drift-is-repaired: PASS
  - cwd-autodetect-pass: PASS
  - decision-needed-template-drift-is-repaired: PASS

  Warnings:
  - none

  Failures:
  - none
  EXIT: 0
  ```
- I exercised the test on the live workspace (which already has
  unrelated unstaged edits to `scripts/advance-stage.ps1` and
  `scripts/validate-lite-artifacts.ps1`) and it stayed green, which is
  also a soft proxy for "clean-copy stable" (the test does not depend
  on the workspace being pristine; it copies into the scratch fixture).

### 3. Is `Warnings:` purely cleanup tail noise — no test-body / under-test contract change?
**Yes.**

- `$script:Warnings` is only ever appended to from inside
  `Remove-DirectoryWithRetry` after the retry budget is exhausted
  (line 91: `Add-Warning ("cleanup failed for scratch root {0}: {1}" ...)`).
  No other call site exists in the file.
- Output ordering is `Checks: → Warnings: → Failures:`. Exit code is
  controlled solely by the `Failures:` block (lines 305-318):
  `exit 0` when `Failures.Count -eq 0`, `exit 1` otherwise. Warnings
  do not influence exit code, do not feed into `Failures`, and do not
  short-circuit subsequent test logic.
- The `Invoke-ManagedAssetsCase` function body is unchanged. The set
  of asserted expectations (`STATUS == PASS`, drift-line absence,
  cwd-autodetect path) is unchanged. The script-under-test invocation
  shape (`install.ps1` first, then `update-managed-assets.ps1`) is
  unchanged.

### 4. Was `scripts/update-managed-assets.ps1` / `install.ps1` main logic re-opened?
**No.**

Both files are clean against HEAD:
- `git diff HEAD -- scripts/update-managed-assets.ps1` → empty
- `git diff HEAD -- install.ps1` → empty

The fix is purely test-side noise control; the script-under-test's
contract is preserved.

## Commands actually executed

All under `D:\data\claude-dev-harness`:
- `git log --oneline -5 -- tests/verify-update-managed-assets.ps1` — confirmed last-commit baseline
- `git status --short -- scripts/ install.ps1 tests/verify-update-managed-assets.ps1` — confirmed only the test file is modified for this fix
- `git diff HEAD -- tests/verify-update-managed-assets.ps1` — full diff inspected
- `git diff HEAD -- scripts/update-managed-assets.ps1 install.ps1` — confirmed empty (main logic untouched)
- `pwsh -NoProfile -File tests/verify-update-managed-assets.ps1` — exit 0; 3 checks PASS; Warnings: none; Failures: none
- `Glob docs/tasks/294bf604*/*` — confirmed no prior plan / code-review under this task id (this fix was a scoped follow-up to Phase 4's deferred item)

## Files / regions read

- `tests/verify-update-managed-assets.ps1:1-180` (helper definitions, `Invoke-ManagedAssetsCase` body)
- `tests/verify-update-managed-assets.ps1:180-318` (scratch-root setup, try/finally wrapper, output blocks)

## Out of scope (per Leader's directive)

- `scripts/update-managed-assets.ps1` main logic and `install.ps1` were
  explicitly excluded from this round; both confirmed unmodified and
  not re-opened.
- The unrelated workspace-tree edits to `scripts/advance-stage.ps1` and
  `scripts/validate-lite-artifacts.ps1` are pre-existing and unrelated
  to fix `605dac8a`; they are not part of this review.

No implementation modifications were made during this review.
