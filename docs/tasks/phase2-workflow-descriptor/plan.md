---
task_id: phase2-workflow-descriptor
stage: PLAN
tool: claudecode
updated: 2026-04-24
---
# Phase 2 · Workflow Descriptor

本任务是 `docs/tasks/harness-aionui-workflow-alignment/architecture.md` §4 Phase 2 的独立 lite 推进。只做 workflow 描述符和 fallback 链；**不做** team preset bridge（Phase 4），**不做** ACP tool-call schema（Phase 3+ 后期）。

**Revision Note (PLAN Review Run 1 → revise)**：Run 1 给出 5 条 P1/P2，本轮在 Clarification / Plan / Verification / Risks 全段重写以闭环。五点决策：

1. **放弃 `## Workflow Binding` 与 `start-task.ps1` 依赖**。Phase 1 实际落地的是 frontmatter `tool_profile` / `model`（见 `scripts/advance-stage.ps1:9-11`、`scripts/validate-lite-artifacts.ps1` 对应分支），并**没有** `## Workflow Binding` section，也**没有** `scripts/start-task.ps1`。本 Phase 的 fallback 链剔除 plan-binding / plan-fallback 两级。
2. **不新增 profile**。描述符 `default_profile` 全部只引用 Phase 1 已落地的三个：`harness-default-claude` / `harness-default-codex` / `harness-default-gemini`。不引用 `harness-reviewer-codex` / `harness-tester-gemini`。
3. **描述符校验改为 advisory**。`advance-stage.ps1:637` 的 `Invoke-LiteArtifactValidator` 在 tool 解析前执行；若把描述符校验设为 fatal，会阻塞"显式 `-Tool` + 坏描述符"路径。决策：描述符 audit **只输出警告**到 stdout 的 `Warnings:` 段（新增），**不加入 `Errors:` 段**，退出码保持 0。`Resolve-FallbackTool` 内部再做一次 try/catch，YAML 坏或字段缺时静默跳过 workflow-default 级，退到抛错级。
4. **CLI 兼容边界收窄到三个分支**。Phase 1 的 `-Profile` 已是 `-Tool` 的伴侣参数（见 `scripts/advance-stage.ps1:9`、`709-713`）。Phase 2 只保留下面三种兼容口径：`cli-profile`（`-Tool` 空、`-Profile` 非空）沿用 Phase 1 的 profile/model 语义；`cli-tool` 且显式带 `-Profile` 和/或 `-Model` 时沿用 Phase 1 语义与 mismatch 拒绝；**纯 `cli-tool`**（`-Tool` 非空、且未传 `-Profile` / `-Model`）是本 Phase 新增的 clearing path，下一 stage 必须清空继承的 `tool_profile` / `model`。显式回归：`-Tool codex -Profile harness-default-codex`（一致）通过，`-Tool claudecode -Profile harness-default-codex`（不一致）沿用 Phase 1 拒绝行为。
5. **stdout 契约不破**。`verify-workflow-contracts.ps1:391 / 531` 和 `verify-tool-profile.ps1:339` 对 `PLAN_REVIEW | codex` / `DONE | none` 做 exact string 比对。决策：`resolved tool=<x> via <source>` 写到 **stderr**（`[Console]::Error.WriteLine`），stdout 只保留 `$nextStage | $nextTool`。既有断言不动，新测试捕获 stderr 验证解析路径。

**Revision Note (PLAN Review Run 2 → revise · 2026-04-24)**：Leader 裁定 Phase 2 采用 **non-sticky** 语义——当前 stage 的 frontmatter `tool_profile` 只是"本 stage 已分配到的 profile"的记录性元数据，**不**参与下一 stage 的解析。对应调整：

- Fallback 链从 4 级降为 **3 级**：`cli-tool → cli-profile → workflow-default → throw`。原第 3 级 `frontmatter-profile` **整体移除**（在下一 stage 解析链中）。
- `current-stage.tool_profile` 不作任何 fallback 来源；它只作为 Phase 1 已有的"本 stage 选定 profile"记录，不对下一 stage 产生黏性。
- 显式新增冲突解决测试（见 TODO 5 新增 F1）：当前 PLAN 有 `tool_profile: harness-default-claude`、描述符 `PLAN_REVIEW.default_profile: harness-default-codex`、CLI 零参数，**必须** 解析为 `codex` 并 `via workflow-default`，**不** 解析为 `claudecode`。
- `-Tool` / `-Profile` CLI 优先级不变（第 1、2 级语义不动）。
- `Resolve-FallbackTool` 签名去掉 `-CurrentToolProfile` 参数；`source ∈ {cli-tool, cli-profile, workflow-default, none}`（`frontmatter-profile` 从 source 枚举移除）。

**Leader Follow-up (post Run 3 · 2026-04-24)**：non-sticky 语义进一步明确到**写回契约**，而不只是在 tool 解析链上非黏性：

- 当 `source = workflow-default` 时，下一 stage 的 writeback **必须**把 `tool_profile` 写成描述符 `stages.<next>.default_profile`，并把 `model` 写成该 profile 描述符里的 `model`；当前 stage 的 `ExistingProfile` / `ExistingModel` **完全不复用**
- 当 `source = cli-tool` 且 CLI **未**传 `-Profile` / `-Model` 时，下一 stage writeback **必须清空** `tool_profile` / `model`，避免当前 stage 的旧元数据残留
- 当 `source = cli-profile` 时，继续沿用 Phase 1 的 profile/model 写回语义；当用户显式传 `-Tool ... -Profile ...` 时，matching 通过 / mismatch 拒绝也继续沿用 Phase 1
- 回归矩阵按仓库真实状态修正：当前 repo 有 **18** 个既有 `tests/verify-*.ps1`；新增 `tests/verify-workflow-descriptor.ps1` 后，Phase 2 全量 verify 套件应为 **19**

## Clarification

