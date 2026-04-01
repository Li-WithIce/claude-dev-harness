# Skills 体系融合 需求规格说明

> 状态：已确认 v5（基于 Codex 多轮 review 修订）
> 创建日期：2026-03-14
> 所属里程碑：无

## 1. 概述

### 1.1 功能简述
将当前分散的开发相关 skill 的精华融合到 7 个核心 skill 中，形成以 `using-superpowers` + `orchestrator` 为主导、`spec → plan → implement → review → test` 为流程骨干的统一开发工作流体系，同时保留 `codex` 和 `gemini-designer-main` 作为可选委派目标。同步完成 `.claude/skills` → `.codex/skills` 的镜像对齐。

### 1.2 所属模块
- 主稿源：`%USERPROFILE%\.claude\skills\`
- 镜像目标：`%USERPROFILE%\.codex\skills\`

### 1.3 关联文档
- 各核心 skill 的当前 SKILL.md（orchestrator, using-superpowers, spec, plan, implement, review, test）
- 被吸收 skill 的当前 SKILL.md（brainstorming, writing-plans, executing-plans, dispatching-parallel-agents, finishing-a-development-branch, test-driven-development, systematic-debugging, verification-before-completion, receiving-code-review, requesting-code-review, subagent-driven-development）
- Codex 审查报告：`docs/skill-consolidation/review.md`
- Codex 改造方案文档：`docs/skill-consolidation/skills-core-refactor.md`

## 2. 用户故事与场景

### 2.1 目标用户
使用 Claude Code 进行软件开发的开发者（即 skill 体系的维护者和使用者）。

### 2.2 用户故事
- 作为开发者，我希望开发流程由统一的核心 skill 驱动，以便减少 skill 间的触发冲突和职责重叠。
- 作为开发者，我希望每个核心 skill 吸收同类 skill 中经过验证的最佳实践，以便获得更强的单一 skill 而非多个碎片化 skill。
- 作为开发者，我希望 using-superpowers 能感知当前流程阶段并推荐下一步操作，以便减少手动选择 skill 的心智负担。
- 作为开发者，我希望 `.claude` 和 `.codex` 两套 skill 目录保持一致，以便无论使用哪个 agent 运行时，行为都相同。

### 2.3 使用场景

**场景一：新功能开发全流程**
- 前置条件：开发者启动新对话，描述一个需要开发的功能
- 期望结果：using-superpowers 识别为开发任务 → 触发 orchestrator → orchestrator 依次驱动 spec → plan → implement → review → test → DONE，每个阶段内的 skill 已融合了被吸收 skill 的最佳实践

**场景二：中途需要调试**
- 前置条件：implement 阶段遇到 bug
- 期望结果：implement skill 内置 systematic-debugging 的 4 阶段根因分析流程，不需要额外触发独立的 debugging skill

**场景三：用户指定 Codex 执行**
- 前置条件：用户在 implement 阶段说"用 codex 来做"
- 期望结果：codex skill 独立触发，orchestrator 记录 DEV 阶段由 Codex 执行

**场景四：specialist skill 与主流程的关系**
- 前置条件：用户说"帮我做一个前端页面"
- 期望结果：using-superpowers 识别为开发任务 → 先进入 orchestrator → 在 DEV 阶段内调用 `frontend-design` 作为二级能力，而非由 frontend-design 直接抢占主流程入口

## 3. 功能需求

### 3.1 输入
- 当前全部 skill 的 SKILL.md 内容（已在前序梳理中完成阅读）
- 用户确认的融合决策（见第 3.4 节）
- Codex review 反馈（见 review.md）

### 3.2 输出

**核心产出：**
1. 7 个核心 skill 的新版 SKILL.md 及 references/（覆盖原文件）
2. 11 个被退役 skill 的 frontmatter 收窄 + 正文替换为重定向说明
3. `.codex/skills` 镜像同步（含新增缺失目录）

**配套产出：**
4. 本 spec 文档及后续 plan 文档
5. `implementation-notes.md`（implement 阶段产出）

### 3.3 核心行为描述

#### 3.3.1 using-superpowers 融合行为
- 保留现有的 skill 路由守门职责
- 新增流程感知能力：检测当前是否处于 orchestrator 管理的流程中，如果是，自动推荐当前阶段对应的 skill，而非遍历所有 skill 匹配
- 新增开发任务优先路由：当检测到开发意图（开发、修 bug、重构、代码 review、测试验证）时，优先导向 orchestrator
- 明确调用层级：开发主流程 skill 高于 specialist skill；specialist skill 仅在具体 stage 内作为二级能力调用
- 新增 red flags（必须阻止的合理化借口）：
  - "这个改动很小，不需要 orchestrator"
  - "先直接 implement，再补文档"
  - "review/test 太慢，先提交"
  - "这个是 bug fix，不用 spec/plan"
- 保留中文输出、代码标识符英文的规则

#### 3.3.2 orchestrator 融合行为
- 保留现有的 SPEC → PLAN → DEV → REVIEW → TEST → DONE 阶段流转和门控机制
- 执行架构采用分阶段策略：DEV 阶段默认由 Claude `/implement` 执行（用户显式要求时委派 Codex）；TEST 阶段保持 Gemini 主测（fallback 顺序：Gemini → Claude `/test` → Codex）
- **runner 契约迁移**：所有 references/ 文档（artifact-contracts.md, gates.md, runbook.md, state-templates.md, model-invocation.md）中关于 runner 的描述必须同步更新，确保 DEV 的 Claude-first 和 TEST 的 Gemini-first 在正文与 references 中一致
- 吸收 `dispatching-parallel-agents` 的并行分发规则：当 plan 中存在 2+ 无依赖的 TODO 时，orchestrator 可以建议并行分发 subagent 执行
- 吸收 `executing-plans` 的批量执行模式：implement 阶段以每批 3 个 TODO 为单位执行，每批完成后设置检查点，由用户确认后继续
- 吸收 `finishing-a-development-branch` 的 DONE 阶段收尾协议：DONE 阶段提供 4 选项（merge/PR/保留/丢弃），测试全绿才能进入收尾
- 保留 max_loop=2 的回环机制和 P0/P1/P2 门控规则
- 保留制品路径规范 `docs/<task-id>/`
- 保留状态文件维护（current-flow.md, stage-history.md, handoff.md, decision-needed.md）
- 明确与 using-superpowers 的关系：orchestrator 是开发任务的唯一 governor，using-superpowers 是入口纪律控制器
- 文档中避免硬编码单边路径，改用"当前 skill 所在目录优先"的策略

#### 3.3.3 spec 融合行为
- 保留现有的三大核心原则（不猜测、不模糊、不写代码）和固定模板
- **模板增强**：在模板头部增加 `task_id` 和 `task_name` 字段，使产出满足 orchestrator 的 artifact contract
- 吸收 `brainstorming` 的渐进式澄清：澄清阶段采用一次一问的方式，每个问题提供 2-3 个选项并带推荐项，而非一次性列出所有问题
- 吸收 `brainstorming` 的 YAGNI 裁剪：在撰写 In Scope 时，主动检查是否存在过度设计的功能点，向用户确认是否真的需要
- 吸收 `doc-coauthoring` 的分段验证：spec 撰写时分段（每段 200-300 字）输出给用户确认，而非一次性输出完整文档
- 保持边界约束与确认动作的严格性，不因吸收 brainstorming 而变成开放式文档

#### 3.3.4 plan 融合行为
- 保留现有的三大核心原则（不猜测、不模糊、不写代码）和固定模板
- **模板增强**：在模板头部增加 `task_id` 字段，使产出满足 orchestrator 的 artifact contract
- TODO 粒度保持 1-4 小时级（面向人类开发者），implement 阶段由 agent 自行细化
- 吸收 `writing-plans` 的精确文件路径要求：每个 TODO 必须列出精确的文件路径（不可使用模糊描述如"在相关文件中"），以及验证该 TODO 的具体命令和预期输出
- 吸收 `writing-plans` 的 TDD 结构提示：每个 TODO 的验收标准中标注"先写测试再写实现"的提醒（但不在 plan 中写具体测试代码，这属于 implement 阶段）
- 吸收 `writing-plans` 的依赖可视化：依赖关系章节必须标明哪些 TODO 可以并行，为 orchestrator 的并行分发提供依据
- 新增 handoff 视角：每个 TODO 标注可委派给 Codex 的输入信息、预期输出、watchouts

#### 3.3.5 implement 融合行为
- 保留现有的两种工作模式（按 Plan 实现 / 根据反馈修复）和编码规范
- 吸收 `test-driven-development` 的 RED-GREEN-REFACTOR 铁律：每个 TODO 实现时必须先写失败测试 → 看到失败 → 写最小实现 → 看到通过 → 重构。跳过测试需要用户显式许可
- 吸收 `systematic-debugging` 的根因分析流程：修复模式下，修复 bug 前必须完成 4 阶段（调查→模式分析→单假设测试→实施）；连续 3 次修复失败后必须停止，向用户报告并讨论架构问题
- 吸收 `verification-before-completion` 的完成验证：每完成一个 TODO，必须运行验证命令并检查输出后才能勾选完成，不可基于"代码看起来对了"就声称完成
- 吸收 `receiving-code-review` 的反馈处理协议：收到 review/test 反馈后，先验证问题是否成立再决定修改，禁止表演性认同，保留技术性怀疑能力
- **新增固定交付物**：`implementation-notes.md`，内容包含改了什么、没改什么、风险点、reviewer watchouts。此文件是 DEV → REVIEW 的必要 handoff 交付物

#### 3.3.6 review 融合行为
- 保留现有的 5 维度审查框架和 P0/P1/P2 分级模板
- **模板增强**：在 review.md 模板头部增加 `task_id`、`task_name` 字段，输出路径为 `docs/<task-id>/review.md`，P0/P1/P2 结论与 orchestrator REVIEW gate 直接对应
- **新增第 6 维度：Spec 合规检查**，逐条验证 spec 中的验收标准是否被实现，不信任实现者的自述报告，必须对照代码验证（吸收自 `subagent-driven-development`）
- **新增输入要求**：review 必须同时对照 `spec.md`、`plan.md`、`implementation-notes.md` 和当前 diff
- 增加"是否少做、多做、做错"的三维核查
- 吸收代码审查 subagent 模板能力：review 阶段可调用 subagent 执行审查（注：原 `requesting-code-review` 的实际内容为 `verification-before-completion` 副本，不含此模板，此处不再点名该 skill 作为来源）
- 吸收 `verification-before-completion` 的证据要求：review 结论必须基于实际运行证据
- 明确 P0 是唯一阻塞 TEST 的等级；P1/P2 必须进入 watchouts 和 TEST handoff
- review.md 输出必须可被 orchestrator gate 直接消费

#### 3.3.7 test 融合行为
- 保留现有的严禁修改业务代码、test.md 输出契约（8 章节 + pass/fail/blocked 结论）
- **模板增强**：在 test.md 模板头部增加 `task_id`、`task_name` 字段，输出路径为 `docs/<task-id>/test.md`，结论字段（pass/fail/blocked）与 orchestrator gate 的 TEST verdict 直接对应
- 吸收 `verification-before-completion` 的 5 步门控函数：test 阶段每个验证点必须执行 IDENTIFY→RUN→READ→VERIFY→CLAIM 流程
- 强化证据先于结论：没有证据时优先输出 `blocked`，不可推断 pass
- TEST 阶段默认由 Gemini 主测（通过 `gemini-designer-main`）；fallback 顺序：Gemini → Claude `/test` → Codex
- specialist test skill（如 webapp-testing）只作为 test stage 内的二级调用，不抢主流程入口
- 吸收 `webapp-testing` 的侦察先于行动模式：涉及 UI 测试时，先截图/DOM 检查确认状态，再执行操作

### 3.4 业务规则与约束

**已确认的融合决策：**

| 决策项 | 选择 | 说明 |
|--------|------|------|
| 被退役 skill 处理 | 硬退役 | frontmatter 收窄 + 正文改为重定向说明，不删除目录 |
| 被退役 skill 清单 | 共 11 个 | brainstorming, writing-plans, executing-plans, dispatching-parallel-agents, finishing-a-development-branch, test-driven-development, systematic-debugging, verification-before-completion, receiving-code-review, requesting-code-review, subagent-driven-development |
| 执行架构 | DEV: Claude-first / TEST: Gemini-first | DEV 默认 Claude，可选 Codex；TEST 默认 Gemini，fallback Claude → Codex |
| TODO 粒度 | 统一粗粒度（1-4h）| implement 阶段 agent 自行细化 |
| using-superpowers 职责 | 路由 + 流程感知 | 感知 orchestrator 阶段，推荐下一步 |
| 体系边界 | 核心 7 + codex + gemini | 共 9 个开发流程相关 skill |
| 制品路径 | `docs/<task-id>/` | 统一使用 task-id 隔离 |
| 双目录策略 | `.claude` 为唯一主稿，`.codex` 为镜像 | 不允许 `.codex` 独立演化 |
| specialist skill | 保留但降为二级能力 | 不作为开发主流程入口 |

**不变的约束：**
- orchestrator 的 max_loop=2 回环限制不变
- 各 skill 的核心原则（不猜测、不模糊等）不变
- P0/P1/P2 门控规则不变
- test.md 结论只允许 pass/fail/blocked
- TEST fallback 顺序不变：Gemini → Claude `/test` → Codex

## 4. 非功能需求

### 4.1 性能要求
- 核心 SKILL.md 正文保持精炼，详细规则优先下沉到 references/ 子目录
- 新增正文不得无上限复制被吸收 skill 的整段内容，须提炼为规则条目
- 使用 references/ 子目录拆分详细内容（参考 orchestrator 的现有做法）

### 4.2 安全要求
无特殊要求。

### 4.3 兼容性要求
- 融合后的 skill 必须兼容 Claude Code 的 Skill 工具调用机制（frontmatter + SKILL.md 格式）
- codex 和 gemini-designer-main 的 SKILL.md 不做修改，仅调整 orchestrator 中对它们的引用方式
- 文档中不硬编码 `.claude` 或 `.codex` 单边路径，改用相对路径或"当前 skill 所在目录优先"的策略
- **兼容性例外**：codex 和 gemini-designer-main 在 `.codex/skills` 中作为镜像占位目录，其 SKILL.md 内仍保留对 `.claude` 路径的引用，运行时继续依赖 `.claude` 侧脚本路径。此为已接受的兼容性例外，不视为镜像不一致
- 镜像后 `.claude` 与 `.codex` 的所有本次被镜像同步的同名 skill（含核心 skill、本次被修改的 specialist skill 及其他本次被修改的非核心 skill）frontmatter、正文核心规则、references 及支持资产语义必须一致

## 5. 边界与限制

### 5.1 明确包含（In Scope）
1. 改写 7 个核心 skill 的 SKILL.md 及其 references/，融入被吸收 skill 的精华
2. 对 11 个被退役 skill 执行硬退役（收窄 frontmatter + 正文改为重定向说明），不删除目录
3. 更新 orchestrator 的全部 references/ 文档，使 runner 契约与 DEV Claude-first / TEST Gemini-first 决策一致
4. 对核心 skill 模板增加 `task_id` 等字段，满足 orchestrator artifact contract
5. 更新 using-superpowers 的流程感知逻辑和开发任务优先路由
6. `.codex/skills` 镜像同步：补齐缺失目录（orchestrator, codex, gemini-designer-main），同步所有核心 skill、本次被修改的 specialist skill 以及其他本次被修改的非核心 skill（如 writing-skills）的完整目录（SKILL.md 及该 skill 已存在的支持资产，如 references/、reference/、scripts/、examples/ 等）
7. 对开发相关的 specialist skill 补充"二级能力"声明（一条规则，不重写）

### 5.2 明确排除（Out of Scope）
1. 不重写非开发类 specialist skill 的整体体系
2. 不修改 codex 和 gemini-designer-main 自身的 SKILL.md 内容
3. 不创建新 skill，仅改写已有 skill
4. 不修改 CLAUDE.md 全局指令
5. 不建立跨仓库发布系统
6. 不做目录重命名或 skill 目录结构变更

### 5.3 已知约束
- 融合后的 SKILL.md 体量增大可能影响 Claude 加载速度和 token 消耗，需通过 references/ 拆分控制
- using-superpowers 的流程感知依赖 orchestrator 的状态文件，如果状态文件不存在则回退到纯路由模式
- 被退役 skill 如果被其他 skill 引用（如 writing-skills 引用 test-driven-development），需要更新引用指向核心 skill 的对应章节
- specialist skill 的"二级能力"声明需要每个相关 skill 单独添加一条规则，工作量与涉及 skill 数量正相关

## 6. 验收标准（Acceptance Criteria）

### AC-1：核心 skill 功能完整
- **Given** 7 个核心 skill 的新版 SKILL.md 已写入
- **When** 对每个核心 skill 执行内容检查
- **Then** 每个 skill 包含原有功能 + 被吸收 skill 的指定精华内容，无遗漏

### AC-2：artifact contract 对齐
- **Given** spec、plan、review、test 四个核心 skill 的模板已更新
- **When** 检查每个模板的头部字段
- **Then** 所有模板包含 `task_id`、支持 `docs/<task-id>/` 输出路径、满足 orchestrator artifact contract 要求

### AC-3：被退役 skill 已降权
- **Given** 硬退役完成
- **When** 检查 11 个被退役 skill 的 SKILL.md
- **Then** 每个 skill 的 frontmatter description 已收窄为窄触发、正文已改为重定向说明（指向新的核心 skill）、目录完整保留

### AC-4：触发无冲突
- **Given** 新的 skill 体系生效
- **When** 用户发起以下开发请求：
  - "做一个新功能"
  - "修一个 bug"
  - "写 plan"
  - "review 代码"
  - "跑测试"
  - "fix review 里的问题"
- **Then** using-superpowers 正确路由到 orchestrator，orchestrator 正确驱动对应阶段，不会被已退役 skill 或 specialist skill 抢先命中

### AC-5：可选委派正常工作
- **Given** 用户在 implement 阶段说"用 codex 来做"
- **When** skill 路由处理该请求
- **Then** codex skill 正常触发，orchestrator 记录 DEV 阶段执行者为 Codex

### AC-6：流程感知正常工作
- **Given** 用户正处于 orchestrator 管理的 PLAN 阶段
- **When** 用户发送新消息
- **Then** using-superpowers 感知到当前阶段，优先推荐 `/plan` 而非遍历所有 skill

### AC-7：runner 契约一致
- **Given** orchestrator 正文和 references/ 均已更新
- **When** 检查 DEV 和 TEST 阶段的 runner 描述
- **Then** 正文与 references/ 一致：DEV 默认 Claude 执行、可选委派 Codex；TEST 默认 Gemini 执行、fallback Claude → Codex；两阶段 runner 策略无矛盾

### AC-8：双目录镜像一致
- **Given** `.codex/skills` 镜像同步完成
- **When** 对比 `.claude/skills` 与 `.codex/skills` 的核心 skill、本次被修改的 specialist skill 及其他本次被修改的非核心 skill（如 writing-skills）
- **Then** 同名 skill 的 frontmatter、正文核心规则、references 及支持资产语义一致；`.codex` 中新增的 orchestrator/codex/gemini-designer-main 目录可被正常加载；codex 和 gemini-designer-main 的 `.claude` 路径引用属于已接受的兼容性例外

### AC-9：向后兼容
- **Given** 用户直接调用 `/spec`、`/plan`、`/implement`、`/review`、`/test`
- **When** skill 被触发
- **Then** 行为符合融合后的定义，不报错，不提示"skill 不存在"

### AC-10：specialist skill 降级
- **Given** 相关 specialist skill 已添加"二级能力"声明
- **When** 用户发起标准开发任务
- **Then** specialist skill 不抢占主流程入口，仅在 stage 内被调用时生效

## 7. 决策记录（Decision Log）

| # | 问题 | 决策 |
|---|------|------|
| 1 | writing-skills 引用 TDD 如何处理 | 纳入 In Scope，退役阶段更新引用指向 implement 的 TDD 章节 |
| 2 | orchestrator references/ 更新范围 | 全部 5 个 references 文件必须同步调整 runner 契约 |
| 3 | CLAUDE.md 是否需要修改 | 不需要，using-superpowers 内部处理流程感知 |
| 4 | brainstorming 和 requesting-code-review 退役 | 均纳入退役清单（共 11 个），精华已融入核心 skill |
| 5 | specialist skill 二级能力声明清单 | frontend-design, mcp-builder, webapp-testing, claude-api 需添加；docx/pdf/pptx/xlsx 不需要 |
| 6 | TEST runner 策略 | Gemini 主测，fallback Gemini → Claude `/test` → Codex |
| 7 | requesting-code-review 来源归因 | 该 skill 实际内容为 verification-before-completion 副本，不含代码审查 subagent 模板；review 的吸收描述改为"吸收代码审查 subagent 模板能力"，不再点名该 skill 作为来源 |
| 8 | codex/gemini-designer-main 镜像路径 | 列为兼容性例外：在 `.codex` 中作为镜像占位，运行时继续依赖 `.claude` 路径 |

## 8. 开放问题（Open Questions）

无。

## 9. 变更记录

| 日期 | 变更内容 | 变更人 |
|------|---------|--------|
| 2026-03-14 | 初稿创建 | Claude |
| 2026-03-14 | v2：基于 Codex 第一轮 review 修订 P0/P1/P2 | Claude |
| 2026-03-14 | v3：基于 Codex 第二轮 review 修订——P0-1（TEST runner 策略改为 Gemini 主测，消除与 Claude-first 的矛盾）、P1-1（退役清单统一为 11 个并显式列出）、P1-2（镜像范围扩展到本次被修改的 specialist skill）、P1-3（review/test 补充模板增强要求）、P2-1（Open Questions 改为 Decision Log）| Claude |
| 2026-03-14 | v4：基于 Codex 第三轮 review 修订——P1-1（requesting-code-review 来源归因纠正）、P1-2（codex/gemini-designer-main 兼容性例外补入 spec）、P2-1（AC-8 扩展为核心 skill + 本次修改的 specialist skill）| Claude |
| 2026-03-14 | v5：基于 Codex 后续 review 修订——镜像范围扩展纳入 writing-skills 及其支持资产；AC-8 口径同步更新为"所有本次被修改的非核心 skill" | Claude |
