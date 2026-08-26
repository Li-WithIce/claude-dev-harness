#!/usr/bin/env pwsh
#requires -Version 7.3
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$OutputPath = '',
    [string]$CodexHome = '',
    [ValidateSet('cognitive-fast-path','installed-desktop-path')][string]$BenchmarkPath = 'cognitive-fast-path',
    [ValidateRange(1,10)][int]$Groups = 1,
    [ValidateRange(1,10)][int]$Trials = 3,
    [ValidateRange(1,12)][int]$MaxRoundTrips = 8,
    [string]$Model = 'gpt-5.6-sol',
    [ValidateSet('max')][string]$Reasoning = 'max',
    [ValidateRange(30,3600)][int]$TimeoutSeconds = 900,
    [switch]$ValidateOnly,
    [switch]$KeepScratch
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$atomicWritePath = Join-Path $PSScriptRoot 'lib\Harness.AtomicWrite.psm1'
$hashingPath = Join-Path $PSScriptRoot 'lib\Harness.Hashing.psm1'
$pathModulePath = Join-Path $PSScriptRoot 'lib\Harness.Path.psm1'
$otelContractPath = Join-Path $PSScriptRoot 'host-benchmark\HostBenchmark.Otel.ps1'
$trialPath = Join-Path $PSScriptRoot 'host-benchmark\HostBenchmark.Trial.ps1'
foreach ($path in @($atomicWritePath,$hashingPath,$pathModulePath,$otelContractPath,$trialPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required host benchmark input is missing: $path" }
}
Import-Module $atomicWritePath -Force -ErrorAction Stop
Import-Module $hashingPath -Force -ErrorAction Stop
Import-Module $pathModulePath -Force -ErrorAction Stop

function Invoke-HostGit {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "host benchmark Git command failed: git $($Arguments -join ' ')" }
    return $output
}

function Get-HostGitState {
    param([Parameter(Mandatory)][string]$Root,[switch]$IncludeIgnored)
    $revision = (@(Invoke-HostGit -Root $Root -Arguments @('rev-parse','--verify','HEAD')) -join '').Trim()
    $tree = (@(Invoke-HostGit -Root $Root -Arguments @('rev-parse',"$revision`^{tree}")) -join '').Trim()
    $objectFormat = (@(Invoke-HostGit -Root $Root -Arguments @('rev-parse','--show-object-format')) -join '').Trim()
    $status = [Collections.Generic.List[string]]::new()
    foreach ($line in @(Invoke-HostGit -Root $Root -Arguments @('-c','core.quotepath=false','status','--porcelain=v1','--untracked-files=all'))) { $status.Add([string]$line) }
    foreach ($line in @(Invoke-HostGit -Root $Root -Arguments @('-c','core.quotepath=false','ls-files','-v','--'))) {
        if ([string]$line -cnotmatch '^H ') { $status.Add('IF ' + [string]$line) }
    }
    if ($IncludeIgnored) {
        foreach ($path in @(Invoke-HostGit -Root $Root -Arguments @('-c','core.quotepath=false','ls-files','--others','--ignored','--exclude-standard','--'))) { $status.Add('!! ' + [string]$path) }
    }
    $statusText = @($status | Sort-Object) -join "`n"
    return [ordered]@{
        revision=$revision
        commit_tree_oid=$tree
        object_format=$objectFormat
        dirty=$status.Count -gt 0
        status_entry_count=$status.Count
        status_digest=Get-HarnessSha256Text -Content $statusText
        state_digest=Get-HarnessSha256Text -Content ("{0}`n{1}`n{2}`n{3}" -f $revision,$tree,$objectFormat,$statusText)
        state_basis=$(if($IncludeIgnored){'git-revision-tree-status-ignored/v1'}else{'git-revision-tree-status/v1'})
    }
}

function Test-HostGitFileMatchesRevision {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Revision)
    try {
        $relative = Get-HarnessRelativePath -WorkspaceRoot $Root -Path $Path
        $expected = (@(Invoke-HostGit -Root $Root -Arguments @('rev-parse',("{0}:{1}" -f $Revision,$relative))) -join '').Trim()
        $actual = (@(Invoke-HostGit -Root $Root -Arguments @('hash-object','--',$relative)) -join '').Trim()
        return $expected -match '^[0-9a-f]{40,64}$' -and $actual -ceq $expected
    } catch { return $false }
}

