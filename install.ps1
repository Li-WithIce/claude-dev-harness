[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [string]$RepoRoot = "",
    [ValidateSet('core', 'governed', 'full')]
    [string]$Preset = '',
    [ValidateSet('auto', 'minimal', 'full')]
    [string]$VaultProfile = 'auto',
    [switch]$RebaselineLegacyInstallState,
    [string]$ExpectedRebaselinePlanDigest = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$presetSpecified = $PSBoundParameters.ContainsKey('Preset')
$vaultProfileSpecified = $PSBoundParameters.ContainsKey('VaultProfile')
if ($presetSpecified -and $vaultProfileSpecified -and $VaultProfile -ne 'auto') {
    $mappedPreset = if ($VaultProfile -eq 'full') { 'full' } else { 'core' }
    if ($Preset -ne $mappedPreset) {
        throw "Preset '$Preset' conflicts with VaultProfile '$VaultProfile' (maps to '$mappedPreset')"
    }
}

. (Join-Path $PSScriptRoot 'scripts\install-transaction-common.ps1')

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

function Save-InstallManifestSnapshot {
    if ([string]::IsNullOrWhiteSpace($script:ManifestPath)) {
        return
    }

    Write-InstallStateTextAtomic -Path $script:ManifestPath -Content (ConvertTo-ManifestJsonDocument -Value $script:Manifest)
}

function Write-ManagedInstallText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
        [switch]$RecordBackup,
        [ValidateSet('managed', 'create-if-missing', 'user-owned')][string]$Ownership = 'managed',
        $ExpectedCurrentIdentity
    )

    $sourceIdentity = if ($null -eq $ExpectedCurrentIdentity) {
        Get-InstallManagedPathIdentity -Path $Path
    } else {
        Assert-InstallExpectedPostimageShape -Identity $ExpectedCurrentIdentity -Label "Expected current identity for $Path"
        if ([string]$ExpectedCurrentIdentity['mode'] -ne 'exact' -or
            [string]$ExpectedCurrentIdentity['item_type'] -notin @('missing','file')) {
            throw "Managed text expected current identity must be missing or file: $Path"
        }
        if (-not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $Path) -Right $ExpectedCurrentIdentity)) {
            throw "Managed text target changed from its expected current identity: $Path"
        }
        $ExpectedCurrentIdentity
    }
    $desiredIdentity = New-InstallExactFileIdentity -Content $Content
    if ($RecordBackup) { Backup-IfNeeded -Path $Path -Ownership $Ownership -ExpectedPostimage $desiredIdentity }
    if ([string]$sourceIdentity['item_type'] -in @('missing','file')) {
        Write-InstallStateTextAtomic -Path $Path -Content $Content -ExpectedCurrentDigest $(if ([string]$sourceIdentity['item_type'] -eq 'missing') { 'missing' } else { [string]$sourceIdentity['sha256'] })
        return
    }
    if (-not $RecordBackup) {
        throw "Managed text target is not a file and has no persisted backup: $Path"
    }
    [void](Invoke-InstallExactPathTransition `
        -Path $Path `
        -SourceIdentity $sourceIdentity `
        -DesiredIdentity $desiredIdentity `
        -MaterializeDesired { param($BuildPath) Write-InstallStateTextDurable -Path $BuildPath -Content $Content })
}

