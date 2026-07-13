---
name: orchestrator
description: Use when a development task needs lite workflow dispatch, per-stage tool selection, recovery, or stage advancement through `plan.md` frontmatter.
---

# Orchestrator

orchestrator 只负责 lite workflow：`PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST`。`DONE` 只是 frontmatter 终态标记，不是可执行 stage。

## 真相源

- 唯一阶段真相源：`docs/tasks/{task_id}/plan.md` frontmatter
- 可选下一阶段默认来源：`agent-configs/workflows/harness-lite.yaml`
- 可选附件：`docs/tasks/{task_id}/spec.md`
- TEST 产物：`docs/tasks/{task_id}/test.md`
- 共享运行时 mirror 只由 repo 脚本 `scripts/advance-stage.ps1` 重写；项目内入口是 `.assistant\entry\advance-stage.ps1`

## frontmatter 契约

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | none
tool_profile: <optional profile name>
model: <optional full model id>
updated: YYYY-MM-DD
---
```

规则：

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`
- `DONE` 只能写 `tool: none`
- `tool` 表示“当前 stage 由哪个工具继续”，仍是显式 backend 字段
- `tool_profile` 与 `model` 是 opt-in；存在 `tool_profile` 时，profile 的 `backend` 必须等于 `tool`
- 当前 stage 的 `tool_profile` 只是活跃 profile 记录，不会作为下一 stage 的黏性 fallback
- `model` 必须写完整模型 ID，不写 `opus`、`pro` 这类短别名

## 入口规则

1. 先判断请求是 `resume-current`、`switch-existing`、`new-task` 还是 `inbox-first`
2. 只有 `new-task mode=workflow` 才进入 orchestrator；`mode=quick` 由入口 agent 直接处理并验证；`mode=ask` 是 iterative blocking clarification gate，必须停留在入口层 until all blocking requirements are resolved，然后重新判断并 route to `quick` or `workflow`
3. `new-task` 的 read-only / mutation / durable / ambiguous precedence 只由 `entry-router` 判定；`review` / `test` 等名词本身不把请求送入 orchestrator
4. 进入 workflow 后先定 `task_id`；未显式指定时，当前 `PLAN` 默认写 `tool: codex`、`tool_profile: harness-default-codex`、`model: gpt-5.5/xhigh`
5. 如果 `plan.md` 已存在，直接读 frontmatter 决定当前 `stage` 和 `tool`
6. 输入不足时才创建 `docs/tasks/{task_id}/spec.md`
7. 不再维护 `current-flow.md`、`handoff.md`、`implementation-notes.md`、`review.md`

## 自动懒加载规则

orchestrator 只能在 `new-task mode=workflow` 或已确认的 resume/switch workflow 任务中加载。`ask` 未解除阻塞前不得加载 orchestrator、创建 `docs/tasks/{task_id}/` 或进入 `PLAN`。进入 workflow 后按当前 stage 懒加载：

- `PLAN`：只加载 `plan`
- `PLAN_REVIEW`：只加载 `review`
- `IMPLEMENT`：只加载 `implement`
- `CODE_REVIEW`：只加载 `review`
- `TEST`：只加载 `test`
- Markdown/HTML 互转、HTML 报告、网页 artifact、URL/HTML 提取 Markdown 或发布预览时，可额外加载 `md-html` 作为直接相关 skill；它说明 source/artifact 边界，不新增 stage，也不进入默认 stage whitelist。
- `spec.md` / `plan.md` 超过 160 行或 8 个二级标题、且需要人工审阅/决策时，`md-html` 可生成 fixed template paired reading HTML；该产物不替代 Markdown 真相源。

禁止 bulk-load 全部 skills、全部历史任务、Claude 兼容 skill、`workflow-team`。`workflow-team` 仅在 `$env:AITEAMCODE_TEAM_MODE='1'` 且 leader 明确选择 team mode 时加载。

## 调度规则

