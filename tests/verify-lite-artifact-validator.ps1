# 校验 `validate-lite-artifacts.ps1` 是否真正约束了 lite 写作规范。
# 重点覆盖 frontmatter schema、review findings 写法、IMPLEMENT 回修证据和 TEST handoff。
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

function New-IsolatedRepoFixture {
    param([string]$SourceRoot)

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-validator-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\lite-artifact-parser.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\validate-lite-artifacts.ps1'
    Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath 'skills\obsidian-memory\scripts\runtime-state-common.ps1'
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
        [bool]$IncludeHandoff = $true,
        [bool]$IncludeEvidence = $true,
        [string]$ExecutedAt = "2026-07-10T10:00:00+08:00"
    )

    $handoff = if ($IncludeHandoff) {
        "## Handoff`r`n- delivery: 输出测试结论。`r`n- follow_up: none`r`n"
    } else {
        ""
    }
    $evidence = if ($IncludeEvidence) {
        "## Evidence`r`n- command: ``pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1```r`n- exit_code: 0`r`n- executed_at: $ExecutedAt`r`n- revision: 0123456789abcdef0123456789abcdef01234567`r`n- evidence_path: scripts/validate-lite-artifacts.ps1`r`n"
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

$evidence

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
. (Join-Path $RepoRoot 'scripts\lite-artifact-parser.ps1')
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

    $confirmationGrammarCases = @(
        [pscustomobject]@{ Name = 'draft'; Body = '- status: draft'; Expected = 'draft' }
        [pscustomobject]@{ Name = 'confirmed'; Body = '- status: confirmed'; Expected = 'confirmed' }
        [pscustomobject]@{ Name = 'boundary-blank'; Body = "`r`n- status: confirmed`r`n"; Expected = 'confirmed' }
        [pscustomobject]@{ Name = 'horizontal-space'; Body = "- status:`tconfirmed `t"; Expected = 'confirmed' }
        [pscustomobject]@{ Name = 'zero'; Body = '- note: missing'; Expected = $null }
        [pscustomobject]@{ Name = 'duplicate'; Body = "- status: confirmed`r`n- status: confirmed"; Expected = $null }
        [pscustomobject]@{ Name = 'contradictory'; Body = "- status: draft`r`n- status: confirmed"; Expected = $null }
        [pscustomobject]@{ Name = 'legal-plus-illegal'; Body = "- status: confirmed`r`n- status: invalid"; Expected = $null }
        [pscustomobject]@{ Name = 'case-key'; Body = '- Status: confirmed'; Expected = $null }
        [pscustomobject]@{ Name = 'case-value'; Body = '- status: CONFIRMED'; Expected = $null }
        [pscustomobject]@{ Name = 'indent'; Body = '  - status: confirmed'; Expected = $null }
        [pscustomobject]@{ Name = 'comment'; Body = "<!--`r`n- status: confirmed`r`n-->"; Expected = $null }
        [pscustomobject]@{ Name = 'fence'; Body = "~~~text`r`n- status: confirmed`r`n~~~"; Expected = $null }
        [pscustomobject]@{ Name = 'extra'; Body = "- status: confirmed`r`nextra"; Expected = $null }
    )
    $confirmationGrammarFailures = @()
    foreach ($case in $confirmationGrammarCases) {
        $sections = @(Get-LiteSections -Content ("## User Confirmation`r`n{0}`r`n## Plan`r`n- test" -f $case.Body))
        try {
            $actual = Get-LiteUserConfirmationStatus -Sections $sections
        } catch {
            $actual = $null
        }
        if (($null -eq $case.Expected -and $null -ne $actual) -or
            ($null -ne $case.Expected -and $actual -cne $case.Expected)) {
            $confirmationGrammarFailures += $case.Name
        }
    }
    if ($confirmationGrammarFailures.Count -eq 0) {
        Add-Check 'User Confirmation grammar accepts only one case-exact top-level status line with boundary blanks'
    } else {
        Add-Failure ("User Confirmation grammar matrix failed: {0}" -f ($confirmationGrammarFailures -join ', '))
    }

    $plainScalarCases = @(
        [pscustomobject]@{ Name = 'plain'; Value = 'visible text'; Expected = $true }
        [pscustomobject]@{ Name = 'backticked-path'; Value = '`/root/reviewer`'; Expected = $true }
        [pscustomobject]@{ Name = 'empty-link'; Value = '[](https://example.test/hidden)'; Expected = $false }
        [pscustomobject]@{ Name = 'link-only'; Value = '[note](https://example.test/hidden)'; Expected = $false }
        [pscustomobject]@{ Name = 'format-only'; Value = [string][char]0x200B; Expected = $false }
        [pscustomobject]@{ Name = 'html-only'; Value = '<span>hidden</span>'; Expected = $false }
        [pscustomobject]@{ Name = 'entity-only'; Value = '&ZeroWidthSpace;'; Expected = $false }
        [pscustomobject]@{ Name = 'literal-brackets'; Value = '[System.IO.File]::Exists($path)'; Expected = $true; Literal = $true }
        [pscustomobject]@{ Name = 'literal-invocation'; Value = '& pwsh -NoProfile'; Expected = $true; Literal = $true }
        [pscustomobject]@{ Name = 'literal-redirection'; Value = '< input.txt'; Expected = $true; Literal = $true }
        [pscustomobject]@{ Name = 'matched-double-code-span'; Value = '``[System.IO.File]``'; Expected = $true }
        [pscustomobject]@{ Name = 'short-closing-code-span'; Value = '``[](https://example.test/hidden)`'; Expected = $false }
        [pscustomobject]@{ Name = 'long-closing-code-span'; Value = '`[](https://example.test/hidden)``'; Expected = $false }
        [pscustomobject]@{ Name = 'extra-closing-code-span'; Value = '``[](https://example.test/hidden)```'; Expected = $false }
        [pscustomobject]@{ Name = 'multiple-single-code-spans'; Value = '`!` [](https://example.test/hidden) `!`'; Expected = $false }
        [pscustomobject]@{ Name = 'multiple-double-code-spans'; Value = '``!`` [](https://example.test/hidden) ``!``'; Expected = $false }
    )
    $plainScalarFailures = @($plainScalarCases | Where-Object {
        $literal = $_.PSObject.Properties.Name -contains 'Literal' -and $_.Literal
        (Test-LitePlainScalar -Value $_.Value -Literal:$literal) -ne $_.Expected
    })
    if ($plainScalarFailures.Count -eq 0) {
        Add-Check 'machine scalar grammar requires a plain visible value'
    } else {
        Add-Failure ("machine scalar grammar failed: {0}" -f (($plainScalarFailures | ForEach-Object Name) -join ', '))
    }

    $blockFieldCases = @(
        [pscustomobject]@{ Name = 'inline'; Content = '- field: visible'; Expected = $true }
        [pscustomobject]@{ Name = 'indented-list'; Content = "- field:`r`n  - visible"; Expected = $true }
        [pscustomobject]@{ Name = 'blank-then-indented'; Content = "- field:`r`n`r`n  visible"; Expected = $true }
        [pscustomobject]@{ Name = 'heading-boundary'; Content = "- field:`r`n### unrelated`r`n  - later"; Expected = $false }
        [pscustomobject]@{ Name = 'paragraph-boundary'; Content = "- field:`r`nunrelated`r`n  - later"; Expected = $false }
        [pscustomobject]@{ Name = 'thematic-break-boundary'; Content = "- field:`r`n---`r`n  - later"; Expected = $false }
        [pscustomobject]@{ Name = 'tab-sibling-boundary'; Content = "- field:`r`n-`tshadow:`r`n  - later"; Expected = $false }
    )
    $blockFieldFailures = @($blockFieldCases | Where-Object {
        (Test-LiteTopLevelFieldValue -Content $_.Content -FieldPattern 'field') -ne $_.Expected
    })
    if ($blockFieldFailures.Count -eq 0) {
        Add-Check 'block machine values stop at the first nonblank unindented boundary'
    } else {
        Add-Failure ("block machine value boundaries failed: {0}" -f (($blockFieldFailures | ForEach-Object Name) -join ', '))
    }

    $taskDuplicateConfirmation = 'lite-validator-duplicate-confirm-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskDuplicateConfirmationDir = Join-Path $taskBase $taskDuplicateConfirmation
    $createdTaskDirs += $taskDuplicateConfirmationDir
    New-Item -ItemType Directory -Path $taskDuplicateConfirmationDir -Force | Out-Null
    $duplicateConfirmationPlan = (New-PlanContent -TaskId $taskDuplicateConfirmation -Stage 'PLAN' -Tool 'codex').Replace(
        '- status: confirmed',
        "- status: draft`r`n- status: confirmed"
    )
    Write-Utf8Bom -Path (Join-Path $taskDuplicateConfirmationDir 'plan.md') -Content $duplicateConfirmationPlan
    $duplicateConfirmationResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskDuplicateConfirmation -RepoRoot $RepoRoot
    if ($duplicateConfirmationResult.ExitCode -ne 0 -and
        ($duplicateConfirmationResult.Output -join "`n") -match 'exactly one case-exact top-level status line') {
        Add-Check 'validator rejects contradictory User Confirmation status lines'
    } else {
        Add-Failure ("contradictory User Confirmation should fail validator, got: {0}" -f ($duplicateConfirmationResult.Output -join ' | '))
    }

    $taskPostPlanDraft = 'lite-validator-post-plan-draft-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskPostPlanDraftDir = Join-Path $taskBase $taskPostPlanDraft
    $createdTaskDirs += $taskPostPlanDraftDir
    New-Item -ItemType Directory -Path $taskPostPlanDraftDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskPostPlanDraftDir 'plan.md') -Content (New-PlanContent `
        -TaskId $taskPostPlanDraft `
        -Stage 'PLAN_REVIEW' `
        -Tool 'codex' `
        -ConfirmationStatus 'draft' `
        -PlanReviewRuns $planReviewPass)
    $postPlanDraftResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskPostPlanDraft -RepoRoot $RepoRoot
    if ($postPlanDraftResult.ExitCode -ne 0 -and
        ($postPlanDraftResult.Output -join "`n") -match 'post-PLAN stages require User Confirmation status: confirmed') {
        Add-Check 'post-PLAN stages require confirmed User Confirmation state'
    } else {
        Add-Failure ("post-PLAN draft confirmation should fail validator: {0}" -f ($postPlanDraftResult.Output -join ' | '))
    }

    $hiddenSectionVectors = @(
        [pscustomobject]@{ Name = 'html-comment'; Open = '<!--'; Close = '-->'; Error = 'plan\.md sections should be' }
        [pscustomobject]@{ Name = 'tilde-fence'; Open = '~~~powershell'; Close = '~~~'; Error = 'plan\.md sections should be' }
        [pscustomobject]@{ Name = 'raw-html'; Open = '<script>'; Close = '</script>'; Error = 'Block-position angle-bracket syntax' }
        [pscustomobject]@{ Name = 'tab-pseudo-close'; Open = "~~~text`r`n`t~~~"; Close = '~~~'; Error = 'plan\.md sections should be' }
    )
    $hiddenSectionFailures = @()
    foreach ($vector in $hiddenSectionVectors) {
        $taskHiddenSections = 'lite-validator-hidden-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskHiddenSectionsDir = Join-Path $taskBase $taskHiddenSections
        $createdTaskDirs += $taskHiddenSectionsDir
        New-Item -ItemType Directory -Path $taskHiddenSectionsDir -Force | Out-Null
        $hiddenSectionsPlan = (New-PlanContent -TaskId $taskHiddenSections -Stage 'PLAN' -Tool 'codex').Replace(
            '# Sample Plan',
            "# Sample Plan`r`n$($vector.Open)"
        ).Replace(
            '## Plan Review',
            "$($vector.Close)`r`n## Plan Review"
        )
        Write-Utf8Bom -Path (Join-Path $taskHiddenSectionsDir 'plan.md') -Content $hiddenSectionsPlan
        $hiddenSectionsResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskHiddenSections -RepoRoot $RepoRoot
        if ($hiddenSectionsResult.ExitCode -eq 0 -or
            ($hiddenSectionsResult.Output -join "`n") -notmatch $vector.Error) {
            $hiddenSectionFailures += $vector.Name
        }
    }
    if ($hiddenSectionFailures.Count -eq 0) {
        Add-Check 'validator rejects workflow headings hidden across HTML comments, fenced code, and raw HTML'
    } else {
        Add-Failure ("validator accepted or misclassified hidden workflow sections: {0}" -f ($hiddenSectionFailures -join ', '))
    }

    $taskInlineComment = 'lite-validator-inline-comment-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInlineCommentDir = Join-Path $taskBase $taskInlineComment
    $createdTaskDirs += $taskInlineCommentDir
    New-Item -ItemType Directory -Path $taskInlineCommentDir -Force | Out-Null
    $inlineCommentPlan = (New-PlanContent -TaskId $taskInlineComment -Stage 'PLAN' -Tool 'codex').Replace(
        '- ui: not-applicable',
        ('- ui: not-applicable' + "`r`n" + '- literal: `<!--`')
    )
    Write-Utf8Bom -Path (Join-Path $taskInlineCommentDir 'plan.md') -Content $inlineCommentPlan
    $inlineCommentResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInlineComment -RepoRoot $RepoRoot
    if ($inlineCommentResult.ExitCode -eq 0 -and
        ($inlineCommentResult.Output -join "`n") -match 'STATUS: PASS') {
        Add-Check 'validator keeps block headings visible after an inline HTML-comment literal'
    } else {
        Add-Failure ("inline HTML-comment literal should not hide later sections: {0}" -f ($inlineCommentResult.Output -join ' | '))
    }

    $taskLiteralVerification = 'lite-validator-literal-command-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskLiteralVerificationDir = Join-Path $taskBase $taskLiteralVerification
    $createdTaskDirs += $taskLiteralVerificationDir
    New-Item -ItemType Directory -Path $taskLiteralVerificationDir -Force | Out-Null
    $literalVerificationPlan = (New-PlanContent -TaskId $taskLiteralVerification -Stage 'PLAN' -Tool 'codex').Replace(
        '- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-artifact-validator.ps1`',
        '- `[System.IO.File]::Exists("x")`'
    )
    Write-Utf8Bom -Path (Join-Path $taskLiteralVerificationDir 'plan.md') -Content $literalVerificationPlan
    $literalVerificationResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskLiteralVerification -RepoRoot $RepoRoot
    if ($literalVerificationResult.ExitCode -eq 0) {
        Add-Check 'Verification accepts visible literal command syntax inside a code span'
    } else {
        Add-Failure ("literal Verification command should pass: {0}" -f ($literalVerificationResult.Output -join ' | '))
    }

    $hiddenClarificationBodies = @(
        '- note: <!-- 验收 非目标 受影响 回滚 ui: -->'
        '- [note](https://example.test/验收/非目标/受影响/回滚/ui:)'
    )
    $hiddenClarificationFailures = @()
    foreach ($clarificationBody in $hiddenClarificationBodies) {
        $taskHiddenClarification = 'lite-validator-hidden-clarification-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskHiddenClarificationDir = Join-Path $taskBase $taskHiddenClarification
        $createdTaskDirs += $taskHiddenClarificationDir
        New-Item -ItemType Directory -Path $taskHiddenClarificationDir -Force | Out-Null
        Write-Utf8Bom -Path (Join-Path $taskHiddenClarificationDir 'plan.md') -Content (New-PlanContent `
            -TaskId $taskHiddenClarification `
            -Stage 'PLAN' `
            -Tool 'codex' `
            -ClarificationBody $clarificationBody)
        $hiddenClarificationResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskHiddenClarification -RepoRoot $RepoRoot
        if ($hiddenClarificationResult.ExitCode -eq 0 -or
            ($hiddenClarificationResult.Output -join "`n") -notmatch 'Clarification should contain') {
            $hiddenClarificationFailures += $clarificationBody
        }
    }
    if ($hiddenClarificationFailures.Count -eq 0) {
        Add-Check 'validator requires explicit visible Clarification fields and values'
    } else {
        Add-Failure ("hidden Clarification values satisfied the contract: {0}" -f ($hiddenClarificationFailures -join ' | '))
    }

    $taskInterruptedClarification = 'lite-validator-interrupted-clarification-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInterruptedClarificationDir = Join-Path $taskBase $taskInterruptedClarification
    $createdTaskDirs += $taskInterruptedClarificationDir
    New-Item -ItemType Directory -Path $taskInterruptedClarificationDir -Force | Out-Null
    $interruptedClarification = @'
