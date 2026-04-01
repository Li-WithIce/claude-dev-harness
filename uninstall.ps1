[CmdletBinding()]
param(
    [string]$ManifestPath = "",
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

function Restore-BackupRecord {
    param($Record)

    $targetPath = $Record['path']
    $backupPath = $Record['backup_path']
    $itemType = $Record['item_type']
    $linkType = $Record['link_type']
    $linkTarget = $Record['link_target']
    $existed = [bool]$Record['existed']

    Remove-PathIfExists -Path $targetPath

    if (-not $existed) {
        return $false
    }

    Ensure-Directory -Path (Split-Path -Parent $targetPath)

    switch ($itemType) {
        'link' {
            if ([string]::IsNullOrWhiteSpace($linkTarget)) {
                throw "Cannot restore link without target: $targetPath"
            }

            if ($linkType -eq 'Junction') {
                New-Item -ItemType Junction -Path $targetPath -Target $linkTarget | Out-Null
            } else {
                New-Item -ItemType SymbolicLink -Path $targetPath -Target $linkTarget | Out-Null
            }
            return $true
        }
        'directory' {
            if ([string]::IsNullOrWhiteSpace($backupPath) -or -not (Test-Path -LiteralPath $backupPath)) {
                throw "Missing directory backup payload: $targetPath"
            }

            Copy-Item -LiteralPath $backupPath -Destination $targetPath -Recurse -Force
            return $true
        }
        'file' {
            if ([string]::IsNullOrWhiteSpace($backupPath) -or -not (Test-Path -LiteralPath $backupPath)) {
                throw "Missing file backup payload: $targetPath"
            }

            Copy-Item -LiteralPath $backupPath -Destination $targetPath -Force
            return $true
        }
        default {
            if ([string]::IsNullOrWhiteSpace($backupPath) -or -not (Test-Path -LiteralPath $backupPath)) {
                return $false
            }

            Copy-Item -LiteralPath $backupPath -Destination $targetPath -Recurse -Force
            return $true
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$RepoRoot = Get-NormalizedPath -Path $RepoRoot

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $activeInstallPath = Join-Path (Join-Path $RepoRoot 'backups') 'active-install.json'
    $activeInstallRaw = Read-FileUtf8 -Path $activeInstallPath
    if ([string]::IsNullOrWhiteSpace($activeInstallRaw)) {
        throw "Missing active install manifest pointer: $activeInstallPath"
    }

    $activeInstall = ConvertTo-NormalizedObject -Value ($activeInstallRaw | ConvertFrom-Json)
    $ManifestPath = $activeInstall['manifest_path']
}

$ManifestPath = Get-NormalizedPath -Path $ManifestPath
$manifestRaw = Read-FileUtf8 -Path $ManifestPath
if ([string]::IsNullOrWhiteSpace($manifestRaw)) {
    throw "Missing install manifest: $ManifestPath"
}

$manifest = ConvertTo-NormalizedObject -Value ($manifestRaw | ConvertFrom-Json)
$restored = @()
$removed = @()

$backupRecords = @($manifest['backups'])
[array]::Reverse($backupRecords)

foreach ($record in $backupRecords) {
    $targetPath = $record['path']
    if (Restore-BackupRecord -Record $record) {
        $restored += $targetPath
    } else {
        $removed += $targetPath
    }
}

$generatedSystemPath = $manifest['generated_repo_system_path']
if (-not [string]::IsNullOrWhiteSpace($generatedSystemPath)) {
    Remove-PathIfExists -Path $generatedSystemPath
}

$activeInstallPath = Join-Path (Join-Path $RepoRoot 'backups') 'active-install.json'
if (Test-Path -LiteralPath $activeInstallPath -PathType Leaf) {
    $activeInstallRaw = Read-FileUtf8 -Path $activeInstallPath
    if (-not [string]::IsNullOrWhiteSpace($activeInstallRaw)) {
        $activeInstall = ConvertTo-NormalizedObject -Value ($activeInstallRaw | ConvertFrom-Json)
        if ($activeInstall['manifest_path'] -eq $ManifestPath) {
            Remove-PathIfExists -Path $activeInstallPath
        }
    }
}

Write-Output 'Uninstall summary:'
Write-Output ('- manifest: {0}' -f $ManifestPath)
Write-Output ('- restored_count: {0}' -f $restored.Count)
Write-Output ('- removed_generated_count: {0}' -f $removed.Count)
if ($restored.Count -gt 0) {
    Write-Output '- restored paths:'
    foreach ($path in $restored) {
        Write-Output ('  {0}' -f $path)
    }
}
if ($removed.Count -gt 0) {
    Write-Output '- removed generated paths:'
    foreach ($path in $removed) {
        Write-Output ('  {0}' -f $path)
    }
}
