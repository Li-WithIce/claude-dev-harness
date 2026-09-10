# Governed Plan

- task_id: thin-trust-kernel-tk03-v1-sunset
- contract_digest: sha256:ce1073dd8d58d873a7c3b6b199e3f05d3ba3d40076580fc93f6d2c881b85bfbe

## Goal

Implement the user-confirmed TK-03 v2-only transition from PR #11 Head
`2e1949d7bcedc5397404d86a5ce95b51c8dde4a0`. Replace the former Stable-before-v1-
retirement dependency with current Sunset evidence, verified v2 stop-loss and
recovery, and a separately approved exact physical-removal diff. Physical
removal and full Sunset completion remain pending that final approval.

## Scope

The Requirement Contract is clear. `breaking_public_api_change` selects
Critical even though the source work is local and reversible. All six task
policies are required: plan, Approval, rollback, independent review, verification,
and dry-run. Current user confirmation is the product/architecture authority;
it does not mean that any Release gate passed.

The user separately authorized releasing the old v1 current pointer for
`dp-03-real-qualification` and migrating that task only to v2 `paused`. Preserve
its original plan and Evidence, both DONE v1 histories, and the existing v2
current pointer. Do not execute Qualification or advance the migrated task.

The source scope covers protocol/config/default admission, entry, migration,
distribution profiles, ordinary status/recovery, ownership and tests, the
corresponding architecture change and generated inventories. No TK-07,
Qualification/dispatch, Promotion, Auto Flip, Canary, Stable, real installation,
Ready/merge, history rewriting, or actual `.qoder` access is authorized.

## Implementation

1. Preserve the exact old pointer preimage and old task-file digests. Require
   matching task id, stage, entry host, Contract, Approval, source Head, and
   expected digests. Preview the named operation independently. Under the
   existing v1 plan/runtime locks, use the canonical idle-pointer renderer and
   K0 atomic CAS to release only that pointer. Run the existing migrator's
   dry-run, review its exact digest, then perform its native paused v2 import.
   On failure, restore only the matching pointer postimage and only if the v2
   import was not published; never delete a v2 task to reactivate v1.
2. Publish an explicit Architecture Change Contract. Preserve old Release
   schemas, receipts, digests and recorded outcomes; supersede the active
   retirement prerequisite explicitly, without inventing new Release passes.
3. Converge ordinary new-task/auto selection on v2; reject retired v1 requests
   without implicit migration. Retain existing-v2 artifact precedence and
   strict invalid-input rejection. Implement stop-new-work and v2 recovery
   instead of routing rollback into v1; preserve historic config/data bytes.
4. Isolate retained migration/history readers from ordinary Runtime. Remove
   v1 routing from generated entry contracts and remove active legacy assets
   from desired install profiles. Preserve foreign data, transaction safety,
   history-based uninstall and the separate physical-removal approval gate.
5. Update owner tests, manifest-derived routing and generated source/TCB
   inventories. Keep historical compatibility data labelled as historical,
   never count an archived/inactive test as an executed pass, and do not add a
   second central routing catalog.
6. Run focused checks, independent dry-run, bounded review and terminal full
   validation in a tracked-source-only checkout under the fixed project root.
   Deliver ordinary commits and a stacked Draft PR, exact-head CI receipts and
   a truthful V1S-01..V1S-10 matrix. Keep the task open at any outstanding
   deletion/ownership/verification gate rather than weakening completion.

## Verification

Bind each result to the exact source revision, task version and Contract.
Critical Approval, dry-run and actual execution must bind the same protected
operation identity for the operation being verified. Use a real different
executor/context for the required dry-run and a real different-actor read-only
audit; do not self-author another actor's receipt.

- Migration: original current-pointer digest and task history unchanged except
  the authorized pointer; native migration source/dry-run digest match; target
  `paused`; no Qualification execution; existing v2 current byte-identical.
- Protocol: new/auto/config/environment matrix, v1 rejection, pause/recovery,
  existing-v2 precedence, invalid/missing/drifted inputs and zero-write errors.
- Distribution/entry: fresh core/governed/full and isolated update/uninstall,
  no active v1 assets, source ownership, unknown drift, rollback and foreign-
  data preservation; generated entry/TCB/catalog byte checks.
- Engineering: AST/BOM/diff checks, focused owner tests, quick, terminal
  isolated Suite all, ordinary exact-head CI and all required receipts.
- Evidence: retain failures and interrupted attempts; distinguish pass,
  skipped, unavailable and not_run; physical deletion remains not_run until
  the exact diff receives separate approval.

Every `.ps1` and fixture stays under `D:/data/dev-harness-next`. Never run a
recursive source-copy/snapshot Suite against the original worktree containing
actual `.qoder`; use an exact tracked-source checkout and explicit temp roots.

## Rollback

Pointer release is a compare-and-swap mutation of one explicitly named file.
Keep its original raw bytes in this task's private validation evidence. If
migration fails before publishing the v2 task, restore that preimage only when
the pointer still matches this operation's postimage. If either identity has
changed, stop and retain recovery evidence; do not overwrite concurrent work.
After successful publication, preserve the v2 task as paused and preserve the
old v1 plan as immutable migration history. Never delete v2 state to revive v1.

Source work stays on `codex/thin-trust-kernel-tk03-v1-sunset`. Use subsequent
ordinary corrective commits; do not reset, stash, clean, rebase, amend or force-
push. Runtime stop-loss stops new work and uses v2 recovery or an explicitly
approved known-good v2 distribution; it does not select v1. No live installer
or Release publication is performed. Fixture cleanup is limited to task-owned,
verified contained paths and never retries a host-denied operation by bypass.