- 验收标准:
  - 新增 `agent-configs/workflows/harness-lite.yaml`，含 5 个可执行 stage（`PLAN / PLAN_REVIEW / IMPLEMENT / CODE_REVIEW / TEST`）的 `role + default_profile + skills_whitelist` 映射；`DONE` 仅作终态，不是 stage 条目；`default_profile` 只允许引用 Phase 1 已落地的三个 profile 文件（`harness-default-claude` / `harness-default-codex` / `harness-default-gemini`）
  - `scripts/advance-stage.ps1` 的 tool 解析变成 **3 级链（non-sticky）**（编号按解析优先级）：
    1. CLI `-Tool`（显式传入；解析优先级延续 Phase 1。其 writeback 再细分为"纯 `cli-tool` clearing path"与"`cli-tool` + 显式 `-Profile`/`-Model` 兼容路径"）
    2. CLI `-Profile`（Phase 1 伴侣参数；新增"`-Tool` 空时按 `profile.backend` 填充 `$Tool` 再复用 `Resolve-AssignedTool`"兼容扩展）
    3. `agent-configs/workflows/harness-lite.yaml.stages.<next>.default_profile` → 读该 profile 的 `backend` 作 tool
    - 三级全缺 → 沿用 Phase 1 抛错："Advancing to {stage} requires -Tool (claudecode \| codex \| gemini)."
    - **non-sticky 关键守则**：当前 stage 的 frontmatter `tool_profile` 不参与下一 stage 解析；它只是 Phase 1 "本 stage 已分配 profile" 的元数据记录，不在 fallback 链内
  - Phase 2 明确**下一 stage writeback 规则**（与 tool 解析分开定义）：
    - `source = workflow-default` → 下一 stage frontmatter / task mirror **必须写入** `tool_profile = default_profile` 与 `model = <default_profile.model>`；当前 stage `ExistingProfile` / `ExistingModel` 不得复用
    - `source = cli-tool` 且 CLI 未传 `-Profile` / `-Model` → 下一 stage frontmatter / task mirror **必须清空** `tool_profile` / `model`
    - `source = cli-profile` → 保持 Phase 1 既有语义：写入 CLI 选择的 profile；若 CLI 未传 `-Model`，则沿用该 profile 描述符默认 model
    - `source = cli-tool` 且 CLI 同时显式传 `-Profile` / `-Model` → 保持 Phase 1 既有语义与校验，尤其是 `tool == profile.backend` mismatch 仍拒绝
  - 解析路径只输出到 **stderr**（`[Console]::Error.WriteLine("resolved tool=<x> via <source>")`）；stdout 最末行严格保留现有契约 `<stage> | <tool>`，不破坏 `verify-workflow-contracts.ps1:391/531`、`verify-tool-profile.ps1:339` 的 exact-string 断言
  - 三种 CLI 兼容口径（关键验收）：
    - `cli-profile`：`-Tool` 空且 `-Profile` 非空时，解析 `profile.backend` 作为 tool，profile/model 写回继续沿用 Phase 1
    - `cli-tool` + 显式 `-Profile` 和/或 `-Model`：继续沿用 Phase 1 语义与校验，含 `tool == profile.backend` mismatch 拒绝
    - 纯 `cli-tool`：`-Tool` 非空且未传 `-Profile` / `-Model` 时，作为本 Phase 新增 clearing path，下一 stage 必须清空 `tool_profile` / `model`
  - 冲突场景决议（关键验收）：当前 PLAN 有 `tool_profile: harness-default-claude`，描述符 `PLAN_REVIEW.default_profile: harness-default-codex`，CLI 不传 `-Tool`/`-Profile`，推进结果**必须**是 `PLAN_REVIEW | codex`（via workflow-default），**不可**是 `claudecode`
  - 冲突场景写回决议（关键验收）：上述 workflow-default 场景推进后，下一 stage `plan.md` 与 task mirror **必须**写入 `tool_profile: harness-default-codex` 与该 profile 的默认 `model`；当前 stage 的 `harness-default-claude` / 旧 model 不得留存
  - 显式 cli-tool 清理决议（关键验收）：当前 stage 即使已有 `tool_profile` / `model`，只要用户用 `-Tool <next>` 推进且未传 `-Profile` / `-Model`，下一 stage `plan.md` 与 task mirror 都必须**不再**保留旧的 `tool_profile` / `model`
  - `scripts/validate-lite-artifacts.ps1` 新增 workflow 描述符 **advisory audit** 分支：描述符缺失 → 跳过；描述符存在但字段非法 → 仅写入新的 `Warnings:` 段、**不** 加入 `Errors:`、退出码保持 0。这保证即使 `advance-stage.ps1:637` 在 tool 解析前跑 validator，损坏的描述符也不阻塞显式 `-Tool` 的正常推进
  - `Resolve-FallbackTool`（`advance-stage.ps1` 内部函数）在 workflow-default 级解析时单独 try/catch YAML 异常与字段缺失，安静降级；advisory warning 只由 validator 发出，运行时函数不重复告警
  - 新增 `tests/verify-workflow-descriptor.ps1` 覆盖点见 §Verification
  - Phase 2 回归矩阵按真实仓库数执行：**18** 个既有 `tests/verify-*.ps1` 零回归；新增 `tests/verify-workflow-descriptor.ps1` 后，全量 verify 套件总数为 **19**

- 非目标:
  - 不实现 team preset spawn（Phase 4 任务）
  - 不实现 ACP tool-call schema（Phase 3+ 后期）
  - 不修改 frontmatter schema；不引入 `## Workflow Binding` section；**不依赖** `scripts/start-task.ps1`（Phase 1 未落地）
  - 不新增 stage，不改 `advance-stage.ps1` 的 stage switch 顺序
  - 不新增 profile；只消费 Phase 1 的三个已落地 profile
  - 不迁移 `implement` 等副作用 skill 到 adapter（Phase 3 再议）
  - 不处理 `current-flow.md` 真相源冲突（Phase 0 范围）
  - 不改 stdout 既有 `<stage> | <tool>` 行契约；不修改既有测试的 exact-string 断言
  - **当前 stage frontmatter `tool_profile` 不参与下一 stage 解析**（non-sticky 语义）；它只是"本 stage 已选定 profile"的元数据，不是下一 stage 的 fallback 来源
  - **当前 stage `ExistingProfile` / `ExistingModel` 不得在 `workflow-default` 或"纯 `cli-tool`（无 `-Profile`/`-Model`）"路径中被复用到下一 stage writeback**
  - 不对 Phase 1 `tool_profile` 字段的含义或 validator 校验做任何改动；它在 Phase 1 的"本 stage 活跃 profile"角色保持不变

- 受影响目录:
  - `agent-configs/workflows/` — 新增目录与 `harness-lite.yaml`
  - `scripts/advance-stage.ps1` — 新增 `Resolve-FallbackTool`；`Resolve-AssignedTool` 前置扩展（`-Tool` 空 → 依次试 `-Profile` / 描述符 workflow-default；**non-sticky：不读取当前 stage frontmatter `tool_profile`**）；stderr 回显；**不动** stdout 契约；同步调整 `Resolve-ProfileSelection`/写回分支以落实 "`workflow-default` 写 descriptor profile/model" 与 "`cli-tool` 无 profile/model 时清空元数据" 两条契约
  - `scripts/validate-lite-artifacts.ps1` — 新增 `Warnings:` 输出段（若无警告则 `- none`）+ workflow descriptor advisory audit；`Errors:` 行为不变
  - `skills/orchestrator/SKILL.md` + `skills/orchestrator/references/{runbook,state-templates,default-tool-profiles,lite-writing-guide}.md` — 描述 fallback 三级顺序（non-sticky）、advisory audit 语义、stderr 回显约定
  - `vault-template/entry/advance-stage.ps1.template` — 若 Phase 1 shim 已透传 `-Profile`（实际已有），本 Phase 不动；否则同步追加
  - `README.md` — 补 CLI 示例（描述符 + `-Profile` 路径各一）
  - `tests/` — 新增 `verify-workflow-descriptor.ps1`；**不修改** `verify-workflow-contracts.ps1`、`verify-tool-profile.ps1` 等既有契约测试

