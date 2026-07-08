# Lite Writing Guide

本指南约束 `harness-lite` 主线里的任务文档写法。目标只有一个：让 `docs/tasks/<task-id>/` 下的产物既能给人看，也能被脚本稳定读取。

## 适用范围

- `docs/tasks/<task-id>/plan.md`
- `docs/tasks/<task-id>/spec.md`
- `plan.md` 里的 append-only `Plan Review / Implementation Notes / Code Review`
- `docs/tasks/<task-id>/test.md`

本指南只约束 `new-task mode=workflow` 后的任务产物。`mode=quick` 默认不创建 `docs/tasks/<task-id>/`，只在当前对话内完成、验证并报告；若 quick 执行中发现需要留痕、review、test 或影响面扩大，应切换到 workflow。`mode=ask` 是 workflow 前的 iterative blocking clarification gate：未解除阻塞前不创建 `docs/tasks/<task-id>/`、不进入 PLAN、不修改代码。

## 通用原则

- 只写当前 task 的差量信息，不重写全量背景。
- 机器可读字段必须逐字匹配，不改 section 名、不改字段名。
- 所有路径都写仓库内真实路径，不写“相关文件”“某模块”这类模糊说法。
- 所有验证命令都写可执行命令，不写“自行测试”。
- 不适用时写 `none` 或 `not-applicable`，不要留空标题或占位段落。
- append-only 区块只追加新 run，不回写或改写旧 run。

## plan.md 契约

### Frontmatter

`plan.md` frontmatter 必须包含 4 个基础字段，并可选择性增加 `tool_profile` / `model`：

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | none
tool_profile: harness-default-codex
model: gpt-5.5/xhigh
updated: YYYY-MM-DD
---
```

规则：

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`
- `DONE` 只能写 `tool: none`
- `tool` 表示“当前 stage 由哪个 backend 继续”，即使用 profile 也必须显式保留
- `tool_profile` 指向 `agent-configs/profiles/<name>.yaml`
- 当前 stage 的 `tool_profile/model` 只是活跃元数据，不会作为下一 stage 的黏性 fallback
- 存在 `tool_profile` 时，`tool` 必须等于 profile 描述符中的 `backend`
- `model` 必须写完整模型 ID，不写 `opus`、`pro`、`latest` 这类短别名
- 未启用 `tool_profile` / `model` 时，旧四字段 frontmatter 继续合法

### Workflow Descriptor（可选）

若仓库启用了 `agent-configs/workflows/harness-lite.yaml`，它只为下一 stage 提供 `workflow-default` fallback，不改变 `plan.md` frontmatter 仍是唯一当前 stage 真相源。

当前仓库的默认 descriptor 是 Codex-only：`PLAN`、`PLAN_REVIEW`、`IMPLEMENT`、`CODE_REVIEW`、`TEST` 都默认使用 `harness-default-codex`。如需 Claude Code 介入，必须在当前任务或推进命令里显式指定对应 backend / profile。

最小字段：

```yaml
name: harness-lite
version: 1
stages:
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
```

规则：

- fallback 顺序固定为：显式 `-Tool` → 显式 `-Profile` → workflow descriptor `default_profile`
- descriptor 只影响“下一 stage 默认选哪个 profile/backend”，不会把当前 stage 的 `tool_profile` 黏性传下去
- descriptor 校验问题只出现在 validator 的 `Warnings:` 段，不会单独变成 `Errors:`

### Optional Context Providers

Context providers 只提供 advisory context。Provider output is evidence candidate, not workflow truth；任何 provider 结果影响决策前，必须落回当前仓库真实文件、命令、diff、review finding、Implementation Notes 或 test output。Provider 不可写 frontmatter、`.assistant/运行时/*`、review verdict 或 TEST conclusion；不可用、stale 或冲突时回退 `rg`/Read/manual inspection。

Provider usage may be recorded inside an append-only run when it affected scope, risk, or verification. This is not frontmatter, not a stage gate, and not a verdict source:

```yaml
provider_context:
  - provider: codegraph | agentmemory | codedb-mcp | none
    purpose: impact-scan | historical-recall | risk-scan | test-scope
    grounded_to:
      - path/or/command
    fallback: rg/read/manual-inspection
    limitations: stale-index | historical-only | unavailable | none
```

