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
    [string]$Approval = '',
    [string]$TransactionId = '',
    [string]$ActorHost = 'codex',
    [string]$ActorModel = 'inherit',
    [string]$RepoRoot = '',
    [string]$WorkspaceRoot = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AutoExpectedVersionUsed = $false

function Resolve-HarnessEntryExpectedVersion {
    param(
        [Parameter(Mandatory)][string]$ResolvedRepoRoot,
        [Parameter(Mandatory)][string]$ResolvedWorkspaceRoot,
        [Parameter(Mandatory)][string]$ResolvedTaskId,
        [AllowNull()][Nullable[int]]$ProvidedVersion
    )

    if ($null -ne $ProvidedVersion) { return [int]$ProvidedVersion }
    $status = Get-HarnessTaskStatus -RepoRoot $ResolvedRepoRoot -WorkspaceRoot $ResolvedWorkspaceRoot -TaskId $ResolvedTaskId
    $version = [int]$status.task.version
    $script:AutoExpectedVersionUsed = $true

    $readyName = [Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_CLI_VERSION_READY_EVENT',[EnvironmentVariableTarget]::Process)
    $releaseName = [Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_CLI_VERSION_RELEASE_EVENT',[EnvironmentVariableTarget]::Process)
    if ([string]::IsNullOrWhiteSpace($readyName) -xor [string]::IsNullOrWhiteSpace($releaseName)) {
        throw 'task CLI version test barrier requires both event names'
    }
    if (-not [string]::IsNullOrWhiteSpace($readyName)) {
        $ready = [Threading.EventWaitHandle]::OpenExisting($readyName)
        $release = [Threading.EventWaitHandle]::OpenExisting($releaseName)
        try {
            [void]$ready.Set()
            if (-not $release.WaitOne(10000)) { throw 'task CLI version test barrier timed out' }
        } finally {
            $release.Dispose()
            $ready.Dispose()
        }
    }
    return $version
}

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

    if ($Command -cin @('enable-v2','reset-auto','disable-v2')) {
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -ErrorAction Stop
        $protocolValue=if($Command -ceq 'reset-auto'){'auto'}else{'v2'}
        $result=Set-HarnessWorkspaceProtocolConfig -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -NewTaskProtocol $protocolValue -PauseNewWork:($Command -ceq 'disable-v2')
    } elseif ($Command -ceq 'protocol') {
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -ErrorAction Stop
        $result = Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    } elseif ($Command -ceq 'inspect') {
        if ([string]::IsNullOrWhiteSpace($RequestFile)) {
            throw 'inspect requires -RequestFile'
        }
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Requirement.psm1') -Force -ErrorAction Stop
        $result = Invoke-RequirementInspection -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -RequestFile $RequestFile
    } elseif ($Command -ceq 'status' -and [string]::IsNullOrWhiteSpace($TaskId)) {
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Recovery.psm1') -Force -ErrorAction Stop
        $result = Get-HarnessRecoveryIndex -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
    } elseif ($Command -ceq 'resume') {
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Recovery.psm1') -Force -ErrorAction Stop
        $result = Get-HarnessResumeClarification -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    } else {
        if ($Command -cne 'replay') {
            Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -ErrorAction Stop
            $protocol = Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
            if ([string]$protocol.selected_protocol -cne 'v2') {
                throw "new-work-not-admitted: $($protocol.reason); recover existing v2 tasks or explicitly repair admission"
            }
            $env:HARNESS_PROTOCOL = 'v2'
        } else {
            $env:HARNESS_PROTOCOL = 'v2'
        }
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.TaskState.psm1') -Force -ErrorAction Stop
        if ($Command -ceq 'create') {
            if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Contract)) {
                throw 'create requires -TaskId and -Contract'
            }
            $result = New-HarnessTaskState -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractPath $Contract -Profile $Profile -Capabilities $Capabilities -ActivateCurrent:$ActivateCurrent -ActorHost $ActorHost -ActorModel $ActorModel
        } elseif ($Command -ceq 'status') {
            $result = Get-HarnessTaskStatus -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
        } elseif ($Command -ceq 'transition') {
            if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'transition requires -TaskId' }
            $resolvedVersion = Resolve-HarnessEntryExpectedVersion -ResolvedRepoRoot $RepoRoot -ResolvedWorkspaceRoot $WorkspaceRoot -ResolvedTaskId $TaskId -ProvidedVersion $ExpectedVersion
            $result = Set-HarnessTaskTransition -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ExpectedVersion $resolvedVersion -To $To -Reason $Reason -ContractPath $Contract -EvidenceSatisfied:$EvidenceSatisfied -ActorHost $ActorHost -ActorModel $ActorModel
        } elseif ($Command -ceq 'verify') {
            if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Evidence)) { throw 'verify requires -TaskId and -Evidence' }
            $resolvedVersion = Resolve-HarnessEntryExpectedVersion -ResolvedRepoRoot $RepoRoot -ResolvedWorkspaceRoot $WorkspaceRoot -ResolvedTaskId $TaskId -ProvidedVersion $ExpectedVersion
            $result = Set-HarnessTaskEvidence -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ExpectedVersion $resolvedVersion -EvidencePath $Evidence -ActorHost $ActorHost -ActorModel $ActorModel
        } elseif ($Command -ceq 'approve') {
            if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Approval)) { throw 'approve requires -TaskId and -Approval' }
            $resolvedVersion = Resolve-HarnessEntryExpectedVersion -ResolvedRepoRoot $RepoRoot -ResolvedWorkspaceRoot $WorkspaceRoot -ResolvedTaskId $TaskId -ProvidedVersion $ExpectedVersion
            $result = Set-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ExpectedVersion $resolvedVersion -ApprovalPath $Approval -ActorHost $ActorHost -ActorModel $ActorModel
        } elseif ($Command -ceq 'resume-and-execute') {
            if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'resume-and-execute requires -TaskId' }
            $resolvedVersion = Resolve-HarnessEntryExpectedVersion -ResolvedRepoRoot $RepoRoot -ResolvedWorkspaceRoot $WorkspaceRoot -ResolvedTaskId $TaskId -ProvidedVersion $ExpectedVersion
            $result = Resume-HarnessTaskExecution -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ExpectedVersion $resolvedVersion -ActorHost $ActorHost -ActorModel $ActorModel
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
    } elseif ($Command -cin @('enable-v2','reset-auto','disable-v2')) {
        Write-Output ("operation: {0}" -f $result.operation)
        Write-Output ("action: {0}" -f $result.action)
        Write-Output ("new_task_protocol: {0}" -f $result.new_task_protocol)
        Write-Output ("new_work: {0}" -f $result.new_work)
        Write-Output ("path: {0}" -f $result.path)
    } elseif ($Command -ceq 'protocol') {
        Write-Output ("task_id: {0}" -f $(if ($null -eq $result.task_id) { 'none' } else { $result.task_id }))
        Write-Output ("requested_protocol: {0}" -f $result.requested_protocol)
        Write-Output ("detected_protocol: {0}" -f $result.detected_protocol)
        Write-Output ("selected_protocol: {0}" -f $result.selected_protocol)
        Write-Output ("new_task_admission: {0}" -f $result.new_task_admission)
        Write-Output ("preference_source: {0}" -f $result.preference_source)
        Write-Output ("default_source: {0}" -f $result.default_source)
        Write-Output ("reason: {0}" -f $result.reason)
        Write-Output ("workspace_config: {0}" -f $result.workspace_config.new_task_protocol)
        Write-Output ("runtime_default: {0}" -f $result.runtime_default_decision.status)
        if (-not [string]::IsNullOrWhiteSpace([string]$result.warning)) { Write-Output ("warning: {0}" -f $result.warning) }
        Write-Output 'runtime_writes: 0'
    } elseif ($Command -ceq 'status') {
        if ([string]$result.operation -ceq 'recovery-index') {
            Write-Output ("current_task: {0}" -f $(if ($null -eq $result.current) { 'none' } else { $result.current.task_id }))
            Write-Output ("recoverable_tasks: {0}" -f @($result.tasks).Count)
            Write-Output ("terminal_tasks: {0}" -f $result.terminal_task_count)
            Write-Output 'runtime_writes: 0'
        } else {
            Write-Output ("task_id: {0}" -f $result.task.task_id)
            Write-Output ("status: {0}" -f $result.task.status)
            Write-Output ("is_current: {0}" -f ([string]$result.is_current).ToLowerInvariant())
            Write-Output ("pending_transactions: {0}" -f @($result.pending_transactions).Count)
        }
    } elseif ($Command -ceq 'resume') {
        Write-Output ("requirement_state: {0}" -f $result.requirement_state)
        Write-Output ("write_authorized: {0}" -f ([string]$result.write_authorized).ToLowerInvariant())
        Write-Output ("blocking_decision: {0}" -f $result.blocking_decision)
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
    } elseif ($Command -ceq 'approve') {
        Write-Output ("operation: {0}" -f $result.operation)
        Write-Output ("task_id: {0}" -f $result.task.task_id)
        Write-Output ("version: {0}" -f $result.task.version)
        Write-Output ("status: {0}" -f $result.task.status)
        Write-Output ("approval_id: {0}" -f $result.approval_id)
        Write-Output ("approval_path: {0}" -f $result.approval_path)
        Write-Output ("pointer_action: {0}" -f $result.pointer_action)
    } elseif ($Command -ceq 'resume-and-execute') {
        Write-Output ("operation: {0}" -f $result.operation)
        Write-Output ("task_id: {0}" -f $result.task.task_id)
        Write-Output ("version: {0}" -f $result.task.version)
        Write-Output ("status: {0}" -f $result.task.status)
        Write-Output ("write_authorized: {0}" -f ([string]$result.write_authorized).ToLowerInvariant())
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
    $message = [string]$_.Exception.Message
    $conflict = [regex]::Match($message,'^ExpectedVersion mismatch: expected=\d+ actual=(?<actual>\d+)$')
    if ($script:AutoExpectedVersionUsed -and $conflict.Success) {
        $currentVersion = [int]$conflict.Groups['actual'].Value
        if ($AsJson) {
            [Console]::Error.WriteLine(([ordered]@{error='task-version-conflict';current_version=$currentVersion;writes=0} | ConvertTo-Json -Compress))
        } else {
            [Console]::Error.WriteLine("task-version-conflict; current_version=$currentVersion; task changed concurrently, reread and retry")
        }
    } else {
        [Console]::Error.WriteLine($message)
    }
    exit 2
}
