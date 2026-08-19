[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][string]$ExactHeadReportPath,
    [Parameter(Mandatory)][string]$ReleaseIsolationReportPath,
    [Parameter(Mandatory)][string]$ReleaseModelReceiptPath,
    [Parameter(Mandatory)][string]$ReleaseHostReceiptPath,
    [Parameter(Mandatory)][string]$V1StopLossReportPath,
    [Parameter(Mandatory)][string]$LifecycleCoreReportPath,
    [Parameter(Mandatory)][string]$LifecycleGovernedReportPath,
    [Parameter(Mandatory)][string]$LifecycleFullReportPath,
    [Parameter(Mandatory)][string]$AggregatorObservationPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][int]$RunAttempt,
    [Parameter(Mandatory)][string]$CheckoutSha,
    [Parameter(Mandatory)][ValidateSet('success','failure','neutral','cancelled','skipped','timed_out','action_required','stale','startup_failure')][string]$Conclusion,
    [ValidateSet('formal','test-only')][string]$ProducerMode = 'formal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$module = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
$receipt = & $module {
    param($Root,$ExactHead,$Isolation,$Model,$HostReceipt,$V1StopLoss,$Core,$Governed,$Full,$Aggregator,$Output,$WorkflowRun,$Attempt,$Checkout,$JobConclusion,$Mode)
    New-ReleaseFullReceiptArtifact -RepoRoot $Root -ExactHeadReportPath $ExactHead -ReleaseIsolationReportPath $Isolation `
        -ReleaseModelReceiptPath $Model -ReleaseHostReceiptPath $HostReceipt -V1StopLossReportPath $V1StopLoss `
        -LifecycleCoreReportPath $Core -LifecycleGovernedReportPath $Governed -LifecycleFullReportPath $Full `
        -AggregatorObservationPath $Aggregator -OutputPath $Output -RunId $WorkflowRun -RunAttempt $Attempt `
        -CheckoutSha $Checkout -Conclusion $JobConclusion -ProducerMode $Mode
} $RepoRoot $ExactHeadReportPath $ReleaseIsolationReportPath $ReleaseModelReceiptPath $ReleaseHostReceiptPath $V1StopLossReportPath $LifecycleCoreReportPath $LifecycleGovernedReportPath $LifecycleFullReportPath $AggregatorObservationPath $OutputPath $RunId $RunAttempt $CheckoutSha $Conclusion $ProducerMode

Write-Output 'Release full receipt summary:'
Write-Output ("- producer_mode: {0}" -f $receipt.producer_mode)
Write-Output ("- status: {0}" -f $receipt.status)
Write-Output ("- reason: {0}" -f $receipt.reason)
Write-Output ("- receipt_digest: {0}" -f $receipt.receipt_digest)
if ([string]$receipt.status -ceq 'fail') { exit 1 }
if ([string]$receipt.status -ceq 'unavailable') { exit 3 }
exit 0
