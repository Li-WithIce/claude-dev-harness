[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][ValidateSet('core','governed','full')][string]$Preset,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('formal','test-only','diagnostic-smoke')][string]$ProducerMode = 'formal',
    [ValidateSet('','install','verify-after-install','update','verify-after-update','uninstall','cleanup')][string]$TestFailureStage = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not [string]::IsNullOrWhiteSpace($TestFailureStage) -and $ProducerMode -cne 'test-only') { throw 'TestFailureStage requires ProducerMode test-only' }

$rolloutModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
$atomicModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Force -PassThru -ErrorAction Stop
$powerShellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
$installScript = Join-Path $RepoRoot 'install.ps1'
$verifyScript = Join-Path $RepoRoot 'tests\verify-installation.ps1'
$uninstallScript = Join-Path $RepoRoot 'uninstall.ps1'
$producerScript = [IO.Path]::GetFullPath($PSCommandPath)
$atomicScript = Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1'
$pathScript = Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1'
$schemaPath = Join-Path $RepoRoot 'schemas\preset-lifecycle-report.schema.json'
$inputFiles = @($installScript,$uninstallScript,$verifyScript,$producerScript,$atomicScript,$pathScript,$schemaPath)
foreach ($path in $inputFiles) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required preset lifecycle input is missing: $path" } }
if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is required for preset lifecycle qualification' }
$mainUserProfile = [IO.Path]::GetFullPath($env:USERPROFILE)

function Get-PresetLifecycleBytesDigest {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-PresetLifecycleTextDigest {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-PresetLifecycleBytesDigest -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Get-PresetLifecycleFileDigest {
    param([Parameter(Mandatory)][string]$Path)
    return Get-PresetLifecycleBytesDigest -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Get-PresetLifecycleSnapshot {
    param([Parameter(Mandatory)][string[]]$Paths)
    $snapshot = [ordered]@{}
    foreach ($path in @($Paths | Sort-Object -Unique)) {
        $full = [IO.Path]::GetFullPath($path)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $info = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            $snapshot[$full] = [ordered]@{status='present';length=[long]$info.Length;digest=(Get-PresetLifecycleFileDigest -Path $full)}
        } elseif (Test-Path -LiteralPath $full) {
            $snapshot[$full] = [ordered]@{status='non-file';length=$null;digest=$null}
        } else {
            $snapshot[$full] = [ordered]@{status='missing';length=$null;digest=$null}
        }
    }
    return $snapshot
}

function Test-PresetLifecycleSnapshotEqual {
    param([Parameter(Mandatory)][Collections.IDictionary]$Left,[Parameter(Mandatory)][Collections.IDictionary]$Right)
    if (@(Compare-Object @($Left.Keys | Sort-Object) @($Right.Keys | Sort-Object)).Count -ne 0) { return $false }
    foreach ($path in $Left.Keys) {
        foreach ($name in @('status','length','digest')) { if ([string]$Left[$path][$name] -cne [string]$Right[$path][$name]) { return $false } }
    }
    return $true
}

function New-PresetLifecycleStageRecord {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [AllowNull()][object]$ExitCode,
        [Parameter(Mandatory)][DateTimeOffset]$Started,
        [Parameter(Mandatory)][DateTimeOffset]$Ended,
        [Parameter(Mandatory)][string]$CommandIdentity,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$OutputBytes,
        [Parameter(Mandatory)][string]$Reason
    )
    $duration = [long][Math]::Round(($Ended - $Started).TotalMilliseconds,0,[MidpointRounding]::AwayFromZero)
    return [ordered]@{
        stage=$Name
        status=$Status
        exit_code=$ExitCode
        started_at_utc=$Started.ToUniversalTime().ToString('o')
        ended_at_utc=$Ended.ToUniversalTime().ToString('o')
        duration_ms=$duration
        command_digest=(Get-PresetLifecycleTextDigest -Text $CommandIdentity)
        output_digest=(Get-PresetLifecycleBytesDigest -Bytes $OutputBytes)
        reason=$Reason
    }
}

function New-PresetLifecycleNotRunStage {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$CommandIdentity)
    $now = [DateTimeOffset]::UtcNow
    return New-PresetLifecycleStageRecord -Name $Name -Status 'not_run' -ExitCode $null -Started $now -Ended $now -CommandIdentity $CommandIdentity -OutputBytes ([byte[]]@()) -Reason 'blocked-by-prior-stage'
}

