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
. (Join-Path $PSScriptRoot 'runtime-state-common.ps1')

function New-IdleRepairTaskState {
    param(
        [switch]$FromPlan,
        [string]$Audit = ''
    )

    return [pscustomobject]@{
        TaskId     = 'none'
        TaskName   = '无'
        Status     = '空闲'
        CurrentDoc = 'none'
        Tool       = 'none'
        Next       = '等待新任务'
        FromFlow   = $false
        FromPlan   = $FromPlan.IsPresent
        Audit      = $Audit
    }
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

    $currentPath = Join-Path $VaultRoot '运行时\当前任务.md'
    $current = Get-CanonicalCurrentTaskState -Path $currentPath

    # current-flow is a one-time legacy migration source only. Once a pointer
    # exists, it remains the authoritative input for repair.
    if (-not $current.Exists) {
        $flow = Get-FlowSnapshot -VaultRoot $VaultRoot
        if (-not (Test-IsIdleValue -Value $flow.TaskId)) {
            if (-not (Test-CanonicalRuntimeTaskId -TaskId $flow.TaskId)) {
                return New-IdleRepairTaskState -Audit 'normalized invalid current-flow task_id to canonical idle without task path access'
            }
            return [pscustomobject]@{
                TaskId     = $flow.TaskId
                TaskName   = $flow.TaskName
                Status     = $flow.Stage
                CurrentDoc = $flow.CurrentDoc
                Tool       = 'none'
                Next       = $flow.Next
                FromFlow   = $true
                FromPlan   = $false
                Audit      = ''
            }
        }
    }

    if (-not (Test-IsIdleValue -Value $current.TaskId)) {
        if (-not (Test-CanonicalRuntimeTaskId -TaskId $current.TaskId)) {
            return New-IdleRepairTaskState -Audit 'normalized invalid current task_id to canonical idle without task path access'
        }
        $workspaceRoot = Split-Path -Parent $VaultRoot
        $planPath = Join-Path $workspaceRoot ('docs/tasks/{0}/plan.md' -f $current.TaskId)
        $planStage = if (Test-Path -LiteralPath $planPath -PathType Leaf) { Get-YamlValue -Path $planPath -Key 'stage' } else { '' }
        $planTool = if (Test-Path -LiteralPath $planPath -PathType Leaf) { Get-YamlValue -Path $planPath -Key 'tool' } else { '' }
        if ($planStage -eq 'DONE') {
            return New-IdleRepairTaskState -FromPlan
        }
        $resolvedStage = if (Test-CanonicalRuntimeStage -Stage $planStage) { $planStage } else { $current.Stage }
        $resolvedDoc = if ($resolvedStage -eq 'DONE') { 'docs/tasks/{0}/test.md' -f $current.TaskId } elseif (Test-CanonicalRuntimeStage -Stage $resolvedStage) { 'docs/tasks/{0}/plan.md' -f $current.TaskId } else { $current.CurrentDoc }
        return [pscustomobject]@{
            TaskId     = $current.TaskId
            TaskName   = $(if ([string]::IsNullOrWhiteSpace($current.TaskName)) { $current.TaskId } else { $current.TaskName })
            Status     = $resolvedStage
            CurrentDoc = $resolvedDoc
            Tool       = $(if ([string]::IsNullOrWhiteSpace($planTool)) { $current.Tool } else { $planTool })
            Next       = $current.NextStep
            FromFlow   = $false
            FromPlan   = Test-CanonicalRuntimeStage -Stage $planStage
            Audit      = ''
        }
    }

    return New-IdleRepairTaskState
}