function Test-HostReportPath {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + '\'
    if (-not $pathFull.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    $relative = [IO.Path]::GetRelativePath($rootFull,$pathFull).Replace('\','/')
    & git -C $rootFull check-ignore --no-index --quiet -- $relative 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-HostMedian {
    param([Parameter(Mandatory)][double[]]$Values)
    if ($Values.Count -eq 0) { throw 'host benchmark median requires at least one value' }
    $ordered = @($Values | Sort-Object)
    $middle = [int][math]::Floor($ordered.Count / 2)
    if (($ordered.Count % 2) -eq 1) { return [double]$ordered[$middle] }
    return ([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2
}

function Test-HostRunnerPathAtOrBelow {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root)
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $pathFull.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -or $pathFull.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)
}

function Test-HostRunnerExactUtf8File {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedText)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $actual = [IO.File]::ReadAllBytes($Path)
        $expected = [Text.UTF8Encoding]::new($false).GetBytes($ExpectedText)
        if ($actual.Length -ne $expected.Length) { return $false }
        for ($index=0; $index -lt $actual.Length; $index++) {
            if ($actual[$index] -ne $expected[$index]) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-HostRunnerWorkspaceChanges {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$BaselineRevision)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($arguments in @(
        @('-c','core.quotepath=false','diff',$BaselineRevision,'--name-only','--'),
        @('-c','core.quotepath=false','diff','--cached',$BaselineRevision,'--name-only','--'),
        @('-c','core.quotepath=false','ls-files','--others','--exclude-standard','--'),
        @('-c','core.quotepath=false','ls-files','--others','--ignored','--exclude-standard','--')
    )) {
        foreach ($path in @(Invoke-HostGit -Root $Workspace -Arguments $arguments)) {
            $normalized = ([string]$path).Replace('\','/')
            if ($normalized.Length -gt 0) { [void]$paths.Add($normalized) }
        }
    }
    foreach ($line in @(Invoke-HostGit -Root $Workspace -Arguments @('-c','core.quotepath=false','ls-files','-v','--'))) {
        $entry = [string]$line
        if ($entry -cnotmatch '^H ') {
            $path = if ($entry.Length -gt 2) { $entry.Substring(2).Replace('\','/') } else { 'unknown' }
            [void]$paths.Add('__git_index_flag__/' + $path)
        }
    }
    return @($paths | Sort-Object)
}

function Test-HostRunnerTrialEvidence {
    param(
        [Parameter(Mandatory)][ValidateSet('bare','v1','v2')][string]$Protocol,
        [Parameter(Mandatory)][string]$TrialRoot,
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$SourceRevision,
        [Parameter(Mandatory)][string]$SourceCommitTree,
        [switch]$RequireSourceBinding
    )
    try {
        $workspace = Join-Path $TrialRoot 'workspace'
        if (-not (Test-Path -LiteralPath $workspace -PathType Container)) { return $false }
        $baseline = [string]$Record.workspace_baseline_revision
        if ($baseline -cnotmatch '^[0-9a-f]{40,64}$') { return $false }
        $head = (@(Invoke-HostGit -Root $workspace -Arguments @('rev-parse','--verify','HEAD')) -join '').Trim()
        if ($head -cne $baseline -or -not (Test-HostRunnerExactUtf8File -Path (Join-Path $workspace 'src\value.txt') -ExpectedText 'beta')) { return $false }
        $changed = @(Get-HostRunnerWorkspaceChanges -Workspace $workspace -BaselineRevision $baseline)
        foreach ($relative in $changed) {
            if ($relative.StartsWith('__git_index_flag__/',[StringComparison]::Ordinal)) { return $false }
            $resolved = Resolve-HarnessContainedPath -WorkspaceRoot $workspace -Path $relative -Label 'runner benchmark changed path' -MustExist File
            $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            if ($item.PSIsContainer -or -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)) { return $false }
        }
        if ($changed -cnotcontains 'src/value.txt') { return $false }
        $artifactAllowlist = @('docs/tasks/host-benchmark-fixed-workflow/plan.md','docs/tasks/host-benchmark-fixed-workflow/test.md','docs/tasks/host-benchmark-fixed-workflow/skill-manifest.json')
        $requiredArtifacts = @('docs/tasks/host-benchmark-fixed-workflow/plan.md','docs/tasks/host-benchmark-fixed-workflow/test.md')
        $runtimeAllowlist = @('.assistant/运行时/当前任务.md','.assistant/运行时/恢复索引.md','.assistant/运行时/tasks/host-benchmark-fixed-workflow.md')
        $artifactChanges = @($changed | Where-Object { $_.StartsWith('docs/tasks/',[StringComparison]::Ordinal) })
        $runtimeChanges = @($changed | Where-Object { $_.StartsWith('.assistant/runtime/',[StringComparison]::Ordinal) -or $_.StartsWith('.assistant/运行时/',[StringComparison]::Ordinal) })
        if ($Protocol -ceq 'v1') {
            $allowed = @('src/value.txt') + $artifactAllowlist + $runtimeAllowlist
            if (@($changed | Where-Object { $_ -cnotin $allowed }).Count -ne 0 -or @($requiredArtifacts | Where-Object { $_ -cnotin $artifactChanges }).Count -ne 0 -or $artifactChanges.Count -notin @(2,3) -or $runtimeChanges.Count -ne 3) { return $false }
        } elseif ($changed.Count -ne 1 -or $artifactChanges.Count -ne 0 -or $runtimeChanges.Count -ne 0) { return $false }
        if ([int]$Record.artifact_writes -ne $artifactChanges.Count -or [int]$Record.runtime_writes -ne $runtimeChanges.Count) { return $false }
        if ($RequireSourceBinding) {
            $sourceRoot = Join-Path $TrialRoot 'source'
            if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { return $false }
            $sourceState = Get-HostGitState -Root $sourceRoot -IncludeIgnored
            if ([string]$sourceState.revision -cne $SourceRevision -or [string]$sourceState.commit_tree_oid -cne $SourceCommitTree -or [bool]$sourceState.dirty) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-HostTrialContract {
    param(
        [Parameter(Mandatory)][ValidateSet('bare','v1','v2')][string]$Protocol,
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][int]$ExpectedTrial,
        [Parameter(Mandatory)][string]$SourceRevision,
        [Parameter(Mandatory)][string]$SourceCommitTree,
        [ValidateSet('cognitive-fast-path','installed-desktop-path')][string]$BenchmarkPath = 'cognitive-fast-path',
        [switch]$AllowUnavailableRequestMeasurement,
        [switch]$AllowUnavailableRecord,
        [switch]$RequireSourceBinding
    )
    try {
        $recordStatus = [string]$Record.status
        if ([int]$Record.trial -ne $ExpectedTrial -or -not [bool]$Record.runner_evidence_passed) { return $false }
        if ($recordStatus -ceq 'measured') {
            if (-not [bool]$Record.completion_passed) { return $false }
        } elseif (-not $AllowUnavailableRecord -or $recordStatus -cne 'unavailable') { return $false }
        if ([string]$Record.outcome -cne 'completed' -or [string]$Record.reason_code -cne 'completed' -or -not [bool]$Record.workflow_completed) { return $false }
        $duration = [double]$Record.total_duration_ms
        if (-not [double]::IsFinite($duration) -or $duration -le 0 -or [int]$Record.unexpected_writes -ne 0 -or -not [bool]$Record.raw_trace_deleted) { return $false }
        if ([string]$Record.successful_request_sends.basis -cne 'codex-0.144.4-successful-websocket-send/v2') { return $false }
        if (-not $AllowUnavailableRequestMeasurement -and ([string]$Record.successful_request_sends.status -cne 'measured' -or [double]$Record.successful_request_sends.value -le 0)) { return $false }
        if ($AllowUnavailableRequestMeasurement -and [string]$Record.successful_request_sends.status -cnotin @('measured','unavailable')) { return $false }
        if ([string]$Record.host_turns.status -cne 'measured' -or [string]$Record.host_turns.basis -cne 'codex-jsonl-turn.started') { return $false }
        if ($Protocol -ceq 'v1') {
            if ([string]$Record.workflow_contract -cne 'confirmed-plan-to-done' -or [int]$Record.fresh_sessions -ne 5 -or [int]$Record.host_turns.value -ne 5) { return $false }
            if ((@($Record.v1_stage_journal) -join '>') -cne 'PLAN_REVIEW>IMPLEMENT>CODE_REVIEW>TEST>DONE' -or -not [bool]$Record.v1_validator_passed) { return $false }
            if ((@($Record.v1_target_journal) -join '>') -cne 'alpha>alpha>beta>beta>beta') { return $false }
            if ([int]$Record.artifact_writes -notin @(2,3) -or [int]$Record.runtime_writes -ne 3) { return $false }
        } else {
            if ([string]$Record.workflow_contract -cne 'new-task' -or [int]$Record.fresh_sessions -ne 1 -or [int]$Record.host_turns.value -ne 1) { return $false }
            if ([int]$Record.artifact_writes -ne 0 -or [int]$Record.runtime_writes -ne 0) { return $false }
        }
        if ($BenchmarkPath -ceq 'installed-desktop-path') {
            $desktop = $Record.installed_desktop
            $desktopKeys = @('benchmark_path','host_surface','user_config_mode','workspace_config_loaded','profile_config','protocol_environment','install_status','verification_status','auth_unchanged','workspace_protocol_config','route_probe','cleanup_status','hook_installed','hook_trust','hook_callability')
            if ($desktop -isnot [Collections.IDictionary] -or (@(Compare-Object @($desktopKeys|Sort-Object) @($desktop.Keys|ForEach-Object{[string]$_}|Sort-Object))).Count -ne 0 -or
                [string]$desktop.benchmark_path -cne $BenchmarkPath -or [string]$desktop.host_surface -cne 'installed-desktop-path' -or [string]$desktop.user_config_mode -cne 'loaded' -or
                [string]$desktop.protocol_environment -cne 'cleared' -or [string]$desktop.hook_trust -cne 'manual' -or [string]$desktop.hook_callability -cne 'manual') { return $false }
            $profileConfig = $desktop.profile_config
            if ($profileConfig -isnot [Collections.IDictionary] -or (@($profileConfig.Keys | Sort-Object) -join ',') -cne 'digest,status') { return $false }
            if ([string]$profileConfig.status -ceq 'absent') {
                if ($null -ne $profileConfig.digest) { return $false }
            } elseif ([string]$profileConfig.status -ceq 'present') {
                if ([string]$profileConfig.digest -cnotmatch '^sha256:[0-9a-f]{64}$') { return $false }
            } else { return $false }
            if ($Protocol -ceq 'bare') {
                if ([bool]$desktop.workspace_config_loaded -or [string]$desktop.install_status -cne 'not-applicable' -or [string]$desktop.verification_status -cne 'not-applicable' -or [string]$desktop.cleanup_status -cne 'not-required' -or [string]$desktop.hook_installed -cne 'not-applicable' -or $null -ne $desktop.auth_unchanged -or $null -ne $desktop.workspace_protocol_config -or $null -ne $desktop.route_probe) { return $false }
            } else {
                if (-not [bool]$desktop.workspace_config_loaded -or [string]$desktop.install_status -cne 'pass' -or [string]$desktop.verification_status -cne 'pass' -or -not [bool]$desktop.auth_unchanged -or [string]$desktop.cleanup_status -cne 'passed' -or [string]$desktop.hook_installed -cne 'verified') { return $false }
                $routeKeys = @('requested_protocol','detected_protocol','selected_protocol','preference_source','default_source','reason','workspace_config_status','workspace_config_protocol','runtime_default_status','artifact_kind')
                if ($desktop.route_probe -isnot [Collections.IDictionary] -or (@(Compare-Object @($routeKeys|Sort-Object) @($desktop.route_probe.Keys|ForEach-Object{[string]$_}|Sort-Object))).Count -ne 0 -or [string]$desktop.route_probe.selected_protocol -cne $Protocol) { return $false }
                if ($Protocol -ceq 'v2') {
                    $workspaceConfigKeys = @('status','new_task_protocol','preference_source','config_digest')
                    if ($desktop.workspace_protocol_config -isnot [Collections.IDictionary] -or (@(Compare-Object @($workspaceConfigKeys|Sort-Object) @($desktop.workspace_protocol_config.Keys|ForEach-Object{[string]$_}|Sort-Object))).Count -ne 0 -or
                        [string]$desktop.workspace_protocol_config.status -cne 'pass' -or [string]$desktop.workspace_protocol_config.new_task_protocol -cne 'v2' -or [string]$desktop.workspace_protocol_config.preference_source -cne 'workspace-config' -or [string]$desktop.workspace_protocol_config.config_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                        [string]$desktop.route_probe.requested_protocol -cne 'v2' -or [string]$desktop.route_probe.detected_protocol -cne 'new' -or [string]$desktop.route_probe.preference_source -cne 'workspace-config' -or [string]$desktop.route_probe.default_source -cne 'workspace-config' -or
                        [string]$desktop.route_probe.reason -cne 'workspace-v2-new-task' -or [string]$desktop.route_probe.workspace_config_status -cne 'present' -or [string]$desktop.route_probe.workspace_config_protocol -cne 'v2' -or [string]$desktop.route_probe.runtime_default_status -cne 'not-read' -or [string]$desktop.route_probe.artifact_kind -cne 'new-task') { return $false }
                } elseif ($null -ne $desktop.workspace_protocol_config -or [string]$desktop.route_probe.detected_protocol -cne 'v1' -or [string]$desktop.route_probe.default_source -cne 'existing-artifact' -or [string]$desktop.route_probe.reason -cne 'existing-v1-plan' -or [string]$desktop.route_probe.artifact_kind -cne 'v1-plan') { return $false }
            }
        } elseif ($Record -is [Collections.IDictionary] -and $Record.Contains('installed_desktop')) { return $false }
        if ($RequireSourceBinding) {
            if ([string]$Record.source_binding.status -cne 'bound' -or [string]$Record.source_binding.revision -cne $SourceRevision -or [string]$Record.source_binding.commit_tree_oid -cne $SourceCommitTree -or [string]$Record.source_binding.verification -cne 'git-head-tree-clean/v1') { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-ReleaseHostTrialSet {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Records,
        [Parameter(Mandatory)][int]$RequiredTrials,
        [Parameter(Mandatory)][string]$SourceRevision,
        [Parameter(Mandatory)][string]$SourceCommitTree,
        [ValidateSet('cognitive-fast-path','installed-desktop-path')][string]$BenchmarkPath = 'cognitive-fast-path'
    )
    if ($RequiredTrials -ne 3) { return $false }
    $profileConfig = $null
    foreach ($protocol in @('bare','v1','v2')) {
        if (-not $Records.Contains($protocol)) { return $false }
        $trials = @($Records[$protocol].trials)
        if ($trials.Count -ne $RequiredTrials) { return $false }
        if ((@($trials | ForEach-Object { [int]$_.trial } | Sort-Object) -join ',') -cne '1,2,3') { return $false }
        foreach ($record in $trials) {
            if (-not (Test-HostTrialContract -Protocol $protocol -Record $record -ExpectedTrial ([int]$record.runner_expected_trial) -SourceRevision $SourceRevision -SourceCommitTree $SourceCommitTree -BenchmarkPath $BenchmarkPath -RequireSourceBinding)) { return $false }
            if ($BenchmarkPath -ceq 'installed-desktop-path') {
                if ($null -eq $profileConfig) { $profileConfig = $record.installed_desktop.profile_config }
                elseif (-not (Test-InstalledDesktopUserConfigBinding -Expected $profileConfig -Actual $record.installed_desktop.profile_config)) { return $false }
            }
        }
    }
    return $true
}

function Get-SanitizedHostTrialDiagnostic {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match '^host-benchmark-auth-home-') { return 'isolated-auth-home-unavailable' }
    if ($message -match '^host-benchmark-source-') { return 'source-binding-unavailable' }
    if ($message -match '^host-benchmark-installed-') { return 'installed-desktop-unavailable' }
    return 'trial-exception'
}

function New-HostUnavailableTrial {
    param([int]$Trial,[string]$Diagnostic,[string]$SourceRevision,[string]$SourceCommitTree,[bool]$RawTraceDeleted = $false)
    return [ordered]@{
        trial=$Trial;runner_expected_trial=$Trial;runner_evidence_passed=$false;workspace_baseline_revision=$null;status='unavailable';diagnostic=$Diagnostic;completion_passed=$false;outcome='failed';reason_code='execution_failed'
        source_binding=[ordered]@{status='unavailable';revision=$SourceRevision;commit_tree_oid=$SourceCommitTree;verification='unavailable';reason=$Diagnostic}
        workflow_contract='unavailable';workflow_completed=$false;v1_stage_journal=@();v1_target_journal=@();v1_validator_passed=$false;fresh_sessions=0
        host_turns=[ordered]@{status='unavailable';value=$null;basis='codex-jsonl-turn.started';reason=$Diagnostic}
        successful_request_sends=[ordered]@{status='unavailable';value=$null;basis='codex-0.144.4-successful-websocket-send/v2';reason=$Diagnostic}
        completed_agent_messages=0;total_duration_ms=0;sum_codex_process_duration_ms=0;first_useful_action_ms=$null
        tool_calls=[ordered]@{command=0;mcp=0;web_search=0;file_change=0;total=0}
        loaded_skills=[ordered]@{status='unavailable';value=$null;reason=$Diagnostic};skill_file_command_matches=[ordered]@{status='unavailable';value=$null;reason=$Diagnostic};loaded_files=[ordered]@{status='unavailable';value=$null;reason=$Diagnostic}
        artifact_writes=0;runtime_writes=0;unexpected_writes=0;raw_trace_deleted=$RawTraceDeleted;post_trial_diagnostics=@()
        tokens=[ordered]@{status='unavailable';input=$null;cached_input=$null;output=$null}
    }
}

. $otelContractPath
. $trialPath

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ($Model -cne 'gpt-5.6-sol') { throw 'Release host benchmark requires gpt-5.6-sol.' }
$expectedCodexVersion = '0.144.4'
$wrapperPath = Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
$schemaPath = Join-Path $RepoRoot 'schemas\host-benchmark\observation.schema.json'
$installPath = Join-Path $RepoRoot 'install.ps1'
$collectorPath = Join-Path $RepoRoot 'scripts\receive-otlp-http.ps1'
foreach ($path in @($wrapperPath,$schemaPath,$installPath,$collectorPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required host benchmark input is missing: $path" }
}
$schemaText = [IO.File]::ReadAllText($schemaPath,[Text.UTF8Encoding]::new($false,$true))
$null = $schemaText | ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
if ($ValidateOnly) { Write-Output 'STATUS: PASS (host benchmark definition only; no model session executed)'; exit 0 }

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ('thin-v2-host-benchmark-' + [guid]::NewGuid().ToString('N') + '.json') }
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path (Get-Location).Path $OutputPath }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (-not (Test-HostReportPath -Root $RepoRoot -Path $OutputPath)) { throw 'Host benchmark output must be outside the source tree or ignored by Git.' }
if ([string]::IsNullOrWhiteSpace($CodexHome)) { $CodexHome = [Environment]::GetEnvironmentVariable('HOST_BENCHMARK_CODEX_HOME',[EnvironmentVariableTarget]::Process) }
if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
    if ((Test-HostRunnerPathAtOrBelow -Path $OutputPath -Root $CodexHome) -or (Test-HostRunnerPathAtOrBelow -Path $CodexHome -Root $OutputPath)) { throw 'Host benchmark output must not overlap the dedicated Codex home.' }
    if (Test-Path -LiteralPath $CodexHome -PathType Container) {
        $physicalOutput = Get-HostPhysicalPathInfo -Path $OutputPath -AllowMissing -RejectLinks
        $physicalCodexHome = Get-HostPhysicalPathInfo -Path $CodexHome -RejectLinks
        if ((Test-HostRunnerPathAtOrBelow -Path ([string]$physicalOutput.physical_path) -Root ([string]$physicalCodexHome.physical_path)) -or (Test-HostRunnerPathAtOrBelow -Path ([string]$physicalCodexHome.physical_path) -Root ([string]$physicalOutput.physical_path))) { throw 'Host benchmark output must not overlap the dedicated Codex home.' }
    }
}
if ($BenchmarkPath -ceq 'installed-desktop-path') {
    if ([string]::IsNullOrWhiteSpace($CodexHome) -or [IO.Path]::GetFileName($CodexHome) -cne '.codex') { throw 'host-benchmark-installed-profile-invalid' }
    $installedProfileRoot = [IO.Path]::GetDirectoryName($CodexHome)
    if ((Test-HostRunnerPathAtOrBelow -Path $OutputPath -Root $installedProfileRoot) -or (Test-HostRunnerPathAtOrBelow -Path $installedProfileRoot -Root $OutputPath)) { throw 'Host benchmark output must not overlap the installed Desktop profile.' }
    $physicalInstalledProfile = Get-HostPhysicalPathInfo -Path $installedProfileRoot -RejectLinks
    $physicalInstalledOutput = Get-HostPhysicalPathInfo -Path $OutputPath -AllowMissing -RejectLinks
    if ((Test-HostRunnerPathAtOrBelow -Path ([string]$physicalInstalledOutput.physical_path) -Root ([string]$physicalInstalledProfile.physical_path)) -or (Test-HostRunnerPathAtOrBelow -Path ([string]$physicalInstalledProfile.physical_path) -Root ([string]$physicalInstalledOutput.physical_path))) { throw 'Host benchmark output must not physically overlap the installed Desktop profile.' }
}

$sourceStart = Get-HostGitState -Root $RepoRoot
$sourceInputPaths = @($PSCommandPath,$wrapperPath,$schemaPath,$collectorPath,$atomicWritePath,$hashingPath,$pathModulePath,$otelContractPath,$trialPath)
if ($BenchmarkPath -ceq 'installed-desktop-path') {
    $sourceInputPaths += @(
        (Join-Path $RepoRoot 'install.ps1'),
        (Join-Path $RepoRoot 'uninstall.ps1'),
        (Join-Path $RepoRoot 'tests\verify-installation.ps1'),
        (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1')
    )
}
$sourceInputHeadBoundStart = @($sourceInputPaths | Where-Object { -not (Test-HostGitFileMatchesRevision -Root $RepoRoot -Path $_ -Revision ([string]$sourceStart.revision)) }).Count -eq 0
$sourceInputs = [ordered]@{
    runner_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $PSCommandPath
    wrapper_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $wrapperPath
    observation_schema_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $schemaPath
    otlp_collector_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $collectorPath
    atomic_write_module_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $atomicWritePath
    path_module_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $pathModulePath
    otel_contract_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $otelContractPath
    trial_helper_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $trialPath
}
if ($BenchmarkPath -ceq 'installed-desktop-path') {
    $sourceInputs['installed_inputs'] = [ordered]@{
        install_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path (Join-Path $RepoRoot 'install.ps1')
        uninstall_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path (Join-Path $RepoRoot 'uninstall.ps1')
        verification_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path (Join-Path $RepoRoot 'tests\verify-installation.ps1')
        protocol_digest=Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1')
    }
}
$sourceMode = if ([bool]$sourceStart.dirty -or -not $sourceInputHeadBoundStart) { 'live-dirty-diagnostic' } else { 'clean-commit-clone' }
$producerMode = if ($BenchmarkPath -cne 'installed-desktop-path') { 'not-applicable' } elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('HOST_BENCHMARK_TEST_MODE',[EnvironmentVariableTarget]::Process))) { 'test-only' } elseif ($Groups -ne 3 -or $Trials -ne 3 -or $KeepScratch) { 'diagnostic-smoke' } else { 'formal' }
$reportRunId = [guid]::NewGuid().ToString('N')
$benchmarkGroups = [Collections.Generic.List[object]]::new()
$protocolNames = @('bare','v1','v2')
$timer = [Diagnostics.Stopwatch]::StartNew()
$profileLock = $null
$isolatedConfigSentinel = $null
$scratchBase = $null
$scratchRoot = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $lockFailure = if($BenchmarkPath-ceq'installed-desktop-path'){'host-benchmark-installed-profile-lock-timeout'}else{'host-benchmark-auth-home-lock-timeout'}
        $profileLock = Enter-HostCodexHomeMutex -Path $CodexHome -FailureCode $lockFailure
    }
    $scratchBase = New-HarnessContainedDirectory -WorkspaceRoot $RepoRoot -Path '.assistant\运行时\release-qualification' -Label 'host benchmark scratch base'
    $scratchRoot = New-HarnessContainedDirectory -WorkspaceRoot $scratchBase -Path ('thin-v2-host-benchmark-' + [guid]::NewGuid().ToString('N')) -Label 'host benchmark scratch root'
    if ($BenchmarkPath -ceq 'cognitive-fast-path' -and -not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $null = Recover-HostIsolatedConfigSentinel -Path $CodexHome
        $configExists = Test-Path -LiteralPath (Join-Path $CodexHome 'config.toml')
        $CodexHome = Assert-HostCodexHome -Path $CodexHome -RepoRoot $RepoRoot -ScratchRoot $scratchRoot -AllowNativeSystemSkills -AllowIsolatedHostConfig:$configExists
        $isolatedConfigSentinel = Initialize-HostIsolatedConfigSentinel -Path $CodexHome
        $CodexHome = Assert-HostCodexHome -Path $CodexHome -RepoRoot $RepoRoot -ScratchRoot $scratchRoot -AllowNativeSystemSkills -AllowIsolatedHostConfig
    }
    for ($groupIndex=1; $groupIndex -le $Groups; $groupIndex++) {
        $groupTimer = [Diagnostics.Stopwatch]::StartNew()
        $groupRunId = [guid]::NewGuid().ToString('N')
        $groupRoot = New-HarnessContainedDirectory -WorkspaceRoot $scratchRoot -Path ("group-$groupIndex-$groupRunId") -Label 'host benchmark group root'
        $groupRootDigest = Get-HarnessSha256Text -Content ("host-benchmark-group-root/v1`n" + [IO.Path]::GetFullPath($groupRoot))
        $groupSourceStart = Get-HostGitState -Root $RepoRoot
        $groupInputHeadBoundStart = @($sourceInputPaths | Where-Object { -not (Test-HostGitFileMatchesRevision -Root $RepoRoot -Path $_ -Revision ([string]$groupSourceStart.revision)) }).Count -eq 0
        $groupRecords = [ordered]@{}
        $trialRecordsByProtocol = [ordered]@{bare=[Collections.Generic.List[object]]::new();v1=[Collections.Generic.List[object]]::new();v2=[Collections.Generic.List[object]]::new()}
        $executionOrder = [Collections.Generic.List[object]]::new()
        $sequence = 0
        for ($trial=1; $trial -le $Trials; $trial++) {
            $rotation = (($groupIndex - 1) + ($trial - 1)) % $protocolNames.Count
            for ($offset=0; $offset -lt $protocolNames.Count; $offset++) {
                $protocol = $protocolNames[($rotation + $offset) % $protocolNames.Count]
                $sequence++
                $executionOrder.Add([ordered]@{sequence=$sequence;protocol=$protocol;trial=$trial})
                Write-Output ("[HOST] group={0}/{1} protocol={2} trial={3}/{4}" -f $groupIndex,$Groups,$protocol,$trial,$Trials)
                $trialRunId = [guid]::NewGuid().ToString('N')
                $trialRoot = Join-Path $groupRoot ("$protocol-$trial")
                $trialRootDigest = Get-HarnessSha256Text -Content ("host-benchmark-trial-root/v1`n" + [IO.Path]::GetFullPath($trialRoot))
                $installedProfileConfigBefore = $null
                $installedIntegrityFailed = $false
                try {
                    if ($BenchmarkPath -ceq 'installed-desktop-path') { $installedProfileConfigBefore = Get-InstalledDesktopUserConfigBinding -CodexHome $CodexHome }
                    $record = Invoke-HostTrial -Protocol $protocol -Trial $trial -ScratchRoot $groupRoot -RepoRoot $RepoRoot -WrapperPath $wrapperPath -SchemaPath $schemaPath -CollectorPath $collectorPath -CodexHome $CodexHome -BenchmarkPath $BenchmarkPath -Model $Model -Reasoning $Reasoning -MaxRoundTrips $MaxRoundTrips -TimeoutSeconds $TimeoutSeconds -ExpectedCodexVersion $expectedCodexVersion -SourceBindingRequired (-not [bool]$groupSourceStart.dirty -and $groupInputHeadBoundStart) -SourceRevision ([string]$groupSourceStart.revision) -SourceCommitTree ([string]$groupSourceStart.commit_tree_oid)
                } catch {
                    $installedIntegrityFailed = $BenchmarkPath -ceq 'installed-desktop-path' -and [string]$_.Exception.Message -cmatch '^host-benchmark-installed-(?:install|verification)-(?:profile-integrity-failed|changed-auth|changed-config)$'
                    $diagnostic = Get-SanitizedHostTrialDiagnostic -ErrorRecord $_
                    $preTraceFailure = $diagnostic -cin @('isolated-auth-home-unavailable','source-binding-unavailable','installed-desktop-unavailable')
                    $record = New-HostUnavailableTrial -Trial $trial -Diagnostic $diagnostic -SourceRevision ([string]$groupSourceStart.revision) -SourceCommitTree ([string]$groupSourceStart.commit_tree_oid) -RawTraceDeleted $preTraceFailure
                } finally {
                    Import-Module $atomicWritePath -Force -ErrorAction Stop
                    Import-Module $hashingPath -Force -ErrorAction Stop
                    Import-Module $pathModulePath -Force -ErrorAction Stop
                }
                $installedCleanupFailed = $false
                try {
                    $runnerEvidencePassed = Test-HostRunnerTrialEvidence -Protocol $protocol -TrialRoot $trialRoot -Record $record -SourceRevision ([string]$groupSourceStart.revision) -SourceCommitTree ([string]$groupSourceStart.commit_tree_oid) -RequireSourceBinding:(-not [bool]$groupSourceStart.dirty)
                    if ($record -is [Collections.IDictionary]) {
                        $record['trial_run_id'] = $trialRunId
                        $record['trial_root_digest'] = $trialRootDigest
                        $record['runner_expected_trial'] = $trial
                        $record['runner_evidence_passed'] = $runnerEvidencePassed
                    } else {
                        $record | Add-Member -NotePropertyName trial_run_id -NotePropertyValue $trialRunId -Force
                        $record | Add-Member -NotePropertyName trial_root_digest -NotePropertyValue $trialRootDigest -Force
                        $record | Add-Member -NotePropertyName runner_expected_trial -NotePropertyValue $trial -Force
                        $record | Add-Member -NotePropertyName runner_evidence_passed -NotePropertyValue $runnerEvidencePassed -Force
                    }
                } finally {
                    if ($BenchmarkPath -ceq 'installed-desktop-path') {
                        $cleanupStatus = if ($protocol -ceq 'bare') { 'not-required' } else { 'passed' }
                        try {
                            $workspace = Join-Path $trialRoot 'workspace'
                            if (Test-InstalledDesktopWorkspaceRegistered -CodexHome $CodexHome -Workspace $workspace) {
                                $trialSourceRoot = Join-Path $trialRoot 'source'
                                $cleanupRepoRoot = if (Test-Path -LiteralPath $trialSourceRoot -PathType Container) { $trialSourceRoot } else { $RepoRoot }
                                [void](Invoke-InstalledDesktopTrialCleanup -CodexHome $CodexHome -Workspace $workspace -RepoRoot $cleanupRepoRoot)
                            } else {
                                $trialSourceRoot = Join-Path $trialRoot 'source'
                                $cleanupRepoRoot = if (Test-Path -LiteralPath $trialSourceRoot -PathType Container) { $trialSourceRoot } else { $RepoRoot }
                                $recovery = Get-InstalledDesktopPendingRecovery -CodexHome $CodexHome -Workspace $workspace -RepoRoot $cleanupRepoRoot
                                if ($null -ne $recovery) {
                                    [void](Invoke-InstalledDesktopTrialRecovery -CodexHome $CodexHome -Workspace $workspace -RepoRoot $cleanupRepoRoot -Recovery $recovery)
                                    $cleanupStatus = 'recovered'
                                } else { [void](Assert-InstalledDesktopProfileReady -CodexHome $CodexHome) }
                            }
                            if ($installedProfileConfigBefore -isnot [Collections.IDictionary] -or -not (Test-InstalledDesktopUserConfigBinding -Expected $installedProfileConfigBefore -Actual (Get-InstalledDesktopUserConfigBinding -CodexHome $CodexHome))) { throw 'host-benchmark-installed-config-changed' }
                        } catch {
                            $cleanupStatus = 'failed'
                            $installedCleanupFailed = $true
                            if ($record -is [Collections.IDictionary]) {
                                $record['status'] = 'fail'
                                $record['completion_passed'] = $false
                                $record['diagnostic'] = 'installed-desktop-cleanup-failed'
                            } else {
                                $record | Add-Member -NotePropertyName status -NotePropertyValue 'fail' -Force
                                $record | Add-Member -NotePropertyName completion_passed -NotePropertyValue $false -Force
                                $record | Add-Member -NotePropertyName diagnostic -NotePropertyValue 'installed-desktop-cleanup-failed' -Force
                            }
                        }
                        if ($record -is [Collections.IDictionary]) {
                            if (-not $record.Contains('installed_desktop') -or $record['installed_desktop'] -isnot [Collections.IDictionary]) { $record['installed_desktop'] = [ordered]@{} }
                            $record['installed_desktop']['cleanup_status'] = $cleanupStatus
                        } else {
                            if ($null -eq $record.PSObject.Properties['installed_desktop']) { $record | Add-Member -NotePropertyName installed_desktop -NotePropertyValue ([ordered]@{}) }
                            $record.installed_desktop['cleanup_status'] = $cleanupStatus
                        }
                        if ($installedIntegrityFailed) {
                            if ($record -is [Collections.IDictionary]) {
                                $record['status'] = 'fail'
                                $record['completion_passed'] = $false
                                $record['diagnostic'] = 'installed-desktop-profile-integrity-failed'
                            } else {
                                $record | Add-Member -NotePropertyName status -NotePropertyValue 'fail' -Force
                                $record | Add-Member -NotePropertyName completion_passed -NotePropertyValue $false -Force
                                $record | Add-Member -NotePropertyName diagnostic -NotePropertyValue 'installed-desktop-profile-integrity-failed' -Force
                            }
                        }
                    }
                }
                $trialRecordsByProtocol[$protocol].Add($record)
                if ($installedCleanupFailed -or $installedIntegrityFailed) { throw 'Installed Desktop profile integrity failed; refusing subsequent trials.' }
            }
        }
        $pendingCleanupFailures = @($script:HostPendingOtlpCollectors | Where-Object { -not (Complete-HostPendingOtlpCleanup -Pending $_) }).Count
        if ($pendingCleanupFailures -gt 0) { throw 'OTLP collector or raw trace cleanup remained pending before group aggregation.' }
        foreach ($protocol in $protocolNames) {
            $all = @($trialRecordsByProtocol[$protocol])
            $unavailableCount = @($all | Where-Object { [string]$_.status -ceq 'unavailable' -or [string]$_.successful_request_sends.status -ceq 'unavailable' }).Count
            $invalidCount = @($all | Where-Object {
                if ([string]$_.status -ceq 'fail') { return $true }
                if ([string]$_.status -ceq 'unavailable') {
                    if ([string]$_.outcome -cne 'completed' -or [string]$_.reason_code -cne 'completed') { return $false }
                    return -not (Test-HostTrialContract -Protocol $protocol -Record $_ -ExpectedTrial ([int]$_.runner_expected_trial) -SourceRevision ([string]$groupSourceStart.revision) -SourceCommitTree ([string]$groupSourceStart.commit_tree_oid) -BenchmarkPath $BenchmarkPath -AllowUnavailableRequestMeasurement -AllowUnavailableRecord -RequireSourceBinding:(-not [bool]$groupSourceStart.dirty -and $groupInputHeadBoundStart))
                }
                if (-not (Test-HostTrialContract -Protocol $protocol -Record $_ -ExpectedTrial ([int]$_.runner_expected_trial) -SourceRevision ([string]$groupSourceStart.revision) -SourceCommitTree ([string]$groupSourceStart.commit_tree_oid) -BenchmarkPath $BenchmarkPath -AllowUnavailableRequestMeasurement -RequireSourceBinding:(-not [bool]$groupSourceStart.dirty -and $groupInputHeadBoundStart))) { return $true }
                if ([string]$_.successful_request_sends.status -ceq 'unavailable') { return $false }
                return -not (Test-HostTrialContract -Protocol $protocol -Record $_ -ExpectedTrial ([int]$_.runner_expected_trial) -SourceRevision ([string]$groupSourceStart.revision) -SourceCommitTree ([string]$groupSourceStart.commit_tree_oid) -BenchmarkPath $BenchmarkPath -RequireSourceBinding:(-not [bool]$groupSourceStart.dirty -and $groupInputHeadBoundStart))
            }).Count
            $protocolStatus = if ($invalidCount -gt 0 -or $all.Count -ne $Trials) { 'fail' } elseif ($unavailableCount -gt 0) { 'unavailable' } else { 'measured' }
            $sendStatus = if (@($all | Where-Object { [string]$_.successful_request_sends.status -cne 'measured' }).Count -eq 0 -and $all.Count -eq $Trials) { 'measured' } else { 'unavailable' }
            $sendMedian = if ($sendStatus -ceq 'measured') { [math]::Round((Get-HostMedian -Values @($all | ForEach-Object { [double]$_.successful_request_sends.value })),2) } else { $null }
            $groupRecords[$protocol] = [ordered]@{
                status=$protocolStatus;runner_contract_failures=$invalidCount;trials=$all
                successful_request_sends=[ordered]@{status=$sendStatus;median=$sendMedian;basis='codex-0.144.4-successful-websocket-send/v2';reason=$(if($sendStatus-ceq'measured'){'Median count of version-bound successful non-warmup Responses WebSocket sends.'}else{'One or more trials lacked a valid runner-rechecked successful-send contract.'})}
                medians=[ordered]@{
                    total_duration_ms=$(if($protocolStatus-ceq'measured'){[math]::Round((Get-HostMedian -Values @($all | ForEach-Object {[double]$_.total_duration_ms})),2)}else{$null})
                    sum_codex_process_duration_ms=$(if($protocolStatus-ceq'measured'){[math]::Round((Get-HostMedian -Values @($all | ForEach-Object {[double]$_.sum_codex_process_duration_ms})),2)}else{$null})
                    first_useful_action_ms=$(if($protocolStatus-ceq'measured' -and @($all.first_useful_action_ms | Where-Object {$null-ne$_}).Count-eq$Trials){[math]::Round((Get-HostMedian -Values @($all | ForEach-Object {[double]$_.first_useful_action_ms})),2)}else{$null})
                    fresh_sessions=$(if($protocolStatus-ceq'measured'){[math]::Round((Get-HostMedian -Values @($all | ForEach-Object {[double]$_.fresh_sessions})),2)}else{$null})
                    host_turns=$(if($protocolStatus-ceq'measured'){[math]::Round((Get-HostMedian -Values @($all | ForEach-Object {[double]$_.host_turns.value})),2)}else{$null})
                    successful_request_sends=$sendMedian
                    tool_calls=$(if($protocolStatus-ceq'measured'){[math]::Round((Get-HostMedian -Values @($all | ForEach-Object {[double]$_.tool_calls.total})),2)}else{$null})
                    skill_file_command_matches=$(if($protocolStatus-ceq'measured'){[math]::Round((Get-HostMedian -Values @($all | ForEach-Object {[double]$_.skill_file_command_matches.value})),2)}else{$null})
                }
            }
        }

        $groupProfileConfig = $null
        $groupProfileConfigConsistent = $true
        if ($BenchmarkPath -ceq 'installed-desktop-path') {
            foreach ($candidate in @($groupRecords.Values | ForEach-Object { @($_.trials) } | ForEach-Object {
                if ($_ -is [Collections.IDictionary] -and $_.Contains('installed_desktop') -and $_['installed_desktop'] -is [Collections.IDictionary] -and $_['installed_desktop'].Contains('profile_config')) { $_['installed_desktop']['profile_config'] }
            } | Where-Object { $_ -is [Collections.IDictionary] })) {
                if ($null -eq $groupProfileConfig) { $groupProfileConfig = $candidate }
                elseif (-not (Test-InstalledDesktopUserConfigBinding -Expected $groupProfileConfig -Actual $candidate)) { $groupProfileConfigConsistent = $false }
            }
        }

        $groupSourceEnd = Get-HostGitState -Root $RepoRoot
        $groupInputHeadBoundEnd = @($sourceInputPaths | Where-Object { -not (Test-HostGitFileMatchesRevision -Root $RepoRoot -Path $_ -Revision ([string]$groupSourceEnd.revision)) }).Count -eq 0
        $groupSourceDirty = [bool]$groupSourceStart.dirty -or [bool]$groupSourceEnd.dirty -or -not $groupInputHeadBoundStart -or -not $groupInputHeadBoundEnd
        $groupSourceStable = -not $groupSourceDirty -and [string]$groupSourceStart.revision -ceq [string]$groupSourceEnd.revision -and [string]$groupSourceStart.commit_tree_oid -ceq [string]$groupSourceEnd.commit_tree_oid -and [string]$groupSourceStart.state_digest -ceq [string]$groupSourceEnd.state_digest
        $direct = [ordered]@{status='unavailable';ratio=$null;threshold=1.25;reason='Measured complete bare and v2 host trials are required.'}
        $requestSend = [ordered]@{status='unavailable';reduction=$null;threshold=0.60;reason='Measured successful request sends are required for complete v1 and v2 host trials.'}
        if ([string]$groupRecords.bare.status -ceq 'measured' -and [string]$groupRecords.v2.status -ceq 'measured' -and [double]$groupRecords.bare.medians.total_duration_ms -gt 0) {
            $ratio = [math]::Round(([double]$groupRecords.v2.medians.total_duration_ms / [double]$groupRecords.bare.medians.total_duration_ms),4)
            $direct = [ordered]@{status=$(if($ratio-le1.25){'pass'}else{'fail'});ratio=$ratio;threshold=1.25;reason='Ratio of this group measured median complete-task v2 and bare host duration.'}
        }
        if ([string]$groupRecords.v1.status -ceq 'measured' -and [string]$groupRecords.v2.status -ceq 'measured' -and [string]$groupRecords.v1.successful_request_sends.status -ceq 'measured' -and [string]$groupRecords.v2.successful_request_sends.status -ceq 'measured' -and [double]$groupRecords.v1.successful_request_sends.median -gt 0) {
            $reduction = [math]::Round((([double]$groupRecords.v1.successful_request_sends.median-[double]$groupRecords.v2.successful_request_sends.median)/[double]$groupRecords.v1.successful_request_sends.median),4)
            $requestSend = [ordered]@{status=$(if($reduction-ge0.60){'pass'}else{'fail'});reduction=$reduction;threshold=0.60;reason='This group reduction in median version-bound successful non-warmup Responses WebSocket sends from v1 to v2.'}
        }
        $protocolUnavailable = @($groupRecords.Values | Where-Object { [string]$_.status -ceq 'unavailable' }).Count -gt 0
        $protocolFailed = @($groupRecords.Values | Where-Object { [string]$_.status -ceq 'fail' }).Count -gt 0
        $gateUnavailable = [string]$direct.status -ceq 'unavailable' -or [string]$requestSend.status -ceq 'unavailable'
        $releaseTrialSetPassed = -not $groupSourceDirty -and $groupProfileConfigConsistent -and (Test-ReleaseHostTrialSet -Records $groupRecords -RequiredTrials 3 -SourceRevision ([string]$groupSourceStart.revision) -SourceCommitTree ([string]$groupSourceStart.commit_tree_oid) -BenchmarkPath $BenchmarkPath)
        $releaseTrialSet = [ordered]@{status=$(if($releaseTrialSetPassed){'pass'}else{'fail'});required_trials_per_protocol=3;reason=$(if($releaseTrialSetPassed){'Each protocol in this group has exactly three runner-rechecked, source-bound trials.'}else{'Each release group requires clean source and exactly three runner-rechecked, source-bound trials for every protocol.'})}
        $groupEligible = $groupSourceStable -and -not $groupSourceDirty -and $releaseTrialSetPassed -and -not $protocolFailed -and [string]$direct.status -ceq 'pass' -and [string]$requestSend.status -ceq 'pass'
        $groupConfigurationFailure = $Trials -ne 3
        $groupPerformanceFailure = $groupSourceStable -and -not $groupSourceDirty -and $releaseTrialSetPassed -and ([string]$direct.status -ceq 'fail' -or [string]$requestSend.status -ceq 'fail')
        $groupKnownFailure = $protocolFailed -or $groupConfigurationFailure -or $groupPerformanceFailure
        $groupStatus = if ($groupKnownFailure) { 'fail' } elseif ($protocolUnavailable -or -not $groupSourceStable -or $gateUnavailable) { 'unavailable' } elseif ($groupSourceDirty -or -not $releaseTrialSetPassed) { 'fail' } elseif ($groupEligible) { 'pass' } else { 'fail' }
        $measurementPassed = $groupEligible
        if ($BenchmarkPath -ceq 'installed-desktop-path' -and $producerMode -cne 'formal') {
            $groupEligible = $false
            if ($groupStatus -ceq 'pass') { $groupStatus = 'unavailable' }
        }
        $groupTimer.Stop()
        $groupRawTraceCleanupConfirmed = @($groupRecords.Values | ForEach-Object { @($_.trials) } | Where-Object { -not [bool]$_.raw_trace_deleted }).Count -eq 0
        $groupSourceMode = if ($groupSourceDirty) { 'live-dirty-diagnostic' } else { 'clean-commit-clone' }
        $group = [ordered]@{
            group_index=$groupIndex;group_run_id=$groupRunId;group_root_digest=$groupRootDigest
            source_revision=$groupSourceStart.revision;source_dirty=$groupSourceDirty;source_state_stable=$groupSourceStable
            source=[ordered]@{runner_digest=$sourceInputs.runner_digest;wrapper_digest=$sourceInputs.wrapper_digest;observation_schema_digest=$sourceInputs.observation_schema_digest;otlp_collector_digest=$sourceInputs.otlp_collector_digest;atomic_write_module_digest=$sourceInputs.atomic_write_module_digest;path_module_digest=$sourceInputs.path_module_digest;otel_contract_digest=$sourceInputs.otel_contract_digest;trial_helper_digest=$sourceInputs.trial_helper_digest;input_head_binding=[ordered]@{start=$groupInputHeadBoundStart;end=$groupInputHeadBoundEnd;basis='git-hash-object-equals-revision-blob/v1'};execution_mode=$groupSourceMode;commit_tree_oid=$groupSourceStart.commit_tree_oid;object_format=$groupSourceStart.object_format;start=$groupSourceStart;end=$groupSourceEnd}
            execution=[ordered]@{model=$Model;reasoning=$Reasoning;trials_per_protocol=$Trials;release_trials_required=3;max_fresh_sessions=$MaxRoundTrips;fresh_workspace_per_trial=$true;fresh_ephemeral_session_per_invocation=$true;v1_comparator='confirmed-plan-to-done-one-stage-per-host-turn';bare_and_v2_start='new-task';semantic_task='change exact private file bytes and verify';host_turn_basis='codex-jsonl-turn.started';successful_request_send_measurement='codex-0.144.4-successful-websocket-send/v2';expected_codex_service_version=$expectedCodexVersion;trial_order_strategy='round-interleaved-rotating-start';actual_trial_order=@($executionOrder);cache_state='shared-dedicated-auth-home-and-host-cache-not-cleared-between-trials';codex_home='dedicated-config-isolated-auth-home-path-not-persisted';sandbox='danger-full-access';approval_policy='never';workspace_boundary='dedicated-ignored-nested-git-root';prompt_persisted=$false;raw_command_persisted=$false;thread_id_persisted=$false;raw_trace_persisted=$(if($groupRawTraceCleanupConfirmed){$false}else{$null});raw_trace_cleanup_confirmed=$groupRawTraceCleanupConfirmed;scratch_persisted=[bool]$KeepScratch;install_duration_included=$false;duration_ms=[math]::Round($groupTimer.Elapsed.TotalMilliseconds,2)}
            protocols=$groupRecords;performance=[ordered]@{release_trial_set=$releaseTrialSet;direct_latency=$direct;successful_request_send_reduction=$requestSend;eligible=$groupEligible};status=$groupStatus;group_digest=$null
        }
        if ($BenchmarkPath -ceq 'installed-desktop-path') {
            $group.source['installed_inputs'] = $sourceInputs.installed_inputs
            $group.execution['benchmark_path'] = $BenchmarkPath
            $group.execution['host_surface'] = 'installed-desktop-path'
            $group.execution['user_config_mode'] = 'loaded'
            $group.execution['codex_home'] = 'dedicated-installed-desktop-profile-path-not-persisted'
            $group.execution['profile_config'] = $(if($groupProfileConfigConsistent){$groupProfileConfig}else{$null})
            $group.execution['profile_config_consistent'] = $groupProfileConfigConsistent
            $group.performance['measurement_passed'] = $measurementPassed
            $group['qualification'] = [ordered]@{status=$(if($producerMode-ceq'formal'){$groupStatus}else{'unavailable'});reason=$(if($producerMode-ceq'formal'){'Derived from the complete installed Desktop hard-result contract.'}else{"Non-formal producer mode: $producerMode"})}
        }
        $group.group_digest = Get-HarnessSha256Text -Content ($group | ConvertTo-Json -Depth 100 -Compress)
        $benchmarkGroups.Add($group)
    }
} finally {
    $timer.Stop()
    try {
        $pendingCleanupFailures = @($script:HostPendingOtlpCollectors | Where-Object { -not (Complete-HostPendingOtlpCleanup -Pending $_) }).Count
        if ($pendingCleanupFailures -gt 0) { throw 'OTLP collector or raw trace cleanup remained pending after the final bounded retry.' }
        if (-not $KeepScratch -and -not [string]::IsNullOrWhiteSpace($scratchRoot) -and (Test-Path -LiteralPath $scratchRoot -PathType Container)) {
            $resolvedScratch = Resolve-HarnessContainedPath -WorkspaceRoot $scratchBase -Path $scratchRoot -Label 'host benchmark scratch cleanup' -MustExist Directory
            if (-not (Split-Path -Leaf $resolvedScratch).StartsWith('thin-v2-host-benchmark-',[StringComparison]::Ordinal)) { throw 'Refusing to remove unsafe host benchmark scratch path.' }
            Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
        }
    } finally {
        try {
            if ($null -ne $isolatedConfigSentinel) { $null = Complete-HostIsolatedConfigSentinel -State $isolatedConfigSentinel }
        } finally {
            Exit-HostCodexHomeMutex -State $profileLock
        }
    }
}

$sourceEnd = Get-HostGitState -Root $RepoRoot
$sourceInputHeadBoundEnd = @($sourceInputPaths | Where-Object { -not (Test-HostGitFileMatchesRevision -Root $RepoRoot -Path $_ -Revision ([string]$sourceEnd.revision)) }).Count -eq 0
$sourceDirty = [bool]$sourceStart.dirty -or [bool]$sourceEnd.dirty -or -not $sourceInputHeadBoundStart -or -not $sourceInputHeadBoundEnd
$sourceStable = -not $sourceDirty -and [string]$sourceStart.revision -ceq [string]$sourceEnd.revision -and [string]$sourceStart.commit_tree_oid -ceq [string]$sourceEnd.commit_tree_oid -and [string]$sourceStart.state_digest -ceq [string]$sourceEnd.state_digest
$installedProfileConfig = $null
$installedProfileConfigConsistent = $true
if ($BenchmarkPath -ceq 'installed-desktop-path') {
    foreach ($group in $benchmarkGroups) {
        if (-not [bool]$group.execution.profile_config_consistent) { $installedProfileConfigConsistent = $false; continue }
        $candidate = $group.execution.profile_config
        if ($candidate -isnot [Collections.IDictionary]) { continue }
        if ($null -eq $installedProfileConfig) { $installedProfileConfig = $candidate }
        elseif (-not (Test-InstalledDesktopUserConfigBinding -Expected $installedProfileConfig -Actual $candidate)) { $installedProfileConfigConsistent = $false }
    }
}
$passedGroups = @($benchmarkGroups | Where-Object { [string]$_.status -ceq 'pass' -and [bool]$_.performance.eligible }).Count
$measurementPassedGroups = if ($BenchmarkPath -ceq 'installed-desktop-path') { @($benchmarkGroups | Where-Object { [bool]$_.performance.measurement_passed }).Count } else { $passedGroups }
$failedGroups = @($benchmarkGroups | Where-Object { [string]$_.status -ceq 'fail' }).Count
$unavailableGroups = @($benchmarkGroups | Where-Object { [string]$_.status -ceq 'unavailable' }).Count
$releaseConfigurationFailure = $Groups -ne 3 -or $Trials -ne 3 -or -not $installedProfileConfigConsistent
$eligible = $sourceStable -and -not $sourceDirty -and -not $releaseConfigurationFailure -and $benchmarkGroups.Count -eq 3 -and $passedGroups -eq 3
$reportStatus = if ($releaseConfigurationFailure -or $failedGroups -gt 0 -or $sourceDirty) { 'fail' } elseif ($unavailableGroups -gt 0 -or -not $sourceStable) { 'unavailable' } elseif ($eligible) { 'pass' } else { 'fail' }
$releaseGroupSet = [ordered]@{status=$(if($eligible){'pass'}else{$reportStatus});required_groups=3;required_trials_per_protocol_per_group=3;passed_groups=$passedGroups;reason=$(if($eligible){'All three independent clean 3x3 groups passed their own latency and request-reduction gates.'}else{'Release eligibility requires three independent clean groups, each with bare/v1/v2 3x3 evidence and independently passing thresholds.'})}
$report = [ordered]@{
    schema_version='harness-host-benchmark-report/v2';generated_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
    source_revision=$sourceStart.revision;source_dirty=$sourceDirty;source_state_stable=$sourceStable
    source=[ordered]@{runner_digest=$sourceInputs.runner_digest;wrapper_digest=$sourceInputs.wrapper_digest;observation_schema_digest=$sourceInputs.observation_schema_digest;otlp_collector_digest=$sourceInputs.otlp_collector_digest;atomic_write_module_digest=$sourceInputs.atomic_write_module_digest;path_module_digest=$sourceInputs.path_module_digest;otel_contract_digest=$sourceInputs.otel_contract_digest;trial_helper_digest=$sourceInputs.trial_helper_digest;input_head_binding=[ordered]@{start=$sourceInputHeadBoundStart;end=$sourceInputHeadBoundEnd;basis='git-hash-object-equals-revision-blob/v1'};execution_mode=$sourceMode;commit_tree_oid=$sourceStart.commit_tree_oid;object_format=$sourceStart.object_format;start=$sourceStart;end=$sourceEnd}
    execution=[ordered]@{model=$Model;reasoning=$Reasoning;groups=$Groups;required_groups=3;trials_per_protocol_per_group=$Trials;required_trials_per_protocol_per_group=3;group_order_strategy='independent-groups-round-interleaved-rotating-start';max_fresh_sessions=$MaxRoundTrips;fresh_workspace_per_trial=$true;fresh_ephemeral_session_per_invocation=$true;codex_home='dedicated-config-isolated-auth-home-path-not-persisted';duration_ms=[math]::Round($timer.Elapsed.TotalMilliseconds,2)}
    groups=@($benchmarkGroups);performance=[ordered]@{release_group_set=$releaseGroupSet;eligible=$eligible};status=$reportStatus;report_digest=$null
}
if ($BenchmarkPath -ceq 'installed-desktop-path') {
    $report.schema_version = 'harness-installed-desktop-benchmark-report/v1'
    $report['report_run_id'] = $reportRunId
    $report['producer_identity'] = 'host-benchmark-installed-desktop/v1'
    $report['producer_mode'] = $producerMode
    $report['benchmark_path'] = $BenchmarkPath
    $report.source['installed_inputs'] = $sourceInputs.installed_inputs
    $report.execution['benchmark_path'] = $BenchmarkPath
    $report.execution['host_surface'] = 'installed-desktop-path'
    $report.execution['user_config_mode'] = 'loaded'
    $report.execution['codex_home'] = 'dedicated-installed-desktop-profile-path-not-persisted'
    $report.execution['profile_config'] = $installedProfileConfig
    $report.execution['profile_config_consistent'] = $installedProfileConfigConsistent
    $report.performance['measurement_passed_groups'] = $measurementPassedGroups
    $report.performance['measurement_passed'] = ($Groups -eq 3 -and $measurementPassedGroups -eq 3)
    $report['qualification'] = [ordered]@{
        status=$(if($producerMode-ceq'formal'){$reportStatus}else{'unavailable'})
        hard_result_contract='installed-desktop-authoritative-observation/v1'
        hook_trust='manual'
        hook_callability='manual'
        hook_observations_blocking=$false
        reason=$(if($producerMode-ceq'formal'){'Derived from installed profile, workspace route, Direct completion, write, integrity, cleanup, performance, and source observations.'}else{"Non-formal producer mode: $producerMode"})
    }
}
$report.report_digest = Get-HarnessSha256Text -Content ($report | ConvertTo-Json -Depth 100 -Compress)
$outputParent = [IO.Path]::GetDirectoryName($OutputPath)
[void][IO.Directory]::CreateDirectory($outputParent)
[void](Write-HarnessAtomicText -WorkspaceRoot $outputParent -Path $OutputPath -Content (($report | ConvertTo-Json -Depth 100) + "`n"))
Write-Output "HOST_BENCHMARK_STATUS=$($report.status)"
Write-Output "HOST_BENCHMARK_GROUPS_PASSED=$passedGroups/$Groups"
Write-Output "HOST_BENCHMARK_REPORT=$OutputPath"
if ([string]$report.status -ceq 'unavailable') { Write-Output '[UNAVAILABLE] one or more real host measurements were unavailable'; exit 2 }
if (-not $eligible) { exit 1 }
exit 0
