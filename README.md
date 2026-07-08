# Dev Harness

Windows 优先的单仓库开发 harness。它把 `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST` 的可执行阶段、`DONE` frontmatter 终态、共享记忆 `.assistant/`、以及 `docs/tasks/{task_id}/` 产物统一到同一套协议里，当前仓库状态已经包含 Phase 1-7 与 shared-memory v2 的主线能力。

## 这份 README 面向谁

- 使用者：把 harness 安装到你的工作区后，按这里的“日常使用”与“阶段推进”工作。
- 维护者：在本仓库里修改脚本、skills、模板与测试，并用这里的校验命令确认行为没有回退。

## 快速开始

### 安装到目标工作区

```powershell
# 快捷入口
pwsh -File .\harness.ps1 -WorkspaceRoot D:\my-project

# 直接安装
pwsh -File .\install.ps1 -WorkspaceRoot D:\my-project -RepoRoot D:\data\dev-harness

# 显式安装完整 Obsidian/shared-memory vault
pwsh -File .\install.ps1 -WorkspaceRoot D:\my-project -RepoRoot D:\data\dev-harness -VaultProfile full
```

默认安装使用 `VaultProfile auto`：新项目安装 minimal vault；已有完整 `.assistant` vault 的项目继续按 full/preserve 更新，不会自动瘦身或删除旧文件。`VaultProfile` 控制本次安装维护哪些文件，不负责清理已有 vault 内容；需要瘦身时先人工确认再删除旧 full 文件。安装完成后，目标工作区至少会得到：

- 工作区入口文档：`AGENTS.md`
- 工作区入口 shim：`.assistant/entry/AGENTS.md`
- 工作区脚本 shim：`.assistant/entry/advance-stage.ps1`、`.assistant/entry/validate-lite-artifacts.ps1`
- 最小运行时目录：`.assistant/运行时/tasks/`
- Claude Code hooks：`runtime-hooks/claude/*.js` 的安装副本

安装与更新路径只依赖 PowerShell 和 Git；Node.js 不是 harness 安装前置条件。`.js` hooks 只是被复制到目标位置，不要求安装脚本执行 `node` / `npm` / `npx`。

只有显式 `-VaultProfile full`，或 `auto` 检测到既有完整 vault 时，才安装/维护 `.assistant/.obsidian`、`.assistant/工作流`、`.assistant/模板`、`.assistant/配置`、`首页.md`、`MEMORY.md` 和默认运行时指针文件。

宿主侧当前真实行为是：

- repo `skills/` 会同步到 `%USERPROFILE%\.claude\skills`、`%USERPROFILE%\.codex\skills` 与 `%USERPROFILE%\.agents\skills`
- Claude / Codex 会写入各自的共享 `settings.local.json`；Codex 只写 Harness 托管的 `%USERPROFILE%\.codex\managed_config.toml`
- 用户私有的 `%USERPROFILE%\.codex\config.toml` 不由安装脚本或 workflow 创建、清理或改写

### 日常使用

安装后的用户视角，日常基本只有 4 件事：

1. 在目标工作区里直接发起开发任务，让入口文档先判定 `resume-current / switch-existing / new-task / inbox-first`；`new-task` 再轻量路由到 `quick / workflow / ask`。
2. `quick` 直接完成并报告验证；`ask` 是阻塞澄清路由，不写 `docs/tasks/{task_id}/`、不改代码；`workflow` 才进入 `entry-router -> orchestrator` 并写 `docs/tasks/{task_id}/`。
3. workflow 阶段完成后，用 `.assistant/entry/advance-stage.ps1` 推进到下一阶段。
4. 会话中断后，说“继续”/“恢复”/`resume`，优先读取已存在的 runtime 指针；full vault 项目可按 `.assistant/工作流/长会话恢复.md` 的顺序恢复。