- `PLAN`：调用 `plan` skill，补齐 Clarification 和 User Confirmation
- `PLAN_REVIEW`：调用 `review` skill，写 `## Plan Review`
- `IMPLEMENT`：调用 `implement` skill，写 `## Implementation Notes`
- `CODE_REVIEW`：调用 `review` skill，写 `## Code Review`
- `TEST`：调用 `test`，写 `test.md`
- `review` / `test` 直接加载现有 Markdown stage skill；只有显式 readonly `codex` 委派才调用 repo `scripts/invoke-harness-skill.ps1`
- `implement` 不允许走 adapter；必须由主 agent / 人类直接执行

**Team mode (documentation only)**: 当 leader 已设 `$env:AITEAMCODE_TEAM_MODE='1'` 时，可调用 `skills/workflow-team/scripts/spawn-team.ps1` 只启动当前 stage 的一个角色；env 校验由 `spawn-team.ps1` 自身 fail-closed 强制。env 未设时维持单 agent 流程，所有 Phase 1-3 行为零变化；orchestrator skill 本身不新增任何读 env 的可执行分支。

## 推进规则

stage 只通过下面这条命令推进：

```powershell
# Codex-only 默认路径：ExpectedStage 必须是调用方刚读取的 frontmatter stage
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage>
# 可选：同时绑定下一阶段 profile/model
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -Tool <codex> -Profile harness-default-codex -Model gpt-5.5/xhigh
# 可选：只传 profile，backend 从 profile.backend 解析
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -Profile harness-default-codex
# 可选：显式切到其他合法 backend
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -Tool <claudecode>
# 新建/切换任务只同步实际 stage，并显式激活 current
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -SyncOnly -ActivateCurrent
```

规则：

- 非 `DONE` 推进的 fallback 顺序固定为：显式 `-Tool` → 显式 `-Profile` → `agent-configs/workflows/harness-lite.yaml` 的 `default_profile`
- 只有当这三层都缺失时，非 `DONE` 推进才会报 `requires -Tool`
- `pure cli-tool`（显式 `-Tool`、未传 `-Profile/-Model`）会清空下一 stage 继承的 `tool_profile/model`
- `cli-profile` 与 `cli-tool + explicit -Profile/-Model` 保持 Phase 1 mismatch rejection 语义
- 用户可以在任意 stage 边界切换 `tool`
- `-ExpectedStage` 是调用方提供的 compare-and-swap 前置条件；不匹配时零写入，shim 不会代读或代填
- `-SyncOnly` 不推进 stage、不跑阶段完成度 gate，且拒绝 `-Tool/-Profile/-Model`；仅同步实际 frontmatter stage
- `-ActivateCurrent` 只用于明确的新建/切换，不能激活 `DONE`

它会转调 repo 内的 `advance-stage.ps1`，并先自动运行 validator，然后再：

- 更新 `plan.md` frontmatter 的 `stage`、`tool` 和 `updated`
- 始终重写 `运行时/tasks/<task-id>.md`
- task 已 active 或显式 `-ActivateCurrent` 时才重写 `运行时/当前任务.md`；background advance 不抢 current
- active task 到 `DONE` 时把 current 重置为 canonical idle；background `DONE` 不改 current
- 依据最终 current + mirrors 重写 `运行时/恢复索引.md`
- best-effort 写入 `docs/tasks/{task_id}/skill-manifest.json`
- 把 `resolved tool=<tool> via <source>` 写到 stderr，stdout 保持 `<stage> | <tool>`

## PreCompact 自检

- 这是协议条款，不是注册到 Claude Code 内核的 hook。
- 当你主观判断当前 context 已接近上限时，宁可早触发，也不要漏触发。
- 每次 stage callback 结束前，leader 至少自检 3 件事：
  - 是否存在用户已明确授权但还没提交的 wisdom 条目
  - 当前 task 是否已经具备推进条件
  - 若现在中断，会不会丢失下一位接手者恢复所需的最小上下文
