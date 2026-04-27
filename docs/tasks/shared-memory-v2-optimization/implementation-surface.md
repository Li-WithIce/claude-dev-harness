# Shared Memory v2 - Implementation Surface

本文只盘点 `D:\data\claude-dev-harness` 里今天真实生效的 shared-memory 实现面，不讨论目标协议或待实现 v2 设计。

## 1. `.assistant` 运行时文件实际使用面

当前 repo-local vault 里已经落盘并被真实使用的运行时文件：

- `.assistant/运行时/当前任务.md`
- `.assistant/运行时/恢复索引.md`
- `.assistant/运行时/收件箱.md`
- `.assistant/运行时/中断任务.md`
- `.assistant/运行时/上次会话.md`
- `.assistant/运行时/记忆候选.md`
- `.assistant/运行时/记忆候选归档.md`
- `.assistant/运行时/tasks/<task-id>.md`

当前 repo-local vault 里不存在、但代码仍会主动读取或按需生成的文件 / 路径：

- `.assistant/运行时/runtime.lock.json`
- `.assistant/orchestration/current-flow.md`
- `.assistant/entry/`
- `.assistant/运行时/记忆体检报告.md`

### 运行时文件映射

| 路径 | 真实 writer | 真实 reader | 现状备注 |
|---|---|---|---|
| `.assistant/运行时/当前任务.md` | `scripts/advance-stage.ps1`; `skills/obsidian-memory/scripts/repair-shared-memory.ps1` | `runtime-inbox-common.ps1`; `check-shared-memory.ps1`; `runtime-hooks/claude/posttooluse.js`; `runtime-hooks/claude/stop.js` | 热路径和修复路径都写；schema 不完全一致 |
| `.assistant/运行时/tasks/<task-id>.md` | `scripts/advance-stage.ps1`; `promote-runtime-inbox.ps1`; `repair-shared-memory.ps1` | `advance-stage.ps1` 的 recovery rebuild; `check-shared-memory.ps1` | 至少 3 种 shape 并存，且模板还是另一套 |
| `.assistant/运行时/恢复索引.md` | `advance-stage.ps1`; `repair-shared-memory.ps1`; `posttooluse.js` | 人工恢复流程; `check-shared-memory.ps1` | 至少 3 个 writer，输出格式不统一 |
| `.assistant/运行时/收件箱.md` | `append-runtime-inbox.ps1`; `triage-runtime-inbox.ps1`; `promote-runtime-inbox.ps1`; `posttooluse.js`; `repair-shared-memory.ps1` | `triage-runtime-inbox.ps1`; `promote-runtime-inbox.ps1`; `check-shared-memory.ps1` | 当前最完整的 shared-memory 子系统 |
| `.assistant/运行时/中断任务.md` | `promote-runtime-inbox.ps1`; `repair-shared-memory.ps1` | `check-shared-memory.ps1`; `repair-shared-memory.ps1` | 已落盘文件和脚本生成表头不一致 |
| `.assistant/运行时/上次会话.md` | `repair-shared-memory.ps1` 只负责补齐模板 | `check-shared-memory.ps1` | 日常热路径基本不更新，更多是 seed/repair 文件 |
| `.assistant/运行时/记忆候选.md` | `repair-shared-memory.ps1`; `archive-memory-candidates.ps1` | `check-shared-memory.ps1`; 归档脚本 | 属于 memory-maintenance，不参与 stage 推进 |
| `.assistant/运行时/记忆候选归档.md` | `repair-shared-memory.ps1`; `archive-memory-candidates.ps1` | 归档脚本 | 维护面，不是恢复热路径 |
| `.assistant/运行时/runtime.lock.json` | `repair-shared-memory.ps1` | `posttooluse.js`; `check-shared-memory.ps1`; `repair-shared-memory.ps1` | 锁只覆盖 repair/hook 路径，`advance-stage.ps1` 不参与 |
| `.assistant/运行时/记忆体检报告.md` | `write-memory-health-report.ps1` | 人工查看 | 诊断产物，不是协议核心文件 |
| `.assistant/orchestration/current-flow.md` | 不在本 repo-local vault 中维护 | `runtime-inbox-common.ps1`; `check-shared-memory.ps1`; `repair-shared-memory.ps1`; `posttooluse.js`; `stop.js` | 这是 shared-memory today 最大的隐性耦合输入之一 |

## 2. 脚本实现面

### 2.1 热路径

- `scripts/advance-stage.ps1`
  - 当前唯一稳定的 stage 推进入口。
  - 写 `docs/tasks/<task-id>/plan.md` frontmatter 后，同步写：
    - `.assistant/运行时/tasks/<task-id>.md`
    - `.assistant/运行时/当前任务.md`
    - `.assistant/运行时/恢复索引.md`
  - 它不读 `current-flow.md`，也不使用 `runtime.lock.json`。
  - 它当前把 `恢复索引.md` 当成由 `运行时/tasks/*.md` 汇总出的 lite 列表，而不是协议文档里那种 richer recovery view。

