# DP-01 Qualification Baseline and Scope Freeze

- task_id: thin-harness-v2-default-promotion
- task_version_pre_verification: 3
- contract_digest: sha256:912ccf5de9935865e847754821e83e73b8e311c3cf69b0e705cde9d4dc319aaf
- source_revision: d9a095fe177c4206e97db6785464ef9ea4a12101
- conclusion: Default Promotion is not eligible. DP-01 is complete; implementation and formal qualification remain blocked.

## Isolation and Bootstrap

- Stable RepoRoot: `D:\data\dev-harness`
- Stable branch: `codex/harness-v2-public-optin-beta`
- Stable Tag/HEAD: `v2-public-optin-beta.1` / `d9a095fe177c4206e97db6785464ef9ea4a12101`
- Development WorkspaceRoot: `D:\data\dev-harness-next`
- Development branch/HEAD: `codex/harness-v2-default-promotion` / `d9a095fe177c4206e97db6785464ef9ea4a12101`
- Preflight result: both Worktrees clean, distinct paths/branches, no merge/rebase/cherry-pick/revert/bisect, development HEAD contains the stable Tag.
- Stable Harness bootstrap: committed Manifest `install-manifest/v1.2`, governed preset, RepoRoot `D:\data\dev-harness`, WorkspaceRoot `D:\data\dev-harness-next`.
- Workspace shim binding: `D:\data\dev-harness\scripts\task.ps1` with pinned RepoRoot `D:\data\dev-harness` and WorkspaceRoot `D:\data\dev-harness-next`.
- User-level managed Skill/Hook source: `D:\data\dev-harness`; no managed reference to dev-harness-next was found.
- Protocol: `selected_protocol=v2`, `preference_source=workspace-config` for a new task; existing task now resolves through `existing-v2-task-state`. `HARNESS_PROTOCOL` is unset and not required for ordinary workspace use.

## Qualification Gate Matrix

