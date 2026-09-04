
. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')
$script:TaskStateModule = Import-Module (Join-Path $PSScriptRoot 'Harness.TaskState.psm1') -Force -PassThru -ErrorAction Stop

$script:RuntimeRelative = '.assistant/runtime'

function Read-HarnessRecoveryPointer {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )
    return & $script:TaskStateModule { param($Root,$Path) Read-CurrentPointer -WorkspaceRoot $Root -Path $Path } $WorkspaceRoot "$($script:RuntimeRelative)/current.json"
}

function Get-HarnessRecoveryIndex {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $tasksRoot = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/tasks" -Label 'runtime tasks' -AllowMissing
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $terminalCount = 0
        $tasks = @(if (Test-Path -LiteralPath $tasksRoot) {
            Assert-HarnessKernelCondition (Test-Path -LiteralPath $tasksRoot -PathType Container) 'runtime tasks path is not a directory'
            foreach ($directory in Get-ChildItem -LiteralPath $tasksRoot -Directory -Force | Sort-Object Name) {
                if ($directory.Name -cmatch '^\.migration-(?!(?:none|idle|unknown)-)[a-z0-9][a-z0-9-]{0,63}-[0-9a-f]{32}$') { continue }
                Assert-HarnessTaskId -TaskId $directory.Name
                $status = Get-HarnessTaskStatus -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $directory.Name
                if ([string]$status.task.status -cin @('done','cancelled')) { $terminalCount++ } else {
                    [ordered]@{task_id=[string]$status.task.task_id;task_version=[int]$status.task.version
                        status=[string]$status.task.status;execution_profile=[string]$status.task.execution_profile
                        requirement_state=[string]$status.task.requirement_state;is_current=[bool]$status.is_current
                        resume_allowed=[string]$status.task.requirement_state -ceq 'clear' -and [string]$status.task.status -cin @('ready','running','paused','failed')
                        pending_transactions=@($status.pending_transactions);updated_at=[string]$status.task.updated_at}
                }
            }
        })
        try { $pointer = Read-HarnessRecoveryPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot }
        catch { throw "current pointer validation failed: $($_.Exception.Message)" }
        $currentTasks = @($tasks | Where-Object { [bool]$_.is_current })
        $stable = if ($null -eq $pointer) { $currentTasks.Count -eq 0 } else { $currentTasks.Count -eq 1 -and [string]$currentTasks[0].task_id -ceq [string]$pointer.task_id -and [int]$currentTasks[0].task_version -eq [int]$pointer.task_version }
        if ($stable) { break }
    }
    Assert-HarnessKernelCondition $stable 'recovery state changed during snapshot; retry status'
    return [ordered]@{operation='recovery-index'
        schema_version='recovery-index/v2'
        generated_at=[datetimeoffset]::UtcNow.ToString('o')
        source=$script:RuntimeRelative
        current=$(if($null-ne$pointer){[ordered]@{task_id=[string]$pointer.task_id;task_version=[int]$pointer.task_version
            status=[string]$currentTasks[0].status;activated_at=[string]$pointer.activated_at}}else{$null})
        tasks=@($tasks)
        terminal_task_count=$terminalCount
        side_effects=New-HarnessZeroSideEffects}
}

function Get-HarnessResumeClarification {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$TaskId = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Assert-HarnessTaskId -TaskId $TaskId }
    return [ordered]@{operation='resume'
        requirement_state='blocked'
        write_authorized=$false
        requested_task_id=$(if ([string]::IsNullOrWhiteSpace($TaskId)){$null}else{$TaskId})
        blocking_decision='Use resume-and-execute with an explicit TaskId to authorize one CAS-protected state mutation.'
        recovery=(Get-HarnessRecoveryIndex -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot)
        side_effects=New-HarnessZeroSideEffects}
}

Export-ModuleMember -Function Get-HarnessRecoveryIndex,Get-HarnessResumeClarification
