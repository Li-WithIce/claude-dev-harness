---
task_id: 37ce4e15
stage: PLAN
tool: codex
updated: 2026-05-07
---

# Codex CA / Trust-Store Workaround Candidate

## Clarification

- 目标只锁定默认 `workspace-write` 沙箱下的 CA / trust-store workaround。
- 只允许修改 wrapper / 启动层；不动 `install.ps1`、profile、validator。
- 该 candidate 建立在现有 writable state redirect 之上；本轮不回退、不提交前一轮 candidate。
- 本轮只验证一个最小方案：
  - 在 wrapper 启动 Codex 前，生成工作区内可读的 PEM CA bundle
  - 通过 CLI 已识别的 CA 覆盖环境变量，把 Codex 的 TLS 根证书来源切到该 bundle
  - 让 Codex 不再依赖默认沙箱中无法访问的 Windows CurrentUser 证书库

## Evidence That The Entry Point Exists

- 本机 `codex.exe` 二进制字符串已暴露：
  - `CODEX_CA_CERTIFICATE`
  - `SSL_CERT_FILE`
  - `loaded certificates from custom CA bundle`
  - `using system root certificates because no CA override environment variable was selected`
- 手工 probe 已验证：
  - 生成工作区内 PEM bundle
  - 设置 `CODEX_CA_CERTIFICATE=<bundle>`
  - 再运行 `codex exec --ignore-user-config ...`
  - 默认沙箱下可成功返回 `hello`

## Candidate

### 启动层策略

1. 复用现有工作区内 runtime home，例如：
   - `<workspace>\.tmp\codex-home`
2. 在该目录下生成 PEM bundle，例如：
   - `<workspace>\.tmp\codex-home\ca\current-user-root.pem`
3. PEM 内容来自 wrapper 进程可访问的证书源，优先使用：
   - `Cert:\CurrentUser\Root`
4. 在启动 Codex 前设置：
   - `CODEX_CA_CERTIFICATE=<bundle path>`
   - 可选同步 `SSL_CERT_FILE=<bundle path>` 作为兼容兜底
5. 保持上一轮 candidate 的 state redirect 不变：
   - `CODEX_HOME`
   - `TMP`
   - `TEMP`
   - `--ignore-user-config`

### 为什么这是最小 candidate

- 不改 Codex CLI 本体
- 不改 install / profile / validator
- 不需要改变默认沙箱策略
- 只是在 wrapper 里额外准备一个沙箱内可读的 trust-store 文件，并通过已存在的 CLI 入口传入

## Verification

### A1 smoke

命令：

```pwsh
skills/codex/scripts/ask_codex.ps1 -Task "echo hello" -ReadOnly
```

### 通过判据

至少满足：

1. 不再出现：
   - `no native root CA certificates found`
   - `failed to open current user certificate store`
2. wrapper 退出码为 0
3. 输出文件非空，且能反映 `echo hello` 正常执行

### 失败即停条件

- 需要修改 install / profile / validator 才能继续
- 需要改 Codex CLI 本体
- 需要引入独立证书部署/系统配置主线

## Deliverables

- `docs/tasks/37ce4e15/plan.md`
- `docs/tasks/37ce4e15/test.md`
- 最小代码候选仅限 `skills/codex/scripts/ask_codex.ps1`
