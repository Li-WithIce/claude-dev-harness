# TK-06 — Declarative Distribution

## Contract and authority

`install-profile/v1` is a centrally maintained D1 transport policy, not a module
Manifest and not a Runtime execution profile. The three explicit inputs are
`modules/distribution/profiles/{core,governed,full}.json`. Both new contracts
select `digest_algorithm: canonical-json/v1`. A Profile digest covers its whole
canonical object; a `distribution-plan/v1` digest covers its canonical object
with only the top-level `digest` omitted. The CLI prints canonical UTF-8 without
BOM plus one display LF; the LF is not part of the digest. Object key order is
irrelevant; array order remains meaningful and preserves installed skill order.

For module-declared installation assets:

```text
authorized module assets = Manifest package.install_assets requests
                           intersect Profile enabled_modules
                           intersect Profile exact asset_allowlist
```

The Profile also checks each enabled module's requested capabilities against
its explicit `allowed_capabilities` and requires its dependency closure to be
enabled. This is installation admission metadata: it grants no Runtime tools,
activation, task state, Policy, Kernel API or operating-system permission.
`default_activation` is never used to select an installed asset. A request
without a Profile grant is omitted; a Profile grant without a request cannot
fabricate a module asset. Unknown modules, missing dependencies, cycles,
conflicting owners and malformed documents fail closed.

## Compatibility transport, not invented Manifest permissions

Frozen v0 Manifests have no `package.install_assets`. Existing bootstrap files
(entry templates, compatibility skills, host configurations and core hooks) are
therefore explicit `origin: bootstrap` Profile records, not synthetic Manifest
requests. The pre-existing full-preset Memory hook is an explicitly granted
exported-hook transport record. A v1 bootstrap record must be such an exported
hook; it cannot masquerade as an installation asset.

The installed skill representation remains a directory junction. Its `SKILL.md`
is the requested entry asset; its complete transport file list is separately
and explicitly enumerated in the Profile. Capability support files must be
declared in that module's existing `code` or `install_assets` role. These roles
remain disjoint and unchanged. For example, Memory's code wrappers remain code,
not new install assets. An undeclared file or reparse entry in an authorized
skill directory rejects the plan before link traversal or installation. Adding
a sibling skill directory does not install it. The legacy `.system` directory
is fixed installer bookkeeping with its existing local-overlay preservation;
it is not discoverable module authorization.

The TK-06 baseline profiles preserved 8/10/14 skills including
`.system`, 4/4/5 hooks and 5/5/29 vault files for core/governed/full respectively.
TK-06 `full` authorized four module entry assets: the md-html, obsidian-memory and
workflow-team skill entries, and `vault-template/MEMORY.md`. The declared Team
documentation request was not installed because it had no Profile grant.

TK-03 explicitly replaces those active selections: core/governed/full now
install 1/3/6 skills including `.system`, 4/4/5 hooks and 1/1/16 vault files.
The full Profile authorizes three module assets (md-html, obsidian-memory and
`MEMORY.md`), not the v1-only workflow-team skill. No v1 shim, stage skill or
task mirror is desired. The retained sources and historical registry records
are not deleted; existing reconciliation still protects foreign/user-owned data.

## Construction and consumption

`Harness.Distribution` depends only on the existing K0 Path, Hashing and
CanonicalJson primitives. It reads the published Manifest catalog's exact
source list, strictly validates the corresponding on-disk Manifests, checks
their canonical digests and rejects added/missing module directories. It does
not import the C2 constructor, execute a discovered export, or require Git,
Memory, Team, Providers, or Runtime state during plan construction. Repository
publication still uses the existing tracked/index-bound Manifest generator;
the shipped catalog permits the existing archive/isolated-copy install path.

Each plan binds the Profile digest, catalog digest, exact Manifest identities,
enabled module IDs, feature metadata, vault mode and selected transport assets.
Every source and explicitly allowed support file has a raw-byte SHA-256. Source
and target paths use a strict relative POSIX spelling. Unknown fields, BOM,
duplicate decoded JSON keys, case-colliding assets, wildcards in grants, path
escape, reparse paths, missing files and unsupported actions are rejected.
Text sources must be valid UTF-8. Before any install writes, the installer
validates host JSON templates with its existing exact-number compatibility
parser, preserving BigInteger and Decimal support and inexact-number rejection.
It does not apply the new canonical data model to historical host templates,
verbatim vault JSON or capability support files.

`scripts/get-distribution-plan.ps1 -Preset core|governed|full` emits the plan
without writing files. Its optional `-PlanPath` checks a repository-contained
plan against its own digest and a freshly reconstructed plan; a recomputed
digest on forged content is not authorization. The command does not apply it.

`install.ps1` snapshots the existing preset/default/preserve/VaultProfile rules
under the existing mutex, prepares source-only data outside the write-critical
section, then reacquires that same mutex to recheck state and reconstruct the
current plan before any installation or recovery persistence. Changed preset
selection fails closed before writes. Schema checks do not redundantly encode
canonical bytes; current-plan comparison checks the validated content digests.
The legacy pointer preview is in-memory only, and the production lock timeout
is unchanged. The installer derives its skill list, hooks,
vault file actions and all six host-template sources from it. Rendered source
text is read once and its exact captured bytes are checked against the plan.
Skill source sets and bytes are checked again immediately before linking.
This is the actual installation input, not a shadow report or second router.

The plan is the desired transport inventory, not a serialized arbitrary command
list. Existing reconciliation code continues to read actual state, preserve
foreign/user-owned data, compute exact identities, stage/config-merge, atomically
apply, record backups and recover or roll back. Live directory junctions are
not immutable copies or an OS sandbox; later edits to an installed source tree
remain outside this one-time plan snapshot and are governed by existing Host
and Runtime boundaries.

## Historical and release boundaries

`install-registry/v1.1`, `install-manifest/v1.2`, transaction journals, postimage
identities and all their byte/digest algorithms are unchanged. No new plan field
is injected into historical records. Feature ownership records the actual
plan-derived selection using the existing schema.

Uninstall does not import `Harness.Distribution` or rediscover a current Profile.
It converges from registry/history and registered identities, including when
current Profile or catalog input is unavailable or invalid.

TK-06 adds CanonicalJson and the D1 constructor to the Distribution trust path
only. Runtime roots and the frozen Runtime executable-LOC ceiling do not change.
It performs no Qualification, workflow dispatch, Promotion, Auto Flip, Canary,
Stable rollout, v1 Sunset or TK-07 work.

## Verification

`tests/verify-declarative-distribution.ps1` verifies all three deterministic
plans and legacy selections, strict parsing and path/ownership/dependency
rejection, authorization intersections, plan tampering, source drift, reparse
pre-descent rejection, invalid-input zero-write installation, actual narrowed
Profile consumption and registry-based uninstall with invalid current inputs.
The existing install presets, installation/isolation, uninstall/isolation and
managed-update verifiers retain responsibility for their transaction and
compatibility checks. Fixtures that copy an installation source now also copy
its declared Profile, Manifest/catalog and Schema inputs.

Source-bound preflight is repeated by every install in the preset compatibility
verifier. A local TK-06 diagnostic run passed all 247 checks in 873 seconds, so
that verifier alone moves from a 600-second to a bounded 900-second allowance.
Other verifier budgets, timeout failure handling and CI job timeouts are unchanged.

Zero-install-write snapshots bind the entire isolated workspace and user tree
apart from PowerShell's own exact `StartupProfileData-NonInteractive` JIT cache
and its empty parent-directory bookkeeping; every other file under those
parents is still included. Host startup cache activity is not installer state.
