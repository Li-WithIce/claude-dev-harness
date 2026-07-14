---
name: planning
description: Use only when a v2 task policy requires a durable governed plan.
---

# Planning

Use this capability only when `.assistant/runtime/tasks/{task_id}/task.json` has
`policies.plan_required: true`.

Complete the generated `docs/tasks/{task_id}/plan.md` without changing its
`task_id` or `contract_digest` binding. Replace every `<fill-...>` placeholder
and keep the Goal, Scope, Implementation, Verification, and Rollback sections
substantive. This capability does not create or advance workflow stages.

When `plan_required` is false, do not create `plan.md` and do not load this
capability as ceremony.
