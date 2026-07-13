---
name: entry-router
description: Canonical entry router for choosing quick, workflow, ask, resume, switch, or inbox-first paths and loading only the necessary shared memory and local skills.
---

<EXTREMELY-IMPORTANT>
Entry-router is the default first hop for project-scoped development and read-only engineering requests. Do not invoke other workflow skills before routing. After routing, load only the minimum skill/context set required by the selected mode.
</EXTREMELY-IMPORTANT>

## How to Access Skills

**In Claude Code:** use the `Skill` tool; invoking a skill loads its content — follow it directly, never `Read` skill files. **In other environments:** check your platform's docs.

# Using Skills

For project-scoped development and read-only engineering requests, route through this skill first. Load non-workflow/domain skills only after routing, and only when directly relevant or explicitly requested. Route-specific lazy loading wins over broad skill discovery.

**输出语言：** 中文（非代码文本）；代码、命令、标识符保留英文。

## 共享记忆（内联自 obsidian-memory）

共享真相源只在 `.assistant`；详细规则参考 `obsidian-memory` skill（已降级为参考文档）。

### 恢复触发

先区分只读恢复查询与继续执行：`刚才做到哪里了 / what were we doing / status` 只做只读关联和三段式摘要；只有 `继续 / 恢复并执行 / continue / resume-and-execute` 明确要求推进已有 workflow 时，才获得恢复写权限。

1. 先只读 `运行时\收件箱.md` 中 open `[writeback-fallback]` 的元数据；只读恢复查询不重放，明确继续执行时才按 `task_id / expected_stage / operation / failed_step` 和对应 `plan.md` frontmatter 判断是否需要 `-SyncOnly`
2. 再读 `运行时\恢复索引.md`
3. 细节不足时读 `运行时\当前任务.md` → `运行时\tasks\<task-id>.md`
4. 再读 `运行时\中断任务.md` → `运行时\上次会话.md`
5. 回复三段式：当前主任务 / 其他中断任务 / 恢复选项

### 写回规则

- 只有用户明确开始、继续或切换并执行 write-authorized `mode=workflow` 时，才读取实际 frontmatter stage，并通过 `advance-stage.ps1 -TaskId {task_id} -ExpectedStage {actual_stage} -SyncOnly -ActivateCurrent` 同步 mirror 或显式切换 current
- write-authorized workflow 暂停或待续：同步 `运行时\中断任务.md`
- write-authorized workflow 阶段完成：更新 `运行时\上次会话.md` 并刷新 `运行时\恢复索引.md`
- 发现可能值得沉淀的稳定偏好时，只向用户提示；只有用户明确要求记录/沉淀记忆后才写 `运行时\记忆候选.md`。只有已授权持久捕获的 actionable/durable 新事项才写 `运行时\收件箱.md`，交互式歧义先 ask

### Guardrails

- 不在 `.claude` / `.codex` 下创建平行 runtime note
- 不在 `MEMORY.md` / `配置\*.md` / `配置\引导状态.md` 记录当前任务
- 长期记忆提升前必须得到用户确认

## 项目请求优先路由

先判断请求是否属于当前项目 / 仓库。真正的非项目请求不进入 harness-lite，由宿主能力或外部 skill 处理。项目内的 answer / explain / inspect / read-only review / status report / diagnose 也要进入下面的归属与 mode 判定，不能因为“不改代码”而绕过 quick 的无写入合同：

