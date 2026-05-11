# Harness Lite

Windows 优先的单仓库开发 harness。它把 `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST` 的可执行阶段、`DONE` frontmatter 终态、共享记忆 `.assistant/`、以及 `docs/tasks/<task-id>/` 产物统一到同一套协议里，当前仓库状态已经包含 Phase 1-7 与 shared-memory v2 的主线能力。

## 这份 README 面向谁

- 使用者：把 harness 安装到你的工作区后，按这里的“日常使用”与“阶段推进”工作。
- 维护者：在本仓库里修改脚本、skills、模板与测试，并用这里的校验命令确认行为没有回退。

## 快速开始

### 安装到目标工作区

```powershell
# 快捷入口
pwsh -File .\harness.ps1 -WorkspaceRoot D:\my-project

# 直接安装
pwsh -File .\install.ps1 -WorkspaceRoot D:\my-project -RepoRoot D:\data\claude-dev-harness
```

安装完成后，目标工作区会得到：

- 工作区入口文档：`AGENTS.md`、`GEMINI.md`
- 工作区共享记忆：`.assistant/`
- 工作区入口 shim：`.assistant/entry/AGENTS.md`、`.assistant/entry/GEMINI.md`
- 工作区脚本 shim：`.assistant/entry/advance-stage.ps1`、`.assistant/entry/validate-lite-artifacts.ps1`
- Claude Code hooks：`runtime-hooks/claude/*.js` 的安装副本

宿主侧当前真实行为是：

- repo `skills/` 会同步到 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills`
- Claude / Codex 会写入各自的共享 `settings.local.json`；Codex 只写 Harness 托管的 `%USERPROFILE%\.codex\managed_config.toml`
- 用户私有的 `%USERPROFILE%\.codex\config.toml` 不由安装脚本或 workflow 创建、清理或改写
- Gemini 当前依赖工作区 `GEMINI.md` 入口，不会像 Claude/Codex 一样同步一份 host-level `skills` 目录

### 日常使用

安装后的用户视角，日常基本只有 4 件事：

1. 在目标工作区里直接发起开发任务，让入口文档先判定 `resume-current / switch-existing / new-task / inbox-first`；`new-task` 再轻量路由到 `quick / workflow / ask`。
2. `quick` 直接完成并报告验证；`workflow` 才进入 `entry-router -> orchestrator` 并写 `docs/tasks/<task-id>/`。
3. workflow 阶段完成后，用 `.assistant/entry/advance-stage.ps1` 推进到下一阶段。
4. 会话中断后，说“继续”/“恢复”/`resume`，按 `.assistant/工作流/长会话恢复.md` 的顺序恢复。

最常用命令：

```powershell
# Codex-only 默认路径：下一阶段已有 descriptor default_profile 时可省略 -Tool/-Profile
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id>

# 显式指定 profile，backend 从 profile.backend 解析
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Profile harness-default-codex

# 显式指定 tool + profile + model
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool codex -Profile harness-default-codex -Model gpt-5.5/xhigh

# 仍可显式切到其他合法 backend
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool claudecode

# TEST -> DONE 可省略 -Tool
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id>

