---
task_id: codestable-borrowing-roadmap
stage: PLAN
tool: codex
updated: 2026-04-30
---
# CodeStable Borrowing Roadmap

## Clarification
- 验收标准: 产出一份可执行路线图，只覆盖 `work_type` 路由、bug / refactor 专用模板、implementation reflection checks 三项，并说明优先级、surface、前置约束、收益验证和明确不做项。
- 非目标: 不引入 `codestable/` 或第二套真相源；不新增大规模 skill surface；不调整 lite workflow 阶段拓扑；不把 YAML checklist/status 作为推进依据；本任务不改代码。
- 受影响目录: `docs/tasks/codestable-borrowing-roadmap/plan.md`；未来若执行路线图，候选 surface 限于 `skills/plan/SKILL.md`、`skills/implement/SKILL.md`、`skills/review/SKILL.md`、`skills/test/SKILL.md`、`skills/orchestrator/references/lite-writing-guide.md`、`scripts/validate-lite-artifacts.ps1`、`tests/verify-lite-artifact-validator.ps1`。
- 回滚策略: 本任务只新增文档，回滚时删除本文件即可；未来执行时每项应独立提交，validator 或 fixture 出现回归时回退对应 skill/validator 小改。
- ui: not-applicable

## User Confirmation
- status: draft

## Change Contract
- change_type: task
- affected_paths:
  - docs/tasks/codestable-borrowing-roadmap/plan.md

## Plan
- read_first: [docs/tasks/codestable-workflow-benchmark/comparison.md, skills/plan/SKILL.md, skills/implement/SKILL.md, skills/review/SKILL.md, skills/test/SKILL.md, skills/orchestrator/references/lite-writing-guide.md, scripts/validate-lite-artifacts.ps1]
- convergence:
  - `Select-String -Path docs/tasks/codestable-borrowing-roadmap/plan.md -Pattern 'work_type|bug / refactor|implementation reflection checks'`
  - `Select-String -Path docs/tasks/codestable-borrowing-roadmap/plan.md -Pattern '不引入|第二套真相源|大规模 skill surface|本任务不改代码'`
  - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/validate-lite-artifacts.ps1 -TaskId codestable-borrowing-roadmap`
- artifacts: [docs/tasks/codestable-borrowing-roadmap/plan.md]
- 先做这三项，因为它们来自对照评估里的“可直接借鉴”集合，主要落在现有 skill 写作纪律和可选 validator advisory，不需要新目录、新阶段或新运行时。
- 实施顺序固定为 P1 `work_type` 路由 -> P2 bug / refactor 专用模板 -> P3 implementation reflection checks。
- 执行方式采用小步提交：先文档纪律，经过 fixture 或真实任务验证后，再决定是否把其中稳定规则升为 advisory 校验。

### 为什么先做这三项

| 项 | 先做理由 | 对当前底线的影响 |
|---|---|---|
| `work_type` 路由 | 它是后两项的分诊信号，能让 PLAN_REVIEW、IMPLEMENT、TEST 按任务类型聚焦，不需要新增 stage。 | 继续以 `docs/tasks/<task-id>/plan.md` 为阶段真相源，`work_type` 只能是计划字段或文档纪律。 |
| bug / refactor 专用模板 | bug 和 refactor 是 generic plan 最容易漏证据的类型，补模板能直接提高复现、根因、行为等价验证质量。 | 只增强现有 Clarification / Plan / Verification / test 写法，不创建 issue/refactor 并行流程。 |
| implementation reflection checks | 直接压缩 AI 常见 scope creep：顺手重构、补丁分支、往大文件继续堆逻辑、引入计划外概念。 | 只进入 `implement` 和 `review` 审查纪律，不改变推进脚本。 |

### P1 - `work_type` 路由

| 维度 | 路线 |
|---|---|
| 目标 | 在 PLAN 阶段显式标注任务类型，推荐枚举为 `feature | bug | refactor | explore | doc | maintenance`，用于选择后续检查重点。 |
| 范围 | 在 plan.md 的 `## Clarification` 体内加一行 `- work_type: <enum>`；改 plan/review skill 写法与 orchestrator lite-writing-guide 示例；P2/P3 通过该字段做条件化分流。 |
| 非目标 | 不写进 frontmatter；不替代 `Change Contract.change_type`；不阻断旧任务通过 validator；不在 advance-stage 路径上消费此字段。 |
| 受影响 surface | `skills/plan/SKILL.md`、`skills/review/SKILL.md`、`skills/orchestrator/references/lite-writing-guide.md`；可选 `scripts/validate-lite-artifacts.ps1` + `tests/verify-lite-artifact-validator.ps1`（仅规则稳定后做 advisory/opt-in 枚举校验）。 |
| 依赖与约束 | 必须先与 P2/P3 协商共用枚举值；validator 只作 advisory，不阻塞推进；旧任务无 `work_type` 不视为缺陷。 |
| 验证方式 | 用 2 个 fixture 或样例计划覆盖 `bug` 与 `refactor`，确认 PLAN_REVIEW 能按类型指出缺少复现、根因或行为等价验证的问题。 |
| 风险 | AI 可能把 explore/maintenance 误标成 feature，让 P2/P3 无效化；缓解方式是 PLAN_REVIEW 在 finding 中显式核对枚举与场景的吻合度。 |

