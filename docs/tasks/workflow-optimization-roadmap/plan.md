---
task_id: workflow-optimization-roadmap
stage: PLAN
tool: claudecode
updated: 2026-04-27
---
# harness-lite 工作流优化路线图（Phase 5 / 6 / 7）

## Clarification

- 验收标准:
  1. 本文档作为 harness-lite 在 Phase 4（live-migration 完成）之后下一阶段演进的官方路线图，明确 Phase 5 / Phase 6 / Phase 7 的目标、范围、非目标、依赖、TODO、验收、回滚、风险
  2. 每个 Phase 的 TODO 必须可拆解为单独的 harness-lite 任务（每条对应一个 `docs/tasks/<task-id>/`），并能在不重开已完成主线（workflow-alignment / shared-memory-v2 / live-migration）的前提下独立落地
  3. 每个 Phase 的来源标注必须明确区分 **endogenous（内生问题）** / **CCW（来自 `Claude-Code-Workflow-main` 分析）** / **maestro（来自 `maestro-flow-master` 分析）**，并对应到 `docs/tasks/claude-maestro-workflow-benchmark/{claude-code-workflow-analysis.md,maestro-flow-analysis.md}` 的具体机制编号
  4. Phase 之间的 ordering 必须有显式 rationale（为什么 5 先于 6、6 先于 7）
  5. 必须给出"暂缓清单"，明确哪些来自分析的高级机制不进入 Phase 5-7（含原因）
  6. 整个路线图严格遵守 vault-as-truth-source / 单写者 / git 可审三条根约束；任何 TODO 都不得引入 dashboard / server-as-truth-source / 多套并行运行时
  7. validator `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId workflow-optimization-roadmap` 必须 PASS

- 非目标:
  - 不重开 workflow-alignment（Phase 1-4 已完成）、shared-memory-v2、live-migration 三条主线的设计讨论
  - 不在路线图阶段编写任何代码、任何 skill 实现、任何 schema 变更；本任务只产出"接下来要做什么 / 怎么排序 / 怎么验收"的契约
  - 不引入 server-as-truth-source（dashboard、WebSocket、sqlite 持久内存、PTY pool、Queue Scheduler、MCP core_memory 等），harness 继续以文件为唯一真相源
  - 不引入第二套并行 runtime（如 `.maestro/<session>/` + `.team/<session>/` + `.commander/` 多套并存）
  - 不强制接入 CCW 的 22-agent 拓扑或 maestro 的 wave 调度
  - 不规划 Phase 5-7 之外的更长周期（Phase 8+ 留给后续路线图迭代）

- 受影响目录:
  - `docs/tasks/workflow-optimization-roadmap/plan.md`（本文档）
  - `docs/tasks/claude-maestro-workflow-benchmark/{claude-code-workflow-analysis.md,maestro-flow-analysis.md}`（已存在，仅作引用）

- 回滚策略: 路线图为纯文档，`git revert` 删除该目录即可完全回滚；不会修改任何 skill / 脚本 / 运行时 vault 文件
- ui: not-applicable

## User Confirmation
- status: draft

## Plan

### Phase 5 — 文档与协议层最小补强（低风险 / 纯文档与配置）

- 目标: 把 CCW / maestro 中"零基础设施风险、纯文档与协议层"的最佳实践吸收进 harness-lite，先抬高 leader 与 worker 的协作下限；不动 validator schema、不动 advance-stage 脚本、不动 vault 4 层结构
- 范围:
  - workflow-team SKILL.md 增加 `--auto` 透传协议条款（leader → spawned member 的非交互意图传递）
  - skills/plan / skills/implement / skills/review SKILL.md 增加 TodoWrite milestone 模板（`phase-loaded → core-work-done → verification-done` 三段）
  - spec.md 模板新增可选 frontmatter 字段 `front_keywords: [a, b, c]`（inline-array），用于跨任务关键词检索
  - `.assistant/工作流/` 增补一份"长会话恢复 checklist"文档，沉淀目前散落在 CLAUDE.md 与 `恢复索引.md` 之间的实践
