[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Invoke-RepoScript {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [hashtable]$Arguments
    )

    $originalUserProfile = $env:USERPROFILE
    try {
        $env:USERPROFILE = $UserProfile
        $output = @(& $ScriptPath @Arguments 2>&1)
        return [pscustomobject]@{
            Output   = $output
            ExitCode = $LASTEXITCODE
        }
    } finally {
        $env:USERPROFILE = $originalUserProfile
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$scratchRoot = Join-Path $RepoRoot 'tmp\install-isolation-regression'
if (Test-Path -LiteralPath $scratchRoot) {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $scratchRoot | Out-Null

$checks = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

$caseRoot = Join-Path $scratchRoot 'host-only-system-skill-does-not-pollute-repo'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$userProfile = Join-Path $caseRoot 'user'
New-Item -ItemType Directory -Path $workspaceRoot,$userProfile -Force | Out-Null

$localSystemSkillPath = Join-Path $userProfile '.claude\skills\.system\custom-local-skill'
New-Item -ItemType Directory -Path $localSystemSkillPath -Force | Out-Null
Set-Content -LiteralPath (Join-Path $localSystemSkillPath 'SKILL.md') -Value '# local only' -Encoding utf8

$installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($installResult.ExitCode -ne 0) {
    $failures.Add('install.ps1 should succeed when a host-only local system skill exists') | Out-Null
} else {
    $checks.Add('install.ps1 succeeds when a host-only local system skill exists') | Out-Null
}

$repoSystemPollutionPath = Join-Path $RepoRoot 'skills\.system\custom-local-skill'
if (Test-Path -LiteralPath $repoSystemPollutionPath) {
    $failures.Add('install.ps1 should not copy host-only local system skills into repo-local skills/.system') | Out-Null
} else {
    $checks.Add('install.ps1 does not copy host-only local system skills into repo-local skills/.system') | Out-Null
}

if (-not (Test-Path -LiteralPath (Join-Path $localSystemSkillPath 'SKILL.md') -PathType Leaf)) {
    $failures.Add('install.ps1 should preserve the original host-only local system skill') | Out-Null
} else {
    $checks.Add('install.ps1 preserves the original host-only local system skill') | Out-Null
}

$verifyResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

$verifyOutput = $verifyResult.Output -join [Environment]::NewLine
if ($verifyResult.ExitCode -ne 0 -or $verifyOutput -notmatch '(?im)^STATUS:\s+PASS\s*$') {
    $failures.Add('verify-installation.ps1 should pass after installing with a host-only local system skill') | Out-Null
} else {
    $checks.Add('verify-installation.ps1 passes after installing with a host-only local system skill') | Out-Null
}

Write-Output 'Checks:'
if ($checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($check in $checks) {
        Write-Output ('- {0}' -f $check)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $failures) {
    Write-Output ('- {0}' -f $failure)
}

Write-Output ''
Write-Output 'Install Output:'
if ($installResult.Output.Count -eq 0) {
    Write-Output '- none'
} else {
    $installResult.Output | ForEach-Object { Write-Output ([string]$_) }
}

Write-Output ''
Write-Output 'Verify Output:'
if ($verifyResult.Output.Count -eq 0) {
    Write-Output '- none'
} else {
    $verifyResult.Output | ForEach-Object { Write-Output ([string]$_) }
}

exit 1