### P2 - bug / refactor 专用模板

| 维度 | 路线 |
|---|---|
| 目标 | 为 `work_type: bug` 和 `work_type: refactor` 增加最小必填提示，减少 generic plan 漏项。 |
| 范围 | 在 plan/test/review skill 内插入 conditional 模板段落与 lite-writing-guide 例子；模板字段嵌入既有 `## Clarification` / `## Verification` 节，不新增独立文件。 |
| 非目标 | 不引入 `bug-report.md`、`refactor-design.md` 单独文件；不强制普通 feature 任务填写 bug/refactor 字段；不在 PLAN 之外新增 stage；不复刻 cs-issue-* 双阶段 analyze→fix 拆分。 |
| 受影响 surface | `skills/plan/SKILL.md`、`skills/test/SKILL.md`、`skills/review/SKILL.md`、`skills/orchestrator/references/lite-writing-guide.md`。 |
| bug 模板要点 | 复现步骤、期望行为、实际行为、影响范围、严重程度、根因定位动作、修复后验证动作。 |
| refactor 模板要点 | 行为不变声明、范围边界、受影响调用点、等价验证命令、回滚路径、禁止顺手功能变更。 |
| 依赖与约束 | 依赖 P1 已落地（`work_type` 枚举存在）；模板只对应 `work_type` 启用；review 只检查"是否足够指导实现与验证"，不要求 generic 任务填满。 |
| 验证方式 | 抽取最近或构造的 bug/refactor 任务各 1 个，比较套用模板前后是否能更早暴露缺少复现、根因或行为等价验证的缺口。 |
| 风险 | 模板字段易沦为形式（"复现步骤：见 issue"）；缓解方式是 PLAN_REVIEW 复核模板字段是否真的导出了对应 verification 命令，否则退回 PLAN。 |

### P3 - implementation reflection checks

