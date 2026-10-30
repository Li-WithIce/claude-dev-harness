# 项目连续工作改造执行记录

日期：2026-10-30。任务：project-continuity-20261030。当前状态：实施中，真实宿主接续验收未完成。

## 已确认要求与决定

用户要求完善 Harness，让工作台换窗口后沿用已验证打包方式和配置，并保留改造前要求、原因和生命周期记录；不要求集成 memsearch。已批准方案见 ../../architecture/project-continuity-workbench-plan.md。

- PROJECT.md 为用户维护的显式接入入口，生成的 AGENTS 读取它；正式业务说明归档到实际 Git 仓库。
- 业务 Markdown 不等同机器任务状态，Direct 路由算法不改，不新增服务/依赖或 Hook。
- 工作台共用文档放后端仓库；前后端入口指向同一份说明。
- 历史成功打包对话已核实三类产物；完整旧 shell 参数未取到。新薄脚本沿用 package.json 与 Maven，并将实际复测作为新操作基线。

## 检查点

- 通用入口、模板、指南、检索 PROJECT 来源已实现。
- 工作台项目说明、变更记录、操作说明、三个入口和一个打包脚本已创建，本地未提交。
- pass：本地 context recall/read 38 项；Direct 77 项；隔离安装/更新/卸载保留项目文件检查通过。
- 工作台首次真实构建 pass（exit 0），143 测试、0 失败/错误/跳过；ZIP 和两个 JAR 结构通过，输出 `D:\working\release\continuity-20261030-01`，未部署。
- 初次 entry-contract 验证因新增长规则超过入口字节预算而失败（日志 entry-contract.log）；已把详细规则下沉到显式接入的 PROJECT 模板，缩短重复说明，保持原有预算不变。复验 51 项通过（entry-contract-02.log）。
- entry-lifecycle 首轮遇到 runtime-default-source-dirty，当前维护工作树保留用户原有暂存文件；该轮停止，保留日志，改在固定候选的干净验证 worktree 运行，不清理用户文件。
- 其他必要仓库验证、正常安装更新和原始资产哈希回读待完成。
- 新建真实对话、真实压缩后接续及后续业务需求闭环：not_run。新进程 fixture 只证明文档查找与读取，不替代宿主行为。

## 保留边界

两份用户原暂存文件保持原对象；前端 .env.production、用户规则、Codex hooks=false 与 pretooluse_enabled=false 保持原值。无数据库写入、部署或服务启停。日志在 `.assistant/runtime/project-continuity-20261030/`，正式汇总随后补记。
