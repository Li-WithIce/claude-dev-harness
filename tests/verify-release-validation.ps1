[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$failures = @()
$checks = @()

function Add-Check { param([string]$Message) $script:checks += $Message }
function Add-Failure { param([string]$Message) $script:failures += $Message }

function Invoke-ValidationTreeProbe {
    param(
        [string]$Name,
        [bool]$ParentSleeps,
        [bool]$DetachedChild,
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
        $markerLiteral = "'" + $markerPath.Replace("'", "''") + "'"
        $tokenLiteral = "'" + $probeToken.Replace("'", "''") + "'"
        $childCommand = @(
            'Start-Sleep -Seconds 5',
            ('[System.IO.File]::WriteAllText({0}, {1}, [System.Text.UTF8Encoding]::new($false))' -f $markerLiteral,$tokenLiteral),
            'Start-Sleep -Seconds 2'
        ) -join [Environment]::NewLine
        $childEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
        $powerShellLiteral = "'" + $powerShellPath.Replace("'", "''") + "'"
        $identityLiteral = "'" + $identityPath.Replace("'", "''") + "'"
        $useShellExecuteLiteral = if ($DetachedChild) { '$true' } else { '$false' }
        $createNoWindowLiteral = if ($DetachedChild) { '$false' } else { '$true' }
        $parentLines = @()
        if ($StartupDelayMilliseconds -gt 0) {
            $parentLines += ('Start-Sleep -Milliseconds {0}' -f $StartupDelayMilliseconds)
        }
        $parentLines += @(
            '$psi = [System.Diagnostics.ProcessStartInfo]::new()',
            ('$psi.FileName = ' + $powerShellLiteral),
            '$psi.WorkingDirectory = [System.IO.Path]::GetTempPath()',
            ('$psi.Arguments = ' + ("'-NoProfile -NonInteractive -EncodedCommand {0}'" -f $childEncoded)),
            ('$psi.UseShellExecute = ' + $useShellExecuteLiteral),
            ('$psi.CreateNoWindow = ' + $createNoWindowLiteral)
        )
        if ($DetachedChild) {
            $parentLines += '$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden'
        }
        $parentLines += @(
            '$child = [System.Diagnostics.Process]::Start($psi)',
            ('$identity = [string]$child.Id + ''|'' + [string]$child.StartTime.ToUniversalTime().Ticks + ''|'' + {0} + ''|'' + [string]$psi.UseShellExecute + ''|'' + [string]$psi.CreateNoWindow' -f $tokenLiteral),
            ('[System.IO.File]::WriteAllText({0}, $identity, [System.Text.UTF8Encoding]::new($false))' -f $identityLiteral)
        )
        if ($ParentSleeps) {
            $parentLines += 'Start-Sleep -Seconds 5'
        }
        $parentEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($parentLines -join [Environment]::NewLine)))
        $result = Invoke-QuietProcess -Name $Name -FilePath $powerShellPath -Arguments "-NoProfile -NonInteractive -EncodedCommand $parentEncoded" -WorkingDirectory $probeRoot -TimeoutSeconds $ProbeTimeoutSeconds

        if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
            throw "fixture identity not ready before timeout: $Name"
        }
        $identity = @([System.IO.File]::ReadAllText($identityPath, [System.Text.Encoding]::UTF8) -split '\|', 5)
        if ($identity.Count -ne 5) {
            throw "fixture identity malformed for $Name`: expected 5 fields"
        }
        if ($identity[2] -cne $probeToken) {
            throw "fixture identity malformed for $Name`: token mismatch"
        }
        $expectedUseShellExecute = if ($DetachedChild) { 'True' } else { 'False' }
        $expectedCreateNoWindow = if ($DetachedChild) { 'False' } else { 'True' }
        if ($identity[3] -cne $expectedUseShellExecute -or $identity[4] -cne $expectedCreateNoWindow) {
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

$runnerPath = Join-Path $RepoRoot 'scripts\run-validation.ps1'
$smokeRunnerPath = Join-Path $RepoRoot 'scripts\run-isolated-install-smoke.ps1'
$workflowPath = Join-Path $RepoRoot '.github\workflows\validation.yml'
$inventoryPath = Join-Path $RepoRoot 'scripts\get-repo-inventory.ps1'
$readmePath = Join-Path $RepoRoot 'README.md'
$runner = Get-Content -LiteralPath $runnerPath -Raw -Encoding utf8
$runnerTokens = $null
$runnerParseErrors = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseInput($runner, [ref]$runnerTokens, [ref]$runnerParseErrors)
$quietProcessFunction = $runnerAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-QuietProcess'
}, $true)
$quietProcessSource = if ($null -eq $quietProcessFunction) { '' } else { $quietProcessFunction.Extent.Text }
$ownerTry = if ($null -eq $quietProcessFunction) { $null } else {
    $quietProcessFunction.Body.Find({
        param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst] -and
            $null -ne $node.Finally -and
            $node.Body.Extent.Text -match '\$process\.Start\(\)'
    }, $true)
}
$ownerFinallySource = if ($null -eq $ownerTry) { '' } else { $ownerTry.Finally.Extent.Text }
$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding utf8
$rolloutGenerator = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\generate-v2-rollout-report.ps1') -Raw -Encoding utf8

