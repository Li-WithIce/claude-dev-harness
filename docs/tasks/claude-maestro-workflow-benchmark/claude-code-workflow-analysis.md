---
task_id: claude-maestro-workflow-benchmark
artifact: claude-code-workflow-analysis
source_repo: D:\data\Claude-Code-Workflow-main
source_version: claude-code-workflow v7.3.11
analyst: claudecode
updated: 2026-04-27
---

# Claude-Code-Workflow (CCW) 对照分析

本文档以 `D:\data\Claude-Code-Workflow-main`（CCW 主线，npm 包 `claude-code-workflow@7.3.11`）为对照对象，提炼对 `D:\data\claude-dev-harness`（本仓库 harness-lite）有借鉴价值的架构思想、工作流机制、共享状态、artifact 组织、自动化钩子与多 agent 协作协议。范围只做分析与判断，不修改任何代码。

---

## 1. CCW 项目结构总览

### 1.1 顶层目录骨架

```
Claude-Code-Workflow-main/
├── bin/                    # 包入口（ccw.js / ccw-mcp.js）
├── ccw/
│   ├── bin/                # 实际 CLI 入口（ESM）
│   ├── src/                # TS 源码（cli + 服务端 + tools + core）
│   │   ├── cli.ts
│   │   ├── commands/       # 子命令（hook, install, issue, memory, session, team, ...）
│   │   ├── core/           # 服务端 server.ts、routes、services、hooks、memory
│   │   ├── tools/          # 通用工具（cli-executor, command-registry, schemas, ...）
│   │   └── utils/          # 通用工具函数
│   ├── frontend/           # 前端 (workspace) — 仪表盘 + a2ui
│   └── tests/              # 单元 / e2e / visual 测试（node --test）
├── .claude/                # 安装到目标项目 ~/.claude 的样板
│   ├── agents/             # 22 个 agent.md（dispatcher / executor / explorer / ...）
│   ├── commands/           # 6 大类 slash command（/ccw、/issue/*、/workflow/*、/memory/*、...）
│   ├── skills/             # 51+ skill 目录，每个含 SKILL.md + phases/
│   └── workflow-skills/    # 与 .claude/skills 重叠的 workflow 子集（distribution 路径）
├── .ccw/                   # 项目侧只读规范（personal/specs/workflows）
│   ├── personal/           # coding-style.md / tool-preferences.md
│   ├── specs/              # architecture-constraints.md / coding-conventions.md
│   └── workflows/          # 工作流 cli-templates、test-quality-config.json 等
├── .codex/ .gemini/ .qwen/ # 各 CLI 入口下的对应 skill 镜像
├── agents/                 # 顶层公开 agent（role-analysis-reviewer-agent.md）
├── archive/                # 历史快照
├── bin/                    # bin 入口（ESM 桥）
├── docs/ docs-site/        # 用户文档与站点
├── templates/role-templates/
├── README.md / README_CN.md / SPEC.md / WORKFLOW_GUIDE.md
└── package.json            # 7.3.11 / "type":"module" / commander / zod / better-sqlite3 / node-pty
```

### 1.2 主流程

CCW 是一个**JSON-driven 多 agent 框架**，核心抽象是 *Skill 自包含流水线 + 多 CLI（Gemini/Codex/Claude/OpenCode/Qwen）+ 命令链 chain_loader + 后台队列调度*。

主流程（用户视角）：

```
用户输入
  ↓
[Slash command / Skill 触发短语 / ccw 主命令]
  ↓
.claude/commands/ccw.md 主编排器 (Skill 路由)
  ↓ 选择 Skill
workflow-lite-plan / workflow-plan / brainstorm / team-coordinate / spec-generator / ...
  ↓ 在 Skill 内部用 phases/ 文档驱动
LP-Phase 1..5 / Phase 1..N
  ↓ 必要时
Task() 派生 cli-explore-agent / cli-lite-planning-agent / team-worker / ...
  ↓ 多 CLI 协调
ccw cli --tool <claude|codex|gemini|qwen> --mode <analysis|write|review>
  ↓ 产出
.workflow/.lite-plan/<slug>-<date>/  或  .workflow/.team/TC-<slug>-<date>/  或  .workflow/active/WFS-*/
  ↓ Skill 衔接 / 主进程 chain_loader 推进
workflow-lite-execute → workflow-lite-test-review → review-cycle → memory-capture
  ↓
TodoWrite 同步 + ~/.claude/.ccw-sessions/ 持久化 + WebSocket dashboard 实时显示
```

后台维度同时运行：

- `QueueSchedulerService`：以 *DAG 拓扑序 + 会话亲和池 (3 层 resumeKey 复用) + 并发=2* 派发 PTY 会话
- `cli-session-manager`：管理多 CLI session，跨命令复用
- `RecoveryHandler`：PreCompact 钩子里建 checkpoint，session-start 时检测并注入恢复消息
- `StopHandler`（soft enforcement）：永不阻塞 stop，通过注入 continuation message 软推动收敛
- `ModeRegistryService`：基于 `UserPromptSubmit` 关键词激活互斥执行 mode

### 1.3 关键脚本/配置/文档路径

> 后续 harness 借鉴时直接引用这些路径

#### 顶层规范

