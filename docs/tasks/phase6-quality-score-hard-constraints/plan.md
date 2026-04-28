---
task_id: phase6-quality-score-hard-constraints
stage: PLAN
tool: claudecode
updated: 2026-04-28
---
# Phase 6 质量评分与任务硬约束（4 条 TODO）

## Clarification

- 验收标准:
  1. 落地路线图 `docs/tasks/workflow-optimization-roadmap/plan.md` 中 Phase 6 段的 4 条 TODO（quality-score-extension / plan-readfirst-convergence / wisdom-fourfile-alignment / quality-score-rubric），不多不少
  2. P6-T1 必须以 opt-in flag 形式扩展 `scripts/validate-lite-artifacts.ps1`：默认行为不变；zero-regression baseline 不再用硬编码计数，而是规则化定义为「IMPLEMENT 起始日仓库内 `docs/tasks/<tid>/plan.md` 已 PASS validator 的那批」。截至 2026-04-28 现场快照：`docs/tasks/` 下 22 个目录，其中 13 个含 `plan.md`，9 个 PASS、4 个既存 FAIL（`harness-aionui-workflow-alignment` / `phase2-workflow-descriptor` / `review-probe-crossmatch` / `review-probe-misordered`，均与本任务无关、不修复）；既存 FAIL 不在 zero-regression 范围内，9 个 PASS 必须在不打开 flag 时仍 PASS。打开 flag 时执行 4-dim 评分校验与 verdict 阈值一致性校验
  3. P6-T2 必须把 `read_first:` 与 `convergence:` 注册为 plan.md `## Plan` 段的可选字段，validator 仅做语法校验（inline-array 形式、convergence 至少一条 criterion），不做跨段引用 / 文件存在性 / 命令可执行性校验（那些归 review 抽查）
  4. P6-T3 必须给出"现状盘点 + 迁移目标 + 兼容映射"三段式方案：现状是 `运行时\记忆候选.md`（单文件）+ `运行时\记忆候选归档.md`，不是预期的 `记忆候选/` 目录；迁移目标已裁定为 `.assistant/运行时/` 下扁平 4 文件 `记忆-学习.md` / `记忆-决策.md` / `记忆-约定.md` / `记忆-问题.md`，与既有 `运行时\记忆候选.md` 同级，不新增顶层 vault layer
  5. P6-T4 必须新建 `docs/工作流/quality-rubric.md`，包含 4 个 dimension（completeness / consistency / accuracy / depth）的字面定义（沿用 CCW `team-coordinate/specs/quality-gates.md`，不发明新维度）+ 每 dim 至少 1 段示例（pass/revise/blocker 各 1 条 score 区间）；并在 `skills/review/SKILL.md` 中显式 cross-reference
  6. 4 条 TODO 互相之间通过 dependency 排序：P6-T4（rubric）必须先于或与 P6-T1 同步落地（因为 P6-T1 的阈值校验需要引用 rubric 的字面定义）；P6-T2 与 P6-T3 互相独立，可任意顺序
  7. 严守 vault-as-truth-source / 单写者 / git 可审三条根约束；不引入 dashboard、不引入 sqlite、不引入 vector embedding、不引入第二套并行 runtime、不引入 Phase 5 / Phase 7 任何 TODO 的实现
  8. validator `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId phase6-quality-score-hard-constraints` 必须 PASS

- 非目标:
  - 不扩到 Phase 5（auto-mode-propagation / todowrite-milestone-template / spec-keyword-frontmatter / long-session-recovery-checklist 已交付，不回锅）
  - 不扩到 Phase 7（PreCompact hook、phases/ 拆分、artifacts: 声明全部不在本 plan 范围）
  - 不重开 workflow-alignment（Phase 1-4）、shared-memory-v2、live-migration 任何主线讨论
  - 不修改 `.assistant/entry/advance-stage.ps1` 推进逻辑；不修改 stage 拓扑
  - 不引入新 hook（PreCompact 留给 Phase 7）；不引入 sqlite 持久化、vector embedding、memory consolidation pipeline
  - 不强制既有任务（无论当前 PASS 或 FAIL）回填 `read_first:` / `convergence:` / 4-dim 评分（仅 opt-in；validator 默认行为兼容旧格式）
  - 不发明新评分维度（rubric 必须直接复用 CCW 4 维度字面定义）
  - 不引入跨任务 wisdom 索引脚本（那是 Phase 8+ 工作）
  - 不修改 `agent-configs/profiles/*.yaml` 与 `agent-configs/workflows/harness-lite.yaml` 实体字段

