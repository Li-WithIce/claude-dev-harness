---
task_id: shared-memory-v2-optimization
stage: PLAN
tool: claudecode
updated: 2026-04-27
---
# Shared Memory v2 · Structure Optimization

本任务直接优化 `.assistant/` 共享记忆的结构与架构，不展开通用 workflow 改动。基线是当前 `vault-template/工作流/共享记忆协议.md`（schema-versions.md `shared-memory-core: 1.1`）+ `写回协议.md` + `恢复协议.md` + `任务识别协议.md` + `task-runtime: 1.1`。Phase 4（team preset bridge）已闭环；本任务在 Phase 4 已固化的两条目录级前缀（`.assistant/`、`docs/tasks/<task-id>/`）和单写者模型基础上做收紧，不重写既有协议，不引入第二套 vault。

PLAN_REVIEW Run 1 三条 finding 已合并：
- 把 vault/script 解析热路径（`Resolve-SharedMemoryVaultRoot` / `resolve-obsidian-memory-script.ps1` / `runtime-inbox-common.ps1`）纳入收口范围，真正减少多源歧义，而不是仅在文档层声明唯一 vault。
- 把 `entry_host` / `derived_from` / best-effort writeback 契约下沉到三个 live hot writer（`scripts/advance-stage.ps1`、`skills/obsidian-memory/scripts/repair-shared-memory.ps1`、`runtime-hooks/claude/posttooluse.js`），不仅停在模板与静态 checker。
- Verification 直接对齐到共享记忆回归链（verify-repair-shared-memory / verify-runtime-hooks / verify-runtime-inbox / verify-promote-runtime-inbox / verify-memory-maintain / verify-memory-health-report / verify-archive-memory-candidates / verify-triage-runtime-inbox），不再泛跑 Phase 1-4 全套。

## Clarification

- 验收标准:
  - 把 4 层真相源关系写死成机器可读的"层映射表"，单一来源；新增协议或工具入口必须先引用该表，不再分散到各协议里描述。4 层是 `artifact`（`docs/tasks/<task-id>/`）/ `runtime`（`.assistant/运行时/`）/ `config`（`.assistant/配置/`）/ `workflow`（`.assistant/工作流/`）；artifact 层的 `plan.md` frontmatter `stage/tool` 是 task-stage 的唯一真相源
  - `.assistant/` 唯一真相源：明文写"项目本地 `<workspace>/.assistant/` 是当前任务的 vault；不再支持 dual vault 同时激活"；保留 user-level Companion Starter vault 作为长期跨项目偏好仓库（仅 `配置/*.md` 与 `工作流/*.md`），但**当前任务运行时**只能写项目本地 `.assistant/运行时/`（schema-versions.md 的 `task-runtime`、`current-task-pointer`、`recovery-index` 都属此处）
  - 写回阶梯固化为单向链：`docs/tasks/<task-id>/plan.md` → `.assistant/运行时/tasks/<task-id>.md` → `.assistant/运行时/当前任务.md` → `.assistant/运行时/恢复索引.md`；上一节点是下一节点的真相输入，反向不允许；team task-board（`team_task_update`）是 vault 的**镜像**而非真相源，沿用 Q5(a) doc-only ban
  - `当前任务.md` 增 `entry_host` 字段（值域 = `claudecode | codex | gemini | team-leader`），与 `entry_tool` 配合判定单写者；缺失时按 `task-runtime/v1.0-legacy` fallback 读 latest writer
  - `恢复索引.md` 与 `中断任务.md` 显式标记为派生视图：frontmatter 增机器可读字段 `derived_from:` 列出源文件路径（`恢复索引.md` 的 `derived_from` = [`运行时/当前任务.md`, `运行时/tasks/`, `运行时/中断任务.md`]；`中断任务.md` 的 `derived_from` = [`运行时/tasks/`]）；并约束 reader：恢复时若任一源 `updated` > 派生视图 `updated`，先刷新再读（恢复协议已有此规则，本轮把它写进 frontmatter）
  - 单写者锁契约写明：`运行时/runtime.lock.json` 必须含 `writer / task_id / locked_at / entry_host`；锁失败即 `[lock-blocked]` 转 `运行时/收件箱.md`；30 分钟超时；本轮不引入运行时强制 hook，沿用静态测试拦截
  - 最小写入面：单次 stage 推进的强制写入面**只**是 `docs/tasks/<task-id>/plan.md` frontmatter 一处；`运行时/tasks/<task-id>.md` / `当前任务.md` / `恢复索引.md` 的写入降级为 best-effort（失败仅记 stderr 诊断 + 写 `收件箱.md`，不阻塞推进）
  - 校验脚本：`scripts/check-shared-memory-layers.ps1`（新）扫描层映射一致性 + 写回阶梯方向 + `entry_host` 必填 + `恢复索引.md` 派生视图标记 + `runtime.lock.json` schema；`tests/verify-shared-memory-layers.ps1`（新）作为静态拦截入口，集成进 `verify-lite-footprint.ps1` 路径白名单
  - 不破坏既有 schema 版本：`shared-memory-core` 升 `1.2`、`current-task-pointer` 升 `1.1`、`recovery-index` 升 `1.1`、`task-runtime` 维持 `1.1`；旧文件按 legacy 兼容读
  - Leader 已裁定（baked-in）:
    - D1 user-level Companion Starter vault 保留，但**严格收口**到跨项目偏好：仅承载 `配置/*.md` + `工作流/*.md`，禁止任何 `运行时/` 子目录；项目本地 `<workspace>/.assistant/` 是任务级运行时唯一真相源
    - D2 team task-board 与 vault 关系本 Phase 保持手工 / doc-only：不引入 `team_task_update` 自动 mirror hook；leader 写完 vault 后由人工或上游编排触发 board 镜像，与 Q5(a) 一致
    - D3 派生视图标记用机器可读 frontmatter 字段 `derived_from:`（值为来源文件路径数组），不用 Markdown 引用块；`recovery-index/v1.1` 与 `中断任务.md` 都纳入此契约