| 文件 | 内容 |
|------|------|
| `SPEC.md` (76.9 KB) | 系统总规格 |
| `WORKFLOW_GUIDE.md` / `_CN.md` | 工作流选择决策树 / Skills vs Commands 对照 |
| `README.md` / `README_CN.md` | 顶层介绍 + Auto Mode (`-y`) 传播协议 |
| `docs/CCW-CODEX-COMMANDS-SKILLS-GUIDE.md` | Codex 链路使用指引 |
| `docs/skill-team-comparison.md` | skill vs team 设计对照 |
| `ccw/docs/hooks-integration.md` | 钩子集成（PreCompact / Stop / UserPromptSubmit / session-start / file-modified）|

#### 命令与 Skill

| 文件 | 内容 |
|------|------|
| `.claude/commands/ccw.md` | 主编排器（Skill 路由 + Auto Mode `-y` 传播）|
| `.claude/commands/ccw-coordinator.md` | 链编排器（chain_loader 渐进式加载）|
| `.claude/commands/issue/*.md` | issue 全生命周期（new/discover/plan/queue/execute）|
| `.claude/commands/workflow/session/*.md` | session start/resume/list/sync/complete/solidify |
| `.claude/skills/workflow-lite-plan/SKILL.md` | LP-Phase 1-5（660+ 行核心 skill 范本）|
| `.claude/skills/workflow-plan/SKILL.md` + `phases/01-06-*.md` | 完整 Plan 6 阶段（progressive phase loading）|
| `.claude/skills/team-coordinate/SKILL.md` + `roles/coordinator/role.md` + `specs/{pipelines,role-spec-template,quality-gates,knowledge-transfer}.md` | Team v2 全规范 |
| `.claude/skills/ccw-chain/SKILL.md` | chain_loader 协议、变量传递 |
| `.claude/skills/spec-generator/SKILL.md` + `templates/` | 7 阶段规格生成（含 PRD/ADR/Epic 模板）|
| `.claude/skills/review-cycle/SKILL.md` + `phases/review-{session,module,fix}.md` | 三模式审查（git changes / path pattern / fix）|
| `.claude/skills/memory-capture` & `memory-manage` | 记忆 compact/tips 双轨 |

#### 服务端核心

| 文件 | 角色 |
|------|------|
| `ccw/src/core/server.ts` | Express + WebSocket 服务（仪表盘）|
| `ccw/src/core/services/queue-scheduler-service.ts` | 队列状态机 + DAG 调度 + 会话池 |
| `ccw/src/core/services/cli-session-manager.ts` | PTY 会话管理 |
| `ccw/src/core/services/cli-session-mux.ts` | 多 CLI 会话复用器 |
| `ccw/src/core/services/checkpoint-service.ts` | 检查点服务（保存/恢复 mode 状态）|
| `ccw/src/core/services/session-state-service.ts` | 全局 + session-scoped 状态文件 |
| `ccw/src/core/services/flow-executor.ts` | DAG 拓扑序流执行（`{{var}}` 插值 + state.json 持久化）|
| `ccw/src/core/services/mode-registry-service.ts` | 关键词 → mode 激活（互斥）|
| `ccw/src/core/hooks/{recovery-handler,stop-handler,context-limit-detector,user-abort-detector,keyword-detector}.ts` | 钩子检测器 + 软实施 |
| `ccw/src/core/memory-*.ts` (consolidation/extraction/store/embedder/v2-config) | Memory 双管线 + better-sqlite3 + 嵌入向量 |
| `ccw/src/tools/cli-executor*.ts` | CLI 执行核心 |
| `ccw/src/tools/loop-*.ts` | Loop manager / state / task |
| `ccw/src/tools/team-msg.ts` | 团队消息总线 |
| `ccw/src/tools/spec-{loader,init,index-builder,keyword-extractor}.ts` | 规格懒加载 + 关键词索引 |

#### 配置与项目侧规范

| 文件 | 内容 |
|------|------|
| `.ccw/personal/{coding-style,tool-preferences}.md` | 个人偏好（项目本地）|
| `.ccw/specs/{architecture-constraints,coding-conventions}.md` | 架构约束（YAML 头：readMode / priority / category / scope / dimension / keywords）|
| `.ccw/workflows/{cli-tools-usage,coding-philosophy,windows-platform}.md` + `cli-templates/` | 工作流公共片段 |
| `.ccw/workflows/test-quality-config.json` | 测试质量阈值 |
| `package.json` 的 `files[]` | 安装产物白名单（`bin/`、`ccw/dist/`、`.claude/`、`.ccw/`、`.codex/`、`.gemini/`、`.qwen/`、`codex-lens/`）|

---

## 2. 核心机制提炼

### 2.1 Skill = 自包含流水线（Self-Contained Skill）

**定义**：每个 Skill 在 `.claude/skills/<skill-name>/SKILL.md` 内部就完成端到端，不暴露半成品状态。

**结构**：

- `SKILL.md`：YAML frontmatter（`name` / `description` / `allowed-tools`）+ phase 概览 + 路由
- `phases/01-*.md` … `06-*.md`：渐进式按需加载的阶段文档（"progressive phase loading"）
- `roles/`、`specs/`、`templates/`：本 skill 的子规格与模板

**渐进式加载**（`workflow-plan/SKILL.md` 5 节）："Read phase docs ONLY when that phase is about to execute"。配合 TodoWrite 的 `in_progress` 状态保护当前 phase 不被 compact，未触发 phase 不进入上下文。

**Sentinel + TodoWrite 双重保险**（`workflow-plan/SKILL.md` 5 节）：

