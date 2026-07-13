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

function Invoke-AppendInbox {
    param(
        [string]$VaultRoot,
        [string]$TaskId = 'unknown',
        [string]$Type,
        [string]$Summary,
        [string]$Payload = '-',
        [string]$Source = 'manual-test',
        [string]$Status = 'open',
        [string]$WorkingDirectory = ''
    )

    $scriptPath = Join-Path $RepoRoot 'scripts\append-runtime-inbox.ps1'
    $originalLocation = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $originalLocation = (Get-Location).Path
            Set-Location -LiteralPath $WorkingDirectory
        }

        $invokeArgs = @{
            VaultRoot = $VaultRoot
            Type      = $Type
            Summary   = $Summary
            Payload   = $Payload
            Source    = $Source
            Status    = $Status
        }
        if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
            $invokeArgs.TaskId = $TaskId
        }

        $output = @(& $scriptPath @invokeArgs 2>&1)
        return [pscustomobject]@{
            Output   = @($output | ForEach-Object { [string]$_ })
            ExitCode = $LASTEXITCODE
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($originalLocation)) {
            Set-Location -LiteralPath $originalLocation
        }
    }
}

function Start-AppendInboxProcess {
    param(
        [string]$VaultRoot,
        [int]$Index
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'scripts\append-runtime-inbox.ps1'),
        '-VaultRoot', $VaultRoot,
        '-TaskId', ('concurrent-{0}' -f $Index),
        '-Type', 'inbox-first',
        '-Summary', ('concurrent-summary-{0}' -f $Index),
        '-Payload', ('payload-{0}' -f $Index),
        '-Source', 'concurrency-test'
    )) {
        $psi.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    return [pscustomobject]@{
        Process = $process
        StdOut  = $process.StandardOutput.ReadToEndAsync()
        StdErr  = $process.StandardError.ReadToEndAsync()
    }
}

