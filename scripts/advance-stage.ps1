# 推进 harness lite 阶段，并按 `plan.md` frontmatter 重写共享运行时 mirror。
# 这个脚本只认 lite 契约：`docs/tasks/{task_id}/plan.md` 是唯一阶段真相源。
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('PLAN', 'PLAN_REVIEW', 'IMPLEMENT', 'CODE_REVIEW', 'TEST', 'DONE')]
    [string]$ExpectedStage,

    [string]$Tool = "",

    [string]$Profile = "",

    [string]$Model = "",

    [string]$VaultRoot = $Env:OBSIDIAN_VAULT,

    [string]$RepoRoot = "",

    [string]$WorkspaceRoot = "",

    [switch]$SyncOnly,

    [switch]$ActivateCurrent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'lite-artifact-parser.ps1')

Assert-LiteTaskId -TaskId $TaskId

$ValidStages = @("PLAN", "PLAN_REVIEW", "IMPLEMENT", "CODE_REVIEW", "TEST", "DONE")
$ValidTools = @("claudecode", "codex")
$ModelAliasPattern = '^(opus|sonnet|haiku|default|latest|codex|claude|gpt)$'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
} else {
    $repoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
}
$runtimeStatePath = Join-Path $repoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1'
if (-not (Test-Path -LiteralPath $runtimeStatePath -PathType Leaf)) {
    throw "Missing canonical runtime state helper: $runtimeStatePath"
}
if (-not (Get-Command -Name Test-CanonicalRuntimeTaskId -CommandType Function -ErrorAction SilentlyContinue)) {
    . $runtimeStatePath
}
$runtimeInboxPath = Join-Path $repoRoot 'skills\obsidian-memory\scripts\runtime-inbox-common.ps1'
if (-not (Test-Path -LiteralPath $runtimeInboxPath -PathType Leaf)) {
    throw "Missing canonical runtime inbox helper: $runtimeInboxPath"
}
. $runtimeInboxPath
$sharedMemoryResolverPath = Join-Path $repoRoot 'skills\obsidian-memory\scripts\resolve-shared-memory-paths.ps1'
if (-not (Test-Path -LiteralPath $sharedMemoryResolverPath -PathType Leaf)) {
    throw "Missing canonical shared-memory resolver: $sharedMemoryResolverPath"
}
. $sharedMemoryResolverPath
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $workspaceRoot = $repoRoot
} else {
    $workspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
}
$requestedProtocol = [System.Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL', [System.EnvironmentVariableTarget]::Process)
if (-not [string]::IsNullOrWhiteSpace($requestedProtocol) -and $requestedProtocol -cnotin @('auto', 'v1', 'v2')) {
    throw 'HARNESS_PROTOCOL must be auto, v1, or v2'
}
$v2TaskStatePath = Join-Path $workspaceRoot (".assistant\runtime\tasks\{0}\task.json" -f $TaskId)
if (Test-Path -LiteralPath $v2TaskStatePath -PathType Leaf) {
    throw "Task $TaskId is a v2 task; advance-stage.ps1 is v1-only."
}
if ($requestedProtocol -ceq 'v2') {
    throw 'advance-stage.ps1 is v1-only and cannot run with HARNESS_PROTOCOL=v2'
}
if (-not $VaultRoot) {
    throw "Set OBSIDIAN_VAULT or pass -VaultRoot."
}
$VaultRoot = Resolve-SharedMemoryVaultRoot -WorkspaceRoot $workspaceRoot -VaultRoot $VaultRoot
$taskBase = Resolve-LiteContainedPath -Root $workspaceRoot -RelativePath 'docs\tasks' -Label 'task base'
$taskRoot = Resolve-LiteContainedPath -Root $taskBase -RelativePath $TaskId -Label 'task root'
$planPath = Resolve-LiteContainedPath -Root $taskRoot -RelativePath 'plan.md' -Label 'plan path'
$testPath = Resolve-LiteContainedPath -Root $taskRoot -RelativePath 'test.md' -Label 'test path'
$tasksDir = Resolve-LiteContainedPath -Root $VaultRoot -RelativePath '运行时\tasks' -Label 'runtime tasks root'
$taskMirrorPath = Resolve-LiteContainedPath -Root $tasksDir -RelativePath ("{0}.md" -f $TaskId) -Label 'task mirror path'
$indexPath = Resolve-LiteContainedPath -Root $VaultRoot -RelativePath '运行时\恢复索引.md' -Label 'recovery index path'
$currentPath = Resolve-LiteContainedPath -Root $VaultRoot -RelativePath '运行时\当前任务.md' -Label 'current task path'
$validatorPath = Join-Path $PSScriptRoot "validate-lite-artifacts.ps1"

function Invoke-LiteArtifactValidator {
    <#
    .SYNOPSIS
    在推进前运行 lite artifact validator。
    .DESCRIPTION
    通过当前 PowerShell 宿主启动子进程执行 validator，避免子脚本里的 `exit` 直接终止推进脚本。
    .PARAMETER ValidatorPath
    validator 脚本路径。
    .PARAMETER TaskId
    任务 ID。
    .PARAMETER RepoRoot
    harness 工具仓库根目录。
    .PARAMETER WorkspaceRoot
    当前项目根目录，任务 artifact 从这里读取。
    .OUTPUTS
    None。
    #>
    param(
        [string]$ValidatorPath,
        [string]$TaskId,
        [string]$RepoRoot,
        [string]$WorkspaceRoot
    )

    $shellPath = (Get-Process -Id $PID).Path
    $output = @(& $shellPath -NoProfile -File $ValidatorPath -TaskId $TaskId -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        $warningIndex = [Array]::IndexOf($output, 'Warnings:')
        if ($warningIndex -ge 0) {
            for ($index = $warningIndex + 1; $index -lt $output.Count; $index += 1) {
                $line = $output[$index].Trim()
                if ($line.StartsWith('- ') -and $line -ne '- none') {
                    [Console]::Error.WriteLine(('validator warning: {0}' -f $line.Substring(2)))
                }
            }
        }
        return
    }

    $details = @()
    $errorIndex = [Array]::IndexOf($output, 'Errors:')
    if ($errorIndex -ge 0) {
        for ($index = $errorIndex + 1; $index -lt $output.Count; $index += 1) {
            $line = $output[$index].Trim()
            if ($line -eq 'Warnings:') {
                break
            }

            if ([string]::IsNullOrWhiteSpace($line) -or $line -eq '- none') {
                continue
            }

            if ($line.StartsWith('- ')) {
                $details += $line.Substring(2)
            }
        }
    }

    if ($details.Count -eq 0) {
        throw ('validate-lite-artifacts.ps1 failed for {0}.' -f $TaskId)
    }

    throw ('validate-lite-artifacts.ps1 failed for {0}: {1}' -f $TaskId, ($details -join '; '))
}

function Get-LatestRun {
    <#
    .SYNOPSIS
    返回目标 section 的最新 Run 块。
    .DESCRIPTION
    lite workflow 的审查和实现记录都是 append-only，只读取最后一个 `### Run`。
    .PARAMETER Text
    Markdown 全文。
    .PARAMETER Name
    section 名。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Text,
        [string]$Name
    )

    $run = Get-LiteLatestRun -Sections @(Get-LiteSections -Content $Text) -Name $Name
    if ($null -eq $run) {
        return ''
    }
    return $run.Raw
}