- 受影响目录:
  - `scripts/validate-lite-artifacts.ps1`（新增 `-Quality` switch 与对应分支；既有 23 项 check 全保留）
  - `agent-configs/workflows/harness-lite.yaml`（仅在 `PLAN_REVIEW` / `CODE_REVIEW` stage 段下方追加 YAML 注释行说明 `-Quality` 何时启用；YAML 实体字段不动）
  - `skills/plan/SKILL.md`（在推荐骨架段新增 `## Plan` 顶部 metadata 块的 `read_first:` / `convergence:` 可选字段示例与语法说明）
  - `skills/review/SKILL.md`（新增 4-dim 评分录入说明 + cross-reference 到 rubric）
  - `skills/orchestrator/references/lite-writing-guide.md`（同步说明 plan.md 新可选字段，避免规范二源漂移）
  - `skills/obsidian-memory/SKILL.md`（新增 wisdom 4-类写入约束段；不替换既有 Read Order / Writeback 段）
  - `docs/工作流/quality-rubric.md`（新建文件 / 新建上级目录 `docs/工作流/`）
  - `.gitignore`（追加完整规则块：先 `!.assistant/运行时/` 放行目录条目以突破 `:21` `.assistant/*` 黑名单，再 `.assistant/运行时/*` 重建黑名单确保该目录其他文件仍受控，最后 4 条精确文件例外 `!.assistant/运行时/记忆-学习.md` / `!.assistant/运行时/记忆-决策.md` / `!.assistant/运行时/记忆-约定.md` / `!.assistant/运行时/记忆-问题.md` 让本任务新建的 4 个 wisdom 文件可受 git 审计；`.assistant/` 其他子目录与 `运行时/` 内既有 `记忆候选.md` / `记忆候选归档.md` / `收件箱.md` 等不受影响，详细机制见 P6-T3 范围段「`.gitignore` 例外（必须落地）」）
  - `.assistant/运行时/记忆-学习.md`（新建 append-only 文件，受 .gitignore 例外）
  - `.assistant/运行时/记忆-决策.md`（新建 append-only 文件，受 .gitignore 例外）
  - `.assistant/运行时/记忆-约定.md`（新建 append-only 文件，受 .gitignore 例外）
  - `.assistant/运行时/记忆-问题.md`（新建 append-only 文件，受 .gitignore 例外）
  - `docs/tasks/phase6-quality-score-hard-constraints/plan.md`（本文档）

- 回滚策略:
  - 4 条 TODO 全部独立 commit；任意一条可独立 `git revert` 而不影响其他三条
  - P6-T1 validator 改造采用 switch flag 形式，回滚时把 switch 默认值保持 `$false` 即可让所有 task 恢复旧行为
  - P6-T2 schema 扩展为 plan.md `## Plan` 段的可选字段，未启用时全 PASS；回滚等同于"保留字段定义、停止建议使用"
  - P6-T3 wisdom 迁移如出问题，可直接删除新建的 4 文件或目录，回到 `运行时\记忆候选.md` 单文件模型；漂移问题由后续任务记录到迁移完成后的 `issues` 文件
  - P6-T4 rubric 文档独立删除即可；`skills/review/SKILL.md` 中的 cross-reference 在 P6-T1 / P6-T4 同步回滚后失效不会破坏 validator
- ui: not-applicable

## User Confirmation
- status: draft

