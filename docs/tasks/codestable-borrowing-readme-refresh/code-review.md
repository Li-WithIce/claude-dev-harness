---
task_id: codestable-borrowing-readme-refresh
review_type: code-review
tool: codex
updated: 2026-04-30
reviewer: workflow-analyst
verdict: revise
---

# Code Review — README CodeStable 借鉴 guidance 刷新

## 范围

只审 `README.md` 当前未提交的 diff（35 行新增），不复审实现面。对照基准为已提交的 P1/P2/P3 surface（`skills/plan/SKILL.md`、`skills/test/SKILL.md`、`skills/review/SKILL.md`、`skills/implement/SKILL.md`、`skills/orchestrator/references/lite-writing-guide.md`）。

## 边界检查

| # | 检查 | 结果 | 依据 |
|---|---|---|---|
| 1 | README 准确反映已落地行为 | pass（除 finding 1 外） | `work_type` 描述、`change_type` 职责分离、bug/refactor 字段集合、TEST 重点、CODE_REVIEW 重点、reflection 5 类风险与"未命中不打勾、命中写 risks/next" 全部与对应 SKILL.md 一致。 |
| 2 | `work_type` 被正确描述为可选 PLAN / Clarification 分诊信号 | pass | 第 115 行明写 "可选的 PLAN / Clarification 分诊信号"；第 117 行明写 "不是阶段状态、不是 frontmatter 字段，也不是 `advance-stage.ps1` 或 validator 的输入"；与 plan/SKILL.md L57 完全一致。 |
| 3 | bug/refactor 条件化模板与 reflection checks 写为 guidance 而非新 gate / checklist / 超前承诺 | pass | 用语为 "PLAN 里的 Clarification 应补足..."、"TEST 会重点..."、"实现者只在命中风险时..."；末段显式 "不会新增阶段、独立 checklist、第二套真相源或 validator gate"。无 gate / checklist / opt-in advisory 暗示。 |
| 4 | 最小示例清晰且不误导 | revise | 见 finding 1。 |

## Finding

### Finding 1（P2，scoped）— bug 示例漏 `bug.impact:`

- **文件**：`README.md`
- **位置**：新增段 `### work_type、条件化模板与 reflection guidance` 内的最小写法示例（约第 130-138 行 markdown code block）
- **现象**：bug 示例只列 5 行 `bug.*` bullet：`repro` / `expected` / `actual` / `root_cause_action` / `fix_verification`，缺 `bug.impact:`。
- **不一致来源**：
  - `skills/plan/SKILL.md` L70-79 权威列出 6 个 bug 字段，`bug.impact` 在第 4 位（"影响范围和严重程度"）。
  - 同一 README 段落的叙述句明写 "PLAN 里的 Clarification 应补足复现、期望/实际行为、**影响面**、根因定位动作和修复验证"，包含影响面。
  - 因此叙述与示例自相矛盾，且与 plan/SKILL.md 不一致。
- **影响**：
  - 用户复制最小示例会漏 `bug.impact:`；进入 PLAN_REVIEW 时会按 `skills/review/SKILL.md` L45（"检查 PLAN 是否说明...**影响范围/严重程度**"）被退回补字段。
  - 这与 README 该段定位（最小示例）矛盾：照样填仍不通过 PLAN_REVIEW。
- **建议修复**（仅文档调整，不动 SKILL）：在示例的 `bug.actual:` 与 `bug.root_cause_action:` 之间增加一行，例如：

  ```markdown
  - bug.impact: 缺少可选配置时所有依赖该项的任务都会失败；严重度：中
  ```

  让示例和叙述、`skills/plan/SKILL.md` 三处保持一致即可。

## 结论

**verdict: revise — 1 scoped finding（README 文案调整）。**

除最小示例缺 `bug.impact:` 一行外，README 刷新整体准确反映了已落地行为：`work_type` 定位正确（可选分诊、不是 stage/frontmatter/validator 输入）、`change_type` 职责分离描述清晰、bug/refactor 模板与 reflection checks 全部以 guidance 语气呈现，且明确否认新增 gate/checklist/真相源/validator gate。修复 finding 1 后即可视为 pass。
