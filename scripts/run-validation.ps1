[CmdletBinding()]
param(
    [ValidateSet('quick', 'core', 'all')]
    [string]$Suite = 'quick',

    [ValidateSet('all', 'entry-lifecycle', 'evaluation-release', 'install-evidence', 'governance-approval', 'harness-contracts')]
    [string]$CoreGroup = 'all',

    [string]$RepoRoot = '',

    [string]$WorkspaceRoot = '',

    [switch]$IncludeCachedDiff,

    [switch]$VerboseOutput,

    [ValidateRange(30, 900)]
    [int]$CheckTimeoutSeconds = 360
)

if ($PSVersionTable.PSVersion.Major -eq 5) {
    $pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction Stop
    $bridgeArguments = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',[IO.Path]::GetFullPath($PSCommandPath),'-Suite',$Suite,'-CoreGroup',$CoreGroup,'-CheckTimeoutSeconds',[string]$CheckTimeoutSeconds)) {
        [void]$bridgeArguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        [void]$bridgeArguments.Add('-RepoRoot')
        [void]$bridgeArguments.Add($RepoRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        [void]$bridgeArguments.Add('-WorkspaceRoot')
        [void]$bridgeArguments.Add($WorkspaceRoot)
    }
    if ($IncludeCachedDiff.IsPresent) { [void]$bridgeArguments.Add('-IncludeCachedDiff') }
    if ($VerboseOutput.IsPresent) { [void]$bridgeArguments.Add('-VerboseOutput') }
    & $pwshCommand.Source @bridgeArguments
    exit $LASTEXITCODE
}
if ($PSVersionTable.PSVersion -lt [Version]'7.3') {
    throw 'Validation requires PowerShell 7.3 or newer.'
}
if (-not $IsWindows) {
    throw 'Validation Job Object containment is supported on Windows only.'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Suite -ne 'core' -and $CoreGroup -ne 'all') {
    throw "-CoreGroup '$CoreGroup' is only valid with -Suite core."
}

. (Join-Path $PSScriptRoot 'lib\Harness.ValidationProcess.ps1')

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

function Add-GitCheck {
    param(
        [System.Collections.Generic.List[object]]$Checks,
        [string]$Name,
        [string[]]$ArgumentList
    )

    $Checks.Add([pscustomobject]@{
        Name = $Name
        InvocationKind = 'Native'
        FilePath = $script:GitPath
        ArgumentList = @($ArgumentList)
        PowerShellParameters = [ordered]@{}
    }) | Out-Null
}

function Add-PowerShellScriptCheck {
    param(
        [System.Collections.Generic.List[object]]$Checks,
        [string]$Name,
        [string]$ScriptPath,
        [Collections.IDictionary]$Parameters = [ordered]@{}
    )

    $Checks.Add([pscustomobject]@{
        Name = $Name
        InvocationKind = 'PowerShellScript'
        FilePath = $ScriptPath
        ArgumentList = @()
        PowerShellParameters = $Parameters
    }) | Out-Null
}

$repoRootResolved = Resolve-RepoRoot -RequestedRoot $RepoRoot
$testsRoot = Join-Path $repoRootResolved 'tests'
$script:GitPath = Resolve-Executable -Candidates @('git.exe', 'git') -Purpose 'git checks'
$checks = New-Object System.Collections.Generic.List[object]
$skips = New-Object System.Collections.Generic.List[string]

Add-GitCheck -Checks $checks -Name 'git diff --check' -ArgumentList @('diff', '--check')
if ($IncludeCachedDiff) {
    Add-GitCheck -Checks $checks -Name 'git diff --cached --check' -ArgumentList @('diff', '--cached', '--check')
}

