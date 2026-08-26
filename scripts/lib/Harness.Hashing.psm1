Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-HarnessSha256Bytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return 'sha256:' + ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-HarnessFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "hash path is not a file: $Path"
    }
    return 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-HarnessUtf8TextSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return Get-HarnessSha256Bytes -Bytes $script:Utf8NoBom.GetBytes($Text)
}

function Get-HarnessNormalizedTextSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $normalized = $normalized.TrimEnd([char[]]"`r`n") + "`n"
    return Get-HarnessUtf8TextSha256 -Text $normalized
}

Export-ModuleMember -Function Get-HarnessSha256Bytes,Get-HarnessFileSha256,Get-HarnessUtf8TextSha256,Get-HarnessNormalizedTextSha256
