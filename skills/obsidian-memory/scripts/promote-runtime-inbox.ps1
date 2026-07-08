# 共享运行时收件箱提升脚本。
# 支持把 inbox-first 项路由到 interrupted-task 或 decision-needed。
# 产物默认落到当前 workspace 的 docs/tasks/{task_id}/plan.md。

[CmdletBinding()]
param(
    [string]$VaultRoot = '',
    [string]$WorkspaceRoot = '',
    [Parameter(Mandatory = $true)]
    [string]$Target,
    [string]$CreatedAt = '',
    [string]$TaskId = '',
    [string]$Type = 'inbox-first',
    [string]$Source = '',
    [string]$SummaryContains = '',
    [string]$TargetTaskId = '',
    [string]$TargetTaskName = '',
    [string]$EntryHost = '',
    [string]$Priority = 'P2',
    [string]$TaskStage = 'PLAN',
    [string]$NextStep = '',
    [string]$ArtifactRoot = '',
    [string]$PrimaryArtifact = '',
    [string]$DecisionSummary = '',
    [string]$BlockingReason = '',
    [string]$OptionA = '',
    [string]$OptionB = '',
    [string]$RecommendedPath = '',
    [string]$NeededFromUser = '',
    [string]$ResumeWhenResolved = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-shared-memory-paths.ps1')
. (Join-Path $PSScriptRoot 'runtime-inbox-common.ps1')

function Write-FailAndExit {
    <#
    .SYNOPSIS
    输出失败状态并结束脚本。

    .PARAMETER Message
    失败说明。
    #>
    param([string]$Message)

    Write-Output 'STATUS: FAIL'
    Write-Output $Message
    exit 1
}

function Ensure-InterruptedTaskFile {
    <#
    .SYNOPSIS
    确保中断任务文件存在标准表头。

    .PARAMETER Path
    中断任务文件路径。

    .OUTPUTS
    System.String[].
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $content = @(
            '---'
            ('updated: {0}' -f (Get-CurrentTimestamp))
            'derived_from: [运行时/tasks/]'
            '---'
            ''
            '# 中断任务'
            ''
            '| Priority | Updated | Task | TaskId | Status | Next |'
            '|----------|---------|------|--------|--------|------|'
        ) -join "`r`n"
        Write-Utf8Bom -Path $Path -Content $content
    }

    return @(Get-Content -LiteralPath $Path -Encoding utf8)
}

function Write-InterruptedTaskFile {
    <#
    .SYNOPSIS
    写回中断任务表。

    .PARAMETER Path
    中断任务文件路径。

    .PARAMETER Rows
    已格式化的表格数据行。
    #>
    param(
        [string]$Path,
        [string[]]$Rows
    )

    $content = @(
        '---'
        ('updated: {0}' -f (Get-CurrentTimestamp))
        'derived_from: [运行时/tasks/]'
        '---'
        ''
        '# 中断任务'
        ''
        '| Priority | Updated | Task | TaskId | Status | Next |'
        '|----------|---------|------|--------|--------|------|'
        $Rows
    ) -join "`r`n"

    Write-Utf8Bom -Path $Path -Content $content
}

function New-PlanDocument {
    <#
    .SYNOPSIS
    生成最小可用的 plan 文档。

    .PARAMETER TaskId
    任务 ID。

    .PARAMETER TaskName
    任务名称。

    .PARAMETER Summary
    来源 inbox 的摘要。

    .PARAMETER Payload
    来源 inbox 的附加信息。

    .PARAMETER Stage
    当前阶段。

    .PARAMETER NextStep
    下一步动作。

    .OUTPUTS
    System.String.
    #>
    param(
        [string]$TaskId,
        [string]$TaskName,
        [string]$Summary,
        [string]$Payload,
        [string]$Stage,
        [string]$NextStep
    )

    return @(
        '---'
        ('task_id: {0}' -f $TaskId)
        ('task_name: {0}' -f $TaskName)
        ('stage: {0}' -f $Stage)
        'status: draft'
        '---'
        ''
        '# Plan'
        ''
        '## Context'
        ('- Summary: {0}' -f $Summary)
        ('- Payload: {0}' -f $Payload)
        ''
        '## Next'
        ('- {0}' -f $NextStep)
    ) -join "`r`n"
}

