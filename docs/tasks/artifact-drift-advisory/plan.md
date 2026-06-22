---
task_id: artifact-drift-advisory
stage: DONE
tool: none
updated: 2026-06-22
---
# Artifact Drift Advisory

## Clarification
- work_type: maintenance
- 验收标准: 在现有 `scripts/validate-lite-artifacts.ps1` 中增加 artifact drift advisory；只通过 `Add-Warning` 写入 `Warnings:`，不写 `Add-Failure`，不改变 exit code；配套更新 validator 测试，覆盖 warning 出现且退出码仍为 0；必要时更新 `lite-writing-guide.md` 说明该检查是 advisory-only。
- 非目标: 不新增独立 drift 脚本；不修改 `advance-stage.ps1` 阶段拓扑、workflow descriptor、skills 主流程、`.assistant/运行时` 或业务实现文件；不把 artifact drift 升为 hard gate；不引入 `.trellis/`、第二 truth、dashboard/runtime/auto injection/PR automation。
- 受影响目录: `scripts/validate-lite-artifacts.ps1`、`tests/verify-lite-artifact-validator.ps1`、`skills/orchestrator/references/lite-writing-guide.md`。
- 回滚策略: 回滚 validator、测试和写作指南的本任务 diff；由于 warning 不改变 exit code，回滚不会涉及阶段状态迁移。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: enhance
- affected_paths:
  - scripts/validate-lite-artifacts.ps1
  - tests/verify-lite-artifact-validator.ps1
  - skills/orchestrator/references/lite-writing-guide.md

## Plan
- read_first: [docs/tasks/trellis-comparison-reusable-design/discussion-meeting-notes.md, docs/tasks/trellis-comparison-reusable-design/trellis-source-based-corrections.md, docs/tasks/trellis-comparison-reusable-design/gap-analysis.md, docs/tasks/finish-boundary-checklist/plan.md, scripts/validate-lite-artifacts.ps1, tests/verify-lite-artifact-validator.ps1, skills/orchestrator/references/lite-writing-guide.md]
- convergence:
  - `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern 'Add-Warning|Warnings:|artifact drift|affected_paths|artifacts'`
  - `Select-String -Path tests/verify-lite-artifact-validator.ps1 -Pattern 'artifact drift|Warnings:|ExitCode -eq 0|Add-Warning|untracked|PLAN stage|IMPLEMENT stage'`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId artifact-drift-advisory`
- artifacts: [scripts/validate-lite-artifacts.ps1, tests/verify-lite-artifact-validator.ps1, skills/orchestrator/references/lite-writing-guide.md]
- TODO 1: 采用单一实现方案: 扩展现有 `scripts/validate-lite-artifacts.ps1`，不新增独立脚本。理由是 validator 已有 `Warnings:`、`Add-Warning` 和 exit-code 隔离语义；另建脚本会产生第二个检查入口，让 `advance-stage` 与人工验证口径分裂。
- TODO 2: 新增 stage-aware artifact drift advisory。PLAN/PLAN_REVIEW 阶段不得因为未来 artifact 尚未创建而 warning；IMPLEMENT/CODE_REVIEW/TEST/DONE 阶段才比较 `Plan.artifacts`、`Change Contract.affected_paths`、工作树 diff 和文件存在性。
- TODO 3: 工作树 diff 口径使用 repo-relative 路径，覆盖 staged、unstaged 和 untracked 文件；如果当前目录不是 git worktree 或 git 命令不可用，只用 `Add-Warning` 说明 drift audit skipped，不得失败。
- TODO 4: warning 类别只进入 `$script:Warnings`: 未声明的 changed path、声明 artifact 在应存在阶段缺失、`artifacts:` 与 `affected_paths` 角色明显混淆时提示人工确认。路径重叠本身不得自动视为混用，因为文档/skill 任务中同一文件可能既是变更面也是交付产物；只有当路径角色无法从 task type、Plan.artifacts 或 Change Contract 解释时才 warning。不得把这些问题加入 `$script:Failures`，不得改变现有 invalid syntax、frontmatter、section、handoff 的 hard failure 行为。
- TODO 5: 更新 `tests/verify-lite-artifact-validator.ps1`。保留现有 metadata syntax hard checks；把当前“artifacts 不 cross-validated against affected_paths”的旧期望改为 advisory warning 期望；新增 fixture 覆盖 PLAN stage 不提示未来 artifact、IMPLEMENT stage 缺失 artifact 提示 warning、untracked changed path 提示 warning、warning 出现时 validator exit code 仍为 0、旧任务缺少 `artifacts:` 或 `Change Contract` 仍合法。
- TODO 6: 更新 `skills/orchestrator/references/lite-writing-guide.md` 的相关说明，明确 artifact drift 是 reviewer/tester 的 advisory signal，不是 PLAN/TEST 的硬通过条件；旧任务缺少 `artifacts:` 或 `Change Contract` 时继续合法。
- TODO 7: 新窗口执行前本任务应已处于 `IMPLEMENT`。若 frontmatter 仍是 `PLAN` 或 `PLAN_REVIEW`，先通过 `.assistant/entry/advance-stage.ps1 -TaskId artifact-drift-advisory` 推进，不要重写计划或重复发起 plan review。

## Verification
- `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern 'Add-Warning|Warnings:|artifact drift|affected_paths|artifacts'`
- `Select-String -Path tests/verify-lite-artifact-validator.ps1 -Pattern 'artifact drift|Warnings:|ExitCode -eq 0|Add-Warning|untracked|PLAN stage|IMPLEMENT stage'`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId artifact-drift-advisory`