## Change Contract
- change_type: enhance
- affected_paths:
  - scripts/validate-lite-artifacts.ps1
  - agent-configs/workflows/harness-lite.yaml
  - skills/plan/SKILL.md
  - skills/review/SKILL.md
  - skills/orchestrator/references/lite-writing-guide.md
  - skills/obsidian-memory/SKILL.md
  - docs/工作流/quality-rubric.md
  - .gitignore
  - .assistant/运行时/记忆-学习.md
  - .assistant/运行时/记忆-决策.md
  - .assistant/运行时/记忆-约定.md
  - .assistant/运行时/记忆-问题.md

## Plan

### TODO P6-T1 — quality-score-extension（validator 4-dim 评分校验，opt-in）

- 范围:
  - 在 `scripts/validate-lite-artifacts.ps1` 新增 `-Quality` switch（PowerShell 风格，`[switch]$Quality`，命名已裁定为 `-Quality`，IMPLEMENT 时不得替换为 `-EnableQualityScore` 或其他名称）；默认 `$false`，保持当前 23 项 check 行为完全不变
  - 当 `-Quality` 打开时，扩展 `Assert-ReviewRuns`：每个 review run 的 body 内必须包含 4 行 `- score:` 子字段（completeness / consistency / accuracy / depth），每行格式 `- score.completeness: <0-100 整数>` 等；同时校验 verdict 与综合分阈值（≥80 全 pass，60-79 任一维度低于 60 触发 revise，<60 任一维度触发 blocker = 必须 revise）
  - 综合分计算约定为 4 维度算术平均，向下取整；rubric（P6-T4）固化此口径
  - 旧格式（无 `- score.*` 子字段）的 review run 在 `-Quality` 模式下视为"未录入评分"，输出 advisory Warning（不进入 Errors，不影响 PASS/FAIL）
  - 在 `agent-configs/workflows/harness-lite.yaml` 的 `PLAN_REVIEW` / `CODE_REVIEW` stage 段下方追加注释行（YAML 实体字段不动），说明 `-Quality` 何时启用（推荐：新任务自 P6 完成日起；旧任务 opt-in）
- 非目标:
  - 不修改既有 23 项 check 的任何行为（zero-regression baseline 见 Clarification 验收标准 #2；2026-04-28 现场快照为 13 个 plan.md 中 9 个 PASS）
  - 不引入新 frontmatter 字段
  - 不为 `Implementation Notes` run 添加评分（评分仅 review run 适用）
  - 不实现自动加权 / dimension 级权重配置（4 维度等权，写死在 rubric）
  - 不修改 `agent-configs/workflows/harness-lite.yaml` 的实体字段
- affected_paths:
  - `scripts/validate-lite-artifacts.ps1`
  - `agent-configs/workflows/harness-lite.yaml`（仅 YAML 注释段；实体字段不动）
- 验证:
  - `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId <旧任务任选>`（不带 `-Quality`）必须 PASS（与改造前结果完全一致）
  - `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId <旧任务任选> -Quality` 必须 PASS 且 Warnings 段输出"review run X 未录入 4-dim score"
  - 用临时 fixture 任务（带完整 4-dim score 的 review run）执行 `-Quality` 必须 PASS 且 Warnings 为 none
  - 用临时 fixture（评分 verdict 矛盾，例如 4 维全 50 但 verdict: pass）执行 `-Quality` 必须 FAIL 且 Errors 命中"verdict-score 不一致"
  - 对 zero-regression baseline（2026-04-28 现场快照：13 个 plan.md 中 9 个 PASS、4 个既存 FAIL 与本任务无关）在 `-Quality` off 模式下批量跑 validator，PASS / FAIL 集合必须与 IMPLEMENT 前完全一致（写一个一次性 check 脚本验证，不入库）
- 回滚: `git revert` 单条 commit；`-Quality` switch 与所有评分校验代码块一起消失；旧 23 项 check 不受影响
- 风险:
  - PowerShell 的 `[switch]` 在某些 v5 环境下行为差异（v7 已确认无问题，本仓库强制 v7）；缓解：在脚本顶部已有 `Set-StrictMode -Version Latest`，IMPLEMENT 时 verbose 检查 v7 行为
  - 综合分等权聚合在某些场景可能掩盖单维度严重不足；缓解：阈值规则中显式包含"任一维度 < 60 视为 blocker"，避免 60+60+60+59=59.75 算术平均逼近边界时被误判为 revise

