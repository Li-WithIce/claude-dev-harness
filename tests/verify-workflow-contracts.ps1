# 校验 harness lite 的核心 workflow 契约。
# 重点覆盖 `advance-stage.ps1`、plan frontmatter、stage/tool 合法值和关键 gate。
[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Add-Check {
    <#
    .SYNOPSIS
    记录通过项。
    .DESCRIPTION
    测试结束时统一输出，便于快速确认哪些 lite 契约已经覆盖。
    .PARAMETER Message
    检查说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Checks += $Message
}

function Add-Failure {
    <#
    .SYNOPSIS
    记录失败项。
    .DESCRIPTION
    失败项会在脚本末尾集中输出并让测试返回非零退出码。
    .PARAMETER Message
    失败说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Failures += $Message
}

function New-IsolatedRepoFixture {
    param([string]$SourceRoot)

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-workflow-contracts-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\advance-stage.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\lite-artifact-parser.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\validate-lite-artifacts.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'skills\obsidian-memory\scripts\runtime-state-common.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'skills\obsidian-memory\scripts\resolve-shared-memory-paths.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'skills\obsidian-memory\scripts\repair-shared-memory.ps1'
    if (Test-Path -LiteralPath (Join-Path $SourceRoot 'agent-configs\profiles') -PathType Container) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'agent-configs\profiles'
    }
    if (Test-Path -LiteralPath (Join-Path $SourceRoot 'agent-configs\workflows') -PathType Container) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'agent-configs\workflows'
    }

    return $fixtureRoot
}

function New-PlanContent {
    <#
    .SYNOPSIS
    生成 lite plan.md 夹具。
    .DESCRIPTION
    这个模板覆盖 frontmatter、Clarification、User Confirmation 和 append-only sections。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER Stage
    当前阶段。
    .PARAMETER Tool
    当前阶段 tool。
    .PARAMETER ConfirmationStatus
    User Confirmation 状态。
    .PARAMETER PlanReviewRuns
    Plan Review 追加内容。
    .PARAMETER ImplementationRuns
    Implementation Notes 追加内容。
    .PARAMETER CodeReviewRuns
    Code Review 追加内容。
    .OUTPUTS
    String。
    #>
    param(
        [string]$TaskId,
        [string]$Stage,
        [string]$Tool,
        [string]$ConfirmationStatus = "confirmed",
        [string]$PlanReviewRuns = "",
        [string]$ImplementationRuns = "",
        [string]$CodeReviewRuns = ""
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'

    @"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
updated: $updatedDate
---
# Sample Plan

## Clarification
- 验收标准: 命令可以推进到下一阶段。
- 非目标: 不重写无关模块。
- 受影响目录: scripts/, skills/, tests/
- 回滚策略: 直接回退当前脚本改动。
- ui: not-applicable

## User Confirmation
- status: $ConfirmationStatus

## Plan
- 更新 ``scripts/advance-stage.ps1``
- 更新 ``tests/verify-workflow-contracts.ps1``

## Verification
- ``powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-contracts.ps1``

## Risks
- none

## Plan Review
$PlanReviewRuns

## Implementation Notes
$ImplementationRuns

## Code Review
$CodeReviewRuns

"@
}

function New-TestReport {
    <#
    .SYNOPSIS
    生成 test.md 夹具。
    .DESCRIPTION
    支持覆盖 Conclusion 和可选 Handoff，用来验证 TEST gate。
    .PARAMETER Conclusion
    结论字面量。
    .PARAMETER IncludeHandoff
    是否包含 Handoff section。
    .OUTPUTS
    String。
    #>
    param(
        [ValidateSet("pass", "fail", "blocked")]
        [string]$Conclusion,
        [bool]$IncludeHandoff = $true,
        [bool]$IncludeEvidence = $true,
        [string]$ExecutedAt = '2026-07-10T10:00:00+08:00'
    )

    $handoff = if ($IncludeHandoff) {
        "## Handoff`r`n- delivery: 提供当前 task 的验证结论。`r`n- follow_up: none`r`n"
    } else {
        ""
    }
    $evidence = if ($IncludeEvidence) {
        "## Evidence`r`n- command: ``pwsh -NoProfile -File tests/verify-workflow-contracts.ps1```r`n- exit_code: 0`r`n- executed_at: $ExecutedAt`r`n- revision: 0123456789abcdef0123456789abcdef01234567`r`n- evidence_path: scripts/advance-stage.ps1`r`n"
    } else {
        ""
    }

    @"
# Test Report

## Summary
- 针对 lite workflow 进行回归验证。

## Scope
- 只验证当前 task 的阶段推进契约。

## Inputs Reviewed
- docs/tasks/sample-task/plan.md

## Test Approach
- 运行脚本并回读产物。

## Findings
- 无额外发现。

$evidence

## Risks / Gaps
- 无。

## Conclusion
$Conclusion

$handoff
"@
}

function New-CanonicalTestPlan {
    param([string]$TaskId)

    $implementationRuns = @'
### Run 1 · 2026-07-10 09:58 · runner: Codex
- changed: initial implementation
- tests: targeted
- risks: none
- next: CODE_REVIEW
'@
    $codeReviewRuns = @'
### Run 1 · 2026-07-10 09:59 · runner: independent reviewer
- verdict: pass
- findings: none
- next: TEST
'@
    return New-PlanContent -TaskId $TaskId -Stage 'TEST' -Tool 'codex' -ImplementationRuns $implementationRuns -CodeReviewRuns $codeReviewRuns
}

function New-FailedReworkPlan {
    param([string]$TaskId)

    $implementationRuns = @'
### Run 1 · 2026-07-10 09:58 · runner: Codex
- changed: initial implementation
- tests: targeted
- risks: none
- next: CODE_REVIEW

### Run 2 · 2026-07-10 10:01 · runner: Codex
- changed: repair failed verification
- tests: targeted
- risks: none
- next: CODE_REVIEW
'@
    $codeReviewRuns = @'
### Run 1 · 2026-07-10 09:59 · runner: independent reviewer
- verdict: pass
- findings: none
- next: TEST
'@
    return New-PlanContent -TaskId $TaskId -Stage 'IMPLEMENT' -Tool 'codex' -ImplementationRuns $implementationRuns -CodeReviewRuns $codeReviewRuns
}

function Get-FileFingerprint {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 'missing'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'non-file'
    }
    return 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-FingerprintSequence {
    param(
        [object[]]$Before,
        [object[]]$After
    )

    if ($Before.Count -ne $After.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Before.Count; $index += 1) {
        if ([string]$Before[$index] -cne [string]$After[$index]) {
            return $false
        }
    }
    return $true
}

function Invoke-AdvanceOutcome {
    param(
        [string]$ScriptPath,
        [string]$TaskId,
        [string]$VaultRoot,
        [string]$ExpectedStage,
        [string]$WorkspaceRoot = '',
        [string]$Tool = '',
        [switch]$SyncOnly,
        [switch]$ActivateCurrent
    )

    $arguments = @{
        TaskId = $TaskId
        ExpectedStage = $ExpectedStage
        VaultRoot = $VaultRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $arguments.WorkspaceRoot = $WorkspaceRoot }
    if (-not [string]::IsNullOrWhiteSpace($Tool)) { $arguments.Tool = $Tool }
    if ($SyncOnly.IsPresent) { $arguments.SyncOnly = $true }
    if ($ActivateCurrent.IsPresent) { $arguments.ActivateCurrent = $true }
    try {
        $output = (& $ScriptPath @arguments | Out-String).Trim()
        return [pscustomobject]@{ Succeeded = $true; Output = $output; Error = '' }
    } catch {
        return [pscustomobject]@{ Succeeded = $false; Output = ''; Error = $_.Exception.Message }
    }
}

function Invoke-AdvanceSuccess {
    <#
    .SYNOPSIS
    断言阶段推进成功。
    .DESCRIPTION
    成功时返回脚本输出，失败时直接抛错让测试记为失败。
    .PARAMETER ScriptPath
    advance-stage.ps1 绝对路径。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER VaultRoot
    临时共享运行时目录。
    .PARAMETER Tool
    下一阶段 tool；DONE 不需要。
    .OUTPUTS
    String。
    #>
    param(
        [string]$ScriptPath,
        [string]$TaskId,
        [string]$VaultRoot,
        [string]$ExpectedStage,
        [string]$WorkspaceRoot = '',
        [string]$Tool = "",
        [string]$Profile = "",
        [string]$Model = "",
        [switch]$SyncOnly,
        [switch]$ActivateCurrent
    )

    $arguments = @{
        TaskId = $TaskId
        ExpectedStage = $ExpectedStage
        VaultRoot = $VaultRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $arguments.WorkspaceRoot = $WorkspaceRoot }
    if (-not [string]::IsNullOrWhiteSpace($Tool)) { $arguments.Tool = $Tool }
    if (-not [string]::IsNullOrWhiteSpace($Profile)) { $arguments.Profile = $Profile }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments.Model = $Model }
    if ($SyncOnly.IsPresent) { $arguments.SyncOnly = $true }
    if ($ActivateCurrent.IsPresent) { $arguments.ActivateCurrent = $true }
    return (& $ScriptPath @arguments | Out-String).Trim()
}

function Invoke-AdvanceFailure {
    <#
    .SYNOPSIS
    断言阶段推进失败。
    .DESCRIPTION
    失败时返回异常消息，便于继续检查错误语义。
    .PARAMETER ScriptPath
    advance-stage.ps1 绝对路径。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER VaultRoot
    临时共享运行时目录。
    .PARAMETER Tool
    下一阶段 tool；DONE 不需要。
    .OUTPUTS
    String。
    #>
    param(
        [string]$ScriptPath,
        [string]$TaskId,
        [string]$VaultRoot,
        [string]$ExpectedStage,
        [string]$WorkspaceRoot = '',
        [string]$Tool = "",
        [string]$Profile = "",
        [string]$Model = "",
        [switch]$SyncOnly,
        [switch]$ActivateCurrent
    )

    try {
        $arguments = @{
            TaskId = $TaskId
            ExpectedStage = $ExpectedStage
            VaultRoot = $VaultRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $arguments.WorkspaceRoot = $WorkspaceRoot }
        if (-not [string]::IsNullOrWhiteSpace($Tool)) { $arguments.Tool = $Tool }
        if (-not [string]::IsNullOrWhiteSpace($Profile)) { $arguments.Profile = $Profile }
        if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments.Model = $Model }
        if ($SyncOnly.IsPresent) { $arguments.SyncOnly = $true }
        if ($ActivateCurrent.IsPresent) { $arguments.ActivateCurrent = $true }
        & $ScriptPath @arguments | Out-Null
    } catch {
        return $_.Exception.Message
    }

    throw "advance-stage.ps1 unexpectedly succeeded for $TaskId"
}

