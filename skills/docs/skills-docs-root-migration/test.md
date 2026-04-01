# Test Report

## Meta

- **task_id**: skills-docs-root-migration
- **task_name**: Skills docs root migration
- **tested_by**: Codex
- **date**: 2026-03-14

## Summary

This TEST round validated the recent fixes that moved two known residues from `spec/<task-id>` to `docs/<task-id>`. The targeted fixes passed, but a wider regression scan found additional relevant residues outside the two edited files, so the migration is not yet complete.

## Scope

- Verify `orchestrator/references/examples.md` now uses `docs/<task-id>` consistently in the repaired examples.
- Verify `gemini-designer-main/scripts/ask_gemini.sh` help text now uses `docs/<task-id>`.
- Run repo-wide scans for remaining `spec/<task-id>` style residues that still affect generated development-document roots.

## Inputs Reviewed

- User request in this thread: all generated development-related documents should use the `docs/<task-id>` root.
- `orchestrator/references/examples.md`
- `gemini-designer-main/scripts/ask_gemini.sh`
- `.claude/settings.local.json`
- `docs/skill-consolidation/review.md`
- `docs/skills-docs-root-migration/logs/test-run.log`

## Test Approach

- Preflight the TEST primary runner. In this environment, Gemini could not be used because `bash` and `jq` are unavailable and no Gemini API key is configured, so validation ran as Codex fallback.
- Run positive checks on the two edited files to confirm the new `docs/...` paths are present where expected.
- Run a narrow negative scan for old task-scoped artifact paths such as `spec/<task-id>/spec.md` and `spec/<task-id>/test.md`.
- Run a wider `spec/<slug>/` scan and inspect the relevant hits to separate real artifact-root residues from harmless mentions of skill names like `spec/plan/review/test`.

## Findings

1. `orchestrator/references/examples.md` passed the targeted regression check. The repaired examples now consistently reference `docs/auth-login-v2/...`, including `artifact_root`, `spec_path`, test log paths, and `gemini_output_path`.
2. `gemini-designer-main/scripts/ask_gemini.sh` passed the targeted regression check. Its embedded help example now points to `docs/task-123/spec.md`, `plan.md`, `review.md`, and `test.md`.
3. The narrow repo-wide scan for old task-scoped artifact patterns returned no matches.
4. The wider scan still found relevant old-root residues:
   - `.claude/settings.local.json:24` contains an active sync command that still copies `spec/skill-consolidation/` and prints `spec/skill-consolidation synced`.
   - `docs/skill-consolidation/review.md` still records prior task artifacts under `spec/skill-consolidation/`, including `related_spec`, `related_plan`, `related_implementation_notes`, scope text, and artifact presence notes.
5. Some wider-scan hits were intentionally excluded from failure triage because they only name the `spec`/`plan`/`review`/`test` skills rather than referencing artifact roots.

## Risks / Gaps

- This workspace is not a git repository, so verification was performed against current filesystem content rather than a VCS diff.
- No formal task-scoped `spec.md`, `plan.md`, or `review.md` existed for this retroactive migration task; acceptance was derived from the user request and the observed residues.
- The runtime network behavior of `ask_gemini.sh` was not exercised in this round. Validation covered path examples and repository references only.

## Conclusion

fail

The targeted fixes are correct, but the overall migration still fails this TEST round because old `spec/<task-id>` roots remain in active local settings and historical task artifacts.