各 route/stage 的工作纪律见 [`docs/工作流/stage-discipline-matrix.md`](docs/工作流/stage-discipline-matrix.md)。该矩阵只定义思考和审查视角，不新增 stage、frontmatter 字段、provider gate 或 validator hard gate；`quick` 仍是轻量 route，`ask` 仍是阻塞澄清 route，workflow 仍只认 `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST`。

### Optional Context Providers

Context providers 是可选辅助输入，不是 workflow 真相源。内置权威仍是 `docs/tasks/{task_id}/`、当前仓库文件和本地 `.assistant/`；CodeGraph、agentmemory、codedb-mcp 只能提供 advisory context provider 结果，且必须落回真实路径、命令、diff、review finding、Implementation Notes 或 test output。安装、更新和 validation 默认不会安装、注册或连接外部 provider；详细边界见 `docs/工作流/context-provider-boundary.md`，工具入口见 `docs/工具/context-providers.md`。

最常用命令：

```powershell
# Codex-only 默认路径：下一阶段已有 descriptor default_profile 时可省略 -Tool/-Profile
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id}

# 显式指定 profile，backend 从 profile.backend 解析
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -Profile harness-default-codex

# 显式指定 tool + profile + model
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -Tool codex -Profile harness-default-codex -Model gpt-5.5/xhigh

# 仍可显式切到其他合法 backend
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -Tool claudecode

# TEST -> DONE 可省略 -Tool
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id}

# 单独校验任务产物
pwsh -File .assistant\entry\validate-lite-artifacts.ps1 -TaskId {task_id}
```

## 真实任务流程

### 新任务入口模式路由

入口判定仍先保留四类结果：`resume-current`、`switch-existing`、`new-task`、`inbox-first`。只有判定为 `new-task` 后，才增加一层 `mode: quick | workflow | ask`。

- `quick`：quick only when all true：范围和验收清楚、风险低、能在当前对话内完成并验证、用户没有要求留痕 / review / test / 计划；默认不创建 `docs/tasks/{task_id}/`，不改共享指针。
- `workflow`：workflow when any of these is true：用户要求 workflow / 留痕 / review / test / 计划，或变更触碰入口协议、脚本、模板、validator、多文件 / 跨模块、高风险路径，或需要可审计决策 / 产物；进入 `entry-router -> orchestrator`。
- `ask`：Deep Clarification Mode / iterative blocking clarification gate：缺少答案导致无法判断 intent、scope、acceptance criteria、constraints、risk、affected area、output format 或 quick/workflow route choice 时使用；默认每轮只问一个最高价值问题，用户回答后重新判断。Remain in ask until all blocking uncertainties are resolved，只有足够理解后才转 `quick` 或 `workflow`。

显式覆盖词优先，但不能覆盖硬风险：用户说“直接改”“快修”时只有满足 `quick` 全部条件才偏 `quick`；用户说“走 workflow”“留痕”“review”“test”时直接偏 `workflow`。没有显式词时由入口 agent 按上面的 all/any 规则自主判断。

“需求澄清”“需求确认”“拷问需求”“拷问方案”“头脑风暴”“方案压力测试”“设计访谈”“边界确认”“验收标准确认”“非目标确认”，以及 `clarify`、`brainstorm`、`pressure test`、`challenge this plan`、`ask me questions` 等表达属于 Clarification 协议族；PLAN 的验收、非目标、影响面、回滚/兼容仍不确定，或实现路径仍不足以指导 IMPLEMENT 时也按该协议处理。它们不是新 stage：开发任务需要可审计决策或后续实现时，进入现有 `PLAN -> ## Clarification`，用 `clarification_ledger` 记录 `category / question / evidence / recommended_answer / decision / impact`，但账本不替代 Clarification 最低字段；用户确认前 `## User Confirmation` 保持 `draft`，账本仍有 `decision: pending` 时不得确认。进入 workflow 前，只有任务归属、目标或风险边界不足以判断时才走 `ask`；ask 不创建任务产物、不进入 PLAN，直到阻塞问题解除；能通过代码库、文档或 artifact 回答的问题，入口 agent 应先查证，剩余用户决策按依赖顺序一次只问一个并给推荐答案。

