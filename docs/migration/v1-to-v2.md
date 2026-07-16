# v1 to v2 task migration

The v1 and v2 task protocols coexist. Existing task artifacts select the protocol before routing:

1. `.assistant/runtime/tasks/{task_id}/task.json` selects v2.
2. Otherwise, a legal `docs/tasks/{task_id}/plan.md` selects v1.
3. With neither artifact, `auto` resolves a rollout report in fixed priority order: explicit `EligibilityReportPath`, `HARNESS_V2_ELIGIBILITY_REPORT`, then `.assistant/runtime/rollout/v2-eligibility.json`. It selects v2 only when the chosen workspace-contained, revision-bound report has every required gate at `pass`; a selected higher-priority missing or invalid path does not fall through. Otherwise it selects v1 with a diagnostic reason. Explicit `HARNESS_PROTOCOL=v2` is a development/diagnostic opt-in for a new task, not the ordinary desktop workflow.

Use `pwsh -File scripts/task.ps1 protocol -TaskId {task_id} -WorkspaceRoot {workspace}` for a read-only resolution. An explicit protocol that conflicts with an existing artifact fails closed. Promotion of external release evidence is explicit, offline, and separate from task migration; it never converts an existing v1 task. `HARNESS_PROTOCOL=v1` remains the rollback switch and never converts or deletes a task. See `docs/release/compatibility-policy.md` for report generation, promotion, default gating, deprecation, and retirement conditions.

## Frozen v1 path

The v1 compatibility path remains:

- source of stage truth: `docs/tasks/{task_id}/plan.md` frontmatter;
- validation: `scripts/validate-lite-artifacts.ps1`;
- stage transition: `scripts/advance-stage.ps1`;
- stages: `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`;
- recovery mirrors: `.assistant/运行时/*.md` when the installed v1 workspace uses them.

The v1 scripts reject a task once its v2 `task.json` exists. They are not moved, deleted, or recursively forwarded to v2.

## Explicit migration

Active v1 tasks and `DONE` tasks are not migrated. Switch away from the v1 task first, then generate a zero-write report:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\migrate-task-v1-to-v2.ps1 `
  -TaskId {task_id} `
  -ExpectedV1Stage {stage} `
  -WorkspaceRoot {workspace} `
  -DryRun
```

Review the source plan digest, target Contract digest, imported history references, and `dry_run_digest`. Formal migration requires both the reviewed digest and an explicit confirmation:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\migrate-task-v1-to-v2.ps1 `
  -TaskId {task_id} `
  -ExpectedV1Stage {stage} `
  -WorkspaceRoot {workspace} `
  -ExpectedDryRunDigest {sha256_digest} `
  -ConfirmMigration
```

The command revalidates the complete v1 artifact, reacquires the v1 task lock, and verifies the digest again. It then atomically publishes one complete v2 task directory containing `contract.json`, `task.json`, and `events.jsonl`. The imported task starts as `paused`; the event records the v1 plan and history by digest/reference only and does not infer that a v2 capability has run.

The original v1 `plan.md` is never rewritten, moved, or deleted. After successful publication it is an immutable migration reference: the v2 artifact wins detection and the v1 stage command refuses further writes. A controlled pre-publish failure removes staging content and any empty migration-created parent directories, leaving the v1 workspace snapshot unchanged.

## Rollback

- Before successful publication: fix the reported issue and rerun the dry-run; no v1 artifact needs restoration.
- After successful publication: preserve the v2 task as read-only evidence. Do not delete it to reactivate v1 implicitly.
- For unrelated or unmigrated work, set `HARNESS_PROTOCOL=v1` to force the v1 path. A conflicting v2 task still fails closed rather than being opened by v1 tooling.
