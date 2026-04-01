# Skills 体系融合 实施计划

> 关联 Spec：`docs/skill-consolidation/spec.md`（v5，已确认）
> 关联参考：`docs/skill-consolidation/skills-core-refactor.md`、`docs/skill-consolidation/review.md`
> 创建日期：2026-03-14
> 状态：已确认

## 1. 技术方案概述

本次改造将分散的 11 个开发流程 skill 的精华融入 7 个核心 skill（using-superpowers、orchestrator、spec、plan、implement、review、test），形成以 `using-superpowers`（入口纪律控制器）+ `orchestrator`（开发任务唯一 governor）为主导、`spec → plan → implement → review → test` 为流程骨干的统一开发工作流体系。

改造采用 5 阶段推进策略：先改写核心 skill 正文与 references → 再退役旧 skill → 再给 specialist skill 添加二级能力声明 → 再镜像到 `.codex` → 最后做路由与契约验收。所有改动以 `.claude/skills` 为唯一主稿源，完成后一次性镜像到 `.codex/skills`。

核心 SKILL.md 正文保持精炼，详细规则下沉到 `references/` 子目录，以控制 token 消耗。

## 2. 技术决策

### 2.1 方案选型

| 决策 | 选择 | 理由 |
|------|------|------|
| 改造顺序 | 先 orchestrator → using-superpowers → 五阶段 skill | orchestrator 是契约源头，其他 skill 的模板增强依赖它的 artifact contract |
| 正文 vs references 拆分 | 主文保留规则条目，详细协议/模板放 references/ | 控制 SKILL.md token 量，参考 orchestrator 现有做法 |
| 退役方式 | 硬退役：收窄 frontmatter + 正文改重定向 | 保留目录避免断链，降低触发概率 |
| 镜像时机 | 全部改造完成后一次性镜像 | 避免中间状态不一致 |
| P1-1 处理 | review 中关于 `requesting-code-review` 来源错误：改为"吸收代码审查 subagent 模板能力"，不再点名该 skill | review.md P1-1 建议 |
| P1-2 处理 | codex 和 gemini-designer-main 在 `.codex` 中作为镜像占位，运行时继续依赖 `.claude` 路径，列为兼容性例外 | review.md P1-2 建议的方案二 |

### 2.2 外部依赖

无新增外部依赖。主要改动为 `.claude/skills` 和 `.codex/skills` 目录下的 Markdown 文件；镜像阶段会同步涉及 skill 的完整目录（SKILL.md 及该 skill 已存在的支持资产，如 `references/`、`reference/`、`scripts/`、`examples/` 等）。

### 2.3 内部依赖

- orchestrator 的 `references/artifact-contracts.md` 是 spec/plan/review/test 模板增强的契约源
- orchestrator 的 `references/model-invocation.md` 是 runner 策略的权威描述
- orchestrator 的 `references/gates.md` 是 P0/P1/P2 门控规则的权威描述

## 3. 任务拆解

### 3.1 Phase 1：核心 skill 改写（主导层）

- [x] **TODO-P1-1: 改写 orchestrator SKILL.md 正文**
  - **描述**：在 orchestrator 正文中：(1) 明确 orchestrator 是"开发任务默认入口后的唯一 governor"；(2) 吸收 `dispatching-parallel-agents` 的并行分发规则（plan 中 2+ 无依赖 TODO 时建议并行）；(3) 吸收 `executing-plans` 的批量执行模式（每批 3 个 TODO，批间设检查点）；(4) 吸收 `finishing-a-development-branch` 的 DONE 阶段收尾协议（4 选项：merge/PR/保留/丢弃，测试全绿才能收尾）；(5) 明确与 using-superpowers 的关系；(6) 将文档中的硬编码路径改为"当前 skill 所在目录优先"策略
  - **涉及文件**：`%USERPROFILE%\.claude\skills\orchestrator\SKILL.md`
  - **依赖**：无
  - **验收标准**：orchestrator 正文包含并行分发、批量执行、DONE 收尾、与 using-superpowers 关系的规则条目；无硬编码单边路径

- [x] **TODO-P1-2: 更新 orchestrator references/model-invocation.md**
  - **描述**：将 runner 策略改为 DEV 阶段默认 Claude `/implement` 执行（用户显式要求时委派 Codex）；TEST 阶段 Gemini 主测（fallback：Gemini → Claude `/test` → Codex）。确保与正文一致
  - **涉及文件**：`%USERPROFILE%\.claude\skills\orchestrator\references\model-invocation.md`
  - **依赖**：TODO-P1-1
  - **验收标准**：model-invocation.md 中 DEV 和 TEST 的 runner 描述与 SKILL.md 正文一致；DEV=Claude-first，TEST=Gemini-first

