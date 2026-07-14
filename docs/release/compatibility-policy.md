# Thin Harness v2 compatibility and retirement policy

## Gated default

`HARNESS_PROTOCOL=auto` is artifact-first. Existing `.assistant/runtime/tasks/{task_id}/task.json` selects v2; a legal `docs/tasks/{task_id}/plan.md` selects v1. Only a task with no existing artifact may use the v2 default, and only when a workspace-contained `rollout-eligibility/v1` report is supplied through `HARNESS_V2_ELIGIBILITY_REPORT` and validates against the current distribution revision and source digests.

The report must contain passing behavior, full `Suite all` hard-safety and v1 compatibility, Direct performance, core install rollback, and full install rollback gates. Its source digest covers the shipped entry, policy, runtime hook, migration, installer, skill, and validation surfaces. Missing, malformed, tampered, stale, failed, blocked, simulated, or unavailable evidence selects v1 and returns a diagnostic reason. `HARNESS_PROTOCOL=v1` is the permanent immediate rollback switch; explicit v2 remains available for a new task and never overrides an existing v1 artifact.

Generate the report with:

```powershell
pwsh -NoProfile -NonInteractive -File .\scripts\generate-v2-rollout-report.ps1 `
  -RepoRoot $PWD `
  -OutputPath .\.assistant\runtime\rollout\v2-eligibility.json
```

Use `-RequireEligible` only in a release operation that must stop when any gate is not pass. Report output contains only command identities and SHA-256 evidence digests, not captured prompts, credentials, private absolute paths, or command output.

## v1 deprecation without removal

Selecting v1 emits a deprecation warning but does not change behavior. This task does not delete v1, automatically migrate a task, move the five-stage scripts, or weaken install, update, uninstall, recovery, validation, migration, and rollback paths. Existing v1 tasks continue through `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`.

No v1 source may be removed until a later, separately authorized task proves there are no active v1 tasks, a complete external release cycle has been marked stable, rollback evidence is retained, and the removal has its own migration and compatibility approval. PR-14 implements and verifies the gated switch; it does not claim that external release cycle has occurred.