- 非目标:
  - **不**改 `harness-lite` workflow descriptor / `plan.md` frontmatter 4 字段 schema / stage 集合 / tool 枚举
  - **不**改 Phase 4 已固化的 `members_read_only_path_prefixes` 集合（`.assistant/` + `docs/tasks/<task-id>/`），也**不**改 `docs/team-write-authority.md` 的两条目录级前缀
  - **不**新增第二个 runtime hook（沿用 `runtime-hooks/claude/posttooluse.js`，本 Phase 仅在该 hook 与 `advance-stage.ps1` / `repair-shared-memory.ps1` 既有写入面上做最小 conformance 改动）
  - **不**实装 `team_task_update` → vault 自动反向 sync（沿用 Q5(a) 仅文档化，Leader D2 已裁定）
  - **不**改 `MEMORY.md`、`配置/引导状态.md` 含义（继续禁写运行时任务到这两处）
  - **不**改长期记忆候选 / 归档 / TTL 流程（`记忆管理协议.md` 范围）
  - **不**改恢复协议三段式回复格式
  - **不**新增 user-level vault 自动同步机制
  - **不**修改 `validate-lite-artifacts.ps1` 主体逻辑（输出契约字节级一致）
  - **不**碰 Phase 1/2/3 既有测试的 exact-string 断言；本 Phase 仅允许更新与 scoped shared-memory writer conformance 直接相关的 `verify-repair-shared-memory.ps1` / `verify-runtime-hooks.ps1` / `verify-promote-runtime-inbox.ps1` 中针对 `当前任务.md` / `运行时/tasks/<task-id>.md` / `恢复索引.md` / `runtime.lock.json` 的固定字符串或最小合同断言（新增 `entry_host` / `derived_from` 期望值），不扩大到其他测试

- 受影响目录:
  - `vault-template/工作流/共享记忆协议.md` — 顶部新增"4 层真相源映射表"段；写回阶梯链一段；唯一项目本地 vault 段
  - `vault-template/工作流/写回协议.md` — 把"写回阶梯"段写死为单向链；标注 best-effort fallback
  - `vault-template/工作流/恢复协议.md` — 把"派生视图"标记规则写入；reader 一致性检查升级为 hard rule
  - `vault-template/工作流/任务识别协议.md` — 增 `entry_host` 字段判定，沿用既有 5 步顺序
  - `vault-template/配置/schema-versions.md` — 升级 `shared-memory-core: 1.2` / `current-task-pointer: 1.1` / `recovery-index: 1.1`，并在 `task-runtime/v1.1` 最低字段表加 `entry_host`
  - `vault-template/模板/任务状态模板.md` — 模板 frontmatter 加 `entry_host` 字段示例
  - `vault-template/运行时/当前任务.md.template` — frontmatter 加 `entry_host:` 字段
  - `vault-template/运行时/恢复索引.md.template` — frontmatter 加 `derived_from:` 字段（D3 落地）
  - `vault-template/运行时/中断任务.md.template` — frontmatter 加 `derived_from:` 字段（D3 落地）
  - `scripts/check-shared-memory-layers.ps1` — 新文件（层映射 + 写回方向 + lock schema 静态扫描；UTF-8 BOM）
  - `tests/verify-shared-memory-layers.ps1` — 新文件（5 case 静态拦截；UTF-8 BOM）
  - `tests/verify-lite-footprint.ps1` — 路径白名单加 `tests/verify-shared-memory-layers.ps1` + `scripts/check-shared-memory-layers.ps1`
  - `skills/obsidian-memory/scripts/check-shared-memory.ps1` — 增加 `entry_host` 字段读出 + `derived_from:` frontmatter 静态扫描；不改既有断言
  - `docs/aionui-integration/team-preset.md` — 加一段引用本任务的层映射表，明确 team-mode 下 leader 是 `entry_host` 之一
  - `docs/shared-memory-layers.md` — 新文件，作为 4 层真相源映射的唯一真相源（其他文档仅引用此处，不复述）
  - `skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1` — 收紧 `Resolve-SharedMemoryVaultRoot` 候选优先级（显式 `-VaultRoot` / `CLAUDE_DEV_HARNESS_VAULT_PATH` / `OBSIDIAN_SHARED_VAULT` 优先；workspace anchored 次之；cwd-anchored 仅 fallback；候选解析到不同物理 vault 时 stderr `[vault-ambiguous]`）；新增 `Assert-ProjectLocalVault` helper（拒绝指向 user-level agent home 内含 `运行时/` 的 vault）
  - `scripts/resolve-obsidian-memory-script.ps1` — 区分 runtime-touching script 集合（`append-runtime-inbox` / `promote-runtime-inbox` / `triage-runtime-inbox` / `repair-shared-memory` / `archive-memory-candidates` / `maintain-shared-memory` / `run-memory-health` / `write-memory-health-report`）；这些脚本默认不再走 `$USERPROFILE/.claude` 等 agent home fallback，除非 `CLAUDE_DEV_HARNESS_ALLOW_AGENT_HOME=1` 显式 opt-in；read-only 类如 `check-shared-memory.ps1` 维持原 fallback
  - `skills/obsidian-memory/scripts/runtime-inbox-common.ps1` — 在 `Get-RuntimeMarkdownPaths` 入口调用 `Assert-ProjectLocalVault`；增 helper `Get-EntryHostValue`（按 `$env:CLAUDE_DEV_HARNESS_ENTRY_HOST` → 调用方传入 → fallback `unknown` 顺序解析）；不改 inbox 表格结构 / schema_version
  - `scripts/advance-stage.ps1` — `Build-CurrentTaskContent` frontmatter 增 `entry_host: claudecode`（advance-stage 是 claudecode 内部调用，常量即可）；`Write-RecoveryIndex` 顶部 frontmatter 增 `derived_from: [运行时/tasks/]`；写 `当前任务.md` / `tasks/<id>.md` / `恢复索引.md` 三步降级为 best-effort（每步 try/catch，失败 stderr `[writeback-fallback]` + 调 `append-runtime-inbox.ps1` 写收件箱，不阻塞主推进）；`plan.md` frontmatter 写入仍是强制
  - `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1` — interrupted-task promotion 是 live task-runtime writer；`New-TaskRuntimeDocument` frontmatter 必须显式带 `entry_host:`（由 `-EntryHost` 参数或 `Get-EntryHostValue` 解析，默认 `unknown`），避免 promoted task-runtime 掉回无 writer-host 标识的 legacy 形态
  - `skills/obsidian-memory/scripts/repair-shared-memory.ps1` — 写 `当前任务.md` 时 frontmatter 增 `entry_host`（值由 `-EntryHost` 参数或 `Get-EntryHostValue` 获取，默认 `unknown`）；写 `恢复索引.md` 时增 `derived_from: [运行时/tasks/, 运行时/中断任务.md]`；`runtime.lock.json` schema 增 `entry_host` 字段；保留既有 30 分钟超时 / lock-blocked inbox 行为
  - `runtime-hooks/claude/posttooluse.js` — 重建 `恢复索引.md` 时 frontmatter 增 `derived_from: [运行时/当前任务.md, 运行时/tasks/]`；写 `runtime.lock.json` 时 lock 对象增 `entry_host: "claudecode"`；`appendLockBlockedInbox` 在 lock 非 `claudecode` 写入时同步标记 `entry_host_mismatch`；保留 30 分钟过期 / 当前 idle 短路逻辑
  - `tests/verify-repair-shared-memory.ps1` / `tests/verify-runtime-hooks.ps1` — fixture 与断言扩展以匹配新增 `entry_host` / `derived_from` 字段；不改既有 case 总数；不改 inbox 行 schema

