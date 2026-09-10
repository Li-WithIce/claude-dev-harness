[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

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
        $script:Warnings += ("cleanup failed for scratch root {0}: {1}" -f $Path, $lastError.Exception.Message)
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

function New-WrapperContractFixture {
    param(
        [string]$Name,
        [string]$InstallScript,
        [string]$VerifyScript
    )

    $caseRoot = Join-Path $scratchRoot ("wrapper-contract-{0}" -f $Name)
    $fixtureRepoRoot = Join-Path $caseRoot 'repo'
    $fixtureScriptsRoot = Join-Path $fixtureRepoRoot 'scripts'
    $fixtureTestsRoot = Join-Path $fixtureRepoRoot 'tests'
    $userProfile = Join-Path $caseRoot 'user'
    $workspaceRoot = Join-Path $caseRoot 'workspace'
    foreach ($path in @($fixtureScriptsRoot, $fixtureTestsRoot, $userProfile, (Join-Path $workspaceRoot '.assistant'))) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\update-managed-assets.ps1') -Destination (Join-Path $fixtureScriptsRoot 'update-managed-assets.ps1') -Force
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepoRoot 'install.ps1'), $InstallScript, $encoding)
    [System.IO.File]::WriteAllText((Join-Path $fixtureTestsRoot 'verify-installation.ps1'), $VerifyScript, $encoding)

    return [pscustomobject]@{
        RepoRoot      = $fixtureRepoRoot
        UserProfile   = $userProfile
        WorkspaceRoot = $workspaceRoot
    }
}