- 验收:
### unrelated
  - payload-after-heading
- 非目标: 不改无关脚本
- 受影响目录: scripts
- 回滚策略: 回退改动
- ui: not-applicable
'@
    Write-Utf8Bom -Path (Join-Path $taskInterruptedClarificationDir 'plan.md') -Content (New-PlanContent `
        -TaskId $taskInterruptedClarification `
        -Stage 'PLAN' `
        -Tool 'codex' `
        -ClarificationBody $interruptedClarification)
    $interruptedClarificationResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInterruptedClarification -RepoRoot $RepoRoot
    if ($interruptedClarificationResult.ExitCode -ne 0 -and
        ($interruptedClarificationResult.Output -join "`n") -match 'Clarification should contain') {
        Add-Check 'Clarification block values cannot cross an unindented Markdown boundary'
    } else {
        Add-Failure ("interrupted Clarification block should fail validator: {0}" -f ($interruptedClarificationResult.Output -join ' | '))
    }

    $taskUnicodeHeading = 'lite-validator-unicode-heading-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskUnicodeHeadingDir = Join-Path $taskBase $taskUnicodeHeading
    $createdTaskDirs += $taskUnicodeHeadingDir
    New-Item -ItemType Directory -Path $taskUnicodeHeadingDir -Force | Out-Null
    $unicodeHeadingPlan = (New-PlanContent -TaskId $taskUnicodeHeading -Stage 'PLAN' -Tool 'codex').Replace(
        '## User Confirmation',
        ("##{0}User Confirmation" -f [char]0x00A0)
    )
    Write-Utf8Bom -Path (Join-Path $taskUnicodeHeadingDir 'plan.md') -Content $unicodeHeadingPlan
    $unicodeHeadingResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskUnicodeHeading -RepoRoot $RepoRoot
    if ($unicodeHeadingResult.ExitCode -ne 0 -and
        ($unicodeHeadingResult.Output -join "`n") -match 'plan\.md sections should be') {
        Add-Check 'validator rejects non-CommonMark whitespace in structural heading separators'
    } else {
        Add-Failure ("Unicode heading separator should not create a workflow section: {0}" -f ($unicodeHeadingResult.Output -join ' | '))
    }

    $taskCountBeforeInvalidIds = @(Get-ChildItem -LiteralPath $taskBase -Force).Count
    $invalidTaskIds = @('..\..\outside', 'Bad-Task', 'bad_task', 'bad.task', ('a' * 65))
    $invalidTaskIdsRejected = $true
    foreach ($invalidTaskId in $invalidTaskIds) {
        $invalidTaskIdResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $invalidTaskId -RepoRoot $RepoRoot
        if ($invalidTaskIdResult.ExitCode -eq 0 -or ($invalidTaskIdResult.Output -join "`n") -notmatch 'TaskId must be a lowercase slug') {
            $invalidTaskIdsRejected = $false
        }
    }
    if ($invalidTaskIdsRejected -and @(Get-ChildItem -LiteralPath $taskBase -Force).Count -eq $taskCountBeforeInvalidIds) {
        Add-Check 'validator rejects traversal, uppercase, underscore, dot, and 65-character TaskIds before task-tree access'
    } else {
        Add-Failure 'invalid TaskIds should fail without task-tree writes'
    }

    $taskMaxLength = 'a' * 64
    $taskMaxLengthDir = Join-Path $taskBase $taskMaxLength
    $createdTaskDirs += $taskMaxLengthDir
    New-Item -ItemType Directory -Path $taskMaxLengthDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskMaxLengthDir 'plan.md') -Content (New-PlanContent -TaskId $taskMaxLength -Stage 'PLAN' -Tool 'codex')
    $taskMaxLengthResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskMaxLength -RepoRoot $RepoRoot
    if ($taskMaxLengthResult.ExitCode -eq 0) {
        Add-Check 'validator accepts a canonical 64-character TaskId'
    } else {
        Add-Failure ("canonical 64-character TaskId should pass, got: {0}" -f ($taskMaxLengthResult.Output -join ' | '))
    }

    $taskDuplicate = 'lite-validator-duplicate-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskDuplicateDir = Join-Path $taskBase $taskDuplicate
    $createdTaskDirs += $taskDuplicateDir
    New-Item -ItemType Directory -Path $taskDuplicateDir -Force | Out-Null
    $duplicatePlan = (New-PlanContent -TaskId $taskDuplicate -Stage 'PLAN' -Tool 'codex') -replace "stage: PLAN", "stage: PLAN`r`nstage: TEST"
    Write-Utf8Bom -Path (Join-Path $taskDuplicateDir 'plan.md') -Content $duplicatePlan
    $duplicateResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskDuplicate -RepoRoot $RepoRoot
    if ($duplicateResult.ExitCode -ne 0 -and ($duplicateResult.Output -join "`n") -match 'duplicate frontmatter field: stage') {
        Add-Check 'validator rejects duplicate frontmatter fields'
    } else {
        Add-Failure ("duplicate frontmatter should fail, got: {0}" -f ($duplicateResult.Output -join ' | '))
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

    $taskMalformedLatestRun = 'lite-validator-malformed-run-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMalformedLatestRunDir = Join-Path $taskBase $taskMalformedLatestRun
    $createdTaskDirs += $taskMalformedLatestRunDir
    New-Item -ItemType Directory -Path $taskMalformedLatestRunDir -Force | Out-Null
    $malformedLatestRuns = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: IMPLEMENT

### Run 2 · malformed-time · runner: Codex
- verdict: revise
- findings:
  - P1: malformed latest run must not disappear
- next: PLAN
'@
    Write-Utf8Bom -Path (Join-Path $taskMalformedLatestRunDir 'plan.md') -Content (New-PlanContent -TaskId $taskMalformedLatestRun -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $malformedLatestRuns)
    $malformedLatestRunResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskMalformedLatestRun -RepoRoot $RepoRoot
    if ($malformedLatestRunResult.ExitCode -ne 0 -and ($malformedLatestRunResult.Output -join "`n") -match 'invalid Run heading or unparsed Run block') {
        Add-Check 'malformed latest Run fails closed instead of falling back to an older pass'
    } else {
        Add-Failure ("malformed latest Run should fail validator, got: {0}" -f ($malformedLatestRunResult.Output -join ' | '))
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

    $taskJunction = 'lite-validator-junction-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskJunctionTarget = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-validator-target-' + [guid]::NewGuid().ToString('N'))
    $taskJunctionPath = Join-Path $taskBase $taskJunction
    $createdTaskDirs += @($taskJunctionPath, $taskJunctionTarget)
    New-Item -ItemType Directory -Path $taskJunctionTarget -Force | Out-Null
    $taskJunctionPlan = Join-Path $taskJunctionTarget 'plan.md'
    Write-Utf8Bom -Path $taskJunctionPlan -Content (New-PlanContent -TaskId $taskJunction -Stage 'PLAN' -Tool 'codex')
    New-Item -ItemType Junction -Path $taskJunctionPath -Target $taskJunctionTarget | Out-Null
    $taskJunctionHash = (Get-FileHash -LiteralPath $taskJunctionPlan -Algorithm SHA256).Hash
    $taskJunctionResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskJunction -RepoRoot $RepoRoot
    if ($taskJunctionResult.ExitCode -ne 0 -and
        ($taskJunctionResult.Output -join "`n") -match 'reparse point' -and
        (Get-FileHash -LiteralPath $taskJunctionPlan -Algorithm SHA256).Hash -eq $taskJunctionHash) {
        Add-Check 'validator rejects a task junction before reading or mutating its external target'
    } else {
        Add-Failure ("task junction should fail closed, got: {0}" -f ($taskJunctionResult.Output -join ' | '))
    }
    Remove-Item -LiteralPath $taskJunctionPath -Force

    $workspaceRootTarget = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-validator-root-target-' + [guid]::NewGuid().ToString('N'))
    $workspaceRootJunction = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-lite-validator-root-link-' + [guid]::NewGuid().ToString('N'))
    $rootJunctionTask = 'lite-validator-root-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $rootJunctionTaskDir = Join-Path (Join-Path $workspaceRootTarget 'docs\tasks') $rootJunctionTask
    $createdTaskDirs += @($workspaceRootJunction, $workspaceRootTarget)
    New-Item -ItemType Directory -Path $rootJunctionTaskDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $rootJunctionTaskDir 'plan.md') -Content (New-PlanContent -TaskId $rootJunctionTask -Stage 'PLAN' -Tool 'codex')
    New-Item -ItemType Junction -Path $workspaceRootJunction -Target $workspaceRootTarget | Out-Null
    $rootJunctionResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $rootJunctionTask -RepoRoot $RepoRoot -WorkspaceRoot $workspaceRootJunction
    if ($rootJunctionResult.ExitCode -ne 0 -and ($rootJunctionResult.Output -join "`n") -match 'reparse point') {
        Add-Check 'validator rejects a reparse-point WorkspaceRoot itself'
    } else {
        Add-Failure ("reparse-point WorkspaceRoot should fail closed, got: {0}" -f ($rootJunctionResult.Output -join ' | '))
    }
    Remove-Item -LiteralPath $workspaceRootJunction -Force

    $reviewContractCases = @(
        [pscustomobject]@{
            Suffix = 'duplicate-verdict'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- verdict: revise
- findings: none
- next: none
'@
        }
        [pscustomobject]@{
            Suffix = 'mixed-findings'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- findings:
  - P1: duplicate findings must fail
- next: none
'@
        }
        [pscustomobject]@{
            Suffix = 'inline-none-nested-finding'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
  - P1: inline none cannot hide a blocking finding
- next: none
'@
        }
        [pscustomobject]@{
            Suffix = 'inline-none-nested-text'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
  ordinary nested text is also a mixed findings form
- next: none
'@
        }
        [pscustomobject]@{
            Suffix = 'pass-blocking'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings:
  - P1: blocking finding contradicts pass
- next: none
'@
        }
        [pscustomobject]@{
            Suffix = 'revise-none'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: revise
- findings: none
- next: none
'@
        }
        [pscustomobject]@{
            Suffix = 'pass-advisory'
            ShouldPass = $true
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings:
  - P2: advisory finding is non-blocking
  - P3: minor finding is non-blocking
- next: text outside findings may mention P1: without becoming a finding
'@
        }
        [pscustomobject]@{
            Suffix = 'history-superseded'
            ShouldPass = $true
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings:
  - P1: historical contradiction is retained
- next: superseded

### Run 2 · 2026-04-09 10:10 · runner: Codex
- verdict: pass
- findings: none
- next: proceed
'@
        }
        [pscustomobject]@{
            Suffix = 'hidden-run-fence'
            ShouldPass = $false
            Runs = @'
~~~text
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: proceed
~~~
'@
        }
        [pscustomobject]@{
            Suffix = 'hidden-fields-comment'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
<!--
- verdict: pass
- findings: none
- next: proceed
-->
'@
        }
        [pscustomobject]@{
            Suffix = 'runner-empty-link'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: [](https://example.test/hidden)
- verdict: pass
- findings: none
- next: proceed
'@
        }
        [pscustomobject]@{
            Suffix = 'next-empty-link'
            ShouldPass = $false
            Runs = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- findings: none
- next: [](https://example.test/hidden)
'@
        }
    )
    $reviewContractMatrixPassed = $true
    foreach ($reviewCase in $reviewContractCases) {
        $taskReviewContract = 'lite-review-' + $reviewCase.Suffix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskReviewContractDir = Join-Path $taskBase $taskReviewContract
        $createdTaskDirs += $taskReviewContractDir
        New-Item -ItemType Directory -Path $taskReviewContractDir -Force | Out-Null
        Write-Utf8Bom -Path (Join-Path $taskReviewContractDir 'plan.md') -Content (New-PlanContent -TaskId $taskReviewContract -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $reviewCase.Runs)
        $reviewContractResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskReviewContract -RepoRoot $RepoRoot
        if (($reviewContractResult.ExitCode -eq 0) -ne $reviewCase.ShouldPass) {
            $reviewContractMatrixPassed = $false
        }
    }
    if ($reviewContractMatrixPassed) {
        Add-Check 'review grammar and latest verdict/findings consistency matrix fail closed without scanning historical or next text'
    } else {
        Add-Failure 'review grammar and latest consistency matrix should enforce duplicate, blocking, advisory, and historical cases'
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

    $taskQualityHistorical = 'lite-validator-quality-history-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskQualityHistoricalDir = Join-Path $taskBase $taskQualityHistorical
    $createdTaskDirs += $taskQualityHistoricalDir
    New-Item -ItemType Directory -Path $taskQualityHistoricalDir -Force | Out-Null
    $qualityHistoricalRuns = @"
### Run 1 · 2026-04-09 10:00 · runner: Codex
- verdict: pass
- score.completeness: 50
- score.consistency: 50
- score.accuracy: 50
- score.depth: 50
- findings: none
- next: superseded

### Run 2 · 2026-04-09 10:10 · runner: Codex
- verdict: pass
- score.completeness: 88
- score.consistency: 82
- score.accuracy: 90
- score.depth: 84
- findings: none
- next: proceed
"@
    Write-Utf8Bom -Path (Join-Path $taskQualityHistoricalDir 'plan.md') -Content (New-PlanContent -TaskId $taskQualityHistorical -Stage 'PLAN_REVIEW' -Tool 'codex' -PlanReviewRuns $qualityHistoricalRuns)
    $qualityHistoricalResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskQualityHistorical -RepoRoot $RepoRoot -Quality
    if ($qualityHistoricalResult.ExitCode -eq 0 -and ($qualityHistoricalResult.Output -join "`n") -match 'historical; -Quality only evaluates the latest run') {
        Add-Check 'historical quality contradictions are warning-only while latest run passes'
    } else {
        Add-Failure ("historical quality contradictions should not fail -Quality, got: {0}" -f ($qualityHistoricalResult.Output -join ' | '))
    }

    $taskPendingLedger = 'lite-validator-pending-ledger-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskPendingLedgerDir = Join-Path $taskBase $taskPendingLedger
    $createdTaskDirs += $taskPendingLedgerDir
    New-Item -ItemType Directory -Path $taskPendingLedgerDir -Force | Out-Null
    $pendingLedgerClarification = @"
- 验收标准: validator blocks unresolved decisions.
- 非目标: no unrelated changes.
- 受影响目录: scripts/, tests/
- 回滚策略: revert the task.
- ui: not-applicable
- clarification_ledger:
  - category: 验证证据
    question: 是否接受当前覆盖范围？
    evidence: pending user decision
    recommended_answer: accept the documented scope
    decision: pending
    impact: tests
"@
    Write-Utf8Bom -Path (Join-Path $taskPendingLedgerDir 'plan.md') -Content (New-PlanContent -TaskId $taskPendingLedger -Stage 'PLAN' -Tool 'codex' -ConfirmationStatus 'draft' -ClarificationBody $pendingLedgerClarification)
    $pendingLedgerResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskPendingLedger -RepoRoot $RepoRoot
    if ($pendingLedgerResult.ExitCode -ne 0 -and ($pendingLedgerResult.Output -join "`n") -match 'pending decision') {
        Add-Check 'pending clarification ledger decision blocks validator'
    } else {
        Add-Failure ("pending clarification ledger decision should block validator, got: {0}" -f ($pendingLedgerResult.Output -join ' | '))
    }

    $ledgerHeader = @(
        '- 验收标准: validator parses every ledger item.'
        '- 非目标: no unrelated changes.'
        '- 受影响目录: scripts/, tests/'
        '- 回滚策略: revert the task.'
        '- ui: not-applicable'
        '- clarification_ledger:'
    )
    $validLedgerLines = @(
        '  - category: 目标/验收'
        '    question: accept?'
        '    evidence: yes'
        '    recommended_answer: accept'
        '    decision: accepted'
        '    impact: tests'
        '  - category: 非目标'
        '    question: reject?'
        '    evidence: yes'
        '    recommended_answer: reject'
        '    decision: rejected'
        '    impact: none'
    )
    $taskValidLedger = 'lite-validator-valid-ledger-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskValidLedgerDir = Join-Path $taskBase $taskValidLedger
    $createdTaskDirs += $taskValidLedgerDir
    New-Item -ItemType Directory -Path $taskValidLedgerDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskValidLedgerDir 'plan.md') -Content (New-PlanContent -TaskId $taskValidLedger -Stage 'PLAN' -Tool 'codex' -ClarificationBody (@($ledgerHeader + $validLedgerLines) -join "`r`n"))
    $validLedgerResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskValidLedger -RepoRoot $RepoRoot
    if ($validLedgerResult.ExitCode -eq 0) {
        Add-Check 'accepted and rejected clarification ledger items pass strict item parsing'
    } else {
        Add-Failure ("valid clarification ledger should pass, got: {0}" -f ($validLedgerResult.Output -join ' | '))
    }

    $invalidLedgerCases = @(
        [pscustomobject]@{
            Suffix = 'trailing'
            Expected = 'decision should be exactly'
            Lines = @(
                '  - category: 验证证据'
                '    decision: pending # still unresolved'
                '  - category: 非目标'
                '    decision: accepted'
            )
        }
        [pscustomobject]@{
            Suffix = 'missing'
            Expected = 'should contain exactly one decision'
            Lines = @('  - category: 验证证据', '    evidence: missing decision')
        }
        [pscustomobject]@{
            Suffix = 'duplicate'
            Expected = 'should contain exactly one decision'
            Lines = @('  - category: 验证证据', '    decision: accepted', '    decision: rejected')
        }
    )
    $invalidLedgerCasesRejected = $true
    foreach ($ledgerCase in $invalidLedgerCases) {
        $taskInvalidLedger = 'lite-validator-ledger-' + $ledgerCase.Suffix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskInvalidLedgerDir = Join-Path $taskBase $taskInvalidLedger
        $createdTaskDirs += $taskInvalidLedgerDir
        New-Item -ItemType Directory -Path $taskInvalidLedgerDir -Force | Out-Null
        Write-Utf8Bom -Path (Join-Path $taskInvalidLedgerDir 'plan.md') -Content (New-PlanContent -TaskId $taskInvalidLedger -Stage 'PLAN' -Tool 'codex' -ClarificationBody (@($ledgerHeader + $ledgerCase.Lines) -join "`r`n"))
        $invalidLedgerResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInvalidLedger -RepoRoot $RepoRoot
        if ($invalidLedgerResult.ExitCode -eq 0 -or ($invalidLedgerResult.Output -join "`n") -notmatch [regex]::Escape($ledgerCase.Expected)) {
            $invalidLedgerCasesRejected = $false
        }
    }
    if ($invalidLedgerCasesRejected) {
        Add-Check 'ledger items with trailing, missing, or duplicate decisions fail closed'
    } else {
        Add-Failure 'ledger items with trailing, missing, or duplicate decisions should fail strict parsing'
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

    $taskInvalidStageCase = 'lite-validator-stage-case-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInvalidStageCaseDir = Join-Path $taskBase $taskInvalidStageCase
    $createdTaskDirs += $taskInvalidStageCaseDir
    New-Item -ItemType Directory -Path $taskInvalidStageCaseDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskInvalidStageCaseDir 'plan.md') -Content (New-PlanContent -TaskId $taskInvalidStageCase -Stage 'plan' -Tool 'codex')
    $invalidStageCaseResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInvalidStageCase -RepoRoot $RepoRoot
    if ($invalidStageCaseResult.ExitCode -ne 0 -and ($invalidStageCaseResult.Output -join "`n") -match 'plan.md stage should be one of') {
        Add-Check 'case-variant stage values are rejected'
    } else {
        Add-Failure ("case-variant stage should fail validator: {0}" -f ($invalidStageCaseResult.Output -join ' | '))
    }

    $taskInvalidIdCase = 'lite-validator-id-case-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInvalidIdCaseDir = Join-Path $taskBase $taskInvalidIdCase
    $createdTaskDirs += $taskInvalidIdCaseDir
    New-Item -ItemType Directory -Path $taskInvalidIdCaseDir -Force | Out-Null
    $invalidIdCasePlan = (New-PlanContent -TaskId $taskInvalidIdCase -Stage 'PLAN' -Tool 'codex').Replace(
        "task_id: $taskInvalidIdCase",
        "task_id: $($taskInvalidIdCase.ToUpperInvariant())"
    )
    Write-Utf8Bom -Path (Join-Path $taskInvalidIdCaseDir 'plan.md') -Content $invalidIdCasePlan
    $invalidIdCaseResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInvalidIdCase -RepoRoot $RepoRoot
    if ($invalidIdCaseResult.ExitCode -ne 0 -and ($invalidIdCaseResult.Output -join "`n") -match 'plan.md task_id should be') {
        Add-Check 'case-variant task_id values are rejected'
    } else {
        Add-Failure ("case-variant task_id should fail validator: {0}" -f ($invalidIdCaseResult.Output -join ' | '))
    }

    $taskInvalidTool = 'lite-validator-tool-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskInvalidToolDir = Join-Path $taskBase $taskInvalidTool
    $createdTaskDirs += $taskInvalidToolDir
    New-Item -ItemType Directory -Path $taskInvalidToolDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskInvalidToolDir 'plan.md') -Content (New-PlanContent -TaskId $taskInvalidTool -Stage 'PLAN' -Tool 'CODEX')
    $invalidToolResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInvalidTool -RepoRoot $RepoRoot
    if ($invalidToolResult.ExitCode -ne 0 -and ($invalidToolResult.Output -join "`n") -match 'plan.md tool should be one of') {
        Add-Check 'case-variant tool values are rejected'
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

    $taskHiddenImplementation = 'lite-validator-hidden-implementation-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskHiddenImplementationDir = Join-Path $taskBase $taskHiddenImplementation
    $createdTaskDirs += $taskHiddenImplementationDir
    New-Item -ItemType Directory -Path $taskHiddenImplementationDir -Force | Out-Null
    $hiddenImplementation = @'
### Run 1 · 2026-04-09 10:00 · runner: Codex
- changed: [](https://example.test/hidden)
- tests: targeted regression
- risks: none
- next: CODE_REVIEW
'@
    Write-Utf8Bom -Path (Join-Path $taskHiddenImplementationDir 'plan.md') -Content (New-PlanContent -TaskId $taskHiddenImplementation -Stage 'IMPLEMENT' -Tool 'codex' -PlanReviewRuns $planReviewPass -ImplementationRuns $hiddenImplementation)
    $hiddenImplementationResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskHiddenImplementation -RepoRoot $RepoRoot
    if ($hiddenImplementationResult.ExitCode -ne 0 -and
        ($hiddenImplementationResult.Output -join "`n") -match 'Implementation Notes Run 1 should contain - changed:') {
        Add-Check 'Markdown-only Implementation Notes values are rejected'
    } else {
        Add-Failure ("Markdown-only Implementation Notes value should fail validator: {0}" -f ($hiddenImplementationResult.Output -join ' | '))
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

    $taskSameMinuteImplement = 'lite-validator-same-minute-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskSameMinuteImplementDir = Join-Path $taskBase $taskSameMinuteImplement
    $createdTaskDirs += $taskSameMinuteImplementDir
    New-Item -ItemType Directory -Path $taskSameMinuteImplementDir -Force | Out-Null
    $sameMinuteImplementation = @"
### Run 1 · 2026-04-09 10:30 · runner: Codex
- changed: follow-up implementation
- tests: targeted regression
- risks: none
- next: return to CODE_REVIEW
"@
    Write-Utf8Bom -Path (Join-Path $taskSameMinuteImplementDir 'plan.md') -Content (New-PlanContent -TaskId $taskSameMinuteImplement -Stage 'IMPLEMENT' -Tool 'codex' -PlanReviewRuns $planReviewPass -ImplementationRuns $sameMinuteImplementation -CodeReviewRuns $reviseCodeReview)
    $sameMinuteImplementResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskSameMinuteImplement -RepoRoot $RepoRoot
    if ($sameMinuteImplementResult.ExitCode -eq 0) {
        Add-Check 'same-minute implementation evidence does not false-fail freshness'
    } else {
        Add-Failure ("same-minute implementation evidence should not false-fail freshness, got: {0}" -f ($sameMinuteImplementResult.Output -join ' | '))
    }

    $newFreshnessImplementationRun = {
        param(
            [int]$Number,
            [string]$When
        )
@"
### Run $Number · $When · runner: Codex
- changed: freshness fixture implementation $Number
- tests: direct validator fixture
- risks: none
- next: hand off to CODE_REVIEW
"@
    }
    $newFreshnessReviewRun = {
        param(
            [int]$Number,
            [string]$When
        )
@"
### Run $Number · $When · runner: Codex
- verdict: pass
- findings: none
- next: continue workflow
"@
    }

    $freshnessPlanReview = & $newFreshnessReviewRun -Number 1 -When '2026-07-10 09:00'
    $preFailImplementation = & $newFreshnessImplementationRun -Number 1 -When '2026-07-10 09:30'
    $preFailCodeReview = & $newFreshnessReviewRun -Number 1 -When '2026-07-10 10:00'
    $postFailImplementation = & $newFreshnessImplementationRun -Number 2 -When '2026-07-10 11:01'
    $initialFailReworkImplementation = @($preFailImplementation, $postFailImplementation) -join "`r`n"
    $freshnessContractFailures = @()

    $initialFailReworkCases = @(
        [pscustomobject]@{ Name = 'initial-fail-rework-missing-report'; Conclusion = $null }
        [pscustomobject]@{ Name = 'initial-fail-rework-non-fail-report'; Conclusion = 'pass' }
    )
    foreach ($case in $initialFailReworkCases) {
        $taskFreshness = 'fresh-initial-' + $case.Name.Substring('initial-fail-rework-'.Length) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskFreshnessDir = Join-Path $taskBase $taskFreshness
        $createdTaskDirs += $taskFreshnessDir
        New-Item -ItemType Directory -Path $taskFreshnessDir -Force | Out-Null
        Write-Utf8Bom -Path (Join-Path $taskFreshnessDir 'plan.md') -Content (New-PlanContent `
            -TaskId $taskFreshness `
            -Stage 'IMPLEMENT' `
            -Tool 'codex' `
            -PlanReviewRuns $freshnessPlanReview `
            -ImplementationRuns $initialFailReworkImplementation `
            -CodeReviewRuns $preFailCodeReview)
        if ($null -ne $case.Conclusion) {
            Write-Utf8Bom -Path (Join-Path $taskFreshnessDir 'test.md') -Content (New-TestReport `
                -Conclusion $case.Conclusion `
                -ExecutedAt '2026-07-10T11:00:00+08:00')
        }

        $freshnessResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskFreshness -RepoRoot $RepoRoot
        $freshnessOutput = $freshnessResult.Output -join "`n"
        if ($freshnessResult.ExitCode -eq 0) {
            $freshnessContractFailures += ($case.Name + ' was accepted')
        } elseif ($freshnessOutput -notmatch 'IMPLEMENT after TEST fail requires test\.md Conclusion: fail') {
            $freshnessContractFailures += ($case.Name + ' lacked the fail-report diagnostic')
        }
    }

    $freshnessCases = @(
        [pscustomobject]@{ Name = 'fail-evidence-to-implementation-earlier'; Edge = 'fail-implementation'; Candidate = '2026-07-10 10:59'; Accept = $false; Diagnostic = 'IMPLEMENT after TEST fail requires a fresh Implementation Notes run' }
        [pscustomobject]@{ Name = 'fail-evidence-to-implementation-same-minute'; Edge = 'fail-implementation'; Candidate = '2026-07-10 11:00'; Accept = $true; Diagnostic = '' }
        [pscustomobject]@{ Name = 'fail-evidence-to-implementation-later'; Edge = 'fail-implementation'; Candidate = '2026-07-10 11:01'; Accept = $true; Diagnostic = '' }
        [pscustomobject]@{ Name = 'implementation-to-code-review-earlier'; Edge = 'implementation-review'; Candidate = '2026-07-10 10:59'; Accept = $false; Diagnostic = 'CODE_REVIEW requires a fresh Code Review run after latest Implementation Notes' }
        [pscustomobject]@{ Name = 'implementation-to-code-review-same-minute'; Edge = 'implementation-review'; Candidate = '2026-07-10 11:00'; Accept = $true; Diagnostic = '' }
        [pscustomobject]@{ Name = 'implementation-to-code-review-later'; Edge = 'implementation-review'; Candidate = '2026-07-10 11:01'; Accept = $true; Diagnostic = '' }
        [pscustomobject]@{ Name = 'implementation-to-code-review-missing-implementation'; Edge = 'missing-implementation'; Candidate = ''; Accept = $false; Diagnostic = 'CODE_REVIEW requires a fresh Code Review run after latest Implementation Notes' }
        [pscustomobject]@{ Name = 'code-review-to-test-evidence-earlier'; Edge = 'review-test'; Candidate = '2026-07-10T10:59:00+08:00'; Accept = $false; Diagnostic = '(?:TEST|TEST/DONE) requires fresh TEST Evidence after latest Code Review' }
        [pscustomobject]@{ Name = 'code-review-to-test-evidence-same-minute'; Edge = 'review-test'; Candidate = '2026-07-10T11:00:00+08:00'; Accept = $true; Diagnostic = '' }
        [pscustomobject]@{ Name = 'code-review-to-test-evidence-later'; Edge = 'review-test'; Candidate = '2026-07-10T11:01:00+08:00'; Accept = $true; Diagnostic = '' }
        [pscustomobject]@{ Name = 'code-review-to-test-evidence-missing-review'; Edge = 'missing-review'; Candidate = '2026-07-10T11:00:00+08:00'; Accept = $false; Diagnostic = 'TEST/DONE requires latest Code Review verdict: pass' }
    )
    foreach ($case in $freshnessCases) {
        $taskFreshness = 'fresh-edge-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskFreshnessDir = Join-Path $taskBase $taskFreshness
        $createdTaskDirs += $taskFreshnessDir
        New-Item -ItemType Directory -Path $taskFreshnessDir -Force | Out-Null

        $stage = ''
        $implementationRuns = ''
        $codeReviewRuns = ''
        $reportConclusion = $null
        $reportExecutedAt = $null
        switch ($case.Edge) {
            'fail-implementation' {
                $stage = 'IMPLEMENT'
                $candidateImplementation = & $newFreshnessImplementationRun -Number 2 -When $case.Candidate
                $implementationRuns = @($preFailImplementation, $candidateImplementation) -join "`r`n"
                $codeReviewRuns = $preFailCodeReview
                $reportConclusion = 'fail'
                $reportExecutedAt = '2026-07-10T11:00:00+08:00'
            }
            'implementation-review' {
                $stage = 'CODE_REVIEW'
                $implementationRuns = & $newFreshnessImplementationRun -Number 1 -When '2026-07-10 11:00'
                $codeReviewRuns = & $newFreshnessReviewRun -Number 1 -When $case.Candidate
            }
            'missing-implementation' {
                $stage = 'CODE_REVIEW'
                $codeReviewRuns = & $newFreshnessReviewRun -Number 1 -When '2026-07-10 11:00'
            }
            'review-test' {
                $stage = 'TEST'
                $implementationRuns = & $newFreshnessImplementationRun -Number 1 -When '2026-07-10 10:30'
                $codeReviewRuns = & $newFreshnessReviewRun -Number 1 -When '2026-07-10 11:00'
                $reportConclusion = 'pass'
                $reportExecutedAt = $case.Candidate
            }
            'missing-review' {
                $stage = 'TEST'
                $implementationRuns = & $newFreshnessImplementationRun -Number 1 -When '2026-07-10 10:30'
                $reportConclusion = 'pass'
                $reportExecutedAt = $case.Candidate
            }
            default {
                throw ('unknown freshness edge: {0}' -f $case.Edge)
            }
        }

        Write-Utf8Bom -Path (Join-Path $taskFreshnessDir 'plan.md') -Content (New-PlanContent `
            -TaskId $taskFreshness `
            -Stage $stage `
            -Tool 'codex' `
            -PlanReviewRuns $freshnessPlanReview `
            -ImplementationRuns $implementationRuns `
            -CodeReviewRuns $codeReviewRuns)
        if ($null -ne $reportConclusion) {
            Write-Utf8Bom -Path (Join-Path $taskFreshnessDir 'test.md') -Content (New-TestReport `
                -Conclusion $reportConclusion `
                -ExecutedAt $reportExecutedAt)
        }

        $freshnessResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskFreshness -RepoRoot $RepoRoot
        $freshnessOutput = $freshnessResult.Output -join "`n"
        if ($case.Accept) {
            if ($freshnessResult.ExitCode -ne 0 -or $freshnessOutput -notmatch 'STATUS: PASS') {
                $freshnessContractFailures += ($case.Name + ' was rejected: ' + ($freshnessResult.Output -join ' | '))
            }
        } elseif ($freshnessResult.ExitCode -eq 0) {
            $freshnessContractFailures += ($case.Name + ' was accepted')
        } elseif ($freshnessOutput -notmatch $case.Diagnostic) {
            $freshnessContractFailures += ($case.Name + ' lacked the edge diagnostic: ' + ($freshnessResult.Output -join ' | '))
        }
    }

    if ($freshnessContractFailures.Count -eq 0) {
        Add-Check 'TEST fail rework requires its report and all three adjacent evidence edges fail closed on missing or earlier predecessors'
    } else {
        Add-Failure ("TEST failure freshness matrix failed: {0}" -f ($freshnessContractFailures -join '; '))
    }

    $taskCaseHandoff = 'lite-validator-case-handoff-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskCaseHandoffDir = Join-Path $taskBase $taskCaseHandoff
    $createdTaskDirs += $taskCaseHandoffDir
    New-Item -ItemType Directory -Path $taskCaseHandoffDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskCaseHandoffDir 'plan.md') -Content (New-PlanContent -TaskId $taskCaseHandoff -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
    $caseHandoffReport = (New-TestReport -Conclusion 'pass').Replace('## Handoff', '## handoff')
    Write-Utf8Bom -Path (Join-Path $taskCaseHandoffDir 'test.md') -Content $caseHandoffReport
    $caseHandoffResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskCaseHandoff -RepoRoot $RepoRoot
    if ($caseHandoffResult.ExitCode -ne 0 -and
        ($caseHandoffResult.Output -join "`n") -match 'test\.md sections should be') {
        Add-Check 'machine-readable section names are case-exact'
    } else {
        Add-Failure ("case-variant Handoff should fail validator: {0}" -f ($caseHandoffResult.Output -join ' | '))
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

    $taskHiddenTestValues = 'lite-validator-hidden-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskHiddenTestValuesDir = Join-Path $taskBase $taskHiddenTestValues
    $createdTaskDirs += $taskHiddenTestValuesDir
    New-Item -ItemType Directory -Path $taskHiddenTestValuesDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskHiddenTestValuesDir 'plan.md') -Content (New-PlanContent -TaskId $taskHiddenTestValues -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
    $hiddenTestValues = (New-TestReport -Conclusion 'pass').Replace(
        '- command: `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`',
        '- command: [](https://example.test/hidden)'
    ).Replace(
        '- delivery: 提供当前 task 的验证结论。',
        '- delivery: [](https://example.test/hidden)'
    ).Replace(
        '- follow_up: none',
        '- follow_up: [](https://example.test/hidden)'
    )
    Write-Utf8Bom -Path (Join-Path $taskHiddenTestValuesDir 'test.md') -Content $hiddenTestValues
    $hiddenTestValuesResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskHiddenTestValues -RepoRoot $RepoRoot
    if ($hiddenTestValuesResult.ExitCode -ne 0 -and
        ($hiddenTestValuesResult.Output -join "`n") -match 'Handoff should contain|Evidence should contain') {
        Add-Check 'Markdown-only TEST machine values are rejected'
    } else {
        Add-Failure ("Markdown-only TEST values should fail validator: {0}" -f ($hiddenTestValuesResult.Output -join ' | '))
    }

    $taskMissingEvidence = 'lite-validator-evidence-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskMissingEvidenceDir = Join-Path $taskBase $taskMissingEvidence
    $createdTaskDirs += $taskMissingEvidenceDir
    New-Item -ItemType Directory -Path $taskMissingEvidenceDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskMissingEvidenceDir 'plan.md') -Content (New-PlanContent -TaskId $taskMissingEvidence -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
    Write-Utf8Bom -Path (Join-Path $taskMissingEvidenceDir 'test.md') -Content (New-TestReport -Conclusion 'pass' -IncludeEvidence $false)
    $missingEvidenceResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskMissingEvidence -RepoRoot $RepoRoot
    if ($missingEvidenceResult.ExitCode -ne 0 -and ($missingEvidenceResult.Output -join "`n") -match 'Evidence should contain') {
        Add-Check 'missing test evidence fields are rejected'
    } else {
        Add-Failure ("missing test evidence should fail validator, got: {0}" -f ($missingEvidenceResult.Output -join ' | '))
    }

    $invalidEvidenceCases = @(
        [pscustomobject]@{ Suffix = 'exit-text'; Old = '- exit_code: 0'; New = '- exit_code: banana'; Expected = 'exit_code should be an integer' }
        [pscustomobject]@{ Suffix = 'exit-nonzero'; Old = '- exit_code: 0'; New = '- exit_code: 1'; Expected = 'passing test.md requires Evidence exit_code: 0' }
        [pscustomobject]@{ Suffix = 'time'; Old = '- executed_at: 2026-07-10T10:00:00+08:00'; New = '- executed_at: never'; Expected = 'executed_at should be an ISO-8601' }
        [pscustomobject]@{ Suffix = 'revision'; Old = '- revision: 0123456789abcdef0123456789abcdef01234567'; New = '- revision: imaginary'; Expected = 'revision should be a 7-40 character git hash' }
        [pscustomobject]@{ Suffix = 'missing-path'; Old = '- evidence_path: scripts/validate-lite-artifacts.ps1'; New = '- evidence_path: docs/missing-evidence.txt'; Expected = 'evidence_path should name an existing workspace file' }
        [pscustomobject]@{ Suffix = 'escape-path'; Old = '- evidence_path: scripts/validate-lite-artifacts.ps1'; New = '- evidence_path: ../outside-evidence.txt'; Expected = 'evidence_path should name an existing workspace file' }
        [pscustomobject]@{ Suffix = 'duplicate'; Old = '- revision: 0123456789abcdef0123456789abcdef01234567'; New = "- revision: 0123456789abcdef0123456789abcdef01234567`r`n- revision: 89abcdef0123456789abcdef0123456789abcdef"; Expected = 'exactly one non-empty - revision:' }
    )
    $invalidEvidenceCasesRejected = $true
    foreach ($evidenceCase in $invalidEvidenceCases) {
        $taskInvalidEvidence = 'lite-validator-evidence-' + $evidenceCase.Suffix + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $taskInvalidEvidenceDir = Join-Path $taskBase $taskInvalidEvidence
        $createdTaskDirs += $taskInvalidEvidenceDir
        New-Item -ItemType Directory -Path $taskInvalidEvidenceDir -Force | Out-Null
        Write-Utf8Bom -Path (Join-Path $taskInvalidEvidenceDir 'plan.md') -Content (New-PlanContent -TaskId $taskInvalidEvidence -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
        $invalidEvidenceReport = (New-TestReport -Conclusion 'pass').Replace($evidenceCase.Old, $evidenceCase.New)
        Write-Utf8Bom -Path (Join-Path $taskInvalidEvidenceDir 'test.md') -Content $invalidEvidenceReport
        $invalidEvidenceResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskInvalidEvidence -RepoRoot $RepoRoot
        if ($invalidEvidenceResult.ExitCode -eq 0 -or ($invalidEvidenceResult.Output -join "`n") -notmatch [regex]::Escape($evidenceCase.Expected)) {
            $invalidEvidenceCasesRejected = $false
        }
    }
    if ($invalidEvidenceCasesRejected) {
        Add-Check 'arbitrary, duplicate, nonzero-pass, missing, and escaping Evidence values fail closed'
    } else {
        Add-Failure 'invalid TEST Evidence semantics should fail validator'
    }

    $taskDirtyEvidence = 'lite-validator-evidence-dirty-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskDirtyEvidenceDir = Join-Path $taskBase $taskDirtyEvidence
    $createdTaskDirs += $taskDirtyEvidenceDir
    New-Item -ItemType Directory -Path $taskDirtyEvidenceDir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskDirtyEvidenceDir 'plan.md') -Content (New-PlanContent -TaskId $taskDirtyEvidence -Stage 'DONE' -Tool 'none' -PlanReviewRuns $planReviewPass -ImplementationRuns $implementationPass -CodeReviewRuns $codeReviewPass)
    $dirtyRevision = 'dirty:' + ('a' * 64)
    $dirtyEvidenceReport = (New-TestReport -Conclusion 'pass').Replace('0123456789abcdef0123456789abcdef01234567', $dirtyRevision)
    Write-Utf8Bom -Path (Join-Path $taskDirtyEvidenceDir 'test.md') -Content $dirtyEvidenceReport
    $dirtyEvidenceResult = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskDirtyEvidence -RepoRoot $RepoRoot
    if ($dirtyEvidenceResult.ExitCode -eq 0) {
        Add-Check 'dirty:<64hex> is accepted as an explicit dirty workspace revision digest'
    } else {
        Add-Failure ("dirty revision digest should pass validator, got: {0}" -f ($dirtyEvidenceResult.Output -join ' | '))
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
