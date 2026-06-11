[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$RepoRoot = "",
    [string]$Scope = "All",
    [string]$CurrentFlowPath = "",
    [string]$UserProfileRoot = ""
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

function Render-TemplateContent {
    param(
        [string]$Content,
        [switch]$EscapeForCode
    )

    $rendered = $Content
    foreach ($key in $script:RenderTokens.Keys) {
        $value = $script:RenderTokens[$key]
        if ($EscapeForCode) {
            $value = $value.Replace('\', '\\')
        }
        $rendered = $rendered.Replace($key, $value)
    }

    return $rendered
}

function Test-LineContentMatches {
    param(
        [string]$ExpectedContent,
        [string]$ActualContent
    )

    $expectedLines = [regex]::Split($ExpectedContent.TrimEnd(), '\r?\n') | ForEach-Object { $_.TrimEnd() }
    $actualLines = [regex]::Split($ActualContent.TrimEnd(), '\r?\n') | ForEach-Object { $_.TrimEnd() }

    if ($expectedLines.Count -ne $actualLines.Count) {
        return $false
    }

    for ($index = 0; $index -lt $expectedLines.Count; $index += 1) {
        if ($expectedLines[$index] -ne $actualLines[$index]) {
            return $false
        }
    }

    return $true
}

function Get-TomlQuotedPathValue {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    if ($Line -notmatch '^\s*path\s*=') {
        return $null
    }

    $rawValue = ($Line -replace '^\s*path\s*=\s*', '').Trim()
    if ($rawValue.Length -lt 2) {
        return $null
    }

    $quote = $rawValue[0]
    $doubleQuote = [char]34
    $singleQuote = [char]39
    if (($quote -ne $doubleQuote -and $quote -ne $singleQuote) -or ($rawValue[$rawValue.Length - 1] -ne $quote)) {
        return $null
    }

    return Get-NormalizedPath -Path $rawValue.Substring(1, $rawValue.Length - 2)
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

function Find-WorkspaceRootFromLocation {
    param([string]$StartPath)

    try {
        $candidateRoot = Get-NormalizedPath -Path $StartPath
        while (-not [string]::IsNullOrWhiteSpace($candidateRoot)) {
            if (Test-Path -LiteralPath (Join-Path $candidateRoot '.assistant') -PathType Container) {
                return $candidateRoot
            }

            $parent = Split-Path -Parent $candidateRoot
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidateRoot) {
                break
            }

            $candidateRoot = $parent
        }
    } catch {
        return $null
    }

    return $null
}

function Resolve-WorkspaceRoot {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return Get-NormalizedPath -Path $ExplicitPath
    }

    $environmentCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($definition in @(
            [pscustomobject]@{ Name = 'DEV_HARNESS_WORKSPACE_ROOT'; Value = $env:DEV_HARNESS_WORKSPACE_ROOT },
            [pscustomobject]@{ Name = 'CLAUDE_DEV_HARNESS_WORKSPACE_ROOT'; Value = $env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT },
            [pscustomobject]@{ Name = 'WORKSPACE_ROOT'; Value = $env:WORKSPACE_ROOT }
        )) {
        if ([string]::IsNullOrWhiteSpace($definition.Value)) {
            continue
        }

        $environmentCandidates.Add([pscustomobject]@{
                Name = $definition.Name
                Path = Get-NormalizedPath -Path $definition.Value
            }) | Out-Null
    }

    if ($environmentCandidates.Count -gt 1) {
        $uniqueEnvironmentPaths = @($environmentCandidates | Select-Object -ExpandProperty Path -Unique)
        if ($uniqueEnvironmentPaths.Count -gt 1) {
            $details = $environmentCandidates | ForEach-Object { "{0}={1}" -f $_.Name, $_.Path }
            throw ("Conflicting workspace roots from environment: {0}" -f ($details -join '; '))
        }
    }

    if ($environmentCandidates.Count -gt 0) {
        return $environmentCandidates[0].Path
    }

    $cwdWorkspaceRoot = Find-WorkspaceRootFromLocation -StartPath (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($cwdWorkspaceRoot)) {
        return $cwdWorkspaceRoot
    }

    throw 'You must provide -WorkspaceRoot, set DEV_HARNESS_WORKSPACE_ROOT / WORKSPACE_ROOT, or run from inside a workspace that contains .assistant'
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

function Assert-TemplateFileMatches {
    param(
        [string]$Path,
        [string]$TemplatePath,
        [string]$Label,
        [switch]$EscapeForCode
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Error ("缺少 {0}: {1}" -f $Label, $Path)
        return
    }

    $actualContent = Read-FileUtf8 -Path $Path
    if ($null -eq $actualContent) {
        Add-Error ("无法读取 {0}: {1}" -f $Label, $Path)
        return
    }

    $templateContent = Read-FileUtf8 -Path $TemplatePath
    if ($null -eq $templateContent) {
        Add-Error ("无法读取 {0} 模板: {1}" -f $Label, $TemplatePath)
        return
    }

    $renderedTemplate = Render-TemplateContent -Content $templateContent -EscapeForCode:$EscapeForCode
    if (Test-LineContentMatches -ExpectedContent $renderedTemplate -ActualContent $actualContent) {
        Add-Check ("{0} 内容与模板一致" -f $Label)
    } else {
        Add-Error ("{0} 与模板不一致（可能缺少、变更或多出额外行）" -f $Label)
    }
}

function Assert-GitIgnoreManagedEntries {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Error ("缺少 workspace .gitignore: {0}" -f $Path)
        return
    }

    $content = Read-FileUtf8 -Path $Path
    if ($null -eq $content) {
        Add-Error ("无法读取 workspace .gitignore: {0}" -f $Path)
        return
    }

    $lines = [regex]::Split($content, '\r?\n') | ForEach-Object { $_.Trim() }
    foreach ($entry in @('# dev-harness workspace artifacts', '.assistant/', 'AGENTS.md', 'GEMINI.md', '.claude')) {
        $matches = @($lines | Where-Object { $_ -eq $entry })
        if ($matches.Count -eq 1) {
            Add-Check (".gitignore 包含且仅包含一条 [{0}]" -f $entry)
        } elseif ($matches.Count -eq 0) {
            Add-Error (".gitignore 缺少 [{0}]" -f $entry)
        } else {
            Add-Error (".gitignore 中 [{0}] 出现了 {1} 次，应为 1 次" -f $entry, $matches.Count)
        }
    }
}

function Assert-PreservedDirectoryMatchesRepo {
    param(
        [string]$HostPath,
        [string]$RepoPath,
        [string]$Label,
        [switch]$AllowExtraEntries
    )

    $missingCount = 0
    $changedCount = 0
    $extraCount = 0
    $repoRelativeFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($repoFile in Get-ChildItem -LiteralPath $RepoPath -Recurse -File) {
        $relative = $repoFile.FullName.Substring($RepoPath.Length).TrimStart('\')
        [void]$repoRelativeFiles.Add($relative)
        $hostFile = Join-Path $HostPath $relative
        if (-not (Test-Path -LiteralPath $hostFile -PathType Leaf)) {
            $missingCount += 1
            continue
        }

        $repoHash = (Get-FileHash -LiteralPath $repoFile.FullName -Algorithm SHA256).Hash
        $hostHash = (Get-FileHash -LiteralPath $hostFile -Algorithm SHA256).Hash
        if ($repoHash -ne $hostHash) {
            $changedCount += 1
        }
    }

    foreach ($hostFile in Get-ChildItem -LiteralPath $HostPath -Recurse -File) {
        $relative = $hostFile.FullName.Substring($HostPath.Length).TrimStart('\')
        if (-not $repoRelativeFiles.Contains($relative)) {
            $extraCount += 1
        }
    }

    $hasDrift = $missingCount -gt 0 -or $changedCount -gt 0 -or ((-not $AllowExtraEntries.IsPresent) -and $extraCount -gt 0)
    if ($hasDrift) {
        $installScriptPath = Join-Path $RepoRoot 'install.ps1'
        Add-Warning ("{0} 保留为普通目录，但与 repo 内容不一致: missing={1}, changed={2}, extra={3}。可重新运行: {4}" -f $Label, $missingCount, $changedCount, $extraCount, $installScriptPath)
    } else {
        Add-Check ("{0} 保留为普通目录，且内容与 repo 一致" -f $Label)
    }
}

function Get-ManagedTomlBlockContent {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }

    $match = [regex]::Match(
        $Content,
        '(?ms)^\# >>> (?<marker>dev-harness|claude-dev-harness) managed block >>>\r?\n(.*?)^\# <<< \k<marker> managed block <<<\r?\n?'
    )
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[1].Value.Trim()
}

function Get-TomlSkillConfigPaths {
    param([string]$Content)

    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @()
    }

    $inSkillsConfig = $false
    foreach ($line in ([regex]::Split($Content, '\r?\n'))) {
        if ($line -match '^\[\[skills\.config\]\]\s*$') {
            $inSkillsConfig = $true
            continue
        }

        if ($inSkillsConfig -and $line -match '^\[') {
            $inSkillsConfig = $false
        }

        if (-not $inSkillsConfig) {
            continue
        }

        $path = Get-TomlQuotedPathValue -Line $line
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            [void]$paths.Add($path)
        }
    }

    return @($paths)
}

