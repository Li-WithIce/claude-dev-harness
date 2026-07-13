---
name: review
description: Use when the task is in PLAN_REVIEW or CODE_REVIEW and a new append-only review run must be written into `plan.md`.
---

# Review

这个 skill 同时服务 `PLAN_REVIEW` 和 `CODE_REVIEW`。它不再产出独立 `review.md`，而是把审查结论 append 到 `plan.md`。

## 何时使用

- `plan.md` frontmatter 的 `stage` 是 `PLAN_REVIEW` → 追加到 `## Plan Review`
- `plan.md` frontmatter 的 `stage` 是 `CODE_REVIEW` → 追加到 `## Code Review`

## Run 写法

append-only run 用 `### Run <N> · YYYY-MM-DD HH:mm · runner: X` 标题，必含 `- verdict: pass | revise`、`- findings:`、`- next:`；`advance-stage.ps1` 只解析最新 run，并联合校验唯一的 verdict、唯一 findings 形态及二者一致性。CODE_REVIEW 的最新 verdict 为 `pass` 时，该 run 分钟不得早于最新 Implementation run，不能复用返修前的旧 pass；旧 `revise` 仍返回 IMPLEMENT。完整格式（含 4-dim score 字段）见 [`../orchestrator/references/lite-writing-guide.md`](../orchestrator/references/lite-writing-guide.md) 的 Append-Only Run 契约。

## 审查重点

Use the PLAN_REVIEW and CODE_REVIEW disciplines from `docs/工作流/stage-discipline-matrix.md` when the task needs stage-discipline clarification or stage-behavior review:

- PLAN_REVIEW: check coherence, evidence, assumptions, risks, rollback, and verification.
- CODE_REVIEW: try to disprove the patch before accepting it.
- Explain the change simply enough to expose hidden assumptions.
- Preserve useful value when asking for revise.

### PLAN_REVIEW

- Clarification 是否完整
- 对 context provider 任务，按需读取 `references/adversarial-review-gate.md`、`references/code-intel-review.md`、`references/historical-recall-review.md`、`references/codedb-mcp-experimental.md`；provider finding 必须绑定真实证据。
- 若 provider 输出影响计划或审查判断，检查 run 内是否有 `provider_context` 或等价的 grounded evidence；该记录不得进入 frontmatter、不得影响 stage advancement、不得直接决定 verdict。
- 按阶段原则路由审查：PLAN_REVIEW 用 Hegel + Bayes，检查计划自洽、前提证据、未决项闭环；不要新增五转 stage 或第二 truth
- 若用户通过“需求澄清 / 拷问 / 头脑风暴 / 方案压力测试 / 边界确认”等同族触发词进入 PLAN，或 PLAN 的验收、非目标、影响面、回滚/兼容仍不确定，或实现路径仍不足以指导 IMPLEMENT，确认该协议只落在 `## Clarification` 和 `## User Confirmation`，没有新增 stage、frontmatter 字段、runtime 或第二 truth；仅当已写 ledger 且存在 `decision: pending` 时由 validator 阻断推进
- 对 Clarification 协议族或上述不确定任务，检查 `clarification_ledger` 没有替代 `## Clarification` 最低字段；缺少 `验收标准`、`非目标`、`受影响目录 / 模块`、`回滚策略或兼容性约束`、`ui:` 任一项时必须 `verdict: revise`
- 对 Clarification 协议族或上述不确定任务，若存在 `clarification_ledger`，检查每项是否有 `category / question / evidence / recommended_answer / decision / impact`；普通任务只记录 pending 或高影响项，不要求占位账本
- 对 Clarification 协议族或上述不确定任务，若存在 `decision: pending`、或 `## User Confirmation` 已 `- status: confirmed` 但仍有未决项，必须 `verdict: revise`
- 只有发布、权限/身份、数据迁移/破坏性恢复或不可逆外部效果等高风险任务，才检查完整八类问题树（目标/验收、用户与权限、流程与状态、数据与边界、集成依赖、失败与回滚、非目标、验证证据）
- 对 Clarification 协议族或上述不确定任务，检查 `decision: accepted | rejected` 是否有代码 / 文档 / artifact 证据或用户确认依据写入 `evidence`；agent 自行替用户作选择时必须 `verdict: revise`
- 对 Clarification 协议族或上述不确定任务，检查每个 `impact` 非 `none` 的 accepted/rejected 决策是否已反映到 `## Plan`、`## Verification` 或 `## Risks`；没有落地时必须 `verdict: revise`
- 对发布、权限/身份、迁移/破坏性恢复或不可逆外部效果，检查最新 review run 记录独立的 `reviewer_identity` 和 `evidence_digest`；普通任务不要求独立 reviewer 占位字段
- 对 Clarification 协议族或上述不确定任务，检查关键问题是否一次一个、可由代码库回答的问题是否已先查证、仍需用户决策的问题是否带 `recommended_answer` 和可执行的决策边界
- 若 `## Clarification` 含 `work_type:`，核对它是否只作为 PLAN 语义路由使用，且与验收标准、非目标、受影响路径和验证命令一致，没有替代 `Change Contract.change_type`、没有写入 frontmatter
- 若 `work_type: bug`，检查 PLAN 是否说明复现步骤、期望/实际行为、影响范围/严重程度、根因定位动作和修复验证动作；不得退化为“见 issue”这类不可执行占位
- 若 `work_type: refactor`，检查 PLAN 是否说明行为不变约束、重构边界、受影响调用点、等价验证和回滚/兼容路径；不得夹带功能变更；声明型字段必须有同任务内可执行的 `equivalence_check` 或 verification 兜底
- 确认 bug/refactor 模板仍嵌在现有 `plan.md` / `test.md` 结构内，没有新增 issue/analyze/fix stage 或独立真相源文件
- User Confirmation 是否已经 `confirmed`
- 计划粒度是否足够指导实现和验证，风险和验证命令是否可执行
- `Plan.artifacts` 描述交付产物、`Change Contract.affected_paths` 描述变更面；二者与非目标、verification 自洽，未把 artifact 声明误当成 hard gate 或第二 truth
- 按 `read_first:` 抽查 IMPLEMENT 是否真读了，按 `convergence:` 抽查每条 criterion 是否可执行