> 多阶段任务跨长对话时用 TodoWrite 跟踪 active phase，阻止其被压缩；额外在 phase 文档里嵌入 `🔄` sentinel 作为兜底，发现 compact 后只剩 sentinel 时立即重新 `Read("phases/04-task-generation.md")` 恢复。

### 2.2 Skills vs Slash Commands 双轨

**Skills**（触发短语，无斜杠）：`workflow-lite-plan`, `brainstorm`, `team-coordinate`, ...

**Commands**（斜杠）：`/ccw`, `/issue/new`, `/workflow/session:start`, `/memory/prepare`, ...

界限：

- Command 偏向**人类直接调用**的入口（含 `argument-hint`）
- Skill 偏向**编排器/agent 链中调用的步骤**（用 `Skill(skill="...", args="...")` 调用）
- `.claude/commands/ccw.md` 作为唯一主入口，把所有 command 重写成对若干 Skill 的串联调用

### 2.3 Multi-CLI 语义调用（Gemini / Codex / Claude / OpenCode / Qwen）

**核心机制**：用户在自然语言里说 "用 Gemini 分析认证模块"，系统检测意图后通过 `ccw cli --tool gemini --mode analysis` 派发给对应 CLI；可组合 *Collaborative / Parallel / Iterative / Pipeline* 四种模式（见 `README.md`）。

**统一 mode 词表**：`analysis | write | review | auto`（`session-state-service.ts` 中的 `activeMode`）。

**模式互斥**：`ModeRegistryService` 强制同一 session 内每次只激活一个 mode；`UserPromptSubmit` 钩子做关键词检测后写入 mode 状态。

### 2.4 Auto Mode（`-y` / `--yes`）传播协议

`/ccw` 在 Phase 0 检测 `-y`，并在 `assembleCommand` 时注入到链路中每个 Skill 的 args；Skill 内部统一约定：

- LP-Phase 0：`workflowPreferences = { autoYes, forceExplore }`
- LP-Phase 2 / 4：`autoYes` 时跳过 `AskUserQuestion`，自动选默认值
- Phase 5 错误处理 = "Skip"
- 在所有 phase 文档里用 `workflowPreferences.autoYes` 一致引用

### 2.5 Team Architecture v2（动态 role-spec + team-worker）

**核心抽象**：

- **`team-worker` 单一 agent**：内置 Phase 1（Task Discovery 按 prefix 抢占任务）+ Phase 5（Report、Inner Loop 收尾、SendMessage 回 coordinator）。
- **role-spec 文件**：仅包含 YAML frontmatter（`role / prefix / inner_loop / output_tag / message_types`）+ Phase 2-4 的领域逻辑（约 80 行）。
- **coordinator**：把 task description 映射成 capabilities → 生成 role-specs → 写依赖图 → 用 `Agent({subagent_type:"team-worker", run_in_background: true, prompt: <role assignment>})` 派发。
- **task naming**：按 capability 加前缀（`RESEARCH-001`, `IMPL-002`, `TEST-003`, ...）。
- **Inner Loop**：单个 worker 处理同 prefix 任务序列，`context_accumulator` 跨任务保留上下文。

**Session 目录布局**：

```
.workflow/.team/TC-<slug>-<date>/
├── team-session.json        # role registry + dependency_graph + active_workers
├── task-analysis.json       # Phase 1 输出
├── role-specs/<role>.md     # 动态生成的 role-spec
├── artifacts/<task-id>-<name>.md
├── .msg/{messages.jsonl, meta.json}
├── wisdom/{learnings,decisions,issues,conventions}.md
├── explorations/{cache-index.json, explore-<angle>.json}
└── discussions/<round>.md
```

### 2.6 Knowledge Transfer 5 通道

`team-coordinate/specs/knowledge-transfer.md` 定义的跨 worker 信息通道：

| 通道 | Scope | 机制 |
|------|-------|------|
| Artifacts | Producer→Consumer | `<session>/artifacts/<task-id>-<name>.md` |
| State Updates | Cross-role | `team_msg(operation="log", type="state_update")` 写、`get_state` 读 |
| Wisdom | Cross-task | `wisdom/{learnings,decisions,conventions,issues}.md` append-only |
| Context Accumulator | Intra-role inner loop | 内存数组在同 prefix 任务间继承 |
| Exploration Cache | Cross-role | `explorations/cache-index.json` 防重复探索 |

每个 role 的 Phase 2 强制 `team_msg(get_state)` → 读 artifact ref → 读 wisdom；Phase 4 强制写 artifact + `state_update`（schema 含 `ref / key_findings ≤5 / decisions+rationale / files_modified / verification`）+ 追加 wisdom 条目。

### 2.7 Quality Gates（评分模型）

`team-coordinate/specs/quality-gates.md`：

| 维度 | 权重 |
|------|------|
| Completeness | 25% |
| Consistency | 25% |
| Accuracy | 25% |
| Depth | 25% |

阈值：≥80% Pass / 60-79% Review（带告警）/ <60% Fail（重试 Phase 3 最多 2 次）。

按 `output_type ∈ {artifact, codebase, mixed}` 派生不同检查清单（artifact 检查文件存在/格式/交叉引用；codebase 检查 Read 确认修改/语法/无回归/产 summary）。

Code Review 维度细分到 *Quality / Security / Architecture / Requirements*，每条检查附 Error/Warning/Info 严重级。

### 2.8 Session 生命周期 + Checkpoint/Recovery

**Session ID 规则**：