## Risks
- Advisory 误写成 hard gate 会阻断旧任务。缓解: 所有 drift 分支只调用 `Add-Warning`，测试必须断言 exit code 0。
- PLAN 阶段对未来 artifact 报 warning 会造成噪声。缓解: artifact 存在性和 diff 对比从 IMPLEMENT 及之后阶段启用，PLAN/PLAN_REVIEW 只保留现有语法校验。
- 独立脚本看似更隔离但会造成第二验证入口。缓解: 本计划明确选择现有 validator warning 分支，不新增命令入口。

## Plan Review
### Run 1 · 2026-06-22 17:16 · runner: Codex
- verdict: pass
- score.completeness: 95
- score.consistency: 94
- score.accuracy: 92
- score.depth: 91
- findings: none
- next: 进入 IMPLEMENT 时只实现 validator advisory warning 与配套测试，不改 exit code 或阶段拓扑。

### Run 2 · 2026-06-22 17:45 · runner: Codex
- verdict: pass
- score.completeness: 96
- score.consistency: 95
- score.accuracy: 94
- score.depth: 92
- findings: none
- optimization_notes: 将 work_type 收敛为 maintenance；把“artifacts/affected_paths 重叠”从自动 warning 改为角色混淆 warning，降低文档/skill 任务误报；补齐 PLAN/IMPLEMENT stage、untracked path、旧任务兼容的测试要求；增加 stage 交接要求。
- next: 推进到 IMPLEMENT 后只实现 validator advisory warning、测试和写作指南说明，不改 exit code 或阶段拓扑。

## Implementation Notes
### Run 1 · 2026-06-22 18:23 · runner: Codex
- changed: 扩展 `scripts/validate-lite-artifacts.ps1`，新增 stage-aware artifact drift advisory，统一 repo-relative path、读取 staged/unstaged/untracked git diff，并只用 `Add-Warning` 报告缺失 artifact、未声明 changed path 和明显角色混淆；更新 `tests/verify-lite-artifact-validator.ps1`，覆盖 PLAN stage 不提示未来 artifact、IMPLEMENT stage 缺失 artifact warning、untracked changed path warning、warning exit code 0、旧任务缺少声明仍合法；更新 `skills/orchestrator/references/lite-writing-guide.md`，说明 drift audit 是 advisory-only 且旧任务继续合法。
- tests: `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern 'Add-Warning|Warnings:|artifact drift|affected_paths|artifacts'` pass；`Select-String -Path tests/verify-lite-artifact-validator.ps1 -Pattern 'artifact drift|Warnings:|ExitCode -eq 0|Add-Warning|untracked|PLAN stage|IMPLEMENT stage'` pass；`pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1` pass；`pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId artifact-drift-advisory` STATUS: PASS.
- risks: 当前仓库已有大量与本任务无关的 dirty/untracked paths，artifact drift audit 会按设计输出较多 warning；这些 warning 不改变 exit code，也不进入 Errors。
- next: 进入 CODE_REVIEW 时重点确认所有 drift 分支都只调用 `Add-Warning`，且 PLAN/PLAN_REVIEW 阶段不对未来 artifact 发 warning。

## Code Review
### Run 1 · 2026-06-22 18:37 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 92
- score.accuracy: 91
- score.depth: 90
- findings: none
- review_notes: `Assert-ArtifactDriftAdvisory` 只在 `IMPLEMENT` / `CODE_REVIEW` / `TEST` / `DONE` 运行，PLAN/PLAN_REVIEW 只记录 skipped check；缺失 artifact、未声明 changed path、git 不可用等分支均进入 `Add-Warning`，未写入 `Add-Failure`，配套测试覆盖 PLAN 未来 artifact 不 warning、IMPLEMENT 缺失 artifact warning-only、untracked path warning-only、warning exit code 0 和旧任务无声明仍合法。当前同一工作树中存在去 Gemini 支持相关改动，其中部分同文件 diff 不属于本任务；这些会被新 advisory 作为 warning 输出，符合本任务预期，但提交/收尾时必须独立处理。
- next: 推进到 TEST，测试报告重点记录 advisory-only exit code、PLAN 阶段无噪声和 out-of-scope dirty tree drift。
