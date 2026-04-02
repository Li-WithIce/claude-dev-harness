# Claude Dev Harness

Windows 优先的单仓库 Harness 分发仓库。

## 这是什么

这个仓库不是业务应用，也不是单个 skill。它的职责是把一套可运行的 Claude / Codex 开发 Harness 收敛成一个可安装、可验证、可回滚的分发仓库。

安装完成后，它会把以下能力接到宿主环境上：

- `skills/` 作为 Claude / Codex 共用单源
- `runtime-hooks/claude/` 托管 Claude 运行时 hooks
- `agent-configs/` 托管 Claude / Codex / workspace 模板
- `vault-template/` 提供共享记忆仓库初始化骨架
- `install.ps1` / `uninstall.ps1` / `tests/verify-installation.ps1` 形成安装、验证、回滚闭环

如果你要解决的是“如何在一台新机器上把整套 Harness 装起来，并让 Claude / Codex 共用同一份 skills、同一套工作区入口和共享记忆骨架”，这个仓库就是为此准备的。

## 解决什么问题

在改造成这个仓库之前，Harness 依赖的是散落在宿主目录和工作区目录里的资产，例如：

- `%USERPROFILE%\.claude\skills`
- `%USERPROFILE%\.codex\skills`
- `%USERPROFILE%\.claude\hooks-memory`
- `%USERPROFILE%\.claude\CLAUDE.md`
- `%USERPROFILE%\.codex\AGENTS.md`
- `%USERPROFILE%\.codex\config.toml`
- `<workspace-root>\AGENTS.md`
- `<workspace-root>\GEMINI.md`
- `<workspace-root>\.assistant`

这个仓库把它们拆成三层：

| 层 | 进入 Git | 内容 |
|---|---|---|
| shared assets | 是 | `skills/`、canonical docs、共享脚本、验证脚本 |
| host-specific assets | 是 | Claude/Codex/workspace 模板、hooks、Codex managed block |
| user-local runtime | 否 | 真实密钥、用户 overlay、运行时任务状态、宿主本地信任配置 |

核心边界是：

- repo 负责共享资产与宿主模板
- 安装脚本负责把模板渲染到宿主
- 用户本地敏感配置和运行态不进入 Git

## 适合谁用

- 你已经在 Windows 上使用 Claude / Codex，并希望它们共用同一套 skills
- 你希望把 `.assistant` 共享记忆骨架、workspace 入口文件、hooks 一起分发
- 你希望安装结果可以被验证，而不是“能跑就算成功”
- 你希望出问题时能基于 manifest 回滚，而不是手动删目录

不适合的场景：

- 只想单独装某一个 skill
- 只需要 README 级别的使用说明，不需要宿主模板和 hooks
- 非 Windows 环境

## 仓库里有什么

| 路径 | 作用 |
|---|---|
| `skills/` | Claude / Codex 共用 skills 单源 |
| `skills/docs/` | 任务级 canonical docs，属于 repo 证据，不是本地运行态 |
| `scripts/` | 共享记忆维护脚本与辅助同步脚本 |
| `scripts/sync-preserved-docs.ps1` | 把热切换保留的宿主 `skills/docs` 重同步到 repo 当前版本 |
| `runtime-hooks/claude/` | Claude hooks 源文件，安装时渲染到宿主 |
| `agent-configs/` | Claude / Codex / workspace 模板 |
| `vault-template/` | `.assistant` 初始化/补齐模板 |
| `install.ps1` | 安装入口 |
| `uninstall.ps1` | 回滚入口 |
| `tests/verify-installation.ps1` | 安装验证入口 |

## 前置条件

- Windows PowerShell
- 可用的 `node`
- 已存在或准备创建的工作区根目录
- Claude / Codex 宿主目录默认位于 `%USERPROFILE%\.claude` 与 `%USERPROFILE%\.codex`

## 快速开始

### 1. 准备工作区

选一个工作区根目录，例如：

```powershell
<workspace-root>
```

安装后，这里会承载：

- `AGENTS.md`
- `GEMINI.md`
- `.assistant`

### 2. 克隆仓库

```powershell
git clone <your-repo-url> <repo-root>
Set-Location <repo-root>
```

### 3. 按需查看本地 overlay 示例

如果你需要自定义宿主本地配置，先看这些示例文件：

- `agent-configs/claude/settings.local.user.example.json`
- `agent-configs/codex/settings.local.user.example.json`
- `agent-configs/codex/config.user.example.toml`

这些示例只是说明如何扩展本地配置，不应该把真实密钥或私有权限直接提交回仓库。

### 4. 执行安装

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

### 5. 执行验证

