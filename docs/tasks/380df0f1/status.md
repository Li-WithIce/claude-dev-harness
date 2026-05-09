# test-runner Functionalization Migration Map

## Summary

目标不是删除 Gemini 兼容性，而是把当前 backend-specific `gemini-designer-main` 功能上移为 backend-neutral `test-runner`，让 Gemini 变成 `test-runner` 的 optional adapter / legacy alias。

当前默认 TEST 已是 Codex-only：`agent-configs/workflows/harness-lite.yaml` 的 TEST stage 使用 `default_profile: harness-default-codex` 和 `skills_whitelist: [test]`。迁移必须保持这个默认不变。

## 1. 当前 `gemini-designer-main` 引用图

活跃引用面：

- `skills/gemini-designer-main/SKILL.md`
  - frontmatter `name: gemini-designer-main`
  - 语义是 Gemini selected TEST runner，要求只读生成 / 更新 `docs/tasks/<task-id>/test.md`
  - 依赖 `references/cli-usage.md`、`references/output-contract.md`
- `skills/gemini-designer-main/scripts/*`
  - `ask_gemini.ps1` / `ask_gemini.sh` 是面向人工/agent 的 CLI wrapper
  - `invoke-gemini.ps1` 是 `scripts/invoke-harness-skill.ps1` 调用的结构化 adapter target
  - `bootstrap-gemini-project.ps1`、`check-gemini-env.ps1` 是 Gemini CLI 环境辅助
- `agent-configs/profiles/harness-default-gemini.yaml`
  - `backend: gemini`
  - `skills_dirs: [.gemini/skills]`
  - `enabled_skills: [test, gemini-designer-main]`
  - 仅作为显式 Gemini profile / backend override
- `scripts/invoke-harness-skill.ps1`
  - `$AllowedSkills = @('review', 'test', 'gemini-designer-main', 'codex')`
  - `Resolve-AdapterScriptPath` 将 `gemini-designer-main` 解析到 `<skill-root>\gemini-designer-main\scripts\invoke-gemini.ps1`
  - main switch 中 `gemini-designer-main` 分支传 `Workspace` / `Prompt` / `OutputFormat json` / `ApprovalMode plan` / `Model`
- `scripts/validate-lite-artifacts.ps1`
  - `Get-AllowedWorkflowSkills` advisory allowlist 包含 `gemini-designer-main`
- `skills/entry-router/SKILL.md`
  - 将 `gemini-designer-main` 描述为显式 Gemini TEST 阶段才使用的可选委派 skill
- `skills/orchestrator/SKILL.md`
  - lazy loading 与调度规则明确默认 TEST 只加载 `test`；显式 Gemini 路径才加载 / 发起 `gemini-designer-main`
- `skills/orchestrator/references/runbook.md`
  - adapter 白名单文档仍写 `review` / `test` / `gemini-designer-main` / `codex`
- `tests/verify-aionui-skill-contract.ps1`
  - fixture 拷贝 `skills\gemini-designer-main`
  - mock Gemini adapter path 为 `gemini-designer-main\scripts\invoke-gemini.ps1`
  - B2 / B3 覆盖 profile-aware Gemini adapter resolution 和 backend fallback negative control
  - E1 锁定默认 TEST skills-index 不暴露 `gemini-designer-main`
- `tests/verify-lite-footprint.ps1`
  - expected skill set 包含 `gemini-designer-main`
  - tester role prompt 不允许 `Allowed skills: test, gemini-designer-main`
- 历史 `docs/tasks/*`
  - 多处历史计划 / 分析引用旧名，应作为历史证据保留，不做批量重写

非默认但相关的安装面：

- `install.ps1` 只同步 Claude / Codex host skills，不同步 `.gemini/skills`
- `agent-configs/workspace/GEMINI.md.template` 与 `vault-template/entry/GEMINI.md.template` 保留 Gemini workspace entry
- `tests/verify-installation.ps1` / `tests/verify-update-managed-assets.ps1` 验证 Gemini entry 文件，但不验证 `.gemini/skills` 同步

## 2. 推荐目标结构

推荐最终结构：

- `skills/test-runner/SKILL.md`
  - backend-neutral TEST runner contract
  - 说明 `test-runner` 是可选委派层：默认 TEST 仍先使用 `test` markdown skill；只有显式 backend adapter / non-native skill invocation 需要结构化 runner 时才用
  - 统一保留当前 output contract：`# Test Report`、`## Conclusion`、`## Handoff`，verdict 为 `pass | fail | blocked`
- `skills/test-runner/references/output-contract.md`
  - 从 `gemini-designer-main/references/output-contract.md` 抽出，不带 Gemini 名称
- `skills/test-runner/references/cli-usage.md`
  - 写 backend-neutral usage，并列出 Gemini adapter 是当前唯一已落地 adapter
- `skills/test-runner/adapters/gemini/`
  - 推荐迁移 `invoke-gemini.ps1`、`ask_gemini.ps1`、`check-gemini-env.ps1`、`bootstrap-gemini-project.ps1`
  - 也可以先放 `scripts/invoke-gemini.ps1`，但 adapter 子目录更清楚地区分 skill contract 与 backend implementation
