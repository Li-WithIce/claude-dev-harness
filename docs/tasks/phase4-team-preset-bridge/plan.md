---
task_id: phase4-team-preset-bridge
stage: PLAN
tool: claudecode
updated: 2026-04-25
---
# Phase 4 · Team Preset Bridge

本任务是 `docs/tasks/harness-aionui-workflow-alignment/architecture.md` §4 Phase 4（B 主线）的独立 lite 推进。前置假设 Phase 1（`tool_profile` / `model` + 三个 `harness-default-*` profile + `-Profile` / `-Model` CLI）、Phase 2（`agent-configs/workflows/harness-lite.yaml` + `Resolve-FallbackTool` + validator `Warnings:` 段）、Phase 3（`scripts/invoke-harness-skill.ps1` + per-task `skill-manifest.json` + skills-index + invocation trace 合约）均已落地。**不做** `294bf604`（`verify-update-managed-assets` 回归，独立后续任务），**不重新打开** install/uninstall 改造（Phase 3 Run 1 修订 A 已封口）、`current-flow.md` 真相源问题（Phase 0 范围）、Phase 3 adapter 合约（已闭环）。

**Leader 裁定结果（2026-04-25，Q1–Q8 全部闭环）**：

- **Q1 · 桥接组织形式** → **选 (a) 新独立 skill `skills/workflow-team/SKILL.md`**，仅在 team 模式激活。理由：与 orchestrator 解耦，避免 Phase 1-3 已稳定的 orchestrator skill 继续做成巨型 skill；S12（skill 白名单）同步加入 `verify-lite-footprint.ps1`。
- **Q2 · 团队预设输出形式** → **选 (b) 派生脚本 `scripts/export-team-preset.ps1`**。理由：唯一真相源仍是 `harness-lite.yaml` + profiles，避免 preset 与 workflow descriptor 漂移（R-DRIFT 直接消除静态文件易漂移分支）；不落 `agent-configs/team-presets/*.yaml` 静态文件。
- **Q3 · Leader/Member 写权限表的强制方式** → **选 (b) 静态测试拦截 + 文档**。理由：扩 `tests/verify-team-orchestration.ps1` 静态校验 "member 不得直接写入 `docs/tasks/<id>/plan.md`"；runtime hook 拦截留到后续阶段，不在本 Phase 扩 scope。
- **Q4 · Cross-platform 实现矩阵** → **选 (a) PowerShell-only（pwsh 7+）**。理由：harness 已经 PS-only，pwsh 7 在 macOS/Linux 可用；R4 缓解维持现行；不做双端 Node CLI 实现。
- **Q5 · 反向 sync（team_task_update → vault）的处理** → **选 (a) 仅文档化禁止**。理由：与 R3（vault = 真相源、DB = 镜像）一致；本 Phase 不加 validator/runtime 检测，反向 sync 拦截属后续阶段范围。
- **Q6 · Team mode 探测信号** → **选 (b) 显式 env opt-in `AIONUI_TEAM_MODE=1`**。理由：显式 opt-in 默认安全；MCP 在场但 env 未设时**必须不激活**（O6 case 锁死）；R-OPT 缓解最直接。
- **Q7 · Role prompt 起源** → **选 (b) 新增 `agent-configs/role-prompts/<role>.md` × 5**。理由：role 与 profile 解耦，不挤进 profile.context；未来扩 workflow（如 spec-only flow）只加新 role-prompt 文件即可；S10 footprint 禁词已校对（命名小写连字符，与既有 profile 命名风格同构）。
- **Q8 · Leader（编排者）是否计入 spawn role** → **选 (a) Leader 不参与 spawn**。理由：与 architecture §4 Phase 4 "把 5 个 stage 映射成 5 个 role 的 team slot" 一致；5 stage = 5 spawn slot；Leader 即 advance-stage 的发起者，不另起 conversation。

## Clarification

