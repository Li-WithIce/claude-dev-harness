---
name: entry-router
description: Canonical entry router for choosing quick, workflow, ask, resume, switch, or inbox-first paths and loading only the necessary shared memory and local skills.
---

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. This is not optional. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

## How to Access Skills

**In Claude Code:** Use the `Skill` tool. When you invoke a skill, its content is loaded and presented to you. Follow it directly. Never use the Read tool on skill files.

**In other environments:** Check your platform's documentation for how skills are loaded.

# Using Skills

**输出语言：** 中文（非代码文本）。代码、命令、标识符保留英文。

## The Rule

**Invoke relevant or requested skills BEFORE any response or action.** Even a 1% chance a skill might apply means that you should invoke the skill to check. If an invoked skill turns out to be wrong for the situation, you don't need to use it.
**Language: Default to using Chinese (retain English for necessary terms)**

## 共享记忆（内联自 obsidian-memory）

共享记忆仓库：`{VAULT_PATH}`
不再需要单独调用 `obsidian-memory` skill，核心规则已内联于此。

### 恢复触发

用户说“继续”“恢复”“resume”“刚才做到哪里了”时，直接在本 skill 内完成恢复：
1. 读 `运行时\恢复索引.md`
2. 细节不足时读 `运行时\当前任务.md`（共享指针）→ `运行时\tasks\<task-id>.md`（任务级详细状态）
3. 再读 `运行时\中断任务.md` → `运行时\上次会话.md`
4. 回复使用三段式：当前主任务 / 其他中断任务 / 恢复选项

### 写回规则

- 多步骤任务开始、切换：更新 `运行时\当前任务.md` + `运行时\tasks\<task-id>.md`
- 任务暂停或待续：同步 `运行时\中断任务.md`
- 阶段完成：更新 `运行时\上次会话.md` 并刷新 `运行时\恢复索引.md`
- 未确认的稳定偏好先写 `运行时\记忆候选.md`
- 新事项先写 `运行时\收件箱.md`

### Guardrails

- 共享真相源只在 `.assistant`
- 不在 `.claude`、`.codex` 下创建平行 runtime note
- 不在 `MEMORY.md`、`配置\*.md`、`配置\引导状态.md` 记录当前任务
- 长期记忆提升前必须得到用户确认
- 详细规则参考：`obsidian-memory` skill（已降级为参考文档）

## 开发任务优先路由

当检测到**开发意图**时（开发、修 bug、重构、代码 review、测试验证、写 spec、写 plan、实现功能），**必须先进入开发路由**：

在导向之前，先判断请求类型：`resume-current` / `switch-existing` / `new-task` / `inbox-first`。不要把“分析结束后的继续聊天”当成开发任务入口。

- **resume-current**：读 `运行时\当前任务.md` → 找 `docs/tasks/<task-id>/plan.md` frontmatter stage → 由 orchestrator 恢复
- **switch-existing**：读 `运行时\中断任务.md` → 选定 task → 由 orchestrator 恢复
- **inbox-first**：信息不足且无法判断归属时，先按共享记忆规则写入收件箱
- **new-task**：先做 `mode` 路由，再决定是否导向 orchestrator

### new-task mode routing

`new-task` 后必须选择 `mode: quick | workflow | ask`。默认自主判断，只在低置信度时 `ask`。

- **quick**：低风险、边界清楚、可在当前对话内直接完成和验证的小改动 / 简短回答。默认不创建 `docs/tasks/<task-id>/`，不改共享指针。
- **workflow**：需要计划、留痕、review、test、多文件/跨模块协作、较高风险或用户明确要求可审计产物时，导向 `/orchestrator` 创建 `docs/tasks/<task-id>/plan.md`。
- **ask**：只有 quick/workflow 信号冲突、验收或风险边界不足以判断时使用；只问一个最小澄清问题。

显式覆盖关键词：

- 偏 quick：`直接改`、`快修`、`小改一下`、`不用 workflow`、`别走流程`
- 偏 workflow：`走 workflow`、`留痕`、`需要 review`、`需要 test`、`跑完整流程`、`写计划`