### 自动懒加载规则

入口完成 `resume-current / switch-existing / new-task / inbox-first` 判定，以及 `new-task` 的 `quick | workflow | ask` 路由后，才加载下一层材料：

- `quick`：只加载入口规则、用户偏好 / 必要配置，以及与本次请求直接相关的 skill 或 reference；不预读 orchestrator、全部 stage skill 或历史任务。
- `workflow`：加载 `entry-router`、`orchestrator`，再按当前 stage 加载一个阶段 skill：`PLAN -> plan`、`PLAN_REVIEW -> review`、`IMPLEMENT -> implement`、`CODE_REVIEW -> review`、`TEST -> test`。
- `resume-current` / `switch-existing`：先加载已存在的 `.assistant/运行时/恢复索引.md`、`.assistant/运行时/当前任务.md`、`运行时/tasks/<task-id>.md`；缺失运行时文件表示没有已记录的活动状态，不作为错误；必要时只读当前任务的 `plan.md` frontmatter 判定 stage，再加载当前 stage skill。
- `ask`：不加载 workflow stage skill；不创建 `docs/tasks/{task_id}/`、不改代码、不推进阶段；not enter quick/workflow/PLAN/IMPLEMENT。阻塞澄清到足以说明 User goal、Success / acceptance criteria、In scope、Out of scope / non-goals、Affected area、Constraints、Risk level、Expected output、Recommended route: quick or workflow、Why this route is safe。

禁止 bulk-load 全部 skills、全部历史 `docs/tasks/*`、Claude 兼容 skill 或 `workflow-team`。只有用户显式切换 backend、当前 stage frontmatter / workflow descriptor 命中、或 `$env:AITEAMCODE_TEAM_MODE='1'` 等触发条件满足时，才加载这些兼容路径。

### Markdown / HTML artifact 能力

当用户要求 Markdown/HTML 互转、HTML 报告、网页 artifact、Markdown 发布预览、或从 URL/HTML 提取 Markdown 时，入口按需加载 `md-html` skill；它不是默认开发 stage，也不进入 `agent-configs/workflows/harness-lite.yaml` 的 stage whitelist。

核心边界：

- Markdown 默认是人类和 AI 共同编辑的 canonical source / source of truth。
- HTML 默认是 generated display artifact，用于浏览器预览、视觉检查、发布和交付；长 `spec.md` / `plan.md` 的审阅版应做结构重组，不只是 Markdown 渲染。
- HTML -> Markdown 用于导入、审阅和归档，不承诺像素级还原。
- Markdown -> HTML 用于展示/发布/视觉交付，应可从同一 Markdown source 与样式规则重复生成。
- 默认不在同一轮自由编辑 Markdown 和 HTML 两份源；内容改动走 Markdown 后再生成 HTML，视觉改动走模板/样式规则后再生成 HTML。

路由建议：

- `quick`：小文档直接转换、导入或生成。
- `workflow`：复杂报告、网页原型、可审计交付先声明 Markdown source、HTML artifact、模板/样式边界和验证方式。
- `ask`：缺少方向、用途、输出路径或样式边界时，停留在阻塞澄清路由；默认一次问一个最高价值问题，确认后再判断 quick/workflow。

`spec.md` / `plan.md` 是最需要人工审阅和介入的文档。若它们超过 160 行或含 8 个及以上 `##` 二级标题，且用户需要审阅/决策、Markdown 层次不够清晰，默认生成同目录 paired reading HTML（`plan.review.html` / `spec.review.html`，单一审阅文件可用 `review.html`）。该 HTML 使用固定模板，主动重组 summary、decision、risk、checkpoint、流程/架构、对比矩阵、信息卡片和折叠源章节，不替代 Markdown；内容变更仍改 `spec.md` / `plan.md` 后重新生成。

