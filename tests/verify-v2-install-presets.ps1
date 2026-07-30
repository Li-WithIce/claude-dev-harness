[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Add-Check { param([string]$Message) $script:Checks.Add($Message) | Out-Null }
function Add-Failure { param([string]$Message) $script:Failures.Add($Message) | Out-Null }

function Get-TestStringSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($Value))
    } finally {
        $sha256.Dispose()
    }
    return [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
}

function Get-TestFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

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
        [string]$InputText,
        [hashtable]$Environment = @{}
    )

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = (Get-Process -Id $PID).Path
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true
    foreach ($name in @(
        'DEV_HARNESS_WORKSPACE_ROOT','HARNESS_TASK_ID','HARNESS_EXPECTED_VERSION','HARNESS_SESSION_MODE',
        'HARNESS_ENVIRONMENT','HARNESS_DRY_RUN','HARNESS_HOST_QUALIFICATION','HARNESS_SECRET_PROVIDER',
        'CODEX_VERSION','VAULT_ADDR','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AZURE_CLIENT_SECRET',
        'GOOGLE_APPLICATION_CREDENTIALS','KMS_KEY_ID'
    )) {
        [void]$processInfo.Environment.Remove($name)
    }
    foreach ($name in $Environment.Keys) { $processInfo.Environment[$name] = [string]$Environment[$name] }
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