| gate_id | expected_result | existing_implementation | existing_tests | current_status | missing_evidence | external_dependency | estimated_runtime | blocks_default_flip | recommended_next_batch |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DP-G01-MODEL40 | One clean `harness-model-eval-report/v2` with 20 cases × 2 paraphrases, all 40 real sessions on `gpt-5.6-sol/max` and Codex `0.144.4`, hard gates passing. | `scripts/run-model-evals.ps1`, `Harness.ModelEval.psm1`, observation schema and fixed dataset are present; definition-only mode passes. | `verify-model-eval-runner.ps1` 39/39; `verify-rollout-evidence.ps1` covers count/version/session semantics; `run-model-evals.ps1 -ValidateOnly` passes. | environment-blocked | No 40-session real report; no source-bound invocation telemetry. | Dedicated independently logged-in Codex Home and release producer runner; local Codex version is correct but `HOST_BENCHMARK_CODEX_HOME` is unset. | <=120 min release-model job | true | DP-03 |
| DP-G02-COGNITIVE-HOST-3X3 | Three independent clean groups, each bare/v1/v2 × 3 real trials, all groups independently passing latency and request-send gates. | `scripts/run-host-benchmark.ps1` cognitive path, Trial/OTel helpers and v2 host report consumer are present. | Host qualification 160/160; rollout evidence accepts only three independent 3×3 groups; cognitive `-ValidateOnly` passes. | environment-blocked | No 27 real cognitive observations or passing host report. | Dedicated Codex Home, credentialed Windows producer, exact CLI/service, clean source clone. | <=240 min release-host job | true | DP-03 |
| DP-G03-INSTALLED-DESKTOP-HOST-3X3 | Three independent installed Desktop groups with authoritative runtime protocol/profile/lifecycle and Desktop Hook trust/callability observations. | `-BenchmarkPath installed-desktop-path` installs/verifies/cleans isolated profiles and binds rollout digests, but hard-codes qualification unavailable because the observed surface is only `codex-cli-host-equivalent`. | Host qualification fixture explicitly proves measurement may pass while qualification remains unavailable; installed `-ValidateOnly` passes. | implementation-gap | No authoritative installed Desktop runtime/Hook observation and no qualifying installed report. | Real Codex Desktop host, isolated installed profile, dedicated auth home, eligible rollout input for route probing. | DP-02 <=90 min deterministic work; formal run <=240 min | true | DP-02 |
| DP-G04-CODEX-HOME-RUNNER-ISOLATION | Producer and aggregator use distinct labels/accounts; producers use one dedicated auth home; aggregator is credential-blind; all evidence binds one clean revision. | Host-home layout/mutex/physical path guards and `assert-release-runner-boundary.ps1` are present; workflow separates producer and aggregator. | Runner boundary 10/10; Release validation verifies account digests, labels, credentials and artifact separation. | environment-blocked | No real CI account digests, runner labels, dedicated home or run identity. | Repository/org runner variables, isolated Windows accounts and environment policy. | <=60 min configuration, then included in release jobs | true | DP-03 |
| DP-G05-V2-BARE-1.25 | Every host group independently recomputes median `v2/bare <= 1.25`. | Host runner computes per-group medians and RolloutEvidence revalidates them. | Rollout evidence rejects threshold contradictions and copied/pooled groups; Host qualification covers measurement structure. | evidence-missing | No measured complete bare/v2 trials. | Passing real cognitive and installed Host runs. | Included in each <=240 min host run | true | DP-03 |
| DP-G06-REQUEST-SEND-REDUCTION | Every group independently proves successful request-send reduction >=0.60 from v1 to v2 using Codex `0.144.4` OTel evidence. | Trial/OTel collector records successful WebSocket sends and runner recomputes per-group reduction. | Rollout and Host qualification tests reject unavailable, malformed and contradictory measurements. | evidence-missing | No real OTel-backed v1/v2 request-send measurements. | Exact Codex CLI/service telemetry and passing real Host runs. | Included in each <=240 min host run | true | DP-03 |
| DP-G07-INSTALLED-DESKTOP-GATE | Rollout eligibility contains a distinct passing installed Desktop qualification gate bound to the same clean revision and rollout digest. | Installed path produces a diagnostic report, but rollout generator accepts only one generic Host report and has no installed Desktop gate/input. | Current Host qualification test enforces unavailable; rollout test has no passing installed gate case. | implementation-gap | Missing schema/generator gate, authoritative report and workflow input. | DP-G03 authority plus Desktop host. | <=90 min DP-02 deterministic work | true | DP-02 |
| DP-G08-DESKTOP-WRITER-AUTHORITY | A narrowly scoped installed Desktop qualification writer can perform only the required profile/probe operations with auditable Host authority. | `config.workspace.toml.template` and `harness-write-mcp.ps1` are explicitly qualification-only; installer does not deploy the template; writer lacks v1 stage/build/delete/rename/Git equivalents. | Installation and Host qualification tests preserve this unavailable boundary. | implementation-gap | No supported authoritative Desktop qualification write/probe path. | Codex Desktop native app-server/tool trust and Hook callability. | <=90 min DP-02 deterministic work | true | DP-02 |
| DP-G09-RELEASE-MODEL | `release-model` runs Model40 on an allowed Default Promotion ref and publishes exactly one sanitized report. | Job exists with self-hosted Windows producer, account boundary, 120-minute cap and fixed artifact. Current ref allowlist excludes `codex/harness-v2-default-promotion`. | Release validation and runner boundary pass. | implementation-gap | Current branch cannot route the job; no real artifact. | Producer label/account, dedicated Codex Home, GitHub environment. | <=120 min after DP-02 | true | DP-02 |
| DP-G10-RELEASE-HOST | `release-host` produces both required cognitive and authoritative installed Desktop 3×3 evidence on the same revision. | Job exists but invokes only the default cognitive path and the current ref is excluded. | Release validation verifies current cognitive wiring; Host qualification exposes installed gap. | implementation-gap | Missing installed Desktop job/input and current-branch routing; no real artifacts. | Producer runner and DP-G03 implementation. | <=240 min per configured Host job | true | DP-02 |
| DP-G11-RELEASE-FULL | Credential-blind aggregator consumes all real reports, runs full compatibility plus core/full rollback, and succeeds only when every required gate is pass. | Job and generator exist with two report inputs, `!cancelled()`, `-RequireEligible`, Suite all and rollback gates; current ref is excluded and installed gate is absent. | Release validation 32 checks; core/full isolated rollback both pass locally. | implementation-gap | Missing installed Desktop input/gate, current-branch routing and real producer artifacts. | Separate aggregator account/label and DP-03 artifacts. | <=120 min after producers | true | DP-02 |
| DP-G12-ROLLOUT-REPORT | Strict `eligible=true` report binds Model40, cognitive Host, installed Desktop, Suite all, v1 compatibility and core/full rollback to one clean revision. | Generator/validator, atomic output, source digests and offline promotion entry exist; current generator gates behavior, v1 compatibility, one direct-performance Host report and two rollback smokes only. | Rollout evidence 52/52 and Release validation pass. | implementation-gap | Installed Desktop gate/input and all real reports are missing; canonical report does not exist. | DP-02 schema/wiring and DP-03 evidence. | <=120 min release-full | true | DP-02 |
| DP-G13-AUTO-DEFAULT-FLIP | New identity-free `auto` tasks select v2 only from a current valid canonical eligible report; invalid/missing evidence falls back to v1. | Artifact-first resolver, strict report discovery order, `promote-v2-rollout-report.ps1`, `enable-v2/disable-v2/reset-auto` exist. | Protocol 32/32; coexistence 17/17; rollout validation passes. | evidence-missing | No eligible report has been generated or promoted; workspace is explicit opt-in rather than Auto. | Reviewed external eligible report and authorized promotion target. | <=30 min after DP-04 inputs | true | DP-04 |
| DP-G14-V1-ROLLBACK | `HARNESS_PROTOCOL=v1`/`disable-v2` immediately stop new Auto/v2 selection without changing existing artifacts; core/full install/update/uninstall restore cleanly. | Immediate override, artifact-first coexistence, installer/uninstaller transaction and isolation logic are present. | Protocol/coexistence pass; core and full isolated smoke each report install/verify/update/reverify/uninstall/cleanup exit 0. | ready-to-run | Formal release-full still must bind fresh rollback results to the qualifying revision. | None for focused check; aggregator runner for formal gate. | Focused <=1 min each; formal within <=120 min release-full | true | DP-04 |
| DP-G15-CANARY | A bounded canary cohort uses the promoted report, observes predefined success/rollback criteria and retains immediate v1 stop-loss. | Documentation names Canary as a later milestone; no canary state, cohort, duration or success policy is implemented. | No formal Canary verifier or evidence exists. | policy-decision-required | Cohort, duration, metrics, abort threshold, owner and retained evidence are undecided. | Authorized operator and production-like Desktop cohort. | Recommended cap 7 days after policy approval | true | DP-05 |
| DP-G16-STABLE | After a complete successful external Canary cycle, an authorized Stable decision retains rollback evidence and does not imply v1 deletion. | Compatibility policy requires an external Stable cycle before retirement; no Stable marker/decision artifact exists. | No formal Stable evidence exists. | policy-decision-required | Stable acceptance/owner/rollout scope and completed Canary evidence. | Authorized release owner and DP-05 Canary result. | <=2 h decision/rollout after Canary window | true | DP-05 |
| DP-G17-V1-RETIREMENT | No v1 source deletion occurs during Default Promotion; any later retirement is separately authorized after Stable. | Policy explicitly preserves v1 and requires a later task, no active v1 tasks, retained rollback and approval. | Coexistence verifies the full v1 stage chain remains functional. | not-applicable | None for DP-01 through DP-05; retirement remains outside scope. | Separate future authorization after Stable. | not applicable | false | not-applicable |

