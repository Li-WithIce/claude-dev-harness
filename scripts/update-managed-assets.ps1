[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$RepoRoot = "",
    [ValidateSet('All')]
    [string]$Scope = 'All',
    [switch]$SkipVerify,
    [switch]$RebaselineLegacyInstallState,
    [string]$ExpectedRebaselinePlanDigest = ''
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

function Find-WorkspaceRootFromLocation {
    param([string]$StartPath)

    try {
        $candidateRoot = Get-NormalizedPath -Path $StartPath
        while (-not [string]::IsNullOrWhiteSpace($candidateRoot)) {
            if (Test-Path -LiteralPath (Join-Path $candidateRoot '.assistant') -PathType Container) {
                return $candidateRoot
            }

            $parent = Split-Path -Parent $candidateRoot
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidateRoot) {
                break
            }

            $candidateRoot = $parent
        }
    } catch {
        return $null
    }

    return $null
}

function Resolve-WorkspaceRoot {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return Get-NormalizedPath -Path $ExplicitPath
    }

    $environmentCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($definition in @(
            [pscustomobject]@{ Name = 'DEV_HARNESS_WORKSPACE_ROOT'; Value = $env:DEV_HARNESS_WORKSPACE_ROOT },
            [pscustomobject]@{ Name = 'CLAUDE_DEV_HARNESS_WORKSPACE_ROOT'; Value = $env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT },
            [pscustomobject]@{ Name = 'WORKSPACE_ROOT'; Value = $env:WORKSPACE_ROOT }
        )) {
        if ([string]::IsNullOrWhiteSpace($definition.Value)) {
            continue
        }

        $environmentCandidates.Add([pscustomobject]@{
                Name = $definition.Name
                Path = Get-NormalizedPath -Path $definition.Value
            }) | Out-Null
    }

    if ($environmentCandidates.Count -gt 1) {
        $uniqueEnvironmentPaths = @($environmentCandidates | Select-Object -ExpandProperty Path -Unique)
        if ($uniqueEnvironmentPaths.Count -gt 1) {
            $details = $environmentCandidates | ForEach-Object { "{0}={1}" -f $_.Name, $_.Path }
            throw ("Conflicting workspace roots from environment: {0}" -f ($details -join '; '))
        }
    }

    if ($environmentCandidates.Count -gt 0) {
        return $environmentCandidates[0].Path
    }

    $cwdWorkspaceRoot = Find-WorkspaceRootFromLocation -StartPath (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($cwdWorkspaceRoot)) {
        return $cwdWorkspaceRoot
    }

    throw 'You must provide -WorkspaceRoot, set DEV_HARNESS_WORKSPACE_ROOT / WORKSPACE_ROOT, or run from inside a workspace that contains .assistant'
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

    $capturedOutput = New-Object System.Collections.ArrayList
    $exitCode = 0
    $stepThrew = $false
    $stepError = $null

    try {
        & $ScriptPath @Arguments 2>&1 | ForEach-Object {
            [void]$capturedOutput.Add($_)
        }
        $scriptSucceeded = $?
        $exitCode = if ($ScriptPath -like '*.ps1' -and $scriptSucceeded) {
            0
        } elseif ($null -ne $LASTEXITCODE) {
            $LASTEXITCODE
        } else {
            1
        }
    } catch {
        $stepThrew = $true
        $stepError = $_.Exception.Message
        [void]$capturedOutput.Add($stepError)
        $exitCode = 2
    }

    $lines = Convert-ToLineArray -Output @($capturedOutput)
    $text = $lines -join [Environment]::NewLine
    $status = if ($text -match '(?im)^STATUS:\s+REBASELINE_PLAN_REQUIRED\s*$') {
        'REBASELINE_PLAN_REQUIRED'
    } elseif ($text -match '(?im)^STATUS:\s+(PASS|WARN|FAIL)\s*$') {
        $matches[1].ToUpperInvariant()
    } elseif ((-not $stepThrew -and $Name -eq 'install.ps1') -or $exitCode -eq 0) {
        'PASS'
    } else {
        'FAIL'
    }

    $errors = @(Get-SectionItems -Lines $lines -SectionName 'Errors')
    if (-not [string]::IsNullOrWhiteSpace($stepError) -and $errors -notcontains $stepError) {
        $errors += $stepError
    }
    $commitState = if ($text -match '(?im)^STATUS:\s+(REBASELINE_COMMITTED|REBASELINE_ALREADY_COMMITTED)\s*$') {
        $matches[1].ToUpperInvariant()
    } else {
        $null
    }

    return [pscustomobject]@{
        Name     = $Name
        Status   = $status
        ExitCode = $exitCode
        CommitState = $commitState
        Checks   = @(Get-SectionItems -Lines $lines -SectionName 'Checks')
        Warnings = @(Get-SectionItems -Lines $lines -SectionName 'Warnings')
        Errors   = $errors
        Output   = $lines
    }
}