- `skills/gemini-designer-main/SKILL.md`
  - Phase 3+ 收缩为 legacy alias：保留 `name: gemini-designer-main`
  - 明确 canonical skill 是 `test-runner`
  - 显式旧调用时转向 `test-runner` 的 Gemini adapter，不再承载完整 TEST runner 规则
- adapter dispatch
  - `scripts/invoke-harness-skill.ps1 -Skill test-runner -Tool gemini` 调用 `test-runner/adapters/gemini/invoke-gemini.ps1`
  - 兼容期允许 `-Skill gemini-designer-main -Tool gemini` 走同一个 adapter，并发出 legacy diagnostic

## 3. 分阶段迁移计划

Phase A - 新增 canonical `test-runner`，不切默认：

- 新增 `skills/test-runner/`，内容从当前 Gemini skill 抽象为 backend-neutral contract
- 保持 `skills/gemini-designer-main/` 完整不变
- `agent-configs/workflows/harness-lite.yaml` 不变：TEST 仍是 `[test]`
- `harness-default-gemini.yaml` 暂时仍启用 `test` + `gemini-designer-main`
- 增加 footprint 锁点：仓库 skill set 包含 `test-runner`，但默认 TEST whitelist 不包含它

Phase B - adapter 支持双名：

- `scripts/invoke-harness-skill.ps1` allowlist 增加 `test-runner`
- `Resolve-AdapterScriptPath` 支持：
  - `test-runner` + `Tool=gemini` -> `skills/test-runner/adapters/gemini/invoke-gemini.ps1`
  - `gemini-designer-main` -> 同一路径或旧路径 compatibility
- `tests/verify-aionui-skill-contract.ps1` 新增 B2'：`-Skill test-runner -Tool gemini -ToolProfileId <profile>` 能调用 Gemini adapter
- 保留原 B2/B3 legacy 用例，证明旧名仍可用

Phase C - 显式 Gemini profile 切到 `test-runner`：

- `agent-configs/profiles/harness-default-gemini.yaml` 改为 `enabled_skills: [test, test-runner]`
- `gemini-designer-main` 只作为 legacy alias，不再出现在 profile 默认 enabled list
- `scripts/validate-lite-artifacts.ps1` allowlist 同时保留 `test-runner` 和 legacy `gemini-designer-main`
- 更新 docs：`entry-router`、`orchestrator`、`runbook` 改称 `test-runner`；括注 Gemini 是 optional adapter
- 默认 workflow / team preset 保持 Codex-only TEST `[test]`

Phase D - 收缩 legacy alias：

- 将 `skills/gemini-designer-main/SKILL.md` 收缩为 alias wrapper，指向 `../test-runner/SKILL.md`
- 旧脚本路径可二选一：
  - 稳妥：保留 `skills/gemini-designer-main/scripts/invoke-gemini.ps1` 为薄 wrapper，转调 `../../test-runner/adapters/gemini/invoke-gemini.ps1`
  - 激进：只在 `invoke-harness-skill.ps1` 做旧名转发，不保留旧脚本 wrapper
- 建议采用稳妥方案，降低外部旧安装态直接调用脚本路径的断裂风险

Phase E - 长期可选清理：

- 跨至少一次 install/update 周期后，再评估是否移除 `gemini-designer-main` from advisory allowlist
- 不建议删除 `skills/gemini-designer-main/`，除非明确放弃旧显式 `/gemini-designer-main` 调用

## 4. 需要同步的面

配置与 workflow：

- `agent-configs/profiles/harness-default-gemini.yaml`
- `agent-configs/workflows/harness-lite.yaml`：默认 TEST 应保持 `[test]`，新增 negative lock
- `agent-configs/role-prompts/tester.md`：继续只允许 `test`
- `agent-configs/codex/config.shared.toml.template`：如需要 Codex 显式可见 `test-runner`，增加 disabled path；legacy `gemini-designer-main` 是否加入取决于是否需要 Codex native skill list 发现旧名

脚本：

- `scripts/invoke-harness-skill.ps1`
- `scripts/validate-lite-artifacts.ps1`
- `scripts/generate-skills-index.ps1`：无需逻辑改动，但测试要证明默认 TEST index 不暴露 `test-runner`，显式 adapter index 若未来支持 profile-aware index 再扩展
- `scripts/advance-stage.ps1`：通常无需改，只要 manifest 仍由 workflow whitelist 驱动；需要增加锁点防止 TEST manifest 意外出现 `test-runner`
- `scripts/export-team-preset.ps1` / `skills/workflow-team/scripts/spawn-team.ps1`：不改逻辑，只跑回归证明 tester payload 仍只有 `test`

测试：

- `tests/verify-lite-footprint.ps1`
  - expected skill set 加 `test-runner`
  - 锁默认 TEST whitelist / tester prompt 不包含 `test-runner` 或 `gemini-designer-main`
  - 锁 `gemini-designer-main` alias shape
