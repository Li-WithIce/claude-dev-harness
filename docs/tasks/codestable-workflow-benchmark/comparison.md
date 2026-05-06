---
task_id: codestable-workflow-benchmark
artifact: comparison
source_repo: D:\data\CodeStable-main
target_repo: D:\data\claude-dev-harness
analyst: workflow-comparer
updated: 2026-04-30
---

# CodeStable vs Harness 对照评估

本文只做对照和借鉴判断，不改 harness 代码。结论按当前 harness 底线评估：`plan.md` frontmatter 是唯一阶段真相源、`.assistant/` 是 vault-as-truth-source、非 append 写回走 `advance-stage.ps1`、任务审阅面落在 `docs/tasks/<task-id>/`。

## 0. 结论摘要

CodeStable 的价值不在自动化强度，而在把长期软件维护拆成稳定实体：需求、架构、路线图、特性、问题、重构、知识沉淀。它解决的是“任务完成后知识散落，几个月后上下文丢失”的问题。

当前 harness 的价值在机器可验证阶段流：`PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`、validator、tool profile、workflow descriptor、shared-memory v2 和 single-writer 约束。它解决的是“当前任务如何被可靠推进、审查和恢复”的问题。

最合理的融合方向是：**保留 harness 的阶段真相源和验证门，把 CodeStable 的软件实体建模吸收到 plan/spec/test 的模板、可选 task artifacts、长期知识层里**。不应直接复制 `codestable/` 作为第二套运行时。

优先级最高的借鉴项：

- 在 PLAN 阶段引入更明确的 work type 分诊：feature / bug / refactor / explore / doc / knowledge。
- 为 bug 和 refactor 任务增加专用 Clarification / Verification 模板。
- 把 CodeStable 的“反射检查”并入 `implement` 与 `code_review` 纪律，减少 AI 顺手扩大范围。
- 将 roadmap / requirement / architecture 这类长期实体作为后续独立设计任务，而不是马上加入主流程。

## 1. 证据范围

CodeStable 已抽样读取：

- 顶层说明：`D:\data\CodeStable-main\README.md`、`AGENTS.md`、`CLAUDE.md`
- 路由和 onboarding：`cs/SKILL.md`、`cs-onboard/SKILL.md`
- 共享约定：`cs-onboard/reference/shared-conventions.md`、`system-overview.md`、`tools.md`
- 主流程：`cs-feat*`、`cs-issue*`、`cs-refactor*`
- 长期实体：`cs-req`、`cs-arch`、`cs-roadmap`
- 知识沉淀：`cs-learn`、`cs-trick`、`cs-decide`、`cs-explore`、`cs-note`

Harness 已抽样读取：

- 顶层和流程：`README.md`、`skills/using-superpowers/SKILL.md`、`skills/orchestrator/SKILL.md`
- 阶段 skill：`skills/plan`、`implement`、`review`、`test`
- 契约文档：`skills/orchestrator/references/lite-writing-guide.md`、`docs/shared-memory-layers.md`、`docs/工作流/single-writer-precompact.md`
- 脚本：`scripts/advance-stage.ps1`、`scripts/validate-lite-artifacts.ps1`
- 已落地路线：`docs/tasks/workflow-optimization-roadmap/plan.md`、Phase 5/6/7 plans、AionUi alignment docs

## 2. 机制级对照

