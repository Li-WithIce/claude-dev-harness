[CmdletBinding()]
param(
    [ValidateSet('quick', 'core', 'all')]
    [string]$Suite = 'quick',

    [string]$RepoRoot = '',

    [string]$WorkspaceRoot = '',

    [switch]$IncludeCachedDiff,

    [switch]$VerboseOutput,

    [ValidateRange(30, 900)]
    [int]$CheckTimeoutSeconds = 360
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        return (Resolve-Path -LiteralPath $RequestedRoot).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Resolve-Executable {
    param(
        [string[]]$Candidates,
        [string]$Purpose
    )

    foreach ($candidate in $Candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
            return $command.Source
        }
    }

    throw ("Unable to locate executable for {0}: {1}" -f $Purpose, ($Candidates -join ', '))
}

function Quote-PowerShellLiteral {
    param([string]$Value)

    return "'" + ($Value -replace "'", "''") + "'"
}

function New-PowerShellEncodedArguments {
    param(
        [string]$ScriptPath,
        [string[]]$ScriptArguments = @()
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    $tokens.Add('&')
    $tokens.Add((Quote-PowerShellLiteral -Value $ScriptPath))

    foreach ($argument in $ScriptArguments) {
        if ($argument.StartsWith('-')) {
            $tokens.Add($argument)
        } else {
            $tokens.Add((Quote-PowerShellLiteral -Value $argument))
        }
    }

    $command = @"
`$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new(`$false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)
`$OutputEncoding = [Console]::OutputEncoding
$($tokens -join ' ')
`$lastExitCodeVariable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
if (`$null -ne `$lastExitCodeVariable -and `$lastExitCodeVariable.Value -is [int]) { exit `$lastExitCodeVariable.Value }
exit 0
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
}

function Invoke-QuietProcess {
    param(
        [string]$Name,
        [string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $timedOut = $false
    $exitCode = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdout = ''
    $stderr = ''
    $primaryError = $null
    $cleanupErrors = [System.Collections.Generic.List[string]]::new()

    try {
        [void]$process.Start()
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $timedOut) {
            $exitCode = $process.ExitCode
        }
    } catch {
        $primaryError = $_
    } finally {
        if ($started) {
            $cleanupDeadlineMilliseconds = $timer.ElapsedMilliseconds + 5000
            try {
                $process.Kill($true)
            } catch {
                $cleanupErrors.Add(('kill tree: ' + $_.Exception.Message))
            }
            try {
                $remainingCleanupMilliseconds = [math]::Max(0, [int]($cleanupDeadlineMilliseconds - $timer.ElapsedMilliseconds))
                if (-not $process.WaitForExit($remainingCleanupMilliseconds)) {
                    throw 'root process did not exit within cleanup grace'
                }
            } catch {
                $cleanupErrors.Add(('wait root: ' + $_.Exception.Message))
            }
            try {
                $streamTasks = @($stdoutTask,$stderrTask | Where-Object { $null -ne $_ })
                if ($streamTasks.Count -gt 0) {
                    $drainTask = [System.Threading.Tasks.Task]::WhenAll([System.Threading.Tasks.Task[]]$streamTasks)
                    $remainingCleanupMilliseconds = [math]::Max(0, [int]($cleanupDeadlineMilliseconds - $timer.ElapsedMilliseconds))
                    if (-not $drainTask.Wait($remainingCleanupMilliseconds)) {
                        throw 'stdout/stderr did not close within cleanup grace'
                    }
                    if ($null -ne $stdoutTask) { $stdout = $stdoutTask.GetAwaiter().GetResult() }
                    if ($null -ne $stderrTask) { $stderr = $stderrTask.GetAwaiter().GetResult() }
                }
            } catch {
                $cleanupErrors.Add(('drain output: ' + $_.Exception.Message))
            }
        }
        try {
            $process.Dispose()
        } catch {
            $cleanupErrors.Add(('dispose process: ' + $_.Exception.Message))
        }
        $timer.Stop()
    }

    if ($cleanupErrors.Count -gt 0) {
        $primaryMessage = if ($null -ne $primaryError) {
            $primaryError.Exception.Message
        } elseif ($timedOut) {
            "Validation check '$Name' timed out after $TimeoutSeconds seconds."
        } else {
            "Validation check '$Name' exited with code $exitCode but cleanup failed."
        }
        throw [System.InvalidOperationException]::new(($primaryMessage + ' Cleanup failures: ' + ($cleanupErrors -join '; ')), $(if ($null -ne $primaryError) { $primaryError.Exception } else { $null }))
    }
    if ($null -ne $primaryError) {
        throw $primaryError
    }

    return [pscustomobject]@{
        Name = $Name
        ExitCode = $(if ($timedOut) { 124 } else { $exitCode })
        StdOut = $stdout
        StdErr = $stderr
        DurationSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)
        TimedOut = $timedOut
    }
}

function Add-GitCheck {
    param(
        [System.Collections.Generic.List[object]]$Checks,
        [string]$Name,
        [string]$Arguments
    )

    $Checks.Add([pscustomobject]@{
        Name = $Name
        FilePath = $script:GitPath
        Arguments = $Arguments
    }) | Out-Null
}

