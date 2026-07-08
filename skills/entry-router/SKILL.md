---
name: entry-router
description: Canonical entry router for choosing quick, workflow, ask, resume, switch, or inbox-first paths and loading only the necessary shared memory and local skills.
---

<EXTREMELY-IMPORTANT>
Entry-router is the default first hop for development tasks. Do not invoke other workflow skills before routing. After routing, load only the minimum skill/context set required by the selected mode.
</EXTREMELY-IMPORTANT>

## How to Access Skills

**In Claude Code:** use the `Skill` tool; invoking a skill loads its content — follow it directly, never `Read` skill files. **In other environments:** check your platform's docs.

# Using Skills

For development tasks, route through this skill first. Load non-workflow/domain skills only after routing, and only when directly relevant or explicitly requested. Route-specific lazy loading wins over broad skill discovery.

**输出语言：** 中文（非代码文本）；代码、命令、标识符保留英文。

## 共享记忆（内联自 obsidian-memory）

共享真相源只在 `.assistant`；详细规则参考 `obsidian-memory` skill（已降级为参考文档）。

### 恢复触发

用户说“继续 / 恢复 / resume / 刚才做到哪里了”时，直接在本 skill 内恢复：

1. 读 `运行时\恢复索引.md`
2. 细节不足时读 `运行时\当前任务.md` → `运行时\tasks\<task-id>.md`
3. 再读 `运行时\中断任务.md` → `运行时\上次会话.md`
4. 回复三段式：当前主任务 / 其他中断任务 / 恢复选项

### 写回规则

- 多步骤任务开始 / 切换：更新 `运行时\当前任务.md` + `运行时\tasks\<task-id>.md`
- 任务暂停或待续：同步 `运行时\中断任务.md`
- 阶段完成：更新 `运行时\上次会话.md` 并刷新 `运行时\恢复索引.md`
- 未确认稳定偏好先写 `运行时\记忆候选.md`；新事项先写 `运行时\收件箱.md`

### Guardrails

- 不在 `.claude` / `.codex` 下创建平行 runtime note
- 不在 `MEMORY.md` / `配置\*.md` / `配置\引导状态.md` 记录当前任务
- 长期记忆提升前必须得到用户确认

## 开发任务优先路由

检测到开发意图（开发 / 修 bug / 重构 / 代码 review / 测试验证 / 写 spec / 写 plan / 实现功能 / 需求分析 / 方案设计）时，先判断请求类型；不要把“分析后的闲聊”当成开发入口：

- **resume-current**：读 `运行时\当前任务.md` → 找 `docs/tasks/<task-id>/plan.md` frontmatter stage → 由 orchestrator 恢复
- **switch-existing**：读 `运行时\中断任务.md` → 选定 task → 由 orchestrator 恢复
- **inbox-first**：信息不足且无法判断归属时，先按共享记忆规则写入收件箱
- **new-task**：先做 `mode` 路由

非开发任务不进入 harness-lite，由宿主能力或外部 skill 处理。

### new-task mode routing

`new-task` 后选 `mode: quick | workflow | ask`，默认自主判断，低置信度才 `ask`：

- **quick**：quick only when all true：范围和验收清楚、风险低、当前对话内可完成并验证、用户没有要求留痕 / review / test / 计划。默认不建 `docs/tasks/<task-id>/`，不改共享指针。
- **workflow**：workflow when any of these is true：用户要求 workflow / 留痕 / review / test / 计划，或变更触碰入口协议、脚本、模板、validator、多文件 / 跨模块、高风险路径，或需要可审计决策 / 产物时，导向 `/orchestrator` 建 `plan.md`。
- **ask**：Deep Clarification Mode. 缺少答案导致无法判断 quick/workflow、验收、范围、风险或输出边界时使用；提出 minimum sufficient clarification set，可多轮，但每轮只问足以解除当前阻塞的必要问题，并优先给推荐答案。

显式覆盖词：偏 quick（`直接改`、`快修`、`小改一下`、`不用 workflow`、`别走流程`），但必须满足 quick 全部条件；偏 workflow（`走 workflow`、`留痕`、`需要 review`、`需要 test`、`跑完整流程`、`写计划`）。无显式词时按 all/any 规则判断；quick 执行中影响面扩大或用户开始要留痕，停止扩大并切 workflow 或先确认。

### 懒加载

- `quick`：只加载入口规则、用户偏好 / 必要配置和直接相关 skill；不加载 orchestrator 或全部 stage skill。
- `workflow`：加载本 skill + `orchestrator`，再按当前 stage 只加载一个阶段 skill（`PLAN→plan`、`PLAN_REVIEW/CODE_REVIEW→review`、`IMPLEMENT→implement`、`TEST→test`）。
- `resume-current` / `switch-existing`：先读恢复运行时（恢复索引 / 当前任务 / tasks），再按 `plan.md` frontmatter stage 加载当前 stage skill。
- `ask`：不加载 workflow stage skill；用 Deep Clarification Mode 澄清到足以判断路由和验收边界，不创建 `docs/tasks/<task-id>/`、不改代码、不推进阶段。

禁止 bulk-load 全部 skills / 全部历史任务 / Claude 兼容 skill / `workflow-team`；仅在显式 backend override、frontmatter 命中或 `$env:AITEAMCODE_TEAM_MODE='1'` 时才加载这些路径。

### ask response format

Deep Clarification Mode 只输出足以解除阻塞的澄清内容，推荐格式：

