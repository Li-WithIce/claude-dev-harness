# Context Manifest Artifact

`context-manifest.yaml` 是 advisory-only context metadata。它帮助 IMPLEMENT、CODE_REVIEW、TEST 或恢复接手者理解“这个阶段为什么要读哪些文件”，但不参与阶段推进、工具选择、skill 加载或自动注入。

## Source Of Truth

以下仍是唯一真相源或执行源：

- `plan.md` frontmatter 的 `stage` / `tool`
- `plan.md` 的 `read_first:` / `convergence:` / `artifacts:` metadata
- `agent-configs/workflows/harness-lite.yaml` 的 stage default profile 和 `skills_whitelist`
- `.assistant/entry/AGENTS.md` 与当前 stage skill 的 lazy loading 规则
- `Plan Review` / `Code Review` / `test.md` 的 append-only 结论

`context-manifest.yaml` 不反向更新这些文件，也不生成 `skill-manifest.json`。

## Recommended Path

```text
docs/tasks/<task-id>/context-manifest.yaml
```

启用时必须把它写入 `plan.md` 的 `## Plan` / `artifacts:` inline array。旧任务不需要回填。

## When To Use

适合启用：

- 大型任务有多个阶段、多个事实源或后续恢复成本较高
- `read_first:` 已经很长，但 CODE_REVIEW / TEST 还需要阶段化说明
- 任务涉及外部设计稿、研究材料、历史任务 artifact 或跨任务依赖
- 需要说明某个文件“为什么读”，而不只是列路径

不适合启用：

- 小型 quick fix
- 单文件文档或脚本修改
- 只为绕过 lazy loading 或扩大默认 skill 加载范围

## Allowed Shape

推荐字段：

```yaml
schema_version: context-manifest/v1
summary: ""
contexts:
  - phase: IMPLEMENT
    file: docs/tasks/example/spec.md
    reason: "Primary design input for the implementation."
    required: true
    notes: ""
```

字段含义：

- `schema_version`: 固定为 `context-manifest/v1`
- `summary`: 简短说明本清单覆盖的上下文范围
- `contexts`: 阶段化读取建议列表
- `phase`: 该条建议适用的阶段标签，例如 `PLAN_REVIEW`、`IMPLEMENT`、`CODE_REVIEW`、`TEST`；它只是标签，不驱动 stage
- `file`: repo-relative 文件路径
- `reason`: 为什么需要读这个文件
- `required`: `true` 表示该阶段应优先读取；`false` 表示可选背景
- `notes`: 可选补充说明

## Forbidden Fields

不要写入会制造第二套真相源或自动注入语义的字段：

- `stage`
- `status`
- `verdict`
- `tool`
- `current_phase`
- `next_action`
- `active_task`
- `current_pointer`
- `skills_whitelist`
- `auto_inject`
- `injector`
- `load_by_default`
- `workflow_state`

## Boundaries

- 不替代 `plan.md read_first:`。`read_first:` 仍是 Plan 顶部的最小入口清单；context manifest 只补阶段、原因和必读/选读语义。
- 不覆盖 lazy loading。当前 stage 应加载哪些 skill，仍按 `.assistant/entry/AGENTS.md` 和 orchestrator 规则决定。
- 不覆盖 `skills_whitelist`。workflow descriptor 仍是技能白名单来源。
- 不作为 validator hard gate。validator 只通过既有 artifact drift advisory 间接提示声明产物是否存在，不解析本文件 schema。
- 不自动注入。任何 phase-aware injection 都必须另开 `trellis-context-injection-feasibility` 评估任务。

## Review Checklist

PLAN_REVIEW / CODE_REVIEW 抽查：

- 是否已在 `Plan.artifacts` 声明
- 是否只包含 advisory context metadata
- 是否出现 forbidden fields
- 是否把 `phase` 标签误写成 stage truth
- 是否试图覆盖 lazy loading、`skills_whitelist` 或 workflow descriptor
- 是否与 `read_first:` 的职责有清晰边界
