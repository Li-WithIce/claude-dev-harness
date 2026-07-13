---
name: workflow-team
description: Use when harness-lite runs in explicit AiTeamCode team mode and the leader needs to spawn only the current stage role through `spawn-team.ps1`.
---

# Workflow Team

## When To Use

- 仅当 leader 已明确启用 `$env:AITEAMCODE_TEAM_MODE='1'`，并决定为当前 `harness-lite` stage 启动一个角色时使用
- 单 agent 默认路径不激活这个 skill
- env opt-in 的可执行强制点在 `scripts/spawn-team.ps1`，不是本说明文档本身

## Spawn Sequence

1. leader 调用 `skills/workflow-team/scripts/spawn-team.ps1`
2. `spawn-team.ps1` 先做 env fail-closed 校验
3. 脚本从 `plan.md` frontmatter 读取当前 stage；没有 `plan.md` 时必须显式传 `-Stage`，不猜测
4. 校验通过后，脚本调用 `scripts/export-team-preset.ps1` 派生 preset，并只调用一次 `team_spawn_agent`：
   - `PLAN` -> `plan-author`
   - `PLAN_REVIEW` -> `plan-reviewer`
   - `IMPLEMENT` -> `implementer`
   - `CODE_REVIEW` -> `code-reviewer`
   - `TEST` -> `tester`
   - `DONE` 不启动 member

## Auto Mode Propagation

- 仅当 leader 同时设置 `$env:AITEAMCODE_TEAM_MODE='1'` 与 `$env:HARNESS_AUTO='1'` 时，本 skill 才把 spawned member 视为 auto 模式。
- 缺少任一环境变量时按 fail-closed 处理：member 保持当前 non-auto 行为，不自行猜测自动确认。
- auto 模式只表示 member 在自身执行过程中尽量减少中间确认；遇到 blocker、范围冲突或权限缺口时，仍必须立即通过 `team_send_message` 回 leader。
- member 在 auto 模式下仍不得直接写真相源，只能把结果或阻塞回传给 leader，由 leader 决定是否写入 `.assistant/` 或 `docs/tasks/{task_id}/`。
- auto 模式不绕过 `PLAN_REVIEW` / `CODE_REVIEW` gate，也不授予跳过 stage 推进确认的权限。
- leader 仍负责最终的 stage callback / `team_send_message` 交接与推进确认；member 只负责把本阶段执行到可交付状态。

## PreCompact Callback

- leader 派发 worker 任务时，应在消息体显式带上 PreCompact 提示：
  - 若你主观判断 context 临近上限，只通过 `team_send_message` 向 leader 回报 pending wisdom candidate；不得把回报解释为用户已授权记忆写入
  - 若当前 stage 已具备推进条件，只通过 `team_send_message` 向 leader 回报 ready-to-advance
  - 回报后进入 stand by，由 leader 决定写回与推进
- worker 不得调用 `append-runtime-inbox.ps1` 或 `.assistant\entry\advance-stage.ps1`，也不得手工直写 `.assistant/`、`docs/tasks/{task_id}/` 或 shared pointer。
- leader 收到回报后，先核验用户明确授权记忆写入；未授权时只保留消息并提示，授权后才可按 [docs/工作流/single-writer-precompact.md](../../docs/工作流/single-writer-precompact.md) append。stage advance 仍按 write-authorized workflow 与 `cooperative-yield` 规则执行；worker 不参与写入锁竞争。
- 这条 callback 只约束 leader/worker 的自检与交接，不新增任何团队成员、队列或后台守护进程。

## Fallback

- `team_spawn_agent` 不可用或任一 spawn 失败时，立即停止后续 spawn
- 诊断只写 stderr
- stdout 只保留单行 JSON 结果，方便宿主决定回退到 single-agent flow

## Single-Writer Constraint

- 参考 [docs/team-write-authority.md](../../docs/team-write-authority.md)
- spawned member 对以下前缀只读：
  - `.assistant/`
  - `docs/tasks/{task_id}/`
- member 不得直接改 `plan.md`、`test.md`、`skill-manifest.json` 或任何 `.assistant/` 文件
- member 产出应通过 `team_send_message` 回 leader，由 leader 决定是否写入真相源
