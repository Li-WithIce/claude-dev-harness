# 校验单个 `docs/tasks/<task-id>/` 任务目录是否满足 harness-lite 文档契约。
# 这份脚本只覆盖当前主线真正依赖的结构，不再兼容 legacy artifact 语义。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [string]$RepoRoot = "",

    [switch]$Quality
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AllowedStages = @("PLAN", "PLAN_REVIEW", "IMPLEMENT", "CODE_REVIEW", "TEST", "DONE")
$script:AllowedTools = @("claudecode", "codex", "gemini")
$script:AllowedFrontmatterFields = @("task_id", "stage", "tool", "tool_profile", "model", "updated")
$script:RequiredFrontmatterFields = @("task_id", "stage", "tool", "updated")
$script:OptionalFrontmatterFields = @("tool_profile", "model")
$script:ModelAliasPattern = '^(opus|sonnet|haiku|pro|flash|default|latest|codex|gemini|claude|gpt)$'
$script:PlanSections = @(
    "Clarification",
    "User Confirmation",
    "Plan",
    "Verification",
    "Risks",
    "Plan Review",
    "Implementation Notes",
    "Code Review"
)
$script:OptionalPlanSections = @("Change Contract")
$script:AllowedChangeTypes = @("task", "feature", "enhance", "refactor")
$script:QualityScoreDimensions = @("completeness", "consistency", "accuracy", "depth")
$script:TestSections = @(
    "Summary",
    "Scope",
    "Inputs Reviewed",
    "Test Approach",
    "Findings",
    "Risks / Gaps",
    "Conclusion",
    "Handoff"
)
$script:SpecSections = @("Gap", "Constraint", "Verification Delta")

function Add-Check {
    <#
    .SYNOPSIS
    记录一条通过项。
    .DESCRIPTION
    所有检查结果统一汇总输出，方便直接看 validator 覆盖了哪些 lite 契约。
    .PARAMETER Message
    检查说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Checks += $Message
}

function Add-Failure {
    <#
    .SYNOPSIS
    记录一条失败项。
    .DESCRIPTION
    失败项不会中断后续检查，脚本末尾统一返回 FAIL，方便一次看全契约漂移。
    .PARAMETER Message
    失败说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Failures += $Message
}

function Add-Warning {
    <#
    .SYNOPSIS
    记录一条警告项。
    .DESCRIPTION
    advisory 检查使用 Warnings 输出，不改变 validator 的退出码。
    .PARAMETER Message
    警告说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Warnings += $Message
}

function Get-Frontmatter {
    <#
    .SYNOPSIS
    解析 markdown 顶部 frontmatter。
    .DESCRIPTION
    harness-lite 只接受位于文档开头、由两段 `---` 包住的最小 YAML 样式 frontmatter。
    .PARAMETER Content
    完整 markdown 文本。
    .OUTPUTS
    PSCustomObject。
    #>
    param([string]$Content)

    $match = [regex]::Match($Content, '\A---\r?\n(.*?)\r?\n---\r?\n', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw "missing frontmatter block"
    }

    $fields = [ordered]@{}
    foreach ($line in ($match.Groups[1].Value -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -notmatch '^([a-z_]+):\s*(.+)$') {
            throw "invalid frontmatter line: $line"
        }

        $fields[$matches[1]] = $matches[2].Trim()
    }

    [pscustomobject]@{
        Fields = $fields
        Body = $Content.Substring($match.Length)
    }
}

function Get-Sections {
    <#
    .SYNOPSIS
    提取二级标题 section。
    .DESCRIPTION
    validator 只认 `## ` section；这和 lite 文档契约里的机器可读标题层级保持一致。
    .PARAMETER Content
    去掉 frontmatter 之后的 markdown 正文。
    .OUTPUTS
    Object[]。
    #>
    param([string]$Content)

    $sections = @()
    $matches = [regex]::Matches($Content, '(?ms)^##\s+(.+?)\r?\n(.*?)(?=^##\s+|\z)')
    foreach ($match in $matches) {
        $sections += [pscustomobject]@{
            Name = $match.Groups[1].Value.Trim()
            Content = $match.Groups[2].Value.Trim()
        }
    }

    return $sections
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

    return ($normalized -notmatch $script:ModelAliasPattern)
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
    PSCustomObject 或 $null。
    #>
    param(
        [string]$RepoRoot,
        [string]$Name
    )

    try {
        return Read-ToolProfileDescriptor -RepoRoot $RepoRoot -Name $Name
    } catch {
        Add-Failure $_.Exception.Message
        return $null
    }
}

