---
task_id: a184b530
task: 降低验收阶段 PowerShell 弹窗干扰
owner: mdhtml-finalizer
updated: 2026-05-11
status: implemented-uncommitted
---

# Quiet Validation Runner

## Cause Analysis

- README 的完整验证建议会让外部 agent 连续启动多条 `pwsh` 命令；在带 UI 的 Windows host 上，每条短进程都可能表现为一次 PowerShell 窗口闪现。
- 多个验证脚本内部用 `Start-Process` 捕获 stdout/stderr，原实现未指定隐藏窗口，是第二层弹窗来源。
- 直接把所有 `verify-*.ps1` 放进同一 PowerShell session 不安全，因为部分验证脚本会调用 `exit`；需要保留每个脚本独立 exit code。

## Implemented

- 新增 `scripts/run-validation.ps1`
  - `-Suite quick`：`git diff --check` + `verify-lite-footprint.ps1`。
  - `-Suite core`：常用核心回归，覆盖 README 原“文档 / 协议核心验证”脚本，并补充 workflow descriptor、skill manifest、AionUI skill contract、tool profile。
  - `-Suite all`：顺跑可直接执行的 `verify-*.ps1`，默认跳过需要显式 `-WorkspaceRoot` 的 `verify-installation.ps1`；传入 `-WorkspaceRoot` 时一并执行安装验证。
  - 外层只需一次 `pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 ...`；内部用 `CreateNoWindow = $true` 的子进程串行运行，保留 exit code 隔离。
- 更新 `README.md`
  - 将文档 / 协议核心验证与完整 verify 套件推荐入口切到 quiet runner。
  - 删除 README 中鼓励用户手动 `ForEach-Object { pwsh ... }` 的多短进程验证示例。
- 更新测试内部子进程启动方式
  - `tests/verify-aionui-skill-contract.ps1`
  - `tests/verify-skill-manifest.ps1`
  - `tests/verify-workflow-descriptor.ps1`
  - `tests/verify-team-orchestration.ps1`
  - `tests/verify-team-preset.ps1`
  - 这些 helper 的 `Start-Process` 增加 `-WindowStyle Hidden`。
- 更新 `tests/verify-lite-footprint.ps1`
  - 锁定 quiet runner 存在。
  - 锁定 README 推荐 `scripts/run-validation.ps1`。
  - 锁定 runner 使用 `CreateNoWindow = $true`、`-NoProfile -NonInteractive`。
  - 锁定关键内部 helper 使用 `-WindowStyle Hidden`。

## Repair de12b6e3

- `-Suite core` 补回 README 原“文档 / 协议核心验证”遗漏项：
  - `tests/verify-lite-artifact-validator.ps1`
  - `tests/verify-workflow-contracts.ps1`
  - `tests/verify-shared-memory-layers.ps1`
- `tests/verify-lite-footprint.ps1` 额外锁定 `tests/verify-team-orchestration.ps1` 与 `tests/verify-team-preset.ps1` 的 hidden 子进程行为。
- `tests/verify-lite-artifact-validator.ps1` 同步当前 live baseline：18 个 plan-bearing tasks，且 `1cfa7b79`、`37ce4e15`、`85ff35b0` 归入当前 expected FAIL 集合。

## Boundaries

- 未触碰 `%USERPROFILE%\.codex\config.toml`。
- 未改业务仓。
- 未引入 WSL、npm、pip 或其他 runtime 依赖。
- 未提交；等待复审或 Leader 指令。

## Validation

- PASS: `git diff --check`
- PASS: `pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite quick`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-lite-footprint.ps1`
- PASS: `pwsh -NoProfile -NonInteractive -File .\scripts\run-validation.ps1 -Suite core -IncludeCachedDiff`（含恢复后的 `verify-lite-artifact-validator.ps1`、`verify-workflow-contracts.ps1`、`verify-shared-memory-layers.ps1`）
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-install-isolation.ps1`
- PASS: `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts\run-validation.ps1 -Suite quick`

## Remaining Risk

- 外部 agent 如果继续直接发起多条独立 `powershell.exe` / `pwsh` 命令，仍可能看到窗口闪现；本轮通过 README 推荐入口和 quiet runner 降低默认路径干扰。
- `Start-Process -WindowStyle Hidden` 只修正当前 repo 中已发现的验证 helper；未来新增 helper 仍应优先用 quiet runner 或显式隐藏窗口。
