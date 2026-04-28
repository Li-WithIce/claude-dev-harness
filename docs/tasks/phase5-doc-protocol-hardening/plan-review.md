# Phase 5 Doc Protocol Hardening Plan Review

Verdict: `revise`

## Findings

### P1 · 已裁定的 auto-mode 注释落点还没有完全 baked-in，`affected_paths` 仍保留了被否决的 sidecar 文档分支

- 已裁定项 2 明确要求：auto-mode 说明固定写在 `agent-configs/workflows/harness-lite.yaml` 的注释段里，不再允许拆到同级 sidecar 文档：`docs/tasks/phase5-doc-protocol-hardening/plan.md:172`
- `TODO P5-T1` 的正文也已经按这个口径收紧为“仅在 `harness-lite.yaml` 顶部注释块补齐说明”：`docs/tasks/phase5-doc-protocol-hardening/plan.md:63-77`
- 但 `受影响目录` 仍写成“仅在文件顶部注释段或新建同级 `harness-lite.notes.md` 中追加 auto-mode 说明”：`docs/tasks/phase5-doc-protocol-hardening/plan.md:36`
- 这不是措辞小问题，而是实现入口仍保留了一个已经被裁定排除的分支。只要这句还在，Phase 5 的 scoped review 就不能说“已裁定项完全 baked-in”。

## Scope Summary

- 本轮 scoped review 下，Phase 5 的 4 条 TODO 整体仍保持在 doc/protocol hardening 范围内，没有明显溢出到 Phase 6 / 7：`docs/tasks/phase5-doc-protocol-hardening/plan.md:63-102`
- `HARNESS_AUTO` 命名本身已收紧一致；我没有看到重新引入 `HARNESS_AUTO_MODE`、`AIONUI_AUTO` 等平行口径：`docs/tasks/phase5-doc-protocol-hardening/plan.md:63,171`
- `Verification`、`Risks`、`Rollback` 与这次窄范围总体一致，且 plan 本身当前能通过 lite artifact validator；本轮不能直接进入 IMPLEMENT 的原因，仅是上面的 baked-in 冲突还没清干净：`docs/tasks/phase5-doc-protocol-hardening/plan.md:117-166`

## Evidence / Commands

- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId phase5-doc-protocol-hardening -RepoRoot D:\data\claude-dev-harness`
- `Get-Content -LiteralPath docs/tasks/phase5-doc-protocol-hardening/plan.md -Raw -Encoding utf8`
- `Select-String -Path docs/tasks/phase5-doc-protocol-hardening/plan.md -Pattern 'HARNESS_AUTO|harness-lite\.notes\.md|auto-mode|受影响目录|已裁定项|TODO P5-T1|非目标|回滚|风险'`

## File Existence

This review file exists: `docs/tasks/phase5-doc-protocol-hardening/plan-review.md`

## Run 2

Verdict: `pass`

### Findings

no findings

### Closure Summary

- 上一轮唯一 finding 已闭合：`Clarification` 的 `受影响目录` 现在明确写成仅在 `agent-configs/workflows/harness-lite.yaml` 的 YAML 注释段追加 auto-mode 说明，并显式声明“不创建任何 sidecar 文档”：`docs/tasks/phase5-doc-protocol-hardening/plan.md:36`
- 已裁定项 2 与全文表述现在一致：auto-mode 说明只能放在 `agent-configs/workflows/harness-lite.yaml` 注释段，不再保留 `harness-lite.notes.md` 或其他 sidecar 备选分支：`docs/tasks/phase5-doc-protocol-hardening/plan.md:65,172`
- 我已实际重跑 validator：`scripts/validate-lite-artifacts.ps1 -TaskId phase5-doc-protocol-hardening -RepoRoot D:\data\claude-dev-harness`，结果为 `STATUS: PASS`
