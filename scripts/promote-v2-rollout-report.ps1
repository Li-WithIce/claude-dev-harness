[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$ObservedHostContextPath = '',
    [string]$ReviewReceiptPath = '',
    [switch]$AuthorizeCanary,
    [string]$AuthorizedBy = '',
    [string]$ExpiresAtUtc = '',
    [Nullable[double]]$DurationHours = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Hashing.psm1') -Force -ErrorAction Stop

function Get-RolloutRawDigest {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return Get-HarnessSha256Bytes -Bytes $Bytes
}

try {
    $protocolModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -PassThru -ErrorAction Stop
    $evidenceModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
    $qualificationModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Qualification.psm1') -Force -PassThru -ErrorAction Stop
    $runtimeDefaultModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RuntimeDefault.psm1') -Force -PassThru -ErrorAction Stop
    $protectedRoots = [Collections.Generic.List[string]]::new()
    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) { $protectedRoots.Add((Join-Path $userProfile '.codex')) }
    foreach ($name in @('CODEX_HOME','HOST_BENCHMARK_CODEX_HOME')) {
        $value = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $protectedRoots.Add($value) }
    }
    $paths = & $evidenceModule {
        param($Root,$Workspace,$InputPath,$Protected)
        Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Workspace -ReportPath $InputPath -ProtectedRoots $Protected
    } $RepoRoot $WorkspaceRoot $ReportPath @($protectedRoots)
    $WorkspaceRoot = [string]$paths.workspace

    $sourceStateStart = & $evidenceModule { param($Root) Get-HarnessReleaseSourceState -RepoRoot $Root } $RepoRoot
    if ([bool]$sourceStateStart.dirty) { throw 'rollout-promotion-source-dirty' }
    $sourceInfo = Get-Item -LiteralPath $paths.source -Force -ErrorAction Stop
    if ($sourceInfo.Length -gt 4MB) { throw 'rollout-promotion-input-too-large' }
    $reportBytes = [IO.File]::ReadAllBytes([string]$paths.source)
    if ($reportBytes.Length -gt 4MB) { throw 'rollout-promotion-input-too-large' }
    $reportFileDigest = Get-RolloutRawDigest -Bytes $reportBytes
    try { $report = & $qualificationModule { param($Bytes) ConvertFrom-HarnessRolloutJsonBytes -Bytes $Bytes -Kind report } $reportBytes }
    catch { throw 'rollout-promotion-report-invalid-json' }
    & $qualificationModule {
        param($Root,$Document)
        Assert-HarnessRolloutRepositoryClean -RepoRoot $Root
        Assert-HarnessRolloutReport -RepoRoot $Root -Document $Document
    } $RepoRoot $report
    if ([string]$report.schema_version -ceq 'rollout-eligibility/v1') { throw 'rollout-promotion-v1-historical-only' }

    if ([string]$report.phase -ceq 'canary-candidate') {
        if (-not $AuthorizeCanary) { throw 'rollout-promotion-canary-authorization-required' }
        if ([string]::IsNullOrWhiteSpace($AuthorizedBy)) { throw 'rollout-promotion-authorized-by-required' }
        $hasExpiresAt = -not [string]::IsNullOrWhiteSpace($ExpiresAtUtc)
        $hasDuration = $null -ne $DurationHours
        $durationValue = if ($hasDuration) { [double]$DurationHours } else { 0 }
        if ($hasExpiresAt -eq $hasDuration) { throw 'rollout-promotion-canary-expiry-required' }
        if ($hasDuration -and ($durationValue -le 0 -or $durationValue -gt 168)) { throw 'rollout-promotion-canary-duration-invalid' }
    } elseif ($AuthorizeCanary -or -not [string]::IsNullOrWhiteSpace($AuthorizedBy) -or -not [string]::IsNullOrWhiteSpace($ExpiresAtUtc) -or $null -ne $DurationHours) {
        throw 'rollout-promotion-final-does-not-use-canary-authorization'
    }

    if ([string]::IsNullOrWhiteSpace($ObservedHostContextPath)) { throw 'rollout-observed-host-context-missing' }
    if ([string]::IsNullOrWhiteSpace($ReviewReceiptPath)) { throw 'rollout-review-receipt-missing' }
    $ObservedHostContextPath = [IO.Path]::GetFullPath($ObservedHostContextPath)
    $ReviewReceiptPath = [IO.Path]::GetFullPath($ReviewReceiptPath)
    $inputProtectedRoots = @($protectedRoots) + @($RepoRoot,$WorkspaceRoot)
    $contextArtifact = & $evidenceModule {
        param($Path,$Protected) Read-HarnessRolloutEvidenceArtifact -ArtifactPath $Path -ProtectedRoots $Protected -MaximumBytes 64KB
    } $ObservedHostContextPath $inputProtectedRoots
    $receiptArtifact = & $evidenceModule {
        param($Path,$Protected) Read-HarnessRolloutEvidenceArtifact -ArtifactPath $Path -ProtectedRoots $Protected -MaximumBytes 64KB
    } $ReviewReceiptPath $inputProtectedRoots
    $observedHostContext = & $qualificationModule { param($Bytes) ConvertFrom-HarnessRolloutJsonBytes -Bytes $Bytes -Kind observed-host-context } ([byte[]]$contextArtifact.bytes)
    $reviewReceipt = & $qualificationModule { param($Bytes) ConvertFrom-HarnessRolloutJsonBytes -Bytes $Bytes -Kind review-receipt } ([byte[]]$receiptArtifact.bytes)
    & $qualificationModule {
        param($Root,$Context,$Report,$Receipt,$ReceiptPath)
        Assert-HarnessObservedHostContext -RepoRoot $Root -Document $Context
        Assert-HarnessRolloutReviewReceipt -RepoRoot $Root -Document $Receipt -ExpectedPayloadDigest ([string]$Report.review_payload_digest) -ExpectedSourceRevision ([string]$Report.source_revision) -ExpectedPhase ([string]$Report.phase)
        if ([string]$Receipt.receipt_digest -cne [string]$Report.review_receipt.receipt_digest) { throw 'rollout-promotion-review-receipt-mismatch' }
        $boundPath = [IO.Path]::GetFullPath([string]$Report.gates['DP-G12-ROLLOUT-ELIGIBILITY-REPORT'].artifact_path)
        if (-not $boundPath.Equals([IO.Path]::GetFullPath($ReceiptPath),[StringComparison]::OrdinalIgnoreCase)) { throw 'rollout-promotion-review-receipt-path-mismatch' }
    } $RepoRoot $observedHostContext $report $reviewReceipt $ReviewReceiptPath

    if ([string]$report.provenance_status -cne 'verified') { throw 'rollout-evidence-provenance-unverified' }
    $inputGates = [ordered]@{}
    foreach ($name in @($report.gates.Keys | Where-Object { [string]$_ -cne 'DP-G12-ROLLOUT-ELIGIBILITY-REPORT' })) { $inputGates[[string]$name] = $report.gates[$name] }
    & $evidenceModule { param($Gates,$Protected) Assert-HarnessRolloutEvidenceSetProvenance -Gates $Gates -ProtectedRoots $Protected } $inputGates $inputProtectedRoots

    $authorization = $null
    $authorizationBytes = [byte[]]::new(0)
    $decisionIssuedAt = [datetimeoffset]::UtcNow
    $decisionExpiresAt = $null
    if ([string]$report.phase -ceq 'canary-candidate') {
        $decisionIssuedAt = [datetimeoffset]::UtcNow
        $decisionExpiresAt = if ($null -ne $DurationHours) { $decisionIssuedAt.AddHours($durationValue) } else {
            try { [datetimeoffset]::Parse($ExpiresAtUtc,[Globalization.CultureInfo]::InvariantCulture) }
            catch { throw 'rollout-promotion-canary-expiry-invalid' }
        }
        $authorization = & $qualificationModule {
            param($Root,$Workspace,$Report,$Context,$Owner,$Issued,$Expires)
            New-HarnessCanaryAuthorizationDocument -RepoRoot $Root -WorkspaceRoot $Workspace -Report $Report -ObservedHostContext $Context -AuthorizedBy $Owner -IssuedAtUtc $Issued -ExpiresAtUtc $Expires
        } $RepoRoot $WorkspaceRoot $report $observedHostContext $AuthorizedBy $decisionIssuedAt $decisionExpiresAt
        $authorizationBytes = [Text.UTF8Encoding]::new($false).GetBytes(($authorization | ConvertTo-Json -Depth 100 -Compress))
    }

    $decisionScope = if ([string]$report.phase -ceq 'canary-candidate') { 'workspace-canary' } else { 'release-default' }
    $runtimeDecision = & $runtimeDefaultModule {
        param($Root,$Workspace,$Scope,$Revision,$Issued,$Expires)
        New-HarnessRuntimeDefaultDecisionDocument -RepoRoot $Root -WorkspaceRoot $Workspace -Scope $Scope -SourceRevision $Revision -IssuedAtUtc $Issued -ExpiresAtUtc $Expires
    } $RepoRoot $WorkspaceRoot $decisionScope ([string]$report.source_revision) $decisionIssuedAt $decisionExpiresAt
    $runtimeDecisionBytes = [Text.UTF8Encoding]::new($false).GetBytes(($runtimeDecision | ConvertTo-Json -Depth 20 -Compress))

    $transaction = & $evidenceModule {
        param($Root,$Workspace,$InputPath,$Phase,$ReportBytes,$AuthorizationBytes,$DecisionBytes,$Protected,$SourceState,$Protocol,$Report,$Authorization,$Decision)
        Invoke-HarnessRolloutPublicationTransaction -RepoRoot $Root -WorkspaceRoot $Workspace -ReportPath $InputPath -Phase $Phase -ReportBytes $ReportBytes -ExpectedReportDigest ([string]$Report.report_digest) -AuthorizationBytes $AuthorizationBytes -ExpectedAuthorizationDigest $(if($null-eq$Authorization){''}else{[string]$Authorization.authorization_digest}) -DecisionBytes $DecisionBytes -ExpectedDecisionDigest ([string]$Decision.decision_digest) -ProtectedRoots $Protected -SourceStateStart $SourceState -ProtocolModule $Protocol
    } $RepoRoot $WorkspaceRoot $ReportPath ([string]$report.phase) $reportBytes $authorizationBytes $runtimeDecisionBytes @($protectedRoots) $sourceStateStart $protocolModule $report $authorization $runtimeDecision

    [ordered]@{
        operation = 'promote-v2-rollout-report'
        status = 'pass'
        phase = [string]$report.phase
        final_target = [string]$transaction.final_target
        candidate_target = [string]$transaction.candidate_target
        authorization_target = $(if ($null -eq $authorization) { $null } else { [string]$transaction.authorization_target })
        runtime_default_target = [string]$transaction.runtime_default_target
        report_digest = [string]$report.report_digest
        file_digest = $reportFileDigest
        source_revision = [string]$report.source_revision
        authorization_digest = $(if ($null -eq $authorization) { $null } else { [string]$authorization.authorization_digest })
        decision_digest = [string]$runtimeDecision.decision_digest
    } | ConvertTo-Json -Depth 10 -Compress | Write-Output
    exit 0
} catch {
    [Console]::Error.WriteLine('[ROLLOUT-PROMOTION] FAIL: ' + [string]$_.Exception.Message)
    exit 2
}
