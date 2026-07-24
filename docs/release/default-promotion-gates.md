# Thin Harness v2 Default Promotion Gates

## Authority and snapshot boundary

- contract_status: canonical-current
- applies_to: DP-02 through DP-05
- audited_source_revision: `d9a095fe177c4206e97db6785464ef9ea4a12101`
- dp01_archive_commit: `fc0d078ae22dd791870bc6af7608171dd8ce60b5`
- public_opt_in_beta: frozen at `v2-public-optin-beta.1`

The four tracked files under `docs/tasks/thin-harness-v2-default-promotion/` are a pre-archive DP-01 snapshot. They remain historical Evidence and are not rewritten. This document replaces their forward-looking Gate dependencies, completion criteria, and DP-02 through DP-05 batch definitions; it does not alter their Evidence, verdict, or source binding.

This is a qualification contract, not a claim that Default Promotion has passed. Requirements below that have not produced formal source-bound evidence remain unqualified. Local fixtures, `-ValidateOnly`, isolated smoke, `not_run`, `skipped`, `unavailable`, `manual`, and advisory observations are never promoted to formal `pass`.

The currently implemented compatibility behavior remains documented in [compatibility-policy.md](compatibility-policy.md). Where that implementation is narrower than this contract, the difference is a DP-02 implementation gap rather than permission to weaken this contract.

## Dependency order

The dependency order is intentionally acyclic:

1. DP-02 makes every producer and consumer path runnable, including a distinct Installed Desktop report, all three preset lifecycle inputs, current-branch release routing, and fail-closed aggregation.
2. DP-03 produces real Model40, Cognitive Host, Installed Desktop, preset lifecycle, compatibility, source, account, and Home-isolation evidence. Installed Desktop selects v2 with workspace-owned `enable-v2` or an equivalent explicit workspace setting; it does not consume an eligible rollout report.
3. DP-04 consumes the complete DP-03 evidence set to generate and review one eligible report, promotes it to one explicitly authorized Canary workspace, and only then verifies `auto -> v2` plus v1 stop-loss.
4. DP-05 runs the bounded Canary and records a Stable or No-go decision while preserving v1.

An eligible report is therefore an output of complete qualification, never an input to the Promotion-before Installed Desktop Gate.

## Canonical Gate Matrix

`current_gap` describes the audited implementation at `audited_source_revision`; it is not a live pass/fail record. Every formal Gate must be re-bound to the exact clean candidate revision.

