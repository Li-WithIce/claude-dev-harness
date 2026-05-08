---
name: implement
description: Use when the task is in IMPLEMENT and code plus fresh implementation evidence must be appended to `plan.md`.
---

# Implement

IMPLEMENT 负责两件事：改代码，以及把本轮实现证据追加到 `docs/tasks/<task-id>/plan.md` 的 `## Implementation Notes`。

## 何时使用

- `plan.md` frontmatter 的 `stage` 是 `IMPLEMENT`
- 需要按已确认计划实现代码
- CODE_REVIEW 给出 `revise` 后，需要补新实现并追加新证据

## 硬约束

- 不写独立 `implementation-notes.md`
- 只追加新的 `### Run N`，不改旧 run
- 回修轮必须追加一条比最近一次 `Code Review` 更晚的 Implementation Notes run
- 不手改 frontmatter 的 `stage`

## Run 格式

```markdown
## Implementation Notes

### Run 2 · 2026-04-09 11:00 · runner: Codex
- changed: 修改的文件和行为
- tests: 实际跑过的命令；没跑就写 none
- risks: 本轮残留风险；没有就写 none
- next: 交给 CODE_REVIEW 关注什么
```

## Implementation Reflection Checks

实现前后做一次轻量反射，只在命中风险时记录到本轮 `- risks:` 或立刻停下询问；未命中时不需要逐项打勾。

重点只看 5 类 AI 常见失败信号：

- oversized-file stuffing: 是否继续往已过大的文件塞逻辑，而不是拆到更合适的位置。
  例：在已明显臃肿的 `SKILL.md` 继续追加新流程，而不是抽到既有 reference。
- 计划外抽象: 是否新增 PLAN 没声明的分支、层级、接口或抽象。
  例：PLAN 只要求修一个解析分支，却新增 resolver registry 或策略层。
- 邻近顺手重构: 是否顺手改了当前验收范围外的邻近代码。
  例：为修 A 文件顺手整理同目录 B/C 文件命名、格式或结构。
- 未声明新概念: 是否引入 PLAN / spec 没有定义的新术语、状态或配置口径。
  例：实现里新增 `mode=legacy-safe`，但 PLAN / spec 没有定义该模式。
- 症状补丁: 是否只压住表面现象，而没有处理 PLAN 中要求验证的根因或约束。
  例：只吞掉异常或跳过失败用例，没有验证 PLAN 要求定位的根因。

命中任一项时，先判断是否仍在已确认 PLAN 内：在范围内就把理由、取舍和验证补到 `- risks:` / `- next:`；超出范围就停止实现，要求回 PLAN 或拆新任务。不要新增反射 stage、独立 checklist 或新的 Implementation Notes 字段。

## 工作流程

1. 读取 `plan.md` 和可选 `spec.md`
2. 只实现当前计划要求的内容
3. 跑最小必要验证
4. 在 `## Implementation Notes` 末尾追加新 run
5. 推进到 `CODE_REVIEW` 前，默认使用 workflow descriptor 的 `harness-default-codex`；如需切换 backend，再让用户指定下一阶段 `tool`
6. 调用 `.assistant\entry\advance-stage.ps1 -TaskId <task-id>` 进入 `CODE_REVIEW`；切换 backend 时追加 `-Tool <next-tool>`
7. 如需单独排查文档问题，再手动运行 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>`

## TodoWrite Milestones

- 适用：`claudecode`；其余 backend 视宿主实现而定。
- TodoWrite 是 Claude Code 内置 surface，不引入新依赖。
- milestone 是事件，不是签到点；一旦发现 blocker、计划外改动或验证无法完成，必须立刻汇报。
- 推荐最小节奏固定为：`context-loaded` → `code-edited` → `tests-run` → `notes-appended`。
- `notes-appended` 完成后，必须与最终的 stage callback / `team_send_message` / 用户回报配对，不能只停在本地 TodoWrite。
- 最小示例：
  - `context-loaded`：已读完 `plan.md`、`spec.md` 与目标文件
  - `code-edited`：本轮代码或文档改动已落盘
  - `tests-run`：本轮最小必要验证已执行并记录结果
  - `notes-appended`：`Implementation Notes` 已追加新 run，准备交给 `CODE_REVIEW`

## 不要做的事

- 不要重写旧 run
- 不要把 CODE_REVIEW 的结论写进 Implementation Notes
- 不要把 TEST 结论提前写进 `test.md`
