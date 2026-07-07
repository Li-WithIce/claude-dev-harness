[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function C([int[]]$Points) {
    return (-join ($Points | ForEach-Object { [char]$_ }))
}

function Get-LastExitCodeOrZero {
    $variable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if ($null -ne $variable -and $variable.Value -is [int]) {
        return $variable.Value
    }

    return 0
}

function Invoke-RepoScript {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [hashtable]$Arguments = @{},
        [string]$WorkingDirectory = ''
    )

    $originalUserProfile = $env:USERPROFILE
    $originalLocation = $null
    try {
        $env:USERPROFILE = $UserProfile
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $originalLocation = (Get-Location).Path
            Set-Location -LiteralPath $WorkingDirectory
        }

        $output = @(& $ScriptPath @Arguments 2>&1)
        return [pscustomobject]@{
            Output   = @($output | ForEach-Object { [string]$_ })
            ExitCode = (Get-LastExitCodeOrZero)
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($originalLocation)) {
            Set-Location -LiteralPath $originalLocation
        }
        $env:USERPROFILE = $originalUserProfile
    }
}

function Get-PowerShellHostPath {
    try {
        $currentHostPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not [string]::IsNullOrWhiteSpace($currentHostPath) -and (Test-Path -LiteralPath $currentHostPath -PathType Leaf)) {
            return (Get-NormalizedPath -Path $currentHostPath)
        }
    } catch {
        # Fall through to explicit discovery.
    }

    foreach ($commandName in @('pwsh', 'powershell.exe')) {
        try {
            $command = Get-Command $commandName -ErrorAction Stop | Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($command.Source)) {
                return (Get-NormalizedPath -Path $command.Source)
            }
        } catch {
            # Try the next candidate.
        }
    }

    throw 'Unable to locate a PowerShell host executable for verify-archive-memory-candidates.ps1'
}

function Invoke-RepoScriptFreshHost {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [hashtable]$Arguments = @{}
    )

    $hostPath = Get-PowerShellHostPath
    $argumentList = @('-NoProfile')
    if ((Split-Path -Leaf $hostPath) -ieq 'powershell.exe') {
        $argumentList += @('-ExecutionPolicy', 'Bypass')
    }
    $argumentList += @('-File', $ScriptPath)
    foreach ($entry in $Arguments.GetEnumerator()) {
        $argumentList += ('-{0}' -f [string]$entry.Key)
        if ($entry.Value -is [System.Array] -and -not ($entry.Value -is [string])) {
            foreach ($value in $entry.Value) {
                $argumentList += [string]$value
            }
            continue
        }

        $argumentList += [string]$entry.Value
    }

    $originalUserProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $UserProfile
        $output = @(& $hostPath @argumentList 2>&1)
        return [pscustomobject]@{
            Output   = @($output | ForEach-Object { [string]$_ })
            ExitCode = (Get-LastExitCodeOrZero)
        }
    } finally {
        $env:USERPROFILE = $originalUserProfile
    }
}

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
$runtimeDirName = C @(36816, 34892, 26102)
$candidateStem = C @(35760, 24518, 20505, 36873)
$archiveStem = C @(35760, 24518, 20505, 36873, 24402, 26723)
$candidateFileName = "$candidateStem.md"
$archiveFileName = "$archiveStem.md"
$runtimeTag = C @(36816, 34892, 26102)
$memoryTag = C @(35760, 24518)
$archiveTag = C @(24402, 26723)
$dateHeader = C @(26085, 26399)
$typeHeader = C @(31867, 22411)
$contentSummaryHeader = C @(20869, 23481, 25688, 35201)
$suggestedWriteHeader = C @(24314, 35758, 20889, 20837)
$sourceHeader = C @(26469, 28304)
$statusHeader = C @(29366, 24577)
$userConfirmHeader = C @(29992, 25143, 30830, 35748)
$archiveDateHeader = C @(24402, 26723, 26085, 26399)
$resultHeader = C @(32467, 26524)
$targetReasonHeader = C @(30446, 26631, 20301, 32622, 32, 47, 32, 21407, 22240)
$notesHeader = C @(22791, 27880)
$configPreferencePath = ((C @(37197, 32622, 47, 29992, 25143, 20559, 22909)) + '.md')
$candidateEmptySummary = C @(24403, 21069, 26242, 26080, 20505, 36873, 39033)
$archiveEmptySummary = C @(24403, 21069, 26242, 26080, 24402, 26723, 39033)
$noneText = C @(26080)
$scratchRoot = Join-Path $RepoRoot 'tmp\archive-memory-candidates-regression'
if (Test-Path -LiteralPath $scratchRoot) {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $scratchRoot | Out-Null

$caseRoot = Join-Path $scratchRoot 'wrapper-forwarding-and-header-only-archive'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$userProfile = Join-Path $caseRoot 'user'
New-Item -ItemType Directory -Path $workspaceRoot,$userProfile -Force | Out-Null

$installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}
if ($installResult.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before archive-memory-candidates wrapper regression runs'
} else {
    Add-Check 'install.ps1 succeeds before archive-memory-candidates wrapper regression runs'
}

