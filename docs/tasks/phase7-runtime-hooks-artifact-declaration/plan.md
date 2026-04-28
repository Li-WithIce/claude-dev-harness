---
task_id: phase7-runtime-hooks-artifact-declaration
stage: PLAN
tool: claudecode
updated: 2026-04-28
---
# Phase 7 运行时挂钩与艺术品声明（4 条 TODO）

## Clarification

- 验收标准:
  1. 落地路线图 `docs/tasks/workflow-optimization-roadmap/plan.md` 中 Phase 7 段的 4 条 TODO（precompact-checkpoint-hook / phase-loading-large-skills / plan-artifacts-declaration / precompact-mutex-protocol），不多不少
  2. P7-T1 必须以「协议条款 + leader/worker 自检」形式落地，**不引入新 daemon、不引入注册到 Claude Code 内核的 hook**；hook 行为限定为「context 临近上限时主动把 pending wisdom 先以 inbox append 形式提交到 `.assistant/运行时/收件箱.md`，再按需调用 advance-stage 落盘当前进度」；禁止手工 rewrite/delete vault 文件，非 append 写回只能委托现有 `advance-stage.ps1` 按既定语义执行
  3. P7-T2 必须先做「现状盘点」：路线图原文以「≥ 600 行 SKILL.md」为拆分阈值，但截至 2026-04-28 现场，6 个 SKILL.md（`workflow-team` 48 / `implement` 62 / `obsidian-memory` 80 / `review` 97 / `orchestrator` 122 / `plan` 162）全部远低于该阈值，**没有任何 skill 满足 600 行触发条件**；P7-T2 已裁定为 **lazy 守则 only**（详见 Risks 已裁定 1），仅在 `skills/orchestrator/references/lite-writing-guide.md` 末尾追加守则段，不创建任何 `skills/*/phases/` 目录、不新建独立守则文档；不得把"拆分行为"硬编码为 IMPLEMENT 必做项
  4. P7-T3 必须把 `- artifacts: [path1, path2, ...]`（inline-array）注册为 plan.md `## Plan` 段顶部 metadata-style 的可选字段（与 Phase 6 P6-T2 已裁定的 `read_first:` / `convergence:` 同位风格），validator 仅做语法校验：(a) 若出现必须 inline-array；(b) 字段缺省视为合法；(c) 不做 path 存在性校验、不做交叉引用校验（reviewer 抽查范畴）
  5. P7-T4 必须先于（或与 P7-T1 同 commit）落地：新建 `docs/工作流/single-writer-precompact.md`，固化 PreCompact 自检与 vault 单写者契约的兼容协议（核心约束：对于 wisdom 路径只允许 append 到 `运行时/收件箱.md`；若触发 stage 推进，必须先持有推进锁并把非 append 写回委托给现有 `advance-stage.ps1`；获取失败时 cooperative-yield 给正在写入的 advance-stage 流程）；若 P7-T1 先于 P7-T4 commit，验收 FAIL
  6. 4 条 TODO 互相之间通过 dependency 排序：P7-T4 → P7-T1（mutex 必须先于 hook），P7-T2 与 P7-T3 互相独立、与 T1/T4 也独立
  7. 严守 vault-as-truth-source / 单写者 / git 可审三条根约束；不引入 dashboard、不引入 sqlite、不引入 vector embedding、不引入第二套并行 runtime、不引入 chain_loader / FlowExecutor / QueueScheduler、不引入 SessionStart / Stop / UserPromptSubmit 等其他 hook 类型
  8. 不重开 Phase 5 / Phase 6 任何 TODO 的实现，不重开 workflow-alignment（Phase 1-4）/ shared-memory-v2 / live-migration 主线；本任务 IMPLEMENT 期间禁止修改 `.assistant/运行时/记忆-{学习,决策,约定,问题}.md`（Phase 6 P6-T3 产物）的 schema
  9. validator `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId phase7-runtime-hooks-artifact-declaration` 必须 PASS

