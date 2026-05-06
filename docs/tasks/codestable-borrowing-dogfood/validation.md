---
task_id: codestable-borrowing-dogfood
review_type: dogfood-validation
tool: codex
updated: 2026-04-30
reviewer: workflow-analyst
verdict: usable
---

# Dogfood Validation — CodeStable Borrowing Line (P1+P2+P3)

## 范围

只读 dogfood：选两个真实场景（一个 bug-like、一个 refactor-like），按当前 P1/P2/P3 guidance 走 PLAN→IMPLEMENT→TEST→PLAN_REVIEW/CODE_REVIEW 思路，判断字段是否够用、是否过重、是否有空白；并测一次 reflection 是否轻量。不实现新代码、不动 validator、不扩 scope。

## 输入

- `skills/plan/SKILL.md`（211 行）— P1 work_type + P2 bug/refactor 模板
- `skills/test/SKILL.md`（100 行）— P2 bug/refactor 条件化验证
- `skills/review/SKILL.md`（106 行）— P1/P2/P3 review 重点
- `skills/implement/SKILL.md`（76 行）— P3 reflection checks
- `skills/orchestrator/references/lite-writing-guide.md`（460 行）— 写作规范单一真相源

## 场景 1：bug-like（"validator 错误地拒绝合法 frontmatter"）

### PLAN 思路

按 plan/SKILL.md L70-79 套 6 字段：

| 字段 | 写法 | actionable？ |
|---|---|---|
| `bug.repro` | `pwsh -File scripts/validate-lite-artifacts.ps1 -TaskId X` 输出 `STATUS: FAIL` 含 `unexpected frontmatter field` | yes — 复现命令可执行 |
| `bug.expected` | frontmatter 满足 `task_id`/`stage`/`tool`/`updated` 时 STATUS: PASS | yes — 能转断言 |
| `bug.actual` | validator 报 `unexpected frontmatter field` 拒绝合法 frontmatter | yes — 与 expected 对照 |
| `bug.impact` | 阻塞所有任务的 advance-stage；严重度：高 | yes — 能转 fix priority |
| `bug.root_cause_action` | 在 `Test-FrontmatterShape` 加 trace；diff 最近一次 schema 变更 | yes — 调查动作明确 |
| `bug.fix_verification` | `pwsh -File tests/verify-lite-artifact-validator.ps1` Failures: none | yes — 命令可执行 |

### TEST 思路（test/SKILL.md L67-72）

- 重跑 `bug.repro` 命令 → 不再报 `unexpected frontmatter field` ✓
- 验证 expected 行为已恢复（合法 frontmatter STATUS: PASS）✓
- 执行 `bug.fix_verification` 命令 ✓
- 影响面回归：抽 5 个真实任务跑 validator，覆盖 PASS 和 FAIL 两端 ✓

### REVIEW 思路（review/SKILL.md L45）

- PLAN_REVIEW：6 字段都能导出可执行命令，无 "见 issue" 占位 ✓
- CODE_REVIEW：实现证据对应 repro/root cause/fix verification（review L60）✓

### 评估

- **字段够用**：6 个字段在真实小 bug 场景里都能填出可执行内容，无任何"摆设字段"。
- **不过重**：bug-only 任务无需写 refactor 字段；feature 任务无需写 bug 字段；条件化生效。
- **空白**：`bug.severity` 与 `bug.impact` 合并在一个字段（"影响范围和严重程度"），对单条 bug OK；如要做"按 severity 排序的 backlog"会需要拆开，但当前 lite workflow 没有这个需求，**不构成空白**。

## 场景 2：refactor-like（"把 advance-stage.ps1 内 4 处 Invoke-Validator 调用抽到 helper"）

### PLAN 思路

按 plan/SKILL.md L83-90 套 6 字段：

| 字段 | 写法 | actionable？ |
|---|---|---|
| `refactor.invariant` | advance-stage.ps1 对合法 / 非法输入的退出码、stdout/stderr 内容不变 | yes — 行为契约明确 |
| `refactor.scope` | 只改 4 处 `Invoke-Validator` 调用点；不动 frontmatter parser、不动 stage 转移逻辑 | yes — 边界清晰 |
| `refactor.callers` | PLAN→PLAN_REVIEW、PLAN_REVIEW→IMPLEMENT、CODE_REVIEW→TEST、TEST→DONE 共 4 处 | yes — 显式列出 |
| `refactor.equivalence_check` | refactor 前后跑 `tests/verify-lite-artifact-validator.ps1` 与 `tests/verify-workflow-contracts.ps1`，stdout diff 为空 | yes — 命令可执行 |
| `refactor.rollback` | `git revert <sha>`；如有 helper 文件，删除即恢复 | yes — 路径明确 |
| `refactor.no_feature_change` | 不引入新枚举、新参数、新 stage 路径 | 声明型 — 能由 PLAN_REVIEW 抽查 |

### TEST 思路（test/SKILL.md L74-79）

- 执行 `refactor.equivalence_check` 命令 ✓
- 抽查 4 个 caller（refactor.callers）：每个 stage 转移的 advance-stage 命令至少跑一次 ✓
- 说明未发现功能行为变化 ✓
- 若发现有意行为变化（无），TEST 应判 fail/blocked → 现在是 pass ✓

