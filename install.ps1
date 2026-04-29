[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Web.Extensions
$script:JsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:JsonSerializer.MaxJsonLength = [int]::MaxValue

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Ensure-Directory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Remove-PathIfExists {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        return
    }

    Remove-Item -LiteralPath $Path -Force
}

function Get-RelativePath {
    <#
    .SYNOPSIS
    计算 FullPath 相对于 RootPath 的相对路径。
    .PARAMETER RootPath
    根目录。
    .PARAMETER FullPath
    完整路径。
    .OUTPUTS
    System.String。
    #>
    param(
        [string]$RootPath,
        [string]$FullPath
    )

    $normalizedRoot = (Get-NormalizedPath -Path $RootPath).TrimEnd('\')
    $normalizedFullPath = Get-NormalizedPath -Path $FullPath
    return $normalizedFullPath.Substring($normalizedRoot.Length).TrimStart('\')
}

function Copy-ItemMerged {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $item = Get-Item -LiteralPath $SourcePath -Force
    if ($item.PSIsContainer) {
        Ensure-Directory -Path $DestinationPath
        foreach ($child in Get-ChildItem -LiteralPath $SourcePath -Force) {
            Copy-ItemMerged -SourcePath $child.FullName -DestinationPath (Join-Path $DestinationPath $child.Name)
        }
        return
    }

    Ensure-Directory -Path (Split-Path -Parent $DestinationPath)
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Sync-DirectoryMirror {
    <#
    .SYNOPSIS
    将源目录内容镜像到目标目录。
    .PARAMETER SourcePath
    源目录。
    .PARAMETER TargetPath
    目标目录。
    .PARAMETER RemoveExtras
    是否删除目标目录中源目录不存在的额外条目。
    .OUTPUTS
    None。
    #>
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [bool]$RemoveExtras = $true
    )

    Ensure-Directory -Path $TargetPath

    foreach ($sourceDir in Get-ChildItem -LiteralPath $SourcePath -Recurse -Directory -Force) {
        $relative = Get-RelativePath -RootPath $SourcePath -FullPath $sourceDir.FullName
        Ensure-Directory -Path (Join-Path $TargetPath $relative)
    }

    foreach ($sourceFile in Get-ChildItem -LiteralPath $SourcePath -Recurse -File -Force) {
        $relative = Get-RelativePath -RootPath $SourcePath -FullPath $sourceFile.FullName
        $targetFile = Join-Path $TargetPath $relative
        Ensure-Directory -Path (Split-Path -Parent $targetFile)
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetFile -Force
    }

    if (-not $RemoveExtras) {
        return
    }

    $targetItems = Get-ChildItem -LiteralPath $TargetPath -Recurse -Force | Sort-Object FullName -Descending
    foreach ($targetItem in $targetItems) {
        $relative = Get-RelativePath -RootPath $TargetPath -FullPath $targetItem.FullName
        $sourceItem = Join-Path $SourcePath $relative
        if (Test-Path -LiteralPath $sourceItem) {
            continue
        }

        Remove-PathIfExists -Path $targetItem.FullName
    }
}

function Repair-NestedSelfNamedDirectories {
    param([string]$RootPath)

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return
    }

    foreach ($childDir in Get-ChildItem -LiteralPath $RootPath -Directory -Force) {
        Repair-NestedSelfNamedDirectories -RootPath $childDir.FullName
    }

    $selfName = Split-Path -Leaf $RootPath
    if ([string]::IsNullOrWhiteSpace($selfName)) {
        return
    }

    $duplicatePath = Join-Path $RootPath $selfName
    if (-not (Test-Path -LiteralPath $duplicatePath -PathType Container)) {
        return
    }

    foreach ($child in Get-ChildItem -LiteralPath $duplicatePath -Force) {
        Copy-ItemMerged -SourcePath $child.FullName -DestinationPath (Join-Path $RootPath $child.Name)
    }

    Remove-PathIfExists -Path $duplicatePath
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Save-InstallManifestSnapshot {
    if ([string]::IsNullOrWhiteSpace($script:ManifestPath)) {
        return
    }

    Write-Utf8NoBom -Path $script:ManifestPath -Content (ConvertTo-ManifestJsonDocument -Value $script:Manifest)
}

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8
}

function Get-ExistingNewlineStyle {
    param([string]$Content)

    if ($null -eq $Content) {
        return "`r`n"
    }

    if ($Content.Contains("`r`n")) {
        return "`r`n"
    }

    if ($Content.Contains("`n")) {
        return "`n"
    }

    return "`r`n"
}

function Ensure-WorkspaceGitIgnoreEntries {
    param([string]$WorkspaceRoot)

    $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
    $requiredEntries = @(
        '.assistant/',
        'AGENTS.md',
        'GEMINI.md',
        '.claude'
    )
    $managedComment = '# claude-dev-harness workspace artifacts'

    $existingContent = Read-FileUtf8 -Path $gitIgnorePath
    $existingLines = if ($null -eq $existingContent) {
        @()
    } else {
        [regex]::Split($existingContent, '\r?\n')
    }

    $normalizedLines = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $existingLines) {
        [void]$normalizedLines.Add($line.Trim())
    }

    $missingEntries = @(
        $requiredEntries | Where-Object { -not $normalizedLines.Contains($_) }
    )
    if ($missingEntries.Count -eq 0) {
        return
    }

    Backup-IfNeeded -Path $gitIgnorePath

    $newline = Get-ExistingNewlineStyle -Content $existingContent
    $appendedLines = New-Object System.Collections.Generic.List[string]
    if (-not $normalizedLines.Contains($managedComment)) {
        [void]$appendedLines.Add($managedComment)
    }
    foreach ($entry in $missingEntries) {
        [void]$appendedLines.Add($entry)
    }

    $trimmedExisting = if ($null -eq $existingContent) {
        ''
    } else {
        $existingContent.TrimEnd([char[]]@("`r", "`n"))
    }

    $updatedContent = if ([string]::IsNullOrWhiteSpace($trimmedExisting)) {
        ($appendedLines -join $newline) + $newline
    } else {
        $trimmedExisting + $newline + $newline + ($appendedLines -join $newline) + $newline
    }

    Write-Utf8NoBom -Path $gitIgnorePath -Content $updatedContent
}

