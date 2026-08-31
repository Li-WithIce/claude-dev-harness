# Migration preflight history

This records a real preliminary review, not the final task audit.

The independent `/root/tk03_migration_review` actor ran `Inspect` from
2026-08-31T09:27:38.8484321Z to 2026-08-31T09:27:39.9237020Z, exit 0 and
shared_writes=0, on initial driver digest
`sha256:4df851f88c1a373fbb7ab5e0eab468da65493545e92a4937cbbad8775ec49826`.
It found a P2 recovery gap before formal migration: native dry-run failure or a
missing/invalid report could leave the released pointer idle without an
explicit conditionally safe restoration command. No pointer release had run.

The implementer added explicit `Rollback`, guarded by absence of the imported
v2 task, unchanged preserved files, existing locks and exact postimage CAS.
Native report loading/validation now also sits inside the migration recovery
try/catch. The updated driver digest is
`sha256:ae24a6b9d7a2ebd12dd77981608b22af71c547b976348f096ee8612ed62a3349`.
The private pre-execution source binding was refreshed; the authorized targets,
scope, Contract, task version and protected-operation identity did not change.
The initial review is historical; a fresh independent preview is required
before release.

## Source reviews after paused migration

These are preliminary read-only source reviews, not final Evidence acceptance.
Actor/context: `/root/tk03_migration_review`; independent of the implementer.
Exact model identifier was unavailable. Each review used exact-path reads,
bounded diffs/searches and raw file hashes; shared writes and test executions
were zero.

- 2026-08-31T10:07:19.4942983Z to 10:09:25.2685009Z: found that a Decision
  directory could be mistaken for an absent Decision. The implementation now
  rejects non-file Decision inputs. The 23-check Sunset regression passed
  before the subsequent ancestor-path finding.
- 2026-08-31T10:26:55.5749002Z to 10:28:02.1182330Z: confirmed that fix and
  found an adjacent P2: a non-directory `.assistant/runtime` ancestor could
  still look like an absent Decision. Reviewed RuntimeDefault bytes were
  `sha256:c543d4733854028c1e0b168c7e628b4d3c4bb0bb7746139003a8bbf7d8d417b4`.
  The implementer added explicit ancestor directory checks for Decision and
  protocol config paths, plus three zero-write regression cases. Current
  Memory templates were also checked for ordinary v2-to-v1 instructions;
  none were found. This is not authorization for Memory writes.
- 2026-08-31T10:36:11.2904935Z to 10:37:44.4721901Z: found a P1 in retained
  Stage delegation: prepare read the old plan, and commit could append to its
  review trace even after native paused migration. Reviewed delegation bytes
  were `sha256:01967507325f9fe3b33336548d9717b6f735cabe13e6adf9cad9733946ffeca2`.
  Found a P2 in the active old skill verifier, which still required v1 Stage
  success. The implementer retired both exports and old Team spawn before
  legacy access, archived the two Stage-based verifiers, and extracted active
  dispatcher/supervisor checks into `verify-adapter-transport.ps1`. Fresh
  tests and independent review are required before these findings are closed.

The follow-up review ran from 2026-08-31T10:47:11.4825730Z to
10:48:38.6296522Z. It found no new concrete finding and confirmed the static
closure of both ancestor-path P2 cases and the delegation P1. The active
transport/preset versus archived Stage-test separation was also confirmed.
Tests and final exact-Evidence audit were explicitly not run by that reviewer.
The implementer's isolated snapshot `09a64b5bdee7d6c139237718be0e5644f4026dc0`
subsequently supplied the real 35-check Sunset and 13-check transport passes.

| Re-reviewed source | Raw SHA-256 |
|---|---|
| `Harness.RuntimeDefault.psm1` | `ca54dc14b3dfdb902b2d8537ebb02e13de18139f9699533093d65d0235b0be18` |
| `Harness.Protocol.psm1` | `f084462d208ea2e321a688628754a8452759ed19b404cb8cba323822882d99fd` |
| `Harness.AdapterDelegation.psm1` | `d3624a817671d87f0421f1e54b232812b9a9cdf78454a93c78e5940171205554` |
| `skills/workflow-team/scripts/spawn-team.ps1` | `20f60983eae1e5036e9a2ef85839b52e697b500a2d706100bf8a85cdd15239d9` |
| `modules/team/module.manifest.json` | `c53e3cd073b934c046e8bf9b48108782c3b4189ac7ba78b80de3a787bcf9a0f3` |
| `modules/legacy-v1/module.manifest.json` | `25af1152d900a4d5ca580ef41228a9930e2d5163868969ab975e6a1bca280625` |
| `tests/verify-adapter-transport.ps1` | `c0843015faf62f09777d0af06f6490525146e8e929e519b42ca568d2d0756c51` |
| `tests/verify-v1-sunset.ps1` | `fb4472caa78e87c554029aa8c13212ba9766a90f5acf4f94b3dd8bd2064aedcd` |

## Validation execution deviation

