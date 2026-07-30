# Codex Host Configs

本目录只存可分享的 Codex 宿主模板。

- `AGENTS.md.template`: Codex 全局指令模板
- `settings.local.shared.json.template`: 共享 settings.local 模板
- `settings.local.user.example.json`: 用户本地 overlay 示例
- `hooks.shared.json.template`: 合并到 Codex 普通用户 `hooks.json` 的安全 Hook
- `config.user.example.toml`: 用户本地保留字段示例
- `config.workspace.toml.template`: 仅用于 Desktop 写边界资格实验的 project config；当前安装器不会部署

边界：

- `install.ps1` 不改用户 `config.toml`，也不创建或接管外部 `managed_config.toml`；仅当 registry/manifest 证明该文件是旧版 Harness 的未漂移 exact postimage 时，才事务化恢复原始用户基线。释放历史由实际 release manifest、稳定 plan digest 与当时的 manifest 链共同绑定，并在多 workspace owner handoff 期间由 registry 持久保留
- `hooks.json` 保留第三方 Hook，并按 Codex 正常信任流程启用；企业 `hooks=false` / managed-only 策略优先
- Hook 使用明文 `-Command` 调用受版本控制的 launcher 文件，再由安装时固化的绝对 PowerShell 7.3+ 路径运行 adapter；不使用 `EncodedCommand`、隐藏窗口或动态求值
- Windows Hook 的确定性测试覆盖 `cmd.exe /C`、PowerShell 7 和 Windows PowerShell；它只验证安装命令的 JSON 行为，不代表 Hook 已被 Codex 信任/启用，也不代表飞连或其他端点策略放行
- 普通文件写入只把目标路径送入 core policy，配置正文不会作为 `command_text`；direct `apply_patch` 从 Add/Update/Delete/Move 指令提取路径并按 Hook payload 的 `cwd` 做 Workspace containment，`Write`、`Edit`、`MultiEdit`、`NotebookEdit` 共享同一语义，未来等价工具的 adapter 也必须沿用该合同。缺少 `cwd`、无法解析目标、read-only、Workspace 外路径、受保护路径或宿主/系统拒绝仍 fail closed
- `Bash` command text 仍进入 core policy；shell-form `apply_patch` 是实际 Bash 命令，当前 Hook 缺少有效 tool workdir/environment 绑定，因此继续 fail closed
- 用户 Hook JSON 由显式 writer 精确保留 `BigInteger` / decimal；不依赖 PowerShell 7.5 才支持的 BigInteger `ConvertTo-Json` 行为
- 固定版本的 `permission_mode` 只接受 `default` / `bypassPermissions`，它不是 Plan 协作模式信号，也不提供只读保证
- 资格实验模板把原生工具设为 `:read-only`，只自动批准单一 `write_file` MCP；服务端重新绑定固定 RepoRoot/WorkspaceRoot、规范化路径、目标 CAS，并对 Governed/Critical 写重新校验 TaskId/ExpectedVersion/Profile/Contract/Approval/DryRun。它明确拒绝 Harness repo、`.assistant`、`.codex`、`.git`、`docs/tasks` 与根 `AGENTS.md`
- 该模板不能作为默认安装面：只读宿主同时会阻断 v1 五阶段文档/runtime、会写缓存或构建产物的验证、删除/重命名和 Git 提交；writer 也不支持 `RepoRoot == WorkspaceRoot`。在这些能力获得同等受控替代、跨版本安装更新/卸载和真实 Desktop E2E 前，状态必须保持 qualification-only / unavailable，而不是 active 或 pass
- 企业策略或端点隔离阻止 Hook 时应记录为 unavailable，并继续使用 Approval 与独立受控执行器；不得改名、混淆或换载体绕过
- launcher 路径包含 `` ` $ % ! ^ & | < > ( ) `` 时安装会在写入前拒绝，避免 cmd / PowerShell 双重解析歧义
- `.toml` 模板必须通过 `tests/forbidden-path-prefixes.txt` 检查
- 用户私有 provider / auth 留在本地
