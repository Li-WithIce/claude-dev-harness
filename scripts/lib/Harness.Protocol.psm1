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
    $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Label 'workspace protocol config' -AllowMissing
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{
            status = 'missing'
            path = $script:ProtocolConfigRelativePath
            document = [ordered]@{schema_version='harness-protocol-config/v1';new_task_protocol='auto'}
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
        if ($propertyNames.Count -ne 2 -or
            @($propertyNames | Select-Object -Unique).Count -ne 2 -or
            $propertyNames -cnotcontains 'schema_version' -or
            $propertyNames -cnotcontains 'new_task_protocol') {
            throw 'workspace protocol config keys are invalid'
        }
        $document = $text | ConvertFrom-HarnessJson -ErrorAction Stop
    } catch {
        throw "workspace protocol config is not strict UTF-8 JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $jsonDocument) { $jsonDocument.Dispose() }
    }

    $schemaPath = Join-Path $RepoRoot 'schemas/protocol-config.schema.json'
    try {
        $valid = Test-Json -Json ($document | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        throw "workspace protocol config schema validation failed: $($_.Exception.Message)"
    }
    if (-not $valid) { throw 'workspace protocol config failed schema validation' }
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
        [Parameter(Mandatory)][ValidateSet('auto','v1','v2')][string]$NewTaskProtocol
    )

    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    [void](Resolve-Path -LiteralPath (Join-Path $RepoRoot 'schemas/protocol-config.schema.json') -ErrorAction Stop)
    [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Label 'workspace protocol config' -AllowMissing)
    $document = [ordered]@{schema_version='harness-protocol-config/v1';new_task_protocol=$NewTaskProtocol}
    $content = ($document | ConvertTo-Json -Depth 10) + "`n"
    $digest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $script:ProtocolConfigRelativePath -Content $content
    return [ordered]@{
        operation = 'protocol-config'
        action = $(switch ($NewTaskProtocol) {'v2' {'enable-v2'} 'v1' {'disable-v2'} default {'reset-auto'}})
        path = $script:ProtocolConfigRelativePath
        new_task_protocol = $NewTaskProtocol
        digest = $digest
        side_effects = [ordered]@{config_writes=1;runtime_writes=0;artifact_writes=0}
    }
}

