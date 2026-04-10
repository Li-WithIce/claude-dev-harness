# 推进 harness lite 阶段，并按 `plan.md` frontmatter 重写共享运行时 mirror。
# 这个脚本只认 lite 契约：`docs/tasks/<task-id>/plan.md` 是唯一阶段真相源。
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [string]$Tool = "",

    [string]$VaultRoot = $Env:OBSIDIAN_VAULT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ValidStages = @("PLAN", "PLAN_REVIEW", "IMPLEMENT", "CODE_REVIEW", "TEST", "DONE")
$ValidTools = @("claudecode", "codex", "gemini")

if (-not $VaultRoot) {
    throw "Set OBSIDIAN_VAULT or pass -VaultRoot."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$planPath = Join-Path $repoRoot "docs/tasks/$TaskId/plan.md"
$testPath = Join-Path $repoRoot "docs/tasks/$TaskId/test.md"
$tasksDir = Join-Path $VaultRoot "运行时/tasks"
$taskMirrorPath = Join-Path $tasksDir "$TaskId.md"
$indexPath = Join-Path $VaultRoot "运行时/恢复索引.md"
$currentPath = Join-Path $VaultRoot "运行时/当前任务.md"
$validatorPath = Join-Path $PSScriptRoot "validate-lite-artifacts.ps1"

if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Missing $planPath"
}

if (-not (Test-Path -LiteralPath $tasksDir -PathType Container)) {
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
}

function Invoke-LiteArtifactValidator {
    <#
    .SYNOPSIS
    在推进前运行 lite artifact validator。
    .DESCRIPTION
    通过当前 PowerShell 宿主启动子进程执行 validator，避免子脚本里的 `exit` 直接终止推进脚本。
    .PARAMETER ValidatorPath
    validator 脚本路径。
    .PARAMETER TaskId
    任务 ID。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    None。
    #>
    param(
        [string]$ValidatorPath,
        [string]$TaskId,
        [string]$RepoRoot
    )

    $shellPath = (Get-Process -Id $PID).Path
    $output = @(& $shellPath -NoProfile -File $ValidatorPath -TaskId $TaskId -RepoRoot $RepoRoot 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -eq 0) {
        return
    }

    $details = @()
    $errorIndex = [Array]::IndexOf($output, 'Errors:')
    if ($errorIndex -ge 0) {
        for ($index = $errorIndex + 1; $index -lt $output.Count; $index += 1) {
            $line = $output[$index].Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line -eq '- none') {
                continue
            }

            if ($line.StartsWith('- ')) {
                $details += $line.Substring(2)
            }
        }
    }

    if ($details.Count -eq 0) {
        throw ('validate-lite-artifacts.ps1 failed for {0}.' -f $TaskId)
    }

    throw ('validate-lite-artifacts.ps1 failed for {0}: {1}' -f $TaskId, ($details -join '; '))
}

function Get-Frontmatter {
    <#
    .SYNOPSIS
    解析 Markdown frontmatter。
    .DESCRIPTION
    读取 lite workflow 的 frontmatter，并返回键值表。
    .PARAMETER Text
    Markdown 全文。
    .OUTPUTS
    Hashtable。
    #>
    param([string]$Text)

    if ($Text -notmatch "(?s)^---\r?\n(.*?)\r?\n---\r?\n") {
        throw "Missing frontmatter."
    }

    $map = @{}
    foreach ($line in ($Matches[1] -split "\r?\n")) {
        if ($line -match "^\s*([^:]+):\s*(.+?)\s*$") {
            $map[$Matches[1]] = $Matches[2]
        }
    }

    return $map
}

function Get-Section {
    <#
    .SYNOPSIS
    读取二级标题内容。
    .DESCRIPTION
    按 `## <name>` 截取 section，供 gate 检查使用。
    .PARAMETER Text
    Markdown 全文。
    .PARAMETER Name
    目标 section 名。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Text,
        [string]$Name
    )

    if ($Text -match "(?ms)^## $([regex]::Escape($Name))\r?\n(.*?)(?=^## |\z)") {
        return $Matches[1].Trim()
    }

    return ""
}

