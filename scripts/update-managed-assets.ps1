[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$RepoRoot = "",
    [ValidateSet('All')]
    [string]$Scope = 'All',
    [switch]$SkipVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Convert-ToLineArray {
    param($Output)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Output)) {
        if ($null -eq $item) {
            continue
        }
        [void]$lines.Add(([string]$item))
    }

    return @($lines)
}

function Get-SectionItems {
    param(
        [string[]]$Lines,
        [string]$SectionName
    )

    $startIndex = -1
    for ($index = 0; $index -lt $Lines.Count; $index += 1) {
        if ($Lines[$index].Trim() -eq ("{0}:" -f $SectionName)) {
            $startIndex = $index + 1
            break
        }
    }

    if ($startIndex -lt 0) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[string]
    for ($index = $startIndex; $index -lt $Lines.Count; $index += 1) {
        $line = $Lines[$index].Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($items.Count -gt 0) {
                break
            }
            continue
        }

        if ($line -match '^[A-Za-z][A-Za-z /()_-]*:$') {
            break
        }

        if ($line -eq '- none') {
            continue
        }

        if ($line.StartsWith('- ')) {
            [void]$items.Add($line.Substring(2))
        }
    }

    return @($items)
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$Arguments
    )

    $output = @()
    $exitCode = 0

    try {
        $output = @(& $ScriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $output = @($_.Exception.Message)
        $exitCode = 2
    }

    $lines = Convert-ToLineArray -Output $output
    $text = $lines -join [Environment]::NewLine
    $status = if ($text -match '(?im)^STATUS:\s+(PASS|WARN|FAIL)\s*$') {
        $matches[1].ToUpperInvariant()
    } elseif ($exitCode -eq 0) {
        'PASS'
    } else {
        'FAIL'
    }

    return [pscustomobject]@{
        Name     = $Name
        Status   = $status
        ExitCode = $exitCode
        Checks   = @(Get-SectionItems -Lines $lines -SectionName 'Checks')
        Warnings = @(Get-SectionItems -Lines $lines -SectionName 'Warnings')
        Errors   = @(Get-SectionItems -Lines $lines -SectionName 'Errors')
        Output   = $lines
    }
}

function Get-OverallStatus {
    param([object[]]$Results)

    if (@($Results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) {
        return 'FAIL'
    }

    if (@($Results | Where-Object { $_.Status -eq 'WARN' }).Count -gt 0) {
        return 'WARN'
    }

    return 'PASS'
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    foreach ($candidate in @($env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT, $env:WORKSPACE_ROOT)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $WorkspaceRoot = $candidate
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    try {
        $candidateRoot = Get-NormalizedPath -Path (Get-Location).Path
        while (-not [string]::IsNullOrWhiteSpace($candidateRoot)) {
            if (Test-Path -LiteralPath (Join-Path $candidateRoot '.assistant') -PathType Container) {
                $WorkspaceRoot = $candidateRoot
                break
            }

            $parent = Split-Path -Parent $candidateRoot
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidateRoot) {
                break
            }

            $candidateRoot = $parent
        }
    } catch {
        # Ignore workspace inference failures and fall back to the explicit error.
    }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    throw 'You must provide -WorkspaceRoot, set CLAUDE_DEV_HARNESS_WORKSPACE_ROOT / WORKSPACE_ROOT, or run from inside a workspace that contains .assistant'
}

$WorkspaceRoot = Get-NormalizedPath -Path $WorkspaceRoot

$results = @()

if ($Scope -eq 'All') {
    $installResult = Invoke-Step -Name 'install.ps1' -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $WorkspaceRoot
        RepoRoot      = $RepoRoot
    }
    $results += $installResult
    if ($installResult.Status -eq 'FAIL') {
        $overallStatus = 'FAIL'
    } else {
        $overallStatus = $null
    }
} else {
    $overallStatus = $null
}

if ($overallStatus -ne 'FAIL' -and -not $SkipVerify) {
    $verifyResult = Invoke-Step -Name 'verify-installation.ps1' -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $WorkspaceRoot
        RepoRoot      = $RepoRoot
        Scope         = $Scope
    }
    $results += $verifyResult
}

if ($overallStatus -ne 'FAIL') {
    $overallStatus = Get-OverallStatus -Results $results
}

Write-Output ("STATUS: {0}" -f $overallStatus)
Write-Output ("Scope: {0}" -f $Scope)
Write-Output ("RepoRoot: {0}" -f $RepoRoot)
Write-Output ("WorkspaceRoot: {0}" -f $WorkspaceRoot)
Write-Output ''
Write-Output 'Steps:'
foreach ($result in $results) {
    Write-Output ("- {0}: {1}" -f $result.Name, $result.Status)
}
if ($SkipVerify) {
    Write-Output '- verify-installation.ps1: SKIP'
}
Write-Output ''
Write-Output 'Highlights:'
foreach ($result in $results) {
    $highlights = @($result.Errors) + @($result.Warnings)
    if ($highlights.Count -eq 0) {
        $highlights = $result.Checks
    }

    if ($highlights.Count -eq 0) {
        Write-Output ("- {0}: none" -f $result.Name)
        continue
    }

    Write-Output ("- {0}: {1}" -f $result.Name, $highlights[0])
}
if ($SkipVerify) {
    Write-Output '- verify-installation.ps1: skipped by request'
}

switch ($overallStatus) {
    'PASS' { exit 0 }
    'WARN' { exit 1 }
    default { exit 2 }
}
