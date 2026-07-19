[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [string]$RepoRoot = "",
    [string]$UserProfileRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-HarnessBoundedUtf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxBytes = 4MB
    )

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        if ($stream.Length -gt $MaxBytes) {
            throw 'bounded text input exceeds its size limit'
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                throw 'bounded text input ended before its declared length'
            }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1) {
            throw 'bounded text input exceeds its size limit'
        }
        return [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-HarnessHookInstallation {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$UserProfileRoot
    )

    $hookPath = Join-Path $UserProfileRoot '.codex\hooks.json'
    $launcherPath = Join-Path $UserProfileRoot '.claude\hooks-memory\codex-pretooluse-launcher.ps1'
    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
        return [ordered]@{ status = 'missing'; reason = 'hooks-json-missing' }
    }
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        return [ordered]@{ status = 'missing'; reason = 'hook-launcher-missing' }
    }

    try {
        $actual = Read-HarnessBoundedUtf8Text -Path $hookPath | ConvertFrom-Json -AsHashtable -Depth 32 -ErrorAction Stop
        $templatePath = Join-Path $RepoRoot 'agent-configs\codex\hooks.shared.json.template'
        $windowsPowerShellJson = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe').Replace('\', '\\')
        $launcherPathJson = $launcherPath.Replace("'", "''").Replace('\', '\\')
        $renderedTemplate = (Read-HarnessBoundedUtf8Text -Path $templatePath).
            Replace('{WINDOWS_POWERSHELL_EXE}', $windowsPowerShellJson).
            Replace('{CODEX_PRETOOLUSE_LAUNCHER_PS_LITERAL}', $launcherPathJson)
        $expected = $renderedTemplate | ConvertFrom-Json -AsHashtable -Depth 16 -ErrorAction Stop
        if ($actual -isnot [System.Collections.IDictionary] -or
            -not $actual.Contains('hooks') -or
            $actual.hooks -isnot [System.Collections.IDictionary]) {
            return [ordered]@{ status = 'invalid'; reason = 'hooks-json-shape-invalid' }
        }

        $expectedSection = @($expected.PreToolUse)[0]
        $expectedHook = @($expectedSection.hooks)[0]
        $matches = @(
            foreach ($eventName in @($actual.hooks.Keys)) {
                foreach ($section in @($actual.hooks[$eventName])) {
                    if ($section -isnot [System.Collections.IDictionary] -or -not $section.Contains('hooks')) {
                        continue
                    }
                    foreach ($hook in @($section.hooks)) {
                        if ($hook -is [System.Collections.IDictionary] -and
                            $hook.Contains('command') -and
                            [string]$hook.command -ceq [string]$expectedHook.command) {
                            [pscustomobject]@{ Event = $eventName; Section = $section; Hook = $hook }
                        }
                    }
                }
            }
        )
        if ($matches.Count -eq 1 -and
            [string]$matches[0].Event -ceq 'PreToolUse' -and
            [string]$matches[0].Section.matcher -ceq [string]$expectedSection.matcher -and
            [string]$matches[0].Hook.type -ceq [string]$expectedHook.type -and
            [string]$matches[0].Hook.statusMessage -ceq [string]$expectedHook.statusMessage -and
            [int]$matches[0].Hook.timeout -eq [int]$expectedHook.timeout) {
            return [ordered]@{ status = 'verified'; reason = 'hook-command-installed' }
        }
        return [ordered]@{ status = 'invalid'; reason = 'hook-command-missing-or-duplicated' }
    } catch {
        return [ordered]@{ status = 'invalid'; reason = 'hook-installation-check-failed' }
    }
}

