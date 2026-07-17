[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'tests\fixture-test-common.ps1')

$script:checks = [System.Collections.Generic.List[string]]::new()
$script:failures = [System.Collections.Generic.List[string]]::new()
$script:unavailable = [System.Collections.Generic.List[string]]::new()
function Check($Condition,[string]$Pass,[string]$Fail) { if ($Condition) { $script:checks.Add($Pass) } else { $script:failures.Add($Fail) } }
function Snapshot([string]$Root) { return @(Get-ChildItem -LiteralPath $Root -Force -Recurse | ForEach-Object { if ($_.PSIsContainer) { 'D|' + $_.FullName } else { 'F|' + $_.FullName + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } } | Sort-Object) }
function Same($Before,$After,[string]$Pass,[string]$Fail) { Check (@(Compare-Object @($Before) @($After)).Count -eq 0) $Pass $Fail }
function Digest([string]$Text) { $hash=[Security.Cryptography.SHA256]::Create();try{return 'sha256:'+([BitConverter]::ToString($hash.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))).Replace('-','').ToLowerInvariant())}finally{$hash.Dispose()} }
function Write-Contract([string]$Workspace,[string]$TaskId,[string]$Name) {
    $body=[ordered]@{schema_version='requirement-contract/v1';task_id=$TaskId;goal="Recover $TaskId.";acceptance=@('Recovery is deterministic.');in_scope=@('v2 runtime');out_of_scope=@('memory');product_constraints=@('No memory dependency.');product_decisions=@([ordered]@{key='recovery';value='explicit';source='user-confirmed:2026-07-14'});unresolved_product_decisions=@();source_authority=@('current-user-message')}
    $contract=[ordered]@{};foreach($key in $body.Keys){$contract[$key]=$body[$key]};$contract.digest=Digest ($body|ConvertTo-Json -Depth 20 -Compress)
    $path=Join-Path $Workspace $Name;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $path));[IO.File]::WriteAllText($path,(($contract|ConvertTo-Json -Depth 20)+"`n"),[Text.UTF8Encoding]::new($false));return $Name
}
function Invoke-Task([string]$Script,[string]$FixtureRoot,[string]$Workspace,[string[]]$Arguments,[AllowNull()]$Protocol='v2',[string]$Fault='') {
    $oldProtocol=$env:HARNESS_PROTOCOL;$oldFault=$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP
    try {
        if($null-eq$Protocol){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$Protocol}
        if([string]::IsNullOrWhiteSpace($Fault)){Remove-Item Env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP -ErrorAction Ignore}else{$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP=$Fault}
        $handle=Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $Script -Arguments ($Arguments+@('-RepoRoot',$FixtureRoot,'-WorkspaceRoot',$Workspace))
        if(-not$handle.Process.WaitForExit(30000)){$handle.Process.Kill($true);throw 'task CLI timeout'}
        $result=[pscustomobject]@{ExitCode=$handle.Process.ExitCode;StdOut=$handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$handle.StdErr.GetAwaiter().GetResult().Trim()};$handle.Process.Dispose();return $result
    } finally {
        if($null-eq$oldProtocol){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$oldProtocol}
        if($null-eq$oldFault){Remove-Item Env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP -ErrorAction Ignore}else{$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP=$oldFault}
    }
}
function Read-Output($Result) { if([string]::IsNullOrWhiteSpace($Result.StdOut)){return $null};return $Result.StdOut|ConvertFrom-Json -Depth 50 -DateKind String }
function Invoke-NodeHook([string]$NodePath,[string]$HookPath,[string]$InputText) {
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$NodePath;$psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true;$psi.ArgumentList.Add($HookPath)
    $process=[Diagnostics.Process]::new();$process.StartInfo=$psi;[void]$process.Start();$process.StandardInput.Write($InputText);$process.StandardInput.Close();if(-not$process.WaitForExit(30000)){$process.Kill($true);throw 'memory hook timeout'}
    $result=[pscustomobject]@{ExitCode=$process.ExitCode;StdOut=$process.StandardOutput.ReadToEnd();StdErr=$process.StandardError.ReadToEnd()};$process.Dispose();return $result
}