- 回滚策略:
  - 全 additive + 兼容；回滚步骤 =
    - 删除 `docs/shared-memory-layers.md`
    - 删除 `scripts/check-shared-memory-layers.ps1` / `tests/verify-shared-memory-layers.ps1`
    - 撤回 4 个协议文件的新增段落
    - 把 schema-versions.md 三个版本号回退至 `1.1` / `1.0` / `1.0`
    - 删 3 个 vault-template 模板里的 `entry_host` / `derived_from:` 字段
    - 撤回 `verify-lite-footprint.ps1` 路径白名单两条扩展
    - 撤回 `resolve-shared-memory-paths.ps1` 候选优先级收紧（恢复原 8 候选顺序）+ 删 `Assert-ProjectLocalVault` helper
    - 撤回 `resolve-obsidian-memory-script.ps1` runtime-touching 集合判断 + 恢复无条件 agent-home fallback
    - 撤回 `runtime-inbox-common.ps1` 的 `Assert-ProjectLocalVault` 入口与 `Get-EntryHostValue` helper
    - 撤回 `advance-stage.ps1` / `repair-shared-memory.ps1` / `posttooluse.js` 三处 hot writer 的 `entry_host` / `derived_from` 字段写入与 best-effort 包裹（恢复原同步阻塞写）
    - 撤回 `verify-repair-shared-memory.ps1` / `verify-runtime-hooks.ps1` 的字段扩展
  - 单点失败隔离:
    - 新静态扫描脚本失败 → 仅静态测试 FAIL，不影响 `validate-lite-artifacts.ps1` / `advance-stage.ps1` 主路径
    - `entry_host` 字段缺失 → 按 `task-runtime/v1.0-legacy` 读，回退到 latest writer 推断；不阻塞恢复
    - best-effort writeback 失败（如 `运行时/tasks/<id>.md` 写入异常）→ 仅 stderr 诊断 + 写 `收件箱.md`；`plan.md` 推进不回滚
    - 锁文件 schema 缺字段 → reader 回退到 v1 schema，标记为 `[legacy-lock]` 但不拒绝
    - resolver 收紧后误拒合法 vault → 设置 `CLAUDE_DEV_HARNESS_ALLOW_AGENT_HOME=1` 临时放行；并 stderr 诊断
  - 回滚验证：删除上述新文件后跑 `validate-lite-artifacts.ps1` + 共享记忆回归链（verify-repair-shared-memory / verify-runtime-hooks / verify-runtime-inbox / verify-promote-runtime-inbox / verify-memory-maintain / verify-memory-health-report / verify-archive-memory-candidates / verify-triage-runtime-inbox）+ `verify-lite-footprint.ps1` + `verify-workflow-contracts.ps1` → 应全部 PASS

- ui: not-applicable

## User Confirmation
- status: confirmed
- note: 本 plan 直接落到 `.assistant/` 共享记忆结构层；前置 = Phase 4 闭环；Leader 已裁定 D1/D2/D3（user-level vault 保留但严格收口到跨项目偏好；team-board mirror 保持手工 / doc-only；派生视图用 `derived_from:` frontmatter 字段）；PLAN_REVIEW Run 1 三条 finding（resolver 收口 / hot writer conformance / verification 对齐共享记忆链）已合并；本轮已按"4 必修项"全数覆盖（drift / dual-vault / truth-layering / single-writer minimal-surface）

