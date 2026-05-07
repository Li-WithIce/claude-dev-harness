# Workflow Optimization Roadmap Plan Review

Verdict: `revise`

## Findings

### P1 · 这份 plan 目前还不能进入 IMPLEMENT，因为它自己没有通过 `validate-lite-artifacts.ps1`

- `plan.md` 的 Clarification 把 "`scripts/validate-lite-artifacts.ps1 -TaskId workflow-optimization-roadmap` 必须 PASS" 写成了验收标准：`docs/tasks/workflow-optimization-roadmap/plan.md:18`
- 但我实际运行后，validator 返回 `STATUS: FAIL`，唯一错误是 `Verification should contain backticked commands`
- 问题落点在 `Verification` 段：每条命令后面都直接跟了中文说明，例如 `docs/tasks/workflow-optimization-roadmap/plan.md:180-185`
- 在当前 repo 规则下，这不是风格问题，而是 implement blocker。只要 plan 本身 validator 不绿，这份路线图就还不能作为下一步 Phase 的正式输入

### P2 · maestro 来源标注还有 1 处没达到“具体机制编号”的要求，追溯性不够精确

- Clarification 明确要求：每个来源标注都要对应 benchmark 文档里的“具体机制编号”：`docs/tasks/workflow-optimization-roadmap/plan.md:14`
- Phase 5 和 Phase 7 的来源基本满足这个要求：例如 `P5-T1 ← CCW A2`、`P7-T3 ← maestro 推荐项 #2`：`docs/tasks/workflow-optimization-roadmap/plan.md:70-74,150-154`
- 但 `P6-T2` 仍写的是 `maestro ... Section 推荐顶项`，没有具体编号：`docs/tasks/workflow-optimization-roadmap/plan.md:110-113`
- 对照 benchmark 文档，maestro 的推荐项是有显式序号的，`read_first[] / convergence.criteria[]` 对应的是推荐项 `1`：`docs/tasks/claude-maestro-workflow-benchmark/maestro-flow-analysis.md:263-264`
- 这不会改变 Phase 6 的方向，但会让“内生问题驱动 vs 外部来源提炼”的追溯链在这一条上变得模糊

## Open Questions / Assumptions

- 仅按你限定的 5 个 review 点审查后，Phase 5 / 6 / 7 的排序本身是合理的：先文档与协议习惯，再 validator/schema 量化，再最晚引入轻量 hook，依赖链 `5 -> 6 -> 7` 自洽：`docs/tasks/workflow-optimization-roadmap/plan.md:52-55,88-91,128-131`
- 每个 Phase 的 `目标 / 范围 / 非目标 / TODO / 验收 / 回滚 / 风险` 结构也基本闭环，没有明显重开 Phase 1-4、shared-memory-v2、live-migration 主线
- deferred 清单与 `vault-as-truth-source / 单写者 / git 可审` 三条底线总体一致，且明确把 dashboard / server-as-truth-source / 多套运行时留在暂缓区：`docs/tasks/workflow-optimization-roadmap/plan.md:156-176`

## Evidence / Commands

- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId workflow-optimization-roadmap -RepoRoot D:\data\claude-dev-harness`
- `Get-Content -LiteralPath docs/tasks/workflow-optimization-roadmap/plan.md -Raw -Encoding utf8`
- `Select-String -Path docs/tasks/workflow-optimization-roadmap/plan.md -Pattern '^### Phase [567]|^- 来源:|暂缓清单|A1|A2|A3|A4|A5|A6|B3|read_first|convergence|artifact|dashboard|server-as-truth-source|runtime'`
- `Select-String -Path docs/tasks/claude-maestro-workflow-benchmark/claude-code-workflow-analysis.md,docs/tasks/claude-maestro-workflow-benchmark/maestro-flow-analysis.md -Pattern 'A1|A2|A3|A4|A5|A6|B3|read_first|convergence|artifact|推荐'`

## File Existence

This review file exists: `docs/tasks/workflow-optimization-roadmap/plan-review.md`

## Run 2

Verdict: `pass`

### Findings

no findings

### Closure Summary

- blocker 1 已闭合：`Verification` 现在已经改成 validator 可执行的纯反引号命令列表；我实际运行 `scripts/validate-lite-artifacts.ps1 -TaskId workflow-optimization-roadmap` 后结果为 `STATUS: PASS`
- blocker 2 已闭合：`P6-T2` 现在已明确写成 `maestro recommendation #1`，并把 `read_first` / `convergence.criteria` 追溯到 `maestro-flow-analysis.md` 的具体推荐项，而不是模糊的 section 引用
