# Thin Trust Kernel Architecture Contract

## Status and purpose

TK-00 freezes the architectural boundary used by later Thin Trust Kernel work.
TK-01 centralizes hashing and adds the opt-in canonical JSON primitive. TK-02
implements Manifest v0 construction and validation routing without changing
Runtime behavior, installation authorization, activation, or v1 Sunset. TK-04
extracts the seven C2 Capability packages, adds their Git-index source closure,
and binds current Release bundles with separate sidecars while preserving all
historical receipt bytes. TK-05 adds the strict four-operation Adapter Kernel
API, makes the exact nine current A3 paths thin, and binds their raw source and
executable LOC through `adapter-inventory/v1`. TK-07 removes duplicated Runtime
validation, projection, and task-state machinery while keeping the same public
contracts. Its honestly reached Runtime closure is 2987 executable LOC, below
the terminal 3000-line target, with no budget exception. A later
boundary change requires an explicit Architecture Decision or Change Contract
that states the reason, TCB impact, new trust assumptions, alternatives,
migration, and verification.

The Harness has three irreducible responsibilities:

1. **Entry Contract** — select the protocol and hand work to the correct path.
2. **Risk Routing** — block unresolved product intent and choose the required
   execution and protection policy.
3. **Evidence Chain** — bind durable task transitions to revision, Contract,
   Approval, Evidence, and status truth.

Everything else is outside the Runtime Kernel by default and must justify its
inclusion through a transitive dependency from a selected Runtime root.

## Two trust paths

```text
Host input
   |
   v
A3 Host Adapter ---> K1 Runtime Trust Kernel ---> task/status/Evidence result
                          |
                          v
                    K0 Trust Primitives

Repository desired state
   |
   v
D1 Distribution Reconciler --------------------> installed state/drift result
   |
   v
K0 Trust Primitives
```

The Runtime Trust Path and Distribution Trust Path share K0 primitives but are
separate reachability domains in `kernel-tcb-roots.json`. D1 may invoke the
current monolithic installer while it is being replaced incrementally; K1 must
not import D1 or treat the complete installer as a Runtime dependency. The
Inventory reports both paths, while the Runtime LOC budget uses only files
reachable from a `runtime_root`.

## K0 — Trust Primitives

K0 owns the smallest reusable mechanisms on which both trust paths rely:

- repository and Workspace containment;
- physical identity and reparse-boundary rejection;
- strict JSON and Schema validation;
- the canonical hashing contract;
- atomic write and replace;
- locking and compare-and-swap support;
- stable error and result contracts.

`scripts/lib/Harness.Path.psm1` is the current canonical Path primitive.
`scripts/lib/Harness.AtomicWrite.psm1` is the current canonical Atomic Write
primitive. `scripts/lib/Harness.Hashing.psm1` is the current canonical Hashing
primitive and its byte semantics are frozen in `hashing-contract.md`. No
parallel SHA-256 implementation may be added. TK-01A migrates only the
documented first-wave K0/K1 callers, and TK-01B-Compat completes production raw
SHA-256 delegation while leaving every historical serialization algorithm with
its current owner.

`scripts/lib/Harness.CanonicalJson.psm1` is the canonical two-function JSON byte
primitive defined by `canonical-json-contract.md`. TK-02 and TK-04 explicitly
adopt it for new Manifest, source-closure, and binding objects through C2
engineering construction code.
No selected Runtime root imports that code. TK-06 explicitly adopts CanonicalJson
on the Distribution trust path for new Profile and Plan contracts. It enters
only that measured trust path; no historical digest is migrated.

## K1 — Runtime Trust Kernel

K1 is limited to:

- Entry Contract compilation and validation;
- Requirement Gate resolution;
- risk and execution-profile policy evaluation;
- Protected Action evaluation;
- the strict `preflight_action`, `controlled_write`, `prepare_delegation`, and
  `commit_delegation` Adapter API, including path and patch validation, trust
  digest calculation, Policy calls, plan generation CAS, artifact publication,
  trace update, cleanup, and atomic commit;
- the task-state state machine, journal, CAS, and recovery projection;
- Evidence, Approval, Receipt-facing trust contracts used by ordinary task
  completion;
- read-only status projection.

K1 excludes Memory vaults, Team orchestration, benchmarks, model evaluation,
Release Qualification producers, rollout report generation, Markdown-to-HTML,
host-specific business policy, and installer transaction implementation.
Release receipts may reuse K0 primitives; that reuse does not make their
producers part of K1.

## D1 — Distribution Reconciler

D1 is the target owner for installation desired state. Its terminal contract is:

1. render desired state;
2. read actual state;
3. compute a deterministic diff and plan;
4. atomically apply or roll back;
5. converge uninstall;
6. report known and unknown drift without mutation during status.

TK-00 classifies the existing bootstrap, installer, uninstall, transaction, and
verification entries but does not rewrite or split them. D1 may depend on K0.
D1 must not implement Runtime protocol or risk routing.

