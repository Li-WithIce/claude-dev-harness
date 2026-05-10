---
name: md-html
description: Use when a task involves Markdown/HTML conversion, HTML reports, web page artifacts, publishing previews, or extracting reviewable Markdown from URL/HTML input.
---

# Markdown / HTML Artifact Publisher

本 skill 负责 Markdown 与 HTML 的互转边界。它不新增 workflow stage，也不引入 runtime 依赖；具体转换工具由任务按本地环境选择。

## 触发条件

- 用户要求 Markdown -> HTML、HTML -> Markdown、网页 artifact、HTML report、静态页面交付或发布预览。
- 用户给出 URL / HTML 文件，希望提取为可编辑、可审阅、可归档的 Markdown。
- workflow 任务的 `artifacts:`、`Verification` 或交付要求中出现 `.md` / `.html` 双产物关系。
- 需要区分内容编辑、视觉样式调整和 generated display artifact 归属。

## Source / Artifact 边界

- Markdown 是人类和 AI 共同编辑的 canonical source / source of truth。
- HTML 是 generated display artifact，用于预览、视觉检查、发布和交付。
- HTML -> Markdown 是导入、审阅、归档路径，不承诺像素级还原。
- Markdown -> HTML 是发布、预览路径，应可重复生成。
- 默认不允许同一轮同时自由编辑 Markdown 和 HTML，避免双源漂移；改内容走 Markdown，改视觉走模板、样式规则或生成管线后再生成 HTML。

## 输入契约

- source Markdown：仓库内 `.md` 文件，或任务明确给定的 Markdown 内容。
- source HTML：仓库内 `.html` 文件、URL 抓取结果或用户提供的 HTML 片段。
- template/style：可选的 HTML 模板、CSS、主题变量或发布配置。
- output path：目标 `.md` / `.html` 路径必须明确；workflow 模式下写入 `docs/tasks/<task-id>/` 或任务声明的 artifact 路径。
- fidelity expectation：说明目标是语义保真、结构保真、视觉预览还是发布交付；不要默认承诺像素级还原。

## 输出契约

- Markdown 输出必须优先保留标题层级、段落、列表、表格、链接、图片替代文本和代码块语义。
- HTML 输出必须可从 Markdown 与模板/样式规则重复生成；不要把手工内容改动只留在 HTML。
- 视觉调整应落在模板、CSS 或生成规则中，并重新生成 HTML。
- 导入得到的 Markdown 应标注来源和不可还原项，例如脚本交互、布局细节、内联样式或动态内容。
- 交付报告应写明 source path、artifact path、生成命令或手工步骤、检查结果和残留差异。

## quick / workflow / ask 行为

- `quick`：单文件、小范围、边界明确时直接转换或修正，并报告 source、artifact、命令和检查结果；不创建任务目录。
- `workflow`：涉及多文件、发布交付、模板规则、视觉验收、URL 导入或需要 review/test 证据时，进入 `entry-router -> orchestrator`；PLAN 应声明 canonical Markdown、generated HTML、模板/样式路径和验证命令。
- `ask`：缺少源文件、目标方向、输出路径或保真要求时，只问一个最小澄清问题，例如“本轮以 Markdown 还是 HTML 作为 source of truth？”

## AI 与人类协作边界

- 人类和 AI 共同编辑 Markdown；它承载内容、结构、审阅意见和长期维护。
- AI 可以生成 HTML、检查视觉结果、提出模板/CSS 修改，并把需要持久化的内容改动回写到 Markdown。
- 人类可以直接检查 HTML 预览，但反馈若涉及内容，应转成 Markdown 修改；若涉及视觉，应转成模板/样式规则修改。
- 如必须临时修 HTML，必须在同一回合说明原因、同步回 Markdown 或模板/样式，并记录防漂移检查。

## 工作流程

1. 判定方向：Markdown -> HTML、HTML/URL -> Markdown，或双向审阅。
2. 明确 source of truth：默认 Markdown；若已有 HTML 只是导入源，导入后 Markdown 接管。
3. 选择或声明生成管线：参考 [references/pipeline.md](references/pipeline.md)，不要默认安装依赖。
4. 执行转换或编辑：内容改 Markdown；视觉改模板/CSS/规则；生成 HTML artifact。
5. 自检：按 [references/checklist.md](references/checklist.md) 覆盖结构、语义、可读性、视觉、可维护性和 gate。
6. 回报：列出 source、artifact、命令/工具、不可还原差异和后续风险。

## References

- Checklist: [references/checklist.md](references/checklist.md)
- Pipeline options: [references/pipeline.md](references/pipeline.md)