function New-TaskRuntimeDocument {
    <#
    .SYNOPSIS
    生成 task-runtime/v1.1 最小运行时文档。

    .PARAMETER TaskId
    任务 ID。

    .PARAMETER TaskName
    任务名称。

    .PARAMETER WorkspaceRoot
    当前活动工作区。

    .PARAMETER Stage
    当前阶段。

    .PARAMETER PrimaryArtifact
    主产物相对路径。

    .PARAMETER EntryHost
    当前写者 host。

    .PARAMETER NextStep
    下一步动作。

    .OUTPUTS
    System.String.
    #>
    param(
        [string]$TaskId,
        [string]$TaskName,
        [string]$WorkspaceRoot,
        [string]$Stage,
        [string]$PrimaryArtifact,
        [string]$EntryHost,
        [string]$NextStep
    )

    return @(
        '---'
        'schema_version: task-runtime/v1.1'
        ('task_id: {0}' -f $TaskId)
        ('task_name: {0}' -f $TaskName)
        ('workspace: {0}' -f $WorkspaceRoot)
        ('primary_artifact: {0}' -f $PrimaryArtifact)
        ('entry_host: {0}' -f $EntryHost)
        '---'
        ''
        '# Task Runtime'
        ''
        ('- stage: {0}' -f $Stage)
        ('- next: {0}' -f $NextStep)
    ) -join "`r`n"
}

<#
.SYNOPSIS
把收件箱活动项提升到编排文件。

.DESCRIPTION
该脚本只处理单条 open 行。
interrupted-task 会创建 task runtime、docs/tasks 下的 plan，以及中断任务表行。
decision-needed 会更新 orchestration/decision-needed.md。
#>

$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot -WorkspaceRoot $WorkspaceRoot
$WorkspaceRoot = Resolve-WorkspaceRoot -WorkspaceRoot $WorkspaceRoot -VaultRoot $VaultRoot
$paths = Get-RuntimeMarkdownPaths -VaultRoot $VaultRoot
$inbox = Read-RuntimeInbox -VaultRoot $VaultRoot
$resolvedEntryHost = Get-EntryHostValue -EntryHost $EntryHost

if (
    [string]::IsNullOrWhiteSpace($CreatedAt) -and
    [string]::IsNullOrWhiteSpace($TaskId) -and
    [string]::IsNullOrWhiteSpace($Type) -and
    [string]::IsNullOrWhiteSpace($Source) -and
    [string]::IsNullOrWhiteSpace($SummaryContains)
) {
    Write-FailAndExit -Message 'At least one selector is required: -CreatedAt, -TaskId, -Type, -Source, or -SummaryContains.'
}

$matches = Select-ActiveInboxRows `
    -Rows $inbox.Rows `
    -CreatedAt $CreatedAt `
    -TaskId $TaskId `
    -Type $Type `
    -Source $Source `
    -SummaryContains $SummaryContains

if ($matches.Count -eq 0) {
    Write-FailAndExit -Message 'Matched 0 active runtime inbox rows.'
}
if ($matches.Count -gt 1) {
    Write-FailAndExit -Message ('Matched {0} active runtime inbox rows; narrow the selectors or add -SummaryContains / -CreatedAt.' -f $matches.Count)
}

$match = $matches[0]
$promotionNote = ''

