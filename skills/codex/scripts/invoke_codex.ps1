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

    [ValidateSet('low', 'medium', 'high', 'max')]
    [string]$Reasoning = 'medium',

    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$Sandbox,

    [ValidateSet('untrusted', 'on-request', 'never')]
    [string]$ApprovalPolicy,

    [switch]$ReadOnly,

    [switch]$FullAuto,

    [switch]$Ephemeral,

    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 1800,

    [Alias('o')]
    [string]$Output,

    [string]$OutputSchema,

    [string]$TelemetryOutput,

    [string]$OtelTraceEndpoint,

    [string]$OtelClientIdentityPath,

    [string]$OtelCollectorInstanceId,

    [Parameter(DontShow)]
    [ValidateSet('0.144.4')]
    [string]$ExpectedCodexVersion = '',

    [switch]$AgentOutputOnly,

    [switch]$Quiet,

    [switch]$Isolated,

    [switch]$Help,

    [Parameter(DontShow)]
    [string]$InternalShimPath,

    [Parameter(DontShow)]
    [string]$InternalShimArgumentsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hasInternalShimPath = -not [string]::IsNullOrWhiteSpace($InternalShimPath)
$hasInternalShimArguments = -not [string]::IsNullOrWhiteSpace($InternalShimArgumentsJson)
if ($hasInternalShimPath -or $hasInternalShimArguments) {
    if (-not ($hasInternalShimPath -and $hasInternalShimArguments)) { throw 'Internal shim path and arguments must be provided together.' }
    $resolvedShimPath = [IO.Path]::GetFullPath($InternalShimPath)
    if ([IO.Path]::GetExtension($resolvedShimPath) -cne '.ps1' -or -not (Test-Path -LiteralPath $resolvedShimPath -PathType Leaf)) { throw 'Internal shim path must be an existing PowerShell script.' }
    $expectedShimPath = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_EXECUTABLE)) { [IO.Path]::GetFullPath($env:CODEX_EXECUTABLE) } else { [string](Get-Command codex -ErrorAction Stop).Path }
    $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ([string]::IsNullOrWhiteSpace($expectedShimPath) -or -not $resolvedShimPath.Equals([IO.Path]::GetFullPath($expectedShimPath),$pathComparison)) { throw 'Internal shim path must match the resolved Codex command.' }
    $shimArgumentsDocument = $InternalShimArgumentsJson | ConvertFrom-Json -AsHashtable -Depth 5
    if (@($shimArgumentsDocument.Keys).Count -ne 1 -or -not $shimArgumentsDocument.ContainsKey('arguments') -or $shimArgumentsDocument.arguments -isnot [array]) { throw 'Internal shim arguments are invalid.' }
    $shimArguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @($shimArgumentsDocument.arguments)) {
        if ($argument -isnot [string]) { throw 'Internal shim arguments must be strings.' }
        $shimArguments.Add([string]$argument)
    }
    $PSNativeCommandArgumentPassing = 'Standard'
    $shimArgumentArray = $shimArguments.ToArray()
    & $resolvedShimPath @shimArgumentArray
    if ($null -eq $LASTEXITCODE) { exit 0 }
    exit $LASTEXITCODE
}

function Show-Usage {
    @'
Usage:
  invoke_codex.ps1 <task> [options]
  invoke_codex.ps1 -Task <task> [options]

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
  -Reasoning <level>           Reasoning effort: low, medium, high, max (default: medium)
  -Sandbox <mode>              read-only, workspace-write, or danger-full-access
  -ApprovalPolicy <policy>     untrusted, on-request, or never
  -ReadOnly                    Read-only sandbox, including resume mode
  -FullAuto                    Full-auto mode for a new session
  -Ephemeral                   Do not persist Codex session files
  -TimeoutSeconds <seconds>    Main Codex timeout (default: 1800)
  -Output, -o <path>           Output file; relative paths use the caller's current directory
  -OutputSchema <path>         JSON Schema for the final model response
  -TelemetryOutput <path>      Sanitized aggregate telemetry JSON (no prompt, command, or thread id)
  -OtelTraceEndpoint <url>     Internal loopback OTLP trace endpoint for release qualification
  -OtelClientIdentityPath <p>  Internal pre-prompt OTLP client identity handshake path
  -OtelCollectorInstanceId <id> Internal OTLP collector instance binding
  -AgentOutputOnly             Omit command summaries from the response file
  -Quiet                       Suppress live command/message previews
  -Isolated                    Disable plugins, apps, memory, browser/computer, and multi-agent features
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

function Write-Utf8NoBomCreateNewAtomic {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $parent = [IO.Path]::GetDirectoryName($Path)
    $tempPath = Join-Path $parent ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path),[guid]::NewGuid().ToString('N'))
    $stream = $null
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream = [IO.FileStream]::new($tempPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [IO.File]::Move($tempPath,$Path)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}

