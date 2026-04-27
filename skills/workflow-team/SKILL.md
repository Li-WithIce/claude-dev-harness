---
name: workflow-team
description: Use when harness-lite runs in explicit AionUi team mode and the leader needs to spawn the five stage-aligned teammates through `spawn-team.ps1`.
---

# Workflow Team

## When To Use

- 仅当 leader 已明确启用 `$env:AIONUI_TEAM_MODE='1'`，并决定按 `harness-lite` 的五个 stage 角色起 team 时使用
- 单 agent 默认路径不激活这个 skill
- env opt-in 的可执行强制点在 `scripts/spawn-team.ps1`，不是本说明文档本身

## Spawn Sequence

1. leader 调用 `skills/workflow-team/scripts/spawn-team.ps1`
2. `spawn-team.ps1` 先做 env fail-closed 校验
3. 校验通过后，脚本调用 `scripts/export-team-preset.ps1` 派生 preset
4. 脚本按 stage 顺序调用 `team_spawn_agent`：
   - `plan-author`
   - `plan-reviewer`
   - `implementer`
   - `code-reviewer`
   - `tester`

## Fallback

- `team_spawn_agent` 不可用或任一 spawn 失败时，立即停止后续 spawn
- 诊断只写 stderr
- stdout 只保留单行 JSON 结果，方便宿主决定回退到 single-agent flow

## Single-Writer Constraint

- 参考 [docs/team-write-authority.md](../../docs/team-write-authority.md)
- spawned member 对以下前缀只读：
  - `.assistant/`
  - `docs/tasks/<task-id>/`
- member 不得直接改 `plan.md`、`test.md`、`skill-manifest.json` 或任何 `.assistant/` 文件
- member 产出应通过 `team_send_message` 回 leader，由 leader 决定是否写入真相源
