. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')
. (Join-Path $PSScriptRoot 'Harness.RuntimeDefaultReader.ps1')

$script:ProtocolConfigRelativePath = '.assistant/config/protocol.json'

function Get-HarnessWorkspaceProtocolConfig {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot)

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Label 'workspace protocol config' -AllowMissing
    $status,$document,$digest = 'missing',[ordered]@{schema_version='harness-protocol-config/v2';new_task_protocol='auto';new_work='enabled'},$null
    if (Test-Path -LiteralPath $path) {
        try {
            $document = Read-HarnessKernelJsonPath -Path $path -Label 'workspace protocol config' -MaximumBytes 4096
        } catch {
            $detail = [string]$_.Exception.Message
            if ($detail -match 'too large$') { throw 'workspace protocol config is too large' }
            if ($detail -match 'without BOM$') { throw 'workspace protocol config must be UTF-8 without BOM' }
            throw "workspace protocol config is not strict UTF-8 JSON: $detail"
        }
        Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $document -Schema $(if ([string]$document.schema_version -ceq 'harness-protocol-config/v2') { 'protocol-config-v2.schema.json' } else { 'protocol-config.schema.json' }) -Label 'workspace protocol config' -Depth 10
        if ([string]$document.new_task_protocol -ceq 'v1') { throw 'v1-protocol-retired: explicit migration or v2 recovery is required' }
        $status = 'present'
        $digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path
    }
    return [ordered]@{status = $status
        path = $script:ProtocolConfigRelativePath
        document = $document
        digest = $digest}
}

function Set-HarnessWorkspaceProtocolConfig {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][ValidateSet('auto','v2')][string]$NewTaskProtocol,[switch]$PauseNewWork)

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    [void](Resolve-Path -LiteralPath (Join-Path $RepoRoot 'schemas/protocol-config-v2.schema.json') -ErrorAction Stop)
    [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Label 'workspace protocol config' -AllowMissing)
    $document = [ordered]@{schema_version='harness-protocol-config/v2';new_task_protocol=$NewTaskProtocol;new_work=$(if($PauseNewWork){'paused'}else{'enabled'})}
    $digest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Content (($document | ConvertTo-Json -Depth 10) + "`n")
    return [ordered]@{operation = 'protocol-config'
        action = $(if($PauseNewWork){'disable-v2'}elseif($NewTaskProtocol -ceq 'v2'){'enable-v2'}else{'reset-auto'})
        path = $script:ProtocolConfigRelativePath
        new_task_protocol = $NewTaskProtocol
        new_work = $document.new_work
        digest = $digest
        side_effects = [ordered]@{config_writes=1;runtime_writes=0;artifact_writes=0}}
}

