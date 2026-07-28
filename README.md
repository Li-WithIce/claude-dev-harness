# Requirement-Safe Thin Harness v2

Windows 优先的轻量工程 harness。新任务先经过 Requirement Gate，再按风险选择 Ask、Direct、Governed 或 Critical；清晰低风险工作直接修改并验证，高风险工作才按需增加持久状态、Evidence、Approval、回滚和独立审查。既有 v1 `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST` 任务继续按 artifact 自动识别、恢复和完成，不会被隐式迁移或删除。

## 当前交付状态

- **v2 public opt-in implementation complete**：Requirement Gate、执行 profile、v2 Task State / Evidence / Approval / Audit、v1/v2 共存与迁移，以及工作区级 `enable-v2` 和 `core` / `governed` / `full` 生命周期已进入公共工程交付范围。
- 普通工作区的默认 `auto` 仍继续 fail-closed 到 v1；需要主动试用的新任务可执行一次工作区级 `enable-v2`，之后正常打开 Codex Desktop，不需要保留环境变量。Default Promotion、零配置 Auto 默认 v2 和 v1 retirement 均是后续里程碑。已有任务始终按现有 v2 `task.json` 或 v1 `plan.md` artifact 继续原协议，不会被偏好配置隐式迁移。
- 入口和架构已经瘦身；本页不声明性能已接近 Bare。

## 快速开始

### 1. 安装默认 core preset

```powershell
pwsh -File .\install.ps1 `
  -WorkspaceRoot D:\my-project `
  -RepoRoot D:\data\dev-harness `
  -Preset core
```

`core` 是新工作区的最小推荐安装；`governed` 增加规划与审计能力，`full` 再加入共享记忆和 team 等可选能力。安装和更新只要求 PowerShell 与 Git，不要求 Node.js。

### 2. 用 Codex 桌面打开项目

默认兼容用法可直接用 Codex 桌面打开 `D:\my-project`，无需设置 `HARNESS_PROTOCOL` 或手工选择 execution profile；当前没有 Runtime Default Decision 时，普通 `auto` 路径进入 v1。要让这个项目的新任务显式使用 v2，只需执行一次：

```powershell
# 只读查看当前新任务协议选择
pwsh -File .assistant\entry\task.ps1 protocol

# 项目级公共 opt-in；随后可正常打开 Codex Desktop，无需环境变量
pwsh -File .assistant\entry\task.ps1 enable-v2