| 维度 | CodeStable | 当前 harness | 评估 |
|---|---|---|---|
| 核心建模对象 | 软件实体和事件：requirements / architecture / roadmap / features / issues / refactors / compound | 单个 task 的阶段流：plan.md + review/implementation/test 产物 | 互补。CodeStable 管长期软件语义，harness 管当前任务推进 |
| 真相源 | 项目内 `codestable/` 文件树；各 skill 按目录和 frontmatter 读写 | `docs/tasks/<task-id>/plan.md` frontmatter + `.assistant` 运行时 mirror | 不能直接叠加第二套运行时。长期实体必须声明为 artifact，而不是 stage truth |
| 路由入口 | `cs` 只做分诊，不做事；开放诉求路由到具体 `cs-*` | `using-superpowers -> orchestrator` 统一把开发任务导入 lite workflow | harness 缺少“任务类型”分诊细度，可借鉴 |
| 新功能流程 | brainstorm -> design -> impl -> accept；design/checklist/acceptance 分文件 | PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST；append-only runs | 概念相近。CodeStable 的 design/accept 结构可映射到 plan/test 模板，不宜新增并行 stage |
| Bug 流程 | report -> analyze -> fix，强调复现、根因、影响面、fix-note | bug 只是普通 task，靠 plan 自由描述 | 可直接加强。bug 任务模板是高 ROI |
| 重构流程 | scan -> design -> apply；行为不变是底线；ff 仅小范围 | refactor 是 `Change Contract` 类型之一，但缺专门 scan/行为等价检查 | 可改造。先把“行为等价/范围锁定/反射检查”写进 plan/review |
| 大需求规划 | `roadmap/{slug}` + items.yaml 状态机 + minimal_loop | roadmap 目前表现为普通 task plan 文档，没有长期规划实体 | 有价值但需要单独设计，避免新 status 文件竞争 plan truth |
| 长期需求/架构 | req/arch 是“只记现状”的长效档案 | `.assistant` 保存记忆和协议，`docs/tasks` 保存任务产物；无产品/架构实体层 | 适合后续新增“长期项目档案层”，但需确定路径和 git 策略 |
| 知识沉淀 | `compound/YYYY-MM-DD-{doc_type}-{slug}.md`，learning/trick/decision/explore | `.assistant/运行时/记忆-学习/决策/约定/问题.md` 已有 wisdom 4 文件 | 已有重叠。可借鉴 doc_type/检索工具，但不需要再复制 compound 目录 |
| 验证强度 | 主要靠 skill discipline 和 `validate-yaml.py` | validator 强校验 frontmatter/sections/review/test/quality | harness 明显更强。CodeStable 机制进入 harness 时应接受 validator 化 |
| Team/runtime | 基本不做 agent 编排，强调人在环 | 已有 tool profile、team mode 文档、single-writer | CodeStable 不提供 team runtime 借鉴，别从这里找多 agent 方案 |
| Onboarding | 审计已有文档，迁移到 `codestable/` 骨架 | install/update-managed-assets 创建 AGENTS/GEMINI/.assistant/shims | 可以借鉴“迁移映射表”和“先审计再搬”，但目标路径需改造 |

## 3. 可直接借鉴

### 3.1 任务类型分诊写入 PLAN 纪律

CodeStable 在 `cs` / `cs-feat` / `cs-issue` / `cs-refactor` 里把 feature、bug、refactor、explore、knowledge 分得很清楚。Harness 现在只有较粗的 `Change Contract.change_type: task | feature | enhance | refactor`。

建议：

- 在 `skills/plan/SKILL.md` 的 Clarification 里增加 `work_type` 口径，先作为文档纪律，不急着改 validator。
- 建议枚举：`feature | bug | refactor | explore | doc | maintenance`。
- PLAN_REVIEW 抽查：work_type 与验收标准、非目标、验证命令是否一致。

价值：同样保持一个 lite workflow，但让后续模板和 review 重点能按任务类型收敛。

### 3.2 Bug 任务模板

CodeStable 的 issue-report/analyze/fix 强制区分现象、复现、期望 vs 实际、根因、影响面、修复方案、验证清单。这正是 generic plan 最容易漏的内容。

建议先不新增 `issue-report.md`，而是在 `plan.md` / `test.md` 中约束 bug 任务最小字段：

- Clarification 必含：复现步骤、期望行为、实际行为、影响范围、严重程度。
- Plan 必含：根因定位动作和至少一个修复验证动作。
- Test 必含：复现步骤重跑、期望行为验证、影响面回归。

价值：几乎不改主流程，却显著提高 bug 修复可审计性。

### 3.3 实现阶段反射检查

CodeStable 的 `shared-conventions.md` 第 7 节和 `cs-feat-impl` / `cs-issue-fix` 的约束很实用：不要往大文件继续塞、不要偷偷加补丁分支、不要顺手优化邻居、不要引入方案外概念。

建议直接加入：

- `skills/implement/SKILL.md`：实现前后自检“是否触发反射信号”。
- `skills/review/SKILL.md`：CODE_REVIEW 关注“方案外改动、补丁分支、顺手重构、未声明新概念”。

价值：纯文档协议改动，不改变 validator 和 stage 拓扑。

### 3.4 “只记现状，不记计划”的架构/需求纪律

CodeStable 对 `requirements/`、`architecture/`、`roadmap/` 的边界定义很清楚：req/arch 只写现状，roadmap 写计划，feature/issue 写单次动作。

建议先作为 harness 文档守则吸收：

