# 校验 `validate-lite-artifacts.ps1` 是否真正约束了 lite 写作规范。
# 重点覆盖 frontmatter schema、review findings 写法、IMPLEMENT 回修证据和 TEST handoff。
[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Check {
    <#
    .SYNOPSIS
    记录通过项。
    .DESCRIPTION
    测试结束时统一输出，方便确认 validator 覆盖了哪些文档契约。
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
    失败项会在脚本末尾集中输出，并让回归返回非零退出码。
    .PARAMETER Message
    失败说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Failures += $Message
}

function Write-Utf8Bom {
    <#
    .SYNOPSIS
    以 UTF-8 BOM 写文件。
    .DESCRIPTION
    夹具需要和仓库 active PowerShell 编码保持一致，避免 Windows PowerShell 解析差异。
    .PARAMETER Path
    目标路径。
    .PARAMETER Content
    文件内容。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Remove-DirectoryWithRetry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 200
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Add-Failure ("cleanup failed for {0}: {1}" -f $Path, $lastError.Exception.Message)
    }
}

function Copy-RepoPathToFixture {
    param(
        [string]$SourceRoot,
        [string]$FixtureRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $destinationPath = Join-Path $FixtureRoot $RelativePath
    $destinationParent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
}

function New-IsolatedRepoFixture {
    param([string]$SourceRoot)

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-validator-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\validate-lite-artifacts.ps1'
    if (Test-Path -LiteralPath (Join-Path $SourceRoot 'agent-configs\profiles') -PathType Container) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'agent-configs\profiles'
    }

    return $fixtureRoot
}

