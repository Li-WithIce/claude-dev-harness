# Lite Writing Guide

本指南约束 `harness-lite` 主线里的任务文档写法。目标只有一个：让 `docs/tasks/<task-id>/` 下的产物既能给人看，也能被脚本稳定读取。

## 适用范围

- `docs/tasks/<task-id>/plan.md`
- `docs/tasks/<task-id>/spec.md`
- `plan.md` 里的 append-only `Plan Review / Implementation Notes / Code Review`
- `docs/tasks/<task-id>/test.md`

## 通用原则

- 只写当前 task 的差量信息，不重写全量背景。
- 机器可读字段必须逐字匹配，不改 section 名、不改字段名。
- 所有路径都写仓库内真实路径，不写“相关文件”“某模块”这类模糊说法。
- 所有验证命令都写可执行命令，不写“自行测试”。
- 不适用时写 `none` 或 `not-applicable`，不要留空标题或占位段落。
- append-only 区块只追加新 run，不回写或改写旧 run。

## plan.md 契约

### Frontmatter

`plan.md` frontmatter 必须包含 4 个基础字段，并可选择性增加 `tool_profile` / `model`：

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | gemini | none
tool_profile: harness-default-codex
model: gpt-5.5/xhigh
updated: YYYY-MM-DD
---
```

规则：

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`、`gemini`
- `DONE` 只能写 `tool: none`
- `tool` 表示“当前 stage 由哪个 backend 继续”，即使用 profile 也必须显式保留
- `tool_profile` 指向 `agent-configs/profiles/<name>.yaml`
- 当前 stage 的 `tool_profile/model` 只是活跃元数据，不会作为下一 stage 的黏性 fallback
- 存在 `tool_profile` 时，`tool` 必须等于 profile 描述符中的 `backend`
- `model` 必须写完整模型 ID，不写 `opus`、`pro`、`latest` 这类短别名
- 未启用 `tool_profile` / `model` 时，旧四字段 frontmatter 继续合法

### Workflow Descriptor（可选）

若仓库启用了 `agent-configs/workflows/harness-lite.yaml`，它只为下一 stage 提供 `workflow-default` fallback，不改变 `plan.md` frontmatter 仍是唯一当前 stage 真相源。

当前仓库的默认 descriptor 是 Codex-first：`PLAN`、`PLAN_REVIEW`、`IMPLEMENT`、`CODE_REVIEW` 都默认使用 `harness-default-codex`；`TEST` 默认使用 `harness-default-gemini`。如需 Claude Code 介入，必须在当前任务或推进命令里显式指定 `claudecode` / `harness-default-claude`。

最小字段：

```yaml
name: harness-lite
version: 1
stages:
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
```

规则：

- fallback 顺序固定为：显式 `-Tool` → 显式 `-Profile` → workflow descriptor `default_profile`
- descriptor 只影响“下一 stage 默认选哪个 profile/backend”，不会把当前 stage 的 `tool_profile` 黏性传下去
- descriptor 校验问题只出现在 validator 的 `Warnings:` 段，不会单独变成 `Errors:`

### Phase 3 Side Artifacts（可选）

- `docs/tasks/<task-id>/skill-manifest.json`：由 `advance-stage.ps1` 在成功推进后 best-effort 生成；不是新的真相源，也不写入 `.assistant/`
- `docs/tasks/<task-id>/skills-index.md`：由 `scripts/generate-skills-index.ps1` 生成，给嵌入消费端或非原生 backend 展示当前 stage 的可用 skills
- invocation trace 只允许以单行 `- invocation: ...` 追加到已有 `### Run N` 块内部；目标 section 没有 Run block 时必须跳过，不能新建 section 或 bare 顶层 bullet

### 必备 section

推荐顺序固定为：

1. `## Clarification`
2. `## User Confirmation`
3. `## Plan`
4. `## Verification`
5. `## Risks`
6. `## Plan Review`
7. `## Implementation Notes`
8. `## Code Review`

### 可选 section：Change Contract