| gate_id | batch | required_result | accepted_inputs | forbidden_substitutes | current_gap | formal_completion_evidence | blocks_default_flip |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DP-G00-EXACT-HEAD-ENGINEERING-CI | every engineering batch | Draft PR checks out the exact Head SHA; changed-optional, all five pr-core groups, aggregate pr-core and Core rollback succeed; ordinary CI Receipt artifacts exist; an independent read-only Reviewer reports no P0/P1. | PR Head SHA, PR base SHA, ordinary CI jobs and receipts, independent review bound to the same Head. | Branch-name checkout, stale receipts, a review of an older Head, skipped/cancelled jobs, or local tests alone. | Ordinary exact-Head jobs and receipts exist; evidence must be produced again for each changed Head. | GitHub run and receipt artifact identities bound to the exact Head, plus the independent review record. | true |
| DP-G01-MODEL40 | DP-03 | One clean `harness-model-eval-report/v2` covering 20 cases times 2 paraphrases, 40 real sessions on `gpt-5.6-sol/max` and Codex `0.144.4`, with every hard gate satisfied. | Real producer output and per-session source/version telemetry. | Fixture replay, scenario eval, `-ValidateOnly`, simulated sessions, or partial reruns. | Runner and deterministic verifier exist; real source-bound report is missing. | Sanitized Model40 report bound to the candidate revision and producer identity. | true |
| DP-G02-COGNITIVE-HOST-3X3 | DP-03 | Three independent clean groups, each bare/v1/v2 times 3 real trials, independently satisfying latency and request-send thresholds. | Real cognitive Host observations, OTel send evidence, independent group/source identities. | Pooled nine trials, copied groups, fixture replay, or `-ValidateOnly`. | Runner and structural verifier exist; 27 real cognitive observations are missing. | Passing `harness-host-benchmark-report/v2` cognitive report bound to the candidate revision. | true |
| DP-G03-INSTALLED-DESKTOP-HOST-3X3 | DP-03 | Three independent Installed Desktop groups satisfy the same performance thresholds and the Installed Desktop hard-result contract below. | Isolated installed Desktop Profile, installed user/workspace configuration, workspace-owned explicit v2 selection, real Direct tasks, and authoritative Lifecycle/Profile/Protocol observations. | Eligible report, `auto -> v2`, process-only `HARNESS_PROTOCOL`, generic Writer, Hook-trust assertion, CLI-host-equivalent fixture, or `-ValidateOnly`. | Installed path can install and inspect a profile but currently reports qualification unavailable because the authoritative Desktop observation surface is incomplete. | Distinct installed Desktop v2 report with 27 real observations and the hard-result fields below, bound to the candidate revision. | true |
| DP-G04-CODEX-HOME-RUNNER-ISOLATION | DP-03 | Producers use one dedicated logged-in Codex Home and a clean source; producer and credential-blind aggregator accounts/labels are distinct. | Runner account digests, labels, run identity, Home path boundary, clean revision. | Shared account/cache, default personal Home, credential payload in artifacts, or label difference without runtime account proof. | Boundary checks exist; release environment evidence is missing. | Source/account/Home isolation records for the exact release run. | true |
| DP-G05-V2-BARE-1.25 | DP-03 | Every Cognitive and Installed Desktop group independently satisfies `median(v2/bare) <= 1.25`. | Complete source-bound bare/v2 trials for each group. | Pooled medians, copied measurements, missing trials, or fixtures. | Recalculation exists; real measurements are missing. | Per-group recomputation in both formal Host reports. | true |
| DP-G06-REQUEST-SEND-REDUCTION | DP-03 | Every Cognitive and Installed Desktop group independently proves successful request-send reduction of at least 0.60 from v1 to v2. | Codex `0.144.4` OTel successful-send observations for each complete group. | Estimated counts, unavailable telemetry, pooled groups, or non-successful sends. | Collector and validation semantics exist; real measurements are missing. | Per-group source-bound OTel calculation in both formal Host reports. | true |
| DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE | DP-02/DP-03 | Rollout eligibility consumes a distinct Installed Desktop Gate, separate from Cognitive Host performance, bound to the same revision and evidence set. | The DP-G03 report and authoritative observation record. | One generic Host input standing in for both paths or an eligible report fed back into Installed Desktop qualification. | Generator/schema/workflow currently accept only one generic Host input. | Fail-closed rollout gate and workflow input with positive and negative deterministic coverage. | true |
| DP-G09-RELEASE-MODEL | DP-02/DP-03 | `release-model` routes the current Default Promotion branch and publishes exactly one sanitized Model40 artifact. | Allowed exact candidate ref, dedicated producer, Model40 runner. | Pull-request ordinary CI or an artifact from another revision. | Job exists; current Default Promotion branch is not allowlisted. | Exact-ref producer run and artifact. | true |
| DP-G10-RELEASE-HOST | DP-02/DP-03 | Release routing produces separate Cognitive and Installed Desktop 3x3 artifacts for the same candidate revision. | Dedicated producer, two explicit benchmark paths and fixed artifacts. | Cognitive-only output, generic Host alias, or different revisions. | Current job invokes only the Cognitive default path and excludes the current branch. | Two fixed sanitized Host artifacts with exact source binding. | true |
| DP-G11-RELEASE-FULL | DP-02/DP-04 | Credential-blind aggregation consumes Model, Cognitive Host, Installed Desktop, compatibility, and core/governed/full lifecycle evidence and fails closed unless every required Gate qualifies. | Fixed artifacts from the same clean revision and distinct producer/aggregator identities. | Missing input treated as success, core/full standing in for governed, or producer reruns on the aggregator. | Current aggregation has two report inputs, no distinct Installed Desktop input, and no governed lifecycle Gate; current branch is excluded. | `-RequireEligible` aggregate run with all required input digests. | true |
| DP-G12-ROLLOUT-ELIGIBILITY-REPORT | DP-04 | One reviewed `eligible=true` report binds all qualification Gates to one exact clean revision. | Passing G00-G07, G09-G11, G14, and G18-G20 evidence from the candidate revision. | Stale/dirty/tampered/simulated/unavailable evidence or a report generated before all inputs exist. | Generator currently covers Model, one Host, compatibility, core and full only. | Strict canonical report plus review and source digests. | true |
| DP-G13-PROMOTION-AUTO-PROBE | DP-04 | Promote the reviewed eligible report to one authorized Canary workspace; verify `auto -> v2`, `HARNESS_PROTOCOL=v1`, and `disable-v2` stop-loss. | A complete G12 report, explicit Canary workspace authorization, promotion CAS and resolver probes. | Workspace `enable-v2` presented as Auto evidence, or Auto probing during DP-03. | Promotion/resolver primitives exist; no eligible report has been produced or promoted. | Promotion receipt, canonical discovery result, Auto probe and both v1 stop-loss probes. | true |
| DP-G14-V1-STOP-LOSS | DP-03/DP-04 | v1 remains immediately selectable without altering existing artifacts; compatibility and rollback remain intact. | `HARNESS_PROTOCOL=v1`, `disable-v2`, v1 compatibility and lifecycle evidence. | Deleting v1, migrating existing tasks, or assuming rollback from source presence alone. | Mechanisms and deterministic checks exist; the candidate release needs fresh bound evidence. | Exact-revision compatibility and stop-loss records. | true |
| DP-G15-CANARY | DP-05 | An authorized, bounded cohort runs with an Owner, duration, metrics and Abort Threshold; any breach selects v1. | Promoted Canary report/workspace and approved policy. | Unbounded rollout, advisory-only observation, or silent continuation after an abort condition. | Policy inputs and real Canary evidence are not yet available. | Canary observation record with owner, window, metrics, aborts and outcome. | true |
| DP-G16-STABLE-DECISION | DP-05 | Record an explicit Stable or No-go decision after the complete Canary while retaining v1 rollback. | Complete G15 evidence and authorized release owner decision. | Calendar passage, partial cohort, or implied approval. | Stable evidence and decision are not yet available. | Signed/authorized decision bound to Canary and release revision. | true |
| DP-G17-V1-RETIREMENT | later task | No v1 physical deletion occurs in DP-01A through DP-05; retirement requires separate authorization after Stable. | Separate future contract, no active v1 tasks, retained rollback evidence. | Default Promotion, Canary, or Stable alone. | Not applicable to this route. | Separate future task and approval. | false |
| DP-G18-CORE-LIFECYCLE | DP-03 | A real isolated core lifecycle performs install, verify, update, verify, uninstall and cleanup in order. | Exact candidate revision, isolated workspace/profile, complete stage results. | Unit fixtures, partial stages, or another preset. | Runner supports core; formal candidate evidence is missing. | Separate source-bound core lifecycle record. | true |
| DP-G19-GOVERNED-LIFECYCLE | DP-03 | A real isolated governed lifecycle performs install, verify, update, verify, uninstall and cleanup in order. | Exact candidate revision, isolated workspace/profile, complete stage results. | Full standing in for governed, partial stages, or local fixture claims. | Runner supports governed; rollout aggregation has no distinct governed Gate and formal evidence is missing. | Separate source-bound governed lifecycle record. | true |
| DP-G20-FULL-LIFECYCLE | DP-03 | A real isolated full lifecycle performs install, verify, update, verify, uninstall and cleanup in order. | Exact candidate revision, isolated workspace/profile, complete stage results. | Governed/core standing in for full or partial stages. | Runner supports full; formal candidate evidence is missing. | Separate source-bound full lifecycle record. | true |

