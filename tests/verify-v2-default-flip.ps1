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
function Write-Json([string]$Path,[object]$Document) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,($Document|ConvertTo-Json -Depth 100 -Compress),[Text.UTF8Encoding]::new($false)) }
function Test-ExactBytes([byte[]]$Left,[byte[]]$Right) { if($Left.Length-ne$Right.Length){return $false};for($i=0;$i-lt$Left.Length;$i++){if($Left[$i]-ne$Right[$i]){return $false}};return $true }
function Get-Rejection([scriptblock]$Action) { try { $null=& $Action; return '' } catch { return [string]$_.Exception.Message } }
function Set-ContextDigest([Collections.IDictionary]$Document) { $Document.context_digest=& $script:protocolModule {param($Value)Get-HarnessObservedHostContextDigest -Document $Value} $Document }
function Set-ReceiptDigest([Collections.IDictionary]$Document) { $Document.receipt_digest=& $script:protocolModule {param($Value)Get-HarnessRolloutReviewReceiptDigest -Document $Value} $Document }
function Set-ReportDigest([Collections.IDictionary]$Document) { $Document.report_digest=& $script:protocolModule {param($Value)Get-HarnessRolloutReportDigest -Document $Value} $Document }
function Set-AuthorizationDigest([Collections.IDictionary]$Document) { $Document.authorization_digest=& $script:protocolModule {param($Value)Get-HarnessCanaryAuthorizationDigest -Document $Value} $Document }

function Invoke-Generator([string[]]$Arguments) {
    $output=@(& $script:powerShell -NoLogo -NoProfile -NonInteractive -File $script:generatorPath -RepoRoot $RepoRoot @Arguments 2>&1|ForEach-Object{[string]$_})
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output-join"`n"}
}
function Invoke-Promotion([string[]]$Arguments) {
    $output=@(& $script:powerShell -NoLogo -NoProfile -NonInteractive -File $script:promotionPath -RepoRoot $RepoRoot @Arguments 2>&1|ForEach-Object{[string]$_})
    return [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output-join"`n"}
}
function Resolve-Canonical([string]$Workspace,[AllowNull()][Collections.IDictionary]$Context=$null,[string]$TaskId='') {
    $parameters=@{RepoRoot=$RepoRoot;WorkspaceRoot=$Workspace;RequestedProtocol='auto';TaskId=$TaskId}
    if($null-ne$Context){$parameters.ObservedHostContext=$Context}
    return Get-HarnessProtocolResolution @parameters
}
function Resolve-Explicit([string]$Workspace,[AllowEmptyString()][string]$ReportPath,[AllowNull()][Collections.IDictionary]$Context=$null,[string]$Requested='auto',[string]$TaskId='') {
    $parameters=@{RepoRoot=$RepoRoot;WorkspaceRoot=$Workspace;RequestedProtocol=$Requested;TaskId=$TaskId;EligibilityReportPath=$ReportPath}
    if($null-ne$Context){$parameters.ObservedHostContext=$Context}
    return Get-HarnessProtocolResolution @parameters
}
function Resolve-Requested([string]$Workspace,[ValidateSet('v1','v2')][string]$Requested) {
    return Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $Workspace -RequestedProtocol $Requested
}

