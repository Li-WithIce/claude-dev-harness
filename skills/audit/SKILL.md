---
name: audit
description: Use only for a policy-required read-only independent review of v2 Evidence.
---

# Audit

Use this capability only when `.assistant/runtime/tasks/{task_id}/task.json` has
`policies.independent_review_required: true`. Task creation never starts a
reviewer and never generates `audit.md`.

The reviewer must use a context different from the implementer context, must
not have participated in the reviewed implementation, and must perform a
read-only review. The same base model is permitted for `isolated-context`;
`different-actor` additionally requires a different actor identity.

Create `docs/tasks/{task_id}/audit.md` from
`templates/v2/audit.md.template`. Bind it to the task id, pre-verification task
version, Contract digest, and exact digest of the resolved Evidence artifact.
The machine record between the marker comments must validate against
`schemas/audit-record.schema.json`. Set `reviewer_participated: false` only
when that is true.

Use `- none` when there are no findings. Every reported finding must use:

`- P0..P3: summary | evidence_path=<workspace-relative-file> | evidence_digest=<sha256>`

The referenced file must exist and its digest must match. Do not claim
independence, spawn a default reviewer, or write an audit on another actor's
behalf.
