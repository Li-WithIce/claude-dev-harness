---
task_id: 83e9ed91
artifact: gap-analysis
updated: 2026-06-22
status: final
owner: gap-reviewer
---

# dev-harness 与 Trellis-main 差距对比

## CodeGraph Context
- official_mcp_tools:
  - codegraph_status
  - codegraph_context
  - codegraph_search
  - codegraph_trace
  - codegraph_node
  - codegraph_files
  - codegraph_impact
  - codegraph_callers
  - codegraph_callees
  - codegraph_explore
- optional_runtime_helpers:
  - codegraph_affected
- status: unavailable
- sync: skipped
- queries:
  - context: codedb_status project=D:\data
  - context: codedb_context query='Trellis active task session runtime task store task lifecycle archive start current' path_glob='Trellis-main/.trellis/scripts/**/*.py'
  - context: codedb_context query='dev-harness advance stage validate lite artifacts plan frontmatter workflow descriptor shared memory' path_glob='dev-harness/**/*.ps1'
  - context: codedb_context query='harness lite workflow stage frontmatter skills orchestrator test review implement plan' path_glob='dev-harness/skills/**/*.md'
- affected_files:
  - dev-harness/docs/tasks/trellis-comparison-reusable-design/gap-analysis.md
  - .assistant/运行时/tasks/83e9ed91.md
- affected_tests:
  - not run: analysis-only task; source code unchanged
- fallback: Missing .codegraph index in workspace. Continued with rg/manual source reading and codedb-data context queries over D:\data.

## 结论

Trellis-main 相比 dev-harness 的核心差距不在阶段数量，而在三件事：

- Trellis 有更完整的 task entity：`task.json` 持久记录 assignee、priority、branch、base branch、PR、parent/children、related files、notes 和 meta；dev-harness 目前把阶段真相收敛在 `plan.md` frontmatter，缺少一个不参与 stage 判定的任务元数据层。
- Trellis 有更强的上下文注入链：`.trellis/spec/`、`implement.jsonl`、`check.jsonl`、per-turn workflow-state breadcrumb 和 session-scoped active task pointer 会共同决定 agent 每轮该读什么；dev-harness 已有 `.assistant`、`read_first`/`artifacts` 方向和 stage skill，但“按任务自动注入 context manifest”还不成体系。
- Trellis 有 finish/spec-update/commit/archive 的闭环：最后阶段要求检查、更新 spec、提交、归档和 journal；dev-harness 的 TEST/Handoff 与 validator 更硬，但对 spec/长期记忆提升、artifact 漂移抽查、任务归档的强制闭环较轻。

推荐路线：不要把 `.trellis/` 搬进 dev-harness；继续保留 `docs/tasks/<task-id>/plan.md` frontmatter 作为唯一阶段真相源。可吸收的部分应压缩成可选 task artifacts、review/test 抽查规则和 validator advisory。

## 事实源

- `dev-harness/README.md`：harness-lite 日常入口、阶段、`quick/workflow/ask` 路由、`docs/tasks` 与 `.assistant` 分工。
- `dev-harness/skills/orchestrator/SKILL.md`：`PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST`、frontmatter 契约、stage 推进与共享运行时 mirror。
- `dev-harness/skills/test/SKILL.md`：TEST 结论与 Handoff 契约。
- `dev-harness/scripts/validate-lite-artifacts.ps1`：当前 validator 的 hard contract。
- `dev-harness/agent-configs/workflows/harness-lite.yaml`：Codex-only 默认 stage profile 与 skills whitelist。
- `Trellis-main/README.md`：Trellis 的 specs、task-centered workflow、project memory 和 multi-platform 定位。
- `Trellis-main/.trellis/workflow.md`：Trellis 的 Plan / Execute / Finish、workflow-state breadcrumb、task artifact 与 finish 规则。
- `Trellis-main/.trellis/scripts/task.py` 与 `Trellis-main/.trellis/scripts/common/active_task.py`：任务生命周期、session-scoped active task pointer、degraded mode。
- `Trellis-main/.trellis/tasks/06-17-architecture-diagram/task.json`：实际 task entity 字段样例。
- `dev-harness/docs/tasks/trellis-comparison-reusable-design/trellis-reusable-design.md`：既有可复用设计判断。

## 能力对照

