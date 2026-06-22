# Task Entity Artifact

`task-entity.yaml` 是可选的任务元数据 artifact，用来承载不适合塞进 `plan.md` frontmatter 的恢复与协作信息。

## 定位

- 推荐路径：`docs/tasks/<task-id>/task-entity.yaml`
- 启用方式：在同任务 `plan.md` 的 `## Plan` metadata 中声明 `artifacts: [docs/tasks/<task-id>/task-entity.yaml]`
- 适用场景：大型任务、跨分支任务、涉及外部 issue / PR / commit、需要 parent/children 或 related files 恢复信息的任务
- 旧任务兼容：旧任务不需要回填；缺少 `task-entity.yaml` 不视为缺陷

## Truth Boundary

`task-entity.yaml` 是 advisory-only metadata。它不参与阶段推进、任务完成判定或工具选择。

唯一阶段真相源仍是 `plan.md` frontmatter：

- `stage`
- `tool`
- `tool_profile`
- `model`
- `updated`

append-only run 仍是 review/test 判定来源：

- `Plan Review` / `Code Review` 的最新 `verdict`
- `test.md` 的 `Conclusion`

`.assistant/运行时/*` 仍是 derived mirror。`skill-manifest.json` 仍是 best-effort stage skill manifest。team board 仍是运行时协作面。`task-entity.yaml` 不反向更新这些文件。

## Allowed Fields

推荐字段为：

```yaml
schema_version: task-entity/v1
summary: One-line task summary.
owner: codex
priority: high
branch: feature/task-entity
base_branch: main
worktree_path: ""
pr_url: ""
commit: ""
parent: ""
children: []
related_files: []
external_refs:
  issues: []
  docs: []
meta:
  linear_id: ""
  jira_ticket: ""
notes: []
```

字段含义：

- `schema_version`: 当前固定建议值 `task-entity/v1`
- `summary`: 人读摘要，不替代 `plan.md` 标题或 Clarification
- `owner` / `priority`: 跨会话协作提示，不替代 team board
- `branch` / `base_branch` / `worktree_path`: 恢复或提交时的上下文提示，不自动创建 worktree
- `pr_url` / `commit`: 已有人为创建 PR 或 commit 后的记录，不触发 PR automation
- `parent` / `children`: 任务关系提示，不驱动 `advance-stage.ps1`
- `related_files`: 恢复时优先看的仓库路径
- `external_refs`: issue、设计稿、外部文档等引用
- `meta`: 低成本集成字段，例如 `linear_id`、`jira_ticket`
- `notes`: 不适合放进 plan 的短备注；不要写长流水

## Forbidden Fields

禁止写入任何会形成第二 truth 的字段，包括：

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

如果需要表达“下一步”，写在 `plan.md` 的 append-only run、`test.md` Handoff 或 team board，不写进 task entity。

## Review Rules

PLAN_REVIEW / CODE_REVIEW 应检查：

- `task-entity.yaml` 是否已在 `plan.md artifacts:` 中声明
- 字段是否只用于 advisory metadata
- 是否出现 forbidden fields
- 是否把 owner/priority/branch/PR 信息误写成 stage truth
- 是否与 `Change Contract.affected_paths`、Implementation Notes、TEST Handoff 自洽

validator 当前不解析 `task-entity.yaml` schema。既有 artifact drift advisory 只会提示已声明 artifact 是否存在、dirty path 是否未声明。

## Relationship To Trellis

本文件只吸收 Trellis task entity 的轻量元数据层，不复制 `.trellis/` runtime、active task pointer、workflow-state breadcrumb、dashboard、自动 PR、自动注入或多平台 runtime。
