# Governed 与 Critical 工作

## 何时使用

Governed 适用于需要持久任务状态、可审计交付、较高风险或受保护范围的工作。Critical 适用于生产、权限/安全、资金、破坏性迁移、不可逆数据变化、公共 API 破坏、敏感数据导出、破坏 Git 历史或缺少 dry-run 的大规模自动化。

文件数量本身不会升级 profile；真正决定因素是风险、持久化要求和受保护动作。

## 最短生命周期

1. 冻结清楚的 Requirement，并选择 Governed 或 Critical。
2. 创建/恢复唯一的 v2 task state；它是生命周期真相源。
3. 按策略满足必需能力后实施。Governed 总是需要验证和持久 Evidence；计划、Approval、回滚与独立审查按策略组合。
4. Critical 在执行和完成前必须具备计划、有效 Approval、回滚方案、独立审查、dry-run、验证与 Evidence。
5. Evidence 记录真实命令、退出码、覆盖、缺口与结论；Critical 的实际 dry-run 命令使用顶层结构化 `dry_run` command 对象，记录独立受控执行器 actor，并继承同一 Evidence 的 task/version/Contract/revision 绑定。未执行项标为 unavailable、manual 或 blocked，不能伪造 pass。
6. 完成门重新校验任务版本、Requirement digest、仓库修订、Evidence、Approval 和治理记录，再进行合法状态转换；正常 verify 与 replay 共用同一 Critical dry-run 门禁。

Approval 与 Ask 不同：Approval 缺失是能力阻断，只有产品/授权决定本身不清楚时才 Ask。作用域、任务版本或 Requirement 变化后，旧 Approval 不能继续授权。

## 中断、恢复与回滚

状态和 Evidence 都保留在工作区内的 canonical v2 路径；current pointer、事件、审计与恢复索引只是绑定记录或派生视图。只读 status/resume 不写状态，只有显式 resume-and-execute 才继续执行。

设置 `HARNESS_PROTOCOL=v1` 只影响新任务路由，不会删除或隐式转换 v2 task。已有 v1 task 继续使用五阶段流程；显式迁移保留原 v1 artifact，回滚也不得靠删除 v2 数据重新激活 v1。

机器状态、Evidence、Approval 与转换规则分别以 `schemas/`、`policies/` 和 `scripts/lib/` 为准；本页只提供操作心智模型。