- `README.md` 或 `lite-writing-guide.md` 增加一句：长期文档若描述现状，不能混入“未来计划”；计划必须落到 task/roadmap artifact。
- TEST/Handoff 里补一句：如本任务改变稳定能力或架构，必须说明“是否需要更新长期文档；不需要则写理由”。

价值：减少长期文档被计划态污染。

### 3.5 `cs-note` 的 AGENTS 管理边界

`cs-note` 的判据“短、稳、每次都要知道”适合 harness 的 workspace onboarding。当前 AGENTS.md 很容易变成杂项堆。

建议：

- 先只在文档里吸收判据：超过两行的背景不要写 AGENTS，进入 `.assistant/运行时/收件箱.md` 或任务 artifact。
- 若后续实现，采用 managed section，必须用户确认，一次只写一条。

价值：避免 AGENTS 膨胀，同时保留高频项目约束。

## 4. 需改造后复用

### 4.1 长期软件实体层

CodeStable 的 `codestable/requirements`、`architecture`、`roadmap` 对长期项目非常有价值，但不能直接复制到 harness 主流程。

推荐改造路径：

- 先设计一个可选长期层，候选路径需单独裁定：`docs/project/`、`docs/lifecycle/`、或 `.assistant/工作流/项目档案/`。
- 明确它不是 stage truth，不参与 `advance-stage.ps1` 的阶段判断。
- 任何长期实体更新必须由 task 的 `artifacts:` 声明并经过 review/test。

不建议现在直接创建 `codestable/`，因为这会和 `.assistant` / `docs/tasks` 并行，恢复时增加歧义。

### 4.2 Roadmap items.yaml

CodeStable 的 roadmap 状态机 `planned -> in-progress -> done/dropped` 和 `minimal_loop` 很有价值，尤其适合大需求拆分。

需要改造点：

- items.yaml 只能是 roadmap artifact，不是当前 task 的阶段真相源。
- `in-progress/done` 不应由 worker 手工改写，必须有明确写者，最好由 leader 或后续脚本操作。
- 与 `plan.md` 的 `stage`、team task board、`.assistant/运行时/tasks` 的关系必须先画清。

建议后续独立任务：设计 `docs/roadmaps/<slug>/roadmap.md + items.yaml`，并写 validator advisory，而不是在本轮直接落地。

### 4.3 Feature checklist.yaml

CodeStable 的 `{slug}-checklist.yaml` 能把 steps/checks 分开，但 harness 已经有 `Plan`、`Implementation Notes`、`Code Review`、`test.md`。

如果引入，应满足：

- checklist 是可选辅助 artifact，并在 `plan.md - artifacts:` 中声明。
- checklist status 不得成为推进依据，推进仍只看 `plan.md` frontmatter 和 latest verdict。
- review/test 必须以 append-only run 记录证据，不能只靠 YAML status。

否则它会变成第二套进度真相源。

### 4.4 `search-yaml.py` / frontmatter 检索

CodeStable 的 `search-yaml.py` 对大量 frontmatter docs 很有用。但 harness 当前长期 wisdom 是四个 append-only md 文件，不是一文一条 frontmatter。

可改造为两条路之一：

- 若新增长期实体层，则给每个实体文档加 frontmatter，再引入轻量 search。
- 若继续使用 wisdom 4 文件，则写 append-entry 检索工具，不套用 per-file YAML 搜索。

不建议为了使用 search-yaml 而改变现有 wisdom 4 文件形态。

### 4.5 Onboarding 审计与迁移映射表

`cs-onboard` 的迁移路径值得借鉴：先扫旧 docs，再生成“现有文件 -> 推荐归位 -> 置信度”的表，低置信度必须问用户。

适配到 harness：

- 可用于未来“把已有项目接入长期实体层”的任务。
- 不应影响现有 `install.ps1` 的基础安装路径，避免 onboarding 从“安装 harness”变成“整理项目文档”。

## 5. 不建议引入

### 5.1 不要直接复制完整 `codestable/` 到每个 harness workspace

原因：

- 会与 `docs/tasks/<task-id>/`、`.assistant/` 并行，形成三套入口。
- 恢复时用户说“继续”时，agent 不清楚应读 `docs/tasks` 还是 `codestable/features`。
- 当前 validator、advance-stage、shared-memory-layers 都不认识 `codestable/`。

如需实体层，必须先设计路径、写者、gitignore、validator/advisory 和与 `artifacts:` 的关系。

