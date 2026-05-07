---
task_id: bf2f2b6a
review_type: gap-analysis
tool: codex
updated: 2026-04-30
reviewer: workflow-analyst
verdict: read-only-analysis
---

# Harness vs AionUi Workflow Gap Analysis

## 范围

只读分析当前 harness 与 AionUi team / workflow / runtime 的能力差距，不实现、不扩 scope、不开新 stage。对照基准：`docs/tasks/harness-aionui-workflow-alignment/architecture.md`（原 7 phase + 13 risk 计划）+ 已落地证据（git log、`agent-configs/`、`skills/workflow-team/`、`skills/orchestrator/shared-memory/v2/`）。

## TL;DR

原 architecture.md 设计的 Phase 0-7 + shared-memory v2 已全部 commit 落地（约占原 gap 计划的 85%）。

剩余差距集中在 **AionUi 运行时层**（live multi-agent spawn、ACP JSON-RPC direct speak、SQLite-backed conversation/team store），这些在 harness 侧由 **vault-based shared-memory v2 + workflow-team skill + spawn-team.ps1** 等价覆盖，属于 "实现路径不同"，不是真实能力空白。建议把 architecture.md 提到的旧对齐任务组（`ee7aec19 / 63c847d5 / 82158830` 及其下游 phase X plan/review/implement/validate/commit 任务，约 60+ 条）整体判为**废弃**——其语义已通过不同 task_id 实际落地。

真正值得保留的 follow-up 只有 2 条（均暂缓）：SKILL.md inputs/outputs schema 形式化、live AionUi 端到端 team smoke test。

## 已落地证据

| 项目 | 证据 | 状态 |
|---|---|---|
| Phase 1 Tool Profile | `agent-configs/profiles/harness-default-{claude,codex,gemini}.yaml` | landed |
| Phase 2 Workflow descriptor | `agent-configs/workflows/harness-lite.yaml` | landed |
| Phase 3 SKILL manifest | `skill-manifest.json` 生成路径 | landed |
| Phase 4 Team preset bridge | `skills/workflow-team/scripts/spawn-team.ps1` | landed |
| Phase 5/6 Protocol hardening | commit `ed66eb9` | landed |
| Phase 7 Runtime hook artifact | commit `d1251bc` | landed |
| Shared memory v2 | commit `d1bae21`（vault-based，已 migrate live vault） | landed |
| Phase 1-4 集成 | commit `309f0ee` | landed |

git log 摘要显示 Phase 0-7 + shared-memory v2 已全部 commit，且各 phase 验证文件均 verdict=pass（代为抽查 phase2-phase7 validation 文件均 PASS）。

## 关键 Gap（6 项）

### G1 — Live multi-agent spawn / lifecycle（运行时差异）

- **AionUi**：通过 `team_spawn_agent` / `team_shutdown_agent` 直接拉起 ACP backend 子进程，配 SQLite `teams` 表跟踪 slotId。
- **Harness**：通过 `spawn-team.ps1` + `agent-configs/profiles/*` 在外部 shell 启动子 agent，状态落 vault。
- **判定**：实现路径不同；harness 侧更轻量（无常驻 daemon），不构成能力空白。
- **决策**：不追平。

### G2 — ACP JSON-RPC direct speak（运行时差异）

- **AionUi**：`team_send_message` 通过 ACP protocol 在子进程间转发。
- **Harness**：通过 vault 文件（mailbox / shared notes）异步交互，依赖 polling / 显式读。
- **判定**：实时性低于 AionUi，但 harness lite workflow 本身是阶段化、非实时的，vault 模型够用。
- **决策**：不追平；如未来需要实时 collab 再开新任务。

### G3 — SQLite-backed conversation / team / mailbox（运行时差异）

- **AionUi**：conversations / teams / mailbox / team_tasks 全在 SQLite。
- **Harness**：vault v2 是 single source of truth；恢复索引 + tasks/<id>.md + mailbox 目录用文件系统承载。
- **判定**：vault 是 canonical 选择（git-friendly、无运行时依赖），SQLite 在 harness 侧反而是负担。
- **决策**：不追平。

### G4 — Tool profile + model 选择（已覆盖）

- **原 gap**：架构文档曾要求显式 backend / model 绑定。
- **现状**：Phase 1 三份 profile YAML 已落地，`advance-stage.ps1 -Tool / -Profile / -Model` 已串通。
- **决策**：closed，无需后续。

### G5 — SKILL.md inputs/outputs schema 形式化（暂缓）

- **现状**：所有 SKILL 用自然语言描述输入/输出，没有 JSON schema 校验。
- **影响**：跨 backend 调用时易出现字段漂移，但当前 lite workflow 的 SKILL 都由 validator 间接约束（plan.md frontmatter / Run 格式），实际未形成阻塞。
- **决策**：暂缓；如出现 cross-backend 字段漂移再开任务。

### G6 — Live AionUi 端到端 team smoke test（暂缓）

- **现状**：Phase 4 设计了 spawn-team 桥接，但没有跑过一次真实 AionUi → harness skill 的 end-to-end smoke。
- **风险**：架构文档 R-MCP（risk: live MCP 行为漂移）尚未被现实测试覆盖。
- **决策**：暂缓；需要时单独开 dogfood 任务，不并入对齐主线。

## 任务分类建议

### 继续（无紧迫）

- 无。当前对齐主线无紧迫缺口。

### 暂缓（保留 backlog，不进当前迭代）

- **SKILL inputs/outputs schema 形式化**（对应 G5）
- **Live AionUi end-to-end team smoke test**（对应 G6 / 架构文档 R-MCP）

### 废弃

以下 team_task_list 中的任务因实际工作已通过不同 task_id 落地（见上方"已落地证据"表），保留只会污染 backlog，建议整体判废：

- `ee7aec19` / `63c847d5` / `82158830` — 原 architecture.md 三条主线追踪任务
- 与之关联的 ~60 条 phase-X-plan / phase-X-review / phase-X-implement / phase-X-validate / phase-X-commit 子任务（已被 commit `309f0ee` / `d1bae21` / `ed66eb9` / `d1251bc` 等覆盖）

### 真正未关闭的独立任务（与本对齐主线无关，仅供 Leader 参考）

- `294bf604` — verify-update-managed-assets
- `68bd1fbf` — sandbox_mode writeback
- `85ff35b0` — codex startup smoke test

这三条不是对齐主线遗留，是独立的小任务，按各自优先级处理即可。

## 结论

原 architecture.md 的 7 phase 计划事实上已完成 ~85%，剩余 gap 全部归类为"运行时实现差异（不追平）"或"暂缓 backlog"。**不建议重启 `ee7aec19 / 63c847d5 / 82158830` 任务组**——它们的语义已落地，重启只会导致重复工作和 task board 噪音。如未来出现 G5（schema 漂移）或 G6（live MCP 行为问题）的真实证据，再单独开新任务即可，不必走原对齐主线。