### REVIEW 思路（review/SKILL.md L46, L61）

- PLAN_REVIEW：行为不变约束（invariant）、边界（scope）、调用点（callers）、等价验证（equivalence_check）、回滚路径（rollback）全部具备，"不夹带功能变更" 由 no_feature_change 声明 ✓
- CODE_REVIEW：实现没有计划外功能行为变化（review L61 抽查），等价验证覆盖 PLAN 声明的 4 个调用点 ✓

### 评估

- **字段够用**：6 个字段把"行为等价、范围约束、回滚、调用点抽查"全部串住，refactor PR 不容易漏证据。
- **不过重**：仅在 work_type=refactor 时启用；feature 任务无负担。
- **空白**：`refactor.no_feature_change` 是声明型字段（不是命令），可能流于"我承诺没改功能"。当前 review/SKILL.md L61 已通过 CODE_REVIEW 抽查兜底（实现没有计划外功能行为变化），所以**不构成阻塞空白**。

## 场景 3：reflection checks 是否轻量

### implement/SKILL.md L35-47 设计要点

- "只在命中风险时记录到本轮 `- risks:` 或立刻停下询问；未命中时不需要逐项打勾。"
- 5 类信号：oversized-file stuffing / 计划外抽象 / 邻近顺手重构 / 未声明新概念 / 症状补丁
- "在范围内就把理由、取舍和验证补到 `- risks:` / `- next:`；超出范围就停止实现，要求回 PLAN 或拆新任务"
- 显式 "不要新增反射 stage、独立 checklist 或新的 Implementation Notes 字段"

### review/SKILL.md L58-59 触发

- "抽查实现是否命中 reflection 风险..."
- "若命中 reflection 风险，确认最新 `Implementation Notes - risks:` 或 `- next:` 已说明理由、取舍和验证；未说明或超出 PLAN 时用现有 P1/P2 finding 退回 IMPLEMENT"

### 模拟一次：feature 任务实现到一半发现要改邻近文件

- IMPLEMENT 端：reflection 命中 "邻近顺手重构" → 判断在/超 PLAN 范围 → 在范围就在 `- risks:` 写 "顺手 normalize 调用点 X，因为新参数引入会重复"；超范围就停下，不动手 → 总成本：1-2 行决策记录 ✓
- CODE_REVIEW 端：抽查（不是逐项打勾）→ 看 `Implementation Notes - risks:` 是否解释了为什么改 X → 没解释就用 P1/P2 finding 退回 → 总成本：1 行 finding ✓

### 评估

- **轻量**：未命中不需要打勾；命中时复用既有 `- risks:` / `- next:` 字段，无新 section。
- **不形式化**：implement 端"未命中时不需要逐项打勾"是显式规则；review 端是"抽查"而非"核对"。
- **5 类是否过多**：每类都是常见 AI 失败模式，但凡命中一类就是值得停下记录的信号，剪裁会损失实际价值；不过多。
- **与 P2 refactor 模板的关系**：reflection 中"邻近顺手重构"针对 work_type=feature/bug 时手抖去 refactor 的情形；refactor 专用模板针对 work_type=refactor 任务的边界声明。两者角度不同、不冗余。

## 结论摘要

### usable

P1（work_type 路由）、P2（bug/refactor 条件化模板）、P3（implementation reflection checks）三项当前已可用。两个真实场景下，PLAN/TEST/REVIEW 思路全部走通，字段都能填出 actionable 内容，无空字段。reflection 检查依靠现有 `- risks:` / `- next:` 字段承载，未命中无成本，命中时也只增 1-2 行记录。

### friction

- 暂无显著摩擦。`## Clarification` 在 work_type=bug/refactor 时同时承载 6 个 dotted-key bullet + 5 行原有标准字段（验收标准/非目标/受影响目录/回滚策略/ui），密度上升但仍可读；这是 P2 设计取舍而非 friction。
- `refactor.no_feature_change` 是声明型字段，单看会觉得"流于承诺"，但 CODE_REVIEW L61 已抽查兜底，实际工作中不会形成漏洞。

### follow-up（小而明确，均不扩 scope）

1. **写作便利**：可以在 `lite-writing-guide.md` 的 work_type/bug/refactor 三段加 inline anchor link（如 `<a id="work-type"></a>`），方便从 plan/review/test SKILL 跨文件跳转；纯文档便利，不动语义。
2. **5 类反射的现实例子**：`skills/implement/SKILL.md` L41-45 的 5 类信号每条加一句"举例 1 行"（如 "oversized-file: 已超过 500 行的脚本继续追加新函数"），帮新人快速判断；只是注释式补充，不扩 scope。
3. **PLAN_REVIEW 对声明型字段的检查口径**：在 review/SKILL.md L46 后加 1 行说明 — "声明型字段（如 `refactor.no_feature_change`）允许是承诺，但必须有同任务内可执行的 `refactor.equivalence_check` 证据兜底"；让 reviewer 不会因字段是声明而放过它。

以上 3 项均为可选写作细化，不引入新阶段、新真相源、validator/stage 变更或新的 SKILL surface。当前版本可以直接进入正式使用，无阻塞 finding。