### 2.2 inbox / repair / health 维护面

repo 根下很多 `scripts/*.ps1` 只是 wrapper；真实逻辑在 `skills/obsidian-memory/scripts/*`。wrapper 通过 `scripts/resolve-obsidian-memory-script.ps1` 分发，且不仅能调 repo 内脚本，也能回落到用户 home 下的 agent skills。

| 入口 | 真实逻辑 | 读/写面 | 备注 |
|---|---|---|---|
| `scripts/append-runtime-inbox.ps1` | `skills/obsidian-memory/scripts/append-runtime-inbox.ps1` | 写 `收件箱.md` | 若未显式传 `TaskId`，优先从 `current-flow` 推断 |
| `scripts/triage-runtime-inbox.ps1` | `triage-runtime-inbox.ps1` | 只读写 `收件箱.md` | 相对收敛，没有外扩写入 |
| `scripts/promote-runtime-inbox.ps1` | `promote-runtime-inbox.ps1` | 写 `docs/tasks/<task-id>/plan.md`、`运行时/tasks/<task-id>.md`、`中断任务.md`、可选 `orchestration/decision-needed.md`、并清 inbox | 它是 inbox-first 到 task-runtime 的桥 |
| `scripts/repair-shared-memory.ps1` | `repair-shared-memory.ps1` | 读写 `runtime.lock.json`、`当前任务.md`、`恢复索引.md`、`收件箱.md`、`中断任务.md`、`上次会话.md`、`记忆候选*.md`、`运行时/tasks/` | shared-memory 维护面最重的脚本 |
| `scripts/memory-health.ps1` | `run-memory-health.ps1` | 只读检查 | 包装 `check-shared-memory.ps1` |
| `scripts/memory-health-report.ps1` | `write-memory-health-report.ps1` | 读 vault，写 `记忆体检报告.md` | 诊断报告，不修复 |
| `scripts/memory-maintain.ps1` | `maintain-shared-memory.ps1` | 调 health / archive / repair | 维护总入口 |
| `scripts/archive-memory-candidates.ps1` | `archive-memory-candidates.ps1` | 读写 `记忆候选.md` / `记忆候选归档.md` | 只碰 memory candidate 面 |

### 2.3 hook 面

- `runtime-hooks/claude/posttooluse.js`
  - 每次 tool write 后读取 `当前任务.md`、`current-flow.md`、`恢复索引.md`、`收件箱.md`、`runtime.lock.json`
  - 会在 foreign lock 时向 `收件箱.md` 追加 `lock-blocked`
  - 会自写 `恢复索引.md`
- `runtime-hooks/claude/stop.js`
  - 读取 `当前任务.md` 和 `current-flow.md`
  - 只做退出前诊断，不写 vault

结论：shared-memory 的真实热路径不是单脚本，而是 `advance-stage.ps1 + claude hooks + obsidian-memory maintenance scripts` 叠出来的。

## 3. 与 orchestrator / current-flow 的真实耦合

这里最关键的事实不是“有没有协议写 current-flow”，而是“哪些代码今天仍然依赖它”。

- `scripts/advance-stage.ps1`
  - 基本不依赖 `current-flow.md`
  - 它以 `docs/tasks/<task-id>/plan.md` 为 stage/tool 真相源，再把结果写回 vault
- `skills/obsidian-memory/scripts/runtime-inbox-common.ps1`
  - `Resolve-EntryTaskId` 明确是 `current-flow -> 当前任务.md -> unknown`
  - 所有 inbox append/promotion 路径都继承这个优先级
- `skills/obsidian-memory/scripts/check-shared-memory.ps1`
  - 在提供 `-OrchestratorFlowPath` 时，会校验 `current-flow` 和共享指针 / task runtime / artifact 路径是否一致
  - 不提供时则跳过这部分扫描
- `skills/obsidian-memory/scripts/repair-shared-memory.ps1`
  - 当 `当前任务.md` 空闲、但 `current-flow` 活跃时，会用 `current-flow` 反填共享指针
- `runtime-hooks/claude/posttooluse.js`
  - 会把 pointer 和 `current-flow` 合并成一个 active snapshot
  - 当 pointer idle 而 `current-flow` active 时，优先信 `current-flow`
- `runtime-hooks/claude/stop.js`
  - 若 pointer idle、但 `current-flow` active，会报退出警告

高信号结论：

- repo-local `.assistant` 当前根本没有 `orchestration/current-flow.md`，但代码路径仍把它当成合法输入。
- 所以 shared-memory today 实际横跨两种 vault shape：
  - repo-local lite vault：只有 `运行时/`
  - installed-workspace / legacy vault：还带 `orchestration/current-flow.md`

## 4. vault 内部的真实漂移点

### 4.1 同一文件多 writer、多 schema

