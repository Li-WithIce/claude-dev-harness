---
task_id: subtask-roadmap-artifact
stage: DONE
tool: none
updated: 2026-06-22
---
# Subtask Roadmap Artifact

## Clarification
- work_type: doc
- 验收标准: 为大型 roadmap 或父子任务拆分提供可选 `subtasks.yaml` / `docs/roadmaps/<slug>/items.yaml` 规范、模板和写作规则；PLAN / REVIEW / TEST 能明确何时建议启用、如何声明、如何检查；所有验证命令通过。
- 非目标: 不新增 stage；不修改 `advance-stage.ps1` 阶段拓扑；不让 subtasks/roadmap artifact 驱动 runtime pointer、team board、workflow descriptor、skill manifest、validator hard gate 或 `.assistant/运行时`；不引入 `.trellis/`、dashboard、queue/scheduler、PR 自动化、worktree 自动化或第二 truth。
- 受影响目录: `docs/工作流/subtask-roadmap-artifact.md`、`vault-template/模板/subtasks.yaml`、`skills/plan/SKILL.md`、`skills/review/SKILL.md`、`skills/test/SKILL.md`、`skills/orchestrator/references/lite-writing-guide.md`、`tests/verify-lite-footprint.ps1`、`tests/verify-lite-artifact-validator.ps1`、`docs/tasks/subtask-roadmap-artifact/plan.md`。
- 回滚策略: 删除新增的 subtask roadmap 协议/模板，回退 skill 写作规则与 footprint/live validator baseline；已存在任务的 `subtasks.yaml` 或 roadmap items 只是可选 artifact，删除规范不会影响 stage 推进。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: task
- affected_paths:
  - docs/tasks/subtask-roadmap-artifact/plan.md
  - docs/tasks/subtask-roadmap-artifact/skill-manifest.json
  - docs/tasks/subtask-roadmap-artifact/test.md
  - docs/工作流/subtask-roadmap-artifact.md
  - vault-template/模板/subtasks.yaml
  - skills/plan/SKILL.md
  - skills/review/SKILL.md
  - skills/test/SKILL.md
  - skills/orchestrator/references/lite-writing-guide.md
  - tests/verify-lite-footprint.ps1
  - tests/verify-lite-artifact-validator.ps1

## Plan
- read_first: [docs/tasks/trellis-comparison-reusable-design/discussion-meeting-notes.md, docs/tasks/trellis-comparison-reusable-design/trellis-reusable-design.md, docs/tasks/trellis-comparison-reusable-design/trellis-source-based-corrections.md, docs/工作流/task-entity-artifact.md, skills/orchestrator/references/lite-writing-guide.md, skills/plan/SKILL.md, skills/review/SKILL.md, skills/test/SKILL.md]
- convergence:
  - `Select-String -Path docs/工作流/subtask-roadmap-artifact.md -Pattern 'subtasks.yaml|docs/roadmaps|advisory-only|advance-stage|second truth'`
  - `Select-String -Path vault-template/模板/subtasks.yaml -Pattern 'schema_version|items|task_id|depends_on|acceptance|forbidden'`
  - `Select-String -Path skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md,skills/orchestrator/references/lite-writing-guide.md -Pattern 'subtasks.yaml|Subtask Roadmap|roadmap artifact|docs/roadmaps'`
  - `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId subtask-roadmap-artifact`
- artifacts: [docs/工作流/subtask-roadmap-artifact.md, vault-template/模板/subtasks.yaml, docs/tasks/subtask-roadmap-artifact/plan.md]
- TODO 1: 新增 `docs/工作流/subtask-roadmap-artifact.md`，定义 task-local `docs/tasks/<task-id>/subtasks.yaml` 与 cross-task `docs/roadmaps/<slug>/items.yaml` 的适用场景、advisory-only 边界、推荐字段、与 `plan.md` / `test.md` / task entity 的关系，以及 forbidden fields。
- TODO 2: 新增 `vault-template/模板/subtasks.yaml`，提供最小模板，覆盖 schema_version、summary、owner、items、task_id/title/depends_on/acceptance/artifacts/notes/open_gaps/forbidden。
- TODO 3: 更新 `skills/plan/SKILL.md` 和 `lite-writing-guide.md`：大型 roadmap、父子任务或依赖拆分可声明 `docs/tasks/<task-id>/subtasks.yaml` 或 `docs/roadmaps/<slug>/items.yaml`，必须列入 `artifacts:`，不得替代 stage truth、team board 或 `advance-stage.ps1`。
- TODO 4: 更新 `skills/review/SKILL.md`：PLAN_REVIEW / CODE_REVIEW 抽查 subtask roadmap artifact 是否只承载拆分、依赖和完成判据，是否含 forbidden second-truth 字段，是否与 Verification / Handoff 自洽。
- TODO 5: 更新 `skills/test/SKILL.md`：若声明 subtask roadmap artifact，TEST/Handoff 需记录是否交付、是否覆盖 parent/child/depends_on/acceptance/open gaps，以及是否仍有 follow-up 需要拆成独立 task。
- TODO 6: 更新 `tests/verify-lite-footprint.ps1` 锁定 subtask roadmap 文档、模板和 skill 文案；更新 `tests/verify-lite-artifact-validator.ps1`，把 live artifact validator baseline 扩展到本任务。
- TODO 7: 跑 Verification 命令，Implementation Notes 记录 changed / tests / risks / next；后续阶段只通过 `.assistant/entry/advance-stage.ps1` 推进。

