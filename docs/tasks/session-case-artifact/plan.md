---
task_id: session-case-artifact
stage: DONE
tool: none
updated: 2026-06-22
---
# Session Case Artifact

## Clarification
- work_type: doc
- 验收标准: 为长 debug / incident / bug 调查任务提供可选 `docs/tasks/<task-id>/case.md` 证据包规范、模板和写作规则；PLAN / REVIEW / TEST 能明确何时建议启用、如何声明、如何检查；所有验证命令通过。
- 非目标: 不新增 stage；不新增 validator hard gate；不解析 `case.md` schema；不引入 case service、dashboard、日志采集 runtime、自动归档、`.trellis/` 目录、第二 truth 或 PR 自动化；不改变现有 `work_type` 枚举。
- 受影响目录: `docs/工作流/case-artifact.md`、`vault-template/模板/case.md`、`skills/plan/SKILL.md`、`skills/review/SKILL.md`、`skills/test/SKILL.md`、`skills/orchestrator/references/lite-writing-guide.md`、`tests/verify-lite-footprint.ps1`、`docs/tasks/session-case-artifact/plan.md`。
- 回滚策略: 删除新增的 case artifact 协议/模板，回退 skill 写作规则与 footprint 锁点；已存在任务的 `case.md` 只是可选 artifact，删除规范不会影响 stage 推进。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: task
- affected_paths:
  - docs/tasks/session-case-artifact/plan.md
  - docs/tasks/session-case-artifact/skill-manifest.json
  - docs/tasks/session-case-artifact/test.md
  - docs/工作流/case-artifact.md
  - vault-template/模板/case.md
  - skills/plan/SKILL.md
  - skills/review/SKILL.md
  - skills/test/SKILL.md
  - skills/orchestrator/references/lite-writing-guide.md
  - tests/verify-lite-footprint.ps1
  - tests/verify-lite-artifact-validator.ps1

## Plan
- read_first: [docs/tasks/trellis-comparison-reusable-design/trellis-reusable-design.md, docs/tasks/trellis-comparison-reusable-design/discussion-meeting-notes.md, skills/orchestrator/references/lite-writing-guide.md, skills/plan/SKILL.md, skills/review/SKILL.md, skills/test/SKILL.md]
- convergence:
  - `Select-String -Path docs/工作流/case-artifact.md -Pattern 'case.md|advisory-only|work_type|second truth'`
  - `Select-String -Path skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md,skills/orchestrator/references/lite-writing-guide.md -Pattern 'case.md|Case Artifact|case artifact'`
  - `Test-Path 'vault-template/模板/case.md'`
  - `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId session-case-artifact`
- artifacts: [docs/工作流/case-artifact.md, vault-template/模板/case.md, docs/tasks/session-case-artifact/plan.md]
- TODO 1: 新增 `docs/工作流/case-artifact.md`，定义 `case.md` 的适用场景、advisory-only 边界、推荐结构、与 `plan.md` / `test.md` 的关系，以及禁止字段。
- TODO 2: 新增 `vault-template/模板/case.md`，提供简洁模板，覆盖 summary、reproduction、timeline、evidence、commands、environment、resolution、open gaps。
- TODO 3: 更新 `skills/plan/SKILL.md` 和 `lite-writing-guide.md`：`work_type: bug` 或 incident/debug 类 `explore|maintenance` 任务可声明 `docs/tasks/<task-id>/case.md`，必须列入 `artifacts:`，不得替代 `test.md` 或 stage truth。
- TODO 4: 更新 `skills/review/SKILL.md`：PLAN_REVIEW / CODE_REVIEW 抽查 case artifact 是否只承载证据，是否含 forbidden second-truth 字段，是否与 Verification / Handoff 自洽。
- TODO 5: 更新 `skills/test/SKILL.md`：若声明 `case.md`，TEST/Handoff 需记录其是否交付、证据是否覆盖复现/命令/时间线、是否仍有 follow-up。
- TODO 6: 更新 `tests/verify-lite-footprint.ps1` 锁定 case artifact 文档、模板和 skill 文案；更新 `tests/verify-lite-artifact-validator.ps1`，把 live artifact validator baseline 扩展到本任务。
- TODO 7: 跑 Verification 命令，Implementation Notes 记录 changed / tests / risks / next；后续阶段只通过 `.assistant/entry/advance-stage.ps1` 推进。

## Verification
- `Select-String -Path docs/工作流/case-artifact.md -Pattern 'case.md|advisory-only|work_type|second truth'`
- `Select-String -Path skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md,skills/orchestrator/references/lite-writing-guide.md -Pattern 'case.md|Case Artifact|case artifact'`
- `Test-Path 'vault-template/模板/case.md'`
- `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId session-case-artifact`

## Risks
- `case.md` 可能被误读为新的 bug stage 或 incident runtime。缓解: 文档和 skill 统一写明 advisory-only，不替代 `plan.md` / `test.md`，不参与 `advance-stage.ps1`。
- `case.md` 与 `test.md` 证据重复。缓解: `case.md` 承载调查时间线和原始证据，`test.md` 仍承载最终验证结论和 Handoff。
- 新增模板可能被滥用于普通小修。缓解: 仅建议长 debug / incident / 复杂 bug 使用，旧任务和普通任务不回填。

## Plan Review

### Run 1 · 2026-06-22 20:22 · runner: Codex
- verdict: pass
- score.completeness: 92
- score.consistency: 91
- score.accuracy: 90
- score.depth: 88
- findings: none
- next: 进入 IMPLEMENT；重点保持 `case.md` advisory-only，不新增 validator hard gate、runtime 或 stage。

## Implementation Notes

### Run 1 · 2026-06-22 20:30 · runner: Codex
- changed: 新增 `docs/工作流/case-artifact.md` 和 `vault-template/模板/case.md`；更新 PLAN/REVIEW/TEST/lite writing guide 对 `case.md` advisory-only 证据包的声明、检查和 Handoff 规则；更新 footprint 与 live validator 基线覆盖本任务；把 `advance-stage` 生成的 task-local `skill-manifest.json` 纳入 Change Contract affected_paths。
- tests: `Select-String -Path docs/工作流/case-artifact.md -Pattern 'case.md|advisory-only|work_type|second truth'` PASS；`Select-String -Path skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md,skills/orchestrator/references/lite-writing-guide.md -Pattern 'case.md|Case Artifact|case artifact'` PASS；`Test-Path 'vault-template/模板/case.md'` PASS；`pwsh -NoProfile -File tests/verify-lite-footprint.ps1` PASS；`pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1` PASS；`pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId session-case-artifact` PASS。
- risks: `case.md` 保持 optional/advisory-only，不新增 stage、runtime、validator hard gate、`.trellis/` 或第二 truth；当前 validator 可能对中文路径的 git quotePath 形式给出 advisory drift warning，但不改变 exit code，后续若要消除该噪音应另立 validator 范围任务。
- next: 进入 CODE_REVIEW，重点复核 `case.md` 没有替代 `test.md`、Handoff 或 stage truth。

## Code Review

### Run 1 · 2026-06-22 20:31 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 92
- score.accuracy: 91
- score.depth: 90
- findings: none
- evidence: `git diff --check` PASS；复核 diff 仅新增 `case.md` advisory 协议/模板、写作规则和回归锁点，没有新增 stage、runtime、validator hard gate、`.trellis/`、dashboard、自动注入或第二 truth。
- next: 进入 TEST；`test.md` 需要记录 `case.md` 未作为当前任务产物创建，只交付协议文档与模板，并说明中文路径 drift warning 为 advisory-only。
