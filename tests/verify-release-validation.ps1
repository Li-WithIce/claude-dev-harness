[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$WorkspaceRoot = '',
    [string]$UserProfileRoot = '',
    [string]$Scope = '',
    [string]$Preset = '',
    [ValidateSet('', 'tree-parent', 'tree-launcher', 'tree-child', 'streams', 'last-native-exit', 'job-owner')]
    [string]$FixtureMode = '',
    [string]$IdentityPath = '',
    [string]$MarkerPath = '',
    [string]$ProbeToken = '',
    [string]$LockPath = '',
    [string]$ReadyPath = '',
    [switch]$ParentSleeps,
    [switch]$RedirectChildStreams,
    [switch]$ViaShortLivedLauncher,
    [int]$StartupDelayMilliseconds = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$script:ReleaseValidationScriptPath = $MyInvocation.MyCommand.Path

function Write-SmokeTrace {
    param([string]$Line)

    [System.IO.File]::AppendAllText(
        $env:DEV_HARNESS_SMOKE_TRACE,
        $Line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Invoke-ReleaseValidationFixture {
    param([string]$Role)

    switch ($Role) {
        'tree-child' {
            Start-Sleep -Seconds 5
            [System.IO.File]::WriteAllText($MarkerPath, $ProbeToken, [System.Text.UTF8Encoding]::new($false))
            Start-Sleep -Seconds 2
            return 0
        }
        'tree-launcher' {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = (Get-Process -Id $PID).Path
            $startInfo.WorkingDirectory = [System.IO.Path]::GetTempPath()
            $startInfo.UseShellExecute = $false
            if ($RedirectChildStreams) {
                $startInfo.RedirectStandardInput = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
            }
            foreach ($argument in @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:ReleaseValidationScriptPath,
                '-FixtureMode', 'tree-child', '-MarkerPath', $MarkerPath, '-ProbeToken', $ProbeToken
            )) {
                [void]$startInfo.ArgumentList.Add([string]$argument)
            }
            $child = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $identity = '{0}|{1}|{2}|{3}' -f $child.Id,$child.StartTime.ToUniversalTime().Ticks,$ProbeToken,$startInfo.RedirectStandardOutput
                [System.IO.File]::WriteAllText($IdentityPath, $identity, [System.Text.UTF8Encoding]::new($false))
            } finally {
                $child.Dispose()
            }
            return 0
        }
        'tree-parent' {
            if ($StartupDelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $StartupDelayMilliseconds
            }

            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = (Get-Process -Id $PID).Path
            $startInfo.WorkingDirectory = [System.IO.Path]::GetTempPath()
            $startInfo.UseShellExecute = $false
            if ($RedirectChildStreams) {
                $startInfo.RedirectStandardInput = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
            }
            $nextRole = if ($ViaShortLivedLauncher) { 'tree-launcher' } else { 'tree-child' }
            $childArguments = @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:ReleaseValidationScriptPath,
                '-FixtureMode', $nextRole, '-MarkerPath', $MarkerPath, '-ProbeToken', $ProbeToken
            )
            if ($ViaShortLivedLauncher) { $childArguments += @('-IdentityPath',$IdentityPath) }
            if ($RedirectChildStreams) { $childArguments += '-RedirectChildStreams' }
            foreach ($argument in $childArguments) {
                [void]$startInfo.ArgumentList.Add([string]$argument)
            }

            $child = [System.Diagnostics.Process]::Start($startInfo)
            try {
                if (-not $ViaShortLivedLauncher) {
                    $identity = '{0}|{1}|{2}|{3}' -f $child.Id,$child.StartTime.ToUniversalTime().Ticks,$ProbeToken,$startInfo.RedirectStandardOutput
                    [System.IO.File]::WriteAllText($IdentityPath, $identity, [System.Text.UTF8Encoding]::new($false))
                }
            } finally {
                $child.Dispose()
            }

            if ($ViaShortLivedLauncher) {
                $identityTimer = [Diagnostics.Stopwatch]::StartNew()
                while (-not (Test-Path -LiteralPath $IdentityPath -PathType Leaf) -and $identityTimer.ElapsedMilliseconds -lt 5000) {
                    Start-Sleep -Milliseconds 10
                }
                if (-not (Test-Path -LiteralPath $IdentityPath -PathType Leaf)) { throw 'short-lived launcher did not publish worker identity' }
            }

            if ($ParentSleeps) {
                Start-Sleep -Seconds 5
            }
            return 0
        }
        'streams' {
            [Console]::Out.WriteLine('OUT-SENTINEL')
            [Console]::Error.WriteLine('ERR-SENTINEL')
            return 23
        }
        'last-native-exit' {
            & $env:ComSpec /d /c exit 29
            return
        }
        'job-owner' {
            . (Join-Path $RepoRoot 'scripts\lib\Harness.ValidationProcess.ps1')
            $parentArguments = @(
                '-NoLogo','-NoProfile','-NonInteractive','-File',$script:ReleaseValidationScriptPath,
                '-FixtureMode','tree-parent','-IdentityPath',$IdentityPath,'-MarkerPath',$MarkerPath,
                '-ProbeToken',$ProbeToken,'-ParentSleeps','-ViaShortLivedLauncher'
            )
            $result = Invoke-QuietProcess -Name 'owner-abort-target' -FilePath (Get-Process -Id $PID).Path -ArgumentList $parentArguments -WorkingDirectory ([IO.Path]::GetTempPath()) -TimeoutSeconds 30
            return $result.ExitCode
        }
        'install' {
            if ([string]::IsNullOrWhiteSpace($Preset)) {
                Write-SmokeTrace ('update|{0}|{1}|{2}|{3}' -f $WorkspaceRoot,$env:USERPROFILE,$RepoRoot,$Preset)
                return [int]$env:DEV_HARNESS_SMOKE_UPDATE_EXIT
            }
            Write-SmokeTrace ('install|{0}|{1}|{2}|{3}' -f $WorkspaceRoot,$env:USERPROFILE,$RepoRoot,$Preset)
            return [int]$env:DEV_HARNESS_SMOKE_INSTALL_EXIT
        }
        'verify' {
            $isSecondVerify = (Test-Path -LiteralPath $env:DEV_HARNESS_SMOKE_TRACE -PathType Leaf) -and
                [System.IO.File]::ReadAllText($env:DEV_HARNESS_SMOKE_TRACE).Contains('verify|')
            if ($isSecondVerify) {
                Write-SmokeTrace ('second-verify|{0}|{1}|{2}|{3}|{4}' -f $WorkspaceRoot,$env:USERPROFILE,$UserProfileRoot,$RepoRoot,$Scope)
                return [int]$env:DEV_HARNESS_SMOKE_SECOND_VERIFY_EXIT
            }
            Write-SmokeTrace ('verify|{0}|{1}|{2}|{3}|{4}' -f $WorkspaceRoot,$env:USERPROFILE,$UserProfileRoot,$RepoRoot,$Scope)
            return [int]$env:DEV_HARNESS_SMOKE_VERIFY_EXIT
        }
        'hold-lock' {
            $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            try {
                [System.IO.File]::WriteAllText($ReadyPath, 'ready', [System.Text.UTF8Encoding]::new($false))
                Start-Sleep -Seconds 5
            } finally {
                $stream.Dispose()
            }
            return 0
        }
        'uninstall' {
            Write-SmokeTrace ('uninstall|{0}|{1}|{2}' -f $WorkspaceRoot,$env:USERPROFILE,$RepoRoot)
            if ($env:DEV_HARNESS_SMOKE_CLEANUP_LOCK -eq '1') {
                $lockFile = Join-Path $WorkspaceRoot 'cleanup-lock.txt'
                [System.IO.File]::WriteAllText($lockFile, 'locked', [System.Text.UTF8Encoding]::new($false))
                $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = (Get-Process -Id $PID).Path
                $startInfo.UseShellExecute = $false
                $startInfo.RedirectStandardInput = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                foreach ($argument in @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'hold-cleanup-lock.ps1'),
                    '-LockPath', $lockFile, '-ReadyPath', $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH
                )) {
                    [void]$startInfo.ArgumentList.Add([string]$argument)
                }
                $holder = [System.Diagnostics.Process]::Start($startInfo)
                try {
                    [System.IO.File]::WriteAllText($env:DEV_HARNESS_SMOKE_HOLDER_PID_PATH, [string]$holder.Id, [System.Text.UTF8Encoding]::new($false))
                } finally {
                    $holder.Dispose()
                }
                $readyTimer = [System.Diagnostics.Stopwatch]::StartNew()
                while (-not (Test-Path -LiteralPath $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH) -and $readyTimer.ElapsedMilliseconds -lt 5000) {
                    Start-Sleep -Milliseconds 25
                }
                if (-not (Test-Path -LiteralPath $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH)) {
                    throw 'cleanup holder did not become ready'
                }
            }
            return [int]$env:DEV_HARNESS_SMOKE_UNINSTALL_EXIT
        }
        default {
            throw "Unknown release validation fixture role: $Role"
        }
    }
}

