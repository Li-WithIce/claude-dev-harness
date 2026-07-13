# Shared cross-process lock for install/uninstall user-global transactions.

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$RootPath
    )

    $normalizedPath = Get-NormalizedPath -Path $Path
    $normalizedRoot = (Get-NormalizedPath -Path $RootPath).TrimEnd('\', '/')
    return $normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith($normalizedRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WorkspaceRegistryKey {
    param([string]$Path)

    return (Get-NormalizedPath -Path $Path).TrimEnd('\', '/').ToLowerInvariant()
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

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8
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
        return ,$items
    }

    $result = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $result[$property.Name] = ConvertTo-NormalizedObject -Value $property.Value
    }
    return $result
}

function Get-InstallTransactionMutexName {
    param([Parameter(Mandatory = $true)][string]$UserProfile)

    $normalizedProfile = [System.IO.Path]::GetFullPath($UserProfile).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ).ToLowerInvariant()
    return 'Global\dev-harness.install.{0}' -f (Get-InstallStateIdentityHash -Value $normalizedProfile)
}

function Get-InstallStateIdentityHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    } finally {
        $sha256.Dispose()
    }
    return [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
}

function Get-InstallStateFileDigest {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 'missing'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Install state path exists but is not a file: $Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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

function Get-InstallManifestDigestRegistryKey {
    param([string]$ManifestPath)

    return Get-InstallStateIdentityHash -Value ((Get-NormalizedPath -Path $ManifestPath).ToLowerInvariant())
}

function Assert-InstallManifestRegistryDigest {
    param(
        $Registry,
        [string]$ManifestPath,
        [bool]$RequireManifestIntegrity
    )

    $digestKey = Get-InstallManifestDigestRegistryKey -ManifestPath $ManifestPath
    $actualDigest = Get-InstallStateFileDigest -Path $ManifestPath
    if ($RequireManifestIntegrity) {
        $expectedDigest = [string]$Registry['manifest_digests'][$digestKey]
        if ($expectedDigest -notmatch '^[0-9a-f]{64}$' -or $expectedDigest -ne $actualDigest) {
            throw "Registered install manifest digest mismatch: $ManifestPath"
        }
    }
    $Registry['manifest_digests'][$digestKey] = $actualDigest
}

function Assert-InstallStatePathHasNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = 'managed path',
        [switch]$AllowFinalReparsePoint
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($normalizedPath)
    $relativePath = $normalizedPath.Substring($root.Length)
    $segments = @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $currentPath = $root
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $currentPath = Join-Path $currentPath $segments[$index]
        if (-not (Test-Path -LiteralPath $currentPath)) {
            continue
        }
        $item = Get-Item -LiteralPath $currentPath -Force
        $isFinal = $index -eq ($segments.Count - 1)
        if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
            -not ($isFinal -and $AllowFinalReparsePoint)) {
            throw "$Label traverses a reparse point: $currentPath"
        }
    }
    return $normalizedPath
}

function Get-InstallBackupPayloadDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('file','directory')][string]$ItemType
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if ($ItemType -eq 'file') {
        if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
            throw "Backup payload is not a file: $normalizedPath"
        }
        return (Get-FileHash -LiteralPath $normalizedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Container)) {
        throw "Backup payload is not a directory: $normalizedPath"
    }

    $rootPrefix = $normalizedPath.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $normalizedPath -Force -Recurse) {
        $itemPath = [System.IO.Path]::GetFullPath($item.FullName)
        $relativePath = $itemPath.Substring($rootPrefix.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $relativeToken = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($relativePath))
        $isReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isReparsePoint) {
            $target = $item.Target
            if ($target -is [System.Array]) { $target = $target[0] }
            $targetToken = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$target))
            $entries.Add(('L|{0}|{1}|{2}' -f $relativeToken,[string]$item.LinkType,$targetToken)) | Out-Null
        } elseif ($item.PSIsContainer) {
            $entries.Add(('D|{0}' -f $relativeToken)) | Out-Null
        } else {
            $entries.Add(('F|{0}|{1}' -f $relativeToken,(Get-InstallStateFileDigest -Path $itemPath))) | Out-Null
        }
    }
    $orderedEntries = $entries.ToArray()
    [Array]::Sort($orderedEntries, [System.StringComparer]::Ordinal)
    return Get-InstallStateIdentityHash -Value ($orderedEntries -join "`n")
}

