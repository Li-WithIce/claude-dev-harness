---
task_id: phase4-team-preset-bridge
stage: FIX_REVIEW
reviewer: harness-reviewer
verdict: pass
---

# Fix Review — Phase 4 Team Preset Bridge

Scope: verify whether the four P1 findings raised in `code-review.md`
are closed by the fix landed in working tree (corresponds to `dc4ffe10`).
No implementation changes were made during this review.

## Verdict

**no findings** — all four P1 items from the prior code-review are closed.

## P1 closure status

### F1 — `scripts/export-team-preset.ps1` JSON / YAML export
**Status: closed.**

The previous `[ordered]@{ ... members = @($members) }` constructor crash
(`Argument types do not match`) is gone. Script now declares `$Output`
as a mandatory parameter and writes the rendered preset to a file.

- JSON: ran with explicit `-Output <tempfile>`, exit 0, file contents
  validate as JSON with the expected top-level schema (`name`,
  `version`, `single_writer.owner = leader`,
  `single_writer.members_read_only_path_prefixes = ['.assistant/',
  'docs/tasks/<task-id>/']`, `members[5]`, each member carrying
  `role`, `backend`, `model`, `skills_whitelist`, `role_prompt_ref`).
- YAML: same invocation with `-Format yaml`, exit 0, file contains
  `name: harness-lite`, the same `members_read_only_path_prefixes`
  list, and the five members in stage order.
- The five members emerge in the documented stage order:
  plan-author / plan-reviewer / implementer / code-reviewer / tester.
- Read-only path prefixes inside the preset match `docs/team-write-authority.md`
  byte-for-byte (verified by P5 in `verify-team-preset.ps1`).

Note (informational, not a finding): the script's contract changed —
output is now file-based via mandatory `-Output`, not stdout. The only
in-repo caller (`tests/verify-team-preset.ps1`) is updated to use the
new contract, so the change is internally consistent. README mentions
`export-team-preset.ps1` but does not pin a stdout contract, so this
is a private contract change between the script and its test.

### F2 — `tests/verify-team-preset.ps1` StrictMode crash
**Status: closed.**

Test now reaches the assertion body and emits structured `Checks:` /
`Failures:` output regardless of upstream success.

Run result:
```
Checks:
- P1 export-team-preset emits valid JSON/YAML with the expected top-level schema
- P2 preset members preserve the five workflow roles in stage order
- P3 preset backend/model values match each stage default_profile descriptor
- P4 preset skills_whitelist matches harness-lite workflow descriptor for every stage
- P5 role_prompt_ref paths exist and the read-only path prefixes stay byte-identical across preset and authority doc

Failures:
- none
EXIT: 0
```

No StrictMode `$preset.members` deref crash. Script now uses an
isolated repo fixture (`New-IsolatedRepoFixture`) and a wrapper that
collects stdout / stderr separately, which means a future export
failure surfaces as a clear `Add-Failure` message rather than a hard
crash. Prior null-deref class is no longer reachable.

### F3 — `tests/verify-team-orchestration.ps1` here-string / mock counting / payload log parsing
**Status: closed.**

Test executes through to the assertion body and reports all six O-checks
with no failures.

Run result:
```
Checks:
- O1 spawn-team fails closed when AIONUI_TEAM_MODE is unset and orchestrator keeps a documentation-only team-mode branch
- O2 spawn-team calls team_spawn_agent exactly five times in workflow stage order when env opt-in is enabled
- O3 spawn payload includes the expected role, backend, model, system prompt seed, and skills whitelist for every member
- O4 spawn-team stops on the first team_spawn_agent failure and returns single-line fallback JSON
- O5 single-writer protection stays aligned on the same two path prefixes across authority doc, role prompts, and static scan patterns
- O6 MCP availability does not bypass the env opt-in gate when AIONUI_TEAM_MODE is unset

Failures:
- none
EXIT: 0
```

The previous `@"..."@` here-string with undefined `$repo` is no longer
present in any reachable code path; the test now constructs static
sample code through here-strings that do not reference uninitialized
variables under StrictMode. O2/O3 confirm the spawn-call mock counts
to 5 and the payload-log parsing reads role / backend / model / system
prompt / skills_whitelist for every member. O1/O6 confirm fail-closed
when `AIONUI_TEAM_MODE` is unset, even with MCP available — i.e. env
gate is the single executable enforcement point.

### F4 — `verify-lite-footprint.ps1` UTF-8 BOM contract
**Status: closed.**

Footprint test exits 0; STATUS line reports PASS. The four new `.ps1`
files explicitly listed by the test now carry UTF-8 BOM:

- `scripts\export-team-preset.ps1 uses UTF-8 BOM`
- `scripts\generate-skills-index.ps1 uses UTF-8 BOM`
- `scripts\invoke-harness-skill.ps1 uses UTF-8 BOM`
- `skills\workflow-team\scripts\spawn-team.ps1 uses UTF-8 BOM`

No `Errors:` section content; the entire footprint contract passes.

## What I actually ran / read

Commands:
- `git log --oneline -20` — confirmed `dc4ffe10` is in working tree, not in committed history (workspace state, not a published commit).
- `git status --short` — confirmed phase-4 deltas (export script, role-prompts, workflow-team skill, four new tests) are still present.
- `pwsh -NoProfile -File scripts/export-team-preset.ps1 -Format json` — confirms `-Output` is mandatory (clean parameter error, not a constructor crash).
- `pwsh -NoProfile -Command "& ./scripts/export-team-preset.ps1 -Format json -Output <tmp>"` — exit 0; file content validates against expected JSON schema.
- `pwsh -NoProfile -Command "& ./scripts/export-team-preset.ps1 -Format yaml -Output <tmp>"` — exit 0; YAML output matches expected shape and key order.
- `pwsh -NoProfile -File tests/verify-team-preset.ps1` — exit 0; P1–P5 all pass.
- `pwsh -NoProfile -File tests/verify-team-orchestration.ps1` — exit 0; O1–O6 all pass.
- `pwsh -NoProfile -File tests/verify-lite-footprint.ps1` — exit 0; STATUS PASS; BOM checks include the four new `.ps1` files.

Files read:
- `scripts/export-team-preset.ps1` (parameter block, prefix constant, output writer)
- `tests/verify-team-preset.ps1` (export invocation surface, fixture wiring)
- `docs/tasks/phase4-team-preset-bridge/code-review.md` (P1 list to close against)

## Out of scope

- Commit `294bf604` is not pulled to mainline this round, per the
  Leader's prior instruction. This review is confined to the four P1
  items raised by `code-review.md` against the working-tree fix.
- No implementation modifications were made; this file is the only
  artifact produced by this review pass.
