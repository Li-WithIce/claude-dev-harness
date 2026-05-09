# 5f738f27 Status

## Summary

已将旧 Gemini TEST runner skill 迁移为 canonical `test-runner`。默认 `TEST` workflow 仍保持 Codex-only `skills_whitelist: [test]`；Gemini 仅作为显式切换 TEST backend 时的 optional adapter。

## Changed Files

- `skills/test-runner/`
  - 由旧 skill 目录迁移而来，frontmatter 改为 `name: test-runner`。
  - 保留 `scripts/invoke-gemini.ps1`、`ask_gemini.ps1`、环境检查与 bootstrap 脚本作为 Gemini optional adapter。
  - `SKILL.md`、`references/output-contract.md`、`references/cli-usage.md` 改为 backend-neutral 口径。
- `agent-configs/profiles/harness-default-gemini.yaml`
  - `enabled_skills` 从旧 skill 名切到 `test-runner`。
- `scripts/invoke-harness-skill.ps1`
  - adapter whitelist 和 Gemini adapter 路径切到 `test-runner\scripts\invoke-gemini.ps1`。
- `scripts/validate-lite-artifacts.ps1`
  - workflow advisory allowlist 移除旧名，加入 `test-runner`。
- `skills/entry-router/SKILL.md`
  - 显式 Gemini TEST 委派说明切到 `test-runner`。
- `skills/orchestrator/SKILL.md`
  - TEST 阶段默认仍为 `test`；显式 Gemini TEST 才使用 `test-runner`。
- `skills/orchestrator/references/runbook.md`
  - adapter whitelist 文档切到 `test-runner`。
- `tests/verify-aionui-skill-contract.ps1`
  - fixture、mock Gemini adapter、profile-aware lookup、backend fallback negative control 全部切到 `test-runner`。
- `tests/verify-lite-footprint.ps1`
  - 预期 skill set 加入 `test-runner`，锁定旧目录缺席、默认 TEST 不暴露 `test-runner`。

## Verification

- `git diff --check` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-skill-manifest.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-install-isolation.ps1` -> PASS
- Active surface grep for the old skill name across `README.md agent-configs scripts skills tests vault-template docs/aionui-integration docs/team-write-authority.md docs/shared-memory-layers.md docs/工作流` -> no matches
- `Test-Path skills\gemini-designer-main` -> `False`
- `Test-Path skills\test-runner` -> `True`

## Remaining Risk

- 旧显式 skill invocation 已按用户要求不再保留目录或 adapter alias；旧调用会断开。
- Gemini compatibility is preserved through explicit `test-runner` adapter paths and the `harness-default-gemini` profile, not through the default TEST workflow.