### TODO P6-T2 — plan-readfirst-convergence（plan.md `## Plan` 段可选字段）

- 范围:
  - 扩展 validator 的 `Assert-PlanContract`：plan.md `## Plan` 段允许（可选）以 `- read_first: [path1, path2, ...]`（inline-array 语法，与 shared-memory-v2 `derived_from:` 同款约束）声明执行者必须先读的清单
  - 同段允许（可选）`- convergence:` 子项，下面缩进列出至少 1 条 `- <criterion>`；每条 criterion 必须可被 grep / 文件断言 / 命令验证，禁止"align with / keep consistent / ensure correctness"等模糊措辞
  - **schema 位置已裁定为 metadata-style**：`read_first:` / `convergence:` 必须出现在 `## Plan` section 段标题之后的顶部 metadata 块中（即在第一条普通 `- TODO …` bullet 之前），便于 validator 顺序解析；IMPLEMENT 时不得允许它们与普通 bullets 混杂
  - validator 仅做语法校验：（a）`read_first` 若出现必须 inline-array；（b）`convergence` 若出现必须至少 1 条非空 criterion；（c）字段缺省视为合法；（d）若出现位置不在 `## Plan` 段顶部 metadata 块（被普通 bullets 隔开），视为格式错误
  - 在 `skills/plan/SKILL.md` 推荐骨架段新增 1 段说明 + 示例；在 `skills/orchestrator/references/lite-writing-guide.md` 同步追加 1 段，避免规范二源漂移
  - 在 `skills/review/SKILL.md` PLAN_REVIEW 重点段新增 1 行："reviewer 必须按 `read_first:` 抽查 IMPLEMENT 是否真读了，按 `convergence:` 抽查每条 criterion 是否可执行"
- 非目标:
  - 不强制既有任务回填 `read_first:` / `convergence:`（无论当前 PASS 或 FAIL 都不强制回填）
  - 不做跨段引用校验（例如 `convergence` 中引用的命令是否真的可执行 — 留给 reviewer 抽查）
  - 不做 path 存在性校验（`read_first` 中的路径不必存在；可能是计划中即将创建的路径）
  - 不引入 nested YAML（如 `convergence: { criteria: [...] }`）；只用 markdown bullet 形式
  - 不为 `read_first` / `convergence` 提供执行器或自动 grep 工具（那是 Phase 8+ 工作）
- affected_paths:
  - `scripts/validate-lite-artifacts.ps1`
  - `skills/plan/SKILL.md`
  - `skills/orchestrator/references/lite-writing-guide.md`
  - `skills/review/SKILL.md`
- 验证:
  - 用临时 fixture（含合法 `read_first: [a, b]` + 3 条 `convergence` criteria）跑 validator 必须 PASS
  - 用 fixture（`read_first` 写成 block-list `- a\n- b` 而非 inline）跑 validator 必须 FAIL 并提示"read_first 必须 inline-array"
  - 用 fixture（`convergence:` 后无任何 criterion 或仅写 "TBD"）跑 validator 必须 FAIL
  - zero-regression baseline 集合（2026-04-28 现场快照：9 个 PASS plan.md，均无 `read_first` / `convergence`）跑 validator 后 PASS 集合不变；4 个既存 FAIL 也保持 FAIL（验证语义而非计数）
  - `Select-String -Path skills/plan/SKILL.md -Pattern 'read_first'` 命中 ≥ 1，`Select-String -Path skills/review/SKILL.md -Pattern 'read_first'` 命中 ≥ 1