$repoBefore=@(& git -C $RepoRoot status --porcelain --untracked-files=all)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('v2-memory-decoupling-'+[guid]::NewGuid().ToString('N'))
$fixture=Join-Path $temp 'core-install';$workspace=Join-Path $temp 'workspace';$crash=Join-Path $temp 'crash'
try {
    foreach($path in @($fixture,$workspace,$crash)){[void][IO.Directory]::CreateDirectory($path)}
    foreach($relative in @('scripts\task.ps1','scripts\lib','schemas','policies','templates\v2','runtime-hooks\core')){Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $fixture -RelativePath $relative}
    $taskScript=Join-Path $fixture 'scripts\task.ps1'
    Check (-not(Test-Path -LiteralPath (Join-Path $fixture 'skills\obsidian-memory'))-and-not(Test-Path -LiteralPath (Join-Path $fixture 'runtime-hooks\memory'))) 'core fixture excludes optional memory assets' 'core fixture contains optional memory assets'
    $coreText=@(Get-ChildItem -LiteralPath $fixture -File -Recurse|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8})-join"`n"
    Check ($coreText -notmatch 'obsidian-memory|运行时[\\/]收件箱|恢复索引\.md|\.assistant[\\/]memory') 'core fixture has no Obsidian, business inbox, or memory path reference' 'core fixture retains a memory path reference'
    foreach($file in @('scripts/lib/Harness.Recovery.psm1','scripts/lib/Harness.TaskState.psm1','scripts/task.ps1','tests/verify-v2-runtime-memory-decoupling.ps1')){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $file),[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq0) "$file parses" "$file parse failed"}
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Recovery.psm1') -Force
    $exports=@(Get-Command -Module Harness.Recovery|Select-Object -ExpandProperty Name|Sort-Object)
    Check (@(Compare-Object @('Get-HarnessRecoveryIndex','Get-HarnessResumeClarification') $exports).Count-eq0) 'Recovery exports are exact' 'Recovery exports drifted'

    $request=[ordered]@{task_id='inspect-memory-free';goal='Inspect without memory.';acceptance=@('No writes.');in_scope=@('inspection');out_of_scope=@('mutation');product_constraints=@('No memory.');source_authority=@('current-user-message');decisions=@([ordered]@{key='export_roles';category='authorization_semantics';question='Which roles may export?';impact='Controls access.';options=@('admin-only','admin-and-analyst');recommended='admin-only';depends_on=@();sources=@([ordered]@{authority='current-user-message';source_id='message-1';value='admin-only'})});repo_checks=@();ask=[ordered]@{style='dependency-aware';max_independent_questions_per_turn=5}}
    $requestPath=Join-Path $workspace 'request.json';[IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false));$before=Snapshot $workspace
    $inspect=Invoke-Task $taskScript $fixture $workspace @('inspect','-RequestFile','request.json','-AsJson') $null;$inspectOutput=Read-Output $inspect
    Check ($inspect.ExitCode-eq0-and$inspectOutput.requirement_state-ceq'clear'-and$inspectOutput.side_effects.runtime_writes-eq0) 'Direct inspection runs without memory installed' 'Direct inspection depends on memory';Same $before (Snapshot $workspace) 'Direct inspection is zero-write' 'Direct inspection wrote workspace state'

    $contract=Write-Contract $workspace 'recover-task' 'contracts/recover.json'
    $create=Invoke-Task $taskScript $fixture $workspace @('create','-TaskId','recover-task','-Contract',$contract,'-AsJson');$created=Read-Output $create
    Check ($create.ExitCode-eq0-and$created.task.status-ceq'ready'-and-not(Test-Path -LiteralPath (Join-Path $workspace '.assistant\memory'))) 'Governed task creates without memory installed' 'Governed task creation depends on memory'
    $before=Snapshot $workspace;$status=Invoke-Task $taskScript $fixture $workspace @('status','-AsJson') $null;$index=Read-Output $status
    Check ($status.ExitCode-eq0-and$index.schema_version-ceq'recovery-index/v2'-and@($index.tasks).Count-eq1-and$index.current-eq$null-and$index.side_effects.runtime_writes-eq0) 'status builds an on-demand read-only recovery index' 'status recovery index is invalid';Same $before (Snapshot $workspace) 'on-demand recovery index is zero-write' 'on-demand recovery index persisted state'
    Check (-not(Test-Path -LiteralPath (Join-Path $workspace '.assistant\runtime\recovery-index.json'))) 'recovery index is not persisted' 'recovery index was persisted'

    $before=Snapshot $workspace;$resume=Invoke-Task $taskScript $fixture $workspace @('resume','-TaskId','recover-task','-AsJson') $null;$resumeOutput=Read-Output $resume
    Check ($resume.ExitCode-eq0-and$resumeOutput.requirement_state-ceq'blocked'-and$resumeOutput.write_authorized-eq$false-and$resumeOutput.blocking_decision-match'resume-and-execute') 'bare resume requires clarification and denies write authorization' 'bare resume granted execution';Same $before (Snapshot $workspace) 'bare resume is zero-write' 'bare resume wrote state'

    $execute=Invoke-Task $taskScript $fixture $workspace @('resume-and-execute','-TaskId','recover-task','-ExpectedVersion','1','-AsJson');$executed=Read-Output $execute
    Check ($execute.ExitCode-eq0-and$executed.write_authorized-eq$true-and$executed.task.version-eq2-and$executed.task.status-ceq'running'-and$executed.pointer_action-ceq'activated') 'explicit resume-and-execute writes running state and activates current' 'explicit resume-and-execute failed'
    $index=Read-Output (Invoke-Task $taskScript $fixture $workspace @('status','-AsJson') $null)
    Check ($index.current.task_id-ceq'recover-task'-and$index.current.task_version-eq2-and@($index.tasks|Where-Object is_current).Count-eq1) 'recovery index reflects the activated task' 'recovery index missed current task'
    $before=Snapshot $workspace;$stale=Invoke-Task $taskScript $fixture $workspace @('resume-and-execute','-TaskId','recover-task','-ExpectedVersion','1','-AsJson')
    Check ($stale.ExitCode-eq2-and$stale.StdErr-match'ExpectedVersion mismatch') 'resume-and-execute enforces CAS' 'stale resume-and-execute was accepted';Same $before (Snapshot $workspace) 'stale resume is zero-write' 'stale resume wrote state'

    $otherContract=Write-Contract $workspace 'other-task' 'contracts/other.json';$other=Invoke-Task $taskScript $fixture $workspace @('create','-TaskId','other-task','-Contract',$otherContract,'-AsJson')
    $before=Snapshot $workspace;$collision=Invoke-Task $taskScript $fixture $workspace @('resume-and-execute','-TaskId','other-task','-ExpectedVersion','1','-AsJson')
    Check ($other.ExitCode-eq0-and$collision.ExitCode-eq2-and$collision.StdErr-match'another current task') 'resume-and-execute does not steal a current pointer' 'resume-and-execute stole the current pointer';Same $before (Snapshot $workspace) 'current collision is zero-write' 'current collision wrote state'
    $pause=Invoke-Task $taskScript $fixture $workspace @('transition','-TaskId','recover-task','-ExpectedVersion','2','-To','paused','-AsJson');$resumeAgain=Invoke-Task $taskScript $fixture $workspace @('resume-and-execute','-TaskId','recover-task','-ExpectedVersion','3','-AsJson')
    Check ($pause.ExitCode-eq0-and$resumeAgain.ExitCode-eq0-and(Read-Output $resumeAgain).task.version-eq4) 'paused task resumes through the explicit write command' 'paused task did not resume'

    $crashContract=Write-Contract $crash 'crash-task' 'contract.json';$failed=Invoke-Task $taskScript $fixture $crash @('create','-TaskId','crash-task','-Contract',$crashContract,'-AsJson') 'v2' '1'
    $match=[regex]::Match($failed.StdErr,'TransactionId=(txn_[0-9a-f]{32})');$transactionId=$(if($match.Success){$match.Groups[1].Value}else{''})
    Check ($failed.ExitCode-eq2-and$match.Success-and(Test-Path -LiteralPath (Join-Path $crash ".assistant\runtime\failed-writes\$transactionId.json"))) 'failed task write uses the dedicated failed-writes journal' 'failed task write did not journal independently'
    Check (-not(Test-Path -LiteralPath (Join-Path $crash '.assistant\memory\inbox'))-and-not(Test-Path -LiteralPath (Join-Path $crash '.assistant\运行时\收件箱.md'))) 'failed write never enters a business or memory inbox' 'failed write leaked into a business inbox'
    $pendingIndex=Read-Output (Invoke-Task $taskScript $fixture $crash @('status','-AsJson') $null)
    Check (@($pendingIndex.tasks).Count-eq1-and@($pendingIndex.tasks[0].pending_transactions).Count-eq1) 'on-demand recovery reports the pending transaction' 'recovery index missed pending transaction'
    $replay=Invoke-Task $taskScript $fixture $crash @('replay','-TransactionId',$transactionId,'-AsJson')
    Check ($replay.ExitCode-eq0-and(Read-Output $replay).result-ceq'recovered') 'failed-write replay remains independent and idempotent' 'failed-write replay failed'

    $staging=Join-Path $crash '.assistant/runtime/tasks/.migration-orphan-task-ffffffffffffffffffffffffffffffff';[void][IO.Directory]::CreateDirectory($staging);[IO.File]::WriteAllText((Join-Path $staging 'partial.json'),'{}',[Text.UTF8Encoding]::new($false));$before=Snapshot $crash
    $stagingStatus=Invoke-Task $taskScript $fixture $crash @('status','-AsJson') $null;$stagingIndex=Read-Output $stagingStatus
    Check ($stagingStatus.ExitCode-eq0-and@($stagingIndex.tasks).Count-eq1-and(Test-Path -LiteralPath $staging)) 'recovery ignores but preserves a strict migration staging residue' 'migration staging residue broke recovery or was deleted';Same $before (Snapshot $crash) 'migration residue handling is zero-write' 'recovery changed migration residue'

    $coreHookText=@(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'runtime-hooks\core') -File -Recurse|ForEach-Object{Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8})-join"`n"
    Check ($coreHookText-notmatch'(?i)resume|obsidian|long-term memory|恢复索引|继续|恢复') 'core hooks contain no resume or memory prompt injection' 'core hooks retain resume or memory prompt injection'
    $memoryHook=Join-Path $RepoRoot 'runtime-hooks\memory\userpromptsubmit.js';$legacyHook=Join-Path $RepoRoot 'runtime-hooks\claude\userpromptsubmit.js'
    Check ((Test-Path -LiteralPath $memoryHook)-and(Test-Path -LiteralPath $legacyHook)) 'optional memory hook exists while the v1 compatibility hook remains' 'optional or v1 compatibility hook is missing'
    $node=Get-Command node -ErrorAction SilentlyContinue
    if($null-eq$node){$script:unavailable.Add('node unavailable; optional memory hook execution not run')}else{$hook=Invoke-NodeHook $node.Source $memoryHook '{"prompt":"resume"}';$payload=$hook.StdOut|ConvertFrom-Json;Check ($hook.ExitCode-eq0-and$hook.StdErr-eq''-and$payload.systemMessage-match'task\.ps1 status'-and$payload.systemMessage-match'only explicit resume-and-execute') 'optional memory hook emits read/write authority guidance' 'optional memory hook output is invalid'}
} finally {
    if(Test-Path -LiteralPath $temp){Remove-DirectoryWithRetry -Path $temp}
}
$repoAfter=@(& git -C $RepoRoot status --porcelain --untracked-files=all);Check (@(Compare-Object $repoBefore $repoAfter).Count-eq0) 'verifier performs no repository writes' 'verifier changed repository state'
foreach($item in $script:checks){"[PASS] $item"};foreach($item in $script:unavailable){"[UNAVAILABLE] $item"};foreach($item in $script:failures){"[FAIL] $item"}
if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1};"STATUS: PASS ($($script:checks.Count) checks, $($script:unavailable.Count) unavailable)";exit 0