The independent Memory boundary review ran from
2026-08-31T11:00:47.0988929Z to 11:03:12.9308695Z with the same separate
reviewer actor/context. It found two P1s (repair/retirement could mutate legacy
mirrors; new inbox capture inferred identity from old current/flow) and two
P2s (fresh v2 health demanded retired mirrors; active tests required retired
repair/identity behavior). Reviewed digests included:

- repair: `sha256:f4e31a478802b0eefeb2598635c6b0c6f2b730cddf742f4310d487c9d85551bd`
- inbox helper: `sha256:b52cd8ef229d2326c71a41f77b0fd891c9338955cf945c11eebf35d05ddbf535`
- checker: `sha256:86ec639d56e3da8bd2084840f9d32ab959c494475b575be5d7556cf12c10e7b0`
- Memory Manifest: `sha256:da6be01675c792455eff6f98b2a8e865b5e7b8283913b686400ae176ab009332`

The implementer closed these code paths, kept candidate archive/inbox/report
coverage active, and archived only the old repair verifier. The reviewer
also required precise NOT_APPLICABLE propagation, strict history metadata
preflight, no implicit agent-home scans, and the same historical-only boundary
for the layer checker. A fresh source review and tests remain required; this
history is not the final exact-Evidence audit.

The 11:16:03.5733262Z–11:17:41.2377251Z review confirmed those four fixes and
found two narrower P2s: flow-only Vault resolution read before metadata
preflight; basic Memory asset parent junctions were not checked. The
11:20:40.9281143Z–11:21:04.1080448Z follow-up confirmed those scenarios fixed
and identified `Select-String -Path` wildcard expansion after literal path
validation. The implementer added full explicit-flow ancestor validation,
the two basic-asset parent checks and literal content reads, with focused
flow-only/junction/locked-neighbor regressions.

The final limited Memory source review ran from
2026-08-31T11:24:08.6016633Z to 11:24:47.0659583Z. It found no new direct
regression and statically closed all three path P2s. It did not run tests or
review the separate TCB expectation update and is not a final Evidence audit.

| Re-reviewed Memory source | Raw SHA-256 |
|---|---|
| runtime-state-common.ps1 | 4d49fb7bc1339b018475cfb46168b7166603b7da669a8ffead7fa4ca0eb8b8b8 |
| resolve-shared-memory-paths.ps1 | ca95c647a9501a18b14dd3439c865814421ff03969ade18324d90a77b4ead13e |
| check-shared-memory.ps1 | 81ea2bdd6688702a3b57d98d3cba6c691230234cbe9a1790f44732e15b40a39a |
| check-shared-memory-layers.ps1 | 1e692f10551bf80dd729dc66cebeebc300adc3b1e08c8480bf21d876c8a3438d |
| runtime-inbox-common.ps1 | dd79e52439cbc4880eb1a2f23093820c677641bbad11949e2a563ebbe4ed9d90 |
| verify-memory-health-report.ps1 | 00700e36b215fd0d9817d8d73b3ed81a4eb2a831a072cc29308eef9db1899f26 |

An early runtime-hook fixture used a nested unresolved working directory. Its
workspace resolver could ascend to the real installed workspace and issue a
read-only native v2 status call. No pointer writes or actual `.qoder` access
were performed. The fixture now sets an explicit invalid workspace root to
prevent ascent; the corrected runtime-hook verifier passed. This is recorded
separately from the retained earlier TK-06 `.qoder` execution deviation.

## Source-delivery preflight and independent dry-run

The 2026-08-31T11:31:33.4762492Z–11:36:10.1972293Z review rejected the first
private commit driver before any Approval import or execution: P1, a live
index/Head race could commit an unapproved tree before a post-check failed;
P2, its hook denylist omitted reference-transaction/post-index-change; P2,
lexical containment and supplied snapshot paths could escape the allowed
private/preserved paths. The rejected driver raw digest was
`sha256:b4b4b6b84fbaa994acd21354be729cf9a68959ebf58f5086bde3fdbb0fad7a6c`.

The corrected driver creates an ordinary single-parent object from the exact
approved tree/base, then CAS-updates only the named branch, without changing
the index/working files or retrying a failed CAS. It fixes the Git Application,
rejects non-sample hook metadata, uses K0 containment for exact private paths,
fixes the six preservation inputs and legacy pointer, and binds the migration
snapshot raw digest. Output is CreateNew, never an overwrite. A preliminary
function-name collision was also corrected before execution.

The same independent reviewer statically closed all three findings during
11:43:29.3679230Z–11:46:27.1158588Z. Corrected driver raw digest:
`sha256:b04f3221d2f6ab6eb0fc6819b858b165d1c94de84526d29f758227089bfb55d0`.
The deletion proposal was separately checked as a one-file/one-hunk candidate
leaving the 34-line reject stub; no patch was applied by the reviewer.

