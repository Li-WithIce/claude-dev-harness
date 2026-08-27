# Capability Source Closure Contract

## Scope

TK-04 binds each extracted C2 Capability to its exact tracked source without
changing any historical Release report, receipt, or digest algorithm. The new
objects are `capability-source/v1`, `capability-source-catalog/v1`, and the
separate `capability-source-binding/v1` Release sidecar. They are construction
and Evidence metadata only: none grants installation, activation, task-state,
Runtime, promotion, or rollout authority.

## Package source closure

For each production `harness-module/v1` Manifest, construction expands the four
disjoint package roles to concrete tracked regular files. The Manifest itself
is bound separately by `manifest_digest`. Every package file must match its Git
index bytes; an unstaged package edit fails before a digest can be produced.

Each `capability-source/v1` record contains:

- stable module id and version;
- the Manifest's `canonical-json/v1` digest;
- `digest_algorithm: canonical-json/v1`;
- `source_basis: git-index-blob/v1`;
- ordinally sorted `{ path, sha256 }` records, where SHA-256 is computed over
  the raw Git index blob stream;
- `source_digest`, computed over all preceding fields with
  `canonical-json/v1`.

The source catalog contains exactly the seven C2 Capability records, rejects a
file assigned to more than one module, records file-reference and unique-file
totals, and binds the complete record set with `catalog_digest`. The mixed
Manifest catalog includes that exact catalog digest. Both tracked catalogs are
UTF-8 without BOM with exactly one LF and are checked together with zero writes.

## Release binding sidecar

Existing model, host, and full Evidence files retain their historical Schemas
and bytes. Each current Release bundle adds one new deterministic sidecar:

- `model-capability-source-binding.json` binds the Benchmark and
  Release-Evidence source digests plus the three existing model artifacts;
- `host-capability-source-binding.json` binds the same two Capability sources
  plus the nine existing host artifacts;
- `full-capability-source-binding.json` binds Release-Evidence plus the four
  existing full artifacts.

Every sidecar records `source_revision`, the current source-catalog digest,
explicit `digest_algorithm: canonical-json/v1`, ordinal module-source and
artifact lists, raw artifact SHA-256 values, and a canonical `binding_digest`.
Only portable file names are serialized. The full writer first validates both
downloaded upstream sidecars, their exact source revision and source closure,
and every referenced artifact digest. A tampered or stale upstream bundle fails
closed.

Formal production requires a clean exact `HEAD`. `test-only` exists solely for
isolated fixtures and carries no release authority. Legacy Release bundle paths
are unchanged, and TK-04 does not execute Qualification, Promotion, Canary, or
Stable.
