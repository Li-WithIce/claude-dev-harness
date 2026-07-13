# Single-Writer PreCompact 协议

## 背景

- 本仓库继续采用 `vault-as-truth-source`：共享恢复与运行时状态以 `.assistant/` 为准。
- `.assistant/` 仍是 single-writer 模型，不允许多个入口同时重写同一份 pointer/runtime 文档。
- 当前可执行写者里，`scripts/advance-stage.ps1` 负责 stage 推进后的非 append 写回，包括：
  - `docs/tasks/{task_id}/plan.md` frontmatter
  - `.assistant/运行时/tasks/<task-id>.md`
  - `.assistant/运行时/当前任务.md`
  - `.assistant/运行时/恢复索引.md`
- PreCompact 只是 leader/worker 的协议化自检，不是新的内核 hook，也不是新的写入器；worker 只通过消息汇报，leader/entry host 才能写回。
- 本文只描述 PreCompact 场景；shared-memory 主合同仍以 `docs/shared-memory-layers.md`、`vault-template/工作流/共享记忆协议.md`、`vault-template/工作流/写回协议.md` 为准。

## Leader 可执行的两类动作与 worker 汇报

- worker 只允许通过 `team_send_message` 向 leader 汇报 pending wisdom candidate 或 ready-to-advance，不得执行动作 A 或动作 B；汇报本身不代表用户已授权记忆写入。
- leader/entry host 收到消息后，先核验当前会话中是否有用户明确授权记忆写入；只有授权存在时才可执行动作 A。动作 B 仍按 write-authorized workflow 的 stage 条件执行。

- 动作 A：pending wisdom append
  - 只有用户明确授权记忆写入后，leader/entry host 才可通过 `skills/obsidian-memory/scripts/append-runtime-inbox.ps1` 追加到 `.assistant/运行时/收件箱.md`
  - 未授权时保持消息态，只向用户提示可沉淀内容，不 append inbox、不写 memory candidate
  - 收件箱中的 task 先由 entry-router 走标准 new/switch workflow；canonical PLAN、validator 与 background `SyncOnly` 成功后，再用 exact selector 调用 `triage-runtime-inbox.ps1`
  - 需要人工选择时保持 inbox row open 并直接向用户提问；不创建第二个 decision 状态文件
  - 不允许直接改写 `.assistant/运行时/记忆-学习.md`、`记忆-决策.md`、`记忆-约定.md`、`记忆-问题.md`
- 动作 B：stage 推进写回
  - leader/entry host 只允许通过 `.assistant/entry/advance-stage.ps1`
  - 调用方必须传刚读取的 `-ExpectedStage`；新建/切换 current 使用 `-SyncOnly -ActivateCurrent`
  - 任何 task-runtime / shared pointer / `plan.md` frontmatter 的非 append 写回，都必须委托给现有 `advance-stage.ps1` 语义执行
  - 不允许手工 patch `plan.md`、`.assistant/运行时/tasks/<task-id>.md`、`.assistant/运行时/当前任务.md` 或 `.assistant/运行时/恢复索引.md`

## Mutex 协议

- worker 不获取写入锁；只发送消息并进入 stand by。
- leader/entry host 收到 PreCompact 消息后，先判断是否有用户明确授权记忆写入，再判断当前只是需要保留上下文，还是已经满足 stage 推进条件。
- 若只需要保留上下文：
  - 有明确记忆写入授权时，只做收件箱 append，且 append-only 仅限 `.assistant/运行时/收件箱.md`
  - 无授权时不写 runtime，仅保留 worker 消息并向用户提示
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
  - 先读 open `[writeback-fallback]`，再由 entry host 用同一 `TaskId/ExpectedStage -SyncOnly` 重放；普通 advance 不得二次推进
  - 成功重放在同 task stage mutex 内完成 runtime ladder，释放并按 `stage -> runtime` 顺序重取 runtime mutex 清理匹配 fallback，最后才释放 stage mutex
- 收件箱 append 成功但 stage 未推进：
  - 这是允许的降级结果
  - 说明最小恢复信息已保住，但 stage 仍停留在原位
  - 后续由 leader 决定是否在下一轮显式推进
- worker 误把 PreCompact 当成写回入口：
  - 视为协议违规
  - 只通过 `team_send_message` 把 pending wisdom / ready-to-advance 回报 leader
  - 不调用收件箱 append、stage advance，也不直接写 `.assistant/` 或 `docs/tasks/{task_id}/`

## 双向引用契约

- `skills/orchestrator/SKILL.md` 必须引用本文，作为 leader 的 PreCompact 自检协议来源。
- `skills/workflow-team/SKILL.md` 必须引用本文，作为 leader→worker callback 的单写者约束来源。
- 本文反向绑定这两个 skill：
  - `skills/orchestrator/SKILL.md`
  - `skills/workflow-team/SKILL.md`
- 如果未来修改 PreCompact 行为，先改本文，再同步改两个 skill 的协议段，保持单一解释面。
