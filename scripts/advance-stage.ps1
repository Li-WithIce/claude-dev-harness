# 推进 harness lite 阶段，并按 `plan.md` frontmatter 重写共享运行时 mirror。
# 这个脚本只认 lite 契约：`docs/tasks/<task-id>/plan.md` 是唯一阶段真相源。
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [string]$Tool = "",

    [string]$Profile = "",

    [string]$Model = "",

    [string]$VaultRoot = $Env:OBSIDIAN_VAULT,

    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ValidStages = @("PLAN", "PLAN_REVIEW", "IMPLEMENT", "CODE_REVIEW", "TEST", "DONE")
$ValidTools = @("claudecode", "codex", "gemini")
$ModelAliasPattern = '^(opus|sonnet|haiku|pro|flash|default|latest|codex|gemini|claude|gpt)$'

if (-not $VaultRoot) {
    throw "Set OBSIDIAN_VAULT or pass -VaultRoot."
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
} else {
    $repoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
}
$planPath = Join-Path $repoRoot "docs/tasks/$TaskId/plan.md"
$testPath = Join-Path $repoRoot "docs/tasks/$TaskId/test.md"
$tasksDir = Join-Path $VaultRoot "运行时/tasks"
$taskMirrorPath = Join-Path $tasksDir "$TaskId.md"
$indexPath = Join-Path $VaultRoot "运行时/恢复索引.md"
$currentPath = Join-Path $VaultRoot "运行时/当前任务.md"
$validatorPath = Join-Path $PSScriptRoot "validate-lite-artifacts.ps1"

if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Missing $planPath"
}

