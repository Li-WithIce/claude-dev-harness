Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HarnessJsonElement {
    param([Text.Json.JsonElement]$Element,[switch]$RejectDuplicateKeys,[string]$Label)
    switch ($Element.ValueKind) {
        'Object' {
            $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if ($RejectDuplicateKeys -and -not $keys.Add($property.Name)) { throw "$Label contains a duplicate JSON key" }
                Assert-HarnessJsonElement -Element $property.Value -RejectDuplicateKeys:$RejectDuplicateKeys -Label $Label
            }
        }
        'Array' { foreach ($item in $Element.EnumerateArray()) { Assert-HarnessJsonElement -Element $item -RejectDuplicateKeys:$RejectDuplicateKeys -Label $Label } }
        'Number' {
            [long]$integer = 0
            if (-not $Element.TryGetInt64([ref]$integer) -and $Element.GetRawText() -match '^-?(?:0|[1-9][0-9]*)$') { throw 'JSON integer is outside the supported Int64 range' }
        }
    }
}

function ConvertFrom-HarnessJsonDocument {
    param([string]$Json,[Text.Json.JsonDocumentOptions]$Options,[switch]$RejectDuplicateKeys,[string]$Label='JSON')
    $document = [Text.Json.JsonDocument]::Parse($Json,$Options)
    try {
        Assert-HarnessJsonElement -Element $document.RootElement -RejectDuplicateKeys:$RejectDuplicateKeys -Label $Label
        return $Json | ConvertFrom-Json -AsHashtable -Depth $(if ($Options.MaxDepth) { $Options.MaxDepth } else { 64 }) -DateKind String
    }
    finally { $document.Dispose() }
}

function ConvertFrom-HarnessJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)][AllowEmptyString()][string]$Json,
        [ValidateRange(1,1024)][int]$Depth = 1024
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
        Write-Output -InputObject (ConvertFrom-HarnessJsonDocument -Json $Json -Options ([Text.Json.JsonDocumentOptions]@{
            MaxDepth=$Depth;AllowTrailingCommas=$true
            CommentHandling=[Text.Json.JsonCommentHandling]::Skip}))
    }
}

function Assert-HarnessTaskId {
    param([Parameter(Mandatory)][string]$TaskId)
    if ($TaskId -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$') { throw "invalid task id: $TaskId" }
}

function Assert-HarnessNoReparseChain {
    param([Parameter(Mandatory)][string]$Path,[string]$Label,[string]$Root='')
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw "$Label has no existing contained parent" }
        $cursor = $parent
    }
    if (-not $cursor.Equals([IO.Path]::GetFullPath($Path),[StringComparison]::OrdinalIgnoreCase) -and -not (Test-Path -LiteralPath $cursor -PathType Container)) { throw "$Label parent is not a directory" }
    $stop = if ($Root) { [IO.Path]::GetFullPath($Root) } else { [IO.Path]::GetPathRoot($cursor) }
    while ($true) {
        if ((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "$Label crosses a reparse point: $cursor" }
        if ($cursor.Equals($stop,[StringComparison]::OrdinalIgnoreCase)) { return }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw "$Label has no existing contained parent" }
        $cursor = $parent
    }
}

function Resolve-HarnessWorkspaceRoot {
    param([Parameter(Mandatory)][string]$WorkspaceRoot)

    if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) { throw "WorkspaceRoot is not a directory: $WorkspaceRoot" }
    $root = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkspaceRoot).ProviderPath))
    if (((Get-Item -LiteralPath $root -Force -ErrorAction Stop).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'WorkspaceRoot must not be a reparse point' }
    return $root
}

function Resolve-HarnessSubstPath {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { return $resolved }
    $mappings = @{}
    foreach ($line in @(& subst.exe 2>$null | ForEach-Object { [string]$_ })) {
        $match = [regex]::Match($line,'^(?<drive>[A-Za-z]:)\\: => (?<target>.+)$')
        if ($match.Success) { $mappings[$match.Groups['drive'].Value] = $match.Groups['target'].Value }
    }
    for ($depth=0;$depth -lt 8;$depth++) {
        $root = [System.IO.Path]::GetPathRoot($resolved)
        if ($root -notmatch '^[A-Za-z]:\\$') { return $resolved }
        $drive = $root.Substring(0,2)
        if (-not $mappings.ContainsKey($drive)) { return $resolved }
        $next = [System.IO.Path]::GetFullPath((Join-Path $mappings[$drive] $resolved.Substring($root.Length)))
        if ($next.Equals($resolved,[System.StringComparison]::OrdinalIgnoreCase)) { throw 'WorkspaceRoot SUBST mapping is cyclic' }
        $resolved = $next
    }
    throw 'WorkspaceRoot SUBST mapping is too deep'
}

