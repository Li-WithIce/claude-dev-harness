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

function Test-ManifestExcludesPath {
    param($Manifest,[string]$Path)
    $expected = Get-NormalizedPath -Path $Path
    $recorded = @($Manifest.managed_backup_targets) + @($Manifest.backups | ForEach-Object { $_.path })
    return @($recorded | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and (Get-NormalizedPath -Path $_) -eq $expected }).Count -eq 0
}

function Test-ManifestIncludesPath {
    param($Manifest,[string]$Path)

    $expected = Get-NormalizedPath -Path $Path
    return @($Manifest.managed_backup_targets | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_) -and (Get-NormalizedPath -Path $_) -eq $expected
        }).Count -eq 1
}

function Assert-InstalledTaskShim {
    param($Fixture,$Manifest,[string]$Label)

    $path = Join-Path $Fixture.Workspace '.assistant\entry\task.ps1'
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Test-ManifestIncludesPath -Manifest $Manifest -Path $path)) {
        Add-Check "$Label installs and owns the workspace task shim"
    } else {
        Add-Failure "$Label did not install and own the workspace task shim"
    }
}

function Assert-InstalledPowerShellEntriesParse {
    param($Fixture,[string]$Label)

    $paths = @(
        (Join-Path $Fixture.Workspace '.assistant\entry\task.ps1'),
        (Join-Path $Fixture.Workspace '.assistant\entry\advance-stage.ps1'),
        (Join-Path $Fixture.Workspace '.assistant\entry\validate-lite-artifacts.ps1'),
        (Join-Path $Fixture.User '.claude\hooks-memory\pretooluse.ps1')
    )
    $issues = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $issues.Add("missing $path")
            continue
        }
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
        foreach ($errorRecord in @($errors)) {
            $issues.Add("${path}: $($errorRecord.Message)")
        }
    }
    if ($issues.Count -eq 0) {
        Add-Check "$Label renders parseable PowerShell entry assets"
    } else {
        Add-Failure "$Label rendered invalid PowerShell entry assets: $($issues -join '; ')"
    }
}