$fixtureRole = $FixtureMode
if ([string]::IsNullOrWhiteSpace($fixtureRole) -and $env:DEV_HARNESS_RELEASE_VALIDATION_FIXTURE -eq '1') {
    $fixtureRole = switch ([System.IO.Path]::GetFileName($script:ReleaseValidationScriptPath)) {
        'install.ps1' { 'install' }
        'verify-installation.ps1' { 'verify' }
        'uninstall.ps1' { 'uninstall' }
        'hold-cleanup-lock.ps1' { 'hold-lock' }
        default { '' }
    }
}
if ($fixtureRole -ceq 'last-native-exit') {
    Invoke-ReleaseValidationFixture -Role $fixtureRole
    return
}
if (-not [string]::IsNullOrWhiteSpace($fixtureRole)) {
    exit (Invoke-ReleaseValidationFixture -Role $fixtureRole)
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$failures = @()
$checks = @()

function Add-Check { param([string]$Message) $script:checks += $Message }
function Add-Failure { param([string]$Message) $script:failures += $Message }
function Get-WorkflowJobBlock {
    param([string]$Text,[string]$JobId)
    $pattern = '(?ms)^  {0}:[ \t]*\r?$.*?(?=^  [A-Za-z0-9_-]+:[ \t]*\r?$|\z)' -f [regex]::Escape($JobId)
    $matches = [regex]::Matches($Text,$pattern)
    return [pscustomobject]@{ Count=$matches.Count; Value=$(if($matches.Count -eq 1){$matches[0].Value}else{''}) }
}

function Get-ExactValidationScratchNames {
    return @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'dev-harness-validation-*' -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '^dev-harness-validation-[0-9a-f]{32}$' } |
        Select-Object -ExpandProperty Name)
}

function Invoke-ValidationTreeProbe {
    param(
        [string]$Name,
        [bool]$ParentSleeps,
        [bool]$DetachedChild,
        [bool]$ViaShortLivedLauncher = $false,
        [bool]$ExpectedTimeout,
        [int]$ExpectedExitCode,
        [int]$StartupDelayMilliseconds = 0,
        [int]$ProbeTimeoutSeconds = 5
    )

    $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dev-harness-validation-tree-{0}-{1}' -f $Name,[guid]::NewGuid().ToString('N'))
    $identityPath = Join-Path $probeRoot 'child.identity'
    $markerPath = Join-Path $probeRoot 'child.marker'
    $probeToken = [guid]::NewGuid().ToString('N')
    $childId = $null
    $childStartTicks = $null
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null

    try {
        $powerShellPath = (Get-Process -Id $PID).Path
        $parentArguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:ReleaseValidationScriptPath,
            '-FixtureMode', 'tree-parent', '-IdentityPath', $identityPath, '-MarkerPath', $markerPath,
            '-ProbeToken', $probeToken, '-StartupDelayMilliseconds', [string]$StartupDelayMilliseconds
        )
        if ($ParentSleeps) {
            $parentArguments += '-ParentSleeps'
        }
        if ($DetachedChild) {
            $parentArguments += '-RedirectChildStreams'
        }
        if ($ViaShortLivedLauncher) {
            $parentArguments += '-ViaShortLivedLauncher'
        }
        $result = Invoke-QuietProcess -Name $Name -FilePath $powerShellPath -ArgumentList $parentArguments -WorkingDirectory $probeRoot -TimeoutSeconds $ProbeTimeoutSeconds

        if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
            throw "fixture identity not ready before timeout: $Name"
        }
        $identity = @([System.IO.File]::ReadAllText($identityPath, [System.Text.Encoding]::UTF8) -split '\|', 4)
        if ($identity.Count -ne 4) {
            throw "fixture identity malformed for $Name`: expected 4 fields"
        }
        if ($identity[2] -cne $probeToken) {
            throw "fixture identity malformed for $Name`: token mismatch"
        }
        $expectedRedirectedStreams = if ($DetachedChild) { 'True' } else { 'False' }
        if ($identity[3] -cne $expectedRedirectedStreams) {
            throw "fixture identity malformed for $Name`: mode mismatch"
        }
        [int]$parsedChildId = 0
        [long]$parsedChildStartTicks = 0
        if (-not [int]::TryParse([string]$identity[0], [ref]$parsedChildId) -or
            -not [long]::TryParse([string]$identity[1], [ref]$parsedChildStartTicks) -or
            $parsedChildId -le 0 -or $parsedChildStartTicks -le 0) {
            throw "fixture identity malformed for $Name`: PID/StartTime must be positive integers"
        }
        $childId = $parsedChildId
        $childStartTicks = $parsedChildStartTicks
        $graceTimer = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            $childProcess = Get-Process -Id $childId -ErrorAction SilentlyContinue
            $childStillMatches = $false
            if ($null -ne $childProcess) {
                try {
                    $childStillMatches = $childProcess.StartTime.ToUniversalTime().Ticks -eq $childStartTicks
                } catch [System.InvalidOperationException] {
                    $childStillMatches = $false
                } finally {
                    $childProcess.Dispose()
                }
            }
            if (-not $childStillMatches) { break }
            Start-Sleep -Milliseconds 25
        } while ($graceTimer.ElapsedMilliseconds -lt 1000)
        $markerExists = Test-Path -LiteralPath $markerPath -PathType Leaf

        if ($result.TimedOut -eq $ExpectedTimeout -and
            $result.ExitCode -eq $ExpectedExitCode -and
            -not $childStillMatches -and
            -not $markerExists) {
            Add-Check ("validation process tree probe {0} preserves exit semantics and leaves no child" -f $Name)
        } else {
            Add-Failure ("validation process tree probe {0} failed: timed_out={1}, exit={2}, child_alive={3}, marker={4}" -f $Name,$result.TimedOut,$result.ExitCode,$childStillMatches,$markerExists)
        }
    } catch {
        Add-Failure ("validation process tree probe {0} threw: {1}" -f $Name,$_.Exception.Message)
    } finally {
        if ($null -ne $childId -and $null -ne $childStartTicks) {
            $childProcess = Get-Process -Id $childId -ErrorAction SilentlyContinue
            try {
                $cleanupIdentityMatches = $false
                if ($null -ne $childProcess) {
                    try {
                        $cleanupIdentityMatches = $childProcess.StartTime.ToUniversalTime().Ticks -eq $childStartTicks
                    } catch [System.InvalidOperationException] {
                        $cleanupIdentityMatches = $false
                    }
                }
                if ($cleanupIdentityMatches) {
                    $childProcess.Kill($true)
                    if (-not $childProcess.WaitForExit(5000)) {
                        Add-Failure ("validation process tree probe {0} cleanup timed out" -f $Name)
                    }
                }
            } catch {
                Add-Failure ("validation process tree probe {0} cleanup failed: {1}" -f $Name,$_.Exception.Message)
            } finally {
                if ($null -ne $childProcess) { $childProcess.Dispose() }
            }
        }
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $probeRoot) {
            Add-Failure ("validation process tree probe {0} left scratch residue" -f $Name)
        }
    }
}

