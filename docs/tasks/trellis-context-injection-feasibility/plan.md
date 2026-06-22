---
task_id: trellis-context-injection-feasibility
stage: DONE
tool: none
updated: 2026-06-22
---
# Trellis Context Injection Feasibility

## Clarification
- work_type: explore
- 验收标准:
  1. 基于 `trellis-source-based-corrections.md` 中的源码勘误，明确 Trellis context injection 是运行时 hook / engine 能力，不等同于本仓库已落地的 `context-manifest.yaml` advisory artifact。
  2. 产出 `context-injection-feasibility.md`，判断 dev-harness 当前是否适合实现 phase-aware 自动注入，并给出 `adopt now` / `adapt later` / `defer` / `reject` 路线。
  3. 明确保留 `plan.md read_first:`、stage skill lazy loading、workflow descriptor `skills_whitelist`、`context-manifest.yaml` advisory-only 边界，避免任何 second truth。
  4. 本任务只做可行性设计和上下文清单 dogfood；不改 `.assistant/entry`、`scripts/advance-stage.ps1`、workflow descriptor、skill manifest 生成、validator hard gate、runtime mirror 或 host hook 集成。
  5. `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId trellis-context-injection-feasibility` 必须 PASS。
- 非目标:
  - 不实现 phase-aware 自动注入、session-start hook、workflow-state breadcrumb、sub-agent context push、host plugin、Codex/Claude runtime adapter 或 `.trellis/` 目录。
  - 不修改 `agent-configs/workflows/harness-lite.yaml`、`.assistant/entry/AGENTS.md`、`.assistant/entry/advance-stage.ps1`、`.assistant/entry/validate-lite-artifacts.ps1`、`scripts/advance-stage.ps1`、`scripts/validate-lite-artifacts.ps1`、skills、tests 或 runtime pointer。
  - 不把 `context-manifest.yaml` 升级成加载配置、`skills_whitelist`、workflow descriptor、active pointer、current task 或 stage truth。
  - 不推进 `subtask-roadmap-artifact`、`session-case-artifact`、dashboard/runtime、PR automation 或 hard gate。
- 受影响目录:
  - `docs/tasks/trellis-context-injection-feasibility/plan.md`
  - `docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md`
  - `docs/tasks/trellis-context-injection-feasibility/context-manifest.yaml`
- 回滚策略: 删除 `docs/tasks/trellis-context-injection-feasibility/` 目录，并由 `.assistant/entry/advance-stage.ps1` 负责恢复后续阶段 mirror；由于不改脚本、skills、descriptor、validator 或 runtime 协议，无需代码回滚。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: task
- affected_paths:
  - docs/tasks/trellis-context-injection-feasibility/plan.md
  - docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md
  - docs/tasks/trellis-context-injection-feasibility/context-manifest.yaml

## Plan
- read_first: [docs/tasks/trellis-comparison-reusable-design/trellis-source-based-corrections.md, docs/tasks/trellis-comparison-reusable-design/trellis-reusable-design.md, docs/tasks/context-manifest-advisory/plan.md, docs/工作流/context-manifest-artifact.md, skills/orchestrator/references/lite-writing-guide.md]
- convergence:
  - `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md -Pattern 'Trellis context injection|运行时|advisory-only|不自动注入|read_first|lazy loading|skills_whitelist|workflow descriptor|second truth'`
  - `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md -Pattern 'adopt now|adapt later|defer|reject|host hook|Codex|Claude'`
  - `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-manifest.yaml -Pattern 'schema_version|contexts|phase|file|reason|required|notes'`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId trellis-context-injection-feasibility`
- artifacts: [docs/tasks/trellis-context-injection-feasibility/plan.md, docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md, docs/tasks/trellis-context-injection-feasibility/context-manifest.yaml]
- TODO 1: 固定事实边界：Trellis context injection 是由 hooks / scripts 在 session start、workflow state、sub-agent launch 等时机主动注入的 runtime engine；dev-harness 当前只有 `read_first:` 与 advisory `context-manifest.yaml`。
- TODO 2: 分析 dev-harness 现有入口和 truth-source 边界，说明为什么不能在本轮把 context manifest 直接接入 lazy loading、`skills_whitelist`、workflow descriptor 或 skill manifest。
- TODO 3: 产出 feasibility matrix，至少覆盖 Codex、Claude Code、通用 CLI/PowerShell harness 三类宿主的可行性、依赖、风险和推荐动作。
- TODO 4: 给出路线分级：`adopt now` 仅限写作/审查提示；`adapt later` 限定为显式 preflight / host-specific adapter 研究；`defer` 自动注入引擎；`reject` 第二 truth / `.trellis/` runtime / descriptor 反写。
- TODO 5: 新增本任务 `context-manifest.yaml` dogfood，只列本任务阶段需要读取的文件和原因；不得包含 forbidden fields，不得表达自动注入。
- TODO 6: 运行 Verification，并在 Implementation Notes 记录 changed / tests / risks / next。

## Verification
- `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md -Pattern 'Trellis context injection|运行时|advisory-only|不自动注入|read_first|lazy loading|skills_whitelist|workflow descriptor|second truth'`
- `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md -Pattern 'adopt now|adapt later|defer|reject|host hook|Codex|Claude'`
- `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-manifest.yaml -Pattern 'schema_version|contexts|phase|file|reason|required|notes'`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId trellis-context-injection-feasibility`

