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

function New-RepairFixture {
    param(
        [string]$CaseRoot,
        [string]$PointerTaskId = "sample-task",
        [string]$PointerTask = "Sample Task",
        [string]$PointerStatus = "TEST",
        [string]$FlowTaskId = "sample-task",
        [string]$FlowTaskName = "Sample Task",
        [string]$FlowStage = "TEST",
        [string]$FlowCurrentDoc = "docs/tasks/sample-task/test.md",
        [string]$FlowNext = "Run TEST"
    )

    $assistantRoot = Join-Path $CaseRoot ".assistant"
    $runtimeDirName = Convert-CodePointsToString -CodePoints @(36816, 34892, 26102)
    $currentTaskFileName = Convert-CodePointsToString -CodePoints @(24403, 21069, 20219, 21153, 46, 109, 100)
    $interruptedFileName = Convert-CodePointsToString -CodePoints @(20013, 26029, 20219, 21153, 46, 109, 100)
    $lastSessionFileName = Convert-CodePointsToString -CodePoints @(19978, 27425, 20250, 35805, 46, 109, 100)
    $indexFileName = Convert-CodePointsToString -CodePoints @(24674, 22797, 32034, 24341, 46, 109, 100)
    $candidateFileName = Convert-CodePointsToString -CodePoints @(35760, 24518, 20505, 36873, 46, 109, 100)
    $archiveFileName = Convert-CodePointsToString -CodePoints @(35760, 24518, 20505, 36873, 24402, 26723, 46, 109, 100)
    $inboxFileName = Convert-CodePointsToString -CodePoints @(25910, 20214, 31665, 46, 109, 100)
    $taskKey = Convert-CodePointsToString -CodePoints @(20219, 21153)
    $statusKey = Convert-CodePointsToString -CodePoints @(29366, 24577)
    $nextKey = Convert-CodePointsToString -CodePoints @(19979, 19968, 27493)
    $dateKey = Convert-CodePointsToString -CodePoints @(26085, 26399)
    $summaryKey = Convert-CodePointsToString -CodePoints @(25688, 35201)

    $runtimeDir = Join-Path $assistantRoot $runtimeDirName
    $orchestrationDir = Join-Path $assistantRoot "orchestration"

    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    New-Item -ItemType Directory -Path $orchestrationDir -Force | Out-Null

    $currentPath = Join-Path $runtimeDir $currentTaskFileName
    $interruptedPath = Join-Path $runtimeDir $interruptedFileName
    $lastSessionPath = Join-Path $runtimeDir $lastSessionFileName
    $indexPath = Join-Path $runtimeDir $indexFileName
    $candidatePath = Join-Path $runtimeDir $candidateFileName
    $archivePath = Join-Path $runtimeDir $archiveFileName
    $inboxPath = Join-Path $runtimeDir $inboxFileName
    $lockPath = Join-Path $runtimeDir "runtime.lock.json"
    $tasksDir = Join-Path $runtimeDir "tasks"
    $currentFlowPath = Join-Path $orchestrationDir "current-flow.md"

    $currentContent = @(
        "---",
        "updated: 2026-04-03 09:00:00",
        "task_id: $PointerTaskId",
        "---",
        "",
        "| Key | Value |",
        "|-----|-------|",
        ("| task_id | `{0}` |" -f $PointerTaskId),
        ("| {0} | {1} |" -f $taskKey, $PointerTask),
        ("| {0} | {1} |" -f $statusKey, $PointerStatus),
        ("| {0} | Run TEST |" -f $nextKey)
    ) -join "`r`n"
    Set-Content -LiteralPath $currentPath -Value $currentContent -Encoding utf8

    $interruptedContent = @(
        "---",
        "updated: 2026-04-03 08:30:00",
        "---",
        "",
        "| Priority | Name | Task | Status | Next |",
        "|----------|------|------|--------|------|"
    ) -join "`r`n"
    Set-Content -LiteralPath $interruptedPath -Value $interruptedContent -Encoding utf8

    $lastSessionContent = @(
        "---",
        "updated: 2026-04-03 08:45:00",
        "---",
        "",
        "| Key | Value |",
        "|-----|-------|",
        ("| {0} | 2026-04-03 |" -f $dateKey),
        ("| {0} | Sample Task |" -f $taskKey),
        ("| {0} | PLAN |" -f $statusKey),
        ("| {0} | Planning complete |" -f $summaryKey)
    ) -join "`r`n"
    Set-Content -LiteralPath $lastSessionPath -Value $lastSessionContent -Encoding utf8

    $inboxContent = @(
        "---",
        "tags: [runtime, inbox]",
        "created: 2026-04-03",
        "updated: 2026-04-03 08:50:00",
        "schema_version: runtime-inbox/v1.0",
        "---",
        "",
        "# Runtime Inbox",
        "",
        "| created_at | source | task_id | type | status | summary | payload |",
        "|------------|--------|---------|------|--------|---------|---------|",
        "| 2026-04-03 08:50:00 | claude-posttooluse | sample-task | lock-blocked | open | Recovery-index refresh blocked by runtime lock. | Shared runtime lock is held by another writer. |"
    ) -join "`r`n"
    Set-Content -LiteralPath $inboxPath -Value $inboxContent -Encoding utf8

    $currentFlowContent = @(
        "schema_version: 2.2",
        "task_id: $FlowTaskId",
        "task_name: $FlowTaskName",
        "stage: $FlowStage",
        "current_doc: $FlowCurrentDoc",
        "next: $FlowNext"
    ) -join "`r`n"
    Set-Content -LiteralPath $currentFlowPath -Value $currentFlowContent -Encoding utf8

    return [pscustomobject]@{
        AssistantRoot   = $assistantRoot
        CurrentPath     = $currentPath
        InterruptedPath = $interruptedPath
        LastSessionPath = $lastSessionPath
        IndexPath       = $indexPath
        CandidatePath   = $candidatePath
        ArchivePath     = $archivePath
        InboxPath       = $inboxPath
        LockPath        = $lockPath
        TasksDir        = $tasksDir
        CurrentFlowPath = $currentFlowPath
    }
}

