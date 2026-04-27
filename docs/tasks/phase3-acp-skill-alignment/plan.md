---
task_id: phase3-acp-skill-alignment
stage: PLAN
tool: claudecode
updated: 2026-04-25
---
# Phase 3 · ACP Skill Alignment

本任务是 `docs/tasks/harness-aionui-workflow-alignment/architecture.md` §3.5 + §4 Phase 3（C 主线）的独立 lite 推进。前置假设 Phase 1（`tool_profile` / `model` + 三个 `harness-default-*` profile + `-Profile` / `-Model` CLI）、Phase 2（`agent-configs/workflows/harness-lite.yaml` + `Resolve-FallbackTool` + validator `Warnings:` 段）均已落地。**不做** team preset bridge（Phase 4），**不做** SKILL.md frontmatter inputs/outputs schema 扩展（延至 Phase 4+，见 architecture §3.5 第 6 步），**不动** `current-flow.md` 真相源问题（Phase 0 范围）。

**Leader 裁定结果（2026-04-24，Q1–Q4 全部闭环；2026-04-25 Run 1 追加 3 条修订）**：

- **Q1 · `review` / `test` adapter 形态** → **stub 方案采纳**。本 Phase 不落地 `skills/review/scripts/*` 或 `skills/test/scripts/*`；adapter 收到 `skill=review` / `skill=test` 一律返回 `ok=true status=markdown-fallback`，并在 stderr 写一行 "adapter stub; fall back to Markdown-skill flow"。
- **Q2 · `skill-manifest.json` 写入位置** → **采用 per-task `docs/tasks/<task-id>/skill-manifest.json`**（弃用 `.assistant/运行时/skill-manifest.json`）。理由：(1) 不新增共享运行时写入面；(2) 更贴近 AionUi 嵌入消费；(3) 与 `skills-index.md` 同属 per-task artifact，验证和回滚同粒度。对应：hook 不再读 `ASSISTANT_ROOT` 环境变量；TODO 3 直接写 `docs/tasks/$TaskId/skill-manifest.json`；TODO 5 的 E3 "ASSISTANT_ROOT 缺失" case 删除，保留 E1 / E2 / E4（写入失败 best-effort）。
- **Q3 · task-level `skills_dir` 字段** → **本 Phase 仅预留**，**不**写入 plan.md frontmatter，**不**加 validator 校验；三级作用域解析器遇无字段直接下沉 project-level（见 TODO 4）。
- **Q4 · invocation trace 落点** → **保留 append-only 单行**（`- invocation: skill=<X> mode=adapter tool=<Y> ok=<bool>`），**仅**允许追加到目标 `plan.md` 中已经存在的 `### Run N` 块（`## Plan Review` / `## Implementation Notes` / `## Code Review` 之下的最新 run 块）尾部；若对应 stage section 尚无任一 `### Run N` 块，adapter **跳过写入**并在 stderr 记录 best-effort 诊断。**不**新增 `## Invocation Log` section，**不**自动创建新 `### Run N` 块，**不**产生顶层或 section 首行的 bare `- invocation:` 行。测试需覆盖"目标 section 无 Run N → 安全跳过且 lite artifact 仍有效"。
- **Run 1 修订 A（2026-04-25）· install.ps1 / uninstall.ps1 active-profile 驱动改造收回** → **本 Phase 不动** `install.ps1` / `uninstall.ps1` 既有行为。单个 active profile 的 `skills_dirs[0]` 无法同时正确驱动 Claude / Codex 两个 host 根（profiles 是 backend-specific，原设计会把 Codex 路径错误绑定到 `harness-default-claude`）。`skills_dirs` 在本 Phase 仅服务于 adapter（invoke-harness-skill.ps1 的 user-level 兜底）/ `skills-index.md` / `skill-manifest.json` 三处语义，**不**进入 install/uninstall。Clarification / TODO / Risks / Verification / affected_paths / 回滚一并删除或改成"本 Phase 不改 install/uninstall"。
- **Run 1 修订 B（2026-04-25）· `verify-installation.ps1` 从 mandatory Verification 列表移除** → 既然本 Phase 不改 install/uninstall，这个脚本不作为当前阶段的 mandatory gate；并且它无法无参运行（`tests/verify-installation.ps1:2-8` 要求 `-WorkspaceRoot`）。如需保留安装层 smoke 只能写成带参的 optional check，不再写入本 plan 的 Verification 列表。
- **Run 1 修订 C（2026-04-25）· invocation trace 合约收紧** → 已并入 Q4 裁定表述（上条），此处仅确认 TODO 1 / TODO 5 D-case 按新合约实现 + 覆盖"无 Run block 安全跳过"。

## Clarification

