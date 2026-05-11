---
task_id: b5a13c02
task: 审计 spec 到 review.html 的结构增强不足
owner: html-visual-auditor
updated: 2026-05-11
status: audit-complete
---

# Spec to Review HTML Structural Audit

## Scope

只读审计当前仓库中 `spec.md` / `plan.md` 到 `review.html` / `spec.review.html` / `plan.review.html` 的 paired reading HTML 约定，重点看结构增强是否已经有可执行、可复现、可测试的实现。

## Findings

### F1 - 只有策略文案，没有可执行生成链路

- `skills/md-html/SKILL.md` 规定长 `spec.md` / `plan.md` 默认输出同目录固定模板阅读版，并要求目录、段落宽度、标题层级、轻量分区和表格可读性增强。
- `skills/md-html/references/pipeline.md` 只列出 `pandoc`、编辑器导出、简单本地脚本等可选路径，没有提供仓库内固定模板或脚本。
- 仓库搜索未发现任何 `.html`、`.css`、review template 或 `spec.md -> review.html` 生成脚本。
- 影响：下一位 agent 只能按自由发挥生成 HTML，无法保证“固定模板”“稳定生成规则”或可重复性。

### F2 - “结构增强”验收标准不够具体

- 当前 checklist 只要求 paired reading HTML 的目录、标题、分区和表格可读性优于原 Markdown 长文。
- 没有定义最低结构合同，例如必须生成 TOC、锚点、H2 分区块、宽表容器、代码块语言保留、任务决策/风险区块突出、source/artifact banner 等。
- 影响：即使生成了普通 Markdown preview，也可能被误判为合格的 `review.html`，但它不一定解决人工审阅的层级和决策点扫描问题。

### F3 - 回归测试只锁文案，不锁产物行为

- `tests/verify-lite-footprint.ps1` 只断言 README、entry-router、md-html skill、pipeline、checklist 中存在关键字符串。
- 没有 fixture 覆盖一个长 `spec.md` 输入，也没有断言生成的 HTML 含 TOC、稳定锚点、表格可读性包装、source-of-truth 提示或无外部 JS。
- 影响：后续修改可能保留文案但继续没有实际结构增强，当前测试无法发现。

### F4 - 输出路径规则存在轻微歧义

- 文档同时允许 `spec.review.html` / `plan.review.html`，以及“单一审阅文件可用 `review.html`”。
- 没有说明当同一任务目录同时存在 `spec.md` 和 `plan.md` 时，`review.html` 是否禁用、如何避免覆盖、是否需要在 PLAN artifacts 中显式声明。
- 影响：多人协作时可能产生覆盖或双源漂移，尤其是 spec 与 plan 都需要审阅版时。

## Evidence

- `skills/md-html/SKILL.md:37-44`：声明 Paired reading HTML 模式与增强目标。
- `skills/md-html/SKILL.md:64-73`：声明输出必须可重复生成、视觉改模板/样式。
- `skills/md-html/references/pipeline.md:13-30`：只列可选工具，没有仓库内固定实现。
- `skills/md-html/references/checklist.md:65-71`：可读性 gate 没有结构合同细节。
- `tests/verify-lite-footprint.ps1:523-583`：只做字符串锁点。
- `rg --files -g "*.html"`：无仓库内 HTML fixture / artifact。
- `rg --files -g "*template*" -g "*.css" -g "*.html" -g "*.ps1" | rg "review|html|md-html|markdown"`：无 review HTML 模板或生成器。

## Recommended Minimal Fix

1. 增加一个仓库内稳定生成器，例如 `scripts/render-review-html.ps1`，只读 Markdown 并输出 paired reading HTML。
2. 增加固定模板/内联 CSS 规则，最低结构合同包括：
   - source-of-truth banner，标明 HTML 是 generated artifact。
   - TOC，基于 H2/H3 生成稳定锚点。
   - 主体最大宽度、H2 分区、表格横向滚动容器、代码块样式。
   - 禁止外部 JS、`script`、`iframe`。
3. 增加 fixture：`tests/fixtures/md-html/long-spec.md`。
4. 增加专门验证：检查生成 HTML 包含 TOC、锚点、source banner、table wrapper、code block、无外部 JS，并验证同一输入重复生成一致。
5. 收紧路径规则：同目录只有一个 `spec.md` 或 `plan.md` 时才允许 `review.html`；两者同时存在时必须使用 `spec.review.html` / `plan.review.html`。

## Conclusion

当前 md-html 收口完成的是“边界与策略”，不是可执行的 `spec.md -> review.html` 结构增强能力。若 Leader 需要真正解决该不足，建议开一个窄实现任务补生成器、模板 fixture 和行为级测试。
