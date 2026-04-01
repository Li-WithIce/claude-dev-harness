# Handoff

> task_id: harness-distribution
> task_name: 开发 Harness 可分发项目整合
> stage: HANDOFF
> date: 2026-04-01
> status: ready

## Summary

`harness-distribution` 已完成从单机散布资产向可分发单仓库模式的改造。当前仓库已包含 shared assets、宿主模板、`vault-template/`、安装/回滚/验证脚本，以及 canonical 文档；真实宿主已经切换到该仓库驱动的安装形态，并通过 `tests/verify-installation.ps1` 验证。

## Completed

- TODO-1 到 TODO-10 已完成。
- operational assets 与历史 `skills/docs/` 文档中的源机器绝对路径已清理为 `%USERPROFILE%` / `{WORKSPACE_ROOT}` / `{VAULT_PATH}` / `{REPO_ROOT}`。
- `install.ps1` 已支持：
  - shared skills 子项级 Junction
  - `.assistant` / `.claude` / `.qoder` sidecar 保留
  - `.system` 合并
  - `settings.local.json` merge-render
  - Codex `config.toml` managed block
  - install 中途失败时的 recovery manifest snapshot
- `uninstall.ps1` 已支持：
  - 按 manifest 回滚
  - 恢复原始 skill Junction 目标
  - 删除安装生成项
- `tests/verify-installation.ps1` 已覆盖：
  - managed skill 链接
  - hooks 渲染
  - Claude / Codex `settings.local.json`
  - Codex `config.toml`
  - forbidden prefix 检查
  - 共享记忆健康检查

## Current State

- 当前工作分支：`codex/harness-distribution`
- 真实宿主已安装完成。
- 当前 active install manifest：
  - `{REPO_ROOT}\backups\install-20260401-181430\install-manifest.json`
- 真实宿主验证结果：
  - `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` -> `STATUS: PASS`
- 首次真实安装失败前的原始基线备份仍保留：
  - `{REPO_ROOT}\backups\install-20260401-174218`

## Verification Evidence

- repo-wide residual scan（排除 `backups/`、`tmp/` 与 `tests/forbidden-path-prefixes.txt`） -> `NO_HITS`
- 标准 sandbox `install -> verify -> uninstall` -> 通过
- sidecar / Junction 回归 sandbox -> 通过
- recovery manifest smoke sandbox -> 通过
- 真实宿主 `uninstall -> install -> verify` -> `STATUS: PASS`

## Watchouts

- `skills/docs` 在当前 Claude 宿主上按热切换策略保留为普通目录，避免 live session 锁冲突；如需完全收敛为 repo single-source，可在冷态下补一轮切换。
- `uninstall.ps1` 不会清理 `{VAULT_PATH}\运行时\*`，这是有意保守策略。
- install 若中途失败，需使用 backup 目录中的 `install-manifest.json` 显式调用 `uninstall.ps1 -ManifestPath ...`。
- 当前仓库尚未配置 remote，因此 TODO-11 只能先完成本地 commit，不能直接 push。
- `.system` 当前通过 repo-local `skills/.system` 维持宿主可见性；相关 repeated uninstall 断链问题已修复。

## Next Actions

- 若要补齐回滚证据，执行一次真实宿主 uninstall 演练，再重新安装：
  - 已完成，可复用当前步骤重新验证。
- 若要完成 TODO-11，配置 git remote 后 push 当前分支。
