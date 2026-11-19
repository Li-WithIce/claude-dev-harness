# Entry Contract Bootstrap

Bootstrap only; routes/lifecycle stay lazy.

- `protocol_default`: `auto`
- `auto_resolves_to`: `existing-v2-or-admitted-v2-new-task`
- `v2_entry_activation`: `v2-only-with-new-work-admission`

- New identity/artifact-free: use host/user-surfaced `HARNESS_PROTOCOL`; else read its process value once; never guess. Resolve admission once via `.assistant\entry\task.ps1 protocol`: only `auto|v2`; `new_work=paused` blocks new work; missing Runtime Default admits v2, invalid/unavailable blocks. No task `status`, nested shim, or task/runtime/current inspection.
- Known identity: `.assistant\entry\task.ps1 protocol -TaskId {task_id}`; valid v2 state wins and may status/resume. Legacy artifacts require explicit migration; do not read or resume. v1/invalid fails closed.
- After admission classify inline. Selected v2 Direct loads no `entry-router`, `orchestrator`, lifecycle skill, Memory, Team, or Provider; hand off now. No status/runtime/lifecycle fan-out.
- If PROJECT.md declares `harness_continuity: enabled`, follow its linked context/record/operation rules before development, resume or compaction recovery. No opt-in: no change.
- Unresolved Requirement or product decision enters Ask; opted-in projects may save a `pending clarification` draft in change records (original request, known source/date, unanswered questions only). Ask and all other writes stay blocked. Protected/expanded/non-Direct reroute before writes.
- Out-of-scope public-contract changes require explicit confirmation; continuation alone enters Ask and authorizes no write.
- Clear Direct: minimum edit -> minimum focused checks covering all confirmed acceptance criteria -> one bounded diff/self-review -> report. Stop only when all required checks pass. Expand only after failure/ambiguity. No task/runtime/current/lifecycle writes.
- Read-only work performs zero writes. Report actual commands/results, self-review, gaps; `not_run`/unavailable is not pass.
- Legacy lifecycle and shim loading are retired. Stop-loss pauses new work; recovery uses v2. History/migration needs explicit authorization.