- 回滚策略:
  - Phase 2 完全 additive：删除 `harness-lite.yaml` + 撤回 `advance-stage.ps1` 的 `Resolve-FallbackTool` + 撤回 validator 的 Warnings 段与 audit 分支 + 撤回新测试 → 回到 Phase 1 末态
  - 单点失败隔离：描述符缺失 → validator 跳过、fallback 跳过；描述符字段非法 → validator 写警告、fallback 跳到抛错级，**既有显式 `-Tool` 路径始终不受影响**
  - Phase 1 的 frontmatter `tool_profile` / `model` 字段与本 Phase 的 fallback 链**完全解耦**（non-sticky）；即使本 Phase 回退，Phase 1 契约仍完整；即使本 Phase 保留，Phase 1 的 `tool_profile` 写入路径也不被读作下一 stage 的来源。额外要求：若仅显式 `-Tool` 推进，不允许旧 stage 的 profile/model 残留到下一 stage

- ui: not-applicable

## User Confirmation
- status: confirmed
- note: 用户消息 "继续" 视为进入 Phase 2 规划的批准（依据 Leader 2026-04-24 指派）；确认范围仅限 Phase 2 本身，不含 Phase 3/4 的进一步授权

## Change Contract
- change_type: feature
- affected_paths:
  - agent-configs/workflows/harness-lite.yaml
  - scripts/advance-stage.ps1
  - scripts/validate-lite-artifacts.ps1
  - skills/orchestrator/SKILL.md
  - skills/orchestrator/references/runbook.md
  - skills/orchestrator/references/state-templates.md
  - skills/orchestrator/references/default-tool-profiles.md
  - skills/orchestrator/references/lite-writing-guide.md
  - README.md
  - tests/verify-workflow-descriptor.ps1

## Plan

- TODO 1 · 描述符 schema 定稿（仅消费 Phase 1 已有 profile）
  - 在 `skills/orchestrator/references/state-templates.md` 增加 "Workflow Descriptor" 小节，给出 `harness-lite.yaml` 的最小模板：
    ```yaml
    name: harness-lite
    version: 1
    stages:
      PLAN:
        role: plan-author
        default_profile: harness-default-claude
        skills_whitelist: [plan, using-superpowers]
      PLAN_REVIEW:
        role: plan-reviewer
        default_profile: harness-default-codex
        skills_whitelist: [review]
      IMPLEMENT:
        role: implementer
        default_profile: harness-default-claude
        skills_whitelist: [implement]
      CODE_REVIEW:
        role: code-reviewer
        default_profile: harness-default-codex
        skills_whitelist: [review]
      TEST:
        role: tester
        default_profile: harness-default-gemini
        skills_whitelist: [test, gemini-designer-main]
    ```
  - 字段强约束：`version` 必填；`role` kebab-case；`default_profile` 必须指向实际存在的 `agent-configs/profiles/<id>.yaml`；`skills_whitelist` 每项必须在 `tests/verify-lite-footprint.ps1` 既有 skill 白名单内
  - **不** 引入 `harness-reviewer-codex` / `harness-tester-gemini` 等不存在的 profile（如果未来需要按角色细分，归 Phase 3/4）

- TODO 2 · 文件落地
  - 新建 `agent-configs/workflows/harness-lite.yaml`，内容严格等价于 TODO 1 模板
  - UTF-8 无 BOM（YAML 约定；与 `.ps1` 的 BOM 要求分开）

- TODO 3 · `advance-stage.ps1` 解析与 writeback 扩展（按三种 CLI 分支收窄兼容边界，不破坏 exact-output，non-sticky）
  - 新增内部函数 `Resolve-FallbackTool -NextStage <string> -CliTool <string> -CliProfile <string> -RepoRoot <path>`
  - **签名明确不含 `-CurrentToolProfile` / `-PlanText`**：当前 stage 的 frontmatter `tool_profile` 不作为参数也不被读取；函数只看 CLI + 描述符两类来源
  - 返回对象 `{ tool, source, workflow_profile, workflow_model }`，`source ∈ {cli-tool, cli-profile, workflow-default, none}`（`frontmatter-profile` 不在枚举内）；其中 `workflow_profile/workflow_model` 只在 `source='workflow-default'` 时填值
  - 解析顺序严格为：`cli-tool → cli-profile → workflow-default`；三级全缺 → 返回 `{tool='', source='none'}`
  - 每一级解析都 try/catch：YAML 坏、文件缺、backend 字段缺 → 跳到下一级
  - 调用位置：`Resolve-AssignedTool` 之前；把解析出的 tool 作为 `$Tool` 喂给 `Resolve-AssignedTool`；若 `source == 'none'` 则沿用现有 `Resolve-AssignedTool` 抛错路径（文案保留 `"Advancing to {0} requires -Tool"`）
  - **三种 CLI 兼容口径（关键）**：
    - `cli-profile`：`-Tool` 空 + `-Profile` 非空 → 读 `agent-configs/profiles/<Profile>.yaml.backend` 作为 tool，`source='cli-profile'`；随后进入 Phase 1 的 profile/model 写回分支
    - `cli-tool` + 显式 `-Profile` 和/或 `-Model`：`-Tool` 非空且至少显式传了 `-Profile` / `-Model` 之一 → 保持 Phase 1 既有 `Resolve-ProfileSelection` 语义与 mismatch 拒绝
    - 纯 `cli-tool`：`-Tool` 非空且未传 `-Profile` / `-Model` → 作为本 Phase 新增 clearing path；tool 解析保持显式 CLI 优先，但下一 stage writeback 清空 `tool_profile` / `model`
    - `-Tool` 空 + `-Profile` 空 → 直接试描述符 `workflow-default`（**跳过 frontmatter `tool_profile`**）
  - 新增/改写 `Resolve-ProfileSelection`（或等价 helper）的**分支表**，明确下一 stage profile/model writeback：
    - `Stage = DONE` → 保持 Phase 1 现有清空行为
    - `source = workflow-default` → **忽略**当前 stage `ExistingProfile` / `ExistingModel`；直接写 `{ Profile = workflow.default_profile, Model = workflow.default_profile.model }`
    - `source = cli-tool` 且 CLI **未传** `-Profile` / `-Model` → **忽略**当前 stage `ExistingProfile` / `ExistingModel`；直接写 `{ Profile = '', Model = '' }`
    - `source = cli-profile` → 保持 Phase 1 既有写回：写选中的 CLI profile；若 CLI 未传 `-Model`，则写该 profile 描述符默认 model
    - `source = cli-tool` 且 CLI 显式传了 `-Profile` 和/或 `-Model` → 保持 Phase 1 既有语义与 mismatch 校验，尤其是 `tool == profile.backend` 不一致仍拒绝
  - `Update-Frontmatter`、task mirror、`当前任务.md` 三处 writeback 统一消费上述分支结果；不得在后续写回环节重新读回当前 stage 的 `ExistingProfile` / `ExistingModel`
  - stderr 回显：在 `Resolve-FallbackTool` 返回前调用 `[Console]::Error.WriteLine("resolved tool=$tool via $source")`；**不写 stdout**；stdout 最末行保持 `"$nextStage | $nextTool"` 不变
  - **non-sticky 回归断言**：即使 `$planText` 中存在 `tool_profile: <X>` / `model: <Y>`，`Resolve-FallbackTool` 的行为与这些字段无关，且 writeback 也不得复用它们；TODO 5 组 B/F 专项验证

