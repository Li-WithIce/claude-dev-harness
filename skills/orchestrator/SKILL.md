---
name: orchestrator
description: Use when a development task needs stage control, recovery, handoff, or tool-binding decisions across INTAKE, PLAN, DEV, REVIEW(implementation), TEST, and HANDOFF.
---

# Orchestrator

Orchestrator 是开发主流程的唯一 governor。固定的是 stage machine，不固定的是每个 stage 由哪个工具执行。它的职责不是重新发明上游评审，而是把“已批准输入”推进成可验证的开发执行流。

固定 stage machine：

```text
INTAKE -> PLAN -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF
```

补充分支：

- `DELTA_SPEC` 不是默认独立 stage，而是在 `INTAKE / PLAN` 之间按需生成的可选制品
- `HANDOFF` 是开发阶段终态；新写入不再把终态写成 `DONE`
- 读取层允许对历史 `DONE` 保留一轮兼容别名，仅用于迁移和恢复

## Scope

- 只用于开发任务：新功能、bug fix、重构、代码审查、测试验证、未完成任务恢复、runner 切换
- 不用于需求评审、UI 评审、技术方案评审本身
- 不用于验收、上线等开发下游环节
- specialist skill 只能在具体 stage 内作为二级能力被调用

## 入口协议

1. 先解析当前任务身份，顺序为：显式用户任务 → 当前文档或任务目录 → artifact frontmatter
2. 如果 `.assistant/orchestration/current-flow.md` 存在且 `task_id`、`tool_profile_id` 可被信任，按其中记录恢复；不要重新 bootstrap
3. 如果 `current-flow.md` 缺失或无效，按 `handoff -> test -> implementation review -> implementation-notes + diff -> plan -> delta-spec/spec` 的顺序恢复
4. 新任务 bootstrap 时，至少要拿到：
   - `entry_tool`
   - `tool_profile_id`
   - 当前 stage binding
   - `fallback_policy`
  - 上游输入摘要（需求评审是否存在、UI 评审是 `present|missing|not-applicable`、技术方案评审是否存在）
5. 如果 tool profile 缺失、当前 stage binding 缺失、用户指定 binding 与恢复状态冲突、或入口工具未指定，立即停止自动推进并写 `.assistant/orchestration/decision-needed.md`
6. bootstrap 时先判定是否满足 fast-track；满足则设置 `mode: fast-track`，否则设置 `mode: full`

## Repo Context Warmup

在首轮 `INTAKE` / `PLAN` 之前，至少完成一次知识预热：

1. 读取工作区根目录下的 `README*`
2. 读取任务相关的 `docs/`、架构说明、接口说明等背景文档
3. 若工作区存在 `.qoder/repowiki/zh/content`，将其作为仓库级上下文缓存补读
4. 至少提炼出以下信息后，才能进入首稿 `PLAN`：
   - 当前架构 / 模块分层
   - 受影响目录或模块
   - 上游 / 下游依赖
   - 隐含约束与潜在回归点

RepoWiki 只用于加速理解与缩小阅读范围，不是真理源；任何 gate、review 或 test claim 仍必须回到源码和真实证据。

## Fast-track 准入条件

必须同时满足以下全部条件：

- 影响范围 ≤ 3 个文件
- 不涉及 API 接口变更或数据库 schema 变更
- 不涉及安全相关逻辑
- 变更类型为：typo 修复、单函数 bug fix、配置调整、样式修改、依赖版本升级
- 用户未显式要求完整流程

## Fast-track 路径

所有阶段保留，但制品精简：

```text
INTAKE(compact) -> PLAN(compact) -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF
```

- `PLAN` 使用 compact template，但仍满足 artifact 最低契约
- `DELTA_SPEC` 只在输入不足时生成；fast-track 不会自动强制创建它
- `TEST` binding 不因 fast-track 而改变
- stage-history 仍正常记录所有阶段转换

## Core Rules

- Stage machine fixed；runner binding dynamic
- 不存在默认工具组合。Claude / Codex / Gemini 都只是可选 profile 示例
- 所有 gate 只看当前任务 artifacts，不看模糊的固定文件名存在感
- 当前任务 canonical artifact 路径为：

