# 368ad685 Status

## Summary

本任务只做命名审计与迁移方案，未实际 rename、移动 skill 目录或修改运行时文件。结论：`using-superpowers` 当前职责已经不是泛化“技能使用指南”，而是工作区入口路由器：它负责 `resume-current / switch-existing / new-task / inbox-first` 判定、`quick | workflow | ask` 模式路由、共享记忆恢复/写回 guardrails、默认懒加载边界，以及导向 `orchestrator` / 当前 stage skill。

## 1. 推荐新名称

推荐 canonical 名称：`entry-router`。

理由：

- 职责覆盖 quick、workflow、ask、resume/switch/inbox，并不只服务 workflow。
- `workflow-router` 容易与 `orchestrator` 混淆；后者才是进入 `mode=workflow` 后的 stage 编排器。
- `entry-router` 更贴近安装态入口文档和 host starter 的职责：先分流，再决定是否进入 workflow。

不建议本轮直接 rename。下一轮迁移应采用 A 路径：先新增 canonical `entry-router`，但保持 `using-superpowers` 完整可用；默认引用全部切到 `entry-router` 后，再把 `using-superpowers` 收缩为 legacy alias。

## 2. 必须改的引用图

### Canonical skill identity

- `skills/using-superpowers/SKILL.md`
  - 目录名、frontmatter `name: using-superpowers` 都会影响 native skill 名称。
  - 迁移目标应为 `skills/entry-router/SKILL.md` 且 frontmatter `name: entry-router`。
- `tests/verify-lite-footprint.ps1`
  - 当前 exact skill set 包含 `using-superpowers`。
  - 当前还直接断言 `skills/using-superpowers/SKILL.md` 的内容。
- `scripts/validate-lite-artifacts.ps1`
  - `Get-RepositorySkillNames` 静态白名单包含 `using-superpowers`。

### Entry / host templates

- `agent-configs/claude/CLAUDE.md.template`
  - 当前显式要求每次对话先调用 `/using-superpowers`。
- `agent-configs/codex/config.shared.toml.template`
  - 当前 managed Codex skill path 指向 `{CODEX_HOME}\skills\using-superpowers\SKILL.md`。
- `agent-configs/codex/AGENTS.md.template`
- `agent-configs/workspace/AGENTS.md.template`
- `vault-template/entry/AGENTS.md.template`
- `vault-template/entry/GEMINI.md.template`
  - 当前 lazy loading 摘要中仍写 `using-superpowers`。

### Workflow descriptor / profiles / team preset

- `agent-configs/workflows/harness-lite.yaml`
  - `PLAN.skills_whitelist: [plan, using-superpowers]` 是 manifest/index/team preset 的机器源。
- `agent-configs/profiles/harness-default-claude.yaml`
- `agent-configs/profiles/harness-default-codex.yaml`
  - `skills` 列表包含 `using-superpowers`。
- `agent-configs/role-prompts/plan-author.md`
  - Allowed skills 写 `plan, using-superpowers`。
- `docs/aionui-integration/team-preset.md`
  - 静态示例仍写 `[plan, using-superpowers]`。
- `scripts/export-team-preset.ps1`
  - 不直接写死名称，但从 `harness-lite.yaml` 派生；改 descriptor 后输出会变。
- `tests/verify-team-preset.ps1`
  - 主要做 descriptor parity，随 descriptor 变化。
- `tests/verify-team-orchestration.ps1`
  - 直接断言 `plan-author` payload skills 为 `plan, using-superpowers`。

### Skill manifest / skills-index

- `scripts/advance-stage.ps1`
  - 读取 workflow descriptor `skills_whitelist`，再查 `skills/<skill>/SKILL.md` frontmatter description，写 `docs/tasks/<task-id>/skill-manifest.json`。
- `scripts/generate-skills-index.ps1`
  - 同样用 descriptor skill id 拼 `skills/<id>/SKILL.md`。
- 因此 descriptor 改成 `entry-router` 前，必须先确保 `skills/entry-router/SKILL.md` 存在，否则 manifest/index description 会降级或缺失。
- 相关测试：`tests/verify-skill-manifest.ps1`、`tests/verify-aionui-skill-contract.ps1`、`tests/verify-workflow-descriptor.ps1`。

### Docs / references

- `README.md`
- `skills/orchestrator/references/runbook.md`
- `skills/orchestrator/references/state-templates.md`
- `skills/obsidian-memory/SKILL.md`
- `vault-template/工作流/任务识别协议.md`
- 历史 `docs/tasks/*` 中的 `using-superpowers` 不应批量改写，只保留为历史证据。

## 3. Alias / 兼容策略

