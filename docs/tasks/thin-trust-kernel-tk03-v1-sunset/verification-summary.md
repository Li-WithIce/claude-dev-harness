# TK-03 source verification and delivery boundary

This is a source implementation and evidence delivery, not full v1 Sunset,
Qualification or Release completion. The task remains open at the outstanding
global ownership/dependency and separately authorized physical-removal gates.

## Source binding

- Baseline: PR #11 exact Head
  `2e1949d7bcedc5397404d86a5ce95b51c8dde4a0`.
- Final candidate source S2: `2c5aad95c5141b24a083f95869b19221f04697c5`.
- Source tree: `12e996e668fa3aaffccf07dc887f133524e5a178`; 492 tracked files,
  3 changed paths relative to source S, no source deletion.
- Historical source S: `2827e1822d5580f9696e8e889ba754b7ac2f194b`, tree
  `15d5641b2c3a8232f4bb57f7beaf7ba339f69d95`, 17 changed paths from A.
- Historical source A: `97e220adc813f1e7aa7b01172cad193c7f45d5ff`, ordinary
  child of the baseline with 111 changed paths. Its failed CI/interrupted full
  run are not evidence of S passing.
- Draft PR: https://github.com/Li-WithIce/claude-dev-harness/pull/12,
  stacked above `codex/thin-trust-kernel-tk06-declarative-distribution`.
- Pre-verification task version: 7. Contract:
  `sha256:ce1073dd8d58d873a7c3b6b199e3f05d3ba3d40076580fc93f6d2c881b85bfbe`.

The verification revision is the native Evidence helper's actual source/dirty
snapshot, including the frozen report changes. It must not be fabricated as S2
if those tracked reports are dirty. A later docs-only delivery commit carries
this historical version-7 snapshot unchanged; it is not the source of S2's
Suite all run. Any CI for that documentation Head is a separate observation,
and Suite all on that later Head remains `not_run` unless actually executed.

This report is frozen before the final resolved-Evidence audit and native
verification transaction. Those subsequent observations belong to `audit.md`
and the native task event/transaction records, not retrospective edits of this
digest-bound snapshot. A successful audit validates the recorded results and
gaps; it does not declare the entire Sunset complete.

## Confirmed work

The v2-only protocol/admission, zero-new-work pause and v2 recovery paths,
retired v1 entry/delegation/repair writers, historical-only Memory diagnostics,
desired core/governed/full distribution, Manifest ownership and archived test
boundaries are implemented. Managed install targets now reject ancestor aliases
before state persistence, while preserving leaf replacement and per-write
ownership, CAS and rollback handling. Historical Release, Decision, Evidence,
Approval and digest schemas/algorithms, K0 hashing/path/CAS, five CoreGroup
identities and the Runtime TCB ceiling are preserved. Three Manifest schemas
change to describe archived tests; protocol-config/v2 and current Runtime
Default admission schemas are added without rewriting historical inputs.

Runtime TCB is 6,075 against the unchanged 6,151 ceiling. Fourteen legacy
fixtures are explicitly archived/not_run, not passed tests. Real installation
and fleet/Host adoption are outside this source-only delivery.

## Execution evidence

- Named legacy migration: complete as native v2 `paused`, version 1.
  `dp-03-real-qualification` was never executed. Original plans/Evidence,
  both DONE v1 histories and the shared v2 current pointer remain preserved.
- Source Approval `apr_tk03_carrier_delivery_v7`, genuine different-actor
  Preview, and ordinary Commit bind the same operation:
  `sha256:ca2de3e92311c029f5d791ad4c52b49bef3c8db52e5d1588c7a37b1d108fc2b2`.
- S2 Preview: exit 0, 13:45:40.3721054Z–13:45:45.5630354Z; executor actor
  and context `/root/tk03_migration_review`, exact model unavailable.
- Implementer S2 Commit: exit 0, 13:47:27.3870589Z–13:47:31.4387976Z.
- Exact S2 quick: pass, 2026-08-31T13:48:37.1270993Z to
  13:49:22.4098391Z, exit 0, source Head/tree intact. Full log retained at
  `tmp/tk03-validation/suite-quick-20260831-214836/stdout.log`, raw SHA-256
  `7fa89d7399657bf6e46488e5ba8c9288877459e80681ab4cf47bfb7f82f470ae`.