if ($runnerParseErrors.Count -eq 0 -and
    $quietProcessSource -match 'WaitForExit\(\$TimeoutSeconds \* 1000\)' -and
    $ownerFinallySource -match 'Kill\(\$true\)' -and
    $ownerFinallySource -match 'ElapsedMilliseconds \+ 5000' -and
    $ownerFinallySource -match 'WaitForExit\(\$remainingCleanupMilliseconds\)' -and
    $ownerFinallySource -match '\.Wait\(\$remainingCleanupMilliseconds\)' -and
    $ownerFinallySource -match 'WhenAll' -and
    $ownerFinallySource -match '\.Dispose\(\)' -and
    $quietProcessSource -match '\$primaryError = \$_' -and
    $quietProcessSource -match 'kill tree:' -and
    $quietProcessSource -match 'wait root:' -and
    $quietProcessSource -match 'drain output:' -and
    $quietProcessSource -match 'dispose process:' -and
    $quietProcessSource -notmatch 'WaitForExit\(\s*\)' -and
    $quietProcessSource -notmatch '\.HasExited' -and
    $ownerFinallySource -notmatch 'DateTime\]::UtcNow' -and
    $quietProcessSource -notmatch '\.Result\b') {
    Add-Check 'validation runner owns the process tree with bounded cleanup and disposal'
} else {
    Add-Failure 'validation runner should tree-kill, bounded-wait, drain, and dispose every check'
}

if ($null -eq $quietProcessFunction) {
    Add-Failure 'validation runner Invoke-QuietProcess function is missing'
} else {
    Invoke-Expression $quietProcessSource
    $timeoutProbeSeconds = 4
    Invoke-ValidationTreeProbe -Name 'timeout-inherited' -ParentSleeps $true -DetachedChild $false -ExpectedTimeout $true -ExpectedExitCode 124 -StartupDelayMilliseconds 1500 -ProbeTimeoutSeconds $timeoutProbeSeconds
    Invoke-ValidationTreeProbe -Name 'exit0-inherited' -ParentSleeps $false -DetachedChild $false -ExpectedTimeout $false -ExpectedExitCode 0
    Invoke-ValidationTreeProbe -Name 'exit0-detached' -ParentSleeps $false -DetachedChild $true -ExpectedTimeout $false -ExpectedExitCode 0

    $streamCommand = 'Write-Output OUT-SENTINEL; [Console]::Error.WriteLine("ERR-SENTINEL"); exit 23'
    $streamEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($streamCommand))
    $streamResult = Invoke-QuietProcess -Name 'nonzero-streams' -FilePath (Get-Process -Id $PID).Path -Arguments "-NoProfile -NonInteractive -EncodedCommand $streamEncoded" -WorkingDirectory $RepoRoot -TimeoutSeconds 5
    if ($streamResult.ExitCode -eq 23 -and
        -not $streamResult.TimedOut -and
        $streamResult.StdOut.Trim() -ceq 'OUT-SENTINEL' -and
        $streamResult.StdErr.Trim() -ceq 'ERR-SENTINEL' -and
        $streamResult.DurationSeconds -ge 0) {
        Add-Check 'validation runner preserves nonzero exit and both output streams'
    } else {
        Add-Failure 'validation runner should preserve nonzero exit, stdout, stderr, and duration'
    }
}

