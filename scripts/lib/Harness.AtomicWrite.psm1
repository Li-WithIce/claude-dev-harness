Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -Force -ErrorAction Stop

function Get-HarnessSha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    return Get-HarnessUtf8TextSha256 -Text $Content
}

function Get-HarnessFileDigest {
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)][string]$Path)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'digest path' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "digest path is not a file: $Path" }
    return Get-HarnessFileSha256 -Path $fullPath
}

function Write-HarnessAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'atomic target' -AllowMissing
    $directory = New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path ([System.IO.Path]::GetDirectoryName($fullPath)) -Label 'atomic target parent'
    if ((Test-Path -LiteralPath $fullPath) -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "atomic target is not a file: $Path" }

    $tempPath = Join-Path $directory ('.{0}.{1}.{2}.tmp' -f [System.IO.Path]::GetFileName($fullPath),$PID,[guid]::NewGuid().ToString('N'))
    $backupPath = "$tempPath.bak"
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
        $stream = [System.IO.FileStream]::new($tempPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,4096,[System.IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [System.IO.File]::Replace($tempPath,$fullPath,$backupPath,$true)
        } else {
            [System.IO.File]::Move($tempPath,$fullPath)
        }
    } finally {
        foreach ($candidate in @($tempPath,$backupPath)) { if ([System.IO.File]::Exists($candidate)) { [System.IO.File]::Delete($candidate) } }
    }
    return Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $fullPath
}

function Write-HarnessAtomicBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$SourceBytes,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')][string]$ExpectedSourceDigest,
        [Parameter(Mandatory)][ValidatePattern('^(?:missing|sha256:[0-9a-f]{64})$')][string]$ExpectedCurrentDigest
    )

    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $workspace -Path $Path -Label 'atomic target' -AllowMissing
    if ((Test-Path -LiteralPath $fullPath) -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "atomic target is not a file: $Path" }

    $tempPath = Join-Path $workspace ('.harness-publish.{0}.{1}.tmp' -f $PID,[guid]::NewGuid().ToString('N'))
    $backupPath = "$tempPath.bak"
    $rejectedPath = "$tempPath.rejected"
    $createdDirectories = [System.Collections.Generic.List[string]]::new()
    $committed = $false
    $cleanupConflictFiles = $false
    try {
        $stream = [System.IO.FileStream]::new($tempPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,4096,[System.IO.FileOptions]::WriteThrough)
        try { $stream.Write($SourceBytes,0,$SourceBytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $tempDigest = Get-HarnessFileSha256 -Path $tempPath
        if ($tempDigest -cne $ExpectedSourceDigest) { throw 'atomic source digest changed before publish' }

        $directoryPath = [System.IO.Path]::GetDirectoryName($fullPath)
        $cursor = $directoryPath
        while (-not (Test-Path -LiteralPath $cursor)) {
            $createdDirectories.Add($cursor)
            $parent = [System.IO.Path]::GetDirectoryName($cursor)
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw 'atomic target parent is unavailable' }
            $cursor = $parent
        }
        [void](New-HarnessContainedDirectory -WorkspaceRoot $workspace -Path $directoryPath -Label 'atomic target parent')
        if ($ExpectedCurrentDigest -ceq 'missing') {
            [System.IO.File]::Move($tempPath,$fullPath)
        } else {
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'atomic target digest changed before publish' }
            $currentDigest = Get-HarnessFileSha256 -Path $fullPath
            if ($currentDigest -cne $ExpectedCurrentDigest) { throw 'atomic target digest changed before publish' }
            [System.IO.File]::Replace($tempPath,$fullPath,$backupPath,$true)
            $overwrittenDigest = $null
            try {
                $overwrittenDigest = Get-HarnessFileSha256 -Path $backupPath
                if ($overwrittenDigest -cne $ExpectedCurrentDigest) { throw 'atomic target digest changed before publish' }
            } catch {
                $verificationError = $_
                try {
                    if (-not [System.IO.File]::Exists($backupPath)) { throw 'atomic target backup is unavailable' }
                    $publishedDigest = Get-HarnessFileSha256 -Path $fullPath
                    if ($publishedDigest -cne $ExpectedSourceDigest) { throw 'atomic target conflict recovery changed concurrently' }
                    [System.IO.File]::Replace($backupPath,$fullPath,$rejectedPath,$true)
                    $restoredDigest = Get-HarnessFileSha256 -Path $fullPath
                    $rejectedDigest = Get-HarnessFileSha256 -Path $rejectedPath
                    if (($null -ne $overwrittenDigest -and $restoredDigest -cne $overwrittenDigest) -or $rejectedDigest -cne $ExpectedSourceDigest) { throw 'atomic target conflict recovery changed concurrently' }
                    $cleanupConflictFiles = $true
                } catch {
                    throw 'atomic target conflict recovery failed; recovery files were preserved'
                }
                throw $verificationError
            }
            $cleanupConflictFiles = $true
        }
        $committed = $true
        return $ExpectedSourceDigest
    } finally {
        foreach ($candidate in @($tempPath) + $(if ($cleanupConflictFiles) { @($backupPath,$rejectedPath) } else { @() })) {
            try { if ([System.IO.File]::Exists($candidate)) { [System.IO.File]::Delete($candidate) } } catch { }
        }
        if (-not $committed) {
            foreach ($directory in $createdDirectories) {
                try { if ((Test-Path -LiteralPath $directory -PathType Container) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { [System.IO.Directory]::Delete($directory,$false) } } catch { }
            }
        }
    }
}

function Remove-HarnessFileIfDigestAtomic {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')][string]$ExpectedDigest
    )
    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $workspace -Path $Path -Label 'atomic delete target' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return $false }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'atomic delete target is not a file' }
    $currentDigest = Get-HarnessFileSha256 -Path $fullPath
    if ($currentDigest -cne $ExpectedDigest) { throw 'atomic delete target digest changed' }
    $quarantinePath = Join-Path $workspace ('.harness-delete.{0}.{1}.tmp' -f $PID,[guid]::NewGuid().ToString('N'))
    $restore = $false
    try {
        [System.IO.File]::Move($fullPath,$quarantinePath)
        $actualDigest = Get-HarnessFileSha256 -Path $quarantinePath
        if ($actualDigest -cne $ExpectedDigest) { $restore = $true; throw 'atomic delete target digest changed' }
        [System.IO.File]::Delete($quarantinePath)
        return $true
    } finally {
        if ($restore -and [System.IO.File]::Exists($quarantinePath)) {
            try { [System.IO.File]::Move($quarantinePath,$fullPath) } catch { throw 'atomic delete conflict recovery failed; recovery file was preserved' }
        }
    }
}

function Remove-HarnessFileIfDigest {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedDigest
    )

    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'delete target' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return $false }
    $actual = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $fullPath
    if ($actual -cne $ExpectedDigest) { throw "delete target digest changed: $Path" }
    [System.IO.File]::Delete($fullPath)
    return $true
}

Export-ModuleMember -Function Get-HarnessSha256Text,Get-HarnessFileDigest,Write-HarnessAtomicText,Remove-HarnessFileIfDigest
