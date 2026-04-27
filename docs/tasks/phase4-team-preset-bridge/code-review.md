# Phase 4 · Team Preset Bridge — Code Review

- task_id: phase4-team-preset-bridge
- stage: CODE_REVIEW
- reviewer: harness-reviewer (claudecode)
- review_date: 2026-04-25
- verdict: revise (4 P1 findings)

## Scope

Reviewed against the approved Phase 4 plan (Q1–Q8 裁定 + PLAN_REVIEW Run 1 P1/P2 修订)：
- `scripts/export-team-preset.ps1`
- `skills/workflow-team/SKILL.md` + `skills/workflow-team/scripts/spawn-team.ps1`
- 5 份 `agent-configs/role-prompts/*.md`
- `docs/team-write-authority.md` + `docs/aionui-integration/team-preset.md`
- `skills/orchestrator/SKILL.md` + `skills/orchestrator/references/runbook.md`（team-mode 文档分支）
- `tests/verify-team-preset.ps1`
- `tests/verify-team-orchestration.ps1`
- `tests/verify-lite-footprint.ps1` 对新文件的判定

`294bf604` 仍是独立后续任务；本 review 不涉及。

## Evidence Sources / Commands

执行命令：

```
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/export-team-preset.ps1 -Output $env:TEMP/tp.json -Format json
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/export-team-preset.ps1 -Output /tmp/team-preset-test.yaml
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/verify-team-preset.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/verify-team-orchestration.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-footprint.ps1
```

静态阅读：上述全部源文件 + `git status --short` 列出的 Phase 4 涉及文件。

## Findings

### P1-1 · `scripts/export-team-preset.ps1` 每次调用都 exit 1（JSON 与 YAML 路径都坏）

**位置**：`scripts/export-team-preset.ps1:300-308`（构造 `$preset = [ordered]@{ ... members = @($members) }`）。

**复现**：
```
$ pwsh -File scripts/export-team-preset.ps1 -Output $env:TEMP/tp.json -Format json
resolved profile=harness-default-claude backend=claudecode model=claude-opus-4-7 role=plan-author skills_dir=.claude/skills
... (5 行 stderr 诊断)
Argument types do not match
$? = 1
```

5 行 `resolved profile=...` stderr 诊断后立即抛 `Argument types do not match` → 脚本自带 catch 写 `Write-Diagnostic $_.Exception.Message` → exit 1。stdout 完全没有 `team-preset written to ...`，临时文件不会落盘，`Move-Item` 永远不执行。

**根因**：`$members = New-Object System.Collections.Generic.List[object]` 在 `[ordered]@{ ... members = @($members) }` 字面量里被 `@(...)` 包一次后，`Set-StrictMode -Version Latest` 下 OrderedDictionary literal 评估器抛 "Argument types do not match"。最小复现：
```
$members = New-Object System.Collections.Generic.List[object]
$members.Add([ordered]@{ role='r1' })
$preset = [ordered]@{ name='x'; members=@($members) }   # 抛错
$preset = [ordered]@{ name='x'; members=$members }       # OK
```

**影响**：JSON 与 YAML **两个路径都坏**（因为该构造在 `if ($Format -eq 'json') {...} else {...}` 之前就执行）。Phase 4 主交付物 `export-team-preset.ps1` 当前没有任何成功输出能力。

**建议**：把 `members = @($members)` 改成 `members = $members` 或 `members = @($members.ToArray())`；同时建议加一个 e2e 单元 case：调用脚本后断言 `Test-Path $Output`，避免类似缄默退出再次溜过。

---

### P1-2 · `tests/verify-team-preset.ps1` 在 P1 失败时不会输出 Failures 表，被 StrictMode 一棒打死

**位置**：`tests/verify-team-preset.ps1:269-359`。

**复现**：
```
$ pwsh -File tests/verify-team-preset.ps1
verify-team-preset.ps1: The property 'members' cannot be found on this object. Verify that the property exists.
$? = 1
```