# 恢复 Runtime Default 驱动的 auto，或立即让新任务止损到 v1
pwsh -File .assistant\entry\task.ps1 reset-auto
pwsh -File .assistant\entry\task.ps1 disable-v2
```

选择保存在默认不入 Git 的 `.assistant/config/protocol.json`，install、update 和 uninstall 都保留它。优先级固定为：已有 v1/v2 artifact；显式维护覆盖或 `HARNESS_PROTOCOL`；工作区配置；有效的 `.assistant/runtime/protocol-default.json`；v1 fallback。`enable-v2` 是独立可用的项目级 opt-in。

### 3. 直接描述需求

直接说明目标、验收和必要约束；入口根据已确认需求、风险和持久化要求选择：

| 结果 | 何时使用 | 最短行为 |
|---|---|---|
| Ask | 仍有真正未决的用户/产品/授权决定 | 只澄清阻断项，不写代码或任务状态 |
| Direct | 需求清楚、私有且可逆的低风险改动 | 理解、修改、聚焦验证、自审、报告；不创建任务产物 |
| Governed | 需要持久留痕、较高风险或受保护范围 | 使用 v2 task state，并按策略产出 Evidence；计划、审批、回滚或独立审查按需组合 |
| Critical | 生产、权限、资金、破坏性或不可逆高风险动作 | 在执行/完成前满足计划、Approval、回滚、独立审查、dry-run、验证和 Evidence |

只读请求使用 Inspect，保持零写入。`quick` / `workflow` 仅是 Direct / Governed 的兼容别名，不是第二套规则。

默认加载面只包含宿主级 Overlay 和短协议 Bootstrap；完整 v1 路由表、Ask 十项退出条件、Inbox、Recovery 与阶段规则只有在 artifact/protocol detector 选择 v1 后才从 `entry-router` / `orchestrator` 懒加载。Codex 会读取 workspace `AGENTS.md`，所以全局文件保持纯 Overlay；Claude 不消费该文件，因此其全局 `CLAUDE.md` 携带同一短 Bootstrap，但不再注入完整 v1 合同。

恢复语义保持兼容：明确“继续”或“恢复并执行”才推进；只问状态时保持只读；裸“恢复一下”/`resume` 若意图不明则 ask。

## Evidence、Approval 与受保护动作

Evidence 记录真实执行过的验证、覆盖与缺口，并绑定任务版本和仓库修订；没有执行的检查不能写成通过。Critical 的 Approval、顶层结构化 `dry_run` 和至少一条成功执行 record 还必须绑定同一个运行时重算的 `protected-operation/v1` identity，且 `covers` 非空并包含它；无关成功 no-op、环境/目标/scope 漂移或旧 Critical 记录缺少绑定都会 fail closed。该 identity 只使用任务版本、Contract digest、规范化环境/目标、受保护动作类别、Approval 类型与 scope 等稳定非秘密输入。Approval 是对确定操作的合作式授权记录，不是密码学身份认证；参与独立性判断的 actor/context/base-model 字段拒绝空白字符串。

Core 只内置有限的受保护动作规则：生产破坏性数据库命令，以及 `auth` / `permissions` / `rbac` 路径变更。项目特有风险必须通过严格的 `protected-actions-overlay/v1` 增加，不能靠提示词放宽 core。安装器把 Codex `PreToolUse` 合并到普通用户 `hooks.json`，不写信任记录，也不覆盖企业 `hooks=false` / managed-only 策略；经用户正常信任并启用后，`Bash` 只把 command text 送入 core policy。宿主未提供可信的实际 environment identity/cwd 时，Bash 中的 `apply_patch` / `applypatch` 和所有 direct `apply_patch` 都在 adapter 层 fail closed；adapter 不从 approval/permission 标签臆造只读保证。

Windows 启动链使用绝对 System32 Windows PowerShell 与安装时固化的 PowerShell 7.3+ 路径；用户 JSON 用显式 writer 精确保留 `BigInteger` 与 decimal。命令、参数和脚本文件均保持明文，不使用 `EncodedCommand`、隐藏窗口、动态求值、改写信任或安全产品绕过。用户目录若包含无法同时由 cmd 与 PowerShell 安全表示的 `` ` $ % ! ^ & | < > ( ) `` 字符，安装会在写入前拒绝。`tests/verify-v2-install-presets.ps1` 证明命令链可解析并产生预期 allow/deny JSON，但不证明 Host 已信任或启用 Hook，也不证明端点产品已放行。企业策略、Hook trust 或端点隔离无法观测时，Capability 保持 `unavailable`；普通 Direct 不把这种不可观测性误写成 Release 失败。宿主 Hook 是 guardrail，不是完整执行边界；Critical 生产动作仍必须交给独立受控执行器。

仓库同时提供 release-only 的 `config.workspace.toml.template` 与 `harness-write-mcp.ps1`，用于验证“原生只读、唯一受控写工具”的确定性边界。受控 writer 固定 RepoRoot/WorkspaceRoot、规范化目标、执行目标 preimage CAS，并对受保护写重新绑定 v2 task/version/profile/Contract/Approval/dry-run；它拒绝 Harness 控制面、自身 RepoRoot 和 NTFS alternate data stream。`install.ps1` 不部署该原型；无法观察时状态保持 `unavailable`，不能写成 active/pass。

## Worktree 与回滚最短路径

- 每个 linked worktree 都要以自己的路径单独安装，例如 `-WorkspaceRoot D:\repo-worktrees\feature-a`；不要复制父工作区的 `.assistant/runtime/current.json` 或 live runtime。
- 真正的 Git submodule 继续使用父 workspace；独立嵌套仓库即使通过 `git init --separate-git-dir` 保存 metadata，也会按自己的 worktree root 隔离安装，不继承父 current、task 或 Approval。
- v2 持久任务状态当前只在 Windows 上提供物理工作区锁身份；非 Windows、junction/symlink/folder-mount 祖先与其他 reparse 路径会明确 fail closed，不会退化为词法路径锁。
- 新任务需要立即回到 v1 路由时，运行 `.assistant\entry\task.ps1 disable-v2`；一次性维护止损也可设置 `HARNESS_PROTOCOL=v1`。两者都不会删除或降级已有 v2 task；卸载安装器托管资产请单独运行 `uninstall.ps1`，它会保留用户的协议选择。
- 快速上手、Requirement Gate 和持久治理分别见 [`docs/quick-start.md`](docs/quick-start.md)、[`docs/requirement-gate.md`](docs/requirement-gate.md)、[`docs/governed-work.md`](docs/governed-work.md)。

