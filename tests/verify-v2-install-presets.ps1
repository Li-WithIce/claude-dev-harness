[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Add-Check { param([string]$Message) $script:Checks.Add($Message) | Out-Null }
function Add-Failure { param([string]$Message) $script:Failures.Add($Message) | Out-Null }

function Invoke-ChildScript {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    $child = Start-RepoProcess -UserProfile $UserProfile -ScriptPath $ScriptPath -Arguments $Arguments
    try {
        if (-not $child.Process.WaitForExit(180000)) {
            try { $child.Process.Kill($true) } catch {}
            throw "Timed out waiting for $ScriptPath"
        }
        $stdout = $child.StdOut.GetAwaiter().GetResult()
        $stderr = $child.StdErr.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = $child.Process.ExitCode
            Output = @($stdout,$stderr | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }
    } finally {
        $child.Process.Dispose()
    }
}

function Invoke-ChildScriptWithInput {
    param(
        [string]$ScriptPath,
        [string]$InputText
    )

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = (Get-Process -Id $PID).Path
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$ScriptPath)) { $processInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill($true) } catch {}
            throw "Timed out waiting for $ScriptPath"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout.GetAwaiter().GetResult()
            StdErr = $stderr.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function New-PresetFixture {
    param([string]$Name)

    $root = Join-Path $script:ScratchRoot $Name
    $workspace = Join-Path $root 'workspace'
    $user = Join-Path $root 'user'
    New-Item -ItemType Directory -Path $workspace,$user -Force | Out-Null
    return [pscustomobject]@{ Root=$root;Workspace=$workspace;User=$user }
}

function Invoke-Install {
    param($Fixture,[string[]]$ExtraArguments=@())

    $arguments = @(
        '-WorkspaceRoot',$Fixture.Workspace,'-RepoRoot',$script:RepoRoot
    ) + @($ExtraArguments)
    return Invoke-ChildScript -UserProfile $Fixture.User -ScriptPath $script:InstallScript -Arguments $arguments
}

function Invoke-Uninstall {
    param($Fixture)

    return Invoke-ChildScript -UserProfile $Fixture.User -ScriptPath $script:UninstallScript -Arguments @(
        '-WorkspaceRoot',$Fixture.Workspace,'-RepoRoot',$script:RepoRoot
    )
}

function Get-LatestManifest {
    param($Fixture)

    $registryPath = Join-Path $Fixture.User '.dev-harness\install-registry.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "Missing install registry: $registryPath"
    }
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
    $workspace = Get-NormalizedPath -Path $Fixture.Workspace
    $entries = @($registry.workspaces.Values | Where-Object { (Get-NormalizedPath -Path $_.workspace_root) -eq $workspace })
    if ($entries.Count -ne 1 -or @($entries[0].manifests).Count -eq 0) {
        throw "Registry does not contain one manifest history for $workspace"
    }
    $manifestPath = @($entries[0].manifests)[-1]
    return Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
}

function Test-ExactSet {
    param($Actual,$Expected)
    return @(Compare-Object @($Actual) @($Expected)).Count -eq 0
}

function Assert-ManifestPreset {
    param(
        $Manifest,
        [string]$Preset,
        [string]$Source,
        [string[]]$Features,
        [string[]]$Skills,
        [string[]]$Hooks,
        [string]$VaultProfile
    )

    $valid = [string]$Manifest.effective_preset -ceq $Preset -and
        [string]$Manifest.preset_source -ceq $Source -and
        [string]$Manifest.effective_vault_profile -ceq $VaultProfile -and
        [string]$Manifest.feature_ownership.schema_version -ceq 'feature-ownership/v1' -and
        [string]$Manifest.feature_ownership.vault_profile -ceq $VaultProfile -and
        (Test-ExactSet $Manifest.feature_ownership.features $Features) -and
        (Test-ExactSet $Manifest.feature_ownership.skills $Skills) -and
        (Test-ExactSet $Manifest.feature_ownership.hooks $Hooks)
    if ($valid) {
        Add-Check "manifest records exact $Preset feature ownership from $Source"
    } else {
        Add-Failure "manifest does not record exact $Preset feature ownership from $Source"
    }
}

function Assert-InstallExit {
    param($Result,[string]$Label)
    if ($Result.ExitCode -eq 0) { Add-Check "$Label install succeeds" } else { Add-Failure "$Label install failed: $($Result.Output)" }
}