- `tests/verify-aionui-skill-contract.ps1`
  - fixture 拷贝 `skills\test-runner`
  - 新增 canonical `test-runner` Gemini adapter path positive case
  - 保留 legacy `gemini-designer-main` positive / negative compatibility case
- `tests/verify-workflow-descriptor.ps1`
  - TEST workflow-default 仍输出 `TEST | codex`
  - TEST manifest only `test`
- `tests/verify-skill-manifest.ps1`
  - 默认 stage manifest / skills-index 不暴露 adapter-only skills
- `tests/verify-team-preset.ps1`
  - preset skills_whitelist 仍等于 workflow descriptor
- `tests/verify-team-orchestration.ps1`
  - tester spawned payload skills 仍为 `['test']`
- `tests/verify-update-managed-assets.ps1`
  - 如果 Codex managed config 增加 `test-runner` disabled path，需要同步锁点
- `tests/verify-installation.ps1`
  - 若决定开始同步 `.gemini/skills`，必须新增安装验证；但本迁移建议不把 Gemini host skill sync 拉进第一阶段
- `tests/verify-tool-profile.ps1`
  - `harness-default-gemini` enabled skills 迁移到 `test-runner` 后应锁定

文档 / 模板：

- `README.md`
- `skills/entry-router/SKILL.md`
- `skills/orchestrator/SKILL.md`
- `skills/orchestrator/references/runbook.md`
- `skills/orchestrator/references/default-tool-profiles.md`
- `skills/orchestrator/references/lite-writing-guide.md`
- `vault-template/entry/AGENTS.md.template`
- `vault-template/entry/GEMINI.md.template`
- `agent-configs/claude/CLAUDE.md.template`
- `agent-configs/codex/AGENTS.md.template`
- `agent-configs/workspace/AGENTS.md.template`
- `docs/aionui-integration/team-preset.md` only if examples mention adapter skills; stage whitelist should remain `[test]`

## 5. Alias / compatibility 策略

推荐策略：长期保留 `gemini-designer-main` 作为 legacy alias。

- 用户显式 `/gemini-designer-main`：加载 alias 后转向 `/test-runner`
- `invoke-harness-skill.ps1 -Skill gemini-designer-main -Tool gemini`：兼容期转发到 `test-runner` Gemini adapter
- 旧脚本路径：保留 thin wrapper，转调新 adapter
- workflow descriptor：不把 legacy alias 加回默认 TEST whitelist
- profile：`harness-default-gemini` 从 `gemini-designer-main` 迁到 `test-runner`，但 advisory validator 继续接受旧名一段时间
- docs：当前任务以后只在 compatibility / historical context 中提 `gemini-designer-main`

## 6. 风险

- 默认 TEST 回归风险：若把 `test-runner` 加入 `agent-configs/workflows/harness-lite.yaml` TEST whitelist，会破坏 Codex-only 默认和 team preset tester payload。
- adapter path 断裂风险：当前测试硬编码 `gemini-designer-main\scripts\invoke-gemini.ps1`；迁移时必须先双路支持，再改测试。
- profile-aware resolution 风险：`invoke-harness-skill.ps1` 依赖 `ToolProfileId` 的 `skills_dirs`；新 `test-runner` adapter 必须继续覆盖 project-level `.assistant\skills` 与 user-level profile dirs。
- install 语义扩大风险：现在 install 只同步 Claude/Codex skills，不同步 `.gemini/skills`；不要在同一迁移里顺手引入 Gemini host skill sync，除非单独设计安装验证。
- 文档双源漂移风险：如果 `gemini-designer-main` 保留完整规则而 `test-runner` 也有完整规则，会再次出现 canonical / legacy 双份规则漂移；Phase D 应收缩旧 skill。
- 历史 docs 噪音：`docs/tasks/*` 中旧名很多，不应批量改写；active grep 应区分当前面和历史证据。

## 7. 建议验证命令

只读 / 静态基线：

- `git grep -n "gemini-designer-main" -- README.md agent-configs scripts skills tests vault-template docs/aionui-integration docs/team-write-authority.md docs/shared-memory-layers.md docs/工作流`
- `git grep -n "test-runner" -- README.md agent-configs scripts skills tests vault-template docs/aionui-integration docs/team-write-authority.md docs/shared-memory-layers.md docs/工作流`
- `git diff --check`
- `git ls-files -d`

迁移实现后回归：

- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-skill-manifest.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-harness-entry.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-preset.ps1`
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-orchestration.ps1`

关键断言：

- 默认 `harness-lite` TEST remains `skills_whitelist: [test]`
- default TEST manifest / skills-index exposes `test` only
- explicit `-Skill test-runner -Tool gemini -ToolProfileId <gemini-profile>` delegates successfully
- legacy `-Skill gemini-designer-main -Tool gemini` still delegates or emits clear compatibility forwarding behavior
- `harness-default-gemini` uses `test-runner`, not `gemini-designer-main`, after profile migration
