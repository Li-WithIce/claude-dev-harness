# Implementation Notes

> task_id: harness-distribution
> task_name: 开发 Harness 可分发项目整合
> date: 2026-04-01
> stage: DEV

## What Changed

- 将本轮高优先级 operational assets 完成参数化收敛：
  - `scripts/`
  - `runtime-hooks/claude/`
  - `agent-configs/`
  - `skills/obsidian-memory/`
  - `skills/using-superpowers/`
  - `skills/orchestrator/`
  - `vault-template/工作流/` 与 `vault-template/配置/工具与组件.md.template`
- 新增 `skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1`，统一解析：
  - `VaultRoot`
  - `WORKSPACE_ROOT`
  - `USERPROFILE` 下的 agent home
  - `OrchestratorFlowPath`
- 顶层共享脚本改为动态路径解析，不再固化源机器绝对路径：
  - `scripts/memory-health.ps1`
  - `scripts/memory-health-report.ps1`
  - `scripts/memory-maintain.ps1`
  - `scripts/resolve-obsidian-memory-script.ps1`
- Claude hooks 改为安装期渲染 `{VAULT_PATH}`：
  - `runtime-hooks/claude/posttooluse.js`
  - `runtime-hooks/claude/stop.js`
- 新增并实现：
  - `install.ps1`
  - `uninstall.ps1`
  - `tests/verify-installation.ps1`
- 重写 `README.md`，补齐安装、验证、回滚、边界与当前 caveats
- `install.ps1` 当前已覆盖：
  - 渲染 Claude / Codex / workspace 模板
  - 初始化/补齐 `vault-template/`
  - 部署 Claude hooks
  - 生成 Claude / Codex `settings.local.json`
  - 以 managed block 写入 Codex `config.toml`
  - 保留 Claude / Codex `skills` 根目录为普通目录，并按子项创建 managed Junction
  - 保留宿主 `skills/` 下的 `.assistant`、`.claude`、`.qoder` 等隐藏 sidecar
  - 合并 Claude/Codex 现有 `.system` 到 repo-local `skills/.system`
  - 备份并恢复已有 skill Junction 的链接元数据，而不是平铺成普通目录
  - 在 install 中途失败时持续写出 recovery manifest snapshot，避免只剩 backup 目录而没有可消费 manifest
  - 对断链 `.system` Junction 降级跳过，避免 repeated uninstall 后的空路径错误
  - 生成 install manifest 与 active-install 指针
- `tests/verify-installation.ps1` 当前已覆盖：
  - `skills` 根目录保持为普通目录检查
  - repo `skills/` managed 条目逐项链接检查
  - `.system` 可见性检查
  - hooks 文件存在与占位符渲染检查
  - Claude / Codex `settings.local.json` 结构检查
  - Codex `config.toml` managed block 与旧 `[[skills.config]]` 清理检查
  - `agent-configs/codex/*.toml` forbidden prefix 检查
  - `scripts/memory-health.ps1 -VaultRoot ...` 返回 `STATUS: PASS`
- `uninstall.ps1` 当前已覆盖：
  - 按 install manifest 回滚
  - 恢复原始 skill 条目、settings、`config.toml`
  - 删除 install 生成但安装前不存在的宿主文件
  - 恢复安装前已存在的 skill Junction 目标
  - 若宿主 `.system` 仍指向 repo-local `skills/.system`，则保留该生成目录，避免 repeated install/uninstall 后留下断链
  - 删除 repo-local 生成的 `skills/.system`
- 更新 `.gitignore`，忽略本机生成的 `skills/.system/`
- 更新 `.gitignore`，忽略 repo 根 `.obsidian/` 本地状态
- `vault-template/运行时/记忆候选.md.template` 已补齐标准表头，使健康检查不再因为初始模板缺表头而返回 `WARN`
- 清理 `skills/docs/` 历史设计文档与日志中的源机器绝对路径，统一改为 `%USERPROFILE%` / `{WORKSPACE_ROOT}` / `{VAULT_PATH}` / `{REPO_ROOT}`

## What Did Not Change

- 尚未配置 remote，也未完成首次 push

## Risks

- `install.ps1` 目前使用 Node 合并 `settings.local.json`，默认依赖本机可用 `node`
- `vault-template/` 当前采取“缺失即补齐、存在则保留”的策略，适合首次安装与保守升级，但不会主动刷新已存在的工作流/配置文档
- `.system` 当前策略是本机合并到 repo-local `skills/.system`；在真实双宿主环境下仍需要实机确认不会引入额外宿主副作用
- `uninstall.ps1` 当前不会清理 `.assistant/` 运行时数据，这是有意保守策略；若后续需要“彻底卸载”，应单独定义更强约束的清理模式
- 为避免 live session 自己锁住 `skills/docs`，当前安装在宿主已存在 `skills/docs` 普通目录时会保留它；这意味着 `docs` 在热切换场景下可能暂时不是 Junction
- install 若中途失败，虽然现在会写出 recovery manifest snapshot，但仍需要操作者用该 manifest 显式调用 `uninstall.ps1`
- repo-local `skills/.system` 当前仍属于安装生成物，不进 Git；若宿主继续依赖它，重复 uninstall 只会回退到“上一轮已安装状态”，而不是强制清空 `.system`

