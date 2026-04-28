# Phase 6 Code Review

## Findings

### P2 - `.gitignore` 行为今天正确，但没有被回归测试真正锁住

- `tests/verify-lite-footprint.ps1:257-267` 只断言 `.gitignore` 里存在 `!.assistant/运行时/`、`.assistant/运行时/*` 和 4 条 wisdom 文件例外。
- 但计划要求锁的是**行为**，不是只锁文字：4 个 wisdom 文件必须不再被 ignore，而 `记忆候选.md` / `记忆候选归档.md` / `收件箱.md` 仍必须继续命中 ignore（`docs/tasks/phase6-quality-score-hard-constraints/plan.md:163-165`）。
- 我现场手工复核时，当前实现确实满足这个合同；不过仓库里的自动回归并没有执行 `git check-ignore -v`。这意味着未来如果有人把规则误改成更宽的 allow 形式，只要保留这些字面行，`verify-lite-footprint.ps1` 仍可能继续全绿。

### P2 - `-Quality` 的旧任务兼容与 live baseline 收敛只被人工验证，没有入回归

- `tests/verify-lite-artifact-validator.ps1:372-474` 现在覆盖了 warning-only legacy fixture、合法 metadata fixture、以及 scored / mismatch fixture，这证明局部行为是对的。
- 但计划明确要求验证当前现场的 zero-regression baseline：13 个含 `plan.md` 的任务里，默认模式保持 `9 PASS / 4 FAIL`，并且 `-Quality` 不能把旧任务从 PASS 打成 FAIL（`docs/tasks/phase6-quality-score-hard-constraints/plan.md:94-98,128`）。
- 我实际批量重跑后确认当前现场仍是同一组 `9 PASS / 4 FAIL`，`-Quality` 也没有新增失败；问题在于这条合同没有被任何入库测试锁住，所以后续改动仍可能只通过 fixture、却悄悄打坏 live corpus。

### P3 - `read_first` / `convergence` 的“必须位于 Plan 顶部 metadata 块”合同已实现，但缺少对应负例

- `scripts/validate-lite-artifacts.ps1:336-368` 已实现“`read_first:` / `convergence:` 出现在第一条普通 Plan bullet 之后就报错”，这和计划批准口径一致（`docs/tasks/phase6-quality-score-hard-constraints/plan.md:109-110`）。
- 但 `tests/verify-lite-artifact-validator.ps1:383-430` 只测了合法 metadata、block-list `read_first`、以及 placeholder-only `convergence`，没有新增“metadata 放错位置必须 FAIL”的负例。
- 结果是：当前代码没问题，但这条已批准的格式约束还没有被测试唯一锁住。

## Open Questions / Assumptions

- 无。评审按 Leader 指定的 Phase 6 surface 执行；工作区里其他脏文件视为既有背景噪音，不作为本轮 scope drift finding。

## Change Summary

- 当前实现面与计划主线基本一致：`[switch]$Quality` 已落地，legacy review run 在 `-Quality` 模式下保持 warning-only；`read_first` / `convergence` 已按 metadata-style 解析；`agent-configs/workflows/harness-lite.yaml` 只改了注释，未改 YAML 实体；4 个 wisdom 文件也已通过 `.gitignore` 精确例外进入 git 审计面。
- 本轮 blocker 不在实现结果本身，而在回归锁定还不够完整。

## Evidence

- `git diff --name-only -- scripts/validate-lite-artifacts.ps1 agent-configs/workflows/harness-lite.yaml skills/plan/SKILL.md skills/review/SKILL.md skills/orchestrator/references/lite-writing-guide.md skills/obsidian-memory/SKILL.md docs/工作流/quality-rubric.md .gitignore .assistant/运行时/记忆-学习.md .assistant/运行时/记忆-决策.md .assistant/运行时/记忆-约定.md .assistant/运行时/记忆-问题.md tests/verify-lite-artifact-validator.ps1 tests/verify-lite-footprint.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-artifact-validator.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`
- `git check-ignore -v -- .assistant/运行时/记忆候选.md .assistant/运行时/记忆候选归档.md .assistant/运行时/收件箱.md`
- `git check-ignore -v -- .assistant/运行时/记忆-学习.md .assistant/运行时/记忆-决策.md .assistant/运行时/记忆-约定.md .assistant/运行时/记忆-问题.md`
- 批量现场探针：对当前 13 个 `docs/tasks/*/plan.md` 逐个执行 `scripts/validate-lite-artifacts.ps1` 的默认模式与 `-Quality` 模式；结果两组集合一致，均为 `9 PASS / 4 FAIL`
