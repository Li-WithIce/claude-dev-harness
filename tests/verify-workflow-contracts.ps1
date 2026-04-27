# 校验 harness lite 的核心 workflow 契约。
# 重点覆盖 `advance-stage.ps1`、plan frontmatter、stage/tool 合法值和关键 gate。
[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Check {
    <#
    .SYNOPSIS
    记录通过项。
    .DESCRIPTION
    测试结束时统一输出，便于快速确认哪些 lite 契约已经覆盖。
    .PARAMETER Message
    检查说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Checks += $Message
}

function Add-Failure {
    <#
    .SYNOPSIS
    记录失败项。
    .DESCRIPTION
    失败项会在脚本末尾集中输出并让测试返回非零退出码。
    .PARAMETER Message
    失败说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Failures += $Message
}

function Write-Utf8Bom {
    <#
    .SYNOPSIS
    以 UTF-8 BOM 写文件。
    .DESCRIPTION
    测试夹具沿用仓库 markdown 编码，避免 Windows 下读写差异影响结果。
    .PARAMETER Path
    目标路径。
    .PARAMETER Content
    文件内容。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Remove-DirectoryWithRetry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 200
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Add-Failure ("cleanup failed for {0}: {1}" -f $Path, $lastError.Exception.Message)
    }
}

function Copy-RepoPathToFixture {
    param(
        [string]$SourceRoot,
        [string]$FixtureRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $destinationPath = Join-Path $FixtureRoot $RelativePath
    $destinationParent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
}

function New-IsolatedRepoFixture {
    param([string]$SourceRoot)

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-workflow-contracts-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\advance-stage.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\validate-lite-artifacts.ps1'
    if (Test-Path -LiteralPath (Join-Path $SourceRoot 'agent-configs\profiles') -PathType Container) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'agent-configs\profiles'
    }

    return $fixtureRoot
}

function New-PlanContent {
    <#
    .SYNOPSIS
    生成 lite plan.md 夹具。
    .DESCRIPTION
    这个模板覆盖 frontmatter、Clarification、User Confirmation 和 append-only sections。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER Stage
    当前阶段。
    .PARAMETER Tool
    当前阶段 tool。
    .PARAMETER ConfirmationStatus
    User Confirmation 状态。
    .PARAMETER PlanReviewRuns
    Plan Review 追加内容。
    .PARAMETER ImplementationRuns
    Implementation Notes 追加内容。
    .PARAMETER CodeReviewRuns
    Code Review 追加内容。
    .OUTPUTS
    String。
    #>
    param(
        [string]$TaskId,
        [string]$Stage,
        [string]$Tool,
        [string]$ConfirmationStatus = "confirmed",
        [string]$PlanReviewRuns = "",
        [string]$ImplementationRuns = "",
        [string]$CodeReviewRuns = ""
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'

    @"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
updated: $updatedDate
---
# Sample Plan

## Clarification
- 验收标准: 命令可以推进到下一阶段。
- 非目标: 不重写无关模块。
- 受影响目录: scripts/, skills/, tests/
- 回滚策略: 直接回退当前脚本改动。
- ui: not-applicable

## User Confirmation
- status: $ConfirmationStatus

## Plan
- 更新 ``scripts/advance-stage.ps1``
- 更新 ``tests/verify-workflow-contracts.ps1``

## Verification
- ``powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-contracts.ps1``

## Risks
- none

## Plan Review
$PlanReviewRuns

## Implementation Notes
$ImplementationRuns

## Code Review
$CodeReviewRuns

"@
}

function New-TestReport {
    <#
    .SYNOPSIS
    生成 test.md 夹具。
    .DESCRIPTION
    支持覆盖 Conclusion 和可选 Handoff，用来验证 TEST gate。
    .PARAMETER Conclusion
    结论字面量。
    .PARAMETER IncludeHandoff
    是否包含 Handoff section。
    .OUTPUTS
    String。
    #>
    param(
        [ValidateSet("pass", "fail", "blocked")]
        [string]$Conclusion,
        [bool]$IncludeHandoff = $true
    )

    $handoff = if ($IncludeHandoff) {
        "## Handoff`r`n- delivery: 提供当前 task 的验证结论。`r`n- follow_up: none`r`n"
    } else {
        ""
    }

    @"
# Test Report

## Summary
- 针对 lite workflow 进行回归验证。

## Scope
- 只验证当前 task 的阶段推进契约。

## Inputs Reviewed
- docs/tasks/sample-task/plan.md

## Test Approach
- 运行脚本并回读产物。

## Findings
- 无额外发现。

## Risks / Gaps
- 无。

## Conclusion
$Conclusion

$handoff
"@
}

function Invoke-AdvanceSuccess {
    <#
    .SYNOPSIS
    断言阶段推进成功。
    .DESCRIPTION
    成功时返回脚本输出，失败时直接抛错让测试记为失败。
    .PARAMETER ScriptPath
    advance-stage.ps1 绝对路径。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER VaultRoot
    临时共享运行时目录。
    .PARAMETER Tool
    下一阶段 tool；DONE 不需要。
    .OUTPUTS
    String。
    #>
    param(
        [string]$ScriptPath,
        [string]$TaskId,
        [string]$VaultRoot,
        [string]$Tool = ""
    )

    if ([string]::IsNullOrWhiteSpace($Tool)) {
        return (& $ScriptPath -TaskId $TaskId -VaultRoot $VaultRoot | Out-String).Trim()
    }

    return (& $ScriptPath -TaskId $TaskId -Tool $Tool -VaultRoot $VaultRoot | Out-String).Trim()
}

function Invoke-AdvanceFailure {
    <#
    .SYNOPSIS
    断言阶段推进失败。
    .DESCRIPTION
    失败时返回异常消息，便于继续检查错误语义。
    .PARAMETER ScriptPath
    advance-stage.ps1 绝对路径。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER VaultRoot
    临时共享运行时目录。
    .PARAMETER Tool
    下一阶段 tool；DONE 不需要。
    .OUTPUTS
    String。
    #>
    param(
        [string]$ScriptPath,
        [string]$TaskId,
        [string]$VaultRoot,
        [string]$Tool = ""
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Tool)) {
            & $ScriptPath -TaskId $TaskId -VaultRoot $VaultRoot | Out-Null
        } else {
            & $ScriptPath -TaskId $TaskId -Tool $Tool -VaultRoot $VaultRoot | Out-Null
        }
    } catch {
        return $_.Exception.Message
    }

    throw "advance-stage.ps1 unexpectedly succeeded for $TaskId"
}

