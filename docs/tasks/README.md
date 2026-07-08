# Task Artifacts

`docs/tasks/` 是本地 workflow 任务 artifact 面，不是代码管理面，也不是长期历史归档。

git 只保留本说明文件；具体 `docs/tasks/{task_id}/` 默认被 `.gitignore` 排除。

清理原则：

- 当前任务可继续写入 `docs/tasks/{task_id}/`，供本地 validator、advance-stage、review/test 使用。
- 已被当前协议吸收的历史路线图、对比实验、探针任务和外部架构草案不继续留在 git 管理面。
- 后续任务需要引用历史结论时，应引用当前协议文档，或从 git history / 本地任务记录恢复必要片段后重新沉淀到维护面。