function Initialize-GitFixture {
    param([string]$FixtureRoot)

    if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
        return $false
    }

    & git -C $FixtureRoot init -q 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & git -C $FixtureRoot config user.email 'harness-lite@example.invalid' 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & git -C $FixtureRoot config user.name 'Harness Lite Test' 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & git -C $FixtureRoot add -A 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & git -C $FixtureRoot commit -q --allow-empty -m 'baseline' 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Validator {
    <#
    .SYNOPSIS
    调用 lite artifact validator。
    .DESCRIPTION
    用单独的 pwsh 进程执行脚本，确保 exit code 和当前验证基线一致。
    .PARAMETER ValidatorPath
    validator 脚本路径。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER RepoRoot
    仓库根目录。
    .PARAMETER WorkspaceRoot
    项目根目录；为空时 validator 使用 RepoRoot 兼容旧调用。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$ValidatorPath,
        [string]$TaskId,
        [string]$RepoRoot,
        [string]$WorkspaceRoot = "",
        [switch]$Quality
    )

    $command = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $ValidatorPath,
        '-TaskId', $TaskId,
        '-RepoRoot', $RepoRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $command += @('-WorkspaceRoot', $WorkspaceRoot)
    }
    if ($Quality.IsPresent) {
        $command += '-Quality'
    }

    $runnerCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    $runner = if ($null -ne $runnerCommand) {
        $runnerCommand.Source
    } else {
        'powershell.exe'
    }

    $output = @(& $runner @command 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function New-PlanContent {
    <#
    .SYNOPSIS
    生成 plan.md 夹具。
    .DESCRIPTION
    这个模板覆盖 lite validator 当前会读取的 plan section 和 append-only run。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER Stage
    当前阶段。
    .PARAMETER Tool
    tool 名称。
    .PARAMETER ConfirmationStatus
    User Confirmation 状态。
    .PARAMETER FrontmatterExtra
    额外 frontmatter 行。
    .PARAMETER ChangeContractBody
    可选 Change Contract 内容。
    .PARAMETER PlanReviewRuns
    Plan Review 内容。
    .PARAMETER ImplementationRuns
    Implementation Notes 内容。
    .PARAMETER CodeReviewRuns
    Code Review 内容。
    .OUTPUTS
    String。
    #>
    param(
        [string]$TaskId,
        [string]$Stage,
        [string]$Tool,
        [string]$ConfirmationStatus = "confirmed",
        [string]$FrontmatterExtra = "",
        [string]$ChangeContractBody = "",
        [string]$ClarificationBody = "",
        [string]$PlanSectionBody = "",
        [string]$PlanReviewRuns = "",
        [string]$ImplementationRuns = "",
        [string]$CodeReviewRuns = ""
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'
    $extra = if ([string]::IsNullOrWhiteSpace($FrontmatterExtra)) { "" } else { "$FrontmatterExtra`r`n" }
    $changeContractSection = if ([string]::IsNullOrWhiteSpace($ChangeContractBody)) {
        ""
    } else {
        "## Change Contract`r`n$ChangeContractBody`r`n`r`n"
    }
    $planSection = if ([string]::IsNullOrWhiteSpace($PlanSectionBody)) {
        "- 更新 ``scripts/validate-lite-artifacts.ps1`` `r`n- 更新 ``tests/verify-lite-artifact-validator.ps1``"
    } else {
        $PlanSectionBody
    }
    $clarificationSection = if ([string]::IsNullOrWhiteSpace($ClarificationBody)) {
        @(
            '- 验收标准: validator 返回预期结果。'
            '- 非目标: 不改动无关脚本。'
            '- 受影响目录: scripts/, tests/, skills/'
            '- 回滚策略: 回退本轮脚本与文档改动。'
            '- ui: not-applicable'
        ) -join "`r`n"
    } else {
        $ClarificationBody
    }
@"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
updated: $updatedDate
$extra---
# Sample Plan

## Clarification
$clarificationSection

## User Confirmation
- status: $ConfirmationStatus

$changeContractSection
## Plan
$planSection

## Verification
- ``powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-artifact-validator.ps1``

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

function New-SpecContent {
    <#
    .SYNOPSIS
    生成 spec.md 夹具。
    .DESCRIPTION
    spec 只验证固定 section 结构，因此这里提供合法和非法两种最小样例。
    .PARAMETER Valid
    是否生成合法结构。
    .OUTPUTS
    String。
    #>
    param([bool]$Valid = $true)

    if ($Valid) {
@"
# Sample Spec

## Gap
- 需要补文档契约细节。

## Constraint
- 保持 docs/tasks 路径不变。

## Verification Delta
- 多补一条 validator 回归。
"@
    } else {
@"
# Sample Spec

## Gap
- 只有一个 section。
"@
    }
}

function New-TestReport {
    <#
    .SYNOPSIS
    生成 test.md 夹具。
    .DESCRIPTION
    支持覆盖结论和 Handoff，用来验证 TEST/DONE 文档契约。
    .PARAMETER Conclusion
    结论字面量。
    .PARAMETER IncludeHandoff
    是否包含 Handoff。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Conclusion = "pass",
        [bool]$IncludeHandoff = $true
    )

    $handoff = if ($IncludeHandoff) {
        "## Handoff`r`n- delivery: 输出测试结论。`r`n- follow_up: none`r`n"
    } else {
        ""
    }

@"
# Test Report

## Summary
- validator smoke。

## Scope
- 当前 task 文档。

## Inputs Reviewed
- ``docs/tasks/sample/plan.md``

## Test Approach
- 调用 validator。

## Findings
- none

## Risks / Gaps
- none

## Conclusion
$Conclusion

$handoff
"@
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$SourceRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $SourceRoot
$RepoRoot = $fixtureRoot
$validatorPath = Join-Path $RepoRoot 'scripts\validate-lite-artifacts.ps1'
$taskBase = Join-Path $RepoRoot 'docs\tasks'
$script:Checks = @()
$script:Failures = @()
$createdTaskDirs = @()
$gitFixtureReady = Initialize-GitFixture -FixtureRoot $RepoRoot
if ($gitFixtureReady) {
    Add-Check 'git fixture initialized for artifact drift tests'
} else {
    Add-Failure 'git fixture should initialize for artifact drift tests'
}

try {
    $taskValid = 'lite-validator-valid-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskValidDir = Join-Path $taskBase $taskValid
    $createdTaskDirs += $taskValidDir
    New-Item -ItemType Directory -Path $taskValidDir -Force | Out-Null
    $planReviewPass = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: none
"@
    $implementationPass = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- changed: 更新 validator 与 README
- tests: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-artifact-validator.ps1
- risks: none
- next: 交给 CODE_REVIEW 复核
"@
    $codeReviewPass = @"
### Run 1 · 2026-04-09 11:00 · runner: Codex
- verdict: pass
- findings: none
- next: 进入 TEST
"@
    Write-Utf8Bom -Path (Join-Path $taskValidDir 'plan.md') -Content (New-PlanContent -TaskId $taskValid -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
    Write-Utf8Bom -Path (Join-Path $taskValidDir 'spec.md') -Content (New-SpecContent -Valid $true)
    Write-Utf8Bom -Path (Join-Path $taskValidDir 'test.md') -Content (New-TestReport -Conclusion 'pass' -IncludeHandoff $true)
    $validResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot
    if ($validResult.ExitCode -eq 0 -and ($validResult.Output -join "`n") -match 'STATUS: PASS') {
        Add-Check 'valid DONE task passes validator'
    } else {
        Add-Failure ("valid task should pass validator, got: {0}" -f ($validResult.Output -join ' | '))
    }

    # Format-loosening: clarification accepts 同义写法 (受影响模块 / 兼容) aligned with advance-stage.
    $taskLenientClarify = 'lite-validator-clarify-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskLenientClarifyDir = Join-Path $taskBase $taskLenientClarify
    $createdTaskDirs += $taskLenientClarifyDir
    New-Item -ItemType Directory -Path $taskLenientClarifyDir -Force | Out-Null
    $lenientClarification = @(
        '- work_type: refactor'
        '- 验收: 行为不变。'
        '- 非目标: 不扩大范围。'
        '- 受影响模块: scripts/'
        '- 兼容性约束: 保持现有契约。'
        '- ui: not-applicable'
    ) -join "`r`n"
    Write-Utf8Bom -Path (Join-Path $taskLenientClarifyDir 'plan.md') -Content (New-PlanContent -TaskId $taskLenientClarify -Stage 'PLAN' -Tool 'codex' -ClarificationBody $lenientClarification)
    $lenientClarifyResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskLenientClarify -RepoRoot $RepoRoot
    if ($lenientClarifyResult.ExitCode -eq 0 -and ($lenientClarifyResult.Output -join "`n") -match 'STATUS: PASS') {
        Add-Check 'clarification accepts 受影响模块/兼容 synonyms (aligned with advance-stage)'
    } else {
        Add-Failure ("lenient clarification synonyms should pass, got: {0}" -f ($lenientClarifyResult.Output -join ' | '))
    }

    # Format-loosening: Run heading tolerates tight `·` spacing (no surrounding space).
    $taskTightRun = 'lite-validator-tightrun-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskTightRunDir = Join-Path $taskBase $taskTightRun
    $createdTaskDirs += $taskTightRunDir
    New-Item -ItemType Directory -Path $taskTightRunDir -Force | Out-Null
    $tightRun = @'
### Run 1·2026-04-09 10:00·runner: Codex
- verdict: pass
- findings: none
- next: none
'@
    Write-Utf8Bom -Path (Join-Path $taskTightRunDir 'plan.md') -Content (New-PlanContent -TaskId $taskTightRun -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $tightRun)
    $tightRunResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskTightRun -RepoRoot $RepoRoot
    if ($tightRunResult.ExitCode -eq 0 -and ($tightRunResult.Output -join "`n") -match 'STATUS: PASS') {
        Add-Check 'Run heading tolerates tight `·` spacing'
    } else {
        Add-Failure ("tight Run heading spacing should pass, got: {0}" -f ($tightRunResult.Output -join ' | '))
    }

    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-validator-workspace-' + [guid]::NewGuid().ToString('N'))
    $createdTaskDirs += $workspaceRoot
    $workspaceTaskBase = Join-Path $workspaceRoot 'docs\tasks'
    New-Item -ItemType Directory -Path $workspaceTaskBase -Force | Out-Null
    $taskWorkspace = 'lite-validator-workspace-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskWorkspaceDir = Join-Path $workspaceTaskBase $taskWorkspace
    New-Item -ItemType Directory -Path $taskWorkspaceDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskWorkspaceDir 'plan.md') -Content (New-PlanContent -TaskId $taskWorkspace -Stage 'PLAN' -Tool 'codex')
    $workspaceResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskWorkspace -RepoRoot $RepoRoot -WorkspaceRoot $workspaceRoot
    $repoTaskPath = Join-Path $taskBase $taskWorkspace
    $workspaceOutput = $workspaceResult.Output -join "`n"
    if ($workspaceResult.ExitCode -eq 0 -and
        $workspaceOutput -match 'STATUS: PASS' -and
        $workspaceOutput -match [regex]::Escape("TaskRoot: $taskWorkspaceDir") -and
        -not (Test-Path -LiteralPath $repoTaskPath)) {
        Add-Check 'validator reads task artifacts from WorkspaceRoot while using RepoRoot for harness config'
    } else {
        Add-Failure ("WorkspaceRoot task should pass without a repo-local task, got: {0}" -f ($workspaceResult.Output -join ' | '))
    }

    $validQualityResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValid -RepoRoot $RepoRoot -Quality
    if ($validQualityResult.ExitCode -eq 0 -and ($validQualityResult.Output -join "`n") -match 'Plan Review Run 1 未录入 4-dim score') {
        Add-Check 'legacy review runs pass with warnings in -Quality mode'
    } else {
        Add-Failure ("legacy review runs should pass with quality warnings, got: {0}" -f ($validQualityResult.Output -join ' | '))
    }

    $taskPlanMetadataValid = 'lite-validator-planmeta-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskPlanMetadataValidDir = Join-Path $taskBase $taskPlanMetadataValid
    $createdTaskDirs += $taskPlanMetadataValidDir
    New-Item -ItemType Directory -Path $taskPlanMetadataValidDir -Force | Out-Null
    $planMetadataBody = @'
- read_first: [docs/shared-memory-layers.md, scripts/validate-lite-artifacts.ps1]
- convergence:
  - `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern '\[switch\]\`$Quality'`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- artifacts: [docs/工作流/single-writer-precompact.md, scripts/validate-lite-artifacts.ps1]
- 更新 ``scripts/validate-lite-artifacts.ps1``
'@
    Write-Utf8Bom -Path (Join-Path $taskPlanMetadataValidDir 'plan.md') -Content (New-PlanContent -TaskId $taskPlanMetadataValid -Stage 'PLAN' -Tool 'codex' -PlanSectionBody $planMetadataBody)
    $planMetadataValidResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskPlanMetadataValid -RepoRoot $RepoRoot
    if ($planMetadataValidResult.ExitCode -eq 0 -and
        ($planMetadataValidResult.Output -join "`n") -match 'Plan read_first metadata is legal' -and
        ($planMetadataValidResult.Output -join "`n") -match 'Plan artifacts metadata is legal') {
        Add-Check 'plan read_first/convergence/artifacts metadata passes validator'
    } else {
        Add-Failure ("valid plan metadata should pass validator, got: {0}" -f ($planMetadataValidResult.Output -join ' | '))
    }

    $taskReadFirstInvalid = 'lite-validator-readfirst-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskReadFirstInvalidDir = Join-Path $taskBase $taskReadFirstInvalid
    $createdTaskDirs += $taskReadFirstInvalidDir
    New-Item -ItemType Directory -Path $taskReadFirstInvalidDir -Force | Out-Null
    $invalidReadFirstBody = @"
- read_first:
  - docs/shared-memory-layers.md
  - scripts/validate-lite-artifacts.ps1
- 更新 ``scripts/validate-lite-artifacts.ps1``
"@
    Write-Utf8Bom -Path (Join-Path $taskReadFirstInvalidDir 'plan.md') -Content (New-PlanContent -TaskId $taskReadFirstInvalid -Stage 'PLAN' -Tool 'codex' -PlanSectionBody $invalidReadFirstBody)
    $invalidReadFirstResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskReadFirstInvalid -RepoRoot $RepoRoot
    if ($invalidReadFirstResult.ExitCode -ne 0 -and ($invalidReadFirstResult.Output -join "`n") -match 'read_first should use inline-array syntax') {
        Add-Check 'block-list read_first is rejected'
    } else {
        Add-Failure ("block-list read_first should fail validator, got: {0}" -f ($invalidReadFirstResult.Output -join ' | '))
    }

    $taskConvergenceInvalid = 'lite-validator-convergence-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskConvergenceInvalidDir = Join-Path $taskBase $taskConvergenceInvalid
    $createdTaskDirs += $taskConvergenceInvalidDir
    New-Item -ItemType Directory -Path $taskConvergenceInvalidDir -Force | Out-Null
    $invalidConvergenceBody = @"
- convergence:
  - TBD
- 更新 ``scripts/validate-lite-artifacts.ps1``
"@
    Write-Utf8Bom -Path (Join-Path $taskConvergenceInvalidDir 'plan.md') -Content (New-PlanContent -TaskId $taskConvergenceInvalid -Stage 'PLAN' -Tool 'codex' -PlanSectionBody $invalidConvergenceBody)
    $invalidConvergenceResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskConvergenceInvalid -RepoRoot $RepoRoot
    if ($invalidConvergenceResult.ExitCode -ne 0 -and ($invalidConvergenceResult.Output -join "`n") -match 'convergence should contain at least one non-placeholder criterion') {
        Add-Check 'placeholder-only convergence is rejected'
    } else {
        Add-Failure ("placeholder-only convergence should fail validator, got: {0}" -f ($invalidConvergenceResult.Output -join ' | '))
    }

    $taskArtifactsBlockInvalid = 'lite-validator-artifacts-block-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskArtifactsBlockInvalidDir = Join-Path $taskBase $taskArtifactsBlockInvalid
    $createdTaskDirs += $taskArtifactsBlockInvalidDir
    New-Item -ItemType Directory -Path $taskArtifactsBlockInvalidDir -Force | Out-Null
    $invalidArtifactsBlockBody = @"
- artifacts:
  - docs/工作流/single-writer-precompact.md
  - scripts/validate-lite-artifacts.ps1
- 更新 ``scripts/validate-lite-artifacts.ps1``
"@
    Write-Utf8Bom -Path (Join-Path $taskArtifactsBlockInvalidDir 'plan.md') -Content (New-PlanContent -TaskId $taskArtifactsBlockInvalid -Stage 'PLAN' -Tool 'codex' -PlanSectionBody $invalidArtifactsBlockBody)
    $invalidArtifactsBlockResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskArtifactsBlockInvalid -RepoRoot $RepoRoot
    if ($invalidArtifactsBlockResult.ExitCode -ne 0 -and ($invalidArtifactsBlockResult.Output -join "`n") -match 'Plan artifacts should use inline-array syntax like \[a, b\]') {
        Add-Check 'block-list artifacts is rejected'
    } else {
        Add-Failure ("block-list artifacts should fail validator, got: {0}" -f ($invalidArtifactsBlockResult.Output -join ' | '))
    }

    $taskArtifactsEmptyInvalid = 'lite-validator-artifacts-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskArtifactsEmptyInvalidDir = Join-Path $taskBase $taskArtifactsEmptyInvalid
    $createdTaskDirs += $taskArtifactsEmptyInvalidDir
    New-Item -ItemType Directory -Path $taskArtifactsEmptyInvalidDir -Force | Out-Null
    $invalidArtifactsEmptyBody = @"
- artifacts: []
- 更新 ``scripts/validate-lite-artifacts.ps1``
"@
    Write-Utf8Bom -Path (Join-Path $taskArtifactsEmptyInvalidDir 'plan.md') -Content (New-PlanContent -TaskId $taskArtifactsEmptyInvalid -Stage 'PLAN' -Tool 'codex' -PlanSectionBody $invalidArtifactsEmptyBody)
    $invalidArtifactsEmptyResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskArtifactsEmptyInvalid -RepoRoot $RepoRoot
    if ($invalidArtifactsEmptyResult.ExitCode -ne 0 -and ($invalidArtifactsEmptyResult.Output -join "`n") -match 'Plan artifacts should contain at least one entry') {
        Add-Check 'empty artifacts array is rejected'
    } else {
        Add-Failure ("empty artifacts array should fail validator, got: {0}" -f ($invalidArtifactsEmptyResult.Output -join ' | '))
    }

    $taskArtifactsFutureValid = 'lite-validator-artifacts-future-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskArtifactsFutureValidDir = Join-Path $taskBase $taskArtifactsFutureValid
    $createdTaskDirs += $taskArtifactsFutureValidDir
    New-Item -ItemType Directory -Path $taskArtifactsFutureValidDir -Force | Out-Null
    $futureArtifactsBody = @"
- artifacts: [docs/future/not-yet-created.md, scripts/future/not-yet-created.ps1]
- 更新 ``docs/tasks/$taskArtifactsFutureValid/plan.md``
"@
    Write-Utf8Bom -Path (Join-Path $taskArtifactsFutureValidDir 'plan.md') -Content (New-PlanContent -TaskId $taskArtifactsFutureValid -Stage 'PLAN' -Tool 'codex' -PlanSectionBody $futureArtifactsBody)
    $futureArtifactsResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskArtifactsFutureValid -RepoRoot $RepoRoot
    if ($futureArtifactsResult.ExitCode -eq 0 -and
        ($futureArtifactsResult.Output -join "`n") -match 'Plan artifacts metadata is legal' -and
        ($futureArtifactsResult.Output -join "`n") -notmatch '(?ms)Warnings:\s*- artifact drift') {
        Add-Check 'PLAN stage future artifact does not warn'
    } else {
        Add-Failure ("PLAN stage future artifact should not warn, got: {0}" -f ($futureArtifactsResult.Output -join ' | '))
    }

    $taskUnicodeDrift = 'lite-validator-unicode-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskUnicodeDriftDir = Join-Path $taskBase $taskUnicodeDrift
    $createdTaskDirs += $taskUnicodeDriftDir
    New-Item -ItemType Directory -Path $taskUnicodeDriftDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'docs\工作流') -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $RepoRoot 'docs\工作流\unicode-drift.md') -Content "# Unicode drift`r`n"
    $unicodePlanBody = @"
- artifacts: [docs/工作流/unicode-drift.md]
- 更新 ``docs/工作流/unicode-drift.md``
"@
    $unicodeChangeContract = @"
- change_type: enhance
- affected_paths:
  - docs/tasks
  - docs/工作流/unicode-drift.md
"@
    Write-Utf8Bom -Path (Join-Path $taskUnicodeDriftDir 'plan.md') -Content (New-PlanContent -TaskId $taskUnicodeDrift -Stage 'IMPLEMENT' -Tool 'codex' -ChangeContractBody $unicodeChangeContract -PlanSectionBody $unicodePlanBody)
    $unicodeDriftResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskUnicodeDrift -RepoRoot $RepoRoot
    $unicodeDriftOutput = $unicodeDriftResult.Output -join "`n"
    if ($unicodeDriftResult.ExitCode -eq 0 -and
        $unicodeDriftOutput -match 'Plan artifacts metadata is legal' -and
        $unicodeDriftOutput -notmatch 'artifact drift: changed path is not declared') {
        Add-Check 'non-ASCII declared changed path is not drift warning'
    } else {
        Add-Failure ("non-ASCII declared changed path should not warn as undeclared, got: {0}" -f ($unicodeDriftResult.Output -join ' | '))
    }

    $taskArtifactsDriftWarning = 'lite-validator-artifacts-drift-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskArtifactsDriftWarningDir = Join-Path $taskBase $taskArtifactsDriftWarning
    $createdTaskDirs += $taskArtifactsDriftWarningDir
    New-Item -ItemType Directory -Path $taskArtifactsDriftWarningDir -Force | Out-Null
    $crossArtifactsBody = @"
- artifacts: [docs/outputs/generated-contract.md]
- 更新 ``scripts/validate-lite-artifacts.ps1``
"@
    $crossChangeContract = @"
- change_type: enhance
- affected_paths:
  - scripts/validate-lite-artifacts.ps1
  - skills/plan/SKILL.md
"@
    Write-Utf8Bom -Path (Join-Path $taskArtifactsDriftWarningDir 'plan.md') -Content (New-PlanContent -TaskId $taskArtifactsDriftWarning -Stage 'IMPLEMENT' -Tool 'codex' -ChangeContractBody $crossChangeContract -PlanSectionBody $crossArtifactsBody)
    $crossArtifactsResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskArtifactsDriftWarning -RepoRoot $RepoRoot
    if ($crossArtifactsResult.ExitCode -eq 0 -and
        ($crossArtifactsResult.Output -join "`n") -match 'Plan artifacts metadata is legal' -and
        ($crossArtifactsResult.Output -join "`n") -match 'artifact drift: declared artifact is missing: docs/outputs/generated-contract.md') {
        Add-Check 'IMPLEMENT stage missing artifact is warning-only'
    } else {
        Add-Failure ("IMPLEMENT stage missing artifact should warn without failing, got: {0}" -f ($crossArtifactsResult.Output -join ' | '))
    }

    $taskUntrackedDrift = 'lite-validator-untracked-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskUntrackedDriftDir = Join-Path $taskBase $taskUntrackedDrift
    $createdTaskDirs += $taskUntrackedDriftDir
    New-Item -ItemType Directory -Path $taskUntrackedDriftDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'docs\outputs') -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $RepoRoot 'docs\outputs\untracked-drift.md') -Content "# Untracked drift`r`n"
    $untrackedPlanBody = @"