## Optional Context Providers

Context providers 是可选辅助输入，不是 workflow 真相源。内置权威仍是 `docs/tasks/{task_id}/`、当前仓库文件和本地 `.assistant/`；CodeGraph、agentmemory、codedb-mcp 只能提供 advisory context provider 结果，且必须落回真实路径、命令、diff、review finding、Implementation Notes 或 test output。安装、更新和 validation 默认不会安装、注册或连接外部 provider；详细边界见 `docs/工作流/context-provider-boundary.md`，工具入口见 `docs/工具/context-providers.md`。

## 维护者与显式持久任务命令

```powershell
# 只读查看 v2 恢复状态或协议判定
pwsh -File .assistant\entry\task.ps1 status
pwsh -File .assistant\entry\task.ps1 protocol -TaskId {task_id}

# Codex-only 默认路径：ExpectedStage 是调用方刚读取的 frontmatter stage
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage>

# 显式指定 profile，backend 从 profile.backend 解析
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -Profile harness-default-codex

# 仍可显式切到其他合法 backend
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -Tool claudecode

# TEST 按 Conclusion 进入 DONE / IMPLEMENT，可省略 -Tool
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage TEST

# 新建/切换 workflow task：不推进 stage，只同步并显式激活 current
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> -SyncOnly -ActivateCurrent

# 单独校验任务产物
pwsh -File .assistant\entry\validate-lite-artifacts.ps1 -TaskId {task_id}
```

## v1 兼容工作流

以下内容仅适用于 artifact detector 识别为 v1 的 workflow task。v2 的唯一生命周期真相源是 `.assistant/runtime/tasks/<task-id>/task.json`；`Direct` 路径不创建持久任务状态。

### 新任务入口模式路由

入口判定仍先保留四类结果：`resume-current`、`switch-existing`、`new-task`、`inbox-first`。只有判定为 `new-task` 后，才增加一层 `mode: quick | workflow | ask`。

- `quick`：project-scoped standalone read-only answer/explain/inspect/review/status/diagnose 在目标、范围和输出清楚时直接完成，不创建 task artifact；含 mutation 时仍只有范围/验收清楚、风险低、可在当前对话完成验证且未要求 durable workflow/artifact 才 quick。
- `workflow`：用户明确要求 durable workflow、计划/留痕或 staged review/test evidence，或 mutation 触碰入口协议、脚本、模板、validator、多文件/跨模块、高风险路径时，进入 `entry-router -> orchestrator`。
- `ask`：读写意图、任务归属或其他阻塞条件仍不清楚时进入 iterative blocking clarification gate；默认每轮只问一个最高价值问题，用户回答后重新判断。Remain in ask until all blocking uncertainties are resolved，只有足够理解后才转 `quick` 或 `workflow`。

先判 active task 归属，但 route identity does not broaden requested action；只问状态不能因此写 Run 或推进 stage。真正非项目请求仍由宿主处理。`review` / `test` / `plan` 等名词本身不决定 mode：pure read-only 默认 quick，mixed mutation 回到 low/high-risk 门，durable artifact 才 workflow，ambiguous read/write 才 ask。

“需求澄清”“需求确认”“拷问需求”“拷问方案”“头脑风暴”“方案压力测试”“设计访谈”“边界确认”“验收标准确认”“非目标确认”，以及 `clarify`、`brainstorm`、`pressure test`、`challenge this plan`、`ask me questions` 等表达属于 Clarification 协议族；PLAN 的验收、非目标、影响面、回滚/兼容仍不确定，或实现路径仍不足以指导 IMPLEMENT 时也按该协议处理。它们不是新 stage：开发任务需要可审计决策或后续实现时，进入现有 `PLAN -> ## Clarification`，用 `clarification_ledger` 记录 `category / question / evidence / recommended_answer / decision / impact`，但账本不替代 Clarification 最低字段；用户确认前 `## User Confirmation` 保持 `draft`，账本仍有 `decision: pending` 时不得确认。进入 workflow 前，只有任务归属、目标或风险边界不足以判断时才走 `ask`；ask 不创建任务产物、不进入 PLAN，直到阻塞问题解除；能通过代码库、文档或 artifact 回答的问题，入口 agent 应先查证，剩余用户决策按依赖顺序一次只问一个并给推荐答案。

### 自动懒加载规则

