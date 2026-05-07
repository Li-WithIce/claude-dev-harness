# Maestro-Flow Analysis

## 1. 项目结构与主流程概览

### 1.1 结构分层

Maestro-Flow 不是单一 CLI，而是 4 层叠加：

| 层 | 主要目录 | 作用 |
|---|---|---|
| 入口与 prompt 资产 | `.claude/commands/`, `.claude/skills/`, `.codex/skills/`, `workflows/`, `templates/` | slash command、技能、工作流 markdown、JSON 模板 |
| 核心运行时 | `src/commands/`, `src/tools/`, `src/hooks/`, `src/utils/`, `src/mcp/` | CLI、MCP tools、hooks、状态 schema、delegate |
| 协调/执行引擎 | `dashboard/src/server/coordinator/`, `dashboard/src/server/execution/`, `dashboard/src/server/commander/`, `src/team/` | 命令链路由、wave 调度、自动指挥官、团队 phase 管理 |
| 可视化与协作面 | `dashboard/src/client/`, `dashboard/src/server/routes/`, `dashboard/src/server/rooms/` | dashboard、issue board、meeting room、实时事件 |

高频关键路径：

- 命令入口：`README.md`, `.claude/commands/maestro.md`, `workflows/maestro.md`
- 状态协议：`src/utils/state-schema.ts`, `templates/state.json`
- 计划/执行协议：`workflows/plan.md`, `workflows/execute.md`, `templates/plan.json`, `templates/task.json`
- 自动执行：`dashboard/src/server/execution/execution-scheduler.ts`, `wave-executor.ts`, `src/commands/delegate.ts`
- 团队协作：`.claude/skills/team-lifecycle-v4/`, `src/tools/team-msg.ts`, `team-mailbox.ts`, `team-tasks-mcp.ts`, `team-tasks.ts`

### 1.2 主流程

主干流程是 scratch-based artifact pipeline，不再把 phase 当成目录真相源，而是把 phase 当标签：

`init -> roadmap/spec -> analyze -> plan -> execute -> verify -> review/test -> milestone-audit -> milestone-complete`

真实实现上，这条链分成 3 个层次：

1. `/maestro` 先做意图识别与命令链选择  
   入口：`.claude/commands/maestro.md`, `workflows/maestro.md`, `dashboard/src/server/coordinator/chain-map.ts`

2. 每个阶段命令按模板生成或消费 artifact  
   例如：
   - analyze 产出 scratch context
   - plan 产出 `plan.json` + `.task/TASK-*.json`
   - execute 消费 wave DAG 并写 `.summaries/`

3. `state.json.artifacts[]` 作为注册表串起全链路  
   核心协议：`src/utils/state-schema.ts`

### 1.3 状态与 artifact 组织

Maestro 的状态面不是单点，而是多个专用目录：

| 数据域 | 主要路径 | 用途 |
|---|---|---|
| 项目主状态 | `.workflow/state.json` | 里程碑、artifact registry、累计上下文、transition history |
| 主产物区 | `.workflow/scratch/<date>-<type>-<slug>/` | analyze/plan/execute/verify 各阶段产物 |
| issue 闭环 | `.workflow/issues/issues.jsonl` | issue 生命周期、调度状态 |
| `/maestro` 会话 | `.workflow/.maestro/<session>/status.json` | 命令链执行进度、step engine、resume |
| agent 团队域 | `.workflow/.team/<session>/...` | team session、消息总线、agent task、transition log |
| 人类协作域 | `.workflow/collab/...` | 成员、活动、任务、overlay、个人 spec |
| 指挥官域 | `.commander/decisions.jsonl` | autopilot 决策轨迹 |

这里最值得注意的是：它用“目录分域 + 文件专责”代替了单一大状态文件。

## 2. 可迁移到 claude-dev-harness 的具体机制

### 2.1 可直接复用

#### A. 任务定义模板的“强约束字段”

最值得直接借鉴的是 `templates/task.json` + `workflows/plan.md` 对任务定义的硬约束：

- `read_first[]`：强制执行者先读哪些文件
- `convergence.criteria[]`：必须是 grep/命令可验证的收敛条件
- `action` / `implementation[]`：禁止“align with / keep consistent”这类空指令，必须写出精确目标值

这套约束比“写一个计划”更重要，因为它直接提升执行任务的可落地性，适合迁到 harness 的 `plan.md` / `test.md` / skill 指南里。

关键路径：

- `templates/task.json`
- `workflows/plan.md`

#### B. artifact registry 思路

`src/utils/state-schema.ts` 把 `artifacts[]` 作为统一注册表，而不是让各阶段靠目录猜状态：

