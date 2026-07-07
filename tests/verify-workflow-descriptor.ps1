[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ($null -eq $content) {
        return ''
    }

    return $content
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

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-workflow-descriptor-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    foreach ($relativePath in @(
        'scripts\advance-stage.ps1',
        'scripts\validate-lite-artifacts.ps1',
        'agent-configs\profiles',
        'agent-configs\workflows'
    )) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath $relativePath
    }

    return $fixtureRoot
}

function Invoke-Validator {
    param(
        [string]$ValidatorPath,
        [string]$TaskId,
        [string]$RepoRoot,
        [string]$WorkspaceRoot = ""
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ValidatorPath,
        '-TaskId', $TaskId,
        '-RepoRoot', $RepoRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $arguments += @('-WorkspaceRoot', $WorkspaceRoot)
    }

    $output = @(& powershell.exe @arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
        Text = ($output -join "`n")
    }
}

function Invoke-AdvanceStageWithStreams {
    param(
        [string]$AdvancePath,
        [string]$TaskId,
        [string]$VaultRoot,
        [string]$RepoRoot,
        [string]$WorkspaceRoot = "",
        [string]$Tool = "",
        [string]$Profile = "",
        [string]$Model = ""
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $AdvancePath,
        '-TaskId', $TaskId,
        '-VaultRoot', $VaultRoot,
        '-RepoRoot', $RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $arguments += @('-WorkspaceRoot', $WorkspaceRoot)
    }

    if (-not [string]::IsNullOrWhiteSpace($Tool)) {
        $arguments += @('-Tool', $Tool)
    }

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $arguments += @('-Profile', $Profile)
    }

    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $arguments += @('-Model', $Model)
    }

    $streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-workflow-descriptor-streams-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $streamRoot -Force | Out-Null
    $stdoutPath = Join-Path $streamRoot 'stdout.txt'
    $stderrPath = Join-Path $streamRoot 'stderr.txt'

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = (Read-FileUtf8 -Path $stdoutPath).Trim()
        $stderr = (Read-FileUtf8 -Path $stderrPath).Trim()
        $combined = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $combined += $stdout
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $combined += $stderr
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Combined = ($combined -join "`n")
        }
    } finally {
        Remove-DirectoryWithRetry -Path $streamRoot
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
# Workflow Descriptor Fixture

## Clarification
- 验收标准: workflow descriptor fallback behaves as expected.
- 非目标: no team preset bridge or ACP schema.
- 受影响目录: scripts/, agent-configs/, tests/, skills/
- 回滚策略: revert workflow descriptor changes.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- Update workflow descriptor fallback behavior.

## Verification
- ``powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-descriptor.ps1``

## Risks
- none

## Plan Review

## Implementation Notes

## Code Review

"@
}

function Get-ValidWorkflowDescriptorContent {
@"
name: harness-lite
version: 1
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [plan, entry-router]
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  IMPLEMENT:
    role: implementer
    default_profile: harness-default-codex
    skills_whitelist: [implement]
  CODE_REVIEW:
    role: code-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  TEST:
    role: tester
    default_profile: harness-default-codex
    skills_whitelist: [test]
"@
}