function Test-WindowsPowerShellParse {
    <#
    .SYNOPSIS
    检查脚本能否被 Windows PowerShell 解析。
    .DESCRIPTION
    lite 主线仍需兼容 powershell.exe，因此这里直接用 Parser::ParseFile 做烟雾校验。
    .PARAMETER ScriptPath
    要解析的脚本路径。
    .OUTPUTS
    PSCustomObject。
    #>
    param([string]$ScriptPath)

    $escapedPath = $ScriptPath.Replace("'", "''")
    $command = @"
`$tokens = `$null
`$errors = `$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$escapedPath', [ref]`$tokens, [ref]`$errors)
if (`$errors.Count -eq 0) {
    'OK'
} else {
    foreach (`$err in `$errors) {
        '{0}:{1}:{2}' -f `$err.Extent.StartLineNumber, `$err.Extent.StartColumnNumber, `$err.Message
    }
}
"@
    $output = @(& powershell.exe -NoProfile -Command $command 2>&1 | ForEach-Object { [string]$_ })

    return [pscustomobject]@{
        Passed = ($output.Count -eq 1 -and $output[0] -eq 'OK')
        Output = $output
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$SourceRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $SourceRoot
$RepoRoot = $fixtureRoot
$script:Checks = @()
$script:Failures = @()
$today = Get-Date -Format 'yyyy-MM-dd'

$scriptPath = Join-Path $RepoRoot "scripts\advance-stage.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Add-Failure "advance-stage.ps1 should exist at scripts/advance-stage.ps1"
} else {
    Add-Check "advance-stage.ps1 exists"
}

$windowsParse = Test-WindowsPowerShellParse -ScriptPath $scriptPath
if (-not $windowsParse.Passed) {
    Add-Failure ("advance-stage.ps1 should parse in Windows PowerShell, got: {0}" -f ($windowsParse.Output -join ' | '))
} else {
    Add-Check "advance-stage.ps1 parses in Windows PowerShell"
}

$vaultRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-lite-vault-" + [guid]::NewGuid().ToString("N"))
$taskBase = Join-Path $RepoRoot "docs\tasks"
New-Item -ItemType Directory -Path $vaultRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $vaultRoot "运行时") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $vaultRoot "运行时\tasks") -Force | Out-Null
New-Item -ItemType Directory -Path $taskBase -Force | Out-Null

$createdTaskDirs = @()

try {
    $taskPlanSuccess = "lite-plan-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskPlanSuccessDir = Join-Path $taskBase $taskPlanSuccess
    $createdTaskDirs += $taskPlanSuccessDir
    New-Item -ItemType Directory -Path $taskPlanSuccessDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskPlanSuccessDir "plan.md") -Content (New-PlanContent -TaskId $taskPlanSuccess -Stage "PLAN" -Tool "claudecode")
    $planAdvance = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskPlanSuccess -VaultRoot $vaultRoot -Tool "codex"
    $planText = Get-Content -LiteralPath (Join-Path $taskPlanSuccessDir "plan.md") -Raw -Encoding utf8
    $taskMirror = Get-Content -LiteralPath (Join-Path $vaultRoot "运行时\tasks\$taskPlanSuccess.md") -Raw -Encoding utf8
    $currentTask = Get-Content -LiteralPath (Join-Path $vaultRoot "运行时\当前任务.md") -Raw -Encoding utf8
    $recoveryIndex = Get-Content -LiteralPath (Join-Path $vaultRoot "运行时\恢复索引.md") -Raw -Encoding utf8
    if ($planAdvance -eq "PLAN_REVIEW | codex" -and
        $planText -match "(?m)^stage:\s*PLAN_REVIEW\s*$" -and
        $planText -match "(?m)^tool:\s*codex\s*$" -and
        $taskMirror -match [regex]::Escape("- pointer: docs/tasks/$taskPlanSuccess/plan.md") -and
        $taskMirror -match "(?m)^tool:\s*codex\s*$" -and
        $taskMirror -match "(?m)^entry_host:\s*claudecode\s*$" -and
        $taskMirror -match [regex]::Escape("- assigned_tool: codex") -and
        $currentTask -match [regex]::Escape("task_id: $taskPlanSuccess") -and
        $currentTask -match [regex]::Escape(('| task_id | `{0}` |' -f $taskPlanSuccess)) -and
        $currentTask -match [regex]::Escape('| 状态 | PLAN_REVIEW |') -and
        $currentTask -match [regex]::Escape("| 当前文档 | docs/tasks/$taskPlanSuccess/plan.md |") -and
        $currentTask -match [regex]::Escape('| 工具 | codex |') -and
        $currentTask -match [regex]::Escape('| 下一步 | 使用 codex 继续 PLAN_REVIEW |') -and
        $recoveryIndex -match [regex]::Escape("- $taskPlanSuccess | PLAN_REVIEW | $today")) {
        Add-Check "PLAN success case advances to PLAN_REVIEW and rewrites lite mirrors"
    } else {
        Add-Failure "PLAN success case should advance to PLAN_REVIEW and update docs/tasks mirror paths"
    }

    $taskInvalidStage = "lite-invalid-stage-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskInvalidStageDir = Join-Path $taskBase $taskInvalidStage
    $createdTaskDirs += $taskInvalidStageDir
    New-Item -ItemType Directory -Path $taskInvalidStageDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskInvalidStageDir "plan.md") -Content (New-PlanContent -TaskId $taskInvalidStage -Stage "DEV" -Tool "codex")
    $invalidStageMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskInvalidStage -VaultRoot $vaultRoot -Tool "codex"
    if ($invalidStageMessage -match "Unsupported stage: DEV") {
        Add-Check "invalid stage values are rejected"
    } else {
        Add-Failure "invalid stage should be rejected, got: $invalidStageMessage"
    }

    $taskInvalidTool = "lite-invalid-tool-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskInvalidToolDir = Join-Path $taskBase $taskInvalidTool
    $createdTaskDirs += $taskInvalidToolDir
    New-Item -ItemType Directory -Path $taskInvalidToolDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskInvalidToolDir "plan.md") -Content (New-PlanContent -TaskId $taskInvalidTool -Stage "PLAN" -Tool "claude-codex-gemini-default")
    $invalidToolMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskInvalidTool -VaultRoot $vaultRoot -Tool "codex"
    if ($invalidToolMessage -match "Unsupported plan tool: claude-codex-gemini-default") {
        Add-Check "invalid tool values are rejected"
    } else {
        Add-Failure "invalid tool should be rejected, got: $invalidToolMessage"
    }

    $taskMissingNextTool = "lite-missing-next-tool-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskMissingNextToolDir = Join-Path $taskBase $taskMissingNextTool
    $createdTaskDirs += $taskMissingNextToolDir
    New-Item -ItemType Directory -Path $taskMissingNextToolDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskMissingNextToolDir "plan.md") -Content (New-PlanContent -TaskId $taskMissingNextTool -Stage "PLAN" -Tool "codex")
    $missingNextToolMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskMissingNextTool -VaultRoot $vaultRoot
    if ($missingNextToolMessage -match "requires -Tool") {
        Add-Check "non-DONE transitions require an explicit next-stage tool"
    } else {
        Add-Failure "non-DONE transitions should require -Tool, got: $missingNextToolMessage"
    }

    $taskNoConfirm = "lite-no-confirm-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskNoConfirmDir = Join-Path $taskBase $taskNoConfirm
    $createdTaskDirs += $taskNoConfirmDir
    New-Item -ItemType Directory -Path $taskNoConfirmDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskNoConfirmDir "plan.md") -Content (New-PlanContent -TaskId $taskNoConfirm -Stage "PLAN" -Tool "codex" -ConfirmationStatus "draft")
    $noConfirmMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskNoConfirm -VaultRoot $vaultRoot -Tool "codex"
    if ($noConfirmMessage -match "PLAN requires explicit user confirmation") {
        Add-Check "PLAN gate requires explicit user confirmation"
    } else {
        Add-Failure "PLAN gate should block unconfirmed plans, got: $noConfirmMessage"
    }

    $taskImplementStale = "lite-implement-stale-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskImplementStaleDir = Join-Path $taskBase $taskImplementStale
    $createdTaskDirs += $taskImplementStaleDir
    New-Item -ItemType Directory -Path $taskImplementStaleDir -Force | Out-Null
    $staleImplementation = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- changed: scripts/advance-stage.ps1