function Get-InstallLinkIdentityTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $resolvedTarget = if ([System.IO.Path]::IsPathRooted($Target)) {
        $Target
    } else {
        Join-Path ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))) $Target
    }
    return [System.IO.Path]::GetFullPath($resolvedTarget)
}

function New-InstallExactMissingIdentity {
    return [ordered]@{ mode = 'exact'; item_type = 'missing' }
}

function New-InstallExactFileIdentity {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    return [ordered]@{
        mode = 'exact'
        item_type = 'file'
        sha256 = (Get-InstallStateIdentityHash -Value $Content)
    }
}

function New-InstallExactDirectoryIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [ordered]@{
        mode = 'exact'
        item_type = 'directory'
        sha256 = (Get-InstallBackupPayloadDigest -Path $Path -ItemType 'directory')
    }
}

function New-InstallExactLinkIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Junction','SymbolicLink')][string]$LinkType,
        [Parameter(Mandatory = $true)][string]$Target
    )

    return [ordered]@{
        mode = 'exact'
        item_type = 'link'
        link_type = $LinkType
        link_target = (Get-InstallLinkIdentityTarget -Path $Path -Target $Target)
    }
}

function Get-InstallManagedPathIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $normalizedPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return New-InstallExactMissingIdentity
    }

    if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        $target = $item.Target
        if ($target -is [System.Array]) { $target = $target[0] }
        if ([string]::IsNullOrWhiteSpace([string]$target)) {
            throw "Managed link has no target: $normalizedPath"
        }
        $linkType = if ([string]::IsNullOrWhiteSpace([string]$item.LinkType)) {
            if ($item.PSIsContainer) { 'Junction' } else { 'SymbolicLink' }
        } else {
            [string]$item.LinkType
        }
        return New-InstallExactLinkIdentity -Path $normalizedPath -LinkType $linkType -Target ([string]$target)
    }

    if ($item.PSIsContainer) {
        return New-InstallExactDirectoryIdentity -Path $normalizedPath
    }
    return [ordered]@{
        mode = 'exact'
        item_type = 'file'
        sha256 = (Get-InstallStateFileDigest -Path $normalizedPath)
    }
}

function Read-InstallTextSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $identity = Get-InstallManagedPathIdentity -Path $normalizedPath
    $itemType = [string]$identity['item_type']
    if ($itemType -notin @('missing','file')) {
        throw "Install text snapshot requires a missing or file target: $normalizedPath"
    }
    $content = $null
    if ($itemType -eq 'file') {
        $bytes = [System.IO.File]::ReadAllBytes($normalizedPath)
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha256.ComputeHash($bytes)
        } finally {
            $sha256.Dispose()
        }
        $identity = [ordered]@{
            mode = 'exact'
            item_type = 'file'
            sha256 = [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
        }
        $content = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
        if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
            $content = $content.Substring(1)
        }
    }
    if (-not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $normalizedPath) -Right $identity)) {
        throw "Install text target changed while it was read: $normalizedPath"
    }
    return [pscustomobject]@{
        Content = $content
        Identity = $identity
    }
}

