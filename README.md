# Harness Lite

Windows 优先的单仓库开发 Harness，目标只有一个：把 lite workflow 稳定安装到 Claude / Codex / workspace，并保持共享记忆与任务产物结构一致。

## 范围

这个仓库只保留 harness-lite 主线：

- 唯一任务路径：`docs/tasks/<task-id>/`
- 唯一阶段集合：`PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST -> DONE`
- repo 内部推进脚本：`scripts/advance-stage.ps1`
- 项目内入口 shim：`.assistant/entry/advance-stage.ps1`
- 共享记忆骨架：`vault-template/`
- 安装闭环：`install.ps1` / `uninstall.ps1` / `tests/verify-installation.ps1`

不再保留历史 `skills/docs/*` canonical docs、`skills/docs` 热切换同步机制、旧 stage machine 文档集合。

## 主流程

### 任务真相源

lite workflow 的唯一阶段真相源是：

- `docs/tasks/<task-id>/plan.md` frontmatter

最小 frontmatter：

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | gemini | none
updated: YYYY-MM-DD
---
```

规则：

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`、`gemini`
- `DONE` 只能写 `tool: none`
- 用户可以在任意 stage 边界切换 tool；下一阶段用什么工具，不再由固定矩阵推导

### 阶段职责

| Stage | 主要产物 | tool |
|---|---|---|
| `PLAN` | `docs/tasks/<task-id>/plan.md` | 用户显式指定 |
| `PLAN_REVIEW` | `plan.md` 中 `## Plan Review` | 用户显式指定 |
| `IMPLEMENT` | 代码改动 + `plan.md` 中 `## Implementation Notes` | 用户显式指定 |
| `CODE_REVIEW` | `plan.md` 中 `## Code Review` | 用户显式指定 |
| `TEST` | `docs/tasks/<task-id>/test.md` | 用户显式指定 |
| `DONE` | frontmatter 终态 | 固定写 `none` |

### 推进规则

所有阶段推进都只走：

```powershell
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <claudecode|codex|gemini>
```

只有 `TEST -> DONE` 可以省略 `-Tool`；其余推进都必须由用户显式指定下一阶段 tool。

它负责：

- 先自动运行 `scripts/validate-lite-artifacts.ps1`
- 更新 `plan.md` frontmatter
- 重写 `运行时/tasks/<task-id>.md`
- 重写 `运行时/当前任务.md`
- 重写 `运行时/恢复索引.md`

### 共享指针格式

`运行时/当前任务.md` 不是自由格式文本，而是 shared-memory 的标准指针文档。

- 必须包含 `task_id` frontmatter
- 必须包含 `任务 / 状态 / 当前文档 / 下一步` 的双列表格
- `advance-stage.ps1`、`repair-shared-memory.ps1`、runtime hooks 都按这个格式读写
- 空闲态当前文档统一写 `none`，不允许再写伪路径如 `docs/tasks/none/plan.md`

## 仓库结构

| 路径 | 作用 |
|---|---|
| `skills/using-superpowers/` | 顶层路由入口 |
| `skills/orchestrator/` | lite workflow 调度 |
| `skills/plan/` | PLAN 产物规则 |
| `skills/implement/` | IMPLEMENT 产物规则 |
| `skills/review/` | PLAN_REVIEW / CODE_REVIEW 规则 |
| `skills/test/` | TEST 产物规则 |
| `skills/gemini-designer-main/` | Gemini TEST runner |
| `skills/obsidian-memory/` | 共享记忆与 runtime 维护 |
| `skills/orchestrator/references/lite-writing-guide.md` | lite 文档写作规范 |
| `agent-configs/` | Claude / Codex / workspace 模板 |
| `runtime-hooks/claude/` | Claude runtime hooks |
| `vault-template/` | `.assistant` 初始化骨架 |
| `install.ps1` | 安装入口 |
| `uninstall.ps1` | 卸载入口 |
| `tests/verify-installation.ps1` | 安装验证入口 |

## 安装

```powershell
pwsh -File .\install.ps1 -WorkspaceRoot <workspace-root> -RepoRoot <repo-root>
```

安装会：