# 单独校验任务产物
pwsh -File .assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>
```

## 真实任务流程

### 新任务入口模式路由

入口判定仍先保留四类结果：`resume-current`、`switch-existing`、`new-task`、`inbox-first`。只有判定为 `new-task` 后，才增加一层 `mode: quick | workflow | ask`。

- `quick`：低风险、边界清楚、可在当前对话内直接完成和验证的小改动 / 简短回答；默认不创建 `docs/tasks/<task-id>/`，不改共享指针。
- `workflow`：需要计划、留痕、review、test、多文件/跨模块协作、较高风险或用户明确要求可审计产物时，进入 `entry-router -> orchestrator`。
- `ask`：只在 quick/workflow 置信度低、显式信号冲突或缺少关键判断信息时使用，并只问一个最小澄清问题。

显式覆盖词优先：用户说“直接改”“快修”时偏 `quick`；用户说“走 workflow”“留痕”“review”“test”时偏 `workflow`。没有显式词时由入口 agent 自主判断，默认保持轻量。

### 自动懒加载规则

入口完成 `resume-current / switch-existing / new-task / inbox-first` 判定，以及 `new-task` 的 `quick | workflow | ask` 路由后，才加载下一层材料：

- `quick`：只加载入口规则、用户偏好 / 必要配置，以及与本次请求直接相关的 skill 或 reference；不预读 orchestrator、全部 stage skill 或历史任务。
- `workflow`：加载 `entry-router`、`orchestrator`，再按当前 stage 加载一个阶段 skill：`PLAN -> plan`、`PLAN_REVIEW -> review`、`IMPLEMENT -> implement`、`CODE_REVIEW -> review`、`TEST -> test`。
- `resume-current` / `switch-existing`：先加载 `.assistant/运行时/恢复索引.md`、`.assistant/运行时/当前任务.md`、`运行时/tasks/<task-id>.md`；必要时只读当前任务的 `plan.md` frontmatter 判定 stage，再加载当前 stage skill。
- `ask`：不加载 workflow skill，只问一个最小澄清问题。

禁止 bulk-load 全部 skills、全部历史 `docs/tasks/*`、Gemini / Claude 兼容 skill 或 `workflow-team`。只有用户显式切换 backend、当前 stage frontmatter / workflow descriptor 命中、或 `$env:AIONUI_TEAM_MODE='1'` 等触发条件满足时，才加载这些兼容路径。

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
- `ask`：缺少方向、用途、输出路径或样式边界时，只问一个澄清问题。

`spec.md` / `plan.md` 是最需要人工审阅和介入的文档。若它们超过 160 行或含 8 个及以上 `##` 二级标题，且用户需要审阅/决策、Markdown 层次不够清晰，默认生成同目录 paired reading HTML（`plan.review.html` / `spec.review.html`，单一审阅文件可用 `review.html`）。该 HTML 使用固定模板，主动重组 summary、decision、risk、checkpoint、流程/架构、对比矩阵、信息卡片和折叠源章节，不替代 Markdown；内容变更仍改 `spec.md` / `plan.md` 后重新生成。

仓库提供固定生成器：`pwsh -File .\scripts\render-review-html.ps1 -SourcePath .\docs\tasks\<task-id>\spec.md`。生成器只读取 Markdown，输出自包含 HTML fragment + inline CSS，并带 visual block 标记；当同目录同时存在 `spec.md` 与 `plan.md` 时，`review.html` 会被拒绝，需使用 `spec.review.html` / `plan.review.html`。

局部 HTML 增强只允许用于卡片、对比区、流程区、信息网格；不得输出完整页面，不得把 HTML 放进代码块，不得使用 `script`、`iframe` 或外部 JS。paired reading HTML 默认不含 `doctype`、`html`、`head`、`body` 外壳；完整 HTML 页面只有用户明确要求时才生成。

### 阶段与真相源

以下阶段只适用于 `mode=workflow` 的新任务，`quick` 不创建阶段状态。

可执行阶段是：

```text
PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST
```

`DONE` 不是单独执行阶段，而是 `plan.md` frontmatter 的终态标记。

默认 descriptor 是 Codex-only：`PLAN`、`PLAN_REVIEW`、`IMPLEMENT`、`CODE_REVIEW`、`TEST` 都使用 `harness-default-codex`。`claudecode` / `gemini` 仍是合法 backend，但需要在任务 frontmatter 或推进命令中显式指定。

唯一阶段真相源始终是 `docs/tasks/<task-id>/plan.md` frontmatter：

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | gemini | none
tool_profile: <optional profile id>
model: <optional full model id>
updated: YYYY-MM-DD
---
```

当前仓库的真实约束：

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`、`gemini`
- `DONE` 固定写 `tool: none`
- `tool_profile` 是可选当前阶段元数据，不是下一阶段的黏性 fallback
- `model` 必须是完整模型 ID，不接受 `pro`、`latest` 这类短别名
- 存在 `tool_profile` 时，`tool` 必须等于对应 profile 的 `backend`

### 每个阶段写什么

| Stage | 主要产物 | 说明 |
|---|---|---|
| `PLAN` | `docs/tasks/<task-id>/plan.md` | 含 frontmatter、Clarification、User Confirmation、Plan、Verification、Risks、Change Contract |
| `PLAN_REVIEW` | `plan.md` 里的 `## Plan Review` | append-only run，最新 run 决定下一步 |
| `IMPLEMENT` | 代码改动 + `plan.md` 里的 `## Implementation Notes` | 只追加新 run，不回写旧 run |
| `CODE_REVIEW` | `plan.md` 里的 `## Code Review` | append-only review run |
| `TEST` | `docs/tasks/<task-id>/test.md` | 结论与 handoff |
| `DONE` | `plan.md` frontmatter | 终态，不再新开独立文档 |

补充分支：

- 输入不足时，可选创建 `docs/tasks/<task-id>/spec.md`
- `spec.md` 现在支持可选 `front_keywords` frontmatter，用于跨任务检索和长会话恢复，但不是必填字段

### `work_type`、条件化模板与 reflection guidance

`work_type` 是可选的 PLAN / Clarification 分诊信号，用来描述“这轮按哪类工作审”，不是阶段状态、不是 frontmatter 字段，也不是 `advance-stage.ps1` 或 validator 的输入。

它和 `Change Contract.change_type` 的职责分开：

- `work_type` 描述意图和审查重点，例如 `bug`、`refactor`、`feature`、`doc`
- `Change Contract.change_type` 描述产物或变更类型，继续使用现有 validator 认可的 `task | feature | enhance | refactor`

当 `work_type: bug` 时，PLAN 里的 Clarification 应补足复现、期望/实际行为、影响面、根因定位动作和修复验证；TEST 会重点重跑复现、验证修复和最小回归；CODE_REVIEW 会检查实现证据是否覆盖根因与影响面。

当 `work_type: refactor` 时，PLAN 里的 Clarification 应补足行为不变约束、重构边界、受影响调用点、等价验证和回滚/兼容路径；TEST 会重点验证行为等价；CODE_REVIEW 会检查是否夹带计划外功能行为变化。

最小写法示例：

```markdown
## Clarification
- work_type: bug
- bug.repro: 运行 `pwsh -File tests/repro.ps1`，当前会复现退出码 1
- bug.expected: 命令通过并生成 expected.json
- bug.actual: 命令在缺少配置时提前失败
- bug.impact: 缺少可选配置的工作区无法启动相关流程
- bug.root_cause_action: 定位配置读取默认值为何未生效
- bug.fix_verification: 重跑复现命令和相关最小回归
- 验收标准: 缺少可选配置时仍使用默认值
- 非目标: 不调整配置 schema

## Change Contract
- change_type: task
- affected_paths:
  - src/config-loader.ps1
  - tests/repro.ps1
```

IMPLEMENT / CODE_REVIEW 的 implementation reflection checks 是轻量 guidance，只覆盖 5 类风险：过大文件继续塞逻辑、计划外抽象、邻近顺手重构、未声明新概念、症状补丁替代根因修复。实现者只在命中风险时，把理由、取舍和验证记录到最新 `Implementation Notes` 的 `risks` 或 `next`；未命中不需要逐项打勾。它不会新增阶段、独立 checklist、第二套真相源或 validator gate。

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

### `docs/tasks/<task-id>/`

这是任务的审阅面与阶段真相源。

- `plan.md` frontmatter 是唯一阶段真相源
- `plan.md` 的 review / implementation run 是 append-only
- `test.md` 记录 TEST 结论
- `spec.md` 是可选补充，不是默认入口
- Phase 3 之后的可选 side artifacts：
  - `skill-manifest.json`
  - `skills-index.md`

### `.assistant/`

这是共享记忆、恢复、运行时派生视图与协议文档所在位置。

按 shared-memory v2 当前约定，可以把它理解成四层：

| 层 | 路径 | 角色 |
|---|---|---|
| artifact | `docs/tasks/<task-id>/` | 任务真相源 |
| runtime | `.assistant/运行时/` | 当前任务、恢复索引、task mirror、收件箱、wisdom 等运行时状态 |
| config | `.assistant/配置/` | 用户偏好、工具、schema 版本 |
| workflow | `.assistant/工作流/` | 协议与恢复说明 |

当前最重要的职责分工：

- `.assistant/运行时/tasks/<task-id>.md` 是从任务产物镜像出来的 task-runtime
- `.assistant/运行时/当前任务.md` / `恢复索引.md` 是共享 pointer / derived view
- `.assistant/工作流/长会话恢复.md` 汇总了恢复触发词、读取顺序和单写者场景
- 新事项先进入 `.assistant/运行时/收件箱.md`
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

它当前不会做两件事：

- 不校验 `artifacts:` 里路径是否真的存在
- 不把 `artifacts:` 与 `Change Contract -> affected_paths` 做交叉校验

### `git`

`git` 在这个体系里承担“可审计变更面”角色，不是运行时状态容器。

当前真实边界：

- `docs/tasks/<task-id>/*` 是应当进入 review/commit 的主产物面
- 大部分 `.assistant/` 仍默认忽略，不应该把运行时噪音随手提交
- 已显式放开的 `.assistant` 审计面目前主要包括：
  - `.assistant/工作流/长会话恢复.md`
  - `.assistant/运行时/记忆-学习.md`
  - `.assistant/运行时/记忆-决策.md`
  - `.assistant/运行时/记忆-约定.md`
  - `.assistant/运行时/记忆-问题.md`
- 仓库历史里还保留了部分 shared-memory migration 相关 `.assistant` 文件；除非任务明确要求，不要把 live pointer 文件当成普通文档随手提交

## Phase 5 / 6 / 7 已新增或强化的使用约束

### Phase 5：文档协议收口

- `agent-configs/workflows/harness-lite.yaml` 只增加注释协议，不增加新的 YAML 实体字段
- team auto mode 的环境变量名固定为 `HARNESS_AUTO`
- 长会话恢复统一看 `.assistant/工作流/长会话恢复.md`
- `spec.md` 可选支持 `front_keywords`

### Phase 6：quality 与 plan metadata

`## Plan` 段现在支持顶部 metadata-style 块：

```markdown
## Plan
- read_first: [docs/shared-memory-layers.md, scripts/validate-lite-artifacts.ps1]
- convergence:
  - `pwsh -File tests/verify-lite-artifact-validator.ps1`
- artifacts: [docs/工作流/single-writer-precompact.md, scripts/validate-lite-artifacts.ps1]
- TODO 1: ...
```

当前规则是：

- `read_first` / `convergence` / `artifacts` 只能出现在 `## Plan` 标题之后、第一条普通 TODO 之前
- `read_first` 与 `artifacts` 必须是 inline array
- `convergence` 必须至少有 1 条非占位 criterion
- `artifacts` 是声明性字段，只做格式校验

review run 现在支持 `-Quality`：

```powershell
pwsh -File .\scripts\validate-lite-artifacts.ps1 -TaskId <task-id> -Quality
```

当前真实语义：

- 只在 `PLAN_REVIEW` / `CODE_REVIEW` 的 review run 上检查 4-dim score
- 4 个维度固定为 `completeness` / `consistency` / `accuracy` / `depth`
- 阈值以 `docs/工作流/quality-rubric.md` 为准
- 旧任务未补 score 时，在 `-Quality` 模式下只产生 warning，不强制失败

### Phase 7：PreCompact 与 single-writer

Phase 7 没有新增后台进程或新 hook，只有协议收口：

- `PreCompact` 是 leader / worker 的自检协议，不是新的 Claude Code runtime hook
- 需要先保留上下文时，只允许 append 到 `.assistant/运行时/收件箱.md`
- append 路径使用现有 `append-runtime-inbox.ps1`
- 收件箱后续仍走 `promote-runtime-inbox.ps1` / `triage-runtime-inbox.ps1`
- 一旦涉及非 append 写回，必须委托现有 `.assistant/entry/advance-stage.ps1`
- 不允许手工 patch：
  - `docs/tasks/<task-id>/plan.md` frontmatter
  - `.assistant/运行时/tasks/<task-id>.md`
  - `.assistant/运行时/当前任务.md`
  - `.assistant/运行时/恢复索引.md`

这套约束的当前文档入口是：

- `skills/orchestrator/SKILL.md`
- `skills/workflow-team/SKILL.md`
- `docs/工作流/single-writer-precompact.md`

## 关键入口命令

### 终端用户最常用

```powershell
# 安装 / 更新
pwsh -File .\harness.ps1 -WorkspaceRoot <workspace-root>
pwsh -File .\scripts\update-managed-assets.ps1 -WorkspaceRoot <workspace-root>

# 推进与校验
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> [-Tool <backend>] [-Profile <profile>] [-Model <full-model-id>]
pwsh -File .assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id> [-Quality]

# 共享记忆
pwsh -File .\scripts\memory-health.ps1 -VaultRoot <workspace-root>\.assistant
pwsh -File .\scripts\repair-shared-memory.ps1 -VaultRoot <workspace-root>\.assistant
pwsh -File .\scripts\check-shared-memory-layers.ps1 -VaultRoot <workspace-root>\.assistant
```

### 高级 / 维护入口

```powershell
# ACP-style skill adapter
pwsh -File .\scripts\invoke-harness-skill.ps1 -TaskId <task-id> -Stage PLAN_REVIEW -Skill review -Tool codex -WorkspaceRoot <workspace-root> -ArtifactRoot docs\tasks\<task-id> -Mode readonly -PayloadJson '{}'

# per-task skills index
pwsh -File .\scripts\generate-skills-index.ps1 -TaskId <task-id> -Stage TEST -BackendHint codex

# team preset 导出与 team mode
pwsh -File .\scripts\export-team-preset.ps1 -Workflow harness-lite -Output <tmp>\team.yaml
$env:AIONUI_TEAM_MODE='1'
$env:HARNESS_AUTO='1'
pwsh -File .\skills\workflow-team\scripts\spawn-team.ps1 -TaskId <task-id>
```

## 当前仓库清单

截至当前仓库状态：

- `skills/` 下有 `11` 个 workflow skills 和 1 个按需 artifact skill（`md-html`）
- `scripts/` 下有 `18` 个 PowerShell 脚本
- `runtime-hooks/claude/` 下有 `3` 个 hooks
- `tests/` 下有 `26` 个 `verify-*.ps1` 回归脚本

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
| `vault-template/` | 新工作区 `.assistant` 骨架 |

## 验证与回归

### 安装验证

```powershell
pwsh -File .\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root> -RepoRoot D:\data\claude-dev-harness
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
- `core`：跑 `git diff --check` 加核心协议脚本，包括 artifact validator、footprint、workflow contracts / descriptor、shared-memory layers、review HTML renderer、skill manifest、AionUI skill contract、tool profile。
- `all`：跑 `git diff --check` 加除 `verify-installation.ps1` 外所有 `tests/verify-*.ps1`；需要安装验证时额外传 `-WorkspaceRoot`。

### 跑完整 verify 套件

当前共有 `26` 个 `verify-*.ps1`；其中 `verify-installation.ps1` 需要显式传 `-WorkspaceRoot`。

```powershell
# 跑可直接执行的验证脚本；verify-installation.ps1 需要 WorkspaceRoot 时单独传入
pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite all

# 连同安装验证一起跑
pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite all -WorkspaceRoot <workspace-root>
```

## 维护提示

- 本仓库当前默认语言是中文；代码、命令、标识符保留英文
- active `.ps1` 继续要求 UTF-8 BOM，`tests/verify-lite-footprint.ps1` 会锁这个约束
- repo 根目录并不自带 live `.assistant/entry/AGENTS.md`；安装到目标工作区后会从 `vault-template/entry/AGENTS.md.template` 生成这个 shim
- 如果你改了 workflow/validator/shared-memory 协议，优先同步：
  - `README.md`
  - `skills/orchestrator/references/lite-writing-guide.md`
  - 相关 `tests/verify-*.ps1`