function Get-LatestRun {
    <#
    .SYNOPSIS
    返回目标 section 的最新 Run 块。
    .DESCRIPTION
    lite workflow 的审查和实现记录都是 append-only，只读取最后一个 `### Run`。
    .PARAMETER Text
    Markdown 全文。
    .PARAMETER Name
    section 名。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Text,
        [string]$Name
    )

    $runs = [regex]::Matches((Get-Section -Text $Text -Name $Name), "(?ms)^### Run .*?(?=^### Run |\z)")
    if ($runs.Count -eq 0) {
        return ""
    }

    return $runs[$runs.Count - 1].Value.Trim()
}

function Get-RunVerdict {
    <#
    .SYNOPSIS
    提取最新 Run verdict。
    .DESCRIPTION
    PLAN_REVIEW 和 CODE_REVIEW 都只接受 `pass` 或 `revise`。
    .PARAMETER Text
    Markdown 全文。
    .PARAMETER Name
    section 名。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Text,
        [string]$Name
    )

    $run = Get-LatestRun -Text $Text -Name $Name
    if ($run -match "(?m)^- verdict:\s*(pass|revise)\s*$") {
        return $Matches[1]
    }

    return ""
}

function Get-RunTimestamp {
    <#
    .SYNOPSIS
    读取 Run 标题时间。
    .DESCRIPTION
    IMPLEMENT gate 用它判断回修后是否追加了新证据。
    .PARAMETER Text
    Markdown 全文。
    .PARAMETER Name
    section 名。
    .OUTPUTS
    Nullable[datetime]。
    #>
    param(
        [string]$Text,
        [string]$Name
    )

    $run = Get-LatestRun -Text $Text -Name $Name
    if ($run -match "(?m)^### Run \d+\s+·\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s+·\s+runner:") {
        return [datetime]::ParseExact($Matches[1], "yyyy-MM-dd HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return $null
}

function Write-Utf8Bom {
    <#
    .SYNOPSIS
    以 UTF-8 BOM 写文件。
    .DESCRIPTION
    共享运行时 markdown 延续仓库现有 BOM 写法，避免 Windows 下再次漂编码。
    .PARAMETER Path
    目标路径。
    .PARAMETER Content
    要写入的文本。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Resolve-AssignedTool {
    <#
    .SYNOPSIS
    解析下一阶段的指定工具。
    .DESCRIPTION
    lite workflow 不再维护固定 profile 矩阵；每次推进都由用户显式指定下一阶段 tool。
    .PARAMETER Stage
    目标阶段。
    .PARAMETER Tool
    用户为下一阶段指定的工具。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Stage,
        [string]$Tool
    )

    if ($Stage -eq "DONE") {
        return "none"
    }

    if ([string]::IsNullOrWhiteSpace($Tool)) {
        throw ("Advancing to {0} requires -Tool (claudecode | codex | gemini)." -f $Stage)
    }

    $normalized = $Tool.Trim().ToLowerInvariant()
    if ($normalized -notin $ValidTools) {
        throw ("Unsupported tool: {0}" -f $normalized)
    }

    return $normalized
}

function Update-Frontmatter {
    <#
    .SYNOPSIS
    覆盖 plan frontmatter。
    .DESCRIPTION
    只改 lite 契约要求的四个字段，不碰正文和 append-only 历史。
    .PARAMETER Text
    原始 Markdown。
    .PARAMETER Task
    task_id。
    .PARAMETER Stage
    新阶段。
    .PARAMETER Tool
    tool。
    .PARAMETER Updated
    更新时间。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Text,
        [string]$Task,
        [string]$Stage,
        [string]$Tool,
        [string]$Updated
    )

    $frontmatter = @(
        "---"
        "task_id: $Task"
        "stage: $Stage"
        "tool: $Tool"
        "updated: $Updated"
        "---"
        ""
    ) -join "`r`n"

    return [regex]::Replace($Text, "(?s)^---\r?\n.*?\r?\n---\r?\n", $frontmatter, 1)
}

function New-CurrentTaskContent {
    <#
    .SYNOPSIS
    生成共享运行时当前任务指针。
    .DESCRIPTION
    当前任务文件与 obsidian-memory 读取侧共用同一张表，避免阶段推进后写出不可读格式。
    .PARAMETER TaskId
    任务 ID。
    .PARAMETER Status
    当前阶段。
    .PARAMETER CurrentDoc
    当前主文档路径。
    .PARAMETER Tool
    当前阶段工具。
    .PARAMETER NextStep
    下一步说明。
    .OUTPUTS
    String。
    #>
    param(
        [string]$TaskId,
        [string]$Status,
        [string]$CurrentDoc,
        [string]$Tool,
        [string]$NextStep
    )

    return @(
        '---'
        ('updated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('task_id: {0}' -f $TaskId)
        'writer: advance-stage'
        '---'
        ''
        '# 当前任务'
        ''
        '| 项目 | 值 |'
        '|------|-----|'
        ('| task_id | `{0}` |' -f $TaskId)
        ('| 任务 | {0} |' -f $TaskId)
        ('| 状态 | {0} |' -f $Status)
        ('| 当前文档 | {0} |' -f $CurrentDoc)
        ('| 工具 | {0} |' -f $Tool)
        ('| 下一步 | {0} |' -f $NextStep)
    ) -join "`r`n"
}

function Write-RecoveryIndex {
    <#
    .SYNOPSIS
    重写恢复索引。
    .DESCRIPTION
    lite flow 只从 `运行时/tasks/*.md` 汇总任务，不再依赖 `中断任务.md`。
    .PARAMETER TasksDirectory
    任务 mirror 目录。
    .PARAMETER Path
    恢复索引文件路径。
    .OUTPUTS
    None。
    #>
    param(
        [string]$TasksDirectory,
        [string]$Path
    )

    $rows = @()
    foreach ($file in Get-ChildItem -LiteralPath $TasksDirectory -Filter "*.md" -File | Sort-Object Name) {
        $mirrorText = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        $meta = Get-Frontmatter -Text $mirrorText
        $rows += [pscustomobject]@{
            TaskId  = $meta.task_id
            Stage   = $meta.stage
            Updated = $meta.updated
        }
    }

    $ordered = $rows | Sort-Object Updated, TaskId -Descending
    $content = "# 恢复索引`r`n`r`n"
    foreach ($row in $ordered) {
        $content += "- $($row.TaskId) | $($row.Stage) | $($row.Updated)`r`n"
    }

    Write-Utf8Bom -Path $Path -Content $content
}

$planText = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
$frontmatter = Get-Frontmatter -Text $planText
$stage = $frontmatter.stage
$currentTool = $frontmatter.tool

if ($frontmatter.task_id -ne $TaskId) {
    throw "Frontmatter task_id '$($frontmatter.task_id)' does not match '$TaskId'."
}

if ($stage -notin $ValidStages) {
    throw "Unsupported stage: $stage"
}

if ($stage -eq 'DONE') {
    if ($currentTool -ne 'none') {
        throw "DONE stage requires tool: none"
    }
} elseif ($currentTool -notin $ValidTools) {
    throw "Unsupported plan tool: $currentTool"
}

Invoke-LiteArtifactValidator -ValidatorPath $validatorPath -TaskId $TaskId -RepoRoot $repoRoot

$today = Get-Date -Format "yyyy-MM-dd"
$nextStage = switch ($stage) {
    "PLAN" {
        $clarification = Get-Section -Text $planText -Name "Clarification"
        $confirmation = Get-Section -Text $planText -Name "User Confirmation"
        if ($clarification -notmatch "验收" -or
            $clarification -notmatch "非目标" -or
            $clarification -notmatch "受影响" -or
            ($clarification -notmatch "回滚" -and $clarification -notmatch "兼容") -or
            $clarification -notmatch "ui:") {
            throw "PLAN clarification gate failed."
        }
        if ($confirmation -notmatch "(?m)^- status:\s*confirmed\s*$") {
            throw "PLAN requires explicit user confirmation."
        }
        "PLAN_REVIEW"
    }
    "PLAN_REVIEW" {
        $planVerdict = Get-RunVerdict -Text $planText -Name "Plan Review"
        if (-not $planVerdict) {
            throw "PLAN_REVIEW requires latest verdict."
        }
        if ($planVerdict -eq "pass") { "IMPLEMENT" } else { "PLAN" }
    }
    "IMPLEMENT" {
        $implementationRun = Get-LatestRun -Text $planText -Name "Implementation Notes"
        if (-not $implementationRun) {
            throw "IMPLEMENT requires an Implementation Notes run."
        }

        $implementationTime = Get-RunTimestamp -Text $planText -Name "Implementation Notes"
        $codeVerdict = Get-RunVerdict -Text $planText -Name "Code Review"
        $codeReviewTime = Get-RunTimestamp -Text $planText -Name "Code Review"
        if ($codeVerdict -eq "revise" -and $null -ne $codeReviewTime -and $implementationTime -le $codeReviewTime) {
            throw "IMPLEMENT requires a fresh Implementation Notes run after CODE_REVIEW revise."
        }

        "CODE_REVIEW"
    }
    "CODE_REVIEW" {
        $codeVerdict = Get-RunVerdict -Text $planText -Name "Code Review"
        if (-not $codeVerdict) {
            throw "CODE_REVIEW requires latest verdict."
        }
        if ($codeVerdict -eq "pass") { "TEST" } else { "IMPLEMENT" }
    }
    "TEST" {
        if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
            throw "Missing $testPath"
        }

        $testText = Get-Content -LiteralPath $testPath -Raw -Encoding utf8
        if ($testText -notmatch "(?ms)^## Conclusion\r?\n(pass|fail|blocked)\s*$") {
            throw "TEST requires Conclusion."
        }
        $conclusion = $Matches[1]
        if ($testText -notmatch "(?m)^## Handoff\s*$") {
            throw "TEST requires Handoff."
        }
        if ($conclusion -ne "pass") {
            throw "TEST conclusion is $conclusion; stop and report."
        }

        "DONE"
    }
    "DONE" {
        throw "Task is already DONE."
    }
}

$nextTool = Resolve-AssignedTool -Stage $nextStage -Tool $Tool
$updatedPlan = Update-Frontmatter -Text $planText -Task $TaskId -Stage $nextStage -Tool $nextTool -Updated $today
Write-Utf8Bom -Path $planPath -Content $updatedPlan

$latestPlanReview = Get-RunVerdict -Text $updatedPlan -Name "Plan Review"
if (-not $latestPlanReview) {
    $latestPlanReview = "none"
}

$latestCodeReview = Get-RunVerdict -Text $updatedPlan -Name "Code Review"
if (-not $latestCodeReview) {
    $latestCodeReview = "none"
}

$currentDoc = if ($nextStage -eq 'DONE') {
    "docs/tasks/$TaskId/test.md"
} else {
    "docs/tasks/$TaskId/plan.md"
}
$nextStep = if ($nextStage -eq 'DONE') {
    '任务完成'
} else {
    "使用 $nextTool 继续 $nextStage"
}
$taskMirror = @(
    "---"
    "task_id: $TaskId"
    "stage: $nextStage"
    "tool: $nextTool"
    "updated: $today"
    "---"
    "# Task Mirror"
    ""
    "- pointer: $currentDoc"
    "- assigned_tool: $nextTool"
    "- latest_plan_review: $latestPlanReview"
    "- latest_code_review: $latestCodeReview"
    ""
) -join "`r`n"

Write-Utf8Bom -Path $taskMirrorPath -Content $taskMirror
Write-Utf8Bom -Path $currentPath -Content (New-CurrentTaskContent -TaskId $TaskId -Status $nextStage -CurrentDoc $currentDoc -Tool $nextTool -NextStep $nextStep)
Write-RecoveryIndex -TasksDirectory $tasksDir -Path $indexPath

Write-Output "$nextStage | $nextTool"