function Start-AdvanceProcess {
    param(
        [string]$ScriptPath,
        [string]$TaskId,
        [string]$VaultRoot,
        [string]$ExpectedStage,
        [string]$WorkspaceRoot = '',
        [string]$Tool = 'codex',
        [switch]$SyncOnly,
        [switch]$ActivateCurrent
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-TaskId', $TaskId, '-ExpectedStage', $ExpectedStage, '-VaultRoot', $VaultRoot)
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $arguments += @('-WorkspaceRoot', $WorkspaceRoot) }
    if (-not [string]::IsNullOrWhiteSpace($Tool)) { $arguments += @('-Tool', $Tool) }
    if ($SyncOnly.IsPresent) { $arguments += '-SyncOnly' }
    if ($ActivateCurrent.IsPresent) { $arguments += '-ActivateCurrent' }
    foreach ($argument in $arguments) {
        $psi.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    return [pscustomobject]@{
        Process = $process
        StdOut = $process.StandardOutput.ReadToEndAsync()
        StdErr = $process.StandardError.ReadToEndAsync()
    }
}

function Test-WindowsPowerShellParse {
    <#
    .SYNOPSIS
    检查脚本能否被 Windows PowerShell 解析。
    .DESCRIPTION
    lite 主线仍需兼容 powershell.exe，因此这里直接用 Parser::ParseFile 做烟雾校验。
    .PARAMETER ScriptPath
    要解析的脚本路径。
    .OUTPUTS
    PSCustomObject。
    #>
    param([string]$ScriptPath)

    $escapedPath = $ScriptPath.Replace("'", "''")
    $command = @"
`$tokens = `$null
`$errors = `$null
[void][System.Management.Automation.Language.Parser]::ParseFile('$escapedPath', [ref]`$tokens, [ref]`$errors)
if (`$errors.Count -eq 0) {
    'OK'
} else {
    foreach (`$err in `$errors) {
        '{0}:{1}:{2}' -f `$err.Extent.StartLineNumber, `$err.Extent.StartColumnNumber, `$err.Message
    }
}
"@
    $output = @(& powershell.exe -NoProfile -Command $command 2>&1 | ForEach-Object { [string]$_ })

    return [pscustomobject]@{
        Passed = ($output.Count -eq 1 -and $output[0] -eq 'OK')
        Output = $output
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$SourceRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $SourceRoot
$RepoRoot = $fixtureRoot
. (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1')
. (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1')
$script:Checks = @()
$script:Failures = @()
$today = Get-Date -Format 'yyyy-MM-dd'

$scriptPath = Join-Path $RepoRoot "scripts\advance-stage.ps1"
$validatorPath = Join-Path $RepoRoot "scripts\validate-lite-artifacts.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Add-Failure "advance-stage.ps1 should exist at scripts/advance-stage.ps1"
} else {
    Add-Check "advance-stage.ps1 exists"
}

$windowsParse = Test-WindowsPowerShellParse -ScriptPath $scriptPath
if (-not $windowsParse.Passed) {
    Add-Failure ("advance-stage.ps1 should parse in Windows PowerShell, got: {0}" -f ($windowsParse.Output -join ' | '))
} else {
    Add-Check "advance-stage.ps1 parses in Windows PowerShell"
}

$advanceSource = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
$runtimeStateSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1') -Raw -Encoding utf8
$runtimeInboxSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1') -Raw -Encoding utf8
$repairSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\repair-shared-memory.ps1') -Raw -Encoding utf8
$liteParserSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\lite-artifact-parser.ps1') -Raw -Encoding utf8
$runtimeInboxTokens = $null
$runtimeInboxErrors = $null
$runtimeInboxAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1'), [ref]$runtimeInboxTokens, [ref]$runtimeInboxErrors)
$repairTokens = $null
$repairErrors = $null
$repairAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'skills\obsidian-memory\scripts\repair-shared-memory.ps1'), [ref]$repairTokens, [ref]$repairErrors)
$advanceTokens = $null
$advanceErrors = $null
$advanceAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$advanceTokens, [ref]$advanceErrors)
$addFallbackAst = @($advanceAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-RuntimeWritebackFallback' }, $true))
$clearFallbackAst = @($advanceAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Clear-RuntimeWritebackFallback' }, $true))
if ([regex]::Matches($runtimeStateSource, '\.Flush\(\$true\)').Count -eq 1 -and
    $runtimeStateSource.Contains('[System.IO.File]::Replace($tempPath, $targetPath, $backupPath, $true)') -and
    -not $runtimeInboxSource.Contains('$stream.Flush($true)') -and
    -not $liteParserSource.Contains('$stream.Flush($true)') -and
    @($runtimeInboxErrors).Count -eq 0 -and
    @($repairErrors).Count -eq 0 -and
    @($runtimeInboxAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-Utf8Bom' }, $true)).Count -eq 0 -and
    @($runtimeInboxAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Utf8Bom' }, $true)).Count -eq 0 -and
    @($runtimeInboxAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-CanonicalRuntimeUtf8BomAtomic' }, $true)).Count -eq 1 -and
    $runtimeInboxSource.Contains('Write-CanonicalRuntimeUtf8BomAtomic -Path $InboxPath -Content $content') -and
    @($repairAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Utf8Bom' }, $true)).Count -eq 0 -and
    @($repairAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-CanonicalRuntimeUtf8BomAtomic' }, $true)).Count -eq 9 -and
    $liteParserSource.Contains('Write-CanonicalRuntimeUtf8BomAtomic -Path $Path -Content $Content') -and
    $advanceSource.Contains('Write-CanonicalRuntimeUtf8BomAtomic -Path $taskMirrorPath -Content $taskMirror') -and
    $advanceSource.Contains('Write-CanonicalRuntimeUtf8BomAtomic -Path $currentPath -Content $currentWriteContent') -and
    $advanceSource.Contains('Write-CanonicalRuntimeUtf8BomAtomic -Path $indexPath -Content') -and
    -not $advanceSource.Contains('function Write-Utf8Bom')) {
    Add-Check 'plan, inbox, and runtime state reuse one flushed same-directory atomic UTF-8 writer'
} else {
    Add-Failure 'atomic UTF-8 writes should have one shared implementation; local-only callers should use it directly'
}
$runtimeReleaseIndex = $advanceSource.IndexOf('Exit-CanonicalRuntimeMutex -Mutex $runtimeMutex', [System.StringComparison]::Ordinal)
$fallbackClearIndex = $advanceSource.IndexOf('$null = Clear-RuntimeWritebackFallback', [System.StringComparison]::Ordinal)
$stageReleaseIndex = $advanceSource.IndexOf('Exit-LitePlanMutex -Mutex $advanceMutex', [System.StringComparison]::Ordinal)
$fallbackAppendIndex = $advanceSource.IndexOf('$appendError = Report-WritebackFallback', [System.StringComparison]::Ordinal)
if ($runtimeReleaseIndex -ge 0 -and
    @($advanceErrors).Count -eq 0 -and
    $addFallbackAst.Count -eq 1 -and
    $clearFallbackAst.Count -eq 1 -and
    @($addFallbackAst[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Enter-CanonicalRuntimeMutex' }, $true)).Count -eq 1 -and
    @($addFallbackAst[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Exit-CanonicalRuntimeMutex' }, $true)).Count -eq 1 -and
    @($clearFallbackAst[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Enter-CanonicalRuntimeMutex' }, $true)).Count -eq 1 -and
    @($clearFallbackAst[0].FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Exit-CanonicalRuntimeMutex' }, $true)).Count -eq 1 -and
    $fallbackClearIndex -gt $runtimeReleaseIndex -and
    $stageReleaseIndex -gt $fallbackClearIndex -and
    $fallbackAppendIndex -gt $runtimeReleaseIndex -and
    $stageReleaseIndex -gt $fallbackAppendIndex) {
    Add-Check 'fallback append and successful transaction clear reacquire runtime mutex only while retaining the same-task stage mutex'
} else {
    Add-Failure 'fallback append and clear should each reacquire runtime after the main runtime release and before same-task stage release'
}

$vaultRoot = Join-Path $RepoRoot '.assistant'
$taskBase = Join-Path $RepoRoot "docs\tasks"
New-Item -ItemType Directory -Path $vaultRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $vaultRoot "运行时") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $vaultRoot "运行时\tasks") -Force | Out-Null
New-Item -ItemType Directory -Path $taskBase -Force | Out-Null

$createdTaskDirs = @()

try {
    $atomicRuntimeTargets = @(
        [pscustomobject]@{ Name = 'mirror'; Path = (Join-Path $vaultRoot '运行时\tasks\atomic-runtime.md'); Old = 'old mirror'; New = 'new mirror' },
        [pscustomobject]@{ Name = 'current'; Path = (Join-Path $vaultRoot '运行时\当前任务.md'); Old = 'old current'; New = 'new current' },
        [pscustomobject]@{ Name = 'index'; Path = (Join-Path $vaultRoot '运行时\恢复索引.md'); Old = 'old index'; New = 'new index' }
    )
    $atomicRuntimeFailureSafe = $true
    foreach ($target in $atomicRuntimeTargets) {
        [System.IO.File]::WriteAllText($target.Path, $target.Old, (New-Object System.Text.UTF8Encoding($true)))
        $oldHash = (Get-FileHash -LiteralPath $target.Path -Algorithm SHA256).Hash
        $replaceFailed = $false
        $handle = [System.IO.File]::Open($target.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            try {
                Write-CanonicalRuntimeUtf8BomAtomic -Path $target.Path -Content $target.New
            } catch {
                $replaceFailed = $true
            }
        } finally {
            $handle.Dispose()
        }
        $tempFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $target.Path) -Filter ('.{0}.*.tmp*' -f (Split-Path -Leaf $target.Path)) -Force -ErrorAction SilentlyContinue)
        if (-not $replaceFailed -or
            (Get-FileHash -LiteralPath $target.Path -Algorithm SHA256).Hash -ne $oldHash -or
            $tempFiles.Count -ne 0) {
            $atomicRuntimeFailureSafe = $false
        }
    }
    if ($atomicRuntimeFailureSafe) {
        Add-Check 'failed mirror/current/index replaces preserve original bytes and clean atomic temp files'
    } else {
        Add-Failure 'failed runtime file replace should preserve every original and leave no temp file'
    }

    $abandonMarker = Join-Path $vaultRoot 'runtime-owner-held.marker'
    $abandonScript = Join-Path $vaultRoot 'abandon-runtime-owner.ps1'
    $runtimeHelperLiteral = (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1').Replace("'", "''")
    $abandonMarkerLiteral = $abandonMarker.Replace("'", "''")
    [System.IO.File]::WriteAllText($abandonScript, @"
param([string]`$TaskId, [string]`$ExpectedStage, [string]`$VaultRoot, [string]`$Tool)
. '$runtimeHelperLiteral'
`$mutex = Enter-CanonicalRuntimeMutex -VaultRoot `$VaultRoot
[System.IO.File]::WriteAllText('$abandonMarkerLiteral', 'held')
Start-Sleep -Seconds 60
"@, (New-Object System.Text.UTF8Encoding($true)))
    $owner = Start-AdvanceProcess -ScriptPath $abandonScript -TaskId 'abandoned-runtime-owner' -VaultRoot $vaultRoot -ExpectedStage 'PLAN'
    $ownerProcess = $owner.Process
    try {
        for ($attempt = 0; $attempt -lt 100 -and -not (Test-Path -LiteralPath $abandonMarker -PathType Leaf); $attempt += 1) {
            Start-Sleep -Milliseconds 25
        }
        if (-not (Test-Path -LiteralPath $abandonMarker -PathType Leaf)) {
            throw 'abandoned runtime owner did not acquire the mutex'
        }
        $ownerProcess.Kill()
        $ownerProcess.WaitForExit()

        $recoveredMutex = Enter-CanonicalRuntimeMutex -VaultRoot $vaultRoot
        try {
            foreach ($target in $atomicRuntimeTargets) {
                Write-CanonicalRuntimeUtf8BomAtomic -Path $target.Path -Content $target.New
            }
        } finally {
            Exit-CanonicalRuntimeMutex -Mutex $recoveredMutex
        }
        $abandonedPostimagesLegal = @($atomicRuntimeTargets | Where-Object {
                $content = [System.IO.File]::ReadAllText($_.Path)
                $content -cne $_.Old -and $content -cne $_.New
            }).Count -eq 0
        $abandonedTemps = @($atomicRuntimeTargets | ForEach-Object {
                Get-ChildItem -LiteralPath (Split-Path -Parent $_.Path) -Filter ('.{0}.*.tmp*' -f (Split-Path -Leaf $_.Path)) -Force -ErrorAction SilentlyContinue
            })
        if ($abandonedPostimagesLegal -and $abandonedTemps.Count -eq 0) {
            Add-Check 'an abandoned runtime owner recovers to only complete old/new postimages without temp files'
        } else {
            Add-Failure 'abandoned runtime ownership should never expose partial runtime postimages'
        }
    } finally {
        if (-not $ownerProcess.HasExited) {
            $ownerProcess.Kill()
            $ownerProcess.WaitForExit()
        }
        $null = $owner.StdOut.Result
        $null = $owner.StdErr.Result
        $ownerProcess.Dispose()
        Remove-Item -LiteralPath $abandonMarker,$abandonScript -Force -ErrorAction SilentlyContinue
    }
    foreach ($target in $atomicRuntimeTargets) {
        Remove-Item -LiteralPath $target.Path -Force -ErrorAction SilentlyContinue
    }

    $taskPlanSuccess = "lite-plan-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskPlanSuccessDir = Join-Path $taskBase $taskPlanSuccess
    $createdTaskDirs += $taskPlanSuccessDir
    New-Item -ItemType Directory -Path $taskPlanSuccessDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskPlanSuccessDir "plan.md") -Content (New-PlanContent -TaskId $taskPlanSuccess -Stage "PLAN" -Tool "claudecode")
    $planActivate = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskPlanSuccess -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -SyncOnly -ActivateCurrent
    $planAdvance = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskPlanSuccess -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool "codex"
    $planText = Get-Content -LiteralPath (Join-Path $taskPlanSuccessDir "plan.md") -Raw -Encoding utf8
    $taskMirror = Get-Content -LiteralPath (Join-Path $vaultRoot "运行时\tasks\$taskPlanSuccess.md") -Raw -Encoding utf8
    $currentTask = Get-Content -LiteralPath (Join-Path $vaultRoot "运行时\当前任务.md") -Raw -Encoding utf8
    $recoveryIndex = Get-Content -LiteralPath (Join-Path $vaultRoot "运行时\恢复索引.md") -Raw -Encoding utf8
    if ($planActivate -eq 'SYNCED | PLAN | claudecode' -and
        $planAdvance -eq "PLAN_REVIEW | codex" -and
        $planText -match "(?m)^stage:\s*PLAN_REVIEW\s*$" -and
        $planText -match "(?m)^tool:\s*codex\s*$" -and
        $taskMirror -match "(?m)^schema_version:\s*task-runtime/v1\.1\s*$" -and
        $taskMirror -match [regex]::Escape("- pointer: docs/tasks/$taskPlanSuccess/plan.md") -and
        $taskMirror -match "(?m)^tool:\s*codex\s*$" -and
        $taskMirror -match "(?m)^entry_host:\s*codex\s*$" -and
        $taskMirror -match [regex]::Escape("- assigned_tool: codex") -and
        $currentTask -match [regex]::Escape("task_id: $taskPlanSuccess") -and
        $currentTask -match "(?m)^schema_version:\s*current-task-pointer/v1\.1\s*$" -and
        $currentTask -match "(?m)^entry_host:\s*codex\s*$" -and
        $currentTask -match [regex]::Escape(('| task_id | `{0}` |' -f $taskPlanSuccess)) -and
        $currentTask -match [regex]::Escape('| 状态 | PLAN_REVIEW |') -and
        $currentTask -match [regex]::Escape("| 当前文档 | docs/tasks/$taskPlanSuccess/plan.md |") -and
        $currentTask -match [regex]::Escape('| 工具 | codex |') -and
        $currentTask -match [regex]::Escape('| 下一步 | 使用 codex 继续 PLAN_REVIEW |') -and
        $recoveryIndex -match "(?m)^schema_version:\s*recovery-index/v1\.1\s*$" -and
        $recoveryIndex -match [regex]::Escape(('- task_id: `{0}`' -f $taskPlanSuccess))) {
        Add-Check "PLAN success case advances to PLAN_REVIEW and rewrites lite mirrors"
    } else {
        Add-Failure "PLAN success case should advance to PLAN_REVIEW and update docs/tasks mirror paths"
    }

    $workspaceMismatchA = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-workspace-a-' + [guid]::NewGuid().ToString('N'))
    $workspaceMismatchB = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-workspace-b-' + [guid]::NewGuid().ToString('N'))
    $createdTaskDirs += @($workspaceMismatchA, $workspaceMismatchB)
    $taskWorkspaceMismatch = 'lite-workspace-mismatch-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $workspaceMismatchTaskDir = Join-Path $workspaceMismatchA ("docs\tasks\{0}" -f $taskWorkspaceMismatch)
    New-Item -ItemType Directory -Path $workspaceMismatchTaskDir,$workspaceMismatchB -Force | Out-Null
    $workspaceMismatchPlan = Join-Path $workspaceMismatchTaskDir 'plan.md'
    Write-Utf8Bom -Path $workspaceMismatchPlan -Content (New-PlanContent -TaskId $taskWorkspaceMismatch -Stage 'PLAN' -Tool 'codex')
    $workspaceMismatchPlanHash = (Get-FileHash -LiteralPath $workspaceMismatchPlan -Algorithm SHA256).Hash
    $workspaceMismatchVault = Join-Path $workspaceMismatchB '.assistant'
    $workspaceMismatchOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskWorkspaceMismatch -WorkspaceRoot $workspaceMismatchA -VaultRoot $workspaceMismatchVault -ExpectedStage 'PLAN' -SyncOnly -ActivateCurrent
    if (-not $workspaceMismatchOutcome.Succeeded -and
        $workspaceMismatchOutcome.Error -match 'Explicit VaultRoot and WorkspaceRoot disagree' -and
        (Get-FileHash -LiteralPath $workspaceMismatchPlan -Algorithm SHA256).Hash -eq $workspaceMismatchPlanHash -and
        -not (Test-Path -LiteralPath (Join-Path $workspaceMismatchA '.assistant')) -and
        -not (Test-Path -LiteralPath $workspaceMismatchVault)) {
        Add-Check 'WorkspaceRoot and VaultRoot mismatch fails before plan or either workspace runtime is written'
    } else {
        Add-Failure ("WorkspaceRoot and VaultRoot mismatch should fail with zero writes: {0}" -f $(if ($workspaceMismatchOutcome.Succeeded) { $workspaceMismatchOutcome.Output } else { $workspaceMismatchOutcome.Error }))
    }

    $lifecycleVault = $vaultRoot
    Remove-DirectoryWithRetry -Path $lifecycleVault
    $createdTaskDirs += $lifecycleVault
    New-Item -ItemType Directory -Path (Join-Path $lifecycleVault '运行时\tasks') -Force | Out-Null

    $taskSyncMinimal = 'lite-sync-minimal-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskSyncMinimalDir = Join-Path $taskBase $taskSyncMinimal
    $createdTaskDirs += $taskSyncMinimalDir
    New-Item -ItemType Directory -Path $taskSyncMinimalDir -Force | Out-Null
    $syncMinimalPlanPath = Join-Path $taskSyncMinimalDir 'plan.md'
    $syncMinimalPlan = (New-PlanContent -TaskId $taskSyncMinimal -Stage 'PLAN' -Tool 'codex') -replace '## Verification(?s:.*?)## Risks', "## Verification`r`n- invalid plain text`r`n`r`n## Risks"
    Write-Utf8Bom -Path $syncMinimalPlanPath -Content $syncMinimalPlan
    $syncMinimalPlanHash = (Get-FileHash -LiteralPath $syncMinimalPlanPath -Algorithm SHA256).Hash
    $syncMinimalResult = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskSyncMinimal -VaultRoot $lifecycleVault -ExpectedStage 'PLAN' -SyncOnly -ActivateCurrent
    $syncMinimalCurrent = Get-CanonicalCurrentTaskState -Path (Join-Path $lifecycleVault '运行时\当前任务.md')
    $syncMinimalMirror = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory (Join-Path $lifecycleVault '运行时\tasks') | Where-Object { $_.TaskId -eq $taskSyncMinimal })
    if ($syncMinimalResult -eq 'SYNCED | PLAN | codex' -and
        (Get-FileHash -LiteralPath $syncMinimalPlanPath -Algorithm SHA256).Hash -eq $syncMinimalPlanHash -and
        $syncMinimalCurrent.TaskId -eq $taskSyncMinimal -and
        $syncMinimalMirror.Count -eq 1 -and $syncMinimalMirror[0].Stage -eq 'PLAN') {
        Add-Check 'SyncOnly skips the full completion validator, keeps plan unchanged, and can explicitly activate current'
    } else {
        Add-Failure 'SyncOnly should perform only minimal frontmatter/CAS validation and runtime synchronization'
    }

    $syncArgumentCases = @(
        @{ Name = 'Tool'; Arguments = @{ Tool = 'codex' } }
        @{ Name = 'Profile'; Arguments = @{ Profile = 'harness-default-codex' } }
        @{ Name = 'Model'; Arguments = @{ Model = 'openai/gpt-5' } }
    )
    $syncArgumentsRejected = $true
    foreach ($syncArgumentCase in $syncArgumentCases) {
        $syncFailureArguments = @{
            ScriptPath = $scriptPath
            TaskId = $taskSyncMinimal
            VaultRoot = $lifecycleVault
            ExpectedStage = 'PLAN'
            SyncOnly = $true
        }
        foreach ($key in $syncArgumentCase.Arguments.Keys) { $syncFailureArguments[$key] = $syncArgumentCase.Arguments[$key] }
        $syncArgumentMessage = Invoke-AdvanceFailure @syncFailureArguments
        if ($syncArgumentMessage -notmatch 'SyncOnly.*Tool.*Profile.*Model') { $syncArgumentsRejected = $false }
    }
    if ($syncArgumentsRejected) {
        Add-Check 'SyncOnly rejects Tool, Profile, and Model arguments'
    } else {
        Add-Failure 'SyncOnly should reject next-stage selection arguments'
    }

    $syncCasMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskSyncMinimal -VaultRoot $lifecycleVault -ExpectedStage 'PLAN_REVIEW' -SyncOnly
    if ($syncCasMessage -match 'ExpectedStage CAS mismatch' -and (Get-FileHash -LiteralPath $syncMinimalPlanPath -Algorithm SHA256).Hash -eq $syncMinimalPlanHash) {
        Add-Check 'ExpectedStage CAS rejects stale SyncOnly callers without mutation'
    } else {
        Add-Failure "stale SyncOnly CAS should fail before writes, got: $syncCasMessage"
    }

    $taskReplay = 'lite-replay-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskReplayDir = Join-Path $taskBase $taskReplay
    $createdTaskDirs += $taskReplayDir
    New-Item -ItemType Directory -Path $taskReplayDir -Force | Out-Null
    $taskReplayPlan = Join-Path $taskReplayDir 'plan.md'
    Write-Utf8Bom -Path $taskReplayPlan -Content (New-PlanContent -TaskId $taskReplay -Stage 'PLAN' -Tool 'codex')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskReplay -VaultRoot $lifecycleVault -ExpectedStage 'PLAN' -SyncOnly -ActivateCurrent
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskReplay -VaultRoot $lifecycleVault -ExpectedStage 'PLAN' -Tool 'codex'
    $replayPlanHash = (Get-FileHash -LiteralPath $taskReplayPlan -Algorithm SHA256).Hash
    $replayMirrorPath = Join-Path $lifecycleVault ("运行时\tasks\{0}.md" -f $taskReplay)
    $replayMirrorHash = (Get-FileHash -LiteralPath $replayMirrorPath -Algorithm SHA256).Hash
    $replayMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskReplay -VaultRoot $lifecycleVault -ExpectedStage 'PLAN' -Tool 'codex'
    if ($replayMessage -match 'ExpectedStage CAS mismatch' -and
        (Get-FileHash -LiteralPath $taskReplayPlan -Algorithm SHA256).Hash -eq $replayPlanHash -and
        (Get-FileHash -LiteralPath $replayMirrorPath -Algorithm SHA256).Hash -eq $replayMirrorHash) {
        Add-Check 'lost-success ordinary advance replay is rejected by caller-supplied CAS'
    } else {
        Add-Failure "ordinary replay should fail CAS with zero writes, got: $replayMessage"
    }

    $taskBackground = 'lite-background-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskBackgroundDir = Join-Path $taskBase $taskBackground
    $createdTaskDirs += $taskBackgroundDir
    New-Item -ItemType Directory -Path $taskBackgroundDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskBackgroundDir 'plan.md') -Content (New-PlanContent -TaskId $taskBackground -Stage 'PLAN' -Tool 'codex')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskBackground -VaultRoot $lifecycleVault -ExpectedStage 'PLAN' -Tool 'codex'
    $backgroundCurrent = Get-CanonicalCurrentTaskState -Path (Join-Path $lifecycleVault '运行时\当前任务.md')
    $backgroundMirror = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory (Join-Path $lifecycleVault '运行时\tasks') | Where-Object { $_.TaskId -eq $taskBackground })
    if ($backgroundCurrent.TaskId -eq $taskReplay -and $backgroundMirror.Count -eq 1 -and $backgroundMirror[0].Stage -eq 'PLAN_REVIEW') {
        Add-Check 'background advance updates its mirror without stealing current'
    } else {
        Add-Failure 'background advance should preserve the active current pointer'
    }

    $failRouteVault = $vaultRoot
    Remove-DirectoryWithRetry -Path $failRouteVault
    $createdTaskDirs += $failRouteVault
    New-Item -ItemType Directory -Path (Join-Path $failRouteVault '运行时\tasks') -Force | Out-Null
    $taskFailActive = 'lite-fail-active-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskFailActiveDir = Join-Path $taskBase $taskFailActive
    $createdTaskDirs += $taskFailActiveDir
    New-Item -ItemType Directory -Path $taskFailActiveDir -Force | Out-Null
    $failActivePlanPath = Join-Path $taskFailActiveDir 'plan.md'
    Write-Utf8Bom -Path $failActivePlanPath -Content (New-CanonicalTestPlan -TaskId $taskFailActive)
    Write-Utf8Bom -Path (Join-Path $taskFailActiveDir 'test.md') -Content (New-TestReport -Conclusion 'fail')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskFailActive -VaultRoot $failRouteVault -ExpectedStage 'TEST' -SyncOnly -ActivateCurrent
    $failActiveOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskFailActive -VaultRoot $failRouteVault -ExpectedStage 'TEST'
    $failActivePlanText = Get-Content -LiteralPath $failActivePlanPath -Raw -Encoding utf8
    $failActiveCurrent = Get-CanonicalCurrentTaskState -Path (Join-Path $failRouteVault '运行时\当前任务.md')
    $failActiveMirror = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory (Join-Path $failRouteVault '运行时\tasks') | Where-Object { $_.TaskId -eq $taskFailActive })
    if ($failActiveOutcome.Succeeded -and
        $failActiveOutcome.Output -eq 'IMPLEMENT | codex' -and
        $failActivePlanText -match '(?m)^stage:\s*IMPLEMENT\s*$' -and
        $failActiveCurrent.TaskId -eq $taskFailActive -and $failActiveCurrent.Stage -eq 'IMPLEMENT' -and
        $failActiveMirror.Count -eq 1 -and $failActiveMirror[0].Stage -eq 'IMPLEMENT') {
        Add-Check 'visible TEST fail returns an active task to IMPLEMENT and updates its runtime state'
    } else {
        Add-Failure ("visible TEST fail should return active state to IMPLEMENT: {0}" -f $(if ($failActiveOutcome.Succeeded) { $failActiveOutcome.Output } else { $failActiveOutcome.Error }))
    }

    $taskFailBackground = 'lite-fail-background-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskFailBackgroundDir = Join-Path $taskBase $taskFailBackground
    $createdTaskDirs += $taskFailBackgroundDir
    New-Item -ItemType Directory -Path $taskFailBackgroundDir -Force | Out-Null
    $failBackgroundPlanPath = Join-Path $taskFailBackgroundDir 'plan.md'
    Write-Utf8Bom -Path $failBackgroundPlanPath -Content (New-CanonicalTestPlan -TaskId $taskFailBackground)
    Write-Utf8Bom -Path (Join-Path $taskFailBackgroundDir 'test.md') -Content (New-TestReport -Conclusion 'fail')
    $failBackgroundCurrentPath = Join-Path $failRouteVault '运行时\当前任务.md'
    $failBackgroundCurrentBefore = Get-FileFingerprint -Path $failBackgroundCurrentPath
    $failBackgroundOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskFailBackground -VaultRoot $failRouteVault -ExpectedStage 'TEST'
    $failBackgroundPlanText = Get-Content -LiteralPath $failBackgroundPlanPath -Raw -Encoding utf8
    $failBackgroundMirror = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory (Join-Path $failRouteVault '运行时\tasks') | Where-Object { $_.TaskId -eq $taskFailBackground })
    if ($failBackgroundOutcome.Succeeded -and
        $failBackgroundOutcome.Output -eq 'IMPLEMENT | codex' -and
        $failBackgroundPlanText -match '(?m)^stage:\s*IMPLEMENT\s*$' -and
        $failBackgroundMirror.Count -eq 1 -and $failBackgroundMirror[0].Stage -eq 'IMPLEMENT' -and
        (Get-FileFingerprint -Path $failBackgroundCurrentPath) -ceq $failBackgroundCurrentBefore) {
        Add-Check 'background TEST fail returns only its mirror to IMPLEMENT without stealing current'
    } else {
        Add-Failure ("background TEST fail should return to IMPLEMENT without stealing current: {0}" -f $(if ($failBackgroundOutcome.Succeeded) { $failBackgroundOutcome.Output } else { $failBackgroundOutcome.Error }))
    }

    $blockedVault = $vaultRoot
    Remove-DirectoryWithRetry -Path $blockedVault
    $createdTaskDirs += $blockedVault
    New-Item -ItemType Directory -Path (Join-Path $blockedVault '运行时\tasks') -Force | Out-Null
    $taskBlocked = 'lite-blocked-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskBlockedDir = Join-Path $taskBase $taskBlocked
    $createdTaskDirs += $taskBlockedDir
    New-Item -ItemType Directory -Path $taskBlockedDir -Force | Out-Null
    $blockedPlanPath = Join-Path $taskBlockedDir 'plan.md'
    Write-Utf8Bom -Path $blockedPlanPath -Content (New-CanonicalTestPlan -TaskId $taskBlocked)
    Write-Utf8Bom -Path (Join-Path $taskBlockedDir 'test.md') -Content (New-TestReport -Conclusion 'blocked')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskBlocked -VaultRoot $blockedVault -ExpectedStage 'TEST' -SyncOnly -ActivateCurrent
    $blockedInboxPath = Join-Path $blockedVault '运行时\收件箱.md'
    Write-RuntimeInbox -InboxPath $blockedInboxPath -CreatedDate '2026-07-10' -Rows @([pscustomobject]@{
            CreatedAt = '-'; Source = 'sentinel'; TaskId = 'unknown'; Type = 'hidden'; Status = 'open'; Summary = 'preserve'; Payload = 'bytes'
        })
    $blockedPaths = @(
        $blockedPlanPath,
        (Join-Path $blockedVault ("运行时\tasks\{0}.md" -f $taskBlocked)),
        (Join-Path $blockedVault '运行时\当前任务.md'),
        (Join-Path $blockedVault '运行时\恢复索引.md'),
        $blockedInboxPath
    )
    $blockedBefore = @($blockedPaths | ForEach-Object { Get-FileFingerprint -Path $_ })
    $blockedOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskBlocked -VaultRoot $blockedVault -ExpectedStage 'TEST'
    $blockedAfter = @($blockedPaths | ForEach-Object { Get-FileFingerprint -Path $_ })
    if (-not $blockedOutcome.Succeeded -and
        $blockedOutcome.Error -match 'blocked' -and
        (Test-FingerprintSequence -Before $blockedBefore -After $blockedAfter)) {
        Add-Check 'TEST blocked stays in TEST with zero plan, mirror, current, index, inbox, or fallback writes'
    } else {
        Add-Failure ("TEST blocked should fail closed with every state surface unchanged: {0}" -f $(if ($blockedOutcome.Succeeded) { $blockedOutcome.Output } else { $blockedOutcome.Error }))
    }

    $retryVault = $vaultRoot
    Remove-DirectoryWithRetry -Path $retryVault
    $createdTaskDirs += $retryVault
    New-Item -ItemType Directory -Path (Join-Path $retryVault '运行时\tasks') -Force | Out-Null
    $taskRetryChain = 'lite-retry-chain-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskRetryChainDir = Join-Path $taskBase $taskRetryChain
    $createdTaskDirs += $taskRetryChainDir
    New-Item -ItemType Directory -Path $taskRetryChainDir -Force | Out-Null
    $retryPlanPath = Join-Path $taskRetryChainDir 'plan.md'
    $retryTestPath = Join-Path $taskRetryChainDir 'test.md'
    Write-Utf8Bom -Path $retryPlanPath -Content (New-CanonicalTestPlan -TaskId $taskRetryChain)
    Write-Utf8Bom -Path $retryTestPath -Content (New-TestReport -Conclusion 'fail' -ExecutedAt '2026-07-10T10:00:00+08:00')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskRetryChain -VaultRoot $retryVault -ExpectedStage 'TEST' -SyncOnly -ActivateCurrent
    $retrySteps = @()
    $retryFailOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskRetryChain -VaultRoot $retryVault -ExpectedStage 'TEST'
    if ($retryFailOutcome.Succeeded -and $retryFailOutcome.Output -eq 'IMPLEMENT | codex') {
        $retrySteps += 'IMPLEMENT'
        $repairRun = @'
### Run 2 · 2026-07-10 10:01 · runner: Codex
- changed: repair failed verification
- tests: targeted
- risks: none
- next: CODE_REVIEW
'@
        $retryPlanText = Get-Content -LiteralPath $retryPlanPath -Raw -Encoding utf8
        $retryPlanText = $retryPlanText.Replace('## Code Review', ($repairRun + "`r`n`r`n## Code Review"))
        Write-Utf8Bom -Path $retryPlanPath -Content $retryPlanText
        $retryImplementOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskRetryChain -VaultRoot $retryVault -ExpectedStage 'IMPLEMENT'
        if ($retryImplementOutcome.Succeeded -and $retryImplementOutcome.Output -eq 'CODE_REVIEW | codex') {
            $retrySteps += 'CODE_REVIEW'
            $reviewRun = @'
### Run 2 · 2026-07-10 10:02 · runner: independent reviewer
- verdict: pass
- findings: none
- next: TEST
'@
            $retryPlanText = (Get-Content -LiteralPath $retryPlanPath -Raw -Encoding utf8).TrimEnd() + "`r`n`r`n" + $reviewRun + "`r`n"
            Write-Utf8Bom -Path $retryPlanPath -Content $retryPlanText
            $retryReviewOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskRetryChain -VaultRoot $retryVault -ExpectedStage 'CODE_REVIEW'
            if ($retryReviewOutcome.Succeeded -and $retryReviewOutcome.Output -eq 'TEST | codex') {
                $retrySteps += 'TEST'
                Write-Utf8Bom -Path $retryTestPath -Content (New-TestReport -Conclusion 'pass' -ExecutedAt '2026-07-10T10:03:00+08:00')
                $retryPassOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskRetryChain -VaultRoot $retryVault -ExpectedStage 'TEST'
                if ($retryPassOutcome.Succeeded -and $retryPassOutcome.Output -eq 'DONE | none') {
                    $retrySteps += 'DONE'
                }
            }
        }
    }
    $retryFinalPlan = Get-Content -LiteralPath $retryPlanPath -Raw -Encoding utf8
    $retryFinalCurrent = Get-CanonicalCurrentTaskState -Path (Join-Path $retryVault '运行时\当前任务.md')
    if (($retrySteps -join ' -> ') -eq 'IMPLEMENT -> CODE_REVIEW -> TEST -> DONE' -and
        $retryFinalPlan -match '(?m)^stage:\s*DONE\s*$' -and
        $retryFinalCurrent.TaskId -eq 'none' -and $retryFinalCurrent.Stage -eq '空闲') {
        Add-Check 'failed verification completes the canonical IMPLEMENT to CODE_REVIEW to TEST to DONE retry chain'
    } else {
        Add-Failure ("failed verification should complete one canonical retry chain, reached: {0}; first={1}" -f ($retrySteps -join ' -> '), $(if ($retryFailOutcome.Succeeded) { $retryFailOutcome.Output } else { $retryFailOutcome.Error }))
    }

    $missingCurrentVault = $vaultRoot
    Remove-DirectoryWithRetry -Path $missingCurrentVault
    $createdTaskDirs += $missingCurrentVault
    New-Item -ItemType Directory -Path (Join-Path $missingCurrentVault '运行时\tasks') -Force | Out-Null
    $taskMissingCurrent = 'lite-current-missing-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMissingCurrentDir = Join-Path $taskBase $taskMissingCurrent
    $createdTaskDirs += $taskMissingCurrentDir
    New-Item -ItemType Directory -Path $taskMissingCurrentDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskMissingCurrentDir 'plan.md') -Content (New-PlanContent -TaskId $taskMissingCurrent -Stage 'PLAN' -Tool 'codex')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskMissingCurrent -VaultRoot $missingCurrentVault -ExpectedStage 'PLAN' -Tool 'codex'
    $missingCurrentState = Get-CanonicalCurrentTaskState -Path (Join-Path $missingCurrentVault '运行时\当前任务.md')
    if ($missingCurrentState.TaskId -eq 'none' -and $missingCurrentState.Stage -eq '空闲' -and $missingCurrentState.CurrentDoc -eq 'none') {
        Add-Check 'background advance with a missing current pointer creates canonical idle instead of activating itself'
    } else {
        Add-Failure 'missing current pointer should normalize to canonical idle'
    }

    $taskDoneActive = 'lite-done-active-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskDoneActiveDir = Join-Path $taskBase $taskDoneActive
    $createdTaskDirs += $taskDoneActiveDir
    New-Item -ItemType Directory -Path $taskDoneActiveDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskDoneActiveDir 'plan.md') -Content (New-CanonicalTestPlan -TaskId $taskDoneActive)
    Write-Utf8Bom -Path (Join-Path $taskDoneActiveDir 'test.md') -Content (New-TestReport -Conclusion 'pass')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskDoneActive -VaultRoot $lifecycleVault -ExpectedStage 'TEST' -SyncOnly -ActivateCurrent
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskDoneActive -VaultRoot $lifecycleVault -ExpectedStage 'TEST'
    $doneActiveCurrent = Get-CanonicalCurrentTaskState -Path (Join-Path $lifecycleVault '运行时\当前任务.md')
    if ($doneActiveCurrent.TaskId -eq 'none' -and $doneActiveCurrent.Stage -eq '空闲') {
        Add-Check 'active DONE resets current to canonical idle'
    } else {
        Add-Failure 'active DONE should reset current to canonical idle'
    }

    $taskDoneKeeper = 'lite-done-keeper-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskDoneKeeperDir = Join-Path $taskBase $taskDoneKeeper
    $createdTaskDirs += $taskDoneKeeperDir
    New-Item -ItemType Directory -Path $taskDoneKeeperDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskDoneKeeperDir 'plan.md') -Content (New-PlanContent -TaskId $taskDoneKeeper -Stage 'PLAN' -Tool 'codex')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskDoneKeeper -VaultRoot $lifecycleVault -ExpectedStage 'PLAN' -SyncOnly -ActivateCurrent
    $taskDoneBackground = 'lite-done-background-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskDoneBackgroundDir = Join-Path $taskBase $taskDoneBackground
    $createdTaskDirs += $taskDoneBackgroundDir
    New-Item -ItemType Directory -Path $taskDoneBackgroundDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskDoneBackgroundDir 'plan.md') -Content (New-CanonicalTestPlan -TaskId $taskDoneBackground)
    Write-Utf8Bom -Path (Join-Path $taskDoneBackgroundDir 'test.md') -Content (New-TestReport -Conclusion 'pass')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskDoneBackground -VaultRoot $lifecycleVault -ExpectedStage 'TEST'
    $doneBackgroundCurrent = Get-CanonicalCurrentTaskState -Path (Join-Path $lifecycleVault '运行时\当前任务.md')
    if ($doneBackgroundCurrent.TaskId -eq $taskDoneKeeper) {
        Add-Check 'background DONE leaves current unchanged'
    } else {
        Add-Failure 'background DONE should not clear or replace another active current task'
    }

    $taskActivateDone = 'lite-activate-done-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskActivateDoneDir = Join-Path $taskBase $taskActivateDone
    $createdTaskDirs += $taskActivateDoneDir
    New-Item -ItemType Directory -Path $taskActivateDoneDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskActivateDoneDir 'plan.md') -Content (New-PlanContent -TaskId $taskActivateDone -Stage 'DONE' -Tool 'none')
    $activateDoneMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskActivateDone -VaultRoot $lifecycleVault -ExpectedStage 'DONE' -SyncOnly -ActivateCurrent
    if ($activateDoneMessage -match 'cannot activate DONE') {
        Add-Check 'ActivateCurrent rejects an already DONE task before writes'
    } else {
        Add-Failure "ActivateCurrent should reject DONE, got: $activateDoneMessage"
    }

    $taskActivateTargetDone = 'lite-activate-target-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskActivateTargetDoneDir = Join-Path $taskBase $taskActivateTargetDone
    $createdTaskDirs += $taskActivateTargetDoneDir
    New-Item -ItemType Directory -Path $taskActivateTargetDoneDir -Force | Out-Null
    $activateTargetPlan = Join-Path $taskActivateTargetDoneDir 'plan.md'
    Write-Utf8Bom -Path $activateTargetPlan -Content (New-CanonicalTestPlan -TaskId $taskActivateTargetDone)
    Write-Utf8Bom -Path (Join-Path $taskActivateTargetDoneDir 'test.md') -Content (New-TestReport -Conclusion 'pass')
    $activateTargetHash = (Get-FileHash -LiteralPath $activateTargetPlan -Algorithm SHA256).Hash
    $activateTargetMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskActivateTargetDone -VaultRoot $lifecycleVault -ExpectedStage 'TEST' -ActivateCurrent
    if ($activateTargetMessage -match 'cannot activate DONE' -and (Get-FileHash -LiteralPath $activateTargetPlan -Algorithm SHA256).Hash -eq $activateTargetHash) {
        Add-Check 'ActivateCurrent rejects a transition targeting DONE before stage mutation'
    } else {
        Add-Failure "ActivateCurrent should reject target DONE without mutation, got: $activateTargetMessage"
    }

    $fallbackVault = $vaultRoot
    Remove-DirectoryWithRetry -Path $fallbackVault
    $createdTaskDirs += $fallbackVault
    New-Item -ItemType Directory -Path (Join-Path $fallbackVault '运行时\tasks') -Force | Out-Null
    $taskFallback = 'lite-fallback-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskFallbackDir = Join-Path $taskBase $taskFallback
    $createdTaskDirs += $taskFallbackDir
    New-Item -ItemType Directory -Path $taskFallbackDir -Force | Out-Null
    $fallbackPlanPath = Join-Path $taskFallbackDir 'plan.md'
    Write-Utf8Bom -Path $fallbackPlanPath -Content (New-CanonicalTestPlan -TaskId $taskFallback)
    Write-Utf8Bom -Path (Join-Path $taskFallbackDir 'test.md') -Content (New-TestReport -Conclusion 'fail')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskFallback -VaultRoot $fallbackVault -ExpectedStage 'TEST' -SyncOnly -ActivateCurrent
    $fallbackSentinelRow = [pscustomobject]@{
        CreatedAt = '-'
        Source = 'must-preserve'
        TaskId = 'unknown'
        Type = 'hidden'
        Status = 'open'
        Summary = 'hidden malformed row'
        Payload = 'bytes'
    }
    $fallbackSentinelLine = Format-InboxRow -Row $fallbackSentinelRow
    Write-RuntimeInbox -InboxPath (Join-Path $fallbackVault '运行时\收件箱.md') -CreatedDate '2026-07-11' -Rows @($fallbackSentinelRow)
    $fallbackCurrentPath = Join-Path $fallbackVault '运行时\当前任务.md'
    $fallbackIndexPath = Join-Path $fallbackVault '运行时\恢复索引.md'
    $fallbackMirrorPath = Join-Path $fallbackVault ("运行时\tasks\{0}.md" -f $taskFallback)
    $fallbackIndexHash = (Get-FileHash -LiteralPath $fallbackIndexPath -Algorithm SHA256).Hash
    $fallbackCurrentHandle = [System.IO.File]::Open($fallbackCurrentPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $fallbackAdvanceMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskFallback -VaultRoot $fallbackVault -ExpectedStage 'TEST'
    } finally {
        $fallbackCurrentHandle.Dispose()
    }
    $fallbackPlanText = Get-Content -LiteralPath $fallbackPlanPath -Raw -Encoding utf8
    $fallbackMirrorText = Get-Content -LiteralPath $fallbackMirrorPath -Raw -Encoding utf8
    $fallbackCurrentState = Get-CanonicalCurrentTaskState -Path $fallbackCurrentPath
    $fallbackInbox = Read-RuntimeInbox -VaultRoot $fallbackVault
    $fallbackInboxText = Get-Content -LiteralPath $fallbackInbox.Path -Raw -Encoding utf8
    $fallbackRows = @($fallbackInbox.Rows | Where-Object { $_.Status -eq 'open' -and $_.TaskId -eq $taskFallback -and $_.Type -eq 'writeback-fallback' -and $_.Source -eq 'advance-stage' })
    $fallbackPayload = if ($fallbackRows.Count -eq 1) { $fallbackRows[0].Payload | ConvertFrom-Json } else { $null }
    if ($fallbackAdvanceMessage -match 'Runtime writeback failed' -and
        $fallbackPlanText -match '(?m)^stage:\s*IMPLEMENT\s*$' -and
        $fallbackMirrorText -match '(?m)^stage:\s*IMPLEMENT\s*$' -and
        $fallbackCurrentState.Stage -eq 'TEST' -and
        (Get-FileHash -LiteralPath $fallbackIndexPath -Algorithm SHA256).Hash -eq $fallbackIndexHash -and
        $fallbackInboxText.Contains($fallbackSentinelLine) -and
        $fallbackRows.Count -eq 1 -and
        $fallbackPayload.schema_version -eq 'writeback-fallback/v1' -and
        $fallbackPayload.operation -eq 'advance' -and
        $fallbackPayload.expected_stage -eq 'IMPLEMENT' -and
        $fallbackPayload.failed_step -eq 'current-task') {
        Add-Check 'TEST fail runtime ladder preserves IMPLEMENT plan/mirror postimages and appends one current-write fallback'
    } else {
        Add-Failure "TEST fail current-write failure should preserve IMPLEMENT postimages and append one structured fallback, got: $fallbackAdvanceMessage"
    }

    $fallbackScriptBeforePipeReason = Get-Content -LiteralPath $scriptPath -Raw -Encoding utf8
    $fallbackReasonAnchor = '                    Reason = $_.Exception.Message'
    $fallbackReasonAnchorCount = [regex]::Matches($fallbackScriptBeforePipeReason, [regex]::Escape($fallbackReasonAnchor)).Count
    if ($fallbackReasonAnchorCount -ne 1) {
        Add-Failure ("isolated driver should expose one runtime failure reason anchor, found {0}" -f $fallbackReasonAnchorCount)
    } else {
        Write-Utf8Bom -Path $scriptPath -Content $fallbackScriptBeforePipeReason.Replace(
            $fallbackReasonAnchor,
            '                    Reason = ''fixture | '' + $_.Exception.Message'
        )
    }
    $fallbackSyncFailureMessages = @()
    try {
        foreach ($attempt in 1..2) {
            $fallbackCurrentHandle = [System.IO.File]::Open($fallbackCurrentPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try {
                $fallbackSyncFailureMessages += Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskFallback -VaultRoot $fallbackVault -ExpectedStage 'IMPLEMENT' -SyncOnly
            } finally {
                $fallbackCurrentHandle.Dispose()
            }
        }
    } finally {
        Write-Utf8Bom -Path $scriptPath -Content $fallbackScriptBeforePipeReason
    }
    $fallbackRowsAfterDuplicate = @((Read-RuntimeInbox -VaultRoot $fallbackVault).Rows | Where-Object { $_.Status -eq 'open' -and $_.TaskId -eq $taskFallback -and $_.Type -eq 'writeback-fallback' -and $_.Source -eq 'advance-stage' })
    $fallbackSyncRowsAfterDuplicate = @($fallbackRowsAfterDuplicate | Where-Object { ($_.Payload | ConvertFrom-Json).operation -eq 'sync' })
    $fallbackSyncPayloadAfterDuplicate = if ($fallbackSyncRowsAfterDuplicate.Count -eq 1) { $fallbackSyncRowsAfterDuplicate[0].Payload | ConvertFrom-Json } else { $null }
    if (@($fallbackSyncFailureMessages | Where-Object { $_ -match 'Runtime writeback failed' }).Count -eq 2 -and
        $fallbackRowsAfterDuplicate.Count -eq 2 -and
        $fallbackSyncRowsAfterDuplicate.Count -eq 1 -and
        $null -ne $fallbackSyncPayloadAfterDuplicate -and
        $fallbackSyncPayloadAfterDuplicate.reason.Contains([string][char]0xFF5C)) {
        Add-Check 'two identical runtime failures containing a pipe retain one canonical sync fallback while preserving the distinct advance fallback'
    } else {
        Add-Failure 'identical runtime failures containing a pipe should deduplicate the canonical open fallback payload'
    }

    $fallbackInboxPath = $fallbackInbox.Path
    $fallbackInboxHandle = [System.IO.File]::Open($fallbackInboxPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $fallbackClearMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskFallback -VaultRoot $fallbackVault -ExpectedStage 'IMPLEMENT' -SyncOnly
    } finally {
        $fallbackInboxHandle.Dispose()
    }
    $fallbackRowsAfterClearFailure = @((Read-RuntimeInbox -VaultRoot $fallbackVault).Rows | Where-Object { $_.Status -eq 'open' -and $_.TaskId -eq $taskFallback -and $_.Type -eq 'writeback-fallback' -and $_.Source -eq 'advance-stage' })
    if ($fallbackClearMessage -match 'fallback clear failed' -and
        $fallbackClearMessage -match 'SyncOnly' -and
        $fallbackRowsAfterClearFailure.Count -eq 2) {
        Add-Check 'SyncOnly clear failure is nonzero, preserves the exact open fallbacks, and prints a replay command'
    } else {
        Add-Failure "fallback clear failure should remain replayable, got: $fallbackClearMessage"
    }

    $fallbackSyncOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskFallback -VaultRoot $fallbackVault -ExpectedStage 'IMPLEMENT' -SyncOnly
    $fallbackRowsAfterRetry = @((Read-RuntimeInbox -VaultRoot $fallbackVault).Rows | Where-Object { $_.Status -eq 'open' -and $_.TaskId -eq $taskFallback -and $_.Type -eq 'writeback-fallback' -and $_.Source -eq 'advance-stage' })
    $fallbackInboxTextAfterRetry = Get-Content -LiteralPath $fallbackInboxPath -Raw -Encoding utf8
    $fallbackCurrentAfterRetry = Get-CanonicalCurrentTaskState -Path $fallbackCurrentPath
    if ($fallbackSyncOutcome.Succeeded -and
        $fallbackSyncOutcome.Output -eq 'SYNCED | IMPLEMENT | codex' -and
        $fallbackRowsAfterRetry.Count -eq 0 -and
        $fallbackInboxTextAfterRetry.Contains($fallbackSentinelLine) -and
        $fallbackCurrentAfterRetry.Stage -eq 'IMPLEMENT') {
        Add-Check 'ExpectedStage IMPLEMENT SyncOnly replay converges fail-derived runtime and consumes the matching fallback'
    } else {
        Add-Failure ("ExpectedStage IMPLEMENT SyncOnly replay should converge current/index and clear the exact fallback: {0}" -f $(if ($fallbackSyncOutcome.Succeeded) { $fallbackSyncOutcome.Output } else { $fallbackSyncOutcome.Error }))
    }

    $freshFallbackImplementation = @'
### Run 2 · 2026-07-10 10:01 · runner: Codex
- changed: repair failed verification
- tests: targeted
- risks: none
- next: CODE_REVIEW
'@
    $fallbackPlanText = Get-Content -LiteralPath $fallbackPlanPath -Raw -Encoding utf8
    $fallbackPlanText = $fallbackPlanText.Replace('## Code Review', ($freshFallbackImplementation + "`r`n`r`n## Code Review"))
    Write-Utf8Bom -Path $fallbackPlanPath -Content $fallbackPlanText
    $fallbackInbox = Read-RuntimeInbox -VaultRoot $fallbackVault
    $fallbackOldStagePayload = [ordered]@{
        schema_version = 'writeback-fallback/v1'
        operation = 'advance'
        expected_stage = 'PLAN_REVIEW'
        failed_step = 'current-task'
        reason = 'stale stage marker'
    } | ConvertTo-Json -Compress
    $fallbackRowsWithOldStage = @($fallbackInbox.Rows | Where-Object { -not (Test-RuntimeInboxPlaceholderRow -Row $_) }) + [pscustomobject]@{
        CreatedAt = '2026-07-10 10:00:00'
        Source = 'advance-stage'
        TaskId = $taskFallback
        Type = 'writeback-fallback'
        Status = 'open'
        Summary = '[writeback-fallback] current-task'
        Payload = $fallbackOldStagePayload
    }
    Write-RuntimeInbox -InboxPath $fallbackInbox.Path -CreatedDate $fallbackInbox.CreatedDate -Rows $fallbackRowsWithOldStage
    $fallbackOrdinaryOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskFallback -VaultRoot $fallbackVault -ExpectedStage 'IMPLEMENT'
    $fallbackRowsAfterOrdinary = @((Read-RuntimeInbox -VaultRoot $fallbackVault).Rows | Where-Object { $_.Status -eq 'open' -and $_.TaskId -eq $taskFallback -and $_.Type -eq 'writeback-fallback' -and $_.Source -eq 'advance-stage' })
    $fallbackInboxTextAfterOrdinary = Get-Content -LiteralPath $fallbackInboxPath -Raw -Encoding utf8
    if ($fallbackOrdinaryOutcome.Succeeded -and
        $fallbackOrdinaryOutcome.Output -eq 'CODE_REVIEW | codex' -and
        $fallbackRowsAfterOrdinary.Count -eq 0 -and
        $fallbackInboxTextAfterOrdinary.Contains($fallbackSentinelLine)) {
        Add-Check 'successful ordinary advance clears covered same-task fallbacks from every old stage and preserves unrelated rows'
    } else {
        Add-Failure ("ordinary advance should clear all covered old-stage fallbacks: {0}" -f $(if ($fallbackOrdinaryOutcome.Succeeded) { $fallbackOrdinaryOutcome.Output } else { $fallbackOrdinaryOutcome.Error }))
    }

    $lateFallbackFixtureRoot = New-IsolatedRepoFixture -SourceRoot $SourceRoot
    $createdTaskDirs += $lateFallbackFixtureRoot
    $lateFallbackScriptPath = Join-Path $lateFallbackFixtureRoot 'scripts\advance-stage.ps1'
    $lateFallbackTaskBase = Join-Path $lateFallbackFixtureRoot 'docs\tasks'
    $lateFallbackVault = Join-Path $lateFallbackFixtureRoot '.assistant'
    $createdTaskDirs += $lateFallbackVault
    New-Item -ItemType Directory -Path (Join-Path $lateFallbackVault '运行时\tasks') -Force | Out-Null
    $taskLateFallback = 'lite-late-fallback-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskLateFallbackDir = Join-Path $lateFallbackTaskBase $taskLateFallback
    New-Item -ItemType Directory -Path $taskLateFallbackDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskLateFallbackDir 'plan.md') -Content (New-CanonicalTestPlan -TaskId $taskLateFallback)
    Write-Utf8Bom -Path (Join-Path $taskLateFallbackDir 'test.md') -Content (New-TestReport -Conclusion 'fail')
    $null = Invoke-AdvanceSuccess -ScriptPath $lateFallbackScriptPath -TaskId $taskLateFallback -VaultRoot $lateFallbackVault -ExpectedStage 'TEST' -SyncOnly -ActivateCurrent

    $lateFallbackReadyName = 'harness-lite-fallback-ready-' + [guid]::NewGuid().ToString('N')
    $lateFallbackReleaseName = 'harness-lite-fallback-release-' + [guid]::NewGuid().ToString('N')
    $lateFallbackReadyEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $lateFallbackReadyName)
    $lateFallbackReleaseEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $lateFallbackReleaseName)
    $lateFallbackSource = Get-Content -LiteralPath $lateFallbackScriptPath -Raw -Encoding utf8
    $lateFallbackAppendLines = @($lateFallbackSource -split '\r?\n' | Where-Object { $_ -match '\$appendError = Report-WritebackFallback -VaultRoot' })
    $lateFallbackLockAnchor = '$advanceMutex = Enter-LitePlanMutex -TaskId $TaskId'
    $lateFallbackProcess = $null
    $lateFallbackSyncProcess = $null
    $lateFallbackCurrentHandle = $null
    $lateFallbackReady = $false
    $lateFallbackSyncExited = $false
    $lateFallbackSyncExitCode = -1
    $lateFallbackSyncStdErr = ''
    $lateFallbackAdvanceExited = $false
    $lateFallbackAdvanceExitCode = -1
    $lateFallbackAdvanceStdErr = ''
    try {
        if ($lateFallbackAppendLines.Count -ne 1 -or -not $lateFallbackSource.Contains($lateFallbackLockAnchor)) {
            Add-Failure 'isolated driver should expose one fallback append and task-lock anchor'
        } else {
            $lateFallbackAppendLine = $lateFallbackAppendLines[0]
            $lateFallbackIndent = [regex]::Match($lateFallbackAppendLine, '^\s*').Value
            $lateFallbackBarrier = @'
$readyEvent = [System.Threading.EventWaitHandle]::OpenExisting('__READY_EVENT__')
try { [void]$readyEvent.Set() } finally { $readyEvent.Dispose() }
$releaseEvent = [System.Threading.EventWaitHandle]::OpenExisting('__RELEASE_EVENT__')
try {
    if (-not $releaseEvent.WaitOne(15000)) {
        throw 'fallback fixture release timed out.'
    }
} finally {
    $releaseEvent.Dispose()
}
'@
            $lateFallbackBarrier = (($lateFallbackBarrier -split '\r?\n') | ForEach-Object { $lateFallbackIndent + $_ }) -join "`r`n"
            $lateFallbackBarrier = $lateFallbackBarrier.Replace('__READY_EVENT__', $lateFallbackReadyName).Replace('__RELEASE_EVENT__', $lateFallbackReleaseName)
            $lateFallbackSource = $lateFallbackSource.Replace($lateFallbackAppendLine, ($lateFallbackBarrier + "`r`n" + $lateFallbackAppendLine))
            $lateFallbackSource = $lateFallbackSource.Replace(
                $lateFallbackLockAnchor,
                '$advanceMutex = Enter-LitePlanMutex -TaskId $TaskId -TimeoutMilliseconds $(if ($SyncOnly.IsPresent) { 0 } else { 5000 })'
            )
            Write-Utf8Bom -Path $lateFallbackScriptPath -Content $lateFallbackSource

            $lateFallbackCurrentPath = Join-Path $lateFallbackVault '运行时\当前任务.md'
            $lateFallbackCurrentHandle = [System.IO.File]::Open($lateFallbackCurrentPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $lateFallbackProcess = Start-AdvanceProcess -ScriptPath $lateFallbackScriptPath -TaskId $taskLateFallback -VaultRoot $lateFallbackVault -ExpectedStage 'TEST'
            $lateFallbackReady = $lateFallbackReadyEvent.WaitOne(15000)
            if ($lateFallbackReady) {
                $lateFallbackCurrentHandle.Dispose()
                $lateFallbackCurrentHandle = $null
                $lateFallbackSyncProcess = Start-AdvanceProcess -ScriptPath $lateFallbackScriptPath -TaskId $taskLateFallback -VaultRoot $lateFallbackVault -ExpectedStage 'IMPLEMENT' -Tool '' -SyncOnly
                $lateFallbackSyncExited = $lateFallbackSyncProcess.Process.WaitForExit(15000)
                if ($lateFallbackSyncExited) {
                    $lateFallbackSyncExitCode = $lateFallbackSyncProcess.Process.ExitCode
                    $lateFallbackSyncStdErr = $lateFallbackSyncProcess.StdErr.Result
                }
            }
            [void]$lateFallbackReleaseEvent.Set()
            $lateFallbackAdvanceExited = $lateFallbackProcess.Process.WaitForExit(30000)
            if ($lateFallbackAdvanceExited) {
                $lateFallbackAdvanceExitCode = $lateFallbackProcess.Process.ExitCode
                $lateFallbackAdvanceStdErr = $lateFallbackProcess.StdErr.Result
            }
        }
    } finally {
        [void]$lateFallbackReleaseEvent.Set()
        if ($null -ne $lateFallbackCurrentHandle) { $lateFallbackCurrentHandle.Dispose() }
        foreach ($processState in @($lateFallbackSyncProcess, $lateFallbackProcess)) {
            if ($null -eq $processState) { continue }
            if (-not $processState.Process.HasExited) {
                $processState.Process.Kill()
                $processState.Process.WaitForExit()
            }
            $processState.Process.Dispose()
        }
        $lateFallbackReadyEvent.Dispose()
        $lateFallbackReleaseEvent.Dispose()
    }

    $lateFallbackRowsBeforeReplay = @((Read-RuntimeInbox -VaultRoot $lateFallbackVault).Rows | Where-Object { $_.Status -eq 'open' -and $_.TaskId -eq $taskLateFallback -and $_.Type -eq 'writeback-fallback' -and $_.Source -eq 'advance-stage' })
    $lateFallbackReplay = Invoke-AdvanceOutcome -ScriptPath $lateFallbackScriptPath -TaskId $taskLateFallback -VaultRoot $lateFallbackVault -ExpectedStage 'IMPLEMENT' -SyncOnly
    $lateFallbackRowsAfterReplay = @((Read-RuntimeInbox -VaultRoot $lateFallbackVault).Rows | Where-Object { $_.Status -eq 'open' -and $_.TaskId -eq $taskLateFallback -and $_.Type -eq 'writeback-fallback' -and $_.Source -eq 'advance-stage' })
    if ($lateFallbackReady -and
        $lateFallbackSyncExited -and
        $lateFallbackSyncExitCode -ne 0 -and
        $lateFallbackSyncStdErr -match 'Timed out waiting for task plan lock' -and
        $lateFallbackAdvanceExited -and
        $lateFallbackAdvanceExitCode -ne 0 -and
        $lateFallbackAdvanceStdErr -match 'Runtime writeback failed' -and
        $lateFallbackRowsBeforeReplay.Count -eq 1 -and
        $lateFallbackReplay.Succeeded -and
        $lateFallbackRowsAfterReplay.Count -eq 0) {
        Add-Check 'runtime failure appends fallback under the task lock before a concurrent SyncOnly can overtake it'
    } else {
        Add-Failure ("late fallback race should serialize SyncOnly until append completes: ready={0}; syncExit={1}; syncErr={2}; advanceExit={3}; advanceErr={4}; rows={5}->{6}; replay={7}" -f $lateFallbackReady, $lateFallbackSyncExitCode, $lateFallbackSyncStdErr, $lateFallbackAdvanceExitCode, $lateFallbackAdvanceStdErr, $lateFallbackRowsBeforeReplay.Count, $lateFallbackRowsAfterReplay.Count, $(if ($lateFallbackReplay.Succeeded) { $lateFallbackReplay.Output } else { $lateFallbackReplay.Error }))
    }

    $appendFailureVault = $vaultRoot
    Remove-DirectoryWithRetry -Path $appendFailureVault
    $createdTaskDirs += $appendFailureVault
    New-Item -ItemType Directory -Path (Join-Path $appendFailureVault '运行时\tasks') -Force | Out-Null
    $taskAppendFailure = 'lite-append-failure-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskAppendFailureDir = Join-Path $taskBase $taskAppendFailure
    $createdTaskDirs += $taskAppendFailureDir
    New-Item -ItemType Directory -Path $taskAppendFailureDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskAppendFailureDir 'plan.md') -Content (New-PlanContent -TaskId $taskAppendFailure -Stage 'PLAN' -Tool 'codex')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskAppendFailure -VaultRoot $appendFailureVault -ExpectedStage 'PLAN' -SyncOnly -ActivateCurrent
    $appendFailureCurrentPath = Join-Path $appendFailureVault '运行时\当前任务.md'
    $appendFailureInboxPath = Join-Path $appendFailureVault '运行时\收件箱.md'
    New-Item -ItemType Directory -Path $appendFailureInboxPath -Force | Out-Null
    $appendFailurePlanHash = (Get-FileHash -LiteralPath (Join-Path $taskAppendFailureDir 'plan.md') -Algorithm SHA256).Hash
    $appendFailureCurrentHash = (Get-FileHash -LiteralPath $appendFailureCurrentPath -Algorithm SHA256).Hash
    $appendFailureProcess = Start-AdvanceProcess -ScriptPath $scriptPath -TaskId $taskAppendFailure -VaultRoot $appendFailureVault -ExpectedStage 'PLAN'
    $appendFailureProcess.Process.WaitForExit()
    $appendFailureStdOut = $appendFailureProcess.StdOut.Result
    $appendFailureStdErr = $appendFailureProcess.StdErr.Result
    if ($appendFailureProcess.Process.ExitCode -ne 0 -and
        $appendFailureStdErr -match 'runtime inbox is not a file' -and
        $appendFailureStdErr -notmatch 'Replay:' -and
        (Get-FileHash -LiteralPath (Join-Path $taskAppendFailureDir 'plan.md') -Algorithm SHA256).Hash -eq $appendFailurePlanHash -and
        (Get-FileHash -LiteralPath $appendFailureCurrentPath -Algorithm SHA256).Hash -eq $appendFailureCurrentHash -and
        $appendFailureStdOut -notmatch 'PLAN_REVIEW \| codex') {
        Add-Check 'invalid inbox type fails at canonical vault preflight without plan/runtime mutation or misleading replay'
    } else {
        Add-Failure ("invalid inbox type should fail before transition or fallback handling: exit={0}; stdout={1}; stderr={2}" -f $appendFailureProcess.Process.ExitCode, $appendFailureStdOut, $appendFailureStdErr)
    }
    $appendFailureProcess.Process.Dispose()
    Remove-Item -LiteralPath $appendFailureInboxPath -Recurse -Force

    $caseVariantFrontmatterCases = @(
        [pscustomobject]@{ Name = 'upper-task-id'; Stage = 'PLAN'; Tool = 'codex'; Error = 'does not match'; UpperTaskId = $true }
        [pscustomobject]@{ Name = 'lower-stage'; Stage = 'plan'; Tool = 'codex'; Error = 'Unsupported stage'; UpperTaskId = $false }
        [pscustomobject]@{ Name = 'upper-tool'; Stage = 'PLAN'; Tool = 'CODEX'; Error = 'Unsupported plan tool'; UpperTaskId = $false }
    )
    $caseVariantFrontmatterFailures = @()
    foreach ($case in $caseVariantFrontmatterCases) {
        $taskCaseVariant = 'lite-case-variant-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskCaseVariantDir = Join-Path $taskBase $taskCaseVariant
        $createdTaskDirs += $taskCaseVariantDir
        New-Item -ItemType Directory -Path $taskCaseVariantDir -Force | Out-Null
        $caseVariantPlanPath = Join-Path $taskCaseVariantDir 'plan.md'
        $caseVariantPlan = New-PlanContent -TaskId $taskCaseVariant -Stage $case.Stage -Tool $case.Tool
        if ($case.UpperTaskId) {
            $caseVariantPlan = $caseVariantPlan.Replace("task_id: $taskCaseVariant", "task_id: $($taskCaseVariant.ToUpperInvariant())")
        }
        Write-Utf8Bom -Path $caseVariantPlanPath -Content $caseVariantPlan
        $caseVariantPlanHash = (Get-FileHash -LiteralPath $caseVariantPlanPath -Algorithm SHA256).Hash
        $caseVariantCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
        $caseVariantCurrentHash = (Get-FileHash -LiteralPath $caseVariantCurrentPath -Algorithm SHA256).Hash
        $caseVariantMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskCaseVariant)
        $caseVariantMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskCaseVariant -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -SyncOnly -ActivateCurrent
        if ($caseVariantMessage -notmatch $case.Error -or
            (Get-FileHash -LiteralPath $caseVariantPlanPath -Algorithm SHA256).Hash -ne $caseVariantPlanHash -or
            (Get-FileHash -LiteralPath $caseVariantCurrentPath -Algorithm SHA256).Hash -ne $caseVariantCurrentHash -or
            (Test-Path -LiteralPath $caseVariantMirrorPath)) {
            $caseVariantFrontmatterFailures += $case.Name
        }
    }
    if ($caseVariantFrontmatterFailures.Count -eq 0) {
        Add-Check 'SyncOnly rejects case-variant task_id, stage, and tool values before plan or runtime writes'
    } else {
        Add-Failure ("case-variant frontmatter wrote or synchronized runtime state: {0}" -f ($caseVariantFrontmatterFailures -join ', '))
    }

    $taskMissingNextTool = "lite-missing-next-tool-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskMissingNextToolDir = Join-Path $taskBase $taskMissingNextTool
    $createdTaskDirs += $taskMissingNextToolDir
    New-Item -ItemType Directory -Path $taskMissingNextToolDir -Force | Out-Null
    $missingNextToolPlanPath = Join-Path $taskMissingNextToolDir 'plan.md'
    Write-Utf8Bom -Path $missingNextToolPlanPath -Content (New-PlanContent -TaskId $taskMissingNextTool -Stage 'PLAN' -Tool 'codex')
    $missingNextToolOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskMissingNextTool -VaultRoot $vaultRoot -ExpectedStage 'PLAN'
    $missingNextToolPlan = Get-Content -LiteralPath $missingNextToolPlanPath -Raw -Encoding utf8
    if ($missingNextToolOutcome.Succeeded -and
        $missingNextToolOutcome.Output -eq 'PLAN_REVIEW | codex' -and
        $missingNextToolPlan -match '(?m)^tool_profile:\s*harness-default-codex\s*$' -and
        $missingNextToolPlan -match '(?m)^model:\s*gpt-5\.5/xhigh\s*$') {
        Add-Check 'non-DONE transitions use the workflow-default tool/profile when CLI selection is absent'
    } else {
        Add-Failure ("non-DONE transition should resolve the workflow-default profile: {0}" -f $(if ($missingNextToolOutcome.Succeeded) { $missingNextToolOutcome.Output } else { $missingNextToolOutcome.Error }))
    }

    $taskNoConfirm = "lite-no-confirm-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskNoConfirmDir = Join-Path $taskBase $taskNoConfirm
    $createdTaskDirs += $taskNoConfirmDir
    New-Item -ItemType Directory -Path $taskNoConfirmDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskNoConfirmDir "plan.md") -Content (New-PlanContent -TaskId $taskNoConfirm -Stage "PLAN" -Tool "codex" -ConfirmationStatus "draft")
    $noConfirmMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskNoConfirm -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool "codex"
    if ($noConfirmMessage -match "PLAN requires explicit user confirmation") {
        Add-Check "PLAN gate requires explicit user confirmation"
    } else {
        Add-Failure "PLAN gate should block unconfirmed plans, got: $noConfirmMessage"
    }

    $taskContradictoryConfirm = 'lite-contradict-confirm-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskContradictoryConfirmDir = Join-Path $taskBase $taskContradictoryConfirm
    $createdTaskDirs += $taskContradictoryConfirmDir
    New-Item -ItemType Directory -Path $taskContradictoryConfirmDir -Force | Out-Null
    $contradictoryConfirmPlanPath = Join-Path $taskContradictoryConfirmDir 'plan.md'
    $contradictoryConfirmPlan = (New-PlanContent -TaskId $taskContradictoryConfirm -Stage 'PLAN' -Tool 'codex').Replace(
        '- status: confirmed',
        "- status: draft`r`n- status: confirmed"
    )
    Write-Utf8Bom -Path $contradictoryConfirmPlanPath -Content $contradictoryConfirmPlan
    $contradictoryConfirmPlanHash = (Get-FileHash -LiteralPath $contradictoryConfirmPlanPath -Algorithm SHA256).Hash
    $contradictoryConfirmMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskContradictoryConfirm)
    $contradictoryConfirmCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $contradictoryConfirmCurrentHash = (Get-FileHash -LiteralPath $contradictoryConfirmCurrentPath -Algorithm SHA256).Hash
    $contradictoryConfirmMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskContradictoryConfirm -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool 'codex'
    if ($contradictoryConfirmMessage -match 'exactly one case-exact top-level status line' -and
        (Get-FileHash -LiteralPath $contradictoryConfirmPlanPath -Algorithm SHA256).Hash -eq $contradictoryConfirmPlanHash -and
        (Get-FileHash -LiteralPath $contradictoryConfirmCurrentPath -Algorithm SHA256).Hash -eq $contradictoryConfirmCurrentHash -and
        -not (Test-Path -LiteralPath $contradictoryConfirmMirrorPath)) {
        Add-Check 'PLAN advance rejects contradictory confirmation before plan or runtime writes'
    } else {
        Add-Failure "contradictory confirmation should fail before plan/runtime writes, got: $contradictoryConfirmMessage"
    }

    $taskPostPlanDraft = 'lite-post-plan-draft-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskPostPlanDraftDir = Join-Path $taskBase $taskPostPlanDraft
    $createdTaskDirs += $taskPostPlanDraftDir
    New-Item -ItemType Directory -Path $taskPostPlanDraftDir -Force | Out-Null
    $postPlanDraftPath = Join-Path $taskPostPlanDraftDir 'plan.md'
    $postPlanDraftReview = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: IMPLEMENT