- 验收标准:
  - 新增 `scripts/export-team-preset.ps1`（Q2(b) 派生脚本）：参数 `-Workflow / -Output / [-Format yaml|json]`；读 `agent-configs/workflows/<workflow>.yaml` + 各 profile YAML，输出 AionUi `team_spawn_agent` 兼容 preset：`{name, version:1, members:[{role, backend, model, skills_whitelist, role_prompt_ref}], single_writer:{owner:'leader', members_read_only_path_prefixes:['.assistant/','docs/tasks/<task-id>/']}}`（**目录级前缀**，不再列单文件名，与 `docs/team-write-authority.md` / role-prompt Authority / O5 静态拦截共享同一组前缀）
  - 新增 `skills/workflow-team/SKILL.md`（Q1(a) 独立 skill）：描述 (1) leader 调用 `spawn-team.ps1` 起 5 role 的步骤；(2) 失败回退到单 agent 流程 + stderr 诊断；(3) 单写者权限表引用。**本 SKILL.md 是文档面**；team-mode opt-in 的可执行强制点位于 `spawn-team.ps1`
  - 新增 `agent-configs/role-prompts/<role>.md` × 5（Q7(b)）：`plan-author` / `plan-reviewer` / `implementer` / `code-reviewer` / `tester` 各一份；内容是 spawn 时 `team_spawn_agent` 的 system prompt seed；Authority 段使用同一组目录级前缀（`.assistant/` + `docs/tasks/<task-id>/`）描述 member 只读面
  - 扩展 `skills/orchestrator/SKILL.md`：§调度规则增**文档分支**说明 "若 `$env:AIONUI_TEAM_MODE='1'`（Q6(b)），leader 可调用 `skills/workflow-team/scripts/spawn-team.ps1`；否则维持单 agent 流程零变化"。**本 Phase 不新增 orchestrator 端真正读 env 的可执行 dispatcher**；team-mode 可执行强制只在 `spawn-team.ps1` 内
  - 新增 `docs/team-write-authority.md`：列 leader / member 写入面表，统一使用目录级前缀（`.assistant/` + `docs/tasks/<task-id>/`）描述 member 只读面、leader 唯一写入身份
  - 新增 `tests/verify-team-preset.ps1`：preset schema + 与 `harness-lite.yaml` 一致性 + role_prompts 完整性 + `members_read_only_path_prefixes` 与 `docs/team-write-authority.md` 一致，共 5 case
  - 新增 `tests/verify-team-orchestration.ps1`：动态测试 `spawn-team.ps1` 的 env opt-in 行为（O1/O2/O6）+ payload 正确性（O3）+ fallback（O4）+ 单写者前缀的静态拦截（O5）；**不**声称证明 orchestrator executable dispatcher（不存在的合同），共 6 case
  - 单 agent 环境（`$env:AIONUI_TEAM_MODE` 未设）下：`advance-stage.ps1` / `invoke-harness-skill.ps1` / `validate-lite-artifacts.ps1` 行为**字节级零变化**，所有 Phase 1-3 既有测试顺跑零回归
  - 所有新 `.ps1` UTF-8 BOM；新 `.md` / `.yaml` UTF-8 无 BOM；`verify-lite-footprint.ps1` 路径白名单同步扩展放行 `skills/workflow-team/` 与 `agent-configs/role-prompts/`

- 非目标:
  - **不**做 `294bf604`（`verify-update-managed-assets` 回归）—— 独立后续任务，不并入本 Phase 主线
  - **不**重开 `install.ps1` / `uninstall.ps1` 改造（Phase 3 Run 1 修订 A 已封口）；本 Phase 也**不**改 install/uninstall
  - **不**改 `current-flow.md` 真相源问题（Phase 0 范围）
  - **不**改 Phase 3 adapter 合约（白名单 / stdout JSON / invocation trace / per-task manifest 已闭环）
  - **不**实装反向 sync（`team_task_update` → `plan.md`）；本 Phase 仅文档化禁止（Q5(a)）
  - **不**扩 `SKILL.md` frontmatter `inputs / outputs` schema（延至独立 skill-frontmatter Phase）
  - **不**改 frontmatter 4-字段 schema；**不**改 stdout `<stage> | <tool>` 契约
  - **不**自动激活 team-mode（Q6(b) 显式 opt-in env 触发）；默认 single-agent 行为零变化
  - **不**新增 `##` 二级 section 到 `plan.md`（任何 team-mode 状态走独立文件，不污染 plan 段序）
  - **不**让 member spawned agent 直接写 vault；写权限只属于 leader / `advance-stage.ps1`（Q3(b) 静态校验拦截）
  - **不**改 `.assistant/工作流/共享记忆协议.md`（vault 协议属 Phase 0 范围）
  - **不**修改 Phase 1 / Phase 2 / Phase 3 任一既有测试的 exact-string 断言

- 受影响目录:
  - `scripts/export-team-preset.ps1` — 新文件（team preset 派生脚本，Q2(b)）
  - `skills/workflow-team/SKILL.md` — 新文件（team-mode 桥接 skill，Q1(a) 独立 skill）
  - `skills/workflow-team/scripts/spawn-team.ps1` — 新文件（leader 端调度 helper；调用 `team_spawn_agent` 的 PowerShell 包装，预留为 stub，真正 MCP 调用由 AionUi 端注入）
  - `agent-configs/role-prompts/plan-author.md` / `plan-reviewer.md` / `implementer.md` / `code-reviewer.md` / `tester.md` — 5 个新 role-prompt 模板（Q7(b)）
  - `skills/orchestrator/SKILL.md` — §调度规则增 team-mode 探测 + 委托语句；不破坏既有 § 顺序
  - `skills/orchestrator/references/runbook.md` — 增 §5 "Team mode dispatch"（探测信号 / spawn 步骤 / 失败回退 / 单写者表引用）
  - `skills/orchestrator/references/state-templates.md` — 增 team preset YAML 模板与 role-prompt 模板样板
  - `skills/orchestrator/references/default-tool-profiles.md` — 新增段落"profile 在 team preset 中的角色"（每 stage 的 default_profile 决定 spawn 时 backend + model）
  - `docs/team-write-authority.md` — 新文件（单写者权限表，leader vs member 写入面）
  - `docs/aionui-integration/team-preset.md` — 新文件（AionUi 消费契约文档；harness 侧不改 AionUi 代码）
  - `README.md` — 加 Team mode 启用说明（`$env:AIONUI_TEAM_MODE='1'` + `export-team-preset.ps1` 用法）
  - `tests/verify-team-preset.ps1` — 新文件
  - `tests/verify-team-orchestration.ps1` — 新文件
  - `tests/verify-lite-footprint.ps1` — 扩 skill 白名单收纳 `skills/workflow-team/`（Q1(a) 已选定）；同步放行 `agent-configs/role-prompts/` 路径