function ConvertTo-NormalizedObject {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[$key] = ConvertTo-NormalizedObject -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [string] -or $Value -is [ValueType]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-NormalizedObject -Value $item))
        }
        return $items
    }

    $result = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $result[$property.Name] = ConvertTo-NormalizedObject -Value $property.Value
    }
    return $result
}

function Read-JsonObject {
    param([string]$Path)

    $raw = Read-FileUtf8 -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    return ConvertTo-NormalizedObject -Value ($script:JsonSerializer.DeserializeObject($raw))
}

function ConvertTo-JsonDocument {
    param($Value)

    return (ConvertTo-NormalizedObject -Value $Value | ConvertTo-Json -Depth 100)
}

function ConvertTo-ManifestJsonDocument {
    param($Value)

    return (ConvertTo-NormalizedObject -Value $Value | ConvertTo-Json -Depth 50)
}

function Merge-DeepObject {
    param(
        $Base,
        $Overlay
    )

    if ($null -eq $Base) {
        return ConvertTo-NormalizedObject -Value $Overlay
    }
    if ($null -eq $Overlay) {
        return ConvertTo-NormalizedObject -Value $Base
    }

    if (($Base -is [System.Collections.IDictionary]) -and ($Overlay -is [System.Collections.IDictionary])) {
        $merged = [ordered]@{}
        foreach ($key in $Base.Keys) {
            $merged[$key] = ConvertTo-NormalizedObject -Value $Base[$key]
        }
        foreach ($key in $Overlay.Keys) {
            if ($merged.Contains($key)) {
                $merged[$key] = Merge-DeepObject -Base $merged[$key] -Overlay $Overlay[$key]
            } else {
                $merged[$key] = ConvertTo-NormalizedObject -Value $Overlay[$key]
            }
        }
        return $merged
    }

    if (($Base -is [System.Collections.IEnumerable]) -and ($Overlay -is [System.Collections.IEnumerable]) -and
        -not ($Base -is [string]) -and -not ($Overlay -is [string])) {
        return ConvertTo-NormalizedObject -Value $Overlay
    }

    return ConvertTo-NormalizedObject -Value $Overlay
}

function Merge-UniqueArray {
    param(
        $Left,
        $Right
    )

    $result = New-Object System.Collections.ArrayList
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($item in @($Left) + @($Right)) {
        if ($null -eq $item) {
            continue
        }

        $key = if ($item -is [string]) {
            "s:$item"
        } else {
            ConvertTo-Json -InputObject $item -Compress -Depth 50
        }

        if ($seen.Add($key)) {
            [void]$result.Add((ConvertTo-NormalizedObject -Value $item))
        }
    }

    return $result
}

function Ensure-ArrayValue {
    param($Value)

    $items = New-Object System.Collections.ArrayList

    if ($null -eq $Value) {
        return $items
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-NormalizedObject -Value $item))
        }
        return $items
    }

    [void]$items.Add((ConvertTo-NormalizedObject -Value $Value))
    return $items
}

function Normalize-SettingsShape {
    param($Settings)

    if ($null -eq $Settings -or -not ($Settings -is [System.Collections.IDictionary])) {
        return $Settings
    }

    if ($Settings.Contains('permissions') -and ($Settings['permissions'] -is [System.Collections.IDictionary])) {
        $permissions = ConvertTo-NormalizedObject -Value $Settings['permissions']
        if ($permissions.Contains('allow')) {
            $permissions['allow'] = Ensure-ArrayValue -Value $permissions['allow']
        }
        $Settings['permissions'] = $permissions
    }

    foreach ($key in @('UserPromptSubmit', 'Stop', 'PostToolUse')) {
        if (-not $Settings.Contains($key)) {
            continue
        }

        $sections = Ensure-ArrayValue -Value $Settings[$key]
        foreach ($section in $sections) {
            if ($section -is [System.Collections.IDictionary] -and $section.Contains('hooks')) {
                $section['hooks'] = Ensure-ArrayValue -Value $section['hooks']
            }
        }
        $Settings[$key] = $sections
    }

    return $Settings
}

