---
task_id: eo-inspired-harness-upgrade-analysis
review_type: triage
tool: codex
updated: 2026-04-30
reviewer: workflow-analyst
verdict: read-only-triage
---

# EO-Inspired Harness Upgrade — 现状分诊

## 范围

只读分析 `docs/design/eo-inspired-harness-upgrade.md`（241 行，2026-04-23 决策记录）相对当前仓库状态的 already landed / still valuable / obsolete / risky 分类，并给出 1-3 个仍值得继续的后续任务建议。**不重写设计文档**，**不立即开实现任务**，避免与已覆盖主线重复（CodeStable / AionUi alignment / Phase 5/6/7 / EO-lite-enhancement）。

## TL;DR

设计文档**采纳的 2 个增量（A Change Contract + B Handoff 密度）已全部 landed**，连同附带的 advance-stage.ps1 `-RepoRoot` 独立修复也已 commit。被显式拒绝的 6 项均仍然适用拒绝理由，不应再启用。**此设计的实施面已完全收敛**，剩余只有 1 项轻量观察（验证 opt-in 字段在长任务中的实际采用率），不构成必须实施的后续任务。

## 现状证据

| 设计承诺 | 落地证据 | 状态 |
|---|---|---|
| `plan.md` 增加可选 `## Change Contract` section | `skills/plan/SKILL.md` L103-114, L138；`skills/orchestrator/references/lite-writing-guide.md` L90-110；`skills/orchestrator/references/state-templates.md` L136-157 | landed |
| `change_type` 枚举校验（task/feature/enhance/refactor） | `scripts/validate-lite-artifacts.ps1` 含 `change_type` 校验 | landed |
| 老任务无 Change Contract 时 validator 跳过 | lite-writing-guide L110 明示 "不写 `## Change Contract` 不影响现有任务" | landed |
| `tests/verify-change-contract.ps1`（2 正例 + 2 反例） | `tests/verify-change-contract.ps1` 存在 | landed |
| `test.md ## Handoff` 新增 `current_state` / `key_decisions` / `next_actions` | `skills/test/SKILL.md` L53-61；`lite-writing-guide.md` L405-418；`state-templates.md` L216-224 | landed |
| 旧 Handoff 格式（只 delivery/follow_up）继续兼容 | test/SKILL.md L61 与 state-templates.md L224 显式声明 | landed |
| `advance-stage.ps1` 不动（设计原承诺） | 设计文档已注明 `-RepoRoot` 是独立修复并独立 commit | landed（独立线） |
| 现有 16 个 verify 测试继续通过 | 由 EO-lite-enhancement task（已 commit `68df690`）承担 | landed |

EO-lite-enhancement 任务（commit `68df690`）的 plan.md frontmatter 显示 `stage: DONE`，与上述证据一致。

## 四类分诊

### A. Already landed（无需后续）

- **A.1** Change Contract section 模板 + 校验 + 测试
- **A.2** Handoff 密度扩展（3 个 opt-in 字段 + 旧格式兼容）
- **A.3** advance-stage.ps1 `-RepoRoot` 独立修复

设计文档"采纳的两个增量"100% 实施完毕。

### B. Still valuable（保留为可选观察项，不立任务）

- **B.1** 长任务恢复采用 `key_decisions + next_actions` 的实际频率
  - 现状：opt-in 字段已上线但缺采用度数据
  - 触发条件：观察到长任务在跨会话恢复时仍然依赖重读整个 artifact，再考虑加示范任务或写作 guide 强化
  - **不立 pending task**，避免被误读为必须实施

### C. Obsolete（被同期主线覆盖或已确认不做）

- **C.1** ❌ 原 Phase 2 模块活文档层 / ❌ Phase 3 Spec Delta — 设计文档已显式拒绝；无再启用条件触发
- **C.2** ❌ 原 Phase 5 INDEX + 增量同步 — 同上，被 `docs/tasks/<task-id>/` 自然索引覆盖
- **C.3** ❌ `change_type: bootstrap` / ❌ 三层 review 分层 / ❌ 独立 handoff 文件 / ❌ `.eo-project.json` / ❌ eo-flow tmux 派发 — 全部被 PLAN_REVIEW + CODE_REVIEW 双层 review、单一 plan.md 真相源、Windows-only 单 agent 架构覆盖

被拒绝项的语义已通过 CodeStable（work_type 路由）、AionUi alignment（Phase 1-4 + shared-memory v2）、Phase 5/6/7 roadmap 等主线进一步固化，不再需要重新评估。

### D. Risky（不应实施）

- **D.1** 任何重新引入 "模块层 / Spec Delta / INDEX 文件" 的尝试
  - 风险：设计文档已记录拒绝理由（命名/索引/跨 task 关联约束 + 边际收益不足）；CodeStable / AionUi 主线进一步证实"单 plan.md 真相源 + 自然目录索引"够用
  - 触发再启用的条件文档已写明（同一目录被 3+ DONE task 修改 + 出现读散落上下文痛点），目前无证据
- **D.2** 任何把 opt-in 字段（current_state / key_decisions / next_actions）改为强制必填的尝试
  - 风险：直接破坏向后兼容承诺，且会触发 validator 对历史 task 全面退回；与 lite-writing-guide L418 "不写不影响 validator" 直接冲突

## 仍值得继续的后续任务建议

按 Leader 要求"1-3 个"，**实际只 1 个轻量项**，刻意保持克制：

### 建议 1（最小，可做可不做）

**采用度观察**：在做下一个长任务（≥3 stage 推进）TEST 阶段时，实际填写 `current_state / key_decisions / next_actions` 三个 opt-in 字段，dogfood 一次密度扩展是否真能减轻跨会话恢复成本。结论简短记到 `docs/tasks/<that-task>/test.md ## Handoff` 即可，不开新任务。

**不建议立 pending task** —— 这是"顺手验证"性质，立 task 反而有指标主义风险。

### 不建议的方向

- 不建议为 EO 设计的"被拒绝项"做二次评估或重启 — 拒绝理由仍然成立。
- 不建议加新 SKILL / 新 stage / 新 validator gate 来"加强" Change Contract 或 Handoff —— 当前 opt-in 写法和 EO 设计原则（好用 + 简单）一致，加严就破坏原则。
- 不建议把这份分诊产物本身扩成新主线计划 —— 它的目的是收敛，不是开新摊子。

## 结论

`docs/design/eo-inspired-harness-upgrade.md` 这条主线**实际已经完结**：采纳项全部 landed，拒绝项全部仍适用拒绝理由，独立修复（`-RepoRoot`）也已 commit。剩下唯一值得做的只是 **dogfood 观察**，不构成必须实施的工作。

如未来出现"模块化痛点"或"长任务跨会话恢复仍依赖重读 artifact"的真实证据，再单独开任务，按设计文档已写明的"再启用条件"触发即可，不需要把这条主线重新拉起。
