# Codex Host Configs

本目录只存可分享的 Codex 宿主模板。

- `AGENTS.md.template`: Codex 全局指令模板
- `settings.local.shared.json.template`: 共享 settings.local 模板
- `settings.local.user.example.json`: 用户本地 overlay 示例
- `hooks.shared.json.template`: 合并到 Codex 普通用户 `hooks.json` 的安全 Hook
- `config.user.example.toml`: 用户本地保留字段示例

边界：

- `install.ps1` 不改用户 `config.toml`，也不创建或接管外部 `managed_config.toml`；仅当 registry/manifest 证明该文件是旧版 Harness 的未漂移 exact postimage 时，才事务化恢复原始用户基线。释放历史由实际 release manifest、稳定 plan digest 与当时的 manifest 链共同绑定，并在多 workspace owner handoff 期间由 registry 持久保留
- `hooks.json` 保留第三方 Hook，并按 Codex 正常信任流程启用；企业 `hooks=false` / managed-only 策略优先
- Hook 使用明文 `-Command` 调用受版本控制的 launcher 文件，再由安装时固化的绝对 PowerShell 7.3+ 路径运行 adapter；不使用 `EncodedCommand`、隐藏窗口或动态求值
- Windows 资格测试按 Codex 0.144.4 的环境-shell 调用形态覆盖 `cmd.exe /C`、PowerShell 7 和 Windows PowerShell；它只验证安装命令的 JSON 行为，不代表 Hook 已被 Codex 信任/启用，也不代表飞连或其他端点策略放行
- `Bash` command text 进入 core policy；Codex 0.144.4 Hook 不提供可信的实际 environment identity/cwd，remote primary 还可能把 Hook cwd 回退到本机，因此 Bash shell-form 和所有 direct `apply_patch` 都 fail closed；宿主增加可信绑定前不按看似本地的 patch 路径放行
- 用户 Hook JSON 由显式 writer 精确保留 `BigInteger` / decimal；不依赖 PowerShell 7.5 才支持的 BigInteger `ConvertTo-Json` 行为
- 固定版本的 `permission_mode` 只接受 `default` / `bypassPermissions`，它不是 Plan 协作模式信号，也不提供只读保证
- 企业策略或端点隔离阻止 Hook 时应记录为 unavailable，并继续使用 Approval 与独立受控执行器；不得改名、混淆或换载体绕过
- launcher 路径包含 `` ` $ % ! ^ & | < > ( ) `` 时安装会在写入前拒绝，避免 cmd / PowerShell 双重解析歧义
- `.toml` 模板必须通过 `tests/forbidden-path-prefixes.txt` 检查
- 用户私有 provider / auth 留在本地
