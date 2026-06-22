---
task_id: trellis-comparison-reusable-design
artifact: trellis-reusable-design
updated: 2026-06-22
status: final
---
# Trellis 对比设计与可复用方案

## 0. 结论摘要

Trellis 对 harness 最值得借鉴的不是“再建一套 `.trellis/` 目录”，而是三类协议能力：

- 把任务从单个阶段文档扩展成可长期追踪的 task entity：需求、状态、责任人、分支、PR、父子任务和完成边界。
- 把上下文拆成稳定规则、任务上下文、会话上下文和执行证据，减少 agent 每轮重新猜“该读什么”。
- 在轻量 UI / graph / timeline 上做 drift detection 和进度可视化，但不让 UI 成为 source of truth。

对 `dev-harness` 的推荐路线是：**继续保留 `plan.md` frontmatter 作为唯一阶段真相源，把 Trellis 可复用机制压缩为可选 task artifacts、review 抽查项和后续 validator advisory**。不引入 `.trellis/`、server truth、dashboard runtime 或第二套状态机。

## 1. 范围与事实源

### Trellis 事实源

本轮把公开资料分成三层使用：

| 层 | 本轮用途 | 事实边界 |
|---|---|---|
| Agent Harness Trellis | 主要对标对象 | 其文档描述 `.trellis/` 结构、task lifecycle、role orchestration、active task pointers、LLM wiki、上下文系统和完成阶段。 |
| CodeTrellis | UI / 观察面参考 | 其文档强调 plan + code graph、drift detection、terminal + timeline、local-first visual IDE。只作为可视化与漂移检测参考，不作为 task truth 设计来源。 |
| Trellis.dev local environment | dev-runtime 参考 | 其文档强调本地服务、日志、crash reports、cases、upgrade / backup / restore。只用于评估“是否需要运行时管理层”，本轮结论为暂缓。 |

外部来源：

- https://docs.trytrellis.app/advanced/architecture
- https://docs.trytrellis.app/overview
- https://docs.trytrellis.app/advanced/context-system
- https://docs.trytrellis.app/advanced/multi-agent-workflow
- https://github.com/Agent-Harness/trellis
- https://codetrellis.dev/docs
- https://trellis.dev/docs/

### harness 现状源

清理后，后续优化只沿用以下当前协议事实源：

- `docs/README.md`
- `docs/shared-memory-layers.md`
- `docs/team-write-authority.md`
- `docs/工作流/task-entity-artifact.md`
- `docs/工作流/context-manifest-artifact.md`
- `docs/工作流/single-writer-precompact.md`
- 用户提供的 `harness-analyst` 只读现状报告

## 2. 机制级对照

| 维度 | Trellis 事实 | harness 现状 | 可复用判断 |
|---|---|---|---|
| 任务真相源 | `.trellis/tasks/<task>/` 持有任务状态、需求、分支、PR、subtask 关系；还有 active task pointer。 | `docs/tasks/<task-id>/plan.md` frontmatter 是唯一 stage truth，`.assistant/运行时` 是恢复 mirror。 | 可借鉴 task entity metadata，但不能让它决定 stage。 |
| 阶段生命周期 | 公开文档描述 plan / execute / finish 边界，并有 role handoff。 | `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`，强 validator。 | finish 边界可吸收到 TEST / Handoff；阶段拓扑不改。 |
| 上下文系统 | Trellis 有 global rules、workspace memory、task context、LLM wiki 和 manifest / JSONL 类上下文文件。 | `.assistant` 分运行时 / 工作流 / 配置 / 模板；`read_first`、`convergence`、`artifacts` 已在 roadmap 中落地。 | 可借鉴“上下文 manifest”，但应复用 `read_first` / `artifacts`。 |
| 多 agent 角色 | Trellis 文档把 research / implement / check 等角色拆开，并通过 task 状态交接。 | harness 默认 Codex-only，可显式 team mode；已有 PLAN_REVIEW / CODE_REVIEW / TEST gate。 | 角色语义可复用，运行时 team 不扩。 |
| 子任务树 | Trellis task lifecycle 支持 parent / subtask 关系。 | harness 有 team task-board mirror，但 docs/tasks 主线仍偏单 task。 | 适合做 optional roadmap / subtask artifact。 |
| 证据与完成 | Trellis finish 阶段强调完成记录与上下文归档。 | TEST 产物有 conclusion / handoff；`artifacts:` 目前只声明，不做存在性 / diff 交叉校验。 | 增强 TEST Handoff 和 artifact 抽查最有 ROI。 |
| 可视化与漂移 | CodeTrellis 强调 plan + graph + timeline、drift detection、chat-to-edit。 | harness 暂缓 dashboard/server truth；CodeGraph 当前不可用时靠 rg/manual reading。 | 先做 headless drift advisory，不做 dashboard。 |
| 运行时管理 | Trellis.dev 提供本地服务、日志、cases、crash reports、backup / restore。 | harness 是 Windows/PowerShell-first repo 工具，无常驻服务。 | cases 可作为 debug artifact；服务层暂缓。 |

