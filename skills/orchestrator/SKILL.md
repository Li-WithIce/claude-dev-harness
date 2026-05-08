---
name: orchestrator
description: Use when a development task needs lite workflow dispatch, per-stage tool selection, recovery, or stage advancement through `plan.md` frontmatter.
---

# Orchestrator

orchestrator 只负责 lite workflow：`PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST`。`DONE` 只是 frontmatter 终态标记，不是可执行 stage。

## 真相源

- 唯一阶段真相源：`docs/tasks/<task-id>/plan.md` frontmatter
- 可选下一阶段默认来源：`agent-configs/workflows/harness-lite.yaml`
- 可选附件：`docs/tasks/<task-id>/spec.md`
- TEST 产物：`docs/tasks/<task-id>/test.md`
- 共享运行时 mirror 只由 repo 脚本 `scripts/advance-stage.ps1` 重写；项目内入口是 `.assistant\entry\advance-stage.ps1`

## frontmatter 契约

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | gemini | none
tool_profile: <optional profile name>
model: <optional full model id>
updated: YYYY-MM-DD
---
```

规则：

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`、`gemini`
- `DONE` 只能写 `tool: none`
- `tool` 表示“当前 stage 由哪个工具继续”，仍是显式 backend 字段
- `tool_profile` 与 `model` 是 opt-in；存在 `tool_profile` 时，profile 的 `backend` 必须等于 `tool`
- 当前 stage 的 `tool_profile` 只是活跃 profile 记录，不会作为下一 stage 的黏性 fallback
- `model` 必须写完整模型 ID，不写 `opus`、`pro` 这类短别名

## 入口规则

1. 先判断请求是 `resume-current`、`switch-existing` 还是 `new-task`
2. 新任务先定 `task_id`；未显式指定时，当前 `PLAN` 默认写 `tool: codex`、`tool_profile: harness-default-codex`、`model: gpt-5.5/xhigh`
3. 如果 `plan.md` 已存在，直接读 frontmatter 决定当前 `stage` 和 `tool`
4. 输入不足时才创建 `docs/tasks/<task-id>/spec.md`
5. 不再维护 `current-flow.md`、`handoff.md`、`implementation-notes.md`、`review.md`

## 调度规则

- `PLAN`：调用 `plan` skill，补齐 Clarification 和 User Confirmation
- `PLAN_REVIEW`：调用 `review` skill，写 `## Plan Review`
- `IMPLEMENT`：调用 `implement` skill，写 `## Implementation Notes`
- `CODE_REVIEW`：调用 `review` skill，写 `## Code Review`
- `TEST`：默认调用 `test`，写 `test.md`；只有显式切到 Gemini 时才使用 `gemini-designer-main`
- 优先调用 repo `scripts/invoke-harness-skill.ps1` 发起 `review` / `test` / `codex`；显式 Gemini 路径可发起 `gemini-designer-main`；返回 `status=markdown-fallback` 时回退到原 Markdown skill 流程
- `implement` 不允许走 adapter；必须由主 agent / 人类直接执行

**Team mode (documentation only)**: 当 leader 已设 `$env:AIONUI_TEAM_MODE='1'` 时，可调用 `skills/workflow-team/scripts/spawn-team.ps1` 起 5 role 团队；env 校验由 `spawn-team.ps1` 自身 fail-closed 强制。env 未设时维持单 agent 流程，所有 Phase 1-3 行为零变化；orchestrator skill 本身不新增任何读 env 的可执行分支。

## 推进规则

stage 只通过下面这条命令推进：

```powershell
# Codex-only 默认路径：descriptor 为下一 stage 声明 default_profile 时可省略 -Tool/-Profile
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id>
# 可选：同时绑定下一阶段 profile/model
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <codex> -Profile harness-default-codex -Model gpt-5.5/xhigh
# 可选：只传 profile，backend 从 profile.backend 解析
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Profile harness-default-codex
# 可选：显式切到其他合法 backend
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <claudecode|gemini>
```

