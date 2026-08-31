# TK-03 validation history

All local validation runs below used tracked-source-only isolated checkouts (`source`,
`recheck-source`, `correction-source`, `exact-source`,
`exact-corrected-source`, or `exact-carrier-source`) under
`D:/data/dev-harness-next/tmp/tk03-validation`. Earlier rows are local snapshot
commits, not the final PR Head; exact PR-Head runs are explicitly labelled.
PowerShell fixtures stayed under the fixed
project root. Rollout input/output fixtures used the separately authorized
non-PowerShell evidence root. None is real Qualification or Release execution.

| Run (UTC, 2026-08-31) | Snapshot | Actual result |
|---|---|---|
| 10:02:13–10:04:06, `admission-hooks-20260831-180213` | `20fd5873aab06dfa2681eca954aefbb8897944bb` | 3 pass, 3 fail. Direct, explicit paused migration and initial Sunset passed. Entry, hook and decoupling expectations required correction. |
| 10:14:05–10:18:17, `tk03-contracts-20260831-181405` | `e7ad8066fea1ba63146f7d8bf6ebc067e87fee7d` | 5 pass, 5 fail. Corrected hooks, codex bootstrap, Sunset, legacy marker and decoupling passed. Entry budget, catalog/TK-03 fixture support, governed-profile negative cases and explicit external evidence root were corrected afterward. |
| 10:27:28–10:44:16, `tk03-recheck-20260831-182728` | `24dcc86e1b34cdeaf2cfafd3501d31d64e2f29a0` | 6 pass, 3 fail. Entry, kernel contracts, catalog, distribution, adapters and Capability source closure passed. Policy Schema list and CI route expectations were stale; default-flip diagnostic output was absent. |
| 10:47:23–10:48:13, `tk03-retirement-recheck-20260831-184723` | `09a64b5bdee7d6c139237718be0e5644f4026dc0` | 4 pass, 1 fail. Transport 13 checks, Sunset 35 checks, policy and thin adapters passed. Default-flip exposed the underlying `rollout-source-file-missing` diagnostic. |
| 10:50:20–10:54:35, `tk03-default-utf8-recheck-20260831-185020` | `09a64b5bdee7d6c139237718be0e5644f4026dc0` | Default-flip structural verifier passed through the existing UTF-8 validation supervisor; no production code change was needed. |
| 10:56:18–10:57:00, `suite-quick-20260831-185618` | `09a64b5bdee7d6c139237718be0e5644f4026dc0` | Quick passed (diff check and lite footprint). |
| 10:57:00–11:08:15, `suite-all-20260831-185700` | `09a64b5bdee7d6c139237718be0e5644f4026dc0` | Interrupted before Memory health, exit -1; not a Suite all pass. Archive candidate fixture failed because default core no longer installs optional Memory. Capability, Distribution, transport and exact-head structural checks passed before interruption. |
| 11:16:25–11:25:02, `tk03-memory-retirement-20260831-191625` | `b87d84dfd1fa69def4a41f93c5efc4334173da97` | All 8 checks passed: Sunset, candidate archive, archive-only maintenance, historical report, provider boundary, inbox, triage and CI routing. |
| 11:20:54–11:25:08, `tk03-memory-paths-20260831-192054` | `3e48f5ab44ac54081d55546f9427aaf29a3d78ff` | Historical-path/report and catalog checks passed. TCB check failed two stale exact-value assertions (6150 versus the generated 6075); the unchanged 6151 ceiling and generator parity passed. Expectations were corrected, not the budget. |
| 11:30:50–11:32:01, `tk03-final-focused-20260831-193049` | `b7e13825d95fa9eb7f6a87fac8d77dd70b6ee678` | All 5 checks passed: historical report, inbox, TCB, kernel contracts and 40-check Sunset. Its complete 492-file tree `9e7896e1489c2a124edf6bad99d73b03a5c49602` is identical to source commit `97e220a`. |
| 11:49:36–11:50:20, `suite-quick-20260831-194936` | exact PR Head `97e220adc813f1e7aa7b01172cad193c7f45d5ff` | Quick passed, exit 0: diff check and lite footprint. This does not stand in for terminal Suite all. |
| 11:50:20–11:58:00, `suite-all-20260831-195020` | exact PR Head `97e220adc813f1e7aa7b01172cad193c7f45d5ff` | Interrupted, exit -1, during declarative Distribution. Stopped before the old stop-loss producer and Memory health checks to close inherited USERPROFILE/config paths. No terminal Suite all pass. |
| 11:50:21–12:09:03, ordinary CI `33388837508` | exact PR Head `97e220adc813f1e7aa7b01172cad193c7f45d5ff` | Terminal failure. Governance-approval and install-evidence groups passed; harness-contracts, entry-lifecycle, evaluation-release, changed-optional and the aggregate failed. Release jobs were skipped by design, not qualified. |
| 12:16:23–12:23:48, `tk03-ci-contract-recheck-20260831-201623` | `58a2c12d2a85c98405a1d64bff49d56e7d57eb82` | Four pass, two fail. Retirement/historical compatibility, deterministic scenarios, entry and Rollout Schema/reader passed. Model mock lacked explicit exit 0; task-state retained one late ancestor-v1 success expectation. Both fixtures were corrected afterward. |
| 12:16:26–12:21:56, `tk03-ci-install-recheck-20260831-201625` | `322afde122a3cc9293b8edf2aa660edfea6926ed` | Update passed. Install reached a later retired entry-AGENTS drift fixture and failed; uninstall exposed the incorrect assumption that core installs spec. Corrections use the current task shim and explicitly governed planning-link fixtures. |
| 12:18:06–12:18:10, `tk03-model-carrier-diagnostic-20260831-201806` | `69bf30587e6fa4952f84a830d711d472a9d77b90` | Failed with the real diagnostic: the pure-PowerShell fake Host returned without setting LASTEXITCODE. Explicit exit 0 was added to the fake Host only; production wrapper unchanged. |
| 12:19:06–12:19:16, `tk03-model-carrier-recheck-20260831-201906` | `b6709151821363a6597cf0625baec857685016bc` | Both model-neutrality and model-eval-runner checks passed. The standalone production wrapper used a local fake Host, never a real model or the retired Stage ABI. |