- TODO 4 · `validate-lite-artifacts.ps1` advisory audit
  - 在现有输出末尾（`Errors:` 段后）新增 `Warnings:` 段，**始终输出**（无警告时写 `- none`），保证脚本契约稳定可被解析
  - 新增 workflow descriptor audit 分支：
    - 描述符不存在 → 不写 warning，不写 error，跳过
    - 描述符存在但 YAML 非法 / 字段缺 / `default_profile` 指向不存在的 profile / `skills_whitelist` 含非白名单 skill → 写入 Warnings（不加 Errors）
  - 退出码规则不变：有 Errors 才非零；Warnings 不影响 exit code
  - `Invoke-LiteArtifactValidator`（`advance-stage.ps1:45+`）的既有 Errors 解析逻辑不变；`advance-stage.ps1:637` 的 gate 行为等价于今天

- TODO 5 · 测试 `tests/verify-workflow-descriptor.ps1`
  - 组 A（advisory audit）
    - A1 正例：描述符合法 → validator 0，Warnings 段写 `- none`
    - A2 反例（advisory）：缺 `version` → validator **仍 exit 0**，Warnings 段列该问题
    - A3 反例（advisory）：`default_profile: does-not-exist` → validator 0 + Warnings 列出
    - A4 反例（advisory）：`skills_whitelist: [bogus-skill]` → validator 0 + Warnings 列出
    - A5 描述符缺失 → validator 0 + Warnings 段 `- none`
  - 组 B（fallback 三级）
    - B1 `cli-tool`：当前 stage 预置 `tool_profile: harness-default-claude` 与 `model: claude-opus-4-7`；显式传 `-Tool codex`、不传 `-Profile` / `-Model` → stderr 含 `resolved tool=codex via cli-tool`；stdout 最末行 `<next> | codex`；下一 stage `plan.md` / task mirror **都不得再含**旧的 `tool_profile` / `model`
    - B2 `cli-profile`：传 `-Profile harness-default-codex`（无 `-Tool`）→ stderr `via cli-profile`；stdout 末行仍 `<next> | codex`
    - B3 `workflow-default`：CLI 零参数，plan.md **无** `tool_profile`，描述符给 `PLAN_REVIEW.default_profile: harness-default-codex` → stderr `via workflow-default`
    - B4 三级全缺 → `advance-stage.ps1` 抛 `"requires -Tool"`（退出非零）
    - **不再有 `via frontmatter-profile` 的正例测试**（该 source 已移除）
  - 组 C（Phase 1 `-Profile` 兼容回归）
    - C1：`-Tool codex -Profile harness-default-codex`（一致）→ 通过，行为与 Phase 1 完全相同
    - C2：`-Tool claudecode -Profile harness-default-codex`（不一致）→ 拒绝（复用 Phase 1 mismatch 校验）
  - 组 D（显式 Tool + 坏描述符 回归）
    - D1：描述符字段非法，但 `-Tool codex` 显式传入 → `advance-stage.ps1` 成功推进；validator Warnings 提及描述符问题，不影响推进
  - 组 E（stdout 契约保证）
    - E1 断言：`advance-stage.ps1` stdout **最末行**严格等于 `"<stage> | <tool>"`；`resolved tool=... via ...` 不出现在 stdout
  - 组 F（non-sticky 关键冲突——Leader Run 2 指定验收）
    - **F1 冲突决议（必须）**：构造当前 stage=PLAN、frontmatter `tool_profile: harness-default-claude`、`model: claude-opus-4-7`；描述符 `PLAN_REVIEW.default_profile: harness-default-codex`；不传 `-Tool` / `-Profile`；调用 `advance-stage.ps1 -TaskId <fixture>`。断言至少六条：(a) stdout 最末行严格等于 `"PLAN_REVIEW | codex"`；(b) stderr 包含 `resolved tool=codex via workflow-default`；(c) stderr **不**包含 `via frontmatter-profile` 或 `via cli-*`；(d) 下一 stage `plan.md` frontmatter 写入 `tool_profile: harness-default-codex`；(e) 下一 stage `plan.md` frontmatter 写入 `model: gpt-5.5/xhigh`；(f) task mirror 同步写入 `tool_profile/model` 与 `assigned_tool_profile/assigned_model` 为 `harness-default-codex / gpt-5.5/xhigh`。该测试锁定"当前 stage `tool_profile` 对下一 stage 无黏性"以及"`workflow-default` 会把 descriptor profile/model 写回下一 stage"两条核心契约
    - F2 变体：同上场景但当前 stage 改为 `tool_profile: harness-default-gemini`、`model: gemini-2.5-pro`（另一种 mismatch）→ 结果仍为 `codex`（via workflow-default），且下一 stage 写回仍是 `harness-default-codex / gpt-5.5/xhigh`；证明 F1 不是巧合、与旧 frontmatter 值无关
    - F3 逆向：移除描述符的 `default_profile` 字段、保留当前 stage frontmatter `tool_profile: harness-default-codex`、`model: gpt-5.5/xhigh`、CLI 零参数 → `advance-stage.ps1` 抛 `"requires -Tool"`（**不**因当前 stage `tool_profile` 存在就成功推进）；证明 `frontmatter-profile` 确已从 fallback 链移除，且旧 `ExistingProfile` / `ExistingModel` 不能替代 workflow-default
  - 测试遵循 `verify-lite-footprint.ps1` 对 PS 脚本的通用约束（UTF-8 BOM、`.ps1` 后缀、位置在 `tests/`）

- TODO 6 · 文档更新
  - `skills/orchestrator/references/runbook.md`：§3 Advance 小节写 fallback **三级**顺序（cli-tool → cli-profile → workflow-default）、**non-sticky 明确声明**（当前 stage `tool_profile` 不参与下一 stage 解析）+ stderr 回显约定
  - `skills/orchestrator/references/default-tool-profiles.md`：补"描述符作为最后兜底默认来源，不构成真相源"一段；**显式说明** `tool_profile` 字段是"本 stage 选定 profile"的活跃状态记录、**不跨 stage 黏性传递**
  - `skills/orchestrator/references/lite-writing-guide.md`：补 workflow 描述符位置、字段与 opt-in 语义；加 FAQ "为什么我的 `tool_profile: harness-default-claude` 没有影响下一 stage"
  - `skills/orchestrator/references/state-templates.md`：TODO 1 已覆盖
  - `skills/orchestrator/SKILL.md`：§调度规则追加一行指向描述符，并标注 non-sticky
  - `README.md`：在推进示例后加两条 CLI 示例（`-Profile` 省略 `-Tool`；配好描述符省略两者）；加一句 FAQ 注明 non-sticky 行为

