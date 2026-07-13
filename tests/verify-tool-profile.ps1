# Validate Phase 1 tool_profile/model support.
[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function New-IsolatedRepoFixture {
    param(
        [string]$SourceRoot,
        [string[]]$RelativePaths
    )

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-tool-profile-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    foreach ($relativePath in $RelativePaths) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath $relativePath
    }

    return $fixtureRoot
}

function Invoke-Validator {
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

function Invoke-AdvanceStage {
    param(
        [string]$AdvancePath,
        [string]$TaskId,
        [string]$ExpectedStage,
        [string]$Tool,
        [string]$VaultRoot,
        [string]$RepoRoot,
        [string]$Profile = "",
        [string]$Model = ""
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $AdvancePath,
        '-TaskId', $TaskId,
        '-ExpectedStage', $ExpectedStage,
        '-Tool', $Tool,
        '-VaultRoot', $VaultRoot,
        '-RepoRoot', $RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $arguments += @('-Profile', $Profile)
    }

    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $arguments += @('-Model', $Model)
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& powershell.exe @arguments 2>&1 | ForEach-Object { [string]$_ })
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function New-PlanContent {
    param(
        [string]$TaskId,
        [string]$Stage,
        [string]$Tool,
        [string[]]$ExtraFrontmatter = @()
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'
    $extra = if ($ExtraFrontmatter.Count -gt 0) {
        ($ExtraFrontmatter -join "`r`n") + "`r`n"
    } else {
        ""
    }

@"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
${extra}updated: $updatedDate
---
# Sample Plan

## Clarification
- 验收标准: tool profile validator returns expected result.
- 非目标: no workflow descriptor or team bridge.
- 受影响目录: scripts/, tests/, skills/, agent-configs/
- 回滚策略: remove optional frontmatter fields and profile descriptors.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- Add optional tool profile support.

## Verification
- ``powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-tool-profile.ps1``

## Risks
- none

## Plan Review

## Implementation Notes

## Code Review

"@
}

function Get-YamlScalar {
    param(
        [string]$Path,
        [string]$Name
    )

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        if ($line -match ('^{0}:\s*(.+?)\s*$' -f [regex]::Escape($Name))) {
            return $matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return ""
}

function Test-FullModelId {
    param([string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) {
        return $false
    }

    $normalized = $Model.Trim()
    if ($normalized -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$') {
        return $false
    }

    if ($normalized -notmatch '[-./]') {
        return $false
    }

    return ($normalized -notmatch '^(opus|sonnet|haiku|default|latest|codex|claude|gpt)$')
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$SourceRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $SourceRoot -RelativePaths @(
    'scripts\advance-stage.ps1',
    'scripts\lite-artifact-parser.ps1',
    'scripts\validate-lite-artifacts.ps1',
    'skills\obsidian-memory\scripts\runtime-inbox-common.ps1',
    'skills\obsidian-memory\scripts\runtime-state-common.ps1',
    'skills\obsidian-memory\scripts\resolve-shared-memory-paths.ps1',
    'agent-configs\profiles'
)
$RepoRoot = $fixtureRoot
$validatorPath = Join-Path $RepoRoot 'scripts\validate-lite-artifacts.ps1'
$advancePath = Join-Path $RepoRoot 'scripts\advance-stage.ps1'
$taskBase = Join-Path $RepoRoot 'docs\tasks'
$profileDir = Join-Path $RepoRoot 'agent-configs\profiles'
$script:Checks = @()
$script:Failures = @()
$createdTaskDirs = @()

try {
    $expectedProfiles = @(
        @{ Name = 'harness-default-claude'; Backend = 'claudecode' },
        @{ Name = 'harness-default-codex'; Backend = 'codex' }
    )

    foreach ($profile in $expectedProfiles) {
        $path = Join-Path $profileDir ("{0}.yaml" -f $profile.Name)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-Failure ("missing profile descriptor: {0}" -f $profile.Name)
            continue
        }

        $name = Get-YamlScalar -Path $path -Name 'name'
        $backend = Get-YamlScalar -Path $path -Name 'backend'
        $model = Get-YamlScalar -Path $path -Name 'model'
        if ($name -eq $profile.Name -and $backend -eq $profile.Backend -and (Test-FullModelId -Model $model)) {
            Add-Check ("profile descriptor is valid: {0}" -f $profile.Name)
        } else {
            Add-Failure ("profile descriptor invalid: {0}" -f $profile.Name)
        }
    }

    $taskOld = 'tool-profile-old-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskOldDir = Join-Path $taskBase $taskOld
    $createdTaskDirs += $taskOldDir
    New-Item -ItemType Directory -Path $taskOldDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskOldDir 'plan.md') -Content (New-PlanContent -TaskId $taskOld -Stage 'PLAN' -Tool 'codex')
    $oldResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskOld -RepoRoot $RepoRoot
    if ($oldResult.ExitCode -eq 0 -and ($oldResult.Output -join "`n") -match 'STATUS: PASS') {
        Add-Check 'old four-field frontmatter remains valid'
    } else {
        Add-Failure ("old frontmatter should pass, got: {0}" -f ($oldResult.Output -join ' | '))
    }

    $taskProfile = 'tool-profile-valid-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskProfileDir = Join-Path $taskBase $taskProfile
    $createdTaskDirs += $taskProfileDir
    New-Item -ItemType Directory -Path $taskProfileDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskProfileDir 'plan.md') -Content (New-PlanContent -TaskId $taskProfile -Stage 'PLAN' -Tool 'codex' -ExtraFrontmatter @('tool_profile: harness-default-codex', 'model: gpt-5.5/xhigh'))
    $profileResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskProfile -RepoRoot $RepoRoot
    if ($profileResult.ExitCode -eq 0 -and ($profileResult.Output -join "`n") -match 'plan.md tool matches tool_profile backend') {
        Add-Check 'matching tool_profile frontmatter passes validator'
    } else {
        Add-Failure ("matching tool_profile should pass, got: {0}" -f ($profileResult.Output -join ' | '))
    }

    $taskMismatch = 'tool-profile-mismatch-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMismatchDir = Join-Path $taskBase $taskMismatch
    $createdTaskDirs += $taskMismatchDir
    New-Item -ItemType Directory -Path $taskMismatchDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskMismatchDir 'plan.md') -Content (New-PlanContent -TaskId $taskMismatch -Stage 'PLAN' -Tool 'codex' -ExtraFrontmatter @('tool_profile: harness-default-claude', 'model: gpt-5.5/xhigh'))
    $mismatchResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskMismatch -RepoRoot $RepoRoot
    if ($mismatchResult.ExitCode -ne 0 -and ($mismatchResult.Output -join "`n") -match 'should match tool_profile backend') {
        Add-Check 'tool/profile backend mismatch is rejected'
    } else {
        Add-Failure ("tool/profile mismatch should fail, got: {0}" -f ($mismatchResult.Output -join ' | '))
    }

    $taskAlias = 'tool-profile-alias-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskAliasDir = Join-Path $taskBase $taskAlias
    $createdTaskDirs += $taskAliasDir
    New-Item -ItemType Directory -Path $taskAliasDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskAliasDir 'plan.md') -Content (New-PlanContent -TaskId $taskAlias -Stage 'PLAN' -Tool 'claudecode' -ExtraFrontmatter @('model: opus'))
    $aliasResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskAlias -RepoRoot $RepoRoot
    if ($aliasResult.ExitCode -ne 0 -and ($aliasResult.Output -join "`n") -match 'full model id') {
        Add-Check 'short model aliases are rejected'
    } else {
        Add-Failure ("short model alias should fail, got: {0}" -f ($aliasResult.Output -join ' | '))
    }

    $vaultRoot = Join-Path $RepoRoot '.assistant'
    New-Item -ItemType Directory -Path (Join-Path $vaultRoot '运行时\tasks') -Force | Out-Null

    $taskAdvanceClearing = 'tool-profile-advance-clearing-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskAdvanceClearingDir = Join-Path $taskBase $taskAdvanceClearing
    $createdTaskDirs += $taskAdvanceClearingDir
    New-Item -ItemType Directory -Path $taskAdvanceClearingDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskAdvanceClearingDir 'plan.md') -Content (New-PlanContent -TaskId $taskAdvanceClearing -Stage 'PLAN' -Tool 'claudecode' -ExtraFrontmatter @('tool_profile: harness-default-claude', 'model: claude-opus-4-7'))
    $advanceClearing = Invoke-AdvanceStage -AdvancePath $advancePath -TaskId $taskAdvanceClearing -ExpectedStage 'PLAN' -Tool 'codex' -VaultRoot $vaultRoot -RepoRoot $RepoRoot
    $clearingPlan = Get-Content -LiteralPath (Join-Path $taskAdvanceClearingDir 'plan.md') -Raw -Encoding utf8
    $clearingMirror = Get-Content -LiteralPath (Join-Path $vaultRoot "运行时\tasks\$taskAdvanceClearing.md") -Raw -Encoding utf8
    if ($advanceClearing.ExitCode -eq 0 -and
        ($advanceClearing.Output -join "`n") -match 'resolved tool=codex via cli-tool' -and
        ($advanceClearing.Output[-1]) -eq 'PLAN_REVIEW | codex' -and
        $clearingPlan -notmatch '(?m)^tool_profile:\s*\S+\s*$' -and
        $clearingPlan -notmatch '(?m)^model:\s*\S+\s*$' -and
        $clearingMirror -notmatch '(?m)^tool_profile:\s*\S+\s*$' -and
        $clearingMirror -notmatch '(?m)^model:\s*\S+\s*$' -and
        $clearingMirror -notmatch '(?m)^- assigned_tool_profile:\s+\S+\s*$' -and
        $clearingMirror -notmatch '(?m)^- assigned_model:\s+\S+\s*$') {
        Add-Check 'advance-stage pure cli-tool path clears inherited profile/model'
    } else {
        Add-Failure ("advance-stage pure cli-tool path should clear inherited profile/model, got: {0}" -f ($advanceClearing.Output -join ' | '))
    }

    $taskAdvance = 'tool-profile-advance-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskAdvanceDir = Join-Path $taskBase $taskAdvance
    $createdTaskDirs += $taskAdvanceDir
    $createdTaskDirs += $vaultRoot
    New-Item -ItemType Directory -Path $taskAdvanceDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskAdvanceDir 'plan.md') -Content (New-PlanContent -TaskId $taskAdvance -Stage 'PLAN' -Tool 'claudecode')
    $advanceOutput = (& $advancePath -TaskId $taskAdvance -ExpectedStage 'PLAN' -Tool 'codex' -Profile 'harness-default-codex' -VaultRoot $vaultRoot -RepoRoot $RepoRoot | Out-String).Trim()
    $advancedPlan = Get-Content -LiteralPath (Join-Path $taskAdvanceDir 'plan.md') -Raw -Encoding utf8
    $advancedMirror = Get-Content -LiteralPath (Join-Path $vaultRoot "运行时\tasks\$taskAdvance.md") -Raw -Encoding utf8
    if ($advanceOutput -eq 'PLAN_REVIEW | codex' -and
        $advancedPlan -match '(?m)^tool_profile:\s*harness-default-codex\s*$' -and
        $advancedPlan -match '(?m)^model:\s*gpt-5\.5/xhigh\s*$' -and
        $advancedMirror -match '(?m)^tool_profile:\s*harness-default-codex\s*$' -and
        $advancedMirror -match [regex]::Escape('- assigned_model: gpt-5.5/xhigh')) {
        Add-Check 'advance-stage writes profile default model into plan and mirror'
    } else {
        Add-Failure 'advance-stage should write profile and model into plan and mirror'
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
