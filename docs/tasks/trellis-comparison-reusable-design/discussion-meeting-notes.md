---
task_id: trellis-comparison-reusable-design
artifact: discussion-meeting-notes
updated: 2026-06-22
status: final
synthesizer: opus-architect
synthesis_task: b1bf4bb7
discussion_inputs:
  - 9b7f92f2  # opus-architect：总体架构判断
  - 0a7db87f  # harness-analyst：现有协议兼容性评估
  - 3589b60d  # trellis-analyst：Trellis 能力映射与取舍
  - e0a20cdd  # gap-reviewer：基于 gap-analysis 的补充审阅
---

# 探讨会纪要：Trellis 可复用设计改造方向

> 本纪要综合四路讨论输入与既有事实源（`trellis-reusable-design.md`、`gap-analysis.md`、`trellis-source-based-corrections.md`），形成方向性判断，不含源码实现。stage truth 仍只看 `plan.md` frontmatter。

## 1. 参会角色与讨论输入来源

| 角色 | 讨论输入任务 | 视角 | 形态 |
|---|---|---|---|
| opus-architect | 9b7f92f2 | 总体架构判断：方向认可与边界 | 直接结论 |
| harness-analyst | 0a7db87f | dev-harness 现有协议兼容性评估 | 直接结论 |
| trellis-analyst | 3589b60d | Trellis 能力映射与取舍评估 | 直接结论 |
| gap-reviewer | e0a20cdd | 基于既有 gap-analysis 的补充审阅 | 以 `gap-analysis.md`（G1–G6）为实体输入 |

支撑事实源：
- `docs/tasks/trellis-comparison-reusable-design/trellis-reusable-design.md`（用户刚补充，status: final）
- `docs/tasks/trellis-comparison-reusable-design/gap-analysis.md`（gap-reviewer，status: final）
- `docs/tasks/trellis-comparison-reusable-design/trellis-source-based-corrections.md`（基于本地源码快照 `D:/data/Trellis-main @ 2026-06-18` 的勘误，status: draft）
- `AGENTS.md` 共享内存与单写者协议

## 2. 会议共识

四路输入高度一致，无人提出推翻方向的意见：

1. **认可当前改造方向。** 只吸收 Trellis 的机制能力（task entity、context taxonomy、finish/checklist、artifact drift advisory），不搬目录与运行时。
2. **唯一阶段真相源不变。** `docs/tasks/<task-id>/plan.md` frontmatter 继续是唯一 stage truth；`.assistant/运行时/*` 只做 mirror / derived pointer。
3. **借鉴一律先以轻量形态落地。** optional artifact、review/test 写作规则、validator warning（advisory）优先；dogfood 稳定后才评估 hard gate，不阻断旧任务。
4. **拒绝引入第二套真相源。** 不引入 `.trellis/`、不让 `task.json.status` / active task pointer / workflow-state breadcrumb / UI / service 参与 stage 判定。
5. **保住 dev-harness 的相对优势。** 独立可否决的 PLAN_REVIEW / CODE_REVIEW + 数值 rubric + append-only 留痕，比 Trellis 的自检自修更可审，借鉴中不得稀释。
6. **P1 首发达成一致：** `finish-boundary-checklist` + `artifact-drift-advisory` 改面最小、ROI 最高、直接补「`artifacts:` 声明与真实产出脱钩」的证据闭环。

## 3. 仍有分歧或需确认的问题

整体是「定级与边界细化」分歧，非方向分歧：