function New-EvidenceSet([ValidateSet('canary-candidate','final-default')][string]$Phase) {
    $contracts=& $script:protocolModule {Get-HarnessRolloutV2GateContracts -InputOnly}
    $hostBinding=& $script:protocolModule {Get-HarnessRolloutV2ExpectedHost}
    $revision=& $script:protocolModule {param($Root)Get-HarnessRolloutRevision -RepoRoot $Root} $RepoRoot
    $gates=[ordered]@{}
    foreach($name in $contracts.Keys){
        $gates[$name]=[ordered]@{
            status=$(if($Phase-ceq'canary-candidate'-and[string]$name-cin@('DP-G13-PROMOTION-AUTO-PROBE','DP-G15-CANARY','DP-G16-STABLE-DECISION')){'not_run'}else{'pass'})
            evidence_contract=[string]$contracts[$name]
            artifact_path=$script:placeholderArtifactPath
            evidence_digest=$script:placeholderArtifactDigest
            source_revision=$revision
            producer_identity='structural-test-producer'
        }
    }
    return [ordered]@{schema_version='rollout-evidence-set/v1';phase=$Phase;source_revision=$revision;host=$hostBinding;gates=$gates}
}
function New-LegacyEvidenceSet([ValidateSet('canary-candidate','final-default')][string]$Phase) {
    $set=New-EvidenceSet $Phase
    foreach($gate in $set.gates.Values){$gate.Remove('artifact_path');$gate.Remove('producer_identity')}
    return $set
}
function New-ReportBundle([ValidateSet('canary-candidate','final-default')][string]$Phase,[ValidateSet('verified','test-only')][string]$ProvenanceStatus,[string]$Name) {
    $set=New-EvidenceSet $Phase
    $payload=& $script:protocolModule {param($Root,$Value,$Status)New-HarnessRolloutReviewPayloadDocument -RepoRoot $Root -EvidenceSet $Value -ProvenanceStatus $Status} $RepoRoot $set $ProvenanceStatus
    $receipt=& $script:protocolModule {param($Root,$Value)New-HarnessRolloutReviewReceiptDocument -RepoRoot $Root -Payload $Value -ReviewerActorId 'structural-reviewer' -ReviewerContextId 'isolated-structural-review' -ReviewerModel 'gpt-5.6-sol'} $RepoRoot $payload
    $receiptPath=Join-Path $script:deliveryRoot "$Name-review-receipt.json";Write-Json $receiptPath $receipt
    $report=if($ProvenanceStatus-ceq'test-only'){
        & $script:protocolModule {param($Root,$Payload,$Receipt,$Path)New-HarnessRolloutV2ReportDocument -RepoRoot $Root -ReviewPayload $Payload -ReviewReceipt $Receipt -ReviewReceiptArtifactPath $Path -TestOnly} $RepoRoot $payload $receipt $receiptPath
    }else{
        & $script:protocolModule {param($Root,$Payload,$Receipt,$Path)New-HarnessRolloutV2ReportDocument -RepoRoot $Root -ReviewPayload $Payload -ReviewReceipt $Receipt -ReviewReceiptArtifactPath $Path} $RepoRoot $payload $receipt $receiptPath
    }
    $reportPath=Join-Path $script:deliveryRoot "$Name-report.json";Write-Json $reportPath $report
    return [pscustomobject]@{Set=$set;Payload=$payload;Receipt=$receipt;ReceiptPath=$receiptPath;Report=$report;ReportPath=$reportPath}
}
function Assert-AuthorizationReason([Collections.IDictionary]$Report,[Collections.IDictionary]$Context,[Collections.IDictionary]$Authorization,[string]$Workspace,[datetimeoffset]$AsOf) {
    return Get-Rejection {& $script:protocolModule {param($Root,$Work,$Rep,$Ctx,$Auth,$Now)Assert-HarnessCanaryAuthorization -RepoRoot $Root -WorkspaceRoot $Work -Report $Rep -ObservedHostContext $Ctx -Document $Auth -AsOfUtc $Now} $RepoRoot $Workspace $Report $Context $Authorization $AsOf}
}
function Invoke-StructuralTransaction([string]$Workspace,[string]$InputPath,[string]$Phase,[byte[]]$ReportBytes,[byte[]]$AuthorizationBytes,[int]$FaultAfter=0) {
    $reportDocument=[Text.UTF8Encoding]::new($false,$true).GetString($ReportBytes)|ConvertFrom-Json -AsHashtable -Depth 100
    $authorizationDigest=if($AuthorizationBytes.Length-eq0){''}else{[string]([Text.UTF8Encoding]::new($false,$true).GetString($AuthorizationBytes)|ConvertFrom-Json -AsHashtable -Depth 100).authorization_digest}
    return & $script:evidenceModule {
        param($Root,$Work,$ArtifactPath,$Mode,$Report,$ReportDigest,$Authorization,$AuthorizationDigest,$SourceState,$Fault)
        Invoke-HarnessRolloutPublicationTransaction -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $ArtifactPath -Phase $Mode -ReportBytes $Report -ExpectedReportDigest $ReportDigest -AuthorizationBytes $Authorization -ExpectedAuthorizationDigest $AuthorizationDigest -SourceStateStart $SourceState -FaultAfterMutation $Fault -SkipCanonicalResolutionForStructuralTest
    } $RepoRoot $Workspace $InputPath $Phase $ReportBytes ([string]$reportDocument.report_digest) $AuthorizationBytes $authorizationDigest $script:sourceState $FaultAfter
}
function New-CanonicalProtocolModule([string]$CanonicalPath,[string]$Phase,[string]$ReportDigest,[AllowEmptyString()][string]$AuthorizationDigest='') {
    return New-Module -ArgumentList @($CanonicalPath,$Phase,$ReportDigest,$AuthorizationDigest) -ScriptBlock {
        param($ExpectedPath,$ExpectedPhase,$ExpectedReportDigest,$ExpectedAuthorizationDigest)
        function Get-HarnessProtocolResolution {
            [CmdletBinding()]param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$RequestedProtocol,[string]$EligibilityReportPath,[AllowNull()][Collections.IDictionary]$ObservedHostContext)
            $selectedPath=if($PSBoundParameters.ContainsKey('EligibilityReportPath')){$EligibilityReportPath}else{[Environment]::GetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[EnvironmentVariableTarget]::Process)}
            $pathMatches=[string]$selectedPath-ceq[string]$ExpectedPath
            return [ordered]@{selected_protocol='v2';rollout_eligibility=[ordered]@{status=$(if($ExpectedPhase-ceq'canary-candidate'){'canary-authorized'}else{'pass'});phase=$ExpectedPhase;report_digest=$(if($pathMatches){$ExpectedReportDigest}else{'sha256:'+('f'*64)});authorization_digest=$(if($ExpectedPhase-ceq'canary-candidate'){$ExpectedAuthorizationDigest}else{$null})}}
        }
    }
}
function New-V1Gates {
    $digest='sha256:'+('2'*64)
    return [ordered]@{
        behavior=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-model-evals.ps1 -Model gpt-5.6-sol -Reasoning max'}
        v1_compatibility=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-validation.ps1 -Suite all -CheckTimeoutSeconds 360 -VerboseOutput'}
        direct_performance=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-host-benchmark.ps1 -Groups 3 -Trials 3 -Model gpt-5.6-sol -Reasoning max'}
        core_install_rollback=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-isolated-install-smoke.ps1 -Preset core'}
        full_install_rollback=[ordered]@{status='pass';evidence_digest=$digest;command='scripts/run-isolated-install-smoke.ps1 -Preset full'}
    }
}
function New-V2TaskDocument([string]$TaskId){$now=[datetimeoffset]::UtcNow.ToString('o');return [ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='ready';identity='existing';intent='write';requirement_state='clear';execution_profile='direct';persistence='ephemeral';policies=[ordered]@{plan_required=$false;approval_required=$false;rollback_required=$false;independent_review_required=$false;verification_required=$true};created_at=$now;updated_at=$now}}

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
$temp=Join-Path $trustedTempRoot ('thin-v2-dp02a-correction-'+[guid]::NewGuid().ToString('N'))
$script:deliveryRoot=Join-Path $temp 'delivery';[void][IO.Directory]::CreateDirectory($script:deliveryRoot)
$oldGitDir=[Environment]::GetEnvironmentVariable('GIT_DIR',[EnvironmentVariableTarget]::Process)
$oldGitWorkTree=[Environment]::GetEnvironmentVariable('GIT_WORK_TREE',[EnvironmentVariableTarget]::Process)
try {
    $shadowRepo=Join-Path $temp 'qualification-git';$null=@(& git init --quiet -- $shadowRepo 2>&1);if($LASTEXITCODE-ne0){throw 'shadow Git init failed'}
    $env:GIT_DIR=Join-Path $shadowRepo '.git';$env:GIT_WORK_TREE=$RepoRoot
    $null=@(& git -C $RepoRoot add -A -- 2>&1);if($LASTEXITCODE-ne0){throw 'shadow Git add failed'}
    $null=@(& git -C $RepoRoot -c user.name='Rollout Test' -c user.email='rollout@test.invalid' commit --quiet -m qualification-snapshot 2>&1);if($LASTEXITCODE-ne0){throw 'shadow Git commit failed'}

    $protocolPath=Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1'
    $rolloutEvidencePath=Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1'
    foreach($file in @($protocolPath,$rolloutEvidencePath,$script:generatorPath,$script:promotionPath,$PSCommandPath)){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq0) "$(Split-Path -Leaf $file) parses" "$(Split-Path -Leaf $file) parse failed"}
    foreach($schema in @('rollout-eligibility-v2.schema.json','rollout-evidence-set.schema.json','rollout-canary-authorization.schema.json','rollout-observed-host-context.schema.json','rollout-review-payload.schema.json','rollout-review-receipt.schema.json')){try{$null=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "schemas/$schema")|ConvertFrom-Json -Depth 100;Check $true "$schema parses" ''}catch{Check $false '' "$schema parse failed"}}
    $script:protocolModule=Import-Module $protocolPath -Force -PassThru
    $script:evidenceModule=Import-Module $rolloutEvidencePath -Force -PassThru
    $exports=@($script:protocolModule.ExportedFunctions.Keys)
    Check (@(Compare-Object @($exports|Sort-Object) @('Get-HarnessProtocolResolution','Get-HarnessWorkspaceProtocolConfig','Set-HarnessWorkspaceProtocolConfig')).Count-eq0) 'Protocol public export surface remains bounded' 'Protocol public export surface changed'
    Check ((Get-Command Get-HarnessProtocolResolution -Module $script:protocolModule.Name).Parameters.ContainsKey('ObservedHostContext')) 'Resolver accepts caller-supplied Observed Host Context' 'Resolver lacks Observed Host Context input'

    $script:placeholderArtifactPath=Join-Path $script:deliveryRoot 'unwired-artifact.json';[IO.File]::WriteAllText($script:placeholderArtifactPath,'{"not":"release-evidence"}',[Text.UTF8Encoding]::new($false))
    $script:placeholderArtifactDigest='sha256:'+((Get-FileHash -LiteralPath $script:placeholderArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant())
    $script:sourceState=& $script:evidenceModule {param($Root)Get-HarnessReleaseSourceState -RepoRoot $Root} $RepoRoot
    $validContext=& $script:protocolModule {param($Root)New-HarnessObservedHostContextDocument -RepoRoot $Root} $RepoRoot
    $contextPath=Join-Path $script:deliveryRoot 'observed-host.json';Write-Json $contextPath $validContext

    $legacySetPath=Join-Path $script:deliveryRoot 'legacy-self-attested.json';Write-Json $legacySetPath (New-LegacyEvidenceSet final-default)
    $legacyOutput=Join-Path $script:deliveryRoot 'legacy-output.json';$legacyGeneration=Invoke-Generator @('-GateEvidencePath',$legacySetPath,'-OutputPath',$legacyOutput,'-RequireEligible')
    Check ($legacyGeneration.ExitCode-ne0-and$legacyGeneration.Output-match'rollout-evidence-provenance-unverified'-and-not(Test-Path $legacyOutput)) 'bare all-pass Evidence Set cannot create a report' 'bare all-pass Evidence Set still created output'

    $describedSet=New-EvidenceSet final-default;$describedSetPath=Join-Path $script:deliveryRoot 'described-set.json';Write-Json $describedSetPath $describedSet
    $diagnosticPayloadPath=Join-Path $script:deliveryRoot 'diagnostic-review-payload.json';$diagnosticGeneration=Invoke-Generator @('-GateEvidencePath',$describedSetPath,'-CreateReviewPayload','-OutputPath',$diagnosticPayloadPath)
    $diagnosticPayload=Get-Content -LiteralPath $diagnosticPayloadPath -Raw|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    Check ($diagnosticGeneration.ExitCode-eq3-and$diagnosticPayload.schema_version-ceq'rollout-review-payload/v1'-and$diagnosticPayload.provenance_status-ceq'unverified'-and@($diagnosticPayload.gates.Values|Where-Object{$_.status-cne'unavailable'}).Count-eq0) 'unwired Artifacts produce only a non-authorizing Review Payload' ("diagnostic payload boundary failed: "+$diagnosticGeneration.Output)
    $diagnosticReceipt=& $script:protocolModule {param($Root,$Payload)New-HarnessRolloutReviewReceiptDocument -RepoRoot $Root -Payload $Payload -ReviewerActorId 'reviewer' -ReviewerContextId 'context' -ReviewerModel 'gpt-5.6-sol'} $RepoRoot $diagnosticPayload
    $diagnosticReceiptPath=Join-Path $script:deliveryRoot 'diagnostic-review-receipt.json';Write-Json $diagnosticReceiptPath $diagnosticReceipt
    $diagnosticFinalPath=Join-Path $script:deliveryRoot 'diagnostic-final.json';$diagnosticFinalize=Invoke-Generator @('-ReviewPayloadPath',$diagnosticPayloadPath,'-ReviewReceiptPath',$diagnosticReceiptPath,'-OutputPath',$diagnosticFinalPath,'-RequireEligible')
    Check ($diagnosticFinalize.ExitCode-ne0-and$diagnosticFinalize.Output-match'rollout-evidence-provenance-unverified'-and-not(Test-Path $diagnosticFinalPath)) 'Review cannot upgrade unverified provenance into an authorizing report' 'unverified Review Payload became authorizing'
    $missingReceipt=Invoke-Generator @('-ReviewPayloadPath',$diagnosticPayloadPath,'-OutputPath',(Join-Path $script:deliveryRoot 'missing-receipt.json'))
    Check ($missingReceipt.ExitCode-ne0-and$missingReceipt.Output-match'rollout-review-payload-and-receipt-required') 'Finalize requires a real Review Receipt file' 'Finalize accepted missing Review Receipt'

    $testFinal=New-ReportBundle final-default test-only 'test-final'
    $verifiedFinal=New-ReportBundle final-default verified 'verified-final'
    $testCandidate=New-ReportBundle canary-candidate test-only 'test-candidate'
    $verifiedCandidate=New-ReportBundle canary-candidate verified 'verified-candidate'
    $schemaDigest='sha256:'+((Get-FileHash -LiteralPath (Join-Path $RepoRoot 'schemas\rollout-eligibility-v2.schema.json') -Algorithm SHA256).Hash.ToLowerInvariant())
    $g12=$verifiedFinal.Report.gates['DP-G12-ROLLOUT-ELIGIBILITY-REPORT']
    Check ($g12.status-ceq'pass'-and$g12.evidence_contract-ceq'rollout-report-review-receipt/v1'-and$g12.evidence_digest-ceq$verifiedFinal.Receipt.receipt_digest-and$g12.evidence_digest-cne$schemaDigest) 'G12 binds the actual phase-specific Review Receipt digest' 'G12 still binds the schema or wrong receipt'

    $reviewReasonMissing=Get-Rejection {& $script:protocolModule {param($Root,$Payload,$Path)New-HarnessRolloutV2ReportDocument -RepoRoot $Root -ReviewPayload $Payload -ReviewReceipt $null -ReviewReceiptArtifactPath $Path} $RepoRoot $verifiedFinal.Payload $verifiedFinal.ReceiptPath}
    Check (-not[string]::IsNullOrWhiteSpace($reviewReasonMissing)) 'report builder rejects a missing Review Receipt' 'report builder accepted a missing Review Receipt'
    $tamperedReceipt=Copy-Document $verifiedFinal.Receipt;$tamperedReceipt.reviewed_payload_digest='sha256:'+('9'*64);Set-ReceiptDigest $tamperedReceipt
    $payloadMismatch=Get-Rejection {& $script:protocolModule {param($Root,$Receipt,$Payload)Assert-HarnessRolloutReviewReceipt -RepoRoot $Root -Document $Receipt -ExpectedPayloadDigest $Payload.reviewed_payload_digest -ExpectedSourceRevision $Payload.source_revision -ExpectedPhase $Payload.phase} $RepoRoot $tamperedReceipt $verifiedFinal.Payload}
    $phaseReceipt=Copy-Document $verifiedFinal.Receipt;$phaseReceipt.phase='canary-candidate';Set-ReceiptDigest $phaseReceipt
    $phaseMismatch=Get-Rejection {& $script:protocolModule {param($Root,$Receipt,$Payload)Assert-HarnessRolloutReviewReceipt -RepoRoot $Root -Document $Receipt -ExpectedPayloadDigest $Payload.reviewed_payload_digest -ExpectedSourceRevision $Payload.source_revision -ExpectedPhase $Payload.phase} $RepoRoot $phaseReceipt $verifiedFinal.Payload}
    $sourceReceipt=Copy-Document $verifiedFinal.Receipt;$sourceReceipt.source_revision='1'*40;Set-ReceiptDigest $sourceReceipt
    $sourceMismatch=Get-Rejection {& $script:protocolModule {param($Root,$Receipt,$Payload)Assert-HarnessRolloutReviewReceipt -RepoRoot $Root -Document $Receipt -ExpectedPayloadDigest $Payload.reviewed_payload_digest -ExpectedSourceRevision $Payload.source_revision -ExpectedPhase $Payload.phase} $RepoRoot $sourceReceipt $verifiedFinal.Payload}
    $blankReviewer=Copy-Document $verifiedFinal.Receipt;$blankReviewer.reviewer_actor_id=' ';Set-ReceiptDigest $blankReviewer
    $blankReviewerReason=Get-Rejection {& $script:protocolModule {param($Root,$Receipt,$Payload)Assert-HarnessRolloutReviewReceipt -RepoRoot $Root -Document $Receipt -ExpectedPayloadDigest $Payload.reviewed_payload_digest -ExpectedSourceRevision $Payload.source_revision -ExpectedPhase $Payload.phase} $RepoRoot $blankReviewer $verifiedFinal.Payload}
    $findingReceipt=Copy-Document $verifiedFinal.Receipt;$findingReceipt.findings.p2=1;Set-ReceiptDigest $findingReceipt
    $findingReason=Get-Rejection {& $script:protocolModule {param($Root,$Receipt,$Payload)Assert-HarnessRolloutReviewReceipt -RepoRoot $Root -Document $Receipt -ExpectedPayloadDigest $Payload.reviewed_payload_digest -ExpectedSourceRevision $Payload.source_revision -ExpectedPhase $Payload.phase} $RepoRoot $findingReceipt $verifiedFinal.Payload}
    $reusedCandidateReason=Get-Rejection {& $script:protocolModule {param($Root,$Payload,$Receipt,$Path)New-HarnessRolloutV2ReportDocument -RepoRoot $Root -ReviewPayload $Payload -ReviewReceipt $Receipt -ReviewReceiptArtifactPath $Path} $RepoRoot $verifiedFinal.Payload $verifiedCandidate.Receipt $verifiedCandidate.ReceiptPath}
    Check ($payloadMismatch-match'payload-mismatch'-and$phaseMismatch-match'phase-mismatch'-and$sourceMismatch-match'source-mismatch'-and$blankReviewerReason-match'invalid-document'-and$findingReason-match'findings'-and-not[string]::IsNullOrWhiteSpace($reusedCandidateReason)) 'Review Receipt payload, phase, source, reviewer, findings, and cross-phase reuse all fail closed' 'a Review Receipt drift case was accepted'

    $resolverWorkspace=Join-Path $temp 'resolver-workspace';$finalCanonical=Join-Path $resolverWorkspace '.assistant\runtime\rollout\v2-eligibility.json';Write-Json $finalCanonical $testFinal.Report
    $missingContext=Resolve-Canonical $resolverWorkspace
    $driftContext=& $script:protocolModule {param($Root)New-HarnessObservedHostContextDocument -RepoRoot $Root -CliVersion '0.144.5' -ServiceVersion '0.144.5' -SkipSemanticValidation} $RepoRoot
    $wrongContractContext=& $script:protocolModule {param($Root)New-HarnessObservedHostContextDocument -RepoRoot $Root -HookContract 'wrong-hook/v1' -SkipSemanticValidation} $RepoRoot
    $badDigestContext=Copy-Document $validContext;$badDigestContext.context_digest='sha256:'+('f'*64)
    $driftResolution=Resolve-Canonical $resolverWorkspace $driftContext
    $wrongContractResolution=Resolve-Canonical $resolverWorkspace $wrongContractContext
    $badDigestResolution=Resolve-Canonical $resolverWorkspace $badDigestContext
    $validContextResolution=Resolve-Canonical $resolverWorkspace $validContext
    Check ($missingContext.selected_protocol-ceq'v1'-and$missingContext.reason-ceq'rollout-observed-host-context-missing') 'missing actual Host Context falls back to v1' 'Report self-attested Host without actual Context'
    Check ($driftResolution.selected_protocol-ceq'v1'-and$driftResolution.reason-ceq'rollout-observed-host-context-cli-version-mismatch') 'actual Host 0.144.5 falls back to v1' 'Host version drift selected v2'
    Check ($wrongContractResolution.selected_protocol-ceq'v1'-and$wrongContractResolution.reason-ceq'rollout-observed-host-context-hook-contract-mismatch') 'actual Hook contract drift falls back to v1' 'Hook contract drift selected v2'
    Check ($badDigestResolution.selected_protocol-ceq'v1'-and$badDigestResolution.reason-ceq'rollout-observed-host-context-digest-mismatch') 'tampered Host Context falls back to v1' 'tampered Host Context selected v2'
    Check ($validContextResolution.selected_protocol-ceq'v1'-and$validContextResolution.reason-ceq'rollout-evidence-provenance-unverified') 'valid Host cannot upgrade test-only Evidence' 'test-only report selected v2'

    $emptyPromotionWorkspace=Join-Path $temp 'public-promotion-workspace';[void][IO.Directory]::CreateDirectory($emptyPromotionWorkspace)
    $testFinalPromotion=Invoke-Promotion @('-WorkspaceRoot',$emptyPromotionWorkspace,'-ReportPath',$testFinal.ReportPath,'-ObservedHostContextPath',$contextPath,'-ReviewReceiptPath',$testFinal.ReceiptPath)
    Check ($testFinalPromotion.ExitCode-eq2-and$testFinalPromotion.Output-match'rollout-evidence-provenance-unverified'-and-not(Test-Path (Join-Path $emptyPromotionWorkspace '.assistant'))) 'test-only Final cannot be promoted and writes nothing' 'test-only Final was promoted or wrote state'
    $candidateWithoutSwitch=Invoke-Promotion @('-WorkspaceRoot',$emptyPromotionWorkspace,'-ReportPath',$testCandidate.ReportPath)
    $candidateWithoutOwner=Invoke-Promotion @('-WorkspaceRoot',$emptyPromotionWorkspace,'-ReportPath',$testCandidate.ReportPath,'-AuthorizeCanary')
    $candidateWithoutExpiry=Invoke-Promotion @('-WorkspaceRoot',$emptyPromotionWorkspace,'-ReportPath',$testCandidate.ReportPath,'-AuthorizeCanary','-AuthorizedBy','operator')
    $candidateTestOnly=Invoke-Promotion @('-WorkspaceRoot',$emptyPromotionWorkspace,'-ReportPath',$testCandidate.ReportPath,'-AuthorizeCanary','-AuthorizedBy','operator','-DurationHours','1','-ObservedHostContextPath',$contextPath,'-ReviewReceiptPath',$testCandidate.ReceiptPath)
    Check ($candidateWithoutSwitch.ExitCode-eq2-and$candidateWithoutSwitch.Output-match'authorization-required'-and$candidateWithoutOwner.Output-match'authorized-by-required'-and$candidateWithoutExpiry.Output-match'expiry-required'-and$candidateTestOnly.Output-match'provenance-unverified'-and-not(Test-Path (Join-Path $emptyPromotionWorkspace '.assistant'))) 'Candidate requires explicit owner/expiry and test-only Candidate remains zero-write' ("Candidate parameter or test-only boundary failed: switch=[$($candidateWithoutSwitch.Output)] owner=[$($candidateWithoutOwner.Output)] expiry=[$($candidateWithoutExpiry.Output)] test=[$($candidateTestOnly.Output)]")

    $authorizationWorkspace=Join-Path $temp 'authorization-workspace';[void][IO.Directory]::CreateDirectory($authorizationWorkspace)
    $now=[datetimeoffset]::UtcNow
    $authorization=& $script:protocolModule {param($Root,$Work,$Report,$Context,$Issued)New-HarnessCanaryAuthorizationDocument -RepoRoot $Root -WorkspaceRoot $Work -Report $Report -ObservedHostContext $Context -AuthorizedBy 'operator@example.invalid' -IssuedAtUtc $Issued -ExpiresAtUtc $Issued.AddHours(1)} $RepoRoot $authorizationWorkspace $verifiedCandidate.Report $validContext $now
    $validAuthorizationReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $authorization $authorizationWorkspace $now
    Check ([string]::IsNullOrWhiteSpace($validAuthorizationReason)-and-not[string]::IsNullOrWhiteSpace([string]$authorization.authorization_id)-and$authorization.authorized_by-ceq'operator@example.invalid'-and$authorization.new_tasks_only-and$authorization.status-ceq'granted') 'Canary Authorization binds owner, identity, Host, granted status, and new-task scope' ("valid Authorization rejected: $validAuthorizationReason")
    $missingOwner=Copy-Document $authorization;$missingOwner.Remove('authorized_by');$missingOwnerReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $missingOwner $authorizationWorkspace $now
    $missingExpiry=Copy-Document $authorization;$missingExpiry.Remove('expires_at_utc');$missingExpiryReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $missingExpiry $authorizationWorkspace $now
    $badStatus=Copy-Document $authorization;$badStatus.status='revoked';Set-AuthorizationDigest $badStatus;$badStatusReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $badStatus $authorizationWorkspace $now
    $notNew=Copy-Document $authorization;$notNew.new_tasks_only=$false;Set-AuthorizationDigest $notNew;$notNewReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $notNew $authorizationWorkspace $now
    Check ($missingOwnerReason-match'invalid-document'-and$missingExpiryReason-match'invalid-document'-and$badStatusReason-match'invalid-document'-and$notNewReason-match'invalid-document') 'missing owner/expiry, non-granted status, and non-new-task scope are rejected' 'a required Canary Authorization field was optional'
    $expired=Copy-Document $authorization;$expired.issued_at_utc=$now.AddHours(-2).ToString('o');$expired.expires_at_utc=$now.AddHours(-1).ToString('o');Set-AuthorizationDigest $expired;$expiredReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $expired $authorizationWorkspace $now
    $future=Copy-Document $authorization;$future.issued_at_utc=$now.AddMinutes(10).ToString('o');$future.expires_at_utc=$now.AddHours(1).ToString('o');Set-AuthorizationDigest $future;$futureReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $future $authorizationWorkspace $now
    $tooLong=Copy-Document $authorization;$tooLong.issued_at_utc=$now.ToString('o');$tooLong.expires_at_utc=$now.AddDays(8).ToString('o');Set-AuthorizationDigest $tooLong;$tooLongReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $tooLong $authorizationWorkspace $now
    $secondContext=& $script:protocolModule {param($Root,$Observed)New-HarnessObservedHostContextDocument -RepoRoot $Root -ObservedAtUtc $Observed} $RepoRoot $now.AddSeconds(-1)
    $contextMismatchReason=Assert-AuthorizationReason $verifiedCandidate.Report $secondContext $authorization $authorizationWorkspace $now
    $copiedWorkspace=Join-Path $temp 'copied-auth-workspace';[void][IO.Directory]::CreateDirectory($copiedWorkspace);$copiedReason=Assert-AuthorizationReason $verifiedCandidate.Report $validContext $authorization $copiedWorkspace $now
    Check ($expiredReason-match'expired'-and$futureReason-match'future-issued'-and$tooLongReason-match'duration-exceeded'-and$contextMismatchReason-match'host-context-mismatch'-and$copiedReason-match'workspace-mismatch') 'expired, future, over-seven-day, Host-mismatched, and copied Authorizations fail closed' 'a temporal or binding Authorization case was accepted'

    $candidateResolverWorkspace=Join-Path $temp 'candidate-resolver';$candidateCanonical=Join-Path $candidateResolverWorkspace '.assistant\runtime\rollout\v2-canary-candidate.json';$authCanonical=Join-Path $candidateResolverWorkspace '.assistant\runtime\rollout\v2-canary-authorization.json';Write-Json $candidateCanonical $verifiedCandidate.Report
    $missingPair=Resolve-Canonical $candidateResolverWorkspace $validContext
    $candidateAuth=& $script:protocolModule {param($Root,$Work,$Report,$Context,$Issued)New-HarnessCanaryAuthorizationDocument -RepoRoot $Root -WorkspaceRoot $Work -Report $Report -ObservedHostContext $Context -AuthorizedBy 'operator' -IssuedAtUtc $Issued -ExpiresAtUtc $Issued.AddHours(1)} $RepoRoot $candidateResolverWorkspace $verifiedCandidate.Report $validContext $now
    Write-Json $authCanonical $candidateAuth;$completePair=Resolve-Canonical $candidateResolverWorkspace $validContext
    $pairCopyWorkspace=Join-Path $temp 'pair-copy';$pairCopyDir=Join-Path $pairCopyWorkspace '.assistant\runtime\rollout';[void][IO.Directory]::CreateDirectory($pairCopyDir);[IO.File]::Copy($candidateCanonical,(Join-Path $pairCopyDir 'v2-canary-candidate.json'));[IO.File]::Copy($authCanonical,(Join-Path $pairCopyDir 'v2-canary-authorization.json'));$copiedPair=Resolve-Canonical $pairCopyWorkspace $validContext
    [IO.File]::Delete($candidateCanonical);$authOnly=Resolve-Canonical $candidateResolverWorkspace $validContext
    Check ($missingPair.reason-ceq'rollout-canary-authorization-missing'-and$completePair.reason-match'rollout-evidence-provenance-unwired'-and$copiedPair.reason-ceq'rollout-canary-authorization-workspace-mismatch'-and$authOnly.reason-ceq'rollout-report-missing') 'missing, complete-unwired, copied, and torn Candidate/Auth pairs all fail closed' 'Candidate/Auth pair state selected v2'

    $candidateBytes=[IO.File]::ReadAllBytes($verifiedCandidate.ReportPath);$finalBytes=[IO.File]::ReadAllBytes($verifiedFinal.ReportPath);$authorizationBytes=[Text.UTF8Encoding]::new($false).GetBytes(($authorization|ConvertTo-Json -Depth 100 -Compress))
    $transactionWorkspace=Join-Path $temp 'transaction-workspace';[void][IO.Directory]::CreateDirectory($transactionWorkspace)
    $candidateTransaction=Invoke-StructuralTransaction $transactionWorkspace $verifiedCandidate.ReportPath 'canary-candidate' $candidateBytes $authorizationBytes
    $candidateTarget=Join-Path $transactionWorkspace $candidateTransaction.candidate_target;$authorizationTarget=Join-Path $transactionWorkspace $candidateTransaction.authorization_target;$finalTarget=Join-Path $transactionWorkspace $candidateTransaction.final_target
    Check ((Test-Path $candidateTarget)-and(Test-Path $authorizationTarget)-and-not(Test-Path $finalTarget)) 'Candidate transaction writes only Candidate and Authorization paths' 'Candidate transaction touched the Final path or missed its pair'
    $finalTransaction=Invoke-StructuralTransaction $transactionWorkspace $verifiedFinal.ReportPath 'final-default' $finalBytes ([byte[]]::new(0))
    Check ((Test-Path $finalTarget)-and-not(Test-Path $candidateTarget)-and-not(Test-Path $authorizationTarget)-and(Test-ExactBytes $finalBytes ([IO.File]::ReadAllBytes($finalTarget)))) 'Final transaction writes Final and removes stale Candidate/Auth' 'Final transaction left stale Candidate/Auth state'
    $finalBefore=[IO.File]::ReadAllBytes($finalTarget);$candidateAfterFinalReason=Get-Rejection {Invoke-StructuralTransaction $transactionWorkspace $verifiedCandidate.ReportPath 'canary-candidate' $candidateBytes $authorizationBytes}
    Check ($candidateAfterFinalReason-match'final-already-canonical'-and(Test-ExactBytes $finalBefore ([IO.File]::ReadAllBytes($finalTarget)))-and-not(Test-Path $candidateTarget)-and-not(Test-Path $authorizationTarget)) 'Candidate cannot affect an existing Final' 'Candidate modified or shadowed an existing Final'

    $roundTripWorkspace=Join-Path $temp 'round-trip-workspace';[void][IO.Directory]::CreateDirectory($roundTripWorkspace);$canonicalFinalPath='.assistant/runtime/rollout/v2-eligibility.json';$roundTripModule=New-CanonicalProtocolModule $canonicalFinalPath 'final-default' ([string]$verifiedFinal.Report.report_digest)
    $oldEligibilityPath=[Environment]::GetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[EnvironmentVariableTarget]::Process)
    try{[Environment]::SetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT','.assistant/runtime/rollout/alternate.json',[EnvironmentVariableTarget]::Process);$roundTrip=& $script:evidenceModule {param($Root,$Work,$ArtifactPath,$Bytes,$Digest,$Context,$Protocol)Invoke-HarnessRolloutPublicationTransaction -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $ArtifactPath -Phase final-default -ReportBytes $Bytes -ExpectedReportDigest $Digest -ObservedHostContext $Context -ProtocolModule $Protocol} $RepoRoot $roundTripWorkspace $verifiedFinal.ReportPath $finalBytes ([string]$verifiedFinal.Report.report_digest) $validContext $roundTripModule}finally{[Environment]::SetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',$oldEligibilityPath,[EnvironmentVariableTarget]::Process)}
    Check ($roundTrip.final_target-ceq$canonicalFinalPath-and(Test-ExactBytes $finalBytes ([IO.File]::ReadAllBytes((Join-Path $roundTripWorkspace $canonicalFinalPath))))) 'canonical round-trip binds the exact published path and report digest' 'canonical round-trip followed an alternate report path or digest'
    $wrongReportWorkspace=Join-Path $temp 'wrong-report-round-trip';[void][IO.Directory]::CreateDirectory($wrongReportWorkspace);$wrongReportModule=New-CanonicalProtocolModule $canonicalFinalPath 'final-default' ('sha256:'+('e'*64));$wrongReportReason=Get-Rejection {& $script:evidenceModule {param($Root,$Work,$ArtifactPath,$Bytes,$Digest,$Context,$Protocol)Invoke-HarnessRolloutPublicationTransaction -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $ArtifactPath -Phase final-default -ReportBytes $Bytes -ExpectedReportDigest $Digest -ObservedHostContext $Context -ProtocolModule $Protocol} $RepoRoot $wrongReportWorkspace $verifiedFinal.ReportPath $finalBytes ([string]$verifiedFinal.Report.report_digest) $validContext $wrongReportModule}
    $canonicalCandidatePath='.assistant/runtime/rollout/v2-canary-candidate.json';$wrongAuthWorkspace=Join-Path $temp 'wrong-auth-round-trip';[void][IO.Directory]::CreateDirectory($wrongAuthWorkspace);$wrongAuthModule=New-CanonicalProtocolModule $canonicalCandidatePath 'canary-candidate' ([string]$verifiedCandidate.Report.report_digest) ('sha256:'+('d'*64));$wrongAuthReason=Get-Rejection {& $script:evidenceModule {param($Root,$Work,$ArtifactPath,$Report,$ReportDigest,$Authorization,$AuthorizationDigest,$Context,$Protocol)Invoke-HarnessRolloutPublicationTransaction -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $ArtifactPath -Phase canary-candidate -ReportBytes $Report -ExpectedReportDigest $ReportDigest -AuthorizationBytes $Authorization -ExpectedAuthorizationDigest $AuthorizationDigest -ObservedHostContext $Context -ProtocolModule $Protocol} $RepoRoot $wrongAuthWorkspace $verifiedCandidate.ReportPath $candidateBytes ([string]$verifiedCandidate.Report.report_digest) $authorizationBytes ([string]$authorization.authorization_digest) $validContext $wrongAuthModule}
    Check ($wrongReportReason-match'canonical-verification-failed'-and-not(Test-Path (Join-Path $wrongReportWorkspace $canonicalFinalPath))-and$wrongAuthReason-match'canonical-verification-failed'-and-not(Test-Path (Join-Path $wrongAuthWorkspace $canonicalCandidatePath))-and-not(Test-Path (Join-Path $wrongAuthWorkspace '.assistant/runtime/rollout/v2-canary-authorization.json'))) 'canonical round-trip rejects report or Authorization digest drift and rolls back' 'canonical round-trip accepted a different report or Authorization digest'
    Remove-Module -ModuleInfo $roundTripModule,$wrongReportModule,$wrongAuthModule -Force
    $script:protocolModule=Import-Module $protocolPath -Force -PassThru

    $rollbackWorkspace=Join-Path $temp 'rollback-workspace';[void][IO.Directory]::CreateDirectory($rollbackWorkspace);$null=Invoke-StructuralTransaction $rollbackWorkspace $verifiedCandidate.ReportPath 'canary-candidate' $candidateBytes $authorizationBytes
    $rollbackCandidate=Join-Path $rollbackWorkspace '.assistant\runtime\rollout\v2-canary-candidate.json';$rollbackAuth=Join-Path $rollbackWorkspace '.assistant\runtime\rollout\v2-canary-authorization.json';$rollbackFinal=Join-Path $rollbackWorkspace '.assistant\runtime\rollout\v2-eligibility.json';$candidatePre=[IO.File]::ReadAllBytes($rollbackCandidate);$authPre=[IO.File]::ReadAllBytes($rollbackAuth)
    $rollbackReason=Get-Rejection {Invoke-StructuralTransaction $rollbackWorkspace $verifiedFinal.ReportPath 'final-default' $finalBytes ([byte[]]::new(0)) 3}
    $rollbackCandidateRestored=Test-ExactBytes $candidatePre ([IO.File]::ReadAllBytes($rollbackCandidate));$rollbackAuthRestored=Test-ExactBytes $authPre ([IO.File]::ReadAllBytes($rollbackAuth))
    Check ($rollbackReason-match'structural-test-fault'-and-not(Test-Path $rollbackFinal)-and$rollbackCandidateRestored-and$rollbackAuthRestored) 'Final cleanup fault restores missing Final plus exact Candidate/Auth preimages' 'Final cleanup fault left torn state'
    $threePreimageWorkspace=Join-Path $temp 'three-preimage-workspace';$threeDir=Join-Path $threePreimageWorkspace '.assistant\runtime\rollout';[void][IO.Directory]::CreateDirectory($threeDir);$oldFinal=[Text.UTF8Encoding]::new($false).GetBytes('{"old":"final"}');$oldCandidate=[Text.UTF8Encoding]::new($false).GetBytes('{"old":"candidate"}');$oldAuth=[Text.UTF8Encoding]::new($false).GetBytes('{"old":"authorization"}');[IO.File]::WriteAllBytes((Join-Path $threeDir 'v2-eligibility.json'),$oldFinal);[IO.File]::WriteAllBytes((Join-Path $threeDir 'v2-canary-candidate.json'),$oldCandidate);[IO.File]::WriteAllBytes((Join-Path $threeDir 'v2-canary-authorization.json'),$oldAuth)
    $threeReason=Get-Rejection {Invoke-StructuralTransaction $threePreimageWorkspace $verifiedFinal.ReportPath 'final-default' $finalBytes ([byte[]]::new(0)) 3}
    $oldFinalRestored=Test-ExactBytes -Left $oldFinal -Right ([IO.File]::ReadAllBytes((Join-Path $threeDir 'v2-eligibility.json')))
    $oldCandidateRestored=Test-ExactBytes -Left $oldCandidate -Right ([IO.File]::ReadAllBytes((Join-Path $threeDir 'v2-canary-candidate.json')))
    $oldAuthRestored=Test-ExactBytes -Left $oldAuth -Right ([IO.File]::ReadAllBytes((Join-Path $threeDir 'v2-canary-authorization.json')))
    Check ($threeReason-match'structural-test-fault'-and$oldFinalRestored-and$oldCandidateRestored-and$oldAuthRestored) 'three-path failure restores exact Final/Candidate/Authorization old bytes' 'three-path rollback changed a preimage'

    $casWorkspace=Join-Path $temp 'rollback-cas-workspace';$casDir=Join-Path $casWorkspace '.assistant\runtime\rollout';[void][IO.Directory]::CreateDirectory($casDir)
    $casExternal=[Text.UTF8Encoding]::new($false).GetBytes('{"external":"new-value"}');$casPublished=[Text.UTF8Encoding]::new($false).GetBytes('{"transaction":"published"}')
    $casPublishedDigest=& $script:evidenceModule {param($Bytes)Get-ReleaseSha256Bytes -Bytes $Bytes} $casPublished
    $casRecords=@(
        [ordered]@{name='final';path=(Join-Path $casDir 'v2-eligibility.json');relative='.assistant/runtime/rollout/v2-eligibility.json';preimage=[ordered]@{exists=$true;bytes=$oldFinal;digest=(& $script:evidenceModule {param($Bytes)Get-ReleaseSha256Bytes -Bytes $Bytes} $oldFinal)};published_digest=$casPublishedDigest},
        [ordered]@{name='candidate';path=(Join-Path $casDir 'v2-canary-candidate.json');relative='.assistant/runtime/rollout/v2-canary-candidate.json';preimage=[ordered]@{exists=$false;bytes=[byte[]]::new(0);digest='missing'};published_digest=$casPublishedDigest},
        [ordered]@{name='authorization';path=(Join-Path $casDir 'v2-canary-authorization.json');relative='.assistant/runtime/rollout/v2-canary-authorization.json';preimage=[ordered]@{exists=$true;bytes=$oldAuth;digest=(& $script:evidenceModule {param($Bytes)Get-ReleaseSha256Bytes -Bytes $Bytes} $oldAuth)};published_digest=$casPublishedDigest}
    )
    $casPreserved=$true
    foreach($record in $casRecords){[IO.File]::WriteAllBytes([string]$record.path,$casExternal);$reason=Get-Rejection {& $script:evidenceModule {param($Work,$Value)Restore-HarnessRolloutPublicationRecord -WorkspaceRoot $Work -Record $Value} $casWorkspace $record};if($reason-cnotmatch"rollout-promotion-rollback-cas-mismatch-$($record.name)"-or-not(Test-ExactBytes $casExternal ([IO.File]::ReadAllBytes([string]$record.path)))){$casPreserved=$false}}
    Check $casPreserved 'rollback CAS preserves lock-external Final/Candidate/Authorization values' 'rollback overwrote or deleted a lock-external value'

    $pathWorkspace=Join-Path $temp 'path-workspace';[void][IO.Directory]::CreateDirectory($pathWorkspace);$paths=& $script:evidenceModule {param($Root,$Work,$ArtifactPath)Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $ArtifactPath} $RepoRoot $pathWorkspace $verifiedFinal.ReportPath
    Check ($paths.final_target_relative-ceq'.assistant/runtime/rollout/v2-eligibility.json'-and$paths.candidate_target_relative-ceq'.assistant/runtime/rollout/v2-canary-candidate.json'-and$paths.authorization_target_relative-ceq'.assistant/runtime/rollout/v2-canary-authorization.json') 'Promotion paths are three distinct Canonical files' 'Canonical rollout paths are not distinct'
    $hardlinkSource=Join-Path $script:deliveryRoot 'hardlink-source.json';[IO.File]::WriteAllText($hardlinkSource,'{}',[Text.UTF8Encoding]::new($false));$hardlinkAlias=Join-Path $script:deliveryRoot 'hardlink-alias.json';$null=@(& fsutil.exe hardlink create $hardlinkAlias $hardlinkSource 2>&1);$hardlinkRejected=$false;try{$null=& $script:evidenceModule {param($Root,$Work,$ArtifactPath)Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $ArtifactPath} $RepoRoot $pathWorkspace $hardlinkAlias}catch{$hardlinkRejected=$true};Check ($LASTEXITCODE-eq0-and$hardlinkRejected) 'Promotion rejects hardlinked report input' 'Promotion accepted hardlinked report input'
    $adsInput=Join-Path $script:deliveryRoot 'ads-input.json';[IO.File]::WriteAllText($adsInput,'{}',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText(($adsInput+':extra'),'x',[Text.UTF8Encoding]::new($false));$adsRejected=$false;try{$null=& $script:evidenceModule {param($Root,$Work,$ArtifactPath)Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Work -ReportPath $ArtifactPath} $RepoRoot $pathWorkspace $adsInput}catch{$adsRejected=$true};Check $adsRejected 'Promotion rejects alternate streams on report input' 'Promotion accepted alternate-stream input'

    $v1Report=& $script:protocolModule {param($Root,$Gates)New-HarnessRolloutReportDocument -RepoRoot $Root -Gates $Gates} $RepoRoot (New-V1Gates);$v1Path=Join-Path $resolverWorkspace 'rollout\v1.json';Write-Json $v1Path $v1Report;$v1Resolution=Resolve-Explicit $resolverWorkspace 'rollout/v1.json' $validContext
    Check ($v1Resolution.selected_protocol-ceq'v1'-and$v1Resolution.rollout_eligibility.status-ceq'historical'-and$v1Resolution.reason-ceq'rollout-v1-historical-diagnostic-only') 'v1 report remains diagnostic-only' 'v1 report gained authorization authority'
    $explicitV1=Resolve-Requested $resolverWorkspace 'v1';$explicitV2=Resolve-Requested $resolverWorkspace 'v2'
    $existingV1Id='existing-v1';$v1Plan=Join-Path $resolverWorkspace "docs\tasks\$existingV1Id\plan.md";[void][IO.Directory]::CreateDirectory((Split-Path -Parent $v1Plan));[IO.File]::WriteAllText($v1Plan,"---`ntask_id: existing-v1`nstage: TEST`ntool: codex`nupdated: 2026-07-25`n---`n",[Text.UTF8Encoding]::new($false));$existingV1=Resolve-Canonical $resolverWorkspace $null $existingV1Id
    $existingV2Id='existing-v2';$v2Path=Join-Path $resolverWorkspace ".assistant\runtime\tasks\$existingV2Id\task.json";Write-Json $v2Path (New-V2TaskDocument $existingV2Id);$existingV2=Resolve-Canonical $resolverWorkspace $null $existingV2Id
    $configWorkspace=Join-Path $temp 'config-workspace';[void][IO.Directory]::CreateDirectory($configWorkspace);$null=Set-HarnessWorkspaceProtocolConfig -RepoRoot $RepoRoot -WorkspaceRoot $configWorkspace -NewTaskProtocol v2;$enabled=Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $configWorkspace;$null=Set-HarnessWorkspaceProtocolConfig -RepoRoot $RepoRoot -WorkspaceRoot $configWorkspace -NewTaskProtocol v1;$disabled=Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $configWorkspace
    Check ($explicitV1.selected_protocol-ceq'v1'-and$explicitV2.selected_protocol-ceq'v2'-and$existingV1.selected_protocol-ceq'v1'-and$existingV2.selected_protocol-ceq'v2'-and$enabled.selected_protocol-ceq'v2'-and$disabled.selected_protocol-ceq'v1') 'v1 stop-loss, explicit/workspace enable-v2, and existing Artifact priority remain unchanged' 'protocol priority regressed'

    $doc=Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\release\default-promotion-gates.md') -Raw -Encoding utf8
    Check ($doc-match'provenance'-and$doc-match'Observed Host Context'-and$doc-match'expires_at_utc'-and$doc-match'v2-canary-candidate\.json'-and$doc-match'Review Payload'-and$doc-match'artifact_path'-and$doc-match'producer_identity'-and$doc-notmatch'rollout-eligibility-v2-envelope/v1') 'Canonical documentation names every correction boundary without the obsolete G12 envelope' 'Canonical documentation lacks or contradicts correction semantics'
} catch {
    [Console]::Error.WriteLine("TEST_EXCEPTION: $($_.Exception.Message)`n$($_.ScriptStackTrace)")
    throw
} finally {
    if($null-eq$oldGitDir){Remove-Item Env:GIT_DIR -ErrorAction Ignore}else{$env:GIT_DIR=$oldGitDir}
    if($null-eq$oldGitWorkTree){Remove-Item Env:GIT_WORK_TREE -ErrorAction Ignore}else{$env:GIT_WORK_TREE=$oldGitWorkTree}
    Remove-Module Harness.Protocol,Harness.RolloutEvidence -ErrorAction Ignore
    if(Test-Path -LiteralPath $temp){Remove-DirectoryWithRetry -Path $temp}
}
$repoAfter=@(& git -C $RepoRoot status --porcelain --untracked-files=all)
Check (@(Compare-Object $repoBefore $repoAfter).Count-eq0) 'default-flip verifier leaves repository state unchanged' 'default-flip verifier changed repository state'
foreach($item in $script:checks){"[PASS] $item"};foreach($item in $script:failures){"[FAIL] $item"};if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1};"STATUS: PASS ($($script:checks.Count) checks)";exit 0
