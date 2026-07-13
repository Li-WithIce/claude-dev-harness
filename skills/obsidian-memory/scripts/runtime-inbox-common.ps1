# 共享运行时收件箱公共函数。
# 负责读取 current-flow / 当前任务、解析收件箱表格，并写回规范化文件。
# 这些函数只服务 obsidian-memory 的 PowerShell 脚本。

$script:RuntimeInboxPlaceholderSummary = '当前暂无收件箱事项'
$script:RuntimeInboxHeader = '| created_at | source | task_id | type | status | summary | payload |'
$script:RuntimeInboxDivider = '|------------|--------|---------|------|--------|---------|---------|'

. (Join-Path $PSScriptRoot 'runtime-state-common.ps1')

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

function Get-EntryHostValue {
    <#
    .SYNOPSIS
    解析共享运行时 writer host。

    .PARAMETER EntryHost
    调用方显式传入的 host。

    .OUTPUTS
    System.String.
    #>
    param([string]$EntryHost = '')

    if (-not [string]::IsNullOrWhiteSpace($env:DEV_HARNESS_ENTRY_HOST)) {
        return $env:DEV_HARNESS_ENTRY_HOST.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_DEV_HARNESS_ENTRY_HOST)) {
        return $env:CLAUDE_DEV_HARNESS_ENTRY_HOST.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($EntryHost)) {
        return $EntryHost.Trim()
    }

    return 'unknown'
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

