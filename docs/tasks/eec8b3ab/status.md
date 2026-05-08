# eec8b3ab Status

## Summary

审计 Codex-only 后的遗留配置面，重点检查 `gemini`、`claudecode`、多后端默认语义、profiles、skills、templates、scripts 和 tests。结论：当前仓库默认路径已是 Codex-only；未确认有可直接删除且不破坏显式 backend override / 安装验证 / 历史 fixture 的 tracked 项。已做最小安全清理：移除 `plan` / `implement` / `review` skill 中 TodoWrite 对 `claudecode` 的硬偏置，改为宿主 surface 中性表述。

## 1. 可直接删除或改名的遗留项

- 无已确认安全删除项。
- 可直接改写项已处理：
  - `skills/plan/SKILL.md`
  - `skills/implement/SKILL.md`
  - `skills/review/SKILL.md`
  - 将 `适用：claudecode` 的 TodoWrite milestone 文案改为“宿主提供 TodoWrite surface 时使用；不作为 Codex-only 默认流程的必需依赖”。

## 2. 应保留为显式兼容路径的项

- `agent-configs/profiles/harness-default-claude.yaml`、`agent-configs/profiles/harness-default-gemini.yaml`
  - 理由：`advance-stage.ps1 -Tool/-Profile` 仍支持显式 backend override；`verify-tool-profile.ps1` 和 `verify-workflow-descriptor.ps1` 覆盖该兼容语义。
- `skills/gemini-designer-main/`
  - 理由：仅在显式 Gemini TEST 路径使用；默认 TEST skill 集仍只有 `test`。
- `scripts/advance-stage.ps1` / `scripts/validate-lite-artifacts.ps1` 中的 `claudecode | codex | gemini` tool enum
  - 理由：这是 frontmatter 兼容 schema 和显式 override 合法集合，不是默认调度矩阵。
- `scripts/invoke-harness-skill.ps1` 的 `gemini-designer-main` adapter
  - 理由：显式 Gemini adapter 路径仍被 `verify-aionui-skill-contract.ps1` 覆盖。
- `agent-configs/claude/*`、`runtime-hooks/claude/*`
  - 理由：Claude Code host 兼容和共享记忆 hook 仍是安装面的一部分。
- `agent-configs/workspace/GEMINI.md.template`、`vault-template/entry/GEMINI.md.template`、安装生成 `GEMINI.md`
  - 理由：Gemini 显式 backend 依赖 workspace entry；安装/更新验证仍锁该文件。

## 3. 需要先更新测试/模板才能删除的项

- 删除 `harness-default-claude` / `harness-default-gemini`
  - 需要同步更新 profile parser、workflow descriptor tests、tool-profile tests、README 和 default-tool-profiles 文档；否则显式 override 和 mismatch rejection 测试会破坏。
- 删除 `gemini-designer-main`
  - 需要同步更新 `scripts/invoke-harness-skill.ps1` whitelist/adapter、`verify-aionui-skill-contract.ps1`、skills-index 相关测试和文档；否则显式 Gemini TEST 路径会破坏。
- 移除 `GEMINI.md` 安装面
  - 需要同步更新 `install.ps1`、`verify-installation.ps1`、`verify-update-managed-assets.ps1`、`.gitignore` 管理条目、workspace/vault entry 模板和 README；否则安装验证会失败。
- 将 tool enum 改为 Codex-only
  - 需要迁移 `plan.md` frontmatter schema、validator、advance-stage、legacy fixture 和所有 claudecode/gemini override 回归；这会主动放弃显式 backend override，不建议作为本轮清理。

## 4. 不应动的项

- `.assistant/运行时/当前任务.md`、`.assistant/运行时/恢复索引.md`
  - 理由：live runtime pointer，不属于本轮配置清理。
- `.aionrs/`、`.tmp/`
  - 理由：本地运行噪音。
- `docs/tasks/208f019c/`、`docs/tasks/7ebed0f5/`
  - 理由：无关未跟踪任务 artifact。
- 历史测试 fixture 中的 `claude-codex-gemini-default`
  - 理由：用于验证 legacy invalid tool 被拒绝，不是活跃默认语义。
- 已提交的历史 `docs/tasks/*` artifact
  - 理由：审计证据和历史任务记录，不应为配置收缩重写。

## Verification

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1` -> PASS
- `git diff --check` -> PASS

## Changed Files

- `skills/plan/SKILL.md`
- `skills/implement/SKILL.md`
- `skills/review/SKILL.md`
- `tests/verify-lite-footprint.ps1`
- `docs/tasks/eec8b3ab/status.md`
