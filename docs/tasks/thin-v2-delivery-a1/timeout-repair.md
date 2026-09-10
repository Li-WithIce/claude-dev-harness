# DELIVERY-A1 bounded validation-timeout repair

## Authorization and boundary

The user explicitly authorized fixing the failed Windows PowerShell quick-validation probe while preserving the existing budgets and assertions and making no Runtime source changes. This is an amendment to DELIVERY-A1, not a reopening of TK-07 or authorization for later delivery stages.

The bridge retains its 90-second outer budget, its 30-second check budget, and all three success conditions. Full Validation configuration, Release producer bodies, Runtime/K0, public exports, Schemas, historical digest algorithms, installation and rollout behavior are unchanged. `Harness.ModuleManifest.psm1` is classified as C2 `engineering-validation`, outside Runtime TCB.

## Diagnosis and repair

At pre-repair Head `818a9663cf4c0516e9996da8be16522e257e7ac6`, the owner verifier failed. An isolated bridge reproduction timed out at 90.05 seconds with no output. Direct pwsh quick subsequently passed in 65.07 seconds, and a Windows PowerShell bridge diagnostic passed in 87.77 seconds. This variability is retained; the last pass alone was not treated as a repair.

Catalog construction previously launched a separate `git show` process for each of 178 package files, in addition to per-file index-flag and worktree comparisons. The repair replaces those 178 blob-reader processes with seven package-scoped `git cat-file --batch` readers. Each file still receives its own flag and worktree comparison immediately before reading. Stage-zero immutable object IDs are obtained with the flag query and sent to the batch reader; long-lived `:path` index lookup caching is not used.

The reader validates a bounded ASCII blob header, reads the exact declared raw byte count and frame terminator, rejects trailing output, checks Git's exit status, and stops its owned process on exceptional exit. Raw SHA-256 and catalog serialization remain the existing implementations. The bridge verifier now reports exit code, timeout, duration and stream lengths on failure without disclosing stream content.

## Bounded precommit checks

- Final reader against the unchanged prior-Head Git-only source: both generated catalogs matched every tracked byte, all 178 file bindings retained; 37.81 seconds. This is cross-version byte-equivalence evidence, not new-Head acceptance.
- Eight existing index-flag cases retained and passed: clean, plain edit, assume-unchanged clean/edit, skip-worktree clean/edit, CRLF equivalence and unrelated hidden flags. Every case preserved its fixture snapshot.
- The three accepted cases also verified five raw blob forms: empty, UTF-8 BOM, binary bytes including frame-like text, UTF-8 text, and a 65,537-byte multi-buffer body, in a Unicode/space workspace.
- Four changed PowerShell files parsed; diff whitespace checks passed. Runtime Kernel, Schema and Full Validation path comparisons showed no change.
- Earlier experimental fixture attempts failed because their package paths violated the existing restricted path syntax. Those local failed artifacts remain preserved; neither the Schema nor its assertions was relaxed. The final fixture uses valid portable relative paths.

## Self-review and remaining acceptance

Bounded self-review covered framing, immutable-object addressing, startup/exception cleanup, unchanged hidden-index rejection, byte-hash parity, and the original bridge assertions and budgets. No unresolved finding was identified in this repair diff. This is an A1 self-review, not a new independent audit of sealed TK-07.

These precommit checks do not complete A1. The exact new committed Head still requires the prescribed owner checks, complete Suite all, a cumulative Draft PR, and terminal ordinary PR CI with current raw receipts. Historical failures remain failures. No push, PR, merge, installation, deletion, dispatch, Qualification, Promotion, Canary or Stable is claimed by this note.

All PowerShell sources, fixtures and scratch paths are beneath `D:/data/dev-harness-next`. Validation sources come from Git objects; the original workspace is not copied and real `.qoder` is excluded. Prior native failure Evidence is retained byte-for-byte separately from the amended contract.
