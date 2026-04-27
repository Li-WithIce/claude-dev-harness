# 共享运行时修复脚本。
# 负责修复共享指针、收件箱、候选记忆、task runtime 与恢复索引。
# 该脚本会在修复前检查 runtime.lock.json，避免覆盖其他写者的活动写入。

[CmdletBinding()]
param(
    [string]$VaultRoot = '',
    [string]$EntryHost = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-shared-memory-paths.ps1')
. (Join-Path $PSScriptRoot 'runtime-inbox-common.ps1')

function New-CandidateTemplate {
    <#
    .SYNOPSIS
    生成记忆候选标准模板。

    .PARAMETER Today
    frontmatter 使用的日期字符串。

    .OUTPUTS
    System.String.
    #>
    param([string]$Today)

    return @"
---
tags: [运行时, 记忆, 候选]
created: $Today
updated: $Today
---

# 记忆候选

| ID | 日期 | 类型 | 内容摘要 | 建议写入 | 来源 | 状态 | 用户确认 |
|----|------|------|----------|----------|------|------|----------|
| 无 | - | - | 当前暂无候选项 | - | - | - | - |
"@
}

function New-ArchiveTemplate {
    <#
    .SYNOPSIS
    生成记忆候选归档标准模板。

    .PARAMETER Today
    frontmatter 使用的日期字符串。

    .OUTPUTS
    System.String.
    #>
    param([string]$Today)

    return @"
---
tags: [运行时, 记忆候选归档]
created: $Today
updated: $Today
---

# 记忆候选归档

| ID | 归档日期 | 类型 | 内容摘要 | 结果 | 目标位置 / 原因 | 备注 |
|----|----------|------|----------|------|-----------------|------|
| 无 | - | - | 当前暂无归档项 | - | - | - |
"@
}

function New-CurrentTaskContent {
    <#
    .SYNOPSIS
    生成当前任务共享指针文档。

    .PARAMETER TaskId
    任务 ID。

    .PARAMETER TaskName
    任务名称。

    .PARAMETER Status
    当前状态。

    .PARAMETER CurrentDoc
    当前文档路径。

    .PARAMETER NextStep
    下一步。

    .OUTPUTS
    System.String.
    #>
    param(
        [string]$TaskId,
        [string]$TaskName,
        [string]$Status,
        [string]$CurrentDoc,
        [string]$NextStep
    )

    return @(
        '---'
        ('updated: {0}' -f (Get-CurrentTimestamp))
        ('task_id: {0}' -f $TaskId)
        ('entry_host: {0}' -f $script:ResolvedEntryHost)
        'writer: repair-shared-memory'
        '---'
        ''
        '# 当前任务'
        ''
        '| 项目 | 值 |'
        '|------|-----|'
        ('| task_id | `{0}` |' -f $TaskId)
        ('| 任务 | {0} |' -f $TaskName)
        ('| 状态 | {0} |' -f $Status)
        ('| 当前文档 | {0} |' -f $CurrentDoc)
        ('| 下一步 | {0} |' -f $NextStep)
    ) -join "`r`n"
}

function New-InterruptedTemplate {
    <#
    .SYNOPSIS
    生成中断任务标准模板。

    .OUTPUTS
    System.String.
    #>
    param()

    return @(
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
}

function New-LastSessionTemplate {
    <#
    .SYNOPSIS
    生成上次会话标准模板。

    .OUTPUTS
    System.String.
    #>
    param()

    return @(
        '---'
        ('updated: {0}' -f (Get-CurrentTimestamp))
        '---'
        ''
        '# 上次会话'
        ''
        '| 项目 | 值 |'
        '|------|-----|'
        ('| 日期 | {0} |' -f (Get-TodayDate))
        '| 任务 | 无 |'
        '| 状态 | 空闲 |'
        '| 摘要 | - |'
    ) -join "`r`n"
}

function New-TaskRuntimeContent {
    <#
    .SYNOPSIS
    生成最小 task runtime 文档。

    .PARAMETER TaskId
    任务 ID。

    .PARAMETER TaskName
    任务名称。

    .PARAMETER PrimaryArtifact
    主产物相对路径。

    .PARAMETER Stage
    当前阶段。

    .OUTPUTS
    System.String.
    #>
    param(
        [string]$TaskId,
        [string]$TaskName,
        [string]$PrimaryArtifact,
        [string]$Stage
    )

    return @(
        '---'
        'schema_version: task-runtime/v1.1'
        ('task_id: {0}' -f $TaskId)
        ('task_name: {0}' -f $TaskName)
        ('primary_artifact: {0}' -f $PrimaryArtifact)
        ('entry_host: {0}' -f $script:ResolvedEntryHost)
        '---'
        ''
        '# Task Runtime'
        ''
        ('- stage: {0}' -f $Stage)
    ) -join "`r`n"
}

function New-RecoveryIndexContent {
    <#
    .SYNOPSIS
    生成恢复索引文档。

    .PARAMETER TaskId
    当前任务 ID。

    .PARAMETER TaskName
    当前任务名称。

    .PARAMETER Status
    当前状态。

    .PARAMETER CurrentDoc
    当前文档路径。

    .PARAMETER NextStep
    下一步。

    .PARAMETER InterruptedLines
    中断任务展示行。

    .OUTPUTS
    System.String.
    #>
    param(
        [string]$TaskId,
        [string]$TaskName,
        [string]$Status,
        [string]$CurrentDoc,
        [string]$NextStep,
        [string[]]$InterruptedLines
    )

    return @(
        '---'
        'tags: [运行时, 恢复索引]'
        ('updated: {0}' -f (Get-CurrentTimestamp))
        'schema_version: recovery-index/v1.1'
        'derived_from: [运行时/tasks/, 运行时/中断任务.md]'
        '---'
        ''
        '# 恢复索引'
        ''
        '## 当前主任务'
        ('- task_id: `{0}`' -f $TaskId)
        ('- 任务: {0}' -f $TaskName)
        ('- 状态: {0}' -f $Status)
        ('- 当前文档: {0}' -f $CurrentDoc)
        ('- 下一步: {0}' -f $NextStep)
        ''
        '## 中断任务 Top 3'
        $InterruptedLines
    ) -join "`r`n"
}

function Get-InterruptedPreviewLines {
    <#
    .SYNOPSIS
    从中断任务表生成恢复索引展示行。

    .PARAMETER Path
    中断任务文件路径。

    .OUTPUTS
    System.String[].
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @('- 无')
    }

    $lines = @()
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        if ($line -match '^\|\s*P\d+\s*\|') {
            $parts = $line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
            if ($parts.Count -ge 6) {
                $lines += ('- [{0}] {1} | {2} | {3}' -f $parts[0], $parts[2], $parts[4], $parts[5])
            }
        }
    }

    if ($lines.Count -eq 0) {
        return @('- 无')
    }

    return @($lines | Select-Object -First 3)
}