- 验收标准:
  - 新增 `scripts/invoke-harness-skill.ps1`（统一 adapter）：参数 `-TaskId / -Stage / -Skill / -Tool / -ToolProfileId / -WorkspaceRoot / -ArtifactRoot / -Mode / -PayloadJson`；stdout **单行** 合法 JSON（`{"ok":bool,"status":string,"artifact_paths":[...],"next_stage_hint":string,"handoff":string,"errors":[...]}`）；诊断写 stderr；白名单硬编码 `$AllowedSkills = @('review','test','gemini-designer-main','codex')`；`skill=implement` **显式拒绝**（`ok=false` + stderr 原因）；`skill=codex` 仅允许 `-Mode readonly` 分支下行，拒绝 `writable`
  - 新增 `scripts/generate-skills-index.ps1`：参数 `-TaskId / -Stage / -BackendHint / [-OutputPath]`；默认输出 `docs/tasks/<task-id>/skills-index.md`；内容列当前 stage `skills_whitelist`（从 `harness-lite.yaml` 读）+ 每 skill 一行 description（从 `SKILL.md` frontmatter 抽）；UTF-8（无 BOM，markdown 约定）
  - 扩展 `scripts/advance-stage.ps1`：stage 推进成功且 stdout 已经输出 `<stage> | <tool>` **之后**，best-effort 写 `docs/tasks/<task-id>/skill-manifest.json`（per-task，Leader 裁定 Q2）；写入异常 → stderr 诊断，**不**影响退出码；**不**读取任何 `ASSISTANT_ROOT` 环境变量
  - `skill-manifest.json` schema：`{"version":1,"task_id":"<id>","stage":"<S>","tool":"<T>","available_commands":[{"name":"<skill>","description":"<desc>"},…],"generated_at":"<ISO8601>"}`；`available_commands` 等同 `harness-lite.yaml.stages.<stage>.skills_whitelist`；文件位置与 `skills-index.md` 同级，便于 per-task 验证与回滚
  - 新增 `tests/verify-skill-manifest.ps1`：manifest schema + per-task 路径断言（不出现在 `.assistant/`）+ 写入失败降级 + 回滚粒度验证，共 4 case（Q2 裁定后移除"ASSISTANT_ROOT 缺失"case）
  - 新增 `tests/verify-aionui-skill-contract.ps1`：adapter I/O + 白名单（含 implement 拒绝 + bogus 拒绝）+ codex/gemini 代理 + scope 解析三级（task 预留级跳过）+ invocation trace 两路径（有 Run N 成功追加 / 无 Run N 安全跳过）共 ~10 case
  - Phase 1 / Phase 2 产出的 16+N 个 `verify-*.ps1` 顺跑零回归（不含 `verify-installation.ps1`，其已从本 Phase mandatory 列表移除；见 Run 1 修订 B）
  - 所有新 `.ps1` UTF-8 BOM；新 `.md` / `.json` UTF-8 无 BOM；文件位置符合 `verify-lite-footprint.ps1` 既有路径约束

- 非目标:
  - 不扩 `SKILL.md` frontmatter（inputs / outputs 结构化 schema）——归 Phase 4+（architecture §3.5 第 6 步）
  - 不把 `implement` skill 包进 adapter（R11 / S11）；不替 implement 写结构化 I/O
  - 不实现 team preset spawn 或 `team_*` 桥（Phase 4）
  - 不引入新的 skill **目录**（避开 S12 / R13 的 `verify-lite-footprint.ps1:167-185` 白名单牵动）；只新增 `scripts/` 下的脚本
  - **不改 `install.ps1` / `uninstall.ps1`**（Run 1 修订 A）：`$claudeSkillsPath` / `$codexSkillsPath` 继续走现有硬编码；**不**引入 `HARNESS_ACTIVE_PROFILE` env 读取；**不**引入 `~/.claude-harness/active-profile` 文件读取；installer 的 skill 根目录选择不受本 Phase 任何文件影响
  - **不把 `verify-installation.ps1` 列入本 Phase mandatory Verification**（Run 1 修订 B）：该脚本需要 `-WorkspaceRoot` 参数，且本 Phase 无安装层改动；如需参数化 optional check 由执行者额外决定，不落入本 plan 的 Verification 列表
  - 不自动创建 `### Run N` 块或新 section 来容纳 invocation trace（Q4 / Run 1 修订 C）：若目标 stage section 下无任何 Run block，adapter 直接跳过 trace 写入
  - 不新增 `##` 二级 section 到 `plan.md`（invocation trace 走现有 run 内单行，不触 validator 段序）
  - 不修改 frontmatter 4-字段 schema
  - 不改 stdout `<stage> | <tool>` 契约；不修改 Phase 1 / Phase 2 既有测试的 exact-string 断言
  - 不把 `current-flow.md` 升格或降格；不改 `.assistant/工作流/共享记忆协议.md`
  - 不替 `review` / `test` skill 落地结构化脚本（Q1 暂留 stub；若 Leader 要求落地则 scope 扩）
  - task-level `skills_dir` 字段仅在三级解析器里**预留**入口，**不**写入任何 plan.md、**不**加 validator 校验（Q3）

