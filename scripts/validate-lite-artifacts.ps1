# 校验单个 `docs/tasks/<task-id>/` 任务目录是否满足 harness-lite 文档契约。
# 这份脚本只覆盖当前主线真正依赖的结构，不再兼容 legacy artifact 语义。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AllowedStages = @("PLAN", "PLAN_REVIEW", "IMPLEMENT", "CODE_REVIEW", "TEST", "DONE")
$script:AllowedTools = @("claudecode", "codex", "gemini")
$script:PlanSections = @(
    "Clarification",
    "User Confirmation",
    "Plan",
    "Verification",
    "Risks",
    "Plan Review",
    "Implementation Notes",
    "Code Review"
)
$script:TestSections = @(
    "Summary",
    "Scope",
    "Inputs Reviewed",
    "Test Approach",
    "Findings",
    "Risks / Gaps",
    "Conclusion",
    "Handoff"
)
$script:SpecSections = @("Gap", "Constraint", "Verification Delta")

function Add-Check {
    <#
    .SYNOPSIS
    记录一条通过项。
    .DESCRIPTION
    所有检查结果统一汇总输出，方便直接看 validator 覆盖了哪些 lite 契约。
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
    记录一条失败项。
    .DESCRIPTION
    失败项不会中断后续检查，脚本末尾统一返回 FAIL，方便一次看全契约漂移。
    .PARAMETER Message
    失败说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Failures += $Message
}

function Get-Frontmatter {
    <#
    .SYNOPSIS
    解析 markdown 顶部 frontmatter。
    .DESCRIPTION
    harness-lite 只接受位于文档开头、由两段 `---` 包住的最小 YAML 样式 frontmatter。
    .PARAMETER Content
    完整 markdown 文本。
    .OUTPUTS
    PSCustomObject。
    #>
    param([string]$Content)

    $match = [regex]::Match($Content, '\A---\r?\n(.*?)\r?\n---\r?\n', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw "missing frontmatter block"
    }

    $fields = [ordered]@{}
    foreach ($line in ($match.Groups[1].Value -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -notmatch '^([a-z_]+):\s*(.+)$') {
            throw "invalid frontmatter line: $line"
        }

        $fields[$matches[1]] = $matches[2].Trim()
    }

    [pscustomobject]@{
        Fields = $fields
        Body = $Content.Substring($match.Length)
    }
}

function Get-Sections {
    <#
    .SYNOPSIS
    提取二级标题 section。
    .DESCRIPTION
    validator 只认 `## ` section；这和 lite 文档契约里的机器可读标题层级保持一致。
    .PARAMETER Content
    去掉 frontmatter 之后的 markdown 正文。
    .OUTPUTS
    Object[]。
    #>
    param([string]$Content)

    $sections = @()
    $matches = [regex]::Matches($Content, '(?ms)^##\s+(.+?)\r?\n(.*?)(?=^##\s+|\z)')
    foreach ($match in $matches) {
        $sections += [pscustomobject]@{
            Name = $match.Groups[1].Value.Trim()
            Content = $match.Groups[2].Value.Trim()
        }
    }

    return $sections
}

function Assert-SectionOrder {
    <#
    .SYNOPSIS
    断言 section 完整且顺序正确。
    .DESCRIPTION
    lite 主线依赖固定 section 名称和顺序；这里只检查当前 guide 里规定的最小集合。
    .PARAMETER Sections
    解析出来的 section 列表。
    .PARAMETER Expected
    预期 section 名称数组。
    .PARAMETER Label
    文档标签。
    .OUTPUTS
    None。
    #>
    param(
        [object[]]$Sections,
        [string[]]$Expected,
        [string]$Label
    )

    $actual = @($Sections | ForEach-Object { $_.Name })
    if (($actual -join '|') -eq ($Expected -join '|')) {
        Add-Check ("{0} sections complete and ordered" -f $Label)
    } else {
        Add-Failure ('{0} sections should be [{1}], got [{2}]' -f $Label, ($Expected -join ' -> '), ($actual -join ' -> '))
    }
}

function Get-SectionContent {
    <#
    .SYNOPSIS
    返回指定 section 正文。
    .DESCRIPTION
    section 不存在时返回空字符串，调用方自行决定这是允许状态还是失败。
    .PARAMETER Sections
    section 列表。
    .PARAMETER Name
    section 名称。
    .OUTPUTS
    String。
    #>
    param(
        [object[]]$Sections,
        [string]$Name
    )

    foreach ($section in $Sections) {
        if ($section.Name -eq $Name) {
            return $section.Content
        }
    }

    return ""
}

