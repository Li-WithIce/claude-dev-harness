[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = '',
    [string]$RequestFile = '',
    [string]$TaskId = '',
    [string]$Contract = '',
    [ValidateSet('governed', 'critical')][string]$Profile = 'governed',
    [string[]]$Capabilities = @(),
    [Nullable[int]]$ExpectedVersion = $null,
    [ValidateSet('blocked', 'ready', 'running', 'verifying', 'paused', 'done', 'failed', 'cancelled')][string]$To = 'ready',
    [string]$Reason = '',
    [switch]$ActivateCurrent,
    [switch]$EvidenceSatisfied,
    [string]$Evidence = '',
    [string]$TransactionId = '',
    [string]$ActorHost = 'codex',
    [string]$ActorModel = 'inherit',
    [string]$RepoRoot = '',
    [string]$WorkspaceRoot = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = $RepoRoot
    }
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    if ($EvidenceSatisfied) {
        throw '-EvidenceSatisfied was removed; use verify -Evidence'
    }

    if ($Command -ceq 'inspect') {
        if ([string]::IsNullOrWhiteSpace($RequestFile)) {
            throw 'inspect requires -RequestFile'
        }
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Requirement.psm1') -Force -ErrorAction Stop
        $result = Invoke-RequirementInspection -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -RequestFile $RequestFile
    } else {
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.TaskState.psm1') -Force -ErrorAction Stop
        if ($Command -ceq 'create') {
            if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Contract)) {
                throw 'create requires -TaskId and -Contract'
            }
            $result = New-HarnessTaskState -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractPath $Contract -Profile $Profile -Capabilities $Capabilities -ActivateCurrent:$ActivateCurrent -ActorHost $ActorHost -ActorModel $ActorModel
        } elseif ($Command -ceq 'status') {
            if ([string]::IsNullOrWhiteSpace($TaskId)) {
                throw 'status requires -TaskId'
            }
            $result = Get-HarnessTaskStatus -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
        } elseif ($Command -ceq 'transition') {
            if ([string]::IsNullOrWhiteSpace($TaskId) -or $null -eq $ExpectedVersion) {
                throw 'transition requires -TaskId and -ExpectedVersion'
            }
            $result = Set-HarnessTaskTransition -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ExpectedVersion ([int]$ExpectedVersion) -To $To -Reason $Reason -ContractPath $Contract -EvidenceSatisfied:$EvidenceSatisfied -ActorHost $ActorHost -ActorModel $ActorModel
        } elseif ($Command -ceq 'verify') {
            if ([string]::IsNullOrWhiteSpace($TaskId) -or $null -eq $ExpectedVersion -or [string]::IsNullOrWhiteSpace($Evidence)) {
                throw 'verify requires -TaskId, -ExpectedVersion, and -Evidence'
            }
            $result = Set-HarnessTaskEvidence -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ExpectedVersion ([int]$ExpectedVersion) -EvidencePath $Evidence -ActorHost $ActorHost -ActorModel $ActorModel
        } elseif ($Command -ceq 'replay') {
            if ([string]::IsNullOrWhiteSpace($TransactionId)) {
                throw 'replay requires -TransactionId'
            }
            $result = Repair-HarnessTaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId
        } else {
            throw "unsupported task command: $Command"
        }
    }

    if ($AsJson) {
        Write-Output ($result | ConvertTo-Json -Depth 30 -Compress)
    } elseif ($Command -ceq 'inspect') {
        Write-Output ("requirement_state: {0}" -f $result.requirement_state)
        Write-Output ("blocking_decisions: {0}" -f @($result.blocking_decisions).Count)
        Write-Output ("contract_digest: {0}" -f $(if ($null -eq $result.contract) { 'none' } else { $result.contract.digest }))
    } elseif ($Command -ceq 'status') {
        Write-Output ("task_id: {0}" -f $result.task.task_id)
        Write-Output ("version: {0}" -f $result.task.version)
        Write-Output ("status: {0}" -f $result.task.status)
        Write-Output ("is_current: {0}" -f ([string]$result.is_current).ToLowerInvariant())
        Write-Output ("pending_transactions: {0}" -f @($result.pending_transactions).Count)
    } elseif ($Command -ceq 'replay') {
        Write-Output ("transaction_id: {0}" -f $result.transaction_id)
        Write-Output ("result: {0}" -f $result.result)
    } elseif ($Command -ceq 'verify') {
        Write-Output ("operation: {0}" -f $result.operation)
        Write-Output ("task_id: {0}" -f $result.task.task_id)
        Write-Output ("version: {0}" -f $result.task.version)
        Write-Output ("status: {0}" -f $result.task.status)
        Write-Output ("conclusion: {0}" -f $result.conclusion)
        Write-Output ("evidence_path: {0}" -f $result.evidence_path)
        Write-Output ("pointer_action: {0}" -f $result.pointer_action)
    } else {
        Write-Output ("operation: {0}" -f $result.operation)
        Write-Output ("task_id: {0}" -f $result.task.task_id)
        Write-Output ("version: {0}" -f $result.task.version)
        Write-Output ("status: {0}" -f $result.task.status)
        Write-Output ("pointer_action: {0}" -f $result.pointer_action)
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