- 受影响目录:
  - `scripts/invoke-harness-skill.ps1` — 新文件（adapter 主体）
  - `scripts/generate-skills-index.ps1` — 新文件（非原生 backend 的 skill index 生成器）
  - `scripts/advance-stage.ps1` — 推进尾部追加 best-effort manifest 写入；**不动** tool 解析 / stdout 契约
  - `skills/orchestrator/SKILL.md` — §调度规则追加 "adapter 优先，markdown fallback" 与 implement 禁入 adapter 两条
  - `skills/orchestrator/references/runbook.md` — §4 新增 "Skill invocation modes"（adapter / markdown / white-list / fallback）
  - `skills/orchestrator/references/default-tool-profiles.md` — 描述 `skills_dirs` 本 Phase 消费点：仅 `invoke-harness-skill.ps1` 的 user-level 兜底；**不**进入 install/uninstall
  - `skills/orchestrator/references/lite-writing-guide.md` — 说明 `skills-index.md` 位置与触发时机
  - `skills/orchestrator/references/state-templates.md` — 追加 `skill-manifest.json` 模板
  - `README.md` — 补 CLI 示例（adapter 调用 + manifest 产物 + skills-index 生成）
  - `tests/verify-aionui-skill-contract.ps1` — 新文件（validation-baseline 已列 gap）
  - `tests/verify-skill-manifest.ps1` — 新文件
  - `tests/verify-lite-footprint.ps1` — 评估是否需在合法 `scripts/*.ps1` 白名单加入新脚本（若现白名单按目录放行则免动）

- 回滚策略:
  - Phase 3 全 additive：删除两个新 `scripts/*.ps1` + 撤回 `advance-stage.ps1` 尾部 manifest hook + 撤回两个新测试 + 撤回文档段落 → 回到 Phase 2 末态；**本 Phase 未改 `install.ps1` / `uninstall.ps1`**，故无安装层回滚面
  - 单点失败隔离：
    - manifest 写入异常（目录只读 / 文件占用 / 任意 IO 错误）→ stderr 诊断，stage 推进照常（不影响 Phase 2 契约）；hook **不**读任何环境变量，所以不存在 "env 缺失" 分支
    - adapter 遇白名单外 skill → stdout 返回 `ok=false` 的合法 JSON + exit 非零；不产生真实副作用
    - adapter invocation trace：目标 stage section 无 `### Run N` 块 → 跳过追加，stderr 提示"no run block to append invocation trace"；plan.md 不发生任何写入，validator 段序不被破坏
  - invocation trace 是 append-only 单行到**既有 run**，**不触**新 section 顺序；撤回即整行删除，不影响 validator 段序

- ui: not-applicable

## User Confirmation
- status: confirmed
- note: 用户消息 "继续" 授权进入 Phase 3 规划（Leader 2026-04-24 指派）；Leader 2026-04-24 裁定 Q1–Q4（review/test stub 采纳 / manifest 采 per-task 路径 / task-level skills_dir 仅预留 / invocation trace 单行保留），Leader 2026-04-25 基于 Run 1 review 追加 3 条修订（收回 install/uninstall profile 驱动改造 / 从 mandatory verification 移除 verify-installation.ps1 / 收紧 invocation trace 合约只在既有 Run N 块追加），本 plan 已按全部裁定结果就地修订

## Change Contract
- change_type: feature
- affected_paths:
  - scripts/invoke-harness-skill.ps1
  - scripts/generate-skills-index.ps1
  - scripts/advance-stage.ps1
  - skills/orchestrator/SKILL.md
  - skills/orchestrator/references/runbook.md
  - skills/orchestrator/references/default-tool-profiles.md
  - skills/orchestrator/references/lite-writing-guide.md
  - skills/orchestrator/references/state-templates.md
  - README.md
  - tests/verify-aionui-skill-contract.ps1
  - tests/verify-skill-manifest.ps1

## Plan

