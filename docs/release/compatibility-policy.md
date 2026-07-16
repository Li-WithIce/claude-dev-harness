# Thin Harness v2 compatibility and retirement policy

## Gated default

`HARNESS_PROTOCOL=auto` is artifact-first. Existing `.assistant/runtime/tasks/{task_id}/task.json` selects v2; a legal `docs/tasks/{task_id}/plan.md` selects v1. Only a task with no existing artifact may use the v2 default, and only when a workspace-contained report supplied through `HARNESS_V2_ELIGIBILITY_REPORT` validates against the current clean distribution revision and source digests.

The report must bind a passing 40-session real model evaluation, a passing real bare/v1/v2 benchmark with exactly three source-bound trials per protocol, full `Suite all` hard-safety and v1 compatibility, and core/full install rollback. `tests/run-scenario-evals.ps1` remains the deterministic PR contract and `scripts/benchmark-harness.ps1` remains a local fixture-replay diagnostic; neither is release model or host-performance evidence. The full suite exposes verifier output, so any structured `[UNAVAILABLE]` result makes compatibility unavailable rather than pass. All release inputs must identify the same clean, stable revision. Missing, malformed, tampered, stale, dirty, failed, blocked, simulated, or unavailable evidence selects v1 and returns a diagnostic reason. `HARNESS_PROTOCOL=v1` is the permanent immediate rollback switch; explicit v2 remains available for a new task and never overrides an existing v1 artifact.

Generate the two real reports and then consume them with the rollout generator:

```powershell
$releaseRoot = Join-Path $PWD '.assistant\运行时\release-qualification'
$codexHome = $env:HOST_BENCHMARK_CODEX_HOME

pwsh -NoProfile -NonInteractive -File .\scripts\run-model-evals.ps1 `
  -RepoRoot $PWD -Model gpt-5.6-sol -Reasoning max -CodexHome $codexHome `
  -OutputPath (Join-Path $releaseRoot 'model-eval.json')

pwsh -NoProfile -NonInteractive -File .\scripts\run-host-benchmark.ps1 `
  -RepoRoot $PWD -Model gpt-5.6-sol -Reasoning max -CodexHome $codexHome -Trials 3 `
  -OutputPath (Join-Path $releaseRoot 'host-benchmark.json')

pwsh -NoProfile -NonInteractive -File .\scripts\generate-v2-rollout-report.ps1 `
  -RepoRoot $PWD `
  -ModelEvalReportPath (Join-Path $releaseRoot 'model-eval.json') `
  -HostBenchmarkReportPath (Join-Path $releaseRoot 'host-benchmark.json') `
  -OutputPath .\.assistant\runtime\rollout\v2-eligibility.json `
  -RequireEligible
```

`HOST_BENCHMARK_CODEX_HOME` must name a dedicated, independently logged-in Codex home accepted by both real runners. In GitHub Actions, repository variable `THIN_V2_RELEASE_RUNNER` selects one repository-dedicated custom Windows runner label and `HOST_BENCHMARK_CODEX_HOME` supplies only the non-secret directory path on that runner; the default hosted runner remains fail closed when no suitable home exists. The runner uses an isolated OS account, carries no unrelated secrets or workloads, and has PowerShell 7.3+, Git, and the version-bound Codex CLI/service `0.144.4` installed and discoverable. Release producer jobs run only the allowlisted `main`, `codex/harness-distribution`, and `codex/thin-harness-v2-refactor` refs, bind the `thin-v2-release` environment, and use checkout with `persist-credentials: false`; configure that environment with matching branch restrictions and required review where available. Do not copy a personal `auth.json`, OAuth token, or credential into the repository, Actions variables/secrets, workflow input, or release artifact. Missing authentication or an incompatible Codex version produces unavailable evidence.

CI runs model and host qualification in separate bounded, sequential jobs so shared account/cache effects do not overlap. A failed producer remains failed, while its upload step still runs when the workflow was not cancelled. Each job creates a fresh run-id/attempt/job-specific evidence directory, rejects a pre-existing directory, and requires its intermediate artifact to contain exactly its one fixed JSON. The `release-full` job uses `needs` with `!cancelled()` to download whichever reports exist, runs the generator with `-RequireEligible`, and uploads only the two fixed inputs and the rollout JSON; user cancellation is never resisted by `always()`. A missing individual report is represented by an unavailable rollout gate. CI gives model calls 120 seconds, preserves the evidence-backed 900-second host call bound, and caps model/host/aggregate jobs at 120/180/120 minutes.

Report output contains only sanitized observations, command identities, and SHA-256 evidence digests, not captured prompts, credentials, private absolute paths, or raw command output. A failed or uploaded report is audit evidence, not authorization to select v2.

The CI artifact is persistence for review only. This release step does not download or install the report into a workspace and does not add default report discovery. Until that separate delivery path exists, a workspace without an explicit valid `HARNESS_V2_ELIGIBILITY_REPORT` continues to select v1.

## v1 deprecation without removal

Selecting v1 emits a deprecation warning but does not change behavior. This task does not delete v1, automatically migrate a task, move the five-stage scripts, or weaken install, update, uninstall, recovery, validation, migration, and rollback paths. Existing v1 tasks continue through `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`.

No v1 source may be removed until a later, separately authorized task proves there are no active v1 tasks, a complete external release cycle has been marked stable, rollback evidence is retained, and the removal has its own migration and compatibility approval. PR-14 implements and verifies the gated switch; it does not claim that external release cycle has occurred.
