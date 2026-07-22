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

用 Codex 打开目标工作区，直接描述目标、验收、范围与限制。普通快速开始不要求设置环境变量；在尚无 eligible rollout report 的工作区中，`auto` 会继续选择 v1。需要主动试用 v2 的新任务时，可在启动 Codex Desktop 前显式设置 `HARNESS_PROTOCOL=v2`；已有任务仍按自身 v1 `plan.md` 或 v2 `task.json` 继续原协议。

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

状态会分别报告 Hook 是否安装、信任与可调用性、Codex Host 版本、Protected Action policy、Desktop enforcement 和 Canonical rollout report。宿主无法权威查询 Hook trust/callable 时结果是 `unknown`；当前受控 Desktop writer 尚未由安装器部署，因此 `desktop_enforcement` 是 `unavailable`。直接运行 `harness-status.ps1` 时整体为 `WARN`，不能当成资格通过；`harness.ps1` 的成功 bootstrap/update 仍返回 `PASS`，并把这项 `WARN` 作为可见的 advisory step 保留下来。

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

`HARNESS_PROTOCOL=v1` 让新任务回到 v1 路由，不会删除已有 v2 task。需要移除安装器托管资产时，单独运行：

```powershell
pwsh -File .\uninstall.ps1 `
  -WorkspaceRoot D:\my-project `
  -RepoRoot D:\data\dev-harness
```

v1/v2 共存和任务迁移见 [v1-to-v2 migration](migration/v1-to-v2.md)。
