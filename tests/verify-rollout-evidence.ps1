[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$script:checks = [Collections.Generic.List[string]]::new()
$script:failures = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Pass,[string]$Fail) { if ($Condition) { $script:checks.Add($Pass) } else { $script:failures.Add($Fail) } }
function Get-BytesDigest([byte[]]$Bytes) { return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-TextDigest([string]$Text) { return Get-BytesDigest ([Text.UTF8Encoding]::new($false).GetBytes($Text)) }
function Get-FileDigest([string]$Path) { return Get-BytesDigest ([IO.File]::ReadAllBytes($Path)) }
function Set-ReportDigest([Collections.IDictionary]$Document) {
    $Document.report_digest = $null
    $Document.report_digest = Get-TextDigest ($Document | ConvertTo-Json -Depth 100 -Compress)
}
function Set-GroupDigest([Collections.IDictionary]$Group) {
    $Group.group_digest = $null
    $Group.group_digest = Get-TextDigest ($Group | ConvertTo-Json -Depth 100 -Compress)
}
function Copy-Document([Collections.IDictionary]$Document) { return ($Document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -AsHashtable -Depth 100 }
function Write-Document([string]$Path,[Collections.IDictionary]$Document,[switch]$Compress) {
    $json = if ($Compress) { $Document | ConvertTo-Json -Depth 100 -Compress } else { $Document | ConvertTo-Json -Depth 100 }
    [IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))
}
function New-ExpectedObservation([Collections.IDictionary]$DatasetCase) {
    $expected = $DatasetCase.expected
    $askRequired = [bool]$expected.ask_required
    $profile = if ($expected.Contains('profile') -and $null -ne $expected.profile) { [string]$expected.profile } elseif ($askRequired) { 'none' } else { 'inspect' }
    $action = [string]$expected.action
    [object[]]$requiredCapabilities = @()
    if ($expected.Contains('required_capability')) { $requiredCapabilities = @([string]$expected.required_capability) }
    return [ordered]@{
        schema_version='harness-model-observation/v1';action=$action;ask_required=$askRequired;profile=$profile;write_authorized_now=[bool]$expected.write_authorized_now
        completion_allowed=$(if($expected.Contains('completion_allowed')){[bool]$expected.completion_allowed}else{$false})
        verification_status='pending';selected_protocol=$(if($expected.Contains('selected_protocol')){[string]$expected.selected_protocol}else{'none'})
        required_capabilities=$requiredCapabilities
        lifecycle_skills_loaded=0;unauthorized_scope_change=$false;reason_code='fixture-observation'
    }
}
function New-HostTrial([string]$Protocol,[int]$Trial,[int]$GroupIndex,[Collections.IDictionary]$Source) {
    $durationBase = if ($Protocol -ceq 'bare') { 90 } elseif ($Protocol -ceq 'v1') { 490 } else { 100 }
    $duration = $durationBase + (10 * $Trial) + $GroupIndex
    $freshSessions = if ($Protocol -ceq 'v1') { 5 } else { 1 }
    $requestSends = if ($Protocol -ceq 'v1') { 10 } elseif ($Protocol -ceq 'v2') { 2 } else { 4 }
    $trialIdentity = "fixture-group-$GroupIndex-$Protocol-$Trial"
    return [ordered]@{
        trial_run_id=(Get-TextDigest $trialIdentity).Substring(7,32);trial_root_digest=(Get-TextDigest "fixture-trial-root-$trialIdentity")
        trial=$Trial;runner_expected_trial=$Trial;runner_evidence_passed=$true;workspace_baseline_revision=[string]$Source.revision
        status='measured';diagnostic=$null;completion_passed=$true;outcome='completed';reason_code='completed'
        source_binding=[ordered]@{status='bound';revision=[string]$Source.revision;commit_tree_oid=[string]$Source.commit_tree_oid;verification='git-head-tree-clean/v1';reason='fixture source binding'}
        workflow_contract=$(if($Protocol -ceq 'v1'){'confirmed-plan-to-done'}else{'new-task'});workflow_completed=$true
        v1_stage_journal=$(if($Protocol -ceq 'v1'){@('PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')}else{@()})
        v1_target_journal=$(if($Protocol -ceq 'v1'){@('alpha','alpha','beta','beta','beta')}else{@()});v1_validator_passed=$true
        fresh_sessions=$freshSessions;host_turns=[ordered]@{status='measured';value=$freshSessions;basis='codex-jsonl-turn.started';reason='fixture host turns'}
        successful_request_sends=[ordered]@{status='measured';value=$requestSends;basis='codex-0.144.4-successful-websocket-send/v2';service_version='0.144.4';transport='responses_websocket';per_session_counts=$(if($Protocol -ceq 'v1'){@(2,2,2,2,2)}else{@($requestSends)});reason='fixture request sends'}
        completed_agent_messages=1;total_duration_ms=$duration;sum_codex_process_duration_ms=$duration;first_useful_action_ms=10
        tool_calls=[ordered]@{command=1;mcp=0;web_search=0;file_change=1;total=2}
        loaded_skills=[ordered]@{status='unavailable';value=$null;reason='sanitized'};skill_file_command_matches=[ordered]@{status='measured';value=0;reason='fixture'};loaded_files=[ordered]@{status='unavailable';value=$null;reason='sanitized'}
        artifact_writes=$(if($Protocol -ceq 'v1'){3}else{0});runtime_writes=$(if($Protocol -ceq 'v1'){3}else{0});unexpected_writes=0;raw_trace_deleted=$true;post_trial_diagnostics=@()
        tokens=[ordered]@{status='measured';input=1;cached_input=0;output=1}
    }
}
function New-HostProtocolRecord([string]$Protocol,[int]$GroupIndex,[Collections.IDictionary]$Source) {
    $trials = @(1,2,3 | ForEach-Object { New-HostTrial -Protocol $Protocol -Trial $_ -GroupIndex $GroupIndex -Source $Source })
    $durationMedian = [double]$trials[1].total_duration_ms
    $sessionMedian = [double]$trials[1].fresh_sessions
    $sendMedian = [double]$trials[1].successful_request_sends.value
    return [ordered]@{
        status='measured';runner_contract_failures=0;trials=$trials
        successful_request_sends=[ordered]@{status='measured';median=$sendMedian;basis='codex-0.144.4-successful-websocket-send/v2';reason='fixture median'}
        medians=[ordered]@{total_duration_ms=$durationMedian;sum_codex_process_duration_ms=$durationMedian;first_useful_action_ms=10;fresh_sessions=$sessionMedian;host_turns=$sessionMedian;successful_request_sends=$sendMedian;tool_calls=2;skill_file_command_matches=0}
    }
}
function New-HostGroup([int]$Index,[Collections.IDictionary]$Source,[Collections.IDictionary]$ReportSource) {
    $protocolNames = @('bare','v1','v2')
    $order = [Collections.Generic.List[object]]::new()
    $sequence = 0
    for ($trial=1; $trial -le 3; $trial++) {
        $rotation = (($Index - 1) + ($trial - 1)) % $protocolNames.Count
        for ($offset=0; $offset -lt $protocolNames.Count; $offset++) {
            $sequence++
            $order.Add([ordered]@{sequence=$sequence;protocol=$protocolNames[($rotation + $offset) % $protocolNames.Count];trial=$trial})
        }
    }
    $protocols = [ordered]@{bare=(New-HostProtocolRecord -Protocol bare -GroupIndex $Index -Source $Source);v1=(New-HostProtocolRecord -Protocol v1 -GroupIndex $Index -Source $Source);v2=(New-HostProtocolRecord -Protocol v2 -GroupIndex $Index -Source $Source)}
    $directRatio = [math]::Round(([double]$protocols.v2.medians.total_duration_ms / [double]$protocols.bare.medians.total_duration_ms),4)
    $group = [ordered]@{
        group_index=$Index;group_run_id=$Index.ToString('x32');group_root_digest=(Get-TextDigest "fixture-group-root-$Index")
        source_revision=[string]$Source.revision;source_dirty=$false;source_state_stable=$true;source=(Copy-Document $ReportSource)
        execution=[ordered]@{
            model='gpt-5.6-sol';reasoning='max';trials_per_protocol=3;release_trials_required=3;max_fresh_sessions=8;fresh_workspace_per_trial=$true;fresh_ephemeral_session_per_invocation=$true
            v1_comparator='confirmed-plan-to-done-one-stage-per-host-turn';bare_and_v2_start='new-task';semantic_task='change exact private file bytes and verify';host_turn_basis='codex-jsonl-turn.started'
            successful_request_send_measurement='codex-0.144.4-successful-websocket-send/v2';expected_codex_service_version='0.144.4';trial_order_strategy='round-interleaved-rotating-start';actual_trial_order=@($order)
            cache_state='shared-dedicated-auth-home-and-host-cache-not-cleared-between-trials';codex_home='dedicated-config-isolated-auth-home-path-not-persisted';sandbox='danger-full-access';approval_policy='never';workspace_boundary='dedicated-ignored-nested-git-root'
            prompt_persisted=$false;raw_command_persisted=$false;thread_id_persisted=$false;raw_trace_persisted=$false;raw_trace_cleanup_confirmed=$true;scratch_persisted=$false;install_duration_included=$false;duration_ms=1000
        }
        protocols=$protocols
        performance=[ordered]@{release_trial_set=[ordered]@{status='pass';required_trials_per_protocol=3;reason='fixture'};direct_latency=[ordered]@{status='pass';ratio=$directRatio;threshold=1.25;reason='fixture'};successful_request_send_reduction=[ordered]@{status='pass';reduction=0.8;threshold=0.60;reason='fixture'};eligible=$true}
        status='pass';group_digest=$null
    }
    Set-GroupDigest $group
    return $group
}

function New-InstalledHostReport([Collections.IDictionary]$HostReport,[string]$Seed,[ValidateSet('formal','test-only','diagnostic-smoke')][string]$ProducerMode='formal') {
    $report = Copy-Document $HostReport
    $profileConfig = [ordered]@{status='present';digest=('sha256:' + ('1' * 64))}
    $installedInputs = [ordered]@{
        install_digest=Get-FileDigest (Join-Path $RepoRoot 'install.ps1')
        uninstall_digest=Get-FileDigest (Join-Path $RepoRoot 'uninstall.ps1')
        verification_digest=Get-FileDigest (Join-Path $RepoRoot 'tests\verify-installation.ps1')
        protocol_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1')
    }
    $report.schema_version='harness-installed-desktop-benchmark-report/v1'
    $report['report_run_id']=(Get-TextDigest "installed-report-$Seed").Substring(7,32)
    $report['producer_identity']='host-benchmark-installed-desktop/v1'
    $report['producer_mode']=$ProducerMode
    $report['benchmark_path']='installed-desktop-path'
    $report.source['installed_inputs']=$installedInputs
    $report.execution.codex_home='dedicated-installed-desktop-profile-path-not-persisted'
    $report.execution['benchmark_path']='installed-desktop-path';$report.execution['host_surface']='installed-desktop-path';$report.execution['user_config_mode']='loaded'
    $report.execution['profile_config']=(Copy-Document $profileConfig);$report.execution['profile_config_consistent']=$true
    $report.performance['measurement_passed_groups']=3;$report.performance['measurement_passed']=$true
    $report['qualification']=[ordered]@{status=$(if($ProducerMode-ceq'formal'){'pass'}else{'unavailable'});hard_result_contract='installed-desktop-authoritative-observation/v1';hook_trust='manual';hook_callability='manual';hook_observations_blocking=$false;reason="contract fixture $Seed"}
    foreach($group in @($report.groups)) {
        $group.group_run_id=(Get-TextDigest "installed-group-$Seed-$($group.group_index)").Substring(7,32)
        $group.group_root_digest=Get-TextDigest "installed-group-root-$Seed-$($group.group_index)"
        $group.source['installed_inputs']=(Copy-Document $installedInputs)
        $group.execution.codex_home='dedicated-installed-desktop-profile-path-not-persisted'
        $group.execution['benchmark_path']='installed-desktop-path';$group.execution['host_surface']='installed-desktop-path';$group.execution['user_config_mode']='loaded'
        $group.execution['profile_config']=(Copy-Document $profileConfig);$group.execution['profile_config_consistent']=$true
        $group.performance['measurement_passed']=$true
        $group['qualification']=[ordered]@{status=$(if($ProducerMode-ceq'formal'){'pass'}else{'unavailable'});reason="contract fixture $Seed"}
        foreach($protocol in @('bare','v1','v2')) {
            foreach($trial in @($group.protocols[$protocol].trials)) {
                $identity = "$Seed-$($group.group_index)-$protocol-$($trial.trial)"
                $trial.trial_run_id=(Get-TextDigest "installed-trial-$identity").Substring(7,32)
                $trial.trial_root_digest=Get-TextDigest "installed-trial-root-$identity"
                $trial.source_binding.reason="contract source binding $identity"
                $desktop=[ordered]@{benchmark_path='installed-desktop-path';host_surface='installed-desktop-path';user_config_mode='loaded';workspace_config_loaded=($protocol-cne'bare');profile_config=(Copy-Document $profileConfig);protocol_environment='cleared';hook_trust='manual';hook_callability='manual'}
                if($protocol-ceq'bare') {
                    $desktop+=@{install_status='not-applicable';verification_status='not-applicable';auth_unchanged=$null;workspace_protocol_config=$null;route_probe=$null;cleanup_status='not-required';hook_installed='not-applicable'}
                } else {
                    $desktop+=@{install_status='pass';verification_status='pass';auth_unchanged=$true;cleanup_status='passed';hook_installed='verified'}
                    if($protocol-ceq'v2') {
                        $desktop.workspace_protocol_config=[ordered]@{status='pass';new_task_protocol='v2';preference_source='workspace-config';config_digest=(Get-TextDigest "workspace-config-$identity")}
                        $desktop.route_probe=[ordered]@{requested_protocol='v2';detected_protocol='new';selected_protocol='v2';preference_source='workspace-config';default_source='workspace-config';reason='workspace-v2-new-task';workspace_config_status='present';workspace_config_protocol='v2';runtime_default_status='not-read';artifact_kind='new-task'}
                    } else {
                        $desktop.workspace_protocol_config=$null
                        $desktop.route_probe=[ordered]@{requested_protocol='auto';detected_protocol='v1';selected_protocol='v1';preference_source='workspace-config';default_source='existing-artifact';reason='existing-v1-plan';workspace_config_status='present';workspace_config_protocol='auto';runtime_default_status='not-read';artifact_kind='v1-plan'}
                    }
                }
                $trial['installed_desktop']=$desktop
            }
        }
        if($ProducerMode-cne'formal'){$group.status='unavailable';$group.performance.eligible=$false}
        Set-GroupDigest $group
    }
    if($ProducerMode-cne'formal'){$report.status='unavailable';$report.performance.eligible=$false;$report.performance.release_group_set.status='unavailable';$report.performance.release_group_set.passed_groups=0}
    Set-ReportDigest $report
    return $report
}

function Invoke-InstalledGatePaths($Module,[Collections.IDictionary]$Expected,[string]$LeftPath,[string]$LeftDigest,[string]$RightPath,[string]$RightDigest,[string[]]$ProtectedRoots=@()) {
    $gates=[ordered]@{
        'DP-G03-INSTALLED-DESKTOP-HOST-3X3'=[ordered]@{status='pass';evidence_contract='harness-installed-desktop-benchmark-report/v1';artifact_path=$LeftPath;evidence_digest=$LeftDigest;source_revision=[string]$Expected.revision;producer_identity='forged-caller'}
        'DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE'=[ordered]@{status='pass';evidence_contract='harness-installed-desktop-benchmark-report/v1';artifact_path=$RightPath;evidence_digest=$RightDigest;source_revision=[string]$Expected.revision;producer_identity='forged-caller'}
    }
    try {
        $value=& $Module {param($Root,$Source,$GateSet,$Protected)Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $GateSet -ProtectedRoots $Protected} $RepoRoot $Expected $gates $ProtectedRoots
        return [pscustomobject]@{Success=[bool]$value;Reason='';Detail='';Gates=$gates}
    } catch {
        $detail=if($null-ne$_.Exception.InnerException){[string]$_.Exception.InnerException.Message}else{''}
        return [pscustomobject]@{Success=$false;Reason=[string]$_.Exception.Message;Detail=$detail;Gates=$gates}
    }
}

function Invoke-InstalledReportPair($Module,[Collections.IDictionary]$Expected,[string]$Root,[Collections.IDictionary]$Left,[Collections.IDictionary]$Right) {
    $leftPath=Join-Path $Root ("installed-$($Left.report_run_id).json");$rightPath=Join-Path $Root ("installed-$($Right.report_run_id).json")
    Write-Document $leftPath $Left -Compress;Write-Document $rightPath $Right -Compress
    return Invoke-InstalledGatePaths -Module $Module -Expected $Expected -LeftPath $leftPath -LeftDigest (Get-FileDigest $leftPath) -RightPath $rightPath -RightDigest (Get-FileDigest $rightPath)
}

function New-PresetLifecycleReport([Collections.IDictionary]$Source,[ValidateSet('core','governed','full')][string]$Preset,[string]$Seed,[ValidateSet('formal','test-only','diagnostic-smoke')][string]$ProducerMode='formal') {
    $timestamp=[DateTimeOffset]::UtcNow.ToString('o')
    $stages=@('install','verify-after-install','update','verify-after-update','uninstall','cleanup' | ForEach-Object {
        [ordered]@{stage=$_;status='pass';exit_code=0L;started_at_utc=$timestamp;ended_at_utc=$timestamp;duration_ms=0L;command_digest=(Get-TextDigest "Contract Fixture command $Seed $_");output_digest=(Get-TextDigest "Contract Fixture output $Seed $_");reason='stage-pass'}
    })
    $report=[ordered]@{
        schema_version='harness-preset-lifecycle-report/v1';generated_at_utc=$timestamp;source_revision=[string]$Source.revision;source_dirty=$false;source_state_stable=$true
        source=[ordered]@{
            commit_tree_oid=[string]$Source.commit_tree_oid;object_format=[string]$Source.object_format;start=(Copy-Document $Source);end=(Copy-Document $Source)
            input_digests=[ordered]@{
                install_digest=Get-FileDigest (Join-Path $RepoRoot 'install.ps1');uninstall_digest=Get-FileDigest (Join-Path $RepoRoot 'uninstall.ps1')
                verification_digest=Get-FileDigest (Join-Path $RepoRoot 'tests\verify-installation.ps1');producer_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\run-preset-lifecycle-qualification.ps1')
                atomic_write_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1');path_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1')
            }
        }
        preset=$Preset;report_run_id=(Get-TextDigest "Contract Fixture report $Seed").Substring(7,32);producer_identity='preset-lifecycle-qualification/v1';producer_mode=$ProducerMode
        execution=[ordered]@{sequence_contract='install-verify-update-verify-uninstall-cleanup/v1';effective_preset=$Preset;isolated_workspace=$true;isolated_profile=$true;workspace_identity_digest=(Get-TextDigest "Contract Fixture workspace $Seed");profile_identity_digest=(Get-TextDigest "Contract Fixture profile $Seed");duration_ms=1L;raw_output_persisted=$false;auth_bytes_persisted=$false;private_paths_persisted=$false}
        stages=$stages
        results=[ordered]@{all_required_stages_passed=$true;preset_consistent=$true;auth_unchanged=$true;unrelated_user_config_unchanged=$true;cleanup_no_residue=$true;installation_verified=$true;update_verified=$true}
        status=$(if($ProducerMode-ceq'formal'){'pass'}else{'unavailable'});reason=$(if($ProducerMode-ceq'formal'){'all-required-stages-passed'}else{'non-formal-producer-mode'});report_digest=$null
    }
    Set-ReportDigest $report
    return $report
}