function Invoke-ValidationOwnerAbortProbe {
    $probeRoot = Join-Path ([IO.Path]::GetTempPath()) ('dev-harness-validation-owner-abort-{0}' -f [guid]::NewGuid().ToString('N'))
    $identityPath = Join-Path $probeRoot 'worker.identity'
    $markerPath = Join-Path $probeRoot 'worker.marker'
    $probeToken = [guid]::NewGuid().ToString('N')
    $workerId = $null
    $workerStartTicks = $null
    $owner = $null
    $scratchBefore = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($scratchName in (Get-ExactValidationScratchNames)) { [void]$scratchBefore.Add($scratchName) }
    [void][IO.Directory]::CreateDirectory($probeRoot)
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.WorkingDirectory = $RepoRoot
        $startInfo.UseShellExecute = $false
        foreach ($argument in @(
            '-NoLogo','-NoProfile','-NonInteractive','-File',$script:ReleaseValidationScriptPath,
            '-FixtureMode','job-owner','-RepoRoot',$RepoRoot,'-IdentityPath',$identityPath,
            '-MarkerPath',$markerPath,'-ProbeToken',$probeToken
        )) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        $owner = [Diagnostics.Process]::Start($startInfo)
        $identityTimer = [Diagnostics.Stopwatch]::StartNew()
        $identityPublished = $false
        [int]$parsedWorkerId = 0
        [long]$parsedWorkerStartTicks = 0
        do {
            if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
                try {
                    $candidate = @([IO.File]::ReadAllText($identityPath,[Text.Encoding]::UTF8) -split '\|',4)
                    [int]$candidateWorkerId = 0
                    [long]$candidateWorkerStartTicks = 0
                    [bool]$candidateRedirect = $false
                    if ($candidate.Count -eq 4 -and $candidate[2] -ceq $probeToken -and
                        [int]::TryParse($candidate[0],[ref]$candidateWorkerId) -and
                        [long]::TryParse($candidate[1],[ref]$candidateWorkerStartTicks) -and
                        [bool]::TryParse($candidate[3],[ref]$candidateRedirect)) {
                        $parsedWorkerId = $candidateWorkerId
                        $parsedWorkerStartTicks = $candidateWorkerStartTicks
                        $identityPublished = $true
                        break
                    }
                } catch [IO.IOException] {
                    # The writer publishes atomically enough for a bounded retry, but may still hold the file briefly.
                } catch [UnauthorizedAccessException] {
                    # Treat a transient sharing/ACL read failure like an incomplete publication within the same deadline.
                }
            }
            if ($owner.WaitForExit(0)) { break }
            Start-Sleep -Milliseconds 10
        } while ($identityTimer.ElapsedMilliseconds -lt 10000)
        if (-not $identityPublished) { throw 'owner-abort worker identity was not published completely' }
        $workerId = $parsedWorkerId
        $workerStartTicks = $parsedWorkerStartTicks
        $owner.Kill()
        if (-not $owner.WaitForExit(5000)) { throw 'owner-abort root did not exit' }
        $grace = [Diagnostics.Stopwatch]::StartNew()
        do {
            $worker = Get-Process -Id $workerId -ErrorAction SilentlyContinue
            $workerAlive = $false
            if ($null -ne $worker) {
                try { $workerAlive = $worker.StartTime.ToUniversalTime().Ticks -eq $workerStartTicks }
                catch [InvalidOperationException] { $workerAlive = $false }
                finally { $worker.Dispose() }
            }
            if (-not $workerAlive) { break }
            Start-Sleep -Milliseconds 10
        } while ($grace.ElapsedMilliseconds -lt 1000)
        $newScratch = @(Get-ExactValidationScratchNames | Where-Object { -not $scratchBefore.Contains($_) })
        if (-not $workerAlive -and -not (Test-Path -LiteralPath $markerPath) -and $newScratch.Count -eq 0) {
            Add-Check 'validation Job Object kill-on-close removes a disconnected worker and owned scratch when the runner is force-stopped'
        } else {
            Add-Failure ("validation owner abort left worker={0} marker={1} new_scratch={2}" -f $workerAlive,(Test-Path -LiteralPath $markerPath),$newScratch.Count)
        }
    } catch {
        Add-Failure ("validation owner abort probe failed: {0}" -f $_.Exception.Message)
    } finally {
        if ($null -ne $owner) {
            try {
                if (-not $owner.WaitForExit(0)) { $owner.Kill($true); [void]$owner.WaitForExit(5000) }
            } catch {}
            $owner.Dispose()
        }
        if ($null -ne $workerId -and $null -ne $workerStartTicks) {
            $worker = Get-Process -Id $workerId -ErrorAction SilentlyContinue
            if ($null -ne $worker) {
                try {
                    if ($worker.StartTime.ToUniversalTime().Ticks -eq $workerStartTicks) {
                        $worker.Kill($true)
                        [void]$worker.WaitForExit(5000)
                    }
                } catch {} finally { $worker.Dispose() }
            }
        }
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$runnerPath = Join-Path $RepoRoot 'scripts\run-validation.ps1'
$validationProcessPath = Join-Path $RepoRoot 'scripts\lib\Harness.ValidationProcess.ps1'
$validationJobPath = Join-Path $RepoRoot 'scripts\lib\Harness.ValidationJob.cs'
$validationSupervisorPath = Join-Path $RepoRoot 'scripts\invoke-validation-check.ps1'
$smokeRunnerPath = Join-Path $RepoRoot 'scripts\run-isolated-install-smoke.ps1'
$runnerBoundaryPath = Join-Path $RepoRoot 'scripts\assert-release-runner-boundary.ps1'
$workflowPath = Join-Path $RepoRoot '.github\workflows\validation.yml'
$inventoryPath = Join-Path $RepoRoot 'scripts\get-repo-inventory.ps1'
$readmePath = Join-Path $RepoRoot 'README.md'

function Invoke-ValidationSupervisorProbe {
    param([Parameter(Mandatory)][string]$RequestPath)

    $process = $null
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Process -Id $PID -ErrorAction Stop).Path
        $startInfo.WorkingDirectory = $RepoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @(
            '-NoLogo','-NoProfile','-NonInteractive','-File',$validationSupervisorPath,'-RequestPath',$RequestPath
        )) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw 'validation supervisor boundary probe timed out'
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask,$stderrTask),5000)) {
            throw 'validation supervisor boundary probe streams did not close'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

$runner = Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
$runnerTokens = $null
$runnerParseErrors = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseInput($runner, [ref]$runnerTokens, [ref]$runnerParseErrors)
$validationProcess = Get-Content -LiteralPath $validationProcessPath -Raw -Encoding utf8
$validationProcessTokens = $null
$validationProcessParseErrors = $null
$validationProcessAst = [System.Management.Automation.Language.Parser]::ParseInput($validationProcess, [ref]$validationProcessTokens, [ref]$validationProcessParseErrors)
$validationJob = Get-Content -LiteralPath $validationJobPath -Raw -Encoding utf8
$validationSupervisor = Get-Content -LiteralPath $validationSupervisorPath -Raw -Encoding utf8
$validationSupervisorTokens = $null
$validationSupervisorParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($validationSupervisor,[ref]$validationSupervisorTokens,[ref]$validationSupervisorParseErrors)
$runnerBoundary = Get-Content -LiteralPath $runnerBoundaryPath -Raw -Encoding utf8
$runnerBoundaryTokens = $null
$runnerBoundaryParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($runnerBoundary,[ref]$runnerBoundaryTokens,[ref]$runnerBoundaryParseErrors)
$runnerBoundaryBytes = [IO.File]::ReadAllBytes($runnerBoundaryPath)
$quietProcessFunction = $validationProcessAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-QuietProcess'
}, $true)
$quietProcessSource = if ($null -eq $quietProcessFunction) { '' } else { $quietProcessFunction.Extent.Text }
$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding utf8
$rolloutGenerator = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\generate-v2-rollout-report.ps1') -Raw -Encoding utf8
$prCoreChecksBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'pr-core-checks'
$prCoreBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'pr-core'
$changedOptionalBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'changed-optional'
$releaseModelBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-model'
$releaseHostBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-host'
$releaseBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-full'
$prCoreChecksJob = $prCoreChecksBlock.Value
$prCoreJob = $prCoreBlock.Value
$changedOptionalJob = $changedOptionalBlock.Value
$releaseModelJob = $releaseModelBlock.Value
$releaseHostJob = $releaseHostBlock.Value
$releaseJob = $releaseBlock.Value
$producerRunnerPattern = '(?ms)^\s*runs-on:\s*\r?\n\s*-\s*self-hosted\s*\r?\n\s*-\s*Windows\s*\r?\n\s*-\s*\$\{\{\s*vars\.THIN_V2_RELEASE_RUNNER\s*\}\}\s*$'
$aggregatorRunnerPattern = '(?ms)^\s*runs-on:\s*\r?\n\s*-\s*self-hosted\s*\r?\n\s*-\s*Windows\s*\r?\n\s*-\s*\$\{\{\s*vars\.THIN_V2_RELEASE_AGGREGATOR_RUNNER\s*\}\}\s*$'
$modelUpload = [regex]::Match($releaseModelJob,'(?ms)^      - name: Upload model evidence\s*$.*\z').Value
$hostUpload = [regex]::Match($releaseHostJob,'(?ms)^      - name: Upload host evidence\s*$.*\z').Value
$releaseUpload = [regex]::Match($releaseJob,'(?ms)^      - name: Upload rollout evidence\s*$.*\z').Value

