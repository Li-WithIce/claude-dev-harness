# Thin Harness v2 Default Promotion Gates

TK-03 amendment: this document retains the original Release route. Its v1
rollback/Stable-before-retirement prerequisite is superseded for the current
Runtime by [the user-confirmed v2-only contract](../architecture/tk03-v2-only-transition.md).
Ten current Sunset gates plus separate exact-removal-diff approval now govern
physical v1 source retirement. No historical Gate status is promoted or rerun.

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
3. DP-04 consumes the complete DP-03 evidence set to generate and review one machine-distinct `rollout-eligibility/v2` Canary-candidate report. It lists every blocking Gate, keeps the post-Promotion Gates non-passing and `eligible=false`, and can be promoted only to one explicitly authorized Canary workspace; only that Canary scope then verifies `auto -> v2` plus v1 stop-loss.
4. DP-05 runs the bounded Canary and records a Stable or No-go decision while preserving v1. Only after G13, G15, and G16 pass may aggregation issue and review the final `rollout-eligibility/v2` report with `eligible=true` for Default Promotion.

A Default-eligible report is therefore an output of the complete qualification route, never an input to the Promotion-before Installed Desktop Gate or the Canary observations it records. The earlier Canary-candidate report is not Default eligibility and cannot authorize ordinary zero-configuration `auto -> v2` outside its explicit Canary target.

## Rollout eligibility schema migration

DP-02 must add `rollout-eligibility/v2` as a new schema. Its formal Gate set must cover every row in the Canonical Gate Matrix whose `blocks_default_flip` value is `true`; a partial subset cannot authorize Default Promotion. Coverage means every blocking Gate has an explicit state and evidence identity, not that a pre-Canary report may mark unrun Gates as passing. The schema must distinguish a Canary-candidate report from a final Default report in a machine-enforced way:

- the DP-04 Canary candidate records G13, G15, and G16 as non-passing, remains `eligible=false`, and is usable only with separate explicit Canary authorization; and
- only a post-DP-05 final report in which every blocking Gate passes may set `eligible=true` and authorize Default Promotion.

The G12 row is satisfied by the v2 report envelope, strict schema/source validation, and independent review; the report does not recursively embed its own digest as an input Gate. DP-02 must not extend `rollout-eligibility/v1` in place or change the meaning of any existing v1 field.

The DP-02A core path now treats a `rollout-eligibility/v1` report as historical diagnostic evidence only. A consumer may parse it and display its historical reasons, but it must not:

- authorize Default Promotion;
- authorize publication of a Runtime Default Decision; or
- be accepted by Promotion as a new Canonical default basis.

Qualification and Promotion no longer accept the old five-Gate `rollout-eligibility/v1` report as authorization. Default Promotion nevertheless remains prohibited: DP-02A implements the v2 qualification contract, DP-02B adds the Installed Desktop producer contract plus strict G03/G07 portable Adapter, and bounded DP-02C batches now include G00, G04, G09-G11, G14 and G18-G20 contracts/Adapters. The current branch can manually dispatch `release-model`, `release-host`, and credential-blind `release-full`; G11 emits only its strict eight-input Receipt and does not create a Candidate or final rollout report. All real release inputs and the formal G11 run remain `not_run`. Missing, old-version, unknown-schema, stale, dirty, tampered, failed, blocked, simulated or unavailable rollout evidence prevents publication of a Runtime Default Decision; it does not disable explicit Runtime use.

### DP-02A machine boundary

`rollout-eligibility/v2` has exactly two phases:

- `canary-candidate` requires G00-G07, G09-G11, G14 and G18-G20 to be `pass`; G13, G15 and G16 must be `not_run`; `eligible` is exactly `false`.
- `final-default` requires every blocking Gate to be `pass`; `eligible` is exactly `true`.