### CODE_REVIEW

- 按阶段原则路由审查：CODE_REVIEW 用 Feynman 反自欺，TEST 交给 Bayes 收证据，`revise` 后用 Debono 保留仍成立的约束、价值或适用条件
- 先用 `references/overengineering-checklist.md` 检查过度抽象，再检查 underengineering：少写不能跳过 validation、security、data-loss protection、accessibility、error handling、root-cause fix 或 required verification。
- 实现是否满足计划，是否有明显漏做、做错、多做
- 最新 `Implementation Notes` 是否和代码一致
- 实际 diff 是否落在 `Change Contract.affected_paths` 可解释范围内，声明的 `Plan.artifacts` 是否已创建或在 `Implementation Notes` 中解释未交付原因
- 是否存在 artifact/diff drift（改了未声明路径、声明产物缺失、产物与变更面角色混淆）；命中时用现有 finding 退回或要求 TEST 明确记录
- 若 provider 输出影响 CODE_REVIEW，确认 `provider_context` 已落到当前文件、命令、diff 或测试输出；不能把 provider claims 当作 verdict 本身。
- 抽查实现是否命中 reflection 风险：过大文件继续塞逻辑、计划外抽象、邻近顺手重构、未声明新概念、症状补丁替代根因修复；命中且最新 `Implementation Notes` 未在 `- risks:` / `- next:` 说明理由取舍时，用现有 P1/P2 finding 退回 IMPLEMENT
- 若 `work_type: bug`，确认实现证据对应复现、根因定位和修复验证，覆盖影响面回归
- 若 `work_type: refactor`，确认没有计划外功能行为变化，等价验证覆盖 PLAN 声明的调用点或依赖面
- 确认后续 TEST/Handoff 能覆盖 artifact、drift、follow-up 和 memory/spec update 四项 finish boundary 判断
- 是否还需要回 IMPLEMENT 补证据或补实现

### 对抗性审查纪律（复杂任务默认开启）

做完相对复杂的任务后，CODE_REVIEW 默认用对抗姿态审查，再 append 进 `## Code Review` run：

- **否定式对抗**：默认证伪实现，主动找错 / 漏 / 多做，对关键改动构造反例或失败输入，而不是确认它“看起来对”
- **追问式对抗**：对存疑点连环追问根因（为什么这么改 / 假设成立吗 / 边界、并发、失败路径如何 / 是否命中 PLAN 根因），问到可验证或退回 IMPLEMENT
- **墨菲定律**：默认会出错的终将出错，显式列最坏失效路径（异常输入、空值、并发、回滚、依赖不可用、部分失败），核对 Verification 是否覆盖，未覆盖写成 finding
- **判断否决证据门槛**：推翻“该不该做 / 是否过度 / 是否应删除”这类设计判断时，必须给可执行反例验证或代码 / 文档证据；给不出时只作为非阻断提示，不直接作为 `verdict: revise` 的唯一理由
- **Debono 价值保留**：`verdict: revise` 后，在 `next` 或 finding 中保留仍成立的约束、价值或适用条件，避免过度批判

命中用现有 `findings` + `verdict: revise` 退回，不加硬校验。复杂 / 高风险任务可显式升级到多 agent 对抗审查（`$env:AITEAMCODE_TEAM_MODE='1'` 走 `workflow-team`，或宿主提供的等效多 agent 能力），由独立 agent 分担否定式与追问式；Codex-only 单 agent 也要完成上述三条。详见 guide 的“对抗性审查纪律”。

## 判定规则

- `pass`：当前阶段可以推进
- `revise`：退回上一可写阶段（`PLAN_REVIEW -> PLAN`、`CODE_REVIEW -> IMPLEMENT`）

## 评分依据

- 4-dim score（`completeness` / `consistency` / `accuracy` / `depth`）的定义、阈值和示例统一看 [`../../docs/工作流/quality-rubric.md`](../../docs/工作流/quality-rubric.md)
- 只在 validator `-Quality` 模式下要求 score 与该 rubric 阈值一致；不要在本文件另发明一套标准

## 推进

写完最新 run 后执行 `.assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <PLAN_REVIEW|CODE_REVIEW>`（按当前 frontmatter stage 传值，自动调用 validator）。默认走 workflow descriptor 的 `harness-default-codex`；切换 backend 时显式传 `-Tool`（如用 profile 同步传 `-Profile` 和完整 `-Model`，profile 的 backend 必须等于 `-Tool`）。

## 不要做的事

- 不要写独立 `review.md`
- 不要修改旧 run
- 不要省略 `verdict`

## Reference

- 写作规范（单一真相源）: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