function Add-PowerShellScriptCheck {
    param(
        [System.Collections.Generic.List[object]]$Checks,
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $Checks.Add([pscustomobject]@{
        Name = $Name
        FilePath = $script:PowerShellPath
        Arguments = (New-PowerShellEncodedArguments -ScriptPath $ScriptPath -ScriptArguments $Arguments)
    }) | Out-Null
}

$repoRootResolved = Resolve-RepoRoot -RequestedRoot $RepoRoot
$testsRoot = Join-Path $repoRootResolved 'tests'
$script:GitPath = Resolve-Executable -Candidates @('git.exe', 'git') -Purpose 'git checks'
$script:PowerShellPath = Resolve-Executable -Candidates @('pwsh.exe', 'pwsh', 'powershell.exe', 'powershell') -Purpose 'PowerShell validation'
$checks = New-Object System.Collections.Generic.List[object]
$skips = New-Object System.Collections.Generic.List[string]

Add-GitCheck -Checks $checks -Name 'git diff --check' -Arguments 'diff --check'
if ($IncludeCachedDiff) {
    Add-GitCheck -Checks $checks -Name 'git diff --cached --check' -Arguments 'diff --cached --check'
}

$coreScripts = @(
    'verify-adversarial-review-gate.ps1',
    'verify-ask-codex.ps1',
    'verify-codex-entry-autoload.ps1',
    'verify-code-intel-provider-boundary.ps1',
    'verify-context-provider-boundary.ps1',
    'verify-context-provider-install-isolation.ps1',
    'verify-entry-routing-clarification.ps1',
    'verify-v2-entry-contract.ps1',
    'verify-v2-direct-no-artifacts.ps1',
    'verify-v2-requirement-gate.ps1',
    'verify-v2-task-state.ps1',
    'verify-v2-evidence.ps1',
    'verify-v2-governed-audit.ps1',
    'verify-v2-readonly-zero-write.ps1',
    'verify-harness-entry.ps1',
    'verify-lite-artifact-validator.ps1',
    'verify-lite-footprint.ps1',
    'verify-memory-provider-boundary.ps1',
    'verify-minimal-safe-change-policy.ps1',
    'verify-md-html-review-renderer.ps1',
    'verify-no-node-install-dependency.ps1',
    'verify-placeholder-rendering.ps1',
    'verify-provider-usage-recording.ps1',
    'verify-workflow-contracts.ps1',
    'verify-workflow-descriptor.ps1',
    'verify-shared-memory-layers.ps1',
    'verify-stage-discipline-matrix.ps1',
    'verify-render-review-html.ps1',
    'verify-release-validation.ps1',
    'verify-runtime-state-contract.ps1',
    'verify-skill-manifest.ps1',
    'verify-task-artifact-drift-audit.ps1',
    'verify-aiteamcode-skill-contract.ps1',
    'verify-tool-profile.ps1'
)

if ($Suite -eq 'quick') {
    $scriptNames = @('verify-lite-footprint.ps1')
} elseif ($Suite -eq 'core') {
    $scriptNames = $coreScripts
} else {
    $scriptNames = Get-ChildItem -LiteralPath $testsRoot -Filter 'verify-*.ps1' -File |
        Where-Object { $_.Name -ne 'verify-installation.ps1' } |
        Sort-Object Name |
        Select-Object -ExpandProperty Name
}

foreach ($scriptName in $scriptNames) {
    $scriptPath = Join-Path $testsRoot $scriptName
    Add-PowerShellScriptCheck -Checks $checks -Name $scriptName -ScriptPath $scriptPath
}

if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $installScript = Join-Path $testsRoot 'verify-installation.ps1'
    Add-PowerShellScriptCheck -Checks $checks -Name 'verify-installation.ps1' -ScriptPath $installScript -Arguments @(
        '-WorkspaceRoot', $WorkspaceRoot,
        '-RepoRoot', $repoRootResolved
    )
} elseif ($Suite -eq 'all') {
    $skips.Add('verify-installation.ps1 requires -WorkspaceRoot and is not part of the default no-argument loop') | Out-Null
}

Write-Output ("Validation suite: {0}" -f $Suite)
Write-Output ("RepoRoot: {0}" -f $repoRootResolved)
Write-Output ("PowerShell host: {0}" -f $script:PowerShellPath)
Write-Output ''

foreach ($skip in $skips) {
    Write-Output ("[SKIP] {0}" -f $skip)
}

$failures = New-Object System.Collections.Generic.List[object]
foreach ($check in $checks) {
    Write-Output ("[RUN ] {0}" -f $check.Name)
    $result = Invoke-QuietProcess -Name $check.Name -FilePath $check.FilePath -Arguments $check.Arguments -WorkingDirectory $repoRootResolved -TimeoutSeconds $CheckTimeoutSeconds
    if ($result.ExitCode -eq 0) {
        Write-Output ("[PASS] {0} ({1}s)" -f $result.Name, $result.DurationSeconds)
        if ($VerboseOutput) {
            if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) { Write-Output $result.StdOut.TrimEnd() }
            if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) { [Console]::Error.WriteLine($result.StdErr.TrimEnd()) }
        }
    } else {
        $failures.Add($result) | Out-Null
        $failureSuffix = if ($result.TimedOut) { ", timeout {0}s" -f $CheckTimeoutSeconds } else { '' }
        Write-Output ("[FAIL] {0} ({1}s, exit {2}{3})" -f $result.Name, $result.DurationSeconds, $result.ExitCode, $failureSuffix)
        if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) {
            Write-Output '--- stdout ---'
            Write-Output $result.StdOut.TrimEnd()
        }
        if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) {
            Write-Output '--- stderr ---'
            [Console]::Error.WriteLine($result.StdErr.TrimEnd())
        }
    }
}

Write-Output ''
if ($failures.Count -gt 0) {
    Write-Output ("STATUS: FAIL ({0} failed)" -f $failures.Count)
    exit 1
}

Write-Output 'STATUS: PASS'
exit 0
