# Shared Memory v2 Live Migration Plan Review

Verdict: `revise`

## Findings

### P1 · TODO 3 给 `恢复索引.md` 设计的是多行 YAML `derived_from`，但现有 checker 只接受单行内联数组；按计划实现后核心验收仍会失败

- 计划在 `TODO 3` 里明确要求把 `derived_from` 写成 block-style YAML：
  - `docs/tasks/shared-memory-v2-live-migration/plan.md:98-103`
- 但 `scripts/check-shared-memory-layers.ps1` 的 `Get-InlineArrayValues` 只接受 `derived_from: [a, b]` 这种单行内联数组；只要不是 `[` 开头、`]` 结尾就直接返回空：
  - `scripts/check-shared-memory-layers.ps1:51-77`
- `skills/obsidian-memory/scripts/check-shared-memory.ps1` 也用同一套解析逻辑：
  - `skills/obsidian-memory/scripts/check-shared-memory.ps1:57-80`
- 这意味着按 TODO 3 原样落地后，`check-shared-memory-layers.ps1 -VaultRoot .assistant` 仍会把 `恢复索引.md` 视为“缺少可用 derived_from”，与 `验收标准` 的 PASS 目标直接冲突。

### P1 · TODO 5 把 live `当前任务.md` 的共享指针状态写死为某个捕获时刻的值，不是“迁移时按现场保留”；这会把单写者运行时回写成过期状态

- 计划要求：
  - 只追加 `entry_host: claudecode`
  - `updated:` 固定保留 `2026-04-27 13:45:00`
  - 正文表格“逐字保留”
  - 见 `docs/tasks/shared-memory-v2-live-migration/plan.md:118-121`
- 但 live repo-local 文件在当前审阅时已经不是这个状态了：
  - `.assistant/运行时/当前任务.md:1-15`
  - 当前 `updated` 已是 `2026-04-27 14:10:00`
  - 当前 `status/current_doc/next step` 也已经是 `PLAN_REVIEW` / `docs/tasks/shared-memory-v2-live-migration/plan.md` / 等待 `0285a51b`
- 对 live shared pointer 来说，“保留某个计划撰写时捕获的时间戳和正文”不是窄范围迁移，而是把运行时指针回写成过期快照。这里需要改成“仅注入 `entry_host`，其余字段以 IMPLEMENT 时的 live 文件为准”，否则 scope 虽然看起来窄，实际会破坏当前运行态。

### P2 · 验收标准里的 `advance-stage.ps1 -DryRun` 不是现有可执行接口，计划还不能直接进入 IMPLEMENT

- 计划把这条命令写进 `验收标准`：
  - `docs/tasks/shared-memory-v2-live-migration/plan.md:30`
- 但现有 `scripts/advance-stage.ps1` 参数面里没有 `-DryRun`：
  - `scripts/advance-stage.ps1:3`
  - 全文件也没有任何 `DryRun` 标识
- 这会让 verification 里这一步变成不可执行说明，而不是可落地 gate。要么删掉这条人工检查，要么改成当前脚本真实支持的验证方式。

## Scope Summary

- D1 / D2 / D3 本身已经基本 baked-in：`docs/tasks/shared-memory-v2-live-migration/plan.md:33-41`, `68`, `130`, `140-142`, `170`, `176`, `182`, `186`
- affected_paths / TODO / Risks 的总体范围也大体保持在 live repo-local `.assistant` 迁移补齐，没有重新打开 shared-memory-v2 的架构面
- 当前不能进 IMPLEMENT 的原因，不是 scope 扩散，而是上面 3 个实现与验证层面的 blocker 还没收口

## File Existence

This review file exists: `docs/tasks/shared-memory-v2-live-migration/plan-review.md`

## Run 2

Verdict: `pass`

### Findings

no findings

### Closure Summary

- blocker 1 已闭合：`TODO 3` 现在明确要求 `derived_from` 使用 inline array，且直接引用了现有 checker 只解析 inline array 的事实，和 `scripts/check-shared-memory-layers.ps1` / `skills/obsidian-memory/scripts/check-shared-memory.ps1` 的当前实现一致。
- blocker 2 已闭合：`TODO 5` 现在明确要求 IMPLEMENT 时保留 live `当前任务.md` 的 `updated` / `writer` / 正文内容，只允许补一行 `entry_host: claudecode`，不再把共享指针写回为预先捕获的 stale snapshot。
- blocker 3 已闭合：验收标准里已移除不存在的 `scripts/advance-stage.ps1 -DryRun`，改为真实可执行的 `git diff --stat` / `git diff` 范围检查，与本任务“仅迁移 live repo-local .assistant 数据”的窄范围目标一致。