function Invoke-TriageInboxList {
    param([string]$VaultRoot)

    $scriptPath = Join-Path $RepoRoot 'scripts\triage-runtime-inbox.ps1'
    $output = @(& $scriptPath -VaultRoot $VaultRoot -List 2>&1)
    return [pscustomobject]@{
        Output   = @($output | ForEach-Object { [string]$_ })
        ExitCode = $LASTEXITCODE
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
$tmpRoot = Join-Path $RepoRoot ('tmp\runtime-inbox-regression-' +
    [guid]::NewGuid().ToString('N'))
try {
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$runtimeDirName = Convert-CodePointsToString -CodePoints @(36816, 34892, 26102)
$inboxFileName = Convert-CodePointsToString -CodePoints @(25910, 20214, 31665, 46, 109, 100)
$placeholderSummary = Convert-CodePointsToString -CodePoints @(24403, 21069, 26242, 26080, 25910, 20214, 31665, 20107, 39033)
$fullWidthPipe = [string][char]0xFF5C
$standardHeader = '| created_at | source | task_id | type | status | summary | payload |'
$placeholderRow = '| - | - | - | - | cleared | {0} | - |' -f $placeholderSummary
$currentTaskFileName = Convert-CodePointsToString -CodePoints @(24403, 21069, 20219, 21153, 46, 109, 100)
$idleText = Convert-CodePointsToString -CodePoints @(31354, 38386)

$ancestorCaseRoot = Join-Path $tmpRoot 'ancestor-junction-agent-home-zero-write'
$ancestorAliasBase = Join-Path $ancestorCaseRoot 'base'
$ancestorAliasPath = Join-Path $ancestorAliasBase 'alias'
if (Test-Path -LiteralPath $ancestorAliasPath) {
    [System.IO.Directory]::Delete($ancestorAliasPath)
}
if (Test-Path -LiteralPath $ancestorCaseRoot) {
    Remove-Item -LiteralPath $ancestorCaseRoot -Recurse -Force
}
$ancestorUserProfile = Join-Path $ancestorCaseRoot 'user'
$ancestorAgentRoot = Join-Path $ancestorUserProfile '.codex'
New-Item -ItemType Directory -Path $ancestorAliasBase,$ancestorAgentRoot -Force | Out-Null
New-Item -ItemType Junction -Path $ancestorAliasPath -Target $ancestorAgentRoot | Out-Null
$ancestorVaultAlias = Join-Path $ancestorAliasPath 'aliased-project\.assistant'
$ancestorActualProject = Join-Path $ancestorAgentRoot 'aliased-project'
$savedUserProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $ancestorUserProfile
    try {
        $ancestorResult = Invoke-AppendInbox -VaultRoot $ancestorVaultAlias -TaskId 'unknown' -Type 'inbox-first' -Summary 'must not escape through an ancestor junction'
    } catch {
        $ancestorResult = [pscustomobject]@{ ExitCode = 1; Output = @($_.Exception.Message) }
    }
} finally {
    $env:USERPROFILE = $savedUserProfile
}
[System.IO.Directory]::Delete($ancestorAliasPath)
if ($ancestorResult.ExitCode -eq 0 -or
    ($ancestorResult.Output -join "`n") -notmatch 'reparse point' -or
    (Test-Path -LiteralPath $ancestorActualProject)) {
    Add-Failure 'append should reject an existing reparse ancestor before a first write into an aliased agent home'
} else {
    Add-Check 'append rejects an existing reparse ancestor before a first write into an aliased agent home'
}

$createCaseRoot = Join-Path $tmpRoot 'create-canonical-inbox'
if (Test-Path -LiteralPath $createCaseRoot) {
    Remove-Item -LiteralPath $createCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $createCaseRoot -Force | Out-Null
$createVaultRoot = Join-Path $createCaseRoot '.assistant'
$createResult = Invoke-AppendInbox `
    -VaultRoot $createVaultRoot `
    -TaskId 'unknown' `
    -Type 'inbox-first' `
    -Summary 'Need workflow triage' `
    -Payload 'User added a new requirement.' `
    -Source 'manual-test'
$createInboxPath = Join-Path (Join-Path $createVaultRoot $runtimeDirName) $inboxFileName
$createContent = if (Test-Path -LiteralPath $createInboxPath -PathType Leaf) {
    Get-Content -LiteralPath $createInboxPath -Raw -Encoding utf8
} else {
    ''
}

if ($createResult.ExitCode -ne 0) {
    Add-Failure 'append-runtime-inbox should return exit code 0 when creating a new runtime inbox file'
} else {
    Add-Check 'append-runtime-inbox returns exit code 0 when creating a new runtime inbox file'
}

if ($createContent -notmatch 'schema_version:\s+runtime-inbox/v1\.0') {
    Add-Failure 'append-runtime-inbox should create runtime-inbox/v1.0 frontmatter when the inbox file is missing'
} else {
    Add-Check 'append-runtime-inbox creates runtime-inbox/v1.0 frontmatter when the inbox file is missing'
}

if ($createContent -notmatch [regex]::Escape($standardHeader)) {
    Add-Failure 'append-runtime-inbox should create the standard inbox table header when the inbox file is missing'
} else {
    Add-Check 'append-runtime-inbox creates the standard inbox table header when the inbox file is missing'
}

if ($createContent -match [regex]::Escape($placeholderSummary)) {
    Add-Failure 'append-runtime-inbox should remove the placeholder row when it appends an active inbox item'
} else {
    Add-Check 'append-runtime-inbox removes the placeholder row when it appends an active inbox item'
}

$createRowPattern = '\|\s*.+?\s*\|\s*manual-test\s*\|\s*unknown\s*\|\s*inbox-first\s*\|\s*open\s*\|\s*Need workflow triage\s*\|\s*User added a new requirement\.\s*\|'
if ($createContent -notmatch $createRowPattern) {
    Add-Failure 'append-runtime-inbox should append the requested inbox-first row into the inbox file'
} else {
    Add-Check 'append-runtime-inbox appends the requested inbox-first row into the inbox file'
}

$createListResult = Invoke-TriageInboxList -VaultRoot $createVaultRoot
$createListText = $createListResult.Output -join "`n"
$createListEnvelope = Get-TriageListEnvelope -Result $createListResult
if ($createListResult.ExitCode -ne 0) {
    Add-Failure 'triage-runtime-inbox should be able to list items from an inbox file created by append-runtime-inbox'
} else {
    Add-Check 'triage-runtime-inbox can list items from an inbox file created by append-runtime-inbox'
}

if ($null -eq $createListEnvelope -or @($createListEnvelope.open_items).Count -ne 1 -or
    $createListResult.Output[-1] -cne 'STATUS: PASS') {
    Add-Failure 'append-runtime-inbox should create one JSON-listable inbox row before the final PASS status'
} else {
    Add-Check 'append-runtime-inbox creates one JSON-listable inbox row before the final PASS status'
}

$invalidTaskRoot = Join-Path $tmpRoot 'invalid-task-id-zero-write'
if (Test-Path -LiteralPath $invalidTaskRoot) {
    Remove-Item -LiteralPath $invalidTaskRoot -Recurse -Force
}
$savedErrorActionPreference = $ErrorActionPreference
$invalidWriterTaskIds = @('none', 'idle', 'Unknown', 'bad_id')
$invalidWriterIdsRejected = $true
try {
    $ErrorActionPreference = 'Continue'
    for ($invalidIndex = 0; $invalidIndex -lt $invalidWriterTaskIds.Count; $invalidIndex++) {
        $invalidTaskVault = Join-Path (Join-Path $invalidTaskRoot $invalidIndex) '.assistant'
        $invalidTaskOutput = @(& pwsh -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'scripts\append-runtime-inbox.ps1') `
            -VaultRoot $invalidTaskVault `
            -TaskId $invalidWriterTaskIds[$invalidIndex] `
            -Type 'inbox-first' `
            -Summary 'must reject non-writer task id' 2>&1)
        $invalidTaskExit = $LASTEXITCODE
        $invalidTaskInbox = Join-Path (Join-Path $invalidTaskVault $runtimeDirName) $inboxFileName
        if ($invalidTaskExit -eq 0 -or (Test-Path -LiteralPath $invalidTaskInbox)) {
            $invalidWriterIdsRejected = $false
        }
    }
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if (-not $invalidWriterIdsRejected) {
    Add-Failure 'append-runtime-inbox should reject none, idle, case variants, and non-canonical ids before any inbox write'
} else {
    Add-Check 'append-runtime-inbox accepts only canonical ids or exact lowercase unknown before any inbox write'
}

$inboxCommonText = Get-Content -LiteralPath (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1') -Raw -Encoding utf8
$runtimeCommonText = Get-Content -LiteralPath (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1') -Raw -Encoding utf8
if ($inboxCommonText -notmatch 'Write-CanonicalRuntimeUtf8BomAtomic\s+-Path\s+\$InboxPath\s+-Content\s+\$content' -or
    $runtimeCommonText -notmatch 'FileMode\]::CreateNew' -or
    $runtimeCommonText -notmatch 'Flush\(\$true\)' -or
    $runtimeCommonText -notmatch 'File\]::Replace') {
    Add-Failure 'runtime inbox should call the single canonical atomic writer directly'
} else {
    Add-Check 'runtime inbox calls the single canonical atomic writer directly'
}

$concurrentCaseRoot = Join-Path $tmpRoot 'concurrent-append-preserves-all-rows'
if (Test-Path -LiteralPath $concurrentCaseRoot) {
    Remove-Item -LiteralPath $concurrentCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $concurrentCaseRoot -Force | Out-Null
$concurrentVaultRoot = Join-Path $concurrentCaseRoot '.assistant'
$concurrentProcesses = [System.Collections.Generic.List[object]]::new()
$concurrentPrimaryError = $null
$concurrentCleanupErrors = @()
try {
    1..6 | ForEach-Object { $concurrentProcesses.Add((Start-AppendInboxProcess -VaultRoot $concurrentVaultRoot -Index $_)) }
    foreach ($appendProcess in $concurrentProcesses) {
        if (-not $appendProcess.Process.WaitForExit(30000)) { throw 'append-runtime-inbox child process timed out' }
        $appendProcess.Process.WaitForExit()
    }
    $concurrentInboxPath = Join-Path (Join-Path $concurrentVaultRoot $runtimeDirName) $inboxFileName
    $concurrentContent = if (Test-Path -LiteralPath $concurrentInboxPath) { Get-Content -LiteralPath $concurrentInboxPath -Raw -Encoding utf8 } else { '' }
    $concurrentExitCodes = @($concurrentProcesses | ForEach-Object { $_.Process.ExitCode })
    $concurrentRows = @([regex]::Matches($concurrentContent, '(?m)^\|\s*.+?\|\s*concurrency-test\s*\|.*?concurrent-summary-\d+.*\|\r?$'))
    $concurrentSummaries = @($concurrentRows | ForEach-Object { $_.Value -replace '^.*?(concurrent-summary-\d+).*$','$1' } | Sort-Object -Unique)
    if (@($concurrentExitCodes | Where-Object { $_ -eq 0 }).Count -eq 6 -and $concurrentRows.Count -eq 6 -and $concurrentSummaries.Count -eq 6) {
        Add-Check 'concurrent append-runtime-inbox writers preserve all rows under the shared runtime mutex'
    } else {
        $concurrentErrors = @($concurrentProcesses | ForEach-Object { $_.StdErr.Result }) -join ' | '
        Add-Failure ("concurrent inbox append should preserve six rows, exits={0}, rows={1}, errors={2}" -f ($concurrentExitCodes -join ','), $concurrentRows.Count, $concurrentErrors)
    }
} catch {
    $concurrentPrimaryError = $_
} finally {
    foreach ($appendProcess in $concurrentProcesses) {
        try {
            if (-not $appendProcess.Process.HasExited) { $appendProcess.Process.Kill($true); $appendProcess.Process.WaitForExit() }
        } catch {
            $concurrentCleanupErrors += ('kill/wait: ' + $_.Exception.Message)
        }
        try {
            $appendProcess.Process.Dispose()
        } catch {
            $concurrentCleanupErrors += ('dispose: ' + $_.Exception.Message)
        }
    }
}
if ($null -ne $concurrentPrimaryError) {
    if ($concurrentCleanupErrors.Count -gt 0) { throw ($concurrentPrimaryError.Exception.Message + '; cleanup: ' + ($concurrentCleanupErrors -join '; ')) }
    throw $concurrentPrimaryError
}
if ($concurrentCleanupErrors.Count -gt 0) { throw ('append-runtime-inbox child cleanup failed: ' + ($concurrentCleanupErrors -join '; ')) }

$escapeCaseRoot = Join-Path $tmpRoot 'escape-placeholder-and-malformed'
if (Test-Path -LiteralPath $escapeCaseRoot) {
    Remove-Item -LiteralPath $escapeCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $escapeCaseRoot -Force | Out-Null
$escapeVaultRoot = Join-Path $escapeCaseRoot '.assistant'
$escapeRuntimeDir = Join-Path $escapeVaultRoot $runtimeDirName
New-Item -ItemType Directory -Path $escapeRuntimeDir -Force | Out-Null
$escapeInboxPath = Join-Path $escapeRuntimeDir $inboxFileName
$hyphenFirstRow = '| - | must-preserve | unknown | hidden | open | hidden malformed row | bytes |'
$headerLikeRow = '| created_at | must-preserve-header-like | unknown | hidden | open | header-like data row | bytes-two |'
$existingContent = @(
    '# Inbox'
    ''
    $standardHeader
    '|------------|--------|---------|------|--------|---------|---------|'
    $placeholderRow
    $hyphenFirstRow
    $headerLikeRow
) -join "`r`n"
Set-Content -LiteralPath $escapeInboxPath -Value $existingContent -Encoding utf8

$escapeSummary = "Need pipe | triage`nand newline"
$escapePayload = "payload line 1`npayload | line 2"
$escapeResult = Invoke-AppendInbox `
    -VaultRoot $escapeVaultRoot `
    -TaskId 'sample-task' `
    -Type 'lock-blocked' `
    -Summary $escapeSummary `
    -Payload $escapePayload `
    -Source 'claude-posttooluse'
$escapeContent = Get-Content -LiteralPath $escapeInboxPath -Raw -Encoding utf8

if ($escapeResult.ExitCode -ne 0) {
    Add-Failure 'append-runtime-inbox should return exit code 0 when appending to an existing inbox file'
} else {
    Add-Check 'append-runtime-inbox returns exit code 0 when appending to an existing inbox file'
}

if ($escapeContent -notmatch 'schema_version:\s+runtime-inbox/v1\.0') {
    Add-Failure 'append-runtime-inbox should repair missing inbox frontmatter before appending'
} else {
    Add-Check 'append-runtime-inbox repairs missing inbox frontmatter before appending'
}

if ($escapeContent -match [regex]::Escape($placeholderRow)) {
    Add-Failure 'append-runtime-inbox should remove the placeholder row from an existing inbox file before appending'
} else {
    Add-Check 'append-runtime-inbox removes the placeholder row from an existing inbox file before appending'
}

if (-not $escapeContent.Contains($hyphenFirstRow) -or -not $escapeContent.Contains($headerLikeRow)) {
    Add-Failure 'append-runtime-inbox should preserve exact seven-column data rows that only resemble a placeholder or header in one cell'
} else {
    Add-Check 'append-runtime-inbox preserves exact seven-column data rows that only resemble a placeholder or header in one cell'
}

$expectedEscapedSummary = 'Need pipe {0} triage <br> and newline' -f $fullWidthPipe
$expectedEscapedPayload = 'payload line 1 <br> payload {0} line 2' -f $fullWidthPipe
if ($escapeContent -notmatch [regex]::Escape($expectedEscapedSummary)) {
    Add-Failure 'append-runtime-inbox should escape pipe characters and newlines in summary values'
} else {
    Add-Check 'append-runtime-inbox escapes pipe characters and newlines in summary values'
}

if ($escapeContent -notmatch [regex]::Escape($expectedEscapedPayload)) {
    Add-Failure 'append-runtime-inbox should escape pipe characters and newlines in payload values'
} else {
    Add-Check 'append-runtime-inbox escapes pipe characters and newlines in payload values'
}

$triageCollisionRoot = Join-Path $tmpRoot 'triage-full-row-identity'
if (Test-Path -LiteralPath $triageCollisionRoot) {
    Remove-Item -LiteralPath $triageCollisionRoot -Recurse -Force
}
$triageCollisionVault = Join-Path $triageCollisionRoot '.assistant'
$triageCollisionRuntime = Join-Path $triageCollisionVault $runtimeDirName
New-Item -ItemType Directory -Path $triageCollisionRuntime -Force | Out-Null
$triageCollisionInbox = Join-Path $triageCollisionRuntime $inboxFileName
. (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1')
. (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1')

$reservedTaskIds = @('none', 'idle', 'unknown')
if (@($reservedTaskIds | Where-Object { Test-CanonicalRuntimeTaskId -TaskId $_ }).Count -ne 0) {
    Add-Failure 'none, idle, and unknown should all be reserved from canonical active task ids'
} else {
    Add-Check 'none, idle, and unknown are reserved from canonical active task ids'
}

$routeRow = Convert-InboxLineToRow -Line '| 2026-07-11 12:30:00 | route-source | unknown | inbox-first | open | deterministic summary | deterministic payload |'
$routeTaskIdA = Get-InboxRouteTaskId -Row $routeRow
$routeTaskIdB = Get-InboxRouteTaskId -Row $routeRow
$rowIdA = Get-InboxRowId -Row $routeRow
$rowIdB = Get-InboxRowId -Row $routeRow
$routeIdentityVariants = @(
    '| 2026-07-11 12:30:01 | route-source | unknown | inbox-first | open | deterministic summary | deterministic payload |'
    '| 2026-07-11 12:30:00 | changed-source | unknown | inbox-first | open | deterministic summary | deterministic payload |'
    '| 2026-07-11 12:30:00 | route-source | unknown | changed-type | open | deterministic summary | deterministic payload |'
    '| 2026-07-11 12:30:00 | route-source | unknown | inbox-first | deferred | deterministic summary | deterministic payload |'
    '| 2026-07-11 12:30:00 | route-source | unknown | inbox-first | open | changed summary | deterministic payload |'
    '| 2026-07-11 12:30:00 | route-source | unknown | inbox-first | open | deterministic summary | changed payload |'
) | ForEach-Object { Get-InboxRouteTaskId -Row (Convert-InboxLineToRow -Line $_) }
if ($routeTaskIdA -notmatch '^inbox-[0-9a-f]{58}$' -or
    $routeTaskIdA -cne $routeTaskIdB -or
    $rowIdA -notmatch '^row-[0-9a-f]{60}$' -or
    $rowIdA -cne $rowIdB -or
    @($routeIdentityVariants | Where-Object { $_ -ceq $routeTaskIdA }).Count -ne 0) {
    Add-Failure 'unknown inbox rows should derive stable canonical route and row ids from the complete serialized row'
} else {
    Add-Check 'unknown inbox rows derive stable canonical route and row ids from complete identity'
}

$sentinelRoutes = @('none', 'idle') | ForEach-Object {
    $sentinelRow = Convert-InboxLineToRow -Line (Format-InboxRow -Row ([pscustomobject]@{
        CreatedAt = $routeRow.CreatedAt
        Source    = $routeRow.Source
        TaskId    = $_
        Type      = $routeRow.Type
        Status    = $routeRow.Status
        Summary   = $routeRow.Summary
        Payload   = $routeRow.Payload
    }))
    Get-InboxRouteTaskId -Row $sentinelRow
}
$boundRouteRow = Convert-InboxLineToRow -Line '| 2026-07-11 12:30:00 | route-source | bound-task | inbox-first | open | deterministic summary | deterministic payload |'
$otherBoundRouteRow = Convert-InboxLineToRow -Line '| 2026-07-11 12:30:00 | route-source | bound-task | inbox-first | open | deterministic summary | other payload |'
if (@($sentinelRoutes | Where-Object { $_ -notmatch '^inbox-[0-9a-f]{58}$' }).Count -ne 0 -or
    (Get-InboxRouteTaskId -Row $boundRouteRow) -cne 'bound-task' -or
    (Get-InboxRouteTaskId -Row $otherBoundRouteRow) -cne 'bound-task' -or
    (Get-InboxRowId -Row $boundRouteRow) -ceq (Get-InboxRowId -Row $otherBoundRouteRow)) {
    Add-Failure 'bound rows should share their task route while distinct full rows retain distinct row ids'
} else {
    Add-Check 'bound rows share their task route while distinct full rows retain distinct row ids'
}

$triageCollisionRows = @(
    Convert-InboxLineToRow -Line '| 2026-07-11 12:00:00 | collision-source | collision-task | selected-type | open | collision-summary | selected-payload |'
    Convert-InboxLineToRow -Line '| 2026-07-11 12:00:00 | collision-source | collision-task | selected-type | open | collision-summary | other-payload |'
)
Write-RuntimeInbox -InboxPath $triageCollisionInbox -CreatedDate '2026-07-11' -Rows $triageCollisionRows
$triageBroadOutput = @(& (Join-Path $RepoRoot 'scripts\triage-runtime-inbox.ps1') `
    -VaultRoot $triageCollisionVault `
    -Type 'selected-type' `
    -SetStatus 'cleared' 2>&1)
$triageBroadExit = $LASTEXITCODE
$triageBroadAfter = Get-Content -LiteralPath $triageCollisionInbox -Raw -Encoding utf8
$selectedRowId = Get-InboxRowId -Row $triageCollisionRows[0]
$triageCollisionOutput = @(& (Join-Path $RepoRoot 'scripts\triage-runtime-inbox.ps1') `
    -VaultRoot $triageCollisionVault `
    -RowId $selectedRowId `
    -SetStatus 'cleared' 2>&1)
$triageCollisionExit = $LASTEXITCODE
$triageCollisionAfter = Get-Content -LiteralPath $triageCollisionInbox -Raw -Encoding utf8

if ($triageBroadExit -eq 0 -or $triageBroadAfter -notmatch '\|\s*open\s*\|') {
    Add-Failure 'triage should reject a selector spanning distinct full-row identities'
} elseif ($triageCollisionExit -ne 0) {
    Add-Failure ('triage-runtime-inbox should resolve one row_id-selected bound-task row: {0}' -f ($triageCollisionOutput -join ' | '))
} elseif (
    $triageCollisionAfter -notmatch '\|\s*2026-07-11 12:00:00\s*\|\s*collision-source\s*\|\s*collision-task\s*\|\s*selected-type\s*\|\s*cleared\s*\|\s*collision-summary\s*\|\s*selected-payload\s*\|' -or
    $triageCollisionAfter -notmatch '\|\s*2026-07-11 12:00:00\s*\|\s*collision-source\s*\|\s*collision-task\s*\|\s*selected-type\s*\|\s*open\s*\|\s*collision-summary\s*\|\s*other-payload\s*\|'
) {
    Add-Failure 'triage-runtime-inbox should update only the exact payload-selected seven-column row'
} else {
    Add-Check 'triage rejects a shared bound-task route and row_id selects one full-row identity'
}

$autoTaskCaseRoot = Join-Path $tmpRoot 'canonical-pointer-precedence'
if (Test-Path -LiteralPath $autoTaskCaseRoot) {
    Remove-Item -LiteralPath $autoTaskCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $autoTaskCaseRoot -Force | Out-Null
$autoTaskWorkspaceRoot = Join-Path $autoTaskCaseRoot 'workspace'
$autoTaskVaultRoot = Join-Path $autoTaskWorkspaceRoot '.assistant'
$autoTaskRuntimeDir = Join-Path $autoTaskVaultRoot $runtimeDirName
$autoTaskOrchestrationDir = Join-Path $autoTaskVaultRoot 'orchestration'
New-Item -ItemType Directory -Path $autoTaskWorkspaceRoot,$autoTaskRuntimeDir,$autoTaskOrchestrationDir -Force | Out-Null

$autoTaskFlowPath = Join-Path $autoTaskOrchestrationDir 'current-flow.md'
$autoTaskFlowContent = @(
    '---'
    'task_id: sample-task'
    'task_name: Sample Task'
    'stage: PLAN'
    'current_doc: docs/tasks/sample-task/plan.md'
    'next: Finish the implementation notes'
    '---'
) -join "`r`n"
Set-Content -LiteralPath $autoTaskFlowPath -Value $autoTaskFlowContent -Encoding utf8

$autoTaskCurrentTaskPath = Join-Path $autoTaskRuntimeDir $currentTaskFileName
$autoTaskCurrentTaskContent = New-CanonicalCurrentTaskContent `
    -TaskId 'none' `
    -TaskName 'none' `
    -Stage $idleText `
    -CurrentDoc 'none' `
    -Tool 'none' `
    -EntryHost 'test' `
    -NextStep 'wait' `
    -Updated '2026-04-03T12:00:00+08:00' `
    -Writer 'test'
Set-Content -LiteralPath $autoTaskCurrentTaskPath -Value $autoTaskCurrentTaskContent -Encoding utf8

$autoTaskResult = Invoke-AppendInbox `
    -VaultRoot '' `
    -TaskId '' `
    -Type 'inbox-first' `
    -Summary 'Idle pointer blocks stale flow' `
    -Payload 'Use unknown when the canonical pointer is idle.' `
    -Source 'manual-test' `
    -WorkingDirectory $autoTaskWorkspaceRoot
$autoTaskInboxPath = Join-Path $autoTaskRuntimeDir $inboxFileName
$autoTaskContent = Get-Content -LiteralPath $autoTaskInboxPath -Raw -Encoding utf8

if ($autoTaskResult.ExitCode -ne 0) {
    Add-Failure 'append-runtime-inbox should return exit code 0 when run from a workspace cwd without an explicit TaskId'
} else {
    Add-Check 'append-runtime-inbox returns exit code 0 when run from a workspace cwd without an explicit TaskId'
}

if ($autoTaskContent -notmatch '\|\s*.+?\s*\|\s*manual-test\s*\|\s*unknown\s*\|\s*inbox-first\s*\|\s*open\s*\|\s*Idle pointer blocks stale flow\s*\|') {
    Add-Failure 'append-runtime-inbox should not resurrect stale current-flow when the canonical pointer is idle'
} else {
    Add-Check 'append-runtime-inbox does not resurrect stale current-flow when the canonical pointer is idle'
}

$activeTaskCurrentTaskContent = New-CanonicalCurrentTaskContent `
    -TaskId 'active-task' `
    -TaskName 'Active Task' `
    -Stage 'PLAN' `
    -CurrentDoc 'docs/tasks/active-task/plan.md' `
    -Tool 'codex' `
    -EntryHost 'test' `
    -NextStep 'continue' `
    -Updated '2026-04-03T12:00:00+08:00' `
    -Writer 'test'
Set-Content -LiteralPath $autoTaskCurrentTaskPath -Value $activeTaskCurrentTaskContent -Encoding utf8
if ((Resolve-EntryTaskId -VaultRoot $autoTaskVaultRoot) -ne 'active-task') {
    Add-Failure 'Resolve-EntryTaskId should prefer a valid active canonical pointer over stale current-flow'
} else {
    Add-Check 'Resolve-EntryTaskId prefers a valid active canonical pointer over stale current-flow'
}

$malformedPointerCases = @(
    $activeTaskCurrentTaskContent.Replace('schema_version: current-task-pointer/v1.1', 'schema_version: malformed-pointer/v0')
    $activeTaskCurrentTaskContent.Replace('| 状态 | PLAN |', '| 状态 | plan |')
    $activeTaskCurrentTaskContent.Replace('updated: 2026-04-03T12:00:00+08:00', 'updated: 2026-04-03 12:00')
)
$malformedPointersRejected = $true
foreach ($malformedPointer in $malformedPointerCases) {
    Set-Content -LiteralPath $autoTaskCurrentTaskPath -Value $malformedPointer -Encoding utf8
    if ((Resolve-EntryTaskId -VaultRoot $autoTaskVaultRoot) -ne 'unknown') {
        $malformedPointersRejected = $false
    }
}
if (-not $malformedPointersRejected) {
    Add-Failure 'Resolve-EntryTaskId should fail closed when an existing canonical pointer has invalid schema, stage case, or timestamp'
} else {
    Add-Check 'Resolve-EntryTaskId fails closed when an existing canonical pointer has invalid schema, stage case, or timestamp'
}

Remove-Item -LiteralPath $autoTaskCurrentTaskPath -Force
if ((Resolve-EntryTaskId -VaultRoot $autoTaskVaultRoot) -ne 'sample-task') {
    Add-Failure 'Resolve-EntryTaskId should use a valid legacy current-flow only when the canonical pointer file is missing'
} else {
    Add-Check 'Resolve-EntryTaskId uses a valid legacy current-flow only when the canonical pointer file is missing'
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