function Get-BackupSafeName {
    param([string]$Path)

    $safeName = ($Path -replace '[:\\\/]+', '_').Trim('_')
    if ($safeName.Length -le 80) {
        return $safeName
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Path))
    } finally {
        $sha.Dispose()
    }
    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').Substring(0, 16).ToLowerInvariant()
    return ("{0}_{1}" -f $safeName.Substring(0, 80).Trim('_'), $hash)
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
        '.claude'
    )
    $managedComment = '# dev-harness workspace artifacts'
    $legacyManagedComment = '# claude-dev-harness workspace artifacts'

    $existingSnapshot = Read-InstallTextSnapshot -Path $gitIgnorePath
    $existingContent = $existingSnapshot.Content
    $existingLines = if ($null -eq $existingContent) {
        @()
    } else {
        [regex]::Split($existingContent, '\r?\n')
    }

    $normalizedLines = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $existingLines) {
        [void]$normalizedLines.Add($line.Trim())
    }

    $hasManagedComment = $normalizedLines.Contains($managedComment)
    $hasLegacyManagedComment = $normalizedLines.Contains($legacyManagedComment)
    $missingEntries = @(
        $requiredEntries | Where-Object { -not $normalizedLines.Contains($_) }
    )
    $initialMissingEntries = @($missingEntries)
    if ($missingEntries.Count -eq 0 -and $hasManagedComment -and -not $hasLegacyManagedComment) {
        return
    }

    $newline = Get-ExistingNewlineStyle -Content $existingContent
    $workingContent = if ($null -eq $existingContent) { '' } else { $existingContent }
    if ($hasLegacyManagedComment) {
        if ($hasManagedComment) {
            $workingContent = [regex]::Replace($workingContent, '(?im)^\s*\# claude-dev-harness workspace artifacts\s*\r?\n?', '')
        } else {
            $workingContent = [regex]::Replace($workingContent, '(?im)^\s*\# claude-dev-harness workspace artifacts\s*$', $managedComment)
        }

        $existingLines = if ([string]::IsNullOrWhiteSpace($workingContent)) {
            @()
        } else {
            [regex]::Split($workingContent, '\r?\n')
        }
        $normalizedLines = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $existingLines) {
            [void]$normalizedLines.Add($line.Trim())
        }
        $missingEntries = @(
            $requiredEntries | Where-Object { -not $normalizedLines.Contains($_) }
        )
    }

    $missingManagedComment = -not $normalizedLines.Contains($managedComment)
    $appendedLines = New-Object System.Collections.Generic.List[string]
    if ($missingManagedComment) {
        [void]$appendedLines.Add($managedComment)
    }
    foreach ($entry in $missingEntries) {
        [void]$appendedLines.Add($entry)
    }

    $trimmedExisting = if ($null -eq $existingContent) {
        ''
    } else {
        $workingContent.TrimEnd([char[]]@("`r", "`n"))
    }

    $updatedContent = if ([string]::IsNullOrWhiteSpace($trimmedExisting)) {
        ($appendedLines -join $newline) + $newline
    } else {
        $trimmedExisting + $newline + $newline + ($appendedLines -join $newline) + $newline
    }

    $updatedLines = @([regex]::Split($updatedContent, '\r?\n'))
    $lineDelta = New-Object System.Collections.ArrayList
    $getLineCount = {
        param([string]$ExpectedLine)
        return @($updatedLines | Where-Object {
            $_.Trim().Equals($ExpectedLine, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count
    }
    if ($hasLegacyManagedComment) {
        if ($hasManagedComment) {
            [void]$lineDelta.Add([ordered]@{
                operation = 'remove'
                line = $legacyManagedComment
                expected_count = 0
            })
        } else {
            [void]$lineDelta.Add([ordered]@{
                operation = 'replace'
                from = $legacyManagedComment
                to = $managedComment
                expected_from_count = 0
                expected_to_count = (& $getLineCount $managedComment)
            })
        }
    } elseif (-not $hasManagedComment) {
        [void]$lineDelta.Add([ordered]@{
            operation = 'add'
            line = $managedComment
            expected_count = (& $getLineCount $managedComment)
        })
    }
    foreach ($entry in $initialMissingEntries) {
        [void]$lineDelta.Add([ordered]@{
            operation = 'add'
            line = $entry
            expected_count = (& $getLineCount $entry)
        })
    }
    $expectedPostimage = [ordered]@{
        mode = 'semantic'
        contract = 'workspace-gitignore/v1'
        line_delta = $lineDelta
    }
    Backup-IfNeeded -Path $gitIgnorePath -ExpectedPostimage $expectedPostimage
    Write-InstallStateTextAtomic `
        -Path $gitIgnorePath `
        -Content $updatedContent `
        -ExpectedCurrentDigest $(if ([string]$existingSnapshot.Identity['item_type'] -eq 'missing') { 'missing' } else { [string]$existingSnapshot.Identity['sha256'] })
}

function ConvertFrom-JsonDocument {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return [ordered]@{}
    }

    return ConvertTo-NormalizedObject -Value ($Json | ConvertFrom-Json)
}

function Read-JsonObject {
    param([string]$Path)

    $raw = Read-FileUtf8 -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    return ConvertFrom-JsonDocument -Json $raw
}

function ConvertTo-JsonDocument {
    param($Value)

    return (ConvertTo-Json -InputObject (ConvertTo-NormalizedObject -Value $Value) -Depth 100)
}

function ConvertTo-ManifestJsonDocument {
    param($Value)

    return (ConvertTo-Json -InputObject (ConvertTo-NormalizedObject -Value $Value) -Depth 50)
}

function New-InstallRegistry {
    return [ordered]@{
        schema_version = 'install-registry/v1.1'
        transaction_status_contract = 'v1'
        history_ownership_contract = 'v1'
        manifest_integrity_contract = 'sha256-v1'
        updated_at = (Get-Date -Format 's')
        workspaces = [ordered]@{}
        global_manifest_history = @()
        retired_manifest_history = @()
        manifest_digests = [ordered]@{}
    }
}

function Read-InstallRegistry {
    param([string]$Path)

    $registryExists = Test-Path -LiteralPath $Path
    $registry = Read-JsonObject -Path $Path
    if (-not $registryExists) {
        return New-InstallRegistry
    }
    if (-not ($registry -is [System.Collections.IDictionary]) -or $registry.Count -eq 0) {
        throw "Existing install registry is empty or not a JSON object: $Path"
    }

    $schemaVersion = [string]$registry['schema_version']
    if ($schemaVersion -notin @('install-registry/v1.0','install-registry/v1.1')) {
        throw "Unsupported install registry schema: $schemaVersion"
    }
    if (-not ($registry['workspaces'] -is [System.Collections.IDictionary])) {
        throw "Invalid install registry workspaces map: $Path"
    }
    if (-not ($registry['global_manifest_history'] -is [System.Collections.IList])) {
        throw "Invalid install registry global history array: $Path"
    }

    $modernFields = @(
        'transaction_status_contract',
        'history_ownership_contract',
        'manifest_integrity_contract',
        'retired_manifest_history',
        'manifest_digests'
    )
    $presentModernFields = @($modernFields | Where-Object { $registry.Contains($_) })
    if ($schemaVersion -eq 'install-registry/v1.0') {
        if ($presentModernFields.Count -notin @(0, $modernFields.Count)) {
            throw "Legacy install registry contains a partial modern contract: $Path"
        }

        $ownedManifestPaths = @($registry['global_manifest_history'])
        foreach ($entry in $registry['workspaces'].Values) {
            if (-not ($entry -is [System.Collections.IDictionary]) -or
                -not ($entry['manifests'] -is [System.Collections.IList])) {
                throw "Legacy install registry workspace entry is invalid: $Path"
            }
            $ownedManifestPaths += @($entry['manifests'])
        }
        $ownedManifestPaths = @($ownedManifestPaths | ForEach-Object { Get-NormalizedPath -Path $_ } | Select-Object -Unique)
        if ($ownedManifestPaths.Count -gt 0) {
            foreach ($manifestPath in $ownedManifestPaths) {
                $manifest = Read-JsonObject -Path $manifestPath
                if (-not ($manifest -is [System.Collections.IDictionary]) -or
                    [string]$manifest['schema_version'] -ne 'install-manifest/v1.2') {
                    throw 'LIVE_UPDATE_REQUIRED: legacy-install-state'
                }
            }
            if ($presentModernFields.Count -ne $modernFields.Count) {
                throw "Legacy install registry cannot validate modern manifest integrity: $Path"
            }
        } elseif ($presentModernFields.Count -eq 0) {
            return New-InstallRegistry
        }
        $registry['schema_version'] = 'install-registry/v1.1'
    } elseif ($presentModernFields.Count -ne $modernFields.Count) {
        throw "Modern install registry is missing required contract state: $Path"
    }

    $transactionStatusContract = [string]$registry['transaction_status_contract']
    if ($transactionStatusContract -ne 'v1') {
        throw "Unsupported install registry transaction status contract: $transactionStatusContract"
    }
    $manifestIntegrityContract = [string]$registry['manifest_integrity_contract']
    if ($manifestIntegrityContract -ne 'sha256-v1') {
        throw "Unsupported install registry manifest integrity contract: $manifestIntegrityContract"
    }
    if (-not ($registry['manifest_digests'] -is [System.Collections.IDictionary])) {
        throw "Invalid install registry manifest digest map: $Path"
    }
    $historyOwnershipContract = [string]$registry['history_ownership_contract']
    if ($historyOwnershipContract -ne 'v1') {
        throw "Unsupported install registry history ownership contract: $historyOwnershipContract"
    }
    if (-not ($registry['retired_manifest_history'] -is [System.Collections.IList])) {
        throw "Invalid install registry retired history array: $Path"
    }

    return $registry
}

function Assert-LegacyRebaselineKeys {
    param(
        $Value,
        [string[]]$RequiredKeys,
        [string[]]$AllowedKeys = $RequiredKeys,
        [string]$Label
    )

    if (-not ($Value -is [System.Collections.IDictionary])) {
        throw "$Label must be a JSON object"
    }
    foreach ($requiredKey in $RequiredKeys) {
        if (-not $Value.Contains($requiredKey)) {
            throw "$Label is missing required field '$requiredKey'"
        }
    }
    foreach ($key in @($Value.Keys)) {
        if ($AllowedKeys -notcontains [string]$key) {
            throw "$Label contains unsupported field '$key'"
        }
    }
}

function Read-LegacyRebaselineJsonSnapshot {
    param(
        [string]$Path,
        [string]$Label
    )

    [void](Assert-InstallStatePathHasNoReparsePoint -Path $Path -Label $Label)
    $beforeDigest = Get-InstallStateFileDigest -Path $Path
    if ($beforeDigest -notmatch '^[0-9a-f]{64}$') {
        throw "$Label is missing: $Path"
    }
    $raw = Read-FileUtf8 -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw) -or (Get-InstallStateFileDigest -Path $Path) -ne $beforeDigest) {
        throw "$Label changed while it was read: $Path"
    }
    return [ordered]@{
        path = (Get-NormalizedPath -Path $Path)
        digest = $beforeDigest
        value = (ConvertFrom-JsonDocument -Json $raw)
    }
}

function Assert-LegacyRebaselineTreeSafe {
    param(
        [string]$Path,
        [string]$Label
    )

    [void](Assert-InstallStatePathHasNoReparsePoint -Path $Path -Label $Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
        if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "$Label contains a reparse point: $($item.FullName)"
        }
    }
}

function Assert-LegacyRebaselineManagedTarget {
    param(
        [string]$TargetPath,
        [string]$Scope,
        [string]$ItemType,
        [bool]$Existed,
        $Manifest,
        [switch]$AllowExtinctWorkspace,
        [switch]$AllowLegacyPointerGlobal
    )

    $target = Get-NormalizedPath -Path $TargetPath
    if ($Scope -eq 'workspace') {
        $workspaceRoot = Get-NormalizedPath -Path $Manifest['workspace_root']
        if ($target -in @(
                Get-NormalizedPath -Path (Join-Path $workspaceRoot '.gitignore')
                Get-NormalizedPath -Path (Join-Path $workspaceRoot 'AGENTS.md')
            )) {
            return
        }
        $vaultRoot = Get-NormalizedPath -Path $Manifest['vault_path']
        if ($target -eq $vaultRoot -or -not (Test-PathWithinRoot -Path $target -RootPath $vaultRoot)) {
            throw "Legacy workspace backup target is not Harness-managed: $target"
        }
        if ($AllowExtinctWorkspace) {
            return
        }
        $relativeTarget = $target.Substring($vaultRoot.TrimEnd('\').Length).TrimStart('\')
        $minimalTargets = @('entry\AGENTS.md','entry\advance-stage.ps1','entry\task.ps1','entry\validate-lite-artifacts.ps1')
        if ([string]$Manifest['effective_vault_profile'] -eq 'minimal') {
            if ($relativeTarget -notin $minimalTargets) {
                throw "Legacy minimal-vault target is not Harness-managed: $target"
            }
            return
        }
        $templateRoot = Join-Path $Manifest['repo_root'] 'vault-template'
        $sourceCandidates = @(
            Join-Path $templateRoot $relativeTarget
            Join-Path $templateRoot ($relativeTarget + '.template')
        )
        if (@($sourceCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 0) {
            throw "Legacy full-vault target has no managed template source: $target"
        }
        return
    }

    $claudeHome = Get-NormalizedPath -Path $Manifest['claude_home']
    $codexHome = Get-NormalizedPath -Path $Manifest['codex_home']
    $agentsHome = Get-NormalizedPath -Path $Manifest['agents_home']
    $exactTargets = @(
        Join-Path $claudeHome 'CLAUDE.md'
        Join-Path $claudeHome 'settings.json'
        Join-Path $claudeHome 'hooks-memory'
        Join-Path $codexHome 'AGENTS.md'
        Join-Path $codexHome 'managed_config.toml'
        Join-Path $codexHome '.claude\settings.local.json'
    ) | ForEach-Object { Get-NormalizedPath -Path $_ }
    if ($target -in $exactTargets) {
        return
    }
    if ($AllowLegacyPointerGlobal -and
        $target -eq (Get-NormalizedPath -Path (Join-Path $claudeHome '.claude\settings.local.json'))) {
        return
    }
    foreach ($userHome in @($claudeHome,$codexHome,$agentsHome)) {
        $skillsRoot = Get-NormalizedPath -Path (Join-Path $userHome 'skills')
        if ($target -eq $skillsRoot) {
            if ($Existed -and $ItemType -eq 'link') { return }
            throw "Legacy skills-root backup is valid only for an existing link: $target"
        }
        if ((Get-NormalizedPath -Path (Split-Path -Parent $target)) -eq $skillsRoot) {
            return
        }
    }
    throw "Legacy user-global backup target is not Harness-managed: $target"
}

function Get-LegacyRebaselineRecordDescriptor {
    param(
        $Record,
        $Manifest,
        [switch]$PointerLegacy
    )

    $baseKeys = @('path','existed','backup_path','item_type','link_type','link_target')
    $recordKeys = if ($PointerLegacy) { $baseKeys } else { @($baseKeys + @('scope','ownership')) }
    Assert-LegacyRebaselineKeys -Value $Record -RequiredKeys $recordKeys -AllowedKeys $recordKeys -Label 'Legacy backup record'
    if (-not ($Record['existed'] -is [bool])) {
        throw 'Legacy backup record existed must be boolean'
    }
    $targetPath = Get-NormalizedPath -Path $Record['path']
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        throw 'Legacy backup record path is empty'
    }
    $workspaceRoot = Get-NormalizedPath -Path $Manifest['workspace_root']
    $userRoots = @($Manifest['claude_home'],$Manifest['codex_home'],$Manifest['agents_home']) | ForEach-Object { Get-NormalizedPath -Path $_ }
    $inWorkspace = Test-PathWithinRoot -Path $targetPath -RootPath $workspaceRoot
    $inUserGlobal = @($userRoots | Where-Object { Test-PathWithinRoot -Path $targetPath -RootPath $_ }).Count -gt 0
    if ($inWorkspace -eq $inUserGlobal) {
        throw "Legacy backup target scope is ambiguous: $targetPath"
    }
    $scope = if ($inWorkspace) { 'workspace' } else { 'user-global' }
    if (-not $PointerLegacy -and [string]$Record['scope'] -ne $scope) {
        throw "Legacy backup target scope disagrees with its path: $targetPath"
    }
    $ownership = if ($PointerLegacy) { 'managed' } else { [string]$Record['ownership'] }
    if ($ownership -notin @('managed','create-if-missing','user-owned')) {
        throw "Legacy backup target ownership is unsupported: $targetPath"
    }
    $itemType = [string]$Record['item_type']
    $existed = [bool]$Record['existed']
    if ($itemType -eq 'link') {
        throw "Legacy rebaseline does not accept reparse-point backups: $targetPath"
    }
    if ((-not $existed -and $itemType -ne 'missing') -or ($existed -and $itemType -notin @('file','directory'))) {
        throw "Legacy backup record has inconsistent type metadata: $targetPath"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record['link_type']) -or
        -not [string]::IsNullOrWhiteSpace([string]$Record['link_target'])) {
        throw "Legacy backup record contains unexpected link metadata: $targetPath"
    }
    Assert-LegacyRebaselineManagedTarget `
        -TargetPath $targetPath `
        -Scope $scope `
        -ItemType $itemType `
        -Existed $existed `
        -Manifest $Manifest `
        -AllowExtinctWorkspace:($PointerLegacy -and $scope -eq 'workspace') `
        -AllowLegacyPointerGlobal:($PointerLegacy -and $scope -eq 'user-global')

    $backupPath = $null
    $payloadDigest = $null
    if ($existed) {
        $backupPath = Get-NormalizedPath -Path $Record['backup_path']
        if ([string]::IsNullOrWhiteSpace($backupPath) -or
            -not (Test-PathWithinRoot -Path $backupPath -RootPath $Manifest['backup_root'])) {
            throw "Legacy backup payload escapes its backup root: $targetPath"
        }
        Assert-LegacyRebaselineTreeSafe -Path $backupPath -Label 'Legacy backup payload'
        $pathType = if ($itemType -eq 'file') { 'Leaf' } else { 'Container' }
        if (-not (Test-Path -LiteralPath $backupPath -PathType $pathType)) {
            throw "Legacy backup payload is missing: $backupPath"
        }
        $payloadDigest = Get-InstallBackupPayloadDigest -Path $backupPath -ItemType $itemType
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$Record['backup_path'])) {
        throw "Missing legacy target has an unexpected backup payload: $targetPath"
    }
    return [ordered]@{
        path = $targetPath
        existed = $existed
        backup_path = $backupPath
        item_type = $itemType
        link_type = $null
        link_target = $null
        scope = $scope
        ownership = $ownership
        source_payload_sha256 = $payloadDigest
    }
}

function Get-LegacyRebaselineManifestSource {
    param(
        $Snapshot,
        [string]$ExpectedWorkspaceRoot,
        [string]$ExpectedRepoRoot,
        [string]$ExpectedUserProfile,
        [string]$ExpectedRegistryPath,
        [switch]$PointerLegacy
    )

    $manifest = $Snapshot['value']
    $commonKeys = @('installed_at','repo_root','workspace_root','vault_path','claude_home','codex_home','agents_home','backup_root','generated_repo_system_path','requested_vault_profile','effective_vault_profile','backups')
    $manifestKeys = if ($PointerLegacy) { $commonKeys } else { @('schema_version','registry_path') + $commonKeys }
    Assert-LegacyRebaselineKeys -Value $manifest -RequiredKeys $manifestKeys -AllowedKeys $manifestKeys -Label 'Legacy install manifest'
    if (-not $PointerLegacy -and [string]$manifest['schema_version'] -ne 'install-manifest/v1.1') {
        throw "Unsupported legacy install manifest schema: $($manifest['schema_version'])"
    }
    $baseIdentityMatches = (Get-NormalizedPath -Path $manifest['workspace_root']) -eq (Get-NormalizedPath -Path $ExpectedWorkspaceRoot) -and
        (Get-NormalizedPath -Path $manifest['repo_root']) -eq (Get-NormalizedPath -Path $ExpectedRepoRoot) -and
        (Get-NormalizedPath -Path $manifest['vault_path']) -eq (Get-NormalizedPath -Path (Join-Path $ExpectedWorkspaceRoot '.assistant'))
    $legacyHomes = @($manifest['claude_home'],$manifest['codex_home'],$manifest['agents_home']) | ForEach-Object { Get-NormalizedPath -Path $_ }
    if ($PointerLegacy) {
        $expectedHomeNames = @('.claude','.codex','.agents')
        $legacyHomeParents = @($legacyHomes | ForEach-Object { Get-NormalizedPath -Path (Split-Path -Parent $_) } | Select-Object -Unique)
        $currentHomes = $expectedHomeNames | ForEach-Object { Get-NormalizedPath -Path (Join-Path $ExpectedUserProfile $_) }
        $isCurrentProfile = $true
        $isExtinctForeignProfile = $legacyHomeParents.Count -eq 1
        for ($homeIndex = 0; $homeIndex -lt $legacyHomes.Count; $homeIndex++) {
            $isCurrentProfile = $isCurrentProfile -and $legacyHomes[$homeIndex] -eq $currentHomes[$homeIndex]
            $isExtinctForeignProfile = $isExtinctForeignProfile -and
                (Split-Path -Leaf $legacyHomes[$homeIndex]) -eq $expectedHomeNames[$homeIndex] -and
                -not (Test-Path -LiteralPath $legacyHomes[$homeIndex])
        }
        $userIdentityMatches = $isCurrentProfile -or $isExtinctForeignProfile
        $pointerProfileMode = if ($isCurrentProfile) { 'current' } else { 'foreign-extinct' }
    } else {
        $userIdentityMatches = $legacyHomes[0] -eq (Get-NormalizedPath -Path (Join-Path $ExpectedUserProfile '.claude')) -and
            $legacyHomes[1] -eq (Get-NormalizedPath -Path (Join-Path $ExpectedUserProfile '.codex')) -and
            $legacyHomes[2] -eq (Get-NormalizedPath -Path (Join-Path $ExpectedUserProfile '.agents'))
        $pointerProfileMode = 'current'
    }
    if (-not $baseIdentityMatches -or -not $userIdentityMatches) {
        throw "Legacy install manifest identity mismatch: $($Snapshot['path'])"
    }
    if (-not $PointerLegacy -and
        (Get-NormalizedPath -Path $manifest['registry_path']) -ne (Get-NormalizedPath -Path $ExpectedRegistryPath)) {
        throw "Legacy install manifest registry mismatch: $($Snapshot['path'])"
    }
    if ([string]$manifest['effective_vault_profile'] -notin @('minimal','full') -or
        [string]$manifest['requested_vault_profile'] -notin @('auto','minimal','full') -or
        -not ($manifest['backups'] -is [System.Collections.IList]) -or @($manifest['backups']).Count -eq 0) {
        throw "Legacy install manifest profile or backups are invalid: $($Snapshot['path'])"
    }
    $backupRoot = Get-NormalizedPath -Path $manifest['backup_root']
    $expectedBackupBase = if ($PointerLegacy) {
        Join-Path $ExpectedRepoRoot 'backups'
    } else {
        Join-Path $ExpectedUserProfile '.dev-harness\backups'
    }
    Assert-LegacyRebaselineTreeSafe -Path $backupRoot -Label 'Legacy backup root'
    if (-not (Test-PathWithinRoot -Path $backupRoot -RootPath $expectedBackupBase) -or
        (Get-NormalizedPath -Path $Snapshot['path']) -ne (Get-NormalizedPath -Path (Join-Path $backupRoot 'install-manifest.json'))) {
        throw "Legacy install manifest backup boundary is invalid: $($Snapshot['path'])"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$manifest['generated_repo_system_path']) -and
        -not (Test-PathWithinRoot -Path $manifest['generated_repo_system_path'] -RootPath $ExpectedRepoRoot)) {
        throw "Legacy generated system path escapes RepoRoot: $($manifest['generated_repo_system_path'])"
    }
    $installedAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$manifest['installed_at'], [ref]$installedAt)) {
        throw "Legacy install manifest has an invalid installed_at: $($Snapshot['path'])"
    }
    $seenTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $records = New-Object System.Collections.ArrayList
    foreach ($record in @($manifest['backups'])) {
        $descriptor = Get-LegacyRebaselineRecordDescriptor `
            -Record $record `
            -Manifest $manifest `
            -PointerLegacy:$PointerLegacy
        if (-not $seenTargets.Add([string]$descriptor['path'])) {
            throw "Legacy install manifest contains duplicate target: $($descriptor['path'])"
        }
        [void]$records.Add($descriptor)
    }
    return [ordered]@{
        manifest = $manifest
        installed_at = $installedAt
        user_profile_mode = $pointerProfileMode
        records = $records
        document = [ordered]@{
            path = $Snapshot['path']
            sha256 = $Snapshot['digest']
            installed_at = [string]$manifest['installed_at']
            records = $records
        }
    }
}

function New-LegacyRebaselineClaudeSettingsIdentity {
    param(
        [string]$Path,
        [string]$ClaudeHome
    )

    $settings = Read-JsonObject -Path $Path
    if (-not ($settings -is [System.Collections.IDictionary]) -or
        -not ($settings['hooks'] -is [System.Collections.IDictionary])) {
        throw "Legacy Claude settings are missing a hooks object: $Path"
    }
    $expectedHooks = [ordered]@{
        UserPromptSubmit = 'userpromptsubmit.js'
        Stop = 'stop.js'
        PostToolUse = 'posttooluse.js'
    }
    $managedSettings = [ordered]@{}
    foreach ($eventName in $expectedHooks.Keys) {
        if (-not $settings['hooks'].Contains($eventName) -or
            -not ($settings['hooks'][$eventName] -is [System.Collections.IList])) {
            throw "Legacy Claude settings are missing managed event: $eventName"
        }
        $expectedCommand = 'node "{0}"' -f (Join-Path $ClaudeHome ('hooks-memory\' + $expectedHooks[$eventName]))
        $managedSections = New-Object System.Collections.ArrayList
        $globalMatchCount = 0
        foreach ($candidateEvent in $settings['hooks'].Keys) {
            if (-not ($settings['hooks'][$candidateEvent] -is [System.Collections.IList])) {
                throw "Legacy Claude settings event must be an array: $candidateEvent"
            }
            foreach ($section in @($settings['hooks'][$candidateEvent])) {
                if (-not ($section -is [System.Collections.IDictionary]) -or
                    -not ($section['hooks'] -is [System.Collections.IList])) {
                    throw "Legacy Claude settings hook section is invalid: $candidateEvent"
                }
                $matchingHooks = @($section['hooks'] | Where-Object {
                    $_ -is [System.Collections.IDictionary] -and
                    ([string]$_['command']).Trim().Equals($expectedCommand, [System.StringComparison]::OrdinalIgnoreCase)
                })
                $globalMatchCount += $matchingHooks.Count
                if ([string]$candidateEvent -eq [string]$eventName -and $matchingHooks.Count -gt 0) {
                    $managedSection = [ordered]@{}
                    foreach ($key in $section.Keys) {
                        if ([string]$key -ne 'hooks') {
                            $managedSection[[string]$key] = ConvertTo-NormalizedObject -Value $section[$key]
                        }
                    }
                    $managedSection['hooks'] = @($matchingHooks | ForEach-Object { ConvertTo-NormalizedObject -Value $_ })
                    [void]$managedSections.Add($managedSection)
                }
            }
        }
        if ($globalMatchCount -ne 1 -or $managedSections.Count -ne 1) {
            throw "Legacy Claude managed hook identity is ambiguous: $eventName"
        }
        $managedSettings[$eventName] = $managedSections
    }
    return New-ClaudeSettingsPostimageIdentity -ManagedSettings $managedSettings
}

function Get-LegacyRebaselineCurrentPostimage {
    param(
        [string]$Path,
        [string]$WorkspaceRoot,
        [string]$ClaudeHome
    )

    Assert-LegacyRebaselineTreeSafe -Path $Path -Label 'Legacy rebaseline current target'
    if ((Get-NormalizedPath -Path $Path) -eq (Get-NormalizedPath -Path (Join-Path $WorkspaceRoot '.gitignore'))) {
        throw 'Legacy rebaseline does not infer historical .gitignore semantic deltas'
    }
    if ((Get-NormalizedPath -Path $Path) -eq (Get-NormalizedPath -Path (Join-Path $ClaudeHome 'settings.json'))) {
        return New-LegacyRebaselineClaudeSettingsIdentity -Path $Path -ClaudeHome $ClaudeHome
    }
    return Get-InstallManagedPathIdentity -Path $Path
}

function New-LegacyRebaselinePlan {
    param(
        [string]$RegistryPath,
        [string]$PointerPath,
        [string]$WorkspaceRoot,
        [string]$RepoRoot,
        [string]$UserProfile
    )

    $registrySnapshot = Read-LegacyRebaselineJsonSnapshot -Path $RegistryPath -Label 'Legacy install registry'
    $registry = $registrySnapshot['value']
    $registryKeys = @('schema_version','updated_at','workspaces','global_manifest_history')
    Assert-LegacyRebaselineKeys -Value $registry -RequiredKeys $registryKeys -AllowedKeys $registryKeys -Label 'Legacy install registry'
    if ([string]$registry['schema_version'] -ne 'install-registry/v1.0' -or
        -not ($registry['workspaces'] -is [System.Collections.IDictionary]) -or
        -not ($registry['global_manifest_history'] -is [System.Collections.IList])) {
        throw 'Legacy rebaseline requires a v1.0 registry with zero modern contract fields'
    }
    $workspaceEntries = @($registry['workspaces'].GetEnumerator())
    if ($workspaceEntries.Count -ne 1) {
        throw 'Legacy rebaseline requires exactly one registered workspace'
    }
    $workspaceEntry = $workspaceEntries[0].Value
    $entryKeys = @('workspace_root','repo_root','effective_vault_profile','installed_at','last_installed_at','manifests')
    Assert-LegacyRebaselineKeys -Value $workspaceEntry -RequiredKeys $entryKeys -AllowedKeys $entryKeys -Label 'Legacy registry workspace entry'
    if ((Get-NormalizedPath -Path $workspaceEntry['workspace_root']) -ne $WorkspaceRoot -or
        (Get-NormalizedPath -Path $workspaceEntry['repo_root']) -ne $RepoRoot -or
        [string]$workspaceEntries[0].Key -ne (Get-WorkspaceRegistryKey -Path $WorkspaceRoot) -or
        [string]$workspaceEntry['effective_vault_profile'] -notin @('minimal','full') -or
        -not ($workspaceEntry['manifests'] -is [System.Collections.IList])) {
        throw 'Legacy registry workspace identity is invalid'
    }
    $manifestPaths = @($workspaceEntry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    $globalHistory = @($registry['global_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    if ($manifestPaths.Count -eq 0 -or $manifestPaths.Count -ne $globalHistory.Count) {
        throw 'Legacy registry workspace/global history is incomplete'
    }
    for ($index = 0; $index -lt $manifestPaths.Count; $index++) {
        if ($manifestPaths[$index] -ne $globalHistory[$index] -or
            @($manifestPaths | Where-Object { $_ -eq $manifestPaths[$index] }).Count -ne 1) {
            throw 'Legacy registry workspace/global history is ambiguous'
        }
    }

    $sources = New-Object System.Collections.ArrayList
    $previousInstalledAt = [datetimeoffset]::MinValue
    for ($manifestIndex = 0; $manifestIndex -lt $manifestPaths.Count; $manifestIndex++) {
        $snapshot = Read-LegacyRebaselineJsonSnapshot -Path $manifestPaths[$manifestIndex] -Label 'Legacy install manifest'
        $source = Get-LegacyRebaselineManifestSource `
            -Snapshot $snapshot `
            -ExpectedWorkspaceRoot $WorkspaceRoot `
            -ExpectedRepoRoot $RepoRoot `
            -ExpectedUserProfile $UserProfile `
            -ExpectedRegistryPath $RegistryPath
        if ($source['installed_at'] -le $previousInstalledAt) {
            throw 'Legacy registry manifest history is not strictly chronological'
        }
        if ([string]$source['manifest']['effective_vault_profile'] -ne [string]$workspaceEntry['effective_vault_profile']) {
            throw 'Legacy registry manifest profile disagrees with its workspace owner'
        }
        if ($sources.Count -gt 0) {
            $expectedRecords = @($sources[0]['records'])
            $actualRecords = @($source['records'])
            if ($expectedRecords.Count -ne $actualRecords.Count) {
                throw 'Legacy registry manifest target sets are inconsistent'
            }
            for ($recordIndex = 0; $recordIndex -lt $expectedRecords.Count; $recordIndex++) {
                foreach ($field in @('path','scope','ownership')) {
                    if ([string]$expectedRecords[$recordIndex][$field] -ne [string]$actualRecords[$recordIndex][$field]) {
                        throw 'Legacy registry manifest target order, scope, or ownership is inconsistent'
                    }
                }
            }
        }
        [void]$sources.Add($source)
        $previousInstalledAt = $source['installed_at']
    }

    $pointerDocument = [ordered]@{
        path = (Get-NormalizedPath -Path $PointerPath)
        sha256 = (Get-InstallStateFileDigest -Path $PointerPath)
        mode = 'absent'
        manifest_path = $null
        manifest_sha256 = $null
        absorbed_user_global_count = 0
        skipped_extinct_workspace_count = 0
        skipped_foreign_user_global_count = 0
    }
    if ($pointerDocument['sha256'] -ne 'missing') {
        $pointerSnapshot = Read-LegacyRebaselineJsonSnapshot -Path $PointerPath -Label 'Legacy active-install pointer'
        $pointer = $pointerSnapshot['value']
        $pointerKeys = @('workspace_root','repo_root','vault_path','manifest_path','installed_at','requested_vault_profile','effective_vault_profile')
        Assert-LegacyRebaselineKeys -Value $pointer -RequiredKeys $pointerKeys -AllowedKeys $pointerKeys -Label 'Legacy active-install pointer'
        if ((Get-NormalizedPath -Path $pointer['repo_root']) -ne $RepoRoot) {
            throw 'Legacy active-install pointer is owned by another RepoRoot'
        }
        $pointerDocument['sha256'] = $pointerSnapshot['digest']
        $pointerManifestPath = Get-NormalizedPath -Path $pointer['manifest_path']
        $pointerDocument['manifest_path'] = $pointerManifestPath
        $registeredPointerIndex = [array]::IndexOf([object[]]$manifestPaths, [object]$pointerManifestPath)
        if ($registeredPointerIndex -ge 0) {
            $pointerSource = $sources[$registeredPointerIndex]
            if ((Get-NormalizedPath -Path $pointer['workspace_root']) -ne $WorkspaceRoot -or
                (Get-NormalizedPath -Path $pointer['vault_path']) -ne (Get-NormalizedPath -Path $pointerSource['manifest']['vault_path']) -or
                [string]$pointer['installed_at'] -ne [string]$pointerSource['manifest']['installed_at'] -or
                [string]$pointer['requested_vault_profile'] -ne [string]$pointerSource['manifest']['requested_vault_profile'] -or
                [string]$pointer['effective_vault_profile'] -ne [string]$pointerSource['manifest']['effective_vault_profile']) {
                throw 'Legacy active-install pointer disagrees with registered history'
            }
            $pointerDocument['mode'] = 'registered-history'
            $pointerDocument['manifest_sha256'] = $pointerSource['document']['sha256']
        } else {
            $pointerManifestSnapshot = Read-LegacyRebaselineJsonSnapshot -Path $pointerManifestPath -Label 'Pre-registry active-install manifest'
            $pointerWorkspace = Get-NormalizedPath -Path $pointer['workspace_root']
            if ($pointerWorkspace -eq $WorkspaceRoot) {
                throw 'History-external pointer for the current profile is unsupported; manual inventory is required'
            }
            if ((Test-Path -LiteralPath $pointerWorkspace) -or
                (Test-Path -LiteralPath $pointer['vault_path'])) {
                throw 'Legacy active-install pointer represents another live workspace'
            }
            $pointerSource = Get-LegacyRebaselineManifestSource `
                -Snapshot $pointerManifestSnapshot `
                -ExpectedWorkspaceRoot $pointerWorkspace `
                -ExpectedRepoRoot $RepoRoot `
                -ExpectedUserProfile $UserProfile `
                -ExpectedRegistryPath $RegistryPath `
                -PointerLegacy
            if ((Get-NormalizedPath -Path $pointer['vault_path']) -ne (Get-NormalizedPath -Path $pointerSource['manifest']['vault_path']) -or
                [string]$pointer['installed_at'] -ne [string]$pointerSource['manifest']['installed_at'] -or
                [string]$pointer['requested_vault_profile'] -ne [string]$pointerSource['manifest']['requested_vault_profile'] -or
                [string]$pointer['effective_vault_profile'] -ne [string]$pointerSource['manifest']['effective_vault_profile'] -or
                $pointerSource['installed_at'] -ge $sources[0]['installed_at']) {
                throw 'Pre-registry active-install manifest identity or chronology is invalid'
            }
            if ([string]$pointerSource['user_profile_mode'] -eq 'current') {
                throw 'History-external pointer for the current profile is unsupported; manual inventory is required'
            }
            $pointerDocument['mode'] = 'foreign-extinct'
            $pointerDocument['manifest_sha256'] = $pointerManifestSnapshot['digest']
            foreach ($pointerRecord in @($pointerSource['records'])) {
                if ([string]$pointerRecord['scope'] -eq 'workspace') {
                    $pointerDocument['skipped_extinct_workspace_count']++
                } else {
                    $pointerDocument['skipped_foreign_user_global_count']++
                }
            }
            [void]$sources.Add($pointerSource)
        }
    }

    $syntheticRecords = New-Object System.Collections.ArrayList
    foreach ($sourceRecord in @($sources[0]['records'])) {
        $record = ConvertTo-NormalizedObject -Value $sourceRecord
        Assert-LegacyRebaselineTreeSafe -Path $record['path'] -Label 'Legacy rebaseline current target'
        $currentIdentityBefore = Get-InstallManagedPathIdentity -Path $record['path']
        $record['expected_postimage'] = Get-LegacyRebaselineCurrentPostimage `
            -Path $record['path'] `
            -WorkspaceRoot $WorkspaceRoot `
            -ClaudeHome (Join-Path $UserProfile '.claude')
        $currentIdentityAfter = Get-InstallManagedPathIdentity -Path $record['path']
        if ((ConvertTo-Json -InputObject $currentIdentityBefore -Depth 30 -Compress) -ne
            (ConvertTo-Json -InputObject $currentIdentityAfter -Depth 30 -Compress)) {
            throw "Legacy rebaseline current target changed while it was inspected: $($record['path'])"
        }
        $record['current_identity'] = $currentIdentityAfter
        Assert-InstallExpectedPostimageShape -Identity $record['expected_postimage'] -Label "Legacy rebaseline expected postimage for $($record['path'])"
        [void]$syntheticRecords.Add($record)
    }
    $sourceDocuments = @($sources | ForEach-Object { $_['document'] })
    $planDocument = [ordered]@{
        contract = 'legacy-rebaseline-plan/v1'
        registry = [ordered]@{ path = $registrySnapshot['path']; sha256 = $registrySnapshot['digest'] }
        workspace_root = $WorkspaceRoot
        repo_root = $RepoRoot
        user_profile = (Get-NormalizedPath -Path $UserProfile)
        effective_vault_profile = [string]$workspaceEntry['effective_vault_profile']
        sources = $sourceDocuments
        pointer = $pointerDocument
        synthetic_records = $syntheticRecords
    }
    $digest = Get-InstallStateIdentityHash -Value (ConvertTo-Json -InputObject $planDocument -Depth 100 -Compress)
    return [ordered]@{
        digest = $digest
        plan_digest = $digest
        document = $planDocument
        sources = $sources
        synthetic_records = $syntheticRecords
        source_manifest_count = $sourceDocuments.Count
        synthetic_backup_record_count = $syntheticRecords.Count
        pointer_absorbed_user_global_count = [int]$pointerDocument['absorbed_user_global_count']
        pointer_skipped_extinct_workspace_count = [int]$pointerDocument['skipped_extinct_workspace_count']
        pointer_skipped_foreign_user_global_count = [int]$pointerDocument['skipped_foreign_user_global_count']
        source_payload_set_sha256 = (Get-InstallStateIdentityHash -Value (ConvertTo-Json -InputObject $sourceDocuments -Depth 100 -Compress))
    }
}

function Get-LegacyRebaselineReceiptInfo {
    param(
        $Registry,
        [string]$RegistryPath,
        [string]$WorkspaceRoot,
        [string]$RepoRoot,
        [string]$UserProfile
    )

    if ([string]$Registry['schema_version'] -ne 'install-registry/v1.1') {
        return $null
    }
    [void](Get-RegisteredManifestStatusUpgradePlan `
        -Registry $Registry `
        -RegistryPath $RegistryPath `
        -ExpectedUserProfile $UserProfile `
        -RequireManifestIntegrity $true)
    $workspaceKey = Get-WorkspaceRegistryKey -Path $WorkspaceRoot
    if (-not $Registry['workspaces'].Contains($workspaceKey)) {
        return $null
    }
    $entry = $Registry['workspaces'][$workspaceKey]
    if ((Get-NormalizedPath -Path $entry['repo_root']) -ne $RepoRoot) {
        throw 'Legacy rebaseline receipt belongs to another RepoRoot'
    }
    $receiptMatches = New-Object System.Collections.ArrayList
    foreach ($manifestPath in @($entry['manifests'])) {
        $manifest = Read-JsonObject -Path $manifestPath
        if (-not $manifest.Contains('legacy_rebaseline_receipt')) { continue }
        $receipt = $manifest['legacy_rebaseline_receipt']
        if (-not ($receipt -is [System.Collections.IDictionary]) -or
            [string]$receipt['contract'] -ne 'legacy_rebaseline/v1' -or
            [string]$receipt['plan_digest'] -notmatch '^[0-9a-f]{64}$' -or
            [string]$receipt['legacy_pointer_sha256'] -notmatch '^(missing|[0-9a-f]{64})$' -or
            [string]$receipt['source_registry_sha256'] -notmatch '^[0-9a-f]{64}$') {
            throw "Committed legacy rebaseline receipt is invalid: $manifestPath"
        }
        [void]$receiptMatches.Add($receipt)
    }
    if ($receiptMatches.Count -gt 1) {
        throw 'More than one active legacy rebaseline receipt is registered for the workspace'
    }
    if ($receiptMatches.Count -eq 0) { return $null }
    return $receiptMatches[0]
}

function Publish-LegacyRebaselinePlan {
    param(
        $Plan,
        [string]$RegistryPath,
        [string]$PointerPath,
        [string]$WorkspaceRoot,
        [string]$RepoRoot,
        [string]$UserProfile
    )

    $stateRoot = Join-Path $UserProfile '.dev-harness'
    $backupRoot = Join-Path $stateRoot ('backups\rebaseline-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$PID-" + [guid]::NewGuid().ToString('N'))
    [void](Assert-InstallStatePathHasNoReparsePoint -Path $backupRoot -Label 'Legacy rebaseline staging root')
    Ensure-Directory -Path $backupRoot
    $backupRecords = New-Object System.Collections.ArrayList
    $recordIndex = 0
    foreach ($sourceRecord in @($Plan['synthetic_records'])) {
        $targetPath = Get-NormalizedPath -Path $sourceRecord['path']
        $record = [ordered]@{
            path = $targetPath
            existed = [bool]$sourceRecord['existed']
            backup_path = $null
            item_type = [string]$sourceRecord['item_type']
            link_type = $null
            link_target = $null
            backup_payload_sha256 = $null
            scope = [string]$sourceRecord['scope']
            ownership = [string]$sourceRecord['ownership']
            expected_postimage = (ConvertTo-NormalizedObject -Value $sourceRecord['expected_postimage'])
        }
        if ($record['existed']) {
            $safeName = '{0:D4}-{1}' -f $recordIndex,(Get-InstallStateIdentityHash -Value $targetPath).Substring(0, 20)
            $destinationPath = Join-Path $backupRoot $safeName
            Copy-Item -LiteralPath $sourceRecord['backup_path'] -Destination $destinationPath -Recurse -Force
            Assert-LegacyRebaselineTreeSafe -Path $destinationPath -Label 'Synthetic backup payload'
            $destinationDigest = Get-InstallBackupPayloadDigest -Path $destinationPath -ItemType $record['item_type']
            if ($destinationDigest -ne [string]$sourceRecord['source_payload_sha256']) {
                throw "Synthetic backup payload does not match its TOFU source: $targetPath"
            }
            $record['backup_path'] = $destinationPath
            $record['backup_payload_sha256'] = $destinationDigest
        }
        [void]$backupRecords.Add($record)
        $recordIndex++
    }

    $pointer = $Plan['document']['pointer']
    $sourceManifestDigests = @($Plan['sources'] | ForEach-Object {
        [ordered]@{
            path = $_['document']['path']
            sha256 = $_['document']['sha256']
        }
    })
    $installedAt = Get-Date -Format 's'
    $manifestPath = Join-Path $backupRoot 'install-manifest.json'
    $receipt = [ordered]@{
        contract = 'legacy_rebaseline/v1'
        plan_digest = $Plan['digest']
        source_registry_path = $Plan['document']['registry']['path']
        source_registry_sha256 = $Plan['document']['registry']['sha256']
        source_manifest_digests = $sourceManifestDigests
        source_manifest_count = [int]$Plan['source_manifest_count']
        source_payload_set_sha256 = $Plan['source_payload_set_sha256']
        synthetic_backup_record_count = [int]$Plan['synthetic_backup_record_count']
        legacy_pointer_path = $pointer['path']
        legacy_pointer_sha256 = $pointer['sha256']
        legacy_pointer_manifest_path = $pointer['manifest_path']
        legacy_pointer_manifest_sha256 = $pointer['manifest_sha256']
        pointer_mode = $pointer['mode']
        pointer_absorbed_user_global_count = [int]$Plan['pointer_absorbed_user_global_count']
        pointer_skipped_extinct_workspace_count = [int]$Plan['pointer_skipped_extinct_workspace_count']
        pointer_skipped_foreign_user_global_count = [int]$Plan['pointer_skipped_foreign_user_global_count']
    }
    $manifest = [ordered]@{
        schema_version = 'install-manifest/v1.2'
        postimage_identity_contract = 'v1'
        installed_at = $installedAt
        repo_root = $RepoRoot
        workspace_root = $WorkspaceRoot
        vault_path = (Join-Path $WorkspaceRoot '.assistant')
        claude_home = (Join-Path $UserProfile '.claude')
        codex_home = (Join-Path $UserProfile '.codex')
        agents_home = (Join-Path $UserProfile '.agents')
        backup_root = $backupRoot
        registry_path = $RegistryPath
        registry_preimage_sha256 = $Plan['document']['registry']['sha256']
        transaction_status = 'committed'
        backup_payload_integrity_contract = 'sha256-v1'
        managed_backup_targets = @($backupRecords | ForEach-Object { $_['path'] })
        generated_repo_system_path = $null
        requested_vault_profile = 'auto'
        effective_vault_profile = $Plan['document']['effective_vault_profile']
        backups = $backupRecords
        legacy_rebaseline_receipt = $receipt
    }
    Write-InstallStateTextAtomic -Path $manifestPath -Content (ConvertTo-ManifestJsonDocument -Value $manifest)
    $publishedManifest = Read-JsonObject -Path $manifestPath
    Assert-RegisteredInstallManifestIdentity `
        -ManifestPath $manifestPath `
        -Manifest $publishedManifest `
        -ExpectedWorkspaceRoot $WorkspaceRoot `
        -ExpectedRepoRoot $RepoRoot `
        -RegistryPath $RegistryPath `
        -ExpectedUserProfile $UserProfile
    foreach ($record in @($publishedManifest['backups'])) {
        Assert-LegacyRebaselineManagedTarget -TargetPath $record['path'] -Scope $record['scope'] -ItemType $record['item_type'] -Existed ([bool]$record['existed']) -Manifest $publishedManifest
        if ([bool]$record['existed'] -and
            (Get-InstallBackupPayloadDigest -Path $record['backup_path'] -ItemType $record['item_type']) -ne [string]$record['backup_payload_sha256']) {
            throw "Published synthetic backup payload digest mismatch: $($record['path'])"
        }
    }

    $finalPlan = New-LegacyRebaselinePlan -RegistryPath $RegistryPath -PointerPath $PointerPath -WorkspaceRoot $WorkspaceRoot -RepoRoot $RepoRoot -UserProfile $UserProfile
    if ([string]$finalPlan['digest'] -ne [string]$Plan['digest'] -or
        (Get-InstallStateFileDigest -Path $RegistryPath) -ne [string]$Plan['document']['registry']['sha256']) {
        throw 'Legacy rebaseline source state changed before registry commit'
    }
    $modernRegistry = New-InstallRegistry
    Add-ManifestToRegistry `
        -Registry $modernRegistry `
        -ManifestPath $manifestPath `
        -WorkspaceRoot $WorkspaceRoot `
        -RepoRoot $RepoRoot `
        -VaultProfile $manifest['effective_vault_profile'] `
        -InstalledAt $installedAt
    Refresh-InstallRegistryManifestDigests -Registry $modernRegistry
    Write-InstallRegistry -Path $RegistryPath -Registry $modernRegistry -ExpectedCurrentDigest ([string]$Plan['document']['registry']['sha256'])
}

function Write-LegacyRebaselineStatus {
    param(
        [string]$Status,
        $State
    )

    Write-Output ("STATUS: $Status")
    Write-Output ('RebaselinePlanDigest: {0}' -f $State['plan_digest'])
    $countFields = [ordered]@{
        SourceManifestCount = 'source_manifest_count'
        SyntheticBackupRecordCount = 'synthetic_backup_record_count'
        PointerAbsorbedUserGlobalCount = 'pointer_absorbed_user_global_count'
        PointerSkippedExtinctWorkspaceCount = 'pointer_skipped_extinct_workspace_count'
        PointerSkippedForeignUserGlobalCount = 'pointer_skipped_foreign_user_global_count'
    }
    foreach ($field in $countFields.GetEnumerator()) {
        Write-Output ('{0}: {1}' -f $field.Key,$State[$field.Value])
    }
}

function Add-ManifestToRegistry {
    param(
        $Registry,
        [string]$ManifestPath,
        [string]$WorkspaceRoot,
        [string]$RepoRoot,
        [string]$VaultProfile,
        [string]$InstalledAt
    )

    $normalizedManifestPath = Get-NormalizedPath -Path $ManifestPath
    $normalizedWorkspaceRoot = Get-NormalizedPath -Path $WorkspaceRoot
    $key = Get-WorkspaceRegistryKey -Path $normalizedWorkspaceRoot
    $workspaces = $Registry['workspaces']
    $entry = if ($workspaces.Contains($key)) {
        $existingEntry = ConvertTo-NormalizedObject -Value $workspaces[$key]
        if ((Get-NormalizedPath -Path $existingEntry['repo_root']) -ne (Get-NormalizedPath -Path $RepoRoot)) {
            throw "Workspace is already registered to another RepoRoot: $normalizedWorkspaceRoot"
        }
        $existingEntry
    } else {
        [ordered]@{
            workspace_root = $normalizedWorkspaceRoot
            repo_root = (Get-NormalizedPath -Path $RepoRoot)
            effective_vault_profile = $VaultProfile
            installed_at = $InstalledAt
            manifests = @()
        }
    }

    $entryManifests = @($entry['manifests'])
    if ($entryManifests -notcontains $normalizedManifestPath) {
        $entry['manifests'] = @($entryManifests + $normalizedManifestPath)
    }
    $entry['repo_root'] = Get-NormalizedPath -Path $RepoRoot
    $entry['effective_vault_profile'] = $VaultProfile
    $entry['last_installed_at'] = $InstalledAt
    $workspaces[$key] = $entry

    $globalHistory = @($Registry['global_manifest_history'])
    if ($globalHistory -notcontains $normalizedManifestPath) {
        $Registry['global_manifest_history'] = @($globalHistory + $normalizedManifestPath)
    }
    $Registry['updated_at'] = Get-Date -Format 's'
    $Registry['schema_version'] = 'install-registry/v1.1'
    $Registry['transaction_status_contract'] = 'v1'
    $Registry['history_ownership_contract'] = 'v1'
    $Registry['manifest_integrity_contract'] = 'sha256-v1'
}

function Refresh-InstallRegistryManifestDigests {
    param($Registry)

    $ownedManifestPaths = @(
        $Registry['workspaces'].Values | ForEach-Object { @($_['manifests']) }
        @($Registry['retired_manifest_history'])
    ) | ForEach-Object { Get-NormalizedPath -Path $_ } | Select-Object -Unique
    $digests = [ordered]@{}
    foreach ($manifestPath in $ownedManifestPaths) {
        $digests[(Get-InstallManifestDigestRegistryKey -ManifestPath $manifestPath)] = Get-InstallStateFileDigest -Path $manifestPath
    }
    $Registry['manifest_digests'] = $digests
    $Registry['manifest_integrity_contract'] = 'sha256-v1'
}

function Assert-RegisteredInstallManifestIdentity {
    param(
        [string]$ManifestPath,
        $Manifest,
        [string]$ExpectedWorkspaceRoot,
        [string]$ExpectedRepoRoot,
        [string]$RegistryPath,
        [string]$ExpectedUserProfile
    )

    if (-not ($Manifest -is [System.Collections.IDictionary])) {
        throw "Registered install manifest must be a JSON object: $ManifestPath"
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedWorkspaceRoot) -or
        [string]::IsNullOrWhiteSpace($ExpectedRepoRoot) -or
        (Get-NormalizedPath -Path $Manifest['workspace_root']) -ne (Get-NormalizedPath -Path $ExpectedWorkspaceRoot) -or
        (Get-NormalizedPath -Path $Manifest['repo_root']) -ne (Get-NormalizedPath -Path $ExpectedRepoRoot)) {
        throw "Registered install manifest identity does not match its owner: $ManifestPath"
    }

    $schemaVersion = [string]$Manifest['schema_version']
    if ($schemaVersion -ne 'install-manifest/v1.2') {
        throw "Unsupported install manifest schema: $schemaVersion"
    }
    if ([string]$Manifest['postimage_identity_contract'] -ne 'v1') {
        throw "Install manifest is missing its postimage identity contract: $ManifestPath"
    }
    if (-not ($Manifest['backups'] -is [System.Collections.IList])) {
        throw "Install manifest backups must be an array: $ManifestPath"
    }
    foreach ($record in @($Manifest['backups'])) {
        if (-not ($record -is [System.Collections.IDictionary]) -or -not $record.Contains('expected_postimage')) {
            throw "Install manifest backup record is missing expected postimage: $ManifestPath"
        }
        Assert-InstallExpectedPostimageShape -Identity $record['expected_postimage'] -Label "Expected postimage for $($record['path'])"
    }

    $expectedBackupBase = Join-Path $ExpectedUserProfile '.dev-harness\backups'
    $manifestBackupRoot = Get-NormalizedPath -Path $Manifest['backup_root']
    if ((Get-NormalizedPath -Path $Manifest['registry_path']) -ne (Get-NormalizedPath -Path $RegistryPath) -or
        -not (Test-PathWithinRoot -Path $manifestBackupRoot -RootPath $expectedBackupBase) -or
        (Get-NormalizedPath -Path $ManifestPath) -ne (Get-NormalizedPath -Path (Join-Path $manifestBackupRoot 'install-manifest.json')) -or
        (Get-NormalizedPath -Path $Manifest['vault_path']) -ne (Get-NormalizedPath -Path (Join-Path $ExpectedWorkspaceRoot '.assistant')) -or
        (Get-NormalizedPath -Path $Manifest['claude_home']) -ne (Get-NormalizedPath -Path (Join-Path $ExpectedUserProfile '.claude')) -or
        (Get-NormalizedPath -Path $Manifest['codex_home']) -ne (Get-NormalizedPath -Path (Join-Path $ExpectedUserProfile '.codex')) -or
        (Get-NormalizedPath -Path $Manifest['agents_home']) -ne (Get-NormalizedPath -Path (Join-Path $ExpectedUserProfile '.agents'))) {
        throw "Registered install manifest path or user identity is invalid: $ManifestPath"
    }
}

function Get-RegisteredManifestStatusUpgradePlan {
    param(
        $Registry,
        [string]$RegistryPath,
        [string]$ExpectedUserProfile,
        [bool]$RequireManifestIntegrity
    )

    $historyIndexes = @{}
    $globalHistory = @($Registry['global_manifest_history'])
    for ($historyIndex = 0; $historyIndex -lt $globalHistory.Count; $historyIndex++) {
        $historyPath = Get-NormalizedPath -Path $globalHistory[$historyIndex]
        if ([string]::IsNullOrWhiteSpace($historyPath)) {
            throw 'Install registry global history contains an empty manifest path'
        }
        if ($historyIndexes.ContainsKey($historyPath)) {
            throw "Install registry global history contains a duplicate manifest: $historyPath"
        }
        $historyIndexes[$historyPath] = $historyIndex
    }

    $manifestOwners = @{}
    foreach ($workspaceEntry in $Registry['workspaces'].GetEnumerator()) {
        $entry = $workspaceEntry.Value
        if (-not ($entry -is [System.Collections.IDictionary])) {
            throw "Workspace registry entry must be an object: $($workspaceEntry.Key)"
        }
        $entryWorkspace = Get-NormalizedPath -Path $entry['workspace_root']
        if ([string]::IsNullOrWhiteSpace($entryWorkspace) -or
            (Get-WorkspaceRegistryKey -Path $entryWorkspace) -ne [string]$workspaceEntry.Key) {
            throw "Workspace registry key/entry identity mismatch: $($workspaceEntry.Key)"
        }
        $entryRepo = Get-NormalizedPath -Path $entry['repo_root']
        if ([string]::IsNullOrWhiteSpace($entryRepo)) {
            throw "Workspace registry entry is missing repo_root: $entryWorkspace"
        }
        $manifestPaths = @($entry['manifests'])
        if ($manifestPaths.Count -eq 0) {
            throw "Workspace registry entry has no install manifests: $entryWorkspace"
        }

        $previousHistoryIndex = -1
        foreach ($manifestPath in $manifestPaths) {
            $normalizedPath = Get-NormalizedPath -Path $manifestPath
            if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
                throw "Workspace registry entry contains an empty manifest path: $entryWorkspace"
            }
            if ($manifestOwners.ContainsKey($normalizedPath)) {
                throw "Install manifest is registered by more than one workspace: $normalizedPath"
            }
            if (-not $historyIndexes.ContainsKey($normalizedPath)) {
                throw "Registered workspace manifest is missing from global history: $normalizedPath"
            }
            $currentHistoryIndex = [int]$historyIndexes[$normalizedPath]
            if ($currentHistoryIndex -le $previousHistoryIndex) {
                throw "Workspace manifest order disagrees with global history: $entryWorkspace"
            }
            $previousHistoryIndex = $currentHistoryIndex

            $raw = Read-FileUtf8 -Path $normalizedPath
            if ([string]::IsNullOrWhiteSpace($raw)) {
                throw "Registered install manifest is missing: $normalizedPath"
            }
            Assert-InstallManifestRegistryDigest `
                -Registry $Registry `
                -ManifestPath $normalizedPath `
                -RequireManifestIntegrity $RequireManifestIntegrity
            $manifest = ConvertFrom-JsonDocument -Json $raw
            Assert-RegisteredInstallManifestIdentity `
                -ManifestPath $normalizedPath `
                -Manifest $manifest `
                -ExpectedWorkspaceRoot $entryWorkspace `
                -ExpectedRepoRoot $entryRepo `
                -RegistryPath $RegistryPath `
                -ExpectedUserProfile $ExpectedUserProfile
            if ([string]$manifest['transaction_status'] -ne 'committed') {
                throw "Registered install manifest is not committed: $normalizedPath"
            }
            $manifestOwners[$normalizedPath] = [string]$workspaceEntry.Key
        }
    }

    $previousRetiredHistoryIndex = -1
    foreach ($retiredManifestPath in @($Registry['retired_manifest_history'])) {
        $normalizedPath = Get-NormalizedPath -Path $retiredManifestPath
        if ([string]::IsNullOrWhiteSpace($normalizedPath) -or $manifestOwners.ContainsKey($normalizedPath)) {
            throw "Retired manifest ownership is empty or duplicates an active owner: $retiredManifestPath"
        }
        if (-not $historyIndexes.ContainsKey($normalizedPath)) {
            throw "Retired manifest is missing from global history: $normalizedPath"
        }
        $currentHistoryIndex = [int]$historyIndexes[$normalizedPath]
        if ($currentHistoryIndex -le $previousRetiredHistoryIndex) {
            throw 'Retired manifest order disagrees with global history'
        }
        $previousRetiredHistoryIndex = $currentHistoryIndex

        $raw = Read-FileUtf8 -Path $normalizedPath
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw "Retired install manifest is missing: $normalizedPath"
        }
        Assert-InstallManifestRegistryDigest `
            -Registry $Registry `
            -ManifestPath $normalizedPath `
            -RequireManifestIntegrity $RequireManifestIntegrity
        $manifest = ConvertFrom-JsonDocument -Json $raw
        $retiredWorkspace = Get-NormalizedPath -Path $manifest['workspace_root']
        $retiredRepo = Get-NormalizedPath -Path $manifest['repo_root']
        Assert-RegisteredInstallManifestIdentity `
            -ManifestPath $normalizedPath `
            -Manifest $manifest `
            -ExpectedWorkspaceRoot $retiredWorkspace `
            -ExpectedRepoRoot $retiredRepo `
            -RegistryPath $RegistryPath `
            -ExpectedUserProfile $ExpectedUserProfile
        if ([string]$manifest['transaction_status'] -ne 'committed') {
            throw "Retired install manifest is not committed: $normalizedPath"
        }
        $manifestOwners[$normalizedPath] = 'retired'
    }
    foreach ($historyPath in $historyIndexes.Keys) {
        if (-not $manifestOwners.ContainsKey($historyPath)) {
            throw "Global history manifest has no registered workspace owner: $historyPath"
        }
    }
    return @()
}

function Import-LegacyActiveInstall {
    param(
        $Registry,
        [string]$PointerPath,
        [string]$ExpectedUserProfile,
        [string]$ExpectedRepoRoot
    )

    if (Test-LegacyPointerMigrationMarked -UserProfile $ExpectedUserProfile -PointerPath $PointerPath) {
        return $null
    }
    $pointerDigest = Get-InstallStateFileDigest -Path $PointerPath
    $raw = Read-FileUtf8 -Path $PointerPath
    $receipt = Get-LegacyRebaselineReceiptInfo `
        -Registry $Registry `
        -RegistryPath (Join-Path $ExpectedUserProfile '.dev-harness\install-registry.json') `
        -WorkspaceRoot $script:WorkspaceRoot `
        -RepoRoot $ExpectedRepoRoot `
        -UserProfile $ExpectedUserProfile
    if ($null -ne $receipt) {
        if ((Get-NormalizedPath -Path $receipt['legacy_pointer_path']) -eq (Get-NormalizedPath -Path $PointerPath) -and
            [string]$receipt['legacy_pointer_sha256'] -eq $pointerDigest) {
            if ($pointerDigest -match '^[0-9a-f]{64}$' -and
                -not (Test-LegacyPointerMigrationMarked -UserProfile $ExpectedUserProfile -PointerPath $PointerPath)) {
                Assert-LegacyPointerMigrationMarkerWritable -UserProfile $ExpectedUserProfile -PointerPath $PointerPath
                Set-LegacyPointerMigrationMarked `
                    -UserProfile $ExpectedUserProfile `
                    -PointerPath $PointerPath `
                    -ExpectedPointerDigest $pointerDigest
            }
            return $null
        }
        throw 'LIVE_UPDATE_REQUIRED: legacy-active-pointer-receipt-mismatch'
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    if ((Get-InstallStateFileDigest -Path $PointerPath) -ne $pointerDigest) {
        Write-Warning "Ignoring a legacy active-install pointer that changed while being read: $PointerPath"
        return $null
    }

    $registrySnapshot = ConvertTo-NormalizedObject -Value $Registry
    try {
        $pointer = ConvertFrom-JsonDocument -Json $raw
        $manifestPath = Get-NormalizedPath -Path $pointer['manifest_path']
        $manifestRaw = Read-FileUtf8 -Path $manifestPath
        if ([string]::IsNullOrWhiteSpace($manifestRaw)) {
            Write-Warning "Ignoring invalid legacy active-install pointer: $PointerPath"
            return $null
        }

        $manifest = ConvertFrom-JsonDocument -Json $manifestRaw
        $expectedClaudeHome = Get-NormalizedPath -Path (Join-Path $ExpectedUserProfile '.claude')
        if ((Get-NormalizedPath -Path $manifest['claude_home']) -ne $expectedClaudeHome) {
            return $null
        }
        if ((Get-NormalizedPath -Path $manifest['repo_root']) -ne (Get-NormalizedPath -Path $ExpectedRepoRoot)) {
            Write-Warning "Ignoring legacy active-install pointer owned by another repo: $PointerPath"
            return $null
        }
        $legacyTransactionStatus = [string]$manifest['transaction_status']
        if (-not [string]::IsNullOrWhiteSpace($legacyTransactionStatus) -and $legacyTransactionStatus -ne 'committed') {
            Write-Warning "Ignoring non-committed legacy active-install pointer: $PointerPath"
            return $null
        }

        $workspaceRoot = Get-NormalizedPath -Path $manifest['workspace_root']
        if ($workspaceRoot -ne (Get-NormalizedPath -Path $pointer['workspace_root'])) {
            Write-Warning "Ignoring mismatched legacy active-install pointer: $PointerPath"
            return $null
        }
        if ([string]$manifest['schema_version'] -ne 'install-manifest/v1.2') {
            throw 'LIVE_UPDATE_REQUIRED: legacy-install-state'
        }

        if ((Get-InstallStateFileDigest -Path $PointerPath) -ne $pointerDigest) {
            Write-Warning "Ignoring a legacy active-install pointer that changed while being validated: $PointerPath"
            return $null
        }
        Add-ManifestToRegistry `
            -Registry $Registry `
            -ManifestPath $manifestPath `
            -WorkspaceRoot $workspaceRoot `
            -RepoRoot $manifest['repo_root'] `
            -VaultProfile $manifest['effective_vault_profile'] `
            -InstalledAt $manifest['installed_at']
        Assert-InstallManifestRegistryDigest `
            -Registry $Registry `
            -ManifestPath $manifestPath `
            -RequireManifestIntegrity $false
        return $pointerDigest
    } catch {
        $Registry.Clear()
        foreach ($entry in $registrySnapshot.GetEnumerator()) {
            $Registry[$entry.Key] = $entry.Value
        }
        if ($_.Exception.Message -like 'LIVE_UPDATE_REQUIRED: legacy-install-state*') {
            throw
        }
        Write-Warning "Ignoring unreadable legacy active-install pointer: $PointerPath"
        return $null
    }
}

function Write-InstallRegistry {
    param([string]$Path, $Registry, [Parameter(Mandatory = $true)][string]$ExpectedCurrentDigest)
    Write-InstallStateTextAtomic -Path $Path -Content (ConvertTo-ManifestJsonDocument -Value $Registry) -ExpectedCurrentDigest $ExpectedCurrentDigest
}

function Resolve-PendingInstallTransaction {
    param(
        [string]$JournalPath,
        [string]$ExpectedUserProfile,
        [string]$ExpectedRegistryPath
    )

    if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) {
        return
    }
    $journal = Read-JsonObject -Path $JournalPath
    if ([string]$journal['schema_version'] -eq 'install-transaction/v1.0') {
        throw "LIVE_UPDATE_REQUIRED: legacy-install-state; manual recovery is required for legacy install transaction: $JournalPath"
    }
    if (-not ($journal -is [System.Collections.IDictionary]) -or
        [string]$journal['schema_version'] -ne 'install-transaction/v1.1' -or
        [string]$journal['registry_schema_version'] -ne 'install-registry/v1.1' -or
        [string]$journal['manifest_schema_version'] -ne 'install-manifest/v1.2' -or
        [string]$journal['postimage_identity_contract'] -ne 'v1' -or
        (Get-NormalizedPath -Path $journal['user_profile']) -ne (Get-NormalizedPath -Path $ExpectedUserProfile) -or
        (Get-NormalizedPath -Path $journal['registry_path']) -ne (Get-NormalizedPath -Path $ExpectedRegistryPath)) {
        throw "Unsupported or mismatched pending install transaction: $JournalPath"
    }

    $manifestPath = Get-NormalizedPath -Path $journal['manifest_path']
    $manifestRaw = Read-FileUtf8 -Path $manifestPath
    if ([string]::IsNullOrWhiteSpace($manifestRaw)) {
        throw "Pending install transaction has no recovery manifest: $manifestPath"
    }
    $manifest = ConvertFrom-JsonDocument -Json $manifestRaw
    if ((Get-NormalizedPath -Path $manifest['repo_root']) -ne (Get-NormalizedPath -Path $journal['repo_root']) -or
        (Get-NormalizedPath -Path $manifest['workspace_root']) -ne (Get-NormalizedPath -Path $journal['workspace_root'])) {
        throw "Pending install journal does not match its manifest identity: $JournalPath"
    }
    if ([string]$manifest['schema_version'] -ne 'install-manifest/v1.2' -or
        [string]$manifest['postimage_identity_contract'] -ne 'v1') {
        throw "Pending install transaction requires install-manifest/v1.2 with postimage identity: $manifestPath"
    }
    Assert-RegisteredInstallManifestIdentity `
        -ManifestPath $manifestPath `
        -Manifest $manifest `
        -ExpectedWorkspaceRoot $journal['workspace_root'] `
        -ExpectedRepoRoot $journal['repo_root'] `
        -RegistryPath $ExpectedRegistryPath `
        -ExpectedUserProfile $ExpectedUserProfile
    $transactionStatus = [string]$manifest['transaction_status']
    if ($transactionStatus -eq 'recovered') {
        $expectedPreimageDigest = [string]$journal['registry_preimage_sha256']
        if ($expectedPreimageDigest -notmatch '^(missing|[0-9a-f]{64})$' -or
            [string]$manifest['registry_preimage_sha256'] -ne $expectedPreimageDigest -or
            (Get-InstallStateFileDigest -Path $ExpectedRegistryPath) -ne $expectedPreimageDigest) {
            throw "Recovered install transaction registry preimage mismatch: $JournalPath"
        }
        Remove-Item -LiteralPath $JournalPath -Force
        return
    }

    $registry = Read-JsonObject -Path $ExpectedRegistryPath
    if ($transactionStatus -eq 'committed') {
        $expectedStatusContract = [string]$journal['postimage_transaction_status_contract']
        if ($expectedStatusContract -ne 'v1' -or
            [string]$journal['postimage_history_ownership_contract'] -ne 'v1' -or
            [string]$journal['postimage_manifest_integrity_contract'] -ne 'sha256-v1') {
            throw "Pending install transaction is missing its committed postimage contract: $JournalPath"
        }
        if (-not ($registry -is [System.Collections.IDictionary]) -or
            [string]$registry['schema_version'] -ne 'install-registry/v1.1' -or
            [string]$registry['history_ownership_contract'] -ne [string]$journal['postimage_history_ownership_contract'] -or
            [string]$registry['manifest_integrity_contract'] -ne [string]$journal['postimage_manifest_integrity_contract'] -or
            [string]$registry['transaction_status_contract'] -ne $expectedStatusContract -or
            -not ($registry['workspaces'] -is [System.Collections.IDictionary]) -or
            -not ($registry['global_manifest_history'] -is [System.Collections.IList]) -or
            -not ($registry['retired_manifest_history'] -is [System.Collections.IList]) -or
            -not ($registry['manifest_digests'] -is [System.Collections.IDictionary])) {
            throw "Pending install transaction registry is not a committed postimage: $JournalPath"
        }
        $workspaceKey = Get-WorkspaceRegistryKey -Path $journal['workspace_root']
        if (-not $registry['workspaces'].Contains($workspaceKey)) {
            throw "Pending install transaction workspace is not registered: $JournalPath"
        }
        $entry = $registry['workspaces'][$workspaceKey]
        if (-not ($entry -is [System.Collections.IDictionary])) {
            throw "Pending install transaction workspace entry is invalid: $JournalPath"
        }
        $entryManifestPaths = @($entry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        $globalHistory = @($registry['global_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        if ((Get-NormalizedPath -Path $entry['workspace_root']) -ne (Get-NormalizedPath -Path $journal['workspace_root']) -or
            (Get-NormalizedPath -Path $entry['repo_root']) -ne (Get-NormalizedPath -Path $journal['repo_root']) -or
            $entryManifestPaths.Count -eq 0 -or $entryManifestPaths[-1] -ne $manifestPath -or
            $globalHistory.Count -eq 0 -or $globalHistory[-1] -ne $manifestPath -or
            [string]$manifest['registry_preimage_sha256'] -ne [string]$journal['registry_preimage_sha256']) {
            throw "Pending install transaction owner or history does not match its committed postimage: $JournalPath"
        }
        $currentDigestKeys = @($registry['manifest_digests'].Keys | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
        $expectedDigestKeys = @($globalHistory | ForEach-Object { Get-InstallManifestDigestRegistryKey -ManifestPath $_ } | Sort-Object -Unique)
        if (($currentDigestKeys -join "`n") -ne ($expectedDigestKeys -join "`n")) {
            throw "Pending install transaction registry digest keys do not match owner history: $JournalPath"
        }
        Assert-InstallManifestRegistryDigest `
            -Registry $registry `
            -ManifestPath $manifestPath `
            -RequireManifestIntegrity $true
        [void](Get-RegisteredManifestStatusUpgradePlan `
            -Registry $registry `
            -RegistryPath $ExpectedRegistryPath `
            -ExpectedUserProfile $ExpectedUserProfile `
            -RequireManifestIntegrity $true)
        if (-not [string]::IsNullOrWhiteSpace([string]$journal['legacy_pointer_import_digest'])) {
            $expectedLegacyPointerPath = Get-NormalizedPath -Path (Join-Path $journal['repo_root'] 'backups\active-install.json')
            if ([string]$journal['legacy_pointer_import_digest'] -notmatch '^[0-9a-f]{64}$' -or
                (Get-NormalizedPath -Path $journal['legacy_pointer_path']) -ne $expectedLegacyPointerPath) {
                throw "Pending install transaction legacy pointer identity is invalid: $JournalPath"
            }
            Set-LegacyPointerMigrationMarked `
                -UserProfile $ExpectedUserProfile `
                -PointerPath $journal['legacy_pointer_path'] `
                -ExpectedPointerDigest $journal['legacy_pointer_import_digest']
        }
        Remove-Item -LiteralPath $JournalPath -Force
        return
    }
    throw "A pending install transaction must be recovered before install. Run uninstall.ps1 -RecoveryManifestPath '$manifestPath'"
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

    return ,$result
}

function Ensure-ArrayValue {
    param($Value)

    $items = New-Object System.Collections.ArrayList

    if ($null -eq $Value) {
        return ,$items
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-NormalizedObject -Value $item))
        }
        return ,$items
    }

    [void]$items.Add((ConvertTo-NormalizedObject -Value $Value))
    return ,$items
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

    foreach ($key in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'PostToolUse')) {
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
    param(
        [switch]$EscapeForCode,
        [switch]$EscapeForPowerShellSingleQuotedLiteral
    )

    $tokens = [ordered]@{}
    foreach ($key in $script:RawRenderTokens.Keys) {
        $value = $script:RawRenderTokens[$key]
        if ($EscapeForCode -and $key -ne '__RENDER_AT_INSTALL__') {
            $value = $value.Replace('\', '\\')
        } elseif ($EscapeForPowerShellSingleQuotedLiteral) {
            $value = $value.Replace("'", "''")
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
    } elseif ($extension -in @('.ps1', '.psm1', '.psd1')) {
        Get-RenderTokenMap -EscapeForPowerShellSingleQuotedLiteral
    } else {
        Get-RenderTokenMap
    }

    $tokenPattern = @(
        $tokens.Keys |
            Sort-Object { ([string]$_).Length } -Descending |
            ForEach-Object { [System.Text.RegularExpressions.Regex]::Escape([string]$_) }
    ) -join '|'
    if ([string]::IsNullOrEmpty($tokenPattern)) {
        return $Content
    }

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param([System.Text.RegularExpressions.Match]$Match)
        return [string]$tokens[[string]$Match.Value]
    }
    return [System.Text.RegularExpressions.Regex]::Replace($Content, $tokenPattern, $evaluator)
}

function Install-RenderedFile {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [switch]$SkipIfExists,
        [switch]$RecordBackup,
        [ValidateSet('managed', 'create-if-missing', 'user-owned')]
        [string]$Ownership = 'managed'
    )

    if ($SkipIfExists -and (Test-Path -LiteralPath $TargetPath)) {
        return
    }

    $raw = Read-FileUtf8 -Path $SourcePath
    if ($null -eq $raw) {
        throw "Missing template source: $SourcePath"
    }

    $rendered = Render-Content -Content $raw -TargetPath $TargetPath
    Write-ManagedInstallText -Path $TargetPath -Content $rendered -RecordBackup:$RecordBackup -Ownership $Ownership
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

    $sharedJson = if ([string]::IsNullOrWhiteSpace($RenderedSharedJson)) {
        '{}'
    } else {
        $RenderedSharedJson
    }

    $existingSnapshot = Read-InstallTextSnapshot -Path $ExistingPath
    $existingJson = $existingSnapshot.Content
    if ([string]::IsNullOrWhiteSpace($existingJson)) {
        $existingJson = '{}'
    }

    $overlayJson = Read-FileUtf8 -Path $OverlayPath
    if ([string]::IsNullOrWhiteSpace($overlayJson)) {
        $overlayJson = '{}'
    }

    $sharedObject = ConvertFrom-JsonDocument -Json $sharedJson
    $existingObject = ConvertFrom-JsonDocument -Json $existingJson
    $overlayObject = ConvertFrom-JsonDocument -Json $overlayJson

    return [pscustomobject]@{
        Content = (ConvertTo-JsonDocument -Value (Merge-SettingsLocal -Shared $sharedObject -Existing $existingObject -Overlay $overlayObject))
        Identity = $existingSnapshot.Identity
    }
}