'@
    Write-Utf8Bom -Path $postPlanDraftPath -Content (New-PlanContent -TaskId $taskPostPlanDraft -Stage 'PLAN_REVIEW' -Tool 'codex' -ConfirmationStatus 'draft' -PlanReviewRuns $postPlanDraftReview)
    $postPlanDraftHash = (Get-FileHash -LiteralPath $postPlanDraftPath -Algorithm SHA256).Hash
    $postPlanDraftCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $postPlanDraftCurrentHash = (Get-FileHash -LiteralPath $postPlanDraftCurrentPath -Algorithm SHA256).Hash
    $postPlanDraftMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskPostPlanDraft)
    $postPlanDraftMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskPostPlanDraft -VaultRoot $vaultRoot -ExpectedStage 'PLAN_REVIEW' -Tool 'codex'
    if ($postPlanDraftMessage -match 'post-PLAN stages require User Confirmation status: confirmed' -and
        (Get-FileHash -LiteralPath $postPlanDraftPath -Algorithm SHA256).Hash -eq $postPlanDraftHash -and
        (Get-FileHash -LiteralPath $postPlanDraftCurrentPath -Algorithm SHA256).Hash -eq $postPlanDraftCurrentHash -and
        -not (Test-Path -LiteralPath $postPlanDraftMirrorPath)) {
        Add-Check 'PLAN_REVIEW advance rejects draft confirmation before plan or runtime writes'
    } else {
        Add-Failure "post-PLAN draft confirmation should fail before writes, got: $postPlanDraftMessage"
    }

    $hiddenAdvanceVectors = @(
        [pscustomobject]@{ Name = 'html-comment'; Open = '<!--'; Close = '-->' }
        [pscustomobject]@{ Name = 'tab-pseudo-close'; Open = "~~~text`r`n`t~~~"; Close = '~~~' }
    )
    $hiddenAdvanceFailures = @()
    foreach ($vector in $hiddenAdvanceVectors) {
        $taskHiddenConfirm = 'lite-hidden-confirm-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskHiddenConfirmDir = Join-Path $taskBase $taskHiddenConfirm
        $createdTaskDirs += $taskHiddenConfirmDir
        New-Item -ItemType Directory -Path $taskHiddenConfirmDir -Force | Out-Null
        $hiddenConfirmPlanPath = Join-Path $taskHiddenConfirmDir 'plan.md'
        $hiddenConfirmPlan = (New-PlanContent -TaskId $taskHiddenConfirm -Stage 'PLAN' -Tool 'codex').Replace(
            '# Sample Plan',
            "# Sample Plan`r`n$($vector.Open)"
        ).Replace(
            '## Plan Review',
            "$($vector.Close)`r`n## Plan Review"
        )
        Write-Utf8Bom -Path $hiddenConfirmPlanPath -Content $hiddenConfirmPlan
        $hiddenConfirmPlanHash = (Get-FileHash -LiteralPath $hiddenConfirmPlanPath -Algorithm SHA256).Hash
        $hiddenConfirmMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskHiddenConfirm)
        $hiddenConfirmCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
        $hiddenConfirmCurrentHash = (Get-FileHash -LiteralPath $hiddenConfirmCurrentPath -Algorithm SHA256).Hash
        $hiddenConfirmMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskHiddenConfirm -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool 'codex'
        if ($hiddenConfirmMessage -notmatch 'validate-lite-artifacts\.ps1 failed' -or
            (Get-FileHash -LiteralPath $hiddenConfirmPlanPath -Algorithm SHA256).Hash -ne $hiddenConfirmPlanHash -or
            (Get-FileHash -LiteralPath $hiddenConfirmCurrentPath -Algorithm SHA256).Hash -ne $hiddenConfirmCurrentHash -or
            (Test-Path -LiteralPath $hiddenConfirmMirrorPath)) {
            $hiddenAdvanceFailures += $vector.Name
        }
    }
    if ($hiddenAdvanceFailures.Count -eq 0) {
        Add-Check 'PLAN advance rejects hidden confirmation vectors before plan or runtime writes'
    } else {
        Add-Failure ("hidden confirmation vectors wrote or advanced: {0}" -f ($hiddenAdvanceFailures -join ', '))
    }

    $taskHiddenClarification = 'lite-hidden-clarification-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskHiddenClarificationDir = Join-Path $taskBase $taskHiddenClarification
    $createdTaskDirs += $taskHiddenClarificationDir
    New-Item -ItemType Directory -Path $taskHiddenClarificationDir -Force | Out-Null
    $hiddenClarificationPlanPath = Join-Path $taskHiddenClarificationDir 'plan.md'
    $hiddenClarificationPlan = [regex]::Replace(
        (New-PlanContent -TaskId $taskHiddenClarification -Stage 'PLAN' -Tool 'codex'),
        '(?ms)(^## Clarification\r?\n).*?(?=^## User Confirmation)',
        ('$1- [note](https://example.test/验收/非目标/受影响/回滚/ui:)' + "`r`n`r`n")
    )
    Write-Utf8Bom -Path $hiddenClarificationPlanPath -Content $hiddenClarificationPlan
    $hiddenClarificationPlanHash = (Get-FileHash -LiteralPath $hiddenClarificationPlanPath -Algorithm SHA256).Hash
    $hiddenClarificationMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskHiddenClarification)
    $hiddenClarificationCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $hiddenClarificationCurrentHash = (Get-FileHash -LiteralPath $hiddenClarificationCurrentPath -Algorithm SHA256).Hash
    $hiddenClarificationMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskHiddenClarification -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool 'codex'
    if ($hiddenClarificationMessage -match 'validate-lite-artifacts\.ps1 failed' -and
        (Get-FileHash -LiteralPath $hiddenClarificationPlanPath -Algorithm SHA256).Hash -eq $hiddenClarificationPlanHash -and
        (Get-FileHash -LiteralPath $hiddenClarificationCurrentPath -Algorithm SHA256).Hash -eq $hiddenClarificationCurrentHash -and
        -not (Test-Path -LiteralPath $hiddenClarificationMirrorPath)) {
        Add-Check 'PLAN advance ignores Clarification tokens hidden in link metadata before plan or runtime writes'
    } else {
        Add-Failure "hidden Clarification evidence should fail before plan/runtime writes, got: $hiddenClarificationMessage"
    }

    $taskInterruptedClarification = 'lite-interrupted-clarification-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInterruptedClarificationDir = Join-Path $taskBase $taskInterruptedClarification
    $createdTaskDirs += $taskInterruptedClarificationDir
    New-Item -ItemType Directory -Path $taskInterruptedClarificationDir -Force | Out-Null
    $interruptedClarificationPlanPath = Join-Path $taskInterruptedClarificationDir 'plan.md'
    $interruptedClarificationPlan = (New-PlanContent -TaskId $taskInterruptedClarification -Stage 'PLAN' -Tool 'codex').Replace(
        '- 验收标准: 命令可以推进到下一阶段。',
        "- 验收标准:`r`n### unrelated`r`n  - payload-after-heading"
    )
    Write-Utf8Bom -Path $interruptedClarificationPlanPath -Content $interruptedClarificationPlan
    $interruptedClarificationPlanHash = (Get-FileHash -LiteralPath $interruptedClarificationPlanPath -Algorithm SHA256).Hash
    $interruptedClarificationCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $interruptedClarificationCurrentHash = (Get-FileHash -LiteralPath $interruptedClarificationCurrentPath -Algorithm SHA256).Hash
    $interruptedClarificationMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskInterruptedClarification)
    $interruptedClarificationMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskInterruptedClarification -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool 'codex'
    if ($interruptedClarificationMessage -match 'validate-lite-artifacts\.ps1 failed' -and
        (Get-FileHash -LiteralPath $interruptedClarificationPlanPath -Algorithm SHA256).Hash -eq $interruptedClarificationPlanHash -and
        (Get-FileHash -LiteralPath $interruptedClarificationCurrentPath -Algorithm SHA256).Hash -eq $interruptedClarificationCurrentHash -and
        -not (Test-Path -LiteralPath $interruptedClarificationMirrorPath)) {
        Add-Check 'PLAN advance rejects a Clarification block value interrupted by another Markdown block'
    } else {
        Add-Failure "interrupted Clarification should fail before writes, got: $interruptedClarificationMessage"
    }

    $reviewAdvanceVectors = @(
        [pscustomobject]@{ Name = 'hidden-run'; Runs = @'
~~~text
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: IMPLEMENT
~~~
'@
        }
        [pscustomobject]@{ Name = 'markdown-next'; Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: [](https://example.test/hidden)
'@
        }
    )
    $reviewAdvanceFailures = @()
    foreach ($vector in $reviewAdvanceVectors) {
        $taskHiddenReview = 'lite-hidden-review-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskHiddenReviewDir = Join-Path $taskBase $taskHiddenReview
        $createdTaskDirs += $taskHiddenReviewDir
        New-Item -ItemType Directory -Path $taskHiddenReviewDir -Force | Out-Null
        $hiddenReviewPlanPath = Join-Path $taskHiddenReviewDir 'plan.md'
        Write-Utf8Bom -Path $hiddenReviewPlanPath -Content (New-PlanContent -TaskId $taskHiddenReview -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $vector.Runs)
        $hiddenReviewPlanHash = (Get-FileHash -LiteralPath $hiddenReviewPlanPath -Algorithm SHA256).Hash
        $hiddenReviewMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskHiddenReview)
        $hiddenReviewCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
        $hiddenReviewCurrentHash = (Get-FileHash -LiteralPath $hiddenReviewCurrentPath -Algorithm SHA256).Hash
        $hiddenReviewMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskHiddenReview -VaultRoot $vaultRoot -ExpectedStage 'PLAN_REVIEW' -Tool 'codex'
        if ($hiddenReviewMessage -notmatch 'validate-lite-artifacts\.ps1 failed|PLAN_REVIEW requires latest verdict' -or
            (Get-FileHash -LiteralPath $hiddenReviewPlanPath -Algorithm SHA256).Hash -ne $hiddenReviewPlanHash -or
            (Get-FileHash -LiteralPath $hiddenReviewCurrentPath -Algorithm SHA256).Hash -ne $hiddenReviewCurrentHash -or
            (Test-Path -LiteralPath $hiddenReviewMirrorPath)) {
            $reviewAdvanceFailures += $vector.Name
        }
    }
    if ($reviewAdvanceFailures.Count -eq 0) {
        Add-Check 'PLAN_REVIEW advance rejects hidden or Markdown-only review evidence before writes'
    } else {
        Add-Failure ("review evidence vectors advanced or wrote state: {0}" -f ($reviewAdvanceFailures -join ', '))
    }

    $taskInterruptedImplementation = 'lite-interrupted-implementation-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInterruptedImplementationDir = Join-Path $taskBase $taskInterruptedImplementation
    $createdTaskDirs += $taskInterruptedImplementationDir
    New-Item -ItemType Directory -Path $taskInterruptedImplementationDir -Force | Out-Null
    $interruptedImplementationPlanPath = Join-Path $taskInterruptedImplementationDir 'plan.md'
    $interruptedImplementation = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- changed:
