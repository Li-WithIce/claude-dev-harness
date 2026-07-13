# Gate Rules

lite workflow 只认 `docs/tasks/{task_id}/` 下的任务产物；这些 gate 只适用于 `new-task mode=workflow`，不约束 `mode=quick` 的直接处理。

## tool 规则

- 非 `DONE` 推进时，优先使用显式 `-Tool` / `-Profile`；未显式指定时使用 workflow descriptor 的 Codex-only `default_profile`
- `tool` 只允许：`claudecode`、`codex`
- `DONE` 固定写 `tool: none`
- 用户可在任意 stage 边界切换 tool

## 路径约定

| Artifact | Path |
|---|---|
| optional spec | `docs/tasks/{task_id}/spec.md` |
| plan | `docs/tasks/{task_id}/plan.md` |
| test | `docs/tasks/{task_id}/test.md` |
| task mirror | `运行时/tasks/<task-id>.md` |

## PLAN -> PLAN_REVIEW

- `plan.md` frontmatter 合法
- `stage: PLAN`
- `## Clarification` 包含：验收标准、非目标、受影响目录、回滚/兼容、`ui:`
- `## User Confirmation` 中存在 `- status: confirmed`

## PLAN_REVIEW -> IMPLEMENT

- `plan.md` 中 `## Plan Review` 的最新 `### Run` 存在
- 最新 run 含 `- verdict: pass | revise`
- `pass` 才前进，`revise` 回 `PLAN`

## IMPLEMENT -> CODE_REVIEW

- `## Implementation Notes` 的最新 `### Run` 存在
- 如果最近一次 `## Code Review` verdict 是 `revise`，那么最新 Implementation run 的分钟不得早于那次 review
- 如果由 `TEST fail` 返回（`IMPLEMENT` 且最近一次 Code Review 为 `pass`），`test.md` 必须保留 `Conclusion: fail`，最新 Implementation run 的分钟不得早于失败 Evidence

## CODE_REVIEW -> TEST

- `## Code Review` 的最新 `### Run` 存在
- 最新 run 含 `- verdict: pass | revise`
- 最新 verdict 为 `pass` 时，该 run 的分钟不得早于最新 Implementation run；旧 `revise` 仍按下一条返回 IMPLEMENT
- `pass` 才前进，`revise` 回 `IMPLEMENT`

## TEST -> DONE / IMPLEMENT

- `test.md` 存在
- `## Conclusion` 第一行是 `pass | fail | blocked`
- `## Evidence` 含 `command`、`exit_code`、`executed_at`、`revision`、`evidence_path`
- `## Handoff` 存在
- Evidence 分钟不得早于最新 Code Review；freshness 比较书面 `yyyy-MM-dd HH:mm`，同分钟接受
- `pass -> DONE`；`fail -> IMPLEMENT`；`blocked` 保持 `TEST`、零写入并报告解除条件。`DONE` 是 TEST attestation，不是 stage driver 执行任意计划命令的证明

## 共享运行时

每次调用都必须传调用方刚读取的 `-ExpectedStage`；CAS 不匹配时零写入。`.assistant\entry\advance-stage.ps1` 转调 repo 内 `scripts/advance-stage.ps1` 后：

- mirror 永远同步实际 `plan.md` stage
- current 只在 task 已 active 或显式 `-ActivateCurrent` 时更新；background advance 不抢 current
- active `DONE` 把 current 重置为 canonical idle；background `DONE` 不改 current；`DONE` 禁止激活
- `-SyncOnly` 不推进 stage、不运行阶段完成度 gate；新建/切换使用 `-SyncOnly -ActivateCurrent`
- runtime ladder 首次失败即停止后续写入并返回非零；释放 runtime mutex 后、仍持同 task stage mutex 时按 `stage -> runtime` 顺序重取 runtime mutex，追加 `[writeback-fallback]` 并释放 runtime mutex，最后释放 task mutex。恢复时先用 `-SyncOnly` 重放；成功重放同样在仍持 task stage mutex 时重取 runtime mutex，清除匹配项并释放 runtime mutex，最后释放 task mutex
- `运行时/恢复索引.md` 始终从最终 current + mirrors 派生

runner 不直接编辑这些 mirror。
