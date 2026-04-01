# Handoff

> task_id: harness-distribution
> task_name: 开发 Harness 可分发项目整合
> stage: HANDOFF
> date: 2026-04-01
> status: ready

## Summary

`harness-distribution` 已完成从单机散布资产向可分发单仓库模式的改造。当前仓库已包含 shared assets、宿主模板、`vault-template/`、安装/回滚/验证脚本，以及 canonical 文档；针对 live session 下保留为普通目录的 `skills/docs`，仓库现在也提供了 `scripts/sync-preserved-docs.ps1` 作为显式同步入口。真实宿主已经刷新到当前代码对应的安装形态，并在同步保留的 `skills/docs` 后通过 `tests/verify-installation.ps1` 验证。

## Completed

- TODO-1 到 TODO-10 已完成。
- operational assets 与历史 `skills/docs/` 文档中的源机器绝对路径已清理为 `%USERPROFILE%` / `{WORKSPACE_ROOT}` / `{VAULT_PATH}` / `{REPO_ROOT}`。
- `install.ps1` 已支持：
  - shared skills 子项级 Junction
  - `.assistant` / `.claude` / `.qoder` sidecar 保留
  - `.system` 合并
  - `settings.local.json` merge-render
  - Codex `config.toml` managed block
  - 只清理 Harness 自己托管的 `[[skills.config]]` 条目，保留用户已有的其他 Codex skill 配置
  - install 中途失败时的 recovery manifest snapshot
- `uninstall.ps1` 已支持：
  - 按 manifest 回滚
  - 恢复原始 skill Junction 目标
  - 删除安装生成项
- `tests/verify-installation.ps1` 已覆盖：
  - managed skill 链接
  - hooks 渲染
  - Claude / Codex `settings.local.json`
  - Codex `config.toml` managed block 内容一致性与托管 skill path 外泄检查
  - `skills/docs` 保留目录内容一致性告警
  - `skills/docs` 保留目录额外陈旧文件告警
  - forbidden prefix 检查
  - 共享记忆健康检查
- `scripts/sync-preserved-docs.ps1` 已支持：
  - 同步 `%USERPROFILE%\.claude\skills\docs` 与 `%USERPROFILE%\.codex\skills\docs`
  - 覆盖漂移文件
  - 移除 repo 中已不存在的陈旧 docs

## Current State

- 当前工作分支：`codex/harness-distribution`
- 真实宿主已安装完成。
- 真实宿主保留的 `%USERPROFILE%\.claude\skills\docs` 与 `%USERPROFILE%\.codex\skills\docs` 当前与 repo canonical docs 一致。
- 当前 active install manifest：
  - `{REPO_ROOT}\backups\install-20260401-185834\install-manifest.json`
- 真实宿主验证结果：
  - `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}` -> `STATUS: PASS`
- 首次真实安装失败前的原始基线备份仍保留：
  - `{REPO_ROOT}\backups\install-20260401-174218`

## Verification Evidence

- repo-wide residual scan（排除 `backups/`、`tmp/` 与 `tests/forbidden-path-prefixes.txt`） -> `NO_HITS`
- 标准 sandbox `install -> verify -> uninstall` -> 通过
- sidecar / Junction 回归 sandbox -> 通过
- recovery manifest smoke sandbox -> 通过
- Codex config 托管边界 sandbox -> install 保留用户自有 `[[skills.config]]`，`verify` 返回 `STATUS: PASS`
- `skills/docs` 漂移告警 sandbox -> 保留目录发生漂移时，`verify` 返回 `STATUS: WARN`
- `skills/docs` 额外陈旧文件 sandbox -> 保留目录存在 repo 已删除的旧文件时，`verify` 返回 `STATUS: WARN`
- `skills/docs` 自动同步 sandbox -> `verify` 先返回 `STATUS: WARN`，运行 `scripts/sync-preserved-docs.ps1` 后再次 `verify` 返回 `STATUS: PASS`
- 真实宿主 `sync-preserved-docs -> verify` -> 脚本输出 `Claude updated=4`、`Codex updated=4`，随后 `verify` 返回 `STATUS: PASS`
- 真实宿主 `install -> verify` -> 先识别 stale 安装，再在刷新 managed block 与同步 `skills/docs` 后返回 `STATUS: PASS`

## Watchouts

- `skills/docs` 在 live session 下仍会按热切换策略保留为普通目录，避免锁冲突；后续 canonical docs 再变更时，需要运行 `scripts/sync-preserved-docs.ps1` 重新收敛，或在冷态下补一轮切换。
- `uninstall.ps1` 不会清理 `{VAULT_PATH}\运行时\*`，这是有意保守策略。
- install 若中途失败，需使用 backup 目录中的 `install-manifest.json` 显式调用 `uninstall.ps1 -ManifestPath ...`。
- 当前仓库尚未配置 remote，因此 TODO-11 只能先完成本地 commit，不能直接 push。
- `.system` 当前通过 repo-local `skills/.system` 维持宿主可见性；相关 repeated uninstall 断链问题已修复。

## Next Actions

- 若要补齐回滚证据，执行一次真实宿主 uninstall 演练，再重新安装：
  - 已完成，可复用当前步骤重新验证。
- 若后续继续改动 `skills/docs` canonical 文档，运行 `scripts/sync-preserved-docs.ps1`，或改走冷态切换以避免 verify 再次返回 `WARN`。
- 若要完成 TODO-11，配置 git remote 后 push 当前分支。
