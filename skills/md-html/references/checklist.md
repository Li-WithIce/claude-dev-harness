# Markdown / HTML Checklist

此清单用于交付前自检，不是新的 validator gate。命中问题时，优先修 source / template / style，再重新生成 artifact。

## 模式选择

### Markdown-only

- 短文或纯内容编辑优先使用 Markdown-only。
- `spec.md` / `plan.md` 未超过 160 行且少于 8 个 `##` 二级标题时，除非用户明确要求 HTML，默认不生成阅读版。
- Markdown 层次已经清晰时，不为形式感额外生成 HTML。

### Paired reading HTML

- `spec.md` / `plan.md` 超过 160 行，或含 8 个及以上 `##` 二级标题。
- 用户需要人工审阅/决策，且 Markdown 查看层次不够清晰。
- HTML 阅读版使用固定模板或稳定生成规则，建议路径为同目录 `plan.review.html` / `spec.review.html`，单一审阅文件也可用 `review.html`。
- HTML 阅读版只增强阅读，不替代 `spec.md` / `plan.md`；内容改动仍回到 Markdown 后重新生成。

### Local HTML enhancement

- 仅用于局部卡片、对比区、流程区、信息网格。
- 只输出可直接渲染的裸 HTML 片段，不输出完整 HTML 页面。
- 不把 HTML 放进代码块。
- 禁止 `script`、`iframe`、外部 JS；样式克制、紧凑、清晰。
- 不影响内容正确性；不适合时回到 Markdown-only。

## P0 Gate

以下任一项失败时不要交付，先修正或回到 ask / PLAN：

- source of truth 不明确。
- 同一轮自由编辑 Markdown 与 HTML，且没有同步回 source / template。
- Markdown -> HTML 产物无法从 source 与模板/样式重复生成。
- HTML / URL -> Markdown 导入遗漏核心内容，且未记录缺口。
- 输出路径会覆盖未声明文件。
- paired reading HTML 被当成 `spec.md` / `plan.md` 的替代真相源。
- Local HTML enhancement 使用 `script`、`iframe`、外部 JS、完整页面外壳，或被放进代码块。

## P1 Gate

以下任一项失败时应修复；无法修复时必须在回报或 TEST 风险中点名：

- 结构层级、链接、图片、表格或代码块转换后明显损坏。
- HTML 语义贫弱，影响可访问性、预览或维护。
- Markdown 难以人工审阅，例如超长单行、无意义嵌套或布局噪音过重。
- HTML 作为交付物但没有预览或视觉抽查证据。
- 生成步骤不可复现，下一位接手者无法重建 artifact。

## 结构

- Markdown 标题层级连续，只有一个明确主标题或按项目约定处理。
- 列表、表格、引用、代码块、脚注和链接没有因为转换丢失层级。
- HTML 有完整文档骨架或嵌入目标要求的片段边界。
- Local HTML enhancement 只有局部片段边界，不含完整页面骨架。
- 生成输出路径与任务声明一致，没有覆盖未声明文件。

## 语义

- Markdown 保留内容语义，而不是用 HTML 布局结构伪装正文。
- HTML -> Markdown 导入时记录不可还原项：动态脚本、交互状态、CSS 布局、内联样式、iframe、表单行为。
- 图片保留可读 alt 文本或标注缺失原因。
- 代码块语言、链接目标和表格表头经过抽查。

## 可读性

- Markdown 可由人类直接审阅，不依赖 HTML 才能理解内容。
- 长段落、嵌套列表和宽表格没有变成难以维护的单行文本。
- HTML 预览中的正文、标题、表格和代码块在目标视口下可读。
- paired reading HTML 的目录、标题、分区和表格可读性优于原 Markdown 长文。
- 生成报告说明了 source path、artifact path 和检查方式。

## 视觉

- HTML 是 generated display artifact，用于预览、视觉检查、发布和交付。
- 视觉调整落在模板、CSS、主题变量或生成规则中，而不是只手改 HTML 正文。
- paired reading HTML 使用固定模板，目标是更清晰，不重新设计 UI。
- Local HTML enhancement 只做局部、克制、紧凑的可读性增强。
- 交付前至少检查一个桌面视口；有移动交付要求时补移动视口。
- 不承诺 HTML -> Markdown 像素级还原；视觉差异只作为导入记录或模板改进输入。

## 可维护性

- Markdown 是 canonical source / source of truth，并能重新生成 HTML（包含 paired reading HTML）。
- 同一轮没有自由编辑 Markdown 与 HTML 两个源；若发生例外，已说明原因并同步回 source 或模板。
- 生成命令、工具版本或手工步骤足够让下一位接手者复现。
- 未引入任务未声明的 runtime 依赖、网络依赖或 package manager 依赖。