function Invoke-PresetLifecycleStage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CommandIdentity,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$UserProfileRoot
    )
    $started = [DateTimeOffset]::UtcNow
    if (-not [string]::IsNullOrWhiteSpace($TestFailureStage)) {
        $exitCode = if ($Name -ceq $TestFailureStage) { 86 } else { 0 }
        $ended = [DateTimeOffset]::UtcNow
        return New-PresetLifecycleStageRecord -Name $Name -Status $(if($exitCode-eq0){'pass'}else{'fail'}) -ExitCode ([long]$exitCode) -Started $started -Ended $ended -CommandIdentity ("test-only-stage-simulation/v1|$CommandIdentity") -OutputBytes ([byte[]]@()) -Reason $(if($exitCode-eq0){'stage-pass'}else{'stage-exit-nonzero'})
    }

    $stdout = [IO.MemoryStream]::new()
    $stderr = [IO.MemoryStream]::new()
    $process = [Diagnostics.Process]::new()
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powerShellPath
        $startInfo.WorkingDirectory = $RepoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Environment['USERPROFILE'] = $UserProfileRoot
        foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'preset lifecycle child process did not start' }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $process.WaitForExit()
        [Threading.Tasks.Task]::WaitAll(@($stdoutTask,$stderrTask))
        $exitCode = [long]$process.ExitCode
        $combined = [IO.MemoryStream]::new()
        try {
            $stdoutBytes = $stdout.ToArray(); $stderrBytes = $stderr.ToArray()
            $combined.Write($stdoutBytes,0,$stdoutBytes.Length); $combined.WriteByte(0); $combined.Write($stderrBytes,0,$stderrBytes.Length)
            $outputBytes = $combined.ToArray()
        } finally { $combined.Dispose() }
        $ended = [DateTimeOffset]::UtcNow
        return New-PresetLifecycleStageRecord -Name $Name -Status $(if($exitCode-eq0){'pass'}else{'fail'}) -ExitCode $exitCode -Started $started -Ended $ended -CommandIdentity $CommandIdentity -OutputBytes $outputBytes -Reason $(if($exitCode-eq0){'stage-pass'}else{'stage-exit-nonzero'})
    } catch {
        $ended = [DateTimeOffset]::UtcNow
        $errorBytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$_.Exception.Message)
        return New-PresetLifecycleStageRecord -Name $Name -Status 'fail' -ExitCode ([long]70) -Started $started -Ended $ended -CommandIdentity $CommandIdentity -OutputBytes $errorBytes -Reason 'stage-internal-failure'
    } finally {
        $process.Dispose(); $stdout.Dispose(); $stderr.Dispose()
    }
}

