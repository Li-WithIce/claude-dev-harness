# v1 to v2 task migration

TK-03 makes the active Runtime v2-only. This is an explicit architecture
change, not evidence that Qualification, Promotion or Stable passed. See the
[transition contract](../architecture/tk03-v2-only-transition.md).

## Active admission and recovery

1. A valid `.assistant/runtime/tasks/{task_id}/task.json` retains v2
   precedence, including while new work is paused. Invalid v2 state fails closed.
2. A legacy `docs/tasks/{task_id}/plan.md` without v2 state is detected by
   existence alone and rejected with `legacy-task-requires-explicit-migration`.
   Ordinary Runtime does not parse or execute the plan.
3. New work accepts only `auto|v2`. Explicit `v1` is retired. New
   `harness-protocol-config/v2` config adds `new_work=enabled|paused`;
   even explicit v2 must respect a pause.
4. Valid historical config v1 bytes with `auto|v2` remain readable without
   rewriting. Historical `v1` configuration is rejected.
5. New `auto` with no Runtime Decision admits v2. An existing invalid,
   unavailable or non-v2 Decision blocks new work. The historical Decision
   Schema and digest remain unchanged; a separate admission Schema restricts
   current acceptance. Release Reports and Review Receipts do not route tasks.

Use `pwsh -File scripts/task.ps1 protocol -TaskId {task_id} -WorkspaceRoot {workspace}`
for read-only resolution. Existing v2 identity wins over new-task preferences;
preferences do not convert, downgrade or delete tasks.

## Retained history, not an executable v1 path

The old plan frontmatter, stage definitions, validators and recovery mirrors
are retained for explicit migration/history maintenance and the separate
Sunset removal gates. `scripts/advance-stage.ps1` now returns a zero-write
`v1-lifecycle-retired` diagnostic before loading its historical implementation.

The strict legacy plan parser lives in `modules/legacy-v1` and is loaded only
by explicit migration. Core/governed/full do not install the old lifecycle
skills, shim, stage wrappers or task mirrors. Old workspace files are not
automatically reclassified as disposable user data.

## Explicit migration

A v1 task selected by the old current pointer and a `DONE` task cannot be
migrated. Releasing a current pointer is a separate, explicitly authorized
operation, not a reason to run a retired stage command. Preserve all old plan
and history bytes, then request a zero-write native report:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\migrate-task-v1-to-v2.ps1 `
  -TaskId {task_id} `
  -ExpectedV1Stage {stage} `
  -WorkspaceRoot {workspace} `
  -DryRun
```

Review the source plan digest, target Contract digest, imported history
references and `dry_run_digest`. Formal migration requires the reviewed digest
and explicit confirmation:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\migrate-task-v1-to-v2.ps1 `
  -TaskId {task_id} `
  -ExpectedV1Stage {stage} `
  -WorkspaceRoot {workspace} `
  -ExpectedDryRunDigest {sha256_digest} `
  -ConfirmMigration
```

The command revalidates the complete v1 artifact, reacquires the v1 task lock,
and verifies the digest again. It atomically publishes one complete v2 task
directory containing `contract.json`, `task.json` and `events.jsonl`. The
import starts as `paused`; history references and digests do not imply that
any v2 capability or Qualification executed.

The original `plan.md` is never rewritten, moved or deleted. Successful
publication makes it an immutable migration reference; v2 artifact precedence
then applies. A controlled pre-publish failure removes only migration staging
and any empty migration-created parent directories, leaving the source
workspace snapshot unchanged.

## Stop-loss

- Before publication: correct the reported issue and obtain a fresh dry-run.
- After publication: preserve v2 state and history; never delete state to
  reactivate v1.
- `disable-v2` pauses new work and preserves existing v2 recovery.
  `enable-v2` or `reset-auto` explicitly re-enables new work.
- A known-good v2 distribution can be restored only with explicit approval.
  `HARNESS_PROTOCOL=v1` is not a rollback path.
- Physical legacy source removal still requires all ten current Sunset gates
  and separate approval of the exact removal diff.
