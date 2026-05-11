---
task_id: 06349522
task: 复审并提交结构增强 review HTML renderer
owner: html-renderer-reviewer
updated: 2026-05-11
status: review-complete
---

# Structured Review HTML Renderer Review

## Summary

复审 `scripts/render-review-html.ps1` 与 md-html 文档、core 验证入口和回归脚本后，结论为可以提交。

## Review Fixes

- 修正 `tests/verify-render-review-html.ps1` 的旧断言，使其锁定当前 renderer 的 fragment 输出、`review-toc`、`raw-*` 稳定锚点、visual block 和无完整页面外壳合同。
- 修正 README 中 `verify-*.ps1` 数量为 26，因为本轮 core 纳入了两个 renderer 回归脚本。
- 修正 `tests/verify-lite-footprint.ps1` 中过时的 “paired reading HTML 可触发完整页面” 锁点，改为锁定默认 fragment + inline CSS 口径。

## Verification

- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-render-review-html.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-md-html-review-renderer.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-lite-footprint.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\run-validation.ps1 -Suite core`
- PASS: `git diff --check`

## Conclusion

生成器、文档合同、footprint 锁点和 core suite 已对齐。复审未保留阻塞问题。