- 非目标:
  - 不引入 CCW 的 SessionStart / Stop / UserPromptSubmit / Soft Enforcement Stop（B4）等其他 hook 类型；只复用 PreCompact 单一检查点
  - 不引入中央 artifact registry 服务、不引入 maestro `state-schema.ts` / `templates/task.json` 之类的 TS 数据层
  - 不实现 chain_loader / FlowExecutor / QueueScheduler / WaveExecutor / SessionPool / PTY pool 等 runtime 组件
  - 不允许 hook 修改 vault 文件之外的任何外部状态（保持 vault-as-truth-source）
  - 不引入新 frontmatter 字段（`artifacts:` 是 `## Plan` 段 metadata，不进 frontmatter）
  - 不强制现有任务回填 `artifacts:`（仅 opt-in；validator 默认行为兼容旧格式）
  - 不修改 stage 拓扑（仍是 PLAN → PLAN_REVIEW → IMPLEMENT → CODE_REVIEW → TEST → DONE）
  - 不修改 Phase 6 已裁定的 P6-T1/T2/T3/T4 任何范围
  - 不强制实质拆分任何 SKILL.md（P7-T2 已裁定为 lazy 守则 only，见 Risks 已裁定 1；现场无 ≥600 行候选）
  - 不修改 `agent-configs/profiles/*.yaml` 与 `agent-configs/workflows/harness-lite.yaml` 实体字段（P7-T1 / P7-T4 协议条款只进 SKILL.md 与 docs/工作流/）

- 受影响目录:
  - `scripts/validate-lite-artifacts.ps1`（P7-T3：扩展 `Assert-PlanContract` 接受 `## Plan` 段顶部 metadata-style 的 `- artifacts: [path1, path2, ...]`；既有 23 项 check 全保留；与 Phase 6 P6-T1 `-Quality` switch 解耦）
  - `skills/orchestrator/SKILL.md`（P7-T1：新增「PreCompact 自检条款」段；不替换既有段落）
  - `skills/workflow-team/SKILL.md`（P7-T1：新增「leader→worker PreCompact 透传与 callback」段；不替换既有段落）
  - `skills/plan/SKILL.md`（P7-T3：在推荐骨架段新增 `## Plan` 顶部 metadata 块的 `artifacts:` 可选字段示例与语法说明，紧跟 P6-T2 的 `read_first:` / `convergence:` 段落之后）
  - `skills/orchestrator/references/lite-writing-guide.md`（P7-T3：同步 `artifacts:` 字段说明，避免规范二源漂移）
  - `docs/工作流/single-writer-precompact.md`（P7-T4：新建文件；与 Phase 6 P6-T4 `quality-rubric.md` 同级，复用 `docs/工作流/` 目录）
  - `docs/tasks/phase7-runtime-hooks-artifact-declaration/plan.md`（本文档）
  - 注：P7-T2 已裁定为 lazy 守则 only（见 Risks 已裁定 1），实际受影响路径仅 `skills/orchestrator/references/lite-writing-guide.md` 末尾追加守则段，不动任何 SKILL.md 实体段、不创建任何 `skills/*/phases/` 目录、不新建独立守则文档；该路径已在上方 P7-T3 行中列入 affected_paths，无重复登记

- 回滚策略:
  - 4 条 TODO 全部独立 commit；任意一条可独立 `git revert` 而不影响其他三条（除 P7-T4 → P7-T1 依赖：若 P7-T1 已 commit 而 P7-T4 单独 revert，必须同时 revert P7-T1）
  - P7-T1 协议条款 revert 即让 leader/worker 行为回到 advisory-only（hook 不会真触发，只是缺少自检文档）
  - P7-T2 已固定为选项 A（lazy 守则 only）；revert 等同于删除 `lite-writing-guide.md` 末尾新增守则段
  - P7-T3 schema 扩展未启用时 validator 全 PASS；回滚等同于「保留字段定义、停止建议使用」（与 P6-T2 同款 lazy-revert 策略）
  - P7-T4 文档独立删除；P7-T1 因依赖 P7-T4，应在同 commit 或前置 commit revert