Both reports contain all 19 blocking Gate identifiers. The normalized `rollout-evidence-set/v1` Generator input contains the other 18 Gate records; G12 is added only after a matching phase/source-bound `rollout-report-review-receipt/v1` is validated. This prevents a caller from supplying a recursive or self-asserted G12 input. Every non-G12 Gate record has exactly `status`, `evidence_contract`, `artifact_path`, `evidence_digest`, `source_revision`, and `producer_identity`; G12 uses the same shape with the Review Receipt Artifact path, strict Receipt digest, and reviewer identity. Every source revision must equal the clean report revision.

The fixed Gate-to-contract bindings are:

| Gate | evidence_contract |
| --- | --- |
| G00 | `thin-harness-exact-head-engineering-evidence/v1` |
| G01 | `harness-model-eval-report/v2` |
| G02, G05, G06 | `harness-host-benchmark-report/v2` |
| G03, G07 | `harness-installed-desktop-benchmark-report/v1` |
| G04 | `harness-release-isolation-report/v1` |
| G09 | `harness-release-model-receipt/v1` |
| G10 | `harness-release-host-receipt/v1` |
| G11 | `harness-release-full-receipt/v1` |
| G12 | `rollout-report-review-receipt/v1` |
| G13 | `harness-canary-promotion-receipt/v1` |
| G14 | `harness-v1-stop-loss-report/v1` |
| G15 | `harness-canary-observation-report/v1` |
| G16 | `harness-stable-decision/v1` |
| G18, G19, G20 | `harness-preset-lifecycle-report/v1` |

These identifiers are strict aggregation entry points, not claims that their real Producers have passed. G03/G07 use the bounded strict Installed Desktop Adapter; G09/G10 use strict Release Producer Receipt contracts, one validating Writer, and Portable Adapters that cross-bind their underlying G01-G07 Artifacts and G04 runner summaries. G11 uses a strict `harness-release-full-receipt/v1` Writer/Adapter that reopens G00, G04, G09, G10, G14, and the three Lifecycle reports, binds all eight raw/document digests to one Source, and requires the same G04/G09/G10/G11 Release Workflow run and attempt. The current branch has manual-only Model/Host/Full orchestration, but no real Model40, Host 3x3, G09, G10, or G11 release evidence has been produced. Every non-G12 Gate reference carries its contract, Artifact path, raw file digest, source revision, and producer/receipt identity. The Generator reopens the Artifact and delegates to that contract's strict Adapter; caller status/identity, a hand-written or fixture result, and an arbitrary digest never establish qualification.

The report Host binding is exact, but it cannot self-attest the running Host. Promotion requires `rollout-observed-host-context/v1` from the trusted caller, binding `product=codex-cli-service`, CLI/service `0.144.4`, `codex-0.144.4-environment-shell-hook/v1`, `codex-invocation-telemetry/v2`, `codex-0.144.4-successful-websocket-send/v2`, UTC observation time, and its digest. Missing Context, version/Contract drift, a future timestamp, or a bad digest prevents Decision publication. No `codex --version` guess, documentation claim, or Report field substitutes for actual Context.

A Candidate never authorizes ordinary Auto by itself. `promote-v2-rollout-report.ps1 -AuthorizeCanary` additionally requires explicit `-AuthorizedBy` and either `-ExpiresAtUtc` or bounded `-DurationHours`. `rollout-canary-authorization/v1` binds a nonblank authorization ID/owner, Candidate schema/phase/digest/revision, physical Workspace identity digest, Observed Host Context digest, UTC `issued_at_utc`/`expires_at_utc`, `new_tasks_only=true`, and `status=granted`; future issue, expiry, or a lifetime over seven days blocks publication. Successful Candidate Promotion publishes a separate `harness-runtime-default/v1` workspace-canary decision with the same workspace identity and expiry. This is a cooperative audit record, not cryptographic identity authentication.