- artifacts: [scripts/validate-lite-artifacts.ps1]
- 更新 ``scripts/validate-lite-artifacts.ps1``
"@
    Write-Utf8Bom -Path (Join-Path $taskUntrackedDriftDir 'plan.md') -Content (New-PlanContent -TaskId $taskUntrackedDrift -Stage 'IMPLEMENT' -Tool 'codex' -ChangeContractBody $crossChangeContract -PlanSectionBody $untrackedPlanBody)
    $untrackedResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskUntrackedDrift -RepoRoot $RepoRoot
    if ($untrackedResult.ExitCode -eq 0 -and
        ($untrackedResult.Output -join "`n") -match 'artifact drift: changed path is not declared in artifacts or affected_paths: docs/outputs/untracked-drift.md') {
        Add-Check 'untracked changed path is warning-only'
    } else {
        Add-Failure ("untracked changed path should warn without failing, got: {0}" -f ($untrackedResult.Output -join ' | '))
    }

    $taskLegacyNoMetadata = 'lite-validator-legacy-nometa-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskLegacyNoMetadataDir = Join-Path $taskBase $taskLegacyNoMetadata
    $createdTaskDirs += $taskLegacyNoMetadataDir
    New-Item -ItemType Directory -Path $taskLegacyNoMetadataDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskLegacyNoMetadataDir 'plan.md') -Content (New-PlanContent -TaskId $taskLegacyNoMetadata -Stage 'IMPLEMENT' -Tool 'codex')
    $legacyNoMetadataResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskLegacyNoMetadata -RepoRoot $RepoRoot
    if ($legacyNoMetadataResult.ExitCode -eq 0 -and
        ($legacyNoMetadataResult.Output -join "`n") -match 'artifact drift advisory skipped because artifacts and affected_paths are absent') {
        Add-Check 'legacy task without artifacts or Change Contract remains legal'
    } else {
        Add-Failure ("legacy task without artifacts or Change Contract should stay legal, got: {0}" -f ($legacyNoMetadataResult.Output -join ' | '))
    }

    $taskMetadataPositionInvalid = 'lite-validator-planmeta-position-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMetadataPositionInvalidDir = Join-Path $taskBase $taskMetadataPositionInvalid
    $createdTaskDirs += $taskMetadataPositionInvalidDir
    New-Item -ItemType Directory -Path $taskMetadataPositionInvalidDir -Force | Out-Null
    $misplacedMetadataBody = @'
