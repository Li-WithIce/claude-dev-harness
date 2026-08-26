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
        [hashtable]$Arguments
    )

    $originalUserProfile = $env:USERPROFILE
    $originalLastExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $originalLastExitCodeValue = if ($null -ne $originalLastExitCode) { $originalLastExitCode.Value } else { $null }
    try {
        $env:USERPROFILE = $UserProfile
        $global:LASTEXITCODE = 0
        try {
            $output = @(& $ScriptPath @Arguments 2>&1)
            $exitCode = Get-LastExitCodeOrZero
        } catch {
            $output = @($_.Exception.Message)
            $exitCode = 1
        }
        return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
    } finally {
        $env:USERPROFILE = $originalUserProfile
        if ($null -eq $originalLastExitCode) {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        } else {
            $global:LASTEXITCODE = $originalLastExitCodeValue
        }
    }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Get-FileSnapshot {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Hash = '' }
    }
    return [pscustomobject]@{ Exists = $true; Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

function Test-SameSnapshot {
    param($Left, $Right)
    return $Left.Exists -eq $Right.Exists -and $Left.Hash -eq $Right.Hash
}

function Get-HookCommands {
    param($Settings)

    return @($Settings.hooks.PSObject.Properties | ForEach-Object {
            foreach ($section in @($_.Value)) {
                foreach ($hook in @($section.hooks)) {
                    [string]$hook.command
                }
            }
        })
}

function Get-TestJunctionTarget {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $null
    }
    $target = $item.Target
    if ($target -is [System.Array]) {
        $target = $target[0]
    }
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }
    return Get-NormalizedPath -Path $target
}

function Add-Check {
    param([string]$Message)
    $script:Checks.Add($Message) | Out-Null
}

function Add-Failure {
    param([string]$Message)
    $script:Failures.Add($Message) | Out-Null
}

