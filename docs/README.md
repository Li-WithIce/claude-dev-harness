# Docs

本目录只保留当前 harness-lite 优化仍会读取的协议文档和近期 Trellis 轻量协议任务证据。

## Active Surfaces

- `工作流/`: 当前协议文档。这里的内容可以作为后续优化的输入。
- `tasks/`: 当前仍保留的任务 artifact。历史路线图、探针任务和外部架构对比不再保留在活跃任务面。
- `aionui-integration/`: team preset 的当前消费契约。
- `shared-memory-layers.md`: `.assistant` 与 `docs/tasks/<task-id>/` 的真相层关系。
- `team-write-authority.md`: team mode 下 leader/member 写入边界。

## Cleanup Policy

- 历史任务记录依赖 git history 查询，不在 `docs/tasks/` 长期堆叠。
- 新的优化计划如果只是参考旧架构，必须把可复用结论沉淀到 `工作流/` 或新的当前任务 artifact，不反向依赖已删除历史目录。
- 不再把旧路线图、外部架构对比、拒绝方案记录、随机短 id 探针目录作为 live baseline。