在 `## User Confirmation` 与 `## Plan` 之间可以插入可选的 `## Change Contract`，把本次变更的类型和路径以机器可读方式声明出来，降低 IMPLEMENT/CODE_REVIEW/TEST 理解成本。

格式固定为：

```markdown
## Change Contract
- change_type: task | feature | enhance | refactor
- affected_paths:
  - <path>
  - <path>
```

字段规则：

- `change_type` 必须在枚举内：`task | feature | enhance | refactor`
- `affected_paths` 至少一条非空、非占位条目（占位符 `<path>` 视为未填）
- 未启用该 section 时 validator 自动跳过；这是 opt-in 字段

不写 `## Change Contract` 不影响现有任务——旧任务继续通过。

### Clarification 最低要求

`## Clarification` 必须逐项覆盖：

- 验收标准
- 非目标
- 受影响目录 / 模块
- 回滚策略或兼容性约束
- `ui: <expectation | not-applicable>`

#### <a id="work-type-routing"></a>work_type（可选语义路由）

新任务可以在 `## Clarification` 内增加一行 `work_type`，帮助 PLAN_REVIEW 选择审查重点：

```markdown
## Clarification
- work_type: feature | bug | refactor | explore | doc | maintenance
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable
```

规则：

- `work_type` 只描述任务意图和审查路线，不是阶段字段，不写入 frontmatter。
- `work_type` 不替代 `## Change Contract`；`Change Contract.change_type` 仍描述产物或变更类型，并继续使用现有 validator 枚举。
- `work_type` 不参与 `advance-stage.ps1` 推进，不创建第二套真相源。
- 旧任务缺少 `work_type` 仍合法；只有存在该字段时，PLAN_REVIEW 才核对它与验收标准、非目标、受影响路径和验证命令是否一致。

#### bug / refactor 条件化模板

以下模板只在 `work_type: bug` 或 `work_type: refactor` 时使用。它们是 `plan.md` / `test.md` 内的写作约束，不新增 issue/analyze/fix stage，也不新增单独真相源文件。

<a id="work-type-bug-template"></a>`work_type: bug` 示例：

```markdown
## Clarification
- work_type: bug
- bug.repro: ...
- bug.expected: ...
- bug.actual: ...
- bug.impact: ...
- bug.root_cause_action: ...
- bug.fix_verification: ...
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable

## Verification
- `<rerun reproduction or equivalent command>`
- `<fix verification command>`
- `<impact regression command>`
```

<a id="work-type-refactor-template"></a>`work_type: refactor` 示例：

```markdown
## Clarification
- work_type: refactor
- refactor.invariant: ...
- refactor.scope: ...
- refactor.callers: ...
- refactor.equivalence_check: ...
- refactor.rollback: ...
- refactor.no_feature_change: ...
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable

## Verification
- `<behavior equivalence command>`
- `<affected caller regression command>`
```

规则：

- 这些字段只在对应 `work_type` 下启用，不要求普通任务填写。
- 不适用的字段要写原因，不能留下空占位。
- PLAN_REVIEW 应检查这些字段是否导出了可执行 verification；TEST 应按同一复现、修复验证或等价验证口径收集证据。
- `work_type: bug` 不等于新建 issue 流程；`work_type: refactor` 不等于绕过功能验收。

### User Confirmation

`## User Confirmation` 只使用这条机器可读字段：

```markdown
## User Confirmation
- status: draft | confirmed
```

### Plan 内容要求

在普通 TODO bullets 之前，可选地放一个 metadata-style 顶部块：

```markdown
## Plan
- read_first: [docs/shared-memory-layers.md, scripts/validate-lite-artifacts.ps1]
- convergence:
  - `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern '\[switch\]\$Quality'`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- artifacts: [docs/工作流/single-writer-precompact.md, scripts/validate-lite-artifacts.ps1]
- 更新 `scripts/validate-lite-artifacts.ps1`，统一质量评分校验。
```

