[CmdletBinding()]
param([string]$RepoRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$failures = [Collections.Generic.List[string]]::new()
$checks = 0
$script:hostBenchmarkTemplateRoot = ''
$script:hostBenchmarkCognitiveHome = ''
function Check([bool]$Condition,[string]$Message) {
    if ($Condition) { $script:checks++ } else { $script:failures.Add($Message) }
}
function Invoke-Git {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' | ')" }
    return $output
}
function Invoke-HostGit {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    return @(Invoke-Git -Root $Root -Arguments $Arguments)
}
function Write-Utf8 {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Get-DirectoryContentDigest {
    param([Parameter(Mandatory)][string]$Root)
    $lines = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relative`:$hash"
    })
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n"))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Initialize-GitFixture {
    param([Parameter(Mandatory)][string]$Root)
    [void][IO.Directory]::CreateDirectory($Root)
    [void](Invoke-Git $Root @('init','--quiet'))
}
function Commit-GitFixture {
    param([Parameter(Mandatory)][string]$Root)
    [void](Invoke-Git $Root @('add','--all'))
    [void](Invoke-Git $Root @('-c','user.name=Harness Test','-c','user.email=harness@example.invalid','commit','--quiet','--no-gpg-sign','-m','fixture'))
}
function Invoke-FixtureRunner {
    param(
        [string]$Fixture,
        [string]$OutputRoot,
        [string]$Mode,
        [int]$Trials,
        [int]$Groups = 1,
        [string]$BenchmarkPath = 'cognitive-fast-path',
        [string]$CodexHome = '',
        [string]$EligibilityReportPath = ''
    )
    $outputPath = Join-Path $OutputRoot ("report-$Mode-$Groups-$Trials.json")
    $logPath = Join-Path $OutputRoot ("order-$Mode-$Groups-$Trials.txt")
    $oldMode = $env:HOST_BENCHMARK_TEST_MODE
    $oldLog = $env:HOST_BENCHMARK_TEST_LOG
    $oldTemplate = $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT
    $oldExpectedCodexHome = $env:HOST_BENCHMARK_TEST_EXPECTED_CODEX_HOME
    try {
        if ([string]::IsNullOrWhiteSpace($script:hostBenchmarkTemplateRoot)) { throw 'host benchmark fixture templates are not initialized' }
        if ($BenchmarkPath -ceq 'cognitive-fast-path' -and [string]::IsNullOrWhiteSpace($CodexHome)) { $CodexHome = $script:hostBenchmarkCognitiveHome }
        $env:HOST_BENCHMARK_TEST_MODE = $Mode
        $env:HOST_BENCHMARK_TEST_LOG = $logPath
        $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT = $script:hostBenchmarkTemplateRoot
        if ($BenchmarkPath -ceq 'cognitive-fast-path') { $env:HOST_BENCHMARK_TEST_EXPECTED_CODEX_HOME = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\') } else { Remove-Item Env:HOST_BENCHMARK_TEST_EXPECTED_CODEX_HOME -ErrorAction Ignore }
        $runnerArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $Fixture 'scripts\run-host-benchmark.ps1'),'-RepoRoot',$Fixture,'-OutputPath',$outputPath,'-Groups',$Groups,'-Trials',$Trials,'-MaxRoundTrips',1,'-TimeoutSeconds',30,'-BenchmarkPath',$BenchmarkPath)
        if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $runnerArguments += @('-CodexHome',$CodexHome) }
        if ($BenchmarkPath -ceq 'installed-desktop-path') { $runnerArguments += @('-EligibilityReportPath',$EligibilityReportPath) }
        $lines = @(& pwsh @runnerArguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $oldMode) { Remove-Item Env:HOST_BENCHMARK_TEST_MODE -ErrorAction Ignore } else { $env:HOST_BENCHMARK_TEST_MODE = $oldMode }
        if ($null -eq $oldLog) { Remove-Item Env:HOST_BENCHMARK_TEST_LOG -ErrorAction Ignore } else { $env:HOST_BENCHMARK_TEST_LOG = $oldLog }
        if ($null -eq $oldTemplate) { Remove-Item Env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT -ErrorAction Ignore } else { $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT = $oldTemplate }
        if ($null -eq $oldExpectedCodexHome) { Remove-Item Env:HOST_BENCHMARK_TEST_EXPECTED_CODEX_HOME -ErrorAction Ignore } else { $env:HOST_BENCHMARK_TEST_EXPECTED_CODEX_HOME = $oldExpectedCodexHome }
    }
    $report = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { [IO.File]::ReadAllText($outputPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -Depth 80 } else { $null }
    $order = if (Test-Path -LiteralPath $logPath -PathType Leaf) { @([IO.File]::ReadAllLines($logPath,[Text.UTF8Encoding]::new($false,$true))) } else { @() }
    return [pscustomobject]@{ExitCode=$exitCode;Output=$lines;Report=$report;Order=$order}
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('hbq-' + [guid]::NewGuid().ToString('N').Substring(0,8))
try {
    [void][IO.Directory]::CreateDirectory($scratch)
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -ErrorAction Stop
    . (Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1')
    . (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1')

    Check ((Resolve-HostTrialStatus -Protocol v2 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 1 -HostTurns 0 -ObservationComplete $false -WorkflowCompleted $true -DirectContractPassed $false -V1ContractPassed $true -Complete $false) -ceq 'unavailable') 'Direct wrapper failure was misclassified as a known contract failure'
    Check ((Resolve-HostTrialStatus -Protocol v1 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 1 -HostTurns 0 -ObservationComplete $false -WorkflowCompleted $false -DirectContractPassed $true -V1ContractPassed $false -Complete $false) -ceq 'unavailable') 'v1 wrapper failure was misclassified as a known contract failure'
    Check ((Resolve-HostTrialStatus -Protocol v2 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 2 -HostTurns 1 -ObservationComplete $false -WorkflowCompleted $true -DirectContractPassed $false -V1ContractPassed $true -Complete $false) -ceq 'fail') 'observed Direct session overrun was hidden by unavailable execution'
    Check ((Resolve-HostTrialStatus -Protocol v1 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 5 -HostTurns 5 -ObservationComplete $true -WorkflowCompleted $true -DirectContractPassed $true -V1ContractPassed $false -Complete $false) -ceq 'fail') 'completed invalid v1 workflow was hidden by unavailable measurement'
    Check ((Resolve-HostTrialStatus -Protocol v1 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 6 -HostTurns 5 -ObservationComplete $false -WorkflowCompleted $false -DirectContractPassed $true -V1ContractPassed $false -Complete $false) -ceq 'fail') 'partial v1 session overrun was hidden by unavailable execution'
    Check ((Resolve-HostTrialStatus -Protocol v1 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 5 -HostTurns 6 -ObservationComplete $false -WorkflowCompleted $false -DirectContractPassed $true -V1ContractPassed $false -Complete $false) -ceq 'fail') 'partial v1 turn overrun was hidden by unavailable execution'

    $authHome = Join-Path $scratch 'dedicated-auth-home'
    Write-Utf8 (Join-Path $authHome 'auth.json') '{}'
    [void][IO.Directory]::CreateDirectory((Join-Path $authHome 'cache'))
    Check ((Assert-HostCodexHomeLayout -Path $authHome) -ceq (Resolve-Path -LiteralPath $authHome).Path) 'minimal dedicated auth-home layout was rejected'
    $nativeSystemRoot = Join-Path $authHome 'skills\.system'
    Write-Utf8 (Join-Path $nativeSystemRoot '.codex-system-skills.marker') "406e58b4e35d949e`n"
    foreach ($name in @('imagegen','openai-docs','plugin-creator','skill-creator','skill-installer')) { Write-Utf8 (Join-Path $nativeSystemRoot "$name\SKILL.md") 'fixture' }
    $nativeSystemRejectedWithoutOptIn = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome } catch { $nativeSystemRejectedWithoutOptIn = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $nativeSystemRejectedWithoutOptIn 'minimal dedicated auth-home accepted native system skills without an explicit opt-in'
    Check ((Assert-HostCodexHomeLayout -Path $authHome -AllowNativeSystemSkills) -ceq (Resolve-Path -LiteralPath $authHome).Path) 'strict native system skills layout was rejected with an explicit opt-in'
    Remove-Item -LiteralPath (Join-Path $nativeSystemRoot 'imagegen') -Recurse -Force
    Write-Utf8 (Join-Path $nativeSystemRoot 'rogue\SKILL.md') 'fixture'
    $rogueNativeSystemEntryRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome -AllowNativeSystemSkills } catch { $rogueNativeSystemEntryRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $rogueNativeSystemEntryRejected 'unknown native system skill entry was accepted'
    Remove-Item -LiteralPath (Join-Path $nativeSystemRoot 'rogue') -Recurse -Force
    Write-Utf8 (Join-Path $nativeSystemRoot 'imagegen\SKILL.md') 'fixture'
    Remove-Item -LiteralPath (Join-Path $nativeSystemRoot 'imagegen\SKILL.md') -Force
    $missingNativeSkillContractRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome -AllowNativeSystemSkills } catch { $missingNativeSkillContractRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $missingNativeSkillContractRejected 'native system skill without SKILL.md was accepted'
    Write-Utf8 (Join-Path $nativeSystemRoot 'imagegen\SKILL.md') 'fixture'
    Write-Utf8 (Join-Path $nativeSystemRoot '.codex-system-skills.marker') "invalid`n"
    $invalidNativeSystemMarkerRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome -AllowNativeSystemSkills } catch { $invalidNativeSystemMarkerRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $invalidNativeSystemMarkerRejected 'invalid native system skills marker was accepted'
    Remove-Item -LiteralPath (Join-Path $authHome 'skills') -Recurse -Force
    [void][IO.Directory]::CreateDirectory((Join-Path $authHome 'skills'))
    $emptyNativeSkillsRootRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome -AllowNativeSystemSkills } catch { $emptyNativeSkillsRootRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $emptyNativeSkillsRootRejected 'empty native skills root was accepted'
    Remove-Item -LiteralPath (Join-Path $authHome 'skills') -Recurse -Force
    Write-Utf8 (Join-Path $authHome 'unexpected.txt') 'x'
    $extraRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome } catch { $extraRejected = $_.Exception.Message -like 'host-benchmark-auth-home-*' }
    Check $extraRejected 'unexpected dedicated auth-home file was accepted'
    Remove-Item -LiteralPath (Join-Path $authHome 'unexpected.txt') -Force

    $sentinelHome = Join-Path $scratch 'isolated-config-sentinel-home'
    Write-Utf8 (Join-Path $sentinelHome 'auth.json') '{}'
    $sentinelPath = Join-Path $sentinelHome 'config.toml'
    $createdSentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    $sentinelItem = Get-Item -LiteralPath $sentinelPath -Force
    Check ([bool]$createdSentinel.created_by_runner -and (Test-Path -LiteralPath $createdSentinel.owner_path -PathType Container) -and @(Get-ChildItem -LiteralPath $createdSentinel.owner_path -Force).Count -eq 0 -and ($sentinelItem.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0 -and (Test-HostExactUtf8File -Path $sentinelPath -ExpectedText "# isolated host benchmark sentinel`n")) 'runner sentinel initialization did not create the exact read-only file and empty persistent owner marker'
    Check (@(Get-ChildItem -LiteralPath $sentinelHome -Force | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigStagingPrefix,[StringComparison]::Ordinal) }).Count -eq 0) 'runner sentinel initialization retained its staging journal'
    $sentinelRejectedWithoutOptIn = $false
    try { $null = Assert-HostCodexHomeLayout -Path $sentinelHome } catch { $sentinelRejectedWithoutOptIn = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $sentinelRejectedWithoutOptIn 'default auth-home layout accepted the isolated Host config sentinel'
    $sentinelRejectedForModelLayout = $false
    try { $null = Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills } catch { $sentinelRejectedForModelLayout = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $sentinelRejectedForModelLayout 'native-system-only model layout accepted the Host config sentinel'
    Check ((Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills -AllowIsolatedHostConfig) -ceq (Resolve-Path -LiteralPath $sentinelHome).Path) 'exact read-only Host config sentinel was rejected with its narrow opt-in'
    $null = Complete-HostIsolatedConfigSentinel -State $createdSentinel
    Check (-not (Test-Path -LiteralPath $sentinelPath) -and -not (Test-Path -LiteralPath $createdSentinel.owner_path)) 'runner-created sentinel or persistent owner marker was not removed after strict cleanup'

    Write-Utf8 $sentinelPath "# isolated host benchmark sentinel`n"
    [IO.File]::SetAttributes($sentinelPath,([IO.File]::GetAttributes($sentinelPath) -bor [IO.FileAttributes]::ReadOnly))
    $sentinelIdentity = Get-HostFileSystemIdentity -Path $sentinelPath
    $reusedSentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    $null = Complete-HostIsolatedConfigSentinel -State $reusedSentinel
    $reusedIdentity = Get-HostFileSystemIdentity -Path $sentinelPath
    $reusedItem = Get-Item -LiteralPath $sentinelPath -Force
    Check (-not [bool]$reusedSentinel.created_by_runner -and [string]$reusedIdentity.volume -ceq [string]$sentinelIdentity.volume -and [string]$reusedIdentity.file_id -ceq [string]$sentinelIdentity.file_id -and ($reusedItem.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0 -and (Test-HostExactUtf8File -Path $sentinelPath -ExpectedText "# isolated host benchmark sentinel`n")) 'preexisting exact sentinel was rewritten or removed'
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    [IO.File]::Delete($sentinelPath)

    $abandonedSentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    $abandonedRecovered = Recover-HostIsolatedConfigSentinel -Path $sentinelHome
    Check ($abandonedRecovered -and -not (Test-Path -LiteralPath $sentinelPath) -and -not (Test-Path -LiteralPath $abandonedSentinel.owner_path) -and (Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills)) 'exact abandoned sentinel and owner marker were not safely recovered'

    $ownerOnlySentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    [IO.File]::Delete($sentinelPath)
    $ownerOnlyRecovered = Recover-HostIsolatedConfigSentinel -Path $sentinelHome
    Check ($ownerOnlyRecovered -and -not (Test-Path -LiteralPath $ownerOnlySentinel.owner_path) -and (Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills)) 'owner-only crash residue was not safely recovered'

    $emptyStagingPath = Join-Path $sentinelHome ($script:HostIsolatedConfigStagingPrefix + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($emptyStagingPath)
    $emptyStagingRecovered = Recover-HostIsolatedConfigSentinel -Path $sentinelHome
    Check ($emptyStagingRecovered -and -not (Test-Path -LiteralPath $emptyStagingPath) -and (Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills)) 'empty pre-publication staging journal was not safely recovered'

    $partialStagingPath = Join-Path $sentinelHome ($script:HostIsolatedConfigStagingPrefix + [guid]::NewGuid().ToString('N'))
    Write-Utf8 (Join-Path $partialStagingPath $script:HostIsolatedConfigStagedLeaf) 'partial'
    $partialStagingRecovered = Recover-HostIsolatedConfigSentinel -Path $sentinelHome
    Check ($partialStagingRecovered -and -not (Test-Path -LiteralPath $partialStagingPath) -and (Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills)) 'partial pre-publication staging journal was not safely recovered'

    $finalStagedSentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    $finalStagedPath = Join-Path ([string]$finalStagedSentinel.owner_path) $script:HostIsolatedConfigStagedLeaf
    [IO.File]::Move($sentinelPath,$finalStagedPath,$false)
    $finalStagedRecovered = Recover-HostIsolatedConfigSentinel -Path $sentinelHome
    Check ($finalStagedRecovered -and -not (Test-Path -LiteralPath $finalStagedPath) -and -not (Test-Path -LiteralPath $finalStagedSentinel.owner_path) -and (Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills)) 'identity-bound final owner plus staged sentinel was not safely recovered'

    $writableCleanupSentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    $writableCleanupRecovered = Recover-HostIsolatedConfigSentinel -Path $sentinelHome
    Check ($writableCleanupRecovered -and -not (Test-Path -LiteralPath $sentinelPath) -and -not (Test-Path -LiteralPath $writableCleanupSentinel.owner_path) -and (Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills)) 'cleanup-in-progress writable owned sentinel was not safely recovered'

    $foreignRecoverySentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    [IO.File]::Delete($sentinelPath)
    Write-Utf8 $sentinelPath 'model = "foreign-after-crash"'
    $foreignRecoveryIdentity = Get-HostFileSystemIdentity -Path $sentinelPath
    $foreignRecoveryDigest = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
    $foreignRecoveryRejected = $false
    try { $null = Recover-HostIsolatedConfigSentinel -Path $sentinelHome } catch { $foreignRecoveryRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    $foreignRecoveryIdentityAfter = Get-HostFileSystemIdentity -Path $sentinelPath
    Check ($foreignRecoveryRejected -and [string]$foreignRecoveryIdentityAfter.volume -ceq [string]$foreignRecoveryIdentity.volume -and [string]$foreignRecoveryIdentityAfter.file_id -ceq [string]$foreignRecoveryIdentity.file_id -and (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash -ceq $foreignRecoveryDigest -and (Test-Path -LiteralPath $foreignRecoverySentinel.owner_path -PathType Container)) 'abandoned-state recovery deleted or rewrote a foreign replacement config or its owner evidence'
    [IO.File]::Delete($sentinelPath)
    [IO.Directory]::Delete([string]$foreignRecoverySentinel.owner_path,$false)

    $sameByteRecoverySentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    $recoveryReplacementSource = Join-Path $scratch 'recovery-same-byte-replacement.toml'
    Write-Utf8 $recoveryReplacementSource "# isolated host benchmark sentinel`n"
    $recoveryReplacementIdentity = Get-HostFileSystemIdentity -Path $recoveryReplacementSource
    Check ([string]$recoveryReplacementIdentity.file_id -cne [string]$sameByteRecoverySentinel.file_id) 'same-byte recovery replacement fixture did not have a distinct file identity'
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    [IO.File]::Delete($sentinelPath)
    [IO.File]::Move($recoveryReplacementSource,$sentinelPath,$false)
    [IO.File]::SetAttributes($sentinelPath,([IO.File]::GetAttributes($sentinelPath) -bor [IO.FileAttributes]::ReadOnly))
    $sameByteRecoveryRejected = $false
    try { $null = Recover-HostIsolatedConfigSentinel -Path $sentinelHome } catch { $sameByteRecoveryRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    $sameByteRecoveryIdentityAfter = Get-HostFileSystemIdentity -Path $sentinelPath
    Check ($sameByteRecoveryRejected -and [string]$sameByteRecoveryIdentityAfter.volume -ceq [string]$recoveryReplacementIdentity.volume -and [string]$sameByteRecoveryIdentityAfter.file_id -ceq [string]$recoveryReplacementIdentity.file_id -and (Test-HostExactUtf8File -Path $sentinelPath -ExpectedText "# isolated host benchmark sentinel`n") -and (Test-Path -LiteralPath $sameByteRecoverySentinel.owner_path -PathType Container)) 'recovery accepted or modified an exact-byte foreign file with the wrong identity'
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    [IO.File]::Delete($sentinelPath)
    [IO.Directory]::Delete([string]$sameByteRecoverySentinel.owner_path,$false)

    $hardlinkRecoverySentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    $hardlinkRecoveryAlias = Join-Path $scratch 'recovery-sentinel-hardlink-alias.toml'
    [void](New-Item -ItemType HardLink -Path $hardlinkRecoveryAlias -Target $sentinelPath -ErrorAction Stop)
    $hardlinkRecoveryRejected = $false
    try { $null = Recover-HostIsolatedConfigSentinel -Path $sentinelHome } catch { $hardlinkRecoveryRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    Check ($hardlinkRecoveryRejected -and (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -and (Test-Path -LiteralPath $hardlinkRecoveryAlias -PathType Leaf) -and (Test-Path -LiteralPath $hardlinkRecoverySentinel.owner_path -PathType Container) -and (Test-HostExactUtf8File -Path $hardlinkRecoveryAlias -ExpectedText "# isolated host benchmark sentinel`n")) 'recovery accepted an identity-matching hardlink or touched its alias/owner evidence'
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    [IO.File]::Delete($sentinelPath)
    [IO.File]::Delete($hardlinkRecoveryAlias)
    [IO.Directory]::Delete([string]$hardlinkRecoverySentinel.owner_path,$false)

    $crashHome = Join-Path $scratch 'isolated-config-crash-home'
    Write-Utf8 (Join-Path $crashHome 'auth.json') '{}'
    $crashReady = Join-Path $scratch 'isolated-config-crash-ready.txt'
    $crashChildPath = Join-Path $scratch 'isolated-config-crash-child.ps1'
    Write-Utf8 $crashChildPath @'
param([string]$TrialPath,[string]$CodexHome,[string]$ReadyPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $TrialPath
$lock = $null
$state = $null
try {
    $lock = Enter-HostCodexHomeMutex -Path $CodexHome -FailureCode 'fixture-lock-timeout'
    $null = Recover-HostIsolatedConfigSentinel -Path $CodexHome
    $state = Initialize-HostIsolatedConfigSentinel -Path $CodexHome
    [IO.File]::WriteAllText($ReadyPath,[string]$lock.name,[Text.UTF8Encoding]::new($false))
    while ($true) { Start-Sleep -Seconds 1 }
} finally {
    if ($null -ne $state) { $null = Complete-HostIsolatedConfigSentinel -State $state }
    Exit-HostCodexHomeMutex -State $lock
}
'@
    $crashProcess = $null
    $mutexObserver = $null
    try {
        $crashProcess = Start-Process -FilePath (Get-Command pwsh -ErrorAction Stop).Source -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$crashChildPath,'-TrialPath',(Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1'),'-CodexHome',$crashHome,'-ReadyPath',$crashReady) -WindowStyle Hidden -PassThru
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-Path -LiteralPath $crashReady -PathType Leaf) -and -not $crashProcess.HasExited -and [DateTime]::UtcNow -lt $readyDeadline) { Start-Sleep -Milliseconds 50 }
        if (-not (Test-Path -LiteralPath $crashReady -PathType Leaf) -or $crashProcess.HasExited) { throw 'crash recovery child did not publish its ready marker' }
        $crashOwners = @(Get-ChildItem -LiteralPath $crashHome -Force | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigOwnerPrefix,[StringComparison]::Ordinal) })
        Check ((Test-Path -LiteralPath (Join-Path $crashHome 'config.toml') -PathType Leaf) -and $crashOwners.Count -eq 1) 'crash recovery child did not publish the owned sentinel pair'
        $mutexObserver = [Threading.Mutex]::OpenExisting([IO.File]::ReadAllText($crashReady,[Text.UTF8Encoding]::new($false,$true)))
        Stop-Process -Id $crashProcess.Id -Force -ErrorAction Stop
        [void]$crashProcess.WaitForExit(10000)
        $recoveryLock = Enter-HostCodexHomeMutex -Path $crashHome -FailureCode 'fixture-recovery-lock-timeout'
        $recoveryWasAbandoned = [bool]$recoveryLock.abandoned
        try { $crashRecovered = Recover-HostIsolatedConfigSentinel -Path $crashHome } finally { Exit-HostCodexHomeMutex -State $recoveryLock }
        Check ($recoveryWasAbandoned -and $crashRecovered -and -not (Test-Path -LiteralPath (Join-Path $crashHome 'config.toml')) -and @(Get-ChildItem -LiteralPath $crashHome -Force | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigOwnerPrefix,[StringComparison]::Ordinal) }).Count -eq 0 -and (Assert-HostCodexHomeLayout -Path $crashHome -AllowNativeSystemSkills)) 'abandoned mutex recovery did not make the profile immediately model-safe'
        $nextHostSentinel = Initialize-HostIsolatedConfigSentinel -Path $crashHome
        $null = Complete-HostIsolatedConfigSentinel -State $nextHostSentinel
        Check (-not (Test-Path -LiteralPath (Join-Path $crashHome 'config.toml')) -and -not (Test-Path -LiteralPath $nextHostSentinel.owner_path)) 'next Host lifecycle failed after abandoned process recovery'
    } finally {
        if ($null -ne $crashProcess -and -not $crashProcess.HasExited) { Stop-Process -Id $crashProcess.Id -Force -ErrorAction SilentlyContinue }
        if ($null -ne $mutexObserver) { $mutexObserver.Dispose() }
    }

    Write-Utf8 $sentinelPath "# isolated host benchmark sentinel`n"
    $writableSentinelRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills -AllowIsolatedHostConfig } catch { $writableSentinelRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $writableSentinelRejected 'writable Host config sentinel was accepted'
    Remove-Item -LiteralPath $sentinelPath -Force
    $bom = [Text.UTF8Encoding]::new($true).GetPreamble()
    $sentinelBytes = [Text.UTF8Encoding]::new($false).GetBytes("# isolated host benchmark sentinel`n")
    [IO.File]::WriteAllBytes($sentinelPath,[byte[]]($bom + $sentinelBytes))
    [IO.File]::SetAttributes($sentinelPath,([IO.File]::GetAttributes($sentinelPath) -bor [IO.FileAttributes]::ReadOnly))
    $bomSentinelRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $sentinelHome -AllowNativeSystemSkills -AllowIsolatedHostConfig } catch { $bomSentinelRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $bomSentinelRejected 'BOM-prefixed Host config sentinel was accepted'
    Remove-Item -LiteralPath $sentinelPath -Force
    Write-Utf8 $sentinelPath 'model = "fixture"'
    $rogueIdentity = Get-HostFileSystemIdentity -Path $sentinelPath
    $rogueDigest = (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash
    $rogueConfigRejected = $false
    try { $null = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome } catch { $rogueConfigRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    $rogueIdentityAfter = Get-HostFileSystemIdentity -Path $sentinelPath
    Check ($rogueConfigRejected -and [string]$rogueIdentityAfter.volume -ceq [string]$rogueIdentity.volume -and [string]$rogueIdentityAfter.file_id -ceq [string]$rogueIdentity.file_id -and (Get-FileHash -LiteralPath $sentinelPath -Algorithm SHA256).Hash -ceq $rogueDigest) 'foreign config.toml was accepted or overwritten by sentinel initialization'
    Remove-Item -LiteralPath $sentinelPath -Force
    $tamperedSentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    Write-Utf8 $sentinelPath 'tampered'
    $tamperedCleanupRejected = $false
    try { $null = Complete-HostIsolatedConfigSentinel -State $tamperedSentinel } catch { $tamperedCleanupRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-config-sentinel-changed' }
    Check ($tamperedCleanupRejected -and (Test-Path -LiteralPath $sentinelPath -PathType Leaf) -and (Test-Path -LiteralPath $tamperedSentinel.owner_path -PathType Container) -and [IO.File]::ReadAllText($sentinelPath) -ceq 'tampered') 'tampered runner sentinel or its owner evidence was deleted or treated as clean'
    Remove-Item -LiteralPath $sentinelPath -Force
    [IO.Directory]::Delete([string]$tamperedSentinel.owner_path,$false)
    $replacedSentinel = Initialize-HostIsolatedConfigSentinel -Path $sentinelHome
    $replacementSource = Join-Path $scratch 'replacement-sentinel.toml'
    Write-Utf8 $replacementSource "# isolated host benchmark sentinel`n"
    [IO.File]::SetAttributes($replacementSource,([IO.File]::GetAttributes($replacementSource) -bor [IO.FileAttributes]::ReadOnly))
    $replacementIdentity = Get-HostFileSystemIdentity -Path $replacementSource
    [IO.File]::SetAttributes($sentinelPath,[IO.FileAttributes]::Normal)
    [IO.File]::Delete($sentinelPath)
    [IO.File]::Move($replacementSource,$sentinelPath,$false)
    $replacedCleanupRejected = $false
    try { $null = Complete-HostIsolatedConfigSentinel -State $replacedSentinel } catch { $replacedCleanupRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-config-sentinel-changed' }
    $replacementAfter = Get-HostFileSystemIdentity -Path $sentinelPath
    Check ($replacedCleanupRejected -and [string]$replacementAfter.volume -ceq [string]$replacementIdentity.volume -and [string]$replacementAfter.file_id -ceq [string]$replacementIdentity.file_id -and (Get-Item -LiteralPath $sentinelPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReadOnly) -and (Test-Path -LiteralPath $replacedSentinel.owner_path -PathType Container)) 'same-byte replacement sentinel or its owner evidence was deleted or accepted as the runner-owned file'
    Remove-Item -LiteralPath $sentinelPath -Force
    [IO.Directory]::Delete([string]$replacedSentinel.owner_path,$false)

    $hardlinkSentinelHome = Join-Path $scratch 'hardlink-sentinel-home'
    $hardlinkSentinelTarget = Join-Path $scratch 'hardlink-sentinel-target.toml'
    Write-Utf8 (Join-Path $hardlinkSentinelHome 'auth.json') '{}'
    Write-Utf8 $hardlinkSentinelTarget "# isolated host benchmark sentinel`n"
    [void](New-Item -ItemType HardLink -Path (Join-Path $hardlinkSentinelHome 'config.toml') -Target $hardlinkSentinelTarget -ErrorAction Stop)
    [IO.File]::SetAttributes($hardlinkSentinelTarget,([IO.File]::GetAttributes($hardlinkSentinelTarget) -bor [IO.FileAttributes]::ReadOnly))
    $hardlinkSentinelRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $hardlinkSentinelHome -AllowNativeSystemSkills -AllowIsolatedHostConfig } catch { $hardlinkSentinelRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-linked-credential' }
    Check $hardlinkSentinelRejected 'hard-linked Host config sentinel was accepted'

    $junctionSentinelHome = Join-Path $scratch 'junction-sentinel-home'
    $junctionSentinelTarget = Join-Path $scratch 'junction-sentinel-target'
    Write-Utf8 (Join-Path $junctionSentinelHome 'auth.json') '{}'
    [void][IO.Directory]::CreateDirectory($junctionSentinelTarget)
    [void](New-Item -ItemType Junction -Path (Join-Path $junctionSentinelHome 'config.toml') -Target $junctionSentinelTarget -ErrorAction Stop)
    $junctionSentinelRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $junctionSentinelHome -AllowNativeSystemSkills -AllowIsolatedHostConfig } catch { $junctionSentinelRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-reparse-point' }
    Check $junctionSentinelRejected 'junction Host config sentinel was accepted'

    $junctionTarget = Join-Path $scratch 'junction-target'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    $junctionPath = Join-Path $authHome 'cache\linked'
    [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop)
    $descendantJunctionRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome } catch { $descendantJunctionRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-reparse-point' }
    Check $descendantJunctionRejected 'descendant auth-home junction was accepted'
    Remove-Item -LiteralPath $junctionPath -Force

    $linkedAuthTarget = Join-Path $scratch 'linked-auth-target'
    Write-Utf8 (Join-Path $linkedAuthTarget 'auth.json') '{}'
    $linkedAuthHome = Join-Path $scratch 'linked-auth-home'
    [void](New-Item -ItemType Junction -Path $linkedAuthHome -Target $linkedAuthTarget -ErrorAction Stop)
    $rootJunctionRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $linkedAuthHome } catch { $rootJunctionRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-reparse-point' }
    Check $rootJunctionRejected 'root auth-home junction was accepted'
    Remove-Item -LiteralPath $linkedAuthHome -Force

    $hardlinkTarget = Join-Path $scratch 'hardlink-auth-target.json'
    Write-Utf8 $hardlinkTarget '{}'
    $hardlinkHome = Join-Path $scratch 'hardlink-auth-home'
    [void][IO.Directory]::CreateDirectory($hardlinkHome)
    [void](New-Item -ItemType HardLink -Path (Join-Path $hardlinkHome 'auth.json') -Target $hardlinkTarget -ErrorAction Stop)
    $hardlinkRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $hardlinkHome } catch { $hardlinkRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-linked-credential' }
    Check $hardlinkRejected 'hard-linked auth credential was accepted'

    $hardlinkStateTarget = Join-Path $scratch 'hardlink-state-target.json'
    Write-Utf8 $hardlinkStateTarget '{}'
    $hardlinkStateHome = Join-Path $scratch 'hardlink-state-home'
    Write-Utf8 (Join-Path $hardlinkStateHome 'auth.json') '{}'
    [void](New-Item -ItemType HardLink -Path (Join-Path $hardlinkStateHome 'models_cache.json') -Target $hardlinkStateTarget -ErrorAction Stop)
    $hardlinkStateRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $hardlinkStateHome } catch { $hardlinkStateRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-linked-credential' }
    Check $hardlinkStateRejected 'hard-linked top-level Codex state file was accepted'

    $hardlinkNestedTarget = Join-Path $scratch 'hardlink-nested-target.json'
    Write-Utf8 $hardlinkNestedTarget '{}'
    $hardlinkNestedHome = Join-Path $scratch 'hardlink-nested-home'
    Write-Utf8 (Join-Path $hardlinkNestedHome 'auth.json') '{}'
    [void][IO.Directory]::CreateDirectory((Join-Path $hardlinkNestedHome 'cache'))
    [void](New-Item -ItemType HardLink -Path (Join-Path $hardlinkNestedHome 'cache\state.json') -Target $hardlinkNestedTarget -ErrorAction Stop)
    $hardlinkNestedRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $hardlinkNestedHome } catch { $hardlinkNestedRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-linked-credential' }
    Check $hardlinkNestedRejected 'hard-linked nested Codex state file was accepted'

    $installedProfileRoot = Join-Path $scratch 'installed-profile-clean'
    $installedCodexHome = Join-Path $installedProfileRoot '.codex'
    Write-Utf8 (Join-Path $installedCodexHome 'auth.json') '{"fixture":"installed-profile"}'
    Write-Utf8 (Join-Path $installedCodexHome 'config.toml') 'model = "fixture"'
    Write-Utf8 (Join-Path $installedCodexHome '.personality_migration') 'complete'
    Write-Utf8 (Join-Path $installedCodexHome 'goals_1.sqlite') 'fixture'
    Write-Utf8 (Join-Path $installedCodexHome 'logs_1.sqlite-wal') 'fixture'
    Write-Utf8 (Join-Path $installedCodexHome 'memories_1.sqlite-shm') 'fixture'
    Write-Utf8 (Join-Path $installedCodexHome 'plugins\fixture\state.json') '{}'
    Write-Utf8 (Join-Path $installedCodexHome 'skills\.system\fixture\SKILL.md') 'fixture'
    Check ((Assert-InstalledDesktopProfileReady -CodexHome $installedCodexHome) -ceq [IO.Path]::GetFullPath($installedProfileRoot).TrimEnd('\')) 'clean installed Desktop profile with config.toml was rejected'
    [void][IO.Directory]::CreateDirectory((Join-Path $installedCodexHome 'skills\rogue'))
    $rogueSkillRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $installedCodexHome -AllowUserConfig } catch { $rogueSkillRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-isolated' }
    Check $rogueSkillRejected 'installed Desktop profile accepted a rogue user skill'
    Remove-Item -LiteralPath (Join-Path $installedCodexHome 'skills\rogue') -Recurse -Force

    $managedAssetsProfile = Join-Path $scratch 'installed-assets-profile'
    $managedAssetsHome = Join-Path $managedAssetsProfile '.codex'
    $managedSkillTarget = Join-Path $scratch 'managed-skill-target'
    Write-Utf8 (Join-Path $managedAssetsHome 'auth.json') '{"fixture":"managed-assets"}'
    [void][IO.Directory]::CreateDirectory((Join-Path $managedAssetsHome 'skills\.system'))
    [void][IO.Directory]::CreateDirectory((Join-Path $managedAssetsHome '.claude'))
    [void][IO.Directory]::CreateDirectory($managedSkillTarget)
    foreach ($skillName in @('entry-router','orchestrator','plan','implement','review','test','spec')) {
        [void](New-Item -ItemType Junction -Path (Join-Path $managedAssetsHome "skills\$skillName") -Target $managedSkillTarget -ErrorAction Stop)
    }
    Check ((Assert-HostCodexHomeLayout -Path $managedAssetsHome -AllowUserConfig -AllowInstalledAssets) -ceq [IO.Path]::GetFullPath($managedAssetsHome).TrimEnd('\')) 'the seven direct managed skill junctions were rejected'
    [void](New-Item -ItemType Junction -Path (Join-Path $managedAssetsHome 'skills\rogue') -Target $managedSkillTarget -ErrorAction Stop)
    $rogueManagedJunctionRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $managedAssetsHome -AllowUserConfig -AllowInstalledAssets } catch { $rogueManagedJunctionRejected = $true }
    Check $rogueManagedJunctionRejected 'a non-managed direct skill junction was accepted'

    foreach ($case in @(
        [pscustomobject]@{Name='skills-root';Relative='skills'},
        [pscustomobject]@{Name='claude-root';Relative='.claude'},
        [pscustomobject]@{Name='system-skill';Relative='skills\.system'},
        [pscustomobject]@{Name='claude-descendant';Relative='.claude\nested\linked'}
    )) {
        $reparseProfile = Join-Path $scratch ("installed-assets-reparse-" + $case.Name)
        $reparseHome = Join-Path $reparseProfile '.codex'
        Write-Utf8 (Join-Path $reparseHome 'auth.json') '{"fixture":"reparse"}'
        $reparsePath = Join-Path $reparseHome $case.Relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reparsePath))
        [void](New-Item -ItemType Junction -Path $reparsePath -Target $managedSkillTarget -ErrorAction Stop)
        $installedReparseRejected = $false
        try { $null = Assert-HostCodexHomeLayout -Path $reparseHome -AllowUserConfig -AllowInstalledAssets } catch { $installedReparseRejected = $true }
        Check $installedReparseRejected "installed assets accepted the $($case.Name) reparse point"
    }

    foreach ($case in @(
        [pscustomobject]@{Relative='AGENTS.md';Directory=$false},
        [pscustomobject]@{Relative='hooks.json';Directory=$false},
        [pscustomobject]@{Relative='managed_config.toml';Directory=$false}
    )) {
        $candidate = Join-Path $installedCodexHome $case.Relative
        if ($case.Directory) { [void][IO.Directory]::CreateDirectory($candidate) } else { Write-Utf8 $candidate 'fixture' }
        $installedAssetRejected = $false
        try { $null = Assert-InstalledDesktopProfileReady -CodexHome $installedCodexHome } catch { $installedAssetRejected = $true }
        Check $installedAssetRejected "installed Desktop profile retained $($case.Relative)"
        if ($case.Directory) { Remove-Item -LiteralPath $candidate -Recurse -Force } else { Remove-Item -LiteralPath $candidate -Force }
    }
    $postUninstallContainers = @(
        (Join-Path $installedCodexHome '.claude'),
        (Join-Path $installedProfileRoot '.claude\skills'),
        (Join-Path $installedProfileRoot '.agents\skills')
    )
    foreach ($container in $postUninstallContainers) { [void][IO.Directory]::CreateDirectory($container) }
    Write-Utf8 (Join-Path $installedProfileRoot '.dev-harness\backups\history\install-manifest.json') '{}'
    Check ((Assert-InstalledDesktopProfileReady -CodexHome $installedCodexHome) -ceq [IO.Path]::GetFullPath($installedProfileRoot).TrimEnd('\')) 'installed Desktop profile rejected empty post-uninstall containers or backup history'
    $postUninstallJunctionTarget = Join-Path $scratch 'post-uninstall-junction-target'
    [void][IO.Directory]::CreateDirectory($postUninstallJunctionTarget)
    foreach ($container in $postUninstallContainers) {
        Write-Utf8 (Join-Path $container 'unexpected.txt') 'managed'
        $containerFileRejected = $false
        try { $null = Assert-InstalledDesktopProfileReady -CodexHome $installedCodexHome } catch { $containerFileRejected = $true }
        Check $containerFileRejected "installed Desktop profile accepted a file under $container"
        Remove-Item -LiteralPath (Join-Path $container 'unexpected.txt') -Force

        Remove-Item -LiteralPath $container -Recurse -Force
        [void](New-Item -ItemType Junction -Path $container -Target $postUninstallJunctionTarget -ErrorAction Stop)
        $containerJunctionRejected = $false
        try { $null = Assert-InstalledDesktopProfileReady -CodexHome $installedCodexHome } catch { $containerJunctionRejected = $true }
        Check $containerJunctionRejected "installed Desktop profile accepted a reparse-backed post-uninstall container at $container"
        Remove-Item -LiteralPath $container -Force
        [void][IO.Directory]::CreateDirectory($container)
    }

    $installedStateRoot = Join-Path $installedProfileRoot '.dev-harness'
    $installedRegistryPath = Join-Path $installedStateRoot 'install-registry.json'
    Write-Utf8 $installedRegistryPath '{"workspaces":{}}'
    Check ((Assert-InstalledDesktopProfileReady -CodexHome $installedCodexHome) -ceq [IO.Path]::GetFullPath($installedProfileRoot).TrimEnd('\')) 'empty installed Desktop registry was rejected'
    $registeredWorkspace = Join-Path $scratch 'registered-workspace'
    $nearbyWorkspace = Join-Path $scratch 'registered-workspace-copy'
    [void][IO.Directory]::CreateDirectory($registeredWorkspace)
    [void][IO.Directory]::CreateDirectory($nearbyWorkspace)
    $activeRegistry = [ordered]@{workspaces=[ordered]@{
        registered=[ordered]@{workspace_root=$registeredWorkspace}
        nearby=[ordered]@{workspace_root=$nearbyWorkspace}
    }}
    Write-Utf8 $installedRegistryPath ($activeRegistry | ConvertTo-Json -Depth 10 -Compress)
    Check (Test-InstalledDesktopWorkspaceRegistered -CodexHome $installedCodexHome -Workspace $registeredWorkspace) 'installed Desktop registry missed the exact workspace'
    Check (-not (Test-InstalledDesktopWorkspaceRegistered -CodexHome $installedCodexHome -Workspace (Join-Path $scratch 'registered-workspace-child'))) 'installed Desktop registry accepted a workspace path prefix'
    $activeRegistryRejected = $false
    try { $null = Assert-InstalledDesktopProfileReady -CodexHome $installedCodexHome } catch { $activeRegistryRejected = $_.Exception.Message -ceq 'host-benchmark-installed-profile-not-clean' }
    Check $activeRegistryRejected 'installed Desktop profile with active registry workspaces was accepted as clean'
    Write-Utf8 $installedRegistryPath '{"workspaces":{}}'

    foreach ($journalName in @('install-transaction.json','uninstall-transaction.json')) {
        $journalPath = Join-Path $installedStateRoot $journalName
        Write-Utf8 $journalPath '{}'
        $pendingJournalRejected = $false
        try { $null = Assert-InstalledDesktopProfileReady -CodexHome $installedCodexHome } catch { $pendingJournalRejected = $_.Exception.Message -ceq 'host-benchmark-installed-profile-transaction-pending' }
        Check $pendingJournalRejected "installed Desktop profile accepted pending $journalName"
        Remove-Item -LiteralPath $journalPath -Force
    }

    $installedAliasTarget = Join-Path $scratch 'installed-profile-alias-target'
    Write-Utf8 (Join-Path $installedAliasTarget '.codex\auth.json') '{"fixture":"alias"}'
    $installedProfileAlias = Join-Path $scratch 'installed-profile-alias'
    [void](New-Item -ItemType Junction -Path $installedProfileAlias -Target $installedAliasTarget -ErrorAction Stop)
    try {
        $installedProfileReparseRejected = $false
        try { $null = Assert-InstalledDesktopProfileReady -CodexHome (Join-Path $installedProfileAlias '.codex') } catch { $installedProfileReparseRejected = $_.Exception.Message -ceq 'host-benchmark-installed-profile-reparse-point' }
        Check $installedProfileReparseRejected 'reparse-backed installed Desktop profile root was accepted'
    } finally {
        Remove-Item -LiteralPath $installedProfileAlias -Force
    }

    $cleanupProfileRoot = Join-Path $scratch 'installed-cleanup-profile'
    $cleanupCodexHome = Join-Path $cleanupProfileRoot '.codex'
    $cleanupWorkspace = Join-Path $scratch 'installed-cleanup-workspace'
    $cleanupRepo = Join-Path $scratch 'installed-cleanup-repo'
    [void][IO.Directory]::CreateDirectory($cleanupWorkspace)
    Write-Utf8 (Join-Path $cleanupCodexHome 'auth.json') '{"fixture":"cleanup"}'
    Write-Utf8 (Join-Path $cleanupProfileRoot '.dev-harness\install-registry.json') (([ordered]@{workspaces=[ordered]@{cleanup=[ordered]@{workspace_root=$cleanupWorkspace}}}) | ConvertTo-Json -Depth 10 -Compress)
    Write-Utf8 (Join-Path $cleanupRepo 'uninstall.ps1') @'
param([string]$WorkspaceRoot,[string]$RepoRoot)
$registryPath = Join-Path $env:USERPROFILE '.dev-harness\install-registry.json'
[IO.File]::WriteAllText($registryPath,'{"workspaces":{}}',[Text.UTF8Encoding]::new($false))
$observation = [ordered]@{userprofile=$env:USERPROFILE;home=$env:HOME;codex_home=$env:CODEX_HOME;workspace=$WorkspaceRoot;repo=$RepoRoot}
[IO.File]::WriteAllText((Join-Path $RepoRoot 'cleanup-observation.json'),($observation | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 0
'@
    $cleanupSavedEnvironment = [ordered]@{}
    foreach ($name in @('USERPROFILE','HOME','CODEX_HOME')) { $cleanupSavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process) }
    try {
        $env:USERPROFILE = Join-Path $scratch 'sentinel-userprofile'
        $env:HOME = Join-Path $scratch 'sentinel-home'
        $env:CODEX_HOME = Join-Path $scratch 'sentinel-codex-home'
        $cleanupAuthBefore = (Get-FileHash -LiteralPath (Join-Path $cleanupCodexHome 'auth.json') -Algorithm SHA256).Hash
        $cleanupPassed = Invoke-InstalledDesktopTrialCleanup -CodexHome $cleanupCodexHome -Workspace $cleanupWorkspace -RepoRoot $cleanupRepo
        $cleanupObservation = [IO.File]::ReadAllText((Join-Path $cleanupRepo 'cleanup-observation.json'),[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json
        Check ($cleanupPassed -and [string]$cleanupObservation.userprofile -ceq $cleanupProfileRoot -and [string]$cleanupObservation.home -ceq $cleanupProfileRoot -and [string]$cleanupObservation.codex_home -ceq $cleanupCodexHome -and [string]$cleanupObservation.workspace -ceq $cleanupWorkspace) 'installed Desktop cleanup did not use the fixture profile and workspace'
        Check ((Get-FileHash -LiteralPath (Join-Path $cleanupCodexHome 'auth.json') -Algorithm SHA256).Hash -ceq $cleanupAuthBefore) 'installed Desktop cleanup changed fixture auth'
        Check ($env:USERPROFILE -ceq (Join-Path $scratch 'sentinel-userprofile') -and $env:HOME -ceq (Join-Path $scratch 'sentinel-home') -and $env:CODEX_HOME -ceq (Join-Path $scratch 'sentinel-codex-home')) 'installed Desktop cleanup did not restore the caller environment'
    } finally {
        foreach ($entry in $cleanupSavedEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key,$entry.Value,[EnvironmentVariableTarget]::Process) }
    }

    $recoveryProfileRoot = Join-Path $scratch 'installed-recovery-profile'
    $recoveryCodexHome = Join-Path $recoveryProfileRoot '.codex'
    $recoveryWorkspace = Join-Path $scratch 'installed-recovery-workspace'
    $recoveryRepo = Join-Path $scratch 'installed-recovery-repo'
    $recoveryManifest = Join-Path $recoveryProfileRoot '.dev-harness\backups\fixture\install-manifest.json'
    $recoveryJournalPath = Join-Path $recoveryProfileRoot '.dev-harness\install-transaction.json'
    [void][IO.Directory]::CreateDirectory($recoveryWorkspace)
    Write-Utf8 (Join-Path $recoveryCodexHome 'auth.json') '{"fixture":"recovery"}'
    Write-Utf8 (Join-Path $recoveryCodexHome 'config.toml') 'model = "fixture"'
    Write-Utf8 $recoveryManifest '{}'
    $recoveryJournal = [ordered]@{
        schema_version = 'install-transaction/v1.1'
        user_profile = $recoveryProfileRoot
        workspace_root = $recoveryWorkspace
        repo_root = $recoveryRepo
        manifest_path = $recoveryManifest
    }
    Write-Utf8 $recoveryJournalPath ($recoveryJournal | ConvertTo-Json -Depth 10 -Compress)
    $recovery = Get-InstalledDesktopPendingRecovery -CodexHome $recoveryCodexHome -Workspace $recoveryWorkspace -RepoRoot $recoveryRepo
    Check ([string]$recovery.manifest_path -ceq [IO.Path]::GetFullPath($recoveryManifest)) 'installed Desktop pending recovery did not bind the expected manifest'

    foreach ($case in @(
        [pscustomobject]@{Field='user_profile';Value=(Join-Path $scratch 'wrong-recovery-profile');Message='profile'},
        [pscustomobject]@{Field='workspace_root';Value=(Join-Path $scratch 'wrong-recovery-workspace');Message='workspace'},
        [pscustomobject]@{Field='repo_root';Value=(Join-Path $scratch 'wrong-recovery-repo');Message='repo'}
    )) {
        $expected = $recoveryJournal[$case.Field]
        $recoveryJournal[$case.Field] = $case.Value
        Write-Utf8 $recoveryJournalPath ($recoveryJournal | ConvertTo-Json -Depth 10 -Compress)
        $bindingRejected = $false
        try { $null = Get-InstalledDesktopPendingRecovery -CodexHome $recoveryCodexHome -Workspace $recoveryWorkspace -RepoRoot $recoveryRepo } catch { $bindingRejected = $_.Exception.Message -ceq 'host-benchmark-installed-recovery-invalid' }
        Check $bindingRejected "installed Desktop pending recovery accepted the wrong $($case.Message) binding"
        $recoveryJournal[$case.Field] = $expected
    }
    $outsideManifest = Join-Path $scratch 'outside-backups\install-manifest.json'
    Write-Utf8 $outsideManifest '{}'
    $recoveryJournal.manifest_path = $outsideManifest
    Write-Utf8 $recoveryJournalPath ($recoveryJournal | ConvertTo-Json -Depth 10 -Compress)
    $outsideManifestRejected = $false
    try { $null = Get-InstalledDesktopPendingRecovery -CodexHome $recoveryCodexHome -Workspace $recoveryWorkspace -RepoRoot $recoveryRepo } catch { $outsideManifestRejected = $_.Exception.Message -ceq 'host-benchmark-installed-recovery-invalid' }
    Check $outsideManifestRejected 'installed Desktop pending recovery accepted an out-of-profile manifest'
    $recoveryJournal.manifest_path = $recoveryManifest
    Write-Utf8 $recoveryJournalPath ($recoveryJournal | ConvertTo-Json -Depth 10 -Compress)

    Write-Utf8 (Join-Path $recoveryCodexHome 'AGENTS.md') 'managed'
    Write-Utf8 (Join-Path $recoveryCodexHome 'hooks.json') '{}'
    Write-Utf8 (Join-Path $recoveryProfileRoot '.dev-harness\install-registry.json') (([ordered]@{workspaces=[ordered]@{recovery=[ordered]@{workspace_root=$recoveryWorkspace}}}) | ConvertTo-Json -Depth 10 -Compress)
    Write-Utf8 (Join-Path $recoveryRepo 'uninstall.ps1') @'
param([string]$RecoveryManifestPath,[string]$RepoRoot)
$profileRoot = $env:USERPROFILE
$codexHome = $env:CODEX_HOME
foreach ($relative in @('AGENTS.md','hooks.json')) { Remove-Item -LiteralPath (Join-Path $codexHome $relative) -Force -ErrorAction Stop }
[IO.File]::WriteAllText((Join-Path $profileRoot '.dev-harness\install-registry.json'),'{"workspaces":{}}',[Text.UTF8Encoding]::new($false))
Remove-Item -LiteralPath (Join-Path $profileRoot '.dev-harness\install-transaction.json') -Force -ErrorAction Stop
$observation = [ordered]@{userprofile=$env:USERPROFILE;home=$env:HOME;codex_home=$env:CODEX_HOME;manifest=$RecoveryManifestPath;repo=$RepoRoot}
[IO.File]::WriteAllText((Join-Path $RepoRoot 'recovery-observation.json'),($observation | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
exit 0
'@
    $recoverySavedEnvironment = [ordered]@{}
    foreach ($name in @('USERPROFILE','HOME','CODEX_HOME')) { $recoverySavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process) }
    try {
        $env:USERPROFILE = Join-Path $scratch 'recovery-sentinel-userprofile'
        $env:HOME = Join-Path $scratch 'recovery-sentinel-home'
        $env:CODEX_HOME = Join-Path $scratch 'recovery-sentinel-codex-home'
        $recoveryAuthBefore = (Get-FileHash -LiteralPath (Join-Path $recoveryCodexHome 'auth.json') -Algorithm SHA256).Hash
        $recoveryPassed = Invoke-InstalledDesktopTrialRecovery -CodexHome $recoveryCodexHome -Workspace $recoveryWorkspace -RepoRoot $recoveryRepo -Recovery $recovery
        $recoveryObservation = [IO.File]::ReadAllText((Join-Path $recoveryRepo 'recovery-observation.json'),[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json
        Check ($recoveryPassed -and [string]$recoveryObservation.userprofile -ceq $recoveryProfileRoot -and [string]$recoveryObservation.home -ceq $recoveryProfileRoot -and [string]$recoveryObservation.codex_home -ceq $recoveryCodexHome -and [string]$recoveryObservation.manifest -ceq [IO.Path]::GetFullPath($recoveryManifest)) 'installed Desktop recovery did not use the bound fixture profile and manifest'
        Check ((Get-FileHash -LiteralPath (Join-Path $recoveryCodexHome 'auth.json') -Algorithm SHA256).Hash -ceq $recoveryAuthBefore) 'installed Desktop recovery changed fixture auth'
        Check ($env:USERPROFILE -ceq (Join-Path $scratch 'recovery-sentinel-userprofile') -and $env:HOME -ceq (Join-Path $scratch 'recovery-sentinel-home') -and $env:CODEX_HOME -ceq (Join-Path $scratch 'recovery-sentinel-codex-home')) 'installed Desktop recovery did not restore the caller environment'
        Check ((Assert-InstalledDesktopProfileReady -CodexHome $recoveryCodexHome) -ceq [IO.Path]::GetFullPath($recoveryProfileRoot).TrimEnd('\')) 'installed Desktop recovery did not leave the fixture profile clean'
    } finally {
        foreach ($entry in $recoverySavedEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key,$entry.Value,[EnvironmentVariableTarget]::Process) }
    }

    $traceSafetyRoot = Join-Path $scratch 'trace-safety'
    $traceResultRoot = Join-Path $traceSafetyRoot 'results'
    $externalTraceRoot = Join-Path $scratch 'external-trace'
    [void][IO.Directory]::CreateDirectory($traceResultRoot)
    Write-Utf8 (Join-Path $externalTraceRoot 'trace.json') 'private'
    $traceJunction = Join-Path $traceResultRoot 'otel-traces'
    [void](New-Item -ItemType Junction -Path $traceJunction -Target $externalTraceRoot -ErrorAction Stop)
    $traceRemoved = Remove-HostRawTrace -TraceRoot $traceJunction -ResultRoot $traceResultRoot -SafetyRoot $traceSafetyRoot
    Check (-not $traceRemoved -and (Test-Path -LiteralPath $traceJunction) -and (Test-Path -LiteralPath (Join-Path $externalTraceRoot 'trace.json') -PathType Leaf)) 'raw-trace junction was deleted or falsely attested as removed'
    Remove-Item -LiteralPath $traceJunction -Force

    $oldCodexHome = $env:CODEX_HOME
    $unrelatedScratch = Join-Path $scratch 'unrelated-scratch'
    [void][IO.Directory]::CreateDirectory($unrelatedScratch)
    try {
        $env:CODEX_HOME = $authHome
        $realHomeRejected = $false
        try { $null = Assert-HostCodexHome -Path $authHome -RepoRoot $RepoRoot -ScratchRoot $unrelatedScratch } catch { $realHomeRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-dedicated' }
        Check $realHomeRejected 'current Codex home was accepted as a dedicated benchmark home'

        $copiedAuthHome = Join-Path $scratch 'copied-auth-home'
        Write-Utf8 (Join-Path $copiedAuthHome 'auth.json') ([IO.File]::ReadAllText((Join-Path $authHome 'auth.json'),[Text.UTF8Encoding]::new($false,$true)))
        $copiedAuthRejected = $false
        try { $null = Assert-HostCodexHome -Path $copiedAuthHome -RepoRoot $RepoRoot -ScratchRoot $unrelatedScratch } catch { $copiedAuthRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-dedicated' }
        Check $copiedAuthRejected 'byte-for-byte copied personal auth was accepted as an independently logged-in benchmark home'

        $authAlias = Join-Path $scratch 'auth-home-alias'
        [void](New-Item -ItemType Junction -Path $authAlias -Target $authHome -ErrorAction Stop)
        try {
            $env:CODEX_HOME = $authAlias
            $aliasHomeRejected = $false
            try { $null = Assert-HostCodexHome -Path $authHome -RepoRoot $RepoRoot -ScratchRoot $unrelatedScratch } catch { $aliasHomeRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-dedicated' }
            Check $aliasHomeRejected 'physical alias of the current Codex home was accepted as dedicated'
        } finally {
            Remove-Item -LiteralPath $authAlias -Force
        }
    } finally {
        if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction Ignore } else { $env:CODEX_HOME = $oldCodexHome }
    }
    $fakeRepoRoot = Join-Path $scratch 'fake-repo-root'
    $repoAuthHome = Join-Path $fakeRepoRoot 'benchmark-auth-home'
    Write-Utf8 (Join-Path $repoAuthHome 'auth.json') '{}'
    $repoHomeRejected = $false
    try { $null = Assert-HostCodexHome -Path $repoAuthHome -RepoRoot $fakeRepoRoot -ScratchRoot $unrelatedScratch } catch { $repoHomeRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-unsafe-location' }
    Check $repoHomeRejected 'repository-local Codex auth home was accepted'

    $pathFixture = Join-Path $scratch 'workspace-paths'
    Initialize-GitFixture $pathFixture
    Write-Utf8 (Join-Path $pathFixture '.gitignore') "ignored/`n"
    Write-Utf8 (Join-Path $pathFixture 'baseline.txt') 'baseline'
    Write-Utf8 (Join-Path $pathFixture 'staged-only.txt') 'baseline'
    Commit-GitFixture $pathFixture
    $pathBaseline = (@(Invoke-Git $pathFixture @('rev-parse','HEAD')) -join '').Trim()
    Write-Utf8 (Join-Path $pathFixture ' src\value.txt') 'leading-space'
    Write-Utf8 (Join-Path $pathFixture 'ignored\evidence.txt') 'ignored'
    Write-Utf8 (Join-Path $pathFixture 'staged-only.txt') 'index-only'
    [void](Invoke-Git $pathFixture @('add','--','staged-only.txt'))
    Write-Utf8 (Join-Path $pathFixture 'staged-only.txt') 'baseline'
    $workspaceChanges = @(Get-HostWorkspaceChanges -Workspace $pathFixture -BaselineRevision $pathBaseline)
    Check ($workspaceChanges -ccontains ' src/value.txt') 'workspace diff normalized away a leading-space path'
    Check ($workspaceChanges -ccontains 'ignored/evidence.txt') 'workspace diff omitted an ignored write'
    Check ($workspaceChanges -ccontains 'staged-only.txt') 'workspace diff omitted a staged-only write'
    [void](Invoke-Git $pathFixture @('update-index','--assume-unchanged','baseline.txt'))
    Write-Utf8 (Join-Path $pathFixture 'baseline.txt') 'assume-hidden'
    $assumeChanges = @(Get-HostWorkspaceChanges -Workspace $pathFixture -BaselineRevision $pathBaseline)
    Check ($assumeChanges -ccontains '__git_index_flag__/baseline.txt') 'workspace evidence omitted an assume-unchanged index flag'
    [void](Invoke-Git $pathFixture @('update-index','--no-assume-unchanged','baseline.txt'))
    Write-Utf8 (Join-Path $pathFixture 'baseline.txt') 'baseline'
    [void](Invoke-Git $pathFixture @('update-index','--skip-worktree','baseline.txt'))
    Write-Utf8 (Join-Path $pathFixture 'baseline.txt') 'skip-hidden'
    $skipChanges = @(Get-HostWorkspaceChanges -Workspace $pathFixture -BaselineRevision $pathBaseline)
    Check ($skipChanges -ccontains '__git_index_flag__/baseline.txt') 'workspace evidence omitted a skip-worktree index flag'

    $hookFixture = Join-Path $scratch 'hook-baseline'
    Initialize-GitFixture $hookFixture
    Write-Utf8 (Join-Path $hookFixture 'baseline.txt') 'baseline'
    $null = Initialize-HostWorkspaceBaseline -Workspace $hookFixture
    $localHooksPath = (@(Invoke-Git $hookFixture @('config','--local','--get','core.hooksPath')) -join '').Trim()
    Check ($localHooksPath -ceq 'NUL') 'workspace baseline did not disable inherited Git hooks'

    $runtimeWorkspace = Join-Path $scratch 'runtime-done'
    $runtimeRoot = Join-Path $runtimeWorkspace '.assistant\运行时'
    [void][IO.Directory]::CreateDirectory((Join-Path $runtimeRoot 'tasks'))
    $runtimeTaskId = 'host-benchmark-fixed-workflow'
    $idleContent = New-CanonicalCurrentTaskContent -TaskId 'none' -TaskName '无' -Stage '空闲' -CurrentDoc 'none' -Tool 'none' -EntryHost 'unknown' -NextStep '等待新任务' -Writer 'advance-stage'
    $mirrorContent = New-CanonicalTaskRuntimeContent -TaskId $runtimeTaskId -TaskName 'Fixed Host Benchmark Workflow' -Stage 'DONE' -WorkspaceRoot $runtimeWorkspace -PrimaryArtifact "docs/tasks/$runtimeTaskId/test.md" -Tool 'none' -EntryHost 'codex' -Writer 'advance-stage'
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '当前任务.md'),$idleContent,[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $runtimeRoot "tasks\$runtimeTaskId.md"),$mirrorContent,[Text.UTF8Encoding]::new($true))
    $idleState = Get-CanonicalCurrentTaskState -Path (Join-Path $runtimeRoot '当前任务.md')
    $runtimeRecords = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory (Join-Path $runtimeRoot 'tasks'))
    $recoveryContent = New-CanonicalRecoveryIndexContent -CurrentTask $idleState -TaskRecords $runtimeRecords
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '恢复索引.md'),$recoveryContent,[Text.UTF8Encoding]::new($true))
    Check (Test-V1RuntimeState -Workspace $runtimeWorkspace -TaskId $runtimeTaskId -ExpectedStage 'DONE') 'canonical DONE idle pointer was rejected'
    $nonIdleContent = New-CanonicalCurrentTaskContent -TaskId $runtimeTaskId -TaskName 'Fixed Host Benchmark Workflow' -Stage 'DONE' -CurrentDoc "docs/tasks/$runtimeTaskId/test.md" -Tool 'none' -EntryHost 'codex' -NextStep 'done' -Writer 'advance-stage'
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '当前任务.md'),$nonIdleContent,[Text.UTF8Encoding]::new($true))
    Check (-not (Test-V1RuntimeState -Workspace $runtimeWorkspace -TaskId $runtimeTaskId -ExpectedStage 'DONE')) 'non-idle DONE pointer was accepted'
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '当前任务.md'),$idleContent,[Text.UTF8Encoding]::new($true))
    $badRecovery = $recoveryContent.Replace(('- task_id: ' + [char]96 + 'none' + [char]96),('- task_id: ' + [char]96 + 'wrong-task' + [char]96))
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '恢复索引.md'),$badRecovery,[Text.UTF8Encoding]::new($true))
    Check (-not (Test-V1RuntimeState -Workspace $runtimeWorkspace -TaskId $runtimeTaskId -ExpectedStage 'DONE')) 'recovery index with the wrong current task was accepted'

    $snapshotRepo = Join-Path $scratch 'snapshot-source'
    Initialize-GitFixture $snapshotRepo
    Write-Utf8 (Join-Path $snapshotRepo 'baseline.txt') 'baseline'
    Commit-GitFixture $snapshotRepo
    $cleanStatus = @(Invoke-Git $snapshotRepo @('-c','core.quotepath=false','status','--porcelain=v1','--untracked-files=all'))
    $chinesePath = Join-Path $snapshotRepo '目录\未跟踪.txt'
    Write-Utf8 $chinesePath '甲'
    $dirtyStatus = @(Invoke-Git $snapshotRepo @('-c','core.quotepath=false','status','--porcelain=v1','--untracked-files=all'))
    Check ($cleanStatus.Count -eq 0) 'committed source fixture was not clean'
    Check ($dirtyStatus.Count -eq 1 -and ($dirtyStatus -join '') -match '目录/未跟踪\.txt') 'Git source preflight did not detect a Chinese untracked path'
    Remove-Item -LiteralPath (Join-Path $snapshotRepo '目录') -Recurse -Force

    $bindingClone = Join-Path $scratch 'source-binding-clone'
    $cloneOutput = @(& git clone --no-local --no-checkout --quiet -- $snapshotRepo $bindingClone 2>&1 | ForEach-Object { [string]$_ })
    Check ($LASTEXITCODE -eq 0) 'native independent source clone failed'
    $revision = (@(Invoke-Git $snapshotRepo @('rev-parse','HEAD')) -join '').Trim()
    $tree = (@(Invoke-Git $snapshotRepo @('rev-parse',"$revision`^{tree}")) -join '').Trim()
    [void](Invoke-Git $bindingClone @('-c','core.hooksPath=NUL','checkout','--quiet','--detach',$revision,'--'))
    $cloneRevision = (@(Invoke-Git $bindingClone @('rev-parse','HEAD')) -join '').Trim()
    $cloneTree = (@(Invoke-Git $bindingClone @('rev-parse',"$cloneRevision`^{tree}")) -join '').Trim()
    Check ($cloneRevision -ceq $revision -and $cloneTree -ceq $tree -and @(Invoke-Git $bindingClone @('status','--porcelain=v1','--untracked-files=all')).Count -eq 0) 'native checkout did not bind revision, tree, and clean state'
    Write-Utf8 (Join-Path $bindingClone '.gitignore') "ignored/`n"
    [void](Invoke-Git $bindingClone @('add','.gitignore'))
    [void](Invoke-Git $bindingClone @('-c','user.name=Harness Test','-c','user.email=harness@example.invalid','commit','--quiet','--no-gpg-sign','-m','ignore-rule'))
    Write-Utf8 (Join-Path $bindingClone 'ignored\tamper.txt') 'tamper'
    Check (@(Invoke-Git $bindingClone @('status','--porcelain=v1','--untracked-files=all')).Count -eq 0 -and @(Invoke-Git $bindingClone @('ls-files','--others','--ignored','--exclude-standard','--')).Count -eq 1) 'ignored source tamper fixture did not distinguish normal status from ignored enumeration'
    [IO.File]::AppendAllText((Join-Path $bindingClone 'baseline.txt'),'tamper',[Text.UTF8Encoding]::new($false))
    Check (@(Invoke-Git $bindingClone @('status','--porcelain=v1','--untracked-files=all')).Count -gt 0) 'native source binding did not detect checkout tamper'

    $fixture = Join-Path $scratch 'runner-source'
    Initialize-GitFixture $fixture
    foreach ($relative in @('scripts\lib','scripts\host-benchmark','skills\codex\scripts','schemas\host-benchmark')) { [void][IO.Directory]::CreateDirectory((Join-Path $fixture $relative)) }
    foreach ($relative in @('scripts\run-host-benchmark.ps1','scripts\host-benchmark\HostBenchmark.Otel.ps1','scripts\lib\Harness.AtomicWrite.psm1','scripts\lib\Harness.Path.psm1','schemas\host-benchmark\observation.schema.json')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination (Join-Path $fixture $relative)
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1') -Destination (Join-Path $fixture 'scripts\host-benchmark\HostBenchmark.Trial.Real.ps1')
    Write-Utf8 (Join-Path $fixture '.gitignore') ".assistant/`n"
    Write-Utf8 (Join-Path $fixture 'install.ps1') "throw 'fixture install must not execute'`n"
    Write-Utf8 (Join-Path $fixture 'uninstall.ps1') "throw 'fixture uninstall must not execute'`n"
    Write-Utf8 (Join-Path $fixture 'tests\verify-installation.ps1') "throw 'fixture verification must not execute'`n"
    Write-Utf8 (Join-Path $fixture 'scripts\promote-v2-rollout-report.ps1') "throw 'fixture promotion must not execute'`n"
    Write-Utf8 (Join-Path $fixture 'scripts\lib\Harness.Protocol.psm1') "throw 'fixture protocol module must not execute'`n"
    Write-Utf8 (Join-Path $fixture 'scripts\receive-otlp-http.ps1') "throw 'fixture collector must not execute'`n"
    Write-Utf8 (Join-Path $fixture 'skills\codex\scripts\invoke_codex.ps1') "throw 'fixture wrapper must not execute'`n"
$stub = @'
. (Join-Path $PSScriptRoot 'HostBenchmark.Trial.Real.ps1')

function Assert-HostCodexHome {
    param(
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ScratchRoot,
        [switch]$AllowUserConfig,
        [switch]$AllowInstalledAssets,
        [switch]$AllowNativeSystemSkills,
        [switch]$AllowIsolatedHostConfig
    )
    return Assert-HostCodexHomeLayout -Path $Path -AllowUserConfig:$AllowUserConfig -AllowInstalledAssets:$AllowInstalledAssets -AllowNativeSystemSkills:$AllowNativeSystemSkills -AllowIsolatedHostConfig:$AllowIsolatedHostConfig
}

$script:InstalledFixtureWorkspaces = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:InstalledFixtureDriftInjected = $false
function Write-InstalledFixtureEvent([string]$Event) {
    [IO.File]::AppendAllText($env:HOST_BENCHMARK_TEST_LOG,("installed:$Event`n"),[Text.UTF8Encoding]::new($false))
}
function Invoke-InstalledDesktopRolloutPromotion {
    param([string]$RepoRoot,[string]$Workspace,[string]$EligibilityReportPath,[string]$SourceRevision)
    Write-InstalledFixtureEvent ("promote:" + (Split-Path -Leaf (Split-Path -Parent $Workspace)))
    $report = [IO.File]::ReadAllText($EligibilityReportPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 20
    if ([string]$report.status -cne 'pass' -or [string]$report.source_revision -cne $SourceRevision -or [string]$report.report_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'fixture rollout report was not eligible or source-bound' }
    $script:InstalledFixtureReportDigest = [string]$report.report_digest
    $fileDigest = 'sha256:' + (Get-FileHash -LiteralPath $EligibilityReportPath -Algorithm SHA256).Hash.ToLowerInvariant()
    return [ordered]@{status='pass';source_revision=$SourceRevision;report_digest=$script:InstalledFixtureReportDigest;file_digest=$fileDigest}
}
function Invoke-InstalledDesktopInstall {
    param([string]$CodexHome,[string]$Workspace,[string]$RepoRoot)
    $label = Split-Path -Leaf (Split-Path -Parent $Workspace)
    Write-InstalledFixtureEvent "install:$label"
    Write-InstalledFixtureEvent "verify:$label"
    [void]$script:InstalledFixtureWorkspaces.Add([IO.Path]::GetFullPath($Workspace).TrimEnd('\'))
    return [ordered]@{install_status='pass';verification_status='pass';hook_installed='verified';auth_unchanged=$true}
}
function Invoke-InstalledDesktopRouteProbe {
    param([string]$Protocol,[string]$Workspace)
    $label = Split-Path -Leaf (Split-Path -Parent $Workspace)
    Write-InstalledFixtureEvent "route:$label"
    if ($Protocol -ceq 'v2') { return [ordered]@{requested_protocol='auto';selected_protocol='v2';detected_protocol='new';reason='eligible-rollout-report';rollout_status='pass';report_digest=$script:InstalledFixtureReportDigest} }
    return [ordered]@{requested_protocol='auto';selected_protocol='v1';detected_protocol='v1';reason='existing-v1-plan';rollout_status='not-required';report_digest=$null}
}
function Test-InstalledDesktopWorkspaceRegistered {
    param([string]$CodexHome,[string]$Workspace)
    return $script:InstalledFixtureWorkspaces.Contains([IO.Path]::GetFullPath($Workspace).TrimEnd('\'))
}
function Invoke-InstalledDesktopTrialCleanup {
    param([string]$CodexHome,[string]$Workspace,[string]$RepoRoot)
    $label = Split-Path -Leaf (Split-Path -Parent $Workspace)
    Write-InstalledFixtureEvent "cleanup:$label"
    $mode = [string]$env:HOST_BENCHMARK_TEST_MODE
    if (-not $script:InstalledFixtureDriftInjected -and $mode -ceq 'installed-cleanup-auth-drift') {
        $script:InstalledFixtureDriftInjected = $true
        [IO.File]::WriteAllText((Join-Path $CodexHome 'auth.json'),'{"fixture":"changed"}',[Text.UTF8Encoding]::new($false))
        throw 'host-benchmark-installed-uninstall-changed-auth'
    }
    if (-not $script:InstalledFixtureDriftInjected -and $mode -ceq 'installed-cleanup-config-drift') {
        $script:InstalledFixtureDriftInjected = $true
        [IO.File]::WriteAllText((Join-Path $CodexHome 'config.toml'),'model = "changed"',[Text.UTF8Encoding]::new($false))
    }
    [void]$script:InstalledFixtureWorkspaces.Remove([IO.Path]::GetFullPath($Workspace).TrimEnd('\'))
    return $true
}

function Write-StubUtf8 {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Initialize-StubTrialEvidence {
    param([string]$Protocol,[int]$Trial,[hashtable]$Named,[string]$Mode)
    $trialRoot = Join-Path ([string]$Named.ScratchRoot) ("$Protocol-$Trial")
    if ($Mode -ceq 'missing-workspace' -and $Protocol -ceq 'v2' -and $Trial -eq 1) { return '' }
    $workspace = Join-Path $trialRoot 'workspace'
    [void][IO.Directory]::CreateDirectory($trialRoot)
    $templateName = if ($Protocol -ceq 'v1') { 'workspace-v1' } else { 'workspace-direct' }
    $workspaceTemplate = Join-Path $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT $templateName
    Copy-Item -LiteralPath $workspaceTemplate -Destination $workspace -Recurse -Force -ErrorAction Stop
    $baseline = (@(Invoke-HostGit -Root $workspace -Arguments @('rev-parse','HEAD')) -join '').Trim()
    Write-StubUtf8 (Join-Path $workspace 'src\value.txt') 'beta'
    if ($Mode -ceq 'wrong-target-bytes' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        Write-StubUtf8 (Join-Path $workspace 'src\value.txt') "beta`n"
    }
    if ($Mode -ceq 'advanced-head' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        [void](Invoke-HostGit -Root $workspace -Arguments @('add','--','src/value.txt'))
        [void](Invoke-HostGit -Root $workspace -Arguments @('commit','--quiet','--no-gpg-sign','-m','unexpected model commit'))
    }
    if ($Mode -ceq 'linked-target' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        $externalTarget = Join-Path $trialRoot 'external-value.txt'
        Write-StubUtf8 $externalTarget 'beta'
        Remove-Item -LiteralPath (Join-Path $workspace 'src\value.txt') -Force
        [void](New-Item -ItemType HardLink -Path (Join-Path $workspace 'src\value.txt') -Target $externalTarget -ErrorAction Stop)
    }
    if ($Mode -ceq 'junction-target' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        $externalSource = Join-Path $trialRoot 'external-src'
        Write-StubUtf8 (Join-Path $externalSource 'value.txt') 'beta'
        Remove-Item -LiteralPath (Join-Path $workspace 'src') -Recurse -Force
        [void](New-Item -ItemType Junction -Path (Join-Path $workspace 'src') -Target $externalSource -ErrorAction Stop)
    }
    if ($Protocol -ceq 'v1') {
        Write-StubUtf8 (Join-Path $workspace 'docs\tasks\host-benchmark-fixed-workflow\plan.md') 'stage: DONE'
        Write-StubUtf8 (Join-Path $workspace 'docs\tasks\host-benchmark-fixed-workflow\test.md') 'STATUS: PASS'
        if ($Mode -ceq 'wrong-artifact-path') {
            Write-StubUtf8 (Join-Path $workspace 'docs\tasks\host-benchmark-fixed-workflow\unexpected.json') '{}'
        } else {
            Write-StubUtf8 (Join-Path $workspace 'docs\tasks\host-benchmark-fixed-workflow\skill-manifest.json') '{}'
        }
        Write-StubUtf8 (Join-Path $workspace '.assistant\运行时\当前任务.md') 'done current'
        Write-StubUtf8 (Join-Path $workspace '.assistant\运行时\恢复索引.md') 'done index'
        Write-StubUtf8 (Join-Path $workspace '.assistant\运行时\tasks\host-benchmark-fixed-workflow.md') 'done task'
    }
    $v2Artifact = $Protocol -ceq 'v2' -and (
        $Mode -ceq 'v2-artifact' -or
        $Mode -ceq 'unavailable-completed-violation' -or
        ($Mode -ceq 'same-protocol-mixed' -and $Trial -eq 2) -or
        ($Mode -ceq 'same-record-mixed' -and $Trial -eq 1)
    )
    if ($v2Artifact) { Write-StubUtf8 (Join-Path $workspace 'docs\tasks\unexpected\plan.md') 'unexpected' }
    if ($Mode -ceq 'staged-only' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        Write-StubUtf8 (Join-Path $workspace 'staged-only.txt') 'index-only'
        [void](Invoke-HostGit -Root $workspace -Arguments @('add','--','staged-only.txt'))
        Write-StubUtf8 (Join-Path $workspace 'staged-only.txt') 'baseline'
    }
    if ($Mode -ceq 'hidden-index-flag' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        [void](Invoke-HostGit -Root $workspace -Arguments @('update-index','--assume-unchanged','staged-only.txt'))
        Write-StubUtf8 (Join-Path $workspace 'staged-only.txt') 'hidden unexpected write'
    }
    if ([Convert]::ToBoolean($Named.SourceBindingRequired)) {
        $sourceRoot = Join-Path $trialRoot 'source'
        Copy-Item -LiteralPath (Join-Path $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT 'source') -Destination $sourceRoot -Recurse -Force -ErrorAction Stop
        $templateRevision = (@(Invoke-HostGit -Root $sourceRoot -Arguments @('rev-parse','HEAD')) -join '').Trim()
        if ($templateRevision -cne [string]$Named.SourceRevision) { throw 'fixture source template revision mismatch' }
        if ($Mode -ceq 'ignored-source' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
            Write-StubUtf8 (Join-Path $sourceRoot '.assistant\tamper.txt') 'ignored source tamper'
        }
    }
    return $baseline
}
function Invoke-HostTrial {
    param(
        [Parameter(Mandatory)][string]$Protocol,
        [Parameter(Mandatory)][int]$Trial,
        [Parameter(ValueFromRemainingArguments=$true)][object[]]$Remaining
    )
    $named = @{}
    for ($index=0; $index -lt $Remaining.Count; $index++) {
        $item = [string]$Remaining[$index]
        if ($item.StartsWith('-') -and $index + 1 -lt $Remaining.Count) { $named[$item.TrimStart('-')] = $Remaining[++$index] }
    }
    [IO.File]::AppendAllText($env:HOST_BENCHMARK_TEST_LOG,("{0}{1}`n" -f $Protocol,$Trial),[Text.UTF8Encoding]::new($false))
    $mode = [string]$env:HOST_BENCHMARK_TEST_MODE
    if ([string]$named.BenchmarkPath -ceq 'cognitive-fast-path') {
        $actualCodexHome = [IO.Path]::GetFullPath([string]$named.CodexHome).TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($env:HOST_BENCHMARK_TEST_EXPECTED_CODEX_HOME) -or $actualCodexHome -cne $env:HOST_BENCHMARK_TEST_EXPECTED_CODEX_HOME) { throw 'fixture-cognitive-home-not-forwarded' }
        $configPath = Join-Path $actualCodexHome 'config.toml'
        $configItem = Get-Item -LiteralPath $configPath -Force -ErrorAction Stop
        $ownerCount = @(Get-ChildItem -LiteralPath $actualCodexHome -Force | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigOwnerPrefix,[StringComparison]::Ordinal) }).Count
        if ($ownerCount -ne 1 -or ($configItem.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0 -or -not (Test-HostExactUtf8File -Path $configPath -ExpectedText "# isolated host benchmark sentinel`n")) { throw 'fixture-cognitive-sentinel-not-active' }
    }
    if ($mode -ceq 'cognitive-sentinel-tamper' -and $Protocol -ceq 'bare' -and $Trial -eq 1) {
        $configPath = Join-Path ([string]$named.CodexHome) 'config.toml'
        [IO.File]::SetAttributes($configPath,[IO.FileAttributes]::Normal)
        [IO.File]::WriteAllText($configPath,'tampered by fixture',[Text.UTF8Encoding]::new($false))
    }
    if ($mode -ceq 'exception' -and $Protocol -ceq 'v2' -and $Trial -eq 1) { throw 'host-benchmark-auth-home-unavailable' }
    $baseline = Initialize-StubTrialEvidence -Protocol $Protocol -Trial $Trial -Named $named -Mode $mode
    $unavailable = $mode -cin @('unavailable','unavailable-completed-violation','unavailable-direct-sessions') -and $Protocol -ceq 'v2' -and $Trial -eq 1
    $sendUnavailable = $mode -cin @('unavailable','unavailable-completed-violation','unavailable-direct-sessions','send-unavailable','mixed-fail-unavailable','same-protocol-mixed','same-record-mixed') -and $Protocol -ceq 'v2' -and $Trial -eq 1
    $v2Artifact = $Protocol -ceq 'v2' -and ($mode -cin @('v2-artifact','unavailable-completed-violation') -or ($mode -ceq 'same-protocol-mixed' -and $Trial -eq 2) -or ($mode -ceq 'same-record-mixed' -and $Trial -eq 1))
    $artifactWrites = if ($v2Artifact) { 1 } elseif ($Protocol -ceq 'v1') { 3 } else { 0 }
    $runtimeWrites = if ($Protocol -ceq 'v1') { 3 } else { 0 }
    $requests = if ($Protocol -ceq 'v1') { 10 } elseif ($Protocol -ceq 'v2') { 2 } else { 4 }
    $duration = if ($Protocol -ceq 'v1') { 500 } elseif ($Protocol -ceq 'v2' -and $mode -ceq 'latency-fail') { 200 } elseif ($Protocol -ceq 'v2') { 110 } else { 100 }
    $revision = [string]$named.SourceRevision
    $tree = [string]$named.SourceCommitTree
    if ($mode -ceq 'bad-source' -and $Protocol -ceq 'v2') { $revision = '0' * 40 }
    $freshSessions = if ($Protocol -ceq 'v1') { 5 } else { 1 }
    if ($mode -cin @('direct-sessions','unavailable-direct-sessions') -and $Protocol -ceq 'v2') { $freshSessions = 2 }
    $journal = if ($Protocol -ceq 'v1') { @('PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE') } else { @() }
    if ($mode -ceq 'v1-journal' -and $Protocol -ceq 'v1') { $journal = @('PLAN_REVIEW','IMPLEMENT','TEST','DONE') }
    $targetJournal = if ($Protocol -ceq 'v1') { @('alpha','alpha','beta','beta','beta') } else { @() }
    if ($mode -cin @('v1-target','mixed-fail-unavailable') -and $Protocol -ceq 'v1') { $targetJournal = @('alpha','beta','beta','beta','beta') }
    $recordTrial = if ($mode -ceq 'wrong-trial-number' -and $Protocol -ceq 'v2' -and $Trial -eq 1) { 2 } else { $Trial }
    $installedDesktop = $null
    if ([string]$named.BenchmarkPath -ceq 'installed-desktop-path') {
        $profileConfig = Get-InstalledDesktopUserConfigBinding -CodexHome ([string]$named.CodexHome)
        if ($Protocol -ceq 'bare') {
            $installedDesktop = [ordered]@{benchmark_path='installed-desktop-path';host_surface='codex-cli-host-equivalent';user_config_mode='loaded';protocol_environment='cleared';profile_config=$profileConfig;install_status='not-applicable';verification_status='not-applicable';auth_unchanged=$true;cleanup_status='not-required';hook_installed='not-applicable';hook_trust='unknown';hook_callability='unknown';route_probe=$null;rollout_promotion=$null}
        } else {
            $workspace = Join-Path (Join-Path ([string]$named.ScratchRoot) ("$Protocol-$Trial")) 'workspace'
            $promotion = Invoke-InstalledDesktopRolloutPromotion -RepoRoot ([string]$named.RepoRoot) -Workspace $workspace -EligibilityReportPath ([string]$named.EligibilityReportPath) -SourceRevision $revision
            $installation = Invoke-InstalledDesktopInstall -CodexHome ([string]$named.CodexHome) -Workspace $workspace -RepoRoot ([string]$named.RepoRoot)
            $route = Invoke-InstalledDesktopRouteProbe -Protocol $Protocol -Workspace $workspace
            $installedDesktop = [ordered]@{benchmark_path='installed-desktop-path';host_surface='codex-cli-host-equivalent';user_config_mode='loaded';protocol_environment='cleared';profile_config=$profileConfig;install_status=$installation.install_status;verification_status=$installation.verification_status;auth_unchanged=$installation.auth_unchanged;cleanup_status='passed';hook_installed=$installation.hook_installed;hook_trust='unknown';hook_callability='unknown';route_probe=$route;rollout_promotion=$promotion}
        }
    }
    $record = [ordered]@{
        trial=$recordTrial;workspace_baseline_revision=$baseline;status=$(if($unavailable){'unavailable'}else{'measured'});diagnostic=$(if($unavailable){'otel-trace-missing'}else{$null});completion_passed=(-not $unavailable);outcome='completed';reason_code='completed'
        workflow_contract=$(if($Protocol-ceq'v1'){'confirmed-plan-to-done'}else{'new-task'});workflow_completed=$true;fresh_sessions=$freshSessions
        v1_stage_journal=$journal;v1_target_journal=$targetJournal;v1_validator_passed=$true
        source_binding=[ordered]@{status='bound';revision=$revision;commit_tree_oid=$tree;verification='git-head-tree-clean/v1';reason='fixture source binding'}
        host_turns=[ordered]@{status='measured';value=$(if($Protocol-ceq'v1'){5}else{1});basis='codex-jsonl-turn.started';reason='fixture'}
        successful_request_sends=[ordered]@{status=$(if($sendUnavailable){'unavailable'}else{'measured'});value=$(if($sendUnavailable){$null}else{$requests});basis='codex-0.144.4-successful-websocket-send/v2';reason='fixture'}
        completed_agent_messages=1;total_duration_ms=$duration;sum_codex_process_duration_ms=$duration;first_useful_action_ms=10
        tool_calls=[ordered]@{command=1;mcp=0;web_search=0;file_change=1;total=2}
        loaded_skills=[ordered]@{status='unavailable';value=$null;reason='fixture'};skill_file_command_matches=[ordered]@{status='measured';value=0;reason='fixture'};loaded_files=[ordered]@{status='unavailable';value=$null;reason='fixture'}
        artifact_writes=$artifactWrites;runtime_writes=$runtimeWrites;unexpected_writes=0;raw_trace_deleted=$(if($mode-ceq'raw-trace' -and $Protocol-ceq'v2'){$false}else{$true});post_trial_diagnostics=@()
        tokens=[ordered]@{status='measured';input=1;cached_input=0;output=1}
    }
    if ($null -ne $installedDesktop) { $record['installed_desktop'] = $installedDesktop }
    return $record
}
'@
    Write-Utf8 (Join-Path $fixture 'scripts\host-benchmark\HostBenchmark.Trial.ps1') $stub
    Commit-GitFixture $fixture

    $templateRoot = Join-Path $scratch 'trial-templates'
    foreach ($templateName in @('workspace-direct','workspace-v1')) {
        $workspaceTemplate = Join-Path $templateRoot $templateName
        Initialize-GitFixture $workspaceTemplate
        [void](Invoke-Git $workspaceTemplate @('config','core.hooksPath','NUL'))
        [void](Invoke-Git $workspaceTemplate @('config','core.longpaths','true'))
        [void](Invoke-Git $workspaceTemplate @('config','user.name','Harness Fixture'))
        [void](Invoke-Git $workspaceTemplate @('config','user.email','harness-fixture@example.invalid'))
        Write-Utf8 (Join-Path $workspaceTemplate 'src\value.txt') 'alpha'
        Write-Utf8 (Join-Path $workspaceTemplate 'staged-only.txt') 'baseline'
        if ($templateName -ceq 'workspace-v1') {
            Write-Utf8 (Join-Path $workspaceTemplate 'docs\tasks\host-benchmark-fixed-workflow\plan.md') 'stage: PLAN'
            Write-Utf8 (Join-Path $workspaceTemplate '.assistant\运行时\当前任务.md') 'initial current'
            Write-Utf8 (Join-Path $workspaceTemplate '.assistant\运行时\恢复索引.md') 'initial index'
            Write-Utf8 (Join-Path $workspaceTemplate '.assistant\运行时\tasks\host-benchmark-fixed-workflow.md') 'initial task'
        }
        Commit-GitFixture $workspaceTemplate
    }
    $sourceTemplate = Join-Path $templateRoot 'source'
    $templateCloneOutput = @(& git -c core.longpaths=true clone --no-local --no-checkout --quiet -- $fixture $sourceTemplate 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "fixture source template clone failed: $($templateCloneOutput -join ' | ')" }
    [void](Invoke-Git $sourceTemplate @('config','core.longpaths','true'))
    $fixtureRevision = (@(Invoke-Git $fixture @('rev-parse','HEAD')) -join '').Trim()
    [void](Invoke-Git $sourceTemplate @('-c','core.hooksPath=NUL','checkout','--quiet','--detach',$fixtureRevision,'--'))
    $script:hostBenchmarkTemplateRoot = $templateRoot
    $script:hostBenchmarkCognitiveHome = Join-Path $scratch 'fixture-cognitive-home'
    Write-Utf8 (Join-Path $script:hostBenchmarkCognitiveHome 'auth.json') '{"fixture":"cognitive-runner"}'
    $templateDigestBefore = Get-DirectoryContentDigest -Root $templateRoot
    $copyProbe = Join-Path $scratch 'template-copy-probe'
    Copy-Item -LiteralPath (Join-Path $templateRoot 'workspace-direct') -Destination $copyProbe -Recurse -Force
    $templateIdentity = Get-HostFileSystemIdentity -Path (Join-Path $templateRoot 'workspace-direct\src\value.txt')
    $copyIdentity = Get-HostFileSystemIdentity -Path (Join-Path $copyProbe 'src\value.txt')
    Check ([string]$templateIdentity.volume -cne [string]$copyIdentity.volume -or [string]$templateIdentity.file_id -cne [string]$copyIdentity.file_id) 'workspace template copy reused the source file identity'
    Write-Utf8 (Join-Path $copyProbe 'src\value.txt') 'beta'
    Check (Test-HostExactUtf8File -Path (Join-Path $templateRoot 'workspace-direct\src\value.txt') -ExpectedText 'alpha') 'workspace template changed through a copied trial file'
    Remove-Item -LiteralPath $copyProbe -Recurse -Force

    $authBytesBefore = [IO.File]::ReadAllBytes((Join-Path $authHome 'auth.json'))
    $overlapOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $fixture 'scripts\run-host-benchmark.ps1') -RepoRoot $fixture -OutputPath (Join-Path $authHome 'auth.json') -CodexHome $authHome -Trials 1 -MaxRoundTrips 1 -TimeoutSeconds 30 2>&1 | ForEach-Object { [string]$_ })
    $overlapExit = $LASTEXITCODE
    $authBytesAfter = [IO.File]::ReadAllBytes((Join-Path $authHome 'auth.json'))
    Check ($overlapExit -ne 0 -and ($overlapOutput -join "`n") -match 'must not overlap the dedicated Codex home' -and [Convert]::ToHexString($authBytesAfter) -ceq [Convert]::ToHexString($authBytesBefore)) 'report output was allowed to overlap or replace the dedicated auth home'

    $outputAlias = Join-Path $scratch 'output-auth-alias'
    [void](New-Item -ItemType Junction -Path $outputAlias -Target $authHome -ErrorAction Stop)
    try {
        $aliasOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $fixture 'scripts\run-host-benchmark.ps1') -RepoRoot $fixture -OutputPath (Join-Path $outputAlias 'auth.json') -CodexHome $authHome -Trials 1 -MaxRoundTrips 1 -TimeoutSeconds 30 2>&1 | ForEach-Object { [string]$_ })
        $aliasExit = $LASTEXITCODE
        $authBytesAfterAlias = [IO.File]::ReadAllBytes((Join-Path $authHome 'auth.json'))
        Check ($aliasExit -ne 0 -and ($aliasOutput -join "`n") -match 'link-alias-rejected|must not overlap' -and [Convert]::ToHexString($authBytesAfterAlias) -ceq [Convert]::ToHexString($authBytesBefore)) 'physical output alias reached or replaced the dedicated auth home'
    } finally {
        Remove-Item -LiteralPath $outputAlias -Force
    }

    $externalScratch = Join-Path $scratch 'external-scratch-target'
    Write-Utf8 (Join-Path $externalScratch 'marker.txt') 'preserve'
    $scratchJunction = Join-Path $fixture '.assistant'
    [void](New-Item -ItemType Junction -Path $scratchJunction -Target $externalScratch -ErrorAction Stop)
    try {
        $junctionOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $fixture 'scripts\run-host-benchmark.ps1') -RepoRoot $fixture -OutputPath (Join-Path $scratch 'scratch-junction-report.json') -Trials 1 -MaxRoundTrips 1 -TimeoutSeconds 30 2>&1 | ForEach-Object { [string]$_ })
        $junctionExit = $LASTEXITCODE
        Check ($junctionExit -ne 0 -and ($junctionOutput -join "`n") -match 'reparse point' -and (Test-Path -LiteralPath (Join-Path $externalScratch 'marker.txt') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $externalScratch '运行时'))) 'scratch junction escaped the repository or modified its external target'
    } finally {
        Remove-Item -LiteralPath $scratchJunction -Force
    }

    $rogueCognitiveHome = Join-Path $scratch 'fixture-cognitive-rogue-home'
    Write-Utf8 (Join-Path $rogueCognitiveHome 'auth.json') '{"fixture":"cognitive-rogue"}'
    Write-Utf8 (Join-Path $rogueCognitiveHome 'config.toml') 'model = "foreign"'
    $rogueCognitiveDigest = (Get-FileHash -LiteralPath (Join-Path $rogueCognitiveHome 'config.toml') -Algorithm SHA256).Hash
    $rogueCognitive = Invoke-FixtureRunner -Fixture $fixture -OutputRoot $scratch -Mode 'cognitive-rogue-config' -Trials 1 -Groups 1 -CodexHome $rogueCognitiveHome
    Check ($rogueCognitive.ExitCode -ne 0 -and $null -eq $rogueCognitive.Report -and ($rogueCognitive.Output -join "`n") -match 'host-benchmark-auth-home-not-isolated' -and @($rogueCognitive.Order | Where-Object { $_ -match '^(?:bare|v1|v2)\d+$' }).Count -eq 0 -and (Get-FileHash -LiteralPath (Join-Path $rogueCognitiveHome 'config.toml') -Algorithm SHA256).Hash -ceq $rogueCognitiveDigest) 'cognitive runner accepted or overwrote a foreign config.toml'

    $tamperCognitiveHome = Join-Path $scratch 'fixture-cognitive-tamper-home'
    Write-Utf8 (Join-Path $tamperCognitiveHome 'auth.json') '{"fixture":"cognitive-tamper"}'
    $tamperCognitive = Invoke-FixtureRunner -Fixture $fixture -OutputRoot $scratch -Mode 'cognitive-sentinel-tamper' -Trials 1 -Groups 1 -CodexHome $tamperCognitiveHome
    $tamperCognitiveConfig = Join-Path $tamperCognitiveHome 'config.toml'
    $tamperCognitiveOwners = @(Get-ChildItem -LiteralPath $tamperCognitiveHome -Force | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigOwnerPrefix,[StringComparison]::Ordinal) })
    Check ($tamperCognitive.ExitCode -ne 0 -and $null -eq $tamperCognitive.Report -and ($tamperCognitive.Output -join "`n") -match 'host-benchmark-auth-home-config-sentinel-changed' -and $tamperCognitive.Order -contains 'bare1' -and (Test-Path -LiteralPath $tamperCognitiveConfig -PathType Leaf) -and $tamperCognitiveOwners.Count -eq 1 -and [IO.File]::ReadAllText($tamperCognitiveConfig) -ceq 'tampered by fixture') 'cognitive runner deleted or accepted a tampered runner sentinel or owner evidence'
    Remove-Item -LiteralPath $tamperCognitiveConfig -Force
    [IO.Directory]::Delete($tamperCognitiveOwners[0].FullName,$false)

    $pass = Invoke-FixtureRunner $fixture $scratch 'pass' 3 3
    $expectedOrder = @(
        'bare1','v11','v21','v12','v22','bare2','v23','bare3','v13',
        'v11','v21','bare1','v22','bare2','v12','bare3','v13','v23',
        'v21','bare1','v11','bare2','v12','v22','v13','v23','bare3'
    )
    $passQualified = $pass.ExitCode -eq 0 -and $null -ne $pass.Report -and [bool]$pass.Report.performance.eligible
    Check $passQualified 'three independent clean 3x3 groups did not qualify'
    Check (-not (Test-Path -LiteralPath (Join-Path $script:hostBenchmarkCognitiveHome 'config.toml')) -and @(Get-ChildItem -LiteralPath $script:hostBenchmarkCognitiveHome -Force | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigOwnerPrefix,[StringComparison]::Ordinal) }).Count -eq 0) 'successful cognitive runner retained its runner-created config sentinel or owner marker'
    Check (@(Compare-Object $expectedOrder $pass.Order -SyncWindow 0).Count -eq 0) 'independent-group rotating execution order changed'
    Check (@($pass.Report.groups).Count -eq 3 -and @($pass.Report.groups | Where-Object { @($_.execution.actual_trial_order).Count -eq 9 }).Count -eq 3) 'grouped 3x3 report omitted group or execution-order records'
    Check (@($pass.Report.groups.group_run_id | Sort-Object -Unique).Count -eq 3 -and @($pass.Report.groups.group_root_digest | Sort-Object -Unique).Count -eq 3) 'grouped 3x3 report reused a group id or namespace root'
    Check (@($pass.Report.groups | Where-Object { [bool]$_.source_state_stable -and [bool]$_.source.input_head_binding.start -and [bool]$_.source.input_head_binding.end }).Count -eq 3) 'grouped 3x3 report omitted independent clean source start/end bindings'
    Check ([string]$pass.Report.source.execution_mode -ceq 'clean-commit-clone' -and [string]$pass.Report.source.commit_tree_oid -match '^[0-9a-f]{40,64}$') 'clean report omitted native commit source identity'
    Check ([bool]$pass.Report.source.input_head_binding.start -and [bool]$pass.Report.source.input_head_binding.end) 'clean report did not bind live execution inputs to HEAD blobs'

    $installedEligibilityReport = Join-Path $scratch 'installed-eligible-report.json'
    Write-Utf8 $installedEligibilityReport (([ordered]@{schema_version='fixture-rollout-report/v1';status='pass';source_revision=$fixtureRevision;report_digest=('sha256:' + ('b' * 64))}) | ConvertTo-Json -Compress)
    $installedEligibilityFileDigest = 'sha256:' + (Get-FileHash -LiteralPath $installedEligibilityReport -Algorithm SHA256).Hash.ToLowerInvariant()
    $installedPassProfile = Join-Path $scratch 'installed-runner-pass-profile'
    $installedPassHome = Join-Path $installedPassProfile '.codex'
    Write-Utf8 (Join-Path $installedPassHome 'auth.json') '{"fixture":"installed-runner-pass"}'
    Write-Utf8 (Join-Path $installedPassHome 'config.toml') 'model = "fixture"'
    $installedPass = Invoke-FixtureRunner -Fixture $fixture -OutputRoot $scratch -Mode 'installed-pass' -Trials 3 -Groups 3 -BenchmarkPath 'installed-desktop-path' -CodexHome $installedPassHome -EligibilityReportPath $installedEligibilityReport
    Check ($installedPass.ExitCode -eq 2 -and $null -ne $installedPass.Report -and [string]$installedPass.Report.schema_version -ceq 'harness-installed-desktop-benchmark-report/v1' -and [string]$installedPass.Report.qualification.status -ceq 'unavailable' -and [string]$installedPass.Report.status -ceq 'unavailable' -and -not [bool]$installedPass.Report.performance.eligible -and [bool]$installedPass.Report.performance.measurement_passed -and [int]$installedPass.Report.performance.measurement_passed_groups -eq 3 -and [string]$installedPass.Report.execution.host_surface -ceq 'codex-cli-host-equivalent' -and [string]$installedPass.Report.execution.rollout_report_digest -ceq ('sha256:' + ('b' * 64)) -and [string]$installedPass.Report.execution.rollout_report_file_digest -ceq $installedEligibilityFileDigest) 'installed Desktop 3x3 measurement did not remain qualification-unavailable with exact rollout bindings and exit 2'
    $installedEvents = @($installedPass.Order | Where-Object { $_ -like 'installed:*' })
    Check (@($installedEvents | Where-Object { $_ -like 'installed:promote:*' }).Count -eq 18 -and @($installedEvents | Where-Object { $_ -like 'installed:install:*' }).Count -eq 18 -and @($installedEvents | Where-Object { $_ -like 'installed:verify:*' }).Count -eq 18 -and @($installedEvents | Where-Object { $_ -like 'installed:route:*' }).Count -eq 18 -and @($installedEvents | Where-Object { $_ -like 'installed:cleanup:*' }).Count -eq 18) 'installed Desktop fixture did not execute the full promotion/install/verify/route/cleanup chain'

    foreach ($driftMode in @('installed-cleanup-auth-drift','installed-cleanup-config-drift')) {
        $driftProfile = Join-Path $scratch ("$driftMode-profile")
        $driftHome = Join-Path $driftProfile '.codex'
        Write-Utf8 (Join-Path $driftHome 'auth.json') ("{`"fixture`":`"$driftMode`"}")
        Write-Utf8 (Join-Path $driftHome 'config.toml') 'model = "fixture"'
        $drift = Invoke-FixtureRunner -Fixture $fixture -OutputRoot $scratch -Mode $driftMode -Trials 3 -Groups 3 -BenchmarkPath 'installed-desktop-path' -CodexHome $driftHome -EligibilityReportPath $installedEligibilityReport
        $driftTrials = @($drift.Order | Where-Object { $_ -match '^(?:bare|v1|v2)\d+$' })
        Check ($drift.ExitCode -eq 1 -and $null -eq $drift.Report -and ($driftTrials -join ',') -ceq 'bare1,v11' -and @($drift.Order | Where-Object { $_ -like 'installed:cleanup:*' }).Count -eq 1) "$driftMode did not fail and stop before the next installed Desktop trial"
    }

    foreach ($case in @(
        [pscustomobject]@{Mode='wrong-target-bytes';Message='Runner accepted non-exact target bytes reported as complete'},
        [pscustomobject]@{Mode='advanced-head';Message='Runner accepted a model-created workspace commit'},
        [pscustomobject]@{Mode='ignored-source';Message='Runner accepted ignored tamper in the independent source checkout'},
        [pscustomobject]@{Mode='linked-target';Message='Runner accepted a hard-linked target outside the workspace'},
        [pscustomobject]@{Mode='junction-target';Message='Runner accepted a junction-backed target outside the workspace'},
        [pscustomobject]@{Mode='hidden-index-flag';Message='Runner accepted a write hidden by an unsafe Git index flag'}
    )) {
        $result = Invoke-FixtureRunner $fixture $scratch $case.Mode 1
        $v2Trial = if ($null -eq $result.Report) { $null } else { @($result.Report.groups[0].protocols.v2.trials)[0] }
        Check ($result.ExitCode -eq 1 -and $null -ne $v2Trial -and -not [bool]$v2Trial.runner_evidence_passed) $case.Message
    }

    $single = Invoke-FixtureRunner $fixture $scratch 'single' 1
    Check ($single.ExitCode -eq 1 -and $null -ne $single.Report -and -not [bool]$single.Report.performance.eligible -and [string]$single.Report.status -ceq 'fail') 'Trials=1 was allowed to satisfy release eligibility'

    foreach ($case in @(
        [pscustomobject]@{Mode='v2-artifact';Protocol='v2';Message='v2 artifact write was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='bad-source';Protocol='v2';Message='source identity mismatch was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='raw-trace';Protocol='v2';Message='retained raw trace was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='v1-journal';Protocol='v1';Message='invalid v1 stage journal was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='v1-target';Protocol='v1';Message='invalid v1 target timing was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='direct-sessions';Protocol='v2';Message='multi-session Direct trial was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='missing-workspace';Protocol='v2';Message='self-reported trial without workspace evidence was accepted'},
        [pscustomobject]@{Mode='wrong-artifact-path';Protocol='v1';Message='same artifact count with a wrong path was accepted'},
        [pscustomobject]@{Mode='staged-only';Protocol='v2';Message='staged-only unexpected write was accepted'},
        [pscustomobject]@{Mode='wrong-trial-number';Protocol='v2';Message='trial record number was not bound to the outer trial'}
    )) {
        $result = Invoke-FixtureRunner $fixture $scratch $case.Mode 1
        $protocolRecord = if ($null -eq $result.Report) { $null } else { $result.Report.groups[0].protocols.([string]$case.Protocol) }
        Check ($result.ExitCode -eq 1 -and $null -ne $protocolRecord -and [int]$protocolRecord.runner_contract_failures -gt 0 -and -not [bool]$result.Report.performance.eligible) $case.Message
    }

    $unavailable = Invoke-FixtureRunner $fixture $scratch 'unavailable' 3 3
    Check ($unavailable.ExitCode -eq 2 -and $null -ne $unavailable.Report -and -not [bool]$unavailable.Report.performance.eligible -and [string]$unavailable.Report.status -ceq 'unavailable') 'request measurement unavailable did not deterministically exit 2'
    $sendUnavailable = Invoke-FixtureRunner $fixture $scratch 'send-unavailable' 3
    Check ($sendUnavailable.ExitCode -eq 1 -and $null -ne $sendUnavailable.Report -and [string]$sendUnavailable.Report.groups[0].status -ceq 'unavailable' -and [string]$sendUnavailable.Report.status -ceq 'fail') 'single diagnostic group did not retain request-send unavailability under the release group-count failure'
    $mixedFailure = Invoke-FixtureRunner $fixture $scratch 'mixed-fail-unavailable' 3
    Check ($mixedFailure.ExitCode -eq 1 -and $null -ne $mixedFailure.Report -and [string]$mixedFailure.Report.status -ceq 'fail') 'known contract failure was masked by an unavailable measurement'
    $sameProtocolFailure = Invoke-FixtureRunner $fixture $scratch 'same-protocol-mixed' 3
    Check ($sameProtocolFailure.ExitCode -eq 1 -and $null -ne $sameProtocolFailure.Report -and [string]$sameProtocolFailure.Report.status -ceq 'fail') 'same-protocol contract failure was masked by an unavailable measurement'
    $sameRecordFailure = Invoke-FixtureRunner $fixture $scratch 'same-record-mixed' 3
    Check ($sameRecordFailure.ExitCode -eq 1 -and $null -ne $sameRecordFailure.Report -and [string]$sameRecordFailure.Report.status -ceq 'fail') 'same-record contract failure was masked by an unavailable measurement'
    $unavailableCompletedFailure = Invoke-FixtureRunner $fixture $scratch 'unavailable-completed-violation' 3
    Check ($unavailableCompletedFailure.ExitCode -eq 1 -and $null -ne $unavailableCompletedFailure.Report -and [string]$unavailableCompletedFailure.Report.status -ceq 'fail') 'completed contract violation was masked by unavailable request measurement status'
    $unavailableDirectFailure = Invoke-FixtureRunner $fixture $scratch 'unavailable-direct-sessions' 3
    Check ($unavailableDirectFailure.ExitCode -eq 1 -and $null -ne $unavailableDirectFailure.Report -and [string]$unavailableDirectFailure.Report.status -ceq 'fail' -and [bool]$unavailableDirectFailure.Report.groups[0].protocols.v2.trials[0].runner_evidence_passed -and [int]$unavailableDirectFailure.Report.groups[0].protocols.v2.trials[0].fresh_sessions -eq 2 -and -not [bool]$unavailableDirectFailure.Report.groups[0].protocols.v2.trials[0].completion_passed) 'Direct session overrun with valid disk evidence was masked by unavailable request measurement status'

    $exception = Invoke-FixtureRunner $fixture $scratch 'exception' 3
    Check ($exception.ExitCode -eq 1 -and $null -ne $exception.Report -and [string]$exception.Report.groups[0].status -ceq 'unavailable' -and (@($exception.Report.groups[0].protocols.v2.trials | Where-Object {$_.diagnostic -ceq 'isolated-auth-home-unavailable'}).Count -eq 1)) 'trial exception did not produce a sanitized unavailable group'
    Check (-not (Test-Path -LiteralPath (Join-Path $script:hostBenchmarkCognitiveHome 'config.toml')) -and @(Get-ChildItem -LiteralPath $script:hostBenchmarkCognitiveHome -Force | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigOwnerPrefix,[StringComparison]::Ordinal) }).Count -eq 0) 'trial exception retained the runner-created config sentinel, owner marker, or profile lock state'

    $dirtyPath = Join-Path $fixture '目录\未跟踪.txt'
    Write-Utf8 $dirtyPath '诊断'
    $dirty = Invoke-FixtureRunner $fixture $scratch 'latency-fail' 3
    Check ($dirty.ExitCode -eq 1 -and $null -ne $dirty.Report -and [bool]$dirty.Report.source_dirty -and -not [bool]$dirty.Report.source_state_stable -and -not [bool]$dirty.Report.performance.eligible -and [string]$dirty.Report.status -ceq 'fail' -and [string]$dirty.Report.groups[0].performance.direct_latency.status -ceq 'fail' -and [string]$dirty.Report.source.execution_mode -ceq 'live-dirty-diagnostic') 'dirty source with a diagnostic latency failure did not fail closed'
    Remove-Item -LiteralPath (Join-Path $fixture '目录') -Recurse -Force

    $hiddenInput = Join-Path $fixture 'scripts\host-benchmark\HostBenchmark.Otel.ps1'
    [void](Invoke-Git $fixture @('update-index','--assume-unchanged','scripts/host-benchmark/HostBenchmark.Otel.ps1'))
    [IO.File]::AppendAllText($hiddenInput,"`n# hidden execution-input tamper`n",[Text.UTF8Encoding]::new($false))
    $hiddenSource = Invoke-FixtureRunner $fixture $scratch 'pass' 3
    Check ($hiddenSource.ExitCode -eq 1 -and $null -ne $hiddenSource.Report -and [bool]$hiddenSource.Report.source_dirty -and -not [bool]$hiddenSource.Report.source.input_head_binding.start -and [string]$hiddenSource.Report.status -ceq 'fail') 'assume-unchanged live execution input was not detected independently from Git status'
    Check ((Get-DirectoryContentDigest -Root $templateRoot) -ceq $templateDigestBefore) 'shared qualification templates changed during trial execution'
} finally {
    if (Test-Path -LiteralPath $scratch -PathType Container) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

Write-Output "Host benchmark qualification checks: $checks"
if ($failures.Count) { $failures | ForEach-Object { Write-Output "- FAIL: $_" }; exit 1 }
Write-Output "STATUS: PASS ($checks checks)"
exit 0
