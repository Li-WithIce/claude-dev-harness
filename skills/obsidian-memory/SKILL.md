---
name: obsidian-memory
description: Use when a task needs shared Obsidian memory, session recovery, runtime writeback, or stable preference lookup from the shared `.assistant` vault.
---

# Obsidian Memory

> **已合入 using-superpowers**：核心读取顺序、写回规则和 guardrails 已内联到 `using-superpowers` skill 中。
> 本文件保留为详细参考文档，无需在每次对话中单独调用。

Claude、Codex、Gemini 共用同一份 Obsidian 记忆仓库：
`{VAULT_PATH}`

## When to Use

- 用户说“继续”“恢复”“resume”
- 任务需要项目偏好、工具路径、系统边界或历史上下文
- 多步骤任务开始、切换、暂停或收尾时，需要写回共享运行时状态
- 需要判断一条信息该写到运行时、配置还是收件箱

## Read Order

- 快速了解：`首页.md` -> `配置\系统信息.md` -> `配置\用户偏好.md` -> `配置\工具与组件.md`
- 恢复任务：`运行时\恢复索引.md` -> `运行时\当前任务.md`（共享指针） -> `运行时\tasks\<task-id>.md`（任务级详细状态） -> `运行时\中断任务.md` -> `运行时\上次会话.md`
- 长期稳定记忆：优先只读 `配置\*.md`，按需补读 `工作流\*.md` 与 `运行时\记忆候选归档.md`

## Writeback

- 单写者：只有入口 agent（Claude Code）写 `当前任务.md`、`中断任务.md`、`上次会话.md`、`恢复索引.md`
- Codex / Gemini 只写 `docs/<task-id>/*` 和 `运行时\tasks\<task-id>.md`
- 多步骤任务开始、切换或继续：入口 agent 更新 `运行时\当前任务.md`（共享指针） + `运行时\tasks\<task-id>.md`
- 任务暂停或待续：入口 agent 同步更新 `运行时\tasks\<task-id>.md` 和 `运行时\中断任务.md`
- 阶段完成：入口 agent 更新 `运行时\上次会话.md` 并刷新 `运行时\恢复索引.md`
- 未确认的稳定偏好先写 `运行时\记忆候选.md`
- 已结束生命周期的候选移入 `运行时\记忆候选归档.md`
- 新事项先写 `运行时\收件箱.md`

## Guardrails

- 共享真相源只在 `{VAULT_PATH}`
- `当前任务.md` 只是共享指针，不承载完整任务细节
- 不在 `.claude`、`.codex`、`.gemini` 下创建平行 runtime note
- 不在 `MEMORY.md`、`配置\*.md`、`配置\引导状态.md` 记录当前任务
- 长期记忆提升前必须得到用户确认

## Tooling

- Consistency check: `scripts/check-shared-memory.ps1`
- One-click health entry: `scripts/run-memory-health.ps1`
- One-click maintenance entry: `scripts/maintain-shared-memory.ps1`
- Candidate archiver: `scripts/archive-memory-candidates.ps1`
- Safe repair helper: `scripts/repair-shared-memory.ps1`
- Markdown report writer: `scripts/write-memory-health-report.ps1`
- Workspace quick entry: `..\..\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH}`
- Workspace maintenance entry: `..\..\scripts\memory-maintain.ps1 -VaultRoot {VAULT_PATH}`
- Workspace archive helper: `scripts/archive-memory-candidates.ps1 -VaultRoot {VAULT_PATH}`
- Workspace repair helper: `scripts/repair-shared-memory.ps1 -VaultRoot {VAULT_PATH}`
- Workspace report helper: `..\..\scripts\memory-health-report.ps1 -VaultRoot {VAULT_PATH}`

## References

- `{VAULT_PATH}\工作流\共享记忆协议.md`
- `{VAULT_PATH}\工作流\写回协议.md`
- `{VAULT_PATH}\工作流\恢复协议.md`
- `{VAULT_PATH}\工作流\记忆管理协议.md`