- `WFS-` workflow / `WFS-review-` review / `WFS-tdd-` tdd / `WFS-test-` test
- `TC-<slug>-<date>` team-coordinate
- `SPEC-<slug>-<date>` spec-generator
- 强校验 `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,255}$` 防路径穿越

**两级存储**：

- `~/.claude/.ccw-sessions/session-<id>.json`（global，跨 session 持久化）
- `<repo>/.workflow/sessions/<id>/state.json`（session-scoped）

**钩子矩阵**（`ccw/docs/hooks-integration.md`）：

| Hook | 时机 | 用途 |
|------|------|------|
| `session-start` | session 启动 | 渐进上下文注入 + Recovery 检测 |
| `PreCompact` | 上下文压缩前 | 创建 checkpoint（mode/workflow/TODO 摘要）|
| `Stop` | stop 请求 | Soft Enforcement，注入 continuation 消息 |
| `UserPromptSubmit` | 提交 prompt | 关键词检测激活 mode |
| `session-end` | 结束 | 更新 cluster metadata + final checkpoint |
| `file-modified` | 文件修改 | auto-commit / 通知 |

**Soft Enforcement Stop**（`stop-handler.ts`）：永不阻塞 stop，按优先级 *context-limit > user-abort > active-workflow > active-mode* 决定是否注入 continuation 消息。

**PreCompact mutex**：`recovery-handler.ts` 用 `inflightCompactions: Map<dir, Promise<HookOutput>>` 保证同一目录的并发 compact 串行化（防止 swarm/ultrawork 多 subagent 同时落 checkpoint）。

### 2.9 Queue Scheduler（后台调度）

`queue-scheduler-service.ts`：

- 状态机 `idle → running ⇄ paused → stopping → completed|failed → idle`，转移合法性硬校验
- 默认 `maxConcurrentSessions=2`、`sessionIdleTimeoutMs=5min`、`resumeKeySessionBindingTimeoutMs=30min`
- 会话池 3 级分配：`resumeKey 亲和 → 空闲复用 → 新建`
- 内存态（无持久化）+ `processingLock` 防 re-entrant
- 通过 `broadcastFn` 把状态变更推到 WebSocket，仪表盘实时刷新

### 2.10 Flow Executor（可视化编排）

`flow-executor.ts`：

- DAG 拓扑序 + per-node `NodeRunner`
- `{{variable}}` / `{{result.output}}` 插值
- `status.json` 持久化、`onNodeStarted/Completed/Failed/StateUpdate` 钩子
- 与 `cli-executor`、`cliSessionMux`、`appendCliSessionAudit`、`assembleInstruction` 集成

### 2.11 Memory 双管线（capture + manage）

`memory-capture` 路由两种模式：

- **Compact**：把整个 session 压缩成结构化文本（用于 session 恢复）
- **Tips**：快速 note（含 `--tag` / `--context`）

收敛到统一存储：`mcp__ccw-tools__core_memory(import)` → 服务端 `core-memory-store.ts` + `unified-memory-service.ts` + `unified-vector-index.ts` + better-sqlite3 + `memory-extraction-pipeline.ts` + `memory-consolidation-pipeline.ts`（双管线 + 嵌入向量）。

### 2.12 Spec 关键词索引 + 懒加载

`.ccw/specs/*.md` 顶部 YAML：

```yaml
---
title: Architecture Constraints
readMode: optional
priority: medium
category: general
scope: project
dimension: specs
keywords: [architecture, constraint, schema, ...]
---
```

`spec-loader.ts` + `spec-keyword-extractor.ts` + `spec-index-builder.ts` 提供 `ccw spec load --category planning`，按关键词命中再加载具体 spec，避免一次塞入全部规范。

### 2.13 Chain Loader（渐进式命令链）

`ccw-chain/SKILL.md` + `chain-loader.ts`：

- `chain_loader list/inspect/start/done/visualize/status`
- 步骤节点逐个加载 skill/command 文档
- 变量在 chain 内自动传播；`pass_variables`/`receive_variables` 跨 chain 委派
- `delegate_depth > 0` 时进入子链，`returned_from_delegate: true` 回到父链

### 2.14 Workflow Tune（沙箱测试 command/skill）

`/workflow-tune`：在 `sandbox/` 独立 git 仓库里用 `ccw cli --tool claude --mode write` 逐步执行，再用 `ccw cli --tool gemini --mode analysis` 分析产物质量、给优化建议。P0 规则含：

> ONE STEP = ONE CLI CALL；STOP After Each CLI Call；UPSTREAM-SCOPE RULE（下游必须消费上游全量 plan）；ABSOLUTE PATHS for `--cd`；FIXED `--rule` VALUES。

---

## 3. 与 claude-dev-harness 的关系（机制级对照）