function Resolve-EntryTaskId {
    <#
    .SYNOPSIS
    解析当前入口任务 ID，以当前任务指针为权威来源。

    .PARAMETER VaultRoot
    共享记忆根目录。

    .OUTPUTS
    System.String.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultRoot
    )

    $currentTaskPath = Join-Path $VaultRoot '运行时\当前任务.md'
    if (Test-Path -LiteralPath $currentTaskPath -PathType Leaf) {
        $currentTask = Get-CanonicalCurrentTaskState -Path $currentTaskPath
        $updatedValue = [datetimeoffset]::MinValue
        $hasValidUpdated = [datetimeoffset]::TryParseExact(
            $currentTask.Updated,
            'yyyy-MM-ddTHH:mm:sszzz',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$updatedValue
        )
        $isCanonicalActive = $currentTask.SchemaVersion -eq 'current-task-pointer/v1.1' -and
            (Test-CanonicalRuntimeTaskId -TaskId $currentTask.TaskId) -and
            (Test-CanonicalRuntimeStage -Stage $currentTask.Stage) -and
            $currentTask.Stage -ne 'DONE' -and
            -not [string]::IsNullOrWhiteSpace($currentTask.EntryHost) -and
            -not [string]::IsNullOrWhiteSpace($currentTask.Writer) -and
            -not [string]::IsNullOrWhiteSpace($currentTask.Updated) -and
            $hasValidUpdated -and
            -not [string]::IsNullOrWhiteSpace($currentTask.CurrentDoc)
        if ($isCanonicalActive) {
            return $currentTask.TaskId
        }

        return 'unknown'
    }

    $flow = Get-FlowSnapshot -VaultRoot $VaultRoot
    if (Test-CanonicalRuntimeTaskId -TaskId $flow.TaskId) {
        return $flow.TaskId
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

    $explicitWorkspaceRoot = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        ''
    } else {
        [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
    }

    if (-not [string]::IsNullOrWhiteSpace($VaultRoot)) {
        $vaultWorkspaceRoot = (Split-Path -Parent ([System.IO.Path]::GetFullPath($VaultRoot))).TrimEnd('\', '/')
        if (-not [string]::IsNullOrWhiteSpace($explicitWorkspaceRoot) -and
            -not $explicitWorkspaceRoot.Equals($vaultWorkspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "WorkspaceRoot does not own the explicit VaultRoot: workspace=$explicitWorkspaceRoot vault=$VaultRoot"
        }
        return $vaultWorkspaceRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($explicitWorkspaceRoot)) {
        return $explicitWorkspaceRoot
    }

    foreach ($candidate in @($env:DEV_HARNESS_WORKSPACE_ROOT, $env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT, $env:WORKSPACE_ROOT)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    $cwd = (Get-Location).Path
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

    $VaultRoot = Assert-CanonicalRuntimeVaultRoot -VaultRoot $VaultRoot

    $runtimeDir = Resolve-CanonicalRuntimeContainedPath -Root $VaultRoot -RelativePath '运行时' -Label 'runtime directory'
    $inboxPath = Resolve-CanonicalRuntimeContainedPath -Root $VaultRoot -RelativePath '运行时\收件箱.md' -Label 'runtime inbox'
    return [pscustomobject]@{
        RuntimeDir       = $runtimeDir
        InboxPath        = $inboxPath
        CurrentTaskPath  = Resolve-CanonicalRuntimeContainedPath -Root $VaultRoot -RelativePath '运行时\当前任务.md' -Label 'runtime current task'
        InterruptedPath  = Resolve-CanonicalRuntimeContainedPath -Root $VaultRoot -RelativePath '运行时\中断任务.md' -Label 'runtime interrupted task'
        LastSessionPath  = Resolve-CanonicalRuntimeContainedPath -Root $VaultRoot -RelativePath '运行时\上次会话.md' -Label 'runtime last session'
        RecoveryIndexPath = Resolve-CanonicalRuntimeContainedPath -Root $VaultRoot -RelativePath '运行时\恢复索引.md' -Label 'runtime recovery index'
        TasksDir         = Resolve-CanonicalRuntimeContainedPath -Root $VaultRoot -RelativePath '运行时\tasks' -Label 'runtime task directory'
        LockPath         = Resolve-CanonicalRuntimeContainedPath -Root $VaultRoot -RelativePath '运行时\runtime.lock.json' -Label 'runtime diagnostic lock'
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

function Test-RuntimeInboxPlaceholderRow {
    <#
    .SYNOPSIS
    仅识别完整匹配七列约定的规范占位行。

    .DESCRIPTION
    不得以单个字段判定占位行，否则合法数据行恰好使用 `-`
    或占位摘要时会在 append / fallback 写回中被静默丢弃。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row
    )

    return (
        [string]$Row.CreatedAt -ceq '-' -and
        [string]$Row.Source -ceq '-' -and
        [string]$Row.TaskId -ceq '-' -and
        [string]$Row.Type -ceq '-' -and
        [string]$Row.Status -ceq 'cleared' -and
        [string]$Row.Summary -ceq $script:RuntimeInboxPlaceholderSummary -and
        [string]$Row.Payload -ceq '-'
    )
}

function Get-InboxIdentityDigest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row
    )

    $identity = "$Namespace`n$(Format-InboxRow -Row $Row)"
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
        return [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-InboxRouteTaskId {
    <#
    .SYNOPSIS
    为收件箱行返回稳定的 workflow task id。

    .DESCRIPTION
    合法且已绑定的 task_id 原样返回；空值或 canonical sentinel 使用完整七列行身份
    派生稳定的 inbox task id，确保 create/triage 间崩溃后仍命中同一 plan。

    .PARAMETER Row
    包含标准收件箱列的对象。

    .OUTPUTS
    System.String.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row
    )

    $taskId = [string]$Row.TaskId
    if (Test-CanonicalRuntimeTaskId -TaskId $taskId) {
        return $taskId
    }

    $sentinels = @('none', 'idle', 'unknown')
    if (-not [string]::IsNullOrWhiteSpace($taskId) -and $sentinels -cnotcontains $taskId) {
        throw "Inbox row task_id is neither canonical nor a supported sentinel: $taskId"
    }

    $digest = Get-InboxIdentityDigest -Namespace 'runtime-inbox-route/v1' -Row $Row
    return 'inbox-' + $digest.Substring(0, 58)
}

function Get-InboxRowId {
    <#
    .SYNOPSIS
    从完整七列行身份派生临时精确选择器。

    .DESCRIPTION
    row_id 不参与 workflow task 路由，也不写入持久 schema；相同完整行共享选择器，
    任一列不同都会得到不同选择器。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Row
    )

    $digest = Get-InboxIdentityDigest -Namespace 'runtime-inbox-row/v1' -Row $Row
    return 'row-' + $digest.Substring(0, 60)
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

    $trimmedLine = $Line.Trim()
    if (-not $trimmedLine.StartsWith('|')) {
        return $null
    }
    if ($trimmedLine.Length -lt 2 -or -not $trimmedLine.EndsWith('|')) {
        throw "Runtime inbox table row must start and end with one boundary pipe: $Line"
    }

    $cells = $trimmedLine.Substring(1, $trimmedLine.Length - 2).Split('|') | ForEach-Object { $_.Trim() }
    if ($cells.Count -ne 7) {
        throw "Runtime inbox table row must contain exactly seven columns: $Line"
    }

    $headerCells = @('created_at', 'source', 'task_id', 'type', 'status', 'summary', 'payload')
    $isHeader = $true
    for ($index = 0; $index -lt $headerCells.Count; $index++) {
        if ($cells[$index] -cne $headerCells[$index]) {
            $isHeader = $false
            break
        }
    }
    $isDivider = @($cells | Where-Object { $_ -notmatch '^-+$' }).Count -eq 0
    if ($isHeader -or $isDivider) {
        return $null
    }

    $row = [pscustomobject]@{
        CreatedAt = $cells[0]
        Source    = $cells[1]
        TaskId    = $cells[2]
        Type      = $cells[3]
        Status    = $cells[4]
        Summary   = $cells[5]
        Payload   = $cells[6]
    }

    if (Test-RuntimeInboxPlaceholderRow -Row $row) {
        return $null
    }

    return $row
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
    } elseif ($NormalizeExisting.IsPresent) {
        $needsRewrite = $true
    }

    if ($needsRewrite) {
        if (-not (Test-Path -LiteralPath $paths.RuntimeDir -PathType Container)) {
            New-Item -ItemType Directory -Path $paths.RuntimeDir -Force | Out-Null
        }
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

    Write-CanonicalRuntimeUtf8BomAtomic -Path $InboxPath -Content $content
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
        [AllowEmptyCollection()]
        [pscustomobject[]]$Rows,
        [string]$RowId = '',
        [string]$RouteTaskId = '',
        [string]$CreatedAt = '',
        [string]$TaskId = '',
        [string]$Type = '',
        [string]$Source = '',
        [string]$Summary = '',
        [string]$Payload = '',
        [string]$SummaryContains = ''
    )

    $filtered = @($Rows | Where-Object { $_.Status -ceq 'open' })
    if (-not [string]::IsNullOrWhiteSpace($RowId)) {
        $filtered = @($filtered | Where-Object { (Get-InboxRowId -Row $_) -ceq $RowId })
    }
    if (-not [string]::IsNullOrWhiteSpace($RouteTaskId)) {
        $filtered = @($filtered | Where-Object { (Get-InboxRouteTaskId -Row $_) -ceq $RouteTaskId })
    }
    if (-not [string]::IsNullOrWhiteSpace($CreatedAt)) {
        $filtered = @($filtered | Where-Object { $_.CreatedAt -ceq $CreatedAt })
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $filtered = @($filtered | Where-Object { $_.TaskId -ceq $TaskId })
    }
    if (-not [string]::IsNullOrWhiteSpace($Type)) {
        $filtered = @($filtered | Where-Object { $_.Type -ceq $Type })
    }
    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        $filtered = @($filtered | Where-Object { $_.Source -ceq $Source })
    }
    if (-not [string]::IsNullOrWhiteSpace($Summary)) {
        $filtered = @($filtered | Where-Object { $_.Summary -ceq $Summary })
    }
    if (-not [string]::IsNullOrWhiteSpace($Payload)) {
        $filtered = @($filtered | Where-Object { $_.Payload -ceq $Payload })
    }
    if (-not [string]::IsNullOrWhiteSpace($SummaryContains)) {
        $filtered = @($filtered | Where-Object { $_.Summary.IndexOf($SummaryContains, [System.StringComparison]::Ordinal) -ge 0 })
    }

    return ,@($filtered)
}