- TODO 1 · `scripts/invoke-harness-skill.ps1`（adapter 主体）
  - `param([string]$TaskId, [string]$Stage, [string]$Skill, [string]$Tool, [string]$ToolProfileId, [string]$WorkspaceRoot, [string]$ArtifactRoot, [string]$Mode, [string]$PayloadJson)`
  - 硬编码白名单常量 `$AllowedSkills = @('review','test','gemini-designer-main','codex')`；`implement` 列入 `$DeniedSkills = @('implement')`，显式拒绝并在 stderr 写 "implement skill must be run by human; adapter refuses side-effect skills (S11 / R11)"
  - 白名单外 skill → `ok=false`，`errors=['skill not in adapter whitelist']`，exit 非零
  - 调度分支：
    - `skill=codex` → 要求 `Mode=readonly`（否则拒绝）；调 `skills/codex/scripts/ask_codex.ps1` with `-ReadOnly -Workspace $WorkspaceRoot` + payload 解出的 `Task` / `File[]` / `Session` / `Model` / `Reasoning`；捕获 `session_id=` / `output_path=` 注入 artifact_paths
    - `skill=gemini-designer-main` → 调 `skills/gemini-designer-main/scripts/invoke-gemini.ps1` with `-Workspace $WorkspaceRoot -Prompt <payload.prompt> -OutputFormat json -ApprovalMode plan -Model <payload.model?>`
    - `skill=review` / `skill=test` → stub：返回 `ok=true status=markdown-fallback errors=[]`；stderr 写 "review/test adapter is stub; fall back to Markdown-skill flow"（Q1 裁定已采纳）
  - 输出：`ConvertTo-Json -Compress -Depth 8 $result` 单行到 stdout（用 `[Console]::Out.WriteLine`，**绝不**用 `Write-Host`）
  - invocation trace（Q4 / Run 1 修订 C 合约）：
    1. 解析当前 stage → 目标 section（PLAN_REVIEW/CODE_REVIEW → `## Plan Review` / `## Code Review`；IMPLEMENT 禁入 adapter 故 N/A；TEST → `## Code Review` 若存在否则跳过；其余 stage 一律跳过）
    2. 在目标 `plan.md` 中扫描目标 section，查找该 section 下**最后一个** `### Run N` 块（使用 `^### Run \d+` regex + section 起止边界）
    3. 若找到 → 在该 Run 块末尾（下一 section 起始 / 文末之前）以 **append-only** 写入单行：`- invocation: skill=$Skill mode=adapter tool=$Tool ok=$($result.ok)`
    4. 若目标 section 不存在、或存在但无任何 `### Run N` 块 → **跳过写入**，stderr 输出 `"invocation trace skipped: no run block under <section>"`；退出码、stdout 不变
    5. **禁止**自动创建新 `### Run N` 块或新 section；**禁止**写 bare 顶层 `- invocation:`
    6. 使用 `System.Threading.Mutex`（命名 `"Global\invoke-harness-skill.plan-md.<hash>"`）保证并发下 append-only 语义
  - 文件必须 UTF-8 BOM 头（`verify-lite-footprint.ps1` 约束）

- TODO 2 · `scripts/generate-skills-index.ps1`
  - `param([string]$TaskId, [string]$Stage, [string]$BackendHint, [string]$OutputPath)`
  - 默认 `$OutputPath = "docs/tasks/$TaskId/skills-index.md"`
  - 读 `agent-configs/workflows/harness-lite.yaml`（复用 Phase 2 加的 YAML 解析工具；若 Phase 2 选了自写 parser，本脚本 dot-source 它；否则用同款 `ConvertFrom-Yaml`），取 `.stages.<Stage>.skills_whitelist`
  - 对每个 skill id 读 `skills/<id>/SKILL.md` 的 frontmatter `description` 字段，生成：
    ```markdown
    # Skills available at <Stage> (backend hint: <BackendHint>)

    - **<skill1>** — <description1>
    - **<skill2>** — <description2>
    ```
  - 输出 UTF-8 无 BOM；目录不存在则创建；已有文件覆盖并在首行写 `<!-- generated at <ISO8601> -->` 注释
  - 文件本身 UTF-8 BOM（`.ps1`）

- TODO 3 · `scripts/advance-stage.ps1` manifest 尾部 hook（per-task，Leader 裁定 Q2）
  - 在 stage 推进成功、`stdout` 已打印 `"$nextStage | $nextTool"` **之后**，加一个 try/catch 块：
    1. 构建 manifest 对象：`version=1 / task_id=$TaskId / stage=$nextStage / tool=$nextTool / available_commands=<read from harness-lite.yaml.stages.$nextStage.skills_whitelist, join SKILL.md description> / generated_at=<ISO8601>`
    2. 目标路径 `docs/tasks/$TaskId/skill-manifest.json`（相对 `$RepoRoot`）；该目录在推进当下一定存在（因为 plan.md 在其中），无需 `New-Item`
    3. `ConvertTo-Json -Depth 8 -Compress` + `Set-Content -Encoding UTF8NoBOM`（PS7）或 `[System.IO.File]::WriteAllText` + UTF8 NoBOM 编码器
    4. try 块 catch 任何异常 → stderr `"skill-manifest write skipped: $($_.Exception.Message)"`；**不**改退出码；**不**写 stdout
  - **不**读任何环境变量；**不**向 `.assistant/` 写入任何文件（Q2 明确禁用共享运行时写入面）
  - 不动 Phase 2 的 `Resolve-FallbackTool` 或 `Invoke-LiteArtifactValidator`；只在脚本最后（所有既有输出之后）追加本 hook
  - 与 Phase 2 `Warnings:` 段、stderr 回显完全正交：manifest hook 只在 stage 推进**成功路径**触发

