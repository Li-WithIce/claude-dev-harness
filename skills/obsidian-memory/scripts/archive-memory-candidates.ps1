param(
    [string]$VaultRoot = "",
    [string[]]$TerminalStatuses = @("promoted", "rejected", "archived")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'resolve-shared-memory-paths.ps1')
$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot

function Update-FrontmatterDate {
# 归档记忆候选中的终态条目。
# 兼容旧版“仅占位提示”格式，并在归档前升级为标准表格。
param(
        [string[]]$Lines,
        [string]$Timestamp
    )

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^updated:\s*') {
            $Lines[$i] = "updated: $Timestamp"
            break
        }
    }

    return ,$Lines
}

function Parse-TableRows {
    param([string[]]$Lines)

    $headerIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -like '| ID *') {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -lt 0) {
        throw "Table header not found."
    }

    $rows = @()
    for ($i = $headerIndex + 2; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not $line.TrimStart().StartsWith('|')) {
            break
        }
        $rows += [pscustomobject]@{
            Index = $i
            Line = $line
        }
    }

    return [pscustomobject]@{
        HeaderIndex = $headerIndex
        DelimiterIndex = $headerIndex + 1
        Rows = $rows
    }
}

function Normalize-ArchiveLines {
    <#
    .SYNOPSIS
    将旧版归档占位内容升级为标准表格。
    .DESCRIPTION
    旧工作区只包含标题和“当前暂无归档项”占位时，先补齐标准表头，
    再交给后续的表格解析和归档写回逻辑处理。
    .PARAMETER Lines
    原始归档文件行数组。
    .OUTPUTS
    System.String[].
    #>
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -like '| ID *') {
            return ,$Lines
        }
    }

    $frontmatterEnd = -1
    $delimiterCount = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq '---') {
            $delimiterCount += 1
            if ($delimiterCount -eq 2) {
                $frontmatterEnd = $i
                break
            }
        }
    }

    $normalized = @()
    if ($frontmatterEnd -ge 0) {
        $normalized += $Lines[0..$frontmatterEnd]
    } else {
        $normalized += @(
            '---'
            'updated: 1970-01-01 00:00:00'
            '---'
        )
    }

    $normalized += @(
        ''
        '# 记忆候选归档'
        ''
        '| ID | 归档日期 | 类型 | 内容摘要 | 结果 | 目标位置 / 原因 | 备注 |'
        '|----|----------|------|----------|------|-----------------|------|'
        '| 无 | - | - | 当前暂无归档项 | - | - | - |'
    )

    return ,$normalized
}

function Split-Columns {
    param([string]$Line)

    $parts = $Line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
    return ,$parts
}

