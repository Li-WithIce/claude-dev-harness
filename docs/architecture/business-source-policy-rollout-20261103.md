# 2026-11-03 业务源码分流改造与更新记录

## 要求与原因

用户要求改造 Harness：审批人员、角色权限和数据关联的普通业务开发，不应因为业务名称或目录名反复要求审批。范围是 Harness 策略、入口和验证；不修改工作台业务源码，不扩大实际数据库操作权限，不开启 Hook。

旧行为有两个来源：`authorization-path-change` 按 `auth`、`permissions`、`rbac` 路径强制独立审查；风险总分达到 9 或 `authorization_or_security_boundary` 标签会将纯源码工作升为 Critical。

## 最小改动

- 移除 core 的 `authorization-path-change`。项目自定义 protected-action overlay 仍可声明自己的规则。
- 新增 `ActionKind=source-code`，要求写入意图、明确修改路径、无执行命令。该分类的风险总分最多选择 Governed；权限边界标签单独出现时只保留来源标记。其他明确 Critical 触发项继续生效。
- 同步策略 schema、工作区入口、说明、回归用例、清单和 TCB 库存。普通源码不要求 Approval 或独立审查；仍须验证实际行为。
- 执行命令、数据库操作和部署另行评估，不能借用源码分类。

## 固定版本与验证

- 源码提交：`4cc168c9b17616d9ca92e4ae783daad382ea5110`。
- 候选树：`2bffef16be630af20c57a228b7a29106ae5f7f36`，提交树与校验树相同。
- 仅提交本轮 21 个文件。原有两份暂存任务记录以及并行的项目连续性、Obsidian 文档均保留在原处，未纳入候选。

本轮改造过程中完成的验证：

| 检查 | 结果 |
| --- | --- |
| 策略契约 | pass，87 项 |
| Direct / Governed / Critical 分流 | pass，85 项 |
| 审批与受保护操作 | pass，106 项 |
| 入口契约 | pass，51 项 |
| 任务状态 | pass，145 项；环境受限的动态 SUBST 保持 unavailable |
| 核心场景 | pass，20 场景、40 变体 |
| 隔离 core 安装、回读、更新、卸载、清理 | pass，各步骤 exit 0 |
| 最终候选双清单、TCB 库存、diff 检查 | pass，未改变原有暂存内容 |

已通过的工程测试未因会话接续而重复运行。本次没有重新运行完整 Suite all，不能将上述结果扩大为所有环境均通过。

## 实际更新与只读验收

共享源码 `D:\data\dev-harness` 从 `7aae456a148737d49217a158a56f5d94c9921044` 正常切换到固定版本。通过 `scripts/update-managed-assets.ps1 -WorkspaceRoot D:\working` 更新工作台；`install.ps1` 与 `verify-installation.ps1` 均为 pass，整体 exit 0。工作台保持 core / minimal 安装。

安装清单：`C:\Users\28796\.dev-harness\backups\install-20261103-105756-963-26740\install-manifest.json`。

本地执行回执：`tmp/harness-business-source-update-20261103-105756.json`；安装后策略验收：`tmp/harness-business-source-installed-acceptance-20261103.json`。

安装后直接加载固定源码，以工作台真实源码路径作只读策略输入：低分源码为 Direct，高分源码为 Governed，均为 `approval=none`、`review=self`；`auth`、`permissions`、`rbac` 目录输入不命中受保护规则。生产破坏性 SQL 字符串仍命中 `production-database-destructive`，缺少任务及授权时拒绝；未执行 SQL。

用户级规则、Codex 配置、Harness preferences、工作台 PROJECT.md、项目说明和打包操作文档的更新前后哈希一致。`hooks=false` 和 `pretooluse_enabled=false` 保持不变。真实桌面 Hook 事件及业务端到端测试为 not_run。

## 旧任务接续

11:00（Asia/Taipei）只读回读时，`workbench-demo-alignment-20261103` 为 running / Critical / version 6，Approval 数量 0；状态读取报告零写入。该任务在本次 Harness 更新期间持续推进，未在此处修改其状态或 Contract。

新规则不会追溯改写旧任务 profile。由工作台原对话核对最新状态和剩余范围：若剩余为普通源码开发，按 `ActionKind=source-code` 重新分流；需要换任务时，按正式流程暂停、取消旧任务并保留证据，再为剩余源码建立独立 Governed 任务。不得直接修改旧 profile、伪造 Approval，或把实际数据库操作归为源码编辑。参见 [治理工作说明](../governed-work.md)。

## 宿主审批阻塞

桌面日志确认本对话已从 `resolvedApprovalPolicy=never` 切换到 `on-request`。本次使用正式目录外写入审批完成候选固定、提交和安装。此前 CreateProcess 前的 `blocked by policy` 未返回具体规则，原因仍不能准确归到 Harness 或某个审查器。
