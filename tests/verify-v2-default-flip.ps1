[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [Collections.Generic.List[string]]::new()
$script:failures = [Collections.Generic.List[string]]::new()
function Check($Condition,[string]$Pass,[string]$Fail) { if ($Condition) { $script:checks.Add($Pass) } else { $script:failures.Add($Fail) } }
function Copy-Document([Collections.IDictionary]$Document) { return ($Document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String }
function Write-Json([string]$Path,[Collections.IDictionary]$Document) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,($Document | ConvertTo-Json -Depth 100 -Compress),[Text.UTF8Encoding]::new($false)) }
function Test-ExactBytes([byte[]]$Left,[byte[]]$Right) { if ($Left.Length -ne $Right.Length) { return $false };for($i=0;$i-lt$Left.Length;$i++){if($Left[$i]-ne$Right[$i]){return $false}};return $true }
function Set-ReportDigest([Collections.IDictionary]$Document) { $Document.report_digest = & $script:protocolModule { param($Value) Get-HarnessRolloutReportDigest -Document $Value } $Document }
function Set-AuthorizationDigest([Collections.IDictionary]$Document) { $Document.authorization_digest = & $script:protocolModule { param($Value) Get-HarnessCanaryAuthorizationDigest -Document $Value } $Document }
function New-V1Gates([string]$Status='pass') {
    $digest='sha256:'+('2'*64)
    return [ordered]@{
        behavior=[ordered]@{status=$Status;evidence_digest=$digest;command='scripts/run-model-evals.ps1 -Model gpt-5.6-sol -Reasoning max'}
        v1_compatibility=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput'}
        direct_performance=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-host-benchmark.ps1 -Groups 3 -Trials 3 -Model gpt-5.6-sol -Reasoning max'}
        core_install_rollback=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-isolated-install-smoke.ps1 -Preset core'}
        full_install_rollback=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-isolated-install-smoke.ps1 -Preset full'}
    }
}
function New-V1Report([string]$Status='pass',[string]$Distribution=$RepoRoot) { return & $script:protocolModule { param($Root,$Gates) New-HarnessRolloutReportDocument -RepoRoot $Root -Gates $Gates } $Distribution (New-V1Gates $Status) }
function New-EvidenceSet([ValidateSet('canary-candidate','final-default')][string]$Phase='final-default',[string]$Distribution=$RepoRoot) {
    $revision = & $script:protocolModule { param($Root) Get-HarnessRolloutRevision -RepoRoot $Root } $Distribution
    $contracts = & $script:protocolModule { Get-HarnessRolloutV2GateContracts -InputOnly }
    $hostBinding = & $script:protocolModule { Get-HarnessRolloutV2ExpectedHost }
    $gates = [ordered]@{}
    foreach($name in $contracts.Keys) {
        $status = if($Phase-ceq'canary-candidate'-and[string]$name-cin@('DP-G13-PROMOTION-AUTO-PROBE','DP-G15-CANARY','DP-G16-STABLE-DECISION')){'not_run'}else{'pass'}
        $gates[$name]=[ordered]@{status=$status;evidence_contract=[string]$contracts[$name];evidence_digest='sha256:'+('3'*64);source_revision=$revision}
    }
    return [ordered]@{schema_version='rollout-evidence-set/v1';phase=$Phase;source_revision=$revision;host=$hostBinding;gates=$gates}
}
function New-V2Report([ValidateSet('canary-candidate','final-default')][string]$Phase='final-default',[string]$Distribution=$RepoRoot) {
    return & $script:protocolModule { param($Root,$Set) New-HarnessRolloutV2ReportDocument -RepoRoot $Root -EvidenceSet $Set } $Distribution (New-EvidenceSet -Phase $Phase -Distribution $Distribution)
}
function Write-WorkspaceReport([string]$Workspace,[string]$Name,[Collections.IDictionary]$Document) { $relative="rollout/$Name.json";Write-Json (Join-Path $Workspace $relative) $Document;return $relative }
function Resolve-Protocol([string]$Workspace,[AllowEmptyString()][string]$ReportPath,[string]$TaskId='new-task',[string]$Requested='auto') { return Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $Workspace -TaskId $TaskId -RequestedProtocol $Requested -EligibilityReportPath $ReportPath }
function Resolve-ProtocolDefault([string]$Workspace,[string]$TaskId='new-task',[string]$Requested='auto') { return Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $Workspace -TaskId $TaskId -RequestedProtocol $Requested }
function Set-ReportEnvironment($Value) { if($null-eq$Value){Remove-Item Env:HARNESS_V2_ELIGIBILITY_REPORT -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[string]$Value,[EnvironmentVariableTarget]::Process)} }
function Resolve-ProtocolCanonical([string]$Workspace) { $prior=[Environment]::GetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[EnvironmentVariableTarget]::Process);try{Set-ReportEnvironment $null;return Resolve-ProtocolDefault $Workspace}finally{Set-ReportEnvironment $prior} }
function Invoke-Promotion([string]$Workspace,[string]$ReportPath,[string]$Distribution=$RepoRoot,[switch]$AuthorizeCanary) { $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',$script:promotionPath,'-RepoRoot',$Distribution,'-WorkspaceRoot',$Workspace,'-ReportPath',$ReportPath);if($AuthorizeCanary){$arguments+='-AuthorizeCanary'};$output=@(& $script:powerShell @arguments 2>&1|ForEach-Object{[string]$_});return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output-join"`n"} }
function Invoke-Generator([string[]]$Arguments) { $output=@(& $script:powerShell -NoLogo -NoProfile -NonInteractive -File $script:generatorPath -RepoRoot $RepoRoot @Arguments 2>&1|ForEach-Object{[string]$_});return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output-join"`n"} }
function Test-PromotionPathRejected($Module,[string]$Root,[string]$Workspace,[string]$Report,[string[]]$Protected=@()) { try{$null=& $Module {param($Repo,$Work,$Input,$Roots)Resolve-HarnessRolloutPromotionPaths -RepoRoot $Repo -WorkspaceRoot $Work -ReportPath $Input -ProtectedRoots $Roots} $Root $Workspace $Report $Protected;return $false}catch{return $true} }
function New-V2TaskDocument([string]$TaskId) { $now=[DateTimeOffset]::UtcNow.ToString('o');return [ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='ready';identity='existing';intent='write';requirement_state='clear';execution_profile='direct';persistence='ephemeral';policies=[ordered]@{plan_required=$false;approval_required=$false;rollback_required=$false;independent_review_required=$false;verification_required=$true};created_at=$now;updated_at=$now} }