- ui: not-applicable

## User Confirmation
- status: draft

## Change Contract
- change_type: enhance
- affected_paths:
  - scripts/validate-lite-artifacts.ps1
  - skills/orchestrator/SKILL.md
  - skills/workflow-team/SKILL.md
  - skills/plan/SKILL.md
  - skills/orchestrator/references/lite-writing-guide.md
  - docs/工作流/single-writer-precompact.md

## Plan

### TODO P7-T1 — precompact-checkpoint-hook（协议条款 + leader/worker 自检，非内核 hook）

- 范围:
  - 在 `skills/orchestrator/SKILL.md` 新增「PreCompact 自检条款」段：定义 leader 在每个 stage callback 结束时必须做的 3 项 self-check：(a) 当前 context 占用是否 ≥ 配置阈值（默认 0.85，可由 leader 主观判断；不引入硬编码读取 token 计数器，避免与具体宿主耦合）；(b) 是否有 pending wisdom 条目尚未 commit 到 `.assistant/运行时/记忆-{学习,决策,约定,问题}.md`；(c) 当前 task 是否处于可推进 stage（plan.md frontmatter 的 stage 是否为 `PLAN_REVIEW` / `CODE_REVIEW` / `IMPLEMENT` 且 verdict / Implementation Notes 已就绪）
  - 在 `skills/workflow-team/SKILL.md` 新增「leader→worker PreCompact 透传与 callback」段：leader 在调用 `team_send_message` 派发 worker 任务时，应在消息体内附带「若你接近 context 上限，请先 append 当前 wisdom + 调用 advance-stage 把当前进度写入 plan.md，再 stand by」的协议提示；worker callback 中应在结束前自检（与 orchestrator 段 (b)(c) 同款）
  - 自检触发动作严格限定为：① 调用 `skills/obsidian-memory/scripts/append-runtime-inbox.ps1` 把 pending wisdom 以 append-only 形式落入 `.assistant/运行时/收件箱.md`，后续仍走仓库现有 `promote-runtime-inbox.ps1` / `triage-runtime-inbox.ps1` 路径分流；② 若处于可推进 stage，调用 `.assistant/entry/advance-stage.ps1` 推进；③ 不允许手工 rewrite/delete 或直接 patch plan/task-runtime/shared-pointer 文件；凡非 append 写回一律交由 `advance-stage.ps1` 按现有脚本语义执行
  - **必须先于 P7-T1 commit 落地 P7-T4 的 mutex 协议**：自检触发 ① ② 时必须按 `docs/工作流/single-writer-precompact.md` 协议 cooperative-yield，禁止与正在写入的 advance-stage 流程产生竞争
  - 不引入新脚本；不引入新 hook 注册点；不引入 token 计数器；不修改 `agent-configs/workflows/harness-lite.yaml` 实体字段
- 非目标:
  - 不实现 token 计数器或 context size 探测器（leader/worker 主观判断阈值即可）
  - 不引入 CCW 的 `recovery-handler.ts` 完整实现，只取「PreCompact 时主动 commit + advance」单点思路
  - 不引入 SessionStart / Stop / UserPromptSubmit / Soft Enforcement Stop 任何其他 hook 类型
  - 不允许自检触发手工 destructive mutate（任何 rewrite/delete/绕过脚本的直接 patch 均归 normal stage flow，不归 hook）
- affected_paths:
  - `skills/orchestrator/SKILL.md`
  - `skills/workflow-team/SKILL.md`