入口完成 `resume-current / switch-existing / new-task / inbox-first` 判定，以及 `new-task` 的 `quick | workflow | ask` 路由后，才加载下一层材料：

- `quick`：只加载入口规则、用户偏好 / 必要配置，以及与本次请求直接相关的 skill 或 reference；不预读 orchestrator、全部 stage skill 或历史任务。
- `workflow`：加载 `entry-router`、`orchestrator`，再按当前 stage 加载一个阶段 skill：`PLAN -> plan`、`PLAN_REVIEW -> review`、`IMPLEMENT -> implement`、`CODE_REVIEW -> review`、`TEST -> test`。
- `resume-current` / `switch-existing`：先只读 identity/runtime/artifact；只有明确继续 / 切换并执行时才处理 fallback、用 `-SyncOnly` 收敛/激活并加载 current stage skill。read-only inspect/status 不写 runtime、不加载 stage skill；缺失 runtime 文件表示没有已记录状态。
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

### v1 阶段与真相源

以下阶段只适用于 v1 `mode=workflow` 的任务，`quick` 不创建阶段状态。

可执行阶段是：

```text
PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST
```

`DONE` 不是单独执行阶段，而是 `plan.md` frontmatter 的终态标记。

默认 descriptor 是 Codex-only：`PLAN`、`PLAN_REVIEW`、`IMPLEMENT`、`CODE_REVIEW`、`TEST` 都使用 `harness-default-codex`。`claudecode` 仍是合法 backend，但需要在任务 frontmatter 或推进命令中显式指定。

在 v1 workflow 内，唯一阶段真相源是 `docs/tasks/{task_id}/plan.md` frontmatter（`task_id` / `stage` / `tool` / `updated`，加可选 `tool_profile` / `model`）。字段枚举、约束和完整骨架只在 [`skills/orchestrator/references/lite-writing-guide.md`](skills/orchestrator/references/lite-writing-guide.md) 维护一份，本 README 不重复。

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
- 所有 advance/sync/activate 都要求调用方显式传刚读取的 `-ExpectedStage`；CAS 不匹配时零写入，shim 不会代读或代填
- 推进前自动调用 `validate-lite-artifacts.ps1`
- `-SyncOnly` 不推进 stage、不运行阶段完成度 gate，且不能与 `-Tool/-Profile/-Model` 同用；`-ActivateCurrent` 只用于明确的新建/切换并拒绝 `DONE`
- 非 `DONE` 推进的 tool 解析顺序：
  - 显式 `-Tool`
  - 显式 `-Profile`
  - `agent-configs/workflows/harness-lite.yaml` 的 `default_profile`
- `pure cli-tool`：显式传 `-Tool`，但未传 `-Profile/-Model` 时，会主动清空下一阶段的 `tool_profile/model`
- `workflow-default`：若命中 descriptor 的 `default_profile`，会把该 profile 与其 model 写回下一阶段 frontmatter
- `PLAN_REVIEW` / `CODE_REVIEW` 的最新 run 若 `verdict: revise`，下一步会回到对应修订阶段
  - `PLAN_REVIEW revise -> PLAN`
  - `CODE_REVIEW revise -> IMPLEMENT`
- `TEST pass -> DONE`；`fail -> IMPLEMENT`；`blocked` 保持 `TEST` 并报告解除条件。`fail` 回环沿用同一推进命令，不新增 reopen 操作
- validator 用 append-only run 与 `Evidence.executed_at` 的书面 `yyyy-MM-dd HH:mm` 建立 freshness 链；更早分钟拒绝，同分钟沿用既有合同视为 fresh
- mirror 始终同步实际 stage；active advance 更新 current，background advance 不抢 current；active `DONE` 将 current 重置为 canonical idle，background `DONE` 不改 current
- runtime ladder 任一步失败都返回非零并追加 `[writeback-fallback]`；只有明确继续 / 切换并执行 workflow 时，resume/switch 才处理 fallback 并用相同 `TaskId/ExpectedStage -SyncOnly` 幂等重放

## v1 的 `.assistant`、`docs/tasks`、validator、git 职责

### `docs/tasks/{task_id}/`

这是 v1 任务的审阅面与阶段真相源。

- 在 v1 workflow 内，`plan.md` frontmatter 是唯一阶段真相源
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
- 只有已授权持久捕获的 actionable/durable 新事项才进入 `.assistant/运行时/收件箱.md`；交互式归属或读写歧义先 ask，不写 inbox
- 只有用户明确要求记录/沉淀记忆后，pending wisdom 才可先走收件箱再 promote/triage；普通 review/status 只提示可沉淀内容

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

