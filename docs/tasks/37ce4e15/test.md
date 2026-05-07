---
task_id: 37ce4e15
stage: TEST
tool: codex
updated: 2026-05-07
---

# Codex CA / Trust-Store Workaround Candidate Test

## Summary

- 本轮实现了最小 CA / trust-store workaround：
  - wrapper 在工作区内生成 PEM CA bundle
  - 启动 Codex 前设置 `CODEX_CA_CERTIFICATE=<workspace>\.tmp\codex-home\ca\current-user-root.pem`
- 针对 `c559c2e3` 的 High finding，本轮只收窄修了 preflight：
  - `codex --version` 不再通过 PowerShell `2>&1` 捕获
  - 改为显式进程调用，保留 stderr warning，但不把非阻塞 warning 误判成 `preflight_failed`
- 该 candidate 与上一轮 writable state redirect 叠加后，默认沙箱下 A1 已转为 PASS。
- `powershell` 路径下，之前由 `failed to clean up stale arg0 temp dirs` 触发的 preflight 误判已消失。
- `pwsh` 路径仍然保持 PASS，没有被本轮 preflight 修复带回归。
- 本轮未再出现：
  - `no native root CA certificates found`
  - `failed to open current user certificate store`
- 两条 wrapper A1 复测都成功执行 `echo hello`，并返回 `session_id` / `output_path`。

## Scope

- 仅验证 wrapper / 启动层 trust-store workaround。
- 不修改 `install.ps1`、profile、validator。
- 不扩展到其他主线。

## Changes Under Test

- 文件：`skills/codex/scripts/ask_codex.ps1`
- 本轮新增能力：
  - 在工作区内 `codex-home\ca` 目录生成 `current-user-root.pem`
  - 使用 `Cert:\CurrentUser\Root` 导出标准 PEM `CERTIFICATE` blocks
  - 在启动 Codex 前设置 `CODEX_CA_CERTIFICATE`
- 本轮 preflight 收口：
  - `Test-CodexRunnable` 改为显式进程执行 `codex --version`
  - Windows PowerShell 5.1 下，stderr warning 只作为 warning 输出，不再进入 `preflight_failed`
- 上一轮 candidate 保持不变：
  - `CODEX_HOME`
  - `TMP`
  - `TEMP`
  - `--ignore-user-config`

## Inputs Reviewed

- `docs/tasks/f5092ff5/analysis.md`
- `docs/tasks/1cfa7b79/test.md`
- `D:\workApp\nodejs\node_modules\@openai\codex\bin\codex.js`
- `D:\workApp\nodejs\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe`

## Verification

### 1. Binary capability evidence

本机 `codex.exe` 二进制字符串可见：

- `CODEX_CA_CERTIFICATE`
- `SSL_CERT_FILE`
- `loaded certificates from custom CA bundle`
- `using system root certificates because no CA override environment variable was selected`

这说明 CLI 本体支持 trust-store override，入口存在于启动层边界内。

### 2. 手工 probe：默认沙箱下 direct `codex exec`

做法：

- 在工作区内生成 PEM bundle：`.tmp\37ce4e15-ca-bundle.pem`
- 在工作区内建立 isolated `CODEX_HOME`
- 设置：
  - `CODEX_HOME`
  - `TMP`
  - `TEMP`
  - `CODEX_CA_CERTIFICATE`
- 运行：

```pwsh
'echo hello' | codex exec --ignore-user-config --cd D:\data\claude-dev-harness --skip-git-repo-check --json
```

结果：

- 默认沙箱下直接返回成功事件流
- `command_execution` 成功执行 `echo hello`
- `agent_message` 返回 `hello`
- 未再出现证书库相关报错

结论：

- 只靠启动层提供 CA bundle，就足以绕过默认沙箱下对 Windows CurrentUser 证书库的依赖。

### 3. Wrapper A1：Windows PowerShell 路径复测

命令：

```pwsh
powershell -ExecutionPolicy Bypass -File skills/codex/scripts/ask_codex.ps1 -Task "echo hello" -ReadOnly -Output .tmp\37ce4e15-powershell-output.md
```

控制台关键结果：

- preflight 输出：
  - `codex warnings: WARNING: failed to clean up stale arg0 temp dirs: 拒绝访问。 (os error 5)`
  - `codex-cli 0.125.0`
- 未再出现：
  - `{"status":"preflight_failed",...}`
- Codex 正常进入任务执行：
  - `> "...pwsh.exe" -Command 'echo hello'`
  - `hello`
- 最终返回：
  - `session_id=019e00fb-d087-72d0-8412-5b4549f7d3e6`
  - `output_path=.tmp\37ce4e15-powershell-output.md`

未观察到：

- `no native root CA certificates found`
- `failed to open current user certificate store`

输出文件内容：

- `.tmp\37ce4e15-powershell-output.md` 包含 shell 片段与 `hello`
- 不是 `(no response from codex)`

工作区内状态证据：

- CA bundle:
  - `D:\data\claude-dev-harness\.tmp\codex-home\ca\current-user-root.pem`
- 新 session rollout:
  - `D:\data\claude-dev-harness\.tmp\codex-home\sessions\2026\05\07\rollout-2026-05-07T05-49-15-019e00fb-d087-72d0-8412-5b4549f7d3e6.jsonl`

结论：

- `powershell` 路径下，High finding 已被修掉；warning 仍可见，但不再导致 preflight 误判失败。

### 4. Wrapper A1：`pwsh` 路径回归复测

命令：

```pwsh
pwsh -NoProfile -File skills/codex/scripts/ask_codex.ps1 -Task "echo hello" -ReadOnly -Output .tmp\37ce4e15-pwsh-output.md
```

控制台关键结果：

- preflight 输出：
  - `codex warnings: WARNING: failed to clean up stale arg0 temp dirs: 拒绝访问。 (os error 5)`
  - `codex-cli 0.125.0`
- Codex 正常进入任务执行：
  - `> "...pwsh.exe" -Command 'echo hello'`
  - `hello`
- 最终返回：
  - `session_id=019e00fc-57cb-7e73-839a-47061a13a521`
  - `output_path=.tmp\37ce4e15-pwsh-output.md`

输出文件内容：

- `.tmp\37ce4e15-pwsh-output.md` 包含 shell 片段与 `hello`
- 不是 `(no response from codex)`

结论：

- `pwsh` 路径仍然 PASS，本轮 preflight 修复没有引入回归。

## Residual Noise

两条 wrapper A1 复测仍观察到相同的非阻塞日志：

- `failed to clean up stale arg0 temp dirs: 拒绝访问。 (os error 5)`
- `failed to refresh available models`
- `wham/apps` 请求失败
- `failed to record rollout items: thread ... not found`

这些日志没有阻止：

- `codex exec` 建连
- agent turn 完成
- shell command 执行
- A1 输出文件生成

因此本轮不把它们作为 PASS blocker。

## Verdict

### Trust-store workaround

pass

### Default sandbox A1 (`powershell`)

pass

### Default sandbox A1 (`pwsh`)

pass

## Recommendation

- 当前 candidate 值得保留：它在 wrapper / 启动层内就解除了默认沙箱下的证书库阻塞，并且已经补齐 Windows PowerShell 5.1 的 preflight 兼容性。
- 若后续要继续收窄剩余噪声，可单独分析：
  - `arg0 temp dirs` 非阻塞警告
  - `models` / `wham/apps` 非阻塞刷新错误
  - `failed to record rollout items` 日志
- 这些不应阻塞本轮 candidate 的结论。
