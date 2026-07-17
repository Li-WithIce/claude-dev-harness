# Thin Harness v2 task state

## Purpose and truth source

Durable Governed and Critical work uses `task-state/v2`. The canonical task document is the only lifecycle truth source; events, Evidence, Approval, audit, current pointer, and recovery index are bound records or derived views, not parallel state.

Direct and Inspect work do not create this layout. Existing v1 `plan.md` tasks continue through the five-stage workflow and are never converted implicitly.

## Workspace layout

```text
.assistant/runtime/
  current.json
  locks/
    step_<target-digest>.json
  failed-writes/
    txn_<transaction-id>.json
    archive/
      txn_<transaction-id>.json
  tasks/<task-id>/
    task.json
    events.jsonl
```

Task Evidence and Approval are published at their canonical workspace-contained paths. Pending transaction journals live under `failed-writes`; a normal writer publishes a `committed` archive and repair publishes a `recovered` archive. These archives are durable commit markers, not business inbox or Memory records.

Migration may stage `.migration-<task-id>-<32 lowercase hex>` below the tasks directory. Recovery ignores and preserves only that strict internal form. Other unknown directories remain fail-closed, and no recovery read deletes residual data.

## Lifecycle

The legal statuses are:

`blocked | ready | running | verifying | paused | done | failed | cancelled`

The transition table is implemented once in `Harness.TaskState.psm1`:

- blocked -> ready after a revised Requirement Contract;
- ready -> running or cancelled;
- running -> verifying, blocked, failed, or paused;
- verifying -> done, running, paused, or failed;
- paused -> running, verifying, or cancelled;
- failed -> running;
- done and cancelled are terminal.

Generic transition cannot claim `done`. Completion requires canonical Evidence and, when policy requires it, current Approval and governance artifacts. An active task clears `current.json` when it reaches done or cancelled.

## Concurrency and atomicity

Every mutation requires `ExpectedVersion`. On Windows the per-task mutex identity is derived from the workspace directory's physical volume and file identity, so drive-letter, SUBST, and volume-GUID spellings of one ordinary workspace share a lock. A `WorkspaceRoot` whose own path or physical SUBST target contains a junction, symlink, folder mount, or other reparse point is unsupported and fails closed. Non-Windows durable task-state mutation is unsupported and fails closed because no stable cross-alias physical identity contract is implemented. A stale version, illegal transition, occupied current pointer, pending transaction or publication claim, unavailable physical identity, path escape, or malformed record fails before publication.

A mutation is expressed as a bounded, operation-specific journal of contained write/delete steps. Every pending journal reserves the whole transaction target set, including steps that have not acquired a claim. Before checking a step preimage, the transaction atomically creates a durable claim keyed by its target path and bound to the task, immutable transaction intent, step, and expected digests. Only that transaction may publish. Whole-transaction claims remain until every postcondition is verified and a `committed` or `recovered` archive exists; completed-step claims are not released early.

The journal binds its operation, task id, real integer ExpectedVersion, physical `workspace_identity`, timestamp, exact step order, paths, actions, strict UTF-8 payloads, and pre/post digests in one immutable intent digest. Its single-quoted `replay_command` is grammar-checked as data, not executed from the journal. Exact-key `operation_context` binds normalized `approval_input_path` or `evidence_input_path` where applicable and always binds `pointer_action`. A current task therefore cannot omit its current-pointer update or clear, and transition, Approval, and Evidence pointer updates preserve the original `activated_at`.

Non-create task and current-pointer steps carry strict UTF-8 embedded preimages. Validation enforces operation-specific task delta allowlists, an exact event-log preimage prefix, task/version-bound Evidence and Approval, and an exact ordered prefix for journal progress. Replay re-resolves the Requirement Contract and original Approval or Evidence input, rechecks record digests and governance, and compares the resolved canonical content to the immutable journal. After the durable journal exists, the normal writer performs the same live validation immediately before its first publication claim, so Contract, Approval, Evidence, governance, and current-pointer drift cannot create a normal/replay semantic split. Claim-free replay uses current Approval expiry and live Evidence revision. Only after an own publication claim proves that publication began is expiry evaluated at the journal authorization timestamp and Evidence revision pinned to the journal snapshot; later clock or unrelated workspace drift cannot strand an authorized partial transaction. On Windows, Evidence invokes Git through a verified drive-letter spelling and binds dirty revision to physical workspace identity, so drive, SUBST, volume-GUID, and case-only spellings of the same supported workspace converge. Live current-pointer state must match either the recorded preimage or postimage replay boundary. Both replay modes retain all other input checks; a claim is publication ownership evidence, not a general authorization bypass.

