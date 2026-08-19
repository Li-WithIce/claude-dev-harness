[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][string]$RepositoryFullName,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$PullRequestNumber,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,18}$')][string]$RunId,
    [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,18}$')][string]$ReviewCommentId,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('formal','test-only')][string]$ProducerMode = 'formal',
    [AllowEmptyString()][string]$GitHubFixtureRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$module = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
$report = & $module {
    param($Root,$Repository,$PullRequest,$WorkflowRun,$ReviewComment,$Output,$Mode,$Fixtures)
    New-ExactHeadEngineeringEvidenceArtifact -RepoRoot $Root -RepositoryFullName $Repository -PullRequestNumber $PullRequest -RunId $WorkflowRun -ReviewCommentId $ReviewComment -OutputPath $Output -ProducerMode $Mode -GitHubFixtureRoot $Fixtures
} $RepoRoot $RepositoryFullName $PullRequestNumber ([long]$RunId) ([long]$ReviewCommentId) $OutputPath $ProducerMode $GitHubFixtureRoot

Write-Output 'Exact-head engineering evidence summary:'
Write-Output ("- producer_mode: {0}" -f $report.producer_mode)
Write-Output ("- status: {0}" -f $report.status)
Write-Output ("- reason: {0}" -f $report.reason)
Write-Output ("- report_digest: {0}" -f $report.report_digest)
if ([string]$report.status -ceq 'fail') { exit 1 }
if ([string]$report.status -ceq 'unavailable') { exit 3 }
exit 0