```powershell
Set-Location <repo-root>
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

`verify-installation.ps1` 的结论语义：

| 状态 | 含义 | 退出码 |
|---|---|---|
| `PASS` | 安装结果符合预期 | `0` |
| `WARN` | 安装仍可用，但存在需要人工处理的偏差，例如 preserved docs 漂移 | `1` |
| `FAIL` | 关键安装链路不符合预期 | `2` |

当前验证覆盖：

- `skills` 根目录保持为普通目录
- repo `skills/` 下的 managed 条目逐项链接状态
- sidecar 兼容所需的 `.system` 可见性
- Claude hooks 渲染
- Claude / Codex `settings.local.json` 结构
- Codex `config.toml` managed block 内容与 Harness 托管 skill path 泄漏检查
- 热切换保留的 `skills/docs` 内容漂移检查
- `agent-configs/codex/*.toml` forbidden prefix 检查
- `scripts/memory-health.ps1 -VaultRoot <workspace-root>\.assistant` 返回 `STATUS: PASS`

## 日常使用流程

### 场景 1：首次安装

```powershell
Set-Location <repo-root>
.\install.ps1 -WorkspaceRoot <workspace-root>
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

目标结果：`STATUS: PASS`

### 场景 2：仓库更新后重新收敛宿主

当你拉取了新的 repo 变更，并且这些变更涉及 `skills/`、模板、hooks、安装脚本时，直接重新执行：

```powershell
Set-Location <repo-root>
.\install.ps1 -WorkspaceRoot <workspace-root>
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

### 场景 3：只改了 `skills/docs`，宿主 live session 还在运行

为了避免 live session 锁住 `skills/docs`，安装阶段会保留宿主上的 `skills/docs` 普通目录，而不是强制替换成 Junction。  
这意味着 repo 里的 canonical docs 一旦变化，宿主 preserved docs 可能漂移，`verify` 会返回 `WARN`。

此时不要重装，直接同步 docs：

```powershell
Set-Location <repo-root>
.\scripts\sync-preserved-docs.ps1
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>
```

默认会同时同步 `%USERPROFILE%\.claude\skills\docs` 与 `%USERPROFILE%\.codex\skills\docs`。如果只想处理单侧：

```powershell
.\scripts\sync-preserved-docs.ps1 -TargetHost Claude
.\scripts\sync-preserved-docs.ps1 -TargetHost Codex
```

这个脚本会：

- 覆盖已漂移的 docs 文件
- 补齐缺失文件
- 删除 repo 中已不存在的陈旧 docs

### 场景 4：需要回滚

```powershell
Set-Location <repo-root>
.\uninstall.ps1
```

默认会读取 `backups/active-install.json` 指向的 manifest。

如果 install 中途失败，或你要指定某次历史安装的 manifest，可以显式传参：

```powershell
.\uninstall.ps1 -ManifestPath <repo-root>\backups\install-YYYYMMDD-HHMMSS\install-manifest.json
```

## 宿主落点一览

| 仓库资产 | 落点 |
|---|---|
| `skills/` | `%USERPROFILE%\.claude\skills\*` / `%USERPROFILE%\.codex\skills\*` |
| `runtime-hooks/claude/*.js` | `%USERPROFILE%\.claude\hooks-memory\*.js` |
| `agent-configs/claude/CLAUDE.md.template` | `%USERPROFILE%\.claude\CLAUDE.md` |
| `agent-configs/codex/AGENTS.md.template` | `%USERPROFILE%\.codex\AGENTS.md` |
| `agent-configs/codex/config.shared.toml.template` | `%USERPROFILE%\.codex\config.toml` 的 managed block |
| `agent-configs/workspace/AGENTS.md.template` | `<workspace-root>\AGENTS.md` |
| `agent-configs/workspace/GEMINI.md.template` | `<workspace-root>\GEMINI.md` |
| `vault-template/` | `<workspace-root>\.assistant` |

## 什么会进 Git，什么不会

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

## 常见问题

### `verify-installation.ps1` 返回 `WARN`

先看告警内容：

- 如果是 `skills/docs` 漂移或存在陈旧文件，运行 `.\scripts\sync-preserved-docs.ps1`
- 如果是宿主配置或 managed block 漂移，重新执行 `.\install.ps1 -WorkspaceRoot <workspace-root>`

### 为什么 `skills/docs` 不是 Junction

这是当前有意保守的热切换策略。为了避免 live session 锁冲突，若宿主上已经存在普通目录形式的 `skills/docs`，安装不会强制把它改回 Junction。

### `uninstall.ps1` 会不会删掉我的运行时数据

不会。当前策略明确不清理：

- `<workspace-root>\.assistant\运行时\*`
- 工作区 `.assistant` 本身
- 未纳入 manifest 的用户后续新增文件

### install 失败后怎么处理

优先看 `backups/install-*/install-manifest.json` 是否已生成。当前安装脚本会尽早写出 recovery manifest snapshot；如果它存在，就可以用：

```powershell
.\uninstall.ps1 -ManifestPath <that-manifest>
```

## 当前限制

- 只支持 Windows
- `settings.local.json` 合并阶段依赖 `node`
- `vault-template/` 当前采用“缺失即补齐、存在则保留”的保守策略，不主动刷新已存在文档
- 为避免 live session 锁住 `skills/docs`，docs-only 变更后的宿主收敛依赖 `.\scripts\sync-preserved-docs.ps1`
- 历史设计文档目录仍保留少量旧时代证据文件；当前不阻塞安装链路

## 推荐命令清单

```powershell
# 安装
.\install.ps1 -WorkspaceRoot <workspace-root>

# 验证
.\tests\verify-installation.ps1 -WorkspaceRoot <workspace-root>

# 同步保留的 docs
.\scripts\sync-preserved-docs.ps1

# 指定只同步 Claude 或 Codex
.\scripts\sync-preserved-docs.ps1 -TargetHost Claude
.\scripts\sync-preserved-docs.ps1 -TargetHost Codex

# 回滚
.\uninstall.ps1

# 指定 manifest 回滚
.\uninstall.ps1 -ManifestPath <manifest-path>
```
