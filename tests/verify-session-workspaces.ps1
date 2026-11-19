[CmdletBinding()]
param([string]$RepoRoot='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.AdapterAction.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.SessionWorkspace.psm1') -Force
. (Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeKernel.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('harness-session-workspaces-' + [guid]::NewGuid().ToString('N'))
$passes = 0
function Check([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passes++
}
function Write-Json([string]$Path,$Value) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 40) + "`n",[Text.UTF8Encoding]::new($false))
}
function Expect-Denial([scriptblock]$Action,[string]$Pattern,[string]$Name) {
    $errorText = ''
    try { $null = & $Action } catch { $errorText = $_.Exception.Message }
    Check ($errorText -match $Pattern) "$Name ($errorText)"
}
function Add-Task([string]$Root,[string[]]$Approvals=@()) {
    $contract = [ordered]@{schema_version='requirement-contract/v1';task_id='workspace-fixture';goal='Offline multi-workspace boundary fixture';acceptance=@('No real writes by preflight');in_scope=@('Fixture directories');
        out_of_scope=@();product_constraints=@();product_decisions=@();unresolved_product_decisions=@();source_authority=@('user-confirmed')}
    $contract.digest = Get-HarnessSha256Text -Content (ConvertTo-HarnessKernelJson -Value $contract -Compress)
    Write-Json (Join-Path $Root 'contract.json') $contract
    $task = [ordered]@{schema_version='task-state/v2';task_id='workspace-fixture';version=2;status='running';identity='new';intent='write';requirement_state='clear';execution_profile='critical';persistence='durable';
        contract_path='contract.json';contract_digest=$contract.digest;block_reason=$null;
        policies=[ordered]@{plan_required=$true;approval_required=$true;rollback_required=$true;independent_review_required=$true;verification_required=$true;dry_run_required=$true};
        approvals=@($Approvals);evidence_path=$null;created_at=[datetimeoffset]::UtcNow.ToString('o');updated_at=[datetimeoffset]::UtcNow.ToString('o')}
    Write-Json (Join-Path $Root '.assistant/runtime/tasks/workspace-fixture/task.json') $task
    return $task
}
function Add-Approval([string]$Root,$Task,$Operation,[string]$Id) {
    $approval = [ordered]@{schema_version='approval/v1';approval_id=$Id;task_id=$Task.task_id;task_version=$Task.version;contract_digest=$Task.contract_digest;
        protected_operation=$Operation;approval_type='architecture';approved_scope=@($Operation.approval_scope);approver='offline-fixture-only';approved_at=[datetimeoffset]::UtcNow.AddMinutes(-1).ToString('o');expires_at=$null;status='granted'}
    Write-Json (Join-Path $Root ".assistant/runtime/tasks/workspace-fixture/approvals/$Id.json") $approval
}
try {
    $primary,$service,$front,$sibling = @('primary','service','front','service-other') | ForEach-Object { Join-Path $fixture $_ }
    foreach ($root in @($primary,$service,$front,$sibling)) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root '.assistant/entry'))
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'src'))
        [IO.File]::WriteAllText((Join-Path $root '.assistant/entry/task.ps1'),'# Synthetic installed entry; never executed')
        Write-Json (Join-Path $root '.assistant/config/protocol.json') @{schema_version='harness-protocol-config/v2';new_task_protocol='v2';new_work='enabled'}
    }
    $session = 'offline-workspace-fixture'
    $grantPath = ".assistant/runtime/session-workspaces/$((Get-HarnessSha256Text -Content $session).Substring(7)).json"
    $grantFull = Join-Path $primary $grantPath
    $arguments = @{RepoRoot=$RepoRoot;WorkspaceRoot=$primary;SessionId=$session;AdditionalWorkspaceRoots=@($service,$front);TaskWorkspaceRoot=$primary;TaskId='workspace-fixture';ExpectedVersion=2;ExpectedCurrentDigest='missing'}
    $preflight = @{RepoRoot=$RepoRoot;WorkspaceRoot=$primary;SessionId=$session;ActionKind='file_mutation';ChangedPaths=@((Join-Path $service 'src/plain.txt'))}
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @preflight } 'escapes WorkspaceRoot' 'unregistered outside target denied'
    $task = Add-Task $primary @('apr_fixture')
    $identity = { param($Root) [ordered]@{path=$Root;identity=(Get-HarnessPhysicalPathIdentity -Path $Root)} }
    $intent = [ordered]@{session_id=$session;primary=(& $identity $primary);workspaces=@((& $identity $service),(& $identity $front));expected_current_digest='missing'}
    $operation = New-HarnessProtectedOperation -TaskVersion 2 -ContractDigest $task.contract_digest -Environment workspace -ActionCategory protected-write -Targets @($grantPath) -ApprovalType architecture `
        -ApprovalScope @('rule:session-workspace-registration',"command_digest:$(Get-HarnessSha256Text -Content (ConvertTo-HarnessKernelJson -Value $intent -Compress))","path:$grantPath")
    Expect-Denial { Set-HarnessSessionWorkspaceGrant @arguments -DryRun } 'does not exist' 'registration requires actual Approval'
    Add-Approval $primary $task $operation 'apr_fixture'
    $stale = @{} + $arguments
    $stale.ExpectedVersion = 1
    Expect-Denial { Set-HarnessSessionWorkspaceGrant @stale -DryRun } 'current clear Critical' 'registration refuses stale version'
    $dry = Set-HarnessSessionWorkspaceGrant @arguments -DryRun
    Check ($dry.dry_run -and -not $dry.written -and -not (Test-Path $grantFull)) 'registration dry-run performs zero writes'
    $registered = Set-HarnessSessionWorkspaceGrant @arguments
    Check ($registered.written -and (Test-Path $grantFull)) 'scoped approved registration succeeds'
    $grantBytes = [IO.File]::ReadAllBytes($grantFull)
    $revoke = @{} + $arguments
    $revoke.AdditionalWorkspaceRoots = @()
    $revoke.ExpectedCurrentDigest = 'sha256:' + (Get-FileHash -LiteralPath $grantFull).Hash.ToLowerInvariant()
    $revokeTask = Add-Task $primary @('apr_revoke')
    $revokeIntent = [ordered]@{session_id=$session;primary=(& $identity $primary);workspaces=@();expected_current_digest=$revoke.ExpectedCurrentDigest}
    $revokeOperation = New-HarnessProtectedOperation -TaskVersion 2 -ContractDigest $revokeTask.contract_digest -Environment workspace -ActionCategory protected-write -Targets @($grantPath) -ApprovalType architecture `
        -ApprovalScope @('rule:session-workspace-registration',"command_digest:$(Get-HarnessSha256Text -Content (ConvertTo-HarnessKernelJson -Value $revokeIntent -Compress))","path:$grantPath")
    Add-Approval $primary $revokeTask $revokeOperation 'apr_revoke'
    $revoked = Set-HarnessSessionWorkspaceGrant @revoke
    Check ($revoked.written -and $revoked.grant.workspaces.Count -eq 0) 'approved empty-root registration revokes additional roots'
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @preflight } 'escapes WorkspaceRoot' 'revoked session cannot edit previous targets'
    $null = Add-Task $primary @('apr_fixture')
    [IO.File]::WriteAllBytes($grantFull,$grantBytes)
    Expect-Denial { Set-HarnessSessionWorkspaceGrant @arguments } 'current digest is stale' 'registration rejects stale CAS'
    $changedScope = @{} + $arguments
    $changedScope.AdditionalWorkspaceRoots = @($sibling)
    Expect-Denial { Set-HarnessSessionWorkspaceGrant @changedScope -DryRun } 'no current granted Approval' 'Approval cannot authorize a different root set'
    $overlap = @{} + $arguments
    $overlap.AdditionalWorkspaceRoots = @($primary)
    Expect-Denial { Set-HarnessSessionWorkspaceGrant @overlap -DryRun } 'must not overlap' 'overlapping roots denied'
    $response = Invoke-HarnessAdapterPreflightAction @preflight
    Check ($response.body.allowed -and $response.body.workspace_checks[0].workspace_root -ceq $service) 'outside target routed to its workspace'
    Check (Test-Json -Json ($response | ConvertTo-Json -Depth 40) -SchemaFile (Join-Path $RepoRoot 'schemas/adapter-kernel-api.schema.json')) 'cross-workspace response satisfies strict Adapter schema'
    $relative = @{} + $preflight
    $relative.ChangedPaths = @('src/plain.txt')
    Check ((Invoke-HarnessAdapterPreflightAction @relative).body.allowed) 'relative target stays in host cwd'
    $relative.SessionId = ''
    Check ((Invoke-HarnessAdapterPreflightAction @relative).body.allowed) 'same-workspace path needs no session grant'
    foreach ($badSession in @('', 'another-session')) {
        $bad = @{} + $preflight
        $bad.SessionId = $badSession
        Expect-Denial { Invoke-HarnessAdapterPreflightAction @bad } 'escapes WorkspaceRoot' 'session scope cannot be inherited'
    }
    foreach ($badTarget in @((Join-Path $sibling 'src/plain.txt'), '../service/src/plain.txt', $grantFull)) {
        $bad = @{} + $preflight
        $bad.ChangedPaths = @($badTarget)
        Expect-Denial { Invoke-HarnessAdapterPreflightAction @bad } 'escapes WorkspaceRoot|registration API' 'sibling, relative escape and grant self-edit denied'
    }
    Expect-Denial { Invoke-HarnessAdapterControlledWrite -RepoRoot $RepoRoot -WorkspaceRoot $primary -TargetPath $grantPath -Content '{}' -ExpectedCurrentSha256 missing } 'control path' 'controlled-write adapter cannot self-authorize a grant'
    $bad = @{} + $preflight
    $bad.SessionMode = 'read-only'
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @bad } 'read-only session' 'additional roots do not weaken read-only'
    $patch = "*** Begin Patch`n*** Add File: src/local.txt`n+fixture`n*** Add File: $(Join-Path $service 'src/plain.txt')`n+fixture`n*** Add File: $(Join-Path $front 'src/plain.txt')`n+fixture`n*** End Patch"
    $patchArguments = @{RepoRoot=$RepoRoot;WorkspaceRoot=$primary;SessionId=$session;ActionKind='apply_patch';PatchText=$patch}
    $mixed = Invoke-HarnessAdapterPreflightAction @patchArguments
    Check ($mixed.body.workspace_checks.Count -eq 3 -and $mixed.body.allowed) 'mixed-root patch checks every workspace'
    $patchArguments.PatchText = $patch.Replace((Join-Path $front 'src/plain.txt'),(Join-Path $sibling 'src/plain.txt'))
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @patchArguments } 'escapes WorkspaceRoot' 'bad last target denies entire preflight'
    # Core no longer protects auth paths; the target overlay keeps target-local protection covered.
    Write-Json (Join-Path $service '.assistant/policies/protected-actions.local.json') @{schema_version='protected-actions-overlay/v1';rules=@(@{id='fixture-authorization-path';match=@{path_globs=@('**/auth/**')};requires_profile='governed';requires_approval='none';requires_dry_run=$false;requires_independent_review=$true})}
    $protected = @{} + $preflight
    $protected.ChangedPaths = @((Join-Path $service 'src/auth/canary.txt'))
    $protected.TaskId = 'workspace-fixture'
    $protected.ExpectedVersion = 2
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @protected } 'protected task is invalid' 'primary task cannot substitute for target task'
    $null = Add-Task $service
    Check ((Invoke-HarnessAdapterPreflightAction @protected).body.protected) 'target-local valid task preserves protected classification'
    Write-Json (Join-Path $front '.assistant/policies/protected-actions.local.json') @{schema_version='protected-actions-overlay/v1';rules=@(@{id='fixture-target-only';match=@{path_globs=@('src/plain.txt')};requires_profile='critical';requires_approval='architecture';requires_dry_run=$false;requires_independent_review=$true})}
    $patchArguments.PatchText = $patch
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @patchArguments } 'requires TaskId' 'target overlay denies complete mixed patch'
    $frontTask = Add-Task $front @('apr_target')
    Add-Approval $front $frontTask $operation 'apr_target'
    $targetOperation = New-HarnessProtectedOperation -TaskVersion 2 -ContractDigest $frontTask.contract_digest -Environment workspace -ActionCategory protected-write `
        -Targets @('src/plain.txt') -ApprovalType architecture -ApprovalScope @('rule:fixture-target-only','path:src/plain.txt')
    $patchArguments.TaskId = 'workspace-fixture'
    $patchArguments.ExpectedVersion = 2
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @patchArguments } 'no current granted Approval' 'registration Approval cannot authorize target protected writes'
    Add-Approval $front $frontTask $targetOperation 'apr_target'
    $approvalPath = Join-Path $front '.assistant/runtime/tasks/workspace-fixture/approvals/apr_target.json'
    $approvalBefore = (Get-FileHash -LiteralPath $approvalPath).Hash
    $approvedPatch = Invoke-HarnessAdapterPreflightAction @patchArguments
    Check ($approvedPatch.body.allowed -and $approvedPatch.body.protected -and $approvedPatch.body.workspace_checks[2].approval_id -ceq 'apr_target' -and $null -eq $approvedPatch.body.approval_id) 'mixed protected patch keeps target-local Approval results'
    Check ((Get-FileHash -LiteralPath $approvalPath).Hash -ceq $approvalBefore) 'preflight never consumes or edits Approval'
    [IO.File]::WriteAllText((Join-Path $front 'contract.json'),'{}',[Text.UTF8Encoding]::new($false))
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @patchArguments } 'Contract' 'invalid target Contract denies complete preflight'
    foreach ($field in @('session_id','identity','expires_at','unknown')) {
        $tampered = $registered.grant | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        switch ($field) {
            session_id { $tampered.session_id = 'another-session' }
            identity { $tampered.workspaces[0].identity = 'stale' }
            expires_at { $tampered.expires_at = [datetimeoffset]::UtcNow.AddDays(-1).ToString('o') }
            unknown { $tampered.unknown = 'denied' }
        }
        Write-Json $grantFull $tampered
        Expect-Denial { Invoke-HarnessAdapterPreflightAction @preflight } 'stale|expired|schema validation' 'tampered grant fails closed'
        Check ((Invoke-HarnessAdapterPreflightAction @relative).body.allowed) 'ordinary direct path ignores unrelated malformed grant'
    }
    [IO.File]::WriteAllBytes($grantFull,$grantBytes)
    Write-Json (Join-Path $service '.assistant/config/protocol.json') @{schema_version='harness-protocol-config/v2';new_task_protocol='v2';new_work='paused'}
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @preflight } 'requires installed v2 admission' 'paused target admission refuses extra-root routing'
    Write-Json (Join-Path $service '.assistant/config/protocol.json') @{schema_version='harness-protocol-config/v2';new_task_protocol='v2';new_work='enabled'}
    $junction = Join-Path $service 'src/link'
    $null = New-Item -ItemType Junction -Path $junction -Target $sibling
    $bad = @{} + $preflight
    $bad.ChangedPaths = @((Join-Path $junction 'escaped.txt'))
    Expect-Denial { Invoke-HarnessAdapterPreflightAction @bad } 'reparse point' 'additional root retains junction rejection'
    [IO.Directory]::Delete($junction)
    $hook = Join-Path $fixture 'pretooluse.ps1'
    $source = [IO.File]::ReadAllText((Join-Path $RepoRoot 'runtime-hooks/claude/pretooluse.ps1')).Replace('{REPO_ROOT}',$RepoRoot)
    [IO.File]::WriteAllText($hook,$source,[Text.UTF8Encoding]::new($true))
    $payload = @{cwd=$primary;session_id=$session;tool_name='Write';tool_input=@{file_path=(Join-Path $service 'src/plain.txt');content='fixture'}}
    $result = Invoke-HarnessKernelProcess -FilePath (Get-Command pwsh).Source -WorkingDirectory $RepoRoot -Arguments @('-NoProfile','-NonInteractive','-File',$hook) -TimeoutMilliseconds 10000 -StandardInput ($payload | ConvertTo-Json -Compress)
    Check ($result.Complete -and $result.ExitCode -eq 0 -and $result.StdOut.Trim() -ceq '{}') 'rendered host adapter forwards documented session_id'
    Check (-not (Test-Path (Join-Path $service 'src/plain.txt')) -and -not (Test-Path (Join-Path $front 'src/plain.txt'))) 'all preflights leave business fixture targets unchanged'
    Write-Output "STATUS: PASS; checks=$passes; fixtures_only=true; desktop_execution=NOT_VERIFIED"
} finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = [IO.Path]::GetFullPath($fixture)
        if (-not $resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) { throw 'fixture cleanup escaped Temp' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
