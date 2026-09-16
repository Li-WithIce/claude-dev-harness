# I01 local integration baseline

The first integration commit records one verified tree, without reconstructing fictional H01-H04 commits:

- Historical parent: `746caadd8057e16b2fa90907a564242f9391ed9e`.
- Integration baseline commit: `21dc2f15168fa9f001f031704ef9fbc06b1daee7`.
- Exact deployed/baseline tree: `69933739c74a9b0876d610e93f7e823aeeb0c33a`.
- All 515 approved working files were compared by SHA-256 and type before that commit. BOM and working-file newline bytes were preserved; Git's existing text normalization remains unchanged.
- This document is a separate follow-up commit. It changes the final tree without changing the integrated implementation. The external I01 receipt records final commit/tree, raw-file identities, commands and local evidence locations.

## Included changes

| Repair | Included scope | Historical evidence identifier |
|---|---|---|
| H01 | Optional Requirement arrays default correctly; corresponding owner regression | H01 patch SHA-256 `EE3B4C7BC459115B66CB0F5633BB5F1313E256AA36B3D01C238C537E22A8E7B7` |
| H02 | Direct patch relative/contained Windows absolute paths share authorization; finite sanitized refusal categories; owner tests and contract changes | H02 closeout, budget approval and UNC fixture records; final H02 tree `e68a3aceb9a601f78100a40903dfe21847863185` |
| H03 | Historical manifest lexical identity does not require the old PSDrive to exist; integrity checks remain | H03 report and tree `82ef665ed4763fb780630d74eb3d82c9a0aac29c` |
| H04 | Retain other valid owners' shared Hook files and references; target feature ownership remains local to its request; installation regressions | H04 report; final tree `69933739c74a9b0876d610e93f7e823aeeb0c33a`; patch SHA-256 `F472E830147289FF74C523AB2AA17C7B14774CA4948BAEA92C4398A12183863A` |

Approved Runtime budget remains baseline 3068 LOC with explicit exceptions of +10 (KTB-EX-002), +2 (H01), and +61 (H02). Strict total limit is <3142; observed Runtime is 3141 LOC, 35575 tokens and 10498 statement ASTs. Token/AST checkpoints are 35575/10498. Growth against historical HEAD was +63 LOC, +223 tokens and +96 ASTs; checkpoint growth was +147 tokens and +96 ASTs because the prior token checkpoint already had 76 tokens of headroom. The original +10 correctness allowance and all review conditions remain in `kernel-tcb-roots.json`. No measurement, dependency, readability, safety or timeout rule changed in I01.

## Daily checkout changes not imported

The daily HEAD still matches the historical parent. Its five unstaged files, empty staged diff and absence of untracked files were observed, not cleaned or merged.

| Daily file/hunk | Attribution and disposition |
|---|---|
| `scripts/lib/Harness.Requirement.psm1` and `tests/verify-v2-requirement-gate.ps1` | Byte-identical to the included H01 versions. Already included; never apply twice. |
| `install.ps1`: historical workspace vault identity | Equivalent H03 path-string combination, with different spelling/comments. The deployed variant is the baseline; daily comments are not imported. |
| `install.ps1`: shared Profile selection, global rendering and Skill synchronization | Additional daily work, overlapping H04 installation flow. Excluded pending separate review. |
| `scripts/install-transaction-common.ps1`: `Get-SharedInstallPreset` | Independent daily helper absent from the deployed tree. It ranks presets, restricts owners to the same source and skips inaccessible workspace directories. This conflicts semantically with H04's explicit ownership and offline-owner retention rules; not an approved replacement for H04. |
| `tests/verify-installation.ps1`: shared preset expectations | Additional daily validation approach overlapping H04's shared-set verification. Excluded; it must not be combined blindly with the new verifier. |

These are content-based attributions, not claims about authorship or completion of that independent work. The exact daily patch and file/hunk disposition are preserved outside the repository. The daily checkout has not been merged by I01.

## Validation and evidence boundaries

I01 uses the existing generators in check mode, Runtime inventory owner and quick on the new copy. Actual commands, exit codes and any failures belong to the external I01 receipt. No old result is relabeled as a new run, and no test is weakened to accept this baseline. A local commit is not a deployment or release.

Historical B01-B06 reports remain separate. B02 was originally blocked and its assisted retest retained an extra newline change. B03-R2 failed a date boundary; R3's sample-only repair passed its focused checks. B04 has missing-output limits. B05 has three-stage persistent recovery evidence. B06's control ran in the coordinator task, the protected conversation used the wrong workspace, and no protected tool call was submitted. Thus actual protected Hook execution/refusal remains unverified. These sample changes, configuration values, task state and chat transcripts are not included here.

Known shared Skills behavior remains unresolved: same-source full/core installation can remove optional Skill links or cause strict core verification mismatches. H04 repaired shared Hooks, not this Skills mechanism. No valid A/B comparison establishes speed, quality or statistical superiority. Historical failures and unknown configuration changes are not erased by this integration.

Future I02/I03 work should start from this independent integration repository and its recorded final commit. Keep the deployed checkout stable; do not deploy, repair Skills, ingest daily changes or reinterpret safety evidence without the next explicit scope.
