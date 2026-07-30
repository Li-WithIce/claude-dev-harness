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

function Assert-ApplyPatchRelativePath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path) -or $Path -cne $Path.Trim() -or
        $Path.IndexOfAny([char[]]@(0,10,13)) -ge 0) {
        throw 'direct apply_patch input contains an invalid target path'
    }
    if ($Path.StartsWith('/',[System.StringComparison]::Ordinal) -or
        $Path.StartsWith('\\',[System.StringComparison]::Ordinal) -or
        $Path -cmatch '^[A-Za-z]:' -or $Path.Contains(':')) {
        throw 'direct apply_patch input requires a relative target path'
    }
    foreach ($segment in [regex]::Split($Path,'[\\/]')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.' -or $segment -ceq '..' -or
            $segment.IndexOfAny([char[]](0..31 + @(60,62,34,124,63,42))) -ge 0 -or
            $segment.EndsWith('.', [System.StringComparison]::Ordinal) -or
            $segment.EndsWith(' ', [System.StringComparison]::Ordinal)) {
            throw 'direct apply_patch input contains an invalid target path'
        }
    }
}

function Get-ApplyPatchChangedPaths {
    param([Parameter(Mandatory = $true)][string]$PatchText)

    $normalized = $PatchText.Replace("`r`n","`n")
    if ($normalized.Contains("`r")) {
        throw 'direct apply_patch input has an invalid patch envelope'
    }
    if ($normalized.EndsWith("`n",[System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(0,$normalized.Length - 1)
    }
    $lines = $normalized.Split([char]10)
    if ($lines.Count -lt 2 -or $lines[0] -cne '*** Begin Patch' -or
        $lines[$lines.Count - 1] -cne '*** End Patch') {
        throw 'direct apply_patch input has an invalid patch envelope'
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    $pathKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $currentOperation = ''
    $moveSeen = $false
    $fileOperationCount = 0
    for ($index = 1; $index -lt $lines.Count - 1; $index++) {
        $line = [string]$lines[$index]
        if (-not $line.StartsWith('*** ',[System.StringComparison]::Ordinal)) {
            continue
        }
        if ($line -ceq '*** Begin Patch' -or $line -ceq '*** End Patch') {
            throw 'direct apply_patch input has an invalid patch envelope'
        }
        $match = [regex]::Match($line,'^\*\*\* (?<operation>Add File|Update File|Delete File|Move to): (?<path>.*)$')
        if (-not $match.Success) {
            throw 'direct apply_patch input contains an unsupported patch directive'
        }
        $operation = [string]$match.Groups['operation'].Value
        $path = [string]$match.Groups['path'].Value
        Assert-ApplyPatchRelativePath -Path $path
        if ($operation -ceq 'Move to') {
            if ($currentOperation -cne 'Update File' -or $moveSeen) {
                throw 'direct apply_patch input contains an invalid Move to directive'
            }
            $moveSeen = $true
        } else {
            $currentOperation = $operation
            $moveSeen = $false
            $fileOperationCount++
        }
        $pathKey = $path.Replace('/','\')
        if ($pathKeys.Add($pathKey)) {
            $paths.Add($path)
        }
    }
    if ($fileOperationCount -eq 0) {
        throw 'direct apply_patch input is missing a file operation'
    }
    return $paths.ToArray()
}

function Resolve-CodexWorkspaceRoot {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][string]$Source)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw 'not a directory'
        }
        $resolved = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath)
        $root = [System.IO.Path]::GetPathRoot($resolved)
        if (-not $resolved.Equals($root,[System.StringComparison]::OrdinalIgnoreCase)) {
            $resolved = $resolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
        }
        return $resolved
    } catch {
        throw "Codex PreToolUse $Source must identify an existing Workspace directory"
    }
}

function Get-CheckedFileMutationPaths {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )

    $result = [System.Collections.Generic.List[string]]::new()
    $identities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw 'file mutation input is missing target path'
        }
        try {
            $fullPath = if ([System.IO.Path]::IsPathFullyQualified($path)) {
                [System.IO.Path]::GetFullPath($path)
            } else {
                [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $path))
            }
        } catch {
            throw 'file mutation input contains an invalid target path'
        }
        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            throw 'file mutation target must not be a directory'
        }
        if ($identities.Add($fullPath)) {
            $result.Add($path)
        }
    }
    return $result.ToArray()
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
        foreach ($path in @(Get-ApplyPatchChangedPaths -PatchText $toolCommand)) {
            $paths.Add([string]$path)
        }
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
    if ($payload.Contains('cwd') -and $payload.cwd -isnot [string]) {
        throw 'Codex PreToolUse input contains a non-string cwd'
    }
    $payloadRootText = if ($payload.Contains('cwd')) { [string]$payload.cwd } else { '' }
    $environmentRootText = [Environment]::GetEnvironmentVariable('DEV_HARNESS_WORKSPACE_ROOT','Process')
    $payloadRoot = if ([string]::IsNullOrWhiteSpace($payloadRootText)) { '' } else { Resolve-CodexWorkspaceRoot -Path $payloadRootText -Source 'cwd' }
    $environmentRoot = if ([string]::IsNullOrWhiteSpace($environmentRootText)) { '' } else { Resolve-CodexWorkspaceRoot -Path $environmentRootText -Source 'DEV_HARNESS_WORKSPACE_ROOT' }
    if (-not [string]::IsNullOrWhiteSpace($payloadRoot) -and
        -not [string]::IsNullOrWhiteSpace($environmentRoot) -and
        -not $payloadRoot.Equals($environmentRoot,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Codex PreToolUse cwd conflicts with DEV_HARNESS_WORKSPACE_ROOT'
    }
    $workspaceRoot = if (-not [string]::IsNullOrWhiteSpace($payloadRoot)) { $payloadRoot } else { $environmentRoot }
    if ([string]::IsNullOrWhiteSpace($workspaceRoot)) {
        throw 'Codex PreToolUse input is missing cwd and DEV_HARNESS_WORKSPACE_ROOT'
    }
    if ($paths.Count -gt 0) {
        $checkedPaths = @(Get-CheckedFileMutationPaths -WorkspaceRoot $workspaceRoot -Paths $paths.ToArray())
        $paths.Clear()
        foreach ($path in $checkedPaths) { $paths.Add([string]$path) }
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
