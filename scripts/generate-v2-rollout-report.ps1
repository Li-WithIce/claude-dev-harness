[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$GateEvidencePath = '',
    # Retained only so the pre-DP-02B release job fails with an explicit diagnostic.
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
$evidenceModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
$protocolModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -PassThru -ErrorAction Stop

function Resolve-ReportInputPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

if (-not [string]::IsNullOrWhiteSpace($ModelEvalReportPath) -or -not [string]::IsNullOrWhiteSpace($HostBenchmarkReportPath)) {
    throw 'rollout-v1-evidence-inputs-are-historical-only'
}
if ([string]::IsNullOrWhiteSpace($GateEvidencePath)) { throw 'rollout-evidence-set-required' }
$GateEvidencePath = Resolve-ReportInputPath -Path $GateEvidencePath
if (-not (Test-Path -LiteralPath $GateEvidencePath -PathType Leaf)) { throw 'rollout-evidence-set-missing' }
$inputInfo = Get-Item -LiteralPath $GateEvidencePath -Force -ErrorAction Stop
if ($inputInfo.Length -gt 4MB) { throw 'rollout-evidence-set-too-large' }
$inputBytes = [IO.File]::ReadAllBytes($GateEvidencePath)
if ($inputBytes.Length -gt 4MB) { throw 'rollout-evidence-set-too-large' }
$evidenceSet = & $protocolModule { param($Bytes) ConvertFrom-HarnessRolloutJsonBytes -Bytes $Bytes -Kind evidence-set } $inputBytes

$protectedRoots = [Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $protectedRoots.Add((Join-Path $env:USERPROFILE '.codex')) }
foreach ($name in @('CODEX_HOME','HOST_BENCHMARK_CODEX_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($value)) { $protectedRoots.Add($value) }
}
$outputTarget = if ([string]::IsNullOrWhiteSpace($OutputPath)) { '' } else {
    & $evidenceModule {
        param($Root,$Path,$Inputs,$Protected) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path -EvidencePaths $Inputs -ProtectedRoots $Protected
    } $RepoRoot $OutputPath @($GateEvidencePath) @($protectedRoots)
}
$sourceStart = & $evidenceModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $RepoRoot
$report = & $protocolModule { param($Root,$Set) New-HarnessRolloutV2ReportDocument -RepoRoot $Root -EvidenceSet $Set } $RepoRoot $evidenceSet
$sourceFinal = & $evidenceModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $RepoRoot
if (-not (& $evidenceModule { param($Start,$End) Test-HarnessReleaseSourceStable -Start $Start -End $End } $sourceStart $sourceFinal)) { throw 'rollout-source-changed' }

$json = $report | ConvertTo-Json -Depth 30 -Compress
if (-not [string]::IsNullOrWhiteSpace($outputTarget)) {
    & $evidenceModule { param($Target,$Content) Write-HarnessReleaseArtifact -Target $Target -Content $Content } $outputTarget $json
}
Write-Output $json

$exitCode = & $evidenceModule { param($GateValues,$Eligible,$Required) Get-HarnessReleaseExitCode -Gates $GateValues -Eligible $Eligible -RequireEligible $Required } $report.gates ([bool]$report.eligible) ([bool]$RequireEligible)
exit $exitCode
