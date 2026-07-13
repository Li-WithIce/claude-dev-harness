#!/usr/bin/env pwsh
#requires -Version 7.3
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,

    [Alias('t')]
    [string]$TaskText,

    [Alias('w')]
    [string]$Workspace = (Get-Location).Path,

    [Alias('f')]
    [string[]]$File,

    [string]$Session,

    [string]$Model,

    [ValidateSet('low', 'medium', 'high')]
    [string]$Reasoning = 'medium',

    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$Sandbox,

    [switch]$ReadOnly,

    [switch]$FullAuto,

    [switch]$Ephemeral,

    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 1800,

    [Alias('o')]
    [string]$Output,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage:
  ask_codex.ps1 <task> [options]
  ask_codex.ps1 -Task <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -Task, -t <text>             Alias for positional task

File context (optional, repeatable):
  -File, -f <path>             Priority file path

Multi-turn:
  -Session <id>                Resume a previous session (thread_id from prior run)

Options:
  -Workspace, -w <path>        Workspace directory (default: current directory)
  -Model <name>                Model override
  -Reasoning <level>           Reasoning effort: low, medium, high (default: medium)
  -Sandbox <mode>              read-only, workspace-write, or danger-full-access
  -ReadOnly                    Read-only sandbox, including resume mode
  -FullAuto                    Full-auto mode for a new session
  -Ephemeral                   Do not persist Codex session files
  -TimeoutSeconds <seconds>    Main Codex timeout (default: 1800)
  -Output, -o <path>           Output file; relative paths use the caller's current directory
  -Help                        Show this help

Success requires Codex exit 0 and an agent response. Only then are these printed:
  session_id=<thread_id>       Use with -Session for follow-up calls
  output_path=<absolute-file>  Response markdown path

Windows requires PowerShell 7.3+ (pwsh). Resume sends the prompt through stdin as '-'.
'@
}

function Trim-Whitespace {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Trim()
}

function Resolve-FileRef {
    param(
        [string]$Workspace,
        [string]$RawPath
    )

    $cleaned = Trim-Whitespace $RawPath
    if ([string]::IsNullOrWhiteSpace($cleaned)) { return '' }
    $cleaned = $cleaned -replace '#L\d+$', ''
    $cleaned = $cleaned -replace ':\d+(-\d+)?$', ''
    if (-not [System.IO.Path]::IsPathRooted($cleaned)) {
        $cleaned = Join-Path $Workspace $cleaned
    }
    if (Test-Path -LiteralPath $cleaned) {
        return (Resolve-Path -LiteralPath $cleaned -ErrorAction SilentlyContinue).Path
    }
    return $cleaned
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Write-Utf8NoBomAtomic {
    param(
        [string]$Path,
        [string]$Content
    )

    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Output path has no parent directory: $Path"
    }
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $tempPath = Join-Path $parent ('.{0}.{1}.tmp' -f [System.IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    $stream = $null
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream = [System.IO.FileStream]::new($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [System.IO.File]::Move($tempPath, $Path, $true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($tempPath)) {
            [System.IO.File]::Delete($tempPath)
        }
    }
}

function Convert-CertificateToPem {
    param([byte[]]$RawData)

    $base64 = [System.Convert]::ToBase64String($RawData, [System.Base64FormattingOptions]::InsertLineBreaks)
    return "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----`n"
}

function New-CodexCaBundle {
    $certs = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop)
    if ($certs.Count -eq 0) { throw 'CurrentUser Root certificate store is empty' }
    $content = (($certs | ForEach-Object { Convert-CertificateToPem -RawData $_.RawData }) -join '')
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('dev-harness-codex-ca-' + [guid]::NewGuid().ToString('N') + '.pem')
    $stream = $null
    $writeError = $null
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($content)
        $stream = [System.IO.FileStream]::new($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } catch {
        $writeError = $_
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    if ($null -ne $writeError) {
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        throw $writeError
    }
    return $path
}

function Resolve-CodexLaunch {
    param([string[]]$CodexArguments)

    $command = Get-Command codex -ErrorAction Stop
    $path = [string]$command.Path
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "Unsupported Codex command type: $($command.CommandType)"
    }
    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $hostPath = (Get-Process -Id $PID).Path
        if ((Split-Path -Leaf $hostPath) -notmatch '^pwsh(\.exe)?$') {
            throw 'ask_codex.ps1 requires the pwsh host.'
        }
        $payload = [ordered]@{ script = $path; arguments = @($CodexArguments) } | ConvertTo-Json -Compress
        $payloadBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payload))
        $launcher = @"