function Get-HarnessProtocolResolution {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[string]$TaskId = '',
        [string]$RequestedProtocol = '',[string]$RepoRoot = '')

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '../..' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Assert-HarnessTaskId -TaskId $TaskId }

    $resolution = [ordered]@{operation='protocol'
        task_id=$(if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId })
        requested_protocol='v2'
        detected_protocol='new'
        selected_protocol='v2'
        new_task_admission='existing'
        preference_source='existing-artifact'
        default_source='existing-artifact'
        reason='existing-v2-task-state'
        warning=$null
        workspace_config=[ordered]@{status='not-read';path=$script:ProtocolConfigRelativePath;new_task_protocol=$null;new_work=$null;digest=$null}
        runtime_default_decision=[ordered]@{status='not-read';usable=$false;reason='artifact-or-explicit-selection';path='.assistant/runtime/protocol-default.json';decision_digest=$null;new_task_protocol=$null;scope=$null;required_capabilities=@();missing_capabilities=@();host_capabilities=$null}
        v2_task_state_path=$null
        side_effects=[ordered]@{runtime_writes=0;artifact_writes=0}}
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $taskStatePath = ".assistant/runtime/tasks/$TaskId/task.json"
        if (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $taskStatePath -Label 'v2 task state' -AllowMissing)) {
            try {
                if ([string]((Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $taskStatePath -Label 'task.json' -RepoRoot $RepoRoot -Schema task-state.schema.json -Depth 30).Document.task_id) -cne $TaskId) { throw 'task.json task_id does not match TaskId' }
            } catch { throw "invalid-v2-artifact: $($_.Exception.Message)" }
            $resolution.detected_protocol = 'v2'
            $resolution.v2_task_state_path = $taskStatePath
            return $resolution
        }
        # Existence is a collision guard, never permission to read or resume legacy contents.
        if (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "docs/tasks/$TaskId/plan.md" -Label 'existing task artifact' -AllowMissing)) { throw 'legacy-task-requires-explicit-migration: ordinary Runtime does not read legacy plans' }
    }

    $resolution.requested_protocol = if ([string]::IsNullOrWhiteSpace($RequestedProtocol)) { [Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[EnvironmentVariableTarget]::Process) } else { $RequestedProtocol }
    $resolution.preference_source = if ([string]::IsNullOrWhiteSpace($RequestedProtocol)) { 'HARNESS_PROTOCOL' } else { 'maintenance-override' }
    if (-not [string]::IsNullOrWhiteSpace($resolution.requested_protocol) -and $resolution.requested_protocol -cnotin @('auto','v2')) {
        if ($resolution.requested_protocol -ceq 'v1') { throw 'v1-protocol-retired: explicit migration or v2 recovery is required' }
        throw 'HARNESS_PROTOCOL must be auto or v2'
    }
    # Admission is checked even for explicit v2; environment preference cannot bypass stop-loss.
    $config = Get-HarnessWorkspaceProtocolConfig -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
    $newWork = if ($config.document.Contains('new_work')) { [string]$config.document.new_work } else { 'enabled' }
    $resolution.workspace_config = [ordered]@{status=[string]$config.status;path=[string]$config.path;new_task_protocol=[string]$config.document.new_task_protocol;new_work=$newWork;digest=$config.digest}
    if ([string]::IsNullOrWhiteSpace($resolution.requested_protocol)) {
        $resolution.requested_protocol = [string]$config.document.new_task_protocol
        $resolution.preference_source = if ($config.status -ceq 'present') { 'workspace-config' } else { 'default-auto' }
    }
    $resolution.new_task_admission = $newWork
    $resolution.default_source = $resolution.preference_source
    $resolution.reason = if ($resolution.requested_protocol -ceq 'v2') { if ($resolution.preference_source -ceq 'workspace-config') { 'workspace-v2-new-task' } else { 'explicit-v2-new-task' } } else { 'v2-default-new-task' }
    if ($newWork -ceq 'paused') {
        $resolution.selected_protocol = $null
        $resolution.reason = 'new-work-paused'
    } elseif ($resolution.requested_protocol -ceq 'auto') {
        $resolution.runtime_default_decision = Get-HarnessRuntimeDefaultDecision -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
        if ($resolution.runtime_default_decision.status -ceq 'missing') {
            $resolution.default_source = 'v2-default'
        } elseif ($resolution.runtime_default_decision.usable -and $resolution.runtime_default_decision.new_task_protocol -ceq 'v2') {
            $resolution.default_source = 'runtime-default-decision'
        } else {
            $resolution.selected_protocol = $null
            $resolution.new_task_admission = 'blocked'
        }
        if ($resolution.runtime_default_decision.status -cne 'missing') { $resolution.reason = [string]$resolution.runtime_default_decision.reason }
    }
    if ($null -eq $resolution.selected_protocol) { $resolution.warning = 'New work is stopped; recover existing v2 tasks or explicitly repair admission.' }
    return $resolution
}

Export-ModuleMember -Function Get-HarnessWorkspaceProtocolConfig,Set-HarnessWorkspaceProtocolConfig,Get-HarnessProtocolResolution