function Get-CodexOtelClientIdentity {
    param([Parameter(Mandatory)][Diagnostics.Process]$RootProcess,[Parameter(Mandatory)]$Launch)
    if (-not $IsWindows) { throw 'OTLP client process provenance is supported on Windows only.' }
    if ([string]$Launch.OtelClientMode -ceq 'direct') {
        if ($RootProcess.HasExited) { throw 'Codex exited before OTLP client registration.' }
        return [ordered]@{process_id=$RootProcess.Id;start_time_filetime_utc=$RootProcess.StartTime.ToUniversalTime().ToFileTimeUtc()}
    }
    if ([string]$Launch.OtelClientMode -cne 'descendant-codex-exe') { throw 'Codex launch cannot provide an OTLP client identity.' }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ($RootProcess.HasExited) { throw 'Codex shim exited before OTLP client registration.' }
        $processes = @(Get-Process -Name codex -ErrorAction SilentlyContinue)
        try {
            $matches = [Collections.Generic.List[Diagnostics.Process]]::new()
            foreach ($candidate in $processes) {
                try {
                    $cursor = $candidate
                    for ($depth = 0; $depth -lt 64 -and $null -ne $cursor; $depth++) {
                        if ($cursor.Id -eq $RootProcess.Id) { [void]$matches.Add($candidate); break }
                        $cursor = $cursor.Parent
                    }
                } catch {}
            }
            if ($matches.Count -gt 1) { throw 'Codex shim produced an ambiguous native process tree.' }
            if ($matches.Count -eq 1) {
                $client = $matches[0]
                $client.Refresh()
                if (-not $client.HasExited -and $client.StartTime.ToUniversalTime() -ge $RootProcess.StartTime.ToUniversalTime()) {
                    return [ordered]@{process_id=$client.Id;start_time_filetime_utc=$client.StartTime.ToUniversalTime().ToFileTimeUtc()}
                }
            }
        } finally {
            foreach ($candidate in $processes) { try { $candidate.Dispose() } catch {} }
        }
        Start-Sleep -Milliseconds 25
    }
    throw 'Native Codex OTLP client process did not appear before the prompt deadline.'
}