If no provider was used, write `provider_context: none` only when useful, otherwise omit it.

### Phase 3 Side Artifacts（可选）

- `docs/tasks/<task-id>/skill-manifest.json`：由 `advance-stage.ps1` 在成功推进后 best-effort 生成；不是新的真相源，也不写入 `.assistant/`
- `docs/tasks/<task-id>/skills-index.md`：由 `scripts/generate-skills-index.ps1` 生成，给嵌入消费端或非原生 backend 展示当前 stage 的可用 skills
- invocation trace 只允许以单行 `- invocation: ...` 追加到已有 `### Run N` 块内部；目标 section 没有 Run block 时必须跳过，不能新建 section 或 bare 顶层 bullet

### 必备 section

推荐顺序固定为：

1. `## Clarification`
2. `## User Confirmation`
3. `## Plan`
4. `## Verification`
5. `## Risks`
6. `## Plan Review`
7. `## Implementation Notes`
8. `## Code Review`

### 可选 section：Change Contract

在 `## User Confirmation` 与 `## Plan` 之间可以插入可选的 `## Change Contract`，把本次变更的类型和路径以机器可读方式声明出来，降低 IMPLEMENT/CODE_REVIEW/TEST 理解成本。

格式固定为：

```markdown
## Change Contract
- change_type: task | feature | enhance | refactor
- affected_paths:
  - <path>
  - <path>
```

字段规则：

- `change_type` 必须在枚举内：`task | feature | enhance | refactor`
- `affected_paths` 至少一条非空、非占位条目（占位符 `<path>` 视为未填）
- 未启用该 section 时 validator 自动跳过；这是 opt-in 字段

不写 `## Change Contract` 不影响现有任务——旧任务继续通过。

### Clarification 最低要求

`## Clarification` 必须逐项覆盖：

- 验收标准
- 非目标
- 受影响目录 / 模块
- 回滚策略或兼容性约束
- `ui: <expectation | not-applicable>`

`clarification_ledger` 只补充问题树和决策留痕，不能替代上述最低字段；即使八类账本都已闭环，`advance-stage` / validator 仍依赖这些机器可读行。

#### 推理纪律：第一性原理 / 剃刀法则 / 贝叶斯

解决问题、修 bug、设计架构或方案时，Clarification 与 Plan 的推理按这三条纪律收敛；落到产物里只写结论与依据，不写口号：

- **第一性原理**：先回到问题的本质约束与目标，而不是照搬现成做法或类比。在 `## Clarification` 写清真正要解决的根本问题和不可让步的约束；bug 任务用 `bug.root_cause_action` 对齐根因而非症状，与 IMPLEMENT 的“症状补丁”反射检查同一口径。
- **剃刀法则**：在满足验收与约束的前提下选最简方案，砍掉非必要实体、抽象与依赖。计划外抽象、邻近顺手重构属于要剔除项（与 IMPLEMENT 反射检查同口径），`## Plan` 只保留必要、可执行的 TODO。
- **贝叶斯更新**：把方案当成带先验的假设，遇到新证据（代码事实、验证结果、review finding）就更新结论，不锚定初稿。Clarification 协议族“一次一个关键问题、先自查再给 `recommended_answer`”就是这条纪律的写法；回修后用新 run 记录被证据更新过的判断。

这三条只约束推理与写作方式，不新增 stage、frontmatter 字段或 validator gate。

#### 阶段原则路由

harness-lite 仍只有 `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST`；以下大师/原则只是各阶段的默认认知视角，不新增五转 pipeline、stage、frontmatter 字段、runtime 文件或 validator hard gate：

