Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HarnessTaskId {
    param([Parameter(Mandatory)][string]$TaskId)
    if ($TaskId -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$') { throw "invalid task id: $TaskId" }
}

function Resolve-HarnessWorkspaceRoot {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) { throw "WorkspaceRoot is not a directory: $WorkspaceRoot" }
    $root = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
    $rootItem = Get-Item -LiteralPath $root -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'WorkspaceRoot must not be a reparse point' }
    return $root
}

function Test-HarnessPathInsideRoot {
    param([string]$Root, [string]$Path)
    $prefix = $Root + [System.IO.Path]::DirectorySeparatorChar
    return $Path -ceq $Root -or $Path.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-HarnessNoReparsePath {
    param([string]$Root, [string]$Path, [string]$Label)

    $cursor = $Path
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw "$Label has no existing contained parent" }
        $cursor = $parent
    }
    while ($cursor.Length -ge $Root.Length -and (Test-HarnessPathInsideRoot -Root $Root -Path $cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label crosses a reparse point: $cursor" }
        if ($cursor -ceq $Root) { break }
        $cursor = [System.IO.Path]::GetDirectoryName($cursor)
    }
}

function Resolve-HarnessContainedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'path',
        [ValidateSet('Any','File','Directory')][string]$MustExist = 'Any',
        [switch]$AllowMissing
    )

    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $root $Path }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    if (-not (Test-HarnessPathInsideRoot -Root $root -Path $fullPath)) { throw "$Label escapes WorkspaceRoot" }
    Assert-HarnessNoReparsePath -Root $root -Path $fullPath -Label $Label

    $exists = Test-Path -LiteralPath $fullPath
    if (-not $exists -and -not $AllowMissing) { throw "$Label does not exist: $Path" }
    if ($exists -and $MustExist -ceq 'File' -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "$Label is not a file: $Path" }
    if ($exists -and $MustExist -ceq 'Directory' -and -not (Test-Path -LiteralPath $fullPath -PathType Container)) { throw "$Label is not a directory: $Path" }
    return $fullPath
}

function New-HarnessContainedDirectory {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'directory'
    )

    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $target = Resolve-HarnessContainedPath -WorkspaceRoot $root -Path $Path -Label $Label -AllowMissing
    $relative = [System.IO.Path]::GetRelativePath($root,$target)
    $cursor = $root
    foreach ($segment in $relative -split '[\\/]') {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -ceq '.') { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            if (-not (Test-Path -LiteralPath $cursor -PathType Container)) { throw "$Label component is not a directory: $cursor" }
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label crosses a reparse point: $cursor" }
        } else {
            [void][System.IO.Directory]::CreateDirectory($cursor)
        }
    }
    return $target
}

function Get-HarnessRelativePath {
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)][string]$Path)
    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $root -Path $Path -Label 'relative path target' -AllowMissing
    return ([System.IO.Path]::GetRelativePath($root,$fullPath).Replace('\','/'))
}

Export-ModuleMember -Function Assert-HarnessTaskId,Resolve-HarnessWorkspaceRoot,Resolve-HarnessContainedPath,New-HarnessContainedDirectory,Get-HarnessRelativePath