- **resume-current**：先只读 `运行时\当前任务.md`、目标 `plan.md` 与必要 runtime。仅当用户明确继续 / 恢复并执行 / resume-and-execute / 执行当前 stage 时，才处理 open `[writeback-fallback]`、按需 `-SyncOnly` 并加载 orchestrator/current-stage skill；裸 `恢复一下 / resume` 走 ask，只读 status/review 不 replay、不 sync、不加载 stage skill。
- **switch-existing**：先只读 `运行时\中断任务.md` 与目标 artifact。仅当用户明确切换并继续 / 执行时，才用 `-SyncOnly -ActivateCurrent -ExpectedStage <actual>` 激活并加载 current-stage skill；只读检查 inactive task 不改 current/mirror。
- **inbox-first**：只用于用户或外部来源已授权持久捕获、内容 actionable/durable 但暂时无法确定 task identity 的事项；交互式归属或读写歧义直接 `ask`，不写 inbox。再次选中既有 inbox row 时，从 `triage-runtime-inbox.ps1 -List` 的单行 JSON 读取 `open_items[].route_task_id` 作为唯一 task identity，并保留同项的临时 `row_id` 供精确分诊；`task_plan_exists=true` 走 `switch-existing`，否则重新执行 `new-task -> quick|workflow|ask`，不得另选 slug。quick 在交付与验证成功后立即用 `-RowId <row_id>` 清来源 row；workflow 只有在 canonical PLAN、validator 与 background `-SyncOnly` 成功后才清；ask/pending 或任一步失败都保持 row open。
  - machine contracts: `open inbox + existing docs/tasks/{task_id}/plan.md -> switch-existing`; `quick success -> exact triage`; `new workflow -> validator -> background SyncOnly -> exact triage`; `ask/pending/failure -> inbox row remains open`; `create/triage crash -> inbox row remains open`; `unknown inbox row -> deterministic route_task_id; task_plan_exists -> switch-existing, otherwise new-task`.
- **new-task**：先做 `mode` 路由

归属与授权必须分开：route identity does not broaden requested action。active task 的只读 status/review 即使命中 `resume-current` / `switch-existing`，也只能检查和报告，不能因此追加 Run、推进 stage 或修复。

### new-task mode routing

`new-task` 后按行为意图选择 `mode: quick | workflow | ask`：

1. **standalone project-scoped read-only -> quick**：纯 answer / explain / inspect / read-only review / status report / diagnose，且目标、范围、输出清楚时直接在当前对话完成；默认不建 `docs/tasks/{task_id}/`、不改共享指针、不加载 orchestrator/stage skill。代码或生产区域高风险只提高证据与审查强度，不自动授权 durable artifact；用户明确要求 workflow、audit file、canonical review/test evidence 等持久产物时才转 workflow。
2. **mutation -> 既有风险门**：请求含 change / build / fix / implement，或 mixed read+write 时，不得套用 read-only shortcut。范围与验收清楚、风险低、当前对话可完成并验证、且未要求 durable workflow/artifact 时可 quick；触碰入口协议、脚本、模板、validator、多文件 / 跨模块、高风险路径，或要求计划、留痕、staged review/test evidence 时走 workflow。
3. **ambiguous read/write -> ask**：是否写入、是否继续已有任务，或 intent / scope / acceptance criteria / constraints / risk / affected area / output format / route choice 会改变执行路径且仍不清楚时，进入 Deep Clarification Mode。Ask mode is an iterative blocking clarification gate；默认一次只问一个 highest-value clarification question。After every user answer / 每次用户回答后重新判断，Remain in ask until all blocking uncertainties are resolved，再转 quick 或 workflow。

判定示例：`review this module, no edits` -> quick；`review production auth, no edits` -> quick with stronger evidence；`review and fix typo` -> 按低风险 mutation 可 quick；`review and apply cross-module/high-risk fix` -> workflow；`write audit.md` / `append Code Review Run` -> workflow；`report active task foo status` -> resume/switch 且保持只读；`看看问题，有问题就处理` -> ask。`review` / `test` / `plan` / `status` / `diagnose` 等名词本身不决定 mode。

### 懒加载

