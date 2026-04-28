# Phase 7 Code Review

## Findings

### P2 - `artifacts:` 仍“不做 path 存在性 / 交叉引用校验”的合同没有被回归唯一锁住

- `scripts/validate-lite-artifacts.ps1:384-408` 当前实现对 `artifacts:` 只做语法检查，符合 plan。
- 但 `tests/verify-lite-artifact-validator.ps1:411-518` 的新增 fixture 只覆盖了：
  - 合法 inline-array
  - block-list 非法
  - 空数组非法
  - metadata 位置非法
- 其中唯一的合法样例 `tests/verify-lite-artifact-validator.ps1:411-417` 使用的全是仓库里已存在的路径：`docs/工作流/single-writer-precompact.md` 和 `scripts/validate-lite-artifacts.ps1`。
- 因此，若未来有人把 validator 回归成“要求 artifact path 必须存在”或“要求 artifacts 必须和 `affected_paths` 对齐”，这套回归仍可能继续全绿。Phase 7 明确批准的“仍不做 path 存在性/交叉引用校验”合同现在还没有被测试唯一锁住。

### P3 - P7-T4 的双向引用合同只锁住了一半，`workflow-team` 的反向链接仍无回归保护

- `docs/工作流/single-writer-precompact.md:68-75` 当前正文是正确的，确实同时反向绑定了 `skills/orchestrator/SKILL.md` 和 `skills/workflow-team/SKILL.md`。
- 但 `tests/verify-lite-footprint.ps1:359-369` 只断言：
  - 两个 skill 文件都提到 `single-writer-precompact.md`
  - 协议文档里包含 `skills/orchestrator/SKILL.md`
- 它没有断言协议文档也包含 `skills/workflow-team/SKILL.md`。如果以后这条 backlink 被删掉，当前 footprint suite 仍会通过。

## Open Questions / Assumptions

- 无。评审按 Leader 指定的 Phase 7 surface 执行；工作区中其他脏文件视为既有背景噪音，不作为本轮 scope drift finding。

## Change Summary

- P7-T1 / P7-T4 主实现口径是对的：当前文本已基于真实 inbox 入口 `append-runtime-inbox.ps1`，并把所有非 append 写回一致委托给现有 `advance-stage.ps1` 语义。
- P7-T2 也保持在已裁定的 A 方案，没有创建 `skills/*/phases/` 或 `docs/工作流/skill-phase-loading.md`。
- 当前需要补的是 regression locking，而不是重新设计主实现。

## Evidence

- `git diff --unified=0 -- scripts/validate-lite-artifacts.ps1 skills/orchestrator/SKILL.md skills/workflow-team/SKILL.md skills/plan/SKILL.md skills/orchestrator/references/lite-writing-guide.md tests/verify-lite-artifact-validator.ps1 tests/verify-lite-footprint.ps1`
- `Get-Content .\docs\工作流\single-writer-precompact.md`
- `Get-ChildItem .\skills -Recurse -Directory -Filter phases`
- `Test-Path .\docs\工作流\skill-phase-loading.md`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-artifact-validator.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`
- `git diff --name-only -- . ':(exclude)docs/tasks/**'`