Candidate, Authorization, Final, and Runtime Default use distinct Canonical paths: `.assistant/runtime/rollout/v2-canary-candidate.json`, `.assistant/runtime/rollout/v2-canary-authorization.json`, `.assistant/runtime/rollout/v2-eligibility.json`, and `.assistant/runtime/protocol-default.json`. Candidate publication never changes Final and is rejected when Final already exists. Final publication writes Final plus the release-default decision and removes Candidate/Authorization inside the same physical-Workspace mutex, per-file CAS, hardlink/ADS/reparse guards, exact-byte checks, and a four-preimage rollback. Ordinary Resolver reads only Runtime Default; the other three files remain Qualification evidence.

G12 uses a non-recursive two-step Review Binding. The Generator first emits a non-authorizing `rollout-review-payload/v1` containing phase, source, Host, and all non-G12 Gates. A separate read-only reviewer emits `rollout-report-review-receipt/v1` bound to that payload digest, source revision, phase, nonblank reviewer identity/model, `read_only=true`, `verdict=pass`, zero P0/P1/P2, UTC time, and receipt digest. Finalization validates the real Receipt Artifact; G12 binds that Receipt digest. Candidate and Final require separate Receipts. Without verified Gate provenance and a matching Receipt, output remains diagnostic/test-only and Promotion rejects it; ordinary Resolver never reads it.

## Host version qualification

The current Default Promotion candidate qualifies only for Codex CLI/service `0.144.4`. Formal Model, Cognitive Host, Installed Desktop, and Rollout reports must record and bind the exact observed Host version and the corresponding versioned Hook/telemetry contract identifiers used by their evidence.

A Canary or Stable qualification environment that observes any Host version drift immediately invalidates the current reports and blocks publishing a new release decision. Adjacent-version qualification is never inferred, no version range is implied, and successful process startup is not compatibility evidence. If the Host cannot authoritatively report its runtime version, Default Promotion remains blocked; a documentation claim cannot replace machine evidence. This release conclusion does not make ordinary Harness use unavailable on the newer or unknown Host: explicit/workspace v2 and existing artifacts remain version-independent.

## Canonical Gate Matrix

`current_gap` describes the audited implementation at `audited_source_revision`; it is not a live pass/fail record. Every formal Gate must be re-bound to the exact clean candidate revision.