- **Q1（最大代差的处理形态）。** 勘误 A 指出 Trellis 的上下文注入是「主动注入运行时引擎」而非分类口径。trellis-analyst 与 opus-architect 一致认为：dev-harness 当前只能吸收其 manifest / advisory 形态，phase-aware 自动注入引擎须 defer 到 host(Codex/Claude) hook 能力可行性评估，**不能直接并入主协议**。需会议拍板：是否单列 `trellis-context-injection-feasibility`（建议 P2），结论出来前不写任何自动注入代码。
- **Q2（context manifest 的越界风险）。** harness-analyst 提示：context manifest 若自动覆盖 stage skill lazy-loading 或 workflow descriptor `skills_whitelist`，会形成第二套上下文真相源。需确认 manifest 只做 advisory、不自动注入。
- **Q3（task entity 字段黑名单）。** 三方一致要求 task entity 禁含 stage / status / verdict / tool / current pointer，但黑名单需在设计任务里显式成文，避免顺手抄入 Trellis 的 `current_phase` / `next_action`。
- **Q4（worktree + PR 自动化）。** trellis-analyst 指出文档/实现漂移：本地 `workflow.md` 提到 `create-pr`，而 `task.py` argparse 实测无 `create-pr` 子命令。结论：task entity 可预留 `worktree_path` / `pr_url` / `commit` 字段，但 PR 自动化不排高优先级，整体 defer。
- **Q5（artifact 增殖节奏）。** opus-architect 提示：task-entity / subtasks / case / session 若一次性铺开，会重演「这条信息写哪」的判断漂移。需确认首发只放行 1–2 项并 dogfood。

## 4. 最终建议方向

### 4.1 吸收（adopt / adapt）

| 项 | 形态 | 边界 |
|---|---|---|
| Finish boundary checklist | review/test 写作规则 | 仅在 `skills/test`、`skills/review` 增 handoff 抽查（artifact 存在性、drift、follow-up、记忆/spec 沉淀判断），不新增 stage |
| Artifact drift advisory | validator warning 或独立脚本 | 比对 `artifacts:` / `affected_paths` / `git diff --name-only` / 文件存在性；先 warning，不阻断旧任务 |
| Task entity artifact | 可选 `task-entity.yaml/md`，在 `plan.md artifacts:` 声明 | 只承载 owner/priority/branch/base_branch/pr_url/parent/children/related_files/meta(issue-tracker)；预留 worktree_path/commit；**禁含 stage/status/verdict/tool/current_phase/next_action** |
| Context manifest advisory | 可选 manifest（file + reason），借鉴 implement.jsonl/check.jsonl | 仅提示 IMPLEMENT/CODE_REVIEW/TEST 必读上下文；**不自动注入**，不覆盖 lazy-loading / skills_whitelist |
| Context taxonomy 分类口径 | 写作规则（global/workspace/task/session 映射到现有 `.assistant` 分层） | 只统一「该写哪」的判断，不新建目录 |
| Role names as review lenses | review 视角（research/implement/check） | 仅作语义 lens，不复制成 agent runtime |

### 4.2 不吸收（reject / defer）

- **reject：** `.trellis/` 目录、`task.py` lifecycle runtime、session active task pointer、workflow-state 第二状态机、UI/service 作为真相源、第二套 memory/spec hierarchy、Trellis 多平台 sub-agent/channel/worker runtime。
- **defer：** dashboard/timeline/graph UI、queue/scheduler/active task runtime、LLM wiki、auto finish/commit/archive、spec 自动晋升 pipeline、worktree+PR 自动化、phase-aware 自动注入引擎、任何 hard gate。

### 4.3 必须坚守的边界（5 条硬约束）

1. stage / verdict / current tool 永远只由 `plan.md` frontmatter + append-only review/test runs 决定；任何新 artifact 禁含这三类字段。
2. 不引入 `.trellis/` 第二任务根；现有三重入口（`docs/tasks`、`.assistant/运行时/tasks`、team board）已是上限。
3. 所有 stage 推进与非 append 写回继续只走 `advance-stage.ps1`；不让 `task.json.status` / pointer / breadcrumb / auto-finish 绕过 validator 与单写者模型。
4. 长期记忆 / spec 晋升保持「先入收件箱再 promote/triage」+ 人确认 + 单写者；不照搬 Trellis 自动晋升。
5. 借鉴项一律先 advisory/warning，dogfood 稳定后才考虑 hard gate，不阻断旧任务。

## 5. P1/P2/P3 落地顺序

