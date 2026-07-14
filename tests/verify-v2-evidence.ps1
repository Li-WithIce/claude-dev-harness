[CmdletBinding()]
param([string]$RepoRoot='')

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(!$RepoRoot){$RepoRoot=Split-Path -Parent $PSScriptRoot};$RepoRoot=(Resolve-Path $RepoRoot).Path
. (Join-Path $RepoRoot 'tests/fixture-test-common.ps1')
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.Evidence.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.AtomicWrite.psm1') -Force
$taskScript=Join-Path $RepoRoot 'scripts/task.ps1';$script:passes=[Collections.Generic.List[string]]::new();$script:failures=[Collections.Generic.List[string]]::new()
function Check($Condition,$Pass,$Fail){if($Condition){$script:passes.Add($Pass)}else{$script:failures.Add($Fail)}}
function Snapshot($Root){return @(Get-ChildItem $Root -Force -Recurse|%{if($_.PSIsContainer){'D|'+$_.FullName}else{'F|'+$_.FullName+'|'+(Get-FileHash $_.FullName).Hash}}|Sort-Object)}
function Same($Before,$After,$Pass,$Fail){Check (@(Compare-Object @($Before) @($After)).Count -eq 0) $Pass $Fail}
function Start-Cli($Workspace,[string[]]$Arguments,$Fault=''){$old=$env:HARNESS_PROTOCOL;$oldFault=$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP;try{$env:HARNESS_PROTOCOL='v2';if($Fault){$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP=$Fault}else{Remove-Item Env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP -ErrorAction Ignore};return Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $taskScript -Arguments ($Arguments+@('-RepoRoot',$RepoRoot,'-WorkspaceRoot',$Workspace))}finally{if($null-eq$old){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$old};if($null-eq$oldFault){Remove-Item Env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP -ErrorAction Ignore}else{$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP=$oldFault}}}
function Complete-Cli($Handle){if(-not$Handle.Process.WaitForExit(30000)){$Handle.Process.Kill($true);throw 'CLI timeout'};$r=[pscustomobject]@{ExitCode=$Handle.Process.ExitCode;StdOut=$Handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$Handle.StdErr.GetAwaiter().GetResult().Trim()};$Handle.Process.Dispose();return $r}
function Invoke-Cli($Workspace,[string[]]$Arguments,$Fault=''){return Complete-Cli (Start-Cli $Workspace $Arguments $Fault)}
function Read-Output($Result){if($Result.StdOut){return $Result.StdOut|ConvertFrom-Json -Depth 50 -DateKind String};return $null}

function Write-Contract($Workspace,$TaskId){
    $body=[ordered]@{schema_version='requirement-contract/v1';task_id=$TaskId;goal="Verify $TaskId.";acceptance=@('Required behavior passes.');in_scope=@('v2 Evidence');out_of_scope=@('v1 TEST');product_constraints=@('No false pass.');product_decisions=@();unresolved_product_decisions=@();source_authority=@('current-user-message')}
    $contract=[ordered]@{};foreach($key in $body.Keys){$contract[$key]=$body[$key]};$contract.digest=Get-HarnessSha256Text -Content ($body|ConvertTo-Json -Depth 30 -Compress)
    $relative="contracts/$TaskId.json";$path=Join-Path $Workspace $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,(($contract|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Path=$relative;Digest=$contract.digest}
}
function Write-JsonFile($Workspace,$Relative,$Value){$path=Join-Path $Workspace $Relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,(($Value|ConvertTo-Json -Depth 40)+"`n"),[Text.UTF8Encoding]::new($false))}