function Get-PresetLifecycleInstalledPreset {
    param([Parameter(Mandatory)][string]$UserProfileRoot,[Parameter(Mandatory)][string]$WorkspaceRoot)
    try {
        $registryPath = Join-Path $UserProfileRoot '.dev-harness\install-registry.json'
        if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { return $null }
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -ErrorAction Stop
        $workspaceFull = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
        $matches = @($registry.workspaces.Values | Where-Object { [IO.Path]::GetFullPath([string]$_.workspace_root).TrimEnd('\').Equals($workspaceFull,[StringComparison]::OrdinalIgnoreCase) })
        if ($matches.Count -ne 1 -or @($matches[0].manifests).Count -eq 0) { return $null }
        $manifestPath = [string]@($matches[0].manifests)[-1]
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -ErrorAction Stop
        return [string]$manifest.effective_preset
    } catch { return $null }
}

$authPaths = [Collections.Generic.List[string]]::new()
$configPaths = [Collections.Generic.List[string]]::new()
$protectedRoots = [Collections.Generic.List[string]]::new()
foreach ($root in @((Join-Path $mainUserProfile '.codex'),(Join-Path $mainUserProfile '.claude'),(Join-Path $mainUserProfile '.agents'),(Join-Path $mainUserProfile '.dev-harness'))) { $protectedRoots.Add([IO.Path]::GetFullPath($root)) }
$codexRoots = [Collections.Generic.List[string]]::new()
$codexRoots.Add([IO.Path]::GetFullPath((Join-Path $mainUserProfile '.codex')))
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    $customCodexRoot = [IO.Path]::GetFullPath($env:CODEX_HOME)
    if ($customCodexRoot -notin $codexRoots) { $codexRoots.Add($customCodexRoot); $protectedRoots.Add($customCodexRoot) }
}
foreach ($root in $codexRoots) {
    $authPaths.Add((Join-Path $root 'auth.json'))
    foreach ($name in @('hooks.json','config.toml','managed_config.toml')) { $configPaths.Add((Join-Path $root $name)) }
}
$configPaths.Add((Join-Path $mainUserProfile '.claude\settings.json'))
$configPaths.Add((Join-Path $mainUserProfile '.dev-harness\install-registry.json'))
$authBefore = Get-PresetLifecycleSnapshot -Paths @($authPaths)
$configBefore = Get-PresetLifecycleSnapshot -Paths @($configPaths)

$targetPath = & $rolloutModule {
    param($Root,$Requested,$Inputs,$Protected)
    Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Requested -EvidencePaths $Inputs -ProtectedRoots $Protected
} $RepoRoot $OutputPath $inputFiles @($protectedRoots)
$pathRoot = [IO.Path]::GetPathRoot($targetPath)
if ($targetPath.Substring($pathRoot.Length).Contains(':')) { throw 'preset lifecycle output alternate stream is rejected' }

$reportRunId = [guid]::NewGuid().ToString('N')
$scratchParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$scratchRoot = Join-Path $scratchParent ("dev-harness-preset-lifecycle-$reportRunId")
if (([IO.Path]::GetFullPath($targetPath)).StartsWith(([IO.Path]::GetFullPath($scratchRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'preset lifecycle output overlaps the isolated execution root' }
$workspaceRoot = Join-Path $scratchRoot 'workspace'
$profileRoot = Join-Path $scratchRoot 'profile'
$workspaceIdentityDigest = Get-PresetLifecycleTextDigest -Text ("preset-lifecycle-workspace/v1|$reportRunId|$Preset|$workspaceRoot")
$profileIdentityDigest = Get-PresetLifecycleTextDigest -Text ("preset-lifecycle-profile/v1|$reportRunId|$Preset|$profileRoot")
$sourceStart = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
$lifecycleStarted = [DateTimeOffset]::UtcNow
$stageRecords = [ordered]@{}
$presetObservations = [Collections.Generic.List[string]]::new()
$installAttempted = $false

try {
    $installAttempted = $true
    [void][IO.Directory]::CreateDirectory($workspaceRoot)
    [void][IO.Directory]::CreateDirectory($profileRoot)
    $stageRecords.install = Invoke-PresetLifecycleStage -Name 'install' -CommandIdentity ("install.ps1|isolated-workspace|source-repo|preset:$Preset") -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$installScript,'-WorkspaceRoot',$workspaceRoot,'-RepoRoot',$RepoRoot,'-Preset',$Preset) -UserProfileRoot $profileRoot
    if ([string]$stageRecords.install.status -ceq 'pass') {
        $installedPreset = Get-PresetLifecycleInstalledPreset -UserProfileRoot $profileRoot -WorkspaceRoot $workspaceRoot
        if (-not [string]::IsNullOrWhiteSpace($installedPreset)) { $presetObservations.Add($installedPreset) }
        $stageRecords['verify-after-install'] = Invoke-PresetLifecycleStage -Name 'verify-after-install' -CommandIdentity 'tests/verify-installation.ps1|isolated-workspace|source-repo|isolated-profile|scope:All' -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$verifyScript,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspaceRoot,'-UserProfileRoot',$profileRoot,'-Scope','All') -UserProfileRoot $profileRoot
    } else { $stageRecords['verify-after-install'] = New-PresetLifecycleNotRunStage -Name 'verify-after-install' -CommandIdentity 'tests/verify-installation.ps1|isolated-workspace|source-repo|isolated-profile|scope:All' }

    if ([string]$stageRecords['verify-after-install'].status -ceq 'pass') {
        $stageRecords.update = Invoke-PresetLifecycleStage -Name 'update' -CommandIdentity ("install.ps1|existing-isolated-workspace|source-repo|preset:$Preset|mode:update") -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$installScript,'-WorkspaceRoot',$workspaceRoot,'-RepoRoot',$RepoRoot,'-Preset',$Preset) -UserProfileRoot $profileRoot
    } else { $stageRecords.update = New-PresetLifecycleNotRunStage -Name 'update' -CommandIdentity ("install.ps1|existing-isolated-workspace|source-repo|preset:$Preset|mode:update") }

    if ([string]$stageRecords.update.status -ceq 'pass') {
        $updatedPreset = Get-PresetLifecycleInstalledPreset -UserProfileRoot $profileRoot -WorkspaceRoot $workspaceRoot
        if (-not [string]::IsNullOrWhiteSpace($updatedPreset)) { $presetObservations.Add($updatedPreset) }
        $stageRecords['verify-after-update'] = Invoke-PresetLifecycleStage -Name 'verify-after-update' -CommandIdentity 'tests/verify-installation.ps1|existing-isolated-workspace|source-repo|isolated-profile|scope:All' -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$verifyScript,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspaceRoot,'-UserProfileRoot',$profileRoot,'-Scope','All') -UserProfileRoot $profileRoot
    } else { $stageRecords['verify-after-update'] = New-PresetLifecycleNotRunStage -Name 'verify-after-update' -CommandIdentity 'tests/verify-installation.ps1|existing-isolated-workspace|source-repo|isolated-profile|scope:All' }
} catch {
    $errorBytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$_.Exception.Message)
    $priorFailure = @($stageRecords.Values | Where-Object { [string]$_.status -ceq 'fail' }).Count -gt 0
    foreach ($name in @('install','verify-after-install','update','verify-after-update')) {
        if ($stageRecords.Contains($name)) { continue }
        if (-not $priorFailure) {
            $now = [DateTimeOffset]::UtcNow
            $stageRecords[$name] = New-PresetLifecycleStageRecord -Name $name -Status 'fail' -ExitCode 70L -Started $now -Ended $now -CommandIdentity ("internal-stage:$name") -OutputBytes $errorBytes -Reason 'stage-internal-failure'
            $priorFailure = $true
        } else { $stageRecords[$name] = New-PresetLifecycleNotRunStage -Name $name -CommandIdentity ("internal-stage:$name") }
    }
} finally {
    if ($installAttempted) {
        $stageRecords.uninstall = Invoke-PresetLifecycleStage -Name 'uninstall' -CommandIdentity 'uninstall.ps1|isolated-workspace|source-repo' -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$uninstallScript,'-WorkspaceRoot',$workspaceRoot,'-RepoRoot',$RepoRoot) -UserProfileRoot $profileRoot
    } else { $stageRecords.uninstall = New-PresetLifecycleNotRunStage -Name 'uninstall' -CommandIdentity 'uninstall.ps1|isolated-workspace|source-repo' }

    $cleanupStarted = [DateTimeOffset]::UtcNow
    $cleanupExit = 0L
    $cleanupReason = 'stage-pass'
    $cleanupOutput = [byte[]]@()
    try {
        $resolvedScratch = [IO.Path]::GetFullPath($scratchRoot)
        if (-not $resolvedScratch.StartsWith($scratchParent+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedScratch) -cne ("dev-harness-preset-lifecycle-$reportRunId")) { throw 'preset lifecycle cleanup target is invalid' }
        if ([IO.Directory]::Exists($resolvedScratch)) { [IO.Directory]::Delete($resolvedScratch,$true) }
        if ($TestFailureStage -ceq 'cleanup') { $cleanupExit = 86; $cleanupReason = 'stage-exit-nonzero' }
    } catch {
        $cleanupExit = 71
        $cleanupReason = 'cleanup-internal-failure'
        $cleanupOutput = [Text.UTF8Encoding]::new($false).GetBytes([string]$_.Exception.Message)
    }
    $cleanupEnded = [DateTimeOffset]::UtcNow
    $stageRecords.cleanup = New-PresetLifecycleStageRecord -Name 'cleanup' -Status $(if($cleanupExit-eq0){'pass'}else{'fail'}) -ExitCode $cleanupExit -Started $cleanupStarted -Ended $cleanupEnded -CommandIdentity 'cleanup|isolated-lifecycle-root' -OutputBytes $cleanupOutput -Reason $cleanupReason
}