function Get-InstallBackupRecordPreimageIdentity {
    param([Parameter(Mandatory = $true)]$Record)

    if (-not [bool]$Record['existed']) {
        return New-InstallExactMissingIdentity
    }
    $itemType = [string]$Record['item_type']
    switch ($itemType) {
        'link' {
            return New-InstallExactLinkIdentity `
                -Path ([string]$Record['path']) `
                -LinkType ([string]$Record['link_type']) `
                -Target ([string]$Record['link_target'])
        }
        'file' {
            return [ordered]@{
                mode = 'exact'
                item_type = 'file'
                sha256 = (Get-InstallBackupPayloadDigest -Path ([string]$Record['backup_path']) -ItemType 'file')
            }
        }
        'directory' {
            return New-InstallExactDirectoryIdentity -Path ([string]$Record['backup_path'])
        }
        default {
            throw "Unsupported backup preimage item_type '$itemType': $($Record['path'])"
        }
    }
}

function Test-InstallExactIdentityEqual {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )

    if ([string]$Left['mode'] -ne 'exact' -or [string]$Right['mode'] -ne 'exact') {
        return $false
    }
    $itemType = [string]$Left['item_type']
    if ($itemType -ne [string]$Right['item_type']) {
        return $false
    }
    switch ($itemType) {
        'missing' { return $true }
        { $_ -in @('file','directory') } {
            return [string]$Left['sha256'] -match '^[0-9a-f]{64}$' -and
                [string]$Left['sha256'] -eq [string]$Right['sha256']
        }
        'link' {
            return [string]$Left['link_type'] -eq [string]$Right['link_type'] -and
                [string]$Left['link_target'] -ne '' -and
                [string]$Left['link_target'] -eq [string]$Right['link_target']
        }
        default { return $false }
    }
}

function Assert-InstallExpectedPostimageShape {
    param(
        [Parameter(Mandatory = $true)]$Identity,
        [string]$Label = 'expected postimage'
    )

    if (-not ($Identity -is [System.Collections.IDictionary])) {
        throw "$Label must be an object"
    }
    $mode = [string]$Identity['mode']
    if ($mode -eq 'exact') {
        $itemType = [string]$Identity['item_type']
        if ($itemType -notin @('missing','file','directory','link')) {
            throw "$Label has an unsupported exact item type: $itemType"
        }
        if ($itemType -in @('file','directory')) {
            if ([string]$Identity['sha256'] -notmatch '^[0-9a-f]{64}$') {
                throw "$Label is missing an exact SHA-256"
            }
        } elseif ($itemType -eq 'link') {
            if ([string]$Identity['link_type'] -notin @('Junction','SymbolicLink') -or
                [string]::IsNullOrWhiteSpace([string]$Identity['link_target']) -or
                -not [System.IO.Path]::IsPathRooted([string]$Identity['link_target'])) {
                throw "$Label has an invalid exact link identity"
            }
        }
        return
    }
    if ($mode -ne 'semantic') {
        throw "$Label has an unsupported identity mode: $mode"
    }

    $contract = [string]$Identity['contract']
    if ($contract -eq 'workspace-gitignore/v1') {
        if (-not ($Identity['line_delta'] -is [System.Collections.IList]) -or @($Identity['line_delta']).Count -eq 0) {
            throw "$Label is missing its .gitignore managed line delta"
        }
        foreach ($delta in @($Identity['line_delta'])) {
            if (-not ($delta -is [System.Collections.IDictionary]) -or
                [string]$delta['operation'] -notin @('add','remove','replace')) {
                throw "$Label contains an invalid .gitignore line delta"
            }
            switch ([string]$delta['operation']) {
                'add' {
                    if ([string]::IsNullOrWhiteSpace([string]$delta['line']) -or
                        [string]$delta['expected_count'] -notmatch '^\d+$') {
                        throw "$Label contains an invalid .gitignore add delta"
                    }
                }
                'remove' {
                    if ([string]::IsNullOrWhiteSpace([string]$delta['line']) -or
                        [int]$delta['expected_count'] -ne 0) {
                        throw "$Label contains an invalid .gitignore remove delta"
                    }
                }
                'replace' {
                    if ([string]::IsNullOrWhiteSpace([string]$delta['from']) -or
                        [string]::IsNullOrWhiteSpace([string]$delta['to']) -or
                        [int]$delta['expected_from_count'] -ne 0 -or
                        [string]$delta['expected_to_count'] -notmatch '^\d+$') {
                        throw "$Label contains an invalid .gitignore replace delta"
                    }
                }
            }
        }
        return
    }
    if ($contract -eq 'claude-settings/v1') {
        if (-not ($Identity['managed_hooks'] -is [System.Collections.IList]) -or @($Identity['managed_hooks']).Count -eq 0) {
            throw "$Label is missing its Claude managed hooks"
        }
        foreach ($managedHook in @($Identity['managed_hooks'])) {
            if (-not ($managedHook -is [System.Collections.IDictionary]) -or
                [string]::IsNullOrWhiteSpace([string]$managedHook['event']) -or
                [string]$managedHook['path'] -ne ('hooks.' + [string]$managedHook['event']) -or
                -not ($managedHook['section'] -is [System.Collections.IDictionary]) -or
                $managedHook['section'].Contains('hooks') -or
                -not ($managedHook['hook'] -is [System.Collections.IDictionary]) -or
                [string]::IsNullOrWhiteSpace([string]$managedHook['hook']['command']) -or
                [int]$managedHook['multiplicity'] -ne 1) {
                throw "$Label contains an invalid Claude managed hook identity"
            }
        }
        return
    }
    throw "$Label has an unsupported semantic contract: $contract"
}

function Write-InstallStateTextDurable {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    $stream = [System.IO.FileStream]::new(
        [System.IO.Path]::GetFullPath($Path),
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Write-InstallStateTextAtomic {
    param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content, [string]$ExpectedCurrentDigest = ''
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($normalizedPath)
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $nonce = '{0}.{1}' -f $PID,[guid]::NewGuid().ToString('N')
    $temporaryPath = "$normalizedPath.$nonce.tmp"
    $backupPath = "$normalizedPath.$nonce.bak"
    try {
        Write-InstallStateTextDurable -Path $temporaryPath -Content $Content
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCurrentDigest) -and -not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $normalizedPath) -Right $(if ($ExpectedCurrentDigest -eq 'missing') { New-InstallExactMissingIdentity } else { [ordered]@{ mode = 'exact'; item_type = 'file'; sha256 = $ExpectedCurrentDigest } }))) {
            throw "Atomic text target changed from its expected current identity: $normalizedPath"
        }
        if (Test-Path -LiteralPath $normalizedPath) {
            if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
                throw "Atomic text target exists but is not a file: $normalizedPath"
            }
            [System.IO.File]::Replace($temporaryPath, $normalizedPath, $backupPath)
        } else {
            [System.IO.File]::Move($temporaryPath, $normalizedPath)
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Copy-InstallStateFileAtomic {
    param([Parameter(Mandatory = $true)][string]$SourcePath, [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$ExpectedCurrentIdentity, [Parameter(Mandatory = $true)]$ExpectedDesiredIdentity)
    $source = [System.IO.Path]::GetFullPath($SourcePath)
    $target = [System.IO.Path]::GetFullPath($Path)
    Assert-InstallExpectedPostimageShape -Identity $ExpectedCurrentIdentity -Label "Expected current file identity for $target"
    Assert-InstallExpectedPostimageShape -Identity $ExpectedDesiredIdentity -Label "Expected desired file identity for $target"
    if ([string]$ExpectedCurrentIdentity['mode'] -ne 'exact' -or
        [string]$ExpectedCurrentIdentity['item_type'] -notin @('missing','file') -or
        [string]$ExpectedDesiredIdentity['mode'] -ne 'exact' -or
        [string]$ExpectedDesiredIdentity['item_type'] -ne 'file') {
        throw "Atomic file copy requires missing/file current and file desired identities: $target"
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Atomic file source is not a file: $source" }
    $parent = [System.IO.Path]::GetDirectoryName($target)
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $nonce = '{0}.{1}' -f $PID,[guid]::NewGuid().ToString('N')
    $temporaryPath = "$target.$nonce.tmp"
    $backupPath = "$target.$nonce.bak"
    try {
        [System.IO.File]::Copy($source, $temporaryPath, $false)
        $stream = [System.IO.File]::Open($temporaryPath, 'Open', 'ReadWrite', 'None')
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        if (-not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $temporaryPath) -Right $ExpectedDesiredIdentity)) {
            throw "Atomic file source changed from its expected desired identity: $source"
        }
        $currentIdentity = Get-InstallManagedPathIdentity -Path $target
        if (-not (Test-InstallExactIdentityEqual -Left $currentIdentity -Right $ExpectedCurrentIdentity)) {
            throw "Atomic file target changed from its expected current identity: $target"
        }
        if ([string]$currentIdentity['item_type'] -eq 'file') {
            [System.IO.File]::Replace($temporaryPath, $target, $backupPath)
        } else {
            [System.IO.File]::Move($temporaryPath, $target)
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Copy-InstallExactDirectory {
    param([Parameter(Mandatory = $true)][string]$SourcePath, [Parameter(Mandatory = $true)][string]$Path, [string]$CopyRoot = '')
    $source = [System.IO.Path]::GetFullPath($SourcePath)
    $target = [System.IO.Path]::GetFullPath($Path)
    if ([string]::IsNullOrWhiteSpace($CopyRoot)) { $CopyRoot = $source }
    if (-not (Test-Path -LiteralPath $source -PathType Container) -or (Test-Path -LiteralPath $target)) {
        throw "Exact directory copy requires an existing source and missing target: $source -> $target"
    }
    [System.IO.Directory]::CreateDirectory($target) | Out-Null
    foreach ($child in Get-ChildItem -LiteralPath $source -Force) {
        $destination = Join-Path $target $child.Name
        if ([bool]($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $linkTarget = $child.Target
            if ($linkTarget -is [System.Array]) { $linkTarget = $linkTarget[0] }
            $linkType = if ([string]::IsNullOrWhiteSpace([string]$child.LinkType)) { if ($child.PSIsContainer) { 'Junction' } else { 'SymbolicLink' } } else { [string]$child.LinkType }
            $resolvedLinkTarget = Get-InstallLinkIdentityTarget -Path $child.FullName -Target ([string]$linkTarget)
            $rootPrefix = [System.IO.Path]::GetFullPath($CopyRoot).TrimEnd('\','/')
            if ($linkType -eq 'Junction' -and ($resolvedLinkTarget -eq $rootPrefix -or $resolvedLinkTarget.StartsWith($rootPrefix + '\', [System.StringComparison]::OrdinalIgnoreCase))) { throw "Exact directory copy cannot relocate a tree-internal junction: $($child.FullName)" }
            New-Item -ItemType $linkType -Path $destination -Target ([string]$linkTarget) | Out-Null
        } elseif ($child.PSIsContainer) {
            Copy-InstallExactDirectory -SourcePath $child.FullName -Path $destination -CopyRoot $CopyRoot
        } else {
            $desired = Get-InstallManagedPathIdentity -Path $child.FullName
            Copy-InstallStateFileAtomic -SourcePath $child.FullName -Path $destination -ExpectedCurrentIdentity (New-InstallExactMissingIdentity) -ExpectedDesiredIdentity $desired
        }
    }
}

function Get-InstallExactPathSidecarPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$DesiredIdentity
    )

    $target = [System.IO.Path]::GetFullPath($Path)
    Assert-InstallExpectedPostimageShape -Identity $DesiredIdentity -Label "Desired identity for $target"
    if ([string]$DesiredIdentity['mode'] -ne 'exact') { throw "Exact path transition requires exact identity: $target" }
    $key = Get-InstallStateIdentityHash -Value ($target.ToLowerInvariant() + "`n" + (ConvertTo-Json -InputObject $DesiredIdentity -Depth 20 -Compress))
    $parent = [System.IO.Path]::GetDirectoryName($target)
    return [pscustomobject]@{
        Ready = Join-Path $parent ('.dev-harness-exact-' + $key + '.ready')
        Old = Join-Path $parent ('.dev-harness-exact-' + $key + '.old')
    }
}

function Invoke-InstallExactPathTransition {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$SourceIdentity,
        [Parameter(Mandatory = $true)]$DesiredIdentity,
        [scriptblock]$MaterializeDesired,
        [switch]$RecoverOnly,
        [switch]$ValidateOnly
    )

    $target = [System.IO.Path]::GetFullPath($Path)
    Assert-InstallExpectedPostimageShape -Identity $SourceIdentity -Label "Source identity for $target"
    Assert-InstallExpectedPostimageShape -Identity $DesiredIdentity -Label "Desired identity for $target"
    if ([string]$SourceIdentity['mode'] -ne 'exact' -or [string]$DesiredIdentity['mode'] -ne 'exact') {
        throw "Exact path transition requires exact identities: $target"
    }
    [void](Assert-InstallStatePathHasNoReparsePoint -Path $target -Label 'Exact path transition target' -AllowFinalReparsePoint)
    $sidecars = Get-InstallExactPathSidecarPaths -Path $target -DesiredIdentity $DesiredIdentity
    $readyExists = Test-Path -LiteralPath $sidecars.Ready
    $oldExists = Test-Path -LiteralPath $sidecars.Old
    if (($RecoverOnly -or $ValidateOnly) -and -not $readyExists -and -not $oldExists) { return $false }
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target)) | Out-Null

    $removePath = {
        param([string]$Candidate)
        $item = Get-Item -LiteralPath $Candidate -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { return }
        if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or -not $item.PSIsContainer) {
            Remove-Item -LiteralPath $Candidate -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath $Candidate -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $movePath = {
        param([string]$Source, [string]$Destination)
        [void](Assert-InstallStatePathHasNoReparsePoint -Path $target -Label 'Exact path transition target' -AllowFinalReparsePoint)
        if (Test-Path -LiteralPath $Destination) { throw "Exact path transition destination already exists: $Destination" }
        $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            [System.IO.Directory]::Move($Source, $Destination)
        } else {
            [System.IO.File]::Move($Source, $Destination)
        }
    }
    $discard = {
        param([string]$Candidate)
        if (-not (Test-Path -LiteralPath $Candidate)) { return }
        $discardPath = Join-Path ([System.IO.Path]::GetDirectoryName($target)) ('.dev-harness-exact-' + [guid]::NewGuid().ToString('N') + '.discard')
        & $movePath $Candidate $discardPath
        & $removePath $discardPath
    }
    if ($readyExists -and
        ([string]$DesiredIdentity['item_type'] -eq 'missing' -or
            -not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $sidecars.Ready) -Right $DesiredIdentity))) {
        throw "Exact path transition ready identity drifted: $($sidecars.Ready)"
    }
    if ($oldExists -and
        -not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $sidecars.Old) -Right $SourceIdentity)) {
        throw "Exact path transition old identity drifted: $($sidecars.Old)"
    }
    if (Test-InstallExactIdentityEqual -Left $SourceIdentity -Right $DesiredIdentity) {
        if ($readyExists -or $oldExists) { throw "No-op exact path transition has sidecars: $target" }
        return $false
    }

    $currentIdentity = Get-InstallManagedPathIdentity -Path $target
    $currentIsSource = Test-InstallExactIdentityEqual -Left $currentIdentity -Right $SourceIdentity
    $currentIsDesired = Test-InstallExactIdentityEqual -Left $currentIdentity -Right $DesiredIdentity
    if ($ValidateOnly) {
        if ($currentIsDesired -or
            ($currentIsSource -and $readyExists -and -not $oldExists -and [string]$DesiredIdentity['item_type'] -ne 'missing') -or
            ([string]$currentIdentity['item_type'] -eq 'missing' -and $readyExists -and $oldExists)) {
            return $true
        }
        throw "Exact path transition is not at a legal recoverable state: $target"
    }
    if ($currentIsDesired) {
        if ($readyExists) { & $discard $sidecars.Ready }
        if ($oldExists) { & $discard $sidecars.Old }
        return $true
    }
    if ($currentIsSource -and -not $readyExists -and [string]$DesiredIdentity['item_type'] -ne 'missing') {
        if ($RecoverOnly) { return $false }
        if ($null -eq $MaterializeDesired) { throw "Exact path transition requires a materializer: $target" }
        $buildPath = Join-Path ([System.IO.Path]::GetDirectoryName($target)) ('.dev-harness-exact-' + [guid]::NewGuid().ToString('N') + '.build')
        try {
            & $MaterializeDesired $buildPath | Out-Null
            if (-not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $buildPath) -Right $DesiredIdentity)) {
                throw "Exact path transition build identity mismatch: $target"
            }
            & $movePath $buildPath $sidecars.Ready
            $readyExists = $true
        } finally {
            & $removePath $buildPath
        }
    }
    if ($currentIsSource) {
        if ($oldExists) { throw "Exact path transition has duplicate source and old: $target" }
        if ([string]$SourceIdentity['item_type'] -ne 'missing') {
            & $movePath $target $sidecars.Old
            $oldExists = $true
        }
        if ([string]$DesiredIdentity['item_type'] -ne 'missing') {
            if (-not $readyExists) { throw "Exact path transition has no ready postimage: $target" }
            & $movePath $sidecars.Ready $target
            $readyExists = $false
        }
        if ($oldExists) { & $discard $sidecars.Old }
        return $true
    }
    if ([string]$currentIdentity['item_type'] -eq 'missing' -and $readyExists -and $oldExists) {
        & $movePath $sidecars.Ready $target
        & $discard $sidecars.Old
        return $true
    }
    throw "Exact path transition is not at a legal recoverable state: $target"
}