function Get-RunVerdict {
    <#
    .SYNOPSIS
    提取最新 Run verdict。
    .DESCRIPTION
    PLAN_REVIEW 和 CODE_REVIEW 都只接受 `pass` 或 `revise`。
    .PARAMETER Text
    Markdown 全文。
    .PARAMETER Name
    section 名。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Text,
        [string]$Name
    )

    $run = Get-LiteLatestRun -Sections @(Get-LiteSections -Content $Text) -Name $Name
    if ($null -ne $run) {
        $reviewContract = Get-LiteReviewRunContract -Run $run
        Assert-LiteLatestReviewConsistency -Review $reviewContract
        return $reviewContract.Verdict
    }

    return ""
}

function Open-TestSnapshot {
    <#
    .SYNOPSIS
    打开 test.md 的只读共享句柄，并读取精确字节身份与 UTF-8 文本。
    .DESCRIPTION
    FileShare.Read 允许 validator 读取，但在 plan commit 前拒绝 write/delete；
    Base64 identity 继续用于 validator 前后及 commit 前的 byte-exact CAS。
    #>
    param([string]$Path)

    $handle = $null
    try {
        $handle = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $offset = if (
            $bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and
            $bytes[1] -eq 0xBB -and
            $bytes[2] -eq 0xBF
        ) { 3 } else { 0 }
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)

        [pscustomobject]@{
            Handle = $handle
            Identity = [Convert]::ToBase64String($bytes)
            Text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        }
    } catch {
        if ($null -ne $handle) { $handle.Dispose() }
        throw
    }
}

function Test-TestSnapshotMatches {
    param(
        [string]$Path,
        [string]$Identity
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) -ceq $Identity
}

function Get-TestConclusion {
    param([string]$Text)

    $content = Get-LiteSectionContent `
        -Sections @(Get-LiteSections -Content $Text) `
        -Name 'Conclusion'
    $lines = @($content -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0 -or $lines[0] -notin @('pass', 'fail', 'blocked')) {
        throw 'test.md requires Conclusion: pass | fail | blocked.'
    }
    return $lines[0]
}