function Get-LegacyTaskRuntimeMigration {
    <#
    .SYNOPSIS
    将可明确识别的旧 Task Mirror 迁移为 canonical runtime record。

    .DESCRIPTION
    只接受无 schema_version、带精确 Task Mirror 标记、唯一 canonical stage 和
    属于同一 task 的 pointer。任何无法证明的记录由调用方原样保留并告警。
    #>
    param(
        [System.IO.FileInfo]$File,
        [string]$CurrentTaskId
    )

    $text = Get-Content -LiteralPath $File.FullName -Raw -Encoding utf8
    if (-not [string]::IsNullOrWhiteSpace((Get-CanonicalRuntimeYamlField -Text $text -Key 'schema_version')) -or
        $text -notmatch '(?m)^# Task Mirror\s*$') {
        return $null
    }

    $taskId = Get-CanonicalRuntimeYamlField -Text $text -Key 'task_id'
    if (-not (Test-CanonicalRuntimeTaskId -TaskId $taskId) -or $taskId -eq $CurrentTaskId) {
        return $null
    }

    $stage = Get-CanonicalRuntimeYamlField -Text $text -Key 'stage'
    $tool = Get-CanonicalRuntimeYamlField -Text $text -Key 'tool'
    $updated = Get-CanonicalRuntimeYamlField -Text $text -Key 'updated'
    $pointerMatches = @([regex]::Matches($text, '(?m)^-\s+pointer:\s*`?([^`\r\n]+?)`?\s*$'))
    if (-not (Test-CanonicalRuntimeStage -Stage $stage) -or
        [string]::IsNullOrWhiteSpace($tool) -or
        [string]::IsNullOrWhiteSpace($updated) -or
        $pointerMatches.Count -ne 1) {
        return $null
    }

    try {
        $updated = [datetimeoffset]::Parse($updated).ToString('yyyy-MM-ddTHH:mm:sszzz')
    } catch {
        return $null
    }

    $primaryArtifact = $pointerMatches[0].Groups[1].Value.Trim() -replace '\\', '/'
    if ($primaryArtifact -cnotmatch ('^docs/tasks/{0}/(?:plan|test)\.md$' -f [regex]::Escape($taskId))) {
        return $null
    }

    $taskName = Get-CanonicalRuntimeYamlField -Text $text -Key 'task_name'
    if ([string]::IsNullOrWhiteSpace($taskName)) {
        $taskName = $taskId
    }

    $legacyBody = [regex]::Replace($text, '(?s)\A---\r?\n.*?\r?\n---\r?\n?', '').Trim()

    return [pscustomobject]@{
        TaskId          = $taskId
        TaskName        = $taskName
        PrimaryArtifact = $primaryArtifact
        Tool            = $tool
        Updated         = $updated
        Stage           = $stage
        LegacyBody      = $legacyBody
    }
}

