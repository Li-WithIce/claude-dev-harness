---
task_id: context-preflight-advisory-command
stage: DONE
tool: none
updated: 2026-06-22
---
# Context Preflight Advisory Command

## Clarification
- work_type: feature
- 验收标准: 新增一个显式只读 PowerShell helper，按 `TaskId` 与 `Phase` 读取 `docs/tasks/<task-id>/context-manifest.yaml` 并打印匹配的 file / reason / required / notes；manifest 缺失、phase 无匹配或建议文件缺失只输出 advisory 信息且 exit code 为 0；参数错误才失败；配套测试覆盖命中、缺失、无匹配和 run-validation core 集成；文档说明该命令不自动注入、不影响 stage、lazy loading、`skills_whitelist` 或 validator hard gate。
- 非目标: 不实现 phase-aware 自动注入、host hook、session-start injection、sub-agent push、runtime pointer、workflow-state breadcrumb、`.trellis/` runtime、dashboard、PR automation、validator hard gate 或 `advance-stage.ps1` 集成；不改 workflow descriptor、stage 拓扑、`.assistant/运行时`、skill manifest 生成或 stage skill lazy loading。
- 受影响目录: `scripts/context-preflight.ps1`、`tests/verify-context-preflight.ps1`、`scripts/run-validation.ps1`、`tests/verify-lite-footprint.ps1`、`tests/verify-lite-artifact-validator.ps1`、`docs/工作流/context-manifest-artifact.md`、`docs/tasks/README.md`、`docs/tasks/context-preflight-advisory-command/plan.md`、`docs/tasks/context-preflight-advisory-command/test.md`。
- 回滚策略: 删除新增 helper 与测试，回退 run-validation / footprint / validator baseline / context manifest 文档 / live task README 的本任务 diff；由于命令只读且不接入阶段推进或 runtime，回滚不涉及迁移。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Change Contract
- change_type: feature
- affected_paths:
  - docs/tasks/context-preflight-advisory-command/plan.md
  - docs/tasks/context-preflight-advisory-command/skill-manifest.json
  - docs/tasks/context-preflight-advisory-command/test.md
  - scripts/context-preflight.ps1
  - tests/verify-context-preflight.ps1
  - scripts/run-validation.ps1
  - tests/verify-lite-footprint.ps1
  - tests/verify-lite-artifact-validator.ps1
  - docs/工作流/context-manifest-artifact.md
  - docs/tasks/README.md

