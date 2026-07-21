# Thin Harness v2 Release Qualification Checklist

> Historical qualification snapshot. Master Plan Runs 112-113 removed formal release qualification from the public Harness completion boundary; unchecked items below are optional release-engineering work, not current delivery blockers.

> Attachment only. `plan.md` remains the sole Master Plan and stage truth.
>
> Qualification base: `codex/harness-distribution@aee525f6b3b0638f11bf6ab278482aa5b8c79d11`
> Qualification start: `codex/thin-harness-v2-refactor@a061cacf3a9c32b3b96d0fb32810085fc3031064`

## A. CI and release proof

- [x] Local `Suite core` passes on the final revision.
- [x] Local `Suite all` passes on the final revision.
- [x] Isolated core and full install/update/uninstall rollback pass.
- [x] Draft PR targets `codex/harness-distribution`.
- [x] `pr-core` and `changed-optional` complete successfully.
- [ ] Manual `release-full` completes and publishes its revision-bound report.

## B. Real model-in-the-loop evaluation

- [x] Deterministic policy/schema Eval remains available.
- [ ] Every scenario paraphrase is sent to a fresh isolated ephemeral Codex session.
- [ ] Actual model is `gpt-5.6-sol`; reasoning is `max`; unavailable is never simulated.
- [ ] `critical_missed_ask=0`, `read_only_write=0`, and `false_pass=0`.
- [ ] `unnecessary_ask`, profile, scope, lifecycle-skill, verification, and completion observations are recorded without full prompts or credentials.

## C. Measured bare/v1/v2 performance

- [ ] Same semantic task, model, reasoning, isolation, and fresh-session conditions are used.
- [ ] Host latency is distinguished from fixture replay.
- [ ] Available turns, tool calls, file/skill loads, writes, tokens, and timing are recorded; unavailable values remain unavailable.
- [ ] Measured `v2/bare <= 1.25`.
- [ ] Measured v2 round trips improve by at least 60% versus v1.

## D. Rollout delivery chain

The checkboxes in this section record final-candidate engineering contracts only. They do not mean that `release-full` produced an eligible artifact, that a production workspace was promoted, or that v2 is Stable.

- [ ] Release CI generates and persists the report outside its own source digest.
- [x] The explicit offline promotion entry publishes the report to the canonical workspace path; install, update, and uninstall preserve it without owning, generating, publishing, restoring, or deleting it.
- [x] `auto` discovers the canonical report without a required environment variable.
- [x] Missing, stale, tampered, failed, blocked, simulated, or unavailable evidence selects v1.
- [x] Existing v1/v2 tasks remain artifact-first; no implicit migration occurs.
- [x] `HARNESS_PROTOCOL=v1` remains the immediate rollback switch; v1 is not removed.

## E. Pre-release robustness and documentation

- [x] Invalid v2 UTF-8, schema, or task identity returns `invalid-v2-artifact` and blocks fallback.
- [x] Protected Actions has a fail-closed workspace overlay and environment-aware extension contract, while core is documented as two built-in rules only.
- [ ] README, CHANGELOG, install/enable/rollback, `task.ps1`, Requirement, profiles, Evidence, Approval, migration, presets, rollout, and troubleshooting reflect current behavior.
- [x] New installation defaults to core; existing installation preserves features; model remains inherit.

## Independent review and finish boundary

- [ ] Fresh isolated read-only reviewer receives base diff, Master Plan, tests, and Evidence without implementation-session conclusions.
- [ ] All P0/P1 and evidenced P2 findings are fixed and affected validation is rerun.
- [ ] Final branch/base/status/remote/CI evidence is recorded; no merge is performed.
