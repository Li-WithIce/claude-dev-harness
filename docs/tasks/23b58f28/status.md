# 23b58f28 Status

## Summary

已完成 entry-router Phase 1 的最小实现：新增 canonical `skills/entry-router/SKILL.md`，保持 `skills/using-superpowers/SKILL.md` 完整不变，未切换 `harness-lite`、profiles、role prompts、entry/host templates 的默认引用。

## Changed Files

- `skills/entry-router/SKILL.md`
  - 从当前 `using-superpowers` 完整规则机械复制，frontmatter 改为 `name: entry-router`。
  - description 明确为 canonical entry router，供 manifest/index 读取。
- `scripts/validate-lite-artifacts.ps1`
  - 将 `entry-router` 加入 workflow skill advisory allowlist。
- `tests/verify-lite-footprint.ps1`
  - exact skill set 加入 `entry-router`。
  - 锁定 `entry-router` 关键入口规则存在。
  - 锁定默认 `PLAN.skills_whitelist` 仍为 `[plan, using-superpowers]`，且未切为 `[plan, entry-router]`。
- `tests/verify-workflow-descriptor.ps1`
  - 增加 opt-in descriptor fixture，确认 `[plan, entry-router]` 可通过 advisory allowlist 且无 warning。
- `tests/verify-skill-manifest.ps1`
  - 增加 opt-in manifest fixture：当 descriptor 显式使用 `[plan, entry-router]` 时，PLAN `skill-manifest.json.available_commands` 可发现 `entry-router` 且读取 canonical description。

## Boundary Checks

- 未修改 `skills/using-superpowers/SKILL.md`。
- 未修改 `agent-configs/workflows/harness-lite.yaml`。
- 未修改 profiles、role prompts、entry/host templates。
- 未处理 test-runner 或 Gemini 兼容面。

## Verification

- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-skill-manifest.ps1` -> PASS
- `git diff --check` -> PASS

## Remaining Risk

- Phase 1 只让 `entry-router` 可被发现；默认 PLAN 仍使用 `using-superpowers`。Phase 2 需要一次性切换 descriptor/profiles/role prompts/templates/tests 的默认引用后，Phase 3 才能把 `using-superpowers` 收缩为 legacy alias。
