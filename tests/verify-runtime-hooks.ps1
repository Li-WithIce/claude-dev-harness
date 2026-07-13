[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

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
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $TemplatePath) 'workspace-resolver.js') -Destination (Join-Path (Split-Path -Parent $TargetPath) 'workspace-resolver.js') -Force
}

function Invoke-NodeHook {
    param(
        [string]$HookPath,
        [string]$Stdin = "",
        [string]$WorkingDirectory = "",
        [hashtable]$Environment = @{}
    )

    $stdinWasBound = $PSBoundParameters.ContainsKey('Stdin')

    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = Split-Path -Parent $HookPath
    }

    $environmentNames = @('DEV_HARNESS_WORKSPACE_ROOT', 'CLAUDE_DEV_HARNESS_WORKSPACE_ROOT', 'WORKSPACE_ROOT')
    $originalEnvironment = @{}
    foreach ($name in $environmentNames) {
        $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    try {
        foreach ($name in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], 'Process')
        }
        Push-Location -LiteralPath $WorkingDirectory
        try {
            $output = if ($stdinWasBound) {
                @($Stdin | & node $HookPath 2>&1)
            } else {
                @(& node $HookPath 2>&1)
            }
        } finally {
            Pop-Location
        }
    } finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
        }
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
$script:Checks = @()
$script:Failures = @()
$scratchRoot = Join-Path $RepoRoot "tmp\runtime-hooks-regression-$([guid]::NewGuid().ToString('N'))"
$dynamicUnresolvedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dev-harness-runtime-hooks-unresolved-{0}" -f [guid]::NewGuid().ToString('N'))