| gate_id | batch | required_result | accepted_inputs | forbidden_substitutes | current_gap | formal_completion_evidence | blocks_default_flip |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DP-G00-EXACT-HEAD-ENGINEERING-CI | every engineering batch | Draft PR checks out the exact Head SHA; changed-optional, all five pr-core groups, aggregate pr-core and Core rollback succeed; ordinary CI Receipt artifacts exist; separately, an independent read-only Reviewer reports no P0/P1 or evidenced P2. | PR Head SHA, PR base SHA, ordinary CI jobs and receipts, plus an externally published independent review bound to the same Head and reviewed diff digest. | Branch-name checkout, stale receipts, a review of an older Head, a PR Body assertion, skipped/cancelled jobs, or local tests alone. | Ordinary exact-Head jobs and receipts exist; both CI and independent Review evidence must be produced again for each changed Head. | GitHub run and receipt artifact identities bound to the exact Head, plus the external independent Review Receipt. | true |
| DP-G01-MODEL40 | DP-03 | One clean `harness-model-eval-report/v2` covering 20 cases times 2 paraphrases, 40 real sessions on `gpt-5.6-sol/max` and Codex `0.144.4`, with every hard gate satisfied. | Real producer output and per-session source/version telemetry. | Fixture replay, scenario eval, `-ValidateOnly`, simulated sessions, or partial reruns. | Strict Portable Adapter and manual-only current-branch Producer route are wired; real Model40 evidence has not been run and no formal Gate pass exists. | Sanitized Model40 report bound to the candidate revision and producer identity. | true |
| DP-G02-COGNITIVE-HOST-3X3 | DP-03 | Three independent clean groups, each bare/v1/v2 times 3 real trials, independently satisfying latency and request-send thresholds. | Real cognitive Host observations, OTel send evidence, independent group/source identities. | Pooled nine trials, copied groups, fixture replay, or `-ValidateOnly`. | Strict Portable Adapter and manual-only current-branch Producer route are wired; real Cognitive Host evidence has not been run and no formal Gate pass exists. | Passing `harness-host-benchmark-report/v2` cognitive report bound to the candidate revision. | true |
| DP-G03-INSTALLED-DESKTOP-HOST-3X3 | DP-03 | Three independent Installed Desktop groups satisfy the same performance thresholds and the Installed Desktop hard-result contract below. | Isolated installed Desktop Profile, installed user/workspace configuration, workspace-owned explicit v2 selection, real Direct tasks, and authoritative Lifecycle/Profile/Protocol observations. | Eligible report, `auto -> v2`, process-only `HARNESS_PROTOCOL`, generic Writer, Hook-trust assertion, CLI-host-equivalent fixture, or `-ValidateOnly`. | The formal producer and strict portable Adapter are runnable; 27 real Installed Desktop observations for the candidate revision have not been run. | Distinct `harness-installed-desktop-benchmark-report/v1` with 27 real observations and the hard-result fields below, bound to the candidate revision. | true |
| DP-G04-CODEX-HOME-RUNNER-ISOLATION | DP-03 | Producers use one dedicated logged-in Codex Home and a clean source; producer and credential-blind aggregator accounts/labels are distinct. | Runner account digests, labels, run identity, Home path boundary, clean revision. | Shared account/cache, default personal Home, credential payload in artifacts, or label difference without runtime account proof. | Strict source-bound Observation/Report producers, Portable Adapter, and Model/Host workflow calls are complete; formal Release Isolation remains `not_run`. | Source/account/Home isolation records for the exact release run. | true |
| DP-G05-V2-BARE-1.25 | DP-03 | Every Cognitive and Installed Desktop group independently satisfies `median(v2/bare) <= 1.25`. | Complete source-bound bare/v2 trials for each group. | Pooled medians, copied measurements, missing trials, or fixtures. | Strict Portable Adapter and manual-only Host Producer route are wired; real Cognitive or Installed Desktop Host evidence has not been run and no formal Gate pass exists. | Per-group recomputation in both formal Host reports. | true |
| DP-G06-REQUEST-SEND-REDUCTION | DP-03 | Every Cognitive and Installed Desktop group independently proves successful request-send reduction of at least 0.60 from v1 to v2. | Codex `0.144.4` OTel successful-send observations for each complete group. | Estimated counts, unavailable telemetry, pooled groups, or non-successful sends. | Strict Portable Adapter and manual-only Host Producer route are wired; real Cognitive or Installed Desktop Host evidence has not been run and no formal Gate pass exists. | Per-group source-bound OTel calculation in both formal Host reports. | true |
| DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE | DP-02/DP-03 | `rollout-eligibility/v2` consumes a distinct Installed Desktop Gate, separate from Cognitive Host performance, bound to the same revision and evidence set. | A second independent formal Installed Desktop report, distinct from G03 and bound to the same clean revision. | One generic Host input standing in for both paths, a v1 rollout report, an identical/copy Artifact, or an eligible report fed back into Installed Desktop qualification. | The Generator and Adapter require distinct G03/G07 physical Artifacts, and the manual Host Producer route creates two independent report paths; real evidence remains `not_run`. | Two independently produced strict Installed Desktop reports plus fail-closed release routing. | true |
| DP-G09-RELEASE-MODEL | DP-02/DP-03 | `release-model` routes the current Default Promotion branch and publishes exactly one sanitized Model40 artifact. | Allowed exact candidate ref, dedicated producer, Model40 runner. | Pull-request ordinary CI or an artifact from another revision. | Strict Model Receipt Schema/Writer/Adapter and the current branch's manual-only three-file Producer bundle are wired; the formal Job remains `not_run`. | Exact-ref producer run, Model artifact, Runner Observation, G04 report, and `harness-release-model-receipt/v1`. | true |
| DP-G10-RELEASE-HOST | DP-02/DP-03 | Release routing produces separate Cognitive and Installed Desktop 3x3 artifacts for the same candidate revision. | Dedicated producer, two explicit benchmark paths and fixed artifacts. | Cognitive-only output, generic Host alias, or different revisions. | Strict Host Receipt Schema/Writer/Adapter and the current branch's manual-only nine-file Producer bundle are wired; the formal Job remains `not_run`. | Exact-ref producer run, one Cognitive plus two distinct Installed Desktop artifacts, Runner Observation, G04 report, and `harness-release-host-receipt/v1`. | true |
| DP-G11-RELEASE-FULL | DP-02/DP-04/DP-05 | Credential-blind aggregation consumes Model, Cognitive Host, Installed Desktop, compatibility, and core/governed/full lifecycle evidence and fails closed unless every required input for the requested v2 report phase qualifies. | Fixed artifacts from the same clean revision and distinct producer/aggregator identities; post-Promotion evidence is additionally required for the final Default report. | Missing input treated as success, core/full standing in for governed, a v1 rollout report, an `eligible=true` Canary candidate, or producer reruns on the aggregator. | Strict eight-input G11 Receipt, Writer, Portable Adapter, and manual-only current-branch credential-blind aggregation are wired; the formal run and all real inputs remain `not_run`, and DP-04/DP-05 report phases remain later work. | A formal source-bound `harness-release-full-receipt/v1`; later phases separately produce their reviewed phase-correct `rollout-eligibility/v2` reports. | true |
| DP-G12-ROLLOUT-ELIGIBILITY-REPORT | DP-04/DP-05 | `rollout-eligibility/v2` enumerates every blocking Gate. The DP-04 Canary candidate is reviewed with G13/G15/G16 non-passing and `eligible=false`; only the separately reviewed post-DP-05 report with every blocking Gate passing may set `eligible=true`. | Candidate: verified G00-G07, G09-G11, G14, and G18-G20 Artifact provenance plus explicit states for G13/G15/G16 and a phase-bound Review Receipt. Final: the same exact-revision set plus verified passing G13/G15/G16 and a distinct Final Review Receipt. | Any `rollout-eligibility/v1` report; a partial or self-attested Gate set; a candidate marked Default-eligible; Schema digest as G12; a reused Candidate/Final Receipt; stale, dirty, tampered, failed, blocked, simulated, test-only, unavailable, or unwired evidence. | Review Payload/Receipt and fail-closed provenance boundaries exist, and G11 code aggregation is wired; formal DP-03 evidence plus DP-04/DP-05 phase execution are absent, so no current authorizing report can be generated. | Strict phase-correct v2 report plus its matching independent Review Receipt and validated raw Artifact provenance. | true |
| DP-G13-PROMOTION-AUTO-PROBE | DP-04 | Promote the reviewed non-Default-eligible v2 Canary candidate to one authorized Canary workspace; atomically publish a workspace-canary Runtime Default Decision; verify scoped `auto -> v2`, `HARNESS_PROTOCOL=v1`, and `disable-v2` stop-loss. | A complete phase-correct `rollout-eligibility/v2` Canary candidate with `eligible=false`, separate explicit Canary workspace authorization, distilled `harness-runtime-default/v1`, Promotion CAS, and resolver probes. | A v1 rollout report, a report claiming final Default eligibility before Canary, workspace `enable-v2` presented as Auto evidence, or Auto probing during DP-03. | Promotion/decision primitives exist, but no canonical v2 Candidate has been produced or promoted. | Promotion receipt, canonical Runtime Decision result, scoped Auto probe, and both v1 stop-loss probes. | true |
| DP-G14-V1-STOP-LOSS | DP-03/DP-04 | v1 remains immediately selectable without altering existing artifacts; compatibility and rollback remain intact. | `HARNESS_PROTOCOL=v1`, `disable-v2`, v1 compatibility and lifecycle evidence. | Deleting v1, migrating existing tasks, or assuming rollback from source presence alone. | Strict source-bound producer, report Schema, portable Adapter, and Host Producer workflow call exist; nullable digest fields are Schema-hardened to `sha256` or `null`; diagnostic smoke remains unavailable by contract, while formal candidate evidence remains `not_run`. | Exact-revision `harness-v1-stop-loss-report/v1` produced in formal mode. | true |
| DP-G15-CANARY | DP-05 | An authorized, bounded cohort runs with an Owner, duration, metrics and Abort Threshold; any breach selects v1. | Promoted Canary report/workspace and approved policy. | Unbounded rollout, advisory-only observation, or silent continuation after an abort condition. | Policy inputs and real Canary evidence are not yet available. | Canary observation record with owner, window, metrics, aborts and outcome. | true |
| DP-G16-STABLE-DECISION | DP-05 | Record an explicit Stable or No-go decision after the complete Canary while retaining v1 rollback. | Complete G15 evidence and authorized release owner decision. | Calendar passage, partial cohort, or implied approval. | Stable evidence and decision are not yet available. | Signed/authorized decision bound to Canary and release revision. | true |
| DP-G17-V1-RETIREMENT | later task | No v1 physical deletion occurs in DP-01A through DP-05; retirement requires separate authorization after Stable. | Separate future contract, no active v1 tasks, retained rollback evidence. | Default Promotion, Canary, or Stable alone. | Not applicable to this route. | Separate future task and approval. | false |
| DP-G18-CORE-LIFECYCLE | DP-03 | A real isolated core lifecycle performs install, verify, update, verify, uninstall and cleanup in order. | Exact candidate revision, isolated workspace/profile, complete stage results. | Unit fixtures, partial stages, or another preset. | Strict producer, report Schema, and portable Adapter exist; diagnostic smoke is unavailable by contract, while release routing and formal candidate evidence remain pending. | Separate source-bound core lifecycle record. | true |
| DP-G19-GOVERNED-LIFECYCLE | DP-03 | A real isolated governed lifecycle performs install, verify, update, verify, uninstall and cleanup in order. | Exact candidate revision, isolated workspace/profile, complete stage results. | Full standing in for governed, partial stages, or local fixture claims. | Strict producer, report Schema, and distinct portable Adapter exist; diagnostic smoke is unavailable by contract, while release aggregation and formal candidate evidence remain pending. | Separate source-bound governed lifecycle record. | true |
| DP-G20-FULL-LIFECYCLE | DP-03 | A real isolated full lifecycle performs install, verify, update, verify, uninstall and cleanup in order. | Exact candidate revision, isolated workspace/profile, complete stage results. | Governed/core standing in for full or partial stages. | Strict producer, report Schema, and portable Adapter exist; diagnostic smoke is unavailable by contract, while release routing and formal candidate evidence remain pending. | Separate source-bound full lifecycle record. | true |

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