**根因**：因为 P1-1，两次 `Invoke-PowerShellWithStreams` 都退出非零，输出文件为空，`$jsonText`/`$yamlText` 为空字符串，`$preset = $jsonText | ConvertFrom-Json` 在 `try/catch` 里被吞，但 `$preset` 仍是 `$null`。随后 line 293 的 `@($preset.members | ForEach-Object { ... })`、line 303 的 `Where-Object { $_.role -eq ... }` 等访问都会在 `Set-StrictMode -Version Latest` 下抛 "The property 'members' cannot be found on this object" — 整个 try 块直接异常退出，**`Write-Output 'Checks:'` / `Write-Output 'Failures:'` 永远不执行**。即便 P1 内部已经 `Add-Failure` 了准确诊断，外部看到的只是 StrictMode 错误。

**影响**：实际触发 review 失败时，测试给不出可读的失败列表，也看不到 P1 写的 `"P1 preset export failed, json stdout=[...] stderr=[..."` 信息。诊断价值=0。

**建议**：在 `$preset` 访问之前加 `if ($null -eq $preset) { Add-Failure 'preset null; skip P2-P5'; }` 之类的短路，或把 P2-P5 包进各自的 try/catch + Add-Failure，让脚本最终一定能跑到 376 行的输出段。

---

### P1-3 · `tests/verify-team-orchestration.ps1:327` 在双引号 here-string 里写 `$repo`，触发 StrictMode 未初始化变量错误

**位置**：`tests/verify-team-orchestration.ps1:327-330`：
```powershell
$sampleCode = @"
Set-Content $repo/.assistant/foo.md 'x'
Set-Content $repo/docs/tasks/x/plan.md 'x'
"@
```

**复现**：
```
$ pwsh -File tests/verify-team-orchestration.ps1
verify-team-orchestration.ps1: The variable '$repo' cannot be retrieved because it has not been set.
$? = 1
```

**根因**：双引号 here-string `@"..."@` 在 `Set-StrictMode -Version Latest` 下立即对里面的 `$repo` 做变量展开 — 但 `$repo` 从未声明 → 抛错。脚本在 line 327 终止，O1–O4 的 `Add-Check` 全部丢失（因为 line 365 的 `Write-Output 'Checks:'` 永远到不了）。即使 spawn-team.ps1 的逻辑通过，外部仍看到 verify-team-orchestration.ps1 fail。

**影响**：Phase 4 的另一条主测试管道也无法产出可解释的 PASS/FAIL；整个 O5 前缀正则比对意图（plan 中是 P1 决议核心）当前**未被任何能跑过的测试覆盖**。

