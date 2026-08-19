# Entry Contract Bootstrap

Bootstrap only; routes/lifecycle stay lazy.

- `protocol_default`: `auto`
- `auto_resolves_to`: `existing-artifact-or-runtime-default-or-v1-fallback`
- `v2_entry_activation`: `explicit-or-workspace-new-or-existing-v2-or-runtime-default-new`

- New identity/artifact-free: use host/user-surfaced `HARNESS_PROTOCOL`; else read its process value once; never guess. `v2` is the first complete routing hop: classify inline; no task `status`/`protocol`, nested shim, or task/runtime/current inspection. Selected v2 Direct loads no `entry-router`, `orchestrator`, lifecycle skill, Memory, Team, or Provider; hand off now.
- Otherwise resolve once. Known: `.assistant\entry\task.ps1 protocol -TaskId {task_id}`; v2 state, else v1 plan, wins. New: `.assistant\entry\task.ps1 protocol`; config `v1|v2|auto`, then a valid Runtime Default Decision or v1 fallback. No status/runtime/lifecycle fan-out. Existing v2 may status/resume; v1 may load its shim. Invalid input fails closed.
- An unresolved Requirement or product decision blocks every write and enters Ask. Protected/expanded/non-Direct reroute before writes.
- A public-contract change found outside confirmed scope stays unresolved until the user explicitly confirms this change; continuation alone enters Ask and authorizes no write.
- Clear Direct: relevant targets -> minimum edit -> minimum focused checks covering all confirmed acceptance criteria -> one bounded diff/self-review -> report. Stop only when all required checks pass. Expand only after failure/ambiguity. No task/runtime/current/lifecycle writes.
- Read-only work performs zero writes. Report actual commands/results, self-review, gaps; `not_run`/unavailable is not pass.
- Only a detector-selected v1 request loads `entry-router`; missing compatibility fails closed; then `orchestrator` + one stage skill.
