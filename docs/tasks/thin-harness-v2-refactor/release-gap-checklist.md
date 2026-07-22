# Thin Harness v2 Release Qualification Checklist

> Historical qualification snapshot with a current interpretation. The public v2 opt-in engineering milestone and the Default Promotion / Stable milestone are separate. Unchecked Model/Host/performance/release/promotion items in sections A-D are later qualification work and are not pass; the documentation and independent-review closure items in section E and the final section remain required for RQ-34 until they are actually recorded complete.

> Attachment only. `plan.md` remains the sole Master Plan and stage truth.
>
> Qualification base: `codex/harness-distribution@aee525f6b3b0638f11bf6ab278482aa5b8c79d11`
> Qualification start: `codex/thin-harness-v2-refactor@a061cacf3a9c32b3b96d0fb32810085fc3031064`
> Ordinary source implementation evidence head: `codex/thin-harness-v2-refactor@acccb30d4ecc0d61ff2ad5b36f3f2cc3a0f5425a` (Master Plan Runs 107-109). Later process-document commits do not supply or refresh promotion qualification.
> RQ-34 opt-in closure candidate: dirty tree based on `4ff92a325e4956150ad7e4ad4a0aa69c3fb3f542`; current local evidence is recorded in Master Plan Runs 116-117 and Code Review Run 8. Final commit and exact-head ordinary CI are still pending and do not retroactively satisfy promotion qualification.

## Current milestone interpretation

- Public opt-in engineering covers Requirement Gate, execution profiles, v2 Task State / Evidence / Approval / Audit, v1/v2 coexistence and rollback, the three install presets, ordinary CI and public documentation.
- Default Promotion / Stable still requires current-HEAD Model40, real cognitive/installed Host 3×3, `v2/bare <= 1.25`, Installed Desktop Gate, an eligible promoted rollout report, Auto default flip and Canary / Stable. Physical removal of v1 is a later retirement milestone that requires separate authorization after Stable.
- Regardless of milestone status, Auto without an eligible report selects v1, explicit v2 remains available, and existing v1/v2 tasks remain artifact-first.

## A. CI and release proof

- [x] Local ordinary-engineering coverage is included in the final RQ-34 `Suite all`; this is not promotion qualification.
- [x] Local `Suite all` exits `0` with top-level `STATUS: PASS` on the final dirty RQ-34 candidate (Run 117; log SHA-256 `402c3911f9ac324dfb73995e284e7d8e60acd7dfdcb1d0b11dfd6fa68142c373`), while retaining one dynamic SUBST `[UNAVAILABLE]` and one explicit no-WorkspaceRoot install SKIP; neither is promotion pass.
- [x] Isolated core, governed and full install/verify/update/second-verify/uninstall/cleanup all exit `0` on the final dirty RQ-34 candidate (Run 117).
- [x] Draft PR targets `codex/harness-distribution`.
- [x] `pr-core` and `changed-optional` complete successfully for process-document head `4ff92a3...` (run `29818578961`); release jobs were skipped.
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
- [x] README, CHANGELOG, install/enable/rollback, `task.ps1`, Requirement, profiles, Evidence, Approval, migration, presets, rollout, and troubleshooting reflect the current public opt-in behavior while keeping Default Promotion / Stable pending.
- [x] New installation defaults to core; existing installation preserves features; model remains inherit.

## Independent review and finish boundary

- [x] Fresh isolated read-only reviewer receives base diff, Master Plan, tests, and Evidence without implementation-session conclusions (Code Review Run 8: `fork_turns=none`, `gpt-5.6-sol/max`).
- [x] All P0/P1 and evidenced P2 findings are fixed and affected validation is rerun; Code Review Run 8 reports `findings: none`.
- [ ] Final branch/base/status/remote/CI evidence is recorded; no merge is performed.