function Assert-ManagedSkillLinks {
    param(
        [string]$HostLabel,
        [string]$HostSkillsPath,
        [string]$RepoSkillsPath
    )

    $hotSwapPreservedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$hotSwapPreservedNames.Add('.system')

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
    $managedEntryNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in Get-ChildItem -LiteralPath $RepoSkillsPath -Force) {
        [void]$managedEntryNames.Add($entry.Name)
        $hostEntryPath = Join-Path $HostSkillsPath $entry.Name
        if (-not (Test-Path -LiteralPath $hostEntryPath)) {
            Add-Error ("{0} skills 缺少 managed 条目: {1}" -f $HostLabel, $hostEntryPath)
            continue
        }

        $expectedTarget = Get-NormalizedPath -Path $entry.FullName
        $actualTarget = Get-JunctionTarget -Path $hostEntryPath
        if ($hotSwapPreservedNames.Contains($entry.Name) -and ($null -eq $actualTarget)) {
            $checkedCount += 1
            $allowExtraEntries = $entry.Name -eq '.system'
            Assert-PreservedDirectoryMatchesRepo -HostPath $hostEntryPath -RepoPath $entry.FullName -Label ("{0} skills/{1}" -f $HostLabel, $entry.Name) -AllowExtraEntries:$allowExtraEntries
            continue
        }

        if ($actualTarget -eq $expectedTarget) {
            $checkedCount += 1
            continue
        }

        Add-Error ("{0} skills 条目未正确链接到 repo: {1}" -f $HostLabel, $hostEntryPath)
    }

    $normalizedRepoSkillsPath = Get-NormalizedPath -Path $RepoSkillsPath
    foreach ($entry in Get-ChildItem -LiteralPath $HostSkillsPath -Force) {
        if ($managedEntryNames.Contains($entry.Name)) {
            continue
        }

        $actualTarget = Get-JunctionTarget -Path $entry.FullName
        if (-not [string]::IsNullOrWhiteSpace($actualTarget) -and
            ($actualTarget.Equals($normalizedRepoSkillsPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                $actualTarget.StartsWith($normalizedRepoSkillsPath + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
            Add-Error ("{0} skills 存在 repo 已不再托管的陈旧 Harness 链接: {1} -> {2}" -f $HostLabel, $entry.FullName, $actualTarget)
        }
    }

    $legacyDocsPath = Join-Path $HostSkillsPath 'docs'
    if (-not $managedEntryNames.Contains('docs') -and (Test-Path -LiteralPath $legacyDocsPath)) {
        Add-Error ("{0} skills 存在 legacy docs 目录，应删除: {1}" -f $HostLabel, $legacyDocsPath)
    }

    Add-Check ("{0} skills 根目录保留为普通目录，managed 条目检查数: {1}" -f $HostLabel, $checkedCount)
}

$RepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
} else {
    $RepoRoot
}

$effectiveUserProfile = if ([string]::IsNullOrWhiteSpace($UserProfileRoot)) {
    $env:USERPROFILE
} else {
    $UserProfileRoot
}

if ([string]::IsNullOrWhiteSpace($effectiveUserProfile)) {
    throw 'USERPROFILE is required for verify-installation.ps1'
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$WorkspaceRoot = Resolve-WorkspaceRoot -ExplicitPath $WorkspaceRoot
$effectiveUserProfile = Get-NormalizedPath -Path $effectiveUserProfile
$VaultPath = Join-Path $WorkspaceRoot '.assistant'
$ClaudeHome = Join-Path $effectiveUserProfile '.claude'
$CodexHome = Join-Path $effectiveUserProfile '.codex'
$AgentsHome = Join-Path $effectiveUserProfile '.agents'
$RepoSkillsPath = Join-Path $RepoRoot 'skills'
$ClaudeSkillsPath = Join-Path $ClaudeHome 'skills'
$CodexSkillsPath = Join-Path $CodexHome 'skills'
$AgentsSkillsPath = Join-Path $AgentsHome 'skills'
$ClaudeHooksPath = Join-Path $ClaudeHome 'hooks-memory'
$ClaudeSettingsPath = Join-Path (Join-Path $ClaudeHome '.claude') 'settings.local.json'
$CodexSettingsPath = Join-Path (Join-Path $CodexHome '.claude') 'settings.local.json'
$CodexConfigPath = Join-Path $CodexHome 'config.toml'
$CodexManagedConfigPath = Join-Path $CodexHome 'managed_config.toml'
$CodexAgentsPath = Join-Path $CodexHome 'AGENTS.md'
$WorkspaceAgentsPath = Join-Path $WorkspaceRoot 'AGENTS.md'
$WorkspaceGeminiPath = Join-Path $WorkspaceRoot 'GEMINI.md'
$WorkspaceGitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
$WorkspaceEntryAgentsPath = Join-Path $VaultPath 'entry\AGENTS.md'
$WorkspaceEntryGeminiPath = Join-Path $VaultPath 'entry\GEMINI.md'
$WorkspaceAdvanceStageShimPath = Join-Path $VaultPath 'entry\advance-stage.ps1'
$WorkspaceValidateArtifactsShimPath = Join-Path $VaultPath 'entry\validate-lite-artifacts.ps1'
$ForbiddenTokens = @('{REPO_ROOT}', '{WORKSPACE_ROOT}', '{VAULT_PATH}', '{CLAUDE_HOME}', '{CODEX_HOME}', '{GEMINI_HOME}')
$script:RenderTokens = [ordered]@{
    '{REPO_ROOT}' = $RepoRoot
    '{WORKSPACE_ROOT}' = $WorkspaceRoot
    '{VAULT_PATH}' = $VaultPath
    '{CLAUDE_HOME}' = $ClaudeHome
    '{CODEX_HOME}' = $CodexHome
    '{GEMINI_HOME}' = (Join-Path $effectiveUserProfile '.gemini')
}

$script:Checks = @()
$script:Warnings = @()
$script:Errors = @()

Assert-ManagedSkillLinks -HostLabel 'Claude' -HostSkillsPath $ClaudeSkillsPath -RepoSkillsPath $RepoSkillsPath
Assert-ManagedSkillLinks -HostLabel 'Codex' -HostSkillsPath $CodexSkillsPath -RepoSkillsPath $RepoSkillsPath
Assert-ManagedSkillLinks -HostLabel 'Agents' -HostSkillsPath $AgentsSkillsPath -RepoSkillsPath $RepoSkillsPath

foreach ($hookName in @('userpromptsubmit.js', 'posttooluse.js', 'stop.js')) {
    Assert-RenderedFile -Path (Join-Path $ClaudeHooksPath $hookName) -ForbiddenTokens $ForbiddenTokens
}

Assert-RenderedFile -Path $CodexAgentsPath -ForbiddenTokens $ForbiddenTokens
Assert-TemplateFileMatches -Path $CodexAgentsPath -TemplatePath (Join-Path $RepoRoot 'agent-configs\codex\AGENTS.md.template') -Label 'Codex AGENTS.md'
Assert-RenderedFile -Path $WorkspaceAgentsPath -ForbiddenTokens $ForbiddenTokens
Assert-RenderedFile -Path $WorkspaceGeminiPath -ForbiddenTokens $ForbiddenTokens
Assert-GitIgnoreManagedEntries -Path $WorkspaceGitIgnorePath
Assert-RenderedFile -Path $WorkspaceEntryAgentsPath -ForbiddenTokens $ForbiddenTokens
Assert-RenderedFile -Path $WorkspaceEntryGeminiPath -ForbiddenTokens $ForbiddenTokens
Assert-RenderedFile -Path $WorkspaceAdvanceStageShimPath -ForbiddenTokens $ForbiddenTokens
Assert-RenderedFile -Path $WorkspaceValidateArtifactsShimPath -ForbiddenTokens $ForbiddenTokens

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

$renderedManagedTemplate = Render-TemplateContent -Content (Read-FileUtf8 -Path (Join-Path $RepoRoot 'agent-configs\codex\config.shared.toml.template')) -EscapeForCode

if (Test-Path -LiteralPath $CodexConfigPath -PathType Leaf) {
    $codexConfig = Read-FileUtf8 -Path $CodexConfigPath
    if ($null -eq $codexConfig) {
        $codexConfig = ""
    }
    if ([regex]::IsMatch($codexConfig, "`r(?!`n)")) {
        Add-Warning 'Codex config.toml 存在孤立 CR 换行字节，可能导致 TOML 解析失败；该文件为用户私有配置，install.ps1 不会自动改写'
    } else {
        Add-Check 'Codex config.toml 未发现孤立 CR 换行字节'
    }

    $managedBlockContent = Get-ManagedTomlBlockContent -Content $codexConfig
    if ($null -eq $managedBlockContent) {
        Add-Check 'Codex config.toml 未包含旧 managed block'
    } else {
        Add-Warning 'Codex config.toml 仍包含旧 managed block；托管配置已写入 managed_config.toml，用户私有 config.toml 不会自动改写'
    }

    $configWithoutManagedBlock = [regex]::Replace(
        $codexConfig,
        '(?ms)^\# >>> (?<marker>dev-harness|claude-dev-harness) managed block >>>\r?\n.*?^\# <<< \k<marker> managed block <<<\r?\n?',
        ''
    )
    $managedSkillPaths = Get-TomlSkillConfigPaths -Content $renderedManagedTemplate
    $leakedManagedPath = $managedSkillPaths |
        Where-Object { $configWithoutManagedBlock -match [regex]::Escape($_) } |
        Select-Object -First 1
    if ($null -ne $leakedManagedPath) {
        Add-Warning ("Codex config.toml 在 managed block 外仍残留 Harness 托管 skill path: {0}；用户私有 config.toml 不会自动改写" -f $leakedManagedPath)
    } else {
        Add-Check 'Codex config.toml 未在 managed block 外泄露 Harness 托管 skill path'
    }
} else {
    Add-Check ("Codex config.toml 不存在，按用户私有可选配置处理: {0}" -f $CodexConfigPath)
}

if (Test-Path -LiteralPath $CodexManagedConfigPath -PathType Leaf) {
    $codexManagedConfig = Read-FileUtf8 -Path $CodexManagedConfigPath
    if ([regex]::IsMatch($codexManagedConfig, "`r(?!`n)")) {
        Add-Error 'Codex managed_config.toml 存在孤立 CR 换行字节，可能导致 TOML 解析失败'
    } else {
        Add-Check 'Codex managed_config.toml 未发现孤立 CR 换行字节'
    }

    if (Test-LineContentMatches -ExpectedContent $renderedManagedTemplate -ActualContent $codexManagedConfig) {
        Add-Check 'Codex managed_config.toml 内容与模板一致'
    } else {
        Add-Error 'Codex managed_config.toml 与模板不一致（可能缺少、变更或多出额外行）'
    }
} else {
    Add-Error ("缺少 Codex managed_config.toml: {0}" -f $CodexManagedConfigPath)
}

$forbiddenPatterns = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests\forbidden-path-prefixes.txt') -Encoding utf8
$tomlHits = Select-String -Path (Join-Path $RepoRoot 'agent-configs\codex\*.toml') -Pattern $forbiddenPatterns -SimpleMatch -ErrorAction SilentlyContinue
if ($null -eq $tomlHits) {
    Add-Check 'agent-configs/codex/*.toml 未命中 forbidden path prefixes'
} else {
    $firstHit = $tomlHits | Select-Object -First 1
    Add-Error ("agent-configs/codex/*.toml 命中 forbidden prefix: {0}:{1}" -f $firstHit.Path, $firstHit.LineNumber)
}

if ($Scope -eq 'WorkflowStatus') {
    Add-Check 'WorkflowStatus scope skips shared-memory health because harness-status runs that gate separately'
} elseif (Test-Path -LiteralPath (Join-Path $RepoRoot 'scripts\memory-health.ps1') -PathType Leaf) {
    $healthArguments = @{
        VaultRoot = $VaultPath
    }
    if (-not [string]::IsNullOrWhiteSpace($CurrentFlowPath)) {
        $healthArguments.OrchestratorFlowPath = $CurrentFlowPath
    }
    $healthOutput = @(& (Join-Path $RepoRoot 'scripts\memory-health.ps1') @healthArguments 2>&1)
    if ($LASTEXITCODE -eq 0 -and ($healthOutput -join [Environment]::NewLine) -match 'STATUS:\s+PASS') {
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