- artifact 带 `type / milestone / phase / scope / path / status / depends_on`
- `current_phase`、`phases_summary` 由 artifact 派生，而不是手工维护

这对 harness 的价值是：如果后续要扩 PLAN/IMPLEMENT/REVIEW/TEST 的链路，应该优先扩“注册表字段”，而不是堆更多指针文件。

关键路径：

- `src/utils/state-schema.ts`
- `templates/state.json`

#### C. JSONL / 单文件记录模式

Maestro 在并发与审计上大量使用 append-only 或 per-record file：

- `issues.jsonl`
- `.workflow/.team/<session>/.msg/messages.jsonl`
- `.workflow/.team/<session>/.msg/mailbox.jsonl`
- `.workflow/collab/tasks/<id>.json`
- `.workflow/.team/<session>/tasks/<id>.json`

这套模式对 harness 很有参考价值，特别适合：

- mailbox / inbox
- task board 审计日志
- transition history
- 长期 lessons / findings 归档

### 2.2 需改造后复用

#### A. `/maestro` 的链路路由器

`/maestro` 本质是一个“意图 -> chain -> step engine”的编排器：

- markdown 定义：`.claude/commands/maestro.md`, `workflows/maestro.md`
- 代码实现：`dashboard/src/server/coordinator/chain-map.ts`, `workflow-coordinator.ts`

值得复用的不是它的 slash command 语法，而是这 3 个机制：

- 先做 task type / chain 解析
- 再做 state-aware next-step 选择
- 最后做 per-step engine 选择

对 harness 的改造建议：

- 保留“workflow descriptor / node catalog / chain”思路
- 不照搬 markdown + TS 双维护
- 让 workflow descriptor 成为唯一真相源，避免规则同时存在于文档和代码

#### B. wave-based parallel execution

`execution-scheduler.ts` + `wave-executor.ts` 体现的是成熟的多任务执行壳层：

- queue / retryQueue / runningSlots
- stall detection
- exponential backoff retry
- slot acquire/release
- per-task executor routing
- execution journal recovery

这套机制适合迁到 harness 的场景：

- 多 teammate 并发执行
- 阶段内 task fan-out
- 失败重试 / 超时回收

但需要改造：

- Maestro 假设有 web dashboard、agent manager、issue board
- harness 当前更轻，更依赖文件协议和 entry scripts
- 因此可借鉴调度状态机，不宜整体照抄服务端框架

关键路径：

- `dashboard/src/server/execution/execution-scheduler.ts`
- `dashboard/src/server/execution/wave-executor.ts`
- `src/commands/delegate.ts`

#### C. team skill 的“角色注册表 + pipeline 配置”

Maestro 的 team skill 不只是 prompt，而是半结构化编排包：

- skill 入口：`.claude/skills/team-lifecycle-v4/SKILL.md`
- pipeline 定义：`.claude/skills/team-lifecycle-v4/specs/pipelines.md`
- team config：`.claude/skills/team-quality-assurance/specs/team-config.json`

值得借鉴的点：

- role registry 明确 role -> task prefix -> responsibility
- pipeline 可以声明 blockedBy、parallel stages、checkpoint
- shared memory 字段能按 owner 标注

对 harness 的改造建议：

- 作为 `workflow-team` / team preset 的上层模板语法参考
- 不直接复用 Claude Skill 目录结构
- 更适合抽成 repo 内统一的 YAML/JSON descriptor

#### D. hook 与 spec 注入体系

Maestro 的 hook 系统值得借鉴，但应缩小范围：

- hook engine：`src/hooks/hook-engine.ts`
- hook registry：`src/hooks/workflow-hooks.ts`
- spec loader：`src/tools/spec-loader.ts`

可借鉴点：

- before/after run/node/command 的可插拔生命周期
- prompt transform hook
- baseline/team/personal 三层 spec 加载

对 harness 更合理的落点：

- 只保留少数 entry hooks
- 让 shared-memory / plan frontmatter / task context 注入更可控
- 不要一开始把 9+ hooks 全搬进来

### 2.3 不适合引入

#### A. 多套协作运行时并存

Maestro 当前至少有 3 套“团队协作”实现：

1. `.workflow/collab/`：人类团队协作  
   代码：`src/tools/team-tasks.ts`, `guide/team-lite-guide.md`

2. `.workflow/.team/`：agent 团队消息/任务/状态  
   代码：`src/tools/team-msg.ts`, `team-mailbox.ts`, `team-tasks-mcp.ts`

3. `dashboard/src/server/rooms/`：meeting-room 内存态 mailbox/task board  
   代码：`room-mailbox.ts`, `room-task-board.ts`

这说明它的协作模型是进化叠加出来的，不是单一最小面。对 harness 不适合直接引入，因为会马上造成第二套、第三套 task board。

