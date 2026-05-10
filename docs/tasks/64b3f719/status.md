---
task_id: 64b3f719
task: correct Open Design / huashu integration toward Markdown HTML workflow boundary
owner: design-verifier
updated: 2026-05-10
status: implemented-with-validation
---

# Markdown / HTML Workflow Boundary

## Goal

把用户澄清后的核心目标落到 harness workflow：Markdown 是人类与 AI 共同编辑、审阅、版本控制的 canonical source；HTML 是 generated display artifact，用于预览、视觉检查、发布与交付。

## Decisions

- 新增 functional skill：`md-html`。
- 不新增 workflow stage，不修改 `agent-configs/workflows/harness-lite.yaml`。
- 不引入外部 runtime 依赖，不安装 npm/pnpm/pip 工具。
- 不触碰 `%USERPROFILE%\.codex\config.toml`。
- 撤回上一轮偏题的 `work_type: design` 扩展；默认 PLAN / IMPLEMENT / REVIEW / TEST 文档纪律保持原状。

## Changed

- `skills/md-html/SKILL.md`
  - 触发条件：Markdown/HTML 互转、HTML report、网页 artifact、发布预览、URL/HTML -> Markdown 导入。
  - 契约：Markdown 默认 source of truth；HTML 默认 generated artifact；HTML -> Markdown 不承诺像素级还原；Markdown -> HTML 应可重复生成。
  - 模式：`quick` 小文档直接转换；`workflow` 复杂交付声明 source/artifact/template/verification；`ask` 缺少方向、路径或保真要求时问一个问题。
- `skills/md-html/references/checklist.md`
  - 覆盖结构、语义、可读性、视觉、可维护性。
  - 增加 P0/P1 gate 和漂移检查。
- `skills/md-html/references/pipeline.md`
  - 文档化 Markdown -> HTML、HTML/URL -> Markdown、双向协作边界。
  - 仅列可选工具链参考：`markitdown`、`pandoc`、`html-to-markdown`、`trafilatura`，不引入依赖。
- `skills/entry-router/SKILL.md`
  - 增加 Markdown / HTML artifact route，说明 quick/workflow/ask 如何按需加载 `md-html`。
- `skills/orchestrator/references/lite-writing-guide.md`
  - 增加 PLAN 写作边界：source/artifact 分开，复杂任务用 `artifacts:` 声明 Markdown source、HTML artifact 和验证方式。
- `skills/orchestrator/SKILL.md`、`skills/orchestrator/references/runbook.md`
  - 同步懒加载说明：Markdown/HTML artifact 任务可额外加载 `md-html`，不新增 stage，不进入默认 stage whitelist。
- `agent-configs/profiles/harness-default-codex.yaml`、`agent-configs/profiles/harness-default-claude.yaml`
  - 将 `md-html` 加入可用 skill 列表，便于入口按需加载；`harness-lite.yaml` 的 stage whitelist 不变。
- `scripts/validate-lite-artifacts.ps1`
  - 将 `md-html` 加入 workflow descriptor advisory allowlist，避免未来显式引用时被当作 legacy/unknown skill；默认 descriptor 未改。
- `README.md`
  - 增加 Markdown / HTML artifact 能力说明和当前仓库清单中的 `md-html`。
- `tests/verify-lite-footprint.ps1`
  - skill footprint 白名单纳入 `md-html`。
  - 锁定 `README`、`entry-router`、`md-html` skill 和 references 的关键边界文案。
- `tests/verify-install-isolation.ps1`
  - 增加 `%USERPROFILE%\.codex\config.toml` sentinel/hash 锁点，确认安装隔离测试不会修改用户 owned Codex config。

## Verification

- PASS: `git diff --check`
- PASS: `pwsh -NoProfile -File tests\verify-lite-footprint.ps1`
- PASS: `pwsh -NoProfile -File tests\verify-install-isolation.ps1`
- PASS: `pwsh -NoProfile -File tests\verify-tool-profile.ps1`
- PASS: `pwsh -NoProfile -File tests\verify-workflow-descriptor.ps1`
- PASS: `pwsh -NoProfile -File tests\verify-skill-manifest.ps1`
- PASS: `pwsh -NoProfile -File tests\verify-aionui-skill-contract.ps1`
- PASS: `rg -n "work_type: design|design\.surface|Design artifact checks|Open Design" README.md skills agent-configs scripts tests` returned no matches.
- PASS: `git diff --name-only -- agent-configs\workflows\harness-lite.yaml scripts\advance-stage.ps1 agent-configs\codex\config.shared.toml.template` returned no paths.
- PASS: `rg -n "using-superpowers|gemini-designer" README.md agent-configs scripts skills vault-template docs\aionui-integration docs\team-write-authority.md docs\shared-memory-layers.md docs\工作流` returned no matches.
- PASS: `verify-lite-footprint` existing active-surface greps reported no `using-superpowers` or old Gemini designer naming leaks.

## Review Focus

- `md-html` 是否足够清晰地区分 Markdown source 与 HTML generated artifact。
- 是否仍保持 default harness-lite stage whitelist 不变。
- `verify-lite-footprint` 的 expected skill set 是否是本轮唯一必要测试锁点，是否还需要后续补更专门的 conversion fixture。