$lifecycleEnded = [DateTimeOffset]::UtcNow
$sourceEnd = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
$authAfter = Get-PresetLifecycleSnapshot -Paths @($authPaths)
$configAfter = Get-PresetLifecycleSnapshot -Paths @($configPaths)
$stages = @('install','verify-after-install','update','verify-after-update','uninstall','cleanup' | ForEach-Object { $stageRecords[$_] })
$allStagesPassed = @($stages | Where-Object { [string]$_.status -cne 'pass' }).Count -eq 0
$presetConsistent = $presetObservations.Count -eq 2 -and @($presetObservations | Where-Object { $_ -cne $Preset }).Count -eq 0
$authUnchanged = Test-PresetLifecycleSnapshotEqual -Left $authBefore -Right $authAfter
$configUnchanged = Test-PresetLifecycleSnapshotEqual -Left $configBefore -Right $configAfter
$cleanupNoResidue = -not (Test-Path -LiteralPath $scratchRoot)
$results = [ordered]@{
    all_required_stages_passed=$allStagesPassed
    preset_consistent=$presetConsistent
    auth_unchanged=$authUnchanged
    unrelated_user_config_unchanged=$configUnchanged
    cleanup_no_residue=$cleanupNoResidue
    installation_verified=([string]$stageRecords['verify-after-install'].status -ceq 'pass')
    update_verified=([string]$stageRecords['verify-after-update'].status -ceq 'pass')
}
$allResultsPassed = @($results.Keys | Where-Object { -not [bool]$results[$_] }).Count -eq 0
$sourceStable = Test-HarnessReleaseSourceStable -Start $sourceStart -End $sourceEnd
$sourceDirty = [bool]$sourceStart.dirty -or [bool]$sourceEnd.dirty
$sourceUnchanged = [string]$sourceStart.revision -ceq [string]$sourceEnd.revision -and [string]$sourceStart.commit_tree_oid -ceq [string]$sourceEnd.commit_tree_oid -and [string]$sourceStart.object_format -ceq [string]$sourceEnd.object_format -and [string]$sourceStart.state_digest -ceq [string]$sourceEnd.state_digest
$operationalPass = $allStagesPassed -and $allResultsPassed -and $sourceUnchanged
$status = if (-not $operationalPass) { 'fail' } elseif ($ProducerMode -cne 'formal') { 'unavailable' } elseif (-not $sourceDirty -and $sourceStable) { 'pass' } else { 'fail' }
$reason = if ($status -ceq 'pass') { 'all-required-stages-passed' } elseif ($status -ceq 'unavailable') { 'non-formal-producer-mode' } else { 'lifecycle-stage-or-result-failure' }
$durationMs = [long][Math]::Max(1,[Math]::Round(($lifecycleEnded - $lifecycleStarted).TotalMilliseconds,0,[MidpointRounding]::AwayFromZero))
$inputDigests = [ordered]@{
    install_digest=Get-PresetLifecycleFileDigest -Path $installScript
    uninstall_digest=Get-PresetLifecycleFileDigest -Path $uninstallScript
    verification_digest=Get-PresetLifecycleFileDigest -Path $verifyScript
    producer_digest=Get-PresetLifecycleFileDigest -Path $producerScript
    atomic_write_digest=Get-PresetLifecycleFileDigest -Path $atomicScript
    path_digest=Get-PresetLifecycleFileDigest -Path $pathScript
}
$report = [ordered]@{
    schema_version='harness-preset-lifecycle-report/v1'
    generated_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
    source_revision=[string]$sourceStart.revision
    source_dirty=$sourceDirty
    source_state_stable=$sourceStable
    source=[ordered]@{commit_tree_oid=[string]$sourceStart.commit_tree_oid;object_format=[string]$sourceStart.object_format;start=$sourceStart;end=$sourceEnd;input_digests=$inputDigests}
    preset=$Preset
    report_run_id=$reportRunId
    producer_identity='preset-lifecycle-qualification/v1'
    producer_mode=$ProducerMode
    execution=[ordered]@{
        sequence_contract='install-verify-update-verify-uninstall-cleanup/v1'
        effective_preset=$Preset
        isolated_workspace=$true
        isolated_profile=$true
        workspace_identity_digest=$workspaceIdentityDigest
        profile_identity_digest=$profileIdentityDigest
        duration_ms=$durationMs
        raw_output_persisted=$false
        auth_bytes_persisted=$false
        private_paths_persisted=$false
    }
    stages=$stages
    results=$results
    status=$status
    reason=$reason
    report_digest=$null
}
$report.report_digest = Get-PresetLifecycleTextDigest -Text ($report | ConvertTo-Json -Depth 100 -Compress)
$json = $report | ConvertTo-Json -Depth 100 -Compress
$expectedBytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
$validated = & $rolloutModule { param($Bytes) ConvertFrom-PresetLifecycleEvidenceBytes -Bytes $Bytes } $expectedBytes
[void](& $rolloutModule { param($Root,$Document,$ExpectedPreset,$AllowNonFormal) Assert-PresetLifecycleReport -RepoRoot $Root -Document $Document -ExpectedPreset $ExpectedPreset -AllowNonFormalSource:$AllowNonFormal } $RepoRoot $validated $Preset ($ProducerMode -cne 'formal'))
$writeRoot = [IO.Path]::GetDirectoryName($targetPath)
while (-not (Test-Path -LiteralPath $writeRoot -PathType Container)) {
    $parent = [IO.Path]::GetDirectoryName($writeRoot)
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $writeRoot) { throw 'preset lifecycle output parent is unavailable' }
    $writeRoot = $parent
}
$writtenDigest = Write-HarnessAtomicText -WorkspaceRoot $writeRoot -Path $targetPath -Content $json
if ([string]$writtenDigest -cne (Get-PresetLifecycleBytesDigest -Bytes $expectedBytes)) { throw 'preset lifecycle atomic write digest mismatch' }
[void](& $rolloutModule { param($Path) Assert-ReleaseSingleLinkFile -Path $Path -Label 'preset-lifecycle-output'; Assert-ReleaseSingleDataStreamFile -Path $Path -Label 'preset-lifecycle-output' } $targetPath)
$actualBytes = [IO.File]::ReadAllBytes($targetPath)
if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($expectedBytes,$actualBytes)) { throw 'preset lifecycle output bytes changed after write' }
$reopened = & $rolloutModule { param($Bytes) ConvertFrom-PresetLifecycleEvidenceBytes -Bytes $Bytes } $actualBytes
[void](& $rolloutModule { param($Root,$Document,$ExpectedPreset,$AllowNonFormal) Assert-PresetLifecycleReport -RepoRoot $Root -Document $Document -ExpectedPreset $ExpectedPreset -AllowNonFormalSource:$AllowNonFormal } $RepoRoot $reopened $Preset ($ProducerMode -cne 'formal'))

Write-Output 'Preset lifecycle qualification summary:'
Write-Output ("- preset: {0}" -f $Preset)
Write-Output ("- producer_mode: {0}" -f $ProducerMode)
foreach ($stage in $stages) { Write-Output ("- {0}: {1}" -f $stage.stage,$stage.status) }
Write-Output ("- status: {0}" -f $status)
Write-Output ("- report_digest: {0}" -f $report.report_digest)
if ($status -ceq 'fail') { exit 1 }
exit 0