- TODO 7 · 既有测试回归验证（**不修改**既有测试源文件）
  - 跑 `tests/verify-workflow-contracts.ps1`、`tests/verify-tool-profile.ps1`、`tests/verify-lite-artifact-validator.ps1`、`tests/verify-lite-footprint.ps1`
  - 任一非零 exit → 本 Phase 回到 IMPLEMENT 调整（优先回查 `Resolve-FallbackTool` 是否误把新逻辑写进 stdout，或 `Warnings:` 段破坏既有 validator 输出解析）
  - 手工 smoke：三条推进路径（cli-tool / cli-profile / workflow-default）各跑一次，肉眼核对 stderr 与 stdout 分流正确
  - `verify-installation.ps1` **不纳入 blanket loop**；它是单独的安装校验步骤，前提是 `$env:HARNESS_INSTALLED_WORKSPACE` 指向一个已完成 `install.ps1` 的 installed workspace fixture，并且 fixture 内已生成 `.assistant\entry\AGENTS.md` / `.assistant\entry\advance-stage.ps1` 等安装产物
  - review 前最终门槛：先完成上述参数化安装校验，再执行 Verification 里的 **18** 脚本 blanket loop；显式要求仓库内 `tests/verify-*.ps1` 总数为 **19**（18 现有 + 1 新增），其中 `verify-installation.ps1` 单列，其余 **18** 个脚本顺跑全绿

## Verification

- `pwsh -File .\tests\verify-workflow-descriptor.ps1`
- `pwsh -File .\tests\verify-workflow-contracts.ps1`
- `pwsh -File .\tests\verify-lite-artifact-validator.ps1`
- `pwsh -File .\tests\verify-lite-footprint.ps1`
- `pwsh -File .\tests\verify-tool-profile.ps1`
- `pwsh -NoProfile -Command "$repo = (Get-Location).Path; $workspace = $env:HARNESS_INSTALLED_WORKSPACE; if ([string]::IsNullOrWhiteSpace($workspace)) { throw 'Set HARNESS_INSTALLED_WORKSPACE to an installed workspace fixture path before running verify-installation.ps1.' }; if (-not (Test-Path (Join-Path $workspace '.assistant\entry\AGENTS.md'))) { throw \"installed workspace fixture missing entry shims: $workspace\" }; & pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-installation.ps1 -WorkspaceRoot $workspace -RepoRoot $repo; exit $LASTEXITCODE"`
- `pwsh -File .\scripts\advance-stage.ps1 -TaskId <smoke> -RepoRoot <path>`
- `pwsh -NoProfile -Command "$scripts = Get-ChildItem .\tests -Filter 'verify-*.ps1' | Sort-Object Name; if ($scripts.Count -ne 19) { throw \"expected 19 verify scripts after adding verify-workflow-descriptor.ps1, got $($scripts.Count)\" }; $loopScripts = $scripts | Where-Object { $_.Name -ne 'verify-installation.ps1' }; if ($loopScripts.Count -ne 18) { throw \"expected 18 directly runnable verify scripts in blanket loop, got $($loopScripts.Count)\" }; foreach ($script in $loopScripts) { & pwsh -NoProfile -ExecutionPolicy Bypass -File $script.FullName; if ($LASTEXITCODE -ne 0) { throw \"verify script failed: $($script.Name) (exit $LASTEXITCODE)\" } }"`

覆盖意图：
- 新 `verify-workflow-descriptor.ps1` **六个**测试组一次跑完：
  - A · advisory audit（5 case）
  - B · fallback **三级** + `cli-tool` 清理陈旧 profile/model（4 case，不再有 `via frontmatter-profile`）
  - C · Phase 1 `-Profile` 兼容回归（2 case）
  - D · 显式 `-Tool` + 坏描述符 回归（1 case）
  - E · stdout 契约（1 case）
  - F · **non-sticky 冲突决议（Run 2/Run 3 Leader 指定）**（3 case）——其中 F1 同时锁定 workflow-default 解析结果与 writeback 产物状态
- `verify-workflow-contracts.ps1` 既有 exact-string 断言（如 `PLAN_REVIEW | codex` / `DONE | none`）在 stderr 回显引入后仍绿，证明 stdout 契约未破
- `verify-lite-artifact-validator.ps1` 在 `Warnings:` 段引入后继续通过；验证新 advisory 分支不改变 `Errors:` / 退出码的既有断言
- `verify-tool-profile.ps1` 证实 Phase 1 `-Tool + -Profile` 一致/不一致的两路断言零回归（对应新测试组 C）；并间接验证 `tool_profile` 字段写入路径未被本 Phase 篡改
- `verify-lite-footprint.ps1` 的 skill / 命名白名单与 `.ps1` BOM 断言对新脚本与描述符仍绿
- Smoke 手工跑三条推进路径（cli-tool / cli-profile / workflow-default）+ 一次 F1 场景肉眼确认：stdout 最末行严格 `<stage> | <tool>`、`resolved tool=... via ...` 只出现在 stderr、当前 stage frontmatter `tool_profile` 不影响下一 stage 解析，而 workflow-default 会把 descriptor 的 profile/model 写回到下一 stage
- 当前 repo **18** 个既有 `tests/verify-*.ps1` + 新增 `tests/verify-workflow-descriptor.ps1` 组成 **19** 脚本全量套件；其中 `verify-installation.ps1` 单独对 `$env:HARNESS_INSTALLED_WORKSPACE` 指向的 installed workspace fixture 执行，**不** 纳入 blanket loop；full-suite gate 只对子进程逐个执行其余 **18** 个可直接运行的脚本，避免 `exit` 提前终止父会话并避免把 repo root 误当安装产物目录

## Risks

