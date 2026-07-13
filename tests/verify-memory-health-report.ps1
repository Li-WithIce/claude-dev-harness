[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$runtimeDirName = Convert-CodePointsToString @(36816, 34892, 26102)
$memoryHealthReportFileName = ((Convert-CodePointsToString @(35760, 24518, 20307, 26816, 25253, 21578)) + '.md')
$scratchRoot = Join-Path $RepoRoot ('tmp\memory-health-report-regression-' + [guid]::NewGuid().ToString('N'))

try {
New-Item -ItemType Directory -Path $scratchRoot | Out-Null

$healthyCaseRoot = Join-Path $scratchRoot 'healthy-custom-output'
$healthyWorkspace = Join-Path $healthyCaseRoot 'workspace'
$healthyUser = Join-Path $healthyCaseRoot 'user'
New-Item -ItemType Directory -Path $healthyWorkspace,$healthyUser -Force | Out-Null

$installResult = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $healthyWorkspace
    RepoRoot      = $RepoRoot
    VaultProfile  = 'full'
}
if ($installResult.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before memory-health-report smoke runs'
} else {
    Add-Check 'install.ps1 succeeds before memory-health-report smoke runs'
}

$healthyReportPath = Join-Path $healthyWorkspace 'reports\health\memory-health.md'
$healthyReportResult = Invoke-RepoScript -UserProfile $healthyUser -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health-report.ps1') -Arguments @{
    OutputPath = $healthyReportPath
} -WorkingDirectory $healthyWorkspace
$healthyReportOutput = $healthyReportResult.Output -join [Environment]::NewLine
$healthyReportContent = if (Test-Path -LiteralPath $healthyReportPath -PathType Leaf) {
    Get-Content -LiteralPath $healthyReportPath -Raw -Encoding utf8
} else {
    ''
}

if ($healthyReportResult.ExitCode -ne 0) {
    Add-Failure 'memory-health-report.ps1 should return exit code 0 for a healthy installed workspace'
} else {
    Add-Check 'memory-health-report.ps1 returns exit code 0 for a healthy installed workspace'
}

if ($healthyReportOutput -notmatch '(?im)^STATUS:\s+PASS\s*$') {
    Add-Failure 'memory-health-report.ps1 should report STATUS: PASS for a healthy installed workspace'
} else {
    Add-Check 'memory-health-report.ps1 reports STATUS: PASS for a healthy installed workspace'
}

if (-not (Test-Path -LiteralPath $healthyReportPath -PathType Leaf)) {
    Add-Failure 'memory-health-report.ps1 should create missing parent directories for a custom OutputPath'
} else {
    Add-Check 'memory-health-report.ps1 creates missing parent directories for a custom OutputPath'
}

if ($healthyReportContent -notmatch [regex]::Escape('## Raw Output')) {
    Add-Failure 'memory-health-report.ps1 should write the generated report content to the custom OutputPath'
} else {
    Add-Check 'memory-health-report.ps1 writes the generated report content to the custom OutputPath'
}

$failingCaseRoot = Join-Path $scratchRoot 'failing-vault-status'
$failingVaultRoot = Join-Path $failingCaseRoot '.assistant'
New-Item -ItemType Directory -Path (Join-Path $failingVaultRoot $runtimeDirName) -Force | Out-Null
$failingUser = Join-Path $failingCaseRoot 'user'
New-Item -ItemType Directory -Path $failingUser -Force | Out-Null

$failingReportResult = Invoke-RepoScript -UserProfile $failingUser -ScriptPath (Join-Path $RepoRoot 'scripts\memory-health-report.ps1') -Arguments @{
    VaultRoot = $failingVaultRoot
}
$failingReportOutput = $failingReportResult.Output -join [Environment]::NewLine
$failingReportPath = Join-Path (Join-Path $failingVaultRoot $runtimeDirName) $memoryHealthReportFileName
$failingReportContent = if (Test-Path -LiteralPath $failingReportPath -PathType Leaf) {
    Get-Content -LiteralPath $failingReportPath -Raw -Encoding utf8
} else {
    ''
}

if ($failingReportResult.ExitCode -ne 2) {
    Add-Failure 'memory-health-report.ps1 should propagate a failing checker exit code when shared memory is invalid'
} else {
    Add-Check 'memory-health-report.ps1 propagates a failing checker exit code when shared memory is invalid'
}

if ($failingReportOutput -notmatch '(?im)^STATUS:\s+FAIL\s*$') {
    Add-Failure 'memory-health-report.ps1 should report STATUS: FAIL when check-shared-memory.ps1 fails'
} else {
    Add-Check 'memory-health-report.ps1 reports STATUS: FAIL when check-shared-memory.ps1 fails'
}

if ($failingReportOutput -notmatch '(?im)^SourceExitCode:\s+2\s*$') {
    Add-Failure 'memory-health-report.ps1 should report the checker exit code in its output'
} else {
    Add-Check 'memory-health-report.ps1 reports the checker exit code in its output'
}

if (-not (Test-Path -LiteralPath $failingReportPath -PathType Leaf)) {
    Add-Failure 'memory-health-report.ps1 should still write a report file when the checker fails'
} else {
    Add-Check 'memory-health-report.ps1 still writes a report file when the checker fails'
}

if ($failingReportContent -notmatch [regex]::Escape('- **status**: FAIL')) {
    Add-Failure 'memory-health-report.ps1 should persist the failing checker status into the generated report'
} else {
    Add-Check 'memory-health-report.ps1 persists the failing checker status into the generated report'
}

if ((Test-FileHasUtf8Bom -Path $healthyReportPath) -and (Test-FileHasUtf8Bom -Path $failingReportPath)) {
    Add-Check 'memory-health-report.ps1 writes healthy and failing reports as UTF-8 with BOM'
} else {
    Add-Failure 'memory-health-report.ps1 should write healthy and failing reports as UTF-8 with BOM'
}
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ('- {0}' -f $item)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ('- {0}' -f $failure)
}

exit 1
