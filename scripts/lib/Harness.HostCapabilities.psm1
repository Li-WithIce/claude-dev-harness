Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HostCapabilityNames = @(
    'workspace_protocol_config',
    'structured_tool_events',
    'request_send_telemetry',
    'desktop_profile_isolation',
    'hook_status_query'
)

function Get-HarnessCodexVersionObservation {
    param()

    $process = $null
    $stdoutStream = $null
    $stderrStream = $null
    $stdoutState = $null
    $stderrState = $null
    $cleanupAttempted = $false
    try {
        $command = Get-Command codex -CommandType Application,ExternalScript -ErrorAction Stop | Select-Object -First 1
        $commandPath = [string]$command.Path
        if ([string]::IsNullOrWhiteSpace($commandPath)) {
            return [ordered]@{ status = 'unavailable'; actual = 'unknown' }
        }

        $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $processInfo.FileName = (Get-Process -Id $PID).Path
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true
        $processInfo.WorkingDirectory = [System.IO.Path]::GetTempPath()
        $commandText = "& '$($commandPath.Replace("'", "''"))' --version"
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $commandText)) {
            $processInfo.ArgumentList.Add($argument)
        }
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $processInfo
        [void]$process.Start()

        $stdoutStream = $process.StandardOutput.BaseStream
        $stderrStream = $process.StandardError.BaseStream
        $stdoutState = [ordered]@{
            stream = $stdoutStream
            buffer = [byte[]]::new(4096)
            task = $null
            eof = $false
            failed = $false
            observed = $false
            retained = [System.IO.MemoryStream]::new()
        }
        $stderrState = [ordered]@{
            stream = $stderrStream
            buffer = [byte[]]::new(4096)
            task = $null
            eof = $false
            failed = $false
            observed = $false
            retained = [System.IO.MemoryStream]::new()
        }
        $states = @($stdoutState, $stderrState)
        $retainedBytes = 0
        $truncated = $false
        $probeTimer = [System.Diagnostics.Stopwatch]::StartNew()

        while ($probeTimer.ElapsedMilliseconds -lt 5000) {
            $madeProgress = $false
            foreach ($state in $states) {
                if ($state.eof -or $state.failed) {
                    continue
                }
                if ($null -eq $state.task) {
                    try {
                        $state.task = $state.stream.ReadAsync($state.buffer, 0, $state.buffer.Length)
                    } catch {
                        $state.failed = $true
                    }
                }
                if ($null -eq $state.task -or -not $state.task.IsCompleted) {
                    continue
                }

                try {
                    $readCount = $state.task.GetAwaiter().GetResult()
                } catch {
                    $state.failed = $true
                    continue
                } finally {
                    $state.task = $null
                }
                $madeProgress = $true
                if ($readCount -eq 0) {
                    $state.eof = $true
                    continue
                }

                $state.observed = $true
                $remaining = 65536 - $retainedBytes
                $retainCount = [Math]::Min($readCount, [Math]::Max(0, $remaining))
                if ($retainCount -gt 0) {
                    $state.retained.Write($state.buffer, 0, $retainCount)
                    $retainedBytes += $retainCount
                }
                if ($retainCount -lt $readCount) {
                    $truncated = $true
                }
            }

            if ($stdoutState.failed -or $stderrState.failed) {
                break
            }
            $rootExited = try { $process.HasExited } catch { $false }
            if ($rootExited -and $stdoutState.eof -and $stderrState.eof) {
                break
            }
            if (-not $madeProgress) {
                Start-Sleep -Milliseconds 10
            }
        }

        $probeComplete = (-not $stdoutState.failed) -and
            (-not $stderrState.failed) -and
            $process.HasExited -and
            $stdoutState.eof -and
            $stderrState.eof
        if (-not $probeComplete) {
            $cleanupAttempted = $true
            if (-not $process.HasExited) {
                try { $process.Kill($true) } catch { }
                try { [void]$process.WaitForExit(2000) } catch { }
            }
            return [ordered]@{ status = 'unavailable'; actual = 'unknown' }
        }
        if ($process.ExitCode -ne 0 -or $stderrState.observed -or $truncated) {
            return [ordered]@{ status = 'unavailable'; actual = 'unknown' }
        }

        try {
            $stdout = [System.Text.UTF8Encoding]::new($false, $true).GetString($stdoutState.retained.ToArray())
        } catch {
            return [ordered]@{ status = 'unavailable'; actual = 'unknown' }
        }
        $match = [regex]::Match($stdout, '\Acodex-cli (?<version>\S+)(?:\r\n|\n)?\z', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if (-not $match.Success) {
            return [ordered]@{ status = 'unavailable'; actual = 'unknown' }
        }
        return [ordered]@{ status = 'observed'; actual = [string]$match.Groups['version'].Value }
    } catch {
        return [ordered]@{ status = 'unavailable'; actual = 'unknown' }
    } finally {
        if ($null -ne $process -and -not $cleanupAttempted) {
            try {
                if (-not $process.HasExited) {
                    $cleanupAttempted = $true
                    try { $process.Kill($true) } catch { }
                    try { [void]$process.WaitForExit(2000) } catch { }
                }
            } catch { }
        }
        if ($null -ne $stdoutStream) { try { $stdoutStream.Dispose() } catch { } }
        if ($null -ne $stderrStream) { try { $stderrStream.Dispose() } catch { } }
        if ($null -ne $stdoutState) { try { $stdoutState.retained.Dispose() } catch { } }
        if ($null -ne $stderrState) { try { $stderrState.retained.Dispose() } catch { } }
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Assert-HarnessHostCapabilitiesDocument {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)

    $expected = @('schema_version','product','actual_version','observation_status','capabilities')
    $actual = @($Document.Keys | ForEach-Object { [string]$_ })
    if (@(Compare-Object ($expected | Sort-Object) ($actual | Sort-Object)).Count -ne 0 -or
        [string]$Document.schema_version -cne 'harness-host-capabilities/v1' -or
        [string]$Document.product -cne 'codex' -or
        [string]::IsNullOrWhiteSpace([string]$Document.actual_version) -or
        [string]$Document.observation_status -cnotin @('observed','partial','unavailable') -or
        $Document.capabilities -isnot [System.Collections.IDictionary]) {
        throw 'host-capabilities-invalid-document'
    }
    $capabilityNames = @($Document.capabilities.Keys | ForEach-Object { [string]$_ })
    if (@(Compare-Object ($script:HostCapabilityNames | Sort-Object) ($capabilityNames | Sort-Object)).Count -ne 0) {
        throw 'host-capabilities-invalid-capability-set'
    }
    foreach ($name in $script:HostCapabilityNames) {
        $value = $Document.capabilities[$name]
        if ($value -isnot [bool] -and [string]$value -cnotin @('unknown','unavailable')) {
            throw "host-capabilities-invalid-value-$name"
        }
    }
    return $true
}

function Get-HarnessHostCapabilities {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $root = (Resolve-Path -LiteralPath $RepoRoot).Path
    $version = Get-HarnessCodexVersionObservation
    $workspaceProtocolConfig = (Test-Path -LiteralPath (Join-Path $root 'schemas\protocol-config.schema.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $root 'scripts\lib\Harness.Protocol.psm1') -PathType Leaf)
    $document = [ordered]@{
        schema_version = 'harness-host-capabilities/v1'
        product = 'codex'
        actual_version = $(if ([string]$version.status -ceq 'observed') { [string]$version.actual } else { 'unknown' })
        observation_status = 'partial'
        capabilities = [ordered]@{
            workspace_protocol_config = [bool]$workspaceProtocolConfig
            structured_tool_events = 'unavailable'
            request_send_telemetry = 'unavailable'
            desktop_profile_isolation = 'unavailable'
            hook_status_query = 'unavailable'
        }
    }
    [void](Assert-HarnessHostCapabilitiesDocument -Document $document)
    return $document
}

Export-ModuleMember -Function Get-HarnessHostCapabilities,Assert-HarnessHostCapabilitiesDocument