function Get-HarnessPhysicalPathIdentity {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw 'WorkspaceRoot physical identity is supported only on Windows' }
    $physical = Resolve-HarnessSubstPath -Path (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    Assert-HarnessNoReparseChain -Path $physical -Label 'WorkspaceRoot physical path'
    $fileIdMatch = [regex]::Match((@(& fsutil.exe file queryFileID $physical 2>&1 | ForEach-Object { [string]$_ }) -join "`n"),'(?i)0x[0-9a-f]{32}')
    if ($LASTEXITCODE -ne 0 -or -not $fileIdMatch.Success) { throw 'WorkspaceRoot physical identity is unavailable' }

    $root = [System.IO.Path]::GetPathRoot($physical)
    $volume = if ($root -match '^\\\\\?\\Volume\{[0-9a-f-]{36}\}\\$') {
        $root
    } else {
        $volumeOutput = @(& mountvol.exe $root /L 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0 -or -not ($volumeMatch = [regex]::Match(($volumeOutput -join "`n"),'(?i)\\\\\?\\Volume\{[0-9a-f-]{36}\}\\')).Success) { throw 'WorkspaceRoot physical identity is unavailable' }
        $volumeMatch.Value
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
        if (-not $physical.Equals($resolved,[System.StringComparison]::OrdinalIgnoreCase) -and (Get-HarnessPhysicalPathIdentity -Path $resolved) -cne (Get-HarnessPhysicalPathIdentity -Path $physical)) { throw 'WorkspaceRoot tool-compatible path changed physical identity' }
        return (Resolve-HarnessWorkspaceRoot -WorkspaceRoot $physical)
    }
    $expectedIdentity = Get-HarnessPhysicalPathIdentity -Path $resolved
    foreach ($drive in @([System.IO.DriveInfo]::GetDrives() | Sort-Object Name)) {
        $driveRoot = [string]$drive.Name
        if ($driveRoot -notmatch '^[A-Za-z]:\\$') { continue }
        $candidate = if ($physical.Length -gt $physicalRoot.Length) { [System.IO.Path]::GetFullPath((Join-Path $driveRoot $physical.Substring($physicalRoot.Length))) } else { $driveRoot }
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { continue }
        try {
            if ((Get-HarnessPhysicalPathIdentity -Path $candidate) -ceq $expectedIdentity) {
                return (Resolve-HarnessWorkspaceRoot -WorkspaceRoot $candidate)
            }
        } catch {}
    }
    throw 'WorkspaceRoot volume has no verified drive-letter path for external tools'
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
    $fullPath = [System.IO.Path]::GetFullPath($Path,$root)
    if (-not ($fullPath.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or `
        $fullPath.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))) { throw "$Label escapes WorkspaceRoot" }
    Assert-HarnessNoReparseChain -Root $root -Path $fullPath -Label $Label

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
    [void][System.IO.Directory]::CreateDirectory($target)
    return Resolve-HarnessContainedPath -WorkspaceRoot $root -Path $target -Label $Label -MustExist Directory
}

function Get-HarnessRelativePath {
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)][string]$Path)
    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    return ([System.IO.Path]::GetRelativePath($root,(Resolve-HarnessContainedPath -WorkspaceRoot $root -Path $Path -Label 'relative path target' -AllowMissing)).Replace('\','/'))
}

Export-ModuleMember -Function ConvertFrom-HarnessJson,Assert-HarnessTaskId,Resolve-HarnessWorkspaceRoot,Resolve-HarnessContainedPath,New-HarnessContainedDirectory,Get-HarnessRelativePath,Get-HarnessPhysicalPathIdentity,Resolve-HarnessToolCompatibleWorkspaceRoot