- 验证:
  - `Select-String -Path skills/orchestrator/SKILL.md -Pattern 'PreCompact 自检|cooperative-yield|context 临近上限'` 命中 ≥ 2 行
  - `Select-String -Path skills/workflow-team/SKILL.md -Pattern 'PreCompact|append-runtime-inbox|advance-stage'` 命中 ≥ 2 行
  - `Select-String -Path skills/orchestrator/SKILL.md skills/workflow-team/SKILL.md -Pattern 'docs/工作流/single-writer-precompact\.md'` 命中 ≥ 2 行（双向引用 P7-T4 文档）
  - `pwsh -NoProfile -Command "$docAdd = git log --diff-filter=A --reverse --format='%H' -- docs/工作流/single-writer-precompact.md | Select-Object -First 1; $skillFirst = git log --reverse --format='%H' -G 'PreCompact 自检|leader→worker PreCompact|single-writer-precompact' -- skills/orchestrator/SKILL.md skills/workflow-team/SKILL.md | Select-Object -First 1; if ([string]::IsNullOrWhiteSpace($docAdd) -or [string]::IsNullOrWhiteSpace($skillFirst)) { throw 'missing dependency commit(s)' }; if ($docAdd -ne $skillFirst) { git merge-base --is-ancestor $docAdd $skillFirst; if ($LASTEXITCODE -ne 0) { throw 'single-writer-precompact.md was introduced after P7-T1 skill changes' } }"` 必须 PASS
- 回滚: `git revert` 单条 commit；orchestrator / workflow-team SKILL.md 的「PreCompact 自检条款」段消失，行为回到 advisory-only
- 风险:
  - leader/worker 主观阈值判断不一致 → 自检触发频率参差。缓解：协议条款明确「宁触发不漏触发」（false positive 是 wisdom append + advance 一次，零副作用；false negative 是丢进度，代价大），鼓励偏保守
  - 自检触发 ① ② 时若与 advance-stage 主流程产生 race → 通过 P7-T4 mutex 协议规避；本 TODO 强依赖 P7-T4 已就位

### TODO P7-T2 — phase-loading-large-skills（≥ 600 行 SKILL.md 拆分守则；现状下无强制拆分对象）

- 范围:
  - **现状盘点（必写）**: 截至 2026-04-28，仓库内 6 个 SKILL.md 行数分别为 `workflow-team` 48 / `implement` 62 / `obsidian-memory` 80 / `review` 97 / `orchestrator` 122 / `plan` 162，**全部低于路线图原文 600 行阈值**；CCW `workflow-plan/SKILL.md` 触发 phases/ 拆分时是 ~700+ 行，本仓库尚无对应规模的 skill。路线图把「拆分 ≥ 600 行 skill」写成动作型 TODO 与现状不匹配，IMPLEMENT 时不得把拆分行为硬编码为 mandatory
  - **已裁定实现路径**: 固定采用选项 A（lazy 守则 only）。只在 `skills/orchestrator/references/lite-writing-guide.md` 末尾追加「SKILL.md 拆分守则」段，记录：(a) 触发阈值 600 行；(b) 未来一旦触发，拆分形态应为主 SKILL.md ≤ 200 行 + `phases/<phase>.md` 子文件；(c) 主 SKILL.md 顶部必须有「何时加载哪个 phase」导航段；(d) 拆分前后 git diff 行数差应 ≈ 0（不允许借机重写内容）
- 非目标:
  - 不强制把任何当前 SKILL.md 拆分（现状无候选）
  - 不引入新的 skill 注册机制
  - 不修改 SKILL.md frontmatter
  - 不实现自动行数检查脚本（人工守则 + 后续任务抽查即可）
- affected_paths:
  - `skills/orchestrator/references/lite-writing-guide.md`
- 验证:
  - `Select-String -Path skills/orchestrator/references/lite-writing-guide.md -Pattern '600|phases/|SKILL\.md 拆分守则'` 命中 ≥ 3 行
  - `Get-ChildItem skills -Recurse -Directory -Filter phases | Measure-Object | Select-Object -ExpandProperty Count` 必须为 `0`