- 回滚策略:
  - Phase 4 全 additive：删除 `scripts/export-team-preset.ps1` + `skills/workflow-team/` 整目录 + `agent-configs/role-prompts/` 整目录 + 两个新测试 + `docs/team-write-authority.md` + `docs/aionui-integration/team-preset.md` + 撤回 `skills/orchestrator/SKILL.md` 与 `references/runbook.md` 的新增段落 → 回到 Phase 3 末态
  - 单点失败隔离：
    - team_* MCP 不可用 → `workflow-team` skill 直接 fallback 到单 agent 流程；leader 收到 stderr 诊断 "team mode requested but team_* MCP unavailable; reverting to single-agent flow"；不破坏 Phase 1-3 任何契约
    - role-prompt 模板缺失 → spawn 报错 + stderr 诊断 + fallback 到单 agent；不写 vault
    - export-team-preset 输出失败（IO / parse 错误）→ exit 非零 + stderr 诊断；不污染 stdout（保持单 agent 工具链不连带破坏）
    - member spawned agent 误写 `.assistant/` 或 `docs/tasks/<task-id>/` 任一路径 → 静态测试 `verify-team-orchestration.ps1` O5（Q3(b)）在 PR / CI 阶段拦截（前缀匹配，与 preset / role-prompt / 单写者文档同一组前缀）；运行时拦截属 Phase 5 范围
    - 单 agent 环境下 `$env:AIONUI_TEAM_MODE` 未设 → `spawn-team.ps1` 自身 fail closed 拒绝进入 spawn 路径（不发起任何 `team_spawn_agent`）；orchestrator / advance-stage / invoke-harness-skill 路径**字节级零变化**
  - 回滚验证：删除上述新文件后跑 Phase 1/2/3 全套 verify-* + `validate-lite-artifacts.ps1` → 应全部 PASS

- ui: not-applicable

## User Confirmation
- status: confirmed
- note: Leader 2026-04-25 圈定 Phase 4 范围（Phase 1/2/3 为前置；不并入独立后续任务 `294bf604`；不重开 install/uninstall / current-flow / Phase 3 adapter）；同日裁定 Q1–Q8 全部闭环（Q1=a / Q2=b / Q3=b / Q4=a / Q5=a / Q6=b / Q7=b / Q8=a），本 plan 已按裁定结果就地修订，无开放式 pending 项，可直接进入 IMPLEMENT

## Change Contract
- change_type: feature
- affected_paths:
  - scripts/export-team-preset.ps1
  - skills/workflow-team/SKILL.md
  - skills/workflow-team/scripts/spawn-team.ps1
  - agent-configs/role-prompts/plan-author.md
  - agent-configs/role-prompts/plan-reviewer.md
  - agent-configs/role-prompts/implementer.md
  - agent-configs/role-prompts/code-reviewer.md
  - agent-configs/role-prompts/tester.md
  - skills/orchestrator/SKILL.md
  - skills/orchestrator/references/runbook.md
  - skills/orchestrator/references/state-templates.md
  - skills/orchestrator/references/default-tool-profiles.md
  - docs/team-write-authority.md
  - docs/aionui-integration/team-preset.md
  - README.md
  - tests/verify-team-preset.ps1
  - tests/verify-team-orchestration.ps1

## Plan

- TODO 1 · `scripts/export-team-preset.ps1`（team preset 派生脚本，Q2(b)）
  - `param([string]$Workflow = 'harness-lite', [string]$Output, [ValidateSet('yaml','json')][string]$Format = 'yaml', [string]$RepoRoot = '')`
  - 读 `agent-configs/workflows/$Workflow.yaml`：取 `name` / `version` / `stages.<S>.{role, default_profile, skills_whitelist}`
  - 对每个 stage 的 `default_profile` 读 `agent-configs/profiles/<id>.yaml`，提取 `backend` / `model` / `skills_dirs[0]`
  - 对每个 stage 的 `role` 读 `agent-configs/role-prompts/<role>.md`，记录 `role_prompt_ref` 路径（**不**内联 prompt 全文，保持 preset 体积可控；spawn 时由 leader 即时读）
  - 输出对象：
    ```yaml
    name: harness-lite
    version: 1
    single_writer:
      owner: leader
      members_read_only_path_prefixes:
        - .assistant/
        - docs/tasks/<task-id>/
    members:
      - role: plan-author
        backend: claudecode
        model: claude-opus-4-7
        skills_whitelist: [plan, using-superpowers]
        role_prompt_ref: agent-configs/role-prompts/plan-author.md
      # ...其余 4 stage 同构
    ```
  - `members_read_only_path_prefixes` 来源固定：导出脚本不参数化此集合，常量数组直接写入 preset；任何后续扩展（如 `.codex/` / `.gemini/`）必须先改 `docs/team-write-authority.md` 再同步至导出脚本，避免漂移
  - 输出格式 yaml（默认）/ json（`-Format json`）；UTF-8 无 BOM
  - stderr：派生过程诊断（`resolved profile=<id> backend=<X> model=<Y> for role=<R>`）；stdout 仅写产物或落地路径（`team-preset written to <path>`），保持下游脚本 pipe 安全
  - 任一前置文件缺失 → exit 非零 + stderr 诊断；**不**写空 / 半成品文件
  - 文件本身 UTF-8 BOM（`.ps1`，verify-lite-footprint.ps1 约束）

