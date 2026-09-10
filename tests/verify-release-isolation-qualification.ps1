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
function Copy-Document([Collections.IDictionary]$Document) { return ($Document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String }
function Set-DocumentDigest([Collections.IDictionary]$Document,[ValidateSet('observation_digest','report_digest')][string]$Property) {
    $Document[$Property] = $null
    $Document[$Property] = Get-TextDigest ($Document | ConvertTo-Json -Depth 100 -Compress)
}
function Write-Document([string]$Path,[Collections.IDictionary]$Document) {
    [IO.File]::WriteAllText($Path,($Document | ConvertTo-Json -Depth 100 -Compress),[Text.UTF8Encoding]::new($false))
}
function Complete($Handle,[int]$TimeoutMilliseconds = 60000) {
    if (-not $Handle.Process.WaitForExit($TimeoutMilliseconds)) { $Handle.Process.Kill($true); throw 'release isolation verifier process timeout' }
    $result = [pscustomobject]@{ExitCode=$Handle.Process.ExitCode;StdOut=$Handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$Handle.StdErr.GetAwaiter().GetResult().Trim()}
    $Handle.Process.Dispose(); return $result
}
function Start-IsolationProcess {
    param([string]$ScriptPath,[string[]]$Arguments,[string]$ProfileRoot,[hashtable]$Environment=@{},[switch]$CreateDefaultAuth)
    if ($CreateDefaultAuth) {
        $defaultHome = Join-Path $ProfileRoot '.codex'; [void][IO.Directory]::CreateDirectory($defaultHome)
        [IO.File]::WriteAllText((Join-Path $defaultHome 'auth.json'),'{}',[Text.UTF8Encoding]::new($false))
    }
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Get-Process -Id $PID).Path;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
    $psi.Environment['USERPROFILE']=$ProfileRoot;$psi.Environment['HOME']=$ProfileRoot
    foreach($name in @('HOST_BENCHMARK_CODEX_HOME','CODEX_HOME','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_API_KEY','GITHUB_OUTPUT')){[void]$psi.Environment.Remove($name)}
    foreach($entry in $Environment.GetEnumerator()){$psi.Environment[[string]$entry.Key]=[string]$entry.Value}
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$ScriptPath)+$Arguments){$psi.ArgumentList.Add([string]$argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$psi;[void]$process.Start()
    return [pscustomobject]@{Process=$process;StdOut=$process.StandardOutput.ReadToEndAsync();StdErr=$process.StandardError.ReadToEndAsync()}
}

$boundaryPath = Join-Path $RepoRoot 'scripts\assert-release-runner-boundary.ps1'
$producerPath = Join-Path $RepoRoot 'scripts\generate-release-isolation-report.ps1'
$modulePath = Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1'
$observationSchemaPath = Join-Path $RepoRoot 'schemas\release-runner-observation.schema.json'
$reportSchemaPath = Join-Path $RepoRoot 'schemas\release-isolation-report.schema.json'
$workflowPath = Join-Path $RepoRoot '.github\workflows\validation.yml'
$workflowBefore = Get-FileDigest $workflowPath
$repoBefore = @(& git -C $RepoRoot -c core.quotepath=false status --porcelain=v1 --untracked-files=all)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('release-isolation-verifier-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $temp 'profile'
$dedicatedHome = Join-Path $temp 'dedicated-codex-home'
$script:module = $null

try {
    [void][IO.Directory]::CreateDirectory($profileRoot); [void][IO.Directory]::CreateDirectory($dedicatedHome)
    [IO.File]::WriteAllText((Join-Path $dedicatedHome 'auth.json'),'{}',[Text.UTF8Encoding]::new($false))
    foreach ($path in @($boundaryPath,$producerPath,$modulePath,$PSCommandPath)) {
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Check (@($errors).Count -eq 0) "$(Split-Path -Leaf $path) parses" "$(Split-Path -Leaf $path) has parse errors"
        Check (Test-FileHasUtf8Bom -Path $path) "$(Split-Path -Leaf $path) has UTF-8 BOM" "$(Split-Path -Leaf $path) lacks UTF-8 BOM"
    }
    foreach ($schemaPath in @($observationSchemaPath,$reportSchemaPath)) {
        $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100
        Check ([string]$schema['$schema'] -ceq 'http://json-schema.org/draft-07/schema#' -and $schema.additionalProperties -eq $false) "$(Split-Path -Leaf $schemaPath) is strict Draft 7" "$(Split-Path -Leaf $schemaPath) is not strict Draft 7"
    }
    $script:module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop

    $common = @('-ProducerRunnerLabel','release-producer-fixture','-AggregatorRunnerLabel','release-aggregator-fixture','-RunId','81234567','-RunAttempt','3','-RepoRoot',$RepoRoot,'-ProducerMode','test-only')
    $modelPath=Join-Path $temp 'model-observation.json';$hostPath=Join-Path $temp 'host-observation.json';$aggregatorPath=Join-Path $temp 'aggregator-observation.json'
    $modelOutput=Join-Path $temp 'model-output.txt';$hostOutput=Join-Path $temp 'host-output.txt'
    $modelRun=Complete (Start-IsolationProcess -ScriptPath $boundaryPath -ProfileRoot $profileRoot -Arguments (@('-Mode','producer','-Role','model-producer','-CodexHome',$dedicatedHome,'-ObservationOutputPath',$modelPath,'-GitHubOutputPath',$modelOutput)+$common))
    $hostRun=Complete (Start-IsolationProcess -ScriptPath $boundaryPath -ProfileRoot $profileRoot -Arguments (@('-Mode','producer','-Role','host-producer','-CodexHome',$dedicatedHome,'-ObservationOutputPath',$hostPath,'-GitHubOutputPath',$hostOutput)+$common))
    $aggregatorRun=Complete (Start-IsolationProcess -ScriptPath $boundaryPath -ProfileRoot $profileRoot -Arguments (@('-Mode','aggregator','-Role','aggregator','-ModelProducerAccountDigest',('sha256:'+('1'*64)),'-HostProducerAccountDigest',('sha256:'+('2'*64)),'-ObservationOutputPath',$aggregatorPath)+$common))
    Check ($modelRun.ExitCode -eq 0 -and $hostRun.ExitCode -eq 0 -and $aggregatorRun.ExitCode -eq 0 -and @($modelPath,$hostPath,$aggregatorPath | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 3) 'three test-only Runner Observations are emitted' 'one or more Runner Observations failed'
    $modelOutputText=Get-Content -LiteralPath $modelOutput -Raw -Encoding utf8;$hostOutputText=Get-Content -LiteralPath $hostOutput -Raw -Encoding utf8
    Check ($modelOutputText -match '^runner_account_digest=sha256:[0-9a-f]{64}\s*$' -and $hostOutputText -match '^runner_account_digest=sha256:[0-9a-f]{64}\s*$' -and $modelRun.StdOut -match '^RELEASE_RUNNER_BOUNDARY=producer\r?\nRUNNER_ACCOUNT_DIGEST=sha256:[0-9a-f]{64}$') 'Observation mode preserves the legacy producer output contract' 'Observation mode changed legacy producer output'

    $model=Get-Content -LiteralPath $modelPath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    $hostObservation=Get-Content -LiteralPath $hostPath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    $aggregator=Get-Content -LiteralPath $aggregatorPath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    $validated=@(
        & $script:module {param($R,$D)Assert-ReleaseRunnerObservation -RepoRoot $R -Document $D} $RepoRoot $model
        & $script:module {param($R,$D)Assert-ReleaseRunnerObservation -RepoRoot $R -Document $D} $RepoRoot $hostObservation
        & $script:module {param($R,$D)Assert-ReleaseRunnerObservation -RepoRoot $R -Document $D} $RepoRoot $aggregator
    )
    Check ((@($model.role,$hostObservation.role,$aggregator.role)-join '|') -ceq 'model-producer|host-producer|aggregator' -and @($model.status,$hostObservation.status,$aggregator.status|Where-Object{$_ -cne 'unavailable'}).Count -eq 0) 'Observation roles are exact and non-formal observations remain unavailable' 'Observation role or non-formal status is invalid'
    Check ([string]$model.codex_home.identity_digest -ceq [string]$hostObservation.codex_home.identity_digest -and [string]$aggregator.codex_home.mode -ceq 'absent' -and $null -eq $aggregator.codex_home.identity_digest -and [bool]$aggregator.credential_boundary.forbidden_process_credentials_absent -and [bool]$aggregator.credential_boundary.default_auth_absent) 'producer Home identity is consistent and aggregator is credential-blind' 'Observation Home or credential boundary is invalid'
    Check ([string]$model.workflow.run_id -ceq '81234567' -and [long]$model.workflow.run_attempt -eq 3 -and [string]$model.source_revision -ceq [string]$hostObservation.source_revision -and [string]$model.source_revision -ceq [string]$aggregator.source_revision) 'Observations bind the exact workflow and source identity' 'Observation workflow or source binding differs'
    $observationTexts=@($modelPath,$hostPath,$aggregatorPath|ForEach-Object{Get-Content -LiteralPath $_ -Raw -Encoding utf8})
    $privatePattern='(?:[A-Za-z]:[\\/]|\\\\|S-[0-9]+(?:-[0-9]+){2,}|(?i:access[_-]?token|api[_-]?key|bearer\s+|cookie\s*:|raw[ _-]?log))'
    Check (@($observationTexts|Where-Object{$_ -match $privatePattern}).Count -eq 0 -and @($validated.observation_run_id|Select-Object -Unique).Count -eq 3) 'Observations persist no path, SID, user, credential, or raw log and use unique run IDs' 'Observation leaked private content or reused a run ID'
    $digestValid=$true
    foreach($document in @($model,$hostObservation,$aggregator)){$saved=[string]$document.observation_digest;$document.observation_digest=$null;$actual=Get-TextDigest($document|ConvertTo-Json -Depth 100 -Compress);$document.observation_digest=$saved;if($saved-cne$actual){$digestValid=$false}}
    Check $digestValid 'all Observation digests recompute from canonical BOM-less JSON' 'an Observation digest does not recompute'

    $credentialSentinel=[guid]::NewGuid().ToString('N')
    $credentialRun=Complete (Start-IsolationProcess -ScriptPath $boundaryPath -ProfileRoot $profileRoot -Environment @{CODEX_ACCESS_TOKEN=$credentialSentinel} -Arguments (@('-Mode','aggregator','-ModelProducerAccountDigest',('sha256:'+('1'*64)),'-HostProducerAccountDigest',('sha256:'+('2'*64)))+$common))
    $authProfile=Join-Path $temp 'default-auth-profile';[void][IO.Directory]::CreateDirectory($authProfile)
    $authRun=Complete (Start-IsolationProcess -ScriptPath $boundaryPath -ProfileRoot $authProfile -CreateDefaultAuth -Arguments (@('-Mode','aggregator','-ModelProducerAccountDigest',('sha256:'+('1'*64)),'-HostProducerAccountDigest',('sha256:'+('2'*64)))+$common))
    Check ($credentialRun.ExitCode -ne 0 -and $credentialRun.StdErr -match 'CODEX_ACCESS_TOKEN' -and $credentialRun.StdErr -notmatch $credentialSentinel -and $authRun.ExitCode -ne 0 -and $authRun.StdErr -match 'default_codex_auth') 'credential variables and default auth fail closed without leaking values' 'aggregator credential rejection failed or leaked a value'

    # The local fixture account is intentionally shared; replace only the opaque aggregator digest so the portable three-account contract can be exercised.
    $aggregator.runner.account_digest='sha256:'+('3'*64);Set-DocumentDigest -Document $aggregator -Property observation_digest;Write-Document -Path $aggregatorPath -Document $aggregator
    $testReportPath=Join-Path $temp 'test-only-report.json'
    $testReportRun=Complete (Start-IsolationProcess -ScriptPath $producerPath -ProfileRoot $profileRoot -Arguments @('-RepoRoot',$RepoRoot,'-ModelProducerObservationPath',$modelPath,'-HostProducerObservationPath',$hostPath,'-AggregatorObservationPath',$aggregatorPath,'-OutputPath',$testReportPath,'-ProducerMode','test-only')) 120000
    $testReport=Get-Content -LiteralPath $testReportPath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    Check ($testReportRun.ExitCode -eq 0 -and [string]$testReport.status -ceq 'unavailable' -and [string]$testReport.reason -ceq 'non-formal-producer-mode' -and @($testReport.results.Keys|Where-Object{-not[bool]$testReport.results[$_]}).Count -eq 0) 'test-only aggregation proves the machine contract but remains unavailable' 'test-only aggregation failed or claimed formal authority'
    Check ((Get-Content -LiteralPath $testReportPath -Raw -Encoding utf8) -notmatch $privatePattern -and @($testReport.observations.Keys).Count -eq 3) 'Report stores only three sanitized Observation summaries' 'Report persisted private content or an invalid Observation set'

    $currentSource=Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
    $cleanSource=[ordered]@{revision=[string]$currentSource.revision;commit_tree_oid=[string]$currentSource.commit_tree_oid;object_format=[string]$currentSource.object_format;dirty=$false;status_entry_count=0L;status_digest=(Get-TextDigest '');state_digest=(Get-TextDigest ("{0}`n{1}`n{2}`n" -f $currentSource.revision,$currentSource.commit_tree_oid,$currentSource.object_format));state_basis='git-revision-tree-status/v1'}
    $formal=Copy-Document $testReport;$formal.source_revision=$cleanSource.revision;$formal.source_dirty=$false;$formal.source_state_stable=$true;$formal.source.commit_tree_oid=$cleanSource.commit_tree_oid;$formal.source.object_format=$cleanSource.object_format;$formal.source.start=$cleanSource;$formal.source.end=(Copy-Document $cleanSource);$formal.producer_mode='formal'
    foreach($summary in $formal.observations.Values){$summary.status='pass'}
    $formal.status='pass';$formal.reason='all-isolation-checks-passed';Set-DocumentDigest -Document $formal -Property report_digest
    function Write-ReportFixture([Collections.IDictionary]$Document,[string]$Name){$path=Join-Path $temp $Name;Write-Document -Path $path -Document $Document;return $path}
    function Invoke-G04Gate([string]$Path,[string]$CallerStatus='fail',[string]$CallerIdentity='caller-forged/v1',[string]$Digest=''){
        if([string]::IsNullOrWhiteSpace($Digest)){$Digest=Get-FileDigest $Path}
        $gates=[ordered]@{'DP-G04-CODEX-HOME-RUNNER-ISOLATION'=[ordered]@{status=$CallerStatus;evidence_contract='harness-release-isolation-report/v1';artifact_path=$Path;evidence_digest=$Digest;source_revision=[string]$cleanSource.revision;producer_identity=$CallerIdentity}}
        [void](& $script:module {param($G,$R,$S)Assert-HarnessRolloutEvidenceSetProvenance -Gates $G -RepoRoot $R -ExpectedSource $S} $gates $RepoRoot $cleanSource)
        return $gates['DP-G04-CODEX-HOME-RUNNER-ISOLATION']
    }
    $formalPath=Write-ReportFixture $formal 'formal-pass.json';$derivedPass=Invoke-G04Gate -Path $formalPath
    Check ([string]$derivedPass.status -ceq 'pass' -and [string]$derivedPass.producer_identity -ceq 'release-isolation-qualification/v1') 'strict formal fixture derives G04 pass and fixed producer identity' 'formal fixture did not derive G04 pass'
    $reasonGate=[ordered]@{'DP-G04-CODEX-HOME-RUNNER-ISOLATION'=[ordered]@{status='pass';evidence_contract='harness-release-isolation-report/v1';artifact_path=$formalPath;evidence_digest=(Get-FileDigest $formalPath);source_revision=[string]$cleanSource.revision;producer_identity='caller-forged/v1';reason='caller-forged-pass'}}
    $callerReasonRejected=$false;try{[void](&$script:module {param($G,$R,$S)Assert-HarnessRolloutEvidenceSetProvenance -Gates $G -RepoRoot $R -ExpectedSource $S} $reasonGate $RepoRoot $cleanSource)}catch{$callerReasonRejected=$true}
    Check $callerReasonRejected 'G04 rejects caller reason as non-authoritative extra input' 'G04 accepted caller reason as authority'

    $formalFail=Copy-Document $formal;$formalFail.observations.model_producer.status='fail';$formalFail.status='fail';$formalFail.reason='isolation-check-failed';Set-DocumentDigest $formalFail report_digest
    $failPath=Write-ReportFixture $formalFail 'formal-fail.json';$derivedFail=Invoke-G04Gate -Path $failPath -CallerStatus pass
    $formalUnavailable=Copy-Document $formal;$formalUnavailable.observations.host_producer.status='unavailable';$formalUnavailable.status='unavailable';$formalUnavailable.reason='isolation-unavailable';Set-DocumentDigest $formalUnavailable report_digest
    $unavailablePath=Write-ReportFixture $formalUnavailable 'formal-unavailable.json';$derivedUnavailable=Invoke-G04Gate -Path $unavailablePath -CallerStatus pass
    Check ([string]$derivedFail.status -ceq 'fail' -and [string]$derivedUnavailable.status -ceq 'unavailable') 'Report content overrides caller-forged pass for formal fail and unavailable' 'caller-forged pass overrode Report authority'
    foreach($mode in @('test-only','diagnostic-smoke')){
        $nonFormal=Copy-Document $formal;$nonFormal.producer_mode=$mode;foreach($summary in $nonFormal.observations.Values){$summary.status='unavailable'};$nonFormal.status='unavailable';$nonFormal.reason='non-formal-producer-mode';Set-DocumentDigest $nonFormal report_digest
        $derived=Invoke-G04Gate -Path (Write-ReportFixture $nonFormal "$mode-report.json") -CallerStatus pass
        Check ([string]$derived.status -ceq 'unavailable') "$mode Report cannot form G04 pass" "$mode Report formed G04 pass"
    }

    function Expect-ReportRejected([string]$Name,[scriptblock]$Mutation,[switch]$KeepDigest){
        $document=Copy-Document $formal;& $Mutation $document;if(-not$KeepDigest){Set-DocumentDigest $document report_digest};$path=Write-ReportFixture $document ("negative-$Name.json");$rejected=$false
        try{$null=Invoke-G04Gate -Path $path -CallerStatus pass}catch{$rejected=$true}
        Check $rejected "Report rejects $Name" "Report accepted $Name"
    }
    Expect-ReportRejected 'unknown field' {param($d)$d.unexpected='value'}
    Expect-ReportRejected 'wrong schema' {param($d)$d.schema_version='unsupported/v9'}
    Expect-ReportRejected 'report digest mismatch' {param($d)$d.reason='isolation-check-failed'} -KeepDigest
    Expect-ReportRejected 'stale source' {param($d)$d.source_revision='0'*40}
    Expect-ReportRejected 'wrong tree' {param($d)$d.source.commit_tree_oid='0'*40}
    Expect-ReportRejected 'dirty or unstable source claiming pass' {param($d)$d.source_dirty=$true}
    Expect-ReportRejected 'wrong role' {param($d)$d.observations.model_producer.role='host-producer'}
    Expect-ReportRejected 'reused Observation run ID' {param($d)$d.observations.host_producer.observation_run_id=$d.observations.model_producer.observation_run_id}
    Expect-ReportRejected 'reused Observation digest' {param($d)$d.observations.host_producer.observation_digest=$d.observations.model_producer.observation_digest}
    Expect-ReportRejected 'different Producer labels' {param($d)$d.observations.host_producer.runner_label_digest='sha256:'+('4'*64)}
    Expect-ReportRejected 'label-only aggregator identity substitute' {param($d)$d.observations.aggregator.runner_label_digest=$d.observations.model_producer.runner_label_digest}
    Expect-ReportRejected 'aggregator account equals model' {param($d)$d.observations.aggregator.account_digest=$d.observations.model_producer.account_digest}
    Expect-ReportRejected 'aggregator account equals host' {param($d)$d.observations.aggregator.account_digest=$d.observations.host_producer.account_digest}
    Expect-ReportRejected 'Producer Home differs' {param($d)$d.observations.host_producer.codex_home_identity_digest='sha256:'+('5'*64)}
    Expect-ReportRejected 'Producer Home absent' {param($d)$d.observations.model_producer.codex_home_identity_digest=$null}
    Expect-ReportRejected 'Producer auth absent' {param($d)$d.results.producer_auth_present=$false}
    Expect-ReportRejected 'Aggregator Credential present' {param($d)$d.results.aggregator_credential_blind=$false}
    Expect-ReportRejected 'test-only masquerades as formal pass' {param($d)$d.producer_mode='test-only'}
    Expect-ReportRejected 'private SID content' {param($d)$d.private_identity=('S-'+(@(1,5,21,100,200,300)-join'-'))}
    Expect-ReportRejected 'user name content' {param($d)$d.private_identity=[Environment]::UserName}
    Expect-ReportRejected 'credential content' {param($d)$d.private_identity=('api'+'_'+'key')}
    Expect-ReportRejected 'private path content' {param($d)$d.private_identity=([char]67+':'+[IO.Path]::DirectorySeparatorChar+'private'+[IO.Path]::DirectorySeparatorChar+'identity')}
    Expect-ReportRejected 'raw log content' {param($d)$d.private_identity='raw log: unavailable'}

    function Expect-ObservationRejected([string]$Name,[Collections.IDictionary]$Base,[scriptblock]$Mutation,[switch]$KeepDigest){
        $document=Copy-Document $Base;&$Mutation $document;if(-not$KeepDigest){Set-DocumentDigest $document observation_digest};$rejected=$false
        try{$null=&$script:module {param($R,$D)Assert-ReleaseRunnerObservation -RepoRoot $R -Document $D} $RepoRoot $document}catch{$rejected=$true}
        Check $rejected "Observation rejects $Name" "Observation accepted $Name"
    }
    $formalObservation=Copy-Document $model;$formalObservation.producer_mode='formal';$formalObservation.status='pass';$formalObservation.reason='all-boundary-checks-passed';$formalObservation.source_revision=$cleanSource.revision;$formalObservation.source_dirty=$false;$formalObservation.source_state_stable=$true;$formalObservation.source.commit_tree_oid=$cleanSource.commit_tree_oid;$formalObservation.source.object_format=$cleanSource.object_format;$formalObservation.source.start=$cleanSource;$formalObservation.source.end=(Copy-Document $cleanSource);Set-DocumentDigest $formalObservation observation_digest
    Expect-ObservationRejected 'unknown field' $formalObservation {param($d)$d.unexpected='value'}
    Expect-ObservationRejected 'wrong schema' $formalObservation {param($d)$d.schema_version='unsupported/v9'}
    Expect-ObservationRejected 'digest mismatch' $formalObservation {param($d)$d.status='fail'} -KeepDigest
    Expect-ObservationRejected 'stale source' $formalObservation {param($d)$d.source_revision='0'*40}
    Expect-ObservationRejected 'wrong tree' $formalObservation {param($d)$d.source.commit_tree_oid='0'*40}
    Expect-ObservationRejected 'dirty source claiming pass' $formalObservation {param($d)$d.source_dirty=$true}
    Expect-ObservationRejected 'wrong role' $formalObservation {param($d)$d.role='aggregator'}
    Expect-ObservationRejected 'Producer Home absent' $formalObservation {param($d)$d.codex_home.mode='absent';$d.codex_home.identity_digest=$null;$d.codex_home.auth_status='absent'}
    Expect-ObservationRejected 'Producer auth absent' $formalObservation {param($d)$d.codex_home.auth_status='absent'}
    Expect-ObservationRejected 'Aggregator Home present' $aggregator {param($d)$d.codex_home.mode='dedicated-auth-home';$d.codex_home.identity_digest='sha256:'+('6'*64);$d.codex_home.auth_status='present'}
    Expect-ObservationRejected 'Aggregator Credential present' $aggregator {param($d)$d.credential_boundary.forbidden_process_credentials_absent=$false}
    Expect-ObservationRejected 'Aggregator default auth present' $aggregator {param($d)$d.credential_boundary.default_auth_absent=$false}
    $strictByteFailures=$true
    foreach($bytes in @([Text.UTF8Encoding]::new($false).GetBytes('{'),([byte[]](0xEF,0xBB,0xBF)+[Text.UTF8Encoding]::new($false).GetBytes('{}')),[Text.UTF8Encoding]::new($false).GetBytes('{"schema_version":"a","schema_version":"b"}'))){try{$null=&$script:module {param($B)ConvertFrom-InstalledDesktopEvidenceBytes -Bytes $B} $bytes;$strictByteFailures=$false}catch{}}
    Check $strictByteFailures 'strict JSON rejects malformed, BOM, and duplicate-key Observation bytes' 'strict JSON accepted malformed, BOM, or duplicate-key bytes'

    $missingRejected=$false;try{$null=&$script:module {param($R,$M,$H,$A,$O)New-ReleaseIsolationReportArtifact -RepoRoot $R -ModelProducerObservationPath $M -HostProducerObservationPath $H -AggregatorObservationPath $A -OutputPath $O -ProducerMode test-only} $RepoRoot (Join-Path $temp 'missing.json') $hostPath $aggregatorPath (Join-Path $temp 'missing-report.json')}catch{$missingRejected=$true}
    $relativeRejected=$false;try{$null=&$script:module {param($R,$M,$H,$A,$O)New-ReleaseIsolationReportArtifact -RepoRoot $R -ModelProducerObservationPath $M -HostProducerObservationPath $H -AggregatorObservationPath $A -OutputPath $O -ProducerMode test-only} $RepoRoot 'relative.json' $hostPath $aggregatorPath (Join-Path $temp 'relative-report.json')}catch{$relativeRejected=$true}
    $reusedRejected=$false;try{$null=&$script:module {param($R,$M,$H,$A,$O)New-ReleaseIsolationReportArtifact -RepoRoot $R -ModelProducerObservationPath $M -HostProducerObservationPath $H -AggregatorObservationPath $A -OutputPath $O -ProducerMode test-only} $RepoRoot $modelPath $modelPath $aggregatorPath (Join-Path $temp 'reused-report.json')}catch{$reusedRejected=$true}
    Check ($missingRejected -and $relativeRejected -and $reusedRejected) 'Producer rejects missing, relative, and reused Observation artifacts' 'Producer accepted missing, relative, or reused Observation artifacts'
    $existingOutputRun=Complete (Start-IsolationProcess -ScriptPath $producerPath -ProfileRoot $profileRoot -Arguments @('-RepoRoot',$RepoRoot,'-ModelProducerObservationPath',$modelPath,'-HostProducerObservationPath',$hostPath,'-AggregatorObservationPath',$aggregatorPath,'-OutputPath',$testReportPath,'-ProducerMode','test-only'))
    $protectedOutput=Join-Path $dedicatedHome 'forbidden-report.json';$protectedOutputRun=Complete (Start-IsolationProcess -ScriptPath $producerPath -ProfileRoot $profileRoot -Environment @{HOST_BENCHMARK_CODEX_HOME=$dedicatedHome} -Arguments @('-RepoRoot',$RepoRoot,'-ModelProducerObservationPath',$modelPath,'-HostProducerObservationPath',$hostPath,'-AggregatorObservationPath',$aggregatorPath,'-OutputPath',$protectedOutput,'-ProducerMode','test-only'))
    $unignoredOutput=Join-Path $RepoRoot 'g04-unignored-output.json';$unignoredOutputRun=Complete (Start-IsolationProcess -ScriptPath $producerPath -ProfileRoot $profileRoot -Arguments @('-RepoRoot',$RepoRoot,'-ModelProducerObservationPath',$modelPath,'-HostProducerObservationPath',$hostPath,'-AggregatorObservationPath',$aggregatorPath,'-OutputPath',$unignoredOutput,'-ProducerMode','test-only'))
    Check ($existingOutputRun.ExitCode -ne 0 -and $existingOutputRun.StdErr -match 'release-output-already-exists' -and $protectedOutputRun.ExitCode -ne 0 -and -not(Test-Path -LiteralPath $protectedOutput) -and $unignoredOutputRun.ExitCode -ne 0 -and -not(Test-Path -LiteralPath $unignoredOutput)) 'Producer refuses overwrite, Credential Home, and unignored source outputs before writing' 'Producer output boundary accepted an unsafe target'

    function Expect-GeneratorIdentityRejected([string]$Name,[Collections.IDictionary]$MutatedHost,[Collections.IDictionary]$MutatedAggregator){
        $hostFixture=Join-Path $temp ("host-$Name.json");$aggregatorFixture=Join-Path $temp ("aggregator-$Name.json");Write-Document $hostFixture $MutatedHost;Write-Document $aggregatorFixture $MutatedAggregator;$output=Join-Path $temp ("report-$Name.json");$rejected=$false
        try{$result=&$script:module {param($R,$M,$H,$A,$O)New-ReleaseIsolationReportArtifact -RepoRoot $R -ModelProducerObservationPath $M -HostProducerObservationPath $H -AggregatorObservationPath $A -OutputPath $O -ProducerMode test-only} $RepoRoot $modelPath $hostFixture $aggregatorFixture $output;if([string]$result.status -ceq 'fail'){$rejected=$true}}catch{$rejected=$true}
        Check $rejected "Producer prevents $Name from passing" "Producer accepted $Name"
    }
    $mutatedHost=Copy-Document $hostObservation;$mutatedHost.observation_run_id=$model.observation_run_id;Set-DocumentDigest $mutatedHost observation_digest;Expect-GeneratorIdentityRejected 'reused-observation-run-id' $mutatedHost $aggregator
    $mutatedHost=Copy-Document $hostObservation;$mutatedHost.workflow.run_id='81234568';Set-DocumentDigest $mutatedHost observation_digest;Expect-GeneratorIdentityRejected 'different-workflow-run-id' $mutatedHost $aggregator
    $mutatedHost=Copy-Document $hostObservation;$mutatedHost.workflow.run_attempt=4L;Set-DocumentDigest $mutatedHost observation_digest;Expect-GeneratorIdentityRejected 'different-run-attempt' $mutatedHost $aggregator
    $mutatedHost=Copy-Document $hostObservation;$mutatedHost.runner.label_digest='sha256:'+('4'*64);Set-DocumentDigest $mutatedHost observation_digest;Expect-GeneratorIdentityRejected 'different-producer-labels' $mutatedHost $aggregator
    $mutatedAggregator=Copy-Document $aggregator;$mutatedAggregator.runner.label_digest=$model.runner.label_digest;Set-DocumentDigest $mutatedAggregator observation_digest;Expect-GeneratorIdentityRejected 'same-producer-aggregator-label' $hostObservation $mutatedAggregator
    $mutatedAggregator=Copy-Document $aggregator;$mutatedAggregator.runner.account_digest=$model.runner.account_digest;Set-DocumentDigest $mutatedAggregator observation_digest;Expect-GeneratorIdentityRejected 'aggregator-model-account-alias' $hostObservation $mutatedAggregator
    $mutatedHost=Copy-Document $hostObservation;$mutatedHost.codex_home.identity_digest='sha256:'+('5'*64);Set-DocumentDigest $mutatedHost observation_digest;Expect-GeneratorIdentityRejected 'different-producer-Home' $mutatedHost $aggregator

    $boundaryCases=$true
    try{
        try{$null=Invoke-G04Gate -Path 'relative.json'}catch{};if($?){ }
        $rawMismatch=$false;try{$null=Invoke-G04Gate -Path $formalPath -Digest ('sha256:'+('0'*64))}catch{$rawMismatch=$true}
        $oversized=Join-Path $temp 'oversized.json';[IO.File]::WriteAllBytes($oversized,[byte[]]::new(1MB+1));$oversizedRejected=$false;try{$null=Invoke-G04Gate -Path $oversized} catch{$oversizedRejected=$true}
        $hardlinkSource=Join-Path $temp 'hardlink-source.json';[IO.File]::Copy($formalPath,$hardlinkSource);$hardlinkAlias=Join-Path $temp 'hardlink-alias.json';$null=New-Item -ItemType HardLink -Path $hardlinkAlias -Target $hardlinkSource -ErrorAction Stop;$hardlinkRejected=$false;try{$null=Invoke-G04Gate -Path $hardlinkAlias}catch{$hardlinkRejected=$true}
        $adsPath=Join-Path $temp 'ads-report.json';[IO.File]::Copy($formalPath,$adsPath);[IO.File]::WriteAllText("$adsPath`:extra",'x');$adsRejected=$false;try{$null=Invoke-G04Gate -Path $adsPath}catch{$adsRejected=$true}
        $realDirectory=Join-Path $temp 'real-report';[void][IO.Directory]::CreateDirectory($realDirectory);$realReport=Join-Path $realDirectory 'report.json';[IO.File]::Copy($formalPath,$realReport);$junction=Join-Path $temp 'report-junction';$null=New-Item -ItemType Junction -Path $junction -Target $realDirectory -ErrorAction Stop;$reparseRejected=$false;try{$null=Invoke-G04Gate -Path (Join-Path $junction 'report.json')}catch{$reparseRejected=$true}
        $boundaryCases=$rawMismatch-and$oversizedRejected-and$hardlinkRejected-and$adsRejected-and$reparseRejected
    }catch{$boundaryCases=$false}
    Check $boundaryCases 'Adapter rejects raw mismatch, oversized, hardlink, ADS, and reparse artifacts' 'an Artifact boundary case was accepted or unavailable'

    Check ((Get-FileDigest $workflowPath) -ceq $workflowBefore -and (Get-Content -LiteralPath $workflowPath -Raw) -notmatch 'generate-release-isolation-report|release-runner-observation') 'Release Workflow remains byte-identical and does not consume G04' 'Release Workflow changed or consumed G04'
    $runtimeReaders=@('scripts/task.ps1','scripts/lib/Harness.Recovery.psm1','scripts/lib/Harness.RuntimeDefault.psm1')
    Check (@($runtimeReaders|Where-Object{(Get-Content -LiteralPath (Join-Path $RepoRoot $_) -Raw -Encoding utf8)-match 'release-isolation-report|DP-G04-CODEX-HOME-RUNNER-ISOLATION'}).Count -eq 0) 'Runtime Core, ordinary Status, and Runtime Default do not read G04' 'a Runtime path began reading G04 evidence'
} finally {
    if ($null -ne $script:module) { Remove-Module $script:module.Name -ErrorAction Ignore }
    Remove-DirectoryWithRetry -Path $temp
}

$repoAfter = @(& git -C $RepoRoot -c core.quotepath=false status --porcelain=v1 --untracked-files=all)
Check (@(Compare-Object $repoBefore $repoAfter).Count -eq 0) 'verifier and producers perform no repository writes' 'verifier or producer changed repository state'
foreach($item in $script:checks){Write-Output "[PASS] $item"}
foreach($item in $script:failures){Write-Output "[FAIL] $item"}
if($script:failures.Count){Write-Output "STATUS: FAIL ($($script:failures.Count) failed)";exit 1}
Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
exit 0
