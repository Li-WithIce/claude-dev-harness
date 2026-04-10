# 共享运行时收件箱公共函数。
# 负责读取 current-flow / 当前任务、解析收件箱表格，并写回规范化文件。
# 这些函数只服务 obsidian-memory 的 PowerShell 脚本。

$script:RuntimeInboxPlaceholderSummary = '当前暂无收件箱事项'
$script:RuntimeInboxHeader = '| created_at | source | task_id | type | status | summary | payload |'
$script:RuntimeInboxDivider = '|------------|--------|---------|------|--------|---------|---------|'

function Write-Utf8Bom {
    <#
    .SYNOPSIS
    以 UTF-8 BOM 写入文本文件。

    .PARAMETER Path
    目标文件路径。

    .PARAMETER Content
    要写入的完整文本。

    .OUTPUTS
    None.

    .NOTES
    该函数会覆盖目标文件。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-CurrentTimestamp {
    <#
    .SYNOPSIS
    返回统一格式的当前时间戳。

    .OUTPUTS
    System.String.
    #>
    param()

    return (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}

function Get-TodayDate {
    <#
    .SYNOPSIS
    返回统一格式的当前日期。

    .OUTPUTS
    System.String.
    #>
    param()

    return (Get-Date -Format 'yyyy-MM-dd')
}

function Get-YamlValue {
    <#
    .SYNOPSIS
    从简单 YAML / frontmatter 中读取单行字段值。

    .PARAMETER Path
    要读取的文件路径。

    .PARAMETER Key
    字段名。

    .OUTPUTS
    System.String 或 $null。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $pattern = '^{0}:\s*(.+)$' -f [regex]::Escape($Key)
    $match = Select-String -Path $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    $value = $match.Matches[0].Groups[1].Value.Trim()
    if (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'")) -or
        ($value.StartsWith('`') -and $value.EndsWith('`'))
    ) {
        return $value.Substring(1, $value.Length - 2)
    }

    return $value
}

function Get-TableValue {
    <#
    .SYNOPSIS
    从 Markdown 双列表格中读取指定键的值。

    .PARAMETER Path
    Markdown 文件路径。

    .PARAMETER Key
    表格左列的键名。

    .OUTPUTS
    System.String 或 $null。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $pattern = '^\|\s*{0}\s*\|\s*(.+?)\s*\|$' -f [regex]::Escape($Key)
    $match = Select-String -Path $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

function Remove-MarkdownTicks {
    <#
    .SYNOPSIS
    去掉 Markdown 行内代码包裹。

    .PARAMETER Value
    原始字符串。

    .OUTPUTS
    System.String.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('`') -and $trimmed.EndsWith('`')) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }

    return $trimmed
}

function Test-IsIdleValue {
    <#
    .SYNOPSIS
    判断任务字段是否表示空闲状态。

    .PARAMETER Value
    要判断的字符串。

    .OUTPUTS
    System.Boolean.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }

    $normalized = (Remove-MarkdownTicks -Value $Value).Trim().ToLowerInvariant()
    return $normalized -in @('none', '无', '空闲', 'idle')
}

function Get-FlowSnapshot {
    <#
    .SYNOPSIS
    读取 current-flow 的核心字段。

    .PARAMETER VaultRoot
    共享记忆根目录。

    .OUTPUTS
    PSCustomObject.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultRoot
    )

    $flowPath = Join-Path $VaultRoot 'orchestration\current-flow.md'
    return [pscustomobject]@{
        Path       = $flowPath
        TaskId     = Get-YamlValue -Path $flowPath -Key 'task_id'
        TaskName   = Get-YamlValue -Path $flowPath -Key 'task_name'
        Stage      = Get-YamlValue -Path $flowPath -Key 'stage'
        CurrentDoc = Get-YamlValue -Path $flowPath -Key 'current_doc'
        Next       = Get-YamlValue -Path $flowPath -Key 'next'
    }
}

function Get-CurrentTaskSnapshot {
    <#
    .SYNOPSIS
    读取当前任务共享指针的核心字段。

    .PARAMETER VaultRoot
    共享记忆根目录。

    .OUTPUTS
    PSCustomObject.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultRoot
    )

    $path = Join-Path $VaultRoot '运行时\当前任务.md'
    $taskId = Get-TableValue -Path $path -Key 'task_id'
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        $taskId = Get-YamlValue -Path $path -Key 'task_id'
    }

    return [pscustomobject]@{
        Path     = $path
        TaskId   = Remove-MarkdownTicks -Value $taskId
        TaskName = Get-TableValue -Path $path -Key '任务'
        Status   = Get-TableValue -Path $path -Key '状态'
        Next     = Get-TableValue -Path $path -Key '下一步'
    }
}