$coreScriptGroups = [ordered]@{
    'entry-lifecycle' = @(
        'verify-adversarial-review-gate.ps1',
        'verify-entry-routing-clarification.ps1',
        'verify-v2-entry-contract.ps1',
        'verify-v2-protocol-config.ps1',
        'verify-runtime-qualification-decoupling.ps1',
        'verify-v2-direct-no-artifacts.ps1',
        'verify-v2-requirement-gate.ps1',
        'verify-v2-json-compat.ps1',
        'verify-v2-task-state.ps1',
        'verify-v2-model-neutrality.ps1',
        'verify-v1-v2-coexistence.ps1',
        'verify-v1-to-v2-migration.ps1',
        'verify-v2-default-flip.ps1',
        'verify-v2-runtime-memory-decoupling.ps1'
    )
    'evaluation-release' = @(
        'run-scenario-evals.ps1',
        'verify-model-eval-runner.ps1',
        'verify-rollout-evidence.ps1',
        'verify-exact-head-engineering-evidence.ps1',
        'verify-v1-stop-loss-qualification.ps1',
        'verify-host-benchmark-runner.ps1',
        'verify-host-benchmark-otel.ps1',
        'verify-host-benchmark-qualification.ps1',
        'verify-release-runner-boundary.ps1',
        'verify-release-isolation-qualification.ps1',
        'verify-ordinary-ci-receipt.ps1',
        'verify-v2-ci-routing.ps1'
    )
    'install-evidence' = @(
        'verify-v2-install-presets.ps1',
        'verify-preset-lifecycle-qualification.ps1',
        'verify-v2-evidence.ps1'
    )
    'governance-approval' = @(
        'verify-v2-governed-audit.ps1',
        'verify-v2-approval.ps1',
        'verify-v2-readonly-zero-write.ps1'
    )
    'harness-contracts' = @(
        'verify-harness-entry.ps1',
        'verify-lite-artifact-validator.ps1',
        'verify-lite-footprint.ps1',
        'verify-minimal-safe-change-policy.ps1',
        'verify-no-node-install-dependency.ps1',
        'verify-placeholder-rendering.ps1',
        'verify-workflow-contracts.ps1',
        'verify-workflow-descriptor.ps1',
        'verify-shared-memory-layers.ps1',
        'verify-stage-discipline-matrix.ps1',
        'verify-release-validation.ps1',
        'verify-runtime-state-contract.ps1',
        'verify-skill-manifest.ps1',
        'verify-task-artifact-drift-audit.ps1',
        'verify-tool-profile.ps1'
    )
}
$coreScripts = @($coreScriptGroups.Values | ForEach-Object { $_ })

if ($Suite -eq 'quick') {
    $scriptNames = @('verify-lite-footprint.ps1')
} elseif ($Suite -eq 'core') {
    if ($CoreGroup -eq 'all') {
        $scriptNames = $coreScripts
    } else {
        $scriptNames = @($coreScriptGroups[$CoreGroup])
    }
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
    Add-PowerShellScriptCheck -Checks $checks -Name 'verify-installation.ps1' -ScriptPath $installScript -Parameters ([ordered]@{
        WorkspaceRoot = $WorkspaceRoot
        RepoRoot = $repoRootResolved
    })
} elseif ($Suite -eq 'all') {
    $skips.Add('verify-installation.ps1 requires -WorkspaceRoot and is not part of the default no-argument loop') | Out-Null
}

Write-Output ("Validation suite: {0}" -f $Suite)
Write-Output ("Core group: {0}" -f $CoreGroup)
Write-Output ("RepoRoot: {0}" -f $repoRootResolved)
Write-Output ("PowerShell host: {0}" -f (Get-Process -Id $PID -ErrorAction Stop).Path)
Write-Output ''

foreach ($skip in $skips) {
    Write-Output ("[SKIP] {0}" -f $skip)
}

$failures = New-Object System.Collections.Generic.List[object]
foreach ($check in $checks) {
    Write-Output ("[RUN ] {0}" -f $check.Name)
    $effectiveTimeoutSeconds = if ($check.Name -ceq 'verify-host-benchmark-qualification.ps1') { [math]::Max($CheckTimeoutSeconds,900) } else { $CheckTimeoutSeconds }
    $result = Invoke-QuietProcess -Name $check.Name -FilePath $check.FilePath -ArgumentList $check.ArgumentList -WorkingDirectory $repoRootResolved -TimeoutSeconds $effectiveTimeoutSeconds -InvocationKind $check.InvocationKind -PowerShellParameters $check.PowerShellParameters
    if ($result.ExitCode -eq 0) {
        Write-Output ("[PASS] {0} ({1}s)" -f $result.Name, $result.DurationSeconds)
        if ($VerboseOutput) {
            if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) { Write-Output $result.StdOut.TrimEnd() }
            if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) { [Console]::Error.WriteLine($result.StdErr.TrimEnd()) }
        }
    } else {
        $failures.Add($result) | Out-Null
        $failureSuffix = if ($result.TimedOut) { ", timeout {0}s" -f $effectiveTimeoutSeconds } else { '' }
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