function Merge-SettingsLocal {
    param(
        $Shared,
        $Existing,
        $Overlay
    )

    $sharedObject = ConvertTo-NormalizedObject -Value $Shared
    $existingObject = ConvertTo-NormalizedObject -Value $Existing
    $overlayObject = ConvertTo-NormalizedObject -Value $Overlay

    $userMerged = Merge-DeepObject -Base $existingObject -Overlay $overlayObject
    $result = ConvertTo-NormalizedObject -Value $userMerged

    if ($null -eq $result -or -not ($result -is [System.Collections.IDictionary])) {
        $result = [ordered]@{}
    }

    foreach ($key in $sharedObject.Keys) {
        if ($key -eq 'permissions') {
            $permissions = if ($result.Contains('permissions') -and ($result['permissions'] -is [System.Collections.IDictionary])) {
                ConvertTo-NormalizedObject -Value $result['permissions']
            } else {
                [ordered]@{}
            }

            $sharedPermissions = ConvertTo-NormalizedObject -Value $sharedObject['permissions']
            $mergedPermissions = Merge-DeepObject -Base $permissions -Overlay $sharedPermissions

            $existingAllow = if ($permissions.Contains('allow')) { $permissions['allow'] } else { @() }
            $sharedAllow = if ($sharedPermissions.Contains('allow')) { $sharedPermissions['allow'] } else { @() }
            $mergedPermissions['allow'] = Ensure-ArrayValue -Value (Merge-UniqueArray -Left $existingAllow -Right $sharedAllow)

            $result['permissions'] = $mergedPermissions
            continue
        }

        $result[$key] = ConvertTo-NormalizedObject -Value $sharedObject[$key]
    }

    return (Normalize-SettingsShape -Settings $result)
}

function Get-RenderTokenMap {
    param([switch]$EscapeForCode)

    $tokens = [ordered]@{}
    foreach ($key in $script:RawRenderTokens.Keys) {
        $value = $script:RawRenderTokens[$key]
        if ($EscapeForCode -and $key -ne '__RENDER_AT_INSTALL__') {
            $value = $value.Replace('\', '\\')
        }
        $tokens[$key] = $value
    }

    return $tokens
}

function Render-Content {
    param(
        [string]$Content,
        [string]$TargetPath
    )

    $extension = [System.IO.Path]::GetExtension($TargetPath).ToLowerInvariant()
    $tokens = if ($extension -in @('.json', '.js', '.mjs', '.toml')) {
        Get-RenderTokenMap -EscapeForCode
    } else {
        Get-RenderTokenMap
    }

    $rendered = $Content
    foreach ($key in $tokens.Keys) {
        $rendered = $rendered.Replace($key, $tokens[$key])
    }

    return $rendered
}

function Install-RenderedFile {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [switch]$SkipIfExists
    )

    if ($SkipIfExists -and (Test-Path -LiteralPath $TargetPath)) {
        return
    }

    $raw = Read-FileUtf8 -Path $SourcePath
    if ($null -eq $raw) {
        throw "Missing template source: $SourcePath"
    }

    $rendered = Render-Content -Content $raw -TargetPath $TargetPath
    Write-Utf8NoBom -Path $TargetPath -Content $rendered
}

function Read-RenderedJsonTemplate {
    param(
        [string]$TemplatePath,
        [string]$TargetPath
    )

    $raw = Read-FileUtf8 -Path $TemplatePath
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    $rendered = Render-Content -Content $raw -TargetPath $TargetPath
    return ConvertTo-NormalizedObject -Value ($script:JsonSerializer.DeserializeObject($rendered))
}

function Render-JsonTemplateText {
    param(
        [string]$TemplatePath,
        [string]$TargetPath
    )

    $raw = Read-FileUtf8 -Path $TemplatePath
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return '{}'
    }

    return (Render-Content -Content $raw -TargetPath $TargetPath)
}