仓库提供固定生成器：`pwsh -File .\scripts\render-review-html.ps1 -SourcePath .\docs\tasks\{task_id}\spec.md`。生成器只读取 Markdown，输出自包含 HTML fragment + inline CSS，并带 visual block 标记；当同目录同时存在 `spec.md` 与 `plan.md` 时，`review.html` 会被拒绝，需使用 `spec.review.html` / `plan.review.html`。

局部 HTML 增强只允许用于卡片、对比区、流程区、信息网格；不得输出完整页面，不得把 HTML 放进代码块，不得使用 `script`、`iframe` 或外部 JS。paired reading HTML 默认不含 `doctype`、`html`、`head`、`body` 外壳；完整 HTML 页面只有用户明确要求时才生成。

### 阶段与真相源

以下阶段只适用于 `mode=workflow` 的新任务，`quick` 不创建阶段状态。

可执行阶段是：

```text
PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST
```

`DONE` 不是单独执行阶段，而是 `plan.md` frontmatter 的终态标记。

默认 descriptor 是 Codex-only：`PLAN`、`PLAN_REVIEW`、`IMPLEMENT`、`CODE_REVIEW`、`TEST` 都使用 `harness-default-codex`。`claudecode` 仍是合法 backend，但需要在任务 frontmatter 或推进命令中显式指定。

唯一阶段真相源始终是 `docs/tasks/{task_id}/plan.md` frontmatter（`task_id` / `stage` / `tool` / `updated`，加可选 `tool_profile` / `model`）。字段枚举、约束和完整骨架只在 [`skills/orchestrator/references/lite-writing-guide.md`](skills/orchestrator/references/lite-writing-guide.md) 维护一份，本 README 不重复。

### 每个阶段写什么

| Stage | 主要产物 | 说明 |
|---|---|---|
| `PLAN` | `docs/tasks/{task_id}/plan.md` | 含 frontmatter、Clarification、User Confirmation、Plan、Verification、Risks、Change Contract |
| `PLAN_REVIEW` | `plan.md` 里的 `## Plan Review` | append-only run，最新 run 决定下一步 |
| `IMPLEMENT` | 代码改动 + `plan.md` 里的 `## Implementation Notes` | 只追加新 run，不回写旧 run |
| `CODE_REVIEW` | `plan.md` 里的 `## Code Review` | append-only review run |
| `TEST` | `docs/tasks/{task_id}/test.md` | 结论与 handoff |
| `DONE` | `plan.md` frontmatter | 终态，不再新开独立文档 |

补充分支：

- 输入不足时，可选创建 `docs/tasks/{task_id}/spec.md`
- `spec.md` 现在支持可选 `front_keywords` frontmatter，用于跨任务检索和长会话恢复，但不是必填字段

### `work_type`、条件化模板与 reflection guidance

`work_type`（可选 PLAN / Clarification 分诊信号，不写入 frontmatter、不被 `advance-stage.ps1` / validator 消费）、`bug` / `refactor` 条件化模板、Clarification 协议族写法、阶段纪律矩阵、推理纪律、CODE_REVIEW 对抗性审查纪律，以及 IMPLEMENT / CODE_REVIEW 的 implementation reflection checks，写法与示例都在 [`docs/工作流/stage-discipline-matrix.md`](docs/工作流/stage-discipline-matrix.md)、[`skills/orchestrator/references/lite-writing-guide.md`](skills/orchestrator/references/lite-writing-guide.md) 与对应 stage skill 维护，本 README 不重复。

### 推进规则

当前 `advance-stage.ps1` 的真实语义如下：