if (-not (Test-Path -LiteralPath $tasksDir -PathType Container)) {
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
}

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
    仓库根目录。
    .OUTPUTS
    None。
    #>
    param(
        [string]$ValidatorPath,
        [string]$TaskId,
        [string]$RepoRoot
    )

    $shellPath = (Get-Process -Id $PID).Path
    $output = @(& $shellPath -NoProfile -File $ValidatorPath -TaskId $TaskId -RepoRoot $RepoRoot 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -eq 0) {
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

function Get-Frontmatter {
    <#
    .SYNOPSIS
    解析 Markdown frontmatter。
    .DESCRIPTION
    读取 lite workflow 的 frontmatter，并返回键值表。
    .PARAMETER Text
    Markdown 全文。
    .OUTPUTS
    Hashtable。
    #>
    param([string]$Text)

    if ($Text -notmatch "(?s)^---\r?\n(.*?)\r?\n---\r?\n") {
        throw "Missing frontmatter."
    }

    $map = @{}
    foreach ($line in ($Matches[1] -split "\r?\n")) {
        if ($line -match "^\s*([^:]+):\s*(.+?)\s*$") {
            $map[$Matches[1]] = $Matches[2]
        }
    }

    return $map
}

function Get-Section {
    <#
    .SYNOPSIS
    读取二级标题内容。
    .DESCRIPTION
    按 `## <name>` 截取 section，供 gate 检查使用。
    .PARAMETER Text
    Markdown 全文。
    .PARAMETER Name
    目标 section 名。
    .OUTPUTS
    String。
    #>
    param(
        [string]$Text,
        [string]$Name
    )

    if ($Text -match "(?ms)^## $([regex]::Escape($Name))\r?\n(.*?)(?=^## |\z)") {
        return $Matches[1].Trim()
    }

    return ""
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

    $runs = [regex]::Matches((Get-Section -Text $Text -Name $Name), "(?ms)^### Run .*?(?=^### Run |\z)")
    if ($runs.Count -eq 0) {
        return ""
    }

    return $runs[$runs.Count - 1].Value.Trim()
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

    $run = Get-LatestRun -Text $Text -Name $Name
    if ($run -match "(?m)^- verdict:\s*(pass|revise)\s*$") {
        return $Matches[1]
    }

    return ""
}

function Get-RunTimestamp {
    <#
    .SYNOPSIS
    读取 Run 标题时间。
    .DESCRIPTION
    IMPLEMENT gate 用它判断回修后是否追加了新证据。
    .PARAMETER Text
    Markdown 全文。
    .PARAMETER Name
    section 名。
    .OUTPUTS
    Nullable[datetime]。
    #>
    param(
        [string]$Text,
        [string]$Name
    )

    $run = Get-LatestRun -Text $Text -Name $Name
    if ($run -match "(?m)^### Run \d+\s+·\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s+·\s+runner:") {
        return [datetime]::ParseExact($Matches[1], "yyyy-MM-dd HH:mm", [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return $null
}

function Write-Utf8Bom {
    <#
    .SYNOPSIS
    以 UTF-8 BOM 写文件。
    .DESCRIPTION
    共享运行时 markdown 延续仓库现有 BOM 写法，避免 Windows 下再次漂编码。
    .PARAMETER Path
    目标路径。
    .PARAMETER Content
    要写入的文本。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Write-Utf8NoBom {
    <#
    .SYNOPSIS
    以 UTF-8 无 BOM 写文件。
    .DESCRIPTION
    skill-manifest.json 需要 UTF-8 无 BOM，避免被嵌入端再做额外清洗。
    .PARAMETER Path
    目标路径。
    .PARAMETER Content
    要写入的文本。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-FullModelId {
    <#
    .SYNOPSIS
    判断 model 是否看起来像完整模型 ID。
    .DESCRIPTION
    Phase 1 不接入具体模型注册表，只阻止 `opus`、`pro` 这类短别名进入机器可读契约。
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
    仓库根目录。
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

    if ($fields['backend'] -notin $ValidTools) {
        throw ("Tool profile {0} has unsupported backend: {1}" -f $normalizedName, $fields['backend'])
    }

    if (-not (Test-FullModelId -Model $fields['model'])) {
        throw ("Tool profile {0} model should be a full model id, got: {1}" -f $normalizedName, $fields['model'])
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
    仓库根目录。
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
        [string]$TaskId,
        [string]$Stage,
        [string]$Tool
    )

    $manifestPath = Join-Path $RepoRoot ("docs/tasks/{0}/skill-manifest.json" -f $TaskId)
    $manifest = [ordered]@{
        version = 1
        task_id = $TaskId
        stage = $Stage
        tool = $Tool
        available_commands = @(Get-StageSkillCommands -RepoRoot $RepoRoot -Stage $Stage)
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
    }

    Write-Utf8NoBom -Path $manifestPath -Content (($manifest | ConvertTo-Json -Depth 8 -Compress))
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
        throw ("Model should be a full model id, got: {0}" -f $selectedModel)
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
        throw ("Advancing to {0} requires -Tool (claudecode | codex | gemini)." -f $Stage)
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

function New-CurrentTaskContent {
    <#
    .SYNOPSIS
    生成共享运行时当前任务指针。
    .DESCRIPTION
    当前任务文件与 obsidian-memory 读取侧共用同一张表，避免阶段推进后写出不可读格式。
    .PARAMETER TaskId
    任务 ID。
    .PARAMETER Status
    当前阶段。
    .PARAMETER CurrentDoc
    当前主文档路径。
    .PARAMETER Tool
    当前阶段工具。
    .PARAMETER ToolProfile
    当前阶段 tool profile。
    .PARAMETER Model
    当前阶段模型。
    .PARAMETER NextStep
    下一步说明。
    .OUTPUTS
    String。
    #>
    param(
        [string]$TaskId,
        [string]$Status,
        [string]$CurrentDoc,
        [string]$Tool,
        [string]$ToolProfile = "",
        [string]$Model = "",
        [string]$NextStep
    )

    $lines = @(
        '---'
        ('updated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('task_id: {0}' -f $TaskId)
        'writer: advance-stage'
        '---'
        ''
        '# 当前任务'
        ''
        '| 项目 | 值 |'
        '|------|-----|'
        ('| task_id | `{0}` |' -f $TaskId)
        ('| 任务 | {0} |' -f $TaskId)
        ('| 状态 | {0} |' -f $Status)
        ('| 当前文档 | {0} |' -f $CurrentDoc)
        ('| 工具 | {0} |' -f $Tool)
    )

    if (-not [string]::IsNullOrWhiteSpace($ToolProfile)) {
        $lines += ('| Tool Profile | {0} |' -f $ToolProfile)
    }

    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $lines += ('| Model | {0} |' -f $Model)
    }

    $lines += ('| 下一步 | {0} |' -f $NextStep)
    return $lines -join "`r`n"
}

function Write-RecoveryIndex {
    <#
    .SYNOPSIS
    重写恢复索引。
    .DESCRIPTION
    lite flow 只从 `运行时/tasks/*.md` 汇总任务，不再依赖 `中断任务.md`。
    .PARAMETER TasksDirectory
    任务 mirror 目录。
    .PARAMETER Path
    恢复索引文件路径。
    .OUTPUTS
    None。
    #>
    param(
        [string]$TasksDirectory,
        [string]$Path
    )

    $rows = @()
    foreach ($file in Get-ChildItem -LiteralPath $TasksDirectory -Filter "*.md" -File | Sort-Object Name) {
        $mirrorText = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        $meta = Get-Frontmatter -Text $mirrorText
        $rows += [pscustomobject]@{
            TaskId  = $meta.task_id
            Stage   = $meta.stage
            Updated = $meta.updated
        }
    }

    $ordered = $rows | Sort-Object Updated, TaskId -Descending
    $content = "# 恢复索引`r`n`r`n"
    foreach ($row in $ordered) {
        $content += "- $($row.TaskId) | $($row.Stage) | $($row.Updated)`r`n"
    }

    Write-Utf8Bom -Path $Path -Content $content
}

$planText = Get-Content -LiteralPath $planPath -Raw -Encoding utf8
$frontmatter = Get-Frontmatter -Text $planText
$stage = $frontmatter.stage
$currentTool = $frontmatter.tool
$currentProfile = if ($frontmatter.ContainsKey('tool_profile')) { $frontmatter.tool_profile } else { "" }
$currentModel = if ($frontmatter.ContainsKey('model')) { $frontmatter.model } else { "" }

if ($frontmatter.task_id -ne $TaskId) {
    throw "Frontmatter task_id '$($frontmatter.task_id)' does not match '$TaskId'."
}

if ($stage -notin $ValidStages) {
    throw "Unsupported stage: $stage"
}

if ($stage -eq 'DONE') {
    if ($currentTool -ne 'none') {
        throw "DONE stage requires tool: none"
    }
} elseif ($currentTool -notin $ValidTools) {
    throw "Unsupported plan tool: $currentTool"
}

Invoke-LiteArtifactValidator -ValidatorPath $validatorPath -TaskId $TaskId -RepoRoot $repoRoot

$today = Get-Date -Format "yyyy-MM-dd"
$nextStage = switch ($stage) {
    "PLAN" {
        $clarification = Get-Section -Text $planText -Name "Clarification"
        $confirmation = Get-Section -Text $planText -Name "User Confirmation"
        if ($clarification -notmatch "验收" -or
            $clarification -notmatch "非目标" -or
            $clarification -notmatch "受影响" -or
            ($clarification -notmatch "回滚" -and $clarification -notmatch "兼容") -or
            $clarification -notmatch "ui:") {
            throw "PLAN clarification gate failed."
        }
        if ($confirmation -notmatch "(?m)^- status:\s*confirmed\s*$") {
            throw "PLAN requires explicit user confirmation."
        }
        "PLAN_REVIEW"
    }
    "PLAN_REVIEW" {
        $planVerdict = Get-RunVerdict -Text $planText -Name "Plan Review"
        if (-not $planVerdict) {
            throw "PLAN_REVIEW requires latest verdict."
        }
        if ($planVerdict -eq "pass") { "IMPLEMENT" } else { "PLAN" }
    }
    "IMPLEMENT" {
        $implementationRun = Get-LatestRun -Text $planText -Name "Implementation Notes"
        if (-not $implementationRun) {
            throw "IMPLEMENT requires an Implementation Notes run."
        }

        $implementationTime = Get-RunTimestamp -Text $planText -Name "Implementation Notes"
        $codeVerdict = Get-RunVerdict -Text $planText -Name "Code Review"
        $codeReviewTime = Get-RunTimestamp -Text $planText -Name "Code Review"
        if ($codeVerdict -eq "revise" -and $null -ne $codeReviewTime -and $implementationTime -le $codeReviewTime) {
            throw "IMPLEMENT requires a fresh Implementation Notes run after CODE_REVIEW revise."
        }

        "CODE_REVIEW"
    }
    "CODE_REVIEW" {
        $codeVerdict = Get-RunVerdict -Text $planText -Name "Code Review"
        if (-not $codeVerdict) {
            throw "CODE_REVIEW requires latest verdict."
        }
        if ($codeVerdict -eq "pass") { "TEST" } else { "IMPLEMENT" }
    }
    "TEST" {
        if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
            throw "Missing $testPath"
        }

        $testText = Get-Content -LiteralPath $testPath -Raw -Encoding utf8
        if ($testText -notmatch "(?ms)^## Conclusion\r?\n(pass|fail|blocked)\s*$") {
            throw "TEST requires Conclusion."
        }
        $conclusion = $Matches[1]
        if ($testText -notmatch "(?m)^## Handoff\s*$") {
            throw "TEST requires Handoff."
        }
        if ($conclusion -ne "pass") {
            throw "TEST conclusion is $conclusion; stop and report."
        }

        "DONE"
    }
    "DONE" {
        throw "Task is already DONE."
    }
}

$fallbackResolution = Resolve-FallbackTool -NextStage $nextStage -CliTool $Tool -CliProfile $Profile -RepoRoot $repoRoot
$toolCandidate = if ($nextStage -eq 'DONE') { $Tool } else { $fallbackResolution.Tool }
$nextTool = Resolve-AssignedTool -Stage $nextStage -Tool $toolCandidate
$profileSelection = Resolve-ProfileSelection -Stage $nextStage -Tool $nextTool -ExistingProfile $currentProfile -ExistingModel $currentModel -RequestedProfile $Profile -RequestedModel $Model -Source $fallbackResolution.Source -WorkflowProfile $fallbackResolution.WorkflowProfile -WorkflowModel $fallbackResolution.WorkflowModel -RepoRoot $repoRoot
$nextProfile = $profileSelection.Profile
$nextModel = $profileSelection.Model
$updatedPlan = Update-Frontmatter -Text $planText -Task $TaskId -Stage $nextStage -Tool $nextTool -ToolProfile $nextProfile -Model $nextModel -Updated $today
Write-Utf8Bom -Path $planPath -Content $updatedPlan

$latestPlanReview = Get-RunVerdict -Text $updatedPlan -Name "Plan Review"
if (-not $latestPlanReview) {
    $latestPlanReview = "none"
}

$latestCodeReview = Get-RunVerdict -Text $updatedPlan -Name "Code Review"
if (-not $latestCodeReview) {
    $latestCodeReview = "none"
}

$currentDoc = if ($nextStage -eq 'DONE') {
    "docs/tasks/$TaskId/test.md"
} else {
    "docs/tasks/$TaskId/plan.md"
}
$nextStep = if ($nextStage -eq 'DONE') {
    '任务完成'
} else {
    "使用 $nextTool 继续 $nextStage"
}
$taskMirrorLines = @(
    "---"
    "task_id: $TaskId"
    "stage: $nextStage"
    "tool: $nextTool"
)

if (-not [string]::IsNullOrWhiteSpace($nextProfile)) {
    $taskMirrorLines += "tool_profile: $nextProfile"
}

if (-not [string]::IsNullOrWhiteSpace($nextModel)) {
    $taskMirrorLines += "model: $nextModel"
}

$taskMirrorLines += @(
    "updated: $today"
    "---"
    "# Task Mirror"
    ""
    "- pointer: $currentDoc"
    "- assigned_tool: $nextTool"
)

if (-not [string]::IsNullOrWhiteSpace($nextProfile)) {
    $taskMirrorLines += "- assigned_tool_profile: $nextProfile"
}

if (-not [string]::IsNullOrWhiteSpace($nextModel)) {
    $taskMirrorLines += "- assigned_model: $nextModel"
}

$taskMirrorLines += @(
    "- latest_plan_review: $latestPlanReview"
    "- latest_code_review: $latestCodeReview"
    ""
)
$taskMirror = $taskMirrorLines -join "`r`n"

Write-Utf8Bom -Path $taskMirrorPath -Content $taskMirror
Write-Utf8Bom -Path $currentPath -Content (New-CurrentTaskContent -TaskId $TaskId -Status $nextStage -CurrentDoc $currentDoc -Tool $nextTool -ToolProfile $nextProfile -Model $nextModel -NextStep $nextStep)
Write-RecoveryIndex -TasksDirectory $tasksDir -Path $indexPath

Write-Output "$nextStage | $nextTool"
try {
    Write-SkillManifest -RepoRoot $repoRoot -TaskId $TaskId -Stage $nextStage -Tool $nextTool
} catch {
    [Console]::Error.WriteLine("skill-manifest write skipped: $($_.Exception.Message)")
}