function Get-RepairTaskState {
    <#
    .SYNOPSIS
    解析修复时应采用的任务状态。

    .PARAMETER VaultRoot
    共享记忆根目录。

    .OUTPUTS
    PSCustomObject.
    #>
    param([string]$VaultRoot)

    $flow = Get-FlowSnapshot -VaultRoot $VaultRoot
    $currentTask = Get-CurrentTaskSnapshot -VaultRoot $VaultRoot

    if (-not (Test-IsIdleValue -Value $flow.TaskId) -and (Test-IsIdleValue -Value $currentTask.TaskId)) {
        return [pscustomobject]@{
            TaskId     = $flow.TaskId
            TaskName   = $flow.TaskName
            Status     = $flow.Stage
            CurrentDoc = $flow.CurrentDoc
            Next       = $flow.Next
            FromFlow   = $true
        }
    }

    if (-not (Test-IsIdleValue -Value $currentTask.TaskId)) {
        return [pscustomobject]@{
            TaskId     = $currentTask.TaskId
            TaskName   = $currentTask.TaskName
            Status     = $currentTask.Status
            CurrentDoc = $(if ([string]::IsNullOrWhiteSpace($flow.CurrentDoc)) { 'docs/tasks/{0}/plan.md' -f $currentTask.TaskId } else { $flow.CurrentDoc })
            Next       = $currentTask.Next
            FromFlow   = $false
        }
    }

    return [pscustomobject]@{
        TaskId     = 'none'
        TaskName   = '无'
        Status     = '空闲'
        CurrentDoc = 'none'
        Next       = '等待新任务'
        FromFlow   = $false
    }
}