- TODO 2 · `skills/workflow-team/SKILL.md` + `skills/workflow-team/scripts/spawn-team.ps1`（Q1(a)）
  - SKILL.md 内容（**文档面**，不读 env）：
    1. § "When to use"：仅在 `$env:AIONUI_TEAM_MODE='1'`（Q6(b)）且 leader 决定起 team 时调用；单 agent 环境下不激活；env opt-in 的可执行强制点位于 `spawn-team.ps1` 自身
    2. § "Spawn sequence"：调用 `spawn-team.ps1`（leader 端 helper）→ 该 helper 自身校验 env，再调 `team_spawn_agent` × 5（每 role 一次，按 stage 顺序：plan-author → plan-reviewer → implementer → code-reviewer → tester）
    3. § "Fallback"：team_* MCP 不可用 / spawn 失败 → 立即降级单 agent 流程，stderr 诊断；leader 决定是否继续
    4. § "Single-writer constraint"：链接到 `docs/team-write-authority.md`；声明 spawned member 对 `.assistant/` 与 `docs/tasks/<task-id>/` 两组前缀**只读**（与 preset `members_read_only_path_prefixes` 同一组）
  - `spawn-team.ps1`（**team-mode opt-in 的可执行强制点**）：
    1. `param([string]$WorkflowName='harness-lite', [string]$TaskId, [string]$RepoRoot='')`
    2. **env 前置校验（fail-closed）**：脚本入口立即读 `$env:AIONUI_TEAM_MODE`；若值不是字符串 `'1'` → stderr 写 "AIONUI_TEAM_MODE not set; team-mode is opt-in only" + stdout 单行 `{"ok":false,"reason":"team_mode_disabled"}` + exit 非零；**不**调用 `export-team-preset.ps1`、**不**构造 payload、**不**触发任何 `team_spawn_agent`
    3. env 校验通过 → 调 `export-team-preset.ps1` 派生 preset 到内存（或临时文件）
    4. 对每个 member：调用 `team_spawn_agent` MCP（实际 MCP 调用由 AionUi 主进程注入；本脚本只负责构造 payload + 调度顺序）；payload 包括 role / backend / model / 系统首条 prompt（读 role_prompt_ref）/ skills_whitelist
    5. spawn 失败 → stderr 诊断 + 终止后续 spawn + 返回 ok=false JSON 单行 stdout（与 Phase 3 adapter stdout 风格一致）
    6. 不修改 plan.md；invocation trace 不写（这是 leader 操作，不属 Phase 3 adapter 调度面）
    7. 全程 stdout 单行 JSON、stderr 走诊断；MCP 在场但 env 未设的情形与 env 未设无 MCP 行为字节级一致（O6 锁死）
  - 文件 UTF-8 BOM

- TODO 3 · `agent-configs/role-prompts/<role>.md` × 5（Q7(b)）
  - 5 个文件：`plan-author.md` / `plan-reviewer.md` / `implementer.md` / `code-reviewer.md` / `tester.md`
  - 每文件结构：
    ```markdown
    # Role: <role>

    You are the <role> for harness-lite workflow.

    ## Stage scope
    <which stage(s) this role drives>

    ## Authority
    - Read-only path prefixes:
      - .assistant/
      - docs/tasks/<task-id>/
    - Write: NONE under either prefix (leader is the sole vault writer)
    - Allowed skills: <skills_whitelist for this stage>

    ## Handoff back to leader
    Use team_send_message(to='Leader', summary='<S>', message='<M>') with structured findings.
    Do not call advance-stage.ps1 directly.
    Do not call team_task_update to mutate task state (vault is the truth source; Q5(a) doc-only ban).
    ```
  - 5 份 role-prompt 的 Authority 段使用**完全相同**的两条前缀字符串（与 preset `members_read_only_path_prefixes` / `docs/team-write-authority.md` / O5 静态拦截共享）；UTF-8 无 BOM；位置 `agent-configs/role-prompts/`；命名小写连字符（避免 S10 footprint 禁词）