- 非目标:
  - 不修改 validator schema（不强制 `front_keywords`，仅 opt-in）
  - 不引入任何新 hook / 新脚本 / 新 runtime
  - 不修改现有 stage 推进协议
- 依赖:
  - 无前置依赖，可立即启动
  - 完成 live-migration（Task 62026153，已交付 PLAN_REVIEW PASS）后才能稳定写入 vault 文档（避免与那条主线产生 vault 写竞争）
- 排序理由: 这是三阶段中风险最低的一档（纯文档），先做能在不阻塞任何后续 Phase 的前提下立刻为团队提供 ROI；同时它也为 Phase 6 的 schema 硬约束提供前置文档习惯（先有"应当怎么做"的约定，再把它编进 validator 里）
- TODO:
  - [P5-T1] `auto-mode-propagation`：在 `skills/workflow-team/SKILL.md` 增加 leader → member 的 auto-confirm 透传条款，并在 `agent-configs/workflows/harness-lite.yaml`（如已存在）补充对应字段说明；不写脚本，只补协议文档
  - [P5-T2] `todowrite-milestone-template`：为 `skills/plan/SKILL.md` / `skills/implement/SKILL.md` / `skills/review/SKILL.md` 在 Phase 段落里加入"必须用 TodoWrite 标注 milestone"的模板段，覆盖 phase 切换 / blocker / completion 三类事件
  - [P5-T3] `spec-keyword-frontmatter`：在 `docs/任务模板/spec.md` 模板里新增可选 frontmatter `front_keywords: [a, b, c]`；validator 不做必填校验；在 plan.md 模板的 Clarification 内说明何时启用该字段
  - [P5-T4] `long-session-recovery-checklist`：在 `.assistant/工作流/` 下新增 `长会话恢复.md`（≤200 行），把恢复触发词、恢复索引读取顺序、worker callback 处理路径写成 step-by-step
- 验收标准:
  - 上述 4 条 TODO 各自落地为独立 `docs/tasks/<task-id>/`，每个 task 都通过 `scripts/validate-lite-artifacts.ps1`
  - workflow-team / plan / implement / review SKILL.md 在 git diff 中只新增段落，不修改现有契约段
  - spec.md 模板新增 `front_keywords` 后，已有 spec.md（如 `docs/tasks/shared-memory-v2-optimization/spec.md`）保持原状仍合法
  - `.assistant/工作流/长会话恢复.md` 单文件 ≤ 200 行、纯中文 step-by-step
- 回滚: 全部为文档级新增；`git revert` 单条 commit 即可完全恢复，不影响任何运行任务
- 风险:
  - workflow-team `--auto` 透传协议落地后，若 leader 漏配置，spawned member 仍会保持现有交互行为（保守降级），可接受
  - `front_keywords` opt-in 后若长期无人填写，会沦为"装饰字段"；Phase 6 规划阶段决定是否提升为半强制
- 来源:
  - P5-T1 ← CCW A2（Auto Mode `-y` propagation，`commands/ccw.md`）
  - P5-T2 ← CCW A1（TodoWrite + sentinel double-insurance，`workflow-plan/SKILL.md`）
  - P5-T3 ← CCW A6（Spec YAML headers + keyword index，`spec-generator/SKILL.md`）
  - P5-T4 ← endogenous（CLAUDE.md 中的"恢复触发"散落在多处，需要单一权威 checklist）

### Phase 6 — 质量评分与任务硬约束（中等风险 / 触及 validator schema）