- 回滚: `git revert` 单条 commit；validator 与三处 SKILL.md 文档同步退回；任何已写入两字段的 plan.md 仍合法（validator 不读它们也不报错）
- 风险:
  - `read_first` 与 IMPLEMENT 实际读取行为脱钩 → 沦为摆设。缓解：`skills/review/SKILL.md` 的"reviewer 抽查"条款必须落地，不能只挂在 plan 文档
  - `convergence` criterion 写得太宽泛仍能通过语法校验。缓解：rubric（P6-T4）的 accuracy 维度示例必须包含"convergence 是否可被 grep / 命令验证"作为评分判据，把语义判断推给 reviewer

### TODO P6-T3 — wisdom-fourfile-alignment（4-类 wisdom append-only 写入约束）

- 范围:
  - **现状盘点**: 当前 `.assistant/` 顶层为 `工作流/模板/配置/运行时/` 四目录，**无** `记忆候选/` 目录；与 wisdom 相关的现存文件为 `运行时\记忆候选.md`（单文件，append-only 性质）+ `运行时\记忆候选归档.md`（archive） + `运行时\收件箱.md`（inbox）。路线图原文"把现有 `.assistant/记忆候选/` 形态收敛为 4 文件"基于不准确的现状假设，迁移目标已由 leader 裁定为下方"迁移目标"段所述方案
  - **迁移目标（已裁定）**: 在 `.assistant/运行时/` 下扁平新建 4 个 append-only 文件 `记忆-学习.md` / `记忆-决策.md` / `记忆-约定.md` / `记忆-问题.md`，与既有 `运行时\记忆候选.md` 同级；不新增顶层 `记忆候选/` 目录、不引入新的 vault layer，与 shared-memory v2 已建立的 4 层结构（`运行时/工作流/配置/模板`）保持完全一致；保留 `运行时\记忆候选.md` 作为 inbox 入口，不动其语义（兼容映射：inbox 经 triage 后分流到 4 类目标文件）
  - **文件命名与映射**：`记忆-学习.md` ← learnings（跨任务可复用知识）；`记忆-决策.md` ← decisions（不可逆设计选择）；`记忆-约定.md` ← conventions（命名 / 路径 / 协议规范）；`记忆-问题.md` ← issues（已知缺陷待修）。中文文件名与现有 `运行时\记忆候选.md` 等命名风格统一；与 P6-T4 rubric 的英文 dimension 名属于不同语义层，不互相绑定
  - **写入约束**: 在 `skills/obsidian-memory/SKILL.md` 新增"wisdom 4-类写入约束"段，明确：（a）4 文件均为 append-only，禁止 delete / rewrite 旧条目；（b）每条 entry 必须以 `### YYYY-MM-DD HH:mm · <task-id> · <author>` 标题打头；（c）单写者（同一时刻只有当前入口 host 可追加）；（d）从 inbox 分流时仅 `Copy` 不 `Move`（保留原始 inbox 时间线）
  - **不动既有路径**: `运行时\记忆候选.md` / `运行时\记忆候选归档.md` / `运行时\收件箱.md` 路径与语义保留；既有 `skills/obsidian-memory/scripts/*.ps1` 脚本不修改
  - **`.gitignore` 例外（必须落地）**: 当前 `.gitignore` 行 21 `.assistant/*` + 行 22 `!.assistant/工作流/` + 行 23 `.assistant/工作流/*` + 行 24 `!.assistant/工作流/长会话恢复.md` 会让本任务新建的 4 个 `运行时/记忆-*.md` 文件被吞掉、无法进入 git 审计面。IMPLEMENT 时必须在 `.gitignore` 末尾追加 4 条 negate 规则（精确到文件名，不用通配符以避免意外放宽）：`!.assistant/运行时/` 一条目录入口豁免 + `.assistant/运行时/*` 黑名单 + 4 条 `!.assistant/运行时/记忆-学习.md` / `!.assistant/运行时/记忆-决策.md` / `!.assistant/运行时/记忆-约定.md` / `!.assistant/运行时/记忆-问题.md`；既有 `运行时\记忆候选.md` / `运行时\记忆候选归档.md` / `运行时\收件箱.md` 仍受 `.assistant/运行时/*` 黑名单覆盖（保持现状未受控），`.assistant` 其他路径（`配置/`、`模板/`、`运行时/` 其他文件）规则不放宽