-`tshadow:
  - payload-from-sibling
- tests: targeted
- risks: none
- next: return to CODE_REVIEW
"@
    Write-Utf8Bom -Path $interruptedImplementationPlanPath -Content (New-PlanContent -TaskId $taskInterruptedImplementation -Stage 'IMPLEMENT' -Tool 'codex' -ImplementationRuns $interruptedImplementation)
    $interruptedImplementationPlanHash = (Get-FileHash -LiteralPath $interruptedImplementationPlanPath -Algorithm SHA256).Hash
    $interruptedImplementationCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $interruptedImplementationCurrentHash = (Get-FileHash -LiteralPath $interruptedImplementationCurrentPath -Algorithm SHA256).Hash
    $interruptedImplementationMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskInterruptedImplementation)
    $interruptedImplementationMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskInterruptedImplementation -VaultRoot $vaultRoot -ExpectedStage 'IMPLEMENT' -Tool 'codex'
    if ($interruptedImplementationMessage -match 'validate-lite-artifacts\.ps1 failed' -and
        (Get-FileHash -LiteralPath $interruptedImplementationPlanPath -Algorithm SHA256).Hash -eq $interruptedImplementationPlanHash -and
        (Get-FileHash -LiteralPath $interruptedImplementationCurrentPath -Algorithm SHA256).Hash -eq $interruptedImplementationCurrentHash -and
        -not (Test-Path -LiteralPath $interruptedImplementationMirrorPath)) {
        Add-Check 'IMPLEMENT advance rejects a block field value interrupted by a sibling item'
    } else {
        Add-Failure "interrupted Implementation field should fail before writes, got: $interruptedImplementationMessage"
    }

    $taskImplementStale = "lite-implement-stale-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskImplementStaleDir = Join-Path $taskBase $taskImplementStale
    $createdTaskDirs += $taskImplementStaleDir
    New-Item -ItemType Directory -Path $taskImplementStaleDir -Force | Out-Null
    $staleImplementation = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- changed: scripts/advance-stage.ps1
- tests: none
- risks: none
- next: 交给 CODE_REVIEW
"@
    $staleReview = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: revise
- findings:
  - P1: 需要补新实现证据
- next: 回 IMPLEMENT
"@
    Write-Utf8Bom -Path (Join-Path $taskImplementStaleDir "plan.md") -Content (New-PlanContent -TaskId $taskImplementStale -Stage "IMPLEMENT" -Tool "codex" -ImplementationRuns $staleImplementation -CodeReviewRuns $staleReview)
    $staleImplementMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskImplementStale -VaultRoot $vaultRoot -ExpectedStage 'IMPLEMENT' -Tool "claudecode"
    if ($staleImplementMessage -match "fresh Implementation Notes run after CODE_REVIEW revise" -or
        $staleImplementMessage -match "requires a fresh Implementation Notes run") {
        Add-Check "IMPLEMENT gate rejects stale evidence after CODE_REVIEW revise"
    } else {
        Add-Failure "IMPLEMENT gate should require fresh evidence after revise, got: $staleImplementMessage"
    }

    $taskImplementFresh = "lite-implement-fresh-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskImplementFreshDir = Join-Path $taskBase $taskImplementFresh
    $createdTaskDirs += $taskImplementFreshDir
    New-Item -ItemType Directory -Path $taskImplementFreshDir -Force | Out-Null
    $freshImplementation = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- changed: 初始实现
- tests: none
- risks: none
- next: 交给 CODE_REVIEW

### Run 2 · 2026-04-09 11:00 · runner: Codex
- changed: 根据 review 修补实现
- tests: pwsh -File tests/verify-workflow-contracts.ps1
- risks: none
- next: 交给 CODE_REVIEW
"@
    Write-Utf8Bom -Path (Join-Path $taskImplementFreshDir "plan.md") -Content (New-PlanContent -TaskId $taskImplementFresh -Stage "IMPLEMENT" -Tool "codex" -ImplementationRuns $freshImplementation -CodeReviewRuns $staleReview)
    $freshImplementAdvance = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskImplementFresh -VaultRoot $vaultRoot -ExpectedStage 'IMPLEMENT' -Tool "claudecode"
    if ($freshImplementAdvance -eq "CODE_REVIEW | claudecode") {
        Add-Check "IMPLEMENT gate accepts fresh evidence and allows tool switching"
    } else {
        Add-Failure "IMPLEMENT success case should advance to CODE_REVIEW"
    }

    $taskImplementSameMinute = "lite-implement-same-minute-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskImplementSameMinuteDir = Join-Path $taskBase $taskImplementSameMinute
    $createdTaskDirs += $taskImplementSameMinuteDir
    New-Item -ItemType Directory -Path $taskImplementSameMinuteDir -Force | Out-Null
    $sameMinuteImplementation = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- changed: 同分钟回修
- tests: targeted
- risks: none
- next: 交给 CODE_REVIEW
"@
    Write-Utf8Bom -Path (Join-Path $taskImplementSameMinuteDir "plan.md") -Content (New-PlanContent -TaskId $taskImplementSameMinute -Stage "IMPLEMENT" -Tool "codex" -ImplementationRuns $sameMinuteImplementation -CodeReviewRuns $staleReview)
    $sameMinuteAdvance = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskImplementSameMinute -VaultRoot $vaultRoot -ExpectedStage 'IMPLEMENT' -Tool "claudecode"
    if ($sameMinuteAdvance -eq "CODE_REVIEW | claudecode") {
        Add-Check "IMPLEMENT gate accepts same-minute follow-up evidence"
    } else {
        Add-Failure "IMPLEMENT same-minute evidence should advance to CODE_REVIEW"
    }

    $taskTestMissingHandoff = "lite-test-no-handoff-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskTestMissingHandoffDir = Join-Path $taskBase $taskTestMissingHandoff
    $createdTaskDirs += $taskTestMissingHandoffDir
    New-Item -ItemType Directory -Path $taskTestMissingHandoffDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskTestMissingHandoffDir "plan.md") -Content (New-CanonicalTestPlan -TaskId $taskTestMissingHandoff)
    Write-Utf8Bom -Path (Join-Path $taskTestMissingHandoffDir "test.md") -Content (New-TestReport -Conclusion "pass" -IncludeHandoff $false)
    $missingHandoffMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskTestMissingHandoff -VaultRoot $vaultRoot -ExpectedStage 'TEST'
    if ($missingHandoffMessage -match "TEST requires Handoff" -or
        $missingHandoffMessage -match "Handoff") {
        Add-Check "TEST gate requires a Handoff section"
    } else {
        Add-Failure "TEST gate should require Handoff, got: $missingHandoffMessage"
    }

    $taskTestHiddenValues = 'lite-test-hidden-values-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskTestHiddenValuesDir = Join-Path $taskBase $taskTestHiddenValues
    $createdTaskDirs += $taskTestHiddenValuesDir
    New-Item -ItemType Directory -Path $taskTestHiddenValuesDir -Force | Out-Null
    $testHiddenPlanPath = Join-Path $taskTestHiddenValuesDir 'plan.md'
    Write-Utf8Bom -Path $testHiddenPlanPath -Content (New-CanonicalTestPlan -TaskId $taskTestHiddenValues)
    $hiddenTestReport = (New-TestReport -Conclusion 'pass').Replace(
        '- command: `pwsh -NoProfile -File tests/verify-workflow-contracts.ps1`',
        '- command: [](https://example.test/hidden)'
    ).Replace(
        '- delivery: 提供当前 task 的验证结论。',
        '- delivery: [](https://example.test/hidden)'
    ).Replace(
        '- follow_up: none',
        '- follow_up: [](https://example.test/hidden)'
    )
    Write-Utf8Bom -Path (Join-Path $taskTestHiddenValuesDir 'test.md') -Content $hiddenTestReport
    $testHiddenPlanHash = (Get-FileHash -LiteralPath $testHiddenPlanPath -Algorithm SHA256).Hash
    $testHiddenMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskTestHiddenValues)
    $testHiddenCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $testHiddenCurrentHash = (Get-FileHash -LiteralPath $testHiddenCurrentPath -Algorithm SHA256).Hash
    $testHiddenMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskTestHiddenValues -VaultRoot $vaultRoot -ExpectedStage 'TEST'
    if ($testHiddenMessage -match 'validate-lite-artifacts\.ps1 failed' -and
        (Get-FileHash -LiteralPath $testHiddenPlanPath -Algorithm SHA256).Hash -eq $testHiddenPlanHash -and
        (Get-FileHash -LiteralPath $testHiddenCurrentPath -Algorithm SHA256).Hash -eq $testHiddenCurrentHash -and
        -not (Test-Path -LiteralPath $testHiddenMirrorPath)) {
        Add-Check 'TEST advance rejects Markdown-only machine values before plan or runtime writes'
    } else {
        Add-Failure "Markdown-only TEST values should fail before plan/runtime writes, got: $testHiddenMessage"
    }

    $taskTestHiddenConclusion = 'lite-test-hidden-conclusion-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskTestHiddenConclusionDir = Join-Path $taskBase $taskTestHiddenConclusion
    $createdTaskDirs += $taskTestHiddenConclusionDir
    New-Item -ItemType Directory -Path $taskTestHiddenConclusionDir -Force | Out-Null
    $hiddenConclusionPlanPath = Join-Path $taskTestHiddenConclusionDir 'plan.md'
    Write-Utf8Bom -Path $hiddenConclusionPlanPath -Content (New-CanonicalTestPlan -TaskId $taskTestHiddenConclusion)
    $hiddenConclusionPrefix = "~~~text`r`n## Conclusion`r`npass`r`n~~~`r`n<!--`r`n## Conclusion`r`npass`r`n-->`r`n"
    Write-Utf8Bom -Path (Join-Path $taskTestHiddenConclusionDir 'test.md') -Content ($hiddenConclusionPrefix + (New-TestReport -Conclusion 'fail'))
    $hiddenConclusionPlanHash = (Get-FileHash -LiteralPath $hiddenConclusionPlanPath -Algorithm SHA256).Hash
    $hiddenConclusionCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $hiddenConclusionCurrentHash = Get-FileFingerprint -Path $hiddenConclusionCurrentPath
    $hiddenConclusionMirrorPath = Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskTestHiddenConclusion)
    $hiddenConclusionOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskTestHiddenConclusion -VaultRoot $vaultRoot -ExpectedStage 'TEST'
    $hiddenConclusionPlanText = Get-Content -LiteralPath $hiddenConclusionPlanPath -Raw -Encoding utf8
    $hiddenConclusionMirror = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory (Join-Path $vaultRoot '运行时\tasks') | Where-Object { $_.TaskId -eq $taskTestHiddenConclusion })
    if ($hiddenConclusionOutcome.Succeeded -and
        $hiddenConclusionOutcome.Output -eq 'IMPLEMENT | codex' -and
        $hiddenConclusionPlanText -match '(?m)^stage:\s*IMPLEMENT\s*$' -and
        (Get-FileFingerprint -Path $hiddenConclusionCurrentPath) -ceq $hiddenConclusionCurrentHash -and
        $hiddenConclusionMirror.Count -eq 1 -and $hiddenConclusionMirror[0].Stage -eq 'IMPLEMENT') {
        Add-Check 'TEST routing uses the visible fail Conclusion and ignores hidden earlier pass values'
    } else {
        Add-Failure ("TEST routing should use the visible fail Conclusion and return to IMPLEMENT: {0}" -f $(if ($hiddenConclusionOutcome.Succeeded) { $hiddenConclusionOutcome.Output } else { $hiddenConclusionOutcome.Error }))
    }

    $taskTestPass = "lite-test-pass-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskTestPassDir = Join-Path $taskBase $taskTestPass
    $createdTaskDirs += $taskTestPassDir
    New-Item -ItemType Directory -Path $taskTestPassDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskTestPassDir "plan.md") -Content (New-CanonicalTestPlan -TaskId $taskTestPass)
    Write-Utf8Bom -Path (Join-Path $taskTestPassDir "test.md") -Content (New-TestReport -Conclusion "pass")
    $testAdvance = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskTestPass -VaultRoot $vaultRoot -ExpectedStage 'TEST'
    $testPlanText = Get-Content -LiteralPath (Join-Path $taskTestPassDir "plan.md") -Raw -Encoding utf8
    if ($testAdvance -eq "DONE | none" -and
        $testPlanText -match "(?m)^stage:\s*DONE\s*$" -and
        $testPlanText -match "(?m)^tool:\s*none\s*$") {
        Add-Check "TEST pass advances to DONE"
    } else {
        Add-Failure "TEST pass case should advance to DONE"
    }

    $taskValidatorBlocked = "lite-validator-blocked-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $taskValidatorBlockedDir = Join-Path $taskBase $taskValidatorBlocked
    $createdTaskDirs += $taskValidatorBlockedDir
    New-Item -ItemType Directory -Path $taskValidatorBlockedDir -Force | Out-Null
    $invalidPlan = (New-PlanContent -TaskId $taskValidatorBlocked -Stage "PLAN" -Tool "codex") -replace [regex]::Escape('- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-contracts.ps1`'), '- plain text verification'
    Write-Utf8Bom -Path (Join-Path $taskValidatorBlockedDir "plan.md") -Content $invalidPlan
    $validatorBlockedMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskValidatorBlocked -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool "codex"
    if ($validatorBlockedMessage -match "validate-lite-artifacts\.ps1 failed" -and $validatorBlockedMessage -match "Verification should contain backticked commands") {
        Add-Check "advance-stage blocks malformed artifacts through validate-lite-artifacts.ps1"
    } else {
        Add-Failure "advance-stage should surface validator failures before stage transition, got: $validatorBlockedMessage"
    }

    $taskCountBeforeTraversal = @(Get-ChildItem -LiteralPath $taskBase -Force).Count
    $mirrorCountBeforeTraversal = @(Get-ChildItem -LiteralPath (Join-Path $vaultRoot '运行时\tasks') -Force).Count
    $traversalMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId '..\..\outside' -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool 'codex'
    if ($traversalMessage -match 'TaskId must be a lowercase slug' -and
        @(Get-ChildItem -LiteralPath $taskBase -Force).Count -eq $taskCountBeforeTraversal -and
        @(Get-ChildItem -LiteralPath (Join-Path $vaultRoot '运行时\tasks') -Force).Count -eq $mirrorCountBeforeTraversal) {
        Add-Check 'TaskId traversal is rejected before workspace or vault writes'
    } else {
        Add-Failure "TaskId traversal should fail without writes, got: $traversalMessage"
    }

    $taskAgentHomeVault = 'lite-agent-home-vault-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskAgentHomeVaultDir = Join-Path $taskBase $taskAgentHomeVault
    $createdTaskDirs += $taskAgentHomeVaultDir
    New-Item -ItemType Directory -Path $taskAgentHomeVaultDir -Force | Out-Null
    $taskAgentHomeVaultPlan = Join-Path $taskAgentHomeVaultDir 'plan.md'
    Write-Utf8Bom -Path $taskAgentHomeVaultPlan -Content (New-PlanContent -TaskId $taskAgentHomeVault -Stage 'CODE_REVIEW' -Tool 'codex')
    $agentHomeProfile = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-agent-home-' + [guid]::NewGuid().ToString('N'))
    $agentHomeWorkspace = Join-Path $agentHomeProfile '.codex'
    $agentHomeRuntimeVault = Join-Path $agentHomeWorkspace '.assistant'
    $createdTaskDirs += $agentHomeProfile
    New-Item -ItemType Directory -Path $agentHomeProfile -Force | Out-Null
    $agentHomePlanHash = (Get-FileHash -LiteralPath $taskAgentHomeVaultPlan -Algorithm SHA256).Hash
    $savedUserProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $agentHomeProfile
        $agentHomeMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskAgentHomeVault -WorkspaceRoot $agentHomeWorkspace -VaultRoot $agentHomeRuntimeVault -ExpectedStage 'CODE_REVIEW' -SyncOnly -ActivateCurrent
    } finally {
        $env:USERPROFILE = $savedUserProfile
    }
    if ($agentHomeMessage -match '\[vault-layer-violation\]' -and
        (Get-FileHash -LiteralPath $taskAgentHomeVaultPlan -Algorithm SHA256).Hash -eq $agentHomePlanHash -and
        -not (Test-Path -LiteralPath $agentHomeRuntimeVault)) {
        Add-Check 'advance-stage rejects a first runtime write under a user-level agent home'
    } else {
        Add-Failure "advance-stage should reject user-level runtime roots before plan/runtime writes, got: $agentHomeMessage"
    }

    $taskRuntimeFile = 'lite-runtime-file-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskRuntimeFileDir = Join-Path $taskBase $taskRuntimeFile
    $createdTaskDirs += $taskRuntimeFileDir
    New-Item -ItemType Directory -Path $taskRuntimeFileDir -Force | Out-Null
    $taskRuntimeFilePlan = Join-Path $taskRuntimeFileDir 'plan.md'
    Write-Utf8Bom -Path $taskRuntimeFilePlan -Content (New-PlanContent -TaskId $taskRuntimeFile -Stage 'PLAN' -Tool 'codex')
    $runtimeFileWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-runtime-file-' + [guid]::NewGuid().ToString('N'))
    $runtimeFileVault = Join-Path $runtimeFileWorkspace '.assistant'
    $runtimeFilePath = Join-Path $runtimeFileVault '运行时'
    $createdTaskDirs += $runtimeFileWorkspace
    New-Item -ItemType Directory -Path $runtimeFileVault -Force | Out-Null
    Set-Content -LiteralPath $runtimeFilePath -Value 'must remain a file' -Encoding utf8
    $runtimeFilePlanHash = (Get-FileHash -LiteralPath $taskRuntimeFilePlan -Algorithm SHA256).Hash
    $runtimeFileHash = (Get-FileHash -LiteralPath $runtimeFilePath -Algorithm SHA256).Hash
    $runtimeFileMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskRuntimeFile -WorkspaceRoot $runtimeFileWorkspace -VaultRoot $runtimeFileVault -ExpectedStage 'PLAN' -Tool 'codex'
    if ($runtimeFileMessage -match 'runtime path is not a directory' -and
        (Get-FileHash -LiteralPath $taskRuntimeFilePlan -Algorithm SHA256).Hash -eq $runtimeFilePlanHash -and
        (Get-FileHash -LiteralPath $runtimeFilePath -Algorithm SHA256).Hash -eq $runtimeFileHash) {
        Add-Check 'advance-stage rejects a runtime file before plan or fallback writes'
    } else {
        Add-Failure "advance-stage should reject a runtime file before mutating plan/runtime state, got: $runtimeFileMessage"
    }

    $taskVaultJunction = 'lite-vault-junction-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskVaultJunctionDir = Join-Path $taskBase $taskVaultJunction
    $createdTaskDirs += $taskVaultJunctionDir
    New-Item -ItemType Directory -Path $taskVaultJunctionDir -Force | Out-Null
    $taskVaultJunctionPlan = Join-Path $taskVaultJunctionDir 'plan.md'
    Write-Utf8Bom -Path $taskVaultJunctionPlan -Content (New-PlanContent -TaskId $taskVaultJunction -Stage 'PLAN' -Tool 'codex')
    $vaultJunctionWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-vault-link-' + [guid]::NewGuid().ToString('N'))
    $vaultJunctionRoot = Join-Path $vaultJunctionWorkspace '.assistant'
    $vaultJunctionTarget = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-vault-target-' + [guid]::NewGuid().ToString('N'))
    $createdTaskDirs += @($vaultJunctionWorkspace, $vaultJunctionTarget)
    New-Item -ItemType Directory -Path $vaultJunctionRoot,$vaultJunctionTarget -Force | Out-Null
    $runtimeJunction = Join-Path $vaultJunctionRoot '运行时'
    New-Item -ItemType Junction -Path $runtimeJunction -Target $vaultJunctionTarget | Out-Null
    $vaultJunctionPlanHash = (Get-FileHash -LiteralPath $taskVaultJunctionPlan -Algorithm SHA256).Hash
    $vaultJunctionMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskVaultJunction -WorkspaceRoot $vaultJunctionWorkspace -VaultRoot $vaultJunctionRoot -ExpectedStage 'PLAN' -Tool 'codex'
    if ($vaultJunctionMessage -match 'reparse point' -and
        (Get-FileHash -LiteralPath $taskVaultJunctionPlan -Algorithm SHA256).Hash -eq $vaultJunctionPlanHash -and
        @(Get-ChildItem -LiteralPath $vaultJunctionTarget -Force).Count -eq 0) {
        Add-Check 'advance-stage rejects a vault runtime junction before plan or external writes'
    } else {
        Add-Failure "vault runtime junction should fail closed without writes, got: $vaultJunctionMessage"
    }
    Remove-Item -LiteralPath $runtimeJunction -Force

    $taskDuplicate = 'lite-duplicate-frontmatter-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskDuplicateDir = Join-Path $taskBase $taskDuplicate
    $createdTaskDirs += $taskDuplicateDir
    New-Item -ItemType Directory -Path $taskDuplicateDir -Force | Out-Null
    $duplicatePlan = (New-PlanContent -TaskId $taskDuplicate -Stage 'PLAN' -Tool 'codex') -replace "stage: PLAN", "stage: PLAN`r`nstage: TEST"
    $duplicatePlanPath = Join-Path $taskDuplicateDir 'plan.md'
    Write-Utf8Bom -Path $duplicatePlanPath -Content $duplicatePlan
    $duplicateHash = (Get-FileHash -LiteralPath $duplicatePlanPath -Algorithm SHA256).Hash
    $duplicateMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskDuplicate -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool 'codex'
    if ($duplicateMessage -match 'duplicate frontmatter field: stage' -and
        (Get-FileHash -LiteralPath $duplicatePlanPath -Algorithm SHA256).Hash -eq $duplicateHash) {
        Add-Check 'advance-stage and validator share duplicate frontmatter rejection'
    } else {
        Add-Failure "duplicate frontmatter should be rejected without mutation, got: $duplicateMessage"
    }

    $taskLatestRun = 'lite-latest-run-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskLatestRunDir = Join-Path $taskBase $taskLatestRun
    $createdTaskDirs += $taskLatestRunDir
    New-Item -ItemType Directory -Path $taskLatestRunDir -Force | Out-Null
    $latestRuns = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: IMPLEMENT