function Merge-SettingsLocalJsonText {
    param(
        [string]$RenderedSharedJson,
        [string]$ExistingPath,
        [string]$OverlayPath
    )

    $tempDir = Join-Path $script:BackupRoot '_settings-merge'
    Ensure-Directory -Path $tempDir

    $sharedPath = Join-Path $tempDir 'shared.json'
    $existingTempPath = Join-Path $tempDir 'existing.json'
    $overlayTempPath = Join-Path $tempDir 'overlay.json'
    $scriptPath = Join-Path $tempDir 'merge-settings.cjs'

    $existingJson = Read-FileUtf8 -Path $ExistingPath
    if ([string]::IsNullOrWhiteSpace($existingJson)) {
        $existingJson = '{}'
    }
    $overlayJson = Read-FileUtf8 -Path $OverlayPath
    if ([string]::IsNullOrWhiteSpace($overlayJson)) {
        $overlayJson = '{}'
    }

    Write-Utf8NoBom -Path $sharedPath -Content $RenderedSharedJson
    Write-Utf8NoBom -Path $existingTempPath -Content $existingJson
    Write-Utf8NoBom -Path $overlayTempPath -Content $overlayJson
    Write-Utf8NoBom -Path $scriptPath -Content @'
const fs = require("fs");

const [sharedPath, existingPath, overlayPath] = process.argv.slice(2);

function readJson(path) {
  if (!path || !fs.existsSync(path)) return {};
  const raw = fs.readFileSync(path, "utf8").trim();
  return raw ? JSON.parse(raw) : {};
}

function isObject(value) {
  return value && typeof value === "object" && !Array.isArray(value);
}

function asArray(value) {
  if (value == null) return [];
  return Array.isArray(value) ? value : [value];
}

function uniqueArray(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const key = typeof value === "string" ? `s:${value}` : JSON.stringify(value);
    if (!seen.has(key)) {
      seen.add(key);
      result.push(value);
    }
  }
  return result;
}

function mergeDeep(base, overlay) {
  if (Array.isArray(base) && Array.isArray(overlay)) {
    return overlay.slice();
  }
  if (isObject(base) && isObject(overlay)) {
    const result = { ...base };
    for (const [key, value] of Object.entries(overlay)) {
      result[key] = key in result ? mergeDeep(result[key], value) : value;
    }
    return result;
  }
  return overlay;
}

const shared = readJson(sharedPath);
const existing = readJson(existingPath);
const overlay = readJson(overlayPath);

const result = mergeDeep(existing, overlay);

const permissions = mergeDeep(result.permissions || {}, shared.permissions || {});
permissions.allow = uniqueArray([
  ...asArray(result.permissions && result.permissions.allow),
  ...asArray(shared.permissions && shared.permissions.allow),
]);
if (permissions.allow.length > 0 || Object.keys(permissions).length > 0) {
  result.permissions = permissions;
}

for (const [key, value] of Object.entries(shared)) {
  if (key === "permissions") continue;
  result[key] = value;
}

for (const key of ["UserPromptSubmit", "Stop", "PostToolUse"]) {
  if (!(key in result)) continue;
  result[key] = asArray(result[key]);
  for (const entry of result[key]) {
    if (isObject(entry) && "hooks" in entry) {
      entry.hooks = asArray(entry.hooks);
    }
  }
}

if (result.permissions && "allow" in result.permissions) {
  result.permissions.allow = asArray(result.permissions.allow);
}

process.stdout.write(JSON.stringify(result, null, 2));
'@

    $mergedOutput = @(& node $scriptPath $sharedPath $existingTempPath $overlayTempPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("Failed to merge settings.local.json via node: {0}" -f ($mergedOutput -join "`n"))
    }

    return ($mergedOutput -join "`n")
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

    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }

    return Get-NormalizedPath -Path $target
}

function Backup-IfNeeded {
    param([string]$Path)

    if (-not $script:BackedUpPaths.Add($Path)) {
        return
    }

    $record = [ordered]@{
        path = $Path
        existed = (Test-Path -LiteralPath $Path)
        backup_path = $null
        item_type = 'missing'
        link_type = $null
        link_target = $null
    }

    if ($record.existed) {
        $item = Get-Item -LiteralPath $Path -Force
        $isReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)

        if ($isReparsePoint) {
            $target = $item.Target
            if ($target -is [System.Array]) {
                $target = $target[0]
            }

            $record.item_type = 'link'
            $record.link_type = if ([string]::IsNullOrWhiteSpace($item.LinkType)) {
                if ($item.PSIsContainer) { 'Junction' } else { 'SymbolicLink' }
            } else {
                $item.LinkType
            }
            $record.link_target = $target
        } else {
            $record.item_type = if ($item.PSIsContainer) { 'directory' } else { 'file' }
            $safeName = ($Path -replace '[:\\\/]+', '_').Trim('_')
            $backupPath = Join-Path $script:BackupRoot $safeName
            Ensure-Directory -Path (Split-Path -Parent $backupPath)
            Copy-Item -LiteralPath $Path -Destination $backupPath -Recurse -Force
            $record.backup_path = $backupPath
        }
    }

    $script:Manifest.backups += $record
    Save-InstallManifestSnapshot
}

function Ensure-Junction {
    param(
        [string]$LinkPath,
        [string]$TargetPath
    )

    $currentTarget = Get-JunctionTarget -Path $LinkPath
    if ($currentTarget -eq (Get-NormalizedPath -Path $TargetPath)) {
        return
    }

    Backup-IfNeeded -Path $LinkPath
    Remove-PathIfExists -Path $LinkPath
    Ensure-Directory -Path (Split-Path -Parent $LinkPath)
    New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
}

