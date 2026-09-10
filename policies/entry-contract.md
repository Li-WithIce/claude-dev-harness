# Entry Contract Bootstrap

Bootstrap only; routes/lifecycle stay lazy.

- `protocol_default`: `auto`
- `auto_resolves_to`: `existing-v2-or-admitted-v2-new-task`
- `v2_entry_activation`: `v2-only-with-new-work-admission`

- New identity/artifact-free: use host/user-surfaced `HARNESS_PROTOCOL`; else read its process value once; never guess. Resolve admission once with `.assistant\entry\task.ps1 protocol`: only `auto|v2` are supported. Workspace `new_work=paused` stops new work even with explicit v2; missing Runtime Default admits v2, invalid/unavailable decisions block. No task `status`, nested shim, or task/runtime/current inspection.
- Known identity: `.assistant\entry\task.ps1 protocol -TaskId {task_id}`; valid v2 state wins and may status/resume. Legacy artifact presence stops with an explicit-migration diagnostic, without reading its contents. Explicit v1 and invalid input fail closed. Never create, resume, or migrate a legacy task implicitly.
- After admission classify inline. Selected v2 Direct loads no `entry-router`, `orchestrator`, lifecycle skill, Memory, Team, or Provider; hand off now. No status/runtime/lifecycle fan-out.
- An unresolved Requirement or product decision blocks every write and enters Ask. Protected/expanded/non-Direct reroute before writes.
- A public-contract change found outside confirmed scope stays unresolved until the user explicitly confirms this change; continuation alone enters Ask and authorizes no write.
- Clear Direct: relevant targets -> minimum edit -> minimum focused checks covering all confirmed acceptance criteria -> one bounded diff/self-review -> report. Stop only when all required checks pass. Expand only after failure/ambiguity. No task/runtime/current/lifecycle writes.
- Read-only work performs zero writes. Report actual commands/results, self-review, gaps; `not_run`/unavailable is not pass.
- Legacy lifecycle and shim loading are retired. Stop-loss pauses new work; recovery uses v2. Explicit migration/history maintenance is isolated and requires its own authorization.