- Exact S2 Suite all: terminal pass, exit 0, during
  2026-08-31T13:49:26.4780277Z–15:07:54.9249118Z. All 73 active catalog
  verifiers plus Git diff passed (74 outer checks), with clean source binding
  intact and the final stdout line `STATUS: PASS`. Fourteen archived tests
  remain not_run; the installed-only verifier is a design skip. Task-state
  reports 142 checks and one unavailable dynamic SUBST case, not 143 passes.
  Stdout raw SHA-256:
  `df29c95bc65795a117c19629c96dd62694456a25ef53d3e4d68935a783ee498f`;
  stderr raw SHA-256:
  `8bb15db2509d730f181d0dbb68f14ea65e6f2312fc6bc1f553ba044b8f5eb339`.
  Stderr contains only three Git LF-to-CRLF warnings, not an empty stream.
  The closed-log/catalog inspection passed at 15:13:49.1809999Z, raw output
  `586495eff16f554d891fb62a86b49e6fe837084c330f8769893bac81c504e10c`.
- Exact S2 ordinary CI: `33398967580`, attempt 1, terminal success during
  2026-08-31T13:48:12Z–14:06:52Z. Seven engineering jobs passed; three Release
  jobs were skipped. The read-only receipt inspection passed during
  14:10:24.3049071Z–14:11:01.6150834Z, binding all seven archives and strict
  receipts to S2, PR 12 and the exact PR #11 base; no CI rerun or dispatch.
  Inspection output raw SHA-256:
  `9e2fd2ca98eb281e287f0cdd269758bc432825c98f1afd029b38b7a97efabe33`.
- Scoped preservation inspection: pass, 14:09:02.7211199Z–14:09:05.7456234Z,
  all six preserved files and the imported paused/version-1 task unchanged.
  Output raw SHA-256:
  `feb0670d2d74c1694a6f90547e31011eb9393cb6620b849f64f515646ad30980`.
- Hardened focused checks: passing results cover 13 distinct verifiers across
  frozen pre-S snapshots. Original failures and all source bindings remain in
  verification-history.md; these are not claimed as exact S Suite all.
- Exact S quick: pass, 2026-08-31T13:15:13.0705918Z to
  13:15:59.1501265Z, exit 0, source Head/tree intact. Full log retained locally
  at `tmp/tk03-validation/suite-quick-20260831-211512/stdout.log`.
- Exact S Suite all: interrupted, exit -1; source binding intact, not a pass.
- Exact S ordinary CI: run `33395891144`, pull_request event, terminal failure.
  The sole failing entry-lifecycle verifier depended on installed Codex command
  discovery. The corrected fixture passes with PATH restricted to its owned
  fake Host; S2 contains this fix and requires its own exact-head validation.
- Exact A quick: pass, 2026-08-31T11:49:36.4565096Z to
  11:50:20.3333703Z, exit 0.
- Exact A Suite all: interrupted, exit -1; not a terminal pass.
- Exact A ordinary CI: run `33388837508`, pull_request event, terminal failure.
- Final resolved-Evidence audit and native verify: not_run yet.

Every intended local test target was a tracked-source-only isolated checkout and explicit
fixture roots under `D:/data/dev-harness-next`. Non-PowerShell rollout test
evidence used `D:/data/dev-harness-validation-temp`. No actual `.qoder` access
was observed; the earlier private runner's ancestor-reparse validation gap is
recorded in verification-history.md and is not retrospectively ruled out by
later metadata checks. Final runs require the hardened K0-contained entries.
No real installation or live Release execution was used. Earlier deviations and failed or
interrupted attempts remain in the adjacent history; later passes do not erase
them.

## Outstanding gates

See `sunset-matrix.md`. External task/Host/operations owners have not confirmed
zero active v1 dependencies; not every historical task disposition is known;
no real runtime/default/distribution rollout was performed. The explicit
migration bridge remains retained. No gate is promoted merely from the one
authorized migration, a local source pass or an old Release receipt.

With the terminal S2 results recorded, the planned native Evidence
conclusion is `blocked`, leading to `paused`, not `done`; native verify remains
`not_run` until actually executed. A later docs-only B delivery requires its
own subsequent task-version Approval and genuine independent Preview, while
retaining the version-7 source Evidence unchanged. That delivery neither
resumes the imported task nor changes an unmet global gate to `met`.

The strict full-task coverage retains AC-10 as `not_verified`: ordinary source
delivery, current preservation checks and the Draft PR have evidence, but the
earlier validation-host ancestor-path limitation cannot be retrospectively
excluded. AC-11 remains `blocked` at the unfulfilled global/deletion gates;
the matrix and exact proposal themselves are present. These are completion
gaps, not undisclosed source-test failures.

Physical deletion is `not_run / not authorized`. The adjacent exact
`proposed-stage-body-removal.patch` is a bounded proposal only. Do not apply it
until all ten gates have current supporting evidence and the user separately
confirms that exact diff. Qualification, workflow_dispatch, Promotion, Auto
Flip, Canary, Stable, Ready/merge and TK-07 remain `not_run`.