$protocolPath=Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1'
$script:generatorPath=Join-Path $RepoRoot 'scripts\generate-v2-rollout-report.ps1'
$script:promotionPath=Join-Path $RepoRoot 'scripts\promote-v2-rollout-report.ps1'
$script:powerShell=(Get-Process -Id $PID).Path
$repoBefore=@(& git -C $RepoRoot status --porcelain --untracked-files=all)
$trustedTempRoot=[Environment]::GetEnvironmentVariable('DEV_HARNESS_VALIDATION_TEMP_ROOT',[EnvironmentVariableTarget]::Process)
if([string]::IsNullOrWhiteSpace($trustedTempRoot)){
    if($RepoRoot.Equals('D:\data\dev-harness-next',[StringComparison]::OrdinalIgnoreCase)){$trustedTempRoot='D:\data\dev-harness-validation-temp'}
    elseif(-not[string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){$trustedTempRoot=$env:RUNNER_TEMP}
    else{throw 'DEV_HARNESS_VALIDATION_TEMP_ROOT is required outside the trusted development workspace'}
}
$trustedTempRoot=(Resolve-Path -LiteralPath $trustedTempRoot -ErrorAction Stop).Path
$temp=Join-Path $trustedTempRoot ('thin-v2-dp02a-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $temp 'workspace'
$oldGitDir=[Environment]::GetEnvironmentVariable('GIT_DIR',[EnvironmentVariableTarget]::Process)
$oldGitWorkTree=[Environment]::GetEnvironmentVariable('GIT_WORK_TREE',[EnvironmentVariableTarget]::Process)
try {
    [void][IO.Directory]::CreateDirectory($workspace)
    $shadowRepo=Join-Path $temp 'qualification-git';$null=@(& git init --quiet -- $shadowRepo 2>&1);if($LASTEXITCODE-ne0){throw 'shadow Git init failed'}
    $env:GIT_DIR=Join-Path $shadowRepo '.git';$env:GIT_WORK_TREE=$RepoRoot
    $null=@(& git -C $RepoRoot add -A -- 2>&1);if($LASTEXITCODE-ne0){throw 'shadow Git add failed'}
    $null=@(& git -C $RepoRoot -c user.name='Rollout Test' -c user.email='rollout@test.invalid' commit --quiet -m qualification-snapshot 2>&1);if($LASTEXITCODE-ne0){throw 'shadow Git commit failed'}

    foreach($file in @($protocolPath,$script:generatorPath,$script:promotionPath,$PSCommandPath)){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq0) "$(Split-Path -Leaf $file) parses" "$(Split-Path -Leaf $file) parse failed"}
    foreach($schema in @('rollout-eligibility-v2.schema.json','rollout-evidence-set.schema.json','rollout-canary-authorization.schema.json')){try{$null=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "schemas/$schema")|ConvertFrom-Json -Depth 100;Check $true "$schema parses" ''}catch{Check $false '' "$schema parse failed"}}
    $script:protocolModule=Import-Module $protocolPath -Force -PassThru
    $evidenceModule=Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru
    $script:atomicModule=Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Force -PassThru
    $exports=@($script:protocolModule.ExportedFunctions.Keys)
    Check (@(Compare-Object @($exports|Sort-Object) @('Get-HarnessProtocolResolution','Get-HarnessWorkspaceProtocolConfig','Set-HarnessWorkspaceProtocolConfig')).Count-eq0) 'Protocol keeps rollout internals private' 'Protocol export boundary changed'
    $contracts=& $script:protocolModule {Get-HarnessRolloutV2GateContracts};$inputContracts=& $script:protocolModule {Get-HarnessRolloutV2GateContracts -InputOnly};$hostBinding=& $script:protocolModule {Get-HarnessRolloutV2ExpectedHost}
    Check ($contracts.Count-eq19-and$inputContracts.Count-eq18-and-not$inputContracts.Contains('DP-G12-ROLLOUT-ELIGIBILITY-REPORT')) 'v2 contract covers all 19 blocking Gates and computes G12 from the envelope' 'v2 Gate coverage or G12 boundary is wrong'
    Check ($hostBinding.observed_version-ceq'0.144.4'-and$hostBinding.hook_contract-ceq'codex-0.144.4-environment-shell-hook/v1'-and$hostBinding.invocation_telemetry_contract-ceq'codex-invocation-telemetry/v2'-and$hostBinding.request_send_contract-ceq'codex-0.144.4-successful-websocket-send/v2') 'v2 host binding pins exact versioned Hook and telemetry contracts' 'v2 host binding is incomplete'
    $promotionSource=Get-Content -Raw -LiteralPath $script:promotionPath -Encoding utf8;$rolloutEvidenceSource=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Encoding utf8;$atomicSource=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Encoding utf8
    Check ($promotionSource-match'workspace_identity'-and$promotionSource-match'authorization_target'-and$promotionSource-match'publishedPaths'-and$rolloutEvidenceSource-match'Assert-ReleaseSingleLinkFile -Path \$source'-and$rolloutEvidenceSource-match'Assert-ReleaseSingleDataStreamFile -Path \$source'-and$rolloutEvidenceSource-match'authorization-target'-and$atomicSource-match'function Write-HarnessAtomicBytes'-and$atomicSource-notmatch'\[System\.IO\.File\]::Copy') 'Promotion retains physical mutex, path revalidation, hardlink/ADS guards, and validated-byte atomic writes' 'Promotion security or atomic publication boundary regressed'

    $missing=Resolve-ProtocolCanonical $workspace
    Check ($missing.selected_protocol-ceq'v1'-and$missing.rollout_eligibility.status-ceq'missing') 'missing report fails closed to v1' 'missing report selected v2'
    $v1=New-V1Report;$v1Path=Write-WorkspaceReport $workspace 'historical-v1' $v1;$v1Resolution=Resolve-Protocol $workspace $v1Path
    Check ($v1Resolution.selected_protocol-ceq'v1'-and$v1Resolution.rollout_eligibility.status-ceq'historical'-and$v1Resolution.rollout_eligibility.report_eligible-and$v1Resolution.reason-ceq'rollout-v1-historical-diagnostic-only') 'all-pass v1 remains readable but cannot authorize auto v2' 'v1 report still authorized or lost historical diagnosis'
    $v1Failed=New-V1Report fail;$v1FailedPath=Write-WorkspaceReport $workspace 'historical-v1-failed' $v1Failed;$v1FailedResolution=Resolve-Protocol $workspace $v1FailedPath
    Check ($v1FailedResolution.selected_protocol-ceq'v1'-and$v1FailedResolution.reason-ceq'rollout-v1-historical-gate-behavior-fail') 'v1 failing Gate reason remains diagnostic' 'v1 failing Gate diagnosis drifted'

    $final=New-V2Report final-default;$finalPath=Write-WorkspaceReport $workspace 'final' $final;$finalResolution=Resolve-Protocol $workspace $finalPath
    Check ($final.gates.Count-eq19-and$final.eligible-and$finalResolution.selected_protocol-ceq'v2'-and$finalResolution.rollout_eligibility.status-ceq'pass'-and$finalResolution.rollout_eligibility.phase-ceq'final-default') 'valid final-default report authorizes new auto v2' 'valid final-default report did not authorize v2'
    $candidate=New-V2Report canary-candidate;$candidatePath=Write-WorkspaceReport $workspace 'candidate' $candidate;$candidateResolution=Resolve-Protocol $workspace $candidatePath
    $candidatePost=@(@('DP-G13-PROMOTION-AUTO-PROBE','DP-G15-CANARY','DP-G16-STABLE-DECISION')|Where-Object{[string]$candidate.gates[$_].status-cne'not_run'})
    Check (-not$candidate.eligible-and$candidatePost.Count-eq0-and$candidateResolution.selected_protocol-ceq'v1'-and$candidateResolution.rollout_eligibility.status-ceq'unauthorized'-and$candidateResolution.reason-ceq'rollout-canary-authorization-missing') 'candidate is machine-distinct and needs separate Workspace authorization' 'candidate bypassed phase or authorization rules'

    $badCandidateSet=New-EvidenceSet canary-candidate;$badCandidateSet.gates['DP-G13-PROMOTION-AUTO-PROBE'].status='pass';$badCandidateRejected=$false;try{$null=& $script:protocolModule {param($Root,$Set)New-HarnessRolloutV2ReportDocument -RepoRoot $Root -EvidenceSet $Set} $RepoRoot $badCandidateSet}catch{$badCandidateRejected=$_.Exception.Message-match'phase-gate'}
    $badFinalSet=New-EvidenceSet final-default;$badFinalSet.gates['DP-G15-CANARY'].status='unavailable';$badFinalRejected=$false;try{$null=& $script:protocolModule {param($Root,$Set)New-HarnessRolloutV2ReportDocument -RepoRoot $Root -EvidenceSet $Set} $RepoRoot $badFinalSet}catch{$badFinalRejected=$_.Exception.Message-match'phase-gate'}
    Check ($badCandidateRejected-and$badFinalRejected) 'builder rejects candidate post-Gate pass and incomplete final report' 'phase builder accepted contradictory Gate states'
    foreach($status in @('fail','blocked','unavailable','simulated','not_run','pending','skipped','manual')){$set=New-EvidenceSet final-default;$set.gates['DP-G03-INSTALLED-DESKTOP-HOST-3X3'].status=$status;$rejected=$false;try{$null=& $script:protocolModule {param($Root,$Value)New-HarnessRolloutV2ReportDocument -RepoRoot $Root -EvidenceSet $Value} $RepoRoot $set}catch{$rejected=$true};Check $rejected "final rejects $status blocking Gate" "final accepted $status blocking Gate"}

    $driftCases=@(
        [pscustomobject]@{Name='host-version';Mutate={param($d)$d.host.observed_version='0.144.5'};Reason='invalid-document|host-binding'},
        [pscustomobject]@{Name='evidence-contract';Mutate={param($d)$d.gates['DP-G01-MODEL40'].evidence_contract='harness-model-eval-report/v1'};Reason='evidence-contract'},
        [pscustomobject]@{Name='evidence-revision';Mutate={param($d)$d.gates['DP-G02-COGNITIVE-HOST-3X3'].source_revision='0'*40};Reason='evidence-revision'}
    )
    foreach($case in $driftCases){$document=Copy-Document $final;& $case.Mutate $document;Set-ReportDigest $document;$path=Write-WorkspaceReport $workspace $case.Name $document;$result=Resolve-Protocol $workspace $path;Check ($result.selected_protocol-ceq'v1'-and$result.reason-match$case.Reason) "$($case.Name) drift fails closed" "$($case.Name) drift selected v2"}
    $staleRevision=Copy-Document $final;$staleRevision.source_revision='0'*40;foreach($gate in $staleRevision.gates.Values){$gate.source_revision=$staleRevision.source_revision};Set-ReportDigest $staleRevision;$staleRevisionResult=Resolve-Protocol $workspace (Write-WorkspaceReport $workspace 'stale-revision' $staleRevision)
    Check ($staleRevisionResult.selected_protocol-ceq'v1'-and$staleRevisionResult.reason-ceq'rollout-report-stale-revision') 'stale report revision fails closed' 'stale report revision selected v2'
    $staleSource=Copy-Document $final;$staleSource.source_digest='sha256:'+('4'*64);Set-ReportDigest $staleSource;$staleSourceResult=Resolve-Protocol $workspace (Write-WorkspaceReport $workspace 'stale-source' $staleSource)
    Check ($staleSourceResult.selected_protocol-ceq'v1'-and$staleSourceResult.reason-ceq'rollout-report-stale-source') 'stale source digest fails closed' 'stale source digest selected v2'
    $staleGenerator=Copy-Document $final;$staleGenerator.generator_digest='sha256:'+('5'*64);Set-ReportDigest $staleGenerator;$staleGeneratorResult=Resolve-Protocol $workspace (Write-WorkspaceReport $workspace 'stale-generator' $staleGenerator)
    Check ($staleGeneratorResult.selected_protocol-ceq'v1'-and$staleGeneratorResult.reason-ceq'rollout-report-stale-generator') 'stale Generator digest fails closed' 'stale Generator digest selected v2'
    $tampered=Copy-Document $final;$tampered.gates['DP-G01-MODEL40'].evidence_digest='sha256:'+('6'*64);$tamperedResult=Resolve-Protocol $workspace (Write-WorkspaceReport $workspace 'tampered-digest' $tampered)
    Check ($tamperedResult.selected_protocol-ceq'v1'-and$tamperedResult.reason-ceq'rollout-report-digest-mismatch') 'tampered report payload fails digest validation' 'tampered report selected v2'
    $badEnvelope=Copy-Document $final;$badEnvelope.gates['DP-G12-ROLLOUT-ELIGIBILITY-REPORT'].evidence_digest='sha256:'+('7'*64);Set-ReportDigest $badEnvelope;$badEnvelopeResult=Resolve-Protocol $workspace (Write-WorkspaceReport $workspace 'bad-envelope' $badEnvelope)
    Check ($badEnvelopeResult.selected_protocol-ceq'v1'-and$badEnvelopeResult.reason-ceq'rollout-report-envelope-schema-digest') 'G12 cannot replace the current envelope Schema digest' 'G12 accepted a caller-controlled envelope digest'
    $missingGate=Copy-Document $final;$missingGate.gates.Remove('DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE');Set-ReportDigest $missingGate;$result=Resolve-Protocol $workspace (Write-WorkspaceReport $workspace 'missing-gate' $missingGate);Check ($result.selected_protocol-ceq'v1') 'partial Gate set fails closed' 'partial Gate set selected v2'
    $unknown=Copy-Document $final;$unknown.schema_version='rollout-eligibility/v99';$result=Resolve-Protocol $workspace (Write-WorkspaceReport $workspace 'unknown-schema' $unknown);Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-invalid-schema') 'unknown rollout schema fails closed' 'unknown rollout schema selected v2'
    $extra=Copy-Document $final;$extra['authorization_bypass']=$true;$result=Resolve-Protocol $workspace (Write-WorkspaceReport $workspace 'extra-key' $extra);Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-invalid-document') 'unknown report field fails closed' 'unknown report field selected v2'

    $strictJson=$final|ConvertTo-Json -Depth 100 -Compress;$strictCases=[ordered]@{duplicate=($strictJson-replace'^\{','{"schema_version":"rollout-eligibility/v2",');comment=('/*x*/'+$strictJson);trailing=($strictJson.Substring(0,$strictJson.Length-1)+',}')}
    foreach($case in $strictCases.GetEnumerator()){$path=Join-Path $workspace "rollout/strict-$($case.Key).json";[IO.File]::WriteAllText($path,[string]$case.Value,[Text.UTF8Encoding]::new($false));$result=Resolve-Protocol $workspace "rollout/strict-$($case.Key).json";Check ($result.selected_protocol-ceq'v1'-and$result.reason-ceq'rollout-report-invalid-json') "strict JSON rejects $($case.Key)" "strict JSON accepted $($case.Key)"}
    $bomPath=Join-Path $workspace 'rollout/strict-bom.json';$bom=[Text.UTF8Encoding]::new($true).GetPreamble()+[Text.UTF8Encoding]::new($false).GetBytes($strictJson);[IO.File]::WriteAllBytes($bomPath,$bom);$bomResult=Resolve-Protocol $workspace 'rollout/strict-bom.json';Check ($bomResult.selected_protocol-ceq'v1'-and$bomResult.reason-ceq'rollout-report-invalid-json') 'strict JSON rejects UTF-8 BOM' 'strict JSON accepted UTF-8 BOM'

    $deliveryRoot=Join-Path $temp 'release-input';[void][IO.Directory]::CreateDirectory($deliveryRoot)
    $candidateSet=New-EvidenceSet canary-candidate;$candidateSetPath=Join-Path $deliveryRoot 'candidate-set.json';Write-Json $candidateSetPath $candidateSet;$candidateOutput=Join-Path $deliveryRoot 'candidate-output.json';$generatedCandidate=Invoke-Generator @('-GateEvidencePath',$candidateSetPath,'-OutputPath',$candidateOutput)
    $generatedCandidateDocument=if(Test-Path $candidateOutput){Get-Content -Raw -LiteralPath $candidateOutput|ConvertFrom-Json -AsHashtable -Depth 100}else{$null}
    Check ($generatedCandidate.ExitCode-eq0-and$generatedCandidateDocument.phase-ceq'canary-candidate'-and-not$generatedCandidateDocument.eligible) 'Generator emits a valid non-eligible candidate from strict evidence set' ("candidate Generator failed: "+$generatedCandidate.Output)
    $finalSet=New-EvidenceSet final-default;$finalSetPath=Join-Path $deliveryRoot 'final-set.json';Write-Json $finalSetPath $finalSet;$finalOutput=Join-Path $deliveryRoot 'final-output.json';$generatedFinal=Invoke-Generator @('-GateEvidencePath',$finalSetPath,'-OutputPath',$finalOutput,'-RequireEligible')
    Check ($generatedFinal.ExitCode-eq0-and(Test-Path $finalOutput)) 'Generator emits eligible final only from all-pass evidence' ("final Generator failed: "+$generatedFinal.Output)
    $candidateRequiredOutput=Join-Path $deliveryRoot 'candidate-required.json';$candidateRequired=Invoke-Generator @('-GateEvidencePath',$candidateSetPath,'-OutputPath',$candidateRequiredOutput,'-RequireEligible')
    Check ($candidateRequired.ExitCode-eq3-and(Test-Path $candidateRequiredOutput)) 'RequireEligible distinguishes candidate from final without discarding candidate artifact' 'RequireEligible did not return candidate exit 3'
    $legacyGenerator=Invoke-Generator @('-ModelEvalReportPath','missing-model.json','-HostBenchmarkReportPath','missing-host.json')
    Check ($legacyGenerator.ExitCode-ne0-and$legacyGenerator.Output-match'rollout-v1-evidence-inputs-are-historical-only') 'Generator rejects the old two-report v1 path' 'Generator accepted old v1 inputs'
    $missingGenerator=Invoke-Generator @();Check ($missingGenerator.ExitCode-ne0-and$missingGenerator.Output-match'rollout-evidence-set-required') 'Generator fails closed without an evidence set' 'Generator accepted a missing evidence set'
    $driftSet=Copy-Document $finalSet;$driftSet.host.observed_version='0.144.5';$driftSetPath=Join-Path $deliveryRoot 'drift-set.json';Write-Json $driftSetPath $driftSet;$driftGenerator=Invoke-Generator @('-GateEvidencePath',$driftSetPath)
    Check ($driftGenerator.ExitCode-ne0) 'Generator rejects Host version drift' 'Generator accepted Host version drift'
    $contractDriftSet=Copy-Document $finalSet;$contractDriftSet.gates['DP-G01-MODEL40'].evidence_contract='harness-model-eval-report/v1';$contractDriftPath=Join-Path $deliveryRoot 'contract-drift-set.json';Write-Json $contractDriftPath $contractDriftSet;$contractDriftGenerator=Invoke-Generator @('-GateEvidencePath',$contractDriftPath)
    Check ($contractDriftGenerator.ExitCode-ne0) 'Generator rejects evidence Contract drift' 'Generator accepted evidence Contract drift'
    $unknownSet=Copy-Document $finalSet;$unknownSet.schema_version='rollout-evidence-set/v99';$unknownSetPath=Join-Path $deliveryRoot 'unknown-set.json';Write-Json $unknownSetPath $unknownSet;$unknownSetGenerator=Invoke-Generator @('-GateEvidencePath',$unknownSetPath)
    Check ($unknownSetGenerator.ExitCode-ne0) 'Generator rejects an unknown evidence-set Schema' 'Generator accepted an unknown evidence-set Schema'
    $partialSet=Copy-Document $finalSet;$partialSet.gates.Remove('DP-G20-FULL-LIFECYCLE');$partialSetPath=Join-Path $deliveryRoot 'partial-set.json';Write-Json $partialSetPath $partialSet;$partialSetGenerator=Invoke-Generator @('-GateEvidencePath',$partialSetPath)
    Check ($partialSetGenerator.ExitCode-ne0) 'Generator rejects a partial evidence set' 'Generator accepted a partial evidence set'
    $duplicateSetJson=$finalSet|ConvertTo-Json -Depth 100 -Compress;$duplicateSetJson=$duplicateSetJson-replace'^\{','{"schema_version":"rollout-evidence-set/v1",';$duplicateSetPath=Join-Path $deliveryRoot 'duplicate-set.json';[IO.File]::WriteAllText($duplicateSetPath,$duplicateSetJson,[Text.UTF8Encoding]::new($false));$duplicateSetGenerator=Invoke-Generator @('-GateEvidencePath',$duplicateSetPath)
    Check ($duplicateSetGenerator.ExitCode-ne0-and$duplicateSetGenerator.Output-match'rollout-evidence-set-invalid-json') 'Generator strict parser rejects duplicate evidence-set keys' 'Generator accepted duplicate evidence-set keys'
    $oversizedInput=Join-Path $deliveryRoot 'oversized-set.json';[IO.File]::WriteAllBytes($oversizedInput,[byte[]]::new(4MB+1));$oversizedGenerator=Invoke-Generator @('-GateEvidencePath',$oversizedInput)
    Check ($oversizedGenerator.ExitCode-ne0-and$oversizedGenerator.Output-match'rollout-evidence-set-too-large') 'Generator rejects oversized evidence input' 'Generator consumed oversized evidence input'

    $v1Delivery=Join-Path $deliveryRoot 'v1.json';Write-Json $v1Delivery $v1;$v1Promotion=Invoke-Promotion $workspace $v1Delivery
    Check ($v1Promotion.ExitCode-eq2-and$v1Promotion.Output-match'v1-historical-only') 'Promotion rejects a valid v1 report as historical-only' 'Promotion accepted v1 as Canonical basis'
    $finalDelivery=Join-Path $deliveryRoot 'final.json';[IO.File]::WriteAllText($finalDelivery,(($final|ConvertTo-Json -Depth 100)+"`n"),[Text.UTF8Encoding]::new($false));$finalBytes=[IO.File]::ReadAllBytes($finalDelivery)
    $workspaceInput=Join-Path $workspace 'input.json';[IO.File]::WriteAllText($workspaceInput,'{}',[Text.UTF8Encoding]::new($false));Check (Test-PromotionPathRejected $evidenceModule $RepoRoot $workspace $workspaceInput) 'Promotion rejects workspace-contained input' 'Promotion accepted workspace-contained input'
    Check (Test-PromotionPathRejected $evidenceModule $RepoRoot $workspace $protocolPath) 'Promotion rejects distribution-contained input' 'Promotion accepted distribution-contained input'
    $credentialRoot=Join-Path $temp 'credential-home';[void][IO.Directory]::CreateDirectory($credentialRoot);$credentialInput=Join-Path $credentialRoot 'report.json';[IO.File]::WriteAllText($credentialInput,'{}',[Text.UTF8Encoding]::new($false));Check (Test-PromotionPathRejected $evidenceModule $RepoRoot $workspace $credentialInput @($credentialRoot)) 'Promotion retains credential-root boundary' 'Promotion accepted credential-root input'
    $normalPaths=& $evidenceModule {param($Root,$Work,$Report)Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $Report} $RepoRoot $workspace $finalDelivery;$slashPaths=& $evidenceModule {param($Root,$Work,$Report)Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $Report} $RepoRoot ($workspace+[IO.Path]::DirectorySeparatorChar) $finalDelivery
    Check (-not[string]::IsNullOrWhiteSpace([string]$normalPaths.workspace_identity)-and[string]$normalPaths.workspace_identity-ceq[string]$slashPaths.workspace_identity) 'equivalent Workspace spellings share one physical Promotion identity' 'equivalent Workspace spellings split Promotion identity'
    $aliasTarget=Join-Path $temp 'alias-target';[void][IO.Directory]::CreateDirectory($aliasTarget);$aliasInput=Join-Path $aliasTarget 'report.json';[IO.File]::WriteAllText($aliasInput,'{}',[Text.UTF8Encoding]::new($false));$inputAlias=Join-Path $temp 'input-alias';New-Item -ItemType Junction -Path $inputAlias -Target $aliasTarget|Out-Null
    Check (Test-PromotionPathRejected $evidenceModule $RepoRoot $workspace (Join-Path $inputAlias 'report.json')) 'Promotion rejects a reparse alias in the report path' 'Promotion accepted a reparse report alias'
    $workspaceAlias=Join-Path $temp 'workspace-alias';New-Item -ItemType Junction -Path $workspaceAlias -Target $workspace|Out-Null;Check (Test-PromotionPathRejected $evidenceModule $RepoRoot $workspaceAlias $finalDelivery) 'Promotion rejects a reparse Workspace alias' 'Promotion accepted a reparse Workspace alias'
    $hardlinkSource=Join-Path $deliveryRoot 'hardlink-source.json';[IO.File]::WriteAllText($hardlinkSource,'{}',[Text.UTF8Encoding]::new($false));$hardlinkAlias=Join-Path $deliveryRoot 'hardlink-alias.json';$null=@(& fsutil.exe hardlink create $hardlinkAlias $hardlinkSource 2>&1);$hardlinkCreated=$LASTEXITCODE-eq0
    Check ($hardlinkCreated-and(Test-PromotionPathRejected $evidenceModule $RepoRoot $workspace $hardlinkSource)) 'Promotion rejects multi-link report input' 'Promotion accepted multi-link report input or fixture creation failed'
    $adsInput=Join-Path $deliveryRoot 'ads-input.json';[IO.File]::WriteAllText($adsInput,'{}',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText(($adsInput+':extra'),'x',[Text.UTF8Encoding]::new($false));Check (Test-PromotionPathRejected $evidenceModule $RepoRoot $workspace $adsInput) 'Promotion rejects alternate data streams on report input' 'Promotion accepted alternate-stream report input'
    $promotion=Invoke-Promotion $workspace $finalDelivery;$canonicalPath=Join-Path $workspace '.assistant\runtime\rollout\v2-eligibility.json'
    Check ($promotion.ExitCode-eq0-and(Test-ExactBytes $finalBytes ([IO.File]::ReadAllBytes($canonicalPath)))-and(Resolve-ProtocolCanonical $workspace).rollout_eligibility.status-ceq'pass') 'Final Promotion preserves exact report bytes and round-trips resolver' ("final Promotion failed: "+$promotion.Output)
    $canonicalBeforeRejection=[IO.File]::ReadAllBytes($canonicalPath);$finalWithCanarySwitch=Invoke-Promotion $workspace $finalDelivery -AuthorizeCanary;Check ($finalWithCanarySwitch.ExitCode-eq2-and(Test-ExactBytes $canonicalBeforeRejection ([IO.File]::ReadAllBytes($canonicalPath)))) 'Final Promotion rejects the Canary authorization switch without changing Canonical bytes' 'Final accepted Canary authorization or changed Canonical bytes'
    $tamperedPromotion=Copy-Document $final;$tamperedPromotion.report_digest='sha256:'+('f'*64);$tamperedPromotionPath=Join-Path $deliveryRoot 'tampered-report.json';Write-Json $tamperedPromotionPath $tamperedPromotion;$tamperedPromotionResult=Invoke-Promotion $workspace $tamperedPromotionPath;Check ($tamperedPromotionResult.ExitCode-eq2-and(Test-ExactBytes $canonicalBeforeRejection ([IO.File]::ReadAllBytes($canonicalPath)))) 'Promotion rejects a tampered report without changing Canonical bytes' 'Promotion accepted tampered report or changed Canonical bytes'
    $oversizedReportPath='rollout/oversized.json';$oversizedBytes=[byte[]]::new(4MB+1);[IO.File]::WriteAllBytes((Join-Path $workspace $oversizedReportPath),$oversizedBytes);$oversizedResolution=Resolve-Protocol $workspace $oversizedReportPath;Check ($oversizedResolution.selected_protocol-ceq'v1'-and$oversizedResolution.reason-ceq'rollout-report-too-large') 'Resolver rejects oversized report input' 'Resolver accepted oversized report input'
    [IO.File]::WriteAllBytes($canonicalPath,$oversizedBytes);$oversizedTargetPromotion=Invoke-Promotion $workspace $finalDelivery;Check ($oversizedTargetPromotion.ExitCode-eq2-and$oversizedTargetPromotion.Output-match'report-target-too-large'-and(Get-Item -LiteralPath $canonicalPath).Length-eq$oversizedBytes.Length) 'Promotion rejects an oversized Canonical preimage unchanged' 'Promotion consumed or changed oversized Canonical preimage';[IO.File]::WriteAllBytes($canonicalPath,$canonicalBeforeRejection)

    $atomicWorkspace=Join-Path $temp 'atomic-workspace';[void][IO.Directory]::CreateDirectory($atomicWorkspace);$atomicTarget=Join-Path $atomicWorkspace 'state\target.json';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $atomicTarget));[IO.File]::WriteAllText($atomicTarget,'A',[Text.UTF8Encoding]::new($false));$digestA='sha256:'+(Get-FileHash -LiteralPath $atomicTarget -Algorithm SHA256).Hash.ToLowerInvariant();[IO.File]::WriteAllText($atomicTarget,'B',[Text.UTF8Encoding]::new($false));$digestB='sha256:'+(Get-FileHash -LiteralPath $atomicTarget -Algorithm SHA256).Hash.ToLowerInvariant();$sourceDigest='sha256:'+(Get-FileHash -LiteralPath $finalDelivery -Algorithm SHA256).Hash.ToLowerInvariant();$casRejected=$false
    try{& $script:atomicModule {param($Root,$SourceBytes,$ExpectedSource,$ExpectedTarget)Write-HarnessAtomicBytes -WorkspaceRoot $Root -SourceBytes $SourceBytes -Path 'state/target.json' -ExpectedSourceDigest $ExpectedSource -ExpectedCurrentDigest $ExpectedTarget} $atomicWorkspace $finalBytes $sourceDigest $digestA|Out-Null}catch{$casRejected=$true};Check ($casRejected-and[IO.File]::ReadAllText($atomicTarget)-ceq'B') 'atomic publish rejects stale target CAS and preserves competing bytes' 'stale target CAS overwrote competing bytes'
    $wrongSourceRejected=$false;try{& $script:atomicModule {param($Root,$SourceBytes,$Wrong)Write-HarnessAtomicBytes -WorkspaceRoot $Root -SourceBytes $SourceBytes -Path 'new/deep/target.json' -ExpectedSourceDigest $Wrong -ExpectedCurrentDigest missing} $atomicWorkspace $finalBytes $digestB|Out-Null}catch{$wrongSourceRejected=$true};Check ($wrongSourceRejected-and-not(Test-Path (Join-Path $atomicWorkspace 'new'))) 'failed source CAS leaves no created parent or publication debris' 'failed source CAS changed Workspace structure'
    $null=@(& git -C $RepoRoot rm --cached --quiet -- scripts/lib/Harness.RolloutEvidence.psm1 2>&1);if($LASTEXITCODE-ne0){throw 'shadow dirty-source setup failed'}
    $dirtyResolution=Resolve-Protocol $workspace $finalPath;$dirtyGenerator=Invoke-Generator @('-GateEvidencePath',$finalSetPath);$dirtyCanonical=[IO.File]::ReadAllBytes($canonicalPath);$dirtyPromotion=Invoke-Promotion $workspace $finalDelivery
    $dirtyCanonicalPreserved=Test-ExactBytes $dirtyCanonical ([IO.File]::ReadAllBytes($canonicalPath))
    Check ($dirtyResolution.selected_protocol-ceq'v1'-and$dirtyResolution.reason-ceq'rollout-source-dirty'-and$dirtyGenerator.ExitCode-ne0-and$dirtyPromotion.ExitCode-eq2-and$dirtyCanonicalPreserved) 'Resolver, Generator, and Promotion all reject dirty distribution source without changing Canonical bytes' 'a dirty distribution authorized or changed rollout state'
    $null=@(& git -C $RepoRoot add -- scripts/lib/Harness.RolloutEvidence.psm1 2>&1);if($LASTEXITCODE-ne0){throw 'shadow dirty-source restore failed'}

    $canaryWorkspace=Join-Path $temp 'canary-workspace';[void][IO.Directory]::CreateDirectory($canaryWorkspace);$candidateDelivery=Join-Path $deliveryRoot 'candidate.json';Write-Json $candidateDelivery $candidate
    $candidateWithoutAuthorization=Invoke-Promotion $canaryWorkspace $candidateDelivery
    Check ($candidateWithoutAuthorization.ExitCode-eq2-and-not(Test-Path (Join-Path $canaryWorkspace '.assistant'))) 'Candidate Promotion requires explicit authorization switch and writes nothing otherwise' 'Candidate Promotion bypassed explicit authorization'
    $candidatePromotion=Invoke-Promotion $canaryWorkspace $candidateDelivery -AuthorizeCanary;$canaryReportPath=Join-Path $canaryWorkspace '.assistant\runtime\rollout\v2-eligibility.json';$canaryAuthPath=Join-Path $canaryWorkspace '.assistant\runtime\rollout\canary-authorization.json';$canaryResolution=Resolve-ProtocolCanonical $canaryWorkspace
    Check ($candidatePromotion.ExitCode-eq0-and(Test-Path $canaryReportPath)-and(Test-Path $canaryAuthPath)-and$canaryResolution.selected_protocol-ceq'v2'-and$canaryResolution.reason-ceq'authorized-canary-candidate'-and$canaryResolution.rollout_eligibility.status-ceq'canary-authorized'-and-not$canaryResolution.rollout_eligibility.report_eligible) 'Authorized Candidate publishes separate bound artifact and scopes auto v2' ("Candidate Promotion failed: "+$candidatePromotion.Output)
    $copiedWorkspace=Join-Path $temp 'copied-workspace';$copiedRollout=Join-Path $copiedWorkspace '.assistant\runtime\rollout';[void][IO.Directory]::CreateDirectory($copiedRollout);[IO.File]::WriteAllBytes((Join-Path $copiedRollout 'v2-eligibility.json'),[IO.File]::ReadAllBytes($canaryReportPath));[IO.File]::WriteAllBytes((Join-Path $copiedRollout 'canary-authorization.json'),[IO.File]::ReadAllBytes($canaryAuthPath));$copiedResolution=Resolve-ProtocolCanonical $copiedWorkspace
    Check ($copiedResolution.selected_protocol-ceq'v1'-and$copiedResolution.reason-ceq'rollout-canary-authorization-workspace-mismatch') 'copied Candidate authorization cannot escape its physical Workspace' 'copied Candidate authorization selected v2 elsewhere'
    $auth=Get-Content -Raw -LiteralPath $canaryAuthPath|ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String;$auth.authorized_at_utc=[DateTimeOffset]::Parse([string]$auth.authorized_at_utc).AddSeconds(1).ToString('o');Write-Json $canaryAuthPath $auth;$tamperedAuth=Resolve-ProtocolCanonical $canaryWorkspace
    Check ($tamperedAuth.selected_protocol-ceq'v1'-and$tamperedAuth.reason-ceq'rollout-canary-authorization-digest-mismatch') 'tampered Canary authorization fails closed' 'tampered Canary authorization selected v2'
    $repairPromotion=Invoke-Promotion $canaryWorkspace $candidateDelivery -AuthorizeCanary;Check ($repairPromotion.ExitCode-eq0-and(Resolve-ProtocolCanonical $canaryWorkspace).selected_protocol-ceq'v2') 'Promotion atomically repairs matching Candidate authorization' 'Candidate authorization repair failed'
    $candidateReplacement=Copy-Document $candidate;$candidateReplacement.generated_at_utc=[DateTimeOffset]::Parse([string]$candidate.generated_at_utc).AddSeconds(1).ToString('o');Set-ReportDigest $candidateReplacement;Write-Json $canaryReportPath $candidateReplacement;$mismatchedAuthorization=Resolve-ProtocolCanonical $canaryWorkspace
    Check ($mismatchedAuthorization.selected_protocol-ceq'v1'-and$mismatchedAuthorization.reason-ceq'rollout-canary-authorization-report-mismatch') 'authorization bound to another Candidate digest fails closed' 'authorization survived Candidate report drift'
    $candidateReplacementPath=Join-Path $deliveryRoot 'candidate-replacement.json';Write-Json $candidateReplacementPath $candidateReplacement;$replacementPromotion=Invoke-Promotion $canaryWorkspace $candidateReplacementPath -AuthorizeCanary;Check ($replacementPromotion.ExitCode-eq0-and(Resolve-ProtocolCanonical $canaryWorkspace).selected_protocol-ceq'v2') 'Candidate replacement refreshes matching Workspace authorization' 'Candidate replacement did not refresh authorization'
    $extraAuthorization=Get-Content -Raw -LiteralPath $canaryAuthPath|ConvertFrom-Json -AsHashtable -Depth 30 -DateKind String;$extraAuthorization['bypass']=$true;Write-Json $canaryAuthPath $extraAuthorization;$extraAuthorizationResult=Resolve-ProtocolCanonical $canaryWorkspace
    Check ($extraAuthorizationResult.selected_protocol-ceq'v1'-and$extraAuthorizationResult.reason-ceq'rollout-canary-authorization-invalid-document') 'authorization rejects unknown fields' 'authorization accepted an unknown field'
    $null=Invoke-Promotion $canaryWorkspace $candidateReplacementPath -AuthorizeCanary;[IO.File]::WriteAllBytes($canaryAuthPath,[byte[]]::new(64KB+1));$oversizedAuthorization=Resolve-ProtocolCanonical $canaryWorkspace
    Check ($oversizedAuthorization.selected_protocol-ceq'v1'-and$oversizedAuthorization.reason-ceq'rollout-canary-authorization-too-large') 'Resolver rejects oversized Canary authorization' 'Resolver accepted oversized Canary authorization'
    $oversizedAuthorizationPromotion=Invoke-Promotion $canaryWorkspace $candidateReplacementPath -AuthorizeCanary;Check ($oversizedAuthorizationPromotion.ExitCode-eq2-and(Get-Item -LiteralPath $canaryAuthPath).Length-eq(64KB+1)) 'Promotion refuses to clobber oversized Authorization preimage' 'Promotion consumed or changed oversized Authorization preimage'

    $rollbackRepo=Join-Path $temp 'rollback-repo';$activeGitDir=$env:GIT_DIR;$activeGitWorkTree=$env:GIT_WORK_TREE
    try {
        Remove-Item Env:GIT_DIR,Env:GIT_WORK_TREE -ErrorAction SilentlyContinue;$null=@(& git clone --quiet --no-hardlinks -- $shadowRepo $rollbackRepo 2>&1);if($LASTEXITCODE-ne0){throw 'rollback clone failed'}
        $rollbackDir=Join-Path $rollbackRepo '.assistant\runtime\rollout';[void][IO.Directory]::CreateDirectory($rollbackDir);$reportSentinel=[Text.UTF8Encoding]::new($false).GetBytes('{"report":"sentinel"}');$authSentinel=[Text.UTF8Encoding]::new($false).GetBytes('{"authorization":"sentinel"}');[IO.File]::WriteAllBytes((Join-Path $rollbackDir 'v2-eligibility.json'),$reportSentinel);[IO.File]::WriteAllBytes((Join-Path $rollbackDir 'canary-authorization.json'),$authSentinel)
        $null=@(& git -C $rollbackRepo add -f -- '.assistant/runtime/rollout/v2-eligibility.json' '.assistant/runtime/rollout/canary-authorization.json' 2>&1);$null=@(& git -C $rollbackRepo -c user.name='Rollout Test' -c user.email='rollout@test.invalid' commit --quiet -m rollback-preimage 2>&1);if($LASTEXITCODE-ne0){throw 'rollback preimage commit failed'}
        $rollbackCandidate=$null
        for($attempt=1;$attempt-le5-and$null-eq$rollbackCandidate;$attempt++){try{$rollbackCandidate=New-V2Report canary-candidate $rollbackRepo}catch [UnauthorizedAccessException]{if($attempt-eq5){throw};Start-Sleep -Milliseconds 250}}
        $rollbackInput=Join-Path $deliveryRoot 'rollback-candidate.json';Write-Json $rollbackInput $rollbackCandidate;$rollbackResult=Invoke-Promotion $rollbackRepo $rollbackInput $rollbackRepo -AuthorizeCanary;$rollbackStatus=@(& git -C $rollbackRepo status --porcelain --untracked-files=all)
        $reportRestored=Test-ExactBytes $reportSentinel ([IO.File]::ReadAllBytes((Join-Path $rollbackDir 'v2-eligibility.json')))
        $authorizationRestored=Test-ExactBytes $authSentinel ([IO.File]::ReadAllBytes((Join-Path $rollbackDir 'canary-authorization.json')))
        Check ($rollbackResult.ExitCode-eq2-and$rollbackResult.Output-match'rollout-promotion-source-changed'-and$reportRestored-and$authorizationRestored-and$rollbackStatus.Count-eq0) 'post-publish failure restores exact Report and Authorization preimages' ("dual rollback failed: "+$rollbackResult.Output)
    } finally {
        if($null-eq$activeGitDir){Remove-Item Env:GIT_DIR -ErrorAction SilentlyContinue}else{$env:GIT_DIR=$activeGitDir};if($null-eq$activeGitWorkTree){Remove-Item Env:GIT_WORK_TREE -ErrorAction SilentlyContinue}else{$env:GIT_WORK_TREE=$activeGitWorkTree}
    }

    $priorReport=[Environment]::GetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[EnvironmentVariableTarget]::Process)
    try{
        $env:HARNESS_V2_ELIGIBILITY_REPORT=$finalPath;$environmentPreferred=Resolve-ProtocolDefault $workspace
        $invalidPath='rollout/invalid.json';[IO.File]::WriteAllText((Join-Path $workspace $invalidPath),'{',[Text.UTF8Encoding]::new($false));$explicitInvalid=Resolve-Protocol $workspace $invalidPath
        $explicitMissing=Resolve-Protocol $workspace 'rollout/missing-explicit.json';$explicitEmpty=Resolve-Protocol $workspace '';$explicitOversized=Resolve-Protocol $workspace $oversizedReportPath
        Check ($environmentPreferred.selected_protocol-ceq'v2'-and$explicitInvalid.selected_protocol-ceq'v1'-and$explicitMissing.selected_protocol-ceq'v1'-and$explicitEmpty.selected_protocol-ceq'v1'-and$explicitOversized.selected_protocol-ceq'v1') 'explicit/environment discovery priority fails closed without fallback' 'invalid explicit report fell through to environment or Canonical evidence'
        New-Item -Path Env:HARNESS_V2_ELIGIBILITY_REPORT -Value '' -Force|Out-Null;$emptyEnvironment=Resolve-ProtocolDefault $workspace;Check ($emptyEnvironment.selected_protocol-ceq'v1'-and$emptyEnvironment.reason-ceq'rollout-report-missing') 'defined empty environment selection blocks Canonical fallback' 'empty environment selection fell through to Canonical report'
    }finally{Set-ReportEnvironment $priorReport}
    $v1Id='existing-v1';$v1Plan=Join-Path $workspace "docs\tasks\$v1Id\plan.md";[void][IO.Directory]::CreateDirectory((Split-Path -Parent $v1Plan));[IO.File]::WriteAllText($v1Plan,"---`ntask_id: existing-v1`nstage: TEST`ntool: codex`nupdated: 2026-07-24`n---`n",[Text.UTF8Encoding]::new($false));$existingV1=Resolve-Protocol $workspace $finalPath $v1Id
    $v2Id='existing-v2';$v2Path=Join-Path $workspace ".assistant\runtime\tasks\$v2Id\task.json";Write-Json $v2Path (New-V2TaskDocument $v2Id);$existingV2=Resolve-Protocol $workspace $candidatePath $v2Id
    Check ($existingV1.selected_protocol-ceq'v1'-and$existingV1.rollout_eligibility.status-ceq'not-required'-and$existingV2.selected_protocol-ceq'v2'-and$existingV2.rollout_eligibility.status-ceq'not-required') 'artifact-first v1/v2 coexistence still outranks rollout evidence' 'rollout evidence changed an existing task protocol'
    $explicitV1=Resolve-Protocol $workspace $finalPath 'explicit-v1' 'v1';$explicitV2=Resolve-Protocol $workspace '' 'explicit-v2' 'v2';Check ($explicitV1.selected_protocol-ceq'v1'-and$explicitV2.selected_protocol-ceq'v2') 'explicit v1 stop-loss and explicit v2 opt-in remain deterministic' 'explicit protocol selection drifted'

    $oldProtocol=$env:HARNESS_PROTOCOL;$oldReport=[Environment]::GetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[EnvironmentVariableTarget]::Process);$before=@(Get-ChildItem -LiteralPath $workspace -Force -Recurse|ForEach-Object{if($_.PSIsContainer){'D|'+$_.FullName}else{'F|'+$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}}|Sort-Object)
    try{$env:HARNESS_PROTOCOL='auto';Set-ReportEnvironment $null;Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Policy.psm1') -Force;$zero=[ordered]@{user_visible_behavior=0;data_integrity=0;authorization_and_security=0;external_side_effects=0;blast_radius=0;rollback=0;verification_coverage=0};$route=Resolve-HarnessExecutionProfile -RepoRoot $RepoRoot -WorkspaceRoot $workspace -RiskScores $zero}finally{if($null-eq$oldProtocol){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$oldProtocol};Set-ReportEnvironment $oldReport;Remove-Module Harness.Policy -ErrorAction Ignore}
    $after=@(Get-ChildItem -LiteralPath $workspace -Force -Recurse|ForEach-Object{if($_.PSIsContainer){'D|'+$_.FullName}else{'F|'+$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}}|Sort-Object);Check ($route.selected_protocol-ceq'v2'-and$route.profile-ceq'direct'-and@(Compare-Object $before $after).Count-eq0) 'final canonical auto reaches Direct with zero routing writes' 'final canonical route wrote state or selected incorrectly'

    $doc=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'docs\release\compatibility-policy.md') -Encoding utf8
    Check ($doc-match'rollout-eligibility/v2'-and$doc-match'Canary Authorization'-and$doc-match'historical diagnostic') 'compatibility policy documents v2 phases, authorization, and v1 downgrade' 'compatibility policy lacks DP-02A semantics'
} finally {
    if($null-eq$oldGitDir){Remove-Item Env:GIT_DIR -ErrorAction Ignore}else{$env:GIT_DIR=$oldGitDir}
    if($null-eq$oldGitWorkTree){Remove-Item Env:GIT_WORK_TREE -ErrorAction Ignore}else{$env:GIT_WORK_TREE=$oldGitWorkTree}
    Remove-Module Harness.Protocol,Harness.RolloutEvidence -ErrorAction Ignore
    if(Test-Path -LiteralPath $temp){Remove-DirectoryWithRetry -Path $temp}
}
$repoAfter=@(& git -C $RepoRoot status --porcelain --untracked-files=all)
Check (@(Compare-Object $repoBefore $repoAfter).Count-eq0) 'default-flip verifier leaves repository state unchanged' 'default-flip verifier changed repository state'
foreach($item in $script:checks){"[PASS] $item"};foreach($item in $script:failures){"[FAIL] $item"};if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1};"STATUS: PASS ($($script:checks.Count) checks)";exit 0