function Assert-UninstallExit {
    param($Result,[string]$Label)
    if ($Result.ExitCode -eq 0) { Add-Check "$Label uninstall succeeds" } else { Add-Failure "$Label uninstall failed: $($Result.Output)" }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$script:RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$script:InstallScript = Join-Path $script:RepoRoot 'install.ps1'
$script:UninstallScript = Join-Path $script:RepoRoot 'uninstall.ps1'
$script:Checks = [System.Collections.Generic.List[string]]::new()
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:ScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dev-harness-preset-test-' + [guid]::NewGuid().ToString('N'))
$coreSkills = @('.system','entry-router','orchestrator','plan','implement','review','test','spec')
$governedSkills = @($coreSkills + @('planning','audit'))
$fullSkills = @(
    '.system'
    Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'skills') -Force -Directory |
        Where-Object { $_.Name -cne '.system' } |
        Sort-Object Name |
        Select-Object -ExpandProperty Name
)
$coreHooks = @('pretooluse.ps1','stop.js','workspace-resolver.js')
$fullHooks = @('pretooluse.ps1','userpromptsubmit.js','stop.js','workspace-resolver.js')
$coreFeatures = @('core','v1-compatibility')
$governedFeatures = @('core','v1-compatibility','governed')
$fullFeatures = @('core','v1-compatibility','governed','memory','team','md-html','adapters','provider-references')

