# Harness / AionUi Workflow Alignment - Implementation Surface

本文只基于 `D:\data\claude-dev-harness` 现状梳理实现表面积；未读取 `D:\data\AionUi-main`，所以 ACP / team 侧语义需要后续由对方仓库或宿主运行时契约补齐。

## 1. Task-start tool / tool-profile selection

### 当前实现

- 唯一活动真相源是 `docs/tasks/<task-id>/plan.md` frontmatter。当前 schema 只有 `task_id/stage/tool/updated` 四个字段；validator 对字段集合做精确校验，见 `scripts/validate-lite-artifacts.ps1:421-448`。
- `tool` 只允许 `claudecode | codex | gemini`；`DONE` 才允许 `none`。该枚举硬编码在 `scripts/advance-stage.ps1:17-18`、`scripts/validate-lite-artifacts.ps1:14-15`，文档/skill 中也重复声明。
- 新任务阶段的 tool 选择目前是提示词约束，不是脚本入口：`skills/orchestrator/SKILL.md:37` 和 `skills/plan/SKILL.md:21` 要求进入 PLAN 前让用户显式指定当前 `tool`。
- 阶段推进由 `.assistant\entry\advance-stage.ps1` shim 转调 `scripts/advance-stage.ps1`；非 DONE 推进必须传 `-Tool`，校验点在 `Resolve-AssignedTool`，见 `scripts/advance-stage.ps1:245-273`。
- `tool` 不是 profile。当前文档显式拒绝固定 profile 矩阵：`skills/orchestrator/SKILL.md:32`、`skills/orchestrator/references/default-tool-profiles.md:3-24`、`scripts/advance-stage.ps1:250`。
- 共享运行时 mirror 只写 `tool` / `assigned_tool`，不写 profile，见 `scripts/advance-stage.ps1:524-531`。

### 可能改点

- 若要支持 task-start `tool_profile_id`，最小可行路径是新增一个可选 section，而不是直接扩展 frontmatter：
  - 推荐新 section：`## Workflow Binding` 或 `## Execution Binding`
  - 字段示例：`entry_tool`、`tool_profile_id`、`tool_profile_source`、`tool_bindings`、`fallback_bindings`
  - 好处：不打破 frontmatter 精确字段校验；类似已有 `## Change Contract` 的 opt-in 扩展模式。
- 若必须把 profile 放入 frontmatter，需要同步修改：
  - `scripts/validate-lite-artifacts.ps1` 的字段集合、枚举和错误文案。
  - `scripts/advance-stage.ps1` 的 `Update-Frontmatter`、frontmatter 读取和 mirror 写回。
  - `vault-template/entry/advance-stage.ps1.template`，新增参数时 shim 也要透传。
  - `skills/orchestrator/SKILL.md`、`skills/orchestrator/references/default-tool-profiles.md`、`state-templates.md`、`lite-writing-guide.md`、`runbook.md`。
  - `skills/plan|implement|review|test/SKILL.md` 的推进说明。
  - `README.md` 的 frontmatter / skill routing / CLI 示例。
  - `tests/verify-workflow-contracts.ps1`、`tests/verify-lite-artifact-validator.ps1`、`tests/verify-lite-footprint.ps1`。
- 如果只是让“任务开始即指定工具”更强制，可新增 `scripts/start-task.ps1` 或 `scripts/init-lite-task.ps1`，由脚本创建 PLAN skeleton 并要求 `-Tool` / `-ToolProfileId`；当前没有新任务创建脚本，PLAN 文件创建主要靠 skill 文本纪律。

### 约束 / 风险

- `tests/verify-lite-footprint.ps1:245-248` 明确断言旧 profile 矩阵词（如 `claude-codex-gemini`、`codex-gemini`）不应回归；新增 profile 命名需要避开旧矩阵语义或同步测试意图。
- `scripts/advance-stage.ps1` 和 `scripts/validate-lite-artifacts.ps1` 同时校验 tool；任何 schema 扩展必须双写或抽公共定义，否则容易漂移。
- 当前 `.assistant\工作流\共享记忆协议.md` 仍说 stage / runner 绑定真相源是 `.assistant\orchestration\current-flow.md`，这与 active lite orchestrator 的 `plan.md` 单真相源冲突。要引入 profile，必须先决策是复用 `current-flow` 字段还是继续以 `plan.md` artifact 为主。