- 更新 ``scripts/validate-lite-artifacts.ps1``
- read_first: [docs/shared-memory-layers.md, scripts/validate-lite-artifacts.ps1]
- convergence:
  - `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern '\[switch\]\`$Quality'`
- artifacts: [docs/工作流/single-writer-precompact.md]
'@
    Write-Utf8Bom -Path (Join-Path $taskMetadataPositionInvalidDir 'plan.md') -Content (New-PlanContent -TaskId $taskMetadataPositionInvalid -Stage 'PLAN' -Tool 'codex' -PlanSectionBody $misplacedMetadataBody)
    $metadataPositionResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskMetadataPositionInvalid -RepoRoot $RepoRoot
    if ($metadataPositionResult.ExitCode -ne 0 -and
        ($metadataPositionResult.Output -join "`n") -match 'Plan metadata read_first should appear before ordinary Plan bullets' -and
        ($metadataPositionResult.Output -join "`n") -match 'Plan metadata convergence should appear before ordinary Plan bullets' -and
        ($metadataPositionResult.Output -join "`n") -match 'Plan metadata artifacts should appear before ordinary Plan bullets') {
        Add-Check 'misplaced Plan metadata is rejected'
    } else {
        Add-Failure ("misplaced Plan metadata should fail validator, got: {0}" -f ($metadataPositionResult.Output -join ' | '))
    }

    $taskQualityPass = 'lite-validator-quality-pass-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskQualityPassDir = Join-Path $taskBase $taskQualityPass
    $createdTaskDirs += $taskQualityPassDir
    New-Item -ItemType Directory -Path $taskQualityPassDir -Force | Out-Null
    $qualityReviewPass = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- score.completeness: 88
