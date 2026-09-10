[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [ValidateSet('core','governed','full')][string]$Preset = 'full'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$installScript = Join-Path $RepoRoot 'install.ps1'
$verifyScript = Join-Path $RepoRoot 'tests\verify-installation.ps1'
$uninstallScript = Join-Path $RepoRoot 'uninstall.ps1'
foreach ($scriptPath in @($installScript, $verifyScript, $uninstallScript)) {
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required smoke script is missing: $scriptPath"
    }
}

$powerShellPath = (Get-Process -Id $PID).Path
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dev-harness-install-smoke-{0}' -f [guid]::NewGuid().ToString('N'))
$workspaceRoot = Join-Path $scratchRoot 'workspace'
$userProfileRoot = Join-Path $scratchRoot 'user'
$originalUserProfile = $env:USERPROFILE

$installExit = $null
$verifyExit = $null
$updateExit = $null
$secondVerifyExit = $null
$uninstallExit = $null
$cleanupExit = 0
$executionError = $null
$uninstallError = $null
$cleanupError = $null
$installSucceeded = $false
$firstVerifySucceeded = $false
$updateSucceeded = $false

try {
    New-Item -ItemType Directory -Path $workspaceRoot, $userProfileRoot -Force | Out-Null
    $env:USERPROFILE = $userProfileRoot

    Write-Output 'Smoke stage: install'
    & $powerShellPath -NoLogo -NoProfile -NonInteractive -File $installScript -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -Preset $Preset
    $installExit = $LASTEXITCODE

    if ($installExit -eq 0) {
        $installSucceeded = $true
        Write-Output 'Smoke stage: verify'
        & $powerShellPath -NoLogo -NoProfile -NonInteractive -File $verifyScript -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -UserProfileRoot $userProfileRoot -Scope All
        $verifyExit = $LASTEXITCODE
        if ($verifyExit -eq 0) {
            $firstVerifySucceeded = $true
            Write-Output 'Smoke stage: update'
            & $powerShellPath -NoLogo -NoProfile -NonInteractive -File $installScript -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot
            $updateExit = $LASTEXITCODE
            if ($updateExit -eq 0) {
                $updateSucceeded = $true
                Write-Output 'Smoke stage: second verify'
                & $powerShellPath -NoLogo -NoProfile -NonInteractive -File $verifyScript -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot -UserProfileRoot $userProfileRoot -Scope All
                $secondVerifyExit = $LASTEXITCODE
            }
        }
    }
} catch {
    $executionError = $_.Exception.Message
    if ($null -eq $installExit) {
        $installExit = 1
    } elseif ($installSucceeded -and $null -eq $verifyExit) {
        $verifyExit = 1
    } elseif ($firstVerifySucceeded -and $null -eq $updateExit) {
        $updateExit = 1
    } elseif ($updateSucceeded -and $null -eq $secondVerifyExit) {
        $secondVerifyExit = 1
    }
} finally {
    try {
        if ($installSucceeded) {
            Write-Output 'Smoke stage: uninstall'
            & $powerShellPath -NoLogo -NoProfile -NonInteractive -File $uninstallScript -WorkspaceRoot $workspaceRoot -RepoRoot $RepoRoot
            $uninstallExit = $LASTEXITCODE
        }
    } catch {
        $uninstallExit = 1
        $uninstallError = $_.Exception.Message
    } finally {
        if ($null -eq $originalUserProfile) {
            Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue
        } else {
            $env:USERPROFILE = $originalUserProfile
        }

        try {
            Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction Stop
        } catch {
            $cleanupExit = 1
            $cleanupError = $_.Exception.Message
        }
    }
}

Write-Output 'Smoke summary:'
Write-Output ('- install_exit: {0}' -f $(if ($null -eq $installExit) { 'SKIP' } else { $installExit }))
Write-Output ('- verify_exit: {0}' -f $(if ($null -eq $verifyExit) { 'SKIP' } else { $verifyExit }))
Write-Output ('- update_exit: {0}' -f $(if ($null -eq $updateExit) { 'SKIP' } else { $updateExit }))
Write-Output ('- second_verify_exit: {0}' -f $(if ($null -eq $secondVerifyExit) { 'SKIP' } else { $secondVerifyExit }))
Write-Output ('- uninstall_exit: {0}' -f $(if ($null -eq $uninstallExit) { 'SKIP' } else { $uninstallExit }))
Write-Output ('- cleanup_exit: {0}' -f $cleanupExit)
foreach ($message in @($executionError, $uninstallError, $cleanupError)) {
    if (-not [string]::IsNullOrWhiteSpace($message)) {
        Write-Output ('[ERROR] {0}' -f $message)
    }
}

foreach ($exitCode in @($installExit, $verifyExit, $updateExit, $secondVerifyExit, $uninstallExit, $cleanupExit)) {
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        exit $exitCode
    }
}
exit 0
