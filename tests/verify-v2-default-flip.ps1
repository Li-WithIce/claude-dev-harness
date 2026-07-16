[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks=[System.Collections.Generic.List[string]]::new();$script:failures=[System.Collections.Generic.List[string]]::new()
function Check($Condition,$Pass,$Fail){if($Condition){$script:checks.Add($Pass)}else{$script:failures.Add($Fail)}}
function New-Gates([string]$Performance='pass'){
    $digest='sha256:'+('2'*64)
    return [ordered]@{
        behavior=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-model-evals.ps1 -Model gpt-5.6-sol -Reasoning max'}
        v1_compatibility=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput'}
        direct_performance=[ordered]@{status=$Performance;evidence_digest=$digest;command='scripts/run-host-benchmark.ps1 -Trials 3 -Model gpt-5.6-sol -Reasoning max'}
        core_install_rollback=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-isolated-install-smoke.ps1 -Preset core'}
        full_install_rollback=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-isolated-install-smoke.ps1 -Preset full'}
    }
}
function New-Report([System.Collections.IDictionary]$Gates){return & $script:protocolModule {param($Root,$Values) New-HarnessRolloutReportDocument -RepoRoot $Root -Gates $Values} $RepoRoot $Gates}
function Set-ReportDigest([System.Collections.IDictionary]$Document){$Document.report_digest=& $script:protocolModule {param($Value) Get-HarnessRolloutReportDigest -Document $Value} $Document}
function Write-Report($Workspace,$Name,[System.Collections.IDictionary]$Document){$relative="rollout/$Name.json";$target=Join-Path $Workspace $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));[IO.File]::WriteAllText($target,($Document|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false));return $relative}
function Resolve-Protocol($Workspace,$ReportPath,$TaskId='new-task',$Requested='auto'){return Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $Workspace -TaskId $TaskId -RequestedProtocol $Requested -EligibilityReportPath $ReportPath}
function New-V2TaskDocument($TaskId){$now=[DateTimeOffset]::UtcNow.ToString('o');return [ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='ready';identity='existing';intent='write';requirement_state='clear';execution_profile='direct';persistence='ephemeral';policies=[ordered]@{plan_required=$false;approval_required=$false;rollback_required=$false;independent_review_required=$false;verification_required=$true};created_at=$now;updated_at=$now}}

