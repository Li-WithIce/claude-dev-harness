# Subtask Roadmap Artifact

`subtasks.yaml` and `docs/roadmaps/<slug>/items.yaml` are optional advisory-only artifacts for large roadmap work, parent/child task breakdowns, and dependency-heavy delivery plans. They help humans and agents see the decomposition without turning the decomposition into a scheduler or a second task truth source.

## When To Use

- A single parent task needs multiple child tasks with dependencies or acceptance criteria.
- A roadmap spans several `docs/tasks/<task-id>/` tasks and needs a stable list of items.
- A task has enough moving pieces that TEST/Handoff should record what remains split out.
- Do not create this artifact for ordinary single-task work or as a replacement for `task-entity.yaml`.

## Paths And Declaration

- Task-local path: `docs/tasks/<task-id>/subtasks.yaml`.
- Cross-task roadmap path: `docs/roadmaps/<slug>/items.yaml`.
- If either path is created, it must be listed in the same task's `plan.md` `## Plan` `artifacts:` inline array.
- `task-entity.yaml` records single-task metadata such as owner, branch, parent, children, and external refs. A subtask roadmap records breakdown items, dependencies, acceptance criteria, artifact links, and open gaps.
- Old tasks do not need to backfill this artifact.

## Advisory-Only Boundary

- `plan.md` frontmatter remains the only stage/tool truth.
- Append-only Plan Review / Code Review runs remain the only review verdict source.
- `test.md` remains the final validation conclusion and Handoff report.
- `subtasks.yaml` and roadmap items do not drive `advance-stage.ps1`, runtime pointers, team boards, workflow descriptors, skill manifests, validator hard gates, queues, schedulers, PR automation, or worktree automation.
- Validator only reports existing artifact drift advisory warnings for declared or changed paths. It does not parse roadmap schema or item status.

## Recommended Fields

```yaml
schema_version: 1
summary: "roadmap or parent task summary"
owner: "optional owner or team"
items:
  - id: "item-1"
    task_id: "optional-docs-task-id"
    title: "short item title"
    type: "task | doc | feature | bug | refactor | explore | maintenance"
    depends_on: []
    acceptance:
      - "observable completion criterion"
    artifacts:
      - "docs/tasks/<task-id>/plan.md"
    notes: "optional context"
    open_gaps: []
forbidden:
  - stage
  - status
  - verdict
  - tool
  - current_phase
  - next_action
  - active_task
  - current_pointer
  - handoff_conclusion
  - done
```

## Forbidden Fields

Do not write fields that create a second task truth source:

- `stage`
- `status`
- `verdict`
- `tool`
- `current_phase`
- `next_action`
- `active_task`
- `current_pointer`
- `handoff_conclusion`
- `done`

Avoid item-level `state`, `progress`, `percent`, or `complete` fields unless a future reviewed task defines them as advisory-only. Until then, completion remains in each child task's `plan.md` and `test.md`.

## Review And Test Expectations

- PLAN_REVIEW checks whether the task really needs a subtask roadmap, whether the artifact is declared in `artifacts:`, and whether it stays advisory-only.
- CODE_REVIEW checks whether the file exists when declared, whether it only records breakdown/dependencies/acceptance/artifacts/open gaps, and whether it avoids second-truth fields.
- TEST/Handoff records whether the artifact was delivered, whether dependencies and acceptance criteria are reviewable, and whether remaining open gaps need separate workflow tasks.
