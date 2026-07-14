[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'tests/fixture-test-common.ps1')
$taskScript = Join-Path $RepoRoot 'scripts/task.ps1'
$script:passes=[Collections.Generic.List[string]]::new();$script:failures=[Collections.Generic.List[string]]::new();$script:unavailable=[Collections.Generic.List[string]]::new()
function Check($Condition,$Pass,$Fail){if($Condition){$script:passes.Add($Pass)}else{$script:failures.Add($Fail)}}
function Snapshot($Root){return @(Get-ChildItem $Root -Force -Recurse|%{if($_.PSIsContainer){'D|'+$_.FullName}else{'F|'+$_.FullName+'|'+(Get-FileHash $_.FullName).Hash}}|Sort-Object)}
function Same($Before,$After,$Pass,$Fail){Check (@(Compare-Object @($Before) @($After)).Count -eq 0) $Pass $Fail}
function Digest($Text){$h=[Security.Cryptography.SHA256]::Create();try{return 'sha256:'+([BitConverter]::ToString($h.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text))).Replace('-','').ToLowerInvariant())}finally{$h.Dispose()}}
function Write-Contract($Workspace,$TaskId,$Name,$Revision='one'){
    $b=[ordered]@{schema_version='requirement-contract/v1';task_id=$TaskId;goal="Test $TaskId.";acceptance=@('Durable.');in_scope=@('v2');out_of_scope=@('v1');product_constraints=@('No v1 writes.');product_decisions=@([ordered]@{key='revision';value=$Revision;source='user-confirmed:2026-07-14'});unresolved_product_decisions=@();source_authority=@('current-user-message')}
    $c=[ordered]@{};foreach($k in $b.Keys){$c[$k]=$b[$k]};$c.digest=Digest ($b|ConvertTo-Json -Depth 20 -Compress)
    $p=Join-Path $Workspace $Name;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $p));[IO.File]::WriteAllText($p,(($c|ConvertTo-Json -Depth 20)+"`n"),[Text.UTF8Encoding]::new($false));return $Name
}

function Start-Cli($Workspace,[string[]]$Arguments,[AllowNull()]$Protocol='v2',$Fault=''){
    $oldP=$env:HARNESS_PROTOCOL;$oldF=$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP
    try{
        if($null -eq $Protocol){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$Protocol}
        if($Fault){$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP=$Fault}else{Remove-Item Env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP -ErrorAction Ignore}
        return Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $taskScript -Arguments ($Arguments+@('-RepoRoot',$RepoRoot,'-WorkspaceRoot',$Workspace))
    }finally{
        if($null -eq $oldP){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$oldP}
        if($null -eq $oldF){Remove-Item Env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP -ErrorAction Ignore}else{$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP=$oldF}
    }
}
function Complete-Cli($Handle){if(-not $Handle.Process.WaitForExit(30000)){$Handle.Process.Kill($true);throw 'task CLI timeout'};$r=[pscustomobject]@{ExitCode=$Handle.Process.ExitCode;StdOut=$Handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$Handle.StdErr.GetAwaiter().GetResult().Trim()};$Handle.Process.Dispose();return $r}
function Invoke-Cli($Workspace,[string[]]$Arguments,[AllowNull()]$Protocol='v2',$Fault=''){return Complete-Cli (Start-Cli $Workspace $Arguments $Protocol $Fault)}
function Read-Output($Result){if($Result.StdOut){return $Result.StdOut|ConvertFrom-Json -Depth 50 -DateKind String};return $null}

$repoBefore=@(& git -C $RepoRoot status --porcelain --untracked-files=all)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('v2-state-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $temp 'workspace';$crashWorkspace=Join-Path $temp 'crash';$outside=Join-Path $temp 'outside'
foreach($path in @($workspace,$crashWorkspace,$outside)){[void][IO.Directory]::CreateDirectory($path)}
foreach($file in @('scripts/lib/Harness.Path.psm1','scripts/lib/Harness.AtomicWrite.psm1','scripts/lib/Harness.TaskState.psm1','scripts/task.ps1','tests/verify-v2-task-state.ps1')){
    $tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $file),[ref]$tokens,[ref]$errors)|Out-Null
    Check (@($errors).Count -eq 0) "$file parses" "$file parse failed"
}
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.TaskState.psm1') -Force
$exports=@(Get-Command -Module Harness.TaskState|Select-Object -ExpandProperty Name|Sort-Object)
Check (@(Compare-Object @('Get-HarnessTaskStatus','New-HarnessTaskState','Repair-HarnessTaskTransaction','Set-HarnessTaskTransition') $exports).Count -eq 0) 'exports are exact' 'exports drifted'