- **non-sticky 语义实现漂移**（Run 2/3 新增 R0，最高优先级）：实现者若在 `Resolve-FallbackTool` 内复用 Phase 1 `tool_profile` 字段作为 fallback 来源，或在 writeback 阶段继续沿用当前 stage `ExistingProfile` / `ExistingModel`，将违反 Leader 裁定的 non-sticky 契约、导致 F1 冲突测试失败并污染下游 stage tool/profile/model 选择。缓解：(a) `Resolve-FallbackTool` 签名物理不含 `-CurrentToolProfile` / `-PlanText` 参数，从 API 层面杜绝读取；(b) `Resolve-ProfileSelection`（或等价 helper）显式分支化 `workflow-default` 写 descriptor profile/model、`cli-tool` 无 profile/model 时清空元数据；(c) TODO 5 组 F 三个测试 case + 组 B1 的 cli-tool 清理 case 共同锁死；(d) 文档 TODO 6 在三处文件（runbook / default-tool-profiles / lite-writing-guide）显式声明 non-sticky
- **advisory 误判为 fatal**：若实现时把描述符 audit 错误写入 `Errors:` 段（而不是新 `Warnings:` 段），`advance-stage.ps1:637` 的 validator gate 会在 tool 解析之前阻塞显式 `-Tool` 的推进，破坏 Phase 1 契约。缓解：TODO 5 组 D 专项测试（`-Tool codex` + 坏描述符 → 推进成功）；实现时 advisory 分支写入只触碰 `$warnings` 数组，`$errors` 数组分支保持完全不变
- **stderr / stdout 流串扰**：`resolved tool=... via ...` 误落到 stdout 将破坏 `verify-workflow-contracts.ps1:391/531` 与 `verify-tool-profile.ps1:339` 的 exact-string 比对。缓解：TODO 3 强制使用 `[Console]::Error.WriteLine`（而非 `Write-Host` / `Write-Warning`，两者在某些 PSHost 下会被重定向到 stdout）；TODO 5 组 E 断言 stdout 最末行严格匹配 `<stage> | <tool>`
- **CLI 兼容边界实现漂移**：若实现时把所有非空 `-Tool` 路径都当成"Phase 1 一字不动"，就会与纯 `cli-tool` clearing path 冲突；若反过来把带显式 `-Profile` / `-Model` 的 `cli-tool` 也改写成 clearing path，又会破坏 Phase 1 mismatch 拒绝。缓解：TODO 3 将三种 CLI 分支拆开定义；TODO 5 用 B1 锁定纯 `cli-tool` clearing path，用 C1/C2 锁定 `cli-profile` 与 `cli-tool` + 显式 `-Profile` 的 Phase 1 兼容行为
- **`Warnings:` 段输出破坏既有 validator 解析**：`verify-lite-artifact-validator.ps1` 既有断言可能依赖 `Errors:` 段的精确位置或 stdout 行数。缓解：实现前读一遍 `verify-lite-artifact-validator.ps1` 断言，确认 `Warnings:` 作为新尾段追加（不插在中间）；若既有测试用 `-match 'Errors:'` 这类松断言则风险为零
- **回归矩阵继续数错或只跑子集**：若继续沿用"16 个既有 verify"这类旧口径，或仍使用单会话 `foreach { & script }` 这种会被 `exit` 提前打断、或把 repo root 误传给 `verify-installation.ps1 -WorkspaceRoot` 的命令，review 前的真实回归覆盖面会不清楚。缓解：Verification 固定写明"18 现有 + 1 新增 = 19"，并把 `verify-installation.ps1` 拆成"前置条件明确的参数化安装校验步骤"，blanket loop 只 count-check 并子进程逐个执行其余 18 个直接可运行脚本
- **YAML 解析器依赖**：PowerShell 7 无内置 YAML 解析器。候选：(a) `ConvertFrom-Yaml`（PowerShell-Yaml 模块，默认不安装）；(b) 轻量自写解析（描述符结构简单：顶层 `name/version/stages`，stage 下 3 字段）。缓解：选 (b) 自写解析以消除环境依赖；选型决定落到 Implementation Notes 第一条
- **profile 命名触发 `verify-lite-footprint.ps1` 禁词**（S10）：描述符 `default_profile` 引用的 id 若含 `codex-gemini` 等旧矩阵词会被 footprint 测试拒绝。缓解：只引用 Phase 1 已存在的 `harness-default-*` 三个；footprint 测试对这三个已知放行
- **`advance-stage.ps1` 复杂度膨胀**（R5）：原脚本已 500+ 行，新增 `Resolve-FallbackTool` 会进一步增长。缓解：把 3 级解析拆成独立私有函数；必要时把 YAML 解析再拆到 `scripts/resolve-workflow-descriptor.ps1`（不对外暴露 CLI，仅 dot-source）
- **vault-template shim 漂移**：若 `vault-template/entry/advance-stage.ps1.template` 未与主脚本同步 fallback 逻辑，workspace 端会行为分叉。缓解：Phase 1 的 shim 已透传 `-Profile` / `-Model`，本 Phase 仅在真的需要时改 template；`tests/verify-update-managed-assets.ps1` 会在主脚本与 template diff 超阈值时报警

## Plan Review

### Run 1 · 2026-04-24 13:49 · runner: harness-reviewer
- verdict: revise
- findings:
  - P1: `docs/tasks/phase2-workflow-descriptor/plan.md:24` treats `## Workflow Binding` and `scripts/start-task.ps1` as Phase 1 outputs, but the validated Phase 1 state only shipped optional `tool_profile` / `model`, `agent-configs/profiles/*.yaml`, validator support, and `advance-stage.ps1` profile/model handling; `scripts/start-task.ps1` is absent. The fallback chain levels 2/3 and TODO 8 therefore depend on functionality this task does not define or own. Revise the plan to either make `## Workflow Binding` schema/validator/tests a Phase 2 deliverable, or remove plan-binding fallback from Phase 2.
  - P1: The descriptor template references `harness-reviewer-codex` and `harness-tester-gemini` at `docs/tasks/phase2-workflow-descriptor/plan.md:79`, `docs/tasks/phase2-workflow-descriptor/plan.md:87`, and `docs/tasks/phase2-workflow-descriptor/plan.md:91`, but Phase 1 currently has only `harness-default-claude.yaml`, `harness-default-codex.yaml`, and `harness-default-gemini.yaml`. Because the plan also requires `default_profile` to point to actual Phase 1 profile files (`docs/tasks/phase2-workflow-descriptor/plan.md:94`), implementing the template literally would fail the new validator. Replace the template with existing profiles or add creation/testing of the missing profiles to scope and affected paths.
  - P1: Validator opt-in and rollback semantics conflict. The plan says invalid workflow descriptor audits return nonzero (`docs/tasks/phase2-workflow-descriptor/plan.md:113`-`docs/tasks/phase2-workflow-descriptor/plan.md:118`), while rollback/risk text says descriptor damage should not drag down advancement and should fall back to explicit `-Tool` (`docs/tasks/phase2-workflow-descriptor/plan.md:45`, `docs/tasks/phase2-workflow-descriptor/plan.md:153`). Current `advance-stage.ps1` runs `Invoke-LiteArtifactValidator` before resolving the next tool (`scripts/advance-stage.ps1:637`), so a malformed descriptor would block even explicit `-Tool` advancement before the fallback code can skip it. Decide whether descriptor validation is fatal or advisory, and add tests for explicit `-Tool` with a broken descriptor.
  - P1: `-Profile` semantics conflict with the already-validated Phase 1 contract. Phase 1 already has `-Profile` / `-Model` parameters (`scripts/advance-stage.ps1:9`, `scripts/advance-stage.ps1:11`) and uses them after `Resolve-AssignedTool` to validate/write profile and model (`scripts/advance-stage.ps1:709`-`scripts/advance-stage.ps1:713`); `-Profile` does not currently replace `-Tool`. The Phase 2 plan says to add `-Profile` and use it to derive `tool` when `-Tool` is empty (`docs/tasks/phase2-workflow-descriptor/plan.md:107`-`docs/tasks/phase2-workflow-descriptor/plan.md:111`). Revise this as an explicit compatible extension, and require regression tests that existing `-Tool codex -Profile harness-default-codex` behavior and mismatch rejection still pass.
  - P2: The proposed stdout line will break existing exact-output tests unless they are updated, but the plan says not to modify existing workflow contract tests (`docs/tasks/phase2-workflow-descriptor/plan.md:41`). Current tests compare exact strings such as `PLAN_REVIEW | codex` and `DONE | none` (`tests/verify-workflow-contracts.ps1:391`, `tests/verify-workflow-contracts.ps1:531`) and Phase 1 tool-profile test compares exact `PLAN_REVIEW | codex` (`tests/verify-tool-profile.ps1:339`). Either change output to preserve the existing final/primary line contract and update assertions deliberately, or make TODO 6 include the required modifications to existing tests.
