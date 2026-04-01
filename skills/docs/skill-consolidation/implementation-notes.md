# Skills 体系融合 - Implementation Notes

> task_id: skill-consolidation
> 完成日期: 2026-03-14
> 总 TODO: 31 / 31 已完成

## 改了什么

### Phase 1：核心 skill 改写（12 TODO）

- **orchestrator SKILL.md**：新增唯一 governor 声明、并行分发规则、批量执行模式（3 TODO/批）、DONE 阶段 4 选项协议、using-superpowers 关系声明
- **orchestrator references/**：model-invocation.md 更新 DEV=Claude-first / TEST=Gemini-first runner 策略；artifact-contracts.md 增加 task_id/task_name 字段要求和 implementation-notes.md 必要交付物；runbook.md 修正 fix round 为 Claude-first；gates.md 和 state-templates.md 已验证一致无需修改
- **using-superpowers SKILL.md**：新增开发任务优先路由（current-flow.md 检测）、调用层级表（3 层）、开发流程 Red Flags（4 条）
- **spec SKILL.md**：模板增加 task_id/task_name；新增渐进式澄清、YAGNI 裁剪、分段验证
- **plan SKILL.md**：模板增加 task_id；TODO 模板增加精确文件路径、验证命令、TDD 提醒、Codex handoff；依赖章节增加并行分组表
- **implement SKILL.md**：核心原则从 4 条扩展到 8 条（新增 TDD 铁律、调试纪律、完成验证、反馈处理）；新增 implementation-notes.md 固定交付物；新建 references/tdd-protocol.md 和 references/debugging-protocol.md
- **review SKILL.md**：模板增加 task_id/task_name/输出路径；新增第 6 维度 Spec 合规检查；新增三维核查
- **test SKILL.md**：模板增加 task_id/task_name/Meta block；新增 5 步门控；Gemini 主测策略

### Phase 2：硬退役 11 个旧 skill（12 TODO）

- 11 个 skill 的 SKILL.md 全部替换为退役重定向：brainstorming → spec、writing-plans → plan、executing-plans → orchestrator+implement、dispatching-parallel-agents → orchestrator、finishing-a-development-branch → orchestrator、test-driven-development → implement、systematic-debugging → implement、verification-before-completion → implement+test、receiving-code-review → implement、requesting-code-review → review、subagent-driven-development → orchestrator+review
- writing-skills 目录审计完成：SKILL.md、persuasion-principles.md、anthropic-best-practices.md、examples/CLAUDE_MD_TESTING.md 中所有退役 skill 引用已更新（含 review 后修复的 Bad 示例中残留的旧路径）

### Phase 3：specialist skill 二级能力声明（4 TODO）

- frontend-design、mcp-builder、webapp-testing、claude-api 各添加"二级能力声明"段落

### Phase 4：镜像到 .codex/skills（5 TODO）

- 7 个核心 skill（含新建的 orchestrator 目录）、codex + gemini-designer-main、11 个退役 skill、4 个 specialist skill、writing-skills 全部镜像完成，diff 验证一致

### Phase 5：验收（1 TODO）

- AC-1 ~ AC-10 全部 PASS，无失败项

## 没改什么

- 退役 skill 目录下的非 SKILL.md 参考文件全部保留（如 test-driven-development/testing-anti-patterns.md、systematic-debugging/root-cause-tracing.md 等）
- codex 和 gemini-designer-main 的 SKILL.md 内容未做修改（兼容性例外）
- 非开发类 skill（algorithmic-art、brand-guidelines、canvas-design 等）不在本次改造范围
- render-graphs.js 中 `subagent-driven-development` 作为示例命令参数保留，不影响功能
- anthropic-best-practices.md 和 examples/CLAUDE_MD_TESTING.md 的 frontmatter `name: brainstorming` 保留（它们是参考/示例文件的历史 frontmatter）

## 风险点

1. **退役 skill frontmatter 触发概率**：虽然 description 以 `[已退役]` 开头极大降低了触发概率，但 skill 目录仍然存在，理论上仍可能被发现系统列出。当前通过 using-superpowers 的优先路由规则缓解
2. **codex/gemini-designer-main 路径依赖**：这两个 skill 在 .codex 中作为镜像占位，运行时仍依赖 .claude 路径，纯 .codex 环境下可能路径失效。已在 plan 文档中记录为已知限制
3. **persuasion-principles.md 是 SKILL.md 的近似副本**：writing-skills 目录下 persuasion-principles.md 内容与 SKILL.md 高度重复，两者都已更新，但未来维护时需注意同步

## Reviewer Watchouts

- 重点检查 orchestrator 的 runner 策略在 SKILL.md 正文与 5 个 references 之间的一致性（AC-7 已验证 PASS）
- 检查 implement 的 references/ 下两个新文件与正文的交叉引用是否完整
- 检查 writing-skills 中退役引用更新是否遗漏（review 后已修复 Bad 示例中残留的旧路径，grep 验证清零）
- 镜像一致性可用 `diff` 命令快速复查