function Invoke-WrapperContractCheck {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        & $Action
        $script:Checks += [pscustomobject]@{
            Name   = $Name
            Status = 'PASS'
        }
    } catch {
        $script:Failures += [pscustomobject]@{
            Name   = $Name
            Reason = $_.Exception.Message
            Output = ''
        }
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

    Invoke-WrapperContractCheck -Name 'legacy-rebaseline-plan-is-forwarded-without-verify' -Action {
        $fixture = New-WrapperContractFixture `
            -Name 'plan' `
            -InstallScript @'
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$RepoRoot,
    [switch]$RebaselineLegacyInstallState,
    [string]$ExpectedRebaselinePlanDigest = ''
)
if (-not $RebaselineLegacyInstallState.IsPresent -or -not [string]::IsNullOrWhiteSpace($ExpectedRebaselinePlanDigest)) {
    Write-Output 'STATUS: FAIL'
    exit 2
}
Write-Output 'STATUS: REBASELINE_PLAN_REQUIRED'
Write-Output 'RebaselinePlanDigest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
Write-Output 'SourceManifestCount: 3'
Write-Output 'TargetCount: 7'
return
'@ `
            -VerifyScript @'
param([string]$WorkspaceRoot, [string]$RepoRoot, [string]$Scope)
[System.IO.File]::WriteAllText((Join-Path $RepoRoot 'verify-called.txt'), 'called')
Write-Output 'STATUS: PASS'
exit 0
'@
        $result = Invoke-RepoScript -UserProfile $fixture.UserProfile -ScriptPath (Join-Path $fixture.RepoRoot 'scripts\update-managed-assets.ps1') -Arguments @{
            WorkspaceRoot               = $fixture.WorkspaceRoot
            RepoRoot                    = $fixture.RepoRoot
            Scope                       = 'All'
            RebaselineLegacyInstallState = $true
        }
        $outputText = $result.Output -join [Environment]::NewLine
        if ($result.ExitCode -eq 0 -or (Get-StatusLineValue -Output $result.Output -Prefix 'STATUS') -ne 'REBASELINE_PLAN_REQUIRED') {
            throw 'plan-only rebaseline should preserve REBASELINE_PLAN_REQUIRED and return nonzero'
        }
        foreach ($expectedLine in @(
                'RebaselinePlanDigest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'SourceManifestCount: 3',
                'TargetCount: 7'
            )) {
            if (-not $outputText.Contains($expectedLine)) {
                throw ("plan-only wrapper output should preserve {0}" -f $expectedLine)
            }
        }
        if (Test-Path -LiteralPath (Join-Path $fixture.RepoRoot 'verify-called.txt')) {
            throw 'plan-only rebaseline must not run verify-installation.ps1'
        }
    }

    Invoke-WrapperContractCheck -Name 'legacy-rebaseline-apply-rejects-skipverify-before-install' -Action {
        $fixture = New-WrapperContractFixture `
            -Name 'skipverify' `
            -InstallScript @'
param([string]$WorkspaceRoot, [string]$RepoRoot, [switch]$RebaselineLegacyInstallState, [string]$ExpectedRebaselinePlanDigest = '')
[System.IO.File]::WriteAllText((Join-Path $RepoRoot 'install-called.txt'), 'called')
Write-Output 'Install summary:'
exit 0
'@ `
            -VerifyScript @'
param([string]$WorkspaceRoot, [string]$RepoRoot, [string]$Scope)
[System.IO.File]::WriteAllText((Join-Path $RepoRoot 'verify-called.txt'), 'called')
Write-Output 'STATUS: PASS'
exit 0
'@
        $result = Invoke-RepoScript -UserProfile $fixture.UserProfile -ScriptPath (Join-Path $fixture.RepoRoot 'scripts\update-managed-assets.ps1') -Arguments @{
            WorkspaceRoot                = $fixture.WorkspaceRoot
            RepoRoot                     = $fixture.RepoRoot
            Scope                        = 'All'
            RebaselineLegacyInstallState = $true
            ExpectedRebaselinePlanDigest = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            SkipVerify                   = $true
        }
        $outputText = $result.Output -join [Environment]::NewLine
        if ($result.ExitCode -eq 0 -or (Get-StatusLineValue -Output $result.Output -Prefix 'STATUS') -ne 'FAIL') {
            throw 'digest-bound apply with SkipVerify should fail immediately'
        }
        if ($outputText -notmatch 'SkipVerify cannot be used') {
            throw 'SkipVerify rejection should explain the forbidden combination'
        }
        if (Test-Path -LiteralPath (Join-Path $fixture.RepoRoot 'install-called.txt')) {
            throw 'SkipVerify rejection must happen before install.ps1'
        }
    }

    Invoke-WrapperContractCheck -Name 'legacy-rebaseline-verify-failure-is-committed-unverified' -Action {
        $fixture = New-WrapperContractFixture `
            -Name 'committed-unverified' `
            -InstallScript @'
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$RepoRoot,
    [switch]$RebaselineLegacyInstallState,
    [string]$ExpectedRebaselinePlanDigest = ''
)
if (-not $RebaselineLegacyInstallState.IsPresent -or $ExpectedRebaselinePlanDigest -cne 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc') {
    Write-Output 'STATUS: FAIL'
    exit 2
}
[System.IO.File]::WriteAllText((Join-Path $RepoRoot 'install-called.txt'), 'called')
Write-Output 'STATUS: REBASELINE_COMMITTED'
Write-Output 'Install summary:'
exit 0
'@ `
            -VerifyScript @'