function Test-IsHarnessHookCommand {
    param(
        [string]$Command,
        [System.Collections.Generic.HashSet[string]]$ManagedCommands
    )

    if ([string]::IsNullOrWhiteSpace($Command) -or $null -eq $ManagedCommands) {
        return $false
    }
    return $ManagedCommands.Contains($Command.Trim())
}

function Merge-ClaudeSettingsJsonText {
    param(
        [string]$RenderedHooksJson,
        [string]$ExistingPath
    )

    $existingSnapshot = Read-InstallTextSnapshot -Path $ExistingPath
    $existingJson = $existingSnapshot.Content
    if ([string]::IsNullOrWhiteSpace($existingJson)) {
        $existingJson = '{}'
    }

    $result = ConvertFrom-JsonDocument -Json $existingJson
    $managedHooks = ConvertFrom-JsonDocument -Json $RenderedHooksJson
    $managedCommands = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($eventName in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'PostToolUse')) {
        foreach ($section in @(if ($managedHooks.Contains($eventName)) { @($managedHooks[$eventName]) } else { @() })) {
            foreach ($hook in @($section['hooks'])) {
                if ($hook -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$hook['command'])) {
                    [void]$managedCommands.Add(([string]$hook['command']).Trim())
                }
            }
        }
    }
    [void]$managedCommands.Add(('pwsh -NoProfile -NonInteractive -File "{0}"' -f (Join-Path (Split-Path -Parent $ExistingPath) 'hooks-memory\pretooluse.ps1')))
    [void]$managedCommands.Add(('node "{0}"' -f (Join-Path (Split-Path -Parent $ExistingPath) 'hooks-memory\userpromptsubmit.js')))
    [void]$managedCommands.Add(('node "{0}"' -f (Join-Path (Split-Path -Parent $ExistingPath) 'hooks-memory\stop.js')))
    [void]$managedCommands.Add(('node "{0}"' -f (Join-Path (Split-Path -Parent $ExistingPath) 'hooks-memory\posttooluse.js')))
    $hooks = if ($result.Contains('hooks')) {
        if (-not ($result['hooks'] -is [System.Collections.IDictionary])) {
            throw "Claude settings hooks must be a JSON object: $ExistingPath"
        }
        ConvertTo-NormalizedObject -Value $result['hooks']
    } else {
        [ordered]@{}
    }

    foreach ($eventName in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'PostToolUse')) {
        $sections = New-Object System.Collections.ArrayList
        foreach ($section in @(if ($hooks.Contains($eventName)) { @($hooks[$eventName]) } else { @() })) {
            if (-not ($section -is [System.Collections.IDictionary]) -or -not $section.Contains('hooks')) {
                [void]$sections.Add((ConvertTo-NormalizedObject -Value $section))
                continue
            }

            $preservedHooks = New-Object System.Collections.ArrayList
            $removedManagedHook = $false
            foreach ($hook in @($section['hooks'])) {
                $command = if ($hook -is [System.Collections.IDictionary] -and $hook.Contains('command')) { [string]$hook['command'] } else { '' }
                if (Test-IsHarnessHookCommand -Command $command -ManagedCommands $managedCommands) {
                    $removedManagedHook = $true
                } else {
                    [void]$preservedHooks.Add((ConvertTo-NormalizedObject -Value $hook))
                }
            }

            if (-not $removedManagedHook) {
                [void]$sections.Add((ConvertTo-NormalizedObject -Value $section))
            } elseif ($preservedHooks.Count -gt 0) {
                $preservedSection = ConvertTo-NormalizedObject -Value $section
                $preservedSection['hooks'] = $preservedHooks
                [void]$sections.Add($preservedSection)
            }
        }

        foreach ($managedSection in @(if ($managedHooks.Contains($eventName)) { @($managedHooks[$eventName]) } else { @() })) {
            [void]$sections.Add((ConvertTo-NormalizedObject -Value $managedSection))
        }
        if ($sections.Count -gt 0) {
            $hooks[$eventName] = $sections
        } else {
            $hooks.Remove($eventName)
        }
    }

    $result['hooks'] = $hooks
    return [pscustomobject]@{
        Content = (ConvertTo-JsonDocument -Value $result)
        Identity = $existingSnapshot.Identity
    }
}

