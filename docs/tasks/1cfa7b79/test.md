---
task_id: 1cfa7b79
stage: TEST
tool: codex
updated: 2026-05-07
---

# Codex Writable State Redirect Candidate Test

## Summary

- 本轮已实现最小 candidate：`skills/codex/scripts/ask_codex.ps1` 在启动 Codex 前，把 writable state 重定向到工作区内 `.tmp\codex-home`，并为 `codex exec` 增加 `--ignore-user-config`。
- writable state 重定向本身验证通过：
  - `tmp\arg0`
  - `skills\.system`
  - `sessions\...`
  均在 `D:\data\claude-dev-harness\.tmp\codex-home` 下创建。
- 默认沙箱下 A1 **仍为 FAIL**，但失败根因已从旧的 `.codex\{tmp\arg0,skills,sessions}` 写权限冲突，切换为新的证书/网络层阻塞：
  - `no native root CA certificates found`
  - `failed to open current user certificate store`

## Scope

- 仅验证 wrapper / 启动层最小 candidate。
- 不修改 `install.ps1`、profile、validator。
- 不扩展到证书库、系统信任、网络策略修复。

## Changes Under Test

- 文件：`skills/codex/scripts/ask_codex.ps1`
- 改动点：
  - 先验证 `-Workspace`
  - 建立工作区内 `.tmp\codex-home`
  - 同步最小只读输入：`auth.json`、`AGENTS.md`
  - 设置：
    - `CODEX_HOME=<workspace>\.tmp\codex-home`
    - `TMP=<workspace>\.tmp\codex-home\tmp`
    - `TEMP=<workspace>\.tmp\codex-home\tmp`
  - `codex exec` / `codex exec resume` 增加 `--ignore-user-config`

## Verification

### 1. 手工 probe：只验证 `CODEX_HOME` 是否生效

做法：

- 在工作区内创建 `D:\data\claude-dev-harness\.tmp\1cfa7b79-codex-home`
- 仅复制 `auth.json`、`AGENTS.md`
- 设置 `CODEX_HOME/TMP/TEMP`
- 运行：

```pwsh
codex --version
```

结果：

- 直接返回 `codex-cli 0.125.0`
- 不再出现指向 `C:\Users\28796\.codex\tmp\arg0\...` 的 access denied / PATH 更新告警

结论：

- `CODEX_HOME` 重定向本身有效。

### 2. 手工 probe：`codex exec --ignore-user-config`

做法：

```pwsh
'echo hello' | codex exec --ignore-user-config --cd D:\data\claude-dev-harness --skip-git-repo-check --json
```

结果：

- 旧的 `C:\Users\28796\.codex\skills` / `sessions` permission denied 消失
- 工作区内 probe home 实际生成：
  - `skills\.system\...`
  - `sessions\2026\05\07\rollout-...`
  - `tmp\arg0\codex-arg0...`
- 新失败切换为：
  - `no native root CA certificates found`
  - `failed to open current user certificate store`
  - 随后 websocket / responses 请求失败

结论：

- writable state 重定向成功把问题面从 home 写权限冲突，推进到新的证书/网络层阻塞。

### 3. Wrapper A1：默认沙箱复测

命令：

```pwsh
skills/codex/scripts/ask_codex.ps1 -Task "echo hello" -ReadOnly
```

控制台关键结果：

- preflight 成功输出：`codex-cli 0.125.0`
- 不再出现：
  - `failed to install system skills: ... C:\Users\28796\.codex\skills`
  - `Codex cannot access session files at C:\Users\28796\.codex\sessions`
- 新失败为：
  - `failed to connect to websocket: IO error: no native root CA certificates found`
  - `failed to open current user certificate store`
- wrapper 输出文件：`.tmp\1cfa7b79-wrapper-output.md`
  - 内容为：`(no response from codex)`

工作区内新 state 证据：

- `D:\data\claude-dev-harness\.tmp\codex-home\tmp\arg0\codex-arg0...`
- `D:\data\claude-dev-harness\.tmp\codex-home\skills\.system\...`
- `D:\data\claude-dev-harness\.tmp\codex-home\sessions\2026\05\07\rollout-...`

旧 home 对照：

- `C:\Users\28796\.codex\skills` 未出现新的 permission denied
- `C:\Users\28796\.codex\sessions` 未再次成为 fatal 错误点
- `C:\Users\28796\.codex\tmp\arg0` 的时间戳未随 wrapper A1 复测前进到本轮运行时刻，说明本轮新建的 `arg0` 目录落在工作区内 `codex-home`

## Verdict

### Writable state redirect

pass

### Default sandbox A1

fail

## Blocker

- 当前 A1 不再被 `.codex\{tmp\arg0,skills,sessions}` 写权限拦住，但仍被新的环境权限问题阻塞：
  - Codex CLI 在默认沙箱下无法访问当前用户证书库
  - 进而无法建立到 `wss://chatgpt.com/backend-api/codex/responses` 的 TLS/websocket 连接
- 这已经超出“writable state 重定向”边界；若继续处理，需要单开证书/信任库方向任务。

## Recommendation

- 本 candidate 可以保留，因为它已经独立解决了 writable state 这一层。
- 后续若要让默认沙箱 A1 真正 PASS，应单独调查：
  - 是否能在启动层为 Codex 提供沙箱内可读的 CA bundle
  - 或是否必须调整默认沙箱对 Windows 当前用户证书库的访问