TK-06 introduces strict `install-profile/v1` and `distribution-plan/v1` data and
`Harness.Distribution`. The installer now consumes the explicit plan for skill,
hook, vault-file and host-template selection before using its existing atomic
transaction reconciler. Profile admission is not Runtime permission. See
`declarative-distribution.md` for the exact bootstrap/Manifest intersection,
directory-link transport, invalid-input preflight and historical-uninstall
boundaries.

## C2 — Capability Modules

The seven extracted domains are Memory, Team, release-evidence, Benchmark,
Markdown-to-HTML, Providers, and engineering validation. Each v1 Capability owns
its code, Schema, tests, routing declaration, install assets, dependencies,
requested capabilities, and module manifest. Its exact package closure is bound
by `capability-source/v1` using raw Git-index blob SHA-256 and explicit
`canonical-json/v1`. C2 may call K0 and a documented K1 public API. K1 must never
import C2, and C2 must never import a host adapter.

`Harness.RolloutEvidence.psm1` is currently C2 release-evidence because current
AST imports bind it to Release and Qualification producer scripts; no selected
ordinary Runtime root imports it. TK-00 does not split that module.

`scripts/lib/Harness.ModuleManifest.psm1` and
`scripts/get-module-manifest-catalog.ps1` are C2 engineering construction
components. They validate tracked Manifest inputs and produce validation
metadata; they cannot grant capabilities, activate modules, install assets, or
write task state.

`scripts/lib/Harness.CapabilitySource.psm1` consumes the current dual catalogs
read-only. `scripts/write-capability-source-binding.ps1` is a C2
release-evidence producer for separate model, host, and full bundle sidecars.
Neither is reachable from a selected Runtime or Distribution root. The full
sidecar validates both upstream producer sidecars before binding its own four
artifacts; existing receipts and public report Schemas are unchanged.

## A3 — Host Adapters

A3 is limited to host input deserialization, a Kernel API call, host output
serialization, and necessary exit-code mapping. An adapter must not write task
state directly, compute trust digests, embed risk-policy constants, validate a
capability's private business Schema, or contain Release Qualification logic.
The terminal target is fewer than 200 executable LOC per adapter. TK-05 reaches
that target for the exact nine classified paths without adding helpers or
forwarding shims. `adapter-inventory.json` records their raw Git index blob
digests, PowerShell token-line or JavaScript lexical-token metrics, direct
Kernel API operations, and a 300-character physical-line ceiling that rejects
LOC packing. The generator rejects real unstaged source changes while remaining
stable across checkout line-ending conversion.

`adapter-kernel-api/v1` has exactly four logical operations. Its strict request
and response Schema rejects unknown fields. The PowerShell surface exports one
function per operation; operation-specific names are the only callable
authority, so no generic command, file, Policy, or caller-supplied trust-digest
escape exists. `harness-module/v1` remains capability-only and is not an
Adapter router.

## legacy-v1

legacy-v1 contains only active compatibility paths that are removed after the
versioned Sunset gates and a separate user authorization. A compatibility path
may call K0 or K1 during transition, but it cannot become a new default or be
used as an implicit source for new K1 design. Classification records its Sunset
target instead of treating a calendar date as deletion authority.

## Dependency directions

Allowed directions are:

```text
K1 -> K0
D1 -> K0
C2 -> K0 or a K1 public API
A3 -> a K1 public API
legacy-v1 -> bounded K0/K1 compatibility seams
```

The following are prohibited:

- K1 importing C2, D1, or Release Qualification;
- C2 importing A3;
- A3 writing task state or trust digests directly;
- D1 implementing Runtime routing;
- a Manifest granting its own Kernel identity or requested capabilities;
- directory moves, generated strings, or compressed source being used to evade
  TCB accounting.

Static dependency enforcement uses PowerShell AST Import-Module and dot-source
edges. Only exact, reviewed dynamic paths may use `manual_edges`; each edge binds
the source expression, target, reason, resolution limit, and TK-00 review. A
missing file, repository escape, reparse alias, unresolved dynamic import, or
unexpected cycle fails generation.

## Reproducible TCB inventory

The machine sources are:

- `kernel-tcb-roots.json` — selected roots, trust artifacts, reviewed manual
  edges, external trust, and Runtime budget;
- `kernel-component-classification.json` — the only complete per-file layer and
  ownership table;
- `scripts/get-kernel-tcb-inventory.ps1` — strict AST generator;
- `kernel-tcb-inventory.json` — tracked deterministic output.
- `schemas/adapter-kernel-api.schema.json` — strict four-operation K1 boundary;
- `scripts/get-adapter-inventory.ps1` — strict A3 metric and source generator;
- `adapter-inventory.json` — tracked deterministic nine-path A3 output.