if ($runnerBoundaryParseErrors.Count -eq 0 -and $runnerBoundaryBytes.Length -ge 3 -and
    $runnerBoundaryBytes[0] -eq 0xEF -and $runnerBoundaryBytes[1] -eq 0xBB -and $runnerBoundaryBytes[2] -eq 0xBF) {
    Add-Check 'release runner account boundary script parses and has a UTF-8 BOM'
} else {
    Add-Failure 'release runner account boundary script must parse and have a UTF-8 BOM'
}

if ($runnerParseErrors.Count -eq 0 -and
    $validationProcessParseErrors.Count -eq 0 -and
    $validationSupervisorParseErrors.Count -eq 0 -and
    $runner -match "lib\\Harness\.ValidationProcess\.ps1" -and
    $runner -match '\$PSVersionTable\.PSVersion\.Major -eq 5' -and
    $runner -match 'Get-Command pwsh -CommandType Application' -and
    $runner -match "InvocationKind = 'PowerShellScript'" -and
    $runner -match 'PowerShellParameters = \$Parameters' -and
    $runner -match 'Invoke-QuietProcess.+-PowerShellParameters \$check\.PowerShellParameters' -and
    $validationProcess -match 'Add-Type -Path \$script:ValidationJobInteropPath' -and
    $validationProcess -match 'harness-validation-check/v1' -and
    $validationProcess -match 'FileMode\]::CreateNew' -and
    $quietProcessSource -match '\.ArgumentList\.Add' -and
    $quietProcessSource -match '(?s)ReadLineAsync\(\).*\$job\.Assign\(\$process\).*WriteLine\(\(''GO:' -and
    $quietProcessSource -match '\[math\]::Min\(10000,\$remainingForHandshake\)' -and
    $quietProcessSource -match 'TerminateAndWait\(124,\$remainingCleanupMilliseconds\)' -and
    $quietProcessSource -match 'ElapsedMilliseconds \+ 5000' -and
    $quietProcessSource -match 'WaitForExit\(\$remainingCleanupMilliseconds\)' -and
    $quietProcessSource -match '\.Wait\(\$remainingCleanupMilliseconds\)' -and
    $quietProcessSource -match 'WhenAll' -and
    $quietProcessSource -match '\$job\.Dispose\(\)' -and
    $quietProcessSource -match '\$primaryError = \$_' -and
    $quietProcessSource -match 'terminate/wait validation job:' -and
    $quietProcessSource -match 'drain validation output:' -and
    $validationJob -match 'JobObjectLimitKillOnJobClose' -and
    $validationJob -match 'AssignProcessToJobObject' -and
    $validationJob -match 'TerminateJobObject' -and
    $validationJob -match 'QueryInformationJobObject' -and
    $validationJob -match 'WaitForSingleObject' -and
    $validationJob -match 'ActiveProcessCount == 0' -and
    $validationSupervisor -match '(?s)\[Console\]::OutputEncoding\s*=\s*\[Text\.UTF8Encoding\]::new\(\$false\).*\$request\s*=\s*Read-ValidationRequest' -and
    $validationSupervisor -match 'JsonDocument\]::Parse' -and
    $validationSupervisor -match 'dev-harness-validation-' -and
    $validationSupervisor -match '\$token -cne \$pathToken' -and
    $validationSupervisor -match 'if \(\$requestOwned\)' -and
    $validationSupervisor -match 'Directory\]::Delete\(\$scratchDirectory\.FullName,\$false\)' -and
    $validationSupervisor -match 'StringComparer\]::OrdinalIgnoreCase' -and
    $validationSupervisor -match '(?s)Delete\(\$resolved\).*READY:' -and
    $validationSupervisor -match '& \$request\.TargetPath @targetParameters' -and
    ($runner + $validationProcess + $validationSupervisor) -notmatch 'EncodedCommand|Invoke-Expression|ExecutionPolicy|CreateNoWindow|WindowStyle' -and
    $validationProcess -notmatch 'Add-Type\s+-TypeDefinition' -and
    $quietProcessSource -notmatch 'WaitForExit\(\s*\)' -and
    $quietProcessSource -notmatch '\.HasExited' -and
    $quietProcessSource -notmatch '\.Result\b') {
    Add-Check 'validation runner assigns a ready supervisor to a kill-on-close Job Object before GO and confirms active-process zero'
} else {
    Add-Failure 'validation runner Job Object containment, handshake, or bounded cleanup contract is incomplete'
}