- 回滚: `git revert` 单条 commit；删掉 `lite-writing-guide.md` 末尾守则段即可
- 风险:
  - 路线图阈值「600 行」与本仓库现状脱节；IMPLEMENT 若忽视现状盘点会做出"拆分 162 行 plan/SKILL.md"这种过度工程行为。缓解：本 TODO 范围段已写明现状 + 强约束「不得把拆分硬编码为 mandatory」；reviewer 必须按现状盘点抽查
  - 守则若散落到第二份独立文档会产生 cross-reference 漂移。缓解：已固定只收口到 `lite-writing-guide.md` 单一权威位置，不再保留 A/B/C 分支

### TODO P7-T3 — plan-artifacts-declaration（plan.md `## Plan` 段顶部 metadata-style 可选字段）

- 范围:
  - 扩展 validator 的 `Assert-PlanContract`：plan.md `## Plan` 段允许（可选）以 `- artifacts: [path1, path2, ...]`（inline-array 语法）声明本任务产出的所有 artifact 路径
  - **schema 位置已与 Phase 6 P6-T2 对齐**：`artifacts:` 必须出现在 `## Plan` 段标题之后的顶部 metadata 块中（紧跟 P6-T2 已裁定的 `read_first:` / `convergence:` 同位置），即在第一条普通 `- TODO …` bullet 之前；validator 必须把"位置不在 metadata 块"列为格式错误
  - validator 仅做语法校验：(a) `artifacts:` 若出现必须 inline-array；(b) 字段缺省视为合法；(c) 字段值至少 1 条非空字符串（若为空数组 `[]` 视为格式错误）；(d) 不做 path 存在性校验、不做交叉引用校验（reviewer 抽查范畴，避免与 P6-T2 `read_first:` 同款 path-non-existence 兼容性破坏）
  - 在 `skills/plan/SKILL.md` 推荐骨架段新增 1 段说明 + 示例（紧跟 P6-T2 的 `read_first:` / `convergence:` 段落）
  - 在 `skills/orchestrator/references/lite-writing-guide.md` 同步追加 1 段
  - 不引入新 frontmatter 字段；不修改既有 23 项 check；不修改 P6-T2 行为
- 非目标:
  - 不强制现有 19+ 任务回填 `artifacts:`（仅 opt-in）
  - 不做 path 存在性校验（artifact 可能是计划中即将创建的路径）
  - 不引入中央 artifact registry（与 maestro `state-schema.ts` 隔离）
  - 不做与 affected_paths 交叉验证（artifacts 是产出声明，affected_paths 是变更面声明，语义不重合）
  - 不引入 nested YAML（如 `artifacts: { paths: [...] }`）；只用 inline-array
  - 不为 `artifacts:` 提供执行器或自动生成工具
- affected_paths:
  - `scripts/validate-lite-artifacts.ps1`
  - `skills/plan/SKILL.md`
  - `skills/orchestrator/references/lite-writing-guide.md`
- 验证:
  - 用临时 fixture（`## Plan` 段顶部含合法 `- artifacts: [a/b.md, c/d.ps1]`）跑 validator 必须 PASS
  - 用 fixture（`artifacts:` 写成 block-list `- a\n- b` 而非 inline）跑 validator 必须 FAIL 并提示"artifacts 必须 inline-array"
  - 用 fixture（`artifacts: []` 空数组）跑 validator 必须 FAIL
  - 用 fixture（`artifacts:` 出现在 `## Plan` 段非顶部位置，被普通 bullets 隔开）跑 validator 必须 FAIL 并提示"位置不在顶部 metadata 块"
  - zero-regression baseline 集合（2026-04-28 现场快照：13 个 plan.md 中 9 个 PASS，均无 `artifacts:`）跑 validator 后 PASS 集合不变；4 个既存 FAIL 也保持 FAIL（验证语义而非计数）
  - `Select-String -Path skills/plan/SKILL.md skills/orchestrator/references/lite-writing-guide.md -Pattern 'artifacts:'` 命中 ≥ 2 行
