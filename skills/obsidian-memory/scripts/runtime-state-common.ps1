# Canonical serializers and readers for shared runtime state.
# Retained v1 history only. Ordinary stage and repair entries are retired.

function Assert-LegacyMemoryFlowPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'legacy-history-path-invalid: explicit flow must be a regular file.'
    }
    $parent = [IO.Path]::GetDirectoryName($full)
    while (-not [string]::IsNullOrWhiteSpace($parent)) {
        $directory = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'legacy-history-path-invalid: explicit flow ancestor is not a regular directory.'
        }
        $next = [IO.Path]::GetDirectoryName($parent)
        if ($next -ceq $parent) { break }
        $parent = $next
    }
    return $full
}

function Test-LegacyMemoryHistoryPresent {
    param([Parameter(Mandatory)][string]$VaultRoot, [string]$OrchestratorFlowPath = '')

    # Metadata only. Invalid, inaccessible, or reparse paths are not absence.
    function Get-HistoryBoundaryItem([string]$Path, [bool]$Container, [bool]$AllowMissing) {
        try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] {
            if ($AllowMissing) { return $null }
            throw
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.PSIsContainer -ne $Container) {
            throw 'legacy-history-path-invalid: historical boundary has a reparse or wrong-type path.'
        }
        return $item
    }

    $null = Get-HistoryBoundaryItem $VaultRoot $true $false
    foreach ($parent in @('运行时', 'orchestration', '工作流', '配置')) {
        $null = Get-HistoryBoundaryItem (Join-Path $VaultRoot $parent) $true $true
    }
    $present = $false
    foreach ($relative in @('运行时/当前任务.md', '运行时/恢复索引.md', '运行时/中断任务.md', '运行时/上次会话.md', 'orchestration/current-flow.md')) {
        if ($null -ne (Get-HistoryBoundaryItem (Join-Path $VaultRoot $relative) $false $true)) { $present = $true }
    }
    if ($null -ne (Get-HistoryBoundaryItem (Join-Path $VaultRoot '运行时/tasks') $true $true)) { $present = $true }
    if (-not [string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
        $null = Assert-LegacyMemoryFlowPath -Path $OrchestratorFlowPath
        $present = $true
    }
    return $present
}

$script:CanonicalRuntimeStages = @('PLAN', 'PLAN_REVIEW', 'IMPLEMENT', 'CODE_REVIEW', 'TEST', 'DONE')

function Write-CanonicalRuntimeUtf8BomAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $targetPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($targetPath)
    $tempPath = Join-Path $directory ('.{0}.{1}.{2}.tmp' -f [System.IO.Path]::GetFileName($targetPath), $PID, [guid]::NewGuid().ToString('N'))
    $backupPath = "$tempPath.bak"
    try {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        $preamble = $encoding.GetPreamble()
        $bytes = $encoding.GetBytes($Content)
        $stream = New-Object System.IO.FileStream($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($preamble, 0, $preamble.Length)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }

        if ([System.IO.File]::Exists($targetPath)) {
            [System.IO.File]::Replace($tempPath, $targetPath, $backupPath, $true)
        } else {
            [System.IO.File]::Move($tempPath, $targetPath)
        }
    } finally {
        foreach ($candidate in @($tempPath, $backupPath)) {
            if ([System.IO.File]::Exists($candidate)) {
                [System.IO.File]::Delete($candidate)
            }
        }
    }
}