$unownedRoot = Join-Path ([IO.Path]::GetTempPath()) ('dev-harness-validation-unowned-{0}' -f [guid]::NewGuid().ToString('N'))
$unownedRequestPath = Join-Path $unownedRoot 'sentinel.json'
[void][IO.Directory]::CreateDirectory($unownedRoot)
try {
    [IO.File]::WriteAllText($unownedRequestPath,'not-json',[Text.UTF8Encoding]::new($false))
    $unownedResult = Invoke-ValidationSupervisorProbe -RequestPath $unownedRequestPath
    if ($unownedResult.ExitCode -ne 0 -and
        [IO.File]::Exists($unownedRequestPath) -and
        $unownedResult.StdOut -notmatch '(?m)^READY:') {
        Add-Check 'validation supervisor rejects an unowned request path without deleting the caller file'
    } else {
        Add-Failure 'validation supervisor should reject an unowned request path without deleting it or becoming ready'
    }
} catch {
    Add-Failure ("validation supervisor unowned-path probe failed: {0}" -f $_.Exception.Message)
} finally {
    Remove-Item -LiteralPath $unownedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($null -eq $quietProcessFunction) {
    Add-Failure 'validation runner Invoke-QuietProcess function is missing'
} else {
    . $validationProcessPath
    $timeoutProbeSeconds = 4
    Invoke-ValidationTreeProbe -Name 'timeout-inherited' -ParentSleeps $true -DetachedChild $false -ExpectedTimeout $true -ExpectedExitCode 124 -StartupDelayMilliseconds 1500 -ProbeTimeoutSeconds $timeoutProbeSeconds
    Invoke-ValidationTreeProbe -Name 'exit0-inherited' -ParentSleeps $false -DetachedChild $false -ExpectedTimeout $false -ExpectedExitCode 0
    Invoke-ValidationTreeProbe -Name 'exit0-isolated-streams' -ParentSleeps $false -DetachedChild $true -ExpectedTimeout $false -ExpectedExitCode 0
    Invoke-ValidationTreeProbe -Name 'exit0-short-launcher' -ParentSleeps $false -DetachedChild $false -ViaShortLivedLauncher $true -ExpectedTimeout $false -ExpectedExitCode 0
    Invoke-ValidationTreeProbe -Name 'timeout-short-launcher' -ParentSleeps $true -DetachedChild $false -ViaShortLivedLauncher $true -ExpectedTimeout $true -ExpectedExitCode 124 -ProbeTimeoutSeconds $timeoutProbeSeconds
    Invoke-ValidationOwnerAbortProbe

    $streamResult = Invoke-QuietProcess -Name 'nonzero-streams' -FilePath $script:ReleaseValidationScriptPath -PowerShellParameters ([ordered]@{ FixtureMode = 'streams' }) -WorkingDirectory $RepoRoot -TimeoutSeconds 5 -InvocationKind PowerShellScript
    if ($streamResult.ExitCode -eq 23 -and
        -not $streamResult.TimedOut -and
        $streamResult.StdOut.Trim() -ceq 'OUT-SENTINEL' -and
        $streamResult.StdErr.Trim() -ceq 'ERR-SENTINEL' -and
        $streamResult.DurationSeconds -ge 0) {
        Add-Check 'validation runner preserves nonzero exit and both output streams'
    } else {
        Add-Failure 'validation runner should preserve nonzero exit, stdout, stderr, and duration'
    }
    $nativeTailResult = Invoke-QuietProcess -Name 'last-native-exit' -FilePath $script:ReleaseValidationScriptPath -PowerShellParameters ([ordered]@{ FixtureMode = 'last-native-exit' }) -WorkingDirectory $RepoRoot -TimeoutSeconds 5 -InvocationKind PowerShellScript
    if ($nativeTailResult.ExitCode -eq 29 -and -not $nativeTailResult.TimedOut) {
        Add-Check 'validation PowerShell supervisor preserves a trailing native exit code without an encoded wrapper'
    } else {
        Add-Failure 'validation PowerShell supervisor should preserve a trailing native exit code'
    }

    $duplicateProducerRejected = $false
    $duplicateParameters = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $duplicateParameters.Add('RepoRoot',$RepoRoot)
    $duplicateParameters.Add('reporoot',$RepoRoot)
    try {
        [void](New-ValidationRequest -InvocationKind PowerShellScript -TargetPath $script:ReleaseValidationScriptPath -WorkingDirectory $RepoRoot -PowerShellParameters $duplicateParameters)
    } catch {
        $duplicateProducerRejected = $_.Exception.Message -match 'invalid or duplicated'
    }

    $duplicateToken = [guid]::NewGuid().ToString('N')
    $duplicateRoot = Join-Path ([IO.Path]::GetTempPath()) ('dev-harness-validation-{0}' -f $duplicateToken)
    $duplicateRequestPath = Join-Path $duplicateRoot 'request.json'
    [void][IO.Directory]::CreateDirectory($duplicateRoot)
    try {
        $duplicateDocument = [ordered]@{
            schema_version = 'harness-validation-check/v1'
            handshake_token = $duplicateToken
            invocation_kind = 'PowerShellScript'
            target_path = $script:ReleaseValidationScriptPath
            working_directory = $RepoRoot
            arguments = @()
            parameters = @(
                [ordered]@{ name = 'RepoRoot'; kind = 'string'; value = $RepoRoot },
                [ordered]@{ name = 'reporoot'; kind = 'string'; value = $RepoRoot }
            )
        }
        [IO.File]::WriteAllText($duplicateRequestPath,($duplicateDocument | ConvertTo-Json -Compress -Depth 5),[Text.UTF8Encoding]::new($false))
        $duplicateParserResult = Invoke-ValidationSupervisorProbe -RequestPath $duplicateRequestPath
    if ($duplicateProducerRejected -and
            $duplicateParserResult.ExitCode -ne 0 -and
            $duplicateParserResult.StdOut -notmatch '(?m)^READY:' -and
            -not [IO.File]::Exists($duplicateRequestPath)) {
            Add-Check 'validation request producer and supervisor reject case-variant PowerShell parameter duplicates before READY'
        } else {
            Add-Failure 'validation request producer and supervisor should reject case-variant PowerShell parameter duplicates before READY'
        }
    } catch {
        Add-Failure ("validation case-variant duplicate probe failed: {0}" -f $_.Exception.Message)
    } finally {
        $duplicateCleanupError = $null
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            try {
                Remove-ValidationScratch -Path $duplicateRoot
                $duplicateCleanupError = $null
                break
            } catch {
                $duplicateCleanupError = $_
                Start-Sleep -Milliseconds 25
            }
        }
        if ($null -ne $duplicateCleanupError -or [IO.Directory]::Exists($duplicateRoot)) {
            Add-Failure ("validation case-variant duplicate probe left scratch residue: {0}" -f $(
                if ($null -eq $duplicateCleanupError) { $duplicateRoot } else { $duplicateCleanupError.Exception.Message }
            ))
        }
    }

    $windowsPowerShell = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $windowsPowerShell) {
        Add-Failure 'Windows PowerShell compatibility host is unavailable'
    } else {
        $bridgeResult = Invoke-QuietProcess -Name 'windows-powershell-bridge' -FilePath $windowsPowerShell.Source -ArgumentList @(
            '-NoLogo','-NoProfile','-NonInteractive','-File',$runnerPath,
            '-Suite','quick','-RepoRoot',$RepoRoot,'-CheckTimeoutSeconds','30'
        ) -WorkingDirectory $RepoRoot -TimeoutSeconds 90 -InvocationKind Native
        if ($bridgeResult.ExitCode -eq 0 -and
            $bridgeResult.StdOut -match '(?im)^PowerShell host: .*\\pwsh\.exe\s*$' -and
            $bridgeResult.StdOut -match '(?m)^STATUS: PASS\s*$') {
            Add-Check 'Windows PowerShell validation entry transparently bridges fixed arguments to pwsh'
        } else {
            Add-Failure 'Windows PowerShell validation entry should transparently bridge fixed arguments to pwsh and pass quick validation'
        }
    }
}

if (@($prCoreChecksBlock,$prCoreBlock,$changedOptionalBlock,$releaseModelBlock,$releaseHostBlock,$releaseBlock | Where-Object Count -eq 1).Count -eq 6) {
    Add-Check 'release workflow declares each PR and release job exactly once'
} else {
    Add-Failure 'release workflow PR or release jobs are missing or duplicated'
}
$prCoreGuardPattern = '(?ms)^    steps:[ \t]*\r?\n^      - name: Require all core groups to pass[ \t]*\r?\n^        shell: pwsh[ \t]*\r?\n^        env:[ \t]*\r?\n^          CORE_CHECKS_RESULT: \$\{\{[ \t]*needs\.pr-core-checks\.result[ \t]*\}\}[ \t]*\r?\n^        run: \|[ \t]*\r?\n^          if \(\$env:CORE_CHECKS_RESULT -cne ''success''\) \{[ \t]*\r?\n^              throw "PR core checks did not succeed: \$env:CORE_CHECKS_RESULT"[ \t]*\r?\n^          \}[ \t]*\r?\n(?:^[ \t]*\r?\n)?(?=^      - name: Check out repository[ \t]*\r?$)'
$prCoreGuardIndex = $prCoreJob.IndexOf('Require all core groups to pass',[StringComparison]::Ordinal)
$prCoreCheckoutIndex = $prCoreJob.IndexOf('Check out repository',[StringComparison]::Ordinal)
$prCoreRollbackIndex = $prCoreJob.IndexOf('Core installation rollback',[StringComparison]::Ordinal)
$prCoreGuardValid = @([regex]::Matches($prCoreJob,$prCoreGuardPattern)).Count -eq 1 -and $prCoreGuardIndex -ge 0 -and $prCoreCheckoutIndex -gt $prCoreGuardIndex -and $prCoreRollbackIndex -gt $prCoreCheckoutIndex

