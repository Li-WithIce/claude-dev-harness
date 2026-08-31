# Module Manifest v0/v1 Construction Contract

## Status and authority

Manifest Phase 0 remains frozen as `schema_version: harness-module/v0` in
`schemas/module-manifest.schema.json`. TK-04 does not rewrite that Schema or its
historical construction bytes. It adds `harness-module/v1` only for the seven
C2 Capability domains and emits a mixed `module-manifest-catalog/v1`. Kernel,
Adapter, Distribution, task-governance, and `legacy-v1` remain v0.

The exact v1 set is `benchmark`, `harness-maintenance`, `md-html`, `memory`,
`providers`, `release-evidence`, and `team`. Their exact
`classification_owner` values are respectively `benchmark`,
`engineering-validation`, `md-html`, `memory`, `providers`,
`release-evidence`, and `team`. No eighth v1 module or duplicate owner is
accepted by production construction.

Phase 0 is a construction-input contract for discovery, ownership, watch paths,
validation ownership, changed-path routing, dependencies, entrypoints, and
requested capability declarations. By itself it cannot drive installation, activation,
default profiles, Protected Action changes, write permission, or Kernel identity.

TK-06's separate D1 `install-profile/v1` and `distribution-plan/v1` contracts
consume v1 `package.install_assets` as requests intersected with central Profile
grants. No Manifest gains self-authorization, activation or Runtime authority;
the frozen v0/v1 schema and code/install-asset role semantics are unchanged.
See `declarative-distribution.md` for the existing bootstrap and exported-hook
transport boundary and registry-based uninstall compatibility.

## v0 required shape

Every document has exactly these top-level fields:

- `schema_version` — exactly `harness-module/v0`;
- `module_id` — canonical lowercase stable identity;
- `kind` — `kernel`, `capability`, `adapter`, or `legacy`;
- `description` — non-empty human purpose;
- `default_activation` — declaration only, never authorization;
- `dependencies.kernel_api` and `dependencies.modules`;
- `requested_capabilities`;
- `ownership.owned_paths` and `ownership.watch_paths`;
- `entrypoints.commands` and `entrypoints.hooks`;
- `validation.owner_tests`, `quick`, `core_group`, `changed`, and `full`.

Unknown fields are rejected at every fixed object boundary. Arrays have bounded
lengths and explicit uniqueness. `module_id` matches
`^[a-z][a-z0-9-]{1,62}$`; reserved ids such as `kernel`, `core`, `runtime`,
`legacy`, and `none` are rejected. Identity uniqueness is case-insensitive even
though the canonical representation is lowercase.

## Kind invariants

- `kernel` cannot request `capability-write`.
- `adapter` cannot request `task-state-write`; `codex-adapter` is an adapter, not
  a capability.
- `legacy` must have `default_activation: false`.
- `capability` cannot request `kernel-policy-write` or own a path under
  `policies/`.
- A module's `requested_capabilities` are requests, not grants.

The future authorization equation is:

```text
effective capabilities =
  manifest.requested_capabilities intersect profile.allowed_capabilities
```

Any request outside the profile allowlist fails closed. Installation and
activation also require an Install Profile, Kernel Policy, and allowlist.
A Manifest can never self-authorize a write, Kernel identity, or default activation.

## Path and glob contract

All paths are repository-relative POSIX paths with no drive, leading slash,
backslash, `.` or `..` segment, or empty segment. `entrypoints` and
`validation.owner_tests` are concrete tracked files and never globs.

`owned_paths` and `watch_paths` use one minimal dialect:

- an exact repository path; or
- an exact directory path followed by terminal `/**`, meaning the directory and
  all descendants;
- no other `*`, `?`, character class, brace, negation, Git attribute, PowerShell
  wildcard, or minimatch semantics.

## Ownership

Across a discovered manifest set:

- every verifier has exactly one owner;
- every owned path has one primary owner;
- a watch path may have multiple watchers;
- shared K0 paths are owned by the Kernel module;
- other modules may watch, but not own, shared K0 paths.

`Harness.Hashing.psm1` is owned by the Thin Trust Kernel v0 module and watched by
the consumers that depend on its frozen K0 byte contract.

