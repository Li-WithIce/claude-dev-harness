[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [ValidateSet('Both', 'Claude', 'Codex')]
    [string]$TargetHost = 'Both'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-RelativePath {
    param(
        [string]$RootPath,
        [string]$FullPath
    )

    $normalizedRoot = (Get-NormalizedPath -Path $RootPath).TrimEnd('\')
    $normalizedFullPath = Get-NormalizedPath -Path $FullPath
    return $normalizedFullPath.Substring($normalizedRoot.Length).TrimStart('\')
}

function Sync-DirectoryMirror {
    param(
        [string]$SourcePath,
        [string]$TargetPath
    )

    Ensure-Directory -Path $TargetPath

    $result = [ordered]@{
        created = 0
        updated = 0
        removed = 0
    }

    foreach ($sourceDir in Get-ChildItem -LiteralPath $SourcePath -Recurse -Directory -Force) {
        $relative = Get-RelativePath -RootPath $SourcePath -FullPath $sourceDir.FullName
        Ensure-Directory -Path (Join-Path $TargetPath $relative)
    }

    foreach ($sourceFile in Get-ChildItem -LiteralPath $SourcePath -Recurse -File -Force) {
        $relative = Get-RelativePath -RootPath $SourcePath -FullPath $sourceFile.FullName
        $targetFile = Join-Path $TargetPath $relative
        Ensure-Directory -Path (Split-Path -Parent $targetFile)

        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetFile -Force
            $result.created += 1
            continue
        }

        $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
        if ($sourceHash -ne $targetHash) {
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetFile -Force
            $result.updated += 1
        }
    }

    $targetItems = Get-ChildItem -LiteralPath $TargetPath -Recurse -Force | Sort-Object FullName -Descending
    foreach ($targetItem in $targetItems) {
        $relative = Get-RelativePath -RootPath $TargetPath -FullPath $targetItem.FullName
        $sourceItem = Join-Path $SourcePath $relative
        if (Test-Path -LiteralPath $sourceItem) {
            continue
        }

        Remove-PathIfExists -Path $targetItem.FullName
        $result.removed += 1
    }

    return $result
}

function Sync-PreservedDocsForHost {
    param(
        [string]$HostLabel,
        [string]$HostDocsPath,
        [string]$RepoDocsPath
    )

    if (-not (Test-Path -LiteralPath $HostDocsPath)) {
        Write-Output ("- {0}: skip, preserved docs 目录不存在: {1}" -f $HostLabel, $HostDocsPath)
        return
    }

    $junctionTarget = Get-JunctionTarget -Path $HostDocsPath
    if ($null -ne $junctionTarget) {
        Write-Output ("- {0}: skip, 当前已是 Junction: {1} -> {2}" -f $HostLabel, $HostDocsPath, $junctionTarget)
        return
    }

    if (-not (Test-Path -LiteralPath $HostDocsPath -PathType Container)) {
        throw ("{0} docs 路径不是目录: {1}" -f $HostLabel, $HostDocsPath)
    }

    $syncResult = Sync-DirectoryMirror -SourcePath $RepoDocsPath -TargetPath $HostDocsPath
    Write-Output ("- {0}: synced preserved docs (created={1}, updated={2}, removed={3})" -f $HostLabel, $syncResult.created, $syncResult.updated, $syncResult.removed)
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is required for sync-preserved-docs.ps1'
}

$RepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
} else {
    $RepoRoot
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$RepoDocsPath = Join-Path $RepoRoot 'skills\docs'
if (-not (Test-Path -LiteralPath $RepoDocsPath -PathType Container)) {
    throw ("Repo docs 目录不存在: {0}" -f $RepoDocsPath)
}

$claudeDocsPath = Join-Path (Join-Path $env:USERPROFILE '.claude\skills') 'docs'
$codexDocsPath = Join-Path (Join-Path $env:USERPROFILE '.codex\skills') 'docs'

Write-Output 'Sync preserved docs:'
Write-Output ("- repo_docs: {0}" -f $RepoDocsPath)

switch ($TargetHost) {
    'Claude' {
        Sync-PreservedDocsForHost -HostLabel 'Claude' -HostDocsPath $claudeDocsPath -RepoDocsPath $RepoDocsPath
    }
    'Codex' {
        Sync-PreservedDocsForHost -HostLabel 'Codex' -HostDocsPath $codexDocsPath -RepoDocsPath $RepoDocsPath
    }
    default {
        Sync-PreservedDocsForHost -HostLabel 'Claude' -HostDocsPath $claudeDocsPath -RepoDocsPath $RepoDocsPath
        Sync-PreservedDocsForHost -HostLabel 'Codex' -HostDocsPath $codexDocsPath -RepoDocsPath $RepoDocsPath
    }
}

$global:LASTEXITCODE = 0
