# Harness 轻量工作流与统一上下文改造计划

日期：2026-10-27。依据：用户在 mini-trellis 对比后要求先制定计划，再按计划改造。

## Goal

普通开发继续走现有 Direct；需要历史依据时通过一个按需只读入口检索项目文档与当前项目的 Codex 对话，先看短摘录，再读取原文。需要持久交付证据的任务继续使用 v2 Governed，不引入新的生命周期。

## Scope

- 修正当前用户指南和 Provider 参考里的 v1 五阶段、plan frontmatter 状态真相等过时说明；历史归档保留历史身份。
- 增加 `scripts/context.ps1 recall/read`，复用 PowerShell、文件系统和 rg。默认检索项目 Markdown；显式 `-IncludeSessions` 加入当前项目的 Codex 本地对话，输出统一来源、摘录和可回读引用。
- 支持 Markdown frontmatter 的 `status: superseded` 和单值 `superseded_by: <workspace-relative.md>`；让替代规则优先，明确历史结果身份。引用绑定内容摘要，原文变化后要求重新检索。
- 提供工作区 `.assistant/entry/context.ps1` 薄入口；按需调用，不注册启动 Hook，不自动保存或提升记忆，不调用外部 Provider。
- 保留已关闭的 PreToolUse 和 Codex Hook 设置、现有用户开发准则及两份原暂存文件。无数据库操作、无全局权限扩大、无业务仓库改动。
- 本轮交付适配当前使用的 Codex；其他宿主对话格式不凭空添加。项目文档入口不依赖宿主。

## Implementation

1. **入口收敛**：quick-start、governed-work、Provider authority/boundary 与当前 v2 Runtime 对齐，说明 Direct / 按需 recall / Governed 的使用顺序。
2. **上下文读取**：实现统一 CLI、文档与 Codex 消息适配、排序/替代关系、摘录预算、摘要绑定 read；不使用缓存、索引服务或额外模型。
3. **分发接入**：在现有模块声明和安装 Profile 注册薄入口，更新对应生成目录；普通入口不自动执行检索。
4. **验证交付**：先验证检索行为和只读性，再跑相关入口/分发测试及要求的 core 回归；核对实际配置、原暂存文件和 diff，记录最终证据。

## Verification

- AC-1：当前指南不再把 v1 五阶段或 plan frontmatter 作为当前执行方式；已有 Direct 零任务产物测试通过。
- AC-2：中英文查询能在项目 Markdown 和显式启用的当前项目 Codex 消息中返回可追溯摘录；工具输出及其他项目对话不作为消息结果。
- AC-3：摘录总字符数和条数受预算限制；`read` 返回对应原文；内容漂移、无效来源或无效替代关系明确报错；检索前后源文件和运行时状态不变。
- AC-4：替代规则优先于旧规则；重复来源不重复输出；无结果明确返回空列表。
- AC-5：core/governed/full 安装均提供按需上下文薄入口，无新增 Hook 或外部 Provider；旧 Hook 关闭偏好和用户规则不变。
- AC-6：聚焦行为测试、相关分发/入口回归和 `scripts/run-validation.ps1 -Suite core` 均有真实退出码；未执行的宿主能力或性能对比明确记录 `not_run`。

性能评价分两层：本轮记录真实本地检索用时与输出预算；完整 Bare / Harness Direct / mini 同模型同任务代理对比作为后续独立实验，未测前不声明速度或费用提升。对方作者的 Trellis 对比数字不作为本项目验收数据。

## Rollback

仅回退本次新增 CLI、薄入口、文档及声明变更，并重新生成目录。保留现有用户文件、历史任务与失败证据；不 reset/stash/clean 工作区，不重开 Hook。安装更新沿用现有备份与事务机制。

## Execution record

- 计划已制定，实施与验证进行中。最终结果在本节补充。
