[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string]$EntryHost = "",
    [string]$RetireInactiveTaskId = "",
    [string]$ExpectedRetireStage = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# TK-03: retained source is not a live lifecycle writer, including retirement.
[Console]::Error.WriteLine('v1-memory-repair-retired: preserve legacy history; use explicit paused migration maintenance.')
exit 2

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

function Invoke-InactiveTaskRetirement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedStage,
        [Parameter(Mandatory = $true)]
        [string]$ResolvedVaultRoot
    )

    $validRetirementStages = @('PLAN', 'PLAN_REVIEW', 'IMPLEMENT', 'CODE_REVIEW', 'TEST')
    Assert-LiteTaskId -TaskId $TaskId
    if ($ExpectedStage -cnotin $validRetirementStages) {
        throw ('ExpectedRetireStage must be an unfinished canonical stage, got: {0}' -f $ExpectedStage)
    }

    $workspaceRoot = Split-Path -Parent $ResolvedVaultRoot
    $taskBase = Resolve-LiteContainedPath -Root $workspaceRoot -RelativePath 'docs\tasks' -Label 'task base'
    $taskRoot = Resolve-LiteContainedPath -Root $taskBase -RelativePath $TaskId -Label 'retirement task root'
    $planPath = Resolve-LiteContainedPath -Root $taskRoot -RelativePath 'plan.md' -Label 'retirement plan path'
    $paths = Get-RuntimeMarkdownPaths -VaultRoot $ResolvedVaultRoot
    $mirrorPath = Resolve-LiteContainedPath -Root $paths.TasksDir -RelativePath ("{0}.md" -f $TaskId) -Label 'retirement mirror path'

    $planMutex = $null
    $runtimeMutex = $null
    try {
        $planMutex = Enter-LitePlanMutex -TaskId $TaskId
        $runtimeMutex = Enter-CanonicalRuntimeMutex -VaultRoot $ResolvedVaultRoot

        if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
            throw "Missing retirement plan: $planPath"
        }
        if (-not (Test-Path -LiteralPath $mirrorPath -PathType Leaf)) {
            throw "Missing inactive task mirror: $mirrorPath"
        }
        if (-not (Test-Path -LiteralPath $paths.CurrentTaskPath -PathType Leaf)) {
            throw "Missing canonical current task pointer: $($paths.CurrentTaskPath)"
        }
        if (-not (Test-Path -LiteralPath $paths.RecoveryIndexPath -PathType Leaf)) {
            throw "Missing canonical recovery index: $($paths.RecoveryIndexPath)"
        }
        if (-not (Test-Path -LiteralPath $paths.InboxPath -PathType Leaf)) {
            throw "Missing runtime inbox: $($paths.InboxPath)"
        }
        if (-not (Test-Path -LiteralPath $paths.InterruptedPath -PathType Leaf)) {
            throw "Missing interrupted-task view: $($paths.InterruptedPath)"
        }

        $planText = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
        $frontmatter = (Get-LiteFrontmatter -Content $planText).Fields
        if (-not $frontmatter.Contains('task_id') -or $frontmatter.task_id -cne $TaskId) {
            throw 'Retirement plan task_id does not match the requested TaskId.'
        }
        if (-not $frontmatter.Contains('stage') -or $frontmatter.stage -cne $ExpectedStage) {
            $actualStage = if ($frontmatter.Contains('stage')) { $frontmatter.stage } else { '<missing>' }
            throw ("ExpectedRetireStage CAS mismatch: expected {0}, actual {1}." -f $ExpectedStage, $actualStage)
        }

        $current = Get-CanonicalCurrentTaskState -Path $paths.CurrentTaskPath
        if (-not $current.Exists -or
            $current.SchemaVersion -cne 'current-task-pointer/v1.1' -or
            [string]::IsNullOrWhiteSpace($current.TaskId) -or
            [string]::IsNullOrWhiteSpace($current.EntryHost) -or
            [string]::IsNullOrWhiteSpace($current.Writer) -or
            [string]::IsNullOrWhiteSpace($current.Updated)) {
            throw 'Current task pointer is not canonical; repair it before retiring an inactive task.'
        }
        if ($current.TaskId -ceq $TaskId) {
            throw 'Cannot retire the active task.'
        }
        if (Test-IsIdleValue -Value $current.TaskId) {
            if ($current.Stage -cne '空闲' -or $current.CurrentDoc -cne 'none') {
                throw 'Idle current task pointer is not canonical.'
            }
        } elseif (-not (Test-CanonicalRuntimeTaskId -TaskId $current.TaskId) -or
            -not (Test-CanonicalRuntimeStage -Stage $current.Stage)) {
            throw 'Active current task pointer is not canonical.'
        }

        $records = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory $paths.TasksDir)
        if (@($records | Where-Object { -not $_.IsValid }).Count -gt 0) {
            throw 'All task runtime mirrors must be canonical before retirement.'
        }
        $targetRecords = @($records | Where-Object { $_.TaskId -ceq $TaskId })
        if ($targetRecords.Count -ne 1) {
            throw ('Expected exactly one canonical target mirror, found: {0}' -f $targetRecords.Count)
        }

        $target = $targetRecords[0]
        $expectedFileName = "{0}.md" -f $TaskId
        $expectedArtifactRoot = "docs/tasks/{0}" -f $TaskId
        $expectedPrimaryArtifact = "{0}/plan.md" -f $expectedArtifactRoot
        $targetWorkspace = try { [System.IO.Path]::GetFullPath($target.Workspace) } catch { '' }
        if (-not ([System.IO.Path]::GetFullPath($target.Path)).Equals([System.IO.Path]::GetFullPath($mirrorPath), [System.StringComparison]::OrdinalIgnoreCase) -or
            $target.FileName -cne $expectedFileName -or
            $target.Stage -cne $ExpectedStage -or
            -not $targetWorkspace.Equals([System.IO.Path]::GetFullPath($workspaceRoot), [System.StringComparison]::OrdinalIgnoreCase) -or
            $target.ArtifactRoot -cne $expectedArtifactRoot -or
            $target.PrimaryArtifact -cne $expectedPrimaryArtifact) {
            throw 'Target task mirror does not match the requested task, stage, workspace, or artifact path.'
        }

        $inbox = Read-RuntimeInbox -VaultRoot $ResolvedVaultRoot
        $openFallbacks = @($inbox.Rows | Where-Object {
                $_.TaskId -ceq $TaskId -and
                $_.Type -ceq 'writeback-fallback' -and
                $_.Status -ceq 'open'
            })
        if ($openFallbacks.Count -gt 0) {
            throw 'Cannot retire a task with an open writeback-fallback.'
        }

        $interruptedText = Get-Content -LiteralPath $paths.InterruptedPath -Raw -Encoding utf8
        if ($interruptedText -match ('(?m)^\|[^\r\n]*\|\s*{0}\s*\|[^\r\n]*$' -f [regex]::Escape($TaskId))) {
            throw 'Cannot retire a task still referenced by the interrupted-task view.'
        }

        $oldMirror = Get-Content -LiteralPath $mirrorPath -Raw -Encoding utf8
        $oldIndex = Get-Content -LiteralPath $paths.RecoveryIndexPath -Raw -Encoding utf8
        $remainingRecords = @($records | Where-Object { $_.TaskId -cne $TaskId })
        $newIndex = New-CanonicalRecoveryIndexContent `
            -CurrentTask $current `
            -TaskRecords $remainingRecords `
            -Updated (Get-CanonicalRuntimeTimestamp) `
            -Writer 'repair-shared-memory'

        try {
            Remove-Item -LiteralPath $mirrorPath -Force
            Write-CanonicalRuntimeUtf8BomAtomic -Path $paths.RecoveryIndexPath -Content $newIndex
            if (Test-Path -LiteralPath $mirrorPath -PathType Leaf) {
                throw 'Retirement postcondition failed: target mirror still exists.'
            }
            $actualIndex = Get-Content -LiteralPath $paths.RecoveryIndexPath -Raw -Encoding utf8
            if ($actualIndex -cne $newIndex) {
                throw 'Retirement postcondition failed: recovery index does not match canonical output.'
            }
        } catch {
            $retirementError = $_.Exception.Message
            $rollbackErrors = @()
            try {
                $currentMirror = if (Test-Path -LiteralPath $mirrorPath -PathType Leaf) {
                    Get-Content -LiteralPath $mirrorPath -Raw -Encoding utf8
                } else {
                    $null
                }
                if ($null -eq $currentMirror -or $currentMirror -cne $oldMirror) {
                    Write-CanonicalRuntimeUtf8BomAtomic -Path $mirrorPath -Content $oldMirror
                }
            } catch {
                $rollbackErrors += ('mirror: {0}' -f $_.Exception.Message)
            }
            try {
                $currentIndex = if (Test-Path -LiteralPath $paths.RecoveryIndexPath -PathType Leaf) {
                    Get-Content -LiteralPath $paths.RecoveryIndexPath -Raw -Encoding utf8
                } else {
                    $null
                }
                if ($null -eq $currentIndex -or $currentIndex -cne $oldIndex) {
                    Write-CanonicalRuntimeUtf8BomAtomic -Path $paths.RecoveryIndexPath -Content $oldIndex
                }
            } catch {
                $rollbackErrors += ('index: {0}' -f $_.Exception.Message)
            }
            if ($rollbackErrors.Count -gt 0) {
                throw ('Inactive task retirement failed: {0}; rollback failed: {1}' -f $retirementError, ($rollbackErrors -join '; '))
            }
            throw ('Inactive task retirement failed and was rolled back: {0}' -f $retirementError)
        }
    } finally {
        if ($null -ne $runtimeMutex) {
            Exit-CanonicalRuntimeMutex -Mutex $runtimeMutex
        }
        if ($null -ne $planMutex) {
            Exit-LitePlanMutex -Mutex $planMutex
        }
    }
}

$hasRetirementTask = -not [string]::IsNullOrWhiteSpace($RetireInactiveTaskId)
$hasRetirementStage = -not [string]::IsNullOrWhiteSpace($ExpectedRetireStage)
if ($hasRetirementTask -xor $hasRetirementStage) {
    Write-Error 'RetireInactiveTaskId and ExpectedRetireStage must be provided together.' -ErrorAction Continue
    exit 1
}

if ($hasRetirementTask) {
    try {
        . (Join-Path $PSScriptRoot 'lite-artifact-parser.ps1')
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1')
        $resolvedVaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot
        Invoke-InactiveTaskRetirement `
            -TaskId $RetireInactiveTaskId `
            -ExpectedStage $ExpectedRetireStage `
            -ResolvedVaultRoot $resolvedVaultRoot
        Write-Output 'STATUS: PASS'
        Write-Output ('Retired inactive task: {0} @ {1}' -f $RetireInactiveTaskId, $ExpectedRetireStage)
        exit 0
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}

$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'repair-shared-memory.ps1'
& $scriptPath -VaultRoot $VaultRoot -EntryHost $EntryHost
exit $LASTEXITCODE
