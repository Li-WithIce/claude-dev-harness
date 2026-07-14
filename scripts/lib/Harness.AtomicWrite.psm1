Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop

function Get-HarnessSha256Bytes {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return 'sha256:' + ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-HarnessSha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    return Get-HarnessSha256Bytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes($Content))
}

function Get-HarnessFileDigest {
    param([Parameter(Mandatory)][string]$WorkspaceRoot, [Parameter(Mandatory)][string]$Path)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'digest path' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "digest path is not a file: $Path" }
    return 'sha256:' + (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
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