- `恢复索引.md`
  - `advance-stage.ps1` 写的是简化列表：`- task_id | stage | updated`
  - `repair-shared-memory.ps1` 写的是 sectioned recovery view
  - `posttooluse.js` 写的也是 sectioned view，但固定把 `中断任务 Top 3` 写成 `- 无`
- `当前任务.md`
  - `advance-stage.ps1` 会写 `工具 / Tool Profile / Model`
  - `repair-shared-memory.ps1` 会重写成不含这些字段的版本
- `运行时/tasks/<task-id>.md`
  - `advance-stage.ps1` 写的是 `Task Mirror`
  - `promote-runtime-inbox.ps1` / `repair-shared-memory.ps1` 写的是最小 `task-runtime/v1.1`
  - `.assistant/模板/任务状态模板.md` 又定义了更丰富、且阶段枚举不同的模板
- `中断任务.md`
  - 当前 repo 里的实际文件是中文表头
  - `promote-runtime-inbox.ps1` 和 `repair-shared-memory.ps1` 生成的是英文表头

### 4.2 单写者 / lock 只覆盖了一部分实现面

- 协议上有单写者和 `runtime.lock.json`
- 真实代码里只有：
  - `repair-shared-memory.ps1` 会创建和消费锁
  - `posttooluse.js` 会读取锁并在冲突时写 inbox
  - `check-shared-memory.ps1` 会检查锁是否过期
- 但 `advance-stage.ps1` 这个最核心的热 writer 完全不参与锁

这意味着今天的 single-writer 更像“部分工具遵守的约定”，不是统一的 runtime contract。

### 4.3 team task-board 与 vault 没有自动一致性

- 仓库脚本、hooks、health checker 里没有任何一处实际调用 `team_task_list` / `team_task_update`
- `team task-board` 目前只存在于：
  - role prompts / 文档约束
  - `.claude/settings.local.json` 的工具权限
  - 某些 task mirror 里的纯文本引用
- `check-shared-memory.ps1` 只校验 vault 与 `current-flow` / artifacts，不校验 MCP task-board

所以今天的 team-board 是外部系统状态，vault 是本地状态，二者没有自动 reconcile；一旦人工漏同步，就会 drift。

## 5. 重复或歧义入口

### 5.1 wrapper 和真实实现分离

- repo 入口：
  - `scripts/append-runtime-inbox.ps1`
  - `scripts/triage-runtime-inbox.ps1`
  - `scripts/promote-runtime-inbox.ps1`
  - `scripts/memory-health.ps1`
  - `scripts/memory-health-report.ps1`
  - `scripts/memory-maintain.ps1`
  - `scripts/repair-shared-memory.ps1`
- 真实实现：
  - `skills/obsidian-memory/scripts/*`

再加上 `resolve-obsidian-memory-script.ps1` 允许从 repo 内或用户 home 下的 agent skill 目录选脚本，shared-memory 命令今天不是单一加载源。

### 5.2 vault root 解析是多来源的

`skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1` 会按以下顺序找 vault：

- 显式 `-VaultRoot`
- `CLAUDE_DEV_HARNESS_VAULT_PATH`
- `OBSIDIAN_SHARED_VAULT`
- `current-flow.shared_vault_root`
- `WorkspaceRoot/.assistant`
- 环境变量里的 workspace root
- `OrchestratorFlowPath` 的父 `.assistant`
- 当前目录向上找 `.assistant`
- 当前目录下的 `.assistant`

同一命令在不同启动位置、不同 env 下可以打到不同 vault。

### 5.3 “当前任务是谁” 的判断顺序也不统一

- inbox append / promotion：优先 `current-flow`
- `posttooluse.js`：pointer idle 时会偏信 `current-flow`
- `advance-stage.ps1`：不看 `current-flow`
- `repair-shared-memory.ps1`：pointer idle 时可用 `current-flow` 回填

这意味着“当前任务真相”今天不是一个统一入口函数。

## 6. Highest-signal conclusions

- shared-memory 真正的热路径只有一半已经 lite 化：`advance-stage.ps1` 以 `plan.md` 为真相源，但 inbox / repair / hooks 仍强依赖 `current-flow` 兼容路径。
- 最大的实现债不是“文件太少”，而是“同一文件被多个 writer 以不同 schema 写”：
  - `恢复索引.md`
  - `当前任务.md`
  - `运行时/tasks/<task-id>.md`
  - `中断任务.md`
- `runtime.lock.json` 目前不是统一锁，只是 repair/hook 局部锁；如果 v2 要强化 single-writer，这是最直接的收紧点。
- team task-board 与 vault today 是两个平行状态面，没有自动 reconcile；如果后续要把 team-mode 作为一等路径，必须先明确谁是唯一真相源。
- 任何 v2 收紧如果不先统一“repo-local lite vault”和“installed-workspace + current-flow vault”这两种现实 shape，后续 health / repair / recovery 只会继续分叉。