## 2. Preset team creation from workflow nodes

### 当前实现

- 当前没有 team creation、spawn、preset、workflow-node 的实际运行时代码。全仓搜索只发现文档/测试中的 legacy `current-flow` 字段和通用 `agent` 文字，没有 team API 或创建脚本。
- workflow 只有线性 stage switch：`PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`。下一阶段在 `scripts/advance-stage.ps1:428-496` 的 `switch ($stage)` 中硬编码。
- orchestrator 的调度是“stage -> skill”文本规则，不是 node graph：`skills/orchestrator/SKILL.md:44-48`。
- old/compat `current-flow` fixture 中已有接近 node binding 的字段：`entry_tool`、`tool_profile_id`、`runner_tool`、`tool_bindings`、`fallback_bindings`，见 `tests/verify-runtime-hooks.ps1:160-179`。但 active orchestrator 明确“不再维护 current-flow”，见 `skills/orchestrator/SKILL.md:40`。
- 共享记忆协议仍按 `entry_tool` 定义单写者模型，见 `.assistant\工作流\共享记忆协议.md` 的“当前入口 host”规则。

### 可能改点

- 需要先定义一个 harness 内部的 workflow node schema。候选落点：
  - `skills/orchestrator/references/state-templates.md`：增加 node / binding 模板。
  - `skills/orchestrator/references/runbook.md`：定义 node 进入、team preset 生成、失败回退流程。
  - `skills/orchestrator/SKILL.md`：把 stage dispatch 改为 `stage -> node -> skill/team preset`。
  - `scripts/advance-stage.ps1`：在推进时写入下一 node 的 binding/mirror，或调用独立 node resolver。
  - `scripts/validate-lite-artifacts.ps1`：校验 node/team preset section 的字段和枚举。
  - `.assistant\运行时\tasks/<task-id>.md` mirror：写入 `entry_tool`、`team_preset_id`、`assigned_members` 等恢复字段。
- 如果只做“预设 team 创建意图”，可以先在 `plan.md` 增加声明式 section，不直接调用外部 team runtime。
- 如果要真的创建团队，当前仓库缺少宿主 API 适配层。需要新增类似 `scripts/invoke-team-preset.ps1` 的边界脚本，避免把 AionUi/team MCP 细节散进 skill 文本。

### 约束 / 风险

- 最大 blocker：仓库内没有 team runtime 或 ACP/team API 契约。只能定义 metadata 和生成意图，无法在本仓内验证“真实创建团队”是否成功。
- 多 agent team 会冲击单写者模型。必须明确 `entry_tool` / leader / teammates 谁能写 `.assistant\运行时\当前任务.md`、谁只能写 `docs/tasks/<task-id>/*` 和 `运行时/tasks/<task-id>.md`。
- current-flow 是潜在复用点，但也是兼容债：hooks、repair、runtime-inbox 还读取它；active orchestrator 又禁止维护它。直接复活 current-flow 会和 lite-footprint 的“简化主线”目标冲突。

## 3. ACP-style skill invocation

### 当前实现

- skill 调用是 Markdown 规则驱动，不是结构化 RPC。`using-superpowers` 要求“相关 skill 必须先调用”，但对非 Claude 环境只写“看平台文档”，见 `skills/using-superpowers/SKILL.md:16-26`。
- orchestrator 只是描述“调用 plan/review/implement/test skill”，并没有统一 invocation payload、result schema 或 call log，见 `skills/orchestrator/SKILL.md:44-48`。
- stage skills 自己写 artifact，没有统一的 `invoke_skill(name, input) -> output` 层：
  - `plan` 写/修 `plan.md`
  - `implement` 改代码并追加 Implementation Notes
  - `review` 追加 review run
  - `test` 写 `test.md`
- Codex 和 Gemini 是已有的脚本化委派例外：
  - `skills/codex/scripts/ask_codex.ps1` 支持 `Workspace`、`File`、`Session`、`Model`、`Reasoning`、`Sandbox`、`ReadOnly`，并输出 `session_id` / `output_path`。
  - `skills/gemini-designer-main/scripts/invoke-gemini.ps1` 支持 `Workspace`、`Prompt`、`OutputFormat`、`ApprovalMode`、`Model`，并返回 JSON。
