# Gate Rules

lite workflow 只认 `docs/tasks/<task-id>/` 下的任务产物。

## tool 规则

- 非 `DONE` 推进时，优先使用显式 `-Tool` / `-Profile`；未显式指定时使用 workflow descriptor 的 Codex-only `default_profile`
- `tool` 只允许：`claudecode`、`codex`、`gemini`
- `DONE` 固定写 `tool: none`
- 用户可在任意 stage 边界切换 tool

## 路径约定

| Artifact | Path |
|---|---|
| optional spec | `docs/tasks/<task-id>/spec.md` |
| plan | `docs/tasks/<task-id>/plan.md` |
| test | `docs/tasks/<task-id>/test.md` |
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
- 如果最近一次 `## Code Review` verdict 是 `revise`，那么最新 Implementation run 必须比那次 review 更新

## CODE_REVIEW -> TEST

- `## Code Review` 的最新 `### Run` 存在
- 最新 run 含 `- verdict: pass | revise`
- `pass` 才前进，`revise` 回 `IMPLEMENT`

## TEST -> DONE

- `test.md` 存在
- `## Conclusion` 第一行是 `pass | fail | blocked`
- `## Handoff` 存在
- 只有 `pass` 才前进；`fail` / `blocked` 停止并报告

## 共享运行时

每次成功推进都由 `.assistant\entry\advance-stage.ps1` 转调 repo 内 `scripts/advance-stage.ps1` 自动重写：

- `运行时/tasks/<task-id>.md`
- `运行时/当前任务.md`
- `运行时/恢复索引.md`

runner 不直接编辑这些 mirror。