function Read-ToolProfileDescriptor {
    <#
    .SYNOPSIS
    读取 tool profile 描述符。
    .DESCRIPTION
    返回纯数据对象；调用方决定把异常记为 failure 还是 warning。
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
        throw "tool_profile should not be empty"
    }

    $normalizedName = $Name.Trim()
    if ($normalizedName -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw ("tool_profile has unsupported name: {0}" -f $normalizedName)
    }

    $profilePath = Join-Path (Join-Path $RepoRoot 'agent-configs\profiles') ("{0}.yaml" -f $normalizedName)
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw ("tool_profile descriptor should exist: {0}" -f $profilePath)
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
            throw ("tool_profile {0} descriptor should contain {1}" -f $normalizedName, $required)
        }
    }

    if ($fields['name'] -ne $normalizedName) {
        throw ("tool_profile file name {0} should match descriptor name {1}" -f $normalizedName, $fields['name'])
    }

    [pscustomobject]@{
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
    workflow descriptor 只使用 `[a, b]` 的最小列表语法。
    .PARAMETER Value
    inline list 文本。
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

function Get-TopLevelPlanBullets {
    <#
    .SYNOPSIS
    解析 `## Plan` 段顶部 metadata-style 字段与普通 bullets。
    .DESCRIPTION
    Phase 6/7 允许 `read_first:` / `convergence:` / `artifacts:` 作为可选 metadata block，
    但它们必须出现在第一条普通 bullet 之前。
    .PARAMETER Content
    `## Plan` section 正文。
    .OUTPUTS
    PSCustomObject。
    #>
    param([string]$Content)

    $lines = @($Content -split "\r?\n")
    $ordinaryBullets = @()
    $readFirstItems = @()
    $convergenceItems = @()
    $artifactsItems = @()
    $hasReadFirst = $false
    $hasConvergence = $false
    $hasArtifacts = $false
    $metadataClosed = $false
    $capturingConvergence = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if ($line -match '^- read_first:\s*(.*?)\s*$') {
            if ($metadataClosed) {
                Add-Failure "Plan metadata read_first should appear before ordinary Plan bullets"
                continue
            }

            if ($hasReadFirst) {
                Add-Failure "Plan metadata should contain at most one read_first field"
                continue
            }

            $hasReadFirst = $true
            $capturingConvergence = $false

            try {
                $readFirstItems = @(Split-InlineYamlList -Value $Matches[1])
            } catch {
                Add-Failure "Plan read_first should use inline-array syntax like [a, b]"
                continue
            }

            if ($readFirstItems.Count -eq 0) {
                Add-Failure "Plan read_first should contain at least one entry"
            } else {
                Add-Check "Plan read_first metadata is legal"
            }

            continue
        }

        if ($line -match '^- convergence:\s*$') {
            if ($metadataClosed) {
                Add-Failure "Plan metadata convergence should appear before ordinary Plan bullets"
                continue
            }

            if ($hasConvergence) {
                Add-Failure "Plan metadata should contain at most one convergence block"
                continue
            }

            $hasConvergence = $true
            $capturingConvergence = $true
            continue
        }

        if ($line -match '^- artifacts:\s*(.*?)\s*$') {
            if ($metadataClosed) {
                Add-Failure "Plan metadata artifacts should appear before ordinary Plan bullets"
                continue
            }

            if ($hasArtifacts) {
                Add-Failure "Plan metadata should contain at most one artifacts field"
                continue
            }

            $hasArtifacts = $true
            $capturingConvergence = $false

            try {
                $artifactsItems = @(Split-InlineYamlList -Value $Matches[1])
            } catch {
                Add-Failure "Plan artifacts should use inline-array syntax like [a, b]"
                continue
            }

            if ($artifactsItems.Count -eq 0) {
                Add-Failure "Plan artifacts should contain at least one entry"
            } else {
                Add-Check "Plan artifacts metadata is legal"
            }

            continue
        }

        if ($capturingConvergence -and $line -match '^\s{2,}-\s+(.+?)\s*$') {
            $criterion = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($criterion)) {
                $convergenceItems += $criterion
            }
            continue
        }

        if ($line -match '^- .+$') {
            if ($capturingConvergence) {
                $capturingConvergence = $false
            }

            $metadataClosed = $true
            $ordinaryBullets += $trimmed
            continue
        }

        if ($capturingConvergence) {
            Add-Failure "Plan convergence should use indented bullets"
            $capturingConvergence = $false
            $metadataClosed = $true
        }

        $metadataClosed = $true
    }

    if ($hasConvergence) {
        if ($convergenceItems.Count -eq 0) {
            Add-Failure "Plan convergence should contain at least one criterion"
        } else {
            $nonPlaceholderCriteria = @(
                $convergenceItems | Where-Object {
                    $_ -notmatch '^(?i:tbd|todo|none)$'
                }
            )
            if ($nonPlaceholderCriteria.Count -eq 0) {
                Add-Failure "Plan convergence should contain at least one non-placeholder criterion"
            } else {
                Add-Check "Plan convergence metadata is legal"
            }
        }
    }

    return [pscustomobject]@{
        OrdinaryBullets = $ordinaryBullets
        ReadFirstItems = $readFirstItems
        ConvergenceItems = $convergenceItems
        ArtifactsItems = $artifactsItems
    }
}

function Get-AllowedWorkflowSkills {
    <#
    .SYNOPSIS
    返回 workflow descriptor 允许引用的 skill 白名单。
    .DESCRIPTION
    直接读取仓库当前 `skills/` 目录，和 footprint 测试锁定的技能集合保持同步。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    String[]。
    #>
    param([string]$RepoRoot)

    return @(
        'codex',
        'entry-router',
        'gemini-designer-main',
        'implement',
        'obsidian-memory',
        'orchestrator',
        'plan',
        'review',
        'spec',
        'test',
        'using-superpowers'
    )
}