All paths are repository-relative POSIX paths sorted with ordinal semantics. The
Inventory contains no Git Head, time, user, machine, process, temporary, or
absolute path. `-Check` constructs the complete JSON in memory, rejects uncovered
budget growth, compares canonical tracked text bytes, and writes nothing. File,
artifact, and tracked-inventory bytes preserve any UTF-8 BOM but normalize CRLF
and CR to LF before SHA-256 or equality checks, so a Git text checkout cannot
change the inventory. This representation is local to engineering inventory and
does not introduce the future canonical Runtime hashing contract. Explicit
`-OutputPath` is the only generation write surface and uses the canonical atomic
write primitive.

Runtime trust references under `schemas/`, `policies/`, `runtime-hooks/`,
`agent-configs/`, `scripts/lib/`, `templates/v2/`, and `vault-template/` must be
either in the executable closure or declared as a trust artifact. An undeclared
reference fails with `untracked_trust_reference`. External dependencies are
limited to PowerShell, the .NET base class library, Git where ordinary Runtime
uses it, and operating-system filesystem semantics.

## Executable LOC contract

For each PowerShell file:

1. decode the tracked file as strict UTF-8 and normalize CRLF/CR to LF only for
   line measurement;
2. parse with the PowerShell language parser and reject any parse error;
3. record every physical line and every nonblank physical line;
4. exclude Comment, NewLine, LineContinuation, and EndOfInput trivia tokens;
5. count each physical line covered by at least one remaining token once;
6. count every covered line of a multiline here-string or scriptblock token;
7. never count one physical line more than once.

JSON, Policy, Schema, template, and Markdown artifacts do not contribute to
`executable_loc`; they report physical lines and bytes separately. The algorithm
does not depend on a formatter version.

## Runtime TCB budget ratchet

The terminal target is **Runtime transitive executable LOC < 3000**. TK-00 did
not claim that target; its generated baseline was 6151 executable LOC. TK-07
now satisfies the target and ratchets the generated current-tree baseline to
**2987** executable LOC. It remains a ratchet:

- default growth is rejected by `-Check`;
- an exception must identify added lines, reason, new trust assumption,
  alternatives, repayment, and expiry milestone;
- security fixes may grow the TCB only through such an explicit exception;
- the sum of active exception lines must cover positive delta;
- reducing the current total does not require an exception and should be
  followed by an explicit baseline reduction.

The TK-00 initial baseline had no exception. TK-01A temporarily recorded
`KTB-EX-001` for a measured 27-line net increase. TK-01B-Compat removes obsolete
first-wave forwarding layers, returns the measured Runtime TCB to the frozen
6151-line baseline, and retires that exception with delta zero. TK-01B-New adds
an initially unreferenced K0 primitive. TK-02 adds a C2-only construction caller,
but no selected trust-path import, so the transitive Runtime measurement remains
6151 with delta zero. TK-04 adds only C2 construction and Release producer
paths, so selected Runtime reachability and the measured 6151-line baseline
remain unchanged. TK-05 removes the redundant core Hook wrapper as a selected
root, selects `Harness.AdapterAction` through the thin Hook and MCP roots, and
measures 6150 executable LOC with no exception. The stable core Hook path
remains a compatibility CLI outside selected ordinary reachability. TK-03 then
reduces selected v2 Runtime reachability to 6075 without physically deleting
the retained migration bridge. TK-06 changes only the Distribution trust path.
TK-07 deletes duplicated implementation inside the honestly measured Runtime
closure, reaches 2987 executable LOC, and lowers the baseline to that exact
generated value with delta zero and no exception. The baseline is a generated
observation bound by verifier checks, not a permanent architectural constant.

The bounded TK-07 Base-to-Head review uses the unchanged inventory algorithm.
PR #12 Head measured 6075 executable lines across 22 Runtime files, with a
976-character maximum physical line, 51 lines over 300 characters, 656
semicolon characters, and 140 multi-semicolon lines. TK-07 measures 2987 lines
across 21 Runtime files, with corresponding source-density values of 500, 37,
418, and 103. The verifier ratchets those Head density values so the reduction
cannot be recreated later by packing more statements onto physical lines.

## Terminal SLOs

These are end-state directions, not TK-00 completion claims:

- Runtime Kernel transitive executable LOC < 3000;
- Entry Contract <= 80 lines and <= 1200 tokens;
- each Host Adapter < 200 executable LOC;
- new module central-file modifications = 0 for discovery, validation, and
  changed-path routing only;
- unowned verifier = 0;
- active Runtime protocol = v2 only;
- active v1 Runtime reader = 0;
- capability-to-Kernel reverse import = 0;
- adapter policy constants = 0;
- unknown installed drift = 0;
- status command count = 1 and status writes = 0.

The generated classification covers the dynamically enumerated scope with no
unclassified, stale, or duplicate path. Its layer totals are observations
regenerated by the contract verifier; the JSON remains the sole complete table.