## Change Contract
- change_type: refactor
- affected_paths:
  - vault-template/工作流/共享记忆协议.md
  - vault-template/工作流/写回协议.md
  - vault-template/工作流/恢复协议.md
  - vault-template/工作流/任务识别协议.md
  - vault-template/配置/schema-versions.md
  - vault-template/模板/任务状态模板.md
  - vault-template/运行时/当前任务.md.template
  - vault-template/运行时/恢复索引.md.template
  - vault-template/运行时/中断任务.md.template
  - scripts/check-shared-memory-layers.ps1
  - tests/verify-shared-memory-layers.ps1
  - tests/verify-lite-footprint.ps1
  - skills/obsidian-memory/scripts/check-shared-memory.ps1
  - docs/aionui-integration/team-preset.md
  - docs/shared-memory-layers.md
  - skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1
  - scripts/resolve-obsidian-memory-script.ps1
  - skills/obsidian-memory/scripts/runtime-inbox-common.ps1
  - scripts/advance-stage.ps1
  - skills/obsidian-memory/scripts/promote-runtime-inbox.ps1
  - skills/obsidian-memory/scripts/repair-shared-memory.ps1
  - runtime-hooks/claude/posttooluse.js
  - tests/verify-promote-runtime-inbox.ps1
  - tests/verify-repair-shared-memory.ps1
  - tests/verify-runtime-hooks.ps1

## Plan

- TODO 1 · `docs/shared-memory-layers.md`（4 层真相源映射，唯一来源）
  - 新文件，UTF-8 无 BOM，结构：`## Layers` 表格列出 4 层（artifact / runtime / config / workflow）+ 每层路径前缀 + 唯一写者 + 真相程度（authoritative / derived / advisory）+ 允许的 reader；`## Writeback Ladder` 单向链 plan.md → tasks/<id>.md → 当前任务.md → 恢复索引.md；`## Forbidden Reverse Edges` 列出禁止的反向写
  - 文档明确：`plan.md` frontmatter `stage/tool` 是 task-stage 唯一真相源；`team_task_update` 写入仅作为 AionUi UI 镜像，**不**改 vault 任何字段
  - 引用关系：所有协议文件 / role-prompt / orchestrator runbook 引用本文件，不复述同内容

- TODO 2 · `vault-template/工作流/共享记忆协议.md` 顶部加"4 层真相源映射"段（一行 + 链接到 TODO 1）
  - 在 `## 共享根目录` 段下面加 `## 真相源分层` 子段：一段说明 + 表格指向 `docs/shared-memory-layers.md`
  - 在 `## 单写者模型` 段中明确 `entry_host` 字段语义；保留既有 `entry_tool`，写明二者关系（`entry_host` 是 agent 平台标识，`entry_tool` 是 backend 标识）
  - 强调 user-level Companion Starter vault 仅承载跨项目长期偏好（`配置/*.md` + `工作流/*.md`）；**任务级运行时（`运行时/`）只在项目本地 `<workspace>/.assistant/` 写**
  - 写明 best-effort writeback fallback 路径：写失败 → stderr + `收件箱.md` `[writeback-fallback]` 标记；plan.md 主推进不回滚

- TODO 3 · `vault-template/工作流/写回协议.md` 写死写回阶梯
  - 在 `## 写回规则` 段顶部加 `## 写回阶梯（单向链）` 子段：固定 4 步：(1) `docs/tasks/<task-id>/plan.md` frontmatter 是 stage 真相源；(2) 同步 `运行时/tasks/<task-id>.md` 详细状态；(3) 刷新 `运行时/当前任务.md` 共享指针；(4) 刷新 `运行时/恢复索引.md`
  - 标注步骤 (2)/(3)/(4) 为 best-effort（失败 → stderr + `收件箱.md`，不阻塞 stage 推进）
  - 加 `## 团队任务面板镜像` 子段：team-mode 下 `team_task_update` 仅在写完 vault 后由 leader 一次性 mirror；vault 永远是真相源
  - 不改既有 1/2/3 步骤文本

- TODO 4 · `vault-template/工作流/恢复协议.md` 派生视图 hard rule
  - 在 `## 读取顺序` 第 1 步前加 `## 派生视图标记`：`恢复索引.md` 与 `中断任务.md` 是派生视图；reader 在读取前必须做时间戳一致性检查（既有规则升级为 hard）
  - 一致性检查失败时的强制刷新顺序：先刷 `当前任务.md` → 再刷 `恢复索引.md` → 重新读取
  - `恢复索引.md` 与 `中断任务.md` frontmatter 增机器可读字段 `derived_from:`（来源文件路径数组）；`check-shared-memory-layers.ps1` 静态校验该字段存在且至少含一条非空非占位路径
  - 不改三段式恢复回复格式

- TODO 5 · `vault-template/工作流/任务识别协议.md` 增 `entry_host` 字段
  - 在 `## 任务状态文件最低匹配键` 表中加一行 `entry_host`
  - 在 `## 派生规则` 后加 `## 单写者判定`：`entry_host` 字段决定本次写入是否合法；缺失 → fallback 到 latest writer 推断（保持 v1.0-legacy 兼容）

- TODO 6 · `vault-template/配置/schema-versions.md` 升级
  - `shared-memory-core` 升 `1.2`（4 层映射表 + 写回阶梯写死）
  - `current-task-pointer` 升 `1.1`（增 `entry_host` 字段）
  - `recovery-index` 升 `1.1`（增 frontmatter `derived_from:` 字段；同步约束 `中断任务.md` 派生视图也使用该字段）
  - `task-runtime/v1.1` 最低字段表加 `entry_host`
  - 兼容策略保持：未声明版本按 legacy 读