function Clear-LockBlockedRows {
    <#
    .SYNOPSIS
    清理成功修复后遗留的 lock-blocked 收件箱项。

    .PARAMETER Inbox
    已读取的收件箱对象。

    .OUTPUTS
    PSCustomObject.
    #>
    param([pscustomobject]$Inbox)

    $cleared = 0
    $rows = foreach ($row in $Inbox.Rows) {
        if ($row.Type -eq 'lock-blocked' -and $row.Status -eq 'open') {
            $cleared += 1
            [pscustomobject]@{
                CreatedAt = $row.CreatedAt
                Source    = $row.Source
                TaskId    = $row.TaskId
                Type      = $row.Type
                Status    = 'cleared'
                Summary   = $row.Summary
                Payload   = '{0} Resolved by repair-shared-memory after refreshing recovery-index.' -f $row.Payload
            }
            continue
        }

        $row
    }

    return [pscustomobject]@{
        Cleared = $cleared
        Rows    = @($rows)
    }
}

<#
.SYNOPSIS
修复共享运行时产物。

.DESCRIPTION
脚本先检查 runtime.lock.json。
若有活动锁则直接返回 WARN；若锁已过期则清除后继续。
继续修复时会创建缺失文件、必要时用 current-flow 覆盖空闲指针，并重建恢复索引。
#>

$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot
$paths = Get-RuntimeMarkdownPaths -VaultRoot $VaultRoot
$today = Get-TodayDate
$repairs = @()
$script:ResolvedEntryHost = Get-EntryHostValue -EntryHost $EntryHost

