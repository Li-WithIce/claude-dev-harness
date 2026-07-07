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
        $scriptSucceeded = $?
        $exitCode = if ($ScriptPath -like '*.ps1' -and $scriptSucceeded) {
            0
        } elseif ($null -ne $LASTEXITCODE) {
            $LASTEXITCODE
        } else {
            1
        }
        if ((Split-Path -Leaf $ScriptPath) -eq 'install.ps1' -and (($output -join [Environment]::NewLine) -match '(?im)^Install summary:\s*$')) {
            $exitCode = 0
        }

        return [pscustomobject]@{
            Output   = $output
            ExitCode = $exitCode
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

function Assert-GitIgnoreEntriesExactlyOnce {
    param(
        [string]$WorkspaceRoot,
        [string[]]$Entries = @(
            '# dev-harness workspace artifacts',
            '.assistant/',
            'AGENTS.md',
            '.claude'
        )
    )

    $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
    if (-not (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf)) {
        throw ("workspace .gitignore should exist after managed update: {0}" -f $gitIgnorePath)
    }

    $content = Get-Content -LiteralPath $gitIgnorePath -Raw -Encoding utf8
    $lines = [regex]::Split($content, '\r?\n') | ForEach-Object { $_.Trim() }

    foreach ($entry in $Entries) {
        $count = @($lines | Where-Object { $_ -eq $entry }).Count
        if ($count -ne 1) {
            throw (".gitignore entry `{0}` should appear exactly once after managed update; got {1}" -f $entry, $count)
        }
    }
}

function Assert-GitIgnoreOrderedEntries {
    param(
        [string]$WorkspaceRoot,
        [string[]]$Entries
    )

    $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
    if (-not (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf)) {
        throw ("workspace .gitignore should exist after managed update: {0}" -f $gitIgnorePath)
    }

    $content = Get-Content -LiteralPath $gitIgnorePath -Raw -Encoding utf8
    $lines = [regex]::Split($content, '\r?\n') | ForEach-Object { $_.Trim() }
    $cursor = 0

    foreach ($entry in $Entries) {
        $foundIndex = -1
        for ($index = $cursor; $index -lt $lines.Count; $index += 1) {
            if ($lines[$index] -eq $entry) {
                $foundIndex = $index
                break
            }
        }

        if ($foundIndex -lt 0) {
            throw (".gitignore should preserve ordered entry sequence after managed update; missing `{0}` at or after index {1}" -f $entry, $cursor)
        }

        $cursor = $foundIndex + 1
    }
}

function Assert-GitIgnoreLfOnly {
    param([string]$WorkspaceRoot)

    $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
    if (-not (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf)) {
        throw ("workspace .gitignore should exist after managed update: {0}" -f $gitIgnorePath)
    }

    $bytes = [System.IO.File]::ReadAllBytes($gitIgnorePath)
    if ($bytes -contains 13) {
        throw '.gitignore should remain LF-only after managed update'
    }
}

function Assert-CodexConfigContentEquals {
    param(
        [string]$UserProfile,
        [string]$ExpectedContent
    )

    $configPath = Join-Path (Join-Path $UserProfile '.codex') 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw ("Codex config.toml should still exist when it existed before managed update: {0}" -f $configPath)
    }

    $content = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    if ($content -ne $ExpectedContent) {
        throw 'Codex config.toml should not be modified by install/update-managed-assets'
    }
}

function Assert-CodexConfigBytesEqual {
    param(
        [string]$UserProfile,
        [byte[]]$ExpectedBytes
    )

    $configPath = Join-Path (Join-Path $UserProfile '.codex') 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw ("Codex config.toml should still exist when it existed before managed update: {0}" -f $configPath)
    }

    $actualBytes = [System.IO.File]::ReadAllBytes($configPath)
    if ($actualBytes.Length -ne $ExpectedBytes.Length) {
        throw ("Codex config.toml byte length should not change; expected {0}, got {1}" -f $ExpectedBytes.Length, $actualBytes.Length)
    }

    for ($index = 0; $index -lt $ExpectedBytes.Length; $index += 1) {
        if ($actualBytes[$index] -ne $ExpectedBytes[$index]) {
            throw ("Codex config.toml bytes should not change; first mismatch at byte {0}" -f $index)
        }
    }
}