推荐保留 `using-superpowers` 作为显式兼容 alias，至少跨一次完整 install/update 周期；更稳妥是长期保留一个极小 alias skill。

建议结构：

- Phase 1 新增 canonical：`skills/entry-router/SKILL.md`
  - 放完整规则，frontmatter `name: entry-router`。
  - 暂时保持 `skills/using-superpowers/SKILL.md` 完整内容不变；此时旧名仍可在默认面中安全工作。
- Phase 2 切默认引用：
  - `harness-lite.yaml`、profiles、role prompts、templates、tests 默认引用一次性切到 `entry-router`。
  - 增加 active path grep 锁点，确认默认面不再出现旧名。
- Phase 3 才收缩 legacy alias：
  - `skills/using-superpowers/SKILL.md` frontmatter 仍为 `name: using-superpowers`。
  - 内容只说明“compatibility alias for `entry-router`”，并要求调用/读取 `entry-router`。
  - alias 只作为显式兼容路径保留，不进入 `harness-lite.yaml` 默认 `skills_whitelist`。
- `agent-configs/codex/config.shared.toml.template`
  - 新增 `entry-router` managed path。
  - 兼容期保留 `using-superpowers` disabled entry，避免旧显式调用路径立刻断。
- `agent-configs/claude/CLAUDE.md.template`
  - 新安装改为 `/entry-router`。
  - alias 保证旧安装态的 `/using-superpowers` 仍可恢复。

关键约束：不能在默认 `harness-lite.yaml` 仍引用 `using-superpowers` 时把它收缩为 alias。否则 alias 会进入默认面，可能越过 whitelist、manifest、team preset 的收口意图。alias 只能在 Phase 2 默认引用切换完成后再启用。

## 4. 分阶段迁移计划

### Phase 0: 文档预告，不改行为

- 在 README / status 中说明 `using-superpowers` 将迁移为 `entry-router`。
- 不改 skill 目录，不改 descriptor。
- 验证：`git grep -n "using-superpowers" -- README.md agent-configs scripts skills tests vault-template docs/aionui-integration` 建立基线。

### Phase 1: 只新增 canonical，不改变默认面

- 新增 `skills/entry-router/SKILL.md`，从当前 `using-superpowers` 搬入完整规则。
- 保持 `skills/using-superpowers/SKILL.md` 完整内容不变，不收缩为 alias。
- 不改 `agent-configs/workflows/harness-lite.yaml`、profiles、role prompts 或 entry templates 的默认引用。
- 更新 exact skill set / validator allowlist：
  - `tests/verify-lite-footprint.ps1`
  - `scripts/validate-lite-artifacts.ps1`
- 可在 README / active docs 中增加“`entry-router` 已引入，默认引用下一阶段切换”的预告；历史 docs/tasks 不动。
- 验证 `verify-lite-footprint.ps1`，确认两个 skill 同时存在，且默认 whitelist 仍未改变。

### Phase 2: 一次性切换默认引用到 entry-router

- 更新 host / entry templates：
  - `agent-configs/claude/CLAUDE.md.template`
  - `agent-configs/codex/AGENTS.md.template`
  - `agent-configs/codex/config.shared.toml.template`
  - `agent-configs/workspace/AGENTS.md.template`
  - `vault-template/entry/AGENTS.md.template`
  - `vault-template/entry/GEMINI.md.template`
- 更新 workflow / profiles / role prompt：
  - `agent-configs/workflows/harness-lite.yaml`
  - `agent-configs/profiles/harness-default-claude.yaml`
  - `agent-configs/profiles/harness-default-codex.yaml`
  - `agent-configs/role-prompts/plan-author.md`
  - `skills/orchestrator/references/state-templates.md`
  - `docs/aionui-integration/team-preset.md`
- 更新 tests 中的 active fixture：
  - `tests/verify-workflow-descriptor.ps1`
  - `tests/verify-team-orchestration.ps1`
  - `tests/verify-lite-footprint.ps1`
  - 必要时更新 `tests/verify-aionui-skill-contract.ps1` 与 `tests/verify-skill-manifest.ps1` 的 PLAN 期望。
- 增加 active path 残留 grep 锁点：
  - 默认面允许 `entry-router`。
  - `using-superpowers` 只允许出现在 `skills/using-superpowers/SKILL.md`、兼容说明、历史 `docs/tasks/*` 或明确 legacy allowlist 中。
  - 建议用测试封装 `git grep -n "using-superpowers" -- README.md agent-configs scripts skills tests vault-template docs/aionui-integration`，再按 allowlist 过滤。