### 5.2 不要引入绕过 PLAN_REVIEW / CODE_REVIEW / TEST 的 fastforward

CodeStable 的 `cs-feat-ff` 和 `cs-refactor-ff` 适合手动工作流，但 harness 已明确小改也进 orchestrator。直接照搬会破坏当前质量门。

可接受的改造是“fast-track plan 模板”：减少 PLAN 内容，但仍保留 review/test gate。

### 5.3 不要让 checklist/status 文件驱动阶段推进

CodeStable 多处通过 YAML status 回写进度。Harness 的核心强项是 `plan.md` frontmatter + latest verdict。不能让 `items.yaml` 或 `checklist.yaml` 反向决定 stage。

### 5.4 不要扩大 skill 数量到 CodeStable 的完整 20+ surface

Harness 的主线 skill 数量少，认知成本可控。直接引入 `cs-req/cs-arch/cs-roadmap/cs-feat-*` 一组会和现有 plan/implement/review/test 重叠。

更好的方式是提炼模板和检查项，少量吸收到现有 skill。

### 5.5 不要让 AI 自动改 AGENTS.md 实质内容

CodeStable 也明确要求 AGENTS.md 高度项目相关，AI 只能提醒或在用户确认后写短条目。Harness 应保持同样边界。

## 6. 推荐实施路线

### Phase C1 - 低风险模板吸收

目标：不改脚本、不改 validator，只改 skill 文档。

建议改动：

- `skills/plan/SKILL.md`：增加 work_type 分诊和 bug/refactor Clarification 提示。
- `skills/implement/SKILL.md`：增加 CodeStable 反射检查摘要。
- `skills/review/SKILL.md`：增加 bug/refactor/code-quality 重点审查项。
- `skills/test/SKILL.md`：增加 bug 任务的复现重跑和 refactor 的行为等价验证提示。

验收：所有现有 validator 不受影响，diff 仅 skill 文档。

### Phase C2 - 任务类型字段 validator advisory

目标：把 C1 的文档纪律升格为可选结构。

建议：

- 扩展 `Change Contract.change_type` 或新增 metadata-style 字段，支持 `bug` / `doc` / `maintenance`。
- validator 只做存在时的枚举校验，不强制老任务回填。
- PLAN_REVIEW 按 work_type 抽查必需字段。

验收：旧任务零回归，新 fixture 覆盖合法/非法 work_type。

### Phase C3 - 长期实体层设计

目标：决定是否引入 requirements / architecture / roadmap 的长期文档层。

必须先裁定：

- 路径放在 `docs/project/`、`docs/lifecycle/` 还是 `.assistant`。
- 哪些文件进 git 审计，哪些保持 runtime。
- 谁有写权，是否必须通过 task artifact 声明。
- 与现有 wisdom 4 文件如何分工。

验收：只产出 plan/architecture 文档，不急着创建实体目录。

### Phase C4 - Roadmap artifact 原型

目标：只做一个 optional roadmap artifact，不改主 stage。

建议：

- `docs/roadmaps/<slug>/roadmap.md`
- `docs/roadmaps/<slug>/items.yaml`
- 与 task 关联通过 `plan.md - artifacts:` 声明。

验收：roadmap 可被 feature task 引用，但不反向推进 stage。

## 7. 关键 guardrails

- `plan.md` frontmatter 继续是唯一阶段真相源。
- `.assistant/运行时/当前任务.md` 和 `恢复索引.md` 不因 CodeStable 机制新增手写路径。
- 新增长期文档不得反向驱动 `advance-stage.ps1`。
- 任何新 status 文件都只能是 artifact 内部状态，不是 task stage 状态。
- 新知识先走 `.assistant/运行时/收件箱.md` 或当前 task artifact，稳定后再进入 wisdom/长期实体层。
- 所有借鉴先作为 opt-in 文档纪律落地，经过 1-2 个真实任务验证后再考虑 validator 化。

## 8. 最终判断

CodeStable 对 harness 最有价值的是“软件生命周期语义”，不是它的目录名或 skill 数量。当前 harness 已经有更强的阶段推进、校验、恢复和 team/profile 基础，所以借鉴策略应是：

1. 先吸收类型分诊、bug/refactor 模板、反射检查这些低风险规则。
2. 再设计长期实体层，让 requirements/architecture/roadmap 成为 task artifacts 的上层索引。
3. 明确拒绝直接复制 `codestable/`、fastforward bypass、YAML status 驱动 stage 这些会破坏 harness 底线的机制。
