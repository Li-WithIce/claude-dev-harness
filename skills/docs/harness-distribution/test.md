# Test Report

## Meta

- task_id: harness-distribution
- task_name: 开发 Harness 可分发项目整合
- tester: codex
- date: 2026-04-01
- conclusion: pass

## Summary

当前实现已通过 repo-wide 路径残留扫描、PowerShell 脚本语法检查、多个 sandbox 安装链路，以及真实宿主安装验证。基于已有证据，可以判定本轮交付满足 `plan.md` 中 TODO-1 至 TODO-10 的主要验收目标，并可进入 HANDOFF。

## Scope

- `install.ps1`
- `uninstall.ps1`
- `tests/verify-installation.ps1`
- `README.md`
- `skills/docs/` canonical 文档与历史文档路径收敛
- 真实宿主 `%USERPROFILE%\.claude` / `%USERPROFILE%\.codex` / `{WORKSPACE_ROOT}` 的安装落点

## Inputs Reviewed

- `skills/docs/harness-distribution/plan.md`
- `skills/docs/harness-distribution/implementation-notes.md`
- `skills/docs/harness-distribution/review.md`
- 当前仓库实现文件与真实宿主 spot-check 结果

## Test Approach

1. 对仓库执行 residual scan，排除 `backups/`、`tmp/` 与 `tests/forbidden-path-prefixes.txt`，确认无源机器绝对路径残留。
2. 运行 PowerShell parser，对 `install.ps1`、`uninstall.ps1`、`tests/verify-installation.ps1` 做语法检查。
3. 在 sandbox 中执行标准 `install -> verify -> uninstall`。
4. 在 sandbox 中构造 `.assistant/.claude/.qoder`、宿主 `.system`、已有 managed / unmanaged skill Junction，验证 sidecar 保留与 Junction 回滚。
5. 在 sandbox 中验证 recovery manifest snapshot 已落盘，且可用于 `uninstall.ps1 -ManifestPath ...`。
6. 在真实宿主执行 `install.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` 与 `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}`，并做 spot-check。

## Findings

- Repo-wide residual scan：`NO_HITS`。
- PowerShell parser：`install.ps1`、`uninstall.ps1`、`tests/verify-installation.ps1` 均返回 `OK`。
- 标准 sandbox：`tests/verify-installation.ps1` 返回 `STATUS: PASS`，`uninstall.ps1` 正常清理生成项。
- sidecar / Junction sandbox：
  - `.assistant`、`.claude`、`.qoder` 在 install / uninstall 后均保留。
  - managed skill 条目在 install 后切换为 repo Junction。
  - 原有 managed / unmanaged skill Junction 在 uninstall 后恢复为原目标。
- recovery manifest sandbox：
  - `backups/active-install.json -> install-manifest.json` 已落盘。
  - `tests/verify-installation.ps1` 返回 `STATUS: PASS`。
  - `uninstall.ps1 -ManifestPath ...` 正常执行。
- 真实宿主 uninstall / reinstall：
  - `uninstall.ps1 -ManifestPath {REPO_ROOT}\backups\install-20260401-180107\install-manifest.json` 正常执行。
  - 暴露出 repeated uninstall 导致 `.system` 断链的问题，修复后重新安装并通过验证。
- 真实宿主：
  - `install.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` 返回成功。
  - `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` 返回 `STATUS: PASS`。
  - `%USERPROFILE%\.claude\skills\.assistant` / `.claude` / `.qoder` 保留。
  - `%USERPROFILE%\.claude\skills\orchestrator` / `using-superpowers` 已切换为 repo Junction。
  - 当前 active install manifest 为 `{REPO_ROOT}\backups\install-20260401-181430\install-manifest.json`。

## Risks / Gaps

- `skills/docs` 在当前 Claude 宿主上按热切换策略保留为普通目录，尚未在冷态下验证完全收敛为 Junction。
- TODO-11 依赖 git remote；当前仓库没有 remote，未执行首次 push。

## Conclusion

pass

基于现有证据，当前实现已满足计划中的主要安装、验证、回滚与宿主切换目标；剩余风险均属于可传递的收尾事项，不构成当前阶段阻塞。
