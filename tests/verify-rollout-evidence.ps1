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

    $installedFormalA=New-InstalledHostReport -HostReport $hostReport -Seed formal-a
    $installedFormalB=New-InstalledHostReport -HostReport $hostReport -Seed formal-b
    $installedFormalResult=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $installedFormalA -Right $installedFormalB
    Check ($installedFormalResult.Success -and [string]$installedFormalResult.Gates['DP-G03-INSTALLED-DESKTOP-HOST-3X3'].status -ceq 'pass' -and [string]$installedFormalResult.Gates['DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE'].producer_identity -ceq 'host-benchmark-installed-desktop/v1') 'two distinct formal-shaped installed contracts are adapted from Artifact status and identity' "valid installed contracts were rejected: $($installedFormalResult.Reason) / $($installedFormalResult.Detail)"
    Check ([string]$installedFormalA.qualification.hook_trust -ceq 'manual' -and -not [bool]$installedFormalA.qualification.hook_observations_blocking -and $installedFormalResult.Success) 'manual Hook observations remain advisory and nonblocking' 'manual Hook observations were forged as machine facts or incorrectly made blocking'

    $installedTestA=New-InstalledHostReport -HostReport $hostReport -Seed test-a -ProducerMode test-only
    $installedTestB=New-InstalledHostReport -HostReport $hostReport -Seed test-b -ProducerMode test-only
    $installedTestResult=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $installedTestA -Right $installedTestB
    Check ($installedTestResult.Success -and @($installedTestResult.Gates.Values | Where-Object { [string]$_.status -ceq 'unavailable' }).Count -eq 2 -and @($installedTestResult.Gates.Values | Where-Object { [string]$_.producer_identity -ceq 'host-benchmark-installed-desktop/v1' }).Count -eq 2) 'caller pass/producer claims are overwritten by test-only Artifact facts' 'test-only evidence became pass or retained caller producer identity'
    $installedSmokeA=New-InstalledHostReport -HostReport $hostReport -Seed smoke-a -ProducerMode diagnostic-smoke
    $installedSmokeB=New-InstalledHostReport -HostReport $hostReport -Seed smoke-b -ProducerMode diagnostic-smoke
    $installedSmokeResult=Invoke-InstalledReportPair -Module $module -Expected $cleanSource -Root $temp -Left $installedSmokeA -Right $installedSmokeB
    Check ($installedSmokeResult.Success -and @($installedSmokeResult.Gates.Values | Where-Object { [string]$_.status -ceq 'unavailable' }).Count -eq 2) 'diagnostic smoke remains unavailable' 'diagnostic smoke became formal evidence'

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
