# 校验纯净 harness-lite 的仓库边界。
# 重点覆盖 skills 白名单、历史脚本缺席、共享模板路径和 runtime 噪音忽略规则。
[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Check {
    <#
    .SYNOPSIS
    记录通过项。
    .DESCRIPTION
    测试结束时统一输出，便于确认 lite footprint 是否仍然纯净。
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
    记录失败项。
    .DESCRIPTION
    失败项会在脚本末尾集中输出并让测试返回非零退出码。
    .PARAMETER Message
    失败说明。
    .OUTPUTS
    None。
    #>
    param([string]$Message)

    $script:Failures += $Message
}

function Assert-PathAbsent {
    <#
    .SYNOPSIS
    断言仓库中不存在指定历史路径。
    .DESCRIPTION
    这些路径属于已抛弃的 legacy 资产，重新出现就说明 lite footprint 被污染。
    .PARAMETER Path
    相对仓库根目录的路径。
    .OUTPUTS
    None。
    #>
    param([string]$Path)

    $fullPath = Join-Path $script:RepoRoot $Path
    if (Test-Path -LiteralPath $fullPath) {
        Add-Failure ("legacy path should be absent: {0}" -f $Path)
    } else {
        Add-Check ("legacy path absent: {0}" -f $Path)
    }
}

function Assert-FileContains {
    <#
    .SYNOPSIS
    断言文件包含指定文本。
    .DESCRIPTION
    用于锁定共享模板和 ignore 规则的最小契约。
    .PARAMETER Path
    相对仓库根目录的文件路径。
    .PARAMETER Needle
    必须存在的文本。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [string]$Needle
    )

    $fullPath = Join-Path $script:RepoRoot $Path
    $content = Get-Content -LiteralPath $fullPath -Raw -Encoding utf8
    if ($content.Contains($Needle)) {
        Add-Check ('{0} contains `{1}`' -f $Path, $Needle)
    } else {
        Add-Failure ('{0} should contain `{1}`' -f $Path, $Needle)
    }
}

function Assert-FileNotContains {
    <#
    .SYNOPSIS
    断言文件不包含指定文本。
    .DESCRIPTION
    用于锁定已抛弃的 legacy 片段，避免 lite 主线再次回退到旧契约。
    .PARAMETER Path
    相对仓库根目录的文件路径。
    .PARAMETER Needle
    必须不存在的文本。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [string]$Needle
    )

    $fullPath = Join-Path $script:RepoRoot $Path
    $content = Get-Content -LiteralPath $fullPath -Raw -Encoding utf8
    if ($content.Contains($Needle)) {
        Add-Failure ('{0} should not contain `{1}`' -f $Path, $Needle)
    } else {
        Add-Check ('{0} does not contain `{1}`' -f $Path, $Needle)
    }
}

function Remove-LinkTargets {
    param([string]$Content)

    $withoutMarkdownTargets = [regex]::Replace($Content, '\]\([^)]+\)', ']()')
    return [regex]::Replace($withoutMarkdownTargets, 'https?://\S+', '')
}

function Assert-DirectoryVisibleTextNotContains {
    <#
    .SYNOPSIS
    断言目录中文件的可见文本不包含指定文本。
    .DESCRIPTION
    用于锁定 active 模板目录级 legacy 文案；Markdown 链接 URL target 会被忽略，
    避免把保留的历史 URL 当作可见品牌回归。
    .PARAMETER Path
    相对仓库根目录的目录路径。
    .PARAMETER Needle
    必须不存在的可见文本。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [string]$Needle
    )

    $fullPath = Join-Path $script:RepoRoot $Path
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $fullPath -Recurse -File) {
        $relativePath = $file.FullName.Substring($script:RepoRoot.Length).TrimStart('\') -replace '\\', '/'
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        $visibleContent = Remove-LinkTargets -Content $content
        if ($visibleContent.Contains($Needle)) {
            [void]$hits.Add($relativePath)
        }
    }

    if ($hits.Count -gt 0) {
        Add-Failure ('{0} visible text should not contain `{1}`; hits: {2}' -f $Path, $Needle, ($hits -join ', '))
    } else {
        Add-Check ('{0} visible text does not contain `{1}`' -f $Path, $Needle)
    }
}

function Assert-Utf8Bom {
    <#
    .SYNOPSIS
    断言 PowerShell 文件带有 UTF-8 BOM。
    .DESCRIPTION
    这个仓库以 Windows PowerShell 为安装与验证主路径，保留脚本都必须显式写 BOM 才能稳定解析中文内容。
    .PARAMETER Path
    相对仓库根目录的文件路径。
    .OUTPUTS
    None。
    #>
    param([string]$Path)

    $fullPath = Join-Path $script:RepoRoot $Path
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($hasBom) {
        Add-Check ('{0} uses UTF-8 BOM' -f $Path)
    } else {
        Add-Failure ('{0} should use UTF-8 BOM for Windows PowerShell compatibility' -f $Path)
    }
}

