# Governed Plan

- task_id: thin-trust-kernel-tk07-kernel-compression
- contract_digest: sha256:5cb7bcd8bc1bb975e08ede7e10e12cca1033cfac1644d709c5beabd978779f49

## Goal

Starting from PR #12 exact Head `3d9fc13e0cb54f022b33f290b86ec1d6d239f1ba`, reduce the honestly measured Runtime transitive executable TCB from 6075 lines to fewer than 3000 lines. Preserve K0 semantics, public APIs, Schema and Envelope contracts, historical bytes and digests, and observable v2 behavior. Deliver the work as an independently reviewable stacked Draft PR with terminal `Suite all` and exact-head ordinary CI evidence; do not claim or perform release qualification or rollout.

## Scope

- In scope: the tracked Runtime root closure, its explicit dependency graph, the Thin Trust Kernel ownership/classification/TCB artifacts, focused compatibility tests, and architecture documentation needed to explain the compressed implementation.
- Preserve the four K0 contracts: hashing, `canonical-json/v1`, path containment, and atomic/CAS publication. Preserve existing task, Requirement, Policy, Approval, Evidence, recovery, admission, controlled-write, CLI, module-export, Schema, Envelope, adapter, and CoreGroup contracts.
- The reduction must come from deleting duplication and simplifying implementation inside the counted Runtime closure. Moving code to excluded layers, generated or compressed executable source, physical line packing, dynamic loading, hidden facades, omitted dependency edges, and misleading classification are prohibited.
- Keep all nine adapters below their existing 200-line limit, preserve entry limits and trust-direction rules, and leave historical receipts, Evidence, bytes, and digests unchanged.
- Excluded: TK-03 physical deletion, Qualification, Promotion, automatic default flip, Canary, Stable, readiness claims, real installation, `workflow_dispatch`, merge, shared-pointer mutation, and execution of unrelated paused tasks.

## Implementation

1. Freeze a machine-readable baseline of Runtime roots, import edges, file classifications, public module exports, CLI surfaces, Schemas, historical digest fixtures, CoreGroup identities, adapter inventory, and the 6075-line TCB result.
2. Add characterization tests before changing behavior. Cover successful and rejected Requirement/task/Approval/Evidence flows, zero-write failures, CAS and concurrency conflicts, interrupted transaction recovery, legacy journal recovery, adapter delegation, and byte-stable digest outputs.
3. Consolidate repeated strict JSON, exact-key, Schema, and validation mechanics only where the shared implementation remains in the counted Runtime closure and produces a net line reduction. New helpers are private implementation details and must not acquire new authority or public exports.
4. Replace duplicated TaskState journal validation and replay branches with declarative shared mechanics while retaining current transaction schemas, allowed transitions, mutex/CAS behavior, crash boundaries, recovery behavior, events, task versions, and current-pointer rules.
5. Simplify the remaining Requirement, Policy, Protocol, RuntimeDefault, Evidence, Approval, Recovery, Governance, HostCapabilities, ControlledWrite, AdapterAction, CLI, and hook code by deleting duplicated mechanics and dead scaffolding without weakening fail-closed validation.
6. After each bounded wave, regenerate classification, source catalog, adapter inventory, roots, and TCB artifacts from tracked source. Reject any change that reduces the reported number without reducing the real executable closure, or that introduces an unresolved or reverse trust edge.
7. Keep changes in normal, reviewable commits on `codex/thin-trust-kernel-tk07-kernel-compression`; do not amend, rebase, force-push, merge, or disturb the source PR branch.

## Verification

- Compare the final public-export and CLI snapshot to the exact-head baseline; verify Schema identifiers, Envelope versions, CoreGroup identities, adapter set, and K0 digests remain unchanged.
- Run focused positive, negative, rollback, concurrency/CAS, crash-recovery, invalid-input, and zero-write suites for every touched Runtime contract.
- Run all affected owner tests and CoreGroups, then regenerate derived artifacts and run their byte-stable `Check` modes.
- Require `unresolved_dependencies = 0`, honest Runtime executable LOC `< 3000`, no budget exception, no prohibited evasion pattern, all adapters `< 200`, and all entry limits satisfied.
- Perform one bounded diff/self-review plus independent different-actor dry-run and audit. Record `pass`, `skipped`, `not_run`, `unavailable`, and failure distinctly.
- In a tracked-source-only isolated project-local copy, run terminal `Suite all`; after normal commits, run ordinary exact-head CI and retain exact commit/run receipts. These checks do not constitute Qualification or release-stage evidence.

## Rollback

- Each implementation wave is independently revertible with a normal revert commit. Never use reset, stash, clean, rebase, amend, or force-push to roll back.
- If a compatibility, trust-boundary, or TCB-integrity check fails, stop publication, preserve the journal/evidence needed to diagnose it, and revert only the offending wave.
- Rollback must preserve task state history, shared pointers, source-branch state, historical Schemas, receipts, Evidence, bytes, and digests. Invalid or incomplete recovery remains fail-closed and zero-write.