- TODO 7 · `scripts/check-shared-memory-layers.ps1`（静态扫描器，新文件，UTF-8 BOM）
  - 入口：`param([Parameter(Mandatory=$true)][string]$VaultRoot, [string]$RepoRoot='', [switch]$Json)`
  - 检查项：
    1. `docs/shared-memory-layers.md` 存在且包含 `## Layers` / `## Writeback Ladder` / `## Forbidden Reverse Edges`
    2. `共享记忆协议.md` 含对 `docs/shared-memory-layers.md` 的引用
    3. `当前任务.md` 含 `entry_host:` 字段（v1.1+）；缺失时 stderr 提示 v1.0-legacy
    4. `恢复索引.md` 与 `中断任务.md` frontmatter 含 `derived_from:` 字段，且至少有一条非空非占位路径
    5. `运行时/runtime.lock.json` 若存在则含 `writer / task_id / locked_at / entry_host` 四字段
  - 输出：`Checks:` / `Warnings:` / `Errors:` 三段；非 `-Json` 时人类可读；`-Json` 单行 JSON
  - 退出码：`Errors:` 为空 → 0；否则 1
  - 不修改任何 vault 文件，只读

- TODO 8 · `tests/verify-shared-memory-layers.ps1`（5 case 静态拦截，UTF-8 BOM）
  - L1：fixture vault 完整时 `check-shared-memory-layers.ps1` exit 0、Errors: none
  - L2：故意删 `docs/shared-memory-layers.md` 内某 section → Errors 提示具体缺失 section
  - L3：fixture `当前任务.md` 缺 `entry_host` → Warnings（legacy fallback），不进 Errors
  - L4：fixture `恢复索引.md` frontmatter 缺 `derived_from:` 字段（或仅含占位 `<path>`）→ Errors
  - L5：fixture `runtime.lock.json` 缺 `entry_host` 字段 → Errors（lock schema mismatch）
  - 与 Phase 1-4 测试同构：exit code 0/1，输出 `Checks:` + `Warnings:` + `Failures:`

- TODO 9 · `tests/verify-lite-footprint.ps1` 路径白名单扩展（同步加 BOM 检查）
  - 把 `scripts/check-shared-memory-layers.ps1` 与 `tests/verify-shared-memory-layers.ps1` 加到 BOM 列表与路径白名单
  - 不改既有 footprint 检查 / 禁词列表

- TODO 10 · `skills/obsidian-memory/scripts/check-shared-memory.ps1` 扩 reader
  - 增加读出 `当前任务.md` 的 `entry_host`（缺失则按 v1.0-legacy 处理）
  - 增加 `恢复索引.md` 与 `中断任务.md` frontmatter `derived_from:` 字段读出与静态扫描
  - 不改既有的 task-runtime / artifact-link 断言；输出契约字节级一致

- TODO 11 · 模板与运行时 stub 增字段
  - `vault-template/模板/任务状态模板.md`：模板 frontmatter 示例加 `entry_host: claudecode | codex | gemini | team-leader` 一行；`## 当前状态` 表格无变化；不改其他模板内容
  - `vault-template/运行时/当前任务.md.template`：frontmatter 加 `entry_host:` 字段（默认空，由 entry agent 写入）
  - `vault-template/运行时/恢复索引.md.template`：frontmatter 加 `derived_from:` 字段（默认 = [`运行时/当前任务.md`, `运行时/tasks/`, `运行时/中断任务.md`]）
  - `vault-template/运行时/中断任务.md.template`：frontmatter 加 `derived_from:` 字段（默认 = [`运行时/tasks/`]）
  - `vault-template/运行时/runtime.lock.json` 若有模板，frontmatter / JSON schema 加 `entry_host` 字段；无模板则跳过

- TODO 12 · `skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1` 候选优先级收口（PLAN_REVIEW finding 1）
  - 把 `Resolve-SharedMemoryVaultRoot` 候选源压成两组：tier-A（显式 `-VaultRoot` / `CLAUDE_DEV_HARNESS_VAULT_PATH` / `OBSIDIAN_SHARED_VAULT` / orchestrator flow `shared_vault_root:`）；tier-B（`<WorkspaceRoot>/.assistant` / `CLAUDE_DEV_HARNESS_WORKSPACE_ROOT/.assistant` / `WORKSPACE_ROOT/.assistant`）；fallback（`<cwd>/.assistant` 与 cwd 父级扫描）
  - tier-A 命中即返回；tier-A 内多源解析到不同物理 vault 时 stderr `[vault-ambiguous]` 警告（保留首选，不抛错）
  - 新增 `Assert-ProjectLocalVault` helper：当 vault 路径位于 `$USERPROFILE\.claude` / `\.codex` / `\.gemini` 之内且包含 `运行时/` 子目录时，抛 `[vault-layer-violation] user-level agent home cannot host runtime layer`；调用方决定是 throw 还是降级
  - 对外行为兼容：单源场景下 byte-identical；现有 callers 不必改 signature
  - 在 `runtime-inbox-common.ps1` 入口（`Get-RuntimeMarkdownPaths`）调用 `Assert-ProjectLocalVault`，runtime-touching 操作守门