function Assert-InstalledTaskProtocol {
    param($Fixture,[string]$Label)

    $taskId = 'installed-shim'
    $planPath = Join-Path $Fixture.Workspace "docs\tasks\$taskId\plan.md"
    New-Item -ItemType Directory -Path (Split-Path -Parent $planPath) -Force | Out-Null
    $planContent = @(
        '---'
        'task_id: installed-shim'
        'stage: PLAN'
        'tool: codex'
        'updated: 2026-07-16'
        '---'
        ''
    ) -join "`n"
    [System.IO.File]::WriteAllText($planPath,$planContent,[System.Text.UTF8Encoding]::new($false))

    $priorProtocol = $env:HARNESS_PROTOCOL
    $priorReport = $env:HARNESS_V2_ELIGIBILITY_REPORT
    $result = $null
    $replayResult = $null
    try {
        $env:HARNESS_PROTOCOL = 'auto'
        Remove-Item Env:HARNESS_V2_ELIGIBILITY_REPORT -ErrorAction SilentlyContinue
        $result = Invoke-ChildScript -UserProfile $Fixture.User -ScriptPath (Join-Path $Fixture.Workspace '.assistant\entry\task.ps1') -Arguments @(
            'protocol','-TaskId',$taskId,'-AsJson'
        )
        Remove-Item Env:HARNESS_PROTOCOL -ErrorAction SilentlyContinue
        $replayResult = Invoke-ChildScript -UserProfile $Fixture.User -ScriptPath (Join-Path $Fixture.Workspace '.assistant\entry\task.ps1') -Arguments @(
            'replay','-TransactionId','txn_00000000000000000000000000000000','-AsJson'
        )
    } finally {
        if ($null -eq $priorProtocol) { Remove-Item Env:HARNESS_PROTOCOL -ErrorAction SilentlyContinue } else { $env:HARNESS_PROTOCOL = $priorProtocol }
        if ($null -eq $priorReport) { Remove-Item Env:HARNESS_V2_ELIGIBILITY_REPORT -ErrorAction SilentlyContinue } else { $env:HARNESS_V2_ELIGIBILITY_REPORT = $priorReport }
    }

    $resultExit = if ($null -eq $result) { 'unavailable' } else { [string]$result.ExitCode }
    $resultOutput = if ($null -eq $result) { '' } else { [string]$result.Output }
    $replayExit = if ($null -eq $replayResult) { 'unavailable' } else { [string]$replayResult.ExitCode }
    $replayOutput = if ($null -eq $replayResult) { '' } else { [string]$replayResult.Output }
    $value = $null
    if ($resultExit -eq '0') {
        try { $value = $resultOutput.Trim() | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop } catch {}
    }
    if ($null -ne $value -and
        [string]$value.detected_protocol -ceq 'v1' -and
        [string]$value.selected_protocol -ceq 'v1' -and
        [string]$value.v1_plan_path -ceq "docs/tasks/$taskId/plan.md" -and
        [int]$value.side_effects.runtime_writes -eq 0 -and
        [int]$value.side_effects.artifact_writes -eq 0) {
        Add-Check "$Label executes protocol through the installed workspace-bound task shim"
    } else {
        Add-Failure "$Label installed task shim protocol call failed: exit=$resultExit output=$resultOutput"
    }
    if ($null -ne $replayResult -and $replayExit -eq '2' -and $replayOutput -match 'transaction journal not found' -and $replayOutput -notmatch 'HARNESS_PROTOCOL') {
        Add-Check "$Label installed task shim enters bounded v2 replay without caller protocol state"
    } else {
        Add-Failure "$Label installed task shim replay call failed unexpectedly: exit=$replayExit output=$replayOutput"
    }
}

function Assert-TaskShimRemoved {
    param($Fixture,[string]$Label)

    $path = Join-Path $Fixture.Workspace '.assistant\entry\task.ps1'
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Check "$Label removes its owned workspace task shim"
    } else {
        Add-Failure "$Label left its owned workspace task shim behind"
    }
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

