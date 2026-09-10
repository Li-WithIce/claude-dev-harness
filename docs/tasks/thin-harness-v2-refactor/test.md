# Test Report

> Current RQ-34 TEST attestation for the public Harness v2 opt-in engineering milestone. This report supersedes the historical `a061cacf...` fail snapshot while preserving that history in the Master Plan. Default Promotion / Stable qualification remains a separate pending milestone and is not represented as pass here.

## Summary
- The final RQ-34 dirty candidate passes the approved public opt-in engineering scope: Critical structured dry-run completion and replay enforcement, v1/v2 coexistence, install/update/uninstall compatibility, maintained documentation, and process-record consistency are supported by focused, full-suite, lifecycle, and isolated-review evidence.

## Scope
- RQ-34 delivery-milestone reconciliation on top of completed PR-00 through PR-14: public v2 explicit opt-in, Critical dry-run closure, v1 compatibility and rollback, current docs/process artifacts, and local ordinary-engineering verification.
- Excluded from this pass: Model40, real cognitive/installed Host 3×3, current-head performance qualification, Installed Desktop Gate, eligible rollout promotion, Auto default flip, Canary/Stable, Ready/merge, and physical v1 removal.

## Inputs Reviewed
- `docs/tasks/thin-harness-v2-refactor/plan.md`
- `docs/tasks/thin-harness-v2-refactor/release-gap-checklist.md`
- `README.md`, `CHANGELOG.md`, `docs/quick-start.md`, `docs/governed-work.md`, `docs/migration/v1-to-v2.md`
- `schemas/evidence.schema.json`, `schemas/task-state.schema.json`
- `scripts/lib/Harness.Evidence.psm1`, `scripts/lib/Harness.Governance.psm1`, `scripts/lib/Harness.TaskState.psm1`
- related policy, Evidence, Governance, TaskState, Approval, coexistence, migration, install, entry, and workflow verifiers

## Test Approach
- Ran the final `Suite all` with verbose output and a 900-second per-check timeout; verified its raw log hash, RUN/PASS accounting, explicit SKIP, dynamic SUBST UNAVAILABLE, zero FAIL markers, and final status.
- Ran isolated core, governed, and full lifecycle smokes sequentially through install, verify, update, second verify, uninstall, and cleanup.
- Ran focused Policy, Evidence, Governance, and TaskState verification after the Run 7 whitespace counterexample; retained the initial six-failure Policy attempt as failed evidence, corrected the exact schema hunk, and reran successfully.
- Used three fresh isolated read-only CODE_REVIEW contexts across the two revise loops and final pass. Run 8 independently replayed schema, Evidence-runtime, and Governance-runtime whitespace counterexamples and found no P0/P1/evidenced P2 or blocking overengineering.
- Bound this report to a canonical JSON digest containing HEAD plus SHA-256 digests of unstaged, staged, and untracked candidate state, with this tracked `test.md` self-excluded so the report does not invalidate its own revision.

## Findings
- Critical tasks persist or compatibly derive `dry_run_required`; an explicit false downgrade is rejected. A successful, task/version/Contract/revision-bound dry-run with a contained output/digest/cwd and independent controlled-executor actor/context is required before `done` in ordinary, current replay, and legacy replay paths.
- Whitespace-only dry-run command and executor identity values are rejected by schema and runtime checks with zero writes; ordinary Evidence actor/command contracts remain unchanged.
- v1 tasks still execute the five-stage lifecycle to DONE; explicit v1 rollback, explicit v2 opt-in, artifact-first existing tasks, migration safety, and core/governed/full install lifecycles remain intact.
- Documentation consistently distinguishes public v2 opt-in engineering completion from pending Default Promotion / Stable qualification. Auto without eligible evidence remains v1; release-job skips and unavailable evidence are not pass.
- Final isolated Code Review Run 8 reports `findings: none` and four-dimensional scores `96/95/97/97`.