- `我会先按 ask 处理`：一句话说明阻塞点，例如路由、验收、范围、风险或输出边界不清楚。
- `已能确定`：列出可由当前请求、代码或文档直接确定的事实。
- `还需要确认`：提出 minimum sufficient clarification set，覆盖必要的意图、成功标准、范围 / 非范围、影响面、优先级、风险容忍、约束、输出格式、示例 / 反例、quick/workflow 归属、是否需要设计 / 实现 / review / testing、是否需要 durable artifacts。
- `推荐答案`：给出默认建议，说明采用后会走 `quick` 还是 `workflow`。

若用户回答后仍不足以安全路由或执行，可以继续 ask；一旦足够明确，转入 `quick` 或 `workflow`，但 `ask` 本身不是 frontmatter stage。

### 同族分支路由（按需，写法见对应单一真相源）

- **Clarification 协议族**（需求澄清 / 拷问 / 头脑风暴 / 方案压力测试 / 边界确认 / `clarify` / `brainstorm` / `pressure test` 等，或 PLAN 的验收、非目标、影响面、回滚/兼容仍不确定，或实现路径仍不足以指导 IMPLEMENT）：仍走 `new-task mode=workflow`，在 `PLAN -> ## Clarification` 的 `clarification_ledger` 沉淀问题 / 证据 / 推荐答案 / 决策 / 影响，并保留 Clarification 最低字段；确认前 `## User Confirmation` 保持 `draft`；信息不足以判归属时走 `ask`；可查问题先自查，剩余用户决策按依赖顺序一次只问一个并给推荐答案。详细写法见 `plan` skill 与 lite-writing-guide。
- **阶段原则路由**：不新增五转流程；按阶段借用认知视角。Entry/Clarification 用 Socrates 分流：外部论点先查来源与代码 / 文档 / artifact 证据，用户需求进入 Clarification 问题树，内部推理回到根约束并找反例，待验证结论进入 Verification / TEST 证据收集；PLAN 用 Osborn 发散、Hegel 收敛、First Principles + Occam 选最小方案；PLAN_REVIEW 用 Hegel + Bayes；IMPLEMENT 用 Ponytail / surgical change；CODE_REVIEW 用 Feynman；TEST 用 Bayes；`revise` 后用 Debono 保留仍成立的价值和约束。
- **Markdown / HTML artifact**：需要互转 / HTML 报告 / 网页 artifact / 发布预览 / 从 URL 提取 Markdown 时按需加载 `md-html` skill；Markdown 是 source of truth、HTML 是 generated artifact，边界见该 skill。
- **开发流程细节**：5 阶段 harness-lite、`plan.md` frontmatter 真相源、`advance-stage.ps1` 推进语义、`spec.md` 可选附件等，见 `orchestrator` skill 与 README，本入口不重复。
- **推理与对抗审查纪律**：解决问题 / 修 bug / 设计架构或方案时从第一性原理出发，遵循剃刀法则与贝叶斯更新；做完相对复杂的任务后默认做对抗性审查（否定式 + 追问式 + 墨菲定律），复杂任务可升级到多 agent。quick 任务同样适用推理纪律；workflow 任务的详细写法见 `plan` / `review` skill 与 lite-writing-guide。

## 调用层级

1. 开发主流程：orchestrator → plan / implement / review / test
2. 可选补充：`spec`（仅输入不足时生成 delta-spec）
3. 可选委派：`codex`（用户显式要求或当前 stage `tool: codex` 时）

## Red Flags

These thoughts mean STOP — you're rationalizing:

| Thought | Reality |
|---------|---------|
| "This is just a simple question" | For development work, route first, then choose quick/workflow/ask. |
| "I need more context first" | Entry routing decides whether context gathering is quick, workflow, or ask. |
| "Let me explore the codebase first" | Route first, then load only the context needed for that route. |
| "I can check version control/files quickly" | Files lack conversation context; entry routing keeps task state clear. |
| "Let me gather information first" | Gathering is part of the selected route, not a pre-route detour. |
| "This doesn't need a formal skill" | Low-risk work can still be quick after routing. |
| "I remember this skill" | Skills evolve. Read current version. |
| "This doesn't count as a task" | Actionable development work still needs mode routing. |
| "The skill is overkill" | Use `quick` when all quick gates are true. |
| "I'll just do this one thing first" | Do route selection before changing files or loading stage skills. |
| "This feels productive" | Unrouted action can skip user constraints or durable workflow gates. |
| "I know what that means" | Use the current entry rules, not remembered behavior. |

开发流程同理：小改动也要先完成 `new-task` mode routing；workflow 模式先成计划再实现；用户或风险要求 workflow 时 review/test 不可跳过；输入不足才进 `spec`，不是默认回到全量需求流程。

## Skill Priority

1. 开发主流程 skill 最优先：先 `resume / switch / new / inbox` 判定，`new-task` 再选 `quick | workflow | ask`
2. 流程型分支其次（如输入不足才进 `spec`）
3. 委派型再次（如 `codex`）

"做一个新功能" → 先 `new-task` mode routing；需要计划 / 留痕时进 orchestrator。"Fix this bug" → 先判 quick/workflow；低风险快修可 quick，需要 review/test 时进 harness。

## Skill Types

**Rigid**（TDD、debugging、gated workflow）严格按纪律执行；**Flexible**（patterns）按原则适配上下文。skill 自身会说明属于哪种。

## User Instructions

Instructions say WHAT, not HOW. “Add X” / “Fix Y” 不代表可以跳过 mode routing 或 workflow。
