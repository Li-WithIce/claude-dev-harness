# Thin Harness v2 compatibility and retirement policy

## Gated default

`HARNESS_PROTOCOL=auto` is artifact-first. Existing `.assistant/runtime/tasks/{task_id}/task.json` selects v2; a legal `docs/tasks/{task_id}/plan.md` selects v1. Only a task with no existing artifact may use the v2 default. Report discovery has one fixed priority: an explicit `EligibilityReportPath`, then `HARNESS_V2_ELIGIBILITY_REPORT`, then `.assistant/runtime/rollout/v2-eligibility.json`. The first selected source must be workspace-contained and validate against the current clean distribution revision and source digests. A selected explicit or environment path that is empty, missing, or invalid fails closed to v1; discovery never falls through to canonical evidence.

The report must bind a passing 40-session real model evaluation, three mutually independent clean bare/v1/v2 benchmark groups with exactly three source-bound trials per protocol in each group, full `Suite all` hard-safety and v1 compatibility, and core/full install rollback. Every model session verifies the same selected executable reports exactly `codex-cli 0.144.4` before invocation and must emit `codex-invocation-telemetry/v2` carrying that version; the consumer accepts only `harness-model-eval-report/v2` whose top-level expected version and all 40 session records match. A missing or mismatched version, schema, or session record fails closed and cannot qualify. Each benchmark group must independently pass the latency and request-reduction thresholds; nine pooled trials or one 3x3 group copied three times are not release evidence. `tests/run-scenario-evals.ps1` remains the deterministic PR contract and `scripts/benchmark-harness.ps1` remains a local fixture-replay diagnostic; neither is release model or host-performance evidence. The full suite exposes verifier output, so any structured `[UNAVAILABLE]` result makes compatibility unavailable rather than pass. All release inputs must identify the same clean, stable revision. Missing, malformed, tampered, stale, dirty, failed, blocked, simulated, or unavailable evidence selects v1 and returns a diagnostic reason. `HARNESS_PROTOCOL=v1` is the permanent immediate rollback switch; explicit v2 remains available for a new task and never overrides an existing v1 artifact.

Generate the two real reports and then consume them with the rollout generator:

```powershell
$releaseRoot = Join-Path ([IO.Path]::GetTempPath()) ('thin-v2-release-' + [guid]::NewGuid().ToString('N'))
$workspaceRoot = 'C:\path\to\workspace'
$codexHome = $env:HOST_BENCHMARK_CODEX_HOME

pwsh -NoProfile -NonInteractive -File .\scripts\run-model-evals.ps1 `
  -RepoRoot $PWD -Model gpt-5.6-sol -Reasoning max -CodexHome $codexHome `
  -OutputPath (Join-Path $releaseRoot 'model-eval.json')

pwsh -NoProfile -NonInteractive -File .\scripts\run-host-benchmark.ps1 `
  -RepoRoot $PWD -Model gpt-5.6-sol -Reasoning max -CodexHome $codexHome -Groups 3 -Trials 3 `
  -OutputPath (Join-Path $releaseRoot 'host-benchmark.json')

pwsh -NoProfile -NonInteractive -File .\scripts\generate-v2-rollout-report.ps1 `
  -RepoRoot $PWD `
  -ModelEvalReportPath (Join-Path $releaseRoot 'model-eval.json') `
  -HostBenchmarkReportPath (Join-Path $releaseRoot 'host-benchmark.json') `
  -OutputPath (Join-Path $releaseRoot 'v2-eligibility.json') `
  -RequireEligible

pwsh -NoProfile -NonInteractive -File .\scripts\promote-v2-rollout-report.ps1 `
  -RepoRoot $PWD `
  -WorkspaceRoot $workspaceRoot `
  -ReportPath (Join-Path $releaseRoot 'v2-eligibility.json')
```

`$releaseRoot` must be an absolute ordinary directory outside the distribution repository, the target workspace, Git metadata, and every credential home. The promotion entry has no output-path, network, download, or authentication option. It accepts only a strict `eligible=true` report bound to the current clean revision, preserves the verified default-stream input bytes, serializes cooperative publishers that use this promotion entry on the physical-workspace mutex, rejects target drift detected by digest CAS before atomic replacement, verifies canonical discovery, and restores the exact previous report bytes if a post-publish check fails. Reparse aliases, hardlinks, alternate data streams, physical aliases, oversized source/preimage files, and stale source state fail closed. This does not serialize arbitrary same-account writers; hostile path or byte replacement outside the supported entry remains outside this release contract and requires OS-account/ACL isolation. The entry does not obfuscate scripts or bypass endpoint security.

