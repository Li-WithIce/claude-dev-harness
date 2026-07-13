[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function Get-FileSetFingerprint {
    param([string[]]$Paths)

    return (@($Paths | ForEach-Object {
        $digest = if (Test-Path -LiteralPath $_ -PathType Leaf) {
            (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash
        } else {
            '<missing>'
        }
        '{0}={1}' -f ([System.IO.Path]::GetFullPath($_)), $digest
    }) -join "`n")
}

function Invoke-WithUserProfile {
    param(
        [string]$UserProfile,
        [string]$WorkingDirectory,
        [string]$ScriptPath,
        [hashtable]$Arguments = @{}
    )

    $previousUserProfile = $env:USERPROFILE
    $previousLocation = (Get-Location).Path
    try {
        $env:USERPROFILE = $UserProfile
        Set-Location -LiteralPath $WorkingDirectory
        $argumentList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ScriptPath)
        foreach ($entry in $Arguments.GetEnumerator()) {
            if ($entry.Value -is [bool]) {
                if ($entry.Value) { $argumentList += ('-{0}' -f $entry.Key) }
            } else {
                $argumentList += ('-{0}' -f $entry.Key)
                $argumentList += [string]$entry.Value
            }
        }
        $output = @(& (Get-Process -Id $PID).Path @argumentList 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally {
        Set-Location -LiteralPath $previousLocation
        $env:USERPROFILE = $previousUserProfile
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
. (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1')
$script:Checks = @()
$script:Failures = @()
$scratchRoot = Join-Path $RepoRoot ('tmp\runtime-state-contract-regression-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $scratchRoot) {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}

$workspaceRoot = Join-Path $scratchRoot 'workspace'
$userRoot = Join-Path $scratchRoot 'user'
$taskId = 'runtime-state-contract'
$planPath = Join-Path $workspaceRoot "docs\tasks\$taskId\plan.md"
$vaultRoot = Join-Path $workspaceRoot '.assistant'
New-Item -ItemType Directory -Path (Split-Path -Parent $planPath),$userRoot -Force | Out-Null

try {
    $install = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot = $RepoRoot
        VaultProfile = 'full'
    }
    if ($install.ExitCode -ne 0) {
        throw ('install failed: {0}' -f ($install.Output -join [Environment]::NewLine))
    }
    $advanceShimPath = Join-Path $vaultRoot 'entry\advance-stage.ps1'
    $validatorShimPath = Join-Path $vaultRoot 'entry\validate-lite-artifacts.ps1'

    $planContent = @"
---
task_id: $taskId
stage: PLAN
tool: claudecode
updated: 2026-07-10
---
# Runtime State Contract

## Clarification
- 验收标准: runtime state stays aligned with plan.md.
- 非目标: no live workspace update.
- 受影响目录: scripts/, skills/, tests/.
- 回滚策略: revert the isolated fixture.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- validate canonical runtime state.

## Verification
- ``pwsh -NoProfile -File tests/verify-runtime-state-contract.ps1``

## Risks
- none

## Plan Review

## Implementation Notes

## Code Review
"@
    $planContent | Set-Content -LiteralPath $planPath -Encoding utf8

    $activate = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath $advanceShimPath -Arguments @{
        TaskId = $taskId
        ExpectedStage = 'PLAN'
        SyncOnly = $true
        ActivateCurrent = $true
    }
    $currentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $activatedCurrent = if (Test-Path -LiteralPath $currentPath -PathType Leaf) { Get-Content -LiteralPath $currentPath -Raw -Encoding utf8 } else { '' }
    if ($activate.ExitCode -ne 0 -or $activatedCurrent -notmatch [regex]::Escape($taskId) -or $activatedCurrent -notmatch '\| 状态 \| PLAN \|') {
        Add-Failure ('sync-only activation should create the PLAN current pointer without advancing: {0}' -f ($activate.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'sync-only activation explicitly selects the current task without advancing'
    }

    $advance = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath $advanceShimPath -Arguments @{
        TaskId = $taskId
        ExpectedStage = 'PLAN'
        Tool = 'codex'
    }
    if ($advance.ExitCode -ne 0 -or ($advance.Output -join [Environment]::NewLine) -notmatch 'PLAN_REVIEW \| codex') {
        Add-Failure ('advance-stage should create canonical runtime records: {0}' -f ($advance.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'advance-stage creates canonical runtime records'
    }

    $backgroundTaskId = 'runtime-background'
    $backgroundPlanPath = Join-Path $workspaceRoot "docs\tasks\$backgroundTaskId\plan.md"
    New-Item -ItemType Directory -Path (Split-Path -Parent $backgroundPlanPath) -Force | Out-Null
    $planContent.Replace("task_id: $taskId", "task_id: $backgroundTaskId").Replace('# Runtime State Contract', '# Runtime Background Contract') |
        Set-Content -LiteralPath $backgroundPlanPath -Encoding utf8
    $backgroundAdvance = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath $advanceShimPath -Arguments @{
        TaskId = $backgroundTaskId
        ExpectedStage = 'PLAN'
        Tool = 'codex'
    }
    $backgroundMirrorPath = Join-Path $vaultRoot "运行时\tasks\$backgroundTaskId.md"
    $backgroundMirror = if (Test-Path -LiteralPath $backgroundMirrorPath -PathType Leaf) { Get-Content -LiteralPath $backgroundMirrorPath -Raw -Encoding utf8 } else { '' }
    $currentAfterBackground = Get-Content -LiteralPath $currentPath -Raw -Encoding utf8
    if ($backgroundAdvance.ExitCode -ne 0 -or $backgroundMirror -notmatch '(?m)^stage:\s*PLAN_REVIEW\s*$' -or $currentAfterBackground -notmatch [regex]::Escape($taskId) -or $currentAfterBackground -match [regex]::Escape($backgroundTaskId)) {
        Add-Failure ('background advance should update only its mirror: {0}' -f ($backgroundAdvance.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'background advance updates its mirror without stealing current'
    }

    $backgroundDoneTaskId = 'runtime-background-done'
    $backgroundDonePlanPath = Join-Path $workspaceRoot "docs\tasks\$backgroundDoneTaskId\plan.md"
    New-Item -ItemType Directory -Path (Split-Path -Parent $backgroundDonePlanPath) -Force | Out-Null
    $planContent.Replace("task_id: $taskId", "task_id: $backgroundDoneTaskId").Replace('stage: PLAN', 'stage: DONE').Replace('tool: claudecode', 'tool: none') |
        Set-Content -LiteralPath $backgroundDonePlanPath -Encoding utf8
    $backgroundDone = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath $advanceShimPath -Arguments @{
        TaskId = $backgroundDoneTaskId
        ExpectedStage = 'DONE'
        SyncOnly = $true
    }
    $backgroundDoneMirrorPath = Join-Path $vaultRoot "运行时\tasks\$backgroundDoneTaskId.md"
    $backgroundDoneMirror = if (Test-Path -LiteralPath $backgroundDoneMirrorPath -PathType Leaf) { Get-Content -LiteralPath $backgroundDoneMirrorPath -Raw -Encoding utf8 } else { '' }
    $currentAfterBackgroundDone = Get-Content -LiteralPath $currentPath -Raw -Encoding utf8
    if ($backgroundDone.ExitCode -ne 0 -or $backgroundDoneMirror -notmatch '(?m)^stage:\s*DONE\s*$' -or $currentAfterBackgroundDone -notmatch [regex]::Escape($taskId)) {
        Add-Failure ('background DONE sync should leave current unchanged: {0}' -f ($backgroundDone.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'background DONE sync leaves current unchanged'
    }

    $currentHashBeforeDoneActivation = (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash
    $doneMirrorHashBeforeActivation = (Get-FileHash -LiteralPath $backgroundDoneMirrorPath -Algorithm SHA256).Hash
    $activateDone = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath $advanceShimPath -Arguments @{
        TaskId = $backgroundDoneTaskId
        ExpectedStage = 'DONE'
        SyncOnly = $true
        ActivateCurrent = $true
    }
    if ($activateDone.ExitCode -eq 0 -or
        (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash -ne $currentHashBeforeDoneActivation -or
        (Get-FileHash -LiteralPath $backgroundDoneMirrorPath -Algorithm SHA256).Hash -ne $doneMirrorHashBeforeActivation) {
        Add-Failure ('DONE activation should fail closed without runtime writes: {0}' -f ($activateDone.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'DONE activation fails closed without runtime writes'
    }

    $health = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health.ps1') -Arguments @{ VaultRoot = $vaultRoot }
    if ($health.ExitCode -ne 0 -or ($health.Output -join [Environment]::NewLine) -notmatch '(?m)^STATUS:\s+PASS\s*$') {
        Add-Failure ('health should pass for canonical runtime state: {0}' -f ($health.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'health passes for canonical runtime state'
    }

    $planHashBeforeDrift = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
    $currentContent = Get-Content -LiteralPath $currentPath -Raw -Encoding utf8
    $driftedCurrent = $currentContent.Replace('| 状态 | PLAN_REVIEW |', '| 状态 | TEST |')
    Set-Content -LiteralPath $currentPath -Value $driftedCurrent -Encoding utf8
    $currentRuntimePath = Join-Path $vaultRoot ('运行时\tasks\{0}.md' -f $taskId)
    "---`r`nschema_version: task-runtime/v1.1`r`ntask_id: $taskId`r`nstage: TEST`r`n---`r`n# damaged current runtime" | Set-Content -LiteralPath $currentRuntimePath -Encoding utf8

    $driftHealth = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health.ps1') -Arguments @{ VaultRoot = $vaultRoot }
    if ($driftHealth.ExitCode -ne 2 -or ($driftHealth.Output -join [Environment]::NewLine) -notmatch 'plan/current stage 漂移') {
        Add-Failure ('health should fail on plan/current stage drift: {0}' -f ($driftHealth.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'health fails on plan/current stage drift'
    }

    $repair = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\repair-shared-memory.ps1') -Arguments @{ VaultRoot = $vaultRoot; EntryHost = 'codex' }
    $planHashAfterRepair = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash
    $repairedHealth = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health.ps1') -Arguments @{ VaultRoot = $vaultRoot }
    $currentRuntimeRecords = @(Get-Content -LiteralPath $currentRuntimePath -Raw -Encoding utf8)
    if ($repair.ExitCode -ne 0 -or $planHashBeforeDrift -ne $planHashAfterRepair -or $repairedHealth.ExitCode -ne 0 -or $currentRuntimeRecords[0] -notmatch 'stage: PLAN_REVIEW') {
        Add-Failure ('repair should restore pointer/current mirror from plan truth without changing plan.md: repair={0}; health={1}' -f ($repair.Output -join [Environment]::NewLine), ($repairedHealth.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'repair restores pointer and damaged current mirror from plan truth without changing plan.md'
    }

    $legacyRuntimePath = Join-Path $vaultRoot '运行时\tasks\legacy-runtime.md'
    @(
        '---'
        'task_id: legacy-runtime'
        'stage: IMPLEMENT'
        'tool: codex'
        'entry_host: legacy-host'
        'updated: 2026-04-03T09:00:00+08:00'
        '---'
        '# Task Mirror'
        ''
        '- pointer: docs/tasks/legacy-runtime/plan.md'
        '- phase: legacy plan investigation'
        '- latest_finding: preserve this historical detail'
    ) -join "`r`n" | Set-Content -LiteralPath $legacyRuntimePath -Encoding utf8

    $legacyRepair = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\repair-shared-memory.ps1') -Arguments @{ VaultRoot = $vaultRoot; EntryHost = 'codex' }
    $legacyRuntimeContent = Get-Content -LiteralPath $legacyRuntimePath -Raw -Encoding utf8
    if ($legacyRepair.ExitCode -ne 0 -or $legacyRuntimeContent -notmatch 'schema_version: task-runtime/v1.1' -or $legacyRuntimeContent -notmatch 'stage: IMPLEMENT' -or $legacyRuntimeContent -match 'stage: DONE' -or $legacyRuntimeContent -notmatch '> - phase: legacy plan investigation' -or $legacyRuntimeContent -notmatch '> - latest_finding: preserve this historical detail') {
        Add-Failure 'repair should migrate only an explicit legacy Task Mirror while preserving its canonical stage and body'
    } else {
        Add-Check 'repair migrates an explicit legacy Task Mirror without inferring DONE or discarding its body'
    }

    $invalidRuntimePath = Join-Path $vaultRoot '运行时\tasks\invalid-runtime.md'
    "---`r`nschema_version: task-runtime/v1.1`r`ntask_id: invalid-runtime`r`nstage: TEST`r`n---`r`n# damaged canonical runtime" | Set-Content -LiteralPath $invalidRuntimePath -Encoding utf8
    $invalidRuntimeHash = (Get-FileHash -LiteralPath $invalidRuntimePath -Algorithm SHA256).Hash
    $invalidRepair = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\repair-shared-memory.ps1') -Arguments @{ VaultRoot = $vaultRoot; EntryHost = 'codex' }
    $invalidRuntimeContent = Get-Content -LiteralPath $invalidRuntimePath -Raw -Encoding utf8
    if ($invalidRepair.ExitCode -ne 1 -or ($invalidRepair.Output -join [Environment]::NewLine) -notmatch 'STATUS:\s+WARN' -or (Get-FileHash -LiteralPath $invalidRuntimePath -Algorithm SHA256).Hash -ne $invalidRuntimeHash -or $invalidRuntimeContent -match 'stage: DONE') {
        Add-Failure 'repair should preserve and warn on an invalid non-current canonical runtime without inferring DONE'
    } else {
        Add-Check 'repair preserves invalid non-current canonical runtime bytes and returns WARN without inferring DONE'
    }

    foreach ($nonDoneRuntimePath in @($backgroundMirrorPath, $legacyRuntimePath, $invalidRuntimePath)) {
        if (Test-Path -LiteralPath $nonDoneRuntimePath -PathType Leaf) {
            Remove-Item -LiteralPath $nonDoneRuntimePath -Force
        }
    }
    $preDoneRepair = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\repair-shared-memory.ps1') -Arguments @{ VaultRoot = $vaultRoot; EntryHost = 'codex' }
    if ($preDoneRepair.ExitCode -ne 0) {
        Add-Failure ('repair should rebuild the recovery index after isolated fixture cleanup: {0}' -f ($preDoneRepair.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'repair rebuilds the recovery index after isolated fixture cleanup'
    }

    $activeTestPlan = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
    $activeTestPlan = $activeTestPlan.Replace('stage: PLAN_REVIEW', 'stage: TEST')
    $activeTestPlan = [regex]::Replace($activeTestPlan, '(?ms)^## Plan Review\s*?(?=^## Implementation Notes)', @"
## Plan Review

### Run 1 · 2026-07-11 00:00 · runner: fixture
- verdict: pass
- findings: none
- next: IMPLEMENT

"@)
    $activeTestPlan = [regex]::Replace($activeTestPlan, '(?ms)^## Implementation Notes\s*?(?=^## Code Review)', @"
## Implementation Notes

### Run 1 · 2026-07-11 00:01 · runner: fixture
- changed: canonical runtime fixture only
- tests: fixture transition
- risks: none
- next: CODE_REVIEW

"@)
    $activeTestPlan = [regex]::Replace($activeTestPlan, '(?ms)^## Code Review\s*\z', @"
## Code Review

### Run 1 · 2026-07-11 00:02 · runner: fixture
- verdict: pass
- findings: none
- next: TEST
"@)
    $activeTestPlan | Set-Content -LiteralPath $planPath -Encoding utf8

    $testPath = Join-Path (Split-Path -Parent $planPath) 'test.md'
    @"
# Test Report

## Summary
- canonical TEST to DONE fixture.

## Scope
- isolated runtime transition.

## Inputs Reviewed
- plan.md

## Test Approach
- use the installed canonical stage shim.

## Findings
- none.

## Evidence
- command: fixture
- exit_code: 0
- executed_at: 2026-07-11T00:03:00+08:00
- revision: 0000000
- evidence_path: docs/tasks/$taskId/test.md

## Risks / Gaps
- isolated fixture only.

## Conclusion
pass

## Handoff
- delivery: fixture complete
- follow_up: none
"@ | Set-Content -LiteralPath $testPath -Encoding utf8

    $syncTest = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath $advanceShimPath -Arguments @{
        TaskId = $taskId
        ExpectedStage = 'TEST'
        SyncOnly = $true
    }
    if ($syncTest.ExitCode -ne 0) {
        Add-Failure ('TEST sync should align the canonical current pointer before DONE advance: {0}' -f ($syncTest.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'TEST sync aligns the canonical current pointer before DONE advance'
    }

    $activeDone = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath $advanceShimPath -Arguments @{
        TaskId = $taskId
        ExpectedStage = 'TEST'
    }
    $idleCurrent = Get-Content -LiteralPath $currentPath -Raw -Encoding utf8
    $activeDoneMirror = Get-Content -LiteralPath $currentRuntimePath -Raw -Encoding utf8
    if ($activeDone.ExitCode -ne 0 -or
        $idleCurrent -notmatch '(?m)^schema_version:\s*current-task-pointer/v1\.1\s*$' -or
        $idleCurrent -notmatch '(?m)^task_id:\s*none\s*$' -or
        $activeDoneMirror -notmatch '(?m)^stage:\s*DONE\s*$') {
        Add-Failure ('active DONE sync should write a canonical idle pointer: {0}' -f ($activeDone.Output -join [Environment]::NewLine))
    } else {
        Add-Check 'active DONE sync writes canonical idle current and DONE mirror'
    }

    $idleDoneHealth = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health.ps1') -Arguments @{ VaultRoot = $vaultRoot }
    $idleDoneHealthOutput = $idleDoneHealth.Output -join [Environment]::NewLine
    if ($idleDoneHealth.ExitCode -ne 0 -or $idleDoneHealthOutput -notmatch '(?m)^STATUS:\s+PASS\s*$' -or $idleDoneHealthOutput -match '共享指针显示为空') {
        Add-Failure ('idle current with only DONE history should pass memory health: {0}' -f $idleDoneHealthOutput)
    } else {
        Add-Check 'idle current with only DONE history passes memory health'
    }

    $orphanTaskId = 'runtime-unfinished-orphan'
    $orphanRuntimePath = Join-Path $vaultRoot "运行时\tasks\$orphanTaskId.md"
    New-CanonicalTaskRuntimeContent `
        -TaskId $orphanTaskId `
        -TaskName $orphanTaskId `
        -Stage 'PLAN' `
        -WorkspaceRoot $workspaceRoot `
        -ArtifactRoot "docs/tasks/$orphanTaskId" `
        -PrimaryArtifact "docs/tasks/$orphanTaskId/plan.md" `
        -Tool 'codex' `
        -EntryHost 'codex' |
        Set-Content -LiteralPath $orphanRuntimePath -Encoding utf8
    $idleState = Get-CanonicalCurrentTaskState -Path $currentPath
    $recordsWithOrphan = Get-CanonicalTaskRuntimeRecords -TasksDirectory (Split-Path -Parent $orphanRuntimePath)
    New-CanonicalRecoveryIndexContent -CurrentTask $idleState -TaskRecords $recordsWithOrphan |
        Set-Content -LiteralPath (Join-Path $vaultRoot '运行时\恢复索引.md') -Encoding utf8

    $orphanHealth = Invoke-WithUserProfile -UserProfile $userRoot -WorkingDirectory $workspaceRoot -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health.ps1') -Arguments @{ VaultRoot = $vaultRoot }
    $orphanHealthOutput = $orphanHealth.Output -join [Environment]::NewLine
    if ($orphanHealth.ExitCode -ne 1 -or
        $orphanHealthOutput -notmatch '(?m)^STATUS:\s+WARN\s*$' -or
        $orphanHealthOutput -notmatch [regex]::Escape("task_id=$orphanTaskId") -or
        $orphanHealthOutput -notmatch [regex]::Escape($orphanRuntimePath)) {
        Add-Failure ('idle current with an unfinished orphan should warn with its task id and path: {0}' -f $orphanHealthOutput)
    } else {
        Add-Check 'idle current with an unfinished orphan warns with its task id and path'
    }

    foreach ($reservedTaskId in @('none', 'idle', 'unknown')) {
        $reservedTaskRoot = Join-Path $workspaceRoot "docs\tasks\$reservedTaskId"
        $reservedPlanPath = Join-Path $reservedTaskRoot 'plan.md'
        $reservedMirrorPath = Join-Path $vaultRoot "运行时\tasks\$reservedTaskId.md"
        $reservedManifestPath = Join-Path $reservedTaskRoot 'skill-manifest.json'
        New-Item -ItemType Directory -Path $reservedTaskRoot -Force | Out-Null
        $planContent.Replace("task_id: $taskId", "task_id: $reservedTaskId") |
            Set-Content -LiteralPath $reservedPlanPath -Encoding utf8

        $reservedStatePaths = @(
            $reservedPlanPath,
            $reservedMirrorPath,
            $reservedManifestPath,
            $currentPath,
            (Join-Path $vaultRoot '运行时\恢复索引.md'),
            (Join-Path $vaultRoot '运行时\中断任务.md'),
            (Join-Path $vaultRoot '运行时\收件箱.md')
        )

        $beforeValidator = Get-FileSetFingerprint -Paths $reservedStatePaths
        $reservedValidator = Invoke-WithUserProfile `
            -UserProfile $userRoot `
            -WorkingDirectory $workspaceRoot `
            -ScriptPath $validatorShimPath `
            -Arguments @{ TaskId = $reservedTaskId }
        $afterValidator = Get-FileSetFingerprint -Paths $reservedStatePaths
        if ($reservedValidator.ExitCode -eq 0 -or $afterValidator -cne $beforeValidator) {
            Add-Failure ('validator should reject reserved TaskId {0} without writes: exit={1}; output={2}' -f
                $reservedTaskId,
                $reservedValidator.ExitCode,
                ($reservedValidator.Output -join [Environment]::NewLine))
        } else {
            Add-Check ('validator rejects reserved TaskId {0} without writes' -f $reservedTaskId)
        }

        $beforeAdvance = Get-FileSetFingerprint -Paths $reservedStatePaths
        $reservedAdvance = Invoke-WithUserProfile `
            -UserProfile $userRoot `
            -WorkingDirectory $workspaceRoot `
            -ScriptPath $advanceShimPath `
            -Arguments @{
                TaskId = $reservedTaskId
                ExpectedStage = 'PLAN'
                SyncOnly = $true
            }
        $afterAdvance = Get-FileSetFingerprint -Paths $reservedStatePaths
        if ($reservedAdvance.ExitCode -eq 0 -or $afterAdvance -cne $beforeAdvance) {
            Add-Failure ('advance should reject reserved TaskId {0} without plan/runtime writes: exit={1}; output={2}' -f
                $reservedTaskId,
                $reservedAdvance.ExitCode,
                ($reservedAdvance.Output -join [Environment]::NewLine))
        } else {
            Add-Check ('advance rejects reserved TaskId {0} without plan/runtime writes' -f $reservedTaskId)
        }
    }
} finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    $script:Checks | ForEach-Object { Write-Output ('- {0}' -f $_) }
}
Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}
$script:Failures | ForEach-Object { Write-Output ('- {0}' -f $_) }
exit 1