- 回滚: `git revert` 单条 commit；validator 与两处文档同步退回；任何已写入 `artifacts:` 的 plan.md 仍合法（validator 不读它也不报错）
- 风险:
  - `artifacts:` 与 IMPLEMENT 实际产出脱钩 → 沦为摆设。缓解：本 plan 已在路线图来源段标注「reviewer 必须按 artifacts: 抽查实际 git diff 是否覆盖声明列表」，落入后续 review 任务承担
  - `artifacts:` 与 `affected_paths`（Change Contract 字段）语义混淆。缓解：plan/SKILL.md 与 lite-writing-guide.md 必须给出区分示例（`artifacts:` = 任务产出物声明、长生命周期；`affected_paths:` = 本次 PR 变更面、commit-level）

### TODO P7-T4 — precompact-mutex-protocol（hook 与 vault 单写者契约的兼容协议文档）

- 范围:
  - 新建 `docs/工作流/single-writer-precompact.md`（与 Phase 6 P6-T4 `quality-rubric.md` 同级，复用 `docs/工作流/` 目录）
  - 文档结构（共 5 节）：① **背景**（vault-as-truth-source / 单写者契约 / advance-stage 推进锁现状回顾，引用 shared-memory-v2 contract）；② **PreCompact 自检触发的 2 类动作**（`append-runtime-inbox.ps1` 承载 pending wisdom append / `advance-stage.ps1`）；③ **mutex 协议**（核心规则：hook 触发动作必须先尝试 acquire 推进锁；若获取失败必须 cooperative-yield，最多重试 N 次后改 stand-by 等待 stage 完成；append-only 仅适用于 `运行时/收件箱.md`，凡非 append 写回必须通过 `advance-stage.ps1` 既有语义执行）；④ **失败模式与降级**（acquire 超时 / advance-stage 中途失败 / inbox append 已写入但 stage 未推进的处理）；⑤ **与 P7-T1 的双向引用契约**（`skills/orchestrator/SKILL.md` 与 `skills/workflow-team/SKILL.md` 必须显式 link 到本文档；本文档必须显式 link 回这两个 skill）
  - 文档语言以中文为主，关键术语保留英文（`cooperative-yield` / `single-writer` / `advance-stage`）以与已有契约文档对齐
  - 文档总行数 ≤ 200 行（参考 P6-T4 quality-rubric.md ≤ 250 行约束，本文档语义更窄，更紧凑）
  - **必须先于（或与）P7-T1 同 commit 落地**；若 P7-T1 commit 早于本文档，验收 FAIL（在 Verification 段强约束）
- 非目标:
  - 不引入新脚本（不实现 lock 文件 / lockfile-based mutex）
  - 不修改 advance-stage.ps1（mutex 在协议层落地，不在脚本层）
  - 不修改 shared-memory-v2 contract（仅引用）
  - 不引入 hook 监控 / 日志 / 告警（保持 cooperative）
- affected_paths:
  - `docs/工作流/single-writer-precompact.md`（新建）
- 验证:
  - `Test-Path 'docs/工作流/single-writer-precompact.md'` 必须为 True
  - `Get-Content docs/工作流/single-writer-precompact.md | Measure-Object -Line` 总行数 ≤ 200
  - `Select-String -Path docs/工作流/single-writer-precompact.md -Pattern 'cooperative-yield|single-writer|advance-stage'` 命中 ≥ 3 行
  - `Select-String -Path docs/工作流/single-writer-precompact.md -Pattern '## .{1,30}'` 必须命中 ≥ 5 个二级标题（对应文档结构 5 节）
  - `Select-String -Path docs/工作流/single-writer-precompact.md -Pattern 'skills/orchestrator/SKILL\.md|skills/workflow-team/SKILL\.md'` 命中 ≥ 2 行（双向引用契约第 ⑤ 节）
  - `pwsh -NoProfile -Command "$docAdd = git log --diff-filter=A --reverse --format='%H' -- docs/工作流/single-writer-precompact.md | Select-Object -First 1; $skillFirst = git log --reverse --format='%H' -G 'PreCompact 自检|leader→worker PreCompact|single-writer-precompact' -- skills/orchestrator/SKILL.md skills/workflow-team/SKILL.md | Select-Object -First 1; if ([string]::IsNullOrWhiteSpace($docAdd) -or [string]::IsNullOrWhiteSpace($skillFirst)) { throw 'missing dependency commit(s)' }; if ($docAdd -ne $skillFirst) { git merge-base --is-ancestor $docAdd $skillFirst; if ($LASTEXITCODE -ne 0) { throw 'single-writer-precompact.md was introduced after P7-T1 skill changes' } }"` 必须 PASS（确保依赖顺序）