function Resolve-EntryTaskId {
    <#
    .SYNOPSIS
    解析当前入口任务 ID，优先 current-flow，再退回当前任务指针。

    .PARAMETER VaultRoot
    共享记忆根目录。

    .OUTPUTS
    System.String.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultRoot
    )

    $flow = Get-FlowSnapshot -VaultRoot $VaultRoot
    if (-not (Test-IsIdleValue -Value $flow.TaskId)) {
        return $flow.TaskId
    }

    $currentTask = Get-CurrentTaskSnapshot -VaultRoot $VaultRoot
    if (-not (Test-IsIdleValue -Value $currentTask.TaskId)) {
        return $currentTask.TaskId
    }

    return 'unknown'
}

function Resolve-WorkspaceRoot {
    <#
    .SYNOPSIS
    解析当前应写入 docs 的工作区根目录。

    .PARAMETER WorkspaceRoot
    显式传入的工作区根目录。

    .PARAMETER VaultRoot
    共享记忆根目录。

    .OUTPUTS
    System.String.
    #>
    param(
        [string]$WorkspaceRoot = '',
        [string]$VaultRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return [System.IO.Path]::GetFullPath($WorkspaceRoot)
    }

    foreach ($candidate in @($env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT, $env:WORKSPACE_ROOT)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $cwd = (Get-Location).Path
    if (Test-Path -LiteralPath (Join-Path $cwd '.assistant') -PathType Container) {
        return [System.IO.Path]::GetFullPath($cwd)
    }

    if (-not [string]::IsNullOrWhiteSpace($VaultRoot)) {
        $normalizedVaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
        if ((Split-Path -Leaf $normalizedVaultRoot) -ieq '.assistant') {
            return (Split-Path -Parent $normalizedVaultRoot)
        }
    }

    return [System.IO.Path]::GetFullPath($cwd)
}

function Get-RuntimeMarkdownPaths {
    <#
    .SYNOPSIS
    返回共享运行时常用路径集合。

    .PARAMETER VaultRoot
    共享记忆根目录。

    .OUTPUTS
    PSCustomObject.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultRoot
    )

    $runtimeDir = Join-Path $VaultRoot '运行时'
    return [pscustomobject]@{
        RuntimeDir       = $runtimeDir
        InboxPath        = Join-Path $runtimeDir '收件箱.md'
        CurrentTaskPath  = Join-Path $runtimeDir '当前任务.md'
        InterruptedPath  = Join-Path $runtimeDir '中断任务.md'
        LastSessionPath  = Join-Path $runtimeDir '上次会话.md'
        RecoveryIndexPath = Join-Path $runtimeDir '恢复索引.md'
        TasksDir         = Join-Path $runtimeDir 'tasks'
        LockPath         = Join-Path $runtimeDir 'runtime.lock.json'
    }
}

function Escape-InboxCell {
    <#
    .SYNOPSIS
    将文本转换成可安全写入 Markdown 表格的单元格。

    .PARAMETER Value
    原始文本。

    .OUTPUTS
    System.String.
    #>
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return '-'
    }

    $normalized = $Value -replace '\r\n', "`n"
    $normalized = $normalized -replace '\r', "`n"
    $normalized = $normalized -replace '\n', ' <br> '
    $normalized = $normalized.Replace('|', [string][char]0xFF5C)
    return $normalized.Trim()
}

function Format-InboxRow {
    <#
    .SYNOPSIS
    将收件箱对象序列化为 Markdown 表格行。

    .PARAMETER Row
    包含标准收件箱列的对象。

    .OUTPUTS
    System.String.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row
    )

    return '| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
        (Escape-InboxCell -Value $Row.CreatedAt), `
        (Escape-InboxCell -Value $Row.Source), `
        (Escape-InboxCell -Value $Row.TaskId), `
        (Escape-InboxCell -Value $Row.Type), `
        (Escape-InboxCell -Value $Row.Status), `
        (Escape-InboxCell -Value $Row.Summary), `
        (Escape-InboxCell -Value $Row.Payload)
}

function Convert-InboxLineToRow {
    <#
    .SYNOPSIS
    将 Markdown 表格行转换成收件箱对象。

    .PARAMETER Line
    单行 Markdown 表格文本。

    .OUTPUTS
    PSCustomObject 或 $null。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line
    )

    if ($Line -notmatch '^\|') {
        return $null
    }

    $cells = $Line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
    if ($cells.Count -lt 7) {
        return $null
    }

    if ($cells[0] -eq 'created_at' -or $cells[0] -match '^-+$') {
        return $null
    }

    return [pscustomobject]@{
        CreatedAt = $cells[0]
        Source    = $cells[1]
        TaskId    = $cells[2]
        Type      = $cells[3]
        Status    = $cells[4]
        Summary   = $cells[5]
        Payload   = $cells[6]
    }
}

