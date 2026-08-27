# Harness Hashing Contract

## Status

TK-01A makes `scripts/lib/Harness.Hashing.psm1` the canonical K0 hashing
primitive. Its public surface is exactly four independent functions, not one
parameter-set function and not five functions:

1. `Get-HarnessSha256Bytes`
2. `Get-HarnessFileSha256`
3. `Get-HarnessUtf8TextSha256`
4. `Get-HarnessNormalizedTextSha256`

Every function returns `sha256:` followed by exactly 64 lowercase hexadecimal
characters. This module owns raw SHA-256 byte selection only; it does not define
an object serialization or a canonical JSON algorithm.

## Byte contracts

| Function | Bytes hashed |
| --- | --- |
| `Get-HarnessSha256Bytes` | The supplied byte array, including an empty array. |
| `Get-HarnessFileSha256` | The file's exact bytes, including any BOM and original line endings. |
| `Get-HarnessUtf8TextSha256` | The supplied .NET string encoded as UTF-8 without a BOM, with no newline or whitespace normalization. |
| `Get-HarnessNormalizedTextSha256` | The normalized string defined below, encoded as UTF-8 without a BOM. |

`Get-HarnessFileSha256` rejects a missing path or a path that is not a file.
Path authorization, Workspace containment, and reparse rejection remain caller
responsibilities; `Get-HarnessFileDigest` in `Harness.AtomicWrite.psm1` retains
those existing checks and its existing missing-file result.

## NormalizedText/v1

NormalizedText performs these operations in order:

1. Replace every CRLF pair with LF.
2. Replace every remaining lone CR with LF.
3. Remove only CR and LF characters from the end of the resulting string.
4. Append exactly one LF.
5. Encode the result as UTF-8 without a BOM and hash those bytes.

Spaces and Tabs are never trimmed. For example, text ending in `SPACE TAB CRLF`
hashes bytes ending in `SPACE TAB LF`. Empty text and text containing only line
endings both hash the single byte `0A`.

## TK-01A compatibility migration

The first migration wave is deliberately limited to K0/K1 callers:

- `Harness.AtomicWrite.psm1` keeps `Get-HarnessSha256Text` and
  `Get-HarnessFileDigest` as compatibility APIs and delegates their final hash;
- `Harness.Requirement.psm1` keeps its existing `ConvertTo-Json -Compress`
  contract bytes and delegates only the final file or UTF-8 text hash;
- `Harness.RuntimeDefault.psm1` keeps its existing Source Identity and Runtime
  Default document bytes and delegates only the final byte or text hash.

Callers outside this wave retain their current implementations. In particular,
TK-01A does not migrate Release, Qualification, rollout, model-evaluation,
adapter, installer, uninstall, installation-transaction, generator, mutex, cache,
or test-only hashing.

## TK-01B-Compat migration

TK-01B-Compat completes production raw SHA-256 centralization without defining
an object serializer. Release, Qualification-contract, rollout,
model-evaluation, adapter, generator, installer, installation-transaction,
benchmark, mutex, cache, and telemetry callers keep their existing byte
construction and delegate only their final SHA-256 operation to the four K0
functions.

Legacy representations remain unchanged. Callers that historically emitted a
bare lowercase hexadecimal value continue to remove the `sha256:` prefix only
after hashing. Comparison-only file hashes continue to compare exact file bytes.
Existing `ConvertTo-Json` depth, compression, property order, domain prefixes,
newlines, and UTF-8 behavior remain owned by their current object-specific
callers.

`Harness.AtomicWrite.psm1` retains `Get-HarnessSha256Text` and
`Get-HarnessFileDigest` as compatibility APIs. Temporary first-wave forwarding
functions in Requirement and Runtime Default are removed after their callers
bind directly to Hashing. Production PowerShell outside `Harness.Hashing.psm1`
must not execute SHA-256 directly.

## TK-01B-New canonical JSON

TK-01B-New is implemented as the separate
`scripts/lib/Harness.CanonicalJson.psm1` K0 primitive. Its approved
`canonical-json/v1` byte semantics and exact two-function API are frozen in
`canonical-json-contract.md`. Hashing remains a four-function raw SHA-256
primitive and contains no object serializer.

Canonical JSON is opt-in only for a new Schema or Envelope, or when an object's
contract explicitly selects that `digest_algorithm`. No generic digest router
or business Envelope is introduced by TK-01B-New.

No existing Evidence, Receipt, Approval, Contract, Manifest, Installed Asset,
Source Identity, Task State, or installation-transaction digest is silently
reinterpreted as canonical JSON.