function Get-RunBlocks {
    <#
    .SYNOPSIS
    解析 append-only run。
    .DESCRIPTION
    review / implementation sections 都用统一的 `### Run N · YYYY-MM-DD HH:mm · runner: X` 标题。
    .PARAMETER SectionContent
    section 正文。
    .OUTPUTS
    Object[]。
    #>
    param([string]$SectionContent)

    if ([string]::IsNullOrWhiteSpace($SectionContent)) {
        return @()
    }

    $runs = @()
    $matches = [regex]::Matches($SectionContent, '(?ms)^###\s+Run\s+(\d+)\s+·\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+·\s+runner:\s+(.+?)\r?\n(.*?)(?=^###\s+Run\s+\d+|\z)')
    foreach ($match in $matches) {
        $runs += [pscustomobject]@{
            Number = [int]$match.Groups[1].Value
            When = [datetime]::ParseExact($match.Groups[2].Value, 'yyyy-MM-dd HH:mm', $null)
            Runner = $match.Groups[3].Value.Trim()
            Body = $match.Groups[4].Value.Trim()
        }
    }

    return $runs
}

function Assert-RunSequence {
    <#
    .SYNOPSIS
    断言 run 编号连续。
    .DESCRIPTION
    append-only 历史不能跳号也不能回退，否则后续 review / implement 证据无法稳定比较。
    .PARAMETER Runs
    run 列表。
    .PARAMETER Label
    section 标签。
    .OUTPUTS
    None。
    #>
    param(
        [object[]]$Runs,
        [string]$Label
    )

    for ($index = 0; $index -lt $Runs.Count; $index++) {
        if ($Runs[$index].Number -ne ($index + 1)) {
            Add-Failure ("{0} run numbers should start from 1 and increase by 1" -f $Label)
            return
        }
    }

    Add-Check ("{0} run numbering is append-only" -f $Label)
}

function Assert-ReviewRuns {
    <#
    .SYNOPSIS
    校验 Plan Review / Code Review run 格式。
    .DESCRIPTION
    review run 必须包含 `verdict`、`findings`、`next`，并禁止旧式空 severity 标题。
    .PARAMETER SectionContent
    section 正文。
    .PARAMETER Label
    section 标签。
    .OUTPUTS
    Object[]。
    #>
    param(
        [string]$SectionContent,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($SectionContent)) {
        Add-Check ("{0} currently empty" -f $Label)
        return @()
    }

    if ($SectionContent -match '(?m)^###\s+P[0-3]\s*$') {
        Add-Failure ('{0} should not use empty severity headings like ### P1' -f $Label)
    }

    $runs = @(Get-RunBlocks -SectionContent $SectionContent)
    if ($runs.Count -eq 0) {
        Add-Failure ('{0} should use ### Run N · ... headings' -f $Label)
        return @()
    }

    Assert-RunSequence -Runs $runs -Label $Label

    foreach ($run in $runs) {
        if ($run.Body -notmatch '(?m)^- verdict:\s*(pass|revise)\s*$') {
            Add-Failure ('{0} Run {1} should contain - verdict: pass | revise' -f $Label, $run.Number)
        }

        $hasFindingsNone = $run.Body -match '(?m)^- findings:\s*none\s*$'
        $hasFindingsList = $run.Body -match '(?m)^- findings:\s*$' -and $run.Body -match '(?m)^\s+- P[0-3]:\s+.+$'
        if (-not ($hasFindingsNone -or $hasFindingsList)) {
            Add-Failure ('{0} Run {1} should contain - findings: none or a P0-P3 findings list' -f $Label, $run.Number)
        }

        if ($run.Body -notmatch '(?m)^- next:\s+.+$') {
            Add-Failure ('{0} Run {1} should contain - next:' -f $Label, $run.Number)
        }
    }

    return $runs
}

function Assert-ImplementationRuns {
    <#
    .SYNOPSIS
    校验 Implementation Notes run 格式。
    .DESCRIPTION
    当前 lite IMPLEMENT skill 约束 `changed/tests/risks/next` 这 4 个字段。
    .PARAMETER SectionContent
    section 正文。
    .OUTPUTS
    Object[]。
    #>
    param([string]$SectionContent)

    if ([string]::IsNullOrWhiteSpace($SectionContent)) {
        Add-Check "Implementation Notes currently empty"
        return @()
    }

    $runs = @(Get-RunBlocks -SectionContent $SectionContent)
    if ($runs.Count -eq 0) {
        Add-Failure 'Implementation Notes should use ### Run N · ... headings'
        return @()
    }

    Assert-RunSequence -Runs $runs -Label "Implementation Notes"

    foreach ($run in $runs) {
        foreach ($field in @('changed', 'tests', 'risks', 'next')) {
            if ($run.Body -notmatch ("(?m)^- {0}:\s+.+" -f [regex]::Escape($field))) {
                Add-Failure ('Implementation Notes Run {0} should contain - {1}:' -f $run.Number, $field)
            }
        }
    }

    return $runs
}