- 所有阶段推进都必须走 `advance-stage.ps1`
- 推进前自动调用 `validate-lite-artifacts.ps1`
- 非 `DONE` 推进的 tool 解析顺序：
  - 显式 `-Tool`
  - 显式 `-Profile`
  - `agent-configs/workflows/harness-lite.yaml` 的 `default_profile`
- `pure cli-tool`：显式传 `-Tool`，但未传 `-Profile/-Model` 时，会主动清空下一阶段的 `tool_profile/model`
- `workflow-default`：若命中 descriptor 的 `default_profile`，会把该 profile 与其 model 写回下一阶段 frontmatter
- `PLAN_REVIEW` / `CODE_REVIEW` 的最新 run 若 `verdict: revise`，下一步会回到对应修订阶段
  - `PLAN_REVIEW revise -> PLAN`
  - `CODE_REVIEW revise -> IMPLEMENT`
- `TEST fail/blocked` 不自动回退，停在报告层处理

## `.assistant`、`docs/tasks`、validator、git 的职责

### `docs/tasks/{task_id}/`

这是任务的审阅面与阶段真相源。

- `plan.md` frontmatter 是唯一阶段真相源
- `plan.md` 的 review / implementation run 是 append-only
- `test.md` 记录 TEST 结论
- `spec.md` 是可选补充，不是默认入口
- Phase 3 之后的可选 side artifacts：
  - `skill-manifest.json`
  - `skills-index.md`

### `.assistant/`

这是项目本地入口、共享记忆、恢复、运行时派生视图与可选协议文档所在位置。`.assistant/` 是用户/工作区本地状态，默认不进入 Git；需要长期维护的协议、模板与规则应放入 tracked `docs/`、`skills/`、`tests/` 或 `vault-template/`。默认 minimal 安装只包含入口 shim 与最小运行时目录；full vault 才包含完整配置、工作流说明、模板与 Obsidian 配置。

按 shared-memory v2 当前约定，可以把它理解成四层：

| 层 | 路径 | 角色 |
|---|---|---|
| artifact | `docs/tasks/{task_id}/` | 任务真相源 |
| runtime | `.assistant/运行时/` | 当前任务、恢复索引、task mirror、收件箱、wisdom 等运行时状态；minimal 下按需生成 |
| config | `.assistant/配置/` | 用户偏好、工具、schema 版本；full vault 才默认安装 |
| workflow | `.assistant/工作流/` | 协议与恢复说明；full vault 才默认安装 |

当前最重要的职责分工：

- `.assistant/运行时/tasks/<task-id>.md` 是从任务产物镜像出来的 task-runtime，按需生成
- `.assistant/运行时/当前任务.md` / `恢复索引.md` 是共享 pointer / derived view，按需生成
- `.assistant/工作流/长会话恢复.md` 只在 full vault 中默认存在，用于汇总恢复触发词、读取顺序和单写者场景
- 新事项先进入 `.assistant/运行时/收件箱.md`，文件不存在时由写入入口创建
- pending wisdom 不直接落到 `记忆-*.md`，而是先走收件箱，再 promote/triage

### `validate-lite-artifacts.ps1`

这是任务文档 gate，不是共享记忆 gate。

当前它会校验：

- `plan.md` frontmatter schema
- `PLAN` / `PLAN_REVIEW` / `IMPLEMENT` / `CODE_REVIEW` / `TEST` 的 section 结构
- review run 的 `verdict/findings/next` 契约
- 可选 `spec.md` 与 `front_keywords`
- Phase 2 的 workflow descriptor advisory `Warnings:`
- Phase 6/7 的 plan metadata：`read_first` / `convergence` / `artifacts`

artifact drift 属于 advisory-first 检查，不是硬 gate：

- `PLAN` / `PLAN_REVIEW` 阶段不会因为未来 artifact 尚未创建而 warning
- `IMPLEMENT` 及之后阶段会把声明 artifact 缺失、实际 changed path 未被 `artifacts:` 或 `Change Contract -> affected_paths` 覆盖、以及 artifact / affected_paths 明显角色混淆写入 `Warnings:`
- 这些 warning 默认不进入 `Errors:`，也不改变 exit code
- 缺少 `artifacts:` 或 `Change Contract` 的 legacy / incomplete task 继续合法

