param(
    [string]$VaultRoot = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'resolve-shared-memory-paths.ps1')
$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath

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
    $match = Select-String -Path $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
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

    if ((Split-Path -Leaf $flowDir) -ieq 'orchestration' -and (Split-Path -Leaf $assistantDir) -ieq '.assistant') {
        return (Split-Path -Parent $assistantDir)
    }

    return (Split-Path -Parent $assistantDir)
}

function Get-LikelyMojibakeHits {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $pattern = '鍥|锛|銆|鈥|鏈€|褰撳墠|浠诲姟|鐢ㄦ埛|宸插|缁撴灉|璇锋眰|闃舵|鍐欏洖|杩涘害|琛ュ厖|杩涘睍|�|[\uE000-\uF8FF]'
    return @(Select-String -Path $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 5)
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
        $artifactRootPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $workspaceRoot 'docs') $TaskId))
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

$sourceTimes = @($currentUpdated, $interruptedUpdated, $lastUpdated) | Where-Object { $null -ne $_ }
if ($null -ne $indexUpdated -and $sourceTimes.Count -gt 0) {
    $latestSource = $sourceTimes | Sort-Object -Descending | Select-Object -First 1
    if ($indexUpdated -lt $latestSource) {
        Add-Warning ('恢复索引比运行时真相源旧: 恢复索引={0}, 最新源={1}' -f $indexUpdated, $latestSource)
    } else {
        Add-Check '恢复索引更新时间不早于当前任务/中断任务/上次会话'
    }
}

$taskValue = Get-TableValue -Path $currentPath -Key '任务'
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
    $candidateContent = Get-Content -Path $candidatePath -Encoding utf8 -Raw
    if ($candidateContent -match '\|\s*ID\s*\|\s*日期\s*\|\s*类型\s*\|') {
        Add-Check '记忆候选.md 含标准表头'
    } else {
        Add-Warning '记忆候选.md 缺少标准表头'
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
        Add-Error ('指定的 orchestrator current-flow 不存在: {0}' -f $OrchestratorFlowPath)
    } else {
        if ([string]::IsNullOrWhiteSpace($taskIdFromFlow)) {
            Add-Error ('指定的 orchestrator current-flow 未解析出 task_id: {0}' -f $OrchestratorFlowPath)
        } elseif ([string]::IsNullOrWhiteSpace($taskIdFromCurrent)) {
            Add-Error ('共享指针未解析出 task_id，但 orchestrator current-flow 指向 task_id={0}' -f $taskIdFromFlow)
        } elseif ($taskIdFromFlow -ne $taskIdFromCurrent) {
            Add-Error ('orchestrator current-flow task_id={0} 与共享指针 task_id={1} 不一致' -f $taskIdFromFlow, $taskIdFromCurrent)
        } else {
            Add-Check ('orchestrator current-flow 与共享指针 task_id 一致: {0}' -f $taskIdFromFlow)
        }
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
        $lockContent = Get-Content -Path $lockPath -Encoding utf8 -Raw | ConvertFrom-Json
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

    if (($null -eq $taskValue -or $taskValue -like '无*') -and $taskFiles.Count -gt 0) {
        $latestTaskFile = $taskFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Add-Warning ('共享指针显示为空，但存在任务状态文件: latest={0}' -f $latestTaskFile.FullName)
    }
}

$agentRoots = Get-DefaultAgentRoots
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