## Focused Verification Evidence

| Command | Result |
| --- | --- |
| `tests/verify-installation.ps1 -WorkspaceRoot D:\data\dev-harness-next -RepoRoot D:\data\dev-harness -Scope All` | exit 0, STATUS PASS, no warnings/errors |
| `tests/verify-v2-protocol-config.ps1 -RepoRoot D:\data\dev-harness-next` | exit 0, 32 checks |
| `tests/verify-rollout-evidence.ps1 -RepoRoot D:\data\dev-harness-next` | exit 0, 52 checks |
| `tests/verify-release-runner-boundary.ps1 -RepoRoot D:\data\dev-harness-next` | exit 0, 10 checks |
| `tests/verify-v1-v2-coexistence.ps1 -RepoRoot D:\data\dev-harness-next` | exit 0, 17 checks |
| `tests/verify-release-validation.ps1 -RepoRoot D:\data\dev-harness-next` | exit 0, 32 checks, failures none |
| `tests/verify-host-benchmark-qualification.ps1 -RepoRoot D:\data\dev-harness-next` | exit 0, 160 checks |
| `tests/verify-model-eval-runner.ps1 -RepoRoot D:\data\dev-harness-next` | exit 0, 39 checks |
| `scripts/run-model-evals.ps1 -RepoRoot D:\data\dev-harness-next -ValidateOnly` | exit 0; definition only, no session |
| `scripts/run-host-benchmark.ps1 ... -BenchmarkPath cognitive-fast-path -Groups 3 -Trials 3 -ValidateOnly` | exit 0; definition only, no session |
| `scripts/run-host-benchmark.ps1 ... -BenchmarkPath installed-desktop-path -Groups 3 -Trials 3 -ValidateOnly` | exit 0; definition only, no session |
| `scripts/run-isolated-install-smoke.ps1 -RepoRoot D:\data\dev-harness-next -Preset core` | exit 0; install/verify/update/reverify/uninstall/cleanup all 0 |
| `scripts/run-isolated-install-smoke.ps1 -RepoRoot D:\data\dev-harness-next -Preset full` | exit 0; install/verify/update/reverify/uninstall/cleanup all 0 |

