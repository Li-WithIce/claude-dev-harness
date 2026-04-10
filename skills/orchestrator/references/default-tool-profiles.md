# Per-Stage Tool Selection

lite workflow 不再维护固定 profile，也不再根据矩阵推导下一个执行者。

## 合法 tool

- `claudecode`
- `codex`
- `gemini`
- `none`：只允许用于 `DONE`

## 规则

- `plan.md` frontmatter 的 `tool` 表示“当前 stage 由哪个工具继续”
- 新任务进入首个 stage 前，必须由用户显式指定 `tool`
- 非 `DONE` 推进时，必须显式传 `-Tool <claudecode|codex|gemini>`
- `TEST -> DONE` 固定写 `tool: none`
- 用户可以在任意 stage 边界切换 tool

## 不再存在的概念

- 不再写历史默认矩阵名称
- 不再写独立的“下一执行者”字段
- 不再从 `(stage, profile)` 反推执行者