- 回滚: 删除 `docs/工作流/single-writer-precompact.md`；若 P7-T1 已落地，必须同步 revert P7-T1（依赖被破坏）
- 风险:
  - 协议层 mutex 没有强制力（无 lockfile / 无 OS lock）；依赖 leader/worker 自律。缓解：协议条款明确「acquire 失败必须 cooperative-yield」+ 后续 review 抽查
  - 文档若与 shared-memory-v2 contract 内容重叠会产生二源漂移。缓解：本文档只描述 PreCompact 场景下的 mutex 适配，不重复 contract 主体；显式引用 contract 路径

## Verification

- `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId phase7-runtime-hooks-artifact-declaration`
- `git diff --stat HEAD~1 -- scripts/ skills/ docs/工作流/`
- `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern 'artifacts'`
- `Select-String -Path skills/plan/SKILL.md skills/orchestrator/references/lite-writing-guide.md -Pattern 'artifacts:'`
- `Select-String -Path skills/orchestrator/SKILL.md skills/workflow-team/SKILL.md -Pattern 'PreCompact|cooperative-yield'`
- `Test-Path 'docs/工作流/single-writer-precompact.md'`
- `Get-Content docs/工作流/single-writer-precompact.md | Measure-Object -Line`
- `pwsh -NoProfile -Command "$docAdd = git log --diff-filter=A --reverse --format='%H' -- docs/工作流/single-writer-precompact.md | Select-Object -First 1; $skillFirst = git log --reverse --format='%H' -G 'PreCompact 自检|leader→worker PreCompact|single-writer-precompact' -- skills/orchestrator/SKILL.md skills/workflow-team/SKILL.md | Select-Object -First 1; if ([string]::IsNullOrWhiteSpace($docAdd) -or [string]::IsNullOrWhiteSpace($skillFirst)) { throw 'missing dependency commit(s)' }; if ($docAdd -ne $skillFirst) { git merge-base --is-ancestor $docAdd $skillFirst; if ($LASTEXITCODE -ne 0) { throw 'single-writer-precompact.md was introduced after P7-T1 skill changes' } }"`
- 语义判据：第 1 条 validator 必须 PASS（0 Errors）；第 2 条 git diff 必须只覆盖本 plan 列出的 affected_paths（无任何 `docs/tasks/<其他>/`、`agent-configs/profiles/`、`agent-configs/workflows/`、`.assistant/运行时/记忆-*.md` 改动）；第 3 条命中 ≥ 1 行（确认 artifacts 字段校验落地）；第 4 条命中 ≥ 2 行（plan/lite-writing-guide 均覆盖）；第 5 条命中 ≥ 2 行（PreCompact 协议在两处 SKILL.md 落地）；第 6 条 True；第 7 条总行数 ≤ 200；第 8 条命令必须 PASS，证明 `single-writer-precompact.md` 的 add commit 不晚于首次引入 P7-T1 skill 条款的 commit

## Risks

