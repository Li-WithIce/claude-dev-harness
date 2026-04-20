# Harness Lite

Windows 优先的单仓库开发 Harness，把 lite workflow 稳定安装到 Claude Code / Codex / Gemini workspace，保持共享记忆与任务产物结构一致。

## 快速开始

### 首次安装到目标项目

```powershell
# 方式一：快捷入口（自动推断 workspace）
pwsh -File .\harness.ps1 -WorkspaceRoot D:\my-project

# 方式二：完整参数
pwsh -File .\install.ps1 -WorkspaceRoot D:\my-project -RepoRoot <repo-root>

# Windows CMD 简写
harness.cmd -WorkspaceRoot D:\my-project
```

安装完成后，在目标项目中启动 Claude Code / Codex / Gemini 即可使用 lite workflow。

### 日常使用

安装后，开发任务自动经过以下流程：

1. **对话启动** — `using-superpowers` skill 自动加载，路由到 orchestrator
2. **新任务** — orchestrator 创建 `docs/tasks/<task-id>/plan.md`，进入 PLAN 阶段
3. **阶段推进** — 每个阶段完成后，执行推进命令进入下一阶段
4. **恢复** — 说"继续"或"resume"，自动从共享记忆恢复上次中断点

```powershell
# 推进阶段（在目标项目目录中执行）
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <claudecode|codex|gemini>

# TEST -> DONE 可以省略 -Tool
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id>
```

## 工作流

### 阶段流转

```
PLAN → PLAN_REVIEW → IMPLEMENT → CODE_REVIEW → TEST → DONE
```

唯一阶段真相源：`docs/tasks/<task-id>/plan.md` frontmatter。

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | gemini | none
updated: YYYY-MM-DD
---
```

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`、`gemini`
- `DONE` 固定写 `tool: none`
- 用户可以在任意 stage 边界切换 tool

### 阶段职责

| Stage | 调用 Skill | 主要产物 |
|---|---|---|
| `PLAN` | `plan` | `plan.md` 含 Clarification / User Confirmation / Plan / Verification / Risks |
| `PLAN_REVIEW` | `review` | `plan.md` 追加 `## Plan Review` run |
| `IMPLEMENT` | `implement` | 代码改动 + `plan.md` 追加 `## Implementation Notes` run |
| `CODE_REVIEW` | `review` | `plan.md` 追加 `## Code Review` run |
| `TEST` | `test` / `gemini-designer-main` | `docs/tasks/<task-id>/test.md` 含 Conclusion / Handoff |
| `DONE` | — | frontmatter 终态 |

补充分支：输入不足时可用 `spec` skill 生成 `docs/tasks/<task-id>/spec.md`（可选 delta-spec，不是默认入口）。

### 推进规则

- 所有推进只走 `advance-stage.ps1`，它会先自动运行 `validate-lite-artifacts.ps1` 校验产物
- 非 `DONE` 推进必须由用户显式指定下一阶段 `tool`
- CODE_REVIEW verdict=revise → 回退到 IMPLEMENT
- TEST fail/blocked → 停止报告，不自动回退

### Skill 路由

```
using-superpowers（每次对话自动加载）
  ├── 检测开发意图 → orchestrator
  │     ├── PLAN        → plan skill
  │     ├── PLAN_REVIEW → review skill
  │     ├── IMPLEMENT   → implement skill
  │     ├── CODE_REVIEW → review skill
  │     └── TEST        → test / gemini-designer-main skill
  ├── 恢复触发词 → 读共享记忆恢复上次中断点
  └── 非开发任务 → 直接处理（不进入 workflow）
```

可选委派：用户显式要求时通过 `codex` skill 委派给 Codex CLI。

### 共享记忆

安装后在目标项目生成 `.assistant/` Obsidian vault，结构：

