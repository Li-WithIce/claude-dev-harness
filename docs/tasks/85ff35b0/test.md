# Test Report

## Summary
- 修复前：pre-flight 通过，但 A1 在去除本地沙箱噪声后暴露 `jq` 硬依赖，smoke 停在 A1。
- 修复后：`skills/codex/scripts/ask_codex.ps1` 去掉未使用的 `jq` 强制预检；A1/A2/B1 在隔离 fixture 上复验通过。
- 默认沙箱下 A1 仍会被 Codex CLI 自身的临时目录清理权限问题拦住；这是本轮范围外的残留环境限制，不再是 `jq` 阻塞。

## Scope
- 修复范围锁定在 `skills/codex/scripts/ask_codex.ps1` 的 `jq` 硬依赖。
- 复验按 `docs/tasks/85ff35b0/plan.md` 的固定顺序执行：
  - pre-flight
  - A1: `skills/codex/scripts/ask_codex.ps1 -ReadOnly`
  - A2: `ask_codex.ps1 -Sandbox workspace-write`
  - B1: `scripts/advance-stage.ps1 -Tool codex -Profile harness-default-codex`
- 不修改 install、profile、validator，不扩大到入口 C。

## Inputs Reviewed
- `docs/tasks/85ff35b0/plan.md`
- `skills/codex/scripts/ask_codex.ps1`
- `scripts/advance-stage.ps1`
- `agent-configs/profiles/harness-default-codex.yaml`

## Test Approach
- pre-flight:
  - 检查 `C:\Users\28796\.codex\config.toml` 是否命中 lone-CR 特征：`Get-Content -Raw ... | Format-Hex | Select-String '0D 20'`
- 修复前基线：
  - 默认沙箱先跑 A1，随后提权复跑，以区分本地沙箱噪声与真实 wrapper 阻塞。
- 修复后复验：
  - 在隔离 repo fixture `D:\data\claude-dev-harness\.tmp\85ff35b0-smoke-fixture-2` 上重跑 A1/A2。
  - 在隔离 vault `D:\data\claude-dev-harness\.tmp\85ff35b0-smoke-vault-2` 上跑 B1，避免改动真实运行时指针。
  - A1 先在默认沙箱做一次对照，再提权执行 A1/A2；B1 在工作区内直接执行。
- 修复后产物：
  - A1 console: `docs/tasks/85ff35b0/a1-console-after-fix.txt`
  - A1 output: `docs/tasks/85ff35b0/a1-output-after-fix.md`
  - A2 console: `docs/tasks/85ff35b0/a2-console-after-fix.txt`
  - A2 output: `docs/tasks/85ff35b0/a2-output-after-fix.md`
  - B1 console: `docs/tasks/85ff35b0/b1-console-after-fix.txt`

## Findings
- pre-flight: pass
  - `config.toml` 存在，且未检出计划中 R1 所述 lone-CR 命中。
- 修复前 A1 baseline: fail
  - 默认沙箱先报 `codex --version` 清理临时目录的访问拒绝。
  - 提权复跑后，`codex --version` 正常，但 wrapper 立刻因 `Test-Command 'jq'` 失败，确认为 `jq` 硬依赖问题。
- 本轮修复: pass
  - `skills/codex/scripts/ask_codex.ps1` 中 `jq` 只出现在 preflight；实际 JSON 解析已全部使用 PowerShell `ConvertFrom-Json`。
  - 已移除 `Test-Command 'jq'` 和对应安装提示，保持 `codex` 为唯一外部硬依赖。
- 修复后 A1 default sandbox: fail
  - 现在不再命中 `jq` 分支，而是再次停在 Codex CLI 自身的 `failed to clean up stale arg0 temp dirs: 拒绝访问。 (os error 5)`。
  - 说明 `jq` 阻塞已解除，但默认本地沙箱限制仍在。
- 修复后 A1 escalated rerun: pass
  - `codex --version` 返回 `codex-cli 0.125.0`。
  - 命令 exit code = 0，stdout/输出文件非空，无 `TOML parse error` / `failed to load config`。
  - 控制台出现 `failed to record rollout items: thread ... not found`；A1 输出中还出现一条非致命 `InvalidOperation` 文本，但未影响 `echo hello` 成功返回。
- 修复后 A2 escalated rerun: pass
  - 命令 exit code = 0，无 `permission denied`。
  - fixture 中成功生成 `smoke-write.txt`，内容精确为 `smoke-ok`。
- 修复后 B1: pass
  - `scripts/advance-stage.ps1` 成功解析 `-Tool codex -Profile harness-default-codex`。
  - fixture 内 `phase3-acp-skill-alignment/plan.md` frontmatter 正确写回为 `stage: PLAN_REVIEW`、`tool: codex`、`tool_profile: harness-default-codex`、`model: gpt-5.5/xhigh`。
  - 隔离 vault 成功生成 `运行时/当前任务.md`、`运行时/恢复索引.md`、`运行时/tasks/phase3-acp-skill-alignment.md`。

## Risks / Gaps
- 默认沙箱下的 A1 仍受 Codex CLI 临时目录清理权限问题影响；如果后续要求“非提权也必须通过”，需另开任务处理该环境限制。
- A1/A2 提权复跑时都出现 `failed to record rollout items: thread ... not found` 非阻塞日志；当前不影响 exit code 和 smoke 判据。
- 入口 C（live MCP teammate launch）仍按计划未覆盖。

## Conclusion
pass

## Handoff
- delivery: `jq` 硬依赖已修复；修后 A1/A2/B1 在隔离 fixture 上复验通过。证据见本文件及 `a1/a2/b1-*-after-fix` 产物。
- follow_up: 若后续需要“默认本地沙箱下也能直接通过 A1”，应单独调查 Codex CLI 的临时目录清理访问拒绝问题；这不是本轮 `jq` 修复的剩余阻塞。