function Assert-PlanContract {
    <#
    .SYNOPSIS
    校验 plan.md。
    .DESCRIPTION
    这里同时覆盖 frontmatter、section 契约，以及和当前 stage 直接相关的文档一致性规则。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER PlanPath
    plan.md 绝对路径。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$TaskId,
        [string]$PlanPath
    )

    $content = Get-Content -LiteralPath $PlanPath -Raw -Encoding utf8
    $frontmatter = Get-Frontmatter -Content $content
    $fields = $frontmatter.Fields

    $fieldNames = @($fields.Keys)
    if (($fieldNames -join '|') -eq ('task_id|stage|tool|updated')) {
        Add-Check "plan.md frontmatter fields are exact"
    } else {
        Add-Failure ('plan.md frontmatter should only contain task_id/stage/tool/updated, got [{0}]' -f ($fieldNames -join ', '))
    }

    if (($fields['task_id']) -eq $TaskId) {
        Add-Check "plan.md task_id matches task directory"
    } else {
        Add-Failure ('plan.md task_id should be [{0}], got [{1}]' -f $TaskId, $fields['task_id'])
    }

    if ($script:AllowedStages -contains $fields['stage']) {
        Add-Check "plan.md stage is legal"
    } else {
        Add-Failure ('plan.md stage should be one of [{0}], got [{1}]' -f ($script:AllowedStages -join ', '), $fields['stage'])
    }

    if ($fields['stage'] -eq 'DONE') {
        if ($fields['tool'] -eq 'none') {
            Add-Check "plan.md DONE tool is legal"
        } else {
            Add-Failure ('plan.md DONE tool should be [none], got [{0}]' -f $fields['tool'])
        }
    } elseif ($script:AllowedTools -contains $fields['tool']) {
        Add-Check "plan.md tool is legal"
    } else {
        Add-Failure ('plan.md tool should be one of [{0}], got [{1}]' -f ($script:AllowedTools -join ', '), $fields['tool'])
    }

    if (($fields['updated']) -match '^\d{4}-\d{2}-\d{2}$') {
        Add-Check "plan.md updated uses YYYY-MM-DD"
    } else {
        Add-Failure ('plan.md updated should use YYYY-MM-DD, got [{0}]' -f $fields['updated'])
    }

    $sections = Get-Sections -Content $frontmatter.Body
    Assert-SectionOrder -Sections $sections -Expected $script:PlanSections -Label "plan.md"

    $clarification = Get-SectionContent -Sections $sections -Name 'Clarification'
    foreach ($needle in @('验收标准', '非目标', '受影响目录', '回滚', 'ui:')) {
        if ($clarification -match [regex]::Escape($needle)) {
            Add-Check ('Clarification contains [{0}]' -f $needle)
        } else {
            Add-Failure ('Clarification should contain [{0}]' -f $needle)
        }
    }

    $confirmation = Get-SectionContent -Sections $sections -Name 'User Confirmation'
    if ($confirmation -match '(?m)^- status:\s*(draft|confirmed)\s*$') {
        Add-Check "User Confirmation status is machine-readable"
    } else {
        Add-Failure 'User Confirmation should contain - status: draft | confirmed'
    }

    $planBody = Get-SectionContent -Sections $sections -Name 'Plan'
    if ($planBody -match '(?m)^- .+$') {
        Add-Check "Plan contains actionable bullets"
    } else {
        Add-Failure "Plan should contain at least one bullet"
    }

    $verification = Get-SectionContent -Sections $sections -Name 'Verification'
    if ($verification -match '(?m)^- `.+`$') {
        Add-Check "Verification contains executable commands"
    } else {
        Add-Failure "Verification should contain backticked commands"
    }

    $risks = Get-SectionContent -Sections $sections -Name 'Risks'
    if (-not [string]::IsNullOrWhiteSpace($risks)) {
        Add-Check "Risks section is not empty"
    } else {
        Add-Failure "Risks section should not be empty"
    }

    $planReviewRuns = @(Assert-ReviewRuns -SectionContent (Get-SectionContent -Sections $sections -Name 'Plan Review') -Label 'Plan Review')
    $implementationRuns = @(Assert-ImplementationRuns -SectionContent (Get-SectionContent -Sections $sections -Name 'Implementation Notes'))
    $codeReviewRuns = @(Assert-ReviewRuns -SectionContent (Get-SectionContent -Sections $sections -Name 'Code Review') -Label 'Code Review')

    if ($fields['stage'] -eq 'IMPLEMENT' -and $codeReviewRuns.Count -gt 0) {
        $latestCodeReview = $codeReviewRuns[-1]
        if ($latestCodeReview.Body -match '(?m)^- verdict:\s*revise\s*$') {
            if ($implementationRuns.Count -eq 0 -or $implementationRuns[-1].When -le $latestCodeReview.When) {
                Add-Failure "IMPLEMENT after CODE_REVIEW revise requires a fresh Implementation Notes run"
            } else {
                Add-Check "IMPLEMENT has fresh evidence after latest revise"
            }
        }
    }

    [pscustomobject]@{
        Stage = $fields['stage']
    }
}