`DP-G08-DESKTOP-WRITER-AUTHORITY` is retired as an independent Gate. Its legitimate result requirement is merged into the `INSTALLED-DESKTOP-AUTHORITATIVE-OBSERVATION` contract below. A test-only mechanism may satisfy that contract, but a generic Writer is neither a product outcome nor a prerequisite for Default Promotion.

## Installed Desktop hard-result contract

`INSTALLED-DESKTOP-AUTHORITATIVE-OBSERVATION` is satisfied only when the formal Installed Desktop report demonstrates all of the following on the real installed Desktop path:

1. An isolated Installed Desktop Profile installs successfully.
2. The host actually loads the installed user and workspace configuration rather than a fixture-only substitute.
3. The tested process has no `HARNESS_PROTOCOL` dependency.
4. Workspace `enable-v2`, or an equivalent explicit workspace-owned v2 setting, selects v2.
5. A real Direct task completes on the installed Desktop path.
6. Lifecycle, execution profile, and selected protocol observations agree.
7. The Direct task causes zero unexpected task, runtime, or current-pointer writes.
8. Only the declared allowed target changes.
9. Auth bytes and pre-existing user configuration remain unchanged.
10. Uninstall and cleanup succeed without residue in the isolated Profile/workspace.
11. The report and every observation bind to the same exact clean source revision.