function Get-HarnessHostVersion {
    param([Parameter(Mandatory = $true)][string]$ExpectedVersion)

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
        if ([string]$match.Groups['version'].Value -ceq $ExpectedVersion) {
            return [ordered]@{ status = 'verified'; actual = $ExpectedVersion }
        }
        return [ordered]@{ status = 'mismatch'; actual = $match.Groups['version'].Value }
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

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -ErrorAction Stop
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $effectiveUserProfile = if ([string]::IsNullOrWhiteSpace($UserProfileRoot)) { $env:USERPROFILE } else { $UserProfileRoot }
    if ([string]::IsNullOrWhiteSpace($effectiveUserProfile)) {
        throw 'USERPROFILE is required for harness-status.ps1'
    }
    $effectiveUserProfile = [System.IO.Path]::GetFullPath($effectiveUserProfile)

    $hook = Get-HarnessHookInstallation -RepoRoot $RepoRoot -UserProfileRoot $effectiveUserProfile
    $hostVersion = Get-HarnessHostVersion -ExpectedVersion '0.144.4'

    try {
        $protectedModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.ProtectedAction.psm1') -Force -PassThru -ErrorAction Stop
        $null = & $protectedModule { param($Root, $Workspace) Read-HarnessProtectedPolicy -RepoRoot $Root -WorkspaceRoot $Workspace } $RepoRoot $WorkspaceRoot
        $protectedPolicy = [ordered]@{ status = 'verified'; reason = 'core-and-overlay-policy-valid' }
    } catch {
        $protectedPolicy = [ordered]@{
            status = $(if ($_.Exception.Message -match 'unavailable') { 'unavailable' } else { 'invalid' })
            reason = 'protected-policy-check-failed'
        }
    }

    try {
        $previousGitOptionalLocks = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', '0', [EnvironmentVariableTarget]::Process)
            Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -ErrorAction Stop
            $resolution = Get-HarnessProtocolResolution `
                -WorkspaceRoot $WorkspaceRoot `
                -RepoRoot $RepoRoot `
                -RequestedProtocol auto `
                -EligibilityReportPath '.assistant/runtime/rollout/v2-eligibility.json'
            $canonicalReport = [ordered]@{
                status = [string]$resolution.rollout_eligibility.status
                reason = [string]$resolution.rollout_eligibility.reason
            }
        } finally {
            [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', $previousGitOptionalLocks, [EnvironmentVariableTarget]::Process)
        }
    } catch {
        $canonicalReport = [ordered]@{ status = 'unavailable'; reason = 'canonical-report-check-failed' }
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    if ([string]$hook.status -cne 'verified') { $errors.Add("Codex Hook installation is $($hook.status): $($hook.reason)") }
    if ([string]$protectedPolicy.status -cne 'verified') { $errors.Add("Protected Action policy is $($protectedPolicy.status): $($protectedPolicy.reason)") }
    $warnings.Add('Codex Hook trust is unknown because the host exposes no authoritative trust query.')
    $warnings.Add('Codex Hook callability is unknown until a host-mediated invocation is observed.')
    if ([string]$hostVersion.status -cne 'verified') { $warnings.Add("Codex Host version is $($hostVersion.status); expected 0.144.4.") }
    $warnings.Add('Desktop enforcement is unavailable because the qualification-only controlled writer is not installed.')
    if ([string]$canonicalReport.status -cne 'pass') { $warnings.Add("Canonical rollout report is $($canonicalReport.status): $($canonicalReport.reason)") }

    $status = if ($errors.Count -gt 0) { 'FAIL' } elseif ($warnings.Count -gt 0) { 'WARN' } else { 'PASS' }
    Write-Output ("STATUS: {0}" -f $status)
    Write-Output ("RepoRoot: {0}" -f $RepoRoot)
    Write-Output ("WorkspaceRoot: {0}" -f $WorkspaceRoot)
    Write-Output ("hook_installed: {0}" -f $hook.status)
    Write-Output 'hook_trust: unknown'
    Write-Output 'hook_callable: unknown'
    Write-Output ("host_version: {0}" -f $hostVersion.status)
    Write-Output 'host_version_expected: 0.144.4'
    Write-Output ("host_version_actual: {0}" -f $hostVersion.actual)
    Write-Output ("protected_policy: {0}" -f $protectedPolicy.status)
    Write-Output 'desktop_enforcement: unavailable'
    Write-Output ("canonical_report: {0}" -f $canonicalReport.status)
    Write-Output ("canonical_report_reason: {0}" -f $canonicalReport.reason)
    Write-Output ''
    Write-Output 'Warnings:'
    if ($warnings.Count -eq 0) { Write-Output '- none' } else { foreach ($warning in $warnings) { Write-Output ("- {0}" -f $warning) } }
    Write-Output ''
    Write-Output 'Errors:'
    if ($errors.Count -eq 0) { Write-Output '- none' } else { foreach ($errorItem in $errors) { Write-Output ("- {0}" -f $errorItem) } }

    switch ($status) {
        'PASS' { exit 0 }
        'WARN' { exit 1 }
        default { exit 2 }
    }
} catch {
    Write-Output 'STATUS: FAIL'
    Write-Output ("Error: {0}" -f $_.Exception.Message)
    exit 2
}