function Ensure-ParentDirectory {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Add-RuntimeWritebackFallback {
    param(
        [string]$VaultRoot,
        [string]$TaskId,
        [string]$Step,
        [string]$Payload
    )

    $mutex = Enter-CanonicalRuntimeMutex -VaultRoot $VaultRoot
    try {
        $inbox = Read-RuntimeInbox -VaultRoot $VaultRoot -NormalizeExisting
        $rows = @($inbox.Rows | Where-Object {
            -not (Test-RuntimeInboxPlaceholderRow -Row $_)
        })
        $summary = Escape-InboxCell -Value ('[writeback-fallback] {0}' -f $Step)
        $Payload = Escape-InboxCell -Value $Payload
        $duplicate = @($rows | Where-Object {
            $_.Source -ceq 'advance-stage' -and
            $_.TaskId -ceq $TaskId -and
            $_.Type -ceq 'writeback-fallback' -and
            $_.Status -ceq 'open' -and
            $_.Summary -ceq $summary -and
            $_.Payload -ceq $Payload
        }).Count -gt 0
        if (-not $duplicate) {
            $rows += [pscustomobject]@{
                CreatedAt = Get-CurrentTimestamp
                Source = 'advance-stage'
                TaskId = $TaskId
                Type = 'writeback-fallback'
                Status = 'open'
                Summary = $summary
                Payload = $Payload
            }
            Write-RuntimeInbox -InboxPath $inbox.Path -CreatedDate $inbox.CreatedDate -Rows $rows
        }
    } finally {
        Exit-CanonicalRuntimeMutex -Mutex $mutex
    }
}

function Report-WritebackFallback {
    param(
        [string]$VaultRoot,
        [string]$TaskId,
        [string]$Step,
        [string]$Reason,
        [string]$Payload
    )

    $message = '[writeback-fallback] {0}: {1}' -f $Step, $Reason
    [Console]::Error.WriteLine($message)

    try {
        Add-RuntimeWritebackFallback -VaultRoot $VaultRoot -TaskId $TaskId -Step $Step -Payload $Payload
        return ''
    } catch {
        [Console]::Error.WriteLine('[writeback-fallback] inbox-note: {0}' -f $_.Exception.Message)
        return $_.Exception.Message
    }
}

function Clear-RuntimeWritebackFallback {
    param(
        [string]$VaultRoot,
        [string]$TaskId,
        [switch]$ActivateCurrent
    )

    $mutex = Enter-CanonicalRuntimeMutex -VaultRoot $VaultRoot
    try {
        $paths = Get-RuntimeMarkdownPaths -VaultRoot $VaultRoot
        if (-not (Test-Path -LiteralPath $paths.InboxPath -PathType Leaf)) {
            return 0
        }
        $inbox = Read-RuntimeInbox -VaultRoot $VaultRoot
        $coveredOperations = if ($ActivateCurrent.IsPresent) { @('activate', 'advance', 'sync') } else { @('advance', 'sync') }
        $matches = @()
        foreach ($row in $inbox.Rows) {
            if ($row.Status -ne 'open' -or $row.TaskId -cne $TaskId -or $row.Type -cne 'writeback-fallback' -or $row.Source -cne 'advance-stage') {
                continue
            }
            try {
                $payload = $row.Payload | ConvertFrom-Json
            } catch {
                continue
            }
            if ($payload.schema_version -ceq 'writeback-fallback/v1' -and
                $coveredOperations -ccontains [string]$payload.operation -and
                $ValidStages -ccontains [string]$payload.expected_stage -and
                -not [string]::IsNullOrWhiteSpace($payload.failed_step) -and
                -not [string]::IsNullOrWhiteSpace($payload.reason) -and
                $row.Summary -ceq ('[writeback-fallback] {0}' -f $payload.failed_step)) {
                $matches += $row
            }
        }
        if ($matches.Count -eq 0) {
            return 0
        }

        $remaining = @($inbox.Rows | Where-Object {
            $row = $_
            @($matches | Where-Object {
                $_.CreatedAt -ceq $row.CreatedAt -and
                $_.Source -ceq $row.Source -and
                $_.TaskId -ceq $row.TaskId -and
                $_.Type -ceq $row.Type -and
                $_.Status -ceq $row.Status -and
                $_.Summary -ceq $row.Summary -and
                $_.Payload -ceq $row.Payload
            }).Count -eq 0
        })
        Write-RuntimeInbox -InboxPath $inbox.Path -CreatedDate $inbox.CreatedDate -Rows $remaining
        return $matches.Count
    } finally {
        Exit-CanonicalRuntimeMutex -Mutex $mutex
    }
}

function Get-SyncReplayCommand {
    param(
        [string]$TaskId,
        [string]$ExpectedStage,
        [string]$RepoRoot,
        [string]$WorkspaceRoot,
        [string]$VaultRoot,
        [switch]$ActivateCurrent
    )

    $command = 'pwsh -NoProfile -File "{0}" -TaskId "{1}" -ExpectedStage {2} -SyncOnly -RepoRoot "{3}" -WorkspaceRoot "{4}" -VaultRoot "{5}"' -f `
        (Join-Path $PSScriptRoot 'advance-stage.ps1'), $TaskId, $ExpectedStage, $RepoRoot, $WorkspaceRoot, $VaultRoot
    if ($ActivateCurrent.IsPresent) {
        $command += ' -ActivateCurrent'
    }
    return $command
}

function New-CanonicalIdleCurrentContent {
    param([string]$Updated)

    return New-CanonicalCurrentTaskContent `
        -TaskId 'none' `
        -TaskName '无' `
        -Stage '空闲' `
        -CurrentDoc 'none' `
        -Tool 'none' `
        -EntryHost 'unknown' `
        -NextStep '等待新任务' `
        -Updated $Updated
}

function Test-FullModelId {
    <#
    .SYNOPSIS
    判断 model 是否看起来像完整模型 ID。
    .DESCRIPTION
    `inherit` 由宿主解析；显式值仍必须是完整模型 ID，阻止 `opus`、`pro` 这类短别名进入机器可读契约。
    .PARAMETER Model
    待检查的模型 ID。
    .OUTPUTS
    Boolean。
    #>
    param([string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) {
        return $false
    }

    $normalized = $Model.Trim()
    if ($normalized -ceq 'inherit') {
        return $true
    }

    if ($normalized -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*[A-Za-z0-9]$') {
        return $false
    }

    if ($normalized -notmatch '[-./]') {
        return $false
    }

    return ($normalized -notmatch $ModelAliasPattern)
}

function Get-ToolProfile {
    <#
    .SYNOPSIS
    读取 agent-configs/profiles 下的 profile 描述符。
    .DESCRIPTION
    只解析 Phase 1 需要的顶层 scalar 字段：name/backend/model。
    .PARAMETER RepoRoot
    harness 工具仓库根目录。
    .PARAMETER Name
    profile 名称。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$RepoRoot,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Tool profile name is empty."
    }

    $normalizedName = $Name.Trim()
    if ($normalizedName -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw ("Unsupported tool profile name: {0}" -f $normalizedName)
    }

    $profilePath = Join-Path (Join-Path $RepoRoot 'agent-configs\profiles') ("{0}.yaml" -f $normalizedName)
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw ("Missing tool profile descriptor: {0}" -f $profilePath)
    }

    $fields = @{}
    foreach ($line in (Get-Content -LiteralPath $profilePath -Encoding utf8)) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^([a-z_]+):\s*(.+?)\s*$') {
            $fields[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }

    foreach ($required in @('name', 'backend', 'model')) {
        if (-not $fields.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($fields[$required])) {
            throw ("Tool profile {0} is missing required field: {1}" -f $normalizedName, $required)
        }
    }

    if ($fields['name'] -ne $normalizedName) {
        throw ("Tool profile file name {0} does not match descriptor name {1}" -f $normalizedName, $fields['name'])
    }

    if ($fields['backend'] -cnotin $ValidTools) {
        throw ("Tool profile {0} has unsupported backend: {1}" -f $normalizedName, $fields['backend'])
    }

    if (-not (Test-FullModelId -Model $fields['model'])) {
        throw ("Tool profile {0} model should be inherit or a full model id, got: {1}" -f $normalizedName, $fields['model'])
    }

    return [pscustomobject]@{
        Name = $fields['name']
        Backend = $fields['backend']
        Model = $fields['model']
        Path = $profilePath
    }
}

function Split-InlineYamlList {
    <#
    .SYNOPSIS
    解析 YAML inline list。
    .DESCRIPTION
    workflow descriptor 只使用 `[a, b]` 这种最小列表语法，这里做轻量解析以避免引入额外 YAML 依赖。
    .PARAMETER Value
    inline list 原始文本。
    .OUTPUTS
    String[]。
    #>
    param([string]$Value)

    $normalized = $Value.Trim()
    if ($normalized -notmatch '^\[(.*)\]$') {
        throw ("Unsupported inline YAML list: {0}" -f $Value)
    }

    $inner = $Matches[1].Trim()
    if ([string]::IsNullOrWhiteSpace($inner)) {
        return @()
    }

    $items = @()
    foreach ($item in ($inner -split ',')) {
        $trimmed = $item.Trim().Trim('"').Trim("'")
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $items += $trimmed
        }
    }

    return $items
}

function Get-WorkflowDescriptor {
    <#
    .SYNOPSIS
    读取 workflow descriptor。
    .DESCRIPTION
    Phase 2 只支持 `agent-configs/workflows/harness-lite.yaml` 这份最小 schema，避免引入外部 YAML 依赖。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    PSCustomObject。
    #>
    param([string]$RepoRoot)

    $descriptorPath = Join-Path (Join-Path $RepoRoot 'agent-configs\workflows') 'harness-lite.yaml'
    if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        throw ("Missing workflow descriptor: {0}" -f $descriptorPath)
    }

    $descriptor = [ordered]@{
        Name = ''
        Version = ''
        Stages = [ordered]@{}
        Path = $descriptorPath
    }

    $sawStages = $false
    $currentStage = ''
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $descriptorPath -Encoding utf8)) {
        $lineNumber += 1
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($line -match '^name:\s*(.+?)\s*$') {
            $descriptor.Name = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^version:\s*(.+?)\s*$') {
            $descriptor.Version = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^stages:\s*$') {
            $sawStages = $true
            $currentStage = ''
            continue
        }

        if ($line -match '^\s{2}([A-Z_]+):\s*$') {
            $currentStage = $Matches[1]
            if ($descriptor.Stages.Contains($currentStage)) {
                throw ("Workflow descriptor duplicates stage {0} at line {1}" -f $currentStage, $lineNumber)
            }

            $descriptor.Stages[$currentStage] = [ordered]@{
                Role = ''
                DefaultProfile = ''
                SkillsWhitelist = @()
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentStage)) {
            throw ("Unsupported workflow descriptor line {0}: {1}" -f $lineNumber, $line)
        }

        if ($line -match '^\s{4}role:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['Role'] = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^\s{4}default_profile:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['DefaultProfile'] = $Matches[1].Trim().Trim('"').Trim("'")
            continue
        }

        if ($line -match '^\s{4}skills_whitelist:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['SkillsWhitelist'] = @(Split-InlineYamlList -Value $Matches[1])
            continue
        }

        throw ("Unsupported workflow descriptor line {0}: {1}" -f $lineNumber, $line)
    }

    if ([string]::IsNullOrWhiteSpace($descriptor.Name)) {
        throw "Workflow descriptor is missing name."
    }

    if ([string]::IsNullOrWhiteSpace($descriptor.Version)) {
        throw "Workflow descriptor is missing version."
    }

    if (-not $sawStages) {
        throw "Workflow descriptor is missing stages."
    }

    return [pscustomobject]@{
        Name = $descriptor.Name
        Version = $descriptor.Version
        Stages = $descriptor.Stages
        Path = $descriptor.Path
    }
}

function Get-WorkflowDefaultProfile {
    <#
    .SYNOPSIS
    读取目标阶段的 workflow default profile。
    .DESCRIPTION
    workflow-default 只在 CLI 没给 tool/profile 时作为最后兜底来源。
    .PARAMETER RepoRoot
    仓库根目录。
    .PARAMETER Stage
    目标阶段。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$RepoRoot,
        [string]$Stage
    )

    $descriptor = Get-WorkflowDescriptor -RepoRoot $RepoRoot
    if (-not $descriptor.Stages.Contains($Stage)) {
        throw ("Workflow descriptor {0} does not define stage {1}" -f $descriptor.Path, $Stage)
    }

    $stageDescriptor = $descriptor.Stages[$Stage]
    if ([string]::IsNullOrWhiteSpace($stageDescriptor.DefaultProfile)) {
        throw ("Workflow descriptor stage {0} is missing default_profile" -f $Stage)
    }

    $profile = Get-ToolProfile -RepoRoot $RepoRoot -Name $stageDescriptor.DefaultProfile
    return [pscustomobject]@{
        Profile = $profile.Name
        Backend = $profile.Backend
        Model = $profile.Model
        Path = $descriptor.Path
    }
}

function Get-SkillDescription {
    <#
    .SYNOPSIS
    读取 repo skills 下的描述字段。
    .DESCRIPTION
    Phase 3 manifest 只需要稳定读取 SKILL.md frontmatter 的 description。
    .PARAMETER RepoRoot
    仓库根目录。
    .PARAMETER SkillName
    skill 标识。
    .OUTPUTS
    String。
    #>
    param(
        [string]$RepoRoot,
        [string]$SkillName
    )

    $skillDocPath = Join-Path (Join-Path (Join-Path $RepoRoot 'skills') $SkillName) 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillDocPath -PathType Leaf)) {
        return ''
    }

    $insideFrontmatter = $false
    $frontmatterCount = 0
    foreach ($line in (Get-Content -LiteralPath $skillDocPath -Encoding utf8)) {
        if ($line -eq '---') {
            $frontmatterCount++
            if ($frontmatterCount -eq 1) {
                $insideFrontmatter = $true
                continue
            }

            break
        }

        if ($insideFrontmatter -and $line -match '^description:\s*(.+?)\s*$') {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return ''
}

function Get-StageSkillCommands {
    <#
    .SYNOPSIS
    为指定 stage 构造 skill manifest command 列表。
    .DESCRIPTION
    读取 workflow descriptor 的 skills_whitelist，并补充 repo skill frontmatter description。
    .PARAMETER RepoRoot
    仓库根目录。
    .PARAMETER Stage
    目标阶段。
    .OUTPUTS
    Object[]。
    #>
    param(
        [string]$RepoRoot,
        [string]$Stage
    )

    if ($Stage -eq 'DONE') {
        return @()
    }

    try {
        $descriptor = Get-WorkflowDescriptor -RepoRoot $RepoRoot
    } catch {
        return @()
    }

    if (-not $descriptor.Stages.Contains($Stage)) {
        return @()
    }

    $commands = @()
    foreach ($skillName in @($descriptor.Stages[$Stage]['SkillsWhitelist'])) {
        $commands += [pscustomobject]@{
            name = $skillName
            description = (Get-SkillDescription -RepoRoot $RepoRoot -SkillName $skillName)
        }
    }

    return $commands
}

function Write-SkillManifest {
    <#
    .SYNOPSIS
    写入 per-task skill-manifest.json。
    .DESCRIPTION
    Phase 3 manifest 只在成功推进后 best-effort 生成，失败由调用方降级为 stderr 诊断。
    .PARAMETER RepoRoot
    harness 工具仓库根目录。
    .PARAMETER WorkspaceRoot
    当前项目根目录，skill-manifest 写入这里的 docs/tasks。
    .PARAMETER TaskId
    任务 ID。
    .PARAMETER Stage
    目标阶段。
    .PARAMETER Tool
    目标工具。
    .OUTPUTS
    None。
    #>
    param(
        [string]$RepoRoot,
        [string]$WorkspaceRoot,
        [string]$TaskId,
        [string]$Stage,
        [string]$Tool
    )

    $manifestPath = Join-Path $WorkspaceRoot ("docs/tasks/{0}/skill-manifest.json" -f $TaskId)
    $manifest = [ordered]@{
        version = 1
        task_id = $TaskId
        stage = $Stage
        tool = $Tool
        available_commands = @(Get-StageSkillCommands -RepoRoot $RepoRoot -Stage $Stage)
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
    }

    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8 -Compress), (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-FallbackTool {
    <#
    .SYNOPSIS
    按 Phase 2 fallback 链解析下一阶段 tool。
    .DESCRIPTION
    顺序固定为 `cli-tool -> cli-profile -> workflow-default -> none`，并显式排除当前 stage 的 frontmatter `tool_profile`。
    .PARAMETER NextStage
    目标阶段。
    .PARAMETER CliTool
    CLI `-Tool`。
    .PARAMETER CliProfile
    CLI `-Profile`。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$NextStage,
        [string]$CliTool,
        [string]$CliProfile,
        [string]$RepoRoot
    )

    if ($NextStage -eq 'DONE') {
        return [pscustomobject]@{
            Tool = ''
            Source = 'none'
            WorkflowProfile = ''
            WorkflowModel = ''
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CliTool)) {
        $resolvedTool = $CliTool.Trim().ToLowerInvariant()
        [Console]::Error.WriteLine("resolved tool=$resolvedTool via cli-tool")
        return [pscustomobject]@{
            Tool = $resolvedTool
            Source = 'cli-tool'
            WorkflowProfile = ''
            WorkflowModel = ''
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($CliProfile)) {
        $profile = Get-ToolProfile -RepoRoot $RepoRoot -Name $CliProfile.Trim()
        [Console]::Error.WriteLine("resolved tool=$($profile.Backend) via cli-profile")
        return [pscustomobject]@{
            Tool = $profile.Backend
            Source = 'cli-profile'
            WorkflowProfile = ''
            WorkflowModel = ''
        }
    }

    try {
        $workflowDefault = Get-WorkflowDefaultProfile -RepoRoot $RepoRoot -Stage $NextStage
        [Console]::Error.WriteLine("resolved tool=$($workflowDefault.Backend) via workflow-default")
        return [pscustomobject]@{
            Tool = $workflowDefault.Backend
            Source = 'workflow-default'
            WorkflowProfile = $workflowDefault.Profile
            WorkflowModel = $workflowDefault.Model
        }
    } catch {
    }

    return [pscustomobject]@{
        Tool = ''
        Source = 'none'
        WorkflowProfile = ''
        WorkflowModel = ''
    }
}

function Resolve-LegacyProfileSelection {
    <#
    .SYNOPSIS
    保留 Phase 1 的 profile/model 选择逻辑。
    .DESCRIPTION
    供 `cli-profile` 与 `cli-tool + explicit profile/model` 路径复用，避免改变既有兼容语义。
    .PARAMETER Tool
    目标阶段 tool。
    .PARAMETER ExistingProfile
    当前 frontmatter 中的 profile。
    .PARAMETER ExistingModel
    当前 frontmatter 中的 model。
    .PARAMETER RequestedProfile
    CLI 指定的新 profile。
    .PARAMETER RequestedModel
    CLI 指定的新 model。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$Tool,
        [string]$ExistingProfile,
        [string]$ExistingModel,
        [string]$RequestedProfile,
        [string]$RequestedModel,
        [string]$RepoRoot
    )

    $hasRequestedProfile = -not [string]::IsNullOrWhiteSpace($RequestedProfile)
    $hasRequestedModel = -not [string]::IsNullOrWhiteSpace($RequestedModel)
    $selectedProfile = if ($hasRequestedProfile) { $RequestedProfile.Trim() } else { $ExistingProfile.Trim() }
    $selectedModel = if ($hasRequestedModel) {
        $RequestedModel.Trim()
    } elseif ($hasRequestedProfile) {
        ''
    } else {
        $ExistingModel.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($selectedProfile)) {
        $descriptor = Get-ToolProfile -RepoRoot $RepoRoot -Name $selectedProfile
        if ($descriptor.Backend -ne $Tool) {
            throw ("Tool profile {0} backend {1} does not match tool {2}." -f $descriptor.Name, $descriptor.Backend, $Tool)
        }

        if ([string]::IsNullOrWhiteSpace($selectedModel)) {
            $selectedModel = $descriptor.Model
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($selectedModel) -and -not (Test-FullModelId -Model $selectedModel)) {
        throw ("Model should be inherit or a full model id, got: {0}" -f $selectedModel)
    }

    return [pscustomobject]@{
        Profile = $selectedProfile
        Model = $selectedModel
    }
}

function Resolve-ProfileSelection {
    <#
    .SYNOPSIS
    解析下一阶段 profile/model 写回值。
    .DESCRIPTION
    保持 `tool` 为显式 backend 字段；profile 存在时必须与下一阶段 tool.backend 一致。
    .PARAMETER Stage
    目标阶段。
    .PARAMETER Tool
    目标阶段 tool。
    .PARAMETER ExistingProfile
    当前 frontmatter 中的 profile。
    .PARAMETER ExistingModel
    当前 frontmatter 中的 model。
    .PARAMETER RequestedProfile
    CLI 指定的新 profile。
    .PARAMETER RequestedModel
    CLI 指定的新 model。
    .PARAMETER Source
    tool 的解析来源。
    .PARAMETER WorkflowProfile
    workflow-default 解析出的 profile。
    .PARAMETER WorkflowModel
    workflow-default 解析出的 model。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$Stage,
        [string]$Tool,
        [string]$ExistingProfile,
        [string]$ExistingModel,
        [string]$RequestedProfile,
        [string]$RequestedModel,
        [string]$Source,
        [string]$WorkflowProfile,
        [string]$WorkflowModel,
        [string]$RepoRoot
    )

    if ($Stage -eq 'DONE') {
        return [pscustomobject]@{
            Profile = ''
            Model = ''
        }
    }

    if ($Source -eq 'workflow-default') {
        if ([string]::IsNullOrWhiteSpace($WorkflowProfile) -or [string]::IsNullOrWhiteSpace($WorkflowModel)) {
            throw "workflow-default resolution requires profile and model."
        }

        return [pscustomobject]@{
            Profile = $WorkflowProfile
            Model = $WorkflowModel
        }
    }

    $hasRequestedProfile = -not [string]::IsNullOrWhiteSpace($RequestedProfile)
    $hasRequestedModel = -not [string]::IsNullOrWhiteSpace($RequestedModel)
    if ($Source -eq 'cli-tool' -and -not $hasRequestedProfile -and -not $hasRequestedModel) {
        return [pscustomobject]@{
            Profile = ''
            Model = ''
        }
    }

    return Resolve-LegacyProfileSelection -Tool $Tool -ExistingProfile $ExistingProfile -ExistingModel $ExistingModel -RequestedProfile $RequestedProfile -RequestedModel $RequestedModel -RepoRoot $RepoRoot
}

function Resolve-AssignedTool {
    <#
    .SYNOPSIS
    解析下一阶段的指定工具。
    .DESCRIPTION
    `tool` 仍是显式 backend 字段；可选 profile 只能补充配置，不能替代 `-Tool`。
    .PARAMETER Stage
    目标阶段。
    .PARAMETER Tool
    用户为下一阶段指定的工具。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Stage,
        [string]$Tool
    )

    if ($Stage -eq "DONE") {
        return "none"
    }

    if ([string]::IsNullOrWhiteSpace($Tool)) {
        throw ("Advancing to {0} requires -Tool (claudecode | codex)." -f $Stage)
    }

    $normalized = $Tool.Trim().ToLowerInvariant()
    if ($normalized -notin $ValidTools) {
        throw ("Unsupported tool: {0}" -f $normalized)
    }

    return $normalized
}

function Update-Frontmatter {
    <#
    .SYNOPSIS
    覆盖 plan frontmatter。
    .DESCRIPTION
    只改 lite 契约要求的字段，不碰正文和 append-only 历史。
    .PARAMETER Text
    原始 Markdown。
    .PARAMETER Task
    task_id。
    .PARAMETER Stage
    新阶段。
    .PARAMETER Tool
    tool。
    .PARAMETER ToolProfile
    可选 tool profile。
    .PARAMETER Model
    可选完整模型 ID。
    .PARAMETER Updated
    更新时间。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Text,
        [string]$Task,
        [string]$Stage,
        [string]$Tool,
        [string]$ToolProfile = "",
        [string]$Model = "",
        [string]$Updated
    )

    $frontmatterLines = @(
        "---"
        "task_id: $Task"
        "stage: $Stage"
        "tool: $Tool"
    )

    if ($Stage -ne 'DONE' -and -not [string]::IsNullOrWhiteSpace($ToolProfile)) {
        $frontmatterLines += "tool_profile: $ToolProfile"
    }

    if ($Stage -ne 'DONE' -and -not [string]::IsNullOrWhiteSpace($Model)) {
        $frontmatterLines += "model: $Model"
    }

    $frontmatterLines += @(
        "updated: $Updated"
        "---"
        ""
    )

    $frontmatter = $frontmatterLines -join "`r`n"

    return [regex]::Replace($Text, "(?s)^---\r?\n.*?\r?\n---\r?\n", $frontmatter, 1)
}

$advanceMutex = $null
$runtimeFailure = $null
$fallbackClearFailure = $null
$runtimeStage = ''
$runtimeTool = ''
$runtimeProfile = ''
$runtimeModel = ''
$testSnapshotBeforeValidation = $null
$appendError = ''
$operation = if ($ActivateCurrent.IsPresent) { 'activate' } elseif ($SyncOnly.IsPresent) { 'sync' } else { 'advance' }
try {
    $advanceMutex = Enter-LitePlanMutex -TaskId $TaskId
    if ($SyncOnly.IsPresent -and (
        -not [string]::IsNullOrWhiteSpace($Tool) -or
        -not [string]::IsNullOrWhiteSpace($Profile) -or
        -not [string]::IsNullOrWhiteSpace($Model)
    )) {
        throw 'SyncOnly cannot be combined with Tool, Profile, or Model.'
    }
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
        throw "Missing $planPath"
    }

    $planTextBeforeValidation = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
    $frontmatter = (Get-LiteFrontmatter -Content $planTextBeforeValidation).Fields
    $allowedFrontmatterFields = @('task_id', 'stage', 'tool', 'tool_profile', 'model', 'updated')
    $requiredFrontmatterFields = @('task_id', 'stage', 'tool', 'updated')
    $unexpectedFrontmatterFields = @($frontmatter.Keys | Where-Object { $_ -notin $allowedFrontmatterFields })
    $missingFrontmatterFields = @($requiredFrontmatterFields | Where-Object { -not $frontmatter.Contains($_) })
    if ($unexpectedFrontmatterFields.Count -gt 0 -or $missingFrontmatterFields.Count -gt 0) {
        throw 'Frontmatter fields are not legal for harness-lite stage synchronization.'
    }
    if ($frontmatter.updated -cnotmatch '^\d{4}-\d{2}-\d{2}$') {
        throw 'Frontmatter updated must use YYYY-MM-DD.'
    }
    $stage = $frontmatter.stage
    $currentTool = $frontmatter.tool
    $currentProfile = if ($frontmatter.Contains('tool_profile')) { $frontmatter.tool_profile } else { '' }
    $currentModel = if ($frontmatter.Contains('model')) { $frontmatter.model } else { '' }
    if ($frontmatter.task_id -cne $TaskId) {
        throw "Frontmatter task_id '$($frontmatter.task_id)' does not match '$TaskId'."
    }
    if ($stage -cnotin $ValidStages) {
        throw "Unsupported stage: $stage"
    }
    if ($stage -ceq 'DONE') {
        if ($currentTool -cne 'none') {
            throw 'DONE stage requires tool: none'
        }
    } elseif ($currentTool -cnotin $ValidTools) {
        throw "Unsupported plan tool: $currentTool"
    }
    if ($stage -cne $ExpectedStage) {
        throw "ExpectedStage CAS mismatch: expected $ExpectedStage, actual $stage."
    }
    if ($ActivateCurrent.IsPresent -and $stage -eq 'DONE') {
        throw 'ActivateCurrent cannot activate DONE.'
    }

    $planText = $planTextBeforeValidation
    $updatedPlan = $planText
    $latestCodeReviewBeforeValidation = if (-not $SyncOnly.IsPresent -and $stage -eq 'IMPLEMENT') {
        Get-RunVerdict -Text $planTextBeforeValidation -Name 'Code Review'
    } else {
        ''
    }
    $initialFailRework = -not $SyncOnly.IsPresent -and
        $stage -eq 'IMPLEMENT' -and
        $latestCodeReviewBeforeValidation -eq 'pass'
    $testExistsBeforeValidation = Test-Path -LiteralPath $testPath -PathType Leaf
    if (-not $SyncOnly.IsPresent -and
        ($stage -eq 'TEST' -or $initialFailRework) -and
        -not $testExistsBeforeValidation) {
        throw "Missing $testPath for $stage."
    }
    if (-not $SyncOnly.IsPresent -and ($stage -eq 'TEST' -or $initialFailRework)) {
        $testSnapshotBeforeValidation = Open-TestSnapshot -Path $testPath
    }
    if ($SyncOnly.IsPresent) {
        $runtimeStage = $stage
        $runtimeTool = $currentTool
        $runtimeProfile = if ($stage -eq 'DONE') { '' } else { $currentProfile }
        $runtimeModel = if ($stage -eq 'DONE') { '' } else { $currentModel }
    } else {
        Invoke-LiteArtifactValidator -ValidatorPath $validatorPath -TaskId $TaskId -RepoRoot $repoRoot -WorkspaceRoot $workspaceRoot
        $planText = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
        if ($planText -cne $planTextBeforeValidation) {
            throw 'plan.md changed while validation was running; retry the stage advance.'
        }
        if ($null -ne $testSnapshotBeforeValidation -and
            -not (Test-TestSnapshotMatches -Path $testPath -Identity $testSnapshotBeforeValidation.Identity)) {
            throw 'test.md changed while validation was running; retry the stage advance.'
        }

        $nextStage = switch ($stage) {
            'PLAN' {
                $clarification = Get-LiteSectionContent `
                    -Sections @(Get-LiteSections -Content $planText) `
                    -Name 'Clarification'
                $confirmationStatus = Get-LiteUserConfirmationStatus -Sections @(Get-LiteSections -Content $planText)
                if (@(Get-LiteMissingClarificationAspects -Content $clarification).Count -gt 0) {
                    throw 'PLAN clarification gate failed.'
                }
                if ($confirmationStatus -cne 'confirmed') {
                    throw 'PLAN requires explicit user confirmation.'
                }
                'PLAN_REVIEW'
            }
            'PLAN_REVIEW' {
                $planVerdict = Get-RunVerdict -Text $planText -Name 'Plan Review'
                if (-not $planVerdict) {
                    throw 'PLAN_REVIEW requires latest verdict.'
                }
                if ($planVerdict -eq 'pass') { 'IMPLEMENT' } else { 'PLAN' }
            }
            'IMPLEMENT' {
                $implementationRun = Get-LatestRun -Text $planText -Name 'Implementation Notes'
                if (-not $implementationRun) {
                    throw 'IMPLEMENT requires an Implementation Notes run.'
                }
                'CODE_REVIEW'
            }
            'CODE_REVIEW' {
                $codeVerdict = Get-RunVerdict -Text $planText -Name 'Code Review'
                if (-not $codeVerdict) {
                    throw 'CODE_REVIEW requires latest verdict.'
                }
                if ($codeVerdict -eq 'pass') { 'TEST' } else { 'IMPLEMENT' }
            }
            'TEST' {
                $conclusion = Get-TestConclusion -Text $testSnapshotBeforeValidation.Text
                if ($conclusion -eq 'pass') {
                    'DONE'
                } elseif ($conclusion -eq 'fail') {
                    'IMPLEMENT'
                } else {
                    throw 'TEST conclusion is blocked; stay in TEST and report the unblock condition.'
                }
            }
            'DONE' {
                throw 'Task is already DONE.'
            }
        }
        if ($ActivateCurrent.IsPresent -and $nextStage -eq 'DONE') {
            throw 'ActivateCurrent cannot activate DONE.'
        }

        $fallbackResolution = Resolve-FallbackTool -NextStage $nextStage -CliTool $Tool -CliProfile $Profile -RepoRoot $repoRoot
        $toolCandidate = if ($nextStage -eq 'DONE') { $Tool } else { $fallbackResolution.Tool }
        $runtimeTool = Resolve-AssignedTool -Stage $nextStage -Tool $toolCandidate
        $profileSelection = Resolve-ProfileSelection -Stage $nextStage -Tool $runtimeTool -ExistingProfile $currentProfile -ExistingModel $currentModel -RequestedProfile $Profile -RequestedModel $Model -Source $fallbackResolution.Source -WorkflowProfile $fallbackResolution.WorkflowProfile -WorkflowModel $fallbackResolution.WorkflowModel -RepoRoot $repoRoot
        $runtimeStage = $nextStage
        $runtimeProfile = $profileSelection.Profile
        $runtimeModel = $profileSelection.Model
        $updatedPlan = Update-Frontmatter -Text $planText -Task $TaskId -Stage $runtimeStage -Tool $runtimeTool -ToolProfile $runtimeProfile -Model $runtimeModel -Updated (Get-Date -Format 'yyyy-MM-dd')
    }

    $latestPlanReview = 'none'
    $latestCodeReview = 'none'
    try {
        $parsedPlanReview = Get-RunVerdict -Text $updatedPlan -Name 'Plan Review'
        if ($parsedPlanReview) { $latestPlanReview = $parsedPlanReview }
        $parsedCodeReview = Get-RunVerdict -Text $updatedPlan -Name 'Code Review'
        if ($parsedCodeReview) { $latestCodeReview = $parsedCodeReview }
    } catch {
        if (-not $SyncOnly.IsPresent) { throw }
    }

    $currentDoc = if ($runtimeStage -eq 'DONE') { "docs/tasks/$TaskId/test.md" } else { "docs/tasks/$TaskId/plan.md" }
    $nextStep = if ($runtimeStage -eq 'DONE') { '任务完成' } else { "使用 $runtimeTool 继续 $runtimeStage" }
    $runtimeUpdated = Get-CanonicalRuntimeTimestamp
    $taskMirror = New-CanonicalTaskRuntimeContent `
        -TaskId $TaskId `
        -TaskName $TaskId `
        -Stage $runtimeStage `
        -WorkspaceRoot $workspaceRoot `
        -PrimaryArtifact $currentDoc `
        -Tool $runtimeTool `
        -EntryHost $runtimeTool `
        -ToolProfile $runtimeProfile `
        -Model $runtimeModel `
        -LatestPlanReview $latestPlanReview `
        -LatestCodeReview $latestCodeReview `
        -Updated $runtimeUpdated
    $activeCurrentContent = if ($runtimeStage -eq 'DONE') {
        New-CanonicalIdleCurrentContent -Updated $runtimeUpdated
    } else {
        New-CanonicalCurrentTaskContent `
            -TaskId $TaskId `
            -TaskName $TaskId `
            -Stage $runtimeStage `
            -CurrentDoc $currentDoc `
            -Tool $runtimeTool `
            -EntryHost $runtimeTool `
            -ToolProfile $runtimeProfile `
            -Model $runtimeModel `
            -NextStep $nextStep `
            -Updated $runtimeUpdated
    }

    $runtimeMutex = Enter-CanonicalRuntimeMutex -VaultRoot $VaultRoot
    try {
        $planTextAtCommit = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
        if ($planTextAtCommit -cne $planTextBeforeValidation) {
            throw 'plan.md changed before stage/runtime commit; retry the operation.'
        }
        $currentState = Get-CanonicalCurrentTaskState -Path $currentPath
        if ($currentState.Exists -and (
            $currentState.SchemaVersion -ne 'current-task-pointer/v1.1' -or
            [string]::IsNullOrWhiteSpace($currentState.TaskId)
        )) {
            throw 'Current task pointer is not canonical; repair it before stage transition.'
        }
        $currentMissing = -not $currentState.Exists
        $currentIsActive = $currentState.Exists -and $currentState.TaskId -eq $TaskId
        if (-not $SyncOnly.IsPresent) {
            if ($null -ne $testSnapshotBeforeValidation -and
                -not (Test-TestSnapshotMatches -Path $testPath -Identity $testSnapshotBeforeValidation.Identity)) {
                throw 'test.md changed before stage/runtime commit; retry the operation.'
            }
            Write-LiteUtf8BomAtomic -Path $planPath -Content $updatedPlan
            if ($null -ne $testSnapshotBeforeValidation) {
                $testSnapshotBeforeValidation.Handle.Dispose()
                $testSnapshotBeforeValidation.Handle = $null
            }
        }

        $currentWriteContent = $null
        if ($ActivateCurrent.IsPresent -or $currentIsActive) {
            $currentWriteContent = $activeCurrentContent
        } elseif ($currentMissing) {
            $currentWriteContent = New-CanonicalIdleCurrentContent -Updated $runtimeUpdated
        }

        $runtimeSteps = @(
            [pscustomobject]@{
                Step = 'tasks-mirror'
                Action = {
                    Ensure-ParentDirectory -Path $taskMirrorPath
                    Write-CanonicalRuntimeUtf8BomAtomic -Path $taskMirrorPath -Content $taskMirror
                }
            }
        )
        if ($null -ne $currentWriteContent) {
            $runtimeSteps += [pscustomobject]@{
                Step = 'current-task'
                Action = {
                    Ensure-ParentDirectory -Path $currentPath
                    Write-CanonicalRuntimeUtf8BomAtomic -Path $currentPath -Content $currentWriteContent
                }
            }
        }
        $runtimeSteps += [pscustomobject]@{
            Step = 'recovery-index'
            Action = {
                Ensure-ParentDirectory -Path $indexPath
                $canonicalCurrent = Get-CanonicalCurrentTaskState -Path $currentPath
                $canonicalRecords = Get-CanonicalTaskRuntimeRecords -TasksDirectory $tasksDir
                Write-CanonicalRuntimeUtf8BomAtomic -Path $indexPath -Content (New-CanonicalRecoveryIndexContent -CurrentTask $canonicalCurrent -TaskRecords $canonicalRecords -Updated $runtimeUpdated)
            }
        }
        foreach ($runtimeStep in $runtimeSteps) {
            try {
                & $runtimeStep.Action
            } catch {
                $runtimeFailure = [pscustomobject]@{
                    Step = $runtimeStep.Step
                    Reason = $_.Exception.Message
                }
                break
            }
        }
    } finally {
        Exit-CanonicalRuntimeMutex -Mutex $runtimeMutex
    }
    if ($null -ne $runtimeFailure) {
        $fallbackPayload = [ordered]@{
            schema_version = 'writeback-fallback/v1'
            operation = $operation
            expected_stage = $runtimeStage
            failed_step = $runtimeFailure.Step
            reason = $runtimeFailure.Reason
        } | ConvertTo-Json -Compress
        $appendError = Report-WritebackFallback -VaultRoot $VaultRoot -TaskId $TaskId -Step $runtimeFailure.Step -Reason $runtimeFailure.Reason -Payload $fallbackPayload
    }
    if ($null -eq $runtimeFailure) {
        try {
            $null = Clear-RuntimeWritebackFallback -VaultRoot $VaultRoot -TaskId $TaskId -ActivateCurrent:$ActivateCurrent.IsPresent
        } catch {
            $fallbackClearFailure = $_.Exception.Message
        }
    }
    if ($null -eq $runtimeFailure -and $null -eq $fallbackClearFailure -and -not $SyncOnly.IsPresent) {
        try {
            Write-SkillManifest -RepoRoot $repoRoot -WorkspaceRoot $workspaceRoot -TaskId $TaskId -Stage $runtimeStage -Tool $runtimeTool
        } catch {
            [Console]::Error.WriteLine("skill-manifest write skipped: $($_.Exception.Message)")
        }
    }
} finally {
    try {
        if ($null -ne $testSnapshotBeforeValidation -and $null -ne $testSnapshotBeforeValidation.Handle) {
            $testSnapshotBeforeValidation.Handle.Dispose()
        }
    } finally {
        Exit-LitePlanMutex -Mutex $advanceMutex
    }
}

$replayCommand = Get-SyncReplayCommand -TaskId $TaskId -ExpectedStage $runtimeStage -RepoRoot $repoRoot -WorkspaceRoot $workspaceRoot -VaultRoot $VaultRoot -ActivateCurrent:$ActivateCurrent.IsPresent
if ($null -ne $runtimeFailure) {
    [Console]::Error.WriteLine("Replay: $replayCommand")
    $appendSuffix = if ([string]::IsNullOrWhiteSpace($appendError)) { '' } else { " Fallback append failed: $appendError" }
    throw "Runtime writeback failed at $($runtimeFailure.Step) after stage $runtimeStage.$appendSuffix Replay: $replayCommand"
}

if ($null -ne $fallbackClearFailure) {
    [Console]::Error.WriteLine("Replay: $replayCommand")
    throw "fallback clear failed: $fallbackClearFailure Replay: $replayCommand"
}

if ($SyncOnly.IsPresent) {
    Write-Output "SYNCED | $runtimeStage | $runtimeTool"
} else {
    Write-Output "$runtimeStage | $runtimeTool"
}
