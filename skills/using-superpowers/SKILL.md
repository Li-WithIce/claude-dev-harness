---
name: using-superpowers
description: Use when starting a conversation to route work to the right local skill and load shared Obsidian memory when the task needs context or recovery.
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
- 不在 `.claude`、`.codex`、`.gemini` 下创建平行 runtime note
- 不在 `MEMORY.md`、`配置\*.md`、`配置\引导状态.md` 记录当前任务
- 长期记忆提升前必须得到用户确认
- 详细规则参考：`obsidian-memory` skill（已降级为参考文档）

## 开发任务优先路由

当检测到**开发意图**时（开发、修 bug、重构、代码 review、测试验证、写 spec、写 plan、实现功能），**优先导向 orchestrator**：

1. 先检查 `.assistant/orchestration/current-flow.md` 是否存在
2. **存在**：仍先导向 `/orchestrator`，由 orchestrator 读取 `current-flow.md` 与共享运行时后恢复当前阶段
3. **不存在**：导向 `/orchestrator` 启动新的开发流程

### 当前开发流程定位

- 该 workflow 只覆盖**开发阶段执行 harness**，不是全生命周期研发流程
- 默认输入至少包括**已批准的需求评审结果**；若任务涉及用户可见 UI 变更，则还需要已批准的 UI 评审；不涉及 UI 的任务要显式记录 `ui review: not-applicable`
- 技术方案评审如果存在则一并消费；如果不存在，不默认阻塞进入主路径
- workflow 的责任是：`INTAKE -> PLAN -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF`
- 若输入不足，由 orchestrator 决定是否生成可选 `DELTA_SPEC` 作为差量边界说明，而不是回退到全量需求流程

### 开发任务判定标准

- 新功能开发、功能实现
- Bug 修复、调试
- 代码重构
- 代码 review
- 测试验证
- 需求分析（delta-spec / 开发边界说明）
- 方案设计（开发计划）

非开发任务（文档查阅、IM 配置、PPT/Excel 创建等）按常规 skill 路由处理。

## 调用层级

| 层级 | Skill 类型 | 说明 |
|------|-----------|------|
| 1 | 开发主流程 | orchestrator → plan / implement / review / test |
| 2 | 可选补充分支 | spec（仅在输入不足时生成 delta-spec） |
| 3 | 可选委派 | codex（用户显式要求时）、gemini-designer-main（TEST 阶段） |
| 4 | Specialist（二级能力） | frontend-design、webapp-testing、claude-api 等 |

规则：
- 开发主流程 skill 高于 specialist skill
- `spec` 在新流程中是**可选 delta-spec 分支**，不是默认入口
- Specialist skill **仅在具体 stage 内**作为二级能力调用，不作为开发主流程入口
- 用户说“帮我做一个前端页面”时，仍先进 orchestrator，再在 DEV 阶段内调用 `frontend-design`

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
| "这个改动很小，不需要 orchestrator" | 小改动走 fast-track 模式，仍需进入 orchestrator。 |
| "先直接 implement，再补文档" | 文档驱动开发是纪律。先形成开发计划。 |
| "没有技术方案评审，就得先补完整 spec" | 新流程只在输入不足时生成可选 `DELTA_SPEC`，不是默认回到全量需求流程。 |
| "review/test 太慢，先提交" | 没有 review/test 的实现是未验证的实现。不可跳过。 |

## Skill Priority

When multiple skills could apply, use this order:

1. **开发主流程 skill 最优先**：开发任务先进入 orchestrator
2. **流程型分支 skill 其次**：例如仅在输入不足时进入 `spec`
3. **实现型 skill 再其次**：如 `frontend-design`、`webapp-testing`

"做一个新功能" → orchestrator first, then PLAN / DEV 阶段内按需调用其他 skill。
"Fix this bug" → orchestrator first，再进入开发阶段 harness。

## Skill Types

**Rigid**（TDD、debugging、gated workflow）：严格按纪律执行。

**Flexible**（patterns）：按原则适配上下文。

The skill itself tells you which.

## User Instructions

Instructions say WHAT, not HOW. “Add X” or “Fix Y” 不代表可以跳过 workflow。