function Assert-ManagedTextContains {
    param(
        [string]$Path,
        [string]$Needle
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("managed text file should exist: {0}" -f $Path)
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if (-not $content.Contains($Needle)) {
        throw ('{0} should contain `{1}`' -f $Path, $Needle)
    }
}

function Assert-ManagedTextNotContains {
    param(
        [string]$Path,
        [string]$Needle
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("managed text file should exist: {0}" -f $Path)
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ($content.Contains($Needle)) {
        throw ('{0} should not contain `{1}`' -f $Path, $Needle)
    }
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
        [scriptblock]$PreInstall,
        [scriptblock]$Mutator,
        [scriptblock]$PostAssert,
        [hashtable]$UpdateArguments = $null,
        [string]$WorkingDirectory = '',
        [string]$InstallVaultProfile = ''
    )

    $caseRoot = Join-Path $scratchRoot $Name
    $userProfile = Join-Path $caseRoot 'user'
    $workspaceRoot = Join-Path $caseRoot 'workspace'
    New-Item -ItemType Directory -Path $userProfile -Force | Out-Null
    New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null

    if ($null -ne $PreInstall) {
        & $PreInstall $caseRoot $userProfile $workspaceRoot
    }

    $installArguments = @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot      = $RepoRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallVaultProfile)) {
        $installArguments.VaultProfile = $InstallVaultProfile
    }

    $installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments $installArguments

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
        -InstallVaultProfile 'full' `
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
        -Name 'codex-config-is-user-owned' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -PreInstall {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $codexHome = Join-Path $UserProfile '.codex'
            New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
            $configPath = Join-Path $codexHome 'config.toml'
            $content = @(
                'model = "gpt-test"'
                'model_reasoning_effort = "xhigh"'
                'model = "gpt-duplicate"'
                'model_reasoning_effort = "low"'
                'sandbox_mode = "workspace-write"'
                ''
                '[profiles.review]'
                'model = "gpt-profile"'
                'model_reasoning_effort = "medium"'
                ''
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($configPath, $content, (New-Object System.Text.UTF8Encoding($false)))
        } `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            $expectedConfig = @(
                'model = "gpt-test"'
                'model_reasoning_effort = "xhigh"'
                'model = "gpt-duplicate"'
                'model_reasoning_effort = "low"'
                'sandbox_mode = "workspace-write"'
                ''
                '[profiles.review]'
                'model = "gpt-profile"'
                'model_reasoning_effort = "medium"'
                ''
            ) -join "`r`n"
            Assert-CodexConfigContentEquals -UserProfile $UserProfile -ExpectedContent $expectedConfig

            $codexManagedConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'managed_config.toml'
            Assert-ManagedTextContains -Path $codexManagedConfigPath -Needle 'skills\\entry-router\\SKILL.md'
            Assert-ManagedTextNotContains -Path $codexManagedConfigPath -Needle 'skills\\using-superpowers\\SKILL.md'

            $codexAgentsPath = Join-Path (Join-Path $UserProfile '.codex') 'AGENTS.md'
            Assert-ManagedTextContains -Path $codexAgentsPath -Needle 'entry-router'
            Assert-ManagedTextNotContains -Path $codexAgentsPath -Needle 'using-superpowers'

            $claudeInstructionsPath = Join-Path (Join-Path $UserProfile '.claude') 'CLAUDE.md'
            Assert-ManagedTextContains -Path $claudeInstructionsPath -Needle '/entry-router'
            Assert-ManagedTextNotContains -Path $claudeInstructionsPath -Needle '/using-superpowers'

            $workspaceAgentsPath = Join-Path $WorkspaceRoot 'AGENTS.md'
            Assert-ManagedTextContains -Path $workspaceAgentsPath -Needle 'entry-router'
            Assert-ManagedTextNotContains -Path $workspaceAgentsPath -Needle 'using-superpowers'

            $vaultAgentsPath = Join-Path $WorkspaceRoot '.assistant\entry\AGENTS.md'
            Assert-ManagedTextContains -Path $vaultAgentsPath -Needle 'entry-router'
            Assert-ManagedTextNotContains -Path $vaultAgentsPath -Needle 'using-superpowers'
        }

    Invoke-ManagedAssetsCase `
        -Name 'codex-config-legacy-managed-block-is-preserved' `
        -Scope 'All' `
        -ExpectedStatus 'WARN' `
        -PreInstall {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $codexHome = Join-Path $UserProfile '.codex'
            New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
            $configPath = Join-Path $codexHome 'config.toml'
            $content = @(
                'model = "user-model"'
                'sandbox_mode = "workspace-write"'
                ''
                '# >>> claude-dev-harness managed block >>>'
                '[managed.shared_paths]'
                'skills_root = "C:\\Users\\28796\\.codex\\skills"'
                ''
                '[[skills.config]]'
                'path = "C:\\Users\\28796\\.codex\\skills\\using-superpowers\\SKILL.md"'
                'enabled = false'
                '# <<< claude-dev-harness managed block <<<'
                ''
                '[[skills.config]]'
                'path = "C:\\user-owned\\custom-skill\\SKILL.md"'
                'enabled = true'
                ''
            ) -join "`r`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            [System.IO.File]::WriteAllBytes($configPath, $bytes)
        } `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            $expectedContent = @(
                'model = "user-model"'
                'sandbox_mode = "workspace-write"'
                ''
                '# >>> claude-dev-harness managed block >>>'
                '[managed.shared_paths]'
                'skills_root = "C:\\Users\\28796\\.codex\\skills"'
                ''
                '[[skills.config]]'
                'path = "C:\\Users\\28796\\.codex\\skills\\using-superpowers\\SKILL.md"'
                'enabled = false'
                '# <<< claude-dev-harness managed block <<<'
                ''
                '[[skills.config]]'
                'path = "C:\\user-owned\\custom-skill\\SKILL.md"'
                'enabled = true'
                ''
            ) -join "`r`n"
            $expectedBytes = [System.Text.Encoding]::UTF8.GetBytes($expectedContent)
            Assert-CodexConfigBytesEqual -UserProfile $UserProfile -ExpectedBytes $expectedBytes

            $codexManagedConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'managed_config.toml'
            Assert-ManagedTextContains -Path $codexManagedConfigPath -Needle '[[skills.config]]'
            Assert-ManagedTextContains -Path $codexManagedConfigPath -Needle 'skills\\entry-router\\SKILL.md'
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
        -Name 'entry-router-managed-assets-are-refreshed' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $managedTextFiles = @(
                (Join-Path (Join-Path $UserProfile '.claude') 'CLAUDE.md'),
                (Join-Path (Join-Path $UserProfile '.codex') 'AGENTS.md'),
                (Join-Path $WorkspaceRoot 'AGENTS.md'),
                (Join-Path (Join-Path (Join-Path $WorkspaceRoot '.assistant') 'entry') 'AGENTS.md')
            )

            foreach ($path in $managedTextFiles) {
                $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
                [System.IO.File]::WriteAllText($path, ($content -replace 'entry-router', 'using-superpowers'), (New-Object System.Text.UTF8Encoding($false)))
            }

            $codexManagedConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'managed_config.toml'
            $codexManagedConfig = Get-Content -LiteralPath $codexManagedConfigPath -Raw -Encoding utf8
            [System.IO.File]::WriteAllText($codexManagedConfigPath, ($codexManagedConfig -replace 'entry-router', 'using-superpowers'), (New-Object System.Text.UTF8Encoding($false)))

            $codexConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'config.toml'
            $codexConfig = if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
                Get-Content -LiteralPath $codexConfigPath -Raw -Encoding utf8
            } else {
                ""
            }
            if ($null -eq $codexConfig) {
                $codexConfig = ""
            }
            $codexConfig = $codexConfig.TrimEnd() + @"

[[skills.config]]
path = "C:\\user-owned\\custom-skill\\SKILL.md"
enabled = true
"@
            [System.IO.File]::WriteAllText($codexConfigPath, $codexConfig + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            $managedTextFiles = @(
                (Join-Path (Join-Path $UserProfile '.claude') 'CLAUDE.md'),
                (Join-Path (Join-Path $UserProfile '.codex') 'AGENTS.md'),
                (Join-Path $WorkspaceRoot 'AGENTS.md'),
                (Join-Path (Join-Path (Join-Path $WorkspaceRoot '.assistant') 'entry') 'AGENTS.md')
            )

            foreach ($path in $managedTextFiles) {
                $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
                if (-not $content.Contains('entry-router')) {
                    throw ("managed entry file should be refreshed to entry-router: {0}" -f $path)
                }
                if ($content.Contains('workflow` loads `using-superpowers') -or
                    $content.Contains('workflow`: load `using-superpowers') -or
                    $content.Contains('/using-superpowers')) {
                    throw ("managed entry file should not retain default using-superpowers routing: {0}" -f $path)
                }
            }

            $codexManagedConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'managed_config.toml'
            $codexManagedConfig = Get-Content -LiteralPath $codexManagedConfigPath -Raw -Encoding utf8
            if (-not $codexManagedConfig.Contains('skills\\entry-router\\SKILL.md')) {
                throw 'Codex managed_config.toml should include entry-router skill path after update'
            }
            if ($codexManagedConfig.Contains('skills\\using-superpowers\\SKILL.md')) {
                throw 'Codex managed_config.toml should remove the legacy using-superpowers skill path after update'
            }

            $codexConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'config.toml'
            $codexConfig = Get-Content -LiteralPath $codexConfigPath -Raw -Encoding utf8
            if ($codexConfig.Contains('skills\\entry-router\\SKILL.md')) {
                throw 'Codex config.toml should not contain managed entry-router skill path after update'
            }
            if ($codexConfig.Contains('skills\\using-superpowers\\SKILL.md')) {
                throw 'Codex config.toml should not contain the legacy using-superpowers skill path after update'
            }
            if (-not $codexConfig.Contains('C:\\user-owned\\custom-skill\\SKILL.md')) {
                throw 'Codex config update should preserve user-owned skills.config entries'
            }
        }

    Invoke-ManagedAssetsCase `
        -Name 'codex-config-remains-absent' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            $codexConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'config.toml'
            if (Test-Path -LiteralPath $codexConfigPath -PathType Leaf) {
                throw 'Codex config.toml should not be created by install/update-managed-assets'
            }

            $codexManagedConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'managed_config.toml'
            Assert-ManagedTextContains -Path $codexManagedConfigPath -Needle 'skills\\entry-router\\SKILL.md'
        }

    Invoke-ManagedAssetsCase `
        -Name 'decision-needed-template-drift-is-repaired' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -InstallVaultProfile 'full' `
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

    Invoke-ManagedAssetsCase `
        -Name 'workspace-gitignore-managed-entries-are-idempotent' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
            $content = Get-Content -LiteralPath $gitIgnorePath -Raw -Encoding utf8
            $updatedContent = [regex]::Replace($content, '(?m)^AGENTS\.md\r?\n?', '')
            [System.IO.File]::WriteAllText($gitIgnorePath, $updatedContent, (New-Object System.Text.UTF8Encoding($false)))
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            Assert-GitIgnoreEntriesExactlyOnce -WorkspaceRoot $WorkspaceRoot
        }

    Invoke-ManagedAssetsCase `
        -Name 'workspace-gitignore-managed-comment-is-restored' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
            $content = Get-Content -LiteralPath $gitIgnorePath -Raw -Encoding utf8
            $updatedContent = [regex]::Replace($content, '(?m)^\# dev-harness workspace artifacts\r?\n?', '')
            [System.IO.File]::WriteAllText($gitIgnorePath, $updatedContent, (New-Object System.Text.UTF8Encoding($false)))
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            Assert-GitIgnoreEntriesExactlyOnce -WorkspaceRoot $WorkspaceRoot
        }

    Invoke-ManagedAssetsCase `
        -Name 'workspace-gitignore-legacy-managed-comment-is-migrated' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
            $content = Get-Content -LiteralPath $gitIgnorePath -Raw -Encoding utf8
            $updatedContent = [regex]::Replace($content, '(?m)^\# dev-harness workspace artifacts$', '# claude-dev-harness workspace artifacts')
            [System.IO.File]::WriteAllText($gitIgnorePath, $updatedContent, (New-Object System.Text.UTF8Encoding($false)))
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            Assert-GitIgnoreEntriesExactlyOnce -WorkspaceRoot $WorkspaceRoot
            $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
            $content = Get-Content -LiteralPath $gitIgnorePath -Raw -Encoding utf8
            if ($content.Contains('# claude-dev-harness workspace artifacts')) {
                throw 'legacy .gitignore managed comment should be migrated to dev-harness'
            }
        }

    Invoke-ManagedAssetsCase `
        -Name 'workspace-gitignore-preserves-user-sentinel-rules' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
            $content = Get-Content -LiteralPath $gitIgnorePath -Raw -Encoding utf8
            $updatedContent = [regex]::Replace($content, '(?m)^AGENTS\.md\r?\n?', '')
            $updatedContent = "# user sentinel`r`nnode_modules/`r`n*.log`r`n`r`n" + $updatedContent.TrimStart([char[]]@("`r", "`n"))
            [System.IO.File]::WriteAllText($gitIgnorePath, $updatedContent, (New-Object System.Text.UTF8Encoding($false)))
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            Assert-GitIgnoreEntriesExactlyOnce -WorkspaceRoot $WorkspaceRoot
            Assert-GitIgnoreEntriesExactlyOnce -WorkspaceRoot $WorkspaceRoot -Entries @('# user sentinel', 'node_modules/', '*.log')
            Assert-GitIgnoreOrderedEntries -WorkspaceRoot $WorkspaceRoot -Entries @('# user sentinel', 'node_modules/', '*.log', '# dev-harness workspace artifacts', '.assistant/', 'AGENTS.md')
        }

    Invoke-ManagedAssetsCase `
        -Name 'workspace-gitignore-preserves-lf-only-newlines' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $gitIgnorePath = Join-Path $WorkspaceRoot '.gitignore'
            $content = Get-Content -LiteralPath $gitIgnorePath -Raw -Encoding utf8
            $updatedContent = [regex]::Replace($content, '(?m)^AGENTS\.md\r?\n?', '')
            $updatedContent = [regex]::Replace($updatedContent, "`r`n", "`n")
            [System.IO.File]::WriteAllText($gitIgnorePath, $updatedContent, (New-Object System.Text.UTF8Encoding($false)))
        } `
        -PostAssert {
            param($CaseRoot, $UserProfile, $WorkspaceRoot, $Result)

            Assert-GitIgnoreEntriesExactlyOnce -WorkspaceRoot $WorkspaceRoot
            Assert-GitIgnoreLfOnly -WorkspaceRoot $WorkspaceRoot
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
