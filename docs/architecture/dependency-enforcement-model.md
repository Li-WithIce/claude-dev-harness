# Dependency, Distribution Authorization, and Runtime Enforcement

## Three controls, not one grep

Thin Trust Kernel uses three distinct controls. They may consume related Policy
or Manifest data, but they protect different boundaries and cannot substitute
for one another.

| Control | Input | Decision time | Guarantees | Does not guarantee |
|---|---|---|---|---|
| Dependency direction | PowerShell AST, import graph, reviewed manual edges, classification | Repository verification | Declared repository dependency direction and reproducible TCB reachability | OS sandboxing, arbitrary generated code, process isolation |
| Install asset authorization | Manifest request intersected with Install Profile allowlist, then D1 plan | Desired-state construction | Unauthorized module assets do not enter desired state or an apply plan | Runtime tool authorization or host process isolation |
| Runtime enforcement | Runtime Policy, Protected Action evaluator, PreToolUse/controlled-write adapters | Before a tool write | A normalized tool action receives a fail-closed policy decision before Harness permits the write | OS-level containment of every process or override of Host/enterprise denial |

## Dependency direction

`scripts/get-kernel-tcb-inventory.ps1` parses PowerShell with the language AST.
It resolves literal Import-Module and dot-source paths, PSScriptRoot/RepoRoot
Join-Path expressions, and strictly foldable PSScriptRoot/RepoRoot expandable
literals. A variable or runtime-computed module name is
`unresolved_dynamic_dependency` unless one exact TK-00 manual edge binds the
source expression and target. Missing paths, repository escape, reparse aliases,
and cycles fail closed.

This proves the checked repository graph only. It is not a PowerShell sandbox
and cannot make `Invoke-Expression`, arbitrary downloaded code, or a separate
process safe. Such behavior needs a different Runtime policy or must remain
forbidden by the component contract.

## Install asset authorization

Manifest Phase 0 declares requested capabilities and ownership but grants
nothing. The target authorization calculation is:

```text
authorized asset set =
  discovered tracked manifests
  intersect Install Profile enabled modules
  intersect Kernel Policy and capability allowlists
```

D1 renders desired state only from that authorized set, then reads actual state,
diffs, plans, and atomically applies. A Schema-invalid Manifest, unknown module,
dependency cycle, owner conflict, or capability request outside the allowlist
produces no plan and executes zero tests or install steps. `git grep` is not an
authorization mechanism.

TK-00 defines this boundary but leaves existing installer behavior unchanged.

## Runtime enforcement

Host adapters deserialize the real tool input and send normalized command or
target-path data to `Harness.ProtectedAction` through the core PreToolUse or
controlled-write path. The evaluator combines core policy, a strict Workspace
overlay, task/Contract state where required, environment, dry-run, and current
Approval. The decision runs before the Harness write surface and fails closed on
missing or malformed policy.

The Hook is a guardrail, not an operating-system sandbox. Host permissions,
filesystem ACLs, enterprise policy, endpoint isolation, and process restrictions
may still deny an action that Harness policy allows. Their denial is not a
Harness pass, and Hook unavailability is not proof of enforcement.

Dependency lint cannot authorize a write. A Manifest cannot authorize a write.
PreToolUse cannot prove a clean import graph. Every completion claim must name
which control produced its evidence.