function Register-CodexOtelClient {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$RootProcess,
        [Parameter(Mandatory)]$Launch,
        [Parameter(Mandatory)][string]$IdentityPath,
        [Parameter(Mandatory)][string]$CollectorInstanceId,
        [Parameter(Mandatory)][int]$Round
    )
    $acceptedPath = $IdentityPath + '.accepted'
    $identity = Get-CodexOtelClientIdentity -RootProcess $RootProcess -Launch $Launch
    $identityText = ([ordered]@{
        schema_version='host-benchmark-otel-client/v1';collector_instance_id=$CollectorInstanceId;round=$Round
        process_id=[int]$identity.process_id;start_time_filetime_utc=[int64]$identity.start_time_filetime_utc
    } | ConvertTo-Json -Compress)
    $identityBytes = [Text.UTF8Encoding]::new($false).GetBytes($identityText)
    $identityDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($identityBytes)).ToLowerInvariant()
    Write-Utf8NoBomCreateNewAtomic -Path $IdentityPath -Content $identityText
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ([DateTimeOffset]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $acceptedPath -PathType Leaf)) {
        if ($RootProcess.HasExited) { throw 'Codex exited before the OTLP collector acknowledged its identity.' }
        Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $acceptedPath -PathType Leaf)) { throw 'OTLP collector did not acknowledge the Codex client before the prompt deadline.' }
    $acceptedItem = Get-Item -LiteralPath $acceptedPath -Force -ErrorAction Stop
    if (($acceptedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $acceptedItem.Length -le 0 -or $acceptedItem.Length -gt 4096) { throw 'OTLP client acknowledgement file is invalid.' }
    $ack = [IO.File]::ReadAllText($acceptedPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 5
    $actualKeys = @($ack.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedKeys = @('schema_version','collector_instance_id','round','identity_sha256') | Sort-Object
    if ($actualKeys.Count -ne $expectedKeys.Count -or @(Compare-Object $actualKeys $expectedKeys -SyncWindow 0).Count -ne 0 -or [string]$ack.schema_version -cne 'host-benchmark-otel-client-ack/v1' -or [string]$ack.collector_instance_id -cne $CollectorInstanceId -or [int]$ack.round -ne $Round -or [string]$ack.identity_sha256 -cne $identityDigest) { throw 'OTLP client acknowledgement does not bind the expected identity.' }
    [IO.File]::Delete($IdentityPath)
    [IO.File]::Delete($acceptedPath)
    if ((Test-Path -LiteralPath $IdentityPath) -or (Test-Path -LiteralPath $acceptedPath)) { throw 'OTLP client identity controls were not removed before the prompt.' }
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
    if ($IsWindows -and $path -match '(?i)[\\/]WindowsApps[\\/]' -and [string]::IsNullOrWhiteSpace($env:CODEX_EXECUTABLE)) {
        $appBinary = Join-Path $HOME '.codex\.sandbox-bin\codex.exe'
        if (Test-Path -LiteralPath $appBinary -PathType Leaf) { $path = (Resolve-Path -LiteralPath $appBinary).Path }
    } elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_EXECUTABLE)) {
        $configured = [System.IO.Path]::GetFullPath($env:CODEX_EXECUTABLE)
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) { throw "CODEX_EXECUTABLE does not exist: $configured" }
        $path = $configured
    }
    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $hostPath = (Get-Process -Id $PID).Path
        if ((Split-Path -Leaf $hostPath) -notmatch '^pwsh(\.exe)?$') {
            throw 'invoke_codex.ps1 requires the pwsh host.'
        }
        $argumentJson = [ordered]@{arguments=@($CodexArguments)} | ConvertTo-Json -Compress
        return [pscustomobject]@{
            FilePath = $hostPath
            PrefixArguments = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-InternalShimPath', $path, '-InternalShimArgumentsJson', $argumentJson)
            Arguments = @()
            EnvironmentOverrides = @{ CODEX_EXECUTABLE = $path }
            OtelClientMode = 'descendant-codex-exe'
            ResolvedCodexPath = [System.IO.Path]::GetFullPath($path)
        }
    }
    if ($extension -in @('.cmd', '.bat')) {
        throw "Unsafe shell shim is not supported: $path"
    }
    if ($IsWindows -and $extension -ne '.exe') {
        throw "Codex command is not a native executable or PowerShell shim: $path"
    }
    return [pscustomobject]@{ FilePath = $path; PrefixArguments = @(); Arguments = @($CodexArguments); EnvironmentOverrides = @{}; OtelClientMode = 'direct'; ResolvedCodexPath = [System.IO.Path]::GetFullPath($path) }
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
        [scriptblock]$OnStdOut,
        [object]$OtelRegistration
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Launch.FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
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
    foreach ($entry in $Launch.EnvironmentOverrides.GetEnumerator()) {
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
        if ($null -ne $OtelRegistration) {
            Register-CodexOtelClient -RootProcess $process -Launch $Launch -IdentityPath ([string]$OtelRegistration.identity_path) -CollectorInstanceId ([string]$OtelRegistration.collector_instance_id) -Round ([int]$OtelRegistration.round)
        }
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
        if ($null -ne $OtelRegistration) {
            foreach ($controlPath in @([string]$OtelRegistration.identity_path,([string]$OtelRegistration.identity_path + '.accepted'))) {
                try {
                    if (Test-Path -LiteralPath $controlPath) {
                        if (-not (Test-Path -LiteralPath $controlPath -PathType Leaf)) { throw 'control path is not a file' }
                        [IO.File]::Delete($controlPath)
                    }
                } catch { $cleanupErrors.Add('remove OTLP identity control: ' + $_.Exception.Message) }
            }
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
        DurationMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
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
if (-not [string]::IsNullOrWhiteSpace($OutputSchema)) {
    if (-not [System.IO.Path]::IsPathRooted($OutputSchema)) { $OutputSchema = Join-Path (Get-Location).Path $OutputSchema }
    $OutputSchema = [System.IO.Path]::GetFullPath($OutputSchema)
    if (-not (Test-Path -LiteralPath $OutputSchema -PathType Leaf)) { throw "Output schema does not exist: $OutputSchema" }
}
if (-not [string]::IsNullOrWhiteSpace($TelemetryOutput)) {
    if (-not [System.IO.Path]::IsPathRooted($TelemetryOutput)) { $TelemetryOutput = Join-Path (Get-Location).Path $TelemetryOutput }
    $TelemetryOutput = [System.IO.Path]::GetFullPath($TelemetryOutput)
}
$otelTraceUri = $null
$otelRound = 0
if (-not [string]::IsNullOrWhiteSpace($OtelTraceEndpoint)) {
    if (-not [Uri]::TryCreate($OtelTraceEndpoint,[UriKind]::Absolute,[ref]$otelTraceUri) -or
        $otelTraceUri.Scheme -cne 'http' -or $otelTraceUri.Host -cne '127.0.0.1' -or
        $otelTraceUri.Port -le 0 -or -not [string]::IsNullOrEmpty($otelTraceUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($otelTraceUri.Query) -or -not [string]::IsNullOrEmpty($otelTraceUri.Fragment) -or
        $otelTraceUri.AbsolutePath -cnotmatch '^/v1/traces/round-[1-9][0-9]*$') {
        throw 'OtelTraceEndpoint must be an absolute loopback HTTP URL ending in /v1/traces/round-N.'
    }
    $OtelTraceEndpoint = $otelTraceUri.AbsoluteUri
    $otelRound = [int]([regex]::Match($otelTraceUri.AbsolutePath,'round-([1-9][0-9]*)$').Groups[1].Value)
}
$hasOtelEndpoint = -not [string]::IsNullOrWhiteSpace($OtelTraceEndpoint)
$hasOtelIdentity = -not [string]::IsNullOrWhiteSpace($OtelClientIdentityPath)
$hasOtelInstance = -not [string]::IsNullOrWhiteSpace($OtelCollectorInstanceId)
if (($hasOtelEndpoint -or $hasOtelIdentity -or $hasOtelInstance) -and -not ($hasOtelEndpoint -and $hasOtelIdentity -and $hasOtelInstance)) {
    throw 'OtelTraceEndpoint, OtelClientIdentityPath, and OtelCollectorInstanceId must be provided together.'
}
if ($hasOtelEndpoint) {
    if (-not $IsWindows) { throw 'Release-qualification OTLP client provenance is supported on Windows only.' }
    if ($OtelCollectorInstanceId -cnotmatch '^[0-9a-f]{32}$') { throw 'OtelCollectorInstanceId must be 32 lowercase hexadecimal characters.' }
    if (-not [IO.Path]::IsPathRooted($OtelClientIdentityPath)) { throw 'OtelClientIdentityPath must be absolute.' }
    $OtelClientIdentityPath = [IO.Path]::GetFullPath($OtelClientIdentityPath)
    $identityParent = [IO.Path]::GetDirectoryName($OtelClientIdentityPath)
    if (-not (Test-Path -LiteralPath $identityParent -PathType Container)) { throw 'OtelClientIdentityPath parent does not exist.' }
    $identityParentItem = Get-Item -LiteralPath $identityParent -Force -ErrorAction Stop
    if (($identityParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or (Test-Path -LiteralPath $OtelClientIdentityPath) -or (Test-Path -LiteralPath ($OtelClientIdentityPath + '.accepted'))) { throw 'OtelClientIdentityPath must start as a new regular control file.' }
}

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
if ($ApprovalPolicy) { $codexArgs.Add('-a'); $codexArgs.Add($ApprovalPolicy) }
$codexArgs.Add('exec')
$codexArgs.Add('--ignore-user-config')
if ($Isolated) {
    foreach ($feature in @('plugins','remote_plugin','apps','browser_use','computer_use','memories','multi_agent','multi_agent_v2','enable_fanout','in_app_browser','image_generation')) {
        $codexArgs.Add('--disable'); $codexArgs.Add($feature)
    }
}
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
if ($OtelTraceEndpoint) {
    $codexArgs.Add('-c'); $codexArgs.Add('otel.environment="release-qualification"')
    $codexArgs.Add('-c'); $codexArgs.Add('otel.log_user_prompt=false')
    $codexArgs.Add('-c'); $codexArgs.Add('otel.exporter="none"')
    $codexArgs.Add('-c'); $codexArgs.Add(('otel.trace_exporter={{"otlp-http"={{endpoint="{0}",protocol="json"}}}}' -f $OtelTraceEndpoint))
    $codexArgs.Add('-c'); $codexArgs.Add('otel.metrics_exporter="none"')
}
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
if ($OutputSchema) { $codexArgs.Add('--output-schema'); $codexArgs.Add($OutputSchema) }
if ($Session) { $codexArgs.Add('--'); $codexArgs.Add($Session) }
$codexArgs.Add('-')

$launch = Resolve-CodexLaunch -CodexArguments $codexArgs.ToArray()
$verifiedCodexVersion = ''
if (-not [string]::IsNullOrWhiteSpace($ExpectedCodexVersion)) {
    $versionLaunch = Resolve-CodexLaunch -CodexArguments @('--version')
    $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not ([string]$versionLaunch.ResolvedCodexPath).Equals([string]$launch.ResolvedCodexPath,$pathComparison)) {
        throw 'Codex version probe resolved a different executable from the model invocation.'
    }
    $versionInvocation = Invoke-CodexProcess -Launch $versionLaunch -Arguments $versionLaunch.Arguments -WorkingDirectory $Workspace -InputText '' -TimeoutSeconds 15 -EnvironmentOverrides @{} -OnStdOut $null -OtelRegistration $null
    $versionStdOut = @($versionInvocation.StdOutLines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $versionStdErr = @($versionInvocation.StdErrLines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($versionInvocation.TimedOut -or $versionInvocation.ExitCode -ne 0 -or $versionStdErr.Count -ne 0 -or
        $versionStdOut.Count -ne 1 -or [string]$versionStdOut[0] -cne "codex-cli $ExpectedCodexVersion") {
        throw 'Codex executable does not match the required release version.'
    }
    $verifiedCodexVersion = $ExpectedCodexVersion
}
$otelRegistration = if ($hasOtelEndpoint) {
    [pscustomobject]@{identity_path=$OtelClientIdentityPath;collector_instance_id=$OtelCollectorInstanceId;round=$otelRound}
} else { $null }
$caBundlePath = ''
$primaryError = $null
$caCleanupError = $null
$threadId = if ($Session) { $Session } else { '' }
$outputContent = [System.Collections.Generic.List[string]]::new()
$streamTimer = [System.Diagnostics.Stopwatch]::StartNew()
$telemetryState = @{
    FirstUsefulActionMs = $null
    TurnCount = 0
    AgentMessageCount = 0
    CommandCallCount = 0
    McpCallCount = 0
    WebSearchCount = 0
    FileChangeCount = 0
    SkillLoadCount = 0
    InputTokens = $null
    CachedInputTokens = $null
    OutputTokens = $null
}
$onStdOut = {
    param([string]$Line)

    if (-not $Quiet) { Show-CodexProgressLine -Line $Line }
    $clean = $Line -replace "`r", '' -replace [char]4, ''
    if (-not $clean.TrimStart().StartsWith('{')) { return }
    try { $event = $clean | ConvertFrom-Json -ErrorAction Stop } catch { return }
    $type = [string](Get-PropertyValue -Object $event -Name 'type')
    $item = Get-PropertyValue -Object $event -Name 'item'
    $itemType = [string](Get-PropertyValue -Object $item -Name 'type')
    if ($type -eq 'turn.started') { $telemetryState.TurnCount++ }
    if ($type -eq 'item.started' -and $null -eq $telemetryState.FirstUsefulActionMs -and $itemType -in @('command_execution','mcp_tool_call','web_search','file_change')) {
        $telemetryState.FirstUsefulActionMs = [Math]::Round($streamTimer.Elapsed.TotalMilliseconds, 2)
    }
    if ($type -eq 'item.completed') {
        switch ($itemType) {
            'agent_message' {
                $telemetryState.AgentMessageCount++
                if ($null -eq $telemetryState.FirstUsefulActionMs) { $telemetryState.FirstUsefulActionMs = [Math]::Round($streamTimer.Elapsed.TotalMilliseconds, 2) }
            }
            'command_execution' {
                $telemetryState.CommandCallCount++
                $commandText = [string](Get-PropertyValue -Object $item -Name 'command')
                if ($commandText -match '(?i)(^|[\\/])SKILL\.md(?:\s|$|["''])') { $telemetryState.SkillLoadCount++ }
            }
            'mcp_tool_call' { $telemetryState.McpCallCount++ }
            'web_search' { $telemetryState.WebSearchCount++ }
            'file_change' { $telemetryState.FileChangeCount++ }
        }
    }
    if ($type -eq 'turn.completed') {
        $usage = Get-PropertyValue -Object $event -Name 'usage'
        foreach ($mapping in @(
            @('input_tokens','InputTokens'),
            @('cached_input_tokens','CachedInputTokens'),
            @('output_tokens','OutputTokens')
        )) {
            $value = Get-PropertyValue -Object $usage -Name $mapping[0]
            if ($null -ne $value) { $telemetryState[$mapping[1]] = [long]$value }
        }
    }
}
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
    $invocation = Invoke-CodexProcess -Launch $launch -Arguments $launch.Arguments -WorkingDirectory $Workspace -InputText $prompt -TimeoutSeconds $TimeoutSeconds -EnvironmentOverrides $environmentOverrides -OnStdOut $onStdOut -OtelRegistration $otelRegistration

    foreach ($line in $invocation.StdErrLines) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { [Console]::Error.WriteLine('[codex stderr] ' + $line) }
    }
    if ($invocation.TimedOut) { throw "Codex timed out after $TimeoutSeconds seconds." }
    if ($invocation.ExitCode -ne 0) {
        $diagnostic = ''
        foreach ($line in $invocation.StdOutLines) {
            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
                if ([string](Get-PropertyValue -Object $event -Name 'type') -ceq 'error') {
                    $diagnostic = [string](Get-PropertyValue -Object $event -Name 'message')
                    break
                }
            } catch {}
        }
        if ($diagnostic) {
            $diagnostic = $diagnostic -replace [regex]::Escape($Workspace), '<workspace>' -replace [regex]::Escape($HOME), '<home>'
            if ($diagnostic.Length -gt 500) { $diagnostic = $diagnostic.Substring(0,500) }
            throw "Codex exited with code $($invocation.ExitCode): $diagnostic"
        }
        throw "Codex exited with code $($invocation.ExitCode)."
    }

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
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                if ($OutputSchema) { $outputContent.Clear() }
                $outputContent.Add($text)
                $hasAgentResponse = $true
            }
        } elseif ($itemType -eq 'command_execution' -and -not $AgentOutputOnly) {
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
if ($TelemetryOutput) {
    $effectiveSandbox = if ($ReadOnly) { 'read-only' } elseif ($Sandbox) { $Sandbox } elseif ($FullAuto) { 'workspace-write' } else { 'default' }
    $tokenStatus = if ($null -ne $telemetryState.InputTokens -and $null -ne $telemetryState.OutputTokens) { 'measured' } else { 'unavailable' }
    $telemetry = [ordered]@{
        schema_version = $(if ([string]::IsNullOrWhiteSpace($verifiedCodexVersion)) { 'codex-invocation-telemetry/v1' } else { 'codex-invocation-telemetry/v2' })
        status = 'measured'
        model = $(if ($Model) { $Model } else { 'inherit' })
        reasoning = $Reasoning
        sandbox = $effectiveSandbox
        approval_policy = $(if ($ApprovalPolicy) { $ApprovalPolicy } else { 'default' })
        ephemeral = [bool]$Ephemeral
        duration_ms = [double]$invocation.DurationMs
        first_useful_action_ms = $telemetryState.FirstUsefulActionMs
        model_turns = [int]$telemetryState.TurnCount
        agent_messages = [int]$telemetryState.AgentMessageCount
        tool_calls = [ordered]@{
            command = [int]$telemetryState.CommandCallCount
            mcp = [int]$telemetryState.McpCallCount
            web_search = [int]$telemetryState.WebSearchCount
            file_change = [int]$telemetryState.FileChangeCount
        }
        lifecycle_skill_loads = [int]$telemetryState.SkillLoadCount
        otel_trace = [ordered]@{
            enabled = -not [string]::IsNullOrWhiteSpace($OtelTraceEndpoint)
            contract = $(if ($OtelTraceEndpoint) { 'codex-0.144.4-successful-websocket-send/v2' } else { $null })
            provenance = $(if ($OtelTraceEndpoint) { 'verified-owner-pid-start-time/v1' } else { $null })
        }
        tokens = [ordered]@{
            status = $tokenStatus
            input = $telemetryState.InputTokens
            cached_input = $telemetryState.CachedInputTokens
            output = $telemetryState.OutputTokens
        }
        output_schema = [ordered]@{
            enabled = -not [string]::IsNullOrWhiteSpace($OutputSchema)
            digest = $(if ($OutputSchema) { 'sha256:' + (Get-FileHash -LiteralPath $OutputSchema -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null })
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($verifiedCodexVersion)) { $telemetry.codex_cli_version = $verifiedCodexVersion }
    Write-Utf8NoBomAtomic -Path $TelemetryOutput -Content ($telemetry | ConvertTo-Json -Depth 8)
}
if ($threadId) { Write-Output "session_id=$threadId" }
Write-Output "output_path=$Output"
if ($TelemetryOutput) { Write-Output "telemetry_path=$TelemetryOutput" }