try {
    New-Item -ItemType Directory -Path $script:ScratchRoot -Force | Out-Null

    $defaultFixture = New-PresetFixture -Name 'default-core'
    $foreignSentinel = Join-Path $defaultFixture.User '.codex\skills\foreign-skill\sentinel.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $foreignSentinel) -Force | Out-Null
    [System.IO.File]::WriteAllText($foreignSentinel,'foreign-user-asset',[System.Text.UTF8Encoding]::new($false))
    $defaultInstall = Invoke-Install -Fixture $defaultFixture
    Assert-InstallExit $defaultInstall 'fresh default'
    if ($defaultInstall.ExitCode -eq 0) {
        Assert-ManifestPreset (Get-LatestManifest $defaultFixture) 'core' 'default-core' $coreFeatures $coreSkills $coreHooks 'minimal'
        $optionalPaths = @(
            (Join-Path $defaultFixture.User '.codex\skills\obsidian-memory'),
            (Join-Path $defaultFixture.User '.codex\skills\workflow-team'),
            (Join-Path $defaultFixture.User '.codex\skills\codex'),
            (Join-Path $defaultFixture.User '.claude\hooks-memory\userpromptsubmit.js')
        )
        if (@($optionalPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) {
            Add-Check 'core omits memory, team, adapter, and optional memory hook assets'
        } else {
            Add-Failure 'core installed an optional memory, team, adapter, or memory hook asset'
        }
        $installedPreToolHook = Join-Path $defaultFixture.User '.claude\hooks-memory\pretooluse.ps1'
        $adapterInput = [ordered]@{
            tool_name = 'Write'
            tool_input = [ordered]@{ file_path = (Join-Path $defaultFixture.Workspace 'notes.txt') }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $adapterResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $adapterInput
        if ($adapterResult.ExitCode -eq 0 -and $adapterResult.StdOut.Trim() -ceq '{}') {
            Add-Check 'Claude PreToolUse adapter accepts optional command and user prompt fields'
        } else {
            Add-Failure "Claude PreToolUse adapter rejected a valid Write payload: $($adapterResult.StdErr)"
        }
        Assert-UninstallExit (Invoke-Uninstall $defaultFixture) 'fresh default'
        if ((Test-Path -LiteralPath $foreignSentinel -PathType Leaf) -and
            [System.IO.File]::ReadAllText($foreignSentinel) -ceq 'foreign-user-asset') {
            Add-Check 'core install and uninstall preserve foreign skill assets'
        } else {
            Add-Failure 'core install or uninstall changed a foreign skill asset'
        }
    }

    $governedFixture = New-PresetFixture -Name 'governed'
    $governedInstall = Invoke-Install -Fixture $governedFixture -ExtraArguments @('-Preset','governed')
    Assert-InstallExit $governedInstall 'governed'
    if ($governedInstall.ExitCode -eq 0) {
        Assert-ManifestPreset (Get-LatestManifest $governedFixture) 'governed' 'preset' $governedFeatures $governedSkills $coreHooks 'minimal'
        if ((Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\planning')) -and
            (Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\audit')) -and
            -not (Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\obsidian-memory'))) {
            Add-Check 'governed adds planning and audit without memory'
        } else {
            Add-Failure 'governed skill selection is incorrect'
        }
        Assert-UninstallExit (Invoke-Uninstall $governedFixture) 'governed'
    }

    $minimalFixture = New-PresetFixture -Name 'legacy-minimal'
    $minimalInstall = Invoke-Install -Fixture $minimalFixture -ExtraArguments @('-VaultProfile','minimal')
    Assert-InstallExit $minimalInstall 'legacy minimal'
    if ($minimalInstall.ExitCode -eq 0) {
        Assert-ManifestPreset (Get-LatestManifest $minimalFixture) 'core' 'vault-profile:minimal' $coreFeatures $coreSkills $coreHooks 'minimal'
        if ($minimalInstall.Output -match 'VaultProfile is deprecated') { Add-Check 'legacy minimal emits migration warning' } else { Add-Failure 'legacy minimal did not emit migration warning' }
        Assert-UninstallExit (Invoke-Uninstall $minimalFixture) 'legacy minimal'
    }

    $detectedFullFixture = New-PresetFixture -Name 'detected-full-vault'
    New-Item -ItemType Directory -Path (Join-Path $detectedFullFixture.Workspace '.assistant\工作流') -Force | Out-Null
    $detectedFullInstall = Invoke-Install -Fixture $detectedFullFixture
    Assert-InstallExit $detectedFullInstall 'detected full vault'
    if ($detectedFullInstall.ExitCode -eq 0) {
        Assert-ManifestPreset (Get-LatestManifest $detectedFullFixture) 'full' 'detected-full-vault' $fullFeatures $fullSkills $fullHooks 'full'
        Assert-UninstallExit (Invoke-Uninstall $detectedFullFixture) 'detected full vault'
    }

    $fullFixture = New-PresetFixture -Name 'legacy-full-preserve'
    $fullInstall = Invoke-Install -Fixture $fullFixture -ExtraArguments @('-VaultProfile','full')
    Assert-InstallExit $fullInstall 'legacy full'
    if ($fullInstall.ExitCode -eq 0) {
        Assert-ManifestPreset (Get-LatestManifest $fullFixture) 'full' 'vault-profile:full' $fullFeatures $fullSkills $fullHooks 'full'
        if ($fullInstall.Output -match 'VaultProfile is deprecated') { Add-Check 'legacy full emits migration warning' } else { Add-Failure 'legacy full did not emit migration warning' }
        $preserveInstall = Invoke-Install -Fixture $fullFixture
        Assert-InstallExit $preserveInstall 'implicit full preservation'
        if ($preserveInstall.ExitCode -eq 0) {
            Assert-ManifestPreset (Get-LatestManifest $fullFixture) 'full' 'manifest-preserve' $fullFeatures $fullSkills $fullHooks 'full'
            if ((Test-Path -LiteralPath (Join-Path $fullFixture.User '.codex\skills\obsidian-memory')) -and
                (Test-Path -LiteralPath (Join-Path $fullFixture.User '.codex\skills\workflow-team')) -and
                (Test-Path -LiteralPath (Join-Path $fullFixture.User '.claude\hooks-memory\userpromptsubmit.js'))) {
                Add-Check 'implicit update preserves full optional capabilities'
            } else {
                Add-Failure 'implicit update shrank an existing full install'
            }
            Assert-UninstallExit (Invoke-Uninstall $fullFixture) 'preserved full update'
        }
    }

    $conflictFixture = New-PresetFixture -Name 'conflict'
    $conflictInstall = Invoke-Install -Fixture $conflictFixture -ExtraArguments @('-Preset','core','-VaultProfile','full')
    $conflictWroteState = (Test-Path -LiteralPath (Join-Path $conflictFixture.User '.dev-harness')) -or
        (Test-Path -LiteralPath (Join-Path $conflictFixture.Workspace 'AGENTS.md')) -or
        (Test-Path -LiteralPath (Join-Path $conflictFixture.Workspace '.assistant'))
    if ($conflictInstall.ExitCode -ne 0 -and $conflictInstall.Output -match 'conflicts with VaultProfile' -and -not $conflictWroteState) {
        Add-Check 'conflicting Preset and VaultProfile fail closed before writes'
    } else {
        Add-Failure "conflicting Preset and VaultProfile were not rejected before writes: $($conflictInstall.Output)"
    }
} catch {
    Add-Failure $_.Exception.Message
} finally {
    Remove-DirectoryWithRetry -Path $script:ScratchRoot
}

Write-Output ('Checks: {0}' -f $script:Checks.Count)
foreach ($check in $script:Checks) { Write-Output ('[PASS] ' + $check) }
if ($script:Failures.Count -gt 0) {
    foreach ($failure in $script:Failures) { Write-Output ('[FAIL] ' + $failure) }
    exit 1
}
Write-Output 'V2_INSTALL_PRESETS_PASS'
exit 0