`$ErrorActionPreference = 'Stop'
`$PSNativeCommandArgumentPassing = 'Standard'
`$payload = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$payloadBase64')) | ConvertFrom-Json
`$scriptPath = [string]`$payload.script
`$arguments = @(`$payload.arguments | ForEach-Object { [string]`$_ })
& `$scriptPath @arguments
if (`$null -eq `$LASTEXITCODE) { exit 0 }
exit `$LASTEXITCODE
"@
        $encodedLauncher = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($launcher))
        return [pscustomobject]@{
            FilePath = $hostPath
            PrefixArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedLauncher)
            Arguments = @()
        }
    }
    if ($extension -in @('.cmd', '.bat')) {
        throw "Unsafe shell shim is not supported: $path"
    }
    if ($IsWindows -and $extension -ne '.exe') {
        throw "Codex command is not a native executable or PowerShell shim: $path"
    }
    return [pscustomobject]@{ FilePath = $path; PrefixArguments = @(); Arguments = @($CodexArguments) }
}

function Receive-CodexStreamLines {
    param(
        [System.Diagnostics.Process]$Process,
        [hashtable]$State,
        [scriptblock]$OnStdOut
    )

    $madeProgress = $false
    foreach ($name in @('StdOut', 'StdErr')) {
        $closedKey = $name + 'Closed'
        $taskKey = $name + 'Task'
        $linesKey = $name + 'Lines'
        $reader = if ($name -eq 'StdOut') { $Process.StandardOutput } else { $Process.StandardError }
        while (-not $State[$closedKey] -and $null -ne $State[$taskKey] -and $State[$taskKey].IsCompleted) {
            $line = $State[$taskKey].GetAwaiter().GetResult()
            if ($null -eq $line) {
                $State[$closedKey] = $true
                $State[$taskKey] = $null
                break
            }
            $State[$linesKey].Add($line)
            if ($name -eq 'StdOut' -and $null -ne $OnStdOut) { & $OnStdOut $line }
            $State[$taskKey] = $reader.ReadLineAsync()
            $madeProgress = $true
        }
    }
    return $madeProgress
}