- TODO 4 · `skills/orchestrator/SKILL.md` 增 team-mode **文档分支**（Q6(b)）
  - 在 §调度规则末尾追加一段（**文档面**，不写任何会读 env 的可执行 dispatcher）：
    > **Team mode (documentation only)**: 当 leader 已设 `$env:AIONUI_TEAM_MODE='1'` 时，可调用 `skills/workflow-team/scripts/spawn-team.ps1` 起 5 role 团队；env 校验由 `spawn-team.ps1` 自身 fail-closed 强制。env 未设时维持单 agent 流程，所有 Phase 1-3 行为零变化；orchestrator skill 本身**不**新增任何读 env 的可执行分支。
  - **不**改既有 § 顺序；**不**改 stdout / stderr 既有契约；**不**新增 orchestrator 端 PowerShell 函数读 `AIONUI_TEAM_MODE`
  - 同步在 `references/runbook.md` 加 §5 "Team mode dispatch"，同样限定为文档；明确 "可执行强制点 = `spawn-team.ps1`"

- TODO 5 · `docs/team-write-authority.md`（单写者权限表）
  - 内容：
    1. § "Member read-only path prefixes"：**目录级前缀**列表（与 preset `members_read_only_path_prefixes` / role-prompt Authority 段 / O5 静态拦截**字节级一致**）：
       - `.assistant/`
       - `docs/tasks/<task-id>/`
    2. § "Leader sole-writer scope"：在以上两组前缀下的**所有写入路径**（包括但不限于 `plan.md` / `test.md` / `skill-manifest.json` / 任何 `.assistant/` 文件 / 任何 `docs/tasks/<task-id>/` 内文件）写入权仅属于 leader 或 leader 间接调用的 `advance-stage.ps1` / `invoke-harness-skill.ps1`（按 Phase 3 既有合约）
    3. § "Member authority"：spawned agent 在以上前缀**全为只读**；输出走 `team_send_message` 回 leader；leader 决定是否 commit / 是否调 `advance-stage.ps1`
    4. § "Forbidden member operations"：member 进程直接对前缀内任一路径执行 `Set-Content` / `Out-File` / `git commit -m ... -- <prefix>/...` / 调 `advance-stage.ps1` / 调 `team_task_update` 改 task state
    5. § "Enforcement"：本 Phase Q3(b) 静态校验（`tests/verify-team-orchestration.ps1` O5 前缀匹配静态扫描）；runtime hook 拦截留 Phase 5
  - 该文档列出的两条前缀字符串是**全 plan 唯一真相源**：preset、role-prompt、O5 测试均引用此处
  - UTF-8 无 BOM

- TODO 6 · `docs/aionui-integration/team-preset.md`（AionUi 消费契约文档）
  - 内容：
    1. team preset 输出 schema（与 TODO 1 输出一致）
    2. AionUi 端建议消费路径：读 preset → 调 `team_spawn_agent` per member
    3. 不在本 repo 改 AionUi 代码；本文档仅作为契约 reference
  - UTF-8 无 BOM；位置 `docs/aionui-integration/`（新目录）

- TODO 7 · 测试
  - `tests/verify-team-preset.ps1`：
    - P1：`export-team-preset.ps1 -Workflow harness-lite` 输出结构通过 schema（`name` / `version` / `single_writer.{owner,members_read_only_path_prefixes[]}` / `members[].{role,backend,model,skills_whitelist[],role_prompt_ref}`）
    - P2：preset.members 数量 = `harness-lite.yaml.stages` 数（5）；`role` 集合等于 `[plan-author, plan-reviewer, implementer, code-reviewer, tester]`
    - P3：每 member 的 `backend` / `model` 与对应 `default_profile` YAML 字段一致
    - P4：每 member 的 `skills_whitelist` 与 `harness-lite.yaml.stages.<stage>.skills_whitelist` 完全一致（顺序敏感或集合相等任选其一，本 Phase 选集合相等）
    - P5：每 member 的 `role_prompt_ref` 指向真实存在的 `agent-configs/role-prompts/<role>.md`；并断言 `members_read_only_path_prefixes` 等于 `['.assistant/', 'docs/tasks/<task-id>/']`，且 `docs/team-write-authority.md` 文档段提取出的前缀字符串与此**字节级一致**（grep 抽取 + 集合相等）
  - `tests/verify-team-orchestration.ps1`（**测试目标 = `spawn-team.ps1`，不再声称证明 orchestrator executable dispatcher**）：
    - O1 env 未设：`$env:AIONUI_TEAM_MODE` 未设直接调 `spawn-team.ps1` → exit 非零 / stdout 单行 `{"ok":false,"reason":"team_mode_disabled"}` / stderr 含 "AIONUI_TEAM_MODE not set" / 期间**不**调用任何 mock `team_spawn_agent`（mock 调用计数 == 0）；同时静态断言 orchestrator skill 文档分支不读 env（`Select-String AIONUI_TEAM_MODE skills/orchestrator/SKILL.md` 仅命中文档段，无 PS 读 env 语句）
    - O2 env opt-in：`$env:AIONUI_TEAM_MODE='1'` 调 `spawn-team.ps1` → mock `team_spawn_agent` 调用恰好 5 次（按 stage 顺序：plan-author → plan-reviewer → implementer → code-reviewer → tester）；stdout 单行 `{"ok":true,...}`
    - O3 spawn payload：O2 路径下每次 `team_spawn_agent` payload 含正确 role / backend / model / system prompt seed（从 role_prompt_ref 读出 + 与 role-prompt 文件字节级一致）/ skills_whitelist
    - O4 fallback：env 已设 + mock `team_spawn_agent` 第 N 次抛异常 → `spawn-team.ps1` 立即终止后续 spawn + stderr 诊断 + stdout 单行 `{"ok":false,"reason":"spawn_failed",...}`；后续 spawn 计数停在 N
    - O5 单写者前缀拦截（Q3(b)，**前缀级静态扫描**）：枚举 5 份 role-prompt 与 SKILL.md 文本，断言每一份均包含字符串 `.assistant/` 与 `docs/tasks/<task-id>/`（前缀来自 `docs/team-write-authority.md` 抽取）；同时模拟一段 member 代码 `Set-Content $repo/.assistant/foo.md` / `Set-Content $repo/docs/tasks/x/plan.md` → 静态正则 `Set-Content\s+\$\w+/(\.assistant/|docs/tasks/)` 命中 ≥ 1 次（演示 PR / CI 阶段可拦截）
    - O6 env 未设 + team_* MCP 在线：手工注入 mock MCP 但保持 env 未设 → `spawn-team.ps1` 行为与 O1 字节级一致（exit code / stdout / stderr / mock 调用计数 0），证明 opt-in 不被 MCP 在场所旁路
  - 测试文件遵循 `verify-lite-footprint.ps1`：UTF-8 BOM、`.ps1` 后缀、位置在 `tests/`
  - 不修改任何既有测试；`validate-lite-artifacts.ps1` 字节级零变化的 fixture diff 在回归 smoke 1 中验证（不在本测试 scope 内）

