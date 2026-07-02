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
    旧 alias 目录移除后，旧名只能留在 git history 或测试回归锁点；
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
    迁移到 test-runner 后，旧名只能留在 git history 或测试回归锁点；
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

Assert-FileNotContains -Path 'agent-configs/workflows/harness-lite.yaml' -Needle 'skills_whitelist: [plan, using-superpowers]'
Assert-FileNotContains -Path 'agent-configs/role-prompts/tester.md' -Needle 'Allowed skills: test, test-runner'
Assert-FileNotContains -Path 'skills/plan/SKILL.md' -Needle '适用：`claudecode`'
Assert-FileNotContains -Path 'skills/implement/SKILL.md' -Needle '适用：`claudecode`'
Assert-FileNotContains -Path 'skills/review/SKILL.md' -Needle '适用：`claudecode`'
Assert-PathAbsent -Path 'skills/using-superpowers'
Assert-PathAbsent -Path ('skills/' + 'gemini-designer' + '-main')
Assert-FileNotContains -Path 'agent-configs/codex/config.shared.toml.template' -Needle 'using-superpowers'
Assert-GitIgnoreState -Path '.assistant/运行时/记忆-学习.md' -ShouldBeIgnored $false
Assert-GitIgnoreState -Path '.assistant/运行时/记忆-决策.md' -ShouldBeIgnored $false
Assert-GitIgnoreState -Path '.assistant/运行时/记忆-约定.md' -ShouldBeIgnored $false
Assert-GitIgnoreState -Path '.assistant/运行时/记忆-问题.md' -ShouldBeIgnored $false
Assert-GitIgnoreState -Path '.assistant/运行时/记忆候选.md' -ShouldBeIgnored $true
Assert-GitIgnoreState -Path '.assistant/运行时/记忆候选归档.md' -ShouldBeIgnored $true
Assert-GitIgnoreState -Path '.assistant/运行时/收件箱.md' -ShouldBeIgnored $true
Assert-GitIgnoreState -Path 'docs/tasks/example/plan.md' -ShouldBeIgnored $true
Assert-GitIgnoreState -Path 'docs/tasks/README.md' -ShouldBeIgnored $false
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
