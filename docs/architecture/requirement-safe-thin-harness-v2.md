# Requirement-Safe Thin Harness v2

## Status and rollout boundary

This document defines the machine-readable contracts introduced by PR-01 and implemented incrementally through PR-14.

- PR-00 through PR-03 keep v1 as the only default runtime.
- PR-04 through PR-13 expose v2 only through explicit opt-in.
- PR-14 keeps `auto` artifact-first and consumes only a strict `harness-runtime-default/v1` decision after explicit/workspace preferences; missing, invalid, expired, source-drifted, workspace-mismatched, or capability-incompatible decisions select v1 with a runtime reason. Release Gate reports remain outside Runtime Core.
- Existing v1 tasks continue to use the current five-stage files and scripts throughout this refactor.

Schema or policy load failure never grants permission. Read-only inspection may continue when policy infrastructure is unavailable, but protected writes fail closed.

## Authority and Requirement Gate

Product intent is resolved in this order:

1. the current user instruction and current-turn confirmation;
2. an approved source explicitly referenced by the user;
3. project product decisions;
4. project architecture decisions;
5. current code, public interfaces, and tests;
6. engineering conventions.

Lower sources can fill only decisions they own and cannot override a higher source. Peer approved sources that disagree are blocking. Current requirements supersede legacy tests when they conflict.

`policies/decision-rights.json` divides decisions into `product`, `architecture`, and `agent`. Unknown categories resolve to `product`. Agent-owned choices remain constrained to reversible, behavior-equivalent, convention-following, verified engineering details.

The Requirement Contract contains product truth only: goal, acceptance, scope, constraints, confirmed decisions, unresolved product decisions, source authority, and a digest. Paths to edit, tool selection, model selection, review actors, runtime pointers, and verification results are execution concerns and do not belong in that contract.

## Risk and execution profiles

`policies/risk-rules.json` scores seven dimensions from 0 through 3. Scores 0–4 select Direct, 5–8 select Governed, and 9–21 select Critical unless a hard trigger overrides the total. Requirement-blocked work does not receive an execution profile. Read-only intent selects Inspect. Durable work is at least Governed. File count alone never escalates a task.

`policies/execution-profiles.json` defines four profiles only:

| Profile | Default persistence | Machine writes | Minimum capabilities |
|---|---|---|---|
| Inspect | ephemeral | none | deterministic verification appropriate to the inspection |
| Direct | ephemeral | no task state or task artifacts | verification |
| Governed | durable | task state and explicit artifacts | verification and durable evidence; other capabilities are policy-composed |
| Critical | durable | task state and explicit artifacts | plan, approval, rollback, independent review, verification, durable evidence, and dry-run |

Ask is not a fifth profile. It is `requirement_state=blocked`. Legacy `quick` and `workflow` names map to Direct and Governed only as compatibility aliases.

`policies/protected-actions.json` contains hard escalation rules. A match raises requirements; it never declares a command or path safe. PR-01 records only the two plan-defined rules. Detection and approval enforcement arrive in later PRs.

Ordinary configuration persistence is a general Runtime capability. Once the user explicitly authorizes and names a Workspace configuration file, database credentials and external-service keys may be written there, including production configuration, without depending on exact model/Host versions, Release Qualification, Vault, KMS, or a Secret Provider. File adapters send target paths to Core Policy and never classify file bodies as command text; Bash continues to send actual command text. Persistence does not authorize disclosure in replies, logs, task artifacts, Evidence, reviews, PRs, CI artifacts, snapshots, documentation, or unrelated files, and it does not bypass read-only sessions, Workspace containment, protected paths, OS permissions, enterprise endpoint policy, or real production-command governance.

## Canonical JSON contracts

PR-01 owns exactly these five JSON Schemas:

| File | Required `schema_version` | Purpose |
|---|---|---|
| `schemas/requirement-contract.schema.json` | `requirement-contract/v1` | frozen product requirement |
| `schemas/task-state.schema.json` | `task-state/v2` | durable v2 task state |
| `schemas/event.schema.json` | `event/v1` | append-only task event |
| `schemas/evidence.schema.json` | `evidence/v1` | revision-bound verification evidence |
| `schemas/approval.schema.json` | `approval/v1` | scope- and contract-bound approval |

`task/v2` and `evidence/v2` are not valid aliases. `current-pointer/v1` remains a canonical future contract, but its schema and runtime behavior belong to PR-05 and are intentionally absent here. Risk and execution-profile files are repository policies, not newly versioned public protocols.

Every top-level schema rejects unknown properties. Fixed nested objects do the same. `event.payload` is the sole deliberate extension boundary in PR-01 because payload shapes depend on event type and are implemented later.

## Task state

The canonical lifecycle values are:

`blocked | ready | running | verifying | paused | done | failed | cancelled`

Task state records identity, intent, requirement state, execution profile, persistence, capability flags, and optimistic version. Optional contract, approval, and evidence references are structural placeholders only. Transition guards, CAS, atomic writes, event transactions, and current-pointer behavior are PR-05 responsibilities; PR-01 does not perform or authorize state changes.

## Evidence and Approval

The detailed Evidence model is the later `records/coverage/conclusion` model, not the earlier illustrative `checks/acceptance` shape. `gaps` is an optional list for explicit omission reasons. It does not create a second coverage truth source. A `pass` document must have empty `not_verified` and `blocked` coverage arrays; PR-06 adds full evidence semantics and workspace containment enforcement.

Approval binds task id, task version, Requirement Contract digest, approval type, scope, approver, time, expiry, and status. PR-01 validates shape only. Grant, invalidation, expiry, protected-action matching, and actor independence are PR-08 responsibilities.

## Validation and change discipline

`tests/fixtures/v2/policy-contract-cases.json` contains one valid and one invalid document for every PR-01 schema. `tests/verify-v2-policy-contracts.ps1` validates schemas, fixtures, exact policy keys, category ownership, score bands, profile minimums, protected rules, and malformed-input fail-closed behavior.

Changes to a schema or policy require a corresponding behavior fixture. Prompt text may explain a rule but cannot loosen these files. At the PR-01 boundary the definitions were inert; later PRs consume them only through the gated, compatibility-preserving paths documented here.