- 把 repo `skills/` 链接到 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills`
- 写入 Claude hooks
- 生成 workspace `AGENTS.md` / `GEMINI.md`
- 初始化或刷新 `<workspace-root>/.assistant`
- 写入 Codex managed config block

## 验证

### 宿主验证

```powershell
pwsh -File .\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root> -RepoRoot <repo-root>
```

如果在隔离 smoke workspace 中验证，显式传入临时 user profile：

```powershell
pwsh -File .\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root> -RepoRoot <repo-root> -UserProfileRoot <temp-user-root>
```

### 托管资产刷新

```powershell
pwsh -File .\scripts\update-managed-assets.ps1 -WorkspaceRoot <workspace-root>
```

这个入口现在只做两件事：

1. 重新运行 `install.ps1`
2. 可选再运行 `verify-installation.ps1`

### 共享记忆检查

```powershell
pwsh -File .\scripts\memory-health.ps1 -VaultRoot <workspace-root>\.assistant
pwsh -File .\scripts\memory-maintain.ps1 -VaultRoot <workspace-root>\.assistant
```

需要单独排查任务文档时，再运行：

```powershell
pwsh -File .assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>
```

它会校验：

- `scripts/validate-lite-artifacts.ps1` 是当前唯一的 lite artifact validator
- `plan.md` frontmatter schema
- `Clarification / User Confirmation / Plan / Verification / Risks` section
- append-only `Plan Review / Implementation Notes / Code Review` run 格式
- 可选 `spec.md` 的固定结构
- `test.md` 的 `Conclusion / Handoff` 契约

## Windows 兼容

这个仓库仍以 Windows PowerShell 作为安装与验证主路径之一，因此有两个硬约束：

- 保留的 active `.ps1` 必须使用 UTF-8 BOM
- 任何读取共享运行时文件的 Node hook 都必须容忍 BOM

当前实现里：

- [advance-stage.ps1](D:/data/claude-dev-harness/scripts/advance-stage.ps1) 与保留的回归脚本都按 UTF-8 BOM 落盘
- [posttooluse.js](D:/data/claude-dev-harness/runtime-hooks/claude/posttooluse.js) 与 [stop.js](D:/data/claude-dev-harness/runtime-hooks/claude/stop.js) 读取文件时会去掉 BOM
- `tests/verify-workflow-contracts.ps1` 会直接校验 `advance-stage.ps1` 能被 `powershell.exe` 解析
- `tests/verify-lite-footprint.ps1` 会校验 active `.ps1` 全部带 BOM

## 设计约束

- repo 只保留 lite workflow 必需 skill：`using-superpowers`、`orchestrator`、`plan`、`implement`、`review`、`test`、`spec`、`obsidian-memory`、`codex`、`gemini-designer-main`
- 不再维护 repo 内历史任务文档仓 `skills/docs/*`
- 不再维护 `skills/docs` 的 preserved directory / sync 机制
- 不再向新文档写入 `INTAKE` / `DEV` / `HANDOFF` / `REVIEW(implementation)`
- 不再把 `current-flow.md` / `handoff.md` / `implementation-notes.md` / `review.md` 作为 lite workflow 的主制品
- 只保留对当前安装、共享记忆、lite stage 推进真正有用的脚本和引用资料

## 写作规范

lite 主线的任务文档写法统一由这份规范约束：

- [skills/orchestrator/references/lite-writing-guide.md](D:/data/claude-dev-harness/skills/orchestrator/references/lite-writing-guide.md)

它覆盖：

- `plan.md` frontmatter 与 section 顺序
- `spec.md` 的差量写法
- append-only review / implementation run 格式
- `test.md` 的 `Conclusion / Handoff` 契约
- `P0/P1/P2/P3` finding 级别和自检清单

## 回归基线

截至 2026-04-10，保留 suite 顺序回归应为 `16/16 PASS`。

当前基线：

- `tests/verify-installation.ps1` 通过
- `tests/verify-lite-artifact-validator.ps1` 通过
- `tests/verify-lite-footprint.ps1` 通过
- `tests/verify-workflow-contracts.ps1` 通过
- `tests/verify-memory-maintain.ps1` 通过
- `tests/verify-runtime-inbox.ps1` / `verify-triage-runtime-inbox.ps1` / `verify-promote-runtime-inbox.ps1` 通过
- `tests/verify-repair-shared-memory.ps1` 通过
- `tests/verify-runtime-hooks.ps1` 通过
- `tests/verify-memory-health-report.ps1` 通过
