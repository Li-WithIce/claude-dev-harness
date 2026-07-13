---
tags: [配置, schema]
created: 2026-04-01
updated: 2026-04-01
---

# Schema Versions

## 目标

记录共享记忆与开发编排相关文档的 schema 版本，避免旧任务文件在恢复时被新 reader 误解析。

## 当前版本表

| Schema | 当前版本 | 作用范围 | 兼容策略 |
|------|------|------|------|
| shared-memory-core | `1.2` | `.assistant/工作流/*.md` 的共享记忆主协议 | 入口 agent 优先读取最新协议 |
| task-runtime | `1.1` | `.assistant/运行时/tasks/<task-id>.md` | health 对缺字段返回 FAIL；repair 只可由 plan.md 重建派生 mirror |
| current-task-pointer | `1.1` | `.assistant/运行时/当前任务.md` | health 对缺字段返回 FAIL；仅缺失 pointer 可一次性从 legacy current-flow 迁移 |
| recovery-index | `1.1` | `.assistant/运行时/恢复索引.md` | 仅从 current pointer + 合法未完成 task mirror 派生 |
| lite-plan-frontmatter | `1.1` | `docs/tasks/{task_id}/plan.md` frontmatter | 仅接受 lite stage/tool 合法值，`DONE` 固定 `tool: none` |
| lite-test-report | `1.0` | `docs/tasks/{task_id}/test.md` | `## Conclusion` 与 `## Handoff` 为最低契约 |

## task-runtime v1.1 最低字段

- `schema_version`
- `task_id`
- `task_name`
- `workspace`
- `artifact_root`
- `primary_artifact`
- `artifact_links`
- `entry_host`
- `stage`
- `updated`（带时区的秒级时间）

## current-task-pointer v1.1 最低字段

- `schema_version`
- `task_id`
- `entry_host`
- `writer`
- `updated`（带时区的秒级时间）
- 表格中的 `状态`、`当前文档`、`下一步`

## recovery-index v1.1 最低字段

- `schema_version`
- `updated`（带时区的秒级时间）
- `writer`
- `derived_from: [运行时/当前任务.md, 运行时/tasks/]`

## 升级规则

1. 新建任务状态文件时，必须显式写入 `schema_version`
2. 旧文件若未声明 `schema_version`，health 必须失败；repair 只能重建派生运行态，绝不改写 `plan.md`
3. 任何 schema 变更先更新本文件，再更新协议文档或模板
4. 若 reader 无法安全兼容旧版本，必须停止自动恢复并写入决策说明
