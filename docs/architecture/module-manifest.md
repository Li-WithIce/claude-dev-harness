# Module Manifest Phase 0 Contract

## Status and authority

Manifest Phase 0 uses `schema_version: harness-module/v0`. The phase name and
Schema version must not be described as Phase 0 plus `harness-module/v1`.
TK-00 defines `schemas/module-manifest.schema.json` and fixtures only. It does
not create a real module manifest, discovery router, installer, activator, or
permission grant.

Phase 0 is a construction-input contract for discovery, ownership, watch paths,
validation ownership, changed-path routing, dependencies, entrypoints, and
requested capability declarations. It does not drive installation, activation,
default profiles, Protected Action changes, write permission, or Kernel identity.

## Required shape

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

A future `Harness.Hashing.psm1` would therefore be owned by Kernel and watched by
release-evidence, distribution, and task-state. TK-00 does not create it.

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

## Future discovery safety

A future implementation must require each manifest to be a tracked regular file,
reject reparse or symlink aliases, enforce unique module ids, require referenced
files and dependency modules, reject dependency cycles and multiple primary
owners, sort output ordinally, and execute zero tests after any Schema or
construction failure. Phase 0 does not implement that router.

The TK-00 fixtures cover a valid capability plus unknown fields, invalid id,
path escape, backslash path, invalid kind, legacy default activation, adapter
task-state write, capability Kernel Policy ownership, Kernel capability write,
and duplicate owned path.
