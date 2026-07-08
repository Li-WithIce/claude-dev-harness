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
| task-runtime | `1.1` | `.assistant/运行时/tasks/<task-id>.md` | 未声明版本的历史任务按 `1.0-legacy` 兼容读取 |
| current-task-pointer | `1.1` | `.assistant/运行时/当前任务.md` | 缺失 `entry_host` 的旧文件按 `1.0-legacy` 兼容读取 |
| recovery-index | `1.1` | `.assistant/运行时/恢复索引.md` | 缺失 `derived_from` 的旧文件按 `1.0-legacy` 兼容读取 |
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

## 升级规则

1. 新建任务状态文件时，必须显式写入 `schema_version`
2. 旧任务文件若未声明 `schema_version`，恢复时按 `task-runtime v1.0-legacy` 处理
3. 任何 schema 变更先更新本文件，再更新协议文档或模板
4. 若 reader 无法安全兼容旧版本，必须停止自动恢复并写入决策说明