| 路径 | 用途 |
|---|---|
| `运行时/当前任务.md` | 当前活跃任务指针（标准双列表格格式） |
| `运行时/恢复索引.md` | 快速恢复视图 |
| `运行时/中断任务.md` | 暂停的其他任务 |
| `运行时/上次会话.md` | 上次会话摘要 |
| `运行时/tasks/<task-id>.md` | 任务级详细状态 |
| `运行时/收件箱.md` | 待处理事项收件箱 |
| `运行时/记忆候选.md` | 未确认的记忆候选 |
| `配置/` | 用户偏好、系统信息、工具组件 |
| `工作流/` | 恢复协议、写回协议等 |

写回规则：

- `advance-stage.ps1` 每次推进自动重写 `当前任务.md`、`tasks/<task-id>.md`、`恢复索引.md`
- Runtime hooks 在 Claude Code 工具调用后自动刷新 `恢复索引.md`
- 空闲态当前文档统一写 `none`

### Runtime Hooks

安装到 Claude Code 的 3 个 hooks（`runtime-hooks/claude/`）：

| Hook | 触发时机 | 功能 |
|---|---|---|
| `posttooluse.js` | 每次工具调用后 | 刷新 `恢复索引.md`；释放 `runtime.lock.json`；锁冲突时回退到收件箱 |
| `stop.js` | 对话结束时 | 检测 `当前任务.md` 是否仍处于活跃状态，发出警告 |
| `userpromptsubmit.js` | 用户提交消息时 | 检测恢复触发词，注入恢复指引到对话上下文 |

## 仓库结构

```
claude-dev-harness/
├── harness.ps1 / harness.cmd     # 快捷引导入口
├── install.ps1                    # 安装到目标项目
├── uninstall.ps1                  # 从目标项目卸载
├── skills/                        # 10 个工作流 skills
│   ├── using-superpowers/         #   顶层路由入口
│   ├── orchestrator/              #   lite workflow 调度
│   │   └── references/            #   gates, runbook, state-templates, writing-guide
│   ├── plan/                      #   PLAN 产物规则
│   ├── implement/                 #   IMPLEMENT 产物规则
│   ├── review/                    #   PLAN_REVIEW / CODE_REVIEW 规则
│   ├── test/                      #   TEST 产物规则
│   ├── spec/                      #   可选 delta-spec
│   ├── obsidian-memory/           #   共享记忆与 runtime 维护
│   ├── codex/                     #   Codex CLI 委派
│   └── gemini-designer-main/      #   Gemini TEST runner
├── scripts/                       # 12 个 PowerShell 脚本
│   ├── advance-stage.ps1          #   阶段推进（核心）
│   ├── validate-lite-artifacts.ps1#   任务产物校验
│   ├── update-managed-assets.ps1  #   托管资产刷新
│   ├── memory-health.ps1          #   共享记忆健康检查
│   ├── memory-maintain.ps1        #   共享记忆维护（归档 + 报告 + 健康检查）
│   ├── memory-health-report.ps1   #   生成健康报告
│   ├── repair-shared-memory.ps1   #   修复共享记忆一致性
│   ├── archive-memory-candidates.ps1  # 归档已处理的记忆候选
│   ├── append-runtime-inbox.ps1   #   向收件箱追加条目
│   ├── triage-runtime-inbox.ps1   #   处理收件箱条目
│   ├── promote-runtime-inbox.ps1  #   提升收件箱条目为任务
│   └── resolve-obsidian-memory-script.ps1  # 解析共享记忆路径
├── runtime-hooks/claude/          # 3 个 Claude Code hooks
├── agent-configs/                 # Claude / Codex / workspace 配置模板
├── vault-template/                # .assistant 初始化骨架
├── tests/                         # 16 个回归测试
└── backups/                       # 安装备份（.gitignore）
```

## 安装与卸载

### 安装

```powershell
pwsh -File .\install.ps1 -WorkspaceRoot <workspace-root> [-RepoRoot <repo-root>]
```

安装动作：