### Performance timing and cache boundary

Installed Desktop qualification uses the following non-negotiable measurement boundary:

1. Core, governed, and full install, update, and uninstall durations are measured by their independent lifecycle Gates and are not included in Direct latency.
2. Direct latency starts when the Host submits the task and ends only after the Agent completes the real modification, focused verification, and final completion report.
3. Bare, v1, and v2 use the same Host, model, reasoning level, Profile, cache policy, task semantics, timing boundary, and resource conditions.
4. Every Trial uses a fresh Workspace and a fresh session; no protocol may reuse a prior protocol's session.
5. v2 cannot receive exclusive warm-up. Any warm-up is symmetric across all three protocols and excluded from timed samples.
6. A dedicated Auth/Host Cache may be shared, but the report records the actual cache state and rotates protocol order to reduce order bias. Such groups must not be described as fully independent cold-start experiments.
7. Installed Desktop must load the installed user and Workspace configuration. Profile initialization occurs outside the timed interval, and Profile integrity is verified before each group starts.
8. `first_useful_action`, Token counts, and tool counts are observational metrics. The hard performance Gates remain complete-task total duration and real successful request-send reduction.

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

`scripts/run-preset-lifecycle-qualification.ps1` produces strict source-bound lifecycle reports and the rollout Adapter validates three distinct G18/G19/G20 Artifacts. The manual-only Host Producer route now calls all three formal presets into separate files. Local `test-only` and `diagnostic-smoke` results remain non-formal and cannot become Gate pass; aggregation and real formal reports are still pending.