- TODO 8 · 回归 + smoke
  - Phase 1 / 2 / 3 / 4 全套 verify-*（不含 `verify-installation.ps1` / `verify-update-managed-assets.ps1`，分别由 Phase 3 Run 1 修订 B / 独立任务 `294bf604` 处理）：
    - `verify-workflow-contracts.ps1` / `verify-tool-profile.ps1` / `verify-workflow-descriptor.ps1` / `verify-lite-artifact-validator.ps1` / `verify-lite-footprint.ps1` / `verify-aionui-skill-contract.ps1` / `verify-skill-manifest.ps1` / `verify-team-preset.ps1` / `verify-team-orchestration.ps1`
  - 任一非零 → 回 IMPLEMENT 排查（优先回查 spawn-team.ps1 stdout 污染 / role-prompt 缺失 / preset schema 漂移）
  - 手工 smoke 三条（执行者本地）：
    1. 单 agent 默认（`$env:AIONUI_TEAM_MODE` 未设）：`advance-stage.ps1 -TaskId <smoke> -Tool codex` 输出与 Phase 3 末态字节一致；同时 `spawn-team.ps1 -TaskId <smoke>` 立即 fail-closed（stdout `{"ok":false,"reason":"team_mode_disabled"}` / exit 非零 / 不调任何 MCP）
    2. `export-team-preset.ps1 -Workflow harness-lite -Output <tmp>/team.yaml` → 文件生成且通过 `verify-team-preset.ps1` schema；preset 中 `members_read_only_path_prefixes` 字段 = `['.assistant/', 'docs/tasks/<task-id>/']`
    3. `$env:AIONUI_TEAM_MODE='1'` + mock `team_spawn_agent` → `spawn-team.ps1 -TaskId <smoke>` 触发 5 次 spawn，stdout 单行 ok=true JSON；mock 抛异常时 fallback 路径生效（stdout `{"ok":false,"reason":"spawn_failed",...}`）

## Verification

- `pwsh -File .\tests\verify-team-preset.ps1`
- `pwsh -File .\tests\verify-team-orchestration.ps1`
- `pwsh -File .\tests\verify-aionui-skill-contract.ps1`
- `pwsh -File .\tests\verify-skill-manifest.ps1`
- `pwsh -File .\tests\verify-workflow-descriptor.ps1`
- `pwsh -File .\tests\verify-workflow-contracts.ps1`
- `pwsh -File .\tests\verify-tool-profile.ps1`
- `pwsh -File .\tests\verify-lite-artifact-validator.ps1`
- `pwsh -File .\tests\verify-lite-footprint.ps1`
- `pwsh -File .\scripts\export-team-preset.ps1 -Workflow harness-lite -Output <tmp>/team.yaml`
- `pwsh -File .\scripts\advance-stage.ps1 -TaskId <smoke> -Tool codex`

