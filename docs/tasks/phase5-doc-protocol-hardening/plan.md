---
task_id: phase5-doc-protocol-hardening
stage: PLAN
tool: claudecode
updated: 2026-04-28
---
# Phase 5 文档与协议层最小补强（4 条 TODO）

## Clarification

- 验收标准:
  1. 落地路线图 `docs/tasks/workflow-optimization-roadmap/plan.md` 中 Phase 5 段的 4 条 TODO（auto-mode-propagation / todowrite-milestone-template / spec-keyword-frontmatter / long-session-recovery-checklist），不多不少
  2. 4 条 TODO 全部仅修改文档与协议条款；不动 `scripts/validate-lite-artifacts.ps1`、不动 `.assistant/entry/advance-stage.ps1`、不动任何 vault 4 层结构（`运行时/` `工作流/` `配置/` `记忆候选/`）
  3. 修改后的 skill SKILL.md 与 vault 文档在 git diff 中只追加新条款或新模板段，不删改既有契约（`PLAN/PLAN_REVIEW/IMPLEMENT/CODE_REVIEW/TEST` 推进协议、单写者约束、frontmatter 4 字段集合等保持不变）
  4. spec.md 新增的 `front_keywords:` 必须为 inline-array 语法（`[a, b, c]`），与 shared-memory-v2 已确立的 `derived_from:` 同款约束保持一致；现有 19 个任务目录无 spec.md，因此不存在 backward-compat 迁移负担
  5. workflow-team `--auto` 透传协议属于 leader → spawned member 的非交互意图传递；本任务不引入新脚本、不修改 `spawn-team.ps1` 实现，仅在 SKILL.md 与 `agent-configs/workflows/harness-lite.yaml` 文档段落里写明协议
  6. `.assistant/工作流/长会话恢复.md` 单文件 ≤ 200 行、纯中文、step-by-step；恢复触发词、读取顺序、worker callback 处理路径必须与 CLAUDE.md "恢复触发"段落 + `skills/obsidian-memory/` 中的 `恢复协议.md` 100% 一致（仅做汇编，不引入新协议）
  7. 验证命令 `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId phase5-doc-protocol-hardening` 必须 PASS

- 非目标:
  - 不扩到 Phase 6（quality score / read_first / convergence schema 扩展）或 Phase 7（PreCompact hook / phases 拆分 / artifacts 声明）
  - 不重开 workflow-alignment（Phase 1-4）、shared-memory-v2、live-migration 任何主线讨论
  - 不修改 validator schema、不修改 advance-stage 推进逻辑、不引入任何新 hook
  - 不引入 dashboard、server-as-truth-source、第二套并发 runtime
  - 不创建新 skill、不重命名既有 skill；只修改既有 4 个 SKILL.md（spec / plan / implement / review / workflow-team 中相关段落）+ 1 个新 vault 文档
  - 不修改 `agent-configs/profiles/*.yaml` 的 profile 定义（`harness-lite.yaml` 仅追加 auto-mode 协议条款，不动 stages / role / default_profile / skills_whitelist）
  - 不强制要求新任务必须填写 `front_keywords`（保持 opt-in，validator 也不做必填校验）

- 受影响目录:
  - `skills/workflow-team/SKILL.md`（新增 auto-mode 协议条款段）
  - `skills/plan/SKILL.md`（新增 TodoWrite milestone 模板段）
  - `skills/implement/SKILL.md`（新增 TodoWrite milestone 模板段）
  - `skills/review/SKILL.md`（新增 TodoWrite milestone 模板段）
  - `skills/spec/SKILL.md`（推荐结构段新增 optional `front_keywords:` frontmatter 示例）
  - `skills/orchestrator/references/lite-writing-guide.md`（同步说明 spec.md 可选 frontmatter，避免与 spec SKILL.md 漂移）
  - `agent-configs/workflows/harness-lite.yaml`（仅在文件顶部 YAML 注释段追加 auto-mode 透传协议说明；YAML 实体字段不动；不创建任何 sidecar 文档）
  - `.assistant/工作流/长会话恢复.md`（新建文件）
  - `docs/tasks/phase5-doc-protocol-hardening/plan.md`（本文档）

- 回滚策略: 4 条 TODO 全部为文档级追加；任意 commit 都可独立 `git revert` 而不影响其他 3 条；spec.md 新增的 `front_keywords:` 为 opt-in 字段，回滚等同"停止建议使用"；workflow-team auto-mode 协议回滚后，spawned member 行为退回当前默认（保守降级）；`.assistant/工作流/长会话恢复.md` 直接删除即可，CLAUDE.md 中的"恢复触发"段落仍为权威源
- ui: not-applicable

## User Confirmation
- status: draft

