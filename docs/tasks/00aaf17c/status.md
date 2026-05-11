---
task_id: 00aaf17c
task: 接手实现结构增强 review HTML 渲染器
owner: html-renderer-builder
updated: 2026-05-11
status: implementation-complete
---

# Structured Review HTML Renderer

## Summary

已实现仓库内固定 paired reading HTML 生成器 `scripts/render-review-html.ps1`，用于从 `spec.md` / `plan.md` 生成可复现的阅读增强 HTML。

## Changed

- 新增 `scripts/render-review-html.ps1`：
  - 默认 `spec.md -> spec.review.html`、`plan.md -> plan.review.html`，其他 Markdown 默认 `review.html`。
  - 当同目录同时存在 `spec.md` 和 `plan.md` 时拒绝输出 `review.html`，避免覆盖和语义歧义。
  - 输出完整 HTML 页面，包含 source-of-truth banner、TOC、稳定 H2/H3 锚点、H2 分区、表格横向滚动容器、代码块语言 class、无外部 JS。
- 新增 fixture `tests/fixtures/md-html/long-spec.md`。
- 新增行为回归 `tests/verify-render-review-html.ps1`，覆盖结构合同、禁止脚本/iframe、重复生成一致性和 `review.html` 冲突规则。
- 将 `verify-render-review-html.ps1` 纳入 `scripts/run-validation.ps1 -Suite core`。
- 更新 `README.md`、`skills/md-html/SKILL.md`、`skills/md-html/references/checklist.md`、`skills/md-html/references/pipeline.md` 和 footprint 锁点，记录固定生成器和最低结构合同。

## Verification

- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-render-review-html.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-lite-footprint.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\run-validation.ps1 -Suite core`

## Notes

工作过程中发现未跟踪文件 `tests/verify-md-html-review-renderer.ps1` 并非本轮创建，且它调用的参数名与当前生成器契约不一致；本轮未修改或删除该并行遗留文件。