- TODO 4 · Skill 作用域三级解析（在 `invoke-harness-skill.ps1` 内实现 `Resolve-ActiveSkillDirs`）
  - 解析顺序：
    1. **task-level**（预留）：读 `docs/tasks/$TaskId/plan.md` frontmatter 的 `skills_dir` 字段（本 Phase **确定不落地**该字段，解析器遇缺默认下沉；Q3）
    2. **project-level**：若 `./.assistant/skills` 目录存在 → 使用之
    3. **user-level**：`$env:USERPROFILE\.claude\skills`（现行为 / 默认兜底）
  - 任一级命中即停，不做多级 merge
  - 返回值是目录字符串；消费点：`invoke-harness-skill.ps1` 在查找 `skills/<id>/scripts/*.ps1` 时的前缀
  - 本 Phase 的适配**仅影响 adapter 代理路径的 skill 查找**；**不**影响 `install.ps1` 的 junction 目标（Run 1 修订 A：本 Phase 不改 install/uninstall，installer 继续走硬编码路径）

- TODO 5 · 测试
  - `tests/verify-aionui-skill-contract.ps1`：
    - A1 合法白名单：`invoke-harness-skill.ps1 -Skill review -Mode readonly …` → exit 0，stdout 恰 **一行** 合法 JSON，`ok=true status=markdown-fallback`，stderr 非空诊断
    - A2 implement 拒绝：`-Skill implement` → exit 非零，stdout `ok=false`，stderr 包含 "adapter refuses"
    - A3 bogus 拒绝：`-Skill nonexistent` → exit 非零，stdout `ok=false` + errors 提到 whitelist
    - A4 codex 非 readonly 拒绝：`-Skill codex -Mode writable` → 拒绝并提示 mode 约束
    - B1 codex 正例（若环境有 `codex` CLI）或 mock：注入假 `ask_codex.ps1` 验证参数透传
    - B2 gemini 正例：mock `invoke-gemini.ps1` 验证 `ApprovalMode=plan` + payload
    - C1 scope 解析：project-level 存在 → 返回 `.assistant/skills`；否则 user-level
    - C2 stdout 单行约束：**字节级** 断言 stdout 不含换行以外字符超过 1 行
    - D1 invocation trace 正例：fixture plan.md 已有 `## Plan Review` + `### Run 1` → adapter 调用后该 Run 1 块尾部出现单行 `- invocation: skill=review mode=adapter tool=codex ok=True`；plan.md 段序未变；validator 仍 PASS
    - D2 invocation trace 跳过：fixture plan.md 目标 section 为空或尚无 `### Run N` → adapter 调用后 plan.md **未被写入**（文件 hash 不变）；stderr 含 `"invocation trace skipped: no run block"`；stdout JSON `ok` 照常；validator 仍 PASS（Run 1 修订 C 专项）
  - `tests/verify-skill-manifest.ps1`（per-task 路径，Leader 裁定 Q2）：
    - E1 正例：跑一次 `advance-stage.ps1 -TaskId <fixture> -Tool codex`（在临时 repo fixture 内）→ 检查 `<fixture-repo>/docs/tasks/<fixture-task>/skill-manifest.json` 存在，JSON 通过 schema：`version=1`、`task_id` / `stage` / `tool` / `available_commands[]` / `generated_at`；**明确断言**文件 **不**出现在 `.assistant/` 下
    - E2 `available_commands` 等同 `harness-lite.yaml.stages.<next>.skills_whitelist`（元素集合相等，顺序可不同）
    - E3 写入失败降级（mock：把 `docs/tasks/<fixture-task>/` 标记为只读 / 占用 `skill-manifest.json` 文件锁）→ `advance-stage.ps1` 仍返回 exit 0，stderr 含 `"skill-manifest write skipped"`，stdout 最末行仍严格等于 `"<stage> | <tool>"`
    - E4 回滚验证：删除 `<fixture-repo>/docs/tasks/<fixture-task>/skill-manifest.json` → 无残留；证明 per-task 位置的清理粒度与 task 生命周期一致
    - **不**再覆盖 "ASSISTANT_ROOT 未设置" case（Q2 决议后 env 不再参与）
  - 测试文件遵循 `verify-lite-footprint.ps1`：UTF-8 BOM、`.ps1` 后缀、位置在 `tests/`
  - 不修改任何既有测试