function Assert-SpecContract {
    <#
    .SYNOPSIS
    校验可选 spec.md。
    .DESCRIPTION
    spec 只是 PLAN 的补充附件，因此只检查固定 section 骨架，不引入额外状态语义。
    .PARAMETER SpecPath
    spec.md 绝对路径。
    .OUTPUTS
    None。
    #>
    param([string]$SpecPath)

    $content = Get-Content -LiteralPath $SpecPath -Raw -Encoding utf8
    $sections = Get-Sections -Content $content
    Assert-SectionOrder -Sections $sections -Expected $script:SpecSections -Label "spec.md"
}

function Assert-TestContract {
    <#
    .SYNOPSIS
    校验 test.md。
    .DESCRIPTION
    TEST / DONE 都依赖这份文档，因此这里检查 section、结论字面量和 handoff 字段。
    .PARAMETER TestPath
    test.md 绝对路径。
    .PARAMETER CurrentStage
    当前 stage，用于补充 DONE 的额外约束。
    .OUTPUTS
    None。
    #>
    param(
        [string]$TestPath,
        [string]$CurrentStage
    )

    $content = Get-Content -LiteralPath $TestPath -Raw -Encoding utf8
    $sections = Get-Sections -Content $content
    Assert-SectionOrder -Sections $sections -Expected $script:TestSections -Label "test.md"

    $conclusion = Get-SectionContent -Sections $sections -Name 'Conclusion'
    $lines = @($conclusion -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt 0 -and ($lines[0] -in @('pass', 'fail', 'blocked'))) {
        Add-Check "test.md Conclusion is legal"
    } else {
        Add-Failure "test.md Conclusion first line should be pass | fail | blocked"
    }

    $handoff = Get-SectionContent -Sections $sections -Name 'Handoff'
    if ($handoff -match '(?m)^- delivery:\s+.+$' -and $handoff -match '(?m)^- follow_up:\s+.+$') {
        Add-Check "test.md Handoff contains delivery and follow_up"
    } else {
        Add-Failure 'test.md Handoff should contain - delivery: and - follow_up:'
    }

    if ($CurrentStage -eq 'DONE') {
        if ($lines.Count -gt 0 -and $lines[0] -eq 'pass') {
            Add-Check "DONE stage is backed by passing test result"
        } else {
            Add-Failure "DONE stage requires test.md Conclusion to be pass"
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$script:Checks = @()
$script:Failures = @()
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$taskRoot = Join-Path (Join-Path $RepoRoot 'docs\tasks') $TaskId
$planPath = Join-Path $taskRoot 'plan.md'
$specPath = Join-Path $taskRoot 'spec.md'
$testPath = Join-Path $taskRoot 'test.md'

if (Test-Path -LiteralPath $taskRoot -PathType Container) {
    Add-Check ("task directory exists: docs/tasks/{0}" -f $TaskId)
} else {
    Add-Failure ("task directory should exist: docs/tasks/{0}" -f $TaskId)
}

if (Test-Path -LiteralPath $planPath -PathType Leaf) {
    Add-Check "plan.md exists"
    $planState = Assert-PlanContract -TaskId $TaskId -PlanPath $planPath

    if (Test-Path -LiteralPath $specPath -PathType Leaf) {
        Add-Check "spec.md exists"
        Assert-SpecContract -SpecPath $specPath
    }

    if ($planState.Stage -in @('TEST', 'DONE')) {
        if (Test-Path -LiteralPath $testPath -PathType Leaf) {
            Add-Check "test.md exists for TEST/DONE"
            Assert-TestContract -TestPath $testPath -CurrentStage $planState.Stage
        } else {
            Add-Failure "TEST/DONE requires docs/tasks/<task-id>/test.md"
        }
    } elseif (Test-Path -LiteralPath $testPath -PathType Leaf) {
        Add-Check "test.md exists"
        Assert-TestContract -TestPath $testPath -CurrentStage $planState.Stage
    }
} else {
    Add-Failure "plan.md should exist"
}

if ($script:Failures.Count -gt 0) {
    Write-Output 'STATUS: FAIL'
} else {
    Write-Output 'STATUS: PASS'
}
Write-Output ("TaskId: {0}" -f $TaskId)
Write-Output ("TaskRoot: {0}" -f $taskRoot)
Write-Output ''
Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ("- {0}" -f $item)
    }
}
Write-Output ''
Write-Output 'Errors:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Failures) {
        Write-Output ("- {0}" -f $item)
    }
}

if ($script:Failures.Count -gt 0) {
    exit 2
}

exit 0
