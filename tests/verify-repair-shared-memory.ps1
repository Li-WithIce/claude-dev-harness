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
        [string]$EntryHost = 'team-leader',
        [string]$RetireInactiveTaskId = '',
        [string]$ExpectedRetireStage = ''
    )

    $scriptPath = Join-Path $RepoRoot "scripts\\repair-shared-memory.ps1"
    $arguments = @{
        VaultRoot = $VaultRoot
        EntryHost = $EntryHost
    }
    if (-not [string]::IsNullOrWhiteSpace($RetireInactiveTaskId)) {
        $arguments.RetireInactiveTaskId = $RetireInactiveTaskId
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRetireStage)) {
        $arguments.ExpectedRetireStage = $ExpectedRetireStage
    }
    $output = @(& $scriptPath @arguments 2>&1)
    return [pscustomobject]@{
        Output   = @($output | ForEach-Object { [string]$_ })
        ExitCode = $LASTEXITCODE
    }
}

function Start-RepairProcess {
    param(
        [string]$VaultRoot,
        [string]$RetireInactiveTaskId = '',
        [string]$ExpectedRetireStage = ''
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'scripts\repair-shared-memory.ps1'), '-VaultRoot', $VaultRoot, '-EntryHost', 'team-leader')
    if (-not [string]::IsNullOrWhiteSpace($RetireInactiveTaskId)) {
        $arguments += @('-RetireInactiveTaskId', $RetireInactiveTaskId)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRetireStage)) {
        $arguments += @('-ExpectedRetireStage', $ExpectedRetireStage)
    }
    foreach ($argument in $arguments) {
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

function Get-FileDigestOrMissing {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return '<missing>'
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-RetirementSnapshot {
    param([string[]]$Paths)

    $snapshot = [ordered]@{}
    foreach ($path in $Paths) {
        $snapshot[[System.IO.Path]::GetFullPath($path)] = Get-FileDigestOrMissing -Path $path
    }
    return $snapshot
}

function Test-RetirementSnapshotMatches {
    param(
        [System.Collections.IDictionary]$Snapshot,
        [string[]]$Paths
    )

    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if (-not $Snapshot.Contains($fullPath) -or $Snapshot[$fullPath] -cne (Get-FileDigestOrMissing -Path $path)) {
            return $false
        }
    }
    return $true
}

function New-RetirementFixture {
    param([string]$CaseRoot)

    $fixture = New-RepairFixture -CaseRoot $CaseRoot
    $targetTaskId = 'retire-inactive-task'
    $currentTaskId = 'current-safe-task'
    $targetPlanPath = Join-Path $CaseRoot "docs\tasks\$targetTaskId\plan.md"
    $targetManifestPath = Join-Path $CaseRoot "docs\tasks\$targetTaskId\skill-manifest.json"
    $targetMirrorPath = Join-Path $fixture.TasksDir "$targetTaskId.md"
    $currentMirrorPath = Join-Path $fixture.TasksDir "$currentTaskId.md"
    New-Item -ItemType Directory -Path (Split-Path -Parent $targetPlanPath),$fixture.TasksDir -Force | Out-Null

    Write-CanonicalRuntimeUtf8BomAtomic -Path $targetPlanPath -Content (@(
        '---',
        "task_id: $targetTaskId",
        'stage: IMPLEMENT',
        'tool: codex',
        'updated: 2026-07-13',
        '---',
        '# Retire inactive task'
    ) -join "`r`n")
    Write-CanonicalRuntimeUtf8BomAtomic -Path $targetManifestPath -Content '{"stage":"IMPLEMENT"}'
    Write-CanonicalRuntimeUtf8BomAtomic -Path $fixture.CurrentPath -Content (New-CanonicalCurrentTaskContent `
        -TaskId $currentTaskId `
        -TaskName $currentTaskId `
        -Stage 'TEST' `
        -CurrentDoc "docs/tasks/$currentTaskId/test.md" `
        -Tool 'codex' `
        -EntryHost 'codex' `
        -NextStep 'Continue TEST' `
        -Updated '2026-07-13T13:00:00+08:00')
    Write-CanonicalRuntimeUtf8BomAtomic -Path $targetMirrorPath -Content (New-CanonicalTaskRuntimeContent `
        -TaskId $targetTaskId `
        -TaskName $targetTaskId `
        -Stage 'IMPLEMENT' `
        -WorkspaceRoot $CaseRoot `
        -PrimaryArtifact "docs/tasks/$targetTaskId/plan.md" `
        -Tool 'codex' `
        -EntryHost 'codex' `
        -Updated '2026-07-13T12:00:00+08:00')
    Write-CanonicalRuntimeUtf8BomAtomic -Path $currentMirrorPath -Content (New-CanonicalTaskRuntimeContent `
        -TaskId $currentTaskId `
        -TaskName $currentTaskId `
        -Stage 'TEST' `
        -WorkspaceRoot $CaseRoot `
        -PrimaryArtifact "docs/tasks/$currentTaskId/test.md" `
        -Tool 'codex' `
        -EntryHost 'codex' `
        -Updated '2026-07-13T13:00:00+08:00')
    $current = Get-CanonicalCurrentTaskState -Path $fixture.CurrentPath
    $records = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory $fixture.TasksDir)
    Write-CanonicalRuntimeUtf8BomAtomic -Path $fixture.IndexPath -Content (New-CanonicalRecoveryIndexContent `
        -CurrentTask $current `
        -TaskRecords $records `
        -Updated '2026-07-13T13:00:00+08:00')

    return [pscustomobject]@{
        Base               = $fixture
        TargetTaskId       = $targetTaskId
        CurrentTaskId      = $currentTaskId
        TargetPlanPath     = $targetPlanPath
        TargetManifestPath = $targetManifestPath
        TargetMirrorPath   = $targetMirrorPath
        CurrentMirrorPath  = $currentMirrorPath
        ProtectedPaths     = @(
            $targetPlanPath,
            $targetManifestPath,
            $fixture.CurrentPath,
            $currentMirrorPath,
            $fixture.InboxPath,
            $fixture.InterruptedPath,
            $fixture.LastSessionPath
        )
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
. (Join-Path $RepoRoot 'scripts\lite-artifact-parser.ps1')
$script:Checks = @()
$script:Failures = @()
$tmpRoot = Join-Path $RepoRoot ('tmp\repair-shared-memory-regression-' + [guid]::NewGuid().ToString('N'))
$noneLabel = Convert-CodePointsToString -CodePoints @(26080)
$idleStatus = Convert-CodePointsToString -CodePoints @(31354, 38386)
$statusKey = Convert-CodePointsToString -CodePoints @(29366, 24577)
$currentDocKey = Convert-CodePointsToString -CodePoints @(24403, 21069, 25991, 26723)
$recoveryIndexFileName = (Convert-CodePointsToString -CodePoints @(24674, 22797, 32034, 24341)) + ".md"
$inboxFileName = (Convert-CodePointsToString -CodePoints @(25910, 20214, 31665)) + ".md"

try {
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$mutexCaseRoot = Join-Path $tmpRoot 'named-mutex-blocks-repair'
New-Item -ItemType Directory -Path $mutexCaseRoot -Force | Out-Null
$mutexFixture = New-RepairFixture -CaseRoot $mutexCaseRoot
$mutexRepair = $null
$mutexRepairPrimaryError = $null
$mutexRepairCleanupErrors = @()
try {
    $heldRuntimeMutex = Enter-CanonicalRuntimeMutex -VaultRoot $mutexFixture.AssistantRoot
    try {
        $mutexRepair = Start-RepairProcess -VaultRoot $mutexFixture.AssistantRoot
        [void]$mutexRepair.Process.WaitForExit(1500)
        $repairBlockedBeforeRelease = -not $mutexRepair.Process.HasExited -and
            -not (Test-Path -LiteralPath $mutexFixture.CandidatePath) -and
            -not (Test-Path -LiteralPath $mutexFixture.IndexPath)
    } finally {
        Exit-CanonicalRuntimeMutex -Mutex $heldRuntimeMutex
    }
    if (-not $mutexRepair.Process.WaitForExit(30000)) { throw 'repair-shared-memory child process timed out' }
    $mutexRepair.Process.WaitForExit()
    $mutexRepairOutput = $mutexRepair.StdOut.Result
    $mutexRepairError = $mutexRepair.StdErr.Result
    if ($repairBlockedBeforeRelease -and $mutexRepair.Process.ExitCode -eq 0 -and
        (Test-Path -LiteralPath $mutexFixture.CandidatePath) -and
        (Test-Path -LiteralPath $mutexFixture.IndexPath)) {
        Add-Check 'repair-shared-memory waits for the shared runtime mutex before its first mutation'
    } else {
        Add-Failure ("repair-shared-memory should wait for named mutex, blocked={0}, exit={1}, stdout={2}, stderr={3}" -f $repairBlockedBeforeRelease, $mutexRepair.Process.ExitCode, $mutexRepairOutput, $mutexRepairError)
    }
} catch {
    $mutexRepairPrimaryError = $_
} finally {
    if ($null -ne $mutexRepair) {
        try {
            if (-not $mutexRepair.Process.HasExited) { $mutexRepair.Process.Kill($true); $mutexRepair.Process.WaitForExit() }
        } catch {
            $mutexRepairCleanupErrors += ('kill/wait: ' + $_.Exception.Message)
        }
        try {
            $mutexRepair.Process.Dispose()
        } catch {
            $mutexRepairCleanupErrors += ('dispose: ' + $_.Exception.Message)
        }
    }
}
if ($null -ne $mutexRepairPrimaryError) {
    if ($mutexRepairCleanupErrors.Count -gt 0) { throw ($mutexRepairPrimaryError.Exception.Message + '; cleanup: ' + ($mutexRepairCleanupErrors -join '; ')) }
    throw $mutexRepairPrimaryError
}
if ($mutexRepairCleanupErrors.Count -gt 0) { throw ('repair-shared-memory child cleanup failed: ' + ($mutexRepairCleanupErrors -join '; ')) }

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

if ($blockedResult.ExitCode -ne 0) {
    Add-Failure "repair-shared-memory should ignore a stale diagnostic runtime.lock.json after acquiring the named mutex"
} else {
    Add-Check "repair-shared-memory uses the named mutex instead of trusting runtime.lock.json as a lock"
}

if ($blockedOutput -notmatch "STATUS:\s+PASS") {
    Add-Failure "repair-shared-memory should report STATUS: PASS after cleaning a stale diagnostic lock file"
} else {
    Add-Check "repair-shared-memory reports STATUS: PASS after cleaning a stale diagnostic lock file"
}

if ($blockedOutput -notmatch "removed stale runtime\.lock\.json diagnostic \(writer=other-writer, task=sample-task\)") {
    Add-Failure "repair-shared-memory should report which stale diagnostic lock file it removed"
} else {
    Add-Check "repair-shared-memory reports stale diagnostic lock cleanup"
}

if (-not (Test-Path -LiteralPath $blockedFixture.IndexPath -PathType Leaf)) {
    Add-Failure "repair-shared-memory should refresh recovery-index after ignoring a stale diagnostic lock file"
} else {
    Add-Check "repair-shared-memory refreshes recovery-index after ignoring a stale diagnostic lock file"
}

if (-not (Test-Path -LiteralPath $blockedFixture.CandidatePath -PathType Leaf)) {
    Add-Failure "repair-shared-memory should continue normal repairs after cleaning a stale diagnostic lock file"
} else {
    Add-Check "repair-shared-memory continues normal repairs after cleaning a stale diagnostic lock file"
}

$blockedInboxContent = Get-Content -LiteralPath $blockedFixture.InboxPath -Raw -Encoding utf8
if ($blockedInboxContent -notmatch "\|\s*2026-04-03 08:50:00\s*\|\s*claude-posttooluse\s*\|\s*sample-task\s*\|\s*lock-blocked\s*\|\s*cleared\s*\|") {
    Add-Failure "repair-shared-memory should clear obsolete lock-blocked rows after acquiring the named mutex"
} else {
    Add-Check "repair-shared-memory clears obsolete lock-blocked rows after acquiring the named mutex"
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

if ($expiredOutput -notmatch "removed stale runtime\.lock\.json diagnostic") {
    Add-Failure "repair-shared-memory should report stale runtime.lock.json diagnostic cleanup"
} else {
    Add-Check "repair-shared-memory reports stale runtime.lock.json diagnostic cleanup"
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

if ($expiredIndexContent -notmatch [regex]::Escape('derived_from: [运行时/当前任务.md, 运行时/tasks/]')) {
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
    Add-Failure "repair-shared-memory should return exit code 0 when recreating a missing runtime inbox without overriding the pointer"
} else {
    Add-Check "repair-shared-memory returns exit code 0 when recreating a missing runtime inbox without overriding the pointer"
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

if ($flowIndexContent -match [regex]::Escape($expectedTaskIdLine) -or $flowIndexContent -notmatch [regex]::Escape('- task_id: `none`')) {
    Add-Failure "repair-shared-memory should not write the current-flow task_id into recovery-index when a pointer exists"
} else {
    Add-Check "repair-shared-memory does not write the current-flow task_id into recovery-index when a pointer exists"
}

if ($flowIndexContent -match [regex]::Escape($expectedStatusLine)) {
    Add-Failure "repair-shared-memory should not rebuild recovery-index from current-flow stage when the shared pointer is idle"
} else {
    Add-Check "repair-shared-memory does not rebuild recovery-index from current-flow stage when the shared pointer is idle"
}

if ($flowIndexContent -match [regex]::Escape($expectedCurrentDocLine)) {
    Add-Failure "repair-shared-memory should not carry current-flow current_doc into recovery-index"
} else {
    Add-Check "repair-shared-memory does not carry current-flow current_doc into recovery-index"
}

if (
    $flowCurrentTaskContent -notmatch [regex]::Escape('| task_id | `none` |') -or
    $flowCurrentTaskContent -match [regex]::Escape("| {0} | TEST |" -f $statusKey)
) {
    Add-Failure "repair-shared-memory should not synchronize an existing current-task.md from current-flow"
} else {
    Add-Check "repair-shared-memory does not synchronize an existing current-task.md from current-flow"
}

if (
    (Test-Path -LiteralPath $flowTaskRuntimePath -PathType Leaf) -or
    $flowTaskRuntimeContent -match [regex]::Escape('primary_artifact: docs/tasks/sample-task/test.md')
) {
    Add-Failure "repair-shared-memory should not create a task runtime from current-flow when a pointer exists"
} else {
    Add-Check "repair-shared-memory does not create a task runtime from current-flow when a pointer exists"
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
    $missingPointerOutput -notmatch ("migrated missing pointer .+{0}" -f [regex]::Escape((Split-Path $missingPointerFixture.CurrentPath -Leaf))) -or
    $missingPointerOutput -notmatch ("created .+{0}" -f [regex]::Escape((Split-Path $missingPointerFixture.InterruptedPath -Leaf))) -or
    $missingPointerOutput -notmatch ("created .+{0}" -f [regex]::Escape((Split-Path $missingPointerFixture.LastSessionPath -Leaf)))
) {
    Add-Failure "repair-shared-memory should report migrating a missing current-task and recreating summary files"
} else {
    Add-Check "repair-shared-memory reports migrating a missing current-task and recreating summary files"
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

$templateContracts = @(
    [pscustomobject]@{ Path = $missingPointerFixture.CandidatePath; Crlf = 0; Lf = 10; Dynamic = '(?m)^created: (?<value>\d{4}-\d{2}-\d{2})(?=\r?$)'; Extra = '(?m)^updated: (?<value>\d{4}-\d{2}-\d{2})(?=\r?$)'; EqualFields = $true }
    [pscustomobject]@{ Path = $missingPointerFixture.ArchivePath; Crlf = 0; Lf = 10; Dynamic = '(?m)^created: (?<value>\d{4}-\d{2}-\d{2})(?=\r?$)'; Extra = '(?m)^updated: (?<value>\d{4}-\d{2}-\d{2})(?=\r?$)'; EqualFields = $true }
    [pscustomobject]@{ Path = $missingPointerFixture.InterruptedPath; Crlf = 8; Lf = 0; Dynamic = '(?m)^updated: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?=\r?$)'; Extra = ''; EqualFields = $false }
    [pscustomobject]@{ Path = $missingPointerFixture.LastSessionPath; Crlf = 11; Lf = 0; Dynamic = '(?m)^updated: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?=\r?$)'; Extra = '(?m)^\| 日期 \| \d{4}-\d{2}-\d{2} \|(?=\r?$)'; EqualFields = $false }
)
$templateContractsOk = $true
foreach ($contract in $templateContracts) {
    $raw = Get-Content -LiteralPath $contract.Path -Raw -Encoding utf8
    $crlfCount = [regex]::Matches($raw, "\r\n").Count
    $bareLfCount = [regex]::Matches($raw, "(?<!\r)\n").Count
    $dynamicMatches = [regex]::Matches($raw, $contract.Dynamic)
    $extraMatches = @()
    if (-not [string]::IsNullOrWhiteSpace($contract.Extra)) { $extraMatches = @([regex]::Matches($raw, $contract.Extra)) }
    $equalFieldsOk = -not $contract.EqualFields -or ($dynamicMatches.Count -eq 1 -and $extraMatches.Count -eq 1 -and $dynamicMatches[0].Groups['value'].Value -eq $extraMatches[0].Groups['value'].Value)
    if (-not (Test-FileHasUtf8Bom -Path $contract.Path) -or
        $crlfCount -ne $contract.Crlf -or $bareLfCount -ne $contract.Lf -or
        $dynamicMatches.Count -ne 1 -or (-not [string]::IsNullOrWhiteSpace($contract.Extra) -and $extraMatches.Count -ne 1) -or -not $equalFieldsOk -or
        $raw.EndsWith([string][char]13) -or $raw.EndsWith([string][char]10)) {
        $templateContractsOk = $false
    }
}
if ($templateContractsOk) {
    Add-Check 'repair-shared-memory recreates fresh templates with the canonical BOM, newline, and dynamic-field shapes'
} else {
    Add-Failure 'repair-shared-memory should recreate fresh templates with the canonical BOM, newline, and dynamic-field shapes'
}

$sentinelHashes = @{}
for ($index = 0; $index -lt $templateContracts.Count; $index++) {
    [System.IO.File]::WriteAllBytes($templateContracts[$index].Path, [Text.Encoding]::UTF8.GetBytes(('repair-template-sentinel-{0}' -f $index)))
    $sentinelHashes[$templateContracts[$index].Path] = (Get-FileHash -LiteralPath $templateContracts[$index].Path -Algorithm SHA256).Hash
}
$sentinelRepair = Invoke-Repair -VaultRoot $missingPointerFixture.AssistantRoot
$sentinelsPreserved = $sentinelRepair.ExitCode -eq 0
foreach ($contract in $templateContracts) {
    if ((Get-FileHash -LiteralPath $contract.Path -Algorithm SHA256).Hash -ne $sentinelHashes[$contract.Path]) {
        $sentinelsPreserved = $false
    }
}
if ($sentinelsPreserved) {
    Add-Check 'repair-shared-memory does not rewrite existing candidate, archive, interrupted, or last-session files'
} else {
    Add-Failure 'repair-shared-memory should not rewrite existing candidate, archive, interrupted, or last-session files'
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

$invalidTaskCaseRoot = Join-Path $tmpRoot 'invalid-current-task-id-normalizes-idle'
New-Item -ItemType Directory -Path $invalidTaskCaseRoot -Force | Out-Null
$invalidTaskFixture = New-RepairFixture `
    -CaseRoot $invalidTaskCaseRoot `
    -PointerTaskId '..\escape' `
    -PointerTask 'Invalid Pointer' `
    -PointerStatus 'PLAN'
$invalidTaskEscapePath = Join-Path (Split-Path -Parent $invalidTaskFixture.TasksDir) 'escape.md'
$invalidTaskResult = Invoke-Repair -VaultRoot $invalidTaskFixture.AssistantRoot
$invalidTaskOutput = $invalidTaskResult.Output -join [Environment]::NewLine
$invalidTaskCurrent = Get-CanonicalCurrentTaskState -Path $invalidTaskFixture.CurrentPath
$invalidTaskRecords = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory $invalidTaskFixture.TasksDir)
if ($invalidTaskResult.ExitCode -eq 0 -and
    $invalidTaskCurrent.TaskId -eq 'none' -and
    $invalidTaskCurrent.Stage -eq $idleStatus -and
    $invalidTaskRecords.Count -eq 0 -and
    -not (Test-Path -LiteralPath $invalidTaskEscapePath) -and
    $invalidTaskOutput -match 'normalized invalid current task_id to canonical idle without task path access') {
    Add-Check 'repair-shared-memory normalizes an invalid current task_id to audited canonical idle without path writes'
} else {
    Add-Failure ('invalid current task_id should normalize to audited canonical idle without path writes: exit={0}; escaped={1}; records={2}; output={3}' -f $invalidTaskResult.ExitCode,(Test-Path -LiteralPath $invalidTaskEscapePath),$invalidTaskRecords.Count,$invalidTaskOutput)
}

$doneCaseRoot = Join-Path $tmpRoot 'done-plan-resets-current-to-idle'
New-Item -ItemType Directory -Path $doneCaseRoot -Force | Out-Null
$doneFixture = New-RepairFixture -CaseRoot $doneCaseRoot
$donePlanPath = Join-Path $doneCaseRoot 'docs\tasks\sample-task\plan.md'
New-Item -ItemType Directory -Path (Split-Path -Parent $donePlanPath) -Force | Out-Null
@(
    '---',
    'task_id: sample-task',
    'stage: DONE',
    'tool: none',
    'updated: 2026-07-10',
    '---',
    '# Done task'
) -join "`r`n" | Set-Content -LiteralPath $donePlanPath -Encoding utf8
$doneResult = Invoke-Repair -VaultRoot $doneFixture.AssistantRoot
$doneCurrentContent = Get-Content -LiteralPath $doneFixture.CurrentPath -Raw -Encoding utf8
$expectedDoneIdleTaskLine = '| task_id | `none` |'
$expectedDoneIdleStatusLine = "| $statusKey | $idleStatus |"
$expectedDoneIdleDocLine = "| $currentDocKey | none |"
if (
    $doneResult.ExitCode -ne 0 -or
    $doneCurrentContent -notmatch [regex]::Escape($expectedDoneIdleTaskLine) -or
    $doneCurrentContent -notmatch [regex]::Escape($expectedDoneIdleStatusLine) -or
    $doneCurrentContent -notmatch [regex]::Escape($expectedDoneIdleDocLine) -or
    $doneCurrentContent -match [regex]::Escape('| 状态 | DONE |')
) {
    Add-Failure 'repair-shared-memory should reset current to canonical idle when its plan is DONE'
} else {
    Add-Check 'repair-shared-memory resets current to canonical idle when its plan is DONE'
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

if ($flowTimestampIndexContent -match [regex]::Escape($expectedTaskIdLine) -or $flowTimestampIndexContent -notmatch [regex]::Escape('- task_id: `none`')) {
    Add-Failure "repair-shared-memory should keep the canonical pointer task_id when current-flow is newer"
} else {
    Add-Check "repair-shared-memory keeps the canonical pointer task_id when current-flow is newer"
}

if ($flowTimestampIndexContent -match [regex]::Escape($expectedStatusLine)) {
    Add-Failure "repair-shared-memory should not refresh recovery-index from current-flow when current-task exists"
} else {
    Add-Check "repair-shared-memory does not refresh recovery-index from current-flow when current-task exists"
}

$retirementCaseRoot = Join-Path $tmpRoot 'inactive-task-retirement'
New-Item -ItemType Directory -Path $retirementCaseRoot -Force | Out-Null
$retirement = New-RetirementFixture -CaseRoot $retirementCaseRoot
$retirementAllPaths = @($retirement.ProtectedPaths) + @($retirement.TargetMirrorPath, $retirement.Base.IndexPath)

$pairSnapshot = Get-RetirementSnapshot -Paths $retirementAllPaths
$pairResult = Invoke-Repair -VaultRoot $retirement.Base.AssistantRoot -RetireInactiveTaskId $retirement.TargetTaskId
if ($pairResult.ExitCode -ne 0 -and
    (Test-RetirementSnapshotMatches -Snapshot $pairSnapshot -Paths $retirementAllPaths)) {
    Add-Check 'inactive-task retirement requires TaskId and ExpectedStage together with zero writes'
} else {
    Add-Failure 'inactive-task retirement should reject incomplete parameters with zero writes'
}

$stageSnapshot = Get-RetirementSnapshot -Paths $retirementAllPaths
$stageResult = Invoke-Repair -VaultRoot $retirement.Base.AssistantRoot -RetireInactiveTaskId $retirement.TargetTaskId -ExpectedRetireStage 'PLAN'
if ($stageResult.ExitCode -ne 0 -and
    (Test-RetirementSnapshotMatches -Snapshot $stageSnapshot -Paths $retirementAllPaths)) {
    Add-Check 'inactive-task retirement rejects a stale ExpectedStage CAS with zero writes'
} else {
    Add-Failure 'inactive-task retirement should reject a stale ExpectedStage CAS with zero writes'
}

$invalidSnapshot = Get-RetirementSnapshot -Paths $retirementAllPaths
$invalidResult = Invoke-Repair -VaultRoot $retirement.Base.AssistantRoot -RetireInactiveTaskId '..\escape' -ExpectedRetireStage 'IMPLEMENT'
if ($invalidResult.ExitCode -ne 0 -and
    (Test-RetirementSnapshotMatches -Snapshot $invalidSnapshot -Paths $retirementAllPaths) -and
    -not (Test-Path -LiteralPath (Join-Path $retirement.Base.TasksDir '..\escape.md'))) {
    Add-Check 'inactive-task retirement rejects path injection before any runtime write'
} else {
    Add-Failure 'inactive-task retirement should reject path injection before any runtime write'
}

$savedCurrent = Get-Content -LiteralPath $retirement.Base.CurrentPath -Raw -Encoding utf8
Write-CanonicalRuntimeUtf8BomAtomic -Path $retirement.Base.CurrentPath -Content (New-CanonicalCurrentTaskContent `
    -TaskId $retirement.TargetTaskId `
    -TaskName $retirement.TargetTaskId `
    -Stage 'IMPLEMENT' `
    -CurrentDoc "docs/tasks/$($retirement.TargetTaskId)/plan.md" `
    -Tool 'codex' `
    -EntryHost 'codex' `
    -NextStep 'Continue IMPLEMENT' `
    -Updated '2026-07-13T13:05:00+08:00')
$activeSnapshot = Get-RetirementSnapshot -Paths $retirementAllPaths
$activeResult = Invoke-Repair -VaultRoot $retirement.Base.AssistantRoot -RetireInactiveTaskId $retirement.TargetTaskId -ExpectedRetireStage 'IMPLEMENT'
if ($activeResult.ExitCode -ne 0 -and
    (Test-RetirementSnapshotMatches -Snapshot $activeSnapshot -Paths $retirementAllPaths)) {
    Add-Check 'inactive-task retirement rejects the active task with zero writes'
} else {
    Add-Failure 'inactive-task retirement should reject the active task with zero writes'
}
Write-CanonicalRuntimeUtf8BomAtomic -Path $retirement.Base.CurrentPath -Content $savedCurrent

$savedInbox = Get-Content -LiteralPath $retirement.Base.InboxPath -Raw -Encoding utf8
Write-CanonicalRuntimeUtf8BomAtomic -Path $retirement.Base.InboxPath -Content ($savedInbox.TrimEnd() + "`r`n| 2026-07-13 13:10:00 | advance-stage | $($retirement.TargetTaskId) | writeback-fallback | open | pending retirement writeback | {} |")
$fallbackSnapshot = Get-RetirementSnapshot -Paths $retirementAllPaths
$fallbackResult = Invoke-Repair -VaultRoot $retirement.Base.AssistantRoot -RetireInactiveTaskId $retirement.TargetTaskId -ExpectedRetireStage 'IMPLEMENT'
if ($fallbackResult.ExitCode -ne 0 -and
    (Test-RetirementSnapshotMatches -Snapshot $fallbackSnapshot -Paths $retirementAllPaths)) {
    Add-Check 'inactive-task retirement rejects an open target writeback-fallback with zero writes'
} else {
    Add-Failure 'inactive-task retirement should reject an open target writeback-fallback with zero writes'
}
Write-CanonicalRuntimeUtf8BomAtomic -Path $retirement.Base.InboxPath -Content $savedInbox

$savedInterrupted = Get-Content -LiteralPath $retirement.Base.InterruptedPath -Raw -Encoding utf8
Write-CanonicalRuntimeUtf8BomAtomic -Path $retirement.Base.InterruptedPath -Content ($savedInterrupted.TrimEnd() + "`r`n| P1 | 2026-07-13 | Retire target | $($retirement.TargetTaskId) | IMPLEMENT | Continue |")
$interruptedSnapshot = Get-RetirementSnapshot -Paths $retirementAllPaths
$interruptedResult = Invoke-Repair -VaultRoot $retirement.Base.AssistantRoot -RetireInactiveTaskId $retirement.TargetTaskId -ExpectedRetireStage 'IMPLEMENT'
if ($interruptedResult.ExitCode -ne 0 -and
    (Test-RetirementSnapshotMatches -Snapshot $interruptedSnapshot -Paths $retirementAllPaths)) {
    Add-Check 'inactive-task retirement rejects an interrupted-view reference with zero writes'
} else {
    Add-Failure 'inactive-task retirement should reject an interrupted-view reference with zero writes'
}
Write-CanonicalRuntimeUtf8BomAtomic -Path $retirement.Base.InterruptedPath -Content $savedInterrupted

$failureSnapshot = Get-RetirementSnapshot -Paths $retirementAllPaths
$indexHandle = [System.IO.File]::Open(
    $retirement.Base.IndexPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
)
try {
    $failureResult = Invoke-Repair -VaultRoot $retirement.Base.AssistantRoot -RetireInactiveTaskId $retirement.TargetTaskId -ExpectedRetireStage 'IMPLEMENT'
} finally {
    $indexHandle.Dispose()
}
if ($failureResult.ExitCode -ne 0 -and
    (Test-RetirementSnapshotMatches -Snapshot $failureSnapshot -Paths $retirementAllPaths)) {
    Add-Check 'inactive-task retirement restores mirror and index when atomic index replacement fails'
} else {
    Add-Failure 'inactive-task retirement should restore mirror and index when atomic index replacement fails'
}

$protectedSnapshot = Get-RetirementSnapshot -Paths $retirement.ProtectedPaths
$beforeConcurrentSnapshot = Get-RetirementSnapshot -Paths $retirementAllPaths
$retirementProcess = $null
$retirementProcessErrors = @()
$heldPlanMutex = Enter-LitePlanMutex -TaskId $retirement.TargetTaskId
try {
    $retirementProcess = Start-RepairProcess `
        -VaultRoot $retirement.Base.AssistantRoot `
        -RetireInactiveTaskId $retirement.TargetTaskId `
        -ExpectedRetireStage 'IMPLEMENT'
    [void]$retirementProcess.Process.WaitForExit(1200)
    $blockedByPlanMutex = -not $retirementProcess.Process.HasExited -and
        (Test-RetirementSnapshotMatches -Snapshot $beforeConcurrentSnapshot -Paths $retirementAllPaths)
} finally {
    Exit-LitePlanMutex -Mutex $heldPlanMutex
}
try {
    if (-not $retirementProcess.Process.WaitForExit(30000)) {
        throw 'inactive-task retirement child process timed out'
    }
    $retirementProcess.Process.WaitForExit()
    $retirementStdOut = $retirementProcess.StdOut.Result
    $retirementStdErr = $retirementProcess.StdErr.Result
    $retiredIndex = Get-Content -LiteralPath $retirement.Base.IndexPath -Raw -Encoding utf8
    if ($blockedByPlanMutex -and
        $retirementProcess.Process.ExitCode -eq 0 -and
        $retirementStdOut -match 'STATUS: PASS' -and
        -not (Test-Path -LiteralPath $retirement.TargetMirrorPath -PathType Leaf) -and
        $retiredIndex -notmatch [regex]::Escape($retirement.TargetTaskId) -and
        $retiredIndex -match [regex]::Escape($retirement.CurrentTaskId) -and
        (Test-RetirementSnapshotMatches -Snapshot $protectedSnapshot -Paths $retirement.ProtectedPaths)) {
        Add-Check 'inactive-task retirement waits for the task plan mutex then changes only target mirror and derived index'
    } else {
        Add-Failure ("inactive-task retirement should serialize and preserve protected files: blocked={0}; exit={1}; stdout={2}; stderr={3}" -f $blockedByPlanMutex,$retirementProcess.Process.ExitCode,$retirementStdOut,$retirementStdErr)
    }
} catch {
    $retirementProcessErrors += $_.Exception.Message
} finally {
    if ($null -ne $retirementProcess) {
        try {
            if (-not $retirementProcess.Process.HasExited) {
                $retirementProcess.Process.Kill($true)
                $retirementProcess.Process.WaitForExit()
            }
            $retirementProcess.Process.Dispose()
        } catch {
            $retirementProcessErrors += $_.Exception.Message
        }
    }
}
if ($retirementProcessErrors.Count -gt 0) {
    Add-Failure ('inactive-task retirement child process cleanup failed: ' + ($retirementProcessErrors -join '; '))
}
} finally {
    Remove-DirectoryWithRetry -Path $tmpRoot
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