| 维度 | CCW 7.3.11 | claude-dev-harness 现状 | 差距描述 |
|------|------------|------------------------|----------|
| 工作流模型 | Skill 自包含流水线 + chain_loader 主进程链 + 后台 QueueScheduler | `agent-configs/workflows/harness-lite.yaml` 单线 5-stage（PLAN→PLAN_REVIEW→IMPLEMENT→CODE_REVIEW→TEST→DONE）+ `scripts/advance-stage.ps1` 单点推进 | harness-lite 是状态机线性推进，无 DAG / 无队列 / 无主进程 chain；CCW 把"决策点"封装成 phase 文档逐次加载 |
| Skill 粒度 | 51+ skill，每个含 phases/，部分含 roles/specs/templates/ | 11 个 skill，`obsidian-memory`、`orchestrator`、`plan/review/implement/test`、`workflow-team`、`gemini-designer-main`、`spec`、`using-superpowers`、`codex` | harness skill 接近 CCW 的 phase 粒度而非 SKILL 粒度；缺 chain_loader、缺 team-worker 这种"角色无关执行体" |
| Plan artifact | `IMPL_PLAN.md` + `.task/TASK-*.json` 两层（plan.json overview + 独立 task 文件）| `docs/tasks/<task-id>/plan.md` 单文件，附录 Plan Review/Implementation Notes/Code Review 段 | harness 单文件简单可控但不便并行；CCW 两层利于 task 并发 + 单点 modify |
| Multi-agent | team-coordinate v2（动态 role-spec + team-worker + DAG）| `workflow-team` skill 5 静态角色（plan-author/plan-reviewer/implementer/code-reviewer/tester），`AIONUI_TEAM_MODE='1'` opt-in | harness team 是固定五段 stage 同名映射；CCW 是 capability 驱动的动态拓扑 |
| Multi-CLI | `ccw cli --tool <claude/codex/gemini/qwen/opencode> --mode <analysis/write/review>` 主进程单点 | frontmatter `tool: claudecode/codex/gemini/none` + `tool_profile/model` opt-in；通过 `scripts/invoke-harness-skill.ps1` 派发 | harness 已有 backend 概念但更窄（per-stage 一个），无 mode 维度（analysis/write/review）也无 parallel/iterative pattern |
| 共享记忆 | `.ccw/specs/*.md` + `core_memory` MCP + `unified-memory-service` (sqlite + 向量) | `.assistant/` 4 层（工作流/运行时/配置/记忆候选）+ shared-memory-v2 contract（`derived_from / entry_host / schema_version`）+ `runtime-inbox/v1.0` 占位 | harness 是 *vault as truth source* 的 4 层 Markdown 协议；CCW 倾向于 sqlite + 向量 + 路由器 |
| Hook | `session-start / PreCompact / Stop / UserPromptSubmit / session-end / file-modified` 6 类，TS HookTemplate | `runtime-hooks/claude/posttooluse.js` 单点 | harness hook 面单一，无 PreCompact checkpoint、无 Stop soft enforcement、无 mode keyword 激活 |
| 队列 | `QueueSchedulerService` 内存 DAG + 状态机 + 会话亲和池 + WebSocket 广播 | 无 | harness 无并发调度概念，所有任务由人类/leader 串行 |
| 仪表盘 | Express + WebSocket 服务（`ccw/src/core/server.ts`），前端 workspace | 无 | harness 是纯命令行 |
| Auto Mode 协议 | `-y` 检测 + `assembleCommand` 注入到链路所有 Skill | 无统一约定 | |
| Memory 维护 | `memory-capture / memory-manage` skill + 双管线 (extraction + consolidation) + 嵌入向量 | `scripts/memory-{health,maintain,health-report}.ps1` + `archive-memory-candidates.ps1` + `triage-runtime-inbox.ps1` | harness 是 PowerShell + Markdown 流，无嵌入向量、无路由器；但有更严格的 vault layer 校验（`check-shared-memory-layers.ps1`）|
| Quality Gate | 评分（Completeness/Consistency/Accuracy/Depth 各 25%）+ 阈值（80/60）+ 重试 ≤2 | 无显式量化 | harness 用 `validate-lite-artifacts.ps1` 二值 PASS/FAIL，无 0-100 评分 |
| Spec/规范注入 | YAML 头（readMode/priority/category/scope/dimension/keywords）+ `ccw spec load --category planning` 关键词命中 | 无；规范在 `.assistant/工作流/*.md`、`AGENTS.md`、`README.md` | harness 缺关键词索引/懒加载 |

---

## 4. 可借鉴清单（按可用度分类）

### 4.1 可直接复用（low-friction，结构兼容 harness 现有 4 层）

#### A1. **TodoWrite + sentinel 双重保险防 compact 丢上下文**

来源：`.claude/skills/workflow-plan/SKILL.md` 第 5 节。

借鉴方式：harness 的 plan/review/implement/test/spec/orchestrator skill 在多步骤产出时，强制写 TodoWrite，并用 `🔄` sentinel + 强制 Read phase 文档兜底；现在 plan.md 的 `## Plan Review`、`## Implementation Notes`、`## Code Review` append-only 段已提供物理 sentinel 雏形，但缺"compact 后只剩 sentinel 时立即重读"的协议。

#### A2. **Auto Mode `-y` 传播协议**

来源：`.claude/commands/ccw.md` Phase 0 + `ccw-chain/SKILL.md`。

借鉴方式：harness 当前由 leader 决定是否提问；可在 orchestrator skill 加 `-y` 入口，统一"User Confirmation 段直接判定为 confirmed、Clarification 跳过 AskUserQuestion、PLAN_REVIEW/CODE_REVIEW 默认 Approve、TEST conclusion 默认 PASS-with-warnings"。代价低，**改 orchestrator skill + 各 skill SKILL.md 即可**，无需新增基础设施。

#### A3. **Skill `phases/` 渐进式按需加载**

来源：`.claude/skills/workflow-plan/phases/*.md`。

借鉴方式：harness skill（如 `plan/SKILL.md`、`review/SKILL.md`）已有"按 stage 写不同段"的概念，但所有规则集中在 SKILL.md 一处。建议把 *Clarification 验收标准最小集合*、*Change Contract 字段表*、*Verification 命令 chain* 拆到 `phases/01-clarification.md` 等文件，主 SKILL.md 仅保留路由 + frontmatter 约束。这能直接降低单 skill 文件长度，减少全量加载成本。

