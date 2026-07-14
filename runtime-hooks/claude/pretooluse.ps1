[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'Claude PreToolUse input is empty'
    }
    $payload = $raw | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    if ($payload -isnot [System.Collections.IDictionary]) {
        throw 'Claude PreToolUse input must be a JSON object'
    }
    if (-not $payload.Contains('tool_name')) {
        throw 'Claude PreToolUse input is missing tool_name'
    }
    $toolName = [string]$payload.tool_name
    if ($toolName -cnotin @('Bash','Write','Edit','MultiEdit','NotebookEdit')) {
        [Console]::Out.Write('{}')
        exit 0
    }
    $toolInput = if ($payload.Contains('tool_input') -and $payload.tool_input -is [System.Collections.IDictionary]) { $payload.tool_input } else { @{} }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @('file_path','path','notebook_path')) {
        if ($toolInput.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$toolInput[$key])) {
            $paths.Add([string]$toolInput[$key])
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
    $commandText = if ($toolInput.Contains('command')) { [string]$toolInput.command } else { '' }
    $userInstruction = if ($payload.Contains('user_prompt')) { [string]$payload.user_prompt } else { '' }
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$coreHook,'-SessionMode',$(if($env:HARNESS_SESSION_MODE -ceq 'read-only'){'read-only'}else{'write'}),'-ActionMode','write','-RepoRoot','{REPO_ROOT}','-WorkspaceRoot',$workspaceRoot,'-Environment',[string]$env:HARNESS_ENVIRONMENT,'-CommandText',$commandText,'-UserInstruction',$userInstruction,'-AsJson')) {
        $arguments.Add([string]$argument)
    }
    if ($paths.Count -gt 0) {
        $arguments.Add('-ChangedPaths')
        foreach ($path in $paths) { $arguments.Add($path) }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:HARNESS_TASK_ID)) { $arguments.Add('-TaskId');$arguments.Add([string]$env:HARNESS_TASK_ID) }
    $expectedVersion = 0
    if ([int]::TryParse([string]$env:HARNESS_EXPECTED_VERSION,[ref]$expectedVersion)) { $arguments.Add('-ExpectedVersion');$arguments.Add([string]$expectedVersion) }
    if ([string]$env:HARNESS_DRY_RUN -ceq '1') { $arguments.Add('-DryRun') }

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = (Get-Process -Id $PID).Path
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true
    foreach ($argument in $arguments) { $processInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(12000)) {
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