- tests: none
- risks: none
- next: 交给 CODE_REVIEW
"@
    $staleReview = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: revise
- findings:
  - P1: 需要补新实现证据
- next: 回 IMPLEMENT
"@
    Write-Utf8Bom -Path (Join-Path $taskImplementStaleDir "plan.md") -Content (New-PlanContent -TaskId $taskImplementStale -Stage "IMPLEMENT" -Tool "codex" -ImplementationRuns $staleImplementation -CodeReviewRuns $staleReview)
    $staleImplementMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskImplementStale -VaultRoot $vaultRoot -Tool "claudecode"
    if ($staleImplementMessage -match "fresh Implementation Notes run after CODE_REVIEW revise" -or
        $staleImplementMessage -match "requires a fresh Implementation Notes run") {
        Add-Check "IMPLEMENT gate rejects stale evidence after CODE_REVIEW revise"
    } else {
        Add-Failure "IMPLEMENT gate should require fresh evidence after revise, got: $staleImplementMessage"
    }

    $taskImplementFresh = "lite-implement-fresh-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskImplementFreshDir = Join-Path $taskBase $taskImplementFresh
    $createdTaskDirs += $taskImplementFreshDir
    New-Item -ItemType Directory -Path $taskImplementFreshDir -Force | Out-Null
    $freshImplementation = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- changed: 初始实现
- tests: none
- risks: none
- next: 交给 CODE_REVIEW