`scripts/run-v1-stop-loss-qualification.ps1` executes the four real protocol probes and one isolated canonical v1 lifecycle, binds their sanitized results to the exact source, and emits `harness-v1-stop-loss-report/v1`. The manual-only Host Producer route now calls it in formal mode, and the G14 Adapter reopens and validates the ordinary Artifact; fixture, `test-only`, and `diagnostic-smoke` results cannot become Gate pass. No formal candidate G14 run is claimed here.

## Exact-Head ordinary CI and review

Every engineering Head proposed for the Default Promotion branch must satisfy G00 after its final change:

- Draft PR source is `codex/harness-v2-default-promotion` and target is `codex/harness-v2-public-optin-beta`.
- Checkout is the exact `github.event.pull_request.head.sha` with persisted credentials disabled.
- `changed-optional` succeeds.
- The five pr-core groups `entry-lifecycle`, `evaluation-release`, `install-evidence`, `governance-approval`, and `harness-contracts` all succeed.
- Aggregate `pr-core` fails closed unless every group succeeds, then completes Core rollback.
- Each group, changed-optional, and aggregate pr-core publishes its ordinary CI Receipt artifact for the same Head.
- CI and independent Review are separate required proofs. A sentence such as `review passed` in the PR Body is not formal Evidence.
- A read-only independent Reviewer of that Head reports no P0/P1 or evidenced P2; an older review is stale after any commit.
- The Review Receipt is published externally in the PR Conversation after the final Commit, so it cannot be committed into and self-reference the reviewed Head.

