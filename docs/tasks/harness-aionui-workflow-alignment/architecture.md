# Architecture: Harness ↔ AionUi Workflow Alignment

---
task_id: harness-aionui-workflow-alignment
kind: architecture
status: draft-revised
author: harness-architect
created: 2026-04-24
revised: 2026-04-24
source_repos:
  - D:\data\claude-dev-harness
  - D:\data\AionUi-main
inputs:
  - docs/tasks/harness-aionui-workflow-alignment/plan.md
  - docs/tasks/harness-aionui-workflow-alignment/validation-baseline.md
  - docs/tasks/harness-aionui-workflow-alignment/implementation-surface.md  # from task ee7aec19
---

本文档面向 PLAN 阶段的 TODO 1–3：盘点当前差距、给出目标架构、排出迁移顺序和风险。**不改代码**。

三条对齐主线（按 Leader 指派）：

1. **任务启动即指定工具 / tool profile**
2. **workflow node 预设 team 创建**
3. **skill 调用链路 ACP 化**

---

## 1. 现状盘点

### 1.1 Harness 现状（真相源摘录）

| 维度 | 现状 | 真相源 |
|---|---|---|
| 阶段真相源 | `docs/tasks/<task-id>/plan.md` frontmatter（`task_id / stage / tool / updated`） | `skills/orchestrator/SKILL.md` |
| 工具取值 | `claudecode \| codex \| gemini \| none` | `scripts/advance-stage.ps1:18` (`$ValidTools`) |
| 工具选择时机 | 每次 `advance-stage.ps1 -Tool ...` 由用户显式指定下一阶段 tool；首轮进入 PLAN 前同样由用户显式指定 | `skills/orchestrator/references/default-tool-profiles.md` |
| 工具语义 | "当前 stage 由哪个工具继续"；**不是** profile；**不是** 模型选择；**没有** 绑定 skill 清单或 system prompt | 同上 |
| skill 注册 | `install.ps1` 把 `skills/` junction 到 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills` | `install.ps1` / README.md §安装 |
| skill 调用 | 依赖 Claude Code / Codex 宿主自身的 skill 加载机制；harness 不参与运行时注入 | 各 `skills/**/SKILL.md` |
| 团队概念 | 无。harness-lite 是单 agent 顺序 stage flow（PLAN → PLAN_REVIEW → IMPLEMENT → CODE_REVIEW → TEST → DONE） | `skills/orchestrator/SKILL.md` |
| 状态外化 | `.assistant/运行时/{当前任务,恢复索引,tasks/<id>}.md` 由 `advance-stage.ps1` 单写者重写 | `scripts/advance-stage.ps1:366`+ |

**关键点**：harness 的 `tool` 字段是一个 3 值字符串枚举。它同时承担"谁来跑下一步"和"用什么人格/能力跑"两层语义，但只表达了前者。

### 1.2 AionUi 对应概念（Explore agent 盘点摘录）

| 维度 | AionUi 位置 | 关键结构 |
|---|---|---|
| 后端配置 | `src/common/types/acpTypes.ts`（`AcpBackendConfig`，~180 行 schema） | `id / cliCommand / defaultCliPath / skillsDirs[] / enabledSkills / disabledBuiltinSkills / context`（system prompt） |
| 后端目录 | `ACP_BACKENDS_ALL`（~305–484 行） | 24 个后端；claude、codex、qwen、gemini、copilot、kimi 等 |
| 预设助手 | `src/common/config/presets/assistantPresets.ts`（`AssistantPreset`） | `id / avatar / presetAgentType / ruleFiles / skillFiles / defaultEnabledSkills[] / promptsI18n[]` |
| 会话持久化 | `src/process/services/database/schema.ts` | `conversations.extra` JSON 列存 backend / model / preset-id |
| skill 注册 | per-backend `skillsDirs[]`（例 `.claude/skills`、`.qwen/skills`） | 启动时自动扫描 |
| skill 注入（native） | 由 ACP agent 自行读 `skillsDirs`，harness 侧无需再灌 | — |
| skill 注入（fallback） | `src/process/task/agentUtils.ts::prepareFirstMessageWithSkillsIndex()` | 拼出 skill index + 预设 rule 文本，塞进首条 user message |
| team 数据模型 | `src/common/types/teamTypes.ts::TeamAgent` | `slotId / conversationId / role / agentType / agentName / status / cliPath? / model? / customAgentId?` |
| team 生命周期 | `src/process/team/mcp/team/TeamMcpServer.ts::handleSpawnAgent` | `team_spawn_agent` 为新 slot 分配 conversation，`buildRolePrompt()` 写入首条 prompt |
| team 持久化 | 同一 SQLite schema | `teams / mailbox / team_tasks` 三张表 |
| ACP 协议 | `src/common/types/acpTypes.ts`（JSON-RPC over stdio） | `initialize / available_commands_update / agent_message_chunk / tool_call / session/set_config_option / permission_request` |

**关键点**：AionUi 已经把 harness 里口语化的"tool"拆成了三层：**backend（CLI）** + **preset（rule+skill+prompt 包）** + **model**。它的 team 层是运行时动态 spawn，**没有** 把工作流编码成预设 DAG（harness 这一块反而更完整）。

---

## 2. Gap 分析（按主线）

### 2.1 主线 A：任务启动即指定工具 / tool profile

| # | Gap | harness 当前状态 | AionUi 参照 | 影响 |
|---|---|---|---|---|
| A1 | `tool` 字段不能表达 model | 只存 `claudecode` 三选一 | `AcpBackendConfig.cliCommand` + `AssistantPreset` 里允许携带模型偏好 | 同一 backend 切 Opus/Sonnet/Haiku 无法记录，无法复现 |
| A2 | 不存在 "tool profile" 概念 | 每轮推进都要用户现场决定 tool，且只能从 3 个里选 | `ASSISTANT_PRESETS[]` — 命名的 (backend + rules + skills + prompts) 组合可持久化复用 | 团队里"某类任务固定用某套配置"的共识没落地 |
| A3 | 任务启动阶段无法绑定 "这个任务全程的默认 profile" | `plan.md` frontmatter 只有单个 `tool`，代表当前 stage；没有 task 级的默认 | AionUi 的会话在 create 时就落 backend + preset | 用户必须在每个 stage 边界手动 reselect，认知负担重 |
| A4 | 没有 per-stage 默认矩阵 | `default-tool-profiles.md` 明确写"不再维护固定 profile，也不再根据矩阵推导" | AionUi 没有 stage，但 `AssistantPreset` 相当于每类任务的默认组合 | 非开发者用户不知道 PLAN/REVIEW/TEST 分别选什么 tool 合理 |

> 设计思考：harness 当前"推进时显式指定 tool"其实是 **反矩阵倾向** — 故意保留用户选择权。对齐方向不是取消这点，而是引入**可选的命名 profile**，让熟练用户一键套用、让新用户有默认可依赖。

### 2.2 主线 B：workflow node 预设 team 创建

| # | Gap | harness 当前状态 | AionUi 参照 | 影响 |
|---|---|---|---|---|
| B1 | harness 工作流是单 agent 顺序 | `advance-stage.ps1` 只推一个 frontmatter 字段，没有 spawn 概念 | `team_spawn_agent` 可以创建 N 个 conversation 各自绑定不同 backend/model/role | 无法利用"不同 stage 让不同 agent 并行/独立"的优势 |
| B2 | 不存在 "workflow preset" 对象 | 阶段流只写在 orchestrator skill 文档里，**没有** 机器可读结构 | AionUi 也没有 workflow 预设（但有 `AssistantPreset`） | 双方都缺 — 对齐意味着 harness 这边**先定义**，AionUi 可消费 |
| B3 | 没有 stage → 角色 → profile 的映射 | `tool` 字段只有值没有语义角色 | AionUi 的 team `role` 限 `leader \| teammate`，太粗 | 无法表达"PLAN 阶段 = plan-author 角色，PLAN_REVIEW = plan-reviewer 角色" |
| B4 | 团队通信协议未复用 | harness 没有 team mailbox / task board | AionUi 有 `team_mailbox` / `team_tasks` 表 + `team_*` MCP 工具 | 如果 harness 在 AionUi 下跑 team 模式，没有桥把 stage 推进事件投射到 task board |
| B5 | vault 与 AionUi DB 是两套状态 | `.assistant/运行时/*.md` | `teams / mailbox / team_tasks` SQLite | 需要选一个作为单一真相源，否则 stage 推进和 team state 会漂移 |

### 2.3 主线 C：skill 调用链路 ACP 化

| # | Gap | harness 当前状态 | AionUi 参照 | 影响 |
|---|---|---|---|---|
| C1 | skill 分发依赖宿主 junction | `install.ps1` junction 到 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills` | `AcpBackendConfig.skillsDirs[]` 是每后端显式声明 | 新加一个后端（例 gemini 或 qwen）需要改安装脚本，不是数据 |
| C2 | 没有"非原生 skill 支持"的降级链路 | Gemini 走 `gemini-designer-main` skill；别的后端缺配 | `prepareFirstMessageWithSkillsIndex()` 给不支持 native skill 的后端拼首条消息 | 换后端时 skill 失效的风险没有防护 |
| C3 | 没有 project / user / team 作用域分层 | 只有 user 级（`%USERPROFILE%\.claude\skills`） | AionUi 也只区分 built-in + custom，但 `enabledSkills / disabledBuiltinSkills` 给了每预设的过滤 | 无法表达"本 task 只启用 plan+implement 两个 skill" |
| C4 | 无运行时 skill manifest | stage 推进时不声明当前可用 skill | ACP `available_commands_update` 通知 UI 哪些命令可用 | 外部（例如 AionUi ACP 嵌入 harness）无法得知 harness 任务开放哪些 skill |
| C5 | skill 内容无显式契约 | `SKILL.md` 是 frontmatter + markdown；没有结构化入参/出参 | ACP tool_call 有结构化 payload | harness skill 如果要被 AionUi native tool-call 调用，需要补 schema |

---

## 2.4 Implementation Surface Realities（incorporated from ee7aec19）

实现表面积盘点对本架构带来以下**硬约束**，必须在目标架构里体现：

| # | 约束 | 来源 | 对架构的影响 |
|---|---|---|---|
| S1 | frontmatter schema 是**精确 4 字段**，validator 对集合做严格校验 | `scripts/validate-lite-artifacts.ps1:421-448` | **不能直接往 frontmatter 加字段**。任何加字段方案都会引发 validator/advance-stage/templates/tests/docs 连锁修改 |
| S2 | `tool` 枚举硬编码在三处（advance-stage + validator + docs） | `scripts/advance-stage.ps1:17-18`、`scripts/validate-lite-artifacts.ps1:14-15` | schema 扩展必须双写或抽公共定义，否则漂移 |
| S3 | 已有 opt-in section 先例 | `## Change Contract` | 新增 tool-profile / workflow-binding 语义**应复用 section 形态**，不走 frontmatter |
| S4 | 仓库**没有 task-init 脚本** | skills/plan 文本纪律创建 PLAN | "启动即选 tool/profile" 需要新增初始化脚本才可脚本化验证 |
| S5 | 仓库**没有 team runtime**（无 spawn / mailbox / task API） | 全仓搜索无匹配 | harness 侧只能定义 metadata 和 intent；真实 team 创建必须外接 AionUi 宿主 |
| S6 | 已有真实 RPC-ish 入口：`skills/codex/scripts/ask_codex.ps1`、`skills/gemini-designer-main/scripts/invoke-gemini.ps1` | 两个脚本已有结构化 param/return | **它们是 ACP-adapter 最自然的起点**，不是"新建全套 invoke 层" |
| S7 | legacy fixture 有接近 node-binding 的字段：`entry_tool / tool_profile_id / runner_tool / tool_bindings / fallback_bindings` | `tests/verify-runtime-hooks.ps1:160-179`（current-flow fixture） | **语义可复用，字段名可直接借用**；但承载介质要从 `current-flow.md` 挪到 `plan.md` section |
| S8 | **真相源冲突未解**：`.assistant\工作流\共享记忆协议.md` 说 `current-flow.md` 是真相源，orchestrator 说不再维护 | 两份协议互不兼容 | 在引入 tool-profile 之前必须先决策并收敛；否则新旧两套都要写会爆炸 |
| S9 | **单写者模型**：`.assistant\运行时\当前任务.md` 只允许 `advance-stage` 写 | `共享记忆协议.md` + `scripts/advance-stage.ps1` | team 多 agent 必须先定义 leader/member 写权限，否则 pointer 竞争 |
| S10 | `tests/verify-lite-footprint.ps1:245-248` 显式断言**禁止** `claude-codex-gemini / codex-gemini` 等旧矩阵词回归 | footprint 测试 | profile 命名必须避开历史矩阵术语 |
| S11 | `skill` body 是给 LLM 读的操作规程，不是可执行函数 | 所有 skill `.md` | ACP 化只能先从 **read-only / bounded side-effect skill** 起（review / test / gemini / codex --read-only），`implement` 不能首批包 |
| S12 | skill set 有白名单 | `tests/verify-lite-footprint.ps1:167-185` | 新增或更名 skill 要同步此白名单 |

## 3. 目标架构

> 设计原则：**好用 + 简单**（对齐 `docs/design/eo-inspired-harness-upgrade.md`）。所有新增必须 opt-in，默认行为零变化。
>
> 受 §2.4 约束，本节**放弃**了原草案"直接扩展 frontmatter 加字段"的方案，改为走 **opt-in section + 适配脚本** 的双层组合。

### 3.1 三层语义拆解

把 harness 的 `tool` 字段一层扩成三层，全部 **opt-in**：

```
backend  : CLI 运行时            — claudecode | codex | gemini（现有 tool 枚举）
profile  : 预设组合（可选）       — e.g. "harness-reviewer-codex"
model    : 具体模型（可选）       — e.g. "claude-opus-4-7"
```

**承载介质：`## Workflow Binding` section（opt-in），不是 frontmatter。**

理由：

- frontmatter schema 精确四字段，严格 validator（S1）；扩展会连锁打穿 validator / advance-stage / vault-template / tests / docs。
- `## Change Contract` 已经验证了 "opt-in section + 未启用时删除段" 的模式（S3）。tool-profile 完全可复用。
- 未启用 section 时，validator 跳过检查；现有全部任务零变化。

frontmatter 保持不变：

```yaml
---
task_id: <task-id>
stage: PLAN
tool: claudecode       # 仍然必填；保持 backend 含义
updated: 2026-04-24
---
```

新 opt-in section（字段名直接借用 `current-flow` legacy fixture，见 S7）：

```markdown
## Workflow Binding   (optional, opt-in)
- entry_tool: claudecode                         # 本 task 首 stage backend
- tool_profile_id: harness-default-claude        # 指向 profile YAML 文件名
- model: claude-opus-4-7                         # 可选；覆盖 profile 默认
- tool_bindings:
  - stage: PLAN
    tool: claudecode
    profile: harness-default-claude
  - stage: PLAN_REVIEW
    tool: codex
    profile: harness-reviewer-codex
- fallback_bindings:
  - stage: any
    tool: claudecode
```

validator 规则（opt-in）：

- 段缺失 → 跳过检查（现有行为）
- 段存在：
  - `entry_tool` 必须 ∈ `{claudecode, codex, gemini}`
  - `tool_profile_id` 必须指向已存在的 `agent-configs/profiles/<id>.yaml`
  - `tool_bindings[].stage` 必须 ∈ 合法 stage 枚举 ∪ `{any}`
  - `tool_bindings[].tool` 与 `fallback_bindings[].tool` 同枚举约束
  - `model` 非空时必须匹配 profile 声明的允许列表或为字符串

### 3.2 Tool Profile 描述符

新增目录 `agent-configs/profiles/*.yaml`：

```yaml
# agent-configs/profiles/harness-default-claude.yaml
name: harness-default-claude
backend: claudecode
model: claude-opus-4-7
skills_dirs:                   # 映射 AionUi AcpBackendConfig.skillsDirs
  - .claude/skills
enabled_skills:                # 映射 enabledSkills
  - plan
  - review
  - implement
  - test
  - using-superpowers
disabled_builtin_skills: []
context: |                     # 映射 AcpBackendConfig.context / AssistantPreset.promptsI18n
  你是 harness-lite workflow 的执行者。严格按 plan.md 推进。
```

用途：

- 用户写 `tool_profile: harness-default-claude` 即等价于一次性指定 (backend + model + skills 包 + system prompt)
- 默认内置 3 套：`harness-default-claude` / `harness-default-codex` / `harness-default-gemini`
- 用户可在自己的 workspace 追加 `.assistant/profiles/*.yaml`（项目级覆盖）

### 3.3 Workflow Preset 描述符（Phase 2 本体）

新增 `agent-configs/workflows/harness-lite.yaml`：

```yaml
name: harness-lite
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-claude
    skills_whitelist: [plan, using-superpowers]
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-reviewer-codex
    skills_whitelist: [review]
  IMPLEMENT:
    role: implementer
    default_profile: harness-default-claude
    skills_whitelist: [implement]
  CODE_REVIEW:
    role: code-reviewer
    default_profile: harness-reviewer-codex
    skills_whitelist: [review]
  TEST:
    role: tester
    default_profile: harness-tester-gemini
    skills_whitelist: [test, gemini-designer-main]
```

作用：

- `advance-stage.ps1` 推进到下一 stage 时，若用户未显式 `-Tool`、也未 `-Profile`，查找优先级：
  1. CLI 参数 `-Tool` / `-Profile`（用户显式）
  2. `plan.md ## Workflow Binding.tool_bindings[].stage == next` 命中条目
  3. `plan.md ## Workflow Binding.fallback_bindings[].stage == any` 命中条目
  4. `workflows/harness-lite.yaml.stages.<next>.default_profile`
  5. 都缺 → 沿用当前行为，要求用户必须 `-Tool`
- **关键约束：fallback 只提供"默认来源"，不绕过"非 DONE 必须显式 `-Tool` 的安全阀"。** `-Tool` 可由脚本从上面 2/3/4 自动解出，但必须显式写到 stdout / log 让用户看到；拒绝"推进时无输出默认"。
- `role` 字段为 team 模式预留：AionUi 环境下 `team_spawn_agent` 用 `role + default_profile` 起对应 agent 并用 role-specific prompt 初始化

### 3.4 Team 预设桥（B 主线，可选，AionUi 专用）

新增 skill `workflow-team`（或 orchestrator 下子能力），仅在 AionUi team 上下文里激活：

```
spawnWorkflowTeam(workflow=harness-lite, taskId=<id>)
  → 读 workflows/harness-lite.yaml
  → 对每个 stage 的 role 预留一个 slot
  → 首个 stage 的 slot 立即 team_spawn_agent（backend + model 来自 profile）
  → 后续 slot 在 advance-stage 时 lazy spawn
  → team_task_create 把 stage 作为任务条目
```

单 agent 环境下 `workflow-team` 不激活，harness 退化为现在的行为。

状态单一真相源选择：**harness vault 仍是真相源**，AionUi DB 作为 **镜像**。原因：

- 当前 16 个回归测试基于 vault（`tests/verify-workflow-contracts.ps1` 等）
- vault 格式稳定，SQLite schema 可能随 AionUi 升级变
- 用 vault 喂给 AionUi 的代价是一层可选 adapter；反向改造代价是重写 harness 全部推进脚本

### 3.5 ACP 化 skill 调用（C 主线）

关键修正：**不新建完整 ACP runtime**，而是围绕 **已有的结构化 skill 入口**（`ask_codex.ps1`、`invoke-gemini.ps1`，见 S6）构建一层统一 adapter，其余 skill 保留 Markdown 纪律。

对齐动作按影响面从小到大：

1. **统一 adapter 层（新增 `scripts/invoke-harness-skill.ps1`）**
   - 输入字段统一：`task_id / stage / skill / tool / tool_profile_id / workspace_root / artifact_root / mode / payload`
   - 输出字段统一：`ok / status / artifact_paths / next_stage_hint / handoff / errors`
   - 首批只包 `codex` / `gemini` 已有脚本；其余 skill 暂保留 Markdown fallback（S11）
   - 记录 invocation 到 append-only run：`- invocation: skill=review mode=adapter tool=codex`（低侵入，不碰 section 顺序）

2. **Per-backend skill dirs 显式化**：`install.ps1` 不再硬编码 `.claude/skills` / `.codex/skills`，而是读 profile 里的 `skills_dirs`。新后端只需新 profile，不改脚本。

3. **非原生 skill fallback**：新增 `scripts/generate-skills-index.ps1`，为不支持 native skill 的后端或需要强约束的任务生成 `docs/tasks/<task-id>/skills-index.md`，语义等价于 AionUi `prepareFirstMessageWithSkillsIndex()`。

4. **作用域分层**：skill 解析顺序变成 `task-level (plan.md 声明) → project-level (.assistant/skills/) → user-level (%USERPROFILE%\.claude\skills)`。老任务不声明则沿用 user-level，零影响。

5. **Skill manifest 输出**：`advance-stage.ps1` 推进后可额外写 `.assistant/运行时/skill-manifest.json`，格式对齐 ACP `available_commands_update`，供 AionUi 嵌入时消费。

6. **Skill 结构化契约（后期，延后到 Phase 4+）**：在 `SKILL.md` frontmatter 追加可选 `inputs / outputs` schema，让 harness skill 能作为 AionUi 的 `tool_call` 对象被调用。**不在近期 Phase 范围**。

**绝对避免**：首批就包 `implement` skill — 它包含真实代码修改，副作用重，ACP 化要求先定义输入/输出；先从 read-only/bounded 开始（S11）。

### 3.6 关系图（谁引用谁）

```
plan.md frontmatter
  ├── tool               ── backend 选择（必填，兼容今天）
  ├── tool_profile ?     ── 指向 profile YAML
  ├── model ?            ── 覆盖 profile 内模型
  └── stage

workflow YAML (harness-lite)
  └── stages.<STAGE>.default_profile  ── 指向 profile YAML
  └── stages.<STAGE>.role              ── 供 team 模式使用

profile YAML
  └── skills_dirs / enabled_skills / disabled_builtin_skills / context
      ↑ 与 AionUi AcpBackendConfig 字段一一对应

ACP 嵌入层（可选）
  └── 读 skill-manifest.json → 填 available_commands_update
  └── 读 workflow YAML → team_spawn_agent 起 stage 对应 role
```

---

## 4. 迁移顺序与实施建议

按 **最小爆炸半径** 递增排。**Phase 0 是 Phase 1 的前置 blocker**（源自 S8），不能跳过。

### Phase 0 · 真相源冲突决议（blocker 清理）

**目标**：在引入 `## Workflow Binding` 前，先把 `.assistant\工作流\共享记忆协议.md` 里"`current-flow.md` 是真相源"的表述收敛到"`plan.md` frontmatter 是真相源，`current-flow.md` 不再维护"。

**改动文件**：
- `.assistant\工作流\共享记忆协议.md` + `vault-template\工作流\共享记忆协议.md`
- 验证 `tests/verify-runtime-hooks.ps1` 里 `current-flow` fixture 的语义（允许作为纯 legacy 存在，但 active orchestrator 不读）
- orchestrator SKILL 里删除或更新任何反向引用

**通过条件**：
- 全仓搜索 `current-flow` 后，所有活跃路径都导向 `plan.md`
- hooks / repair / runtime-inbox 只把 `current-flow` 作为"历史 fixture"处理
- 16 个回归测试零回归

**不做**：不删除 `current-flow.md`（向后兼容），只统一真相源声明。

### Phase 1 · Tool Profile 基础（A 主线）

**目标**：`plan.md` 可选 `## Workflow Binding` section；`agent-configs/profiles/*.yaml` 开箱 3 套默认；新增 `scripts/start-task.ps1` 初始化脚本让"启动即选 tool/profile"可脚本化。

**改动文件**（预估）：
- `agent-configs/profiles/{harness-default-claude,harness-default-codex,harness-default-gemini}.yaml` — 新文件
- `scripts/validate-lite-artifacts.ps1` — 新增 `## Workflow Binding` section opt-in 校验（frontmatter **不动**）
- `scripts/advance-stage.ps1` — 解析 `## Workflow Binding` 字段；`-Profile` 入参；读 binding 回显实际 `-Tool`
- `scripts/start-task.ps1` — **新增**（S4）：`-TaskId -Tool [-Profile]` → 建 `plan.md` skeleton + 写 Workflow Binding 段
- `skills/plan/SKILL.md` + `skills/orchestrator/references/state-templates.md` — 示范 Workflow Binding section 模板
- `skills/orchestrator/references/lite-writing-guide.md` — 字段定义
- `README.md` — 更新 CLI 示例
- `tests/verify-tool-profile.ps1` — 新增（2 正例 + 2 反例，段缺失/段存在各一组）

**通过条件**：
- 段缺失的老 plan.md 继续过 validator（opt-in 特性）
- 段存在的新 plan.md 过 validator，且 `advance-stage.ps1 -TaskId x`（不传 `-Tool`）时能从 binding 解出 tool 并在 stdout 显式回显
- 16 个现有 verify 测试零回归
- profile 命名不触发 `verify-lite-footprint.ps1:245` 的旧矩阵词断言（S10）

### Phase 2 · Workflow 描述符（A + B 主线的公共底座）

**目标**：`agent-configs/workflows/harness-lite.yaml` 成为 stage → role → default_profile 映射的单一位置。

**改动文件**：
- `agent-configs/workflows/harness-lite.yaml` — 新文件
- `scripts/advance-stage.ps1` — 未传 `-Profile` 时从 workflow 描述符回退
- `skills/orchestrator/references/runbook.md` — 说明 fallback 顺序
- `tests/verify-workflow-descriptor.ps1` — 新增

**通过条件**：
- 描述符可解析、字段全、无遗漏 stage
- fallback 链路：CLI `-Profile` > frontmatter `tool_profile` > workflow `default_profile` > 用户必填 `-Tool`

### Phase 3 · ACP skill 对齐（C 主线）

**顺序**：
1. 把 `install.ps1` 的 skill dirs 硬编码迁到 profile 读取
2. 加 `scripts/generate-skills-index.ps1`
3. 加 task-level / project-level skill 作用域解析
4. `advance-stage.ps1` 推进后写 `skill-manifest.json`
5. （延后）SKILL.md frontmatter 扩 inputs/outputs

**改动文件**：
- `install.ps1` / `uninstall.ps1`
- `scripts/generate-skills-index.ps1` — 新文件
- `skills/orchestrator/SKILL.md` — 描述 skill-manifest 输出
- `tests/verify-skill-manifest.ps1` — 新增
- `tests/verify-aionui-skill-contract.ps1` — validation-baseline 已列的 gap

**通过条件**：
- 新后端接入仅需新 profile，不改 install.ps1
- `skill-manifest.json` schema 稳定且与 ACP 字段命名对齐

### Phase 4 · Team 预设桥（B 主线，可选，最后）

**前置**：Phase 1 + 2 通过

**目标**：在 AionUi team 环境下，orchestrator 可把 harness-lite workflow 当 team preset spawn。

**改动文件**：
- `skills/workflow-team/SKILL.md` — 新 skill（或归入 orchestrator）
- orchestrator 增加 team-mode 分支
- `tests/verify-team-orchestration.ps1` — 新增（mock team_* 调用）

**通过条件**：
- 单 agent 环境下该 skill 不激活、行为零变化
- AionUi 环境下能把 5 个 stage 映射成 5 个 role 的 team slot

---

## 5. 风险与缓解

| # | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | 直接扩 frontmatter 打穿 validator/advance-stage/vault-template/tests/docs 链路（S1/S2） | ~~中~~ | ~~高~~ | **已通过改走 `## Workflow Binding` section 规避**；opt-in 形态零破坏 |
| R2 | AionUi ACP 协议演进导致 skill-manifest 契约失效 | 中 | 中 | manifest 里携带 `version` 字段；Phase 3 只在 harness 侧写，AionUi 侧作为消费者自负适配 |
| R3 | vault 与 AionUi DB 状态双写漂移 | 高 | 高 | 明确 **vault = 真相源，DB = 镜像**；团队桥走单向 sync（stage 推进 → DB），不反向 |
| R4 | PowerShell 脚本在 AionUi macOS/Linux 构建下不可用 | 中 | 中 | Phase 1–3 不增加新 PS 依赖面；Phase 4 的 team 桥可选走 Node/MCP（复用 AionUi 已有栈） |
| R5 | `advance-stage.ps1` 过度承载职责 | 中 | 中 | 坚持它只管 stage 推进；profile 解析、manifest 生成拆成独立脚本（`start-task.ps1`、`invoke-harness-skill.ps1`） |
| R6 | Profile YAML 变第二个真相源 | 低 | 中 | Profile 只描述**默认**；`plan.md ## Workflow Binding` 是**实际**；validator 两侧一致性检查 |
| R7 | 用户现场指定 tool 的习惯被破坏 | 高 | 低 | 保留"非 DONE 推进必须有 `-Tool`"约束；fallback 只是自动化默认来源，且**必须显式 echo 解出的 tool**（不允许静默推进） |
| R8 | Skill 作用域分层引入歧义 | 中 | 中 | 固定 task > project > user 优先级；冲突时 validator 报错而不是静默覆盖 |
| R9 | legacy `current-flow` 与 `plan.md` 双真相源未决 (S8) | **高** | **高** | **Phase 0 先收敛**；Phase 1 前全仓不能有活跃 `current-flow` 引用 |
| R10 | 单写者模型被 team phase 打破 (S9) | 中 | 高 | Phase 4 前必须定义 leader/member 写权限表；vault 只由 leader 或 advance-stage 写 |
| R11 | ACP adapter 首批把副作用 skill 包进去 | 中 | 高 | 强制 invoke-harness-skill.ps1 首批白名单：`codex --read-only`、`gemini`、`review`、`test`；`implement` 排除到 Phase 4+（S11） |
| R12 | profile 命名触发 footprint 禁词 (S10) | 低 | 中 | 命名不用 "codex-gemini" / "claude-codex-gemini"；用 `harness-*` 前缀并在 Phase 1 测试里固化命名约束 |
| R13 | skill 白名单 (S12) 被 Phase 3 新增 skill 破坏 | 中 | 低 | 不新增 skill 类目，只新增 scripts；若必须新增 skill，同步改 `verify-lite-footprint.ps1:167-185` |

---

## 6. 推荐实施顺序（一页总结）

| 序号 | 阶段 | 主线 | 产出 | 可回退点 |
|---|---|---|---|---|
| 0 | Phase 0 · 真相源收敛 | 底座 | `共享记忆协议.md` 改写 + 全仓 `current-flow` 去活跃化 | 回退 2 份协议文本 |
| 1 | Phase 1 · Tool Profile | A | `## Workflow Binding` section + 3 套 profile YAML + `start-task.ps1` | 删除 profile YAML 与 section 校验；老 plan.md 不受影响 |
| 2 | Phase 2 · Workflow 描述符 | A + B 底座 | `harness-lite.yaml` + advance-stage fallback 链 | 删除 YAML；advance-stage 回到"必须 `-Tool`" |
| 3 | Phase 3 · ACP skill 对齐 | C | `invoke-harness-skill.ps1` + skill 作用域分层 + manifest 写入 | 保留 skill junction 作为兜底；adapter 仅用于 read-only skill |
| 4 | Phase 4 · Team 预设桥 | B | `workflow-team` skill + 单写者权限表 + team MCP 消费 workflow YAML | 单 agent 环境不激活；可整 phase 搁置 |

**不建议一次性捆绑实施** — 每个 Phase 自带验收标准和独立回归 PR，失败时可定点回退，不影响其他已落地部分。

## 6.1 Cross-cutting file surface（源自 ee7aec19 §Cross-cutting）

| Area | Files |
|---|---|
| Workflow docs / prompts | `skills/orchestrator/SKILL.md`, `skills/orchestrator/references/{default-tool-profiles,runbook,state-templates,lite-writing-guide}.md`, `skills/using-superpowers/SKILL.md`, `skills/{plan,implement,review,test}/SKILL.md`, `README.md` |
| State transition scripts | `scripts/advance-stage.ps1`, `vault-template/entry/advance-stage.ps1.template`, **新增** `scripts/start-task.ps1` |
| Validation | `scripts/validate-lite-artifacts.ps1`, `vault-template/entry/validate-lite-artifacts.ps1.template` |
| Memory / recovery coupling | `runtime-hooks/claude/{posttooluse,stop}.js`, `skills/obsidian-memory/scripts/runtime-inbox-common.ps1`, `repair-shared-memory.ps1`, `check-shared-memory.ps1`, `.assistant/工作流/共享记忆协议.md`, `vault-template/工作流/共享记忆协议.md` |
| Installation / distribution | `install.ps1`, `scripts/update-managed-assets.ps1`, `agent-configs/*`, `vault-template/*` |
| Tests | `tests/verify-workflow-contracts.ps1`, `tests/verify-lite-artifact-validator.ps1`, `tests/verify-lite-footprint.ps1`, `tests/verify-runtime-hooks.ps1`, `tests/verify-runtime-inbox.ps1`, `tests/verify-repair-shared-memory.ps1`, `tests/verify-installation.ps1`, `tests/verify-update-managed-assets.ps1`, **新增** `tests/verify-tool-profile.ps1`、`verify-workflow-descriptor.ps1`、`verify-skill-manifest.ps1` |

---

## 7. 未决点（等用户裁决）

1. **Profile 命名空间**：`harness-default-claude` 还是 `harness-lite.plan` 这种 scope 前缀？影响 Phase 1 的 YAML 结构。**需避开 footprint 禁词**（S10）。
2. **`tool` 字段去留**：frontmatter 保留 `tool` + section 里重写一遍有冗余风险。建议**保留** frontmatter `tool` 作为 backend 级真相源，validator 强制 `tool == Workflow Binding.entry_tool`（或至少该 stage 的 binding 条目）。
3. **Model 粒度**：`model:` 字段是写完整 ID（`claude-opus-4-7`）还是 alias（`opus`）？对齐 AionUi 建议完整 ID。
4. **Team 模式状态真相源**：vault 单向推送到 AionUi DB 是否够用？或是否需要反向订阅？本次建议先单向。
5. **Phase 3 skill 结构化契约**：`inputs / outputs` schema 是跟 ACP tool_call 对齐，还是自定义？建议跟 ACP 对齐以便未来直通。
6. **Phase 0 的 `current-flow` 处理力度**：只改协议文本 vs 同步废弃 hooks 对它的解析逻辑？本次建议只改协议，不碰 hooks（最小爆炸半径）。
7. **`start-task.ps1` 的纪律强度**：是"可选工具脚本"还是"唯一 PLAN 创建入口"？后者需要把 skill 文档里"手建 plan.md"的路径一起改，工作量更大。本次建议**可选**。

---

## 8. 相关引用

- Harness 真相源：`skills/orchestrator/SKILL.md`、`scripts/advance-stage.ps1`、`skills/orchestrator/references/default-tool-profiles.md`
- Harness 上一次架构决策：`docs/design/eo-inspired-harness-upgrade.md`
- AionUi backend schema：`src/common/types/acpTypes.ts`（`AcpBackendConfig`, `ACP_BACKENDS_ALL`）
- AionUi assistant preset：`src/common/config/presets/assistantPresets.ts`
- AionUi team MCP：`src/process/team/mcp/team/TeamMcpServer.ts`、`src/common/types/teamTypes.ts`
- AionUi skill fallback：`src/process/task/agentUtils.ts::prepareFirstMessageWithSkillsIndex`
- AionUi 持久化：`src/process/services/database/schema.ts`（`conversations / teams / mailbox / team_tasks`）

---

（本文档为 PLAN 阶段架构产物，不包含代码改动；实施请按 §4 Phase 拆成独立 lite workflow 任务逐个推进。）