#### A4. **Knowledge Transfer 5 通道里的 wisdom 文件**

来源：`team-coordinate/specs/knowledge-transfer.md`。

借鉴方式：harness 的 `.assistant/记忆候选/` 已是"长期记忆候选池"，可对应 CCW 的 `wisdom/`；但缺 *learnings.md / decisions.md / conventions.md / issues.md* 这种**按性质分文件 + append-only**的细分。这是个非破坏性扩展，**新增 4 个空 md 文件 + 写回协议补一段路由规则**。

#### A5. **Quality Gates 评分维度与阈值**

来源：`team-coordinate/specs/quality-gates.md`。

借鉴方式：harness 当前 PLAN_REVIEW/CODE_REVIEW 是文字段落，可在 review skill 强制按 *Completeness/Consistency/Accuracy/Depth* 4 维 0-100 评分（写在 `## Plan Review` 段的 `score:` 字段或 frontmatter），≥80 标 `pass` / 60-79 `pass-with-warnings` / <60 `fail`，让 advance-stage 可在 frontmatter 读到结构化评分而非靠人类裁定。**checker 改造较小**：`scripts/validate-lite-artifacts.ps1` 增 6 行检查 `score:` 字段。

#### A6. **Spec YAML 头 + 关键词命中**

来源：`.ccw/specs/architecture-constraints.md` 顶部 YAML（`readMode/priority/category/scope/dimension/keywords`）+ `spec-loader.ts`。

借鉴方式：harness 的 `.assistant/工作流/*.md` 6 个协议文件可加同款 YAML 头，由 obsidian-memory skill 在恢复时按 task 类型只加载 keywords 命中的协议（例：纯文档任务无需读 `任务识别协议.md`）。

### 4.2 需改造后复用（中等改动；需要重新设计才能落进 harness）

#### B1. **Plan 两层 artifact（plan.json + .task/TASK-*.json）**

来源：`workflow-lite-plan/SKILL.md` LP-Phase 3。

借鉴方式：harness 当前 `plan.md` 单文件，难以把"任务分解 + 并行/依赖"形式化。可改造为：保留 `plan.md` 作为人类可读总览，新增 `docs/tasks/<task-id>/.task/TASK-*.md`（或 .json）作为细分任务清单，每个 TASK 含 `target_files / acceptance_criteria / depends_on / executor`。**改造点**：plan skill 输出 + validator 同时校验两层；advance-stage 只看 plan.md frontmatter 不变。**风险**：现有 single-file 心智模型变两层，要兼容 read-only legacy plan。

#### B2. **Team v2 动态 role-spec + team-worker 单 agent**

来源：`team-coordinate/SKILL.md` + `team-worker.md` agent。

借鉴方式：harness 当前 `workflow-team` 是 5 个固定 stage 角色（plan-author/plan-reviewer/implementer/code-reviewer/tester），无法对"5 篇文档同时校对"或"3 个并行 explore 角度"这种动态拓扑。可改造为：新增 `team-worker` agent + `task-analysis.json` 派生 role-spec → 把 `workflow-team` 升级为"动态 N 角色 + DAG 依赖图"。**改造点大**：要新建 message bus 抽象（CCW 用 `team_msg` MCP；harness 已有 `team_send_message` 可对应）、Inner Loop / context_accumulator、role-spec 模板。**风险**：当前 5-stage 固定结构是 harness 的核心契约（advance-stage 强约束），动态拓扑会冲击 stage 顺序假设。

#### B3. **PreCompact checkpoint hook + Recovery 协议**

来源：`recovery-handler.ts` + `checkpoint-service.ts` + hooks-integration.md。

借鉴方式：harness 当前 `恢复协议.md` 完全靠 `恢复索引.md` + `当前任务.md` 静态 markdown，没有 *PreCompact 钩子主动建快照* 这步。可在 `runtime-hooks/claude/` 加 `precompact.js`：调用 `repair-shared-memory.ps1` 同步当前 frontmatter + 写一份 timestamped checkpoint 到 `.assistant/运行时/checkpoints/`。**改造点**：新增 hook，要保证 mutex（CCW 的 `inflightCompactions` 模式）；不破坏单写者模型。**风险**：Claude Code 的 hook ABI 变更可能让钩子失效。

#### B4. **Soft Enforcement Stop + Active Workflow Continuation**

来源：`stop-handler.ts`、`hooks-integration.md` Stop Hook 章节。

借鉴方式：harness 当前没有 Stop hook；可加 `runtime-hooks/claude/stop.js`，按 *active stage ≠ DONE* 时注入"还有 stage 未完成，是否继续？"提示。**改造点**：新增 hook + 一行检查 plan.md frontmatter；不影响主路径。**风险**：太频繁的注入会扰乱用户控制，需要 Soft 不能 Hard。

#### B5. **chain_loader 主进程链 + 变量传播**

来源：`ccw-chain/SKILL.md` + `chain-loader.ts`。

借鉴方式：harness 链路靠 leader 手动调 `advance-stage.ps1` + 切换 skill；可加一个 `harness-chain` skill 接受 "新功能 → plan → review → implement → review → test" 全链路一次启动，内部用 `Skill()` 串调，把 task_id / current stage / tool 作为 chain variable。**改造点**：新增 skill + 编写状态机；advance-stage 不变。**风险**：变成"软自动化 leader"，与 harness "leader 显式裁定每个 stage" 的设计哲学有张力。

