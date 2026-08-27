[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [Collections.Generic.List[string]]::new()
$script:failures = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Pass,[string]$Fail) { if ($Condition) { $script:checks.Add($Pass) } else { $script:failures.Add($Fail) } }
function Get-BytesDigest([byte[]]$Bytes) { return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-TextDigest([string]$Text) { return Get-BytesDigest ([Text.UTF8Encoding]::new($false).GetBytes($Text)) }
function Get-FileDigest([string]$Path) { return Get-BytesDigest ([IO.File]::ReadAllBytes($Path)) }
function Copy-Document([Collections.IDictionary]$Document) { return ($Document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -AsHashtable -Depth 100 }
function Set-ReceiptDigest([Collections.IDictionary]$Document) { $Document.receipt_digest=$null;$Document.receipt_digest=Get-TextDigest ($Document | ConvertTo-Json -Depth 100 -Compress) }
function Write-Document([string]$Path,[Collections.IDictionary]$Document) { [IO.File]::WriteAllText($Path,($Document | ConvertTo-Json -Depth 100 -Compress),[Text.UTF8Encoding]::new($false)) }

$modulePath = Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1'
$writerPath = Join-Path $RepoRoot 'scripts\write-release-full-receipt.ps1'
$schemaPath = Join-Path $RepoRoot 'schemas\release-full-receipt.schema.json'
$workflowPath = Join-Path $RepoRoot '.github\workflows\validation.yml'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('release-full-receipt-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $actualSource = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
    $cleanSource = [ordered]@{
        revision=[string]$actualSource.revision;commit_tree_oid=[string]$actualSource.commit_tree_oid;object_format=[string]$actualSource.object_format
        dirty=$false;status_entry_count=0L;status_digest=Get-TextDigest '';state_digest=Get-TextDigest ("{0}`n{1}`n{2}`n" -f $actualSource.revision,$actualSource.commit_tree_oid,$actualSource.object_format);state_basis='git-revision-tree-status/v1'
    }
    $definition = & $module { [ordered]@{definition=Get-ReleaseFullReceiptDefinition;paths=Get-ReleaseFullReceiptInputPaths} }

    function New-ReceiptFixture([ValidateSet('formal','test-only')][string]$ProducerMode='formal') {
        $inputDigests=[ordered]@{};foreach($entry in $definition.paths.GetEnumerator()){$inputDigests[$entry.Key]=Get-FileDigest (Join-Path $RepoRoot ([string]$entry.Value))}
        $inputs=[ordered]@{};$index=0
        foreach($entry in $definition.definition.input_contracts.GetEnumerator()){
            $index++;$inputs[$entry.Key]=[ordered]@{evidence_contract=[string]$entry.Value;raw_digest=Get-TextDigest "G11 raw $index";document_digest=Get-TextDigest "G11 document $index";source_revision=[string]$cleanSource.revision;status='pass'}
        }
        $status=if($ProducerMode-ceq'formal'){'pass'}else{'unavailable'}
        $reason=if($ProducerMode-ceq'formal'){'all-release-full-checks-passed'}else{'non-formal-producer-mode'}
        $document=[ordered]@{
            schema_version='harness-release-full-receipt/v1';generated_at_utc=[DateTimeOffset]::UtcNow.ToString('o');source_revision=[string]$cleanSource.revision;source_dirty=$false;source_state_stable=$true
            source=[ordered]@{commit_tree_oid=[string]$cleanSource.commit_tree_oid;object_format=[string]$cleanSource.object_format;start=(Copy-Document $cleanSource);end=(Copy-Document $cleanSource);input_digests=$inputDigests}
            receipt_run_id=(Get-TextDigest "G11 $ProducerMode receipt").Substring(7,32);producer_identity='release-full-receipt/v1';producer_mode=$ProducerMode
            workflow=[ordered]@{run_id='9001';run_attempt=1L;job_name='release-full';checkout_sha=[string]$cleanSource.revision;conclusion='success'}
            aggregator_observation=[ordered]@{role='aggregator';observation_digest=Get-TextDigest 'G11 aggregator observation';account_digest=Get-TextDigest 'G11 aggregator account';runner_label_digest=Get-TextDigest 'G11 aggregator label'}
            inputs=$inputs;status=$status;reason=$reason;receipt_digest=$null
        }
        Set-ReceiptDigest $document
        return $document
    }

    function Invoke-ReceiptValidation([Collections.IDictionary]$Document) {
        try {
            $value=& $module {param($Root,$Receipt,$Source)Assert-ReleaseFullReceipt -RepoRoot $Root -Document $Receipt -ExpectedSource $Source -RequirePortableSource} $RepoRoot $Document $cleanSource
            return [pscustomobject]@{Success=$true;Value=$value;Reason=''}
        } catch { return [pscustomobject]@{Success=$false;Value=$null;Reason=[string]$_.Exception.Message} }
    }

    function New-BindingFixture([Collections.IDictionary]$Receipt) {
        $modelObservation=[ordered]@{role='model-producer';observation_digest=Get-TextDigest 'G11 model observation';account_digest=Get-TextDigest 'G11 model account';runner_label_digest=Get-TextDigest 'G11 producer label';status='pass'}
        $hostObservation=[ordered]@{role='host-producer';observation_digest=Get-TextDigest 'G11 host observation';account_digest=Get-TextDigest 'G11 host account';runner_label_digest=Get-TextDigest 'G11 producer label';status='pass'}
        $aggregatorObservation=[ordered]@{role='aggregator';observation_digest=[string]$Receipt.aggregator_observation.observation_digest;account_digest=[string]$Receipt.aggregator_observation.account_digest;runner_label_digest=[string]$Receipt.aggregator_observation.runner_label_digest;status='pass'}
        $workflow=[ordered]@{run_id=[string]$Receipt.workflow.run_id;run_attempt=[long]$Receipt.workflow.run_attempt}
        $model=[ordered]@{workflow=[ordered]@{run_id='9001';run_attempt=1L;conclusion='success'};runner_observation=[ordered]@{role='model-producer';observation_digest=[string]$modelObservation.observation_digest;account_digest=[string]$modelObservation.account_digest;runner_label_digest=[string]$modelObservation.runner_label_digest};producer_mode='formal';artifacts=@([ordered]@{status='pass'});source_dirty=$false;source_state_stable=$true;status='pass';reason='all-producer-checks-passed';raw_digest=[string]$Receipt.inputs.release_model.raw_digest;receipt_digest=[string]$Receipt.inputs.release_model.document_digest;source_revision=[string]$Receipt.source_revision}
        $hostReceipt=[ordered]@{workflow=[ordered]@{run_id='9001';run_attempt=1L;conclusion='success'};runner_observation=[ordered]@{role='host-producer';observation_digest=[string]$hostObservation.observation_digest;account_digest=[string]$hostObservation.account_digest;runner_label_digest=[string]$hostObservation.runner_label_digest};producer_mode='formal';artifacts=@([ordered]@{status='pass'},[ordered]@{status='pass'},[ordered]@{status='pass'});source_dirty=$false;source_state_stable=$true;status='pass';reason='all-producer-checks-passed';raw_digest=[string]$Receipt.inputs.release_host.raw_digest;receipt_digest=[string]$Receipt.inputs.release_host.document_digest;source_revision=[string]$Receipt.source_revision}
        return [ordered]@{
            exact=[ordered]@{raw_digest=[string]$Receipt.inputs.exact_head.raw_digest;report_digest=[string]$Receipt.inputs.exact_head.document_digest;source_revision=[string]$Receipt.source_revision;status='pass'}
            isolation=[ordered]@{workflow=$workflow;observations=[ordered]@{model_producer=$modelObservation;host_producer=$hostObservation;aggregator=$aggregatorObservation};raw_digest=[string]$Receipt.inputs.release_isolation.raw_digest;report_digest=[string]$Receipt.inputs.release_isolation.document_digest;source_revision=[string]$Receipt.source_revision;status='pass'}
            model=$model;host=$hostReceipt
            v1=[ordered]@{raw_digest=[string]$Receipt.inputs.v1_stop_loss.raw_digest;report_digest=[string]$Receipt.inputs.v1_stop_loss.document_digest;source_revision=[string]$Receipt.source_revision;status='pass'}
            core=[ordered]@{preset='core';raw_digest=[string]$Receipt.inputs.lifecycle_core.raw_digest;report_digest=[string]$Receipt.inputs.lifecycle_core.document_digest;source_revision=[string]$Receipt.source_revision;status='pass'}
            governed=[ordered]@{preset='governed';raw_digest=[string]$Receipt.inputs.lifecycle_governed.raw_digest;report_digest=[string]$Receipt.inputs.lifecycle_governed.document_digest;source_revision=[string]$Receipt.source_revision;status='pass'}
            full=[ordered]@{preset='full';raw_digest=[string]$Receipt.inputs.lifecycle_full.raw_digest;report_digest=[string]$Receipt.inputs.lifecycle_full.document_digest;source_revision=[string]$Receipt.source_revision;status='pass'}
        }
    }

    function Invoke-Binding([Collections.IDictionary]$Receipt,[Collections.IDictionary]$Bindings) {
        try {
            $value=& $module {param($R,$B)Assert-ReleaseFullReceiptBindings -Receipt $R -ExactHead $B.exact -ReleaseIsolation $B.isolation -ReleaseModel $B.model -ReleaseHost $B.host -V1StopLoss $B.v1 -LifecycleCore $B.core -LifecycleGoverned $B.governed -LifecycleFull $B.full} $Receipt $Bindings
            return [pscustomobject]@{Success=$true;Value=[string]$value;Reason=''}
        } catch { return [pscustomobject]@{Success=$false;Value='';Reason=[string]$_.Exception.Message} }
    }

    function Reject-Receipt([string]$Name,[scriptblock]$Mutation) {
        $document=New-ReceiptFixture;& $Mutation $document;Set-ReceiptDigest $document
        Check (-not (Invoke-ReceiptValidation -Document $document).Success) "G11 rejects $Name" "G11 accepted $Name"
    }

    $formalDocument=New-ReceiptFixture
    $formal=Invoke-ReceiptValidation -Document $formalDocument
    Check ($formal.Success -and [string]$formal.Value.status-ceq'pass') 'formal G11 Fixture derives pass' "formal G11 Fixture failed: $($formal.Reason)"
    $testOnly=Invoke-ReceiptValidation -Document (New-ReceiptFixture -ProducerMode test-only)
    Check ($testOnly.Success -and [string]$testOnly.Value.status-ceq'unavailable' -and [string]$testOnly.Value.reason-ceq'non-formal-producer-mode') 'test-only G11 Fixture remains unavailable' "test-only G11 Fixture failed: $($testOnly.Reason)"

    $bindings=New-BindingFixture -Receipt $formal.Value
    $bindingResult=Invoke-Binding -Receipt $formal.Value -Bindings $bindings
    Check ($bindingResult.Success -and $bindingResult.Value-ceq'pass') 'G11 binds all eight strict input digests and G04/G09/G10 workflow observations' "G11 input binding failed: $($bindingResult.Reason)"

    $formalPath=Join-Path $temp 'release-full.json';Write-Document $formalPath $formalDocument
    $callerGate=[ordered]@{status='fail';evidence_contract='harness-release-full-receipt/v1';artifact_path=$formalPath;evidence_digest=Get-FileDigest $formalPath;source_revision=[string]$cleanSource.revision;producer_identity='caller-forged/v1'}
    $callerResult=$null;$callerError='';try{$callerResult=& $module {param($Root,$Gate,$Source)Read-ReleaseFullReceiptRolloutEvidence -RepoRoot $Root -Gate $Gate -ExpectedSource $Source} $RepoRoot $callerGate $cleanSource}catch{$callerError=[string]$_.Exception.Message}
    Check ($null-ne$callerResult -and [string]$callerResult.status-ceq'pass' -and [string]$callerResult.producer_identity-ceq'release-full-receipt/v1') 'G11 strict reader overrides forged caller pass state and identity' "G11 trusted caller metadata: $callerError"

    Reject-Receipt 'a missing input' {param($r)$r.inputs.Remove('exact_head')}
    Reject-Receipt 'an input from another Source' {param($r)$r.inputs.release_host.source_revision='0'*40}
    Reject-Receipt 'a stale checkout' {param($r)$r.workflow.checkout_sha='0'*40}
    $badReceiptDigest=New-ReceiptFixture;$badReceiptDigest.receipt_digest='sha256:'+('0'*64)
    Check (-not (Invoke-ReceiptValidation -Document $badReceiptDigest).Success) 'G11 rejects a mismatched receipt_digest' 'G11 accepted a mismatched receipt_digest'
    Reject-Receipt 'test-only presented as pass' {param($r)$r.producer_mode='test-only'}
    Reject-Receipt 'a Credential field' {param($r)$r['credential']='Bearer fixture-secret'}
    Reject-Receipt 'a private absolute path' {param($r)$r.reason='C:\Users\private\receipt.json'}

    $runBindings=New-BindingFixture -Receipt $formal.Value;$runBindings.isolation.workflow.run_id='9002'
    Check (-not (Invoke-Binding -Receipt $formal.Value -Bindings $runBindings).Success) 'G11 rejects a different Release Workflow Run' 'G11 accepted a different Release Workflow Run'
    $attemptBindings=New-BindingFixture -Receipt $formal.Value;$attemptBindings.host.workflow.run_attempt=2L
    Check (-not (Invoke-Binding -Receipt $formal.Value -Bindings $attemptBindings).Success) 'G11 rejects a different Release Workflow Attempt' 'G11 accepted a different Release Workflow Attempt'
    $aggregatorDocument=New-ReceiptFixture;$aggregatorDocument.aggregator_observation.observation_digest=Get-TextDigest 'different aggregator';Set-ReceiptDigest $aggregatorDocument;$aggregatorReceipt=Invoke-ReceiptValidation $aggregatorDocument
    $aggregatorBinding=if($aggregatorReceipt.Success){Invoke-Binding -Receipt $aggregatorReceipt.Value -Bindings (New-BindingFixture -Receipt $formal.Value)}else{[pscustomobject]@{Success=$false;Reason='receipt validation failed'}}
    Check ($aggregatorReceipt.Success -and -not $aggregatorBinding.Success) 'G11 rejects an Aggregator Observation that differs from G04' "G11 Aggregator mismatch result was validation=$($aggregatorReceipt.Success) [$($aggregatorReceipt.Reason)], binding=$($aggregatorBinding.Success): $($aggregatorBinding.Reason)"
    $producerBindings=New-BindingFixture -Receipt $formal.Value;$producerBindings.model.runner_observation.observation_digest=Get-TextDigest 'different model observation'
    Check (-not (Invoke-Binding -Receipt $formal.Value -Bindings $producerBindings).Success) 'G11 rejects a G09 Receipt that differs from G04' 'G11 accepted a mismatched G09 Receipt'
    $hostBindings=New-BindingFixture -Receipt $formal.Value;$hostBindings.host.runner_observation.account_digest=Get-TextDigest 'different host account'
    Check (-not (Invoke-Binding -Receipt $formal.Value -Bindings $hostBindings).Success) 'G11 rejects a G10 Receipt that differs from G04' 'G11 accepted a mismatched G10 Receipt'
    $lifecycleBindings=New-BindingFixture -Receipt $formal.Value;$lifecycleBindings.governed.preset='core'
    Check (-not (Invoke-Binding -Receipt $formal.Value -Bindings $lifecycleBindings).Success) 'G11 rejects a substituted Lifecycle preset' 'G11 accepted a substituted Lifecycle preset'

    $requiredNames=@('DP-G00-EXACT-HEAD-ENGINEERING-CI','DP-G01-MODEL40','DP-G02-COGNITIVE-HOST-3X3','DP-G03-INSTALLED-DESKTOP-HOST-3X3','DP-G04-CODEX-HOME-RUNNER-ISOLATION','DP-G05-V2-BARE-1.25','DP-G06-REQUEST-SEND-REDUCTION','DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE','DP-G09-RELEASE-MODEL','DP-G10-RELEASE-HOST','DP-G11-RELEASE-FULL','DP-G18-CORE-LIFECYCLE','DP-G19-GOVERNED-LIFECYCLE','DP-G20-FULL-LIFECYCLE')
    $missingG14=[ordered]@{};foreach($name in $requiredNames){$missingG14[$name]=Copy-Document $callerGate}
    $missingReason='';try{& $module {param($Root,$Source,$Gates)Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $Gates} $RepoRoot $cleanSource $missingG14}catch{$missingReason=[string]$_.Exception.Message}
    Check ($missingReason-ceq'rollout-evidence-release-full-gate-set-incomplete') 'G11 Adapter rejects a Gate Set missing G14 before reading Artifacts' 'G11 Adapter did not fail closed on missing G14'

    $writerTokens=$null;$writerErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($writerPath,[ref]$writerTokens,[ref]$writerErrors)
    $writerText=Get-Content -Raw -LiteralPath $writerPath -Encoding utf8
    Check ($writerErrors.Count-eq0 -and (Test-FileHasUtf8Bom $writerPath) -and $writerText-match'New-ReleaseFullReceiptArtifact' -and $writerText-notmatch'run-model-evals|run-host-benchmark|run-preset-lifecycle|run-v1-stop-loss') 'G11 Writer parses, delegates, and never runs an upstream Producer' 'G11 Writer is invalid or runs an upstream Producer'
    Check ((Get-Content -Raw -LiteralPath $schemaPath -Encoding utf8)|Test-Json) 'G11 Receipt Schema is valid JSON' 'G11 Receipt Schema is invalid JSON'

    $workflow=Get-Content -Raw -LiteralPath $workflowPath -Encoding utf8
    $releaseJob=[regex]::Match($workflow,'(?ms)^  release-full:\s*$.*\z').Value
    $pushBlock=[regex]::Match($workflow,'(?ms)^  push:\s*\r?$.*?(?=^  schedule:\s*\r?$)').Value
    $currentRef='refs/heads/codex/harness-v2-default-promotion'
    $dispatchBlock=[regex]::Match($workflow,'(?ms)^  workflow_dispatch:\s*\r?$.*?(?=^permissions:\s*\r?$)').Value
    $currentModelDownload=[regex]::Match($releaseJob,'(?ms)^      - name: Download current model evidence\s*$.*?(?=^      - name:)').Value
    $currentHostDownload=[regex]::Match($releaseJob,'(?ms)^      - name: Download current host evidence\s*$.*?(?=^      - name:)').Value
    $currentUpload=[regex]::Match($releaseJob,'(?ms)^      - name: Upload current rollout evidence\s*$.*?(?=^      - name:|\z)').Value
    $currentPaths=@([regex]::Matches($currentUpload,'(?m)^\s+\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/(?<name>[a-z0-9-]+\.json)\s*$')|ForEach-Object{$_.Groups['name'].Value})
    $expectedPaths=@('aggregator-runner-observation.json','release-isolation.json','exact-head-engineering.json','release-full-receipt.json','full-capability-source-binding.json')
    Check ($releaseJob-match[regex]::Escape("github.event_name == 'workflow_dispatch' && github.ref == '$currentRef'") -and $pushBlock-notmatch[regex]::Escape($currentRef)) 'Default Promotion enters release-full only through workflow_dispatch' 'Default Promotion release-full routing is not manual-only'
    Check (@('engineering_ci_run_id','engineering_review_comment_id'|Where-Object{$dispatchBlock-notmatch("(?ms)^      {0}:.*?^        required: true\s*$.*?^        type: string\s*$"-f[regex]::Escape($_))}).Count-eq0) 'workflow_dispatch requires both exact-head evidence identifiers as strings' 'workflow_dispatch exact-head inputs are missing or optional'
    Check ($currentModelDownload-notmatch'continue-on-error' -and $currentHostDownload-notmatch'continue-on-error') 'Default Promotion Model and Host downloads fail closed' 'Default Promotion download masks a missing Producer bundle'
    Check (($currentPaths-join'|')-ceq($expectedPaths-join'|') -and $currentUpload-match'if-no-files-found:\s*error' -and $releaseJob-match'write-capability-source-binding\.ps1[^\r\n]+-Kind full[^\r\n]+full-capability-source-binding\.json[^\r\n]+model-capability-source-binding\.json[^\r\n]+host-capability-source-binding\.json') 'Default Promotion rollout bundle contains exactly four historical files plus the source-binding sidecar' 'Default Promotion rollout bundle scope is wrong'
    Check (@([regex]::Matches($releaseJob,'(?m)^\s*GH_TOKEN:\s*\$\{\{ github\.token \}\}\s*$')).Count-eq1 -and $releaseJob-match'(?ms)^    permissions:\s*$.*?^      actions: read\s*$.*?^      pull-requests: read\s*$.*?^      issues: read\s*$' -and $releaseJob-notmatch'(?i)secrets\.') 'G00 receives one step-scoped read-only GitHub token' 'G00 GitHub token scope or permissions are broader than required'
    Check ($releaseJob-match'write-release-full-receipt\.ps1' -and $releaseJob-match'New-ReleaseIsolationReportArtifact' -and $releaseJob-match'New-ExactHeadEngineeringEvidenceArtifact' -and $releaseJob-match'(?s)Legacy full validation.*?generate-v2-rollout-report\.ps1') 'release-full wires G04, G00, and G11 while retaining an explicit legacy-only path' 'release-full aggregation sequence is incomplete'

    foreach($check in $script:checks){Write-Output "[PASS] $check"}
    if($script:failures.Count){foreach($failure in $script:failures){Write-Output "[FAIL] $failure"};Write-Output "STATUS: FAIL ($($script:failures.Count) failed, $($script:checks.Count) passed)";exit 1}
    Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
    exit 0
} finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}