function New-EvidenceFixture($Workspace,$TaskId,$ContractDigest,$Mode){
    $recordRelative=".harness/evidence/$TaskId-$Mode.txt";$recordPath=Join-Path $Workspace $recordRelative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $recordPath));[IO.File]::WriteAllText($recordPath,("$Mode`n"),[Text.UTF8Encoding]::new($false));$digest='sha256:'+((Get-FileHash $recordPath).Hash.ToLowerInvariant())
    $satisfied=@();$notVerified=@();$blocked=@();$gaps=@();$conclusion=$Mode
    if($Mode -in @('pass','false-pass','dirty')){$satisfied=@('AC-1');$conclusion='pass'}elseif($Mode-ceq'fail'){$satisfied=@('AC-1')}elseif($Mode-ceq'blocked'){$blocked=@('AC-1');$gaps=@([ordered]@{id='AC-1';status='blocked';reason='external dependency'})}else{$notVerified=@('AC-1');$gaps=@([ordered]@{id='AC-1';status='not-verified';reason='not run'});$conclusion='partial'}
    if($Mode-ceq'blocked'){$record=[ordered]@{type='inspection';method='external-check';result='blocked';executed_at=[DateTimeOffset]::UtcNow.ToString('o');evidence_path=$recordRelative;digest=$digest;covers=@()}}
    elseif($Mode-ceq'partial'){$record=[ordered]@{type='inspection';method='manual-check';result='partial';executed_at=[DateTimeOffset]::UtcNow.ToString('o');evidence_path=$recordRelative;digest=$digest;covers=@()}}
    else{$exitCode=if($Mode-in @('fail','false-pass')){7}else{0};$record=[ordered]@{type='command';command="fixture-$Mode";cwd='.';exit_code=$exitCode;executed_at=[DateTimeOffset]::UtcNow.ToString('o');evidence_path=$recordRelative;digest=$digest;covers=@('AC-1')}}
    $document=[ordered]@{schema_version='evidence/v1';task_id=$TaskId;task_version=3;contract_digest=$ContractDigest;revision=('dirty:'+'0'*64);records=@($record);coverage=[ordered]@{satisfied=$satisfied;not_verified=$notVerified;blocked=$blocked};gaps=$gaps;conclusion=$conclusion}
    $inputRelative="evidence-inputs/$TaskId-$Mode.json";Write-JsonFile $Workspace $inputRelative $document
    $document.revision=Get-HarnessEvidenceRevision -WorkspaceRoot $Workspace -ContractDigest $ContractDigest -Evidence $document -EvidenceInputPath $inputRelative -EvidenceOutputPath "docs/tasks/$TaskId/evidence.json";Write-JsonFile $Workspace $inputRelative $document
    return [pscustomobject]@{Path=$inputRelative;Document=$document;RecordPath=$recordRelative}
}
function Start-TaskVerifying($Workspace,$TaskId,$ContractPath,[switch]$Activate){$args=@('create','-TaskId',$TaskId,'-Contract',$ContractPath,'-AsJson');if($Activate){$args+= '-ActivateCurrent'};$created=Invoke-Cli $Workspace $args;$running=Invoke-Cli $Workspace @('transition','-TaskId',$TaskId,'-ExpectedVersion','1','-To','running','-AsJson');$verifying=Invoke-Cli $Workspace @('transition','-TaskId',$TaskId,'-ExpectedVersion','2','-To','verifying','-AsJson');if($created.ExitCode-or$running.ExitCode-or$verifying.ExitCode){throw "failed to prepare verifying task: $TaskId"}}