> **定级口径声明（本纪要为最终口径，supersede 前序 final 文档）：** 本表覆盖 `trellis-reusable-design.md` 第 4 节与 `gap-analysis.md` 的优先级。相对 `gap-analysis.md` 的调整：`finish-boundary-checklist` P2→**P1**（跟随其「最小落地顺序」首批、改面最小、直接补证据闭环）；`task-entity-artifact-design`、`context-manifest-advisory` P1→**P2**（依 §3 Q5「artifact 不一次性铺开、首发只放行 1–2 项并 dogfood」）；`artifact-drift-advisory` 维持 **P1**（相对 `trellis-reusable-design.md` 的 P4 提级，理由同上）。

**P1（串行执行，`finish-boundary-checklist` 先；两者共享 `lite-writing-guide.md`，不可并行）**
1. `finish-boundary-checklist`：`skills/test` + `skills/review` 增 4 项 handoff 抽查（纯写作规则）。
2. `artifact-drift-advisory`：validator warning，比对声明/affected_paths/diff/文件存在性。

**P2（次做，承载元数据与上下文）**
3. `task-entity-artifact-design`：设计 `task-entity.yaml/md`，含禁含字段黑名单；只设计，不实现 validator。
4. `context-manifest-advisory`：manifest（file+reason）仅 advisory，先不自动注入。
5. `trellis-context-injection-feasibility`：评估 Codex/Claude host hook 能否做 phase-aware 注入，先出可行性结论。

**P3（后评估，按需）**
6. `subtask-roadmap-artifact`：`subtasks.yaml` / `docs/roadmaps/<slug>/items.yaml`，作为后续独立评估项。
7. `session-summary / case-artifact`：长 debug/incident 任务的可选 `case.md` 证据 bundle。

## 6. 明确不做事项（本轮及可预见周期内）

- 不引入 `.trellis/` 目录或任何第二套任务根。
- 不让 `task.json.status` / active task pointer / workflow-state breadcrumb / UI / service 参与 stage 判定。
- 不做 dashboard / timeline / graph UI、queue / scheduler / active task runtime。
- 不做 auto finish / auto commit / auto archive；不做 spec 自动晋升 pipeline。
- 不实现 phase-aware 自动上下文注入引擎（仅先做可行性评估）。
- 不把 PR 自动化（create-pr / worktree 自动化）排进 P1/P2 实现。
- 不新建第二套长期 memory / LLM wiki 目录。
- 不为任何借鉴项一上来就设 hard gate。

## 7. 下一步可转成任务的建议

| 优先级 | 建议任务 | 类型 | 产出 | 验收要点 |
|---|---|---|---|---|
| P1 | `finish-boundary-checklist` | doc/skill | 更新 `skills/test`、`skills/review` 写作规则 | Handoff 必含 artifact/drift/follow-up/记忆-spec 判断 4 项 |
| P1 | `artifact-drift-advisory` | enhance | validator warning（扩展现有 validator，不新增独立脚本） | 能对比 `artifacts:`/affected_paths/diff/文件存在性，warning 不阻断 |
| P2 | `task-entity-artifact-design` | plan | `task-entity.yaml/md` 规范 + 示例 | 元数据不进 frontmatter；显式列禁含字段黑名单；不实现 validator |
| P2 | `context-manifest-advisory` | plan | manifest 规范（file+reason） | 仅 advisory；不覆盖 lazy-loading / skills_whitelist |
| P2 | `trellis-context-injection-feasibility` | research | host hook 能力评估报告 | 给出能否 phase-aware 注入的结论与边界，不写实现代码 |
| P3 | `subtask-roadmap-artifact` | plan | `subtasks.yaml` 格式 | 表达 parent/child/依赖/完成判据，不驱动 advance-stage |
| P3 | `session-case-artifact` | doc | `case.md` 模板 | 长 debug 任务可保留时间线与命令证据，不替代 test.md |

**最小落地顺序：** 先串行做 P1 两项（`finish-boundary-checklist` 先、`artifact-drift-advisory` 后；两者共享 `lite-writing-guide.md`，不可并行）→ 再做 `task-entity-artifact-design` 承载 branch/PR/subtask/owner → 最后评估 `context-manifest-advisory` 与注入可行性，避免过早与 lazy-loading 重叠。