function New-ClaudeSettingsPostimageIdentity {
    param($ManagedSettings)

    $managedHooks = New-Object System.Collections.ArrayList
    foreach ($eventName in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'PostToolUse')) {
        foreach ($section in @(if ($ManagedSettings.Contains($eventName)) { @($ManagedSettings[$eventName]) } else { @() })) {
            if (-not ($section -is [System.Collections.IDictionary]) -or
                -not ($section['hooks'] -is [System.Collections.IList])) {
                throw "Rendered Claude managed hook section is invalid: $eventName"
            }
            $sectionIdentity = [ordered]@{}
            foreach ($key in $section.Keys) {
                if ([string]$key -ne 'hooks') {
                    $sectionIdentity[[string]$key] = ConvertTo-NormalizedObject -Value $section[$key]
                }
            }
            foreach ($hook in @($section['hooks'])) {
                if (-not ($hook -is [System.Collections.IDictionary]) -or
                    [string]::IsNullOrWhiteSpace([string]$hook['command'])) {
                    throw "Rendered Claude managed hook is invalid: $eventName"
                }
                [void]$managedHooks.Add([ordered]@{
                    event = $eventName
                    path = "hooks.$eventName"
                    section = $sectionIdentity
                    hook = (ConvertTo-NormalizedObject -Value $hook)
                    multiplicity = 1
                })
            }
        }
    }
    return [ordered]@{
        mode = 'semantic'
        contract = 'claude-settings/v1'
        managed_hooks = $managedHooks
    }
}