function New-LegacyMigratedRuntimeContent {
    <#
    .SYNOPSIS
    生成保留旧正文的 canonical task runtime。
    #>
    param(
        [pscustomobject]$LegacyState,
        [string]$WorkspaceRoot,
        [string]$EntryHost
    )

    $canonical = New-CanonicalTaskRuntimeContent `
        -TaskId $LegacyState.TaskId `
        -TaskName $LegacyState.TaskName `
        -Stage $LegacyState.Stage `
        -WorkspaceRoot $WorkspaceRoot `
        -PrimaryArtifact $LegacyState.PrimaryArtifact `
        -Tool $LegacyState.Tool `
        -EntryHost $EntryHost `
        -Updated $LegacyState.Updated `
        -Writer 'repair-shared-memory'
    $quotedBody = if ([string]::IsNullOrWhiteSpace($LegacyState.LegacyBody)) {
        '> none'
    } else {
        (($LegacyState.LegacyBody -split "`r?`n") | ForEach-Object { '> ' + $_ }) -join "`r`n"
    }

    return $canonical + "`r`n`r`n## Preserved Legacy Details`r`n`r`n- migrated_from_stage: $($LegacyState.Stage)`r`n`r`n$quotedBody"
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
$warnings = @()
$script:ResolvedEntryHost = Get-EntryHostValue -EntryHost $EntryHost
$runtimeMutex = Enter-CanonicalRuntimeMutex -VaultRoot $VaultRoot
try {

if (-not (Test-Path -LiteralPath $paths.RuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Path $paths.RuntimeDir -Force | Out-Null
}

if (Test-Path -LiteralPath $paths.LockPath -PathType Leaf) {
    try {
        $lock = Get-Content -LiteralPath $paths.LockPath -Raw -Encoding utf8 | ConvertFrom-Json
        Remove-Item -LiteralPath $paths.LockPath -Force
        $repairs += ('removed stale runtime.lock.json diagnostic (writer={0}, task={1})' -f $lock.writer, $lock.task_id)
    } catch {
        Remove-Item -LiteralPath $paths.LockPath -Force
        $repairs += 'removed malformed runtime.lock.json'
    }
}

$repairState = Get-RepairTaskState -VaultRoot $VaultRoot
if (-not [string]::IsNullOrWhiteSpace($repairState.Audit)) {
    $repairs += $repairState.Audit
}
$runtimeUpdated = Get-CanonicalRuntimeTimestamp
$lockContent = [ordered]@{
    writer    = 'repair-shared-memory'
    task_id   = $repairState.TaskId
    locked_at = [datetimeoffset]::UtcNow.ToString('o')
    entry_host = $script:ResolvedEntryHost
} | ConvertTo-Json -Depth 3
Write-CanonicalRuntimeUtf8BomAtomic -Path $paths.LockPath -Content $lockContent

try {
    if (-not (Test-Path -LiteralPath $paths.TasksDir -PathType Container)) {
        New-Item -ItemType Directory -Path $paths.TasksDir -Force | Out-Null
        $repairs += ('created {0}' -f $paths.TasksDir)
    }

    $candidatePath = Join-Path $paths.RuntimeDir '记忆候选.md'
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        Write-CanonicalRuntimeUtf8BomAtomic `
            -Path $candidatePath `
            -Content @"
---
tags: [运行时, 记忆, 候选]
created: $today
updated: $today
---

# 记忆候选

| ID | 日期 | 类型 | 内容摘要 | 建议写入 | 来源 | 状态 | 用户确认 |
|----|------|------|----------|----------|------|------|----------|
| 无 | - | - | 当前暂无候选项 | - | - | - | - |
"@
        $repairs += ('created {0}' -f $candidatePath)
    }

    $archivePath = Join-Path $paths.RuntimeDir '记忆候选归档.md'
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-CanonicalRuntimeUtf8BomAtomic `
            -Path $archivePath `
            -Content @"
---
tags: [运行时, 记忆候选归档]
created: $today
updated: $today
---

# 记忆候选归档

| ID | 归档日期 | 类型 | 内容摘要 | 结果 | 目标位置 / 原因 | 备注 |
|----|----------|------|----------|------|-----------------|------|
| 无 | - | - | 当前暂无归档项 | - | - | - |
"@
        $repairs += ('created {0}' -f $archivePath)
    }

    if (-not (Test-Path -LiteralPath $paths.InboxPath -PathType Leaf)) {
        Write-RuntimeInbox -InboxPath $paths.InboxPath -CreatedDate $today -Rows @()
        $repairs += ('created {0}' -f $paths.InboxPath)
    }

    if (-not (Test-Path -LiteralPath $paths.InterruptedPath -PathType Leaf)) {
        Write-CanonicalRuntimeUtf8BomAtomic `
            -Path $paths.InterruptedPath `
            -Content (@(
                '---'
                ('updated: {0}' -f (Get-CurrentTimestamp))
                'derived_from: [运行时/tasks/]'
                '---'
                ''
                '# 中断任务'
                ''
                '| Priority | Updated | Task | TaskId | Status | Next |'
                '|----------|---------|------|--------|--------|------|'
            ) -join "`r`n")
        $repairs += ('created {0}' -f $paths.InterruptedPath)
    }

    if (-not (Test-Path -LiteralPath $paths.LastSessionPath -PathType Leaf)) {
        Write-CanonicalRuntimeUtf8BomAtomic `
            -Path $paths.LastSessionPath `
            -Content (@(
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
            ) -join "`r`n")
        $repairs += ('created {0}' -f $paths.LastSessionPath)
    }

    $currentBeforeRepair = Get-CanonicalCurrentTaskState -Path $paths.CurrentTaskPath
    $currentNeedsRepair = -not $currentBeforeRepair.Exists -or
        $currentBeforeRepair.SchemaVersion -ne 'current-task-pointer/v1.1' -or
        [string]::IsNullOrWhiteSpace($currentBeforeRepair.EntryHost) -or
        [string]::IsNullOrWhiteSpace($currentBeforeRepair.Writer) -or
        [string]::IsNullOrWhiteSpace($currentBeforeRepair.Updated) -or
        $currentBeforeRepair.TaskId -ne $repairState.TaskId -or
        $currentBeforeRepair.Stage -ne $repairState.Status -or
        $currentBeforeRepair.CurrentDoc -ne $repairState.CurrentDoc
    if ($currentNeedsRepair) {
        Write-CanonicalRuntimeUtf8BomAtomic -Path $paths.CurrentTaskPath -Content (New-CanonicalCurrentTaskContent `
            -TaskId $repairState.TaskId `
            -TaskName $repairState.TaskName `
            -Stage $repairState.Status `
            -CurrentDoc $repairState.CurrentDoc `
            -Tool $repairState.Tool `
            -EntryHost $script:ResolvedEntryHost `
            -NextStep $repairState.Next `
            -Updated $runtimeUpdated `
            -Writer 'repair-shared-memory')
        if ($repairState.FromFlow) {
            $repairs += ('migrated missing pointer {0} from current-flow' -f $paths.CurrentTaskPath)
        } else {
            $repairs += ('repaired {0}' -f $paths.CurrentTaskPath)
        }
    }

    $workspaceRoot = Split-Path -Parent $VaultRoot
    $legacyRecords = Get-CanonicalTaskRuntimeRecords -TasksDirectory $paths.TasksDir
    $currentTaskRuntimePath = if (Test-CanonicalRuntimeTaskId -TaskId $repairState.TaskId) {
        [System.IO.Path]::GetFullPath((Join-Path $paths.TasksDir ('{0}.md' -f $repairState.TaskId)))
    } else {
        ''
    }
    foreach ($legacyRecord in @($legacyRecords | Where-Object { -not $_.IsValid })) {
        if (-not [string]::IsNullOrWhiteSpace($currentTaskRuntimePath) -and [System.IO.Path]::GetFullPath($legacyRecord.Path) -ieq $currentTaskRuntimePath) {
            continue
        }
        $legacyState = Get-LegacyTaskRuntimeMigration `
            -File (Get-Item -LiteralPath $legacyRecord.Path) `
            -CurrentTaskId $repairState.TaskId
        if ($null -eq $legacyState) {
            $warnings += ('preserved invalid task runtime for manual recovery: {0}' -f $legacyRecord.Path)
            continue
        }

        Write-CanonicalRuntimeUtf8BomAtomic -Path $legacyRecord.Path -Content (New-LegacyMigratedRuntimeContent `
            -LegacyState $legacyState `
            -WorkspaceRoot $workspaceRoot `
            -EntryHost $script:ResolvedEntryHost)
        $repairs += ('migrated legacy task runtime {0} with stage {1}' -f $legacyRecord.Path, $legacyState.Stage)
    }

    if (-not (Test-IsIdleValue -Value $repairState.TaskId)) {
        $taskRuntimePath = Join-Path $paths.TasksDir ('{0}.md' -f $repairState.TaskId)
        $existingRecord = Get-CanonicalTaskRuntimeRecords -TasksDirectory $paths.TasksDir | Where-Object { $_.Path -eq $taskRuntimePath } | Select-Object -First 1
        if ($null -eq $existingRecord -or -not $existingRecord.IsValid -or $existingRecord.Stage -ne $repairState.Status -or $existingRecord.PrimaryArtifact -ne $repairState.CurrentDoc) {
            Write-CanonicalRuntimeUtf8BomAtomic -Path $taskRuntimePath -Content (New-CanonicalTaskRuntimeContent `
                -TaskId $repairState.TaskId `
                -TaskName $repairState.TaskName `
                -Stage $repairState.Status `
                -WorkspaceRoot $workspaceRoot `
                -PrimaryArtifact $repairState.CurrentDoc `
                -Tool $repairState.Tool `
                -EntryHost $script:ResolvedEntryHost `
                -Updated $runtimeUpdated `
                -Writer 'repair-shared-memory')
            $repairs += ('repaired {0}' -f $taskRuntimePath)
        }
    }

    $inbox = Read-RuntimeInbox -VaultRoot $VaultRoot -NormalizeExisting
    $clearedResult = Clear-LockBlockedRows -Inbox $inbox
    if ($clearedResult.Cleared -gt 0) {
        Write-RuntimeInbox -InboxPath $inbox.Path -CreatedDate $inbox.CreatedDate -Rows $clearedResult.Rows
        $repairs += ('cleared {0} lock-blocked inbox item(s)' -f $clearedResult.Cleared)
    }

    $canonicalCurrent = Get-CanonicalCurrentTaskState -Path $paths.CurrentTaskPath
    $canonicalRecords = Get-CanonicalTaskRuntimeRecords -TasksDirectory $paths.TasksDir
    Write-CanonicalRuntimeUtf8BomAtomic -Path $paths.RecoveryIndexPath -Content (New-CanonicalRecoveryIndexContent `
        -CurrentTask $canonicalCurrent `
        -TaskRecords $canonicalRecords `
        -Updated $runtimeUpdated `
        -Writer 'repair-shared-memory')
    $repairs += ('refreshed {0}' -f $paths.RecoveryIndexPath)

    Remove-Item -LiteralPath $paths.LockPath -Force
} catch {
    if (Test-Path -LiteralPath $paths.LockPath -PathType Leaf) {
        Remove-Item -LiteralPath $paths.LockPath -Force
    }
    throw
}

if ($warnings.Count -gt 0) {
    Write-Output 'STATUS: WARN'
} else {
    Write-Output 'STATUS: PASS'
}
Write-Output ('Repaired: {0}' -f $repairs.Count)
foreach ($item in $repairs) {
    Write-Output ('- {0}' -f $item)
}
if ($warnings.Count -gt 0) {
    Write-Output 'Warnings:'
    foreach ($warning in $warnings) {
        Write-Output ('- {0}' -f $warning)
    }
    exit 1
}
exit 0
} finally {
    if (Test-Path -LiteralPath $paths.LockPath -PathType Leaf) {
        Remove-Item -LiteralPath $paths.LockPath -Force -ErrorAction SilentlyContinue
    }
    Exit-CanonicalRuntimeMutex -Mutex $runtimeMutex
}