$candidatePath = Join-Path (Join-Path (Join-Path $workspaceRoot '.assistant') $runtimeDirName) $candidateFileName
$archivePath = Join-Path (Join-Path (Join-Path $workspaceRoot '.assistant') $runtimeDirName) $archiveFileName

$candidateContent = @(
    '---'
    "tags: [$runtimeTag, $memoryTag, $candidateStem]"
    'created: 2026-04-03'
    'updated: 2026-04-03'
    '---'
    ''
    "# $candidateStem"
    ''
    "| ID | $dateHeader | $typeHeader | $contentSummaryHeader | $suggestedWriteHeader | $sourceHeader | $statusHeader | $userConfirmHeader | created |"
    '|----|------|------|----------|----------|------|------|----------|---------|'
    "| memory-001 | 2026-04-03 | preference | remember terminal status | $configPreferencePath | manual | promoted | confirmed | 2026-04-03 12:00:00 |"
) -join "`r`n"
$archiveContent = @(
    '---'
    "tags: [$runtimeTag, $memoryTag, $archiveTag]"
    'created: 2026-04-03'
    'updated: 2026-04-03'
    '---'
    ''
    "# $archiveStem"
    ''
    "| ID | $archiveDateHeader | $typeHeader | $contentSummaryHeader | $resultHeader | $targetReasonHeader | $notesHeader |"
    '|----|----------|------|----------|------|------------------|------|'
) -join "`r`n"
Set-Content -LiteralPath $candidatePath -Value $candidateContent -Encoding utf8
Set-Content -LiteralPath $archivePath -Value $archiveContent -Encoding utf8

$archiveResult = Invoke-RepoScriptFreshHost -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'scripts\archive-memory-candidates.ps1') -Arguments @{
    VaultRoot        = (Join-Path $workspaceRoot '.assistant')
    TerminalStatuses = @('promoted')
}
$archiveOutput = $archiveResult.Output -join [Environment]::NewLine
$candidateAfter = Get-Content -LiteralPath $candidatePath -Raw -Encoding utf8
$archiveAfter = Get-Content -LiteralPath $archivePath -Raw -Encoding utf8

if ($archiveResult.ExitCode -ne 0) {
    Add-Failure 'archive-memory-candidates wrapper should forward named parameters to the underlying script and return exit code 0'
} else {
    Add-Check 'archive-memory-candidates wrapper forwards named parameters to the underlying script and returns exit code 0'
}

if ($archiveOutput -notmatch '(?im)^STATUS:\s+PASS\s*$') {
    Add-Failure 'archive-memory-candidates wrapper should report STATUS: PASS after archiving a promoted candidate'
} else {
    Add-Check 'archive-memory-candidates wrapper reports STATUS: PASS after archiving a promoted candidate'
}

if ($archiveOutput -notmatch '(?im)^Archived:\s+1\s*$') {
    Add-Failure 'archive-memory-candidates wrapper should report Archived: 1 after moving one terminal candidate'
} else {
    Add-Check 'archive-memory-candidates wrapper reports Archived: 1 after moving one terminal candidate'
}

if ($candidateAfter -notmatch [regex]::Escape("| $noneText | - | - | $candidateEmptySummary | - | - | - | - | - |")) {
    Add-Failure 'archive-memory-candidates should restore the standard placeholder row when the candidate table becomes empty'
} else {
    Add-Check 'archive-memory-candidates restores the standard placeholder row when the candidate table becomes empty'
}

if ($archiveAfter -notmatch [regex]::Escape('| memory-001 |')) {
    Add-Failure 'archive-memory-candidates should append archived rows even when the archive table previously had only header and divider'
} else {
    Add-Check 'archive-memory-candidates appends archived rows when the archive table previously had only header and divider'
}

if ($archiveAfter -match [regex]::Escape("| $noneText | - | - | $archiveEmptySummary | - | - | - |")) {
    Add-Failure 'archive-memory-candidates should not leave the archive placeholder row behind once a real archived row exists'
} else {
    Add-Check 'archive-memory-candidates removes the archive placeholder row once a real archived row exists'
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