### Run 2 · 2026-04-09 10:01 · runner: Codex
- verdict: revise
- findings:
  - P1: latest run must control the transition
- next: PLAN
"@
    $latestPlan = (New-PlanContent -TaskId $taskLatestRun -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $latestRuns) -replace '## Plan Review', '##   Plan Review'
    Write-Utf8Bom -Path (Join-Path $taskLatestRunDir 'plan.md') -Content $latestPlan
    $latestAdvance = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskLatestRun -VaultRoot $vaultRoot -ExpectedStage 'PLAN_REVIEW' -Tool 'codex'
    $latestPlanText = Get-Content -LiteralPath (Join-Path $taskLatestRunDir 'plan.md') -Raw -Encoding utf8
    if ($latestAdvance -eq 'PLAN | codex' -and $latestPlanText -match '(?m)^stage:\s*PLAN\s*$') {
        Add-Check 'validator and advance share latest-run parsing with flexible section spacing'
    } else {
        Add-Failure "latest review run should return to PLAN, got: $latestAdvance"
    }

    $taskMalformedRun = 'lite-malformed-run-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMalformedRunDir = Join-Path $taskBase $taskMalformedRun
    $createdTaskDirs += $taskMalformedRunDir
    New-Item -ItemType Directory -Path $taskMalformedRunDir -Force | Out-Null
    $malformedRuns = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: IMPLEMENT