**建议**：改成单引号 here-string `@'...'@`（literal，不展开 `$`）或用 `` `$repo `` 转义；同时把 O5 的样本代码片段从拼字符串改成直接对常量 raw string 跑 `[regex]::Matches`，去掉对未设变量的依赖。

---

### P1-4 · `tests/verify-lite-footprint.ps1` 当前 FAIL：4 个新 `.ps1` 缺 UTF-8 BOM

**复现**：
```
$ pwsh -File tests/verify-lite-footprint.ps1
...
Errors:
- scripts\export-team-preset.ps1 should use UTF-8 BOM for Windows PowerShell compatibility
- skills\workflow-team\scripts\spawn-team.ps1 should use UTF-8 BOM for Windows PowerShell compatibility
- tests\verify-team-orchestration.ps1 should use UTF-8 BOM for Windows PowerShell compatibility
- tests\verify-team-preset.ps1 should use UTF-8 BOM for Windows PowerShell compatibility
```

**根因**：4 个新 `.ps1` 是 UTF-8 NO BOM 写入的，但 footprint 合约要求 `.ps1` 必须 UTF-8 BOM。Plan 的 Clarification 验收标准明确：「所有新 `.ps1` UTF-8 BOM；新 `.md` / `.yaml` UTF-8 无 BOM」。

**影响**：在合并前阻断 Phase 1-3 既有 `verify-lite-footprint.ps1` 测试；TODO 8 回归套件的预设 PASS 行不通。

**建议**：把 4 个文件以 UTF-8 BOM 重写一次（PowerShell `Set-Content -Encoding utf8BOM` 或 `[System.IO.File]::WriteAllText($p, $content, [System.Text.UTF8Encoding]::new($true))`）。

## What was correct (no findings)

- **spawn-team.ps1 env opt-in fail-closed**：`spawn-team.ps1:79-83` 入口立即读 `$env:AIONUI_TEAM_MODE`，非 `'1'` 直接构造 `team_mode_disabled` 单行 JSON、写 stderr `AIONUI_TEAM_MODE not set; team-mode is opt-in only`、exit 1；**不**调 export、**不**触发任何 spawn。env opt-in 的可执行强制点确实只在该脚本，符合 PLAN_REVIEW Run 1 P1 决议。
- **spawn-team.ps1 stdout/stderr 隔离**：使用 `[Console]::Out.WriteLine` 输出单行 JSON，`[Console]::Error.WriteLine` 写诊断；stdout 单行合约稳定。
- **5 份 role-prompt Authority 段一致性**：5 份文件（`plan-author/plan-reviewer/implementer/code-reviewer/tester.md`）都使用同一组目录级前缀 `.assistant/` 与 `docs/tasks/<task-id>/`，"Write: NONE" + handoff 段（含 `Do not call advance-stage.ps1` 与 `Do not call team_task_update`）逐字对齐 plan 模板。
- **`docs/team-write-authority.md` 单写者集合**：§ Member read-only path prefixes 列出两条目录前缀；§ Forbidden member operations 覆盖 `Set-Content` / `Out-File` / `git commit` / `advance-stage.ps1` / `team_task_update`；与 preset / role-prompt / SKILL.md 字节一致。
- **`skills/orchestrator/SKILL.md` 文档分支**：line 58 含 "Team mode (documentation only)" 标签 + "orchestrator skill 本身不新增任何读 env 的可执行分支" 收尾，符合 PLAN_REVIEW Run 1 P1 决议；grep `AIONUI_TEAM_MODE skills/orchestrator/SKILL.md` 仅命中文档段，无 PowerShell 读 env 语句。
- **`skills/orchestrator/references/runbook.md`**：line 67-69 加入 team-mode 文档分支说明，明示 "唯一可执行强制点：`skills/workflow-team/scripts/spawn-team.ps1`"。
- **`docs/aionui-integration/team-preset.md` 与 `skills/workflow-team/SKILL.md`**：单写者前缀引用与 `docs/team-write-authority.md` 一致；SKILL.md "When To Use" 段强调 env opt-in + "可执行强制点在 spawn-team.ps1，不是本说明文档本身"。

## Coverage assessment

按 plan §Verification 与 §TODO 7：

- `verify-team-preset.ps1` P1–P5 设计意图覆盖了 plan 要求的 schema / 5 角色 parity / backend-model parity / skills_whitelist parity / role-prompt 引用与前缀对齐，**但因 P1-2 的输出生命周期 bug，结果不可读**。
- `verify-team-orchestration.ps1` O1–O6 设计意图覆盖了 env-未设 fail-closed / opt-in 5 次 spawn / payload 正确性 / fallback / 前缀级静态拦截 / MCP 在场但 env 未设仍 fail-closed，**但因 P1-3 here-string 错误，结果不可读**。
- 退回到当前状态：**Phase 4 的两个主测试都无法 PASS**；P1-4 又让 footprint 测试 FAIL。也就是 plan §Verification 列出的 11 条命令中至少 3 条当前 FAIL。

## Verdict

**revise** — 4 个 P1 findings 必须先修才能进入 TEST：

1. F1：修 `scripts/export-team-preset.ps1` `members=@($members)` → `$members` / `.ToArray()`，并实现真正能落盘的 e2e。
2. F2：修 `tests/verify-team-preset.ps1`，让 `$preset = $null` 不会令 P2-P5 全部 short-circuit StrictMode；保证 Failures 表一定写出来。
3. F3：修 `tests/verify-team-orchestration.ps1:327` 改用单引号 here-string 或转义 `$`。
4. F4：4 个新 `.ps1` 重写为 UTF-8 BOM，让 `verify-lite-footprint.ps1` PASS。

修完后建议执行：
```
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/export-team-preset.ps1 -Output $env:TEMP/team-preset.yaml
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/verify-team-preset.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/verify-team-orchestration.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-footprint.ps1
```

并把 stdout/stderr 摘要回贴 IMPLEMENT 段，证明 Phase 4 主路径与单写者前缀合约确实可执行。

## Out of scope

- 未审 `agent-configs/profiles/*.yaml` / `agent-configs/workflows/harness-lite.yaml` 内容（属 Phase 1/2 既有合约范围，且本次未改动）。
- 未跑 Phase 1/2/3 全套回归（plan §TODO 8 列表），等修完 P1 findings 后由 IMPLEMENT/TEST 阶段一起跑。
- 不评估 `294bf604`（独立后续任务，未拉回主线）。
