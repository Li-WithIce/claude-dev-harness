Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.TaskState.psm1') -Force -ErrorAction Stop

$script:RuntimeRelative = '.assistant/runtime'

function Read-HarnessRecoveryPointer {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )

    $pointerPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/current.json" -Label 'current pointer' -AllowMissing
    if (-not (Test-Path -LiteralPath $pointerPath)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        throw 'current pointer is not a file'
    }

    try {
        $pointer = [System.IO.File]::ReadAllText($pointerPath,[System.Text.UTF8Encoding]::new($false,$true)) |
            ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    } catch {
        throw "current pointer is not valid JSON: $($_.Exception.Message)"
    }
    try {
        $valid = Test-Json -Json ($pointer | ConvertTo-Json -Depth 10 -Compress) -SchemaFile (Join-Path $RepoRoot 'schemas\current-pointer.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        throw "current pointer schema validation failed: $($_.Exception.Message)"
    }
    if (-not $valid) {
        throw 'current pointer failed schema validation'
    }
    return $pointer
}

function Get-HarnessRecoveryIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $tasksRoot = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/tasks" -Label 'runtime tasks' -AllowMissing
    $pointer = Read-HarnessRecoveryPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
    $tasks = [System.Collections.Generic.List[object]]::new()
    $terminalCount = 0

    if (Test-Path -LiteralPath $tasksRoot) {
        if (-not (Test-Path -LiteralPath $tasksRoot -PathType Container)) {
            throw 'runtime tasks path is not a directory'
        }
        foreach ($directory in Get-ChildItem -LiteralPath $tasksRoot -Directory -Force | Sort-Object Name) {
            if ($directory.Name -cmatch '^\.migration-(?!(?:none|idle|unknown)-)[a-z0-9][a-z0-9-]{0,63}-[0-9a-f]{32}$') {
                continue
            }
            Assert-HarnessTaskId -TaskId $directory.Name
            $status = Get-HarnessTaskStatus -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $directory.Name
            if ([string]$status.task.status -cin @('done','cancelled')) {
                $terminalCount++
                continue
            }
            $tasks.Add([ordered]@{
                task_id = [string]$status.task.task_id
                task_version = [int]$status.task.version
                status = [string]$status.task.status
                execution_profile = [string]$status.task.execution_profile
                requirement_state = [string]$status.task.requirement_state
                is_current = [bool]$status.is_current
                resume_allowed = [string]$status.task.requirement_state -ceq 'clear' -and [string]$status.task.status -cin @('ready','running','paused','failed')
                pending_transactions = @($status.pending_transactions)
                updated_at = [string]$status.task.updated_at
            })
        }
    }

    $current = $null
    if ($null -ne $pointer) {
        $currentMatches = @($tasks | Where-Object { [string]$_.task_id -ceq [string]$pointer.task_id })
        if ($currentMatches.Count -ne 1) {
            throw 'current pointer does not reference one nonterminal runtime task'
        }
        if ([int]$currentMatches[0].task_version -ne [int]$pointer.task_version) {
            throw 'current pointer task_version is stale'
        }
        $current = [ordered]@{
            task_id = [string]$pointer.task_id
            task_version = [int]$pointer.task_version
            status = [string]$currentMatches[0].status
            activated_at = [string]$pointer.activated_at
        }
    }

    return [ordered]@{
        operation = 'recovery-index'
        schema_version = 'recovery-index/v2'
        generated_at = [datetimeoffset]::UtcNow.ToString('o')
        source = $script:RuntimeRelative
        current = $current
        tasks = @($tasks)
        terminal_task_count = $terminalCount
        side_effects = [ordered]@{
            task_state_writes = 0
            runtime_writes = 0
            artifact_writes = 0
            external_writes = 0
        }
    }
}

function Get-HarnessResumeClarification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$TaskId = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        Assert-HarnessTaskId -TaskId $TaskId
    }
    $index = Get-HarnessRecoveryIndex -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
    return [ordered]@{
        operation = 'resume'
        requirement_state = 'blocked'
        write_authorized = $false
        requested_task_id = $(if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId })
        blocking_decision = 'Use resume-and-execute with an explicit TaskId and ExpectedVersion to authorize state mutation.'
        recovery = $index
        side_effects = [ordered]@{
            task_state_writes = 0
            runtime_writes = 0
            artifact_writes = 0
            external_writes = 0
        }
    }
}

Export-ModuleMember -Function Get-HarnessRecoveryIndex,Get-HarnessResumeClarification
