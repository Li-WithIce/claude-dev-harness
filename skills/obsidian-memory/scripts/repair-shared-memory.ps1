param(
    [string]$VaultRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'resolve-shared-memory-paths.ps1')
$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-YamlField {
    param(
        [string]$Path,
        [string]$Field
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $pattern = '^{0}:\s*(.+)$' -f [regex]::Escape($Field)
    $match = Select-String -Path $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-UpdatedTime {
    param([string]$Path)

    $value = Get-YamlField -Path $Path -Field 'updated'
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    try {
        return [datetime]::Parse($value, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

function Get-TableValue {
    param(
        [string]$Path,
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $pattern = '^\|\s*{0}\s*\|\s*(.+?)\s*\|$' -f [regex]::Escape($Key)
    $match = Select-String -Path $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-InterruptedRows {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $lines = Get-Content -Path $Path -Encoding utf8
    $rows = @()
    foreach ($line in $lines) {
        if ($line -match '^\|\s*P\d+\s*\|') {
            $parts = $line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
            if ($parts.Count -ge 5) {
                $rows += [pscustomobject]@{
                    Priority = $parts[0]
                    Task = $parts[2]
                    Status = $parts[3]
                    Next = $parts[4]
                }
            }
        }
    }
    return $rows | Select-Object -First 3
}

function Ensure-File {
    param(
        [string]$Path,
        [string]$Content
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Utf8Bom -Path $Path -Content $Content
        return $true
    }

    return $false
}

$runtimeDir = Join-Path $VaultRoot '运行时'
$currentPath = Join-Path $runtimeDir '当前任务.md'
$interruptedPath = Join-Path $runtimeDir '中断任务.md'
$lastSessionPath = Join-Path $runtimeDir '上次会话.md'
$indexPath = Join-Path $runtimeDir '恢复索引.md'
$candidatePath = Join-Path $runtimeDir '记忆候选.md'
$archivePath = Join-Path $runtimeDir '记忆候选归档.md'

$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$today = Get-Date -Format 'yyyy-MM-dd'
$repairs = @()

$candidateTemplate = @"
---
tags: [运行时, 记忆, 候选]
created: $today
updated: $today
---

# 记忆候选

> [!note] 使用说明
> 这里只记录“可能值得提升为长期记忆、但尚未得到用户确认”的候选项。
> 已确认并稳定的内容再写入 `配置/*.md`；不要直接越过此文件。

| ID | 日期 | 类型 | 内容摘要 | 建议写入 | 来源 | 状态 | 用户确认 |
|----|------|------|----------|----------|------|------|----------|
| 无 | - | - | 当前暂无候选项 | - | - | - | - |
"@

$archiveTemplate = @"
---
tags: [运行时, 记忆, 归档]
created: $today
updated: $today
---

# 记忆候选归档

> [!note] 使用说明
> 这里归档已经结束生命周期的候选项，例如已提升、已否决、或已清理的候选。
> 当前仍待确认的候选留在 `运行时/记忆候选.md`，不要提前挪到这里。

| ID | 归档日期 | 类型 | 内容摘要 | 结果 | 目标位置 / 原因 | 备注 |
|----|----------|------|----------|------|-----------------|------|
| 无 | - | - | 当前暂无归档项 | - | - | - |
"@

if (Ensure-File -Path $candidatePath -Content $candidateTemplate) {
    $repairs += "created $candidatePath"
}
if (Ensure-File -Path $archivePath -Content $archiveTemplate) {
    $repairs += "created $archivePath"
}

# --- 并行写保护修复 ---

# 确保 tasks 目录存在
$tasksDir = Join-Path $runtimeDir 'tasks'
if (-not (Test-Path -LiteralPath $tasksDir -PathType Container)) {
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    $repairs += "created $tasksDir"
}

# 清理过期锁
$lockPath = Join-Path $runtimeDir 'runtime.lock.json'
if (Test-Path -LiteralPath $lockPath) {
    try {
        $lockContent = Get-Content -Path $lockPath -Encoding utf8 -Raw | ConvertFrom-Json
        $lockedAt = [datetime]::Parse($lockContent.locked_at, [System.Globalization.CultureInfo]::InvariantCulture)
        $lockAge = (Get-Date) - $lockedAt
        if ($lockAge.TotalMinutes -gt 30) {
            Remove-Item -LiteralPath $lockPath -Force
            $repairs += "removed expired runtime.lock.json (age={0:N0}min, writer={1})" -f $lockAge.TotalMinutes, $lockContent.writer
        }
    } catch {
        Remove-Item -LiteralPath $lockPath -Force
        $repairs += "removed malformed runtime.lock.json"
    }
}

$indexUpdated = Get-UpdatedTime -Path $indexPath
$currentUpdated = Get-UpdatedTime -Path $currentPath
$interruptedUpdated = Get-UpdatedTime -Path $interruptedPath
$lastUpdated = Get-UpdatedTime -Path $lastSessionPath
$sourceTimes = @($currentUpdated, $interruptedUpdated, $lastUpdated) | Where-Object { $null -ne $_ }
$needsIndexRefresh = $false

if (-not (Test-Path -LiteralPath $indexPath)) {
    $needsIndexRefresh = $true
} elseif ($sourceTimes.Count -gt 0) {
    $latestSource = $sourceTimes | Sort-Object -Descending | Select-Object -First 1
    if ($null -eq $indexUpdated -or $indexUpdated -lt $latestSource) {
        $needsIndexRefresh = $true
    }
}

if ($needsIndexRefresh) {
    $task = Get-TableValue -Path $currentPath -Key '任务'
    $status = Get-TableValue -Path $currentPath -Key '状态'
    $lastStep = Get-TableValue -Path $currentPath -Key '上次完成步骤'
    $nextStep = Get-TableValue -Path $currentPath -Key '下一步'

    $lastDate = Get-TableValue -Path $lastSessionPath -Key '日期'
    $lastTask = Get-TableValue -Path $lastSessionPath -Key '任务'
    $lastStatus = Get-TableValue -Path $lastSessionPath -Key '状态'
    $lastSummary = Get-TableValue -Path $lastSessionPath -Key '摘要'

    $interruptedRows = Get-InterruptedRows -Path $interruptedPath
    $interruptedBlock = if ($interruptedRows.Count -eq 0) {
        "- 无"
    } else {
        ($interruptedRows | ForEach-Object {
            "- [{0}] {1} | {2} | {3}" -f $_.Priority, $_.Task, $_.Status, $_.Next
        }) -join "`r`n"
    }

    $indexContent = @(
        '---'
        'tags: [运行时, 恢复索引]'
        'created: 2026-03-13'
        "updated: $now"
        '---'
        ''
        '# 恢复索引'
        ''
        '继续任务时先读本文；只在信息不足时再回读详细运行时文件。'
        ''
        '## 当前主任务'
        "- 任务: $task"
        "- 状态: $status"
        "- 上次完成: $lastStep"
        "- 下一步: $nextStep"
        ''
        '## 中断任务 Top 3'
        $interruptedBlock
        ''
        '## 上次会话'
        "- $lastDate | $lastTask | $lastStatus"
        "- 摘要: $lastSummary"
        ''
        '## 回退读取'
        '- 详细不足时，再读：`当前任务.md -> 中断任务.md -> 上次会话.md`'
    ) -join [Environment]::NewLine

    Write-Utf8Bom -Path $indexPath -Content $indexContent
    $repairs += "refreshed $indexPath"
}

if ($repairs.Count -eq 0) {
    Write-Output 'STATUS: PASS'
    Write-Output 'Repaired: 0'
    Write-Output 'Message: no repair needed.'
    exit 0
}

Write-Output 'STATUS: PASS'
Write-Output ('Repaired: {0}' -f $repairs.Count)
foreach ($item in $repairs) {
    Write-Output ('- {0}' -f $item)
}
exit 0
