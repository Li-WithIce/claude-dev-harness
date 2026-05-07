---
task_id: 1cfa7b79
stage: PLAN
tool: codex
updated: 2026-05-07
---

# Codex Writable State Redirect Fix Candidate

## Clarification

- 目标只锁定默认 `workspace-write` 沙箱下的 Codex writable state 重定向。
- 只允许修改 wrapper / 启动层；不动 `install.ps1`、profile、validator。
- 本轮只验证一个最小候选：
  - 在 `skills/codex/scripts/ask_codex.ps1` 启动 Codex 前，为 CLI 提供工作区内可写的 `CODEX_HOME`
  - 同时把 `TMP` / `TEMP` 指到该工作区内状态目录
  - 避免再写 `C:\Users\28796\.codex\{tmp\arg0,skills,sessions}`
- 如果验证过程中暴露出与 writable state 无关的新阻塞，只记录到 `test.md`，不继续扩 scope。

## Candidate

### 启动层策略

1. 先验证 `-Workspace`，因为重定向目标需要落在工作区内。
2. 在工作区下建立一个临时 Codex state root，例如：
   - `<workspace>\.tmp\codex-home`
3. 从用户真实 home 只同步最小只读输入：
   - `auth.json`
   - `AGENTS.md`
4. 启动 Codex 前为当前进程 / 子进程设置：
   - `CODEX_HOME=<workspace>\.tmp\codex-home`
   - `TMP=<workspace>\.tmp\codex-home\tmp`
   - `TEMP=<workspace>\.tmp\codex-home\tmp`
5. 在 `codex exec` 调用上增加 `--ignore-user-config`，避免重新加载 `C:\Users\28796\.codex\config.toml` 中可能指回旧 home 的路径。

### 为什么先选这个候选

- `codex exec --help` 已明确支持：
  - `$CODEX_HOME/config.toml`
  - `--ignore-user-config`
- 手工 probe 已证明：
  - 仅设置工作区内 `CODEX_HOME` 后，`codex --version` 不再报旧 home 下的 `arg0` 拒绝访问
  - `skills` / `sessions` 会实际创建在工作区内的 probe home
- 因此这是当前边界内最小、最直接、可验证的 candidate。

## Verification

### A1 smoke

命令：

```pwsh
skills/codex/scripts/ask_codex.ps1 -Task "echo hello" -ReadOnly
```

### 通过判据

至少要同时满足：

1. 控制台里不再出现：
   - `C:\Users\28796\.codex\tmp\arg0`
   - `C:\Users\28796\.codex\skills`
   - `C:\Users\28796\.codex\sessions`
   对应的 permission denied / access denied
2. 工作区内临时 state root 下可以观察到：
   - `tmp\arg0`
   - `skills\.system`
   - `sessions\...`
3. 若 A1 最终仍失败，新的失败根因必须与 writable state 重定向无关，才能判定 candidate 已缩小问题面。

### 失败即停条件

- 需要修改 `install.ps1` / profile / validator 才能继续
- 需要改 Codex CLI 本体而不是 wrapper / 启动层
- 需要引入第二条设计线（例如证书、网络、系统信任库修复）才能继续验证 writable state

## Deliverables

- `docs/tasks/1cfa7b79/plan.md`
- `docs/tasks/1cfa7b79/test.md`
- 最小代码候选仅限 `skills/codex/scripts/ask_codex.ps1`