if ($runner -match '(?m)^\s*\[int\]\$CheckTimeoutSeconds = 360\s*$' -and
    $workflow -match '(?m)^\s*timeout-minutes:\s*30\s*$' -and
    $workflow -match '(?m)^\s*timeout-minutes:\s*45\s*$' -and
    $workflow -match 'run-validation\.ps1 -Suite core -CheckTimeoutSeconds 360' -and
    $rolloutGenerator -match 'run-validation\.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput' -and
    $rolloutGenerator -match '\(\?m\)\^\\\[UNAVAILABLE\\\]\\s\+' -and
    $workflow -match 'run-changed-optional-validation\.ps1' -and
    $workflow -match 'run-isolated-install-smoke\.ps1 -RepoRoot \$PWD -Preset core' -and
    $workflow -match 'generate-v2-rollout-report\.ps1 -RepoRoot \$PWD' -and
    $rolloutGenerator -match 'run-isolated-install-smoke\.ps1 -Preset core' -and
    $rolloutGenerator -match 'run-isolated-install-smoke\.ps1 -Preset full' -and
    $rolloutGenerator -match 'run-scenario-evals\.ps1 -Suite core' -and
    $rolloutGenerator -match 'benchmark-harness\.ps1 -Compare bare,v1,v2' -and
    $workflow -notmatch 'verify-installation\.ps1' -and
    $workflow -notmatch '(?m)^\s*&\s+\.\\uninstall\.ps1' -and
    $readme -match 'PR job 上限为 30 分钟，release job 上限为 45 分钟，单个 verify 脚本上限为 360 秒') {
    Add-Check 'CI layers share bounded validation budgets and delegate install rollback to the smoke runner'
} else {
    Add-Failure 'CI layers, local runner, and README should share bounded budgets and delegate install rollback to the smoke runner'
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
    $originalUninstallExit = $env:DEV_HARNESS_SMOKE_UNINSTALL_EXIT
    $originalCleanupLock = $env:DEV_HARNESS_SMOKE_CLEANUP_LOCK
    $originalHolderPidPath = $env:DEV_HARNESS_SMOKE_HOLDER_PID_PATH
    $originalHolderReadyPath = $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH
    $holderPidPath = Join-Path $fixtureRoot 'cleanup-holder.pid'
    $holderReadyPath = Join-Path $fixtureRoot 'cleanup-holder.ready'

    try {
        New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'tests') -Force | Out-Null
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'install.ps1'), @'
[CmdletBinding()]
param([string]$WorkspaceRoot, [string]$RepoRoot, [string]$Preset)
$line = 'install|{0}|{1}|{2}|{3}' -f $WorkspaceRoot,$env:USERPROFILE,$RepoRoot,$Preset
[System.IO.File]::AppendAllText($env:DEV_HARNESS_SMOKE_TRACE, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
exit [int]$env:DEV_HARNESS_SMOKE_INSTALL_EXIT
'@, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'tests\verify-installation.ps1'), @'
[CmdletBinding()]
param([string]$WorkspaceRoot, [string]$RepoRoot, [string]$UserProfileRoot, [string]$Scope)
$line = 'verify|{0}|{1}|{2}|{3}|{4}' -f $WorkspaceRoot,$env:USERPROFILE,$UserProfileRoot,$RepoRoot,$Scope
[System.IO.File]::AppendAllText($env:DEV_HARNESS_SMOKE_TRACE, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
exit [int]$env:DEV_HARNESS_SMOKE_VERIFY_EXIT
'@, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'hold-cleanup-lock.ps1'), @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LockPath,
    [Parameter(Mandatory = $true)]
    [string]$ReadyPath
)
$stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    [System.IO.File]::WriteAllText($ReadyPath, 'ready', [System.Text.UTF8Encoding]::new($false))
    Start-Sleep -Seconds 5
} finally {
    $stream.Dispose()
}
'@, $utf8NoBom)
        [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'uninstall.ps1'), @'