## Change Contract
- change_type: enhance
- affected_paths:
  - skills/workflow-team/SKILL.md
  - skills/plan/SKILL.md
  - skills/implement/SKILL.md
  - skills/review/SKILL.md
  - skills/spec/SKILL.md
  - skills/orchestrator/references/lite-writing-guide.md
  - agent-configs/workflows/harness-lite.yaml
  - .assistant/工作流/长会话恢复.md

## Plan

### TODO P5-T1 — auto-mode-propagation（workflow-team `--auto` 透传协议）

- 范围:
  - 在 `skills/workflow-team/SKILL.md` 的 "Spawn Sequence" 段后追加新段 "Auto Mode Propagation"，明确 leader 启用 `$env:AIONUI_TEAM_MODE='1'` 同时设置 `$env:HARNESS_AUTO='1'` 时，spawned member 应在自身指令上下文中以"无需交互"模式工作（与 CCW Auto Mode `-y` 的语义对齐）
  - 协议条款必须显式说明：（a）member 仍只通过 `team_send_message` 回 leader，不直接写真相源；（b）auto 模式不绕过 PLAN_REVIEW / CODE_REVIEW gate；（c）auto 模式仅取消 member 自身的中间确认，不取消 leader 的 stage 推进确认
  - 在 `agent-configs/workflows/harness-lite.yaml` 的文件顶部注释段补充 5-10 行说明（YAML 字段实体不动，仅 `#` 注释）；指向 SKILL.md 的对应段落
- 非目标:
  - 不修改 `scripts/spawn-team.ps1` 任何代码
  - 不引入新环境变量验证脚本
  - 不让 auto 模式获得跳过 stage gate 的权限
  - 不在本 TODO 范围内实现 `team_send_message` 的 auto-mode payload 字段
- affected_paths:
  - `skills/workflow-team/SKILL.md`
  - `agent-configs/workflows/harness-lite.yaml`
- 验证:
  - `git diff skills/workflow-team/SKILL.md` 仅显示新增段，不删除既有 "When To Use / Spawn Sequence / Fallback / Single-Writer Constraint" 任意条款
  - SKILL.md 中能用 `Select-String -Pattern '^## Auto Mode Propagation'` 命中
  - `agent-configs/workflows/harness-lite.yaml` 中 `name:`、`version:`、`stages:` 等实体字段在 git diff 前后字节相同（仅注释段差量）
- 回滚: `git revert` 单条 commit；spawned member 行为回到当前默认（仍保守、不做 auto）
- 风险:
  - 协议落地后若 leader 实际未传 `$env:HARNESS_AUTO`，member 不会自动判断启用，存在"协议存在但未生效"的隐性偏差。缓解：协议显式标注 fail-closed（缺省=non-auto）
  - "auto 不绕过 stage gate" 这条边界容易在后续 Phase 实现 hook 时被误读；缓解：在条款里写死示例，并在 risks 里标注

### TODO P5-T2 — todowrite-milestone-template（PLAN/IMPLEMENT/REVIEW 三 skill 引入 TodoWrite 节奏）

- 范围:
  - 在 `skills/plan/SKILL.md` 的 "工作方式" 段之后追加新段 "TodoWrite Milestones"，提供模板：`phase-loaded → core-work-done → verification-done` 三段 milestone，附 1 段最小示例
  - 同样在 `skills/implement/SKILL.md` 的 "工作流程" 段之后追加；模板取 `context-loaded → code-edited → tests-run → notes-appended` 四段
  - 同样在 `skills/review/SKILL.md` 的 "审查重点" 段之后追加；模板取 `context-loaded → findings-collected → run-appended` 三段
  - 三段模板必须显式说明：（a）TodoWrite 是 Claude Code 内置 surface，不引入新依赖；（b）milestone 触发 blocker 时必须立刻汇报，不堆积；（c）completion 必须与最终的 stage callback / SendMessage 配对
- 非目标:
  - 不强制 codex / gemini 这两个 backend 也使用 TodoWrite（CCW Auto Mode 经验：跨 CLI 的 milestone 表达方式不统一，留给 Phase 6/7 再统一）
  - 不修改 advance-stage / validator 的任何检测逻辑
  - 不在 SKILL.md 中要求 leader 必须验证 worker 是否调用了 TodoWrite（advisory 性质）
- affected_paths:
  - `skills/plan/SKILL.md`
  - `skills/implement/SKILL.md`
  - `skills/review/SKILL.md`
- 验证:
  - 3 个 SKILL.md 均能用 `Select-String -Pattern '^## TodoWrite Milestones'` 命中
  - 三段模板所列的 milestone 名称与本 plan 的范围段完全一致（用 `Select-String -Pattern 'phase-loaded' skills/plan/SKILL.md` 等抽样确认）
  - 既有"硬约束 / 推荐骨架 / 不要做的事"等条款保持原文