- **Entry / Clarification — Socrates**：先分清输入是外部论点、用户需求、内部推理还是待验证结论。外部论点先做来源与代码 / 文档 / artifact 证据核对；用户需求进入 Clarification 问题树；内部推理回到根约束并找反例；待验证结论进入后续 Verification / TEST 证据收集。剩余用户决策一次只问一个。
- **PLAN 发散 — Osborn**：复杂方案不要过早锁死；先列替代路径，但只保留会影响验收、非目标、风险或实现路径的发散结果。
- **PLAN 收敛 — Hegel**：把发散项收成关键矛盾、依赖、未决项和可执行 TODO。
- **PLAN 方案选择 — First Principles + Occam**：回到根约束和验收，选择最小必要方案，删除计划外抽象。
- **PLAN_REVIEW — Hegel + Bayes**：检查计划是否自洽，前提是否有代码 / 文档 / artifact 证据，未决项是否闭环。
- **IMPLEMENT — Ponytail / Surgical Change**：最小正确 diff，根因修复，不顺手重构。
- **CODE_REVIEW — Feynman**：盲审、证据、反例验证；判断否决必须给可执行反例，给不出则只作为非阻断提示。
- **TEST — Bayes**：用真实验证更新结论；没证据不写 pass。
- **revise 后 — Debono**：记录被否方案中仍应保留的约束、价值或适用条件，避免过度批判。

#### Clarification 协议族

“需求澄清”“需求确认”“拷问需求”“拷问方案”“头脑风暴”“方案压力测试”“设计访谈”“边界确认”“验收标准确认”“非目标确认”，以及 `clarify`、`brainstorm`、`pressure test`、`challenge this plan`、`ask me questions`、`interrogate the requirement` 等表达，都是同一类 PLAN/Clarification 触发词。

规则：

- 它们只改变 PLAN 写作方式，不新增 workflow stage、frontmatter 字段、runtime、validator hard gate 或第二 truth。
- 触发范围包括显式触发词，也包括 PLAN 的验收、非目标、影响面、回滚/兼容任一项仍不确定，或实现路径仍不足以指导 IMPLEMENT。
- 开发任务需要留痕或后续实现时，在 `PLAN -> ## Clarification` 中用 `clarification_ledger` 沉淀问题、证据、推荐答案、决策和影响；用户确认前 `## User Confirmation` 保持 `- status: draft`。
- `clarification_ledger` 是 `Clarification 最低要求` 的补充，不替代 `验收标准 / 非目标 / 受影响目录或模块 / 回滚策略或兼容性约束 / ui:`；这些字段必须继续出现在 `## Clarification` 中。
- 信息不足以判断 quick/workflow 时才走 `ask`。Ask mode is an iterative blocking clarification gate：默认一次只问一个 highest-value clarification question；每次用户回答后重新判断是否足以路由；Remain in ask until all blocking uncertainties are resolved；只有阻塞问题全部解除后，才可进入 `quick` 或 `workflow`。
- Ask exit criteria: ask cannot exit until the agent can state User goal, Success / acceptance criteria, In scope, Out of scope / non-goals, Affected area, Constraints, Risk level, Expected output, Recommended route: quick or workflow, and Why this route is safe. If any item is materially unknown and affects the work, remain in ask.
- 触发后先自行查证能由代码库、文档或现有 artifact 回答的问题；剩余用户决策按依赖顺序一次只问一个，并给 `recommended_answer`。
- `clarification_ledger` 分类限定为：`目标/验收`、`用户与权限`、`流程与状态`、`数据与边界`、`集成依赖`、`失败与回滚`、`非目标`、`验证证据`；触发协议时八类都必须有账本项。不适用类别写 `question: 该类别是否适用？`、`evidence: not-applicable`、`recommended_answer: 不适用`、`decision: accepted`、`impact: none`。
- 每个账本项使用字段 `category / question / evidence / recommended_answer / decision / impact`；`decision` 只能是 `pending | accepted | rejected`。存在 `pending` 时不得把 `## User Confirmation` 改成 `confirmed`。
- 不得代替用户伪造决策：能由代码 / 文档 / artifact 自行闭环的问题，`evidence` 必须写明证据路径或事实；需要用户选择的问题，在用户回答前必须保持 `decision: pending`，用户回答后把简要回答写入 `evidence`。
- `decision: accepted | rejected` 且 `impact` 不是 `none` 时，必须落到后续 `## Plan`、`## Verification` 或 `## Risks` 的对应 TODO / 命令 / 风险里；否则账本只是旁路记录，不算可执行决策。

账本项示例（节选）：

```markdown
- clarification_ledger:
  - category: 目标/验收
    question: 是否以当前需求替换旧测试期望？
    evidence: 代码和测试期望冲突，当前需求已明确新行为。
    recommended_answer: 接受新行为并更新旧测试。
    decision: accepted
    impact: IMPLEMENT 不保留旧测试兼容分支。
```

