[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-ShellApplyPatchInvocation {
    param([Parameter(Mandatory = $true)][string]$CommandText)

    # The hook does not receive the effective shell workdir/environment. Treat any
    # standalone apply_patch spelling in Bash as an invocation candidate instead of
    # attempting to emulate shell aliases, wrappers, quoting, pipes, or redirection.
    return [regex]::IsMatch($CommandText,'(?i)(?<![A-Za-z0-9_])(?:apply_patch|applypatch)(?![A-Za-z0-9_])')
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'Claude PreToolUse input is empty'
    }
    $payload = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($payload -isnot [System.Collections.IDictionary]) {
        throw 'Claude PreToolUse input must be a JSON object'
    }
    if (-not $payload.Contains('tool_name')) {
        throw 'Claude PreToolUse input is missing tool_name'
    }
    if ($payload.Contains('permission_mode') -and $payload.permission_mode -isnot [string]) {
        throw 'Codex PreToolUse input contains a non-string permission_mode'
    }
    $permissionMode = if ($payload.Contains('permission_mode')) { [string]$payload.permission_mode } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($permissionMode) -and
        $permissionMode -cnotin @('default','bypassPermissions')) {
        throw "Codex PreToolUse input contains an unsupported permission_mode: $permissionMode"
    }
    $toolName = [string]$payload.tool_name
    if ($toolName -cnotin @('Bash','apply_patch','Write','Edit','MultiEdit','NotebookEdit')) {
        [Console]::Out.Write('{}')
        exit 0
    }
    if (-not $payload.Contains('tool_input') -or $payload.tool_input -isnot [System.Collections.IDictionary]) {
        throw "$toolName PreToolUse input is missing tool_input"
    }
    $toolInput = $payload.tool_input
    $paths = [System.Collections.Generic.List[string]]::new()
    $commandText = ''
    $toolCommand = ''
    if ($toolName -cin @('Bash','apply_patch')) {
        if (-not $toolInput.Contains('command') -or $toolInput.command -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$toolInput.command)) {
            throw "$toolName PreToolUse input is missing command"
        }
        $toolCommand = [string]$toolInput.command
    }
    if ($toolName -ceq 'Bash') {
        $commandText = $toolCommand
        if (Test-ShellApplyPatchInvocation -CommandText $toolCommand) {
            throw 'Bash shell-form apply_patch is denied because Codex PreToolUse does not expose the effective tool workdir or environment identity'
        }
    } elseif ($toolName -ceq 'apply_patch') {
        throw 'direct apply_patch is denied because Codex PreToolUse does not bind the effective environment identity and cwd'
    } elseif ($toolName -cne 'Bash') {
        foreach ($key in @('file_path','path','notebook_path')) {
            if ($toolInput.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$toolInput[$key])) {
                $paths.Add([string]$toolInput[$key])
            }
        }
        if ($paths.Count -eq 0) {
            throw "$toolName PreToolUse input is missing target path"
        }
    }
    $workspaceRoot = if ($payload.Contains('cwd')) { [string]$payload.cwd } else { '' }
    if ([string]::IsNullOrWhiteSpace($workspaceRoot)) {
        $workspaceRoot = [Environment]::GetEnvironmentVariable('DEV_HARNESS_WORKSPACE_ROOT','Process')
    }
    if ([string]::IsNullOrWhiteSpace($workspaceRoot)) {
        throw 'Claude PreToolUse input is missing cwd'
    }

    $coreHook = '{REPO_ROOT}\runtime-hooks\core\pretooluse.ps1'
    $arguments = [System.Collections.Generic.List[string]]::new()
    $userInstruction = if ($payload.Contains('user_prompt')) { [string]$payload.user_prompt } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($env:HARNESS_SESSION_MODE) -and
        $env:HARNESS_SESSION_MODE -cnotin @('read-only','write')) {
        throw "HARNESS_SESSION_MODE must be read-only or write: $env:HARNESS_SESSION_MODE"
    }
    $sessionMode = if ($env:HARNESS_SESSION_MODE -ceq 'read-only') { 'read-only' } else { 'write' }
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$coreHook,'-RepoRoot','{REPO_ROOT}','-WorkspaceRoot',$workspaceRoot,'-InputJsonFromStdin','-AsJson')) {
        $arguments.Add([string]$argument)
    }
    $expectedVersion = 0
    $expectedVersionValue = if ([int]::TryParse([string]$env:HARNESS_EXPECTED_VERSION,[ref]$expectedVersion)) { $expectedVersion } else { $null }
    $inputEnvelope = [ordered]@{
        session_mode = $sessionMode
        action_mode = 'write'
        task_id = [string]$env:HARNESS_TASK_ID
        expected_version = $expectedVersionValue
        command_text = $commandText
        changed_paths = $paths.ToArray()
        environment = [string]$env:HARNESS_ENVIRONMENT
        dry_run = [string]$env:HARNESS_DRY_RUN -ceq '1'
        user_instruction = $userInstruction
    } | ConvertTo-Json -Depth 5 -Compress

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = (Get-Process -Id $PID).Path
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) { $processInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($inputEnvelope)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(6000)) {
            $process.Kill($true)
            throw 'core safety hook timed out'
        }
        $errorText = $stderr.GetAwaiter().GetResult().Trim()
        [void]$stdout.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw $(if ([string]::IsNullOrWhiteSpace($errorText)) { "core safety hook denied write (exit $($process.ExitCode))" } else { $errorText })
        }
    } finally {
        $process.Dispose()
    }
    [Console]::Out.Write('{}')
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
