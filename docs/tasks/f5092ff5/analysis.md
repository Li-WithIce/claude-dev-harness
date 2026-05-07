---
task_id: f5092ff5
stage: ANALYSIS
tool: codex
updated: 2026-05-07
---

# 默认沙箱下 Codex 证书 / 信任库 blocker 分析

## TL;DR

- `no native root CA certificates found` / `failed to open current user certificate store` 是在 writable state 重定向之后新暴露出来的下一层 blocker。
- 它不是 `jq` 线问题，也不是 `.codex\{tmp\arg0,skills,sessions}` 写权限问题的同一根因。
- 证据显示：
  - 本机当前用户证书库本身存在，当前 PowerShell 能正常读取；
  - 同一条 `codex exec` 在默认沙箱下失败，在提权运行下成功；
  - 因此根因最接近“Codex CLI 需要从 Windows 当前用户证书库读取 native root CA，但该访问在默认沙箱里被拒绝”的交互问题。
- 最窄建议是：`pause` 当前 candidate 的继续扩展，把它作为独立证书/信任库 fix candidate 另开；短期 workaround 仍是提权运行。

## 1. 最小复现与日志证据

### 复现前提

- 使用已经验证过的 writable state 重定向方式，把 `CODEX_HOME`、`TMP`、`TEMP` 指到工作区内目录；
- 使用 `--ignore-user-config`，避免回退到用户 home 下的旧 state 路径。

### 最小复现命令

```pwsh
'echo hello' | codex exec --ignore-user-config --cd D:\data\claude-dev-harness --skip-git-repo-check --json
```

### 默认沙箱下的直接日志证据

同一条命令在默认沙箱下会出现：

- `Reconnecting... 2/5 (stream disconnected before completion: no native root CA certificates found ...)`
- `failed to open current user certificate store`
- `failed to connect to websocket: IO error: no native root CA certificates found ...`
- 最终 `turn.failed`

更完整的 CLI stderr 还包含：

- `codex_api::endpoint::responses_websocket: failed to connect to websocket`
- `error sending request for url (https://chatgpt.com/backend-api/codex/responses)`

### 同一条命令的提权对照

完全相同的 `codex exec` 命令，在沙箱外提权运行时成功：

- agent message 正常返回
- command execution 成功执行 `echo hello`
- 最终 `turn.completed`

这说明：

- CLI 本身不是“完全不能工作”
- 登录态 / 网络终点不是根本问题
- 问题只在默认沙箱路径上出现

### 证书库存在性的本机对照

当前 PowerShell 进程可直接读取：

```pwsh
Get-ChildItem Cert:\CurrentUser\Root | Select-Object -First 5 Subject,Thumbprint
```

结果正常返回多条证书，例如：

- `DigiCert Global Root G2`
- `GlobalSign Root CA - R3`
- `Microsoft Root Certificate Authority`

这说明：

- Windows 当前用户证书库并不是空的
- 宿主机也不是“没有 root CA”

## 2. 失败是在 Codex CLI、本机证书存储、沙箱/权限层，还是三者交互

## 结论先行

最准确的归因是：

`Codex CLI + Windows 当前用户证书存储 + 默认沙箱/权限层` 的交互问题，
其中**主导阻塞在默认沙箱/权限层**。

### 为什么不是“本机证书存储坏了”

- 当前 shell 能正常枚举 `Cert:\CurrentUser\Root`
- 提权运行的 `codex exec` 也能正常完成请求

如果本机证书存储本身损坏，提权运行通常也会失败，而不是只在默认沙箱里失败。

### 为什么不是“Codex CLI 本体坏了”

- 同一版本 `codex-cli 0.125.0` 在提权环境下能完成：
  - websocket 建连
  - agent turn
  - shell command execution

这说明 CLI 本体具备正常工作能力。

### 为什么不是“wrapper 逻辑问题”

- 最小复现直接用的是 `codex exec --ignore-user-config ...`
- 不依赖 `ask_codex.ps1` 的额外逻辑

所以 wrapper 不是这条 blocker 的根因。

### 最接近的根因

Codex CLI 在建立到 `wss://chatgpt.com/backend-api/codex/responses` 的 TLS/websocket 连接前，需要读取 native root CA。当前日志明确指出：

- `no native root CA certificates found`
- 原因链为 `failed to open current user certificate store`
- 底层错误为 `PermissionDenied (os error 5)`

结合“当前 shell 能读证书库、提权 codex exec 能成功”的对照，最合理的解释是：

- 默认沙箱并没有完全阻止 PowerShell 读取证书存储；
- 但 Codex CLI 进程在当前沙箱/令牌条件下，访问 Windows 当前用户证书库时被拒绝；
- 因此 TLS 根证书发现失败，随后 websocket / HTTPS 请求一起失败。

## 3. 与 state redirect candidate 的关系

这是 state redirect candidate 之后**新暴露的下一层 blocker**。

### 已被 state redirect 解决的层

`docs/tasks/1cfa7b79/test.md` 已证明：

- `.codex\tmp\arg0`
- `.codex\skills`
- `.codex\sessions`

这些旧路径的 permission denied 已不再是 fatal 错误点，工作区内 `.tmp\codex-home\{tmp\arg0,skills,sessions}` 也已成功接管 writable state。

### 当前新暴露的层

当 writable state 不再阻塞后，Codex CLI 继续往下执行到网络/TLS 初始化阶段，才暴露出：

- 当前用户证书库访问被拒绝
- native root CA 发现失败
- websocket / responses 请求失败

因此：

- 这不是 state redirect candidate 失败
- 反而说明 state redirect candidate 已经把第一层问题挪开了
- 当前 blocker 是下一层、独立的新问题

## 4. 最窄的下一步建议

## 推荐结论

`pause current candidate expansion + open separate fix candidate`

### 立即建议

- `pause`：不要在 `1cfa7b79` 上继续叠更多改动
- `continue`：保留当前 state redirect candidate 作为有效中间结果，但不提交本轮
- 短期运行 workaround 仍然是：
  - 提权运行 Codex

### 单独的新 fix candidate 应只聚焦

围绕“默认沙箱下，Codex 如何获得可用的 root CA / 证书链访问”做单独验证，优先级建议：

1. 验证 Codex CLI 是否支持显式 CA bundle 环境变量或参数覆盖
2. 若支持，尝试只在 wrapper / 启动层为 Codex 提供沙箱内可读的 CA bundle
3. 若不支持，再评估是否必须调整默认沙箱对 Windows 当前用户证书库的访问

### 不建议

- 不建议回滚 state redirect candidate，把当前 blocker误判成之前的 writable state 问题
- 不建议先改 `install.ps1` / profile / validator
- 不建议把证书问题和 `jq` / writable state 两条线混成一个大修

## 结论

当前 blocker 不是本机“没有证书”，也不是 Codex CLI 普遍失效，而是 Codex CLI 在默认沙箱下访问 Windows 当前用户证书库时遭遇 `PermissionDenied`，导致 native root CA 发现失败，继而无法建立 TLS/websocket 连接。它是 state redirect candidate 之后新暴露的下一层 blocker，应独立处理。
