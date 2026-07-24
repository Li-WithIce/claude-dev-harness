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

## Default Promotion DP-01 一次性跟踪例外（冻结）

`docs/tasks/thin-harness-v2-default-promotion/` 下的 `plan.md`、`dp01-report.md`、`evidence.json` 和 `audit.md` 是用户显式授权提交的 DP-01 资格基线与范围冻结记录。该例外只覆盖这四个文件，不包含本地 Contract、Evidence 输入或 `.assistant/` runtime，也不表示 Default Promotion 已通过。

这些文件固定记录任务 `version 4 / paused`、Evidence `blocked` 的 DP-01 停点；DP-02 及后续阶段仍需单独授权，且不得把这组冻结记录当作 live runtime 或新任务模板。

这四份文件是 pre-archive 历史快照；DP-02 至 DP-05 的唯一当前资格合同是 [`docs/release/default-promotion-gates.md`](../release/default-promotion-gates.md)，它只取代后续依赖与批次定义，不回写历史 Evidence。