- TODO 13 · `scripts/resolve-obsidian-memory-script.ps1` 区分 runtime-touching script（PLAN_REVIEW finding 1）
  - 维护常量集合 `$script:RuntimeTouchingScripts` = `append-runtime-inbox.ps1` / `promote-runtime-inbox.ps1` / `triage-runtime-inbox.ps1` / `repair-shared-memory.ps1` / `archive-memory-candidates.ps1` / `maintain-shared-memory.ps1` / `run-memory-health.ps1` / `write-memory-health-report.ps1`
  - 解析时若 `$ScriptName` ∈ runtime-touching 集合 且 候选指向 `$USERPROFILE\.claude` / `.codex` / `.gemini` 且 `$env:CLAUDE_DEV_HARNESS_ALLOW_AGENT_HOME` ≠ `1` → 跳过该候选；候选耗尽后抛 `Missing obsidian-memory script in repo (agent-home fallback disabled for runtime-touching scripts)`
  - 非 runtime-touching（如 `check-shared-memory.ps1` / `resolve-shared-memory-paths.ps1` / `runtime-inbox-common.ps1`）保持原 fallback
  - 行为兼容：单 repo / 单 agent-home 场景下 byte-identical；CI 默认走 repo

- TODO 14 · 三个 live hot writer 注入 `entry_host` / `derived_from` / best-effort 契约（PLAN_REVIEW finding 2）
  - `scripts/advance-stage.ps1`:
    - `Build-CurrentTaskContent` frontmatter 顺序：`updated` / `task_id` / `entry_host: claudecode` / `writer: advance-stage`（advance-stage 由 claude code 内部调用，常量 `claudecode` 即可）
    - `Write-RecoveryIndex` 输出在主 markdown 前先写 frontmatter 区块：`tags: [运行时, 恢复索引]` + `updated:` + `derived_from: [运行时/tasks/]` + `schema_version: recovery-index/v1.1`
    - `Write-RuntimeMirrors` 调用链（`Write-CurrentTaskMirror` / `Write-TasksMirror` / `Write-RecoveryIndex`）每步 try/catch；失败时 stderr `[writeback-fallback] <step>: <reason>` 并调 `skills\obsidian-memory\scripts\append-runtime-inbox.ps1` 写 `[writeback-fallback]` 行；plan.md frontmatter 写入仍保持同步阻塞（唯一强制写入面）
  - `skills/obsidian-memory/scripts/repair-shared-memory.ps1`:
    - 新参 `[string]$EntryHost`；缺省时调用 `Get-EntryHostValue`（runtime-inbox-common 暴露）；fallback `unknown`
    - `Build-CurrentTaskContent` frontmatter 增 `entry_host:` 行；`Build-RecoveryIndexContent` frontmatter 增 `derived_from: [运行时/tasks/, 运行时/中断任务.md]`
    - `New-TaskRuntimeContent` / repair-side 自动补建的 `运行时/tasks/<task-id>.md` frontmatter 也必须含 `entry_host:`；最低 conformance 是 task-runtime / current-task / runtime.lock 三处对同一 entry host 有一致可读字段
    - `runtime.lock.json` schema：`@{ writer = 'repair-shared-memory'; task_id = ...; locked_at = ...; entry_host = $EntryHost }`
    - 既有 30 分钟超时 / `Clear-LockBlockedRows` 行为不变
  - `runtime-hooks/claude/posttooluse.js`:
    - `buildRecoveryIndex(taskState)` 输出顶部追加 frontmatter `tags: [运行时, 恢复索引]` + `updated:` + `derived_from: ["运行时/当前任务.md","运行时/tasks/"]`
    - `lock` 对象写入时增 `entry_host: "claudecode"`；`detectForeignLock` 读到的 `lock.entry_host` 与 `claudecode` 不一致时 `appendLockBlockedInbox` 的 type 仍为 `lock-blocked`，但 payload 末尾追加 ` entry_host=${lock.entry_host}`
    - 30 分钟过期 / idle 短路逻辑不动；`writeJson` 输出格式不变（CI 解析依赖）
  - `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1`:
    - interrupted-task promotion 路径新增 `[string]$EntryHost`；缺省时调用 `Get-EntryHostValue`，fallback `unknown`
    - `New-TaskRuntimeDocument` frontmatter 必须包含 `entry_host:`，保证 inbox-first 产生的 task-runtime 与 v2 单写者判定字段对齐
    - `docs/tasks/<task-id>/plan.md` 生成逻辑、`中断任务.md` 行格式、`decision-needed` 分支均保持不变

- TODO 15 · 共享记忆回归测试 fixture 与断言扩展（PLAN_REVIEW finding 2 衍生 + finding 3 配套）
  - `tests/verify-repair-shared-memory.ps1`：fixture 增 `entry_host` 写入路径；新增断言 `当前任务.md` frontmatter 含 `entry_host:`；repair-side 自动补建的 `运行时/tasks/<task-id>.md` frontmatter 也含 `entry_host:`；`恢复索引.md` frontmatter 含 `derived_from:`；`runtime.lock.json` 含 `entry_host`；现有 case 总数与命名不变
  - `tests/verify-runtime-hooks.ps1`：fixture 渲染 hook 后断言 `恢复索引.md` 有 `derived_from:`；`runtime.lock.json` 写入时含 `entry_host: "claudecode"`；`appendLockBlockedInbox` payload 在 entry_host 不一致时含 `entry_host=` 后缀
  - 不改 inbox 行 schema；不改 hook 输入 / 输出 JSON 协议
  - `tests/verify-promote-runtime-inbox.ps1`：从“只做 no-regression 链”提升为显式合同锁；interrupted-task promotion 后必须断言生成的 `运行时/tasks/<task-id>.md` frontmatter 含 `entry_host:`，且值与 promotion 路径传入/解析出的 entry host 一致
  - `tests/verify-runtime-inbox.ps1` / `tests/verify-triage-runtime-inbox.ps1` / `tests/verify-archive-memory-candidates.ps1` / `tests/verify-memory-maintain.ps1` / `tests/verify-memory-health-report.ps1` 不改 fixture / 断言；本 Phase 用它们做契约不退化的回归