- 目标: 把 CCW Quality Gates 与 maestro task hard-constraint 收敛为 harness-lite validator 的可量化扩展；让 Plan Review / Code Review 从纯 verdict 升级为可比较的多维评分；让 plan.md 在 Plan 段显式声明任务的"预读清单"与"收敛准则"，使 PLAN_REVIEW 不再只能凭直觉判断范围
- 范围:
  - validator schema 扩展：Plan Review / Code Review run 的 findings 段允许带 4-dim 评分（completeness / consistency / accuracy / depth，0-100 整数），verdict 与评分阈值对齐（≥80 pass，60-79 revise，<60 必须 revise + blocker）
  - plan.md schema 扩展：Plan 段允许（推荐）以 `read_first:` inline-array 与 `convergence:` 段声明前置阅读清单与显式收敛准则，validator 仅做格式校验（推荐字段，不强制）
  - `.assistant/记忆候选/` 与 wisdom 4-file 形态对齐（learnings / decisions / conventions / issues），均为 append-only md，单写者
- 非目标:
  - 不引入 CCW 的 sqlite 持久 memory、不引入 vector embedding、不引入 memory consolidation pipeline
  - 不引入 maestro 的 artifact registry 全量字段（仅复用"硬约束"思路，不复制其 TS 代码结构）
  - 不修改 stage 拓扑（仍是 PLAN → PLAN_REVIEW → IMPLEMENT → CODE_REVIEW → TEST → DONE）
  - 不引入 hook 系统
- 依赖:
  - Phase 5 已完成（leader 与 worker 已经习惯 TodoWrite milestone 与 keyword frontmatter，再上量化评分阻力较小）
  - shared-memory-v2 contract 已稳定（Phase 4 live-migration 已交付）
- 排序理由: validator schema 改造是有 blast radius 的（已有 19 个任务目录、validator 是工作流 gating 的最后一道屏障）；先在 Phase 5 让所有 task 习惯"TodoWrite 节奏 + spec keyword"以后，再在 Phase 6 把这些半正式约定升级为 schema-level 校验，现有 plan/test/spec 的迁移成本最低
- TODO:
  - [P6-T1] `quality-score-extension`：在 `scripts/validate-lite-artifacts.ps1` 增加 review run 4-dim 评分校验，verdict 与阈值（≥80 pass / 60-79 revise / <60 blocker）一致性检查；同时为已有 19 个任务目录的存量 review run 提供"无评分=旧格式，仍合法"的兼容路径
  - [P6-T2] `plan-readfirst-convergence`：plan.md schema 接受可选 `- read_first: [a, b, c]`（inline-array）与 `- convergence:` 段（list of criteria），由 validator 做语法校验；spec.md 模板与 plan.md 模板同步更新示例
  - [P6-T3] `wisdom-fourfile-alignment`：把现有 `.assistant/记忆候选/` 形态收敛为 learnings / decisions / conventions / issues 四文件 append-only 结构，并在 `skills/obsidian-memory/` 增补对应的写入约束文档
  - [P6-T4] `quality-score-rubric`：新建 `docs/工作流/quality-rubric.md`，明确 4-dim 各自的打分依据与典型示例（完全沿用 CCW Quality Gates 的字面定义，不发明新维度）
- 验收标准:
  - validator 在打开 `--quality` flag 时执行 4-dim 评分校验；不打开时维持现有行为（zero-regression on existing 19 task dirs）
  - 至少在 3 个新建 review run（plan-review / code-review）中实际录入 4-dim 评分并通过 validator
  - plan.md 模板示例包含 `read_first:` 与 `convergence:` 用法说明，且 `docs/tasks/shared-memory-v2-optimization/plan.md` 等已有任务无需被迫迁移
  - `.assistant/记忆候选/` 在迁移完成后只剩 4 个固定文件名，且每个文件 git history 显示只 append（无 delete / no rewrite）
  - `docs/工作流/quality-rubric.md` 提供至少 4 段示例（每个 dim 各 1 段），并在 plan-review / code-review skill 文档中被显式引用