- TODO 6 · 文档更新
  - `skills/orchestrator/SKILL.md`：§调度规则新增两句：(a)"优先调用 `scripts/invoke-harness-skill.ps1` 发起 skill；宿主不支持 JSON stdout 时 fallback 到 Markdown 纪律"；(b)"`implement` skill 必须由人类 / 主 agent 执行，adapter 层禁止分派"
  - `references/runbook.md`：新增 §4 "Skill invocation modes"：列白名单 / implement 禁入 / codex readonly 约束 / review/test 当前 stub 状态 / invocation trace "仅 append 到既有 Run N，无则跳过"合约
  - `references/default-tool-profiles.md`：**更新** `skills_dirs` 消费点说明：本 Phase 仅 `invoke-harness-skill.ps1`（三级解析 user-level 兜底）消费；**不**进入 `install.ps1` / `uninstall.ps1`（Run 1 修订 A）
  - `references/lite-writing-guide.md`：补 "skills-index.md" 段落（位置、触发时机、非原生 backend 场景）；附 invocation trace 合约提示（仅 Run N 内）
  - `references/state-templates.md`：追加 `skill-manifest.json` 模板（明标路径 `docs/tasks/<task-id>/skill-manifest.json`）与 `skills-index.md` 结构样板
  - `README.md`：追加两条 CLI 示例（adapter 调用 / skills-index 生成）、一段 "skill-manifest.json 是 per-task best-effort 产物、与 plan.md 同目录、不是真相源、不写入 `.assistant/`" 说明

- TODO 7 · 回归 + smoke（不修改既有测试源文件）
  - 跑 Phase 1 / 2 / 3 全套：`verify-workflow-contracts.ps1` / `verify-tool-profile.ps1` / `verify-workflow-descriptor.ps1` / `verify-lite-artifact-validator.ps1` / `verify-lite-footprint.ps1` / `verify-update-managed-assets.ps1` / `verify-aionui-skill-contract.ps1` / `verify-skill-manifest.ps1`（**不含** `verify-installation.ps1`，Run 1 修订 B）
  - 任一非零 → 回到 IMPLEMENT 排查（优先回查 adapter stdout 误污染 / manifest hook 误抛异常 / invocation trace 误写无 Run N 场景）
  - 手工 smoke 三条：
    1. `invoke-harness-skill.ps1 -Skill codex -Mode readonly -TaskId <smoke> …` → stdout 单行合法 JSON，plan.md（若存在 `### Run N`）出现 invocation trace；无 Run N → plan.md 不变 + stderr skip 消息
    2. `advance-stage.ps1 -TaskId <smoke> -Tool codex` → `docs/tasks/<smoke>/skill-manifest.json` 生成且 schema 通过；`.assistant/运行时/` 下**不应**出现 `skill-manifest.json`（Q2 验证）
    3. `generate-skills-index.ps1 -TaskId <smoke> -Stage IMPLEMENT -BackendHint kimi` → 生成文件内容与 harness-lite.yaml 一致

## Verification

- `pwsh -File .\tests\verify-aionui-skill-contract.ps1`
- `pwsh -File .\tests\verify-skill-manifest.ps1`
- `pwsh -File .\tests\verify-workflow-descriptor.ps1`
- `pwsh -File .\tests\verify-workflow-contracts.ps1`
- `pwsh -File .\tests\verify-tool-profile.ps1`
- `pwsh -File .\tests\verify-lite-artifact-validator.ps1`
- `pwsh -File .\tests\verify-lite-footprint.ps1`
- `pwsh -File .\tests\verify-update-managed-assets.ps1`
- `pwsh -File .\scripts\advance-stage.ps1 -TaskId <smoke> -Tool codex`

覆盖意图：
- 新 `verify-aionui-skill-contract.ps1`：adapter I/O 契约（stdout 单行 JSON）+ 白名单（implement/bogus/codex-mode 三路拒绝）+ 代理透传（codex/gemini）+ 三级 scope 解析 + invocation trace 两路径（有 Run N 成功追加 / 无 Run N 安全跳过），共 ~10 case
- 新 `verify-skill-manifest.ps1`：manifest schema + per-task 路径（`.assistant/` 下不出现）+ best-effort 写失败降级 + available_commands 与 workflow descriptor 一致性 + 回滚粒度，共 4 case
- `verify-workflow-descriptor.ps1` / `verify-tool-profile.ps1` 确认 Phase 2 fallback 三级 + Phase 1 `-Profile` 回归零破坏
- `verify-lite-artifact-validator.ps1` 确认 Phase 2 `Warnings:` 段 + 本 Phase 未新增 section 的约束成立；特别验证 invocation trace "无 Run N 跳过" 场景下 plan.md 通过 validator
- `verify-installation.ps1` **不**在本 Phase mandatory 列表（Run 1 修订 B）：本 Phase 无安装层改动，且该脚本需 `-WorkspaceRoot` 参数；如需安装层 smoke 由执行者以 optional 带参方式单独跑
- Smoke 三条链路肉眼核验：adapter stdout / manifest 写入 / skills-index 文件