function Get-WorkflowDescriptorForAudit {
    <#
    .SYNOPSIS
    读取 workflow descriptor 供 advisory audit 使用。
    .DESCRIPTION
    解析失败时只收集 warning，不抛 fatal failure。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    PSCustomObject。
    #>
    param([string]$RepoRoot)

    $descriptorPath = Join-Path (Join-Path $RepoRoot 'agent-configs\workflows') 'harness-lite.yaml'
    if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        return [pscustomobject]@{
            Exists = $false
            Descriptor = $null
            Warnings = @()
        }
    }

    $warnings = @()
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
                $warnings += ("workflow descriptor duplicates stage {0} at line {1}" -f $currentStage, $lineNumber)
                continue
            }

            $descriptor.Stages[$currentStage] = [ordered]@{
                Role = ''
                DefaultProfile = ''
                SkillsWhitelist = @()
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentStage)) {
            $warnings += ("workflow descriptor has unsupported line {0}: {1}" -f $lineNumber, $trimmed)
            continue
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
            try {
                $descriptor.Stages[$currentStage]['SkillsWhitelist'] = @(Split-InlineYamlList -Value $Matches[1])
            } catch {
                $warnings += ("workflow descriptor stage {0} has invalid skills_whitelist at line {1}" -f $currentStage, $lineNumber)
            }
            continue
        }

        $warnings += ("workflow descriptor has unsupported line {0}: {1}" -f $lineNumber, $trimmed)
    }

    if ([string]::IsNullOrWhiteSpace($descriptor.Name)) {
        $warnings += "workflow descriptor should contain name"
    }

    if ([string]::IsNullOrWhiteSpace($descriptor.Version)) {
        $warnings += "workflow descriptor should contain version"
    }

    if (-not $sawStages) {
        $warnings += "workflow descriptor should contain stages"
    }

    return [pscustomobject]@{
        Exists = $true
        Descriptor = [pscustomobject]@{
            Name = $descriptor.Name
            Version = $descriptor.Version
            Stages = $descriptor.Stages
            Path = $descriptor.Path
        }
        Warnings = $warnings
    }
}

function Assert-WorkflowDescriptorAdvisory {
    <#
    .SYNOPSIS
    执行 workflow descriptor advisory audit。
    .DESCRIPTION
    只写 Warnings，不写 Errors，确保显式 `-Tool` 路径不会被坏描述符阻塞。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    None。
    #>
    param([string]$RepoRoot)

    $audit = Get-WorkflowDescriptorForAudit -RepoRoot $RepoRoot
    if (-not $audit.Exists) {
        return
    }

    foreach ($warning in $audit.Warnings) {
        Add-Warning $warning
    }

    $descriptor = $audit.Descriptor
    if ($null -eq $descriptor) {
        return
    }

    $expectedStages = @('PLAN', 'PLAN_REVIEW', 'IMPLEMENT', 'CODE_REVIEW', 'TEST')
    foreach ($expectedStage in $expectedStages) {
        if (-not $descriptor.Stages.Contains($expectedStage)) {
            Add-Warning ("workflow descriptor should define stage: {0}" -f $expectedStage)
        }
    }

    foreach ($stageName in @($descriptor.Stages.Keys)) {
        $stageDescriptor = $descriptor.Stages[$stageName]
        if ($stageName -notin $expectedStages) {
            Add-Warning ("workflow descriptor contains unsupported stage: {0}" -f $stageName)
        }

        if ([string]::IsNullOrWhiteSpace($stageDescriptor.Role)) {
            Add-Warning ("workflow descriptor stage {0} should contain role" -f $stageName)
        } elseif ($stageDescriptor.Role -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            Add-Warning ("workflow descriptor stage {0} role should be kebab-case, got [{1}]" -f $stageName, $stageDescriptor.Role)
        }

        if ([string]::IsNullOrWhiteSpace($stageDescriptor.DefaultProfile)) {
            Add-Warning ("workflow descriptor stage {0} should contain default_profile" -f $stageName)
        } else {
            try {
                [void](Read-ToolProfileDescriptor -RepoRoot $RepoRoot -Name $stageDescriptor.DefaultProfile)
            } catch {
                Add-Warning ("workflow descriptor stage {0} default_profile is invalid: {1}" -f $stageName, $stageDescriptor.DefaultProfile)
            }
        }

        if ($stageDescriptor.SkillsWhitelist.Count -eq 0) {
            Add-Warning ("workflow descriptor stage {0} should contain skills_whitelist" -f $stageName)
            continue
        }

        $allowedSkills = @(Get-AllowedWorkflowSkills -RepoRoot $RepoRoot)
        foreach ($skill in $stageDescriptor.SkillsWhitelist) {
            if ($skill -notin $allowedSkills) {
                Add-Warning ("workflow descriptor stage {0} references unsupported skill: {1}" -f $stageName, $skill)
            }
        }
    }
}

function Assert-FullModelId {
    <#
    .SYNOPSIS
    校验 model 字段使用完整 ID。
    .PARAMETER Model
    模型 ID。
    .PARAMETER Label
    错误标签。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Model,
        [string]$Label
    )

    if (Test-FullModelId -Model $Model) {
        Add-Check ("{0} uses a full model id" -f $Label)
    } else {
        Add-Failure ("{0} should use a full model id, got [{1}]" -f $Label, $Model)
    }
}