if ($runner -match '(?m)^\s*\[int\]\$CheckTimeoutSeconds = 360\s*$' -and
    $runner -match '(?m)^\s*\[string\]\$CoreGroup = ''all''\s*,?\s*$' -and
    $runner -match [regex]::Escape("'-CoreGroup',`$CoreGroup") -and
    $runner -match [regex]::Escape("if (`$Suite -ne 'core' -and `$CoreGroup -ne 'all')") -and
    $runner -match "verify-host-benchmark-qualification\.ps1'\) \{ \[math\]::Max\(\`$CheckTimeoutSeconds,900\)" -and
    $prCoreChecksJob -match '(?m)^    timeout-minutes:\s*45\s*$' -and
    $prCoreJob -match '(?m)^    timeout-minutes:\s*45\s*$' -and
    $changedOptionalJob -match '(?m)^    timeout-minutes:\s*30\s*$' -and
    $releaseModelJob -match '(?m)^    timeout-minutes:\s*120\s*$' -and
    $releaseHostJob -match '(?m)^    timeout-minutes:\s*240\s*$' -and
    @([regex]::Matches($releaseHostJob,'(?m)^    timeout-minutes:\s*\d+\s*$')).Count -eq 1 -and
    $releaseJob -match '(?m)^    timeout-minutes:\s*120\s*$' -and
    $releaseJob -match '(?m)^\s*fetch-depth:\s*0\s*$' -and
    $prCoreChecksJob -match '(?m)^      fail-fast:\s*false\s*$' -and
    $prCoreChecksJob -match '(?m)^        run:\s+pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation\.ps1 -Suite core -CoreGroup \$\{\{ matrix\.core_group \}\} -CheckTimeoutSeconds 360\s*$' -and
    $prCoreChecksJob -notmatch '(?m)^\s{4,8}continue-on-error:' -and
    $prCoreChecksJob -notmatch 'run-isolated-install-smoke\.ps1' -and
    @([regex]::Matches($prCoreJob,'(?m)^    needs:[ \t]*pr-core-checks[ \t]*\r?$')).Count -eq 1 -and
    @([regex]::Matches($prCoreJob,'(?m)^    if:[ \t]*\$\{\{[ \t]*always\(\)[ \t]*&&[ \t]*github\.event_name[ \t]*==[ \t]*''pull_request''[ \t]*\}\}[ \t]*\r?$')).Count -eq 1 -and
    $prCoreGuardValid -and $prCoreJob -notmatch '(?m)^\s{4,8}continue-on-error:' -and
    $prCoreJob -notmatch 'run-validation\.ps1 -Suite core' -and
    $rolloutGenerator -match 'run-validation\.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput' -and
    $rolloutGenerator -match '\(\?m\)\^\\\[UNAVAILABLE\\\]\\s\+' -and
    $changedOptionalJob -match '(?m)^        run:\s+pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-changed-optional-validation\.ps1 -RepoRoot \$PWD -ChangedPathsFile changed-paths\.txt\s*$' -and
    $prCoreJob -match '(?m)^        run:\s+pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-isolated-install-smoke\.ps1 -RepoRoot \$PWD -Preset core\s*$' -and
    $rolloutGenerator -match 'run-isolated-install-smoke\.ps1 -Preset core' -and
    $rolloutGenerator -match 'run-isolated-install-smoke\.ps1 -Preset full' -and
    $workflow -notmatch 'verify-installation\.ps1' -and
    $workflow -notmatch '(?m)^\s*&\s+\.\\uninstall\.ps1' -and
    $readme -match '`pr-core-checks` 的每个 matrix leg 与最终 `pr-core` job 上限均为 45 分钟') {
    Add-Check 'CI layers shard core checks, fail closed through pr-core, and delegate rollback with bounded budgets'
} else {
    Add-Failure 'CI core sharding, fail-closed pr-core gate, bounded budgets, rollback delegation, or README contract is incomplete'
}

if ($releaseModelJob -match 'run-model-evals\.ps1[^\r\n]+-TimeoutSeconds 120[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+model-eval\.json' -and
    $releaseHostJob -match 'run-host-benchmark\.ps1[^\r\n]+-TimeoutSeconds 900[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+-Groups 3[^\r\n]+-Trials 3[^\r\n]+host-benchmark\.json' -and
    $releaseHostJob -match '(?m)^\s*needs:\s*release-model\s*$' -and
    $releaseModelJob -notmatch '(?m)^\s*continue-on-error:' -and $releaseHostJob -notmatch '(?m)^\s*continue-on-error:') {
    Add-Check 'release CI serializes and bounds real model and three-group host evidence without masking failures'
} else {
    Add-Failure 'release CI must run both real qualification reports before rollout generation'
}

if (@($releaseModelJob,$releaseHostJob | Where-Object { $_ -match $producerRunnerPattern -and $_ -match '(?m)^\s*HOST_BENCHMARK_CODEX_HOME:\s*\$\{\{\s*vars\.HOST_BENCHMARK_CODEX_HOME\s*\}\}\s*$' -and $_ -match '(?m)^\s*environment:\s*thin-v2-release\s*$' -and $_ -match '(?m)^\s*persist-credentials:\s*false\s*$' -and $_ -match 'refs/heads/codex/thin-harness-v2-refactor' -and $_ -notmatch '(?i)secrets\.' }).Count -eq 2 -and
    $releaseJob -match $aggregatorRunnerPattern -and $releaseJob -match '(?m)^\s*environment:\s*thin-v2-release\s*$' -and $releaseJob -match '(?m)^\s*persist-credentials:\s*false\s*$' -and $releaseJob -notmatch 'HOST_BENCHMARK_CODEX_HOME' -and $releaseJob -notmatch '(?i)secrets\.') {
    Add-Check 'credentialed producers and the credential-blind aggregator use separate dedicated runner labels'
} else {
    Add-Failure 'release CI must map the approved runner and Codex-home repository variables without credential transport'
}

$producerBoundaryCount = 0
foreach ($producer in @($releaseModelJob,$releaseHostJob)) {
    $boundaryIndex = $producer.IndexOf('scripts/assert-release-runner-boundary.ps1',[StringComparison]::Ordinal)
    $producerWorkIndex = $producer.IndexOf('evidence directory',[StringComparison]::Ordinal)
    if ($producer -match '(?m)^\s*runner_account_digest:\s*\$\{\{\s*steps\.runner_boundary\.outputs\.runner_account_digest\s*\}\}\s*$' -and
        $producer -match '(?ms)^\s*- name: Assert credentialed producer runner boundary\s*$\r?\n\s*id:\s*runner_boundary\s*$.*?assert-release-runner-boundary\.ps1 -Mode producer\b' -and
        $boundaryIndex -ge 0 -and $producerWorkIndex -gt $boundaryIndex) { $producerBoundaryCount++ }
}
$aggregatorBoundaryIndex = $releaseJob.IndexOf('scripts/assert-release-runner-boundary.ps1',[StringComparison]::Ordinal)
$aggregatorDownloadIndex = $releaseJob.IndexOf('actions/download-artifact@',[StringComparison]::Ordinal)
$aggregatorGenerateIndex = $releaseJob.IndexOf('scripts/generate-v2-rollout-report.ps1',[StringComparison]::Ordinal)
if ($producerBoundaryCount -eq 2 -and
    $releaseJob -match '(?m)^\s*MODEL_PRODUCER_ACCOUNT_DIGEST:\s*\$\{\{\s*needs\.release-model\.outputs\.runner_account_digest\s*\}\}\s*$' -and
    $releaseJob -match '(?m)^\s*HOST_PRODUCER_ACCOUNT_DIGEST:\s*\$\{\{\s*needs\.release-host\.outputs\.runner_account_digest\s*\}\}\s*$' -and
    $releaseJob -match 'assert-release-runner-boundary\.ps1 -Mode aggregator\b[^\r\n]+-ModelProducerAccountDigest \$env:MODEL_PRODUCER_ACCOUNT_DIGEST[^\r\n]+-HostProducerAccountDigest \$env:HOST_PRODUCER_ACCOUNT_DIGEST' -and
    $aggregatorBoundaryIndex -ge 0 -and $aggregatorDownloadIndex -gt $aggregatorBoundaryIndex -and $aggregatorGenerateIndex -gt $aggregatorBoundaryIndex) {
    Add-Check 'release producers publish account digests and the aggregator verifies both before consuming evidence'
} else {
    Add-Failure 'release account boundary must bind both producer outputs before evidence download or rollout generation'
}

$checkoutAction = 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5'
$uploadAction = 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
$downloadAction = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'

if (@([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($checkoutAction)))).Count -eq 6 -and
    @([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($uploadAction)))).Count -eq 6 -and
    @([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($downloadAction)))).Count -eq 2 -and
    $workflow -notmatch '(?m)^\s*uses:\s*actions/(?:checkout|upload-artifact|download-artifact)@v\d+') {
    Add-Check 'release workflow pins every GitHub Action dependency to a verified full commit SHA'
} else {
    Add-Failure 'release workflow must pin GitHub Action dependencies to the approved commits'
}