| 维度 | dev-harness 现状 | Trellis-main 现状 | 差距判断 |
|---|---|---|---|
| 阶段真相源 | `plan.md` frontmatter 是唯一 stage truth，`DONE` 是 frontmatter 终态。 | `task.json.status` + `.trellis/workflow.md` 状态块 + active task pointer 共同驱动每轮行为。 | dev-harness 更简洁、可审；Trellis 更自动，但多源状态更重。 |
| 任务元数据 | `plan.md` 承载阶段、计划、review、implementation notes；team board 是外部 mirror。 | `task.json` 持久记录 owner、priority、branch、PR、parent/children、related files 等。 | dev-harness 缺少不污染 frontmatter 的 task metadata artifact。 |
| 子任务树 | 主要靠 team task board 或 roadmap 文档；`docs/tasks` 本身没有标准 parent/child 字段。 | `task.py create --parent`、`add-subtask`、`remove-subtask` 和 `task.json.children/parent` 原生支持。 | 大型 roadmap/多 deliverable 任务有真实缺口。 |
| 上下文注入 | `.assistant` + entry lazy loading + stage skill；`read_first`/`artifacts` 是文档约束。 | `.trellis/spec`、`implement.jsonl`、`check.jsonl`、workflow-state breadcrumb、active task pointer 共同注入。 | dev-harness 缺少 machine-readable context manifest 的消费闭环。 |
| 平台适配 | Codex-first，Claude 可显式切换；team mode 是 opt-in。 | 面向多平台，区分 sub-agent dispatch 与 codex inline。 | 如果目标仍是 Windows/Codex-first，Trellis 多平台复杂度不应照搬。 |
| Review/Test | PLAN_REVIEW、CODE_REVIEW、TEST 是独立 gate，validator 对文档契约较硬。 | `trellis-check` 负责 diff/spec/task artifact 检查，可自修；finish 前还有 full-scope check。 | dev-harness gate 更清楚；可补 artifact drift/spec update 抽查。 |
| 记忆与学习 | `.assistant` 有配置、运行时、wisdom 四类文件；长期提升需确认。 | `.trellis/spec` 是持续更新的项目知识，workspace journal 记录会话。 | dev-harness 已覆盖大部分记忆层；缺少“任务结束时必须判断是否更新 spec/记忆”的硬步骤。 |
| 归档闭环 | TEST pass 后 `advance-stage` 到 DONE；运行时 mirror 更新。 | `finish/archive` 清 active pointer、移动 task 到 archive、记录 session/journal，可配置 auto commit。 | dev-harness 缺归档与 journal 强闭环；但这不一定值得引入为默认。 |
| 运行时复杂度 | 无常驻服务，脚本和文件协议为主。 | session runtime、hooks、channels/worker guard、multi-platform adapters 较多。 | Trellis 自动化强，但引入会显著增加维护面。 |

## 真实缺口

### G1. 任务实体元数据层

dev-harness 缺少一个标准位置表达 owner、priority、branch、PR、parent/child、external issue、related files 等任务元信息。把这些继续塞进 `plan.md` frontmatter 会污染唯一阶段真相源；更合适的是新增可选 `task-entity.yaml` 或 `task-entity.md` artifact，并在 `plan.md artifacts:` 中声明。

优先级：P1。  
建议边界：禁止写 stage、verdict、tool、current step；这些仍归 `plan.md` frontmatter 和 append-only runs。

### G2. Context manifest 的消费闭环

Trellis 的 `implement.jsonl` / `check.jsonl` 是按任务选择 specs/research 的机器可读上下文清单。dev-harness 目前有 lazy loading 和 task artifact，但缺少一份“下一阶段必须读取哪些稳定文件”的标准 manifest 及 validator 抽查。

优先级：P1。  
建议边界：先做 advisory，不自动注入到所有 agent；避免和现有 skill lazy loading 冲突。

### G3. 子任务树与 roadmap 映射

Trellis 原生 parent/child task 适合多 deliverable 工作。dev-harness 目前能通过 team task board 拆分，但 docs artifact 层没有标准映射，长期恢复时容易只看到单个 `plan.md`。

优先级：P2。  
建议边界：新增 `subtasks.yaml` 或 `docs/roadmaps/<slug>/items.yaml`，不参与 `advance-stage.ps1`。

### G4. Artifact drift advisory

dev-harness validator 能校验 `plan.md`/`test.md` 结构，但对 `artifacts:` 声明、实际文件、`Change Contract.affected_paths`、`git diff --name-only` 的一致性还没有形成默认 advisory。Trellis 的 check/finish 语义更强调这类收尾检查。

优先级：P1。  
建议边界：先 warning，不阻断旧任务；新任务 dogfood 后再考虑 hard gate。

