# Advisory audit for provider usage notes.
[CmdletBinding()]
param(
    [string]$TaskDir = "docs/tasks",
    [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$warnings = New-Object System.Collections.Generic.List[string]
$root = Resolve-Path -LiteralPath (Get-Location)
$target = Join-Path $root $TaskDir

if (-not (Test-Path -LiteralPath $target)) {
    Write-Output "WARN: provider usage audit skipped; missing TaskDir $TaskDir"
    exit 0
}

$dangerous = @(
    "provider says safe",
    "no callers so safe",
    "agentmemory confirms current stage",
    "index says safe"
)

foreach ($file in Get-ChildItem -LiteralPath $target -Recurse -File -Include *.md) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    foreach ($needle in $dangerous) {
        if ($content.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $warnings.Add(("provider usage dangerous phrase in {0}: {1}" -f $file.FullName.Substring($root.Path.Length).TrimStart('\'), $needle)) | Out-Null
        }
    }
}

if ($warnings.Count -eq 0) {
    Write-Output "STATUS: PASS"
    Write-Output "Warnings: none"
    exit 0
}

Write-Output "STATUS: WARN"
Write-Output "Warnings:"
$warnings | ForEach-Object { Write-Output ("- {0}" -f $_) }
if ($Strict) { exit 1 }
exit 0