The hard-result contract does not require `auto -> v2`, a promoted eligible report, authoritative Hook trust/callability, a generic Writer, Harness self-maintenance, a production identity system, or a Desktop production execution platform.

A minimal test-only observation mechanism is allowed when it exposes the real installed Desktop execution result and fails closed. If the current host has no authoritative API for Hook trust/callability, record that item as `manual`/advisory in DP-05 Canary; do not convert it to machine `pass`, and do not block DP-02/DP-03 machine qualification on an API the host does not expose. Critical production execution continues through an independent controlled executor.

## Preset lifecycle evidence

Core, governed, and full are three independent Gates. Each formal lifecycle record must:

- use the exact clean candidate revision and an isolated workspace/profile;
- execute `install -> verify -> update -> verify -> uninstall -> cleanup` in that order;
- record each stage exit and preserve cleanup evidence after failure;
- prove Auth and unrelated user configuration are unchanged;
- bind the effective preset and source revision; and
- remain a separate rollout input so `full` can never stand in for `governed`.

Local `scripts/run-isolated-install-smoke.ps1 -Preset core|governed|full` runs are deterministic preflight evidence only. DP-03/release aggregation must produce fresh source-bound qualification evidence for all three.

## Exact-Head ordinary CI and review

Every engineering Head proposed for the Default Promotion branch must satisfy G00 after its final change:

- Draft PR source is `codex/harness-v2-default-promotion` and target is `codex/harness-v2-public-optin-beta`.
- Checkout is the exact `github.event.pull_request.head.sha` with persisted credentials disabled.
- `changed-optional` succeeds.
- The five pr-core groups `entry-lifecycle`, `evaluation-release`, `install-evidence`, `governance-approval`, and `harness-contracts` all succeed.
- Aggregate `pr-core` fails closed unless every group succeeds, then completes Core rollback.
- Each group, changed-optional, and aggregate pr-core publishes its ordinary CI Receipt artifact for the same Head.
- A read-only independent Reviewer of that Head reports no P0/P1; an older review is stale after any commit.

Cancelled, skipped, neutral, pending, unavailable, or missing checks and receipts are not pass. Pushing another commit invalidates the prior G00 evidence and requires a new exact-Head run and review.

## Finite route

### DP-02 — Make qualification runnable

- Single objective: remove only the implementation/contract blockers that prevent the current branch from producing every formal qualification input.
- Inputs: this contract, current Installed Desktop unavailable evidence, current Host/rollout schemas and consumers, release workflow, and lifecycle runner.
- Modification scope: distinct Installed Desktop report/qualification contract; Promotion-before workspace-v2 Desktop path; distinct rollout Installed Desktop Gate; current-branch release routing; core/governed/full lifecycle aggregation; directly corresponding focused tests and docs.
- Non-goals: real Model40/3x3, Promotion, Auto Flip, Canary, generic Writer, self-maintenance, security platform, production identity system, Desktop production execution platform, or v1 deletion.
- Verification: positive/negative runner fixtures, Installed Desktop authority fail-closed checks, rollout evidence, release routing, protocol/coexistence, and all three lifecycle smokes.
- Completion: every required producer/input/gate is independently runnable and fail-closed on the current branch; no eligible report is required to run Installed Desktop qualification.
- Maximum estimated runtime: 90 minutes.
- Failure stop: stop and report a policy/environment blocker if authoritative machine observation would require a generic Writer, security platform, production identity system, or an authoritative host API that does not exist.