### G5. Finish 阶段的 spec/记忆提升判断

Trellis 在 finish 中把 `trellis-update-spec` 放成 required once。dev-harness 已有 `.assistant` 记忆和收件箱协议，但 TEST/Handoff 没有强制问“本任务是否产生需要沉淀的规则、坑、决策”。

优先级：P2。  
建议边界：只在 TEST/Handoff 模板中新增判断项；长期记忆提升仍遵守用户确认和 single-writer 规则。

### G6. Session/journal 归档

Trellis workspace journal 对跨会话回放有帮助，且 archive 会移动已完成 task。dev-harness 的恢复索引更轻，但缺少按任务完成归档的完整时间线。

优先级：P3。  
建议边界：不默认 auto commit，不移动 `docs/tasks`；如需要，只追加 session summary artifact。

## 已覆盖或更优的部分

- dev-harness 的阶段 gate 更显式：PLAN_REVIEW、CODE_REVIEW、TEST 是硬阶段，Trellis 的 check/finish 更像一组流程步骤。
- dev-harness 的 validator 更适合团队审计：frontmatter、section、结论、handoff 都能被脚本直接判定。
- dev-harness 的 `.assistant` 分层已经覆盖 Trellis workspace memory / specs / journal 的大部分用途，只是结束时沉淀动作不够强。
- dev-harness 的 quick/workflow/ask 路由更适合用户“直接改”和“留痕”的不同成本需求；Trellis 默认更强调 task creation consent 和 plan-before-code。
- dev-harness 当前与 AiTeamCode team board/CodeGraph artifact 的集成更贴近本工作区，不应被 `.trellis` runtime 取代。

## 不建议引入

- 不引入 `.trellis/` 目录作为第二套任务根。它会和 `docs/tasks/<task-id>/`、`.assistant/运行时/tasks/<task-id>.md`、team task board 形成三重入口。
- 不让 `task.json.status` 或 session pointer 参与 stage 判定。stage 仍只看 `plan.md` frontmatter。
- 不复制 Trellis 多平台 hook/adapters 的完整复杂度。dev-harness 的当前目标是 Windows/Codex-first，过度平台化会扩大维护面。
- 不默认 auto commit journal/archive。用户偏好是先检查、再编辑、最后总结验证；提交应保留明确边界。
- 不把 spec update 变成无确认的长期记忆写入。dev-harness 的 shared memory 协议要求长期记忆提升前确认。

## 建议任务切分

| 优先级 | 建议任务 | 产出 | 验收标准 |
|---|---|---|---|
| P1 | `task-entity-artifact-design` | `task-entity.md/yaml` 规范 + 示例 | 元数据不进入 frontmatter；validator 能 advisory 检查声明与存在性。 |
| P1 | `context-manifest-advisory` | `context-manifest.jsonl` 或复用 `artifacts/read_first` 的机器可读规则 | IMPLEMENT/CODE_REVIEW/TEST 可明确知道要读哪些 specs/research。 |
| P1 | `artifact-drift-advisory` | validator warning 或独立脚本 | 对比 `artifacts:`、affected paths、实际 diff 和文件存在性。 |
| P2 | `finish-boundary-checklist` | 更新 `skills/test` 与 `skills/review` 写作规则 | Handoff 必须记录 artifact、follow-up、memory/spec update 判断。 |
| P2 | `subtask-roadmap-artifact` | `subtasks.yaml` / roadmap items 格式 | 能表达 parent/child、依赖、完成判据和对应 task_id，不驱动 stage。 |
| P3 | `session-summary-artifact` | 可选 `session.md` 或 `case.md` 模板 | 长 debug/incident 任务可保留时间线与命令证据。 |

## 最小落地顺序

1. 先做 `finish-boundary-checklist` 和 `artifact-drift-advisory`，因为它们不改变 stage truth，且能直接补当前 harness 的证据闭环。
2. 再做 `task-entity-artifact-design`，给大型任务承载 branch/PR/subtask/owner 信息。
3. 最后评估 `context-manifest-advisory`，避免过早和现有 lazy loading、stage skill 机制重叠。

## 交接

- 本报告只读分析，不修改源码。
- CodeGraph MCP 不可用，原因是 `D:\data\.codegraph` 索引缺失；已用 `rg`、文件读取和 `codedb-data` 查询补足事实源。
- 可直接把 P1 三项转成后续 workflow 任务；不需要重开“是否引入 Trellis runtime”的讨论。