1. 把 repo `skills/` junction 到 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills`
2. 写入 Claude hooks 到 `%USERPROFILE%\.claude\settings.local.json`
3. 生成 workspace `AGENTS.md` / `GEMINI.md`（入口 shim）
4. 初始化或刷新 `<workspace-root>/.assistant` vault
5. 写入 `.assistant/entry/advance-stage.ps1` 和 `validate-lite-artifacts.ps1` 入口
6. 写入 Codex managed config block

### 卸载

```powershell
pwsh -File .\uninstall.ps1 [-ManifestPath <path>] [-RepoRoot <repo-root>]
```

卸载根据 `backups/active-install.json` 清单恢复所有被修改的文件。

### 更新

已安装的 workspace 更新到最新 harness 版本：

```powershell
# 方式一：快捷入口
pwsh -File .\harness.ps1 -WorkspaceRoot <workspace-root>

# 方式二：直接调用
pwsh -File .\scripts\update-managed-assets.ps1 -WorkspaceRoot <workspace-root>
```

## 验证

### 安装验证

```powershell
pwsh -File .\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root> -RepoRoot <repo-root>
```

隔离 smoke 环境中传入临时 user profile：

```powershell
pwsh -File .\tests\verify-installation.ps1 -WorkspaceRoot <ws> -RepoRoot <repo> -UserProfileRoot <temp-user>
```

### 任务产物校验

仓库脚本入口：`scripts/validate-lite-artifacts.ps1`

```powershell
# 直接调用仓库脚本
pwsh -File .\scripts\validate-lite-artifacts.ps1 -TaskId <task-id>

# workspace 入口 shim
pwsh -File .assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>
```

校验内容：`plan.md` frontmatter schema、section 结构、append-only run 格式、`spec.md` 可选结构、`test.md` Conclusion/Handoff 契约。

### 共享记忆维护

```powershell
# 健康检查
pwsh -File .\scripts\memory-health.ps1 -VaultRoot <workspace-root>\.assistant

# 全量维护（归档 + 报告 + 健康检查）
pwsh -File .\scripts\memory-maintain.ps1 -VaultRoot <workspace-root>\.assistant

# 修复一致性
pwsh -File .\scripts\repair-shared-memory.ps1 -VaultRoot <workspace-root>\.assistant
```

## 回归测试

16 个测试覆盖全部核心功能：

| 测试 | 覆盖范围 |
|---|---|
| `verify-installation.ps1` | 安装闭环 |
| `verify-install-isolation.ps1` | 安装隔离性 |
| `verify-uninstall-isolation.ps1` | 卸载隔离性 |
| `verify-harness-entry.ps1` | harness.ps1 引导入口 |
| `verify-update-managed-assets.ps1` | 托管资产刷新 |
| `verify-workflow-contracts.ps1` | 阶段推进契约（advance-stage） |
| `verify-lite-artifact-validator.ps1` | 产物校验规则 |
| `verify-lite-footprint.ps1` | UTF-8 BOM 与文件规范 |
| `verify-runtime-hooks.ps1` | Runtime hooks 行为 |
| `verify-memory-maintain.ps1` | 记忆维护流程 |
| `verify-memory-health-report.ps1` | 健康报告生成 |
| `verify-repair-shared-memory.ps1` | 共享记忆修复 |
| `verify-archive-memory-candidates.ps1` | 记忆候选归档 |
| `verify-runtime-inbox.ps1` | 收件箱追加 |
| `verify-triage-runtime-inbox.ps1` | 收件箱处理 |
| `verify-promote-runtime-inbox.ps1` | 收件箱提升 |

运行全部测试：

```powershell
Get-ChildItem tests\verify-*.ps1 | ForEach-Object { pwsh -File $_.FullName }
```

## Windows 兼容

硬约束：

- 所有 active `.ps1` 必须使用 UTF-8 BOM（`verify-lite-footprint.ps1` 校验）
- Node hooks 读取共享运行时文件时必须容忍 BOM
- `verify-workflow-contracts.ps1` 校验 `advance-stage.ps1` 能被 `powershell.exe` 解析

## 写作规范

任务文档写法由 `skills/orchestrator/references/lite-writing-guide.md` 统一约束，覆盖：

- `plan.md` frontmatter 与 section 顺序
- `spec.md` 差量写法
- append-only review / implementation run 格式
- `test.md` 的 Conclusion / Handoff 契约
- P0/P1/P2/P3 finding 级别和自检清单