## v1 历史 Phase 能力（兼容保留）

当前仓库仍保留 Phase 1-7 与 shared-memory v2 能力，供已有 v1 任务兼容使用。这些约束不再按 phase 单独罗列，而是并入对应的 v1 真相源：

- plan metadata（`read_first` / `convergence` / `artifacts`）与 review `-Quality` 4-dim score（`completeness` / `consistency` / `accuracy` / `depth`）：见 [`skills/orchestrator/references/lite-writing-guide.md`](skills/orchestrator/references/lite-writing-guide.md) 与 [`docs/工作流/quality-rubric.md`](docs/工作流/quality-rubric.md)
- `PreCompact` 自检与 single-writer 写回（append 走 `append-runtime-inbox.ps1`，非 append 写回只委托 `advance-stage.ps1`）：见 [`skills/orchestrator/SKILL.md`](skills/orchestrator/SKILL.md)、[`skills/workflow-team/SKILL.md`](skills/workflow-team/SKILL.md) 与 [`docs/工作流/single-writer-precompact.md`](docs/工作流/single-writer-precompact.md)
- team auto mode 环境变量固定为 `HARNESS_AUTO`；长会话恢复优先看已存在 runtime 指针，full vault 项目再读 `.assistant/工作流/长会话恢复.md`；`spec.md` 可选 `front_keywords`

## v1 持久工作流与维护入口

### 安装、状态与 v1 阶段维护

```powershell
# 安装 / 更新
pwsh -File .\harness.ps1 -WorkspaceRoot <workspace-root>
pwsh -File .\scripts\update-managed-assets.ps1 -WorkspaceRoot <workspace-root>

# 推进与校验
pwsh -File .assistant\entry\task.ps1 status
pwsh -File .assistant\entry\task.ps1 protocol -TaskId {task_id}
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage <current-stage> [-SyncOnly] [-ActivateCurrent] [-Tool <backend>] [-Profile <profile>] [-Model <full-model-id>]
pwsh -File .assistant\entry\validate-lite-artifacts.ps1 -TaskId {task_id} [-Quality]

# 共享记忆
pwsh -File .\scripts\memory-health.ps1 -VaultRoot <workspace-root>\.assistant
pwsh -File .\scripts\repair-shared-memory.ps1 -VaultRoot <workspace-root>\.assistant
pwsh -File .\scripts\check-shared-memory-layers.ps1 -VaultRoot <workspace-root>\.assistant
```

旧安装状态只能通过同一个维护入口显式收敛，并分成只读 plan 与 digest-bound apply 两步：

```powershell
# 只读生成计划；预期以非零状态 REBASELINE_PLAN_REQUIRED 返回 digest 与计数
pwsh -File .\scripts\update-managed-assets.ps1 -WorkspaceRoot <workspace-root> -RebaselineLegacyInstallState

# 人工核对计划后，携原 digest 执行 apply；状态漂移会拒绝执行
pwsh -File .\scripts\update-managed-assets.ps1 -WorkspaceRoot <workspace-root> -RebaselineLegacyInstallState -ExpectedRebaselinePlanDigest <digest-from-plan-only>
```

这是显式的 digest-bound TOFU：legacy v1.1 没有历史 payload digest，因此只能绑定当前可读来源、恢复计划与 live identity，不能证明过去从未被篡改。apply 禁止 `-SkipVerify`，只有后续 install 完成且 verifier 精确返回 `STATUS: PASS` 才成功；若 rebaseline 已提交而后续 install 或 verifier 未精确完成，命令以非零 `STATUS: UPDATE_COMMITTED_UNVERIFIED` 返回，不声称 rollback，调用方可按各入口自身的安全校验重试 verify、update 或 uninstall。

### 安装 preset 与旧版 VaultProfile

新安装应使用 `-Preset core|governed|full`。未显式传 preset 的新工作区默认使用 `core`；已安装工作区再次运行安装器时，从最新 manifest 保留原 preset，不会隐式缩减能力。

`-VaultProfile auto|minimal|full` 只保留为旧调用方迁移入口，并会输出弃用提示：`minimal` 映射到 `core`，`full` 映射到 `full`，`auto` 对既有 full vault 保持 preserve；与显式 `-Preset` 同时出现时，`auto` 只是无约束兼容提示，显式 preset 胜出。该参数只控制安装器维护范围，不会自动删除既有 vault 内容。

