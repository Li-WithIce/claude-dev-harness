# Single-Writer PreCompact 协议

## 背景

- 本仓库继续采用 `vault-as-truth-source`：共享恢复与运行时状态以 `.assistant/` 为准。
- `.assistant/` 仍是 single-writer 模型，不允许多个入口同时重写同一份 pointer/runtime 文档。
- 当前可执行写者里，`scripts/advance-stage.ps1` 负责 stage 推进后的非 append 写回，包括：
  - `docs/tasks/<task-id>/plan.md` frontmatter
  - `.assistant/运行时/tasks/<task-id>.md`
  - `.assistant/运行时/当前任务.md`
  - `.assistant/运行时/恢复索引.md`
- PreCompact 只是 leader/worker 的协议化自检，不是新的内核 hook，也不是新的写入器。
- 本文只描述 PreCompact 场景；shared-memory 主合同仍以 `docs/shared-memory-layers.md`、`vault-template/工作流/共享记忆协议.md`、`vault-template/工作流/写回协议.md` 为准。

## PreCompact 触发的两类动作

- 动作 A：pending wisdom append
  - 只允许通过 `skills/obsidian-memory/scripts/append-runtime-inbox.ps1` 追加到 `.assistant/运行时/收件箱.md`
  - 后续分流继续使用现有 `promote-runtime-inbox.ps1` / `triage-runtime-inbox.ps1`
  - 不允许直接改写 `.assistant/运行时/记忆-学习.md`、`记忆-决策.md`、`记忆-约定.md`、`记忆-问题.md`
- 动作 B：stage 推进写回
  - 只允许通过 `.assistant/entry/advance-stage.ps1`
  - 任何 task-runtime / shared pointer / `plan.md` frontmatter 的非 append 写回，都必须委托给现有 `advance-stage.ps1` 语义执行
  - 不允许手工 patch `plan.md`、`.assistant/运行时/tasks/<task-id>.md`、`.assistant/运行时/当前任务.md` 或 `.assistant/运行时/恢复索引.md`

## Mutex 协议

- PreCompact 前先判断：当前只是需要保留上下文，还是已经满足 stage 推进条件。
- 若只需要保留上下文：
  - 只做收件箱 append
  - append-only 仅限 `.assistant/运行时/收件箱.md`
- 若需要 stage 推进：
  - 先视为要进入 `advance-stage` 的 single-writer 区域
  - 必须先尝试 acquire 推进锁
  - 获取失败时必须 `cooperative-yield`
- `cooperative-yield` 规则：
  - 不抢写
  - 不并发重写 shared pointer
  - 给已经在执行的 `advance-stage` 主流程让路
- 允许的并发边界：
  - 不同任务的普通思考/读取可以并行
  - append-only 写 `.assistant/运行时/收件箱.md` 仍应串行提交，不假设文件级并发安全
  - 一旦进入 `advance-stage`，视为该 task 的非 append 写回窗口被占用
- 建议重试策略：
  - 最多重试少量次数
  - 若仍失败，停止写回并把状态通过消息回 leader
  - 不在 PreCompact 阶段自建 lockfile、daemon 或外部协调器

## 失败模式与降级

- acquire 超时：
  - 不继续抢写
  - 记录需要恢复的最小上下文
  - 通过 `team_send_message` 或当前 callback 报告 leader，等待正常 stage 流收口
- `advance-stage` 中途失败：
  - 以脚本 stderr/stdout 为准
  - 不手工补写 shared pointer
  - 回到普通修复流程，再由 entry host 重新推进
- 收件箱 append 成功但 stage 未推进：
  - 这是允许的降级结果
  - 说明最小恢复信息已保住，但 stage 仍停留在原位
  - 后续由 leader 决定是否在下一轮显式推进
- worker 误把 PreCompact 当成“直接落 wisdom 文件”：
  - 视为协议违规
  - 应回退到收件箱 append 路径
  - 不把 `.assistant/运行时/记忆-*.md` 当作 PreCompact 的直接目标

## 双向引用契约

- `skills/orchestrator/SKILL.md` 必须引用本文，作为 leader 的 PreCompact 自检协议来源。
- `skills/workflow-team/SKILL.md` 必须引用本文，作为 leader→worker callback 的单写者约束来源。
- 本文反向绑定这两个 skill：
  - `skills/orchestrator/SKILL.md`
  - `skills/workflow-team/SKILL.md`
- 如果未来修改 PreCompact 行为，先改本文，再同步改两个 skill 的协议段，保持单一解释面。
