# Claude Host Configs

本目录只存可分享的 Claude 宿主模板。

- `CLAUDE.md.template`: Claude 全局指令模板
- `settings.json.example`: 不含密钥的示例配置
- `settings.local.shared.json.template`: 共享 hooks 模板
- `settings.local.user.example.json`: 用户本地 overlay 示例

边界：

- 不把真实 token、base URL、私有权限项写进仓库
- `install.ps1` 负责把占位符渲染为目标机器路径
- 用户私有增量配置留在本地 overlay
