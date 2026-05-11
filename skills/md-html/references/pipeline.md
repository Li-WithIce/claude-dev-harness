# Markdown / HTML Pipeline Options

本页记录可选工具链思路，参考 `huashu-md-html` 的 source/artifact 分层：Markdown 管内容和结构，HTML 管展示和发布。仓库不因此新增 runtime 依赖；只有目标环境已具备工具或任务显式允许安装时才使用。

## 模式矩阵

| 模式 | 适用场景 | 输出 |
|---|---|---|
| Markdown-only | 短文、纯内容编辑、结构清晰的 `spec.md` / `plan.md` | 只保留 Markdown |
| Paired reading HTML | 超过 160 行或 8 个二级标题的长 `spec.md` / `plan.md`，且需要人工审阅/决策 | 同目录 `plan.review.html` / `spec.review.html` 或 `review.html` |
| Local HTML enhancement | 局部卡片、对比区、流程区、信息网格需要更清晰呈现 | Markdown 内可直接渲染的裸 HTML 片段 |

## Paired reading HTML

适用：长 `spec.md` / `plan.md` 的固定模板阅读版。

要求：

- Markdown 是唯一内容 source；HTML 阅读版是派生产物。
- 触发阈值固定为超过 160 行或 8 个及以上 `##` 二级标题，并且用户需要审阅/决策、Markdown 层次不够清晰。
- 使用固定模板或稳定生成规则：source banner、TOC、summary、decision、risk、checkpoint、流程/架构、对比矩阵、信息卡片、折叠源章节、表格样式、代码块样式。
- 当前仓库固定生成器：`scripts/render-review-html.ps1`。默认 `spec.md -> spec.review.html`、`plan.md -> plan.review.html`；同目录同时存在 `spec.md` 和 `plan.md` 时拒绝 `review.html`。
- 默认不做完整网站设计，不加入品牌化视觉；目标是把长文重组为审阅视图，而不是普通 Markdown 渲染。
- 默认输出自包含 HTML fragment + inline CSS；不得包含 `script`、`iframe`、外部 JS、`doctype`、`html`、`head`、`body` 外壳。
- 内容变更必须改 `spec.md` / `plan.md` 后重新生成 HTML。

可选工具：

- `scripts/render-review-html.ps1 -SourcePath <spec-or-plan.md> -OutputPath <review.html> -Force`：仓库默认 paired reading HTML 路径，输出结构重组后的 fragment。
- `pandoc --standalone --toc --template <template>`：仅适合用户明确要求完整 HTML 页面时使用。
- 编辑器导出 / preview save：适合 quick，但需记录实际操作。
- 简单本地脚本：适合仓库自带模板；本仓库优先使用 `pwsh -File .\scripts\render-review-html.ps1 -SourcePath <spec-or-plan.md>`，脚本只读取 Markdown 并输出 HTML artifact。

## Markdown -> HTML

适用：发布、预览、视觉检查、交付 HTML report。

常见路径：

- `pandoc`: 适合 Markdown 到完整 HTML、模板、目录、metadata、PDF 前置链路。
- 静态站点生成器：适合多页面、主题化、导航和发布站点；必须把配置和模板纳入 artifact 声明。
- 自定义模板脚本：适合单页报告；脚本应从 Markdown 读入并稳定输出 HTML。
- 编辑器 / IDE preview：适合 quick 预览，但若作为交付证据，需要记录实际导出方式。

要求：

- Markdown 是 source of truth。
- 模板、CSS、主题变量和生成参数是视觉 source。
- HTML 可以删除后从 Markdown 与模板/样式重新生成。
- 内容修正必须回写 Markdown，再重新生成 HTML。

## HTML / URL -> Markdown

适用：导入、审阅、归档、把网页内容变成可维护 source。

常见路径：

- `markitdown`: 适合把多种文档或 HTML 输入转为 Markdown 草稿。
- `html-to-markdown`: 适合结构较清晰的 HTML 片段转换。
- `trafilatura`: 适合 URL / 网页正文抽取，偏内容归档而非页面还原。
- `pandoc`: 适合 HTML 到 Markdown 的通用转换和格式规范化。
- 浏览器复制 / 阅读模式：适合 quick 导入；必须人工检查标题、链接、图片和表格。

要求：

- HTML 是导入源，不自动成为长期 source of truth。
- 导入后的 Markdown 接管内容维护。
- 不承诺像素级还原，不承诺保留脚本交互或 CSS 布局。
- 导入报告应记录来源 URL / 文件、工具、时间、已知丢失项和人工抽查结果。

## Local HTML enhancement

适用：Markdown 局部表达不够清晰，但不需要完整 HTML 页面。

允许：

- 局部卡片。
- 对比区。
- 流程区。
- 信息网格。

禁止：

- 完整 HTML 页面；Local HTML enhancement 模式不输出 `html` / `head` / `body` 外壳。
- fenced code block 包住 HTML。
- `script`、`iframe`、外部 JS。
- 依赖外部 CSS/JS 才能理解内容。
- 大面积替代 Markdown 正文。

建议：

- 使用少量 inline style 或简单语义标签。
- 控制片段长度，保持可审阅。
- 核心事实仍写在可读文本中，避免只靠视觉位置表达。

## 双向协作边界

- 默认一轮只允许一个可编辑 source：Markdown。
- 改内容：编辑 Markdown。
- 改视觉：编辑模板、CSS、主题变量或生成规则。
- 改发布壳：编辑模板或构建配置。
- 改长文阅读体验：改 fixed reading template，再从 `spec.md` / `plan.md` 重新生成 HTML。
- 临时 HTML hotfix：只在交付阻塞时使用，并立即把原因、差异和同步动作写入回报或任务记录。

## 验证建议

- 结构抽查：标题、列表、表格、代码块、链接、图片 alt。
- 语义抽查：HTML -> Markdown 后正文是否可读、是否遗漏关键段落。
- 视觉抽查：Markdown -> HTML 后桌面视口和必要移动视口。
- 可重复性：删除或忽略 generated HTML 后，使用记录命令重新生成。
- 长文阅读版抽查：`spec.md` / `plan.md` 的 summary、决策、风险、checkpoint、流程/架构、对比矩阵和折叠源章节在 HTML 中更清晰。
- 结构合同抽查：source banner、TOC、visual block 标记、H2/H3 锚点、表格滚动容器、代码块语言、无 `script` / `iframe` / 外部 JS / `doctype` / `html` / `head` / `body`。
- 局部增强抽查：没有完整页面外壳、代码块包裹、`script`、`iframe` 或外部 JS。
- 漂移检查：确认内容变更不只存在于 HTML artifact。