function Repair-InstallRestorePlanTransitions {
    param([object[]]$Plan, [switch]$FailedInstall, [scriptblock]$ValidateProjectedPlan)
    $actions = [System.Collections.Generic.List[object]]::new()
    $projectedIdentities = @{}
    $claimedSidecars = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Plan)) {
        $record = $entry.Record
        $postimage = $record['expected_postimage']
        if ([string]$postimage['mode'] -ne 'exact') { continue }
        $preimage = Get-InstallBackupRecordPreimageIdentity -Record $record
        $targetPath = [string]$record['path']
        $restoreSidecars = Get-InstallExactPathSidecarPaths -Path $targetPath -DesiredIdentity $preimage
        $installSidecars = Get-InstallExactPathSidecarPaths -Path $targetPath -DesiredIdentity $postimage
        $restorePending = -not $claimedSidecars.Contains($restoreSidecars.Ready) -and ((Test-Path -LiteralPath $restoreSidecars.Ready) -or (Test-Path -LiteralPath $restoreSidecars.Old))
        $installPending = -not $claimedSidecars.Contains($installSidecars.Ready) -and ((Test-Path -LiteralPath $installSidecars.Ready) -or (Test-Path -LiteralPath $installSidecars.Old))
        if (Test-InstallExactIdentityEqual -Left $preimage -Right $postimage) {
            if ($restorePending -or $installPending) { throw "No-op restore record has exact-path sidecars: $targetPath" }
            continue
        }
        if ($restorePending -and $installPending) { throw "Install and restore exact-path transitions are both pending: $targetPath" }
        if (-not $restorePending -and -not $installPending) { continue }
        if ($restorePending) {
            $source = $postimage; $desired = $preimage
            $claimedKey = $restoreSidecars.Ready
        } else {
            if (-not $FailedInstall) { throw "Unexpected install exact-path transition during uninstall resume: $targetPath" }
            $source = $preimage; $desired = $postimage
            $claimedKey = $installSidecars.Ready
        }
        [void](Invoke-InstallExactPathTransition -Path $targetPath -SourceIdentity $source -DesiredIdentity $desired -ValidateOnly)
        [void]$claimedSidecars.Add($claimedKey)
        $projectedKey = [System.IO.Path]::GetFullPath($targetPath)
        if ($projectedIdentities.ContainsKey($projectedKey)) {
            if (-not (Test-InstallExactIdentityEqual -Left $projectedIdentities[$projectedKey] -Right $desired)) { throw "Pending exact-path transitions project conflicting identities: $targetPath" }
            continue
        }
        $projectedIdentities[$projectedKey] = $desired
        $actions.Add([pscustomobject]@{ Path = $targetPath; Source = $source; Desired = $desired }) | Out-Null
    }
    if ($actions.Count -gt 0) {
        if ($null -eq $ValidateProjectedPlan) { throw 'Pending exact-path transitions require projected plan validation' }
        & $ValidateProjectedPlan $projectedIdentities $Plan | Out-Null
    }
    foreach ($action in $actions) {
        [void](Invoke-InstallExactPathTransition -Path $action.Path -SourceIdentity $action.Source -DesiredIdentity $action.Desired -RecoverOnly)
    }
}