## Risks

- **R0（最高）· `implement` skill 误入 adapter 白名单**：若 TODO 1 把 `implement` 漏进 `$AllowedSkills` 或 deny 列表缺失，adapter 会自动分派真实代码修改（S11 / R11 列为项目级最高风险）。缓解：(a) 白名单 / 黑名单常量集中写在脚本顶部；(b) TODO 5 A2 case 锁死 implement 必被拒绝；(c) 文档 TODO 6 SKILL.md 与 runbook 双处明写 "implement 必须人类执行"；(d) code review 专项 checklist
- **adapter stdout 被诊断文本污染**：若内部误用 `Write-Host` / `Write-Output` 输出进度，stdout 将破坏 "单行 JSON" 契约，下游消费者（AionUi / CI）解析失败。缓解：强制 `[Console]::Out.WriteLine(ConvertTo-Json -Compress …)`、诊断走 `[Console]::Error.WriteLine`；TODO 5 C2 字节级断言 stdout **行数=1**
- **manifest 写入异常阻塞 stage 推进**：若 TODO 3 的 hook 未 try/catch 吞住异常，会让原本成功的 `advance-stage.ps1` 变成非零退出，破坏 Phase 2 契约。缓解：hook 全程 try/catch 且 catch 分支仅 stderr 诊断；TODO 5 E3 专项（只读 / 文件占用模拟）
- **invocation trace 误创建 section / bare 行破坏 validator 段序**（Q4 / Run 1 修订 C）：若 TODO 1 误把"无 Run N"路径实现为"自动创建 Run 0"或"在 section 首行追加 bare `- invocation:`"，会破坏 lite artifact 结构、污染段序。缓解：(a) adapter 实现对"无 Run N"必须 **零 plan.md 写入**；(b) TODO 5 D2 case 用文件 hash 断言零写入；(c) validator 对 fixture plan.md 跑 PASS 作为二道门
- **skill scope 预留字段 UX 误导**：文档若不明示 `skills_dir` 是 "预留未启用"，读者可能今天就在 plan.md 里写该字段并期望生效。缓解：TODO 4 解析器遇字段静默忽略；TODO 6 `lite-writing-guide.md` / `runbook.md` 明标 "本 Phase 预留，暂不读入"
- **Phase 2 未实装就 IMPLEMENT Phase 3 的顺序耦合**：TODO 3 manifest hook 读 `harness-lite.yaml`；若 Phase 2 实际实装把 YAML parser 绑在 `Resolve-FallbackTool` 私有作用域，本 Phase hook 无法 dot-source。缓解：(a) IMPLEMENT 前确认 Phase 2 任务 `529cf558 / bff6d431` 完成；(b) 若 YAML parser 是私有的，本 Phase 独立再 inline 一份（TODO 2/3 的 parser 可共用）；(c) 不跨 Phase 依赖内部函数，只读文件
- **invocation trace 写入冲突**：并发 stage skill 调用（不常见但不排除）可能破坏 plan.md append-only 语义。缓解：TODO 1 用 `System.Threading.Mutex` 或临时 lock 文件；TODO 5 D1 单线程 case 先锁 happy path，并发测试延到 Phase 3.1 或不做
- **ACP schema 漂移**（R2）：AionUi 日后改 `available_commands_update` 字段，本 Phase manifest 会过时。缓解：manifest 自带 `version:1`；consumer 侧自负适配；harness 不做前瞻兼容
- **per-task manifest 与 `.assistant/` 混淆**（Q2 裁定后新增）：Leader 已采 per-task 路径，但 IMPLEMENT 阶段若实现者误把 manifest 同时写入 `.assistant/运行时/`（延续 architecture §3.5 原文），会再度引入共享运行时写入面。缓解：TODO 3 明写 "不读 ASSISTANT_ROOT / 不写 `.assistant/`"；TODO 5 E1 断言 `.assistant/` 下无 `skill-manifest.json`；code review checklist 加此项
- **Q1 stub 的下游感知**：`review` / `test` adapter 走 stub（Leader 已采纳），consumer 拿到 `status=markdown-fallback` 后必须回退到 Markdown 流程。若未来 AionUi 消费者未处理该 status，可能把 stub 误当失败。缓解：manifest / adapter 文档明示 `markdown-fallback` 是合法成功态；`ok=true` 即视作成功，消费者不应看 status 反向判失败

## Plan Review