Per-check start/end UTC, exact exit codes and full stdout/stderr remain in each
run's `results.json` and sibling log files under the private validation root.
Later corrected passes do not erase these failures or turn their old source
bindings into current evidence.

## Validation-host encoding correction

The initial private focused runner directly created hidden PowerShell children.
A read-only diagnostic showed their Console output encoding was `gb2312`,
while Git's `core.quotepath=false` paths were UTF-8. This misdecoded the tracked
Chinese template paths and produced `rollout-source-file-missing`, despite
their presence in the isolated checkout. The same exact-path diagnostic with
UTF-8 Console decoding resolved all 405 selected paths and found zero missing.

The private runner now reuses the repository's existing UTF-8 validation
supervisor and bounded Job Object containment. No Qualification production
code, historical digest algorithm, source-file list or artifact boundary was
weakened. The test retains an early assertion reporting the real generator
exit/error when an expected diagnostic artifact is absent.

## Interrupted full run and fixture binding corrections

The first full run was stopped while `verify-harness-entry` was starting,
before any Memory health verifier. Review found its legacy checker could
inherit real `CLAUDE_HOME`/`CODEX_HOME` and scan outside the fixture. No such
scan was observed; it was prevented before those checks ran. Private runners
now pin both homes to isolated paths and clear inherited workspace/vault
selectors. Production historical diagnostics no longer scan agent homes.

The first stop attempt matched the diagnostic command itself; the process
API refused self-tree termination and no process was stopped by that attempt.
The corrected exact `-File` selector excluded the caller and terminated only
the isolated validation process and its descendants. The interrupted run's
logs and negative exit remain retained, not relabeled as a terminal pass.