function Backup-IfNeeded {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)]$ExpectedPostimage,
        [ValidateSet('managed', 'create-if-missing', 'user-owned')]
        [string]$Ownership = 'managed',
        [switch]$AllowFinalReparsePoint
    )

    $normalizedPath = Get-NormalizedPath -Path $Path
    Assert-InstallExpectedPostimageShape -Identity $ExpectedPostimage -Label "Expected postimage for $normalizedPath"
    if (-not $script:BackedUpPaths.Add($normalizedPath)) {
        $existingRecord = @($script:Manifest.backups | Where-Object {
            (Get-NormalizedPath -Path $_['path']) -eq $normalizedPath
        } | Select-Object -First 1)
        if ($existingRecord.Count -ne 1 -or
            (ConvertTo-Json -InputObject $existingRecord[0]['expected_postimage'] -Depth 30 -Compress) -ne
            (ConvertTo-Json -InputObject $ExpectedPostimage -Depth 30 -Compress)) {
            throw "Conflicting expected postimage for repeated backup target: $normalizedPath"
        }
        return
    }

    $scope = $null
    foreach ($userGlobalRoot in @($script:UserGlobalRoots)) {
        if (Test-PathWithinRoot -Path $normalizedPath -RootPath $userGlobalRoot) {
            $scope = 'user-global'
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($scope) -and (Test-PathWithinRoot -Path $normalizedPath -RootPath $script:WorkspaceRoot)) {
        $scope = 'workspace'
    }
    if ([string]::IsNullOrWhiteSpace($scope)) {
        throw "Cannot classify backup outside workspace and managed user-global roots: $normalizedPath"
    }
    $backupTargetLabel = if ($scope -eq 'workspace') { 'Workspace backup target' } else { 'User-global backup target' }
    $currentItem = Get-Item -LiteralPath $normalizedPath -Force -ErrorAction SilentlyContinue
    $currentIsReparsePoint = $null -ne $currentItem -and [bool]($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    $exactPostimage = [string]$ExpectedPostimage['mode'] -eq 'exact'
    [void](Assert-InstallStatePathHasNoReparsePoint `
        -Path $normalizedPath `
        -Label $backupTargetLabel `
        -AllowFinalReparsePoint:($AllowFinalReparsePoint -or ($currentIsReparsePoint -and $exactPostimage)))
    $script:Manifest.managed_backup_targets = @($script:Manifest.managed_backup_targets + $normalizedPath | Select-Object -Unique)

    $record = [ordered]@{
        path = $normalizedPath
        existed = (Test-Path -LiteralPath $normalizedPath)
        backup_path = $null
        item_type = 'missing'
        link_type = $null
        link_target = $null
        backup_payload_sha256 = $null
        scope = $scope
        ownership = $Ownership
        expected_postimage = (ConvertTo-NormalizedObject -Value $ExpectedPostimage)
    }

    if ($record.existed) {
        $item = Get-Item -LiteralPath $normalizedPath -Force
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
            $preimageIdentity = Get-InstallManagedPathIdentity -Path $normalizedPath
            $safeName = Get-BackupSafeName -Path $normalizedPath
            $backupPath = Join-Path $script:BackupRoot $safeName
            Ensure-Directory -Path (Split-Path -Parent $backupPath)
            if ($record.item_type -eq 'directory') {
                Copy-InstallExactDirectory -SourcePath $normalizedPath -Path $backupPath
            } else {
                Copy-InstallStateFileAtomic -SourcePath $normalizedPath -Path $backupPath -ExpectedCurrentIdentity (New-InstallExactMissingIdentity) -ExpectedDesiredIdentity $preimageIdentity
            }
            $backupIdentity = Get-InstallManagedPathIdentity -Path $backupPath
            if (-not (Test-InstallExactIdentityEqual -Left $preimageIdentity -Right $backupIdentity)) {
                throw "Backup copy did not preserve exact preimage identity: $normalizedPath"
            }
            $record.backup_path = $backupPath
            $record.backup_payload_sha256 = Get-InstallBackupPayloadDigest -Path $backupPath -ItemType $record.item_type
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

    $expectedPostimage = New-InstallExactLinkIdentity -Path $LinkPath -LinkType 'Junction' -Target $TargetPath
    $sourceIdentity = Get-InstallManagedPathIdentity -Path $LinkPath
    if (Test-InstallExactIdentityEqual -Left $sourceIdentity -Right $expectedPostimage) { return }
    Backup-IfNeeded -Path $LinkPath -ExpectedPostimage $expectedPostimage -AllowFinalReparsePoint
    [void](Invoke-InstallExactPathTransition `
        -Path $LinkPath `
        -SourceIdentity $sourceIdentity `
        -DesiredIdentity $expectedPostimage `
        -MaterializeDesired { param($BuildPath) New-Item -ItemType Junction -Path $BuildPath -Target $TargetPath | Out-Null })
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
        [string]$RepoSkillsPath,
        [string[]]$ManagedEntryNames
    )

    $hotSwapPreservedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$hotSwapPreservedNames.Add('.system')

    $managedEntries = [ordered]@{}
    foreach ($name in $ManagedEntryNames) {
        $entryPath = Join-Path $RepoSkillsPath $name
        if (-not (Test-Path -LiteralPath $entryPath)) {
            throw "Preset skill entry is missing: $entryPath"
        }
        $managedEntries[$name] = $entryPath
    }

    $rootTarget = Get-JunctionTarget -Path $HostSkillsPath
    if ($null -ne $rootTarget) {
        $rootStagingPath = Join-Path $script:BackupRoot ('_skills-postimage-' + (Get-InstallStateIdentityHash -Value (Get-NormalizedPath -Path $HostSkillsPath)))
        Remove-PathIfExists -Path $rootStagingPath
        Ensure-Directory -Path $rootStagingPath
        try {
            foreach ($name in $managedEntries.Keys) {
                New-Item -ItemType Junction -Path (Join-Path $rootStagingPath $name) -Target $managedEntries[$name] | Out-Null
            }
            $rootExpectedPostimage = New-InstallExactDirectoryIdentity -Path $rootStagingPath
            $rootSourceIdentity = Get-InstallManagedPathIdentity -Path $HostSkillsPath
            Backup-IfNeeded -Path $HostSkillsPath -ExpectedPostimage $rootExpectedPostimage -AllowFinalReparsePoint
            [void](Invoke-InstallExactPathTransition `
                -Path $HostSkillsPath `
                -SourceIdentity $rootSourceIdentity `
                -DesiredIdentity $rootExpectedPostimage `
                -MaterializeDesired { param($BuildPath) Move-Item -LiteralPath $rootStagingPath -Destination $BuildPath })
        } finally {
            Remove-PathIfExists -Path $rootStagingPath
        }
    }

    Ensure-Directory -Path $HostSkillsPath

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

        if ($null -ne $expectedTarget) {
            Ensure-Junction -LinkPath $entry.FullName -TargetPath $expectedTarget
            continue
        }
        $entrySourceIdentity = Get-InstallManagedPathIdentity -Path $entry.FullName
        $entryExpectedPostimage = New-InstallExactMissingIdentity
        Backup-IfNeeded -Path $entry.FullName -ExpectedPostimage $entryExpectedPostimage -AllowFinalReparsePoint
        [void](Invoke-InstallExactPathTransition `
            -Path $entry.FullName `
            -SourceIdentity $entrySourceIdentity `
            -DesiredIdentity $entryExpectedPostimage)
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

function Update-CodexManagedConfig {
    param(
        [string]$TemplatePath,
        [string]$ManagedTargetPath
    )

    $renderedManaged = Render-Content -Content (Read-FileUtf8 -Path $TemplatePath) -TargetPath $ManagedTargetPath
    $newManagedContent = $renderedManaged.Trim() + "`r`n"

    Write-ManagedInstallText -Path $ManagedTargetPath -Content $newManagedContent -RecordBackup
}

function Install-VaultTemplate {
    param(
        [string]$TemplateRoot,
        [string]$TargetRoot
    )

    function Get-VaultOwnership {
        param([string]$RelativePath)

        if ($RelativePath -in @('工作流\项目约定.md', '配置\用户偏好.md')) {
            return 'user-owned'
        }

        if ($RelativePath -like '运行时\*' -or
            $RelativePath -like '.obsidian\*' -or
            $RelativePath -in @('首页.md', 'MEMORY.md', '配置\系统信息.md', '配置\工具与组件.md', '配置\引导状态.md')) {
            return 'create-if-missing'
        }

        return 'managed'
    }

    foreach ($source in Get-ChildItem -LiteralPath $TemplateRoot -Recurse -File) {
        $relative = $source.FullName.Substring($TemplateRoot.Length).TrimStart('\')
        $targetRelative = if ($relative.EndsWith('.template')) {
            $relative.Substring(0, $relative.Length - '.template'.Length)
        } else {
            $relative
        }
        $targetPath = Join-Path $TargetRoot $targetRelative
        $ownership = Get-VaultOwnership -RelativePath $targetRelative
        $shouldOverwrite = $ownership -eq 'managed'

        if ((Test-Path -LiteralPath $targetPath) -and -not $shouldOverwrite) {
            continue
        }

        $extension = [System.IO.Path]::GetExtension($source.FullName).ToLowerInvariant()
        if ($extension -in @('.template', '.md', '.json', '.js', '.mjs', '.toml', '.txt') -or $relative.EndsWith('.template')) {
            Install-RenderedFile `
                -SourcePath $source.FullName `
                -TargetPath $targetPath `
                -SkipIfExists:(-not $shouldOverwrite) `
                -RecordBackup:$shouldOverwrite `
                -Ownership $ownership
            continue
        }

        if ($shouldOverwrite) {
            $binaryExpectedPostimage = [ordered]@{
                mode = 'exact'
                item_type = 'file'
                sha256 = (Get-InstallStateFileDigest -Path $source.FullName)
            }
            $binarySourceIdentity = Get-InstallManagedPathIdentity -Path $targetPath
            Backup-IfNeeded -Path $targetPath -Ownership $ownership -ExpectedPostimage $binaryExpectedPostimage
            if ([string]$binarySourceIdentity['item_type'] -notin @('missing','file')) {
                [void](Invoke-InstallExactPathTransition `
                    -Path $targetPath `
                    -SourceIdentity $binarySourceIdentity `
                    -DesiredIdentity $binaryExpectedPostimage `
                    -MaterializeDesired ({ param($BuildPath) Copy-InstallStateFileAtomic -SourcePath $source.FullName -Path $BuildPath -ExpectedCurrentIdentity (New-InstallExactMissingIdentity) -ExpectedDesiredIdentity $binaryExpectedPostimage }.GetNewClosure()))
                continue
            }
        }
        $binaryCurrentIdentity = if ($shouldOverwrite) { $binarySourceIdentity } else { New-InstallExactMissingIdentity }
        $binaryDesiredIdentity = if ($shouldOverwrite) { $binaryExpectedPostimage } else { Get-InstallManagedPathIdentity -Path $source.FullName }
        Copy-InstallStateFileAtomic -SourcePath $source.FullName -Path $targetPath -ExpectedCurrentIdentity $binaryCurrentIdentity -ExpectedDesiredIdentity $binaryDesiredIdentity
    }
}

function Test-ExistingFullVault {
    param([string]$TargetRoot)

    foreach ($relativePath in @('工作流', '.obsidian', '首页.md', 'MEMORY.md')) {
        if (Test-Path -LiteralPath (Join-Path $TargetRoot $relativePath)) {
            return $true
        }
    }

    $weakMarkerCount = 0
    foreach ($relativePath in @('配置', '模板')) {
        if (Test-Path -LiteralPath (Join-Path $TargetRoot $relativePath)) {
            $weakMarkerCount++
        }
    }

    return ($weakMarkerCount -eq 2)
}

function Get-InstallPresetDefinition {
    param(
        [Parameter(Mandatory)][ValidateSet('core','governed','full')][string]$Name,
        [Parameter(Mandatory)][string]$RepoSkillsPath
    )

    $coreSkills = @('.system','entry-router','orchestrator','plan','implement','review','test','spec')
    if ($Name -eq 'core') {
        return [ordered]@{
            name = 'core'
            features = @('core','v1-compatibility')
            skills = $coreSkills
            hooks = @('pretooluse.ps1','stop.js','workspace-resolver.js')
            vault_profile = 'minimal'
        }
    }
    if ($Name -eq 'governed') {
        return [ordered]@{
            name = 'governed'
            features = @('core','v1-compatibility','governed')
            skills = @($coreSkills + @('planning','audit'))
            hooks = @('pretooluse.ps1','stop.js','workspace-resolver.js')
            vault_profile = 'minimal'
        }
    }
    $fullSkills = @(
        '.system'
        Get-ChildItem -LiteralPath $RepoSkillsPath -Force -Directory |
            Where-Object { $_.Name -cne '.system' } |
            Sort-Object Name |
            Select-Object -ExpandProperty Name
    )
    return [ordered]@{
        name = 'full'
        features = @('core','v1-compatibility','governed','memory','team','md-html','adapters','provider-references')
        skills = $fullSkills
        hooks = @('pretooluse.ps1','userpromptsubmit.js','stop.js','workspace-resolver.js')
        vault_profile = 'full'
    }
}

function Get-PreservedInstallPreset {
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$WorkspaceKey,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    if ($Registry['workspaces'].Contains($WorkspaceKey)) {
        $manifestPaths = @($Registry['workspaces'][$WorkspaceKey]['manifests'])
        if ($manifestPaths.Count -gt 0) {
            $manifest = Read-JsonObject -Path $manifestPaths[-1]
            $recordedPreset = [string]$manifest['effective_preset']
            if (-not [string]::IsNullOrWhiteSpace($recordedPreset)) {
                if ($recordedPreset -notin @('core','governed','full')) {
                    throw "Installed manifest has an invalid effective_preset: $recordedPreset"
                }
                return [ordered]@{ preset=$recordedPreset;source='manifest-preserve' }
            }
            $legacyPreset = if ([string]$manifest['effective_vault_profile'] -eq 'full') { 'full' } else { 'core' }
            return [ordered]@{ preset=$legacyPreset;source='legacy-manifest-preserve' }
        }
    }
    if (Test-ExistingFullVault -TargetRoot $TargetRoot) {
        return [ordered]@{ preset='full';source='detected-full-vault' }
    }
    return [ordered]@{ preset='core';source='default-core' }
}

function Resolve-InstallPreset {
    param(
        [string]$RequestedPreset,
        [bool]$PresetSpecified,
        [string]$RequestedVaultProfile,
        [bool]$VaultProfileSpecified,
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$WorkspaceKey,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $preserved = Get-PreservedInstallPreset -Registry $Registry -WorkspaceKey $WorkspaceKey -TargetRoot $TargetRoot
    $vaultMappedPreset = if ($RequestedVaultProfile -eq 'minimal') {
        'core'
    } elseif ($RequestedVaultProfile -eq 'full') {
        'full'
    } else {
        [string]$preserved.preset
    }
    if ($PresetSpecified -and $VaultProfileSpecified -and $RequestedVaultProfile -ne 'auto' -and $RequestedPreset -ne $vaultMappedPreset) {
        throw "Preset '$RequestedPreset' conflicts with VaultProfile '$RequestedVaultProfile' (maps to '$vaultMappedPreset')"
    }
    if ($PresetSpecified) {
        return [ordered]@{ preset=$RequestedPreset;source=$(if($VaultProfileSpecified){"preset+vault-profile:$RequestedVaultProfile"}else{'preset'}) }
    }
    if ($VaultProfileSpecified) {
        return [ordered]@{ preset=$vaultMappedPreset;source="vault-profile:$RequestedVaultProfile" }
    }
    return $preserved
}

function Get-PresetHookSourcePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$HookName
    )

    if ($HookName -eq 'userpromptsubmit.js') {
        return Join-Path $RepoRoot 'runtime-hooks\memory\userpromptsubmit.js'
    }
    return Join-Path $RepoRoot ("runtime-hooks\claude\{0}" -f $HookName)
}

function Install-MinimalVaultTemplate {
    param(
        [string]$TemplateRoot,
        [string]$TargetRoot
    )

    $entryRoot = Join-Path $TemplateRoot 'entry'
    foreach ($file in @(
            @{ Source = 'AGENTS.md.template'; Target = 'AGENTS.md' },
            @{ Source = 'advance-stage.ps1.template'; Target = 'advance-stage.ps1' },
            @{ Source = 'task.ps1.template'; Target = 'task.ps1' },
            @{ Source = 'validate-lite-artifacts.ps1.template'; Target = 'validate-lite-artifacts.ps1' }
        )) {
        $targetPath = Join-Path $TargetRoot (Join-Path 'entry' $file.Target)
        Install-RenderedFile -SourcePath (Join-Path $entryRoot $file.Source) -TargetPath $targetPath -RecordBackup
    }

    $runtimeTasksRoot = Join-Path $TargetRoot '运行时\tasks'
    Ensure-Directory -Path $runtimeTasksRoot
    $gitkeepSource = Join-Path $TemplateRoot '运行时\tasks\.gitkeep'
    if (Test-Path -LiteralPath $gitkeepSource -PathType Leaf) {
        Copy-Item -LiteralPath $gitkeepSource -Destination (Join-Path $runtimeTasksRoot '.gitkeep') -Force
    }
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is required for install.ps1'
}
if (-not $RebaselineLegacyInstallState -and
    -not [string]::IsNullOrWhiteSpace($ExpectedRebaselinePlanDigest)) {
    throw 'ExpectedRebaselinePlanDigest requires RebaselineLegacyInstallState'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedRebaselinePlanDigest) -and
    $ExpectedRebaselinePlanDigest -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'ExpectedRebaselinePlanDigest must be a SHA-256 digest'
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
$AgentsHome = Join-Path $env:USERPROFILE '.agents'
$RepoSkillsPath = Join-Path $RepoRoot 'skills'
$InstallStateRoot = Join-Path $env:USERPROFILE '.dev-harness'
$InstallRegistryPath = Join-Path $InstallStateRoot 'install-registry.json'
$InstallTransactionJournalPath = Join-Path $InstallStateRoot 'install-transaction.json'
$BackupRoot = Join-Path $InstallStateRoot ('backups\install-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$PID")
$LegacyActiveInstallPath = Join-Path $RepoRoot 'backups\active-install.json'
[void](Assert-InstallStatePathHasNoReparsePoint -Path $WorkspaceRoot -Label 'WorkspaceRoot')
foreach ($managedUserGlobalRoot in @($ClaudeHome, $CodexHome, $AgentsHome)) {
    [void](Assert-InstallStatePathHasNoReparsePoint -Path $managedUserGlobalRoot -Label 'Managed user-global root')
    if (Test-PathWithinRoot -Path $WorkspaceRoot -RootPath $managedUserGlobalRoot) {
        throw "WorkspaceRoot cannot be inside a managed user-global root: $managedUserGlobalRoot"
    }
}

$installTransactionMutex = Enter-InstallTransactionMutex -UserProfile $env:USERPROFILE
try {
$pendingUninstallJournalPath = Join-Path $env:USERPROFILE '.dev-harness\uninstall-transaction.json'
foreach ($installStatePath in @(
    $InstallStateRoot,
    $InstallRegistryPath,
    $InstallTransactionJournalPath,
    $pendingUninstallJournalPath,
    $BackupRoot
)) {
    [void](Assert-InstallStatePathHasNoReparsePoint -Path $installStatePath -Label 'Install state path')
}
if (Test-Path -LiteralPath $pendingUninstallJournalPath -PathType Leaf) {
    $pendingUninstallJournal = Read-JsonObject -Path $pendingUninstallJournalPath
    if ([string]$pendingUninstallJournal['schema_version'] -eq 'uninstall-transaction/v1.0') {
        throw "LIVE_UPDATE_REQUIRED: legacy-install-state; manual recovery is required for legacy uninstall transaction: $pendingUninstallJournalPath"
    }
    if ([string]$pendingUninstallJournal['schema_version'] -ne 'uninstall-transaction/v1.1') {
        throw "Unsupported pending uninstall transaction: $pendingUninstallJournalPath"
    }
    throw "A pending uninstall transaction must be resumed before install: $pendingUninstallJournalPath"
}
if ($RebaselineLegacyInstallState) {
    $registryShape = Read-JsonObject -Path $InstallRegistryPath
    if ([string]$registryShape['schema_version'] -eq 'install-registry/v1.1') {
        $modernRegistry = Read-InstallRegistry -Path $InstallRegistryPath
        $receipt = Get-LegacyRebaselineReceiptInfo `
            -Registry $modernRegistry `
            -RegistryPath $InstallRegistryPath `
            -WorkspaceRoot $WorkspaceRoot `
            -RepoRoot $RepoRoot `
            -UserProfile $env:USERPROFILE
        if ($null -eq $receipt) {
            throw 'Modern install registry has no matching legacy rebaseline receipt'
        }
        $legacyPointerMarked = Test-LegacyPointerMigrationMarked -UserProfile $env:USERPROFILE -PointerPath $LegacyActiveInstallPath
        if ((Get-NormalizedPath -Path $receipt['legacy_pointer_path']) -ne $LegacyActiveInstallPath -or
            (-not $legacyPointerMarked -and
                [string]$receipt['legacy_pointer_sha256'] -ne (Get-InstallStateFileDigest -Path $LegacyActiveInstallPath))) {
            throw 'LIVE_UPDATE_REQUIRED: legacy-active-pointer-receipt-mismatch'
        }
        if ([string]::IsNullOrWhiteSpace($ExpectedRebaselinePlanDigest)) {
            if (Test-Path -LiteralPath $InstallTransactionJournalPath -PathType Leaf) {
                throw "A pending install transaction must be recovered with digest-bound apply: $InstallTransactionJournalPath"
            }
            Write-LegacyRebaselineStatus -Status 'REBASELINE_ALREADY_COMMITTED' -State $receipt
            return
        }
        if ([string]$receipt['plan_digest'] -ne $ExpectedRebaselinePlanDigest.ToLowerInvariant()) {
            throw 'ExpectedRebaselinePlanDigest does not match the committed legacy rebaseline receipt'
        }
        Write-LegacyRebaselineStatus -Status 'REBASELINE_ALREADY_COMMITTED' -State $receipt
    } else {
        if (Test-Path -LiteralPath $InstallTransactionJournalPath -PathType Leaf) {
            throw "Legacy rebaseline requires no pending install transaction: $InstallTransactionJournalPath"
        }
        $rebaselinePlan = New-LegacyRebaselinePlan `
            -RegistryPath $InstallRegistryPath `
            -PointerPath $LegacyActiveInstallPath `
            -WorkspaceRoot $WorkspaceRoot `
            -RepoRoot $RepoRoot `
            -UserProfile $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($ExpectedRebaselinePlanDigest)) {
            Write-LegacyRebaselineStatus -Status 'REBASELINE_PLAN_REQUIRED' -State $rebaselinePlan
            return
        }
        if ([string]$rebaselinePlan['digest'] -ne $ExpectedRebaselinePlanDigest.ToLowerInvariant()) {
            throw 'ExpectedRebaselinePlanDigest does not match the current legacy state'
        }
        Publish-LegacyRebaselinePlan `
            -Plan $rebaselinePlan `
            -RegistryPath $InstallRegistryPath `
            -PointerPath $LegacyActiveInstallPath `
            -WorkspaceRoot $WorkspaceRoot `
            -RepoRoot $RepoRoot `
            -UserProfile $env:USERPROFILE
        Write-LegacyRebaselineStatus -Status 'REBASELINE_COMMITTED' -State $rebaselinePlan
    }
}
Resolve-PendingInstallTransaction `
    -JournalPath $InstallTransactionJournalPath `
    -ExpectedUserProfile $env:USERPROFILE `
    -ExpectedRegistryPath $InstallRegistryPath
$registryPreimageSha256 = Get-InstallStateFileDigest -Path $InstallRegistryPath

$script:RawRenderTokens = [ordered]@{
    '{REPO_ROOT}' = $RepoRoot
    '{WORKSPACE_ROOT}' = $WorkspaceRoot
    '{VAULT_PATH}' = $VaultPath
    '{CLAUDE_HOME}' = $ClaudeHome
    '{CODEX_HOME}' = $CodexHome
    '__RENDER_AT_INSTALL__' = (Get-Date -Format 'yyyy-MM-dd')
    '__RUNTIME_TIMESTAMP__' = ([datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszzz'))
}
$script:BackupRoot = $BackupRoot
$script:WorkspaceRoot = $WorkspaceRoot
$script:UserGlobalRoots = @($ClaudeHome, $CodexHome, $AgentsHome)
$script:BackedUpPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:Manifest = [ordered]@{
    schema_version = 'install-manifest/v1.2'
    postimage_identity_contract = 'v1'
    installed_at = (Get-Date -Format 's')
    repo_root = $RepoRoot
    workspace_root = $WorkspaceRoot
    vault_path = $VaultPath
    claude_home = $ClaudeHome
    codex_home = $CodexHome
    agents_home = $AgentsHome
    backup_root = $BackupRoot
    registry_path = $InstallRegistryPath
    registry_preimage_sha256 = $registryPreimageSha256
    transaction_status = 'in-progress'
    backup_payload_integrity_contract = 'sha256-v1'
    managed_backup_targets = @()
    generated_repo_system_path = $null
    requested_vault_profile = $VaultProfile
    effective_vault_profile = $null
    requested_preset = $(if ($presetSpecified) { $Preset } else { $null })
    effective_preset = $null
    preset_source = $null
    feature_ownership = $null
    backups = @()
}
$script:ManifestPath = Join-Path $BackupRoot 'install-manifest.json'

$claudeSkillsPath = Join-Path $ClaudeHome 'skills'
$codexSkillsPath = Join-Path $CodexHome 'skills'
$agentsSkillsPath = Join-Path $AgentsHome 'skills'
$claudeHooksPath = Join-Path $ClaudeHome 'hooks-memory'
$codexSettingsDir = Join-Path $CodexHome '.claude'
$claudeSettingsPath = Join-Path $ClaudeHome 'settings.json'
$codexSettingsPath = Join-Path $codexSettingsDir 'settings.local.json'
$codexOverlayPath = Join-Path $codexSettingsDir 'settings.local.user.json'
$codexManagedConfigPath = Join-Path $CodexHome 'managed_config.toml'
$claudeGlobalPath = Join-Path $ClaudeHome 'CLAUDE.md'
$codexGlobalPath = Join-Path $CodexHome 'AGENTS.md'
$workspaceAgentsPath = Join-Path $WorkspaceRoot 'AGENTS.md'
$registryCommitted = $false
$legacyPointerImported = $false
$legacyPointerImportDigest = $null
$transactionStarted = $false

try {
    $installRegistry = Read-InstallRegistry -Path $InstallRegistryPath
    $currentWorkspaceKey = Get-WorkspaceRegistryKey -Path $WorkspaceRoot
    if ($installRegistry['workspaces'].Contains($currentWorkspaceKey) -and
        (Get-NormalizedPath -Path $installRegistry['workspaces'][$currentWorkspaceKey]['repo_root']) -ne $RepoRoot) {
        throw "Workspace is already registered to another RepoRoot: $WorkspaceRoot"
    }
    $legacyPointerImportDigest = Import-LegacyActiveInstall -Registry $installRegistry -PointerPath $LegacyActiveInstallPath -ExpectedUserProfile $env:USERPROFILE -ExpectedRepoRoot $RepoRoot
    $legacyPointerImported = -not [string]::IsNullOrWhiteSpace([string]$legacyPointerImportDigest)
    [void](Get-RegisteredManifestStatusUpgradePlan `
        -Registry $installRegistry `
        -RegistryPath $InstallRegistryPath `
        -ExpectedUserProfile $env:USERPROFILE `
        -RequireManifestIntegrity $true)
    $presetResolution = Resolve-InstallPreset `
        -RequestedPreset $Preset `
        -PresetSpecified $presetSpecified `
        -RequestedVaultProfile $VaultProfile `
        -VaultProfileSpecified $vaultProfileSpecified `
        -Registry $installRegistry `
        -WorkspaceKey $currentWorkspaceKey `
        -TargetRoot $VaultPath
    $effectivePreset = [string]$presetResolution.preset
    $presetDefinition = Get-InstallPresetDefinition -Name $effectivePreset -RepoSkillsPath $RepoSkillsPath
    $effectiveVaultProfile = [string]$presetDefinition.vault_profile
    $script:Manifest.effective_preset = $effectivePreset
    $script:Manifest.preset_source = [string]$presetResolution.source
    $script:Manifest.effective_vault_profile = $effectiveVaultProfile
    $script:Manifest.feature_ownership = [ordered]@{
        schema_version = 'feature-ownership/v1'
        features = @($presetDefinition.features)
        skills = @($presetDefinition.skills)
        hooks = @($presetDefinition.hooks)
        vault_profile = $effectiveVaultProfile
    }
    if ($vaultProfileSpecified) {
        Write-Warning ("VaultProfile is deprecated; '{0}' mapped to Preset '{1}'." -f $VaultProfile,$effectivePreset)
    }
    if ($legacyPointerImported) {
        Assert-LegacyPointerMigrationMarkerWritable -UserProfile $env:USERPROFILE -PointerPath $LegacyActiveInstallPath
    }

    Ensure-Directory -Path $BackupRoot
    Save-InstallManifestSnapshot
    $journalLegacyPointerPath = if ($legacyPointerImported) { $LegacyActiveInstallPath } else { $null }
    $journalLegacyPointerImportDigest = if ($legacyPointerImported) { [string]$legacyPointerImportDigest } else { $null }
    $installTransactionJournal = [ordered]@{
        schema_version = 'install-transaction/v1.1'
        registry_schema_version = 'install-registry/v1.1'
        manifest_schema_version = 'install-manifest/v1.2'
        postimage_identity_contract = 'v1'
        prepared_at = (Get-Date -Format 's')
        user_profile = (Get-NormalizedPath -Path $env:USERPROFILE)
        repo_root = $RepoRoot
        workspace_root = $WorkspaceRoot
        registry_path = $InstallRegistryPath
        registry_preimage_sha256 = $registryPreimageSha256
        manifest_path = $script:ManifestPath
        postimage_transaction_status_contract = 'v1'
        postimage_history_ownership_contract = 'v1'
        postimage_manifest_integrity_contract = 'sha256-v1'
        legacy_pointer_path = $journalLegacyPointerPath
        legacy_pointer_import_digest = $journalLegacyPointerImportDigest
    }
    Write-InstallStateTextAtomic `
        -Path $InstallTransactionJournalPath `
        -Content (ConvertTo-Json -InputObject $installTransactionJournal -Depth 20)
    $transactionStarted = $true
    Ensure-Directory -Path $ClaudeHome
    Ensure-Directory -Path $CodexHome
    Ensure-Directory -Path $AgentsHome
    Ensure-Directory -Path $codexSettingsDir
    Ensure-Directory -Path $WorkspaceRoot
    [void](Assert-InstallStatePathHasNoReparsePoint -Path $WorkspaceRoot -Label 'WorkspaceRoot')
    foreach ($managedUserGlobalRoot in @($ClaudeHome, $CodexHome, $AgentsHome)) {
        [void](Assert-InstallStatePathHasNoReparsePoint -Path $managedUserGlobalRoot -Label 'Managed user-global root')
    }
    Ensure-Directory -Path $RepoSkillsPath

    Ensure-Directory -Path (Join-Path $RepoSkillsPath '.system')
    Ensure-WorkspaceGitIgnoreEntries -WorkspaceRoot $WorkspaceRoot

    if ($effectiveVaultProfile -eq 'full') {
        $retiredDecisionTemplatePath = Join-Path $VaultPath '模板\决策需求模板.md'
        $retiredDecisionTemplateRecord = $null
        if ($installRegistry['workspaces'].Contains($currentWorkspaceKey)) {
            $workspaceManifestPaths = @($installRegistry['workspaces'][$currentWorkspaceKey]['manifests'])
            for ($manifestIndex = $workspaceManifestPaths.Count - 1; $manifestIndex -ge 0; $manifestIndex--) {
                $registeredManifest = Read-JsonObject -Path $workspaceManifestPaths[$manifestIndex]
                $matchingRecords = @($registeredManifest['backups'] | Where-Object {
                        (Get-NormalizedPath -Path $_['path']) -eq (Get-NormalizedPath -Path $retiredDecisionTemplatePath)
                    })
                if ($matchingRecords.Count -gt 1) {
                    throw "Registered manifest contains duplicate retired template records: $($workspaceManifestPaths[$manifestIndex])"
                }
                if ($matchingRecords.Count -eq 1) {
                    $retiredDecisionTemplateRecord = $matchingRecords[0]
                    break
                }
            }
        }
        if ($null -ne $retiredDecisionTemplateRecord -and
            [string]$retiredDecisionTemplateRecord['ownership'] -eq 'managed') {
            $retiredDecisionTemplateSourceIdentity = Get-InstallManagedPathIdentity -Path $retiredDecisionTemplatePath
            $retiredDecisionTemplateExpectedIdentity = $retiredDecisionTemplateRecord['expected_postimage']
            if (-not (Test-InstallExactIdentityEqual `
                    -Left $retiredDecisionTemplateSourceIdentity `
                    -Right $retiredDecisionTemplateExpectedIdentity)) {
                throw "Retired managed vault template changed from its registered identity: $retiredDecisionTemplatePath"
            }
            if ([string]$retiredDecisionTemplateSourceIdentity['item_type'] -ne 'missing') {
                $retiredDecisionTemplateMissingIdentity = New-InstallExactMissingIdentity
                Backup-IfNeeded `
                    -Path $retiredDecisionTemplatePath `
                    -Ownership 'managed' `
                    -ExpectedPostimage $retiredDecisionTemplateMissingIdentity
                [void](Invoke-InstallExactPathTransition `
                    -Path $retiredDecisionTemplatePath `
                    -SourceIdentity $retiredDecisionTemplateSourceIdentity `
                    -DesiredIdentity $retiredDecisionTemplateMissingIdentity)
            }
        }
        Install-VaultTemplate -TemplateRoot (Join-Path $RepoRoot 'vault-template') -TargetRoot $VaultPath
    } else {
        Install-MinimalVaultTemplate -TemplateRoot (Join-Path $RepoRoot 'vault-template') -TargetRoot $VaultPath
    }

    Install-RenderedFile -SourcePath (Join-Path $RepoRoot 'agent-configs\claude\CLAUDE.md.template') -TargetPath $claudeGlobalPath -RecordBackup

    Install-RenderedFile -SourcePath (Join-Path $RepoRoot 'agent-configs\codex\AGENTS.md.template') -TargetPath $codexGlobalPath -RecordBackup

    Install-RenderedFile -SourcePath (Join-Path $RepoRoot 'agent-configs\workspace\AGENTS.md.template') -TargetPath $workspaceAgentsPath -RecordBackup

    $claudeHooksStagingPath = Join-Path $BackupRoot '_claude-hooks-postimage'
    Remove-PathIfExists -Path $claudeHooksStagingPath
    Ensure-Directory -Path $claudeHooksStagingPath
    try {
        foreach ($hookName in @($presetDefinition.hooks)) {
            $hookSource = Get-PresetHookSourcePath -RepoRoot $RepoRoot -HookName $hookName
            Install-RenderedFile -SourcePath $hookSource -TargetPath (Join-Path $claudeHooksStagingPath $hookName)
        }
        $claudeHooksExpectedPostimage = New-InstallExactDirectoryIdentity -Path $claudeHooksStagingPath
        $claudeHooksSourceIdentity = Get-InstallManagedPathIdentity -Path $claudeHooksPath
        Backup-IfNeeded -Path $claudeHooksPath -ExpectedPostimage $claudeHooksExpectedPostimage
        [void](Invoke-InstallExactPathTransition `
            -Path $claudeHooksPath `
            -SourceIdentity $claudeHooksSourceIdentity `
            -DesiredIdentity $claudeHooksExpectedPostimage `
            -MaterializeDesired { param($BuildPath) Move-Item -LiteralPath $claudeHooksStagingPath -Destination $BuildPath })
    } finally {
        Remove-PathIfExists -Path $claudeHooksStagingPath
    }

    $claudeSettingsTemplate = if ($effectivePreset -eq 'full') { 'settings.local.shared.json.template' } else { 'settings.local.core.json.template' }
    $claudeSharedSettingsJson = Render-JsonTemplateText -TemplatePath (Join-Path $RepoRoot ("agent-configs\claude\{0}" -f $claudeSettingsTemplate)) -TargetPath $claudeSettingsPath
    $claudeSettingsMerge = Merge-ClaudeSettingsJsonText -RenderedHooksJson $claudeSharedSettingsJson -ExistingPath $claudeSettingsPath
    $claudeSettingsExpectedPostimage = New-ClaudeSettingsPostimageIdentity -ManagedSettings (ConvertFrom-JsonDocument -Json $claudeSharedSettingsJson)
    Backup-IfNeeded -Path $claudeSettingsPath -ExpectedPostimage $claudeSettingsExpectedPostimage
    Write-InstallStateTextAtomic `
        -Path $claudeSettingsPath `
        -Content $claudeSettingsMerge.Content `
        -ExpectedCurrentDigest $(if ([string]$claudeSettingsMerge.Identity['item_type'] -eq 'missing') { 'missing' } else { [string]$claudeSettingsMerge.Identity['sha256'] })

    $codexSharedSettingsJson = Render-JsonTemplateText -TemplatePath (Join-Path $RepoRoot 'agent-configs\codex\settings.local.shared.json.template') -TargetPath $codexSettingsPath
    $codexSettingsMerge = Merge-SettingsLocalJsonText -RenderedSharedJson $codexSharedSettingsJson -ExistingPath $codexSettingsPath -OverlayPath $codexOverlayPath
    Write-ManagedInstallText -Path $codexSettingsPath -Content $codexSettingsMerge.Content -RecordBackup -ExpectedCurrentIdentity $codexSettingsMerge.Identity

    Update-CodexManagedConfig -TemplatePath (Join-Path $RepoRoot 'agent-configs\codex\config.shared.toml.template') -ManagedTargetPath $codexManagedConfigPath

    Sync-SkillsDirectory -HostSkillsPath $claudeSkillsPath -RepoSkillsPath $RepoSkillsPath -ManagedEntryNames @($presetDefinition.skills)
    Sync-SkillsDirectory -HostSkillsPath $codexSkillsPath -RepoSkillsPath $RepoSkillsPath -ManagedEntryNames @($presetDefinition.skills)
    Sync-SkillsDirectory -HostSkillsPath $agentsSkillsPath -RepoSkillsPath $RepoSkillsPath -ManagedEntryNames @($presetDefinition.skills)

    Save-InstallManifestSnapshot
    Add-ManifestToRegistry `
        -Registry $installRegistry `
        -ManifestPath $script:ManifestPath `
        -WorkspaceRoot $WorkspaceRoot `
        -RepoRoot $RepoRoot `
        -VaultProfile $effectiveVaultProfile `
        -InstalledAt $script:Manifest.installed_at
    $script:Manifest.transaction_status = 'committed'
    Save-InstallManifestSnapshot
    Refresh-InstallRegistryManifestDigests -Registry $installRegistry
    Write-InstallRegistry -Path $InstallRegistryPath -Registry $installRegistry -ExpectedCurrentDigest $registryPreimageSha256
    $registryCommitted = $true
    if ($legacyPointerImported) {
        Set-LegacyPointerMigrationMarked `
            -UserProfile $env:USERPROFILE `
            -PointerPath $LegacyActiveInstallPath `
            -ExpectedPointerDigest $legacyPointerImportDigest
    }
    Remove-Item -LiteralPath $InstallTransactionJournalPath -Force

    Write-Output 'Install summary:'
    Write-Output ('- repo_root: {0}' -f $RepoRoot)
    Write-Output ('- workspace_root: {0}' -f $WorkspaceRoot)
    Write-Output ('- vault_path: {0}' -f $VaultPath)
    Write-Output ('- requested_vault_profile: {0}' -f $VaultProfile)
    Write-Output ('- effective_vault_profile: {0}' -f $effectiveVaultProfile)
    Write-Output ('- requested_preset: {0}' -f $(if ($presetSpecified) { $Preset } else { 'none' }))
    Write-Output ('- effective_preset: {0}' -f $effectivePreset)
    Write-Output ('- preset_source: {0}' -f $presetResolution.source)
    Write-Output ('- claude_skills_root: {0}' -f $claudeSkillsPath)
    Write-Output ('- codex_skills_root: {0}' -f $codexSkillsPath)
    Write-Output ('- agents_skills_root: {0}' -f $agentsSkillsPath)
    Write-Output ('- managed_skill_source: {0}' -f $RepoSkillsPath)
    Write-Output ('- backup_root: {0}' -f $BackupRoot)
    Write-Output ('- install_registry: {0}' -f $InstallRegistryPath)
    Write-Output ''
    Write-Output 'Manual follow-up:'
    Write-Output ('- Review optional Codex overlay file: {0}' -f $codexOverlayPath)
    Write-Output ('- Run: {0}' -f (Join-Path $RepoRoot 'tests\verify-installation.ps1'))
} catch {
    if ($transactionStarted -and -not $registryCommitted) {
        $script:Manifest.transaction_status = 'failed'
        Save-InstallManifestSnapshot
    }
    if (-not $transactionStarted -and (Test-Path -LiteralPath $InstallTransactionJournalPath -PathType Leaf)) {
        Remove-Item -LiteralPath $InstallTransactionJournalPath -Force
    }
    $rootCause = if ($_.Exception) { $_.Exception.Message } else { 'unknown error' }
    $recoveryMessage = if (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf) {
        "Install failed after writing recovery manifest: $($script:ManifestPath)`nRoot cause: $rootCause"
    } else {
        "Install failed before recovery manifest snapshot could be written.`nRoot cause: $rootCause"
    }
    Write-Error $recoveryMessage
    throw
}
} finally {
    Exit-InstallTransactionMutex -Mutex $installTransactionMutex
}