### Run 2 · 2026-04-09 11:00 · runner: Codex
- changed: 根据 review 修补实现
- tests: pwsh -File tests/verify-workflow-contracts.ps1
- risks: none
- next: 交给 CODE_REVIEW
"@
    Write-Utf8Bom -Path (Join-Path $taskImplementFreshDir "plan.md") -Content (New-PlanContent -TaskId $taskImplementFresh -Stage "IMPLEMENT" -Tool "codex" -ImplementationRuns $freshImplementation -CodeReviewRuns $staleReview)
    $freshImplementAdvance = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskImplementFresh -VaultRoot $vaultRoot -Tool "claudecode"
    if ($freshImplementAdvance -eq "CODE_REVIEW | claudecode") {
        Add-Check "IMPLEMENT gate accepts fresh evidence and allows tool switching"
    } else {
        Add-Failure "IMPLEMENT success case should advance to CODE_REVIEW"
    }

    $taskTestMissingHandoff = "lite-test-no-handoff-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskTestMissingHandoffDir = Join-Path $taskBase $taskTestMissingHandoff
    $createdTaskDirs += $taskTestMissingHandoffDir
    New-Item -ItemType Directory -Path $taskTestMissingHandoffDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskTestMissingHandoffDir "plan.md") -Content (New-PlanContent -TaskId $taskTestMissingHandoff -Stage "TEST" -Tool "gemini")
    Write-Utf8Bom -Path (Join-Path $taskTestMissingHandoffDir "test.md") -Content (New-TestReport -Conclusion "pass" -IncludeHandoff $false)
    $missingHandoffMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskTestMissingHandoff -VaultRoot $vaultRoot
    if ($missingHandoffMessage -match "TEST requires Handoff" -or
        $missingHandoffMessage -match "Handoff") {
        Add-Check "TEST gate requires a Handoff section"
    } else {
        Add-Failure "TEST gate should require Handoff, got: $missingHandoffMessage"
    }

    $taskTestPass = "lite-test-pass-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskTestPassDir = Join-Path $taskBase $taskTestPass
    $createdTaskDirs += $taskTestPassDir
    New-Item -ItemType Directory -Path $taskTestPassDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskTestPassDir "plan.md") -Content (New-PlanContent -TaskId $taskTestPass -Stage "TEST" -Tool "gemini")
    Write-Utf8Bom -Path (Join-Path $taskTestPassDir "test.md") -Content (New-TestReport -Conclusion "pass")
    $testAdvance = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskTestPass -VaultRoot $vaultRoot
    $testPlanText = Get-Content -LiteralPath (Join-Path $taskTestPassDir "plan.md") -Raw -Encoding utf8
    if ($testAdvance -eq "DONE | none" -and
        $testPlanText -match "(?m)^stage:\s*DONE\s*$" -and
        $testPlanText -match "(?m)^tool:\s*none\s*$") {
        Add-Check "TEST pass advances to DONE"
    } else {
        Add-Failure "TEST pass case should advance to DONE"
    }

    $taskValidatorBlocked = "lite-validator-blocked-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskValidatorBlockedDir = Join-Path $taskBase $taskValidatorBlocked
    $createdTaskDirs += $taskValidatorBlockedDir
    New-Item -ItemType Directory -Path $taskValidatorBlockedDir -Force | Out-Null
    $invalidPlan = (New-PlanContent -TaskId $taskValidatorBlocked -Stage "PLAN" -Tool "codex") -replace [regex]::Escape('- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-contracts.ps1`'), '- plain text verification'
    Write-Utf8Bom -Path (Join-Path $taskValidatorBlockedDir "plan.md") -Content $invalidPlan
    $validatorBlockedMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskValidatorBlocked -VaultRoot $vaultRoot -Tool "codex"
    if ($validatorBlockedMessage -match "validate-lite-artifacts\.ps1 failed" -and $validatorBlockedMessage -match "Verification should contain backticked commands") {
        Add-Check "advance-stage blocks malformed artifacts through validate-lite-artifacts.ps1"
    } else {
        Add-Failure "advance-stage should surface validator failures before stage transition, got: $validatorBlockedMessage"
    }
} finally {
    foreach ($taskDir in $createdTaskDirs) {
        Remove-DirectoryWithRetry -Path $taskDir
    }

    Remove-DirectoryWithRetry -Path $vaultRoot
    Remove-DirectoryWithRetry -Path $fixtureRoot
}

Write-Output "Checks:"
if ($script:Checks.Count -eq 0) {
    Write-Output "- none"
} else {
    foreach ($check in $script:Checks) {
        Write-Output "- $check"
    }
}

Write-Output ""
Write-Output "Failures:"
if ($script:Failures.Count -eq 0) {
    Write-Output "- none"
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output "- $failure"
}

exit 1