- `read_first:`、`convergence:`、`artifacts:` 只允许出现在 `## Plan` 标题之后、第一条普通 bullet 之前
- `read_first:` 必须使用 inline-array 语法
- `convergence:` 下面至少 1 条非空 criterion，且不要只写 `TBD`
- `artifacts:` 必须使用 inline-array 语法，且至少列 1 条非空路径
- 示例顺序固定为 `read_first:` → `convergence:` → `artifacts:`；validator 不强制顺序，但文档示例与人工写作都按这个顺序
- `artifacts:` 表示任务产出物声明；不要和 `## Change Contract` 里的 `affected_paths` 混用
- 不需要时整段删除即可；不要把它们插到普通 TODO 中途
- 每一项都是可执行动作，不写抽象口号。
- 尽量带文件路径或模块名。
- 控制在实现可直接消费的粒度。

正确示例：

```markdown
## Plan
- 更新 `scripts/advance-stage.ps1`，统一当前任务指针写法。
- 更新 `skills/obsidian-memory/scripts/check-shared-memory.ps1`，移除 `docs/<task-id>` fallback。
```

错误示例：

```markdown
## Plan
- 优化流程一致性。
- 修一些共享记忆问题。
```

### Verification 内容要求

- 写真实命令。
- 只列本轮需要执行的验证。

正确示例：

```markdown
## Verification
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-contracts.ps1`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-footprint.ps1`
```

## spec.md 契约

`spec.md` 只是 PLAN 的可选附件，不是独立 stage。

### 可选 frontmatter

`spec.md` 可在文件顶部加入 opt-in frontmatter：

```yaml
---
front_keywords: [shared-memory, long-session, recovery]
---
```

规则：

- 仅在跨任务关键词检索或长会话恢复需要快速命中时使用
- 单任务、无跨任务复用价值时不写
- 必须使用 inline-array 语法，keyword 优先 kebab-case
- 单个 `spec.md` 最多写 5 个 keyword
- validator 当前不读取该 frontmatter；不写也完全合法

推荐结构：

```markdown
---
front_keywords: [shared-memory, long-session, recovery]
---
# <Task Title> Spec

## Gap
- 当前输入还缺什么。

## Constraint
- 本轮必须遵守的边界和兼容性约束。

## Verification Delta
- TEST 需要额外补哪些验证。
```

规则：

- 只补缺口，不复制 `plan.md` 已经明确的内容。
- 不创建额外状态文件，不写 stage。

## Append-Only Run 契约

### Run 标题格式

所有 append-only run 都使用：

```markdown
### Run <N> · YYYY-MM-DD HH:mm · runner: <Runner>
```

### Plan Review / Code Review

固定格式：

```markdown
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: pass | revise
- findings:
  - P1: ...
  - P2: ...
- next: 下一步动作；无则写 none
```

规则：

- `advance-stage.ps1` 只读取最新 run 的 `- verdict:`。
- 没有 findings 时写 `- findings: none`，不要写空 severity 标题。
- 只在真的有问题时使用 `P0/P1/P2/P3`。
- Phase 3 adapter 的 invocation trace 只能追加到现有 run 末尾，不能手写到 section 顶层

### Implementation Notes

推荐格式：

```markdown
### Run 1 · 2026-04-09 11:00 · runner: Codex
- changed: 更新了哪些文件或行为
- tests: 跑了哪些验证；无则写 none
- risks: 本轮残留风险；无则写 none
- next: 交给 CODE_REVIEW 关注什么；无则写 none
```

规则：

- 回修后必须追加新 run，不能复用旧 run 充当“新证据”。
- `changed` 写结果，不写空话。
- `IMPLEMENT` 若是接 `CODE_REVIEW revise` 回来，最新 run 必须比那条 review 更晚。

#### Implementation reflection checks

IMPLEMENT 使用现有 `- risks:` / `- next:` 记录命中的反射风险，不新增 section、字段、stage 或独立 checklist。未命中时不需要逐项写“无”。

只检查 5 类窄范围信号：