function Build-CandidateRow {
    param([string[]]$Columns)

    if ($Columns.Count -ge 9) {
        return '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f $Columns[0], $Columns[1], $Columns[2], $Columns[3], $Columns[4], $Columns[5], $Columns[6], $Columns[7], $Columns[8]
    }

    return '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $Columns[0], $Columns[1], $Columns[2], $Columns[3], $Columns[4], $Columns[5], $Columns[6], $Columns[7]
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $content = ($Lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-LastTableRowIndex {
    <#
    .SYNOPSIS
    返回表体的最后一行索引。
    .DESCRIPTION
    只有表头和分隔线时，替换范围要停在分隔线，而不是访问不存在的数据行。
    .PARAMETER Table
    Parse-TableRows 返回的结构。
    .OUTPUTS
    Int32。
    #>
    param([pscustomobject]$Table)

    if ($Table.Rows.Count -eq 0) {
        return $Table.DelimiterIndex
    }

    return $Table.Rows[-1].Index
}

$candidatePath = Join-Path $VaultRoot '运行时\记忆候选.md'
$archivePath = Join-Path $VaultRoot '运行时\记忆候选归档.md'

if (-not (Test-Path -LiteralPath $candidatePath)) {
    throw "Candidate file not found: $candidatePath"
}
if (-not (Test-Path -LiteralPath $archivePath)) {
    throw "Archive file not found: $archivePath"
}

$today = Get-Date -Format 'yyyy-MM-dd'
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$candidateLines = Get-Content -Path $candidatePath -Encoding utf8
$archiveLines = Get-Content -Path $archivePath -Encoding utf8
$archiveHasStandardTable = $false
foreach ($line in $archiveLines) {
    if ($line -like '| ID *') {
        $archiveHasStandardTable = $true
        break
    }
}

$candidateTable = Parse-TableRows -Lines $candidateLines
$archiveLines = Normalize-ArchiveLines -Lines $archiveLines
$archiveTable = Parse-TableRows -Lines $archiveLines
$candidateHeaderColumns = Split-Columns -Line $candidateLines[$candidateTable.HeaderIndex]

$candidateRowData = foreach ($row in $candidateTable.Rows) {
    $cols = Split-Columns -Line $row.Line
    if ($cols[0] -eq '无') {
        continue
    }

    [pscustomobject]@{
        Id = $cols[0]
        Date = $cols[1]
        Type = $cols[2]
        Summary = $cols[3]
        SuggestedTarget = $cols[4]
        Source = $cols[5]
        Status = $cols[6]
        Confirmation = $cols[7]
        Created = if ($cols.Count -ge 9) { $cols[8] } else { '-' }
    }
}

$toArchive = @($candidateRowData | Where-Object { $TerminalStatuses -contains $_.Status })
$toKeep = @($candidateRowData | Where-Object { $TerminalStatuses -notcontains $_.Status })

if ($toArchive.Count -eq 0) {
    if (-not $archiveHasStandardTable) {
        $archiveLines = Update-FrontmatterDate -Lines $archiveLines -Timestamp $timestamp
        Write-Utf8Bom -Path $archivePath -Lines $archiveLines
    }
    Write-Output 'STATUS: PASS'
    Write-Output 'Archived: 0'
    Write-Output 'Message: no terminal candidates to archive.'
    exit 0
}

$archiveRows = foreach ($item in $toArchive) {
    $targetOrReason = $item.SuggestedTarget
    if ($item.Status -eq 'rejected' -and -not [string]::IsNullOrWhiteSpace($item.Confirmation) -and $item.Confirmation -ne '待确认') {
        $targetOrReason = $item.Confirmation
    }

    $note = "source=$($item.Source); confirmation=$($item.Confirmation)"
    '| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $item.Id, $today, $item.Type, $item.Summary, $item.Status, $targetOrReason, $note
}

$existingArchiveData = @()
foreach ($row in $archiveTable.Rows) {
    $cols = Split-Columns -Line $row.Line
    if ($cols[0] -eq '无') {
        continue
    }
    $existingArchiveData += $row.Line
}

$newArchiveTableRows = @()
$newArchiveTableRows += $existingArchiveData
$newArchiveTableRows += $archiveRows
if ($newArchiveTableRows.Count -eq 0) {
    $newArchiveTableRows = @('| 无 | - | - | 当前暂无归档项 | - | - | - |')
}

$newCandidateTableRows = @()
foreach ($item in $toKeep) {
    $candidateColumns = @(
        $item.Id,
        $item.Date,
        $item.Type,
        $item.Summary,
        $item.SuggestedTarget,
        $item.Source,
        $item.Status,
        $item.Confirmation
    )
    if ($candidateHeaderColumns.Count -ge 9) {
        $candidateColumns += $item.Created
    }
    $newCandidateTableRows += Build-CandidateRow -Columns $candidateColumns
}
if ($newCandidateTableRows.Count -eq 0) {
    if ($candidateHeaderColumns.Count -ge 9) {
        $newCandidateTableRows = @('| 无 | - | - | 当前暂无候选项 | - | - | - | - | - |')
    } else {
        $newCandidateTableRows = @('| 无 | - | - | 当前暂无候选项 | - | - | - | - |')
    }
}

$candidateLines = Update-FrontmatterDate -Lines $candidateLines -Timestamp $timestamp
$archiveLines = Update-FrontmatterDate -Lines $archiveLines -Timestamp $timestamp

$candidateOutput = @()
for ($i = 0; $i -lt $candidateLines.Count; $i++) {
    if ($i -lt $candidateTable.HeaderIndex) {
        $candidateOutput += $candidateLines[$i]
        continue
    }
    if ($i -eq $candidateTable.HeaderIndex) {
        $candidateOutput += $candidateLines[$i]
        $candidateOutput += $candidateLines[$candidateTable.DelimiterIndex]
        $candidateOutput += $newCandidateTableRows
        $i = Get-LastTableRowIndex -Table $candidateTable
        continue
    }
}

$archiveOutput = @()
for ($i = 0; $i -lt $archiveLines.Count; $i++) {
    if ($i -lt $archiveTable.HeaderIndex) {
        $archiveOutput += $archiveLines[$i]
        continue
    }
    if ($i -eq $archiveTable.HeaderIndex) {
        $archiveOutput += $archiveLines[$i]
        $archiveOutput += $archiveLines[$archiveTable.DelimiterIndex]
        $archiveOutput += $newArchiveTableRows
        $i = Get-LastTableRowIndex -Table $archiveTable
        continue
    }
}

Write-Utf8Bom -Path $candidatePath -Lines $candidateOutput
Write-Utf8Bom -Path $archivePath -Lines $archiveOutput

Write-Output 'STATUS: PASS'
Write-Output ('Archived: {0}' -f $toArchive.Count)
foreach ($item in $toArchive) {
    Write-Output ('- {0} -> {1}' -f $item.Id, $item.Status)
}
exit 0
