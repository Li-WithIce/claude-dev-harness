[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$script:RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$script:Checks = @()
$script:Failures = @()

$scriptFiles = @(
    "install.ps1",
    "harness.ps1",
    "scripts/update-managed-assets.ps1",
    "scripts/run-validation.ps1",
    "uninstall.ps1"
)

$forbiddenCommandPattern = '(?i)(^|[\s&;|({=])(?:node|npm|npx)(?:\.exe|\.cmd)?(?=$|[\s)"''`;|}])'

foreach ($relativePath in $scriptFiles) {
    $path = Join-Path $script:RepoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Failure ("required script missing: {0}" -f $relativePath)
        continue
    }

    $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
    $lineNumber = 0
    $hits = @()
    foreach ($line in [regex]::Split($content, '\r?\n')) {
        $lineNumber += 1
        if ($line -match '^\s*#') {
            continue
        }

        if ($line -match $forbiddenCommandPattern) {
            $hits += ("{0}:{1}: {2}" -f $relativePath, $lineNumber, $line.Trim())
        }
    }

    if ($hits.Count -eq 0) {
        Add-Check ("no required Node/npm/npx command dependency in {0}" -f $relativePath)
    } else {
        Add-Failure ("Node/npm/npx command dependency leaked into {0}: {1}" -f $relativePath, ($hits -join " | "))
    }
}

Write-Output "Checks:"
if ($script:Checks.Count -eq 0) {
    Write-Output "- none"
} else {
    foreach ($check in $script:Checks) {
        Write-Output ("- {0}" -f $check)
    }
}

Write-Output ""
Write-Output "Failures:"
if ($script:Failures.Count -eq 0) {
    Write-Output "- none"
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ("- {0}" -f $failure)
}

exit 1