function Read-RuntimeInbox {
    <#
    .SYNOPSIS
    读取并规范化共享运行时收件箱。

    .PARAMETER VaultRoot
    共享记忆根目录。

    .OUTPUTS
    PSCustomObject.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultRoot,
        [switch]$NormalizeExisting
    )

    $paths = Get-RuntimeMarkdownPaths -VaultRoot $VaultRoot
    if (-not (Test-Path -LiteralPath $paths.RuntimeDir -PathType Container)) {
        New-Item -ItemType Directory -Path $paths.RuntimeDir -Force | Out-Null
    }

    $created = Get-TodayDate
    $rows = @()
    $needsRewrite = $false

    if (Test-Path -LiteralPath $paths.InboxPath -PathType Leaf) {
        $content = Get-Content -LiteralPath $paths.InboxPath -Raw -Encoding utf8
        $createdValue = Get-YamlValue -Path $paths.InboxPath -Key 'created'
        if (-not [string]::IsNullOrWhiteSpace($createdValue)) {
            $created = $createdValue
        }

        foreach ($line in (Get-Content -LiteralPath $paths.InboxPath -Encoding utf8)) {
            $row = Convert-InboxLineToRow -Line $line
            if ($null -ne $row) {
                $rows += $row
            }
        }

        if (
            $NormalizeExisting.IsPresent -and (
                $content -notmatch 'schema_version:\s+runtime-inbox/v1\.0' -or
                $content -notmatch [regex]::Escape($script:RuntimeInboxHeader) -or
                $content -notmatch '(?m)^# Runtime Inbox$'
            )
        ) {
            $needsRewrite = $true
        }
    } else {
        $needsRewrite = $true
    }

    if ($needsRewrite) {
        Write-RuntimeInbox -InboxPath $paths.InboxPath -CreatedDate $created -Rows $rows
    }

    return [pscustomobject]@{
        Path        = $paths.InboxPath
        CreatedDate = $created
        Rows        = @($rows)
    }
}

function Write-RuntimeInbox {
    <#
    .SYNOPSIS
    将收件箱对象写回标准 Markdown 格式。

    .PARAMETER InboxPath
    收件箱文件路径。

    .PARAMETER CreatedDate
    frontmatter 中的 created 日期。

    .PARAMETER Rows
    要写入的数据行。

    .OUTPUTS
    None.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$InboxPath,
        [Parameter(Mandatory = $true)]
        [string]$CreatedDate,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Rows
    )

    $rowLines = @($Rows | ForEach-Object { Format-InboxRow -Row $_ })
    if ($rowLines.Count -eq 0) {
        $rowLines = @(
            '| - | - | - | - | cleared | {0} | - |' -f $script:RuntimeInboxPlaceholderSummary
        )
    }

    $content = @(
        '---'
        'tags: [runtime, inbox]'
        ('created: {0}' -f $CreatedDate)
        ('updated: {0}' -f (Get-CurrentTimestamp))
        'schema_version: runtime-inbox/v1.0'
        '---'
        ''
        '# Runtime Inbox'
        ''
        $script:RuntimeInboxHeader
        $script:RuntimeInboxDivider
        $rowLines
    ) -join "`r`n"

    Write-Utf8Bom -Path $InboxPath -Content $content
}

function Select-ActiveInboxRows {
    <#
    .SYNOPSIS
    按字面条件筛选 open 状态的收件箱行。

    .PARAMETER Rows
    收件箱行集合。

    .PARAMETER CreatedAt
    精确匹配 created_at。

    .PARAMETER TaskId
    精确匹配 task_id。

    .PARAMETER Type
    精确匹配 type。

    .PARAMETER Source
    精确匹配 source。

    .PARAMETER SummaryContains
    按字面子串匹配 summary。

    .OUTPUTS
    PSCustomObject[].
    #>
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject[]]$Rows,
        [string]$CreatedAt = '',
        [string]$TaskId = '',
        [string]$Type = '',
        [string]$Source = '',
        [string]$SummaryContains = ''
    )

    $filtered = @($Rows | Where-Object { $_.Status -eq 'open' })
    if (-not [string]::IsNullOrWhiteSpace($CreatedAt)) {
        $filtered = @($filtered | Where-Object { $_.CreatedAt -eq $CreatedAt })
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $filtered = @($filtered | Where-Object { $_.TaskId -eq $TaskId })
    }
    if (-not [string]::IsNullOrWhiteSpace($Type)) {
        $filtered = @($filtered | Where-Object { $_.Type -eq $Type })
    }
    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        $filtered = @($filtered | Where-Object { $_.Source -eq $Source })
    }
    if (-not [string]::IsNullOrWhiteSpace($SummaryContains)) {
        $filtered = @($filtered | Where-Object { $_.Summary.Contains($SummaryContains) })
    }

    return ,@($filtered)
}