`HOST_BENCHMARK_CODEX_HOME` must name a dedicated, independently logged-in Codex home accepted by both real producers. In GitHub Actions, `release-model` and `release-host` require `self-hosted`, `Windows`, and the repository-dedicated producer label supplied by `THIN_V2_RELEASE_RUNNER`; `release-full` requires `self-hosted`, `Windows`, and a separate label supplied by `THIN_V2_RELEASE_AGGREGATOR_RUNNER`. There is no hosted-runner fallback. Because `runs-on` is resolved before a job's environment is declared, both selectors must be repository/org-level variables, not environment-level variables; a missing value fails closed. `HOST_BENCHMARK_CODEX_HOME` supplies only the non-secret directory path to the producers. At runtime each producer hashes its Windows account SID together with the workflow run id and attempt using SHA-256 and exposes only that run-scoped digest. The aggregator recomputes its digest with the same run identity and fails closed if it matches either producer, so different labels are routing inputs rather than proof of account separation. It also rejects the default `$HOME/.codex/auth.json` and the credential-bearing environment variables `HOST_BENCHMARK_CODEX_HOME`, `CODEX_HOME`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`, and `OPENAI_API_KEY`; it never reruns a producer or receives credential payloads. Both runner accounts carry no unrelated secrets or workloads and have PowerShell 7.3+, Git, and the version-bound Codex CLI/service `0.144.4` installed and discoverable. Release jobs bind `thin-v2-release`, run only the allowlisted `main`, `codex/harness-distribution`, and `codex/thin-harness-v2-refactor` refs, and use checkout with `persist-credentials: false`; configure the environment with matching branch restrictions and required review where available. Do not copy a personal `auth.json`, OAuth token, or credential into the repository, Actions variables/secrets, workflow input, or release artifact. Missing runner configuration, authentication, or an incompatible Codex version fails closed or produces unavailable evidence.

CI runs model and host qualification in separate bounded, sequential jobs so shared account/cache effects do not overlap. The host producer emits one v2 report containing three independently named and source-snapshotted groups, 27 total observations, three distinct group namespace digests, and three independently recomputed threshold results; the consumer rejects duplicate group identities, roots, trial identities, or recursively canonicalized trial payloads. A failed producer remains failed, while its upload step still runs when the workflow was not cancelled. Each job creates a fresh run-id/attempt/job-specific evidence directory, rejects a pre-existing directory, and requires its intermediate artifact to contain exactly its one fixed JSON. The credential-blind `release-full` job uses its separate unlogged runner account and `needs` with `!cancelled()` to download whichever reports exist, runs the generator with `-RequireEligible`, and uploads only the two fixed inputs and the rollout JSON; user cancellation is never resisted by `always()`. A missing individual report is represented by an unavailable rollout gate. CI gives model calls 120 seconds, preserves the evidence-backed 900-second bound for each host invocation, and caps model/host/aggregate jobs at 120/180/120 minutes.

Report output contains only sanitized observations, command identities, and SHA-256 evidence digests, not captured prompts, credentials, private absolute paths, or raw command output. A failed or uploaded report is audit evidence, not authorization to select v2.

The CI artifact is persistence for review and is never downloaded automatically. After an authorized operator obtains its rollout JSON as an external ordinary file, the explicit promotion command above is the only supported delivery path into a workspace. Install, update, and uninstall preserve the canonical report but never generate, back it up as a managed asset, restore, or remove it. A workspace without a valid selected report, including one without canonical evidence, continues to select v1. A legacy `harness-host-benchmark-report/v1` with a valid strict shape that is still bound to the current clean source remains historical evidence and is classified as `unavailable` for current qualification; stale, malformed, dirty, or tampered v1 reports remain invalid and fail. No v1 report can be wrapped or copied into eligibility; a new three-group v2 run is required. Completing this delivery mechanism does not claim that release-full, the real 40-session evaluation, the three independent clean 3x3 groups, or a complete external Stable cycle has occurred.

## v1 deprecation without removal

Selecting v1 emits a deprecation warning but does not change behavior. This task does not delete v1, automatically migrate a task, move the five-stage scripts, or weaken install, update, uninstall, recovery, validation, migration, and rollback paths. Existing v1 tasks continue through `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`.

No v1 source may be removed until a later, separately authorized task proves there are no active v1 tasks, a complete external release cycle has been marked stable, rollback evidence is retained, and the removal has its own migration and compatibility approval. PR-14 implements and verifies the gated switch; it does not claim that external release cycle has occurred.
