---
name: md-html
description: Use when a task involves Markdown/HTML conversion, HTML reports, web page artifacts, publishing previews, or extracting reviewable Markdown from URL/HTML input.
---

# Markdown / HTML Artifact Publisher

本 skill 负责 Markdown 与 HTML 的互转边界。它不新增 workflow stage，也不引入 runtime 依赖；具体转换工具由任务按本地环境选择。

## 触发条件

- 用户要求 Markdown -> HTML、HTML -> Markdown、网页 artifact、HTML report、静态页面交付或发布预览。
- 用户给出 URL / HTML 文件，希望提取为可编辑、可审阅、可归档的 Markdown。
- `spec.md` / `plan.md` 超过 160 行或含 8 个及以上二级标题，且用户需要人工审阅/决策、Markdown 层次不够清晰时，默认生成同目录 HTML 阅读版。
- workflow 任务的 `artifacts:`、`Verification` 或交付要求中出现 `.md` / `.html` 双产物关系。
- 需要区分内容编辑、视觉样式调整和 generated display artifact 归属。

## Source / Artifact 边界

- Markdown 是人类和 AI 共同编辑的 canonical source / source of truth。
- HTML 是 generated display artifact，用于预览、视觉检查、发布和交付；长 `spec.md` / `plan.md` 的 paired reading HTML 应主动重组结构，不只是 Markdown 渲染。
- HTML -> Markdown 是导入、审阅、归档路径，不承诺像素级还原。
- Markdown -> HTML 是发布、预览路径，应可重复生成。
- 默认不允许同一轮同时自由编辑 Markdown 和 HTML，避免双源漂移；改内容走 Markdown，改视觉走模板、样式规则或生成管线后再生成 HTML。
- `spec.md` / `plan.md` 的 HTML 阅读版是派生产物，不替代 Markdown；内容变更仍改 `spec.md` / `plan.md` 后重新生成。

## 三种模式

### Markdown-only

适用：短文、纯内容编辑、结构已经清晰的 `spec.md` / `plan.md`、或不需要浏览器阅读版的任务。

- 只维护 Markdown。
- 不生成 HTML 页面。
- 可以用普通 Markdown 表格、列表、标题和引用表达结构。

### Paired reading HTML

适用：长 `spec.md` / `plan.md` 需要人工审阅、决策或跨角色复核，且 Markdown 查看层次不够清晰。

- 触发阈值：`spec.md` / `plan.md` 超过 160 行，或含 8 个及以上 `##` 二级标题。
- 默认输出同目录固定模板阅读版：`plan.review.html` / `spec.review.html`；若任务目录只有一个待审阅 Markdown，也可用 `review.html`。
- HTML 做结构化审阅增强：summary、decision、risk、checkpoint、流程/架构、对比矩阵、信息卡片、折叠源章节等 visual blocks；不只是 Markdown 转 HTML。
- 仓库内固定生成器是 `scripts/render-review-html.ps1`；它输出 source-of-truth banner、TOC、summary/decision/risk/checkpoint 区、流程/架构重组、局部 visual blocks、折叠源章节、表格滚动容器和代码块样式。
- 默认产物是自包含 HTML fragment + inline CSS；不得包含 `script`、`iframe`、外部 JS、`doctype`、`html`、`head`、`body` 外壳。
- HTML 阅读版是 generated artifact；不得成为内容真相源。

### Local HTML enhancement

适用：Markdown 内局部片段用纯 Markdown 可读性不足，但无需完整 HTML 页面。

- 只允许局部裸 HTML：卡片、对比区、流程区、信息网格。
- 不输出完整 HTML 页面，不写 `html` / `head` / `body` 外壳。
- 不把 HTML 放进代码块；它必须是可直接渲染的局部片段。
- 禁止 `script`、`iframe`、外部 JS；样式必须克制、紧凑、清晰。
- 不影响内容正确性；核心内容仍应能从 Markdown 上下文理解。

## 输入契约

- source Markdown：仓库内 `.md` 文件，或任务明确给定的 Markdown 内容。
- source HTML：仓库内 `.html` 文件、URL 抓取结果或用户提供的 HTML 片段。
- template/style：可选的 HTML 模板、CSS、主题变量或发布配置。
- output path：目标 `.md` / `.html` 路径必须明确；workflow 模式下写入 `docs/tasks/{task_id}/` 或任务声明的 artifact 路径。
- fidelity expectation：说明目标是语义保真、结构保真、视觉预览还是发布交付；不要默认承诺像素级还原。

