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
        [hashtable]$Arguments,
        [string]$WorkingDirectory = ''
    )

    $originalUserProfile = $env:USERPROFILE
    $originalLocation = $null
    try {
        $env:USERPROFILE = $UserProfile
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $originalLocation = (Get-Location).Path
            Set-Location -LiteralPath $WorkingDirectory
        }

        $output = @(& $ScriptPath @Arguments 2>&1)
        return [pscustomobject]@{
            Output   = $output
            ExitCode = $LASTEXITCODE
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($originalLocation)) {
            Set-Location -LiteralPath $originalLocation
        }

        $env:USERPROFILE = $originalUserProfile
    }
}

function Get-StatusLineValue {
    param(
        $Output,
        [string]$Prefix
    )

    $line = @($Output | Where-Object { [string]$_ -match ("^{0}:\s+" -f [regex]::Escape($Prefix)) } | Select-Object -First 1)
    if ($line.Count -eq 0) {
        return $null
    }

    return ([string]$line[0] -replace ("^{0}:\s+" -f [regex]::Escape($Prefix)), '')
}

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

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$scratchRoot = Join-Path $RepoRoot 'tmp\harness-entry-regression'

if (Test-Path -LiteralPath $scratchRoot) {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $scratchRoot | Out-Null

$script:Checks = @()
$script:Failures = @()

$harnessPath = Join-Path $RepoRoot 'harness.ps1'

# Case 1: bootstrap from a subdirectory inside a fresh git workspace.
$caseRoot = Join-Path $scratchRoot 'bootstrap-from-git-ancestor'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$workingDirectory = Join-Path $workspaceRoot 'src\module'
New-Item -ItemType Directory -Path $userProfile,$workingDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $workspaceRoot '.git') -Force | Out-Null

$bootstrapResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
    RepoRoot = $RepoRoot
} -WorkingDirectory $workingDirectory

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'STATUS') -ne 'PASS') {
    Add-Failure 'harness.ps1 should bootstrap a fresh workspace when run from a project subdirectory'
} else {
    Add-Check 'harness.ps1 bootstraps a fresh workspace from a project subdirectory'
}

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'Mode') -ne 'bootstrap-workspace') {
    Add-Failure 'harness.ps1 should report bootstrap-workspace mode for a fresh workspace'
} else {
    Add-Check 'harness.ps1 reports bootstrap-workspace mode for a fresh workspace'
}

if ((Get-StatusLineValue -Output $bootstrapResult.Output -Prefix 'WorkspaceRoot') -ne $workspaceRoot) {
    Add-Failure 'harness.ps1 should infer the git ancestor as WorkspaceRoot during bootstrap'
} else {
    Add-Check 'harness.ps1 infers the git ancestor as WorkspaceRoot during bootstrap'
}

if (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot '.assistant') -PathType Container)) {
    Add-Failure 'harness.ps1 should create .assistant during bootstrap'
} else {
    Add-Check 'harness.ps1 creates .assistant during bootstrap'
}

# Case 2: update an existing workspace from a descendant path and repair managed drift.
$caseRoot = Join-Path $scratchRoot 'update-existing-workspace'
$userProfile = Join-Path $caseRoot 'user'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$workingDirectory = Join-Path $workspaceRoot '.assistant'
New-Item -ItemType Directory -Path $userProfile,$workspaceRoot -Force | Out-Null

$installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($installResult.ExitCode -ne 0) {
    Add-Failure 'install.ps1 should succeed before the harness update regression runs'
} else {
    $sharedMemoryProtocolLeaf = [string]::Concat(([int[]](20849,20139,35760,24518,21327,35758,46,109,100) | ForEach-Object { [char]$_ }))
    $protocolPath = @(Get-ChildItem -LiteralPath (Join-Path $workspaceRoot '.assistant') -Recurse -File | Where-Object {
            $_.Name -eq $sharedMemoryProtocolLeaf
        } | Select-Object -First 1)

    if ($protocolPath.Count -ne 1) {
        Add-Failure 'unable to resolve managed protocol file inside the installed workspace'
    } else {
        Add-Content -LiteralPath $protocolPath[0].FullName -Value "`nLOCAL-DRIFT" -Encoding utf8

        $updateResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath $harnessPath -Arguments @{
            RepoRoot = $RepoRoot
        } -WorkingDirectory $workingDirectory

        if ((Get-StatusLineValue -Output $updateResult.Output -Prefix 'STATUS') -ne 'PASS') {
            Add-Failure 'harness.ps1 should update an existing workspace when run below the workspace root'
        } else {
            Add-Check 'harness.ps1 updates an existing workspace when run below the workspace root'
        }

        if ((Get-StatusLineValue -Output $updateResult.Output -Prefix 'Mode') -ne 'update-existing-workspace') {
            Add-Failure 'harness.ps1 should report update-existing-workspace mode for an installed workspace'
        } else {
            Add-Check 'harness.ps1 reports update-existing-workspace mode for an installed workspace'
        }

        $protocolContent = Get-Content -LiteralPath $protocolPath[0].FullName -Raw -Encoding utf8
        if ($protocolContent.Contains('LOCAL-DRIFT')) {
            Add-Failure 'harness.ps1 should repair managed workspace drift through update-managed-assets'
        } else {
            Add-Check 'harness.ps1 repairs managed workspace drift through update-managed-assets'
        }
    }
}

# Case 3: running from the repo root without an explicit workspace should fail safely.
$repoRootCase = Join-Path $scratchRoot 'repo-root-guard'
$repoRootUserProfile = Join-Path $repoRootCase 'user'
New-Item -ItemType Directory -Path $repoRootUserProfile -Force | Out-Null

$guardResult = Invoke-RepoScript -UserProfile $repoRootUserProfile -ScriptPath $harnessPath -Arguments @{
    RepoRoot = $RepoRoot
} -WorkingDirectory $RepoRoot

if ((Get-StatusLineValue -Output $guardResult.Output -Prefix 'STATUS') -ne 'FAIL') {
    Add-Failure 'harness.ps1 should fail safely when run from the harness repo root without WorkspaceRoot'
} else {
    Add-Check 'harness.ps1 fails safely when run from the harness repo root without WorkspaceRoot'
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ("- {0}" -f $item)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ("- {0}" -f $failure)
}

exit 1
