# 项目连续工作改造验证记录

时间：2026-10-30。Harness 候选：`cddacbad5a2d3511b4a1ecbafa2896e20e97fb51`。结论：partial，实际新会话与真实压缩仍待验收。

## 已验证

- 通用 PROJECT 导航和本地 context recall/read：38 项通过；Direct 业务记录不触发机器任务写入：77 项通过；entry contract：51 项通过。
- 隔离安装、更新、卸载保留 PROJECT 和业务文档；关闭 PreToolUse 后安装、更新、安装验证保持偏好。provider 变更相关七项验证通过。
- adapter inventory、kernel TCB inventory 与 module/capability catalog 检查通过；验证目录中入口生命周期组 12 项通过，原 default-flip 缺临时目录失败，设置 `DEV_HARNESS_VALIDATION_TEMP_ROOT` 后单项 51 项通过。完整 harness-contracts 组被运行环境中断；其中 thin-adapters、session-workspaces 和 canonical-json 已通过，不能将该组记为整体通过。
- D:\data 正常更新并通过安装验证；D:\working core 安装后再次正常更新并通过安装验证。三个 PROJECT 与共享业务文档在安装更新前后哈希一致；旧工作区 AGENTS 保存在 `C:\Users\28796\.dev-harness\backups\install-20261030-152714-106-3064\D_working_AGENTS.md`，与更新前哈希一致。
- D:\working 已安装的 context recall/read 找回并读取 `workbench-service/docs/operations/build-release.md`。总目录、前端、后端的 PROJECT 均解析到同一份工作台说明。
- 固定工具路径的脚本在 `D:\working\release\continuity-20261030-02` 和 `continuity-20261030-03` 构建成功，第三次在原 Maven PATH 缺失且 JAVA_HOME 无效的子进程运行；退出码 0，后端 16 类、143 测试、0 失败、0 错误、0 跳过。ZIP 根目录与两个 JAR 主类、外置配置未被打入 JAR 均已检查。
- 前端原 `.env.production`、用户规则、pretooluse_enabled=false 的哈希不变；Codex/Claude 的 PreToolUse 未注册，Codex hooks=false。两份用户原暂存文件 blob `9220841cd016f0fa92e913acab5f1e91d8b29f83`、`ed5177fa22f224c366d5340dacef4fc4d4cd16ea` 保留。

## 未验证或限制

- 新 Codex 会话重新接续、真正上下文压缩后继续、用户后续真实需求的闭环：not_run。新 PowerShell 进程和检索夹具不等于宿主验收。
- 历史成功对话只证明产物及工具链，完整原 shell 参数未取到；本次新入口已实际验证，不声称字节级复原历史命令。
- `C:\Users\28796\.codex\config.toml` 哈希在本轮期间改变，修改时间 15:25:39；安装器/安装清单未发现对该文件的写入，现有快照不足以确认变化内容或来源。未覆盖文件，当前 hooks=false 已核实。
- 未运行完整 Suite all；未部署、未修改数据库、未停止或启动服务。
- 工作台文件尚未提交/推送；能从同一机器新窗口读取，但没有远端版本保障。

详细日志保存在 `.assistant/runtime/project-continuity-20261030/`，包括 `context-recall.log`、`direct.log`、`entry-contract-02.log`、`entry-lifecycle-02.log`、`default-flip-03.log`、`providers-03.log`、`continuity-install-final.log`、`hook-preference.log`、`install-data.log`、`update-working.log` 和 `workbench-build-clean-env.log`。日志只证明实际执行范围，不代替未运行的场景。
