# Lite Runbook

## 1. Bootstrap

1. 解析任务是 `resume-current`、`switch-existing`、`new-task` 还是 `inbox-first`
2. 判定为 `new-task` 后由 `entry-router` 按 read-only / mutation / durable / ambiguous precedence 选择 `mode: quick | workflow | ask`；`review` / `test` 等名词本身不决定 mode
3. 只有 `mode=workflow` 才进入 orchestrator；quick 不创建 task artifact，ask 保持 iterative blocking clarification gate
4. 进入 workflow 后为新任务选择 `task_id`；未显式指定时，当前 `PLAN` 默认使用 `tool: codex`、`tool_profile: harness-default-codex`、`model: gpt-5.5/xhigh`
   可选：显式选择其他 `tool_profile` 和完整 `model`
   可选：在仓库里维护 `agent-configs/workflows/harness-lite.yaml`，为后续 stage 声明 `default_profile`
5. 如无 `plan.md`，先创建 `docs/tasks/{task_id}/plan.md`
6. 输入不足时再补 `docs/tasks/{task_id}/spec.md`

### 1.1 Lazy Loading

- `quick` 只加载入口规则、用户偏好 / 必要配置和直接相关 skill；不进入 orchestrator。
- `workflow` 加载 `entry-router`、`orchestrator` 和当前 stage skill。
- `resume-current` / `switch-existing` 先只读 identity/runtime/artifact；只有明确继续 / 切换并执行时才处理 fallback、`-SyncOnly` 收敛/激活并加载 current stage skill。read-only inspect/status 不写 runtime、不加载 stage skill。
- Markdown/HTML 互转、HTML report、网页 artifact、URL/HTML 提取 Markdown 或发布预览时，可额外加载 `md-html`；它不改变默认 PLAN/IMPLEMENT/REVIEW/TEST stage。
- 长 `spec.md` / `plan.md` 超过 160 行或 8 个二级标题，且需要人工审阅/决策、Markdown 层次不够清晰时，默认声明 paired reading HTML artifact（`plan.review.html` / `spec.review.html` 或 `review.html`），并保留 Markdown 为 source。
- 禁止 bulk-load 全部 skills、全部历史任务、Claude 兼容 skill、`workflow-team`；显式 backend、stage 或 team-mode 触发时除外。

## 2. Execute by Stage

- `PLAN`：写 Clarification、计划正文、Verification、Risks，并等待用户确认
- `PLAN_REVIEW`：追加一条 Plan Review run
- `IMPLEMENT`：改代码并追加一条 Implementation Notes run
- `CODE_REVIEW`：追加一条 Code Review run
- `TEST`：写 `test.md`

## 3. Advance

当前 stage 完成后执行：

```powershell
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage>
# 可选 profile/model 绑定
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -Tool <codex> -Profile harness-default-codex -Model gpt-5.5/xhigh
# 可选：只传 profile，backend 从 profile.backend 解析
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -Profile harness-default-codex
# 可选：显式切到其他合法 backend
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -Tool <claudecode>
# 新建/切换任务：不推进，只显式激活 current
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -SyncOnly -ActivateCurrent
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
- `ExpectedStage` 必须由调用方读取 frontmatter 后显式传入；CAS 不匹配时零写入
- `SyncOnly` 只同步实际 stage，不运行完整 stage validator；`ActivateCurrent` 只用于明确的新建/切换且拒绝 `DONE`
- 解析 trace `resolved tool=<tool> via <source>` 只写 stderr；stdout 仍固定为 `<stage> | <tool>`

共享 current 生命周期：mirror 始终同步；active advance 同步 current，background advance 只更新自身 mirror；active `DONE` 把 current 置为 canonical idle，background `DONE` 不改 current。runtime 写回任一步失败均返回非零；释放 runtime mutex 后、仍持同 task stage mutex 时按 `stage -> runtime` 顺序重取 runtime mutex，追加 `[writeback-fallback]` 并释放 runtime mutex，最后释放 task mutex。恢复时先读 fallback，再用相同 `TaskId/ExpectedStage -SyncOnly` 重放；成功重放同样在仍持 task stage mutex 时重取 runtime mutex，完成匹配清理并释放 runtime mutex，最后释放 task mutex。

## 4. Skill Invocation Modes

- `review` / `test` 直接走 Markdown stage skill，不调用 adapter
- adapter 白名单只保留 `codex`
- `implement` 明确禁入 adapter；需要主 agent / 人类直接执行
- `codex` 只允许 `-Mode readonly`
- 只有真实 `status=delegated` 的 invocation 才写 trace，并只允许 append 到目标 section 里已经存在的最新 `### Run N`；如果没有 Run block，就跳过写入并在 stderr 记录诊断
- 成功推进后，`advance-stage.ps1` 会 best-effort 写 `docs/tasks/{task_id}/skill-manifest.json`
- 需要给嵌入消费端展示技能清单时，运行 `scripts/generate-skills-index.ps1` 生成 `docs/tasks/{task_id}/skills-index.md`

## 5. Team Mode Dispatch

- orchestrator 只保留 team-mode 的文档分支，不新增可执行 dispatcher
- 唯一可执行强制点：`skills/workflow-team/scripts/spawn-team.ps1`
- `spawn-team.ps1` 只有在 `$env:AITEAMCODE_TEAM_MODE='1'` 时才会进入 spawn 路径
- env 未设时，脚本会 fail-closed 返回 `reason=team_mode_disabled`
- 单写者约束参考 [docs/team-write-authority.md](../../../docs/team-write-authority.md)

## 6. Loop Rules

- `PLAN_REVIEW verdict=revise` -> 回 `PLAN`
- `CODE_REVIEW verdict=revise` -> 回 `IMPLEMENT`
- `TEST conclusion=fail` -> 回 `IMPLEMENT`，保留失败 `test.md` 并追加 fresh Implementation / Code Review / TEST evidence
- `TEST conclusion=blocked` -> 保持 `TEST`，停止并报告解除条件

## 7. Terminal State

- `TEST conclusion=pass` -> `DONE`
- `DONE` 只写进 frontmatter，不再有独立 `HANDOFF` stage
- 交付摘要写在 `test.md` 的 `## Handoff`