### Run 2 · malformed-time · runner: Codex
- verdict: revise
- findings:
  - P1: malformed latest run must block advancement
- next: PLAN
"@
    $malformedPlanPath = Join-Path $taskMalformedRunDir 'plan.md'
    Write-Utf8Bom -Path $malformedPlanPath -Content (New-PlanContent -TaskId $taskMalformedRun -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $malformedRuns)
    $malformedPlanHash = (Get-FileHash -LiteralPath $malformedPlanPath -Algorithm SHA256).Hash
    $malformedMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskMalformedRun -VaultRoot $vaultRoot -ExpectedStage 'PLAN_REVIEW' -Tool 'codex'
    $malformedPlanText = Get-Content -LiteralPath $malformedPlanPath -Raw -Encoding utf8
    if ($malformedMessage -match 'validate-lite-artifacts\.ps1 failed' -and
        (Get-FileHash -LiteralPath $malformedPlanPath -Algorithm SHA256).Hash -eq $malformedPlanHash -and
        $malformedPlanText -match '(?m)^stage:\s*PLAN_REVIEW\s*$') {
        Add-Check 'malformed latest Run blocks advancement without mutating plan.md'
    } else {
        Add-Failure "malformed latest Run should fail closed without stage mutation, got: $malformedMessage"
    }

    $taskConcurrent = 'lite-concurrent-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskConcurrentDir = Join-Path $taskBase $taskConcurrent
    $createdTaskDirs += $taskConcurrentDir
    New-Item -ItemType Directory -Path $taskConcurrentDir -Force | Out-Null
    $concurrentPlanPath = Join-Path $taskConcurrentDir 'plan.md'
    Write-Utf8Bom -Path $concurrentPlanPath -Content (New-PlanContent -TaskId $taskConcurrent -Stage 'PLAN' -Tool 'codex')
    $concurrentA = Start-AdvanceProcess -ScriptPath $scriptPath -TaskId $taskConcurrent -VaultRoot $vaultRoot -ExpectedStage 'PLAN'
    $concurrentB = Start-AdvanceProcess -ScriptPath $scriptPath -TaskId $taskConcurrent -VaultRoot $vaultRoot -ExpectedStage 'PLAN'
    $concurrentA.Process.WaitForExit()
    $concurrentB.Process.WaitForExit()
    $concurrentExitCodes = @($concurrentA.Process.ExitCode, $concurrentB.Process.ExitCode)
    $concurrentText = Get-Content -LiteralPath $concurrentPlanPath -Raw -Encoding utf8
    $concurrentTemps = @(Get-ChildItem -LiteralPath $taskConcurrentDir -Filter '.plan.md.*.tmp*' -Force -ErrorAction SilentlyContinue)
    if (@($concurrentExitCodes | Where-Object { $_ -eq 0 }).Count -eq 1 -and
        $concurrentText -match '(?m)^stage:\s*PLAN_REVIEW\s*$' -and
        $concurrentTemps.Count -eq 0) {
        Add-Check 'same-task concurrent advances serialize to one transition'
    } else {
        Add-Failure ("concurrent advances should yield one transition, exits={0}" -f ($concurrentExitCodes -join ','))
    }
    $concurrentA.Process.Dispose()
    $concurrentB.Process.Dispose()

    $runtimeTaskA = 'lite-runtime-a-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $runtimeTaskB = 'lite-runtime-b-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $runtimeTaskADir = Join-Path $taskBase $runtimeTaskA
    $runtimeTaskBDir = Join-Path $taskBase $runtimeTaskB
    $createdTaskDirs += @($runtimeTaskADir, $runtimeTaskBDir)
    New-Item -ItemType Directory -Path $runtimeTaskADir,$runtimeTaskBDir -Force | Out-Null
    $runtimePlanA = Join-Path $runtimeTaskADir 'plan.md'
    $runtimePlanB = Join-Path $runtimeTaskBDir 'plan.md'
    Write-Utf8Bom -Path $runtimePlanA -Content (New-PlanContent -TaskId $runtimeTaskA -Stage 'PLAN' -Tool 'codex')
    Write-Utf8Bom -Path $runtimePlanB -Content (New-PlanContent -TaskId $runtimeTaskB -Stage 'PLAN' -Tool 'codex')
    $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskPlanSuccess -VaultRoot $vaultRoot -ExpectedStage 'PLAN_REVIEW' -SyncOnly -ActivateCurrent
    $runtimeCurrentPath = Join-Path $vaultRoot '运行时\当前任务.md'
    $runtimeIndexPath = Join-Path $vaultRoot '运行时\恢复索引.md'
    $runtimeTasksPath = Join-Path $vaultRoot '运行时\tasks'
    $runtimeMirrorA = Join-Path $runtimeTasksPath ($runtimeTaskA + '.md')
    $runtimeMirrorB = Join-Path $runtimeTasksPath ($runtimeTaskB + '.md')
    $currentBeforeRuntimeLock = if (Test-Path -LiteralPath $runtimeCurrentPath) { Get-Content -LiteralPath $runtimeCurrentPath -Raw -Encoding utf8 } else { '' }
    $indexBeforeRuntimeLock = if (Test-Path -LiteralPath $runtimeIndexPath) { Get-Content -LiteralPath $runtimeIndexPath -Raw -Encoding utf8 } else { '' }
    $heldRuntimeMutex = Enter-CanonicalRuntimeMutex -VaultRoot $vaultRoot
    try {
        $runtimeAdvanceA = Start-AdvanceProcess -ScriptPath $scriptPath -TaskId $runtimeTaskA -VaultRoot $vaultRoot -ExpectedStage 'PLAN'
        $runtimeAdvanceB = Start-AdvanceProcess -ScriptPath $scriptPath -TaskId $runtimeTaskB -VaultRoot $vaultRoot -ExpectedStage 'PLAN'
        [void]$runtimeAdvanceA.Process.WaitForExit(1500)
        [void]$runtimeAdvanceB.Process.WaitForExit(1500)
        $blockedPlansUnchanged =
            (Get-Content -LiteralPath $runtimePlanA -Raw -Encoding utf8) -match '(?m)^stage:\s*PLAN\s*$' -and
            (Get-Content -LiteralPath $runtimePlanB -Raw -Encoding utf8) -match '(?m)^stage:\s*PLAN\s*$' -and
            -not (Test-Path -LiteralPath $runtimeMirrorA) -and
            -not (Test-Path -LiteralPath $runtimeMirrorB) -and
            $(if (Test-Path -LiteralPath $runtimeCurrentPath) { (Get-Content -LiteralPath $runtimeCurrentPath -Raw -Encoding utf8) -ceq $currentBeforeRuntimeLock } else { $currentBeforeRuntimeLock -eq '' }) -and
            $(if (Test-Path -LiteralPath $runtimeIndexPath) { (Get-Content -LiteralPath $runtimeIndexPath -Raw -Encoding utf8) -ceq $indexBeforeRuntimeLock } else { $indexBeforeRuntimeLock -eq '' })
    } finally {
        Exit-CanonicalRuntimeMutex -Mutex $heldRuntimeMutex
    }
    [void]$runtimeAdvanceA.Process.WaitForExit(30000)
    [void]$runtimeAdvanceB.Process.WaitForExit(30000)
    $runtimeAdvanceAOutput = $runtimeAdvanceA.StdOut.Result
    $runtimeAdvanceBOutput = $runtimeAdvanceB.StdOut.Result
    $runtimeAdvanceAError = $runtimeAdvanceA.StdErr.Result
    $runtimeAdvanceBError = $runtimeAdvanceB.StdErr.Result
    $canonicalRuntimeRecords = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory $runtimeTasksPath)
    $runtimeRecordA = @($canonicalRuntimeRecords | Where-Object { $_.TaskId -eq $runtimeTaskA })
    $runtimeRecordB = @($canonicalRuntimeRecords | Where-Object { $_.TaskId -eq $runtimeTaskB })
    $runtimeCurrent = Get-CanonicalCurrentTaskState -Path $runtimeCurrentPath
    $runtimeIndexText = Get-Content -LiteralPath $runtimeIndexPath -Raw -Encoding utf8
    $runtimeIndexCurrentMatch = [regex]::Match($runtimeIndexText, '(?m)^- task_id:\s*`([^`]+)`\s*$')
    if ($blockedPlansUnchanged -and
        $runtimeAdvanceA.Process.ExitCode -eq 0 -and
        $runtimeAdvanceB.Process.ExitCode -eq 0 -and
        $runtimeRecordA.Count -eq 1 -and $runtimeRecordA[0].IsValid -and
        $runtimeRecordB.Count -eq 1 -and $runtimeRecordB[0].IsValid -and
        $runtimeIndexCurrentMatch.Success -and
        $runtimeIndexCurrentMatch.Groups[1].Value -eq $runtimeCurrent.TaskId -and
        $runtimeCurrent.TaskId -eq $taskPlanSuccess) {
        Add-Check 'different-task background advances wait for the runtime mutex and leave active current/index consistent'
    } else {
        Add-Failure ("shared runtime mutex failed: blocked={0}; exits={1},{2}; current={3}; index={4}; stderr={5}|{6}; stdout={7}|{8}" -f $blockedPlansUnchanged, $runtimeAdvanceA.Process.ExitCode, $runtimeAdvanceB.Process.ExitCode, $runtimeCurrent.TaskId, $runtimeIndexCurrentMatch.Groups[1].Value, $runtimeAdvanceAError, $runtimeAdvanceBError, $runtimeAdvanceAOutput, $runtimeAdvanceBOutput)
    }
    $runtimeAdvanceA.Process.Dispose()
    $runtimeAdvanceB.Process.Dispose()

    $taskAtomic = 'lite-atomic-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskAtomicDir = Join-Path $taskBase $taskAtomic
    $createdTaskDirs += $taskAtomicDir
    New-Item -ItemType Directory -Path $taskAtomicDir -Force | Out-Null
    $atomicPlanPath = Join-Path $taskAtomicDir 'plan.md'
    Write-Utf8Bom -Path $atomicPlanPath -Content (New-PlanContent -TaskId $taskAtomic -Stage 'PLAN' -Tool 'codex')
    $atomicHash = (Get-FileHash -LiteralPath $atomicPlanPath -Algorithm SHA256).Hash
    $atomicHandle = [System.IO.File]::Open($atomicPlanPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $atomicMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskAtomic -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool 'codex'
    } finally {
        $atomicHandle.Dispose()
    }
    $atomicTemps = @(Get-ChildItem -LiteralPath $taskAtomicDir -Filter '.plan.md.*.tmp*' -Force -ErrorAction SilentlyContinue)
    if ((Get-FileHash -LiteralPath $atomicPlanPath -Algorithm SHA256).Hash -eq $atomicHash -and $atomicTemps.Count -eq 0) {
        Add-Check 'failed atomic replace preserves the original plan and cleans temp files'
    } else {
        Add-Failure "atomic replace failure should preserve plan, got: $atomicMessage"
    }

    $validatorRealPath = Join-Path (Split-Path -Parent $validatorPath) 'validate-lite-artifacts.real.ps1'
    Copy-Item -LiteralPath $validatorPath -Destination $validatorRealPath -Force
    try {
        $taskToctou = 'lite-toctou-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskToctouDir = Join-Path $taskBase $taskToctou
        $createdTaskDirs += $taskToctouDir
        New-Item -ItemType Directory -Path $taskToctouDir -Force | Out-Null
        $toctouPlanPath = Join-Path $taskToctouDir 'plan.md'
        Write-Utf8Bom -Path $toctouPlanPath -Content (New-PlanContent -TaskId $taskToctou -Stage 'PLAN' -Tool 'codex')
        $toctouWrapper = @'
[CmdletBinding()]
param([string]$TaskId, [string]$RepoRoot, [string]$WorkspaceRoot)
$runner = (Get-Process -Id $PID).Path
& $runner -NoProfile -File (Join-Path $PSScriptRoot 'validate-lite-artifacts.real.ps1') -TaskId $TaskId -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Add-Content -LiteralPath (Join-Path (Join-Path (Join-Path $WorkspaceRoot 'docs\tasks') $TaskId) 'plan.md') -Value "`r`n<!-- validator-race -->" -Encoding utf8
exit 0
'@
        Write-Utf8Bom -Path $validatorPath -Content $toctouWrapper
        $toctouMessage = Invoke-AdvanceFailure -ScriptPath $scriptPath -TaskId $taskToctou -VaultRoot $vaultRoot -ExpectedStage 'PLAN' -Tool 'codex'
        $toctouText = Get-Content -LiteralPath $toctouPlanPath -Raw -Encoding utf8
        if ($toctouMessage -match 'changed while validation was running' -and
            $toctouText -match 'validator-race' -and
            $toctouText -match '(?m)^stage:\s*PLAN\s*$') {
            Add-Check 'validator-time mutation is detected and never overwritten'
        } else {
            Add-Failure "TOCTOU mutation should be preserved and rejected, got: $toctouMessage"
        }

        $taskPredeleted = 'lite-predeleted-fail-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskPredeletedDir = Join-Path $taskBase $taskPredeleted
        $createdTaskDirs += $taskPredeletedDir
        New-Item -ItemType Directory -Path $taskPredeletedDir -Force | Out-Null
        $predeletedPlanPath = Join-Path $taskPredeletedDir 'plan.md'
        $predeletedTestPath = Join-Path $taskPredeletedDir 'test.md'
        Write-Utf8Bom -Path $predeletedPlanPath -Content (New-FailedReworkPlan -TaskId $taskPredeleted)
        $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskPredeleted -VaultRoot $vaultRoot -ExpectedStage 'IMPLEMENT' -SyncOnly
        $predeletedTemplatePath = Join-Path (Split-Path -Parent $validatorPath) 'predeleted-test-template.md'
        Write-Utf8Bom -Path $predeletedTemplatePath -Content (New-TestReport -Conclusion 'fail')
        $predeletedPaths = @(
            $predeletedPlanPath,
            (Join-Path $vaultRoot ("运行时\tasks\{0}.md" -f $taskPredeleted)),
            (Join-Path $vaultRoot '运行时\当前任务.md'),
            (Join-Path $vaultRoot '运行时\恢复索引.md'),
            (Join-Path $vaultRoot '运行时\收件箱.md')
        )
        $predeletedBefore = @($predeletedPaths | ForEach-Object { Get-FileFingerprint -Path $_ })
        $predeletedWrapper = @'
[CmdletBinding()]
param([string]$TaskId, [string]$RepoRoot, [string]$WorkspaceRoot)
$testPath = Join-Path (Join-Path (Join-Path (Join-Path $WorkspaceRoot 'docs') 'tasks') $TaskId) 'test.md'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'predeleted-test-template.md') -Destination $testPath -Force
$runner = (Get-Process -Id $PID).Path
& $runner -NoProfile -File (Join-Path $PSScriptRoot 'validate-lite-artifacts.real.ps1') -TaskId $TaskId -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
exit $LASTEXITCODE
'@
        Write-Utf8Bom -Path $validatorPath -Content $predeletedWrapper
        $predeletedOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskPredeleted -VaultRoot $vaultRoot -ExpectedStage 'IMPLEMENT'
        $predeletedAfter = @($predeletedPaths | ForEach-Object { Get-FileFingerprint -Path $_ })
        if (-not $predeletedOutcome.Succeeded -and
            $predeletedOutcome.Error -match 'test\.md|fail report|Missing' -and
            -not (Test-Path -LiteralPath $predeletedTestPath) -and
            (Test-FingerprintSequence -Before $predeletedBefore -After $predeletedAfter)) {
            Add-Check 'initial failed-rework state snapshots test.md before validator and rejects a pre-deleted report with zero writes'
        } else {
            Add-Failure ("initial failed-rework state should reject a pre-deleted report before validator can recreate it: {0}" -f $(if ($predeletedOutcome.Succeeded) { $predeletedOutcome.Output } else { $predeletedOutcome.Error }))
        }
        Remove-Item -LiteralPath $predeletedTemplatePath -Force -ErrorAction SilentlyContinue

        $taskTestToctou = 'lite-test-toctou-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskTestToctouDir = Join-Path $taskBase $taskTestToctou
        $createdTaskDirs += $taskTestToctouDir
        New-Item -ItemType Directory -Path $taskTestToctouDir -Force | Out-Null
        $testToctouPlanPath = Join-Path $taskTestToctouDir 'plan.md'
        $testToctouReportPath = Join-Path $taskTestToctouDir 'test.md'
        Write-Utf8Bom -Path $testToctouPlanPath -Content (New-FailedReworkPlan -TaskId $taskTestToctou)
        Write-Utf8Bom -Path $testToctouReportPath -Content (New-TestReport -Conclusion 'fail')
        $null = Invoke-AdvanceSuccess -ScriptPath $scriptPath -TaskId $taskTestToctou -VaultRoot $vaultRoot -ExpectedStage 'IMPLEMENT' -SyncOnly
        $testToctouMarkerPath = Join-Path $vaultRoot 'test-ab-a.marker'
        $testToctouReportFingerprint = Get-FileFingerprint -Path $testToctouReportPath
        $testToctouWrapper = @'