- 回滚: 三处独立追加，可分别 revert；revert 后行为退回当前（worker 自行决定是否使用 TodoWrite）
- 风险:
  - 模板若过于具体，会让 worker 把 TodoWrite 当成"格式化打卡"，而不是真正的进度跟踪。缓解：模板段落里强调"milestone 是事件，不是签到点"
  - codex / gemini 经过 stage 推进后看到这些 milestone 模板可能会误以为必须执行 TodoWrite。缓解：在模板首行加注 "适用：claudecode；其余 backend 视实现而定"

### TODO P5-T3 — spec-keyword-frontmatter（spec.md 可选 `front_keywords` 字段）

- 范围:
  - 修改 `skills/spec/SKILL.md` 的 "推荐结构" 段，在 `# <Task Title> Spec` 之上展示可选 frontmatter 示例：`---\nfront_keywords: [a, b, c]\n---`，并附说明：何时启用（跨任务关键词检索 / 长会话恢复时快速命中）、何时不写（单任务、无跨任务复用价值）
  - 同步在 `skills/orchestrator/references/lite-writing-guide.md` 中追加 1 段 "spec.md 可选 frontmatter"，避免规范二源漂移
  - 在示例中明确：`front_keywords` 必须 inline-array、kebab-case 优先、单任务 ≤ 5 个 keyword（防止 keyword 膨胀）
- 非目标:
  - 不修改 `scripts/validate-lite-artifacts.ps1`：当前 validator 对 spec.md 只校验 sections（`Gap` / `Constraint` / `Verification Delta`），不读 frontmatter，因此追加 frontmatter 不会触发 schema 失败；保持 opt-in 由 Phase 6 决定是否升格
  - 不创建任何新模板文件；spec.md 的样例仍以 SKILL.md 内联代码块为准
  - 不强制现有任务（无 spec.md 的 19 个任务）补 spec.md
  - 不为本字段引入跨任务索引脚本（那是 Phase 6 工作）
- affected_paths:
  - `skills/spec/SKILL.md`
  - `skills/orchestrator/references/lite-writing-guide.md`
- 验证:
  - `Select-String -Path skills/spec/SKILL.md -Pattern 'front_keywords:'` 命中至少 1 次
  - `Select-String -Path skills/orchestrator/references/lite-writing-guide.md -Pattern 'front_keywords'` 命中至少 1 次
  - 在临时新建一份带 `front_keywords: [demo, sample]` frontmatter 的 spec.md（任意已有任务下）后，运行 `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId <that-task>` 仍 PASS（验证 validator 不会反弹）；验证完成后立即删除该临时 spec.md
- 回滚: 单条 revert；spec.md 模板回到当前形态；任何已写入 `front_keywords` 的 spec.md 仍合法（validator 不读它）
- 风险:
  - opt-in 字段长期无人填写，会沦为"装饰"。缓解：Phase 6 评审时可决定是否升格为 advisory warning；本 Phase 仅做铺垫
  - 多人在不同任务下使用相同 keyword 但拼写不一致（如 `auto-mode` vs `auto_mode`）会破坏后续检索价值。缓解：在 SKILL.md 里明确 kebab-case 约定 + ≤ 5 上限

### TODO P5-T4 — long-session-recovery-checklist（`.assistant/工作流/长会话恢复.md`）

- 范围:
  - 新建 `.assistant/工作流/长会话恢复.md`，单文件 ≤ 200 行
  - 内容必须严格汇编自 3 个权威源：（a）CLAUDE.md 中"恢复触发"段；（b）`skills/obsidian-memory/` 中相关协议（特别是 `恢复协议.md`）；（c）`.assistant/工作流/任务识别协议.md`
  - 章节结构（建议）：① 触发词清单 → ② 读取顺序（恢复索引 → 当前任务 → tasks/<id> → 中断任务 → 上次会话）→ ③ worker callback 处理路径 → ④ 单写者契约下的临界场景（如恢复时多端并发、运行时文件冲突）→ ⑤ 故障兜底（恢复索引缺失 / 当前任务缺失）
  - 文档结尾必须列出"权威源"段，明确若三源之间出现冲突，本文件以哪一份为准（默认：CLAUDE.md > obsidian-memory 协议 > 工作流协议；本文件仅汇编）
- 非目标:
  - 不引入新协议条款；遇到三源未覆盖的边角场景，标注 TODO 留给 Phase 6/7 评估，不在本任务里发明
  - 不修改 CLAUDE.md / `skills/obsidian-memory/` / 既有协议任意一行
  - 不变更 `.assistant/` 4 层结构（运行时/工作流/配置/记忆候选）
  - 不引入新触发词（仅汇编现有"继续 / 恢复 / resume / 刚才做到哪里了"等）
- affected_paths:
  - `.assistant/工作流/长会话恢复.md`