function Invoke-CodexProcess {
    param(
        [object]$Launch,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$InputText,
        [int]$TimeoutSeconds,
        [hashtable]$EnvironmentOverrides,
        [scriptblock]$OnStdOut
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Launch.FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @($Launch.PrefixArguments) + @($Arguments)) {
        $psi.ArgumentList.Add([string]$argument)
    }
    foreach ($entry in $EnvironmentOverrides.GetEnumerator()) {
        $psi.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $timedOut = $false
    $exitCode = $null
    $inputTask = $null
    $inputClosed = $false
    $primaryError = $null
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()
    $state = @{
        StdOutTask = $null
        StdErrTask = $null
        StdOutClosed = $false
        StdErrClosed = $false
        StdOutLines = [System.Collections.Generic.List[string]]::new()
        StdErrLines = [System.Collections.Generic.List[string]]::new()
    }

    try {
        [void]$process.Start()
        $started = $true
        $state.StdOutTask = $process.StandardOutput.ReadLineAsync()
        $state.StdErrTask = $process.StandardError.ReadLineAsync()
        $inputTask = $process.StandardInput.WriteAsync($InputText)
        while ($true) {
            $madeProgress = Receive-CodexStreamLines -Process $process -State $state -OnStdOut $OnStdOut
            if (-not $inputClosed -and $inputTask.IsCompleted) {
                $null = $inputTask.GetAwaiter().GetResult()
                $process.StandardInput.Close()
                $inputClosed = $true
                $madeProgress = $true
            }
            if ($process.HasExited) {
                $exitCode = $process.ExitCode
                break
            }
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                break
            }
            if (-not $madeProgress) { Start-Sleep -Milliseconds 10 }
        }
    } catch {
        $primaryError = $_
    } finally {
        if ($started) {
            $cleanupDeadline = $timer.ElapsedMilliseconds + 5000
            try { $process.Kill($true) } catch { $cleanupErrors.Add('kill tree: ' + $_.Exception.Message) }
            try {
                $remaining = [Math]::Max(0, [int]($cleanupDeadline - $timer.ElapsedMilliseconds))
                if (-not $process.WaitForExit($remaining)) { throw 'root process did not exit within cleanup grace' }
            } catch { $cleanupErrors.Add('wait root: ' + $_.Exception.Message) }
            try {
                if (-not $inputClosed) {
                    $remaining = [Math]::Max(0, [int]($cleanupDeadline - $timer.ElapsedMilliseconds))
                    if ($null -ne $inputTask -and -not $inputTask.Wait($remaining)) { throw 'stdin write did not finish within cleanup grace' }
                    if ($null -ne $inputTask) { $null = $inputTask.GetAwaiter().GetResult() }
                    $process.StandardInput.Close()
                    $inputClosed = $true
                }
            } catch { $cleanupErrors.Add('close stdin: ' + $_.Exception.Message) }
            try {
                while (-not $state.StdOutClosed -or -not $state.StdErrClosed) {
                    $madeProgress = Receive-CodexStreamLines -Process $process -State $state -OnStdOut $OnStdOut
                    if ($state.StdOutClosed -and $state.StdErrClosed) { break }
                    if ($timer.ElapsedMilliseconds -ge $cleanupDeadline) { throw 'stdout/stderr did not close within cleanup grace' }
                    if (-not $madeProgress) { Start-Sleep -Milliseconds 10 }
                }
            } catch { $cleanupErrors.Add('drain output: ' + $_.Exception.Message) }
        }
        try { $process.Dispose() } catch { $cleanupErrors.Add('dispose process: ' + $_.Exception.Message) }
    }

    if ($cleanupErrors.Count -gt 0) {
        $primaryMessage = if ($null -ne $primaryError) {
            $primaryError.Exception.Message
        } elseif ($timedOut) {
            "Codex timed out after $TimeoutSeconds seconds."
        } else {
            "Codex exited with code $exitCode but cleanup failed."
        }
        throw [System.InvalidOperationException]::new(($primaryMessage + ' Cleanup failures: ' + ($cleanupErrors -join '; ')), $(if ($null -ne $primaryError) { $primaryError.Exception } else { $null }))
    }
    if ($null -ne $primaryError) { throw $primaryError }

    return [pscustomobject]@{
        ExitCode = $(if ($timedOut) { 124 } else { $exitCode })
        TimedOut = $timedOut
        StdOutLines = $state.StdOutLines.ToArray()
        StdErrLines = $state.StdErrLines.ToArray()
    }
}

function Show-CodexProgressLine {
    param([string]$Line)

    $clean = $Line -replace "`r", '' -replace [char]4, ''
    if (-not $clean.TrimStart().StartsWith('{')) { return }
    try {
        $event = $clean | ConvertFrom-Json -ErrorAction Stop
        $type = [string](Get-PropertyValue -Object $event -Name 'type')
        $item = Get-PropertyValue -Object $event -Name 'item'
        $itemType = [string](Get-PropertyValue -Object $item -Name 'type')
        if ($type -eq 'item.started' -and $itemType -eq 'command_execution') {
            $preview = [string](Get-PropertyValue -Object $item -Name 'command')
            if ($preview.Length -gt 100) { $preview = $preview.Substring(0, 100) }
            if ($preview) { [Console]::Error.WriteLine("[codex] > $preview") }
        } elseif ($type -eq 'item.completed' -and $itemType -eq 'agent_message') {
            $preview = [string](Get-PropertyValue -Object $item -Name 'text')
            if ($preview) {
                $preview = $preview.Split("`n")[0]
                if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                [Console]::Error.WriteLine("[codex] $preview")
            }
        }
    } catch {}
}