## Verification
- `Select-String -Path docs/工作流/subtask-roadmap-artifact.md -Pattern 'subtasks.yaml|docs/roadmaps|advisory-only|advance-stage|second truth'`
- `Select-String -Path vault-template/模板/subtasks.yaml -Pattern 'schema_version|items|task_id|depends_on|acceptance|forbidden'`
- `Select-String -Path skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md,skills/orchestrator/references/lite-writing-guide.md -Pattern 'subtasks.yaml|Subtask Roadmap|roadmap artifact|docs/roadmaps'`
- `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId subtask-roadmap-artifact`

## Risks
- `subtasks.yaml` 或 roadmap items 可能被误读为新的任务调度器。缓解: 文档和 skill 统一写明 advisory-only，不参与 `advance-stage.ps1`、runtime pointer、team board 或 workflow descriptor。
- artifact 可能与 `task-entity.yaml` 的 parent/children 字段重复。缓解: task entity 记录单任务 metadata；subtask roadmap 记录拆分、依赖和完成判据，二者都不做 stage truth。
- 一次性铺开 roadmap artifact 可能增加“信息写哪里”的判断成本。缓解: 仅建议大型 roadmap、父子任务或依赖拆分使用，普通单任务不创建空文件。

## Plan Review

### Run 1 · 2026-06-22 20:23 · runner: Codex
- verdict: pass
- score.completeness: 93
- score.consistency: 92
- score.accuracy: 91
- score.depth: 89
- findings: none
- evidence: PLAN 覆盖 P3 `subtask-roadmap-artifact` 的协议文档、模板、PLAN/REVIEW/TEST/lite writing guide 文案、footprint 与 live validator baseline；`artifacts:` 与 `affected_paths` 分工清楚，非目标排除了 `.trellis/`、stage/runtime、team board、workflow descriptor、validator hard gate、PR/worktree 自动化和第二 truth。
- next: 进入 IMPLEMENT；重点保持 `subtasks.yaml` / roadmap items 只表达拆分、依赖和完成判据，不驱动 `advance-stage.ps1` 或 runtime pointer。

## Implementation Notes

### Run 1 · 2026-06-22 20:25 · runner: Codex
- changed: 新增 `docs/工作流/subtask-roadmap-artifact.md` 和 `vault-template/模板/subtasks.yaml`；更新 PLAN/REVIEW/TEST/lite writing guide 对 `subtasks.yaml` 与 `docs/roadmaps/<slug>/items.yaml` advisory-only 拆分清单的声明、检查和 Handoff 规则；更新 footprint 与 live validator 基线覆盖本任务。
- tests: `Select-String -Path docs/工作流/subtask-roadmap-artifact.md -Pattern 'subtasks.yaml|docs/roadmaps|advisory-only|advance-stage|second truth'` PASS；`Select-String -Path vault-template/模板/subtasks.yaml -Pattern 'schema_version|items|task_id|depends_on|acceptance|forbidden'` PASS；`Select-String -Path skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md,skills/orchestrator/references/lite-writing-guide.md -Pattern 'subtasks.yaml|Subtask Roadmap|roadmap artifact|docs/roadmaps'` PASS；`pwsh -NoProfile -File tests/verify-lite-footprint.ps1` PASS；`pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1` PASS；`pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId subtask-roadmap-artifact` PASS。
- risks: subtask roadmap 保持 optional/advisory-only，不新增 stage、runtime、team board、queue/scheduler、validator hard gate、`.trellis/`、PR/worktree 自动化或第二 truth；当前 validator 可能对中文路径的 git quotePath 形式给出 advisory drift warning，但不改变 exit code，后续若要消除该噪音应另立 validator 范围任务。
- next: 进入 CODE_REVIEW，重点复核 roadmap artifact 没有替代 `advance-stage.ps1`、team board、`test.md` 或 Handoff。

## Code Review

### Run 1 · 2026-06-22 20:26 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 92
- score.accuracy: 91
- score.depth: 90
- findings: none
- evidence: `git diff --check` PASS；复核 diff 仅新增 subtask roadmap advisory 协议/模板、写作规则和回归锁点，没有新增 stage、runtime、team board 调度、queue/scheduler、validator hard gate、`.trellis/`、PR/worktree 自动化或第二 truth；抽查 `docs/工作流/subtask-roadmap-artifact.md` 与 `vault-template/模板/subtasks.yaml` 未发现 forbidden fields 作为 YAML 状态字段。
- next: 进入 TEST；`test.md` 需要记录本任务交付的是 roadmap artifact 协议/模板，不创建当前任务自己的 `subtasks.yaml`，并说明中文路径 drift warning 为 advisory-only。
