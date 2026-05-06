---
task_id: codestable-bug-refactor-templates
review_type: code-review
phase: P2
tool: codex
updated: 2026-04-30
reviewer: workflow-analyst
verdict: pass
---

# Code Review — P2 bug / refactor 条件化模板

## 范围

只审本轮 P2 实现，不包含 P3（reflection checks）。
实现方上报改动：

- `skills/plan/SKILL.md`
- `skills/test/SKILL.md`
- `skills/review/SKILL.md`
- `skills/orchestrator/references/lite-writing-guide.md`

## 证据

- `git diff --stat HEAD` 仅命中 4 个上报文件（148 insertions, 0 deletions），无新文件、无改名、无删除。
- `git diff --stat HEAD -- tests/verify-lite-artifact-validator.ps1 scripts/validate-lite-artifacts.ps1 scripts/advance-stage.ps1 skills/implement/SKILL.md` → 无任何改动。
- `validate-lite-artifacts.ps1 -TaskId codestable-borrowing-roadmap` → STATUS: PASS（无回归）。

## 边界检查

| # | 检查 | 结果 | 依据 |
|---|---|---|---|
| 1 | 模板仅在 `work_type: bug \| refactor` 时启用 | pass | `skills/plan/SKILL.md`: "以下模板只在 `work_type: bug` 或 `work_type: refactor` 时启用。不要为普通 feature/doc/maintenance 任务强制补这些字段"；`skills/test/SKILL.md`: "当 `plan.md` 的 `## Clarification` 含 `work_type: bug` 或 `work_type: refactor` 时…"；`skills/review/SKILL.md`: 全部使用 "若 `work_type: bug`" / "若 `work_type: refactor`" 条件句；`lite-writing-guide.md`: "以下模板只在 `work_type: bug` 或 `work_type: refactor` 时使用"。 |
| 2 | 仅落在现有 PLAN / TEST / REVIEW surface 内 | pass | 4 个改动文件全部为既有 surface（plan / test / review SKILL + orchestrator 写作指南）；模板字段嵌入既有 `## Clarification` / `## Verification` / `## Test Approach` / `## Findings`，无新增 section/SKILL/文件。 |
| 3 | 无 issue/analyze/fix 双阶段流程或第二套真相源 | pass | `skills/plan/SKILL.md`: "也不要新建 `bug-report.md`、`refactor-design.md` 或 analyze/fix 双阶段流程"；`skills/test/SKILL.md`: "TEST 仍只产出同一个 `docs/tasks/<task-id>/test.md`，不要新增 issue/refactor 专用报告或额外阶段"；`skills/review/SKILL.md`: "确认 bug/refactor 模板仍嵌在现有 `plan.md` / `test.md` 结构内，没有新增 issue/analyze/fix stage 或独立真相源文件"；`lite-writing-guide.md`: "`work_type: bug` 不等于新建 issue 流程"。 |
| 4 | 未侵入 frontmatter / validator / advance-stage / stage 主干 | pass | 沿用 P1 的 frontmatter 边界："不要写进 frontmatter，不要让 `advance-stage.ps1` 消费它"。`bug.*` / `refactor.*` 字段位于 `## Clarification` 内，作为 bullet 列入既有 section，未新增顶层节、未引入 validator 必填、未触及 stage 流转。`tests/verify-lite-artifact-validator.ps1`、`scripts/validate-lite-artifacts.ps1`、`scripts/advance-stage.ps1` 均未改动。 |
| 5 | 未提前实现 P3 reflection checks | pass | `skills/implement/SKILL.md` 未改动。`skills/review/SKILL.md` 在 CODE_REVIEW 新增的两条均为 P2 类型化验证（"实现证据能对应复现/根因/修复"、"实现没有计划外功能行为变化"），与 P3 的通用 scope drift 反射（过大文件继续塞逻辑、计划外抽象、顺手重构、新概念引入、补丁覆盖症状）无重叠。 |

## 关于 `tests/verify-lite-artifact-validator.ps1` 本地 FAIL

**判定**：独立的工作区快照漂移，**不构成 P2 阻塞 finding**。

证据链：

1. 失败位置 `tests/verify-lite-artifact-validator.ps1:619` 硬编码 `-eq 14`，断言 live baseline 仍含 14 个 plan-bearing tasks。
2. 当前 `find docs/tasks -mindepth 2 -maxdepth 2 -name plan.md` 命中 15 个，超出 1 个，新增项为 `docs/tasks/codestable-borrowing-roadmap/plan.md`。
3. 该 plan.md 是先前路线图任务（codestable-borrowing-roadmap）的产物，由我（workflow-analyst）在起草路线图阶段创建，**早于本轮 P2 实现**。
4. 本轮 P2 仅改动 4 个 skill/guide 文件（148 行新增），未触及 `tests/verify-lite-artifact-validator.ps1`、`scripts/validate-lite-artifacts.ps1`、`scripts/advance-stage.ps1` 或任何 docs/tasks 路径，**不可能改变 plan-bearing task 计数**。
5. `validate-lite-artifacts.ps1 -TaskId codestable-borrowing-roadmap` 重跑 STATUS: PASS — 该任务已通过 validator，只是 verify 测试的硬编码白名单未跟随。

因此 verify 失败的根因是测试白名单的维护债（hard-coded baseline 落后于工作区状态），与 P2 边界守住与否无关。

**建议**（独立于本次 P2 review 的运营动作）：开一个独立维护任务，把 `tests/verify-lite-artifact-validator.ps1:619` 的 baseline 由 14 升到 15，并在 `$expectedPassTasks` 中加入 `codestable-borrowing-roadmap`（验证已 PASS）。此动作不应回滚或推迟 P2。

## 观察项（非 finding）

- `bug.*` / `refactor.*` 字段以 dotted-key bullet 形式存在 `## Clarification`，与既有 `验收标准:` / `非目标:` 等中文键混排。后续若引入 advisory validator，会需要决定是否把这些 dotted-key 也纳入校验枚举（与 P1 advisory 规划一致：先文档纪律，规则稳定后再考虑校验）。
- `skills/review/SKILL.md` 的 PLAN_REVIEW 现包含 5 项 P1+P2 相关检查，篇幅可控；后续若 P3 再加 scope drift 检查，需注意整体清单是否还在 review 一次能跑完的密度内。

## 结论

**verdict: pass — no findings.**

P2 边界全部守住：bug/refactor 模板严格条件化（仅 `work_type: bug | refactor` 启用）、只落在既有 PLAN/TEST/REVIEW surface 内、未引入 issue/analyze/fix 双阶段或第二套真相源、未侵入 frontmatter/validator/advance-stage、未提前吞掉 P3 reflection checks。

`tests/verify-lite-artifact-validator.ps1` 本地 FAIL 经核实为工作区快照漂移导致的测试白名单维护债，与 P2 改动无因果，**不阻塞 P2 推进**，但建议作为独立维护任务跟进。可推进到 P3 implementation reflection checks。
