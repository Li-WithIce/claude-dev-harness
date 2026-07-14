[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$OutputPath = '',
    [switch]$RequireEligible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$powerShell = (Get-Process -Id $PID).Path

function Get-TextDigest {
    param([string]$Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return 'sha256:' + ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-RolloutGate {
    param([string]$Command,[string]$ScriptPath,[string[]]$Arguments)
    $output = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $text = $output -join "`n"
    return [pscustomobject]@{Command=$Command;ExitCode=$exitCode;Output=$text;EvidenceDigest=(Get-TextDigest -Text ("command=$Command`nexit_code=$exitCode`n$text"))}
}

function New-GateRecord {
    param([string]$Status,[pscustomobject]$Run)
    return [ordered]@{status=$Status;evidence_digest=$Run.EvidenceDigest;command=$Run.Command}
}

function Read-JsonOutput {
    param([string]$Text)
    $lines = @($Text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return $null }
    try { return $lines[-1] | ConvertFrom-Json -AsHashtable -Depth 60 -ErrorAction Stop } catch { return $null }
}

$behaviorRun = Invoke-RolloutGate -Command 'tests/run-scenario-evals.ps1 -Suite core' -ScriptPath (Join-Path $RepoRoot 'tests\run-scenario-evals.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-Suite','core')
$behaviorJson = Read-JsonOutput -Text $behaviorRun.Output
$behaviorStatus = if ($behaviorRun.ExitCode -eq 0 -and $null -ne $behaviorJson -and [bool]$behaviorJson.eligibility.eligible) { 'pass' } elseif ($null -ne $behaviorJson -and [int]$behaviorJson.summary.unavailable -gt 0) { 'unavailable' } else { 'fail' }

$compatRun = Invoke-RolloutGate -Command 'scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 360' -ScriptPath (Join-Path $RepoRoot 'scripts\run-validation.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-Suite','all','-CheckTimeoutSeconds','360')
$compatStatus = if ($compatRun.ExitCode -eq 0) { 'pass' } else { 'fail' }

$benchmarkRun = Invoke-RolloutGate -Command 'scripts/benchmark-harness.ps1 -Compare bare,v1,v2' -ScriptPath (Join-Path $RepoRoot 'scripts\benchmark-harness.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-Compare','bare,v1,v2')
$benchmarkJson = Read-JsonOutput -Text $benchmarkRun.Output
$performanceStatus = if ($benchmarkRun.ExitCode -ne 0 -or $null -eq $benchmarkJson) { 'fail' } else { [string]$benchmarkJson.performance_regression.direct_latency.status }
if ($performanceStatus -cnotin @('pass','fail','blocked','unavailable','simulated')) { $performanceStatus = 'fail' }

$coreRun = Invoke-RolloutGate -Command 'scripts/run-isolated-install-smoke.ps1 -Preset core' -ScriptPath (Join-Path $RepoRoot 'scripts\run-isolated-install-smoke.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-Preset','core')
$coreStatus = if ($coreRun.ExitCode -eq 0) { 'pass' } else { 'fail' }
$fullRun = Invoke-RolloutGate -Command 'scripts/run-isolated-install-smoke.ps1 -Preset full' -ScriptPath (Join-Path $RepoRoot 'scripts\run-isolated-install-smoke.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-Preset','full')
$fullStatus = if ($fullRun.ExitCode -eq 0) { 'pass' } else { 'fail' }

$gates = [ordered]@{
    behavior = New-GateRecord -Status $behaviorStatus -Run $behaviorRun
    v1_compatibility = New-GateRecord -Status $compatStatus -Run $compatRun
    direct_performance = New-GateRecord -Status $performanceStatus -Run $benchmarkRun
    core_install_rollback = New-GateRecord -Status $coreStatus -Run $coreRun
    full_install_rollback = New-GateRecord -Status $fullStatus -Run $fullRun
}
$protocolModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -PassThru -ErrorAction Stop
$report = & $protocolModule { param($Root,$GateValues) New-HarnessRolloutReportDocument -RepoRoot $Root -Gates $GateValues } $RepoRoot $gates
$json = $report | ConvertTo-Json -Depth 30 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $target = if ([System.IO.Path]::IsPathRooted($OutputPath)) { [System.IO.Path]::GetFullPath($OutputPath) } else { [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $OutputPath)) }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($target,$json,[System.Text.UTF8Encoding]::new($false))
}
Write-Output $json
$executionFailed = $behaviorStatus -cne 'pass' -or $compatStatus -cne 'pass' -or $coreStatus -cne 'pass' -or $fullStatus -cne 'pass' -or $performanceStatus -cin @('fail','blocked')
if ($executionFailed) { exit 1 }
if ($RequireEligible -and -not [bool]$report.eligible) { exit 3 }
exit 0