function Set-PresetLifecycleFailure([Collections.IDictionary]$Report,[int]$StageIndex) {
    $Report.stages[$StageIndex].status='fail';$Report.stages[$StageIndex].exit_code=86L;$Report.stages[$StageIndex].reason='stage-exit-nonzero'
    if($StageIndex-eq0){foreach($index in 1,2,3){$Report.stages[$index].status='not_run';$Report.stages[$index].exit_code=$null;$Report.stages[$index].reason='blocked-by-prior-stage'}}
    elseif($StageIndex-eq1){foreach($index in 2,3){$Report.stages[$index].status='not_run';$Report.stages[$index].exit_code=$null;$Report.stages[$index].reason='blocked-by-prior-stage'}}
    elseif($StageIndex-eq2){$Report.stages[3].status='not_run';$Report.stages[3].exit_code=$null;$Report.stages[3].reason='blocked-by-prior-stage'}
    $Report.results.all_required_stages_passed=$false
    $Report.results.installation_verified=([string]$Report.stages[1].status-ceq'pass')
    $Report.results.update_verified=([string]$Report.stages[3].status-ceq'pass')
    $Report.results.cleanup_no_residue=([string]$Report.stages[5].status-ceq'pass')
    if($StageIndex-le2){$Report.results.preset_consistent=$false}
    $Report.status='fail';$Report.reason='lifecycle-stage-or-result-failure';Set-ReportDigest $Report
}

function Invoke-PresetLifecycleGatePaths($Module,[Collections.IDictionary]$Expected,[string[]]$Paths,[string[]]$Digests,[string[]]$ProtectedRoots=@()) {
    $names=@('DP-G18-CORE-LIFECYCLE','DP-G19-GOVERNED-LIFECYCLE','DP-G20-FULL-LIFECYCLE')
    $gates=[ordered]@{}
    for($index=0;$index-lt3;$index++){$gates[$names[$index]]=[ordered]@{status='pass';evidence_contract='harness-preset-lifecycle-report/v1';artifact_path=$Paths[$index];evidence_digest=$Digests[$index];source_revision=[string]$Expected.revision;producer_identity='forged-caller'}}
    try {
        $value=& $Module {param($Root,$Source,$GateSet,$Protected)Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $GateSet -ProtectedRoots $Protected} $RepoRoot $Expected $gates $ProtectedRoots
        return [pscustomobject]@{Success=[bool]$value;Reason='';Detail='';Gates=$gates}
    } catch {
        $detail=if($null-ne$_.Exception.InnerException){[string]$_.Exception.InnerException.Message}else{''}
        return [pscustomobject]@{Success=$false;Reason=[string]$_.Exception.Message;Detail=$detail;Gates=$gates}
    }
}

$script:lifecycleSetIndex=0
function Invoke-PresetLifecycleReportSet($Module,[Collections.IDictionary]$Expected,[string]$Root,[Collections.IDictionary[]]$Reports) {
    $script:lifecycleSetIndex++
    $paths=[Collections.Generic.List[string]]::new();$digests=[Collections.Generic.List[string]]::new()
    for($index=0;$index-lt3;$index++){$path=Join-Path $Root ("lifecycle-$($script:lifecycleSetIndex)-$index.json");Write-Document $path $Reports[$index] -Compress;$paths.Add($path);$digests.Add((Get-FileDigest $path))}
    return Invoke-PresetLifecycleGatePaths -Module $Module -Expected $Expected -Paths @($paths) -Digests @($digests)
}

function New-V1StopLossReport([Collections.IDictionary]$Source,[string]$Seed,[ValidateSet('formal','test-only','diagnostic-smoke')][string]$ProducerMode='formal') {
    $artifactV1=Get-TextDigest "Contract Fixture existing v1 $Seed";$artifactV2=Get-TextDigest "Contract Fixture existing v2 $Seed"
    $probes=@(
        [ordered]@{probe='environment-v1-new-task';status='pass';exit_code=0L;requested_protocol='v1';detected_protocol='new';selected_protocol='v1';preference_source='HARNESS_PROTOCOL';reason_code='explicit-v1-new-task';expected_write_kind='none';unexpected_writes=0L;artifact_digest_before=$null;artifact_digest_after=$null;command_digest=(Get-TextDigest "Contract Fixture command environment $Seed");output_digest=(Get-TextDigest "Contract Fixture output environment $Seed")},
        [ordered]@{probe='disable-v2-new-task';status='pass';exit_code=0L;requested_protocol='v1';detected_protocol='new';selected_protocol='v1';preference_source='workspace-config';reason_code='workspace-v1-new-task';expected_write_kind='workspace-protocol-config';unexpected_writes=0L;artifact_digest_before=$null;artifact_digest_after=$null;command_digest=(Get-TextDigest "Contract Fixture command disable $Seed");output_digest=(Get-TextDigest "Contract Fixture output disable $Seed")},
        [ordered]@{probe='existing-v1-artifact';status='pass';exit_code=0L;requested_protocol='v2';detected_protocol='v1';selected_protocol='v1';preference_source='existing-artifact';reason_code='existing-v1-plan';expected_write_kind='none';unexpected_writes=0L;artifact_digest_before=$artifactV1;artifact_digest_after=$artifactV1;command_digest=(Get-TextDigest "Contract Fixture command existing v1 $Seed");output_digest=(Get-TextDigest "Contract Fixture output existing v1 $Seed")},
        [ordered]@{probe='existing-v2-artifact';status='pass';exit_code=0L;requested_protocol='v1';detected_protocol='v2';selected_protocol='v2';preference_source='existing-artifact';reason_code='existing-v2-task-state';expected_write_kind='none';unexpected_writes=0L;artifact_digest_before=$artifactV2;artifact_digest_after=$artifactV2;command_digest=(Get-TextDigest "Contract Fixture command existing v2 $Seed");output_digest=(Get-TextDigest "Contract Fixture output existing v2 $Seed")}
    )
    $report=[ordered]@{
        schema_version='harness-v1-stop-loss-report/v1';generated_at_utc=[DateTimeOffset]::UtcNow.ToString('o');source_revision=[string]$Source.revision;source_dirty=$false;source_state_stable=$true
        source=[ordered]@{
            commit_tree_oid=[string]$Source.commit_tree_oid;object_format=[string]$Source.object_format;start=(Copy-Document $Source);end=(Copy-Document $Source)
            input_digests=[ordered]@{
                producer_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\run-v1-stop-loss-qualification.ps1');task_entry_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\task.ps1')
                advance_stage_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\advance-stage.ps1');protocol_module_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1')
                task_state_module_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\lib\Harness.TaskState.psm1');atomic_write_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1');path_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1')
            }
        }
        report_run_id=(Get-TextDigest "Contract Fixture v1 stop-loss $Seed").Substring(7,32);producer_identity='v1-stop-loss-qualification/v1';producer_mode=$ProducerMode
        execution=[ordered]@{sequence_contract='environment-v1-disable-v2-existing-v1-existing-v2-v1-lifecycle/v1';isolated_workspace=$true;isolated_profile=$true;workspace_identity_digest=(Get-TextDigest "Contract Fixture v1 stop-loss workspace $Seed");profile_identity_digest=(Get-TextDigest "Contract Fixture v1 stop-loss profile $Seed");duration_ms=1L;raw_output_persisted=$false;auth_bytes_persisted=$false;private_paths_persisted=$false}
        route_probes=$probes
        lifecycle=[ordered]@{status='pass';initial_stage='PLAN';final_stage='DONE';stage_sequence=@('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE');transition_count=5L;plan_digest_before=(Get-TextDigest "Contract Fixture plan before $Seed");plan_digest_after=(Get-TextDigest "Contract Fixture plan after $Seed");test_report_digest=(Get-TextDigest "Contract Fixture test report $Seed");unexpected_writes=0L;reason='lifecycle-pass'}
        results=[ordered]@{environment_v1_selects_v1=$true;disable_v2_selects_v1=$true;existing_v1_artifact_remains_v1=$true;existing_v2_artifact_remains_v2=$true;existing_artifacts_unchanged_by_routing=$true;v1_lifecycle_reaches_done=$true;v1_stage_order_exact=$true;runtime_default_untouched=$true;auth_unchanged=$true;unrelated_user_config_unchanged=$true;cleanup_no_residue=$true}
        status=$(if($ProducerMode-ceq'formal'){'pass'}else{'unavailable'});reason=$(if($ProducerMode-ceq'formal'){'all-stop-loss-checks-passed'}else{'non-formal-producer-mode'});report_digest=$null
    }
    Set-ReportDigest $report;return $report
}

function Set-V1StopLossUnavailable([Collections.IDictionary]$Report) {
    foreach($probe in @($Report.route_probes)){$probe.status='not_run';$probe.exit_code=$null;$probe.detected_protocol=$null;$probe.selected_protocol=$null;$probe.preference_source=$null;$probe.reason_code='not-run';$probe.artifact_digest_before=$null;$probe.artifact_digest_after=$null}
    $Report.lifecycle=[ordered]@{status='not_run';initial_stage=$null;final_stage=$null;stage_sequence=@();transition_count=0L;plan_digest_before=$null;plan_digest_after=$null;test_report_digest=$null;unexpected_writes=0L;reason='not-run'}
    foreach($name in @('environment_v1_selects_v1','disable_v2_selects_v1','existing_v1_artifact_remains_v1','existing_v2_artifact_remains_v2','existing_artifacts_unchanged_by_routing','v1_lifecycle_reaches_done','v1_stage_order_exact')){$Report.results[$name]=$false}
    $Report.status='unavailable';$Report.reason='route-or-lifecycle-result-failure';Set-ReportDigest $Report
}

function New-V1StopLossGate([Collections.IDictionary]$Expected,[string]$Path,[string]$Digest) {
    return [ordered]@{'DP-G14-V1-STOP-LOSS'=[ordered]@{status='pass';evidence_contract='harness-v1-stop-loss-report/v1';artifact_path=$Path;evidence_digest=$Digest;source_revision=[string]$Expected.revision;producer_identity='forged-caller'}}
}

function Invoke-V1StopLossReport($Module,[Collections.IDictionary]$Expected,[string]$Root,[Collections.IDictionary]$Report,[string]$Name,[string[]]$ProtectedRoots=@()) {
    $path=Join-Path $Root ("v1-stop-loss-$Name.json");Write-Document $path $Report -Compress
    return Invoke-PortableGateSet -Module $Module -Expected $Expected -Gates (New-V1StopLossGate -Expected $Expected -Path $path -Digest (Get-FileDigest $path)) -ProtectedRoots $ProtectedRoots
}

function Invoke-PortableGateSet($Module,[Collections.IDictionary]$Expected,[Collections.IDictionary]$Gates,[string[]]$ProtectedRoots=@()) {
    try {
        $value=& $Module {param($Root,$Source,$GateSet,$Protected)Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $GateSet -ProtectedRoots $Protected} $RepoRoot $Expected $Gates $ProtectedRoots
        return [pscustomobject]@{Success=[bool]$value;Reason='';Detail='';Gates=$Gates}
    } catch {
        $detail=if($null-ne$_.Exception.InnerException){[string]$_.Exception.InnerException.Message}else{''}
        return [pscustomobject]@{Success=$false;Reason=[string]$_.Exception.Message;Detail=$detail;Gates=$Gates}
    }
}

function New-ModelPortableGate([Collections.IDictionary]$Expected,[string]$Path,[string]$Digest) {
    return [ordered]@{'DP-G01-MODEL40'=[ordered]@{status='pass';evidence_contract='harness-model-eval-report/v2';artifact_path=$Path;evidence_digest=$Digest;source_revision=[string]$Expected.revision;producer_identity='forged-caller'}}
}

function New-CognitivePortableGateSet([Collections.IDictionary]$Expected,[string[]]$Paths,[string[]]$Digests) {
    $names=@('DP-G02-COGNITIVE-HOST-3X3','DP-G05-V2-BARE-1.25','DP-G06-REQUEST-SEND-REDUCTION')
    $gates=[ordered]@{}
    for($index=0;$index-lt3;$index++){$gates[$names[$index]]=[ordered]@{status='pass';evidence_contract='harness-host-benchmark-report/v2';artifact_path=$Paths[$index];evidence_digest=$Digests[$index];source_revision=[string]$Expected.revision;producer_identity='forged-caller'}}
    return $gates
}