function Invoke-Repair {
    param(
        [string]$VaultRoot,
        [string]$EntryHost = 'team-leader'
    )

    $scriptPath = Join-Path $RepoRoot "scripts\\repair-shared-memory.ps1"
    $output = @(& $scriptPath -VaultRoot $VaultRoot -EntryHost $EntryHost 2>&1)
    return [pscustomobject]@{
        Output   = @($output | ForEach-Object { [string]$_ })
        ExitCode = $LASTEXITCODE
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$tmpRoot = Join-Path $RepoRoot "tmp\\repair-shared-memory-regression"
$noneLabel = Convert-CodePointsToString -CodePoints @(26080)
$idleStatus = Convert-CodePointsToString -CodePoints @(31354, 38386)
$statusKey = Convert-CodePointsToString -CodePoints @(29366, 24577)
$currentDocKey = Convert-CodePointsToString -CodePoints @(24403, 21069, 25991, 26723)
$recoveryIndexFileName = (Convert-CodePointsToString -CodePoints @(24674, 22797, 32034, 24341)) + ".md"
$inboxFileName = (Convert-CodePointsToString -CodePoints @(25910, 20214, 31665)) + ".md"

if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$blockedCaseRoot = Join-Path $tmpRoot "active-lock-blocks-repair"
New-Item -ItemType Directory -Path $blockedCaseRoot -Force | Out-Null
$blockedFixture = New-RepairFixture -CaseRoot $blockedCaseRoot
$activeLock = [ordered]@{
    writer    = "other-writer"
    task_id   = "sample-task"
    locked_at = [datetimeoffset]::UtcNow.ToString("o")
    entry_host = "codex"
} | ConvertTo-Json -Depth 3
Set-Content -LiteralPath $blockedFixture.LockPath -Value $activeLock -Encoding utf8
$blockedResult = Invoke-Repair -VaultRoot $blockedFixture.AssistantRoot
$blockedOutput = $blockedResult.Output -join [Environment]::NewLine

if ($blockedResult.ExitCode -ne 1) {
    Add-Failure "repair-shared-memory should return exit code 1 when a valid runtime.lock.json is held by another writer"
} else {
    Add-Check "repair-shared-memory returns exit code 1 when a valid runtime.lock.json is held by another writer"
}

if ($blockedOutput -notmatch "STATUS:\s+WARN") {
    Add-Failure "repair-shared-memory should report STATUS: WARN when blocked by an active runtime lock"
} else {
    Add-Check "repair-shared-memory reports STATUS: WARN when blocked by an active runtime lock"
}

if ($blockedOutput -notmatch "Blocked: active runtime\.lock\.json is held by other-writer for task sample-task; skipped shared runtime repair\.") {
    Add-Failure "repair-shared-memory should explain which active runtime lock blocked the repair"
} else {
    Add-Check "repair-shared-memory explains which active runtime lock blocked the repair"
}

if (Test-Path -LiteralPath $blockedFixture.IndexPath -PathType Leaf) {
    Add-Failure "repair-shared-memory should not refresh recovery-index while another writer holds runtime.lock.json"
} else {
    Add-Check "repair-shared-memory leaves recovery-index untouched while another writer holds runtime.lock.json"
}

if (Test-Path -LiteralPath $blockedFixture.CandidatePath -PathType Leaf) {
    Add-Failure "repair-shared-memory should not create other shared runtime artifacts while blocked by an active runtime.lock.json"
} else {
    Add-Check "repair-shared-memory does not create other shared runtime artifacts while blocked by an active runtime.lock.json"
}

$blockedInboxContent = Get-Content -LiteralPath $blockedFixture.InboxPath -Raw -Encoding utf8
if ($blockedInboxContent -notmatch "\|\s*2026-04-03 08:50:00\s*\|\s*claude-posttooluse\s*\|\s*sample-task\s*\|\s*lock-blocked\s*\|\s*open\s*\|") {
    Add-Failure "repair-shared-memory should leave lock-blocked inbox rows open when another writer still holds the runtime lock"
} else {
    Add-Check "repair-shared-memory leaves lock-blocked inbox rows open when another writer still holds the runtime lock"
}

$expiredCaseRoot = Join-Path $tmpRoot "expired-lock-allows-repair"
New-Item -ItemType Directory -Path $expiredCaseRoot -Force | Out-Null
$expiredFixture = New-RepairFixture -CaseRoot $expiredCaseRoot
$expiredLock = [ordered]@{
    writer    = "stale-writer"
    task_id   = "sample-task"
    locked_at = ([datetimeoffset]::UtcNow.AddMinutes(-31)).ToString("o")
    entry_host = "codex"
} | ConvertTo-Json -Depth 3
Set-Content -LiteralPath $expiredFixture.LockPath -Value $expiredLock -Encoding utf8
$expiredResult = Invoke-Repair -VaultRoot $expiredFixture.AssistantRoot
$expiredOutput = $expiredResult.Output -join [Environment]::NewLine

if ($expiredResult.ExitCode -ne 0) {
    Add-Failure "repair-shared-memory should return exit code 0 after removing an expired runtime.lock.json and completing repair"
} else {
    Add-Check "repair-shared-memory returns exit code 0 after removing an expired runtime.lock.json and completing repair"
}

if ($expiredOutput -notmatch "STATUS:\s+PASS") {
    Add-Failure "repair-shared-memory should report STATUS: PASS after removing an expired runtime lock and repairing shared runtime"
} else {
    Add-Check "repair-shared-memory reports STATUS: PASS after removing an expired runtime lock and repairing shared runtime"
}

if ($expiredOutput -notmatch "removed expired runtime\.lock\.json") {
    Add-Failure "repair-shared-memory should report expired runtime.lock.json cleanup"
} else {
    Add-Check "repair-shared-memory reports expired runtime.lock.json cleanup"
}

if ($expiredOutput -notmatch ("refreshed .+{0}" -f [regex]::Escape($recoveryIndexFileName))) {
    Add-Failure "repair-shared-memory should refresh recovery-index after it acquires the runtime lock"
} else {
    Add-Check "repair-shared-memory refreshes recovery-index after it acquires the runtime lock"
}

if (-not (Test-Path -LiteralPath $expiredFixture.IndexPath -PathType Leaf)) {
    Add-Failure "repair-shared-memory should create or refresh recovery-index after removing an expired runtime.lock.json"
} else {
    Add-Check "repair-shared-memory creates or refreshes recovery-index after removing an expired runtime.lock.json"
}

if ($expiredOutput -notmatch "cleared 1 lock-blocked inbox item\(s\)") {
    Add-Failure "repair-shared-memory should report when it clears stale lock-blocked inbox rows after a successful repair"
} else {
    Add-Check "repair-shared-memory reports when it clears stale lock-blocked inbox rows after a successful repair"
}

$expiredInboxContent = Get-Content -LiteralPath $expiredFixture.InboxPath -Raw -Encoding utf8
$expiredCurrentTaskContent = Get-Content -LiteralPath $expiredFixture.CurrentPath -Raw -Encoding utf8
$expiredIndexContent = Get-Content -LiteralPath $expiredFixture.IndexPath -Raw -Encoding utf8
if ($expiredInboxContent -notmatch "\|\s*2026-04-03 08:50:00\s*\|\s*claude-posttooluse\s*\|\s*sample-task\s*\|\s*lock-blocked\s*\|\s*cleared\s*\|") {
    Add-Failure "repair-shared-memory should clear stale lock-blocked inbox rows after refreshing shared runtime"
} else {
    Add-Check "repair-shared-memory clears stale lock-blocked inbox rows after refreshing shared runtime"
}

if ($expiredInboxContent -notmatch [regex]::Escape("Resolved by repair-shared-memory after refreshing recovery-index.")) {
    Add-Failure "repair-shared-memory should append a repair note when it clears lock-blocked inbox rows"
} else {
    Add-Check "repair-shared-memory appends a repair note when it clears lock-blocked inbox rows"
}

if ($expiredCurrentTaskContent -notmatch 'entry_host:\s+team-leader') {
    Add-Failure 'repair-shared-memory should persist entry_host into current-task.md during repair'
} else {
    Add-Check 'repair-shared-memory persists entry_host into current-task.md during repair'
}

if ($expiredIndexContent -notmatch [regex]::Escape('derived_from: [运行时/tasks/, 运行时/中断任务.md]')) {
    Add-Failure 'repair-shared-memory should persist derived_from into recovery-index during repair'
} else {
    Add-Check 'repair-shared-memory persists derived_from into recovery-index during repair'
}

if (Test-Path -LiteralPath $expiredFixture.LockPath -PathType Leaf) {
    Add-Failure "repair-shared-memory should release the runtime lock it acquired during repair"
} else {
    Add-Check "repair-shared-memory releases the runtime lock it acquired during repair"
}

$flowCaseRoot = Join-Path $tmpRoot "flow-precedence-recreates-inbox"
New-Item -ItemType Directory -Path $flowCaseRoot -Force | Out-Null
$flowFixture = New-RepairFixture `
    -CaseRoot $flowCaseRoot `
    -PointerTaskId "none" `
    -PointerTask $noneLabel `
    -PointerStatus $idleStatus `
    -FlowTaskId "sample-task" `
    -FlowTaskName "Sample Task" `
    -FlowStage "TEST" `
        -FlowCurrentDoc "docs/tasks/sample-task/test.md" `
    -FlowNext "Continue TEST"
Remove-Item -LiteralPath $flowFixture.InboxPath -Force
$flowResult = Invoke-Repair -VaultRoot $flowFixture.AssistantRoot
$flowOutput = $flowResult.Output -join [Environment]::NewLine

if ($flowResult.ExitCode -ne 0) {
    Add-Failure "repair-shared-memory should return exit code 0 when recreating a missing runtime inbox and rebuilding recovery-index from current-flow"
} else {
    Add-Check "repair-shared-memory returns exit code 0 when recreating a missing runtime inbox and rebuilding recovery-index from current-flow"
}

if ($flowOutput -notmatch ("created .+{0}" -f [regex]::Escape($inboxFileName))) {
    Add-Failure "repair-shared-memory should report when it recreates a missing runtime inbox"
} else {
    Add-Check "repair-shared-memory reports when it recreates a missing runtime inbox"
}

if (-not (Test-Path -LiteralPath $flowFixture.InboxPath -PathType Leaf)) {
    Add-Failure "repair-shared-memory should recreate runtime inbox when it is missing"
} else {
    Add-Check "repair-shared-memory recreates runtime inbox when it is missing"
}

$flowInboxContent = Get-Content -LiteralPath $flowFixture.InboxPath -Raw -Encoding utf8
$expectedInboxHeader = "| created_at | source | task_id | type | status | summary | payload |"
if ($flowInboxContent -notmatch [regex]::Escape($expectedInboxHeader)) {
    Add-Failure "repair-shared-memory should recreate runtime inbox with the standard inbox table header"
} else {
    Add-Check "repair-shared-memory recreates runtime inbox with the standard inbox table header"
}

$flowIndexContent = Get-Content -LiteralPath $flowFixture.IndexPath -Raw -Encoding utf8
$flowCurrentTaskContent = Get-Content -LiteralPath $flowFixture.CurrentPath -Raw -Encoding utf8
$flowTaskRuntimePath = Join-Path $flowFixture.TasksDir 'sample-task.md'
$flowTaskRuntimeContent = if (Test-Path -LiteralPath $flowTaskRuntimePath -PathType Leaf) {
    Get-Content -LiteralPath $flowTaskRuntimePath -Raw -Encoding utf8
} else {
    ''
}
$expectedTaskIdLine = "- task_id: " + [char]96 + "sample-task" + [char]96
$expectedStatusLine = "- {0}: TEST" -f $statusKey
$expectedCurrentDocLine = "- {0}: docs/tasks/sample-task/test.md" -f $currentDocKey

if ($flowIndexContent -notmatch [regex]::Escape($expectedTaskIdLine)) {
    Add-Failure "repair-shared-memory should write the current-flow task_id into recovery-index"
} else {
    Add-Check "repair-shared-memory writes the current-flow task_id into recovery-index"
}

if ($flowIndexContent -notmatch [regex]::Escape($expectedStatusLine)) {
    Add-Failure "repair-shared-memory should rebuild recovery-index from current-flow stage when the shared pointer is idle"
} else {
    Add-Check "repair-shared-memory rebuilds recovery-index from current-flow stage when the shared pointer is idle"
}

if ($flowIndexContent -notmatch [regex]::Escape($expectedCurrentDocLine)) {
    Add-Failure "repair-shared-memory should carry current-flow current_doc into recovery-index"
} else {
    Add-Check "repair-shared-memory carries current-flow current_doc into recovery-index"
}

if (
    $flowCurrentTaskContent -notmatch [regex]::Escape('| task_id | `sample-task` |') -or
    $flowCurrentTaskContent -notmatch [regex]::Escape("| {0} | TEST |" -f $statusKey)
) {
    Add-Failure "repair-shared-memory should synchronize current-task.md from current-flow when the shared pointer is idle"
} else {
    Add-Check "repair-shared-memory synchronizes current-task.md from current-flow when the shared pointer is idle"
}

if (
    -not (Test-Path -LiteralPath $flowTaskRuntimePath -PathType Leaf) -or
    $flowTaskRuntimeContent -notmatch [regex]::Escape('primary_artifact: docs/tasks/sample-task/test.md') -or
    $flowTaskRuntimeContent -notmatch [regex]::Escape('- stage: TEST') -or
    $flowTaskRuntimeContent -notmatch 'entry_host:\s+team-leader'
) {
    Add-Failure "repair-shared-memory should create a minimal task runtime with entry_host from current-flow when tasks/<task-id>.md is missing"
} else {
    Add-Check "repair-shared-memory creates a minimal task runtime with entry_host from current-flow when tasks/<task-id>.md is missing"
}

$missingPointerCaseRoot = Join-Path $tmpRoot "missing-pointer-files-recreated"
New-Item -ItemType Directory -Path $missingPointerCaseRoot -Force | Out-Null
$missingPointerFixture = New-RepairFixture `
    -CaseRoot $missingPointerCaseRoot `
    -PointerTaskId "none" `
    -PointerTask $noneLabel `
    -PointerStatus $idleStatus `
    -FlowTaskId "sample-task" `
    -FlowTaskName "Sample Task" `
    -FlowStage "TEST" `
        -FlowCurrentDoc "docs/tasks/sample-task/test.md" `
    -FlowNext "Continue TEST"
Remove-Item -LiteralPath $missingPointerFixture.CurrentPath -Force
Remove-Item -LiteralPath $missingPointerFixture.InterruptedPath -Force
Remove-Item -LiteralPath $missingPointerFixture.LastSessionPath -Force
$missingPointerResult = Invoke-Repair -VaultRoot $missingPointerFixture.AssistantRoot
$missingPointerOutput = $missingPointerResult.Output -join [Environment]::NewLine

if ($missingPointerResult.ExitCode -ne 0) {
    Add-Failure "repair-shared-memory should return exit code 0 when recreating missing pointer/runtime summary files"
} else {
    Add-Check "repair-shared-memory returns exit code 0 when recreating missing pointer/runtime summary files"
}

if (
    $missingPointerOutput -notmatch ("created .+{0}" -f [regex]::Escape((Split-Path $missingPointerFixture.CurrentPath -Leaf))) -or
    $missingPointerOutput -notmatch ("created .+{0}" -f [regex]::Escape((Split-Path $missingPointerFixture.InterruptedPath -Leaf))) -or
    $missingPointerOutput -notmatch ("created .+{0}" -f [regex]::Escape((Split-Path $missingPointerFixture.LastSessionPath -Leaf)))
) {
    Add-Failure "repair-shared-memory should report recreating missing current-task/interrupted-task/last-session files"
} else {
    Add-Check "repair-shared-memory reports recreating missing current-task/interrupted-task/last-session files"
}

if (
    -not (Test-Path -LiteralPath $missingPointerFixture.CurrentPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $missingPointerFixture.InterruptedPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $missingPointerFixture.LastSessionPath -PathType Leaf)
) {
    Add-Failure "repair-shared-memory should recreate missing current-task/interrupted-task/last-session files"
} else {
    Add-Check "repair-shared-memory recreates missing current-task/interrupted-task/last-session files"
}

$idleCaseRoot = Join-Path $tmpRoot "idle-pointer-uses-none-current-doc"
New-Item -ItemType Directory -Path $idleCaseRoot -Force | Out-Null
$idleFixture = New-RepairFixture `
    -CaseRoot $idleCaseRoot `
    -PointerTaskId "none" `
    -PointerTask $noneLabel `
    -PointerStatus $idleStatus `
    -FlowTaskId "none" `
    -FlowTaskName $noneLabel `
    -FlowStage $idleStatus `
    -FlowCurrentDoc "none" `
    -FlowNext "等待新任务"
$idleResult = Invoke-Repair -VaultRoot $idleFixture.AssistantRoot
$idleCurrentTaskContent = Get-Content -LiteralPath $idleFixture.CurrentPath -Raw -Encoding utf8
$idleIndexContent = Get-Content -LiteralPath $idleFixture.IndexPath -Raw -Encoding utf8
$expectedIdleCurrentDocLine = "| {0} | none |" -f $currentDocKey
$expectedIdleIndexCurrentDocLine = "- {0}: none" -f $currentDocKey

if ($idleResult.ExitCode -ne 0) {
    Add-Failure "repair-shared-memory should return exit code 0 for an idle shared runtime"
} else {
    Add-Check "repair-shared-memory returns exit code 0 for an idle shared runtime"
}

if (
    $idleCurrentTaskContent -notmatch [regex]::Escape($expectedIdleCurrentDocLine) -or
    $idleCurrentTaskContent -match [regex]::Escape('docs/tasks/none/plan.md')
) {
    Add-Failure 'repair-shared-memory should write `none` instead of a fake docs/tasks/none/plan.md pointer when runtime is idle'
} else {
    Add-Check 'repair-shared-memory writes `none` instead of a fake docs/tasks/none/plan.md pointer when runtime is idle'
}

if (
    $idleIndexContent -notmatch [regex]::Escape($expectedIdleIndexCurrentDocLine) -or
    $idleIndexContent -match [regex]::Escape('docs/tasks/none/plan.md')
) {
    Add-Failure 'repair-shared-memory should keep recovery-index idle current_doc at `none`'
} else {
    Add-Check 'repair-shared-memory keeps recovery-index idle current_doc at `none`'
}

$flowTimestampCaseRoot = Join-Path $tmpRoot "current-flow-newer-than-index"
New-Item -ItemType Directory -Path $flowTimestampCaseRoot -Force | Out-Null
$flowTimestampFixture = New-RepairFixture `
    -CaseRoot $flowTimestampCaseRoot `
    -PointerTaskId "none" `
    -PointerTask $noneLabel `
    -PointerStatus $idleStatus `
    -FlowTaskId "sample-task" `
    -FlowTaskName "Sample Task" `
    -FlowStage "TEST" `
        -FlowCurrentDoc "docs/tasks/sample-task/test.md" `
    -FlowNext "Continue TEST"

New-Item -ItemType Directory -Path $flowTimestampFixture.TasksDir -Force | Out-Null
Set-Content -LiteralPath $flowTimestampFixture.CandidatePath -Value "# candidate" -Encoding utf8
Set-Content -LiteralPath $flowTimestampFixture.ArchivePath -Value "# archive" -Encoding utf8
$staleTaskIdLine = "- task_id: " + [char]96 + "none" + [char]96
Set-Content -LiteralPath $flowTimestampFixture.IndexPath -Value (@(
    "---",
    "updated: 2026-04-03 09:30:00",
    "---",
    "",
    "# stale",
    $staleTaskIdLine,
    ("- {0}: {1}" -f $statusKey, $idleStatus)
) -join "`r`n") -Encoding utf8
(Get-Item -LiteralPath $flowTimestampFixture.CurrentFlowPath).LastWriteTime = [datetime]"2026-04-03 10:00:00"
$flowTimestampResult = Invoke-Repair -VaultRoot $flowTimestampFixture.AssistantRoot
$flowTimestampOutput = $flowTimestampResult.Output -join [Environment]::NewLine
$flowTimestampIndexContent = Get-Content -LiteralPath $flowTimestampFixture.IndexPath -Raw -Encoding utf8

if ($flowTimestampResult.ExitCode -ne 0) {
    Add-Failure "repair-shared-memory should return exit code 0 when current-flow is newer than recovery-index"
} else {
    Add-Check "repair-shared-memory returns exit code 0 when current-flow is newer than recovery-index"
}

if ($flowTimestampOutput -notmatch ("refreshed .+{0}" -f [regex]::Escape($recoveryIndexFileName))) {
    Add-Failure "repair-shared-memory should refresh recovery-index when current-flow changes after the last index rebuild"
} else {
    Add-Check "repair-shared-memory refreshes recovery-index when current-flow changes after the last index rebuild"
}

if ($flowTimestampIndexContent -notmatch [regex]::Escape($expectedTaskIdLine)) {
    Add-Failure "repair-shared-memory should not leave a stale idle task_id in recovery-index when current-flow is newer"
} else {
    Add-Check "repair-shared-memory does not leave a stale idle task_id in recovery-index when current-flow is newer"
}

if ($flowTimestampIndexContent -notmatch [regex]::Escape($expectedStatusLine)) {
    Add-Failure "repair-shared-memory should refresh recovery-index from current-flow even when current-task timestamps are older"
} else {
    Add-Check "repair-shared-memory refreshes recovery-index from current-flow even when current-task timestamps are older"
}

Write-Output "Checks:"
if ($script:Checks.Count -eq 0) {
    Write-Output "- none"
} else {
    foreach ($item in $script:Checks) {
        Write-Output ("- {0}" -f $item)
    }
}

Write-Output ""
Write-Output "Failures:"
if ($script:Failures.Count -eq 0) {
    Write-Output "- none"
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ("- {0}" -f $failure)
}

exit 1
