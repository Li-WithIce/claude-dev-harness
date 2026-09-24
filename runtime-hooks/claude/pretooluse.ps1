[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stage = 'input'
$actionKind = 'unknown'

try {
    # The launcher writes UTF-8; a redirected child can otherwise default to CP936.
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Claude PreToolUse input is empty' }
    $payload = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($payload -isnot [Collections.IDictionary]) { throw 'Claude PreToolUse input must be a JSON object' }
    if (-not $payload.Contains('tool_name')) { throw 'Claude PreToolUse input is missing tool_name' }
    if ($payload.tool_name -isnot [string]) { throw 'Codex PreToolUse input contains a non-string tool_name' }
    $stage = 'tool'
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
    $actionKind = if ($toolName -ceq 'Bash') { 'shell' } elseif ($toolName -ceq 'apply_patch') { 'apply_patch' } else { 'file_mutation' }
    if ($toolName -cin @('Bash','apply_patch')) {
        if (-not $toolInput.Contains('command') -or $toolInput.command -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$toolInput.command)) { throw "$toolName PreToolUse input is missing command" }
    } else {
        foreach ($key in @('file_path','path','notebook_path')) {
            if (-not $toolInput.Contains($key)) { continue }
            if ($toolInput[$key] -isnot [string]) { throw "$toolName PreToolUse target path must be a string" }
            if (-not [string]::IsNullOrWhiteSpace([string]$toolInput[$key])) { $changedPaths += [string]$toolInput[$key] }
        }
        if ($changedPaths.Count -eq 0) { throw "$toolName PreToolUse input is missing target path" }
    }

    $stage = 'workspace'
    if ($payload.Contains('cwd') -and $payload.cwd -isnot [string]) { throw 'Codex PreToolUse input contains a non-string cwd' }
    if (-not [string]::IsNullOrWhiteSpace($env:HARNESS_SESSION_MODE) -and $env:HARNESS_SESSION_MODE -cnotin @('read-only','write')) {
        throw "HARNESS_SESSION_MODE must be read-only or write: $env:HARNESS_SESSION_MODE"
    }
    $expectedVersion = 0
    $stage = 'module'
    $module = '{REPO_ROOT}\scripts\lib\Harness.AdapterAction.psm1'
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) { throw 'core safety hook module is unavailable' }
    Import-Module $module -Force -ErrorAction Stop
    $stage = 'preflight'
    [void](Invoke-HarnessAdapterPreflightAction -RepoRoot '{REPO_ROOT}' `
        -WorkspaceRoot $(if ($payload.Contains('cwd')) { [string]$payload.cwd } else { '' }) -WorkspaceRootFallback ([Environment]::GetEnvironmentVariable('DEV_HARNESS_WORKSPACE_ROOT','Process')) `
        -PermissionMode $permissionMode -SessionMode $(if ($env:HARNESS_SESSION_MODE -ceq 'read-only') { 'read-only' } else { 'write' }) `
        -ActionMode write -ActionKind $actionKind `
        -ShellText $(if($toolName-ceq'Bash'){[string]$toolInput.command}else{''}) `
        -PatchText $(if($toolName-ceq'apply_patch'){[string]$toolInput.command}else{''}) `
        -ChangedPaths $changedPaths -TaskId ([string]$env:HARNESS_TASK_ID) `
        -ExpectedVersion $(if ([int]::TryParse([string]$env:HARNESS_EXPECTED_VERSION,[ref]$expectedVersion)) { $expectedVersion } else { $null }) -Environment ([string]$env:HARNESS_ENVIRONMENT) `
        -DryRun:([string]$env:HARNESS_DRY_RUN -ceq '1') `
        -UserInstruction $(if ($payload.Contains('user_prompt')) { [string]$payload.user_prompt } else { '' }))
    [Console]::Out.Write('{}')
    exit 0
} catch {
    # Only fixed categories cross the host boundary; never forward raw exception text.
    $preflightStage = [string]$_.Exception.Data['harness_preflight_stage']
    if ($preflightStage -cin @('workspace','action-input','target','policy')) { $stage = $preflightStage }
    $message=[string]$_.Exception.Message
    $code=switch -Regex ($message) {
        '^Codex PreToolUse input contains (?:a non-string|an unsupported) permission_mode' {
            'permission-mode'
            break
        }
        ('^(?:Codex PreToolUse (?:cwd conflicts with DEV_HARNESS_WORKSPACE_ROOT|input is missing cwd and DEV_HARNESS_WORKSPACE_ROOT|input contains a non-string cwd)|'+
            'direct patch requires a bound host cwd|WorkspaceRoot is not a directory:|WorkspaceRoot must not be a reparse point)') {
            'workspace-binding'
            break
        }
        '^direct (?:\w+ input (?:contains an invalid target path|requires a relative target path)|patch target must be relative or a fully qualified Windows drive path)' {
            'patch-path'
            break
        }
        '^direct \w+ input (?:has an invalid patch envelope|contains (?:an invalid|an empty|content after|an unsupported)|is missing a file operation)' {
            'patch-syntax'
            break
        }
        '^(?:file mutation target (?:escapes WorkspaceRoot|crosses a reparse point:|has no existing contained parent|parent is not a directory|must not be a directory)|relative path target escapes WorkspaceRoot)' {
            'path-boundary'
            break
        }
        '^Bash shell-form \w+ is denied because' {
            'shell-form'
            break
        }
        '^read-only session cannot invoke a write tool$' {
            'read-only'
            break
        }
        '^protected (?:write requires|write task profile is insufficient|task version is stale)' {
            'policy-requirement'
            break
        }
        '^(?:protected action policy is (?:unavailable|invalid)|protected action overlay)' {
            'policy-unavailable'
            break
        }
        '^core safety hook module is unavailable$' {
            'startup'
            break
        }
        '^(?:Claude PreToolUse input|Codex PreToolUse input contains a non-string|HARNESS_SESSION_MODE must be|\w+ PreToolUse (?:input is missing|target path must be))' {
            'input'
            break
        }
        default { 'unknown' }
    }
    [Console]::Error.WriteLine("HARNESS_DENY:$code;stage=$stage;action=$actionKind")
    exit 2
}
