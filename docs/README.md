# Docs

本目录只保留当前 harness-lite 优化仍会读取的协议文档和少量目录策略说明。

## Active Surfaces

- `工作流/`: 当前协议文档。这里的内容可以作为后续优化的输入。
- `tasks/`: 本地 workflow 任务 artifact 目录；git 只保留目录策略说明。
- `shared-memory-layers.md`: `.assistant` 与 `docs/tasks/<task-id>/` 的真相层关系。
- `team-write-authority.md`: team mode 下 leader/member 写入边界与 team preset 消费契约。

## Cleanup Policy

- 历史任务记录依赖 git history 或本地工作区恢复，不在 `docs/tasks/` 长期堆叠。
- 新的优化计划如果只是参考旧架构，必须把可复用结论沉淀到 `工作流/`、`skills/` 或 `tests/`，不反向依赖已删除历史目录。
- 不再把旧路线图、外部架构对比、拒绝方案记录、随机短 id 探针目录作为 live baseline。