Snapshot `09a64b5...` tracked 484 files. Five ignored governed task documents
were copied but not included by its former `git add --all`, so it is not a
complete source-index binding. The refresh helper now stages every exact
authorized source path, including those five files, before snapshot commits.
Future final validation must use that corrected complete snapshot.

## Source A CI and private validation boundary corrections

The first exact-head ordinary CI also exposed stale successful-v1 fixtures:
default writes were expected to reject without an explicit protocol override;
ordinary status was expected to warn merely because no Release Decision
existed; Stage delegation and retired install assets were still assumed to be
active. These are corrected as current v2 admission, explicit legacy refusal,
standalone carrier isolation, and current desired-asset tests. Original CAS,
transaction recovery, ownership, rollback and drift-marker assertions remain.

The old stop-loss verifier attempted its diagnostic-smoke producer in CI and
failed to produce a report; this was not formal Qualification. Its active
local/CI branch now checks retirement and preserved historical Schema/reader
semantics, and exits before all three retained historical producer calls.
The five nullable-digest negative cases remain Schema-plus-Adapter rejection
tests on complete valid synthetic reports, with recomputed digests. Historical
producer code, Schema and digest algorithms were not changed.

Independent review at 12:20:04–12:23:31 found that the private refresh/runner
paths only enforced lexical roots and source-leaf checks, and that focused
results did not enforce a clean tree binding. No actual protected-path access
was observed. A later K0 metadata-only check accepted all 492 tracked source
paths and the named clone/run roots, but is not retrospective proof of those
earlier executions. The scripts now reject ancestor reparse paths through K0,
require their own contained Git root, reject Git path overrides, copy only
git-tracked inputs, isolate each run's homes, and bind clean source Head/tree
before execution and check source preservation afterward. Final validation
must be repeated through these hardened entries. Earlier results are retained
as historical observations with this limitation, not upgraded to final proof.

The former bounded untracked input scan returned additional_source_count=0 in
every recorded refresh; it has nevertheless been removed so that tracked-only
is enforced. A separate scenario finding was also fixed: any normal return for
the retired-v1 fixture now fails, rather than accepting a nullable completion
value as a false/block result.

The hardened contract run `tk03-hardened-contract-20260831-204107` completed
six focused checks with exit 0 and unchanged source bindings. Its snapshot is
`a73ab4862c48b255c9f406b395e1802786c191bc`, tree
`adf16f07d7e768cb86f1ee8a4ff0ef6839ade599`. The task-state dynamic SUBST case
remains a separately reported Host unavailability, not an executed pass.

The same-tree hardened install check ran 12:41:07.8421100Z–12:45:10.6696365Z,
exit 1 with its source binding intact. After the earlier entry-shim fix let
the file reach its final report, it exposed two more retired assumptions:
the nested-reparse victim was under an obsolete v1 runtime asset, and a full
Memory protocol drift expected the removed special-case verifier label. The
fixture now targets the current core entry/task.ps1 junction while preserving
victim bytes/count and zero partial-state checks. The full protocol remains
managed and must produce exactly the existing single shim-template-drift
marker; restoring its original bytes must return verification to PASS.
No installer/verifier production behavior was altered for these corrections.

The next exact installation run (12:51:08.8811835Z–12:54:45.7904644Z,
snapshot `e32d65076276414887c8951582b4eb0a5329c439`) failed only the nested
current-entry zero-residual-state check; full protocol drift and restored-byte
checks passed. A separate contained probe during
12:57:02.7503714Z–12:57:07.4004816Z established a real installer preflight gap:
the child rejected the reparse target and preserved the sole victim file, but
only after creating a recovery manifest and user-global state directories.
It was not a false test failure and was not relabelled as pass.

The installer now checks ancestors of declared managed vault targets under
the existing transaction mutex, before transaction or legacy-marker writes.
It reuses the existing path guard, allows only the already-supported final
leaf replacement, and does not read preserved user-owned/create-if-missing
assets. Per-write identity/CAS/rollback behavior is retained. This is a bounded
production correction to restore the confirmed invalid-input zero-write
boundary; the earlier tests-only candidate and its unimported Approval draft
are superseded. No candidate Preview, Commit or native Approval ran for it.

