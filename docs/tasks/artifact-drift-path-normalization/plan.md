---
task_id: artifact-drift-path-normalization
stage: DONE
tool: none
updated: 2026-06-22
---
# Artifact Drift Path Normalization

## Clarification
- work_type: maintenance
- 验收标准: `artifact drift` advisory 能正确比较 Git 返回的非 ASCII repo-relative path 与 `Plan.artifacts` / `Change Contract.affected_paths`；中文路径已声明时不再误报 `changed path is not declared`；warning 仍然 advisory-only，不改变 exit code；validator 回归测试覆盖该场景并通过。
- 非目标: 不新增独立 drift 脚本；不修改 `advance-stage.ps1`、workflow descriptor、stage 拓扑、`.assistant/运行时` 或业务实现文件；不把 artifact drift 升为 hard gate；不引入 `.trellis/`、第二 truth、dashboard/runtime/auto injection/PR automation；不改变既有 hard failure 行为。
- 受影响目录: `scripts/validate-lite-artifacts.ps1`、`tests/verify-lite-artifact-validator.ps1`、`docs/tasks/artifact-drift-path-normalization/plan.md`、`docs/tasks/artifact-drift-path-normalization/test.md`。
- 回滚策略: 回滚 validator 路径采集归一化、对应测试和本任务文档；由于 drift 仍只写 warning，回滚不涉及阶段拓扑或运行时迁移。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: enhance
- affected_paths:
  - docs/tasks/artifact-drift-path-normalization/plan.md
  - docs/tasks/artifact-drift-path-normalization/skill-manifest.json
  - docs/tasks/artifact-drift-path-normalization/test.md
  - scripts/validate-lite-artifacts.ps1
  - tests/verify-lite-artifact-validator.ps1

## Plan
- read_first: [docs/tasks/artifact-drift-advisory/plan.md, scripts/validate-lite-artifacts.ps1, tests/verify-lite-artifact-validator.ps1, skills/orchestrator/references/lite-writing-guide.md]
- convergence:
  - `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern 'core.quotePath|artifact drift|Get-GitChangedPathsForAudit|Normalize-RepoRelativePath'`
  - `Select-String -Path tests/verify-lite-artifact-validator.ps1 -Pattern 'non-ASCII|quotePath|unicode|工作流|changed path is not declared'`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId artifact-drift-path-normalization`
- artifacts: [docs/tasks/artifact-drift-path-normalization/plan.md, docs/tasks/artifact-drift-path-normalization/test.md]
- TODO 1: 复核现有 `artifact-drift-advisory` 实现，确认所有 drift 分支继续只调用 `Add-Warning`，本任务只处理 Git 路径输出/归一化。
- TODO 2: 修正 `Get-GitChangedPathsForAudit` 的 Git 路径采集，使 staged、unstaged、untracked 路径在非 ASCII 场景下以可比较的 repo-relative 字符串进入 `Normalize-RepoRelativePath`。
- TODO 3: 保留非 git worktree、git 不可用、git 子命令失败时的 skipped warning 语义，不把这些情况改成 failure。
- TODO 4: 更新 `tests/verify-lite-artifact-validator.ps1`，新增中文或其他非 ASCII 路径 fixture：文件已在 `artifacts:` / `affected_paths` 声明且实际变更时，validator exit code 为 0，且不出现 `changed path is not declared` drift warning。
- TODO 5: 更新 live validator baseline，纳入本任务计划目录；不得让新增任务导致 live PASS set 失败。
- TODO 6: 跑 Verification 命令，Implementation Notes 记录 changed / tests / risks / next；后续阶段只通过 `.assistant/entry/advance-stage.ps1` 推进。

## Verification
- `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern 'core.quotePath|artifact drift|Get-GitChangedPathsForAudit|Normalize-RepoRelativePath'`
- `Select-String -Path tests/verify-lite-artifact-validator.ps1 -Pattern 'non-ASCII|quotePath|unicode|工作流|changed path is not declared'`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId artifact-drift-path-normalization`

## Risks
- 只修改 Git 参数可能无法覆盖旧版 Git 或异常编码环境。缓解: 回归测试使用真实 git fixture 和非 ASCII 路径，若仍失败再补最小 decode fallback。
- 路径归一化若过宽可能掩盖真实未声明变更。缓解: 不改 `Test-RepoPathCoveredByDeclaration` 的覆盖规则，只让 Git 输出进入同一 repo-relative 字符串形态。
- 新增任务计划会改变 live baseline 数量。缓解: 同步更新 validator 回归脚本的 expected PASS set。

## Plan Review
### Run 1 · 2026-06-22 20:31 · runner: Codex
- verdict: pass
- score.completeness: 92
- score.consistency: 91
- score.accuracy: 90
- score.depth: 88
- findings: none
- evidence: PLAN 聚焦 `artifact drift` 的 Git 路径输出归一化与 validator 回归测试；Clarification、Change Contract、read_first、convergence、Verification 与非目标一致，未引入新脚本、stage、runtime、hard gate 或第二 truth。
- next: 进入 IMPLEMENT；只修复非 ASCII 路径比较噪音，保持所有 drift 结果 warning-only。

## Implementation Notes
### Run 1 · 2026-06-22 20:34 · runner: Codex
- changed: 更新 `scripts/validate-lite-artifacts.ps1` 的 `Get-GitChangedPathsForAudit`，在 git worktree 检测和 staged/unstaged/untracked 路径采集时显式使用 `core.quotePath=false`，让非 ASCII repo-relative path 以可比较字符串进入既有 `Normalize-RepoRelativePath`；更新 `tests/verify-lite-artifact-validator.ps1`，新增 `docs/工作流/unicode-drift.md` fixture，断言已声明中文路径不会触发 `changed path is not declared` warning，并把 live baseline 扩展到本任务。
- tests: `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern 'core.quotePath|artifact drift|Get-GitChangedPathsForAudit|Normalize-RepoRelativePath'` PASS；`Select-String -Path tests/verify-lite-artifact-validator.ps1 -Pattern 'non-ASCII|quotePath|unicode|工作流|changed path is not declared'` PASS；`pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1` PASS；`pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId artifact-drift-path-normalization` STATUS: PASS；`git diff --check` PASS。
- risks: drift 仍保持 advisory-only，所有 drift 分支仍只写 warning；当前任务尚未进入 TEST，`docs/tasks/artifact-drift-path-normalization/test.md` 缺失会作为 artifact drift warning 出现但不影响 exit code。
- next: 进入 CODE_REVIEW，重点复核 Git 路径参数没有改变 hard failure 行为，且新增 fixture 覆盖真实非 ASCII path 比较。

## Code Review
### Run 1 · 2026-06-22 20:34 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 92
- score.accuracy: 91
- score.depth: 90
- findings: none
- evidence: `git diff -- scripts/validate-lite-artifacts.ps1` 只在 artifact drift 的 git worktree/diff/ls-files 采集上增加 `core.quotePath=false`；`git diff -- tests/verify-lite-artifact-validator.ps1` 只新增非 ASCII 路径 fixture 和 live baseline 扩展；`pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId artifact-drift-path-normalization -Quality` STATUS: PASS。
- next: 进入 TEST；重点记录中文路径 drift warning 已消除、warning-only exit code 语义未改变，以及 `test.md` 作为最终 artifact 交付后当前缺失 warning 会消失。