function Get-CanonicalRuntimeTimestamp {
    param()

    return [datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function ConvertTo-CanonicalRuntimeScalar {
    param([string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return (($Value -replace '[\r\n|]', ' ').Trim())
}

function Get-CanonicalRuntimeYamlField {
    param(
        [string]$Text,
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $matches = [regex]::Matches($Text, ('(?m)^{0}:\s*(.*?)\s*$' -f [regex]::Escape($Key)))
    if ($matches.Count -ne 1) {
        return $null
    }

    return $matches[0].Groups[1].Value.Trim()
}

function Get-CanonicalRuntimeTableValue {
    param(
        [string]$Text,
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $matches = [regex]::Matches($Text, ('(?m)^\|\s*{0}\s*\|\s*(.*?)\s*\|\s*$' -f [regex]::Escape($Key)))
    if ($matches.Count -ne 1) {
        return $null
    }

    return $matches[0].Groups[1].Value.Trim().Trim('`')
}

function Test-CanonicalRuntimeTaskId {
    param([string]$TaskId)

    return -not [string]::IsNullOrWhiteSpace($TaskId) -and
        $TaskId -cmatch '^[a-z0-9][a-z0-9-]{0,63}$' -and
        $TaskId -notin @('none', 'idle', 'unknown')
}

function Test-CanonicalRuntimeStage {
    param([string]$Stage)

    return $script:CanonicalRuntimeStages -ccontains $Stage
}

function Resolve-CanonicalRuntimeContainedPath {
    param(
        [string]$Root,
        [string]$RelativePath,
        [string]$Label = 'path'
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root)
    $volumeRoot = [System.IO.Path]::GetPathRoot($rootPath)
    if ($rootPath.Length -gt $volumeRoot.Length) {
        $rootPath = $rootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its root: $candidate"
    }

    $paths = @()
    $current = $rootPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $paths += $current
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }

    $current = $rootPath
    foreach ($segment in ($candidate.Substring($prefix.Length) -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        $paths += $current
    }
    foreach ($path in $paths) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label contains a reparse point: $path"
        }
    }

    return $candidate
}

function Assert-CanonicalRuntimeVaultRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultRoot,
        [string[]]$AgentRoots = @()
    )

    $normalizedVaultRoot = [System.IO.Path]::GetFullPath($VaultRoot)
    $vaultVolumeRoot = [System.IO.Path]::GetPathRoot($normalizedVaultRoot)
    if ($normalizedVaultRoot.Length -gt $vaultVolumeRoot.Length) {
        $normalizedVaultRoot = $normalizedVaultRoot.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }
    if ((Test-Path -LiteralPath $normalizedVaultRoot) -and -not (Test-Path -LiteralPath $normalizedVaultRoot -PathType Container)) {
        throw "runtime vault root is not a directory: $normalizedVaultRoot"
    }

    if ($AgentRoots.Count -eq 0) {
        $AgentRoots = @($env:CLAUDE_HOME, $env:CODEX_HOME)
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $AgentRoots += @(
                (Join-Path $env:USERPROFILE '.claude'),
                (Join-Path $env:USERPROFILE '.codex')
            )
        }
    }
    foreach ($agentRoot in @($AgentRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
        $normalizedAgentRoot = [System.IO.Path]::GetFullPath($agentRoot)
        $agentVolumeRoot = [System.IO.Path]::GetPathRoot($normalizedAgentRoot)
        if ($normalizedAgentRoot.Length -gt $agentVolumeRoot.Length) {
            $normalizedAgentRoot = $normalizedAgentRoot.TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            )
        }
        if ($normalizedVaultRoot.Equals($normalizedAgentRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedVaultRoot.StartsWith(($normalizedAgentRoot + [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "[vault-layer-violation] user-level agent home cannot host runtime layer: $normalizedVaultRoot"
        }
    }

    $runtimePath = Resolve-CanonicalRuntimeContainedPath -Root $normalizedVaultRoot -RelativePath '运行时' -Label 'runtime vault'
    if ((Test-Path -LiteralPath $runtimePath) -and -not (Test-Path -LiteralPath $runtimePath -PathType Container)) {
        throw "runtime path is not a directory: $runtimePath"
    }
    $inboxPath = Resolve-CanonicalRuntimeContainedPath -Root $normalizedVaultRoot -RelativePath '运行时\收件箱.md' -Label 'runtime inbox'
    if ((Test-Path -LiteralPath $inboxPath) -and -not (Test-Path -LiteralPath $inboxPath -PathType Leaf)) {
        throw "runtime inbox is not a file: $inboxPath"
    }
    return $normalizedVaultRoot
}

function Get-CanonicalRuntimeMutexName {
    # ponytail: one runtime lock avoids path-alias split brain; shard only if measured contention requires a stable workspace id.
    return 'Global\dev-harness.runtime'
}

function Enter-CanonicalRuntimeMutex {
    param(
        [string]$VaultRoot,
        [int]$TimeoutMilliseconds = 5000
    )

    $mutex = New-Object System.Threading.Mutex($false, (Get-CanonicalRuntimeMutexName))
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out waiting for shared runtime lock: $VaultRoot"
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-CanonicalRuntimeMutex {
    param([System.Threading.Mutex]$Mutex)

    if ($null -eq $Mutex) {
        return
    }
    try {
        $Mutex.ReleaseMutex() | Out-Null
    } finally {
        $Mutex.Dispose()
    }
}

function New-CanonicalCurrentTaskContent {
    param(
        [string]$TaskId,
        [string]$TaskName,
        [string]$Stage,
        [string]$CurrentDoc,
        [string]$Tool,
        [string]$EntryHost,
        [string]$NextStep,
        [string]$ToolProfile = '',
        [string]$Model = '',
        [string]$Updated = '',
        [string]$Writer = 'advance-stage'
    )

    if ([string]::IsNullOrWhiteSpace($Updated)) {
        $Updated = Get-CanonicalRuntimeTimestamp
    }

    $lines = @(
        '---',
        'schema_version: current-task-pointer/v1.1',
        ('updated: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Updated)),
        ('task_id: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $TaskId)),
        ('task_name: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $TaskName)),
        ('entry_host: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $EntryHost)),
        ('writer: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Writer)),
        '---',
        '',
        '# 当前任务',
        '',
        '| 项目 | 值 |',
        '|------|-----|',
        ('| task_id | `{0}` |' -f (ConvertTo-CanonicalRuntimeScalar -Value $TaskId)),
        ('| 任务 | {0} |' -f (ConvertTo-CanonicalRuntimeScalar -Value $TaskName)),
        ('| 状态 | {0} |' -f (ConvertTo-CanonicalRuntimeScalar -Value $Stage)),
        ('| 当前文档 | {0} |' -f (ConvertTo-CanonicalRuntimeScalar -Value $CurrentDoc)),
        ('| 工具 | {0} |' -f (ConvertTo-CanonicalRuntimeScalar -Value $Tool))
    )

    if (-not [string]::IsNullOrWhiteSpace($ToolProfile)) {
        $lines += ('| Tool Profile | {0} |' -f (ConvertTo-CanonicalRuntimeScalar -Value $ToolProfile))
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $lines += ('| Model | {0} |' -f (ConvertTo-CanonicalRuntimeScalar -Value $Model))
    }

    $lines += ('| 下一步 | {0} |' -f (ConvertTo-CanonicalRuntimeScalar -Value $NextStep))
    return $lines -join "`r`n"
}

function New-CanonicalTaskRuntimeContent {
    param(
        [string]$TaskId,
        [string]$TaskName,
        [string]$Stage,
        [string]$WorkspaceRoot,
        [string]$ArtifactRoot = '',
        [string]$PrimaryArtifact,
        [string]$Tool,
        [string]$EntryHost,
        [string]$ToolProfile = '',
        [string]$Model = '',
        [string]$LatestPlanReview = '',
        [string]$LatestCodeReview = '',
        [string]$Updated = '',
        [string]$Writer = 'advance-stage'
    )

    if ([string]::IsNullOrWhiteSpace($Updated)) {
        $Updated = Get-CanonicalRuntimeTimestamp
    }

    if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
        $ArtifactRoot = 'docs/tasks/{0}' -f $TaskId
    }
    $lines = @(
        '---',
        'schema_version: task-runtime/v1.1',
        ('task_id: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $TaskId)),
        ('task_name: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $TaskName)),
        ('stage: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Stage)),
        ('workspace: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $WorkspaceRoot)),
        ('artifact_root: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $ArtifactRoot)),
        ('primary_artifact: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $PrimaryArtifact)),
        ('artifact_links: [{0}]' -f (ConvertTo-CanonicalRuntimeScalar -Value $PrimaryArtifact)),
        ('tool: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Tool)),
        ('entry_host: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $EntryHost)),
        ('writer: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Writer)),
        ('updated: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Updated)),
        '---',
        '',
        '# Task Runtime',
        '',
        ('- stage: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Stage)),
        ('- pointer: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $PrimaryArtifact)),
        ('- assigned_tool: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Tool))
    )

    if (-not [string]::IsNullOrWhiteSpace($ToolProfile)) {
        $profileValue = ConvertTo-CanonicalRuntimeScalar -Value $ToolProfile
        $insertIndex = [Array]::IndexOf($lines, '---', 1)
        $lines = @($lines[0..($insertIndex - 1)] + ('tool_profile: {0}' -f $profileValue) + $lines[$insertIndex..($lines.Count - 1)])
        $lines += ('- assigned_tool_profile: {0}' -f $profileValue)
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $modelValue = ConvertTo-CanonicalRuntimeScalar -Value $Model
        $insertIndex = [Array]::IndexOf($lines, '---', 1)
        $lines = @($lines[0..($insertIndex - 1)] + ('model: {0}' -f $modelValue) + $lines[$insertIndex..($lines.Count - 1)])
        $lines += ('- assigned_model: {0}' -f $modelValue)
    }

    $lines += @(
        ('- latest_plan_review: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $LatestPlanReview)),
        ('- latest_code_review: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $LatestCodeReview)),
        ''
    )
    return $lines -join "`r`n"
}

function Get-CanonicalCurrentTaskState {
    param([string]$Path)

    $text = if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw -Encoding utf8 } else { '' }
    return [pscustomobject]@{
        Exists       = -not [string]::IsNullOrWhiteSpace($text)
        SchemaVersion = Get-CanonicalRuntimeYamlField -Text $text -Key 'schema_version'
        TaskId       = Get-CanonicalRuntimeYamlField -Text $text -Key 'task_id'
        TaskName     = Get-CanonicalRuntimeYamlField -Text $text -Key 'task_name'
        Stage        = Get-CanonicalRuntimeTableValue -Text $text -Key '状态'
        CurrentDoc   = Get-CanonicalRuntimeTableValue -Text $text -Key '当前文档'
        Tool         = Get-CanonicalRuntimeTableValue -Text $text -Key '工具'
        EntryHost    = Get-CanonicalRuntimeYamlField -Text $text -Key 'entry_host'
        NextStep     = Get-CanonicalRuntimeTableValue -Text $text -Key '下一步'
        Updated      = Get-CanonicalRuntimeYamlField -Text $text -Key 'updated'
        Writer       = Get-CanonicalRuntimeYamlField -Text $text -Key 'writer'
        Raw          = $text
    }
}

function Get-CanonicalTaskRuntimeRecords {
    param([string]$TasksDirectory)

    if (-not (Test-Path -LiteralPath $TasksDirectory -PathType Container)) {
        return @()
    }

    $records = @()
    foreach ($file in Get-ChildItem -LiteralPath $TasksDirectory -Filter '*.md' -File) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        $taskId = Get-CanonicalRuntimeYamlField -Text $text -Key 'task_id'
        $stage = Get-CanonicalRuntimeYamlField -Text $text -Key 'stage'
        $updated = Get-CanonicalRuntimeYamlField -Text $text -Key 'updated'
        $required = @('schema_version', 'task_id', 'task_name', 'stage', 'workspace', 'artifact_root', 'primary_artifact', 'artifact_links', 'entry_host', 'writer', 'updated')
        $missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace((Get-CanonicalRuntimeYamlField -Text $text -Key $_)) })
        $updatedValue = $null
        try {
            $updatedValue = [datetimeoffset]::Parse($updated)
        } catch {
            # The invalid timestamp is reported through IsValid.
        }

        $records += [pscustomobject]@{
            Path            = $file.FullName
            FileName        = $file.Name
            SchemaVersion   = Get-CanonicalRuntimeYamlField -Text $text -Key 'schema_version'
            TaskId          = $taskId
            TaskName        = Get-CanonicalRuntimeYamlField -Text $text -Key 'task_name'
            Stage           = $stage
            Workspace       = Get-CanonicalRuntimeYamlField -Text $text -Key 'workspace'
            ArtifactRoot    = Get-CanonicalRuntimeYamlField -Text $text -Key 'artifact_root'
            PrimaryArtifact = Get-CanonicalRuntimeYamlField -Text $text -Key 'primary_artifact'
            EntryHost       = Get-CanonicalRuntimeYamlField -Text $text -Key 'entry_host'
            Writer          = Get-CanonicalRuntimeYamlField -Text $text -Key 'writer'
            Updated         = $updated
            UpdatedValue    = $updatedValue
            IsValid         = $missing.Count -eq 0 -and
                (Get-CanonicalRuntimeYamlField -Text $text -Key 'schema_version') -eq 'task-runtime/v1.1' -and
                (Test-CanonicalRuntimeTaskId -TaskId $taskId) -and
                (Test-CanonicalRuntimeStage -Stage $stage) -and
                $null -ne $updatedValue
        }
    }

    return @($records)
}

function New-CanonicalRecoveryIndexContent {
    param(
        [pscustomobject]$CurrentTask,
        [pscustomobject[]]$TaskRecords,
        [int]$TopN = 3,
        [string]$Updated = '',
        [string]$Writer = 'advance-stage'
    )

    if ([string]::IsNullOrWhiteSpace($Updated)) {
        $Updated = Get-CanonicalRuntimeTimestamp
    }

    $currentId = ConvertTo-CanonicalRuntimeScalar -Value $CurrentTask.TaskId
    $incomplete = @($TaskRecords | Where-Object {
            $null -ne $_ -and $_.IsValid -and $_.Stage -ne 'DONE' -and $_.TaskId -ne $currentId
        } | Sort-Object @{ Expression = 'UpdatedValue'; Descending = $true }, @{ Expression = 'TaskId'; Descending = $false } | Select-Object -First $TopN)

    $lines = @(
        '---',
        'tags: [运行时, 恢复索引]',
        ('updated: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Updated)),
        'derived_from: [运行时/当前任务.md, 运行时/tasks/]',
        'schema_version: recovery-index/v1.1',
        ('writer: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $Writer)),
        '---',
        '',
        '# 恢复索引',
        '',
        '## 当前主任务',
        ('- task_id: `{0}`' -f $currentId),
        ('- 任务: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $CurrentTask.TaskName)),
        ('- 状态: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $CurrentTask.Stage)),
        ('- 当前文档: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $CurrentTask.CurrentDoc)),
        ('- 下一步: {0}' -f (ConvertTo-CanonicalRuntimeScalar -Value $CurrentTask.NextStep)),
        '',
        ('## 未完成任务 Top {0}' -f $TopN)
    )

    if ($incomplete.Count -eq 0) {
        $lines += '- 无'
    } else {
        foreach ($record in $incomplete) {
            $lines += ('- task_id: `{0}` | stage: {1} | updated: {2} | current_doc: {3}' -f $record.TaskId, $record.Stage, $record.Updated, $record.PrimaryArtifact)
        }
    }

    return $lines -join "`r`n"
}