function Get-PreservedSkillEntryNames {
    param(
        [string]$SkillsRoot,
        [string[]]$ManagedEntryNames,
        [string]$RepoSkillsPath
    )

    $managedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $ManagedEntryNames) {
        [void]$managedSet.Add($name)
    }

    $normalizedRepoSkillsPath = Get-NormalizedPath -Path $RepoSkillsPath
    $preserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $legacyRemovedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$legacyRemovedNames.Add('docs')
    if (-not (Test-Path -LiteralPath $SkillsRoot -PathType Container)) {
        return ,$preserved
    }

    foreach ($entry in Get-ChildItem -LiteralPath $SkillsRoot -Force) {
        if ($managedSet.Contains($entry.Name)) {
            continue
        }

        if ($legacyRemovedNames.Contains($entry.Name)) {
            continue
        }

        $entryTarget = Get-JunctionTarget -Path $entry.FullName
        $isStaleHarnessLink = $false
        if (-not [string]::IsNullOrWhiteSpace($entryTarget) -and -not [string]::IsNullOrWhiteSpace($normalizedRepoSkillsPath)) {
            $isStaleHarnessLink = $entryTarget.Equals($normalizedRepoSkillsPath, [System.StringComparison]::OrdinalIgnoreCase) -or
                $entryTarget.StartsWith($normalizedRepoSkillsPath + '\', [System.StringComparison]::OrdinalIgnoreCase)
        }

        if (-not $isStaleHarnessLink) {
            [void]$preserved.Add($entry.Name)
        }
    }

    return ,$preserved
}

function Sync-SkillsDirectory {
    param(
        [string]$HostSkillsPath,
        [string]$RepoSkillsPath
    )

    $hotSwapPreservedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$hotSwapPreservedNames.Add('.system')

    $rootTarget = Get-JunctionTarget -Path $HostSkillsPath
    if ($null -ne $rootTarget) {
        Backup-IfNeeded -Path $HostSkillsPath
        Remove-PathIfExists -Path $HostSkillsPath
    }

    Ensure-Directory -Path $HostSkillsPath

    $managedEntries = [ordered]@{}
    foreach ($entry in Get-ChildItem -LiteralPath $RepoSkillsPath -Force) {
        $managedEntries[$entry.Name] = $entry.FullName
    }

    $preservedNames = Get-PreservedSkillEntryNames -SkillsRoot $HostSkillsPath -ManagedEntryNames $managedEntries.Keys -RepoSkillsPath $RepoSkillsPath

    foreach ($entry in Get-ChildItem -LiteralPath $HostSkillsPath -Force) {
        $currentTarget = Get-JunctionTarget -Path $entry.FullName
        $shouldPreserveForHotSwap = $hotSwapPreservedNames.Contains($entry.Name) -and ($null -eq $currentTarget)
        if ($preservedNames.Contains($entry.Name) -or $shouldPreserveForHotSwap) {
            continue
        }

        $expectedTarget = if ($managedEntries.Contains($entry.Name)) {
            Get-NormalizedPath -Path $managedEntries[$entry.Name]
        } else {
            $null
        }

        if (($null -ne $expectedTarget) -and ($currentTarget -eq $expectedTarget)) {
            continue
        }

        Backup-IfNeeded -Path $entry.FullName
        Remove-PathIfExists -Path $entry.FullName
    }

    foreach ($name in $managedEntries.Keys) {
        $linkPath = Join-Path $HostSkillsPath $name
        if ($hotSwapPreservedNames.Contains($name) -and (Test-Path -LiteralPath $linkPath) -and ($null -eq (Get-JunctionTarget -Path $linkPath))) {
            if ($name -eq '.system') {
                Sync-DirectoryMirror -SourcePath $managedEntries[$name] -TargetPath $linkPath -RemoveExtras:$false
            }
            continue
        }

        Ensure-Junction -LinkPath $linkPath -TargetPath $managedEntries[$name]
    }
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

function Get-ManagedSkillPathsFromTomlContent {
    param([string]$Content)

    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @()
    }

    foreach ($line in ($Content -split "`r?`n")) {
        $path = Get-TomlQuotedPathValue -Line $line
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            [void]$paths.Add($path)
        }
    }

    return @($paths)
}

function Remove-ManagedSkillsConfigBlocks {
    param(
        [string]$Content,
        [string[]]$ManagedSkillPaths
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ""
    }

    $managedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ManagedSkillPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            [void]$managedSet.Add((Get-NormalizedPath -Path $path))
        }
    }

    if ($managedSet.Count -eq 0) {
        return $Content.Trim()
    }

    $lines = $Content -split "`r?`n"
    $result = New-Object System.Collections.Generic.List[string]

    for ($index = 0; $index -lt $lines.Count;) {
        $line = $lines[$index]
        if ($line -notmatch '^\[\[skills\.config\]\]\s*$') {
            $result.Add($line)
            $index += 1
            continue
        }

        $block = New-Object System.Collections.Generic.List[string]
        $block.Add($line)
        $index += 1

        while ($index -lt $lines.Count -and $lines[$index] -notmatch '^\[') {
            $block.Add($lines[$index])
            $index += 1
        }

        $blockPath = $null
        foreach ($blockLine in $block) {
            $blockPath = Get-TomlQuotedPathValue -Line $blockLine
            if (-not [string]::IsNullOrWhiteSpace($blockPath)) {
                break
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($blockPath) -and $managedSet.Contains($blockPath)) {
            continue
        }

        foreach ($blockLine in $block) {
            $result.Add($blockLine)
        }
    }

    return ($result -join "`r`n").Trim()
}