- oversized-file stuffing: 继续往已过大的文件塞逻辑
- 计划外抽象: 新增 PLAN 没声明的分支、层级、接口或抽象
- 邻近顺手重构: 顺手改了当前验收范围外的邻近代码
- 未声明新概念: 引入 PLAN / spec 没有定义的新术语、状态或配置口径
- 症状补丁: 只压住表面现象，没有处理 PLAN 中要求验证的根因或约束

规则：

- 命中但仍在 PLAN 内时，在 `- risks:` 或 `- next:` 写明理由、取舍和验证。
- 命中且超出 PLAN 时，停止实现并回 PLAN 或拆新任务。
- CODE_REVIEW 用现有 `findings` 退回，不引入 validator 硬校验。

## test.md 契约

推荐结构：

```markdown
# Test Report

## Summary
- 一句话结论摘要。

## Scope
- 本轮覆盖范围。

## Inputs Reviewed
- `docs/tasks/<task-id>/plan.md`
- `docs/tasks/<task-id>/spec.md`（如存在）

## Test Approach
- 实际执行的命令、手工检查或日志来源。

## Findings
- 关键发现；无则写 none。

## Risks / Gaps
- 残留风险或证据缺口；无则写 none。

## Conclusion
pass

## Handoff
- delivery: 交付摘要
- follow_up: 后续动作；无则写 none
- current_state: 当前阶段与关键产物路径
- key_decisions:
  - decision: 跨会话必须保留的决策
    why: 决策原因
- next_actions:
  - 恢复后第一组动作
```

规则：

- `## Conclusion` 下第一行必须且只能是 `pass`、`fail`、`blocked`。
- `## Handoff` 必须存在。
- `delivery` 与 `follow_up` 是最低必填，validator 只校验这两条。
- `current_state`、`key_decisions`、`next_actions` 为 opt-in 密度扩展，推荐长任务填写；不写不影响 validator。
- 旧格式 Handoff（只含 delivery/follow_up）继续通过校验。
- 不要把 review 发现写成独立 `review.md`。

## SKILL.md 拆分守则

- 这是 Phase 7 的 lazy 守则，不是立即执行的拆分任务。
- 只有当某个 `skills/*/SKILL.md` 实际增长到约 `600` 行或以上时，才考虑拆分。
- 触发后目标形态应为：主 `SKILL.md` 控制在 `<= 200` 行，细分内容放到 `phases/<phase>.md`。
- 主 `SKILL.md` 顶部必须保留导航，明确“何时加载哪个 phase”。
- 拆分前后 `git diff --stat` 应接近纯位移；不要借拆分机会重写内容或顺手改语义。
- 当前仓库现场没有任何 `SKILL.md` 达到该阈值，因此不要预先创建 `skills/*/phases/` 目录，也不要新建独立 `docs/工作流/skill-phase-loading.md`。

## FAQ

### 为什么我的 `tool_profile: harness-default-claude` 没有影响下一 stage

因为 `tool_profile` 只记录“当前 stage 已分配到哪个 profile”。下一 stage 的解析顺序是显式 `-Tool` → 显式 `-Profile` → workflow descriptor `default_profile`。如果当前 stage 没传新参数，而目标 stage 在 `agent-configs/workflows/harness-lite.yaml` 里有 `default_profile`，就会走 `workflow-default`，而不是复用旧 frontmatter 的 `tool_profile/model`。

## 严重级别

推荐统一使用：

- `P0`: 阻塞继续推进
- `P1`: 高优先级缺陷或回归
- `P2`: 重要但不阻塞的偏差
- `P3`: 次要问题或文档修正

规则：

- 一个 finding 只标一个级别。
- 级别只用于真实 finding，不用于空标题占位。

## 自检清单

- [ ] 路径全部位于 `docs/tasks/<task-id>/`
- [ ] `plan.md` frontmatter 只有 4 个基础字段，或再加合法的 `tool_profile` / `model`
- [ ] `tool` 与当前 `stage` 组合合法
- [ ] `User Confirmation` 使用机器可读 `status`
- [ ] append-only run 没有改写旧历史
- [ ] review run 含 `verdict`
- [ ] test.md 含 `Conclusion` 和 `Handoff`
- [ ] 验证命令可直接执行