- 补 `scripts/update-managed-assets.ps1` 覆盖：
  - `tests/verify-update-managed-assets.ps1` 应验证 update 会把 workspace/global entry templates、Codex managed config、vault entry 文件从旧名刷新到 `entry-router`。
  - 同时验证用户自有 config / 未管理段不会被粗暴清除。
- 补 manifest/index 断言：
  - `scripts/generate-skills-index.ps1 -Stage PLAN` 输出必须包含 `entry-router`，且 description 来自 `skills/entry-router/SKILL.md`。
  - `scripts/advance-stage.ps1` 的 PLAN available_commands/description 也必须使用 `entry-router`。可用 `PLAN_REVIEW verdict=revise -> PLAN` 的 fixture 触发下一 stage 为 PLAN，再断言 `skill-manifest.json.available_commands` 包含 `entry-router` 且不包含 `using-superpowers`。

### Phase 3: 收缩 using-superpowers 为 legacy alias

- 在 Phase 2 默认引用和 active grep 全部通过后，才把 `skills/using-superpowers/SKILL.md` 改为 legacy alias。
- alias 内容只指向 `entry-router`，不再复制完整规则，避免双源漂移。
- 保留 alias 的测试锁点：
  - alias 目录存在。
  - alias 不在 `harness-lite.yaml` 默认 `skills_whitelist`。
  - alias 不出现在 `skill-manifest.json` / `skills-index.md` 的默认 PLAN available commands。

### Phase 4: 安装 / update 兼容验证

- 跑安装和 update 回归，确认新模板渲染、host skills sync、Codex config managed block 都稳定。
- 确认 `Sync-SkillsDirectory` 会同步 `entry-router` 与 alias；不要让旧 alias 被误当用户自有 skill。
- 生成一次 PLAN 阶段 `skills-index.md` / `skill-manifest.json`，确认 available_commands 使用 `entry-router`，description 来自 canonical SKILL。

### Phase 5: 可选移除 alias

- 只有在确认不再支持旧 `/using-superpowers` 显式调用时才做。
- 需要同时清理 Codex config alias entry、README 兼容说明、tests allowlist。
- 如果没有强烈清理收益，建议长期保留 alias，降低旧安装断裂风险。

## 5. 风险

- 原生 skill 名称可能由目录名或 frontmatter name 决定；canonical 的目录名和 frontmatter 必须一致。
- 保留 alias 会让 `skills/` 数量增加；必须用测试锁住 alias 不进入默认 `skills_whitelist`。
- 最大风险：过早把 `using-superpowers` 收缩为 alias，而默认 `harness-lite.yaml` / role prompt / profile 仍引用旧名；这会让 alias 留在默认面，导致 manifest、team preset、whitelist 的语义不一致。
- 改 `harness-lite.yaml` 会改变 team preset、skill manifest、skills-index 的对外 payload，AionUI 端或下游文档可能依赖旧名称。
- 旧安装态的 Claude 全局指令可能仍调用 `/using-superpowers`；没有 alias 会直接断恢复入口。
- Codex managed config 当前写死 `{CODEX_HOME}\skills\using-superpowers\SKILL.md`，必须通过 update-managed-assets / install 迁移。
- 历史 docs/tasks 中的大量旧名称不应重写；迁移验证时需要限定 active path，否则 grep 会产生预期历史命中。
- `using-superpowers` 内联了 obsidian-memory 核心规则；迁移时若 alias 与 canonical 双份完整内容，会产生文档漂移风险。

## 6. 建议验证命令

- `git grep -n "using-superpowers" -- README.md agent-configs scripts skills tests vault-template docs/aionui-integration`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-preset.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-orchestration.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-skill-manifest.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-harness-entry.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-installation.ps1 -WorkspaceRoot <installed-workspace> -RepoRoot D:\data\claude-dev-harness`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\generate-skills-index.ps1 -TaskId <fixture> -Stage PLAN -BackendHint codex -OutputPath <tmp>\skills-index.md`
- `git diff --check`

## Evidence

- Active reference search: `git grep -n "using-superpowers" -- README.md agent-configs scripts skills tests vault-template docs/aionui-integration docs/team-write-authority.md docs/shared-memory-layers.md`
- Install sync review: `Select-String -Path install.ps1 -Pattern 'Sync-SkillsDirectory|config.shared.toml|AGENTS.md.template|CLAUDE.md.template'`
- Manifest/index review: `Select-String -Path scripts\advance-stage.ps1,scripts\generate-skills-index.ps1,scripts\validate-lite-artifacts.ps1 -Pattern 'skills_whitelist|Get-SkillDescription|available_commands|using-superpowers'`
- Current status before writing this file had only runtime pointer modifications and unrelated untracked task dirs.