规则：

- 非 `DONE` 推进的 fallback 顺序固定为：显式 `-Tool` → 显式 `-Profile` → `agent-configs/workflows/harness-lite.yaml` 的 `default_profile`
- 只有当这三层都缺失时，非 `DONE` 推进才会报 `requires -Tool`
- `pure cli-tool`（显式 `-Tool`、未传 `-Profile/-Model`）会清空下一 stage 继承的 `tool_profile/model`
- `cli-profile` 与 `cli-tool + explicit -Profile/-Model` 保持 Phase 1 mismatch rejection 语义
- 用户可以在任意 stage 边界切换 `tool`

它会转调 repo 内的 `advance-stage.ps1`，并先自动运行 validator，然后再：

- 更新 `plan.md` frontmatter 的 `stage`、`tool` 和 `updated`
- 重写 `运行时/tasks/<task-id>.md`
- 重写 `运行时/当前任务.md`
- 重写 `运行时/恢复索引.md`
- best-effort 写入 `docs/tasks/<task-id>/skill-manifest.json`
- 把 `resolved tool=<tool> via <source>` 写到 stderr，stdout 保持 `<stage> | <tool>`

## PreCompact 自检

- 这是协议条款，不是注册到 Claude Code 内核的 hook。
- 当你主观判断当前 context 已接近上限时，宁可早触发，也不要漏触发。
- 每次 stage callback 结束前，leader 至少自检 3 件事：
  - 是否存在还没提交的 wisdom 条目
  - 当前 task 是否已经具备推进条件
  - 若现在中断，会不会丢失下一位接手者恢复所需的最小上下文
- wisdom 路径只允许 append：如需提交 pending wisdom，先走 `skills/obsidian-memory/scripts/append-runtime-inbox.ps1` 写入 `.assistant/运行时/收件箱.md`。
- 收件箱后的分流仍走仓库现有 `promote-runtime-inbox.ps1` / `triage-runtime-inbox.ps1` 路径；不要手工直写 `.assistant/运行时/记忆-*.md`。
- 若当前 stage 已可推进，非 append 写回只能委托 `.assistant\entry\advance-stage.ps1`；不要手工 patch `plan.md`、`运行时/tasks/<task-id>.md`、`运行时/当前任务.md` 或 `运行时/恢复索引.md`。
- 触发 append 或 advance 前，先按 [docs/工作流/single-writer-precompact.md](../../docs/工作流/single-writer-precompact.md) 执行 `cooperative-yield` / single-writer 协议；不要与正在运行的 `advance-stage` 主流程竞争。

## stop 条件

出现以下任一情况就停止并直接报告：

- `plan.md` 缺失或 frontmatter 不合法
- `stage` 或 `tool` 不在合法集合内
- PLAN 没有明确用户确认
- IMPLEMENT 没有新证据支撑回修
- TEST 缺 `## Conclusion` 或 `## Handoff`
- 当前 stage 的最新 run 没有合法 `verdict`
- 非 `DONE` 推进时 `-Tool` / `-Profile` / workflow-default 都无法解析下一阶段 tool

## 响应头

每次 orchestrator 响应先给这四行：

```text
task_id: <task-id>
stage: <stage>
tool: <tool>
advance_hint: pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id>
```

`advance_hint` 默认走 workflow descriptor；需要临时切换 backend 时再追加 `-Tool <claudecode|codex|gemini>`。`TEST -> DONE` 时也可以省略 `-Tool`。

## References

- Gate rules: [references/gates.md](references/gates.md)
- Runbook: [references/runbook.md](references/runbook.md)
- State templates: [references/state-templates.md](references/state-templates.md)
- Tool selection: [references/default-tool-profiles.md](references/default-tool-profiles.md)
- Writing guide: [references/lite-writing-guide.md](references/lite-writing-guide.md)