## Stable CoreGroup identity

`validation.core_group` is null or exactly one of:

- `entry-lifecycle`;
- `evaluation-release`;
- `install-evidence`;
- `governance-approval`;
- `harness-contracts`.

Manifest discovery must preserve the current PR matrix check name, ordinary
receipt `check_name`, and exact-head receipt identity. Renaming or regrouping is
a separate versioned CI Contract change. “Zero central-file modification” is a
target only for discovery, validation, and routing; install or activation policy
remains centrally authorized.

For v1 Capability documents, `validation.core_groups` replaces the singular
v0 `core_group`. It is a strict object whose only possible keys are the same
five stable identities. A Capability may contribute an explicit ordered subset
to more than one group, but every contributed test must be one of that module's
`owner_tests`. TK-04 preserves the exact pre-existing 14/14/3/3/20 group
membership and order.

## v1 Capability package shape

`schemas/module-manifest-v1.schema.json` keeps the shared identity, dependency,
capability request, ownership, and validation fields and adds:

- `module_version`, a strict semantic version;
- `classification_owner`, one of the seven frozen C2 owner domains;
- `package.code`, `package.schemas`, `package.tests`, and
  `package.install_assets`;
- `exports.commands`, `exports.hooks`, and `exports.libraries`;
- `validation.core_groups`.

Every tracked file under a Capability's primary ownership, except its own
Manifest, belongs to exactly one package role. Role overlap, an incomplete role
closure, an export outside `package.code`, a non-`.psm1` library, or an owner
test outside `package.tests` fails construction. These package and export fields
are descriptive build inputs only. `default_activation` is exactly false, and
`kind` is exactly `capability`.

## Construction and discovery safety

`scripts/lib/Harness.ModuleManifest.psm1` discovers only tracked regular files at
`modules/<module_id>/module.manifest.json`. Physical discovery and the Git index
must contain the same exact set. The constructor rejects reparse or symlink
aliases through canonical physical containment, enforces case-insensitive unique
module ids, requires every referenced file and dependency module, rejects cycles,
rejects multiple primary owners and verifier owners, and sorts constructed sets
ordinally.

`scripts/get-module-manifest-catalog.ps1` writes or checks both tracked outputs.
An all-v0 fixture still emits the historical `module-manifest-catalog/v0` bytes
and no source catalog. Production emits `module-manifest-catalog/v1` plus
`capability-source-catalog/v1`. Both outputs use canonical UTF-8 without BOM
plus exactly one terminal LF, and `.gitattributes` pins both to `eol=lf`.
`-Check` validates both byte sequences with zero writes.

The v1 package closure and raw Git-index blob hashing contract are specified in
`capability-source.md`. `scripts/lib/Harness.CapabilitySource.psm1` is a strict,
read-only consumer of the current dual catalogs. It provides no installation,
activation, Runtime, task-state, or authorization path.

`scripts/run-validation.ps1` derives quick, full, and the five stable CoreGroups
from that catalog. `scripts/run-changed-optional-validation.ps1` derives its eight
module routes from the same catalog. Both construct and byte-check the catalog
before scheduling any verifier. The fail-closed contract is exact: any
construction failure must execute zero tests. This includes Schema, reference,
dependency, ownership, and catalog-drift failures.

The 13 mixed-version modules cover the five CoreGroups, eight existing optional
routes, and a separate `legacy-v1` marker. The marker has
`default_activation: false` and names only the four active Sunset-gated
compatibility paths. TK-02 neither deletes those paths nor executes a Sunset
gate.

The TK-00 fixtures cover a valid capability plus unknown fields, invalid id,
path escape, backslash path, invalid kind, legacy default activation, adapter
task-state write, capability Kernel Policy ownership, Kernel capability write,
and duplicate owned path. TK-02 adds constructed-set fixtures for a valid
dependency, a missing dependency, a cycle, overlapping primary ownership, and
multiple verifier owners. TK-04 adds mixed v0/v1, strict v1 Schema, package
role, classification-owner, Git-index source closure, stale-catalog, and Release
sidecar fixtures.
