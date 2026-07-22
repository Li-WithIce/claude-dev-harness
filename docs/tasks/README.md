# Task Artifacts

`docs/tasks/` 是本地 workflow 任务 artifact 面，不是代码管理面，也不是长期历史归档。

git 默认只保留本说明文件；具体 `docs/tasks/{task_id}/` 默认被 `.gitignore` 排除，显式例外见下文。

清理原则：

- 当前任务可继续写入 `docs/tasks/{task_id}/`，供本地 validator、advance-stage、review/test 使用。
- 已被当前协议吸收的历史路线图、对比实验、探针任务和外部架构草案不继续留在 git 管理面。
- 后续任务需要引用历史结论时，应引用当前协议文档，或从 git history / 本地任务记录恢复必要片段后重新沉淀到维护面。

## 当前任务一次性跟踪例外（DONE 后冻结）

`docs/tasks/thin-harness-v2-refactor/` 下的 `plan.md`、`test.md`、`release-gap-checklist.md` 和 `skill-manifest.json` 是用户显式授权提交的一次性工程审计跟踪面。该例外只适用于 `thin-harness-v2-refactor`，不改变其他任务目录默认忽略的规则，也不构成后续提交 `docs/tasks/{task_id}/` 的先例。

任务到达 `DONE` 后，这四个文件只保留为冻结审计记录和 Git 历史入口；它们不再充当 live runtime，也不得复制为新任务模板。运行时恢复仍以当前协议指定的 `.assistant/` 状态面为准。
