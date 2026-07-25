# Thin Harness v2 compatibility and retirement policy

## Canonical Default Promotion contract

The current DP-02 through DP-05 qualification dependencies and completion criteria are defined in [default-promotion-gates.md](default-promotion-gates.md). The tracked DP-01 task files are a historical pre-archive snapshot. This policy continues to describe implemented compatibility behavior; any narrower implementation called out below is a DP-02 gap and does not weaken the Canonical Gate contract.

## Gated default

Protocol resolution is artifact-first. Existing `.assistant/runtime/tasks/{task_id}/task.json` selects v2; otherwise a legal `docs/tasks/{task_id}/plan.md` selects v1, regardless of conflicting new-task preferences. For a task with no artifact, an explicit maintenance override or `HARNESS_PROTOCOL` comes next, then strict user-owned workspace config `.assistant/config/protocol.json`. The config is `harness-protocol-config/v1` with only `new_task_protocol=auto|v1|v2`; `enable-v2` is the current public project opt-in, while `disable-v2` is an immediate v1 stop-loss. Install, update, and uninstall preserve its exact bytes and never claim it as a managed asset.

Only a new task still selected as `auto` enters report discovery: explicit `EligibilityReportPath`, then `HARNESS_V2_ELIGIBILITY_REPORT`, then Canonical Final `.assistant/runtime/rollout/v2-eligibility.json`; only when Final is absent may discovery consider `.assistant/runtime/rollout/v2-canary-candidate.json` plus `.assistant/runtime/rollout/v2-canary-authorization.json`. The first selected report source must be workspace-contained and validate against the current clean distribution revision and source digests. A selected explicit/environment path or an existing invalid Final fails closed to v1 and never falls through to Candidate. Workspace `enable-v2` does not assert that any release gate passed and is not Default Promotion.

The active machine report contract is `rollout-eligibility/v2`. It enumerates all 19 blocking Canonical Gates and has two mutually exclusive phases: `canary-candidate` is `eligible=false` with G13/G15/G16 exactly `not_run`, while `final-default` is `eligible=true` only when every blocking Gate is `pass`. G12 is not a Schema digest: it binds a phase/source-specific `rollout-report-review-receipt/v1` over a non-authorizing Review Payload. Candidate Review cannot be reused for Final.

The old five-Gate `rollout-eligibility/v1` fields, digest and validation meaning remain unchanged, but the report is historical diagnostic evidence only. Resolver may expose its historical all-pass or first failing-Gate reason; it always selects v1. Promotion rejects even a current valid v1 report with `rollout-promotion-v1-historical-only`. No v1 report can authorize Default Promotion, Canary or a new `auto -> v2`, and it cannot be wrapped or copied into v2 eligibility. `HARNESS_PROTOCOL=v1` remains the permanent immediate rollback switch; explicit v2 remains available for a new task and never overrides an existing v1 artifact.

Generator consumes one strict `rollout-evidence-set/v1` containing the phase, current source revision, exact Host binding and the 18 non-G12 Gate references. Each reference requires the evidence Contract, Artifact path, raw file digest, source revision, and producer/receipt identity. Caller-declared status is never authoritative: Generator reopens the ordinary file, verifies raw bytes/digest, and delegates status derivation to the named strict Adapter. Because DP-02B/DP-02C formal Adapters remain unwired, current public input produces `rollout-evidence-provenance-unverified` or a non-authorizing Review Payload; hand-written/fixture JSON cannot produce a promotable report. The former Model/Host parameters remain historical-only failures.

The current candidate is qualified only for Codex CLI/service `0.144.4`; the existing version pin is not a compatible-version range. Report fields cannot prove the running Host. Report-driven Auto and Promotion post-validation require a trusted caller-supplied `rollout-observed-host-context/v1` with exact CLI/service versions, Hook/invocation/request-send Contracts, UTC observation time, and `context_digest`. Missing Context, actual 0.144.5, Contract drift, future observation, or digest mismatch returns an explicit reason and selects v1. Explicit/workspace v2 and existing v1/v2 Artifacts keep their prior precedence.

The following commands show only the fail-closed DP-02A offline interfaces. `$gateEvidencePath`, Review Receipt, and Observed Host Context must eventually come from separately validated producers; current unwired inputs cannot authorize:

```powershell
$trustedValidationRoot = $env:DEV_HARNESS_VALIDATION_TEMP_ROOT
if ([string]::IsNullOrWhiteSpace($trustedValidationRoot)) { throw 'DEV_HARNESS_VALIDATION_TEMP_ROOT is required' }
$releaseRoot = Join-Path ([IO.Path]::GetFullPath($trustedValidationRoot)) ('thin-v2-release-' + [guid]::NewGuid().ToString('N'))
$workspaceRoot = 'C:\path\to\workspace'
$gateEvidencePath = Join-Path $releaseRoot 'rollout-evidence-set.json'
$reviewPayloadPath = Join-Path $releaseRoot 'rollout-review-payload.json'
$reviewReceiptPath = Join-Path $releaseRoot 'rollout-review-receipt.json'
$observedHostContextPath = Join-Path $releaseRoot 'rollout-observed-host-context.json'

pwsh -NoProfile -NonInteractive -File .\scripts\generate-v2-rollout-report.ps1 `
  -RepoRoot $PWD `
  -GateEvidencePath $gateEvidencePath `
  -CreateReviewPayload `
  -OutputPath $reviewPayloadPath

# After a separate read-only review of that exact payload:
pwsh -NoProfile -NonInteractive -File .\scripts\generate-v2-rollout-report.ps1 `
  -RepoRoot $PWD `
  -ReviewPayloadPath $reviewPayloadPath `
  -ReviewReceiptPath $reviewReceiptPath `
  -OutputPath (Join-Path $releaseRoot 'v2-eligibility.json')

pwsh -NoProfile -NonInteractive -File .\scripts\promote-v2-rollout-report.ps1 `
  -RepoRoot $PWD `
  -WorkspaceRoot $workspaceRoot `
  -ReportPath (Join-Path $releaseRoot 'v2-eligibility.json') `
  -ReviewReceiptPath $reviewReceiptPath `
  -ObservedHostContextPath $observedHostContextPath

