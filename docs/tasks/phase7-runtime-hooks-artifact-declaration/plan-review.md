# Phase 7 Plan Review

## Findings

### P1 - P7-T1 依赖了仓库里不存在的 `append-memory.ps1`

- `docs/tasks/phase7-runtime-hooks-artifact-declaration/plan.md:72` 把 `skills/obsidian-memory/scripts/append-memory.ps1` 写成“已存在”的触发动作前提。
- 但当前仓库 `skills/obsidian-memory/scripts/` 下并没有这个脚本，现有脚本只有 `append-runtime-inbox.ps1`、`triage-runtime-inbox.ps1`、`maintain-shared-memory.ps1` 等。
- 同一 TODO 又明确写了“`不引入新脚本`”（`plan.md:74`），所以 P7-T1 以当前文字状态不能直接进入 IMPLEMENT；要么改成真实存在的写入路径，要么放宽“不可新建脚本”的约束。

### P1 - P7-T1 的“只能改 stage”口径和已批准的 `advance-stage` 现实语义冲突

- `docs/tasks/phase7-runtime-hooks-artifact-declaration/plan.md:72,79` 把自检触发动作限定为“禁止改 frontmatter `stage` 之外的字段”。
- 但当前主线的 `scripts/advance-stage.ps1:1286-1326` 会在推进时同时改写 `updated`、`tool_profile`、`model`，并刷新 task mirror。
- 计划另一侧又在 P7-T4 非目标里写了“`不修改 advance-stage.ps1`”（`plan.md:160`）。这意味着 P7-T1 若按现文实现，要么违反自己对 hook mutate 的限制，要么重开 Phase 2 已批准的 `advance-stage` 契约，二者不能同时成立。

### P2 - 已裁定 1（P7-T2 选项 A）还没有 fully baked-in，正文仍保留“待裁定 / A-B-C 多选”分支

- 风险段已经把 P7-T2 路径裁定为 **选项 A — lazy 守则 only**（`docs/tasks/phase7-runtime-hooks-artifact-declaration/plan.md:199`）。
- 但 TODO 正文仍写“详见 Risks 待裁定项 1”“本 TODO 仅在路径裁定后才可推进 IMPLEMENT”（`plan.md:97`），`affected_paths` 仍保留“`lite-writing-guide.md` 或 `docs/工作流/skill-phase-loading.md` 二选一”以及“仅在选项 B 下追加 `skills/*/phases/`”的条件分支（`plan.md:104-106`），验证/回滚也继续按 A/B/C 三套路径展开（`plan.md:110-113`）。
- 这说明已裁定项还没有收敛进正文主合同；按当前写法，IMPLEMENT 仍可名义上走已被否决的 B/C 路径，scope 也因此没有完全锁死在已批准的 Phase 7 方案内。

### P2 - P7-T1 / P7-T4 的依赖顺序校验命令按字面不可执行

- P7-T1 验证要求 `git log --diff-filter=A --name-only` 证明 `single-writer-precompact.md` 的 add commit 早于 `skills/orchestrator/SKILL.md` 的本任务 modify commit（`docs/tasks/phase7-runtime-hooks-artifact-declaration/plan.md:87`）。
- P7-T4 也用了同类命令：`git log --diff-filter=A --format=%H -- docs/工作流/single-writer-precompact.md skills/orchestrator/SKILL.md` 来比较“新文档 add”与 “orchestrator/SKILL.md modify” 的先后（`plan.md:171`）。
- 但 `--diff-filter=A` 只会保留 **新增** 文件，不会返回 `skills/orchestrator/SKILL.md` 的修改提交，所以这两条命令无法完成计划宣称的比较。若依赖顺序是强验收项，验证命令需要改成能同时观察 add / modify 的真实可执行形式。

## Conclusion

- verdict: revise
- validator: `PASS`
- 结论：Phase 7 的 4 条 TODO 主体方向基本对齐 roadmap，且没有重开 Phase 5/6 或 shared-memory / workflow-alignment 已完成主线；但当前仍有上述 4 个 implementability / baked-in blocker，不能直接进入 IMPLEMENT。

## Evidence

- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId phase7-runtime-hooks-artifact-declaration -RepoRoot D:\data\claude-dev-harness`
- `Get-Content .\docs\tasks\phase7-runtime-hooks-artifact-declaration\plan.md`
- `Get-ChildItem .\skills\obsidian-memory\scripts | Select-Object Name`
- `Get-ChildItem -Recurse -Filter append-memory.ps1 | Select-Object FullName`
- `Select-String -Path .\docs\tasks\phase7-runtime-hooks-artifact-declaration\plan.md -Pattern '待裁定|选项 A|选项 B|选项 C|append-memory\.ps1|advance-stage|frontmatter \`stage\` 之外'`
- `Select-String -Path .\scripts\advance-stage.ps1 -Pattern 'tool_profile|model|updated'`

## Run 2

- verdict: pass
- findings: none
- conclusion:
  - 上一轮 4 个 scoped finding 已闭合：P7-T1 已改为基于真实存在的 `skills/obsidian-memory/scripts/append-runtime-inbox.ps1`；P7-T1/P7-T4 也已改成“append 仅限收件箱，非 append 写回委托给现有 `advance-stage.ps1` 语义执行”的口径，不再与 `scripts/advance-stage.ps1` 当前会改写 `updated/tool_profile/model` 的现实冲突。
  - P7-T2 已彻底收口到已裁定的 A 方案：正文、affected_paths、验证、回滚都只剩 `lite-writing-guide.md` 单一路径，不再保留 A/B/C 条件分支或 `skill-phase-loading.md` 备选。
  - P7-T1/P7-T4 的依赖顺序验证已改成真实可执行的比较方式：先取 `single-writer-precompact.md` 的 add commit，再用 `git log -G ...` 抓首次引入 P7-T1 条款的 skill commit，并用 `git merge-base --is-ancestor` 判定先后。
  - 3 个已裁定项仍 fully baked-in：P7-T2 固定选项 A、P7-T1 固定主观阈值、P7-T3 固定 `read_first:` → `convergence:` → `artifacts:` 顺序，均未回退。
- validator: `PASS`
- evidence:
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lite-artifacts.ps1 -TaskId phase7-runtime-hooks-artifact-declaration -RepoRoot D:\data\claude-dev-harness`
  - `Get-Content .\docs\tasks\phase7-runtime-hooks-artifact-declaration\plan.md`
  - `Get-ChildItem .\skills\obsidian-memory\scripts\append-runtime-inbox.ps1`
  - `Select-String -Path .\docs\tasks\phase7-runtime-hooks-artifact-declaration\plan.md -Pattern 'append-runtime-inbox|advance-stage\.ps1|现有脚本语义|选项 B|选项 C|待裁定|skill-phase-loading|merge-base --is-ancestor'`
