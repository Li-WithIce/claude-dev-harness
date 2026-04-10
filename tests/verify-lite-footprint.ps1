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

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$script:RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$script:Checks = @()
$script:Failures = @()

$expectedSkills = @(
    'codex',
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

Assert-FileContains -Path '.gitignore' -Needle '.assistant/'
Assert-FileContains -Path '.gitignore' -Needle 'skills/*/.runtime/'
Assert-FileContains -Path '.gitignore' -Needle 'agent-configs/workspace/entry/'
Assert-FileContains -Path 'vault-template/工作流/共享记忆协议.md' -Needle 'docs/tasks/<task-id>/*'
Assert-FileContains -Path 'vault-template/工作流/写回协议.md' -Needle 'docs/tasks/<task-id>/*'
Assert-FileContains -Path 'vault-template/配置/敏感信息规范.md' -Needle 'docs/tasks/**'
Assert-FileContains -Path 'README.md' -Needle 'skills/orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'README.md' -Needle 'scripts/validate-lite-artifacts.ps1'
Assert-FileContains -Path 'README.md' -Needle '.assistant\entry\advance-stage.ps1'
Assert-FileContains -Path 'README.md' -Needle '.assistant\entry\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'README.md' -Needle 'tool: claudecode | codex | gemini | none'
Assert-FileContains -Path 'scripts/advance-stage.ps1' -Needle 'validate-lite-artifacts.ps1'
Assert-FileContains -Path 'scripts/advance-stage.ps1' -Needle '[string]$Tool = ""'
Assert-FileContains -Path 'scripts/validate-lite-artifacts.ps1' -Needle 'task_id/stage/tool/updated'
Assert-FileContains -Path 'skills/spec/SKILL.md' -Needle '../orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/plan/SKILL.md' -Needle '../orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/review/SKILL.md' -Needle '../orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/test/SKILL.md' -Needle '../orchestrator/references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/orchestrator/SKILL.md' -Needle 'references/lite-writing-guide.md'
Assert-FileContains -Path 'skills/plan/SKILL.md' -Needle '.assistant\entry\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'skills/implement/SKILL.md' -Needle '.assistant\entry\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'skills/review/SKILL.md' -Needle '.assistant\entry\advance-stage.ps1'
Assert-FileContains -Path 'skills/test/SKILL.md' -Needle '.assistant\entry\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'skills/orchestrator/references/runbook.md' -Needle '.assistant\entry\advance-stage.ps1'
Assert-FileContains -Path 'skills/using-superpowers/SKILL.md' -Needle '.assistant\entry\advance-stage.ps1'
Assert-FileContains -Path 'vault-template/entry/advance-stage.ps1.template' -Needle '{REPO_ROOT}\scripts\advance-stage.ps1'
Assert-FileContains -Path 'vault-template/entry/advance-stage.ps1.template' -Needle '[string]$Tool = ""'
Assert-FileContains -Path 'vault-template/entry/validate-lite-artifacts.ps1.template' -Needle '{REPO_ROOT}\scripts\validate-lite-artifacts.ps1'
Assert-FileContains -Path 'skills/obsidian-memory/scripts/check-shared-memory.ps1' -Needle "Join-Path (Join-Path `$workspaceRoot 'docs/tasks') `$TaskId"
Assert-FileNotContains -Path 'skills/obsidian-memory/scripts/check-shared-memory.ps1' -Needle "Join-Path (Join-Path `$workspaceRoot 'docs') `$TaskId"
Assert-FileNotContains -Path 'skills/obsidian-memory/scripts/repair-shared-memory.ps1' -Needle 'docs/tasks/none/plan.md'
Assert-FileNotContains -Path 'README.md' -Needle 'claude-codex-gemini'
Assert-FileNotContains -Path 'skills/orchestrator/SKILL.md' -Needle 'claude-codex-gemini'
Assert-FileNotContains -Path 'skills/orchestrator/SKILL.md' -Needle 'next_runner'
Assert-FileNotContains -Path 'skills/orchestrator/references/default-tool-profiles.md' -Needle 'codex-gemini'

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
