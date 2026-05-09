---
name: test-runner
description: Use when an explicit TEST-stage adapter should produce a read-only, evidence-based `docs/tasks/<task-id>/test.md`; Gemini is the current optional adapter.
---

# Test Runner

`test-runner` 是 TEST 阶段的显式委派入口。默认 TEST 仍只加载 `test`；只有任务明确切到 Gemini TEST 路径时，才通过这里调用 Gemini optional adapter。它不改代码，只根据现有证据生成或更新 `docs/tasks/<task-id>/test.md`。

## 何时使用

- `plan.md` frontmatter 的 `stage` 是 `TEST`
- `plan.md` frontmatter 的 `tool` 是 `gemini`，或调用方显式选择 Gemini adapter
- 需要根据现有证据生成 `test.md`

## 输入

- `docs/tasks/<task-id>/plan.md`
- `docs/tasks/<task-id>/spec.md`（如存在）
- 已有日志、截图、命令输出
- 任何补充证据文件

## 硬约束

- 不生成独立 `review.md` 或 `implementation-notes.md`
- 不虚构测试执行
- 证据不足时结论只能是 `blocked`
- 输出必须满足 `test` skill 的 heading 契约，尤其是 `## Conclusion` 和 `## Handoff`

## 工作方式

1. 先确认当前任务在 `TEST`
2. 显式把 `plan.md`、可选 `spec.md` 和真实证据通过 `--file` 传给所选 adapter
3. 生成 `docs/tasks/<task-id>/test.md`
4. 回读输出，确认格式和结论合法
5. 只有结论为 `pass` 时才调用 `advance-stage.ps1`

## References

- CLI usage: [references/cli-usage.md](references/cli-usage.md)
- Output contract: [references/output-contract.md](references/output-contract.md)