The external Receipt uses `thin-harness-independent-review-receipt/v1` and records the PR number, actual Base SHA, exact Head SHA, `sha256` reviewed-diff digest, nonblank reviewer actor/context identifiers, actual reviewer model, `read_only=true`, verdict, P0/P1/P2 counts, and UTC creation time. It also states the review scope and real Findings and makes no claim of cryptographic identity authentication. If the Receipt cannot be published externally, the Review component is `unavailable` and G00 remains incomplete.

Cancelled, skipped, neutral, pending, unavailable, or missing checks and receipts are not pass. Pushing another commit invalidates the prior G00 evidence and requires a new exact-Head run and review.

## Finite route

### DP-02 — Make qualification runnable

- Single objective: remove only the implementation/contract blockers that prevent the current branch from producing every formal qualification input.
- Inputs: this contract, current Installed Desktop unavailable evidence, current Host/rollout schemas and consumers, release workflow, and lifecycle runner.
- Modification scope: `rollout-eligibility/v2` producer/consumer/Promotion/resolver migration with v1 diagnostic-only handling; distinct Installed Desktop report/qualification contract; Promotion-before workspace-v2 Desktop path; distinct rollout Installed Desktop Gate; current-branch release routing; core/governed/full lifecycle aggregation; directly corresponding focused tests and docs.
- Non-goals: real Model40/3x3, Promotion, Auto Flip, Canary, generic Writer, self-maintenance, security platform, production identity system, Desktop production execution platform, or v1 deletion.
- Verification: positive/negative runner fixtures, Installed Desktop authority fail-closed checks, rollout evidence, release routing, protocol/coexistence, and all three lifecycle smokes.
- Completion: every required producer/input/gate is independently runnable and fail-closed on the current branch; no eligible report is required to run Installed Desktop qualification.
- Maximum estimated runtime: 90 minutes.
- Failure stop: stop and report a policy/environment blocker if authoritative machine observation would require a generic Writer, security platform, production identity system, or an authoritative host API that does not exist.

