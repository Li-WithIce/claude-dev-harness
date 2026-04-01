# Implementation Notes

> task_id: dev-stage-harness-refactor
> task_name: 开发阶段 Harness 化工作流改造
> date: 2026-04-01

## 改了什么

- 将 `using-superpowers` 重定向为开发阶段入口，明确 approved inputs、可选 `DELTA_SPEC` 与 `INTAKE -> PLAN -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF`
- 将 `orchestrator` 与 references 收敛为开发阶段 harness，补齐 `handoff.md`、shared runtime hard gate、UTF-8 编码纪律与 legacy `DONE` 兼容读取
- 将 `spec` / `plan` / `implement` / `review` / `test` 五个阶段 skill 对齐为开发阶段语义，明确 `plan.md` 主文档和 `spec.md` 可选 delta-spec 角色
- 继续根据 review 收口 `review.md` 的显式 `review_verdict` 契约，并将 `handoff.md` 统一为“全程滚动状态文档，HANDOFF 时承担最终交付快照”
- 修正 non-UI 任务的 approved input 契约：允许 `ui review: not-applicable`，并同步到 gate、runbook、state template、validation scenario 与结果文档
- 为 `.assistant` 增加 `schema-versions.md`、`敏感信息规范.md`、`任务识别协议.md` 与任务状态模板，并将模板中的可写 stage 值集与 canonical artifact links 收口到当前 harness，补齐 schema 演进、artifact link 和多任务切换协议
- 将 `.assistant/运行时/tasks/*.md` 的 5 个任务状态文件全部补齐到 `task-runtime/v1.1` 最低字段，并把可迁移的 legacy `DONE` 当前态收口为 `HANDOFF`
- 将 `.claude` 主稿同步到 `.codex` 镜像，并完成完整矩阵 hash 校验

## 没改什么

- 未新增顶层 skill
- 未引入 `delivery.md`
- 未改动共享运行时指针文件（`当前任务.md`、`中断任务.md`、`恢复索引.md`、`上次会话.md`）

## 风险点

- 这次验证以文档契约、一致性扫查和镜像矩阵为主，尚未用一个真实开发任务完整跑通 live orchestrator 写回链
- 历史在途任务仍需要按新 `runbook.md` 执行一次迁移/兼容验证
- `.assistant` 的任务状态文件已完成字段级回填，但共享指针类文件仍需入口 agent 按新协议统一刷新

## reviewer watchouts

- 后续新写 markdown 仍需显式使用 UTF-8，避免再次引入乱码
- 后续修改必须继续保持 `.claude` 单源、`.codex` 只做镜像
- 新任务应优先消费 approved inputs，而不是默认回到全量 `spec` 流程
- 多任务切换仍应由入口 agent 刷新共享指针文件；Codex 只补协议和任务级状态

## 本轮已执行的验证

- PowerShell `Select-String` 术语扫查，确认 `.claude` 与 `.codex` 关键 skill 已切到 `INTAKE` / `HANDOFF` / `DELTA_SPEC`
- 定点核对 `artifact-contracts`、`gates`、`runbook`、`state-templates`、`examples`，确认当前 `handoff.md` 样例中的 `review_verdict`、输入状态值集与 rolling 状态文档模型一致
- `.claude` 与 `.codex` 完整镜像矩阵 hash 比对通过
- 关键文件按 `-Encoding utf8` 读取 spot-check，无明显 mojibake
- `.assistant` 新增协议文档、任务状态模板与活跃任务状态文件按 `utf8` 读取 spot-check，通过 schema / artifact link / task-identification / stage-enum 关键字检查
- `.assistant/运行时/tasks/*.md` 全量扫描通过：5/5 任务状态文件均已具备 `schema_version`、`primary_artifact` 与 `Artifact Links`
- `{WORKSPACE_ROOT}\memory-health.ps1` 基础健康检查返回 `STATUS: PASS`
