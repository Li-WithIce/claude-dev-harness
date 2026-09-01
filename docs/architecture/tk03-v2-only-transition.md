# TK-03 Architecture Change Contract

## Authority and scope

The current user explicitly confirmed TK-03, including replacing the former
Stable-before-v1-retirement prerequisite, and separately authorized releasing
the `dp-03-real-qualification` v1 pointer and importing that task as v2 paused.
The implementation baseline is PR #11 Head
`2e1949d7bcedc5397404d86a5ce95b51c8dde4a0`.

This contract supersedes the **active Runtime** v1 fallback, v1 stop-loss and
Stable prerequisite in compatibility-policy, default-promotion-gates and the
older entry/policy descriptions. It does not rewrite historical Release
Schemas, report bytes, digest algorithms, qualification results or task plans.
No Qualification, dispatch, Promotion, Auto Flip, Canary, Stable, Ready or merge
is authorized or implied. A code default is not a Release Gate pass.

## Admission and recovery

| Input | Current behavior |
|---|---|
| Existing valid v2 task | Retain v2 precedence, including while new work is paused; recover through v2 APIs. |
| Invalid v2 artifact | Reject, with no legacy fallback or writes. |
| Legacy plan path without v2 state | Reject by existence alone; ordinary Runtime never reads its contents. |
| New task with absent config/decision | Admit only v2. |
| `auto` with valid v2 Runtime Decision | Validate original digest/source/capability bindings and admit v2. |
| `auto` with invalid/unavailable Decision | Block new work, never infer v1 or silently ignore the invalid input. |
| Explicit `v1`, including old v1 workspace config | Fail closed; explicit migration maintenance is separate. |
| `disable-v2` | Write `harness-protocol-config/v2`, `new_task_protocol=v2`, `new_work=paused`. |
| `enable-v2` / `reset-auto` | Explicitly enable new v2 work / re-enable v2-only auto admission. |

The historical config v1 Schema remains unchanged. Valid old `auto`/`v2`
config bytes can be read without rewriting; old `v1` does not become a paused
or authorizing v2 decision by reinterpretation. The new config Schema rejects
unknown fields, unsupported protocols and admission states. Install/update/
uninstall still preserve this user-owned file.

The historical Runtime Decision v1 Schema and digest algorithm remain
unchanged. A separately named **runtime-default-admission** Schema narrows
current acceptance to v2. The producer no longer accepts `NewTaskProtocol=v1`.
An old report remains historical; neither its original truth nor its digest is
rewritten to make the new Runtime admit it.

New-work admission is checked even for explicit v2. Therefore the old
explicit-v2/no-protocol-call first-hop prose is superseded: hosts resolve
admission once before inline classification, without reading task/current
state. Direct still creates no task, plan, runtime pointer or lifecycle state.
The existing-task Policy handoff is v2 recovery, not a guessed fresh profile.

## Retained compatibility boundary

Only explicitly invoked migration/history maintenance may parse legacy plans.
The strict parser is isolated under `modules/legacy-v1`; it is not imported by
ordinary Protocol, Policy, status or recovery. The v1 stage writer is retired
with a zero-write diagnostic before importing its historical implementation.
Migration remains opt-in, exact-digest bound and paused on import.

Fresh core/governed/full profiles omit active v1 lifecycle skills, shim/stage
wrappers, task mirrors and legacy workflow templates. Historical assets remain
in the repository for a separately approved removal diff. Reconciliation uses
the existing TK-06 ownership/history rules; foreign and user-owned data are
not reclassified as obsolete managed data.

The previous full-only `workflow-team` skill describes the retired v1 stage
model, so it is no longer installed or advertised as an active Team feature.
Repository Team maintenance code remains retained; no replacement v2 Team
implementation or automatic delegation is introduced. Installed verification
uses the validated desired Profile and never invokes historical mirror health
or repair as an automatic install gate.

The retained Stage-based `prepare_delegation` and `commit_delegation` exports
reject with `v1-delegation-retired` before reading a plan, invoking a backend,
publishing an artifact or appending a review trace. Their CLI reports the same
rejection. The old Team spawn entry rejects with `v1-team-retired` before any
legacy task access. Existing API envelope versions remain unchanged; this is
not a new v2 Stage or Team ABI. Independent dispatcher/supervisor transport
tests remain active, including literal typed parameters, exact byte framing,
request rejection, bounded process-tree cleanup and timeout behavior.

Tests of active v2 admission, stop-loss, recovery, installation and migration
boundaries replace claims that v1 lifecycle behavior is supported. Any retained
legacy test must be explicitly classified as archived compatibility in its
owning Manifest, absent from active CoreGroup/changed/full routes, and reported
as not executed rather than pass. CoreGroup identities do not change.

The fourteen exact archived paths live in the `legacy-v1` Manifest, not in a
second manual router. Their replacement coverage is:

| Retired behavior | Active coverage |
|---|---|
| v1 routing, coexistence and shared-pointer recovery | `verify-v2-entry-contract`, `verify-v2-direct-no-artifacts`, `verify-v2-protocol-config`, `verify-runtime-hooks`, `verify-v1-sunset` |
| v1 stage/skill/workflow/review gates | `verify-v2-requirement-gate`, `verify-v2-task-state`, `verify-v2-policy-contracts`, `verify-v2-evidence`, `verify-v2-governed-audit` |
| Stage-based delegation and Team execution | `verify-v1-sunset` (zero-read/write rejection), `verify-adapter-transport` (transport only), `verify-team-preset` (descriptor maintenance only) |
| v1 Memory mirror repair and inferred inbox identity | `verify-v1-sunset` (both repair entries and retirement branch reject before reads/writes), `verify-runtime-inbox` (locked history, explicit ID / default unknown), `verify-memory-maintain` (archive only, no implicit history report/health) |
| legacy plan interpretation required for explicit import | `verify-v1-to-v2-migration` (still active, paused import only) |
| fresh/update/uninstall asset selection and ownership | `verify-declarative-distribution`, `verify-v2-install-presets`, install/uninstall isolation |

Archived tests are not asserted equivalent to v2 behavior: they protect a
retired protocol, while the active checks cover the confirmed replacement.

Both Memory repair entries reject before imports, locks or reads, including
inactive-task retirement. Ordinary authorized Memory maintenance retains
candidate archive only; repair/report/health are explicitly `NOT_RUN` there.
Direct health/report/layer commands remain scoped to historical-v1-only and
cannot act as v2 Runtime health gates. A fresh full v2 Memory installation
returns `NOT_APPLICABLE`; wrong-type, reparse, inaccessible or explicitly
missing history input fails closed instead of being treated as absent.
Historical diagnostics never recursively scan agent homes. Inbox row format,
selectors, locks and explicit TaskId behavior are unchanged; omitted TaskId
uses the existing `unknown` value without reading old pointers or flows.

## Retirement and rollback

All ten V1S gates require current evidence. In particular, this workspace's
paused migration does not establish the absence of external active v1 tasks,
nor the human owner assertions required by the Sunset matrix. Both DONE v1
histories remain preserved. Physical removal still requires **all ten gates
current-head met and separate user approval of the exact removal diff**.

Stop-loss pauses new work and recovers existing v2 state. An explicitly approved
known-good **v2** distribution may be restored; never revive v1, delete an
imported task, reset the working tree or rewrite history. The one-time pointer
release used raw-byte preimages, existing locks, CAS and a conditional recovery
path; no live installation or Release publication is part of this transition.
