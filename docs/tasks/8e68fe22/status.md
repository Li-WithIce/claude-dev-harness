---
task_id: 8e68fe22
task: refine md-html spec/plan reading strategy
owner: design-verifier
updated: 2026-05-10
status: finalized
base_commit: 71c4668e018b0e6bddb7f0060b7b0cb792bf08ca
---

# md-html Spec / Plan Reading Strategy

## Goal

增强 `md-html` 的人工审阅策略：当 `spec.md` / `plan.md` 变长且 Markdown 层次不够清晰时，默认建议生成同目录 HTML 阅读版；同时允许受限的局部 HTML 视觉增强。

## Implemented

- `skills/md-html/SKILL.md`
  - 增加三种模式：Markdown-only、Paired reading HTML、Local HTML enhancement。
  - 明确长 `spec.md` / `plan.md` 触发阈值：超过 160 行，或含 8 个及以上 `##` 二级标题，并且需要人工审阅/决策、Markdown 层次不够清晰。
  - 明确 paired reading HTML 是派生产物，不替代 `spec.md` / `plan.md`；内容变更仍改 Markdown 后重新生成。
  - 限制 Local HTML enhancement 只用于局部卡片、对比区、流程区、信息网格；不输出完整页面、不放代码块、禁止 `script` / `iframe` / 外部 JS。
- `skills/md-html/references/checklist.md`
  - 增加模式选择检查和 P0 gate，覆盖长文阅读版派生边界与局部增强禁用项。
- `skills/md-html/references/pipeline.md`
  - 增加模式矩阵、paired reading HTML 固定模板思路和局部 HTML 增强限制。
  - 保持不引入 runtime 依赖，只列可选工具链。
- `README.md`
  - 增加长 `spec.md` / `plan.md` paired reading HTML 触发说明、固定模板和局部 HTML 视觉增强边界。
- `skills/entry-router/SKILL.md`
  - 增加长 `spec.md` / `plan.md` 审阅策略和局部 HTML 视觉增强限制。
- `skills/orchestrator/SKILL.md`
  - 增加长 `spec.md` / `plan.md` 可额外声明 paired reading HTML 的懒加载说明，不新增 stage。
- `skills/orchestrator/references/runbook.md`
  - 增加 lazy loading 下的长文 paired reading HTML 建议。
- `skills/orchestrator/references/lite-writing-guide.md`
  - 增加 PLAN artifacts 写作边界：长 `spec.md` / `plan.md` 可列同目录 paired reading HTML；固定模板和派生产物边界保持 Markdown truth source。
- `tests/verify-lite-footprint.ps1`
  - 锁定长 `spec.md` / `plan.md` trigger、paired reading HTML、fixed template、derived artifact 和 Local HTML enhancement restrictions。

## Finalizer Review

- 复审时补齐 `README.md` 的完整 HTML 页面例外：用户明确要求或 paired reading HTML 触发时才生成完整 HTML 页面。
- 复审时收窄 `skills/md-html/references/checklist.md` 的可维护性表述，避免把所有 HTML artifact 都写成只有 paired reading HTML。
- `tests/verify-lite-footprint.ps1` 增加 README 例外文案锁点。

## Boundaries

- 未触碰 `%USERPROFILE%\.codex\config.toml`。
- 未改业务仓。
- 未引入 runtime 依赖。
- 未修改 install/profile/AionUI contract 脚本或配置。
- 由 `1043b17e` finalizer 复审并提交。

## Verification

- PASS: `git diff --check`
- PASS: `git diff --cached --check`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-footprint.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-install-isolation.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-descriptor.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-skill-manifest.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-aionui-skill-contract.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-tool-profile.ps1`
