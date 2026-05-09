# Codex Host Configs

本目录只存可分享的 Codex 宿主模板。

- `AGENTS.md.template`: Codex 全局指令模板
- `settings.local.shared.json.template`: 共享 settings.local 模板
- `settings.local.user.example.json`: 用户本地 overlay 示例
- `config.shared.toml.template`: 由安装脚本托管并写入 Codex `managed_config.toml` 的共享片段
- `config.user.example.toml`: 用户本地保留字段示例

边界：

- `install.ps1` 将 Harness 托管配置写入 `managed_config.toml`，并从用户 `config.toml` 清理旧 managed block；不覆盖用户本地 model/provider/auth/project trust，也不删除用户已有的其他 `[[skills.config]]`
- `.toml` 模板必须通过 `tests/forbidden-path-prefixes.txt` 检查
- 用户私有 provider / auth 留在本地
