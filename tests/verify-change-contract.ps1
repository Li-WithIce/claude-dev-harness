# 校验 Change Contract opt-in section 的 validator 行为。
# 正例：合法 Change Contract / 无 Change Contract（兼容）。
# 反例：非法 change_type / affected_paths 占位 / affected_paths 串到其他字段 / section 位置错置。
[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Add-Check {
    <#
    .SYNOPSIS
    记录通过项。
    .DESCRIPTION
    测试结束统一输出，便于快速看 Change Contract 契约覆盖情况。
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
    失败项最终集中输出并导致非零退出码。
    .PARAMETER Message
    失败说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Failures += $Message
}

function New-IsolatedRepoFixture {
    param([string]$SourceRoot)

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-change-contract-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\lite-artifact-parser.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\validate-lite-artifacts.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'skills\obsidian-memory\scripts\runtime-state-common.ps1'
    return $fixtureRoot
}

function Invoke-Validator {
    <#
    .SYNOPSIS
    调用 lite artifact validator。
    .DESCRIPTION
    沿用 verify-lite-artifact-validator.ps1 的进程级调用方式，确保 exit code 与真实 CLI 一致。
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
    生成 plan.md 夹具，可选注入 Change Contract。
    .DESCRIPTION
    仅覆盖 Change Contract opt-in 验证所需的最小 plan 骨架。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER Stage
    当前 stage。
    .PARAMETER Tool
    工具。
    .PARAMETER ChangeContract
    可选 Change Contract section 正文（不含 `## Change Contract` 标题）。
    .PARAMETER ChangeContractPosition
    Change Contract section 的插入位置，默认位于 User Confirmation 与 Plan 之间。
    .OUTPUTS
    String。
    #>
    param(
        [string]$TaskId,
        [string]$Stage,
        [string]$Tool,
        [string]$ChangeContract = "",
        [ValidateSet("before_plan", "after_code_review")]
        [string]$ChangeContractPosition = "before_plan"
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'
    $changeContractBeforePlan = ""
    $changeContractAfterCodeReview = ""
    if (-not [string]::IsNullOrWhiteSpace($ChangeContract)) {
        $changeContractBlock = "## Change Contract`r`n$ChangeContract`r`n"
        if ($ChangeContractPosition -eq "after_code_review") {
            $changeContractAfterCodeReview = "`r`n$changeContractBlock"
        } else {
            $changeContractBeforePlan = "$changeContractBlock`r`n"
        }
    }

@"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
updated: $updatedDate
---
# Sample Plan

## Clarification
- 验收标准: validator 返回预期结果。
- 非目标: 不改动无关脚本。
- 受影响目录: scripts/, tests/
- 回滚策略: 回退本轮改动。
- ui: not-applicable

## User Confirmation
- status: confirmed

$changeContractBeforePlan## Plan
- 更新 ``scripts/validate-lite-artifacts.ps1``

## Verification
- ``powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-change-contract.ps1``

## Risks
- none

## Plan Review

## Implementation Notes

## Code Review
$changeContractAfterCodeReview

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
    # 正例 1：含合法 Change Contract
    $taskValid = 'change-contract-valid-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskValidDir = Join-Path $taskBase $taskValid
    $createdTaskDirs += $taskValidDir
    New-Item -ItemType Directory -Path $taskValidDir -Force | Out-Null
    $legalContract = @"
- change_type: feature
- affected_paths:
  - scripts/validate-lite-artifacts.ps1
  - tests/verify-change-contract.ps1
"@
    Write-Utf8Bom -Path (Join-Path $taskValidDir 'plan.md') -Content (New-PlanContent -TaskId $taskValid -Stage 'PLAN' -Tool 'claudecode' -ChangeContract $legalContract)
    $validResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($validResult.ExitCode -eq 0 -and ($validResult.Output -join "`n") -match 'Change Contract change_type is legal' -and ($validResult.Output -join "`n") -match 'Change Contract affected_paths has at least one entry') {
        Add-Check 'valid Change Contract passes validator'
    } else {
        Add-Failure ("valid Change Contract should pass validator, got: {0}" -f ($validResult.Output -join ' | '))
    }

    # 正例 2：不含 Change Contract（opt-in 兼容）
    $taskAbsent = 'change-contract-absent-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskAbsentDir = Join-Path $taskBase $taskAbsent
    $createdTaskDirs += $taskAbsentDir
    New-Item -ItemType Directory -Path $taskAbsentDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskAbsentDir 'plan.md') -Content (New-PlanContent -TaskId $taskAbsent -Stage 'PLAN' -Tool 'claudecode')
    $absentResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskAbsent -RepoRoot $RepoRoot
    if ($absentResult.ExitCode -eq 0 -and ($absentResult.Output -join "`n") -notmatch 'Change Contract') {
        Add-Check 'absent Change Contract is skipped (opt-in)'
    } else {
        Add-Failure ("absent Change Contract should skip validation, got: {0}" -f ($absentResult.Output -join ' | '))
    }

    # 反例 1：非法 change_type (bootstrap)
    $taskBadType = 'change-contract-bad-type-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskBadTypeDir = Join-Path $taskBase $taskBadType
    $createdTaskDirs += $taskBadTypeDir
    New-Item -ItemType Directory -Path $taskBadTypeDir -Force | Out-Null
    $badTypeContract = @"
- change_type: bootstrap
- affected_paths:
  - scripts/validate-lite-artifacts.ps1
"@
    Write-Utf8Bom -Path (Join-Path $taskBadTypeDir 'plan.md') -Content (New-PlanContent -TaskId $taskBadType -Stage 'PLAN' -Tool 'claudecode' -ChangeContract $badTypeContract)
    $badTypeResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskBadType -RepoRoot $RepoRoot
    if ($badTypeResult.ExitCode -ne 0 -and ($badTypeResult.Output -join "`n") -match 'Change Contract change_type should be one of') {
        Add-Check 'illegal change_type is rejected'
    } else {
        Add-Failure ("illegal change_type should fail validator, got: {0}" -f ($badTypeResult.Output -join ' | '))
    }

    # 反例 2：affected_paths 只含占位符 <path>
    $taskBadPaths = 'change-contract-bad-paths-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskBadPathsDir = Join-Path $taskBase $taskBadPaths
    $createdTaskDirs += $taskBadPathsDir
    New-Item -ItemType Directory -Path $taskBadPathsDir -Force | Out-Null
    $badPathsContract = @"
- change_type: feature
- affected_paths:
  - <path>
"@
    Write-Utf8Bom -Path (Join-Path $taskBadPathsDir 'plan.md') -Content (New-PlanContent -TaskId $taskBadPaths -Stage 'PLAN' -Tool 'claudecode' -ChangeContract $badPathsContract)
    $badPathsResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskBadPaths -RepoRoot $RepoRoot
    if ($badPathsResult.ExitCode -ne 0 -and ($badPathsResult.Output -join "`n") -match 'affected_paths should contain at least one non-placeholder entry') {
        Add-Check 'placeholder-only affected_paths is rejected'
    } else {
        Add-Failure ("placeholder affected_paths should fail validator, got: {0}" -f ($badPathsResult.Output -join ' | '))
    }

    # 反例 3：affected_paths 为空，但其他字段含嵌套 bullet
    $taskCrossMatch = 'change-contract-crossmatch-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskCrossMatchDir = Join-Path $taskBase $taskCrossMatch
    $createdTaskDirs += $taskCrossMatchDir
    New-Item -ItemType Directory -Path $taskCrossMatchDir -Force | Out-Null
    $crossMatchContract = @"
- change_type: feature
- affected_paths:
- notes:
  - scripts/not-from-notes.ps1
"@
    Write-Utf8Bom -Path (Join-Path $taskCrossMatchDir 'plan.md') -Content (New-PlanContent -TaskId $taskCrossMatch -Stage 'PLAN' -Tool 'claudecode' -ChangeContract $crossMatchContract)
    $crossMatchResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskCrossMatch -RepoRoot $RepoRoot
    if ($crossMatchResult.ExitCode -ne 0 -and ($crossMatchResult.Output -join "`n") -match 'affected_paths should contain at least one non-placeholder entry') {
        Add-Check 'affected_paths ignores nested bullets from other fields'
    } else {
        Add-Failure ("empty affected_paths with nested bullets elsewhere should fail validator, got: {0}" -f ($crossMatchResult.Output -join ' | '))
    }

    # 反例 4：Change Contract 位置错置
    $taskMisordered = 'change-contract-misordered-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMisorderedDir = Join-Path $taskBase $taskMisordered
    $createdTaskDirs += $taskMisorderedDir
    New-Item -ItemType Directory -Path $taskMisorderedDir -Force | Out-Null
    $misorderedContract = @"
- change_type: feature
- affected_paths:
  - scripts/validate-lite-artifacts.ps1
"@
    Write-Utf8Bom -Path (Join-Path $taskMisorderedDir 'plan.md') -Content (New-PlanContent -TaskId $taskMisordered -Stage 'PLAN' -Tool 'claudecode' -ChangeContract $misorderedContract -ChangeContractPosition 'after_code_review')
    $misorderedResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskMisordered -RepoRoot $RepoRoot
    if ($misorderedResult.ExitCode -ne 0 -and ($misorderedResult.Output -join "`n") -match 'Change Contract should appear between User Confirmation and Plan') {
        Add-Check 'misordered Change Contract section is rejected'
    } else {
        Add-Failure ("misordered Change Contract should fail validator, got: {0}" -f ($misorderedResult.Output -join ' | '))
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