function Assert-FrontmatterFields {
    <#
    .SYNOPSIS
    校验 plan.md frontmatter 字段集合。
    .DESCRIPTION
    老四字段格式继续合法；`tool_profile` 与 `model` 是 opt-in 字段，位置固定在 `tool` 与 `updated` 之间。
    .PARAMETER FieldNames
    frontmatter 字段名。
    .OUTPUTS
    None。
    #>
    param([string[]]$FieldNames)

    $unknownFields = @($FieldNames | Where-Object { $_ -notin $script:AllowedFrontmatterFields })
    $missingRequired = @($script:RequiredFrontmatterFields | Where-Object { $_ -notin $FieldNames })
    $requiredInOrder = @($FieldNames | Where-Object { $_ -in $script:RequiredFrontmatterFields })
    $duplicateOptional = @()
    foreach ($optional in $script:OptionalFrontmatterFields) {
        if (@($FieldNames | Where-Object { $_ -eq $optional }).Count -gt 1) {
            $duplicateOptional += $optional
        }
    }

    if ($unknownFields.Count -gt 0 -or
        $missingRequired.Count -gt 0 -or
        ($requiredInOrder -join '|') -ne ($script:RequiredFrontmatterFields -join '|') -or
        $duplicateOptional.Count -gt 0) {
        Add-Failure ('plan.md frontmatter should only contain task_id/stage/tool/updated plus optional tool_profile/model, got [{0}]' -f ($FieldNames -join ', '))
        return
    }

    $toolIndex = [array]::IndexOf($FieldNames, 'tool')
    $updatedIndex = [array]::IndexOf($FieldNames, 'updated')
    foreach ($optional in $script:OptionalFrontmatterFields) {
        $optionalIndex = [array]::IndexOf($FieldNames, $optional)
        if ($optionalIndex -ge 0 -and ($optionalIndex -le $toolIndex -or $optionalIndex -ge $updatedIndex)) {
            Add-Failure ('plan.md optional frontmatter field {0} should appear between tool and updated' -f $optional)
            return
        }
    }

    if (@($FieldNames | Where-Object { $_ -in $script:OptionalFrontmatterFields }).Count -eq 0) {
        Add-Check "plan.md frontmatter fields are exact"
    } else {
        Add-Check "plan.md frontmatter fields include legal optional profile fields"
    }
}

function Assert-ToolProfileBinding {
    <#
    .SYNOPSIS
    校验 frontmatter tool_profile 与 tool/model 的一致性。
    .PARAMETER Fields
    frontmatter 字段。
    .PARAMETER RepoRoot
    仓库根目录。
    .OUTPUTS
    None。
    #>
    param(
        [System.Collections.Specialized.OrderedDictionary]$Fields,
        [string]$RepoRoot
    )

    $hasProfile = $Fields.Contains('tool_profile') -and -not [string]::IsNullOrWhiteSpace($Fields['tool_profile'])
    $hasModel = $Fields.Contains('model') -and -not [string]::IsNullOrWhiteSpace($Fields['model'])

    if ($hasModel) {
        Assert-FullModelId -Model $Fields['model'] -Label 'plan.md model'
    }

    if (-not $hasProfile) {
        return
    }

    $profile = Get-ToolProfile -RepoRoot $RepoRoot -Name $Fields['tool_profile']
    if ($null -eq $profile) {
        return
    }

    Add-Check ("tool_profile descriptor exists: {0}" -f $profile.Name)

    if ($script:AllowedTools -contains $profile.Backend) {
        Add-Check "tool_profile backend is legal"
    } else {
        Add-Failure ("tool_profile backend should be one of [{0}], got [{1}]" -f ($script:AllowedTools -join ', '), $profile.Backend)
    }

    if ($Fields['tool'] -eq $profile.Backend) {
        Add-Check "plan.md tool matches tool_profile backend"
    } else {
        Add-Failure ("plan.md tool [{0}] should match tool_profile backend [{1}]" -f $Fields['tool'], $profile.Backend)
    }

    Assert-FullModelId -Model $profile.Model -Label ('tool_profile {0} model' -f $profile.Name)
}

function Assert-SectionOrder {
    <#
    .SYNOPSIS
    断言 section 完整且顺序正确。
    .DESCRIPTION
    lite 主线依赖固定 section 名称和顺序；这里只检查当前 guide 里规定的最小集合。
    .PARAMETER Sections
    解析出来的 section 列表。
    .PARAMETER Expected
    预期 section 名称数组。
    .PARAMETER Label
    文档标签。
    .OUTPUTS
    None。
    #>
    param(
        [object[]]$Sections,
        [string[]]$Expected,
        [string]$Label
    )

    $actual = @($Sections | ForEach-Object { $_.Name })
    if (($actual -join '|') -eq ($Expected -join '|')) {
        Add-Check ("{0} sections complete and ordered" -f $Label)
    } else {
        Add-Failure ('{0} sections should be [{1}], got [{2}]' -f $Label, ($Expected -join ' -> '), ($actual -join ' -> '))
    }
}

