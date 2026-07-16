[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ModelEvalReportPath = '',
    [string]$HostBenchmarkReportPath = '',
    [string]$OutputPath = '',
    [switch]$RequireEligible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$powerShell = (Get-Process -Id $PID).Path
$evidenceModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop

function Get-TextDigest {
    param([string]$Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Resolve-ReportInputPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Invoke-RolloutGate {
    param([string]$Name,[string]$Command,[string]$ScriptPath,[string[]]$Arguments)
    $output = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $text = $output -join "`n"
    if ($exitCode -ne 0 -or $text -cmatch '(?m)^\[UNAVAILABLE\]\s+') {
        Write-Host ("[ROLLOUT:{0}] exit={1}" -f $Name,$exitCode)
        foreach ($line in @($output | Select-Object -Last 200)) { Write-Host ("[ROLLOUT:{0}] {1}" -f $Name,$line) }
    }
    return [pscustomobject]@{
        Command = $Command
        ExitCode = $exitCode
        Output = $text
        EvidenceDigest = Get-TextDigest -Text ("command=$Command`nexit_code=$exitCode`n$text")
    }
}

function New-GateRecord {
    param([string]$Status,[string]$EvidenceDigest,[string]$Command)
    return [ordered]@{status=$Status;evidence_digest=$EvidenceDigest;command=$Command}
}

function New-ExecutedGateRecord {
    param([string]$Status,[pscustomobject]$Run)
    return New-GateRecord -Status $Status -EvidenceDigest $Run.EvidenceDigest -Command $Run.Command
}

function New-EvidenceGateRecord {
    param([System.Collections.IDictionary]$Gate)
    return New-GateRecord -Status ([string]$Gate.status) -EvidenceDigest ([string]$Gate.evidence_digest) -Command ([string]$Gate.command)
}

$ModelEvalReportPath = Resolve-ReportInputPath -Path $ModelEvalReportPath
$HostBenchmarkReportPath = Resolve-ReportInputPath -Path $HostBenchmarkReportPath
$protectedRoots = [Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $protectedRoots.Add((Join-Path $env:USERPROFILE '.codex')) }
foreach ($name in @('CODEX_HOME','HOST_BENCHMARK_CODEX_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($value)) { $protectedRoots.Add($value) }
}
$outputTarget = if ([string]::IsNullOrWhiteSpace($OutputPath)) { '' } else {
    & $evidenceModule {
        param($Root,$Path,$Inputs,$Protected) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path -EvidencePaths $Inputs -ProtectedRoots $Protected
    } $RepoRoot $OutputPath @($ModelEvalReportPath,$HostBenchmarkReportPath) @($protectedRoots)
}
$sourceStart = & $evidenceModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $RepoRoot

$behaviorEvidence = & $evidenceModule {
    param($Root,$Path,$Source) Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $Root -ReportPath $Path -ExpectedSource $Source
} $RepoRoot $ModelEvalReportPath $sourceStart
Write-Host ("[ROLLOUT:behavior] status={0} reason={1}" -f $behaviorEvidence.status,$behaviorEvidence.reason)

$compatRun = Invoke-RolloutGate -Name 'v1_compatibility' -Command 'scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput' -ScriptPath (Join-Path $RepoRoot 'scripts\run-validation.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-Suite','all','-CheckTimeoutSeconds','360','-VerboseOutput')
$compatStatus = if ($compatRun.ExitCode -ne 0) { 'fail' } elseif ($compatRun.Output -cmatch '(?m)^\[UNAVAILABLE\]\s+') { 'unavailable' } else { 'pass' }

$performanceEvidence = & $evidenceModule {
    param($Root,$Path,$Source) Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $Root -ReportPath $Path -ExpectedSource $Source
} $RepoRoot $HostBenchmarkReportPath $sourceStart
Write-Host ("[ROLLOUT:direct_performance] status={0} reason={1}" -f $performanceEvidence.status,$performanceEvidence.reason)

$coreRun = Invoke-RolloutGate -Name 'core_install_rollback' -Command 'scripts/run-isolated-install-smoke.ps1 -Preset core' -ScriptPath (Join-Path $RepoRoot 'scripts\run-isolated-install-smoke.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-Preset','core')
$coreStatus = if ($coreRun.ExitCode -eq 0) { 'pass' } else { 'fail' }
$fullRun = Invoke-RolloutGate -Name 'full_install_rollback' -Command 'scripts/run-isolated-install-smoke.ps1 -Preset full' -ScriptPath (Join-Path $RepoRoot 'scripts\run-isolated-install-smoke.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-Preset','full')
$fullStatus = if ($fullRun.ExitCode -eq 0) { 'pass' } else { 'fail' }

$sourceEnd = & $evidenceModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $RepoRoot
$sourceStable = & $evidenceModule { param($Start,$End) Test-HarnessReleaseSourceStable -Start $Start -End $End } $sourceStart $sourceEnd
if (-not $sourceStable) {
    $compatStatus = 'fail'
    $compatRun.EvidenceDigest = Get-TextDigest -Text ("source_start={0}`nsource_end={1}`nprior_evidence={2}" -f $sourceStart.state_digest,$sourceEnd.state_digest,$compatRun.EvidenceDigest)
    Write-Host '[ROLLOUT:source] qualification source was dirty or changed while gates ran; report will be ineligible.'
}

$gates = [ordered]@{
    behavior = New-EvidenceGateRecord -Gate $behaviorEvidence
    v1_compatibility = New-ExecutedGateRecord -Status $compatStatus -Run $compatRun
    direct_performance = New-EvidenceGateRecord -Gate $performanceEvidence
    core_install_rollback = New-ExecutedGateRecord -Status $coreStatus -Run $coreRun
    full_install_rollback = New-ExecutedGateRecord -Status $fullStatus -Run $fullRun
}
if (-not $sourceStable) {
    if ([string]$gates.behavior.status -ceq 'pass') { $gates.behavior.status = 'fail' }
    if ([string]$gates.direct_performance.status -ceq 'pass') { $gates.direct_performance.status = 'fail' }
}

$protocolModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -PassThru -ErrorAction Stop
$report = & $protocolModule { param($Root,$GateValues) New-HarnessRolloutReportDocument -RepoRoot $Root -Gates $GateValues } $RepoRoot $gates
$sourceFinal = & $evidenceModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $RepoRoot
$sourceStayedStableThroughReport = & $evidenceModule { param($Start,$End) Test-HarnessReleaseSourceStable -Start $Start -End $End } $sourceStart $sourceFinal
if (-not $sourceStayedStableThroughReport) {
    $gates.v1_compatibility.status = 'fail'
    $gates.v1_compatibility.evidence_digest = Get-TextDigest -Text ("source_start={0}`nsource_final={1}`nprior_evidence={2}" -f $sourceStart.state_digest,$sourceFinal.state_digest,$gates.v1_compatibility.evidence_digest)
    $report = & $protocolModule { param($Root,$GateValues) New-HarnessRolloutReportDocument -RepoRoot $Root -Gates $GateValues } $RepoRoot $gates
}

$json = $report | ConvertTo-Json -Depth 30 -Compress
if (-not [string]::IsNullOrWhiteSpace($outputTarget)) {
    & $evidenceModule { param($Target,$Content) Write-HarnessReleaseArtifact -Target $Target -Content $Content } $outputTarget $json
}
Write-Output $json

$exitCode = & $evidenceModule { param($GateValues,$Eligible,$Required) Get-HarnessReleaseExitCode -Gates $GateValues -Eligible $Eligible -RequireEligible $Required } $gates ([bool]$report.eligible) ([bool]$RequireEligible)
exit $exitCode
