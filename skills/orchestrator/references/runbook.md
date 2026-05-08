# Lite Runbook

## 1. Bootstrap

1. 解析任务是 `resume-current`、`switch-existing`、`new-task` 还是 `inbox-first`
2. 判定为 `new-task` 后先选择 `mode: quick | workflow | ask`
   - `quick`：低风险、边界清楚、可当前对话直接完成和验证；不创建 `docs/tasks/<task-id>/`
   - `workflow`：需要计划、留痕、review、test、多文件/跨模块协作或较高风险；进入 orchestrator
   - `ask`：只有 quick/workflow 信号冲突或缺少关键判断信息时使用，只问一个最小问题
3. 显式覆盖词：`直接改` / `快修` 偏 `quick`；`走 workflow` / `留痕` / `review` / `test` 偏 `workflow`
4. 进入 workflow 后为新任务选择 `task_id`；未显式指定时，当前 `PLAN` 默认使用 `tool: codex`、`tool_profile: harness-default-codex`、`model: gpt-5.5/xhigh`
   可选：显式选择其他 `tool_profile` 和完整 `model`
   可选：在仓库里维护 `agent-configs/workflows/harness-lite.yaml`，为后续 stage 声明 `default_profile`
5. 如无 `plan.md`，先创建 `docs/tasks/<task-id>/plan.md`
6. 输入不足时再补 `docs/tasks/<task-id>/spec.md`

## 2. Execute by Stage

- `PLAN`：写 Clarification、计划正文、Verification、Risks，并等待用户确认
- `PLAN_REVIEW`：追加一条 Plan Review run
- `IMPLEMENT`：改代码并追加一条 Implementation Notes run
- `CODE_REVIEW`：追加一条 Code Review run
- `TEST`：写 `test.md`

## 3. Advance

当前 stage 完成后执行：

```powershell
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id>
# 可选 profile/model 绑定
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <codex> -Profile harness-default-codex -Model gpt-5.5/xhigh
# 可选：只传 profile，backend 从 profile.backend 解析
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Profile harness-default-codex
# 可选：显式切到其他合法 backend
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <claudecode|gemini>
```

这个 workspace shim 会转调 repo 内的 `advance-stage.ps1`，并先自动运行 validator。

脚本负责：

- 更新 `plan.md` frontmatter
- 写入下一阶段 `tool`
- 按解析来源写入下一阶段 `tool_profile` / `model`
- 刷新共享运行时 mirror

规则：

- 非 `DONE` 推进的 fallback 顺序固定为：`cli-tool -> cli-profile -> workflow-default`
- `workflow-default` 读取 `agent-configs/workflows/harness-lite.yaml.stages.<next>.default_profile`
- 当前 stage 的 `tool_profile/model` 是 non-sticky 元数据，不参与下一 stage fallback
- `pure cli-tool`（显式 `-Tool`、未传 `-Profile/-Model`）会清空下一 stage 继承的 `tool_profile/model`
- `cli-profile` 与 `cli-tool + explicit -Profile/-Model` 继续要求 `tool == profile.backend`
- 三层都缺失时，非 `DONE` 推进才会报 `requires -Tool`
- 用户可以在任意 stage 边界切换 tool
- 解析 trace `resolved tool=<tool> via <source>` 只写 stderr；stdout 仍固定为 `<stage> | <tool>`

## 4. Skill Invocation Modes

- 优先入口：`scripts/invoke-harness-skill.ps1`
- adapter 白名单固定为：`review`、`test`、`gemini-designer-main`、`codex`；默认 TEST skill 集只使用 `test`
- `implement` 明确禁入 adapter；需要主 agent / 人类直接执行
- `review` / `test` 当前是 stub：stdout 返回合法 JSON，`status=markdown-fallback`，stderr 提示回退到 Markdown skill 流
- `codex` 只允许 `-Mode readonly`
- invocation trace 只允许 append 到目标 section 里已经存在的最新 `### Run N`；如果没有 Run block，就跳过写入并在 stderr 记录诊断
- 成功推进后，`advance-stage.ps1` 会 best-effort 写 `docs/tasks/<task-id>/skill-manifest.json`
- 需要给嵌入消费端展示技能清单时，运行 `scripts/generate-skills-index.ps1` 生成 `docs/tasks/<task-id>/skills-index.md`

## 5. Team Mode Dispatch

- orchestrator 只保留 team-mode 的文档分支，不新增可执行 dispatcher
- 唯一可执行强制点：`skills/workflow-team/scripts/spawn-team.ps1`
- `spawn-team.ps1` 只有在 `$env:AIONUI_TEAM_MODE='1'` 时才会进入 spawn 路径
- env 未设时，脚本会 fail-closed 返回 `reason=team_mode_disabled`
- 单写者约束参考 [docs/team-write-authority.md](../../../docs/team-write-authority.md)

## 6. Loop Rules

- `PLAN_REVIEW verdict=revise` -> 回 `PLAN`
- `CODE_REVIEW verdict=revise` -> 回 `IMPLEMENT`
- `TEST conclusion=fail|blocked` -> 不自动回环，直接停止并报告

## 7. Terminal State

- `TEST conclusion=pass` -> `DONE`
- `DONE` 只写进 frontmatter，不再有独立 `HANDOFF` stage
- 交付摘要写在 `test.md` 的 `## Handoff`
