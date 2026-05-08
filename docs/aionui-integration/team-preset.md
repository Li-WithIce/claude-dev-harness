# Team Preset Contract

## Scope

- 本文档只描述 harness 侧导出的 team preset 契约
- 本仓库不修改 AionUi 代码
- AionUi 端可读取 preset 后逐个调用 `team_spawn_agent`

## Exported preset shape

`scripts/export-team-preset.ps1` 输出以下结构：

```yaml
name: harness-lite
version: 1
single_writer:
  owner: leader
  members_read_only_path_prefixes:
    - .assistant/
    - docs/tasks/<task-id>/
members:
  - role: plan-author
    backend: codex
    model: gpt-5.5/xhigh
    skills_whitelist: [plan, using-superpowers]
    role_prompt_ref: agent-configs/role-prompts/plan-author.md
```

## Consumption guidance

- 先读取 preset
- 再按 `members` 顺序调用 `team_spawn_agent`
- `role_prompt_ref` 由 leader 在 spawn 时读取，作为 system prompt seed
- `members_read_only_path_prefixes` 表示 member 的只读保护集合

## Shared-memory authority

- team-mode 下，leader 视为 `entry_host = team-leader`
- leader 是共享运行时（`.assistant/运行时/当前任务.md`、`恢复索引.md` 等）的唯一写者
- spawned member 只写 `运行时/tasks/<task-id>.md` 与 `docs/tasks/<task-id>/`
- `team_task_update` 是 vault 的镜像，不回写 vault 真相字段
- 4 层真相源关系见 `docs/shared-memory-layers.md`

## spawn-team payload

`skills/workflow-team/scripts/spawn-team.ps1` 为每个 member 构造如下 payload：

```json
{
  "task_id": "<task-id>",
  "workflow": "harness-lite",
  "role": "plan-author",
  "backend": "codex",
  "model": "gpt-5.5/xhigh",
  "system_prompt": "<contents of role_prompt_ref>",
  "skills_whitelist": ["plan", "using-superpowers"],
  "members_read_only_path_prefixes": [".assistant/", "docs/tasks/<task-id>/"]
}
```

这是 harness 侧的约定。AionUi 端若需要额外字段，应在消费层补足，而不是回写静态 preset。
