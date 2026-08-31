[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'tests/fixture-test-common.ps1')
$script:hashing = Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.Hashing.psm1') -Force -PassThru
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check([bool]$Condition,[string]$Label) { $script:checks++; if($Condition){"[PASS] $Label"}else{$script:failures.Add($Label);"[FAIL] $Label"} }
function Read-Text([string]$Path) { [IO.File]::ReadAllText((Join-Path $RepoRoot $Path),[Text.UTF8Encoding]::new($false,$true)) }
function Write-Json([string]$Path,$Document) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,($Document|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false)) }
function Invoke-Task([string[]]$Arguments) {
    $handle = Start-RepoProcess -UserProfile $homeRoot -ScriptPath (Join-Path $RepoRoot 'scripts/task.ps1') -Arguments ($Arguments + @('-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson'))
    try {
        if(-not $handle.Process.WaitForExit(30000)){ $handle.Process.Kill($true);throw 'Sunset fixture timed out' }
        return [ordered]@{code=$handle.Process.ExitCode;output=$handle.StdOut.GetAwaiter().GetResult().Trim();error=$handle.StdErr.GetAwaiter().GetResult().Trim()}
    } finally { $handle.Process.Dispose() }
}
function Snapshot {
    @(Get-ChildItem -LiteralPath $workspace -Force -Recurse | ForEach-Object {
        $value = if($_.PSIsContainer){'directory'}else{& $script:hashing {param($P) Get-HarnessFileSha256 -Path $P} $_.FullName}
        [IO.Path]::GetRelativePath($workspace,$_.FullName) + '|' + $value
    } | Sort-Object) -join "`n"
}
function Invoke-RetiredEntry([string]$Path,[string[]]$Arguments) {
    $handle=Start-RepoProcess -UserProfile $homeRoot -ScriptPath (Join-Path $RepoRoot $Path) -Arguments $Arguments
    try {
        if(-not $handle.Process.WaitForExit(30000)){$handle.Process.Kill($true);throw 'retired entry fixture timed out'}
        return [ordered]@{code=$handle.Process.ExitCode;output=$handle.StdOut.GetAwaiter().GetResult().Trim();error=$handle.StdErr.GetAwaiter().GetResult().Trim()}
    }finally{$handle.Process.Dispose()}
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('tk03-sunset-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $temp 'workspace';$homeRoot=Join-Path $temp 'home'
$prior=$env:HARNESS_PROTOCOL
try {
    [void][IO.Directory]::CreateDirectory($workspace);[void][IO.Directory]::CreateDirectory($homeRoot)
    foreach($path in @('scripts/lib/Harness.Protocol.psm1','scripts/lib/Harness.Policy.psm1','scripts/lib/Harness.Recovery.psm1','scripts/harness-status.ps1')) {
        $text=Read-Text $path
        Check ($text -notmatch 'Get-HarnessV1Frontmatter|Assert-HarnessV1Frontmatter|Harness\.LegacyMigration|lite-artifact-parser|ReadAllText\(\$plan|运行时') "$path has no legacy content reader/import"
    }
    $entry=Read-Text 'policies/entry-contract.md'
    Check ($entry -match 'existing-v2-or-admitted-v2-new-task' -and $entry -notmatch 'v1-fallback|else v1 plan|Only a detector-selected v1') 'Entry Contract has only v2 admission/recovery routes'
    foreach($preset in @('core','governed','full')) {
        $profile=(Read-Text "modules/distribution/profiles/$preset.json")|ConvertFrom-Json -AsHashtable
        $legacy=@($profile.asset_allowlist|Where-Object { $_.target -match '^(entry/(AGENTS\.md|advance-stage\.ps1|validate-lite-artifacts\.ps1)|entry-router$|orchestrator$|plan$|implement$|review$|test$|spec$|workflow-team$|运行时/(当前任务|恢复索引|上次会话|中断任务|tasks/))' })
        Check ($legacy.Count -eq 0 -and @($profile.enabled_modules|Where-Object module_id -ceq 'legacy-v1').Count -eq 0 -and $profile.features -cnotcontains 'v1-compatibility') "$preset installs no active legacy lifecycle or task mirror"
    }
    $env:HARNESS_PROTOCOL='auto'
    $body=[ordered]@{schema_version='requirement-contract/v1';task_id='sunset-v2';goal='Exercise only an isolated v2 task.';acceptance=@('AC-1');in_scope=@('fixture');out_of_scope=@('real work');product_constraints=@('no external writes');product_decisions=@();unresolved_product_decisions=@();source_authority=@('current-user-message')}
    $body.digest=Get-HarnessUtf8TextSha256 -Text ($body|ConvertTo-Json -Depth 30 -Compress)
    Write-Json (Join-Path $workspace 'contract.json') $body
    $created=Invoke-Task @('create','-TaskId','sunset-v2','-Contract','contract.json','-Profile','governed')
    Check ($created.code -eq 0 -and ($created.output|ConvertFrom-Json).task.status -ceq 'ready') 'artifact-free auto creates a native v2 task'
    if($created.code -ne 0){throw $created.error}
    $paused=Invoke-Task @('disable-v2')
    $before=Snapshot
    $env:HARNESS_PROTOCOL='v2'
    $risk=[ordered]@{user_visible_behavior=0;data_integrity=0;authorization_and_security=0;external_side_effects=0;blast_radius=0;rollback=0;verification_coverage=0}
    $policy=Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.Policy.psm1') -Force -PassThru
    $policyRejected=$false
    try { & $policy {param($R,$W,$Risk) Resolve-HarnessExecutionProfile -RepoRoot $R -WorkspaceRoot $W -Identity new -Intent write -RiskScores $Risk} $RepoRoot $workspace $risk | Out-Null } catch { $policyRejected=$_.Exception.Message -match 'new-work-not-admitted' }
    Check $policyRejected 'Direct policy cannot bypass explicit workspace pause'
    $taskModule=Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.TaskState.psm1') -Force -PassThru
    $nativeRejected=$false
    try { & $taskModule {param($R,$W) New-HarnessTaskState -RepoRoot $R -WorkspaceRoot $W -TaskId 'paused-native' -ContractPath 'absent.json'} $RepoRoot $workspace | Out-Null } catch { $nativeRejected=$_.Exception.Message -match 'new-work-not-admitted' }
    Check $nativeRejected 'native task creation cannot bypass pause by bypassing CLI'
    $status=Invoke-Task @('status','-TaskId','sunset-v2')
    $recovery=Invoke-Task @('status')
    Check ($status.code -eq 0 -and $recovery.code -eq 0) 'existing v2 status and recovery remain available while paused'
    Check ((Snapshot) -ceq $before) 'paused rejections and v2 recovery have zero writes'
    $transition=Invoke-Task @('transition','-TaskId','sunset-v2','-ExpectedVersion','1','-To','running')
    Check ($transition.code -eq 0 -and ($transition.output|ConvertFrom-Json).task.status -ceq 'running') 'existing v2 work is recoverable without deleting or downgrading its state'

    $legacyPlan=Join-Path $workspace 'docs/tasks/old-task/plan.md';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $legacyPlan));[IO.File]::WriteAllText($legacyPlan,'unreadable legacy sentinel',[Text.UTF8Encoding]::new($false))
    $legacyPointer=Join-Path $workspace '.assistant/运行时/当前任务.md';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $legacyPointer));[IO.File]::WriteAllText($legacyPointer,'legacy pointer sentinel',[Text.UTF8Encoding]::new($false))
    $legacyFlow=Join-Path $workspace '.assistant/orchestration/current-flow.md';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $legacyFlow));[IO.File]::WriteAllText($legacyFlow,'legacy flow sentinel',[Text.UTF8Encoding]::new($false))
    $before=Snapshot
    $locks=@([IO.File]::Open($legacyPlan,'Open','ReadWrite','None'),[IO.File]::Open($legacyPointer,'Open','ReadWrite','None'),[IO.File]::Open($legacyFlow,'Open','ReadWrite','None'))
    try {
        $recovery=Invoke-Task @('status')
        $legacy=Invoke-Task @('protocol','-TaskId','old-task')
        Check ($recovery.code -eq 0 -and $legacy.code -eq 2 -and $legacy.error -match 'legacy-task-requires-explicit-migration') 'locked legacy files do not prevent v2 recovery and are never read'
        $retired=Start-RepoProcess -UserProfile $homeRoot -ScriptPath (Join-Path $RepoRoot 'scripts/advance-stage.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-VaultRoot',(Join-Path $workspace '.assistant'),'-TaskId','old-task','-ExpectedStage','TEST','-SyncOnly','-ActivateCurrent')
        try {
            if(-not $retired.Process.WaitForExit(30000)){$retired.Process.Kill($true);throw 'retired lifecycle fixture timed out'}
            Check ($retired.Process.ExitCode -eq 2 -and $retired.StdErr.GetAwaiter().GetResult() -match 'v1-lifecycle-retired') 'retired stage/sync writer rejects before trying to read locked v1 files'
        } finally { $retired.Process.Dispose() }
        foreach ($path in @('scripts/repair-shared-memory.ps1','skills/obsidian-memory/scripts/repair-shared-memory.ps1')) {
            $repair=Invoke-RetiredEntry $path @('-VaultRoot',(Join-Path $workspace '.assistant'),'-EntryHost','test')
            Check ($repair.code -eq 2 -and $repair.error -match '^v1-memory-repair-retired') "$path rejects before reading locked legacy files or acquiring lifecycle locks"
        }
        $retire=Invoke-RetiredEntry 'scripts/repair-shared-memory.ps1' @('-VaultRoot',(Join-Path $workspace '.assistant'),'-RetireInactiveTaskId','old-task','-ExpectedRetireStage','TEST')
        Check ($retire.code -eq 2 -and $retire.error -match '^v1-memory-repair-retired') 'inactive-task retirement cannot bypass the repair entry rejection'
        foreach ($path in @('scripts/memory-maintain.ps1','skills/obsidian-memory/scripts/maintain-shared-memory.ps1')) {
            $maintain=Invoke-RetiredEntry $path @('-OrchestratorFlowPath',$legacyFlow)
            Check ($maintain.code -eq 2 -and $maintain.error -match '^v1-memory-maintain-flow-retired') "$path rejects implicit flow resolution before touching locked history"
        }
    } finally {foreach($lock in $locks){$lock.Dispose()}}
    Check ((Snapshot) -ceq $before) 'retired lifecycle, repair, retirement and legacy identity rejection preserve all bytes and directories'

    $migratedHistory=Join-Path $workspace 'docs/tasks/sunset-v2/plan.md'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $migratedHistory))
    [IO.File]::WriteAllText($migratedHistory,'immutable imported v1 history',[Text.UTF8Encoding]::new($false))
    $backend=Join-Path $workspace '.assistant/skills/codex/scripts/invoke_codex.ps1'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backend))
    $backendMarker=Join-Path $workspace 'backend-started.marker'
    [IO.File]::WriteAllText($backend,("[IO.File]::WriteAllText('"+$backendMarker.Replace("'","''")+"','unexpected')"),[Text.UTF8Encoding]::new($false))
    $before=Snapshot
    $locks=@([IO.File]::Open($legacyPlan,'Open','ReadWrite','None'),[IO.File]::Open($migratedHistory,'Open','ReadWrite','None'),[IO.File]::Open($legacyPointer,'Open','ReadWrite','None'))
    try {
        foreach($id in @('old-task','sunset-v2')) {
            $result=Invoke-RetiredEntry 'scripts/invoke-harness-skill.ps1' @('-TaskId',$id,'-Stage','PLAN_REVIEW','-Skill','codex','-Tool','codex','-WorkspaceRoot',$workspace,'-PayloadJson','{"task":"must never run"}')
            $value=$result.output|ConvertFrom-Json
            Check ($result.code -eq 1 -and -not $value.ok -and $value.status -ceq 'rejected' -and $value.errors[0] -match '^v1-delegation-retired') "legacy delegation CLI rejects $id before reading locked history or starting backend"
        }
        $api=Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.AdapterDelegation.psm1') -Force -PassThru
        $prepare=[ordered]@{schema_version='adapter-kernel-api/v1';message_type='request';body=[ordered]@{operation='prepare_delegation';repo_root=$RepoRoot;workspace_root=$workspace;task_id='sunset-v2';stage='PLAN_REVIEW';skill='codex';tool='codex';tool_profile_id='';mode='readonly';payload_json='{"task":"must never run"}'}}
        $commit=[ordered]@{schema_version='adapter-kernel-api/v1';message_type='request';body=[ordered]@{operation='commit_delegation';delegation_id=('a'*32);succeeded=$true;artifact_base64='eA==';session_id='';diagnostics=@()}}
        foreach($request in @($prepare,$commit)) {
            $rejected=$false
            try {& $api {param($R) if($R.body.operation -ceq 'prepare_delegation'){Invoke-HarnessAdapterPrepareDelegation -Request $R}else{Invoke-HarnessAdapterCommitDelegation -Request $R}} $request|Out-Null}
            catch{$rejected=$_.Exception.Message -match '^v1-delegation-retired' -and $_.Exception.Data['adapter_status'] -ceq 'rejected'}
            Check $rejected "direct $($request.body.operation) cannot bypass legacy retirement"
        }
        $team=Invoke-RetiredEntry 'skills/workflow-team/scripts/spawn-team.ps1' @('-TaskId','old-task','-RepoRoot',$workspace)
        $value=$team.output|ConvertFrom-Json
        Check ($team.code -eq 2 -and -not $value.ok -and $value.reason -ceq 'v1-team-retired' -and $value.spawned_roles.Count -eq 0) 'legacy Team entry rejects before reading locked stage or starting roles'
    }finally{foreach($lock in $locks){$lock.Dispose()}}
    Check (-not(Test-Path -LiteralPath $backendMarker) -and (Snapshot) -ceq $before) 'retired delegation and Team leave backend, history, state, pointer and directory set unchanged'

    $runtime=Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeDefault.psm1') -Force -PassThru
    $document=& $runtime {param($R,$W) New-HarnessRuntimeDefaultDecisionDocument -RepoRoot $R -WorkspaceRoot $W -Scope release-default} $RepoRoot $workspace
    $document.new_task_protocol='v1'
    $document.decision_digest=& $runtime {param($D) Get-HarnessRuntimeDefaultDecisionDigest -Document $D} $document
    $json=$document|ConvertTo-Json -Depth 30 -Compress
    Check (Test-Json -Json $json -SchemaFile (Join-Path $RepoRoot 'schemas/runtime-default-decision.schema.json')) 'historical v1 Decision Schema remains unchanged'
    $rejected=$false;try{$rejected=-not(Test-Json -Json $json -SchemaFile (Join-Path $RepoRoot 'schemas/runtime-default-admission.schema.json') -ErrorAction Stop)}catch{$rejected=$true}
    Check $rejected 'current Runtime admission Schema rejects an otherwise valid historical v1 Decision'
    $reset=Invoke-Task @('reset-auto');$env:HARNESS_PROTOCOL='auto'
    Write-Json (Join-Path $workspace '.assistant/runtime/protocol-default.json') $document
    $before=Snapshot;$result=Invoke-Task @('protocol');$value=$result.output|ConvertFrom-Json
    Check ($result.code -eq 0 -and $null -eq $value.selected_protocol -and $value.new_task_admission -ceq 'blocked') 'historical v1 Runtime Decision blocks new work instead of falling back'
    Check ((Snapshot) -ceq $before) 'rejected historical Decision and digest are preserved byte-for-byte'
    $decisionPath=Join-Path $workspace '.assistant/runtime/protocol-default.json'
    [IO.File]::Delete($decisionPath)
    [void][IO.Directory]::CreateDirectory($decisionPath)
    $before=Snapshot
    $result=Invoke-Task @('protocol');$value=$result.output|ConvertFrom-Json
    $recovery=Invoke-Task @('status','-TaskId','sunset-v2')
    Check ($result.code -eq 0 -and $null -eq $value.selected_protocol -and $value.new_task_admission -ceq 'blocked' -and $value.reason -ceq 'runtime-default-not-regular-file') 'existing non-file Decision is invalid, never a missing default that admits v2'
    Check ($recovery.code -eq 0 -and (Snapshot) -ceq $before) 'non-file Decision blocks new work but preserves existing v2 recovery with zero writes'
    $primaryWorkspace=$workspace
    foreach($parent in @('.assistant','.assistant/runtime','.assistant/config')) {
        $workspace=Join-Path $temp ('invalid-parent-'+$parent.Replace('/','-'))
        [void][IO.Directory]::CreateDirectory($workspace)
        $occupied=Join-Path $workspace $parent
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $occupied))
        [IO.File]::WriteAllText($occupied,'not a directory',[Text.UTF8Encoding]::new($false))
        $before=Snapshot;$result=Invoke-Task @('protocol')
        $blocked=$result.code -eq 2
        if($result.code -eq 0){$value=$result.output|ConvertFrom-Json;$blocked=$null -eq $value.selected_protocol -and $value.new_task_admission -ceq 'blocked'}
        Check $blocked "$parent occupied by a file is invalid, not missing admission input"
        Check ((Snapshot) -ceq $before) "$parent rejection preserves both file bytes and directory set"
    }
    $workspace=$primaryWorkspace
} finally {
    if($null-eq$prior){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$prior}
    $resolved=[IO.Path]::GetFullPath($temp);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)){throw 'fixture cleanup escaped its root'}
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
if($failures.Count){"STATUS: FAIL ($($failures.Count)/$checks)";exit 1}
"STATUS: PASS ($checks checks; migration/Release execution not performed by this verifier)"
exit 0