#### <a id="work-type-routing"></a>work_type（可选语义路由）

新任务可以在 `## Clarification` 内增加一行 `work_type`，帮助 PLAN_REVIEW 选择审查重点：

```markdown
## Clarification
- work_type: feature | bug | refactor | explore | doc | maintenance
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable
```

规则：

- `work_type` 只描述任务意图和审查路线，不是阶段字段，不写入 frontmatter。
- `work_type` 不替代 `## Change Contract`；`Change Contract.change_type` 仍描述产物或变更类型，并继续使用现有 validator 枚举。
- `work_type` 不参与 `advance-stage.ps1` 推进，不创建第二套真相源。
- 旧任务缺少 `work_type` 仍合法；只有存在该字段时，PLAN_REVIEW 才核对它与验收标准、非目标、受影响路径和验证命令是否一致。

#### bug / refactor 条件化模板

以下模板只在 `work_type: bug` 或 `work_type: refactor` 时使用。它们是 `plan.md` / `test.md` 内的写作约束，不新增 issue/analyze/fix stage，也不新增单独真相源文件。

<a id="work-type-bug-template"></a>`work_type: bug` 示例：

```markdown
## Clarification
- work_type: bug
- bug.repro: ...
- bug.expected: ...
- bug.actual: ...
- bug.impact: ...
- bug.root_cause_action: ...
- bug.fix_verification: ...
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable

## Verification
- `<rerun reproduction or equivalent command>`
- `<fix verification command>`
- `<impact regression command>`
```

<a id="work-type-refactor-template"></a>`work_type: refactor` 示例：

```markdown
## Clarification
- work_type: refactor
- refactor.invariant: ...
- refactor.scope: ...
- refactor.callers: ...
- refactor.equivalence_check: ...
- refactor.rollback: ...
- refactor.no_feature_change: ...
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable

## Verification
- `<behavior equivalence command>`
- `<affected caller regression command>`
```

规则：

- 这些字段只在对应 `work_type` 下启用，不要求普通任务填写。
- 不适用的字段要写原因，不能留下空占位。
- PLAN_REVIEW 应检查这些字段是否导出了可执行 verification；TEST 应按同一复现、修复验证或等价验证口径收集证据。
- `work_type: bug` 不等于新建 issue 流程；`work_type: refactor` 不等于绕过功能验收。

### User Confirmation

`## User Confirmation` 只使用这条机器可读字段：

```markdown
## User Confirmation
- status: draft | confirmed
```

规则：

- 用户确认前保持 `draft`。
- 若 `## Clarification` 含 `clarification_ledger`，存在 `decision: pending` 时不得写 `confirmed`。

### Plan 内容要求

在普通 TODO bullets 之前，可选地放一个 metadata-style 顶部块：

```markdown
## Plan
- read_first: [docs/shared-memory-layers.md, scripts/validate-lite-artifacts.ps1]
- convergence:
  - `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern '\[switch\]\$Quality'`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- artifacts: [docs/工作流/single-writer-precompact.md, scripts/validate-lite-artifacts.ps1]
- 更新 `scripts/validate-lite-artifacts.ps1`，统一质量评分校验。
```

- `read_first:`、`convergence:`、`artifacts:` 只允许出现在 `## Plan` 标题之后、第一条普通 bullet 之前
- `read_first:` 必须使用 inline-array 语法
- `convergence:` 下面至少 1 条非空 criterion，且不要只写 `TBD`
- `artifacts:` 必须使用 inline-array 语法，且至少列 1 条非空路径
- 示例顺序固定为 `read_first:` → `convergence:` → `artifacts:`；validator 不强制顺序，但文档示例与人工写作都按这个顺序
- `artifacts:` 表示任务产出物声明；不要和 `## Change Contract` 里的 `affected_paths` 混用
- `artifacts:` 是交付产物清单，`affected_paths` 是变更面清单；PLAN_REVIEW 应检查二者和非目标、verification 是否自洽，但旧任务缺少这些 opt-in 字段仍合法
- Artifact drift audit 是 advisory-only：validator 只在 `IMPLEMENT` 及之后阶段把声明 artifact 缺失、未声明 changed path、明显角色混淆写入 `Warnings:`，不写 `Errors:`，不改变 exit code。
- `PLAN` / `PLAN_REVIEW` 阶段不得因为未来 artifact 尚未创建而 warning；缺少 `artifacts:` 或 `Change Contract` 的旧任务继续合法。
- 不需要时整段删除即可；不要把它们插到普通 TODO 中途
- 每一项都是可执行动作，不写抽象口号。
- 尽量带文件路径或模块名。
- 控制在实现可直接消费的粒度。

