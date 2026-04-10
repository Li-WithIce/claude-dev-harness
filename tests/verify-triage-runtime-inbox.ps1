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

function Convert-CodePointsToString {
    param([int[]]$CodePoints)

    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
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

    throw 'Unable to locate a PowerShell host executable for verify-triage-runtime-inbox.ps1'
}

function Invoke-TriageInbox {
    param(
        [string]$VaultRoot,
        [hashtable]$Arguments = @{}
    )

    $scriptPath = Join-Path $RepoRoot 'scripts\triage-runtime-inbox.ps1'
    $hostPath = Get-PowerShellHostPath
    $argumentList = @('-NoProfile')
    if ((Split-Path -Leaf $hostPath) -ieq 'powershell.exe') {
        $argumentList += @('-ExecutionPolicy', 'Bypass')
    }
    $argumentList += @(
        '-File', $scriptPath,
        '-VaultRoot', $VaultRoot
    )
    foreach ($entry in $Arguments.GetEnumerator()) {
        $argumentList += ('-{0}' -f [string]$entry.Key)
        if ($entry.Value -is [bool]) {
            if (-not [bool]$entry.Value) {
                $argumentList = $argumentList[0..($argumentList.Count - 2)]
            }
            continue
        }

        $argumentList += [string]$entry.Value
    }

    $output = @(& $hostPath @argumentList 2>&1)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        Output   = @($output | ForEach-Object { [string]$_ })
        ExitCode = $exitCode
    }
}