The native source Approval was then imported as
`apr_tk03_source_delivery_v5` at task version 5; shared pointer unchanged.
The reviewer genuinely executed the Preview once in its different actor/context
(`/root/tk03_migration_review`, exact model unavailable). Process time:
11:48:17.4136251Z–11:48:19.8627391Z; exit 0. The driver's inner Git operation
ran 11:48:18.0792954Z–11:48:19.7585460Z. Head, approved index tree, task/live
Approval raw bytes and prescribed preserved state remained unchanged.

- Preview output raw digest:
  `sha256:4ec48669b36c1d84fdb62f7d80bb3ba4dc5ff8a274849d143882ee6f1bc43347`.
- Protected operation:
  `sha256:945c6c571436d2330805b4781efa3fa769108235373c7351ec82c546b0e8b582`.
- Approved tree: `9e7896e1489c2a124edf6bad99d73b03a5c49602`, 111 changed paths.
- The implementer's matching Commit ran 11:49:11.7715817Z–11:49:13.9091325Z,
  exit 0, publishing `97e220adc813f1e7aa7b01172cad193c7f45d5ff` as the ordinary
  child of the exact PR #11 baseline. Shared state remained preserved.

This is an actual operation-bound independent dry-run, not the final audit of
resolved Evidence. Physical removal and Qualification remain `not_run`.

## Current-test retirement and validation-host review

The same independent actor reviewed the retained stop-loss test front branch
and Rollout nullable-fixture migration during 12:05:59.9798446Z–12:06:53.7315330Z.
Its P2 finding was an extra-empty-directory blind spot after pause; this was
fixed with the exact directory-and-file allowlist before subsequent tests.
The old successful-v1 body remains retained and unreachable; historical full
report Schema and Adapter rejection cases remain active synthetic checks.

The subsequent bounded actual-diff review ran
12:20:04.9961770Z–12:23:31.9860125Z. It found no P0, but one P1 and three P2:

- Private refresh/runner roots lacked complete ancestor-reparse rejection.
- The refresh helper still permitted bounded untracked inputs.
- Focused results could label dirty source bytes with an old Head.
- A retired-v1 scenario could accept an unexpected normal return as a block.

These were corrected using the existing K0 path functions, strictly tracked
copy inputs, explicit Head/tree/clean preflight and post-execution source
checks, and unconditional rejection of a retired-v1 normal return. No K0 or
Qualification production implementation was changed. Closure review and final
source-bound dry-run/audit remain separate actual operations; this intermediate
review is not final resolved-Evidence approval.

The next review (12:30:44.7174782Z–12:34:35.5401148Z) kept that P1 open:
some Git status calls preceded metadata validation, or reused the source copy
list instead of the target clone's current tracked list. The helpers now read
each relevant index first, reject protected paths and K0-invalid leaves or
ancestors, then inspect the worktree. Focused/full runners repeat those checks
after execution; refresh checks the target clone before its snapshot commit
and again before final status. These checks do not retroactively establish the
safety or source binding of the earlier attempts.

The independent actor statically closed that P1 with no new P0/P1/P2 during
12:39:17.2107368Z–12:40:11.1652917Z. Four immutable reviewed helper digests:

- refresh: `sha256:b1dac94bcf591aa8a9290f9b0d047c6544d3762e25c37e802a3067d5ab79bede`
- focused: `sha256:d693e41bc46d093d1c493c29bfe2d0c877bbebd240684096875847759d9550e6`
- suite: `sha256:f7db808b9e569a242bc7354b0da8a6ca728c1c186edef0a7df1b9710e80b9c3e`
- correction delivery: `sha256:fa63920b6eb4f040ac783752c742d4ae05961bb53b3aad1925f5c76fbd62fef7`

The correction driver retains the reviewed exact-tree/single-parent/CAS and
preservation checks, with new mode-specific evidence paths and K0 worktree
preflight. This review did not run tests, Preview, Commit, or Runtime writes;
the concrete correction Approval/operation and final Evidence audit still
require their own actual bindings and execution.

The final two installation fixture corrections were independently reviewed
during 12:48:32.3002221Z–12:49:12.6110433Z with no new P0/P1/P2. The core
reparse fixture now targets the actual managed task entry without weakening
victim/no-residual-state checks; the full Memory protocol uses the verifier's
existing single managed-asset drift marker and an added restored-byte PASS
check. Reviewed verifier raw digest:
`sha256:680246d9b5d235e53bcf64cbc5a25549bc032f229ce648fda943f999a7b48996`.
This was exact-file read-only static review, not a dynamic pass.

The next isolated run established an actual late-rejection gap, as recorded
in verification-history.md. The seven-line installer preflight correction was
then independently reviewed during 12:59:55.4033473Z–13:01:02.0430764Z with no
new P0/P1/P2. It runs under the existing mutex before all installation/legacy
marker/recovery persistence, outside the recovery-manifest-writing catch. It
checks only managed vault target ancestors and retains final-leaf exact/CAS
handling. Reviewed installer raw digest:
`sha256:36f58b164ee1001a930bda48a1663c6bdb0af9064142d42066ed0b3aadf5c432`.
The old tests-only tree's unimported bindings do not cover this source change.
