[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

$inventory = [ordered]@{
    skill_directories = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'skills') -Directory -Force).Count
    powershell_scripts = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -Filter '*.ps1' -File).Count
    claude_hooks = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'runtime-hooks\claude') -Filter '*.js' -File).Count
    verify_scripts = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests') -Filter 'verify-*.ps1' -File).Count
}

if ($AsJson) {
    $inventory | ConvertTo-Json
    exit 0
}

Write-Output '# Repository inventory'
Write-Output ''
foreach ($entry in $inventory.GetEnumerator()) {
    Write-Output ('- {0}: {1}' -f $entry.Key, $entry.Value)
}