- 非目标:
  - 不强制立即把历史 inbox 内容分流到 4 文件（迁移可在 Phase 6 落地后逐步进行）
  - 不修改 `triage-runtime-inbox.ps1` / `archive-memory-candidates.ps1` 等既有脚本
  - 不引入新脚本（自动分流脚本归 Phase 8+）
  - 不引入跨 vault 索引（每个项目自己维护 4 文件）
  - 不为 4 文件设置 schema validator（仅文档约束 + git history 抽查）
- affected_paths:
  - `skills/obsidian-memory/SKILL.md`
  - `.gitignore`（追加 4 条 wisdom 文件 negate 规则；其他 `.assistant/` 内容覆盖范围不变）
  - `.assistant/运行时/记忆-学习.md`
  - `.assistant/运行时/记忆-决策.md`
  - `.assistant/运行时/记忆-约定.md`
  - `.assistant/运行时/记忆-问题.md`
- 验证:
  - `Select-String -Path skills/obsidian-memory/SKILL.md -Pattern 'wisdom 4 类|记忆-学习|记忆-决策|记忆-约定|记忆-问题'` 命中 ≥ 4 次（覆盖 4 文件名）
  - 4 文件初始化（每个文件至少 1 个 placeholder header `### 2026-04-28 ··· · phase6-init · system`）后，`git log --follow` 单文件历史显示仅 1 次 add
  - 任意 1 个 dummy entry 写入后，再执行第二次 append（不 rewrite 第一次），git diff 必须仅显示新增行（无修改 / 无删除）
  - `运行时\记忆候选.md` 与 `运行时\记忆候选归档.md` 在 IMPLEMENT 前后字节相同（用 `Get-FileHash` 比对）
  - `Test-Path` 4 个新文件路径必须全部为 True；`.assistant/` 顶层目录列表与改造前一致（仍是 `工作流/模板/配置/运行时/`，无新增顶层目录）
  - `git check-ignore -v .assistant/运行时/记忆-学习.md` 必须返回非命中（exit code 1）；同理 `记忆-决策.md` / `记忆-约定.md` / `记忆-问题.md` 4 个新文件均不被忽略
  - `git check-ignore -v .assistant/运行时/记忆候选.md` 仍返回命中（确认其他 `.assistant/运行时/` 内容仍受 ignore，规则未被意外放宽）
  - `git status` 在 4 文件初始化后必须把它们识别为 untracked / staged 候选（不能被 ignore 吞）
- 回滚: 删除 `.assistant/运行时/记忆-学习.md` / `记忆-决策.md` / `记忆-约定.md` / `记忆-问题.md` 4 文件 + 撤销 `.gitignore` 末尾追加的 negate 块即可回到当前现状（顶层结构无变更）；`skills/obsidian-memory/SKILL.md` 单条 revert
- 风险:
  - 4 文件初期空置会让 leader / worker 不知何时往哪写；缓解：写入约束段必须给"何时写哪个文件"的最小判别表（学习 = 跨任务复用知识，决策 = 不可逆设计选择，约定 = 命名 / 路径 / 协议规范，问题 = 已知缺陷待修）
  - `Copy 不 Move` 的策略会让 inbox 长期膨胀；接受此风险，inbox 容量管理归 Phase 8+
  - 与既有 `运行时\记忆候选.md` 单文件入口共存期间，可能出现"为何不直接 append 到 4 文件而要先经 inbox"的 onboarding 困惑；缓解：写入约束段开头明确"inbox 是无确认条目的暂存区，4 文件只接受 triage 后已认定的稳定条目"

### TODO P6-T4 — quality-score-rubric（4-dim 评分细则文档）