## 3. 可复用方案

### adopt now

#### A1. Finish boundary checklist

Trellis 的 finish 边界适合收进 harness 的 `TEST` / `Handoff` 写法，而不是新增 stage。

建议后续任务：

- 在 `skills/test/SKILL.md` 的 Handoff 要求中加入 4 项：artifact 是否存在、是否需要长期文档更新、是否有 subtask / follow-up、是否有 runtime pointer 或 recovery 更新。
- 在 `skills/review/SKILL.md` 加一条抽查：`artifacts:` 声明是否覆盖实际产出；未覆盖时 findings。

收益：直接补上 phase7 里已经指出的 `artifacts:` 与真实产出脱钩风险。

#### A2. Context taxonomy 固化

Trellis 的 global / workspace / task / session context 分层与 harness `.assistant` 分层相近，适合收成写作规则。

建议：

- `global/project rules` -> `AGENTS.md` + `.assistant/工作流/项目约定.md`
- `workspace memory` -> `.assistant/配置/*.md` 与 `.assistant/运行时/记忆-*.md`
- `task context` -> `docs/tasks/<task-id>/plan.md` 的 `read_first:` / `convergence:` / `artifacts:`
- `session scratch` -> `.assistant/运行时/tasks/<task-id>.md`，不进长期协议

收益：减少“这条信息该写 AGENTS、runtime、task artifact 还是长期文档”的判断漂移。

#### A3. Role names as review lenses

Trellis 的 research / implement / check 角色不需要复制成 agent runtime，但可以作为 review lens：

- research lens：PLAN / PLAN_REVIEW 是否真的读了必要事实源。
- implement lens：IMPLEMENT 是否只做 plan 内的变更。
- check lens：CODE_REVIEW / TEST 是否复核 artifacts、diff 和 verification。

收益：复用角色语义，不增加 team surface。

### adapt

#### B1. Task entity metadata artifact

Trellis 的任务实体字段有价值，但直接写进 frontmatter 会污染 stage truth。更适合做 optional artifact。

建议格式：

- 路径：`docs/tasks/<task-id>/task-entity.md` 或 `task-entity.yaml`
- 必须在 `plan.md` 的 `artifacts:` 中声明。
- 字段只允许描述：requirement links、owner、branch、PR、parent task、subtasks、external issue。
- 禁止字段：stage、verdict、current tool。它们继续由 `plan.md` frontmatter 和 append-only review/test runs 管。

适用场景：大型 roadmap、跨分支任务、需要和 PR/issue/subtask 对齐的任务。

#### B2. Subtask tree artifact

Trellis 的 parent / subtask 关系适合补足 harness 单 task 视角的短板。

建议先不动 team task-board，新增可选 artifact：

- `docs/roadmaps/<slug>/items.yaml` 或 `docs/tasks/<task-id>/subtasks.yaml`
- 只表达拆分、依赖、完成判据和对应 task_id。
- 不驱动 `advance-stage.ps1`，也不更新 `.assistant/运行时/当前任务.md`。

当前结论是：roadmap / items 可以是 artifact，但不能成为 stage truth。

#### B3. Headless drift detection

CodeTrellis 的 drift detection 可以改造成无 UI 的 reviewer 抽查或脚本。

最小方案：

- 输入：`Change Contract.affected_paths`、`Plan.artifacts`、`git diff --name-only`。
- 输出：warning，不阻断旧任务。
- 检查：
  - diff 中出现未声明路径。
  - 声明 artifact 未创建。
  - `artifacts:` 与 `affected_paths` 混用。

这比直接做 dashboard 更符合 vault-as-truth-source / git 可审底线。

#### B4. Case artifact for incident / debug tasks

Trellis.dev 的 cases / logs / crash reports 思路可转成静态文档 artifact。

建议：

- 对 `work_type: bug` 或 `debug` 类任务，允许 `docs/tasks/<task-id>/case.md`。
- 内容包含 reproduction、timeline、logs excerpts、commands、environment、fix evidence。
- 不替代 `test.md`，只作为 evidence bundle。

这能补齐复杂 debug 任务里证据散落在聊天记录和 terminal output 的问题。

### defer

#### C1. Dashboard / timeline / graph UI

暂缓。理由：

- harness 明确选择 vault-as-truth-source，现有 roadmap 已把 dashboard / server-as-truth-source 列为 deferred。
- CodeGraph 当前不可用时，graph UI 会变成二手展示，无法保证事实一致。
- 先做 headless drift advisory，等字段和证据链稳定后再评估 UI。

#### C2. Queue / scheduler / active task runtime

