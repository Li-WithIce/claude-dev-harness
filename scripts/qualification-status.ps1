[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -ErrorAction Stop
    $qualification = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Qualification.psm1') -Force -PassThru -ErrorAction Stop
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot

    $profile = & $qualification { Get-HarnessRolloutV2ExpectedHost }
    $finalRelative = '.assistant/runtime/rollout/v2-eligibility.json'
    $candidateRelative = '.assistant/runtime/rollout/v2-canary-candidate.json'
    $authorizationRelative = '.assistant/runtime/rollout/v2-canary-authorization.json'
    $finalPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $finalRelative -Label 'qualification final report' -AllowMissing
    $candidatePath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $candidateRelative -Label 'qualification candidate report' -AllowMissing
    $authorizationPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $authorizationRelative -Label 'qualification authorization' -AllowMissing
    $reportRelative = if (Test-Path -LiteralPath $finalPath -PathType Leaf) { $finalRelative } elseif (Test-Path -LiteralPath $candidatePath -PathType Leaf) { $candidateRelative } else { '' }

    $reportStatus = 'missing'
    $reportReason = 'qualification-report-missing'
    $report = $null
    if (-not [string]::IsNullOrWhiteSpace($reportRelative)) {
        try {
            $report = & $qualification {
                param($Root,$Workspace,$Path)
                $document = Read-HarnessRolloutWorkspaceDocument -WorkspaceRoot $Workspace -Path $Path -Kind report
                Assert-HarnessRolloutReport -RepoRoot $Root -Document $document
                return $document
            } $RepoRoot $WorkspaceRoot $reportRelative
            $reportStatus = 'valid'
            $reportReason = 'qualification-report-valid'
        } catch {
            $reportStatus = 'invalid'
            $reportReason = [string]$_.Exception.Message
        }
    }

    Write-Output ("STATUS: {0}" -f $(if ($reportStatus -ceq 'valid') { 'AVAILABLE' } else { 'UNAVAILABLE' }))
    Write-Output ("RepoRoot: {0}" -f $RepoRoot)
    Write-Output ("WorkspaceRoot: {0}" -f $WorkspaceRoot)
    Write-Output 'qualification_profile: codex-exact-release'
    Write-Output ("host_product_expected: {0}" -f $profile.product)
    Write-Output ("host_version_expected: {0}" -f $profile.observed_version)
    Write-Output ("report_status: {0}" -f $reportStatus)
    Write-Output ("report_reason: {0}" -f $reportReason)
    Write-Output ("report_path: {0}" -f $(if ([string]::IsNullOrWhiteSpace($reportRelative)) { 'none' } else { $reportRelative }))
    Write-Output ("canary_authorization: {0}" -f $(if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) { 'present' } else { 'missing' }))
    if ($null -ne $report) {
        Write-Output ("report_phase: {0}" -f $report.phase)
        Write-Output ("evidence_provenance: {0}" -f $report.provenance_status)
        Write-Output ("review_receipt: {0}" -f $(if ($null -ne $report.review_receipt) { 'present' } else { 'missing' }))
        foreach ($name in @($report.gates.Keys | Sort-Object)) {
            Write-Output ("gate_{0}: {1}" -f $name, $report.gates[$name].status)
        }
    }
    exit $(if ($reportStatus -ceq 'valid') { 0 } else { 1 })
} catch {
    [Console]::Error.WriteLine('[QUALIFICATION-STATUS] UNAVAILABLE: ' + [string]$_.Exception.Message)
    exit 2
}