- next: Revise the plan before IMPLEMENT; do not advance until Phase 1 assumptions, fatal/advisory validator behavior, `-Profile` compatibility, and stdout/test contracts are made internally consistent.

### Run 2 · 2026-04-24 14:02 · runner: harness-reviewer
- verdict: revise
- findings:
  - P1: The five Run 1 findings are materially addressed, but the revised fallback chain still has an unresolved Phase 1 semantics conflict: it resolves frontmatter `tool_profile` before the workflow descriptor default (`docs/tasks/phase2-workflow-descriptor/plan.md:26`-`docs/tasks/phase2-workflow-descriptor/plan.md:27`, `docs/tasks/phase2-workflow-descriptor/plan.md:117`-`docs/tasks/phase2-workflow-descriptor/plan.md:126`, `docs/tasks/phase2-workflow-descriptor/plan.md:146`-`docs/tasks/phase2-workflow-descriptor/plan.md:147`). Phase 1 treats `tool_profile` as the current assigned profile that must match current `tool`, not as a task-wide next-stage binding (`README.md:57`-`README.md:66`, `scripts/advance-stage.ps1:618`, `scripts/advance-stage.ps1:710`, `tests/verify-tool-profile.ps1:322`-`tests/verify-tool-profile.ps1:330`). With the planned order, a PLAN currently using `tool_profile: harness-default-claude` would advance to PLAN_REVIEW as `claudecode` via `frontmatter-profile`, bypassing the descriptor's `PLAN_REVIEW.default_profile: harness-default-codex` (`docs/tasks/phase2-workflow-descriptor/plan.md:92`-`docs/tasks/phase2-workflow-descriptor/plan.md:94`). B3/B4 do not cover this conflicting-profile case, so descriptor stage defaults would be unreliable for any profiled current task unless that stickiness is explicitly intended.
- open questions / assumptions:
  - Assumption: Phase 2 workflow descriptors are intended to provide next-stage defaults when there is no CLI override, including when the current stage had a Phase 1 `tool_profile`.
  - If `tool_profile` stickiness is intended instead, document that workflow descriptors cannot override an existing frontmatter profile and add an explicit conflicting-profile acceptance test.
- change summary:
  - Run 1 items 1/2/3/4/5 are otherwise closed: unsupported `## Workflow Binding` / `scripts/start-task.ps1` assumptions are removed, descriptor profiles are limited to the three existing Phase 1 profiles, descriptor audit is advisory rather than fatal, `-Profile` is framed as a compatible extension, and resolved-tool diagnostics are routed to stderr while preserving exact stdout contracts.
- next: Revise fallback precedence and the test matrix before IMPLEMENT.

### Run 3 · 2026-04-24 14:17 · runner: harness-reviewer
- verdict: revise
- findings:
  - P1: The fallback chain is now non-sticky on paper, but the plan still leaves Phase 1 profile/model carry-forward semantics unchanged (`docs/tasks/phase2-workflow-descriptor/plan.md:16`, `docs/tasks/phase2-workflow-descriptor/plan.md:59`, `docs/tasks/phase2-workflow-descriptor/plan.md:135`-`docs/tasks/phase2-workflow-descriptor/plan.md:136`). Current `Resolve-ProfileSelection` reuses `ExistingProfile` and `ExistingModel` whenever CLI `-Profile` / `-Model` are absent, then rejects backend mismatches (`scripts/advance-stage.ps1:388`-`scripts/advance-stage.ps1:402`). That means the required F1 non-sticky scenario (`docs/tasks/phase2-workflow-descriptor/plan.md:170`-`docs/tasks/phase2-workflow-descriptor/plan.md:172`) still cannot succeed as written: after `workflow-default` resolves `codex`, the existing `tool_profile: harness-default-claude` would be reapplied and fail exactly like the current Phase 1 regression case (`tests/verify-tool-profile.ps1:322`-`tests/verify-tool-profile.ps1:327`). Even if the old profile were cleared ad hoc, the old `model` would still leak unless the plan also defines model writeback behavior. Revise TODO 3/5 to specify what happens on `workflow-default` transitions with no CLI profile: either clear inherited profile/model, or explicitly write the descriptor `default_profile` and its model into next-stage frontmatter/task mirror, and assert that artifact state in F1/F2.
  - P2: The regression matrix still has wording drift and is not operationalized. The plan claims `16 个既有 verify-*.ps1 + Phase 1 产出 tests/verify-tool-profile.ps1 零回归` and `全部 16 个既有 verify-*.ps1 顺跑零回归` (`docs/tasks/phase2-workflow-descriptor/plan.md:43`, `docs/tasks/phase2-workflow-descriptor/plan.md:210`), but the current repo contains 18 `tests/verify-*.ps1` scripts. The executable verification list only names five existing regressions plus the new Phase 2 script (`docs/tasks/phase2-workflow-descriptor/plan.md:184`, `docs/tasks/phase2-workflow-descriptor/plan.md:190`-`docs/tasks/phase2-workflow-descriptor/plan.md:194`), so the claimed full-suite regression surface is still ambiguous. Either narrow the claim to the named subset, or replace it with a concrete "run all `tests/verify-*.ps1`" step and correct the count.
- open questions / assumptions:
  - Assumption: non-sticky applies to next-stage `tool_profile` / `model` writeback as well as tool resolution when the source is `workflow-default`.
  - The plan still needs to choose one explicit artifact contract for descriptor-driven advances: next-stage frontmatter/mirror stays blank for profile/model, or it is populated from `default_profile`.
- change summary:
  - Run 2's source-order fix is correct: `frontmatter-profile` is removed from the fallback chain, validator behavior remains advisory, `-Profile` stays a compatible extension, and stdout/stderr contracts remain internally consistent.
- next: Revise non-sticky writeback semantics and the regression command list before entering IMPLEMENT.