### 高级 / 维护入口

```powershell
# explicit readonly Codex delegation
pwsh -File .\scripts\invoke-harness-skill.ps1 -TaskId {task_id} -Stage PLAN_REVIEW -Skill codex -Tool codex -WorkspaceRoot <workspace-root> -Mode readonly -PayloadJson '{"task":"Review the current plan"}'

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

组件数量随仓库演进动态生成，避免 README 数字漂移：

```powershell
pwsh -NoProfile -File .\scripts\get-repo-inventory.ps1
```

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

# 只跑一个 core 分组；可选值见下方说明
pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite core -CoreGroup entry-lifecycle
```

`scripts/run-validation.ps1` 是推荐的 quiet validation 入口：从 Windows PowerShell 5.1 调用时，入口只把已声明的固定参数透明转交给 `pwsh`；PowerShell 7.3+ runner 才进入后续验证。每项检查先启动固定、可审计的 tracked supervisor，supervisor 发布 `READY` 后才由父进程加入 Windows kill-on-close Job Object，收到匹配的 `GO` 后再执行目标。父进程仍在运行时，正常结束或超时都会主动终止 Job 并确认 active-process 为零；PowerShell 7 runner 被强停时则由操作系统关闭不可继承的 Job handle，触发 kill-on-close。不支持 Job assignment 时 fail closed。参数只经严格 JSON data request 传递，请求绑定系统临时目录中的随机 token 路径，并在确认归属后、目标进入前删除 request 及其专属空目录；不使用编码命令、动态脚本载荷、隐藏窗口或策略绕过参数。Windows 互操作源码固定在 `scripts/lib/Harness.ValidationJob.cs`。

三档口径：

- `quick`：只跑 `git diff --check` 和 `tests/verify-lite-footprint.ps1`，适合 README / 文档小修后的快速回归。
- `core`：跑 `git diff --check`、v1/v2 核心协议、Requirement/route/TaskState/Evidence/Approval/兼容迁移、行为 eval、CI 路由、artifact/runtime/install 合同与基础 workflow/skill/tool checks；Memory、Team、md-html、Codex adapter 和 Provider 重型验证由 changed optional 或 `all` 执行。
- `all`：跑 `git diff --check` 加除 `verify-installation.ps1` 外所有 `tests/verify-*.ps1`；需要安装验证时额外传 `-WorkspaceRoot`。

`-CoreGroup` 只允许与 `-Suite core` 一起使用，默认值 `all` 保持 43 个 core 脚本及其顺序；五个可单独执行的分组依次为 `entry-lifecycle`（14）、`evaluation-release`（9）、`install-evidence`（2）、`governance-approval`（3）和 `harness-contracts`（15）。从 Windows PowerShell 5.1 进入时，该参数也会透明转交给 PowerShell 7 runner。

GitHub Actions 的普通 PR 路径由五路 `pr-core-checks` matrix、`changed-optional` 和最终 core 安装回滚组成。所有普通 PR job 都 checkout 精确 PR HEAD，并分别上传一个 `thin-harness-ordinary-ci-receipt/v1` 单文件 artifact；receipt 只含 PR/run、base/head/checkout SHA、固定 check identity、outcome 与 UTC 时间，不含 prompt、credential、raw trace/log 或私人绝对路径。最终 `pr-core` 只有在五个分组精确为 `success` 时才继续；`pr-core-checks` 的每个 matrix leg 与最终 `pr-core` job 上限均为 45 分钟，`changed-optional` 上限为 30 分钟。

协议解析先认已有 v2 `task.json` / 合法 v1 `plan.md` artifact，再看显式维护覆盖或 `HARNESS_PROTOCOL`，随后读取严格的工作区 `.assistant/config/protocol.json`。只有新任务最终仍为 `auto` 时才读取版本无关、Evidence 无关的 `.assistant/runtime/protocol-default.json`；它严格验证 schema、digest、source revision、可选 workspace/expiry 绑定和实际 required capabilities。Decision 缺失或无效时回退 v1；`disable-v2` / `HARNESS_PROTOCOL=v1` 永久保留为止损开关。

### 跑完整 verify 套件

完整清单由 `scripts/run-validation.ps1` 动态发现 `tests/verify-*.ps1`；其中 `verify-installation.ps1` 需要显式传 `-WorkspaceRoot`，不要在文档中维护易失真的固定数量。

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