## Corrected source S and hardened checks

The hardened same-tree catalog run completed four checks with exit 0 and
unchanged source binding: Rollout Evidence, Module catalog, TCB inventory and
Capability extraction. The run is `tk03-hardened-catalog-20260831-204107`,
snapshot `790408867137345771757e22f04fcdb6f9640945`, tree
`adf16f07d7e768cb86f1ee8a4ff0ef6839ade599`; its last check ended
2026-08-31T12:54:05.1067259Z. Results raw SHA-256:
`d1733b6de7d27c1a96e711361a730dfbbfafab2f308b65f6f750a9baaedc80f8`.
The six-check hardened contract results raw SHA-256 is
`319ea7590eed8bb12106049673c1ce1bdec273727b333426c5288ad4ffbcc637`.

In the first hardened install run, uninstall passed during
12:45:10.6864854Z–12:47:09.2662294Z, and managed update passed during
12:47:09.2745066Z–12:48:46.1119799Z. These passes do not erase that run's
installation failure. Combined results raw SHA-256:
`c80083fdbc3ae9463a80194a87420c4f188653d467ca569fe70b72883df9e2bb`.

After the actual installer preflight fix, the hardened run
`tk03-hardened-install-preflight-20260831-210147` passed installation isolation
during 13:01:47.4514022Z–13:05:08.6988113Z and TCB inventory during
13:05:08.7136329Z–13:05:34.0319876Z, both exit 0 with clean source binding
unchanged. Snapshot: `058662619ff00c67fdbc8b336c49a61cf45a7ce7`;
tree: `f422480b069b2be6a140ab51b4959c8efa518ff5`. Results raw SHA-256:
`5e3024d671b6a50de73114a8f06e8c0d69787f40dbd03e6eb7ec3c7bd9f2d744`.
Its source differs from S only by the subsequently appended review history.
The current nested-entry alias test therefore passed its original victim,
no-partial-state and rollback boundary assertions; no test was weakened.

Corrected source S is the ordinary child of source A:
`2827e1822d5580f9696e8e889ba754b7ac2f194b`, tree
`15d5641b2c3a8232f4bb57f7beaf7ba339f69d95`, 17 changed paths, no deletion.
The new `exact-corrected-source` checkout contains only its 492 tracked files.
The exact S quick run passed, exit 0, during
13:15:13.0705918Z–13:15:59.1501265Z; source Head/tree remained clean and
unchanged. Stdout raw SHA-256:
`cfaf578e18a3063e532d2f9535e65a729533e07b837ca1b57cfc1de4268ef59e`.
Exact S Suite all ran 13:16:03.0068279Z–13:38:42.1911595Z and was deliberately
interrupted after CI established the missing-tool fixture failure, to switch
to the corrected source. The exact owned inner validation process was checked
by PID, parent PID, full command line and creation time before stopping its
tree; its parent runner completed normal postchecks and recorded exit -1,
status fail, source binding intact. This is not a terminal Suite all pass.
Stdout raw SHA-256:
`a9d2910f6955790a0a90fa7b0b67c5e2526e6d41b8638071933a7020f5023506`.
The old clone, launcher and logs remain retained without source replacement.

## Source S CI and model carrier discovery correction

Ordinary S CI `33395891144` completed during
2026-08-31T13:14:41Z–13:32:13Z with conclusion failure. Four core groups and
changed-optional passed; entry-lifecycle and its aggregate failed. Three Release
jobs were skipped. The sole failing entry-lifecycle verifier was model
neutrality: the unchanged production carrier performs `Get-Command codex`
before consulting `CODEX_EXECUTABLE`. The fake test backend supplied only the
override, leaving command discovery dependent on an installed Codex. That
dependency existed locally but not on the clean CI runner. The earlier local
passes were real results but did not prove this missing-tool environment.