- 回滚:
  - validator 改造采用 flag 形式（`--quality` opt-in），回滚时把 flag 默认关闭即可让所有 task 恢复旧行为
  - plan.md schema 扩展为可选字段，未启用时全 PASS；回滚等同于"保留字段定义、停止建议使用"
  - wisdom 4-file 迁移如出问题，可临时把 `.assistant/记忆候选/` 改回单文件 append-only 模式，记录漂移到 wisdom/issues.md 后再修
- 风险:
  - 4-dim 评分客观性是 CCW 痛点之一；rubric 落地时若示例不充分，会出现 reviewer 之间分歧
  - `read_first:` 字段如果与 IMPLEMENT 实际读取行为脱钩，会沦为"摆设清单"；建议同时在 review skill 增补"verifier 必须按 read_first 抽查"的协议（含在 P6-T2 中）
- 来源:
  - P6-T1 ← CCW A5（Quality Gates 4-dim score，`team-coordinate/specs/quality-gates.md`）
  - P6-T2 ← maestro recommendation #1（`maestro-flow-analysis.md` 第 3.1 节第 1 条「任务 schema 的硬约束：`read_first`、可验证 `convergence.criteria`、禁止模糊 action」，亦对应同文件第 2.1.A 节「任务定义模板的强约束字段」，源出 `templates/task.json` + `workflows/plan.md`）
  - P6-T3 ← CCW A4（wisdom 4-file dirs：`team-coordinate/specs/knowledge-transfer.md` 第 1 节）
  - P6-T4 ← CCW A5（同 P6-T1，rubric 直接复用其字面定义）

### Phase 7 — 运行时挂钩与艺术品声明（中等-较高风险 / 引入轻量 hook）

- 目标: 把 CCW 在长会话保护与渐进式 skill 加载方面的工程经验，以最克制的方式接入 harness-lite，缓解"长 IMPLEMENT 接近 context 上限被压缩"和"大型 skill SKILL.md 一次加载浪费 context"两个内生问题；同时把 maestro 的 artifact registry "声明任务输出 artifact" 思路落到 plan.md，方便交接
- 范围:
  - PreCompact-style checkpoint hook：在 leader / worker 临近 context 上限时主动调用 stage 推进或 wisdom append 落盘（不引入 long-running daemon，仅在每个 stage 结束的 callback 内做检查）
  - 大型 skill 渐进加载：将 SKILL.md ≥ 600 行的 skill（如 workflow-team、plan）拆出 `phases/<phase>.md` 子文件，主 SKILL.md 仅做导航（参考 CCW `workflow-plan/SKILL.md`）
  - plan.md schema 进一步扩展：可选 `artifacts:` 段，用 inline-array 显式声明本任务产出的所有 artifact 路径（继承 maestro artifact registry 思路，但只做"声明"不做"中央 registry"）
- 非目标:
  - 不引入 CCW 的 SessionStart / Stop / UserPromptSubmit 等全套 hook；只复用 PreCompact 单一检查点
  - 不引入中央 artifact registry 服务、不引入 `state-schema.ts` 之类的 TS 数据层
  - 不实现 chain_loader / FlowExecutor / QueueScheduler 等 runtime 组件
  - 不允许 hook 修改 vault 文件之外的任何外部状态（保持 vault-as-truth-source）
- 依赖:
  - Phase 6 已落地（4-dim 评分与 read_first/convergence schema 稳定，hook 才有可量化的"是否已收敛"判据）
  - Phase 5 的 TodoWrite milestone 已被广泛使用，hook 才能在 milestone 边界精确插入
