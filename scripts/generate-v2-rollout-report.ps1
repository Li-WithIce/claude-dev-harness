[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$GateEvidencePath = '',
    [switch]$CreateReviewPayload,
    [string]$ReviewPayloadPath = '',
    [string]$ReviewReceiptPath = '',
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

function Read-RolloutInputDocument {
    param([string]$Path,[string]$Kind,[long]$MaximumBytes,[string]$MissingReason,[string]$TooLargeReason)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $MissingReason }
    $info = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($info.Length -gt $MaximumBytes) { throw $TooLargeReason }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt $MaximumBytes) { throw $TooLargeReason }
    return & $protocolModule { param($Value,$DocumentKind) ConvertFrom-HarnessRolloutJsonBytes -Bytes $Value -Kind $DocumentKind } $bytes $Kind
}

if (-not [string]::IsNullOrWhiteSpace($ModelEvalReportPath) -or -not [string]::IsNullOrWhiteSpace($HostBenchmarkReportPath)) {
    throw 'rollout-v1-evidence-inputs-are-historical-only'
}
$evidenceMode = -not [string]::IsNullOrWhiteSpace($GateEvidencePath)
$finalizeMode = -not [string]::IsNullOrWhiteSpace($ReviewPayloadPath) -or -not [string]::IsNullOrWhiteSpace($ReviewReceiptPath)
if ($evidenceMode -eq $finalizeMode) { throw 'rollout-generator-input-mode-invalid' }
if ($finalizeMode -and ([string]::IsNullOrWhiteSpace($ReviewPayloadPath) -or [string]::IsNullOrWhiteSpace($ReviewReceiptPath))) { throw 'rollout-review-payload-and-receipt-required' }
if ($evidenceMode -and -not $CreateReviewPayload) { throw 'rollout-evidence-provenance-unverified' }
if ($finalizeMode -and $CreateReviewPayload) { throw 'rollout-generator-input-mode-invalid' }

$GateEvidencePath = Resolve-ReportInputPath -Path $GateEvidencePath
$ReviewPayloadPath = Resolve-ReportInputPath -Path $ReviewPayloadPath
$ReviewReceiptPath = Resolve-ReportInputPath -Path $ReviewReceiptPath
$inputPaths = @($GateEvidencePath,$ReviewPayloadPath,$ReviewReceiptPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$protectedRoots = [Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $protectedRoots.Add((Join-Path $env:USERPROFILE '.codex')) }
foreach ($name in @('CODEX_HOME','HOST_BENCHMARK_CODEX_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($value)) { $protectedRoots.Add($value) }
}
$outputTarget = if ([string]::IsNullOrWhiteSpace($OutputPath)) { '' } else {
    & $evidenceModule {
        param($Root,$Path,$Inputs,$Protected) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path -EvidencePaths $Inputs -ProtectedRoots $Protected
    } $RepoRoot $OutputPath @($inputPaths) @($protectedRoots)
}
$sourceStart = & $evidenceModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $RepoRoot

$document = $null
$exitCode = 0
if ($evidenceMode) {
    $evidenceSet = Read-RolloutInputDocument -Path $GateEvidencePath -Kind evidence-set -MaximumBytes 4MB -MissingReason 'rollout-evidence-set-missing' -TooLargeReason 'rollout-evidence-set-too-large'
    & $protocolModule { param($Root,$Set) Assert-HarnessRolloutV2EvidenceSet -RepoRoot $Root -Document $Set } $RepoRoot $evidenceSet
    $provenanceStatus = 'verified'
    try {
        & $evidenceModule { param($Gates,$Protected) Assert-HarnessRolloutEvidenceSetProvenance -Gates $Gates -ProtectedRoots $Protected } $evidenceSet.gates @($protectedRoots)
    } catch {
        $reason = [string]$_.Exception.Message
        if (-not $reason.StartsWith('rollout-evidence-',[StringComparison]::Ordinal)) { throw }
        $provenanceStatus = 'unverified'
    }
    $document = & $protocolModule { param($Root,$Set,$Status) New-HarnessRolloutReviewPayloadDocument -RepoRoot $Root -EvidenceSet $Set -ProvenanceStatus $Status } $RepoRoot $evidenceSet $provenanceStatus
    $exitCode = if ($provenanceStatus -ceq 'verified') { 0 } else { 3 }
} else {
    $payload = Read-RolloutInputDocument -Path $ReviewPayloadPath -Kind review-payload -MaximumBytes 4MB -MissingReason 'rollout-review-payload-missing' -TooLargeReason 'rollout-review-payload-too-large'
    $receipt = Read-RolloutInputDocument -Path $ReviewReceiptPath -Kind review-receipt -MaximumBytes 64KB -MissingReason 'rollout-review-receipt-missing' -TooLargeReason 'rollout-review-receipt-too-large'
    & $protocolModule {
        param($Root,$Payload,$Receipt)
        Assert-HarnessRolloutReviewPayload -RepoRoot $Root -Document $Payload
        Assert-HarnessRolloutReviewReceipt -RepoRoot $Root -Document $Receipt -ExpectedPayloadDigest ([string]$Payload.reviewed_payload_digest) -ExpectedSourceRevision ([string]$Payload.source_revision) -ExpectedPhase ([string]$Payload.phase)
    } $RepoRoot $payload $receipt
    if ([string]$payload.provenance_status -cne 'verified') { throw 'rollout-evidence-provenance-unverified' }
    & $evidenceModule { param($Gates,$Protected) Assert-HarnessRolloutEvidenceSetProvenance -Gates $Gates -ProtectedRoots $Protected } $payload.gates @($protectedRoots)
    $document = & $protocolModule {
        param($Root,$Payload,$Receipt,$ReceiptPath)
        New-HarnessRolloutV2ReportDocument -RepoRoot $Root -ReviewPayload $Payload -ReviewReceipt $Receipt -ReviewReceiptArtifactPath $ReceiptPath
    } $RepoRoot $payload $receipt $ReviewReceiptPath
}

$sourceFinal = & $evidenceModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $RepoRoot
if (-not (& $evidenceModule { param($Start,$End) Test-HarnessReleaseSourceStable -Start $Start -End $End } $sourceStart $sourceFinal)) { throw 'rollout-source-changed' }
$json = $document | ConvertTo-Json -Depth 100 -Compress
if (-not [string]::IsNullOrWhiteSpace($outputTarget)) {
    & $evidenceModule { param($Target,$Content) Write-HarnessReleaseArtifact -Target $Target -Content $Content } $outputTarget $json
}
Write-Output $json
if ($RequireEligible -and ($document -isnot [System.Collections.IDictionary] -or -not $document.Contains('eligible') -or -not [bool]$document.eligible)) { exit 3 }
exit $exitCode