#### B6. **Memory 双管线（extraction + consolidation）**

来源：`ccw/src/core/memory-extraction-pipeline.ts` + `memory-consolidation-pipeline.ts`。

借鉴方式：harness 的 `triage-runtime-inbox.ps1` + `archive-memory-candidates.ps1` 类似 "extraction → archive"，但没有 *consolidation*（多条 candidate 合并去重 + 提炼共性）。可加 `consolidate-memory.ps1`，按 tag/keywords 合并旧候选条目。**改造点**：新增脚本 + 验证脚本；schema 增 `consolidated_from: []`。**风险**：合并语义需要人工审；纯脚本机械合并会造成意义损失。

### 4.3 不适合引入（与 harness 设计哲学冲突或显著超出当前需求）

#### C1. **WebSocket dashboard / Express server / 前端 workspace**

来源：`ccw/src/core/server.ts` + `ccw/frontend/`。

理由：harness 是纯 CLI + Markdown vault 设计，**不依赖 daemon**。引入服务端意味着新增进程生命周期、端口、CORS、WebSocket 协议、前端 build、`better-sqlite3`/`node-pty` 二进制依赖（CCW 的 postinstall 显式 `npm rebuild`）；与"安装一份脚本即可"的最小依赖目标冲突。

#### C2. **better-sqlite3 + 向量索引内嵌记忆**

来源：`unified-vector-index.ts` + `memory-embedder-bridge.ts` + `memory-v2-config.ts`。

理由：harness 共享记忆是 Markdown + frontmatter，由 vault checker（`check-shared-memory-layers.ps1`）保证机械可校验。换成 sqlite + 向量后，记忆变成"黑箱二进制 + 模型语义"，与 *vault-as-truth-source*、*单写者模型*、*git diff 可审*三大底线冲突。

#### C3. **QueueSchedulerService 内存调度器**

来源：`queue-scheduler-service.ts`。

理由：harness 当前不存在并发任务概念，advance-stage 是"人 + leader 逐 stage 显式推进"。引入并发会同时引入：DAG 依赖、会话亲和池、resumeKey、PTY 池、状态机持久化（CCW 自承"in-memory state, no persistence; crash recovery deferred"）。投资大、收益小、且与 harness "每条命令可单独审计" 的契约冲突。

#### C4. **节点级 a2ui / pending-question-service / 交互式 UI**

来源：`a2ui-protocol-guide.md` + `pending-question-service.ts`。

理由：harness 的"问题"靠 leader 直接回话/手敲；引入交互协议要建 UI + 通信通道。投入产出比低。

#### C5. **PTY-based cli-session-manager + cli-session-mux**

来源：`cli-session-manager.ts` + `cli-session-mux.ts`。

理由：harness 的多 backend 已通过 frontmatter `tool` + `tool_profile` 解决；不需要常驻 PTY 池来"复用 session 节省启动时间"。harness 每次 advance-stage 是 stage 边界，启动开销不是瓶颈。

#### C6. **MCP `core_memory` 内置工具**

来源：`mcp__ccw-tools__core_memory(*)` + `bin/ccw-mcp.js`。

理由：harness 已有 `mcp__aionui-team-*` 这套作 team 通信；记忆走 vault Markdown。再加一个 MCP 服务等于多一套真相源。

#### C7. **role-analysis-reviewer-agent / cli-execution-agent 等 22 个 agent.md**

来源：`.claude/agents/`。

理由：CCW 的 agent 数量是因为它要在 22 种 task type 上分别派发；harness lite 5 stage 已经把"角色"折叠进 stage，再细分会引入"agent 选择"的判断成本，与 harness "leader 是唯一决策者" 的契约冲突。

---

## 5. 重点路径速查（harness 后续如借鉴可直接 Read）

