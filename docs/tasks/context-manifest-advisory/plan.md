---
task_id: context-manifest-advisory
stage: DONE
tool: none
updated: 2026-06-22
---
# Context Manifest Advisory

## Clarification
- work_type: maintenance
- 验收标准: dev-harness 增加可选 `context-manifest.yaml` advisory artifact 的规范、模板和当前任务 dogfood 示例；写作规则说明它只记录 phase/file/reason/required/notes 等上下文读取建议，不自动注入、不覆盖 `read_first:`、lazy loading、`skills_whitelist`、workflow descriptor 或 stage skill；旧任务不需要回填；validator 不解析 context manifest schema，只通过既有 `artifacts:` drift advisory 间接提示声明产物是否存在。
- 非目标: 不引入 `.trellis/`、`implement.jsonl`/`check.jsonl` 执行器、phase-aware 自动注入引擎、第二上下文真相源、active pointer、workflow-state breadcrumb、dashboard/runtime/auto injection/PR automation；不修改 `advance-stage.ps1`、workflow descriptor、skill manifest 生成、team board schema 或 validator hard gate；不提前实现 `trellis-context-injection-feasibility`、`subtask-roadmap-artifact` 或 session case artifact。
- 受影响目录: `docs/工作流/context-manifest-artifact.md`、`vault-template/模板/上下文清单模板.yaml`、`skills/orchestrator/references/lite-writing-guide.md`、`skills/plan/SKILL.md`、`skills/review/SKILL.md`、`skills/test/SKILL.md`、`docs/tasks/context-manifest-advisory/context-manifest.yaml`、`docs/tasks/context-manifest-advisory/task-entity.yaml`、`tests/verify-lite-artifact-validator.ps1`。
- 回滚策略: 删除新增的 context manifest 规范/模板/dogfood artifact，并回滚三份 skill/guide 文案与 validator live baseline；由于没有新增消费端、自动注入或 hard gate，回滚不涉及 stage 状态迁移、runtime pointer 修复或 descriptor 回滚。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: enhance
- affected_paths:
  - docs/工作流/context-manifest-artifact.md
  - vault-template/模板/上下文清单模板.yaml
  - skills/orchestrator/references/lite-writing-guide.md
  - skills/plan/SKILL.md
  - skills/review/SKILL.md
  - skills/test/SKILL.md
  - docs/tasks/context-manifest-advisory/context-manifest.yaml
  - docs/tasks/context-manifest-advisory/task-entity.yaml
  - tests/verify-lite-artifact-validator.ps1

