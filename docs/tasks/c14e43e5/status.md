# c14e43e5 Status

## Summary

已完成 entry-router Phase 2 默认引用切换：默认入口从 `using-superpowers` 切到 `entry-router`。`skills/using-superpowers/SKILL.md` 保持完整内容不变，继续作为显式 legacy 兼容 skill；未处理 Gemini/test-runner 迁移。

## Changed Files

- `agent-configs/workflows/harness-lite.yaml`
  - `PLAN.skills_whitelist` 改为 `[plan, entry-router]`。
- `agent-configs/profiles/harness-default-codex.yaml`
- `agent-configs/profiles/harness-default-claude.yaml`
  - 默认 enabled skill 改为 `entry-router`。
- `agent-configs/role-prompts/plan-author.md`
  - Allowed skills 改为 `plan, entry-router`。
- `agent-configs/claude/CLAUDE.md.template`
- `agent-configs/codex/AGENTS.md.template`
- `agent-configs/workspace/AGENTS.md.template`
- `vault-template/entry/AGENTS.md.template`
- `vault-template/entry/GEMINI.md.template`
- `vault-template/工作流/任务识别协议.md`
  - lazy-loading / entry 文案改为默认加载 `entry-router`。
- `agent-configs/codex/config.shared.toml.template`
  - 新增 managed `entry-router` skill path。
  - 保留 disabled `using-superpowers` path，并标记为 legacy explicit compatibility path。
- `README.md`
- `docs/aionui-integration/team-preset.md`
- `skills/orchestrator/references/runbook.md`
- `skills/orchestrator/references/state-templates.md`
- `skills/obsidian-memory/SKILL.md`
  - active docs / examples / references 切到 `entry-router`。
- `tests/verify-lite-footprint.ps1`
  - 锁定默认 descriptor/profile/template/role prompt 使用 `entry-router`。
  - 新增 active path grep 锁点：`using-superpowers` 只允许出现在 legacy skill、Codex disabled legacy config、validator repository allowlist。
- `tests/verify-workflow-descriptor.ps1`
  - 默认 fixture 改为 `entry-router`；保留显式 legacy allowlist 兼容检查。
- `tests/verify-skill-manifest.ps1`
  - 默认 PLAN manifest / skills-index 锁定 `entry-router` available command 与 description。
- `tests/verify-aionui-skill-contract.ps1`
  - `generate-skills-index -Stage PLAN` 锁定 `entry-router`。
- `tests/verify-team-orchestration.ps1`
  - plan-author spawned payload skill whitelist 改为 `entry-router`。
- `tests/verify-update-managed-assets.ps1`
  - 锁定 install/update 后 Codex/Claude/workspace/vault entry 默认刷新到 `entry-router`，同时保留 Codex legacy disabled path。

## Boundary Checks

- `git diff -- skills/using-superpowers/SKILL.md` -> no diff.
- Active path grep:
  - `agent-configs/codex/config.shared.toml.template` legacy disabled path.
  - `scripts/validate-lite-artifacts.ps1` repository skill allowlist.
  - `skills/using-superpowers/SKILL.md` legacy skill body.
  - No default README / workflow / profile / role prompt / template / team doc match remains.

## Verification

- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-skill-manifest.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-preset.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-orchestration.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-harness-entry.ps1` -> PASS
- `git diff --check` -> PASS
- `git ls-files -d` -> no output

## Remaining Risk

- Phase 3 仍未执行：`using-superpowers` 仍是完整 legacy skill，而不是 alias stub。必须等默认引用与 active grep 锁点稳定后，单独把它收缩为 legacy alias。
- Codex managed config 仍保留 disabled `using-superpowers` path，用于旧显式调用兼容；未来若移除 alias，需要同步更新 config 模板和 managed update 回归。
- 提交卫生：`.assistant/运行时/当前任务.md`、`.assistant/运行时/恢复索引.md` 仍是既有 runtime pointer 修改；`docs/tasks/208f019c/*`、`docs/tasks/7ebed0f5/*` 仍是无关未跟踪任务资料。本轮应排除这些项，只纳入 Phase 2 相关文件与 `docs/tasks/c14e43e5/status.md`。
