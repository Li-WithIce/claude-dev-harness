[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TaskId,
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Skill,
    [Parameter(Mandatory)][string]$Tool,
    [string]$ToolProfileId = '',
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [ValidateSet('readonly','writable')][string]$Mode = 'readonly',
    [string]$PayloadJson = '{}'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\Harness.AdapterDelegation.psm1') -Force -ErrorAction Stop

function New-AdapterResult {
    param([bool]$Ok,[string]$Status,[string[]]$ArtifactPaths=@(),[string]$Handoff='',[string[]]$Errors=@())

    return [ordered]@{
        ok=$Ok
        status=$Status
        artifact_paths=@($ArtifactPaths)
        next_stage_hint=''
        handoff=$Handoff
        errors=@($Errors)
    }
}

function Write-Diagnostic {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message)) { [Console]::Error.WriteLine($Message) }
}

function Invoke-AdapterBackend {
    param([Parameter(Mandatory)][Collections.IDictionary]$Prepared)

    $supervisor = Join-Path $PSScriptRoot 'invoke-harness-skill-supervisor.ps1'
    $dispatcher = Join-Path $PSScriptRoot 'invoke-harness-skill-dispatcher.ps1'
    foreach ($path in @($Prepared.backend_script,$supervisor,$dispatcher)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing adapter target script: $path" }
    }
    $parameters = [ordered]@{
        Task=[string]$Prepared.backend_task
        Workspace=[string]$Prepared.backend_workspace
        File=[string[]]@($Prepared.backend_files)
        Session=[string]$Prepared.backend_session
        Model=[string]$Prepared.backend_model
        Reasoning=[string]$Prepared.backend_reasoning
        TimeoutSeconds=[int]$Prepared.backend_timeout_seconds
        ReadOnly=[bool]$Prepared.backend_read_only
        Output=[string]$Prepared.backend_output_path
    }
    $records = [Collections.Generic.List[object]]::new()
    foreach ($entry in $parameters.GetEnumerator()) {
        $value = $entry.Value
        if ($value -is [bool]) {
            if ($value) { $records.Add([ordered]@{name=[string]$entry.Key;kind='switch';value=$true}) }
        } elseif ($value -is [string[]]) {
            if ($value.Count) { $records.Add([ordered]@{name=[string]$entry.Key;kind='string-array';value=$value}) }
        } elseif ($value -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($value)) { $records.Add([ordered]@{name=[string]$entry.Key;kind='string';value=$value}) }
        } elseif ($value -is [int]) {
            $records.Add([ordered]@{name=[string]$entry.Key;kind='int32';value=$value})
        } else {
            throw "Adapter target parameter '$($entry.Key)' has an unsupported type."
        }
    }
    $requestPath = Join-Path ([IO.Path]::GetTempPath()) ('invoke-harness-skill-request-' + [guid]::NewGuid().ToString('N') + '.json')
    $request = [ordered]@{schema_version='invoke-harness-skill-dispatch/v1';parameters=$records.ToArray()}
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($request | ConvertTo-Json -Depth 6 -Compress))
        $stream = [IO.FileStream]::new($requestPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
        $powerShell = (@(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0]).Source
        $output = @(& $powerShell -NoProfile -NonInteractive -File $supervisor `
            -TargetScriptPath ([string]$Prepared.backend_script) -RequestPath $requestPath `
            -OutputPath ([string]$Prepared.backend_output_path) -TimeoutSeconds 1815 2>&1 |
            ForEach-Object { [string]$_ })
        return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output}
    } finally {
        try {
            [IO.File]::Delete($requestPath)
            if (Test-Path -LiteralPath $requestPath) { throw 'dispatch request still exists after delete' }
        } catch {
            throw "Adapter dispatch request cleanup failed: $($_.Exception.Message)"
        }
    }
}

$result = $null
$exitCode = 0
try {
    $prepareRequest = [ordered]@{
        schema_version='adapter-kernel-api/v1'
        message_type='request'
        body=[ordered]@{
            operation='prepare_delegation'
            repo_root=$repoRoot
            workspace_root=$WorkspaceRoot
            task_id=$TaskId
            stage=$Stage
            skill=$Skill
            tool=$Tool
            tool_profile_id=$ToolProfileId
            mode=$Mode
            payload_json=$PayloadJson
        }
    }
    $prepared = (Invoke-HarnessAdapterPrepareDelegation -Request $prepareRequest).body
    foreach ($warning in @($prepared.warnings)) { Write-Diagnostic $warning }
    $invocation = Invoke-AdapterBackend -Prepared $prepared
    $frames = [Collections.Generic.List[string]]::new()
    $diagnostics = [Collections.Generic.List[string]]::new()
    $sessionId = ''
    $framePrefix = '__DEV_HARNESS_BACKEND_OUTPUT_BASE64__='
    foreach ($line in @($invocation.Output)) {
        if ($line.StartsWith($framePrefix,[StringComparison]::Ordinal)) {
            $frames.Add($line.Substring($framePrefix.Length))
        } elseif ($line -match '^session_id=(.+)$') {
            $sessionId = $Matches[1]
        } elseif ($line -notmatch '^output_path=' -and -not [string]::IsNullOrWhiteSpace($line)) {
            $diagnostics.Add($line)
        }
    }
    if ($invocation.ExitCode -ne 0) { $diagnostics.Add("codex adapter exited with code $($invocation.ExitCode)") }
    foreach ($line in $diagnostics) { Write-Diagnostic $line }
    if ($invocation.ExitCode -eq 0 -and $frames.Count -ne 1) {
        throw "codex adapter expected exactly one backend output frame, got $($frames.Count)"
    }
    $commitRequest = [ordered]@{
        schema_version='adapter-kernel-api/v1'
        message_type='request'
        body=[ordered]@{
            operation='commit_delegation'
            delegation_id=[string]$prepared.delegation_id
            succeeded=$invocation.ExitCode -eq 0
            artifact_base64=$(if($frames.Count){$frames[0]}else{''})
            session_id=$sessionId
            diagnostics=$diagnostics.ToArray()
        }
    }
    $committed = (Invoke-HarnessAdapterCommitDelegation -Request $commitRequest).body
    foreach ($warning in @($committed.warnings)) { Write-Diagnostic $warning }
    $result = $committed.result
    if (-not [bool]$result.ok) { $exitCode = 1 }
} catch {
    Write-Diagnostic $_.Exception.Message
    $status = if ($_.Exception.Data.Contains('adapter_status')) { [string]$_.Exception.Data['adapter_status'] } else { 'error' }
    $result = New-AdapterResult -Ok $false -Status $status -Errors @($_.Exception.Message)
    $exitCode = 1
}
if ($null -eq $result) {
    $result = New-AdapterResult -Ok $false -Status error -Errors @('adapter produced no result')
    $exitCode = 1
}
[Console]::Out.WriteLine(($result | ConvertTo-Json -Compress -Depth 8))
exit $exitCode
