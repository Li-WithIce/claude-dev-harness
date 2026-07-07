# Advisory audit for task artifact drift.
[CmdletBinding()]
param(
    [string]$TaskDir = "docs/tasks",
    [ValidateSet("Advisory", "Strict")]
    [string]$Mode = "Advisory"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Resolve-Path -LiteralPath (Get-Location)
$target = Join-Path $root $TaskDir
$warnings = New-Object System.Collections.Generic.List[string]

function Get-ChangeContractAffectedPaths {
    param([string]$Content)

    $match = [regex]::Match($Content, '(?ms)^## Change Contract\s*(?<body>.*?)(?=^## |\z)')
    if (-not $match.Success) { return @() }

    $paths = New-Object System.Collections.Generic.List[string]
    $insideAffectedPaths = $false
    foreach ($line in ($match.Groups['body'].Value -split "`r?`n")) {
        if ($line -match '^- affected_paths:\s*$') {
            $insideAffectedPaths = $true
            continue
        }

        if ($insideAffectedPaths -and $line -match '^\s*-\s+(?<path>.+?)\s*$') {
            $paths.Add($Matches['path'].Trim().Trim('`')) | Out-Null
            continue
        }

        if ($insideAffectedPaths -and $line -match '^- ') {
            break
        }
    }

    return @($paths)
}

if (-not (Test-Path -LiteralPath $target)) {
    Write-Output "WARN: artifact drift audit skipped; missing TaskDir $TaskDir"
    exit 0
}

foreach ($plan in Get-ChildItem -LiteralPath $target -Recurse -Filter plan.md -File) {
    $content = Get-Content -LiteralPath $plan.FullName -Raw -Encoding utf8
    if ($content -match '(?m)^- artifacts:\s*\[(?<items>[^\]]*)\]') {
        $items = $Matches['items'].Split(',') | ForEach-Object { $_.Trim().Trim('`') } | Where-Object { $_ }
        foreach ($item in $items) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $item))) {
                $warnings.Add(("declared artifact is missing: {0}" -f $item)) | Out-Null
            }
        }
    }

    foreach ($item in (Get-ChangeContractAffectedPaths -Content $content)) {
        $normalized = ($item -replace '\\', '/')
        if ($normalized -match '^docs/tasks/') {
            $warnings.Add(("affected_paths should describe implementation paths, not task artifacts: {0}" -f $item)) | Out-Null
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
if ($Mode -eq "Strict") { exit 1 }
exit 0
