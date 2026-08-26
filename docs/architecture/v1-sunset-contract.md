# v1 Sunset Contract

## Status

This contract defines evidence required before v1 Runtime compatibility may be
removed. TK-00 does not execute Sunset. A date, milestone name, or the fact that
all gates pass is not deletion authority; the user must separately authorize
the exact removal diff after every gate is current-head `met`.

Statuses are `not_met`, `partial`, or `met`. The current TK-00 observations are
deliberately conservative and must be regenerated when Sunset is proposed.

## Gates

| ID | Requirement | Machine evidence | Human evidence | Failure meaning | Removal unlocked | Current status |
|---|---|---|---|---|---|---|
| V1S-01 | New task creation defaults only to v2. | Protocol/config tests prove every artifact-free default creates v2 and no new v1 artifact. | Product owner confirms no supported new-task v1 default remains. | New work can still enter v1. | Remove new-task v1 creation. | partial |
| V1S-02 | Every active task is v2. | Read-only recovery inventory reports zero active v1 task or plan. | Owners confirm no active external workflow depends on an unobserved v1 task. | Deletion can strand active work. | Remove active v1 task reads. | not_met |
| V1S-03 | Every migratable v1 task is migrated or explicitly archived. | Migration inventory binds each v1 id to a v2 task or archive decision. | Task owners accept every archive and unresolved task disposition. | Historical live state is ambiguous. | Remove migratable v1 state writers. | not_met |
| V1S-04 | `auto` never resolves to v1. | Protocol tests prove config and Runtime Default paths have no v1 fallback. | Product owner accepts the changed rollback model. | Artifact-free or invalid Runtime input can still select v1. | Remove auto-to-v1 branches. | not_met |
| V1S-05 | Runtime Default cannot output or imply v1. | Strict Runtime Default Schema and verifier reject v1 and fallback decisions. | Release owner approves the replacement rollback control. | Runtime publication still relies on v1 fallback. | Remove Runtime Default v1 handling. | partial |
| V1S-06 | Entry Contract contains no v1 routing. | Generated Entry Contract and drift verifier contain no active v1 route or shim load. | Host owners confirm every supported adapter follows v2-only entry. | Host prose can still route to v1. | Remove v1 Entry Contract prose. | not_met |
| V1S-07 | Distribution installs no v1 shim or lifecycle asset. | Clean install/update manifests contain zero active v1 entry-router, orchestrator, stage, or plan asset. | Distribution owner accepts rollback and upgrade behavior. | New or updated Workspaces still receive v1. | Remove v1 install assets. | not_met |
| V1S-08 | Status and recovery read no v1 runtime or plan state. | AST/import and behavioral tests prove v2-only status/recovery with zero v1 file reads. | Operations owner accepts loss of v1 recovery. | Status deletion can hide recoverable v1 work. | Remove v1 status and recovery readers. | not_met |
| V1S-09 | Active validation and changed-path routing contain no v1 Runtime test. | CI inventory classifies any retained v1 fixture as archive/compatibility only and runs no active v1 Runtime route. | Test owner approves the archived compatibility boundary. | CI still protects active v1 behavior. | Remove active v1 Runtime verifiers and routes. | not_met |
| V1S-10 | `migrate-task-v1-to-v2.ps1` has completed its last compatibility mission. | Zero eligible v1 tasks remain and a final migration dry-run/report is current-head complete. | User explicitly authorizes retiring the migration tool. | A supported task still needs the bridge. | Remove the migration command and last bounded seam. | not_met |

## Post-removal guard

After authorized removal, static guards cover active Runtime, policies, adapters,
install assets, status, and validation routing. Migration history, release notes,
archived fixtures, and explicitly labelled compatibility documentation may retain
the term v1; grep alone is not evidence of an active reader.

Any regression in a gate returns that gate to `not_met` or `partial` and blocks
further deletion. Sunset must not be bundled with TK-00, TK-01 hashing work, or a
Release Qualification run.