- wisdom 路径只允许 append：只有用户明确要求记录/沉淀记忆后，才可提交 pending wisdom，并通过 `skills/obsidian-memory/scripts/append-runtime-inbox.ps1` 写入 `.assistant/运行时/收件箱.md`；普通 review/status 只提示可沉淀内容。
- 收件箱任务分流回到 entry-router：使用 `triage-runtime-inbox.ps1 -List` 单行 JSON 中的 `open_items[].route_task_id` 作为 task identity，并保留同项临时 `row_id`；`task_plan_exists=true` 走 `switch-existing`，否则由 entry-router 选择 quick/workflow/ask。quick 交付与验证成功后立即用 `-RowId <row_id>` 精确 triage；workflow 完成 canonical PLAN、validator 与 background `-SyncOnly` 后再 triage；ask/pending、失败或仍需人工选择时 row 保持 open，并直接向用户提问。不要手工直写 runtime、decision 或记忆文件。
- inbox recovery 的 machine contracts 以 `entry-router` 为唯一来源；本 skill 只执行其已选 route，不复制判定矩阵。
- 若当前 stage 已可推进，非 append 写回只能委托 `.assistant\entry\advance-stage.ps1`；不要手工 patch `plan.md`、`运行时/tasks/<task-id>.md`、`运行时/当前任务.md` 或 `运行时/恢复索引.md`。
- 用户明确继续 / 切换并执行 workflow、已进入 orchestrator 后，才处理 matching open `[writeback-fallback]`；runtime ladder 任一步失败都返回非零，释放锁后用相同 `TaskId/ExpectedStage` 执行 `-SyncOnly`，成功后只清除精确匹配的 fallback 行。
- 触发 append 或 advance 前，先按 [docs/工作流/single-writer-precompact.md](../../docs/工作流/single-writer-precompact.md) 执行 `cooperative-yield` / single-writer 协议；不要与正在运行的 `advance-stage` 主流程竞争。

## TodoWrite Milestones（跨阶段，可选 host surface）

各 stage skill 不再各自重复这段；统一在此。

- 仅在宿主提供 TodoWrite surface 时使用；不是 Codex-only 默认流程的必需依赖。没有该 surface 时用原生计划 / team board / 回报消息表达同等 milestone。
- milestone 是事件不是签到点：发现 blocker、计划外改动、证据缺口或 scope 漂移时必须立刻汇报，不要堆到收尾。
- 每个 stage 的最小节奏都是「load-context → core-work → verify → append/report」，例如：
  - `PLAN`：`phase-loaded` → `core-work-done` → `verification-done`
  - `IMPLEMENT`：`context-loaded` → `code-edited` → `tests-run` → `notes-appended`
  - `PLAN_REVIEW` / `CODE_REVIEW`：`context-loaded` → `findings-collected` → `run-appended`
- 最后一个 milestone 完成后必须紧跟最终的 stage callback / `team_send_message` / 用户回报，不能只停在 TodoWrite 更新。

## stop 条件

出现以下任一情况就停止并直接报告：

- `plan.md` 缺失或 frontmatter 不合法
- `stage` 或 `tool` 不在合法集合内
- PLAN 没有明确用户确认
- IMPLEMENT 没有新证据支撑回修
- TEST 缺 `## Conclusion` 或 `## Handoff`
- 当前 stage 的最新 run 没有合法 `verdict`
- `-ExpectedStage` 与当前 frontmatter stage 不一致，或存在尚未收敛的 matching `[writeback-fallback]`
- 非 `DONE` 推进时 `-Tool` / `-Profile` / workflow-default 都无法解析下一阶段 tool

## 响应头

每次 orchestrator 响应先给这四行：

```text
task_id: <task-id>
stage: <stage>
tool: <tool>
advance_hint: pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage>
```

`advance_hint` 默认走 workflow descriptor；需要临时切换 backend 时再追加 `-Tool <claudecode|codex>`。`TEST -> DONE` 时也可以省略 `-Tool`。

## References

- Gate rules: [references/gates.md](references/gates.md)
- Runbook: [references/runbook.md](references/runbook.md)
- State templates: [references/state-templates.md](references/state-templates.md)
- Tool selection: [references/default-tool-profiles.md](references/default-tool-profiles.md)
- Writing guide: [references/lite-writing-guide.md](references/lite-writing-guide.md)