param([string]$WorkspaceRoot, [string]$RepoRoot, [string]$Scope)
[System.IO.File]::WriteAllText((Join-Path $RepoRoot 'verify-called.txt'), 'called')
Write-Output 'STATUS: WARN'
Write-Output 'Warnings:'
Write-Output '- synthetic verifier failure'
exit 1
'@
        $result = Invoke-RepoScript -UserProfile $fixture.UserProfile -ScriptPath (Join-Path $fixture.RepoRoot 'scripts\update-managed-assets.ps1') -Arguments @{
            WorkspaceRoot                = $fixture.WorkspaceRoot
            RepoRoot                     = $fixture.RepoRoot
            Scope                        = 'All'
            RebaselineLegacyInstallState = $true
            ExpectedRebaselinePlanDigest = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        }
        $outputText = $result.Output -join [Environment]::NewLine
        if ($result.ExitCode -eq 0 -or (Get-StatusLineValue -Output $result.Output -Prefix 'STATUS') -ne 'UPDATE_COMMITTED_UNVERIFIED') {
            throw 'verify failure after digest-bound apply should return UPDATE_COMMITTED_UNVERIFIED and nonzero'
        }
        foreach ($marker in @('install-called.txt', 'verify-called.txt')) {
            if (-not (Test-Path -LiteralPath (Join-Path $fixture.RepoRoot $marker) -PathType Leaf)) {
                throw ("committed-unverified case should run through {0}" -f $marker)
            }
        }
        if ($outputText -notmatch 'Rollback: not performed' -or
            $outputText -notmatch 'verify-installation\.ps1, update-managed-assets\.ps1, or uninstall\.ps1') {
            throw 'committed-unverified output should state no rollback and the supported retry paths'
        }
    }

    Invoke-WrapperContractCheck -Name 'legacy-rebaseline-postcommit-install-failure-preserves-commit-state' -Action {
        $fixture = New-WrapperContractFixture `
            -Name 'postcommit-install-failure' `
            -InstallScript @'
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$RepoRoot,
    [switch]$RebaselineLegacyInstallState,
    [string]$ExpectedRebaselinePlanDigest = ''
)
if (-not $RebaselineLegacyInstallState.IsPresent -or $ExpectedRebaselinePlanDigest -cne 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd') {
    throw 'unexpected rebaseline arguments'
}
Write-Output 'STATUS: REBASELINE_COMMITTED'
Write-Output 'RebaselinePlanDigest: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
throw 'synthetic postcommit install failure'
'@ `
            -VerifyScript @'
