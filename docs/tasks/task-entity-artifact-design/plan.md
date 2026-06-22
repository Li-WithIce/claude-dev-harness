---
task_id: task-entity-artifact-design
stage: DONE
tool: none
updated: 2026-06-22
---
# Task Entity Artifact Design

## Clarification
- work_type: maintenance
- 验收标准: dev-harness 增加可选 `task-entity.yaml` artifact 的规范、模板和当前任务 dogfood 示例；写作规则说明它只承载 owner/priority/branch/PR/parent/children/related_files/external_refs/meta/notes 等任务元数据，不参与 stage/status/verdict/tool/current pointer 判定；旧任务不需要回填；validator 只继续通过既有 `artifacts:` 存在性 advisory 间接提示，不解析 task entity 字段。
- 非目标: 不引入 `.trellis/`；不新增第二任务根、第二 stage/status truth、active pointer、workflow-state breadcrumb、dashboard/runtime/auto injection/PR automation；不修改 `advance-stage.ps1` 阶段拓扑；不让 validator 对 `task-entity.yaml` 做 schema hard gate；不提前实现 `context-manifest-advisory`、`subtask-roadmap-artifact` 或 PR/worktree 自动化。
- 受影响目录: `docs/工作流/task-entity-artifact.md`、`vault-template/模板/任务实体模板.yaml`、`skills/orchestrator/references/lite-writing-guide.md`、`skills/plan/SKILL.md`、`skills/review/SKILL.md`、`skills/test/SKILL.md`、`docs/tasks/task-entity-artifact-design/task-entity.yaml`、`tests/verify-lite-artifact-validator.ps1`。
- 回滚策略: 删除新增的 task entity 规范/模板/dogfood artifact，并回滚三份 skill/guide 文案与 validator live baseline；由于没有新增消费端和 hard gate，回滚不涉及 stage 状态迁移或 runtime pointer 修复。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: enhance
- affected_paths:
  - docs/工作流/task-entity-artifact.md
  - vault-template/模板/任务实体模板.yaml
  - skills/orchestrator/references/lite-writing-guide.md
  - skills/plan/SKILL.md
  - skills/review/SKILL.md
  - skills/test/SKILL.md
  - docs/tasks/task-entity-artifact-design/task-entity.yaml
  - tests/verify-lite-artifact-validator.ps1