$repoBefore=@(& git -C $RepoRoot status --porcelain --untracked-files=all);$temp=Join-Path ([IO.Path]::GetTempPath()) ('v2-evidence-'+[guid]::NewGuid().ToString('N'));$workspace=Join-Path $temp 'workspace';$outside=Join-Path $temp 'outside';[void][IO.Directory]::CreateDirectory($workspace);[void][IO.Directory]::CreateDirectory($outside)
[IO.File]::WriteAllText((Join-Path $workspace '.gitignore'),".assistant/runtime/`n.harness/evidence/`nevidence-inputs/`ndocs/tasks/*/evidence.json`n",[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $workspace 'source.txt'),"baseline`n",[Text.UTF8Encoding]::new($false))
$contracts=@{};$taskIds=@('pass-task','false-pass-task','stale-task','fail-task','blocked-task','partial-task','dirty-task','escape-task','digest-task','crash-task')
foreach($taskId in $taskIds){$contracts[$taskId]=Write-Contract $workspace $taskId}
git -C $workspace init -q;git -C $workspace config user.email harness@example.invalid;git -C $workspace config user.name Harness;git -C $workspace config core.autocrlf false;git -C $workspace add .;git -C $workspace commit -qm baseline;$head=(git -C $workspace rev-parse HEAD).Trim()
foreach($file in @('scripts/lib/Harness.Evidence.psm1','scripts/lib/Harness.TaskState.psm1','scripts/task.ps1','tests/verify-v2-evidence.ps1')){$path=Join-Path $RepoRoot $file;$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq 0) "$file parses" "$file parse failed";Check (Test-FileHasUtf8Bom $path) "$file has UTF-8 BOM" "$file lacks UTF-8 BOM"}
$exports=@(Get-Command -Module Harness.Evidence|Select-Object -ExpandProperty Name|Sort-Object);Check (@(Compare-Object @('Get-HarnessEvidenceRevision','Resolve-HarnessEvidence') $exports).Count-eq 0) 'Evidence exports are exact' 'Evidence exports drifted'
foreach($taskId in $taskIds){Start-TaskVerifying $workspace $taskId $contracts[$taskId].Path -Activate:($taskId-ceq'pass-task')}

$passEvidence=New-EvidenceFixture $workspace 'pass-task' $contracts['pass-task'].Digest 'pass';Check ($passEvidence.Document.revision-ceq$head) 'clean Evidence binds the current commit' 'clean Evidence revision is stale';$result=Invoke-Cli $workspace @('verify','-TaskId','pass-task','-ExpectedVersion','3','-Evidence',$passEvidence.Path,'-AsJson');$passResult=Read-Output $result
$artifact=Join-Path $workspace 'docs/tasks/pass-task/evidence.json';$status=Read-Output (Invoke-Cli $workspace @('status','-TaskId','pass-task','-AsJson'))
Check ($result.ExitCode-eq 0-and$passResult.conclusion-ceq'pass'-and$passResult.task.status-ceq'done'-and$passResult.pointer_action-ceq'cleared'-and-not(Test-Path (Join-Path $workspace '.assistant/runtime/current.json'))) 'pass Evidence closes active task and clears current' 'pass Evidence did not close active task'
Check ((Test-Path $artifact)-and('sha256:'+((Get-FileHash $artifact).Hash.ToLowerInvariant()))-ceq$passResult.evidence_digest-and$status.event_count-eq 5) 'pass Evidence artifact and audit events are durable' 'pass Evidence artifact or events are invalid'
Check (-not(Test-Path (Join-Path $workspace '.assistant/运行时'))-and-not(Test-Path (Join-Path $workspace 'docs/tasks/pass-task/test.md'))) 'Evidence does not write v1 runtime or test.md' 'Evidence changed v1 surfaces'
$falsePass=New-EvidenceFixture $workspace 'false-pass-task' $contracts['false-pass-task'].Digest 'false-pass';$snapshot=Snapshot $workspace;$result=Invoke-Cli $workspace @('verify','-TaskId','false-pass-task','-ExpectedVersion','3','-Evidence',$falsePass.Path,'-AsJson')
Check ($result.ExitCode-eq 2-and-not$result.StdOut-and$result.StdErr-match'declared=pass derived=fail') 'pass with nonzero command is rejected' 'nonzero command was accepted as pass';Same $snapshot (Snapshot $workspace) 'false pass rejection is zero-write' 'false pass rejection wrote state'

