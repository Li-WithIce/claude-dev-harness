[CmdletBinding()]
param([string]$RepoRoot='')

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent $PSScriptRoot}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'tests\fixture-test-common.ps1')
$script:passes=[System.Collections.Generic.List[string]]::new();$script:failures=[System.Collections.Generic.List[string]]::new()
function Check($Condition,$Pass,$Fail){if($Condition){$script:passes.Add($Pass)}else{$script:failures.Add($Fail)}}
function Complete($Handle){if(-not$Handle.Process.WaitForExit(90000)){$Handle.Process.Kill($true);throw 'fixture process timeout'};$r=[pscustomobject]@{ExitCode=$Handle.Process.ExitCode;StdOut=$Handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$Handle.StdErr.GetAwaiter().GetResult().Trim()};$Handle.Process.Dispose();return $r}
function Invoke-Script($Path,[string[]]$Arguments,[AllowNull()]$Protocol='auto'){
    $old=$env:HARNESS_PROTOCOL
    try{if($null-eq$Protocol){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$Protocol};return Complete (Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $Path -Arguments $Arguments)}
    finally{if($null-eq$old){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$old}}
}
function Read-Json($Result){if([string]::IsNullOrWhiteSpace($Result.StdOut)){return $null};return $Result.StdOut|ConvertFrom-Json -Depth 40 -DateKind String}
function Set-PlanSection($Path,$Name,$NextName,$Body){$text=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true));$pattern="(?ms)^## $([regex]::Escape($Name))\s*.*?(?=^## $([regex]::Escape($NextName))\s*)";$updated=[regex]::Replace($text,$pattern,("## {0}`r`n`r`n{1}`r`n`r`n" -f $Name,$Body),1);if($updated-ceq$text){throw "section replacement failed: $Name"};Write-Utf8Bom -Path $Path -Content $updated}