## Evidence
- command: `pwsh -NoLogo -NoProfile -NonInteractive -File scripts\run-validation.ps1 -Suite all -CheckTimeoutSeconds 900 -VerboseOutput; pwsh -NoLogo -NoProfile -NonInteractive -File scripts\run-isolated-install-smoke.ps1 -RepoRoot D:\data\dev-harness -Preset core; pwsh -NoLogo -NoProfile -NonInteractive -File scripts\run-isolated-install-smoke.ps1 -RepoRoot D:\data\dev-harness -Preset governed; pwsh -NoLogo -NoProfile -NonInteractive -File scripts\run-isolated-install-smoke.ps1 -RepoRoot D:\data\dev-harness -Preset full`
- exit_code: 0
- executed_at: 2026-07-22T14:36:04+08:00
- revision: dirty:db7eda21b667252ddee9454a0152de8e4d4a24069657642e6e8a72dc7932cff8
- evidence_path: `docs/tasks/thin-harness-v2-refactor/test.md`

## Risks / Gaps
- Final Suite log `D:\data\dev-harness-validation-temp\rq34-whitespace-final-suite-all-20260722.log` (SHA-256 `402c3911f9ac324dfb73995e284e7d8e60acd7dfdcb1d0b11dfd6fa68142c373`) has 68 RUN entries, 67 timed verifier passes plus timed `git diff --check`, zero FAIL, one explicit no-WorkspaceRoot install SKIP, one dynamic SUBST UNAVAILABLE, and final PASS. The three isolated lifecycle logs provide real install/update/uninstall evidence for the skipped aggregate install entry; dynamic SUBST remains unavailable, not pass.
- Exact-head ordinary CI is impossible before the final commit and remains required after push. Starting-head run `29818578961` passed ordinary PR gates at `4ff92a3...`; its release jobs were skipped and are not current-candidate release evidence.
- Model40, real Host 3×3, performance ratios, Installed Desktop Gate, eligible report, promotion, Auto flip, Canary/Stable, Ready/merge, and v1 removal were not executed. They remain later, separately authorized qualification or retirement work.
- Public Harness actor identity is cooperative and non-cryptographic. Structured actor/context separation and bound Evidence do not invent enterprise principal authentication; PreToolUse remains a guardrail rather than an unbypassable security boundary.

## Conclusion
pass

## Handoff
- delivery: Public Harness v2 opt-in engineering and RQ-34 consistency closure pass local TEST, including the existing Plan/process documents, Critical dry-run fixes, compatibility evidence, user documentation, and final isolated review.
- follow_up: Advance TEST to DONE, create the one required local commit, ordinary-push the existing branch, refresh Draft PR #1, and wait for exact-head ordinary CI. Keep release jobs/skips and pending promotion truthfully separated; do not Ready, merge, promote, flip Auto, delete v1, or create a new login session.
- artifact: Required v2 code, schema, tests, architecture/migration/user docs, Master Plan, release checklist, skill manifest, and this canonical test report exist. The authorized tracked task-directory exception freezes after DONE except for final delivery metadata already required by RQ-34.
- drift: The TEST candidate contains only the declared RQ-34 documentation/process and Critical dry-run closure surfaces. Normal and Quality validators pass; their historical advisory artifact-drift warnings do not override direct repo-root existence/diff inspection. Staged and untracked counts are zero.
- follow_up_decision: Do not create a second task or Master Plan for RQ-34. Default Promotion / Stable and post-Stable v1 retirement remain separate future decisions requiring explicit authorization.
- memory_spec_update: none; no external memory/spec write is needed or authorized, and `plan.md` remains the sole Master Plan.
- current_state: TEST pass on `codex/thin-harness-v2-refactor`, based on HEAD `4ff92a325e4956150ad7e4ad4a0aa69c3fb3f542` plus the recorded dirty candidate; awaiting canonical `TEST -> DONE`, final commit/push, Draft PR refresh, and exact-head ordinary CI.
- key_decisions:
  - decision: Treat public v2 opt-in engineering completion separately from Default Promotion / Stable qualification.
    why: Current code, compatibility, docs, and ordinary verification pass, while external performance/release evidence remains explicitly unavailable or unexecuted and must not block or masquerade as the public Harness milestone.
  - decision: Keep v1 installed and executable after DONE.
    why: Existing tasks, immediate rollback, migration safety, and post-Stable retirement authorization remain hard compatibility boundaries.
- next_actions:
  - Run artifact validators, then use the canonical stage driver for `TEST -> DONE`.
  - Stage the exact intended tracked files, inspect the cached diff, and commit once as `thin-v2(RQ-34): reconcile delivery milestone and task truth`.
  - Ordinary-push `codex/thin-harness-v2-refactor`, update Draft PR #1 without changing Draft state, and wait for exact-head ordinary PR CI.
