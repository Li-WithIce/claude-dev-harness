param(
    [string]$VaultRoot = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'resolve-shared-memory-paths.ps1')
. (Join-Path $scriptRoot 'runtime-state-common.ps1')
$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath

# This retained checker diagnoses v1 history only, never current v2 Runtime.
# Fresh optional Memory does not require retired mirrors to be reconstructed.
try {
    $hasHistory = Test-LegacyMemoryHistoryPresent -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
    if (-not $hasHistory) {
        foreach ($relative in @('工作流/共享记忆协议.md', '工作流/记忆管理协议.md', '运行时/收件箱.md', '运行时/记忆候选.md', '配置/系统信息.md', '配置/用户偏好.md', '配置/工具与组件.md')) {
            $item = Get-Item -LiteralPath (Join-Path $VaultRoot $relative) -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'memory-asset-path-invalid' }
        }
        Write-Output 'STATUS: NOT_APPLICABLE'
        Write-Output 'Scope: historical-v1-only'
        Write-Output 'Reason: no retained v1 mirrors; v2 Runtime health was not checked. Do not recreate retired mirrors.'
        exit 0
    }
} catch {
    Write-Output 'STATUS: FAIL'
    Write-Output 'Scope: historical-v1-only'
    Write-Output 'Reason: missing optional Memory assets or invalid/unavailable historical boundary.'
    exit 2
}

$errors = @()
$warnings = @()
$checks = @()
$infos = @()

function Add-Check {
    param([string]$Message)
    $script:checks += $Message
}

function Add-Info {
    param([string]$Message)
    $script:infos += $Message
}

function Add-Warning {
    param([string]$Message)
    $script:warnings += $Message
}