### DP-03 — Produce real qualification evidence

- Single objective: produce real passing Model40, Cognitive Host 3x3, Installed Desktop Host 3x3, core/governed/full lifecycle, compatibility, and isolation evidence for one exact clean revision.
- Inputs: a clean DP-02 revision, exact Codex `0.144.4`, dedicated logged-in Home, isolated Desktop Profile, and distinct producer/aggregator configuration.
- Modification scope: release-run configuration and external evidence artifacts only; any source fix returns to DP-02.
- Non-goals: eligible-report Promotion, Auto Flip, Canary, Stable, generic Writer, or v1 deletion.
- Verification: strict report consumers, three independent groups per Host path, per-group latency/send thresholds, source/account/Home isolation, and three distinct preset lifecycle records.
- Completion: all formal inputs qualify against one exact clean revision with no simulated, unavailable, manual-as-pass, dirty, or stale data.
- Maximum estimated runtime: 10 hours, including one bounded rerun window.
- Failure stop: stop on version/auth/Home/account/source drift, unavailable machine observation, threshold failure, lifecycle failure, or any need to change source.

### DP-04 — Build and promote one Canary candidate

- Single objective: aggregate complete DP-03 evidence into one reviewed eligible report, promote it to one authorized Canary workspace, and verify Auto plus v1 stop-loss.
- Inputs: all DP-03 reports, exact-Head G00 evidence, credential-blind aggregation, and explicit Canary workspace authorization.
- Modification scope: release-full aggregate output, report review, explicit offline Promotion, Auto probe, and stop-loss probes.
- Non-goals: broad Stable rollout, source repair, real evidence rerun on the aggregator, generic Writer, or v1 deletion.
- Verification: `-RequireEligible`, all gate/revision digests, Promotion CAS/round-trip, `auto -> v2`, `HARNESS_PROTOCOL=v1`, and `disable-v2`.
- Completion: one canonical eligible report exists only in the authorized Canary workspace and every resolver/rollback probe matches the same revision.
- Maximum estimated runtime: 3 hours.
- Failure stop: stop on any non-qualifying Gate, missing artifact/receipt, source or target drift, invalid report, Promotion rollback, or resolver mismatch.

### DP-05 — Canary and Stable decision

- Single objective: run a bounded Canary and record an explicit Stable or No-go decision while retaining immediate v1 rollback.
- Inputs: DP-04 Canary workspace/report and approved cohort, Owner, metrics, duration, Abort Thresholds, plus Hook trust/callability advisory where authoritative automation is unavailable.
- Modification scope: Canary observations, advisory/manual host checks, rollback records, and authorized Stable/No-go decision only.
- Non-goals: v1 physical deletion, production auth redesign, generic Writer, self-maintenance, security platform, or unrelated architecture work.
- Verification: predefined metrics, abort handling, report/revision continuity, v1 stop-loss, advisory truthfulness, and retained evidence.
- Completion: Stable is explicitly approved with complete Canary evidence, or No-go/rollback is recorded; both outcomes preserve v1.
- Maximum estimated runtime: 7 days as a hard recommended cap, approved before DP-05 starts.
- Failure stop: immediately select v1 and stop on any Abort Threshold, evidence gap, source drift, owner ambiguity, or policy ambiguity.

## DP-01A stop boundary

DP-01A only publishes this corrected contract and its maintenance links. It does not implement DP-02, run real Model40 or Host 3x3, run release-full, generate/promote an eligible report, flip Auto, start Canary, mark Stable, or delete v1.