$owner=Write-Contract $workspace 'owner-task' 'contracts/owner.json'
$snap=Snapshot $workspace;$r=Invoke-Cli $workspace @('create','-TaskId','owner-task','-Contract',$owner,'-AsJson') $null
Check ($r.ExitCode -eq 2 -and -not $r.StdOut -and $r.StdErr -match 'HARNESS_PROTOCOL=v2') 'writes require explicit v2' 'write ran without v2';Same $snap (Snapshot $workspace) 'protocol rejection is zero-write' 'protocol rejection wrote state'
$r=Invoke-Cli $workspace @('create','-TaskId','owner-task','-Contract',$owner,'-ActivateCurrent','-AsJson');$created=Read-Output $r
Check ($r.ExitCode -eq 0 -and $created.task.status -ceq 'ready' -and $created.pointer_action -ceq 'activated') 'active create succeeds' 'active create failed'
$taskPath=Join-Path $workspace '.assistant/runtime/tasks/owner-task/task.json';$eventsPath=Join-Path $workspace '.assistant/runtime/tasks/owner-task/events.jsonl';$currentPath=Join-Path $workspace '.assistant/runtime/current.json'
Check ((Test-Path $taskPath)-and(Test-Path $eventsPath)-and(Test-Path $currentPath)-and(Test-Path (Join-Path $workspace '.assistant/runtime/locks'))) 'runtime layout is complete' 'runtime layout is incomplete'
Check (-not(Test-Path (Join-Path $workspace '.assistant/运行时'))-and-not(Test-Path (Join-Path $workspace 'docs/tasks'))) 'v1 and artifacts stay untouched' 'v2 wrote v1 or artifacts'

$snap=Snapshot $workspace;$r=Invoke-Cli $workspace @('status','-TaskId','owner-task','-AsJson') $null;$status=Read-Output $r
Check ($r.ExitCode -eq 0 -and $status.event_count -eq 1 -and $status.is_current -eq $true -and $status.side_effects.runtime_writes -eq 0) 'status is read-only' 'status output is invalid';Same $snap (Snapshot $workspace) 'status is zero-write' 'status wrote state'
$snap=Snapshot $workspace;$r=Invoke-Cli $workspace @('transition','-TaskId','owner-task','-ExpectedVersion','9','-To','running','-AsJson')
Check ($r.ExitCode -eq 2 -and -not $r.StdOut -and $r.StdErr -match 'ExpectedVersion mismatch') 'CAS mismatch fails closed' 'CAS mismatch accepted';Same $snap (Snapshot $workspace) 'CAS mismatch is zero-write' 'CAS mismatch wrote state'
$snap=Snapshot $workspace;$r=Invoke-Cli $workspace @('transition','-TaskId','owner-task','-ExpectedVersion','1','-To','done','-EvidenceSatisfied','-AsJson')
Check ($r.ExitCode -eq 2 -and $r.StdErr -match 'illegal task transition') 'illegal transition fails closed' 'illegal transition accepted';Same $snap (Snapshot $workspace) 'illegal transition is zero-write' 'illegal transition wrote state'

$background=Write-Contract $workspace 'background-task' 'contracts/background.json';$currentBefore=[IO.File]::ReadAllText($currentPath)
$r=Invoke-Cli $workspace @('create','-TaskId','background-task','-Contract',$background,'-AsJson')
Check ($r.ExitCode -eq 0 -and (Read-Output $r).pointer_action -ceq 'unchanged' -and [IO.File]::ReadAllText($currentPath) -ceq $currentBefore) 'background create preserves current' 'background create took current'
$backgroundEvents=Join-Path $workspace '.assistant/runtime/tasks/background-task/events.jsonl';$prefix=[IO.File]::ReadAllText($backgroundEvents)
$one=Start-Cli $workspace @('transition','-TaskId','background-task','-ExpectedVersion','1','-To','running','-AsJson');$two=Start-Cli $workspace @('transition','-TaskId','background-task','-ExpectedVersion','1','-To','running','-AsJson')
$race=@((Complete-Cli $one),(Complete-Cli $two));$win=@($race|? ExitCode -eq 0);$lose=@($race|? ExitCode -eq 2)
$status=Read-Output (Invoke-Cli $workspace @('status','-TaskId','background-task','-AsJson') $null)
Check ($win.Count -eq 1 -and $lose.Count -eq 1 -and $status.task.version -eq 2 -and $status.event_count -eq 2) 'concurrent CAS has one winner' 'concurrent CAS failed';Check ([IO.File]::ReadAllText($backgroundEvents).StartsWith($prefix,[StringComparison]::Ordinal)) 'events are append-only' 'event prefix changed';Check ([IO.File]::ReadAllText($currentPath) -ceq $currentBefore) 'background transition preserves current' 'background transition changed current'

$blocked=Invoke-Cli $workspace @('transition','-TaskId','background-task','-ExpectedVersion','2','-To','blocked','-Reason','ambiguity','-AsJson')
$same=Invoke-Cli $workspace @('transition','-TaskId','background-task','-ExpectedVersion','3','-To','ready','-Contract',$background,'-AsJson')
$revised=Write-Contract $workspace 'background-task' 'contracts/background-v2.json' 'two';$resolved=Invoke-Cli $workspace @('transition','-TaskId','background-task','-ExpectedVersion','3','-To','ready','-Contract',$revised,'-AsJson')
Check ($blocked.ExitCode -eq 0 -and $same.ExitCode -eq 2 -and $same.StdErr -match 'revised Contract digest' -and $resolved.ExitCode -eq 0) 'blocked task requires revised Contract' 'blocked task accepted stale Contract'
$running=Invoke-Cli $workspace @('transition','-TaskId','owner-task','-ExpectedVersion','1','-To','running','-AsJson');$verifying=Invoke-Cli $workspace @('transition','-TaskId','owner-task','-ExpectedVersion','2','-To','verifying','-AsJson');$done=Invoke-Cli $workspace @('transition','-TaskId','owner-task','-ExpectedVersion','3','-To','done','-EvidenceSatisfied','-AsJson')
Check ($running.ExitCode -eq 0 -and $verifying.ExitCode -eq 0 -and $done.ExitCode -eq 0 -and (Read-Output $done).pointer_action -ceq 'cleared' -and -not(Test-Path $currentPath)) 'active done clears current' 'active done failed'