- score.consistency: 82
- score.accuracy: 90
- score.depth: 84
- findings: none
- next: none
"@
    Write-Utf8Bom -Path (Join-Path $taskQualityPassDir 'plan.md') -Content (New-PlanContent -TaskId $taskQualityPass -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $qualityReviewPass)
    $qualityPassResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskQualityPass -RepoRoot $RepoRoot -Quality
    if ($qualityPassResult.ExitCode -eq 0 -and ($qualityPassResult.Output -join "`n") -match 'verdict matches 4-dim score threshold') {
        Add-Check 'scored review run passes in -Quality mode'
    } else {
        Add-Failure ("scored review run should pass in -Quality mode, got: {0}" -f ($qualityPassResult.Output -join ' | '))
    }

    $taskQualityMismatch = 'lite-validator-quality-mismatch-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskQualityMismatchDir = Join-Path $taskBase $taskQualityMismatch
    $createdTaskDirs += $taskQualityMismatchDir
    New-Item -ItemType Directory -Path $taskQualityMismatchDir -Force | Out-Null
    $qualityReviewMismatch = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- score.completeness: 50
- score.consistency: 50
- score.accuracy: 50
- score.depth: 50
- findings: none
- next: none
"@
    Write-Utf8Bom -Path (Join-Path $taskQualityMismatchDir 'plan.md') -Content (New-PlanContent -TaskId $taskQualityMismatch -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $qualityReviewMismatch)
    $qualityMismatchResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskQualityMismatch -RepoRoot $RepoRoot -Quality
    if ($qualityMismatchResult.ExitCode -ne 0 -and ($qualityMismatchResult.Output -join "`n") -match 'verdict-score 不一致') {
        Add-Check 'score verdict mismatch is rejected in -Quality mode'
    } else {
        Add-Failure ("score verdict mismatch should fail in -Quality mode, got: {0}" -f ($qualityMismatchResult.Output -join ' | '))
    }

    $taskExtraField = 'lite-validator-extra-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskExtraFieldDir = Join-Path $taskBase $taskExtraField
    $createdTaskDirs += $taskExtraFieldDir
    New-Item -ItemType Directory -Path $taskExtraFieldDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskExtraFieldDir 'plan.md') -Content (New-PlanContent -TaskId $taskExtraField -Stage 'PLAN' -Tool 'codex' -FrontmatterExtra 'owner: codex')
    $extraFieldResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskExtraField -RepoRoot $RepoRoot
    if ($extraFieldResult.ExitCode -ne 0 -and ($extraFieldResult.Output -join "`n") -match 'frontmatter should only contain task_id/stage/tool/updated') {
        Add-Check 'extra frontmatter fields are rejected'
    } else {
        Add-Failure ("extra frontmatter field should fail validator, got: {0}" -f ($extraFieldResult.Output -join ' | '))
    }

    $taskInvalidTool = 'lite-validator-tool-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInvalidToolDir = Join-Path $taskBase $taskInvalidTool
    $createdTaskDirs += $taskInvalidToolDir
    New-Item -ItemType Directory -Path $taskInvalidToolDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskInvalidToolDir 'plan.md') -Content (New-PlanContent -TaskId $taskInvalidTool -Stage 'PLAN' -Tool 'claude-codex-gemini-default')
    $invalidToolResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInvalidTool -RepoRoot $RepoRoot
    if ($invalidToolResult.ExitCode -ne 0 -and ($invalidToolResult.Output -join "`n") -match 'plan.md tool should be one of') {
        Add-Check 'invalid tool values are rejected'
    } else {
        Add-Failure ("invalid tool should fail validator, got: {0}" -f ($invalidToolResult.Output -join ' | '))
    }

    $taskEmptySeverity = 'lite-validator-severity-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskEmptySeverityDir = Join-Path $taskBase $taskEmptySeverity
    $createdTaskDirs += $taskEmptySeverityDir
    New-Item -ItemType Directory -Path $taskEmptySeverityDir -Force | Out-Null
    $badReview = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings:
