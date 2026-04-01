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
    param(
        [string[]]$Lines,
        [string]$Timestamp
    )

    $updated = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^updated:\s*') {
            $Lines[$i] = "updated: $Timestamp"
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        return ,$Lines
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

function Split-Columns {
    param([string]$Line)

    $parts = $Line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
    return ,$parts
}

function Build-CandidateRow {
    param([string[]]$Columns)
    return '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $Columns[0], $Columns[1], $Columns[2], $Columns[3], $Columns[4], $Columns[5], $Columns[6], $Columns[7]
}

function Build-ArchiveRow {
    param(
        [string]$Id,
        [string]$Date,
        [string]$Type,
        [string]$Summary,
        [string]$Result,
        [string]$TargetOrReason,
        [string]$Note
    )

    return '| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $Id, $Date, $Type, $Summary, $Result, $TargetOrReason, $Note
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $content = ($Lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($true)))
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

$candidateTable = Parse-TableRows -Lines $candidateLines
$archiveTable = Parse-TableRows -Lines $archiveLines

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
    }
}

$toArchive = @($candidateRowData | Where-Object { $TerminalStatuses -contains $_.Status })
$toKeep = @($candidateRowData | Where-Object { $TerminalStatuses -notcontains $_.Status })

if ($toArchive.Count -eq 0) {
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
    Build-ArchiveRow -Id $item.Id -Date $today -Type $item.Type -Summary $item.Summary -Result $item.Status -TargetOrReason $targetOrReason -Note $note
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
    $newCandidateTableRows += Build-CandidateRow -Columns @(
        $item.Id,
        $item.Date,
        $item.Type,
        $item.Summary,
        $item.SuggestedTarget,
        $item.Source,
        $item.Status,
        $item.Confirmation
    )
}
if ($newCandidateTableRows.Count -eq 0) {
    $newCandidateTableRows = @('| 无 | - | - | 当前暂无候选项 | - | - | - | - |')
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
        $i = $candidateTable.Rows[-1].Index
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
        $i = $archiveTable.Rows[-1].Index
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