- Codex skill 配置在 `agent-configs/codex/config.shared.toml.template` 中以 `[[skills.config]]` 注册，但 `enabled = false`，当前更像路径/发现元数据，不是主动服务端调用注册。

### 可能改点

- 建议新增一层 ACP-like adapter，而不是直接重写所有 skill：
  - `scripts/invoke-harness-skill.ps1` 或 `skills/orchestrator/scripts/invoke-skill.ps1`
  - 输入统一字段：`task_id`、`stage`、`skill`、`tool`、`tool_profile_id`、`workspace_root`、`artifact_root`、`mode`、`payload`
  - 输出统一字段：`ok`、`status`、`artifact_paths`、`next_stage_hint`、`handoff`、`errors`
  - 首批只包 `codex` / `gemini` wrapper 和本地 artifact validator，人工 skill 继续保留 Markdown fallback。
- 更新 `skills/orchestrator/SKILL.md` 的调度规则，把“调用 X skill”改为“优先通过 adapter 发起 skill invocation；宿主不支持时 fallback 到当前 Markdown skill 流程”。
- 给 `plan.md` 或 task mirror 增加 invocation trace：
  - 低侵入方式：写在 append-only run 内，如 `- invocation: skill=review mode=manual tool=codex`
  - 强 schema 方式：新增 `## Invocation Log`，但会牵动 validator section 顺序。

### 约束 / 风险

- 当前 skill bodies 是给 LLM 读的操作规程，不是可执行函数；ACP 化若要求自动执行，就必须为每个 skill 定义输入/输出和可执行 adapter。
- `implement` skill 包含真实代码修改，难以无副作用地包装成通用调用；应先从 read-only / bounded side-effect skill 开始，例如 `review`、`test`、`gemini-designer-main`、`codex --read-only`。
- 若新增 skill 或改变 skill set，要同步 `tests/verify-lite-footprint.ps1:167-185` 的 skills 白名单。

## Cross-cutting files to touch later

| Area | Files |
|---|---|
| Workflow docs / prompts | `skills/orchestrator/SKILL.md`, `skills/orchestrator/references/default-tool-profiles.md`, `runbook.md`, `state-templates.md`, `lite-writing-guide.md`, `skills/using-superpowers/SKILL.md`, `skills/plan|implement|review|test/SKILL.md`, `README.md` |
| State transition scripts | `scripts/advance-stage.ps1`, `vault-template/entry/advance-stage.ps1.template` |
| Validation | `scripts/validate-lite-artifacts.ps1`, `vault-template/entry/validate-lite-artifacts.ps1.template` |
| Memory / recovery coupling | `runtime-hooks/claude/posttooluse.js`, `runtime-hooks/claude/stop.js`, `skills/obsidian-memory/scripts/runtime-inbox-common.ps1`, `repair-shared-memory.ps1`, `check-shared-memory.ps1`, `.assistant/工作流/共享记忆协议.md`, `vault-template/工作流/共享记忆协议.md` |
| Installation / distribution | `install.ps1`, `scripts/update-managed-assets.ps1`, `agent-configs/*`, `vault-template/*` |
| Tests | `tests/verify-workflow-contracts.ps1`, `tests/verify-lite-artifact-validator.ps1`, `tests/verify-lite-footprint.ps1`, `tests/verify-runtime-hooks.ps1`, `tests/verify-runtime-inbox.ps1`, `tests/verify-repair-shared-memory.ps1`, `tests/verify-installation.ps1`, `tests/verify-update-managed-assets.ps1` |

## Highest-signal blockers

- 本仓没有 AionUi ACP/team runtime 合约；真实 team 创建和 ACP 调用无法仅靠本仓实现验证。
- `plan.md` 单真相源与 legacy `current-flow.md` 兼容路径并存。tool profile / team preset 最容易落在 current-flow 字段上，但这会逆转 lite 简化方向。
- frontmatter schema 目前是精确四字段。任何直接扩展都会引发 validator、advance-stage、templates、tests、docs 的连锁修改。
- 现有 workflow 没有 task-start 脚本，只有 skill 文本纪律。要让“启动即选择 tool/profile”可验证，需要新增初始化脚本或把 PLAN skeleton 创建纳入可校验 adapter。
- 单写者模型和 team 多 agent 天然冲突，必须先定义 entry host / leader / member 写权限，否则 team preset 会造成 runtime pointer 竞争。