### Run 1 · 2026-04-25 00:39 · runner: harness-reviewer
- verdict: revise
- findings:
  - P1: TODO 4 is not Phase 1/2-compatible as written. It resolves a single `HARNESS_ACTIVE_PROFILE` / `active-profile` id, defaults it to `harness-default-claude`, then applies one `skills_dirs[0]` to both `$claudeSkillsPath` and `$codexSkillsPath` (`docs/tasks/phase3-acp-skill-alignment/plan.md:127`-`docs/tasks/phase3-acp-skill-alignment/plan.md:135`). Current shipped profiles are backend-specific and point to different relative directories (`agent-configs/profiles/harness-default-claude.yaml:4`-`agent-configs/profiles/harness-default-claude.yaml:5`, `agent-configs/profiles/harness-default-codex.yaml:4`-`agent-configs/profiles/harness-default-codex.yaml:5`), while the current installer uses separate host roots (`install.ps1:1119`-`install.ps1:1120`). As written, the plan would route Codex installs through the Claude skills dir or vice versa unless it defines a per-backend resolution/normalization contract. That reopens already-validated Phase 1 profile semantics instead of building on them.
  - P1: Verification is still not executable as written because it again treats `verify-installation.ps1` as a plain no-arg script (`docs/tasks/phase3-acp-skill-alignment/plan.md:175`, `docs/tasks/phase3-acp-skill-alignment/plan.md:191`), but the script requires mandatory `-WorkspaceRoot` (`tests/verify-installation.ps1:2`-`tests/verify-installation.ps1:8`). This is the same Phase 2 failure mode and blocks an IMPLEMENT-ready review gate.
  - P2: Q4 invocation-trace writeback is not implementation-ready under lite artifact rules. The plan requires appending a single `- invocation:` line into the "current stage's latest run" (`docs/tasks/phase3-acp-skill-alignment/plan.md:16`, `docs/tasks/phase3-acp-skill-alignment/plan.md:64`, `docs/tasks/phase3-acp-skill-alignment/plan.md:100`, `docs/tasks/phase3-acp-skill-alignment/plan.md:156`), but it does not define what happens when the target section has no run block yet. Once `Plan Review` / `Implementation Notes` / `Code Review` are non-empty, validator requires `### Run N` blocks with mandatory structure (`scripts/validate-lite-artifacts.ps1:750`, `scripts/validate-lite-artifacts.ps1:801`, `scripts/validate-lite-artifacts.ps1:805`, `scripts/validate-lite-artifacts.ps1:832`). A bare appended bullet would invalidate the artifact, so the plan still needs an explicit host/run-block provisioning contract before IMPLEMENT.
- next: Revise the install-path contract, parameterized verification commands, and invocation-trace writeback contract before entering IMPLEMENT.

### Run 2 · 2026-04-25 00:51 · runner: harness-reviewer
- verdict: pass
- findings: none
- evidence: In this review scope, the three Run 1 blockers are now closed: the install/uninstall profile-driven change has been fully removed from Phase 3 scope with no conflicting residue in Clarification / Non-goals / affected paths / rollback / verification (`docs/tasks/phase3-acp-skill-alignment/plan.md:13`-`docs/tasks/phase3-acp-skill-alignment/plan.md:17`, `docs/tasks/phase3-acp-skill-alignment/plan.md:31`-`docs/tasks/phase3-acp-skill-alignment/plan.md:41`, `docs/tasks/phase3-acp-skill-alignment/plan.md:43`-`docs/tasks/phase3-acp-skill-alignment/plan.md:56`, `docs/tasks/phase3-acp-skill-alignment/plan.md:57`-`docs/tasks/phase3-acp-skill-alignment/plan.md:65`); `verify-installation.ps1` has been fully removed from the mandatory Verification/gate path (`docs/tasks/phase3-acp-skill-alignment/plan.md:26`, `docs/tasks/phase3-acp-skill-alignment/plan.md:34`, `docs/tasks/phase3-acp-skill-alignment/plan.md:175`-`docs/tasks/phase3-acp-skill-alignment/plan.md:200`); and the invocation trace contract is now explicitly constrained to append only inside an existing `### Run N` block, otherwise safely skip with stderr diagnostics and zero artifact mutation (`docs/tasks/phase3-acp-skill-alignment/plan.md:16`, `docs/tasks/phase3-acp-skill-alignment/plan.md:64`, `docs/tasks/phase3-acp-skill-alignment/plan.md:98`-`docs/tasks/phase3-acp-skill-alignment/plan.md:100`, `docs/tasks/phase3-acp-skill-alignment/plan.md:107`-`docs/tasks/phase3-acp-skill-alignment/plan.md:116`, `docs/tasks/phase3-acp-skill-alignment/plan.md:145`-`docs/tasks/phase3-acp-skill-alignment/plan.md:161`, `docs/tasks/phase3-acp-skill-alignment/plan.md:202`-`docs/tasks/phase3-acp-skill-alignment/plan.md:209`).
- next: Plan is ready to enter IMPLEMENT for the scoped items reviewed in Run 2.

## Implementation Notes

## Code Review