## Plan
- read_first: [docs/tasks/trellis-comparison-reusable-design/discussion-meeting-notes.md, docs/tasks/trellis-comparison-reusable-design/gap-analysis.md, docs/tasks/trellis-comparison-reusable-design/trellis-source-based-corrections.md, docs/tasks/task-entity-artifact-design/plan.md, docs/工作流/task-entity-artifact.md, skills/orchestrator/references/lite-writing-guide.md, skills/plan/SKILL.md, skills/review/SKILL.md, skills/test/SKILL.md, tests/verify-lite-artifact-validator.ps1]
- convergence:
  - `Select-String -Path docs/工作流/context-manifest-artifact.md -Pattern 'advisory-only|context-manifest.yaml|phase|file|reason|required|lazy loading|skills_whitelist|不自动注入|plan.md read_first'`
  - `Select-String -Path vault-template/模板/上下文清单模板.yaml -Pattern 'schema_version|contexts|phase|file|reason|required|notes|forbidden'`
  - `Select-String -Path skills/orchestrator/references/lite-writing-guide.md,skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md -Pattern 'context-manifest.yaml|Context Manifest|advisory|lazy loading|skills_whitelist|second truth'`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId context-manifest-advisory`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- artifacts: [docs/工作流/context-manifest-artifact.md, vault-template/模板/上下文清单模板.yaml, docs/tasks/context-manifest-advisory/context-manifest.yaml, docs/tasks/context-manifest-advisory/task-entity.yaml]
- TODO 1: 新增 `docs/工作流/context-manifest-artifact.md`。明确 `context-manifest.yaml` 的定位、适用场景、推荐路径、字段白名单、禁含字段黑名单、与 `plan.md read_first:` / `.assistant` / lazy loading / `skills_whitelist` / workflow descriptor / `skill-manifest.json` 的边界。
- TODO 2: 新增 `vault-template/模板/上下文清单模板.yaml`。模板只包含 advisory context entries，并以注释列出 forbidden fields；字段不得包含 `stage`、`status`、`verdict`、`tool`、`current_phase`、`next_action`、`active_task`、`current_pointer`、`skills_whitelist`、`auto_inject`、`injector`。
- TODO 3: 在 `skills/orchestrator/references/lite-writing-guide.md` 增加可选 context manifest artifact 章节，说明它必须放在 `docs/tasks/<task-id>/context-manifest.yaml`，需要在 `Plan.artifacts` 声明，旧任务不回填，validator 不做 schema hard gate。
- TODO 4: 更新 `skills/plan/SKILL.md` / `skills/review/SKILL.md` / `skills/test/SKILL.md` 的写作要点。PLAN 只在多阶段、大量事实源、跨任务研究或后续恢复成本高时建议启用；REVIEW 抽查 forbidden fields 和覆盖 lazy-loading / `skills_whitelist` 的 second truth 风险；TEST/Handoff 记录 context manifest 是否交付、是否仍是 advisory-only。
- TODO 5: 为当前任务新增 dogfood artifact `docs/tasks/context-manifest-advisory/context-manifest.yaml`，示范 PLAN_REVIEW / IMPLEMENT / CODE_REVIEW / TEST 各阶段的 file + reason 写法，同时明确本文件不驱动加载和注入。
- TODO 6: 为当前任务新增 dogfood `docs/tasks/context-manifest-advisory/task-entity.yaml`，把本任务作为 `task-entity-artifact-design` 后续子任务记录，同时不写任何 stage/status/current pointer 字段。
- TODO 7: 更新 `tests/verify-lite-artifact-validator.ps1` 的 live baseline 至当前新增计划任务数量，并把 `context-manifest-advisory` 纳入 expected pass set；不新增 context manifest schema 校验。
- TODO 8: 保持 P2 边界：不改 `scripts/advance-stage.ps1`、workflow descriptor、runtime mirror 协议、team board schema、skill manifest 生成或任何自动注入逻辑；若实现中发现必须改这些文件，停止并回 PLAN。

## Verification
- `Select-String -Path docs/工作流/context-manifest-artifact.md -Pattern 'advisory-only|context-manifest.yaml|phase|file|reason|required|lazy loading|skills_whitelist|不自动注入|plan.md read_first'`
- `Select-String -Path vault-template/模板/上下文清单模板.yaml -Pattern 'schema_version|contexts|phase|file|reason|required|notes|forbidden'`
- `Select-String -Path skills/orchestrator/references/lite-writing-guide.md,skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md -Pattern 'context-manifest.yaml|Context Manifest|advisory|lazy loading|skills_whitelist|second truth'`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId context-manifest-advisory`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`

## Risks
- `context-manifest.yaml` 容易被误读为自动注入配置。缓解: 规范、模板和 skill 文案都声明 advisory-only，不覆盖 lazy loading / `skills_whitelist`，不进入 descriptor 或 skill manifest 生成。
- 与 `plan.md read_first:` 重叠。缓解: `read_first:` 仍是 Plan 顶部轻量入口；context manifest 只在复杂任务中补充 phase/file/reason 粒度，不替代 Plan metadata。
- 当前工作树已有大量非本任务 dirty paths，新 artifact drift advisory 会输出噪声。缓解: 本任务 Handoff 和后续提交必须把 context manifest P2 与既有 Gemini removal / Trellis planning drift 分开说明，不把 out-of-scope drift 当作本任务失败。
- live baseline 会随新增 plan-bearing task 变化。缓解: 本任务只更新当前 live baseline，不引入新的 schema gate。

## Plan Review
### Run 1 · 2026-06-22 19:18 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 93
- score.accuracy: 92
- score.depth: 90
- findings: none
- review_notes: 计划边界与 Trellis 会议纪要一致：`context-manifest.yaml` 只作为 advisory artifact，记录 phase/file/reason/required/notes，不覆盖 `read_first:`、lazy loading、`skills_whitelist`、workflow descriptor 或 skill manifest；非目标已排除自动注入引擎、descriptor 变更、validator schema hard gate 和 `.trellis/` runtime。`artifacts:` 与 `affected_paths` 覆盖规范、模板、dogfood artifact、skill 文案和 live baseline 更新，verification 可执行。
- next: 推进 IMPLEMENT；只落地规范、模板、写作/审查/测试规则、dogfood artifact 和 validator live baseline，不实现自动注入或 hard gate。

## Implementation Notes
### Run 1 · 2026-06-22 19:27 · runner: Codex
- changed: 新增 `docs/工作流/context-manifest-artifact.md`、`vault-template/模板/上下文清单模板.yaml`、当前任务 dogfood `docs/tasks/context-manifest-advisory/context-manifest.yaml` 与 `task-entity.yaml`；更新 orchestrator writing guide、plan/review/test skills，明确 `context-manifest.yaml` 只是 advisory context metadata，不覆盖 `read_first:`、lazy loading、`skills_whitelist`、workflow descriptor、skill manifest 或自动注入；更新 `tests/verify-lite-artifact-validator.ps1` live baseline 到 24 个 plan-bearing tasks，并把当前任务纳入 expected pass set。
- tests: `Select-String -Path docs/工作流/context-manifest-artifact.md -Pattern 'advisory-only|context-manifest.yaml|phase|file|reason|required|lazy loading|skills_whitelist|不自动注入|plan.md read_first'`; `Select-String -Path vault-template/模板/上下文清单模板.yaml -Pattern 'schema_version|contexts|phase|file|reason|required|notes|forbidden'`; `Select-String -Path skills/orchestrator/references/lite-writing-guide.md,skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md -Pattern 'context-manifest.yaml|Context Manifest|advisory|lazy loading|skills_whitelist|second truth'`; `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId context-manifest-advisory`; `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`。
- risks: 当前工作树存在大量非本任务 dirty paths，validator 对它们输出 warning-only artifact drift；本任务不修改 drift 归一化逻辑，也不新增 context manifest schema hard gate。
- next: CODE_REVIEW 重点检查是否有任何字段或文案把 `context-manifest.yaml` 变成 lazy-loading / `skills_whitelist` / auto-injection 的 second truth，以及本轮是否误改了 P2 非目标文件。

## Code Review
### Run 1 · 2026-06-22 19:34 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 92
- score.accuracy: 91
- score.depth: 90
- findings: none
- review_notes: 新增规范、模板、dogfood artifact、skill 文案和 validator live baseline 均符合计划边界。`context-manifest.yaml` dogfood 只含 `phase`、`file`、`reason`、`required`、`notes` 等 advisory context metadata；复查未发现 `stage/status/verdict/tool/current_phase/next_action/active_task/current_pointer/skills_whitelist/auto_inject/injector/load_by_default/workflow_state` 等 forbidden field key。文档明确 `read_first:` 仍是 Plan 顶部最小入口，context manifest 不覆盖 lazy loading、`skills_whitelist`、workflow descriptor、skill manifest 或自动注入；测试只更新 live baseline 到 24 个 plan-bearing tasks，没有新增 context manifest schema hard gate。当前工作树存在前序 Trellis/Gemini removal dirty paths，validator drift warning 属 warning-only 边界。
- next: 推进 TEST；TEST/Handoff 必须记录 context manifest artifact 已交付、未发现 lazy-loading / skills_whitelist / auto-injection second truth 风险，以及当前 dirty worktree 的 artifact drift warning 边界。
