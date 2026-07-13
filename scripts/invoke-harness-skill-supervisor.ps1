[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483)]
    [int]$TimeoutSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.3') {
    [Console]::Error.WriteLine('invoke-harness-skill supervisor requires PowerShell 7.3 or newer.')
    exit 1
}
if (-not (Test-Path -LiteralPath $TargetScriptPath -PathType Leaf)) {
    [Console]::Error.WriteLine("Missing adapter target wrapper: $TargetScriptPath")
    exit 1
}

$resolvedTargetPath = (Resolve-Path -LiteralPath $TargetScriptPath).Path
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if (-not $resolvedOutputPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    [Console]::Error.WriteLine('Adapter backend output path must be under the system temp directory.')
    exit 1
}
if (Test-Path -LiteralPath $resolvedOutputPath) {
    [Console]::Error.WriteLine("Adapter backend output path already exists: $resolvedOutputPath")
    exit 1
}
$powerShellPath = [Environment]::ProcessPath
if ([string]::IsNullOrWhiteSpace($powerShellPath)) {
    [Console]::Error.WriteLine('Unable to resolve the current PowerShell executable.')
    exit 1
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $powerShellPath
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
$psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
$psi.CreateNoWindow = $true
foreach ($argument in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $resolvedTargetPath)) {
    $psi.ArgumentList.Add($argument)
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $psi
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$liveDeadlineMilliseconds = [long]$TimeoutSeconds * 1000
$started = $false
$timedOut = $false
$exitCode = $null
$stdoutTask = $null
$stderrTask = $null
$stdout = ''
$stderr = ''
$backendOutputBase64 = $null
$primaryError = $null
$cleanupErrors = [System.Collections.Generic.List[string]]::new()

try {
    try {
        [void]$process.Start()
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $remainingLiveMilliseconds = [math]::Max(0, [int]($liveDeadlineMilliseconds - $timer.ElapsedMilliseconds))
        $timedOut = -not $process.WaitForExit($remainingLiveMilliseconds)
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
                $streamTasks = @($stdoutTask, $stderrTask | Where-Object { $null -ne $_ })
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

    if ($null -eq $primaryError -and -not $timedOut -and $exitCode -eq 0 -and $cleanupErrors.Count -eq 0) {
        try {
            if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf)) {
                throw 'adapter target succeeded without writing its assigned output file'
            }
            $outputItem = Get-Item -LiteralPath $resolvedOutputPath -Force
            if ($outputItem -isnot [System.IO.FileInfo] -or
                ($outputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'adapter target output must be a regular non-reparse file'
            }
            $backendOutputBase64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($resolvedOutputPath))
        } catch {
            $primaryError = $_
        }
    }
} finally {
    try {
        [System.IO.File]::Delete($resolvedOutputPath)
        if (Test-Path -LiteralPath $resolvedOutputPath) {
            throw 'backend output still exists after delete'
        }
    } catch {
        $cleanupErrors.Add(('delete backend output: ' + $_.Exception.Message))
    }
}

if ($null -ne $backendOutputBase64 -and $null -eq $primaryError -and -not $timedOut -and $exitCode -eq 0 -and $cleanupErrors.Count -eq 0) {
    [Console]::Out.WriteLine(('__DEV_HARNESS_BACKEND_OUTPUT_BASE64__=' + $backendOutputBase64))
}
if (-not [string]::IsNullOrEmpty($stdout)) {
    [Console]::Out.Write($stdout)
}
if (-not [string]::IsNullOrEmpty($stderr)) {
    [Console]::Error.Write($stderr)
}

if ($cleanupErrors.Count -gt 0) {
    $primaryMessage = if ($null -ne $primaryError) {
        $primaryError.Exception.Message
    } elseif ($timedOut) {
        "Adapter target timed out after $TimeoutSeconds seconds."
    } else {
        "Adapter target exited with code $exitCode but cleanup failed."
    }
    [Console]::Error.WriteLine(($primaryMessage + ' Cleanup failures: ' + ($cleanupErrors -join '; ')))
    if ($timedOut) { exit 124 }
    if ($null -ne $exitCode -and $exitCode -ne 0) { exit $exitCode }
    exit 1
}
if ($null -ne $primaryError) {
    [Console]::Error.WriteLine(('Adapter target failed: ' + $primaryError.Exception.Message))
    exit 1
}
if ($timedOut) {
    [Console]::Error.WriteLine("Adapter target timed out after $TimeoutSeconds seconds.")
    exit 124
}

exit $exitCode