No Model40 session, real Host observation, release-full aggregation, eligible report generation, report promotion, Auto flip or Canary was executed.

## Finite Route

### DP-02 — Make formal qualification runnable

- Single objective: remove all code/contract blockers that prevent this branch from producing authoritative Default Promotion qualification evidence.
- Inputs: this Gate Matrix; installed Desktop `qualification=unavailable` evidence; current writer/template, host runner, schemas, rollout generator and workflow.
- Modification scope: a narrow installed Desktop qualification authority path; explicit installed report/gate wiring; current Default Promotion ref routing; focused schemas/tests/docs only.
- Non-goals: no generic Writer, self-maintenance security, production identity system, real Model40/3×3, Promotion, Auto flip, Canary or v1 deletion.
- Verification: Model/Host runner fixtures, Host qualification, rollout evidence, Release validation, protocol/coexistence and core/full rollback.
- Completion: installed Desktop fixture can authoritatively report pass/fail instead of forced unavailable; rollout/report/workflow require it; current branch can route all release jobs; all deterministic checks pass.
- Maximum estimated runtime: 90 minutes.
- Failure stop: stop if Desktop runtime/Hook authority cannot be proven without a general writer/security expansion, or if any source/ref/gate binding cannot fail closed.

### DP-03 — Produce real qualification evidence

- Single objective: produce clean, source-bound passing Model40, cognitive Host 3×3 and installed Desktop Host 3×3 reports.
- Inputs: clean DP-02 revision; exact Codex `0.144.4`; dedicated logged-in Codex Home; distinct producer/aggregator runner configuration.
- Modification scope: release-run configuration and external evidence artifacts only; source fixes require a return to DP-02.
- Non-goals: no rollout promotion, Auto flip, Canary, Stable or v1 deletion.
- Verification: strict report consumers, per-session/trial source digests, three independent groups, per-group latency/request-send thresholds, account/home isolation.
- Completion: all real reports pass and bind the same clean revision; no unavailable/simulated/dirty input remains.
- Maximum estimated runtime: 10 hours including one bounded rerun window.
- Failure stop: stop on version/auth/home/account/source drift, any unavailable observation, threshold failure or need to change source.

### DP-04 — Build and promote one Canary candidate

- Single objective: aggregate DP-03 evidence into one reviewed eligible report and explicitly promote it to one authorized Canary workspace so `auto` selects v2 there.
- Inputs: all DP-03 reports; passing Suite all and fresh core/full rollback; credential-blind aggregator; authorized Canary workspace.
- Modification scope: release-full evidence output and explicit offline rollout promotion only.
- Non-goals: no broad Stable rollout, no implicit artifact download, no source repair, no v1 deletion.
- Verification: `-RequireEligible`, report digest/revision checks, promotion CAS/round-trip validation, `auto -> v2`, `HARNESS_PROTOCOL=v1` immediate stop-loss.
- Completion: one canonical eligible report is installed only in the Canary workspace and all resolver/rollback probes pass.
- Maximum estimated runtime: 3 hours.
- Failure stop: stop on any non-pass gate, missing artifact, source/target drift, invalid report, promotion rollback or resolver mismatch.

### DP-05 — Canary and Stable admission decision

- Single objective: observe the bounded Canary and make an explicit Stable/no-go decision while retaining v1 rollback.
- Inputs: DP-04 Canary workspace/report; approved cohort, metrics, duration, abort thresholds and owner.
- Modification scope: Canary/Stable evidence and authorized rollout decision only.
- Non-goals: no v1 physical deletion, production auth redesign, generic Writer or unrelated architecture expansion.
- Verification: predefined success metrics, zero rollback-trigger breaches, report/revision continuity, tested v1 stop-loss and retained evidence.
- Completion: Stable is explicitly approved with complete Canary evidence, or no-go/rollback is recorded; either outcome preserves v1.
- Maximum estimated runtime: 7 days (recommended hard cap; must be approved before DP-05 starts).
- Failure stop: immediately stop and select v1 on any abort threshold, evidence gap, source drift or policy ambiguity.

## Next Batch

The only next batch is **DP-02 — Make formal qualification runnable**. Running DP-03 now would only produce `unavailable` installed Desktop evidence and the current branch would not route release jobs.

## Stop Boundary

- No source file was modified.
- No commit, push, PR, Model40, real Host 3×3, release-full, eligible rollout report, Promotion, Auto flip, Canary or v1 deletion occurred.
- DP-01 stops here and requires a separate authorization before DP-02.
