# README Workflow / Usage Refresh Code Review

## Findings

- none

## Conclusion

- verdict: pass
- README 当前刷新内容与仓库真实状态一致，已覆盖：
  - 当前用户视角的安装后日常使用方式
  - `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE` 流程与 `plan.md` frontmatter 真相源
  - `.assistant` / `docs/tasks` / `validate-lite-artifacts.ps1` / `git` 的职责分工
  - Phase 5 / 6 / 7 带来的当前约束与入口命令
  - 技能 / 脚本 / hooks / `verify-*.ps1` 计数

## Follow-up

- `skills/using-superpowers/SKILL.md:74-75` 仍保留旧口径：“非 DONE 推进必须由用户显式指定下一阶段 tool”。这和当前 `advance-stage.ps1` 已落地的 Phase 2 `workflow-default` 行为不一致。
- 我将其判定为 **后续 doc-sync 跟进项，不构成这轮 README-only 任务的阻塞 finding**：
  - README 这里记录的是当前实现真相，和 `scripts/advance-stage.ps1` / `agent-configs/workflows/harness-lite.yaml` 一致
  - `skills/using-superpowers/SKILL.md` 不在这轮 README 刷新任务的实现面内，属于仓库里另一个仍待同步的用户入口文档
  - 因此它是 repo-level 文档漂移，不是本次 README 刷新的 correctness bug

## Evidence

- `git status --short README.md docs/tasks/readme-workflow-usage-refresh skills/using-superpowers/SKILL.md agent-configs/workflows/harness-lite.yaml scripts/validate-lite-artifacts.ps1 scripts/advance-stage.ps1`
- `Get-Content .\README.md`
- `Get-Content .\skills\using-superpowers\SKILL.md`
- `Get-Content .\agent-configs\workflows\harness-lite.yaml`
- `Select-String -Path .\scripts\advance-stage.ps1 -Pattern 'resolved tool|workflow-default|Resolve-FallbackSelection|tool_profile|model|updated'`
- `Get-ChildItem .\skills -Directory | Where-Object Name -ne '.system'`
- `Get-ChildItem .\scripts -File -Filter '*.ps1'`
- `Get-ChildItem .\runtime-hooks\claude -File`
- `Get-ChildItem .\tests -File -Filter 'verify-*.ps1'`
- `Select-String -Path .\install.ps1 -Pattern 'settings.local.json|GEMINI.md|runtime-hooks\\claude|Sync-SkillsDirectory'`