默认判断：

- 窄范围、单文件或文档小修、验收清楚、失败影响低、可立即验证时，默认 `quick`。
- 需求仍在形成、影响面不清、需要用户确认验收、会改共享协议 / 脚本 / 多阶段产物、或需要独立 review/test 证据时，默认 `workflow`。
- quick 执行中若发现影响面扩大或用户开始要求留痕 / review / test，停止扩大实现并切换到 workflow 或先确认。

### 自动懒加载规则

完成 `resume-current / switch-existing / new-task / inbox-first` 判定后，按模式收缩读取面：

- `quick`：只加载入口规则、用户偏好 / 必要配置，以及与本次请求直接相关的 skill 或 reference；不加载 orchestrator 或全部 stage skill。
- `workflow`：加载本 skill 与 `orchestrator`，再按当前 stage 只加载一个阶段 skill：`PLAN -> plan`、`PLAN_REVIEW -> review`、`IMPLEMENT -> implement`、`CODE_REVIEW -> review`、`TEST -> test`。
- `resume-current` / `switch-existing`：先加载 `运行时\恢复索引.md`、`运行时\当前任务.md`、`运行时\tasks\<task-id>.md`；必要时只读当前任务 `plan.md` frontmatter 判定 stage，再加载当前 stage skill。
- `ask`：不加载 workflow skill，只问一个最小澄清问题。

禁止 bulk-load 全部 skills、全部历史任务、Claude 兼容 skill、`workflow-team`。只有显式 backend override、当前 stage/frontmatter 命中、或 `$env:AIONUI_TEAM_MODE='1'` 触发时才加载这些路径。

### Markdown / HTML artifact route

当用户明确要求 Markdown/HTML 互转、HTML 报告、网页 artifact、Markdown 发布预览、从 URL/HTML 提取 Markdown、或浏览器交付物时，按需加载 `md-html` skill。

- `quick`：小文档直接转换、生成或导入；Markdown 默认是 source of truth，HTML 是 generated artifact。
- `workflow`：复杂交付先在 PLAN 中声明 Markdown source、HTML artifact 和验证方式，再按当前 stage 加载阶段 skill；`md-html` 作为相关 skill/reference 使用，不进入默认 stage whitelist。
- `workflow` 中如 `spec.md` / `plan.md` 超过 160 行或含 8 个及以上 `##` 二级标题，且需要人工审阅/决策、Markdown 层次不够清晰，默认使用 fixed template 生成 paired reading HTML（`plan.review.html` / `spec.review.html` 或 `review.html`）。
- `ask`：缺少方向、用途、输出路径或样式边界时，只问一个最小澄清问题。

不要在同一轮同时自由编辑 Markdown 和 HTML。内容改动走 Markdown 后再生成 HTML；视觉改动走模板/样式规则后再生成 HTML；HTML -> Markdown 只承诺导入/审阅/归档，不承诺像素级还原。
局部 HTML 增强只限卡片、对比区、流程区、信息网格；不输出完整页面，不把 HTML 放进代码块，不使用 `script`、`iframe` 或外部 JS。

### 当前开发流程（Harness Lite v2）

5 个可执行阶段：`PLAN → PLAN_REVIEW → IMPLEMENT → CODE_REVIEW → TEST`

- 唯一真相源：`docs/tasks/<task-id>/plan.md` frontmatter（`stage`、`tool`、`task_id`）
- 终态标记：`DONE`，只写回 `plan.md` frontmatter，不是独立 stage
- 默认执行面是 Codex-only：PLAN / PLAN_REVIEW / IMPLEMENT / CODE_REVIEW / TEST 都使用 `harness-default-codex`
- 阶段推进：优先使用 `.assistant\entry\advance-stage.ps1 -TaskId <id>`；需要切换 backend 时再传 `-Tool <claudecode|codex>`
- 非 `DONE` 推进的下一阶段 tool 解析顺序是：显式 `-Tool` → 显式 `-Profile` → `agent-configs/workflows/harness-lite.yaml` 的 `default_profile`
- 只有在显式 `-Tool`、显式 `-Profile` 和 workflow `default_profile` 都缺失时，非 `DONE` 推进才会报 `requires -Tool`
- 用户可以在任意 stage 边界切换不同工具继续同一个 task
- CODE_REVIEW revise → 回 IMPLEMENT；TEST fail/blocked → 停止报告，不触发 IMPLEMENT 循环
- spec.md 只作为可选附件，不是默认入口