[CmdletBinding()]
param([string]$TaskId, [string]$RepoRoot, [string]$WorkspaceRoot)
$testPath = Join-Path (Join-Path (Join-Path (Join-Path $WorkspaceRoot 'docs') 'tasks') $TaskId) 'test.md'
$originalBytes = [System.IO.File]::ReadAllBytes($testPath)
$testText = Get-Content -LiteralPath $testPath -Raw -Encoding utf8
$testText = $testText.Replace('- command: `pwsh -NoProfile -File tests/verify-workflow-contracts.ps1`', '- command: `pwsh -NoProfile -File tests/verify-workflow-contracts.ps1 -Changed`')
$mutationStatus = 'blocked'
try {
    [System.IO.File]::WriteAllText($testPath, $testText, [System.Text.UTF8Encoding]::new($true))
    $mutationStatus = 'mutated'
} catch [System.IO.IOException] {
}
$runner = (Get-Process -Id $PID).Path
& $runner -NoProfile -File (Join-Path $PSScriptRoot 'validate-lite-artifacts.real.ps1') -TaskId $TaskId -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
$validatorExitCode = $LASTEXITCODE
if ($mutationStatus -eq 'mutated') {
    [System.IO.File]::WriteAllBytes($testPath, $originalBytes)
}
[System.IO.File]::WriteAllText('__MARKER_PATH__', $mutationStatus, [System.Text.UTF8Encoding]::new($false))
exit $validatorExitCode
'@
        $testToctouWrapper = $testToctouWrapper.Replace('__MARKER_PATH__', $testToctouMarkerPath.Replace("'", "''"))
        Write-Utf8Bom -Path $validatorPath -Content $testToctouWrapper
        $testToctouOutcome = Invoke-AdvanceOutcome -ScriptPath $scriptPath -TaskId $taskTestToctou -VaultRoot $vaultRoot -ExpectedStage 'IMPLEMENT'
        $testToctouPlanText = Get-Content -LiteralPath $testToctouPlanPath -Raw -Encoding utf8
        $testToctouMutationStatus = if (Test-Path -LiteralPath $testToctouMarkerPath -PathType Leaf) {
            Get-Content -LiteralPath $testToctouMarkerPath -Raw -Encoding utf8
        } else {
            'missing'
        }
        if ($testToctouOutcome.Succeeded -and
            $testToctouOutcome.Output -eq 'CODE_REVIEW | codex' -and
            $testToctouMutationStatus -eq 'blocked' -and
            (Get-FileFingerprint -Path $testToctouReportPath) -eq $testToctouReportFingerprint -and
            $testToctouPlanText -match '(?m)^stage:\s*CODE_REVIEW\s*$') {
            Add-Check 'held test.md snapshot blocks validator-window A-B-A mutation while allowing the validated transition'
        } else {
            Add-Failure ("validator-window A-B-A mutation should be blocked by the held snapshot: status={0}; outcome={1}" -f $testToctouMutationStatus, $(if ($testToctouOutcome.Succeeded) { $testToctouOutcome.Output } else { $testToctouOutcome.Error }))
        }

        $barrierFixtureRoot = New-IsolatedRepoFixture -SourceRoot $SourceRoot
        $createdTaskDirs += $barrierFixtureRoot
        $barrierScriptPath = Join-Path $barrierFixtureRoot 'scripts\advance-stage.ps1'
        $barrierTaskBase = Join-Path $barrierFixtureRoot 'docs\tasks'
        $barrierVault = Join-Path $barrierFixtureRoot '.assistant'
        $createdTaskDirs += $barrierVault
        New-Item -ItemType Directory -Path (Join-Path $barrierVault '运行时\tasks') -Force | Out-Null
        $taskCommitWindow = 'lite-commit-window-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskCommitWindowDir = Join-Path $barrierTaskBase $taskCommitWindow
        New-Item -ItemType Directory -Path $taskCommitWindowDir -Force | Out-Null
        $commitWindowPlanPath = Join-Path $taskCommitWindowDir 'plan.md'
        $commitWindowTestPath = Join-Path $taskCommitWindowDir 'test.md'
        Write-Utf8Bom -Path $commitWindowPlanPath -Content (New-CanonicalTestPlan -TaskId $taskCommitWindow)
        Write-Utf8Bom -Path $commitWindowTestPath -Content (New-TestReport -Conclusion 'pass')
        $null = Invoke-AdvanceSuccess -ScriptPath $barrierScriptPath -TaskId $taskCommitWindow -VaultRoot $barrierVault -ExpectedStage 'TEST' -SyncOnly -ActivateCurrent
        $commitWindowInboxPath = Join-Path $barrierVault '运行时\收件箱.md'
        Write-RuntimeInbox -InboxPath $commitWindowInboxPath -CreatedDate '2026-07-10' -Rows @([pscustomobject]@{
                CreatedAt = '-'; Source = 'sentinel'; TaskId = 'unknown'; Type = 'hidden'; Status = 'open'; Summary = 'preserve'; Payload = 'bytes'
            })
        $readyEventName = 'harness-lite-ready-' + [guid]::NewGuid().ToString('N')
        $releaseEventName = 'harness-lite-release-' + [guid]::NewGuid().ToString('N')
        $readyEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $readyEventName)
        $releaseEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $releaseEventName)
        $barrierSource = Get-Content -LiteralPath $barrierScriptPath -Raw -Encoding utf8
        $barrierAnchor = '            Write-LiteUtf8BomAtomic -Path $planPath -Content $updatedPlan'
        $barrierAnchorCount = [regex]::Matches($barrierSource, [regex]::Escape($barrierAnchor)).Count
        $barrierProcess = $null
        try {
            if ($barrierAnchorCount -ne 1) {
                Add-Failure ("isolated driver should expose one runtime commit anchor, found {0}" -f $barrierAnchorCount)
            } else {
                $barrierBlock = @'
            $readyEvent = [System.Threading.EventWaitHandle]::OpenExisting('__READY_EVENT__')
            try { [void]$readyEvent.Set() } finally { $readyEvent.Dispose() }
            $releaseEvent = [System.Threading.EventWaitHandle]::OpenExisting('__RELEASE_EVENT__')
            try {
                if (-not $releaseEvent.WaitOne(15000)) {
                    throw 'fixture release barrier timed out.'
                }
            } finally {
                $releaseEvent.Dispose()
            }
'@
                $barrierBlock = $barrierBlock.Replace('__READY_EVENT__', $readyEventName)
                $barrierBlock = $barrierBlock.Replace('__RELEASE_EVENT__', $releaseEventName)
                $barrierSource = $barrierSource.Replace($barrierAnchor, ($barrierBlock + "`r`n" + $barrierAnchor))
                Write-Utf8Bom -Path $barrierScriptPath -Content $barrierSource
                $barrierProcess = Start-AdvanceProcess -ScriptPath $barrierScriptPath -TaskId $taskCommitWindow -VaultRoot $barrierVault -ExpectedStage 'TEST' -Tool ''
                $barrierReady = $readyEvent.WaitOne(15000)
                $commitMutationBlocked = $false
                if ($barrierReady) {
                    try {
                        $mutatedCommitReport = (Get-Content -LiteralPath $commitWindowTestPath -Raw -Encoding utf8).Replace(
                            "## Conclusion`r`npass",
                            "## Conclusion`r`nfail"
                        )
                        Write-Utf8Bom -Path $commitWindowTestPath -Content $mutatedCommitReport
                    } catch [System.IO.IOException] {
                        $commitMutationBlocked = $true
                    }
                }
                [void]$releaseEvent.Set()
                $barrierExited = $barrierProcess.Process.WaitForExit(30000)
                if (-not $barrierExited) {
                    $barrierProcess.Process.Kill()
                    $barrierProcess.Process.WaitForExit()
                }
                $barrierStdOut = $barrierProcess.StdOut.Result
                $barrierStdErr = $barrierProcess.StdErr.Result
                $commitWindowPlanText = Get-Content -LiteralPath $commitWindowPlanPath -Raw -Encoding utf8
                $commitWindowTestText = Get-Content -LiteralPath $commitWindowTestPath -Raw -Encoding utf8
                $commitWindowInboxText = Get-Content -LiteralPath $commitWindowInboxPath -Raw -Encoding utf8
                if ($barrierReady -and $barrierExited -and
                    $barrierProcess.Process.ExitCode -eq 0 -and
                    $barrierStdOut.Trim() -eq 'DONE | none' -and
                    $commitMutationBlocked -and
                    $commitWindowPlanText -match '(?m)^stage:\s*DONE\s*$' -and
                    $commitWindowTestText -match '(?m)^## Conclusion\r?\npass\r?$' -and
                    $commitWindowInboxText.Contains('| - | sentinel | unknown | hidden | open | preserve | bytes |')) {
                    Add-Check 'held test.md snapshot blocks post-CAS mutation until the validated plan commit completes'
                } else {
                    Add-Failure ("post-CAS mutation should be blocked while the validated transition commits: ready={0}; blocked={1}; exited={2}; exit={3}; stdout={4}; stderr={5}" -f $barrierReady, $commitMutationBlocked, $barrierExited, $barrierProcess.Process.ExitCode, $barrierStdOut, $barrierStdErr)
                }
            }
        } finally {
            [void]$releaseEvent.Set()
            if ($null -ne $barrierProcess) {
                if (-not $barrierProcess.Process.HasExited) {
                    $barrierProcess.Process.Kill()
                    $barrierProcess.Process.WaitForExit()
                }
                $barrierProcess.Process.Dispose()
            }
            $readyEvent.Dispose()
            $releaseEvent.Dispose()
        }

        $taskWarning = 'lite-warning-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskWarningDir = Join-Path $taskBase $taskWarning
        $createdTaskDirs += $taskWarningDir
        New-Item -ItemType Directory -Path $taskWarningDir -Force | Out-Null
        Write-Utf8Bom -Path (Join-Path $taskWarningDir 'plan.md') -Content (New-PlanContent -TaskId $taskWarning -Stage 'PLAN' -Tool 'codex')
        $warningWrapper = @'
