# EO-Inspired Harness Upgrade（裁剪版决策记录）

---
status: decided
created: 2026-04-23
revised: 2026-04-23
source: D:\data\eo-skills-main
scope: dev-harness workflow upgrade
supersedes: 2026-04-23 初版（Phase 0-5 全量方案）
---

## 决策原则

1. 工作流必须好用。
2. 整个流程必须相对简单。

基于这两条原则，本文档从原 5 Phase 方案砍成 **2 个最小增量改动**。原方案的 Phase 2-5 作为"已评估并拒绝"的决策记录保留在本文档末尾，不进入实施。

## 保留的主流程

```text
PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE
```

- 唯一阶段真相源：`docs/tasks/<task-id>/plan.md` frontmatter
- 不新增 stage
- 不新增 skill
- 不新增目录树
- `advance-stage.ps1` 不动

## 采纳的两个增量

### A. Change Contract（plan.md 可选 section）

在 PLAN 阶段产物 `docs/tasks/<task-id>/plan.md` 中增加可选 section：

```markdown
## Change Contract
- change_type: task | feature | enhance | refactor
- affected_paths:
  - <path>
```

字段说明：

| 字段 | 说明 |
|---|---|
| `change_type` | 变更性质分类，枚举值固定 |
| `affected_paths` | 本 task 预计改动的文件或目录路径 |

校验规则：

- 老任务没有 `Change Contract` 时 validator 跳过检查（opt-in）
- 存在该 section 时，`change_type` 必须在枚举内
- `affected_paths` 至少一条

价值：让 IMPLEMENT、CODE_REVIEW、TEST 能快速消费"这次改什么类型、动哪些路径"，不用从自然语言 Goals 里反推。

### B. Handoff 密度扩展（test.md 现有 section 加字段）

扩展 `docs/tasks/<task-id>/test.md ## Handoff`：

```markdown
## Handoff
- delivery: ...          # 已有，保留
- follow_up: ...         # 已有，保留
- current_state: ...     # 新增：当前阶段 + 关键产物路径
- key_decisions:         # 新增：跨会话必须保留的决策
  - decision: ...
    why: ...
- next_actions:          # 新增：恢复后第一组可执行动作
```

字段说明：

| 字段 | 说明 |
|---|---|
| `delivery` | 已交付内容（已有） |
| `follow_up` | 后续动作；无则 `none`（已有） |
| `current_state` | 当前任务状态快照和关键产物路径 |
| `key_decisions` | 跨会话必须保持的决策和原因 |
| `next_actions` | 恢复后第一组动作 |

校验规则：

- 旧格式 `Handoff` 继续兼容
- 不做硬性字段数量检查，只在模板和 lite-writing-guide 里示范

价值：长任务跨会话恢复时，agent 只需扫 `key_decisions` + `next_actions` 就能续接，不用重读整个 artifact。

## 实施表面积

| 文件 | 改动 |
|---|---|
| `skills/plan/SKILL.md` | 模板增加可选 Change Contract section |
| `skills/test/SKILL.md` | Handoff 模板补 3 个字段 |
| `skills/orchestrator/references/lite-writing-guide.md` | 增补 2 小节说明 |
| `skills/orchestrator/references/state-templates.md` | plan.md / test.md 模板同步更新 |
| `scripts/validate-lite-artifacts.ps1` | 新增 `change_type` 枚举校验（~10 行） |
| `tests/verify-change-contract.ps1` | 新增，2 正例 + 2 反例 |

**6 个现有文件修改 + 1 个新增测试**。不新增 skill，不新增目录，不新增业务脚本。

## 兼容性

- 现有 16 个 verify 测试必须继续通过
- 老任务没有 `Change Contract` 时 validator 不报错
- 老任务用旧格式 `Handoff`（只有 delivery/follow_up）时继续通过

## 实施顺序

按单任务推进：

1. 本次 PR 完成 A + B 两个改动（不拆）
2. 走完一遍 harness-lite：PLAN → PLAN_REVIEW → IMPLEMENT → CODE_REVIEW → TEST → DONE
3. 不新增 stage，不改 `advance-stage.ps1`

## Review Findings 处理记录

2026-04-23 codex 对本文档 + 工作区 diff 的审查 finding，已处理如下。

### [P1] ✅ resolved — `/docs/` 从 .gitignore 移除

- 位置：`.gitignore:34`（已修复）
- 原问题：`/docs/` 规则会忽略设计文档本身及所有 task artifact
- 处理：直接删除 `/docs/` 行，保留同批引入的 `/.idea/` 和 `/.claude/`
- 验证：`git check-ignore -v docs/design/eo-inspired-harness-upgrade.md` 不再命中

### [P2] ✅ resolved — `-RepoRoot` 归类为独立修复

- 位置：`scripts/advance-stage.ps1`
- 原问题：本文档"不动 advance-stage.ps1"与 diff 不一致
- 处理：确认 `-RepoRoot` 参数是独立的 shim/root 解析修复，**不属于 EO-inspired 范围**
- 归档：见下一节"相关独立改动"；提交时与 EO 增量分开 commit，各自独立评审

