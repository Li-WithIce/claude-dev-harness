[CmdletBinding()]
param([string]$RepoRoot='')

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent $PSScriptRoot}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'tests\fixture-test-common.ps1')
$script:passes=[System.Collections.Generic.List[string]]::new();$script:failures=[System.Collections.Generic.List[string]]::new()
function Check($Condition,$Pass,$Fail){if($Condition){$script:passes.Add($Pass)}else{$script:failures.Add($Fail)}}
function Snapshot($Root){return @(Get-ChildItem -LiteralPath $Root -Force -Recurse|ForEach-Object{if($_.PSIsContainer){'D|'+[IO.Path]::GetRelativePath($Root,$_.FullName)}else{'F|'+[IO.Path]::GetRelativePath($Root,$_.FullName)+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}}|Sort-Object)}
function Same($Before,$After,$Pass,$Fail){Check (@(Compare-Object @($Before) @($After)).Count-eq0) $Pass $Fail}
function Complete($Handle){if(-not$Handle.Process.WaitForExit(90000)){$Handle.Process.Kill($true);throw 'migration fixture timeout'};$r=[pscustomobject]@{ExitCode=$Handle.Process.ExitCode;StdOut=$Handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$Handle.StdErr.GetAwaiter().GetResult().Trim()};$Handle.Process.Dispose();return $r}
function Invoke-Migration($Workspace,[string[]]$Arguments,$Fault=$false){$old=$env:DEV_HARNESS_TEST_MIGRATION_FAIL_BEFORE_PUBLISH;try{if($Fault){$env:DEV_HARNESS_TEST_MIGRATION_FAIL_BEFORE_PUBLISH='1'}else{Remove-Item Env:DEV_HARNESS_TEST_MIGRATION_FAIL_BEFORE_PUBLISH -ErrorAction Ignore};return Complete (Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath (Join-Path $RepoRoot 'scripts\migrate-task-v1-to-v2.ps1') -Arguments ($Arguments+@('-RepoRoot',$RepoRoot,'-WorkspaceRoot',$Workspace,'-AsJson')))}finally{if($null-eq$old){Remove-Item Env:DEV_HARNESS_TEST_MIGRATION_FAIL_BEFORE_PUBLISH -ErrorAction Ignore}else{$env:DEV_HARNESS_TEST_MIGRATION_FAIL_BEFORE_PUBLISH=$old}}}
function Write-V1Fixture($Workspace,$TaskId){
    $root=Join-Path $Workspace "docs\tasks\$TaskId";[void][IO.Directory]::CreateDirectory($root);$path=Join-Path $root 'plan.md'
    Write-Utf8Bom -Path $path -Content @"
---
task_id: $TaskId
stage: IMPLEMENT
tool: codex
updated: 2026-07-14
---
# Migration Fixture

## Clarification
- 验收标准: migrate only after reviewed dry-run digest.
- 非目标: no automatic active-task migration.
- 受影响目录: isolated fixture only.
- 回滚策略: preserve the v1 plan unchanged.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- migrate the paused v1 fixture.

## Verification
- ``pwsh -NoProfile -File tests/verify-v1-to-v2-migration.ps1``

## Risks
- partial writes must be cleaned.

## Plan Review

### Run 1 · 2026-07-14 20:00 · runner: fixture
- verdict: pass
- findings: none
- next: IMPLEMENT

## Implementation Notes

## Code Review

"@
    return $path
}

