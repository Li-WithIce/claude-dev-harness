# 校验 `validate-lite-artifacts.ps1` 是否真正约束了 lite 写作规范。
# 重点覆盖 frontmatter schema、review findings 写法、IMPLEMENT 回修证据和 TEST handoff。
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
    测试结束时统一输出，方便确认 validator 覆盖了哪些文档契约。
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
    失败项会在脚本末尾集中输出，并让回归返回非零退出码。
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
    夹具需要和仓库 active PowerShell 编码保持一致，避免 Windows PowerShell 解析差异。
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

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-validator-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\validate-lite-artifacts.ps1'
    if (Test-Path -LiteralPath (Join-Path $SourceRoot 'agent-configs\profiles') -PathType Container) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'agent-configs\profiles'
    }

    return $fixtureRoot
}

function Invoke-Validator {
    <#
    .SYNOPSIS
    调用 lite artifact validator。
    .DESCRIPTION
    用单独的 powershell.exe 进程执行脚本，确保 exit code 和真实 CLI 行为一致。
    .PARAMETER ValidatorPath
    validator 脚本路径。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$ValidatorPath,
        [string]$TaskId,
        [string]$RepoRoot
    )

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ValidatorPath -TaskId $TaskId -RepoRoot $RepoRoot 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function New-PlanContent {
    <#
    .SYNOPSIS
    生成 plan.md 夹具。
    .DESCRIPTION
    这个模板覆盖 lite validator 当前会读取的 plan section 和 append-only run。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER Stage
    当前阶段。
    .PARAMETER Tool
    tool 名称。
    .PARAMETER ConfirmationStatus
    User Confirmation 状态。
    .PARAMETER FrontmatterExtra
    额外 frontmatter 行。
    .PARAMETER PlanReviewRuns
    Plan Review 内容。
    .PARAMETER ImplementationRuns
    Implementation Notes 内容。
    .PARAMETER CodeReviewRuns
    Code Review 内容。
    .OUTPUTS
    String。
    #>
    param(
        [string]$TaskId,
        [string]$Stage,
        [string]$Tool,
        [string]$ConfirmationStatus = "confirmed",
        [string]$FrontmatterExtra = "",
        [string]$PlanReviewRuns = "",
        [string]$ImplementationRuns = "",
        [string]$CodeReviewRuns = ""
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'
    $extra = if ([string]::IsNullOrWhiteSpace($FrontmatterExtra)) { "" } else { "$FrontmatterExtra`r`n" }
@"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
updated: $updatedDate
$extra---
# Sample Plan

## Clarification
- 验收标准: validator 返回预期结果。
- 非目标: 不改动无关脚本。
- 受影响目录: scripts/, tests/, skills/
- 回滚策略: 回退本轮脚本与文档改动。
- ui: not-applicable

## User Confirmation
- status: $ConfirmationStatus

## Plan
- 更新 ``scripts/validate-lite-artifacts.ps1``
- 更新 ``tests/verify-lite-artifact-validator.ps1``

## Verification
- ``powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-artifact-validator.ps1``

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

function New-SpecContent {
    <#
    .SYNOPSIS
    生成 spec.md 夹具。
    .DESCRIPTION
    spec 只验证固定 section 结构，因此这里提供合法和非法两种最小样例。
    .PARAMETER Valid
    是否生成合法结构。
    .OUTPUTS
    String。
    #>
    param([bool]$Valid = $true)

    if ($Valid) {
@"
# Sample Spec

## Gap
- 需要补文档契约细节。

## Constraint
- 保持 docs/tasks 路径不变。

## Verification Delta
- 多补一条 validator 回归。
"@
    } else {
@"
# Sample Spec

## Gap
- 只有一个 section。
"@
    }
}

function New-TestReport {
    <#
    .SYNOPSIS
    生成 test.md 夹具。
    .DESCRIPTION
    支持覆盖结论和 Handoff，用来验证 TEST/DONE 文档契约。
    .PARAMETER Conclusion
    结论字面量。
    .PARAMETER IncludeHandoff
    是否包含 Handoff。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Conclusion = "pass",
        [bool]$IncludeHandoff = $true
    )

    $handoff = if ($IncludeHandoff) {
        "## Handoff`r`n- delivery: 输出测试结论。`r`n- follow_up: none`r`n"
    } else {
        ""
    }

@"
# Test Report

## Summary
- validator smoke。

## Scope
- 当前 task 文档。

## Inputs Reviewed
- ``docs/tasks/sample/plan.md``

## Test Approach
- 调用 validator。

## Findings
- none

## Risks / Gaps
- none

## Conclusion
$Conclusion

$handoff
"@
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$SourceRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $SourceRoot
$RepoRoot = $fixtureRoot
$validatorPath = Join-Path $RepoRoot 'scripts\validate-lite-artifacts.ps1'
$taskBase = Join-Path $RepoRoot 'docs\tasks'
$script:Checks = @()
$script:Failures = @()
$createdTaskDirs = @()

try {
    $taskValid = 'lite-validator-valid-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskValidDir = Join-Path $taskBase $taskValid
    $createdTaskDirs += $taskValidDir
    New-Item -ItemType Directory -Path $taskValidDir -Force | Out-Null
    $planReviewPass = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: none
"@
    $implementationPass = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- changed: 更新 validator 与 README
- tests: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-artifact-validator.ps1
- risks: none
- next: 交给 CODE_REVIEW 复核
"@
    $codeReviewPass = @"
### Run 1 · 2026-04-09 11:00 · runner: Codex
- verdict: pass
- findings: none
- next: 进入 TEST
"@
    Write-Utf8Bom -Path (Join-Path $taskValidDir 'plan.md') -Content (New-PlanContent -TaskId $taskValid -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
    Write-Utf8Bom -Path (Join-Path $taskValidDir 'spec.md') -Content (New-SpecContent -Valid $true)
    Write-Utf8Bom -Path (Join-Path $taskValidDir 'test.md') -Content (New-TestReport -Conclusion 'pass' -IncludeHandoff $true)
    $validResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($validResult.ExitCode -eq 0 -and ($validResult.Output -join "`n") -match 'STATUS: PASS') {
        Add-Check 'valid DONE task passes validator'
    } else {
        Add-Failure ("valid task should pass validator, got: {0}" -f ($validResult.Output -join ' | '))
    }

    $taskExtraField = 'lite-validator-extra-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskExtraFieldDir = Join-Path $taskBase $taskExtraField
    $createdTaskDirs += $taskExtraFieldDir
    New-Item -ItemType Directory -Path $taskExtraFieldDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskExtraFieldDir 'plan.md') -Content (New-PlanContent -TaskId $taskExtraField -Stage 'PLAN' -Tool 'codex' -FrontmatterExtra 'owner: codex')
    $extraFieldResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskExtraField -RepoRoot $RepoRoot
    if ($extraFieldResult.ExitCode -ne 0 -and ($extraFieldResult.Output -join "`n") -match 'frontmatter should only contain task_id/stage/tool/updated') {
        Add-Check 'extra frontmatter fields are rejected'
    } else {
        Add-Failure ("extra frontmatter field should fail validator, got: {0}" -f ($extraFieldResult.Output -join ' | '))
    }

    $taskInvalidTool = 'lite-validator-tool-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInvalidToolDir = Join-Path $taskBase $taskInvalidTool
    $createdTaskDirs += $taskInvalidToolDir
    New-Item -ItemType Directory -Path $taskInvalidToolDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskInvalidToolDir 'plan.md') -Content (New-PlanContent -TaskId $taskInvalidTool -Stage 'PLAN' -Tool 'claude-codex-gemini-default')
    $invalidToolResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInvalidTool -RepoRoot $RepoRoot
    if ($invalidToolResult.ExitCode -ne 0 -and ($invalidToolResult.Output -join "`n") -match 'plan.md tool should be one of') {
        Add-Check 'invalid tool values are rejected'
    } else {
        Add-Failure ("invalid tool should fail validator, got: {0}" -f ($invalidToolResult.Output -join ' | '))
    }

    $taskEmptySeverity = 'lite-validator-severity-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskEmptySeverityDir = Join-Path $taskBase $taskEmptySeverity
    $createdTaskDirs += $taskEmptySeverityDir
    New-Item -ItemType Directory -Path $taskEmptySeverityDir -Force | Out-Null
    $badReview = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings:
### P1
- next: none
"@
    Write-Utf8Bom -Path (Join-Path $taskEmptySeverityDir 'plan.md') -Content (New-PlanContent -TaskId $taskEmptySeverity -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $badReview)
    $emptySeverityResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskEmptySeverity -RepoRoot $RepoRoot
    if ($emptySeverityResult.ExitCode -ne 0 -and ($emptySeverityResult.Output -join "`n") -match 'should not use empty severity headings') {
        Add-Check 'empty severity headings are rejected'
    } else {
        Add-Failure ("empty severity headings should fail validator, got: {0}" -f ($emptySeverityResult.Output -join ' | '))
    }

    $taskStaleImplement = 'lite-validator-stale-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskStaleImplementDir = Join-Path $taskBase $taskStaleImplement
    $createdTaskDirs += $taskStaleImplementDir
    New-Item -ItemType Directory -Path $taskStaleImplementDir -Force | Out-Null
    $staleImplementation = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- changed: 初始实现
- tests: none
- risks: none
- next: 交给 CODE_REVIEW
"@
    $reviseCodeReview = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: revise
- findings:
  - P1: 需要补新实现证据
- next: 回 IMPLEMENT
"@
    Write-Utf8Bom -Path (Join-Path $taskStaleImplementDir 'plan.md') -Content (New-PlanContent -TaskId $taskStaleImplement -Stage 'IMPLEMENT' -Tool 'codex' -PlanReviewRuns $planReviewPass -ImplementationRuns $staleImplementation -CodeReviewRuns $reviseCodeReview)
    $staleImplementResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskStaleImplement -RepoRoot $RepoRoot
    if ($staleImplementResult.ExitCode -ne 0 -and ($staleImplementResult.Output -join "`n") -match 'requires a fresh Implementation Notes run') {
        Add-Check 'stale implementation evidence after revise is rejected'
    } else {
        Add-Failure ("stale implementation evidence should fail validator, got: {0}" -f ($staleImplementResult.Output -join ' | '))
    }

    $taskMissingHandoff = 'lite-validator-handoff-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMissingHandoffDir = Join-Path $taskBase $taskMissingHandoff
    $createdTaskDirs += $taskMissingHandoffDir
    New-Item -ItemType Directory -Path $taskMissingHandoffDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskMissingHandoffDir 'plan.md') -Content (New-PlanContent -TaskId $taskMissingHandoff -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
    Write-Utf8Bom -Path (Join-Path $taskMissingHandoffDir 'test.md') -Content (New-TestReport -Conclusion 'pass' -IncludeHandoff $false)
    $missingHandoffResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskMissingHandoff -RepoRoot $RepoRoot
    if ($missingHandoffResult.ExitCode -ne 0 -and ($missingHandoffResult.Output -join "`n") -match 'Handoff should contain') {
        Add-Check 'missing Handoff fields are rejected'
    } else {
        Add-Failure ("missing Handoff should fail validator, got: {0}" -f ($missingHandoffResult.Output -join ' | '))
    }

    $taskBadSpec = 'lite-validator-spec-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskBadSpecDir = Join-Path $taskBase $taskBadSpec
    $createdTaskDirs += $taskBadSpecDir
    New-Item -ItemType Directory -Path $taskBadSpecDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskBadSpecDir 'plan.md') -Content (New-PlanContent -TaskId $taskBadSpec -Stage 'PLAN' -Tool 'codex')
    Write-Utf8Bom -Path (Join-Path $taskBadSpecDir 'spec.md') -Content (New-SpecContent -Valid $false)
    $badSpecResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskBadSpec -RepoRoot $RepoRoot
    if ($badSpecResult.ExitCode -ne 0 -and ($badSpecResult.Output -join "`n") -match 'spec.md sections should be') {
        Add-Check 'invalid spec structure is rejected'
    } else {
        Add-Failure ("invalid spec should fail validator, got: {0}" -f ($badSpecResult.Output -join ' | '))
    }
} finally {
    foreach ($taskDir in $createdTaskDirs) {
        Remove-DirectoryWithRetry -Path $taskDir
    }

    Remove-DirectoryWithRetry -Path $fixtureRoot
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($check in $script:Checks) {
        Write-Output ("- {0}" -f $check)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ("- {0}" -f $failure)
}

exit 1