[CmdletBinding()]
param([string]$WorkspaceRoot, [string]$RepoRoot)
$line = 'uninstall|{0}|{1}|{2}' -f $WorkspaceRoot,$env:USERPROFILE,$RepoRoot
[System.IO.File]::AppendAllText($env:DEV_HARNESS_SMOKE_TRACE, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
if ($env:DEV_HARNESS_SMOKE_CLEANUP_LOCK -eq '1') {
    $lockPath = Join-Path $WorkspaceRoot 'cleanup-lock.txt'
    [System.IO.File]::WriteAllText($lockPath, 'locked', [System.Text.UTF8Encoding]::new($false))
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Process -Id $PID).Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'hold-cleanup-lock.ps1'),'-LockPath',$lockPath,'-ReadyPath',$env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $holder = [System.Diagnostics.Process]::Start($startInfo)
    [System.IO.File]::WriteAllText($env:DEV_HARNESS_SMOKE_HOLDER_PID_PATH, [string]$holder.Id, [System.Text.UTF8Encoding]::new($false))
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
    }
    if (-not (Test-Path -LiteralPath $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH)) {
        throw 'cleanup holder did not become ready'
    }
}
exit [int]$env:DEV_HARNESS_SMOKE_UNINSTALL_EXIT
'@, $utf8NoBom)

        $cases = @(
            [pscustomobject]@{ Name = 'success'; Install = 0; Verify = 0; Uninstall = 0; Cleanup = 0; CleanupLock = $false; Expected = 0; Sequence = @('install','verify','uninstall') },
            [pscustomobject]@{ Name = 'verify-failure'; Install = 0; Verify = 21; Uninstall = 0; Cleanup = 0; CleanupLock = $false; Expected = 21; Sequence = @('install','verify','uninstall') },
            [pscustomobject]@{ Name = 'uninstall-failure'; Install = 0; Verify = 0; Uninstall = 22; Cleanup = 0; CleanupLock = $false; Expected = 22; Sequence = @('install','verify','uninstall') },
            [pscustomobject]@{ Name = 'install-failure'; Install = 20; Verify = 0; Uninstall = 0; Cleanup = 0; CleanupLock = $false; Expected = 20; Sequence = @('install') },
            [pscustomobject]@{ Name = 'verify-and-uninstall-failure'; Install = 0; Verify = 21; Uninstall = 22; Cleanup = 0; CleanupLock = $false; Expected = 21; Sequence = @('install','verify','uninstall') },
            [pscustomobject]@{ Name = 'cleanup-failure'; Install = 0; Verify = 0; Uninstall = 0; Cleanup = 1; CleanupLock = $true; Expected = 1; Sequence = @('install','verify','uninstall') },
            [pscustomobject]@{ Name = 'verify-uninstall-cleanup-failure'; Install = 0; Verify = 21; Uninstall = 22; Cleanup = 1; CleanupLock = $true; Expected = 21; Sequence = @('install','verify','uninstall') }
        )

        foreach ($case in $cases) {
            Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $holderPidPath,$holderReadyPath -Force -ErrorAction SilentlyContinue
            $env:DEV_HARNESS_SMOKE_TRACE = $tracePath
            $env:DEV_HARNESS_SMOKE_INSTALL_EXIT = [string]$case.Install
            $env:DEV_HARNESS_SMOKE_VERIFY_EXIT = [string]$case.Verify
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
                $verifyFields = @($traceLines | Where-Object { $_ -like 'verify|*' } | Select-Object -First 1) -split '\|'
                if ($verifyFields.Count -gt 1) {
                    $argumentsWereCorrect = $argumentsWereCorrect -and $verifyFields.Count -eq 6 -and
                        $verifyFields[2] -eq $verifyFields[3] -and $verifyFields[5] -eq 'All'
                }
                $failedStageOutputWasPreserved = $true
                foreach ($stage in @('install','verify','uninstall','cleanup')) {
                    $expectedStageExit = [int]$case.$(([string]$stage[0]).ToUpperInvariant() + $stage.Substring(1))
                    if ($expectedStageExit -ne 0 -and ($caseOutput -join "`n") -notmatch ('(?m)^- {0}_exit: {1}$' -f $stage,$expectedStageExit)) {
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
        $env:DEV_HARNESS_SMOKE_UNINSTALL_EXIT = $originalUninstallExit
        $env:DEV_HARNESS_SMOKE_CLEANUP_LOCK = $originalCleanupLock
        $env:DEV_HARNESS_SMOKE_HOLDER_PID_PATH = $originalHolderPidPath
        $env:DEV_HARNESS_SMOKE_HOLDER_READY_PATH = $originalHolderReadyPath
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