The fixture now launches PowerShell by its captured absolute path and gives
the carrier a PATH containing only that workspace's owned fake Host directory.
PATH and the executable override are restored in finally. Each fake response
reports the discovered command path, and all three calls must resolve exactly
their own fixture. All model, session, read-only and original-byte preservation
assertions remain; no production carrier or historical Schema was changed.

The hardened `tk03-model-path-isolation-20260831-213321` run passed model
neutrality (15 checks), during 13:33:22.0884008Z–13:33:31.7192342Z, and the
model evaluation runner during 13:33:31.7386237Z–13:33:38.7775709Z. Both exited
0 with unchanged clean source bindings: snapshot
`ed5b9d476dc5e0e7cee77f918bd855e0ae3f7428`, tree
`2501653cef9cd383f706936887a39bc517227245`. The corrected verifier raw SHA-256
is `ace989d6767b87df61b1d8b1d066edab9972d9029f1073079bb57e6aeb238160`.
This is a new source change; S's failed CI and any S Suite observation are not
promoted to successful evidence for its later commit.

## Final candidate S2

Source S2 is `2c5aad95c5141b24a083f95869b19221f04697c5`, tree
`12e996e668fa3aaffccf07dc887f133524e5a178`, an ordinary child of S with only
the model discovery fixture and two existing history reports changed. The
Git-object-only `exact-carrier-source` checkout contains 492 tracked files;
K0 metadata validation preceded working-tree checks and confirmed a clean
exact source binding. It does not replace the earlier clones or failed logs.

S2 quick passed during 2026-08-31T13:48:37.1270993Z–13:49:22.4098391Z,
exit 0, with source Head/tree intact. The outer checks were Git diff validation
and lite footprint. Run: `suite-quick-20260831-214836`. Stdout raw SHA-256:
`7fa89d7399657bf6e46488e5ba8c9288877459e80681ab4cf47bfb7f82f470ae`;
stderr was empty. This remains separate from the S2 Suite all and ordinary
CI run `33398967580` results; no terminal result is inferred from quick.

A read-only source/preservation inspection during
2026-08-31T14:09:02.7211199Z–14:09:05.7456234Z confirmed S2 Head/tree,
492 K0-checked tracked paths, only permitted report changes, all six migration
preservation digests, the idle legacy pointer and dp-03 paused/version-1 state.
K0 hashing/path/CAS and the workflow are unchanged from the baseline. The only
Schema changes are the three Manifest schemas and two new admission schemas.
Runtime TCB remains 6075/6151 with no exception. The exact removal proposal's
cached check returned 0 without applying it. The first read-only command text
had a PowerShell parse error before executing any statement; the corrected
inspection, not that failed attempt, supplies these results.

## S2 exact-head ordinary CI

