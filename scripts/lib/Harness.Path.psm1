Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HarnessTaskId {
    param([Parameter(Mandatory)][string]$TaskId)
    if ($TaskId -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$') { throw "invalid task id: $TaskId" }
}

function Assert-HarnessNoReparseAncestor {
    param([Parameter(Mandatory)][string]$Path,[string]$Label)

    $cursor = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($cursor)
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label contains a reparse point: $cursor" }
        if ($cursor.Equals($pathRoot,[System.StringComparison]::OrdinalIgnoreCase)) { break }
        $trimmed = $cursor.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
        $parent = [System.IO.Path]::GetDirectoryName($trimmed)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor -or $parent -eq $trimmed) { break }
        $cursor = $parent
    }
}

function Resolve-HarnessWorkspaceRoot {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) { throw "WorkspaceRoot is not a directory: $WorkspaceRoot" }
    $fullPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).ProviderPath)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    $root = if ($fullPath.Equals($pathRoot,[System.StringComparison]::OrdinalIgnoreCase)) {
        $pathRoot
    } else {
        $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
    }
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'WorkspaceRoot must not be a reparse point' }
    return $root
}

function Resolve-HarnessSubstPath {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { return $resolved }
    for ($depth=0;$depth -lt 8;$depth++) {
        $root = [System.IO.Path]::GetPathRoot($resolved)
        if ($root -notmatch '^[A-Za-z]:\\$') { return $resolved }
        $drive = $root.Substring(0,2)
        $mapping = $null
        foreach ($line in @(& subst.exe 2>$null | ForEach-Object { [string]$_ })) {
            $match = [regex]::Match($line,'^(?<drive>[A-Za-z]:)\\: => (?<target>.+)$')
            if ($match.Success -and [string]$match.Groups['drive'].Value -ieq $drive) {
                $mapping = [string]$match.Groups['target'].Value
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($mapping)) { return $resolved }
        $tail = $resolved.Substring($root.Length)
        $next = [System.IO.Path]::GetFullPath((Join-Path $mapping $tail))
        if ($next.Equals($resolved,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'WorkspaceRoot SUBST mapping is cyclic' }
        $resolved = $next
    }
    throw 'WorkspaceRoot SUBST mapping is too deep'
}

function Get-HarnessPhysicalPathIdentity {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw 'WorkspaceRoot physical identity is supported only on Windows' }
    $physical = Resolve-HarnessSubstPath -Path $resolved
    Assert-HarnessNoReparseAncestor -Path $physical -Label 'WorkspaceRoot physical path'
    $fileIdOutput = @(& fsutil.exe file queryFileID $physical 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'WorkspaceRoot physical identity is unavailable' }
    $fileIdMatch = [regex]::Match(($fileIdOutput -join "`n"),'(?i)0x[0-9a-f]{32}')
    if (-not $fileIdMatch.Success) { throw 'WorkspaceRoot physical identity is unavailable' }

    $root = [System.IO.Path]::GetPathRoot($physical)
    $volume = $null
    if ($root -match '^\\\\\?\\Volume\{[0-9a-f-]{36}\}\\$') {
        $volume = $root
    } else {
        $candidate = [System.IO.Path]::GetFullPath($physical)
        while (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $mountPoint = $candidate.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
            $volumeOutput = @(& mountvol.exe $mountPoint /L 2>&1 | ForEach-Object { [string]$_ })
            if ($LASTEXITCODE -eq 0) {
                $volumeMatch = [regex]::Match(($volumeOutput -join "`n"),'(?i)\\\\\?\\Volume\{[0-9a-f-]{36}\}\\')
                if (-not $volumeMatch.Success) { throw 'WorkspaceRoot physical identity is unavailable' }
                $volume = $volumeMatch.Value
                break
            }
            $parent = [System.IO.Path]::GetDirectoryName($candidate.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar))
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) { break }
            $candidate = $parent
        }
        if ([string]::IsNullOrWhiteSpace($volume)) { throw 'WorkspaceRoot physical identity is unavailable' }
    }
    return ('volume:{0}|file:{1}' -f $volume.ToLowerInvariant(),$fileIdMatch.Value.ToLowerInvariant())
}

function Resolve-HarnessToolCompatibleWorkspaceRoot {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    $resolved = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { return $resolved }

    $physical = Resolve-HarnessSubstPath -Path $resolved
    $physicalRoot = [System.IO.Path]::GetPathRoot($physical)
    if ($physicalRoot -notmatch '^\\\\\?\\Volume\{[0-9a-f-]{36}\}\\$') {
        if (-not $physical.Equals($resolved,[System.StringComparison]::OrdinalIgnoreCase)) {
            $expectedIdentity = Get-HarnessPhysicalPathIdentity -Path $resolved
            if ((Get-HarnessPhysicalPathIdentity -Path $physical) -cne $expectedIdentity) {
                throw 'WorkspaceRoot tool-compatible path changed physical identity'
            }
        }
        return (Resolve-HarnessWorkspaceRoot -WorkspaceRoot $physical)
    }

    $expectedIdentity = Get-HarnessPhysicalPathIdentity -Path $resolved
    $toolRoot = $null
    foreach ($drive in @([System.IO.DriveInfo]::GetDrives() | Sort-Object Name)) {
        $driveRoot = [string]$drive.Name
        if ($driveRoot -notmatch '^[A-Za-z]:\\$') { continue }
        $volumeOutput = @(& mountvol.exe $driveRoot /L 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { continue }
        $volumeMatch = [regex]::Match(($volumeOutput -join "`n"),'(?i)\\\\\?\\Volume\{[0-9a-f-]{36}\}\\')
        if (-not $volumeMatch.Success -or
            -not $volumeMatch.Value.Equals($physicalRoot,[System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $tail = $physical.Substring($physicalRoot.Length)
        $candidate = if ([string]::IsNullOrEmpty($tail)) {
            $driveRoot
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $driveRoot $tail))
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        try {
            if ((Get-HarnessPhysicalPathIdentity -Path $candidate) -ceq $expectedIdentity) {
                $toolRoot = $candidate
                break
            }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($toolRoot)) {
        throw 'WorkspaceRoot volume has no verified drive-letter path for external tools'
    }
    return (Resolve-HarnessWorkspaceRoot -WorkspaceRoot $toolRoot)
}

function Test-HarnessPathInsideRoot {
    param([string]$Root, [string]$Path)
    $prefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return $Path.Equals($Root,[System.StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)
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
    $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    } else {
        [System.IO.Path]::GetFullPath($Path,$root)
    }
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

Export-ModuleMember -Function Assert-HarnessTaskId,Resolve-HarnessWorkspaceRoot,Resolve-HarnessContainedPath,New-HarnessContainedDirectory,Get-HarnessRelativePath,Get-HarnessPhysicalPathIdentity,Resolve-HarnessToolCompatibleWorkspaceRoot
