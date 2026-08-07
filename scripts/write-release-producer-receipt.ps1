[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][ValidateSet('model','host')][string]$Kind,
    [Parameter(Mandatory)][string]$RunnerObservationPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][int]$RunAttempt,
    [Parameter(Mandatory)][string]$CheckoutSha,
    [Parameter(Mandatory)][ValidateSet('success','failure','neutral','cancelled','skipped','timed_out','action_required','stale','startup_failure')][string]$Conclusion,
    [ValidateSet('formal','test-only')][string]$ProducerMode = 'formal',
    [string]$ModelReportPath = '',
    [string]$CognitiveHostReportPath = '',
    [string]$InstalledDesktopPrimaryReportPath = '',
    [string]$InstalledDesktopDistinctReportPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$module = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
$receipt = & $module {
    param($Root,$ReceiptKind,$Observation,$Output,$WorkflowRun,$Attempt,$Checkout,$JobConclusion,$Mode,$Model,$Cognitive,$InstalledPrimary,$InstalledDistinct)
    New-ReleaseProducerReceiptArtifact -RepoRoot $Root -Kind $ReceiptKind -RunnerObservationPath $Observation -OutputPath $Output `
        -RunId $WorkflowRun -RunAttempt $Attempt -CheckoutSha $Checkout -Conclusion $JobConclusion -ProducerMode $Mode `
        -ModelReportPath $Model -CognitiveHostReportPath $Cognitive -InstalledDesktopPrimaryReportPath $InstalledPrimary -InstalledDesktopDistinctReportPath $InstalledDistinct
} $RepoRoot $Kind $RunnerObservationPath $OutputPath $RunId $RunAttempt $CheckoutSha $Conclusion $ProducerMode $ModelReportPath $CognitiveHostReportPath $InstalledDesktopPrimaryReportPath $InstalledDesktopDistinctReportPath

Write-Output ("Release {0} producer receipt summary:" -f $Kind)
Write-Output ("- producer_mode: {0}" -f $receipt.producer_mode)
Write-Output ("- status: {0}" -f $receipt.status)
Write-Output ("- reason: {0}" -f $receipt.reason)
Write-Output ("- receipt_digest: {0}" -f $receipt.receipt_digest)
if ([string]$receipt.status -ceq 'fail') { exit 1 }
exit 0