- 验证:
  - `Get-Item .assistant/工作流/长会话恢复.md | Select-Object -ExpandProperty Length` 对应文件存在且非空
  - `(Get-Content .assistant/工作流/长会话恢复.md).Count` ≤ 200
  - 通过 `Select-String -Path .assistant/工作流/长会话恢复.md -Pattern '触发词|读取顺序|权威源'` 三个关键词分别命中
  - 该文档不出现任何对 CLAUDE.md 的实质性修改建议（用 `Select-String -Pattern '修改|覆盖|改写' .assistant/工作流/长会话恢复.md` 检查应为 0 命中或仅出现在"非目标"段）
- 回滚: 直接 `git rm .assistant/工作流/长会话恢复.md`；CLAUDE.md "恢复触发"段保持唯一权威
- 风险:
  - 三源之间已有的细微差异（例如恢复触发词大小写）若被本文件首次显式列出，会让用户误以为"汇编版"是新协议。缓解：文档头与权威源段双重声明"汇编 only"
  - 200 行硬上限可能在长期演化下被突破；本任务 baseline 必须 ≤ 200，超出由后续任务单独处理（不在本任务回锅）

## Verification

- `pwsh -NoProfile -File scripts/validate-lite-artifacts.ps1 -TaskId phase5-doc-protocol-hardening`
- `git diff --stat HEAD~1 -- skills/ agent-configs/ .assistant/工作流/`
- `Select-String -Path skills/workflow-team/SKILL.md -Pattern '^## Auto Mode Propagation'`
- `Select-String -Path skills/plan/SKILL.md skills/implement/SKILL.md skills/review/SKILL.md -Pattern '^## TodoWrite Milestones'`
- `Select-String -Path skills/spec/SKILL.md -Pattern 'front_keywords:'`
- `Get-Content .assistant/工作流/长会话恢复.md | Measure-Object -Line`
- 语义判据：第 1 条 validator 必须 PASS（0 Errors）；第 2 条 git diff 必须只覆盖本 plan 列出的 affected_paths（无任何 `scripts/`、`docs/tasks/<其他>/`、`.assistant/运行时/` 改动）；第 3-5 条均必须命中（命中数：Auto Mode 1、TodoWrite Milestones 3、front_keywords ≥ 1）；第 6 条行数 ≤ 200

## Risks

- 4 条 TODO 看似独立，但在 IMPLEMENT 阶段如果一个 commit 同时触动多个 SKILL.md，会让回滚单元变得不清晰。缓解：约定 IMPLEMENT 时按 P5-T1/T2/T3/T4 拆 4 个独立 commit；每个 commit 只动 1 条 TODO 列出的 affected_paths
- `agent-configs/workflows/harness-lite.yaml` 的注释段虽不影响 validator advisory 检查（validator 跳过 `#` 行），但若注释行写得过长可能在 PR review 中干扰可读性。缓解：每条注释 ≤ 80 字符
- spec.md 新增 frontmatter 示例时，若 SKILL.md 中代码块的语法标记不准确（例如把 ` ```yaml ` 写成 ` ```markdown `），会让示例本身可读性下降。缓解：在 IMPLEMENT 时显式 `Select-String -Pattern '\`\`\`yaml' skills/spec/SKILL.md` 检查
- TodoWrite milestone 名称在三个 SKILL.md 之间不统一（plan: phase-loaded / implement: context-loaded）已在范围段固化；如果未来 Phase 6 决定统一命名，将作为独立任务，不在本路线图回锅
- `.assistant/工作流/长会话恢复.md` 在 IMPLEMENT 时若被 worker 误改成"新协议"而非"汇编"，会破坏单一权威源契约。缓解：CODE_REVIEW 时必须逐条比对 CLAUDE.md "恢复触发"段、`恢复协议.md`、`任务识别协议.md`，确保"汇编 only"
- 已裁定 1：环境变量名锁定为 `HARNESS_AUTO`（不采用 `HARNESS_AUTO_MODE` / `AIONUI_AUTO`）。理由：Phase 5 仅做最小协议补强，沿用当前文案的最小变更面；如未来需要升级命名，将作为独立任务，不在本 Phase 回锅。本 plan 全文（P5-T1 范围 / 风险）已使用此名，IMPLEMENT 时不得替换
- 已裁定 2：`agent-configs/workflows/harness-lite.yaml` 的 auto-mode 说明固定放在 YAML 注释段（不创建同级 `harness-lite.notes.md` 或任何 sidecar 文档）。理由：保持 affected_paths 最小、不新增 sidecar 文档、不改变既有文件发现路径。P5-T1 affected_paths 已据此固化为仅 2 项（SKILL.md + harness-lite.yaml），IMPLEMENT 时不得追加 sidecar 文件

## Plan Review

## Implementation Notes

## Code Review
