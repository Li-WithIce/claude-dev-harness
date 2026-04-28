# Phase 6 Quality Score Hard Constraints Plan Review

Verdict: `revise`

## Findings

### P1 · P6-T3 计划要求新建的 4 个 `.assistant/运行时/记忆-*.md` 文件当前仍会被 `.gitignore` 吞掉，和 `git 可审` 根约束直接冲突

- P6-T3 在顶层 `受影响目录` 与 TODO 本体里都把 `.assistant/运行时/记忆-学习.md` / `记忆-决策.md` / `记忆-约定.md` / `记忆-问题.md` 作为实体交付面写死了：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:39-42,145-156`
- 但当前仓库的 `.gitignore` 仍只对 `.assistant/工作流/长会话恢复.md` 开了精确例外，`.assistant/运行时/*` 仍被整段忽略：`.gitignore:21-24`
- 我实际执行 `git check-ignore -v .assistant/运行时/记忆-学习.md ...`，4 个目标路径全部命中 `.gitignore:21`
- 这意味着按当前 plan 进入 IMPLEMENT，P6-T3 的 4 个新文件不会进入普通 `git diff` / `git status` 审计面，和 Clarification 明写的 `git 可审` 根约束不兼容：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:18`

### P1 · zero-regression 口径仍冻结在“19 个任务目录”，和当前仓库真实 surface 不一致，验收范围会失真

- plan 在 Clarification、P6-T1、P6-T2 多处都把兼容面写成“现有 19 个任务目录”：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:13,27,81,94,110,124`
- 但我实际统计当前 `docs/tasks/` 目录，仓库里已有 `22` 个 task 目录；其中带 `plan.md` 的也只有 `13` 个，不存在一个能自然对应“现有 19 个任务目录”的稳定集合
- 在这种状态下，P6-T1/P6-T2 的 zero-regression gate 不是精确验收，而是过期数字。进入 IMPLEMENT 前，plan 需要把它改成动态口径（例如“当前所有适用 task 目录”），或重新写清楚固定子集到底是哪 19 个

### P2 · 顶层 scope 仍未完全 baked-in：`agent-configs/workflows/harness-lite.yaml` 被 P6-T1 明确纳入改动面，但 Clarification / Change Contract 没有同步声明

- P6-T1 的范围明确要求在 `agent-configs/workflows/harness-lite.yaml` 的 `PLAN_REVIEW` / `CODE_REVIEW` 段下追加注释，且该文件也出现在 P6-T1 自己的 `affected_paths` 里：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:79,86-88`
- 但顶层 `受影响目录` 没列这个路径：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:32-43`
- `## Change Contract` 也同样漏掉了它：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:56-68`
- 因此 Phase 6 的总体 scope 声明和 TODO 级 scope 之间仍有一处未收口的差异，不能算“fully baked-in”

## Scope Summary

- roadmap 的 4 条 Phase 6 TODO 已全部映射进本 plan，且 4 个已裁定项本体都已写入正文：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:72-187,207-210`
- Phase 5 / Phase 7 与已完成主线的排除边界整体仍然清楚，没有看到重开 `workflow-alignment` / `shared-memory-v2` / `live-migration` 的正文扩展：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:21-30`
- validator 现状是绿的；本轮 verdict 为 `revise` 不是因为 lite artifact 结构问题，而是因为上面 3 个实现前置矛盾还没收口

## Evidence / Commands

- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId phase6-quality-score-hard-constraints -RepoRoot D:\data\claude-dev-harness`
- `Select-String -Path docs/tasks/workflow-optimization-roadmap/plan.md -Pattern '^### Phase 6|quality-score-extension|plan-readfirst-convergence|wisdom-fourfile-alignment|quality-score-rubric' -Context 0,4`
- `Get-ChildItem docs/tasks -Directory`
- `Get-ChildItem docs/tasks -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'plan.md') }`
- `git check-ignore -v '.assistant/运行时/记忆-学习.md' '.assistant/运行时/记忆-决策.md' '.assistant/运行时/记忆-约定.md' '.assistant/运行时/记忆-问题.md'`
- `Get-Content .gitignore`
- `Select-String -Path docs/tasks/phase6-quality-score-hard-constraints/plan.md -Pattern '19 个|23 项|harness-lite.yaml|Change Contract|受影响目录'`

## File Existence

This review file exists: `docs/tasks/phase6-quality-score-hard-constraints/plan-review.md`

## Run 2

Verdict: `revise`

### Findings

#### P2 · closure point 1 还没完全 baked-in：顶层 `.gitignore` 变更说明仍写成“仅追加 4 条 `!.assistant/运行时/记忆-*.md` 例外项”，但这在当前规则下并不足以让 4 个文件真正出现在 git 审计面

- 这一版 plan 已经把 `.gitignore` 纳入顶层 `受影响目录` 与 `Change Contract`，也在 P6-T3 细则里写出了正确的完整规则块：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:40,68,143-166`
- 但顶层 `受影响目录` 对 `.gitignore` 的摘要仍写成“仅追加 4 条 `!.assistant/运行时/记忆-*.md` 例外项”：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:40`
- 这和当前仓库的 ignore 机制不一致。现有 `.gitignore:21-24` 先把 `.assistant/*` 黑掉，只放行 `工作流/长会话恢复.md`；如果 IMPLEMENT 真的只按这句去追加 4 条文件级 negate，而不同时放行 `!.assistant/运行时/` 并重建 `.assistant/运行时/*` 黑名单，4 个 wisdom 文件仍不会被 unignore
- 也就是说，closure point 1 的“详细 TODO 已修正”是对的，但“顶层范围摘要”还没完全跟上，仍存在实现入口级的误导

### Closure Summary

- closure point 2 已闭合：zero-regression 口径现在已改成基于当前现场的规则 + 快照，而不是过时的硬编码 `19`
  - 我实测当前仓库为 `22` 个 `docs/tasks/` 目录，其中 `13` 个含 `plan.md`
  - 这 `13` 个里当前确实是 `9` 个 PASS、`4` 个既存 FAIL：`harness-aionui-workflow-alignment`、`phase2-workflow-descriptor`、`review-probe-crossmatch`、`review-probe-misordered`
  - 新 plan 的快照与现场一致：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:13,85,98,128`
- closure point 3 已闭合：顶层 `受影响目录` / `Change Contract` 现在都已补上 `agent-configs/workflows/harness-lite.yaml`：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:34,62,83,92`
- 4 个已裁定项仍保持 fully baked-in：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:217-220`
- validator 我已实际重跑，结果继续为 `STATUS: PASS`

## Run 3

Verdict: `pass`

### Findings

no findings

### Closure Summary

- 上一轮唯一 remaining finding 已闭合：顶层 `受影响目录` 里的 `.gitignore` 摘要现在已经与 P6-T3 细则完全一致，明确写出三步：
  - `!.assistant/运行时/` 放行目录入口
  - `.assistant/运行时/*` 重建黑名单
  - 4 条精确 wisdom 文件例外 `!.assistant/运行时/记忆-学习.md` / `记忆-决策.md` / `记忆-约定.md` / `记忆-问题.md`
  - 见 `docs/tasks/phase6-quality-score-hard-constraints/plan.md:40,143-166`
- 前两轮已闭合项未回退：
  - zero-regression 口径仍是基于当前现场的规则 + 快照；我再次实测当前 `13` 个含 `plan.md` 的 task 中为 `9 PASS / 4 FAIL`，与 plan 文案一致：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:13,85,98,128`
  - 顶层 `受影响目录` / `Change Contract` 仍包含 `agent-configs/workflows/harness-lite.yaml`：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:34,62`
- 4 个已裁定项仍 fully baked-in：`docs/tasks/phase6-quality-score-hard-constraints/plan.md:217-220`
- 我已实际重跑 `scripts/validate-lite-artifacts.ps1 -TaskId phase6-quality-score-hard-constraints -RepoRoot D:\data\claude-dev-harness`，结果继续为 `STATUS: PASS`