#### Markdown / HTML artifact source boundary

当任务使用 `md-html` 生成或导入 Markdown/HTML 产物时，PLAN 应把 source 和 artifact 分开写清：

- Markdown 默认是 source of truth；HTML 默认是 generated display artifact。
- Markdown -> HTML 用于发布、预览、视觉检查和交付；应能从同一 Markdown source 与模板/样式规则重复生成。
- HTML -> Markdown 用于导入、审阅和归档；不承诺像素级还原。
- 不要让 IMPLEMENT 在同一轮自由修改 Markdown 和 HTML 两份源；内容改动走 Markdown，视觉改动走模板/样式规则，然后重新生成 HTML。
- 复杂任务建议把 Markdown source、HTML artifact、模板/样式说明列入 `artifacts:`，并在 `Verification` 写预览、导入或 repeatability 检查。
- `spec.md` / `plan.md` 超过 160 行或含 8 个及以上 `##` 二级标题，且需要人工审阅/决策、Markdown 层次不够清晰时，默认生成同目录 paired reading HTML：`plan.review.html` / `spec.review.html`，单一审阅文件可用 `review.html`。
- paired reading HTML 使用固定模板或稳定生成规则，只增强阅读，不替代 `spec.md` / `plan.md`。
- Local HTML enhancement 只限局部卡片、对比区、流程区、信息网格；不输出完整页面，不把 HTML 放进代码块，不使用 `script`、`iframe` 或外部 JS。

正确示例：

```markdown
## Plan
- 更新 `scripts/advance-stage.ps1`，统一当前任务指针写法。
- 更新 `skills/obsidian-memory/scripts/check-shared-memory.ps1`，移除 `docs/<task-id>` fallback。
```

错误示例：

```markdown
## Plan
- 优化流程一致性。
- 修一些共享记忆问题。
```

### Verification 内容要求

- 写真实命令。
- 只列本轮需要执行的验证。

正确示例：

```markdown
## Verification
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-contracts.ps1`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-footprint.ps1`
```

## spec.md 契约

`spec.md` 只是 PLAN 的可选附件，不是独立 stage。

### 可选 frontmatter

`spec.md` 可在文件顶部加入 opt-in frontmatter：

```yaml
---
front_keywords: [shared-memory, long-session, recovery]
---
```

规则：

- 仅在跨任务关键词检索或长会话恢复需要快速命中时使用
- 单任务、无跨任务复用价值时不写
- 必须使用 inline-array 语法，keyword 优先 kebab-case
- 单个 `spec.md` 最多写 5 个 keyword
- validator 当前不读取该 frontmatter；不写也完全合法

推荐结构：

```markdown
---
front_keywords: [shared-memory, long-session, recovery]
---
# <Task Title> Spec

## Gap
- 当前输入还缺什么。

## Constraint
- 本轮必须遵守的边界和兼容性约束。

## Verification Delta
- TEST 需要额外补哪些验证。
```

规则：

- 只补缺口，不复制 `plan.md` 已经明确的内容。
- 不创建额外状态文件，不写 stage。

## Append-Only Run 契约

### Run 标题格式

所有 append-only run 都使用：

```markdown
### Run <N> · YYYY-MM-DD HH:mm · runner: <Runner>
```

### Plan Review / Code Review

固定格式：

```markdown
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: pass | revise
- findings:
  - P1: ...
  - P2: ...
- next: 下一步动作；无则写 none
```

规则：

- `advance-stage.ps1` 只读取最新 run 的 `- verdict:`。
- 没有 findings 时写 `- findings: none`，不要写空 severity 标题。
- 只在真的有问题时使用 `P0/P1/P2/P3`。
- Phase 3 adapter 的 invocation trace 只能追加到现有 run 末尾，不能手写到 section 顶层
- PLAN_REVIEW / CODE_REVIEW 应把 artifact、affected_paths、实际 diff、Implementation Notes 和后续 Handoff 的 finish boundary 作为人工审查点；这是 append-only review 写作规则，不新增 stage，也不把 drift 升为 validator hard gate。

