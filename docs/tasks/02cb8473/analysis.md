---
task_id: 02cb8473
stage: ANALYSIS
tool: codex
updated: 2026-05-07
---

# 默认沙箱下 Codex CLI 残留失败分析

## TL;DR

- `failed to clean up stale arg0 temp dirs: 拒绝访问。 (os error 5)` 是最早可见症状，但不是唯一失败点。
- 在默认 `workspace-write` 沙箱里，Codex CLI 会尝试写入/清理 `C:\Users\28796\.codex\...` 下的 `tmp\arg0`、`skills`、`sessions`。
- 这些路径都在工作区外；当前 harness 沙箱允许读取，但不允许在工作区外写入，所以 CLI 在 `codex --version` 阶段先告警，在 `codex exec` 阶段进一步因为无法创建 system skills / session 文件而硬失败。
- 这不是 `jq` 修复线的同一根因。`jq` 是 wrapper 的 preflight 依赖问题；本问题是 Codex CLI 与默认沙箱环境边界的权限冲突。

## 1. 复现入口和最小证据

### 入口 A：直接跑 Codex CLI

命令：

```pwsh
codex --version
```

默认沙箱下观测结果：

- 命令仍返回版本：`codex-cli 0.125.0`
- 同时输出两条关键告警：
  - `failed to clean up stale arg0 temp dirs: 拒绝访问。 (os error 5)`
  - `failed to update PATH ... at path "C:\Users\28796\.codex\tmp\arg0\codex-arg0..."`

结论：

- `codex --version` 本身可以启动；
- 但它在启动时就会尝试清理 / 写入 `C:\Users\28796\.codex\tmp\arg0\...`，而默认沙箱拦住了这类工作区外写操作。

### 入口 B：当前 wrapper A1（`ask_codex.ps1 -ReadOnly`）

命令：

```pwsh
skills/codex/scripts/ask_codex.ps1 -Task "echo hello" -ReadOnly
```

默认沙箱下观测结果：

- preflight 先打印 `codex --version` 的同一批 `arg0 temp dirs` / `PATH` 告警；
- 进入 `codex exec` 后继续报：
  - `failed to install system skills: io error while create system skills dir: 拒绝访问。 (os error 5)`
  - `Failed to create session: 拒绝访问。 (os error 5)`
  - `Codex cannot access session files at C:\Users\28796\.codex\sessions (permission denied)`
- wrapper 最终只是在 CLI exit code = 1 后返回 `[ERROR] Codex exited with code 1`。

最小证据链说明：

- `arg0 temp dirs` 告警不是孤立事件；
- 同一轮运行里，Codex 对 `.codex\skills` 和 `.codex\sessions` 的写入也被拦截；
- 所以这是一个统一的“工作区外写权限被拒绝”问题。

## 2. 失败是在 Codex CLI、本体 wrapper，还是环境/权限层

### wrapper 不是根因

`skills/codex/scripts/ask_codex.ps1` 的关键调用链很薄：

- `ask_codex.ps1:94-113` 定义 `Test-CodexRunnable`
- `ask_codex.ps1:96` 直接执行 `codex --version`
- `ask_codex.ps1:166` 调用 `Test-CodexRunnable`
- `ask_codex.ps1:223-227` 组装并启动 `codex exec`

因此 wrapper 的职责只是：

1. 调一次 `codex --version` 做可运行性预检
2. 再启动一次 `codex exec`

而实际报错来自 Codex CLI 内部模块：

- `codex_core_skills::manager`
- `codex_core::session`

这说明 wrapper 只是把 CLI 错误透传出来，不是根因本身。

### 也不是静态 Windows ACL 配错

只读检查显示：

- `whoami` 仍是 `jiabin\28796`
- `C:\Users\28796\.codex`、`C:\Users\28796\.codex\sessions`、`C:\Users\28796\.codex\skills` 的 owner 也是 `JIABIN\28796`
- ACL 中 `jiabin\28796` 持有 `FullControl`

所以从宿主机文件所有权看，不像是“这个用户本来就没权限”。

### 根因定位：环境 / 沙箱权限层

当前任务运行在 harness 的默认 `workspace-write` 沙箱中。该沙箱允许：

- 读取工作区外路径
- 但只允许向工作区 / writable roots 写入

Codex CLI 启动时默认会写用户态目录：

- `C:\Users\28796\.codex\tmp\arg0\...`
- `C:\Users\28796\.codex\skills`
- `C:\Users\28796\.codex\sessions`

这些都在工作区外，所以被默认沙箱拒绝，形成：

1. `codex --version` 阶段的 `arg0` 清理 / PATH 更新告警
2. `codex exec` 阶段的 system skills / session 创建硬失败

结论：

- 错误表面出现在 Codex CLI 启动路径里
- 真正根因在环境 / 权限层（默认 `workspace-write` 沙箱）
- wrapper 不是根因

## 3. 与 `jq` 修复线的关系

二者不是同一根因。

### `jq` 线

- 老问题出在 wrapper preflight：`Test-Command 'jq'`
- 即使 Codex CLI 本身可运行，只要机器没装 `jq`，旧脚本也会直接失败
- 该问题已在 `skills/codex/scripts/ask_codex.ps1` 中移除

### 当前默认沙箱失败线

- 当前问题即使在 `jq` 已移除的脚本上依然复现
- 直接跑 `codex --version` 也能看到同类 `arg0 temp dirs` / PATH 告警
- 说明失败源头不是 wrapper 的 `jq` 预检，而是 Codex CLI 对工作区外用户目录的写入被沙箱拦截

因此：

- `jq` 修复已完整解决它自己的根因
- 默认沙箱失败是独立后续问题
- 不应把它回滚或归咎到 `jq` 修复线

## 4. 最窄的下一步建议

### 建议结论

`workaround now + separate fix candidate later`

### 立即建议

- `continue` 当前任务线，但把“默认沙箱下直接跑 Codex”视为已知环境限制
- 需要继续 smoke / Codex 工作时，沿用已验证可行的提权路径
- 不要回头修改 install / profile / validator，因为这条问题不在它们的边界里

### 若必须支持“默认沙箱直跑 Codex”

单开一个专门 fix candidate，范围只围绕“给 Codex CLI 一个沙箱内可写的状态目录”：

1. 启动 Codex 时显式重定向其 writable state（至少 `tmp\arg0`、`skills`、`sessions`）到工作区内或已批准 writable root
2. 如果 CLI 支持独立环境变量 / config 覆盖，则仅在 harness 启动层传入，不改 install/profile/validator
3. 只有在前两项都不可行时，才评估是否需要扩大 writable roots；这已经超出本只读分析范围

### 不建议

- 不建议把该问题归入 `jq` 任务继续修
- 不建议先改 install / profile / validator 试错
- 不建议在未确认 Codex state 重定向能力前直接扩散到更大设计线

## 结论

`failed to clean up stale arg0 temp dirs` 不是一个孤立 CLI bug；它是默认 `workspace-write` 沙箱阻止 Codex 写入 `C:\Users\28796\.codex\...` 的第一个可见信号。真正的致命点出现在同一条链路后续的 `skills` / `sessions` 写入失败。该问题与 `jq` 修复无关，应作为独立的默认沙箱兼容性问题处理。