function Get-SectionContent {
    <#
    .SYNOPSIS
    返回指定 section 正文。
    .DESCRIPTION
    section 不存在时返回空字符串，调用方自行决定这是允许状态还是失败。
    .PARAMETER Sections
    section 列表。
    .PARAMETER Name
    section 名称。
    .OUTPUTS
    String。
    #>
    param(
        [object[]]$Sections,
        [string]$Name
    )

    foreach ($section in $Sections) {
        if ($section.Name -eq $Name) {
            return $section.Content
        }
    }

    return ""
}

function Get-RunBlocks {
    <#
    .SYNOPSIS
    解析 append-only run。
    .DESCRIPTION
    review / implementation sections 都用统一的 `### Run N · YYYY-MM-DD HH:mm · runner: X` 标题。
    .PARAMETER SectionContent
    section 正文。
    .OUTPUTS
    Object[]。
    #>
    param([string]$SectionContent)

    if ([string]::IsNullOrWhiteSpace($SectionContent)) {
        return @()
    }

    $runs = @()
    $matches = [regex]::Matches($SectionContent, '(?ms)^###\s+Run\s+(\d+)\s+·\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+·\s+runner:\s+(.+?)\r?\n(.*?)(?=^###\s+Run\s+\d+|\z)')
    foreach ($match in $matches) {
        $runs += [pscustomobject]@{
            Number = [int]$match.Groups[1].Value
            When = [datetime]::ParseExact($match.Groups[2].Value, 'yyyy-MM-dd HH:mm', $null)
            Runner = $match.Groups[3].Value.Trim()
            Body = $match.Groups[4].Value.Trim()
        }
    }

    return $runs
}

function Assert-RunSequence {
    <#
    .SYNOPSIS
    断言 run 编号连续。
    .DESCRIPTION
    append-only 历史不能跳号也不能回退，否则后续 review / implement 证据无法稳定比较。
    .PARAMETER Runs
    run 列表。
    .PARAMETER Label
    section 标签。
    .OUTPUTS
    None。
    #>
    param(
        [object[]]$Runs,
        [string]$Label
    )

    for ($index = 0; $index -lt $Runs.Count; $index++) {
        if ($Runs[$index].Number -ne ($index + 1)) {
            Add-Failure ("{0} run numbers should start from 1 and increase by 1" -f $Label)
            return
        }
    }

    Add-Check ("{0} run numbering is append-only" -f $Label)
}

function Assert-ReviewRuns {
    <#
    .SYNOPSIS
    校验 Plan Review / Code Review run 格式。
    .DESCRIPTION
    review run 必须包含 `verdict`、`findings`、`next`，并禁止旧式空 severity 标题。
    .PARAMETER SectionContent
    section 正文。
    .PARAMETER Label
    section 标签。
    .OUTPUTS
    Object[]。
    #>
    param(
        [string]$SectionContent,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($SectionContent)) {
        Add-Check ("{0} currently empty" -f $Label)
        return @()
    }

    if ($SectionContent -match '(?m)^###\s+P[0-3]\s*$') {
        Add-Failure ('{0} should not use empty severity headings like ### P1' -f $Label)
    }

    $runs = @(Get-RunBlocks -SectionContent $SectionContent)
    if ($runs.Count -eq 0) {
        Add-Failure ('{0} should use ### Run N · ... headings' -f $Label)
        return @()
    }

    Assert-RunSequence -Runs $runs -Label $Label

    foreach ($run in $runs) {
        $verdictMatch = [regex]::Match($run.Body, '(?m)^- verdict:\s*(pass|revise)\s*$')
        if (-not $verdictMatch.Success) {
            Add-Failure ('{0} Run {1} should contain - verdict: pass | revise' -f $Label, $run.Number)
            continue
        }

        $hasFindingsNone = $run.Body -match '(?m)^- findings:\s*none\s*$'
        $hasFindingsList = $run.Body -match '(?m)^- findings:\s*$' -and $run.Body -match '(?m)^\s+- P[0-3]:\s+.+$'
        if (-not ($hasFindingsNone -or $hasFindingsList)) {
            Add-Failure ('{0} Run {1} should contain - findings: none or a P0-P3 findings list' -f $Label, $run.Number)
        }

        if ($run.Body -notmatch '(?m)^- next:\s+.+$') {
            Add-Failure ('{0} Run {1} should contain - next:' -f $Label, $run.Number)
        }

        if (-not $Quality.IsPresent) {
            continue
        }

        $scores = @{}
        $scoreMatches = 0
        foreach ($dimension in $script:QualityScoreDimensions) {
            $scoreMatch = [regex]::Match($run.Body, ("(?m)^- score\.{0}:\s*(\d+)\s*$" -f [regex]::Escape($dimension)))
            if ($scoreMatch.Success) {
                $scoreMatches += 1
                $scoreValue = [int]$scoreMatch.Groups[1].Value
                if ($scoreValue -lt 0 -or $scoreValue -gt 100) {
                    Add-Failure ('{0} Run {1} score.{2} should be an integer between 0 and 100' -f $Label, $run.Number, $dimension)
                    continue
                }

                $scores[$dimension] = $scoreValue
            }
        }

        if ($scoreMatches -eq 0) {
            Add-Warning ('{0} Run {1} 未录入 4-dim score' -f $Label, $run.Number)
            continue
        }

        if ($scoreMatches -ne $script:QualityScoreDimensions.Count) {
            Add-Failure ('{0} Run {1} should contain all 4 quality scores: {2}' -f $Label, $run.Number, ($script:QualityScoreDimensions -join ', '))
            continue
        }

        $scoreSum = 0
        $hasBlockingDimension = $false
        foreach ($dimension in $script:QualityScoreDimensions) {
            $scoreSum += $scores[$dimension]
            if ($scores[$dimension] -lt 60) {
                $hasBlockingDimension = $true
            }
        }

        $averageScore = [math]::Floor($scoreSum / $script:QualityScoreDimensions.Count)
        $expectedVerdict = if ($hasBlockingDimension) { 'revise' } elseif ($averageScore -ge 80) { 'pass' } else { 'revise' }
        $actualVerdict = $verdictMatch.Groups[1].Value

        if ($actualVerdict -eq $expectedVerdict) {
            Add-Check ('{0} Run {1} verdict matches 4-dim score threshold' -f $Label, $run.Number)
        } else {
            Add-Failure ('{0} Run {1} verdict-score 不一致: verdict [{2}] should be [{3}] (avg={4}; completeness={5}, consistency={6}, accuracy={7}, depth={8})' -f $Label, $run.Number, $actualVerdict, $expectedVerdict, $averageScore, $scores['completeness'], $scores['consistency'], $scores['accuracy'], $scores['depth'])
        }
    }

    return $runs
}