```
# Skill 范本
D:\data\Claude-Code-Workflow-main\.claude\skills\workflow-lite-plan\SKILL.md           # 660+ 行 Skill 范本（exploration/clarification/planning/handoff）
D:\data\Claude-Code-Workflow-main\.claude\skills\workflow-plan\SKILL.md                # progressive phase loading + sentinel
D:\data\Claude-Code-Workflow-main\.claude\skills\workflow-plan\phases\04-task-generation.md
D:\data\Claude-Code-Workflow-main\.claude\skills\team-coordinate\SKILL.md              # Team v2 编排器
D:\data\Claude-Code-Workflow-main\.claude\skills\team-coordinate\roles\coordinator\role.md
D:\data\Claude-Code-Workflow-main\.claude\skills\team-coordinate\specs\pipelines.md
D:\data\Claude-Code-Workflow-main\.claude\skills\team-coordinate\specs\role-spec-template.md
D:\data\Claude-Code-Workflow-main\.claude\skills\team-coordinate\specs\quality-gates.md
D:\data\Claude-Code-Workflow-main\.claude\skills\team-coordinate\specs\knowledge-transfer.md
D:\data\Claude-Code-Workflow-main\.claude\skills\spec-generator\SKILL.md               # 7 阶段 spec 生成
D:\data\Claude-Code-Workflow-main\.claude\skills\review-cycle\SKILL.md                 # 3 模式 review
D:\data\Claude-Code-Workflow-main\.claude\skills\memory-capture\SKILL.md
D:\data\Claude-Code-Workflow-main\.claude\skills\ccw-chain\SKILL.md                    # chain_loader 协议

# 命令入口
D:\data\Claude-Code-Workflow-main\.claude\commands\ccw.md                              # 主编排器 + Auto Mode 传播
D:\data\Claude-Code-Workflow-main\.claude\commands\ccw-coordinator.md
D:\data\Claude-Code-Workflow-main\.claude\commands\workflow-tune.md                    # 沙箱测试 command/skill

# Agent
D:\data\Claude-Code-Workflow-main\.claude\agents\team-worker.md                        # 单 agent 内置 Phase 1+5
D:\data\Claude-Code-Workflow-main\.claude\agents\cli-explore-agent.md
D:\data\Claude-Code-Workflow-main\.claude\agents\cli-lite-planning-agent.md

# 服务端核心（TS）
D:\data\Claude-Code-Workflow-main\ccw\src\core\hooks\index.ts
D:\data\Claude-Code-Workflow-main\ccw\src\core\hooks\recovery-handler.ts               # PreCompact mutex
D:\data\Claude-Code-Workflow-main\ccw\src\core\hooks\stop-handler.ts                   # Soft Enforcement
D:\data\Claude-Code-Workflow-main\ccw\src\core\hooks\keyword-detector.ts
D:\data\Claude-Code-Workflow-main\ccw\src\core\services\queue-scheduler-service.ts
D:\data\Claude-Code-Workflow-main\ccw\src\core\services\session-state-service.ts
D:\data\Claude-Code-Workflow-main\ccw\src\core\services\checkpoint-service.ts
D:\data\Claude-Code-Workflow-main\ccw\src\core\services\flow-executor.ts
D:\data\Claude-Code-Workflow-main\ccw\src\core\services\mode-registry-service.ts
D:\data\Claude-Code-Workflow-main\ccw\src\tools\spec-loader.ts                         # 关键词命中 spec
D:\data\Claude-Code-Workflow-main\ccw\src\tools\team-msg.ts

# 项目侧规范
D:\data\Claude-Code-Workflow-main\.ccw\specs\architecture-constraints.md
D:\data\Claude-Code-Workflow-main\.ccw\specs\coding-conventions.md
D:\data\Claude-Code-Workflow-main\.ccw\workflows\test-quality-config.json

# 顶层文档
D:\data\Claude-Code-Workflow-main\WORKFLOW_GUIDE.md
D:\data\Claude-Code-Workflow-main\SPEC.md
D:\data\Claude-Code-Workflow-main\ccw\docs\hooks-integration.md
D:\data\Claude-Code-Workflow-main\ccw\docs\team.md
D:\data\Claude-Code-Workflow-main\docs\skill-team-comparison.md
D:\data\Claude-Code-Workflow-main\package.json                                         # files[] 安装产物白名单
```

---

## 6. 结论与下一步建议

CCW 与 harness 的根本差异不在"功能多少"，而在**真相源形态**：

- **CCW**：sqlite + 向量 + WebSocket + 内存队列；"server-as-truth-source"。优势是动态拓扑、并发、可视化；代价是必须运行 daemon、二进制依赖、跨机器同步难。
- **harness-lite**：Markdown vault + git + 单写者；"vault-as-truth-source"。优势是任意时刻可 git diff 审计、零依赖、跨工具一致；代价是天然单线、动态拓扑要靠人，不能并发。

> 不应直接吸收 CCW 的 server / 向量 / 队列那一脉。harness 的核心价值正是 *把它们都拒绝掉*。

**最具借鉴价值的 6 个低成本扩展**（按 ROI 排序）：

1. **A2 Auto Mode `-y` 传播协议**：纯 skill SKILL.md 改文档，无新增脚本，能直接降低 leader 重复确认负担。
2. **A1 TodoWrite + sentinel 防 compact 丢上下文**：skill 文档 + 主 agent 行为契约，无新增脚本。
3. **A6 Spec YAML 头 + 关键词命中**：在 `.assistant/工作流/*.md` 加 YAML 头 + obsidian-memory 加路由，零破坏增量。
4. **A4 wisdom/ 4 文件分类**：在 `.assistant/记忆候选/` 增加 `learnings.md / decisions.md / conventions.md / issues.md` append-only 占位，写回协议补一节。
5. **A5 Quality Gates 4 维评分**：review skill 改输出 schema + validator 加 6 行检查，让 PLAN_REVIEW/CODE_REVIEW 结果机器可读。
6. **A3 Skill phases/ 渐进加载**：把现有 skill 中超过 200 行的 SKILL.md 拆 phases/，主文档只留路由 + frontmatter 约束。

**中风险但战略价值的两个**（需要单独立项评估）：

- **B3 PreCompact checkpoint hook**：解决长会话上下文丢失痛点，但要新增 runtime-hooks 文件 + mutex 协议，需要单独 plan/review。
- **B5 chain_loader 主进程链**：把"leader 手动 advance-stage" 升级为"一条命令跑完整链"，但与 harness 显式裁定哲学张力大，建议先做 opt-in flag 形式，不替换默认路径。

**显式拒绝**（写在非目标里）：

- C1/C3 daemon + dashboard + 队列；C2 sqlite/向量记忆；C5 PTY 池；C6 MCP core_memory；C7 22 agent 细分。

后续若 leader 决定推进 A1-A6，建议**单独发起 6 条 lite 任务**而非合并一个超大 plan，每条都符合现有 plan.md schema 的 affected_paths/Verification/Risks 规范。