#### B. 文档协议与代码协议双维护

Maestro 在多个关键面存在“文档一份、代码一份”的双维护：

- `/maestro` chain map：`workflows/maestro.md` vs `dashboard/src/server/coordinator/chain-map.ts`
- pipeline 规则：skill markdown/specs vs runtime TS

这会提高表达力，但 drift 风险很高。harness 现在已经在收敛 workflow descriptor，不该把这种双真相模式带进来。

#### C. dashboard / commander 全套控制平面

Commander + dashboard 很强，但太重：

- `dashboard/src/server/commander/commander-agent.ts`
- `dashboard/src/server/routes/*`
- `dashboard/src/client/*`

它依赖：

- 实时 event bus
- websocket / sse
- issue board
- agent manager
- persistent dashboard config

对 harness 当前阶段而言，性价比不高。更合理的做法是先吸收它的“调度状态机”和“artifact/state 协议”，而不是把 web control plane 一起引入。

#### D. legacy 兼容层过厚

虽然 README 宣称 scratch-based artifact registry，但 dashboard `StateManager` 仍在读：

- `.workflow/phases/<slug>/index.json`
- `.workflow/phases/<slug>/.task/TASK-*.json`
- `current_phase`, `phases_summary`

而 `state-schema.ts` 又把这些字段降级为派生值或迁移兼容层。说明运行时已经存在新旧模型并存。harness 不应把这种历史包袱一起复制。

关键路径：

- `src/utils/state-schema.ts`
- `dashboard/src/server/state/state-manager.ts`

## 3. 对 claude-dev-harness 的迁移建议

### 3.1 优先引入

1. 任务 schema 的硬约束：`read_first`、可验证 `convergence.criteria`、禁止模糊 action。
2. artifact registry 思路：让阶段推进和输出登记更多依赖结构化注册表，而不是散落指针。
3. per-session JSONL / per-record file：适合 mailbox、task log、transition history。
4. team preset / role pipeline 的结构化描述：角色、blockedBy、parallel stages、checkpoint 都值得吸收。

### 3.2 适合做成 harness 后续增强的点

1. workflow descriptor 的 node catalog / template schema  
   参考：`templates/workflows/specs/node-catalog.md`, `template-schema.md`
2. 多执行器路由  
   参考：`workflows/execute.md` 的 per-task executor resolution
3. 轻量 autopilot / scheduler  
   参考：`commander-agent.ts`, `execution-scheduler.ts`

### 3.3 明确不要照搬的点

1. 全量 dashboard / commander 控制平面
2. `.workflow/collab` + `.workflow/.team` + room runtime 三套协作模型
3. `.claude` / `.codex` 双套 command/skill 资产树
4. markdown 协议和 TS 逻辑双维护

## 4. 关键文件路径清单

### 4.1 主流程与协议

- `README.md`
- `.claude/commands/maestro.md`
- `workflows/maestro.md`
- `workflows/plan.md`
- `workflows/execute.md`
- `templates/state.json`
- `templates/plan.json`
- `templates/task.json`
- `src/utils/state-schema.ts`

### 4.2 自动执行与调度

- `dashboard/src/server/execution/execution-scheduler.ts`
- `dashboard/src/server/execution/wave-executor.ts`
- `dashboard/src/server/commander/commander-agent.ts`
- `src/commands/delegate.ts`

### 4.3 团队协作与状态

- `.claude/skills/team-lifecycle-v4/SKILL.md`
- `.claude/skills/team-lifecycle-v4/specs/pipelines.md`
- `.claude/skills/team-quality-assurance/specs/team-config.json`
- `src/tools/team-msg.ts`
- `src/tools/team-mailbox.ts`
- `src/tools/team-tasks-mcp.ts`
- `src/tools/team-tasks.ts`
- `src/team/phase-orchestrator.ts`

### 4.4 hooks / 扩展 / 规范注入

- `src/hooks/hook-engine.ts`
- `src/hooks/workflow-hooks.ts`
- `src/tools/spec-loader.ts`
- `src/core/overlay/loader.ts`
- `.mcp.json`

## 5. 总结判断

Maestro-Flow 最有价值的不是“49 个命令”或“dashboard”，而是它把多 agent 开发拆成了 3 类清晰资产：

- **结构化状态**：`state.json` + artifact registry + session dirs
- **结构化任务**：`plan.json` + `TASK-*.json` + wave DAG
- **结构化协作**：role registry + pipeline config + mailbox/task board

对 `claude-dev-harness` 来说，最值得吸收的是这些“协议层”与“调度层”的设计；最不该照搬的是它因为长期演化而形成的多套协作运行时、双重真相源和重型控制平面。
