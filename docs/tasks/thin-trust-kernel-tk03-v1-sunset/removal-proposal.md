# Exact retained-source removal proposal (not applied)

Status: blocked on all ten current-head Sunset gates and a separate user
approval of this exact diff. No physical source deletion is part of the
current implementation, and no immediate approval is requested while those
prerequisites remain unmet.

The bounded first candidate is
`proposed-stage-body-removal.patch`. It removes the unreachable historical
implementation of `scripts/advance-stage.ps1` while keeping its parameter
surface and early zero-write `v1-lifecycle-retired` rejection. The old entry
therefore remains fail-closed for a stale caller. This candidate is not a
complete v1 source purge or retirement of the migration bridge.

| Binding | Value |
|---|---|
| Exact target | scripts/advance-stage.ps1 |
| Preimage index blob | 0491c944b00cdd3aa474270eba29f597feca8b61 |
| Current working-file raw SHA-256 | sha256:5cf1f0b2336570511956ddf83a54b1a5792536d8809a0e874a2b8e753572ce27 |
| Patch raw SHA-256 | sha256:8844112354d9fcf4d35cfcee2df00c13d57b6fd647184fe36808866e17fc7e58 |
| Before / proposed after lines | 1467 / 34 |
| Application | not_run |

Preflight uses `git apply --cached --check` only. It checks the exact staged
source without applying the patch or changing the index. The patch must be
regenerated and independently reviewed if its preimage changes; the digest
alone cannot authorize a later source version.

The file remains owned by the inactive legacy-v1 module and outside Runtime
TCB and Capability/v1 source receipts. The proposal does not change any
Manifest path, active test route, historical Schema, receipt or digest
algorithm. After a separately authorized application, rerun Sunset, TCB,
catalog, complete isolated Suite all and ordinary exact-head CI; passing
preflight is not passing post-removal validation.

Still retained, requiring their own current exact diffs after the gates:
the migration command/parser, legacy artifact validators and fixtures,
historical templates, retired Stage delegation/Team implementation, and the
unreachable Memory repair/identity bodies. Historical task plans, Evidence,
receipts, DONE histories and actual `.qoder` are excluded from every deletion
proposal. No blanket source deletion or migration-tool retirement is implied.
