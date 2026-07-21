# Test Report

> Historical TEST snapshot for revision `a061cacf...`. It is preserved as process evidence and superseded by Master Plan Runs 107-113 for the final public-Harness scope and exact head `acccb30d...`.

## Summary
- Release Qualification 独立重审已否证当前交付完整性：除真实 Direct host latency 尚缺外，仍存在 CI 报告交付、真实模型 Eval、真实 bare/v1/v2 runner、损坏 v2 artifact、Protected Actions 扩展合同与 CHANGELOG 六项可修复缺口；当前结论为 fail。

## Scope
- PR-00 至 PR-14 的代码、测试、迁移/兼容、rollout gate、声明 artifact 与总体 Definition of Done。

## Inputs Reviewed
- `docs/tasks/thin-harness-v2-refactor/plan.md`
- base diff `codex/harness-distribution...a061cacf3a9c32b3b96d0fb32810085fc3031064`
- Release workflow、rollout generator、protocol detector、deterministic Eval、benchmark、Protected Actions、README 与 release/testing 文档。

## Test Approach
- 重新读取 Master Plan、base diff 与 Release Qualification 相关实现面。
- 用单条只读审计命令检查报告持久化、真实模型调用、真实 host runner、损坏 v2 artifact 识别、policy extension contract 与 CHANGELOG 交付。
- 保留 local fixture replay 与真实 Direct host trace 的证据边界，不用模拟或本地解析耗时替代发布性能证据。

## Findings
- `.github/workflows/validation.yml` 只把 rollout report 写入 `RUNNER_TEMP`，没有 artifact upload 或其他持久发布步骤，安装/工作区也没有默认发现链路。
- `tests/run-scenario-evals.ps1` 明确把 external model 标为 unavailable，未把 paraphrase 交给全新 Codex 会话；`scripts/benchmark-harness.ps1` 只读取 fixture observation 并测量本地 JSON replay，没有真实 bare/v1/v2 host runner。
- `Harness.Protocol.psm1` 仅凭 `task.json` 路径存在就判定 v2，未在 detector 中校验 UTF-8、schema 与 task identity；损坏 artifact 会被当作 existing-v2。
- `Harness.ProtectedAction.psm1` 把两条内置 rule id 写死为精确全集，既无项目级 overlay，也没有正式 core-only extension contract。
- `CHANGELOG.md` 相对 base 没有更新；README 与现有发布文档也未覆盖真实模型 Eval、报告安装/发现和完整故障排查。
- 以上均为当前分支可修复缺陷，因此不能继续用 environment-blocked 表达；应返回 IMPLEMENT。真实 Direct 性能仍须在修复 runner 后实测，未测前仍不得翻转默认。

## Evidence
- command: `pwsh -NoProfile -NonInteractive -Command '<release qualification six-gap read-only audit>'`
- exit_code: 1
- executed_at: 2026-07-15T09:24:03+08:00
- revision: a061cacf3a9c32b3b96d0fb32810085fc3031064
- evidence_path: `docs/tasks/thin-harness-v2-refactor/test.md`

## Risks / Gaps
- 尚未捕获同模型、Max、同语义任务、新隔离会话的 bare/v1/v2 Direct host latency、turns 与 tool calls。
- 尚未创建 Draft PR 或运行远程 pr-core、changed-optional、release-full；不能把本地历史结果当作远程 CI pass。
- v1 必须继续处于 deprecation-without-removal；返修不得删除、自动迁移或破坏即时回滚路径。

## Conclusion
fail

## Handoff
- delivery: PR-00 至 PR-14 的既有实现和历史验证保留；本轮新增的是独立 Release Qualification 六项失败证据，没有伪造修复或远程验证结果。
- follow_up: 用正式 stage advancement 返回 IMPLEMENT，按 release-gap checklist 最小修复；完成真实模型 Eval/性能、rollout delivery、文档与健壮性后重新审查和 TEST。
- artifact: 既有 Plan artifact 保留；RQ checklist 尚待在 IMPLEMENT 作为现有任务附件生成，不能成为第二 Master Plan。
- drift: 当前新增 drift 为 RQ 六项实现/交付缺口；base branch、v1 源码和既有 task artifact 未修改。
- follow_up_decision: 不拆新任务；Release Qualification 是当前 Master Plan 的交付闭环。
- memory_spec_update: none；用户未授权写入外部 memory，Master Plan 仍是唯一真相源。
- current_state: TEST fail；实现 HEAD 为 `a061cacf3a9c32b3b96d0fb32810085fc3031064`，等待正式推进到 IMPLEMENT。
- key_decisions:
  - decision: 不把 deterministic Eval、local fixture replay 或临时 CI 文件当作真实模型、真实 Direct 性能或已交付 rollout report。
    why: Release Qualification 要求独立新会话、measured host trace 与可发现的持久报告，且所有 unavailable 必须 fail closed。
- next_actions:
  - 正式推进 `TEST -> IMPLEMENT`，生成并执行 release-gap checklist。
  - 修复六项缺口并完成本地、远程、模型、性能和独立审查证据。
  - 重新进入 TEST；全部 gate 真实 pass 后才推进 DONE，始终禁止 merge 与删除 v1。
