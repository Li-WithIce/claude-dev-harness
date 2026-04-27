---
tags: [配置, schema]
created: 2026-04-01
updated: 2026-04-27
---

# Schema Versions

## 目标

记录共享记忆与开发编排相关文档的 schema 版本，避免旧任务文件在恢复时被新 reader 误解析。

## 当前版本表

| Schema | 当前版本 | 作用范围 | 兼容策略 |
|------|------|------|------|
| shared-memory-core | `1.2` | `.assistant/工作流/*.md` 的共享记忆主协议 | 入口 agent 优先读取最新协议 |
| task-runtime | `1.1` | `.assistant/运行时/tasks/<task-id>.md` | 未声明版本的历史任务按 `1.0-legacy` 兼容读取 |
| current-task-pointer | `1.1` | `.assistant/运行时/当前任务.md` | 继续保持共享指针简化 |
| recovery-index | `1.1` | `.assistant/运行时/恢复索引.md` | 继续保持派生导航视图 |
| runtime-inbox | `1.0` | `.assistant/运行时/收件箱.md` | 占位行允许保留；open 行必须使用标准表头并在恢复或分流后关闭 |
| orchestrator-current-flow | `2.2` | 工作区 `.assistant/orchestration/current-flow.md` | `2.1` 与未声明版本在 2026-06-01 前只告警；自 2026-06-01 起必须升级到 `2.2` |
| orchestrator-handoff | `2.2` | 工作区 `.assistant/orchestration/handoff.md` | `2.1` 与未声明版本在 2026-06-01 前只告警；自 2026-06-01 起必须升级到 `2.2` |
| orchestrator-decision-needed | `1.0` | 工作区 `.assistant/orchestration/decision-needed.md` | 文件缺失表示无 open decision；存在时新写回使用 `1.0` |

## task-runtime v1.1 最低字段

- `schema_version`
- `task_id`
- `task_name`
- `workspace`
- `artifact_root`
- `primary_artifact`
- `artifact_links`
- `entry_host`

## runtime-inbox v1.0 最低结构

- front matter 中显式写入 `schema_version: runtime-inbox/v1.0`
- markdown 表头固定为 `created_at | source | task_id | type | status | summary | payload`
- 默认占位行使用 `status: cleared`
- 待处理事项必须使用 `open` 或其他未关闭状态，供 health check 与 harness-status 分流

## 升级规则

1. 新建任务状态文件时，必须显式写入 `schema_version`
2. 旧任务文件若未声明 `schema_version`，恢复时按 `task-runtime v1.0-legacy` 处理
3. 任何 schema 变更先更新本文档，再更新协议文档或模板
4. 若 reader 无法安全兼容旧版本，必须停止自动恢复并写入决策说明
5. `orchestrator-current-flow` / `orchestrator-handoff` 的 `2.2` 代际用于承载 `delivery_profile` / `clarification` 语义和对应 handoff 镜像；新写回必须显式写 `schema_version`