## Risks
- 容易把 Trellis 的 runtime injection 误读成当前可直接落地的 `context-manifest.yaml` schema 扩展。缓解: 本任务只做 feasibility，不改任何消费端。
- 自动注入会绕开用户可审的 lazy loading 与 `read_first:`。缓解: 任何后续实现必须另开 task，并保留显式 opt-in 与单一 truth-source。
- 当前工作树已有大量 unrelated dirty paths，artifact drift advisory 会输出 warning-only 噪声。缓解: 本任务只把自身新增 task 目录列为 affected paths，并在 Handoff 记录 drift 边界。

## Plan Review

### Run 1 · 2026-06-22 19:43 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 93
- score.accuracy: 92
- score.depth: 91
- findings: none
- review_notes: PLAN 明确把本任务限定为 `work_type: explore` 的可行性设计，`context-injection-feasibility.md` 与 `context-manifest.yaml` 是唯一新增产物；非目标排除了 `.trellis/` runtime、phase-aware 自动注入、host hook adapter、workflow descriptor / `skills_whitelist` 变更、skill manifest 生成、validator hard gate 和 runtime mirror 协议修改。`read_first:` 覆盖 Trellis 源码勘误、已完成 context manifest 规范与 writing guide；Verification 命令可执行，足以检查 `advisory-only`、`read_first`、lazy loading、`skills_whitelist`、workflow descriptor 与 second truth 边界。
- next: 推进 IMPLEMENT；只产出 feasibility 文档和本任务 context manifest dogfood，不改脚本、skills、tests、descriptor 或 runtime 入口。

## Implementation Notes

### Run 1 · 2026-06-22 19:44 · runner: Codex
- changed: 完成可行性设计与 context manifest dogfood。
  - 新增 `docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md`，结论为当前不实现 Trellis 式自动 context injection；保留 `context-manifest.yaml` advisory-only，建议后续只评估显式 `context-preflight` 类只读 helper。
  - 新增 `docs/tasks/trellis-context-injection-feasibility/context-manifest.yaml`，仅记录本任务 PLAN_REVIEW / IMPLEMENT / CODE_REVIEW / TEST 的 file、reason、required、notes，不包含 loading / injection / stage truth 字段。
- tests: 已执行计划中的 Verification。
  - `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md -Pattern 'Trellis context injection|运行时|advisory-only|不自动注入|read_first|lazy loading|skills_whitelist|workflow descriptor|second truth'`
  - `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md -Pattern 'adopt now|adapt later|defer|reject|host hook|Codex|Claude'`
  - `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-manifest.yaml -Pattern 'schema_version|contexts|phase|file|reason|required|notes'`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId trellis-context-injection-feasibility` -> STATUS: PASS。
- risks: 当前仓库存在大量非本任务 dirty paths，artifact drift advisory 会继续输出 warning-only 噪声；本任务没有修改脚本、skills、tests、workflow descriptor、runtime mirror 或自动注入入口。
- next: CODE_REVIEW 重点检查 feasibility 文档是否仍把自动注入定为 defer/reject 边界，`context-manifest.yaml` 是否没有 forbidden fields，且本轮 diff 是否只落在 task 目录内。

## Code Review

### Run 1 · 2026-06-22 19:45 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 93
- score.accuracy: 92
- score.depth: 90
- findings: none
- reviewer notes:
  - 实现只新增本 task 目录下的 `context-injection-feasibility.md` 与 `context-manifest.yaml`，并追加本 plan 的 Implementation Notes；未修改脚本、skills、tests、workflow descriptor、runtime mirror、validator hard gate 或自动注入入口。
  - `context-injection-feasibility.md` 明确当前不实现 Trellis 式 runtime injection；`adopt now` 仅限审查 / Handoff 口径，`adapt later` 限定为显式只读 preflight helper，自动注入为 `defer`，second truth / `.trellis/` runtime / descriptor 反写为 `reject`。
  - `context-manifest.yaml` 只包含 `schema_version`、`summary`、`contexts`、`phase`、`file`、`reason`、`required`、`notes` 等 advisory context metadata；抽查未发现 `stage/status/verdict/tool/current_phase/next_action/active_task/current_pointer/skills_whitelist/auto_inject/injector/load_by_default/workflow_state` 作为 YAML key。
- evidence:
  - `Select-String -Path docs/tasks/trellis-context-injection-feasibility/context-manifest.yaml -Pattern '^\s*(stage|status|verdict|tool|current_phase|next_action|active_task|current_pointer|skills_whitelist|auto_inject|injector|load_by_default|workflow_state)\s*:'` -> no matches。
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId trellis-context-injection-feasibility` -> STATUS: PASS；broader dirty tree artifact drift 为 warning-only。
- next: 推进 TEST；TEST/Handoff 记录 feasibility artifact 已交付、context manifest 保持 advisory-only、后续如做 automation 需拆 `context-preflight-advisory-command`。