- TODO 16 · `docs/aionui-integration/team-preset.md` 引用层映射
  - 加一段："team-mode 下 leader 是 `entry_host = team-leader`，是 vault 共享运行时的唯一写者；spawned member 仅写 `运行时/tasks/<task-id>.md` 任务级状态，不直接写共享指针；team-board (`team_task_update`) 是 vault 的镜像，与 Q5(a) 一致"
  - 引用 `docs/shared-memory-layers.md` 作为层映射真相源

- TODO 17 · 回归 + smoke（PLAN_REVIEW finding 3 对齐共享记忆链）
  - 跑 `validate-lite-artifacts.ps1 -TaskId shared-memory-v2-optimization`：本 plan.md 应 PASS
  - 跑共享记忆回归链（与 Verification 块一致）：verify-repair-shared-memory / verify-runtime-hooks / verify-runtime-inbox / verify-promote-runtime-inbox / verify-memory-maintain / verify-memory-health-report / verify-archive-memory-candidates / verify-triage-runtime-inbox 应全 PASS
  - 跑 `verify-workflow-contracts.ps1`：advance-stage 是 lite workflow 主写者，确认 frontmatter / mirror 输出契约不退化
  - 跑 `verify-lite-footprint.ps1`：scripts/ + runtime-hooks/ 改动需在路径白名单内
  - 跑新 `tests/verify-shared-memory-layers.ps1`：5 case 应全 PASS
  - smoke：人工 fixture 一份项目本地 vault → `check-shared-memory-layers.ps1` 跑出 `Errors: none`；改 vault 指向 `$USERPROFILE\.claude\` 内含 `运行时/` 的目录 → 应抛 `[vault-layer-violation]`；恢复指向项目本地后再跑应回 PASS

## Verification

- `pwsh -File scripts/validate-lite-artifacts.ps1 -TaskId shared-memory-v2-optimization`
- `pwsh -File tests/verify-shared-memory-layers.ps1`
- `pwsh -File tests/verify-repair-shared-memory.ps1`
- `pwsh -File tests/verify-runtime-hooks.ps1`
- `pwsh -File tests/verify-runtime-inbox.ps1`
- `pwsh -File tests/verify-promote-runtime-inbox.ps1`
- `pwsh -File tests/verify-triage-runtime-inbox.ps1`
- `pwsh -File tests/verify-archive-memory-candidates.ps1`
- `pwsh -File tests/verify-memory-maintain.ps1`
- `pwsh -File tests/verify-memory-health-report.ps1`
- `pwsh -File tests/verify-lite-footprint.ps1`
- `pwsh -File tests/verify-workflow-contracts.ps1`
- `pwsh -File scripts/check-shared-memory-layers.ps1 -VaultRoot <fixture-vault>`

覆盖意图：
- `validate-lite-artifacts.ps1` 校 plan.md schema + 4 字段 frontmatter + 必备 section 顺序
- 新 `verify-shared-memory-layers.ps1`：5 case（layers doc 存在性 / 协议引用 / entry_host / `derived_from:` / lock schema），覆盖 4 必修项中的 truth-layering 与 single-writer
- 共享记忆回归链（verify-repair-shared-memory / verify-runtime-hooks / verify-runtime-inbox / verify-promote-runtime-inbox / verify-triage-runtime-inbox / verify-archive-memory-candidates / verify-memory-maintain / verify-memory-health-report）覆盖 hot writer + helper 的实际行为：repair / hook / inbox 三个写入面 + promote-runtime-inbox 的 task-runtime `entry_host` 合同锁 + 4 个 inbox/记忆维护链
- `verify-workflow-contracts.ps1` 仅这一条 workflow 回归被纳入：advance-stage.ps1 是 lite workflow mainline mutation point，hot writer 改动直接影响其 mirror 输出契约
- `verify-lite-footprint.ps1` 因本 Phase 改 `scripts/` + `runtime-hooks/` + `tests/`，需要走 footprint 白名单确认无越权落点
- `check-shared-memory-layers.ps1` 提供脚本级静态扫描，团队回归 / CI / 本地手工三处都可跑
- 不再泛跑 Phase 1-4 全套 verify-*：team-preset / tool-profile / workflow-descriptor / aionui-skill-contract / skill-manifest / lite-artifact-validator 与本任务 hot path 不相关，跑了不增加证据

## Risks

- **R-DRIFT-RUNTIME**（最高）· `.assistant/运行时/` 与 team task-board 状态飘移：team-board 写入未走单向链 → vault 与 board 双源真相分裂；缓解：(a) 本任务把 vault 写为唯一真相源、team_task_update 仅作为 mirror；(b) `docs/shared-memory-layers.md` 的 forbidden reverse edges 段静态拦截 board → vault 反向；(c) 沿用 Q5(a) 仅文档化禁止，不引入 runtime hook；(d) Leader 已裁定 D2，本 Phase 不做 board 自动 mirror，由人工或上游编排在写完 vault 后触发

- **R-DUAL-VAULT** · 项目本地 `<workspace>/.assistant/` 与 user-level Companion Starter vault 同时被读写：reader 不知道哪个是当前任务源；缓解：(a) 本任务明文写"任务级运行时只在项目本地"；(b) Leader 已裁定 D1，user-level vault 仅承载 `配置/*.md` + `工作流/*.md`（跨项目长期偏好），禁止任何 `运行时/` 子目录；(c) `check-shared-memory-layers.ps1` 在 `-VaultRoot` 指向 user-level 时额外报 Errors（检出 `运行时/` 即视作越权）；(d) 项目本地 vault 是唯一任务级真相源

- **R-LAYER-LEAK** · 真相源跨层泄漏：例如把当前任务步骤写到 `配置/*.md`、把长期偏好写到 `运行时/`；缓解：本任务的 4 层映射表写死禁写位置；既有 `共享记忆协议.md` 的 `## 禁写位置` 段落保留并扩展（增加 "运行时/恢复索引.md 不承载独立判断" 一条）；reader 侧由 `check-shared-memory-layers.ps1` 静态扫描

- **R-DERIVED-VIEW-AUTHORITY** · 派生视图（`恢复索引.md` / `中断任务.md`）被当作真相源使用：不同 agent 同时编辑导致冲突；缓解：(a) frontmatter `derived_from:` 字段 hard rule（D3 落地），机器可读；(b) reader 一致性检查（updated 比对）升级为 hard；(c) 仅 `entry_host` 持有者负责刷新；(d) 不持锁的 agent 只写 `运行时/tasks/<id>.md`，不碰共享指针

- **R-LOCK-SCHEMA-DRIFT** · `runtime.lock.json` schema 历史只含 3 字段（`writer / task_id / locked_at`）；新增 `entry_host` 后旧 reader 报错；缓解：reader fallback 至 v1 schema、`[legacy-lock]` 标记、不拒绝；新 writer 必填 `entry_host`；30 分钟超时仍生效

- **R-WRITEBACK-ATOMIC** · 写回阶梯单向链分多步执行，中途崩溃 → vault 半开状态；缓解：(a) 强制顺序 plan.md → tasks/<id>.md → 当前任务.md → 恢复索引.md；(b) 每步失败仅 stderr + `收件箱.md` `[writeback-fallback]` 标记，不阻塞 plan.md 主推进；(c) 恢复时由 reader 一致性检查（updated 时间戳）发现并拉齐；(d) 本 Phase 不引入事务/原子写

- **R-SCHEMA-VERSION-PROLIFERATION** · 三个 schema 版本同时升级（`shared-memory-core: 1.2` / `current-task-pointer: 1.1` / `recovery-index: 1.1`）→ 旧 reader 失配；缓解：(a) `schema-versions.md` 集中维护，reader 优先读注册表；(b) 未声明版本一律按 legacy 处理；(c) `task-runtime` 不升版本（沿用 1.1），减小 blast radius

- **R-MINIMAL-SURFACE-MISREAD** · "最小写入面降级为 best-effort" 被误解为可以不写 vault；缓解：明确写"plan.md 是唯一强制写入面；其余三处是 best-effort 但 *recommended*"；reader 在恢复时若发现派生视图陈旧会自动补刷，不丢数据

- **R-CONTRACT-FAKE** · check-shared-memory-layers.ps1 静态扫描被误当成 runtime 强制；缓解：本 Phase 显式声明"静态拦截，不做 runtime hook"，runtime 强制留 Phase 5（与 Phase 4 R-CONTRACT-FAKE 同源）

- **R-TEAM-MODE-LEADER-AS-ENTRY-HOST** · team-mode 下 leader 是 entry_host = `team-leader`，与 single-agent 下 entry_host = `claudecode|codex|gemini` 不同；spawned member 不能伪装 entry_host；缓解：role-prompt Authority 段（Phase 4 已固化）已禁写共享指针；本 Phase 在 `docs/aionui-integration/team-preset.md` 中重申；O5 静态拦截覆盖

- **R-RESOLVER-AMBIGUITY**（PLAN_REVIEW finding 1 衍生）· `Resolve-SharedMemoryVaultRoot` 8 候选源 + flow shared_vault_root + 父级扫描，环境内同时存在多个候选 vault 时返回首选不一定是项目本地；缓解：(a) 候选源压成 tier-A / tier-B / fallback 三级，tier-A 优先；(b) tier-A 内多源解析到不同物理路径时 stderr `[vault-ambiguous]` 警告但不抛错（保留首选）；(c) `Assert-ProjectLocalVault` helper 拒绝指向 user-level agent home 内含 `运行时/` 的 vault；(d) 行为兼容：单源场景 byte-identical

- **R-AGENT-HOME-LEAK**（PLAN_REVIEW finding 1 衍生）· `resolve-obsidian-memory-script.ps1` 在 repo miss 时回退 `$USERPROFILE\.claude` 等 agent home，runtime-touching 脚本可能从 user-level 加载并对项目 vault 写入 → 脚本 / vault 跨 layer 串源；缓解：(a) runtime-touching 集合（8 个脚本）默认禁用 agent-home fallback；(b) 必需时 `CLAUDE_DEV_HARNESS_ALLOW_AGENT_HOME=1` 显式 opt-in；(c) read-only checker 类（`check-shared-memory.ps1`）保持 fallback；(d) 候选耗尽时抛精确错误信息便于定位

- **R-RUNTIME-WRITER-CONFORMANCE-DRIFT**（PLAN_REVIEW finding 2 衍生）· 三个 live writer（advance-stage / repair-shared-memory / posttooluse）独立维护 `entry_host` / `derived_from` / lock schema 字段，长期可能漂移到不一致状态；缓解：(a) `runtime-inbox-common.ps1` 暴露统一 `Get-EntryHostValue` helper，PowerShell 侧两个 writer 共用；(b) `runtime.lock.json` schema 由 `check-shared-memory-layers.ps1` 静态扫描；(c) `verify-repair-shared-memory` / `verify-runtime-hooks` 用 exact-string 断言锁定写入格式；(d) posttooluse.js 是 JS 不能共用 PowerShell helper，但 fixture 测试覆盖到位（hook 渲染输出 byte-level diff）

## Plan Review

## Implementation Notes

## Code Review
