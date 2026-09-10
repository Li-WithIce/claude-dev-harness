$script:ValidationProcessLibraryRoot = $PSScriptRoot
$script:ValidationSupervisorPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\invoke-validation-check.ps1'))
$script:ValidationJobInteropPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Harness.ValidationJob.cs'))

function Initialize-ValidationJobInterop {
    if (-not $IsWindows) { throw 'Validation Job Object containment is supported on Windows only.' }
    if (-not (Test-Path -LiteralPath $script:ValidationSupervisorPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $script:ValidationJobInteropPath -PathType Leaf)) {
        throw 'Tracked validation containment components are missing.'
    }
    if (-not ('DevHarness.Validation.JobController' -as [type])) {
        Add-Type -Path $script:ValidationJobInteropPath -ErrorAction Stop
    }
}

function Remove-ValidationScratch {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Validation scratch cleanup escaped the system temp root.'
    }
    if (-not [IO.Directory]::Exists($resolved)) { return }
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Validation scratch cleanup refused a reparse directory.'
    }
    [IO.Directory]::Delete($resolved,$true)
}

function New-ValidationRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('Native','PowerShellScript')][string]$InvocationKind,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string[]]$ArgumentList = @(),
        [Collections.IDictionary]$PowerShellParameters = [ordered]@{}
    )

    $resolvedTarget = [IO.Path]::GetFullPath($TargetPath)
    $resolvedWorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Leaf) -or
        -not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
        throw 'Validation target or working directory does not exist.'
    }
    $token = [guid]::NewGuid().ToString('N')
    $scratchRoot = Join-Path ([IO.Path]::GetTempPath()) ('dev-harness-validation-{0}' -f $token)
    $requestPath = Join-Path $scratchRoot 'request.json'
    [void][IO.Directory]::CreateDirectory($scratchRoot)
    try {
        $parameterNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $parameterEntries = [Collections.Generic.List[object]]::new()
        foreach ($entry in $PowerShellParameters.GetEnumerator()) {
            $name = [string]$entry.Key
            if ([string]::IsNullOrWhiteSpace($name) -or $name -cnotmatch '^[A-Za-z][A-Za-z0-9]*$' -or -not $parameterNames.Add($name)) {
                throw 'Validation PowerShell parameter name is invalid or duplicated.'
            }
            $value = $entry.Value
            if ($value -is [bool] -or $value -is [switch]) {
                $kind = 'switch'
                $serializedValue = [bool]$value
            } elseif ($value -is [array]) {
                $kind = 'string_array'
                $serializedValue = @($value | ForEach-Object { [string]$_ })
            } else {
                $kind = 'string'
                $serializedValue = [string]$value
            }
            [void]$parameterEntries.Add([ordered]@{ name = $name; kind = $kind; value = $serializedValue })
        }
        if (($InvocationKind -ceq 'Native' -and $parameterEntries.Count -ne 0) -or
            ($InvocationKind -ceq 'PowerShellScript' -and @($ArgumentList).Count -ne 0)) {
            throw 'Validation request mixed native arguments with PowerShell parameters.'
        }
        $document = [ordered]@{
            schema_version = 'harness-validation-check/v1'
            handshake_token = $token
            invocation_kind = $InvocationKind
            target_path = $resolvedTarget
            working_directory = $resolvedWorkingDirectory
            arguments = @($ArgumentList | ForEach-Object { [string]$_ })
            parameters = $parameterEntries.ToArray()
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($document | ConvertTo-Json -Compress -Depth 5))
        $stream = [IO.FileStream]::new($requestPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $stream.Write($bytes,0,$bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        return [pscustomobject]@{ Root = $scratchRoot; Path = $requestPath; Token = $token }
    } catch {
        Remove-ValidationScratch -Path $scratchRoot
        throw
    }
}

function Invoke-QuietProcess {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds,
        [ValidateSet('Native','PowerShellScript')]
        [string]$InvocationKind = 'Native',
        [Collections.IDictionary]$PowerShellParameters = [ordered]@{}
    )

    Initialize-ValidationJobInterop
    $request = New-ValidationRequest -InvocationKind $InvocationKind -TargetPath $FilePath -WorkingDirectory $WorkingDirectory -ArgumentList $ArgumentList -PowerShellParameters $PowerShellParameters
    $job = $null
    $process = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $jobAssigned = $false
    $timedOut = $false
    $exitCode = $null
    $readyTask = $null
    $readyLine = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdout = ''
    $stderr = ''
    $primaryError = $null
    $cleanupErrors = [Collections.Generic.List[string]]::new()

    try {
        $job = [DevHarness.Validation.JobController]::new()
        $powerShellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powerShellPath
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        foreach ($argument in @(
            '-NoLogo','-NoProfile','-NonInteractive','-File',$script:ValidationSupervisorPath,
            '-RequestPath',$request.Path
        )) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Validation supervisor did not start.' }
        $started = $true
        $readyTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $remainingForHandshake = [math]::Max(1,[int](($TimeoutSeconds * 1000) - $timer.ElapsedMilliseconds))
        $handshakeBudget = [math]::Min(10000,$remainingForHandshake)
        if (-not $readyTask.Wait($handshakeBudget)) {
            throw "Validation supervisor for '$Name' did not become ready within ${handshakeBudget}ms."
        }
        $readyLine = $readyTask.GetAwaiter().GetResult()
        if ($readyLine -cne ('READY:{0}' -f $request.Token)) {
            throw "Validation supervisor for '$Name' returned an invalid readiness signal."
        }

        $job.Assign($process)
        $jobAssigned = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $process.StandardInput.WriteLine(('GO:{0}' -f $request.Token))
        $process.StandardInput.Flush()
        $process.StandardInput.Close()

        $remainingRunMilliseconds = [math]::Max(0,[int](($TimeoutSeconds * 1000) - $timer.ElapsedMilliseconds))
        $timedOut = $remainingRunMilliseconds -eq 0 -or -not $process.WaitForExit($remainingRunMilliseconds)
        if (-not $timedOut) { $exitCode = $process.ExitCode }
    } catch {
        $primaryError = $_
    } finally {
        $cleanupDeadlineMilliseconds = $timer.ElapsedMilliseconds + 5000
        if ($started) {
            try { $process.StandardInput.Close() } catch { $cleanupErrors.Add(('close supervisor input: ' + $_.Exception.Message)) }
        }
        if ($null -ne $job) {
            if ($jobAssigned) {
                try {
                    $remainingCleanupMilliseconds = [math]::Max(0,[int]($cleanupDeadlineMilliseconds - $timer.ElapsedMilliseconds))
                    if (-not $job.TerminateAndWait(124,$remainingCleanupMilliseconds)) {
                        throw 'validation Job Object did not reach active-process zero within cleanup grace'
                    }
                } catch { $cleanupErrors.Add(('terminate/wait validation job: ' + $_.Exception.Message)) }
            } elseif ($started) {
                try {
                    if (-not $process.WaitForExit(0)) {
                        $process.Kill($true)
                        $remainingCleanupMilliseconds = [math]::Max(0,[int]($cleanupDeadlineMilliseconds - $timer.ElapsedMilliseconds))
                        if (-not $process.WaitForExit($remainingCleanupMilliseconds)) {
                            throw 'unassigned validation supervisor did not exit within cleanup grace'
                        }
                    }
                } catch { $cleanupErrors.Add(('stop unassigned supervisor: ' + $_.Exception.Message)) }
            }
            try { $job.Dispose() } catch { $cleanupErrors.Add(('close validation job: ' + $_.Exception.Message)) }
        }
        if ($started) {
            try {
                $remainingCleanupMilliseconds = [math]::Max(0,[int]($cleanupDeadlineMilliseconds - $timer.ElapsedMilliseconds))
                if (-not $process.WaitForExit($remainingCleanupMilliseconds)) {
                    throw 'validation supervisor did not exit within cleanup grace'
                }
            } catch { $cleanupErrors.Add(('wait supervisor: ' + $_.Exception.Message)) }

            if ($null -eq $stdoutTask -and $null -ne $readyTask) {
                try {
                    $remainingCleanupMilliseconds = [math]::Max(0,[int]($cleanupDeadlineMilliseconds - $timer.ElapsedMilliseconds))
                    if (-not $readyTask.Wait($remainingCleanupMilliseconds)) { throw 'readiness stream did not close within cleanup grace' }
                    if ($null -eq $readyLine) { $readyLine = $readyTask.GetAwaiter().GetResult() }
                    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                } catch { $cleanupErrors.Add(('complete readiness stream: ' + $_.Exception.Message)) }
            }
            try {
                $streamTasks = @($stdoutTask,$stderrTask | Where-Object { $null -ne $_ })
                if ($streamTasks.Count -gt 0) {
                    $drainTask = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]$streamTasks)
                    $remainingCleanupMilliseconds = [math]::Max(0,[int]($cleanupDeadlineMilliseconds - $timer.ElapsedMilliseconds))
                    if (-not $drainTask.Wait($remainingCleanupMilliseconds)) {
                        throw 'validation stdout/stderr did not close within cleanup grace'
                    }
                    if ($null -ne $stdoutTask) { $stdout = $stdoutTask.GetAwaiter().GetResult() }
                    if ($null -ne $stderrTask) { $stderr = $stderrTask.GetAwaiter().GetResult() }
                }
            } catch { $cleanupErrors.Add(('drain validation output: ' + $_.Exception.Message)) }
        }
        if ($null -ne $process) {
            try { $process.Dispose() } catch { $cleanupErrors.Add(('dispose supervisor: ' + $_.Exception.Message)) }
        }
        try { Remove-ValidationScratch -Path $request.Root } catch { $cleanupErrors.Add(('remove validation scratch: ' + $_.Exception.Message)) }
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
        throw [InvalidOperationException]::new(
            ($primaryMessage + ' Cleanup failures: ' + ($cleanupErrors -join '; ')),
            $(if ($null -ne $primaryError) { $primaryError.Exception } else { $null })
        )
    }
    if ($null -ne $primaryError) { throw $primaryError }

    return [pscustomobject]@{
        Name = $Name
        ExitCode = $(if ($timedOut) { 124 } else { $exitCode })
        StdOut = $stdout
        StdErr = $stderr
        DurationSeconds = [math]::Round($timer.Elapsed.TotalSeconds,2)
        TimedOut = $timedOut
    }
}
