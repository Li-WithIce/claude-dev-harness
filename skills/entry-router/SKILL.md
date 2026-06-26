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

**In Claude Code:** use the `Skill` tool; invoking a skill loads its content — follow it directly, never `Read` skill files. **In other environments:** check your platform's docs.

# Using Skills

**Invoke relevant or requested skills BEFORE any response or action.** Even a 1% chance a skill might apply means invoke to check; if it turns out wrong, you don't have to use it.

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

- **quick**：低风险、边界清楚、当前对话内可完成并验证的小改动 / 简短回答。默认不建 `docs/tasks/<task-id>/`，不改共享指针。
- **workflow**：需要计划 / 留痕 / review / test、多文件跨模块、较高风险或用户明确要求可审计产物时，导向 `/orchestrator` 建 `plan.md`。
- **ask**：只在 quick/workflow 信号冲突或验收 / 风险边界不足时，问一个最小澄清问题。

显式覆盖词：偏 quick（`直接改`、`快修`、`小改一下`、`不用 workflow`、`别走流程`）；偏 workflow（`走 workflow`、`留痕`、`需要 review`、`需要 test`、`跑完整流程`、`写计划`）。无显式词时：窄范围 / 单文件 / 小修 / 验收清楚 / 失败影响低 → 默认 `quick`；需求仍在成形 / 影响面不清 / 改协议或脚本或多阶段产物 / 需要独立 review-test 证据 → 默认 `workflow`。quick 执行中影响面扩大或用户开始要留痕，停止扩大并切 workflow 或先确认。

### 懒加载

- `quick`：只加载入口规则、用户偏好 / 必要配置和直接相关 skill；不加载 orchestrator 或全部 stage skill。
- `workflow`：加载本 skill + `orchestrator`，再按当前 stage 只加载一个阶段 skill（`PLAN→plan`、`PLAN_REVIEW/CODE_REVIEW→review`、`IMPLEMENT→implement`、`TEST→test`）。
- `resume-current` / `switch-existing`：先读恢复运行时（恢复索引 / 当前任务 / tasks），再按 `plan.md` frontmatter stage 加载当前 stage skill。
- `ask`：不加载 workflow skill，只问一个最小澄清问题。

禁止 bulk-load 全部 skills / 全部历史任务 / Claude 兼容 skill / `workflow-team`；仅在显式 backend override、frontmatter 命中或 `$env:AIONUI_TEAM_MODE='1'` 时才加载这些路径。

### 同族分支路由（按需，写法见对应单一真相源）

- **Clarification 协议族**（需求澄清 / 拷问 / 头脑风暴 / 方案压力测试 / 边界确认 / `clarify` / `brainstorm` / `pressure test` 等）：仍走 `new-task mode=workflow`，在 `PLAN -> ## Clarification` 沉淀问题 / 推荐答案 / 决策，确认前 `## User Confirmation` 保持 `draft`；信息不足以判归属时走 `ask`；可查问题先自查再给推荐答案。详细写法见 `plan` skill 与 lite-writing-guide。
- **Markdown / HTML artifact**：需要互转 / HTML 报告 / 网页 artifact / 发布预览 / 从 URL 提取 Markdown 时按需加载 `md-html` skill；Markdown 是 source of truth、HTML 是 generated artifact，边界见该 skill。
- **开发流程细节**：5 阶段 harness-lite、`plan.md` frontmatter 真相源、`advance-stage.ps1` 推进语义、`spec.md` 可选附件等，见 `orchestrator` skill 与 README，本入口不重复。

## 调用层级

1. 开发主流程：orchestrator → plan / implement / review / test
2. 可选补充：`spec`（仅输入不足时生成 delta-spec）
3. 可选委派：`codex`（用户显式要求或当前 stage `tool: codex` 时）

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
