# Markdown / HTML Checklist

此清单用于交付前自检，不是新的 validator gate。命中问题时，优先修 source / template / style，再重新生成 artifact。

## P0 Gate

以下任一项失败时不要交付，先修正或回到 ask / PLAN：

- source of truth 不明确。
- 同一轮自由编辑 Markdown 与 HTML，且没有同步回 source / template。
- Markdown -> HTML 产物无法从 source 与模板/样式重复生成。
- HTML / URL -> Markdown 导入遗漏核心内容，且未记录缺口。
- 输出路径会覆盖未声明文件。

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
- 生成报告说明了 source path、artifact path 和检查方式。

## 视觉

- HTML 是 generated display artifact，用于预览、视觉检查、发布和交付。
- 视觉调整落在模板、CSS、主题变量或生成规则中，而不是只手改 HTML 正文。
- 交付前至少检查一个桌面视口；有移动交付要求时补移动视口。
- 不承诺 HTML -> Markdown 像素级还原；视觉差异只作为导入记录或模板改进输入。

## 可维护性

- Markdown 是 canonical source / source of truth，并能重新生成 HTML。
- 同一轮没有自由编辑 Markdown 与 HTML 两个源；若发生例外，已说明原因并同步回 source 或模板。
- 生成命令、工具版本或手工步骤足够让下一位接手者复现。
- 未引入任务未声明的 runtime 依赖、网络依赖或 package manager 依赖。

## P0 Gate

- Markdown 是 canonical source / source of truth。
- HTML 只是 generated display artifact。
- 同一轮没有自由编辑 Markdown 和 HTML 两份 source。
- 内容改动已落在 Markdown；视觉改动已落在模板、CSS、主题变量或生成规则。

## P1 Gate

- `source_of_truth`: Markdown。
- `artifact`: HTML 仅为 generated display artifact。
- `direction`: 标清 Markdown -> HTML 或 HTML/URL -> Markdown。
- `repeatability`: Markdown -> HTML 可重复生成。
- `drift`: 没有双源漂移；内容改动不只存在于 HTML。
- `verification`: 已执行或说明未执行的预览、结构或语义检查。