## 输出契约

- Markdown 输出必须优先保留标题层级、段落、列表、表格、链接、图片替代文本和代码块语义。
- HTML 输出必须可从 Markdown 与模板/样式规则重复生成；不要把手工内容改动只留在 HTML。
- 长 `spec.md` / `plan.md` 的 paired reading HTML 必须使用固定模板或稳定生成规则，优先清晰阅读，不重新设计页面。
- 同一任务目录同时存在 `spec.md` 和 `plan.md` 时，不使用 `review.html`，必须输出 `spec.review.html` 或 `plan.review.html` 以避免覆盖和语义歧义。
- 完整 HTML 页面只有用户明确要求时才生成；paired reading HTML 默认使用自包含 HTML fragment + inline CSS，局部增强不得升级成完整页面。
- Local HTML enhancement 输出必须是局部片段，不得生成完整页面或把 HTML 包在 fenced code block 中。
- 视觉调整应落在模板、CSS 或生成规则中，并重新生成 HTML。
- 导入得到的 Markdown 应标注来源和不可还原项，例如脚本交互、布局细节、内联样式或动态内容。
- 交付报告应写明 source path、artifact path、生成命令或手工步骤、检查结果和残留差异。

## quick / workflow / ask 行为

- `quick`：单文件、小范围、边界明确时直接转换或修正，并报告 source、artifact、命令和检查结果；不创建任务目录。若短文足够清晰，使用 Markdown-only。
- `workflow`：涉及多文件/高风险改造、发布交付、模板规则、视觉验收，或用户明确要求 durable/staged/canonical review/test artifact/evidence 时，进入 `entry-router -> orchestrator`；单页 URL 导入或普通 review/test 结果本身不升级。PLAN 应声明 canonical Markdown、generated HTML、模板/样式路径和验证命令。
- `workflow` 中的长 `spec.md` / `plan.md` 若命中阈值且需要人工审阅/决策，默认声明 paired reading HTML artifact。
- `ask`：缺少源文件、目标方向、输出路径、保真要求或无法判断是否需要 HTML 阅读版时，停留在 iterative blocking clarification gate；默认一次只问一个最高价值问题，例如“本轮以 Markdown 还是 HTML 作为 source of truth？”，确认后再重新判断 quick/workflow。

## AI 与人类协作边界

- 人类和 AI 共同编辑 Markdown；它承载内容、结构、审阅意见和长期维护。
- AI 可以生成 HTML、检查视觉结果、提出模板/CSS 修改，并把需要持久化的内容改动回写到 Markdown。
- 人类可以直接检查 HTML 预览，但反馈若涉及内容，应转成 Markdown 修改；若涉及视觉，应转成模板/样式规则修改。
- 对最需要人工介入的 `spec.md` / `plan.md`，AI 应在长文命中阈值时主动提供 paired reading HTML，帮助人类更快审阅结构和决策点。
- 如必须临时修 HTML，必须在同一回合说明原因、同步回 Markdown 或模板/样式，并记录防漂移检查。

## 工作流程

1. 判定方向：Markdown -> HTML、HTML/URL -> Markdown，或双向审阅。
2. 选择模式：Markdown-only、Paired reading HTML 或 Local HTML enhancement。
3. 明确 source of truth：默认 Markdown；若已有 HTML 只是导入源，导入后 Markdown 接管。
4. 选择或声明生成管线：参考 [references/pipeline.md](references/pipeline.md)，不要默认安装依赖。
5. 执行转换或编辑：内容改 Markdown；视觉改模板/CSS/规则；生成 HTML artifact 或局部 HTML 片段。
6. 自检：按 [references/checklist.md](references/checklist.md) 覆盖结构、语义、可读性、视觉、可维护性和 gate。
7. 回报：列出 source、artifact、命令/工具、不可还原差异和后续风险。

## References

- Checklist: [references/checklist.md](references/checklist.md)
- Pipeline options: [references/pipeline.md](references/pipeline.md)