function Assert-ImplementationRuns {
    <#
    .SYNOPSIS
    校验 Implementation Notes run 格式。
    .DESCRIPTION
    当前 lite IMPLEMENT skill 约束 `changed/tests/risks/next` 这 4 个字段。
    .PARAMETER SectionContent
    section 正文。
    .OUTPUTS
    Object[]。
    #>
    param([string]$SectionContent)

    if ([string]::IsNullOrWhiteSpace($SectionContent)) {
        Add-Check "Implementation Notes currently empty"
        return @()
    }

    $runs = @(Get-RunBlocks -SectionContent $SectionContent)
    if ($runs.Count -eq 0) {
        Add-Failure 'Implementation Notes should use ### Run N · ... headings'
        return @()
    }

    Assert-RunSequence -Runs $runs -Label "Implementation Notes"

    foreach ($run in $runs) {
        foreach ($field in @('changed', 'tests', 'risks', 'next')) {
            if ($run.Body -notmatch ("(?m)^- {0}:\s+.+" -f [regex]::Escape($field))) {
                Add-Failure ('Implementation Notes Run {0} should contain - {1}:' -f $run.Number, $field)
            }
        }
    }

    return $runs
}

function Assert-ChangeContract {
    <#
    .SYNOPSIS
    校验可选 Change Contract section。
    .DESCRIPTION
    opt-in 字段：存在时必须满足 change_type 枚举与 affected_paths 至少一条非占位条目。
    占位符 `<path>` 或空白条目视为未填。
    .PARAMETER SectionContent
    Change Contract section 正文。
    .OUTPUTS
    None。
    #>
    param([string]$SectionContent)

    $changeTypeMatch = [regex]::Match($SectionContent, '(?m)^-\s*change_type:\s*(\S+)\s*$')
    if (-not $changeTypeMatch.Success) {
        Add-Failure "Change Contract should contain - change_type: <task|feature|enhance|refactor>"
    } elseif ($script:AllowedChangeTypes -contains $changeTypeMatch.Groups[1].Value) {
        Add-Check "Change Contract change_type is legal"
    } else {
        Add-Failure ("Change Contract change_type should be one of [{0}], got [{1}]" -f ($script:AllowedChangeTypes -join ', '), $changeTypeMatch.Groups[1].Value)
    }

    if ($SectionContent -notmatch '(?m)^-\s*affected_paths:\s*$') {
        Add-Failure "Change Contract should contain - affected_paths: followed by at least one entry"
        return
    }

    $pathEntries = @()
    $lines = @($SectionContent -split "\r?\n")
    $inAffectedPaths = $false
    foreach ($line in $lines) {
        if ($line -match '^-\s*affected_paths:\s*$') {
            $inAffectedPaths = $true
            continue
        }

        if (-not $inAffectedPaths) {
            continue
        }

        if ($line -match '^-\s*.+?:') {
            break
        }

        if ($line -match '^\s{2,}-\s+(.+?)\s*$') {
            $pathEntries += $matches[1].Trim()
        }
    }

    $validEntries = @($pathEntries | Where-Object { $_ -and $_ -ne '<path>' })
    if ($validEntries.Count -ge 1) {
        Add-Check "Change Contract affected_paths has at least one entry"
    } else {
        Add-Failure "Change Contract affected_paths should contain at least one non-placeholder entry"
    }
}