## Reviewer Watchouts

- 核查 `install.ps1` 对 Codex `config.toml` 的 managed block 边界是否足够稳定，尤其是旧 `[[skills.config]]` 清理规则
- 核查 `install.ps1` 对 `settings.local.json` 的 merge 策略是否只托管共享区块，同时保留用户本地增量
- 核查 `skills/.system` 的 repo-local 合并策略是否满足 Claude/Codex 双宿主兼容预期
- 核查 `skills/docs` 的热切换保留策略是否足够明确，是否需要在后续冷启动安装中补充“收敛为 Junction”的路径
- 核查 `uninstall.ps1` 对“安装前不存在的目标文件”的删除范围是否仍然足够保守，以及 Junction 恢复分支是否覆盖足够全面

## Verification Run

- repo-wide residual scan（排除 `backups/`、`tmp/` 与 `tests/forbidden-path-prefixes.txt`）：
  - 结果：`NO_HITS`
- 高优 scoped residual scan：
  - `scripts/`
  - `runtime-hooks/`
  - `agent-configs/`
  - `skills/obsidian-memory/`
  - `skills/using-superpowers/`
  - `skills/orchestrator/`
  - `vault-template/工作流/`
  - `vault-template/配置/`
  - 结果：未命中 `%USERPROFILE%` / `{WORKSPACE_ROOT}` / `{REPO_ROOT}`
- `{REPO_ROOT}\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH}`
  - 结果：`STATUS: PASS`
- `node --check {REPO_ROOT}\runtime-hooks\claude\posttooluse.js`
  - 结果：通过
- `node --check {REPO_ROOT}\runtime-hooks\claude\stop.js`
  - 结果：通过
- sandbox 演练：
  - `install.ps1 -WorkspaceRoot {REPO_ROOT}\tmp\sandbox\workspace`
  - `tests/verify-installation.ps1 -WorkspaceRoot {REPO_ROOT}\tmp\sandbox\workspace`
  - 结果：`STATUS: PASS`
- recovery-manifest smoke sandbox：
  - `install.ps1 -WorkspaceRoot {REPO_ROOT}\tmp\manifest-sandbox\workspace`
  - 安装后确认 `backups/active-install.json -> install-manifest.json` 已落盘
  - `tests/verify-installation.ps1 -WorkspaceRoot {REPO_ROOT}\tmp\manifest-sandbox\workspace`
  - `uninstall.ps1 -ManifestPath {REPO_ROOT}\backups\install-20260401-180047\install-manifest.json`
  - 结果：`STATUS: PASS`
- sidecar / Junction 回归 sandbox：
  - 构造 `.assistant/.claude/.qoder` sidecar、宿主 `.system`、已有 managed skill Junction、额外本地 skill Junction
  - `install.ps1 -WorkspaceRoot {REPO_ROOT}\tmp\sidecar-sandbox\workspace`
  - `tests/verify-installation.ps1 -WorkspaceRoot {REPO_ROOT}\tmp\sidecar-sandbox\workspace`
  - `uninstall.ps1 -ManifestPath {REPO_ROOT}\backups\install-20260401-174154\install-manifest.json`
  - 结果：
    - sidecar 在 install / uninstall 后均保留
    - managed skill 条目切换为 repo Junction
    - 原有 managed / unmanaged skill Junction 在 uninstall 后恢复为原目标
    - repo-local `skills/.system` 在 uninstall 后移除
- sandbox 回滚：
  - `uninstall.ps1 -ManifestPath {REPO_ROOT}\backups\install-20260401-171816\install-manifest.json`
  - spot-check 结果：
    - `.claude\skills` / `.codex\skills` 已恢复为普通目录
    - 原始 `.system` 内容恢复
    - 原始 `settings.local.json` 恢复
    - repo-local `skills/.system` 已移除
- 真实宿主 uninstall / reinstall 演练：
  - `uninstall.ps1 -ManifestPath {REPO_ROOT}\backups\install-20260401-180107\install-manifest.json`
  - 演练中发现 repeated uninstall 会把仍被宿主 `.system` Junction 引用的 repo-local `skills/.system` 删掉，已修复脚本并从 `install-20260401-174218` 备份恢复 `.system`
  - 修复后重新执行 `install.ps1 -WorkspaceRoot {WORKSPACE_ROOT}`
  - `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}`
  - 结果：`STATUS: PASS`
- 真实宿主安装演练：
  - `install.ps1 -WorkspaceRoot {WORKSPACE_ROOT}`
  - `tests/verify-installation.ps1 -WorkspaceRoot {WORKSPACE_ROOT}`
  - 结果：`STATUS: PASS`
  - spot-check 结果：
    - `%USERPROFILE%\.claude\skills\.assistant` / `.claude` / `.qoder` 保留
    - `%USERPROFILE%\.claude\skills\orchestrator` / `using-superpowers` 已切换为指向 repo 的 Junction
    - `%USERPROFILE%\.claude\skills\docs` 按热切换策略保留为普通目录
    - `backups/active-install.json` 当前指向 `install-20260401-181430\install-manifest.json`
  - 额外说明：
    - 首次真实安装失败前的原始基线备份仍保留在 `{REPO_ROOT}\backups\install-20260401-174218`