## Plan
- read_first: [docs/tasks/trellis-comparison-reusable-design/discussion-meeting-notes.md, docs/tasks/trellis-comparison-reusable-design/gap-analysis.md, docs/tasks/trellis-comparison-reusable-design/trellis-source-based-corrections.md, skills/orchestrator/references/lite-writing-guide.md, scripts/validate-lite-artifacts.ps1, tests/verify-lite-artifact-validator.ps1]
- convergence:
  - `Select-String -Path docs/工作流/task-entity-artifact.md -Pattern 'forbidden|stage|status|verdict|tool|current_phase|next_action|advisory-only|plan.md frontmatter'`
  - `Select-String -Path vault-template/模板/任务实体模板.yaml -Pattern 'schema_version|owner|priority|branch|base_branch|pr_url|parent|children|related_files|external_refs|forbidden'`
  - `Select-String -Path skills/orchestrator/references/lite-writing-guide.md,skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md -Pattern 'task-entity.yaml|Task entity|stage/status|second truth|advisory'`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId task-entity-artifact-design`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- artifacts: [docs/工作流/task-entity-artifact.md, vault-template/模板/任务实体模板.yaml, docs/tasks/task-entity-artifact-design/task-entity.yaml]
- TODO 1: 新增 `docs/工作流/task-entity-artifact.md`。明确 `task-entity.yaml` 的定位、适用场景、推荐路径、字段白名单、禁含字段黑名单、与 `plan.md` frontmatter / `.assistant/运行时` / team board / `skill-manifest.json` 的边界。
- TODO 2: 新增 `vault-template/模板/任务实体模板.yaml`。模板只包含 advisory metadata，并以注释列出 forbidden fields；字段不得包含 `stage`、`status`、`verdict`、`tool`、`current_phase`、`next_action`、`active_task`、`current_pointer`。
- TODO 3: 在 `skills/orchestrator/references/lite-writing-guide.md` 增加可选 task entity artifact 章节，说明它必须放在 `docs/tasks/<task-id>/task-entity.yaml`，需要在 `Plan.artifacts` 声明，旧任务不回填，validator 不做 schema hard gate。
- TODO 4: 更新 `skills/plan/SKILL.md` / `skills/review/SKILL.md` / `skills/test/SKILL.md` 的写作要点。PLAN 只在大型/跨分支/有父子任务或外部 issue 时建议启用；REVIEW 抽查 forbidden fields 和第二 truth 风险；TEST/Handoff 记录 task entity 是否已交付与是否需要后续 P2/P3 拆分。
- TODO 5: 为当前任务新增 dogfood artifact `docs/tasks/task-entity-artifact-design/task-entity.yaml`，示范 branch/parent/children/related_files/external_refs/meta 的最小写法，同时明确本文件不驱动 stage。
- TODO 6: 更新 `tests/verify-lite-artifact-validator.ps1` 的 live baseline 至当前新增计划任务数量，并把 `task-entity-artifact-design` 纳入 expected pass list；不新增 task entity schema 校验。
- TODO 7: 保持 P2 边界：不改 `scripts/advance-stage.ps1`、workflow descriptor、runtime mirror 协议、team board schema 或任何自动注入逻辑；若实现中发现必须改这些文件，停止并回 PLAN。

## Verification
- `Select-String -Path docs/工作流/task-entity-artifact.md -Pattern 'forbidden|stage|status|verdict|tool|current_phase|next_action|advisory-only|plan.md frontmatter'`
- `Select-String -Path vault-template/模板/任务实体模板.yaml -Pattern 'schema_version|owner|priority|branch|base_branch|pr_url|parent|children|related_files|external_refs|forbidden'`
- `Select-String -Path skills/orchestrator/references/lite-writing-guide.md,skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md -Pattern 'task-entity.yaml|Task entity|stage/status|second truth|advisory'`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId task-entity-artifact-design`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`

## Risks
- `task-entity.yaml` 容易被误读为第二任务状态。缓解: 规范、模板和 review 规则均显式列 forbidden fields，并声明 `plan.md` frontmatter 仍是唯一 stage truth。
- 与 team board 的 owner/priority 重叠。缓解: task entity 只做跨会话 advisory metadata，不反向更新 team board；team board 仍是运行时协作面。
- 当前工作树已有 `refactor/remove-gemini-support` 大量 dirty paths，新 advisory 会输出噪声。缓解: 本任务 Handoff 和后续提交必须把 Trellis P2 与 Gemini removal 分开说明，不把 out-of-scope drift 当作本任务失败。
- baseline 维护会继续随新增 plan-bearing task 变化。缓解: 本任务只做当前 live baseline 更新，不引入新的 hard-coded schema gate。

## Plan Review
### Run 1 · 2026-06-22 18:50 · runner: Codex
- verdict: pass
- score.completeness: 92
- score.consistency: 91
- score.accuracy: 90
- score.depth: 88
- findings: none
- review_notes: Leader 已派发三条团队 PLAN_REVIEW（dev-harness 兼容、Trellis 边界、风险/提交边界），短等待窗口内未收到阻断 finding。当前 plan 已通过 `validate-lite-artifacts`，并明确 task entity 只作为 advisory artifact，不进入 frontmatter、runtime mirror、advance-stage、validator schema 或第二 truth。后续团队如返回 finding，纳入 CODE_REVIEW 或回修。
- next: 推进 IMPLEMENT，严格按 TODO 1-7 落地，不新增 validator schema hard gate。

## Implementation Notes
### Run 1 · 2026-06-22 18:54 · runner: Codex
- changed: 新增 `docs/工作流/task-entity-artifact.md`、`vault-template/模板/任务实体模板.yaml` 和当前任务 dogfood `docs/tasks/task-entity-artifact-design/task-entity.yaml`；更新 orchestrator writing guide、plan/review/test skills，明确 `task-entity.yaml` 只是 advisory metadata，不承载 stage/status/verdict/tool/current pointer；更新 `tests/verify-lite-artifact-validator.ps1` live baseline 到 23 个 plan-bearing tasks，并把当前任务纳入 expected pass set。
- tests: `Select-String -Path docs/工作流/task-entity-artifact.md -Pattern 'forbidden|stage|status|verdict|tool|current_phase|next_action|advisory-only|plan.md frontmatter'`; `Select-String -Path vault-template/模板/任务实体模板.yaml -Pattern 'schema_version|owner|priority|branch|base_branch|pr_url|parent|children|related_files|external_refs|forbidden'`; `Select-String -Path skills/orchestrator/references/lite-writing-guide.md,skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md -Pattern 'task-entity.yaml|Task entity|stage/status|second truth|advisory'`; `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId task-entity-artifact-design`; `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`。
- risks: 当前工作树存在大量非本任务 dirty paths，validator 对它们输出 warning-only artifact drift；`docs/工作流/task-entity-artifact.md` 的非 ASCII 路径也被 validator 的 git-status 归一化显示成转义路径 warning，但回归脚本整体 pass，且本任务不修改 validator drift 归一化逻辑。
- next: CODE_REVIEW 重点检查是否有任何字段或文案把 `task-entity.yaml` 变成 stage/status/verdict/tool/current pointer 的 second truth，以及本轮是否误改了 P2 非目标文件。

## Code Review
### Run 1 · 2026-06-22 18:57 · runner: Codex
- verdict: pass
- score.completeness: 91
- score.consistency: 90
- score.accuracy: 89
- score.depth: 87
- findings: none
- review_notes: 已派发团队 CODE_REVIEW 任务 222abb79、e8b93fb8、797002ef；短等待窗口内未收到阻断 finding，任务板仍显示 in_progress。Leader 本地审查覆盖新增规范、模板、dogfood artifact、skill 文案和 validator baseline；`task-entity.yaml` 与模板未出现真实 forbidden fields，文案均声明 advisory-only 且不进入 `advance-stage.ps1`、runtime pointer、team board 或 validator hard gate。已执行计划内 Select-String 抽查、当前任务 validator 和 `tests/verify-lite-artifact-validator.ps1`，结果均 pass；validator 的 drift 输出为 warning-only，主要来自现有 dirty tree 和非 ASCII path 归一化噪声。
- next: 推进 TEST；TEST/Handoff 必须记录 task entity artifact 已交付、未发现 second truth 字段、以及当前 dirty worktree 的 artifact drift warning 边界。
