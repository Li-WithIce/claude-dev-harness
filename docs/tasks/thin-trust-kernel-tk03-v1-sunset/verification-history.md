# TK-03 validation history

All runs below used a tracked-source-only isolated checkout under
`D:/data/dev-harness-next/tmp/tk03-validation/source`. These are local snapshot
commits, not the final PR Head. PowerShell fixtures stayed under the fixed
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

## Completion boundary

Terminal Suite all, final exact-head ordinary CI, final independent audit and
current ten-gate matrix are recorded separately when executed. An individual
verifier pass is not a Suite all pass. Archived tests are `not_run`; the
installed-only verifier is a design skip unless explicitly supplied an
isolated Workspace. No archived or missing check counts as passed.
