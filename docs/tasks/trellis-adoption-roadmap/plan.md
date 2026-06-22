---
task_id: trellis-adoption-roadmap
stage: PLAN
tool: codex
tool_profile: harness-default-codex
model: gpt-5.5/xhigh
updated: 2026-06-22
---
# Trellis Adoption Roadmap

## Clarification
- work_type: doc
- 验收标准: 三份 Trellis 改造计划形成一致路线图，`trellis-adoption-roadmap` 只表达 roadmap/backlog/依赖关系，`finish-boundary-checklist` 是 P1 第一个执行任务，`artifact-drift-advisory` 是 P1 第二个执行任务，三份计划均包含明确执行边界和 Plan Review 结论。
- 非目标: 不在本任务实现任何子任务；不修改 `skills/`、`scripts/`、`tests/`、validator、workflow descriptor、`.assistant/运行时` 或任何业务实现文件；不引入 `.trellis/`、新 stage、`advance-stage.ps1` 阶段拓扑变更、第二 truth、dashboard/runtime/auto injection/PR automation/hard gate。
- 受影响目录: `docs/tasks/trellis-adoption-roadmap/plan.md`、`docs/tasks/finish-boundary-checklist/plan.md`、`docs/tasks/artifact-drift-advisory/plan.md`。
- 回滚策略: 回滚或删除本轮新增的三份 `plan.md` 即可；没有实现文件、runtime pointer 或 workflow descriptor 状态需要恢复。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: task
- affected_paths:
  - docs/tasks/trellis-adoption-roadmap/plan.md
  - docs/tasks/finish-boundary-checklist/plan.md
  - docs/tasks/artifact-drift-advisory/plan.md

## Plan
- read_first: [docs/tasks/trellis-comparison-reusable-design/discussion-meeting-notes.md, docs/tasks/trellis-comparison-reusable-design/trellis-source-based-corrections.md, docs/tasks/trellis-comparison-reusable-design/trellis-reusable-design.md, docs/tasks/trellis-comparison-reusable-design/gap-analysis.md, skills/plan/SKILL.md]
- convergence:
  - `Select-String -Path docs/tasks/trellis-adoption-roadmap/plan.md -Pattern 'finish-boundary-checklist|artifact-drift-advisory|不引入 \.trellis|不新增 stage|hard gate'`
  - `Select-String -Path docs/tasks/finish-boundary-checklist/plan.md -Pattern 'skills/test/SKILL.md|skills/review/SKILL.md|lite-writing-guide|旧格式|validator hard gate'`
  - `Select-String -Path docs/tasks/artifact-drift-advisory/plan.md -Pattern 'Add-Warning|exit code|warning|advisory-only|不新增独立脚本|validator warning'`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId trellis-adoption-roadmap`
- artifacts: [docs/tasks/trellis-adoption-roadmap/plan.md, docs/tasks/finish-boundary-checklist/plan.md, docs/tasks/artifact-drift-advisory/plan.md]
- TODO 1: 固定 Trellis 借鉴硬边界。所有后续任务只吸收 finish/checklist、artifact drift、task entity、context taxonomy 这类轻量协议能力，不复制 `.trellis/` 目录、task runtime、active pointer、workflow-state breadcrumb、UI/service truth 或自动化 PR/commit/archive。
- TODO 2: 固定 P1 执行顺序。按本线程用户交接要求，`finish-boundary-checklist` 先执行，范围只落到 `skills/test/SKILL.md`、`skills/review/SKILL.md` 和 `skills/orchestrator/references/lite-writing-guide.md` 的写作规则；随后执行 `artifact-drift-advisory`，范围落到现有 validator warning 体系和配套验证。
- TODO 3: 固定 P2 backlog。`task-entity-artifact-design`、`context-manifest-advisory`、`trellis-context-injection-feasibility` 只能在 P1 dogfood 后推进；它们不得把 stage/status/verdict/tool/current pointer 写成第二套真相源，也不得自动覆盖 lazy loading 或 workflow descriptor。
- TODO 4: 固定 P3 backlog。`subtask-roadmap-artifact` 与 `session-case-artifact` 只作为后续可选 artifact 评估，不进入 P1/P2 实现窗口。
- TODO 5: 给开发窗口交接。开发窗口只按子任务计划实施 `finish-boundary-checklist` 和 `artifact-drift-advisory`，不要把总控 roadmap 自身当作实现任务，也不要提前实现 P2/P3。
- TODO 6: 交接前推进 P1 子任务 stage。`finish-boundary-checklist` 与 `artifact-drift-advisory` 的 Plan Review pass 后应由当前窗口通过 `.assistant/entry/advance-stage.ps1` 推进到 `IMPLEMENT`，避免新窗口重新进入 PLAN/PLAN_REVIEW；总控 roadmap 不作为开发任务推进。

## Verification
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId trellis-adoption-roadmap`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId finish-boundary-checklist`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId artifact-drift-advisory`

## Risks
- P1 顺序与早期文档表格存在差异。缓解: 以 `discussion-meeting-notes.md` 的最终定级和本线程用户交接为准，并在 TODO 2 明确执行顺序。
- Roadmap 可能被误读成可直接开发的范围。缓解: Clarification 和 TODO 5 明确总控只做 backlog/依赖，不改实现文件。
- 后续任务容易顺手扩大到 Trellis runtime。缓解: 三份计划均重复写入同一组 hard boundary。

## Plan Review
### Run 1 · 2026-06-22 17:16 · runner: Codex
- verdict: pass
- score.completeness: 93
- score.consistency: 92
- score.accuracy: 91
- score.depth: 88
- findings: none
- next: 先执行 `finish-boundary-checklist`；总控 roadmap 本身不进入实现。

### Run 2 · 2026-06-22 17:45 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 94
- score.accuracy: 92
- score.depth: 90
- findings: none
- optimization_notes: 明确 P1 子任务需要在本窗口推进到 IMPLEMENT，避免新开发窗口重复 PLAN/PLAN_REVIEW；收紧 artifact-drift 收敛检索词，避免“独立脚本”误读为新增入口。
- next: 当前窗口只推进 P1 子任务 stage，不推进总控 roadmap 实现。

## Implementation Notes

## Code Review
