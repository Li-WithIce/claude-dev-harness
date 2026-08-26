# Entry Contract Prose-to-Policy Parity

## Method

The source is `policies/entry-contract.md` at the current tree. `enforced` means
a Hook, evaluator, or state machine rejects the contrary behavior.
Tests and documentation are evidence of a contract, not enforcement. `partially_enforced`
means a machine seam enforces only part of the prose. `prose_only` means the host
must currently follow the Entry Contract. `not_applicable` is reserved for
explanatory text with no enforceable action.

Removal eligibility is conservative: prose is not eligible until every trust
intent is enforced by a Hook, evaluator, or state machine and has current tests.

| Rule | Source paraphrase | Trust intent | Current enforcement point | Current tests | Parity | Target enforcement | Gap | Removal eligibility |
|---|---|---|---|---|---|---|---|---|
| EC-01 | `protocol_default` is `auto`. | One deterministic default. | `Harness.Protocol` validates config and process preference. | `verify-v2-entry-contract`, `verify-v2-protocol-config` | enforced | Protocol evaluator | Host must still call the evaluator on non-explicit paths. | not_eligible |
| EC-02 | Auto is existing artifact, then Runtime Default, then v1 fallback. | Artifact truth wins; Qualification is not Runtime input. | `Get-HarnessProtocolResolution` and strict Runtime Default validation. | `verify-v2-protocol-config`, `verify-runtime-qualification-decoupling` | enforced | Protocol evaluator | v1 fallback remains until Sunset. | not_eligible |
| EC-03 | Artifact-free identity uses surfaced/process `HARNESS_PROTOCOL` once and never guesses. | No hidden preference source. | Protocol evaluator validates supported process values; host first-hop selection is prose. | `verify-v2-entry-contract`, `verify-entry-routing-clarification` | partially_enforced | Host-neutral entry adapter plus Protocol API | No machine component proves the host read the process value exactly once. | not_eligible |
| EC-04 | Explicit v2 is a complete first hop; do not call status/protocol or inspect task/runtime/current. | Explicit selection cannot fan out into stale state. | `scripts/task.ps1` enforces its commands, but the host's first-hop choice precedes the CLI. | `verify-v2-entry-contract`, `verify-v2-direct-no-artifacts` | partially_enforced | Host-neutral entry adapter | Machine code cannot observe prohibited pre-routing reads made by the host. | not_eligible |
| EC-05 | Selected v2 Direct loads no v1 lifecycle, Memory, Team, or Provider. | Optional capability failure cannot contaminate Direct. | Direct has no durable task writer; Runtime modules have no Memory import. Host skill loading remains prose. | `verify-v2-direct-no-artifacts`, `verify-v2-runtime-memory-decoupling` | partially_enforced | Host-neutral entry adapter and module dependency lint | Host-side skill loads are not fully machine gated. | not_eligible |
| EC-06 | Known identity resolves v2 state before v1 plan; new identity uses config, Runtime Default, then fallback. | Existing artifact truth is deterministic. | `Harness.Protocol` artifact-first resolution. | `verify-v1-v2-coexistence`, `verify-v2-protocol-config` | enforced | Protocol evaluator | None while v1 compatibility remains. | not_eligible |
| EC-07 | Existing v2 may status/resume; v1 may load its shim; invalid input fails closed. | No ambiguous cross-protocol mutation. | Task CLI, Protocol, Recovery, TaskState, strict Schemas. | `verify-v2-task-state`, `verify-v1-v2-coexistence` | enforced | Protocol and TaskState evaluators | v1 branch remains Sunset-gated. | not_eligible |
| EC-08 | Unresolved Requirement or product decision blocks every write and enters Ask. | Product intent precedes mutation. | `Harness.Requirement`, Contract validation, TaskState creation, ProtectedAction. | `verify-v2-requirement-gate`, `verify-v2-readonly-zero-write` | enforced | Requirement Gate and protected-write evaluator | Host must still present Ask accurately. | not_eligible |
| EC-09 | Protected, expanded, or non-Direct work reroutes before writes. | Risk cannot be downgraded by prose. | `Harness.Policy`, `Harness.ProtectedAction`, core PreToolUse. | `verify-v2-policy-contracts`, `verify-v2-approval`, `verify-runtime-hooks` | partially_enforced | Risk evaluator plus all host mutation adapters | Scope expansion discovered only in reasoning is not machine observable. | not_eligible |
| EC-10 | A public-contract expansion outside scope requires explicit user confirmation; continuation alone is insufficient. | Continuation is not authorization. | Requirement Contract binds confirmed scope, but discovery of a new public change is host reasoning. | `verify-v2-requirement-gate` | prose_only | Requirement change evaluator receiving an explicit proposed delta | No runtime component automatically detects every public-contract expansion. | not_eligible |
| EC-11 | Clear Direct uses minimum targets/checks, one bounded review, and no task/runtime/current/lifecycle writes. | Small work stays ephemeral and verified. | Direct profile cannot persist a task; target minimization and review are host behavior. | `verify-v2-direct-no-artifacts` | partially_enforced | Direct execution adapter | Minimum-edit and bounded-review semantics are not machine enforced. | not_eligible |
| EC-12 | Read-only work performs zero writes and reports `not_run`/`unavailable` distinctly from pass. | Inspection is non-mutating and evidence states remain truthful. | Inspect APIs and status paths are read-only; reporting vocabulary is prose/Evidence Schema. | `verify-v2-readonly-zero-write`, `verify-v2-evidence` | partially_enforced | Read-only adapter plus Evidence result type | Free-form reports can still misstate an unavailable check. | not_eligible |
| EC-13 | Only detector-selected v1 loads `entry-router`; missing compatibility fails closed. | Legacy lifecycle cannot leak into v2. | Installed template and protocol selection constrain routing; host load remains prose. | `verify-v2-entry-contract`, `verify-v1-v2-coexistence` | partially_enforced | Host-neutral entry adapter | No central loader machine-enforces every host skill load. | not_eligible |

No TK-00 rule is marked eligible for removal. The terminal Entry Contract target
of at most 80 lines and 1200 tokens is a future outcome after machine parity, not
a reason to delete current trust prose.
