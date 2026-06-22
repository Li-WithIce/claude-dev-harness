---
task_id: trellis-comparison-reusable-design
artifact: trellis-source-based-corrections
updated: 2026-06-22
status: draft
source_snapshot: D:/data/Trellis-main @ 2026-06-18
relation: follow-up correction to trellis-reusable-design.md
---
# Trellis 对比：基于真实源码的事实修正与差距补强

## 0. 本文定位

- **关系**：本文是 `trellis-reusable-design.md` 的 follow-up 修正，**不改写其任何结论**；原文档的 adopt/adapt/defer/reject 分类与「不引入 `.trellis/`」主张继续有效。
- **修正理由**：原文档自声明「本轮只把公开文档作为输入来源，不把其实现细节写入本仓库协议」，其第 2 节机制对照表因此**基于公开网页**而非源码。本文基于本地真实源码 `D:/data/Trellis-main`（快照 2026-06-18）复核，补两处被低估 / 漏识别的机制。
- **事实边界**：只读 Trellis 源码、不修改；dev-harness 侧事实均为本会话直接读取 / 运行验证。

## 1. 源码事实快照

| 项 | 事实 | 证据 |
|---|---|---|
| 形态 | 公司开源产品 `@mindfoldhq/trellis`（Mindfold），AGPL-3.0，npm 分发 | `README.md`、`package.json` |
| 规模 | pnpm monorepo（`packages/cli` + `packages/core`），240 TS/JS + 71 Python + 920 MD | 顶层 `ls`、`pnpm-workspace.yaml` |
| 多平台 | 一套 `.trellis/` 适配 16 个平台（`.claude` / `.codex` / `.cursor` / `.gemini` / `.opencode`…） | README「16 AI coding platforms」、顶层平台目录 |
| 三层架构 | workflow 层（`.trellis/workflow.md`）/ persistence 层（tasks + spec + workspace）/ platform 集成层（hooks + agents + skills + commands） | `local-architecture/overview.md` |
| 运行时 | Node≥18 + Python≥3.9；`.trellis/scripts/` Python + 平台 hooks | README Prerequisites、`core/overview.md` |
| 升级机制 | `.trellis/.template-hashes.json` 比对模板哈希，检测用户本地改动 | 顶层 `.trellis/.template-hashes.json`（33KB） |
| 代码智能 | 集成 GitNexus（14178 symbols / impact / execution flows） | `Trellis-main/CLAUDE.md` |

## 2. 对原机制对照表的两处核心勘误

### 勘误 A：上下文注入是**运行时引擎**，不只是「context 分类」

原文档（A2）把 Trellis 上下文系统理解为 global / workspace / task / session 的**分类口径**，建议 dev-harness 复用为「写作规则」。**源码显示这低估了一层**：Trellis 有一套**主动注入的运行时**。

源码事实（`local-architecture/context-injection.md`）：

- 注入由 `.trellis/scripts` + 平台 hooks 共同实现，目标是「让 AI 在正确时机读正确文件，而非依赖模型记忆」。
- `session-start` hook：session 启动 / clear / compact 时注入 workflow 摘要 + 当前 task + active tasks + spec index + developer identity + git status。
- `workflow-state`：每个 user turn 按 task 状态（`no_task` / `planning` / `in_progress` / `completed`）注入轻量 hint 块。
- `sub-agent context` 两种模式：**hook push**（agent 启动前由 hook 注入 jsonl 引用文件 + `prd.md` / `design.md` / `implement.md`）与 **agent pull**（agent 自读）。

**对 dev-harness 的含义**：dev-harness 的 `read_first:` 是**被动**靠 LLM 自觉读取的清单，缺「在正确时机主动注入」的运行时层。这是与 Trellis 之间最实的机制代差，原 A2 没有体现。

**修正定级**：从原 A2 的「adopt now（写作规则）」拆出一个**新的 adapt/defer 项**——注入引擎受 host（Codex / Claude）hook 能力限制，需单独评估可行性，不能简单归入「写作规则」。

### 勘误 B：task entity 比「轻量 metadata」更完整

原文档（B1）建议把 Trellis 任务实体做成「只含 requirement links / owner / branch / PR / parent / subtask 的 optional artifact」，定级 adapt。方向正确，但**源码显示 task entity 的成熟度被低估**。

源码事实（`core/tasks.md` 的 `task.json`）：字段含 `status` / `dev_type` / `priority` / `creator` / `assignee` / `branch` / `base_branch` / `worktree_path` / `current_phase` / `next_action[]` / `commit` / `pr_url` / `parent` / `children[]` / `relatedFiles` / `meta`（`meta` 直接预留 `linear_id` / `jira_ticket`）。配套 `task.py` CLI 实测子命令共 15 个（实读 `.trellis/scripts/task.py` argparse）：`create` / `add-context` / `validate` / `list-context` / `start` / `current` / `finish` / `set-branch` / `set-base-branch` / `set-scope` / `archive` / `list` / `add-subtask` / `remove-subtask` / `list-archive`，parent 列表显示子任务进度 `(planning) [2/3 done]`。