$repoBefore=@(&git -C $RepoRoot status --porcelain --untracked-files=all)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('v1-v2-migration-'+[guid]::NewGuid().ToString('N'));$workspace=Join-Path $temp 'workspace';$activeWorkspace=Join-Path $temp 'active'
foreach($path in @($workspace,$activeWorkspace)){[void][IO.Directory]::CreateDirectory($path)}
try{
    foreach($file in @('modules/legacy-v1/Harness.LegacyMigration.psm1','scripts/lib/Harness.Protocol.psm1','scripts/lib/Harness.TaskState.psm1','scripts/migrate-task-v1-to-v2.ps1','tests/verify-v1-to-v2-migration.ps1')){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $file),[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq0) "$file parses" "$file parse failed"}
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.TaskState.psm1') -Force
    $exports=@(Get-Command -Module Harness.TaskState|Select-Object -ExpandProperty Name|Sort-Object)
    Check (@(Compare-Object @('Get-HarnessTaskStatus','New-HarnessTaskState','Repair-HarnessTaskTransaction','Resume-HarnessTaskExecution','Set-HarnessTaskApproval','Set-HarnessTaskEvidence','Set-HarnessTaskTransition') $exports).Count-eq0) 'TaskState keeps migration publication internal to the confirmed command' 'TaskState exports drifted'

    $taskId='migrate-paused';$planPath=Write-V1Fixture $workspace $taskId;$planBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($planPath));$args=@('-TaskId',$taskId,'-ExpectedV1Stage','IMPLEMENT')
    $before=Snapshot $workspace;$dry=Invoke-Migration $workspace ($args+@('-DryRun'));$dryJson=if($dry.ExitCode-eq0){$dry.StdOut|ConvertFrom-Json -Depth 40 -DateKind String}else{$null}
    Check ($null-ne$dryJson-and$dry.ExitCode-eq0-and$dryJson.operation-ceq'migration-dry-run'-and$dryJson.report.target_status-ceq'paused'-and$dryJson.report.dry_run_digest-match'^sha256:[0-9a-f]{64}$'-and$dryJson.side_effects.v2_writes-eq0) 'dry-run emits a digest-bound zero-write report' ("dry-run failed: $($dry.StdErr)")
    Same $before (Snapshot $workspace) 'migration dry-run is zero-write' 'migration dry-run changed the workspace'
    $digest=if($null-ne$dryJson){[string]$dryJson.report.dry_run_digest}else{'sha256:'+'0'*64}

    $before=Snapshot $workspace;$mismatch=Invoke-Migration $workspace ($args+@('-ExpectedDryRunDigest',('sha256:'+'0'*64),'-ConfirmMigration'))
    Check ($mismatch.ExitCode-eq2-and$mismatch.StdErr-match'dry-run digest mismatch') 'stale dry-run digest fails closed' 'stale dry-run digest was accepted'
    Same $before (Snapshot $workspace) 'digest mismatch is zero-write' 'digest mismatch changed the workspace'

    $before=Snapshot $workspace;$fault=Invoke-Migration $workspace ($args+@('-ExpectedDryRunDigest',$digest,'-ConfirmMigration')) $true
    Check ($fault.ExitCode-eq2-and$fault.StdErr-match'injected migration failure before publish') 'pre-publish migration fault is reported' 'migration fault was not injected'
    Same $before (Snapshot $workspace) 'failed migration removes staging and leaves the whole v1 workspace unchanged' 'failed migration left partial writes'

    $success=Invoke-Migration $workspace ($args+@('-ExpectedDryRunDigest',$digest,'-ConfirmMigration'));$successJson=if($success.ExitCode-eq0){$success.StdOut|ConvertFrom-Json -Depth 40 -DateKind String}else{$null}
    $target=Join-Path $workspace ".assistant\runtime\tasks\$taskId";$task=if(Test-Path (Join-Path $target 'task.json')){Get-Content (Join-Path $target 'task.json') -Raw|ConvertFrom-Json -Depth 40 -DateKind String}else{$null};$event=if(Test-Path (Join-Path $target 'events.jsonl')){Get-Content (Join-Path $target 'events.jsonl') -Raw|ConvertFrom-Json -Depth 40 -DateKind String}else{$null}
    Check ($null-ne$successJson-and$null-ne$task-and$null-ne$event-and$success.ExitCode-eq0-and$successJson.operation-ceq'import-v1'-and$task.status-ceq'paused'-and$task.identity-ceq'existing'-and(Test-Path (Join-Path $target 'contract.json'))-and$event.payload.import_note.source_protocol-ceq'v1'-and$event.payload.import_note.capability_state_inferred-eq$false) 'confirmed migration atomically publishes a paused v2 task with a reference-only import note' ("migration failed: stderr=[$($success.StdErr)] stdout=[$($success.StdOut)] target_exists=$(Test-Path $target) files=$(@(Get-ChildItem $target -ErrorAction Ignore|Select-Object -ExpandProperty Name)-join',')")
    Check ($planBefore-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes($planPath))-and$null-ne$event-and$event.payload.import_note.source_plan_digest-ceq[System.String]$dryJson.report.source_plan_digest) 'successful migration preserves and digest-binds the original v1 plan' 'successful migration changed or unbound the v1 plan'
    $protocol=Complete (Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath (Join-Path $RepoRoot 'scripts\task.ps1') -Arguments @('protocol','-TaskId',$taskId,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson'));$protocolJson=$protocol.StdOut|ConvertFrom-Json -Depth 20 -DateKind String
    Check ($protocol.ExitCode-eq0-and$protocolJson.detected_protocol-ceq'v2') 'successful migration makes v2 artifact detection authoritative' 'migrated task was not detected as v2'

    $activeId='active-v1';$activePlan=Write-V1Fixture $activeWorkspace $activeId;$currentDir=Join-Path $activeWorkspace '.assistant\运行时';[void][IO.Directory]::CreateDirectory($currentDir);Write-Utf8Bom -Path (Join-Path $currentDir '当前任务.md') -Content "---`r`ntask_id: $activeId`r`n---`r`n# current"
    $activeBefore=Snapshot $activeWorkspace;$active=Invoke-Migration $activeWorkspace @('-TaskId',$activeId,'-ExpectedV1Stage','IMPLEMENT','-DryRun')
    Check ($active.ExitCode-eq2-and$active.StdErr-match'active v1 task cannot be migrated') 'active v1 task is never migrated by detection or dry-run' 'active v1 migration was allowed'
    Same $activeBefore (Snapshot $activeWorkspace) 'active-v1 rejection is zero-write' 'active-v1 rejection changed the workspace'
}finally{if(Test-Path $temp){Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue}}
$repoAfter=@(&git -C $RepoRoot status --porcelain --untracked-files=all);Check (@(Compare-Object $repoBefore $repoAfter).Count-eq0) 'verifier performs no repository writes' 'verifier changed repository state'
foreach($item in $script:passes){"[PASS] $item"};foreach($item in $script:failures){"[FAIL] $item"}
if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1};"STATUS: PASS ($($script:passes.Count) checks)";exit 0