function Assert-GitIgnoreState {
    <#
    .SYNOPSIS
    断言路径当前是否被 `.gitignore` 命中。
    .DESCRIPTION
    Phase 6 需要锁定 wisdom 文件被放行、其余 `运行时/` 文件继续 ignore 的实际行为，
    不能只锁 `.gitignore` 文本。
    .PARAMETER Path
    相对仓库根目录的路径。
    .PARAMETER ShouldBeIgnored
    期望是否被 ignore。
    .OUTPUTS
    None。
    #>
    param(
        [string]$Path,
        [bool]$ShouldBeIgnored
    )

    $fullPath = Join-Path $script:RepoRoot $Path
    & git -C $script:RepoRoot check-ignore -q -- $fullPath
    $isIgnored = ($LASTEXITCODE -eq 0)

    if ($isIgnored -eq $ShouldBeIgnored) {
        $label = if ($ShouldBeIgnored) { 'is ignored' } else { 'is reviewable' }
        Add-Check ('git ignore behavior ok: {0} {1}' -f $Path, $label)
    } else {
        $expected = if ($ShouldBeIgnored) { 'ignored' } else { 'reviewable' }
        Add-Failure ('git ignore behavior drifted: {0} should be {1}' -f $Path, $expected)
    }
}

function Get-RepoRelativePath {
    <#
    .SYNOPSIS
    计算仓库相对路径。
    .DESCRIPTION
    Windows PowerShell 没有 `System.IO.Path.GetRelativePath`，这里用 URI 方式生成兼容的相对路径。
    .PARAMETER TargetPath
    要转换的绝对路径。
    .OUTPUTS
    System.String。
    #>
    param([string]$TargetPath)

    $baseUri = New-Object System.Uri(($script:RepoRoot.TrimEnd('\') + '\'))
    $targetUri = New-Object System.Uri($TargetPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', '\')
}

function Assert-UsingSuperpowersRemovedFromActiveSurface {
    <#
    .SYNOPSIS
    锁定活跃入口面不再引用 using-superpowers。
    .DESCRIPTION
    旧 alias 目录移除后，旧名只能留在历史 docs/tasks 记录或测试回归锁点；
    入口、配置、脚本、skill 与模板不应再引用它。
    .OUTPUTS
    None。
    #>

    $searchPaths = @(
        'README.md',
        'agent-configs',
        'scripts',
        'skills',
        'vault-template',
        'docs/aionui-integration',
        'docs/team-write-authority.md',
        'docs/shared-memory-layers.md',
        'docs/工作流'
    )
    $grepArgs = @('-C', $script:RepoRoot, 'grep', '-n', 'using-superpowers', '--') + $searchPaths
    $grepMatches = @(& git @grepArgs 2>$null | ForEach-Object { [string]$_ })

    if ($grepMatches.Count -eq 0) {
        Add-Check 'active path grep has no using-superpowers references'
    } else {
        Add-Failure ("using-superpowers leaked into active surface: {0}" -f ($grepMatches -join ' | '))
    }
}

function Assert-GeminiDesignerRemovedFromActiveSurface {
    <#
    .SYNOPSIS
    锁定活跃入口面不再引用旧 Gemini designer 命名。
    .DESCRIPTION
    迁移到 test-runner 后，旧名只能留在历史 docs/tasks 记录或测试回归锁点；
    入口、配置、脚本、skill 与模板不应再引用它。
    .OUTPUTS
    None。
    #>

    $searchPaths = @(
        'README.md',
        'agent-configs',
        'scripts',
        'skills',
        'vault-template',
        'docs/aionui-integration',
        'docs/team-write-authority.md',
        'docs/shared-memory-layers.md',
        'docs/工作流'
    )
    $grepArgs = @('-C', $script:RepoRoot, 'grep', '-n', 'gemini-designer', '--') + $searchPaths
    $grepMatches = @(& git @grepArgs 2>$null | ForEach-Object { [string]$_ })

    if ($grepMatches.Count -eq 0) {
        Add-Check 'active path grep has no gemini-designer references'
    } else {
        Add-Failure ("gemini-designer leaked into active surface: {0}" -f ($grepMatches -join ' | '))
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$script:RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$script:Checks = @()
$script:Failures = @()

$expectedSkills = @(
    'codex',
    'entry-router',
    'implement',
    'md-html',
    'obsidian-memory',
    'orchestrator',
    'plan',
    'review',
    'spec',
    'test',
    'workflow-team'
)

$actualSkills = Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'skills') -Directory |
    Where-Object { $_.Name -ne '.system' } |
    Select-Object -ExpandProperty Name |
    Sort-Object

if ((@($actualSkills) -join '|') -eq (($expectedSkills | Sort-Object) -join '|')) {
    Add-Check 'skills 白名单与 harness-lite 预期一致'
} else {
    Add-Failure ("unexpected skills set: {0}" -f (@($actualSkills) -join ', '))
}

foreach ($legacyPath in @(
    'agent-configs/workspace/entry',
    'skills/docs',
    'docs/工作流/skill-phase-loading.md',
    'scripts/advance-orchestrator-stage.ps1',
    'scripts/validate-harness-artifacts.ps1',
    'scripts/migrate-task-artifacts.ps1',
    'vault-template/.obsidian/workspace.json'
)) {
    Assert-PathAbsent -Path $legacyPath
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'skills/orchestrator/references/lite-writing-guide.md') -PathType Leaf) {
    Add-Check 'lite writing guide exists'
} else {
    Add-Failure 'lite writing guide should exist at skills/orchestrator/references/lite-writing-guide.md'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'scripts/validate-lite-artifacts.ps1') -PathType Leaf) {
    Add-Check 'lite artifact validator exists'
} else {
    Add-Failure 'lite artifact validator should exist at scripts/validate-lite-artifacts.ps1'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'scripts/run-validation.ps1') -PathType Leaf) {
    Add-Check 'quiet validation runner exists'
} else {
    Add-Failure 'quiet validation runner should exist at scripts/run-validation.ps1'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'skills/workflow-team/SKILL.md') -PathType Leaf) {
    Add-Check 'workflow-team skill exists'
} else {
    Add-Failure 'workflow-team skill should exist at skills/workflow-team/SKILL.md'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'scripts/export-team-preset.ps1') -PathType Leaf) {
    Add-Check 'team preset export script exists'
} else {
    Add-Failure 'team preset export script should exist at scripts/export-team-preset.ps1'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'agent-configs/role-prompts/plan-author.md') -PathType Leaf) {
    Add-Check 'role prompt templates exist'
} else {
    Add-Failure 'role prompt templates should exist at agent-configs/role-prompts/'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'docs/team-write-authority.md') -PathType Leaf) {
    Add-Check 'team write authority doc exists'
} else {
    Add-Failure 'team write authority doc should exist at docs/team-write-authority.md'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'docs/shared-memory-layers.md') -PathType Leaf) {
    Add-Check 'shared memory layers doc exists'
} else {
    Add-Failure 'shared memory layers doc should exist at docs/shared-memory-layers.md'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'docs/工作流/single-writer-precompact.md') -PathType Leaf) {
    Add-Check 'single-writer precompact doc exists'
} else {
    Add-Failure 'single-writer precompact doc should exist at docs/工作流/single-writer-precompact.md'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'scripts/check-shared-memory-layers.ps1') -PathType Leaf) {
    Add-Check 'shared memory layers checker exists'
} else {
    Add-Failure 'shared memory layers checker should exist at scripts/check-shared-memory-layers.ps1'
}