- 范围:
  - 新建 `docs/工作流/quality-rubric.md`（含新建上级目录 `docs/工作流/`）
  - 文档结构：① 4 dimension 字面定义（直接引用 CCW `team-coordinate/specs/quality-gates.md` 的英文术语 + 中文短注释，不发明新维度）；② 阈值与综合分计算口径（≥80 / 60-79 / <60，4 维度等权算术平均，单维度 < 60 直接 blocker）；③ 每 dim 至少 3 段示例（pass / revise / blocker 区间各 1 段，给出 score + 文字 rationale）；④ 与 P6-T1 validator 行为的 cross-reference（"validator -Quality 模式按本文 ② 节阈值校验"）；⑤ 与 P6-T2 `convergence:` 的 cross-reference（accuracy 维度的"是否可被 grep / 命令验证"作为评分判据）
  - 同步在 `skills/review/SKILL.md` 末尾新增"评分依据"段，单段引用 rubric 文档（不重复定义阈值，避免规范二源漂移）
  - 文档语言以中文为主，4 dimension 名称保留英文（`completeness` / `consistency` / `accuracy` / `depth`）便于与 CCW 原文对齐
- 非目标:
  - 不发明新 dimension（若 rubric 落地后真出现 CCW 4 维不够覆盖的场景，作为单独任务在 Phase 8+ 评估）
  - 不修改 `team-coordinate/specs/quality-gates.md`（属于 CCW 仓库，不在 harness 写权限内）
  - 不在本文档定义 dimension 级权重（4 维等权写死在 rubric 与 validator）
  - 不为 rubric 提供自动评分工具（评分仍是 reviewer 人工判断）
- affected_paths:
  - `docs/工作流/quality-rubric.md`（新建）
  - `skills/review/SKILL.md`
- 验证:
  - `Test-Path 'docs/工作流/quality-rubric.md'` 必须为 True
  - `Select-String -Path docs/工作流/quality-rubric.md -Pattern 'completeness|consistency|accuracy|depth'` 4 个名称分别命中 ≥ 1 次
  - `Select-String -Path docs/工作流/quality-rubric.md -Pattern '≥80|60-79|<60'` 阈值标记命中 ≥ 1 次
  - `Select-String -Path skills/review/SKILL.md -Pattern 'quality-rubric\.md'` 命中 ≥ 1 次（确认 cross-reference 落地）
  - 文档总行数 ≤ 250 行（避免 rubric 膨胀；超出由后续任务单独处理）
- 回滚: 删除 `docs/工作流/quality-rubric.md` + `git rm -r docs/工作流/`（若空目录）；`skills/review/SKILL.md` 中的"评分依据"段单条 revert
- 风险:
  - rubric 示例若过于具体会让 reviewer 套模板而非真做判断；缓解：每个示例段必须给出"为何属于此 score 区间"的 rationale，不仅给数字
  - rubric 与 validator 阈值漂移风险（同一阈值在两处声明）；缓解：validator 代码注释必须显式回指 rubric 文档路径，IMPLEMENT 时设为强约束

## Verification

- `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId phase6-quality-score-hard-constraints`
- `git diff --stat HEAD~1 -- scripts/ skills/ docs/工作流/ .assistant/`
- `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern '\[switch\]\$Quality'`
- `Select-String -Path skills/plan/SKILL.md skills/review/SKILL.md skills/orchestrator/references/lite-writing-guide.md -Pattern 'read_first|convergence'`
- `Select-String -Path skills/obsidian-memory/SKILL.md -Pattern '记忆-学习|记忆-决策|记忆-约定|记忆-问题'`
- `Test-Path 'docs/工作流/quality-rubric.md'`
- `Get-Content docs/工作流/quality-rubric.md | Measure-Object -Line`
- `git check-ignore -v .assistant/运行时/记忆-学习.md .assistant/运行时/记忆-决策.md .assistant/运行时/记忆-约定.md .assistant/运行时/记忆-问题.md`
- 语义判据：第 1 条 validator 必须 PASS（0 Errors）；第 2 条 git diff 必须只覆盖本 plan 列出的 affected_paths（无任何 `docs/tasks/<其他>/`、`agent-configs/profiles/`、`运行时/` 已有文件改动）；第 3 条命中 1 行（确认 -Quality switch 落地）；第 4 条命中 ≥ 4（plan/review/lite-writing-guide 均覆盖）；第 5 条命中 4 文件名；第 6 条 True；第 7 条总行数 ≤ 250；第 8 条对 4 个 wisdom 文件均返回 exit code 1（不被 .gitignore 命中），证明可审计变更面落地