function Assert-PlanContract {
    <#
    .SYNOPSIS
    校验 plan.md。
    .DESCRIPTION
    这里同时覆盖 frontmatter、section 契约，以及和当前 stage 直接相关的文档一致性规则。
    .PARAMETER TaskId
    任务标识。
    .PARAMETER PlanPath
    plan.md 绝对路径。
    .OUTPUTS
    PSCustomObject。
    #>
    param(
        [string]$TaskId,
        [string]$PlanPath,
        [string]$RepoRoot
    )

    $content = Get-Content -LiteralPath $PlanPath -Raw -Encoding utf8
    $frontmatter = Get-Frontmatter -Content $content
    $fields = $frontmatter.Fields

    $fieldNames = @($fields.Keys)
    Assert-FrontmatterFields -FieldNames $fieldNames

    if (($fields['task_id']) -eq $TaskId) {
        Add-Check "plan.md task_id matches task directory"
    } else {
        Add-Failure ('plan.md task_id should be [{0}], got [{1}]' -f $TaskId, $fields['task_id'])
    }

    if ($script:AllowedStages -contains $fields['stage']) {
        Add-Check "plan.md stage is legal"
    } else {
        Add-Failure ('plan.md stage should be one of [{0}], got [{1}]' -f ($script:AllowedStages -join ', '), $fields['stage'])
    }

    if ($fields['stage'] -eq 'DONE') {
        if ($fields['tool'] -eq 'none') {
            Add-Check "plan.md DONE tool is legal"
        } else {
            Add-Failure ('plan.md DONE tool should be [none], got [{0}]' -f $fields['tool'])
        }
    } elseif ($script:AllowedTools -contains $fields['tool']) {
        Add-Check "plan.md tool is legal"
    } else {
        Add-Failure ('plan.md tool should be one of [{0}], got [{1}]' -f ($script:AllowedTools -join ', '), $fields['tool'])
    }

    Assert-ToolProfileBinding -Fields $fields -RepoRoot $RepoRoot

    if (($fields['updated']) -match '^\d{4}-\d{2}-\d{2}$') {
        Add-Check "plan.md updated uses YYYY-MM-DD"
    } else {
        Add-Failure ('plan.md updated should use YYYY-MM-DD, got [{0}]' -f $fields['updated'])
    }

    $sections = Get-Sections -Content $frontmatter.Body
    $requiredSections = @($sections | Where-Object { $_.Name -notin $script:OptionalPlanSections })
    Assert-SectionOrder -Sections $requiredSections -Expected $script:PlanSections -Label "plan.md"

    $sectionNames = @($sections | ForEach-Object { $_.Name })
    $changeContracts = @($sections | Where-Object { $_.Name -eq 'Change Contract' })
    if ($changeContracts.Count -gt 1) {
        Add-Failure "plan.md should contain at most one Change Contract section"
    } elseif ($changeContracts.Count -eq 1) {
        $changeIndex = [array]::IndexOf($sectionNames, 'Change Contract')
        $confirmationIndex = [array]::IndexOf($sectionNames, 'User Confirmation')
        $planIndex = [array]::IndexOf($sectionNames, 'Plan')
        if ($changeIndex -eq ($confirmationIndex + 1) -and $planIndex -eq ($changeIndex + 1)) {
            Add-Check "Change Contract section is positioned between User Confirmation and Plan"
        } else {
            Add-Failure "Change Contract should appear between User Confirmation and Plan"
        }

        $changeContract = $changeContracts[0]
        Assert-ChangeContract -SectionContent $changeContract.Content
    }

    $clarification = Get-SectionContent -Sections $sections -Name 'Clarification'
    foreach ($needle in @('验收标准', '非目标', '受影响目录', '回滚', 'ui:')) {
        if ($clarification -match [regex]::Escape($needle)) {
            Add-Check ('Clarification contains [{0}]' -f $needle)
        } else {
            Add-Failure ('Clarification should contain [{0}]' -f $needle)
        }
    }

    $confirmation = Get-SectionContent -Sections $sections -Name 'User Confirmation'
    if ($confirmation -match '(?m)^- status:\s*(draft|confirmed)\s*$') {
        Add-Check "User Confirmation status is machine-readable"
    } else {
        Add-Failure 'User Confirmation should contain - status: draft | confirmed'
    }

    $planBody = Get-SectionContent -Sections $sections -Name 'Plan'
    $planMetadata = Get-TopLevelPlanBullets -Content $planBody
    if ($planMetadata.OrdinaryBullets.Count -gt 0) {
        Add-Check "Plan contains actionable bullets"
    } else {
        Add-Failure "Plan should contain at least one ordinary bullet"
    }

    $verification = Get-SectionContent -Sections $sections -Name 'Verification'
    if ($verification -match '(?m)^- `.+`$') {
        Add-Check "Verification contains executable commands"
    } else {
        Add-Failure "Verification should contain backticked commands"
    }

    $risks = Get-SectionContent -Sections $sections -Name 'Risks'
    if (-not [string]::IsNullOrWhiteSpace($risks)) {
        Add-Check "Risks section is not empty"
    } else {
        Add-Failure "Risks section should not be empty"
    }

    $planReviewRuns = @(Assert-ReviewRuns -SectionContent (Get-SectionContent -Sections $sections -Name 'Plan Review') -Label 'Plan Review')
    $implementationRuns = @(Assert-ImplementationRuns -SectionContent (Get-SectionContent -Sections $sections -Name 'Implementation Notes'))
    $codeReviewRuns = @(Assert-ReviewRuns -SectionContent (Get-SectionContent -Sections $sections -Name 'Code Review') -Label 'Code Review')

    if ($fields['stage'] -eq 'IMPLEMENT' -and $codeReviewRuns.Count -gt 0) {
        $latestCodeReview = $codeReviewRuns[-1]
        if ($latestCodeReview.Body -match '(?m)^- verdict:\s*revise\s*$') {
            if ($implementationRuns.Count -eq 0 -or $implementationRuns[-1].When -le $latestCodeReview.When) {
                Add-Failure "IMPLEMENT after CODE_REVIEW revise requires a fresh Implementation Notes run"
            } else {
                Add-Check "IMPLEMENT has fresh evidence after latest revise"
            }
        }
    }

    [pscustomobject]@{
        Stage = $fields['stage']
    }
}