# A reviewed Candidate additionally requires all three:
#   -AuthorizeCanary -AuthorizedBy '<operator>' -DurationHours 24
```

`$releaseRoot` must be an absolute ordinary directory outside the distribution repository, target workspace, Git metadata, and every credential home. Candidate Promotion requires explicit owner plus `-ExpiresAtUtc` or bounded `-DurationHours`; the authorization includes `authorization_id`, `authorized_by`, `issued_at_utc`, `expires_at_utc`, Observed Host digest, `new_tasks_only=true`, and `status=granted`, with a seven-day maximum. Candidate writes only `v2-canary-candidate.json` and `v2-canary-authorization.json`. Final writes `v2-eligibility.json` and transactionally deletes the other two. One physical-Workspace mutex, per-file CAS, ordinary-file/hardlink/ADS/reparse guards, exact-byte verification, and three-preimage rollback cover every mutation. This cooperative audit record is not cryptographic identity authentication.

`HOST_BENCHMARK_CODEX_HOME` must name a dedicated, independently logged-in Codex home accepted by both real producers. In GitHub Actions, `release-model` and `release-host` require `self-hosted`, `Windows`, and the repository-dedicated producer label supplied by `THIN_V2_RELEASE_RUNNER`; `release-full` requires `self-hosted`, `Windows`, and a separate label supplied by `THIN_V2_RELEASE_AGGREGATOR_RUNNER`. There is no hosted-runner fallback. Because `runs-on` is resolved before a job's environment is declared, both selectors must be repository/org-level variables, not environment-level variables; a missing value fails closed. `HOST_BENCHMARK_CODEX_HOME` supplies only the non-secret directory path to the producers. At runtime each producer hashes its Windows account SID together with the workflow run id and attempt using SHA-256 and exposes only that run-scoped digest. The aggregator recomputes its digest with the same run identity and fails closed if it matches either producer, so different labels are routing inputs rather than proof of account separation. It also rejects the default `$HOME/.codex/auth.json` and the credential-bearing environment variables `HOST_BENCHMARK_CODEX_HOME`, `CODEX_HOME`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`, and `OPENAI_API_KEY`; it never reruns a producer or receives credential payloads. Both runner accounts carry no unrelated secrets or workloads and have PowerShell 7.3+, Git, and the version-bound Codex CLI/service `0.144.4` installed and discoverable. Release jobs bind `thin-v2-release`, currently run only the allowlisted `main`, `codex/harness-distribution`, and `codex/thin-harness-v2-refactor` refs, and use checkout with `persist-credentials: false`; the current Default Promotion branch is not yet routed and DP-02 must add it without weakening the fail-closed ref boundary. Configure the environment with matching branch restrictions and required review where available. Do not copy a personal `auth.json`, OAuth token, or credential into the repository, Actions variables/secrets, workflow input, or release artifact. Missing runner configuration, authentication, or an incompatible Codex version fails closed or produces unavailable evidence.

CI still defines the pre-DP-02A two-producer release jobs, but the current Default Promotion branch is not routed and the `release-full` command still uses the rejected legacy Generator parameters. That mismatch is an intentional fail-closed DP-02B/DP-02C blocker, not a passing release route. The configured model/host/aggregate budgets remain 120/240/120 minutes and must be preserved by the later wiring. DP-02A does not modify runner configuration, run release jobs or aggregate formal Model, Cognitive Host, Installed Desktop or lifecycle evidence.

Report output contains only sanitized observations, command identities, and SHA-256 evidence digests, not captured prompts, credentials, private absolute paths, or raw command output. A failed or uploaded report is audit evidence, not authorization to select v2.

The CI artifact is persistence for review and is never downloaded automatically. Install, update, and uninstall preserve all three Canonical rollout files but never generate, manage, restore, or remove them. A workspace without a valid Final, or without a complete unexpired Candidate/Authorization pair and valid actual Host Context, selects v1. A legacy `harness-host-benchmark-report/v1` remains historical/unavailable, and `rollout-eligibility/v1` remains diagnostic-only. Completing this DP-02A correction does not claim that release-full, Model40, either real Host 3x3, formal lifecycle Evidence, real Promotion, Auto Flip, Canary, or Stable has occurred.

## v1 deprecation without removal

Selecting v1 emits a deprecation warning but does not change behavior. This task does not delete v1, automatically migrate a task, move the five-stage scripts, or weaken install, update, uninstall, recovery, validation, migration, and rollback paths. Existing v1 tasks continue through `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`.

No v1 source may be removed until a later, separately authorized task proves there are no active v1 tasks, a complete external release cycle has been marked stable, rollback evidence is retained, and the removal has its own migration and compatibility approval. PR-14 implements and verifies the gated switch; it does not claim that external release cycle has occurred.