function Assert-RolloutAbsent {
    param($Fixture,[string]$Label)
    $path = Join-Path $Fixture.Workspace '.assistant\runtime\rollout\v2-eligibility.json'
    if (-not (Test-Path -LiteralPath $path)) { Add-Check "$Label leaves the canonical rollout report absent" } else { Add-Failure "$Label generated or restored the canonical rollout report" }
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
    $coreRolloutSentinel = Join-Path $defaultFixture.Workspace '.assistant\runtime\rollout\v2-eligibility.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $coreRolloutSentinel) -Force | Out-Null
    $coreRolloutBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"installer_owned":false}')
    [System.IO.File]::WriteAllBytes($coreRolloutSentinel,$coreRolloutBytes)
    $defaultInstall = Invoke-Install -Fixture $defaultFixture
    Assert-InstallExit $defaultInstall 'fresh default'
    if ($defaultInstall.ExitCode -eq 0) {
        $defaultManifest = Get-LatestManifest $defaultFixture
        Assert-ManifestPreset $defaultManifest 'core' 'default-core' $coreFeatures $coreSkills $coreHooks 'minimal'
        Assert-InstalledTaskShim $defaultFixture $defaultManifest 'core install'
        Assert-InstalledTaskProtocol $defaultFixture 'core install'
        if (([System.IO.File]::ReadAllBytes($coreRolloutSentinel) -join ',') -ceq ($coreRolloutBytes -join ',') -and (Test-ManifestExcludesPath $defaultManifest $coreRolloutSentinel)) { Add-Check 'core install preserves and does not claim the canonical rollout report' } else { Add-Failure 'core install changed or claimed the canonical rollout report' }
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
        $coreUpdate = Invoke-Install -Fixture $defaultFixture
        Assert-InstallExit $coreUpdate 'core update'
        if ($coreUpdate.ExitCode -eq 0) {
            $coreUpdateManifest = Get-LatestManifest $defaultFixture
            Assert-InstalledTaskShim $defaultFixture $coreUpdateManifest 'core update'
            Assert-InstalledTaskProtocol $defaultFixture 'core update'
            if (([System.IO.File]::ReadAllBytes($coreRolloutSentinel) -join ',') -ceq ($coreRolloutBytes -join ',') -and (Test-ManifestExcludesPath $coreUpdateManifest $coreRolloutSentinel)) { Add-Check 'core update preserves and does not claim the canonical rollout report' } else { Add-Failure 'core update changed or claimed the canonical rollout report' }
        }
        Assert-UninstallExit (Invoke-Uninstall $defaultFixture) 'fresh default'
        Assert-TaskShimRemoved $defaultFixture 'core uninstall'
        if ((Test-Path -LiteralPath $foreignSentinel -PathType Leaf) -and [System.IO.File]::ReadAllText($foreignSentinel) -ceq 'foreign-user-asset' -and
            (Test-Path -LiteralPath $coreRolloutSentinel -PathType Leaf) -and ([System.IO.File]::ReadAllBytes($coreRolloutSentinel) -join ',') -ceq ($coreRolloutBytes -join ',')) {
            Add-Check 'core install and uninstall preserve foreign skill assets and canonical rollout evidence'
        } else {
            Add-Failure 'core install or uninstall changed a foreign skill asset or canonical rollout evidence'
        }
    }

    $apostropheFixture = New-PresetFixture -Name "apostrophe'shim-{VAULT_PATH}"
    $apostropheInstall = Invoke-Install -Fixture $apostropheFixture -ExtraArguments @('-Preset','core')
    Assert-InstallExit $apostropheInstall 'apostrophe workspace'
    if ($apostropheInstall.ExitCode -eq 0) {
        $apostropheManifest = Get-LatestManifest $apostropheFixture
        Assert-InstalledTaskShim $apostropheFixture $apostropheManifest 'apostrophe workspace'
        Assert-InstalledPowerShellEntriesParse $apostropheFixture 'apostrophe workspace'
        $apostropheShimPath = Join-Path $apostropheFixture.Workspace '.assistant\entry\task.ps1'
        $apostropheShimText = [System.IO.File]::ReadAllText($apostropheShimPath,[System.Text.Encoding]::UTF8)
        if ($apostropheShimText.Contains($apostropheFixture.Workspace.Replace("'","''")) -and
            -not $apostropheShimText.Contains('{WORKSPACE_ROOT}')) {
            Add-Check 'apostrophe workspace is escaped as PowerShell data without a leftover render token'
        } else {
            Add-Failure 'apostrophe workspace was not safely rendered into the task shim'
        }
        Assert-InstalledTaskProtocol $apostropheFixture 'apostrophe workspace'
        Assert-UninstallExit (Invoke-Uninstall $apostropheFixture) 'apostrophe workspace'
        Assert-TaskShimRemoved $apostropheFixture 'apostrophe workspace uninstall'
    }

    $governedFixture = New-PresetFixture -Name 'governed'
    $governedInstall = Invoke-Install -Fixture $governedFixture -ExtraArguments @('-Preset','governed')
    Assert-InstallExit $governedInstall 'governed'
    if ($governedInstall.ExitCode -eq 0) {
        $governedManifest = Get-LatestManifest $governedFixture
        Assert-ManifestPreset $governedManifest 'governed' 'preset' $governedFeatures $governedSkills $coreHooks 'minimal'
        Assert-InstalledTaskShim $governedFixture $governedManifest 'governed install'
        Assert-InstalledTaskProtocol $governedFixture 'governed install'
        if ((Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\planning')) -and
            (Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\audit')) -and
            -not (Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\obsidian-memory'))) {
            Add-Check 'governed adds planning and audit without memory'
        } else {
            Add-Failure 'governed skill selection is incorrect'
        }
        $governedUpdate = Invoke-Install -Fixture $governedFixture
        Assert-InstallExit $governedUpdate 'implicit governed preservation'
        if ($governedUpdate.ExitCode -eq 0) {
            $governedUpdateManifest = Get-LatestManifest $governedFixture
            Assert-ManifestPreset $governedUpdateManifest 'governed' 'manifest-preserve' $governedFeatures $governedSkills $coreHooks 'minimal'
            Assert-InstalledTaskShim $governedFixture $governedUpdateManifest 'governed update'
            Assert-InstalledTaskProtocol $governedFixture 'governed update'
            if ((Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\planning')) -and
                (Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\audit')) -and
                -not (Test-Path -LiteralPath (Join-Path $governedFixture.User '.codex\skills\obsidian-memory'))) {
                Add-Check 'implicit update preserves governed planning and audit without memory'
            } else {
                Add-Failure 'implicit update changed governed skill selection'
            }
        }
        Assert-UninstallExit (Invoke-Uninstall $governedFixture) 'governed'
        Assert-TaskShimRemoved $governedFixture 'governed uninstall'
    }

    $governedAutoFixture = New-PresetFixture -Name 'governed-with-legacy-auto'
    $governedAutoInstall = Invoke-Install -Fixture $governedAutoFixture -ExtraArguments @('-Preset','governed','-VaultProfile','auto')
    Assert-InstallExit $governedAutoInstall 'governed with legacy auto'
    if ($governedAutoInstall.ExitCode -eq 0) {
        Assert-ManifestPreset (Get-LatestManifest $governedAutoFixture) 'governed' 'preset+vault-profile:auto' $governedFeatures $governedSkills $coreHooks 'minimal'
        if ($governedAutoInstall.Output -match 'VaultProfile is deprecated' -and
            $governedAutoInstall.Output -notmatch 'conflicts with VaultProfile') {
            Add-Check 'explicit governed preset accepts legacy VaultProfile auto without downgrading to core'
        } else {
            Add-Failure 'explicit governed preset did not accept legacy VaultProfile auto as an unconstrained compatibility hint'
        }
        Assert-UninstallExit (Invoke-Uninstall $governedAutoFixture) 'governed with legacy auto'
    }

    $minimalFixture = New-PresetFixture -Name 'legacy-minimal'
    $minimalInstall = Invoke-Install -Fixture $minimalFixture -ExtraArguments @('-VaultProfile','minimal')
    Assert-InstallExit $minimalInstall 'legacy minimal'
    if ($minimalInstall.ExitCode -eq 0) {
        Assert-ManifestPreset (Get-LatestManifest $minimalFixture) 'core' 'vault-profile:minimal' $coreFeatures $coreSkills $coreHooks 'minimal'
        if ($minimalInstall.Output -match 'VaultProfile is deprecated') { Add-Check 'legacy minimal emits migration warning' } else { Add-Failure 'legacy minimal did not emit migration warning' }
        Assert-UninstallExit (Invoke-Uninstall $minimalFixture) 'legacy minimal'
    }

    $presetCoreFixture = New-PresetFixture -Name 'preset-core-absent-rollout'
    $presetCoreInstall = Invoke-Install -Fixture $presetCoreFixture -ExtraArguments @('-Preset','core')
    Assert-InstallExit $presetCoreInstall 'explicit core without rollout report'
    if ($presetCoreInstall.ExitCode -eq 0) {
        Assert-RolloutAbsent $presetCoreFixture 'core install'
        $presetCoreManifest = Get-LatestManifest $presetCoreFixture
        $presetCoreRolloutSentinel = Join-Path $presetCoreFixture.Workspace '.assistant\runtime\rollout\v2-eligibility.json'
        if (Test-ManifestExcludesPath $presetCoreManifest $presetCoreRolloutSentinel) { Add-Check 'core install does not claim an absent canonical rollout report' } else { Add-Failure 'core install claimed an absent canonical rollout report' }
        $presetCoreRolloutBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"installer_owned":false,"arrival":"after-core-install"}')
        New-Item -ItemType Directory -Path (Split-Path -Parent $presetCoreRolloutSentinel) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($presetCoreRolloutSentinel,$presetCoreRolloutBytes)
        $presetCoreUpdate = Invoke-Install -Fixture $presetCoreFixture -ExtraArguments @('-Preset','core')
        Assert-InstallExit $presetCoreUpdate 'explicit core update without rollout report'
        if ($presetCoreUpdate.ExitCode -eq 0) {
            $presetCoreUpdateManifest = Get-LatestManifest $presetCoreFixture
            if (([System.IO.File]::ReadAllBytes($presetCoreRolloutSentinel) -join ',') -ceq ($presetCoreRolloutBytes -join ',') -and (Test-ManifestExcludesPath $presetCoreUpdateManifest $presetCoreRolloutSentinel)) { Add-Check 'core update preserves and does not claim a rollout report created after install' } else { Add-Failure 'core update changed or claimed a rollout report created after install' }
        }
        Assert-UninstallExit (Invoke-Uninstall $presetCoreFixture) 'explicit core without rollout report'
        if ((Test-Path -LiteralPath $presetCoreRolloutSentinel -PathType Leaf) -and ([System.IO.File]::ReadAllBytes($presetCoreRolloutSentinel) -join ',') -ceq ($presetCoreRolloutBytes -join ',')) { Add-Check 'core uninstall preserves a rollout report created after install' } else { Add-Failure 'core uninstall removed or changed a rollout report created after install' }
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
    $fullRolloutSentinel=Join-Path $fullFixture.Workspace '.assistant\runtime\rollout\v2-eligibility.json';New-Item -ItemType Directory -Path (Split-Path -Parent $fullRolloutSentinel) -Force|Out-Null;$fullRolloutBytes=[System.Text.UTF8Encoding]::new($false).GetBytes('{"installer_owned":false,"preset":"full"}');[System.IO.File]::WriteAllBytes($fullRolloutSentinel,$fullRolloutBytes)
    $fullInstall = Invoke-Install -Fixture $fullFixture -ExtraArguments @('-VaultProfile','full')
    Assert-InstallExit $fullInstall 'legacy full'
    if ($fullInstall.ExitCode -eq 0) {
        $fullInstallManifest=Get-LatestManifest $fullFixture
        Assert-ManifestPreset $fullInstallManifest 'full' 'vault-profile:full' $fullFeatures $fullSkills $fullHooks 'full'
        Assert-InstalledTaskShim $fullFixture $fullInstallManifest 'full install'
        Assert-InstalledTaskProtocol $fullFixture 'full install'
        if ($fullInstall.Output -match 'VaultProfile is deprecated') { Add-Check 'legacy full emits migration warning' } else { Add-Failure 'legacy full did not emit migration warning' }
        if (([System.IO.File]::ReadAllBytes($fullRolloutSentinel)-join',') -ceq ($fullRolloutBytes-join',') -and (Test-ManifestExcludesPath $fullInstallManifest $fullRolloutSentinel)) { Add-Check 'full fresh install preserves and does not claim the canonical rollout report' } else { Add-Failure 'full fresh install changed or claimed the canonical rollout report' }
        $preserveInstall = Invoke-Install -Fixture $fullFixture
        Assert-InstallExit $preserveInstall 'implicit full preservation'
        if ($preserveInstall.ExitCode -eq 0) {
            $preserveManifest=Get-LatestManifest $fullFixture
            Assert-ManifestPreset $preserveManifest 'full' 'manifest-preserve' $fullFeatures $fullSkills $fullHooks 'full'
            Assert-InstalledTaskShim $fullFixture $preserveManifest 'full update'
            Assert-InstalledTaskProtocol $fullFixture 'full update'
            if (([System.IO.File]::ReadAllBytes($fullRolloutSentinel)-join',') -ceq ($fullRolloutBytes-join',') -and (Test-ManifestExcludesPath $preserveManifest $fullRolloutSentinel)) { Add-Check 'full update preserves and does not claim the canonical rollout report' } else { Add-Failure 'full update changed or claimed the canonical rollout report' }
            if ((Test-Path -LiteralPath (Join-Path $fullFixture.User '.codex\skills\obsidian-memory')) -and
                (Test-Path -LiteralPath (Join-Path $fullFixture.User '.codex\skills\workflow-team')) -and
                (Test-Path -LiteralPath (Join-Path $fullFixture.User '.claude\hooks-memory\userpromptsubmit.js'))) {
                Add-Check 'implicit update preserves full optional capabilities'
            } else {
                Add-Failure 'implicit update shrank an existing full install'
            }
            Assert-UninstallExit (Invoke-Uninstall $fullFixture) 'preserved full update'
            Assert-TaskShimRemoved $fullFixture 'full uninstall'
            if ((Test-Path -LiteralPath $fullRolloutSentinel -PathType Leaf) -and ([System.IO.File]::ReadAllBytes($fullRolloutSentinel)-join',') -ceq ($fullRolloutBytes-join',')) { Add-Check 'full uninstall preserves canonical rollout evidence' } else { Add-Failure 'full uninstall removed or changed canonical rollout evidence' }
        }
    }

    $presetFullFixture = New-PresetFixture -Name 'preset-full-absent-rollout'
    $presetFullInstall = Invoke-Install -Fixture $presetFullFixture -ExtraArguments @('-Preset','full')
    Assert-InstallExit $presetFullInstall 'explicit full without rollout report'
    if ($presetFullInstall.ExitCode -eq 0) {
        Assert-RolloutAbsent $presetFullFixture 'full install'
        $presetFullManifest = Get-LatestManifest $presetFullFixture
        $presetFullRolloutSentinel = Join-Path $presetFullFixture.Workspace '.assistant\runtime\rollout\v2-eligibility.json'
        if (Test-ManifestExcludesPath $presetFullManifest $presetFullRolloutSentinel) { Add-Check 'full install does not claim an absent canonical rollout report' } else { Add-Failure 'full install claimed an absent canonical rollout report' }
        $presetFullRolloutBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"installer_owned":false,"arrival":"after-full-install"}')
        New-Item -ItemType Directory -Path (Split-Path -Parent $presetFullRolloutSentinel) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($presetFullRolloutSentinel,$presetFullRolloutBytes)
        $presetFullUpdate = Invoke-Install -Fixture $presetFullFixture -ExtraArguments @('-Preset','full')
        Assert-InstallExit $presetFullUpdate 'explicit full update without rollout report'
        if ($presetFullUpdate.ExitCode -eq 0) {
            $presetFullUpdateManifest = Get-LatestManifest $presetFullFixture
            if (([System.IO.File]::ReadAllBytes($presetFullRolloutSentinel) -join ',') -ceq ($presetFullRolloutBytes -join ',') -and (Test-ManifestExcludesPath $presetFullUpdateManifest $presetFullRolloutSentinel)) { Add-Check 'full update preserves and does not claim a rollout report created after install' } else { Add-Failure 'full update changed or claimed a rollout report created after install' }
        }
        Assert-UninstallExit (Invoke-Uninstall $presetFullFixture) 'explicit full without rollout report'
        if ((Test-Path -LiteralPath $presetFullRolloutSentinel -PathType Leaf) -and ([System.IO.File]::ReadAllBytes($presetFullRolloutSentinel) -join ',') -ceq ($presetFullRolloutBytes -join ',')) { Add-Check 'full uninstall preserves a rollout report created after install' } else { Add-Failure 'full uninstall removed or changed a rollout report created after install' }
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
