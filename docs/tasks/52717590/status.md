# 52717590 Status

## Summary

为 `quick / workflow / resume` 增加协议级自动懒加载规则。现有 `resume-current / switch-existing / new-task / inbox-first` 判定保持不变；`new-task` 仍先路由到 `quick | workflow | ask`，随后才按模式加载下一层材料。

## Lazy Loading Rules

- `quick`: 只加载入口规则、用户偏好 / 必要配置，以及与本次请求直接相关的 skill 或 reference；不预读 orchestrator、全部 stage skill 或历史任务。
- `workflow`: 加载 `using-superpowers`、`orchestrator`，再按当前 stage 加载一个阶段 skill：`PLAN -> plan`、`PLAN_REVIEW -> review`、`IMPLEMENT -> implement`、`CODE_REVIEW -> review`、`TEST -> test`。
- `resume-current` / `switch-existing`: 先加载 `恢复索引.md`、`当前任务.md`、`运行时/tasks/<task-id>.md`；必要时只读当前任务 `plan.md` frontmatter 判定 stage，再加载当前 stage skill。
- `ask`: 不加载 workflow skill，只问一个最小澄清问题。
- 禁止 bulk-load 全部 skills、全部历史任务、Gemini / Claude 兼容 skill、`workflow-team`；显式 backend、stage/frontmatter 或 team-mode 触发时除外。

## Changed Files

- `README.md`
- `agent-configs/codex/AGENTS.md.template`
- `agent-configs/workspace/AGENTS.md.template`
- `.assistant/工作流/长会话恢复.md`
- `vault-template/entry/AGENTS.md.template`
- `vault-template/entry/GEMINI.md.template`
- `vault-template/工作流/任务识别协议.md`
- `vault-template/工作流/恢复协议.md`
- `skills/using-superpowers/SKILL.md`
- `skills/orchestrator/SKILL.md`
- `skills/orchestrator/references/runbook.md`
- `tests/verify-lite-footprint.ps1`
- `docs/tasks/52717590/status.md`

## Verification

- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` -> PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-harness-entry.ps1` -> PASS
- `git diff --check` -> PASS

## Notes

- 未新增脚本、执行器、stage 或 team-mode 自动入口。
- 未修改 `.assistant/运行时/当前任务.md`、`.assistant/运行时/恢复索引.md`。