### `git`

`git` 在这个体系里承担“可审计代码与协议变更面”角色，不是运行时状态容器。

当前真实边界：

- `docs/tasks/{task_id}/*` 是本地 workflow 任务产物，默认由 `.gitignore` 排除；需要沉淀长期协议时，把结论移入 `docs/工作流/`、`skills/`、`tests/` 或其他明确维护面
- `.assistant/` 整体默认忽略，不应提交 live vault、runtime pointer、用户偏好或恢复视图
- `.assistant/` 里的通用协议若需要进入仓库，应先提升到 `docs/工作流/`、`skills/` 或 `vault-template/`，再由安装/更新路径渲染到目标工作区
- 仓库历史里可能曾保留 shared-memory migration 相关 `.assistant` 文件；当前索引不再跟踪 `.assistant/` 内容

## 历史 Phase 能力（已并入主线）

当前仓库已包含 Phase 1-7 与 shared-memory v2 的主线能力。这些约束不再按 phase 单独罗列，而是并入对应单一真相源：

- plan metadata（`read_first` / `convergence` / `artifacts`）与 review `-Quality` 4-dim score（`completeness` / `consistency` / `accuracy` / `depth`）：见 [`skills/orchestrator/references/lite-writing-guide.md`](skills/orchestrator/references/lite-writing-guide.md) 与 [`docs/工作流/quality-rubric.md`](docs/工作流/quality-rubric.md)
- `PreCompact` 自检与 single-writer 写回（append 走 `append-runtime-inbox.ps1`，非 append 写回只委托 `advance-stage.ps1`）：见 [`skills/orchestrator/SKILL.md`](skills/orchestrator/SKILL.md)、[`skills/workflow-team/SKILL.md`](skills/workflow-team/SKILL.md) 与 [`docs/工作流/single-writer-precompact.md`](docs/工作流/single-writer-precompact.md)
- team auto mode 环境变量固定为 `HARNESS_AUTO`；长会话恢复优先看已存在 runtime 指针，full vault 项目再读 `.assistant/工作流/长会话恢复.md`；`spec.md` 可选 `front_keywords`

## 关键入口命令

### 终端用户最常用

```powershell
# 安装 / 更新
pwsh -File .\harness.ps1 -WorkspaceRoot <workspace-root>
pwsh -File .\scripts\update-managed-assets.ps1 -WorkspaceRoot <workspace-root>

# 推进与校验
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} [-Tool <backend>] [-Profile <profile>] [-Model <full-model-id>]
pwsh -File .assistant\entry\validate-lite-artifacts.ps1 -TaskId {task_id} [-Quality]

# 共享记忆
pwsh -File .\scripts\memory-health.ps1 -VaultRoot <workspace-root>\.assistant
pwsh -File .\scripts\repair-shared-memory.ps1 -VaultRoot <workspace-root>\.assistant
pwsh -File .\scripts\check-shared-memory-layers.ps1 -VaultRoot <workspace-root>\.assistant
```

### 高级 / 维护入口

```powershell
# ACP-style skill adapter
pwsh -File .\scripts\invoke-harness-skill.ps1 -TaskId {task_id} -Stage PLAN_REVIEW -Skill review -Tool codex -WorkspaceRoot <workspace-root> -ArtifactRoot docs\tasks\{task_id} -Mode readonly -PayloadJson '{}'

# per-task skills index
pwsh -File .\scripts\generate-skills-index.ps1 -TaskId {task_id} -Stage TEST -BackendHint codex

# team preset 导出与 team mode
pwsh -File .\scripts\export-team-preset.ps1 -Workflow harness-lite -Output <tmp>\team.yaml
$env:AITEAMCODE_TEAM_MODE='1'
$env:HARNESS_AUTO='1'
pwsh -File .\skills\workflow-team\scripts\spawn-team.ps1 -TaskId {task_id}
```