- [x] **TODO-P1-3: 更新 orchestrator references/artifact-contracts.md**
  - **描述**：确认所有 artifact contract 包含 `task_id`、`task_name` 字段要求；确认 `implementation-notes.md` 作为 DEV→REVIEW 必要交付物的契约；确认 review.md 和 test.md 的结论字段与 gate 直接对应
  - **涉及文件**：`%USERPROFILE%\.claude\skills\orchestrator\references\artifact-contracts.md`
  - **依赖**：TODO-P1-1
  - **验收标准**：artifact-contracts.md 中 spec/plan/review/test/implementation-notes 均有 task_id 要求；review 结论映射 REVIEW gate；test 结论映射 TEST gate

- [x] **TODO-P1-4: 更新 orchestrator references/gates.md**
  - **描述**：确认 gate 条件与更新后的 runner 策略、artifact contract 对齐。确认 P0 阻塞 TEST、P1/P2 可进入 TEST 但记录风险
  - **涉及文件**：`%USERPROFILE%\.claude\skills\orchestrator\references\gates.md`
  - **依赖**：TODO-P1-3
  - **验收标准**：gates.md 中 REVIEW→TEST 转换条件与 P0/P1/P2 规则一致

- [x] **TODO-P1-5: 更新 orchestrator references/runbook.md**
  - **描述**：确认 runbook 中所有操作步骤与更新后的 runner 策略、artifact contract、gate 规则一致。去除任何硬编码的单边路径
  - **涉及文件**：`%USERPROFILE%\.claude\skills\orchestrator\references\runbook.md`
  - **依赖**：TODO-P1-2, TODO-P1-4
  - **验收标准**：runbook 操作步骤与 model-invocation.md、gates.md 无矛盾

- [x] **TODO-P1-6: 更新 orchestrator references/state-templates.md**
  - **描述**：确认 state 模板（current-flow.md、stage-history.md、handoff.md、decision-needed.md）与更新后的 runner 策略一致。handoff 模板需支持记录 DEV 阶段 runner 和 TEST 阶段 runner
  - **涉及文件**：`%USERPROFILE%\.claude\skills\orchestrator\references\state-templates.md`
  - **依赖**：TODO-P1-2
  - **验收标准**：state 模板中 runner 字段支持 Claude/Codex/Gemini

- [x] **TODO-P1-7: 改写 using-superpowers SKILL.md**
  - **描述**：(1) 新增流程感知能力：检测 `.assistant/orchestration/current-flow.md` 是否存在，存在则感知当前阶段并推荐对应 skill；不存在则回退到纯路由模式。(2) 新增开发任务优先路由：开发意图（开发、修 bug、重构、代码 review、测试验证）优先导向 orchestrator。(3) 明确调用层级：开发主流程 skill 高于 specialist skill；specialist skill 仅在具体 stage 内作为二级能力调用。(4) 新增 4 条 red flags。(5) 保留中文输出、代码标识符英文规则。(6) 保留已有的 skill 路由守门职责
  - **涉及文件**：`%USERPROFILE%\.claude\skills\using-superpowers\SKILL.md`
  - **依赖**：TODO-P1-1（需要了解 orchestrator 的完整阶段定义）
  - **验收标准**：using-superpowers 包含流程感知逻辑、开发任务优先路由、调用层级、4 条 red flags；不改变非开发任务的路由行为

### 3.2 Phase 1：核心 skill 改写（阶段层）

- [x] **TODO-P1-8: 改写 spec SKILL.md**
  - **描述**：(1) 模板增强：头部增加 `task_id`、`task_name` 字段。(2) 吸收 `brainstorming` 的渐进式澄清：澄清阶段采用一次一问，每个问题提供 2-3 选项并带推荐项。(3) 吸收 `brainstorming` 的 YAGNI 裁剪：撰写 In Scope 时主动检查过度设计。(4) 吸收 `doc-coauthoring` 的分段验证：spec 撰写时分段（每段 200-300 字）输出给用户确认。(5) 保持边界约束与确认动作的严格性
  - **涉及文件**：`%USERPROFILE%\.claude\skills\spec\SKILL.md`
  - **依赖**：TODO-P1-3（artifact contract 对齐）
  - **验收标准**：spec 模板包含 task_id/task_name；正文包含渐进式澄清、YAGNI 裁剪、分段验证的规则条目；核心原则（不猜测、不模糊、不写代码）不变