function Assert-SpecContract {
    <#
    .SYNOPSIS
    校验可选 spec.md。
    .DESCRIPTION
    spec 只是 PLAN 的补充附件，因此只检查固定 section 骨架，不引入额外状态语义。
    .PARAMETER SpecPath
    spec.md 绝对路径。
    .OUTPUTS
    None。
    #>
    param([string]$SpecPath)

    $content = Get-Content -LiteralPath $SpecPath -Raw -Encoding utf8
    $sections = Get-Sections -Content $content
    Assert-SectionOrder -Sections $sections -Expected $script:SpecSections -Label "spec.md"
}

function Assert-TestContract {
    <#
    .SYNOPSIS
    校验 test.md。
    .DESCRIPTION
    TEST / DONE 都依赖这份文档，因此这里检查 section、结论字面量和 handoff 字段。
    .PARAMETER TestPath
    test.md 绝对路径。
    .PARAMETER CurrentStage
    当前 stage，用于补充 DONE 的额外约束。
    .OUTPUTS
    None。
    #>
    param(
        [string]$TestPath,
        [string]$CurrentStage
    )

    $content = Get-Content -LiteralPath $TestPath -Raw -Encoding utf8
    $sections = Get-Sections -Content $content
    Assert-SectionOrder -Sections $sections -Expected $script:TestSections -Label "test.md"

    $conclusion = Get-SectionContent -Sections $sections -Name 'Conclusion'
    $lines = @($conclusion -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt 0 -and ($lines[0] -in @('pass', 'fail', 'blocked'))) {
        Add-Check "test.md Conclusion is legal"
    } else {
        Add-Failure "test.md Conclusion first line should be pass | fail | blocked"
    }

    $handoff = Get-SectionContent -Sections $sections -Name 'Handoff'
    if ($handoff -match '(?m)^- delivery:\s+.+$' -and $handoff -match '(?m)^- follow_up:\s+.+$') {
        Add-Check "test.md Handoff contains delivery and follow_up"
    } else {
        Add-Failure 'test.md Handoff should contain - delivery: and - follow_up:'
    }

    if ($CurrentStage -eq 'DONE') {
        if ($lines.Count -gt 0 -and $lines[0] -eq 'pass') {
            Add-Check "DONE stage is backed by passing test result"
        } else {
            Add-Failure "DONE stage requires test.md Conclusion to be pass"
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$script:Checks = @()
$script:Failures = @()
$script:Warnings = @()
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$taskRoot = Join-Path (Join-Path $RepoRoot 'docs\tasks') $TaskId
$planPath = Join-Path $taskRoot 'plan.md'
$specPath = Join-Path $taskRoot 'spec.md'
$testPath = Join-Path $taskRoot 'test.md'

if (Test-Path -LiteralPath $taskRoot -PathType Container) {
    Add-Check ("task directory exists: docs/tasks/{0}" -f $TaskId)
} else {
    Add-Failure ("task directory should exist: docs/tasks/{0}" -f $TaskId)
}

if (Test-Path -LiteralPath $planPath -PathType Leaf) {
    Add-Check "plan.md exists"
    $planState = Assert-PlanContract -TaskId $TaskId -PlanPath $planPath -RepoRoot $RepoRoot

    if (Test-Path -LiteralPath $specPath -PathType Leaf) {
        Add-Check "spec.md exists"
        Assert-SpecContract -SpecPath $specPath
    }

    if ($planState.Stage -in @('TEST', 'DONE')) {
        if (Test-Path -LiteralPath $testPath -PathType Leaf) {
            Add-Check "test.md exists for TEST/DONE"
            Assert-TestContract -TestPath $testPath -CurrentStage $planState.Stage
        } else {
            Add-Failure "TEST/DONE requires docs/tasks/<task-id>/test.md"
        }
    } elseif (Test-Path -LiteralPath $testPath -PathType Leaf) {
        Add-Check "test.md exists"
        Assert-TestContract -TestPath $testPath -CurrentStage $planState.Stage
    }
} else {
    Add-Failure "plan.md should exist"
}

Assert-WorkflowDescriptorAdvisory -RepoRoot $RepoRoot

if ($script:Failures.Count -gt 0) {
    Write-Output 'STATUS: FAIL'
} else {
    Write-Output 'STATUS: PASS'
}
Write-Output ("TaskId: {0}" -f $TaskId)
Write-Output ("TaskRoot: {0}" -f $taskRoot)
Write-Output ''
Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ("- {0}" -f $item)
    }
}
Write-Output ''
Write-Output 'Errors:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Failures) {
        Write-Output ("- {0}" -f $item)
    }
}
Write-Output ''
Write-Output 'Warnings:'
if ($script:Warnings.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Warnings) {
        Write-Output ("- {0}" -f $item)
    }
}

if ($script:Failures.Count -gt 0) {
    exit 2
}

exit 0