#### 对抗性审查纪律（CODE_REVIEW）

做完相对复杂的任务后，CODE_REVIEW 默认按对抗姿态审查，再把结论 append 进 `## Code Review` run；这是审查写法，不新增 stage 或 validator gate：

- **否定式对抗**：默认尝试证伪本次实现——主动找“它在哪里是错的 / 漏的 / 多做的”，对每条关键改动设法构造反例或失败输入，而不是确认它“看起来对”。
- **追问式对抗**：对存疑点连环追问根因——“为什么这样改 / 这个假设成立吗 / 边界、并发、失败路径如何 / 真的命中 PLAN 的根因吗”，一直问到能给出可验证答案或退回 IMPLEMENT。
- **墨菲定律**：默认“会出错的地方终将出错”，显式列出最坏失效路径（异常输入、空值、并发、回滚、依赖不可用、部分失败），核对 PLAN 的 Verification 是否覆盖；未覆盖的写成 finding。
- **判断否决证据门槛**：若 finding 推翻的是“该不该做 / 是否过度 / 是否应删除”这类设计判断，必须附一个可执行反例验证或代码 / 文档证据；给不出时只作为非阻断提示，不直接作为 `verdict: revise` 的唯一理由。
- **Debono 价值保留**：`verdict: revise` 后，在 `next` 或 finding 中保留仍成立的约束、价值或适用条件；不要把可复用的洞察随被否方案一起丢掉。

命中问题用现有 `findings`（`P0/P1/P2/P3`）退回，`verdict: revise`；不引入新的硬校验。

可选多 Agent 升级：复杂或高风险任务可显式 escalate 到多 agent 对抗审查——leader 在 `$env:AITEAMCODE_TEAM_MODE='1'` 下走 `skills/workflow-team`（或宿主提供的等效多 agent 能力），让独立 agent 分别承担否定式与追问式角色；Codex-only 默认单 agent 也必须完成上面三条纪律。结论仍 append 回同一个 `## Code Review` run，不另开真相源。

### Implementation Notes

推荐格式：

```markdown
### Run 1 · 2026-04-09 11:00 · runner: Codex
- changed: 更新了哪些文件或行为
- tests: 跑了哪些验证；无则写 none
- risks: 本轮残留风险；无则写 none
- next: 交给 CODE_REVIEW 关注什么；无则写 none
```

规则：

- 回修后必须追加新 run，不能复用旧 run 充当“新证据”。
- `changed` 写结果，不写空话。
- `IMPLEMENT` 若是接 `CODE_REVIEW revise` 回来，最新 run 必须比那条 review 更晚。

#### Implementation reflection checks

IMPLEMENT 使用现有 `- risks:` / `- next:` 记录命中的反射风险，不新增 section、字段、stage 或独立 checklist。未命中时不需要逐项写“无”。

IMPLEMENT 先执行 Minimal Safe Change ladder，再做实现。它要求最小正确 diff，但不得削弱 trust-boundary validation、security、data-loss protection、accessibility、error handling、root-cause fix 或 required verification。

只检查 5 类窄范围信号：

- oversized-file stuffing: 继续往已过大的文件塞逻辑
- 计划外抽象: 新增 PLAN 没声明的分支、层级、接口或抽象
- 邻近顺手重构: 顺手改了当前验收范围外的邻近代码
- 未声明新概念: 引入 PLAN / spec 没有定义的新术语、状态或配置口径
- 症状补丁: 只压住表面现象，没有处理 PLAN 中要求验证的根因或约束

规则：

- 命中但仍在 PLAN 内时，在 `- risks:` 或 `- next:` 写明理由、取舍和验证。
- 命中且超出 PLAN 时，停止实现并回 PLAN 或拆新任务。
- CODE_REVIEW 用现有 `findings` 退回，不引入 validator 硬校验。

## test.md 契约

推荐结构：