function Invoke-NestedSkillTriage {
    param(
        [string]$VaultRoot,
        [hashtable]$Arguments = @{}
    )

    $scriptPath = Join-Path $RepoRoot 'skills\obsidian-memory\scripts\triage-runtime-inbox.ps1'
    $originalNestedMode = $env:CDH_OBSIDIAN_MEMORY_NESTED
    try {
        $env:CDH_OBSIDIAN_MEMORY_NESTED = '1'
        $invokeArgs = @{
            VaultRoot = $VaultRoot
        }
        foreach ($entry in $Arguments.GetEnumerator()) {
            $invokeArgs[[string]$entry.Key] = $entry.Value
        }

        $output = @(& $scriptPath @invokeArgs 2>&1)
        return [pscustomobject]@{
            Output = @($output | ForEach-Object { [string]$_ })
        }
    } finally {
        $env:CDH_OBSIDIAN_MEMORY_NESTED = $originalNestedMode
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$tmpRoot = Join-Path $RepoRoot 'tmp\runtime-inbox-triage-regression'
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$runtimeDirName = Convert-CodePointsToString -CodePoints @(36816, 34892, 26102)
$inboxFileName = Convert-CodePointsToString -CodePoints @(25910, 20214, 31665, 46, 109, 100)
$fullWidthPipe = [string][char]0xFF5C

$caseRoot = Join-Path $tmpRoot 'triage-runtime-inbox'
if (Test-Path -LiteralPath $caseRoot) {
    Remove-Item -LiteralPath $caseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
$vaultRoot = Join-Path $caseRoot '.assistant'
$runtimeDir = Join-Path $vaultRoot $runtimeDirName
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
$inboxPath = Join-Path $runtimeDir $inboxFileName

$initialContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-04-03'
    'updated: 2026-04-03 08:00:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    '| 2026-04-03 08:00:00 | claude-posttooluse | sample-task | lock-blocked | open | Recovery-index refresh blocked by runtime lock. | Shared runtime lock is held by other-writer for task sample-task. |'
    ("| 2026-04-03 08:05:00 | manual-test | sample-task | inbox-first | open | Need pipe {0} triage <br> and newline | payload line 1 <br> payload {0} line 2 |" -f $fullWidthPipe)
    '| 2026-04-03 08:10:00 | manual-test | sample-task | inbox-first | open | Need more routing context | user asked to revisit this later |'
) -join "`r`n"
Set-Content -LiteralPath $inboxPath -Value $initialContent -Encoding utf8

$listResult = Invoke-TriageInbox -VaultRoot $vaultRoot -Arguments @{ List = $true }
if ($listResult.ExitCode -ne 0) {
    Add-Failure 'triage-runtime-inbox should return exit code 0 when listing active inbox items'
} else {
    Add-Check 'triage-runtime-inbox returns exit code 0 when listing active inbox items'
}

$listOutputText = $listResult.Output -join "`n"
if ($listOutputText -notmatch 'OpenItems:\s+3') {
    Add-Failure 'triage-runtime-inbox should report the number of active inbox items when listing'
} else {
    Add-Check 'triage-runtime-inbox reports the number of active inbox items when listing'
}

if (
    $listOutputText -notmatch 'created_at=2026-04-03 08:05:00;\s*source=manual-test;\s*task_id=sample-task;\s*type=inbox-first;\s*status=open;\s*summary=Need pipe' -or
    $listOutputText -notmatch 'and newline'
) {
    Add-Failure 'triage-runtime-inbox should include inbox-first rows in list mode'
} else {
    Add-Check 'triage-runtime-inbox includes inbox-first rows in list mode'
}

$ambiguousBefore = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
$ambiguousResult = Invoke-TriageInbox `
    -VaultRoot $vaultRoot `
    -Arguments @{
        Type      = 'inbox-first'
        SetStatus = 'cleared'
    }
$ambiguousAfter = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
if ($ambiguousResult.ExitCode -eq 0) {
    Add-Failure 'triage-runtime-inbox should require narrower selectors when multiple active rows match'
} else {
    Add-Check 'triage-runtime-inbox requires narrower selectors when multiple active rows match'
}

$ambiguousOutputText = $ambiguousResult.Output -join "`n"
if ($ambiguousOutputText -notmatch [regex]::Escape('Matched 2 active runtime inbox rows; narrow the selectors or add -ResolveAllMatches.')) {
    Add-Failure 'triage-runtime-inbox should explain ambiguous matches'
} else {
    Add-Check 'triage-runtime-inbox explains ambiguous matches'
}

if ($ambiguousBefore -ne $ambiguousAfter) {
    Add-Failure 'triage-runtime-inbox should leave the inbox file unchanged when matches are ambiguous'
} else {
    Add-Check 'triage-runtime-inbox leaves the inbox file unchanged when matches are ambiguous'
}

$nestedBefore = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
$nestedResult = Invoke-NestedSkillTriage `
    -VaultRoot $vaultRoot `
    -Arguments @{
        SetStatus = 'cleared'
    }
$nestedAfter = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
$nestedOutputText = $nestedResult.Output -join "`n"
if ($nestedOutputText -notmatch '(?im)^STATUS:\s+FAIL\s*$') {
    Add-Failure 'triage-runtime-inbox nested mode should still emit STATUS: FAIL when required selectors are missing'
} else {
    Add-Check 'triage-runtime-inbox nested mode emits STATUS: FAIL when required selectors are missing'
}

if ($nestedOutputText -match '(?im)^STATUS:\s+(WARN|PASS)\s*$') {
    Add-Failure 'triage-runtime-inbox nested mode should stop after the first FAIL/WARN status instead of continuing into later branches'
} else {
    Add-Check 'triage-runtime-inbox nested mode stops after the first FAIL/WARN status instead of continuing into later branches'
}

if ($nestedBefore -ne $nestedAfter) {
    Add-Failure 'triage-runtime-inbox nested mode should leave the inbox file unchanged after a selector validation failure'
} else {
    Add-Check 'triage-runtime-inbox nested mode leaves the inbox file unchanged after a selector validation failure'
}

$resolveResult = Invoke-TriageInbox `
    -VaultRoot $vaultRoot `
    -Arguments @{
        CreatedAt      = '2026-04-03 08:05:00'
        Type           = 'inbox-first'
        SetStatus      = 'cleared'
        ResolutionNote = 'Promoted into the clarified workflow plan.'
    }
$resolvedContent = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
if ($resolveResult.ExitCode -ne 0) {
    Add-Failure 'triage-runtime-inbox should return exit code 0 when resolving a uniquely matched inbox item'
} else {
    Add-Check 'triage-runtime-inbox returns exit code 0 when resolving a uniquely matched inbox item'
}

if ($resolvedContent -notmatch '\|\s*2026-04-03 08:05:00\s*\|\s*manual-test\s*\|\s*sample-task\s*\|\s*inbox-first\s*\|\s*cleared\s*\|') {
    Add-Failure 'triage-runtime-inbox should update the matched row status'
} else {
    Add-Check 'triage-runtime-inbox updates the matched row status'
}

if ($resolvedContent -notmatch [regex]::Escape('resolution: Promoted into the clarified workflow plan.')) {
    Add-Failure 'triage-runtime-inbox should append the resolution note into the payload'
} else {
    Add-Check 'triage-runtime-inbox appends the resolution note into the payload'
}

$literalCaseRoot = Join-Path $tmpRoot 'triage-runtime-inbox-literal-summary'
if (Test-Path -LiteralPath $literalCaseRoot) {
    Remove-Item -LiteralPath $literalCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $literalCaseRoot -Force | Out-Null
$literalVaultRoot = Join-Path $literalCaseRoot '.assistant'
$literalRuntimeDir = Join-Path $literalVaultRoot $runtimeDirName
New-Item -ItemType Directory -Path $literalRuntimeDir -Force | Out-Null
$literalInboxPath = Join-Path $literalRuntimeDir $inboxFileName

$literalContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-04-03'
    'updated: 2026-04-03 09:00:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    '| 2026-04-03 09:00:00 | manual-test | task-a | inbox-first | open | Need [docs] follow-up | payload a |'
    '| 2026-04-03 09:01:00 | manual-test | task-b | inbox-first | open | Need d follow-up | payload b |'
) -join "`r`n"
Set-Content -LiteralPath $literalInboxPath -Value $literalContent -Encoding utf8

$literalResult = Invoke-TriageInbox `
    -VaultRoot $literalVaultRoot `
    -Arguments @{
        SummaryContains = '[docs]'
        SetStatus       = 'cleared'
    }
$literalOutputText = $literalResult.Output -join "`n"
$literalUpdatedContent = Get-Content -LiteralPath $literalInboxPath -Raw -Encoding utf8

if ($literalResult.ExitCode -ne 0) {
    Add-Failure 'triage-runtime-inbox should treat SummaryContains as a literal substring and resolve a unique row containing square brackets'
} else {
    Add-Check 'triage-runtime-inbox treats SummaryContains as a literal substring and resolves a unique row containing square brackets'
}

if ($literalOutputText -notmatch '(?im)^ResolvedItems:\s+1\s*$') {
    Add-Failure 'triage-runtime-inbox should resolve exactly one row when SummaryContains includes literal wildcard-like characters'
} else {
    Add-Check 'triage-runtime-inbox resolves exactly one row when SummaryContains includes literal wildcard-like characters'
}

if ($literalUpdatedContent -notmatch '\|\s*2026-04-03 09:00:00\s*\|\s*manual-test\s*\|\s*task-a\s*\|\s*inbox-first\s*\|\s*cleared\s*\|\s*Need \[docs\] follow-up\s*\|') {
    Add-Failure 'triage-runtime-inbox should clear the row whose summary literally contains [docs]'
} else {
    Add-Check 'triage-runtime-inbox clears the row whose summary literally contains [docs]'
}

if ($literalUpdatedContent -notmatch '\|\s*2026-04-03 09:01:00\s*\|\s*manual-test\s*\|\s*task-b\s*\|\s*inbox-first\s*\|\s*open\s*\|\s*Need d follow-up\s*\|') {
    Add-Failure 'triage-runtime-inbox should leave non-matching rows untouched when SummaryContains includes literal wildcard-like characters'
} else {
    Add-Check 'triage-runtime-inbox leaves non-matching rows untouched when SummaryContains includes literal wildcard-like characters'
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
