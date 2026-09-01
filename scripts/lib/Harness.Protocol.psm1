Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.RuntimeDefault.psm1') -Force -ErrorAction Stop

$script:ProtocolConfigRelativePath = '.assistant/config/protocol.json'

function Get-HarnessWorkspaceProtocolConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    foreach ($parent in @('.assistant','.assistant/config')) {
        [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $parent -Label 'workspace protocol config parent' -MustExist Directory -AllowMissing)
    }
    $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Label 'workspace protocol config' -AllowMissing
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{
            status = 'missing'
            path = $script:ProtocolConfigRelativePath
            document = [ordered]@{schema_version='harness-protocol-config/v2';new_task_protocol='auto';new_work='enabled'}
            digest = $null
        }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'workspace protocol config is not a file' }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt 4096) { throw 'workspace protocol config is too large' }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'workspace protocol config must be UTF-8 without BOM'
    }

    $jsonDocument = $null
    try {
        $text = [System.Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($text)
        if ($jsonDocument.RootElement.ValueKind -cne [System.Text.Json.JsonValueKind]::Object) {
            throw 'workspace protocol config must be a JSON object'
        }
        $propertyNames = @($jsonDocument.RootElement.EnumerateObject() | ForEach-Object { $_.Name })
        if (@($propertyNames | Select-Object -Unique).Count -ne $propertyNames.Count) {
            throw 'workspace protocol config keys are invalid'
        }
        $document = $text | ConvertFrom-HarnessJson -ErrorAction Stop
    } catch {
        throw "workspace protocol config is not strict UTF-8 JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $jsonDocument) { $jsonDocument.Dispose() }
    }

    $schemaName = if ([string]$document.schema_version -ceq 'harness-protocol-config/v2') { 'protocol-config-v2.schema.json' } else { 'protocol-config.schema.json' }
    $schemaPath = Join-Path $RepoRoot "schemas/$schemaName"
    try {
        $valid = Test-Json -Json ($document | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        throw "workspace protocol config schema validation failed: $($_.Exception.Message)"
    }
    if (-not $valid) { throw 'workspace protocol config failed schema validation' }
    if ([string]$document.new_task_protocol -ceq 'v1') { throw 'v1-protocol-retired: explicit migration or v2 recovery is required' }
    return [ordered]@{
        status = 'present'
        path = $script:ProtocolConfigRelativePath
        document = $document
        digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path
    }
}

function Set-HarnessWorkspaceProtocolConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][ValidateSet('auto','v2')][string]$NewTaskProtocol,
        [switch]$PauseNewWork
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    [void](Resolve-Path -LiteralPath (Join-Path $RepoRoot 'schemas/protocol-config-v2.schema.json') -ErrorAction Stop)
    [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Label 'workspace protocol config' -AllowMissing)
    $document = [ordered]@{schema_version='harness-protocol-config/v2';new_task_protocol=$NewTaskProtocol;new_work=$(if($PauseNewWork){'paused'}else{'enabled'})}
    $content = ($document | ConvertTo-Json -Depth 10) + "`n"
    $digest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Content $content
    return [ordered]@{
        operation = 'protocol-config'
        action = $(if($PauseNewWork){'disable-v2'}elseif($NewTaskProtocol -ceq 'v2'){'enable-v2'}else{'reset-auto'})
        path = $script:ProtocolConfigRelativePath
        new_task_protocol = $NewTaskProtocol
        new_work = $document.new_work
        digest = $digest
        side_effects = [ordered]@{config_writes=1;runtime_writes=0;artifact_writes=0}
    }
}

function Assert-HarnessV2TaskArtifact {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TaskId
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'task.json is not a file' }
        $json = [System.IO.File]::ReadAllText($Path,[System.Text.UTF8Encoding]::new($false,$true))
        $document = $json | ConvertFrom-HarnessJson -ErrorAction Stop
        $schemaPath = Join-Path $RepoRoot 'schemas\task-state.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'task-state schema is unavailable' }
        if (-not (Test-Json -Json ($document | ConvertTo-Json -Depth 30 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) { throw 'task.json failed task-state/v2 schema validation' }
        if ([string]$document.task_id -cne $TaskId) { throw 'task.json task_id does not match TaskId' }
    } catch {
        $detail = [string]$_.Exception.Message
        if ($detail.StartsWith('invalid-v2-artifact:',[StringComparison]::Ordinal)) { throw }
        throw "invalid-v2-artifact: $detail"
    }
}