The normal writer verifies every postcondition, writes the `committed` archive as the durable commit marker, removes only its own claims, and then removes the pending journal. Repair requires claims to form the completed prefix plus at most the first unfinished in-flight step; an own claim later in the suffix is invalid and cannot grant snapshot authorization. Repair validates every completed-prefix own claim and postimage, publishes remaining steps, verifies the complete postimage set, writes a `recovered` archive, removes its own claims, and then removes pending state. If pending and its matching archive coexist, repair treats this as interrupted cleanup: it verifies and removes only matching own claims; any foreign claim remains untouched. Archive-only replay fails closed if an own claim remains but ignores a later foreign claim. A pending journal that disappears without a matching archive fails closed; completion is never inferred or synthesized from target postimages.

A fault records a workspace-bound transaction id. `task.ps1 replay` is idempotent. If replay waits behind a normal writer, the writer's existing commit marker is the convergence proof; replay never creates a replacement archive from observation alone. Unknown or tampered journal paths, identity, intent, progress, payloads, preimages, claims, and archive relationships are rejected.

Pending journals created by the immediately preceding v2 implementation use the exact historical 11-key journal and 6-key step shape. Replay recognizes only that complete legacy shape, validates its operation-specific payloads and ordered progress, derives a domain-separated physical-workspace intent, and then uses the current mutex, target claims, CAS progress writes, archive marker, and cleanup order. It preserves the legacy shape in its archive and remains idempotent; it does not rewrite or silently upgrade the pending record. Current-format top-level fields mixed with legacy steps, legacy fields mixed with current steps, extra keys, and unknown shapes fail closed. This narrow recovery seam exists only so an upgrade cannot strand an already pending transaction; all new writers emit the current format.

The current pointer is optional and singular. Background tasks do not steal it. Resume is read-only; only explicit `resume-and-execute -TaskId ... -ExpectedVersion ...` can mutate state and activate a resumable task.

## Evidence, Approval, and governance

- `evidence/v1` binds task id/version, Requirement Contract digest, the full current commit or a dirty digest, command exit codes, records, coverage, and conclusion. Unsafe Git index flags fail closed instead of hiding tracked changes.
- pass plus nonzero exit, stale digest/revision, path escape, or incomplete coverage cannot complete a task.
- Approval binds the exact task version, contract digest, type, scope, approver, time, expiry, and status. Scope or version change makes it stale.
- Required audit binds implementer/reviewer actor and context plus the Evidence digest. A pass audit cannot contain a P0/P1 blocking finding.

These records are prerequisites to a state transition; they never overwrite `task.json` as a second truth source.

## Read and recovery behavior

`task.ps1 status` and bare `resume` are zero-write. The recovery index enumerates nonterminal tasks, validates the pointer against a live task/version, and reports pending failed-write journals. Terminal tasks are counted but not resumable.

Memory and Team are optional consumers. Core recovery works from the runtime task documents alone and does not require Obsidian, an inbox, provider indexes, or prompt injection.

## Compatibility, validation, and rollback

Protocol detection is artifact-first: an existing v2 `task.json` stays v2; a legal v1 `plan.md` stays v1. Explicit protocol conflicts fail closed. Migration uses dry-run digest checks and atomic directory publication, preserves the v1 artifact read-only, and never deletes v2 data to perform rollback.

`tests/verify-v2-task-state.ps1`, `tests/verify-v2-evidence.ps1`, `tests/verify-v2-approval.ps1`, `tests/verify-v2-governed-audit.ps1`, `tests/verify-v2-runtime-memory-decoupling.ps1`, and migration/coexistence tests cover these contracts.

Rollback sets `HARNESS_PROTOCOL=v1` for new work or reverts the relevant implementation commit. Existing v2 runtime remains available for read-only diagnosis and explicit recovery; existing v1 tasks, installation, update, uninstall, recovery, and validation remain intact.