DP-02A stops at the Rollout v2 core boundary above. The bounded DP-02B implementation adds the Installed Desktop producer/authority contract and G03/G07 portable Adapter only. Bounded DP-02C adds the G04 Release Isolation producer/Adapter, G14 v1 stop-loss producer/Adapter, strict core/governed/full producer with G18/G19/G20 portable Adapters, G00 Exact-head Engineering Portable Evidence, G09/G10 Release Producer Receipt contracts/Writer/Adapters, and the strict G11 Receipt/Writer/Adapter with current-branch manual-only Model/Host/Full routing. DP-02C code implementation is complete; real Release Qualification evidence remains DP-03 work.

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

- Single objective: aggregate complete DP-03 evidence into one reviewed, phase-distinct `rollout-eligibility/v2` Canary candidate with `eligible=false`, promote it only to one authorized Canary workspace, and verify Canary-scoped Auto plus v1 stop-loss.
- Inputs: all DP-03 reports, exact-Head G00 evidence, credential-blind aggregation, and explicit Canary workspace authorization.
- Modification scope: release-full Canary-candidate output, report review, explicit offline Canary Promotion, scoped Auto probe, and stop-loss probes.
- Non-goals: broad Stable rollout, source repair, real evidence rerun on the aggregator, generic Writer, or v1 deletion.
- Verification: strict v2 candidate validation, complete Gate-state coverage, `eligible=false`, all available gate/revision digests, Promotion CAS/round-trip, Canary-scoped `auto -> v2`, `HARNESS_PROTOCOL=v1`, and `disable-v2`.
- Completion: one canonical Canary-candidate report exists only in the authorized Canary workspace, cannot authorize Default Promotion elsewhere, and every resolver/rollback probe matches the same revision.
- Maximum estimated runtime: 3 hours.
- Failure stop: stop on any non-qualifying Gate, missing artifact/receipt, source or target drift, invalid report, Promotion rollback, or resolver mismatch.

### DP-05 — Canary and Stable decision

- Single objective: run a bounded Canary, record an explicit Stable or No-go decision while retaining immediate v1 rollback, and only for a Stable outcome aggregate and review the final `rollout-eligibility/v2` Default report.
- Inputs: DP-04 Canary workspace/report and approved cohort, Owner, metrics, duration, Abort Thresholds, plus Hook trust/callability advisory where authoritative automation is unavailable.
- Modification scope: Canary observations, advisory/manual host checks, rollback records, authorized Stable/No-go decision, and the final phase-correct report/review only.
- Non-goals: v1 physical deletion, production auth redesign, generic Writer, self-maintenance, security platform, or unrelated architecture work.
- Verification: predefined metrics, abort handling, report/revision continuity, v1 stop-loss, advisory truthfulness, retained evidence, and rejection of `eligible=true` unless every blocking Gate passes.
- Completion: Stable is explicitly approved with complete Canary evidence and a reviewed final v2 report, or No-go/rollback is recorded with no Default-eligible report; both outcomes preserve v1.
- Maximum estimated runtime: 7 days as a hard recommended cap, approved before DP-05 starts.
- Failure stop: immediately select v1 and stop on any Abort Threshold, evidence gap, source drift, owner ambiguity, or policy ambiguity.

## DP-01A and DP-01B stop boundary

DP-01A published the corrected contract and maintenance links. DP-01B only hardens its rollout Schema migration, exact Host-version qualification, Installed Desktop timing/cache boundary, and G00 external Review evidence. Neither batch implements DP-02, runs real Model40 or Host 3x3, runs release-full, generates or promotes an eligible report, flips Auto, starts Canary, marks Stable, or deletes v1.