$crashContract=Write-Contract $crashWorkspace 'crash-task' 'contract.json';$r=Invoke-Cli $crashWorkspace @('create','-TaskId','crash-task','-Contract',$crashContract,'-ActivateCurrent','-AsJson') 'v2' '1'
$match=[regex]::Match($r.StdErr,'TransactionId=(txn_[0-9a-f]{32})');$transactionId=if($match.Success){$match.Groups[1].Value}else{''};$journal=Join-Path $crashWorkspace ".assistant/runtime/failed-writes/$transactionId.json"
Check ($r.ExitCode -eq 2 -and -not $r.StdOut -and $match.Success -and $r.StdErr -match '-WorkspaceRoot' -and (Test-Path $journal)) 'crash leaves workspace-bound journal' 'crash journal missing'
$replay=Invoke-Cli $crashWorkspace @('replay','-TransactionId',$transactionId,'-AsJson');$again=Invoke-Cli $crashWorkspace @('replay','-TransactionId',$transactionId,'-AsJson');$lines=@(Get-Content (Join-Path $crashWorkspace '.assistant/runtime/tasks/crash-task/events.jsonl'))
Check ($replay.ExitCode -eq 0 -and (Read-Output $replay).result -ceq 'recovered' -and $again.ExitCode -eq 0 -and (Read-Output $again).result -ceq 'already-recovered' -and $lines.Count -eq 1 -and -not(Test-Path $journal)) 'crash replay is idempotent' 'crash replay failed'

$archive=Join-Path $crashWorkspace ".assistant/runtime/failed-writes/archive/$transactionId.json";$tamperId='txn_ffffffffffffffffffffffffffffffff';$tamperPath=Join-Path $crashWorkspace ".assistant/runtime/failed-writes/$tamperId.json"
$tampered=Get-Content $archive -Raw|ConvertFrom-Json -AsHashtable -DateKind String;$tampered.transaction_id=$tamperId;$tampered.replay_command="replay $tamperId";$tampered.steps[0].relative_path='.assistant/runtime/../escaped.json'
[IO.File]::WriteAllText($tamperPath,(($tampered|ConvertTo-Json -Depth 50)+"`n"),[Text.UTF8Encoding]::new($false));$snap=Snapshot $crashWorkspace;$r=Invoke-Cli $crashWorkspace @('replay','-TransactionId',$tamperId,'-AsJson')
Check ($r.ExitCode -eq 2 -and $r.StdErr -match 'path or action is invalid') 'tampered journal fails closed' 'tampered journal replayed';Same $snap (Snapshot $crashWorkspace) 'tampered replay is zero-write' 'tampered replay wrote state'
$outsideContract=Write-Contract $outside 'escape-task' 'contract.json';$snap=Snapshot $workspace;$r=Invoke-Cli $workspace @('create','-TaskId','escape-task','-Contract',(Join-Path $outside $outsideContract),'-AsJson')
Check ($r.ExitCode -eq 2 -and $r.StdErr -match 'escapes WorkspaceRoot') 'path escape fails closed' 'path escape accepted';Same $snap (Snapshot $workspace) 'path escape is zero-write' 'path escape wrote state'

try{
    [void](New-Item -ItemType Junction -Path (Join-Path $workspace 'contract-link') -Target $outside -ErrorAction Stop);$snap=Snapshot $workspace
    $r=Invoke-Cli $workspace @('create','-TaskId','escape-task','-Contract','contract-link/contract.json','-AsJson')
    Check ($r.ExitCode -eq 2 -and $r.StdErr -match 'reparse point') 'reparse path fails closed' 'reparse path accepted';Same $snap (Snapshot $workspace) 'reparse rejection is zero-write' 'reparse rejection wrote state'
}catch{$script:unavailable.Add('reparse fixture unavailable: '+$_.Exception.Message)}
if(Test-Path $temp){Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue}
$repoAfter=@(& git -C $RepoRoot status --porcelain --untracked-files=all);Check (@(Compare-Object $repoBefore $repoAfter).Count -eq 0) 'verifier performs no repository writes' 'verifier changed repository state'
foreach($item in $script:passes){"[PASS] $item"};foreach($item in $script:unavailable){"[UNAVAILABLE] $item"};foreach($item in $script:failures){"[FAIL] $item"}
if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1};"STATUS: PASS ($($script:passes.Count) checks, $($script:unavailable.Count) unavailable)";exit 0