if (Test-Path -LiteralPath (Join-Path $script:RepoRoot 'tests/verify-shared-memory-layers.ps1') -PathType Leaf) {
    Add-Check 'shared memory layers regression exists'
} else {
    Add-Failure 'shared memory layers regression should exist at tests/verify-shared-memory-layers.ps1'
}

Assert-FileContains -Path '.gitignore' -Needle '.assistant/'
Assert-FileContains -Path '.gitignore' -Needle '!.assistant/运行时/'
Assert-FileContains -Path '.gitignore' -Needle '.assistant/运行时/*'
Assert-FileContains -Path '.gitignore' -Needle '!.assistant/运行时/记忆-学习.md'
Assert-FileContains -Path '.gitignore' -Needle '!.assistant/运行时/记忆-决策.md'
Assert-FileContains -Path '.gitignore' -Needle '!.assistant/运行时/记忆-约定.md'
Assert-FileContains -Path '.gitignore' -Needle '!.assistant/运行时/记忆-问题.md'
Assert-FileContains -Path '.gitignore' -Needle 'skills/*/.runtime/'
Assert-FileContains -Path '.gitignore' -Needle 'agent-configs/workspace/entry/'
Assert-FileContains -Path '.gitignore' -Needle '/.codex/'
Assert-FileContains -Path 'docs/shared-memory-layers.md' -Needle '## Layers'
Assert-FileContains -Path 'docs/shared-memory-layers.md' -Needle '## Writeback Ladder'
Assert-FileContains -Path 'docs/shared-memory-layers.md' -Needle '## Forbidden Reverse Edges'
Assert-FileContains -Path 'vault-template/工作流/共享记忆协议.md' -Needle 'docs/tasks/<task-id>/*'
Assert-FileContains -Path 'vault-template/工作流/共享记忆协议.md' -Needle 'docs/shared-memory-layers.md'
Assert-FileContains -Path 'vault-template/工作流/共享记忆协议.md' -Needle '{REPO_ROOT}\docs\shared-memory-layers.md'
Assert-FileContains -Path 'vault-template/工作流/写回协议.md' -Needle 'docs/tasks/<task-id>/*'
Assert-FileContains -Path 'vault-template/工作流/写回协议.md' -Needle 'docs/shared-memory-layers.md'
Assert-FileContains -Path 'vault-template/配置/敏感信息规范.md' -Needle 'docs/tasks/**'
Assert-FileContains -Path 'README.md' -Needle 'skills/orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'README.md' -Needle 'scripts/validate-lite-artifacts.ps1'
Assert-FileContains -Path 'README.md' -Needle 'scripts/run-validation.ps1'
Assert-FileContains -Path 'README.md' -Needle '-NoProfile -NonInteractive -File .\scripts\run-validation.ps1'
Assert-FileContains -Path 'README.md' -Needle 'quiet validation'
Assert-FileContains -Path 'README.md' -Needle 'export-team-preset.ps1'
Assert-FileContains -Path 'README.md' -Needle 'AIONUI_TEAM_MODE'
Assert-FileContains -Path 'README.md' -Needle '.assistant\entry\advance-stage.ps1'
Assert-FileContains -Path 'README.md' -Needle '.assistant\entry\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'README.md' -Needle 'tool: claudecode | codex | none'
Assert-FileContains -Path 'README.md' -Needle 'tool_profile'
Assert-FileContains -Path 'README.md' -Needle 'mode: quick | workflow | ask'
Assert-FileContains -Path 'README.md' -Needle '自动懒加载规则'
Assert-FileContains -Path 'README.md' -Needle '禁止 bulk-load 全部 skills'
Assert-FileContains -Path 'README.md' -Needle 'md-html'
Assert-FileContains -Path 'README.md' -Needle 'Markdown 默认是人类和 AI 共同编辑的 canonical source / source of truth'
Assert-FileContains -Path 'README.md' -Needle 'HTML 默认是 generated display artifact'
Assert-FileContains -Path 'README.md' -Needle '超过 160 行或含 8 个及以上 `##` 二级标题'
Assert-FileContains -Path 'README.md' -Needle 'paired reading HTML'
Assert-FileContains -Path 'README.md' -Needle '不替代 Markdown'
Assert-FileContains -Path 'README.md' -Needle '主动重组 summary、decision、risk、checkpoint'
Assert-FileContains -Path 'README.md' -Needle 'scripts\render-review-html.ps1'
Assert-FileContains -Path 'README.md' -Needle '默认不含 `doctype`、`html`、`head`、`body` 外壳'
Assert-FileContains -Path 'README.md' -Needle '局部 HTML 增强只允许用于卡片、对比区、流程区、信息网格'
Assert-FileContains -Path 'README.md' -Needle '不得使用 `script`、`iframe` 或外部 JS'
Assert-FileContains -Path 'README.md' -Needle '完整 HTML 页面只有用户明确要求时才生成'
Assert-FileContains -Path 'README.md' -Needle 'resume-current'
Assert-FileContains -Path 'README.md' -Needle '直接改'
Assert-FileContains -Path 'README.md' -Needle '走 workflow'
Assert-FileContains -Path 'skills/workflow-team/SKILL.md' -Needle '.assistant/'
Assert-FileContains -Path 'skills/workflow-team/SKILL.md' -Needle 'docs/tasks/<task-id>/'
Assert-FileContains -Path 'scripts/advance-stage.ps1' -Needle 'validate-lite-artifacts.ps1'
Assert-FileContains -Path 'scripts/advance-stage.ps1' -Needle '[writeback-fallback]'
Assert-FileContains -Path 'scripts/export-team-preset.ps1' -Needle 'members_read_only_path_prefixes'
Assert-FileContains -Path 'scripts/check-shared-memory-layers.ps1' -Needle 'derived_from'
Assert-FileContains -Path 'tests/verify-shared-memory-layers.ps1' -Needle 'runtime.lock.json'
Assert-FileContains -Path 'scripts/advance-stage.ps1' -Needle '[string]$Tool = ""'
Assert-FileContains -Path 'scripts/advance-stage.ps1' -Needle '[string]$Profile = ""'
Assert-FileContains -Path 'scripts/run-validation.ps1' -Needle 'CreateNoWindow = $true'
Assert-FileContains -Path 'scripts/run-validation.ps1' -Needle "ValidateSet('quick', 'core', 'all')"
Assert-FileContains -Path 'scripts/run-validation.ps1' -Needle '-NoProfile -NonInteractive -ExecutionPolicy Bypass'
Assert-FileContains -Path 'scripts/run-validation.ps1' -Needle 'verify-md-html-review-renderer.ps1'
Assert-FileContains -Path 'scripts/render-review-html.ps1' -Needle 'data-visual-block="summary"'
Assert-FileContains -Path 'scripts/render-review-html.ps1' -Needle 'data-visual-block="decision-grid"'
Assert-FileContains -Path 'scripts/render-review-html.ps1' -Needle 'data-visual-block="risk-grid"'
Assert-FileContains -Path 'scripts/render-review-html.ps1' -Needle 'data-visual-block="checkpoints"'
Assert-FileContains -Path 'tests/verify-md-html-review-renderer.ps1' -Needle 'output stays an HTML fragment'
Assert-FileContains -Path 'tests/verify-aionui-skill-contract.ps1' -Needle '-WindowStyle Hidden'
Assert-FileContains -Path 'tests/verify-skill-manifest.ps1' -Needle '-WindowStyle Hidden'
Assert-FileContains -Path 'tests/verify-workflow-descriptor.ps1' -Needle '-WindowStyle Hidden'
Assert-FileContains -Path 'tests/verify-team-orchestration.ps1' -Needle '-WindowStyle Hidden'
Assert-FileContains -Path 'tests/verify-team-preset.ps1' -Needle '-WindowStyle Hidden'
Assert-FileContains -Path 'scripts/validate-lite-artifacts.ps1' -Needle 'tool_profile'
Assert-FileContains -Path 'scripts/validate-lite-artifacts.ps1' -Needle '[switch]$Quality'
Assert-FileContains -Path 'scripts/validate-lite-artifacts.ps1' -Needle 'artifacts'
Assert-FileContains -Path 'agent-configs/profiles/harness-default-claude.yaml' -Needle 'backend: claudecode'
Assert-FileContains -Path 'agent-configs/profiles/harness-default-codex.yaml' -Needle 'backend: codex'
Assert-FileContains -Path 'agent-configs/profiles/harness-default-codex.yaml' -Needle '  - entry-router'
Assert-FileContains -Path 'agent-configs/profiles/harness-default-claude.yaml' -Needle '  - entry-router'
Assert-FileContains -Path 'agent-configs/profiles/harness-default-codex.yaml' -Needle '  - md-html'
Assert-FileContains -Path 'agent-configs/profiles/harness-default-claude.yaml' -Needle '  - md-html'
Assert-FileContains -Path 'agent-configs/workflows/harness-lite.yaml' -Needle 'default_profile: harness-default-codex'
Assert-FileContains -Path 'agent-configs/workflows/harness-lite.yaml' -Needle 'skills_whitelist: [plan, entry-router]'
Assert-FileNotContains -Path 'agent-configs/workflows/harness-lite.yaml' -Needle 'skills_whitelist: [plan, using-superpowers]'
Assert-FileContains -Path 'agent-configs/workflows/harness-lite.yaml' -Needle 'skills_whitelist: [test]'
Assert-FileContains -Path 'agent-configs/role-prompts/plan-author.md' -Needle 'Allowed skills: plan, entry-router'
Assert-FileContains -Path 'agent-configs/role-prompts/tester.md' -Needle 'Allowed skills: test'
Assert-FileNotContains -Path 'agent-configs/role-prompts/tester.md' -Needle 'Allowed skills: test, test-runner'
Assert-FileContains -Path 'skills/spec/SKILL.md' -Needle '../orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/plan/SKILL.md' -Needle '../orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/review/SKILL.md' -Needle '../orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/review/SKILL.md' -Needle 'quality-rubric.md'
Assert-FileContains -Path 'skills/test/SKILL.md' -Needle '../orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/plan/SKILL.md' -Needle 'read_first'
Assert-FileContains -Path 'skills/plan/SKILL.md' -Needle 'convergence'
Assert-FileContains -Path 'skills/plan/SKILL.md' -Needle 'artifacts:'
Assert-FileContains -Path 'skills/review/SKILL.md' -Needle 'read_first'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'read_first'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'convergence'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'artifacts:'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'SKILL.md 拆分守则'
Assert-FileContains -Path 'skills/plan/SKILL.md' -Needle '.assistant\entry\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'skills/implement/SKILL.md' -Needle '.assistant\entry\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'skills/review/SKILL.md' -Needle '.assistant\entry\advance-stage.ps1'
Assert-FileContains -Path 'skills/plan/SKILL.md' -Needle '不作为 Codex-only 默认流程的必需依赖'
Assert-FileContains -Path 'skills/implement/SKILL.md' -Needle '不作为 Codex-only 默认流程的必需依赖'
Assert-FileContains -Path 'skills/review/SKILL.md' -Needle '不作为 Codex-only 默认流程的必需依赖'
Assert-FileNotContains -Path 'skills/plan/SKILL.md' -Needle '适用：`claudecode`'
Assert-FileNotContains -Path 'skills/implement/SKILL.md' -Needle '适用：`claudecode`'
Assert-FileNotContains -Path 'skills/review/SKILL.md' -Needle '适用：`claudecode`'
Assert-FileContains -Path 'skills/test/SKILL.md' -Needle '.assistant\entry\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle '.assistant\entry\advance-stage.ps1'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle 'spawn-team.ps1'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle 'name: entry-router'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle '.assistant\entry\advance-stage.ps1'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle 'mode: quick | workflow | ask'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle 'quick`：只加载入口规则'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle '禁止 bulk-load 全部 skills'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle 'md-html'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle 'Markdown 默认是 source of truth'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle 'HTML 是 generated artifact'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle '超过 160 行或含 8 个及以上 `##` 二级标题'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle 'fixed template 生成 paired reading HTML'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle '局部 HTML 增强只限卡片、对比区、流程区、信息网格'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle '不使用 `script`、`iframe` 或外部 JS'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle '直接改'
Assert-FileContains -Path 'skills/entry-router/SKILL.md' -Needle '走 workflow'
Assert-PathAbsent -Path 'skills/using-superpowers'
Assert-PathAbsent -Path ('skills/' + 'gemini-designer' + '-main')
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'name: md-html'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'Markdown 是人类和 AI 共同编辑的 canonical source / source of truth'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'HTML 是 generated display artifact'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle '默认不允许同一轮同时自由编辑 Markdown 和 HTML'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle '超过 160 行或含 8 个及以上二级标题'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'Markdown-only'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'Paired reading HTML'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'Local HTML enhancement'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'plan.review.html'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'spec.review.html'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'HTML 阅读版是派生产物，不替代 Markdown'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'summary、decision、risk、checkpoint'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle 'scripts/render-review-html.ps1'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle '默认产物是自包含 HTML fragment + inline CSS'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle '完整 HTML 页面只有用户明确要求时才生成'
Assert-FileContains -Path 'skills/md-html/SKILL.md' -Needle '禁止 `script`、`iframe`、外部 JS'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle 'P0 Gate'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle 'P1 Gate'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle 'Markdown-only'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle 'Paired reading HTML'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle 'Local HTML enhancement'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle '未超过 160 行且少于 8 个 `##` 二级标题'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle '不把 HTML 放进代码块'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle '禁止 `script`、`iframe`、外部 JS'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle 'scripts/render-review-html.ps1'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle '退化为普通 Markdown 渲染'
Assert-FileContains -Path 'skills/md-html/references/checklist.md' -Needle 'tests/verify-md-html-review-renderer.ps1'
Assert-FileContains -Path 'tests/verify-md-html-review-renderer.ps1' -Needle 'output stays an HTML fragment'
Assert-FileContains -Path 'scripts/render-review-html.ps1' -Needle 'Generated paired reading HTML fragment'
Assert-FileContains -Path 'scripts/render-review-html.ps1' -Needle 'table-scroll'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle 'markitdown'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle '仓库不因此新增 runtime 依赖'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle '模式矩阵'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle 'fixed reading template'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle 'HTML 阅读版是派生产物'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle '结构重组后的 fragment'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle '`doctype`、`html`、`head`、`body`'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle 'Local HTML enhancement 模式不输出 `html` / `head` / `body` 外壳'
Assert-FileContains -Path 'skills/md-html/references/pipeline.md' -Needle '`script`、`iframe`、外部 JS'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'new-task mode=workflow'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle '按当前 stage 懒加载'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'md-html'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle '不新增 stage，也不进入默认 stage whitelist'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle '超过 160 行或 8 个二级标题'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'fixed template paired reading HTML'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'workflow-team` 仅在 `$env:AIONUI_TEAM_MODE=''1''`'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle 'mode: quick | workflow | ask'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle 'Lazy Loading'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle 'md-html'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle '不改变默认 PLAN/IMPLEMENT/REVIEW/TEST stage'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle '长 `spec.md` / `plan.md` 超过 160 行或 8 个二级标题'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle '默认声明 paired reading HTML artifact'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'new-task mode=workflow'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'Markdown / HTML artifact source boundary'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'Markdown 默认是 source of truth'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'HTML 默认是 generated display artifact'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle '超过 160 行或含 8 个及以上 `##` 二级标题'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'paired reading HTML 使用固定模板'
Assert-FileContains -Path 'skills/orchestrator/references/lite-writing-guide.md' -Needle 'Local HTML enhancement 只限局部卡片、对比区、流程区、信息网格'
Assert-FileContains -Path 'skills/orchestrator/references/gates.md' -Needle 'new-task mode=workflow'
Assert-FileContains -Path 'vault-template/工作流/任务识别协议.md' -Needle 'quick | workflow | ask'
Assert-FileContains -Path 'vault-template/工作流/任务识别协议.md' -Needle '自动懒加载规则'
Assert-FileContains -Path 'vault-template/工作流/恢复协议.md' -Needle 'Resume 懒加载'
Assert-FileContains -Path 'vault-template/工作流/任务识别协议.md' -Needle '直接改'
Assert-FileContains -Path 'vault-template/工作流/任务识别协议.md' -Needle '走 workflow'
Assert-FileContains -Path 'vault-template/工作流/写回协议.md' -Needle 'mode: quick | workflow | ask'
Assert-FileContains -Path '.assistant/工作流/长会话恢复.md' -Needle 'mode: quick | workflow | ask'
Assert-FileContains -Path '.assistant/工作流/长会话恢复.md' -Needle 'Resume 懒加载'
Assert-FileContains -Path 'vault-template/entry/AGENTS.md.template' -Needle 'mode: quick | workflow | ask'
Assert-FileContains -Path 'vault-template/entry/AGENTS.md.template' -Needle 'Lazy loading:'
Assert-FileContains -Path 'vault-template/entry/AGENTS.md.template' -Needle '`workflow`: load `entry-router`, `orchestrator`'
Assert-FileContains -Path 'vault-template/entry/AGENTS.md.template' -Needle '`ask`: do not load workflow skills; ask one minimal clarification question.'
Assert-FileContains -Path 'agent-configs/codex/AGENTS.md.template' -Needle 'Do not bulk-load all skills'
Assert-FileContains -Path 'agent-configs/codex/AGENTS.md.template' -Needle '`workflow` loads `entry-router`, `orchestrator`'
Assert-FileContains -Path 'agent-configs/codex/AGENTS.md.template' -Needle '`ask` does not load workflow skills; ask one minimal clarification question.'
Assert-FileContains -Path 'agent-configs/workspace/AGENTS.md.template' -Needle 'Do not bulk-load all skills'
Assert-FileContains -Path 'agent-configs/workspace/AGENTS.md.template' -Needle '`workflow` loads `entry-router`, `orchestrator`'
Assert-FileContains -Path 'agent-configs/workspace/AGENTS.md.template' -Needle '`ask` does not load workflow skills; ask one minimal clarification question.'
Assert-FileContains -Path 'agent-configs/claude/CLAUDE.md.template' -Needle 'Claude 是显式兼容 host'
Assert-FileContains -Path 'agent-configs/claude/CLAUDE.md.template' -Needle '先调用 `/entry-router`'
Assert-FileContains -Path 'agent-configs/claude/CLAUDE.md.template' -Needle '`ask` 不加载 workflow skill，只问一个最小澄清问题。'
Assert-FileContains -Path 'skills/orchestrator/references/default-tool-profiles.md' -Needle 'team preset'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'PreCompact 自检'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'append-runtime-inbox.ps1'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'single-writer-precompact.md'
Assert-FileContains -Path 'skills/workflow-team/SKILL.md' -Needle 'PreCompact Callback'
Assert-FileContains -Path 'skills/workflow-team/SKILL.md' -Needle 'append-runtime-inbox.ps1'
Assert-FileContains -Path 'skills/workflow-team/SKILL.md' -Needle 'single-writer-precompact.md'
Assert-FileContains -Path 'docs/team-write-authority.md' -Needle '.assistant/'
Assert-FileContains -Path 'docs/team-write-authority.md' -Needle 'docs/tasks/<task-id>/'
Assert-FileContains -Path 'docs/工作流/single-writer-precompact.md' -Needle 'cooperative-yield'
Assert-FileContains -Path 'docs/工作流/single-writer-precompact.md' -Needle 'append-runtime-inbox.ps1'
Assert-FileContains -Path 'docs/工作流/single-writer-precompact.md' -Needle 'skills/orchestrator/SKILL.md'
Assert-FileContains -Path 'docs/工作流/single-writer-precompact.md' -Needle 'skills/workflow-team/SKILL.md'
Assert-FileContains -Path 'skills/obsidian-memory/SKILL.md' -Needle '记忆-学习.md'
Assert-FileContains -Path 'skills/obsidian-memory/SKILL.md' -Needle '记忆-决策.md'
Assert-FileContains -Path 'skills/obsidian-memory/SKILL.md' -Needle '记忆-约定.md'
Assert-FileContains -Path 'skills/obsidian-memory/SKILL.md' -Needle '记忆-问题.md'
Assert-FileContains -Path 'skills/obsidian-memory/SKILL.md' -Needle '已合入 entry-router'
Assert-FileContains -Path 'agent-configs/codex/config.shared.toml.template' -Needle 'skills\\entry-router\\SKILL.md'
Assert-FileNotContains -Path 'agent-configs/codex/config.shared.toml.template' -Needle 'using-superpowers'
Assert-FileContains -Path 'agent-configs/workflows/harness-lite.yaml' -Needle '-Quality'
Assert-FileContains -Path 'docs/工作流/quality-rubric.md' -Needle 'completeness'
Assert-FileContains -Path 'docs/工作流/quality-rubric.md' -Needle 'consistency'
Assert-FileContains -Path 'docs/工作流/quality-rubric.md' -Needle 'accuracy'
Assert-FileContains -Path 'docs/工作流/quality-rubric.md' -Needle 'depth'
Assert-FileContains -Path '.assistant/运行时/记忆-学习.md' -Needle 'phase6-init'
Assert-FileContains -Path '.assistant/运行时/记忆-决策.md' -Needle 'phase6-init'
Assert-FileContains -Path '.assistant/运行时/记忆-约定.md' -Needle 'phase6-init'
Assert-FileContains -Path '.assistant/运行时/记忆-问题.md' -Needle 'phase6-init'
Assert-GitIgnoreState -Path '.assistant/运行时/记忆-学习.md' -ShouldBeIgnored $false
Assert-GitIgnoreState -Path '.assistant/运行时/记忆-决策.md' -ShouldBeIgnored $false
Assert-GitIgnoreState -Path '.assistant/运行时/记忆-约定.md' -ShouldBeIgnored $false
Assert-GitIgnoreState -Path '.assistant/运行时/记忆-问题.md' -ShouldBeIgnored $false
Assert-GitIgnoreState -Path '.assistant/运行时/记忆候选.md' -ShouldBeIgnored $true
Assert-GitIgnoreState -Path '.assistant/运行时/记忆候选归档.md' -ShouldBeIgnored $true
Assert-GitIgnoreState -Path '.assistant/运行时/收件箱.md' -ShouldBeIgnored $true
Assert-FileContains -Path 'vault-template/entry/advance-stage.ps1.template' -Needle '{REPO_ROOT}\scripts\advance-stage.ps1'
Assert-FileContains -Path 'vault-template/entry/advance-stage.ps1.template' -Needle '[string]$Tool = ""'
Assert-FileContains -Path 'vault-template/entry/validate-lite-artifacts.ps1.template' -Needle '{REPO_ROOT}\scripts\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'scripts/validate-lite-artifacts.ps1' -Needle "'entry-router'"
Assert-FileContains -Path 'scripts/validate-lite-artifacts.ps1' -Needle "'md-html'"
Assert-FileContains -Path 'skills/obsidian-memory/scripts/check-shared-memory.ps1' -Needle "Join-Path (Join-Path `$workspaceRoot 'docs/tasks') `$TaskId"
Assert-FileNotContains -Path 'skills/obsidian-memory/scripts/check-shared-memory.ps1' -Needle "Join-Path (Join-Path `$workspaceRoot 'docs') `$TaskId"
Assert-FileNotContains -Path 'skills/obsidian-memory/scripts/repair-shared-memory.ps1' -Needle 'docs/tasks/none/plan.md'
Assert-FileNotContains -Path 'README.md' -Needle 'claude-codex-gemini'
Assert-DirectoryVisibleTextNotContains -Path 'vault-template' -Needle 'CC-Codex-Gemini Companion Starter'
Assert-DirectoryVisibleTextNotContains -Path 'vault-template' -Needle 'CC-Codex-Gemini'
Assert-DirectoryVisibleTextNotContains -Path 'vault-template' -Needle 'Gemini Companion'
Assert-FileNotContains -Path 'skills/orchestrator/SKILL.md' -Needle 'claude-codex-gemini'
Assert-FileNotContains -Path 'skills/orchestrator/SKILL.md' -Needle 'next_runner'
Assert-FileNotContains -Path 'skills/orchestrator/references/default-tool-profiles.md' -Needle 'codex-gemini'
Assert-FileNotContains -Path 'skills/plan/SKILL.md' -Needle '## Change Contract  (optional, opt-in)'
Assert-FileNotContains -Path 'skills/orchestrator/references/state-templates.md' -Needle '## Change Contract  (optional, opt-in)'

