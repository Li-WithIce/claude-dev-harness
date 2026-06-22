---
task_id: finish-boundary-checklist
stage: DONE
tool: none
updated: 2026-06-22
---
# Finish Boundary Checklist

## Clarification
- work_type: maintenance
- 验收标准: `skills/test/SKILL.md`、`skills/review/SKILL.md` 和 `skills/orchestrator/references/lite-writing-guide.md` 增加 finish boundary 写作规则；新写法要求 TEST/Handoff 和 review 明确记录 artifact、drift、follow-up、memory/spec update 判断；旧 `delivery`/`follow_up` Handoff 格式继续兼容；不修改 validator hard gate。
- 非目标: 不修改 `scripts/validate-lite-artifacts.ps1`、`tests/`、workflow descriptor、`advance-stage.ps1`、`.assistant/运行时` 或任何实现文件；不新增 stage；不引入 `.trellis/`、第二 truth、dashboard/runtime/auto injection/PR automation/hard gate。
- 受影响目录: `skills/test/SKILL.md`、`skills/review/SKILL.md`、`skills/orchestrator/references/lite-writing-guide.md`。
- 回滚策略: 回滚上述三份写作规则文档即可；validator 行为、旧任务格式和阶段推进逻辑不发生迁移。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: enhance
- affected_paths:
  - skills/test/SKILL.md
  - skills/review/SKILL.md
  - skills/orchestrator/references/lite-writing-guide.md

## Plan
- read_first: [docs/tasks/trellis-comparison-reusable-design/discussion-meeting-notes.md, docs/tasks/trellis-comparison-reusable-design/trellis-reusable-design.md, docs/tasks/trellis-comparison-reusable-design/gap-analysis.md, skills/test/SKILL.md, skills/review/SKILL.md, skills/orchestrator/references/lite-writing-guide.md]
- convergence:
  - `Select-String -Path skills/test/SKILL.md -Pattern 'artifact|drift|follow_up|memory|spec|Handoff'`
  - `Select-String -Path skills/review/SKILL.md -Pattern 'artifacts|affected_paths|drift|Handoff|follow-up'`
  - `Select-String -Path skills/orchestrator/references/lite-writing-guide.md -Pattern 'finish boundary|artifact|drift|memory|spec|旧格式|delivery|follow_up'`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- artifacts: [skills/test/SKILL.md, skills/review/SKILL.md, skills/orchestrator/references/lite-writing-guide.md]
- TODO 1: 更新 `skills/test/SKILL.md` 的 Handoff 规则。保留 `delivery` 与 `follow_up` 作为 validator 最低必填，同时要求新任务在 Handoff 里记录四项 finish 判断: artifact 是否存在或交付、是否存在 artifact/diff drift、follow-up 是否需要拆新任务、是否需要 memory/spec update。该要求是写作规则，不改 `test.md` hard contract。
- TODO 2: 更新 `skills/review/SKILL.md` 的 PLAN_REVIEW/CODE_REVIEW 审查重点。PLAN_REVIEW 关注 `artifacts:`、`Change Contract.affected_paths`、verification 和非目标是否自洽；CODE_REVIEW 关注实际 diff、产物声明、Implementation Notes 和后续 TEST/Handoff 是否能覆盖 artifact/drift/follow-up/memory-spec 判断。
- TODO 3: 更新 `skills/orchestrator/references/lite-writing-guide.md`。把 finish boundary 写成现有 `test.md` Handoff 与 append-only review 的写作规则，明确旧任务只有 `delivery`/`follow_up` 仍合法，validator 仍只硬校验既有最低字段。
- TODO 4: 不改 validator。不得把四项 finish 判断升为 `scripts/validate-lite-artifacts.ps1` 的 `Add-Failure`、不得要求旧 `test.md` 回填、不得新增独立 checklist 文件或新阶段。
- TODO 5: 实现后只追加必要的 Implementation Notes 证据；如发现必须改 validator 才能表达规则，停止并回 PLAN，而不是在本任务扩大范围。
- TODO 6: 新窗口执行前本任务应已处于 `IMPLEMENT`。若 frontmatter 仍是 `PLAN` 或 `PLAN_REVIEW`，先通过 `.assistant/entry/advance-stage.ps1 -TaskId finish-boundary-checklist` 推进，不要重写计划或重复发起 plan review。

