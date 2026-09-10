# Harness Canonical JSON Contract

## Status and API

TK-01B-New defines `canonical-json/v1` as an RFC 8785-compatible strict
safe-integer profile. `scripts/lib/Harness.CanonicalJson.psm1` is the canonical
K0 implementation and exports exactly two functions:

1. `ConvertTo-HarnessCanonicalJsonBytes`
2. `Get-HarnessCanonicalJsonSha256`

Both functions accept `JsonBytes` as a raw byte array. They never accept a
PowerShell object, because object conversion can erase duplicate names, number
spellings, and input encoding failures before the canonicalizer sees them.

## Input contract

Input must be one complete JSON value encoded as strict UTF-8 without a BOM.
The parser rejects:

- an initial UTF-8 BOM or malformed UTF-8;
- comments, trailing commas, incomplete input, or any other non-JSON syntax;
- nesting deeper than 64 JSON containers;
- duplicate decoded property names within the same object, including names
  whose different escape spellings decode to the same UTF-16 string;
- lone raw or escaped UTF-16 surrogates;
- a number outside the numeric profile below.

The top-level value may be any permitted JSON value. Duplicate-name comparison
is case-sensitive and ordinal.

## Strings and Unicode

Unicode scalar values are preserved exactly; no NFC, NFD, or other Unicode
normalization is performed. Quote and reverse solidus are escaped as `\"` and
`\\`. Backspace, Tab, LF, form feed, and CR use `\b`, `\t`, `\n`, `\f`, and
`\r`. Other U+0000 through U+001F controls use lowercase `\uhhhh`. Slash and
all other Unicode scalars are emitted as-is.

These rules are the string rules in RFC 8785. Consequently, escaped and raw
spellings of the same scalar converge, while canonically equivalent but
code-point-distinct Unicode strings remain byte-distinct.

## Objects and arrays

Every object's decoded property names are sorted recursively by unsigned UTF-16
code units using locale-independent ordinal comparison. Properties of objects
inside arrays are sorted by the same rule. Array element order is never changed.

## Safe-integer number profile

JSON number text is parsed as an IEEE 754 binary64 value, matching the RFC 8785
data model. The parsed value is accepted only when it is finite, integral, and
within the inclusive range `-9007199254740991` through `9007199254740991`.
Accepted numbers are emitted as ordinary base-10 integers without exponent,
decimal point, or leading zero. Positive and negative zero both emit `0`.

Fractions, unsafe integers, infinities produced by overflow, and other values
outside this profile fail closed. New schemas must represent decimal,
high-precision, or longer-integer values as JSON strings with their own schema
semantics.

## Output and digest

Output is the compact canonical JSON representation encoded as exact UTF-8 without a BOM.
No insignificant whitespace or terminal LF is emitted. For example, an empty
object is exactly the two bytes `7B 7D`.

`Get-HarnessCanonicalJsonSha256` passes only those exact canonical bytes to
`Get-HarnessSha256Bytes`. Its result is `sha256:` followed by 64 lowercase
hexadecimal characters. `Harness.CanonicalJson` contains no parallel SHA-256
implementation, and `Harness.Hashing` retains its exact four-function surface.

## Adoption and compatibility boundary

`canonical-json/v1` is opt-in for a new Schema or Envelope, or for an object
whose contract explicitly selects that `digest_algorithm`. TK-01B-New does not
add a generic algorithm router and does not create a business Envelope. TK-02 is
the first explicit adopter: the new Manifest catalog contract hashes each
`harness-module/v0` source after canonicalization and emits its own canonical
catalog bytes. TK-04 adds only new Manifest v1, Capability source closure, and
Release sidecar objects that explicitly declare `canonical-json/v1`; it does
not reinterpret any historical report or receipt.

No pre-TK-02 Evidence, Receipt, Approval, Requirement Contract, Installed Asset,
Source Identity, Task State, installation transaction, Release, Qualification,
rollout, benchmark, or model-evaluation byte sequence or digest is reinterpreted.
Those historical algorithms remain with their current owners.

The primitive is classified as K0. At TK-04, no selected Runtime or Distribution
root reached the C2 engineering construction or Release sidecar callers.
TK-06 explicitly adopts it for the new `install-profile/v1` and
`distribution-plan/v1` contracts. It is now reached by Distribution, but not
by any selected Runtime root. Existing installation, transaction and history
digests retain their algorithms; see `declarative-distribution.md`.