```text
docs/<task-id>/plan.md
docs/<task-id>/implementation-notes.md
docs/<task-id>/review.md
docs/<task-id>/test.md
docs/<task-id>/handoff.md
docs/<task-id>/spec.md        # 仅当 DELTA_SPEC 被触发时存在
```

- `plan.md` 是开发阶段主文档
- `spec.md` 在新流程里只承担可选 `delta-spec / 开发边界说明` 角色
- `handoff.md` 是跨阶段滚动状态文档；进入 `HANDOFF` 后，它同时承担最终交付快照
- `P0 / P1` 阻塞 TEST；仅 `P2` 时可以进入 TEST，但风险必须保留到 `handoff.md`
- `test.md` 结论必须且只能是 `pass`、`fail`、`blocked`
- `HANDOFF` 是当前流程终态；新写入不再使用 `DONE`

## Shared Runtime Contract

Orchestrator not only updates `.assistant/orchestration/*`，也必须同步 Obsidian 共享运行时：

- Start / switch / resume：更新 `运行时/当前任务.md` 和 `运行时/tasks/<task-id>.md`
- Waiting / interruption：更新 `运行时/tasks/<task-id>.md` 和 `运行时/中断任务.md`
- Stage close-out：更新 `运行时/上次会话.md` 并刷新 `运行时/恢复索引.md`
- Untriaged new work：先落到 `运行时/收件箱.md`

若共享运行时镜像缺失、过期或指向其他 `task_id`，视为 blocked。

每次 advance、loop-back、fallback、recovery 完成前，都必须运行：

```text
..\..\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH} -OrchestratorFlowPath <absolute-path-to-current-flow.md>
```

只有 `STATUS: PASS` 才允许推进。

## Encoding Discipline

所有 markdown 和 state 读写必须使用显式 UTF-8 处理。

- PowerShell 中一律使用 `-Encoding utf8`
- Windows PowerShell 下共享运行时 markdown 优先 UTF-8 with BOM
- 禁止把明显乱码、坏掉的中文标点或替代字符写回文档
- 如果源文本看起来乱码，必须先用显式 UTF-8 重读再处理
- 每次离开阶段前，至少 spot-check 标题和 2 行中文正文

## Stage Map

| Stage | Required output | Binding source | Gate to next |
|------|-----------------|----------------|--------------|
| INTAKE | `current-flow.md` + 输入摘要；必要时生成 `spec.md` | 当前 tool profile 的 `INTAKE` binding | 已确认 approved inputs 足以进入 `PLAN`，或已生成可用的 `DELTA_SPEC` |
| PLAN | `docs/<task-id>/plan.md` | 当前 tool profile 的 `PLAN` binding | `plan.md` 满足 contract 且获得用户确认 |
| DEV | diff + `docs/<task-id>/implementation-notes.md` | 当前 tool profile 的 `DEV` binding | 当前任务 diff 可审查，且 `implementation-notes.md` 已就绪 |
| REVIEW(implementation) | `docs/<task-id>/review.md` | 当前 tool profile 的 `REVIEW(implementation)` binding | 无 `P0 / P1`，`P2` 风险已准备传递给 TEST / HANDOFF |
| TEST | `docs/<task-id>/test.md` | 当前 tool profile 的 `TEST` binding | `test.md` 有效，且结论合法 |
| HANDOFF | `docs/<task-id>/handoff.md` | 当前 tool profile 的 `HANDOFF` binding 或 orchestrator fallback | 交付信息完整，风险与结论可供下游消费 |

## Critical Stage Rules