function Set-RegistryManifestDigestForPath {
    param(
        $Registry,
        [string]$ManifestPath
    )

    $normalizedPath = (Get-NormalizedPath -Path $ManifestPath).ToLowerInvariant()
    $digestKey = Get-InstallStateIdentityHash -Value $normalizedPath
    $digest = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $property = $Registry.manifest_digests.PSObject.Properties[$digestKey]
    if ($null -eq $property) {
        $Registry.manifest_digests | Add-Member -NotePropertyName $digestKey -NotePropertyValue $digest
    } else {
        $property.Value = $digest
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$sourceRoot = Get-NormalizedPath -Path $RepoRoot
. (Join-Path $sourceRoot 'scripts\install-transaction-common.ps1')
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('uninstall-isolation-' + [guid]::NewGuid().ToString('N'))
$thinRepoRoot = Join-Path $scratchRoot 'repo-thin'
$thinRepoA = Join-Path $scratchRoot 'repo-thin-a'
$thinRepoB = Join-Path $scratchRoot 'repo-thin-b'
$RepoRoot = $sourceRoot
$userProfile = Join-Path $scratchRoot 'user'
$workspaceA = Join-Path $scratchRoot 'workspace-a'
$workspaceB = Join-Path $scratchRoot 'workspace-b'
$singleUserProfile = Join-Path $scratchRoot 'single-user'
$singleWorkspace = Join-Path $scratchRoot 'single-workspace'
$mixedUserProfile = Join-Path $scratchRoot 'mixed-user'
$mixedWorkspaceA = Join-Path $scratchRoot 'mixed-workspace-a'
$mixedWorkspaceB = Join-Path $scratchRoot 'mixed-workspace-b'
$homeUserProfile = Join-Path $scratchRoot 'home-user'
$homeWorkspaceB = Join-Path $scratchRoot 'home-workspace-b'
$mergeUserProfile = Join-Path $scratchRoot 'merge-user'
$mergeWorkspace = Join-Path $scratchRoot 'merge-workspace'
$recoveryUserProfile = Join-Path $scratchRoot 'recovery-user'
$recoveryWorkspace = Join-Path $scratchRoot 'recovery-workspace'
$ownerUserProfile = Join-Path $scratchRoot 'owner-user'
$ownerWorkspaceA = Join-Path $scratchRoot 'owner-workspace-a'
$ownerWorkspaceB = Join-Path $scratchRoot 'owner-workspace-b'
$ownerRepoA = Join-Path $scratchRoot 'repo-a'
$ownerRepoB = Join-Path $scratchRoot 'repo-b'
$unregisteredUserProfile = Join-Path $scratchRoot 'unregistered-user'
$unregisteredWorkspace = Join-Path $scratchRoot 'unregistered-workspace'
$legacyUserProfile = Join-Path $scratchRoot 'legacy-user'
$legacyWorkspace = Join-Path $scratchRoot 'legacy-workspace'
$registryPath = Join-Path $userProfile '.dev-harness\install-registry.json'
$legacyPointerPath = Join-Path $RepoRoot 'backups\active-install.json'
$script:Checks = [System.Collections.Generic.List[string]]::new()
$script:Failures = [System.Collections.Generic.List[string]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$mixedProcesses = [System.Collections.Generic.List[object]]::new()

try {
    foreach ($relativePath in @(
            'install.ps1'
            'uninstall.ps1'
            'agent-configs'
            'runtime-hooks'
            'vault-template'
            'scripts'
            'skills\entry-router'
            'skills\orchestrator'
            'skills\plan'
            'skills\implement'
            'skills\review'
            'skills\test'
            'skills\spec'
            'tests\verify-installation.ps1'
            'tests\fixture-test-common.ps1'
            'tests\forbidden-path-prefixes.txt'
        )) {
        Copy-RepoPathToFixture -SourceRoot $sourceRoot -FixtureRoot $thinRepoRoot -RelativePath $relativePath
    }
    New-Item -ItemType Directory -Path (Join-Path $thinRepoRoot 'skills\.system') -Force | Out-Null
    Copy-Item -LiteralPath $thinRepoRoot -Destination $thinRepoA -Recurse -Force
    Copy-Item -LiteralPath $thinRepoRoot -Destination $thinRepoB -Recurse -Force
    New-Item -ItemType Directory -Path $userProfile,$workspaceA,$workspaceB,$singleUserProfile,$singleWorkspace,$mixedUserProfile,$mixedWorkspaceA,$mixedWorkspaceB,$homeUserProfile,$homeWorkspaceB,$mergeUserProfile,$mergeWorkspace,$recoveryUserProfile,$recoveryWorkspace,$ownerUserProfile,$ownerWorkspaceA,$ownerWorkspaceB,$ownerRepoA,$ownerRepoB,$unregisteredUserProfile,$unregisteredWorkspace,$legacyUserProfile,$legacyWorkspace -Force | Out-Null
    $mixedPreinstall = Invoke-RepoScript -UserProfile $mixedUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $mixedWorkspaceA
        RepoRoot = $RepoRoot
    }
    $mixedRegistryPath = Join-Path $mixedUserProfile '.dev-harness\install-registry.json'
    $mixedRegistryHashBefore = if (Test-Path -LiteralPath $mixedRegistryPath) { (Get-FileHash -LiteralPath $mixedRegistryPath -Algorithm SHA256).Hash } else { '' }
    $heldMixedMutex = Enter-InstallTransactionMutex -UserProfile $mixedUserProfile
    try {
        $mixedProcesses.Add((Start-RepoProcess -UserProfile $mixedUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$mixedWorkspaceB,'-RepoRoot',$RepoRoot))) | Out-Null
        $mixedProcesses.Add((Start-RepoProcess -UserProfile $mixedUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @('-WorkspaceRoot',$mixedWorkspaceA,'-RepoRoot',$RepoRoot))) | Out-Null
        $mixedExitedWhileLocked = @($mixedProcesses | Where-Object { $_.Process.WaitForExit(500) }).Count
        $mixedRegistryHashWhileLocked = if (Test-Path -LiteralPath $mixedRegistryPath) { (Get-FileHash -LiteralPath $mixedRegistryPath -Algorithm SHA256).Hash } else { '' }
        if ($mixedPreinstall.ExitCode -eq 0 -and
            $mixedExitedWhileLocked -eq 0 -and
            $mixedRegistryHashWhileLocked -eq $mixedRegistryHashBefore -and
            -not (Test-Path -LiteralPath (Join-Path $mixedWorkspaceB 'AGENTS.md'))) {
            Add-Check 'concurrent install and uninstall wait for one USERPROFILE transaction lock before mutation'
        } else {
            Add-Failure 'mixed install/uninstall should remain write-free while the USERPROFILE transaction lock is held'
        }
    } finally {
        Exit-InstallTransactionMutex -Mutex $heldMixedMutex
    }
    $mixedTimedOutProcessIds = [System.Collections.Generic.List[int]]::new()
    foreach ($child in $mixedProcesses) {
        if (-not $child.Process.WaitForExit(60000)) {
            $mixedTimedOutProcessIds.Add($child.Process.Id) | Out-Null
            try {
                $child.Process.Kill($true)
            } catch [System.InvalidOperationException] {
                if (-not $child.Process.HasExited) {
                    throw
                }
            }
            if (-not $child.Process.WaitForExit(10000)) {
                throw ("timed out stopping mixed child process tree {0}" -f $child.Process.Id)
            }
        }
    }
    $mixedExitCodes = @($mixedProcesses | ForEach-Object { $_.Process.ExitCode })
    $mixedRegistry = Read-JsonFile -Path $mixedRegistryPath
    $mixedEntries = @()
    if ($null -ne $mixedRegistry) {
        $mixedEntries = @($mixedRegistry.workspaces.PSObject.Properties)
    }
    $mixedVerify = Invoke-RepoScript -UserProfile $mixedUserProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $mixedWorkspaceB
        RepoRoot = $RepoRoot
        Scope = 'All'
    }
    if ($mixedTimedOutProcessIds.Count -eq 0 -and
        @($mixedExitCodes | Where-Object { $_ -eq 0 }).Count -eq 2 -and
        $mixedEntries.Count -eq 1 -and
        (Get-NormalizedPath -Path $mixedEntries[0].Value.workspace_root) -eq $mixedWorkspaceB -and
        $mixedVerify.ExitCode -eq 0 -and
        @($mixedVerify.Output | Where-Object { [string]$_ -ceq 'STATUS: PASS' }).Count -eq 1) {
        Add-Check 'concurrent install/uninstall preserves only the installed workspace and a valid user-global state'
    } else {
        $mixedErrors = @($mixedProcesses | ForEach-Object { $_.StdErr.Result }) -join ' | '
        Add-Failure ("mixed install/uninstall should leave only workspace B valid, exits={0}, entries={1}, verify={2}, timeouts={3}, errors={4}" -f ($mixedExitCodes -join ','),$mixedEntries.Count,$mixedVerify.ExitCode,($mixedTimedOutProcessIds -join ','),$mixedErrors)
    }

    $homeInstall = Invoke-RepoScript -UserProfile $homeUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $homeUserProfile
        RepoRoot = $RepoRoot
    }
    $homeBInstall = Invoke-RepoScript -UserProfile $homeUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $homeWorkspaceB
        RepoRoot = $RepoRoot
    }
    $homeUninstall = Invoke-RepoScript -UserProfile $homeUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $homeUserProfile
        RepoRoot = $RepoRoot
    }
    $homeVerifyB = Invoke-RepoScript -UserProfile $homeUserProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $homeWorkspaceB
        RepoRoot = $RepoRoot
        Scope = 'All'
    }
    $results.Add($homeInstall) | Out-Null
    $results.Add($homeBInstall) | Out-Null
    $results.Add($homeUninstall) | Out-Null
    $homeRegistryPath = Join-Path $homeUserProfile '.dev-harness\install-registry.json'
    $homeRegistry = Read-JsonFile -Path $homeRegistryPath
    $homeEntries = @()
    if ($null -ne $homeRegistry) {
        $homeEntries = @($homeRegistry.workspaces.PSObject.Properties)
    }
    if ($homeInstall.ExitCode -eq 0 -and
        $homeBInstall.ExitCode -eq 0 -and
        $homeUninstall.ExitCode -eq 0 -and
        $homeEntries.Count -eq 1 -and
        (Get-NormalizedPath -Path $homeEntries[0].Value.workspace_root) -eq $homeWorkspaceB -and
        (Test-Path -LiteralPath (Join-Path $homeUserProfile '.claude\CLAUDE.md') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $homeUserProfile '.codex\AGENTS.md') -PathType Leaf) -and
        $homeVerifyB.ExitCode -eq 0 -and
        @($homeVerifyB.Output | Where-Object { [string]$_ -ceq 'STATUS: PASS' }).Count -eq 1) {
        Add-Check 'uninstalling a HOME workspace preserves explicit user-global roots for the remaining workspace'
    } else {
        Add-Failure ("HOME workspace uninstall should preserve the remaining workspace user-global installation, entries={0}, verify={1}" -f $homeEntries.Count,$homeVerifyB.ExitCode)
    }

    $RepoRoot = $thinRepoRoot
    $mergeGitIgnorePath = Join-Path $mergeWorkspace '.gitignore'
    $mergeSettingsPath = Join-Path $mergeUserProfile '.claude\settings.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $mergeSettingsPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($mergeGitIgnorePath, "existing-rule/`r`n.claude`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $mergeBaselineSettings = [ordered]@{
        model = 'baseline-model'
        hooks = [ordered]@{
            UserPromptSubmit = @([ordered]@{
                hooks = @(
                    [ordered]@{ type = 'command'; command = 'baseline-third-party.cmd'; timeout = 10 }
                    [ordered]@{ type = 'command'; command = 'node "C:\third-party\hooks-memory\stop.js"'; timeout = 10 }
                )
            })
        }
    }
    [System.IO.File]::WriteAllText($mergeSettingsPath, ($mergeBaselineSettings | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $mergeInstall = Invoke-RepoScript -UserProfile $mergeUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $mergeWorkspace
        RepoRoot = $RepoRoot
    }
    $mergeGitIgnoreAfterInstall = Get-Content -LiteralPath $mergeGitIgnorePath -Raw -Encoding utf8
    [System.IO.File]::WriteAllText($mergeGitIgnorePath, ($mergeGitIgnoreAfterInstall.TrimEnd([char[]]@("`r","`n")) + "`r`npost-install-user-rule/`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    $mergeCurrentSettings = Read-JsonFile -Path $mergeSettingsPath
    $mergeCurrentSettings | Add-Member -NotePropertyName 'userAdded' -NotePropertyValue 'keep-me' -Force
    $stopSections = @($mergeCurrentSettings.hooks.Stop)
    $mergeCurrentSettings.hooks.Stop = @($stopSections + [pscustomobject]@{
        hooks = @(
            [pscustomobject]@{ type = 'command'; command = 'post-install-third-party.cmd'; timeout = 10 }
        )
    } + [pscustomobject]@{ matcher = 'Empty user section'; hooks = @() })
    [System.IO.File]::WriteAllText($mergeSettingsPath, ($mergeCurrentSettings | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
    $mergeCodexHooksPath = Join-Path $mergeUserProfile '.codex\hooks.json'
    $mergeCurrentCodexHooks = Read-JsonFile -Path $mergeCodexHooksPath
    $mergeCurrentCodexHooks.hooks | Add-Member -NotePropertyName 'PostToolUse' -NotePropertyValue @([pscustomobject]@{
        matcher = '^PostInstallThirdParty$'
        hooks = @([pscustomobject]@{ type = 'command'; command = 'codex-post-install-third-party.cmd'; timeout = 9 })
    }) -Force
    [System.IO.File]::WriteAllText($mergeCodexHooksPath, ($mergeCurrentCodexHooks | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
    $mergeRegistryPath = Join-Path $mergeUserProfile '.dev-harness\install-registry.json'
    $mergeRegistryCommitLock = [System.IO.File]::Open($mergeRegistryPath, 'Open', 'Read', 'ReadWrite')
    try {
        $mergeInterruptedUninstall = Invoke-RepoScript -UserProfile $mergeUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
            WorkspaceRoot = $mergeWorkspace
            RepoRoot = $RepoRoot
        }
    } finally {
        $mergeRegistryCommitLock.Dispose()
    }
    $mergeUninstallJournalPath = Join-Path $mergeUserProfile '.dev-harness\uninstall-transaction.json'
    $mergeJournalPersisted = Test-Path -LiteralPath $mergeUninstallJournalPath -PathType Leaf
    $mergeUninstall = Invoke-RepoScript -UserProfile $mergeUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{ RepoRoot = $RepoRoot }
    $results.Add($mergeInstall) | Out-Null
    $results.Add($mergeInterruptedUninstall) | Out-Null
    $results.Add($mergeUninstall) | Out-Null
    $mergeFinalGitIgnore = Get-Content -LiteralPath $mergeGitIgnorePath -Raw -Encoding utf8
    $mergeFinalSettings = Read-JsonFile -Path $mergeSettingsPath
    $mergeFinalCommands = Get-HookCommands -Settings $mergeFinalSettings
    $mergeFinalGitLines = @([regex]::Split($mergeFinalGitIgnore, '\r?\n') | ForEach-Object { $_.Trim() })
    $remainingHarnessLines = @('# dev-harness workspace artifacts','# claude-dev-harness workspace artifacts','AGENTS.md') | Where-Object {
        $token = $_
        @([regex]::Split($mergeFinalGitIgnore, '\r?\n') | Where-Object { $_.Trim().Equals($token, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    }
    $emptyUserSections = @($mergeFinalSettings.hooks.Stop | Where-Object {
        $matcherProperty = $_.PSObject.Properties['matcher']
        $null -ne $matcherProperty -and $matcherProperty.Value -eq 'Empty user section' -and @($_.hooks).Count -eq 0
    })
    $mergeFinalCodexHooks = Read-JsonFile -Path $mergeCodexHooksPath
    $mergeFinalCodexCommands = Get-HookCommands -Settings $mergeFinalCodexHooks
    $mergeFinalCodexThirdPartyHooks = @(
        foreach ($section in @($mergeFinalCodexHooks.hooks.PostToolUse)) {
            foreach ($hook in @($section.hooks)) {
                if ([string]$section.matcher -ceq '^PostInstallThirdParty$' -and
                    [string]$hook.type -ceq 'command' -and
                    [string]$hook.command -ceq 'codex-post-install-third-party.cmd' -and
                    [int]$hook.timeout -eq 9) { $hook }
            }
        }
    )
    if ($mergeInstall.ExitCode -eq 0 -and
        $mergeInterruptedUninstall.ExitCode -ne 0 -and
        $mergeJournalPersisted -and
        $mergeUninstall.ExitCode -eq 0 -and
        -not (Test-Path -LiteralPath $mergeUninstallJournalPath) -and
        $mergeFinalGitLines -contains 'existing-rule/' -and
        $mergeFinalGitLines -contains 'post-install-user-rule/' -and
        @($mergeFinalGitLines | Where-Object { $_ -eq '.assistant/' }).Count -eq 0 -and
        @($remainingHarnessLines).Count -eq 0 -and
        $mergeFinalSettings.model -eq 'baseline-model' -and
        $mergeFinalSettings.userAdded -eq 'keep-me' -and
        @($mergeFinalCommands | Where-Object { $_ -eq 'baseline-third-party.cmd' }).Count -eq 1 -and
        @($mergeFinalCommands | Where-Object { $_ -eq 'post-install-third-party.cmd' }).Count -eq 1 -and
        @($mergeFinalCommands | Where-Object { $_ -eq 'node "C:\third-party\hooks-memory\stop.js"' }).Count -eq 1 -and
        $emptyUserSections.Count -eq 1 -and
        @($mergeFinalCommands | Where-Object { $_ -match [regex]::Escape((Join-Path $mergeUserProfile '.claude\hooks-memory')) }).Count -eq 0 -and
        $mergeFinalCodexThirdPartyHooks.Count -eq 1 -and
        @($mergeFinalCodexCommands | Where-Object { $_ -match [regex]::Escape((Join-Path $mergeUserProfile '.claude\hooks-memory')) }).Count -eq 0) {
        Add-Check 'semantic uninstall resumes after a pre-commit crash while preserving gitignore, settings, and Codex hook user increments'
    } else {
        Add-Failure ("semantic uninstall crash-resume should preserve user edits and remove only Harness-managed gitignore lines and hooks; install={0}, interrupted={1}, journal={2}, resume={3}, harness_lines={4}, model={5}, user_added={6}, commands={7}, codex_commands={8}, gitignore={9}" -f `
            $mergeInstall.ExitCode,$mergeInterruptedUninstall.ExitCode,$mergeJournalPersisted,$mergeUninstall.ExitCode,(@($remainingHarnessLines) -join ','),$mergeFinalSettings.model,$mergeFinalSettings.userAdded,(@($mergeFinalCommands) -join ','),(@($mergeFinalCodexCommands) -join ','),($mergeFinalGitIgnore -replace "`r?`n",'<NL>'))
    }

    $bomUserProfile = Join-Path $scratchRoot 'semantic-bom-user'
    $bomWorkspace = Join-Path $scratchRoot 'semantic-bom-workspace'
    $bomCodexHooksPath = Join-Path $bomUserProfile '.codex\hooks.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $bomCodexHooksPath),$bomWorkspace -Force | Out-Null
    $bomBaselineHooks = [ordered]@{
        description = 'bom baseline'
        hooks = [ordered]@{
            Stop = @([ordered]@{
                matcher = '^Baseline$'
                hooks = @([ordered]@{ type='command';command='bom-baseline-third-party.cmd';timeout=7 })
            })
        }
    } | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($bomCodexHooksPath,$bomBaselineHooks,[System.Text.UTF8Encoding]::new($true))
    $bomBaselineBytes = [System.IO.File]::ReadAllBytes($bomCodexHooksPath)
    $bomInstall = Invoke-RepoScript -UserProfile $bomUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $bomWorkspace
        RepoRoot = $RepoRoot
    }
    $results.Add($bomInstall) | Out-Null
    if ($bomInstall.ExitCode -eq 0) {
        $bomRegistryPath = Join-Path $bomUserProfile '.dev-harness\install-registry.json'
        $bomRegistryCommitLock = [System.IO.File]::Open($bomRegistryPath,'Open','Read','ReadWrite')
        try {
            $bomInterruptedUninstall = Invoke-RepoScript -UserProfile $bomUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
                WorkspaceRoot = $bomWorkspace
                RepoRoot = $RepoRoot
            }
        } finally {
            $bomRegistryCommitLock.Dispose()
        }
        $bomJournalPath = Join-Path $bomUserProfile '.dev-harness\uninstall-transaction.json'
        $bomJournalPersisted = Test-Path -LiteralPath $bomJournalPath -PathType Leaf
        $bomResume = Invoke-RepoScript -UserProfile $bomUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{ RepoRoot = $RepoRoot }
        $results.Add($bomInterruptedUninstall) | Out-Null
        $results.Add($bomResume) | Out-Null
        $bomFinalBytes = if (Test-Path -LiteralPath $bomCodexHooksPath -PathType Leaf) { [System.IO.File]::ReadAllBytes($bomCodexHooksPath) } else { [byte[]]@() }
        if ($bomInterruptedUninstall.ExitCode -ne 0 -and
            $bomJournalPersisted -and
            $bomResume.ExitCode -eq 0 -and
            -not (Test-Path -LiteralPath $bomJournalPath) -and
            $bomFinalBytes.Length -ge 3 -and
            $bomFinalBytes[0] -eq 0xef -and $bomFinalBytes[1] -eq 0xbb -and $bomFinalBytes[2] -eq 0xbf -and
            ($bomFinalBytes -join ',') -ceq ($bomBaselineBytes -join ',')) {
            Add-Check 'semantic uninstall crash-resume restores a UTF-8 BOM hook baseline byte-for-byte'
        } else {
            Add-Failure "semantic uninstall crash-resume did not preserve the BOM baseline: install=$($bomInstall.ExitCode) interrupted=$($bomInterruptedUninstall.ExitCode) journal=$bomJournalPersisted resume=$($bomResume.ExitCode)"
        }
    } else {
        Add-Failure 'semantic BOM baseline fixture install failed'
    }

    $semanticBarrierRoot = Join-Path $scratchRoot 'semantic-uninstall-snapshot-barrier'
    $uninstallSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'uninstall.ps1') -Raw -Encoding utf8
    $functionCut = $uninstallSource.IndexOf('function Read-InstallManifest', [System.StringComparison]::Ordinal)
    if ($functionCut -lt 0) {
        Add-Failure 'semantic uninstall snapshot barrier could not isolate production restore functions'
    } else {
        $functionSource = $uninstallSource.Substring(0, $functionCut)
        $semanticBarrierCases = @(
            [pscustomobject]@{
                Name = 'claude-write'
                Target = { param($CaseRoot, $ClaudeHome, $WorkspaceRoot) Join-Path $ClaudeHome 'settings.json' }
                Initial = { param($ClaudeHome) [ordered]@{
                        userAdded = 'A'
                        hooks = [ordered]@{
                            Stop = @([ordered]@{
                                hooks = @([ordered]@{ type = 'command'; command = ('node "{0}"' -f (Join-Path $ClaudeHome 'hooks-memory\stop.js')); timeout = 10 })
                            })
                        }
                    } | ConvertTo-Json -Depth 20 }
                Drift = '{"external":"B-claude-write"}'
                Anchor = '    $currentRaw = $currentSnapshot.Content'
            }
            [pscustomobject]@{
                Name = 'gitignore-delete'
                Target = { param($CaseRoot, $ClaudeHome, $WorkspaceRoot) Join-Path $WorkspaceRoot '.gitignore' }
                Initial = { param($ClaudeHome) "# dev-harness workspace artifacts`n.assistant/`nAGENTS.md`n.claude`n" }
                Drift = "external-B/`n"
                Anchor = '    $resultRaw = ($resultLines -join $newline).TrimEnd([char[]]@("`r", "`n"))'
            }
        )
        $semanticBarrierFailures = New-Object System.Collections.Generic.List[string]
        foreach ($case in $semanticBarrierCases) {
            $caseRoot = Join-Path $semanticBarrierRoot $case.Name
            $workspaceRoot = Join-Path $caseRoot 'workspace'
            $claudeHome = Join-Path $caseRoot 'user\.claude'
            $fixtureRoot = Join-Path $caseRoot 'fixture'
            $targetPath = & $case.Target $caseRoot $claudeHome $workspaceRoot
            New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath),$workspaceRoot,$claudeHome -Force | Out-Null
            $initial = & $case.Initial $claudeHome
            [System.IO.File]::WriteAllText($targetPath, $initial, (New-Object System.Text.UTF8Encoding($false)))
            Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\install-transaction-common.ps1'
            Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\lib\Harness.Hashing.psm1'
            if (@($functionSource.Split([string[]]@($case.Anchor), [System.StringSplitOptions]::None)).Count -ne 2) {
                $semanticBarrierFailures.Add("$($case.Name): barrier anchor is not unique") | Out-Null
                continue
            }
            $escapedTarget = $targetPath.Replace("'", "''")
            $escapedDrift = $case.Drift.Replace("'", "''")
            $barrier = "    [System.IO.File]::WriteAllText('$escapedTarget', '$escapedDrift', (New-Object System.Text.UTF8Encoding(`$false)))"
            $instrumentedSource = $functionSource.Replace($case.Anchor, ($case.Anchor + [Environment]::NewLine + $barrier))
            $instrumentedPath = Join-Path $fixtureRoot 'uninstall-functions.ps1'
            [System.IO.File]::WriteAllText($instrumentedPath, $instrumentedSource, (New-Object System.Text.UTF8Encoding($false)))
            $record = [ordered]@{
                path = $targetPath
                existed = $false
                backup_path = $null
                item_type = 'missing'
                link_type = $null
                link_target = $null
            }
            if ($case.Name -eq 'claude-write') {
                $record['expected_postimage'] = [ordered]@{
                    mode = 'semantic'
                    contract = 'claude-settings/v1'
                    managed_hooks = @([ordered]@{
                        event = 'Stop'
                        path = 'hooks.Stop'
                        section = [ordered]@{}
                        hook = [ordered]@{
                            type = 'command'
                            command = ('node "{0}"' -f (Join-Path $claudeHome 'hooks-memory\stop.js'))
                            timeout = 10
                        }
                        multiplicity = 1
                    })
                }
            }
            $manifest = [ordered]@{
                workspace_root = $workspaceRoot
                claude_home = $claudeHome
                codex_home = (Join-Path $caseRoot 'user\.codex')
            }
            $rejected = & {
                param($FunctionsPath, $RepoPath, $BackupRecord, $InstallManifest)
                . $FunctionsPath -RepoRoot $RepoPath
                try {
                    [void](Restore-BackupRecord -Record $BackupRecord -Manifest $InstallManifest)
                    return $false
                } catch {
                    return $true
                }
            } $instrumentedPath $RepoRoot $record $manifest
            $current = if (Test-Path -LiteralPath $targetPath -PathType Leaf) { Get-Content -LiteralPath $targetPath -Raw -Encoding utf8 } else { $null }
            if (-not $rejected -or $current -cne $case.Drift) {
                $semanticBarrierFailures.Add(("{0}: rejected={1}, preserved={2}" -f $case.Name,$rejected,($current -ceq $case.Drift))) | Out-Null
            }
        }
        if ($semanticBarrierFailures.Count -eq 0) {
            Add-Check 'semantic uninstall snapshot barrier rejects post-merge write/delete drift and preserves exact B'
        } else {
            Add-Failure ('semantic uninstall snapshot CAS regression failed: ' + ($semanticBarrierFailures -join '; '))
        }
    }

    $postimageUser = Join-Path $scratchRoot 'postimage-user'
    $postimageWorkspace = Join-Path $scratchRoot 'postimage-workspace'
    $postimageInstall = Invoke-RepoScript -UserProfile $postimageUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $postimageWorkspace
        RepoRoot = $RepoRoot
    }
    $postimageRegistryPath = Join-Path $postimageUser '.dev-harness\install-registry.json'
    $postimageRegistry = Read-JsonFile -Path $postimageRegistryPath
    $postimageEntry = @($postimageRegistry.workspaces.PSObject.Properties | Select-Object -First 1)
    $postimageManifestPath = [string]@($postimageEntry[0].Value.manifests)[-1]
    $postimageSettingsPath = Join-Path $postimageUser '.claude\settings.json'
    $installedSettingsRaw = Get-Content -LiteralPath $postimageSettingsPath -Raw -Encoding utf8
    $postimageRegistrySnapshot = Get-FileSnapshot -Path $postimageRegistryPath
    $postimageManifestSnapshot = Get-FileSnapshot -Path $postimageManifestPath
    $postimageWorkspaceSnapshot = Get-FileSnapshot -Path (Join-Path $postimageWorkspace 'AGENTS.md')
    $postimageJournalPath = Join-Path $postimageUser '.dev-harness\uninstall-transaction.json'

    $mutatedSettings = $installedSettingsRaw | ConvertFrom-Json
    $mutatedSettings.hooks.Stop[0].hooks[0].timeout = 99
    [System.IO.File]::WriteAllText($postimageSettingsPath, ($mutatedSettings | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $mutatedSettingsSnapshot = Get-FileSnapshot -Path $postimageSettingsPath
    $semanticStructureReject = Invoke-RepoScript -UserProfile $postimageUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $postimageWorkspace
        RepoRoot = $RepoRoot
    }
    $semanticStructureWriteFree = Test-SameSnapshot -Left $mutatedSettingsSnapshot -Right (Get-FileSnapshot -Path $postimageSettingsPath)
    [System.IO.File]::WriteAllText($postimageSettingsPath, $installedSettingsRaw, (New-Object System.Text.UTF8Encoding($false)))
    $duplicateSettings = $installedSettingsRaw | ConvertFrom-Json
    $duplicateSettings.hooks.Stop[0].hooks = @($duplicateSettings.hooks.Stop[0].hooks + ($duplicateSettings.hooks.Stop[0].hooks[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json))
    [System.IO.File]::WriteAllText($postimageSettingsPath, ($duplicateSettings | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $duplicateSettingsSnapshot = Get-FileSnapshot -Path $postimageSettingsPath
    $semanticDuplicateReject = Invoke-RepoScript -UserProfile $postimageUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $postimageWorkspace
        RepoRoot = $RepoRoot
    }
    $semanticDuplicateWriteFree = Test-SameSnapshot -Left $duplicateSettingsSnapshot -Right (Get-FileSnapshot -Path $postimageSettingsPath)
    [System.IO.File]::WriteAllText($postimageSettingsPath, $installedSettingsRaw, (New-Object System.Text.UTF8Encoding($false)))
    $managedLinkPath = Join-Path $postimageUser '.claude\skills\entry-router'
    Remove-Item -LiteralPath $managedLinkPath -Force
    New-Item -ItemType Directory -Path $managedLinkPath -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $managedLinkPath 'user-sentinel.txt'), 'keep-me', (New-Object System.Text.UTF8Encoding($false)))
    $linkReplacementReject = Invoke-RepoScript -UserProfile $postimageUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $postimageWorkspace
        RepoRoot = $RepoRoot
    }
    $results.Add($postimageInstall) | Out-Null
    $results.Add($semanticStructureReject) | Out-Null
    $results.Add($semanticDuplicateReject) | Out-Null
    $results.Add($linkReplacementReject) | Out-Null
    if ($postimageInstall.ExitCode -eq 0 -and
        $semanticStructureReject.ExitCode -ne 0 -and
        $semanticDuplicateReject.ExitCode -ne 0 -and
        $linkReplacementReject.ExitCode -ne 0 -and
        $semanticStructureWriteFree -and
        $semanticDuplicateWriteFree -and
        (Get-Content -LiteralPath (Join-Path $managedLinkPath 'user-sentinel.txt') -Raw -Encoding utf8) -eq 'keep-me' -and
        (Test-SameSnapshot -Left $postimageRegistrySnapshot -Right (Get-FileSnapshot -Path $postimageRegistryPath)) -and
        (Test-SameSnapshot -Left $postimageManifestSnapshot -Right (Get-FileSnapshot -Path $postimageManifestPath)) -and
        (Test-SameSnapshot -Left $postimageWorkspaceSnapshot -Right (Get-FileSnapshot -Path (Join-Path $postimageWorkspace 'AGENTS.md'))) -and
        -not (Test-Path -LiteralPath $postimageJournalPath)) {
        Add-Check 'semantic structure or multiplicity changes and link-to-directory replacement fail before journal or user-data mutation'
    } else {
        Add-Failure 'postimage identity conflicts must fail closed before every uninstall mutation'
    }

    $typedSemanticUser = Join-Path $scratchRoot 'typed-semantic-user'
    $typedSemanticWorkspace = Join-Path $scratchRoot 'typed-semantic-workspace'
    $typedSemanticInstall = Invoke-RepoScript -UserProfile $typedSemanticUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $typedSemanticWorkspace
        RepoRoot = $RepoRoot
    }
    $typedSemanticRegistryPath = Join-Path $typedSemanticUser '.dev-harness\install-registry.json'
    $typedSemanticRegistry = Read-JsonFile -Path $typedSemanticRegistryPath
    $typedSemanticEntry = @($typedSemanticRegistry.workspaces.PSObject.Properties | Select-Object -First 1)
    $typedSemanticManifestPath = [string]@($typedSemanticEntry[0].Value.manifests)[-1]
    $typedSemanticSettingsPath = Join-Path $typedSemanticUser '.claude\settings.json'
    $typedSemanticSettings = Read-JsonFile -Path $typedSemanticSettingsPath
    $typedSemanticSettings.hooks.Stop[0].hooks[0].timeout = '10'
    [System.IO.File]::WriteAllText($typedSemanticSettingsPath, ($typedSemanticSettings | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $typedSemanticSettingsSnapshot = Get-FileSnapshot -Path $typedSemanticSettingsPath
    $typedSemanticRegistrySnapshot = Get-FileSnapshot -Path $typedSemanticRegistryPath
    $typedSemanticManifestSnapshot = Get-FileSnapshot -Path $typedSemanticManifestPath
    $typedSemanticWorkspaceSnapshot = Get-FileSnapshot -Path (Join-Path $typedSemanticWorkspace 'AGENTS.md')
    $typedSemanticReject = Invoke-RepoScript -UserProfile $typedSemanticUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $typedSemanticWorkspace
        RepoRoot = $RepoRoot
    }
    $results.Add($typedSemanticInstall) | Out-Null
    $results.Add($typedSemanticReject) | Out-Null
    if ($typedSemanticInstall.ExitCode -eq 0 -and
        $typedSemanticReject.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $typedSemanticSettingsSnapshot -Right (Get-FileSnapshot -Path $typedSemanticSettingsPath)) -and
        (Test-SameSnapshot -Left $typedSemanticRegistrySnapshot -Right (Get-FileSnapshot -Path $typedSemanticRegistryPath)) -and
        (Test-SameSnapshot -Left $typedSemanticManifestSnapshot -Right (Get-FileSnapshot -Path $typedSemanticManifestPath)) -and
        (Test-SameSnapshot -Left $typedSemanticWorkspaceSnapshot -Right (Get-FileSnapshot -Path (Join-Path $typedSemanticWorkspace 'AGENTS.md'))) -and
        -not (Test-Path -LiteralPath (Join-Path $typedSemanticUser '.dev-harness\uninstall-transaction.json'))) {
        Add-Check 'semantic identity rejects a JSON number-to-string type change before mutation'
    } else {
        Add-Failure 'semantic identity must compare JSON primitive types instead of their string rendering'
    }

    $planBindingUser = Join-Path $scratchRoot 'install-plan-binding-user'
    $planBindingWorkspace = Join-Path $scratchRoot 'install-plan-binding-workspace'
    $planBindingInstall = Invoke-RepoScript -UserProfile $planBindingUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $planBindingWorkspace
        RepoRoot = $RepoRoot
    }
    $planBindingRegistryPath = Join-Path $planBindingUser '.dev-harness\install-registry.json'
    $planBindingRegistry = Read-JsonFile -Path $planBindingRegistryPath
    $planBindingEntry = @($planBindingRegistry.workspaces.PSObject.Properties | Select-Object -First 1)
    $planBindingManifestPath = [string]@($planBindingEntry[0].Value.manifests)[-1]
    $planBindingManifest = Read-JsonFile -Path $planBindingManifestPath
    Remove-Item -LiteralPath $planBindingRegistryPath -Force
    $planBindingManifest.transaction_status = 'failed'
    [System.IO.File]::WriteAllText($planBindingManifestPath, ($planBindingManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $planBindingJournalPath = Join-Path $planBindingUser '.dev-harness\install-transaction.json'
    $planBindingJournal = [ordered]@{
        schema_version = 'install-transaction/v1.1'
        registry_schema_version = 'install-registry/v1.1'
        manifest_schema_version = 'install-manifest/v1.2'
        postimage_identity_contract = 'v1'
        user_profile = $planBindingUser
        repo_root = $RepoRoot
        workspace_root = $planBindingWorkspace
        registry_path = $planBindingRegistryPath
        registry_preimage_sha256 = 'missing'
        manifest_path = $planBindingManifestPath
        manifest_backup_record_count = [Math]::Max(0, @($planBindingManifest.backups).Count - 1)
        manifest_restore_plan_digest = ('0' * 64)
        postimage_transaction_status_contract = 'v1'
        postimage_history_ownership_contract = 'v1'
        postimage_manifest_integrity_contract = 'sha256-v1'
        legacy_pointer_path = $null
        legacy_pointer_import_digest = $null
    }
    [System.IO.File]::WriteAllText($planBindingJournalPath, ($planBindingJournal | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $planBindingManifestTable = Get-Content -LiteralPath $planBindingManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $planBindingFirstRestoreRecord = @($planBindingManifestTable.backups | Where-Object { [string]$_['scope'] -eq 'workspace' })[-1]
    $planBindingRestorePreimage = Get-InstallBackupRecordPreimageIdentity -Record $planBindingFirstRestoreRecord
    $planBindingRestorePostimage = $planBindingFirstRestoreRecord.expected_postimage
    if ([string]$planBindingRestorePreimage.item_type -ne 'missing' -or [string]$planBindingRestorePostimage.mode -ne 'exact') {
        throw 'install recovery fixture first restore record must be exact with a missing preimage'
    }
    $planBindingRestoreSidecars = Get-InstallExactPathSidecarPaths `
        -Path ([string]$planBindingFirstRestoreRecord.path) `
        -DesiredIdentity $planBindingRestorePreimage
    Move-Item -LiteralPath ([string]$planBindingFirstRestoreRecord.path) -Destination $planBindingRestoreSidecars.Old
    $planBindingDriftRecord = @($planBindingManifestTable.backups | Where-Object {
        [string]$_['scope'] -eq 'workspace' -and
        [string]$_['path'] -ne [string]$planBindingFirstRestoreRecord.path -and
        [string]$_['expected_postimage']['mode'] -eq 'exact' -and
        [string]$_['expected_postimage']['item_type'] -eq 'file'
    } | Select-Object -First 1)[0]
    $planBindingDriftPath = [string]$planBindingDriftRecord.path
    $planBindingDriftBytes = [System.IO.File]::ReadAllBytes($planBindingDriftPath)
    [System.IO.File]::WriteAllText($planBindingDriftPath, 'user-drift', (New-Object System.Text.UTF8Encoding($false)))
    $planBindingProjectedReject = Invoke-RepoScript -UserProfile $planBindingUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $planBindingManifestPath
        RepoRoot = $RepoRoot
    }
    $results.Add($planBindingProjectedReject) | Out-Null
    if ($planBindingProjectedReject.ExitCode -ne 0 -and
        (Test-Path -LiteralPath $planBindingRestoreSidecars.Old) -and
        (Get-Content -LiteralPath $planBindingDriftPath -Raw -Encoding utf8) -eq 'user-drift') {
        Add-Check 'projected prefix validation rejects a later target drift before repairing an earlier sidecar'
    } else {
        Add-Failure 'sidecar repair must validate no-sidecar targets before its first mutation'
    }
    [System.IO.File]::WriteAllBytes($planBindingDriftPath, $planBindingDriftBytes)
    $planBindingRecovery = Invoke-RepoScript -UserProfile $planBindingUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $planBindingManifestPath
        RepoRoot = $RepoRoot
    }
    $planBindingRecoveredManifest = Read-JsonFile -Path $planBindingManifestPath
    $results.Add($planBindingInstall) | Out-Null
    $results.Add($planBindingRecovery) | Out-Null
    if ($planBindingInstall.ExitCode -eq 0 -and
        $planBindingRecovery.ExitCode -eq 0 -and
        $planBindingRecoveredManifest.transaction_status -eq 'recovered' -and
        -not (Test-Path -LiteralPath $planBindingJournalPath) -and
        -not (Test-Path -LiteralPath $planBindingRestoreSidecars.Old) -and
        -not (Test-Path -LiteralPath $planBindingRegistryPath) -and
        -not (Test-Path -LiteralPath (Join-Path $planBindingWorkspace 'AGENTS.md'))) {
        Add-Check 'install recovery treats the atomic manifest as the only mutable restore plan, ignores stale journal mirrors, and resumes a restore-direction sidecar first'
    } else {
        Add-Failure 'stale legacy journal count and digest must not reject a valid atomic manifest restore plan'
    }
    [System.IO.File]::WriteAllText($planBindingJournalPath, ($planBindingJournal | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $planBindingRecoveredSnapshot = Get-FileSnapshot -Path $planBindingManifestPath
    $planBindingRecoveredRetry = Invoke-RepoScript -UserProfile $planBindingUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $planBindingManifestPath
        RepoRoot = $RepoRoot
    }
    $results.Add($planBindingRecoveredRetry) | Out-Null
    if ($planBindingRecoveredRetry.ExitCode -eq 0 -and
        -not (Test-Path -LiteralPath $planBindingJournalPath) -and
        (Test-SameSnapshot -Left $planBindingRecoveredSnapshot -Right (Get-FileSnapshot -Path $planBindingManifestPath)) -and
        -not (Test-Path -LiteralPath (Join-Path $planBindingWorkspace 'AGENTS.md'))) {
        Add-Check 'recovered manifest retry clears an immutable journal without recovery phase or target mutation'
    } else {
        Add-Failure 'recovered manifest retry must not require or rewrite recovery phase state'
    }

    $committedCrashUser = Join-Path $scratchRoot 'committed-before-registry-user'
    $committedCrashWorkspace = Join-Path $scratchRoot 'committed-before-registry-workspace'
    $committedCrashInstall = Invoke-RepoScript -UserProfile $committedCrashUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $committedCrashWorkspace
        RepoRoot = $RepoRoot
    }
    $committedCrashRegistryPath = Join-Path $committedCrashUser '.dev-harness\install-registry.json'
    $committedCrashRegistry = Read-JsonFile -Path $committedCrashRegistryPath
    $committedCrashEntry = @($committedCrashRegistry.workspaces.PSObject.Properties | Select-Object -First 1)
    $committedCrashManifestPath = [string]@($committedCrashEntry[0].Value.manifests)[-1]
    $committedCrashManifest = Read-JsonFile -Path $committedCrashManifestPath
    Remove-Item -LiteralPath $committedCrashRegistryPath -Force
    $committedCrashJournalPath = Join-Path $committedCrashUser '.dev-harness\install-transaction.json'
    $committedCrashJournal = [ordered]@{
        schema_version = 'install-transaction/v1.1'
        registry_schema_version = 'install-registry/v1.1'
        manifest_schema_version = 'install-manifest/v1.2'
        postimage_identity_contract = 'v1'
        user_profile = $committedCrashUser
        repo_root = $RepoRoot
        workspace_root = $committedCrashWorkspace
        registry_path = $committedCrashRegistryPath
        registry_preimage_sha256 = 'missing'
        manifest_path = $committedCrashManifestPath
        postimage_transaction_status_contract = 'v1'
        postimage_history_ownership_contract = 'v1'
        postimage_manifest_integrity_contract = 'sha256-v1'
        legacy_pointer_path = $null
        legacy_pointer_import_digest = $null
    }
    [System.IO.File]::WriteAllText($committedCrashJournalPath, ($committedCrashJournal | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $committedCrashRecovery = Invoke-RepoScript -UserProfile $committedCrashUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $committedCrashManifestPath
        RepoRoot = $RepoRoot
    }
    $committedCrashRecoveredManifest = Read-JsonFile -Path $committedCrashManifestPath
    $results.Add($committedCrashInstall) | Out-Null
    $results.Add($committedCrashRecovery) | Out-Null
    if ($committedCrashInstall.ExitCode -eq 0 -and
        $committedCrashRecovery.ExitCode -eq 0 -and
        $committedCrashRecoveredManifest.transaction_status -eq 'recovered' -and
        -not (Test-Path -LiteralPath $committedCrashRegistryPath) -and
        -not (Test-Path -LiteralPath $committedCrashJournalPath) -and
        -not (Test-Path -LiteralPath (Join-Path $committedCrashWorkspace 'AGENTS.md'))) {
        Add-Check 'explicit recovery rolls back a committed manifest when registry still equals the journal preimage'
    } else {
        Add-Failure 'committed-before-registry crash recovery must use the manifest plan and exact registry preimage'
    }

    $tupleUser = Join-Path $scratchRoot 'partial-tuple-user'
    $tupleWorkspace = Join-Path $scratchRoot 'partial-tuple-workspace'
    $tupleInstall = Invoke-RepoScript -UserProfile $tupleUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{ WorkspaceRoot = $tupleWorkspace; RepoRoot = $RepoRoot }
    $tupleRegistryPath = Join-Path $tupleUser '.dev-harness\install-registry.json'
    $tupleRegistry = Read-JsonFile -Path $tupleRegistryPath
    [void]$tupleRegistry.PSObject.Properties.Remove('manifest_integrity_contract')
    [System.IO.File]::WriteAllText($tupleRegistryPath, ($tupleRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tupleRegistrySnapshot = Get-FileSnapshot -Path $tupleRegistryPath
    $tupleWorkspaceSnapshot = Get-FileSnapshot -Path (Join-Path $tupleWorkspace 'AGENTS.md')
    $tupleBackupCount = @(Get-ChildItem -LiteralPath (Join-Path $tupleUser '.dev-harness\backups') -Directory).Count
    $tupleBlockedInstall = Invoke-RepoScript -UserProfile $tupleUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{ WorkspaceRoot = $tupleWorkspace; RepoRoot = $RepoRoot }
    $tupleBlockedUninstall = Invoke-RepoScript -UserProfile $tupleUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{ WorkspaceRoot = $tupleWorkspace; RepoRoot = $RepoRoot }
    $results.Add($tupleInstall) | Out-Null
    $results.Add($tupleBlockedInstall) | Out-Null
    $results.Add($tupleBlockedUninstall) | Out-Null
    if ($tupleInstall.ExitCode -eq 0 -and $tupleBlockedInstall.ExitCode -ne 0 -and $tupleBlockedUninstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tupleRegistrySnapshot -Right (Get-FileSnapshot -Path $tupleRegistryPath)) -and
        (Test-SameSnapshot -Left $tupleWorkspaceSnapshot -Right (Get-FileSnapshot -Path (Join-Path $tupleWorkspace 'AGENTS.md'))) -and
        @(Get-ChildItem -LiteralPath (Join-Path $tupleUser '.dev-harness\backups') -Directory).Count -eq $tupleBackupCount -and
        -not (Test-Path -LiteralPath (Join-Path $tupleUser '.dev-harness\install-transaction.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $tupleUser '.dev-harness\uninstall-transaction.json'))) {
        Add-Check 'partial modern registry tuple blocks install and uninstall before mutation'
    } else {
        Add-Failure 'partial modern registry tuple must never downgrade to legacy behavior'
    }

    $chainUser = Join-Path $scratchRoot 'restore-chain-user'
    $chainWorkspace = Join-Path $scratchRoot 'restore-chain-workspace'
    $chainInstallA = Invoke-RepoScript -UserProfile $chainUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{ WorkspaceRoot = $chainWorkspace; RepoRoot = $RepoRoot }
    $chainInstallB = Invoke-RepoScript -UserProfile $chainUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{ WorkspaceRoot = $chainWorkspace; RepoRoot = $RepoRoot }
    $chainRegistryPath = Join-Path $chainUser '.dev-harness\install-registry.json'
    $chainRegistry = Read-JsonFile -Path $chainRegistryPath
    $chainEntry = @($chainRegistry.workspaces.PSObject.Properties | Select-Object -First 1)
    $chainManifestPaths = @($chainEntry[0].Value.manifests)
    $chainOlderManifestPath = [string]$chainManifestPaths[0]
    $chainOlderManifest = Read-JsonFile -Path $chainOlderManifestPath
    $chainTargetPath = Join-Path $chainUser '.claude\CLAUDE.md'
    $chainRecord = @($chainOlderManifest.backups | Where-Object { (Get-NormalizedPath -Path $_.path) -eq (Get-NormalizedPath -Path $chainTargetPath) } | Select-Object -First 1)
    $chainRecord[0].expected_postimage.sha256 = ('0' * 64)
    [System.IO.File]::WriteAllText($chainOlderManifestPath, ($chainOlderManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    Set-RegistryManifestDigestForPath -Registry $chainRegistry -ManifestPath $chainOlderManifestPath
    [System.IO.File]::WriteAllText($chainRegistryPath, ($chainRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $chainRegistrySnapshot = Get-FileSnapshot -Path $chainRegistryPath
    $chainTargetSnapshot = Get-FileSnapshot -Path $chainTargetPath
    $chainReject = Invoke-RepoScript -UserProfile $chainUser -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{ WorkspaceRoot = $chainWorkspace; RepoRoot = $RepoRoot }
    $results.Add($chainInstallA) | Out-Null
    $results.Add($chainInstallB) | Out-Null
    $results.Add($chainReject) | Out-Null
    if ($chainInstallA.ExitCode -eq 0 -and $chainInstallB.ExitCode -eq 0 -and $chainReject.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $chainRegistrySnapshot -Right (Get-FileSnapshot -Path $chainRegistryPath)) -and
        (Test-SameSnapshot -Left $chainTargetSnapshot -Right (Get-FileSnapshot -Path $chainTargetPath)) -and
        -not (Test-Path -LiteralPath (Join-Path $chainUser '.dev-harness\uninstall-transaction.json'))) {
        Add-Check 'two-manifest restore chain rejects a tampered middle identity before the first restore'
    } else {
        Add-Failure 'restore-chain preflight must validate every historical identity before mutation'
    }

    $legacyBlockInstall = Invoke-RepoScript -UserProfile $recoveryUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $recoveryWorkspace
        RepoRoot = $RepoRoot
    }
    $recoveryRegistryPath = Join-Path $recoveryUserProfile '.dev-harness\install-registry.json'
    $recoveryWorkspaceAgentsPath = Join-Path $recoveryWorkspace 'AGENTS.md'
    $recoveryClaudePath = Join-Path $recoveryUserProfile '.claude\CLAUDE.md'
    $legacyBlockRegistry = Read-JsonFile -Path $recoveryRegistryPath
    $legacyBlockEntry = @($legacyBlockRegistry.workspaces.PSObject.Properties | Select-Object -First 1)
    $legacyBlockManifestPath = [string]@($legacyBlockEntry[0].Value.manifests)[-1]
    $legacyBlockManifest = Read-JsonFile -Path $legacyBlockManifestPath
    $legacyBlockManifest.schema_version = 'install-manifest/v1.1'
    [System.IO.File]::WriteAllText($legacyBlockManifestPath, ($legacyBlockManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    Set-RegistryManifestDigestForPath -Registry $legacyBlockRegistry -ManifestPath $legacyBlockManifestPath
    $legacyBlockRegistry.schema_version = 'install-registry/v1.0'
    [System.IO.File]::WriteAllText($recoveryRegistryPath, ($legacyBlockRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $legacyRegistrySnapshot = Get-FileSnapshot -Path $recoveryRegistryPath
    $legacyManifestSnapshot = Get-FileSnapshot -Path $legacyBlockManifestPath
    $legacyWorkspaceSnapshot = Get-FileSnapshot -Path $recoveryWorkspaceAgentsPath
    $legacyClaudeSnapshot = Get-FileSnapshot -Path $recoveryClaudePath
    $legacyBackupCount = @(Get-ChildItem -LiteralPath (Join-Path $recoveryUserProfile '.dev-harness\backups') -Directory).Count
    $legacyBlockedReinstall = Invoke-RepoScript -UserProfile $recoveryUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $recoveryWorkspace
        RepoRoot = $RepoRoot
    }
    $legacyBlockedUninstall = Invoke-RepoScript -UserProfile $recoveryUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $recoveryWorkspace
        RepoRoot = $RepoRoot
    }
    $results.Add($legacyBlockInstall) | Out-Null
    $results.Add($legacyBlockedReinstall) | Out-Null
    $results.Add($legacyBlockedUninstall) | Out-Null
    if ($legacyBlockInstall.ExitCode -eq 0 -and
        $legacyBlockedReinstall.ExitCode -ne 0 -and
        $legacyBlockedUninstall.ExitCode -ne 0 -and
        (@($legacyBlockedReinstall.Output) -join "`n") -match 'LIVE_UPDATE_REQUIRED: legacy-install-state' -and
        (@($legacyBlockedUninstall.Output) -join "`n") -match 'LIVE_UPDATE_REQUIRED: legacy-install-state' -and
        (Test-SameSnapshot -Left $legacyRegistrySnapshot -Right (Get-FileSnapshot -Path $recoveryRegistryPath)) -and
        (Test-SameSnapshot -Left $legacyManifestSnapshot -Right (Get-FileSnapshot -Path $legacyBlockManifestPath)) -and
        (Test-SameSnapshot -Left $legacyWorkspaceSnapshot -Right (Get-FileSnapshot -Path $recoveryWorkspaceAgentsPath)) -and
        (Test-SameSnapshot -Left $legacyClaudeSnapshot -Right (Get-FileSnapshot -Path $recoveryClaudePath)) -and
        @(Get-ChildItem -LiteralPath (Join-Path $recoveryUserProfile '.dev-harness\backups') -Directory).Count -eq $legacyBackupCount -and
        -not (Test-Path -LiteralPath (Join-Path $recoveryUserProfile '.dev-harness\install-transaction.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $recoveryUserProfile '.dev-harness\uninstall-transaction.json'))) {
        Add-Check 'legacy v1.0 registry plus v1.1 manifest stack blocks install and uninstall without mutation'
    } else {
        Add-Failure 'legacy install state must be a write-free rollout blocker'
    }


    $RepoRoot = $sourceRoot
    foreach ($ownerRepo in @($ownerRepoA,$ownerRepoB)) {
        foreach ($directoryName in @('agent-configs','runtime-hooks','vault-template','skills','scripts')) {
            Copy-Item -LiteralPath (Join-Path $RepoRoot $directoryName) -Destination $ownerRepo -Recurse -Force
        }
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'install.ps1') -Destination (Join-Path $ownerRepo 'install.ps1') -Force
        New-Item -ItemType Directory -Path (Join-Path $ownerRepo 'tests') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests\forbidden-path-prefixes.txt') -Destination (Join-Path $ownerRepo 'tests\forbidden-path-prefixes.txt') -Force
    }
    $ownerInstallA = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $ownerWorkspaceA
        RepoRoot = $ownerRepoA
    }
    $ownerInstallB = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $ownerWorkspaceB
        RepoRoot = $ownerRepoB
    }
    $ownerClaudeLink = Join-Path $ownerUserProfile '.claude\skills\entry-router'
    $ownerBeforeUninstall = Get-TestJunctionTarget -Path $ownerClaudeLink
    $ownerRegistryPath = Join-Path $ownerUserProfile '.dev-harness\install-registry.json'
    $ownerRegistryBeforeBlockedHandoff = Get-FileSnapshot -Path $ownerRegistryPath
    $ownerWorkspaceBBeforeBlockedHandoff = Get-FileSnapshot -Path (Join-Path $ownerWorkspaceB 'AGENTS.md')
    $ownerUnavailableTarget = Join-Path $ownerRepoA 'skills\entry-router'
    $ownerUnavailableHoldingPath = Join-Path $ownerRepoA 'skills\entry-router.unavailable'
    Move-Item -LiteralPath $ownerUnavailableTarget -Destination $ownerUnavailableHoldingPath
    try {
        $ownerBlockedUninstall = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
            WorkspaceRoot = $ownerWorkspaceB
            RepoRoot = $ownerRepoB
        }
    } finally {
        Move-Item -LiteralPath $ownerUnavailableHoldingPath -Destination $ownerUnavailableTarget
    }
    $results.Add($ownerBlockedUninstall) | Out-Null
    if ($ownerBlockedUninstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $ownerRegistryBeforeBlockedHandoff -Right (Get-FileSnapshot -Path $ownerRegistryPath)) -and
        (Test-SameSnapshot -Left $ownerWorkspaceBBeforeBlockedHandoff -Right (Get-FileSnapshot -Path (Join-Path $ownerWorkspaceB 'AGENTS.md'))) -and
        (Get-TestJunctionTarget -Path $ownerClaudeLink) -eq $ownerBeforeUninstall) {
        Add-Check 'owner handoff rejects a missing link target before changing workspace, registry, or active links'
    } else {
        Add-Failure 'owner handoff should fail closed when a link target to be restored is unavailable'
    }
    $ownerRegistryCommitLock = [System.IO.File]::Open($ownerRegistryPath, 'Open', 'Read', 'ReadWrite')
    try {
        $ownerInterruptedUninstall = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
            WorkspaceRoot = $ownerWorkspaceB
            RepoRoot = $ownerRepoB
        }
    } finally {
        $ownerRegistryCommitLock.Dispose()
    }
    $ownerUninstallJournalPath = Join-Path $ownerUserProfile '.dev-harness\uninstall-transaction.json'
    $results.Add($ownerInterruptedUninstall) | Out-Null
    if ($ownerInterruptedUninstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $ownerRegistryBeforeBlockedHandoff -Right (Get-FileSnapshot -Path $ownerRegistryPath)) -and
        (Test-Path -LiteralPath $ownerUninstallJournalPath -PathType Leaf) -and
        (Get-TestJunctionTarget -Path $ownerClaudeLink) -eq (Get-NormalizedPath -Path (Join-Path $ownerRepoA 'skills\entry-router'))) {
        Add-Check 'failed registry commit leaves a durable uninstall intent after restoring owner links'
    } else {
        Add-Failure 'an interrupted owner handoff should preserve a resumable intent with the pre-commit registry'
    }
    $ownerJournalRaw = Get-Content -LiteralPath $ownerUninstallJournalPath -Raw -Encoding utf8
    $ownerJournalDocument = $ownerJournalRaw | ConvertFrom-Json
    $ownerJournalManifestPath = [string]@($ownerJournalDocument.fully_consumed_manifest_paths)[-1]
    $ownerJournalManifestRaw = Get-Content -LiteralPath $ownerJournalManifestPath -Raw -Encoding utf8
    $ownerJournalTamperedManifest = $ownerJournalManifestRaw | ConvertFrom-Json
    $ownerJournalTamperedManifest | Add-Member -NotePropertyName 'post_journal_tamper' -NotePropertyValue 'reject-me'
    [System.IO.File]::WriteAllText($ownerJournalManifestPath, ($ownerJournalTamperedManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $ownerJournalBeforeTamperResume = Get-FileSnapshot -Path $ownerUninstallJournalPath
    $ownerRegistryBeforeTamperResume = Get-FileSnapshot -Path $ownerRegistryPath
    $ownerTamperedResume = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $ownerRepoB
    }
    $results.Add($ownerTamperedResume) | Out-Null
    if ($ownerTamperedResume.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $ownerJournalBeforeTamperResume -Right (Get-FileSnapshot -Path $ownerUninstallJournalPath)) -and
        (Test-SameSnapshot -Left $ownerRegistryBeforeTamperResume -Right (Get-FileSnapshot -Path $ownerRegistryPath))) {
        Add-Check 'uninstall resume revalidates journal-bound manifest content before mutation'
    } else {
        Add-Failure 'pending uninstall resume must reject manifest changes made after journal preparation'
    }
    [System.IO.File]::WriteAllText($ownerJournalManifestPath, $ownerJournalManifestRaw, (New-Object System.Text.UTF8Encoding($false)))
    $ownerForeignRepoResume = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $ownerRepoA
    }
    $results.Add($ownerForeignRepoResume) | Out-Null
    if ($ownerForeignRepoResume.ExitCode -ne 0 -and (Test-Path -LiteralPath $ownerUninstallJournalPath -PathType Leaf)) {
        Add-Check 'uninstall resume rejects a RepoRoot that does not own the prepared transaction'
    } else {
        Add-Failure 'journal resume must preserve the original RepoRoot ownership boundary'
    }
    $ownerWorkspaceKeyTamper = $ownerJournalRaw | ConvertFrom-Json
    $ownerWorkspaceKeyTamper.workspace_key = [string]@($ownerWorkspaceKeyTamper.remaining_workspace_keys)[0]
    [System.IO.File]::WriteAllText($ownerUninstallJournalPath, ($ownerWorkspaceKeyTamper | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $ownerWorkspaceKeyTamperSnapshot = Get-FileSnapshot -Path $ownerUninstallJournalPath
    $ownerRegistryBeforeWorkspaceKeyTamper = Get-FileSnapshot -Path $ownerRegistryPath
    $ownerWorkspaceKeyTamperResume = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $ownerRepoB
    }
    $results.Add($ownerWorkspaceKeyTamperResume) | Out-Null
    if ($ownerWorkspaceKeyTamperResume.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $ownerWorkspaceKeyTamperSnapshot -Right (Get-FileSnapshot -Path $ownerUninstallJournalPath)) -and
        (Test-SameSnapshot -Left $ownerRegistryBeforeWorkspaceKeyTamper -Right (Get-FileSnapshot -Path $ownerRegistryPath))) {
        Add-Check 'uninstall resume derives the workspace target from the registry preimage'
    } else {
        Add-Failure 'journal workspace_key tampering must fail before registry or journal mutation'
    }
    [System.IO.File]::WriteAllText($ownerUninstallJournalPath, $ownerJournalRaw, (New-Object System.Text.UTF8Encoding($false)))

    $ownerConsumedPathTamper = $ownerJournalRaw | ConvertFrom-Json
    $ownerConsumedPathTamper.fully_consumed_manifest_paths = @()
    [System.IO.File]::WriteAllText($ownerUninstallJournalPath, ($ownerConsumedPathTamper | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $ownerConsumedPathTamperSnapshot = Get-FileSnapshot -Path $ownerUninstallJournalPath
    $ownerRegistryBeforeConsumedPathTamper = Get-FileSnapshot -Path $ownerRegistryPath
    $ownerConsumedPathTamperResume = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $ownerRepoB
    }
    $results.Add($ownerConsumedPathTamperResume) | Out-Null
    if ($ownerConsumedPathTamperResume.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $ownerConsumedPathTamperSnapshot -Right (Get-FileSnapshot -Path $ownerUninstallJournalPath)) -and
        (Test-SameSnapshot -Left $ownerRegistryBeforeConsumedPathTamper -Right (Get-FileSnapshot -Path $ownerRegistryPath))) {
        Add-Check 'uninstall resume derives the complete tombstone set from the registry preimage'
    } else {
        Add-Failure 'journal consumed-manifest omission must fail before registry or journal mutation'
    }
    [System.IO.File]::WriteAllText($ownerUninstallJournalPath, $ownerJournalRaw, (New-Object System.Text.UTF8Encoding($false)))

    $ownerRetainedManifestPath = [string]@(($ownerJournalRaw | ConvertFrom-Json).updated_global_history)[-1]
    $ownerRetainedManifestRaw = Get-Content -LiteralPath $ownerRetainedManifestPath -Raw -Encoding utf8
    $ownerRetainedManifestTamper = $ownerRetainedManifestRaw | ConvertFrom-Json
    $ownerRetainedManifestTamper | Add-Member -NotePropertyName 'retained_owner_tamper' -NotePropertyValue 'reject-me'
    [System.IO.File]::WriteAllText($ownerRetainedManifestPath, ($ownerRetainedManifestTamper | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $ownerJournalBeforeRetainedTamperResume = Get-FileSnapshot -Path $ownerUninstallJournalPath
    $ownerRegistryBeforeRetainedTamperResume = Get-FileSnapshot -Path $ownerRegistryPath
    $ownerRetainedTamperResume = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $ownerRepoB
    }
    $results.Add($ownerRetainedTamperResume) | Out-Null
    if ($ownerRetainedTamperResume.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $ownerJournalBeforeRetainedTamperResume -Right (Get-FileSnapshot -Path $ownerUninstallJournalPath)) -and
        (Test-SameSnapshot -Left $ownerRegistryBeforeRetainedTamperResume -Right (Get-FileSnapshot -Path $ownerRegistryPath))) {
        Add-Check 'uninstall resume revalidates the retained handoff owner manifest'
    } else {
        Add-Failure 'retained owner manifest tampering must fail before registry or journal mutation'
    }
    [System.IO.File]::WriteAllText($ownerRetainedManifestPath, $ownerRetainedManifestRaw, (New-Object System.Text.UTF8Encoding($false)))

    $ownerPendingInstallRegistrySnapshot = Get-FileSnapshot -Path $ownerRegistryPath
    $ownerPendingInstallJournalSnapshot = Get-FileSnapshot -Path $ownerUninstallJournalPath
    $ownerPendingInstall = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $ownerWorkspaceA
        RepoRoot = $ownerRepoA
    }
    $results.Add($ownerPendingInstall) | Out-Null
    if ($ownerPendingInstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $ownerPendingInstallRegistrySnapshot -Right (Get-FileSnapshot -Path $ownerRegistryPath)) -and
        (Test-SameSnapshot -Left $ownerPendingInstallJournalSnapshot -Right (Get-FileSnapshot -Path $ownerUninstallJournalPath))) {
        Add-Check 'install fails closed while a durable uninstall intent is pending'
    } else {
        Add-Failure 'install must not invalidate the registry preimage of a pending uninstall transaction'
    }
    $ownerUninstallB = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $ownerRepoB
    }
    $ownerCommittedRegistryRaw = Get-Content -LiteralPath $ownerRegistryPath -Raw -Encoding utf8
    $ownerCommittedRetainedRaw = Get-Content -LiteralPath $ownerRetainedManifestPath -Raw -Encoding utf8
    [System.IO.File]::WriteAllText($ownerUninstallJournalPath, $ownerJournalRaw, (New-Object System.Text.UTF8Encoding($false)))
    $ownerStrippedPostimage = $ownerCommittedRegistryRaw | ConvertFrom-Json
    [void]$ownerStrippedPostimage.PSObject.Properties.Remove('history_ownership_contract')
    [void]$ownerStrippedPostimage.PSObject.Properties.Remove('manifest_integrity_contract')
    [void]$ownerStrippedPostimage.PSObject.Properties.Remove('manifest_digests')
    [System.IO.File]::WriteAllText($ownerRegistryPath, ($ownerStrippedPostimage | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $ownerCommittedRetainedTamper = $ownerCommittedRetainedRaw | ConvertFrom-Json
    $ownerCommittedRetainedTamper | Add-Member -NotePropertyName 'committed_postimage_tamper' -NotePropertyValue 'reject-me'
    [System.IO.File]::WriteAllText($ownerRetainedManifestPath, ($ownerCommittedRetainedTamper | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $ownerStrippedRegistrySnapshot = Get-FileSnapshot -Path $ownerRegistryPath
    $ownerStrippedManifestSnapshot = Get-FileSnapshot -Path $ownerRetainedManifestPath
    $ownerStrippedCommittedResume = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $ownerRepoB
    }
    $results.Add($ownerStrippedCommittedResume) | Out-Null
    if ($ownerStrippedCommittedResume.ExitCode -ne 0 -and
        (Test-Path -LiteralPath $ownerUninstallJournalPath -PathType Leaf) -and
        (Test-SameSnapshot -Left $ownerStrippedRegistrySnapshot -Right (Get-FileSnapshot -Path $ownerRegistryPath)) -and
        (Test-SameSnapshot -Left $ownerStrippedManifestSnapshot -Right (Get-FileSnapshot -Path $ownerRetainedManifestPath))) {
        Add-Check 'committed journal cleanup rejects a contract-stripped or tampered registry postimage'
    } else {
        Add-Failure 'committed journal cleanup must require the exact v1 sha256 postimage contract'
    }
    [System.IO.File]::WriteAllText($ownerRegistryPath, $ownerCommittedRegistryRaw, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($ownerRetainedManifestPath, $ownerCommittedRetainedRaw, (New-Object System.Text.UTF8Encoding($false)))
    $ownerCommittedJournalCleanup = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $ownerRepoB
    }
    $results.Add($ownerCommittedJournalCleanup) | Out-Null
    $ownerRegistry = Read-JsonFile -Path $ownerRegistryPath
    $ownerEntries = @()
    if ($null -ne $ownerRegistry) {
        $ownerEntries = @($ownerRegistry.workspaces.PSObject.Properties)
    }
    $ownerExpectedTargets = @(
        Join-Path $ownerRepoA 'skills\entry-router'
        Join-Path $ownerRepoA 'skills\entry-router'
        Join-Path $ownerRepoA 'skills\entry-router'
    )
    $ownerActualTargets = @(
        Get-TestJunctionTarget -Path (Join-Path $ownerUserProfile '.claude\skills\entry-router')
        Get-TestJunctionTarget -Path (Join-Path $ownerUserProfile '.codex\skills\entry-router')
        Get-TestJunctionTarget -Path (Join-Path $ownerUserProfile '.agents\skills\entry-router')
    )
    $ownerVerifyA = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $ownerWorkspaceA
        RepoRoot = $ownerRepoA
        Scope = 'All'
    }
    $ownerHistory = @()
    if ($null -ne $ownerRegistry) {
        $ownerHistory = @($ownerRegistry.global_manifest_history)
    }
    $results.Add($ownerInstallA) | Out-Null
    $results.Add($ownerInstallB) | Out-Null
    $results.Add($ownerUninstallB) | Out-Null
    if ($ownerInstallA.ExitCode -eq 0 -and
        $ownerInstallB.ExitCode -eq 0 -and
        $ownerBeforeUninstall -eq (Get-NormalizedPath -Path (Join-Path $ownerRepoB 'skills\entry-router')) -and
        $ownerUninstallB.ExitCode -eq 0 -and
        $ownerCommittedJournalCleanup.ExitCode -eq 0 -and
        -not (Test-Path -LiteralPath $ownerUninstallJournalPath) -and
        $ownerEntries.Count -eq 1 -and
        (Get-NormalizedPath -Path $ownerEntries[0].Value.workspace_root) -eq $ownerWorkspaceA -and
        (Get-NormalizedPath -Path $ownerEntries[0].Value.repo_root) -eq $ownerRepoA -and
        $ownerHistory.Count -gt 0 -and
        @($ownerActualTargets | ForEach-Object -Begin { $index = 0 } -Process { $matches = $_ -eq (Get-NormalizedPath -Path $ownerExpectedTargets[$index]); $index++; $matches } | Where-Object { -not $_ }).Count -eq 0 -and
        $ownerVerifyA.ExitCode -eq 0 -and
        @($ownerVerifyA.Output | Where-Object { [string]$_ -ceq 'STATUS: PASS' }).Count -eq 1) {
        Add-Check 'uninstalling the active RepoRoot owner atomically hands all user-global links back to the latest remaining workspace owner'
    } else {
        Add-Failure ("active owner handoff should relink to RepoA and leave A valid; installs={0},{1}, uninstall={2}, cleanup={3}, entries={4}, verify={5}, targets={6}, uninstall_output={7}, cleanup_output={8}" -f $ownerInstallA.ExitCode,$ownerInstallB.ExitCode,$ownerUninstallB.ExitCode,$ownerCommittedJournalCleanup.ExitCode,$ownerEntries.Count,$ownerVerifyA.ExitCode,(@($ownerActualTargets) -join ','),(@($ownerUninstallB.Output) -join ' | '),(@($ownerCommittedJournalCleanup.Output) -join ' | '))
    }

    $ownerRegistryBeforeRepoConflict = Get-FileSnapshot -Path $ownerRegistryPath
    $ownerWorkspaceBeforeRepoConflict = Get-FileSnapshot -Path (Join-Path $ownerWorkspaceA 'AGENTS.md')
    $ownerLinkBeforeRepoConflict = Get-TestJunctionTarget -Path $ownerClaudeLink
    $ownerRepoConflictInstall = Invoke-RepoScript -UserProfile $ownerUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $ownerWorkspaceA
        RepoRoot = $ownerRepoB
    }
    $results.Add($ownerRepoConflictInstall) | Out-Null
    if ($ownerRepoConflictInstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $ownerRegistryBeforeRepoConflict -Right (Get-FileSnapshot -Path $ownerRegistryPath)) -and
        (Test-SameSnapshot -Left $ownerWorkspaceBeforeRepoConflict -Right (Get-FileSnapshot -Path (Join-Path $ownerWorkspaceA 'AGENTS.md'))) -and
        (Get-TestJunctionTarget -Path $ownerClaudeLink) -eq $ownerLinkBeforeRepoConflict) {
        Add-Check 'same-workspace cross-RepoRoot install is rejected before registry, workspace, or active-link mutation'
    } else {
        Add-Failure 'same-workspace RepoRoot rollover should fail closed instead of creating mixed-owner history'
    }

    $RepoRoot = $thinRepoRoot
    $receiptRepoA = $thinRepoA
    $receiptRepoB = $thinRepoB
    $receiptUserProfile = Join-Path $scratchRoot 'multi-repo-receipt-user'
    $receiptWorkspaceA = Join-Path $scratchRoot 'multi-repo-receipt-workspace-a'
    $receiptWorkspaceB = Join-Path $scratchRoot 'multi-repo-receipt-workspace-b'
    New-Item -ItemType Directory -Path $receiptUserProfile,$receiptWorkspaceA,$receiptWorkspaceB -Force | Out-Null
    $receiptInstallA = Invoke-RepoScript -UserProfile $receiptUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $receiptWorkspaceA
        RepoRoot = $receiptRepoA
    }
    $receiptInstallB = Invoke-RepoScript -UserProfile $receiptUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $receiptWorkspaceB
        RepoRoot = $receiptRepoB
    }
    $receiptRegistryPath = Join-Path $receiptUserProfile '.dev-harness\install-registry.json'
    $receiptRegistry = Read-JsonFile -Path $receiptRegistryPath
    $receiptEntryA = @($receiptRegistry.workspaces.PSObject.Properties | Where-Object {
            (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $receiptWorkspaceA
        })[0].Value
    $receiptEntryB = @($receiptRegistry.workspaces.PSObject.Properties | Where-Object {
            (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $receiptWorkspaceB
        })[0].Value
    $receiptManifestPathA = [string]@($receiptEntryA.manifests)[-1]
    $receiptManifestPathB = [string]@($receiptEntryB.manifests)[-1]
    $receiptPointerPathA = Join-Path $receiptRepoA 'backups\active-install.json'
    $receiptPointerPathB = Join-Path $receiptRepoB 'backups\active-install.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $receiptPointerPathA),(Split-Path -Parent $receiptPointerPathB) -Force | Out-Null
    [System.IO.File]::WriteAllText($receiptPointerPathA, 'retired-pointer-a', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($receiptPointerPathB, 'retired-pointer-b', (New-Object System.Text.UTF8Encoding($false)))
    $receiptPointerDigestA = Get-InstallStateFileDigest -Path $receiptPointerPathA
    $receiptPointerDigestB = Get-InstallStateFileDigest -Path $receiptPointerPathB
    $receiptManifestA = Read-JsonFile -Path $receiptManifestPathA
    $receiptManifestB = Read-JsonFile -Path $receiptManifestPathB
    $receiptManifestA | Add-Member -NotePropertyName 'legacy_rebaseline_receipt' -NotePropertyValue ([ordered]@{
            contract = 'legacy_rebaseline/v1'
            plan_digest = (('a' * 64) -join '')
            legacy_pointer_path = $receiptPointerPathA
            legacy_pointer_sha256 = $receiptPointerDigestA
            source_registry_sha256 = (('b' * 64) -join '')
        }) -Force
    $receiptManifestB | Add-Member -NotePropertyName 'legacy_rebaseline_receipt' -NotePropertyValue ([ordered]@{
            contract = 'legacy_rebaseline/v1'
            plan_digest = (('c' * 64) -join '')
            legacy_pointer_path = $receiptPointerPathB
            legacy_pointer_sha256 = $receiptPointerDigestB
            source_registry_sha256 = (('d' * 64) -join '')
        }) -Force
    [System.IO.File]::WriteAllText($receiptManifestPathA, ($receiptManifestA | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($receiptManifestPathB, ($receiptManifestB | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    Set-RegistryManifestDigestForPath -Registry $receiptRegistry -ManifestPath $receiptManifestPathA
    Set-RegistryManifestDigestForPath -Registry $receiptRegistry -ManifestPath $receiptManifestPathB
    [System.IO.File]::WriteAllText($receiptRegistryPath, ($receiptRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))

    $receiptMarkerPathA = Get-LegacyPointerMigrationMarkerPath -UserProfile $receiptUserProfile -PointerPath $receiptPointerPathA
    $receiptMarkerPathB = Get-LegacyPointerMigrationMarkerPath -UserProfile $receiptUserProfile -PointerPath $receiptPointerPathB
    $receiptUninstallA = Invoke-RepoScript -UserProfile $receiptUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $receiptWorkspaceA
        RepoRoot = $receiptRepoA
    }
    $receiptMarkerAAfterFirstUninstall = if (Test-Path -LiteralPath $receiptMarkerPathA -PathType Leaf) {
        [System.IO.File]::ReadAllText($receiptMarkerPathA).Trim()
    } else { '' }
    Remove-Item -LiteralPath $receiptMarkerPathA -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $receiptMarkerPathB -Force | Out-Null
    $receiptRegistryBeforeBlockedFinal = Get-FileSnapshot -Path $receiptRegistryPath
    $receiptWorkspaceBeforeBlockedFinal = Get-FileSnapshot -Path (Join-Path $receiptWorkspaceB 'AGENTS.md')
    $receiptOwnerLinkBeforeBlockedFinal = Get-TestJunctionTarget -Path (Join-Path $receiptUserProfile '.claude\skills\entry-router')
    try {
        $receiptBlockedFinalUninstall = Invoke-RepoScript -UserProfile $receiptUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
            WorkspaceRoot = $receiptWorkspaceB
            RepoRoot = $receiptRepoB
        }
        $receiptBlockedFinalKeptMarkerDirectory = Test-Path -LiteralPath $receiptMarkerPathB -PathType Container
    } finally {
        Remove-Item -LiteralPath $receiptMarkerPathB -Recurse -Force
    }
    $receiptUninstallJournalPath = Join-Path $receiptUserProfile '.dev-harness\uninstall-transaction.json'
    $receiptBlockedFinalWasWriteFree =
        $receiptBlockedFinalUninstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $receiptRegistryBeforeBlockedFinal -Right (Get-FileSnapshot -Path $receiptRegistryPath)) -and
        (Test-SameSnapshot -Left $receiptWorkspaceBeforeBlockedFinal -Right (Get-FileSnapshot -Path (Join-Path $receiptWorkspaceB 'AGENTS.md'))) -and
        (Get-TestJunctionTarget -Path (Join-Path $receiptUserProfile '.claude\skills\entry-router')) -eq $receiptOwnerLinkBeforeBlockedFinal -and
        (Test-Path -LiteralPath $receiptUninstallJournalPath -PathType Leaf) -and
        $receiptBlockedFinalKeptMarkerDirectory -and
        -not (Test-Path -LiteralPath $receiptMarkerPathA)
    $receiptResumedFinalUninstall = Invoke-RepoScript -UserProfile $receiptUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $receiptRepoB
    }
    $receiptMarkerAAfterResume = if (Test-Path -LiteralPath $receiptMarkerPathA -PathType Leaf) {
        [System.IO.File]::ReadAllText($receiptMarkerPathA).Trim()
    } else { '' }
    $receiptMarkerBAfterResume = if (Test-Path -LiteralPath $receiptMarkerPathB -PathType Leaf) {
        [System.IO.File]::ReadAllText($receiptMarkerPathB).Trim()
    } else { '' }
    Remove-Item -LiteralPath $receiptPointerPathA,$receiptPointerPathB -Force -ErrorAction SilentlyContinue
    $results.Add($receiptInstallA) | Out-Null
    $results.Add($receiptInstallB) | Out-Null
    $results.Add($receiptUninstallA) | Out-Null
    $results.Add($receiptBlockedFinalUninstall) | Out-Null
    $results.Add($receiptResumedFinalUninstall) | Out-Null
    if ($receiptInstallA.ExitCode -eq 0 -and
        $receiptInstallB.ExitCode -eq 0 -and
        $receiptUninstallA.ExitCode -eq 0 -and
        $receiptMarkerAAfterFirstUninstall -eq $receiptPointerDigestA -and
        $receiptBlockedFinalWasWriteFree -and
        $receiptResumedFinalUninstall.ExitCode -eq 0 -and
        -not (Test-Path -LiteralPath $receiptRegistryPath) -and
        -not (Test-Path -LiteralPath $receiptUninstallJournalPath) -and
        $receiptMarkerAAfterResume -eq $receiptPointerDigestA -and
        $receiptMarkerBAfterResume -eq $receiptPointerDigestB) {
        Add-Check 'last-workspace resume publishes independently bound receipt markers for multiple RepoRoots before restore'
    } else {
        Add-Failure ("multi-RepoRoot receipt uninstall must group marker intents by manifest RepoRoot and resume safely; installs={0},{1}; uninstall_a={2}; blocked={3}; write_free={4}; resume={5}; markers={6},{7}; outputs={8} / {9}" -f $receiptInstallA.ExitCode,$receiptInstallB.ExitCode,$receiptUninstallA.ExitCode,$receiptBlockedFinalUninstall.ExitCode,$receiptBlockedFinalWasWriteFree,$receiptResumedFinalUninstall.ExitCode,$receiptMarkerAAfterResume,$receiptMarkerBAfterResume,(@($receiptBlockedFinalUninstall.Output) -join ' | '),(@($receiptResumedFinalUninstall.Output) -join ' | '))
    }

    $unregisteredInstall = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $unregisteredWorkspace
        RepoRoot = $receiptRepoB
    }
    $unregisteredRegistryPath = Join-Path $unregisteredUserProfile '.dev-harness\install-registry.json'
    $unregisteredRegistry = Read-JsonFile -Path $unregisteredRegistryPath
    $unregisteredEntry = @($unregisteredRegistry.workspaces.PSObject.Properties | Select-Object -First 1)
    $unregisteredManifestPath = [string]@($unregisteredEntry[0].Value.manifests)[-1]
    Remove-Item -LiteralPath $unregisteredRegistryPath -Force
    $unregisteredWorkspaceSnapshot = Get-FileSnapshot -Path (Join-Path $unregisteredWorkspace 'AGENTS.md')
    $unregisteredClaudeSnapshot = Get-FileSnapshot -Path (Join-Path $unregisteredUserProfile '.claude\CLAUDE.md')
    $wrongRepoUninstall = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        ManifestPath = $unregisteredManifestPath
        RepoRoot = $receiptRepoA
    }
    $unregisteredManifestOriginal = Get-Content -LiteralPath $unregisteredManifestPath -Raw -Encoding utf8
    $failedUnregisteredManifest = $unregisteredManifestOriginal | ConvertFrom-Json
    $failedUnregisteredManifest.transaction_status = 'failed'
    [System.IO.File]::WriteAllText($unregisteredManifestPath, ($failedUnregisteredManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $failedUnregisteredRaw = Get-Content -LiteralPath $unregisteredManifestPath -Raw -Encoding utf8
    $ordinaryFailedUninstall = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        ManifestPath = $unregisteredManifestPath
        RepoRoot = $receiptRepoB
    }
    $aliasManifestPath = Join-Path (Split-Path -Parent $unregisteredManifestPath) 'recovery-alias.json'
    [System.IO.File]::WriteAllText($aliasManifestPath, $failedUnregisteredRaw, (New-Object System.Text.UTF8Encoding($false)))
    $aliasRecovery = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $aliasManifestPath
        RepoRoot = $receiptRepoB
    }
    $invalidItemManifest = $failedUnregisteredRaw | ConvertFrom-Json
    $invalidItemManifest.backups[0].item_type = 'unknown-item'
    [System.IO.File]::WriteAllText($unregisteredManifestPath, ($invalidItemManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $invalidItemRecovery = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $unregisteredManifestPath
        RepoRoot = $receiptRepoB
    }
    $duplicateTargetManifest = $failedUnregisteredRaw | ConvertFrom-Json
    $duplicateTargetManifest.backups = @($duplicateTargetManifest.backups + $duplicateTargetManifest.backups[0])
    [System.IO.File]::WriteAllText($unregisteredManifestPath, ($duplicateTargetManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $duplicateTargetRecovery = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $unregisteredManifestPath
        RepoRoot = $receiptRepoB
    }
    $unregisteredInvalidAttemptsWereWriteFree = `
        (Test-SameSnapshot -Left $unregisteredWorkspaceSnapshot -Right (Get-FileSnapshot -Path (Join-Path $unregisteredWorkspace 'AGENTS.md'))) -and
        (Test-SameSnapshot -Left $unregisteredClaudeSnapshot -Right (Get-FileSnapshot -Path (Join-Path $unregisteredUserProfile '.claude\CLAUDE.md'))) -and
        -not (Test-Path -LiteralPath $unregisteredRegistryPath)
    [System.IO.File]::WriteAllText($unregisteredManifestPath, $failedUnregisteredRaw, (New-Object System.Text.UTF8Encoding($false)))
    $validUnregisteredRecovery = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $unregisteredManifestPath
        RepoRoot = $receiptRepoB
    }
    $validRecoveredManifest = Read-JsonFile -Path $unregisteredManifestPath
    $results.Add($unregisteredInstall) | Out-Null
    $results.Add($wrongRepoUninstall) | Out-Null
    $results.Add($ordinaryFailedUninstall) | Out-Null
    $results.Add($aliasRecovery) | Out-Null
    $results.Add($invalidItemRecovery) | Out-Null
    $results.Add($duplicateTargetRecovery) | Out-Null
    $results.Add($validUnregisteredRecovery) | Out-Null
    if ($unregisteredInstall.ExitCode -eq 0 -and
        $wrongRepoUninstall.ExitCode -ne 0 -and
        $ordinaryFailedUninstall.ExitCode -ne 0 -and
        $aliasRecovery.ExitCode -ne 0 -and
        $invalidItemRecovery.ExitCode -ne 0 -and
        $duplicateTargetRecovery.ExitCode -ne 0 -and
        $unregisteredInvalidAttemptsWereWriteFree -and
        $validUnregisteredRecovery.ExitCode -eq 0 -and
        $validRecoveredManifest.transaction_status -eq 'recovered' -and
        -not (Test-Path -LiteralPath $unregisteredRegistryPath)) {
        Add-Check 'unregistered manifests enforce repo/status/exact-path/record schema before the explicit recovery path can mutate state'
    } else {
        Add-Failure ("unregistered recovery identity should fail closed before a valid explicit recovery; install={0}, wrong_repo={1}, ordinary_failed={2}, alias={3}, item={4}, duplicate={5}, recovery={6}" -f $unregisteredInstall.ExitCode,$wrongRepoUninstall.ExitCode,$ordinaryFailedUninstall.ExitCode,$aliasRecovery.ExitCode,$invalidItemRecovery.ExitCode,$duplicateTargetRecovery.ExitCode,$validUnregisteredRecovery.ExitCode)
    }

    $interruptedManifest = $unregisteredManifestOriginal | ConvertFrom-Json
    $interruptedManifest.transaction_status = 'in-progress'
    [System.IO.File]::WriteAllText($unregisteredManifestPath, ($interruptedManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $inProgressRecovery = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $unregisteredManifestPath
        RepoRoot = $receiptRepoB
    }
    $inProgressRecoveredManifest = Read-JsonFile -Path $unregisteredManifestPath
    [System.IO.File]::WriteAllText($unregisteredManifestPath, $unregisteredManifestOriginal, (New-Object System.Text.UTF8Encoding($false)))
    $orphanCommittedRecovery = Invoke-RepoScript -UserProfile $unregisteredUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RecoveryManifestPath = $unregisteredManifestPath
        RepoRoot = $receiptRepoB
    }
    $orphanCommittedRecoveredManifest = Read-JsonFile -Path $unregisteredManifestPath
    $results.Add($inProgressRecovery) | Out-Null
    $results.Add($orphanCommittedRecovery) | Out-Null
    if ($inProgressRecovery.ExitCode -eq 0 -and
        $inProgressRecoveredManifest.transaction_status -eq 'recovered' -and
        $orphanCommittedRecovery.ExitCode -eq 0 -and
        $orphanCommittedRecoveredManifest.transaction_status -eq 'recovered') {
        Add-Check 'explicit recovery accepts identity-bound unregistered in-progress and committed-orphan install manifests'
    } else {
        Add-Failure 'hard-interrupted install manifests should have an explicit, identity-bound recovery path'
    }

    $legacyInstallFirst = Invoke-RepoScript -UserProfile $legacyUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $legacyWorkspace
        RepoRoot = $receiptRepoA
    }
    $legacyRegistryPath = Join-Path $legacyUserProfile '.dev-harness\install-registry.json'
    $legacyRegistryFirst = Read-JsonFile -Path $legacyRegistryPath
    $legacyEntryFirst = @($legacyRegistryFirst.workspaces.PSObject.Properties | Select-Object -First 1)
    $legacyManifestFirst = [string]@($legacyEntryFirst[0].Value.manifests)[-1]
    $legacyPointerPathForClone = Join-Path $receiptRepoA 'backups\active-install.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyPointerPathForClone) -Force | Out-Null
    $legacyPointerContent = [ordered]@{ manifest_path = $legacyManifestFirst; workspace_root = $legacyWorkspace } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($legacyPointerPathForClone, $legacyPointerContent, (New-Object System.Text.UTF8Encoding($false)))
    $legacyMarkerParentBlocker = Join-Path $legacyUserProfile '.dev-harness\legacy-pointer-imports'
    $legacyMarkerPath = Get-LegacyPointerMigrationMarkerPath -UserProfile $legacyUserProfile -PointerPath $legacyPointerPathForClone
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyMarkerPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($legacyMarkerPath, 'invalid-marker', (New-Object System.Text.UTF8Encoding($false)))
    (Get-Item -LiteralPath $legacyMarkerPath).IsReadOnly = $true
    $legacyRegistryBeforeReadOnlyMarker = Get-FileSnapshot -Path $legacyRegistryPath
    $legacyWorkspaceBeforeReadOnlyMarker = Get-FileSnapshot -Path (Join-Path $legacyWorkspace 'AGENTS.md')
    try {
        $legacyReadOnlyMarkerInstall = Invoke-RepoScript -UserProfile $legacyUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
            WorkspaceRoot = $legacyWorkspace
            RepoRoot = $receiptRepoA
        }
    } finally {
        (Get-Item -LiteralPath $legacyMarkerPath).IsReadOnly = $false
        Remove-Item -LiteralPath $legacyMarkerParentBlocker -Recurse -Force
    }
    $results.Add($legacyReadOnlyMarkerInstall) | Out-Null
    if ($legacyReadOnlyMarkerInstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $legacyRegistryBeforeReadOnlyMarker -Right (Get-FileSnapshot -Path $legacyRegistryPath)) -and
        (Test-SameSnapshot -Left $legacyWorkspaceBeforeReadOnlyMarker -Right (Get-FileSnapshot -Path (Join-Path $legacyWorkspace 'AGENTS.md')))) {
        Add-Check 'invalid legacy migration marker fails before install transaction mutation or registry commit'
    } else {
        Add-Failure 'invalid legacy migration marker must fail closed before install mutation begins'
    }
    [System.IO.File]::WriteAllText($legacyMarkerParentBlocker, 'not-a-directory', (New-Object System.Text.UTF8Encoding($false)))
    $legacyRegistryBeforeBlockedMarker = Get-FileSnapshot -Path $legacyRegistryPath
    $legacyWorkspaceBeforeBlockedMarker = Get-FileSnapshot -Path (Join-Path $legacyWorkspace 'AGENTS.md')
    $legacyClaudeBeforeBlockedMarker = Get-FileSnapshot -Path (Join-Path $legacyUserProfile '.claude\CLAUDE.md')
    try {
        $legacyBlockedUninstall = Invoke-RepoScript -UserProfile $legacyUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
            WorkspaceRoot = $legacyWorkspace
            RepoRoot = $receiptRepoA
        }
    } finally {
        Remove-Item -LiteralPath $legacyMarkerParentBlocker -Force
    }
    $results.Add($legacyBlockedUninstall) | Out-Null
    if ($legacyBlockedUninstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $legacyRegistryBeforeBlockedMarker -Right (Get-FileSnapshot -Path $legacyRegistryPath)) -and
        (Test-SameSnapshot -Left $legacyWorkspaceBeforeBlockedMarker -Right (Get-FileSnapshot -Path (Join-Path $legacyWorkspace 'AGENTS.md'))) -and
        (Test-SameSnapshot -Left $legacyClaudeBeforeBlockedMarker -Right (Get-FileSnapshot -Path (Join-Path $legacyUserProfile '.claude\CLAUDE.md')))) {
        Add-Check 'legacy pointer marker failure aborts uninstall before workspace, registry, or user-global mutation'
    } else {
        Add-Failure 'legacy pointer marker failure should fail closed before uninstall mutation'
    }
    $legacyUninstallFirst = Invoke-RepoScript -UserProfile $legacyUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $legacyWorkspace
        RepoRoot = $receiptRepoA
    }
    $legacySentinelPath = Join-Path $legacyWorkspace 'AGENTS.md'
    [System.IO.File]::WriteAllText($legacySentinelPath, 'between-installs-sentinel', (New-Object System.Text.UTF8Encoding($false)))
    $legacyChangedPointerContent = [ordered]@{
        manifest_path = $legacyManifestFirst
        workspace_root = $legacyWorkspace
        legacy_generation = 2
    } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($legacyPointerPathForClone, $legacyChangedPointerContent, (New-Object System.Text.UTF8Encoding($false)))
    $legacyInstallSecond = Invoke-RepoScript -UserProfile $legacyUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $legacyWorkspace
        RepoRoot = $receiptRepoA
    }
    $legacyRegistrySecond = Read-JsonFile -Path $legacyRegistryPath
    $legacyEntrySecond = @($legacyRegistrySecond.workspaces.PSObject.Properties | Select-Object -First 1)
    $legacySecondManifestCount = @($legacyEntrySecond[0].Value.manifests).Count
    $legacyUninstallSecond = Invoke-RepoScript -UserProfile $legacyUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $legacyWorkspace
        RepoRoot = $receiptRepoA
    }
    $results.Add($legacyInstallFirst) | Out-Null
    $results.Add($legacyUninstallFirst) | Out-Null
    $results.Add($legacyInstallSecond) | Out-Null
    $results.Add($legacyUninstallSecond) | Out-Null
    if ($legacyInstallFirst.ExitCode -eq 0 -and
        $legacyUninstallFirst.ExitCode -eq 0 -and
        $legacyInstallSecond.ExitCode -eq 0 -and
        $legacySecondManifestCount -eq 1 -and
        $legacyUninstallSecond.ExitCode -eq 0 -and
        (Get-Content -LiteralPath $legacySentinelPath -Raw -Encoding utf8) -eq 'between-installs-sentinel') {
        Add-Check 'a consumed legacy active-install pointer remains one-shot even when its content later changes'
    } else {
        Add-Failure ("legacy pointer migration should be one-shot per USERPROFILE; installs={0},{1}, uninstalls={2},{3}, manifests={4}, sentinel={5}" -f $legacyInstallFirst.ExitCode,$legacyInstallSecond.ExitCode,$legacyUninstallFirst.ExitCode,$legacyUninstallSecond.ExitCode,$legacySecondManifestCount,(Test-Path -LiteralPath $legacySentinelPath))
    }

    $singleInstall = Invoke-RepoScript -UserProfile $singleUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $singleWorkspace
        RepoRoot = $RepoRoot
    }
    $singleRegistryPath = Join-Path $singleUserProfile '.dev-harness\install-registry.json'
    $singleRegistry = Read-JsonFile -Path $singleRegistryPath
    $singleEntry = @($singleRegistry.workspaces.PSObject.Properties | Select-Object -First 1)
    $singleManifestPath = [string]@($singleEntry[0].Value.manifests)[-1]
    $singleManifest = Read-JsonFile -Path $singleManifestPath
    $singleWorkspaceHolding = "$singleWorkspace.holding"
    $singleVictim = Join-Path $scratchRoot 'single-reparse-victim'
    Move-Item -LiteralPath $singleWorkspace -Destination $singleWorkspaceHolding
    New-Item -ItemType Directory -Path $singleVictim -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $singleVictim 'AGENTS.md'), 'victim-sentinel', (New-Object System.Text.UTF8Encoding($false)))
    New-Item -ItemType Junction -Path $singleWorkspace -Target $singleVictim | Out-Null
    $singleRegistryBeforeReparse = Get-FileSnapshot -Path $singleRegistryPath
    try {
        $singleReparseUninstall = Invoke-RepoScript -UserProfile $singleUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
            WorkspaceRoot = $singleWorkspace
            RepoRoot = $RepoRoot
        }
    } finally {
        if (Test-Path -LiteralPath $singleWorkspace) {
            Remove-Item -LiteralPath $singleWorkspace -Force
        }
        Move-Item -LiteralPath $singleWorkspaceHolding -Destination $singleWorkspace
    }
    $results.Add($singleReparseUninstall) | Out-Null
    if ($singleReparseUninstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $singleRegistryBeforeReparse -Right (Get-FileSnapshot -Path $singleRegistryPath)) -and
        (Get-Content -LiteralPath (Join-Path $singleVictim 'AGENTS.md') -Raw -Encoding utf8) -eq 'victim-sentinel') {
        Add-Check 'uninstall rejects a workspace replaced by a junction before redirected restore'
    } else {
        Add-Failure 'workspace reparse swap must fail before registry or victim mutation'
    }
    $singleInstallJournalPath = Join-Path $singleUserProfile '.dev-harness\install-transaction.json'
    $singleStaleInstallJournal = [ordered]@{
        schema_version = 'install-transaction/v1.1'
        registry_schema_version = 'install-registry/v1.1'
        manifest_schema_version = 'install-manifest/v1.2'
        postimage_identity_contract = 'v1'
        user_profile = $singleUserProfile
        repo_root = $RepoRoot
        workspace_root = $singleWorkspace
        registry_path = $singleRegistryPath
        registry_preimage_sha256 = [string]$singleManifest.registry_preimage_sha256
        manifest_path = $singleManifestPath
        postimage_transaction_status_contract = [string]$singleRegistry.transaction_status_contract
        postimage_history_ownership_contract = 'v1'
        postimage_manifest_integrity_contract = 'sha256-v1'
        legacy_pointer_path = $null
        legacy_pointer_import_digest = $null
    } | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($singleInstallJournalPath, $singleStaleInstallJournal, (New-Object System.Text.UTF8Encoding($false)))
    $singleRegistryRaw = Get-Content -LiteralPath $singleRegistryPath -Raw -Encoding utf8
    $singleStrippedRegistry = $singleRegistryRaw | ConvertFrom-Json
    [void]$singleStrippedRegistry.PSObject.Properties.Remove('history_ownership_contract')
    [void]$singleStrippedRegistry.PSObject.Properties.Remove('manifest_integrity_contract')
    [void]$singleStrippedRegistry.PSObject.Properties.Remove('manifest_digests')
    [System.IO.File]::WriteAllText($singleRegistryPath, ($singleStrippedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $singleStrippedRegistrySnapshot = Get-FileSnapshot -Path $singleRegistryPath
    $singleStaleJournalSnapshot = Get-FileSnapshot -Path $singleInstallJournalPath
    $singleBlockedCommittedRetry = Invoke-RepoScript -UserProfile $singleUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $singleWorkspace
        RepoRoot = $RepoRoot
    }
    $results.Add($singleBlockedCommittedRetry) | Out-Null
    if ($singleBlockedCommittedRetry.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $singleStrippedRegistrySnapshot -Right (Get-FileSnapshot -Path $singleRegistryPath)) -and
        (Test-SameSnapshot -Left $singleStaleJournalSnapshot -Right (Get-FileSnapshot -Path $singleInstallJournalPath))) {
        Add-Check 'committed install journal cleanup rejects a contract-stripped registry postimage'
    } else {
        Add-Failure 'committed install journal must keep the transaction gate closed for an impossible postimage'
    }
    [System.IO.File]::WriteAllText($singleRegistryPath, $singleRegistryRaw, (New-Object System.Text.UTF8Encoding($false)))
    $singleUninstall = Invoke-RepoScript -UserProfile $singleUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        WorkspaceRoot = $singleWorkspace
        RepoRoot = $RepoRoot
    }
    $singlePostUninstallSentinel = Join-Path $singleWorkspace 'AGENTS.md'
    [System.IO.File]::WriteAllText($singlePostUninstallSentinel, 'post-uninstall-user-data', (New-Object System.Text.UTF8Encoding($false)))
    $singleReplay = Invoke-RepoScript -UserProfile $singleUserProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        ManifestPath = $singleManifestPath
        RepoRoot = $RepoRoot
    }
    $singleConsumedManifest = Read-JsonFile -Path $singleManifestPath
    $results.Add($singleInstall) | Out-Null
    $results.Add($singleUninstall) | Out-Null
    $results.Add($singleReplay) | Out-Null
    if ($singleInstall.ExitCode -eq 0 -and
        $singleUninstall.ExitCode -eq 0 -and
        -not (Test-Path -LiteralPath $singleRegistryPath) -and
        -not (Test-Path -LiteralPath $singleInstallJournalPath) -and
        $singleConsumedManifest.transaction_status -eq 'uninstalled' -and
        $singleReplay.ExitCode -ne 0 -and
        (Get-Content -LiteralPath $singlePostUninstallSentinel -Raw -Encoding utf8) -eq 'post-uninstall-user-data') {
        Add-Check 'one install/uninstall tombstones its manifest and rejects replay against post-uninstall user data'
    } else {
        Add-Failure 'single-manifest uninstall should remove the registry and make the consumed manifest non-replayable'
    }

    $RepoRoot = $sourceRoot
    $claudeGlobalPath = Join-Path $userProfile '.claude\CLAUDE.md'
    $claudeSettingsPath = Join-Path $userProfile '.claude\settings.json'
    $legacyClaudeSettingsPath = Join-Path $userProfile '.claude\.claude\settings.local.json'
    $codexGlobalPath = Join-Path $userProfile '.codex\AGENTS.md'
    $localSkillPath = Join-Path $userProfile '.claude\skills\.system\custom-local-skill\SKILL.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $claudeGlobalPath),(Split-Path -Parent $legacyClaudeSettingsPath),(Split-Path -Parent $codexGlobalPath),(Split-Path -Parent $localSkillPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($claudeGlobalPath, '# original claude', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($codexGlobalPath, '# original codex', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($localSkillPath, '# local only', (New-Object System.Text.UTF8Encoding($false)))
    $originalClaudeSettings = [ordered]@{
        model = 'sentinel-model'
        permissions = [ordered]@{
            allow = @('Read(//workspace/**)')
        }
        hooks = [ordered]@{
            UserPromptSubmit = @([ordered]@{
                    hooks = @([ordered]@{ type = 'command'; command = 'third-party-hook.cmd'; timeout = 10 })
                })
        }
    } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($claudeSettingsPath, $originalClaudeSettings, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($legacyClaudeSettingsPath, '{"legacy":true}', (New-Object System.Text.UTF8Encoding($false)))
    $claudeHashBefore = (Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash
    $claudeSettingsHashBefore = (Get-FileHash -LiteralPath $claudeSettingsPath -Algorithm SHA256).Hash
    $legacyClaudeSettingsBefore = Get-FileSnapshot -Path $legacyClaudeSettingsPath
    $codexHashBefore = (Get-FileHash -LiteralPath $codexGlobalPath -Algorithm SHA256).Hash
    $legacyPointerBefore = Get-FileSnapshot -Path $legacyPointerPath

    $installA = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $workspaceA
        RepoRoot = $RepoRoot
    }
    $results.Add($installA) | Out-Null
    $registryAfterA = Read-JsonFile -Path $registryPath
    $entryA = @($registryAfterA.workspaces.PSObject.Properties | Where-Object { (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $workspaceA })
    $manifestAOld = if ($entryA.Count -eq 1) { [string]@($entryA[0].Value.manifests)[-1] } else { '' }

    $installAUpdate = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $workspaceA
        RepoRoot = $RepoRoot
    }
    $results.Add($installAUpdate) | Out-Null
    $registryAfterAUpdate = Read-JsonFile -Path $registryPath
    $entryA = @($registryAfterAUpdate.workspaces.PSObject.Properties | Where-Object { (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $workspaceA })
    $manifestA = if ($entryA.Count -eq 1) { [string]@($entryA[0].Value.manifests)[-1] } else { '' }

    $installB = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        WorkspaceRoot = $workspaceB
        RepoRoot = $RepoRoot
    }
    $results.Add($installB) | Out-Null
    $registryAfterB = Read-JsonFile -Path $registryPath
    if ($installA.ExitCode -eq 0 -and $installAUpdate.ExitCode -eq 0 -and $installB.ExitCode -eq 0 -and @($registryAfterB.workspaces.PSObject.Properties).Count -eq 2) {
        Add-Check 'two workspaces install into one user-scoped registry'
    } else {
        Add-Failure 'two isolated installs should create two workspace registry entries'
    }

    $entryB = @($registryAfterB.workspaces.PSObject.Properties | Where-Object { (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $workspaceB })
    $manifestBPath = if ($entryB.Count -eq 1) { [string]@($entryB[0].Value.manifests)[-1] } else { '' }
    $registryIdentityBaseline = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8
    $workspaceAIdentityBaseline = Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md')
    $workspaceBIdentityBaseline = Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')

    $digestTamperedManifest = (Get-Content -LiteralPath $manifestBPath -Raw -Encoding utf8) | ConvertFrom-Json
    $digestTamperedManifest | Add-Member -NotePropertyName 'untrusted_change' -NotePropertyValue 'must-not-be-accepted'
    $manifestBBeforeDigestTamper = Get-Content -LiteralPath $manifestBPath -Raw -Encoding utf8
    [System.IO.File]::WriteAllText($manifestBPath, ($digestTamperedManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $digestTamperedSnapshot = Get-FileSnapshot -Path $manifestBPath
    $digestTamperResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($digestTamperResult) | Out-Null
    if ($digestTamperResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $digestTamperedSnapshot -Right (Get-FileSnapshot -Path $manifestBPath)) -and
        (Get-Content -LiteralPath $registryPath -Raw -Encoding utf8) -eq $registryIdentityBaseline -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'registry-bound manifest digest rejects backup-plan tampering before mutation'
    } else {
        Add-Failure 'registered manifest content must be integrity-bound before restore'
    }
    [System.IO.File]::WriteAllText($manifestBPath, $manifestBBeforeDigestTamper, (New-Object System.Text.UTF8Encoding($false)))

    $tamperedRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $tamperedRegistry.workspaces = 'not-an-object'
    [System.IO.File]::WriteAllText($registryPath, ($tamperedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $malformedWorkspacesResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($malformedWorkspacesResult) | Out-Null
    if ($malformedWorkspacesResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md'))) -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'uninstall rejects a non-object registry workspaces field before mutation'
    } else {
        Add-Failure 'a malformed registry workspaces field should fail closed before mutation'
    }
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $unknownContractRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $unknownContractRegistry.transaction_status_contract = 'unknown-v2'
    [System.IO.File]::WriteAllText($registryPath, ($unknownContractRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $unknownContractSnapshot = Get-FileSnapshot -Path $registryPath
    $unknownContractInstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $unknownContractUninstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($unknownContractInstall) | Out-Null
    $results.Add($unknownContractUninstall) | Out-Null
    if ($unknownContractInstall.ExitCode -ne 0 -and
        $unknownContractUninstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $unknownContractSnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'install and uninstall reject unknown registry transaction contracts before mutation'
    } else {
        Add-Failure 'unknown registry transaction contracts must fail closed on both lifecycle commands'
    }
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $manifestBIdentityBaseline = Get-Content -LiteralPath $manifestBPath -Raw -Encoding utf8
    $emptyStatusManifestB = $manifestBIdentityBaseline | ConvertFrom-Json
    $emptyStatusManifestB.transaction_status = ''
    [System.IO.File]::WriteAllText($manifestBPath, ($emptyStatusManifestB | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $emptyStatusManifestSnapshot = Get-FileSnapshot -Path $manifestBPath
    $emptyStatusRegistry = $registryIdentityBaseline | ConvertFrom-Json
    Set-RegistryManifestDigestForPath -Registry $emptyStatusRegistry -ManifestPath $manifestBPath
    [System.IO.File]::WriteAllText($registryPath, ($emptyStatusRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $emptyStatusRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $emptyStatusInstallResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $emptyStatusResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($emptyStatusInstallResult) | Out-Null
    $results.Add($emptyStatusResult) | Out-Null
    if ($emptyStatusInstallResult.ExitCode -ne 0 -and
        $emptyStatusResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $emptyStatusManifestSnapshot -Right (Get-FileSnapshot -Path $manifestBPath)) -and
        (Test-SameSnapshot -Left $emptyStatusRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'transaction status contract rejects and never auto-commits an empty registered manifest status'
    } else {
        Add-Failure 'an empty registered manifest status should fail closed for both install and uninstall under the v1 contract'
    }
    [System.IO.File]::WriteAllText($manifestBPath, $manifestBIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $rootDeleteManifestB = $manifestBIdentityBaseline | ConvertFrom-Json
    $rootDeleteManifestB.backups = @($rootDeleteManifestB.backups) + [pscustomobject]@{
        path = (Join-Path $userProfile '.codex')
        scope = 'user-global'
        ownership = 'managed'
        existed = $false
        item_type = 'missing'
        backup_path = $null
        link_type = $null
        link_target = $null
    }
    [System.IO.File]::WriteAllText($manifestBPath, ($rootDeleteManifestB | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $rootDeleteRegistry = $registryIdentityBaseline | ConvertFrom-Json
    Set-RegistryManifestDigestForPath -Registry $rootDeleteRegistry -ManifestPath $manifestBPath
    [System.IO.File]::WriteAllText($registryPath, ($rootDeleteRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $codexRootSentinel = Join-Path $userProfile '.codex\user-owned-sentinel.txt'
    [System.IO.File]::WriteAllText($codexRootSentinel, 'must-survive', (New-Object System.Text.UTF8Encoding($false)))
    $rootDeleteManifestSnapshot = Get-FileSnapshot -Path $manifestBPath
    $rootDeleteRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $rootDeleteResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($rootDeleteResult) | Out-Null
    if ($rootDeleteResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $rootDeleteManifestSnapshot -Right (Get-FileSnapshot -Path $manifestBPath)) -and
        (Test-SameSnapshot -Left $rootDeleteRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Get-Content -LiteralPath $codexRootSentinel -Raw -Encoding utf8) -eq 'must-survive' -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'backup target allowlist rejects a user-global root deletion record before mutation'
    } else {
        Add-Failure 'a tampered backup record must never be able to delete an entire user-global root'
    }
    [System.IO.File]::WriteAllText($manifestBPath, $manifestBIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $tamperedRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $tamperedRegistry.global_manifest_history = @($manifestA,$manifestBPath)
    [System.IO.File]::WriteAllText($registryPath, ($tamperedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $partialHistoryResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($partialHistoryResult) | Out-Null
    if ($partialHistoryResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md'))) -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'global history must contain every active workspace manifest in relative order'
    } else {
        Add-Failure 'partial global history should fail before restoring an active owner'
    }
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $forgedHistoryPath = Join-Path $scratchRoot 'forged-history-manifest.json'
    Copy-Item -LiteralPath $manifestBPath -Destination $forgedHistoryPath -Force
    $tamperedRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $tamperedRegistry.global_manifest_history = @($manifestAOld,$manifestA,$forgedHistoryPath,$manifestBPath)
    $tamperedRegistry.retired_manifest_history = @($forgedHistoryPath)
    Set-RegistryManifestDigestForPath -Registry $tamperedRegistry -ManifestPath $forgedHistoryPath
    [System.IO.File]::WriteAllText($registryPath, ($tamperedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $forgedHistoryResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($forgedHistoryResult) | Out-Null
    if ($forgedHistoryResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md'))) -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'every retired global history manifest must pass exact path and registry identity checks'
    } else {
        Add-Failure 'a forged retired history manifest should fail before any restore'
    }
    Remove-Item -LiteralPath $forgedHistoryPath -Force
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $tamperedRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $tamperedRegistry.global_manifest_history = @($manifestA)
    [System.IO.File]::WriteAllText($registryPath, ($tamperedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $missingOwnerHistoryResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($missingOwnerHistoryResult) | Out-Null
    if ($missingOwnerHistoryResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md'))) -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'uninstall rejects a registry whose active workspace latest manifest is missing from global owner history'
    } else {
        Add-Failure 'missing active owner history should fail without unlinking the selected workspace or changing registry'
    }
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $tamperedRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $tamperedEntryA = @($tamperedRegistry.workspaces.PSObject.Properties | Where-Object { (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $workspaceA })
    $tamperedEntryA[0].Value.manifests = @($manifestBPath)
    [System.IO.File]::WriteAllText($registryPath, ($tamperedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $crossWorkspaceResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceA
    }
    $results.Add($crossWorkspaceResult) | Out-Null
    if ($crossWorkspaceResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md'))) -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'uninstall rejects a registry entry whose latest manifest belongs to another workspace before mutation'
    } else {
        Add-Failure 'cross-workspace manifest pointer tampering should fail without mutating either workspace or registry'
    }
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $tamperedRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $tamperedEntryA = @($tamperedRegistry.workspaces.PSObject.Properties | Where-Object { (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $workspaceA })
    $tamperedEntryA[0].Value.manifests = @($manifestBPath,$manifestA)
    [System.IO.File]::WriteAllText($registryPath, ($tamperedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $historicalWorkspaceResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceA
    }
    $results.Add($historicalWorkspaceResult) | Out-Null
    if ($historicalWorkspaceResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md'))) -and
        (Test-SameSnapshot -Left $workspaceBIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
        Add-Check 'uninstall validates every workspace history manifest before restoring the first record'
    } else {
        Add-Failure 'a cross-workspace historical manifest should fail before mutating either workspace or registry'
    }
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $tamperedRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $tamperedEntryA = @($tamperedRegistry.workspaces.PSObject.Properties | Where-Object { (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $workspaceA })
    $tamperedEntryA[0].Value.workspace_root = $workspaceB
    [System.IO.File]::WriteAllText($registryPath, ($tamperedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $entryWorkspaceResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceA
    }
    $results.Add($entryWorkspaceResult) | Out-Null
    if ($entryWorkspaceResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md')))) {
        Add-Check 'uninstall rejects a registry key and entry workspace mismatch before mutation'
    } else {
        Add-Failure 'registry key/entry workspace tampering should fail without mutation'
    }
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $tamperedRegistry = $registryIdentityBaseline | ConvertFrom-Json
    $tamperedEntryA = @($tamperedRegistry.workspaces.PSObject.Properties | Where-Object { (Get-NormalizedPath -Path $_.Value.workspace_root) -eq $workspaceA })
    $tamperedEntryA[0].Value.repo_root = (Join-Path $scratchRoot 'wrong-repo-owner')
    [System.IO.File]::WriteAllText($registryPath, ($tamperedRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedRegistrySnapshot = Get-FileSnapshot -Path $registryPath
    $entryRepoResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceA
    }
    $results.Add($entryRepoResult) | Out-Null
    if ($entryRepoResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md')))) {
        Add-Check 'uninstall rejects a registry repo owner mismatch before mutation'
    } else {
        Add-Failure 'registry repo owner tampering should fail without mutation'
    }
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $manifestAIdentityBaseline = Get-Content -LiteralPath $manifestA -Raw -Encoding utf8
    $tamperedManifestA = $manifestAIdentityBaseline | ConvertFrom-Json
    $tamperedManifestA.registry_path = Join-Path $scratchRoot 'wrong-registry.json'
    [System.IO.File]::WriteAllText($manifestA, ($tamperedManifestA | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $tamperedManifestRegistry = $registryIdentityBaseline | ConvertFrom-Json
    Set-RegistryManifestDigestForPath -Registry $tamperedManifestRegistry -ManifestPath $manifestA
    [System.IO.File]::WriteAllText($registryPath, ($tamperedManifestRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $registryIdentitySnapshot = Get-FileSnapshot -Path $registryPath
    $tamperedManifestSnapshot = Get-FileSnapshot -Path $manifestA
    $manifestRegistryResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceA
    }
    $results.Add($manifestRegistryResult) | Out-Null
    if ($manifestRegistryResult.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $tamperedManifestSnapshot -Right (Get-FileSnapshot -Path $manifestA)) -and
        (Test-SameSnapshot -Left $registryIdentitySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceAIdentityBaseline -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md')))) {
        Add-Check 'uninstall rejects a manifest registry path mismatch before mutation'
    } else {
        Add-Failure 'manifest registry path tampering should fail without mutation'
    }
    [System.IO.File]::WriteAllText($manifestA, $manifestAIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($registryPath, $registryIdentityBaseline, (New-Object System.Text.UTF8Encoding($false)))

    $installedClaudeSettings = Read-JsonFile -Path $claudeSettingsPath
    $installedHookCommands = Get-HookCommands -Settings $installedClaudeSettings
    $installedPermissions = $installedClaudeSettings.PSObject.Properties['permissions']
    $installedAllow = @(if ($null -ne $installedPermissions -and $null -ne $installedPermissions.Value.PSObject.Properties['allow']) { $installedPermissions.Value.allow })
    $harnessHooksUnique = @('pretooluse.ps1', 'stop.js') | Where-Object {
        $hookName = $_
        @($installedHookCommands | Where-Object { $_ -like "*$hookName*" }).Count -ne 1
    }
    $optionalMemoryHookCount = @($installedHookCommands | Where-Object { $_ -like '*userpromptsubmit.js*' }).Count
    $retiredPostToolHookCount = @($installedHookCommands | Where-Object { $_ -like '*hooks-memory\posttooluse.js*' }).Count
    if (@($installedHookCommands | Where-Object { $_ -eq 'third-party-hook.cmd' }).Count -eq 1 -and @($harnessHooksUnique).Count -eq 0 -and $optionalMemoryHookCount -eq 0 -and $retiredPostToolHookCount -eq 0 -and $installedAllow.Count -eq 1 -and [string]$installedAllow[0] -ceq 'Read(//workspace/**)' -and $null -eq $installedClaudeSettings.hooks.PSObject.Properties['permissions']) {
        Add-Check 'repeated core install preserves third-party Claude hooks and root permissions, keeps core hooks unique, and omits optional or retired hooks'
    } else {
        Add-Failure 'repeated core install should preserve third-party Claude hooks and root permissions, keep core hooks unique, omit optional or retired hooks, and leave permissions outside hooks'
    }

    $installedClaudeHash = (Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash
    $registryBeforeOldManifest = Get-FileSnapshot -Path $registryPath
    $workspaceABeforeOldManifest = Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md')
    $oldManifestUninstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        ManifestPath = $manifestAOld
    }
    $results.Add($oldManifestUninstall) | Out-Null
    if ($oldManifestUninstall.ExitCode -ne 0 -and
        (Test-SameSnapshot -Left $registryBeforeOldManifest -Right (Get-FileSnapshot -Path $registryPath)) -and
        (Test-SameSnapshot -Left $workspaceABeforeOldManifest -Right (Get-FileSnapshot -Path (Join-Path $workspaceA 'AGENTS.md'))) -and
        (Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash -eq $installedClaudeHash) {
        Add-Check 'an older manifest cannot select an entire registered workspace uninstall'
    } else {
        Add-Failure 'an older manifest should be rejected without changing workspace, registry, or user-global files'
    }

    $manifestB = Read-JsonFile -Path $manifestBPath
    $payloadRecord = @($manifestB.backups | Where-Object { $_.existed -and $_.item_type -eq 'file' -and -not [string]::IsNullOrWhiteSpace($_.backup_path) } | Select-Object -First 1)
    if ($payloadRecord.Count -eq 1) {
        $payloadPath = [string]$payloadRecord[0].backup_path
        $missingPayloadPath = "$payloadPath.missing"
        $registryBeforeMissingPayload = Get-FileSnapshot -Path $registryPath
        $workspaceBBeforeMissingPayload = Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')
        Move-Item -LiteralPath $payloadPath -Destination $missingPayloadPath
        try {
            $missingPayloadUninstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
                RepoRoot = $RepoRoot
                WorkspaceRoot = $workspaceB
            }
            $results.Add($missingPayloadUninstall) | Out-Null
            if ($missingPayloadUninstall.ExitCode -ne 0 -and
                (Test-SameSnapshot -Left $registryBeforeMissingPayload -Right (Get-FileSnapshot -Path $registryPath)) -and
                (Test-SameSnapshot -Left $workspaceBBeforeMissingPayload -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md'))) -and
                (Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash -eq $installedClaudeHash) {
                Add-Check 'missing backup payload aborts uninstall before any workspace, registry, or user-global mutation'
            } else {
                Add-Failure 'missing backup payload should abort uninstall before any mutation'
            }
        } finally {
            Move-Item -LiteralPath $missingPayloadPath -Destination $payloadPath -Force
        }
        $payloadBytes = [System.IO.File]::ReadAllBytes($payloadPath)
        $registryBeforeCorruptPayload = Get-FileSnapshot -Path $registryPath
        $workspaceBBeforeCorruptPayload = Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')
        try {
            [System.IO.File]::WriteAllText($payloadPath, 'corrupt-backup-payload', (New-Object System.Text.UTF8Encoding($false)))
            $corruptPayloadUninstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
                RepoRoot = $RepoRoot
                WorkspaceRoot = $workspaceB
            }
            $results.Add($corruptPayloadUninstall) | Out-Null
            if ($corruptPayloadUninstall.ExitCode -ne 0 -and
                (Test-SameSnapshot -Left $registryBeforeCorruptPayload -Right (Get-FileSnapshot -Path $registryPath)) -and
                (Test-SameSnapshot -Left $workspaceBBeforeCorruptPayload -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md'))) -and
                (Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash -eq $installedClaudeHash) {
                Add-Check 'corrupt backup payload digest aborts uninstall before any mutation'
            } else {
                Add-Failure 'backup payload content corruption must fail before restore mutation'
            }
        } finally {
            [System.IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
        }
        $legacyPayloadManifestRaw = Get-Content -LiteralPath $manifestBPath -Raw -Encoding utf8
        $legacyPayloadRegistryRaw = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8
        $legacyPayloadManifest = $legacyPayloadManifestRaw | ConvertFrom-Json
        [void]$legacyPayloadManifest.PSObject.Properties.Remove('backup_payload_integrity_contract')
        foreach ($backupRecord in @($legacyPayloadManifest.backups)) {
            [void]$backupRecord.PSObject.Properties.Remove('backup_payload_sha256')
        }
        [System.IO.File]::WriteAllText($manifestBPath, ($legacyPayloadManifest | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
        $legacyPayloadRegistry = $legacyPayloadRegistryRaw | ConvertFrom-Json
        Set-RegistryManifestDigestForPath -Registry $legacyPayloadRegistry -ManifestPath $manifestBPath
        [System.IO.File]::WriteAllText($registryPath, ($legacyPayloadRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
        try {
            [System.IO.File]::WriteAllText($payloadPath, 'legacy-corrupt-backup-payload', (New-Object System.Text.UTF8Encoding($false)))
            $legacyPayloadRegistrySnapshot = Get-FileSnapshot -Path $registryPath
            $legacyPayloadWorkspaceSnapshot = Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')
            $legacyPayloadUninstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
                RepoRoot = $RepoRoot
                WorkspaceRoot = $workspaceB
            }
            $results.Add($legacyPayloadUninstall) | Out-Null
            if ($legacyPayloadUninstall.ExitCode -ne 0 -and
                (Test-SameSnapshot -Left $legacyPayloadRegistrySnapshot -Right (Get-FileSnapshot -Path $registryPath)) -and
                (Test-SameSnapshot -Left $legacyPayloadWorkspaceSnapshot -Right (Get-FileSnapshot -Path (Join-Path $workspaceB 'AGENTS.md')))) {
                Add-Check 'legacy backup payload without an integrity contract fails closed before restore'
            } else {
                Add-Failure 'unverified legacy backup payload must never overwrite user data'
            }
        } finally {
            [System.IO.File]::WriteAllBytes($payloadPath, $payloadBytes)
            [System.IO.File]::WriteAllText($manifestBPath, $legacyPayloadManifestRaw, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText($registryPath, $legacyPayloadRegistryRaw, (New-Object System.Text.UTF8Encoding($false)))
        }
    } else {
        Add-Failure 'test setup should find a file backup payload in the latest workspace manifest'
    }

    $implicitUninstall = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{ RepoRoot = $RepoRoot }
    $results.Add($implicitUninstall) | Out-Null
    if ($implicitUninstall.ExitCode -ne 0 -and (Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash -eq $installedClaudeHash) {
        Add-Check 'uninstall without WorkspaceRoot or ManifestPath fails closed without changing user-global files'
    } else {
        Add-Failure 'implicit uninstall should fail closed without changing user-global files'
    }

    $nonOwnerRegistryCommitLock = [System.IO.File]::Open($registryPath, 'Open', 'Read', 'ReadWrite')
    try {
        $interruptedUninstallA = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
            RepoRoot = $RepoRoot
            ManifestPath = $manifestA
        }
    } finally {
        $nonOwnerRegistryCommitLock.Dispose()
    }
    $nonOwnerJournalPath = Join-Path $userProfile '.dev-harness\uninstall-transaction.json'
    $nonOwnerJournalRaw = Get-Content -LiteralPath $nonOwnerJournalPath -Raw -Encoding utf8
    $uninstallA = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
    }
    [System.IO.File]::WriteAllText($nonOwnerJournalPath, $nonOwnerJournalRaw, (New-Object System.Text.UTF8Encoding($false)))
    $committedNonOwnerCleanup = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
    }
    $results.Add($interruptedUninstallA) | Out-Null
    $results.Add($uninstallA) | Out-Null
    $results.Add($committedNonOwnerCleanup) | Out-Null
    $registryAfterUninstallA = Read-JsonFile -Path $registryPath
    $retiredAfterUninstallA = @($registryAfterUninstallA.retired_manifest_history)
    if ($interruptedUninstallA.ExitCode -ne 0 -and
        $uninstallA.ExitCode -eq 0 -and
        $committedNonOwnerCleanup.ExitCode -eq 0 -and
        -not (Test-Path -LiteralPath $nonOwnerJournalPath) -and
        @($registryAfterUninstallA.workspaces.PSObject.Properties).Count -eq 1 -and
        $registryAfterUninstallA.history_ownership_contract -eq 'v1' -and
        $retiredAfterUninstallA.Count -eq 2 -and
        $retiredAfterUninstallA -contains $manifestAOld -and
        $retiredAfterUninstallA -contains $manifestA -and
        (Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash -eq $installedClaudeHash) {
        Add-Check 'non-owner uninstall resumes and cleans a committed journal with an empty tombstone set'
    } else {
        Add-Failure 'first workspace uninstall should retain explicit rollback ownership and preserve the remaining active owner'
    }

    $uninstallB = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'uninstall.ps1') -Arguments @{
        RepoRoot = $RepoRoot
        WorkspaceRoot = $workspaceB
    }
    $results.Add($uninstallB) | Out-Null
    if ($uninstallB.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $registryPath) -and
        (Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash -eq $claudeHashBefore -and
        (Get-FileHash -LiteralPath $claudeSettingsPath -Algorithm SHA256).Hash -eq $claudeSettingsHashBefore -and
        (Get-FileHash -LiteralPath $codexGlobalPath -Algorithm SHA256).Hash -eq $codexHashBefore) {
        Add-Check 'last workspace uninstall restores original user-global hashes and removes the empty registry'
    } else {
        Add-Failure ("last workspace uninstall should restore original user-global hashes and remove the empty registry; exit={0}, registry_exists={1}, claude={2}, settings={3}, codex={4}" -f `
            $uninstallB.ExitCode,
            (Test-Path -LiteralPath $registryPath),
            ((Get-FileHash -LiteralPath $claudeGlobalPath -Algorithm SHA256).Hash -eq $claudeHashBefore),
            ((Get-FileHash -LiteralPath $claudeSettingsPath -Algorithm SHA256).Hash -eq $claudeSettingsHashBefore),
            ((Get-FileHash -LiteralPath $codexGlobalPath -Algorithm SHA256).Hash -eq $codexHashBefore))
    }

    if (Test-SameSnapshot -Left $legacyClaudeSettingsBefore -Right (Get-FileSnapshot -Path $legacyClaudeSettingsPath)) {
        Add-Check 'install and uninstall leave the legacy double-.claude settings file untouched'
    } else {
        Add-Failure 'install and uninstall should not clean or rewrite the legacy double-.claude settings file'
    }

    if ((Get-Content -LiteralPath $localSkillPath -Raw -Encoding utf8).Trim() -eq '# local only') {
        Add-Check 'install and uninstall preserve the original host-only system skill'
    } else {
        Add-Failure 'install and uninstall should preserve the original host-only system skill'
    }

    $legacyPointerAfter = Get-FileSnapshot -Path $legacyPointerPath
    if (Test-SameSnapshot -Left $legacyPointerBefore -Right $legacyPointerAfter) {
        Add-Check 'isolated install/uninstall leaves the legacy repo active-install pointer unchanged'
    } else {
        Add-Failure 'isolated install/uninstall should not mutate the legacy repo active-install pointer'
    }
} finally {
    $mixedCleanupFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($child in $mixedProcesses) {
        $childId = try { $child.Process.Id } catch { -1 }
        try {
            if (-not $child.Process.HasExited) {
                try {
                    $child.Process.Kill($true)
                } catch [System.InvalidOperationException] {
                    if (-not $child.Process.HasExited) {
                        throw
                    }
                }
                if (-not $child.Process.WaitForExit(10000)) {
                    throw ("process tree did not exit within cleanup timeout")
                }
            }
        } catch {
            $mixedCleanupFailures.Add(("mixed child {0} cleanup failed: {1}" -f $childId,$_.Exception.Message)) | Out-Null
        } finally {
            try {
                $child.Process.Dispose()
            } catch {
                $mixedCleanupFailures.Add(("mixed child {0} dispose failed: {1}" -f $childId,$_.Exception.Message)) | Out-Null
            }
        }
    }
    if ($mixedCleanupFailures.Count -eq 0) {
        try {
            if (Test-Path -LiteralPath $scratchRoot) {
                Remove-Item -LiteralPath $scratchRoot -Recurse -Force
            }
        } catch {
            $mixedCleanupFailures.Add(("scratch cleanup failed: {0}" -f $_.Exception.Message)) | Out-Null
        }
    }
    foreach ($cleanupFailure in $mixedCleanupFailures) {
        Add-Failure $cleanupFailure
    }
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    $script:Checks | ForEach-Object { Write-Output ("- {0}" -f $_) }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

$script:Failures | ForEach-Object { Write-Output ("- {0}" -f $_) }
Write-Output ''
Write-Output 'Command output:'
foreach ($result in $results) {
    $result.Output | ForEach-Object { Write-Output ([string]$_) }
}
exit 1