## Plan
- read_first: [docs/tasks/trellis-context-injection-feasibility/context-injection-feasibility.md, docs/工作流/context-manifest-artifact.md, vault-template/模板/上下文清单模板.yaml, scripts/run-validation.ps1, tests/verify-lite-footprint.ps1, tests/verify-lite-artifact-validator.ps1]
- convergence:
  - `Select-String -Path scripts/context-preflight.ps1 -Pattern 'context-manifest.yaml|TaskId|Phase|Warnings|Recommendations|exit 0|advance-stage|skills_whitelist'`
  - `Select-String -Path tests/verify-context-preflight.ps1 -Pattern 'matching phase|missing manifest|no matching phase|missing suggested file|ExitCode -eq 0'`
  - `Select-String -Path docs/工作流/context-manifest-artifact.md,docs/tasks/README.md,scripts/run-validation.ps1,tests/verify-lite-footprint.ps1 -Pattern 'context-preflight|advisory-only|verify-context-preflight|current plan-bearing tasks'`
  - `pwsh -NoProfile -File tests/verify-context-preflight.ps1`
  - `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
  - `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId context-preflight-advisory-command`
- artifacts: [scripts/context-preflight.ps1, tests/verify-context-preflight.ps1, docs/tasks/context-preflight-advisory-command/plan.md, docs/tasks/context-preflight-advisory-command/test.md]
- TODO 1: 新增 `scripts/context-preflight.ps1`，参数为 `-TaskId`、`-Phase`、可选 `-RepoRoot`；读取 task-local `context-manifest.yaml`，只打印建议，不读取文件内容、不写任何文件、不调用 `advance-stage.ps1`。
- TODO 2: helper 使用受限 YAML 解析，只支持当前 context manifest 推荐 shape；输出包括 `STATUS: PASS`、manifest path、phase、Recommendations 和 Warnings。manifest 缺失、phase 无匹配、建议文件不存在都保持 exit code 0；只有 `TaskId` / `Phase` 参数缺失或非法 repo root 这类调用错误才非零。
- TODO 3: 新增 `tests/verify-context-preflight.ps1`，用临时 repo fixture 覆盖 matching phase、missing manifest、no matching phase、missing suggested file 仍 exit code 0、参数缺失失败，以及不修改 manifest / target 文件。
- TODO 4: 更新 `scripts/run-validation.ps1` core suite 纳入 `verify-context-preflight.ps1`；更新 `tests/verify-lite-footprint.ps1` 锁定 helper、测试和 core suite 集成。
- TODO 5: 更新 `docs/工作流/context-manifest-artifact.md`，说明 `scripts/context-preflight.ps1` 是可选 advisory preflight，不自动注入、不替代 `read_first:` 或 lazy loading。
- TODO 6: 更新 `docs/tasks/README.md` 的当前 live task 列表，纳入现有 9 个 DONE 任务和本任务，避免历史清理后的任务面说明漂移。
- TODO 7: 更新 `tests/verify-lite-artifact-validator.ps1` live baseline 到新增本任务后的数量，并把本任务加入 expected PASS set。
- TODO 8: 跑 Verification 命令，Implementation Notes 记录 changed / tests / risks / next；后续阶段只通过 `.assistant/entry/advance-stage.ps1` 推进。

## Verification
- `Select-String -Path scripts/context-preflight.ps1 -Pattern 'context-manifest.yaml|TaskId|Phase|Warnings|Recommendations|exit 0|advance-stage|skills_whitelist'`
- `Select-String -Path tests/verify-context-preflight.ps1 -Pattern 'matching phase|missing manifest|no matching phase|missing suggested file|ExitCode -eq 0'`
- `Select-String -Path docs/工作流/context-manifest-artifact.md,docs/tasks/README.md,scripts/run-validation.ps1,tests/verify-lite-footprint.ps1 -Pattern 'context-preflight|advisory-only|verify-context-preflight|current plan-bearing tasks'`
- `pwsh -NoProfile -File tests/verify-context-preflight.ps1`
- `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId context-preflight-advisory-command`

## Risks
- 手写 YAML 解析可能被误用为 schema hard gate。缓解: 只解析当前推荐 shape，解析不到的条目输出 warning，不改变 normal advisory exit code。
- helper 可能被误读为自动注入。缓解: 文档和脚本输出都写明 advisory-only，且不接入 entry、advance-stage、workflow descriptor、lazy loading 或 skill manifest。
- 新增任务会改变 live validator baseline。缓解: 同步更新 `verify-lite-artifact-validator.ps1` 的 current task set。

## Plan Review
### Run 1 · 2026-06-22 20:40 · runner: Codex
- verdict: pass
- score.completeness: 94
- score.consistency: 92
- score.accuracy: 91
- score.depth: 89
- findings: none
- evidence: PLAN 直接承接 `trellis-context-injection-feasibility` 的 recommended next task，范围限定为显式只读 `context-preflight` helper、测试、文档和 live baseline；非目标排除了自动注入、host hook、stage advancement、workflow descriptor、`skills_whitelist`、validator hard gate、`.assistant/运行时` 与 `.trellis/` runtime。
- next: 进入 IMPLEMENT；只实现 advisory 输出和回归测试，保持 normal advisory miss exit code 0。

## Implementation Notes
### Run 1 · 2026-06-22 20:48 · runner: Codex
- changed: 新增 `scripts/context-preflight.ps1`，按 `TaskId` / `Phase` 只读解析 task-local `context-manifest.yaml` 并打印 Recommendations / Warnings；新增 `tests/verify-context-preflight.ps1` 覆盖 matching phase、missing manifest、no matching phase、missing suggested file、缺少 TaskId 和不修改文件；更新 `scripts/run-validation.ps1` 将该测试纳入 core suite，并固定 UTF-8 输入/输出编码，保证重定向执行下嵌套 validator 的中文路径比较稳定；更新 `tests/verify-lite-footprint.ps1`、`tests/verify-lite-artifact-validator.ps1`、`docs/工作流/context-manifest-artifact.md` 与 `docs/tasks/README.md`。
- tests: `Select-String -Path scripts/context-preflight.ps1 -Pattern 'context-manifest.yaml|TaskId|Phase|Warnings|Recommendations|exit 0|advance-stage|skills_whitelist'` PASS；`Select-String -Path tests/verify-context-preflight.ps1 -Pattern 'matching phase|missing manifest|no matching phase|missing suggested file|ExitCode -eq 0'` PASS；`Select-String -Path docs/工作流/context-manifest-artifact.md,docs/tasks/README.md,scripts/run-validation.ps1,tests/verify-lite-footprint.ps1 -Pattern 'context-preflight|advisory-only|verify-context-preflight|current plan-bearing tasks'` PASS；`pwsh -NoProfile -File tests/verify-context-preflight.ps1` PASS；`pwsh -NoProfile -File tests/verify-lite-footprint.ps1` PASS；`pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1` PASS；`pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId context-preflight-advisory-command` STATUS: PASS；`pwsh -NoProfile -File scripts/run-validation.ps1 -Suite core` PASS；`git diff --check` PASS。
- risks: YAML 解析保持受限，不尝试成为 schema validator；helper 仍是显式命令，不接入 `.assistant/entry`、`advance-stage.ps1`、workflow descriptor、lazy loading、`skills_whitelist`、skill manifest 或 validator hard gate。当前任务尚未进入 TEST，`test.md` 缺失会作为 artifact drift warning 出现但不影响 exit code。
- next: 进入 CODE_REVIEW，重点复核 helper 是否完全只读、run-validation UTF-8 变更是否只影响执行稳定性，以及 live task README 是否匹配当前 plan-bearing task set。

## Code Review
### Run 1 · 2026-06-22 20:49 · runner: Codex
- verdict: pass
- score.completeness: 95
- score.consistency: 93
- score.accuracy: 92
- score.depth: 90
- findings: none
- evidence: 新增 `scripts/context-preflight.ps1` 只读 task-local `context-manifest.yaml` 并输出 Recommendations / Warnings；未发现 `Set-Content`、`WriteAllText`、`New-Item`、`Remove-Item`、`advance-stage` 调用、workflow descriptor 写入或 skill manifest 写入。`pwsh -NoProfile -File scripts/context-preflight.ps1 -TaskId trellis-context-injection-feasibility -Phase IMPLEMENT` 输出真实 manifest 建议且 Warnings 为 none；`pwsh -NoProfile -File scripts/run-validation.ps1 -Suite core` STATUS: PASS。
- next: 进入 TEST；记录 helper 是显式只读 advisory command，run-validation UTF-8 修复只稳定重定向验证，不改变阶段推进或 validator hard gate。
