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
        '-File', $scriptPath
    )
    if (-not [string]::IsNullOrWhiteSpace($VaultRoot)) {
        $argumentList += @('-VaultRoot', $VaultRoot)
    }
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

function Get-TriageListEnvelope {
    param([pscustomobject]$Result)

    $jsonLine = @($Result.Output | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
        return $null
    }
    try {
        return ($jsonLine | ConvertFrom-Json)
    } catch {
        return $null
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$tmpRoot = Join-Path $RepoRoot ('tmp\runtime-inbox-triage-regression-' +
    [guid]::NewGuid().ToString('N'))
try {
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$runtimeDirName = Convert-CodePointsToString -CodePoints @(36816, 34892, 26102)
$inboxFileName = Convert-CodePointsToString -CodePoints @(25910, 20214, 31665, 46, 109, 100)
$fullWidthPipe = [string][char]0xFF5C

$invalidSelectorWorkspace = Join-Path $tmpRoot 'invalid-selector-zero-write'
if (Test-Path -LiteralPath $invalidSelectorWorkspace) {
    Remove-Item -LiteralPath $invalidSelectorWorkspace -Recurse -Force
}
New-Item -ItemType Directory -Path $invalidSelectorWorkspace -Force | Out-Null
$invalidSelectorResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{
    WorkspaceRoot = $invalidSelectorWorkspace
    RowId         = 'ROW-not-valid'
}
$invalidRouteResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{
    WorkspaceRoot = $invalidSelectorWorkspace
    RouteTaskId   = 'unknown'
}
$missingSelectorResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{
    WorkspaceRoot = $invalidSelectorWorkspace
}
if ($invalidSelectorResult.ExitCode -eq 0 -or
    ($invalidSelectorResult.Output -join "`n") -notmatch 'RowId must match' -or
    $invalidRouteResult.ExitCode -eq 0 -or
    ($invalidRouteResult.Output -join "`n") -notmatch 'RouteTaskId must be a canonical task id' -or
    $missingSelectorResult.ExitCode -eq 0 -or
    ($missingSelectorResult.Output -join "`n") -notmatch 'At least one selector is required' -or
    @(Get-ChildItem -LiteralPath $invalidSelectorWorkspace -Force).Count -ne 0) {
    Add-Failure 'invalid or missing selectors should fail before root resolution, mutex acquisition, or any workspace write'
} else {
    Add-Check 'invalid or missing selectors fail before root resolution, mutex acquisition, or any workspace write'
}

$freshListResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{
    WorkspaceRoot = $invalidSelectorWorkspace
    List          = $true
}
$freshListEnvelope = Get-TriageListEnvelope -Result $freshListResult
$freshNoMatchResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{
    WorkspaceRoot = $invalidSelectorWorkspace
    RowId         = ('row-' + ('a' * 60))
}
if ($freshListResult.ExitCode -ne 0 -or
    $null -eq $freshListEnvelope -or
    @($freshListEnvelope.open_items).Count -ne 0 -or
    $freshListResult.Output[-1] -cne 'STATUS: PASS' -or
    $freshNoMatchResult.ExitCode -eq 0 -or
    ($freshNoMatchResult.Output -join "`n") -notmatch 'Matched 0 active runtime inbox rows' -or
    @(Get-ChildItem -LiteralPath $invalidSelectorWorkspace -Force).Count -ne 0) {
    Add-Failure 'fresh list should return an empty PASS envelope and a no-match update should fail without creating inbox state'
} else {
    Add-Check 'fresh list returns an empty PASS envelope and a no-match update fails without creating inbox state'
}

$fakeUserProfile = Join-Path $tmpRoot 'fake-user-profile'
$agentHomeVault = Join-Path $fakeUserProfile '.codex\parallel-runtime\.assistant'
New-Item -ItemType Directory -Path $agentHomeVault -Force | Out-Null
$savedUserProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $fakeUserProfile
    $agentHomeResult = Invoke-TriageInbox -VaultRoot $agentHomeVault -Arguments @{
        RowId = ('row-' + ('b' * 60))
    }
} finally {
    $env:USERPROFILE = $savedUserProfile
}
if ($agentHomeResult.ExitCode -eq 0 -or
    ($agentHomeResult.Output -join "`n") -notmatch '\[vault-layer-violation\]' -or
    @(Get-ChildItem -LiteralPath $agentHomeVault -Force).Count -ne 0) {
    Add-Failure 'a fresh vault under a user-level agent home should be rejected before runtime creation'
} else {
    Add-Check 'a fresh vault under a user-level agent home is rejected before runtime creation'
}

$junctionCaseRoot = Join-Path $tmpRoot 'workspace-vault-junction-zero-write'
$junctionWorkspace = Join-Path $junctionCaseRoot 'workspace'
$junctionExternalVault = Join-Path $junctionCaseRoot 'external-vault'
$junctionPath = Join-Path $junctionWorkspace '.assistant'
if (Test-Path -LiteralPath $junctionPath) {
    [System.IO.Directory]::Delete($junctionPath)
}
if (Test-Path -LiteralPath $junctionCaseRoot) {
    Remove-Item -LiteralPath $junctionCaseRoot -Recurse -Force
}
$junctionExternalRuntime = Join-Path $junctionExternalVault $runtimeDirName
$junctionExternalInbox = Join-Path $junctionExternalRuntime $inboxFileName
New-Item -ItemType Directory -Path $junctionWorkspace,$junctionExternalRuntime -Force | Out-Null
$junctionInboxContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-07-11'
    'updated: 2026-07-11 12:00:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    '| 2026-07-11 12:00:00 | junction-test | unknown | junction-test | open | must remain external | external bytes |'
) -join "`r`n"
Set-Content -LiteralPath $junctionExternalInbox -Value $junctionInboxContent -Encoding utf8
New-Item -ItemType Junction -Path $junctionPath -Target $junctionExternalVault | Out-Null
$junctionBefore = Get-Content -LiteralPath $junctionExternalInbox -Raw -Encoding utf8
$junctionResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{
    WorkspaceRoot = $junctionWorkspace
    Type          = 'junction-test'
}
$junctionAfter = Get-Content -LiteralPath $junctionExternalInbox -Raw -Encoding utf8
[System.IO.Directory]::Delete($junctionPath)
if ($junctionResult.ExitCode -eq 0 -or
    ($junctionResult.Output -join "`n") -notmatch 'reparse point' -or
    $junctionBefore -cne $junctionAfter -or
    $junctionAfter -notmatch '\|\s*open\s*\|\s*must remain external') {
    Add-Failure 'a workspace .assistant junction should be rejected before any external runtime write'
} else {
    Add-Check 'a workspace .assistant junction is rejected before any external runtime write'
}

$wrongTypeWorkspace = Join-Path $tmpRoot 'runtime-directory-wrong-type'
$wrongTypeVault = Join-Path $wrongTypeWorkspace '.assistant'
$wrongTypeRuntime = Join-Path $wrongTypeVault $runtimeDirName
New-Item -ItemType Directory -Path $wrongTypeVault -Force | Out-Null
Set-Content -LiteralPath $wrongTypeRuntime -Value 'must remain a file' -Encoding utf8
$wrongTypeBefore = Get-Content -LiteralPath $wrongTypeRuntime -Raw -Encoding utf8
$wrongTypeResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{ WorkspaceRoot = $wrongTypeWorkspace; List = $true }
$wrongTypeAfter = Get-Content -LiteralPath $wrongTypeRuntime -Raw -Encoding utf8
if ($wrongTypeResult.ExitCode -eq 0 -or
    ($wrongTypeResult.Output -join "`n") -notmatch 'runtime path is not a directory' -or
    $wrongTypeBefore -cne $wrongTypeAfter) {
    Add-Failure 'a runtime path with the wrong item type should fail closed without changing the file'
} else {
    Add-Check 'a runtime path with the wrong item type fails closed without changing the file'
}

$vaultFileWorkspace = Join-Path $tmpRoot 'vault-root-file-wrong-type'
New-Item -ItemType Directory -Path $vaultFileWorkspace -Force | Out-Null
$vaultFilePath = Join-Path $vaultFileWorkspace '.assistant'
Set-Content -LiteralPath $vaultFilePath -Value 'must remain a file' -Encoding utf8
$vaultFileBefore = Get-Content -LiteralPath $vaultFilePath -Raw -Encoding utf8
$vaultFileList = Invoke-TriageInbox -VaultRoot '' -Arguments @{ WorkspaceRoot = $vaultFileWorkspace; List = $true }
$vaultFileUpdate = Invoke-TriageInbox -VaultRoot '' -Arguments @{ WorkspaceRoot = $vaultFileWorkspace; Type = 'anything' }
$vaultFileAfter = Get-Content -LiteralPath $vaultFilePath -Raw -Encoding utf8

$inboxDirectoryWorkspace = Join-Path $tmpRoot 'inbox-directory-wrong-type'
$inboxDirectoryVault = Join-Path $inboxDirectoryWorkspace '.assistant'
$inboxDirectoryRuntime = Join-Path $inboxDirectoryVault $runtimeDirName
$inboxDirectoryPath = Join-Path $inboxDirectoryRuntime $inboxFileName
New-Item -ItemType Directory -Path $inboxDirectoryPath -Force | Out-Null
$inboxDirectoryList = Invoke-TriageInbox -VaultRoot '' -Arguments @{ WorkspaceRoot = $inboxDirectoryWorkspace; List = $true }
$inboxDirectoryUpdate = Invoke-TriageInbox -VaultRoot '' -Arguments @{ WorkspaceRoot = $inboxDirectoryWorkspace; Type = 'anything' }
if ($vaultFileList.ExitCode -eq 0 -or $vaultFileUpdate.ExitCode -eq 0 -or
    (($vaultFileList.Output + $vaultFileUpdate.Output) -join "`n") -notmatch 'vault root is not a directory' -or
    $vaultFileBefore -cne $vaultFileAfter -or
    $inboxDirectoryList.ExitCode -eq 0 -or $inboxDirectoryUpdate.ExitCode -eq 0 -or
    (($inboxDirectoryList.Output + $inboxDirectoryUpdate.Output) -join "`n") -notmatch 'runtime inbox is not a file' -or
    @(Get-ChildItem -LiteralPath $inboxDirectoryPath -Force).Count -ne 0) {
    Add-Failure 'vault-file and inbox-directory authority corruption should fail list/update without mutation'
} else {
    Add-Check 'vault-file and inbox-directory authority corruption fail list/update without mutation'
}

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
$listEnvelope = Get-TriageListEnvelope -Result $listResult
if ($null -eq $listEnvelope -or @($listEnvelope.open_items).Count -ne 3 -or
    $listResult.Output[-1] -cne 'STATUS: PASS') {
    Add-Failure 'triage-runtime-inbox should emit one structured JSON envelope before the final PASS status'
} else {
    Add-Check 'triage-runtime-inbox emits one structured JSON envelope before the final PASS status'
}

if ($null -eq $listEnvelope -or @($listEnvelope.open_items | Where-Object {
        $_.created_at -ceq '2026-04-03 08:05:00' -and
        $_.source -ceq 'manual-test' -and
        $_.task_id -ceq 'sample-task' -and
        $_.type -ceq 'inbox-first' -and
        $_.summary -ceq 'Need pipe ｜ triage <br> and newline'
    }).Count -ne 1) {
    Add-Failure 'triage-runtime-inbox should include inbox-first rows in list mode'
} else {
    Add-Check 'triage-runtime-inbox includes inbox-first rows in list mode'
}

[object[]]$boundTaskItems = if ($null -ne $listEnvelope) { @($listEnvelope.open_items | Where-Object { $_.task_id -ceq 'sample-task' }) } else { @() }
$selectedBoundRow = @($boundTaskItems | Where-Object { $_.created_at -ceq '2026-04-03 08:05:00' }) | Select-Object -First 1
$selectedBoundRowId = if ($null -ne $selectedBoundRow) { [string]$selectedBoundRow.row_id } else { '' }
if ($boundTaskItems.Count -ne 3 -or
    @($boundTaskItems.route_task_id | Sort-Object -Unique).Count -ne 1 -or
    @($boundTaskItems.row_id | Sort-Object -Unique).Count -ne 3 -or
    @($boundTaskItems.row_id | Where-Object { $_ -cnotmatch '^row-[0-9a-f]{60}$' }).Count -ne 0) {
    Add-Failure 'list should separate a shared bound-task route from each exact full-row selector'
} else {
    Add-Check 'list separates a shared bound-task route from each exact full-row selector'
}

$invalidStatusBefore = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
$invalidStatusResult = Invoke-TriageInbox -VaultRoot $vaultRoot -Arguments @{
    RowId     = $selectedBoundRowId
    SetStatus = "cleared`nopen"
}
$invalidStatusAfter = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
if ($invalidStatusResult.ExitCode -eq 0 -or
    ($invalidStatusResult.Output -join "`n") -notmatch 'SetStatus must be one of' -or
    $invalidStatusBefore -cne $invalidStatusAfter) {
    Add-Failure 'non-canonical status values should fail before reading or rewriting the inbox'
} else {
    Add-Check 'non-canonical status values fail before reading or rewriting the inbox'
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
if ($ambiguousOutputText -notmatch [regex]::Escape('Matched 2 distinct active runtime inbox row identities; use -RowId from -List or the exact full-row selectors.')) {
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
        RowId          = $selectedBoundRowId
        SetStatus      = 'cleared'
        ResolutionNote = 'Promoted into the clarified workflow plan.'
    }
$resolvedContent = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
if ($resolveResult.ExitCode -ne 0) {
    Add-Failure 'triage-runtime-inbox should resolve one row_id-selected item when several rows share a bound task'
} else {
    Add-Check 'triage-runtime-inbox resolves one row_id-selected item when several rows share a bound task'
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

$malformedCaseRoot = Join-Path $tmpRoot 'triage-malformed-row-zero-write'
$malformedVaultRoot = Join-Path $malformedCaseRoot '.assistant'
$malformedRuntimeDir = Join-Path $malformedVaultRoot $runtimeDirName
$malformedInboxPath = Join-Path $malformedRuntimeDir $inboxFileName
New-Item -ItemType Directory -Path $malformedRuntimeDir -Force | Out-Null
$malformedTargetLine = '| 2026-07-11 12:00:00 | malformed-test | malformed-task | inbox-first | open | valid target | valid payload |'
. (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1')
$malformedTargetRowId = Get-InboxRowId -Row (Convert-InboxLineToRow -Line $malformedTargetLine)
$malformedVariants = @(
    '| 2026-07-11 12:01:00 | malformed-test | unrelated-task | empty-tail | open | unrelated row | keep ||'
    '|| 2026-07-11 12:02:00 | malformed-test | unrelated-task | empty-head | open | unrelated row | keep |'
)
$malformedRejected = $true
foreach ($malformedLine in $malformedVariants) {
    $malformedContent = @(
        '---'
        'tags: [runtime, inbox]'
        'created: 2026-07-11'
        'updated: 2026-07-11 12:02:00'
        'schema_version: runtime-inbox/v1.0'
        '---'
        ''
        '# Runtime Inbox'
        ''
        '| created_at | source | task_id | type | status | summary | payload |'
        '|------------|--------|---------|------|--------|---------|---------|'
        $malformedTargetLine
        $malformedLine
    ) -join "`r`n"
    Set-Content -LiteralPath $malformedInboxPath -Value $malformedContent -Encoding utf8
    $malformedBefore = Get-Content -LiteralPath $malformedInboxPath -Raw -Encoding utf8
    $malformedResult = Invoke-TriageInbox -VaultRoot $malformedVaultRoot -Arguments @{ RowId = $malformedTargetRowId }
    $malformedAfter = Get-Content -LiteralPath $malformedInboxPath -Raw -Encoding utf8
    if ($malformedResult.ExitCode -eq 0 -or
        ($malformedResult.Output -join "`n") -notmatch 'exactly seven columns' -or
        $malformedBefore -cne $malformedAfter -or
        $malformedAfter -notmatch [regex]::Escape($malformedLine)) {
        $malformedRejected = $false
    }
}
if (-not $malformedRejected) {
    Add-Failure 'malformed leading/trailing empty columns should fail the whole triage update without losing original bytes'
} else {
    Add-Check 'malformed leading/trailing empty columns fail the whole triage update without losing original bytes'
}

$structureCollisionRoot = Join-Path $tmpRoot 'triage-structure-row-collision'
$structureCollisionVault = Join-Path $structureCollisionRoot '.assistant'
$structureCollisionRuntime = Join-Path $structureCollisionVault $runtimeDirName
$structureCollisionInbox = Join-Path $structureCollisionRuntime $inboxFileName
New-Item -ItemType Directory -Path $structureCollisionRuntime -Force | Out-Null
$structureTargetLine = '| 2026-07-11 12:10:00 | structure-test | structure-task | inbox-first | open | exact target | target bytes |'
$hyphenFirstDataLine = '| - | must-preserve | unknown | hidden | open | hidden malformed row | bytes |'
$headerLikeDataLine = '| created_at | must-preserve-header-like | unknown | hidden | open | header-like data row | bytes-two |'
$structureContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-07-11'
    'updated: 2026-07-11 12:10:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    $structureTargetLine
    $hyphenFirstDataLine
    $headerLikeDataLine
) -join "`r`n"
Set-Content -LiteralPath $structureCollisionInbox -Value $structureContent -Encoding utf8
$structureTargetRowId = Get-InboxRowId -Row (Convert-InboxLineToRow -Line $structureTargetLine)
$structureResult = Invoke-TriageInbox -VaultRoot $structureCollisionVault -Arguments @{ RowId = $structureTargetRowId }
$structureAfter = Get-Content -LiteralPath $structureCollisionInbox -Raw -Encoding utf8
if ($structureResult.ExitCode -ne 0 -or
    -not $structureAfter.Contains($hyphenFirstDataLine) -or
    -not $structureAfter.Contains($headerLikeDataLine) -or
    $structureAfter -notmatch '\|\s*2026-07-11 12:10:00\s*\|\s*structure-test\s*\|\s*structure-task\s*\|\s*inbox-first\s*\|\s*cleared\s*\|') {
    Add-Failure 'triage should classify table structure by all seven cells and preserve unrelated sentinel-like rows byte-for-byte'
} else {
    Add-Check 'triage classifies table structure by all seven cells and preserves unrelated sentinel-like rows byte-for-byte'
}

$routeCaseRoot = Join-Path $tmpRoot 'triage-runtime-inbox-deterministic-route'
if (Test-Path -LiteralPath $routeCaseRoot) {
    Remove-Item -LiteralPath $routeCaseRoot -Recurse -Force
}
$routeVaultRoot = Join-Path $routeCaseRoot '.assistant'
$routeRuntimeDir = Join-Path $routeVaultRoot $runtimeDirName
New-Item -ItemType Directory -Path $routeRuntimeDir -Force | Out-Null
$routeInboxPath = Join-Path $routeRuntimeDir $inboxFileName
$routeContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-07-11'
    'updated: 2026-07-11 12:30:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    ('| 2026-07-11 12:30:00 | route-test | unknown | inbox-first | open | Preserve this requirement across a crash | exact payload must survive; route_task_id=inbox-{0}; task_plan_exists=False |' -f ('a' * 58))
    ('| 2026-07-11 12:30:00 | route-test | unknown | inbox-first | open | Preserve this requirement across a crash | exact payload must survive; route_task_id=inbox-{0}; task_plan_exists=False |' -f ('a' * 58))
) -join "`r`n"
Set-Content -LiteralPath $routeInboxPath -Value $routeContent -Encoding utf8

$routeListA = Invoke-TriageInbox -VaultRoot $routeVaultRoot -Arguments @{ List = $true; WorkspaceRoot = $routeCaseRoot }
$routeListB = Invoke-TriageInbox -VaultRoot $routeVaultRoot -Arguments @{ List = $true; WorkspaceRoot = $routeCaseRoot }
$routeEnvelopeA = Get-TriageListEnvelope -Result $routeListA
$routeEnvelopeB = Get-TriageListEnvelope -Result $routeListB
$routeItemA = if ($null -ne $routeEnvelopeA) { @($routeEnvelopeA.open_items) | Select-Object -First 1 } else { $null }
$routeItemB = if ($null -ne $routeEnvelopeB) { @($routeEnvelopeB.open_items) | Select-Object -First 1 } else { $null }
$spoofRouteTaskId = 'inbox-' + ('a' * 58)
if ($routeListA.ExitCode -ne 0 -or $routeListB.ExitCode -ne 0 -or
    $null -eq $routeItemA -or $null -eq $routeItemB -or
    $routeItemA.route_task_id -notmatch '^inbox-[0-9a-f]{58}$' -or
    $routeItemA.row_id -notmatch '^row-[0-9a-f]{60}$' -or
    $routeItemA.route_task_id -ceq $spoofRouteTaskId -or
    $routeItemA.route_task_id -cne $routeItemB.route_task_id -or
    $routeItemA.row_id -cne $routeItemB.row_id -or
    [bool]$routeItemA.task_plan_exists) {
    Add-Failure 'triage list should expose stable injection-safe task routing and row selector ids'
} else {
    Add-Check 'triage list exposes stable injection-safe task routing and row selector ids'
}

if ($null -ne $routeItemA) {
    $routeTaskId = $routeItemA.route_task_id
    $routeTaskRoot = Join-Path $routeCaseRoot ("docs\tasks\{0}" -f $routeTaskId)
    $routePlanPath = Join-Path $routeTaskRoot 'plan.md'
    New-Item -ItemType Directory -Path $routeTaskRoot -Force | Out-Null
    $routePlanContent = "---`r`ntask_id: $routeTaskId`r`nstage: PLAN`r`ntool: codex`r`nupdated: 2026-07-11`r`n---`r`n# Deterministic inbox route"
    Set-Content -LiteralPath $routePlanPath -Value $routePlanContent -Encoding utf8

    $routeInboxBeforeRetry = Get-Content -LiteralPath $routeInboxPath -Raw -Encoding utf8
    $routeRetryList = Invoke-TriageInbox -VaultRoot $routeVaultRoot -Arguments @{ List = $true }
    $routeRetryEnvelope = Get-TriageListEnvelope -Result $routeRetryList
    $routeRetryItem = if ($null -ne $routeRetryEnvelope) { @($routeRetryEnvelope.open_items) | Select-Object -First 1 } else { $null }
    $routeInboxAfterRetry = Get-Content -LiteralPath $routeInboxPath -Raw -Encoding utf8
    $routeTaskDirectories = @(Get-ChildItem -LiteralPath (Join-Path $routeCaseRoot 'docs\tasks') -Directory -Force)
    if ($routeRetryList.ExitCode -ne 0 -or
        $null -eq $routeRetryItem -or
        $routeRetryItem.route_task_id -cne $routeTaskId -or
        -not [bool]$routeRetryItem.task_plan_exists -or
        $routeInboxBeforeRetry -cne $routeInboxAfterRetry -or
        $routeTaskDirectories.Count -ne 1) {
        Add-Failure 'an explicit VaultRoot should rediscover its existing deterministic plan independent of cwd after a create/triage crash'
    } else {
        Add-Check 'an explicit VaultRoot rediscovers its existing deterministic plan independent of cwd after a create/triage crash'
    }

    $mismatchedRootList = Invoke-TriageInbox -VaultRoot $routeVaultRoot -Arguments @{ List = $true; WorkspaceRoot = $RepoRoot }
    if ($mismatchedRootList.ExitCode -eq 0 -or ($mismatchedRootList.Output -join "`n") -match '(?m)^STATUS:\s+PASS\s*$') {
        Add-Failure 'triage list should reject mismatched explicit VaultRoot and WorkspaceRoot before reporting PASS'
    } else {
        Add-Check 'triage list rejects mismatched explicit VaultRoot and WorkspaceRoot before reporting PASS'
    }

    $routePlanBeforeTriage = Get-Content -LiteralPath $routePlanPath -Raw -Encoding utf8
    $routeResolve = Invoke-TriageInbox -VaultRoot $routeVaultRoot -Arguments @{
        RowId     = [string]$routeItemA.row_id
        SetStatus = 'cleared'
    }
    $routePlanAfterTriage = Get-Content -LiteralPath $routePlanPath -Raw -Encoding utf8
    $routeInboxAfterTriage = Get-Content -LiteralPath $routeInboxPath -Raw -Encoding utf8
    if ($routeResolve.ExitCode -ne 0 -or
        $routePlanBeforeTriage -cne $routePlanAfterTriage -or
        [regex]::Matches($routeInboxAfterTriage, '\|\s*2026-07-11 12:30:00\s*\|\s*route-test\s*\|\s*unknown\s*\|\s*inbox-first\s*\|\s*cleared\s*\|').Count -ne 2 -or
        $routeInboxAfterTriage -match '\|\s*2026-07-11 12:30:00\s*\|\s*route-test\s*\|\s*unknown\s*\|\s*inbox-first\s*\|\s*open\s*\|' -or
        @(Get-ChildItem -LiteralPath (Join-Path $routeCaseRoot 'docs\tasks') -Directory -Force).Count -ne 1) {
        Add-Failure 'RowId triage should clear only its identical full-row identity without changing or duplicating its plan'
    } else {
        Add-Check 'RowId triage clears identical full-row duplicates without changing or duplicating their plan'
    }
}

$precedenceRoot = Join-Path $tmpRoot 'workspace-over-env-vault-precedence'
if (Test-Path -LiteralPath $precedenceRoot) {
    Remove-Item -LiteralPath $precedenceRoot -Recurse -Force
}
$envWorkspaceRoot = Join-Path $precedenceRoot 'env-workspace'
$explicitWorkspaceRoot = Join-Path $precedenceRoot 'explicit-workspace'
$envVaultRoot = Join-Path $envWorkspaceRoot '.assistant'
$explicitVaultRoot = Join-Path $explicitWorkspaceRoot '.assistant'
$envInboxPath = Join-Path (Join-Path $envVaultRoot $runtimeDirName) $inboxFileName
$explicitInboxPath = Join-Path (Join-Path $explicitVaultRoot $runtimeDirName) $inboxFileName
New-Item -ItemType Directory -Path (Split-Path -Parent $envInboxPath),(Split-Path -Parent $explicitInboxPath) -Force | Out-Null
$inboxPrefix = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-07-11'
    'updated: 2026-07-11 13:00:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
)
$envContent = @($inboxPrefix + '| 2026-07-11 13:00:00 | env-vault | unknown | inbox-first | open | must stay untouched | env payload |') -join "`r`n"
$explicitContent = @($inboxPrefix + '| 2026-07-11 13:00:01 | explicit-workspace | unknown | inbox-first | open | must be selected | explicit payload |') -join "`r`n"
Set-Content -LiteralPath $envInboxPath -Value $envContent -Encoding utf8
Set-Content -LiteralPath $explicitInboxPath -Value $explicitContent -Encoding utf8
$savedDevHarnessVaultPath = $env:DEV_HARNESS_VAULT_PATH
try {
    $env:DEV_HARNESS_VAULT_PATH = $envVaultRoot
    $precedenceList = Invoke-TriageInbox -VaultRoot '' -Arguments @{ List = $true; WorkspaceRoot = $explicitWorkspaceRoot }
    $precedenceEnvelope = Get-TriageListEnvelope -Result $precedenceList
    [object[]]$precedenceItems = if ($null -ne $precedenceEnvelope) { @($precedenceEnvelope.open_items) } else { @() }
    $precedenceItemCount = @($precedenceItems).Count
    $precedenceRowId = if ($precedenceItemCount -eq 1) { [string]$precedenceItems[0].row_id } else { '' }
    $envBeforeUpdate = Get-Content -LiteralPath $envInboxPath -Raw -Encoding utf8
    $precedenceUpdate = if ([string]::IsNullOrWhiteSpace($precedenceRowId)) {
        $null
    } else {
        Invoke-TriageInbox -VaultRoot '' -Arguments @{ WorkspaceRoot = $explicitWorkspaceRoot; RowId = $precedenceRowId }
    }
    $envAfterUpdate = Get-Content -LiteralPath $envInboxPath -Raw -Encoding utf8
    $explicitAfterUpdate = Get-Content -LiteralPath $explicitInboxPath -Raw -Encoding utf8
} finally {
    $env:DEV_HARNESS_VAULT_PATH = $savedDevHarnessVaultPath
}
if ($precedenceList.ExitCode -ne 0 -or
    $precedenceItemCount -ne 1 -or
    $precedenceItems[0].source -cne 'explicit-workspace' -or
    $null -eq $precedenceUpdate -or $precedenceUpdate.ExitCode -ne 0 -or
    $envBeforeUpdate -cne $envAfterUpdate -or
    $explicitAfterUpdate -notmatch '\|\s*explicit-workspace\s*\|\s*unknown\s*\|\s*inbox-first\s*\|\s*cleared\s*\|') {
    Add-Failure ("explicit WorkspaceRoot should override an environment VaultRoot for both List and update without touching the env vault: list_exit={0}; items={1}; source={2}; update_exit={3}; env_same={4}; explicit_cleared={5}; list=[{6}]" -f `
        $precedenceList.ExitCode,
        $precedenceItemCount,
        $(if ($precedenceItemCount -eq 1) { [string]$precedenceItems[0].source } else { '' }),
        $(if ($null -eq $precedenceUpdate) { 'null' } else { $precedenceUpdate.ExitCode }),
        ($envBeforeUpdate -ceq $envAfterUpdate),
        ($explicitAfterUpdate -match '\|\s*explicit-workspace\s*\|\s*unknown\s*\|\s*inbox-first\s*\|\s*cleared\s*\|'),
        ($precedenceList.Output -join ' | '))
} else {
    Add-Check 'explicit WorkspaceRoot overrides an environment VaultRoot for List and update without cross-workspace writes'
}

. (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\resolve-shared-memory-paths.ps1')
$nestedVaultDirectory = Join-Path $explicitVaultRoot 'nested\deeper'
New-Item -ItemType Directory -Path $nestedVaultDirectory -Force | Out-Null
$nestedWorkspaceDirectory = Join-Path $explicitWorkspaceRoot 'src\nested'
New-Item -ItemType Directory -Path $nestedWorkspaceDirectory -Force | Out-Null
$rootEnvironmentNames = @(
    'DEV_HARNESS_VAULT_PATH', 'CLAUDE_DEV_HARNESS_VAULT_PATH', 'OBSIDIAN_SHARED_VAULT',
    'DEV_HARNESS_WORKSPACE_ROOT', 'CLAUDE_DEV_HARNESS_WORKSPACE_ROOT', 'WORKSPACE_ROOT'
)
$savedRootEnvironment = @{}
foreach ($name in $rootEnvironmentNames) {
    $savedRootEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
$crossTierResult = $null
$cwdConflictListResult = $null
$cwdConflictUpdateResult = $null
try {
    Push-Location -LiteralPath $nestedVaultDirectory
    try {
        $nestedResolvedVault = Resolve-SharedMemoryVaultRoot
    } finally {
        Pop-Location
    }
    Push-Location -LiteralPath $nestedWorkspaceDirectory
    try {
        $nestedWorkspaceResolvedVault = Resolve-SharedMemoryVaultRoot
    } finally {
        Pop-Location
    }
    $env:DEV_HARNESS_VAULT_PATH = $envVaultRoot
    $env:OBSIDIAN_SHARED_VAULT = $explicitVaultRoot
    $conflictingEnvironmentRejected = $false
    try {
        $null = Resolve-SharedMemoryVaultRoot
    } catch {
        $conflictingEnvironmentRejected = $_.Exception.Message -match '\[vault-ambiguous\]'
    }

    $env:OBSIDIAN_SHARED_VAULT = $null
    $env:DEV_HARNESS_WORKSPACE_ROOT = $explicitWorkspaceRoot
    $crossTierEnvBefore = Get-Content -LiteralPath $envInboxPath -Raw -Encoding utf8
    $crossTierWorkspaceBefore = Get-Content -LiteralPath $explicitInboxPath -Raw -Encoding utf8
    $crossTierResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{ List = $true }
    $crossTierEnvAfter = Get-Content -LiteralPath $envInboxPath -Raw -Encoding utf8
    $crossTierWorkspaceAfter = Get-Content -LiteralPath $explicitInboxPath -Raw -Encoding utf8

    $env:DEV_HARNESS_WORKSPACE_ROOT = $null
    $cwdConflictEnvBefore = Get-Content -LiteralPath $envInboxPath -Raw -Encoding utf8
    $cwdConflictWorkspaceBefore = Get-Content -LiteralPath $explicitInboxPath -Raw -Encoding utf8
    Push-Location -LiteralPath $nestedWorkspaceDirectory
    try {
        $cwdConflictListResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{ List = $true }
        $cwdConflictUpdateResult = Invoke-TriageInbox -VaultRoot '' -Arguments @{ RowId = ('row-' + ('a' * 60)) }
    } finally {
        Pop-Location
    }
    $cwdConflictEnvAfter = Get-Content -LiteralPath $envInboxPath -Raw -Encoding utf8
    $cwdConflictWorkspaceAfter = Get-Content -LiteralPath $explicitInboxPath -Raw -Encoding utf8
} finally {
    foreach ($name in $rootEnvironmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedRootEnvironment[$name], 'Process')
    }
}
if ((Get-NormalizedPath -Path $nestedResolvedVault) -ne (Get-NormalizedPath -Path $explicitVaultRoot) -or
    (Get-NormalizedPath -Path $nestedWorkspaceResolvedVault) -ne (Get-NormalizedPath -Path $explicitVaultRoot) -or
    -not $conflictingEnvironmentRejected) {
    Add-Failure 'cwd fallback should find the workspace .assistant from nested workspace or vault paths and conflicting environment roots should fail closed'
} else {
    Add-Check 'cwd fallback finds the workspace .assistant from nested workspace or vault paths and conflicting environment roots fail closed'
}

if ($null -eq $crossTierResult -or
    $crossTierResult.ExitCode -eq 0 -or
    ($crossTierResult.Output -join "`n") -notmatch '\[vault-ambiguous\]' -or
    $crossTierEnvBefore -cne $crossTierEnvAfter -or
    $crossTierWorkspaceBefore -cne $crossTierWorkspaceAfter) {
    Add-Failure 'disagreeing vault and workspace environment tiers should fail closed before any inbox write'
} else {
    Add-Check 'disagreeing vault and workspace environment tiers fail closed before any inbox write'
}

if ($null -eq $cwdConflictListResult -or $null -eq $cwdConflictUpdateResult -or
    $cwdConflictListResult.ExitCode -eq 0 -or $cwdConflictUpdateResult.ExitCode -eq 0 -or
    ($cwdConflictListResult.Output -join "`n") -notmatch '\[vault-ambiguous\]' -or
    ($cwdConflictUpdateResult.Output -join "`n") -notmatch '\[vault-ambiguous\]' -or
    $cwdConflictEnvBefore -cne $cwdConflictEnvAfter -or
    $cwdConflictWorkspaceBefore -cne $cwdConflictWorkspaceAfter) {
    Add-Failure 'a stale vault environment root should conflict with a different cwd workspace before list or update writes'
} else {
    Add-Check 'a stale vault environment root conflicts with a different cwd workspace before list or update writes'
}
} finally {
    Remove-DirectoryWithRetry -Path $tmpRoot
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
