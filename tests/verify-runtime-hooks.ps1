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

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8
}

function Write-RenderedHook {
    param(
        [string]$TemplatePath,
        [string]$TargetPath,
        [string]$VaultRoot
    )

    $content = Read-FileUtf8 -Path $TemplatePath
    $rendered = $content.Replace('{VAULT_PATH}', $VaultRoot.Replace('\', '\\'))
    Set-Content -LiteralPath $TargetPath -Value $rendered -Encoding utf8
}

function Enable-LockWriteCapture {
    param(
        [string]$HookPath,
        [string]$CapturePath
    )

    $content = Read-FileUtf8 -Path $HookPath
    $instrumented = $content.Replace(
        '  fs.writeFileSync(lockPath, JSON.stringify(lock), "utf8");',
        ('  fs.writeFileSync(lockPath, JSON.stringify(lock), "utf8");' + [Environment]::NewLine + '  fs.writeFileSync("' + $CapturePath.Replace('\', '\\') + '", JSON.stringify(lock), "utf8");')
    )
    Set-Content -LiteralPath $HookPath -Value $instrumented -Encoding utf8
}

function Invoke-NodeHook {
    param(
        [string]$HookPath,
        [string]$Stdin = ""
    )

    $output = if ([string]::IsNullOrEmpty($Stdin)) {
        @(& node $HookPath 2>&1)
    } else {
        @($Stdin | & node $HookPath 2>&1)
    }

    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try {
            $json = $text | ConvertFrom-Json
        } catch {
            $json = $null
        }
    }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $text
        Json     = $json
    }
}

function Get-JsonPropertyValue {
    param(
        [AllowNull()]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function New-HookFixture {
    param(
        [string]$CaseRoot,
        [string]$PointerStatus,
        [string]$TaskLabel = 'Sample Task',
        [string]$FlowStatus = $PointerStatus
    )

    $vaultRoot = Join-Path $CaseRoot '.assistant'
    $runtimeDirName = Convert-CodePointsToString -CodePoints @(36816, 34892, 26102)
    $currentTaskFileName = Convert-CodePointsToString -CodePoints @(24403, 21069, 20219, 21153, 46, 109, 100)
    $interruptedFileName = Convert-CodePointsToString -CodePoints @(20013, 26029, 20219, 21153, 46, 109, 100)
    $lastSessionFileName = Convert-CodePointsToString -CodePoints @(19978, 27425, 20250, 35805, 46, 109, 100)
    $runtimeDir = Join-Path $vaultRoot $runtimeDirName
    $orchestrationDir = Join-Path $vaultRoot 'orchestration'
    $taskKey = Convert-CodePointsToString -CodePoints @(20219, 21153)
    $statusKey = Convert-CodePointsToString -CodePoints @(29366, 24577)
    $nextKey = Convert-CodePointsToString -CodePoints @(19979, 19968, 27493)

    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runtimeDir 'tasks') -Force | Out-Null
    New-Item -ItemType Directory -Path $orchestrationDir -Force | Out-Null

    $currentTaskPath = Join-Path $runtimeDir $currentTaskFileName
    $currentTaskContent = @(
        '---',
        'updated: 2026-04-02 12:00:00',
        'task_id: sample-task',
        'writer: Claude Code',
        '---',
        '',
        '# Current Task',
        '',
        '| Key | Value |',
        '|-----|-------|',
        '| task_id | `sample-task` |',
        ("| {0} | {1} |" -f $taskKey, $TaskLabel),
        ("| {0} | {1} |" -f $statusKey, $PointerStatus),
        ("| {0} | run the next step |" -f $nextKey)
    ) -join "`r`n"
    Set-Content -LiteralPath $currentTaskPath -Value $currentTaskContent -Encoding utf8

    $interruptedPath = Join-Path $runtimeDir $interruptedFileName
    Set-Content -LiteralPath $interruptedPath -Value "# Interrupted`r`n" -Encoding utf8

    $lastSessionPath = Join-Path $runtimeDir $lastSessionFileName
    $lastSessionContent = @(
        '# Last Session',
        '',
        '| Key | Value |',
        '|-----|-------|',
        '| 日期 | 2026-04-02 |',
        '| 任务 | Sample Task |',
        '| 状态 | active |',
        '| 摘要 | summary |'
    ) -join "`r`n"
    Set-Content -LiteralPath $lastSessionPath -Value $lastSessionContent -Encoding utf8

    $flowPath = Join-Path $orchestrationDir 'current-flow.md'
    $flowContent = @(
        'schema_version: 2.2',
        'task_id: sample-task',
        'task_name: Sample Task',
        'mode: fast-track',
        ("stage: {0}" -f $FlowStatus),
        'review_scope: implementation',
        'entry_tool: Codex',
        'tool_profile_id: codex-only',
        'tool_profile_source: repo-preset',
        'runner_tool: Codex',
        'runner: task runner',
        'fallback_policy: ask_user',
        'recovery_source: current-flow',
        'artifact_root: docs/tasks/sample-task',
        ("current_doc: docs/tasks/sample-task/{0}" -f $(if ($FlowStatus -eq 'CODE_REVIEW') { 'review.md' } else { 'test.md' })),
        'plan_path: docs/tasks/sample-task/plan.md',
        'implementation_notes_path: docs/tasks/sample-task/implementation-notes.md',
        'review_path: docs/tasks/sample-task/review.md',
        'test_path: docs/tasks/sample-task/test.md',
        'tool_bindings:',
        '  PLAN: Codex task runner',
        '  PLAN_REVIEW: Codex task runner',
        '  IMPLEMENT: Codex task runner',
        '  CODE_REVIEW: Codex task runner',
        '  TEST: Codex local test runner',
        'fallback_bindings:',
        '  TEST:',
        '    - Claude /test',
        'gate:',
        '  status: blocked',
        '  basis: waiting for verification',
        'next: continue',
        'runtime_health_command: ..\..\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH} -OrchestratorFlowPath .assistant\orchestration\current-flow.md'
    ) -join "`r`n"
    Set-Content -LiteralPath $flowPath -Value $flowContent -Encoding utf8

    return [pscustomobject]@{
        VaultRoot         = $vaultRoot
        RuntimeDir        = $runtimeDir
        CurrentTaskPath   = $currentTaskPath
        InterruptedPath   = $interruptedPath
        LastSessionPath   = $lastSessionPath
        CurrentFlowPath   = $flowPath
        RecoveryIndexPath = Join-Path $runtimeDir (Convert-CodePointsToString -CodePoints @(24674, 22797, 32034, 24341, 46, 109, 100))
        InboxPath         = Join-Path $runtimeDir '收件箱.md'
        LockPath          = Join-Path $runtimeDir 'runtime.lock.json'
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
$scratchRoot = Join-Path $RepoRoot "tmp\runtime-hooks-regression"

if (Test-Path -LiteralPath $scratchRoot) {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
$script:Checks = @()
$script:Failures = @()

$stopTemplatePath = Join-Path $RepoRoot "runtime-hooks\claude\stop.js"
$postToolTemplatePath = Join-Path $RepoRoot "runtime-hooks\claude\posttooluse.js"

$stopIdleCase = Join-Path $scratchRoot "stop-idle"
New-Item -ItemType Directory -Path $stopIdleCase -Force | Out-Null
$stopIdleFixture = New-HookFixture -CaseRoot $stopIdleCase -PointerStatus "空闲" -TaskLabel "无"
$stopIdleHookPath = Join-Path $stopIdleCase "stop.js"
Write-RenderedHook -TemplatePath $stopTemplatePath -TargetPath $stopIdleHookPath -VaultRoot $stopIdleFixture.VaultRoot
$stopIdleResult = Invoke-NodeHook -HookPath $stopIdleHookPath
$stopIdleMessage = Get-JsonPropertyValue -Object $stopIdleResult.Json -Name "systemMessage"
if ($stopIdleResult.ExitCode -ne 0 -or ($null -ne $stopIdleMessage)) {
    Add-Failure "stop-idle should return empty JSON"
} else {
    Add-Check "stop-idle returns empty JSON for inactive pointer"
}

$stopPointerIdleFlowActiveCase = Join-Path $scratchRoot "stop-pointer-idle-flow-active"
New-Item -ItemType Directory -Path $stopPointerIdleFlowActiveCase -Force | Out-Null
$stopPointerIdleFlowActiveFixture = New-HookFixture -CaseRoot $stopPointerIdleFlowActiveCase -PointerStatus "空闲" -TaskLabel "无" -FlowStatus "TEST"
$stopPointerIdleFlowActiveHookPath = Join-Path $stopPointerIdleFlowActiveCase "stop.js"
Write-RenderedHook -TemplatePath $stopTemplatePath -TargetPath $stopPointerIdleFlowActiveHookPath -VaultRoot $stopPointerIdleFlowActiveFixture.VaultRoot
$stopPointerIdleFlowActiveResult = Invoke-NodeHook -HookPath $stopPointerIdleFlowActiveHookPath
$stopPointerIdleFlowActiveMessage = Get-JsonPropertyValue -Object $stopPointerIdleFlowActiveResult.Json -Name "systemMessage"
if ($stopPointerIdleFlowActiveResult.ExitCode -ne 0 -or $null -eq $stopPointerIdleFlowActiveMessage -or $stopPointerIdleFlowActiveMessage -notmatch "status=TEST" -or $stopPointerIdleFlowActiveMessage -notmatch "current-flow") {
    Add-Failure "stop hook should warn when current-flow remains active after the shared pointer is idle"
} else {
    Add-Check "stop hook warns when current-flow remains active after the shared pointer is idle"
}

$stopTestCase = Join-Path $scratchRoot "stop-test-active"
New-Item -ItemType Directory -Path $stopTestCase -Force | Out-Null
$stopTestFixture = New-HookFixture -CaseRoot $stopTestCase -PointerStatus "TEST"
$stopTestHookPath = Join-Path $stopTestCase "stop.js"
Write-RenderedHook -TemplatePath $stopTemplatePath -TargetPath $stopTestHookPath -VaultRoot $stopTestFixture.VaultRoot
$stopTestResult = Invoke-NodeHook -HookPath $stopTestHookPath
$stopTestMessage = Get-JsonPropertyValue -Object $stopTestResult.Json -Name "systemMessage"
if ($stopTestResult.ExitCode -ne 0 -or $null -eq $stopTestMessage -or $stopTestMessage -notmatch "status=TEST") {
    Add-Failure "stop-test-active should warn with status=TEST"
} else {
    Add-Check "stop-test-active warns for TEST status"
}

$stopCodeReviewCase = Join-Path $scratchRoot "stop-code-review-active"
New-Item -ItemType Directory -Path $stopCodeReviewCase -Force | Out-Null
$stopCodeReviewFixture = New-HookFixture -CaseRoot $stopCodeReviewCase -PointerStatus "CODE_REVIEW" -FlowStatus "CODE_REVIEW"
$stopCodeReviewHookPath = Join-Path $stopCodeReviewCase "stop.js"
Write-RenderedHook -TemplatePath $stopTemplatePath -TargetPath $stopCodeReviewHookPath -VaultRoot $stopCodeReviewFixture.VaultRoot
$stopCodeReviewResult = Invoke-NodeHook -HookPath $stopCodeReviewHookPath
$stopCodeReviewMessage = Get-JsonPropertyValue -Object $stopCodeReviewResult.Json -Name "systemMessage"
if ($stopCodeReviewResult.ExitCode -ne 0 -or $null -eq $stopCodeReviewMessage -or $stopCodeReviewMessage -notmatch "status=CODE_REVIEW") {
    Add-Failure "stop-code-review-active should warn with status=CODE_REVIEW"
} else {
    Add-Check "stop-code-review-active warns for CODE_REVIEW status"
}

$postToolCase = Join-Path $scratchRoot "posttooluse-lock-release"
New-Item -ItemType Directory -Path $postToolCase -Force | Out-Null
$postToolFixture = New-HookFixture -CaseRoot $postToolCase -PointerStatus "TEST"
$postToolHookPath = Join-Path $postToolCase "posttooluse.js"
Write-RenderedHook -TemplatePath $postToolTemplatePath -TargetPath $postToolHookPath -VaultRoot $postToolFixture.VaultRoot
$postToolLockCapturePath = Join-Path $postToolCase 'lock-capture.json'
Enable-LockWriteCapture -HookPath $postToolHookPath -CapturePath $postToolLockCapturePath
$postToolResult = Invoke-NodeHook -HookPath $postToolHookPath
$postToolMessage = Get-JsonPropertyValue -Object $postToolResult.Json -Name "systemMessage"
$postToolRecoveryIndex = if (Test-Path -LiteralPath $postToolFixture.RecoveryIndexPath -PathType Leaf) {
    Get-Content -LiteralPath $postToolFixture.RecoveryIndexPath -Raw -Encoding utf8
} else {
    ''
}
$postToolLockCapture = if (Test-Path -LiteralPath $postToolLockCapturePath -PathType Leaf) {
    Get-Content -LiteralPath $postToolLockCapturePath -Raw -Encoding utf8
} else {
    ''
}
if (
    $postToolResult.ExitCode -ne 0 -or
    $null -eq $postToolResult.Json -or
    $null -ne $postToolMessage -or
    -not (Test-Path -LiteralPath $postToolFixture.RecoveryIndexPath -PathType Leaf) -or
    (Test-Path -LiteralPath $postToolFixture.LockPath -PathType Leaf)
) {
    Add-Failure "posttooluse should refresh recovery-index and release runtime.lock.json"
} else {
    Add-Check "posttooluse refreshes recovery-index and releases runtime.lock.json"
}

if (
    $postToolRecoveryIndex -notmatch [regex]::Escape('- task_id: `sample-task`') -or
    $postToolRecoveryIndex -notmatch [regex]::Escape('- 当前文档: docs/tasks/sample-task/test.md') -or
    $postToolRecoveryIndex -notmatch [regex]::Escape('derived_from: ["运行时/当前任务.md","运行时/tasks/"]')
) {
    Add-Failure "posttooluse should write task_id, current_doc, and derived_from into recovery-index"
} else {
    Add-Check "posttooluse writes task_id, current_doc, and derived_from into recovery-index"
}

if ($postToolLockCapture -notmatch [regex]::Escape('"entry_host":"claudecode"')) {
    Add-Failure 'posttooluse should write entry_host=claudecode into runtime.lock.json before rebuilding recovery-index'
} else {
    Add-Check 'posttooluse writes entry_host=claudecode into runtime.lock.json before rebuilding recovery-index'
}

$postToolFlowCase = Join-Path $scratchRoot "posttooluse-pointer-idle-flow-active"
New-Item -ItemType Directory -Path $postToolFlowCase -Force | Out-Null
$postToolFlowFixture = New-HookFixture -CaseRoot $postToolFlowCase -PointerStatus "空闲" -TaskLabel "无" -FlowStatus "TEST"
$postToolFlowHookPath = Join-Path $postToolFlowCase "posttooluse.js"
Write-RenderedHook -TemplatePath $postToolTemplatePath -TargetPath $postToolFlowHookPath -VaultRoot $postToolFlowFixture.VaultRoot
$postToolFlowResult = Invoke-NodeHook -HookPath $postToolFlowHookPath
$postToolFlowMessage = Get-JsonPropertyValue -Object $postToolFlowResult.Json -Name "systemMessage"
$postToolFlowRecoveryIndex = if (Test-Path -LiteralPath $postToolFlowFixture.RecoveryIndexPath -PathType Leaf) {
    Get-Content -LiteralPath $postToolFlowFixture.RecoveryIndexPath -Raw -Encoding utf8
} else {
    ''
}
if (
    $postToolFlowResult.ExitCode -ne 0 -or
    $null -ne $postToolFlowMessage -or
    $postToolFlowRecoveryIndex -notmatch [regex]::Escape('- task_id: `sample-task`') -or
    $postToolFlowRecoveryIndex -notmatch [regex]::Escape('- 任务: Sample Task') -or
    $postToolFlowRecoveryIndex -notmatch [regex]::Escape('- 状态: TEST') -or
    $postToolFlowRecoveryIndex -notmatch [regex]::Escape('- 当前文档: docs/tasks/sample-task/test.md') -or
    $postToolFlowRecoveryIndex -notmatch [regex]::Escape('derived_from: ["运行时/当前任务.md","运行时/tasks/"]')
) {
    Add-Failure "posttooluse should rebuild recovery-index from current-flow when the shared pointer is idle"
} else {
    Add-Check "posttooluse rebuilds recovery-index from current-flow when the shared pointer is idle"
}

$postToolLockedCase = Join-Path $scratchRoot "posttooluse-respects-lock"
New-Item -ItemType Directory -Path $postToolLockedCase -Force | Out-Null
$postToolLockedFixture = New-HookFixture -CaseRoot $postToolLockedCase -PointerStatus "TEST"
$postToolLockedHookPath = Join-Path $postToolLockedCase "posttooluse.js"
Write-RenderedHook -TemplatePath $postToolTemplatePath -TargetPath $postToolLockedHookPath -VaultRoot $postToolLockedFixture.VaultRoot
Set-Content -LiteralPath $postToolLockedFixture.LockPath -Value (@{
        writer    = "other-writer"
        task_id   = "sample-task"
        locked_at = (Get-Date).ToString("s")
        entry_host = "team-leader"
    } | ConvertTo-Json) -Encoding utf8
$postToolLockedResult = Invoke-NodeHook -HookPath $postToolLockedHookPath
$postToolLockedMessage = Get-JsonPropertyValue -Object $postToolLockedResult.Json -Name "systemMessage"
$postToolLockedInboxContent = if (Test-Path -LiteralPath $postToolLockedFixture.InboxPath -PathType Leaf) {
    Get-Content -LiteralPath $postToolLockedFixture.InboxPath -Raw -Encoding utf8
} else {
    ''
}
if (
    $postToolLockedResult.ExitCode -ne 0 -or
    $null -eq $postToolLockedMessage -or
    $postToolLockedMessage -notmatch "other-writer" -or
    $postToolLockedMessage -notmatch "Recorded in runtime inbox" -or
    (Test-Path -LiteralPath $postToolLockedFixture.RecoveryIndexPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $postToolLockedFixture.LockPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $postToolLockedFixture.InboxPath -PathType Leaf) -or
    $postToolLockedInboxContent -notmatch 'lock-blocked' -or
    $postToolLockedInboxContent -notmatch 'other-writer' -or
    $postToolLockedInboxContent -notmatch 'entry_host=team-leader'
) {
    Add-Failure "posttooluse should respect an active runtime.lock.json from another writer and record the blocked write in inbox"
} else {
    Add-Check "posttooluse respects an active runtime.lock.json from another writer and records inbox fallback"
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
