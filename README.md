# Claude Dev Harness

Windows 优先的单仓库 Harness 分发仓库。

当前目标：

- `skills/` 作为 Claude / Codex 共用单源
- `runtime-hooks/claude/` 托管 Claude 运行时 hooks
- `agent-configs/` 托管 Claude / Codex / workspace 模板
- `vault-template/` 提供共享记忆仓库初始化骨架
- `install.ps1` / `uninstall.ps1` / `tests/verify-installation.ps1` 完成安装、验证与回滚闭环

## Prerequisites

- Windows PowerShell
- 可用的 `node`
- 已存在或准备创建的工作区根目录
- Claude / Codex 宿主目录默认位于 `%USERPROFILE%\\.claude` 与 `%USERPROFILE%\\.codex`

## Repository Layout

- `skills/`: Claude / Codex 共用 skills 单源
- `scripts/`: 共享记忆维护/体检脚本入口
- `runtime-hooks/claude/`: Claude hooks 源文件，安装时渲染到宿主目录
- `vault-template/`: `.assistant` 初始化/补齐模板
- `agent-configs/`: Claude / Codex / workspace 模板
- `tests/verify-installation.ps1`: 安装后静态验证

## Install

```powershell
Set-Location <repo-root>
.\install.ps1 -WorkspaceRoot <workspace-root>
```

安装脚本会：

- 初始化或补齐 `<workspace-root>\.assistant`
- 渲染并写入：
  - `%USERPROFILE%\.claude\CLAUDE.md`
  - `%USERPROFILE%\.codex\AGENTS.md`
  - `<workspace-root>\AGENTS.md`
  - `<workspace-root>\GEMINI.md`
- 渲染并部署 Claude hooks 到 `%USERPROFILE%\.claude\hooks-memory`
- 合并生成 Claude / Codex 的 `settings.local.json`
- 以 managed block 更新 `%USERPROFILE%\.codex\config.toml`，只托管 Harness 自己的 `[[skills.config]]` 条目
- 保留 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills` 根目录为普通目录，并将 repo `skills/` 下的 managed 条目逐项链接进去
- 保留宿主 `skills/` 下的隐藏 sidecar 目录，例如 `.assistant`、`.claude`、`.qoder`
- 将现有 Claude / Codex `.system` 内容合并到 repo-local `skills/.system`
- 写入 install manifest 到 `backups/install-*/install-manifest.json`

## Verify

```powershell
Set-Location <repo-root>
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

当前验证覆盖：

- `skills` 根目录保持为普通目录
- repo `skills/` 下的 managed 条目逐项链接状态
- sidecar 兼容所需的 `.system` 可见性
- Claude hooks 渲染
- Claude / Codex `settings.local.json` 结构
- Codex `config.toml` managed block 内容与 Harness 托管 skill path 泄漏检查
- 热切换保留的 `skills/docs` 内容漂移检查
- `agent-configs/codex/*.toml` forbidden prefix 检查
- `scripts/memory-health.ps1 -VaultRoot <workspace>\\.assistant` 返回 `STATUS: PASS`

## Uninstall

```powershell
Set-Location <repo-root>
.\uninstall.ps1
```

默认行为：

- 读取 `backups/active-install.json`
- 恢复安装前存在的 skill 条目、宿主配置和 settings/config 文件
- 删除安装生成但安装前不存在的宿主文件
- 删除 repo-local 生成的 `skills/.system`
- 恢复安装前已存在的 skill Junction，而不是把它们平铺成普通目录

保守边界：

- 不清理 `<workspace-root>\.assistant\运行时\*`
- 不删除工作区 `.assistant` 本身
- 不清理用户后续新增的未纳入 manifest 的本地文件

## Shared vs Local

进入 Git：

- `skills/`
- `runtime-hooks/claude/`
- `agent-configs/`
- `vault-template/`
- `skills/docs/*` 下的 canonical docs

不进入 Git：

- 真实密钥
- 用户私有 overlay
- 真实运行时任务状态
- 本机生成的 `skills/.system/`
- `backups/`

## Current Caveats

- 首轮只支持 Windows
- `settings.local.json` 合并阶段依赖 `node`
- `vault-template/` 当前采用“缺失即补齐、存在则保留”的保守策略，不主动刷新已存在文档
- 为避免 live session 自己锁住 `skills/docs`，若宿主上已存在 `skills/docs` 普通目录，安装阶段会保留它而不是强制替换为 Junction；若其内容已与 repo 漂移，`tests/verify-installation.ps1` 会返回 `WARN`
- 历史设计文档目录仍保留部分源机器绝对路径，当前不阻塞安装链路
