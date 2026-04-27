---
task_id: shared-memory-v2-live-migration
stage: PLAN
tool: claudecode
updated: 2026-04-27
---
# Live Repo-Local `.assistant` 迁移到 shared-memory v2 契约

本任务把 `D:\data\claude-dev-harness\.assistant\` 现存内容补齐到 `shared-memory-v2-optimization` 已批准并落地的 v2 契约。范围严格围绕"让 live vault 通过 `scripts/check-shared-memory-layers.ps1` 与 task-runtime/v1.1 最低契约"，不重开 v2 架构决策、不修改任何 v2 优化代码、不扩到无关 workflow。

当前 baseline（实测）：
- `pwsh -File scripts/check-shared-memory-layers.ps1 -VaultRoot .assistant` STATUS=FAIL，3 Errors + 1 Warning
- Errors:
  - `.assistant/工作流/共享记忆协议.md` 未引用 `docs/shared-memory-layers.md`
  - `.assistant/运行时/恢复索引.md` 缺 `derived_from:` frontmatter（且当前文件根本没有 frontmatter）
  - `.assistant/运行时/中断任务.md` 缺 `derived_from:` frontmatter
- Warning:
  - `.assistant/运行时/当前任务.md` 缺 `entry_host:`（legacy fallback active）
- 隐含 gap（checker 不报，但 task-runtime/v1.1 v2 后续约定要求）：
  - `.assistant/运行时/tasks/*.md`（3 个文件）frontmatter 全部缺 `entry_host:`
  - `.assistant/配置/schema-versions.md` 中 `current-task-pointer` 仍为 `1.0`、`recovery-index` 仍为 `1.0`、`task-runtime/v1.1` 最低字段清单未含 `entry_host`

## Clarification

- 验收标准:
  - `pwsh -NoProfile -File scripts/check-shared-memory-layers.ps1 -VaultRoot .assistant` STATUS=PASS，Errors 段为空，Warnings 段为空
  - `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId shared-memory-v2-live-migration` STATUS=PASS
  - 共享记忆回归链全 PASS（迁移期间 vault 内容变化只 touch 数据，不改 hot writer / checker）：`verify-shared-memory-layers` / `verify-repair-shared-memory` / `verify-runtime-hooks` / `verify-runtime-inbox` / `verify-promote-runtime-inbox` / `verify-triage-runtime-inbox` / `verify-archive-memory-candidates` / `verify-memory-maintain` / `verify-memory-health-report`
  - `verify-lite-footprint.ps1` PASS（迁移文件全部位于既有白名单路径前缀 `.assistant/` + `docs/tasks/<task-id>/`）
  - IMPLEMENT 完成后用 `git diff --stat` 确认仅 8 个 affected_paths 文件被修改、累计行变化为 additive（每个 frontmatter 文件净新增行数 ≥ 1，正文段净变化 = 0），与 affected_paths 清单严格一一对应；任何超出 affected_paths 的文件出现在 diff 都视为越权

- 非目标:
  - **不**重开 `shared-memory-v2-optimization` 任何架构决策（D1/D2/D3 终态保持）
  - **不**修改任何 v2 优化期间已落地的 hot writer（`scripts/advance-stage.ps1` / `skills/obsidian-memory/scripts/repair-shared-memory.ps1` / `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1` / `runtime-hooks/claude/posttooluse.js`）
  - **不**修改 `scripts/check-shared-memory-layers.ps1` / `tests/verify-shared-memory-layers.ps1` / `validate-lite-artifacts.ps1`
  - **不**重排 `.assistant/运行时/tasks/*.md` 现有 "Task Mirror" 列表/正文结构；只在 frontmatter 增 `entry_host:`
  - **不**触碰 `vault-template/`（迁移目标是 live vault，不是模板）
  - **不**改 `.assistant/工作流/` 下的 `任务识别协议.md` / `写回协议.md` / `恢复协议.md` / `记忆管理协议.md` / `项目约定.md` 任何正文字段——这些协议在 v2 优化中已就绪，只有 `共享记忆协议.md` 需要补一段对 `docs/shared-memory-layers.md` 的引用
  - **不**升级 `.assistant/orchestration/`（如存在）的 schema 版本（不属于本任务范围）
  - **不**改长期记忆候选 / 归档 / 收件箱 行（保持现行 `runtime-inbox/v1.0` 占位行不变）
  - **不**扩到 user-level Companion Starter vault（`$USERPROFILE\.claude\` 下的同名结构；本任务只迁移项目本地 `<repo>/.assistant/`）
  - **不**做静默就地编辑：每一处 frontmatter 写入都必须保留原 `tags` / `created` / `updated` 字段（仅追加新字段或更新 `updated`）

- 受影响目录:
  - `.assistant/工作流/共享记忆协议.md` — 在适当锚点（推荐"## 共享根目录"或文件末尾"## 参考"段）追加一行链接到 `docs/shared-memory-layers.md`，闭合 checker Errors-1
  - `.assistant/运行时/当前任务.md` — frontmatter 增 `entry_host: claudecode`（值取自 `当前任务.md` 已写入的 `writer:`，目前是 `Codex` → 迁移后归一为 `claudecode`，与 `advance-stage.ps1` 的常量一致）；闭合 checker Warning
  - `.assistant/运行时/恢复索引.md` — 整个文件当前没有 frontmatter；要补一段 frontmatter（`tags: [运行时, 恢复索引]` / `updated:` / `derived_from: [运行时/当前任务.md, 运行时/tasks/, 运行时/中断任务.md]` / `schema_version: recovery-index/v1.1`）；正文不变；闭合 checker Errors-2
  - `.assistant/运行时/中断任务.md` — frontmatter 增 `derived_from: [运行时/tasks/]` 与 `schema_version: recovery-index/v1.1` 同源派生标记（`中断任务.md` 自身在 v2 contract 里属于派生视图）；正文表头不变；闭合 checker Errors-3
  - `.assistant/运行时/tasks/shared-memory-v2-live-migration.md` — frontmatter 增 `entry_host: claudecode`（与本任务 `当前任务.md` 一致）；不改其他字段
  - `.assistant/运行时/tasks/shared-memory-v2-optimization.md` — frontmatter 增 `entry_host: claudecode`（追溯标记，迁移历史任务）；不改其他字段
  - `.assistant/运行时/tasks/harness-aionui-workflow-alignment.md` — frontmatter 增 `entry_host: claudecode`（追溯标记）；不改其他字段
  - `.assistant/配置/schema-versions.md` — 当前版本表 `current-task-pointer` 升 `1.1`，`recovery-index` 升 `1.1`；新增"task-runtime v1.1 最低字段"列表加 `entry_host`；`updated:` 字段同步刷新到 `2026-04-27`；不改 `shared-memory-core: 1.2`、不改 `task-runtime` 版本号本身（仍 1.1）、不改 orchestrator-* 系列任何字段

- 回滚策略:
  - 全 additive + reversible：迁移仅追加 frontmatter 字段，不重写正文，不删行
  - 单 commit 落地（推荐 `chore(.assistant): migrate to shared-memory v2 contract`）；回滚 = `git revert <commit>`
  - 单点失败隔离:
    - 若某一文件 frontmatter 写法导致 checker 解析失败 → 仅该文件回退原状（`git checkout HEAD~1 -- <file>`），其他文件保留
    - 若 schema-versions.md 升级触发 `obsidian-memory` reader 在历史任务上误判 → 设置 `task-runtime/v1.0-legacy` fallback（已是 v2 优化期内既有兼容策略）；不需要本任务改 reader
    - 若 `derived_from:` 列表中的某个源路径在某个工作目录下不存在（如 `运行时/tasks/` 为空） → checker 仅校验字段存在 + 至少一条非占位条目，路径目标存在性不强校验
    - 若 user-level vault 与项目本地 vault 同名 frontmatter 冲突（不应发生，user-level 不含 `运行时/`）→ `Assert-ProjectLocalVault` 已在 v2 优化期生效，会拒绝 user-level 内含 `运行时/` 的 vault
  - 回滚验证：`git revert` 后跑 `check-shared-memory-layers.ps1` → 应回到当前 baseline 的 3 Errors + 1 Warning（不会出现新错误）

- ui: not-applicable

## User Confirmation
- status: confirmed
- note: 本 plan 是 `shared-memory-v2-optimization` 的 live vault 迁移补齐；范围严格围绕通过 `check-shared-memory-layers.ps1` 与 task-runtime/v1.1 entry_host 契约；Leader 已裁定 D1/D2/D3（D1 保持窄范围、tasks/*.md 维持 v1.0-legacy 回退仅补 `entry_host`；D2 3 个现有 tasks/*.md 全部回填 `entry_host: claudecode` 含历史 `harness-aionui-workflow-alignment`；D3 单 commit 落地，提交信息 `chore(.assistant): migrate to shared-memory v2 contract` 或等价表达），可进入 PLAN_REVIEW

## Change Contract
- change_type: refactor
- affected_paths:
  - .assistant/工作流/共享记忆协议.md
  - .assistant/运行时/当前任务.md
  - .assistant/运行时/恢复索引.md
  - .assistant/运行时/中断任务.md
  - .assistant/运行时/tasks/shared-memory-v2-live-migration.md
  - .assistant/运行时/tasks/shared-memory-v2-optimization.md
  - .assistant/运行时/tasks/harness-aionui-workflow-alignment.md
  - .assistant/配置/schema-versions.md

## Plan

- TODO 1 · 落 baseline 证据
  - 在 IMPLEMENT 起点先重跑 `pwsh -NoProfile -File scripts/check-shared-memory-layers.ps1 -VaultRoot .assistant` 并把 stdout 复制到 `docs/tasks/shared-memory-v2-live-migration/baseline.txt`（一次性证据，便于 CODE_REVIEW 与 TEST 比对前后）
  - 不要求该文件位列 affected_paths（属于 task-local 工件，已落在 `docs/tasks/<id>/` 前缀内）

- TODO 2 · 修 `.assistant/工作流/共享记忆协议.md`（闭合 Errors-1）
  - 在文件末尾追加一段或在"## 共享根目录"段后追加一行：`真相源 4 层映射详见 [docs/shared-memory-layers.md](../../docs/shared-memory-layers.md)`
  - 仅追加文本，不改既有 frontmatter / 段落 / 标题；保留 `created: 2026-03-17`、`updated: 2026-04-07` → 同步把 `updated` 升到 `2026-04-27`
  - 验证：`Select-String -Path .assistant/工作流/共享记忆协议.md -Pattern 'docs/shared-memory-layers.md'` 必须命中

- TODO 3 · 修 `.assistant/运行时/恢复索引.md`（闭合 Errors-2）
  - 当前文件没有 frontmatter，只有正文。在文件最顶补一段 frontmatter（YAML 块 + 空行）：
    ```yaml
    ---
    tags: [运行时, 恢复索引]
    updated: 2026-04-27
    derived_from: [运行时/当前任务.md, 运行时/tasks/, 运行时/中断任务.md]
    schema_version: recovery-index/v1.1
    ---
    ```
  - `derived_from` 必须采用 **inline array** 语法（`[a, b, c]`），不得展开成 block list（`-` 开头多行）；现有 checker `scripts/check-shared-memory-layers.ps1` 与 `skills/obsidian-memory/scripts/check-shared-memory.ps1` 仅解析 inline array 一种形式，block list 会导致 `derived_from` 被识别为空 → checker 仍报缺字段
  - 正文（`# 恢复索引` 与既有两行 task 列表）逐字保留
  - 编码：UTF-8 with BOM（与现有 hot writer `Write-Utf8Bom` 输出一致）

- TODO 4 · 修 `.assistant/运行时/中断任务.md`（闭合 Errors-3）
  - 在既有 frontmatter 内追加 `derived_from:` 与 `schema_version:`：
    - `derived_from: [运行时/tasks/]`
    - `schema_version: recovery-index/v1.1`
  - 同步把 `updated` 升到 `2026-04-27`
  - 表头与表体（包括空数据行）逐字保留
  - 不改 `tags` 现值

- TODO 5 · 修 `.assistant/运行时/当前任务.md`（闭合 Warning）
  - **核心约束**：IMPLEMENT 时必须保留 live state——`updated:` / `writer:` / 正文表格内容以执行那一刻文件实际存在的值为准，**不**预先把任何 runtime 字段写死成捕获快照。本 plan 不在 affected_paths 之外固定 live runtime 状态，避免把共享指针 freeze 成 stale state（hot writer 在 IMPLEMENT 期之间仍可能写入新值）
  - 唯一允许的写动作：在 frontmatter 内 `task_id` 行后追加一行 `entry_host: claudecode`
  - **不**修改 `updated:` 字段（保留 IMPLEMENT 触发那一刻的实测值）；**不**修改 `writer:` 字段（writer 是上一次写入者标记，独立于 entry_host，由后续 hot writer 自然刷新）；**不**修改正文任何一行（包括表格、说明、链接）
  - 验证：写入后 `Select-String -Path .assistant/运行时/当前任务.md -Pattern '^entry_host:\s*claudecode$'` 必须命中；其余 frontmatter 字段与正文 byte-for-byte 与 IMPLEMENT 起点一致（用 `git diff` 确认仅一行新增）

- TODO 6 · 修 3 个 `.assistant/运行时/tasks/*.md`（task-runtime/v1.1 entry_host 契约）
  - 文件清单：
    - `shared-memory-v2-live-migration.md`
    - `shared-memory-v2-optimization.md`
    - `harness-aionui-workflow-alignment.md`
  - 每个文件 frontmatter 在 `tool` 行后追加：`entry_host: claudecode`
  - 不改 `task_id` / `stage` / `tool` / `updated` 任何字段；不改正文 "Task Mirror" 区块
  - 4-字段 plan.md frontmatter 与 task mirror frontmatter 是不同 schema：plan.md 是 `task_id/stage/tool/updated`，task mirror 是 v2 contract 下的 task-runtime/v1.1（`schema_version` / `task_id` / `task_name` / `workspace` / `artifact_root` / `primary_artifact` / `artifact_links`）。本迁移 **只补 entry_host**，不补齐其他 v1.1 最低字段（Leader 已裁定 D1：保持窄范围，依赖 `task-runtime/v1.0-legacy` fallback；完整 v1.1 字段补齐由后续单独任务承担）

- TODO 7 · 修 `.assistant/配置/schema-versions.md`
  - 当前版本表中：
    - `current-task-pointer | 1.0 | ...` → `current-task-pointer | 1.1 | ...`（兼容策略列继续保持原文："继续保持共享指针简化"，无需改）
    - `recovery-index | 1.0 | ...` → `recovery-index | 1.1 | ...`（兼容策略保持原文）
  - 在"## task-runtime v1.1 最低字段"列表末尾追加一行 `- entry_host`
  - frontmatter `updated: 2026-04-03` → `updated: 2026-04-27`
  - 不改 `shared-memory-core: 1.2`、不改 `task-runtime: 1.1` 版本号本体、不改 orchestrator-* / runtime-inbox 系列任何字段

- TODO 8 · 提交单 commit + 落最终证据（Leader 已裁定 D3：单 commit 策略）
  - 一次性 stage 8 个文件（与 affected_paths 一致），commit message：`chore(.assistant): migrate to shared-memory v2 contract`（或等价表达）
  - 重跑 `pwsh -NoProfile -File scripts/check-shared-memory-layers.ps1 -VaultRoot .assistant`，把 stdout 复制到 `docs/tasks/shared-memory-v2-live-migration/post-migration.txt`，验收时与 baseline.txt 对比

## Verification

- `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId shared-memory-v2-live-migration -RepoRoot D:\data\claude-dev-harness`
- `pwsh -NoProfile -File scripts/check-shared-memory-layers.ps1 -VaultRoot .assistant`
- `pwsh -NoProfile -File tests/verify-shared-memory-layers.ps1`
- `pwsh -NoProfile -File tests/verify-repair-shared-memory.ps1`
- `pwsh -NoProfile -File tests/verify-runtime-hooks.ps1`
- `pwsh -NoProfile -File tests/verify-runtime-inbox.ps1`
- `pwsh -NoProfile -File tests/verify-promote-runtime-inbox.ps1`
- `pwsh -NoProfile -File tests/verify-triage-runtime-inbox.ps1`
- `pwsh -NoProfile -File tests/verify-archive-memory-candidates.ps1`
- `pwsh -NoProfile -File tests/verify-memory-maintain.ps1`
- `pwsh -NoProfile -File tests/verify-memory-health-report.ps1`
- `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`

覆盖意图：
- `validate-lite-artifacts.ps1`：本 plan.md 自身的契约（frontmatter / sections / Change Contract）
- `check-shared-memory-layers.ps1 -VaultRoot .assistant`：核心收敛指标——FAIL → PASS（3 Errors + 1 Warning → 0 / 0）
- 共享记忆回归链 9 条：迁移仅写入数据、不改 hot writer / checker，所以这些应保持 PASS（任何一条 FAIL 都意味着 v2 优化期落地的 hot writer 或本迁移误改了被认为不在范围内的文件）
- `verify-lite-footprint.ps1`：所有迁移文件位于既有白名单前缀（`.assistant/` + `docs/tasks/<task-id>/`），不应触发新越权
- 不再泛跑 Phase 1-4 全套：team-preset / tool-profile / workflow-descriptor / aionui-skill-contract / skill-manifest / lite-artifact-validator 与本任务无关；`verify-workflow-contracts.ps1` 也不在 chain（迁移不动 advance-stage.ps1 主路径）

## Risks

- **R-FRONTMATTER-PARSE**（最高）· `.assistant/运行时/恢复索引.md` 当前完全没有 frontmatter，要新增一整段 YAML；若与正文 `# 恢复索引` 之间缺空行 / 缩进错位 / BOM 缺失，会被 `Get-YamlValue` / `obsidian-memory` reader 误判为正文一部分；缓解：(a) frontmatter 与正文之间留一行空行；(b) UTF-8 BOM；(c) IMPLEMENT 完成后立即跑 checker 二次确认；(d) 写入用 `[System.IO.File]::WriteAllText` + `UTF8Encoding($true)` 与 hot writer 一致

- **R-LEGACY-MIRROR-DRIFT** · `.assistant/运行时/tasks/*.md` 当前是 "Task Mirror" 自由文本格式，缺 `schema_version` / `task_name` / `workspace` / `artifact_root` / `primary_artifact` / `artifact_links` 等 task-runtime/v1.1 最低字段；本迁移仅补 `entry_host`，依赖 v1.0-legacy fallback 兼容；若未来 reader 收紧到 v1.1 严格校验，3 个 mirror 都会再次 FAIL；缓解：(a) Leader 已裁定 D1，本 Phase 不做完整 v1.1 字段补齐；(b) `task-runtime/v1.0-legacy` fallback 已在 schema-versions.md 中明文允许；(c) 后续单开任务再做完整字段补齐（不在本任务范围）

- **R-CHECKER-FALSE-PASS** · 修完三处 Errors 后 checker 输出 PASS，但 vault 实际仍存在隐藏污染（如 schema_version 字段值拼写错误、derived_from 路径写错）；缓解：(a) IMPLEMENT 期 baseline.txt / post-migration.txt diff 比对；(b) 共享记忆回归链 9 条覆盖典型读路径；(c) `obsidian-memory` skill 在 IMPLEMENT 后做一次手工 `恢复` 触发恢复索引读路径

- **R-WRITER-CONSTANT-MISMATCH** · 当前 `当前任务.md` 的 `writer: Codex`，但 `advance-stage.ps1` hot writer 写入时使用 `writer: advance-stage`，`repair-shared-memory.ps1` 使用 `writer: repair-shared-memory`；本迁移只追加 `entry_host: claudecode` 不动 `writer:`，下次 hot writer 触发会覆盖整个文件、`writer:` 自动归一；缓解：本任务不修 `writer:`（writer 是 last-touched 标记，每次 hot write 自动重写），与本迁移无冲突；entry_host 是 platform 级常量、迁移期手工设为 `claudecode`，与 hot writer 默认一致

- **R-HISTORY-TASK-BACKFILL** · 给 3 个历史 tasks/<id>.md 都打 `entry_host: claudecode` 是追溯归一，但其中 `harness-aionui-workflow-alignment.md` 实际可能由 Codex / Gemini 写出；缓解：(a) Leader 已裁定 D2，3 个 mirror 统一回填 `claudecode`；(b) `entry_host` 在 v2 contract 里是 platform agent 标识不是 backend 标识，3 个历史任务都通过 claudecode 入口推进（与 `当前任务.md writer: Codex` 是不同概念）；(c) 当前没有非 claudecode 入口痕迹，统一值减小 reader 解析复杂度

- **R-SCHEMA-VERSION-LIVE-DRIFT** · `.assistant/配置/schema-versions.md` 升级 current-task-pointer / recovery-index 至 1.1 后，`vault-template/配置/schema-versions.md`（已在 v2 优化期升级到 1.1）和 live 版本一致；但 user-level Companion Starter vault（`$USERPROFILE\.claude\配置\schema-versions.md`，如果存在）可能仍是 1.0；缓解：(a) D1 已裁定 user-level 仅承载跨项目偏好，不含 schema-versions.md 影响 task runtime；(b) `Assert-ProjectLocalVault` 已拒绝 user-level 内含 `运行时/`；(c) 如果发现 user-level 也有 schema-versions.md，单独同步即可，不属于本任务

- **R-OBSIDIAN-PLUGIN-CACHE** · Obsidian 客户端可能缓存 `.assistant/` 目录内文件 frontmatter；迁移后 Obsidian UI 可能显示旧值直到下次 reload；缓解：(a) 这是 UI 层 cache 不影响脚本/checker；(b) IMPLEMENT 后通过 `pwsh check-shared-memory-layers.ps1` 验证而非 Obsidian UI；(c) 用户在 Obsidian 中手动 `Reload App without saving`（Ctrl+P → Reload）即可

- **R-COMMIT-PARTIAL** · 8 个文件分多次 commit 时会出现"中间态" PASS/FAIL（例如先改了 `共享记忆协议.md` 但没改 frontmatter 文件 → checker 仍 FAIL 但报错不同）；缓解：(a) Leader 已裁定 D3，单 commit 落地；(b) IMPLEMENT 期 git stage 后用 `git diff --staged --name-only` 验证文件清单与 affected_paths 一致

- **R-VAULT-LAYER-VIOLATION-FALSE-ALARM** · `Assert-ProjectLocalVault` 在 user-level vault 内出现 `运行时/` 时会抛 `[vault-layer-violation]`；本迁移在项目本地 vault 内修改 `运行时/` 字段，不触发该断言；缓解：(a) 项目本地 `.assistant/` 不在 `$USERPROFILE\.claude\` 路径内（前者是 `D:\data\claude-dev-harness\.assistant\`）；(b) checker 已正确隔离

- **R-PLAN-REVIEW-OVERREACH** · PLAN_REVIEW 期可能再次提出"既然在迁移就补全 task-runtime/v1.1 最低字段"等扩 scope 建议；缓解：(a) Leader 已明确"keep scope narrow"；(b) Leader 已裁定 D1 把 v1.1 完整字段补齐归到后续任务；(c) 本 plan 非目标段落显式禁止

## Plan Review

## Implementation Notes

## Code Review