function Remove-ManagedTomlBlock {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return ""
    }

    $pattern = '(?ms)^\# >>> claude-dev-harness managed block >>>\r?\n.*?^\# <<< claude-dev-harness managed block <<<\r?\n?'
    return ([regex]::Replace($Content, $pattern, '')).Trim()
}

function Update-CodexConfig {
    param(
        [string]$TemplatePath,
        [string]$TargetPath
    )

    $existing = Read-FileUtf8 -Path $TargetPath
    $renderedManaged = Render-Content -Content (Read-FileUtf8 -Path $TemplatePath) -TargetPath $TargetPath
    $managedSkillPaths = Get-ManagedSkillPathsFromTomlContent -Content $renderedManaged
    $managedBlock = @(
        '# >>> claude-dev-harness managed block >>>'
        $renderedManaged.Trim()
        '# <<< claude-dev-harness managed block <<<'
    ) -join "`r`n"

    $sanitized = Remove-ManagedTomlBlock -Content $existing
    $sanitized = Remove-ManagedSkillsConfigBlocks -Content $sanitized -ManagedSkillPaths $managedSkillPaths

    $newContent = if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $managedBlock + "`r`n"
    } else {
        $sanitized.TrimEnd() + "`r`n`r`n" + $managedBlock + "`r`n"
    }

    Backup-IfNeeded -Path $TargetPath
    Write-Utf8NoBom -Path $TargetPath -Content $newContent
}

function Merge-SystemSkills {
    param(
        [string[]]$SourceRoots,
        [string]$TargetPath
    )

    $existingTarget = if (Test-Path -LiteralPath $TargetPath) { Get-NormalizedPath -Path $TargetPath } else { $null }
    $stagingPath = Join-Path $script:BackupRoot '_merged-system'
    $canonicalSystemPath = $null
    if ($SourceRoots.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($SourceRoots[0])) {
        $canonicalSystemPath = Get-NormalizedPath -Path (Join-Path $SourceRoots[0] '.system')
    }

    Remove-PathIfExists -Path $stagingPath
    Ensure-Directory -Path $stagingPath

    if (Test-Path -LiteralPath $TargetPath -PathType Container) {
        foreach ($child in Get-ChildItem -LiteralPath $TargetPath -Force) {
            Copy-ItemMerged -SourcePath $child.FullName -DestinationPath (Join-Path $stagingPath $child.Name)
        }
    }

    foreach ($sourceRoot in $SourceRoots) {
        if ([string]::IsNullOrWhiteSpace($sourceRoot)) {
            continue
        }

        $sourcePath = Join-Path $sourceRoot '.system'
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
            continue
        }

        $sourceNormalizedPath = Get-NormalizedPath -Path $sourcePath
        $sourceTarget = Get-JunctionTarget -Path $sourcePath
        if ($existingTarget -and (($sourceNormalizedPath -eq $existingTarget) -or ($sourceTarget -eq $existingTarget))) {
            continue
        }

        try {
            $children = Get-ChildItem -LiteralPath $sourcePath -Force -ErrorAction Stop
        } catch {
            continue
        }

        foreach ($child in $children) {
            $destination = Join-Path $stagingPath $child.Name
            $shouldPreserveCanonicalChild = -not [string]::IsNullOrWhiteSpace($canonicalSystemPath) -and
                ($sourceNormalizedPath -ne $canonicalSystemPath) -and
                (Test-Path -LiteralPath $destination)
            if ($shouldPreserveCanonicalChild) {
                continue
            }

            Copy-ItemMerged -SourcePath $child.FullName -DestinationPath $destination
        }
    }

    if ((Get-ChildItem -LiteralPath $stagingPath -Force | Measure-Object).Count -eq 0) {
        if (Test-Path -LiteralPath $TargetPath -PathType Container) {
            Repair-NestedSelfNamedDirectories -RootPath $TargetPath
        }
        Remove-PathIfExists -Path $stagingPath
        return
    }

    Repair-NestedSelfNamedDirectories -RootPath $stagingPath
    Remove-PathIfExists -Path $TargetPath
    Ensure-Directory -Path (Split-Path -Parent $TargetPath)
    Move-Item -LiteralPath $stagingPath -Destination $TargetPath
    $script:Manifest.generated_repo_system_path = $TargetPath
    Save-InstallManifestSnapshot
}