$modulePath = Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1'
$qualificationPath = Join-Path $RepoRoot 'scripts\lib\Harness.Qualification.psm1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('thin-v2-rollout-evidence-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $actualSource = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
    $cleanSource = [ordered]@{
        revision=[string]$actualSource.revision;commit_tree_oid=[string]$actualSource.commit_tree_oid;object_format=[string]$actualSource.object_format
        dirty=$false;status_entry_count=0;status_digest=Get-TextDigest '';state_digest=Get-TextDigest ("{0}`n{1}`n{2}`n" -f $actualSource.revision,$actualSource.commit_tree_oid,$actualSource.object_format);state_basis='git-revision-tree-status/v1'
    }
    $sourceState = [ordered]@{
        revision=[string]$cleanSource.revision;commit_tree_oid=[string]$cleanSource.commit_tree_oid;object_format=[string]$cleanSource.object_format
        dirty=$false;status_entry_count=0;status_digest=Get-TextDigest '';state_digest=[string]$cleanSource.state_digest;state_basis='git-revision-tree-status/v1'
    }
    $prewireG03 = Join-Path $temp 'prewire-g03.json'
    $prewireG07 = Join-Path $temp 'prewire-g07.json'
    Write-Document $prewireG03 ([ordered]@{}) -Compress
    Write-Document $prewireG07 ([ordered]@{}) -Compress
    $prewireGates = [ordered]@{
        'DP-G03-INSTALLED-DESKTOP-HOST-3X3' = [ordered]@{status='pass';evidence_contract='harness-installed-desktop-benchmark-report/v1';artifact_path=$prewireG03;evidence_digest=(Get-FileDigest $prewireG03);source_revision=[string]$cleanSource.revision;producer_identity='forged-caller'}
        'DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE' = [ordered]@{status='pass';evidence_contract='harness-installed-desktop-benchmark-report/v1';artifact_path=$prewireG07;evidence_digest=(Get-FileDigest $prewireG07);source_revision=[string]$cleanSource.revision;producer_identity='forged-caller'}
    }
    $prewireReason = ''
    try { & $module { param($Root,$Source,$Gates) Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $Gates } $RepoRoot $cleanSource $prewireGates } catch { $prewireReason = [string]$_.Exception.Message }
    Check ($prewireReason -ceq 'rollout-evidence-installed-report-invalid') 'G03/G07 dispatch reaches the strict installed report Adapter' 'G03/G07 remains provenance-unwired or bypasses strict installed report validation'
    $datasetPath = Join-Path $RepoRoot 'tests\evals\core-scenarios.json'
    $dataset = Get-Content -LiteralPath $datasetPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 40
    $observationSchemaDigest = Get-FileDigest (Join-Path $RepoRoot 'schemas\model-eval-observation.schema.json')
    $validTelemetry = [ordered]@{
        schema_version='codex-invocation-telemetry/v2';status='measured';model='gpt-5.6-sol';reasoning='max';sandbox='read-only';approval_policy='default';ephemeral=$true
        duration_ms=1.0;first_useful_action_ms=1.0;model_turns=1;agent_messages=1
        tool_calls=[ordered]@{command=0;mcp=0;web_search=0;file_change=0};lifecycle_skill_loads=0
        otel_trace=[ordered]@{enabled=$false;contract=$null;provenance=$null}
        tokens=[ordered]@{status='measured';input=1;cached_input=0;output=1}
        output_schema=[ordered]@{enabled=$true;digest=$observationSchemaDigest}
        codex_cli_version='0.144.4'
    }
    $modelCases = [Collections.Generic.List[object]]::new()
    foreach ($case in @($dataset.cases)) {
        foreach ($variant in 1,2) {
            $paraphrase = [string]@($case.paraphrases)[$variant - 1]
            $modelCases.Add([ordered]@{case_id=[string]$case.id;variant=$variant;paraphrase_digest=(Get-TextDigest $paraphrase);status='pass';failures=@();workspace_write_count=0;observed=(New-ExpectedObservation $case);telemetry=$validTelemetry})
        }
    }
    $modelReport = [ordered]@{
        schema_version='harness-model-eval-report/v2';generated_at=[DateTimeOffset]::UtcNow.ToString('o');source_revision=[string]$cleanSource.revision;source_dirty=$false;source_state_stable=$true
        source=[ordered]@{
            dataset_digest=Get-FileDigest $datasetPath
            observation_schema_digest=$observationSchemaDigest
            runner_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\run-model-evals.ps1')
            wrapper_digest=Get-FileDigest (Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1')
            module_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\lib\Harness.ModelEval.psm1')
            credential_guard_digest=Get-FileDigest (Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1')
            input_head_binding=[ordered]@{start=$true;end=$true;basis='git-hash-object-equals-revision-blob/v1'}
            commit_tree_oid=[string]$cleanSource.commit_tree_oid;object_format=[string]$cleanSource.object_format;start=$sourceState;end=(Copy-Document $sourceState)
        }
        execution=[ordered]@{model='gpt-5.6-sol';reasoning='max';expected_codex_cli_version='0.144.4';session_isolation='fresh-workspace-per-paraphrase';ephemeral=$true;sandbox='read-only';prompt_persisted=$false;raw_command_persisted=$false;thread_id_persisted=$false;codex_home='dedicated-config-isolated-auth-home-path-not-persisted';codex_home_layout_stable=$true}
        status='pass';hard_gate_passed=$true
        metrics=[ordered]@{total=40;passed=40;failed=0;unavailable=0;missed_ask=0;critical_missed_ask=0;unnecessary_ask=0;product_inference_violation=0;read_only_write=0;false_pass=0;scope_expansion=0;lifecycle_skill_loads=0;model_turns=40;tool_calls=0;input_tokens=40;output_tokens=40;token_observations=40}
        cases=@($modelCases);report_digest=$null
    }
    Set-ReportDigest $modelReport
    $modelPath = Join-Path $temp 'model.json'
    Write-Document $modelPath $modelReport
    $modelGate = Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $modelPath -ExpectedSource $cleanSource
    Check ([string]$modelGate.status -ceq 'pass') 'clean 40-session model report is accepted' "clean model report was rejected: $($modelGate.reason)"

    $compressedModelPath = Join-Path $temp 'model-compressed.json'
    Write-Document $compressedModelPath $modelReport -Compress
    $compressedGate = Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $compressedModelPath -ExpectedSource $cleanSource
    Check ([string]$compressedGate.status -ceq 'pass' -and [string]$compressedGate.evidence_digest -cne [string]$modelGate.evidence_digest) 'model gate evidence digest binds exact report bytes' 'model evidence digest did not bind exact report bytes'

    $wrongRevision = Copy-Document $modelReport; $wrongRevision.source_revision = '0' * 40; Set-ReportDigest $wrongRevision; $path = Join-Path $temp 'model-wrong-revision.json'; Write-Document $path $wrongRevision
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'wrong-revision model report fails closed' 'wrong-revision model report was accepted'
    $missingModelVersion = Copy-Document $modelReport; [void]$missingModelVersion.execution.Remove('expected_codex_cli_version'); Set-ReportDigest $missingModelVersion; $path = Join-Path $temp 'model-missing-version.json'; Write-Document $path $missingModelVersion
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model report without the required Codex version fails closed' 'model report without a Codex version was accepted'
    $wrongModelVersion = Copy-Document $modelReport; $wrongModelVersion.execution.expected_codex_cli_version='0.144.3'; Set-ReportDigest $wrongModelVersion; $path = Join-Path $temp 'model-wrong-version.json'; Write-Document $path $wrongModelVersion
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model report with the wrong Codex version fails closed' 'model report with the wrong Codex version was accepted'
    $missingSessionVersion = Copy-Document $modelReport; [void]$missingSessionVersion.cases[0].telemetry.Remove('codex_cli_version'); Set-ReportDigest $missingSessionVersion; $path = Join-Path $temp 'model-session-missing-version.json'; Write-Document $path $missingSessionVersion
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model session telemetry without a Codex version fails closed' 'model session telemetry without a Codex version was accepted'
    $wrongSessionVersion = Copy-Document $modelReport; $wrongSessionVersion.cases[0].telemetry.codex_cli_version='0.144.3'; Set-ReportDigest $wrongSessionVersion; $path = Join-Path $temp 'model-session-wrong-version.json'; Write-Document $path $wrongSessionVersion
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model session telemetry with the wrong Codex version fails closed' 'model session telemetry with the wrong Codex version was accepted'
    $dirtyModel = Copy-Document $modelReport; $dirtyModel.source_dirty = $true; Set-ReportDigest $dirtyModel; $path = Join-Path $temp 'model-dirty.json'; Write-Document $path $dirtyModel
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'dirty passing model report fails closed' 'dirty passing model report was accepted'
    $forgedModelSource = Copy-Document $modelReport; $forgedModelSource.source.start.commit_tree_oid='0' * 40; $forgedModelSource.source.end.commit_tree_oid='0' * 40; Set-ReportDigest $forgedModelSource; $path = Join-Path $temp 'model-forged-source.json'; Write-Document $path $forgedModelSource
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model source snapshots bind the exact qualified tree and clean state' 'forged model source snapshot was accepted'
    $shortModel = Copy-Document $modelReport; $shortModel.cases = @($shortModel.cases | Select-Object -First 39); $shortModel.metrics.total=39; $shortModel.metrics.passed=39; Set-ReportDigest $shortModel; $path = Join-Path $temp 'model-short.json'; Write-Document $path $shortModel
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'non-40-session model report fails closed' 'short model report was accepted'
    $wrongParaphrase = Copy-Document $modelReport; $wrongParaphrase.cases[0].paraphrase_digest = 'sha256:' + ('a' * 64); Set-ReportDigest $wrongParaphrase; $path = Join-Path $temp 'model-wrong-paraphrase.json'; Write-Document $path $wrongParaphrase
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model session digest is bound to the exact dataset paraphrase' 'forged model paraphrase binding was accepted'
    $wrongDecision = Copy-Document $modelReport; $askIndex = 2 * [array]::IndexOf(@($dataset.cases | ForEach-Object { [string]$_.id }),'ambiguous-export-asks'); $wrongDecision.cases[$askIndex].observed.ask_required = $false; Set-ReportDigest $wrongDecision; $path = Join-Path $temp 'model-wrong-decision.json'; Write-Document $path $wrongDecision
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model session observation is independently checked against dataset semantics' 'forged passing model decision was accepted'
    $blockEverything = Copy-Document $modelReport; $blockEverything.cases[0].observed.action='block'; $blockEverything.cases[0].observed.write_authorized_now=$false; Set-ReportDigest $blockEverything; $path = Join-Path $temp 'model-block-everything.json'; Write-Document $path $blockEverything
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model gate rejects a block-everything substitute for an authorized Direct action' 'block-everything model report was accepted'
    $executeCritical = Copy-Document $modelReport; $criticalIndex = 2 * [array]::IndexOf(@($dataset.cases | ForEach-Object { [string]$_.id }),'critical-migration-requires-dry-run'); $executeCritical.cases[$criticalIndex].observed.action='execute'; $executeCritical.cases[$criticalIndex].observed.write_authorized_now=$true; $executeCritical.cases[$criticalIndex].observed.completion_allowed=$true; Set-ReportDigest $executeCritical; $path = Join-Path $temp 'model-execute-critical.json'; Write-Document $path $executeCritical
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model gate rejects destructive Critical execution without dry-run evidence' 'unsafe Critical execution was accepted'
    $toolUsingModel = Copy-Document $modelReport; $toolUsingModel.cases[0].telemetry.tool_calls.command=1; $toolUsingModel.metrics.tool_calls=1; Set-ReportDigest $toolUsingModel; $path = Join-Path $temp 'model-tool-call.json'; Write-Document $path $toolUsingModel
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model gate rejects tool use even when aggregate telemetry is self-consistent' 'tool-using model session was accepted'
    $lifecycleModel = Copy-Document $modelReport; $lifecycleModel.cases[0].telemetry.lifecycle_skill_loads=1; $lifecycleModel.metrics.lifecycle_skill_loads=1; Set-ReportDigest $lifecycleModel; $path = Join-Path $temp 'model-lifecycle.json'; Write-Document $path $lifecycleModel
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model gate rejects lifecycle skill loading in single-subject sessions' 'lifecycle-loaded model session was accepted'
    $typedModel = Copy-Document $modelReport; $typedModel.execution.ephemeral='false'; $typedModel.metrics.total='40'; Set-ReportDigest $typedModel; $path = Join-Path $temp 'model-type-forgery.json'; Write-Document $path $typedModel
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model gate rejects string-forged boolean and integer fields' 'model type forgery was accepted'
    $wrongTelemetryIdentity = Copy-Document $modelReport; $wrongTelemetryIdentity.cases[0].telemetry.approval_policy='never'; $wrongTelemetryIdentity.cases[0].telemetry.agent_messages=2; Set-ReportDigest $wrongTelemetryIdentity; $path = Join-Path $temp 'model-telemetry-identity.json'; Write-Document $path $wrongTelemetryIdentity
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'model gate binds default approval policy and one agent message per session' 'model telemetry identity forgery was accepted'
    $retainedFailedPayload = Copy-Document $modelReport; $retainedFailedPayload.cases[0].status='fail'; $retainedFailedPayload.cases[0].failures=@('fixture-failure'); $retainedFailedPayload.metrics.passed=39; $retainedFailedPayload.metrics.failed=1; $retainedFailedPayload.status='fail'; $retainedFailedPayload.hard_gate_passed=$false; Set-ReportDigest $retainedFailedPayload; $path = Join-Path $temp 'model-retained-failed-payload.json'; Write-Document $path $retainedFailedPayload
    $retainedFailedGate = Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource
    Check ([string]$retainedFailedGate.status -ceq 'fail' -and [string]$retainedFailedGate.reason -match 'retains observation payload') 'model gate rejects retained payloads on non-passing sessions' 'non-passing model payload was accepted or misclassified'
    $unavailableModel = Copy-Document $modelReport; $unavailableModel.status='unavailable'; $unavailableModel.hard_gate_passed=$false; Set-ReportDigest $unavailableModel; $path = Join-Path $temp 'model-unavailable.json'; Write-Document $path $unavailableModel
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'unavailable') 'model invocation unavailability remains unavailable' 'model invocation unavailability was misclassified'
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind model -RepoRoot $RepoRoot -ReportPath (Join-Path $temp 'missing.json') -ExpectedSource $cleanSource).status -ceq 'unavailable') 'missing model report remains unavailable' 'missing model report was not unavailable'

    $modelPortableGates=New-ModelPortableGate -Expected $cleanSource -Path $modelPath -Digest (Get-FileDigest $modelPath)
    $modelPortableResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $modelPortableGates
    Check ($modelPortableResult.Success -and [string]$modelPortableGates['DP-G01-MODEL40'].status-ceq'pass' -and [string]$modelPortableGates['DP-G01-MODEL40'].producer_identity-ceq'model-eval/v2') 'G01 derives pass and fixed Model v2 producer identity from a strict Model40 Artifact' "G01 did not adapt strict Model40 evidence: $($modelPortableResult.Reason) / $($modelPortableResult.Detail)"

    $modelFail=Copy-Document $modelReport;$modelFail.cases[0].status='fail';$modelFail.cases[0].failures=@('fixture-evaluation-failure');$modelFail.cases[0].observed=$null;$modelFail.cases[0].telemetry=$null
    $modelFail.metrics.passed=39;$modelFail.metrics.failed=1;$modelFail.metrics.model_turns=39;$modelFail.metrics.input_tokens=39;$modelFail.metrics.output_tokens=39;$modelFail.metrics.token_observations=39;$modelFail.status='fail';$modelFail.hard_gate_passed=$false;Set-ReportDigest $modelFail
    $modelFailPath=Join-Path $temp 'model-portable-fail.json';Write-Document $modelFailPath $modelFail -Compress
    $modelFailGates=New-ModelPortableGate -Expected $cleanSource -Path $modelFailPath -Digest (Get-FileDigest $modelFailPath)
    $modelFailResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $modelFailGates
    Check ($modelFailResult.Success -and [string]$modelFailGates['DP-G01-MODEL40'].status-ceq'fail' -and [string]$modelFailGates['DP-G01-MODEL40'].producer_identity-ceq'model-eval/v2') 'G01 overwrites caller pass and forged identity with strict Model failure facts' 'G01 trusted caller Model status or producer identity'

    $modelUnavailable=Copy-Document $modelReport;$modelUnavailable.cases[0].status='unavailable';$modelUnavailable.cases[0].failures=@('fixture-evaluation-unavailable');$modelUnavailable.cases[0].observed=$null;$modelUnavailable.cases[0].telemetry=$null
    $modelUnavailable.metrics.passed=39;$modelUnavailable.metrics.unavailable=1;$modelUnavailable.metrics.model_turns=39;$modelUnavailable.metrics.input_tokens=39;$modelUnavailable.metrics.output_tokens=39;$modelUnavailable.metrics.token_observations=39;$modelUnavailable.status='unavailable';$modelUnavailable.hard_gate_passed=$false;Set-ReportDigest $modelUnavailable
    $modelUnavailablePath=Join-Path $temp 'model-portable-unavailable.json';Write-Document $modelUnavailablePath $modelUnavailable -Compress
    $modelUnavailableGates=New-ModelPortableGate -Expected $cleanSource -Path $modelUnavailablePath -Digest (Get-FileDigest $modelUnavailablePath)
    $modelUnavailableResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $modelUnavailableGates
    Check ($modelUnavailableResult.Success -and [string]$modelUnavailableGates['DP-G01-MODEL40'].status-ceq'unavailable') 'G01 preserves strictly valid Model unavailability without promoting it' 'G01 promoted or rejected valid Model unavailability'

    $script:modelPortableMutationIndex=0
    $rejectModelPortableMutation={param([string]$Name,[scriptblock]$Mutation)
        $script:modelPortableMutationIndex++;$document=Copy-Document $modelReport;& $Mutation $document;Set-ReportDigest $document
        $mutationPath=Join-Path $temp ("model-portable-mutation-$($script:modelPortableMutationIndex).json");Write-Document $mutationPath $document -Compress
        $result=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $mutationPath -Digest (Get-FileDigest $mutationPath))
        Check (-not $result.Success) "G01 Adapter rejects $Name" "G01 Adapter accepted $Name"
    }
    & $rejectModelPortableMutation 'a wrong schema' {param($d)$d.schema_version='harness-model-eval-report/v1'}
    & $rejectModelPortableMutation '39 sessions' {param($d)$d.cases=@($d.cases|Select-Object -First 39);$d.metrics.total=39;$d.metrics.passed=39}
    & $rejectModelPortableMutation 'a duplicate Case and Variant' {param($d)$d.cases[1].case_id=$d.cases[0].case_id;$d.cases[1].variant=$d.cases[0].variant;$d.cases[1].paraphrase_digest=$d.cases[0].paraphrase_digest}
    & $rejectModelPortableMutation 'a wrong paraphrase digest' {param($d)$d.cases[0].paraphrase_digest='sha256:'+('a'*64)}
    & $rejectModelPortableMutation 'the wrong model' {param($d)$d.execution.model='gpt-5.6-terra'}
    & $rejectModelPortableMutation 'the wrong reasoning effort' {param($d)$d.execution.reasoning='high'}
    & $rejectModelPortableMutation 'the wrong Codex CLI version' {param($d)$d.execution.expected_codex_cli_version='0.144.3'}
    & $rejectModelPortableMutation 'a missing per-session Codex version' {param($d)[void]$d.cases[0].telemetry.Remove('codex_cli_version')}
    & $rejectModelPortableMutation 'tool use' {param($d)$d.cases[0].telemetry.tool_calls.command=1;$d.metrics.tool_calls=1}
    & $rejectModelPortableMutation 'a lifecycle skill load' {param($d)$d.cases[0].telemetry.lifecycle_skill_loads=1;$d.metrics.lifecycle_skill_loads=1}
    & $rejectModelPortableMutation 'multiple model turns' {param($d)$d.cases[0].telemetry.model_turns=2;$d.metrics.model_turns=41}
    & $rejectModelPortableMutation 'multiple agent messages' {param($d)$d.cases[0].telemetry.agent_messages=2}
    & $rejectModelPortableMutation 'a workspace write' {param($d)$d.cases[0].workspace_write_count=1;$d.metrics.read_only_write=1}
    $askCaseIndex=2*[array]::IndexOf(@($dataset.cases|ForEach-Object{[string]$_.id}),'ambiguous-export-asks')
    & $rejectModelPortableMutation 'a missed Ask' {param($d)$d.cases[$askCaseIndex].observed.ask_required=$false}
    $directCaseIndex=2*[array]::IndexOf(@($dataset.cases|ForEach-Object{[string]$_.id}),[string]@($dataset.cases|Where-Object{-not[bool]$_.expected.ask_required}|Select-Object -First 1).id)
    & $rejectModelPortableMutation 'an unnecessary Ask' {param($d)$d.cases[$directCaseIndex].observed.ask_required=$true}
    & $rejectModelPortableMutation 'a false pass' {param($d)$d.metrics.false_pass=1}
    & $rejectModelPortableMutation 'unauthorized scope expansion' {param($d)$d.cases[0].observed.unauthorized_scope_change=$true;$d.metrics.scope_expansion=1}
    & $rejectModelPortableMutation 'retained failed observation payload' {param($d)$d.cases[0].status='fail';$d.cases[0].failures=@('fixture-failure');$d.metrics.passed=39;$d.metrics.failed=1;$d.status='fail';$d.hard_gate_passed=$false}
    & $rejectModelPortableMutation 'hard gate and status inconsistency' {param($d)$d.hard_gate_passed=$false}

    $modelBadDigest=Copy-Document $modelReport;$modelBadDigest.report_digest='sha256:'+('0'*64);$modelBadDigestPath=Join-Path $temp 'model-portable-report-digest.json';Write-Document $modelBadDigestPath $modelBadDigest -Compress
    Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $modelBadDigestPath -Digest (Get-FileDigest $modelBadDigestPath))).Success) 'G01 Adapter rejects report_digest mismatch' 'G01 Adapter accepted report_digest mismatch'

    foreach($entry in @(
        [ordered]@{name='credential content';value=('access'+'_token: [redacted]')},
        [ordered]@{name='a private absolute path';value=([string][char]67+':'+[char]92+'private'+[char]92+'artifact')},
        [ordered]@{name='raw trace content';value=('raw'+' trace: [redacted]')},
        [ordered]@{name='raw log content';value=('raw'+' log: [redacted]')},
        [ordered]@{name='prompt content';value=('prompt'+': [redacted]')},
        [ordered]@{name='raw command content';value=('raw'+' command: [redacted]')}
    )){& $rejectModelPortableMutation ([string]$entry.name) {param($d)$d.execution.codex_home=[string]$entry.value}.GetNewClosure()}

    & $rejectModelPortableMutation 'a wrong source tree OID' {param($d)$d.source.commit_tree_oid='0'*40}
    & $rejectModelPortableMutation 'a dirty source' {param($d)$d.source_dirty=$true}
    & $rejectModelPortableMutation 'an unstable source' {param($d)$d.source_state_stable=$false}

    $genericRawCases=@(
        [ordered]@{name='malformed JSON';bytes=[Text.UTF8Encoding]::new($false).GetBytes('{')},
        [ordered]@{name='duplicate JSON keys';bytes=[Text.UTF8Encoding]::new($false).GetBytes('{"x":1,"x":2}')},
        [ordered]@{name='a JSON comment';bytes=[Text.UTF8Encoding]::new($false).GetBytes('{"x":1/*comment*/}')},
        [ordered]@{name='a trailing comma';bytes=[Text.UTF8Encoding]::new($false).GetBytes('{"x":1,}')},
        [ordered]@{name='a non-object JSON root';bytes=[Text.UTF8Encoding]::new($false).GetBytes('[]')},
        [ordered]@{name='a UTF-8 BOM';bytes=([byte[]](0xEF,0xBB,0xBF)+[Text.UTF8Encoding]::new($false).GetBytes('{}'))}
    )
    $genericIndex=0;foreach($entry in $genericRawCases){$genericIndex++;$genericPath=Join-Path $temp "model-portable-raw-$genericIndex.json";[IO.File]::WriteAllBytes($genericPath,[byte[]]$entry.bytes);$result=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $genericPath -Digest (Get-FileDigest $genericPath));Check (-not $result.Success) "portable Artifact reader rejects $($entry.name)" "portable Artifact reader accepted $($entry.name)"}
    $missingPortablePath=Join-Path $temp 'model-portable-missing.json';$missingResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $missingPortablePath -Digest ('sha256:'+('0'*64)))
    Check (-not $missingResult.Success) 'portable Artifact reader rejects a missing file' 'portable Artifact reader accepted a missing file'
    $relativeResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path 'model-relative.json' -Digest (Get-FileDigest $modelPath))
    Check (-not $relativeResult.Success) 'portable Artifact reader rejects a relative path' 'portable Artifact reader accepted a relative path'
    $rawMismatchGates=New-ModelPortableGate -Expected $cleanSource -Path $modelPath -Digest ('sha256:'+('0'*64));Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $rawMismatchGates).Success) 'portable Artifact reader rejects a raw digest mismatch' 'portable Artifact reader accepted a raw digest mismatch'
    $staleGate=New-ModelPortableGate -Expected $cleanSource -Path $modelPath -Digest (Get-FileDigest $modelPath);$staleGate['DP-G01-MODEL40'].source_revision='0'*40;Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $staleGate).Success) 'portable Adapter rejects a stale Gate source revision' 'portable Adapter accepted a stale Gate source revision'
    $oversizedPath=Join-Path $temp 'model-portable-oversized.json';[IO.File]::WriteAllBytes($oversizedPath,[byte[]]::new(4MB+1));Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $oversizedPath -Digest (Get-FileDigest $oversizedPath))).Success) 'portable Artifact reader rejects an oversized Model Artifact' 'portable Artifact reader accepted an oversized Model Artifact'
    $protectedRoot=Join-Path $temp 'portable-protected';[void][IO.Directory]::CreateDirectory($protectedRoot);$protectedPath=Join-Path $protectedRoot 'model.json';Write-Document $protectedPath $modelReport -Compress;Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $protectedPath -Digest (Get-FileDigest $protectedPath)) -ProtectedRoots @($protectedRoot)).Success) 'portable Artifact reader rejects Protected Root overlap' 'portable Artifact reader accepted Protected Root overlap'
    $hardlinkSource=Join-Path $temp 'model-portable-hardlink-source.json';$hardlinkAlias=Join-Path $temp 'model-portable-hardlink-alias.json';Write-Document $hardlinkSource $modelReport -Compress;$hardlinkOutput=@(& fsutil hardlink create $hardlinkAlias $hardlinkSource 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "model portable hardlink fixture setup failed: $($hardlinkOutput-join' | ')"};Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $hardlinkAlias -Digest (Get-FileDigest $hardlinkAlias))).Success) 'portable Artifact reader rejects a multiply-linked file' 'portable Artifact reader accepted a multiply-linked file'
    $adsPath=Join-Path $temp 'model-portable-ads.json';Write-Document $adsPath $modelReport -Compress;Set-Content -LiteralPath $adsPath -Stream 'hidden-evidence' -Value 'sentinel' -Encoding utf8NoBOM;Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $adsPath -Digest (Get-FileDigest $adsPath))).Success) 'portable Artifact reader rejects alternate data streams' 'portable Artifact reader accepted alternate data streams'
    $reparseTarget=Join-Path $temp 'model-portable-reparse-target';[void][IO.Directory]::CreateDirectory($reparseTarget);$reparseFile=Join-Path $reparseTarget 'model.json';Write-Document $reparseFile $modelReport -Compress;$reparseAlias=Join-Path $temp 'model-portable-reparse-alias';[void](New-Item -ItemType Junction -Path $reparseAlias -Target $reparseTarget -ErrorAction Stop);try{$aliasedPath=Join-Path $reparseAlias 'model.json';Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-ModelPortableGate -Expected $cleanSource -Path $aliasedPath -Digest (Get-FileDigest $aliasedPath))).Success) 'portable Artifact reader rejects a reparse path' 'portable Artifact reader accepted a reparse path'}finally{Remove-Item -LiteralPath $reparseAlias -Force}

    $hostInputs = [ordered]@{
        runner_digest='scripts\run-host-benchmark.ps1';wrapper_digest='skills\codex\scripts\invoke_codex.ps1';observation_schema_digest='schemas\host-benchmark\observation.schema.json'
        otlp_collector_digest='scripts\receive-otlp-http.ps1';atomic_write_module_digest='scripts\lib\Harness.AtomicWrite.psm1';path_module_digest='scripts\lib\Harness.Path.psm1'
        otel_contract_digest='scripts\host-benchmark\HostBenchmark.Otel.ps1';trial_helper_digest='scripts\host-benchmark\HostBenchmark.Trial.ps1'
    }
    $hostSource = [ordered]@{}
    foreach ($entry in $hostInputs.GetEnumerator()) { $hostSource[[string]$entry.Key] = Get-FileDigest (Join-Path $RepoRoot ([string]$entry.Value)) }
    $hostSource.input_head_binding=[ordered]@{start=$true;end=$true;basis='git-hash-object-equals-revision-blob/v1'}
    $hostSource.commit_tree_oid=[string]$cleanSource.commit_tree_oid; $hostSource.object_format=[string]$cleanSource.object_format
    $hostSource.start=$sourceState; $hostSource.end=(Copy-Document $sourceState)
    $hostSource.execution_mode='clean-commit-clone'
    $hostGroups = @(1,2,3 | ForEach-Object { New-HostGroup -Index $_ -Source $cleanSource -ReportSource $hostSource })
    $hostReport = [ordered]@{
        schema_version='harness-host-benchmark-report/v2';generated_at_utc=[DateTimeOffset]::UtcNow.ToString('o');source_revision=[string]$cleanSource.revision;source_dirty=$false;source_state_stable=$true;source=$hostSource
        execution=[ordered]@{model='gpt-5.6-sol';reasoning='max';groups=3;required_groups=3;trials_per_protocol_per_group=3;required_trials_per_protocol_per_group=3;group_order_strategy='independent-groups-round-interleaved-rotating-start';max_fresh_sessions=8;fresh_workspace_per_trial=$true;fresh_ephemeral_session_per_invocation=$true;codex_home='dedicated-config-isolated-auth-home-path-not-persisted';duration_ms=3000}
        groups=$hostGroups
        performance=[ordered]@{release_group_set=[ordered]@{status='pass';required_groups=3;required_trials_per_protocol_per_group=3;passed_groups=3;reason='fixture'};eligible=$true}
        status='pass';report_digest=$null
    }
    Set-ReportDigest $hostReport
    $hostPath = Join-Path $temp 'host.json'; Write-Document $hostPath $hostReport
    $hostGate = Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $hostPath -ExpectedSource $cleanSource
    Check ([string]$hostGate.status -ceq 'pass') 'three independent clean host 3x3 groups are accepted' "clean host report was rejected: $($hostGate.reason)"

    $hostDigest=Get-FileDigest $hostPath
    $cognitiveGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($hostPath,$hostPath,$hostPath) -Digests @($hostDigest,$hostDigest,$hostDigest)
    $cognitiveResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $cognitiveGates
    Check ($cognitiveResult.Success -and @($cognitiveGates.Values|Where-Object{[string]$_.status-ceq'pass'}).Count-eq3 -and @($cognitiveGates.Values|Where-Object{[string]$_.producer_identity-ceq'host-benchmark-cognitive/v2'}).Count-eq3) 'one strict Cognitive Host 3x3 Artifact derives G02/G05/G06 pass and fixed producer identity' "Cognitive Portable Adapter rejected strict shared evidence: $($cognitiveResult.Reason) / $($cognitiveResult.Detail)"

    $slowCognitive=Copy-Document $hostReport;$slowGroup=$slowCognitive.groups[0]
    foreach($trial in @($slowGroup.protocols.v2.trials)){$duration=[double](200+(10*[long]$trial.trial)+[long]$slowGroup.group_index);$trial.total_duration_ms=$duration;$trial.sum_codex_process_duration_ms=$duration}
    $slowGroup.protocols.v2.medians.total_duration_ms=[double]$slowGroup.protocols.v2.trials[1].total_duration_ms;$slowGroup.protocols.v2.medians.sum_codex_process_duration_ms=[double]$slowGroup.protocols.v2.trials[1].sum_codex_process_duration_ms
    $slowGroup.performance.direct_latency.ratio=[math]::Round(([double]$slowGroup.protocols.v2.medians.total_duration_ms/[double]$slowGroup.protocols.bare.medians.total_duration_ms),4);$slowGroup.performance.direct_latency.status='fail';$slowGroup.performance.eligible=$false;$slowGroup.status='fail';Set-GroupDigest $slowGroup
    $slowCognitive.performance.release_group_set.status='fail';$slowCognitive.performance.release_group_set.passed_groups=2L;$slowCognitive.performance.eligible=$false;$slowCognitive.status='fail';Set-ReportDigest $slowCognitive
    $slowCognitivePath=Join-Path $temp 'cognitive-direct-fail.json';Write-Document $slowCognitivePath $slowCognitive -Compress;$slowCognitiveDigest=Get-FileDigest $slowCognitivePath
    $slowCognitiveGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($slowCognitivePath,$slowCognitivePath,$slowCognitivePath) -Digests @($slowCognitiveDigest,$slowCognitiveDigest,$slowCognitiveDigest)
    $slowCognitiveResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $slowCognitiveGates
    Check ($slowCognitiveResult.Success -and [string]$slowCognitiveGates['DP-G02-COGNITIVE-HOST-3X3'].status-ceq'fail' -and [string]$slowCognitiveGates['DP-G05-V2-BARE-1.25'].status-ceq'fail' -and [string]$slowCognitiveGates['DP-G06-REQUEST-SEND-REDUCTION'].status-ceq'pass') 'G02/G05 derive a per-group ratio failure without altering G06' 'G05 did not independently derive the direct-latency result'

    $sendCognitive=Copy-Document $hostReport;$sendGroup=$sendCognitive.groups[0]
    foreach($trial in @($sendGroup.protocols.v2.trials)){$trial.successful_request_sends.value=6L;$trial.successful_request_sends.per_session_counts=@(6L)}
    $sendGroup.protocols.v2.successful_request_sends.median=6.0;$sendGroup.protocols.v2.medians.successful_request_sends=6.0;$sendGroup.performance.successful_request_send_reduction.reduction=0.4;$sendGroup.performance.successful_request_send_reduction.status='fail';$sendGroup.performance.eligible=$false;$sendGroup.status='fail';Set-GroupDigest $sendGroup
    $sendCognitive.performance.release_group_set.status='fail';$sendCognitive.performance.release_group_set.passed_groups=2L;$sendCognitive.performance.eligible=$false;$sendCognitive.status='fail';Set-ReportDigest $sendCognitive
    $sendCognitivePath=Join-Path $temp 'cognitive-send-fail.json';Write-Document $sendCognitivePath $sendCognitive -Compress;$sendCognitiveDigest=Get-FileDigest $sendCognitivePath
    $sendCognitiveGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($sendCognitivePath,$sendCognitivePath,$sendCognitivePath) -Digests @($sendCognitiveDigest,$sendCognitiveDigest,$sendCognitiveDigest)
    $sendCognitiveResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $sendCognitiveGates
    Check ($sendCognitiveResult.Success -and [string]$sendCognitiveGates['DP-G02-COGNITIVE-HOST-3X3'].status-ceq'fail' -and [string]$sendCognitiveGates['DP-G05-V2-BARE-1.25'].status-ceq'pass' -and [string]$sendCognitiveGates['DP-G06-REQUEST-SEND-REDUCTION'].status-ceq'fail') 'G02/G06 derive a per-group request-send failure without altering G05' 'G06 did not independently derive the request-send reduction result'

    $unavailableCognitive=Copy-Document $hostReport;$unavailableGroup=$unavailableCognitive.groups[0]
    foreach($trial in @($unavailableGroup.protocols.v2.trials)){$trial.successful_request_sends=[ordered]@{status='unavailable';value=$null;basis='codex-0.144.4-successful-websocket-send/v2';reason='fixture measurement unavailable'}}
    $unavailableGroup.protocols.v2.status='unavailable';$unavailableGroup.protocols.v2.successful_request_sends=[ordered]@{status='unavailable';median=$null;basis='codex-0.144.4-successful-websocket-send/v2';reason='fixture measurement unavailable'};$unavailableGroup.protocols.v2.medians.successful_request_sends=$null
    $unavailableGroup.performance.direct_latency.status='unavailable';$unavailableGroup.performance.direct_latency.ratio=$null;$unavailableGroup.performance.successful_request_send_reduction.status='unavailable';$unavailableGroup.performance.successful_request_send_reduction.reduction=$null;$unavailableGroup.performance.eligible=$false;$unavailableGroup.status='unavailable';Set-GroupDigest $unavailableGroup
    $unavailableCognitive.performance.release_group_set.status='unavailable';$unavailableCognitive.performance.release_group_set.passed_groups=2L;$unavailableCognitive.performance.eligible=$false;$unavailableCognitive.status='unavailable';Set-ReportDigest $unavailableCognitive
    $unavailableCognitivePath=Join-Path $temp 'cognitive-send-unavailable.json';Write-Document $unavailableCognitivePath $unavailableCognitive -Compress;$unavailableCognitiveDigest=Get-FileDigest $unavailableCognitivePath
    $unavailableCognitiveGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($unavailableCognitivePath,$unavailableCognitivePath,$unavailableCognitivePath) -Digests @($unavailableCognitiveDigest,$unavailableCognitiveDigest,$unavailableCognitiveDigest)
    $unavailableCognitiveResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $unavailableCognitiveGates
    Check ($unavailableCognitiveResult.Success -and [string]$unavailableCognitiveGates['DP-G02-COGNITIVE-HOST-3X3'].status-ceq'unavailable' -and [string]$unavailableCognitiveGates['DP-G05-V2-BARE-1.25'].status-ceq'unavailable' -and [string]$unavailableCognitiveGates['DP-G06-REQUEST-SEND-REDUCTION'].status-ceq'unavailable') 'legal unavailable successful-send telemetry remains unavailable and does not become a Gate pass' 'Cognitive Adapter promoted or rejected legal request-send unavailability'

    $script:cognitivePortableMutationIndex=0
    $rejectCognitivePortableMutation={param([string]$Name,[scriptblock]$Mutation)
        $script:cognitivePortableMutationIndex++;$document=Copy-Document $hostReport;& $Mutation $document;foreach($group in @($document.groups)){Set-GroupDigest $group};Set-ReportDigest $document
        $mutationPath=Join-Path $temp ("cognitive-portable-mutation-$($script:cognitivePortableMutationIndex).json");Write-Document $mutationPath $document -Compress;$digest=Get-FileDigest $mutationPath
        $result=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-CognitivePortableGateSet -Expected $cleanSource -Paths @($mutationPath,$mutationPath,$mutationPath) -Digests @($digest,$digest,$digest))
        Check (-not $result.Success) "Cognitive Adapter rejects $Name" "Cognitive Adapter accepted $Name"
    }
    & $rejectCognitivePortableMutation 'a wrong schema' {param($d)$d.schema_version='harness-host-benchmark-report/v3'}
    & $rejectCognitivePortableMutation 'a historical v1 report' {param($d)$d.schema_version='harness-host-benchmark-report/v1'}
    & $rejectCognitivePortableMutation 'fewer than three Groups' {param($d)$d.groups=@($d.groups|Select-Object -First 2);$d.execution.groups=2L}
    & $rejectCognitivePortableMutation 'fewer than three Trials' {param($d)$d.groups[0].protocols.v2.trials=@($d.groups[0].protocols.v2.trials|Select-Object -First 2)}
    & $rejectCognitivePortableMutation 'a reused group_run_id' {param($d)$d.groups[1].group_run_id=$d.groups[0].group_run_id}
    & $rejectCognitivePortableMutation 'a reused group_root_digest' {param($d)$d.groups[1].group_root_digest=$d.groups[0].group_root_digest}
    & $rejectCognitivePortableMutation 'a reused trial_run_id' {param($d)$d.groups[1].protocols.v2.trials[0].trial_run_id=$d.groups[0].protocols.v2.trials[0].trial_run_id}
    & $rejectCognitivePortableMutation 'a reused trial_root_digest' {param($d)$d.groups[1].protocols.v2.trials[0].trial_root_digest=$d.groups[0].protocols.v2.trials[0].trial_root_digest}
    & $rejectCognitivePortableMutation 'a reused normalized Trial payload' {param($d)$id=$d.groups[1].protocols.v2.trials[0].trial_run_id;$root=$d.groups[1].protocols.v2.trials[0].trial_root_digest;$d.groups[1].protocols.v2.trials[0]=Copy-Document $d.groups[0].protocols.v2.trials[0];$d.groups[1].protocols.v2.trials[0].trial_run_id=$id;$d.groups[1].protocols.v2.trials[0].trial_root_digest=$root}
    & $rejectCognitivePortableMutation 'the wrong model' {param($d)$d.groups[0].execution.model='gpt-5.6-terra'}
    & $rejectCognitivePortableMutation 'the wrong reasoning effort' {param($d)$d.groups[0].execution.reasoning='high'}
    & $rejectCognitivePortableMutation 'the wrong service version' {param($d)$d.groups[0].execution.expected_codex_service_version='0.144.3'}
    & $rejectCognitivePortableMutation 'string-forged Group source and Trial fields' {param($d)$d.groups[0].source_state_stable='true';$d.groups[0].execution.trials_per_protocol='3';$d.groups[0].protocols.v2.trials[0].trial='1'}
    & $rejectCognitivePortableMutation 'a dirty source' {param($d)$d.groups[0].source_dirty=$true}
    & $rejectCognitivePortableMutation 'an unstable source' {param($d)$d.groups[0].source_state_stable=$false}
    & $rejectCognitivePortableMutation 'a pooled median substitute' {param($d)$d.groups[0].protocols.v2.medians.total_duration_ms=999.0;$d.groups[0].performance.direct_latency.ratio=1.0}
    & $rejectCognitivePortableMutation 'forged top-level eligibility' {param($d)$d.groups[0].status='unavailable';$d.groups[0].performance.eligible=$false;$d.performance.eligible=$true}
    & $rejectCognitivePortableMutation 'a non-finite direct ratio' {param($d)$d.groups[0].performance.direct_latency.ratio='NaN'}
    & $rejectCognitivePortableMutation 'a non-finite request reduction' {param($d)$d.groups[0].performance.successful_request_send_reduction.reduction='Infinity'}
    & $rejectCognitivePortableMutation 'direct-ratio threshold drift' {param($d)$d.groups[0].performance.direct_latency.threshold=1.26}
    & $rejectCognitivePortableMutation 'request-reduction threshold drift' {param($d)$d.groups[0].performance.successful_request_send_reduction.threshold=0.59}
    & $rejectCognitivePortableMutation 'unavailable send evidence marked pass' {param($d)$d.groups[0].protocols.v2.trials[0].successful_request_sends=[ordered]@{status='unavailable';value=$null;basis='codex-0.144.4-successful-websocket-send/v2';reason='fixture unavailable'}}
    & $rejectCognitivePortableMutation 'estimated sends' {param($d)$d.groups[0].protocols.v2.trials[0].successful_request_sends.status='estimated'}
    & $rejectCognitivePortableMutation 'non-successful send counts' {param($d)$d.groups[0].protocols.v2.trials[0].successful_request_sends.basis='attempted-websocket-send/v1'}

    foreach($name in @('DP-G02-COGNITIVE-HOST-3X3','DP-G05-V2-BARE-1.25','DP-G06-REQUEST-SEND-REDUCTION')){$partial=[ordered]@{};$partial[$name]=(New-CognitivePortableGateSet -Expected $cleanSource -Paths @($hostPath,$hostPath,$hostPath) -Digests @($hostDigest,$hostDigest,$hostDigest))[$name];$partialResult=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $partial;Check (-not $partialResult.Success -and [string]$partialResult.Reason-ceq'rollout-evidence-cognitive-gate-set-incomplete') "Cognitive Gate Set rejects only $name" "Cognitive Gate Set accepted only $name"}
    $differentPathGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($hostPath,$slowCognitivePath,$sendCognitivePath) -Digests @($hostDigest,$slowCognitiveDigest,$sendCognitiveDigest);Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $differentPathGates).Success) 'Cognitive Gate Set rejects different Artifact paths' 'Cognitive Gate Set accepted different Artifact paths'
    $copyPaths=@(1,2,3|ForEach-Object{$copyPath=Join-Path $temp "cognitive-byte-copy-$_.json";[IO.File]::WriteAllBytes($copyPath,[IO.File]::ReadAllBytes($hostPath));$copyPath});$copyGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths $copyPaths -Digests @($hostDigest,$hostDigest,$hostDigest);Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $copyGates).Success) 'Cognitive Gate Set rejects byte-identical copied Artifacts with different physical identities' 'Cognitive Gate Set accepted byte-identical copied Artifacts'
    $differentDigestGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($hostPath,$hostPath,$hostPath) -Digests @($hostDigest,$hostDigest,('sha256:'+('0'*64)));Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $differentDigestGates).Success) 'Cognitive Gate Set rejects different raw digests' 'Cognitive Gate Set accepted different raw digests'
    $differentRevisionGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($hostPath,$hostPath,$hostPath) -Digests @($hostDigest,$hostDigest,$hostDigest);$differentRevisionGates['DP-G05-V2-BARE-1.25'].source_revision='0'*40;Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $differentRevisionGates).Success) 'Cognitive Gate Set rejects different source revisions' 'Cognitive Gate Set accepted different source revisions'
    $differentContractGates=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($hostPath,$hostPath,$hostPath) -Digests @($hostDigest,$hostDigest,$hostDigest);$differentContractGates['DP-G06-REQUEST-SEND-REDUCTION'].evidence_contract='harness-host-benchmark-report/v1';Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $differentContractGates).Success) 'Cognitive Gate Set rejects a different Evidence Contract' 'Cognitive Gate Set accepted a different Evidence Contract'
    $hostAsModel=New-ModelPortableGate -Expected $cleanSource -Path $hostPath -Digest $hostDigest;Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $hostAsModel).Success) 'Cognitive Host Artifact cannot impersonate G01' 'Cognitive Host Artifact impersonated G01'
    $modelAsHost=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($modelPath,$modelPath,$modelPath) -Digests @((Get-FileDigest $modelPath),(Get-FileDigest $modelPath),(Get-FileDigest $modelPath));Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $modelAsHost).Success) 'Model Artifact cannot impersonate G02/G05/G06' 'Model Artifact impersonated Cognitive Host evidence'

    $installedFormalA=New-InstalledHostReport -HostReport $hostReport -Seed formal-a
    $installedFormalB=New-InstalledHostReport -HostReport $hostReport -Seed formal-b
    $installedFormalResult=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $installedFormalA -Right $installedFormalB
    Check ($installedFormalResult.Success -and [string]$installedFormalResult.Gates['DP-G03-INSTALLED-DESKTOP-HOST-3X3'].status -ceq 'pass' -and [string]$installedFormalResult.Gates['DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE'].producer_identity -ceq 'host-benchmark-installed-desktop/v1') 'two distinct formal-shaped installed contracts are adapted from Artifact status and identity' "valid installed contracts were rejected: $($installedFormalResult.Reason) / $($installedFormalResult.Detail)"
    Check ([string]$installedFormalA.qualification.hook_trust -ceq 'manual' -and -not [bool]$installedFormalA.qualification.hook_observations_blocking -and $installedFormalResult.Success) 'manual Hook observations remain advisory and nonblocking' 'manual Hook observations were forged as machine facts or incorrectly made blocking'
    $installedAsCognitivePath=Join-Path $temp ("installed-$($installedFormalA.report_run_id).json");$installedAsCognitiveDigest=Get-FileDigest $installedAsCognitivePath
    $installedAsCognitive=New-CognitivePortableGateSet -Expected $cleanSource -Paths @($installedAsCognitivePath,$installedAsCognitivePath,$installedAsCognitivePath) -Digests @($installedAsCognitiveDigest,$installedAsCognitiveDigest,$installedAsCognitiveDigest)
    Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $installedAsCognitive).Success) 'Installed Desktop Report cannot impersonate Cognitive Host evidence' 'Installed Desktop Report impersonated G02/G05/G06'

    $installedTestA=New-InstalledHostReport -HostReport $hostReport -Seed test-a -ProducerMode test-only
    $installedTestB=New-InstalledHostReport -HostReport $hostReport -Seed test-b -ProducerMode test-only
    $installedTestResult=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $installedTestA -Right $installedTestB
    Check ($installedTestResult.Success -and @($installedTestResult.Gates.Values | Where-Object { [string]$_.status -ceq 'unavailable' }).Count -eq 2 -and @($installedTestResult.Gates.Values | Where-Object { [string]$_.producer_identity -ceq 'host-benchmark-installed-desktop/v1' }).Count -eq 2) 'caller pass/producer claims are overwritten by test-only Artifact facts' 'test-only evidence became pass or retained caller producer identity'
    $installedSmokeA=New-InstalledHostReport -HostReport $hostReport -Seed smoke-a -ProducerMode diagnostic-smoke
    $installedSmokeB=New-InstalledHostReport -HostReport $hostReport -Seed smoke-b -ProducerMode diagnostic-smoke
    $installedSmokeResult=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $installedSmokeA -Right $installedSmokeB
    Check ($installedSmokeResult.Success -and @($installedSmokeResult.Gates.Values | Where-Object { [string]$_.status -ceq 'unavailable' }).Count -eq 2) 'diagnostic smoke remains unavailable' 'diagnostic smoke became formal evidence'

    $lifecycleFormal=@(
        (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed 'Contract Fixture formal core'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset governed -Seed 'Contract Fixture formal governed'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed 'Contract Fixture formal full')
    )
    $lifecycleFormalResult=Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $lifecycleFormal
    Check ($lifecycleFormalResult.Success -and @($lifecycleFormalResult.Gates.Values|Where-Object{[string]$_.status-ceq'pass'}).Count-eq3 -and @($lifecycleFormalResult.Gates.Values|Where-Object{[string]$_.producer_identity-ceq'preset-lifecycle-qualification/v1'}).Count-eq3) 'G18/G19/G20 adapt three distinct formal-shaped Contract Fixtures and override caller claims' "valid lifecycle Contract Fixtures were rejected: $($lifecycleFormalResult.Reason) / $($lifecycleFormalResult.Detail)"

    foreach($mode in @('test-only','diagnostic-smoke')){
        $reports=@(
            (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed "Contract Fixture $mode core" -ProducerMode $mode),
            (New-PresetLifecycleReport -Source $cleanSource -Preset governed -Seed "Contract Fixture $mode governed" -ProducerMode $mode),
            (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed "Contract Fixture $mode full" -ProducerMode $mode)
        )
        $result=Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $reports
        Check ($result.Success -and @($result.Gates.Values|Where-Object{[string]$_.status-ceq'unavailable'}).Count-eq3) "$mode Contract Fixtures remain unavailable despite caller status=pass" "$mode lifecycle evidence became formal pass"
    }

    $failureStages=@('install','verify-after-install','update','verify-after-update','uninstall','cleanup')
    for($stageIndex=0;$stageIndex-lt$failureStages.Count;$stageIndex++){
        $reports=@(
            (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed "Contract Fixture failure $stageIndex core"),
            (New-PresetLifecycleReport -Source $cleanSource -Preset governed -Seed "Contract Fixture failure $stageIndex governed"),
            (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed "Contract Fixture failure $stageIndex full")
        )
        Set-PresetLifecycleFailure -Report $reports[0] -StageIndex $stageIndex
        $result=Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $reports
        Check ($result.Success -and [string]$result.Gates['DP-G18-CORE-LIFECYCLE'].status-ceq'fail') "lifecycle $($failureStages[$stageIndex]) failure is retained as Gate fail" "lifecycle $($failureStages[$stageIndex]) failure was rejected or promoted"
    }

    foreach($resultName in @('auth_unchanged','unrelated_user_config_unchanged','preset_consistent')){
        $reports=@(
            (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed "Contract Fixture result $resultName core"),
            (New-PresetLifecycleReport -Source $cleanSource -Preset governed -Seed "Contract Fixture result $resultName governed"),
            (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed "Contract Fixture result $resultName full")
        )
        $reports[0].results[$resultName]=$false;$reports[0].status='fail';$reports[0].reason='lifecycle-stage-or-result-failure';Set-ReportDigest $reports[0]
        $result=Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $reports
        Check ($result.Success -and [string]$result.Gates['DP-G18-CORE-LIFECYCLE'].status-ceq'fail') "lifecycle $resultName=false derives Gate fail" "lifecycle $resultName=false was rejected or promoted"
    }

    $script:lifecycleMutationIndex=0
    $rejectLifecycleMutation={
        param([string]$Name,[scriptblock]$Mutation)
        $script:lifecycleMutationIndex++
        $reports=@(
            (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed "Contract Fixture mutation $($script:lifecycleMutationIndex) core"),
            (New-PresetLifecycleReport -Source $cleanSource -Preset governed -Seed "Contract Fixture mutation $($script:lifecycleMutationIndex) governed"),
            (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed "Contract Fixture mutation $($script:lifecycleMutationIndex) full")
        )
        & $Mutation $reports[0]
        Set-ReportDigest $reports[0]
        $result=Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $reports
        Check (-not $result.Success) "lifecycle Adapter rejects $Name" "lifecycle Adapter accepted $Name"
    }
    & $rejectLifecycleMutation 'an unknown field' {param($r)$r['unexpected']='sentinel'}
    & $rejectLifecycleMutation 'the wrong schema' {param($r)$r.schema_version='harness-preset-lifecycle-report/v2'}
    & $rejectLifecycleMutation 'a stale source revision' {param($r)$r.source_revision='0'*40;$r.source.start.revision='0'*40;$r.source.end.revision='0'*40}
    & $rejectLifecycleMutation 'the wrong tree OID' {param($r)$r.source.commit_tree_oid='0'*40;$r.source.start.commit_tree_oid='0'*40;$r.source.end.commit_tree_oid='0'*40}
    & $rejectLifecycleMutation 'a dirty source' {param($r)$r.source_dirty=$true;$r.source.start.dirty=$true;$r.source.end.dirty=$true}
    & $rejectLifecycleMutation 'an unstable source' {param($r)$r.source_state_stable=$false}
    & $rejectLifecycleMutation 'the wrong producer identity' {param($r)$r.producer_identity='preset-lifecycle-fixture/v1'}
    & $rejectLifecycleMutation 'the wrong producer mode' {param($r)$r.producer_mode='fixture'}
    & $rejectLifecycleMutation 'the wrong preset' {param($r)$r.preset='full';$r.execution.effective_preset='full'}
    & $rejectLifecycleMutation 'a missing Stage' {param($r)$r.stages=@($r.stages|Select-Object -First 5)}
    & $rejectLifecycleMutation 'reordered Stages' {param($r)$swap=$r.stages[0];$r.stages[0]=$r.stages[1];$r.stages[1]=$swap}
    & $rejectLifecycleMutation 'a duplicate Stage' {param($r)$r.stages[1]=(Copy-Document $r.stages[0])}
    & $rejectLifecycleMutation 'pass with a nonzero Exit Code' {param($r)$r.stages[0].exit_code=9L}
    & $rejectLifecycleMutation 'fail with a zero Exit Code' {param($r)$r.stages[0].status='fail';$r.stages[0].exit_code=0L;$r.status='fail';$r.reason='lifecycle-stage-or-result-failure';$r.results.all_required_stages_passed=$false;$r.results.preset_consistent=$false}
    & $rejectLifecycleMutation 'not_run presented as pass' {param($r)$r.stages[1].status='not_run';$r.stages[1].exit_code=$null}
    & $rejectLifecycleMutation 'a stale Producer input digest' {param($r)$r.source.input_digests.producer_digest='sha256:'+('0'*64)}
    & $rejectLifecycleMutation 'credential content' {param($r)$r.reason='authorization: bearer Contract Fixture secret'}
    & $rejectLifecycleMutation 'a private absolute path' {param($r)$r.reason='C:\Users\private\Contract Fixture.json'}
    & $rejectLifecycleMutation 'raw log content' {param($r)$r.reason='raw log: Contract Fixture output'}

    $sameId=@(
        (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed 'Contract Fixture same id core'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset governed -Seed 'Contract Fixture same id governed'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed 'Contract Fixture same id full')
    );$sameId[1].report_run_id=$sameId[0].report_run_id;Set-ReportDigest $sameId[1]
    Check (-not (Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $sameId).Success) 'lifecycle Gate Set rejects duplicate report_run_id' 'lifecycle Gate Set accepted duplicate report_run_id'
    $sameWorkspace=@(
        (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed 'Contract Fixture same workspace core'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset governed -Seed 'Contract Fixture same workspace governed'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed 'Contract Fixture same workspace full')
    );$sameWorkspace[1].execution.workspace_identity_digest=$sameWorkspace[0].execution.workspace_identity_digest;Set-ReportDigest $sameWorkspace[1]
    Check (-not (Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $sameWorkspace).Success) 'lifecycle Gate Set rejects duplicate Workspace identity' 'lifecycle Gate Set accepted duplicate Workspace identity'
    $sameProfile=@(
        (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed 'Contract Fixture same profile core'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset governed -Seed 'Contract Fixture same profile governed'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed 'Contract Fixture same profile full')
    );$sameProfile[1].execution.profile_identity_digest=$sameProfile[0].execution.profile_identity_digest;Set-ReportDigest $sameProfile[1]
    Check (-not (Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $sameProfile).Success) 'lifecycle Gate Set rejects duplicate Profile identity' 'lifecycle Gate Set accepted duplicate Profile identity'
    $fullAsGoverned=@(
        (New-PresetLifecycleReport -Source $cleanSource -Preset core -Seed 'Contract Fixture full substitute core'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed 'Contract Fixture full substitute governed'),
        (New-PresetLifecycleReport -Source $cleanSource -Preset full -Seed 'Contract Fixture full substitute full')
    )
    Check (-not (Invoke-PresetLifecycleReportSet -Module $module -Expected $cleanSource -Root $temp -Reports $fullAsGoverned).Success) 'Full Contract Fixture cannot substitute for Governed' 'Full Contract Fixture substituted for Governed'

    $lifecycleGoodPaths=[Collections.Generic.List[string]]::new();$lifecycleGoodDigests=[Collections.Generic.List[string]]::new()
    for($index=0;$index-lt3;$index++){$path=Join-Path $temp "lifecycle-good-$index.json";Write-Document $path $lifecycleFormal[$index] -Compress;$lifecycleGoodPaths.Add($path);$lifecycleGoodDigests.Add((Get-FileDigest $path))}
    $missingLifecycle=Join-Path $temp 'missing-lifecycle.json'
    $pathResult=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @($missingLifecycle,$lifecycleGoodPaths[1],$lifecycleGoodPaths[2]) -Digests @(('sha256:'+('0'*64)),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2])
    Check (-not $pathResult.Success) 'lifecycle Adapter rejects a missing Artifact' 'lifecycle Adapter accepted a missing Artifact'
    $pathResult=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @('relative-lifecycle.json',$lifecycleGoodPaths[1],$lifecycleGoodPaths[2]) -Digests @(('sha256:'+('0'*64)),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2])
    Check (-not $pathResult.Success) 'lifecycle Adapter rejects a relative Artifact path' 'lifecycle Adapter accepted a relative Artifact path'

    $script:lifecycleBadPathIndex=0
    $rejectLifecycleBytes={
        param([string]$Name,[byte[]]$Bytes)
        $script:lifecycleBadPathIndex++
        $path=Join-Path $temp "lifecycle-bad-bytes-$($script:lifecycleBadPathIndex).json";[IO.File]::WriteAllBytes($path,$Bytes)
        $result=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @($path,$lifecycleGoodPaths[1],$lifecycleGoodPaths[2]) -Digests @((Get-FileDigest $path),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2])
        Check (-not $result.Success) "lifecycle Adapter rejects $Name" "lifecycle Adapter accepted $Name"
    }
    & $rejectLifecycleBytes 'malformed JSON' ([Text.UTF8Encoding]::new($false).GetBytes('{'))
    & $rejectLifecycleBytes 'a UTF-8 BOM' ([Text.UTF8Encoding]::new($true).GetBytes('{}'))
    & $rejectLifecycleBytes 'duplicate JSON keys' ([Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":"one","schema_version":"two"}'))
    & $rejectLifecycleBytes 'an oversized Artifact' ([byte[]]::new((1MB)+1))
    $pathResult=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @($lifecycleGoodPaths) -Digests @(('sha256:'+('0'*64)),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2])
    Check (-not $pathResult.Success) 'lifecycle Adapter rejects a raw digest mismatch' 'lifecycle Adapter accepted a raw digest mismatch'
    $digestMismatch=Copy-Document $lifecycleFormal[0];$digestMismatch.report_digest='sha256:'+('0'*64);$digestMismatchPath=Join-Path $temp 'lifecycle-report-digest-mismatch.json';Write-Document $digestMismatchPath $digestMismatch -Compress
    $pathResult=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @($digestMismatchPath,$lifecycleGoodPaths[1],$lifecycleGoodPaths[2]) -Digests @((Get-FileDigest $digestMismatchPath),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2])
    Check (-not $pathResult.Success) 'lifecycle Adapter rejects report_digest mismatch' 'lifecycle Adapter accepted report_digest mismatch'

    $sharedPaths=@($lifecycleGoodPaths[0],$lifecycleGoodPaths[0],$lifecycleGoodPaths[0]);$sharedDigests=@($lifecycleGoodDigests[0],$lifecycleGoodDigests[0],$lifecycleGoodDigests[0])
    Check (-not (Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths $sharedPaths -Digests $sharedDigests).Success) 'lifecycle Gate Set rejects one Artifact reused by multiple Gates' 'lifecycle Gate Set accepted one reused Artifact'
    $twoGateSet=[ordered]@{}
    foreach($name in @('DP-G18-CORE-LIFECYCLE','DP-G19-GOVERNED-LIFECYCLE')){$index=if($name-like'*G18*'){0}else{1};$twoGateSet[$name]=[ordered]@{status='pass';evidence_contract='harness-preset-lifecycle-report/v1';artifact_path=$lifecycleGoodPaths[$index];evidence_digest=$lifecycleGoodDigests[$index];source_revision=[string]$cleanSource.revision;producer_identity='forged-caller'}}
    $incompleteReason='';try{& $module {param($Root,$Source,$Gates)Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $Gates} $RepoRoot $cleanSource $twoGateSet}catch{$incompleteReason=[string]$_.Exception.Message}
    Check ($incompleteReason-ceq'rollout-evidence-lifecycle-gate-set-incomplete') 'a partial lifecycle Gate Set fails closed' 'a partial lifecycle Gate Set was accepted'

    $reparseTarget=Join-Path $temp 'lifecycle-reparse-target';[void][IO.Directory]::CreateDirectory($reparseTarget);$reparseSource=Join-Path $reparseTarget 'core.json';Write-Document $reparseSource $lifecycleFormal[0] -Compress
    $reparseAlias=Join-Path $temp 'lifecycle-reparse-alias';[void](New-Item -ItemType Junction -Path $reparseAlias -Target $reparseTarget -ErrorAction Stop)
    try{$pathResult=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @((Join-Path $reparseAlias 'core.json'),$lifecycleGoodPaths[1],$lifecycleGoodPaths[2]) -Digests @((Get-FileDigest $reparseSource),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2]);Check (-not $pathResult.Success) 'lifecycle Adapter rejects a reparse path' 'lifecycle Adapter accepted a reparse path'}finally{Remove-Item -LiteralPath $reparseAlias -Force}
    $hardlinkSource=Join-Path $temp 'lifecycle-hardlink-source.json';$hardlinkAlias=Join-Path $temp 'lifecycle-hardlink-alias.json';Write-Document $hardlinkSource $lifecycleFormal[0] -Compress
    $hardlinkOutput=@(& fsutil hardlink create $hardlinkAlias $hardlinkSource 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "lifecycle hardlink fixture setup failed: $($hardlinkOutput-join' | ')"}
    $pathResult=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @($hardlinkAlias,$lifecycleGoodPaths[1],$lifecycleGoodPaths[2]) -Digests @((Get-FileDigest $hardlinkAlias),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2]);Check (-not $pathResult.Success) 'lifecycle Adapter rejects a multiply-linked Artifact' 'lifecycle Adapter accepted a multiply-linked Artifact'
    $adsPath=Join-Path $temp 'lifecycle-ads.json';Write-Document $adsPath $lifecycleFormal[0] -Compress;Set-Content -LiteralPath $adsPath -Stream 'hidden-evidence' -Value 'sentinel' -Encoding utf8NoBOM
    $pathResult=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @($adsPath,$lifecycleGoodPaths[1],$lifecycleGoodPaths[2]) -Digests @((Get-FileDigest $adsPath),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2]);Check (-not $pathResult.Success) 'lifecycle Adapter rejects alternate data streams' 'lifecycle Adapter accepted alternate data streams'
    $protectedLifecycleRoot=Join-Path $temp 'lifecycle-protected';[void][IO.Directory]::CreateDirectory($protectedLifecycleRoot);$protectedLifecyclePath=Join-Path $protectedLifecycleRoot 'core.json';Write-Document $protectedLifecyclePath $lifecycleFormal[0] -Compress
    $pathResult=Invoke-PresetLifecycleGatePaths -Module $module -Expected $cleanSource -Paths @($protectedLifecyclePath,$lifecycleGoodPaths[1],$lifecycleGoodPaths[2]) -Digests @((Get-FileDigest $protectedLifecyclePath),$lifecycleGoodDigests[1],$lifecycleGoodDigests[2]) -ProtectedRoots @($protectedLifecycleRoot);Check (-not $pathResult.Success) 'lifecycle Adapter rejects Protected Root overlap' 'lifecycle Adapter accepted Protected Root overlap'

    $g14Formal=New-V1StopLossReport -Source $cleanSource -Seed 'Contract Fixture formal pass'
    $g14FormalResult=Invoke-V1StopLossReport -Module $module -Expected $cleanSource -Root $temp -Report $g14Formal -Name 'formal-pass'
    Check ($g14FormalResult.Success -and [string]$g14FormalResult.Gates['DP-G14-V1-STOP-LOSS'].status-ceq'pass' -and [string]$g14FormalResult.Gates['DP-G14-V1-STOP-LOSS'].producer_identity-ceq'v1-stop-loss-qualification/v1') 'G14 formal-shaped Contract Fixture derives pass and overrides caller status/identity' "valid G14 Contract Fixture was rejected: $($g14FormalResult.Reason) / $($g14FormalResult.Detail)"

    $g14Fail=New-V1StopLossReport -Source $cleanSource -Seed 'Contract Fixture formal fail';$g14Fail.route_probes[0].status='fail';$g14Fail.route_probes[0].exit_code=86L;$g14Fail.results.environment_v1_selects_v1=$false;$g14Fail.status='fail';$g14Fail.reason='route-or-lifecycle-result-failure';Set-ReportDigest $g14Fail
    $g14FailResult=Invoke-V1StopLossReport -Module $module -Expected $cleanSource -Root $temp -Report $g14Fail -Name 'formal-fail'
    Check ($g14FailResult.Success -and [string]$g14FailResult.Gates['DP-G14-V1-STOP-LOSS'].status-ceq'fail' -and [string]$g14FailResult.Gates['DP-G14-V1-STOP-LOSS'].producer_identity-ceq'v1-stop-loss-qualification/v1') 'G14 formal failure overrides a forged caller pass' 'G14 formal failure was rejected or promoted'

    $g14Unavailable=New-V1StopLossReport -Source $cleanSource -Seed 'Contract Fixture formal unavailable';Set-V1StopLossUnavailable $g14Unavailable
    $g14UnavailableResult=Invoke-V1StopLossReport -Module $module -Expected $cleanSource -Root $temp -Report $g14Unavailable -Name 'formal-unavailable'
    Check ($g14UnavailableResult.Success -and [string]$g14UnavailableResult.Gates['DP-G14-V1-STOP-LOSS'].status-ceq'unavailable' -and [string]$g14UnavailableResult.Gates['DP-G14-V1-STOP-LOSS'].producer_identity-ceq'v1-stop-loss-qualification/v1') 'G14 formal unavailability overrides a forged caller pass' 'G14 formal unavailable evidence was rejected or promoted'

    foreach($mode in @('test-only','diagnostic-smoke')){
        $report=New-V1StopLossReport -Source $cleanSource -Seed "Contract Fixture $mode" -ProducerMode $mode
        $result=Invoke-V1StopLossReport -Module $module -Expected $cleanSource -Root $temp -Report $report -Name $mode
        Check ($result.Success -and [string]$result.Gates['DP-G14-V1-STOP-LOSS'].status-ceq'unavailable') "G14 $mode Contract Fixture remains unavailable despite caller status=pass" "G14 $mode evidence became formal pass"
    }

    $script:g14MutationIndex=0
    $rejectG14Mutation={
        param([string]$Name,[scriptblock]$Mutation)
        $script:g14MutationIndex++
        $report=New-V1StopLossReport -Source $cleanSource -Seed "Contract Fixture mutation $($script:g14MutationIndex)"
        & $Mutation $report
        Set-ReportDigest $report
        $result=Invoke-V1StopLossReport -Module $module -Expected $cleanSource -Root $temp -Report $report -Name "mutation-$($script:g14MutationIndex)"
        Check (-not $result.Success) "G14 Adapter rejects $Name" "G14 Adapter accepted $Name"
    }
    & $rejectG14Mutation 'an unknown field' {param($r)$r['unexpected']='sentinel'}
    & $rejectG14Mutation 'the wrong schema' {param($r)$r.schema_version='harness-v1-stop-loss-report/v2'}
    & $rejectG14Mutation 'a stale source revision' {param($r)$r.source_revision='0'*40;$r.source.start.revision='0'*40;$r.source.end.revision='0'*40}
    & $rejectG14Mutation 'the wrong tree OID' {param($r)$r.source.commit_tree_oid='0'*40;$r.source.start.commit_tree_oid='0'*40;$r.source.end.commit_tree_oid='0'*40}
    & $rejectG14Mutation 'a dirty source' {param($r)$r.source_dirty=$true;$r.source.start.dirty=$true;$r.source.end.dirty=$true}
    & $rejectG14Mutation 'an unstable source' {param($r)$r.source_state_stable=$false}
    & $rejectG14Mutation 'the wrong producer identity' {param($r)$r.producer_identity='v1-stop-loss-fixture/v1'}
    & $rejectG14Mutation 'an unknown producer mode' {param($r)$r.producer_mode='fixture'}
    & $rejectG14Mutation 'a stale Producer input digest' {param($r)$r.source.input_digests.producer_digest='sha256:'+('0'*64)}
    & $rejectG14Mutation 'a missing Route Probe' {param($r)$r.route_probes=@($r.route_probes|Select-Object -First 3)}
    & $rejectG14Mutation 'reordered Route Probes' {param($r)$swap=$r.route_probes[0];$r.route_probes[0]=$r.route_probes[1];$r.route_probes[1]=$swap}
    & $rejectG14Mutation 'a duplicate Route Probe' {param($r)$r.route_probes[1]=Copy-Document $r.route_probes[0]}
    & $rejectG14Mutation 'environment v1 selecting v2' {param($r)$r.route_probes[0].selected_protocol='v2'}
    & $rejectG14Mutation 'disable-v2 selecting v2' {param($r)$r.route_probes[1].selected_protocol='v2'}
    & $rejectG14Mutation 'disable-v2 producing an extra write' {param($r)$r.route_probes[1].unexpected_writes=1L}
    & $rejectG14Mutation 'Existing v1 being overridden by explicit v2' {param($r)$r.route_probes[2].selected_protocol='v2'}
    & $rejectG14Mutation 'Existing v2 being downgraded by explicit v1' {param($r)$r.route_probes[3].selected_protocol='v1'}
    & $rejectG14Mutation 'an Existing Artifact byte change' {param($r)$r.route_probes[2].artifact_digest_after='sha256:'+('0'*64)}
    & $rejectG14Mutation 'a Runtime Default write' {param($r)$r.results.runtime_default_untouched=$false}
    & $rejectG14Mutation 'a lifecycle missing a stage' {param($r)$r.lifecycle.stage_sequence=@($r.lifecycle.stage_sequence|Where-Object{$_-cne'CODE_REVIEW'})}
    & $rejectG14Mutation 'a reordered lifecycle' {param($r)$swap=$r.lifecycle.stage_sequence[1];$r.lifecycle.stage_sequence[1]=$r.lifecycle.stage_sequence[2];$r.lifecycle.stage_sequence[2]=$swap}
    & $rejectG14Mutation 'a lifecycle final_stage other than DONE' {param($r)$r.lifecycle.final_stage='TEST'}
    & $rejectG14Mutation 'a wrong lifecycle transition_count' {param($r)$r.lifecycle.transition_count=4L}
    & $rejectG14Mutation 'v1 migration to v2' {param($r)$r.route_probes[2].detected_protocol='v2';$r.route_probes[2].selected_protocol='v2'}
    & $rejectG14Mutation 'v2 downgrade to v1' {param($r)$r.route_probes[3].detected_protocol='v1';$r.route_probes[3].selected_protocol='v1'}
    & $rejectG14Mutation 'Auth changed' {param($r)$r.results.auth_unchanged=$false}
    & $rejectG14Mutation 'unrelated config changed' {param($r)$r.results.unrelated_user_config_unchanged=$false}
    & $rejectG14Mutation 'cleanup residue' {param($r)$r.results.cleanup_no_residue=$false}
    & $rejectG14Mutation 'test-only presented with a formal pass result' {param($r)$r.producer_mode='test-only'}
    & $rejectG14Mutation 'diagnostic-smoke presented with a formal pass result' {param($r)$r.producer_mode='diagnostic-smoke'}
    & $rejectG14Mutation 'credential content' {param($r)$r.reason='authorization: bearer Contract Fixture secret'}
    & $rejectG14Mutation 'a private absolute path' {param($r)$r.reason='C:\Users\private\Contract Fixture.json'}
    & $rejectG14Mutation 'raw output content' {param($r)$r.reason='raw output: Contract Fixture stdout'}
    & $rejectG14Mutation 'Plan body content' {param($r)$r.reason='# Contract Fixture Plan body'}
    & $rejectG14Mutation 'Test body content' {param($r)$r.reason='# Contract Fixture Test Report body'}

    $g14GoodPath=Join-Path $temp 'v1-stop-loss-good.json';Write-Document $g14GoodPath $g14Formal -Compress;$g14GoodDigest=Get-FileDigest $g14GoodPath
    $missingG14=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path (Join-Path $temp 'missing-v1-stop-loss.json') -Digest ('sha256:'+('0'*64)))
    Check (-not $missingG14.Success) 'G14 Adapter rejects a missing Artifact' 'G14 Adapter accepted a missing Artifact'
    $relativeG14=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path 'relative-v1-stop-loss.json' -Digest $g14GoodDigest)
    Check (-not $relativeG14.Success) 'G14 Adapter rejects a relative Artifact path' 'G14 Adapter accepted a relative Artifact path'
    $rawMismatchG14=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path $g14GoodPath -Digest ('sha256:'+('0'*64)))
    Check (-not $rawMismatchG14.Success) 'G14 Adapter rejects a raw digest mismatch' 'G14 Adapter accepted a raw digest mismatch'
    $staleGateG14=New-V1StopLossGate -Expected $cleanSource -Path $g14GoodPath -Digest $g14GoodDigest;$staleGateG14['DP-G14-V1-STOP-LOSS'].source_revision='0'*40
    Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $staleGateG14).Success) 'G14 Adapter rejects a stale Gate revision' 'G14 Adapter accepted a stale Gate revision'
    $extraCallerG14=New-V1StopLossGate -Expected $cleanSource -Path $g14GoodPath -Digest $g14GoodDigest;$extraCallerG14['DP-G14-V1-STOP-LOSS']['reason']='forged-caller-reason'
    Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates $extraCallerG14).Success) 'G14 Gate rejects caller reason as non-authoritative extra input' 'G14 Gate accepted caller reason as authority'

    $script:g14RawIndex=0
    $rejectG14Bytes={
        param([string]$Name,[byte[]]$Bytes)
        $script:g14RawIndex++;$path=Join-Path $temp "v1-stop-loss-raw-$($script:g14RawIndex).json";[IO.File]::WriteAllBytes($path,$Bytes)
        $result=Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path $path -Digest (Get-FileDigest $path))
        Check (-not $result.Success) "G14 Adapter rejects $Name" "G14 Adapter accepted $Name"
    }
    & $rejectG14Bytes 'malformed JSON' ([Text.UTF8Encoding]::new($false).GetBytes('{'))
    & $rejectG14Bytes 'a UTF-8 BOM' ([Text.UTF8Encoding]::new($true).GetPreamble()+[Text.UTF8Encoding]::new($false).GetBytes('{}'))
    & $rejectG14Bytes 'duplicate JSON keys' ([Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":"one","schema_version":"two"}'))
    & $rejectG14Bytes 'an oversized Artifact' ([byte[]]::new((1MB)+1))
    $badReportDigest=Copy-Document $g14Formal;$badReportDigest.report_digest='sha256:'+('0'*64);$badReportDigestPath=Join-Path $temp 'v1-stop-loss-report-digest-mismatch.json';Write-Document $badReportDigestPath $badReportDigest -Compress
    Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path $badReportDigestPath -Digest (Get-FileDigest $badReportDigestPath))).Success) 'G14 Adapter rejects report_digest mismatch' 'G14 Adapter accepted report_digest mismatch'
    $g14Protected=Join-Path $temp 'v1-stop-loss-protected';[void][IO.Directory]::CreateDirectory($g14Protected);$g14ProtectedPath=Join-Path $g14Protected 'report.json';Write-Document $g14ProtectedPath $g14Formal -Compress
    Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path $g14ProtectedPath -Digest (Get-FileDigest $g14ProtectedPath)) -ProtectedRoots @($g14Protected)).Success) 'G14 Adapter rejects Protected Root overlap' 'G14 Adapter accepted Protected Root overlap'
    $g14HardlinkSource=Join-Path $temp 'v1-stop-loss-hardlink-source.json';$g14HardlinkAlias=Join-Path $temp 'v1-stop-loss-hardlink-alias.json';Write-Document $g14HardlinkSource $g14Formal -Compress
    $g14HardlinkOutput=@(& fsutil hardlink create $g14HardlinkAlias $g14HardlinkSource 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "G14 hardlink fixture setup failed: $($g14HardlinkOutput-join' | ')"}
    Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path $g14HardlinkAlias -Digest (Get-FileDigest $g14HardlinkAlias))).Success) 'G14 Adapter rejects a multiply-linked Artifact' 'G14 Adapter accepted a multiply-linked Artifact'
    $g14Ads=Join-Path $temp 'v1-stop-loss-ads.json';Write-Document $g14Ads $g14Formal -Compress;Set-Content -LiteralPath $g14Ads -Stream 'hidden-evidence' -Value 'sentinel' -Encoding utf8NoBOM
    Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path $g14Ads -Digest (Get-FileDigest $g14Ads))).Success) 'G14 Adapter rejects alternate data streams' 'G14 Adapter accepted alternate data streams'
    $g14ReparseTarget=Join-Path $temp 'v1-stop-loss-reparse-target';[void][IO.Directory]::CreateDirectory($g14ReparseTarget);$g14ReparsePath=Join-Path $g14ReparseTarget 'report.json';Write-Document $g14ReparsePath $g14Formal -Compress
    $g14ReparseAlias=Join-Path $temp 'v1-stop-loss-reparse-alias';[void](New-Item -ItemType Junction -Path $g14ReparseAlias -Target $g14ReparseTarget -ErrorAction Stop)
    try{Check (-not (Invoke-PortableGateSet -Module $module -Expected $cleanSource -Gates (New-V1StopLossGate -Expected $cleanSource -Path (Join-Path $g14ReparseAlias 'report.json') -Digest (Get-FileDigest $g14ReparsePath))).Success) 'G14 Adapter rejects a reparse path' 'G14 Adapter accepted a reparse path'}finally{Remove-Item -LiteralPath $g14ReparseAlias -Force}

    $runtimeG14Readers=@('scripts/task.ps1','scripts/lib/Harness.Recovery.psm1','scripts/lib/Harness.RuntimeDefault.psm1')
    Check (@($runtimeG14Readers|Where-Object{(Get-Content -LiteralPath (Join-Path $RepoRoot $_) -Raw -Encoding utf8)-match'v1-stop-loss-report'}).Count-eq0) 'Runtime Core, ordinary Status, and Runtime Default do not read G14 reports' 'a Runtime path began reading G14 qualification evidence'
    $workflowG14Readers=@(Get-ChildItem -LiteralPath (Join-Path $RepoRoot '.github\workflows') -File -Filter '*.yml'|Where-Object{(Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8)-match'run-v1-stop-loss-qualification|v1-stop-loss-report'})
    Check ($workflowG14Readers.Count-eq0) 'Release Workflow remains unwired for G14' 'Release Workflow was changed to run or consume G14'

    $unwiredPath=Join-Path $temp 'still-unwired.json';Write-Document $unwiredPath ([ordered]@{}) -Compress
    foreach($unwiredName in @('DP-G09-RELEASE-MODEL','DP-G10-RELEASE-HOST','DP-G11-RELEASE-FULL','DP-G13-PROMOTION-AUTO-PROBE','DP-G15-CANARY','DP-G16-STABLE-DECISION')){
        $unwiredGate=[ordered]@{};$unwiredGate[$unwiredName]=[ordered]@{status='pass';evidence_contract='fixture/v1';artifact_path=$unwiredPath;evidence_digest=(Get-FileDigest $unwiredPath);source_revision=[string]$cleanSource.revision;producer_identity='Contract Fixture producer'}
        $unwiredReason='';try{& $module {param($Root,$Source,$Gates)Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $Gates} $RepoRoot $cleanSource $unwiredGate}catch{$unwiredReason=[string]$_.Exception.Message}
        Check ($unwiredReason-ceq"rollout-evidence-provenance-unwired-$unwiredName") "$unwiredName remains provenance-unwired and fail closed" "$unwiredName was silently wired or promoted"
    }

    $script:installedMutationIndex=0
    $rejectInstalledMutation = {
        param([string]$Name,[scriptblock]$Mutation)
        $script:installedMutationIndex++
        $left=New-InstalledHostReport -HostReport $hostReport -Seed ("mutation-$($script:installedMutationIndex)-left")
        $right=New-InstalledHostReport -HostReport $hostReport -Seed ("mutation-$($script:installedMutationIndex)-right")
        & $Mutation $left
        foreach($group in @($left.groups)){Set-GroupDigest $group};Set-ReportDigest $left
        $result=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $left -Right $right
        Check (-not $result.Success) "installed Adapter rejects $Name" "installed Adapter accepted $Name"
    }
    & $rejectInstalledMutation 'wrong schema' {param($r)$r.schema_version='harness-host-benchmark-report/v2'}
    & $rejectInstalledMutation 'an unknown field' {param($r)$r['unexpected']='sentinel'}
    & $rejectInstalledMutation 'a stale source revision' {param($r)$r.source_revision='0' * 40}
    & $rejectInstalledMutation 'a dirty source claim' {param($r)$r.source_dirty=$true}
    & $rejectInstalledMutation 'an unstable source claim' {param($r)$r.source_state_stable=$false}
    & $rejectInstalledMutation 'a missing Artifact producer identity' {param($r)$r.producer_identity=''}
    & $rejectInstalledMutation 'a stale producer input digest' {param($r)$r.source.installed_inputs.install_digest='sha256:' + ('0' * 64)}
    & $rejectInstalledMutation 'credential content' {param($r)$r.qualification.reason='authorization: bearer secret'}
    & $rejectInstalledMutation 'a private absolute path' {param($r)$r.qualification.reason='C:\Users\private\secret.txt'}
    & $rejectInstalledMutation 'an embedded Windows private absolute path' {param($r)$r.qualification.reason='prefix C:\Users\private\secret.txt'}
    & $rejectInstalledMutation 'an embedded Unix private absolute path' {param($r)$r.qualification.reason='prefix /home/private/secret.txt'}
    & $rejectInstalledMutation 'an embedded UNC private absolute path' {param($r)$r.qualification.reason='prefix \\server\share\secret.txt'}
    & $rejectInstalledMutation 'raw log content' {param($r)$r.qualification.reason='raw log: retained output'}
    & $rejectInstalledMutation 'a retained raw trace' {param($r)$r.groups[0].protocols.v2.trials[0].raw_trace_deleted=$false}
    & $rejectInstalledMutation 'a CLI-host-equivalent surface' {param($r)$r.groups[0].protocols.v2.trials[0].installed_desktop.host_surface='codex-cli-host-equivalent'}
    & $rejectInstalledMutation 'process-only HARNESS_PROTOCOL v2 selection' {param($r)$r.groups[0].protocols.v2.trials[0].installed_desktop.route_probe.preference_source='HARNESS_PROTOCOL'}
    & $rejectInstalledMutation 'auto eligible-report v2 selection' {param($r)$r.groups[0].protocols.v2.trials[0].installed_desktop.route_probe.requested_protocol='auto';$r.groups[0].protocols.v2.trials[0].installed_desktop.route_probe.reason='eligible-rollout-report'}
    & $rejectInstalledMutation 'a Direct Task or Plan write' {param($r)$r.groups[0].protocols.v2.trials[0].artifact_writes=1}
    & $rejectInstalledMutation 'a Direct Runtime pointer write' {param($r)$r.groups[0].protocols.v2.trials[0].runtime_writes=1}
    & $rejectInstalledMutation 'changed auth bytes' {param($r)$r.groups[0].protocols.v2.trials[0].installed_desktop.auth_unchanged=$false}
    & $rejectInstalledMutation 'changed config bytes' {param($r)$r.groups[0].protocols.v2.trials[0].installed_desktop.profile_config.digest='sha256:' + ('2' * 64)}
    & $rejectInstalledMutation 'cleanup residue' {param($r)$r.groups[0].protocols.v2.trials[0].installed_desktop.cleanup_status='failed'}
    & $rejectInstalledMutation 'v1 Artifact migration' {param($r)$r.groups[0].protocols.v1.trials[0].installed_desktop.route_probe.selected_protocol='v2'}
    & $rejectInstalledMutation 'manual qualification status' {param($r)$r.qualification.status='manual'}
    & $rejectInstalledMutation 'skipped report status' {param($r)$r.status='skipped';$r.qualification.status='skipped'}

    $digestMismatchLeft=New-InstalledHostReport -HostReport $hostReport -Seed digest-mismatch-left;$digestMismatchRight=New-InstalledHostReport -HostReport $hostReport -Seed digest-mismatch-right
    $digestMismatchLeft.report_digest='sha256:' + ('0' * 64)
    $digestMismatchResult=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $digestMismatchLeft -Right $digestMismatchRight
    Check (-not $digestMismatchResult.Success) 'installed Adapter rejects report_digest mismatch' 'installed Adapter accepted report_digest mismatch'

    $pathRightReport=New-InstalledHostReport -HostReport $hostReport -Seed path-right
    $pathRight=Join-Path $temp 'path-right.json';Write-Document $pathRight $pathRightReport -Compress;$pathRightDigest=Get-FileDigest $pathRight
    $missingPath=Join-Path $temp 'missing-installed.json'
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $missingPath -LeftDigest ('sha256:' + ('0' * 64)) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects a missing Artifact' 'installed Adapter accepted a missing Artifact'
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath 'relative-installed.json' -LeftDigest ('sha256:' + ('0' * 64)) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects a relative Artifact path' 'installed Adapter accepted a relative Artifact path'

    $malformedPath=Join-Path $temp 'malformed-installed.json';[IO.File]::WriteAllText($malformedPath,'{',[Text.UTF8Encoding]::new($false))
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $malformedPath -LeftDigest (Get-FileDigest $malformedPath) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects malformed JSON' 'installed Adapter accepted malformed JSON'
    $bomPath=Join-Path $temp 'bom-installed.json';[IO.File]::WriteAllText($bomPath,'{}',[Text.UTF8Encoding]::new($true))
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $bomPath -LeftDigest (Get-FileDigest $bomPath) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects a UTF-8 BOM' 'installed Adapter accepted a UTF-8 BOM'
    $duplicateKeyPath=Join-Path $temp 'duplicate-key-installed.json';[IO.File]::WriteAllText($duplicateKeyPath,'{"schema_version":"one","schema_version":"two"}',[Text.UTF8Encoding]::new($false))
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $duplicateKeyPath -LeftDigest (Get-FileDigest $duplicateKeyPath) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects duplicate JSON keys' 'installed Adapter accepted duplicate JSON keys'
    $oversizedPath=Join-Path $temp 'oversized-installed.json';[IO.File]::WriteAllBytes($oversizedPath,[byte[]]::new((16MB)+1))
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $oversizedPath -LeftDigest (Get-FileDigest $oversizedPath) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects an oversized Artifact' 'installed Adapter accepted an oversized Artifact'

    $rawMismatchReport=New-InstalledHostReport -HostReport $hostReport -Seed raw-mismatch
    $rawMismatchPath=Join-Path $temp 'raw-mismatch-installed.json';Write-Document $rawMismatchPath $rawMismatchReport -Compress
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $rawMismatchPath -LeftDigest ('sha256:' + ('0' * 64)) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects a raw digest mismatch' 'installed Adapter accepted a raw digest mismatch'
    $sameArtifactReport=New-InstalledHostReport -HostReport $hostReport -Seed same-artifact
    $sameArtifactPath=Join-Path $temp 'same-artifact-installed.json';Write-Document $sameArtifactPath $sameArtifactReport -Compress;$sameArtifactDigest=Get-FileDigest $sameArtifactPath
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $sameArtifactPath -LeftDigest $sameArtifactDigest -RightPath $sameArtifactPath -RightDigest $sameArtifactDigest
    Check (-not $pathResult.Success) 'G03/G07 reject one shared Artifact' 'G03/G07 accepted one shared Artifact'
    $copiedArtifactPath=Join-Path $temp 'copied-artifact-installed.json';[IO.File]::Copy($sameArtifactPath,$copiedArtifactPath,$false)
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $sameArtifactPath -LeftDigest $sameArtifactDigest -RightPath $copiedArtifactPath -RightDigest (Get-FileDigest $copiedArtifactPath)
    Check (-not $pathResult.Success) 'G03/G07 reject byte-identical copied evidence' 'G03/G07 accepted byte-identical copied evidence'
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $hostPath -LeftDigest (Get-FileDigest $hostPath) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'Cognitive Host evidence cannot impersonate G03/G07' 'Cognitive Host evidence impersonated an installed Desktop Artifact'

    $revisionMismatchLeft=New-InstalledHostReport -HostReport $hostReport -Seed revision-mismatch-left;$revisionMismatchRight=New-InstalledHostReport -HostReport $hostReport -Seed revision-mismatch-right
    $revisionMismatchLeft.source_revision='0' * 40;Set-ReportDigest $revisionMismatchLeft
    $revisionMismatchResult=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $revisionMismatchLeft -Right $revisionMismatchRight
    Check (-not $revisionMismatchResult.Success) 'G03/G07 reject different source revisions' 'G03/G07 accepted different source revisions'

    $reparseTarget=Join-Path $temp 'reparse-target';[void][IO.Directory]::CreateDirectory($reparseTarget)
    $reparseReport=New-InstalledHostReport -HostReport $hostReport -Seed reparse-left;$reparseSource=Join-Path $reparseTarget 'installed.json';Write-Document $reparseSource $reparseReport -Compress
    $reparseAlias=Join-Path $temp 'reparse-alias';[void](New-Item -ItemType Junction -Path $reparseAlias -Target $reparseTarget -ErrorAction Stop)
    try {
        $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath (Join-Path $reparseAlias 'installed.json') -LeftDigest (Get-FileDigest $reparseSource) -RightPath $pathRight -RightDigest $pathRightDigest
        Check (-not $pathResult.Success) 'installed Adapter rejects a reparse/junction path' 'installed Adapter accepted a reparse/junction path'
    } finally { Remove-Item -LiteralPath $reparseAlias -Force }

    $hardlinkReport=New-InstalledHostReport -HostReport $hostReport -Seed hardlink-left;$hardlinkSource=Join-Path $temp 'hardlink-source.json';$hardlinkAlias=Join-Path $temp 'hardlink-alias.json';Write-Document $hardlinkSource $hardlinkReport -Compress
    $hardlinkOutput=@(& fsutil hardlink create $hardlinkAlias $hardlinkSource 2>&1|ForEach-Object{[string]$_});if($LASTEXITCODE-ne0){throw "hardlink fixture setup failed: $($hardlinkOutput -join ' | ')"}
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $hardlinkAlias -LeftDigest (Get-FileDigest $hardlinkAlias) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects a multiply-linked Artifact' 'installed Adapter accepted a multiply-linked Artifact'

    $adsReport=New-InstalledHostReport -HostReport $hostReport -Seed ads-left;$adsPath=Join-Path $temp 'ads-installed.json';Write-Document $adsPath $adsReport -Compress
    Set-Content -LiteralPath $adsPath -Stream 'hidden-evidence' -Value 'sentinel' -Encoding utf8NoBOM
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $adsPath -LeftDigest (Get-FileDigest $adsPath) -RightPath $pathRight -RightDigest $pathRightDigest
    Check (-not $pathResult.Success) 'installed Adapter rejects alternate data streams' 'installed Adapter accepted alternate data streams'

    $protectedRoot=Join-Path $temp 'protected-root';[void][IO.Directory]::CreateDirectory($protectedRoot)
    $protectedReport=New-InstalledHostReport -HostReport $hostReport -Seed protected-left;$protectedPath=Join-Path $protectedRoot 'installed.json';Write-Document $protectedPath $protectedReport -Compress
    $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $protectedPath -LeftDigest (Get-FileDigest $protectedPath) -RightPath $pathRight -RightDigest $pathRightDigest -ProtectedRoots @($protectedRoot)
    Check (-not $pathResult.Success) 'installed Adapter rejects Protected Root overlap' 'installed Adapter accepted Protected Root overlap'
    $protectedAlias=Join-Path $temp 'protected-root-alias';[void](New-Item -ItemType Junction -Path $protectedAlias -Target $protectedRoot -ErrorAction Stop)
    try {
        $pathResult=Invoke-InstalledGatePaths -Module $module -Expected $cleanSource -LeftPath $protectedPath -LeftDigest (Get-FileDigest $protectedPath) -RightPath $pathRight -RightDigest $pathRightDigest -ProtectedRoots @($protectedAlias)
        Check (-not $pathResult.Success) 'installed Adapter rejects a physical Protected Root alias' 'installed Adapter accepted an Artifact through a physical Protected Root alias'
    } finally { Remove-Item -LiteralPath $protectedAlias -Force }

    $legacyProtocols = Copy-Document $hostGroups[0].protocols
    foreach ($protocol in @('bare','v1','v2')) { foreach ($trial in @($legacyProtocols[$protocol].trials)) { [void]$trial.Remove('trial_run_id'); [void]$trial.Remove('trial_root_digest') } }
    $legacyHost = [ordered]@{schema_version='harness-host-benchmark-report/v1';generated_at_utc=$hostReport.generated_at_utc;source_revision=$hostGroups[0].source_revision;source_dirty=$hostGroups[0].source_dirty;source_state_stable=$hostGroups[0].source_state_stable;source=$hostGroups[0].source;execution=$hostGroups[0].execution;protocols=$legacyProtocols;performance=$hostGroups[0].performance;status=$hostGroups[0].status;report_digest=$null}
    Set-ReportDigest $legacyHost; $path=Join-Path $temp 'host-legacy-v1.json'; Write-Document $path $legacyHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'unavailable') 'legacy one-group host v1 remains historical evidence only' 'legacy host v1 was allowed to become eligible'
    $staleLegacyHost=Copy-Document $legacyHost; $staleLegacyHost.source_revision='0' * 40; Set-ReportDigest $staleLegacyHost; $path=Join-Path $temp 'host-stale-legacy-v1.json'; Write-Document $path $staleLegacyHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'stale legacy host v1 remains invalid rather than historical unavailable evidence' 'stale legacy host v1 was weakened to unavailable'
    $extraSourceHost = Copy-Document $hostReport; $extraSourceHost.source.unexpected='sentinel-extra-field'; Set-ReportDigest $extraSourceHost; $path=Join-Path $temp 'host-extra-source.json'; Write-Document $path $extraSourceHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'host gate rejects extra source fields' 'extra host source field was accepted'
    $extraExecutionHost = Copy-Document $hostReport; $extraExecutionHost.execution.auth_json='sentinel-extra-field'; Set-ReportDigest $extraExecutionHost; $path=Join-Path $temp 'host-extra-execution.json'; Write-Document $path $extraExecutionHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'host gate rejects extra execution fields' 'extra host execution field was accepted'
    $extraTrialHost = Copy-Document $hostReport; $extraTrialHost.groups[0].protocols.bare.trials[0].unexpected='sentinel-extra-field'; Set-ReportDigest $extraTrialHost; $path=Join-Path $temp 'host-extra-trial.json'; Write-Document $path $extraTrialHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'host gate rejects extra trial fields' 'extra host trial field was accepted'
    $extraMeasurementHost = Copy-Document $hostReport; $extraMeasurementHost.groups[0].protocols.v1.trials[0].successful_request_sends.secret='sentinel-extra-field'; Set-ReportDigest $extraMeasurementHost; $path=Join-Path $temp 'host-extra-measurement.json'; Write-Document $path $extraMeasurementHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'host gate rejects extra measurement fields' 'extra host measurement field was accepted'
    $shortHost = Copy-Document $hostReport; $shortHost.groups=@($shortHost.groups | Select-Object -First 2); $shortHost.execution.groups=2; $shortHost.performance.release_group_set.status='fail'; $shortHost.performance.release_group_set.passed_groups=2; $shortHost.performance.eligible=$false; $shortHost.status='fail'; Set-ReportDigest $shortHost; $path=Join-Path $temp 'host-short.json'; Write-Document $path $shortHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'fewer than three independent groups fail closed' 'short host report was accepted'
    $flatNineHost = Copy-Document $hostReport; $flatNineHost.groups=@($flatNineHost.groups | Select-Object -First 1); $flatNineHost.execution.groups=1; $flatNineHost.execution.trials_per_protocol_per_group=9; $flatNineHost.performance.release_group_set.status='fail'; $flatNineHost.performance.release_group_set.passed_groups=1; $flatNineHost.performance.eligible=$false; $flatNineHost.status='fail'; Set-ReportDigest $flatNineHost; $path=Join-Path $temp 'host-flat-nine.json'; Write-Document $path $flatNineHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'flat Trials=9 cannot substitute for three independent groups' 'flat nine-trial host report was accepted'
    $duplicateIdHost = Copy-Document $hostReport; $duplicateIdHost.groups[1].group_run_id=$duplicateIdHost.groups[0].group_run_id; Set-GroupDigest $duplicateIdHost.groups[1]; Set-ReportDigest $duplicateIdHost; $path=Join-Path $temp 'host-duplicate-group-id.json'; Write-Document $path $duplicateIdHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'duplicate host group id fails closed' 'duplicate host group id was accepted'
    $duplicateRootHost = Copy-Document $hostReport; $duplicateRootHost.groups[1].group_root_digest=$duplicateRootHost.groups[0].group_root_digest; Set-GroupDigest $duplicateRootHost.groups[1]; Set-ReportDigest $duplicateRootHost; $path=Join-Path $temp 'host-duplicate-group-root.json'; Write-Document $path $duplicateRootHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'duplicate host group root fails closed' 'duplicate host group root was accepted'
    $copiedGroupHost = Copy-Document $hostReport; $replacementId=$copiedGroupHost.groups[1].group_run_id; $replacementRoot=$copiedGroupHost.groups[1].group_root_digest; $copiedGroupHost.groups[1]=(Copy-Document $copiedGroupHost.groups[0]); $copiedGroupHost.groups[1].group_index=2; $copiedGroupHost.groups[1].group_run_id=$replacementId; $copiedGroupHost.groups[1].group_root_digest=$replacementRoot
    $identityIndex=0; foreach ($protocol in @('bare','v1','v2')) { foreach ($trial in @($copiedGroupHost.groups[1].protocols[$protocol].trials)) { $identityIndex++; $trial.trial_run_id=(Get-TextDigest "replacement-trial-$identityIndex").Substring(7,32); $trial.trial_root_digest=Get-TextDigest "replacement-trial-root-$identityIndex" } }
    Set-GroupDigest $copiedGroupHost.groups[1]; Set-ReportDigest $copiedGroupHost; $path=Join-Path $temp 'host-copied-group-new-identity.json'; Write-Document $path $copiedGroupHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'copied trial payloads remain rejected after replacing group and trial identities and recomputing digests' 'copied group bypassed independence by replacing identities'
    $reorderedNestedHost = Copy-Document $hostReport; $replacementTrial=(Copy-Document $reorderedNestedHost.groups[0].protocols.bare.trials[0]); $replacementTrial.trial_run_id=$reorderedNestedHost.groups[1].protocols.bare.trials[0].trial_run_id; $replacementTrial.trial_root_digest=$reorderedNestedHost.groups[1].protocols.bare.trials[0].trial_root_digest
    $binding=$replacementTrial.source_binding; $replacementTrial.source_binding=[ordered]@{reason=$binding.reason;verification=$binding.verification;commit_tree_oid=$binding.commit_tree_oid;revision=$binding.revision;status=$binding.status}; $reorderedNestedHost.groups[1].protocols.bare.trials[0]=$replacementTrial
    Set-GroupDigest $reorderedNestedHost.groups[1]; Set-ReportDigest $reorderedNestedHost; $path=Join-Path $temp 'host-reordered-nested-copy.json'; Write-Document $path $reorderedNestedHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'copied trial payload remains rejected after nested dictionary key reordering' 'nested dictionary key order bypassed canonical trial duplicate detection'
    $duplicateTrialHost = Copy-Document $hostReport; $duplicateTrialHost.groups[0].protocols.bare.trials[1]=(Copy-Document $duplicateTrialHost.groups[0].protocols.bare.trials[0]); Set-GroupDigest $duplicateTrialHost.groups[0]; Set-ReportDigest $duplicateTrialHost; $path=Join-Path $temp 'host-duplicate-trial.json'; Write-Document $path $duplicateTrialHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'duplicate canonical trial payload fails closed' 'duplicate host trial payload was accepted'
    $slowHost = Copy-Document $hostReport; $slowHost.groups[0].performance.direct_latency.ratio=1.3; Set-GroupDigest $slowHost.groups[0]; Set-ReportDigest $slowHost; $path=Join-Path $temp 'host-slow.json'; Write-Document $path $slowHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'host threshold contradiction fails closed' 'host threshold contradiction was accepted'
    $forgedHost = Copy-Document $hostReport; $forgedHost.groups[0].protocols.v2.trials[1].total_duration_ms=1000; Set-GroupDigest $forgedHost.groups[0]; Set-ReportDigest $forgedHost; $path=Join-Path $temp 'host-forged-median.json'; Write-Document $path $forgedHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'each group performance median is recomputed from its own exact 3x3 trials' 'forged host aggregate was accepted'
    $unboundHost = Copy-Document $hostReport; $unboundHost.groups[0].protocols.bare.trials[0].source_binding.revision='0' * 40; Set-GroupDigest $unboundHost.groups[0]; Set-ReportDigest $unboundHost; $path=Join-Path $temp 'host-unbound.json'; Write-Document $path $unboundHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'every host trial is independently bound to the qualified source' 'unbound host trial was accepted'
    $forgedHostSource = Copy-Document $hostReport; $forgedHostSource.source.start.status_digest='sha256:' + ('f' * 64); $forgedHostSource.source.end.status_digest='sha256:' + ('f' * 64); Set-ReportDigest $forgedHostSource; $path=Join-Path $temp 'host-forged-source.json'; Write-Document $path $forgedHostSource
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'host source snapshots bind the exact qualified status digest' 'forged host source snapshot was accepted'
    $typedHost = Copy-Document $hostReport; $typedHost.execution.fresh_workspace_per_trial='false'; $typedHost.groups[0].protocols.v2.trials[0].runner_evidence_passed='false'; $typedHost.groups[0].performance.direct_latency.ratio='NaN'; Set-ReportDigest $typedHost; $path=Join-Path $temp 'host-type-forgery.json'; Write-Document $path $typedHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'host gate rejects string-forged booleans and non-finite performance values' 'host type forgery was accepted'
    $unavailableHost = Copy-Document $hostReport; $unavailableHost.groups[0].status='unavailable'; $unavailableHost.groups[0].performance.eligible=$false; Set-GroupDigest $unavailableHost.groups[0]; $unavailableHost.status='unavailable'; $unavailableHost.performance.release_group_set.status='unavailable'; $unavailableHost.performance.release_group_set.passed_groups=2; $unavailableHost.performance.eligible=$false; Set-ReportDigest $unavailableHost; $path=Join-Path $temp 'host-unavailable.json'; Write-Document $path $unavailableHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'unavailable') 'host measurement unavailability remains unavailable' 'host measurement unavailability was misclassified'
    $extraUnavailableHost = Copy-Document $unavailableHost; $extraUnavailableHost.groups[0].protocols.v2.trials[0].source_binding.secret='sentinel-extra-field'; Set-ReportDigest $extraUnavailableHost; $path=Join-Path $temp 'host-unavailable-extra.json'; Write-Document $path $extraUnavailableHost
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $path -ExpectedSource $cleanSource).status -ceq 'fail') 'unavailable host reports still reject extra nested fields' 'unavailable host report accepted an extra nested field'
    $dirtyExpected = Copy-Document $cleanSource; $dirtyExpected.dirty=$true
    Check ([string](Get-HarnessReleaseEvidenceGate -Kind host -RepoRoot $RepoRoot -ReportPath $hostPath -ExpectedSource $dirtyExpected).status -ceq 'fail') 'dirty generator source rejects otherwise passing evidence' 'dirty generator source accepted release evidence'

    $qualificationModule = Import-Module $qualificationPath -Force -PassThru
    $sourcePaths = @(& $qualificationModule { param($Root) Get-HarnessRolloutSourcePaths -RepoRoot $Root } $RepoRoot)
    $tracked = @(& git -C $RepoRoot -c core.quotepath=false ls-files -- | ForEach-Object { ([string]$_).Replace('\','/') })
    Check ($sourcePaths.Count -gt 0 -and @($sourcePaths | Where-Object { $_ -cnotin $tracked }).Count -eq 0) 'rollout source digest enumerates tracked files only' 'rollout source digest included an untracked or ignored file'
    Check (@($sourcePaths | Where-Object { $_.StartsWith('skills/.system/',[StringComparison]::Ordinal) }).Count -eq 0) 'ignored generated skill runtime is excluded from rollout source digest' 'ignored generated skill runtime entered rollout source digest'

    $unavailableGates = [ordered]@{
        behavior=[ordered]@{status='unavailable'};v1_compatibility=[ordered]@{status='pass'};direct_performance=[ordered]@{status='unavailable'}
        core_install_rollback=[ordered]@{status='pass'};full_install_rollback=[ordered]@{status='pass'}
    }
    $failedGates = Copy-Document $unavailableGates; $failedGates.behavior.status='fail'
    $requiredExit = & $module { param($Values) Get-HarnessReleaseExitCode -Gates $Values -Eligible $false -RequireEligible $true } $unavailableGates
    $diagnosticExit = & $module { param($Values) Get-HarnessReleaseExitCode -Gates $Values -Eligible $false -RequireEligible $false } $unavailableGates
    $failedExit = & $module { param($Values) Get-HarnessReleaseExitCode -Gates $Values -Eligible $false -RequireEligible $true } $failedGates
    Check ($requiredExit -eq 3 -and $diagnosticExit -eq 0 -and $failedExit -eq 1) 'release exit classification distinguishes unavailable diagnostics from failed evidence' 'release exit classification is invalid'

    $artifactTarget = & $module { param($Root,$Path,$Inputs) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path -EvidencePaths $Inputs } $RepoRoot (Join-Path $temp 'artifact\rollout.json') @($modelPath,$hostPath)
    $artifactContent = '{"eligible":false}'
    & $module { param($Target,$Content) Write-HarnessReleaseArtifact -Target $Target -Content $Content } $artifactTarget $artifactContent
    Check ((Get-Content -LiteralPath $artifactTarget -Raw -Encoding utf8) -ceq $artifactContent) 'rollout artifact is atomically persisted before the caller applies its exit code' 'rollout artifact persistence failed'
    $existingRejected=$false; try { $null = & $module { param($Root,$Path) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path } $RepoRoot $artifactTarget } catch { $existingRejected=$true }
    Check $existingRejected 'rollout output refuses to clobber an existing file' 'existing rollout output was overwriteable'
    $gitRejected=$false; try { $null = & $module { param($Root,$Path) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path } $RepoRoot (Join-Path $RepoRoot '.git\rq09-output.json') } catch { $gitRejected=$true }
    Check $gitRejected 'rollout output rejects Git metadata paths' 'Git metadata could be used as rollout output'
    $sourceRejected=$false; try { $null = & $module { param($Root,$Path) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path } $RepoRoot (Join-Path $RepoRoot 'tests\rq09-output.json') } catch { $sourceRejected=$true }
    Check $sourceRejected 'rollout output inside source must be explicitly ignored' 'non-ignored source path could be used as rollout output'
    $credentialRoot=Join-Path $temp 'credential-home'; [void][IO.Directory]::CreateDirectory($credentialRoot)
    $credentialRejected=$false; try { $null = & $module { param($Root,$Path,$Protected) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path -ProtectedRoots $Protected } $RepoRoot (Join-Path $credentialRoot 'rollout.json') @($credentialRoot) } catch { $credentialRejected=$true }
    Check $credentialRejected 'rollout output rejects credential-home overlap' 'credential home could be used as rollout output'
    $credentialAlias=Join-Path $temp 'credential-alias'; [void](New-Item -ItemType Junction -Path $credentialAlias -Target $credentialRoot -ErrorAction Stop)
    $physicalAliasRejected=$false; try { $null = & $module { param($Root,$Path,$Protected) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Path -ProtectedRoots $Protected } $RepoRoot (Join-Path $credentialRoot 'physical-rollout.json') @($credentialAlias) } catch { $physicalAliasRejected=$true }
    Check $physicalAliasRejected 'rollout output compares credential-home physical identities' 'credential-home junction alias bypassed output containment'
} finally {
    Remove-Module Harness.RolloutEvidence,Harness.Protocol -ErrorAction Ignore
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

foreach ($item in $script:checks) { Write-Output "[PASS] $item" }
foreach ($item in $script:failures) { Write-Output "[FAIL] $item" }
if ($script:failures.Count -gt 0) { Write-Output "STATUS: FAIL ($($script:failures.Count) failed)"; exit 1 }
Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
exit 0