Assert-UsingSuperpowersRemovedFromActiveSurface
Assert-GeminiDesignerRemovedFromActiveSurface

$phaseDirs = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'skills') -Recurse -Directory -Filter 'phases')
if ($phaseDirs.Count -eq 0) {
    Add-Check 'no skills/*/phases directories were created'
} else {
    Add-Failure ("skills phase-loading should stay lazy-only, found: {0}" -f (@($phaseDirs | ForEach-Object { Get-RepoRelativePath -TargetPath $_.FullName }) -join ', '))
}

$bomTargets = @(
    'harness.ps1',
    'install.ps1',
    'uninstall.ps1'
)
$bomTargets += Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'scripts') -Filter '*.ps1' -File | ForEach-Object { Get-RepoRelativePath -TargetPath $_.FullName }
$bomTargets += Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'tests') -Filter 'verify-*.ps1' -File | ForEach-Object { Get-RepoRelativePath -TargetPath $_.FullName }
$bomTargets += Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'skills') -Recurse -Filter '*.ps1' -File | ForEach-Object { Get-RepoRelativePath -TargetPath $_.FullName }

foreach ($bomTarget in ($bomTargets | Sort-Object -Unique)) {
    Assert-Utf8Bom -Path $bomTarget
}

if ($script:Failures.Count -gt 0) {
    Write-Output 'STATUS: FAIL'
} else {
    Write-Output 'STATUS: PASS'
}
Write-Output ("RepoRoot: {0}" -f $script:RepoRoot)
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

if ($script:Failures.Count -gt 0) {
    exit 2
}

exit 0