[CmdletBinding()]
param([string]$TaskId, [string]$RepoRoot, [string]$WorkspaceRoot)
'STATUS: PASS'
'Errors:'
'- none'
'Warnings:'
'- stage-safety-warning-sentinel'
exit 0
'@
        Write-Utf8Bom -Path $validatorPath -Content $warningWrapper
        $warningProcess = Start-AdvanceProcess -ScriptPath $scriptPath -TaskId $taskWarning -VaultRoot $vaultRoot -ExpectedStage 'PLAN'
        $warningProcess.Process.WaitForExit()
        $warningStdOut = $warningProcess.StdOut.Result
        $warningStdErr = $warningProcess.StdErr.Result
        if ($warningProcess.Process.ExitCode -eq 0 -and
            $warningStdOut -match 'PLAN_REVIEW \| codex' -and
            $warningStdErr -match 'stage-safety-warning-sentinel') {
            Add-Check 'successful stage advance preserves validator warnings'
        } else {
            Add-Failure 'successful stage advance should surface validator warning text'
        }
        $warningProcess.Process.Dispose()
    } finally {
        Copy-Item -LiteralPath $validatorRealPath -Destination $validatorPath -Force
        Remove-Item -LiteralPath $validatorRealPath -Force
    }
} finally {
    foreach ($taskDir in $createdTaskDirs) {
        Remove-DirectoryWithRetry -Path $taskDir
    }

    Remove-DirectoryWithRetry -Path $vaultRoot
    Remove-DirectoryWithRetry -Path $fixtureRoot
}

Write-Output "Checks:"
if ($script:Checks.Count -eq 0) {
    Write-Output "- none"
} else {
    foreach ($check in $script:Checks) {
        Write-Output "- $check"
    }
}

Write-Output ""
Write-Output "Failures:"
if ($script:Failures.Count -eq 0) {
    Write-Output "- none"
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output "- $failure"
}

exit 1