function Invoke-CodexHookCommandWithInput {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('cmd','pwsh','powershell')][string]$Runner,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$InputText,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [ValidateRange(0,65535)][int]$CodePage = 0,
        [hashtable]$Environment = @{}
    )

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = switch ($Runner) {
        'cmd' { $env:ComSpec }
        'pwsh' { (Get-Process -Id $PID).Path }
        'powershell' { Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe' }
    }
    $processInfo.WorkingDirectory = $WorkingDirectory
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardInput = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $processInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $processInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($name in @(
        'DEV_HARNESS_WORKSPACE_ROOT','HARNESS_TASK_ID','HARNESS_EXPECTED_VERSION','HARNESS_SESSION_MODE',
        'HARNESS_ENVIRONMENT','HARNESS_DRY_RUN','HARNESS_HOST_QUALIFICATION','HARNESS_SECRET_PROVIDER',
        'CODEX_VERSION','VAULT_ADDR','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AZURE_CLIENT_SECRET',
        'GOOGLE_APPLICATION_CREDENTIALS','KMS_KEY_ID'
    )) {
        [void]$processInfo.Environment.Remove($name)
    }
    foreach ($name in $Environment.Keys) { $processInfo.Environment[$name] = [string]$Environment[$name] }
    if ($CodePage -ne 0 -and $Runner -ne 'cmd') { throw 'CodePage is supported only by the cmd fixture' }
    $arguments = if ($Runner -eq 'cmd') {
        $effectiveCommand = if ($CodePage -eq 0) { $Command } else { "chcp $CodePage >nul && $Command" }
        @('/C',$effectiveCommand)
    } else {
        @('-NoProfile','-Command',$Command)
    }
    foreach ($argument in $arguments) {
        $processInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($InputText)
        $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill($true) } catch {}
            throw "Timed out waiting for Codex hook through $Runner"
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

function Test-CodexDenyOutput {
    param($Result,[string]$ReasonPattern)

    if ($Result.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($Result.StdErr)) { return $false }
    try {
        $document = $Result.StdOut | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        return @($document.Keys).Count -eq 1 -and
            $document.Contains('hookSpecificOutput') -and
            @($document.hookSpecificOutput.Keys).Count -eq 3 -and
            [string]$document.hookSpecificOutput.hookEventName -ceq 'PreToolUse' -and
            [string]$document.hookSpecificOutput.permissionDecision -ceq 'deny' -and
            [string]$document.hookSpecificOutput.permissionDecisionReason -match $ReasonPattern
    } catch {
        return $false
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

function Set-TestLegacyManagedConfigState {
    param(
        $Fixture,
        [Parameter(Mandatory = $true)][string]$ExternalBaselineText,
        [Parameter(Mandatory = $true)][string]$LegacyManagedText
    )

    $registryPath = Join-Path $Fixture.User '.dev-harness\install-registry.json'
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
    $workspaceKey = (Get-NormalizedPath -Path $Fixture.Workspace).TrimEnd('\','/').ToLowerInvariant()
    $manifestPath = [string]@($registry.workspaces[$workspaceKey].manifests)[-1]
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
    $managedConfigPath = Join-Path $Fixture.User '.codex\managed_config.toml'
    $externalBackupPath = Join-Path $manifest.backup_root 'legacy-managed-config-external-baseline.toml'
    [System.IO.File]::WriteAllText($externalBackupPath,$ExternalBaselineText,[System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($managedConfigPath,$LegacyManagedText,[System.Text.UTF8Encoding]::new($false))
    $legacyRecord = [ordered]@{
        path = (Get-NormalizedPath -Path $managedConfigPath)
        existed = $true
        backup_path = (Get-NormalizedPath -Path $externalBackupPath)
        item_type = 'file'
        link_type = $null
        link_target = $null
        backup_payload_sha256 = (Get-TestFileSha256 -Path $externalBackupPath)
        scope = 'user-global'
        ownership = 'managed'
        expected_postimage = [ordered]@{
            mode = 'exact'
            item_type = 'file'
            sha256 = (Get-TestFileSha256 -Path $managedConfigPath)
        }
    }
    $manifest.managed_backup_targets = @($manifest.managed_backup_targets + $legacyRecord.path | Select-Object -Unique)
    $manifest.backups = @($manifest.backups + $legacyRecord)
    foreach ($record in @($manifest.backups)) {
        if ($record.expected_postimage -is [System.Collections.IDictionary] -and
            $record.expected_postimage.Contains('contract') -and
            [string]$record.expected_postimage.contract -ceq 'claude-settings/v1') {
            [void]$record.expected_postimage.Remove('preimage_managed_hooks')
        }
    }
    [System.IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 50),[System.Text.UTF8Encoding]::new($false))
    $manifestDigestKey = Get-TestStringSha256 -Value ((Get-NormalizedPath -Path $manifestPath).ToLowerInvariant())
    $registry.manifest_digests[$manifestDigestKey] = Get-TestFileSha256 -Path $manifestPath
    [System.IO.File]::WriteAllText($registryPath,($registry | ConvertTo-Json -Depth 50),[System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        RegistryPath = $registryPath
        ManifestPath = (Get-NormalizedPath -Path $manifestPath)
        ManagedConfigPath = $managedConfigPath
    }
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

function New-ProtocolConfigSentinel {
    param($Fixture,[ValidateSet('auto','v1','v2')][string]$Protocol = 'v2')

    $path = Join-Path $Fixture.Workspace '.assistant\config\protocol.json'
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((@{
        schema_version = 'harness-protocol-config/v1'
        new_task_protocol = $Protocol
    } | ConvertTo-Json -Compress) + "`n")
    [System.IO.File]::WriteAllBytes($path,$bytes)
    return [pscustomobject]@{Path=$path;Bytes=$bytes}
}

function Assert-ProtocolConfigPreserved {
    param($Fixture,$Sentinel,$Manifest,[string]$Label)

    $path = [string]$Sentinel.Path
    $exact = Test-Path -LiteralPath $path -PathType Leaf
    if ($exact) {
        $actual = [System.IO.File]::ReadAllBytes($path)
        $exact = ($actual.Length -eq $Sentinel.Bytes.Length)
        if ($exact) {
            for ($index=0;$index -lt $actual.Length;$index++) {
                if ($actual[$index] -ne $Sentinel.Bytes[$index]) { $exact = $false; break }
            }
        }
    }
    $unclaimed = $null -eq $Manifest -or (Test-ManifestExcludesPath -Manifest $Manifest -Path $path)
    if ($exact -and $unclaimed) {
        Add-Check "$Label preserves exact user protocol config bytes without claiming ownership"
    } else {
        Add-Failure "$Label changed, removed, or claimed the user protocol config"
    }
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
        (Join-Path $Fixture.User '.claude\hooks-memory\pretooluse.ps1'),
        (Join-Path $Fixture.User '.claude\hooks-memory\codex-pretooluse-launcher.ps1')
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

function Assert-InstalledCodexHook {
    param($Fixture,[string]$Label,[switch]$RequireForeign)

    $hooksPath = Join-Path $Fixture.User '.codex\hooks.json'
    try {
        $rawDocument = Get-Content -LiteralPath $hooksPath -Raw -Encoding utf8
        $document = $rawDocument | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        $expectedPath = Join-Path $Fixture.User '.claude\hooks-memory\codex-pretooluse-launcher.ps1'
        $windowsPowerShell = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
        $expectedCommand = '{0} -NoLogo -NoProfile -NonInteractive -Command . ''{1}''' -f $windowsPowerShell,$expectedPath.Replace("'", "''")
        $harnessHooks = @(
            foreach ($eventName in @($document.hooks.Keys)) {
                foreach ($section in @($document.hooks[$eventName])) {
                    foreach ($hook in @($section.hooks)) {
                        if ([string]$hook.command -ceq $expectedCommand) {
                            [pscustomobject]@{ Event=$eventName;Section=$section;Hook=$hook }
                        }
                    }
                }
            }
        )
        $validHarness = $harnessHooks.Count -eq 1 -and
            [string]$harnessHooks[0].Event -ceq 'PreToolUse' -and
            [string]$harnessHooks[0].Section.matcher -ceq '^(Bash|apply_patch|Write|Edit|MultiEdit|NotebookEdit)$' -and
            [string]$harnessHooks[0].Hook.type -ceq 'command' -and
            [int]$harnessHooks[0].Hook.timeout -eq 15
        $foreignPreTool = @(
            if ($document['hooks'].Contains('PreToolUse')) {
                $document['hooks']['PreToolUse'] | Where-Object { [string]$_['matcher'] -ceq '^ForeignTool$' }
            }
        )
        $foreignStop = @(if ($document['hooks'].Contains('Stop')) { $document['hooks']['Stop'] } else { @() })
        $foreignMetadata = $document['foreign_metadata']
        $validForeign = -not $RequireForeign -or (
            [string]$document.description -ceq 'foreign hook sentinel' -and
            $foreignMetadata -is [System.Collections.IDictionary] -and
            [string]$foreignMetadata['owner'] -ceq 'fixture' -and
            [string]$foreignMetadata['timestamp'] -ceq '2024-01-01T00:00:00+09:00' -and
            $foreignMetadata.Contains('CaseKey') -and
            $foreignMetadata.Contains('casekey') -and
            [string]$foreignMetadata['CaseKey'] -ceq 'upper' -and
            [string]$foreignMetadata['casekey'] -ceq 'lower' -and
            $rawDocument -match '"large_integer"\s*:\s*18446744073709551616' -and
            $rawDocument -match '"precise_decimal"\s*:\s*0\.1234567890123456789012345678' -and
            $foreignPreTool.Count -eq 1 -and
            @($foreignPreTool[0].hooks).Count -eq 1 -and
            [string]$foreignPreTool[0].hooks[0].type -ceq 'command' -and
            [string]$foreignPreTool[0].hooks[0].command -ceq 'foreign-pretool' -and
            [int]$foreignPreTool[0].hooks[0].timeout -eq 7 -and
            $foreignStop.Count -eq 1 -and
            @($foreignStop[0].hooks).Count -eq 1 -and
            [string]$foreignStop[0].hooks[0].type -ceq 'command' -and
            [string]$foreignStop[0].hooks[0].command -ceq 'foreign-stop' -and
            [int]$foreignStop[0].hooks[0].timeout -eq 8
        )
        if ($validHarness -and $validForeign) {
            Add-Check "$Label configures exactly one ordinary Codex user hook and preserves foreign hooks"
        } else {
            Add-Failure "$Label Codex hooks.json merge is invalid"
        }
    } catch {
        Add-Failure "$Label Codex hooks.json is unavailable or invalid: $($_.Exception.Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$script:RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$script:InstallScript = Join-Path $script:RepoRoot 'install.ps1'
$script:UninstallScript = Join-Path $script:RepoRoot 'uninstall.ps1'
. (Join-Path $script:RepoRoot 'scripts\install-transaction-common.ps1')
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
$coreHooks = @('pretooluse.ps1','codex-pretooluse-launcher.ps1','stop.js','workspace-resolver.js')
$fullHooks = @('pretooluse.ps1','codex-pretooluse-launcher.ps1','userpromptsubmit.js','stop.js','workspace-resolver.js')
$coreFeatures = @('core','v1-compatibility')
$governedFeatures = @('core','v1-compatibility','governed')
$fullFeatures = @('core','v1-compatibility','governed','memory','team','md-html','adapters','provider-references')

try {
    New-Item -ItemType Directory -Path $script:ScratchRoot -Force | Out-Null

    $exactNumberToken = '0.1234567890123456789012345678'
    try {
        $exactNumberDocument = ConvertFrom-InstallJson -Json ('{"value":' + $exactNumberToken + '}')
        $exactNumberText = ([decimal]$exactNumberDocument['value']).ToString('G29',[System.Globalization.CultureInfo]::InvariantCulture)
        if ($exactNumberDocument['value'] -is [decimal] -and
            (Get-InstallJsonNumberCanonicalValue -Value $exactNumberText) -ceq
            (Get-InstallJsonNumberCanonicalValue -Value $exactNumberToken)) {
            Add-Check 'install JSON parser preserves an exactly representable 28-digit decimal'
        } else {
            Add-Failure 'install JSON parser changed an exactly representable 28-digit decimal'
        }
    } catch {
        Add-Failure "install JSON parser rejected an exactly representable decimal: $($_.Exception.Message)"
    }
    foreach ($exactIntegerToken in @('18446744073709551616','-9223372036854775809')) {
        try {
            $exactIntegerDocument = ConvertFrom-InstallJson -Json ('{"value":' + $exactIntegerToken + '}')
            $exactIntegerJson = ConvertTo-InstallJson -Value $exactIntegerDocument -Depth 10 -Compress
            $exactIntegerRoundTrip = ConvertFrom-InstallJson -Json $exactIntegerJson
            if ($exactIntegerDocument['value'] -is [System.Numerics.BigInteger] -and
                $exactIntegerRoundTrip['value'] -is [System.Numerics.BigInteger] -and
                [string]$exactIntegerRoundTrip['value'] -ceq $exactIntegerToken -and
                $exactIntegerJson -ceq ('{"value":' + $exactIntegerToken + '}')) {
                Add-Check "install JSON writer preserves a BigInteger as an exact JSON number: $exactIntegerToken"
            } else {
                Add-Failure "install JSON writer changed a BigInteger value or shape: $exactIntegerToken"
            }
        } catch {
            Add-Failure "install JSON writer rejected an exact BigInteger ${exactIntegerToken}: $($_.Exception.Message)"
        }
    }
    foreach ($inexactNumberToken in @('1e-29','1.23456789012345678901234567895','1e100')) {
        try {
            [void](ConvertFrom-InstallJson -Json ('{"value":' + $inexactNumberToken + '}'))
            Add-Failure "install JSON parser silently accepted an inexact number: $inexactNumberToken"
        } catch {
            if ($_.Exception.Message -match 'cannot be represented exactly') {
                Add-Check "install JSON parser rejects an inexact number without rewriting it: $inexactNumberToken"
            } else {
                Add-Failure "install JSON parser rejected $inexactNumberToken for an unexpected reason: $($_.Exception.Message)"
            }
        }
    }
    try {
        Assert-InstallRegistryReleaseMarkerCoverage `
            -Registry ([ordered]@{ released_target_history = @() }) `
            -ExpectedUserProfile $script:ScratchRoot `
            -ManifestPaths @()
        Add-Check 'release marker coverage accepts an empty fresh registry history'
    } catch {
        Add-Failure "release marker coverage rejected an empty fresh registry history: $($_.Exception.Message)"
    }

    $defaultFixture = New-PresetFixture -Name 'default-core'
    $foreignSentinel = Join-Path $defaultFixture.User '.codex\skills\foreign-skill\sentinel.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $foreignSentinel) -Force | Out-Null
    [System.IO.File]::WriteAllText($foreignSentinel,'foreign-user-asset',[System.Text.UTF8Encoding]::new($false))
    $foreignManagedConfig = Join-Path $defaultFixture.User '.codex\managed_config.toml'
    $foreignManagedText = "# Managed by install.ps1`r`nallow_managed_hooks_only = true`r`n[features]`r`nhooks = false`r`n"
    [System.IO.File]::WriteAllText($foreignManagedConfig,$foreignManagedText,[System.Text.UTF8Encoding]::new($false))
    $foreignManagedBytes = [System.IO.File]::ReadAllBytes($foreignManagedConfig)
    $foreignHooksPath = Join-Path $defaultFixture.User '.codex\hooks.json'
    $foreignHooks = @'
{
  "description": "foreign hook sentinel",
  "foreign_metadata": {
    "owner": "fixture",
    "timestamp": "2024-01-01T00:00:00+09:00",
    "CaseKey": "upper",
    "casekey": "lower",
    "large_integer": 18446744073709551616,
    "precise_decimal": 0.1234567890123456789012345678,
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "^ForeignTool$", "hooks": [{ "type": "command", "command": "foreign-pretool", "timeout": 7 }] },
      { "matcher": "^(Bash|apply_patch|Write|Edit|MultiEdit|NotebookEdit)$", "hooks": [{ "type": "command", "command": "third-party-shape-collision", "timeout": 15 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "foreign-stop", "timeout": 8 }] }
    ]
  }
}
'@
    [System.IO.File]::WriteAllText($foreignHooksPath,$foreignHooks,[System.Text.UTF8Encoding]::new($false))
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
        if (([System.IO.File]::ReadAllBytes($foreignManagedConfig) -join ',') -ceq ($foreignManagedBytes -join ',') -and
            (Test-ManifestExcludesPath $defaultManifest $foreignManagedConfig)) {
            Add-Check 'core install preserves external Codex managed policy without claiming ownership'
        } else {
            Add-Failure 'core install changed or claimed external Codex managed policy'
        }
        $defaultVerify = Invoke-ChildScript -UserProfile $defaultFixture.User -ScriptPath (Join-Path $script:RepoRoot 'tests\verify-installation.ps1') -Arguments @(
            '-WorkspaceRoot',$defaultFixture.Workspace,'-RepoRoot',$script:RepoRoot,'-Scope','All'
        )
        if ($defaultVerify.ExitCode -eq 0 -and
            $defaultVerify.Output -match '(?m)^STATUS: PASS\r?$' -and
            $defaultVerify.Output -notmatch 'LIVE_UPDATE_REQUIRED: legacy Harness managed_config') {
            Add-Check 'installation verification treats legacy-looking Codex managed policy as external ownership'
        } else {
            Add-Failure "installation verification misclassified external Codex managed policy: exit=$($defaultVerify.ExitCode) output=$($defaultVerify.Output)"
        }
        Assert-InstalledCodexHook -Fixture $defaultFixture -Label 'core install' -RequireForeign
        $hooksRecord = @($defaultManifest.backups | Where-Object { (Get-NormalizedPath -Path $_.path) -eq (Get-NormalizedPath -Path $foreignHooksPath) })
        if ($hooksRecord.Count -eq 1 -and [string]$hooksRecord[0].expected_postimage.contract -ceq 'claude-settings/v1') {
            Add-Check 'core install records semantic ownership for the ordinary Codex hook source'
        } else {
            Add-Failure 'core install did not record semantic ownership for Codex hooks.json'
        }
        $fixtureSecrets = [ordered]@{
            Database = 'fixture-only-' + 'db-password'
            Api = 'fixture-only-' + 'api-key'
            Client = 'fixture-only-' + 'client-secret'
            Webhook = 'fixture-only-' + 'webhook-secret'
            ObjectStorage = 'fixture-only-' + 'object-storage-key'
            Queue = 'fixture-only-' + 'queue-credential'
            Smtp = 'fixture-only-' + 'smtp-credential'
        }
        $containsFixtureSecret = {
            param($Result)
            $output = [string]$Result.StdOut + [string]$Result.StdErr
            return @($fixtureSecrets.Values | Where-Object { $output.Contains([string]$_) }).Count -gt 0
        }
        $gitIgnorePath = Join-Path $defaultFixture.Workspace '.gitignore'
        $gitIgnoreExisted = Test-Path -LiteralPath $gitIgnorePath -PathType Leaf
        $gitIgnorePreimage = if ($gitIgnoreExisted) { Get-TestFileSha256 -Path $gitIgnorePath } else { '' }
        $productionFileCases = @(
            [ordered]@{
                Name='Write appsettings.Production.json';Tool='Write';Version='fixture-old-version';Qualification='failed'
                Input=[ordered]@{file_path=(Join-Path $defaultFixture.Workspace 'appsettings.Production.json');content=('Server=fixture-db.internal;Database=fixture;User Id=fixture;Password=' + $fixtureSecrets.Database)}
            },
            [ordered]@{
                Name='Edit .env.production';Tool='Edit';Version='fixture-future-version';Qualification='unavailable'
                Input=[ordered]@{file_path=(Join-Path $defaultFixture.Workspace '.env.production');old_string='FIXTURE_OLD';new_string=(@(
                    'DB_PASSWORD=' + $fixtureSecrets.Database,
                    'EXTERNAL_API_KEY=' + $fixtureSecrets.Api,
                    'CLIENT_SECRET=' + $fixtureSecrets.Client,
                    'WEBHOOK_SECRET=' + $fixtureSecrets.Webhook
                ) -join "`n")}
            },
            [ordered]@{
                Name='MultiEdit config/production.yml';Tool='MultiEdit';Version='unknown';Qualification='failed'
                Input=[ordered]@{file_path=(Join-Path $defaultFixture.Workspace 'config\production.yml');edits=@([ordered]@{old_string='FIXTURE_OLD';new_string=('database: fixture`nobject_storage_key: ' + $fixtureSecrets.ObjectStorage)})}
            },
            [ordered]@{
                Name='NotebookEdit application-prod.yml';Tool='NotebookEdit';Version='unknown';Qualification='unavailable'
                Input=[ordered]@{notebook_path=(Join-Path $defaultFixture.Workspace 'application-prod.yml');new_source=('message_queue: ' + $fixtureSecrets.Queue + "`nsmtp: " + $fixtureSecrets.Smtp)}
            }
        )
        foreach ($fileCase in $productionFileCases) {
            $adapterInput = [ordered]@{
                tool_name = [string]$fileCase.Tool
                permission_mode = 'default'
                tool_input = $fileCase.Input
                cwd = $defaultFixture.Workspace
            } | ConvertTo-Json -Depth 12 -Compress
            $adapterResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $adapterInput -Environment @{
                DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace
                HARNESS_ENVIRONMENT='production'
                CODEX_VERSION=[string]$fileCase.Version
                HARNESS_HOST_QUALIFICATION=[string]$fileCase.Qualification
            }
            if ($adapterResult.ExitCode -eq 0 -and $adapterResult.StdOut.Trim() -ceq '{}' -and
                [string]::IsNullOrWhiteSpace($adapterResult.StdErr) -and -not (& $containsFixtureSecret $adapterResult)) {
                Add-Check "shared PreToolUse adapter allows version-neutral production config persistence through $($fileCase.Name) without disclosure"
            } else {
                Add-Failure "shared PreToolUse adapter rejected or disclosed content through $($fileCase.Name)"
            }
        }

        $ordinaryPatchInput = [ordered]@{
            tool_name = 'apply_patch'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = (@(
                '*** Begin Patch',
                '*** Add File: config/production.yml',
                '+database:',
                ('+  password: ' + $fixtureSecrets.Database),
                '+external:',
                ('+  api_key: ' + $fixtureSecrets.Api),
                '+note: DROP TRUNCATE DELETE FROM authorization credential token',
                '*** End Patch'
            ) -join "`n") }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $ordinaryPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $ordinaryPatchInput -Environment @{
            DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace
            HARNESS_ENVIRONMENT='production'
            CODEX_VERSION='unknown'
            HARNESS_HOST_QUALIFICATION='failed'
        }
        if ($ordinaryPatchResult.ExitCode -eq 0 -and $ordinaryPatchResult.StdOut.Trim() -ceq '{}' -and
            [string]::IsNullOrWhiteSpace($ordinaryPatchResult.StdErr) -and -not (& $containsFixtureSecret $ordinaryPatchResult)) {
            Add-Check 'shared PreToolUse adapter allows direct production-config apply_patch without classifying file content as command text'
        } else {
            Add-Failure 'shared PreToolUse adapter rejected or disclosed an ordinary direct production-config apply_patch'
        }

        $environmentIdentifier = 'fixture-' + 'environment-marker'
        $grammarAllowPatches = [ordered]@{
            StartedLeadingSpaceAdd = (@('*** Begin Patch',' *** Add File: notes-space.txt','+ok','*** End Patch') -join "`n")
            StartedLeadingTabAdd = (@('*** Begin Patch',("`t" + '*** Add File: notes-tab.txt'),'+ok','*** End Patch') -join "`n")
            AddThenLeadingSpaceAdd = (@('*** Begin Patch','*** Add File: notes-one.txt','+one',' *** Add File: notes-two.txt','+two','*** End Patch') -join "`n")
            DeleteThenLeadingSpaceAdd = (@('*** Begin Patch','*** Delete File: notes-old.txt',' *** Add File: notes-new.txt','+new','*** End Patch') -join "`n")
            EnvironmentId = (@('*** Begin Patch',('*** Environment ID: ' + $environmentIdentifier),'*** Add File: config/production.yml','+key: fixture','*** End Patch') -join "`n")
            EndOfFileLf = (@('*** Begin Patch','*** Update File: config/production.yml','@@','-old','+new','*** End of File','*** End Patch') -join "`n")
            EndOfFileCrlf = (@('*** Begin Patch','*** Update File: config/production.yml','@@','-old','+new','*** End of File','*** End Patch') -join "`r`n")
            MoveEndOfFile = (@('*** Begin Patch','*** Update File: notes-old.txt','*** Move to: notes-new.txt','@@','-old','+new','*** End of File','*** End Patch') -join "`n")
            UpdateContextMarker = (@('*** Begin Patch','*** Update File: notes.txt','@@','-old','+new',' *** Update File: auth/context-only.ps1','*** End Patch') -join "`n")
            TrailingHeaderWhitespace = (@('*** Begin Patch',('*** Add File: notes-trailing.txt' + " `t"),'+ok','*** End Patch') -join "`n")
        }
        foreach ($grammarAllowCase in $grammarAllowPatches.GetEnumerator()) {
            $grammarAllowInput = [ordered]@{
                tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command=[string]$grammarAllowCase.Value};cwd=$defaultFixture.Workspace
            } | ConvertTo-Json -Depth 10 -Compress
            $grammarAllowResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $grammarAllowInput -Environment @{
                DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace
                HARNESS_ENVIRONMENT='production'
                CODEX_VERSION='unknown'
                HARNESS_HOST_QUALIFICATION='failed'
            }
            $grammarOutput = [string]$grammarAllowResult.StdOut + [string]$grammarAllowResult.StdErr
            if ($grammarAllowResult.ExitCode -eq 0 -and $grammarAllowResult.StdOut.Trim() -ceq '{}' -and
                [string]::IsNullOrWhiteSpace($grammarAllowResult.StdErr) -and
                -not $grammarOutput.Contains($environmentIdentifier) -and -not (& $containsFixtureSecret $grammarAllowResult)) {
                Add-Check "shared PreToolUse adapter accepts official direct patch grammar without metadata authority: $($grammarAllowCase.Key)"
            } else {
                Add-Failure "shared PreToolUse adapter rejected or disclosed official direct patch grammar: $($grammarAllowCase.Key)"
            }
        }

        $consistentTarget = Join-Path $defaultFixture.Workspace '.env.production'
        $consistentCases = @(
            [ordered]@{Tool='Write';Input=[ordered]@{file_path=$consistentTarget;content=$fixtureSecrets.Database}},
            [ordered]@{Tool='Edit';Input=[ordered]@{file_path=$consistentTarget;old_string='FIXTURE_OLD';new_string=$fixtureSecrets.Database}},
            [ordered]@{Tool='MultiEdit';Input=[ordered]@{file_path=$consistentTarget;edits=@([ordered]@{old_string='FIXTURE_OLD';new_string=$fixtureSecrets.Database})}},
            [ordered]@{Tool='NotebookEdit';Input=[ordered]@{notebook_path=$consistentTarget;new_source=$fixtureSecrets.Database}},
            [ordered]@{Tool='apply_patch';Input=[ordered]@{command=("*** Begin Patch`n*** Add File: .env.production`n+DB_PASSWORD=" + $fixtureSecrets.Database + "`n*** End Patch")}}
        )
        $consistentResults = @(
            foreach ($consistentCase in $consistentCases) {
                $inputJson = [ordered]@{tool_name=$consistentCase.Tool;permission_mode='default';tool_input=$consistentCase.Input;cwd=$defaultFixture.Workspace} | ConvertTo-Json -Depth 10 -Compress
                Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $inputJson -Environment @{DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace;HARNESS_ENVIRONMENT='production'}
            }
        )
        if (@($consistentResults | Where-Object { $_.ExitCode -ne 0 -or $_.StdOut.Trim() -cne '{}' -or -not [string]::IsNullOrWhiteSpace($_.StdErr) -or (& $containsFixtureSecret $_) }).Count -eq 0) {
            Add-Check 'Write, Edit, MultiEdit, NotebookEdit, and direct apply_patch receive the same ordinary target policy result'
        } else {
            Add-Failure 'ordinary file tools did not receive a consistent target-only policy result'
        }

        $protectedPatchCommands = [ordered]@{
            Add = "*** Begin Patch`n*** Add File: auth/new.ps1`n+new`n*** End Patch"
            Update = "*** Begin Patch`n*** Update File: permissions/update.ps1`n@@`n-old`n+new`n*** End Patch"
            Delete = "*** Begin Patch`n*** Delete File: rbac/delete.ps1`n*** End Patch"
            Move = "*** Begin Patch`n*** Update File: notes.txt`n*** Move to: auth/moved.txt`n@@`n-old`n+new`n*** End Patch"
            MultiFile = "*** Begin Patch`n*** Add File: notes.txt`n+ok`n*** Add File: auth/mixed.ps1`n+protected`n*** End Patch"
            LeadingSpaceAdd = "*** Begin Patch`n *** Add File: auth/space.ps1`n+protected`n*** End Patch"
            LeadingTabAdd = "*** Begin Patch`n`t*** Add File: auth/tab.ps1`n+protected`n*** End Patch"
            LeadingSpaceUpdate = "*** Begin Patch`n *** Update File: permissions/space.ps1`n@@`n-old`n+new`n*** End Patch"
            LeadingSpaceDelete = "*** Begin Patch`n *** Delete File: rbac/space.ps1`n*** End Patch"
            WhitespaceMultiFile = "*** Begin Patch`n*** Add File: notes.txt`n+ok`n *** Add File: auth/whitespace-mixed.ps1`n+protected`n*** End Patch"
            EnvironmentProtected = ("*** Begin Patch`n*** Environment ID: " + $environmentIdentifier + "`n*** Add File: auth/environment.ps1`n+protected`n*** End Patch")
        }
        foreach ($protectedPatchCase in $protectedPatchCommands.GetEnumerator()) {
            $protectedPatchInput = [ordered]@{
                tool_name = 'apply_patch'
                permission_mode = $(if ($protectedPatchCase.Key -ceq 'MultiFile') { 'bypassPermissions' } else { 'default' })
                tool_input = [ordered]@{ command = [string]$protectedPatchCase.Value }
                cwd = $defaultFixture.Workspace
            } | ConvertTo-Json -Depth 10 -Compress
            $protectedPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $protectedPatchInput -Environment @{DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace}
            $protectedPatchOutput = [string]$protectedPatchResult.StdOut + [string]$protectedPatchResult.StdErr
            if ($protectedPatchResult.ExitCode -eq 2 -and $protectedPatchResult.StdErr -match 'protected write requires TaskId and ExpectedVersion' -and
                -not $protectedPatchOutput.Contains($environmentIdentifier)) {
                Add-Check "shared PreToolUse adapter extracts and preserves protected direct apply_patch targets: $($protectedPatchCase.Key)"
            } else {
                Add-Failure "shared PreToolUse adapter did not protect direct apply_patch targets: $($protectedPatchCase.Key)"
            }
        }
        $protectedPatchInput = [ordered]@{
            tool_name = 'apply_patch'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = [string]$protectedPatchCommands.Update }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $ordinaryBashInput = [ordered]@{
            tool_name = 'Bash'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = 'git status --short' }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $installedHooksDocument = Get-Content -LiteralPath $foreignHooksPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
        $installedHookCommands = @(
            foreach ($section in @($installedHooksDocument.hooks.PreToolUse)) {
                foreach ($hook in @($section.hooks)) {
                    if ([string]$hook.command -like '*codex-pretooluse-launcher.ps1*') { [string]$hook.command }
                }
            }
        )
        if ($installedHookCommands.Count -eq 1) {
            Add-Check 'core install keeps the Harness command distinct from a same-shape third-party hook'
        } else {
            Add-Failure 'core install did not produce exactly one identifiable Harness command'
        }
        $installedHookCommand = if ($installedHookCommands.Count -eq 1) { [string]$installedHookCommands[0] } else { '' }
        $fakePwsh = Join-Path $defaultFixture.Workspace 'pwsh.cmd'
        $fakePwshSentinel = Join-Path $defaultFixture.Workspace 'fake-pwsh-ran.txt'
        [System.IO.File]::WriteAllText($fakePwsh,"@echo off`r`necho hijacked>`"$fakePwshSentinel`"`r`nexit /b 0`r`n",[System.Text.UTF8Encoding]::new($false))
        foreach ($runner in @('cmd','pwsh','powershell')) {
            $runnerDeny = Invoke-CodexHookCommandWithInput -Runner $runner -Command $installedHookCommand -InputText $protectedPatchInput -WorkingDirectory $defaultFixture.Workspace
            if (Test-CodexDenyOutput -Result $runnerDeny -ReasonPattern 'denied or failed closed') {
                Add-Check "installed Codex Hook command fixture emits official deny JSON through the $runner parser"
            } else {
                Add-Failure "installed Codex Hook command fixture did not emit deny JSON through the ${runner} parser: exit=$($runnerDeny.ExitCode) stdout=$($runnerDeny.StdOut) stderr=$($runnerDeny.StdErr)"
            }
            $runnerAllow = Invoke-CodexHookCommandWithInput -Runner $runner -Command $installedHookCommand -InputText $ordinaryBashInput -WorkingDirectory $defaultFixture.Workspace
            if ($runnerAllow.ExitCode -eq 0 -and $runnerAllow.StdOut.Trim() -ceq '{}' -and [string]::IsNullOrWhiteSpace($runnerAllow.StdErr)) {
                Add-Check "installed Codex Hook command fixture emits the allow sentinel through the $runner parser"
            } else {
                Add-Failure "installed Codex Hook command fixture did not emit the allow sentinel through the $runner parser"
            }
            $runnerMutationAllow = Invoke-CodexHookCommandWithInput -Runner $runner -Command $installedHookCommand -InputText $ordinaryPatchInput -WorkingDirectory $defaultFixture.Workspace
            if ($runnerMutationAllow.ExitCode -eq 0 -and $runnerMutationAllow.StdOut.Trim() -ceq '{}' -and [string]::IsNullOrWhiteSpace($runnerMutationAllow.StdErr) -and -not (& $containsFixtureSecret $runnerMutationAllow)) {
                Add-Check "installed Codex Hook command fixture allows a relative direct apply_patch through the $runner parser without disclosure"
            } else {
                Add-Failure "installed Codex Hook command fixture rejected or disclosed a relative direct apply_patch through the $runner parser"
            }
        }
        $legacyCodePage = $null
        foreach ($candidateCodePage in @(936,437,1252)) {
            $codePageProbe = Invoke-CodexHookCommandWithInput `
                -Runner cmd `
                -Command 'chcp' `
                -InputText '' `
                -WorkingDirectory $defaultFixture.Workspace `
                -CodePage $candidateCodePage
            if ($codePageProbe.ExitCode -eq 0 -and $codePageProbe.StdOut -match "(?m)\b$candidateCodePage\b") {
                $legacyCodePage = $candidateCodePage
                break
            }
        }
        if ($null -eq $legacyCodePage) {
            Add-Failure 'installed Codex Hook command fixture could not activate code page 936, 437, or 1252'
        } else {
            $unicodeProtectedPatchInput = [ordered]@{
                tool_name = 'apply_patch'
                permission_mode = 'default'
                tool_input = [ordered]@{ command = "*** Begin Patch`n*** Update File: auth/授权.ps1`n@@`n-old`n+新值`n*** End Patch" }
                cwd = $defaultFixture.Workspace
            } | ConvertTo-Json -Depth 10 -Compress
            $legacyCodePageDeny = Invoke-CodexHookCommandWithInput `
                -Runner cmd `
                -Command $installedHookCommand `
                -InputText $unicodeProtectedPatchInput `
                -WorkingDirectory $defaultFixture.Workspace `
                -CodePage $legacyCodePage
            if ($unicodeProtectedPatchInput.Contains('auth/授权.ps1') -and
                (Test-CodexDenyOutput -Result $legacyCodePageDeny -ReasonPattern 'denied or failed closed')) {
                Add-Check "installed Codex Hook exact command fails closed for a raw UTF-8 Unicode protected path under code page $legacyCodePage"
            } else {
                Add-Failure "installed Codex Hook exact command did not fail closed for raw UTF-8 under code page ${legacyCodePage}: exit=$($legacyCodePageDeny.ExitCode) stdout=$($legacyCodePageDeny.StdOut) stderr=$($legacyCodePageDeny.StdErr)"
            }

            $unicodeOrdinaryBashInput = [ordered]@{
                tool_name = 'Bash'
                permission_mode = 'default'
                tool_input = [ordered]@{ command = "Write-Output '说明：正常'" }
                cwd = $defaultFixture.Workspace
            } | ConvertTo-Json -Depth 10 -Compress
            $legacyCodePageAllow = Invoke-CodexHookCommandWithInput `
                -Runner cmd `
                -Command $installedHookCommand `
                -InputText $unicodeOrdinaryBashInput `
                -WorkingDirectory $defaultFixture.Workspace `
                -CodePage $legacyCodePage
            if ($unicodeOrdinaryBashInput.Contains('说明') -and
                $legacyCodePageAllow.ExitCode -eq 0 -and
                $legacyCodePageAllow.StdOut.Trim() -ceq '{}' -and
                [string]::IsNullOrWhiteSpace($legacyCodePageAllow.StdErr)) {
                Add-Check "installed Codex Hook exact command allows raw UTF-8 Unicode JSON under code page $legacyCodePage"
            } else {
                Add-Failure "installed Codex Hook exact command did not allow raw UTF-8 under code page ${legacyCodePage}: exit=$($legacyCodePageAllow.ExitCode) stdout=$($legacyCodePageAllow.StdOut) stderr=$($legacyCodePageAllow.StdErr)"
            }
        }
        if (-not (Test-Path -LiteralPath $fakePwshSentinel)) {
            Add-Check 'installed Codex Hook command fixture uses pinned absolute PowerShell executables instead of a workspace pwsh shim'
        } else {
            Add-Failure 'Codex Hook executed a workspace pwsh shim'
        }
        $shellPatchCommand = @(
            "applypatch <<'PATCH'"
            '*** Begin Patch'
            '*** Add File: docs/example-shell.sql'
            '+DELETE FROM customer;'
            '*** End Patch'
            'PATCH'
        ) -join "`n"
        $shellPatchInput = [ordered]@{
            tool_name = 'Bash'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = $shellPatchCommand;workdir='auth' }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $shellPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $shellPatchInput -Environment @{ HARNESS_ENVIRONMENT='production' }
        if ($shellPatchResult.ExitCode -eq 2 -and $shellPatchResult.StdErr -match 'effective tool workdir or environment identity') {
            Add-Check 'shared PreToolUse adapter fails closed for shell-form applypatch with an unbound tool workdir'
        } else {
            Add-Failure "shared PreToolUse adapter accepted shell-form applypatch without a bound tool workdir: $($shellPatchResult.StdErr)"
        }
        $protectedShellPatchCommand = @(
            "cd src && apply_patch <<'PATCH'"
            '*** Begin Patch'
            '*** Update File: auth/authorize.ps1'
            '@@'
            '-old'
            '+new'
            '*** End Patch'
            'PATCH'
        ) -join "`n"
        $protectedShellPatchInput = [ordered]@{
            tool_name = 'Bash'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = $protectedShellPatchCommand }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $protectedShellPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $protectedShellPatchInput
        if ($protectedShellPatchResult.ExitCode -eq 2 -and $protectedShellPatchResult.StdErr -match 'effective tool workdir or environment identity') {
            Add-Check 'shared PreToolUse adapter fails closed for shell-form apply_patch even with command-local cd'
        } else {
            Add-Failure "shared PreToolUse adapter did not deny a protected Codex shell-form apply_patch path: $($protectedShellPatchResult.StdErr)"
        }
        $unsupportedShellPatchInput = [ordered]@{
            tool_name = 'Bash'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = "echo before && $protectedShellPatchCommand" }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $unsupportedShellPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $unsupportedShellPatchInput
        if ($unsupportedShellPatchResult.ExitCode -eq 2 -and $unsupportedShellPatchResult.StdErr -match 'effective tool workdir or environment identity') {
            Add-Check 'shared PreToolUse adapter fails closed for composed shell apply_patch invocation'
        } else {
            Add-Failure 'shared PreToolUse adapter accepted a non-canonical shell apply_patch composition'
        }
        $wrappedShellPatchCommands = [ordered]@{
            command_wrapper = "command apply_patch <<'PATCH'`n*** Begin Patch`n*** Add File: notes.txt`n+ok`n*** End Patch`nPATCH"
            env_path_wrapper = "env X=1 ./apply_patch <<'PATCH'`n*** Begin Patch`n*** Add File: notes.txt`n+ok`n*** End Patch`nPATCH"
            quoted_command = "'apply_patch' <<'PATCH'`n*** Begin Patch`n*** Add File: notes.txt`n+ok`n*** End Patch`nPATCH"
            redirected_input = 'apply_patch < patch.txt'
            piped_input = 'type patch.txt | /usr/bin/applypatch'
        }
        foreach ($wrappedCase in $wrappedShellPatchCommands.GetEnumerator()) {
            $wrappedInput = [ordered]@{
                tool_name = 'Bash'
                permission_mode = 'default'
                tool_input = [ordered]@{ command = [string]$wrappedCase.Value }
                cwd = $defaultFixture.Workspace
            } | ConvertTo-Json -Depth 10 -Compress
            $wrappedResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $wrappedInput
            if ($wrappedResult.ExitCode -eq 2 -and $wrappedResult.StdErr -match 'effective tool workdir or environment identity') {
                Add-Check "shared PreToolUse adapter fails closed for wrapped shell apply_patch: $($wrappedCase.Key)"
            } else {
                Add-Failure "shared PreToolUse adapter accepted wrapped shell apply_patch: $($wrappedCase.Key)"
            }
        }
        $applyPatchMentionInput = [ordered]@{
            tool_name = 'Bash'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = 'rg -n ''apply[_]patch'' README.md' }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $applyPatchMentionResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $applyPatchMentionInput
        if ($applyPatchMentionResult.ExitCode -eq 0 -and $applyPatchMentionResult.StdOut.Trim() -ceq '{}') {
            Add-Check 'shared PreToolUse adapter allows an ordinary Bash command without a literal apply_patch token'
        } else {
            Add-Failure 'shared PreToolUse adapter rejected an ordinary Bash command without a literal apply_patch token'
        }
        $planPatchInput = [ordered]@{
            tool_name = 'apply_patch'
            tool_input = [ordered]@{ command = "*** Begin Patch`n*** Add File: plan-denied.txt`n+no`n*** End Patch" }
            cwd = $defaultFixture.Workspace
            permission_mode = 'plan'
        } | ConvertTo-Json -Depth 10 -Compress
        $planPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $planPatchInput
        if ($planPatchResult.ExitCode -eq 2 -and $planPatchResult.StdErr -match 'unsupported permission_mode: plan') {
            Add-Check 'shared PreToolUse adapter rejects the non-existent Codex plan permission mode instead of inventing a host guarantee'
        } else {
            Add-Failure 'shared PreToolUse adapter accepted a permission mode outside the pinned Codex hook contract'
        }
        foreach ($productionCommand in @('DROP DATABASE fixture_database','TRUNCATE TABLE fixture_table','DELETE FROM fixture_table')) {
            $productionBashInput = [ordered]@{
                tool_name = 'Bash'
                permission_mode = 'bypassPermissions'
                tool_input = [ordered]@{ command = $productionCommand }
                cwd = $defaultFixture.Workspace
            } | ConvertTo-Json -Depth 10 -Compress
            $productionBashResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $productionBashInput -Environment @{HARNESS_ENVIRONMENT='production';DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace}
            if ($productionBashResult.ExitCode -eq 2 -and $productionBashResult.StdErr -match 'protected write requires TaskId and ExpectedVersion') {
                Add-Check "shared PreToolUse adapter forwards and protects production Bash command: $($productionCommand.Split(' ')[0])"
            } else {
                Add-Failure "shared PreToolUse adapter allowed protected production Bash command: $($productionCommand.Split(' ')[0])"
            }
        }
        $longBashInput = [ordered]@{
            tool_name = 'Bash'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = ('Write-Output ' + ('x' * 40000)) }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $longBashResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $longBashInput
        if ($longBashResult.ExitCode -eq 0 -and $longBashResult.StdOut.Trim() -ceq '{}') {
            Add-Check 'shared PreToolUse adapter carries long Bash input to core through stdin instead of the Windows command line'
        } else {
            Add-Failure "shared PreToolUse adapter rejected long Bash input before core evaluation: $($longBashResult.StdErr)"
        }
        $productionSqlPatchInput = [ordered]@{
            tool_name = 'apply_patch'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = "*** Begin Patch`n*** Add File: docs/example.sql`n+DELETE FROM customer;`n*** End Patch" }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $productionSqlPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $productionSqlPatchInput -Environment @{HARNESS_ENVIRONMENT='production';DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace}
        if ($productionSqlPatchResult.ExitCode -eq 0 -and $productionSqlPatchResult.StdOut.Trim() -ceq '{}' -and [string]::IsNullOrWhiteSpace($productionSqlPatchResult.StdErr)) {
            Add-Check 'shared PreToolUse adapter does not classify direct patch file content as an executed production command'
        } else {
            Add-Failure 'shared PreToolUse adapter classified direct patch file content as an executed production command'
        }
        $invalidPatchCases = [ordered]@{
            missing_begin = "*** Add File: a.txt`n+x`n*** End Patch"
            missing_end = "*** Begin Patch`n*** Add File: a.txt`n+x"
            duplicate_begin = "*** Begin Patch`n*** Begin Patch`n*** Add File: a.txt`n+x`n*** End Patch"
            nested_begin = "*** Begin Patch`n*** Add File: a.txt`n*** Begin Patch`n+x`n*** End Patch"
            early_end = "*** Begin Patch`n*** End Patch`n*** Add File: a.txt`n+x`n*** End Patch"
            duplicate_end = "*** Begin Patch`n*** Add File: a.txt`n+x`n*** End Patch`n*** End Patch"
            repeated_final_newline = "*** Begin Patch`n*** Add File: a.txt`n+x`n*** End Patch`n`n"
            empty_patch = "*** Begin Patch`n*** End Patch"
            no_file_operation = "*** Begin Patch`n+body only`n*** End Patch"
            unknown_directive = "*** Begin Patch`n*** Unsupported: a.txt`n*** Add File: a.txt`n+x`n*** End Patch"
            duplicate_environment_id = "*** Begin Patch`n*** Environment ID: first`n*** Environment ID: second`n*** Add File: a.txt`n+x`n*** End Patch"
            empty_environment_id = "*** Begin Patch`n*** Environment ID:   `n*** Add File: a.txt`n+x`n*** End Patch"
            late_environment_id = "*** Begin Patch`n*** Add File: a.txt`n+x`n*** Environment ID: late`n*** End Patch"
            environment_id_in_update = "*** Begin Patch`n*** Update File: a.txt`n@@`n-old`n+new`n*** Environment ID: late`n*** End Patch"
            environment_id_as_update_context = "*** Begin Patch`n*** Update File: a.txt`n@@`n-old`n+new`n *** Environment ID: late`n*** End Patch"
            end_of_file_in_add = "*** Begin Patch`n*** Add File: a.txt`n+x`n*** End of File`n*** End Patch"
            end_of_file_in_delete = "*** Begin Patch`n*** Delete File: a.txt`n*** End of File`n*** End Patch"
            end_of_file_before_change = "*** Begin Patch`n*** Update File: a.txt`n@@`n*** End of File`n*** End Patch"
            duplicate_end_of_file = "*** Begin Patch`n*** Update File: a.txt`n@@`n-old`n+new`n*** End of File`n*** End of File`n*** End Patch"
            content_after_end_of_file = "*** Begin Patch`n*** Update File: a.txt`n@@`n-old`n+new`n*** End of File`n+late`n*** End Patch"
            orphan_move = "*** Begin Patch`n*** Move to: b.txt`n*** End Patch"
            duplicate_move = "*** Begin Patch`n*** Update File: a.txt`n*** Move to: b.txt`n*** Move to: c.txt`n@@`n-x`n+y`n*** End Patch"
            move_after_change = "*** Begin Patch`n*** Update File: a.txt`n@@`n-x`n+y`n*** Move to: b.txt`n*** End Patch"
            move_after_add = "*** Begin Patch`n*** Add File: a.txt`n*** Move to: b.txt`n+x`n*** End Patch"
            move_after_delete = "*** Begin Patch`n*** Delete File: a.txt`n*** Move to: b.txt`n*** End Patch"
            empty_path = "*** Begin Patch`n*** Add File: `n+x`n*** End Patch"
            leading_path_whitespace = "*** Begin Patch`n*** Add File:  a.txt`n+x`n*** End Patch"
            nul_path = "*** Begin Patch`n*** Add File: a$([char]0)b.txt`n+x`n*** End Patch"
            bare_cr_path = "*** Begin Patch`n*** Add File: a`rb.txt`n+x`n*** End Patch"
            windows_absolute = "*** Begin Patch`n*** Add File: C:\outside.txt`n+x`n*** End Patch"
            unix_absolute = "*** Begin Patch`n*** Add File: /outside.txt`n+x`n*** End Patch"
            unc_path = "*** Begin Patch`n*** Add File: \\server\share\outside.txt`n+x`n*** End Patch"
            drive_relative = "*** Begin Patch`n*** Add File: C:outside.txt`n+x`n*** End Patch"
            alternate_data_stream = "*** Begin Patch`n*** Add File: a.txt:stream`n+x`n*** End Patch"
            dot_segment = "*** Begin Patch`n*** Add File: config/./a.txt`n+x`n*** End Patch"
            dotdot_segment = "*** Begin Patch`n*** Add File: config/../a.txt`n+x`n*** End Patch"
            escaping_move = "*** Begin Patch`n*** Update File: a.txt`n*** Move to: ../outside.txt`n@@`n-x`n+y`n*** End Patch"
        }
        foreach ($invalidPatchCase in $invalidPatchCases.GetEnumerator()) {
            $invalidPatchInput = [ordered]@{
                tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command=[string]$invalidPatchCase.Value};cwd=$defaultFixture.Workspace
            } | ConvertTo-Json -Depth 10 -Compress
            $invalidPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $invalidPatchInput -Environment @{DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace}
            if ($invalidPatchResult.ExitCode -eq 2 -and $invalidPatchResult.StdErr -match '^direct apply_patch input') {
                Add-Check "shared PreToolUse adapter fails closed for malformed direct apply_patch: $($invalidPatchCase.Key)"
            } else {
                Add-Failure "shared PreToolUse adapter accepted malformed direct apply_patch: $($invalidPatchCase.Key)"
            }
        }

        $adapterTokens = $null
        $adapterErrors = $null
        $adapterAst = [System.Management.Automation.Language.Parser]::ParseFile($installedPreToolHook,[ref]$adapterTokens,[ref]$adapterErrors)
        $adapterFunctions = @($adapterAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
        $pathValidatorAst = @($adapterFunctions | Where-Object Name -CEQ 'Assert-ApplyPatchRelativePath')[0]
        $patchParserAst = @($adapterFunctions | Where-Object Name -CEQ 'Get-ApplyPatchChangedPaths')[0]
        if (@($adapterErrors).Count -eq 0 -and $null -ne $pathValidatorAst -and $null -ne $patchParserAst) {
            $pathValidatorBody = $pathValidatorAst.Body.GetScriptBlock()
            function Assert-ApplyPatchRelativePath { param([string]$Path) & $pathValidatorBody -Path $Path }
            $patchParserBody = $patchParserAst.Body.GetScriptBlock()
            foreach ($controlPath in @("a$([char]0)b.txt","a`rb.txt","a`nb.txt")) {
                try {
                    & $pathValidatorBody -Path $controlPath
                    Add-Failure 'direct apply_patch path validator accepted a NUL, CR, or LF control character'
                } catch {
                    Add-Check 'direct apply_patch path validator rejects a NUL, CR, or LF control character'
                }
            }
            $deduplicatedPaths = @(& $patchParserBody -PatchText "*** Begin Patch`n*** Add File: Config/File.txt`n+x`n*** Update File: config\file.txt`n@@`n-x`n+y`n*** End Patch")
            $movePaths = @(& $patchParserBody -PatchText "*** Begin Patch`r`n*** Update File: old.txt`r`n*** Move to: new.txt`r`n@@`r`n-old`r`n+new`r`n*** End Patch`r`n")
            $startedWhitespacePaths = @(& $patchParserBody -PatchText "*** Begin Patch`n *** Add File: notes-space.txt`n+one`n*** End Patch")
            $addWhitespacePaths = @(& $patchParserBody -PatchText "*** Begin Patch`n*** Add File: notes-one.txt`n+one`n`t*** Update File: notes-two.txt`n@@`n-old`n+new`n*** End Patch")
            $deleteWhitespacePaths = @(& $patchParserBody -PatchText "*** Begin Patch`n*** Delete File: notes-old.txt`n *** Add File: notes-new.txt`n+new`n*** End Patch")
            $environmentPaths = @(& $patchParserBody -PatchText ("*** Begin Patch`n*** Environment ID: " + $environmentIdentifier + "`n*** Add File: config/production.yml`n+x`n*** End Patch"))
            $moveEndOfFilePaths = @(& $patchParserBody -PatchText "*** Begin Patch`n*** Update File: notes-old.txt`n*** Move to: notes-new.txt`n@@`n-old`n+new`n*** End of File`n*** End Patch")
            $updateContextPaths = @(& $patchParserBody -PatchText "*** Begin Patch`n*** Update File: notes.txt`n@@`n-old`n+new`n *** Update File: auth/context-only.ps1`n*** End Patch")
            if ($deduplicatedPaths.Count -eq 1 -and $movePaths.Count -eq 2 -and
                $startedWhitespacePaths.Count -eq 1 -and $startedWhitespacePaths[0] -ceq 'notes-space.txt' -and
                $addWhitespacePaths.Count -eq 2 -and $addWhitespacePaths[1] -ceq 'notes-two.txt' -and
                $deleteWhitespacePaths.Count -eq 2 -and $deleteWhitespacePaths[1] -ceq 'notes-new.txt' -and
                $environmentPaths.Count -eq 1 -and $environmentPaths[0] -ceq 'config/production.yml' -and
                @($environmentPaths | Where-Object { [string]$_ -ceq $environmentIdentifier }).Count -eq 0 -and
                $moveEndOfFilePaths.Count -eq 2 -and $moveEndOfFilePaths[0] -ceq 'notes-old.txt' -and $moveEndOfFilePaths[1] -ceq 'notes-new.txt' -and
                $updateContextPaths.Count -eq 1 -and $updateContextPaths[0] -ceq 'notes.txt') {
                Add-Check 'direct apply_patch parser aligns whitespace, Environment ID, Move, End of File, LF/CRLF, and Update context target extraction'
            } else {
                Add-Failure 'direct apply_patch parser grammar-aware target extraction is invalid'
            }
        } else {
            Add-Failure 'installed direct apply_patch parser functions are unavailable or do not parse'
        }

        $rootCases = @(
            [ordered]@{Name='environment-only root';Payload=[ordered]@{tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command="*** Begin Patch`n*** Add File: env-root.txt`n+x`n*** End Patch"}};Environment=@{DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace};Allowed=$true},
            [ordered]@{Name='same normalized roots';Payload=[ordered]@{tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command="*** Begin Patch`n*** Add File: same-root.txt`n+x`n*** End Patch"};cwd=$defaultFixture.Workspace};Environment=@{DEV_HARNESS_WORKSPACE_ROOT=($defaultFixture.Workspace + '\')};Allowed=$true},
            [ordered]@{Name='missing roots';Payload=[ordered]@{tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command="*** Begin Patch`n*** Add File: missing-root.txt`n+x`n*** End Patch"}};Environment=@{};Allowed=$false},
            [ordered]@{Name='conflicting roots';Payload=[ordered]@{tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command="*** Begin Patch`n*** Add File: conflict-root.txt`n+x`n*** End Patch"};cwd=$defaultFixture.Workspace};Environment=@{DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.User};Allowed=$false},
            [ordered]@{Name='non-string cwd';Payload=[ordered]@{tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command="*** Begin Patch`n*** Add File: bad-cwd.txt`n+x`n*** End Patch"};cwd=@($defaultFixture.Workspace)};Environment=@{};Allowed=$false}
        )
        foreach ($rootCase in $rootCases) {
            $rootResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText ($rootCase.Payload | ConvertTo-Json -Depth 10 -Compress) -Environment $rootCase.Environment
            $actualAllowed = $rootResult.ExitCode -eq 0 -and $rootResult.StdOut.Trim() -ceq '{}' -and [string]::IsNullOrWhiteSpace($rootResult.StdErr)
            if ($actualAllowed -eq [bool]$rootCase.Allowed) {
                Add-Check "shared PreToolUse adapter enforces Workspace root binding: $($rootCase.Name)"
            } else {
                Add-Failure "shared PreToolUse adapter Workspace root binding is invalid: $($rootCase.Name)"
            }
        }

        $directoryPatchInput = [ordered]@{tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command="*** Begin Patch`n*** Add File: .assistant`n+x`n*** End Patch"};cwd=$defaultFixture.Workspace} | ConvertTo-Json -Depth 10 -Compress
        $directoryPatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $directoryPatchInput -Environment @{DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace}
        if ($directoryPatchResult.ExitCode -eq 2 -and $directoryPatchResult.StdErr -match 'must not be a directory') {
            Add-Check 'shared PreToolUse adapter rejects a direct apply_patch directory target'
        } else {
            Add-Failure 'shared PreToolUse adapter accepted a direct apply_patch directory target'
        }

        $outsideWriteInput = [ordered]@{tool_name='Write';permission_mode='default';tool_input=[ordered]@{file_path=(Join-Path $defaultFixture.Workspace '..\outside.txt');content='fixture'};cwd=$defaultFixture.Workspace} | ConvertTo-Json -Depth 10 -Compress
        $outsideWriteResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $outsideWriteInput -Environment @{DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace}
        if ($outsideWriteResult.ExitCode -eq 2 -and $outsideWriteResult.StdErr -match 'escapes WorkspaceRoot') {
            Add-Check 'shared PreToolUse adapter preserves Workspace containment for ordinary file tools'
        } else {
            Add-Failure 'shared PreToolUse adapter allowed an ordinary file-tool target outside the Workspace'
        }

        $reparseTarget = Join-Path $defaultFixture.Root 'reparse-target'
        $reparseLink = Join-Path $defaultFixture.Workspace 'config-link'
        [System.IO.Directory]::CreateDirectory($reparseTarget) | Out-Null
        New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget | Out-Null
        $reparsePatchInput = [ordered]@{tool_name='apply_patch';permission_mode='default';tool_input=[ordered]@{command="*** Begin Patch`n*** Add File: config-link/production.yml`n+x`n*** End Patch"};cwd=$defaultFixture.Workspace} | ConvertTo-Json -Depth 10 -Compress
        $reparsePatchResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $reparsePatchInput -Environment @{DEV_HARNESS_WORKSPACE_ROOT=$defaultFixture.Workspace}
        if ($reparsePatchResult.ExitCode -eq 2 -and $reparsePatchResult.StdErr -match 'reparse point') {
            Add-Check 'shared PreToolUse adapter preserves reparse, junction, and symlink ancestor protection'
        } else {
            Add-Failure 'shared PreToolUse adapter allowed a target through a reparse ancestor'
        }

        $productionTargets = @(
            'appsettings.Production.json','.env.production','config\production.yml','application-prod.yml'
        ) | ForEach-Object { Join-Path $defaultFixture.Workspace $_ }
        $gitIgnorePreserved = if ($gitIgnoreExisted) {
            (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) -and (Get-TestFileSha256 -Path $gitIgnorePath) -ceq $gitIgnorePreimage
        } else {
            -not (Test-Path -LiteralPath $gitIgnorePath)
        }
        if ($gitIgnorePreserved -and
            @($productionTargets | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) {
            Add-Check 'PreToolUse policy evaluation neither changes .gitignore nor writes or reclassifies target files'
        } else {
            Add-Failure 'PreToolUse policy evaluation changed .gitignore or a target file'
        }
        [System.IO.Directory]::Delete($reparseLink)
        $missingPathInput = [ordered]@{
            tool_name = 'Write'
            permission_mode = 'default'
            tool_input = [ordered]@{ content = 'no target' }
            cwd = $defaultFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $missingPathResult = Invoke-ChildScriptWithInput -ScriptPath $installedPreToolHook -InputText $missingPathInput
        if ($missingPathResult.ExitCode -eq 2 -and $missingPathResult.StdErr -match 'missing target path') {
            Add-Check 'shared PreToolUse adapter fails closed when a file-write target is missing'
        } else {
            Add-Failure 'shared PreToolUse adapter allowed a file write without a target path'
        }
        $postInstallHooks = ConvertFrom-InstallJson -Json (Get-Content -LiteralPath $foreignHooksPath -Raw -Encoding utf8)
        $postInstallHooks.hooks['PreToolUse'] = @($postInstallHooks.hooks.PreToolUse | Where-Object {
            @($_.hooks | Where-Object { [string]$_.command -ceq 'third-party-shape-collision' }).Count -eq 0
        })
        $postInstallHooks.hooks['PostToolUse'] = @([ordered]@{
            matcher = '^ForeignPost$'
            hooks = @([ordered]@{ type='command';command='post-install-third-party';timeout=9 })
        })
        [System.IO.File]::WriteAllText($foreignHooksPath,(ConvertTo-InstallJson -Value $postInstallHooks -Depth 20),[System.Text.UTF8Encoding]::new($false))
        $coreUpdate = Invoke-Install -Fixture $defaultFixture
        Assert-InstallExit $coreUpdate 'core update'
        if ($coreUpdate.ExitCode -eq 0) {
            Assert-InstalledCodexHook -Fixture $defaultFixture -Label 'core update' -RequireForeign
            $updatedHooks = Get-Content -LiteralPath $foreignHooksPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
            $updatedPostInstallHooks = @(
                foreach ($section in @($updatedHooks.hooks.PostToolUse)) {
                    foreach ($hook in @($section.hooks)) {
                        if ([string]$section.matcher -ceq '^ForeignPost$' -and
                            [string]$hook.type -ceq 'command' -and
                            [string]$hook.command -ceq 'post-install-third-party' -and
                            [int]$hook.timeout -eq 9) { $hook }
                    }
                }
            )
            if ($updatedPostInstallHooks.Count -eq 1) {
                Add-Check 'core update preserves the full post-install third-party hook payload'
            } else {
                Add-Failure 'core update changed or removed the post-install third-party hook payload'
            }
            $updatedCommands = @(
                foreach ($event in $updatedHooks.hooks.Values) {
                    foreach ($section in @($event)) {
                        foreach ($hook in @($section.hooks)) { [string]$hook.command }
                    }
                }
            )
            if (@($updatedCommands | Where-Object { $_ -ceq 'third-party-shape-collision' }).Count -eq 0) {
                Add-Check 'core update does not resurrect a deleted same-shape third-party hook'
            } else {
                Add-Failure 'core update resurrected a deleted same-shape third-party hook'
            }
            if (([System.IO.File]::ReadAllBytes($foreignManagedConfig) -join ',') -ceq ($foreignManagedBytes -join ',')) {
                Add-Check 'core update preserves external Codex managed policy'
            } else {
                Add-Failure 'core update changed external Codex managed policy'
            }
            $coreUpdateManifest = Get-LatestManifest $defaultFixture
            Assert-InstalledTaskShim $defaultFixture $coreUpdateManifest 'core update'
            Assert-InstalledTaskProtocol $defaultFixture 'core update'
            if (([System.IO.File]::ReadAllBytes($coreRolloutSentinel) -join ',') -ceq ($coreRolloutBytes -join ',') -and (Test-ManifestExcludesPath $coreUpdateManifest $coreRolloutSentinel)) { Add-Check 'core update preserves and does not claim the canonical rollout report' } else { Add-Failure 'core update changed or claimed the canonical rollout report' }
        }
        Assert-UninstallExit (Invoke-Uninstall $defaultFixture) 'fresh default'
        Assert-TaskShimRemoved $defaultFixture 'core uninstall'
        $restoredHooks = Get-Content -LiteralPath $foreignHooksPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
        $restoredCommands = @(
            foreach ($event in $restoredHooks.hooks.Values) {
                foreach ($section in @($event)) {
                    foreach ($hook in @($section.hooks)) { [string]$hook.command }
                }
            }
        )
        $expectedHarnessPath = Join-Path $defaultFixture.User '.claude\hooks-memory\codex-pretooluse-launcher.ps1'
        $windowsPowerShell = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
        $expectedHarnessCommand = '{0} -NoLogo -NoProfile -NonInteractive -Command . ''{1}''' -f $windowsPowerShell,$expectedHarnessPath.Replace("'", "''")
        if ([string]$restoredHooks.description -ceq 'foreign hook sentinel' -and
            [string]$restoredHooks.foreign_metadata.owner -ceq 'fixture' -and
            [string]$restoredHooks.foreign_metadata.timestamp -ceq '2024-01-01T00:00:00+09:00' -and
            $restoredHooks.foreign_metadata.Contains('CaseKey') -and
            $restoredHooks.foreign_metadata.Contains('casekey') -and
            [string]$restoredHooks.foreign_metadata['CaseKey'] -ceq 'upper' -and
            [string]$restoredHooks.foreign_metadata['casekey'] -ceq 'lower' -and
            @($restoredCommands | Where-Object { $_ -ceq 'foreign-pretool' }).Count -eq 1 -and
            @($restoredCommands | Where-Object { $_ -ceq 'foreign-stop' }).Count -eq 1 -and
            @($restoredCommands | Where-Object { $_ -ceq 'post-install-third-party' }).Count -eq 1 -and
            @($restoredCommands | Where-Object { $_ -ceq 'third-party-shape-collision' }).Count -eq 0 -and
            @($restoredCommands | Where-Object { $_ -ceq $expectedHarnessCommand }).Count -eq 0 -and
            ([System.IO.File]::ReadAllBytes($foreignManagedConfig) -join ',') -ceq ($foreignManagedBytes -join ',')) {
            Add-Check 'core uninstall removes only Harness Codex hooks while preserving baseline and post-install third-party hooks'
        } else {
            Add-Failure 'core uninstall did not preserve foreign Codex configuration'
        }
        if ((Test-Path -LiteralPath $foreignSentinel -PathType Leaf) -and [System.IO.File]::ReadAllText($foreignSentinel) -ceq 'foreign-user-asset' -and
            (Test-Path -LiteralPath $coreRolloutSentinel -PathType Leaf) -and ([System.IO.File]::ReadAllBytes($coreRolloutSentinel) -join ',') -ceq ($coreRolloutBytes -join ',')) {
            Add-Check 'core install and uninstall preserve foreign skill assets and canonical rollout evidence'
        } else {
            Add-Failure 'core install or uninstall changed a foreign skill asset or canonical rollout evidence'
        }
    }

    $managedConfigRetirementFixture = New-PresetFixture -Name 'managed-config-retirement'
    $managedConfigBaselineInstall = Invoke-Install -Fixture $managedConfigRetirementFixture -ExtraArguments @('-Preset','core')
    Assert-InstallExit $managedConfigBaselineInstall 'managed config retirement baseline'
    if ($managedConfigBaselineInstall.ExitCode -eq 0) {
        $externalBaselineText = "# external administrator policy`r`n[features]`r`nhooks = false`r`n"
        $legacyManagedText = "# Managed by install.ps1`r`nallow_managed_hooks_only = true`r`n[features]`r`nhooks = true`r`n"
        $legacyState = Set-TestLegacyManagedConfigState `
            -Fixture $managedConfigRetirementFixture `
            -ExternalBaselineText $externalBaselineText `
            -LegacyManagedText $legacyManagedText
        $managedConfigPath = $legacyState.ManagedConfigPath
        $legacyRegistryForForgery = Get-Content -LiteralPath $legacyState.RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
        $legacyManifestForForgery = Get-Content -LiteralPath $legacyState.ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
        $legacyRegistryForForgery.released_target_history = @(
            [ordered]@{
                path = (Get-NormalizedPath -Path $managedConfigPath)
                manifest_paths = @($legacyState.ManifestPath)
                release_manifest_path = $legacyState.ManifestPath
                release_manifest_plan_digest = (Get-InstallManifestPlanDigest -Manifest $legacyManifestForForgery)
            }
        )
        try {
            [void](Get-InstallRegistryReleasedTargetHistoryMap `
                -Registry $legacyRegistryForForgery `
                -ExpectedUserProfile $managedConfigRetirementFixture.User)
            Add-Failure 'release history accepted a manifest without a committed release marker'
        } catch {
            Add-Check 'release history rejects a manifest without a committed release marker'
        }
        $missingReleaseManifestPath = Join-Path $managedConfigRetirementFixture.User '.dev-harness\backups\missing\install-manifest.json'
        $legacyRegistryForForgery.released_target_history = @(
            [ordered]@{
                path = (Get-NormalizedPath -Path $managedConfigPath)
                manifest_paths = @($missingReleaseManifestPath)
                release_manifest_path = $missingReleaseManifestPath
                release_manifest_plan_digest = ('0' * 64)
            }
        )
        try {
            [void](Get-InstallRegistryReleasedTargetHistoryMap `
                -Registry $legacyRegistryForForgery `
                -ExpectedUserProfile $managedConfigRetirementFixture.User)
            Add-Failure 'release history accepted a nonexistent release manifest'
        } catch {
            Add-Check 'release history rejects a nonexistent release manifest'
        }

        $managedConfigUpgrade = Invoke-Install -Fixture $managedConfigRetirementFixture -ExtraArguments @('-Preset','core')
        Assert-InstallExit $managedConfigUpgrade 'legacy managed config retirement'
        if ($managedConfigUpgrade.ExitCode -eq 0) {
            $retirementManifest = Get-LatestManifest $managedConfigRetirementFixture
            $retirementRecords = @($retirementManifest.backups | Where-Object {
                (Get-NormalizedPath -Path $_.path) -eq (Get-NormalizedPath -Path $managedConfigPath)
            })
            $releasedTargets = @($retirementManifest.released_backup_targets | ForEach-Object { Get-NormalizedPath -Path $_ })
            if ([System.IO.File]::ReadAllText($managedConfigPath) -ceq $externalBaselineText -and
                $retirementRecords.Count -eq 1 -and
                [string]$retirementRecords[0].expected_postimage.item_type -ceq 'file' -and
                [string]$retirementRecords[0].expected_postimage.sha256 -ceq (Get-TestFileSha256 -Path $managedConfigPath) -and
                @($releasedTargets | Where-Object { $_ -eq (Get-NormalizedPath -Path $managedConfigPath) }).Count -eq 1) {
                Add-Check 'legacy Harness managed_config retires transactionally to the exact external baseline and records release ownership'
            } else {
                Add-Failure 'legacy Harness managed_config retirement did not restore and release the external baseline'
            }
            $markerOnlyRegistry = Get-Content -LiteralPath $legacyState.RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
            $markerOnlyRegistry.released_target_history = @()
            try {
                Assert-InstallRegistryReleaseMarkerCoverage `
                    -Registry $markerOnlyRegistry `
                    -ExpectedUserProfile $managedConfigRetirementFixture.User `
                    -ManifestPaths @($markerOnlyRegistry.global_manifest_history)
                Add-Failure 'release marker coverage accepted registry state without a tombstone'
            } catch {
                Add-Check 'release marker coverage rejects registry state without a tombstone'
            }
            $releaseRegistryBytes = [System.IO.File]::ReadAllBytes($legacyState.RegistryPath)
            $releaseRegistryDocument = Get-Content -LiteralPath $legacyState.RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
            $releaseWorkspaceKey = (Get-NormalizedPath -Path $managedConfigRetirementFixture.Workspace).TrimEnd('\','/').ToLowerInvariant()
            $releaseManifestPath = Get-NormalizedPath -Path ([string]@($releaseRegistryDocument.workspaces[$releaseWorkspaceKey].manifests)[-1])
            $releaseManifestBytes = [System.IO.File]::ReadAllBytes($releaseManifestPath)
            $releaseManagedConfigBytes = [System.IO.File]::ReadAllBytes($managedConfigPath)
            $releaseWorkspaceAgentsPath = Join-Path $managedConfigRetirementFixture.Workspace 'AGENTS.md'
            $releaseWorkspaceAgentsBytes = [System.IO.File]::ReadAllBytes($releaseWorkspaceAgentsPath)
            $releaseUninstallJournalPath = Join-Path $managedConfigRetirementFixture.User '.dev-harness\uninstall-transaction.json'
            Remove-Item -LiteralPath $legacyState.RegistryPath -Force
            try {
                $unregisteredReleaseUninstall = Invoke-ChildScript `
                    -UserProfile $managedConfigRetirementFixture.User `
                    -ScriptPath $script:UninstallScript `
                    -Arguments @('-ManifestPath',$releaseManifestPath,'-RepoRoot',$script:RepoRoot)
                $unregisteredReleaseRejected = $unregisteredReleaseUninstall.ExitCode -ne 0 -and
                    $unregisteredReleaseUninstall.Output -match 'requires install registry evidence' -and
                    -not (Test-Path -LiteralPath $releaseUninstallJournalPath) -and
                    ([System.IO.File]::ReadAllBytes($releaseManifestPath) -join ',') -ceq ($releaseManifestBytes -join ',') -and
                    ([System.IO.File]::ReadAllBytes($managedConfigPath) -join ',') -ceq ($releaseManagedConfigBytes -join ',') -and
                    ([System.IO.File]::ReadAllBytes($releaseWorkspaceAgentsPath) -join ',') -ceq ($releaseWorkspaceAgentsBytes -join ',')
            } finally {
                [System.IO.File]::WriteAllBytes($legacyState.RegistryPath,$releaseRegistryBytes)
            }
            if ($unregisteredReleaseRejected) {
                Add-Check 'normal unregistered release-manifest uninstall fails closed before reclaiming managed_config'
            } else {
                Add-Failure 'normal unregistered release-manifest uninstall did not fail closed without registry evidence'
            }

            $userManagedText = "# user changed after Harness release`r`n[features]`r`nhooks = false`r`n"
            [System.IO.File]::WriteAllText($managedConfigPath,$userManagedText,[System.Text.UTF8Encoding]::new($false))
            $postReleaseUpdate = Invoke-Install -Fixture $managedConfigRetirementFixture -ExtraArguments @('-Preset','core')
            Assert-InstallExit $postReleaseUpdate 'released managed config user update'
            if ($postReleaseUpdate.ExitCode -eq 0 -and [System.IO.File]::ReadAllText($managedConfigPath) -ceq $userManagedText) {
                Add-Check 'subsequent install preserves user edits after managed_config ownership release'
            } else {
                Add-Failure 'subsequent install reclaimed or changed released managed_config ownership'
            }
            Assert-UninstallExit (Invoke-Uninstall $managedConfigRetirementFixture) 'released managed config'
            if ((Test-Path -LiteralPath $managedConfigPath -PathType Leaf) -and
                [System.IO.File]::ReadAllText($managedConfigPath) -ceq $userManagedText) {
                Add-Check 'uninstall leaves the released managed_config under external ownership'
            } else {
                Add-Failure 'uninstall changed or removed the released managed_config'
            }
        }
    }

    $managedConfigHandoffA = New-PresetFixture -Name 'managed-config-handoff'
    $managedConfigHandoffB = [pscustomobject]@{
        Root = $managedConfigHandoffA.Root
        Workspace = (Join-Path $managedConfigHandoffA.Root 'workspace-b')
        User = $managedConfigHandoffA.User
    }
    New-Item -ItemType Directory -Path $managedConfigHandoffB.Workspace -Force | Out-Null
    $handoffBaselineInstall = Invoke-Install -Fixture $managedConfigHandoffA -ExtraArguments @('-Preset','core')
    Assert-InstallExit $handoffBaselineInstall 'managed config handoff workspace A baseline'
    if ($handoffBaselineInstall.ExitCode -eq 0) {
        $handoffExternalText = "# external administrator handoff policy`r`n[features]`r`nhooks = false`r`n"
        $handoffLegacyText = "# Managed by install.ps1`r`nallow_managed_hooks_only = true`r`n[features]`r`nhooks = true`r`n"
        $handoffLegacyState = Set-TestLegacyManagedConfigState `
            -Fixture $managedConfigHandoffA `
            -ExternalBaselineText $handoffExternalText `
            -LegacyManagedText $handoffLegacyText
        $handoffManagedConfigPath = $handoffLegacyState.ManagedConfigPath
        $handoffOriginalManifestPath = $handoffLegacyState.ManifestPath
        $handoffWorkspaceBInstall = Invoke-Install -Fixture $managedConfigHandoffB -ExtraArguments @('-Preset','core')
        Assert-InstallExit $handoffWorkspaceBInstall 'managed config handoff workspace B release'
        if ($handoffWorkspaceBInstall.ExitCode -eq 0) {
            $handoffRegistryBeforeUninstall = Get-Content -LiteralPath $handoffLegacyState.RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
            $handoffWorkspaceBKey = (Get-NormalizedPath -Path $managedConfigHandoffB.Workspace).TrimEnd('\','/').ToLowerInvariant()
            $handoffWorkspaceBManifestPath = Get-NormalizedPath -Path ([string]@($handoffRegistryBeforeUninstall.workspaces[$handoffWorkspaceBKey].manifests)[-1])
            $handoffReleasedEntries = @($handoffRegistryBeforeUninstall.released_target_history | Where-Object {
                (Get-NormalizedPath -Path $_.path) -eq (Get-NormalizedPath -Path $handoffManagedConfigPath)
            })
            $handoffReleasedManifestPaths = if ($handoffReleasedEntries.Count -eq 1) {
                @($handoffReleasedEntries[0].manifest_paths | ForEach-Object { Get-NormalizedPath -Path $_ })
            } else {
                @()
            }
            $handoffRegistryWithBadDigest = ConvertFrom-InstallJson -Json (ConvertTo-Json -InputObject $handoffRegistryBeforeUninstall -Depth 100)
            $handoffRegistryWithBadDigest['released_target_history'][0]['release_manifest_plan_digest'] = ('0' * 64)
            try {
                [void](Get-InstallRegistryReleasedTargetHistoryMap `
                    -Registry $handoffRegistryWithBadDigest `
                    -ExpectedUserProfile $managedConfigHandoffA.User)
                Add-Failure 'release history accepted a mismatched release manifest plan digest'
            } catch {
                Add-Check 'release history rejects a mismatched release manifest plan digest'
            }
            if ([System.IO.File]::ReadAllText($handoffManagedConfigPath) -ceq $handoffExternalText -and
                $handoffReleasedEntries.Count -eq 1 -and
                $handoffReleasedManifestPaths -contains $handoffOriginalManifestPath -and
                $handoffReleasedManifestPaths -contains $handoffWorkspaceBManifestPath) {
                Add-Check 'managed_config release tombstone covers both owners before workspace handoff'
            } else {
                Add-Failure 'managed_config release tombstone did not cover both owners before workspace handoff'
            }

            $handoffUserText = "# user changed after workspace handoff release`r`n[features]`r`nhooks = false`r`n"
            [System.IO.File]::WriteAllText($handoffManagedConfigPath,$handoffUserText,[System.Text.UTF8Encoding]::new($false))
            $handoffUninstallJournalPath = Join-Path $managedConfigHandoffA.User '.dev-harness\uninstall-transaction.json'
            $handoffRegistryCommitLock = [System.IO.File]::Open($handoffLegacyState.RegistryPath,'Open','Read','ReadWrite')
            try {
                $handoffInterruptedUninstall = Invoke-Uninstall $managedConfigHandoffB
            } finally {
                $handoffRegistryCommitLock.Dispose()
            }
            if ($handoffInterruptedUninstall.ExitCode -ne 0 -and
                (Test-Path -LiteralPath $handoffUninstallJournalPath -PathType Leaf)) {
                Add-Check 'managed_config release handoff persists a resumable uninstall journal when registry commit is interrupted'
                $handoffWorkspaceBUninstall = Invoke-Uninstall $managedConfigHandoffB
                Assert-UninstallExit $handoffWorkspaceBUninstall 'managed config handoff workspace B resume'
            } else {
                Add-Failure "managed_config release handoff did not expose a resumable interrupted uninstall: exit=$($handoffInterruptedUninstall.ExitCode)"
                $handoffWorkspaceBUninstall = $null
            }
            if ($null -ne $handoffWorkspaceBUninstall -and $handoffWorkspaceBUninstall.ExitCode -eq 0 -and
                -not (Test-Path -LiteralPath $handoffUninstallJournalPath)) {
                $handoffRegistryAfterUninstall = Get-Content -LiteralPath $handoffLegacyState.RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
                $handoffEntriesAfterUninstall = @($handoffRegistryAfterUninstall.released_target_history | Where-Object {
                    (Get-NormalizedPath -Path $_.path) -eq (Get-NormalizedPath -Path $handoffManagedConfigPath)
                })
                $handoffPathsAfterUninstall = if ($handoffEntriesAfterUninstall.Count -eq 1) {
                    @($handoffEntriesAfterUninstall[0].manifest_paths | ForEach-Object { Get-NormalizedPath -Path $_ })
                } else {
                    @()
                }
                if ($handoffRegistryAfterUninstall.workspaces.Count -eq 1 -and
                    @($handoffRegistryAfterUninstall.global_manifest_history).Count -eq 1 -and
                    (Get-NormalizedPath -Path $handoffRegistryAfterUninstall.global_manifest_history[0]) -eq $handoffOriginalManifestPath -and
                    $handoffPathsAfterUninstall -contains $handoffOriginalManifestPath -and
                    [System.IO.File]::ReadAllText($handoffManagedConfigPath) -ceq $handoffUserText) {
                    Add-Check 'managed_config release tombstone survives owner handoff and preserves user edits'
                } else {
                    Add-Failure 'managed_config release tombstone or user edits were lost during owner handoff'
                }

                $handoffWorkspaceAUpdate = Invoke-Install -Fixture $managedConfigHandoffA -ExtraArguments @('-Preset','core')
                Assert-InstallExit $handoffWorkspaceAUpdate 'managed config handoff workspace A update'
                if ($handoffWorkspaceAUpdate.ExitCode -eq 0 -and
                    [System.IO.File]::ReadAllText($handoffManagedConfigPath) -ceq $handoffUserText) {
                    Add-Check 'remaining workspace update respects released managed_config ownership'
                } else {
                    Add-Failure 'remaining workspace update reclaimed or changed released managed_config ownership'
                }

                if ($handoffWorkspaceAUpdate.ExitCode -eq 0) {
                    $finalRegistryCommitLock = [System.IO.File]::Open($handoffLegacyState.RegistryPath,'Open','Read','ReadWrite')
                    try {
                        $finalInterruptedUninstall = Invoke-Uninstall $managedConfigHandoffA
                    } finally {
                        $finalRegistryCommitLock.Dispose()
                    }
                    if ($finalInterruptedUninstall.ExitCode -ne 0 -and
                        (Test-Path -LiteralPath $handoffUninstallJournalPath -PathType Leaf)) {
                        $finalJournalRaw = Get-Content -LiteralPath $handoffUninstallJournalPath -Raw -Encoding utf8
                        $finalJournal = $finalJournalRaw | ConvertFrom-Json -AsHashtable -DateKind String
                        foreach ($consumedManifestPath in @($finalJournal.fully_consumed_manifest_paths)) {
                            $consumedManifest = Get-Content -LiteralPath $consumedManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
                            $consumedManifest.transaction_status = 'uninstalled'
                            $consumedManifest['uninstalled_at'] = Get-Date -Format 's'
                            [System.IO.File]::WriteAllText($consumedManifestPath,($consumedManifest | ConvertTo-Json -Depth 100),[System.Text.UTF8Encoding]::new($false))
                        }
                        Remove-Item -LiteralPath $handoffLegacyState.RegistryPath -Force
                        $tamperedFinalJournal = $finalJournalRaw | ConvertFrom-Json -AsHashtable -DateKind String
                        $tamperedReleaseEntries = @($tamperedFinalJournal.released_target_history)
                        if ($tamperedReleaseEntries.Count -eq 1) {
                            $tamperedReleaseEntries[0].release_manifest_plan_digest = ('0' * 64)
                        }
                        [System.IO.File]::WriteAllText($handoffUninstallJournalPath,($tamperedFinalJournal | ConvertTo-Json -Depth 100),[System.Text.UTF8Encoding]::new($false))
                        $tamperedFinalJournalBytes = [System.IO.File]::ReadAllBytes($handoffUninstallJournalPath)
                        $tamperedFinalUserBytes = [System.IO.File]::ReadAllBytes($handoffManagedConfigPath)
                        $tamperedFinalResume = Invoke-Uninstall $managedConfigHandoffA
                        if ($tamperedReleaseEntries.Count -eq 1 -and
                            $tamperedFinalResume.ExitCode -ne 0 -and
                            -not (Test-Path -LiteralPath $handoffLegacyState.RegistryPath) -and
                            (Test-Path -LiteralPath $handoffUninstallJournalPath -PathType Leaf) -and
                            ([System.IO.File]::ReadAllBytes($handoffUninstallJournalPath) -join ',') -ceq ($tamperedFinalJournalBytes -join ',') -and
                            ([System.IO.File]::ReadAllBytes($handoffManagedConfigPath) -join ',') -ceq ($tamperedFinalUserBytes -join ',')) {
                            Add-Check 'post-commit uninstall resume rejects tampered managed_config release history without cleanup'
                        } else {
                            Add-Failure 'post-commit uninstall resume accepted or changed tampered managed_config release history'
                        }
                        [System.IO.File]::WriteAllText($handoffUninstallJournalPath,$finalJournalRaw,[System.Text.UTF8Encoding]::new($false))
                        $handoffWorkspaceAUninstall = Invoke-Uninstall $managedConfigHandoffA
                        Assert-UninstallExit $handoffWorkspaceAUninstall 'managed config handoff workspace A post-commit resume'
                    } else {
                        Add-Failure "managed_config final uninstall did not expose a resumable delete commit: exit=$($finalInterruptedUninstall.ExitCode)"
                        $handoffWorkspaceAUninstall = $null
                    }
                    if ($null -ne $handoffWorkspaceAUninstall -and $handoffWorkspaceAUninstall.ExitCode -eq 0 -and
                        -not (Test-Path -LiteralPath $handoffLegacyState.RegistryPath) -and
                        -not (Test-Path -LiteralPath $handoffUninstallJournalPath) -and
                        (Test-Path -LiteralPath $handoffManagedConfigPath -PathType Leaf) -and
                        [System.IO.File]::ReadAllText($handoffManagedConfigPath) -ceq $handoffUserText) {
                        Add-Check 'final workspace uninstall removes registry state and preserves released managed_config'
                    } else {
                        Add-Failure 'final workspace uninstall did not preserve released managed_config or clean registry state'
                    }
                }
            }
        }
    }

    $hookDriftFixture = New-PresetFixture -Name 'codex-hook-drift'
    $hookDriftInstall = Invoke-Install -Fixture $hookDriftFixture -ExtraArguments @('-Preset','core')
    Assert-InstallExit $hookDriftInstall 'Codex hook drift baseline'
    if ($hookDriftInstall.ExitCode -eq 0) {
        $hookDriftPath = Join-Path $hookDriftFixture.User '.codex\hooks.json'
        $hookDriftRegistryPath = Join-Path $hookDriftFixture.User '.dev-harness\install-registry.json'
        $hookDriftAgentsPath = Join-Path $hookDriftFixture.Workspace 'AGENTS.md'
        $installedHookBytes = [System.IO.File]::ReadAllBytes($hookDriftPath)
        $registryBytesBeforeDriftUpdate = [System.IO.File]::ReadAllBytes($hookDriftRegistryPath)
        $agentsBytesBeforeDriftUpdate = [System.IO.File]::ReadAllBytes($hookDriftAgentsPath)
        $driftedHooks = Get-Content -LiteralPath $hookDriftPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
        [void]$driftedHooks.hooks.Remove('PreToolUse')
        [System.IO.File]::WriteAllText($hookDriftPath,($driftedHooks | ConvertTo-Json -Depth 20),[System.Text.UTF8Encoding]::new($false))
        $driftedHookBytes = [System.IO.File]::ReadAllBytes($hookDriftPath)
        $hookDriftUpdate = Invoke-Install -Fixture $hookDriftFixture
        if ($hookDriftUpdate.ExitCode -ne 0 -and
            $hookDriftUpdate.Output -match 'registered Harness postimage' -and
            ([System.IO.File]::ReadAllBytes($hookDriftPath) -join ',') -ceq ($driftedHookBytes -join ',') -and
            ([System.IO.File]::ReadAllBytes($hookDriftRegistryPath) -join ',') -ceq ($registryBytesBeforeDriftUpdate -join ',') -and
            ([System.IO.File]::ReadAllBytes($hookDriftAgentsPath) -join ',') -ceq ($agentsBytesBeforeDriftUpdate -join ',')) {
            Add-Check 'Codex hook drift rejects update before mutating hooks, registry, or workspace entry'
        } else {
            Add-Failure "Codex hook drift did not fail closed before update writes: exit=$($hookDriftUpdate.ExitCode) output=$($hookDriftUpdate.Output)"
        }
        [System.IO.File]::WriteAllBytes($hookDriftPath,$installedHookBytes)
        Assert-UninstallExit (Invoke-Uninstall $hookDriftFixture) 'Codex hook drift recovery'
    }

    $hookRaceFixture = New-PresetFixture -Name 'codex-hook-snapshot-race'
    $hookRaceRepo = Join-Path $hookRaceFixture.Root 'repo'
    New-Item -ItemType Directory -Path $hookRaceRepo -Force | Out-Null
    foreach ($directoryName in @('agent-configs','runtime-hooks','vault-template','skills','scripts')) {
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $directoryName) -Destination (Join-Path $hookRaceRepo $directoryName) -Recurse -Force
    }
    $hookRaceInstallScript = Join-Path $hookRaceRepo 'install.ps1'
    $hookRaceUninstallScript = Join-Path $hookRaceRepo 'uninstall.ps1'
    Copy-Item -LiteralPath $script:InstallScript -Destination $hookRaceInstallScript -Force
    Copy-Item -LiteralPath $script:UninstallScript -Destination $hookRaceUninstallScript -Force
    $hookRaceArguments = @('-WorkspaceRoot',$hookRaceFixture.Workspace,'-RepoRoot',$hookRaceRepo,'-Preset','core')
    $hookRaceInstall = Invoke-ChildScript -UserProfile $hookRaceFixture.User -ScriptPath $hookRaceInstallScript -Arguments $hookRaceArguments
    Assert-InstallExit $hookRaceInstall 'Codex hook snapshot-race baseline'
    if ($hookRaceInstall.ExitCode -eq 0) {
        $hookRacePath = Join-Path $hookRaceFixture.User '.codex\hooks.json'
        $hookRaceRegistryPath = Join-Path $hookRaceFixture.User '.dev-harness\install-registry.json'
        $hookRaceAgentsPath = Join-Path $hookRaceFixture.Workspace 'AGENTS.md'
        $hookRaceJournalPath = Join-Path $hookRaceFixture.User '.dev-harness\install-transaction.json'
        $hookRaceInstalledBytes = [System.IO.File]::ReadAllBytes($hookRacePath)
        $hookRaceRegistryBytes = [System.IO.File]::ReadAllBytes($hookRaceRegistryPath)
        $hookRaceAgentsBytes = [System.IO.File]::ReadAllBytes($hookRaceAgentsPath)
        $hookRaceInstallSource = Get-Content -LiteralPath $hookRaceInstallScript -Raw -Encoding utf8
        $hookRaceMutation = @'
    $testRaceHooks = Get-Content -LiteralPath $codexHooksPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
    [void]$testRaceHooks.hooks.Remove('PreToolUse')
    [System.IO.File]::WriteAllText($codexHooksPath,($testRaceHooks | ConvertTo-Json -Depth 20),[System.Text.UTF8Encoding]::new($false))
'@
        $beforeMergeAnchor = '    $codexHooksMerge = Merge-ClaudeSettingsJsonText `'
        if (@($hookRaceInstallSource.Split([string[]]@($beforeMergeAnchor),[System.StringSplitOptions]::None)).Count -ne 2) {
            Add-Failure 'Codex hook snapshot-race merge anchor is not unique'
        } else {
            $beforeMergeSource = $hookRaceInstallSource.Replace($beforeMergeAnchor,($hookRaceMutation + [Environment]::NewLine + $beforeMergeAnchor))
            [System.IO.File]::WriteAllText($hookRaceInstallScript,$beforeMergeSource,[System.Text.UTF8Encoding]::new($true))
            $beforeMergeRace = Invoke-ChildScript -UserProfile $hookRaceFixture.User -ScriptPath $hookRaceInstallScript -Arguments $hookRaceArguments
            $raceAfterBeforeMerge = Get-Content -LiteralPath $hookRacePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
            $beforeMergePending = Test-Path -LiteralPath $hookRaceJournalPath -PathType Leaf
            $beforeMergeRecovery = $null
            if ($beforeMergePending) {
                $beforeMergeJournal = Get-Content -LiteralPath $hookRaceJournalPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
                $beforeMergeRecovery = Invoke-ChildScript -UserProfile $hookRaceFixture.User -ScriptPath $hookRaceUninstallScript -Arguments @(
                    '-RecoveryManifestPath',[string]$beforeMergeJournal.manifest_path,'-RepoRoot',$hookRaceRepo
                )
            }
            $raceAfterBeforeMergeRecovery = Get-Content -LiteralPath $hookRacePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
            $beforeMergeRacePreserved = $beforeMergeRace.ExitCode -ne 0 -and
                $beforeMergeRace.Output -match 'registered Harness postimage' -and
                $beforeMergePending -and $null -ne $beforeMergeRecovery -and $beforeMergeRecovery.ExitCode -eq 0 -and
                -not (Test-Path -LiteralPath $hookRaceJournalPath) -and
                ([System.IO.File]::ReadAllBytes($hookRaceRegistryPath) -join ',') -ceq ($hookRaceRegistryBytes -join ',') -and
                ([System.IO.File]::ReadAllBytes($hookRaceAgentsPath) -join ',') -ceq ($hookRaceAgentsBytes -join ',')
            if ($beforeMergeRacePreserved -and
                -not $raceAfterBeforeMerge.hooks.Contains('PreToolUse') -and
                -not $raceAfterBeforeMergeRecovery.hooks.Contains('PreToolUse')) {
                Add-Check 'Codex hook final merge rejects a raced source snapshot and recovery preserves it without committing state'
            } else {
                Add-Failure "Codex hook final merge did not reject and preserve a raced source snapshot: exit=$($beforeMergeRace.ExitCode) output=$($beforeMergeRace.Output)"
            }
        }

        [System.IO.File]::WriteAllBytes($hookRacePath,$hookRaceInstalledBytes)
        $afterMergeAnchor = '    $codexHooksExpectedPostimage = New-ClaudeSettingsPostimageIdentity'
        if (@($hookRaceInstallSource.Split([string[]]@($afterMergeAnchor),[System.StringSplitOptions]::None)).Count -ne 2) {
            Add-Failure 'Codex hook snapshot-race backup anchor is not unique'
        } else {
            $afterMergeSource = $hookRaceInstallSource.Replace($afterMergeAnchor,($hookRaceMutation + [Environment]::NewLine + $afterMergeAnchor))
            [System.IO.File]::WriteAllText($hookRaceInstallScript,$afterMergeSource,[System.Text.UTF8Encoding]::new($true))
            $afterMergeRace = Invoke-ChildScript -UserProfile $hookRaceFixture.User -ScriptPath $hookRaceInstallScript -Arguments $hookRaceArguments
            $raceAfterMerge = Get-Content -LiteralPath $hookRacePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
            $afterMergePending = Test-Path -LiteralPath $hookRaceJournalPath -PathType Leaf
            $afterMergeRecovery = $null
            if ($afterMergePending) {
                $afterMergeJournal = Get-Content -LiteralPath $hookRaceJournalPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
                $afterMergeRecovery = Invoke-ChildScript -UserProfile $hookRaceFixture.User -ScriptPath $hookRaceUninstallScript -Arguments @(
                    '-RecoveryManifestPath',[string]$afterMergeJournal.manifest_path,'-RepoRoot',$hookRaceRepo
                )
            }
            $raceAfterMergeRecovery = Get-Content -LiteralPath $hookRacePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
            $afterMergeRacePreserved = $afterMergeRace.ExitCode -ne 0 -and
                $afterMergeRace.Output -match 'Backup source changed from its expected current identity' -and
                $afterMergePending -and $null -ne $afterMergeRecovery -and $afterMergeRecovery.ExitCode -eq 0 -and
                -not (Test-Path -LiteralPath $hookRaceJournalPath) -and
                ([System.IO.File]::ReadAllBytes($hookRaceRegistryPath) -join ',') -ceq ($hookRaceRegistryBytes -join ',') -and
                ([System.IO.File]::ReadAllBytes($hookRaceAgentsPath) -join ',') -ceq ($hookRaceAgentsBytes -join ',')
            if ($afterMergeRacePreserved -and
                -not $raceAfterMerge.hooks.Contains('PreToolUse') -and
                -not $raceAfterMergeRecovery.hooks.Contains('PreToolUse')) {
                Add-Check 'Codex hook backup rejects a post-merge race and recovery preserves it without committing state'
            } else {
                Add-Failure "Codex hook backup did not reject and preserve a post-merge race: exit=$($afterMergeRace.ExitCode) output=$($afterMergeRace.Output)"
            }
        }

        $runRecordedPreimageRace = {
            param(
                [string]$FixtureName,
                [string]$Label,
                [string]$InjectedInstallSource
            )

            [System.IO.File]::WriteAllText($hookRaceInstallScript,$hookRaceInstallSource,[System.Text.UTF8Encoding]::new($true))
            $fixture = New-PresetFixture -Name $FixtureName
            $arguments = @('-WorkspaceRoot',$fixture.Workspace,'-RepoRoot',$hookRaceRepo,'-Preset','core')
            $baseline = Invoke-ChildScript -UserProfile $fixture.User -ScriptPath $hookRaceInstallScript -Arguments $arguments
            Assert-InstallExit $baseline "$Label baseline"
            if ($baseline.ExitCode -ne 0) { return }

            $hooksPath = Join-Path $fixture.User '.codex\hooks.json'
            $registryPath = Join-Path $fixture.User '.dev-harness\install-registry.json'
            $agentsPath = Join-Path $fixture.Workspace 'AGENTS.md'
            $journalPath = Join-Path $fixture.User '.dev-harness\install-transaction.json'
            $hooksBytes = [System.IO.File]::ReadAllBytes($hooksPath)
            $registryBytes = [System.IO.File]::ReadAllBytes($registryPath)
            $agentsBytes = [System.IO.File]::ReadAllBytes($agentsPath)

            [System.IO.File]::WriteAllText($hookRaceInstallScript,$InjectedInstallSource,[System.Text.UTF8Encoding]::new($true))
            $race = Invoke-ChildScript -UserProfile $fixture.User -ScriptPath $hookRaceInstallScript -Arguments $arguments
            $journalPending = Test-Path -LiteralPath $journalPath -PathType Leaf
            $journal = $null
            $targetBackupRecordCount = -1
            if ($journalPending) {
                try {
                    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
                    $failedManifest = Get-Content -LiteralPath ([string]$journal.manifest_path) -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
                    $normalizedHooksPath = Get-NormalizedPath -Path $hooksPath
                    $targetBackupRecordCount = @($failedManifest.backups | Where-Object {
                        (Get-NormalizedPath -Path ([string]$_['path'])) -eq $normalizedHooksPath
                    }).Count
                } catch {
                    Add-Failure "$Label did not leave a readable recovery journal and manifest: $($_.Exception.Message)"
                }
            }

            $preRecoveryExact =
                (Test-Path -LiteralPath $hooksPath -PathType Leaf) -and
                (Test-Path -LiteralPath $registryPath -PathType Leaf) -and
                (Test-Path -LiteralPath $agentsPath -PathType Leaf) -and
                (([System.IO.File]::ReadAllBytes($hooksPath) -join ',') -ceq ($hooksBytes -join ',')) -and
                (([System.IO.File]::ReadAllBytes($registryPath) -join ',') -ceq ($registryBytes -join ',')) -and
                (([System.IO.File]::ReadAllBytes($agentsPath) -join ',') -ceq ($agentsBytes -join ','))

            $recovery = $null
            if ($null -ne $journal) {
                $recovery = Invoke-ChildScript -UserProfile $fixture.User -ScriptPath $hookRaceUninstallScript -Arguments @(
                    '-RecoveryManifestPath',[string]$journal.manifest_path,'-RepoRoot',$hookRaceRepo
                )
            }
            $postRecoveryExact =
                (Test-Path -LiteralPath $hooksPath -PathType Leaf) -and
                (Test-Path -LiteralPath $registryPath -PathType Leaf) -and
                (Test-Path -LiteralPath $agentsPath -PathType Leaf) -and
                (([System.IO.File]::ReadAllBytes($hooksPath) -join ',') -ceq ($hooksBytes -join ',')) -and
                (([System.IO.File]::ReadAllBytes($registryPath) -join ',') -ceq ($registryBytes -join ',')) -and
                (([System.IO.File]::ReadAllBytes($agentsPath) -join ',') -ceq ($agentsBytes -join ','))

            if ($race.ExitCode -ne 0 -and
                $race.Output -match 'Recorded backup preimage does not match its expected source identity' -and
                $journalPending -and $targetBackupRecordCount -eq 0 -and $preRecoveryExact -and
                $null -ne $recovery -and $recovery.ExitCode -eq 0 -and
                -not (Test-Path -LiteralPath $journalPath) -and $postRecoveryExact) {
                Add-Check "$Label rejects the incoherent preimage before appending its backup record and recovers exact bytes"
            } else {
                Add-Failure "$Label did not reject and recover the incoherent preimage: exit=$($race.ExitCode) records=$targetBackupRecordCount pending=$journalPending pre_exact=$preRecoveryExact recovery_exit=$(if ($null -eq $recovery) { 'none' } else { $recovery.ExitCode }) post_exact=$postRecoveryExact output=$($race.Output)"
            }
        }

        $managedBackupTargetAnchor = '    $script:Manifest.managed_backup_targets = @($script:Manifest.managed_backup_targets + $normalizedPath | Select-Object -Unique)'
        $recordExistedAnchor = '    if ($record.existed) {'
        $missingBeforeRecord = @'
    $testRecordedPreimageBytes = $null
    if ($null -ne $ExpectedCurrentIdentity -and
        $normalizedPath -eq (Get-NormalizedPath -Path $codexHooksPath)) {
        $testRecordedPreimageBytes = [System.IO.File]::ReadAllBytes($normalizedPath)
        Remove-Item -LiteralPath $normalizedPath -Force
    }
'@
        $missingBeforeBackup = @'
    if ($null -ne $testRecordedPreimageBytes) {
        [System.IO.File]::WriteAllBytes($normalizedPath,$testRecordedPreimageBytes)
    }
'@
        if (@($hookRaceInstallSource.Split([string[]]@($managedBackupTargetAnchor),[System.StringSplitOptions]::None)).Count -ne 2 -or
            @($hookRaceInstallSource.Split([string[]]@($recordExistedAnchor),[System.StringSplitOptions]::None)).Count -ne 2) {
            Add-Failure 'Codex hook file-to-missing preimage-race anchors are not unique'
        } else {
            $missingRaceSource = $hookRaceInstallSource.Replace(
                $managedBackupTargetAnchor,
                ($managedBackupTargetAnchor + [Environment]::NewLine + $missingBeforeRecord.TrimEnd()))
            $missingRaceSource = $missingRaceSource.Replace(
                $recordExistedAnchor,
                ($missingBeforeBackup.TrimEnd() + [Environment]::NewLine + $recordExistedAnchor))
            & $runRecordedPreimageRace `
                -FixtureName 'codex-hook-file-missing-file-race' `
                -Label 'Codex hook file-to-missing-to-same preimage race' `
                -InjectedInstallSource $missingRaceSource
        }

        $getBackupItemAnchor = '        $item = Get-Item -LiteralPath $normalizedPath -Force'
        $getPreimageIdentityAnchor = '        $preimageIdentity = Get-InstallManagedPathIdentity -Path $normalizedPath'
        $junctionBeforeItem = @'
        $testRecordedPreimageBytes = $null
        if ($null -ne $ExpectedCurrentIdentity -and
            $normalizedPath -eq (Get-NormalizedPath -Path $codexHooksPath)) {
            $testRecordedPreimageBytes = [System.IO.File]::ReadAllBytes($normalizedPath)
            $testRecordedPreimageJunctionTarget = Join-Path $script:BackupRoot '_recorded-preimage-junction-target'
            [System.IO.Directory]::CreateDirectory($testRecordedPreimageJunctionTarget) | Out-Null
            Remove-Item -LiteralPath $normalizedPath -Force
            New-Item -ItemType Junction -Path $normalizedPath -Target $testRecordedPreimageJunctionTarget | Out-Null
        }
'@
        $junctionBeforeIdentity = @'
        if ($null -ne $testRecordedPreimageBytes) {
            $testRecordedPreimageItem = [pscustomobject]@{
                Attributes = $item.Attributes
                Target = $item.Target
                PSIsContainer = $item.PSIsContainer
                LinkType = $item.LinkType
            }
            Remove-Item -LiteralPath $normalizedPath -Force
            [System.IO.File]::WriteAllBytes($normalizedPath,$testRecordedPreimageBytes)
            $item = $testRecordedPreimageItem
        }
'@
        if (@($hookRaceInstallSource.Split([string[]]@($getBackupItemAnchor),[System.StringSplitOptions]::None)).Count -ne 2 -or
            @($hookRaceInstallSource.Split([string[]]@($getPreimageIdentityAnchor),[System.StringSplitOptions]::None)).Count -ne 2) {
            Add-Failure 'Codex hook file-to-junction preimage-race anchors are not unique'
        } else {
            $junctionRaceSource = $hookRaceInstallSource.Replace(
                $getBackupItemAnchor,
                ($junctionBeforeItem.TrimEnd() + [Environment]::NewLine + $getBackupItemAnchor))
            $junctionRaceSource = $junctionRaceSource.Replace(
                $getPreimageIdentityAnchor,
                ($junctionBeforeIdentity.TrimEnd() + [Environment]::NewLine + $getPreimageIdentityAnchor))
            & $runRecordedPreimageRace `
                -FixtureName 'codex-hook-file-junction-file-race' `
                -Label 'Codex hook file-to-junction-to-same preimage race' `
                -InjectedInstallSource $junctionRaceSource
        }

        [System.IO.File]::WriteAllText($hookRaceInstallScript,$hookRaceInstallSource,[System.Text.UTF8Encoding]::new($true))
    }

    $apostropheFixture = New-PresetFixture -Name "apostrophe'shim-{VAULT_PATH}"
    $apostropheInstall = Invoke-Install -Fixture $apostropheFixture -ExtraArguments @('-Preset','core')
    Assert-InstallExit $apostropheInstall 'apostrophe workspace'
    if ($apostropheInstall.ExitCode -eq 0) {
        Assert-InstalledCodexHook -Fixture $apostropheFixture -Label 'apostrophe workspace'
        $apostropheHooksDocument = Get-Content -LiteralPath (Join-Path $apostropheFixture.User '.codex\hooks.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String
        $apostropheHookCommand = [string]@($apostropheHooksDocument.hooks.PreToolUse | Where-Object { [string]$_.matcher -ceq '^(Bash|apply_patch|Write|Edit|MultiEdit|NotebookEdit)$' })[0].hooks[0].command
        $apostropheHookInput = [ordered]@{
            tool_name = 'Bash'
            permission_mode = 'default'
            tool_input = [ordered]@{ command = "Write-Output '注释'" }
            cwd = $apostropheFixture.Workspace
        } | ConvertTo-Json -Depth 10 -Compress
        $apostropheHookResult = Invoke-CodexHookCommandWithInput -Runner cmd -Command $apostropheHookCommand -InputText $apostropheHookInput -WorkingDirectory $apostropheFixture.Workspace
        if ($apostropheHookResult.ExitCode -eq 0 -and $apostropheHookResult.StdOut.Trim() -ceq '{}' -and [string]::IsNullOrWhiteSpace($apostropheHookResult.StdErr)) {
            Add-Check 'installed Codex Hook command fixture preserves UTF-8 stdin and apostrophe paths through the default Windows cmd parser'
        } else {
            Add-Failure "installed Codex Hook command fixture failed for UTF-8 stdin or an apostrophe path: exit=$($apostropheHookResult.ExitCode) stdout=$($apostropheHookResult.StdOut) stderr=$($apostropheHookResult.StdErr)"
        }
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
        $apostropheHooksPath = Join-Path $apostropheFixture.User '.codex\hooks.json'
        if (-not (Test-Path -LiteralPath $apostropheHooksPath)) {
            Add-Check 'fresh Codex hook install removes hooks.json when no preimage exists'
        } else {
            Add-Failure 'fresh Codex hook uninstall left hooks.json without a preimage'
        }
    }

    $governedFixture = New-PresetFixture -Name 'governed'
    $governedProtocolConfig = New-ProtocolConfigSentinel -Fixture $governedFixture
    $governedInstall = Invoke-Install -Fixture $governedFixture -ExtraArguments @('-Preset','governed')
    Assert-InstallExit $governedInstall 'governed'
    if ($governedInstall.ExitCode -eq 0) {
        $governedManifest = Get-LatestManifest $governedFixture
        Assert-ManifestPreset $governedManifest 'governed' 'preset' $governedFeatures $governedSkills $coreHooks 'minimal'
        Assert-InstalledTaskShim $governedFixture $governedManifest 'governed install'
        Assert-InstalledTaskProtocol $governedFixture 'governed install'
        Assert-ProtocolConfigPreserved $governedFixture $governedProtocolConfig $governedManifest 'governed install'
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
            Assert-ProtocolConfigPreserved $governedFixture $governedProtocolConfig $governedUpdateManifest 'governed update'
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
        Assert-ProtocolConfigPreserved $governedFixture $governedProtocolConfig $null 'governed uninstall'
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
    $presetCoreProtocolConfig = New-ProtocolConfigSentinel -Fixture $presetCoreFixture
    $presetCoreInstall = Invoke-Install -Fixture $presetCoreFixture -ExtraArguments @('-Preset','core')
    Assert-InstallExit $presetCoreInstall 'explicit core without rollout report'
    if ($presetCoreInstall.ExitCode -eq 0) {
        Assert-RolloutAbsent $presetCoreFixture 'core install'
        $presetCoreManifest = Get-LatestManifest $presetCoreFixture
        Assert-ProtocolConfigPreserved $presetCoreFixture $presetCoreProtocolConfig $presetCoreManifest 'core install'
        $presetCoreRolloutSentinel = Join-Path $presetCoreFixture.Workspace '.assistant\runtime\rollout\v2-eligibility.json'
        if (Test-ManifestExcludesPath $presetCoreManifest $presetCoreRolloutSentinel) { Add-Check 'core install does not claim an absent canonical rollout report' } else { Add-Failure 'core install claimed an absent canonical rollout report' }
        $presetCoreRolloutBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"installer_owned":false,"arrival":"after-core-install"}')
        New-Item -ItemType Directory -Path (Split-Path -Parent $presetCoreRolloutSentinel) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($presetCoreRolloutSentinel,$presetCoreRolloutBytes)
        $presetCoreUpdate = Invoke-Install -Fixture $presetCoreFixture -ExtraArguments @('-Preset','core')
        Assert-InstallExit $presetCoreUpdate 'explicit core update without rollout report'
        if ($presetCoreUpdate.ExitCode -eq 0) {
            $presetCoreUpdateManifest = Get-LatestManifest $presetCoreFixture
            Assert-ProtocolConfigPreserved $presetCoreFixture $presetCoreProtocolConfig $presetCoreUpdateManifest 'core update'
            if (([System.IO.File]::ReadAllBytes($presetCoreRolloutSentinel) -join ',') -ceq ($presetCoreRolloutBytes -join ',') -and (Test-ManifestExcludesPath $presetCoreUpdateManifest $presetCoreRolloutSentinel)) { Add-Check 'core update preserves and does not claim a rollout report created after install' } else { Add-Failure 'core update changed or claimed a rollout report created after install' }
        }
        Assert-UninstallExit (Invoke-Uninstall $presetCoreFixture) 'explicit core without rollout report'
        Assert-ProtocolConfigPreserved $presetCoreFixture $presetCoreProtocolConfig $null 'core uninstall'
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
    $fullProtocolConfig = New-ProtocolConfigSentinel -Fixture $fullFixture
    $fullRolloutSentinel=Join-Path $fullFixture.Workspace '.assistant\runtime\rollout\v2-eligibility.json';New-Item -ItemType Directory -Path (Split-Path -Parent $fullRolloutSentinel) -Force|Out-Null;$fullRolloutBytes=[System.Text.UTF8Encoding]::new($false).GetBytes('{"installer_owned":false,"preset":"full"}');[System.IO.File]::WriteAllBytes($fullRolloutSentinel,$fullRolloutBytes)
    $fullInstall = Invoke-Install -Fixture $fullFixture -ExtraArguments @('-VaultProfile','full')
    Assert-InstallExit $fullInstall 'legacy full'
    if ($fullInstall.ExitCode -eq 0) {
        $fullInstallManifest=Get-LatestManifest $fullFixture
        Assert-ManifestPreset $fullInstallManifest 'full' 'vault-profile:full' $fullFeatures $fullSkills $fullHooks 'full'
        Assert-InstalledTaskShim $fullFixture $fullInstallManifest 'full install'
        Assert-InstalledTaskProtocol $fullFixture 'full install'
        Assert-ProtocolConfigPreserved $fullFixture $fullProtocolConfig $fullInstallManifest 'full install'
        if ($fullInstall.Output -match 'VaultProfile is deprecated') { Add-Check 'legacy full emits migration warning' } else { Add-Failure 'legacy full did not emit migration warning' }
        if (([System.IO.File]::ReadAllBytes($fullRolloutSentinel)-join',') -ceq ($fullRolloutBytes-join',') -and (Test-ManifestExcludesPath $fullInstallManifest $fullRolloutSentinel)) { Add-Check 'full fresh install preserves and does not claim the canonical rollout report' } else { Add-Failure 'full fresh install changed or claimed the canonical rollout report' }
        $preserveInstall = Invoke-Install -Fixture $fullFixture
        Assert-InstallExit $preserveInstall 'implicit full preservation'
        if ($preserveInstall.ExitCode -eq 0) {
            $preserveManifest=Get-LatestManifest $fullFixture
            Assert-ManifestPreset $preserveManifest 'full' 'manifest-preserve' $fullFeatures $fullSkills $fullHooks 'full'
            Assert-InstalledTaskShim $fullFixture $preserveManifest 'full update'
            Assert-InstalledTaskProtocol $fullFixture 'full update'
            Assert-ProtocolConfigPreserved $fullFixture $fullProtocolConfig $preserveManifest 'full update'
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
            Assert-ProtocolConfigPreserved $fullFixture $fullProtocolConfig $null 'full uninstall'
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