if (-not (Test-Path -LiteralPath $paths.RuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Path $paths.RuntimeDir -Force | Out-Null
}

if (Test-Path -LiteralPath $paths.LockPath -PathType Leaf) {
    try {
        $lock = Get-Content -LiteralPath $paths.LockPath -Raw -Encoding utf8 | ConvertFrom-Json
        $lockedAt = [datetimeoffset]::Parse($lock.locked_at)
        $ageMinutes = ([datetimeoffset]::UtcNow - $lockedAt.ToUniversalTime()).TotalMinutes
        if ($ageMinutes -le 30) {
            Write-Output 'STATUS: WARN'
            Write-Output ('Blocked: active runtime.lock.json is held by {0} for task {1}; skipped shared runtime repair.' -f $lock.writer, $lock.task_id)
            exit 1
        }

        Remove-Item -LiteralPath $paths.LockPath -Force
        $repairs += ('removed expired runtime.lock.json (age={0:N0}min, writer={1})' -f $ageMinutes, $lock.writer)
    } catch {
        Remove-Item -LiteralPath $paths.LockPath -Force
        $repairs += 'removed malformed runtime.lock.json'
    }
}

$repairState = Get-RepairTaskState -VaultRoot $VaultRoot
$lockContent = [ordered]@{
    writer    = 'repair-shared-memory'
    task_id   = $repairState.TaskId
    locked_at = [datetimeoffset]::UtcNow.ToString('o')
    entry_host = $script:ResolvedEntryHost
} | ConvertTo-Json -Depth 3
Write-Utf8Bom -Path $paths.LockPath -Content $lockContent

try {
    if (-not (Test-Path -LiteralPath $paths.TasksDir -PathType Container)) {
        New-Item -ItemType Directory -Path $paths.TasksDir -Force | Out-Null
        $repairs += ('created {0}' -f $paths.TasksDir)
    }

    $candidatePath = Join-Path $paths.RuntimeDir '记忆候选.md'
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        Write-Utf8Bom -Path $candidatePath -Content (New-CandidateTemplate -Today $today)
        $repairs += ('created {0}' -f $candidatePath)
    }

    $archivePath = Join-Path $paths.RuntimeDir '记忆候选归档.md'
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Utf8Bom -Path $archivePath -Content (New-ArchiveTemplate -Today $today)
        $repairs += ('created {0}' -f $archivePath)
    }

    if (-not (Test-Path -LiteralPath $paths.InboxPath -PathType Leaf)) {
        Write-RuntimeInbox -InboxPath $paths.InboxPath -CreatedDate $today -Rows @()
        $repairs += ('created {0}' -f $paths.InboxPath)
    }

    if (-not (Test-Path -LiteralPath $paths.CurrentTaskPath -PathType Leaf)) {
        Write-Utf8Bom -Path $paths.CurrentTaskPath -Content (New-CurrentTaskContent `
            -TaskId 'none' `
            -TaskName '无' `
            -Status '空闲' `
            -CurrentDoc 'none' `
            -NextStep '等待新任务')
        $repairs += ('created {0}' -f $paths.CurrentTaskPath)
    }

    if (-not (Test-Path -LiteralPath $paths.InterruptedPath -PathType Leaf)) {
        Write-Utf8Bom -Path $paths.InterruptedPath -Content (New-InterruptedTemplate)
        $repairs += ('created {0}' -f $paths.InterruptedPath)
    }

    if (-not (Test-Path -LiteralPath $paths.LastSessionPath -PathType Leaf)) {
        Write-Utf8Bom -Path $paths.LastSessionPath -Content (New-LastSessionTemplate)
        $repairs += ('created {0}' -f $paths.LastSessionPath)
    }

    Write-Utf8Bom -Path $paths.CurrentTaskPath -Content (New-CurrentTaskContent `
        -TaskId $repairState.TaskId `
        -TaskName $repairState.TaskName `
        -Status $repairState.Status `
        -CurrentDoc $repairState.CurrentDoc `
        -NextStep $repairState.Next)
    if ($repairState.FromFlow) {
        $repairs += ('synchronized {0} from current-flow' -f $paths.CurrentTaskPath)
    } else {
        $repairs += ('normalized {0}' -f $paths.CurrentTaskPath)
    }

    if (-not (Test-IsIdleValue -Value $repairState.TaskId)) {
        $taskRuntimePath = Join-Path $paths.TasksDir ('{0}.md' -f $repairState.TaskId)
        if (-not (Test-Path -LiteralPath $taskRuntimePath -PathType Leaf)) {
            Write-Utf8Bom -Path $taskRuntimePath -Content (New-TaskRuntimeContent `
                -TaskId $repairState.TaskId `
                -TaskName $repairState.TaskName `
                -PrimaryArtifact $repairState.CurrentDoc `
                -Stage $repairState.Status)
            $repairs += ('created {0}' -f $taskRuntimePath)
        }
    }

    $inbox = Read-RuntimeInbox -VaultRoot $VaultRoot -NormalizeExisting
    $clearedResult = Clear-LockBlockedRows -Inbox $inbox
    if ($clearedResult.Cleared -gt 0) {
        Write-RuntimeInbox -InboxPath $inbox.Path -CreatedDate $inbox.CreatedDate -Rows $clearedResult.Rows
        $repairs += ('cleared {0} lock-blocked inbox item(s)' -f $clearedResult.Cleared)
    }

    $indexContent = New-RecoveryIndexContent `
        -TaskId $repairState.TaskId `
        -TaskName $repairState.TaskName `
        -Status $repairState.Status `
        -CurrentDoc $repairState.CurrentDoc `
        -NextStep $repairState.Next `
        -InterruptedLines (Get-InterruptedPreviewLines -Path $paths.InterruptedPath)
    Write-Utf8Bom -Path $paths.RecoveryIndexPath -Content $indexContent
    $repairs += ('refreshed {0}' -f $paths.RecoveryIndexPath)

    Remove-Item -LiteralPath $paths.LockPath -Force
} catch {
    if (Test-Path -LiteralPath $paths.LockPath -PathType Leaf) {
        Remove-Item -LiteralPath $paths.LockPath -Force
    }
    throw
}

Write-Output 'STATUS: PASS'
Write-Output ('Repaired: {0}' -f $repairs.Count)
foreach ($item in $repairs) {
    Write-Output ('- {0}' -f $item)
}
exit 0