if ($releaseJob -match '(?ms)^\s*needs:\s*\r?\n\s*- release-model\s*\r?\n\s*- release-host' -and
    $releaseJob -match '!cancelled\(\)' -and $releaseJob -notmatch 'always\(\)' -and
    @([regex]::Matches($releaseJob,[regex]::Escape($downloadAction))).Count -eq 2 -and
    $releaseJob -match 'generate-v2-rollout-report\.ps1[^\r\n]+-ModelEvalReportPath[^\r\n]+model-eval\.json[^\r\n]+-HostBenchmarkReportPath[^\r\n]+host-benchmark\.json[^\r\n]+v2-rollout-eligibility\.json[^\r\n]+-RequireEligible' -and
    $releaseJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\aggregate' -and
    $rolloutGenerator -match 'ModelEvalReportPath' -and
    $rolloutGenerator -match 'HostBenchmarkReportPath' -and
    $rolloutGenerator -notmatch 'run-scenario-evals\.ps1 -Suite core' -and
    $rolloutGenerator -notmatch 'benchmark-harness\.ps1 -Compare bare,v1,v2') {
    Add-Check 'rollout generator consumes real evidence instead of deterministic or fixture proxies'
} else {
    Add-Failure 'rollout generator must bind real model and host reports'
}

if ($modelUpload -match [regex]::Escape($uploadAction) -and $modelUpload -match '(?m)^\s*path:\s*\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/model-eval\.json\s*$' -and $modelUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and
    $hostUpload -match [regex]::Escape($uploadAction) -and $hostUpload -match '(?m)^\s*path:\s*\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/host-benchmark\.json\s*$' -and $hostUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and
    $releaseUpload -match '!cancelled\(\)' -and
    $releaseUpload -match [regex]::Escape($uploadAction) -and
    $releaseUpload -match '(?m)^\s*if-no-files-found:\s*warn\s*$' -and
    @([regex]::Matches($releaseUpload,'(?m)^\s+\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/[a-z0-9-]+\.json\s*$')).Count -eq 3 -and
    ($modelUpload + $hostUpload + $releaseUpload) -notmatch '(?i)auth\.json|CODEX_ACCESS_TOKEN|OPENAI_API_KEY|secrets\.') {
    Add-Check 'release CI uses fresh one-file producer artifacts and limits final upload scope to three sanitized JSON paths'
} else {
    Add-Failure 'release artifact upload must be always-on, exact, and credential-free'
}