| 维度 | 路线 |
|---|---|
| 目标 | 在 IMPLEMENT 和 CODE_REVIEW 阶段加入反射检查，阻止方案外扩张和低质量补丁堆叠。 |
| 范围 | 在 implement/review skill 写入反射条目；输出位置统一为 `Implementation Notes - risks:` 与 `Code Review - findings:` 既有节，不引入新章节、新字段、新阶段。 |
| 非目标 | 不引入"反射 stage"；不要求每个 IMPLEMENT 输出列出全部检查项；不阻断必要小修；不复刻 cs `shared-conventions.md §7` 七条全集，按 lite workflow 取核心 5 条。 |
| 受影响 surface | `skills/implement/SKILL.md`、`skills/review/SKILL.md`、`skills/orchestrator/references/lite-writing-guide.md`。 |
| 检查项 | 是否往已过大的文件继续塞逻辑；是否新增计划外分支或抽象；是否顺手重构邻近代码；是否引入未在 PLAN 中声明的新概念；是否用补丁覆盖症状而非修掉根因。 |
| 依赖与约束 | reflection check 不要求新增 frontmatter 字段；命中后必须在 `Implementation Notes` 写明决定（接受 / 退回 / 拆出新任务），CODE_REVIEW 据此与 plan diff 比对。 |
| 验证方式 | 在至少 2 个实现任务中检查 `Implementation Notes` 是否明确记录 scope 风险；CODE_REVIEW 若发现方案外改动，应能用现有 `P1/P2` finding 退回 IMPLEMENT。 |
| 风险 | 反射检查可能让 IMPLEMENT 文档变啰嗦或形式化（每次都写"无 scope drift"）；缓解方式是只在命中风险时记录条目，未命中可省略；CODE_REVIEW 抽样核对而非逐项打勾。 |

### 实施顺序和里程碑

| 顺序 | 内容 | 退出条件 |
|---|---|---|
| 1 | 落地 `work_type` 文档纪律。 | 新增样例能说明 `work_type` 如何影响 PLAN_REVIEW；现有 validator 通过。 |
| 2 | 落地 bug / refactor 条件化模板。 | bug/refactor 样例计划包含复现、根因、行为等价验证等关键字段；普通任务模板不变重。 |
| 3 | 落地 implementation reflection checks。 | IMPLEMENT 与 CODE_REVIEW 文档明确 scope drift 检查；样例 review 能据此形成 finding。 |
| 4 | 评估是否做 advisory 校验。 | 只有在前三步通过真实任务验证后，才考虑增加非阻塞 warning 和 fixture。 |

### 明确不做

| 不做项 | 理由 |
|---|---|
| 不引入 `codestable/` 文件树 | 会和 `.assistant`、`docs/tasks/<task-id>/` 形成并行入口。 |
| 不新增第二套真相源 | 当前底线是 `plan.md` frontmatter 和 `.assistant` 共享记忆分层，路线图不改变这一点。 |
| 不扩成大规模 skill surface | 只吸收到现有 `plan/implement/review/test` skill，不复制 `cs-*` skill 族。 |
| 不绕过 PLAN_REVIEW / CODE_REVIEW / TEST | CodeStable fastforward 类机制不适合当前 lite workflow。 |
| 不用 YAML checklist/status 推进阶段 | 阶段推进仍只由 `advance-stage.ps1` 读取合法 artifact。 |
| 不自动改 AGENTS.md | 若未来需要长期项目约束，应先走用户确认和现有共享记忆协议。 |

## Verification
- `Select-String -Path docs/tasks/codestable-borrowing-roadmap/plan.md -Pattern 'work_type|bug / refactor|implementation reflection checks'`
- `Select-String -Path docs/tasks/codestable-borrowing-roadmap/plan.md -Pattern '不引入|第二套真相源|大规模 skill surface|本任务不改代码'`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/validate-lite-artifacts.ps1 -TaskId codestable-borrowing-roadmap`

## Risks
- `work_type` 可能变成装饰字段；缓解方式是让 PLAN_REVIEW、bug/refactor 模板和 TEST 写法都消费它，而不是只在 Clarification 里出现。
- 模板可能让小任务变重；缓解方式是条件化启用，只对 `bug` 和 `refactor` 要求额外字段，普通任务保持当前 lite 骨架。
- validator 若过早强制新字段会造成旧任务回归；缓解方式是先文档纪律，后续只做 opt-in advisory 或 warning，确认稳定后再讨论硬校验。

## Plan Review

## Implementation Notes

## Code Review
