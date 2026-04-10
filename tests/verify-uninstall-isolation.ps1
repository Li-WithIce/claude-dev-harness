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

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$scratchRoot = Join-Path $RepoRoot 'tmp\uninstall-isolation-regression'
if (Test-Path -LiteralPath $scratchRoot) {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $scratchRoot | Out-Null

$checks = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

$caseRoot = Join-Path $scratchRoot 'host-only-system-skill-survives-uninstall'
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
    $failures.Add('install.ps1 should succeed before uninstall isolation checks run') | Out-Null
} else {
    $checks.Add('install.ps1 succeeds before uninstall isolation checks run') | Out-Null
}

$activeInstallPath = Join-Path $RepoRoot 'backups\active-install.json'
$activeInstall = Read-JsonFile -Path $activeInstallPath
$manifestPath = if ($null -ne $activeInstall) {
    Get-NormalizedPath -Path $activeInstall.manifest_path
} else {
    $null
}
$manifest = Read-JsonFile -Path $manifestPath
$expectedClaudeHome = Get-NormalizedPath -Path (Join-Path $userProfile '.claude')
$expectedCodexHome = Get-NormalizedPath -Path (Join-Path $userProfile '.codex')
$manifestMatchesSandbox = $false
if ($null -ne $manifest) {
    $manifestMatchesSandbox = `
        ((Get-NormalizedPath -Path $manifest.workspace_root) -eq $workspaceRoot) -and `
        ((Get-NormalizedPath -Path $manifest.claude_home) -eq $expectedClaudeHome) -and `
        ((Get-NormalizedPath -Path $manifest.codex_home) -eq $expectedCodexHome)
}

if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $failures.Add('install.ps1 should leave a readable active-install manifest for uninstall.ps1') | Out-Null
} elseif (-not $manifestMatchesSandbox) {
    $failures.Add('active-install manifest should belong to the sandbox install before uninstall.ps1 runs') | Out-Null
} else {
    $checks.Add('install.ps1 leaves a readable active-install manifest for uninstall.ps1') | Out-Null
}

$uninstallResult = [pscustomobject]@{
    Output   = @()
    ExitCode = 0
}

if ($manifestMatchesSandbox) {
    $uninstallResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot     = $RepoRoot
        ManifestPath = $manifestPath
    }
}

if (-not $manifestMatchesSandbox) {
    $failures.Add('uninstall.ps1 was skipped because the active-install manifest did not belong to this sandbox run') | Out-Null
} elseif ($uninstallResult.ExitCode -ne 0) {
    $failures.Add('uninstall.ps1 should succeed after installing with a host-only local system skill') | Out-Null
} else {
    $checks.Add('uninstall.ps1 succeeds after installing with a host-only local system skill') | Out-Null
}

$repoSystemPollutionPath = Join-Path $RepoRoot 'skills\.system\custom-local-skill'
if (Test-Path -LiteralPath $repoSystemPollutionPath) {
    $failures.Add('uninstall.ps1 should not leave host-only local system skills behind in repo-local skills/.system') | Out-Null
} else {
    $checks.Add('uninstall.ps1 does not leave host-only local system skills behind in repo-local skills/.system') | Out-Null
}

$localSkillFilePath = Join-Path $localSystemSkillPath 'SKILL.md'
if (-not (Test-Path -LiteralPath $localSkillFilePath -PathType Leaf)) {
    $failures.Add('uninstall.ps1 should preserve the original host-only local system skill') | Out-Null
} elseif ((Get-Content -LiteralPath $localSkillFilePath -Raw -Encoding utf8).Trim() -ne '# local only') {
    $failures.Add('uninstall.ps1 should restore the original host-only local system skill contents') | Out-Null
} else {
    $checks.Add('uninstall.ps1 preserves the original host-only local system skill') | Out-Null
}

if (Test-Path -LiteralPath $activeInstallPath -PathType Leaf) {
    $failures.Add('uninstall.ps1 should remove the active-install manifest pointer after restoring the matching install') | Out-Null
} else {
    $checks.Add('uninstall.ps1 removes the active-install manifest pointer after restoring the matching install') | Out-Null
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
Write-Output 'Uninstall Output:'
if ($uninstallResult.Output.Count -eq 0) {
    Write-Output '- none'
} else {
    $uninstallResult.Output | ForEach-Object { Write-Output ([string]$_) }
}

exit 1
