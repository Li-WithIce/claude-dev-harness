# Markdown / HTML Pipeline Options

本页记录可选工具链思路，参考 `huashu-md-html` 的 source/artifact 分层：Markdown 管内容和结构，HTML 管展示和发布。仓库不因此新增 runtime 依赖；只有目标环境已具备工具或任务显式允许安装时才使用。

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

## 双向协作边界

- 默认一轮只允许一个可编辑 source：Markdown。
- 改内容：编辑 Markdown。
- 改视觉：编辑模板、CSS、主题变量或生成规则。
- 改发布壳：编辑模板或构建配置。
- 临时 HTML hotfix：只在交付阻塞时使用，并立即把原因、差异和同步动作写入回报或任务记录。

## 验证建议

- 结构抽查：标题、列表、表格、代码块、链接、图片 alt。
- 语义抽查：HTML -> Markdown 后正文是否可读、是否遗漏关键段落。
- 视觉抽查：Markdown -> HTML 后桌面视口和必要移动视口。
- 可重复性：删除或忽略 generated HTML 后，使用记录命令重新生成。
- 漂移检查：确认内容变更不只存在于 HTML artifact。