if (-not (Test-Path -LiteralPath $smokeRunnerPath -PathType Leaf)) {
    Add-Failure 'isolated install smoke runner is missing'
} else {
    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dev-harness-release-validation-{0}' -f [guid]::NewGuid().ToString('N'))
    $fixtureRepo = Join-Path $fixtureRoot 'repo'
    $tracePath = Join-Path $fixtureRoot 'trace.log'
    $originalTrace = $env:DEV_HARNESS_SMOKE_TRACE
    $originalInstallExit = $env:DEV_HARNESS_SMOKE_INSTALL_EXIT
    $originalVerifyExit = $env:DEV_HARNESS_SMOKE_VERIFY_EXIT
    $originalUpdateExit = $env:DEV_HARNESS_SMOKE_UPDATE_EXIT
    $originalSecondVerifyExit = $env:DEV_HARNESS_SMOKE_SECOND_VERIFY_EXIT
    $originalUninstallExit = $env:DEV_HARNESS_SMOKE_UNINSTALL_EXIT
    $originalCleanupLock = $env:DEV_HARNESS_SMOKE_CLEANUP_LOCK
    $originalHolderPidPath = $env:DEV_HARNESS_SMOKE_HOLDER_PID_PATH
    $originalHolderReadyPath = $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH
    $originalFixtureMode = $env:DEV_HARNESS_RELEASE_VALIDATION_FIXTURE
    $holderPidPath = Join-Path $fixtureRoot 'cleanup-holder.pid'
    $holderReadyPath = Join-Path $fixtureRoot 'cleanup-holder.ready'

    try {
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'tests') -Force | Out-Null
        foreach ($relativePath in @('install.ps1', 'tests\verify-installation.ps1', 'hold-cleanup-lock.ps1', 'uninstall.ps1')) {
            Copy-Item -LiteralPath $script:ReleaseValidationScriptPath -Destination (Join-Path $fixtureRepo $relativePath) -Force
        }
        $env:DEV_HARNESS_RELEASE_VALIDATION_FIXTURE = '1'

        $cases = @(
            [pscustomobject]@{ Name = 'success'; Install = 0; Verify = 0; Update = 0; SecondVerify = 0; Uninstall = 0; Cleanup = 0; CleanupLock = $false; Expected = 0; Sequence = @('install','verify','update','second-verify','uninstall') },
            [pscustomobject]@{ Name = 'verify-failure'; Install = 0; Verify = 21; Update = 0; SecondVerify = 0; Uninstall = 0; Cleanup = 0; CleanupLock = $false; Expected = 21; Sequence = @('install','verify','uninstall') },
            [pscustomobject]@{ Name = 'update-failure'; Install = 0; Verify = 0; Update = 23; SecondVerify = 0; Uninstall = 0; Cleanup = 0; CleanupLock = $false; Expected = 23; Sequence = @('install','verify','update','uninstall') },
            [pscustomobject]@{ Name = 'second-verify-failure'; Install = 0; Verify = 0; Update = 0; SecondVerify = 24; Uninstall = 0; Cleanup = 0; CleanupLock = $false; Expected = 24; Sequence = @('install','verify','update','second-verify','uninstall') },
            [pscustomobject]@{ Name = 'uninstall-failure'; Install = 0; Verify = 0; Update = 0; SecondVerify = 0; Uninstall = 22; Cleanup = 0; CleanupLock = $false; Expected = 22; Sequence = @('install','verify','update','second-verify','uninstall') },
            [pscustomobject]@{ Name = 'install-failure'; Install = 20; Verify = 0; Update = 0; SecondVerify = 0; Uninstall = 0; Cleanup = 0; CleanupLock = $false; Expected = 20; Sequence = @('install') },
            [pscustomobject]@{ Name = 'verify-and-uninstall-failure'; Install = 0; Verify = 21; Update = 0; SecondVerify = 0; Uninstall = 22; Cleanup = 0; CleanupLock = $false; Expected = 21; Sequence = @('install','verify','uninstall') },
            [pscustomobject]@{ Name = 'cleanup-failure'; Install = 0; Verify = 0; Update = 0; SecondVerify = 0; Uninstall = 0; Cleanup = 1; CleanupLock = $true; Expected = 1; Sequence = @('install','verify','update','second-verify','uninstall') },
            [pscustomobject]@{ Name = 'second-verify-uninstall-cleanup-failure'; Install = 0; Verify = 0; Update = 0; SecondVerify = 24; Uninstall = 22; Cleanup = 1; CleanupLock = $true; Expected = 24; Sequence = @('install','verify','update','second-verify','uninstall') }
        )

        foreach ($case in $cases) {
            Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $holderPidPath,$holderReadyPath -Force -ErrorAction SilentlyContinue
            $env:DEV_HARNESS_SMOKE_TRACE = $tracePath
            $env:DEV_HARNESS_SMOKE_INSTALL_EXIT = [string]$case.Install
            $env:DEV_HARNESS_SMOKE_VERIFY_EXIT = [string]$case.Verify
            $env:DEV_HARNESS_SMOKE_UPDATE_EXIT = [string]$case.Update
            $env:DEV_HARNESS_SMOKE_SECOND_VERIFY_EXIT = [string]$case.SecondVerify
            $env:DEV_HARNESS_SMOKE_UNINSTALL_EXIT = [string]$case.Uninstall
            $env:DEV_HARNESS_SMOKE_CLEANUP_LOCK = if ($case.CleanupLock) { '1' } else { '0' }
            $env:DEV_HARNESS_SMOKE_HOLDER_PID_PATH = $holderPidPath
            $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH = $holderReadyPath
            $runnerScratchRoot = $null
            $fixtureCleanupFailure = $null

            try {
                $caseOutput = @(& (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $smokeRunnerPath -RepoRoot $fixtureRepo 2>&1 | ForEach-Object { [string]$_ })
                $caseExit = $LASTEXITCODE
                $traceLines = @(Get-Content -LiteralPath $tracePath -Encoding utf8 -ErrorAction SilentlyContinue)
                $actualSequence = @($traceLines | ForEach-Object { ($_ -split '\|', 2)[0] })
                $installFields = if ($traceLines.Count -gt 0) { @($traceLines[0] -split '\|') } else { @() }
                if ($installFields.Count -ge 2) {
                    $runnerScratchRoot = Split-Path -Parent $installFields[1]
                }
                $pathsWereRemoved = $installFields.Count -ge 3 -and
                    -not (Test-Path -LiteralPath $installFields[1]) -and
                    -not (Test-Path -LiteralPath $installFields[2])
                $cleanupStateWasCorrect = if ($case.Cleanup -eq 0) { $pathsWereRemoved } else { -not $pathsWereRemoved }
                $argumentsWereCorrect = $installFields.Count -eq 5 -and $installFields[4] -eq 'full'
                $updateFields = @($traceLines | Where-Object { $_ -like 'update|*' } | Select-Object -First 1) -split '\|'
                if ($updateFields.Count -gt 1) {
                    $argumentsWereCorrect = $argumentsWereCorrect -and $updateFields.Count -eq 5 -and
                        [string]::IsNullOrWhiteSpace($updateFields[4])
                }
                $verifyFields = @($traceLines | Where-Object { $_ -like 'verify|*' } | Select-Object -First 1) -split '\|'
                if ($verifyFields.Count -gt 1) {
                    $argumentsWereCorrect = $argumentsWereCorrect -and $verifyFields.Count -eq 6 -and
                        $verifyFields[2] -eq $verifyFields[3] -and $verifyFields[5] -eq 'All'
                }
                $secondVerifyFields = @($traceLines | Where-Object { $_ -like 'second-verify|*' } | Select-Object -First 1) -split '\|'
                if ($secondVerifyFields.Count -gt 1) {
                    $argumentsWereCorrect = $argumentsWereCorrect -and $secondVerifyFields.Count -eq 6 -and
                        $secondVerifyFields[2] -eq $secondVerifyFields[3] -and $secondVerifyFields[5] -eq 'All'
                }
                $failedStageOutputWasPreserved = $true
                $stageExits = [ordered]@{
                    install = [int]$case.Install
                    verify = [int]$case.Verify
                    update = [int]$case.Update
                    second_verify = [int]$case.SecondVerify
                    uninstall = [int]$case.Uninstall
                    cleanup = [int]$case.Cleanup
                }
                foreach ($stage in $stageExits.GetEnumerator()) {
                    if ($stage.Value -ne 0 -and ($caseOutput -join "`n") -notmatch ('(?m)^- {0}_exit: {1}$' -f $stage.Key,$stage.Value)) {
                        $failedStageOutputWasPreserved = $false
                    }
                }

                if ($caseExit -eq $case.Expected -and
                    ($actualSequence -join ',') -eq ($case.Sequence -join ',') -and
                    $cleanupStateWasCorrect -and $argumentsWereCorrect -and $failedStageOutputWasPreserved -and
                    ($caseOutput -join "`n") -match ('(?m)^- cleanup_exit: {0}$' -f $case.Cleanup)) {
                    Add-Check ("isolated smoke case {0} preserves order, exit priority, arguments, and cleanup" -f $case.Name)
                } else {
                    Add-Failure ("isolated smoke case {0} failed: exit={1}, expected={2}, sequence={3}, cleanup_state={4}, arguments={5}, output={6}" -f $case.Name,$caseExit,$case.Expected,($actualSequence -join ','),$cleanupStateWasCorrect,$argumentsWereCorrect,($caseOutput -join ' | '))
                }
            } finally {
                if (Test-Path -LiteralPath $holderPidPath -PathType Leaf) {
                    try {
                        $holderId = [int](Get-Content -LiteralPath $holderPidPath -Raw -Encoding utf8)
                        $holderProcess = Get-Process -Id $holderId -ErrorAction SilentlyContinue
                        if ($null -ne $holderProcess) {
                            Stop-Process -InputObject $holderProcess -Force -ErrorAction Stop
                            if (-not $holderProcess.WaitForExit(5000)) {
                                throw "cleanup holder process $holderId did not exit"
                            }
                        }
                    } catch {
                        $fixtureCleanupFailure = $_.Exception.Message
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($runnerScratchRoot) -and (Test-Path -LiteralPath $runnerScratchRoot)) {
                    try {
                        Remove-Item -LiteralPath $runnerScratchRoot -Recurse -Force -ErrorAction Stop
                    } catch {
                        $fixtureCleanupFailure = $_.Exception.Message
                    }
                }
                Remove-Item -LiteralPath $holderPidPath,$holderReadyPath -Force -ErrorAction SilentlyContinue
            }
            if (-not [string]::IsNullOrWhiteSpace($fixtureCleanupFailure) -or
                (-not [string]::IsNullOrWhiteSpace($runnerScratchRoot) -and (Test-Path -LiteralPath $runnerScratchRoot))) {
                Add-Failure ("isolated smoke case {0} did not release its cleanup holder and scratch root: {1}" -f $case.Name,$fixtureCleanupFailure)
            }
        }
    } finally {
        $env:DEV_HARNESS_SMOKE_TRACE = $originalTrace
        $env:DEV_HARNESS_SMOKE_INSTALL_EXIT = $originalInstallExit
        $env:DEV_HARNESS_SMOKE_VERIFY_EXIT = $originalVerifyExit
        $env:DEV_HARNESS_SMOKE_UPDATE_EXIT = $originalUpdateExit
        $env:DEV_HARNESS_SMOKE_SECOND_VERIFY_EXIT = $originalSecondVerifyExit
        $env:DEV_HARNESS_SMOKE_UNINSTALL_EXIT = $originalUninstallExit
        $env:DEV_HARNESS_SMOKE_CLEANUP_LOCK = $originalCleanupLock
        $env:DEV_HARNESS_SMOKE_HOLDER_PID_PATH = $originalHolderPidPath
        $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH = $originalHolderReadyPath
        $env:DEV_HARNESS_RELEASE_VALIDATION_FIXTURE = $originalFixtureMode
        if (Test-Path -LiteralPath $holderPidPath -PathType Leaf) {
            $holderId = [int](Get-Content -LiteralPath $holderPidPath -Raw -Encoding utf8)
            $holderProcess = Get-Process -Id $holderId -ErrorAction SilentlyContinue
            if ($null -ne $holderProcess) {
                Stop-Process -InputObject $holderProcess -Force -ErrorAction Stop
                if (-not $holderProcess.WaitForExit(5000)) {
                    throw "cleanup holder process $holderId did not exit"
                }
            }
        }
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction Stop
    }
}

if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
    Add-Failure 'repository inventory script is missing'
} else {
    $inventoryOutput = @(& $inventoryPath -RepoRoot $RepoRoot 2>&1)
    $inventorySucceeded = $?
    if ($inventorySucceeded -and ($inventoryOutput -join "`n") -match 'verify_scripts:') {
        Add-Check 'repository inventory is generated from the current filesystem'
    } else {
        Add-Failure 'repository inventory script should run and report verify_scripts'
    }
}

if ($readme -match 'get-repo-inventory\.ps1' -and $readme -notmatch 'skills/` 下有 `\d+`' -and $readme -notmatch 'scripts/` 下有 `\d+`' -and $readme -notmatch 'tests/` 下有 `\d+`') {
    Add-Check 'README delegates mutable component counts to generated inventory'
} else {
    Add-Failure 'README should delegate mutable component counts to generated inventory'
}

Write-Output 'Checks:'
if ($checks.Count -eq 0) { Write-Output '- none' } else { $checks | ForEach-Object { Write-Output ('- {0}' -f $_) } }
Write-Output ''
Write-Output 'Failures:'
if ($failures.Count -eq 0) { Write-Output '- none'; exit 0 }
$failures | ForEach-Object { Write-Output ('- {0}' -f $_) }
exit 1
