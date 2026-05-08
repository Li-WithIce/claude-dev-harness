# d9047bf0 Status

## Summary

为新任务入口增加 `quick | workflow | ask` 模式路由。原有 `resume-current / switch-existing / new-task / inbox-first` 判定保持不变；只有判定为 `new-task` 后才进入模式路由。

## Routing Rules

- `quick`: 低风险、边界清楚、可在当前对话内直接完成和验证的小改动或简短回答；默认不创建 `docs/tasks/<task-id>/`，不改共享指针。
- `workflow`: 需要计划、留痕、review、test、多文件/跨模块协作、较高风险或用户明确要求可审计产物时，进入 orchestrator 创建 `docs/tasks/<task-id>/plan.md`。
- `ask`: 只在 quick/workflow 置信度低、显式信号冲突或缺少关键判断信息时使用；只问一个最小澄清问题。
- 显式覆盖：`直接改`、`快修` 偏 `quick`；`走 workflow`、`留痕`、`review`、`test` 偏 `workflow`。

## Changed Files

- `README.md`
- `.assistant/工作流/长会话恢复.md`
- `.assistant/工作流/任务识别协议.md`（ignored live vault source）
- `.assistant/工作流/写回协议.md`（ignored live vault source）
- `skills/using-superpowers/SKILL.md`
- `skills/orchestrator/SKILL.md`
- `skills/orchestrator/references/gates.md`
- `skills/orchestrator/references/lite-writing-guide.md`
- `skills/orchestrator/references/runbook.md`
- `vault-template/entry/AGENTS.md.template`
- `vault-template/entry/GEMINI.md.template`
- `vault-template/工作流/任务识别协议.md`
- `vault-template/工作流/写回协议.md`
- `tests/verify-lite-footprint.ps1`

## Verification

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-harness-entry.ps1` -> PASS
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1` -> PASS
- `git diff --check` -> PASS

## Notes

- 未新增执行脚本、阶段或重流程。
- `quick` 是入口轻量路径；`workflow` 继续使用既有 harness-lite stage 和 Codex-only defaults。