$stale=New-EvidenceFixture $workspace 'stale-task' $contracts['stale-task'].Digest 'pass';$stale.Document.contract_digest='sha256:'+('0'*64);Write-JsonFile $workspace $stale.Path $stale.Document;$snapshot=Snapshot $workspace;$result=Invoke-Cli $workspace @('verify','-TaskId','stale-task','-ExpectedVersion','3','-Evidence',$stale.Path,'-AsJson')
Check ($result.ExitCode-eq 2-and$result.StdErr-match'contract_digest is stale') 'stale Contract digest is rejected' 'stale Contract digest was accepted';Same $snapshot (Snapshot $workspace) 'stale Contract rejection is zero-write' 'stale Contract rejection wrote state'
$badDigest=New-EvidenceFixture $workspace 'digest-task' $contracts['digest-task'].Digest 'pass';$badDigest.Document.records[0].digest='sha256:'+('0'*64);Write-JsonFile $workspace $badDigest.Path $badDigest.Document;$snapshot=Snapshot $workspace;$result=Invoke-Cli $workspace @('verify','-TaskId','digest-task','-ExpectedVersion','3','-Evidence',$badDigest.Path,'-AsJson')
Check ($result.ExitCode-eq 2-and$result.StdErr-match'record digest mismatch') 'record digest mismatch is rejected' 'record digest mismatch was accepted';Same $snapshot (Snapshot $workspace) 'record digest rejection is zero-write' 'record digest rejection wrote state'
$escape=New-EvidenceFixture $workspace 'escape-task' $contracts['escape-task'].Digest 'pass';$escape.Document.records[0].evidence_path='../outside.txt';Write-JsonFile $workspace $escape.Path $escape.Document;$snapshot=Snapshot $workspace;$result=Invoke-Cli $workspace @('verify','-TaskId','escape-task','-ExpectedVersion','3','-Evidence',$escape.Path,'-AsJson')
Check ($result.ExitCode-eq 2-and$result.StdErr-match'schema') 'record evidence path escape is rejected' 'record evidence path escape was accepted';Same $snapshot (Snapshot $workspace) 'record path rejection is zero-write' 'record path rejection wrote state'
[IO.File]::Copy((Join-Path $workspace $passEvidence.Path),(Join-Path $outside 'evidence.json'));$snapshot=Snapshot $workspace;$result=Invoke-Cli $workspace @('verify','-TaskId','escape-task','-ExpectedVersion','3','-Evidence',(Join-Path $outside 'evidence.json'),'-AsJson')
Check ($result.ExitCode-eq 2-and$result.StdErr-match'escapes WorkspaceRoot') 'Evidence input path escape is rejected' 'Evidence input path escape was accepted';Same $snapshot (Snapshot $workspace) 'input path rejection is zero-write' 'input path rejection wrote state'

$failEvidence=New-EvidenceFixture $workspace 'fail-task' $contracts['fail-task'].Digest 'fail';$result=Invoke-Cli $workspace @('verify','-TaskId','fail-task','-ExpectedVersion','3','-Evidence',$failEvidence.Path,'-AsJson');$value=Read-Output $result
Check ($result.ExitCode-eq 0-and$value.conclusion-ceq'fail'-and$value.task.status-ceq'running'-and$value.task.version-eq 4) 'fail Evidence returns task to running' 'fail Evidence completed or stranded task'
$blockedEvidence=New-EvidenceFixture $workspace 'blocked-task' $contracts['blocked-task'].Digest 'blocked';$result=Invoke-Cli $workspace @('verify','-TaskId','blocked-task','-ExpectedVersion','3','-Evidence',$blockedEvidence.Path,'-AsJson');$value=Read-Output $result
Check ($result.ExitCode-eq 0-and$value.conclusion-ceq'blocked'-and$value.task.status-ceq'paused') 'blocked Evidence keeps task unfinished and paused' 'blocked Evidence reached a terminal state'
$partialEvidence=New-EvidenceFixture $workspace 'partial-task' $contracts['partial-task'].Digest 'partial';$result=Invoke-Cli $workspace @('verify','-TaskId','partial-task','-ExpectedVersion','3','-Evidence',$partialEvidence.Path,'-AsJson');$value=Read-Output $result
Check ($result.ExitCode-eq 0-and$value.conclusion-ceq'partial'-and$value.task.status-ceq'verifying'-and$value.task.version-eq 4) 'partial Evidence remains verifying' 'partial Evidence completed task'

