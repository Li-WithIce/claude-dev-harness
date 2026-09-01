[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$runtimeDirName = Convert-CodePointsToString @(36816, 34892, 26102)
$archiveStem = Convert-CodePointsToString @(35760, 24518, 20505, 36873, 24402, 26723)
$archiveFileName = "$archiveStem.md"
$runtimeArchiveTag = Convert-CodePointsToString @(36816, 34892, 26102, 44, 32, 35760, 24518, 20505, 36873, 24402, 26723)
$archiveDateHeader = Convert-CodePointsToString @(24402, 26723, 26085, 26399)
$typeHeader = Convert-CodePointsToString @(31867, 22411)
$contentSummaryHeader = Convert-CodePointsToString @(20869, 23481, 25688, 35201)
$resultHeader = Convert-CodePointsToString @(32467, 26524)
$targetReasonHeader = Convert-CodePointsToString @(30446, 26631, 20301, 32622, 32, 47, 32, 21407, 22240)
$notesHeader = Convert-CodePointsToString @(22791, 27880)
$legacyArchivePlaceholder = Convert-CodePointsToString @(26242, 26080, 24402, 26723, 35760, 24405)
$scratchRoot = Join-Path $RepoRoot ('tmp\memory-maintain-regression-' +
    [guid]::NewGuid().ToString('N'))
$checks = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

try {
New-Item -ItemType Directory -Path $scratchRoot | Out-Null

$caseRoot = Join-Path $scratchRoot 'fresh-install-maintain-pass'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$userProfile = Join-Path $caseRoot 'user'
New-Item -ItemType Directory -Path $workspaceRoot,$userProfile -Force | Out-Null

$installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
    VaultProfile  = 'full'
}

if ($installResult.ExitCode -ne 0) {
    $failures.Add('install.ps1 should succeed before memory-maintain smoke runs') | Out-Null
} else {
    $checks.Add('install.ps1 succeeds before memory-maintain smoke runs') | Out-Null
}

$maintainResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'scripts\memory-maintain.ps1') -WorkingDirectory $workspaceRoot
$maintainOutput = $maintainResult.Output -join [Environment]::NewLine

if ($maintainResult.ExitCode -ne 0) {
    $failures.Add('memory-maintain.ps1 should return exit code 0 when run from an installed workspace cwd') | Out-Null
} else {
    $checks.Add('memory-maintain.ps1 returns exit code 0 when run from an installed workspace cwd') | Out-Null
}

if ($maintainOutput -notmatch '(?im)^STATUS:\s+PASS\s*$') {
    $failures.Add('memory-maintain.ps1 should report STATUS: PASS for a fresh installed workspace') | Out-Null
} else {
    $checks.Add('memory-maintain.ps1 reports STATUS: PASS for a fresh installed workspace') | Out-Null
}

foreach ($stepName in @('archive')) {
    if ($maintainOutput -notmatch ("(?im)^- {0}:\s+PASS\s+\(exit=0\)\s*$" -f [regex]::Escape($stepName))) {
        $failures.Add(("memory-maintain.ps1 should report step {0}=PASS on a fresh installed workspace" -f $stepName)) | Out-Null
    } else {
        $checks.Add(("memory-maintain.ps1 reports step {0}=PASS on a fresh installed workspace" -f $stepName)) | Out-Null
    }
}
foreach ($stepName in @('repair','report','health')) {
    if ($maintainOutput -match ("(?im)^- {0}:\s+NOT_RUN\s+\(" -f $stepName)) {
        $checks.Add("memory-maintain reports $stepName as NOT_RUN, not a health/repair pass") | Out-Null
    } else { $failures.Add("memory-maintain must not run $stepName implicitly") | Out-Null }
}

$archivePath = Join-Path (Join-Path (Join-Path $workspaceRoot '.assistant') $runtimeDirName) $archiveFileName
$archiveContent = if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    Get-Content -LiteralPath $archivePath -Raw -Encoding utf8
} else {
    ''
}
$expectedArchiveHeader = "| ID | $archiveDateHeader | $typeHeader | $contentSummaryHeader | $resultHeader | $targetReasonHeader | $notesHeader |"
if ($archiveContent -notmatch [regex]::Escape($expectedArchiveHeader)) {
    $failures.Add('fresh install should create memory-candidate archive with the standard table header expected by archive-memory-candidates.ps1') | Out-Null
} else {
    $checks.Add('fresh install creates memory-candidate archive with the standard table header expected by archive-memory-candidates.ps1') | Out-Null
}