- **先定 profile，再动 stage**：没有 `entry_tool`、`tool_profile_id`、当前 stage binding 或 `fallback_policy`，不要推进
- **INTAKE 只消费输入，不重演上游评审**：需求评审是默认必需输入；若任务涉及用户可见 UI 变更，则 UI 评审也必须存在；非 UI 任务必须显式记录 `ui review: not-applicable`；技术方案评审若存在则直接消费，不存在时也不默认阻塞
- **DELTA_SPEC 按需触发**：只有输入不足以支撑开发计划时，才生成 `spec.md`
- **PLAN 先收敛，再进入 DEV**：`plan.md` 必须成为开发主文档，并由用户确认
- **每次阶段迁移都要刷新 handoff**：`handoff.md` 必须持续反映当前 stage、gate basis、最新变更摘要和下一步
- **DEV 必须留下实现证据**：每次实现或回修后都要刷新 `implementation-notes.md`
- **P0 / P1 阻塞 TEST**：implementation review 有 `P0 / P1` 时必须回 DEV
- **REVIEW 必须声明 verdict**：`review.md` 需要显式写出 `review_verdict: pass | revise`
- **TEST 只服从当前 binding**：runner 与 fallback 顺序都以 tool profile 为准
- **通过 TEST 后进入 HANDOFF**：不再把测试通过写成 `DONE`
- **没有合法证据就不 HANDOFF**：`test.md` 没有明确证据时，不允许进入交付终态

## Required Writeback

维护以下文件：

- `.assistant/orchestration/current-flow.md`
- `.assistant/orchestration/stage-history.md`
- `.assistant/orchestration/handoff.md`
- `.assistant/orchestration/decision-needed.md`
- `{VAULT_PATH}\运行时\当前任务.md`
- `{VAULT_PATH}\运行时\tasks\<task-id>.md`
- `{VAULT_PATH}\运行时\中断任务.md`
- `{VAULT_PATH}\运行时\上次会话.md`
- `{VAULT_PATH}\运行时\恢复索引.md`
- `{VAULT_PATH}\运行时\收件箱.md`（新事项分流时）

写回规则：

- 每次 advance、loop-back、fallback、recovery 都要更新 `current-flow.md`
- 每次 stage 变化都要追加 `stage-history.md`
- `current-flow.md` 必须记录 `entry_tool`、`tool_profile_id`、`tool_profile_source`、`runner_tool`、`runner`、`tool_bindings`、`fallback_policy`
- 只要输入摘要、`DELTA_SPEC` 判定、stage、runner、artifact 路径、gate basis 或 fallback policy 变化，就要刷新 `handoff.md`
- 只要无法安全自动推进，就写 `decision-needed.md`

每次 orchestrator 响应必须先输出：

```text
stage: <STAGE>
task_id: <task-id>
entry_tool: <user-selected entry tool>
runner: <current runner>
gate: <passed|not passed|blocked>
next: <next action>
```

## Stop Conditions

出现以下任一情况时，停止自动推进并写 `decision-needed.md`：

- 当前任务身份不清
- tool profile 在 bootstrap 或 recovery 后仍缺失
- 当前 stage binding 缺失
- 尝试 advance 时所需的下一个 stage binding 缺失
- 上游 approved inputs 不足，且无法判断是否应触发 `DELTA_SPEC`
- `plan.md` / `review.md` / `test.md` / `handoff.md` 不满足 contract
- 共享运行时镜像缺失、过期或指向其他 `task_id`
- 共享运行时 health gate 不返回 `STATUS: PASS`
- 新写文档存在疑似 mojibake
- 试图在没有明确验证证据的情况下进入 `HANDOFF`

## Red Flags

- “没有技术方案评审，就先走完整 spec 流程”
- “TEST 通过后直接当成 DONE”
- “`.codex` 镜像能先改一半，后面再补”
- “缺 binding 也能临时猜一个 runner”

这些都意味着：回到 stage machine，刷新 tool profile 和 state，再从合法 gate 继续。

## References

- Gate checks: [references/gates.md](references/gates.md)
- Artifact contracts: [references/artifact-contracts.md](references/artifact-contracts.md)
- State templates: [references/state-templates.md](references/state-templates.md)
- Tool profile template: [references/tool-profile-template.md](references/tool-profile-template.md)
- Model invocation: [references/model-invocation.md](references/model-invocation.md)
- Execution runbook: [references/runbook.md](references/runbook.md)
- Review templates: [references/review-templates.md](references/review-templates.md)
- Troubleshooting: [references/troubleshooting.md](references/troubleshooting.md)
- Recovery examples: [references/examples.md](references/examples.md)
- Task ID rules: [references/task-id-rules.md](references/task-id-rules.md)
- Validation scenarios: [references/validation-scenarios.md](references/validation-scenarios.md)