- 排序理由: 引入任何 hook（即使是最克制的 PreCompact）都意味着 ABI 变化与 mutex 协议；放在最后，可以在 Phase 5/6 已经把"协作约定"和"质量门"调好之后，再让 hook 来增强而非替代既有约定；如果中途发现 hook 风险超预期，可以推迟到 Phase 8 而不影响前两阶段交付
- TODO:
  - [P7-T1] `precompact-checkpoint-hook`：在 `skills/orchestrator/` 与 `skills/workflow-team/` 增加"context 临近上限时主动 commit pending wisdom / 调用 advance-stage 持久化当前进度"的协议；实现在 leader 端通过 stage callback 自检（不引入新 daemon）；hook 仅追加 vault 文件，禁止任何 mutate
  - [P7-T2] `phase-loading-large-skills`：把 ≥ 600 行的 skill SKILL.md（候选：workflow-team、plan）按 PLAN/IMPLEMENT/REVIEW 阶段拆出 `phases/<phase>.md`，主 SKILL.md 改为导航 + on-demand load 说明
  - [P7-T3] `plan-artifacts-declaration`：plan.md schema 接受可选 `- artifacts: [path1, path2, ...]`（inline-array），declaration-only，不做交叉校验；validator 仅检查格式
  - [P7-T4] `precompact-mutex-protocol`：在 `docs/工作流/` 新增 `single-writer-precompact.md`，把 PreCompact hook 与单写者契约的兼容协议固化（关键约束：hook 只能 append、且必须先持有 stage 推进锁）
- 验收标准:
  - PreCompact hook 在两次实际长会话中触发，每次都只产生 wisdom append + stage advance，git diff 中无任何 mutate 操作
  - workflow-team / plan 拆分后，主 SKILL.md ≤ 200 行；按需加载的 phase 子文件总和与拆分前内容等价（`git diff --stat` 行数差 ≈ 0）
  - 至少 3 个新任务在 plan.md 中显式声明 `artifacts:`，并通过 validator
  - `single-writer-precompact.md` 明确"hook 必须先 cooperative-yield 给 stage 推进锁"，并在 plan.md / shared-memory-v2 contract 文档中被双向引用
- 回滚:
  - PreCompact hook 是协议性质（leader 自检），不是注册到 Claude Code 内核的 hook；回滚等同于把 skill 中的"自检条款"改回 advisory-only
  - phase-loading 拆分如出现 skill 行为漂移，可 `git revert` 单条 commit 把内容合回单文件 SKILL.md
  - `artifacts:` 字段仍是可选，回滚时停止填写即可
- 风险:
  - PreCompact 检查点必须严格守住 vault 单写者；如果 hook 触发时碰撞到正在写入的 stage 推进，可能产生 partial write（P7-T4 的 mutex 协议必须先于 P7-T1 落地）
  - 大型 skill 拆分会增加 leader 推断当前正在执行哪个 phase 的负担；需要在主 SKILL.md 顶部的导航段写清"何时加载哪段"
  - `artifacts:` 若无 verifier 抽查，会和 `read_first:` 一样退化成摆设；接受此风险，本 Phase 仅做声明，不做交叉校验
- 来源:
  - P7-T1 ← CCW B3（PreCompact checkpoint hook，`ccw/src/core/hooks/recovery-handler.ts` + `ccw/docs/hooks-integration.md`）
  - P7-T2 ← CCW A3（phases/ progressive loading，`workflow-plan/SKILL.md`）
  - P7-T3 ← maestro（artifact registry 思路，`maestro-flow-analysis.md` 推荐项 #2，简化为"声明 only"）
  - P7-T4 ← endogenous + CCW B3（hook 与 vault 单写者契约的兼容必须本仓库自己设计）

### 暂缓清单（Phase 5-7 不引入）

- 来自 CCW，整段暂缓:
  - C1 WebSocket dashboard / 前端可视化（与 vault-as-truth-source 冲突）
  - C2 sqlite 持久 memory + vector embedding（引入额外 runtime，违反"git 可审"）
  - C3 QueueSchedulerService + 三级 session pool（harness 当前并发度不需要）
  - C4 a2ui / PTY pool（无对应使用场景）
  - C5 MCP core_memory（与 vault 4 层结构语义重叠）
  - C6 22-agent 拓扑（harness-lite 5 角色已饱和，超过会引起角色边界模糊）
  - C7 Soft Enforcement Stop（B4，依赖 Claude Code 内核 hook 注册，与 Phase 7 的 cooperative PreCompact 形态不一致）
  - B1 plan two-layer artifact（与 plan.md 当前 Clarification + Plan 双段冗余）
  - B2 Team v2 dynamic role-spec topology（harness 5 角色静态映射已稳定）
  - B5 chain_loader（依赖 FlowExecutor runtime）
  - B6 memory consolidation pipeline（依赖 sqlite 与 embedding 服务）
