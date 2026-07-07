# Context Provider vNext

Do not add a new skill until these conditions are true:

- V2/V3 references are repeated enough to create maintenance cost.
- At least 3 real workflow tasks prove stable provider routing triggers.
- Lazy-loading does not regress.
- Footprint, manifest, stage whitelist, profile, README inventory, and tests can be synchronized.
- Rollback is clear.

## Possible Future Files

- `skills/code-intel/SKILL.md`
- `skills/memory-provider/SKILL.md`
- `agent-configs/workflows/harness-lite.yaml`
- `agent-configs/profiles/harness-default-codex.yaml`
- README skill inventory
- `tests/verify-skill-manifest.ps1`
- `tests/verify-lite-footprint.ps1`

This document is evaluation only. This task must not add provider skills.
