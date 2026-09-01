# Thin Harness v2 快速上手

以下描述 TK-03 的 v2-only 源码契约；不表示已有工作区已经更新，也不表示 Qualification、Promotion 或 Stable 已通过。

## 安装

在 Harness 仓库中运行：

```powershell
pwsh -File .\install.ps1 `
  -WorkspaceRoot D:\my-project `
  -RepoRoot D:\data\dev-harness `
  -Preset core
```

`core` 适合普通开发。需要持久规划与审计工具时使用 `governed`；只有确实需要可选共享记忆、md-html 和 Provider 参考时才使用 `full`。三个 preset 均不安装退役的 v1 生命周期或 workflow-team。对同一工作区再次运行安装命令就是 update；省略 `-Preset` 时会保留已安装 preset。

## 使用

用 Codex 打开目标工作区，直接描述目标、验收、范围与限制。新任务的 `auto` 只准入 v2；没有配置和 Runtime Decision 时默认准入，有无效 Decision 时阻断。可以用工作区级命令查看、启用或暂停新工作：

```powershell
# status：只读显示这个工作区的新任务会选择什么协议
pwsh -File .assistant\entry\task.ps1 protocol

# enable：明确重新启用新 v2 工作；配置默认不入 Git
pwsh -File .assistant\entry\task.ps1 enable-v2

# reset：重新启用 v2-only auto；disable：暂停新工作，不切回 v1
pwsh -File .assistant\entry\task.ps1 reset-auto
pwsh -File .assistant\entry\task.ps1 disable-v2
```

新写入的 `.assistant/config/protocol.json` 使用 `harness-protocol-config/v2`：`new_task_protocol=auto|v2`、`new_work=enabled|paused`。它由用户持有，install/update/uninstall 不接管或删除。历史 v1 配置中有效的 `auto`/`v2` 可原字节读取，`v1` 则拒绝。暂停也约束显式 `HARNESS_PROTOCOL=v2`，但不妨碍已有有效 v2 任务恢复；已有 v2 artifact 优先于新任务配置。只有旧 plan 而没有 v2 state 的任务会要求显式迁移，不会执行旧生命周期。代码默认值不等于 Release Default Promotion 已完成。

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

默认状态只报告 Host product、当前 Runtime 所需 Capability、协议选择来源、Runtime Default Decision、工作区配置、已有任务 artifact 和 Protected Action policy；它不启动 `codex --version`，Host version 作为未探测的可选事实显示为 `unknown`。只有显式运行同一命令并追加 `-ProbeHostDetails` 才观察版本；未被当前 Decision 要求的 Capability 即使是 `unavailable` 也不形成 WARN，更不会被解释为版本不匹配。

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

## 止损与卸载

`.assistant\entry\task.ps1 disable-v2` 暂停新工作，保留既有 v2 恢复；`HARNESS_PROTOCOL=v1` 已退役并会拒绝。恢复旧的已知良好 v2 分发仍需单独明确授权，不得删除已迁移 state 来复活 v1。需要移除安装器托管资产时，单独运行；用户的 `.assistant/config/protocol.json` 会保留：

```powershell
pwsh -File .\uninstall.ps1 `
  -WorkspaceRoot D:\my-project `
  -RepoRoot D:\data\dev-harness
```

显式暂停迁移和历史保留见 [v1-to-v2 migration](migration/v1-to-v2.md)；物理删除旧源码仍受 [Sunset 契约](architecture/v1-sunset-contract.md) 的独立门槛约束。
