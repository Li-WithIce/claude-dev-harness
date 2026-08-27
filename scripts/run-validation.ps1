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
$manifestModulePath = Join-Path $repoRootResolved 'scripts\lib\Harness.ModuleManifest.psm1'
Import-Module $manifestModulePath -Force -ErrorAction Stop
$manifestCatalog = Assert-HarnessModuleManifestCatalogCurrent -RepoRoot $repoRootResolved
$script:GitPath = Resolve-Executable -Candidates @('git.exe', 'git') -Purpose 'git checks'
$checks = New-Object System.Collections.Generic.List[object]
$skips = New-Object System.Collections.Generic.List[string]

Add-GitCheck -Checks $checks -Name 'git diff --check' -ArgumentList @('diff', '--check')
if ($IncludeCachedDiff) {
    Add-GitCheck -Checks $checks -Name 'git diff --cached --check' -ArgumentList @('diff', '--cached', '--check')
}

$coreScriptGroups = [ordered]@{}
foreach ($groupName in @($manifestCatalog.Catalog.core_groups.Keys)) {
    $coreScriptGroups[$groupName] = @($manifestCatalog.Catalog.core_groups[$groupName] | ForEach-Object { Split-Path -Leaf ([string]$_) })
}
$coreScripts = @($coreScriptGroups.Values | ForEach-Object { $_ })

if ($Suite -eq 'quick') {
    $scriptNames = @($manifestCatalog.Catalog.quick_tests | ForEach-Object { Split-Path -Leaf ([string]$_) })
} elseif ($Suite -eq 'core') {
    if ($CoreGroup -eq 'all') {
        $scriptNames = $coreScripts
    } else {
        $scriptNames = @($coreScriptGroups[$CoreGroup])
    }
} else {
    $scriptNames = @($manifestCatalog.Catalog.full_tests | ForEach-Object { Split-Path -Leaf ([string]$_) })
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
