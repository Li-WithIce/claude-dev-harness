[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8
}

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Warning {
    param([string]$Message)
    $script:Warnings += $Message
}

function Add-Error {
    param([string]$Message)
    $script:Errors += $Message
}

function Get-JunctionTarget {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -Force
    $target = $item.Target
    if ($target -is [System.Array]) {
        $target = $target[0]
    }

    return Get-NormalizedPath -Path $target
}

function Assert-RenderedFile {
    param(
        [string]$Path,
        [string[]]$ForbiddenTokens
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Error ("缺少文件: {0}" -f $Path)
        return
    }

    $content = Read-FileUtf8 -Path $Path
    if ($null -eq $content) {
        Add-Error ("无法读取文件: {0}" -f $Path)
        return
    }

    $hit = $ForbiddenTokens | Where-Object { $content.Contains($_) } | Select-Object -First 1
    if ($null -ne $hit) {
        Add-Error ("文件仍含未渲染占位符 {0}: {1}" -f $hit, $Path)
    } else {
        Add-Check ("已渲染: {0}" -f $Path)
    }
}

function Assert-ManagedSkillLinks {
    param(
        [string]$HostLabel,
        [string]$HostSkillsPath,
        [string]$RepoSkillsPath
    )

    $hotSwapPreservedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$hotSwapPreservedNames.Add('docs')

    if (-not (Test-Path -LiteralPath $HostSkillsPath -PathType Container)) {
        Add-Error ("缺少 {0} skills 目录: {1}" -f $HostLabel, $HostSkillsPath)
        return
    }

    $rootTarget = Get-JunctionTarget -Path $HostSkillsPath
    if ($null -ne $rootTarget) {
        Add-Error ("{0} skills 根目录不应是 Junction: {1} -> {2}" -f $HostLabel, $HostSkillsPath, $rootTarget)
        return
    }

    $checkedCount = 0
    foreach ($entry in Get-ChildItem -LiteralPath $RepoSkillsPath -Force) {
        $hostEntryPath = Join-Path $HostSkillsPath $entry.Name
        if (-not (Test-Path -LiteralPath $hostEntryPath)) {
            Add-Error ("{0} skills 缺少 managed 条目: {1}" -f $HostLabel, $hostEntryPath)
            continue
        }

        $expectedTarget = Get-NormalizedPath -Path $entry.FullName
        $actualTarget = Get-JunctionTarget -Path $hostEntryPath
        if ($hotSwapPreservedNames.Contains($entry.Name) -and ($null -eq $actualTarget)) {
            $checkedCount += 1
            continue
        }

        if ($actualTarget -eq $expectedTarget) {
            $checkedCount += 1
            continue
        }

        Add-Error ("{0} skills 条目未正确链接到 repo: {1}" -f $HostLabel, $hostEntryPath)
    }

    Add-Check ("{0} skills 根目录保留为普通目录，managed 条目检查数: {1}" -f $HostLabel, $checkedCount)
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is required for verify-installation.ps1'
}

$RepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
} else {
    $RepoRoot
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$WorkspaceRoot = Get-NormalizedPath -Path $WorkspaceRoot
$VaultPath = Join-Path $WorkspaceRoot '.assistant'
$ClaudeHome = Join-Path $env:USERPROFILE '.claude'
$CodexHome = Join-Path $env:USERPROFILE '.codex'
$RepoSkillsPath = Join-Path $RepoRoot 'skills'
$ClaudeSkillsPath = Join-Path $ClaudeHome 'skills'
$CodexSkillsPath = Join-Path $CodexHome 'skills'
$ClaudeHooksPath = Join-Path $ClaudeHome 'hooks-memory'
$ClaudeSettingsPath = Join-Path (Join-Path $ClaudeHome '.claude') 'settings.local.json'
$CodexSettingsPath = Join-Path (Join-Path $CodexHome '.claude') 'settings.local.json'
$CodexConfigPath = Join-Path $CodexHome 'config.toml'
$CodexAgentsPath = Join-Path $CodexHome 'AGENTS.md'
$WorkspaceAgentsPath = Join-Path $WorkspaceRoot 'AGENTS.md'
$WorkspaceGeminiPath = Join-Path $WorkspaceRoot 'GEMINI.md'
$ForbiddenTokens = @('{REPO_ROOT}', '{WORKSPACE_ROOT}', '{VAULT_PATH}', '{CLAUDE_HOME}', '{CODEX_HOME}', '{GEMINI_HOME}')

$script:Checks = @()
$script:Warnings = @()
$script:Errors = @()

Assert-ManagedSkillLinks -HostLabel 'Claude' -HostSkillsPath $ClaudeSkillsPath -RepoSkillsPath $RepoSkillsPath
Assert-ManagedSkillLinks -HostLabel 'Codex' -HostSkillsPath $CodexSkillsPath -RepoSkillsPath $RepoSkillsPath

foreach ($hookName in @('userpromptsubmit.js', 'posttooluse.js', 'stop.js')) {
    Assert-RenderedFile -Path (Join-Path $ClaudeHooksPath $hookName) -ForbiddenTokens $ForbiddenTokens
}

Assert-RenderedFile -Path $CodexAgentsPath -ForbiddenTokens $ForbiddenTokens
Assert-RenderedFile -Path $WorkspaceAgentsPath -ForbiddenTokens $ForbiddenTokens
Assert-RenderedFile -Path $WorkspaceGeminiPath -ForbiddenTokens $ForbiddenTokens

if (Test-Path -LiteralPath $ClaudeSettingsPath -PathType Leaf) {
    try {
        $claudeSettings = Get-Content -LiteralPath $ClaudeSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($key in @('UserPromptSubmit', 'Stop', 'PostToolUse')) {
            $value = $claudeSettings.$key
            if ($value -is [System.Array] -and $value.Count -gt 0) {
                Add-Check ("Claude settings.local.json 包含数组化的 {0}" -f $key)
            } else {
                Add-Error ("Claude settings.local.json 缺少数组化的 {0}" -f $key)
            }
        }
    } catch {
        Add-Error ("Claude settings.local.json 不是合法 JSON: {0}" -f $_.Exception.Message)
    }
} else {
    Add-Error ("缺少 Claude settings.local.json: {0}" -f $ClaudeSettingsPath)
}

if (Test-Path -LiteralPath $CodexSettingsPath -PathType Leaf) {
    try {
        $codexSettings = Get-Content -LiteralPath $CodexSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
        $allow = @($codexSettings.permissions.allow)
        if ($allow -contains 'Read(//workspace/**)') {
            Add-Check 'Codex settings.local.json 已包含 shared workspace 读取权限'
        } else {
            Add-Error 'Codex settings.local.json 缺少 shared workspace 读取权限'
        }
    } catch {
        Add-Error ("Codex settings.local.json 不是合法 JSON: {0}" -f $_.Exception.Message)
    }
} else {
    Add-Error ("缺少 Codex settings.local.json: {0}" -f $CodexSettingsPath)
}

if (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf) {
    $codexConfig = Read-FileUtf8 -Path $CodexConfigPath
    if ($codexConfig -match '# >>> claude-dev-harness managed block >>>' -and $codexConfig -match '# <<< claude-dev-harness managed block <<<') {
        Add-Check 'Codex config.toml 已写入 managed block'
    } else {
        Add-Error 'Codex config.toml 缺少 managed block'
    }

    $configWithoutManagedBlock = [regex]::Replace(
        $codexConfig,
        '(?ms)^\# >>> claude-dev-harness managed block >>>\r?\n.*?^\# <<< claude-dev-harness managed block <<<\r?\n?',
        ''
    )
    if ($configWithoutManagedBlock -match '^\[\[skills\.config\]\]' ) {
        Add-Error 'Codex config.toml 在 managed block 外仍残留 [[skills.config]]'
    } else {
        Add-Check 'Codex config.toml 已清理旧的 [[skills.config]]'
    }
} else {
    Add-Error ("缺少 Codex config.toml: {0}" -f $CodexConfigPath)
}

$forbiddenPatterns = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests\forbidden-path-prefixes.txt') -Encoding utf8
$tomlHits = Select-String -Path (Join-Path $RepoRoot 'agent-configs\codex\*.toml') -Pattern $forbiddenPatterns -SimpleMatch -ErrorAction SilentlyContinue
if ($null -eq $tomlHits) {
    Add-Check 'agent-configs/codex/*.toml 未命中 forbidden path prefixes'
} else {
    $firstHit = $tomlHits | Select-Object -First 1
    Add-Error ("agent-configs/codex/*.toml 命中 forbidden prefix: {0}:{1}" -f $firstHit.Path, $firstHit.LineNumber)
}

if (Test-Path -LiteralPath (Join-Path $RepoRoot 'scripts\memory-health.ps1') -PathType Leaf) {
    $healthOutput = @(& (Join-Path $RepoRoot 'scripts\memory-health.ps1') -VaultRoot $VaultPath 2>&1)
    if ($LASTEXITCODE -eq 0 -and ($healthOutput -join "`n") -match 'STATUS:\s+PASS') {
        Add-Check '共享记忆健康检查返回 STATUS: PASS'
    } else {
        Add-Error ("共享记忆健康检查失败: exit={0}" -f $LASTEXITCODE)
    }
} else {
    Add-Error ("缺少 memory-health.ps1: {0}" -f (Join-Path $RepoRoot 'scripts\memory-health.ps1'))
}

$status = 'PASS'
if ($script:Errors.Count -gt 0) {
    $status = 'FAIL'
} elseif ($script:Warnings.Count -gt 0) {
    $status = 'WARN'
}

Write-Output ("STATUS: {0}" -f $status)
Write-Output ("RepoRoot: {0}" -f $RepoRoot)
Write-Output ("WorkspaceRoot: {0}" -f $WorkspaceRoot)
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
Write-Output 'Warnings:'
if ($script:Warnings.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Warnings) {
        Write-Output ("- {0}" -f $item)
    }
}
Write-Output ''
Write-Output 'Errors:'
if ($script:Errors.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Errors) {
        Write-Output ("- {0}" -f $item)
    }
}

if ($script:Errors.Count -gt 0) {
    exit 2
}
if ($script:Warnings.Count -gt 0) {
    exit 1
}
exit 0
