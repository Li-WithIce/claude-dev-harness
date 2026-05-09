# 12cee303 Status

## Summary

已完成 entry-router Phase 3 legacy alias 收缩，暂未提交。`skills/using-superpowers/SKILL.md` 已从完整入口规则收缩为兼容 alias，只指向 canonical `entry-router`；默认 workflow / manifest / team preset 仍使用 `entry-router`。

## Changed Files

- `skills/using-superpowers/SKILL.md`
  - 保留 frontmatter `name: using-superpowers`，用于旧显式 `/using-superpowers` 调用兼容。
  - 删除完整入口路由、共享记忆、lazy-loading、harness-lite 规则副本。
  - 明确 canonical entry skill 是 `entry-router` / `../entry-router/SKILL.md`。
  - 明确 alias 不应进入 `harness-lite.yaml`、默认 profiles、role prompts、team presets、skill manifests 或 skills-index outputs。
- `tests/verify-lite-footprint.ps1`
  - 将 Phase 3 active grep 说明从 legacy skill 本体更新为 legacy alias 本体。
  - 用 alias 形态锁点替代旧的完整入口规则锁点。
  - 反向锁定 alias 不再包含 `.assistant\entry\advance-stage.ps1`、`mode: quick | workflow | ask`、`禁止 bulk-load 全部 skills` 等完整入口规则。
- `scripts/validate-lite-artifacts.ps1`
  - 保留 `using-superpowers` 在 workflow skill advisory allowlist 中，并加注释说明它只是旧显式调用兼容 alias，不是默认 workflow skill。
- `agent-configs/codex/config.shared.toml.template`
  - 保留 disabled `using-superpowers` managed skill path，并把注释更新为 alias compatibility path。

## Boundary Checks

- `agent-configs/workflows/harness-lite.yaml` 仍为 `PLAN.skills_whitelist: [plan, entry-router]`。
- 默认 profiles、role prompt、team preset、manifest / skills-index 仍不暴露 `using-superpowers`。
- Active grep 只在显式 legacy allowlist 命中旧名：Codex disabled config、validator allowlist、alias 本体、测试锁点。
- 未处理 Gemini / test-runner 兼容面。
- 暂未提交，等待复审。

## Verification

- `git diff --check` -> PASS
- `git grep -n "using-superpowers" -- README.md agent-configs scripts skills tests vault-template docs/aionui-integration docs/team-write-authority.md docs/shared-memory-layers.md docs/工作流` -> only expected legacy allowlist hits
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-skill-manifest.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-harness-entry.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-preset.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-orchestration.ps1` -> PASS

## Remaining Risk

- 旧安装态显式调用 `/using-superpowers` 依赖宿主能继续按该 alias 文本加载并转向 `/entry-router`；本轮只保证 alias 文件仍存在，不改变宿主 skill invocation 机制。
- Codex managed config 仍保留 disabled legacy alias path，这是有意兼容面；未来若移除 alias，需要同步清理 config 模板、validator allowlist、active grep 锁点和 managed-assets 回归。
- 工作树中仍有本任务外的既有噪音：`.assistant/运行时/当前任务.md`、`.assistant/运行时/恢复索引.md`、`docs/tasks/208f019c/`、`docs/tasks/7ebed0f5/`。
