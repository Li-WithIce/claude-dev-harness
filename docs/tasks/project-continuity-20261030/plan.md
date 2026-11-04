# Governed Plan

- task_id: project-continuity-20261030
- contract_digest: sha256:a1ccc6c33fe0ae036687ad97a9f6ebf7ebe12b67c8d5ead18c4fb01400115ffe

## Goal

实现已确认的 Harness 连续接续与改造溯源计划，在 working 接入并复测既有打包方式。正式方案见 ../../architecture/project-continuity-workbench-plan.md。

## Scope

通用入口、项目文档模板、既有本地检索、必要分发验证与 working 试点。保留原有暂存文件、用户配置修改和 Hook 关闭偏好；不安装外部记忆产品，不执行数据库写入或生产部署。

## Implementation

1. 核实工作台成功打包记录、配置来源与实际构建入口。
2. 用用户维护的 PROJECT.md 显式接入项目连续记录，正式资料保存在 Git 仓库；生成的 AGENTS.md 只负责发现入口，避免安装更新覆盖项目路径。
3. 调整 Direct 规则，允许轻量业务记录但不创建机器任务状态；复用现有 recall/read。
4. 增加通用模板，接入工作台前后端与父目录，固化已证实的构建命令并做本地复测。
5. 验证入口、检索、安装更新保留性，记录真实跨会话/压缩验收与未执行项。

## Verification

运行相关 Direct、entry-contract、context-recall 和分发检查；工作台构建和包结构检查；核对原暂存对象及配置哈希。新会话、真实压缩和用户后续新需求的验收必须有实际观察，未发生时不得声明通过，Evidence 保留 partial。

## Rollback

回退本次入口、模板与脚本变更即可停止接入；保留业务记录、用户文件和失败证据。通过正常安装更新传播，不启用 Hook，不使用 reset/stash/clean。
