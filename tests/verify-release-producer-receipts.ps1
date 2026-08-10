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
function Copy-Document([Collections.IDictionary]$Document) { return ($Document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -AsHashtable -Depth 100 }
function Set-ReceiptDigest([Collections.IDictionary]$Document) { $Document.receipt_digest=$null;$Document.receipt_digest=Get-TextDigest ($Document | ConvertTo-Json -Depth 100 -Compress) }

$modulePath = Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1'
$writerPath = Join-Path $RepoRoot 'scripts\write-release-producer-receipt.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('release-producer-receipts-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $actualSource = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
    $cleanSource = [ordered]@{
        revision=[string]$actualSource.revision;commit_tree_oid=[string]$actualSource.commit_tree_oid;object_format=[string]$actualSource.object_format
        dirty=$false;status_entry_count=0;status_digest=Get-TextDigest '';state_digest=Get-TextDigest ("{0}`n{1}`n{2}`n" -f $actualSource.revision,$actualSource.commit_tree_oid,$actualSource.object_format);state_basis='git-revision-tree-status/v1'
    }

    function New-ReceiptFixture([ValidateSet('model','host')][string]$Kind,[ValidateSet('formal','test-only')][string]$ProducerMode='formal') {
        $metadata = & $module {
            param($ReceiptKind)
            [ordered]@{definition=Get-ReleaseProducerReceiptDefinition -Kind $ReceiptKind;inputs=Get-ReleaseProducerReceiptInputPaths -Kind $ReceiptKind}
        } $Kind
        $inputDigests = [ordered]@{}
        foreach ($entry in $metadata.inputs.GetEnumerator()) { $inputDigests[$entry.Key] = Get-FileDigest (Join-Path $RepoRoot ([string]$entry.Value)) }
        $artifacts = [Collections.Generic.List[object]]::new()
        $index = 0
        foreach ($definition in @($metadata.definition.artifacts)) {
            $index++
            $artifacts.Add([ordered]@{
                role=[string]$definition.role;evidence_contract=[string]$definition.evidence_contract
                raw_digest=Get-TextDigest "release $Kind raw $index";report_digest=Get-TextDigest "release $Kind report $index"
                source_revision=[string]$cleanSource.revision;status='pass'
            })
        }
        $status = if ($ProducerMode -ceq 'formal') { 'pass' } else { 'unavailable' }
        $reason = if ($ProducerMode -ceq 'formal') { 'all-producer-checks-passed' } else { 'non-formal-producer-mode' }
        $document = [ordered]@{
            schema_version=[string]$metadata.definition.schema_version;generated_at_utc=[DateTimeOffset]::UtcNow.ToString('o');source_revision=[string]$cleanSource.revision
            source_dirty=$false;source_state_stable=$true
            source=[ordered]@{commit_tree_oid=[string]$cleanSource.commit_tree_oid;object_format=[string]$cleanSource.object_format;start=(Copy-Document $cleanSource);end=(Copy-Document $cleanSource);input_digests=$inputDigests}
            receipt_run_id=(Get-TextDigest "release $Kind $ProducerMode receipt").Substring(7,32);producer_identity=[string]$metadata.definition.producer_identity;producer_mode=$ProducerMode
            workflow=[ordered]@{run_id='9001';run_attempt=1;job_name=[string]$metadata.definition.job_name;checkout_sha=[string]$cleanSource.revision;conclusion='success'}
            runner_observation=[ordered]@{role=[string]$metadata.definition.observation_role;observation_digest=Get-TextDigest "release $Kind $ProducerMode observation";account_digest=Get-TextDigest "release $Kind account";runner_label_digest=Get-TextDigest 'release producer runner label'}
            artifacts=@($artifacts);status=$status;reason=$reason;receipt_digest=$null
        }
        Set-ReceiptDigest $document
        return $document
    }

    function Invoke-ReceiptValidation([ValidateSet('model','host')][string]$Kind,[Collections.IDictionary]$Document) {
        try {
            $value = & $module { param($Root,$ReceiptKind,$Receipt,$Source) Assert-ReleaseProducerReceipt -RepoRoot $Root -Kind $ReceiptKind -Document $Receipt -ExpectedSource $Source -RequirePortableSource } $RepoRoot $Kind $Document $cleanSource
            return [pscustomobject]@{Success=$true;Value=$value;Reason=''}
        } catch { return [pscustomobject]@{Success=$false;Value=$null;Reason=[string]$_.Exception.Message} }
    }

    function Invoke-ObservationBinding([Collections.IDictionary]$Receipt,[string]$Status='pass',[string]$RunId='9001',[int]$RunAttempt=1,[string]$Digest='',[string]$Role='') {
        $observation = [ordered]@{
            role=$(if([string]::IsNullOrWhiteSpace($Role)){[string]$Receipt.runner_observation.role}else{$Role})
            observation_digest=$(if([string]::IsNullOrWhiteSpace($Digest)){[string]$Receipt.runner_observation.observation_digest}else{$Digest})
            account_digest=[string]$Receipt.runner_observation.account_digest;runner_label_digest=[string]$Receipt.runner_observation.runner_label_digest;status=$Status
        }
        try {
            $value = & $module { param($ProducerReceipt,$Summary,$Workflow) Assert-ReleaseProducerReceiptObservationBinding -Receipt $ProducerReceipt -Observation $Summary -IsolationWorkflow $Workflow } $Receipt $observation ([ordered]@{run_id=$RunId;run_attempt=$RunAttempt})
            return [pscustomobject]@{Success=$true;Value=[string]$value;Reason=''}
        } catch { return [pscustomobject]@{Success=$false;Value='';Reason=[string]$_.Exception.Message} }
    }

    function Reject-Receipt([string]$Name,[ValidateSet('model','host')][string]$Kind,[scriptblock]$Mutation) {
        $document = New-ReceiptFixture -Kind $Kind
        & $Mutation $document
        Set-ReceiptDigest $document
        Check (-not (Invoke-ReceiptValidation -Kind $Kind -Document $document).Success) "$Kind receipt rejects $Name" "$Kind receipt accepted $Name"
    }

    $formalModel = New-ReceiptFixture -Kind model
    $formalHost = New-ReceiptFixture -Kind host
    $modelResult = Invoke-ReceiptValidation -Kind model -Document $formalModel
    $hostResult = Invoke-ReceiptValidation -Kind host -Document $formalHost
    Check ($modelResult.Success -and [string]$modelResult.Value.status -ceq 'pass') 'formal G09 Receipt Fixture derives pass' "formal G09 Receipt Fixture failed: $($modelResult.Reason)"
    Check ($hostResult.Success -and [string]$hostResult.Value.status -ceq 'pass') 'formal G10 Receipt Fixture derives pass' "formal G10 Receipt Fixture failed: $($hostResult.Reason)"
    Check ((Invoke-ObservationBinding -Receipt $modelResult.Value).Success -and (Invoke-ObservationBinding -Receipt $hostResult.Value).Success) 'formal Receipt Fixtures bind their exact G04 producer summaries' 'formal Receipt Fixture did not bind its G04 producer summary'

    foreach ($kind in @('model','host')) {
        $testOnly = New-ReceiptFixture -Kind $kind -ProducerMode test-only
        $result = Invoke-ReceiptValidation -Kind $kind -Document $testOnly
        $binding = if ($result.Success) { Invoke-ObservationBinding -Receipt $result.Value -Status unavailable } else { [pscustomobject]@{Success=$false;Value=''} }
        Check ($result.Success -and [string]$result.Value.status -ceq 'unavailable' -and $binding.Success -and [string]$binding.Value -ceq 'unavailable') "$kind test-only Receipt remains unavailable" "$kind test-only Receipt became formal or invalid"
    }

    Reject-Receipt 'a stale checkout Head' model { param($r)$r.workflow.checkout_sha='0'*40 }
    $staleRun = New-ReceiptFixture -Kind model;$staleRun.workflow.run_id='9002';Set-ReceiptDigest $staleRun;$staleRunResult=Invoke-ReceiptValidation -Kind model -Document $staleRun
    Check ($staleRunResult.Success -and -not (Invoke-ObservationBinding -Receipt $staleRunResult.Value).Success) 'G09 rejects a stale workflow Run' 'G09 accepted a stale workflow Run'
    $staleAttempt = New-ReceiptFixture -Kind host;$staleAttempt.workflow.run_attempt=2;Set-ReceiptDigest $staleAttempt;$staleAttemptResult=Invoke-ReceiptValidation -Kind host -Document $staleAttempt
    Check ($staleAttemptResult.Success -and -not (Invoke-ObservationBinding -Receipt $staleAttemptResult.Value).Success) 'G10 rejects a stale workflow Attempt' 'G10 accepted a stale workflow Attempt'

    foreach ($kind in @('model','host')) {
        $failedJob = New-ReceiptFixture -Kind $kind;$failedJob.workflow.conclusion='failure';$failedJob.status='fail';$failedJob.reason='producer-check-failed';Set-ReceiptDigest $failedJob
        $failedResult=Invoke-ReceiptValidation -Kind $kind -Document $failedJob
        $failedBinding=if($failedResult.Success){Invoke-ObservationBinding -Receipt $failedResult.Value}else{[pscustomobject]@{Success=$false;Value=''}}
        Check ($failedResult.Success -and $failedBinding.Success -and [string]$failedBinding.Value -ceq 'fail') "$kind non-success Job conclusion derives fail" "$kind non-success Job conclusion did not fail"
    }
    $cognitiveFailure = & $module { Get-ReleaseProducerCombinedStatus -Statuses @('pass','fail','pass') }
    Check ([string]$cognitiveFailure -ceq 'fail') 'G10 Cognitive Artifact status combines G02/G05/G06' 'G10 Cognitive Artifact status ignored a G02/G05/G06 failure'

    Reject-Receipt 'the wrong Runner Observation role' model { param($r)$r.runner_observation.role='host-producer' }
    $wrongObservation = Invoke-ObservationBinding -Receipt $modelResult.Value -Digest (Get-TextDigest 'different observation')
    Check (-not $wrongObservation.Success) 'G09 rejects a mismatched G04 Observation digest' 'G09 accepted a mismatched G04 Observation digest'
    Check (-not (Invoke-ObservationBinding -Receipt $hostResult.Value -Role model-producer).Success) 'G10 rejects a mismatched G04 Observation role' 'G10 accepted a mismatched G04 Observation role'

    $modelEvidence = [ordered]@{raw_digest=Get-TextDigest 'different model raw';report_digest=[string]$formalModel.artifacts[0].report_digest;source_revision=[string]$cleanSource.revision;status='pass'}
    $modelDigestRejected=$false;try{& $module {param($ReceiptArtifact,$Evidence)Assert-ReleaseProducerArtifactBinding -ReceiptArtifact $ReceiptArtifact -Evidence $Evidence} $modelResult.Value.artifacts[0] $modelEvidence}catch{$modelDigestRejected=$true}
    Check $modelDigestRejected 'G09 rejects a Model raw digest mismatch' 'G09 accepted a Model raw digest mismatch'

    Reject-Receipt 'a missing Artifact' host { param($r)$r.artifacts=@($r.artifacts|Select-Object -First 2) }
    Reject-Receipt 'a Cognitive Artifact substituted for Installed Desktop' host { param($r)$r.artifacts[1].role='cognitive-host';$r.artifacts[1].evidence_contract='harness-host-benchmark-report/v2' }
    Reject-Receipt 'an Installed Desktop Artifact substituted for Cognitive Host' host { param($r)$r.artifacts[0].role='installed-desktop-primary';$r.artifacts[0].evidence_contract='harness-installed-desktop-benchmark-report/v1' }
    Reject-Receipt 'identical Installed Desktop Artifacts' host { param($r)$r.artifacts[2].raw_digest=$r.artifacts[1].raw_digest;$r.artifacts[2].report_digest=$r.artifacts[1].report_digest }
    Reject-Receipt 'an Artifact from another Source' host { param($r)$r.artifacts[2].source_revision='0'*40 }

    $badDigest=New-ReceiptFixture -Kind model;$badDigest.receipt_digest='sha256:'+('0'*64)
    Check (-not (Invoke-ReceiptValidation -Kind model -Document $badDigest).Success) 'Receipt rejects a mismatched receipt_digest' 'Receipt accepted a mismatched receipt_digest'
    $pretendFormal=New-ReceiptFixture -Kind model -ProducerMode test-only;$pretendFormal.producer_mode='formal';$pretendFormal.status='pass';$pretendFormal.reason='all-producer-checks-passed';Set-ReceiptDigest $pretendFormal;$pretendResult=Invoke-ReceiptValidation -Kind model -Document $pretendFormal
    Check ($pretendResult.Success -and -not (Invoke-ObservationBinding -Receipt $pretendResult.Value -Status unavailable).Success) 'test-only Observation cannot impersonate a formal pass Receipt' 'test-only Observation impersonated a formal pass Receipt'
    Reject-Receipt 'a Credential field' model { param($r)$r['credential']='Bearer fixture-secret' }
    Reject-Receipt 'a private absolute path' host { param($r)$r.reason='C:\Users\private\receipt.json' }

    $writerTokens=$null;$writerErrors=$null;[void][Management.Automation.Language.Parser]::ParseFile($writerPath,[ref]$writerTokens,[ref]$writerErrors)
    $writerText=Get-Content -LiteralPath $writerPath -Raw -Encoding utf8
    Check ($writerErrors.Count -eq 0 -and $writerText -match 'New-ReleaseProducerReceiptArtifact' -and $writerText -notmatch 'run-model-evals|run-host-benchmark') 'single Receipt Writer delegates validation and never runs a benchmark' 'Receipt Writer is invalid, bypasses the shared implementation, or runs a benchmark'
    foreach($kind in @('model','host')){$schema=Get-Content -LiteralPath (Join-Path $RepoRoot "schemas\release-$kind-receipt.schema.json") -Raw -Encoding utf8;Check ($schema|Test-Json) "$kind Receipt Schema is valid JSON" "$kind Receipt Schema is invalid JSON"}

    $workflowText=Get-Content -LiteralPath (Join-Path $RepoRoot '.github\workflows\validation.yml') -Raw -Encoding utf8
    $modelJob=[regex]::Match($workflowText,'(?ms)^  release-model:\s*$.*?(?=^  release-host:\s*$)').Value
    $hostJob=[regex]::Match($workflowText,'(?ms)^  release-host:\s*$.*?(?=^  release-full:\s*$)').Value
    $fullJob=[regex]::Match($workflowText,'(?ms)^  release-full:\s*$.*\z').Value
    $defaultPromotionCondition="github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/codex/harness-v2-default-promotion'"
    Check ($modelJob -match [regex]::Escape($defaultPromotionCondition) -and $modelJob -match 'write-release-producer-receipt\.ps1[^\r\n]+-Kind model\b' -and $modelJob -match 'release-model-receipt\.json' -and $hostJob -match [regex]::Escape($defaultPromotionCondition) -and $hostJob -match 'write-release-producer-receipt\.ps1[^\r\n]+-Kind host\b' -and $hostJob -match 'release-host-receipt\.json' -and $fullJob -match [regex]::Escape($defaultPromotionCondition) -and $fullJob -match 'write-release-full-receipt\.ps1' -and $fullJob -match 'release-(?:model|host|full)-receipt\.json') 'Release Workflow binds manual-only G09/G10 Producers and G11 aggregation' 'Release Workflow Producer or G11 Receipt binding is wrong'
    $runtimeReaders=@('scripts/task.ps1','scripts/lib/Harness.Recovery.psm1','scripts/lib/Harness.RuntimeDefault.psm1')
    Check (@($runtimeReaders|Where-Object{(Get-Content -LiteralPath (Join-Path $RepoRoot $_) -Raw -Encoding utf8)-match'release-(?:model|host|full)-receipt'}).Count -eq 0) 'Runtime Core, ordinary Status, and Runtime Default do not read Release Receipts' 'a Runtime path began reading Release Receipts'
    $unwiredPath=Join-Path $temp 'g11-unwired.json';[IO.File]::WriteAllText($unwiredPath,'{}',[Text.UTF8Encoding]::new($false));$g11=[ordered]@{'DP-G11-RELEASE-FULL'=[ordered]@{status='pass';evidence_contract='harness-release-full-receipt/v1';artifact_path=$unwiredPath;evidence_digest=Get-FileDigest $unwiredPath;source_revision=[string]$cleanSource.revision;producer_identity='forged-caller'}}
    $g11Reason='';try{& $module {param($Root,$Source,$Gates)Assert-HarnessRolloutEvidenceSetProvenance -RepoRoot $Root -ExpectedSource $Source -Gates $Gates} $RepoRoot $cleanSource $g11}catch{$g11Reason=[string]$_.Exception.Message}
    Check ($g11Reason -ceq 'rollout-evidence-release-full-gate-set-incomplete') 'G11 is wired and fails closed without its complete dependency Gate Set' 'G11 did not require its complete dependency Gate Set'

    foreach($check in $script:checks){Write-Output "[PASS] $check"}
    if($script:failures.Count -gt 0){foreach($failure in $script:failures){Write-Output "[FAIL] $failure"};Write-Output "STATUS: FAIL ($($script:failures.Count) failed, $($script:checks.Count) passed)";exit 1}
    Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
    exit 0
} finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}
