[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][string]$ModelProducerObservationPath,
    [Parameter(Mandatory)][string]$HostProducerObservationPath,
    [Parameter(Mandatory)][string]$AggregatorObservationPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('formal','test-only','diagnostic-smoke')][string]$ProducerMode = 'formal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$module = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
$report = & $module {
    param($Root,$Model,$Host,$Aggregator,$Output,$Mode)
    New-ReleaseIsolationReportArtifact -RepoRoot $Root -ModelProducerObservationPath $Model -HostProducerObservationPath $Host -AggregatorObservationPath $Aggregator -OutputPath $Output -ProducerMode $Mode
} $RepoRoot $ModelProducerObservationPath $HostProducerObservationPath $AggregatorObservationPath $OutputPath $ProducerMode

Write-Output 'Release isolation qualification summary:'
Write-Output ("- producer_mode: {0}" -f $report.producer_mode)
Write-Output ("- status: {0}" -f $report.status)
Write-Output ("- reason: {0}" -f $report.reason)
Write-Output ("- report_digest: {0}" -f $report.report_digest)
if ([string]$report.status -ceq 'fail') { exit 1 }
exit 0