Ordinary PR CI [33398967580](https://github.com/Li-WithIce/claude-dev-harness/actions/runs/33398967580)
ran from 2026-08-31T13:48:12Z to 2026-08-31T14:06:52Z, attempt 1, and
completed successfully. All seven engineering jobs passed; release-host,
release-model and release-full were skipped by design. This is not a Release
Qualification pass and no workflow_dispatch or CI rerun was invoked.

The independently reviewed private inspector actually ran during
2026-08-31T14:10:24.3049071Z–2026-08-31T14:11:01.6150834Z, exit 0. It pinned the
repository, workflow id/path, PR/base, Head and attempt; matched all seven job
and artifact identities; checked API ZIP digests, strict UTF-8/Schema and raw
receipt digests; and rechecked the terminal run binding. No archive was
extracted. An earlier invocation returned read-only response unavailable,
exit 1, and produced no passing record; the later invocation used unchanged
inspector bytes. This retried metadata/artifact reading, not the CI run.

| Check | Job database id | Receipt raw SHA-256 |
|---|---|---|
| entry-lifecycle | 99510298209 | `903052825c45a025573b980794e255753ad7b87f1e8d844735a2efb91db8e7a4` |
| evaluation-release | 99510298125 | `566d802be2f31ef95a7a03735ba1e921c5d93a16c05adcd43cf81fabf50124d1` |
| install-evidence | 99510298223 | `51e6793f37899e15da662ac84ff0a1deaf4bcea56fe638fec35bc66f08eada92` |
| governance-approval | 99510298092 | `86129ab34b5b0fbc6970623d97894dca0af052b99a6e858df0860016ab3952ad` |
| harness-contracts | 99510298048 | `d7716cd39cbad86ce6373e1e98cc66c6a5e0997c29e170b7b7f81ad1d8cfa8a2` |
| core-rollback | 99515850987 | `3ad45a2008be269f98509ef436098bdd856fc624e98e0f49db7887b9c5b7fc0f` |
| changed-optional | 99510297744 | `c19c135bb421b8fd1a460045b3942cc708445761dd9c00636abca886240c2520` |

All receipts bind checkout/head
`2c5aad95c5141b24a083f95869b19221f04697c5`, base
`2e1949d7bcedc5397404d86a5ce95b51c8dde4a0`, PR 12 and attempt 1.
The exact archives and raw receipt text are represented in the private
`ci-source-S2-inspection.json` output with their SHA-256 values. This CI
observation is separate from the local Suite all aggregate recorded below.

## S2 exact-source terminal Suite all

The hardened tracked-source-only run `suite-all-20260831-214926` completed
during 2026-08-31T13:49:26.4780277Z–15:07:54.9249118Z, status pass, exit 0.
Source Head `2c5aad95c5141b24a083f95869b19221f04697c5` and tree
`12e996e668fa3aaffccf07dc887f133524e5a178` remained intact. The command was
`pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 600 -VerboseOutput`
inside the exact-carrier-source checkout, not the original working tree.

The closed stdout ends with `STATUS: PASS`. A strict outer-check/catalog
comparison found exactly 73 distinct active verifier passes and one Git diff
pass, with no missing, unexpected or duplicate verifier. Fourteen exact
Manifest-owned fixtures remain archived/not_run. The installed-only
`verify-installation.ps1` entry is one design skip in the no-argument loop;
isolated installation, presets, update and uninstall checks did execute.
Task-state reports `STATUS: PASS (142 checks, 1 unavailable)`: its dynamic
SUBST fixture was Host-blocked and not bypassed. Runtime/Memory decoupling
separately reports 35 checks, 0 unavailable. These counts are not conflated.

Result JSON raw SHA-256:
`b98b89295c89fc41033e4ff3bb210bb29e077920f22b0df95f663428ca2a6cff`.
Stdout raw SHA-256:
`df29c95bc65795a117c19629c96dd62694456a25ef53d3e4d68935a783ee498f`.
Stderr raw SHA-256:
`8bb15db2509d730f181d0dbb68f14ea65e6f2312fc6bc1f553ba044b8f5eb339`.
Stderr is not empty: it contains three Git LF-to-CRLF warnings, two for the
fixture `.gitignore` and one for `source.txt`, and no other lines.

The bounded read-only aggregate inspector rechecked all raw digests, the
closed result, final line and exact source catalog membership during
15:13:48.7418578Z–15:13:49.1809999Z, exit 0. Its private output is
`suite-all-source-S2-inspection.json`, raw SHA-256
`586495eff16f554d891fb62a86b49e6fe837084c330f8769893bac81c504e10c`.
The inspector script raw SHA-256 is
`813ba798aafee7a66318f82c7259618d4c67c356a45116d12a4c2a728a42f9c0`.
An earlier one-shot read-only inspection returned exit 1 without output and
does not supply evidence. The file-backed inspection then passed; rereading
closed logs did not rerun validation. No live Qualification, default flip,
Promotion, Canary, Stable or physical removal was performed by this suite.

## Completion boundary

Terminal Suite all, final exact-head ordinary CI, final independent audit and
current ten-gate matrix are recorded separately when executed. An individual
verifier pass is not a Suite all pass. Archived tests are `not_run`; the
installed-only verifier is a design skip unless explicitly supplied an
isolated Workspace. No archived or missing check counts as passed.