> ⚠️ 勘误（2026-06-22 复核）：`core/tasks.md` 与 `workflow.md` 文档提到的 `create-pr`（及 `init-context`）在 `task.py` argparse 实测**并不存在**——属 Trellis 自身的文档/实现漂移，PR 自动化尚停留在文档层。本文先前据 `core/tasks.md` 文档将 `create-pr` 列为已实现命令有误，特此更正。该实例同时印证 `discussion-meeting-notes.md` Q4 与「worktree + PR 自动化整体 defer」的结论。

**对 dev-harness 的含义**：原 B1 结论（做成 artifact、不进 frontmatter）依然成立且正确；但应在 B1 里明确：① `worktree_path` + `pr_url` 字段 + 文档层规划的 PR 自动化（注意 `create-pr` 命令实测未实现，见上方勘误）指向「多 agent 并行 + PR 自动化」方向，这是 dev-harness team mode 尚未覆盖的面；② `meta` 的 issue-tracker 预留是低成本高价值字段。

### 其他补强（非核心，简列）

- **阶段粒度**：Trellis 阶段是**多层粒度**——叙事层 4 步（README：Plan / Implement / Verify / Finish）、workflow 层 3 phase（`workflow.md`：Plan / Execute / Finish）、task action 层（`task.json.next_action`：implement / check / finish / create-pr）。dev-harness 是**单层扁平 5 stage**（PLAN / PLAN_REVIEW / IMPLEMENT / CODE_REVIEW / TEST）。原文档「阶段拓扑不改」结论成立，但应记录：dev-harness 的扁平模型在「可审 / 恢复」上更简单，Trellis 的多层在「叙事 / 路由 / 自动化」上更灵活。
- **spec 学习闭环**：`spec-system.md` + `trellis-update-spec` + workflow Phase 3.3 形成「实现中学到 → 自动晋升回 `.trellis/spec/`」闭环。dev-harness 的 `.assistant` 记忆晋升需人确认（原文档 C3 已 defer LLM wiki，方向一致；但应补记：Trellis 强的是**自动晋升 pipeline**，不是 wiki 目录）。
- **质量门方向相反**：Trellis `check` 是 sub-agent 自检自修（lint / type / test）；dev-harness 是独立、留痕、可否决的 PLAN_REVIEW / CODE_REVIEW run + 数值 rubric。**这一项 dev-harness 更严**，原文档未明确点出这是 dev-harness 的相对优势。

## 3. 整体差距分层（基于源码）

### 3.1 Trellis 领先的能力差距（值得借鉴）

1. 运行时上下文注入引擎（勘误 A）——**最大代差**。
2. 结构化 task entity + worktree / PR 自动化（勘误 B）。
3. 多 agent 编排：research / implement / check + channel / forum / workers + break-loop（证据：`.claude/agents/`、`skills/trellis-channel/references/{forum,workers}.md`、`skills/trellis-break-loop/`）。
4. spec 自动晋升闭环。
5. 多平台可移植（16 平台生成）。
6. 代码智能（GitNexus）+ 产品工程度（turbo / husky / pyright / 双语文档 / marketplace）。

### 3.2 dev-harness 有意为之的定位差异（非落后）

1. **单一真相源**：`plan.md` frontmatter 唯一 stage truth；Trellis 状态散在 `task.json.current_phase` + `.runtime/sessions/*` + workflow-state。恢复路径更干净——印证原文档 D1。
2. **更硬的质量门**：见 2. 其他补强第 3 点。
3. **append-only 审计留痕**：review / test run 逐条不可改。
4. **零依赖 + 贴合环境**：纯 PowerShell + 文件，中文母语，Windows 原生；Trellis 需 Node + Python。

> 差距本质：Trellis 把工作流**产品化 / 自动化 / 可移植**；dev-harness 把工作流**压成最小可审计文件协议**。多数「差距」是 dev-harness **故意不做**（dashboard / server-truth / 第二套 runtime 已在原文档 reject / defer）。

## 4. 对原「可复用方案 / 后续任务」的修正建议

| 原项 | 原定级 | 修正 |
|---|---|---|
| A2 context taxonomy | adopt now | **拆分**：分类口径仍 adopt（写作规则）；新增「主动注入引擎」为独立 adapt/defer（受 host hook 能力限制，需可行性评估） |
| B1 task entity | adapt | 维持；补记 `worktree_path` / `create-pr` / `meta(issue-tracker)` 三个高价值字段，关联 team mode |
| C3 LLM wiki | defer | 维持；但区分「wiki 目录（defer）」与「spec 自动晋升 pipeline（可单独评估 adapt）」 |
| 后续任务表 P1~P6 | — | 新增候选 `trellis-context-injection-feasibility`：评估 Codex / Claude host 能否做 phase-aware 注入，优先级建议 P2 |

## 5. 边界与免责

- 源码快照：`D:/data/Trellis-main` @ 2026-06-18；Trellis 上游可能演进，本文不追踪。
- 本文**只读**源码，不修改 Trellis；不修改 dev-harness 的脚本 / skills / validator / 安装资产。
- 本文为 follow-up artifact，**未纳入** `trellis-comparison-reusable-design` 的 Change Contract；是否升级为正式 task artifact 由后续决定。
- 本文不改写 `trellis-reusable-design.md` 的任何既有结论。
