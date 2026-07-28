# Thin Harness v2 快速上手

## 安装

在 Harness 仓库中运行：

```powershell
pwsh -File .\install.ps1 `
  -WorkspaceRoot D:\my-project `
  -RepoRoot D:\data\dev-harness `
  -Preset core
```

`core` 适合普通开发。需要持久规划与审计工具时使用 `governed`；只有确实需要共享记忆、team 等完整能力时才使用 `full`。对同一工作区再次运行安装命令就是 update；省略 `-Preset` 时会保留已安装 preset。

## 使用

用 Codex 打开目标工作区，直接描述目标、验收、范围与限制。当前普通快速开始不要求设置环境变量，默认 `auto` 仍选择 v1。需要让该项目的新任务主动使用 v2 时，执行一次工作区级 opt-in：

```powershell
# status：只读显示这个工作区的新任务会选择什么协议
pwsh -File .assistant\entry\task.ps1 protocol

# enable：写入默认不入 Git 的项目配置；之后正常打开 Desktop 即可
pwsh -File .assistant\entry\task.ps1 enable-v2

# reset：回到 Runtime Default 驱动的 auto；disable：立即让新任务回到 v1
pwsh -File .assistant\entry\task.ps1 reset-auto
pwsh -File .assistant\entry\task.ps1 disable-v2
```

配置文件是 `.assistant/config/protocol.json`，schema 为 `harness-protocol-config/v1`；它严格只接受 `new_task_protocol=auto|v1|v2`，由用户持有，install/update/uninstall 不接管或删除。已有任务仍按自身 v1 `plan.md` 或 v2 `task.json` 继续原协议，并且永远优先于环境变量和工作区配置。项目级 `enable-v2` 是当前公共显式 opt-in，不代表 Default Promotion 或零配置 Auto 默认 v2 已完成。

进入 v2 后，Harness 会把请求归入：

- Inspect：只读，零写入。
- Ask：仍有会改变产品、权限、兼容或不可逆结果的未决决定，先澄清。
- Direct：清楚、可逆、低风险，直接修改并做聚焦验证，不创建任务产物。
- Governed：需要持久留痕或更强控制，创建 v2 task state 和 Evidence。
- Critical：受保护或不可逆高风险工作，执行前必须满足额外能力门。

不需要手工选择 profile，也不要把未运行的测试写成通过。详细边界见 [Requirement Gate](requirement-gate.md) 与 [Governed work](governed-work.md)。

## 健康状态

需要检查安装与桌面能力时运行：

```powershell
pwsh -File D:\data\dev-harness\scripts\harness-status.ps1 `
  -WorkspaceRoot D:\my-project `
  -RepoRoot D:\data\dev-harness
```

默认状态只报告实际 Host product/version、可观测 Capability、协议选择来源、Runtime Default Decision、工作区配置、已有任务 artifact 和 Protected Action policy。无法权威观测的 Capability 保持 `unavailable`，不会被解释为版本不匹配，也不会让普通 Direct 因 request-send telemetry 或 Hook status 不可用而失败。需要查看精确 Release Profile、Gate、Evidence、Review 或 Canary 时，必须显式运行 `scripts/qualification-status.ps1`；默认 `harness.ps1` 不调用它。

## Worktree

每个 linked worktree 都是独立工作区。在 worktree 的任意子目录中可一键完成默认 Core bootstrap 和状态检查：

```powershell
pwsh -File D:\data\dev-harness\harness.ps1
```

也可以显式指定它自己的绝对路径安装：

```powershell
pwsh -File D:\data\dev-harness\install.ps1 `
  -WorkspaceRoot D:\repo-worktrees\feature-a `
  -RepoRoot D:\data\dev-harness `
  -Preset core
```

不要从主 checkout 复制 live `.assistant/runtime` 或 current pointer。真正的 Git submodule 继续使用父 workspace；独立嵌套仓库（包括 `--separate-git-dir`）和 linked worktree 使用自己的 worktree root。

## 回滚

`.assistant\entry\task.ps1 disable-v2` 让该工作区的新任务回到 v1 路由；`HARNESS_PROTOCOL=v1` 仍可用于一次性维护止损。它们不会删除已有 v2 task。需要移除安装器托管资产时，单独运行；用户的 `.assistant/config/protocol.json` 会保留：

```powershell
pwsh -File .\uninstall.ps1 `
  -WorkspaceRoot D:\my-project `
  -RepoRoot D:\data\dev-harness
```

v1/v2 共存和任务迁移见 [v1-to-v2 migration](migration/v1-to-v2.md)。
