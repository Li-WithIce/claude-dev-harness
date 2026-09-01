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
| EC-01 | `protocol_default` is `auto`. | One deterministic default. | `Harness.Protocol` validates config and process preference. | `verify-v2-entry-contract`, `verify-v2-protocol-config` | enforced | Protocol evaluator | Hosts must call admission even for explicit v2. | not_eligible |
| EC-02 | Auto admits only v2; an absent Decision uses the v2 default and invalid/unavailable input blocks new work. | No implicit legacy fallback or Release inference. | `Get-HarnessProtocolResolution` and strict Runtime Default admission. | `verify-v2-protocol-config`, `verify-runtime-qualification-decoupling`, `verify-v1-sunset` | enforced | Protocol evaluator | Host-side bypass remains outside this evaluator. | not_eligible |
| EC-03 | Artifact-free identity uses surfaced/process `HARNESS_PROTOCOL` once and never guesses. | No hidden preference source. | Protocol validates supported preference; host first-hop selection is prose. | `verify-v2-entry-contract`, `verify-v2-direct-no-artifacts` | partially_enforced | Host-neutral entry adapter plus Protocol API | No machine component proves the host read the value exactly once. | not_eligible |
| EC-04 | Resolve new-work admission once, including explicit v2, before inline classification; no task/current scan. | A pause cannot be bypassed by preference. | Protocol, Policy and native TaskState creation all enforce admission. | `verify-v1-sunset`, `verify-v2-protocol-config`, `verify-v2-direct-no-artifacts` | partially_enforced | Host-neutral entry adapter | Uninstrumented host reads are not observable. | not_eligible |
| EC-05 | Selected v2 Direct loads no v1 lifecycle, Memory, Team, or Provider. | Optional capability failure cannot contaminate Direct. | Direct has no durable task writer; Runtime modules have no Memory import. Host skill loading remains prose. | `verify-v2-direct-no-artifacts`, `verify-v2-runtime-memory-decoupling` | partially_enforced | Host-neutral entry adapter and module dependency lint | Host-side skill loads are not fully machine gated. | not_eligible |
| EC-06 | Valid existing v2 state wins; a legacy path is rejected by existence without reading its contents. | Recovery retains artifact truth without implicit migration. | `Harness.Protocol` artifact-first resolution. | `verify-v2-protocol-config`, `verify-v1-sunset` | enforced | Protocol evaluator | Historical migration is a separate explicit maintenance command. | not_eligible |
| EC-07 | Existing v2 may status/resume while new work is paused; invalid state fails closed. | Stop-loss does not strand or downgrade existing v2 work. | Task CLI, Protocol, Recovery, TaskState, strict Schemas. | `verify-v2-task-state`, `verify-v1-sunset` | enforced | Protocol and TaskState evaluators | Host must distinguish recovery from new-work admission. | not_eligible |
| EC-08 | Unresolved Requirement or product decision blocks every write and enters Ask. | Product intent precedes mutation. | `Harness.Requirement`, Contract validation, TaskState creation, ProtectedAction. | `verify-v2-requirement-gate`, `verify-v2-readonly-zero-write` | enforced | Requirement Gate and protected-write evaluator | Host must still present Ask accurately. | not_eligible |
| EC-09 | Protected, expanded, or non-Direct work reroutes before writes. | Risk cannot be downgraded by prose. | `Harness.Policy`, `Harness.ProtectedAction`, core PreToolUse. | `verify-v2-policy-contracts`, `verify-v2-approval`, `verify-runtime-hooks` | partially_enforced | Risk evaluator plus all host mutation adapters | Scope expansion discovered only in reasoning is not machine observable. | not_eligible |
| EC-10 | A public-contract expansion outside scope requires explicit user confirmation; continuation alone is insufficient. | Continuation is not authorization. | Requirement Contract binds confirmed scope, but discovery of a new public change is host reasoning. | `verify-v2-requirement-gate` | prose_only | Requirement change evaluator receiving an explicit proposed delta | No runtime component automatically detects every public-contract expansion. | not_eligible |
| EC-11 | Clear Direct uses minimum targets/checks, one bounded review, and no task/runtime/current/lifecycle writes. | Small work stays ephemeral and verified. | Direct profile cannot persist a task; target minimization and review are host behavior. | `verify-v2-direct-no-artifacts` | partially_enforced | Direct execution adapter | Minimum-edit and bounded-review semantics are not machine enforced. | not_eligible |
| EC-12 | Read-only work performs zero writes and reports `not_run`/`unavailable` distinctly from pass. | Inspection is non-mutating and evidence states remain truthful. | Inspect APIs and status paths are read-only; reporting vocabulary is prose/Evidence Schema. | `verify-v2-readonly-zero-write`, `verify-v2-evidence` | partially_enforced | Read-only adapter plus Evidence result type | Free-form reports can still misstate an unavailable check. | not_eligible |
| EC-13 | Legacy lifecycle/shim loading is retired; explicit history/migration maintenance requires its own authorization. | No ordinary legacy Runtime route. | v2-only Protocol, retired stage command and v2-only install Profiles; host loading is prose. | `verify-v2-entry-contract`, `verify-v1-sunset`, `verify-v1-to-v2-migration`, `verify-v2-install-presets` | partially_enforced | Host-neutral entry adapter | No central loader enforces every external host skill load. | not_eligible |

No TK-00 rule is marked eligible for removal. The terminal Entry Contract target
of at most 80 lines and 1200 tokens is a future outcome after machine parity, not
a reason to delete current trust prose.