function Set-WorkflowDescriptor {
    param(
        [string]$RepoRoot,
        [string]$Content
    )

    $workflowPath = Join-Path $RepoRoot 'agent-configs\workflows\harness-lite.yaml'
    [System.IO.File]::WriteAllText($workflowPath, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-WorkflowDescriptor {
    param([string]$RepoRoot)

    $workflowPath = Join-Path $RepoRoot 'agent-configs\workflows\harness-lite.yaml'
    if (Test-Path -LiteralPath $workflowPath) {
        Remove-Item -LiteralPath $workflowPath -Force
    }
}

function Assert-WarningsNone {
    param([string]$Text)

    return ($Text -match '(?ms)^Warnings:\r?\n- none\s*$')
}

function Assert-ArtifactHasProfileModel {
    param(
        [string]$PlanText,
        [string]$MirrorText,
        [string]$Profile,
        [string]$Model
    )

    return (
        $PlanText -match ("(?m)^tool_profile:\s*{0}\s*$" -f [regex]::Escape($Profile)) -and
        $PlanText -match ("(?m)^model:\s*{0}\s*$" -f [regex]::Escape($Model)) -and
        $MirrorText -match ("(?m)^tool_profile:\s*{0}\s*$" -f [regex]::Escape($Profile)) -and
        $MirrorText -match ("(?m)^model:\s*{0}\s*$" -f [regex]::Escape($Model)) -and
        $MirrorText -match [regex]::Escape("- assigned_tool_profile: $Profile") -and
        $MirrorText -match [regex]::Escape("- assigned_model: $Model")
    )
}

function Assert-ArtifactClearedProfileModel {
    param(
        [string]$PlanText,
        [string]$MirrorText
    )

    return (
        $PlanText -notmatch '(?m)^tool_profile:\s*\S+\s*$' -and
        $PlanText -notmatch '(?m)^model:\s*\S+\s*$' -and
        $MirrorText -notmatch '(?m)^tool_profile:\s*\S+\s*$' -and
        $MirrorText -notmatch '(?m)^model:\s*\S+\s*$' -and
        $MirrorText -notmatch '(?m)^- assigned_tool_profile:\s+\S+\s*$' -and
        $MirrorText -notmatch '(?m)^- assigned_model:\s+\S+\s*$'
    )
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$SourceRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $SourceRoot
$RepoRoot = $fixtureRoot
$validatorPath = Join-Path $RepoRoot 'scripts\validate-lite-artifacts.ps1'
$advancePath = Join-Path $RepoRoot 'scripts\advance-stage.ps1'
$taskBase = Join-Path $RepoRoot 'docs\tasks'
$vaultRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-workflow-descriptor-vault-' + [guid]::NewGuid().ToString('N'))
$script:Checks = @()
$script:Failures = @()
$createdTaskDirs = @()
$createdWorkspaceRoots = @()

New-Item -ItemType Directory -Path (Join-Path $vaultRoot '运行时\tasks') -Force | Out-Null

try {
    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content (Get-ValidWorkflowDescriptorContent)

    $taskValid = 'workflow-descriptor-valid-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskValidDir = Join-Path $taskBase $taskValid
    $createdTaskDirs += $taskValidDir
    New-Item -ItemType Directory -Path $taskValidDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskValidDir 'plan.md') -Content (New-PlanContent -TaskId $taskValid -Stage 'PLAN' -Tool 'claudecode')
    $validResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($validResult.ExitCode -eq 0 -and ($validResult.Text -match 'STATUS: PASS') -and (Assert-WarningsNone -Text $validResult.Text)) {
        Add-Check 'A1 valid workflow descriptor keeps validator green with Warnings: - none'
    } else {
        Add-Failure ("A1 should pass with empty warnings, got: {0}" -f ($validResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [plan, entry-router]
"@
    $missingVersionResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($missingVersionResult.ExitCode -eq 0 -and $missingVersionResult.Text -match 'workflow descriptor should contain version') {
        Add-Check 'A2 missing workflow version is advisory-only'
    } else {
        Add-Failure ("A2 should warn on missing version, got: {0}" -f ($missingVersionResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
version: 1
stages:
  PLAN:
    role: plan-author
    default_profile: does-not-exist
    skills_whitelist: [plan, entry-router]
"@
    $missingProfileResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($missingProfileResult.ExitCode -eq 0 -and $missingProfileResult.Text -match 'default_profile is invalid: does-not-exist') {
        Add-Check 'A3 invalid workflow default_profile is advisory-only'
    } else {
        Add-Failure ("A3 should warn on invalid default_profile, got: {0}" -f ($missingProfileResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
version: 1
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [bogus-skill]
"@
    $bogusSkillResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($bogusSkillResult.ExitCode -eq 0 -and $bogusSkillResult.Text -match 'references unsupported skill: bogus-skill') {
        Add-Check 'A4 invalid workflow skill is advisory-only'
    } else {
        Add-Failure ("A4 should warn on invalid skill, got: {0}" -f ($bogusSkillResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content ((Get-ValidWorkflowDescriptorContent).Replace('skills_whitelist: [plan, entry-router]', 'skills_whitelist: [plan, using-superpowers]'))
    $legacySkillResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($legacySkillResult.ExitCode -eq 0 -and $legacySkillResult.Text -match 'references unsupported skill: using-superpowers') {
        Add-Check 'A5 legacy using-superpowers is rejected as unsupported workflow skill'
    } else {
        Add-Failure ("A5 legacy using-superpowers should warn as unsupported, got: {0}" -f ($legacySkillResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
version: 1
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [plan, entry-router]
  IMPLEMENT:
    role: implementer
    default_profile: harness-default-codex
    skills_whitelist: [implement]
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  CODE_REVIEW:
    role: code-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  TEST:
    role: tester
    default_profile: harness-default-codex
    skills_whitelist: [test]
"@
    $wrongOrderResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($wrongOrderResult.ExitCode -eq 0 -and $wrongOrderResult.Text -match 'workflow descriptor stages should be exactly PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST') {
        Add-Check 'A6 workflow descriptor warns when stage order drifts'
    } else {
        Add-Failure ("A6 wrong stage order should warn, got: {0}" -f ($wrongOrderResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
version: 1
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [plan, codegraph]
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  IMPLEMENT:
    role: implementer
    default_profile: harness-default-codex
    skills_whitelist: [implement]
  CODE_REVIEW:
    role: code-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  TEST:
    role: tester
    default_profile: harness-default-codex
    skills_whitelist: [test]
"@
    $providerSkillResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($providerSkillResult.ExitCode -eq 0 -and $providerSkillResult.Text -match 'workflow descriptor stage PLAN must not whitelist provider skill: codegraph') {
        Add-Check 'A7 workflow descriptor rejects provider names in skills_whitelist'
    } else {
        Add-Failure ("A7 provider skill should warn, got: {0}" -f ($providerSkillResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
version: 1
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [plan, entry-router]
  codegraph:
    role: codegraph
    default_profile: harness-default-codex
    skills_whitelist: [plan]
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  IMPLEMENT:
    role: implementer
    default_profile: harness-default-codex
    skills_whitelist: [implement]
  CODE_REVIEW:
    role: code-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  TEST:
    role: tester
    default_profile: harness-default-codex
    skills_whitelist: [test]
"@
    $providerStageResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($providerStageResult.ExitCode -eq 0 -and
        $providerStageResult.Text -match 'workflow descriptor contains unsupported stage: codegraph' -and
        $providerStageResult.Text -match 'workflow descriptor must not define provider as stage: codegraph') {
        Add-Check 'A8 workflow descriptor rejects providers as stages'
    } else {
        Add-Failure ("A8 provider stage should warn, got: {0}" -f ($providerStageResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
version: 1
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [plan, entry-router]
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [plan]
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  IMPLEMENT:
    role: implementer
    default_profile: harness-default-codex
    skills_whitelist: [implement]
  CODE_REVIEW:
    role: code-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  TEST:
    role: tester
    default_profile: harness-default-codex
    skills_whitelist: [test]
"@
    $duplicateStageResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($duplicateStageResult.ExitCode -eq 0 -and $duplicateStageResult.Text -match 'workflow descriptor duplicates stage PLAN') {
        Add-Check 'A9 workflow descriptor warns on duplicate stages'
    } else {
        Add-Failure ("A9 duplicate stage should warn, got: {0}" -f ($duplicateStageResult.Output -join ' | '))
    }

    Remove-WorkflowDescriptor -RepoRoot $RepoRoot
    $missingWorkflowResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($missingWorkflowResult.ExitCode -eq 0 -and (Assert-WarningsNone -Text $missingWorkflowResult.Text)) {
        Add-Check 'A10 missing workflow descriptor is skipped without warnings'
    } else {
        Add-Failure ("A10 missing workflow descriptor should keep warnings empty, got: {0}" -f ($missingWorkflowResult.Output -join ' | '))
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content (Get-ValidWorkflowDescriptorContent)

    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-workflow-descriptor-workspace-' + [guid]::NewGuid().ToString('N'))
    $createdWorkspaceRoots += $workspaceRoot
    $workspaceTaskBase = Join-Path $workspaceRoot 'docs\tasks'
    New-Item -ItemType Directory -Path $workspaceTaskBase -Force | Out-Null
    $taskWorkspace = 'workflow-descriptor-workspace-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskWorkspaceDir = Join-Path $workspaceTaskBase $taskWorkspace
    New-Item -ItemType Directory -Path $taskWorkspaceDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskWorkspaceDir 'plan.md') -Content (New-PlanContent -TaskId $taskWorkspace -Stage 'PLAN' -Tool 'claudecode')
    $workspaceAdvanceResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskWorkspace -VaultRoot $vaultRoot -RepoRoot $RepoRoot -WorkspaceRoot $workspaceRoot
    $workspacePlan = Read-FileUtf8 -Path (Join-Path $taskWorkspaceDir 'plan.md')
    $workspaceMirror = Read-FileUtf8 -Path (Join-Path $vaultRoot "运行时\tasks\$taskWorkspace.md")
    $workspaceManifestPath = Join-Path $taskWorkspaceDir 'skill-manifest.json'
    $repoTaskPath = Join-Path $taskBase $taskWorkspace
    $repoManifestPath = Join-Path $repoTaskPath 'skill-manifest.json'
    $workspaceManifest = if (Test-Path -LiteralPath $workspaceManifestPath -PathType Leaf) {
        Read-FileUtf8 -Path $workspaceManifestPath | ConvertFrom-Json
    } else {
        $null
    }
    if ($workspaceAdvanceResult.ExitCode -eq 0 -and
        $workspaceAdvanceResult.StdOut -eq 'PLAN_REVIEW | codex' -and
        $workspacePlan -match '(?m)^stage:\s*PLAN_REVIEW\s*$' -and
        $workspaceMirror -match [regex]::Escape("- pointer: docs/tasks/$taskWorkspace/plan.md") -and
        $null -ne $workspaceManifest -and
        $workspaceManifest.available_commands.Count -eq 1 -and
        $workspaceManifest.available_commands[0].name -eq 'review' -and
        -not (Test-Path -LiteralPath $repoTaskPath) -and
        -not (Test-Path -LiteralPath $repoManifestPath)) {
        Add-Check 'advance-stage reads and writes task artifacts in WorkspaceRoot while using RepoRoot for workflow config'
    } else {
        Add-Failure ("WorkspaceRoot advance should update only workspace artifacts, got stdout=[{0}] stderr=[{1}]" -f $workspaceAdvanceResult.StdOut, $workspaceAdvanceResult.StdErr)
    }

    $taskCliTool = 'workflow-descriptor-b1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskCliToolDir = Join-Path $taskBase $taskCliTool
    $createdTaskDirs += $taskCliToolDir
    New-Item -ItemType Directory -Path $taskCliToolDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskCliToolDir 'plan.md') -Content (New-PlanContent -TaskId $taskCliTool -Stage 'PLAN' -Tool 'claudecode' -ExtraFrontmatter @('tool_profile: harness-default-claude', 'model: claude-opus-4-7'))
    $cliToolResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskCliTool -VaultRoot $vaultRoot -RepoRoot $RepoRoot -Tool 'codex'
    $cliToolPlan = Read-FileUtf8 -Path (Join-Path $taskCliToolDir 'plan.md')
    $cliToolMirror = Read-FileUtf8 -Path (Join-Path $vaultRoot "运行时\tasks\$taskCliTool.md")
    if ($cliToolResult.ExitCode -eq 0 -and
        $cliToolResult.StdOut -eq 'PLAN_REVIEW | codex' -and
        $cliToolResult.StdErr -match 'resolved tool=codex via cli-tool' -and
        (Assert-ArtifactClearedProfileModel -PlanText $cliToolPlan -MirrorText $cliToolMirror)) {
        Add-Check 'B1 pure cli-tool keeps stdout exact, traces stderr, and clears inherited profile/model'
    } else {
        Add-Failure ("B1 pure cli-tool should clear inherited profile/model, got stdout=[{0}] stderr=[{1}]" -f $cliToolResult.StdOut, $cliToolResult.StdErr)
    }

    $taskCliProfile = 'workflow-descriptor-b2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskCliProfileDir = Join-Path $taskBase $taskCliProfile
    $createdTaskDirs += $taskCliProfileDir
    New-Item -ItemType Directory -Path $taskCliProfileDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskCliProfileDir 'plan.md') -Content (New-PlanContent -TaskId $taskCliProfile -Stage 'PLAN' -Tool 'claudecode')
    $cliProfileResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskCliProfile -VaultRoot $vaultRoot -RepoRoot $RepoRoot -Profile 'harness-default-codex'
    if ($cliProfileResult.ExitCode -eq 0 -and
        $cliProfileResult.StdOut -eq 'PLAN_REVIEW | codex' -and
        $cliProfileResult.StdErr -match 'resolved tool=codex via cli-profile') {
        Add-Check 'B2 cli-profile resolves backend from profile without polluting stdout'
    } else {
        Add-Failure ("B2 cli-profile should resolve codex, got stdout=[{0}] stderr=[{1}]" -f $cliProfileResult.StdOut, $cliProfileResult.StdErr)
    }

    $taskCliProfileInvalid = 'workflow-descriptor-b3-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskCliProfileInvalidDir = Join-Path $taskBase $taskCliProfileInvalid
    $createdTaskDirs += $taskCliProfileInvalidDir
    New-Item -ItemType Directory -Path $taskCliProfileInvalidDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskCliProfileInvalidDir 'plan.md') -Content (New-PlanContent -TaskId $taskCliProfileInvalid -Stage 'PLAN' -Tool 'claudecode')
    $cliProfileInvalidResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskCliProfileInvalid -VaultRoot $vaultRoot -RepoRoot $RepoRoot -Profile 'harness-default-missing'
    $cliProfileInvalidPlan = Read-FileUtf8 -Path (Join-Path $taskCliProfileInvalidDir 'plan.md')
    $cliProfileInvalidMirrorPath = Join-Path $vaultRoot "运行时\tasks\$taskCliProfileInvalid.md"
    if ($cliProfileInvalidResult.ExitCode -ne 0 -and
        $cliProfileInvalidResult.StdOut -eq '' -and
        $cliProfileInvalidResult.Combined -match 'Missing tool profile descriptor:' -and
        $cliProfileInvalidResult.Combined -notmatch 'via workflow-default' -and
        $cliProfileInvalidPlan -match '(?m)^stage:\s*PLAN\s*$' -and
        -not (Test-Path -LiteralPath $cliProfileInvalidMirrorPath)) {
        Add-Check 'B3 invalid cli-profile fails closed without falling through to workflow-default'
    } else {
        Add-Failure ("B3 invalid cli-profile should fail closed, got stdout=[{0}] stderr=[{1}]" -f $cliProfileInvalidResult.StdOut, $cliProfileInvalidResult.StdErr)
    }

    $taskWorkflowDefault = 'workflow-descriptor-b4-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskWorkflowDefaultDir = Join-Path $taskBase $taskWorkflowDefault
    $createdTaskDirs += $taskWorkflowDefaultDir
    New-Item -ItemType Directory -Path $taskWorkflowDefaultDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskWorkflowDefaultDir 'plan.md') -Content (New-PlanContent -TaskId $taskWorkflowDefault -Stage 'PLAN' -Tool 'claudecode')
    $workflowDefaultResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskWorkflowDefault -VaultRoot $vaultRoot -RepoRoot $RepoRoot
    if ($workflowDefaultResult.ExitCode -eq 0 -and
        $workflowDefaultResult.StdOut -eq 'PLAN_REVIEW | codex' -and
        $workflowDefaultResult.StdErr -match 'resolved tool=codex via workflow-default') {
        Add-Check 'B4 workflow-default falls back to descriptor stage default'
    } else {
        Add-Failure ("B4 workflow-default should resolve codex, got stdout=[{0}] stderr=[{1}]" -f $workflowDefaultResult.StdOut, $workflowDefaultResult.StdErr)
    }

    $taskWorkflowDefaultTest = 'workflow-descriptor-b4-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskWorkflowDefaultTestDir = Join-Path $taskBase $taskWorkflowDefaultTest
    $createdTaskDirs += $taskWorkflowDefaultTestDir
    New-Item -ItemType Directory -Path $taskWorkflowDefaultTestDir -Force | Out-Null
    $codeReviewPass = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: pass
- findings: none
- next: TEST
"@
    $workflowDefaultTestContent = New-PlanContent -TaskId $taskWorkflowDefaultTest -Stage 'CODE_REVIEW' -Tool 'claudecode'
    $workflowDefaultTestContent = [regex]::Replace($workflowDefaultTestContent, '(?m)^## Code Review\s*$', "## Code Review`r`n$codeReviewPass")
    Write-Utf8Bom -Path (Join-Path $taskWorkflowDefaultTestDir 'plan.md') -Content $workflowDefaultTestContent
    $workflowDefaultTestResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskWorkflowDefaultTest -VaultRoot $vaultRoot -RepoRoot $RepoRoot
    $workflowDefaultTestPlan = Read-FileUtf8 -Path (Join-Path $taskWorkflowDefaultTestDir 'plan.md')
    $workflowDefaultTestMirror = Read-FileUtf8 -Path (Join-Path $vaultRoot "运行时\tasks\$taskWorkflowDefaultTest.md")
    $workflowDefaultTestManifest = Read-FileUtf8 -Path (Join-Path $taskWorkflowDefaultTestDir 'skill-manifest.json') | ConvertFrom-Json
    if ($workflowDefaultTestResult.ExitCode -eq 0 -and
        $workflowDefaultTestResult.StdOut -eq 'TEST | codex' -and
        $workflowDefaultTestResult.StdErr -match 'resolved tool=codex via workflow-default' -and
        (Assert-ArtifactHasProfileModel -PlanText $workflowDefaultTestPlan -MirrorText $workflowDefaultTestMirror -Profile 'harness-default-codex' -Model 'gpt-5.5/xhigh') -and
        $workflowDefaultTestManifest.available_commands.Count -eq 1 -and
        $workflowDefaultTestManifest.available_commands[0].name -eq 'test') {
        Add-Check 'B4b CODE_REVIEW -> TEST workflow-default is Codex-only with test skill'
    } else {
        Add-Failure ("B4b TEST workflow-default should resolve codex/test, got stdout=[{0}] stderr=[{1}]" -f $workflowDefaultTestResult.StdOut, $workflowDefaultTestResult.StdErr)
    }

    Remove-WorkflowDescriptor -RepoRoot $RepoRoot
    $taskRequiresTool = 'workflow-descriptor-b5-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskRequiresToolDir = Join-Path $taskBase $taskRequiresTool
    $createdTaskDirs += $taskRequiresToolDir
    New-Item -ItemType Directory -Path $taskRequiresToolDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskRequiresToolDir 'plan.md') -Content (New-PlanContent -TaskId $taskRequiresTool -Stage 'PLAN' -Tool 'claudecode')
    $requiresToolResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskRequiresTool -VaultRoot $vaultRoot -RepoRoot $RepoRoot
    if ($requiresToolResult.ExitCode -ne 0 -and $requiresToolResult.Combined -match 'requires -Tool') {
        Add-Check 'B5 missing cli-tool/cli-profile/workflow-default still throws requires -Tool'
    } else {
        Add-Failure ("B5 should require -Tool when all fallbacks are missing, got: {0}" -f $requiresToolResult.Combined)
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content (Get-ValidWorkflowDescriptorContent)

    $taskCompatPass = 'workflow-descriptor-c1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskCompatPassDir = Join-Path $taskBase $taskCompatPass
    $createdTaskDirs += $taskCompatPassDir
    New-Item -ItemType Directory -Path $taskCompatPassDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskCompatPassDir 'plan.md') -Content (New-PlanContent -TaskId $taskCompatPass -Stage 'PLAN' -Tool 'claudecode')
    $compatPassResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskCompatPass -VaultRoot $vaultRoot -RepoRoot $RepoRoot -Tool 'codex' -Profile 'harness-default-codex'
    $compatPassPlan = Read-FileUtf8 -Path (Join-Path $taskCompatPassDir 'plan.md')
    $compatPassMirror = Read-FileUtf8 -Path (Join-Path $vaultRoot "运行时\tasks\$taskCompatPass.md")
    if ($compatPassResult.ExitCode -eq 0 -and
        $compatPassResult.StdOut -eq 'PLAN_REVIEW | codex' -and
        (Assert-ArtifactHasProfileModel -PlanText $compatPassPlan -MirrorText $compatPassMirror -Profile 'harness-default-codex' -Model 'gpt-5.5/xhigh')) {
        Add-Check 'C1 explicit tool+profile keeps Phase 1 compatible writeback'
    } else {
        Add-Failure ("C1 explicit tool+profile should preserve Phase 1 behavior, got stdout=[{0}] stderr=[{1}]" -f $compatPassResult.StdOut, $compatPassResult.StdErr)
    }

    $taskCompatFail = 'workflow-descriptor-c2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskCompatFailDir = Join-Path $taskBase $taskCompatFail
    $createdTaskDirs += $taskCompatFailDir
    New-Item -ItemType Directory -Path $taskCompatFailDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskCompatFailDir 'plan.md') -Content (New-PlanContent -TaskId $taskCompatFail -Stage 'PLAN' -Tool 'claudecode')
    $compatFailResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskCompatFail -VaultRoot $vaultRoot -RepoRoot $RepoRoot -Tool 'claudecode' -Profile 'harness-default-codex'
    if ($compatFailResult.ExitCode -ne 0 -and $compatFailResult.Combined -match 'does not match tool claudecode') {
        Add-Check 'C2 explicit tool/profile mismatch still reuses Phase 1 rejection'
    } else {
        Add-Failure ("C2 explicit tool/profile mismatch should fail, got: {0}" -f $compatFailResult.Combined)
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
stages:
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
"@
    $taskBadDescriptor = 'workflow-descriptor-d1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskBadDescriptorDir = Join-Path $taskBase $taskBadDescriptor
    $createdTaskDirs += $taskBadDescriptorDir
    New-Item -ItemType Directory -Path $taskBadDescriptorDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskBadDescriptorDir 'plan.md') -Content (New-PlanContent -TaskId $taskBadDescriptor -Stage 'PLAN' -Tool 'claudecode')
    $badDescriptorValidator = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskBadDescriptor -RepoRoot $RepoRoot
    $badDescriptorAdvance = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskBadDescriptor -VaultRoot $vaultRoot -RepoRoot $RepoRoot -Tool 'codex'
    if ($badDescriptorValidator.ExitCode -eq 0 -and
        $badDescriptorValidator.Text -match 'workflow descriptor should contain version' -and
        $badDescriptorAdvance.ExitCode -eq 0 -and
        $badDescriptorAdvance.StdOut -eq 'PLAN_REVIEW | codex' -and
        $badDescriptorAdvance.StdErr -match 'resolved tool=codex via cli-tool') {
        Add-Check 'D1 explicit -Tool still advances when workflow descriptor only emits warnings'
    } else {
        Add-Failure ("D1 explicit -Tool should survive bad descriptor warnings, got validator=[{0}] advance=[{1}]" -f ($badDescriptorValidator.Output -join ' | '), $badDescriptorAdvance.Combined)
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content (Get-ValidWorkflowDescriptorContent)

    $taskStdout = 'workflow-descriptor-e1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskStdoutDir = Join-Path $taskBase $taskStdout
    $createdTaskDirs += $taskStdoutDir
    New-Item -ItemType Directory -Path $taskStdoutDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskStdoutDir 'plan.md') -Content (New-PlanContent -TaskId $taskStdout -Stage 'PLAN' -Tool 'claudecode')
    $stdoutResult = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskStdout -VaultRoot $vaultRoot -RepoRoot $RepoRoot
    if ($stdoutResult.ExitCode -eq 0 -and
        $stdoutResult.StdOut -eq 'PLAN_REVIEW | codex' -and
        $stdoutResult.StdOut -notmatch 'resolved tool=' -and
        $stdoutResult.StdErr -match 'resolved tool=codex via workflow-default') {
        Add-Check 'E1 stdout keeps exact stage/tool contract while stderr carries resolution trace'
    } else {
        Add-Failure ("E1 stdout contract should remain exact, got stdout=[{0}] stderr=[{1}]" -f $stdoutResult.StdOut, $stdoutResult.StdErr)
    }

    $taskF1 = 'workflow-descriptor-f1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskF1Dir = Join-Path $taskBase $taskF1
    $createdTaskDirs += $taskF1Dir
    New-Item -ItemType Directory -Path $taskF1Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskF1Dir 'plan.md') -Content (New-PlanContent -TaskId $taskF1 -Stage 'PLAN' -Tool 'claudecode' -ExtraFrontmatter @('tool_profile: harness-default-claude', 'model: claude-opus-4-7'))
    $f1Result = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskF1 -VaultRoot $vaultRoot -RepoRoot $RepoRoot
    $f1Plan = Read-FileUtf8 -Path (Join-Path $taskF1Dir 'plan.md')
    $f1Mirror = Read-FileUtf8 -Path (Join-Path $vaultRoot "运行时\tasks\$taskF1.md")
    if ($f1Result.ExitCode -eq 0 -and
        $f1Result.StdOut -eq 'PLAN_REVIEW | codex' -and
        $f1Result.StdErr -match 'resolved tool=codex via workflow-default' -and
        $f1Result.StdErr -notmatch 'via frontmatter-profile' -and
        $f1Result.StdErr -notmatch 'via cli-' -and
        (Assert-ArtifactHasProfileModel -PlanText $f1Plan -MirrorText $f1Mirror -Profile 'harness-default-codex' -Model 'gpt-5.5/xhigh')) {
        Add-Check 'F1 workflow-default overrides current frontmatter profile and writes descriptor profile/model back'
    } else {
        Add-Failure ("F1 non-sticky workflow-default case failed, got stdout=[{0}] stderr=[{1}]" -f $f1Result.StdOut, $f1Result.StdErr)
    }

    $taskF2 = 'workflow-descriptor-f2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskF2Dir = Join-Path $taskBase $taskF2
    $createdTaskDirs += $taskF2Dir
    New-Item -ItemType Directory -Path $taskF2Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskF2Dir 'plan.md') -Content (New-PlanContent -TaskId $taskF2 -Stage 'PLAN' -Tool 'claudecode' -ExtraFrontmatter @('tool_profile: harness-default-claude', 'model: claude-opus-4-8'))
    $f2Result = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskF2 -VaultRoot $vaultRoot -RepoRoot $RepoRoot
    $f2Plan = Read-FileUtf8 -Path (Join-Path $taskF2Dir 'plan.md')
    $f2Mirror = Read-FileUtf8 -Path (Join-Path $vaultRoot "运行时\tasks\$taskF2.md")
    if ($f2Result.ExitCode -eq 0 -and
        $f2Result.StdOut -eq 'PLAN_REVIEW | codex' -and
        $f2Result.StdErr -match 'resolved tool=codex via workflow-default' -and
        (Assert-ArtifactHasProfileModel -PlanText $f2Plan -MirrorText $f2Mirror -Profile 'harness-default-codex' -Model 'gpt-5.5/xhigh')) {
        Add-Check 'F2 workflow-default remains non-sticky even with a different existing profile/model'
    } else {
        Add-Failure ("F2 non-sticky variant failed, got stdout=[{0}] stderr=[{1}]" -f $f2Result.StdOut, $f2Result.StdErr)
    }

    Set-WorkflowDescriptor -RepoRoot $RepoRoot -Content @"
name: harness-lite
version: 1
stages:
  PLAN_REVIEW:
    role: plan-reviewer
    skills_whitelist: [review]
"@
    $taskF3 = 'workflow-descriptor-f3-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskF3Dir = Join-Path $taskBase $taskF3
    $createdTaskDirs += $taskF3Dir
    New-Item -ItemType Directory -Path $taskF3Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskF3Dir 'plan.md') -Content (New-PlanContent -TaskId $taskF3 -Stage 'PLAN' -Tool 'codex' -ExtraFrontmatter @('tool_profile: harness-default-codex', 'model: gpt-5.5/xhigh'))
    $f3Result = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskF3 -VaultRoot $vaultRoot -RepoRoot $RepoRoot
    if ($f3Result.ExitCode -ne 0 -and $f3Result.Combined -match 'requires -Tool') {
        Add-Check 'F3 current-stage tool_profile does not substitute for workflow-default when descriptor lacks default_profile'
    } else {
        Add-Failure ("F3 should still require -Tool without workflow default, got: {0}" -f $f3Result.Combined)
    }
} finally {
    foreach ($taskDir in $createdTaskDirs) {
        Remove-DirectoryWithRetry -Path $taskDir
    }

    foreach ($workspaceRoot in $createdWorkspaceRoots) {
        Remove-DirectoryWithRetry -Path $workspaceRoot
    }

    Remove-DirectoryWithRetry -Path $vaultRoot
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