$crashEvidence=New-EvidenceFixture $workspace 'crash-task' $contracts['crash-task'].Digest 'pass';$result=Invoke-Cli $workspace @('verify','-TaskId','crash-task','-ExpectedVersion','3','-Evidence',$crashEvidence.Path,'-AsJson') '1';$match=[regex]::Match($result.StdErr,'TransactionId=(txn_[0-9a-f]{32})');$transactionId=if($match.Success){$match.Groups[1].Value}else{''}
Check ($result.ExitCode-eq 2-and$match.Success-and(Test-Path (Join-Path $workspace 'docs/tasks/crash-task/evidence.json'))-and(Test-Path (Join-Path $workspace ".assistant/runtime/failed-writes/$transactionId.json"))) 'Evidence fault leaves artifact and replay journal' 'Evidence fault did not journal partial write'
$replay=Invoke-Cli $workspace @('replay','-TransactionId',$transactionId,'-AsJson');$again=Invoke-Cli $workspace @('replay','-TransactionId',$transactionId,'-AsJson');$status=Read-Output (Invoke-Cli $workspace @('status','-TaskId','crash-task','-AsJson'))
Check ($replay.ExitCode-eq 0-and(Read-Output $replay).result-ceq'recovered'-and$again.ExitCode-eq 0-and(Read-Output $again).result-ceq'already-recovered'-and$status.task.status-ceq'done'-and$status.event_count-eq 5) 'Evidence transaction replay is complete and idempotent' 'Evidence transaction replay lost or duplicated state'

[IO.File]::WriteAllText((Join-Path $workspace 'source.txt'),"dirty-one`n",[Text.UTF8Encoding]::new($false));$dirtyEvidence=New-EvidenceFixture $workspace 'dirty-task' $contracts['dirty-task'].Digest 'dirty'
Check ($dirtyEvidence.Document.revision -match '^dirty:[0-9a-f]{64}$') 'dirty revision is deterministic and schema-valid' 'dirty revision was not derived'
[IO.File]::WriteAllText((Join-Path $workspace 'source.txt'),"dirty-two`n",[Text.UTF8Encoding]::new($false));$snapshot=Snapshot $workspace;$result=Invoke-Cli $workspace @('verify','-TaskId','dirty-task','-ExpectedVersion','3','-Evidence',$dirtyEvidence.Path,'-AsJson')
Check ($result.ExitCode-eq 2-and$result.StdErr-match'dirty revision is stale') 'stale dirty revision is rejected' 'stale dirty revision was accepted';Same $snapshot (Snapshot $workspace) 'stale revision rejection is zero-write' 'stale revision rejection wrote state'
$dirtyEvidence.Document.revision=Get-HarnessEvidenceRevision -WorkspaceRoot $workspace -ContractDigest $contracts['dirty-task'].Digest -Evidence $dirtyEvidence.Document -EvidenceInputPath $dirtyEvidence.Path -EvidenceOutputPath 'docs/tasks/dirty-task/evidence.json';Write-JsonFile $workspace $dirtyEvidence.Path $dirtyEvidence.Document
$result=Invoke-Cli $workspace @('verify','-TaskId','dirty-task','-ExpectedVersion','3','-Evidence',$dirtyEvidence.Path,'-AsJson');$value=Read-Output $result
Check ($result.ExitCode-eq 0-and$value.task.status-ceq'done'-and$value.conclusion-ceq'pass') 'fresh dirty revision can close a task' 'fresh dirty revision was rejected'

if(Test-Path $temp){Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue}
$repoAfter=@(& git -C $RepoRoot status --porcelain --untracked-files=all);Check (@(Compare-Object $repoBefore $repoAfter).Count-eq 0) 'Evidence verifier performs no repository writes' 'Evidence verifier changed repository state'
foreach($item in $script:passes){"[PASS] $item"};foreach($item in $script:failures){"[FAIL] $item"}
if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1};"STATUS: PASS ($($script:passes.Count) checks)";exit 0