function Get-LegacyPointerMigrationMarkerPath {
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$PointerPath
    )

    $pointerIdentity = [System.IO.Path]::GetFullPath($PointerPath).ToLowerInvariant()
    return Join-Path $UserProfile ('.dev-harness\legacy-pointer-imports\{0}.sha256' -f (Get-InstallStateIdentityHash -Value $pointerIdentity))
}

function Test-LegacyPointerMigrationMarked {
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$PointerPath
    )

    $markerPath = Get-LegacyPointerMigrationMarkerPath -UserProfile $UserProfile -PointerPath $PointerPath
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $false
    }
    $markerDigest = [System.IO.File]::ReadAllText($markerPath).Trim()
    if ($markerDigest -notmatch '^[0-9a-f]{64}$') {
        throw "Legacy pointer migration marker is invalid: $markerPath"
    }
    return $true
}

function Set-LegacyPointerMigrationMarked {
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$PointerPath,
        [string]$ExpectedPointerDigest = ''
    )

    $markerPath = Get-LegacyPointerMigrationMarkerPath -UserProfile $UserProfile -PointerPath $PointerPath
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPointerDigest)) {
        if ($ExpectedPointerDigest -notmatch '^[0-9a-f]{64}$') {
            throw "Expected legacy pointer digest is invalid: $ExpectedPointerDigest"
        }
        Write-InstallStateTextAtomic -Path $markerPath -Content $ExpectedPointerDigest
        return
    }
    if (-not (Test-Path -LiteralPath $PointerPath -PathType Leaf)) {
        return
    }
    $currentPointerDigest = Get-InstallStateFileDigest -Path $PointerPath
    Write-InstallStateTextAtomic -Path $markerPath -Content $currentPointerDigest
    if ((Get-InstallStateFileDigest -Path $PointerPath) -ne $currentPointerDigest) {
        throw "Legacy pointer changed while its migration marker was written: $PointerPath"
    }
}