覆盖意图：
- 新 `verify-team-preset.ps1`：preset schema（含 `members_read_only_path_prefixes`）+ 5 member parity + backend/model parity + skills_whitelist parity + role-prompt 引用完整性 + 前缀字符串与 `docs/team-write-authority.md` 字节级一致，共 5 case
- 新 `verify-team-orchestration.ps1`（**测试目标 = `spawn-team.ps1`**）：env 未设 fail-closed（O1）+ env opt-in 起 5 次 spawn（O2）+ spawn payload 正确性（O3）+ spawn 异常 fallback（O4）+ 单写者前缀级静态拦截（O5）+ MCP 在场但 env 未设仍 fail-closed（O6），共 6 case；**不**声称证明 orchestrator executable dispatcher
- `verify-aionui-skill-contract.ps1` / `verify-skill-manifest.ps1` 确认 Phase 3 adapter / manifest 合约零回归
- `verify-workflow-descriptor.ps1` / `verify-tool-profile.ps1` 确认 Phase 1/2 fallback / writeback / non-sticky 零回归
- `verify-lite-artifact-validator.ps1` 确认 Phase 4 未引入新 plan.md section / 未改 frontmatter schema
- `verify-lite-footprint.ps1` 确认新增 `skills/workflow-team/`（Q1(a)）+ `agent-configs/role-prompts/` 目录路径白名单已正确扩展
- 注意：`verify-installation.ps1` 不在本 Phase mandatory 列表（Phase 3 Run 1 修订 B 决议沿用）；`verify-update-managed-assets.ps1` 不在本 Phase 列表（独立任务 `294bf604`，Leader 已圈定）
- Smoke 三条：单 agent 字节级零变化 + `spawn-team.ps1` env-未设 fail-closed / preset 派生（前缀字段断言）/ mock team-mode env-opt-in spawn

## Risks

- **R0（最高）· 单写者模型被 team-mode 打破**（继承 architecture R10）：spawned member 在 `.assistant/` 或 `docs/tasks/<task-id>/` 任一前缀下写入导致 single-truth 损坏；缓解：(a) `docs/team-write-authority.md` 列出**两条目录级前缀**作为唯一真相源；(b) preset `members_read_only_path_prefixes` / role-prompt Authority / O5 静态拦截共享同一组前缀（字节级一致，由 P5 + O5 双重断言）；(c) Q3(b) 静态测试 O5 前缀正则扫描在 PR / CI 阶段拦截；(d) team-mode 触发时 leader 保持唯一 vault 写者身份；(e) Phase 5 加 runtime hook 强化（不在本 Phase 范围）
- **R-OPT 误开 team-mode 静默 spawn**：若按"team_* MCP 在线即激活"策略，单 agent 用户被强制 spawn → 行为剧变；缓解：Q6(b) 显式 env opt-in `AIONUI_TEAM_MODE=1`；可执行强制点固定在 `spawn-team.ps1` 入口 fail-closed（不在 orchestrator skill / SKILL.md 文档处）；O1 / O6 case 锁死 "env 未设 → 任何 MCP 调用计数 0"
- **R-CONTRACT-FAKE 把文档分支当成可执行合同**：若把 orchestrator SKILL.md 的 "Team mode detection" 文本误解为可执行 dispatcher，会让 O1/O2/O6 测试假装在证明一个不存在的运行时分支；缓解：本 Phase 显式声明 orchestrator skill 文本为**文档面**，team-mode opt-in 唯一可执行强制点 = `spawn-team.ps1`；O1 静态断言 orchestrator skill 文件**不**含读 env 的 PowerShell 语句（仅文档段允许出现 `AIONUI_TEAM_MODE` 字符串）
- **R-DRIFT team preset 与 workflow descriptor 漂移**：`harness-lite.yaml` 改了 stage / role / skills_whitelist 后未刷新 preset → spawn 用错配置；缓解：(a) Q2(b) 派生脚本（preset 永远从 yaml 即时派生，**不**落静态文件）；(b) `verify-team-preset.ps1` P3/P4 强制 parity 校验（backend/model/skills_whitelist 与 yaml + profiles 一致）
- **R-PLATFORM 跨平台**（继承 architecture R4）：本 Phase Q4(a) PowerShell-only，macOS/Linux 用户需安装 pwsh 7+；缓解：在 README + runbook 明示 pwsh 7+ 是 Phase 4 前置；不做双端 Node 镜像（不在本 Phase scope）
- **R-FALLBACK fallback 路径被 stdout 污染破坏**：`spawn-team.ps1` 失败时若误用 `Write-Host` / `Write-Output` 输出诊断，会破坏 stdout 单行 JSON 契约（沿用 Phase 3 adapter 风格）；缓解：强制 `[Console]::Out.WriteLine`（stdout）/ `[Console]::Error.WriteLine`（stderr）；O4 case 字节级断言 stdout 行数=1
- **R-PROMPT role-prompt 内容漂移**：5 份 role-prompt 与 stage authority 不一致（如 implementer prompt 漏写 "do not call advance-stage"）→ spawned agent 越权操作；缓解：role-prompt 模板 § "Authority" 段固定结构；P5 case 校验文件存在性；内容 review 在 IMPLEMENT 阶段 code review 强制 checklist
- **R-FOOTPRINT 新增 skill 目录触发 verify-lite-footprint 断言**（继承 R13）：Q1(a) 选独立 skill 后 `skills/workflow-team/` 需加入 footprint 白名单（`verify-lite-footprint.ps1:167-185` 区域）；漏改 → footprint 测试 FAIL；缓解：TODO 7 测试 dependency 上 lift footprint 修订；同时校对 `agent-configs/role-prompts/` 目录是否被 footprint 路径白名单覆盖
- **R-MCP team_* MCP 调用契约假设**：本 Phase 假设 AionUi 端 `team_spawn_agent` 接受 `{role, backend, model, system_prompt, skills_whitelist}` 等字段；若 AionUi 实际 schema 不同 → spawn 直接失败；缓解：(a) `docs/aionui-integration/team-preset.md` 文档化 harness 侧契约；(b) IMPLEMENT 前 cross-check `src/process/team/mcp/team/TeamMcpServer.ts::handleSpawnAgent`（architecture §3 引用）；(c) spawn 失败走 R-FALLBACK 路径
- **R-REV 反向 sync 漏洞**：member 通过 `team_task_update` 改 task state → vault 失同步；本 Phase Q5(a) 仅文档化禁止，未做 validator 拦截；若 leader 在 team-mode 下未守门 → vault drift；缓解：role-prompt § "Handoff" 显式禁止 `team_task_update` 用于 task state 改写；Phase 5 加拦截
- **R-LEADER Leader 角色定位**（关 Q8）：Q8(a) 已裁定 Leader 不计入 spawn role，5 stage = 5 spawn slot；TODO 1 preset.members 固定 5；TODO 7 P2 断言 "members 数量 = 5" 不放宽
- **Phase 1-3 顺序耦合**：本 Phase 依赖 Phase 1 profile（backend/model）、Phase 2 workflow descriptor（stage/role/skills_whitelist）、Phase 3 adapter（spawn member 内部调 invoke-harness-skill.ps1 时复用 stdout JSON 合约）；缓解：(a) IMPLEMENT 前确认 Phase 3 已闭环（已知 PASS）；(b) 不引入对 Phase 1-3 内部函数的依赖（仅读文件）；(c) 任何 Phase 1-3 测试 FAIL 必须先回排 Phase 1-3，再进 Phase 4