### P1
- next: none
"@
    Write-Utf8Bom -Path (Join-Path $taskEmptySeverityDir 'plan.md') -Content (New-PlanContent -TaskId $taskEmptySeverity -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $badReview)
    $emptySeverityResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskEmptySeverity -RepoRoot $RepoRoot
    if ($emptySeverityResult.ExitCode -ne 0 -and ($emptySeverityResult.Output -join "`n") -match 'should not use empty severity headings') {
        Add-Check 'empty severity headings are rejected'
    } else {
        Add-Failure ("empty severity headings should fail validator, got: {0}" -f ($emptySeverityResult.Output -join ' | '))
    }

    $taskStaleImplement = 'lite-validator-stale-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskStaleImplementDir = Join-Path $taskBase $taskStaleImplement
    $createdTaskDirs += $taskStaleImplementDir
    New-Item -ItemType Directory -Path $taskStaleImplementDir -Force | Out-Null
    $staleImplementation = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- changed: 初始实现
- tests: none
- risks: none
- next: 交给 CODE_REVIEW
"@
    $reviseCodeReview = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: revise
- findings:
  - P1: 需要补新实现证据
- next: 回 IMPLEMENT
"@
    Write-Utf8Bom -Path (Join-Path $taskStaleImplementDir 'plan.md') -Content (New-PlanContent -TaskId $taskStaleImplement -Stage 'IMPLEMENT' -Tool 'codex' -PlanReviewRuns $planReviewPass -ImplementationRuns $staleImplementation -CodeReviewRuns $reviseCodeReview)
    $staleImplementResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskStaleImplement -RepoRoot $RepoRoot
    if ($staleImplementResult.ExitCode -ne 0 -and ($staleImplementResult.Output -join "`n") -match 'requires a fresh Implementation Notes run') {
        Add-Check 'stale implementation evidence after revise is rejected'
    } else {
        Add-Failure ("stale implementation evidence should fail validator, got: {0}" -f ($staleImplementResult.Output -join ' | '))
    }

    $taskMissingHandoff = 'lite-validator-handoff-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMissingHandoffDir = Join-Path $taskBase $taskMissingHandoff
    $createdTaskDirs += $taskMissingHandoffDir
    New-Item -ItemType Directory -Path $taskMissingHandoffDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskMissingHandoffDir 'plan.md') -Content (New-PlanContent -TaskId $taskMissingHandoff -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
    Write-Utf8Bom -Path (Join-Path $taskMissingHandoffDir 'test.md') -Content (New-TestReport -Conclusion 'pass' -IncludeHandoff $false)
    $missingHandoffResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskMissingHandoff -RepoRoot $RepoRoot
    if ($missingHandoffResult.ExitCode -ne 0 -and ($missingHandoffResult.Output -join "`n") -match 'Handoff should contain') {
        Add-Check 'missing Handoff fields are rejected'
    } else {
        Add-Failure ("missing Handoff should fail validator, got: {0}" -f ($missingHandoffResult.Output -join ' | '))
    }

    $taskBadSpec = 'lite-validator-spec-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskBadSpecDir = Join-Path $taskBase $taskBadSpec
    $createdTaskDirs += $taskBadSpecDir
    New-Item -ItemType Directory -Path $taskBadSpecDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskBadSpecDir 'plan.md') -Content (New-PlanContent -TaskId $taskBadSpec -Stage 'PLAN' -Tool 'codex')
    Write-Utf8Bom -Path (Join-Path $taskBadSpecDir 'spec.md') -Content (New-SpecContent -Valid $false)
    $badSpecResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskBadSpec -RepoRoot $RepoRoot
    if ($badSpecResult.ExitCode -ne 0 -and ($badSpecResult.Output -join "`n") -match 'spec.md sections should be') {
        Add-Check 'invalid spec structure is rejected'
    } else {
        Add-Failure ("invalid spec should fail validator, got: {0}" -f ($badSpecResult.Output -join ' | '))
    }
} finally {
    foreach ($taskDir in $createdTaskDirs) {
        Remove-DirectoryWithRetry -Path $taskDir
    }

    Remove-DirectoryWithRetry -Path $fixtureRoot
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($check in $script:Checks) {
        Write-Output ("- {0}" -f $check)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ("- {0}" -f $failure)
}

exit 1