function Assert-LegacyPointerMigrationMarkerWritable {
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [Parameter(Mandatory = $true)][string]$PointerPath
    )

    if (-not (Test-Path -LiteralPath $PointerPath -PathType Leaf)) {
        return
    }
    $markerPath = Get-LegacyPointerMigrationMarkerPath -UserProfile $UserProfile -PointerPath $PointerPath
    if ((Test-Path -LiteralPath $markerPath) -and
        -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "Legacy pointer migration marker exists but is not a file: $markerPath"
    }
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        $markerItem = Get-Item -LiteralPath $markerPath -Force
        if ([bool]($markerItem.Attributes -band [System.IO.FileAttributes]::ReadOnly)) {
            throw "Legacy pointer migration marker is read-only: $markerPath"
        }
        $existingMarkerContent = [System.IO.File]::ReadAllText($markerPath)
        Write-InstallStateTextAtomic -Path $markerPath -Content $existingMarkerContent
        return
    }
    $probeRoot = [System.IO.Path]::GetDirectoryName($markerPath)
    [System.IO.Directory]::CreateDirectory($probeRoot) | Out-Null
    if (-not (Test-Path -LiteralPath $probeRoot -PathType Container)) {
        throw "Legacy pointer migration marker parent is not a directory: $probeRoot"
    }
    $probePath = Join-Path $probeRoot ('.dev-harness-marker-probe.{0}.{1}' -f $PID,[guid]::NewGuid().ToString('N'))
    try {
        Write-InstallStateTextAtomic -Path $probePath -Content 'probe'
    } finally {
        [System.IO.File]::Delete($probePath)
    }
}