$legacyArchivePath = Join-Path (Join-Path (Join-Path $workspaceRoot '.assistant') $runtimeDirName) $archiveFileName
$legacyArchiveContent = @(
    '---'
    "tags: [$runtimeArchiveTag]"
    'created: 2026-04-03'
    'updated: 2026-04-03'
    '---'
    ''
    "# $archiveStem"
    ''
    "- $legacyArchivePlaceholder"
) -join "`r`n"
Set-Content -LiteralPath $legacyArchivePath -Value $legacyArchiveContent -Encoding utf8

$legacyMaintainResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'scripts\memory-maintain.ps1') -WorkingDirectory $workspaceRoot
$legacyMaintainOutput = $legacyMaintainResult.Output -join [Environment]::NewLine
$upgradedArchiveContent = Get-Content -LiteralPath $legacyArchivePath -Raw -Encoding utf8

if ($legacyMaintainResult.ExitCode -ne 0) {
    $failures.Add('memory-maintain.ps1 should succeed when an existing workspace still has the legacy archive placeholder format') | Out-Null
} else {
    $checks.Add('memory-maintain.ps1 succeeds when an existing workspace still has the legacy archive placeholder format') | Out-Null
}

if ($legacyMaintainOutput -notmatch '(?im)^STATUS:\s+PASS\s*$') {
    $failures.Add('memory-maintain.ps1 should still report STATUS: PASS after upgrading the legacy archive placeholder format') | Out-Null
} else {
    $checks.Add('memory-maintain.ps1 reports STATUS: PASS after upgrading the legacy archive placeholder format') | Out-Null
}

if ($upgradedArchiveContent -notmatch [regex]::Escape($expectedArchiveHeader)) {
    $failures.Add('memory-maintain.ps1 should upgrade the legacy archive placeholder format to the standard archive table') | Out-Null
} else {
    $checks.Add('memory-maintain.ps1 upgrades the legacy archive placeholder format to the standard archive table') | Out-Null
}

$vaultRoot = Join-Path $workspaceRoot '.assistant'
$historyPaths = @(
    '.assistant/运行时/当前任务.md', '.assistant/运行时/恢复索引.md',
    '.assistant/运行时/中断任务.md', '.assistant/运行时/上次会话.md',
    '.assistant/运行时/tasks/legacy-memory-history.md',
    '.assistant/orchestration/current-flow.md', 'docs/tasks/legacy-memory-history/plan.md'
) | ForEach-Object { Join-Path $workspaceRoot $_ }
foreach ($path in $historyPaths) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path,'immutable legacy history sentinel',[Text.UTF8Encoding]::new($false))
}
$beforeHistory = @($historyPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join '|'
$historyLocks = @($historyPaths | ForEach-Object { [IO.File]::Open($_,'Open','ReadWrite','None') })
try {
    foreach ($scriptPath in @('scripts/memory-maintain.ps1','skills/obsidian-memory/scripts/maintain-shared-memory.ps1')) {
        $lockedResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot $scriptPath) -Arguments @{VaultRoot=$vaultRoot} -WorkingDirectory $workspaceRoot
        if ($lockedResult.ExitCode -eq 0 -and ($lockedResult.Output -join "`n") -match 'Scope: optional-memory-archive') {
            $checks.Add("$scriptPath archives without reading locked history or invoking historical health") | Out-Null
        } else { $failures.Add("$scriptPath must succeed without reading locked history") | Out-Null }
    }
} finally { foreach ($handle in $historyLocks) { $handle.Dispose() } }
$afterHistory = @($historyPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join '|'
if ($beforeHistory -ceq $afterHistory -and -not (Test-Path -LiteralPath (Join-Path $vaultRoot '运行时/记忆体检报告.md'))) {
    $checks.Add('maintenance preserves all historical bytes and does not implicitly create a history report') | Out-Null
} else { $failures.Add('maintenance wrote history or an implicit report') | Out-Null }
} finally {
    try {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction Stop
    } catch {
        $failures.Add(("cleanup failed for {0}: {1}" -f $scratchRoot, $_.Exception.Message)) | Out-Null
    }
}

Write-Output 'Checks:'
if ($checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($check in $checks) {
        Write-Output ('- {0}' -f $check)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $failures) {
    Write-Output ('- {0}' -f $failure)
}

Write-Output ''
Write-Output 'Install Output:'
if ($installResult.Output.Count -eq 0) {
    Write-Output '- none'
} else {
    $installResult.Output | ForEach-Object { Write-Output ([string]$_) }
}

Write-Output ''
Write-Output 'Maintain Output:'
if ($maintainResult.Output.Count -eq 0) {
    Write-Output '- none'
} else {
    $maintainResult.Output | ForEach-Object { Write-Output ([string]$_) }
}

exit 1
