# Codex Host Configs

本目录只存可分享的 Codex 宿主模板。

- `AGENTS.md.template`: Codex 全局指令模板
- `settings.local.shared.json.template`: 共享 settings.local 模板
- `settings.local.user.example.json`: 用户本地 overlay 示例
- `config.shared.toml.template`: 由安装脚本托管并写入 Codex `managed_config.toml` 的共享片段
- `config.user.example.toml`: 用户本地保留字段示例

边界：

- `install.ps1` 只将 Harness 托管配置写入 `managed_config.toml`；用户 `config.toml` 是私有配置面，不由 workflow 创建、清理或改写
- `.toml` 模板必须通过 `tests/forbidden-path-prefixes.txt` 检查
- 用户私有 provider / auth 留在本地