function Assert-InstallStateTextTargetWritable {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
        throw "Install state text target is missing or not a file: $normalizedPath"
    }
    $item = Get-Item -LiteralPath $normalizedPath -Force
    if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReadOnly)) {
        throw "Install state text target is read-only: $normalizedPath"
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $normalizedPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::Read
        )
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    $probePath = Join-Path ([System.IO.Path]::GetDirectoryName($normalizedPath)) ('.dev-harness-state-probe.{0}.{1}' -f $PID,[guid]::NewGuid().ToString('N'))
    try {
        Write-InstallStateTextAtomic -Path $probePath -Content 'probe'
    } finally {
        [System.IO.File]::Delete($probePath)
    }
}

function Enter-InstallTransactionMutex {
    param(
        [Parameter(Mandatory = $true)][string]$UserProfile,
        [int]$TimeoutMilliseconds = 15000
    )

    $mutex = [System.Threading.Mutex]::new($false, (Get-InstallTransactionMutexName -UserProfile $UserProfile))
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw [System.TimeoutException]::new("Timed out waiting for install transaction lock: $UserProfile")
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-InstallTransactionMutex {
    param([System.Threading.Mutex]$Mutex)

    if ($null -eq $Mutex) {
        return
    }
    try {
        $Mutex.ReleaseMutex() | Out-Null
    } finally {
        $Mutex.Dispose()
    }
}