- 来自 maestro，整段暂缓:
  - 多套并行运行时共存（`.maestro/` + `.team/` + `.commander/` + `collab/`）
  - wave-based 并行执行调度器（`execution-scheduler.ts` + `wave-executor.ts`）
  - 全量 commander 决策日志（`.commander/decisions.jsonl`）
  - 文档与代码双维护（doc/code dual maintenance）
  - 对外可视化 dashboard 与 backward-compat 兼容层
- 暂缓的统一原因: 上述项要么与 vault-as-truth-source 冲突，要么需要新建运行时组件（违反 git 可审），要么 ROI 显著低于 Phase 5-7 已选项；如果未来出现明确驱动场景，再走单独 PLAN 任务重新评估，不在本路线图内

## Verification

- `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId workflow-optimization-roadmap`
- `git log --oneline -- docs/tasks/workflow-optimization-roadmap/`
- `git diff --stat HEAD~1 -- docs/tasks/`
- `Select-String -Path docs/tasks/workflow-optimization-roadmap/plan.md -Pattern '^### Phase [567]'`
- `Select-String -Path docs/tasks/workflow-optimization-roadmap/plan.md -Pattern '^- 来源:'`
- `Select-String -Path docs/tasks/workflow-optimization-roadmap/plan.md -Pattern '暂缓清单'`
- 语义判据：第 1 条命令必须 PASS（0 Errors）；第 2 条确认本路线图以单 commit 形态进入仓库；第 3 条确认变更范围仅覆盖 `docs/tasks/workflow-optimization-roadmap/plan.md` 一个文件；第 4 条必须命中 3 行（Phase 5/6/7 各 1）；第 5 条必须命中 ≥ 3 行；第 6 条必须命中 1 行

## Risks

- 路线图仅是文档，不会自我执行；如果 leader 在 Phase 5 完成后未走 PLAN 任务把 Phase 6 的 TODO 拆解为独立任务，路线图会变成"装饰文档"。缓解：每个 TODO 的 ID（P5-T1 等）即未来子任务的 task-id 候选，leader 可直接 1-1 映射到 `docs/tasks/<task-id>/`
- Phase 6 的 validator 改造与 Phase 7 的 hook 接入都引入向后兼容风险；本路线图已通过"opt-in flag + 旧格式继续合法"的方式控制 blast radius，但实际落地任务仍需独立 PLAN_REVIEW 才能确保兼容性细节
- CCW / maestro 的机制编号锁定在当前两份分析文档（`docs/tasks/claude-maestro-workflow-benchmark/{claude-code-workflow-analysis.md,maestro-flow-analysis.md}`）；如果未来这两份分析被覆盖更新，本路线图的 source citation 可能失效。缓解：分析文档为 append-only，禁止 destructive 编辑（在 Phase 6 wisdom 4-file 落地时同步约束）
- 暂缓清单是当前判断；当外部需求变化（如真的需要并发跑 5+ task），应在该需求的独立 PLAN 任务里重评 deferred 项，不允许在本路线图内通过"补丁修改"方式偷偷把 deferred 项 re-promote
- 本 PLAN 在 leader 确认前为 draft 状态；status: draft 必须在 leader 显式回复"确认"后由后续 IMPLEMENT 任务（如有）改为 confirmed，不允许 worker 私改

## Plan Review

## Implementation Notes

## Code Review