if ($Target -eq 'interrupted-task') {
    if ([string]::IsNullOrWhiteSpace($TargetTaskId)) {
        $TargetTaskId = $match.TaskId
    }
    if ([string]::IsNullOrWhiteSpace($TargetTaskName)) {
        $TargetTaskName = $match.Summary
    }
    if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
        $ArtifactRoot = 'docs/tasks/{0}' -f $TargetTaskId
    }
    if ([string]::IsNullOrWhiteSpace($PrimaryArtifact)) {
        $PrimaryArtifact = '{0}/plan.md' -f $ArtifactRoot
    }
    if ([string]::IsNullOrWhiteSpace($NextStep)) {
        $NextStep = 'Continue the promoted task.'
    }

    $artifactPath = Join-Path $WorkspaceRoot ($PrimaryArtifact -replace '/', '\')
    $artifactDir = Split-Path -Parent $artifactPath
    if (-not (Test-Path -LiteralPath $artifactDir -PathType Container)) {
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    }
    $planContent = New-PlanDocument `
        -TaskId $TargetTaskId `
        -TaskName $TargetTaskName `
        -Summary $match.Summary `
        -Payload $match.Payload `
        -Stage $TaskStage `
        -NextStep $NextStep
    Write-Utf8Bom -Path $artifactPath -Content $planContent

    if (-not (Test-Path -LiteralPath $paths.TasksDir -PathType Container)) {
        New-Item -ItemType Directory -Path $paths.TasksDir -Force | Out-Null
    }
    $taskRuntimePath = Join-Path $paths.TasksDir ('{0}.md' -f $TargetTaskId)
    $taskRuntimeContent = New-TaskRuntimeDocument `
        -TaskId $TargetTaskId `
        -TaskName $TargetTaskName `
        -WorkspaceRoot $WorkspaceRoot `
        -Stage $TaskStage `
        -PrimaryArtifact $PrimaryArtifact `
        -EntryHost $resolvedEntryHost `
        -NextStep $NextStep
    Write-Utf8Bom -Path $taskRuntimePath -Content $taskRuntimeContent

    $interruptedLines = Ensure-InterruptedTaskFile -Path $paths.InterruptedPath
    $dataRows = @()
    foreach ($line in $interruptedLines) {
        if ($line -match '^\|\s*P\d+\s*\|') {
            $parts = $line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
            if ($parts.Count -ge 6 -and $parts[3] -ne $TargetTaskId) {
                $dataRows += $line
            }
        }
    }
    $dataRows += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f `
        $Priority, (Get-CurrentTimestamp), $TargetTaskName, $TargetTaskId, $TaskStage, $NextStep)
    Write-InterruptedTaskFile -Path $paths.InterruptedPath -Rows $dataRows
    $promotionNote = 'Promoted to interrupted-task {0}.' -f $TargetTaskId
}
elseif ($Target -eq 'decision-needed') {
    $flow = Get-FlowSnapshot -VaultRoot $VaultRoot
    $decisionTaskId = if (-not (Test-IsIdleValue -Value $flow.TaskId)) { $flow.TaskId } elseif (-not (Test-IsIdleValue -Value $match.TaskId)) { $match.TaskId } else { 'unknown' }
    $decisionSummaryValue = if ([string]::IsNullOrWhiteSpace($DecisionSummary)) { $match.Summary } else { $DecisionSummary }
    $decisionReason = if ([string]::IsNullOrWhiteSpace($BlockingReason)) { $match.Payload } else { $BlockingReason }
    $decisionPath = Join-Path $VaultRoot 'orchestration\decision-needed.md'
    $decisionContent = @(
        '---'
        ('task_id: {0}' -f $decisionTaskId)
        'status: open'
        ('updated: {0}' -f (Get-CurrentTimestamp))
        '---'
        ''
        '# Decision Needed'
        ''
        '## Summary'
        ('- {0}' -f $decisionSummaryValue)
        ''
        '## Blocking Reason'
        ('- {0}' -f $decisionReason)
    ) -join "`r`n"
    Write-Utf8Bom -Path $decisionPath -Content $decisionContent
    $promotionNote = 'Promoted to decision-needed.md for task {0}.' -f $decisionTaskId
}
else {
    Write-FailAndExit -Message ('Unsupported target: {0}' -f $Target)
}

$matchKey = '{0}|{1}|{2}|{3}' -f $match.CreatedAt, $match.Source, $match.TaskId, $match.Summary
$updatedRows = foreach ($row in $inbox.Rows) {
    $rowKey = '{0}|{1}|{2}|{3}' -f $row.CreatedAt, $row.Source, $row.TaskId, $row.Summary
    if ($rowKey -eq $matchKey) {
        [pscustomobject]@{
            CreatedAt = $row.CreatedAt
            Source    = $row.Source
            TaskId    = $row.TaskId
            Type      = $row.Type
            Status    = 'cleared'
            Summary   = $row.Summary
            Payload   = '{0} {1}' -f $row.Payload, $promotionNote
        }
        continue
    }

    $row
}

Write-RuntimeInbox -InboxPath $inbox.Path -CreatedDate $inbox.CreatedDate -Rows $updatedRows
Write-Output 'STATUS: PASS'
Write-Output ('Target: {0}' -f $Target)
exit 0