## Risks

- 4 条 TODO 之间存在弱依赖：P6-T4（rubric）必须先于或与 P6-T1（validator -Quality）同步落地，否则 -Quality 模式下 reviewer 没有阈值依据；IMPLEMENT 时建议 commit 顺序 P6-T4 → P6-T1 → P6-T2 → P6-T3
- P6-T1 的 4-dim 评分客观性是 CCW 原生痛点；rubric 若示例不足会导致 reviewer 之间分歧；本任务 P6-T4 验证项已要求每 dim ≥ 3 段示例（pass/revise/blocker），但实际充分性只能在 rubric 投入使用 1-2 个 review 周期后回顾
- P6-T2 的 `read_first` / `convergence` 与 IMPLEMENT 实际行为脱钩仍是开放问题；本 plan 已通过"reviewer 抽查"条款（落入 P6-T2 范围 + P6-T4 rubric accuracy 维度示例）做缓解，但若 reviewer 不真做抽查，字段会沦为装饰；接受此风险，进一步执行抽查由后续 review 任务承担
- P6-T3 wisdom 4 文件初期空置 + Copy 不 Move 策略会让 inbox 膨胀；本 Phase 不引入容量管理，由 Phase 8+ 任务承担
- validator 改造的 PowerShell switch 兼容性已限定 v7（本仓库 baseline）；若未来需支持 v5 环境，单独评估
- 已裁定 1（P6-T3 路径选择）：选项 **B** — 在 `.assistant/运行时/` 下扁平新建 4 个 md 文件（`记忆-学习.md` / `记忆-决策.md` / `记忆-约定.md` / `记忆-问题.md`），与既有 `运行时\记忆候选.md` 同级。理由：不新增顶层目录，保持 shared-memory v2 已建立的 4 层结构（`运行时/工作流/配置/模板`）不变；选项 A 会引入第 5 个顶层 layer 与现状冲突；选项 C 把约束停留在文档而无实体落盘，会与 P6-T2 / P6-T4 的 cross-reference 同步失败。IMPLEMENT 时 P6-T3 的 changed 字段必须显式写"采用选项 B"
- 已裁定 2（P6-T1 switch 命名）：采用 **`-Quality`**。理由：与路线图原文（quality-score-extension）和 PowerShell 轻量 flag 风格（短名 + 形容词起头）一致；动词起头的 `-EnableQualityScore` 在 v7 `[switch]` 行为下并无优势，且更冗长。IMPLEMENT 时 `[switch]$Quality` 命名锁定，不得替换
- 已裁定 3（P6-T2 schema 位置）：采用 **`## Plan` 段顶部 metadata-style** — `read_first:` / `convergence:` 必须出现在 `## Plan` 段标题之后、第一条普通 `- TODO …` bullet 之前的顶部 metadata 块。理由：最利于 validator 顺序解析，避免与普通 bullets 混杂导致正则误判；与 frontmatter / Change Contract 的 metadata-first 风格一致。IMPLEMENT 时 validator 必须把"位置不在顶部 metadata 块"列为格式错误（已写入 P6-T2 范围第 (d) 条）
- 已裁定 4（P6-T4 文档语言）：采用 **中文为主 + 4 dimension 名保留英文**（`completeness` / `consistency` / `accuracy` / `depth` 不翻译）。理由：与本仓库既有中文文档习惯一致，同时保留与 CCW `team-coordinate/specs/quality-gates.md` 原文的术语对照；全中文翻译会引入"完整性 / 一致性 / 准确性 / 深度"四个翻译歧义点，反而增加二源漂移风险。IMPLEMENT 时 rubric 文档段落用中文，dimension 标题与 validator 注释中的字段名保留英文

## Plan Review

## Implementation Notes

## Code Review
