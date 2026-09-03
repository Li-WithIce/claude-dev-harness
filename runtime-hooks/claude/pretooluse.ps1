[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Claude PreToolUse input is empty' }
    $payload = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($payload -isnot [Collections.IDictionary]) { throw 'Claude PreToolUse input must be a JSON object' }
    if (-not $payload.Contains('tool_name')) { throw 'Claude PreToolUse input is missing tool_name' }
    $permissionMode = if ($payload.Contains('permission_mode')) { [string]$payload.permission_mode } else { '' }
    if ($payload.Contains('permission_mode') -and $payload.permission_mode -isnot [string])
    { throw 'Codex PreToolUse input contains a non-string permission_mode' }
    if ($permissionMode -and $permissionMode -cnotin @('default','bypassPermissions'))
    { throw "Codex PreToolUse input contains an unsupported permission_mode: $permissionMode" }

    $toolName = [string]$payload.tool_name
    if ($toolName -cnotin @('Bash','apply_patch','Write','Edit','MultiEdit','NotebookEdit')) {
        [Console]::Out.Write('{}')
        exit 0
    }
    if (-not $payload.Contains('tool_input') -or $payload.tool_input -isnot [Collections.IDictionary])
    { throw "$toolName PreToolUse input is missing tool_input" }

    $toolInput = $payload.tool_input
    $changedPaths = @()
    if ($toolName -cin @('Bash','apply_patch')) {
        if (-not $toolInput.Contains('command') -or $toolInput.command -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$toolInput.command)) { throw "$toolName PreToolUse input is missing command" }
        $actionKind = if ($toolName -ceq 'Bash') { 'shell' } else { 'apply_patch' }
    } else {
        $actionKind = 'file_mutation'
        foreach ($key in @('file_path','path','notebook_path')) {
            if (-not $toolInput.Contains($key)) { continue }
            if ($toolInput[$key] -isnot [string]) { throw "$toolName PreToolUse target path must be a string" }
            if (-not [string]::IsNullOrWhiteSpace([string]$toolInput[$key])) { $changedPaths += [string]$toolInput[$key] }
        }
        if ($changedPaths.Count -eq 0) { throw "$toolName PreToolUse input is missing target path" }
    }

    if ($payload.Contains('cwd') -and $payload.cwd -isnot [string]) { throw 'Codex PreToolUse input contains a non-string cwd' }
    $payloadRoot = if ($payload.Contains('cwd')) { [string]$payload.cwd } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($env:HARNESS_SESSION_MODE) -and
        $env:HARNESS_SESSION_MODE -cnotin @('read-only','write')) {
        throw "HARNESS_SESSION_MODE must be read-only or write: $env:HARNESS_SESSION_MODE"
    }
    $expectedVersion = 0
    $expectedVersionValue = if ([int]::TryParse([string]$env:HARNESS_EXPECTED_VERSION,[ref]$expectedVersion)) { $expectedVersion } else { $null }
    $module = '{REPO_ROOT}\scripts\lib\Harness.AdapterAction.psm1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) { throw 'core safety hook module is unavailable' }
    Import-Module $module -Force -ErrorAction Stop
    [void](Invoke-HarnessAdapterPreflightAction -RepoRoot '{REPO_ROOT}' `
        -WorkspaceRoot $payloadRoot -WorkspaceRootFallback ([Environment]::GetEnvironmentVariable('DEV_HARNESS_WORKSPACE_ROOT','Process')) `
        -PermissionMode $permissionMode -SessionMode $(if ($env:HARNESS_SESSION_MODE -ceq 'read-only') { 'read-only' } else { 'write' }) `
        -ActionMode write -ActionKind $actionKind `
        -ShellText $(if($toolName-ceq'Bash'){[string]$toolInput.command}else{''}) `
        -PatchText $(if($toolName-ceq'apply_patch'){[string]$toolInput.command}else{''}) `
        -ChangedPaths $changedPaths -TaskId ([string]$env:HARNESS_TASK_ID) `
        -ExpectedVersion $expectedVersionValue -Environment ([string]$env:HARNESS_ENVIRONMENT) `
        -DryRun:([string]$env:HARNESS_DRY_RUN -ceq '1') `
        -UserInstruction $(if ($payload.Contains('user_prompt')) { [string]$payload.user_prompt } else { '' }))
    [Console]::Out.Write('{}')
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