## Plan Review

### Run 1 · 2026-04-25 14:31 · runner: harness-implementer
- verdict: revise
- findings:
  - P1: `O1` / `O2` / `O6` 目前不是现实可执行的验证合同。计划把 team-mode 探测定义在 `skills/orchestrator/SKILL.md` 和 `skills/workflow-team/SKILL.md` 上，但本 Phase 受影响的可执行面只有 `scripts/export-team-preset.ps1` 与 `skills/workflow-team/scripts/spawn-team.ps1`；当前 repo 内没有任何脚本会读取 `AIONUI_TEAM_MODE` 并真正执行“orchestrator 委托 `workflow-team`”这条运行时分支。因此 `tests/verify-team-orchestration.ps1` 无法只靠本仓库代码去 mock `team_spawn_agent` 并证明 O1/O2/O6。进入 IMPLEMENT 前，计划需要二选一并写死：要么把验证范围收紧为“静态检查 orchestrator / workflow-team 文案 + 动态测试 `spawn-team.ps1`”；要么把一个实际消费 `AIONUI_TEAM_MODE` 的可执行 dispatcher 明确纳入本 Phase 范围与受影响文件。
  - P2: team preset 导出契约与单写者文档范围还不一致。当前 preset `single_writer.members_read_only_paths` 只列了 `docs/tasks/<id>/plan.md` 和 `test.md`，但 TODO 5 又把 `skill-manifest.json` / `skills-index.md` 列为 truth-source files，并同时声明 member `Write: NONE`。如果 AionUi 端按 exported preset 执行只读约束，那么 preset、`docs/team-write-authority.md`、role-prompt Authority 段和 O5 静态拦截检查的保护集合并不一致。进入 IMPLEMENT 前，需要统一“member 禁写”的精确文件集合，并让 preset schema、文档和测试使用同一套列表。
- next: Revise the executable team-mode verification contract and reconcile the single-writer protected-path set before entering IMPLEMENT.

### Run 2 · 2026-04-25 14:40 · runner: harness-implementer
- verdict: pass
- findings: none
- evidence: The two scoped blockers from Run 1 are now closed. Team-mode dynamic verification is explicitly narrowed to `skills/workflow-team/scripts/spawn-team.ps1` as the only executable env opt-in gate: Clarification, TODO 2, TODO 4, TODO 7 `O1/O2/O6`, Verification coverage text, smoke, and `R-CONTRACT-FAKE` all now say orchestrator is documentation-only and does not provide an executable dispatcher. The single-writer contract is also internally consistent on the directory-prefix set `['.assistant/', 'docs/tasks/<task-id>/']`: preset schema (`members_read_only_path_prefixes`), `docs/team-write-authority.md`, role-prompt Authority, `verify-team-preset.ps1` `P5`, `verify-team-orchestration.ps1` `O5`, rollback wording, and `R0` all reference the same pair of prefixes.
- next: Plan is ready to enter IMPLEMENT for the two scoped items reviewed in Run 2.

## Implementation Notes

## Code Review
