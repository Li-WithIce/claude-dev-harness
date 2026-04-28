# Phase 5 Doc Protocol Hardening Code Review

Verdict: `revise`

## Findings

### P1 · `.assistant/工作流/长会话恢复.md` 仍是被忽略的本地文件，没有进入可审计的版本化变更面；当前实现实际上只交付了 7 个可审 surface

- 本轮批准的第 8 个 surface 是 `.assistant/工作流/长会话恢复.md`，且文档本身已经写出完整内容：`.assistant/工作流/长会话恢复.md:1-90`
- 但仓库当前仍把整个 `.assistant/` 目录加入忽略：`.gitignore:21`
- 结果是这份新文档不会进入普通 `git diff` / `git status` 审计面；我实际核对时，`git check-ignore -v .assistant/工作流/长会话恢复.md` 命中 `.gitignore:21`，`git ls-files` 也不包含该文件
- 因此当前 reviewable change set 里，真正可交付的是 7 个 tracked 文档 surface；`P5-T4` 虽然本地文件已存在，但还没有成为可提交、可审计的实现产物

### P2 · `长会话恢复.md` 的“只按三项权威源汇编”声明不准确；`worker callback` / 单写者条款实际还依赖了现有共享记忆与写回协议

- 文档在 `## 权威源` 中声明只按 3 份来源汇编：安装态 `CLAUDE.md`、`.assistant/工作流/恢复协议.md`、`.assistant/工作流/任务识别协议.md`：`.assistant/工作流/长会话恢复.md:85-90`
- 但 `worker callback` 与单写者路径里的关键规则，例如“非入口 host 只写 `docs/tasks/<task-id>/*` 与 `运行时/tasks/<task-id>.md`”“由入口 host 刷新共享指针与恢复索引”“信息不足先写 `运行时/收件箱.md`”出现在：`.assistant/工作流/长会话恢复.md:35-38`
- 这些条款本身不是新协议，仓库里已有现成来源：`.assistant/工作流/共享记忆协议.md:59-65` 与 `.assistant/工作流/写回协议.md:17-20`
- 所以本轮实现并没有发明新规则，但这份文档当前的 provenance 声明还不够准确；按字面看，它并不只是“按列出的三项权威源汇编”

## Scope Summary

- `HARNESS_AUTO` 命名与 `harness-lite.yaml` 注释段约束已按计划落地：`agent-configs/workflows/harness-lite.yaml:1-6`, `skills/workflow-team/SKILL.md:26-33`
- `TodoWrite Milestones` / `front_keywords` / `长会话恢复.md` 正文都已补齐：`skills/plan/SKILL.md:131-141`, `skills/implement/SKILL.md:45-56`, `skills/review/SKILL.md:49-59`, `skills/spec/SKILL.md:23-60`, `skills/orchestrator/references/lite-writing-guide.md:170-209`, `.assistant/工作流/长会话恢复.md:1-90`
- 我没有看到任何 `scripts/validate-lite-artifacts.ps1`、`.assistant/entry/advance-stage.ps1`、shared-memory runtime contract 或 Phase 6/7 surface 的代码改动；工作树里的 `.assistant/运行时/当前任务.md` / `恢复索引.md` 变化看起来是当前 entry-host 会话指针刷新，不是本轮 Phase 5 文档补强本身

## Evidence / Commands

- `git status --short`
- `git diff --name-only -- . ':(exclude)docs/tasks/phase5-doc-protocol-hardening/*'`
- `git diff --unified=0 -- agent-configs/workflows/harness-lite.yaml skills/workflow-team/SKILL.md skills/plan/SKILL.md skills/implement/SKILL.md skills/review/SKILL.md skills/spec/SKILL.md skills/orchestrator/references/lite-writing-guide.md`
- `git status --short --ignored '.assistant/工作流/长会话恢复.md'`
- `git check-ignore -v '.assistant/工作流/长会话恢复.md'`
- `git ls-files '.assistant/工作流/长会话恢复.md' 'skills/workflow-team/SKILL.md' 'skills/plan/SKILL.md' 'skills/implement/SKILL.md' 'skills/review/SKILL.md' 'skills/spec/SKILL.md' 'skills/orchestrator/references/lite-writing-guide.md' 'agent-configs/workflows/harness-lite.yaml'`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId phase5-doc-protocol-hardening -RepoRoot D:\data\claude-dev-harness`
- `Select-String -Path agent-configs/workflows/harness-lite.yaml,skills/workflow-team/SKILL.md,skills/plan/SKILL.md,skills/implement/SKILL.md,skills/review/SKILL.md,skills/spec/SKILL.md,skills/orchestrator/references/lite-writing-guide.md,.assistant/工作流/长会话恢复.md -Pattern 'HARNESS_AUTO|Auto Mode Propagation|TodoWrite Milestones|front_keywords|本文件只汇编|权威源'`
- `Select-String -Path .assistant/工作流/长会话恢复.md,.assistant/工作流/共享记忆协议.md,.assistant/工作流/写回协议.md -Pattern 'team_send_message|入口 host|非入口 host|收件箱|共享指针'`

## File Existence

This review file exists: `docs/tasks/phase5-doc-protocol-hardening/code-review.md`