- [x] **TODO-P1-9: 改写 plan SKILL.md**
  - **描述**：(1) 模板增强：头部增加 `task_id` 字段。(2) 吸收 `writing-plans` 的精确文件路径要求：每个 TODO 必须列出精确文件路径和验证命令。(3) 吸收 `writing-plans` 的 TDD 结构提示：每个 TODO 验收标准中标注"先写测试再写实现"提醒。(4) 吸收 `writing-plans` 的依赖可视化：依赖关系章节必须标明可并行 TODO。(5) 新增 handoff 视角：每个 TODO 标注可委派 Codex 的输入/输出/watchouts。(6) TODO 粒度保持 1-4 小时级
  - **涉及文件**：`%USERPROFILE%\.claude\skills\plan\SKILL.md`
  - **依赖**：TODO-P1-3（artifact contract 对齐）
  - **验收标准**：plan 模板包含 task_id；TODO 模板包含文件路径、验证命令、TDD 提醒、handoff 视角；依赖章节要求标注可并行项

- [x] **TODO-P1-10: 改写 implement SKILL.md 并创建 references/**
  - **描述**：(1) 吸收 `test-driven-development` 的 RED-GREEN-REFACTOR 铁律：每个 TODO 先写失败测试→看到失败→写最小实现→看到通过→重构；跳过测试需用户显式许可。(2) 吸收 `systematic-debugging` 的 4 阶段根因分析：修复前必须完成调查→模式分析→单假设测试→实施；连续 3 次失败后必须停止。(3) 吸收 `verification-before-completion` 的完成验证：每完成一个 TODO，必须运行验证命令并检查输出。(4) 吸收 `receiving-code-review` 的反馈处理：先验证问题是否成立再修改，禁止表演性认同。(5) 新增固定交付物 `implementation-notes.md`（改了什么/没改什么/风险点/reviewer watchouts）。(6) 为避免正文过长，将 TDD 铁律详细步骤和调试流程放入 `references/` 子目录
  - **涉及文件**：
    - `%USERPROFILE%\.claude\skills\implement\SKILL.md`（改写）
    - `%USERPROFILE%\.claude\skills\implement\references\tdd-protocol.md`（新建）
    - `%USERPROFILE%\.claude\skills\implement\references\debugging-protocol.md`（新建）
  - **依赖**：TODO-P1-3（artifact contract 对齐）
  - **验收标准**：implement 正文包含 TDD 铁律概述、调试纪律概述、完成验证、反馈处理、implementation-notes.md 输出要求；references/ 包含 TDD 和调试的详细流程；正文 token 量不超过原 SKILL.md 的 2 倍

- [x] **TODO-P1-11: 改写 review SKILL.md**
  - **描述**：(1) 模板增强：review.md 头部增加 `task_id`、`task_name`，输出路径为 `docs/<task-id>/review.md`，P0/P1/P2 结论与 orchestrator REVIEW gate 直接对应。(2) 新增第 6 维度：Spec 合规检查（逐条验证 spec AC 是否被实现，必须对照代码验证）。(3) 新增输入要求：review 必须同时对照 spec.md、plan.md、implementation-notes.md 和当前 diff。(4) 增加"是否少做、多做、做错"三维核查。(5) 吸收代码审查 subagent 模板能力。(6) 吸收 verification-before-completion 的证据要求：结论必须基于实际运行证据。(7) 明确 P0 唯一阻塞 TEST；P1/P2 进入 watchouts 和 TEST handoff
  - **涉及文件**：`%USERPROFILE%\.claude\skills\review\SKILL.md`
  - **依赖**：TODO-P1-3（artifact contract 对齐）
  - **验收标准**：review 模板包含 task_id/task_name/输出路径；正文包含 6 维度审查框架（含 Spec 合规）、三维核查、证据要求；review.md 输出可被 orchestrator gate 直接消费

- [x] **TODO-P1-12: 改写 test SKILL.md**
  - **描述**：(1) 模板增强：test.md 头部增加 `task_id`、`task_name`，输出路径为 `docs/<task-id>/test.md`，结论字段（pass/fail/blocked）与 orchestrator TEST gate 对应。(2) 吸收 verification-before-completion 的 5 步门控：IDENTIFY→RUN→READ→VERIFY→CLAIM。(3) 强化证据先于结论：没有证据时优先 `blocked`。(4) 明确 TEST 阶段默认 Gemini 主测；fallback 顺序：Gemini → Claude `/test` → Codex。(5) 明确 specialist test skill（如 webapp-testing）只作为 test stage 内二级调用。(6) 吸收 webapp-testing 的侦察先于行动模式：涉及 UI 测试时先截图/DOM 检查
  - **涉及文件**：`%USERPROFILE%\.claude\skills\test\SKILL.md`
  - **依赖**：TODO-P1-3（artifact contract 对齐）
  - **验收标准**：test 模板包含 task_id/task_name/输出路径；正文包含 5 步门控、证据先于结论、Gemini 主测策略、specialist 二级调用声明；test.md 结论可被 orchestrator gate 直接消费

### 3.3 Phase 2：硬退役 11 个旧 skill

- [x] **TODO-P2-1: 硬退役 brainstorming**
  - **描述**：(1) 收窄 frontmatter description 为"[已退役] 创意探索功能已融入 /spec 的渐进式澄清流程"。(2) 正文替换为重定向说明：指向 spec 的渐进式澄清和 YAGNI 裁剪章节
  - **涉及文件**：`%USERPROFILE%\.claude\skills\brainstorming\SKILL.md`
  - **依赖**：TODO-P1-8（spec 改写完成）
  - **验收标准**：frontmatter description 窄触发；正文为重定向说明

- [x] **TODO-P2-2: 硬退役 writing-plans**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 plan 的精确文件路径要求和依赖可视化章节
  - **涉及文件**：`%USERPROFILE%\.claude\skills\writing-plans\SKILL.md`
  - **依赖**：TODO-P1-9（plan 改写完成）
  - **验收标准**：同 TODO-P2-1

- [x] **TODO-P2-3: 硬退役 executing-plans**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 orchestrator 的批量执行模式和 implement 的 TDD 铁律
  - **涉及文件**：`%USERPROFILE%\.claude\skills\executing-plans\SKILL.md`
  - **依赖**：TODO-P1-1, TODO-P1-10
  - **验收标准**：同 TODO-P2-1

- [x] **TODO-P2-4: 硬退役 dispatching-parallel-agents**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 orchestrator 的并行分发规则
  - **涉及文件**：`%USERPROFILE%\.claude\skills\dispatching-parallel-agents\SKILL.md`
  - **依赖**：TODO-P1-1（orchestrator 改写完成）
  - **验收标准**：同 TODO-P2-1

- [x] **TODO-P2-5: 硬退役 finishing-a-development-branch**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 orchestrator 的 DONE 阶段收尾协议
  - **涉及文件**：`%USERPROFILE%\.claude\skills\finishing-a-development-branch\SKILL.md`
  - **依赖**：TODO-P1-1
  - **验收标准**：同 TODO-P2-1

- [x] **TODO-P2-6: 硬退役 test-driven-development**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 implement 的 TDD 铁律章节和 `references/tdd-protocol.md`
  - **涉及文件**：`%USERPROFILE%\.claude\skills\test-driven-development\SKILL.md`（注意：`testing-anti-patterns.md` 保留不动，作为参考资料）
  - **依赖**：TODO-P1-10
  - **验收标准**：SKILL.md frontmatter 窄触发、正文重定向；`testing-anti-patterns.md` 保留

- [x] **TODO-P2-7: 硬退役 systematic-debugging**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 implement 的根因分析流程章节和 `references/debugging-protocol.md`
  - **涉及文件**：`%USERPROFILE%\.claude\skills\systematic-debugging\SKILL.md`（目录内其他参考文件保留不动）
  - **依赖**：TODO-P1-10
  - **验收标准**：SKILL.md frontmatter 窄触发、正文重定向；其他文件保留

- [x] **TODO-P2-8: 硬退役 verification-before-completion**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 implement 的完成验证章节和 test 的 5 步门控章节
  - **涉及文件**：`%USERPROFILE%\.claude\skills\verification-before-completion\SKILL.md`
  - **依赖**：TODO-P1-10, TODO-P1-12
  - **验收标准**：同 TODO-P2-1

- [x] **TODO-P2-9: 硬退役 receiving-code-review**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 implement 的反馈处理协议章节
  - **涉及文件**：`%USERPROFILE%\.claude\skills\receiving-code-review\SKILL.md`
  - **依赖**：TODO-P1-10
  - **验收标准**：同 TODO-P2-1

- [x] **TODO-P2-10: 硬退役 requesting-code-review**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 review 的代码审查 subagent 模板能力章节。注意：当前此 skill 的正文实际是 verification-before-completion 的副本，退役说明需如实指向 review skill
  - **涉及文件**：`%USERPROFILE%\.claude\skills\requesting-code-review\SKILL.md`（`code-reviewer.md` 保留不动）
  - **依赖**：TODO-P1-11
  - **验收标准**：SKILL.md frontmatter 窄触发、正文重定向到 review

- [x] **TODO-P2-11: 硬退役 subagent-driven-development**
  - **描述**：收窄 frontmatter + 正文改为重定向，指向 orchestrator（并行分发）和 review（Spec 合规检查）。目录内的 prompt 模板文件保留
  - **涉及文件**：`%USERPROFILE%\.claude\skills\subagent-driven-development\SKILL.md`（`code-quality-reviewer-prompt.md`、`implementer-prompt.md`、`spec-reviewer-prompt.md` 保留不动）
  - **依赖**：TODO-P1-1, TODO-P1-11
  - **验收标准**：SKILL.md frontmatter 窄触发、正文重定向；prompt 模板保留

### 3.4 Phase 2 补充：更新引用链

- [x] **TODO-P2-12: 审计并更新 writing-skills 中所有退役 skill 引用**
  - **描述**：对 `%USERPROFILE%\.claude\skills\writing-skills\` 目录下的所有文件做完整审计（包括 `SKILL.md` 及其支持资产如 `persuasion-principles.md` 等），检查所有对 11 个退役 skill 的引用（包括但不限于 `test-driven-development`、`systematic-debugging`、`verification-before-completion` 等），将每个引用更新为指向吸收了该能力的核心 skill 对应章节
  - **涉及文件**：
    - `%USERPROFILE%\.claude\skills\writing-skills\SKILL.md`
    - `%USERPROFILE%\.claude\skills\writing-skills\persuasion-principles.md`
    - 以及该目录下任何其他包含退役 skill 引用的文件
  - **依赖**：TODO-P2-1 ~ TODO-P2-11 全部完成（需要知道每个退役 skill 的重定向目标）
  - **验收标准**：writing-skills 目录下所有文件中不再包含任何指向 11 个退役 skill 的引用，所有引用已替换为对应的核心 skill 章节

### 3.5 Phase 3：specialist skill 二级能力声明

- [x] **TODO-P3-1: 给 frontend-design 添加二级能力声明**
  - **描述**：在 `frontend-design/SKILL.md` 正文开头添加一条规则："本 skill 是开发主流程中的二级能力，仅在 orchestrator 管理的 stage 内被调用。如任务属于标准开发活动，应先由 orchestrator 决定当前 stage，再在 stage 内调用本 skill。"
  - **涉及文件**：`%USERPROFILE%\.claude\skills\frontend-design\SKILL.md`
  - **依赖**：TODO-P1-7（using-superpowers 中已明确调用层级）
  - **验收标准**：SKILL.md 包含二级能力声明

- [x] **TODO-P3-2: 给 mcp-builder 添加二级能力声明**
  - **描述**：同 TODO-P3-1 的声明文本
  - **涉及文件**：`%USERPROFILE%\.claude\skills\mcp-builder\SKILL.md`
  - **依赖**：TODO-P1-7
  - **验收标准**：同 TODO-P3-1

- [x] **TODO-P3-3: 给 webapp-testing 添加二级能力声明**
  - **描述**：同 TODO-P3-1 的声明文本
  - **涉及文件**：`%USERPROFILE%\.claude\skills\webapp-testing\SKILL.md`
  - **依赖**：TODO-P1-7
  - **验收标准**：同 TODO-P3-1

- [x] **TODO-P3-4: 给 claude-api 添加二级能力声明**
  - **描述**：同 TODO-P3-1 的声明文本
  - **涉及文件**：`%USERPROFILE%\.claude\skills\claude-api\SKILL.md`
  - **依赖**：TODO-P1-7
  - **验收标准**：同 TODO-P3-1

### 3.6 Phase 4：镜像到 .codex/skills

- [x] **TODO-P4-1: 镜像 7 个核心 skill 到 .codex/skills**
  - **描述**：将 `.claude/skills` 下的 7 个核心 skill 目录的全部内容（SKILL.md + references/）同步到 `.codex/skills` 对应目录。具体目录：using-superpowers、orchestrator（新增）、spec、plan、implement（含新建的 references/）、review、test
  - **涉及文件**：
    - `%USERPROFILE%\.codex\skills\using-superpowers\SKILL.md`（覆盖）
    - `%USERPROFILE%\.codex\skills\orchestrator\`（新建目录 + SKILL.md + references/）
    - `%USERPROFILE%\.codex\skills\spec\SKILL.md`（覆盖）
    - `%USERPROFILE%\.codex\skills\plan\SKILL.md`（覆盖）
    - `%USERPROFILE%\.codex\skills\implement\SKILL.md`（覆盖）+ `references/`（新建）
    - `%USERPROFILE%\.codex\skills\review\SKILL.md`（覆盖）
    - `%USERPROFILE%\.codex\skills\test\SKILL.md`（覆盖）
  - **依赖**：TODO-P1-1 ~ TODO-P1-12 全部完成
  - **验收标准**：`.codex/skills` 中 7 个核心 skill 的 SKILL.md + references/ 与 `.claude/skills` 内容一致

- [x] **TODO-P4-2: 镜像 codex 和 gemini-designer-main 到 .codex/skills**
  - **描述**：将 `.claude/skills/codex` 和 `.claude/skills/gemini-designer-main` 目录整体复制到 `.codex/skills/` 下。这两个 skill 的 SKILL.md 不做内容修改，作为镜像占位，运行时继续依赖 `.claude` 路径（兼容性例外）
  - **涉及文件**：
    - `%USERPROFILE%\.codex\skills\codex\`（新建目录 + 全部内容）
    - `%USERPROFILE%\.codex\skills\gemini-designer-main\`（新建目录 + 全部内容）
  - **依赖**：无
  - **验收标准**：两个目录存在且内容与 `.claude` 侧一致

- [x] **TODO-P4-3: 镜像 11 个退役 skill 到 .codex/skills**
  - **描述**：将 11 个退役 skill 的已修改 SKILL.md 同步到 `.codex/skills` 对应目录（这些目录在 `.codex` 中已存在，仅需覆盖 SKILL.md）
  - **涉及文件**：`.codex/skills` 下的 brainstorming、writing-plans、executing-plans、dispatching-parallel-agents、finishing-a-development-branch、test-driven-development、systematic-debugging、verification-before-completion、receiving-code-review、requesting-code-review、subagent-driven-development 的 SKILL.md
  - **依赖**：TODO-P2-1 ~ TODO-P2-11 全部完成
  - **验收标准**：`.codex/skills` 中 11 个退役 skill 的 SKILL.md 与 `.claude/skills` 一致

- [x] **TODO-P4-4: 镜像 4 个 specialist skill 到 .codex/skills**
  - **描述**：将 4 个已添加二级能力声明的 specialist skill 的完整 skill 目录同步到 `.codex/skills` 对应目录，包括 SKILL.md 及该 skill 已存在的支持资产（如 `reference/`、`scripts/`、`examples/`）。具体来说：`frontend-design`（仅 SKILL.md）、`mcp-builder`（SKILL.md + `reference/` + `scripts/`）、`webapp-testing`（SKILL.md + `examples/` + `scripts/`）、`claude-api`（仅 SKILL.md）
  - **涉及文件**：
    - `.codex/skills/frontend-design/SKILL.md`（覆盖）
    - `.codex/skills/mcp-builder/SKILL.md`（覆盖）+ `reference/`、`scripts/`（同步）
    - `.codex/skills/webapp-testing/SKILL.md`（覆盖）+ `examples/`、`scripts/`（同步）
    - `.codex/skills/claude-api/SKILL.md`（覆盖）
  - **依赖**：TODO-P3-1 ~ TODO-P3-4 全部完成
  - **验收标准**：`.codex/skills` 中 4 个 specialist skill 的 SKILL.md 及其支持资产与 `.claude/skills` 一致

- [x] **TODO-P4-5: 镜像 writing-skills 到 .codex/skills**
  - **描述**：将 TODO-P2-12 中被修改的 `writing-skills` 目录下所有被改动的文件同步到 `.codex/skills/writing-skills/`，确保引用更新在双目录中一致。至少包括 `SKILL.md` 和 `persuasion-principles.md`
  - **涉及文件**：
    - `%USERPROFILE%\.codex\skills\writing-skills\SKILL.md`（覆盖）
    - `%USERPROFILE%\.codex\skills\writing-skills\persuasion-principles.md`（覆盖）
    - 以及 TODO-P2-12 中实际被修改的其他文件
  - **依赖**：TODO-P2-12 完成
  - **验收标准**：`.codex/skills/writing-skills/` 中所有被修改的文件与 `.claude/skills/writing-skills/` 内容一致

### 3.7 Phase 5：验收检查

- [x] **TODO-P5-1: 路由与契约验收**
  - **描述**：对照 spec AC-1 ~ AC-10 逐条验收：(1) AC-1 核心 skill 功能完整：检查 7 个核心 skill 包含原有功能 + 被吸收精华。(2) AC-2 artifact contract 对齐：检查 spec/plan/review/test 模板头部 task_id。(3) AC-3 被退役 skill 已降权：检查 11 个退役 skill 的 frontmatter 和正文。(4) AC-4 触发无冲突：模拟检查 6 个典型请求的路由结果。(5) AC-5 可选委派正常工作：检查 orchestrator 正文和 model-invocation.md 中用户指定 Codex 的委派路径是否完整。(6) AC-6 流程感知正常工作：检查 using-superpowers 中是否包含 current-flow.md 检测逻辑和阶段推荐规则。(7) AC-7 runner 契约一致：对比 orchestrator 正文与 5 个 references。(8) AC-8 双目录镜像一致：对比 `.claude` 与 `.codex` 核心 skill + 退役 skill + specialist skill + writing-skills。(9) AC-9 向后兼容：检查直接调用 `/spec`、`/plan`、`/implement`、`/review`、`/test` 时行为符合融合后定义，不报错。(10) AC-10 specialist skill 降级：检查 4 个 specialist skill 的二级能力声明
  - **涉及文件**：所有上述已修改的文件
  - **依赖**：TODO-P4-1 ~ TODO-P4-5 全部完成
  - **验收标准**：AC-1 ~ AC-10 全部通过；发现的问题记录到 `docs/skill-consolidation/implementation-notes.md`

## 4. 依赖关系与执行顺序

```text
Phase 1 主导层（可并行启动）:
  TODO-P1-1 (orchestrator 正文)
    → TODO-P1-2 (model-invocation)
    → TODO-P1-3 (artifact-contracts)
      → TODO-P1-4 (gates)
        → TODO-P1-5 (runbook) ← 也依赖 P1-2
    → TODO-P1-6 (state-templates) ← 也依赖 P1-2
    → TODO-P1-7 (using-superpowers) ← 依赖 P1-1

Phase 1 阶段层（P1-3 完成后可并行）:
  TODO-P1-3 →
    TODO-P1-8 (spec)       ‖
    TODO-P1-9 (plan)       ‖  可并行
    TODO-P1-10 (implement) ‖
    TODO-P1-11 (review)    ‖
    TODO-P1-12 (test)      ‖

Phase 2 退役（各自依赖对应的核心 skill 完成，退役之间可并行）:
  TODO-P1-8  → TODO-P2-1  (brainstorming)
  TODO-P1-9  → TODO-P2-2  (writing-plans)
  TODO-P1-1 + P1-10 → TODO-P2-3  (executing-plans)
  TODO-P1-1  → TODO-P2-4  (dispatching-parallel-agents)  ‖
  TODO-P1-1  → TODO-P2-5  (finishing-a-dev-branch)        ‖  可并行
  TODO-P1-10 → TODO-P2-6  (test-driven-development)       ‖
  TODO-P1-10 → TODO-P2-7  (systematic-debugging)          ‖
  TODO-P1-10 + P1-12 → TODO-P2-8  (verification-before-completion)
  TODO-P1-10 → TODO-P2-9  (receiving-code-review)
  TODO-P1-11 → TODO-P2-10 (requesting-code-review)
  TODO-P1-1 + P1-11 → TODO-P2-11 (subagent-driven-development)
  TODO-P2-6  → TODO-P2-12 (审计 writing-skills 全部退役引用) ← 也依赖 P2-1~P2-11

Phase 3 specialist（P1-7 完成后可全部并行）:
  TODO-P1-7 →
    TODO-P3-1 ‖ TODO-P3-2 ‖ TODO-P3-3 ‖ TODO-P3-4

Phase 4 镜像（各自依赖对应的前置 phase 完成）:
  Phase 1 全部 → TODO-P4-1 (核心 skill 镜像)
  无前置      → TODO-P4-2 (codex/gemini 镜像，可提前执行)
  Phase 2 全部 → TODO-P4-3 (退役 skill 镜像)
  Phase 3 全部 → TODO-P4-4 (specialist 镜像)
  TODO-P2-12   → TODO-P4-5 (writing-skills 镜像)

Phase 5 验收:
  Phase 4 全部 + TODO-P4-5 → TODO-P5-1
```

**最大并行度分析**：
- Phase 1 内部：P1-8/P1-9/P1-10/P1-11/P1-12 可 5 路并行
- Phase 2 内部：大部分退役 TODO 可并行
- Phase 3 内部：4 个 specialist 声明可并行
- Phase 4 内部：P4-2 可提前执行；P4-1/P4-3/P4-4 各自独立可并行
- 跨 phase：Phase 2 和 Phase 3 可并行（它们不互相依赖，仅各自依赖 Phase 1 的不同部分）

## 5. 测试标准

### 5.1 单元测试标准

由于本次改造的产出全部是 Markdown 文件，不涉及可执行代码，"单元测试"以内容检查方式进行：

| TODO | 验证方式 |
|------|---------|
| P1-1 ~ P1-7 | 检查 SKILL.md 正文：(1) 包含 spec 中要求的所有融合规则条目 (2) 无硬编码单边路径 (3) 保留原有核心原则 |
| P1-8 ~ P1-12 | 检查 SKILL.md 模板：(1) 包含 task_id 字段 (2) 包含 spec 中要求的所有融合内容 (3) 核心原则不变 |
| P2-1 ~ P2-11 | 检查退役 SKILL.md：(1) frontmatter description 已收窄且包含"[已退役]" (2) 正文为重定向说明 (3) 指向正确的核心 skill |
| P2-12 | 检查 writing-skills 中无任何指向 11 个退役 skill 的引用 |
| P3-1 ~ P3-4 | 检查 specialist SKILL.md 包含二级能力声明段落 |
| P4-1 ~ P4-5 | 对比 `.claude` 与 `.codex` 同名文件内容一致 |

### 5.2 集成 / 场景验证标准

**场景一：新功能开发全流程路由**
- 前置条件：skill 体系已完成融合
- 操作步骤：模拟用户发送"做一个新功能"
- 期望结果：using-superpowers 应路由到 orchestrator → orchestrator 应驱动 SPEC 阶段
- 验证方式：检查 using-superpowers 正文中开发任务优先路由逻辑是否覆盖此场景

**场景二：bug fix 路由**
- 前置条件：同上
- 操作步骤：模拟用户发送"修一个 bug"
- 期望结果：using-superpowers 路由到 orchestrator；不被 systematic-debugging 抢先命中
- 验证方式：检查 systematic-debugging 的 frontmatter 已收窄，不会被该请求命中

**场景三：中途调试**
- 前置条件：implement 阶段遇到 bug
- 期望结果：implement skill 内置 4 阶段根因分析流程
- 验证方式：检查 implement 正文或 references 包含调试流程

**场景四：runner 契约一致性**
- 操作步骤：对比 orchestrator 正文、model-invocation.md、runbook.md、state-templates.md 中关于 DEV 和 TEST 阶段 runner 的描述
- 期望结果：全部一致——DEV=Claude-first（可选 Codex），TEST=Gemini-first（fallback Claude→Codex）

**场景五：双目录镜像一致性**
- 操作步骤：对比 `.claude/skills/<core-skill>/SKILL.md` 与 `.codex/skills/<core-skill>/SKILL.md`
- 期望结果：7 个核心 skill + 11 个退役 skill + 4 个 specialist skill + writing-skills 的内容完全一致

**场景六：specialist skill 不抢入口**
- 前置条件：用户发送"帮我做一个前端页面"
- 期望结果：using-superpowers 路由到 orchestrator（而非 frontend-design）；frontend-design 仅在 DEV stage 内被调用
- 验证方式：检查 frontend-design 的二级能力声明 + using-superpowers 的调用层级规则

**场景七：可选 Codex 委派（AC-5）**
- 前置条件：用户在 implement 阶段说"用 codex 来做"
- 期望结果：codex skill 正常触发，orchestrator 记录 DEV 阶段执行者为 Codex
- 验证方式：检查 orchestrator 正文和 model-invocation.md 中包含用户指定 Codex 的委派路径

**场景八：流程感知（AC-6）**
- 前置条件：用户正处于 orchestrator 管理的 PLAN 阶段
- 期望结果：using-superpowers 感知到当前阶段，优先推荐 `/plan` 而非遍历所有 skill
- 验证方式：检查 using-superpowers 正文中包含 current-flow.md 检测逻辑和阶段推荐规则

**场景九：向后兼容（AC-9）**
- 前置条件：用户直接调用 `/spec`、`/plan`、`/implement`、`/review`、`/test`
- 期望结果：行为符合融合后的定义，不报错，不提示"skill 不存在"
- 验证方式：检查 5 个核心 skill 的 frontmatter name 和 description 未被删除或破坏

## 6. 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| implement SKILL.md 融合后过长 | token 消耗增大，触发不清 | 主文保留规则条目，详细流程放 references/ 子目录（TDD + 调试两个独立文件） |
| 退役 skill frontmatter 不够窄 | 仍被发现系统优先命中 | 使用 `[已退役]` 前缀 + 极窄描述；正文明确标注已被核心流程吸收 |
| .codex 镜像后 codex/gemini-designer-main 仍依赖 .claude 路径 | 纯 .codex 运行环境下路径失效 | 列为兼容性例外，在 plan 文档中明确记录此限制 |
| using-superpowers 流程感知依赖 current-flow.md | 状态文件不存在时可能误判 | 设计回退逻辑：不存在时回退到纯路由模式 |
| 大量文件同时修改可能遗漏 | 部分 skill 改造不完整 | Phase 5 逐条对照 AC 验收；使用 diff 工具对比镜像一致性 |
| requesting-code-review 实际内容与名称不符 | 退役说明可能指向错误 | P1-1 已标注此问题，退役时如实指向 review skill |

## 7. 开放问题

无。所有技术决策已在 spec v5 和本 plan 的技术决策章节中确认。
