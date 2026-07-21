# Entry Contract Bootstrap

Bootstrap only; routes/lifecycle stay lazy.

- `protocol_default`: `auto`
- `auto_resolves_to`: `existing-artifact-or-gated-v2-new`
- `v2_entry_activation`: `explicit-new-or-existing-v2-or-eligible-auto-new`

- New identity/artifact-free: use host/user-surfaced `HARNESS_PROTOCOL`; else read its process value once; never guess. `v2` is the first complete routing hop: classify inline; no task `status`/`protocol`, nested shim, or task/runtime/current inspection. Selected v2 Direct loads no `entry-router`, `orchestrator`, lifecycle skill, Memory, Team, or Provider; hand off now.
- Otherwise resolve once. Known: exactly one `.assistant\entry\task.ps1 protocol -TaskId {task_id}`; v2 `task.json` wins, then v1 `plan.md`. New `auto`: exactly one `.assistant\entry\task.ps1 protocol`; all-pass rollout selects v2, else v1. Detection never fans out to status/nested/runtime/lifecycle. After selection, existing v2 may use scoped status/resume; v1 may load its shim. Invalid evidence fails closed.
- An unresolved Requirement or product decision blocks every write and enters Ask. Protected/expanded/non-Direct reroute before writes.
- A public-contract change found outside confirmed scope stays unresolved until the user explicitly confirms this change; continuation alone enters Ask and authorizes no write.
- Clear Direct: relevant targets -> minimum edit -> minimum focused checks covering all confirmed acceptance criteria -> one bounded diff/self-review -> report. Stop only when all required checks pass. Expand only after failure/ambiguity. No task/runtime/current/lifecycle writes.
- Read-only work performs zero writes. Report actual commands/results, self-review, gaps; `not_run`/unavailable is not pass.
- Only a detector-selected v1 request loads `entry-router`; missing compatibility fails closed; then `orchestrator` + one stage skill.