- `quick`：只加载入口规则、用户偏好 / 必要配置和直接相关 skill；不加载 orchestrator 或全部 stage skill。
- `workflow`：加载本 skill + `orchestrator`，再按当前 stage 只加载一个阶段 skill（`PLAN→plan`、`PLAN_REVIEW/CODE_REVIEW→review`、`IMPLEMENT→implement`、`TEST→test`）。
- `resume-current` / `switch-existing`：先只读 identity/runtime/artifact；只有明确继续 / 切换并执行当前 workflow 时才处理 fallback、`-SyncOnly` / activate 并加载 current-stage skill。read-only inspect/status 保持 minimal context 和零写。
- `ask`：不加载 workflow stage skill；不进入 quick、workflow、PLAN、IMPLEMENT 或后续阶段；不创建 `docs/tasks/{task_id}/`、不改代码、不初始化 provider。Remain in ask until all blocking uncertainties are resolved.

禁止 bulk-load 全部 skills / 全部历史任务 / Claude 兼容 skill / `workflow-team`；仅在显式 backend override、frontmatter 命中或 `$env:AITEAMCODE_TEAM_MODE='1'` 时才加载这些路径。

### ask response format

Deep Clarification Mode 只输出足以解除阻塞的澄清内容。不要问可由当前 repo 文件低成本查到的问题；可给推荐默认值，但除非用户确认或项目规则显式允许默认，否则不得按默认值继续。

推荐格式：

```markdown
我先停留在 ask，因为还有一个会影响路由/实现的关键问题没有确认。

我目前理解：
- ...

当前阻塞点：
- ...

请先确认一个问题：
- ...

我的建议默认值：
- ...

你确认后，我会重新判断应该走 quick 还是 workflow。
```

### Ask exit criteria

ask cannot exit until the agent can state:

1. User goal:
2. Success / acceptance criteria:
3. In scope:
4. Out of scope / non-goals:
5. Affected area:
6. Constraints:
7. Risk level:
8. Expected output:
9. Recommended route: quick or workflow
10. Why this route is safe:

If any item is materially unknown and affects the work, remain in ask. Simple ambiguity may be resolved with one question, but ask mode remains active until all blocking uncertainties are resolved.

### 同族分支路由（按需，写法见对应单一真相源）

- **Clarification 协议族**（需求澄清 / 拷问 / 头脑风暴 / 方案压力测试 / 边界确认 / `clarify` / `brainstorm` / `pressure test` 等）：pure read-only/no-edit 的方案审查仍 quick；只有需要 durable development decision、canonical artifact 或后续实现时才走 `new-task mode=workflow`，在 `PLAN -> ## Clarification` 的 `clarification_ledger` 沉淀问题 / 证据 / 推荐答案 / 决策 / 影响，并保留 Clarification 最低字段。PLAN 的验收、非目标、影响面、回滚/兼容仍不确定，或实现路径不足以指导 IMPLEMENT 时沿用该 durable Clarification；确认前 `## User Confirmation` 保持 `draft`。若读写/归属仍不清楚则停留 `ask`，不得创建 artifact；可查问题先自查，剩余用户决策一次一个并给推荐答案。详细写法见 `plan` skill 与 lite-writing-guide。
- **Stage Discipline Matrix**：Entry/Ask 用 Socratic Blocking Clarification，Quick 用 Smallest Reversible Action。完整矩阵在 `docs/工作流/stage-discipline-matrix.md`；只在需要澄清 route/stage discipline 或审查 stage 行为时加载。
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

"做一个新功能" → 先 `new-task` mode routing；需要计划 / 留痕时进 orchestrator。"Fix this bug" → 先判 quick/workflow；低风险快修可 quick，需要 durable/staged review/test evidence 时进 workflow。

## Skill Types

**Rigid**（TDD、debugging、gated workflow）严格按纪律执行；**Flexible**（patterns）按原则适配上下文。skill 自身会说明属于哪种。

## User Instructions

Instructions say WHAT, not HOW. “Add X” / “Fix Y” 不代表可以跳过 mode routing 或 workflow。