function Add-Error {
    param([string]$Message)
    $script:errors += $Message
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
    $match = Select-String -LiteralPath $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-InlineArrayValues {
    param(
        [string]$Path,
        [string]$Field
    )

    $rawValue = Get-YamlField -Path $Path -Field $Field
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return @()
    }

    $trimmedValue = $rawValue.Trim()
    if (-not ($trimmedValue.StartsWith('[') -and $trimmedValue.EndsWith(']'))) {
        return @()
    }

    $inner = $trimmedValue.Substring(1, $trimmedValue.Length - 2)
    if ([string]::IsNullOrWhiteSpace($inner)) {
        return @()
    }

    return @(
        $inner.Split(',') |
            ForEach-Object { $_.Trim().Trim('"', '''', '`') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Test-HasConcreteArrayValue {
    param([string[]]$Values)

    foreach ($value in @($Values)) {
        if ($value -and $value -notmatch '^\s*<.+>\s*$') {
            return $true
        }
    }

    return $false
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
        Add-Warning ('无法解析更新时间: {0} -> {1}' -f $Path, $value)
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
    $match = Select-String -LiteralPath $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-BulletValue {
    param(
        [string]$Path,
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $pattern = '^\-\s*{0}\s*:\s*(.+)$' -f [regex]::Escape($Key)
    $match = Select-String -LiteralPath $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-CurrentTaskId {
    param([string]$Path)

    $taskId = Get-YamlField -Path $Path -Field 'task_id'
    if ([string]::IsNullOrWhiteSpace($taskId)) {
        $taskId = Get-TableValue -Path $Path -Key 'task_id'
    }

    if ([string]::IsNullOrWhiteSpace($taskId)) {
        return $null
    }

    return $taskId.Trim()
}

function Normalize-StatePathValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmedValue = $Value.Trim()
    if ($trimmedValue -eq 'none') {
        return $null
    }

    return $trimmedValue
}

function Get-WorkspaceRootFromFlowPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $flowDir = Split-Path -Parent $Path
    $assistantDir = Split-Path -Parent $flowDir

    return (Split-Path -Parent $assistantDir)
}

function Get-LikelyMojibakeHits {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $pattern = '鍥|锛|銆|鈥|鏈€|褰撳墠|浠诲姟|鐢ㄦ埛|宸插|缁撴灉|璇锋眰|闃舵|鍐欏洖|杩涘害|琛ュ厖|杩涘睍|�|[\uE000-\uF8FF]'
    return @(Select-String -LiteralPath $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 5)
}

function Resolve-WorkspacePath {
    param(
        [string]$PathValue,
        [string]$WorkspaceRoot
    )

    $trimmedPath = Normalize-StatePathValue -Value $PathValue
    if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($trimmedPath)) {
        return [System.IO.Path]::GetFullPath($trimmedPath)
    }

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return [System.IO.Path]::GetFullPath($trimmedPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $trimmedPath))
}

function Get-CurrentTaskArtifactResolution {
    param(
        [string]$TaskId,
        [string]$OrchestratorFlowPath
    )

    $emptyResult = [pscustomobject]@{
        ResolvedPaths         = @()
        ExplicitResolvedPaths = @()
        MissingExplicitPaths  = @()
        ArtifactRootProvided  = $false
        ArtifactRootPath      = $null
        ArtifactRootExists    = $false
    }

    if ([string]::IsNullOrWhiteSpace($OrchestratorFlowPath) -or -not (Test-Path -LiteralPath $OrchestratorFlowPath -PathType Leaf)) {
        return $emptyResult
    }

    $workspaceRoot = Get-WorkspaceRootFromFlowPath -Path $OrchestratorFlowPath
    $artifactFields = @(
        'spec_path',
        'spec_review_path',
        'plan_path',
        'plan_review_path',
        'review_path',
        'test_path',
        'implementation_notes_path',
        'current_doc'
    )

    $resolvedExplicitPaths = @()
    $missingExplicitPaths = @()
    foreach ($field in $artifactFields) {
        $fieldValue = Normalize-StatePathValue -Value (Get-YamlField -Path $OrchestratorFlowPath -Field $field)
        if ([string]::IsNullOrWhiteSpace($fieldValue)) {
            continue
        }

        $resolvedPath = Resolve-WorkspacePath -PathValue $fieldValue -WorkspaceRoot $workspaceRoot
        if (-not [string]::IsNullOrWhiteSpace($resolvedPath) -and (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            $resolvedExplicitPaths += $resolvedPath
        } else {
            $missingExplicitPaths += ('{0}={1}' -f $field, $resolvedPath)
        }
    }

    $artifactRootValue = Normalize-StatePathValue -Value (Get-YamlField -Path $OrchestratorFlowPath -Field 'artifact_root')
    $artifactRootProvided = -not [string]::IsNullOrWhiteSpace($artifactRootValue)
    $artifactRootPath = Resolve-WorkspacePath -PathValue $artifactRootValue -WorkspaceRoot $workspaceRoot
    if ([string]::IsNullOrWhiteSpace($artifactRootPath) -and -not [string]::IsNullOrWhiteSpace($TaskId) -and -not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
        $artifactRootPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $workspaceRoot 'docs/tasks') $TaskId))
    }

    $artifactNames = @(
        'spec.md',
        'spec-review.md',
        'plan.md',
        'plan-review.md',
        'review.md',
        'test.md',
        'implementation-notes.md'
    )

    $artifactRootResolvedPaths = @()
    $artifactRootExists = -not [string]::IsNullOrWhiteSpace($artifactRootPath) -and (Test-Path -LiteralPath $artifactRootPath -PathType Container)
    if ($artifactRootExists) {
        $artifactRootResolvedPaths = @(
            $artifactNames |
                ForEach-Object { Join-Path $artifactRootPath $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Sort-Object -Unique
        )
    }

    return [pscustomobject]@{
        ResolvedPaths         = @($resolvedExplicitPaths + $artifactRootResolvedPaths | Sort-Object -Unique)
        ExplicitResolvedPaths = @($resolvedExplicitPaths | Sort-Object -Unique)
        MissingExplicitPaths  = @($missingExplicitPaths | Sort-Object -Unique)
        ArtifactRootProvided  = $artifactRootProvided
        ArtifactRootPath      = $artifactRootPath
        ArtifactRootExists    = $artifactRootExists
    }
}

$workflowDir = Join-Path $VaultRoot '工作流'
$runtimeDir = Join-Path $VaultRoot '运行时'
$configDir = Join-Path $VaultRoot '配置'

$requiredFiles = @(
    (Join-Path $workflowDir '共享记忆协议.md'),
    (Join-Path $workflowDir '写回协议.md'),
    (Join-Path $workflowDir '恢复协议.md'),
    (Join-Path $workflowDir '记忆管理协议.md'),
    (Join-Path $runtimeDir '恢复索引.md'),
    (Join-Path $runtimeDir '当前任务.md'),
    (Join-Path $runtimeDir '中断任务.md'),
    (Join-Path $runtimeDir '上次会话.md'),
    (Join-Path $runtimeDir '收件箱.md'),
    (Join-Path $runtimeDir '记忆候选.md'),
    (Join-Path $configDir '系统信息.md'),
    (Join-Path $configDir '用户偏好.md'),
    (Join-Path $configDir '工具与组件.md')
)

foreach ($path in $requiredFiles) {
    if (Test-Path -LiteralPath $path) {
        Add-Check ('存在: {0}' -f $path)
    } else {
        Add-Error ('缺少必需文件: {0}' -f $path)
    }
}

$indexPath = Join-Path $runtimeDir '恢复索引.md'
$currentPath = Join-Path $runtimeDir '当前任务.md'
$interruptedPath = Join-Path $runtimeDir '中断任务.md'
$lastSessionPath = Join-Path $runtimeDir '上次会话.md'
$candidatePath = Join-Path $runtimeDir '记忆候选.md'
$taskIdFromCurrent = Get-CurrentTaskId -Path $currentPath
$taskIdFromFlow = $null

$indexUpdated = Get-UpdatedTime -Path $indexPath
$currentUpdated = Get-UpdatedTime -Path $currentPath
$interruptedUpdated = Get-UpdatedTime -Path $interruptedPath
$lastUpdated = Get-UpdatedTime -Path $lastSessionPath
$currentEntryHost = Get-YamlField -Path $currentPath -Field 'entry_host'
$recoveryDerivedFrom = Get-InlineArrayValues -Path $indexPath -Field 'derived_from'
$interruptedDerivedFrom = Get-InlineArrayValues -Path $interruptedPath -Field 'derived_from'

if (-not [string]::IsNullOrWhiteSpace($currentEntryHost)) {
    Add-Check ('当前任务 entry_host={0}' -f $currentEntryHost)
} elseif (Test-Path -LiteralPath $currentPath -PathType Leaf) {
    Add-Warning ('当前任务缺少 entry_host，按 legacy fallback 处理: {0}' -f $currentPath)
}

if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
    if (Test-HasConcreteArrayValue -Values $recoveryDerivedFrom) {
        Add-Check ('恢复索引声明 derived_from: {0}' -f ($recoveryDerivedFrom -join ', '))
    } else {
        Add-Warning ('恢复索引缺少可用 derived_from: {0}' -f $indexPath)
    }
}

if (Test-Path -LiteralPath $interruptedPath -PathType Leaf) {
    if (Test-HasConcreteArrayValue -Values $interruptedDerivedFrom) {
        Add-Check ('中断任务声明 derived_from: {0}' -f ($interruptedDerivedFrom -join ', '))
    } else {
        Add-Warning ('中断任务缺少可用 derived_from: {0}' -f $interruptedPath)
    }
}

$currentTaskValue = Get-TableValue -Path $currentPath -Key '任务'
$hasActiveCurrentTask = -not [string]::IsNullOrWhiteSpace($currentTaskValue) -and $currentTaskValue -notlike '无*'
$interruptedContent = if (Test-Path -LiteralPath $interruptedPath -PathType Leaf) {
    Get-Content -LiteralPath $interruptedPath -Raw -Encoding utf8
} else {
    ''
}
$hasInterruptedTasks = $interruptedContent -match '(?m)^\|\s*P\d+\s*\|'
$sourceTimes = @($currentUpdated)
if ($hasInterruptedTasks) {
    $sourceTimes += $interruptedUpdated
}
if (-not $hasActiveCurrentTask) {
    $sourceTimes += $lastUpdated
}
$sourceTimes = @($sourceTimes | Where-Object { $null -ne $_ })
if ($null -ne $indexUpdated -and $sourceTimes.Count -gt 0) {
    $latestSource = $sourceTimes | Sort-Object -Descending | Select-Object -First 1
    if ($indexUpdated -lt $latestSource) {
        Add-Warning ('恢复索引比运行时真相源旧: 恢复索引={0}, 最新源={1}' -f $indexUpdated, $latestSource)
    } else {
        Add-Check '恢复索引更新时间不早于当前任务/中断任务/上次会话'
    }
}
if (-not [string]::IsNullOrWhiteSpace($OrchestratorFlowPath) -and (Test-Path -LiteralPath $OrchestratorFlowPath -PathType Leaf) -and (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
    $flowNext = (Get-YamlField -Path $OrchestratorFlowPath -Field 'next')
    $indexNext = (Get-BulletValue -Path $indexPath -Key '下一步')
    if (
        -not [string]::IsNullOrWhiteSpace($flowNext) -and
        -not [string]::IsNullOrWhiteSpace($indexNext) -and
        $flowNext.Trim() -ne $indexNext.Trim()
    ) {
        Add-Warning ('恢复索引下一步与 current-flow.next 不一致: recovery-index={0}, current-flow={1}' -f $indexNext, $flowNext)
    }
}

$taskValue = $currentTaskValue
$statusValue = Get-TableValue -Path $currentPath -Key '状态'
if ($null -ne $taskValue -and $null -ne $statusValue) {
    if ($taskValue -like '无*' -and $statusValue -ne '空闲') {
        Add-Warning ('当前任务显示为空，但状态不是空闲: 任务={0}, 状态={1}' -f $taskValue, $statusValue)
    }
    if ($taskValue -notlike '无*' -and $statusValue -eq '空闲') {
        Add-Warning ('当前任务非空，但状态仍为空闲: 任务={0}, 状态={1}' -f $taskValue, $statusValue)
    }
}

if (Test-Path -LiteralPath $candidatePath) {
    $candidateContent = Get-Content -LiteralPath $candidatePath -Encoding utf8 -Raw
    if ($candidateContent -match '\|\s*ID\s*\|\s*日期\s*\|\s*类型\s*\|') {
        Add-Check '记忆候选.md 含标准表头'
    } else {
        Add-Warning '记忆候选.md 缺少标准表头'
    }
}
$inboxPath = Join-Path $runtimeDir '收件箱.md'
if (Test-Path -LiteralPath $inboxPath -PathType Leaf) {
    $inboxContent = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
    if ($inboxContent -match [regex]::Escape('| created_at | source | task_id | type | status | summary | payload |')) {
        $activeInboxCount = 0
        $lockBlockedCount = 0
        foreach ($line in ($inboxContent -split "`r?`n")) {
            if (-not $line.TrimStart().StartsWith('|')) {
                continue
            }

            $cells = $line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
            if ($cells.Count -ne 7) {
                continue
            }

            $type = $cells[3]
            $status = $cells[4]
            if ($type -eq 'type' -or $type -eq '------' -or $type -eq '-') {
                continue
            }
            if ($status -match '^(?i:resolved|closed|done|cleared)$') {
                continue
            }

            $activeInboxCount += 1
            if ($type -eq 'lock-blocked') {
                $lockBlockedCount += 1
            }
        }

        if ($activeInboxCount -gt 0) {
            Add-Error ('收件箱存在未处理项: active={0}, lock_blocked={1}' -f $activeInboxCount, $lockBlockedCount)
        }
    }
}

$artifactTaskId = $taskIdFromCurrent
if (-not [string]::IsNullOrWhiteSpace($OrchestratorFlowPath) -and (Test-Path -LiteralPath $OrchestratorFlowPath -PathType Leaf)) {
    $taskIdFromFlow = Get-CurrentTaskId -Path $OrchestratorFlowPath
    if (-not [string]::IsNullOrWhiteSpace($taskIdFromFlow)) {
        $artifactTaskId = $taskIdFromFlow
    }
}

$artifactResolution = Get-CurrentTaskArtifactResolution -TaskId $artifactTaskId -OrchestratorFlowPath $OrchestratorFlowPath
$taskArtifactPaths = @($artifactResolution.ResolvedPaths)
if ($artifactResolution.MissingExplicitPaths.Count -gt 0) {
    Add-Error ('orchestrator current-flow 中的当前任务文档路径无效: {0}' -f ($artifactResolution.MissingExplicitPaths -join ', '))
}
if ($artifactResolution.ArtifactRootProvided -and -not $artifactResolution.ArtifactRootExists) {
    Add-Error ('orchestrator current-flow 的 artifact_root 不存在: {0}' -f $artifactResolution.ArtifactRootPath)
}
if ($taskArtifactPaths.Count -gt 0) {
    $artifactNames = ($taskArtifactPaths | ForEach-Object { Split-Path $_ -Leaf }) -join ', '
    Add-Check ('当前任务文档已纳入乱码扫描: {0}' -f $artifactNames)
} elseif ([string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
    Add-Info '未提供 OrchestratorFlowPath，已跳过工作区当前任务文档扫描'
} elseif ([string]::IsNullOrWhiteSpace($artifactTaskId)) {
    Add-Info '未解析出当前流程 task_id，已跳过工作区当前任务文档扫描'
} else {
    Add-Info ('未发现可扫描的当前任务文档: task_id={0}' -f $artifactTaskId)
}

if (-not [string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
    if (-not (Test-Path -LiteralPath $OrchestratorFlowPath -PathType Leaf)) {
        Add-Warning ('指定的 legacy current-flow 不存在: {0}' -f $OrchestratorFlowPath)
    } else {
        Add-Info 'current-flow is a legacy migration input and is not a runtime truth source.'
    }
}

$runtimeMojibakeScanPaths = @(
    $indexPath,
    $currentPath,
    $interruptedPath,
    $lastSessionPath,
    $candidatePath
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

foreach ($scanPath in $runtimeMojibakeScanPaths) {
    $hits = Get-LikelyMojibakeHits -Path $scanPath
    if (@($hits).Count -gt 0) {
        $details = ($hits | ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber }) -join ', '
        Add-Warning ('运行时文件疑似乱码: {0}' -f $details)
    }
}

foreach ($artifactPath in $taskArtifactPaths) {
    $hits = Get-LikelyMojibakeHits -Path $artifactPath
    if (@($hits).Count -gt 0) {
        $details = ($hits | ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber }) -join ', '
        Add-Error ('当前任务文档疑似乱码: {0}' -f $details)
    }
}

# --- 并行写保护一致性检查 ---

# 检查 tasks 目录存在
$tasksDir = Join-Path $runtimeDir 'tasks'
if (Test-Path -LiteralPath $tasksDir -PathType Container) {
    Add-Check '运行时/tasks/ 目录存在'
} else {
    Add-Error '运行时/tasks/ 目录不存在（任务级状态未落盘到 Obsidian）'
}

# 检查 runtime.lock.json 是否存在且过期
$lockPath = Join-Path $runtimeDir 'runtime.lock.json'
if (Test-Path -LiteralPath $lockPath) {
    try {
        $lockContent = Get-Content -LiteralPath $lockPath -Encoding utf8 -Raw | ConvertFrom-Json
        $lockedAt = [datetime]::Parse($lockContent.locked_at, [System.Globalization.CultureInfo]::InvariantCulture)
        $lockAge = (Get-Date) - $lockedAt
        if ($lockAge.TotalMinutes -gt 30) {
            Add-Warning ('runtime.lock.json 已过期: locked_at={0}, writer={1}, age={2:N0} minutes' -f $lockContent.locked_at, $lockContent.writer, $lockAge.TotalMinutes)
        } else {
            Add-Check ('runtime.lock.json 活跃: writer={0}, task_id={1}' -f $lockContent.writer, $lockContent.task_id)
        }
    } catch {
        Add-Warning ('runtime.lock.json 格式异常: {0}' -f $_.Exception.Message)
    }
}

# 检查共享指针是否指向存在的 task_id
if ($null -ne $taskValue -and $taskValue -notlike '无*' -and (Test-Path -LiteralPath $tasksDir -PathType Container)) {
    if (-not [string]::IsNullOrWhiteSpace($taskIdFromCurrent)) {
        $taskStatePath = Join-Path $tasksDir "$taskIdFromCurrent.md"
        if (Test-Path -LiteralPath $taskStatePath) {
            Add-Check ('共享指针 task_id={0} 对应任务状态文件存在' -f $taskIdFromCurrent)
            if (-not [string]::IsNullOrWhiteSpace($OrchestratorFlowPath) -and (Test-Path -LiteralPath $OrchestratorFlowPath -PathType Leaf)) {
                Add-Info 'Skipped current-flow comparison; canonical runtime state is checked below.'
            }
        } else {
            Add-Error ('共享指针 task_id={0} 但无对应 运行时/tasks/{0}.md' -f $taskIdFromCurrent)
        }
    } else {
        Add-Error '共享指针存在活动任务，但未解析出 task_id'
    }
}

# 检查孤儿任务文件（tasks/ 下有文件但不被共享指针或中断任务引用）
if (Test-Path -LiteralPath $tasksDir -PathType Container) {
    $taskFiles = @(Get-ChildItem -Path $tasksDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
    if ($taskFiles.Count -gt 0) {
        Add-Check ('运行时/tasks/ 下有 {0} 个任务状态文件' -f $taskFiles.Count)
    }

    $currentTaskStatePath = $null
    if (-not [string]::IsNullOrWhiteSpace($taskIdFromCurrent)) {
        $currentTaskStatePath = Join-Path $tasksDir "$taskIdFromCurrent.md"
    }

    if (-not [string]::IsNullOrWhiteSpace($currentTaskStatePath) -and (Test-Path -LiteralPath $currentTaskStatePath -PathType Leaf)) {
        $hits = Get-LikelyMojibakeHits -Path $currentTaskStatePath
        if (@($hits).Count -gt 0) {
            $lines = ($hits | ForEach-Object { $_.LineNumber }) -join ', '
            Add-Warning ('当前任务状态文件疑似乱码: {0} (lines: {1})' -f $currentTaskStatePath, $lines)
        }
    }

    $historicalTaskReports = @()
    foreach ($taskFile in $taskFiles) {
        if (-not [string]::IsNullOrWhiteSpace($currentTaskStatePath) -and $taskFile.FullName -eq $currentTaskStatePath) {
            continue
        }

        $hits = Get-LikelyMojibakeHits -Path $taskFile.FullName
        if (@($hits).Count -gt 0) {
            $lines = ($hits | ForEach-Object { $_.LineNumber }) -join ', '
            $historicalTaskReports += ('{0} (lines: {1})' -f $taskFile.FullName, $lines)
        }
    }

    if ($historicalTaskReports.Count -gt 0) {
        Add-Info ('历史任务状态文件存在疑似乱码（不阻塞当前 gate）: {0}' -f ($historicalTaskReports -join '; '))
    }

}

# --- Canonical runtime contract (v1.1) ---

$canonicalCurrent = Get-CanonicalCurrentTaskState -Path $currentPath
if ($canonicalCurrent.SchemaVersion -ne 'current-task-pointer/v1.1') {
    Add-Error ('当前任务 schema_version 必须为 current-task-pointer/v1.1: {0}' -f $currentPath)
}
foreach ($field in @('TaskId', 'EntryHost', 'Writer', 'Updated', 'Stage', 'CurrentDoc')) {
    if ([string]::IsNullOrWhiteSpace([string]$canonicalCurrent.$field)) {
        Add-Error ('当前任务缺少 canonical 字段 {0}: {1}' -f $field, $currentPath)
    }
}
try {
    $null = [datetimeoffset]::Parse($canonicalCurrent.Updated)
} catch {
    Add-Error ('当前任务 updated 必须为带时区的秒级时间: {0}' -f $currentPath)
}

$canonicalRecords = Get-CanonicalTaskRuntimeRecords -TasksDirectory $tasksDir
foreach ($invalidRecord in @($canonicalRecords | Where-Object { -not $_.IsValid })) {
    Add-Error ('任务 runtime 不符合 task-runtime/v1.1: {0}' -f $invalidRecord.Path)
}

$canonicalIndexText = if (Test-Path -LiteralPath $indexPath -PathType Leaf) { Get-Content -LiteralPath $indexPath -Raw -Encoding utf8 } else { '' }
if ((Get-CanonicalRuntimeYamlField -Text $canonicalIndexText -Key 'schema_version') -ne 'recovery-index/v1.1') {
    Add-Error ('恢复索引 schema_version 必须为 recovery-index/v1.1: {0}' -f $indexPath)
}
if ((Get-CanonicalRuntimeYamlField -Text $canonicalIndexText -Key 'writer') -notin @('install', 'advance-stage', 'repair-shared-memory')) {
    Add-Error ('恢复索引 writer 必须是 canonical runtime writer: {0}' -f $indexPath)
}
$canonicalIndexUpdated = Get-CanonicalRuntimeYamlField -Text $canonicalIndexText -Key 'updated'
try {
    $null = [datetimeoffset]::Parse($canonicalIndexUpdated)
} catch {
    Add-Error ('恢复索引 updated 必须为带时区的秒级时间: {0}' -f $indexPath)
}
$requiredIndexSources = @('运行时/当前任务.md', '运行时/tasks/')
foreach ($source in $requiredIndexSources) {
    if ($source -notin $recoveryDerivedFrom) {
        Add-Error ('恢复索引 derived_from 缺少 canonical source: {0}' -f $source)
    }
}
if (@($recoveryDerivedFrom | Where-Object { $_ -notin $requiredIndexSources }).Count -gt 0) {
    Add-Error ('恢复索引 derived_from 包含非 canonical source: {0}' -f ($recoveryDerivedFrom -join ', '))
}

$currentIsIdle = $canonicalCurrent.TaskId -eq 'none'
if ($currentIsIdle) {
    if ($canonicalCurrent.Stage -ne '空闲' -or $canonicalCurrent.CurrentDoc -ne 'none') {
        Add-Error '空闲当前任务必须使用 状态=空闲 且 当前文档=none。'
    }
    $latestUnfinishedRecord = @($canonicalRecords |
        Where-Object { $_.IsValid -and $_.Stage -ne 'DONE' -and $_.TaskId -ne $canonicalCurrent.TaskId } |
        Sort-Object @{ Expression = 'UpdatedValue'; Descending = $true }, @{ Expression = 'TaskId'; Descending = $false } |
        Select-Object -First 1)
    if ($latestUnfinishedRecord.Count -gt 0) {
        Add-Warning ('共享指针显示为空，但存在未完成任务状态文件: task_id={0}; stage={1}; path={2}' -f
            $latestUnfinishedRecord[0].TaskId,
            $latestUnfinishedRecord[0].Stage,
            $latestUnfinishedRecord[0].Path)
    }
} else {
    if (-not (Test-CanonicalRuntimeTaskId -TaskId $canonicalCurrent.TaskId)) {
        Add-Error ('当前任务 task_id 非法: {0}' -f $canonicalCurrent.TaskId)
    }
    if (-not (Test-CanonicalRuntimeStage -Stage $canonicalCurrent.Stage)) {
        Add-Error ('当前任务状态非法: {0}' -f $canonicalCurrent.Stage)
    }

    $currentRecord = @($canonicalRecords | Where-Object { $_.TaskId -eq $canonicalCurrent.TaskId } | Select-Object -First 1)
    if ($currentRecord.Count -eq 0) {
        Add-Error ('当前任务缺少 task runtime mirror: {0}' -f $canonicalCurrent.TaskId)
    } elseif ($currentRecord[0].IsValid) {
        if ($currentRecord[0].Stage -ne $canonicalCurrent.Stage) {
            Add-Error ('plan/current/mirror stage 漂移: current={0}, mirror={1}' -f $canonicalCurrent.Stage, $currentRecord[0].Stage)
        }
        if ($currentRecord[0].PrimaryArtifact -ne $canonicalCurrent.CurrentDoc) {
            Add-Error ('current/mirror primary artifact 漂移: current={0}, mirror={1}' -f $canonicalCurrent.CurrentDoc, $currentRecord[0].PrimaryArtifact)
        }
    }

    $workspaceRoot = Split-Path -Parent $VaultRoot
    $planPath = Join-Path $workspaceRoot ('docs/tasks/{0}/plan.md' -f $canonicalCurrent.TaskId)
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        Add-Error ('当前任务 plan.md 不存在: {0}' -f $planPath)
    } else {
        $planStage = Get-YamlField -Path $planPath -Field 'stage'
        if ($planStage -ne $canonicalCurrent.Stage) {
            Add-Error ('plan/current stage 漂移: plan={0}, current={1}' -f $planStage, $canonicalCurrent.Stage)
        }
    }
}

$expectedIndexTaskIdLine = ('- task_id: `{0}`' -f $canonicalCurrent.TaskId)
if ($canonicalIndexText -notmatch [regex]::Escape($expectedIndexTaskIdLine)) {
    Add-Error ('恢复索引未指向当前任务: {0}' -f $canonicalCurrent.TaskId)
}
$topSection = [regex]::Match($canonicalIndexText, '(?s)^## 未完成任务 Top \d+\s*(.*)$')
if ($topSection.Success) {
    $topRows = @([regex]::Matches($topSection.Groups[1].Value, '(?m)^- task_id: `([^`]+)` \| stage: ([A-Z_]+)'))
    if ($topRows.Count -gt 3) {
        Add-Error ('恢复索引未完成任务超过 Top N: {0}' -f $topRows.Count)
    }
    foreach ($row in $topRows) {
        if ($row.Groups[2].Value -eq 'DONE' -or -not (Test-CanonicalRuntimeStage -Stage $row.Groups[2].Value)) {
            Add-Error ('恢复索引包含非法或已完成任务: {0}' -f $row.Value)
        }
    }
}

foreach ($lastSessionField in @('日期', '任务', '状态', '摘要')) {
    if ([string]::IsNullOrWhiteSpace((Get-TableValue -Path $lastSessionPath -Key $lastSessionField))) {
        Add-Error ('上次会话缺少会话摘要字段 {0}: {1}' -f $lastSessionField, $lastSessionPath)
    }
}

# An explicit Vault diagnostic never authorizes recursive scans of agent homes.
# Preserve the retired loop as source history, with no active scan targets.
$agentRoots = @()
$forbiddenNames = @('恢复索引.md', '当前任务.md', '中断任务.md', '上次会话.md', '收件箱.md', '记忆候选.md')

foreach ($root in $agentRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }

    foreach ($name in $forbiddenNames) {
        $matches = Get-ChildItem -Path $root -Filter $name -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike ($VaultRoot + '*') }
        foreach ($match in $matches) {
            Add-Warning ('发现平行 runtime note: {0}' -f $match.FullName)
        }
    }
}

$status = 'PASS'
if ($errors.Count -gt 0) {
    $status = 'FAIL'
} elseif ($warnings.Count -gt 0) {
    $status = 'WARN'
}

Write-Output ('STATUS: {0}' -f $status)
Write-Output 'Scope: historical-v1-only'
Write-Output ('VaultRoot: {0}' -f $VaultRoot)
Write-Output ''
Write-Output 'Info:'
if ($infos.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $infos) {
        Write-Output ('- {0}' -f $item)
    }
}
Write-Output ''
Write-Output 'Checks:'
if ($checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $checks) {
        Write-Output ('- {0}' -f $item)
    }
}
Write-Output ''
Write-Output 'Warnings:'
if ($warnings.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $warnings) {
        Write-Output ('- {0}' -f $item)
    }
}
Write-Output ''
Write-Output 'Errors:'
if ($errors.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $errors) {
        Write-Output ('- {0}' -f $item)
    }
}

if ($errors.Count -gt 0) {
    exit 2
}
if ($warnings.Count -gt 0) {
    exit 1
}
exit 0