param([string]$WorkspaceRoot, [string]$RepoRoot, [string]$Scope)
[System.IO.File]::WriteAllText((Join-Path $RepoRoot 'verify-called.txt'), 'called')
Write-Output 'STATUS: PASS'
exit 0
'@
        $result = Invoke-RepoScript -UserProfile $fixture.UserProfile -ScriptPath (Join-Path $fixture.RepoRoot 'scripts\update-managed-assets.ps1') -Arguments @{
            WorkspaceRoot                = $fixture.WorkspaceRoot
            RepoRoot                     = $fixture.RepoRoot
            Scope                        = 'All'
            RebaselineLegacyInstallState = $true
            ExpectedRebaselinePlanDigest = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
        }
        $outputText = $result.Output -join [Environment]::NewLine
        if ($result.ExitCode -eq 0 -or (Get-StatusLineValue -Output $result.Output -Prefix 'STATUS') -ne 'UPDATE_COMMITTED_UNVERIFIED') {
            throw 'postcommit install failure should return UPDATE_COMMITTED_UNVERIFIED and nonzero'
        }
        if ($outputText -notmatch 'synthetic postcommit install failure' -or
            $outputText -notmatch 'Rollback: not performed') {
            throw 'postcommit install failure should preserve its error and no-rollback disclosure'
        }
        if (Test-Path -LiteralPath (Join-Path $fixture.RepoRoot 'verify-called.txt')) {
            throw 'postcommit install failure should not run verification after the install step failed'
        }
    }

    Invoke-WrapperContractCheck -Name 'retired-managed-vault-template-keeps-exact-uninstall-lineage' -Action {
        $caseRoot = Join-Path $scratchRoot 'retired-managed-vault-template'
        $fixtureRepoRoot = Join-Path $caseRoot 'repo'
        $userProfile = Join-Path $caseRoot 'user'
        $workspaceRoot = Join-Path $caseRoot 'workspace'
        New-Item -ItemType Directory -Path $fixtureRepoRoot,$userProfile,$workspaceRoot -Force | Out-Null
        foreach ($fixtureSource in @('install.ps1','uninstall.ps1','scripts','skills','vault-template','agent-configs','runtime-hooks','modules','schemas','module-manifest-catalog.json')) {
            Copy-Item `
                -LiteralPath (Join-Path $RepoRoot $fixtureSource) `
                -Destination (Join-Path $fixtureRepoRoot $fixtureSource) `
                -Recurse `
                -Force
        }

        $fixtureClaudeHome = Join-Path $userProfile '.claude'
        $fixtureClaudeSettingsPath = Join-Path $fixtureClaudeHome 'settings.json'
        $fixtureHookTemplatePath = Join-Path $fixtureRepoRoot 'agent-configs\claude\settings.local.shared.json.template'
        $fixturePostToolSourcePath = Join-Path $fixtureRepoRoot 'runtime-hooks\claude\posttooluse.js'
        $fixtureProfilePath = Join-Path $fixtureRepoRoot 'modules\distribution\profiles\full.json'
        $livePostToolPath = Join-Path $fixtureClaudeHome 'hooks-memory\posttooluse.js'
        $legacyPostToolCommand = 'node "{0}"' -f $livePostToolPath
        $thirdPartyPostToolCommand = 'third-party-posttool.cmd'
        $currentHookTemplateRaw = Get-Content -LiteralPath $fixtureHookTemplatePath -Raw -Encoding utf8
        $legacyHookTemplate = $currentHookTemplateRaw | ConvertFrom-Json
        $legacyHookTemplate | Add-Member -NotePropertyName PostToolUse -NotePropertyValue @(
            [ordered]@{
                matcher = 'Write|Edit|MultiEdit'
                hooks = @([ordered]@{ type = 'command'; command = 'node "{CLAUDE_HOME}\hooks-memory\posttooluse.js"'; timeout = 10 })
            }
        ) -Force
        [System.IO.File]::WriteAllText(
            $fixtureHookTemplatePath,
            ($legacyHookTemplate | ConvertTo-Json -Depth 20),
            (New-Object System.Text.UTF8Encoding($false))
        )
        [System.IO.File]::WriteAllText(
            $fixturePostToolSourcePath,
            'process.stdin.resume(); process.stdout.write("{}\n");',
            (New-Object System.Text.UTF8Encoding($false))
        )
        # Seed an older centrally authorized inventory for the retirement transition.
        $currentProfileRaw = Get-Content -LiteralPath $fixtureProfilePath -Raw -Encoding utf8
        $legacyProfile = $currentProfileRaw | ConvertFrom-Json -AsHashtable
        $legacyProfile.asset_allowlist += [ordered]@{
            id = 'fixture-retired-posttooluse'
            kind = 'hook'
            origin = 'bootstrap'
            module_id = 'distribution'
            source = 'runtime-hooks/claude/posttooluse.js'
            target = 'posttooluse.js'
            ownership = 'managed'
            files = @('runtime-hooks/claude/posttooluse.js')
        }
        New-Item -ItemType Directory -Path $fixtureClaudeHome -Force | Out-Null
        $thirdPartyBaseline = [ordered]@{
            hooks = [ordered]@{
                PostToolUse = @(
                    [ordered]@{
                        matcher = 'Write'
                        hooks = @([ordered]@{ type = 'command'; command = $thirdPartyPostToolCommand })
                    }
                )
            }
        }
        [System.IO.File]::WriteAllText(
            $fixtureClaudeSettingsPath,
            ($thirdPartyBaseline | ConvertTo-Json -Depth 20),
            (New-Object System.Text.UTF8Encoding($false))
        )
        $readFixtureHookCommands = {
            $settings = Get-Content -LiteralPath $fixtureClaudeSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
            return @($settings.hooks.PSObject.Properties | ForEach-Object {
                    foreach ($section in @($_.Value)) {
                        foreach ($hook in @($section.hooks)) {
                            [string]$hook.command
                        }
                    }
                })
        }

        $templateRelativePath = '模板\决策需求模板.md'
        $fixtureTemplatePath = Join-Path (Join-Path $fixtureRepoRoot 'vault-template') $templateRelativePath
        $retiredContent = "obsolete managed decision template`n"
        [System.IO.File]::WriteAllText($fixtureTemplatePath, $retiredContent, (New-Object System.Text.UTF8Encoding($false)))
        $retiredTarget = $templateRelativePath.Replace('\','/')
        $retiredSource = 'vault-template/' + $retiredTarget
        $legacyProfile.asset_allowlist += [ordered]@{
            id = 'fixture-retired-decision-template'
            kind = 'vault'
            origin = 'bootstrap'
            module_id = 'distribution'
            source = $retiredSource
            target = $retiredTarget
            ownership = 'managed'
            files = @($retiredSource)
        }
        [System.IO.File]::WriteAllText($fixtureProfilePath,($legacyProfile | ConvertTo-Json -Depth 30),(New-Object System.Text.UTF8Encoding($false)))

        $initialInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $fixtureRepoRoot 'install.ps1') -Arguments @{
            WorkspaceRoot = $workspaceRoot
            RepoRoot      = $fixtureRepoRoot
            VaultProfile  = 'full'
        }
        $liveTemplatePath = Join-Path (Join-Path $workspaceRoot '.assistant') $templateRelativePath
        if ($initialInstall.ExitCode -ne 0 -or
            (Get-Content -LiteralPath $liveTemplatePath -Raw -Encoding utf8) -cne $retiredContent -or
            -not (Test-Path -LiteralPath $livePostToolPath -PathType Leaf)) {
            throw 'fixture setup should install the formerly managed decision template and PostToolUse hook'
        }
        $initialHookCommands = @(& $readFixtureHookCommands)
        if (@($initialHookCommands | Where-Object { $_ -ceq $legacyPostToolCommand }).Count -ne 1 -or
            @($initialHookCommands | Where-Object { $_ -ceq $thirdPartyPostToolCommand }).Count -ne 1) {
            throw 'fixture setup should contain one legacy Harness and one third-party PostToolUse command'
        }

        Remove-Item -LiteralPath $fixtureTemplatePath -Force
        Remove-Item -LiteralPath $fixturePostToolSourcePath -Force
        [System.IO.File]::WriteAllText($fixtureProfilePath,$currentProfileRaw,(New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText(
            $fixtureHookTemplatePath,
            $currentHookTemplateRaw,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $updateResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $fixtureRepoRoot 'scripts\update-managed-assets.ps1') -Arguments @{
            WorkspaceRoot = $workspaceRoot
            RepoRoot      = $fixtureRepoRoot
            Scope         = 'All'
            SkipVerify    = $true
        }
        if ($updateResult.ExitCode -ne 0 -or
            (Get-StatusLineValue -Output $updateResult.Output -Prefix 'STATUS') -ne 'PASS' -or
            (Test-Path -LiteralPath $liveTemplatePath)) {
            throw 'managed update should tombstone the retired owned template'
        }
        $updatedHookCommands = @(& $readFixtureHookCommands)
        if ((Test-Path -LiteralPath $livePostToolPath) -or
            @($updatedHookCommands | Where-Object { $_ -ceq $legacyPostToolCommand }).Count -ne 0 -or
            @($updatedHookCommands | Where-Object { $_ -ceq $thirdPartyPostToolCommand }).Count -ne 1) {
            throw 'managed update should retire only the Harness PostToolUse command/file and preserve third-party PostToolUse'
        }

        $registryPath = Join-Path $userProfile '.dev-harness\install-registry.json'
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json
        $workspaceEntry = @($registry.workspaces.PSObject.Properties | Select-Object -First 1)[0].Value
        $latestManifestPath = [string]@($workspaceEntry.manifests)[-1]
        $latestManifest = Get-Content -LiteralPath $latestManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $tombstoneRecords = @($latestManifest.backups | Where-Object {
                (Get-NormalizedPath -Path $_.path) -eq (Get-NormalizedPath -Path $liveTemplatePath)
            })
        if ($tombstoneRecords.Count -ne 1 -or
            -not [bool]$tombstoneRecords[0].existed -or
            [string]$tombstoneRecords[0].item_type -ne 'file' -or
            [string]$tombstoneRecords[0].ownership -ne 'managed' -or
            [string]$tombstoneRecords[0].expected_postimage.item_type -ne 'missing' -or
            (Get-Content -LiteralPath $tombstoneRecords[0].backup_path -Raw -Encoding utf8) -cne $retiredContent) {
            throw 'retired template transition must be committed as exact file-to-missing ownership evidence'
        }

        $uninstallResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $fixtureRepoRoot 'uninstall.ps1') -Arguments @{
            WorkspaceRoot = $workspaceRoot
            RepoRoot      = $fixtureRepoRoot
        }
        $uninstalledHookCommands = @(& $readFixtureHookCommands)
        if ($uninstallResult.ExitCode -ne 0 -or
            (Test-Path -LiteralPath $liveTemplatePath) -or
            (Test-Path -LiteralPath $livePostToolPath) -or
            @($uninstalledHookCommands | Where-Object { $_ -ceq $legacyPostToolCommand }).Count -ne 0 -or
            @($uninstalledHookCommands | Where-Object { $_ -ceq $thirdPartyPostToolCommand }).Count -ne 1) {
            throw 'full uninstall should restore the original template and third-party hook preimage without retired Harness PostToolUse'
        }

        $unownedUserProfile = Join-Path $caseRoot 'unowned-user'
        $unownedWorkspaceRoot = Join-Path $caseRoot 'unowned-workspace'
        $unownedLivePath = Join-Path (Join-Path $unownedWorkspaceRoot '.assistant') $templateRelativePath
        New-Item -ItemType Directory -Path $unownedUserProfile,(Split-Path -Parent $unownedLivePath) -Force | Out-Null
        $unownedContent = "user-owned decision notes`n"
        [System.IO.File]::WriteAllText($unownedLivePath, $unownedContent, (New-Object System.Text.UTF8Encoding($false)))
        $unownedInstall = Invoke-RepoScript -UserProfile $unownedUserProfile -ScriptPath (Join-Path $fixtureRepoRoot 'install.ps1') -Arguments @{
            WorkspaceRoot = $unownedWorkspaceRoot
            RepoRoot      = $fixtureRepoRoot
            VaultProfile  = 'full'
        }
        if ($unownedInstall.ExitCode -ne 0 -or
            (Get-Content -LiteralPath $unownedLivePath -Raw -Encoding utf8) -cne $unownedContent) {
            throw 'an unregistered same-path file must remain user-owned and untouched'
        }
    }

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
            if (Test-Path -LiteralPath $codexManagedConfigPath) {
                throw 'install/update-managed-assets should not create Codex administrator policy'
            }

            $codexAgentsPath = Join-Path (Join-Path $UserProfile '.codex') 'AGENTS.md'
            Assert-ManagedTextContains -Path $codexAgentsPath -Needle 'Read the resolved workspace''s `AGENTS.md` first'
            Assert-ManagedTextNotContains -Path $codexAgentsPath -Needle 'entry-router'
            Assert-ManagedTextNotContains -Path $codexAgentsPath -Needle 'using-superpowers'

            $claudeInstructionsPath = Join-Path (Join-Path $UserProfile '.claude') 'CLAUDE.md'
            Assert-ManagedTextContains -Path $claudeInstructionsPath -Needle 'v2-only-with-new-work-admission'
            Assert-ManagedTextContains -Path $claudeInstructionsPath -Needle '`protocol_default`: `auto`'
            Assert-ManagedTextNotContains -Path $claudeInstructionsPath -Needle '/using-superpowers'

            $workspaceAgentsPath = Join-Path $WorkspaceRoot 'AGENTS.md'
            Assert-ManagedTextContains -Path $workspaceAgentsPath -Needle 'v2-only-with-new-work-admission'
            Assert-ManagedTextNotContains -Path $workspaceAgentsPath -Needle 'using-superpowers'

            $vaultAgentsPath = Join-Path $WorkspaceRoot '.assistant\entry\AGENTS.md'
            if (Test-Path -LiteralPath $vaultAgentsPath) { throw 'current installation must not materialize the retired lifecycle shim' }
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
            if (Test-Path -LiteralPath $codexManagedConfigPath) {
                throw 'legacy user config migration should not create Codex administrator policy'
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
        -Name 'v2-admission-managed-assets-are-refreshed' `
        -Scope 'All' `
        -ExpectedStatus 'PASS' `
        -Mutator {
            param($CaseRoot, $UserProfile, $WorkspaceRoot)

            $managedAdmissionTextFiles = @(
                (Join-Path (Join-Path $UserProfile '.claude') 'CLAUDE.md'),
                (Join-Path $WorkspaceRoot 'AGENTS.md')
            )

            foreach ($path in $managedAdmissionTextFiles) {
                $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
                if (-not $content.Contains('v2-only-with-new-work-admission')) { throw 'managed fixture is missing its current v2 admission contract' }
                [System.IO.File]::WriteAllText($path, ($content -replace 'v2-only-with-new-work-admission', 'stale-v1-admission'), (New-Object System.Text.UTF8Encoding($false)))
            }

            $codexAgentsPath = Join-Path (Join-Path $UserProfile '.codex') 'AGENTS.md'
            $codexAgents = Get-Content -LiteralPath $codexAgentsPath -Raw -Encoding utf8
            [System.IO.File]::WriteAllText($codexAgentsPath, ($codexAgents -replace 'Read the resolved workspace', 'Read the stale workspace'), (New-Object System.Text.UTF8Encoding($false)))

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

            $managedAdmissionTextFiles = @(
                (Join-Path (Join-Path $UserProfile '.claude') 'CLAUDE.md'),
                (Join-Path $WorkspaceRoot 'AGENTS.md')
            )

            foreach ($path in $managedAdmissionTextFiles) {
                $content = Get-Content -LiteralPath $path -Raw -Encoding utf8
                if (-not $content.Contains('v2-only-with-new-work-admission')) {
                    throw ("managed entry file should be refreshed to the current v2 admission contract: {0}" -f $path)
                }
                if ($content.Contains('stale-v1-admission')) {
                    throw ("managed entry file should not retain stale admission routing: {0}" -f $path)
                }
            }
            if (Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.assistant\entry\AGENTS.md')) { throw 'v2 admission refresh must not recreate the retired lifecycle shim' }

            $codexAgentsPath = Join-Path (Join-Path $UserProfile '.codex') 'AGENTS.md'
            $codexAgents = Get-Content -LiteralPath $codexAgentsPath -Raw -Encoding utf8
            if (-not $codexAgents.Contains("Read the resolved workspace's ``AGENTS.md`` first") -or
                $codexAgents.Contains('Read the stale workspace') -or
                $codexAgents.Contains('entry-router')) {
                throw 'Codex host overlay should be refreshed without duplicating the workspace entry contract'
            }

            $codexManagedConfigPath = Join-Path (Join-Path $UserProfile '.codex') 'managed_config.toml'
            if (Test-Path -LiteralPath $codexManagedConfigPath) {
                throw 'v2 admission update should not create Codex administrator policy'
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
            if (Test-Path -LiteralPath $codexManagedConfigPath) {
                throw 'install/update-managed-assets should leave Codex managed_config.toml absent'
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