---

## 相关独立改动（非 EO-inspired 范围）

以下改动与本计划同期存在于工作区，但**不属于 EO 吸收范围**，需要独立评审与独立 commit。

### `scripts/advance-stage.ps1` — 新增 `-RepoRoot` 参数

- 性质：基础设施修复
- 动机：允许 `.assistant\entry\advance-stage.ps1` shim 显式传入 repo 根，不再硬依赖 `Split-Path -Parent $PSScriptRoot`
- 影响：提升 shim 在多 repo / 非默认布局下的可用性
- 边界：本次 EO 增量实施**不扩展 `advance-stage.ps1`**；该改动已独立存在，只需确认不要被 EO 相关改动覆盖

---

## 已评估并拒绝的方案（决策记录）

以下是原始设计中考虑过、但根据"好用 + 简单"原则明确不做的方案。保留记录以避免未来重复讨论。

### ❌ 原 Phase 2：模块活文档层 `docs/modules/<module>/spec.md`

**拒绝理由**：

- harness 本身没有"模块"这一等概念，引入即需定义模块命名、路径、索引、跨 task 关联等一整套约束
- 只有"多个 task 反复改同一业务域"的长期演进场景才能摊平建设成本
- 目前 harness 的消费场景以"单任务闭环"为主，模块层的边际收益不足以抵消复杂度

**再启用条件**：同一代码目录被 3+ 个已 DONE task 修改过，且出现"新 task 需要先读散落在多个 task artifact 里的上下文"的痛点。

### ❌ 原 Phase 3：Spec Delta + `archive-module-delta.ps1`

**拒绝理由**：

- 依附 Phase 2 的模块层，Phase 2 不做则无处落地
- MODIFIED 冲突（旧文本在 spec 中找不到）的处理策略很难做到既自动化又安全；EO 自己也是靠人工裁决
- 手动维护 spec 比机械合并更直接——在没有模块层的前提下，Delta 本身就是无依赖对象的空转

**再启用条件**：Phase 2 启用后，且出现"多个 task 的 spec 改动需要顺序合并"的场景。

### ❌ 原 Phase 5：文档索引 + 增量同步（INDEX.md + `.doc-sync-cursor` + `sync-agent-docs.ps1`）

**拒绝理由**：

- `docs/tasks/<task-id>/` 目录结构本身就是自然索引
- INDEX 与实际文档状态极易失同步，维护成本高
- git diff 基础的增量同步逻辑复杂，容易出 bug
- EO 的 doc-manager 价值在于统一代码侧的多视角文档体系；harness 目前没有这个问题

**再启用条件**：task artifact 总量超过 100，且出现"agent 读不到相关历史 task"的痛点。

### ❌ `change_type: bootstrap`

**拒绝理由**：

- EO 的 bootstrap 是"模块初始化时的首批实现"，依附模块 spec 概念
- harness 没有模块初始化流程，bootstrap 无对应上下文
- 保留 `task / feature / enhance / refactor` 四个枚举已能覆盖主流场景

**再启用条件**：如果未来引入 Phase 2 模块层，届时再评估。

### ❌ 三层 review 分层（spec-review / change-review / code-review）

**拒绝理由**：

- harness 已有 `PLAN_REVIEW`（对应 change-review，审方案）和 `CODE_REVIEW`（对应 code-review，审实施）
- spec-review（审模块需求）依附模块层，Phase 2 不做则无对应对象
- 两层 review 已能覆盖"方案审 + 代码审"的核心分工

### ❌ 独立 handoff 文件 `tmp/<topic>-handoff.md`

**拒绝理由**：

- EO 的横切 handoff 价值在于"随时 clear 前快照"，但需要独立的文件命名、生命周期、清理机制
- harness 的 handoff 集中在 TEST 阶段的 `test.md ## Handoff`，stage 边界已经是天然快照点
- 共享运行时 mirror（`运行时/tasks/<task-id>.md`）已在 stage 推进时自动刷新，提供了低 token 的恢复视图

**再启用条件**：出现"长任务在 IMPLEMENT 中途必须 clear 但又不想推进到 TEST"的实际痛点。

### ❌ `.eo-project.json` 项目配置文件

**拒绝理由**：

- harness 不需要 vault/local 双模式
- project_name / doc_root 由项目自决，无需集中配置
- 引入即等于在 `plan.md` 之外增设第二个状态源，违反单一真相源原则

### ❌ eo-flow / eo-workflow（tmux + smux 跨 agent 派发）

**拒绝理由**：

- harness 是 Windows 优先的单 agent 框架
- tmux/smux 在 Windows 支持有限
- 跨 pane 自动派发的复杂度与 harness "一次只推一个 stage" 的节奏相冲突

---

## 验收

本决策记录的验收：

- [x] 采纳的增量 A/B 各自有明确契约（字段、枚举、校验规则）
- [x] 实施表面积明确到文件级别
- [x] 每个被拒绝的方案都有理由和再启用条件
- [x] 不引入新 stage、新 skill、新目录

后续实施的验收见具体 task（`docs/tasks/<task-id>/plan.md`）。
