---
name: gemini-designer-main
description: Use when Gemini is the selected TEST runner and the current task needs a read-only, evidence-based test.md with a pass, fail, or blocked conclusion.
---

# Gemini Test Runner

Gemini-based TEST runner。只在当前 tool profile 或 handoff 选择 Gemini 执行 TEST 时使用。

本 skill **不替代** `test` skill 的 TEST 方法论；它是建立在 `test` 之上的 runner-specific overlay。换句话说：

- `test` 负责定义 TEST stage 的通用协议
- `gemini-designer-main` 负责把这套协议映射到 Gemini CLI 的只读审证流程

## When to Use

- 为当前任务生成或更新 `docs/<task-id>/test.md`
- 在 REVIEW 或 TEST loop-back 后重跑 TEST 结论
- 基于现有证据输出 `pass`、`fail` 或 `blocked`
- 当前 TEST binding 或 handoff 明确选择 Gemini 作为 runner

Do not use it for UI design, visual exploration, HTML generation, SVG work, or branding tasks.
不要用它来替代本地动态验证、补跑单测、直接修实现，或在 binding 未选择 Gemini 时抢占 TEST stage。

## Protocol Inheritance

执行本 skill 时，默认继承 `test` skill 的以下硬规则：

- 先读当前任务上下文，再进入 TEST
- **证据先于结论**
- `test.md` 的合法结论只能是 `pass`、`fail`、`blocked`
- `test.md` 必须满足统一输出契约
- 证据不足时只能给出 `blocked`，不能把缺证据误报成 `pass`

本 skill 只补充 Gemini runner 特有规则，不放宽以上要求。

## Entry and Context

如果 `.assistant/orchestration/current-flow.md` 存在：

1. 先读取 `stage`、`entry_tool`、`tool_profile_id`、`tool_bindings`、`fallback_policy`
2. 只在以下条件满足时继续：
   - 当前 stage 是 `TEST`
   - 或 handoff 明确要求本 skill 产出 / 更新当前任务的 `test.md`
   - 当前 TEST binding 或 handoff 明确选择 Gemini
3. 如果当前 stage 不是 `TEST`、binding 指向别的 runner、或 tool profile 缺失，停止本 skill 并回到 orchestrator
4. 优先收集当前任务的 `spec.md`、`plan.md`、`review.md`、`implementation-notes.md`、已有测试日志和证据包
5. 若 `.qoder/repowiki/zh/content` 存在，可按需加入与当前任务相关的目录说明、模块关系和依赖说明，用于补全测试矩阵与回归范围

## Gemini-specific Rules

- Windows 上优先通过 `scripts/ask_gemini.ps1` 走原生 Gemini CLI
- `scripts/ask_gemini.sh` 只作为 bash / bridge fallback
- 通过 `--file` 传入当前任务 artifacts；不要让 Gemini 自己猜输入
- Gemini 不得虚构命令、测试结果或证据；证据不足时结论必须是 `blocked`
- Gemini 负责的是**只读审证与报告生成**，不是本地测试总控；如果当前任务需要先补跑命令、截图、日志或动态恢复演练，应先由本地 TEST runner 或上游证据收集步骤完成
- 尽量把原始证据和简洁的证据摘要一起传给 Gemini：既给 `spec/plan/review`，也给命令输出、日志、截图说明或实现说明
- RepoWiki 适合帮助 Gemini 推导测试矩阵、边界条件和回归范围，但**不是真理源**；最终断言仍必须以代码、接口契约和真实测试输出为准
- 执行后必须读取 `output_path` 并校验报告契约
- 是否 fallback、fallback 给谁，都服从当前 orchestrator / tool profile，而不是本 skill 自己决定

## Adapted Verification Flow

相对于 `test` skill 的 `IDENTIFY -> RUN -> READ -> VERIFY -> CLAIM`，本 skill 的 Gemini 版流程是：

1. **IDENTIFY**：从 `spec`、`plan`、`review` 中提取验证点与预期结果
2. **CHECK EVIDENCE**：确认输入包中是否已经包含对应的 RUN/READ 证据；如果没有，不能把 Gemini 分析当作真实执行
3. **PACKAGE**：把任务 artifacts、原始证据、已知缺口整理成传给 Gemini 的文件集合
4. **EXECUTE**：用 `ask_gemini.ps1` 或 `ask_gemini.sh` 执行只读分析
5. **VALIDATE**：回读 `output_path`，检查 `test.md` 结构与 `pass|fail|blocked` 结论是否合法
6. **CLAIM**：只有当 Gemini 结论和输入证据一致、且契约合法时，才接受这份 `test.md`

## Common Mistakes

- 让 Gemini 自己猜当前任务输入，而不是显式传 `--file`
- 没有任何 RUN/READ 证据，却希望 Gemini 直接给 `pass`
- 把 Gemini 当作本地测试执行器，期望它替代单测、集成测试或恢复演练
- 已有 `review.md` / `implementation-notes.md` / 证据日志，却没有一并传给 Gemini
- 接受了格式非法或结论非法的 `test.md`，没有先做输出契约校验
- 把 RepoWiki 页面直接当成实现真相，忽略源码或真实执行证据

## References

- Shared TEST protocol: `test` skill
- CLI usage and example commands: [references/cli-usage.md](references/cli-usage.md)
- Output contract and invalid-output rules: [references/output-contract.md](references/output-contract.md)