function Get-HarnessProtocolResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [string]$TaskId = '',
        [string]$RequestedProtocol = '',
        [string]$RepoRoot = ''
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '../..' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Assert-HarnessTaskId -TaskId $TaskId }

    $detected = 'new'
    $taskStatePath = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $taskStatePath = ".assistant/runtime/tasks/$TaskId/task.json"
        $target = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $taskStatePath -Label 'v2 task state' -AllowMissing
        if (Test-Path -LiteralPath $target) {
            Assert-HarnessV2TaskArtifact -RepoRoot $RepoRoot -Path $target -TaskId $TaskId
            $detected = 'v2'
        } else {
            # Existence is a collision guard, never permission to read or resume legacy contents.
            $plan = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "docs/tasks/$TaskId/plan.md" -Label 'existing task artifact' -AllowMissing
            if (Test-Path -LiteralPath $plan) { throw 'legacy-task-requires-explicit-migration: ordinary Runtime does not read legacy plans' }
        }
    }

    $workspaceConfig = [ordered]@{status='not-read';path=$script:ProtocolConfigRelativePath;new_task_protocol=$null;new_work=$null;digest=$null}
    $runtimeDefault = [ordered]@{status='not-read';usable=$false;reason='artifact-or-explicit-selection';path='.assistant/runtime/protocol-default.json';decision_digest=$null;new_task_protocol=$null;scope=$null;required_capabilities=@();missing_capabilities=@();host_capabilities=$null}
    $requested = 'v2'
    $selected = 'v2'
    $admission = 'existing'
    $preferenceSource = 'existing-artifact'
    $defaultSource = 'existing-artifact'
    $reason = 'existing-v2-task-state'

    if ($detected -ceq 'new') {
        $requested = $RequestedProtocol
        $preferenceSource = 'maintenance-override'
        if ([string]::IsNullOrWhiteSpace($requested)) {
            $requested = [Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[EnvironmentVariableTarget]::Process)
            $preferenceSource = 'HARNESS_PROTOCOL'
        }
        if (-not [string]::IsNullOrWhiteSpace($requested) -and $requested -cnotin @('auto','v2')) {
            if ($requested -ceq 'v1') { throw 'v1-protocol-retired: explicit migration or v2 recovery is required' }
            throw 'HARNESS_PROTOCOL must be auto or v2'
        }
        # Admission is checked even for explicit v2; environment preference cannot bypass stop-loss.
        $config = Get-HarnessWorkspaceProtocolConfig -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
        $newWork = if ($config.document.Contains('new_work')) { [string]$config.document.new_work } else { 'enabled' }
        $workspaceConfig = [ordered]@{status=[string]$config.status;path=[string]$config.path;new_task_protocol=[string]$config.document.new_task_protocol;new_work=$newWork;digest=$config.digest}
        if ([string]::IsNullOrWhiteSpace($requested)) {
            $requested = [string]$config.document.new_task_protocol
            $preferenceSource = if ($config.status -ceq 'present') { 'workspace-config' } else { 'default-auto' }
        }
        $admission = $newWork
        $defaultSource = $preferenceSource
        $reason = if ($requested -ceq 'v2') { if ($preferenceSource -ceq 'workspace-config') { 'workspace-v2-new-task' } else { 'explicit-v2-new-task' } } else { 'v2-default-new-task' }
        if ($newWork -ceq 'paused') {
            $selected = $null
            $reason = 'new-work-paused'
        } elseif ($requested -ceq 'auto') {
            $runtimeDefault = Get-HarnessRuntimeDefaultDecision -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
            if ($runtimeDefault.status -ceq 'missing') {
                $defaultSource = 'v2-default'
            } elseif ($runtimeDefault.usable -and $runtimeDefault.new_task_protocol -ceq 'v2') {
                $defaultSource = 'runtime-default-decision'
                $reason = [string]$runtimeDefault.reason
            } else {
                $selected = $null
                $admission = 'blocked'
                $reason = [string]$runtimeDefault.reason
            }
        }
    }

    return [ordered]@{
        operation='protocol'
        task_id=$(if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId })
        requested_protocol=$requested
        detected_protocol=$detected
        selected_protocol=$selected
        new_task_admission=$admission
        preference_source=$preferenceSource
        default_source=$defaultSource
        reason=$reason
        warning=$(if ($null -eq $selected) { 'New work is stopped; recover existing v2 tasks or explicitly repair admission.' } else { $null })
        workspace_config=$workspaceConfig
        runtime_default_decision=$runtimeDefault
        v2_task_state_path=$(if ($detected -ceq 'v2') { $taskStatePath } else { $null })
        side_effects=[ordered]@{runtime_writes=0;artifact_writes=0}
    }
}

Export-ModuleMember -Function Get-HarnessWorkspaceProtocolConfig,Set-HarnessWorkspaceProtocolConfig,Get-HarnessProtocolResolution