try {
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

$stopTemplatePath = Join-Path $RepoRoot "runtime-hooks\claude\stop.js"
$userPromptTemplatePath = Join-Path $RepoRoot "runtime-hooks\claude\userpromptsubmit.js"

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
if (
    $stopPointerIdleFlowActiveResult.ExitCode -ne 0 -or
    $null -eq $stopPointerIdleFlowActiveMessage -or
    $stopPointerIdleFlowActiveMessage -notmatch "status=TEST" -or
    $stopPointerIdleFlowActiveMessage -notmatch "current-flow" -or
    $stopPointerIdleFlowActiveMessage -notmatch "does not authorize runtime writes" -or
    $stopPointerIdleFlowActiveMessage -notmatch "read-only work may stop without refresh"
) {
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
if (
    $stopTestResult.ExitCode -ne 0 -or
    $null -eq $stopTestMessage -or
    $stopTestMessage -notmatch "status=TEST" -or
    $stopTestMessage -notmatch "does not authorize runtime writes" -or
    $stopTestMessage -notmatch "read-only work may stop without refresh" -or
    $stopTestMessage -match "Refresh current-task or last-session before stopping"
) {
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
if (
    $stopCodeReviewResult.ExitCode -ne 0 -or
    $null -eq $stopCodeReviewMessage -or
    $stopCodeReviewMessage -notmatch "status=CODE_REVIEW" -or
    $stopCodeReviewMessage -notmatch "does not authorize runtime writes" -or
    $stopCodeReviewMessage -notmatch "read-only work may stop without refresh" -or
    $stopCodeReviewMessage -match "Refresh current-task or last-session before stopping"
) {
    Add-Failure "stop-code-review-active should warn with status=CODE_REVIEW"
} else {
    Add-Check "stop-code-review-active warns for CODE_REVIEW status"
}

$stopTemplateContent = Read-FileUtf8 -Path $stopTemplatePath
if ($stopTemplateContent.Contains('Refresh current-task or last-session before stopping')) {
    Add-Failure 'stop hook must not instruct read-only sessions to write runtime state'
} else {
    Add-Check 'stop hook remains diagnostic and does not grant runtime write authority'
}

$userPromptPositiveInputs = @(
    '{"prompt":"resume"}', '{"prompt":"continue"}', '{"prompt":"what were we doing"}',
    '{"prompt":"继续"}', '{"prompt":"恢复"}', '{"prompt":"继续刚才的任务"}', '{"prompt":"刚才做到哪里了"}',
    '\u7ee7\u7eed', '\u6062\u590d', '\u7ee7\u7eed\u521a\u624d\u7684\u4efb\u52a1', '\u521a\u624d\u505a\u5230\u54ea\u91cc\u4e86'
)
$userPromptFailures = @(
    foreach ($stdinCase in $userPromptPositiveInputs) {
        $result = Invoke-NodeHook -HookPath $userPromptTemplatePath -Stdin $stdinCase
        if ($result.ExitCode -ne 0 -or (Get-JsonPropertyValue -Object $result.Json -Name 'systemMessage') -notmatch 'Resume trigger detected') { $stdinCase }
    }
    foreach ($stdinCase in @('{"prompt":"unrelated"}', '{"prompt":"discontinue"}', '')) {
        $result = Invoke-NodeHook -HookPath $userPromptTemplatePath -Stdin $stdinCase
        if ($result.ExitCode -ne 0 -or $result.Output -cne '{}') { $stdinCase }
    }
)
if ($userPromptFailures.Count -eq 0) {
    Add-Check 'userpromptsubmit preserves the 14-case resume trigger corpus'
} else {
    Add-Failure ("userpromptsubmit resume corpus mismatches: {0}" -f ($userPromptFailures -join ', '))
}

$dynamicActiveRoot = Join-Path $scratchRoot 'dynamic-active'
$dynamicIdleRoot = Join-Path $scratchRoot 'dynamic-idle'
$dynamicConflictRoot = Join-Path $scratchRoot 'dynamic-conflict'
$sharedHookRoot = Join-Path $scratchRoot 'shared-hooks'
New-Item -ItemType Directory -Path $dynamicActiveRoot,$dynamicIdleRoot,$dynamicConflictRoot,$dynamicUnresolvedRoot,$sharedHookRoot -Force | Out-Null
$dynamicActiveFixture = New-HookFixture -CaseRoot $dynamicActiveRoot -PointerStatus 'TEST'
$dynamicIdleFixture = New-HookFixture -CaseRoot $dynamicIdleRoot -PointerStatus '空闲' -TaskLabel '无' -FlowStatus 'DONE'
$dynamicConflictFixture = New-HookFixture -CaseRoot $dynamicConflictRoot -PointerStatus 'CODE_REVIEW'
$sharedStopHookPath = Join-Path $sharedHookRoot 'stop.js'
Write-RenderedHook -TemplatePath $stopTemplatePath -TargetPath $sharedStopHookPath -VaultRoot $dynamicActiveFixture.VaultRoot

$dynamicActiveResult = Invoke-NodeHook -HookPath $sharedStopHookPath -WorkingDirectory $dynamicActiveRoot
$dynamicIdleResult = Invoke-NodeHook -HookPath $sharedStopHookPath -WorkingDirectory $dynamicIdleRoot
$dynamicActiveMessage = Get-JsonPropertyValue -Object $dynamicActiveResult.Json -Name 'systemMessage'
$dynamicIdleMessage = Get-JsonPropertyValue -Object $dynamicIdleResult.Json -Name 'systemMessage'
if ($dynamicActiveResult.ExitCode -ne 0 -or $dynamicIdleResult.ExitCode -ne 0 -or $dynamicActiveMessage -notmatch 'status=TEST' -or $null -ne $dynamicIdleMessage) {
    Add-Failure 'one installed hook should resolve different workspaces from each invocation cwd without cross-reading'
} else {
    Add-Check 'one installed hook resolves the active workspace from each invocation cwd'
}

$workspaceResolutionCases = @(
    [pscustomobject]@{
        Name           = 'same-root environment candidates override cwd after normalization'
        Environment    = @{
            DEV_HARNESS_WORKSPACE_ROOT = $dynamicConflictRoot
            WORKSPACE_ROOT             = "${dynamicConflictRoot}\."
        }
        ExpectedStatus = 'CODE_REVIEW'
        ExpectEmpty    = $false
    },
    [pscustomobject]@{
        Name           = 'conflicting environment candidates fail closed even with valid cwd'
        Environment    = @{
            DEV_HARNESS_WORKSPACE_ROOT = $dynamicActiveRoot
            WORKSPACE_ROOT             = $dynamicConflictRoot
        }
        ExpectedStatus = $null
        ExpectEmpty    = $true
    },
    [pscustomobject]@{
        Name           = 'invalid environment candidate fails closed instead of using valid cwd'
        Environment    = @{ DEV_HARNESS_WORKSPACE_ROOT = $dynamicUnresolvedRoot }
        ExpectedStatus = $null
        ExpectEmpty    = $true
    },
    [pscustomobject]@{
        Name           = 'legacy environment candidate remains authoritative over cwd'
        Environment    = @{ CLAUDE_DEV_HARNESS_WORKSPACE_ROOT = $dynamicConflictRoot }
        ExpectedStatus = 'CODE_REVIEW'
        ExpectEmpty    = $false
    }
)

foreach ($case in $workspaceResolutionCases) {
    $result = Invoke-NodeHook -HookPath $sharedStopHookPath -WorkingDirectory $dynamicActiveRoot -Environment $case.Environment
    $message = Get-JsonPropertyValue -Object $result.Json -Name 'systemMessage'
    $passed = if ($case.ExpectEmpty) {
        $result.ExitCode -eq 0 -and $result.Output -ceq '{}' -and $null -ne $result.Json -and $null -eq $message
    } else {
        $result.ExitCode -eq 0 -and $null -ne $result.Json -and $message -match ("status={0}" -f [regex]::Escape($case.ExpectedStatus))
    }

    if ($passed) {
        Add-Check $case.Name
    } else {
        Add-Failure ("{0}; output={1}" -f $case.Name, $result.Output)
    }
}

if (
    (Test-Path -LiteralPath $dynamicActiveFixture.RecoveryIndexPath -PathType Leaf) -or
    (Test-Path -LiteralPath $dynamicConflictFixture.RecoveryIndexPath -PathType Leaf)
) {
    Add-Failure 'workspace resolution cases should remain read-only'
} else {
    Add-Check 'workspace resolution cases remain read-only'
}

} finally {
    try {
        Remove-DirectoryWithRetry -Path $dynamicUnresolvedRoot
    } finally {
        Remove-DirectoryWithRetry -Path $scratchRoot
    }
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