$protocolPath=Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1';$generatorPath=Join-Path $RepoRoot 'scripts\generate-v2-rollout-report.ps1';$docPath=Join-Path $RepoRoot 'docs\release\compatibility-policy.md'
$repoBefore=@(&git -C $RepoRoot status --porcelain --untracked-files=all)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('thin-v2-pr14-'+[guid]::NewGuid().ToString('N'));$workspace=Join-Path $temp 'workspace'
$oldGitDir=[Environment]::GetEnvironmentVariable('GIT_DIR',[EnvironmentVariableTarget]::Process);$oldGitWorkTree=[Environment]::GetEnvironmentVariable('GIT_WORK_TREE',[EnvironmentVariableTarget]::Process)
try{
    [void][IO.Directory]::CreateDirectory($workspace)
    $shadowRepo=Join-Path $temp 'qualification-git';$null=@(&git init --quiet -- $shadowRepo 2>&1);if($LASTEXITCODE-ne0){throw 'shadow qualification Git init failed'}
    $env:GIT_DIR=Join-Path $shadowRepo '.git';$env:GIT_WORK_TREE=$RepoRoot
    $null=@(&git -C $RepoRoot add -A -- 2>&1);if($LASTEXITCODE-ne0){throw 'shadow qualification Git add failed'}
    $null=@(&git -C $RepoRoot -c user.name='Rollout Test' -c user.email='rollout@test.invalid' commit --quiet -m qualification-snapshot 2>&1);if($LASTEXITCODE-ne0){throw 'shadow qualification Git commit failed'}
    foreach($file in @($protocolPath,$generatorPath,$PSCommandPath)){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq0) "$(Split-Path -Leaf $file) parses" "$(Split-Path -Leaf $file) parse failed";Check (Test-FileHasUtf8Bom $file) "$(Split-Path -Leaf $file) has UTF-8 BOM" "$(Split-Path -Leaf $file) lacks UTF-8 BOM"}
    $script:protocolModule=Import-Module $protocolPath -Force -PassThru
    $exports=@($script:protocolModule.ExportedFunctions.Keys)
    Check ($exports.Count-eq1-and$exports[0]-ceq'Get-HarnessProtocolResolution') 'Protocol keeps one public function' 'Protocol exposed rollout internals'
    $sourcePaths=@(& $script:protocolModule {param($Root) Get-HarnessRolloutSourcePaths -RepoRoot $Root} $RepoRoot)
    Check ($sourcePaths-ccontains'runtime-hooks/core/pretooluse.ps1'-and$sourcePaths-ccontains'scripts/migrate-task-v1-to-v2.ps1'-and$sourcePaths-ccontains'scripts/run-validation.ps1'-and$sourcePaths-ccontains'tests/verify-v2-approval.ps1') 'rollout source digest covers runtime, migration, validation, and hard-safety tests' 'rollout source digest omits a safety execution surface'
    $generator=Get-Content -LiteralPath $generatorPath -Raw -Encoding utf8
    Check ($generator-match'run-validation\.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput'-and$generator-match"\[UNAVAILABLE\\\]\\s\+") 'rollout generator exposes and classifies full-suite unavailable evidence' 'rollout generator can collapse unavailable full-suite evidence into pass'

    $missing=Resolve-Protocol $workspace ''
    Check ($missing.selected_protocol-ceq'v1'-and$missing.reason-ceq'rollout-report-missing'-and$missing.rollout_eligibility.status-ceq'missing'-and$missing.warning-match'deprecated') 'missing report keeps new auto task on v1 with a diagnostic warning' 'missing report did not fail safe to v1'

    $pass=New-Report (New-Gates);$passPath=Write-Report $workspace 'pass' $pass;$eligible=Resolve-Protocol $workspace $passPath
    Check ($eligible.selected_protocol-ceq'v2'-and$eligible.reason-ceq'eligible-rollout-report'-and$eligible.rollout_eligibility.status-ceq'pass'-and$null-eq$eligible.warning) 'current all-pass report flips only a new auto task to v2' 'all-pass current report did not select v2'
    $null=@(&git -C $RepoRoot rm --cached --quiet -- scripts/lib/Harness.RolloutEvidence.psm1 2>&1);if($LASTEXITCODE-ne0){throw 'shadow untracked-source setup failed'}
    $dirtyDistribution=Resolve-Protocol $workspace $passPath
    Check ($dirtyDistribution.selected_protocol-ceq'v1'-and$dirtyDistribution.reason-ceq'rollout-source-dirty') 'untracked distribution source invalidates an otherwise current report' 'untracked distribution source kept auto on v2'
    $null=@(&git -C $RepoRoot add -- scripts/lib/Harness.RolloutEvidence.psm1 2>&1);if($LASTEXITCODE-ne0){throw 'shadow untracked-source restore failed'}

    foreach($status in @('fail','blocked','unavailable','simulated')){
        $document=New-Report (New-Gates $status);$path=Write-Report $workspace "performance-$status" $document;$result=Resolve-Protocol $workspace $path
        Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq"rollout-gate-direct_performance-$status") "$status performance gate keeps auto on v1" "$status performance gate selected v2"
    }
    foreach($case in @(
        [pscustomobject]@{name='behavior';status='unavailable'},
        [pscustomobject]@{name='v1_compatibility';status='blocked'},
        [pscustomobject]@{name='core_install_rollback';status='fail'},
        [pscustomobject]@{name='full_install_rollback';status='simulated'}
    )){
        $gates=New-Gates;$gates[$case.name].status=$case.status;$document=New-Report $gates;$path=Write-Report $workspace ("gate-{0}-{1}" -f $case.name,$case.status) $document;$result=Resolve-Protocol $workspace $path
        Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq("rollout-gate-{0}-{1}" -f $case.name,$case.status)) "$($case.name) $($case.status) keeps auto on v1" "$($case.name) $($case.status) selected v2"
    }

    $staleRevision=($pass|ConvertTo-Json -Depth 30)|ConvertFrom-Json -AsHashtable -Depth 30;$staleRevision.source_revision='0'*40;Set-ReportDigest $staleRevision;$path=Write-Report $workspace 'stale-revision' $staleRevision;$result=Resolve-Protocol $workspace $path
    Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-stale-revision') 'stale revision fails closed' 'stale revision selected v2'
    $staleSource=($pass|ConvertTo-Json -Depth 30)|ConvertFrom-Json -AsHashtable -Depth 30;$staleSource.source_digest='sha256:'+('3'*64);Set-ReportDigest $staleSource;$path=Write-Report $workspace 'stale-source' $staleSource;$result=Resolve-Protocol $workspace $path
    Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-stale-source') 'stale source digest fails closed' 'stale source digest selected v2'
    $staleGenerator=($pass|ConvertTo-Json -Depth 30)|ConvertFrom-Json -AsHashtable -Depth 30;$staleGenerator.generator_digest='sha256:'+('4'*64);Set-ReportDigest $staleGenerator;$path=Write-Report $workspace 'stale-generator' $staleGenerator;$result=Resolve-Protocol $workspace $path
    Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-stale-generator') 'stale generator digest fails closed' 'stale generator selected v2'
    $tampered=($pass|ConvertTo-Json -Depth 30)|ConvertFrom-Json -AsHashtable -Depth 30;$tampered.gates.behavior.evidence_digest='sha256:'+('5'*64);$path=Write-Report $workspace 'tampered' $tampered;$result=Resolve-Protocol $workspace $path
    Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-digest-mismatch') 'tampered report digest fails closed' 'tampered report selected v2'
    $proxy=($pass|ConvertTo-Json -Depth 30)|ConvertFrom-Json -AsHashtable -Depth 30;$proxy.gates.behavior.command='tests/run-scenario-evals.ps1 -Suite core';Set-ReportDigest $proxy;$path=Write-Report $workspace 'proxy-command' $proxy;$result=Resolve-Protocol $workspace $path
    Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-invalid-gate') 'deterministic proxy command fails closed' 'deterministic proxy command selected v2'
    $extra=($pass|ConvertTo-Json -Depth 30)|ConvertFrom-Json -AsHashtable -Depth 30;$extra['authorization_bypass']=$true;$path=Write-Report $workspace 'extra-key' $extra;$result=Resolve-Protocol $workspace $path
    Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-invalid-document') 'unknown report fields fail closed' 'unknown report field selected v2'
    $outside=Resolve-Protocol $workspace '..\outside-report.json'
    Check ($outside.selected_protocol-ceq'v1'-and$outside.rollout_eligibility.status-ceq'invalid') 'report path escape fails closed' 'outside report path was accepted'

    $v1Id='existing-v1';$v1Path=Join-Path $workspace "docs\tasks\$v1Id\plan.md";[void][IO.Directory]::CreateDirectory((Split-Path -Parent $v1Path));[IO.File]::WriteAllText($v1Path,"---`ntask_id: existing-v1`nstage: TEST`ntool: codex`nupdated: 2026-07-14`n---`n",[Text.UTF8Encoding]::new($false))
    $existingV1=Resolve-Protocol $workspace $passPath $v1Id
    Check ($existingV1.selected_protocol-ceq'v1'-and$existingV1.detected_protocol-ceq'v1'-and$existingV1.rollout_eligibility.status-ceq'not-required') 'existing v1 artifact overrides an eligible rollout report' 'eligible report converted existing v1 task'
    $v2Id='existing-v2';$v2Path=Join-Path $workspace ".assistant\runtime\tasks\$v2Id\task.json";[void][IO.Directory]::CreateDirectory((Split-Path -Parent $v2Path));[IO.File]::WriteAllText($v2Path,((New-V2TaskDocument $v2Id)|ConvertTo-Json -Depth 20 -Compress),[Text.UTF8Encoding]::new($false));$failedPath=Write-Report $workspace 'failed' (New-Report (New-Gates 'fail'))
    $existingV2=Resolve-Protocol $workspace $failedPath $v2Id
    Check ($existingV2.selected_protocol-ceq'v2'-and$existingV2.detected_protocol-ceq'v2'-and$existingV2.rollout_eligibility.status-ceq'not-required') 'existing v2 artifact overrides an ineligible report' 'ineligible report downgraded existing v2 task'
    $explicitV1=Resolve-Protocol $workspace $passPath 'explicit-new' 'v1';$explicitV2=Resolve-Protocol $workspace '' 'explicit-new' 'v2'
    Check ($explicitV1.selected_protocol-ceq'v1'-and$explicitV1.reason-ceq'explicit-v1-new-task'-and$explicitV2.selected_protocol-ceq'v2'-and$explicitV2.reason-ceq'explicit-v2-new-task') 'explicit v1 rollback and v2 opt-in remain deterministic' 'explicit protocol behavior drifted'

    $oldProtocol=$env:HARNESS_PROTOCOL;$oldReport=$env:HARNESS_V2_ELIGIBILITY_REPORT
    try{$env:HARNESS_PROTOCOL='auto';$env:HARNESS_V2_ELIGIBILITY_REPORT=$passPath;Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Policy.psm1') -Force;$zero=[ordered]@{user_visible_behavior=0;data_integrity=0;authorization_and_security=0;external_side_effects=0;blast_radius=0;rollback=0;verification_coverage=0};$route=Resolve-HarnessExecutionProfile -RepoRoot $RepoRoot -WorkspaceRoot $workspace -RiskScores $zero;Check ($route.selected_protocol-ceq'v2'-and$route.profile-ceq'direct') 'eligible auto report reaches v2 Direct policy without another model turn' 'Policy ignored the eligible auto report'}finally{if($null-eq$oldProtocol){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$oldProtocol};if($null-eq$oldReport){Remove-Item Env:HARNESS_V2_ELIGIBILITY_REPORT -ErrorAction Ignore}else{$env:HARNESS_V2_ELIGIBILITY_REPORT=$oldReport};Remove-Module Harness.Policy -ErrorAction Ignore}

    $doc=Get-Content -LiteralPath $docPath -Raw -Encoding utf8
    Check ($doc-match'HARNESS_PROTOCOL=v1'-and$doc-match'does not delete v1'-and$doc-match'complete external release cycle') 'compatibility policy documents rollback, retention, and external release-cycle boundary' 'compatibility policy is incomplete'
}finally{
    if($null-eq$oldGitDir){Remove-Item Env:GIT_DIR -ErrorAction Ignore}else{$env:GIT_DIR=$oldGitDir}
    if($null-eq$oldGitWorkTree){Remove-Item Env:GIT_WORK_TREE -ErrorAction Ignore}else{$env:GIT_WORK_TREE=$oldGitWorkTree}
    Remove-Module Harness.Protocol -ErrorAction Ignore;if(Test-Path $temp){Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue}
}
$repoAfter=@(&git -C $RepoRoot status --porcelain --untracked-files=all);Check (@(Compare-Object $repoBefore $repoAfter).Count-eq0) 'default-flip verifier leaves repository state unchanged' 'default-flip verifier changed repository state'
foreach($item in $script:checks){"[PASS] $item"};foreach($item in $script:failures){"[FAIL] $item"};if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1};"STATUS: PASS ($($script:checks.Count) checks)";exit 0