if ($Help) {
    Show-Usage
    return
}
if ([string]::IsNullOrEmpty($Task) -and -not [string]::IsNullOrEmpty($TaskText)) {
    $Task = $TaskText
}
$Task = Trim-Whitespace $Task
if ([string]::IsNullOrEmpty($Task)) { throw 'Request text is empty. Pass a positional arg or -Task.' }
if ($Session -match '\p{Cc}') { throw 'Session contains a control character and cannot be emitted safely.' }
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw "Workspace does not exist: $Workspace" }
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path

if ([string]::IsNullOrWhiteSpace($Output)) {
    $skillDir = Split-Path $PSScriptRoot -Parent
    $Output = Join-Path (Join-Path $skillDir '.runtime') ('{0}-{1}.md' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff'), [guid]::NewGuid().ToString('N'))
} elseif (-not [System.IO.Path]::IsPathRooted($Output)) {
    $Output = Join-Path (Get-Location).Path $Output
}
$Output = [System.IO.Path]::GetFullPath($Output)

$fileBlock = ''
foreach ($ref in @($File)) {
    $resolved = Resolve-FileRef -Workspace $Workspace -RawPath $ref
    if (-not [string]::IsNullOrEmpty($resolved)) {
        $existsTag = if (Test-Path -LiteralPath $resolved) { 'exists' } else { 'missing' }
        $fileBlock += "`n- $resolved ($existsTag)"
    }
}
$prompt = $Task
if ($fileBlock) { $prompt += "`nPriority files (read these first before making changes):$fileBlock" }

$codexArgs = [System.Collections.Generic.List[string]]::new()
$codexArgs.Add('exec')
$codexArgs.Add('--ignore-user-config')
if ($Session) {
    $codexArgs.Add('resume')
    $codexArgs.Add('--json')
    $codexArgs.Add('--skip-git-repo-check')
} else {
    $codexArgs.Add('--cd')
    $codexArgs.Add($Workspace)
    $codexArgs.Add('--skip-git-repo-check')
    $codexArgs.Add('--json')
}
$codexArgs.Add('-c')
$codexArgs.Add(('model_reasoning_effort="{0}"' -f $Reasoning))
if ($Session) {
    if ($ReadOnly) {
        $codexArgs.Add('-c'); $codexArgs.Add('sandbox_mode="read-only"')
    } elseif ($Sandbox) {
        $codexArgs.Add('-c'); $codexArgs.Add(('sandbox_mode="{0}"' -f $Sandbox))
    }
} elseif ($ReadOnly) {
    $codexArgs.Add('--sandbox'); $codexArgs.Add('read-only')
} elseif ($Sandbox) {
    $codexArgs.Add('--sandbox'); $codexArgs.Add($Sandbox)
} elseif ($FullAuto) {
    $codexArgs.Add('--full-auto')
}
if ($Model) { $codexArgs.Add('-m'); $codexArgs.Add($Model) }
if ($Ephemeral) { $codexArgs.Add('--ephemeral') }
if ($Session) { $codexArgs.Add('--'); $codexArgs.Add($Session) }
$codexArgs.Add('-')

$launch = Resolve-CodexLaunch -CodexArguments $codexArgs.ToArray()
$caBundlePath = ''
$primaryError = $null
$caCleanupError = $null
$threadId = if ($Session) { $Session } else { '' }
$outputContent = [System.Collections.Generic.List[string]]::new()
try {
    $environmentOverrides = @{}
    if ($IsWindows -and [string]::IsNullOrWhiteSpace($env:CODEX_CA_CERTIFICATE)) {
        try {
            $caBundlePath = New-CodexCaBundle
            $environmentOverrides.CODEX_CA_CERTIFICATE = $caBundlePath
        } catch {
            Write-Host "[codex] custom CA bundle unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    $invocation = Invoke-CodexProcess -Launch $launch -Arguments $launch.Arguments -WorkingDirectory $Workspace -InputText $prompt -TimeoutSeconds $TimeoutSeconds -EnvironmentOverrides $environmentOverrides -OnStdOut ${function:Show-CodexProgressLine}

    foreach ($line in $invocation.StdErrLines) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { [Console]::Error.WriteLine('[codex stderr] ' + $line) }
    }
    if ($invocation.TimedOut) { throw "Codex timed out after $TimeoutSeconds seconds." }
    if ($invocation.ExitCode -ne 0) { throw "Codex exited with code $($invocation.ExitCode)." }

    $hasAgentResponse = $false
    foreach ($line in $invocation.StdOutLines) {
        $clean = $line -replace "`r", '' -replace [char]4, ''
        if (-not $clean.TrimStart().StartsWith('{')) { continue }
        try { $event = $clean | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $rawThreadId = Get-PropertyValue -Object $event -Name 'thread_id'
        if ($null -ne $rawThreadId -and $rawThreadId -isnot [string]) { throw 'Codex thread_id must be a string.' }
        $eventThreadId = [string]$rawThreadId
        if ($eventThreadId) { $threadId = $eventThreadId }
        $rawType = Get-PropertyValue -Object $event -Name 'type'
        if ($null -ne $rawType -and $rawType -isnot [string]) { throw 'Codex event type must be a string.' }
        $type = [string]$rawType
        $item = Get-PropertyValue -Object $event -Name 'item'
        if ($type -ne 'item.completed' -or $null -eq $item) { continue }
        $rawItemType = Get-PropertyValue -Object $item -Name 'type'
        if ($null -ne $rawItemType -and $rawItemType -isnot [string]) { throw 'Codex item type must be a string.' }
        $itemType = [string]$rawItemType
        if ($itemType -eq 'agent_message') {
            $rawText = Get-PropertyValue -Object $item -Name 'text'
            if ($null -ne $rawText -and $rawText -isnot [string]) { throw 'Codex agent message text must be a string.' }
            $text = [string]$rawText
            if (-not [string]::IsNullOrWhiteSpace($text)) { $outputContent.Add($text); $hasAgentResponse = $true }
        } elseif ($itemType -eq 'command_execution') {
            $command = [string](Get-PropertyValue -Object $item -Name 'command')
            $aggregated = [string](Get-PropertyValue -Object $item -Name 'aggregated_output')
            if ($command) {
                $command = $command -replace '^/bin/(zsh|bash) (-lc|-c) ', ''
                $outputContent.Add("### Shell: ``$($command.Substring(0, [Math]::Min(200, $command.Length)))```n$($aggregated.Substring(0, [Math]::Min(500, $aggregated.Length)))")
            }
        }
    }
    if (-not $hasAgentResponse) { throw 'Codex exited successfully without an agent response.' }
    if ($threadId -match '\p{Cc}') { throw 'Codex thread id contains a control character and cannot be emitted safely.' }
} catch {
    $primaryError = $_
} finally {
    if ($caBundlePath) {
        try { Remove-Item -LiteralPath $caBundlePath -Force -ErrorAction Stop } catch { $caCleanupError = $_ }
    }
}
if ($null -ne $caCleanupError) {
    $message = if ($null -ne $primaryError) { $primaryError.Exception.Message } else { 'Codex invocation cleanup failed.' }
    throw [System.InvalidOperationException]::new(($message + ' CA cleanup failure: ' + $caCleanupError.Exception.Message), $(if ($null -ne $primaryError) { $primaryError.Exception } else { $caCleanupError.Exception }))
}
if ($null -ne $primaryError) { throw $primaryError }

Write-Utf8NoBomAtomic -Path $Output -Content ($outputContent -join "`n")
if ($threadId) { Write-Output "session_id=$threadId" }
Write-Output "output_path=$Output"