### Run 4 · 2026-04-24 14:31 · runner: harness-reviewer
- verdict: revise
- findings:
  - P1: Run 3's writeback gap is now addressed, but the plan is still internally contradictory about explicit `-Tool` behavior. Multiple sections still say `-Tool` non-empty remains Phase 1 behavior "completely unchanged" / "一字不动" (`docs/tasks/phase2-workflow-descriptor/plan.md:16`, `docs/tasks/phase2-workflow-descriptor/plan.md:39`, `docs/tasks/phase2-workflow-descriptor/plan.md:50`, `docs/tasks/phase2-workflow-descriptor/plan.md:150`), while the new writeback contract and tests require the pure `cli-tool` path with no `-Profile` / `-Model` to clear inherited `tool_profile` / `model` and succeed (`docs/tasks/phase2-workflow-descriptor/plan.md:30`, `docs/tasks/phase2-workflow-descriptor/plan.md:46`, `docs/tasks/phase2-workflow-descriptor/plan.md:53`, `docs/tasks/phase2-workflow-descriptor/plan.md:156`, `docs/tasks/phase2-workflow-descriptor/plan.md:179`). Those cannot both be true because current Phase 1 logic reuses `ExistingProfile` / `ExistingModel` and rejects the existing-profile mismatch case (`scripts/advance-stage.ps1:388`-`scripts/advance-stage.ps1:402`, `tests/verify-tool-profile.ps1:322`-`tests/verify-tool-profile.ps1:327`). Revise the compatibility wording so only `cli-profile` and `cli-tool` with explicit `-Profile` / `-Model` keep Phase 1 semantics, while pure `cli-tool` is explicitly documented as a new Phase 2 writeback rule.
  - P2: The verification plan is count-correct now, but the new dynamic full-suite command still is not executable as written. The final gate loops over `tests/verify-*.ps1` inside one `pwsh -Command` session (`docs/tasks/phase2-workflow-descriptor/plan.md:219`), but the verify scripts themselves terminate PowerShell with `exit 0` / `exit 1` (`tests/verify-tool-profile.ps1:369`, `tests/verify-tool-profile.ps1:376`, `tests/verify-lite-artifact-validator.ps1:470`, `tests/verify-lite-artifact-validator.ps1:477`). In PowerShell that exits the enclosing session, so the loop stops on the first script instead of running all 19. Replace the final gate with a parent loop that launches each script in a fresh `pwsh -File` subprocess and checks `$LASTEXITCODE`, or add a dedicated suite-runner script.
- open questions / assumptions:
  - Assumption: the intended Phase 1 compatibility boundary is "`-Tool` plus explicit `-Profile` / `-Model` stays unchanged", not "every non-empty `-Tool` path stays unchanged".
  - Assumption: the review gate must actually execute all 19 verify scripts rather than relying on a single-session loop that is interrupted by `exit`.
- change summary:
  - Run 3's two requested fixes are materially present: the plan now specifies descriptor-driven writeback for `workflow-default`, explicit metadata clearing for pure `cli-tool`, concrete artifact assertions for F1/F2, corrected `18 + 1 = 19` wording, and a full-suite verification intent.
- next: Narrow the Phase 1 compatibility wording and replace the dynamic gate with a subprocess-based full-suite command before entering IMPLEMENT.

### Run 5 · 2026-04-24 14:35 · runner: harness-reviewer
- verdict: revise
- findings:
  - P1: Run 4's two targeted issues are materially addressed: the CLI compatibility boundary is now narrowed to the three intended cases, and the full-suite gate now uses subprocess-per-script execution. The remaining blocker is that the gate still assumes every `verify-*.ps1` can be invoked as `pwsh -File <script>` with no additional arguments (`docs/tasks/phase2-workflow-descriptor/plan.md:213`, `docs/tasks/phase2-workflow-descriptor/plan.md:223`), but `tests/verify-installation.ps1` still requires mandatory `-WorkspaceRoot` and fails immediately without it (`tests/verify-installation.ps1:3`-`tests/verify-installation.ps1:4`; reproduced by running `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-installation.ps1`, which returns “missing mandatory parameters: WorkspaceRoot”). So the new "19-script full suite" command is still not executable against the current repo contract. Revise the final gate to either exclude parameterized verify scripts from the blanket loop and keep them as separately parameterized commands, or provide the required arguments/workspace fixture for `verify-installation.ps1` within the suite command.
- open questions / assumptions:
  - Assumption: the final review gate is intended to be copy-pastable and runnable exactly as written, not a conceptual placeholder.
  - If `verify-installation.ps1` is meant to stay inside the 19-script blanket run, the plan needs to define which workspace fixture/path is passed to its mandatory `-WorkspaceRoot`.
- change summary:
  - Run 4's specific findings are otherwise resolved: the plan now cleanly separates `cli-profile`, `cli-tool` with explicit `-Profile` / `-Model`, and pure `cli-tool` clearing semantics, and it correctly moved away from the single-session `foreach { & script }` pattern that `exit` would terminate early.
- next: Make the full-suite verification gate executable for parameterized verify scripts before entering IMPLEMENT.

### Run 6 · 2026-04-24 14:46 · runner: harness-reviewer
- verdict: revise
- findings:
  - P1: The CLI compatibility contract is now internally consistent and correctly narrowed to the requested three-way split: `cli-profile`, `cli-tool + explicit -Profile and/or -Model`, and pure `cli-tool` as the Phase 2 clearing path (`docs/tasks/phase2-workflow-descriptor/plan.md:16`, `docs/tasks/phase2-workflow-descriptor/plan.md:50`-`docs/tasks/phase2-workflow-descriptor/plan.md:53`, `docs/tasks/phase2-workflow-descriptor/plan.md:152`-`docs/tasks/phase2-workflow-descriptor/plan.md:155`). The remaining issue in this review scope is the full-suite gate: its 19-total / 18-blanket-loop counting is now self-consistent (`docs/tasks/phase2-workflow-descriptor/plan.md:213`, `docs/tasks/phase2-workflow-descriptor/plan.md:224`, `docs/tasks/phase2-workflow-descriptor/plan.md:239`), and `verify-installation.ps1` is correctly split out with explicit parameters, but the command still passes `-WorkspaceRoot $repo -RepoRoot $repo` (`docs/tasks/phase2-workflow-descriptor/plan.md:224`). `tests/verify-installation.ps1` validates an installed workspace rooted at `WorkspaceRoot`, and running it against the harness repo root fails with missing workspace-managed artifacts such as `.assistant\entry\AGENTS.md`, `.assistant\entry\advance-stage.ps1`, and related installation state (`tests/verify-installation.ps1:318`-`tests/verify-installation.ps1:330`; reproduced by `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-installation.ps1 -WorkspaceRoot $PWD -RepoRoot $PWD`, which returns `STATUS: FAIL`). So the final full-suite command is still not executable as written; it needs a real installed workspace fixture/path for `verify-installation.ps1`.
- next: Replace `$repo` with a provisioned workspace root in the parameterized `verify-installation.ps1` step before entering IMPLEMENT.

### Run 7 · 2026-04-24 14:55 · runner: harness-reviewer
- verdict: pass
- findings:
  - none. In this round's scoped item, the `verify-installation.ps1` handling is now described as a genuinely executable plan: it is explicitly excluded from the blanket loop, requires `$env:HARNESS_INSTALLED_WORKSPACE` to point to an installed workspace fixture, checks that fixture before invocation, and keeps the `19 total / 18 blanket-loop` counting logic internally consistent (`docs/tasks/phase2-workflow-descriptor/plan.md:213`-`docs/tasks/phase2-workflow-descriptor/plan.md:225`). That now matches the script's real contract that `-WorkspaceRoot` is mandatory and that the target must be an installed workspace carrying managed `.assistant\entry\...` artifacts, rather than the repo root (`tests/verify-installation.ps1:3`-`tests/verify-installation.ps1:5`, `tests/verify-installation.ps1:318`-`tests/verify-installation.ps1:330`).
- next: Scoped item closed; no remaining issue in this review round.

## Implementation Notes

## Code Review