function Test-ExactPassResult {
    param($Result)

    if ($null -eq $Result -or $Result.ExitCode -ne 0) {
        return $false
    }

    $statusLines = @($Result.Output | Where-Object {
            ([string]$_).Trim() -match '^STATUS:\s+\S+\s*$'
        })
    return $statusLines.Count -eq 1 -and ([string]$statusLines[0]).Trim() -ceq 'STATUS: PASS'
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

$hasExpectedRebaselinePlanDigest = -not [string]::IsNullOrWhiteSpace($ExpectedRebaselinePlanDigest)
$isRebaselineApply = $RebaselineLegacyInstallState.IsPresent -and $hasExpectedRebaselinePlanDigest

if ($hasExpectedRebaselinePlanDigest -and -not $RebaselineLegacyInstallState.IsPresent) {
    Write-Output 'STATUS: FAIL'
    Write-Output 'Error: ExpectedRebaselinePlanDigest requires RebaselineLegacyInstallState.'
    exit 2
}

if ($isRebaselineApply -and $SkipVerify.IsPresent) {
    Write-Output 'STATUS: FAIL'
    Write-Output 'Error: SkipVerify cannot be used with digest-bound legacy rebaseline apply.'
    exit 2
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot

$WorkspaceRoot = Resolve-WorkspaceRoot -ExplicitPath $WorkspaceRoot

$results = @()

if ($Scope -eq 'All') {
    $installArguments = @{
        WorkspaceRoot = $WorkspaceRoot
        RepoRoot      = $RepoRoot
    }
    if ($RebaselineLegacyInstallState.IsPresent) {
        $installArguments.RebaselineLegacyInstallState = $true
    }
    if ($hasExpectedRebaselinePlanDigest) {
        $installArguments.ExpectedRebaselinePlanDigest = $ExpectedRebaselinePlanDigest
    }

    $installResult = Invoke-Step -Name 'install.ps1' -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments $installArguments
    $results += $installResult
    if ($installResult.Status -eq 'REBASELINE_PLAN_REQUIRED') {
        foreach ($line in $installResult.Output) {
            Write-Output $line
        }
        exit 1
    }
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

if ($isRebaselineApply -and
    -not [string]::IsNullOrWhiteSpace([string]$installResult.CommitState) -and
    ($installResult.Status -ne 'PASS' -or -not (Test-ExactPassResult -Result $verifyResult))) {
    $overallStatus = 'UPDATE_COMMITTED_UNVERIFIED'
} elseif ($overallStatus -ne 'FAIL') {
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
if ($overallStatus -eq 'UPDATE_COMMITTED_UNVERIFIED') {
    Write-Output '- Legacy rebaseline is committed, but the subsequent install or verification path did not complete with exact STATUS: PASS.'
    Write-Output '- Rollback: not performed.'
    Write-Output '- Retry: verify-installation.ps1, update-managed-assets.ps1, or uninstall.ps1 remain available and enforce their own safety checks.'
}

switch ($overallStatus) {
    'PASS' { exit 0 }
    'WARN' { exit 1 }
    default { exit 2 }
}