- 4 条 TODO 之间存在硬依赖：P7-T4（mutex 协议文档）必须先于或与 P7-T1（PreCompact 自检）同 commit 落地，否则自检触发动作可能与 advance-stage 流程产生 race；IMPLEMENT 建议 commit 顺序 P7-T4 → P7-T1 → P7-T3 → P7-T2
- P7-T1 是协议性质（leader/worker 自律），不是注册到 Claude Code 内核的 hook；如果未来 Claude Code 提供原生 PreCompact API，需要单独评估迁移成本（不在本任务范围）
- P7-T2 现状盘点显示无 SKILL.md ≥ 600 行触发阈值，路线图原文与现场脱节；本 plan 已固定采用选项 A（lazy 守则 only），避免把拆分 162 行 skill 这类过度工程重新拉回实现面
- P7-T3 的 `artifacts:` 与 IMPLEMENT 实际产出脱钩仍是开放问题；本 plan 通过 reviewer 抽查条款做缓解，但若 reviewer 不真做抽查，字段会沦为装饰；接受此风险，进一步执行抽查由后续 review 任务承担
- P7-T4 mutex 协议无强制力（无 lockfile / 无 OS lock），依赖自律；如未来出现频繁 race，需单独任务评估是否引入 lockfile（本 Phase 不引入）
- validator 改造（P7-T3）的 PowerShell 实现已限定 v7（与 Phase 6 P6-T1 同基线）；若未来需支持 v5 环境，单独评估
- 本任务严守 vault-as-truth-source / 单写者 / git 可审；不引入 dashboard、sqlite、vector embedding、second runtime；与路线图暂缓清单一致

- 已裁定 1（P7-T2 路径选择）：选项 **A — lazy 守则 only**。仅在 `skills/orchestrator/references/lite-writing-guide.md` 末尾追加「SKILL.md 拆分守则」段（含 600 行阈值 + 主 SKILL.md ≤ 200 行 + `phases/<phase>.md` 形态 + git diff 行数差 ≈ 0），**暂不创建任何 `skills/*/phases/` 目录、不新建独立 `docs/工作流/skill-phase-loading.md`**。理由：截至 2026-04-28 现场 6 个 SKILL.md 行数全部 ≤162（最大 `skills/plan/SKILL.md`），远低于 600 行阈值；选项 B 强制拆分 162 行 skill 构成无收益复杂度；选项 C 多一层文档维护且与 `lite-writing-guide.md` 已有 plan 写作规范地位重叠。IMPLEMENT 时 P7-T2 的 changed 字段必须显式写"采用选项 A"；不得创建 `skills/*/phases/`；不得新建 `docs/工作流/skill-phase-loading.md`
- 已裁定 2（P7-T1 「context 临近上限」判断口径）：采用 **主观口径** — leader/worker 凭经验主观判断当前 context 占用是否临近上限，**不引入半量化探测、不调用 hosted runtime 的 token usage 接口、不引入 token 计数器**。理由：当前没有稳定且可信的 context 剩余度 API，半量化规则容易制造伪精确与误触发；本 phase 先固化协作协议，不把判断器做成隐藏控制面（与 vault-as-truth-source / git 可审一致）。IMPLEMENT 时 `skills/orchestrator/SKILL.md` 自检条款必须明确"主观判断、宁触发不漏触发"，不得引入任何自动探测代码或脚本
- 已裁定 3（P7-T3 与 P6-T2 schema 字段相对顺序）：`## Plan` 段顶部 metadata 块字段顺序固定为 **`read_first:` → `convergence:` → `artifacts:`**。理由：沿用 P6-T2 已落地的「先读什么 → 怎么算完成」语义入口，把"产出什么"声明置于其后，既保留任务入口可读性，也让 validator 与作者按一致顺序遵循；按字典序或出现频率排序会破坏与 P6 已交付契约的语义一致性。IMPLEMENT 时 P7-T3 范围段已隐含此顺序约束（详见 P7-T3 范围中的 schema 位置说明），`skills/plan/SKILL.md` 推荐骨架示例必须按此顺序展示，validator 不强制顺序（仅强制位置在顶部 metadata 块）但文档与 lite-writing-guide.md 必须按此顺序示范

## Plan Review

## Implementation Notes

## Code Review