function Install-VaultTemplate {
    param(
        [string]$TemplateRoot,
        [string]$TargetRoot
    )

    function Test-IsManagedVaultStaticPath {
        param([string]$RelativePath)

        if ([string]::IsNullOrWhiteSpace($RelativePath)) {
            return $false
        }

        if ($RelativePath -like '运行时\*') {
            return $false
        }

        if ($RelativePath -ieq '.obsidian\workspace.json') {
            return $false
        }

        return $true
    }

    foreach ($source in Get-ChildItem -LiteralPath $TemplateRoot -Recurse -File) {
        $relative = $source.FullName.Substring($TemplateRoot.Length).TrimStart('\')
        $targetRelative = if ($relative.EndsWith('.template')) {
            $relative.Substring(0, $relative.Length - '.template'.Length)
        } else {
            $relative
        }
        $targetPath = Join-Path $TargetRoot $targetRelative
        $shouldOverwrite = (Test-Path -LiteralPath $targetPath) -and (Test-IsManagedVaultStaticPath -RelativePath $targetRelative)

        if ((Test-Path -LiteralPath $targetPath) -and -not $shouldOverwrite) {
            continue
        }

        $extension = [System.IO.Path]::GetExtension($source.FullName).ToLowerInvariant()
        if ($extension -in @('.template', '.md', '.json', '.js', '.mjs', '.toml', '.txt') -or $relative.EndsWith('.template')) {
            Install-RenderedFile -SourcePath $source.FullName -TargetPath $targetPath -SkipIfExists:(-not $shouldOverwrite)
            continue
        }

        if ($shouldOverwrite) {
            Remove-PathIfExists -Path $targetPath
        }
        Ensure-Directory -Path (Split-Path -Parent $targetPath)
        Copy-Item -LiteralPath $source.FullName -Destination $targetPath -Force
    }
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is required for install.ps1'
}

$RepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $RepoRoot
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$WorkspaceRoot = Get-NormalizedPath -Path $WorkspaceRoot
$VaultPath = Join-Path $WorkspaceRoot '.assistant'
$ClaudeHome = Join-Path $env:USERPROFILE '.claude'
$CodexHome = Join-Path $env:USERPROFILE '.codex'
$GeminiHome = Join-Path $env:USERPROFILE '.gemini'
$RepoSkillsPath = Join-Path $RepoRoot 'skills'
$BackupRoot = Join-Path $RepoRoot ('backups\install-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$PID")

Ensure-Directory -Path $BackupRoot

$script:RawRenderTokens = [ordered]@{
    '{REPO_ROOT}' = $RepoRoot
    '{WORKSPACE_ROOT}' = $WorkspaceRoot
    '{VAULT_PATH}' = $VaultPath
    '{CLAUDE_HOME}' = $ClaudeHome
    '{CODEX_HOME}' = $CodexHome
    '{GEMINI_HOME}' = $GeminiHome
    '__RENDER_AT_INSTALL__' = (Get-Date -Format 'yyyy-MM-dd')
}
$script:BackupRoot = $BackupRoot
$script:BackedUpPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:Manifest = [ordered]@{
    installed_at = (Get-Date -Format 's')
    repo_root = $RepoRoot
    workspace_root = $WorkspaceRoot
    vault_path = $VaultPath
    claude_home = $ClaudeHome
    codex_home = $CodexHome
    gemini_home = $GeminiHome
    backup_root = $BackupRoot
    generated_repo_system_path = $null
    backups = @()
}
$script:ManifestPath = Join-Path $BackupRoot 'install-manifest.json'

$claudeSkillsPath = Join-Path $ClaudeHome 'skills'
$codexSkillsPath = Join-Path $CodexHome 'skills'
$claudeHooksPath = Join-Path $ClaudeHome 'hooks-memory'
$claudeSettingsDir = Join-Path $ClaudeHome '.claude'
$codexSettingsDir = Join-Path $CodexHome '.claude'
$claudeSettingsPath = Join-Path $claudeSettingsDir 'settings.local.json'
$codexSettingsPath = Join-Path $codexSettingsDir 'settings.local.json'
$claudeOverlayPath = Join-Path $claudeSettingsDir 'settings.local.user.json'
$codexOverlayPath = Join-Path $codexSettingsDir 'settings.local.user.json'
$codexConfigPath = Join-Path $CodexHome 'config.toml'
$claudeGlobalPath = Join-Path $ClaudeHome 'CLAUDE.md'
$codexGlobalPath = Join-Path $CodexHome 'AGENTS.md'
$workspaceAgentsPath = Join-Path $WorkspaceRoot 'AGENTS.md'
$workspaceGeminiPath = Join-Path $WorkspaceRoot 'GEMINI.md'

try {
    Ensure-Directory -Path $ClaudeHome
    Ensure-Directory -Path $CodexHome
    Ensure-Directory -Path $claudeSettingsDir
    Ensure-Directory -Path $codexSettingsDir
    Ensure-Directory -Path $WorkspaceRoot
    Ensure-Directory -Path $RepoSkillsPath

    Save-InstallManifestSnapshot

    Ensure-Directory -Path (Join-Path $RepoSkillsPath '.system')
    Ensure-WorkspaceGitIgnoreEntries -WorkspaceRoot $WorkspaceRoot

    Install-VaultTemplate -TemplateRoot (Join-Path $RepoRoot 'vault-template') -TargetRoot $VaultPath

    Backup-IfNeeded -Path $claudeGlobalPath
    Install-RenderedFile -SourcePath (Join-Path $RepoRoot 'agent-configs\claude\CLAUDE.md.template') -TargetPath $claudeGlobalPath

    Backup-IfNeeded -Path $codexGlobalPath
    Install-RenderedFile -SourcePath (Join-Path $RepoRoot 'agent-configs\codex\AGENTS.md.template') -TargetPath $codexGlobalPath

    Backup-IfNeeded -Path $workspaceAgentsPath
    Install-RenderedFile -SourcePath (Join-Path $RepoRoot 'agent-configs\workspace\AGENTS.md.template') -TargetPath $workspaceAgentsPath

    Backup-IfNeeded -Path $workspaceGeminiPath
    Install-RenderedFile -SourcePath (Join-Path $RepoRoot 'agent-configs\workspace\GEMINI.md.template') -TargetPath $workspaceGeminiPath

    Backup-IfNeeded -Path $claudeHooksPath
    Remove-PathIfExists -Path $claudeHooksPath
    Ensure-Directory -Path $claudeHooksPath
    foreach ($hook in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'runtime-hooks\claude') -File) {
        Install-RenderedFile -SourcePath $hook.FullName -TargetPath (Join-Path $claudeHooksPath $hook.Name)
    }

    $claudeSharedSettingsJson = Render-JsonTemplateText -TemplatePath (Join-Path $RepoRoot 'agent-configs\claude\settings.local.shared.json.template') -TargetPath $claudeSettingsPath
    $claudeMergedSettingsJson = Merge-SettingsLocalJsonText -RenderedSharedJson $claudeSharedSettingsJson -ExistingPath $claudeSettingsPath -OverlayPath $claudeOverlayPath
    Backup-IfNeeded -Path $claudeSettingsPath
    Write-Utf8NoBom -Path $claudeSettingsPath -Content $claudeMergedSettingsJson

    $codexSharedSettingsJson = Render-JsonTemplateText -TemplatePath (Join-Path $RepoRoot 'agent-configs\codex\settings.local.shared.json.template') -TargetPath $codexSettingsPath
    $codexMergedSettingsJson = Merge-SettingsLocalJsonText -RenderedSharedJson $codexSharedSettingsJson -ExistingPath $codexSettingsPath -OverlayPath $codexOverlayPath
    Backup-IfNeeded -Path $codexSettingsPath
    Write-Utf8NoBom -Path $codexSettingsPath -Content $codexMergedSettingsJson

    Update-CodexConfig -TemplatePath (Join-Path $RepoRoot 'agent-configs\codex\config.shared.toml.template') -TargetPath $codexConfigPath

    Sync-SkillsDirectory -HostSkillsPath $claudeSkillsPath -RepoSkillsPath $RepoSkillsPath
    Sync-SkillsDirectory -HostSkillsPath $codexSkillsPath -RepoSkillsPath $RepoSkillsPath

    Save-InstallManifestSnapshot
    Write-Utf8NoBom -Path (Join-Path (Join-Path $RepoRoot 'backups') 'active-install.json') -Content (ConvertTo-ManifestJsonDocument -Value ([ordered]@{
        manifest_path = $script:ManifestPath
        repo_root = $RepoRoot
        workspace_root = $WorkspaceRoot
        vault_path = $VaultPath
        installed_at = $script:Manifest.installed_at
    }))

    Write-Output 'Install summary:'
    Write-Output ('- repo_root: {0}' -f $RepoRoot)
    Write-Output ('- workspace_root: {0}' -f $WorkspaceRoot)
    Write-Output ('- vault_path: {0}' -f $VaultPath)
    Write-Output ('- claude_skills_root: {0}' -f $claudeSkillsPath)
    Write-Output ('- codex_skills_root: {0}' -f $codexSkillsPath)
    Write-Output ('- managed_skill_source: {0}' -f $RepoSkillsPath)
    Write-Output ('- backup_root: {0}' -f $BackupRoot)
    Write-Output ''
    Write-Output 'Manual follow-up:'
    Write-Output ('- Review optional overlay files: {0} / {1}' -f $claudeOverlayPath, $codexOverlayPath)
    Write-Output ('- Run: {0}' -f (Join-Path $RepoRoot 'tests\verify-installation.ps1'))
} catch {
    Save-InstallManifestSnapshot
    $rootCause = if ($_.Exception) { $_.Exception.Message } else { 'unknown error' }
    $recoveryMessage = if (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf) {
        "Install failed after writing recovery manifest: $($script:ManifestPath)`nRoot cause: $rootCause"
    } else {
        "Install failed before recovery manifest snapshot could be written.`nRoot cause: $rootCause"
    }
    Write-Error $recoveryMessage
    throw
}
