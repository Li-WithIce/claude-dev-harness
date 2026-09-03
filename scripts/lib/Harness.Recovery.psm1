
. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')
$script:TaskStateModule = Import-Module (Join-Path $PSScriptRoot 'Harness.TaskState.psm1') -Force -PassThru -ErrorAction Stop

$script:RuntimeRelative = '.assistant/runtime'

function Read-HarnessRecoveryPointer {
    param([string]$RepoRoot,[string]$WorkspaceRoot)
    return & $script:TaskStateModule { param($Root,$Path) Read-CurrentPointer -WorkspaceRoot $Root -Path $Path } $WorkspaceRoot "$($script:RuntimeRelative)/current.json"
}

function Get-HarnessRecoveryIndex {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot)
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
                    $task = Select-HarnessKernelKeys -Value $status.task -Keys @('task_id','status','execution_profile','requirement_state')
                    $task.Insert(1,'task_version',[int]$status.task.version)
                    $task.is_current = [bool]$status.is_current
                    $task.resume_allowed = [string]$status.task.requirement_state -ceq 'clear' -and [string]$status.task.status -cin @('ready','running','paused','failed')
                    $task.pending_transactions = @($status.pending_transactions)
                    $task.updated_at = [string]$status.task.updated_at
                    $task
                }
            }
        })
        try { $pointer = Read-HarnessRecoveryPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot }
        catch { throw "current pointer validation failed: $($_.Exception.Message)" }
        $currentTasks = @($tasks | Where-Object { [bool]$_.is_current })
        $stable = if ($null -eq $pointer) { $currentTasks.Count -eq 0 } else { $currentTasks.Count -eq 1 -and [string]$currentTasks[0].task_id -ceq [string]$pointer.task_id -and [int]$currentTasks[0].task_version -eq [int]$pointer.task_version }
        $currentSnapshot = if ($stable -and $null -ne $pointer) {
            $snapshot = Select-HarnessKernelKeys -Value $pointer -Keys @('task_id','task_version','activated_at')
            $snapshot.Insert(2,'status',[string]$currentTasks[0].status)
            $snapshot
        } else { $null }
        if ($stable) { break }
    }
    Assert-HarnessKernelCondition $stable 'recovery state changed during snapshot; retry status'
    return [ordered]@{operation='recovery-index'
        schema_version='recovery-index/v2'
        generated_at=[datetimeoffset]::UtcNow.ToString('o')
        source=$script:RuntimeRelative
        current=$currentSnapshot
        tasks=@($tasks)
        terminal_task_count=$terminalCount
        side_effects=New-HarnessZeroSideEffects}
}

function Get-HarnessResumeClarification {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[string]$TaskId='')
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
