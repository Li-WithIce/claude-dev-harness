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

function Invoke-TriageInboxList {
    param([string]$VaultRoot)

    $scriptPath = Join-Path $RepoRoot 'scripts\triage-runtime-inbox.ps1'
    $output = @(& $scriptPath -VaultRoot $VaultRoot -List 2>&1)
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
$tmpRoot = Join-Path $RepoRoot 'tmp\runtime-inbox-regression'
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$runtimeDirName = Convert-CodePointsToString -CodePoints @(36816, 34892, 26102)
$inboxFileName = Convert-CodePointsToString -CodePoints @(25910, 20214, 31665, 46, 109, 100)
$placeholderSummary = Convert-CodePointsToString -CodePoints @(24403, 21069, 26242, 26080, 25910, 20214, 31665, 20107, 39033)
$fullWidthPipe = [string][char]0xFF5C
$standardHeader = '| created_at | source | task_id | type | status | summary | payload |'
$placeholderRow = '| - | - | - | - | cleared | {0} | - |' -f $placeholderSummary
$currentTaskFileName = Convert-CodePointsToString -CodePoints @(24403, 21069, 20219, 21153, 46, 109, 100)
$currentTaskHeading = Convert-CodePointsToString -CodePoints @(24403, 21069, 20219, 21153)
$taskTag = Convert-CodePointsToString -CodePoints @(20219, 21153)
$sharedPointerTag = Convert-CodePointsToString -CodePoints @(20849, 20139, 25351, 38024)
$projectHeader = Convert-CodePointsToString -CodePoints @(39033, 30446)
$valueHeader = Convert-CodePointsToString -CodePoints @(20540)
$noneText = Convert-CodePointsToString -CodePoints @(26080)
$idleText = Convert-CodePointsToString -CodePoints @(31354, 38386)
$detailStatusHeader = Convert-CodePointsToString -CodePoints @(35814, 24773, 29366, 24577)
$waitForNewTaskText = Convert-CodePointsToString -CodePoints @(31561, 24453, 26032, 20219, 21153)
$statusHeader = Convert-CodePointsToString -CodePoints @(29366, 24577)
$nextHeader = Convert-CodePointsToString -CodePoints @(19979, 19968, 27493)
$runtimeTasksLiteral = Convert-CodePointsToString -CodePoints @(36816, 34892, 26102, 47, 116, 97, 115, 107, 115, 47)

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
if ($createListResult.ExitCode -ne 0) {
    Add-Failure 'triage-runtime-inbox should be able to list items from an inbox file created by append-runtime-inbox'
} else {
    Add-Check 'triage-runtime-inbox can list items from an inbox file created by append-runtime-inbox'
}

if ($createListText -notmatch 'OpenItems:\s+1') {
    Add-Failure 'append-runtime-inbox should create inbox rows in the standard line-oriented format expected by triage-runtime-inbox'
} else {
    Add-Check 'append-runtime-inbox creates inbox rows in the standard line-oriented format expected by triage-runtime-inbox'
}

$escapeCaseRoot = Join-Path $tmpRoot 'escape-placeholder-and-malformed'
if (Test-Path -LiteralPath $escapeCaseRoot) {
    Remove-Item -LiteralPath $escapeCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $escapeCaseRoot -Force | Out-Null
$escapeVaultRoot = Join-Path $escapeCaseRoot '.assistant'
$escapeRuntimeDir = Join-Path $escapeVaultRoot $runtimeDirName
New-Item -ItemType Directory -Path $escapeRuntimeDir -Force | Out-Null
$escapeInboxPath = Join-Path $escapeRuntimeDir $inboxFileName
$existingContent = @(
    '# Inbox'
    ''
    $standardHeader
    '|------------|--------|---------|------|--------|---------|---------|'
    $placeholderRow
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

$autoTaskCaseRoot = Join-Path $tmpRoot 'autoresolve-task-id-from-current-flow'
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
$autoTaskCurrentTaskContent = @(
    '---'
    "tags: [$runtimeDirName, $taskTag, $sharedPointerTag]"
    'created: 2026-04-03 12:00:00'
    'updated: 2026-04-03 12:00:00'
    'task_id: none'
    'writer: test'
    '---'
    ''
    "# $currentTaskHeading"
    ''
    "| $projectHeader | $valueHeader |"
    '|------|-----|'
    '| task_id | `none` |'
    "| $taskTag | $noneText |"
    "| $statusHeader | $idleText |"
    "| $detailStatusHeader | ``$runtimeTasksLiteral`` |"
    "| $nextHeader | $waitForNewTaskText |"
) -join "`r`n"
Set-Content -LiteralPath $autoTaskCurrentTaskPath -Value $autoTaskCurrentTaskContent -Encoding utf8

$autoTaskResult = Invoke-AppendInbox `
    -VaultRoot '' `
    -TaskId '' `
    -Type 'inbox-first' `
    -Summary 'Auto-resolve current task id' `
    -Payload 'Use current-flow task id when TaskId is omitted.' `
    -Source 'manual-test' `
    -WorkingDirectory $autoTaskWorkspaceRoot
$autoTaskInboxPath = Join-Path $autoTaskRuntimeDir $inboxFileName
$autoTaskContent = Get-Content -LiteralPath $autoTaskInboxPath -Raw -Encoding utf8
$autoTaskOutputText = $autoTaskResult.Output -join "`n"

if ($autoTaskResult.ExitCode -ne 0) {
    Add-Failure 'append-runtime-inbox should return exit code 0 when run from a workspace cwd without an explicit TaskId'
} else {
    Add-Check 'append-runtime-inbox returns exit code 0 when run from a workspace cwd without an explicit TaskId'
}

if ($autoTaskContent -notmatch '\|\s*.+?\s*\|\s*manual-test\s*\|\s*sample-task\s*\|\s*inbox-first\s*\|\s*open\s*\|\s*Auto-resolve current task id\s*\|') {
    Add-Failure 'append-runtime-inbox should infer task_id from current-flow before falling back to an idle shared pointer'
} else {
    Add-Check 'append-runtime-inbox infers task_id from current-flow before falling back to an idle shared pointer'
}

if ($autoTaskOutputText -notmatch '(?im)^EntryTaskId:\s+sample-task\s*$') {
    Add-Failure 'append-runtime-inbox should report the resolved task_id in its output when TaskId is omitted'
} else {
    Add-Check 'append-runtime-inbox reports the resolved task_id in its output when TaskId is omitted'
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