### 开发任务判定标准

- 新功能开发、功能实现
- Bug 修复、调试
- 代码重构
- 代码 review
- 测试验证
- 需求分析（delta-spec / 开发边界说明）
- 方案设计（开发计划）

非开发任务不进入 harness-lite workflow，由宿主自身能力或外部 skill 处理。

## 调用层级

| 层级 | Skill 类型 | 说明 |
|------|-----------|------|
| 1 | 开发主流程 | orchestrator → plan / implement / review / test |
| 2 | 可选补充分支 | spec（仅在输入不足时生成 delta-spec） |
| 3 | 可选委派 | codex（用户显式要求或当前 stage 分配 `tool: codex` 时） |

规则：
- `spec` 在新流程中是**可选 delta-spec 分支**，不是默认入口
- 开发任务只走上面 3 层，不再依赖 repo 内置 specialist skill

## Red Flags

These thoughts mean STOP — you're rationalizing:

| Thought | Reality |
|---------|---------|
| "This is just a simple question" | Questions are tasks. Check for skills. |
| "I need more context first" | Skill check comes BEFORE clarifying questions. |
| "Let me explore the codebase first" | Skills tell you HOW to explore. Check first. |
| "I can check version control/files quickly" | Files lack conversation context. Check for skills. |
| "Let me gather information first" | Skills tell you HOW to gather information. |
| "This doesn't need a formal skill" | If a skill exists, use it. |
| "I remember this skill" | Skills evolve. Read current version. |
| "This doesn't count as a task" | Action = task. Check for skills. |
| "The skill is overkill" | Simple things become complex. Use it. |
| "I'll just do this one thing first" | Check BEFORE doing anything. |
| "This feels productive" | Undisciplined action wastes time. Skills prevent this. |
| "I know what that means" | Knowing the concept ≠ using the skill. Invoke it. |

### 开发流程 Red Flags

以下想法必须阻止，它们是跳过流程的合理化借口：

| Thought | Reality |
|---------|---------|
| "这个改动很小，不需要判断流程" | 小改动可以走 quick，但必须先完成 `new-task` mode routing。 |
| "先直接 implement，再补文档" | workflow 模式仍先形成计划；quick 模式只适用于边界清楚、可直接验证的低风险事项。 |
| "没有技术方案评审，就得先补完整 spec" | 新流程只在输入不足时生成可选 `DELTA_SPEC`，不是默认回到全量需求流程。 |
| "review/test 太慢，先提交" | 用户或风险要求 workflow 时，review/test 不可跳过。 |

## Skill Priority

When multiple skills could apply, use this order:

1. **开发主流程 skill 最优先**：开发任务先完成 `resume/switch/new/inbox` 判定；`new-task` 再选 `quick | workflow | ask`
2. **流程型分支 skill 其次**：例如仅在输入不足时进入 `spec`
3. **委派型 skill 再其次**：如 `codex`

"做一个新功能" → 先做 `new-task` mode routing；需要计划/留痕时进入 orchestrator。
"Fix this bug" → 先判断 quick/workflow；低风险快修可 quick，需要 review/test 时进入 harness。

## Skill Types

**Rigid**（TDD、debugging、gated workflow）：严格按纪律执行。

**Flexible**（patterns）：按原则适配上下文。

The skill itself tells you which.

## User Instructions

Instructions say WHAT, not HOW. “Add X” or “Fix Y” 不代表可以跳过 workflow。