## 当前仓库清单

截至当前仓库状态：

- `skills/` 下有 `12` 个 skill 目录（含 `.system`、`codex` 和按需 artifact skill `md-html`）
- `scripts/` 下有 `20` 个 PowerShell 脚本
- `runtime-hooks/claude/` 下有 `3` 个 hooks
- `tests/` 下有 `38` 个 `verify-*.ps1` 回归脚本

关键组件分布：

| 区域 | 当前重点 |
|---|---|
| `skills/entry-router` | 顶层入口与开发路由 |
| `skills/orchestrator` | 主流程编排 |
| `skills/plan` / `implement` / `review` / `test` | 各阶段写作与产物规则 |
| `skills/workflow-team` | team preset bridge 与 auto / PreCompact 协议 |
| `skills/obsidian-memory` | 共享记忆读写、repair、promotion |
| `skills/md-html` | Markdown/HTML 互转、发布与导入边界 |
| `agent-configs/profiles` | tool profile 描述符 |
| `agent-configs/workflows/harness-lite.yaml` | workflow descriptor 与阶段注释协议 |
| `vault-template/` | 新工作区 `.assistant` minimal/full 骨架 |

## 验证与回归

### 安装验证

```powershell
pwsh -File .\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root> -RepoRoot D:\data\dev-harness
```

### quiet validation 三档

```powershell
# 快速文档 / footprint 锁点：git diff --check + verify-lite-footprint.ps1
pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite quick

# 文档 / 协议核心验证
pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite core
```

`scripts/run-validation.ps1` 是推荐的 quiet validation 入口：外层只启动一次 PowerShell；内部验证脚本用无窗口子进程串行执行，保留每个脚本独立 exit code，同时减少验收阶段反复弹出 PowerShell 窗口。

三档口径：

- `quick`：只跑 `git diff --check` 和 `tests/verify-lite-footprint.ps1`，适合 README / 文档小修后的快速回归。
- `core`：跑 `git diff --check` 加核心协议脚本，包括 context-provider guardrails、artifact validator、footprint、workflow contracts / descriptor、shared-memory layers、review HTML renderer、skill manifest、AiTeamCode skill contract、tool profile，以及安装路径无 Node/npm/npx 强依赖检查。
- `all`：跑 `git diff --check` 加除 `verify-installation.ps1` 外所有 `tests/verify-*.ps1`；需要安装验证时额外传 `-WorkspaceRoot`。

GitHub Actions 在 `main` 与 `codex/harness-distribution` 的 push，以及 pull request 上运行 Windows quick/core validation。CI 不安装、注册或连接外部 provider，也不要求 Node.js。

### 跑完整 verify 套件

当前共有 `38` 个 `verify-*.ps1`；其中 `verify-installation.ps1` 需要显式传 `-WorkspaceRoot`。

```powershell
# 跑可直接执行的验证脚本；verify-installation.ps1 需要 WorkspaceRoot 时单独传入
pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite all

# 连同安装验证一起跑
pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite all -WorkspaceRoot <workspace-root>
```

## 维护提示

- 本仓库当前默认语言是中文；代码、命令、标识符保留英文
- active `.ps1` 继续要求 UTF-8 BOM，`tests/verify-lite-footprint.ps1` 会锁这个约束
- Git 索引不跟踪 live `.assistant/entry/AGENTS.md`；安装到目标工作区后会从 `vault-template/entry/AGENTS.md.template` 生成这个 shim
- 如果你改了 workflow/validator/shared-memory 协议，优先同步：
  - `README.md`
  - `skills/orchestrator/references/lite-writing-guide.md`
  - 相关 `tests/verify-*.ps1`