## Verification
- `Select-String -Path skills/test/SKILL.md -Pattern 'artifact|drift|follow_up|memory|spec|Handoff'`
- `Select-String -Path skills/review/SKILL.md -Pattern 'artifacts|affected_paths|drift|Handoff|follow-up'`
- `Select-String -Path skills/orchestrator/references/lite-writing-guide.md -Pattern 'finish boundary|artifact|drift|memory|spec|旧格式|delivery|follow_up'`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId finish-boundary-checklist`

## Risks
- 文案可能被理解为 validator hard gate。缓解: 在三处文档都写明旧格式兼容、仅写作规则、validator 最低字段不变。
- Review/Test 规则可能重复或冲突。缓解: `lite-writing-guide.md` 作为格式契约源，`skills/test` 和 `skills/review` 只写阶段执行要点。
- 后续 `artifact-drift-advisory` 会再触碰 validator。缓解: 本任务不预先修改 validator，只为下一任务提供审查语义。

## Plan Review
### Run 1 · 2026-06-22 17:16 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 93
- score.accuracy: 92
- score.depth: 89
- findings: none
- next: 进入 IMPLEMENT 时只修改三份写作规则文档，不改 validator 或实现文件。

### Run 2 · 2026-06-22 17:45 · runner: Codex
- verdict: pass
- score.completeness: 95
- score.consistency: 94
- score.accuracy: 93
- score.depth: 90
- findings: none
- optimization_notes: 增加 stage 交接要求，确保新窗口直接从 IMPLEMENT 消费本计划；其余边界保持不变。
- next: 推进到 IMPLEMENT 后执行三份写作规则文档改造。

## Implementation Notes
### Run 1 · 2026-06-22 18:11 · runner: Codex
- changed: 更新 `skills/test/SKILL.md` 的 Handoff finish boundary 写法，更新 `skills/review/SKILL.md` 的 PLAN_REVIEW/CODE_REVIEW artifact drift 审查点，更新 `skills/orchestrator/references/lite-writing-guide.md` 的 finish boundary 与旧格式兼容说明。
- tests: `Select-String -Path skills/test/SKILL.md -Pattern 'artifact|drift|follow_up|memory|spec|Handoff'` pass；`Select-String -Path skills/review/SKILL.md -Pattern 'artifacts|affected_paths|drift|Handoff|follow-up'` pass；`Select-String -Path skills/orchestrator/references/lite-writing-guide.md -Pattern 'finish boundary|artifact|drift|memory|spec|旧格式|delivery|follow_up'` pass；`pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId finish-boundary-checklist` STATUS: PASS；`pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1` failed because the live baseline expects 18 plan-bearing tasks but the current workspace contains 22.
- risks: Completion is blocked by a test baseline drift in `tests/verify-lite-artifact-validator.ps1`; changing that test is explicitly out of scope for this task.
- next: Do not advance this task until the validator regression baseline is handled by an allowed task boundary or the task plan is adjusted.

### Run 2 · 2026-06-22 18:17 · runner: Codex
- changed: 用户授权先修复阻塞项后，更新 `tests/verify-lite-artifact-validator.ps1` 的 live baseline 为当前 22 个 plan-bearing tasks；任务一三份写作规则文档未再扩大改动。
- tests: `Select-String -Path skills/test/SKILL.md -Pattern 'artifact|drift|follow_up|memory|spec|Handoff'` pass；`Select-String -Path skills/review/SKILL.md -Pattern 'artifacts|affected_paths|drift|Handoff|follow-up'` pass；`Select-String -Path skills/orchestrator/references/lite-writing-guide.md -Pattern 'finish boundary|artifact|drift|memory|spec|旧格式|delivery|follow_up'` pass；`pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1` pass；`pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId finish-boundary-checklist` STATUS: PASS.
- risks: `tests/verify-lite-artifact-validator.ps1` 的 baseline 修复是用户授权的前置解阻改动，不属于原任务一三文档范围。
- next: 进入 CODE_REVIEW 时重点复核 finish boundary 仍只是写作规则，未改 validator hard gate。

## Code Review
### Run 1 · 2026-06-22 18:37 · runner: Codex
- verdict: pass
- score.completeness: 93
- score.consistency: 91
- score.accuracy: 92
- score.depth: 88
- findings: none
- review_notes: 任务范围内的三份写作规则文档已覆盖 finish boundary 四项判断，并保持旧 `delivery` / `follow_up` Handoff 兼容；`tests/verify-lite-artifact-validator.ps1` baseline 调整已在 Implementation Notes Run 2 标注为用户授权的前置解阻，不把四项 finish 判断升为 validator hard gate。当前工作树仍有 `refactor/remove-gemini-support` 相关 staged/unstaged 改动，属于本任务外 drift，后续提交时需分开说明或拆分。
- next: 推进到 TEST，测试报告需记录 artifact 已交付、dirty tree drift 为 out-of-scope、无需 memory/spec update。
