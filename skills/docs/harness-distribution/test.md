# Test Report

## Meta

- task_id: harness-distribution
- task_name: 开发 Harness 可分发项目整合
- tester: codex
- date: 2026-04-01
- conclusion: pass

## Summary

当前实现已通过 repo-wide 路径残留扫描、PowerShell 脚本语法检查、多个 sandbox 安装链路，以及最新真实宿主 `install -> verify` 验证。针对 Codex `config.toml` 托管边界、`skills/docs` 内容漂移和保留目录中的额外陈旧文件，本轮不仅补上了定向 sandbox 证据，还新增了 `scripts/sync-preserved-docs.ps1` 自动修复路径，并验证了 `WARN -> sync -> PASS` 的闭环；结合最新真实宿主 `STATUS: PASS`，可以判定本轮交付满足 `plan.md` 中 TODO-1 至 TODO-10 的主要验收目标，并可进入 HANDOFF。

## Scope

- `install.ps1`
- `uninstall.ps1`
- `scripts/sync-preserved-docs.ps1`
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
2. 运行 PowerShell parser，对 `install.ps1`、`uninstall.ps1`、`scripts/sync-preserved-docs.ps1`、`tests/verify-installation.ps1` 做语法检查。
3. 在 sandbox 中执行标准 `install -> verify -> uninstall`。
4. 在 sandbox 中构造 `.assistant/.claude/.qoder`、宿主 `.system`、已有 managed / unmanaged skill Junction，验证 sidecar 保留与 Junction 回滚。
5. 在 sandbox 中验证 recovery manifest snapshot 已落盘，且可用于 `uninstall.ps1 -ManifestPath ...`。
6. 在 `config-boundary` sandbox 预置用户自有 `[[skills.config]]`，验证 install 不会删除非 Harness 托管条目。
7. 在 `docs-drift` sandbox 预置保留为普通目录的 `skills/docs` 并制造内容漂移，验证 `tests/verify-installation.ps1` 返回 `WARN`。
8. 在 `docs-extra` sandbox 预置与 repo 一致的保留 `skills/docs`，再额外注入 repo 已不存在的旧文件，验证 `tests/verify-installation.ps1` 返回 `WARN`。
9. 在 `docs-sync` sandbox 预置 `.claude/.codex` preserved docs 漂移，然后验证 `tests/verify-installation.ps1 -> WARN`、`scripts/sync-preserved-docs.ps1 -> 修复`、再次 `tests/verify-installation.ps1 -> PASS`。
10. 在真实宿主先执行 `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` 识别 stale 安装状态，再执行 `install.ps1 -WorkspaceRoot {WORKSPACE_ROOT}`、同步保留的 `skills/docs` 目录，并重新运行 `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}`。

## Findings

- Repo-wide residual scan：`NO_HITS`。
- PowerShell parser：`install.ps1`、`uninstall.ps1`、`scripts/sync-preserved-docs.ps1`、`tests/verify-installation.ps1` 均返回 `OK`。
- 标准 sandbox：`tests/verify-installation.ps1` 返回 `STATUS: PASS`，`uninstall.ps1` 正常清理生成项。
- sidecar / Junction sandbox：
  - `.assistant`、`.claude`、`.qoder` 在 install / uninstall 后均保留。
  - managed skill 条目在 install 后切换为 repo Junction。
  - 原有 managed / unmanaged skill Junction 在 uninstall 后恢复为原目标。
- recovery manifest sandbox：
  - `backups/active-install.json -> install-manifest.json` 已落盘。
  - `tests/verify-installation.ps1` 返回 `STATUS: PASS`。
  - `uninstall.ps1 -ManifestPath ...` 正常执行。
- Codex config 托管边界 sandbox：
  - 预置用户自有 `[[skills.config]]` 后执行 `install -> verify -> uninstall`。
  - install 后 `config.toml` 同时保留用户自有条目与 Harness managed block。
  - `tests/verify-installation.ps1` 返回 `STATUS: PASS`。
- `skills/docs` 漂移告警 sandbox：
  - 预置宿主 `skills/docs` 为普通目录，并人为修改 `review.md`。
  - `tests/verify-installation.ps1` 返回 `STATUS: WARN`，告警内容包含“保留为普通目录，但与 repo 内容不一致”。
- `skills/docs` 额外陈旧文件告警 sandbox：
  - 预置宿主 `skills/docs` 为与 repo 一致的普通目录，再额外加入 `obsolete-task\review.md`。
  - `tests/verify-installation.ps1` 返回 `STATUS: WARN`，告警内容包含 `extra=1`。
- `skills/docs` 自动同步 sandbox：
  - 预置 `.claude\skills\docs\harness-distribution\review.md` 漂移，且在 `.codex\skills\docs` 注入 `obsolete-task\review.md`。
  - 首次 `tests/verify-installation.ps1` 返回 `STATUS: WARN`，并在告警中提示运行 `scripts\sync-preserved-docs.ps1`。
  - 执行 `scripts/sync-preserved-docs.ps1 -RepoRoot {REPO_ROOT}` 后，输出 `Claude updated=1`、`Codex removed=2`。
  - 再次 `tests/verify-installation.ps1` 返回 `STATUS: PASS`。
- 真实宿主 uninstall / reinstall：
  - `uninstall.ps1 -ManifestPath {REPO_ROOT}\backups\install-20260401-180107\install-manifest.json` 正常执行。
  - 暴露出 repeated uninstall 导致 `.system` 断链的问题，修复后重新安装并通过验证。
- 真实宿主：
  - 初次直接执行 `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` 时，识别出旧 managed block 与保留 `skills/docs` 漂移导致的 stale 状态。
  - 重新执行 `install.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` 后，Codex `config.toml` managed block 已与最新模板一致。
  - 执行 `scripts/sync-preserved-docs.ps1 -RepoRoot {REPO_ROOT}` 后，输出 `Claude updated=4`、`Codex updated=4`。
  - 随后 `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` 返回 `STATUS: PASS`。
  - `%USERPROFILE%\.claude\skills\.assistant` / `.claude` / `.qoder` 保留。
  - `%USERPROFILE%\.claude\skills\orchestrator` / `using-superpowers` 已切换为 repo Junction。
  - 当前 active install manifest 为 `{REPO_ROOT}\backups\install-20260401-185834\install-manifest.json`。

## Risks / Gaps

- `skills/docs` 在 live session 热切换模式下仍保留为普通目录；未来 canonical docs 再变更时，仍需要运行 `scripts/sync-preserved-docs.ps1` 或在冷态下重装，不能指望 install 自动把它收敛回 Junction。
- TODO-11 依赖 git remote；当前仓库没有 remote，未执行首次 push。

## Conclusion

pass

基于现有证据，当前实现已满足计划中的主要安装、验证、回滚与宿主切换目标；剩余风险均属于可传递的收尾事项，不构成当前阶段阻塞。
