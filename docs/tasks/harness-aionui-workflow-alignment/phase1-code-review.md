# Phase 1 Code Review: Tool Profile Foundation

## Findings

### P1 - Documented Change Contract skeleton uses a heading the validator rejects

`skills/plan/SKILL.md:92` and `skills/orchestrator/references/state-templates.md:31` tell agents to copy `## Change Contract  (optional, opt-in)`, but the validator only treats the exact section name `Change Contract` as optional (`scripts/validate-lite-artifacts.ps1:30`) and only removes exact-name sections before section-order validation (`scripts/validate-lite-artifacts.ps1:676`). It also only validates exact-name contracts at `scripts/validate-lite-artifacts.ps1:680`.

Effect: a plan created from the official skeleton with the optional section enabled will not be recognized as a legal optional section and will fail the `plan.md sections complete and ordered` contract before stage advancement. This is a truth-source conflict between the PLAN skill/state template and the validator. The format block in `skills/plan/SKILL.md:63` and `skills/orchestrator/references/lite-writing-guide.md:68` is correct, so the skeleton headings should be changed to exact `## Change Contract` or the validator should intentionally accept annotated headings.

### P2 - Local `.codex/skills` and `.gemini/skills` profile directories are not ignored

The Phase 1 profiles point at workspace-relative skill directories (`agent-configs/profiles/harness-default-codex.yaml:4`, `agent-configs/profiles/harness-default-gemini.yaml:4`), and the current worktree contains untracked `.codex/skills/...` and `.gemini/skills/...` junction contents. `.gitignore` only adds `/.claude/` (`.gitignore:33`) and omits the parallel Codex/Gemini local state directories.

Effect: `git status --untracked-files=all` exposes AionUi builtin skill files through `.codex/skills` and `.gemini/skills`, so a normal add could accidentally commit generated/user-local skill material and pollute the lite footprint. If these directories are valid local runtime state, add `/.codex/` and `/.gemini/` to the same ignore block; if they are not valid, remove the generated directories and avoid creating them under the repo root.

### P2 - Test cleanup failures are downgraded to warnings while tests still pass

The new test helpers retry `Remove-Item`, then only emit a warning if cleanup still fails (`tests/verify-tool-profile.ps1:47`, `tests/verify-change-contract.ps1:83`). The scripts then exit `0` whenever assertion failures are empty (`tests/verify-tool-profile.ps1:330`, `tests/verify-change-contract.ps1:327`). The same pattern was added to existing contract tests (`tests/verify-lite-artifact-validator.ps1:82`, `tests/verify-workflow-contracts.ps1:82`).

Effect observed during review: `verify-tool-profile.ps1`, `verify-change-contract.ps1`, `verify-lite-artifact-validator.ps1`, and `verify-workflow-contracts.ps1` all reported success while printing `cleanup skipped ... Access to the path 'plan.md' is denied`, leaving generated `docs/tasks/tool-profile-*`, `docs/tasks/change-contract-*`, and `docs/tasks/lite-*` fixtures in the worktree. That makes repeat validation state dirty and can mask cleanup regressions. Cleanup failures should either fail the test or the fixtures should be created outside the repo tree with deterministic cleanup.

## Open Questions / Assumptions

- I did not mark sticky profile carry-forward as a bug because `tests/verify-tool-profile.ps1` explicitly expects an existing profile/backend mismatch to block advancement. If users should be able to drop a profile at a stage boundary without hand-editing `plan.md`, the CLI needs a clear/unset path and tests.
- Profile descriptor validation currently checks only `name/backend/model`. If `skills_dirs`, `enabled_skills`, `disabled_builtin_skills`, and `context` are intended as AionUi-consumable contract fields in Phase 1, add schema coverage for them.
- `model` is intentionally treated as a syntactic full-ID check only; this review assumes provider/backend compatibility is out of scope for Phase 1.

## Change Summary

The implementation adds optional `tool_profile` / `model` frontmatter, default profile descriptors, validator and `advance-stage.ps1` support, runtime mirror writeback, entry shim parameters, README/orchestrator/skill docs, `tests/verify-tool-profile.ps1`, and related footprint/contract-test updates.

Targeted checks run:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-tool-profile.ps1` - pass, with cleanup warnings
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-change-contract.ps1` - pass, with cleanup warnings
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-lite-artifact-validator.ps1` - pass, with cleanup warnings
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-lite-footprint.ps1` - pass
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-workflow-contracts.ps1` - pass, with cleanup warnings