暂缓。Trellis 的 active task pointer 和多 agent lifecycle 对长任务有用，但 harness 当前通过 `advance-stage.ps1`、`.assistant/运行时/恢复索引.md` 和 team board mirror 已覆盖主路径。

触发条件：未来同一 workspace 需要同时推进 3 个以上长期并行 task，并且现有恢复索引无法稳定表达优先级。

#### C3. LLM wiki / persistent project memory expansion

暂缓。harness 已有 `.assistant/运行时/记忆-学习|决策|约定|问题.md` 方案；不应再建 LLM wiki 目录。

可后续评估：是否需要为 wisdom 4 文件增加检索脚本或索引摘要，但仍在 `.assistant` 内完成。

### reject

#### D1. 不引入 `.trellis/`

原因：

- 会和 `docs/tasks/<task-id>/`、`.assistant/运行时/tasks/` 形成第三套任务入口。
- 用户说“继续”时恢复路径会变模糊。
- validator / advance-stage / shared-memory 协议都不认识该目录。

#### D2. 不让 UI 或 service 成为 source of truth

Dashboard、timeline、terminal session、case service 都只能是 projection 或 artifact。stage、verdict、handoff 继续由文件协议决定。

#### D3. 不复制 Trellis role runtime

research / implement / check 可作为语义 lens，不复制成新的 agent topology。harness 已有 PLAN_REVIEW、CODE_REVIEW、TEST 三道质量门，再叠 runtime role 会增加编排复杂度。

#### D4. 不引入第二套 memory hierarchy

Trellis 的 workspace memory / LLM wiki 与 harness `.assistant` 功能重叠。可复用的是分类口径，不是路径或目录名。

## 4. 推荐后续任务

| 优先级 | 任务候选 | 类型 | 产出 | 备注 |
|---|---|---|---|---|
| P1 | `finish-boundary-checklist` | doc / skill polish | 更新 `skills/test/SKILL.md`、`skills/review/SKILL.md` | 低风险，直接补 artifact / handoff 抽查。 |
| P2 | `context-taxonomy-writing-rules` | doc | 更新 `.assistant/工作流/项目约定.md` 或 `docs/工作流/context-taxonomy.md` | 需要注意单写者和 vault 写回边界。 |
| P3 | `task-entity-artifact-design` | plan | 新增可选 `task-entity.md/yaml` 设计，不实现 validator | 先给大型任务试用，不进入 frontmatter。 |
| P4 | `artifact-drift-advisory` | enhance | validator warning 或独立脚本 | 依赖 `artifacts:` 已稳定使用。 |
| P5 | `debug-case-artifact-template` | doc | `case.md` 模板 + bug task 写作规则 | 适合真实 bug 修复 dogfood。 |
| P6 | `subtask-roadmap-artifact` | plan | `subtasks.yaml` / `docs/roadmaps/<slug>/items.yaml` | 作为后续独立评估项。 |

## 5. 与既有路线图的合并关系

- `work_type`、bug/refactor 模板、reflection checks 不需要在 Trellis 路线里重复开一组。
- `read_first`、`convergence`、`artifacts` 已由当前协议覆盖；Trellis 只补“怎么消费这些字段”。
- `artifact registry` 不进入当前轻量路线；Trellis 的 task entity 只应作为轻量 metadata artifact，不做中央 registry。
- AionUi gap 已裁定 live multi-agent smoke 暂缓；Trellis role workflow 不改变这个判断。

## 6. Guardrails

- `plan.md` frontmatter 继续是唯一阶段真相源。
- `.assistant/运行时/当前任务.md`、`恢复索引.md` 继续是 mirror，不承载完整设计。
- 所有 Trellis 借鉴项都先作为 optional artifact 或 skill writing rule；经过真实任务 dogfood 后再考虑 validator advisory。
- 新增 metadata 不得包含 stage / verdict / tool，避免和 harness 主协议竞争。
- 对外部资料只保留链接与机制摘要；不复制其目录结构。

## 7. 最终建议

下一步最值得做的是 `finish-boundary-checklist`：它能直接封住 `artifacts:` 声明与真实产出脱钩的问题，改动面小。其次是 `task-entity-artifact-design`，用于把大型任务的 branch / PR / subtask / requirement links 统一放在 task artifact，而不是把 `plan.md` frontmatter 扩成杂货架。

## 8. 后续：基于源码的事实修正（指针）

本文第 1 节明确「只把公开文档作为输入来源，不把其实现细节写入本仓库协议」，故第 2 节机制对照表基于公开网页。后续基于本地真实源码 `D:/data/Trellis-main`（快照 2026-06-18）的复核与勘误，记录在同目录 follow-up 文档：[trellis-source-based-corrections.md](trellis-source-based-corrections.md)，含两处核心修正——① 上下文注入是「运行时引擎」而非仅「context 分类」；② `task.json` task entity 比「轻量 metadata」更完整。本节仅为导航指针，不改写第 0–7 节任何既有结论。
