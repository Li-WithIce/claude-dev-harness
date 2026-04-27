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

function Add-Warning {
    param([string]$Message)

    $script:Warnings += $Message
}

function Remove-DirectoryWithRetry {
    param(
        [string]$Path,
        [int]$MaxAttempts = 10,
        [int]$DelayMilliseconds = 200
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt += 1) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Add-Warning ("cleanup failed for scratch root {0}: {1}" -f $Path, $lastError.Exception.Message)
        return $false
    }

    return $true
}

function Invoke-ManagedAssetsCase {
    param(
        [string]$Name,
        [string]$Scope,
        [string]$ExpectedStatus,
        [scriptblock]$Mutator,
        [scriptblock]$PostAssert,
        [hashtable]$UpdateArguments = $null,
        [string]$WorkingDirectory = ''
    )

    $caseRoot = Join-Path $scratchRoot $Name
    $userProfile = Join-Path $caseRoot 'user'
    $workspaceRoot = Join-Path $caseRoot 'workspace'
    New-Item -ItemType Directory -Path $userProfile -Force | Out-Null
    New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null

    $installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot      = $RepoRoot
    }

    if ($installResult.ExitCode -ne 0) {
        $script:Failures += [pscustomobject]@{
            Name   = $Name
            Reason = 'install.ps1 failed during setup'
            Output = ($installResult.Output -join [Environment]::NewLine)
        }
        return
    }

    if ($null -ne $Mutator) {
        & $Mutator $caseRoot $userProfile $workspaceRoot
    }

    $resolvedArguments = if ($null -ne $UpdateArguments) {
        $UpdateArguments
    } else {
        @{
            WorkspaceRoot = $workspaceRoot
            RepoRoot      = $RepoRoot
            Scope         = $Scope
        }
    }
    $resolvedWorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        ''
    } else {
        $WorkingDirectory.Replace('{WORKSPACE_ROOT}', $workspaceRoot).Replace('{CASE_ROOT}', $caseRoot)
    }
    $result = Invoke-RepoScript `
        -UserProfile $userProfile `
        -ScriptPath (Join-Path $RepoRoot 'scripts\update-managed-assets.ps1') `
        -Arguments $resolvedArguments `
        -WorkingDirectory $resolvedWorkingDirectory

    $actualStatus = Get-StatusLineValue -Output $result.Output -Prefix 'STATUS'
    if ($actualStatus -ne $ExpectedStatus) {
        $script:Failures += [pscustomobject]@{
            Name   = $Name
            Reason = "expected status=$ExpectedStatus; got status=$actualStatus"
            Output = ($result.Output -join [Environment]::NewLine)
        }
        return
    }

    if ($null -ne $PostAssert) {
        try {
            & $PostAssert $caseRoot $userProfile $workspaceRoot $result
        } catch {
            $script:Failures += [pscustomobject]@{
                Name   = $Name
                Reason = $_.Exception.Message
                Output = ($result.Output -join [Environment]::NewLine)
            }
            return
        }
    }

    $script:Checks += [pscustomobject]@{
        Name   = $Name
        Status = $actualStatus
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('update-managed-assets-regression-' + [guid]::NewGuid().ToString('N'))

$script:Checks = @()
$script:Warnings = @()
$script:Failures = @()

try {
    New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

    Invoke-ManagedAssetsCase `
        -Name 'workflow-protocol-drift-is-repaired' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $protocolLeafName = -join (@(20849, 20139, 35760, 24518, 21327, 35758, 46, 109, 100) | ForEach-Object { [char]$_ })
            $protocolPath = @(Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot '.assistant') -Recurse -File | Where-Object {
                    $_.Name -eq $protocolLeafName
                } | Select-Object -First 1)
            if ($protocolPath.Count -ne 1) {
                throw 'unable to resolve managed workflow protocol file in workspace vault'
            }

            Add-Content -LiteralPath $protocolPath[0].FullName -Value "`nDRIFT-LINE" -Encoding utf8
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            $protocolLeafName = -join (@(20849, 20139, 35760, 24518, 21327, 35758, 46, 109, 100) | ForEach-Object { [char]$_ })
            $protocolPath = @(Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot '.assistant') -Recurse -File | Where-Object {
                    $_.Name -eq $protocolLeafName
                } | Select-Object -First 1)
            if ($protocolPath.Count -ne 1) {
                throw 'unable to resolve managed workflow protocol file in workspace vault after update'
            }

            $content = Get-Content -LiteralPath $protocolPath[0].FullName -Raw -Encoding utf8
            if ($content.Contains('DRIFT-LINE')) {
                throw 'workflow protocol drift should be repaired by Scope=All'
            }
        }

    Invoke-ManagedAssetsCase `
        -Name 'cwd-autodetect-pass' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -WorkingDirectory '{WORKSPACE_ROOT}\.assistant' `
        -UpdateArguments @{ Scope = 'All' } `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            $status = Get-StatusLineValue -Output $Result.Output -Prefix 'STATUS'
            if ($status -ne 'PASS') {
                throw 'update-managed-assets should pass when it infers WorkspaceRoot from the current working directory'
            }
        }

    Invoke-ManagedAssetsCase `
        -Name 'decision-needed-template-drift-is-repaired' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $templateLeafName = -join (@(20915, 31574, 38656, 27714, 27169, 26495, 46, 109, 100) | ForEach-Object { [char]$_ })
            $templatePath = @(Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot '.assistant') -Recurse -File | Where-Object {
                    $_.Name -eq $templateLeafName
                } | Select-Object -First 1)
            if ($templatePath.Count -ne 1) {
                throw 'unable to resolve decision-needed template in workspace vault'
            }

            Add-Content -LiteralPath $templatePath[0].FullName -Value "`nDRIFT-LINE" -Encoding utf8
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            $templateLeafName = -join (@(20915, 31574, 38656, 27714, 27169, 26495, 46, 109, 100) | ForEach-Object { [char]$_ })
            $templatePath = @(Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot '.assistant') -Recurse -File | Where-Object {
                    $_.Name -eq $templateLeafName
                } | Select-Object -First 1)
            if ($templatePath.Count -ne 1) {
                throw 'unable to resolve decision-needed template in workspace vault after update'
            }

            $content = Get-Content -LiteralPath $templatePath[0].FullName -Raw -Encoding utf8
            if ($content.Contains('DRIFT-LINE')) {
                throw 'decision-needed template drift should be repaired by Scope=All'
            }
        }
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot | Out-Null
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ('- {0}: {1}' -f $item.Name, $item.Status)
    }
}

Write-Output ''
Write-Output 'Warnings:'
if ($script:Warnings.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($warning in $script:Warnings) {
        Write-Output ('- {0}' -f $warning)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ('- {0}: {1}' -f $failure.Name, $failure.Reason)
    if (-not [string]::IsNullOrWhiteSpace($failure.Output)) {
        Write-Output $failure.Output
    }
}

exit 1
