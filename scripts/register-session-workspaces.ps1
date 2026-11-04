[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(Mandatory)][string]$AdditionalWorkspaceRootsJson,
    [Parameter(Mandatory)][string]$TaskWorkspaceRoot,
    [Parameter(Mandatory)][string]$TaskId,
    [Parameter(Mandatory)][int]$ExpectedVersion,
    [Parameter(Mandatory)][string]$ExpectedCurrentDigest,
    [string]$RepoRoot='',
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try {
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.SessionWorkspace.psm1') -Force -ErrorAction Stop
    $roots = ConvertFrom-Json -InputObject $AdditionalWorkspaceRootsJson -NoEnumerate -ErrorAction Stop
    if ($roots -isnot [Collections.IList] -or @($roots | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count) { throw 'additional workspace roots must be a JSON string array' }
    Set-HarnessSessionWorkspaceGrant -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -SessionId $SessionId -AdditionalWorkspaceRoots ([string[]]@($roots)) `
        -TaskWorkspaceRoot $TaskWorkspaceRoot -TaskId $TaskId -ExpectedVersion $ExpectedVersion -ExpectedCurrentDigest $ExpectedCurrentDigest -DryRun:$DryRun | ConvertTo-Json -Depth 30
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