```markdown
# Test Report

## Summary
- 一句话结论摘要。

## Scope
- 本轮覆盖范围。

## Inputs Reviewed
- `docs/tasks/<task-id>/plan.md`
- `docs/tasks/<task-id>/spec.md`（如存在）

## Test Approach
- 实际执行的命令、手工检查或日志来源。

## Findings
- 关键发现；无则写 none。

## Risks / Gaps
- 残留风险或证据缺口；无则写 none。

## Conclusion
pass

## Handoff
- delivery: 交付摘要
- follow_up: 后续动作；无则写 none
- artifact: 声明的 artifact 是否已经存在或交付；没有则说明原因
- drift: 是否发现 artifact / diff drift；没有则写 none
- follow_up_decision: 是否需要把未完成事项拆成新任务；没有则写 none
- memory_spec_update: 是否需要 memory / spec update；没有则写 none
- current_state: 当前阶段与关键产物路径
- key_decisions:
  - decision: 跨会话必须保留的决策
    why: 决策原因
- next_actions:
  - 恢复后第一组动作
```

规则：

- `## Conclusion` 下第一行必须且只能是 `pass`、`fail`、`blocked`。
- `## Handoff` 必须存在。
- `delivery` 与 `follow_up` 是最低必填，validator 只校验这两条。
- 新任务的 finish boundary 应在 `## Handoff` 记录 4 项判断：artifact 是否存在或已交付、是否存在 artifact / diff drift、follow-up 是否需要拆新任务、是否需要 memory / spec update。
- `current_state`、`key_decisions`、`next_actions` 为 opt-in 密度扩展，推荐长任务填写；不写不影响 validator。
- 旧格式 Handoff（只含 delivery/follow_up）继续通过校验；validator 仍只硬校验既有最低字段，不要求旧任务回填 finish boundary。
- 不要把 review 发现写成独立 `review.md`。

## SKILL.md 拆分守则

- 这是 Phase 7 的 lazy 守则，不是立即执行的拆分任务。
- 只有当某个 `skills/*/SKILL.md` 实际增长到约 `600` 行或以上时，才考虑拆分。
- 触发后目标形态应为：主 `SKILL.md` 控制在 `<= 200` 行，细分内容放到 `phases/<phase>.md`。
- 主 `SKILL.md` 顶部必须保留导航，明确“何时加载哪个 phase”。
- 拆分前后 `git diff --stat` 应接近纯位移；不要借拆分机会重写内容或顺手改语义。
- 当前仓库现场没有任何 `SKILL.md` 达到该阈值，因此不要预先创建 `skills/*/phases/` 目录，也不要新建独立 `docs/工作流/skill-phase-loading.md`。

## FAQ

### 为什么我的 `tool_profile: harness-default-claude` 没有影响下一 stage

因为 `tool_profile` 只记录“当前 stage 已分配到哪个 profile”。下一 stage 的解析顺序是显式 `-Tool` → 显式 `-Profile` → workflow descriptor `default_profile`。如果当前 stage 没传新参数，而目标 stage 在 `agent-configs/workflows/harness-lite.yaml` 里有 `default_profile`，就会走 `workflow-default`，而不是复用旧 frontmatter 的 `tool_profile/model`。

## 严重级别

推荐统一使用：

- `P0`: 阻塞继续推进
- `P1`: 高优先级缺陷或回归
- `P2`: 重要但不阻塞的偏差
- `P3`: 次要问题或文档修正

规则：

- 一个 finding 只标一个级别。
- 级别只用于真实 finding，不用于空标题占位。

## 自检清单

- [ ] 路径全部位于 `docs/tasks/<task-id>/`
- [ ] `plan.md` frontmatter 只有 4 个基础字段，或再加合法的 `tool_profile` / `model`
- [ ] `tool` 与当前 `stage` 组合合法
- [ ] `User Confirmation` 使用机器可读 `status`
- [ ] `clarification_ledger` 没有替代 Clarification 最低字段：`验收标准`、`非目标`、`受影响目录 / 模块`、`回滚策略或兼容性约束`、`ui:`
- [ ] 触发 Clarification 协议时，`clarification_ledger` 无 `decision: pending`，且非 `impact: none` 决策已落到 Plan / Verification / Risks
- [ ] append-only run 没有改写旧历史
- [ ] review run 含 `verdict`
- [ ] test.md 含 `Conclusion` 和 `Handoff`
- [ ] 验证命令可直接执行