function Get-HarnessV1Frontmatter {
    param([Parameter(Mandatory)][string]$Content)

    $match = [regex]::Match($Content,'\A---\r?\n(?<body>.*?)\r?\n---\r?\n',[System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw 'v1 plan is missing frontmatter' }
    $fields = [ordered]@{}
    foreach ($line in ($match.Groups['body'].Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -cnotmatch '^([a-z_]+):\s*(.+)$') { throw "v1 plan has an invalid frontmatter line: $line" }
        $key = [string]$Matches[1]
        if ($fields.Contains($key)) { throw "v1 plan has a duplicate frontmatter field: $key" }
        $fields[$key] = $Matches[2].Trim()
    }
    return $fields
}

function Assert-HarnessV1Frontmatter {
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Fields,
        [Parameter(Mandatory)][string]$TaskId
    )

    $required = @('task_id','stage','tool','updated')
    $optional = @('tool_profile','model')
    $actual = @($Fields.Keys | ForEach-Object { [string]$_ })
    $unknown = @($actual | Where-Object { $_ -cnotin @($required + $optional) })
    $requiredInOrder = @($actual | Where-Object { $_ -cin $required })
    if ($unknown.Count -gt 0 -or ($requiredInOrder -join '|') -cne ($required -join '|')) {
        throw 'v1 plan frontmatter field set or order is invalid'
    }
    $toolIndex = [array]::IndexOf($actual,'tool')
    $updatedIndex = [array]::IndexOf($actual,'updated')
    foreach ($name in $optional) {
        $index = [array]::IndexOf($actual,$name)
        if ($index -ge 0 -and ($index -le $toolIndex -or $index -ge $updatedIndex)) {
            throw "v1 plan optional frontmatter field is out of order: $name"
        }
    }
    if ([string]$Fields['task_id'] -cne $TaskId) { throw 'v1 plan task_id does not match TaskId' }
    $stage = [string]$Fields['stage']
    if ($stage -cnotin @('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')) { throw 'v1 plan stage is invalid' }
    if ($stage -ceq 'DONE') {
        if ([string]$Fields['tool'] -cne 'none') { throw 'v1 DONE plan requires tool: none' }
    } elseif ([string]$Fields['tool'] -cnotin @('claudecode','codex')) {
        throw 'v1 plan tool is invalid'
    }
    if ([string]$Fields['updated'] -cnotmatch '^\d{4}-\d{2}-\d{2}$') { throw 'v1 plan updated date is invalid' }
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
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '..\..' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Assert-HarnessTaskId -TaskId $TaskId }

    $detected = 'new'
    $stage = $null
    $planPath = $null
    $planDigest = $null
    $taskStatePath = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $taskStatePath = ".assistant/runtime/tasks/$TaskId/task.json"
        $taskStateTarget = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $taskStatePath -Label 'v2 task state' -AllowMissing
        if (Test-Path -LiteralPath $taskStateTarget) {
            Assert-HarnessV2TaskArtifact -RepoRoot $RepoRoot -Path $taskStateTarget -TaskId $TaskId
            $detected = 'v2'
        } else {
            $planPath = "docs/tasks/$TaskId/plan.md"
            $planTarget = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $planPath -Label 'v1 plan' -AllowMissing
            if (Test-Path -LiteralPath $planTarget) {
                if (-not (Test-Path -LiteralPath $planTarget -PathType Leaf)) { throw 'v1 plan path is not a file' }
                try {
                    $content = [IO.File]::ReadAllText($planTarget,[Text.UTF8Encoding]::new($false,$true))
                    $fields = Get-HarnessV1Frontmatter -Content $content
                    Assert-HarnessV1Frontmatter -Fields $fields -TaskId $TaskId
                } catch {
                    throw "v1 plan exists but is not a legal v1 artifact: $($_.Exception.Message)"
                }
                $detected = 'v1'
                $stage = [string]$fields['stage']
                $planDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $planPath
            }
        }
    }

    $workspaceConfig = [ordered]@{status='not-read';path=$script:ProtocolConfigRelativePath;new_task_protocol=$null;digest=$null}
    $requested = $detected
    $preferenceSource = 'existing-artifact'
    if ($detected -ceq 'new') {
        $requested = $RequestedProtocol
        $preferenceSource = 'maintenance-override'
        if ([string]::IsNullOrWhiteSpace($requested)) {
            $requested = [Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[EnvironmentVariableTarget]::Process)
            $preferenceSource = 'HARNESS_PROTOCOL'
        }
        if ([string]::IsNullOrWhiteSpace($requested)) {
            $config = Get-HarnessWorkspaceProtocolConfig -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
            $workspaceConfig = [ordered]@{
                status = [string]$config.status
                path = [string]$config.path
                new_task_protocol = [string]$config.document.new_task_protocol
                digest = $config.digest
            }
            $requested = [string]$config.document.new_task_protocol
            $preferenceSource = if ([string]$config.status -ceq 'present') { 'workspace-config' } else { 'default-auto' }
        }
        if ($requested -cnotin @('auto','v1','v2')) { throw 'HARNESS_PROTOCOL must be auto, v1, or v2' }
    }

    $runtimeDefault = [ordered]@{
        status = 'not-read'
        usable = $false
        reason = 'artifact-or-explicit-selection'
        path = '.assistant/runtime/protocol-default.json'
        decision_digest = $null
        new_task_protocol = $null
        scope = $null
        missing_capabilities = @()
    }
    if ($detected -ceq 'new' -and $requested -ceq 'auto') {
        $runtimeDefault = Get-HarnessRuntimeDefaultDecision -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
    }

    $selected = if ($detected -cin @('v1','v2')) {
        $detected
    } elseif ($requested -cin @('v1','v2')) {
        $requested
    } elseif ([bool]$runtimeDefault.usable) {
        [string]$runtimeDefault.new_task_protocol
    } else {
        'v1'
    }
    $reason = if ($detected -ceq 'v2') {
        'existing-v2-task-state'
    } elseif ($detected -ceq 'v1') {
        'existing-v1-plan'
    } elseif ($requested -ceq 'v2') {
        $(if ($preferenceSource -ceq 'workspace-config') {'workspace-v2-new-task'} else {'explicit-v2-new-task'})
    } elseif ($requested -ceq 'v1') {
        $(if ($preferenceSource -ceq 'workspace-config') {'workspace-v1-new-task'} else {'explicit-v1-new-task'})
    } else {
        [string]$runtimeDefault.reason
    }
    $defaultSource = if ($detected -cin @('v1','v2')) {
        'existing-artifact'
    } elseif ($requested -cin @('v1','v2')) {
        $preferenceSource
    } elseif ([string]$runtimeDefault.status -ceq 'valid') {
        'runtime-default-decision'
    } else {
        'v1-fallback'
    }
    $warning = if ($selected -ceq 'v1') { 'v1 protocol is deprecated but remains supported; HARNESS_PROTOCOL=v1 is the rollback switch.' } else { $null }

    return [ordered]@{
        operation = 'protocol'
        task_id = $(if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId })
        requested_protocol = $requested
        detected_protocol = $detected
        selected_protocol = $selected
        preference_source = $preferenceSource
        default_source = $defaultSource
        reason = $reason
        warning = $warning
        workspace_config = $workspaceConfig
        runtime_default_decision = $runtimeDefault
        v1_stage = $stage
        v1_plan_path = $(if ($detected -ceq 'v1') { $planPath } else { $null })
        v1_plan_digest = $planDigest
        v2_task_state_path = $(if ($detected -ceq 'v2') { $taskStatePath } else { $null })
        side_effects = [ordered]@{runtime_writes=0;artifact_writes=0}
    }
}

Export-ModuleMember -Function Get-HarnessWorkspaceProtocolConfig,Set-HarnessWorkspaceProtocolConfig,Get-HarnessProtocolResolution