$repoBefore=@(&git -C $RepoRoot status --porcelain --untracked-files=all)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('v1-v2-coexist-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $temp 'workspace';[void][IO.Directory]::CreateDirectory($workspace)
$taskScript=Join-Path $RepoRoot 'scripts\task.ps1';$advance=Join-Path $RepoRoot 'scripts\advance-stage.ps1'
try{
    foreach($file in @('scripts/lib/Harness.Protocol.psm1','scripts/task.ps1','scripts/advance-stage.ps1','tests/verify-v1-v2-coexistence.ps1')){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $file),[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq0) "$file parses" "$file parse failed"}

    $new=Read-Json (Invoke-Script $taskScript @('protocol','-TaskId','new-task','-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson'))
    $newV2=Read-Json (Invoke-Script $taskScript @('protocol','-TaskId','new-task','-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') 'v2')
    Check ($new.detected_protocol-ceq'new'-and$new.selected_protocol-ceq'v1'-and$new.side_effects.runtime_writes-eq0) 'auto keeps a new task on v1 without writes' 'new auto protocol resolution is wrong'
    Check ($newV2.selected_protocol-ceq'v2'-and$newV2.reason-ceq'explicit-v2-new-task') 'explicit v2 selects v2 for a new task' 'explicit v2 new-task resolution is wrong'

    $taskId='coexist-v1'
    $taskRoot=Join-Path $workspace "docs\tasks\$taskId";[void][IO.Directory]::CreateDirectory($taskRoot)
    $planPath=Join-Path $taskRoot 'plan.md'
    $plan=@"
---
task_id: $taskId
stage: PLAN
tool: codex
updated: 2026-07-14
---
# Coexistence Fixture

## Clarification
- 验收标准: v1 task reaches DONE through every canonical stage.
- 非目标: no product behavior.
- 受影响目录: isolated fixture only.
- 回滚策略: delete the isolated fixture.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- exercise the frozen v1 stage path.

## Verification
- ``pwsh -NoProfile -File tests/verify-v1-v2-coexistence.ps1``

## Risks
- isolated fixture only.

## Plan Review

## Implementation Notes

## Code Review

"@
    Write-Utf8Bom -Path $planPath -Content $plan
    $v1=Read-Json (Invoke-Script $taskScript @('protocol','-TaskId',$taskId,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson'))
    $v1Conflict=Invoke-Script $taskScript @('protocol','-TaskId',$taskId,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') 'v2'
    Check ($v1.detected_protocol-ceq'v1'-and$v1.selected_protocol-ceq'v1'-and$v1.v1_stage-ceq'PLAN') 'legal v1 plan wins auto detection' 'v1 artifact was not detected'
    Check ($v1Conflict.ExitCode-eq2-and$v1Conflict.StdErr-match'explicit v1-to-v2 migration') 'explicit v2 cannot override an existing v1 task' 'v1 conflict did not fail closed'

    $args=@('-TaskId',$taskId,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-VaultRoot',(Join-Path $workspace '.assistant'))
    $stageResults=[System.Collections.Generic.List[object]]::new()
    $stageResults.Add((Invoke-Script $advance (@('-ExpectedStage','PLAN')+$args) 'auto'))
    Set-PlanSection $planPath 'Plan Review' 'Implementation Notes' @"
### Run 1 · 2026-07-14 20:00 · runner: fixture
- verdict: pass
- findings: none
- next: IMPLEMENT
"@
    $stageResults.Add((Invoke-Script $advance (@('-ExpectedStage','PLAN_REVIEW')+$args) 'auto'))
    Set-PlanSection $planPath 'Implementation Notes' 'Code Review' @"
### Run 1 · 2026-07-14 20:01 · runner: fixture
- changed: isolated fixture only
- tests: v1 stage transition
- risks: none
- next: CODE_REVIEW
"@
    $stageResults.Add((Invoke-Script $advance (@('-ExpectedStage','IMPLEMENT')+$args) 'auto'))
    $text=[IO.File]::ReadAllText($planPath,[Text.UTF8Encoding]::new($false,$true));$text=[regex]::Replace($text,'(?ms)^## Code Review\s*\z',@"
## Code Review

### Run 1 · 2026-07-14 20:02 · runner: fixture
- verdict: pass
- findings: none
- next: TEST
"@);Write-Utf8Bom -Path $planPath -Content $text
    $stageResults.Add((Invoke-Script $advance (@('-ExpectedStage','CODE_REVIEW')+$args) 'auto'))
    $testPath=Join-Path $taskRoot 'test.md'
    Write-Utf8Bom -Path $testPath -Content @"
# Test Report

## Summary
- v1 coexistence transition fixture.

## Scope
- isolated v1 task.

## Inputs Reviewed
- plan.md

## Test Approach
- execute the canonical v1 stage command.

## Findings
- none.

## Evidence
- command: verify-v1-v2-coexistence
- exit_code: 0
- executed_at: 2026-07-14T20:03:00+08:00
- revision: 0000000
- evidence_path: docs/tasks/$taskId/test.md

## Risks / Gaps
- isolated fixture only.

## Conclusion
pass

## Handoff
- delivery: fixture complete
- follow_up: none
"@
    $stageResults.Add((Invoke-Script $advance (@('-ExpectedStage','TEST')+$args) 'auto'))
    $finalPlan=[IO.File]::ReadAllText($planPath,[Text.UTF8Encoding]::new($false,$true))
    Check (@($stageResults|Where-Object ExitCode -ne 0).Count-eq0-and$finalPlan-match'(?m)^stage:\s*DONE\s*$') 'v1 task advances through PLAN, PLAN_REVIEW, IMPLEMENT, CODE_REVIEW, TEST, and DONE' ("v1 stage chain failed: "+(($stageResults|ForEach-Object{$_.StdErr})-join' | '))

    $v2Id='coexist-v2';$v2Root=Join-Path $workspace ".assistant\runtime\tasks\$v2Id";[void][IO.Directory]::CreateDirectory($v2Root);[IO.File]::WriteAllText((Join-Path $v2Root 'task.json'),'{}',[Text.UTF8Encoding]::new($false))
    $v2=Read-Json (Invoke-Script $taskScript @('protocol','-TaskId',$v2Id,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') 'auto')
    $v2Conflict=Invoke-Script $taskScript @('protocol','-TaskId',$v2Id,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') 'v1'
    $advanceV2=Invoke-Script $advance @('-TaskId',$v2Id,'-ExpectedStage','PLAN','-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace) 'auto'
    Check ($v2.detected_protocol-ceq'v2'-and$v2.selected_protocol-ceq'v2') 'v2 task state wins auto detection' 'v2 artifact was not detected'
    Check ($v2Conflict.ExitCode-eq2-and$v2Conflict.StdErr-match'cannot use the v1 compatibility path') 'explicit v1 cannot override an existing v2 task' 'v2 conflict did not fail closed'
    Check ($advanceV2.ExitCode-eq1-and$advanceV2.StdErr-match'v2 task; advance-stage.ps1 is v1-only') 'v2 task is rejected before the v1 stage path runs' 'v2 task reached advance-stage'

    $corruptId='corrupt-v2';$corruptPath=Join-Path $workspace ".assistant\runtime\tasks\$corruptId\task.json";[void][IO.Directory]::CreateDirectory($corruptPath)
    $corrupt=Invoke-Script $taskScript @('protocol','-TaskId',$corruptId,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') 'auto'
    Check ($corrupt.ExitCode-eq2-and$corrupt.StdErr-match'v2 task state path is not a file') 'corrupt v2 artifact fails closed instead of falling back to v1' 'corrupt v2 artifact was misdetected'
}finally{
    if(Test-Path $temp){Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue}
}
$repoAfter=@(&git -C $RepoRoot status --porcelain --untracked-files=all);Check (@(Compare-Object $repoBefore $repoAfter).Count-eq0) 'verifier performs no repository writes' 'verifier changed repository state'
foreach($item in $script:passes){"[PASS] $item"};foreach($item in $script:failures){"[FAIL] $item"}
if($script:failures.Count){"STATUS: FAIL ($($script:failures.Count) failed)";exit 1};"STATUS: PASS ($($script:passes.Count) checks)";exit 0
