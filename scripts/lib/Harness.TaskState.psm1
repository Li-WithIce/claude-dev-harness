. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')
Import-Module (Join-Path $PSScriptRoot 'Harness.Governance.psm1') -Force -ErrorAction Stop

$script:RuntimeRelative = '.assistant/runtime'
$script:SchemaRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:TaskStateWorkspaceIdentityCache = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:Transitions = [ordered]@{blocked = @('ready')
    ready     = @('running','cancelled')
    running   = @('verifying','blocked','failed','paused')
    verifying = @('done','running','paused','failed')
    paused    = @('running','verifying','cancelled')
    failed    = @('running')
    done      = @()
    cancelled = @()}
$script:WriterTransitionEvents = @{ready='requirement.resolved';running='execution.started';
    verifying='verification.started';blocked='requirement.blocked';
    paused='execution.paused';done='task.completed';
    failed='task.failed';cancelled='task.cancelled'}
function Get-TaskStatePaths {
    param([string]$TaskId)
    return [pscustomobject]@{TaskRoot="$($script:RuntimeRelative)/tasks/$TaskId";Task="$($script:RuntimeRelative)/tasks/$TaskId/task.json"
        Events="$($script:RuntimeRelative)/tasks/$TaskId/events.jsonl";Current="$($script:RuntimeRelative)/current.json"}
}
function Get-TaskStateWorkspaceIdentity {
    param([string]$WorkspaceRoot)
    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if (-not $script:TaskStateWorkspaceIdentityCache.ContainsKey($root)) { $script:TaskStateWorkspaceIdentityCache[$root] = Get-HarnessPhysicalPathIdentity -Path $root }
    return $script:TaskStateWorkspaceIdentityCache[$root]
}

function Assert-TaskStateWorkspaceIdentityCurrent {
    param([string]$WorkspaceRoot)
    if ((Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot) -cne (Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot)) { throw 'WorkspaceRoot physical identity changed during task-state operation' }
    Assert-HarnessKernelCondition ($env:DEV_HARNESS_TEST_TASK_STATE_FAIL_IDENTITY_RECHECK -cne '1') 'injected task-state identity recheck failure'
}

function Invoke-TaskStateLocked {
    param([string]$WorkspaceRoot,[scriptblock]$Action)
    $mutex = $null
    try {
        $mutex = Enter-HarnessKernelMutex -Name (Get-HarnessKernelMutexName -WorkspaceIdentity (Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot) -Suffix state) -Label task-state
        return & $Action
    } finally {
        Exit-HarnessKernelMutex -Mutex $mutex
    }
}

function Assert-V2WriteProtocol {
    if ($env:HARNESS_PROTOCOL -cne 'v2') { throw 'task-state writes require explicit HARNESS_PROTOCOL=v2' }
    $script:TaskStateWorkspaceIdentityCache.Clear()
}

function Get-TaskPolicyFlags {
    param([string]$RepoRoot,[string]$Profile,[string[]]$Capabilities)
    if ($Profile -cnotin @('governed','critical')) { throw 'durable task profile must be governed or critical' }
    $profilePolicy = (Get-Content -LiteralPath (Join-Path $RepoRoot 'policies\execution-profiles.json') -Raw -Encoding utf8 | ConvertFrom-HarnessJson -ErrorAction Stop).profiles[$Profile]
    $invalid = @($Capabilities | Where-Object { (@($profilePolicy.minimum_capabilities) + @($profilePolicy.configurable_capabilities)) -cnotcontains $_ } | Select-Object -First 1)
    if ($invalid.Count) { throw "capability is not allowed for ${Profile}: $($invalid[0])" }
    $selected = @($profilePolicy.minimum_capabilities) + @($Capabilities)
    if ($selected -cnotcontains 'verification_required' -or $selected -cnotcontains 'durable_artifacts_required') { throw 'durable task policy is missing mandatory capabilities' }
    $result = [ordered]@{}
    foreach ($key in @('plan','approval','rollback','independent_review','verification','dry_run')) {
        $result["${key}_required"] = $selected -ccontains "${key}_required"
    }
    return $result
}

function Assert-TaskStateDocument {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Task)
    Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $Task -Schema task-state.schema.json -Label 'task state'
    Assert-HarnessKernelCondition ($Task.persistence -ceq 'durable' -and $Task.intent -ceq 'write' -and $Task.execution_profile -cin @('governed','critical') -and `
        -not @(@('contract_path','contract_digest','block_reason','approvals','evidence_path') | Where-Object { -not $Task.Contains($_) }).Count) 'persisted task state has an invalid durable execution profile or invariant set'
    Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace([string]$Task.contract_path) -and [string]$Task.contract_digest -cmatch '^sha256:[0-9a-f]{64}$') 'persisted task state requires a bound Requirement Contract'
    $expectedPolicies = Get-TaskPolicyFlags -RepoRoot $RepoRoot -Profile $Task.execution_profile -Capabilities @($Task.policies.Keys | Where-Object { [bool]$Task.policies[$_] })
    Assert-HarnessKernelCondition (-not @($expectedPolicies.Keys | Where-Object {
        [bool]$(if ($_ -ceq 'dry_run_required' -and -not $Task.policies.Contains($_)) { $Task.execution_profile -ceq 'critical' } else { $Task.policies[$_] }) -ne [bool]$expectedPolicies[$_]
    }).Count) 'persisted task state policies do not match its execution profile'
    Assert-HarnessKernelCondition $(if([string]$Task.status-ceq'blocked'){
        [string]$Task.requirement_state-ceq'blocked'-and-not[string]::IsNullOrWhiteSpace([string]$Task.block_reason)
    }else{[string]$Task.requirement_state-ceq'clear'-and$null-eq$Task.block_reason}) 'persisted task Requirement state is inconsistent'
}

function Read-TaskStateDocument {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$Path,[string]$ExpectedTaskId)
    $task = (Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'task state').Document
    Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $task
    if ($task.task_id -cne $ExpectedTaskId) { throw 'persisted task state task_id does not match its canonical path' }
    return $task
}

function Read-CurrentPointer {
    param([string]$WorkspaceRoot,[string]$Path)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'current pointer' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }
    return (Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $fullPath -Label 'current pointer' -RepoRoot $script:SchemaRoot -Schema current-pointer.schema.json).Document
}

function ConvertFrom-TaskEventLog {
    param([string]$Text,[string]$Label)
    if ($Text.Length -and -not $Text.EndsWith("`n",[StringComparison]::Ordinal)) { throw "$Label must end with a newline" }
    $lines = @(if ($Text.Length) { $Text.Substring(0,$Text.Length-1) -split "`n" | ForEach-Object { $_.TrimEnd("`r") } })
    return [pscustomobject]@{Text=$Text;Count=$lines.Count;
        Lines=$lines;Events=@($lines | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { throw "$Label contains a blank line" }
        $event = ConvertFrom-HarnessKernelJson -Json $_ -Label $Label -RequireObject
        Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $event -Schema event.schema.json -Label 'event'
        $event
    })}
}

function Read-EventLog {
    param([string]$WorkspaceRoot,[string]$Path)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'event log' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return ConvertFrom-TaskEventLog -Text '' -Label 'event log' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'event log is not a file' }
    try { $text = [IO.File]::ReadAllText($fullPath,[Text.UTF8Encoding]::new($false,$true)) } catch { throw "event log is not valid UTF-8: $($_.Exception.Message)" }
    return ConvertFrom-TaskEventLog -Text $text -Label 'event log'
}

function New-TaskEvent {
    param([string]$EventId,[string]$TaskId,[int]$Version,[string]$Type,[string]$Host,[string]$Model,[string]$Timestamp,[System.Collections.IDictionary]$Payload)
    return [ordered]@{ schema_version='event/v1';event_id=$EventId;
        task_id=$TaskId;task_version=$Version;
        type=$Type;actor=[ordered]@{host=$Host;model=$Model}
        occurred_at=$Timestamp;payload=$Payload }
}

function New-TransactionStep {
    param([string]$WorkspaceRoot,[string]$Id,[string]$RelativePath,[ValidateSet('write','delete')][string]$Action,[AllowNull()][string]$Content)
    $before,$beforeContentBase64 = (Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $RelativePath),$null
    if ($Id -cin @('task-state','current-pointer') -and $null -ne $before) {
        $beforeBytes = [System.IO.File]::ReadAllBytes((Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $RelativePath -Label "$Id transaction preimage" -MustExist File))
        if ((Get-HarnessSha256Text -Content ([System.Text.UTF8Encoding]::new($false,$true).GetString($beforeBytes))) -cne $before) { throw "$Id transaction preimage changed while preparing the journal" }
        $beforeContentBase64 = [Convert]::ToBase64String($beforeBytes)
    }
    if ($Action -ceq 'delete' -and $null -eq $before) { throw "delete transaction target does not exist: $RelativePath" }
    return [ordered]@{
        id=$Id
        relative_path=$RelativePath
        action=$Action
        before_digest=$before
        before_content_base64=$beforeContentBase64
        after_digest=$(if($Action-ceq'write'){Get-HarnessSha256Text -Content $Content}else{$null})
        content_base64=$(if($Action-ceq'write'){[Convert]::ToBase64String((New-Object System.Text.UTF8Encoding($false)).GetBytes($Content))}else{$null})
    }
}

function Get-PendingTransactions {
    param([string]$WorkspaceRoot,[string]$TaskId='',[string[]]$ReservedPaths=@(),[string]$TransactionId='')
    $root = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes' -AllowMissing
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Filter 'txn_*.json' -File | ForEach-Object {
        $record = Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path (Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $_.FullName) -Location pending
        if ($record.Journal.task_id -ceq $TaskId) { $record.Journal.transaction_id }
        if ($ReservedPaths.Count) {
            if ($record.Journal.transaction_id -ceq $TransactionId) { throw 'transaction journal is already pending' }
            foreach($overlap in @($record.Journal.steps | Where-Object { $ReservedPaths -contains $_.relative_path } | Select-Object -First 1)){throw "transaction target is reserved by pending transaction $($record.Journal.transaction_id): $($overlap.relative_path)"}
        }
    })
}

function Get-TransactionIntentDigest {
    param([System.Collections.IDictionary]$Journal,[string]$WorkspaceRoot='',[switch]$Legacy)
    $intent = Select-HarnessKernelKeys -Value $Journal -Keys (@('transaction_id','operation','task_id','expected_version') + $(if ($Legacy) { @() } else { @('workspace_identity','operation_context') }) + @('replay_command','created_at'))
    if ($Legacy) {
        $intent.Insert(0,'workspace_identity',(Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot))
        $intent.Insert(0,'format','task-transaction/legacy-v1')
    }
    $intent.steps = @($Journal.steps | ForEach-Object { Select-HarnessKernelKeys -Value $_ -Keys `
        (@('id','relative_path','action','before_digest') + $(if ($Legacy) { @() } else { @('before_content_base64') }) + @('after_digest','content_base64')) })
    return Get-HarnessSha256Text -Content (ConvertTo-HarnessKernelJson -Value $intent)
}

function Get-TransactionStepText {
    param([System.Collections.IDictionary]$Step,[string]$Label,[string]$Property='content_base64',[switch]$AllowNull)
    if ($null -eq $Step[$Property] -and $AllowNull) { return $null }
    try {
        return [System.Text.UTF8Encoding]::new($false,$true).GetString([Convert]::FromBase64String([string]$Step[$Property]))
    } catch {
        throw "$Label is not valid base64-encoded UTF-8"
    }
}

function Get-TransactionPayloadDocument {
    param([Collections.IDictionary]$Step,[string]$Label,[string]$Schema,[string]$TaskId,[int64]$Version,[string]$VersionField='task_version',[switch]$Before)
    $content = Get-TransactionStepText -Step $Step -Label $Label -Property $(if ($Before) { 'before_content_base64' } else { 'content_base64' }) -AllowNull:$Before
    if ($Before -and $null -eq $content) { throw "$Label is missing" }
    $document = ConvertFrom-HarnessKernelJson -Json $content -Label $Label -RequireObject
    Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $document -Schema $Schema -Label $Label
    Assert-HarnessKernelCondition ($document.task_id -ceq $TaskId -and [int64]$document[$VersionField] -eq $Version) "$Label does not match its task intent"
    return $document
}

function Get-TransactionStepClaimOwnership {
    param([string]$WorkspaceRoot,[pscustomobject]$Record,[System.Collections.IDictionary]$Step)
    $journal = $Record.Journal
    $pathKey = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $Step.relative_path
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $pathKey = $pathKey.ToLowerInvariant() }
    $relativePath = "$($script:RuntimeRelative)/locks/step_$((Get-HarnessSha256Text -Content $pathKey).Substring(7)).json"
    $expected = [ordered]@{schema_version='task-step-claim/v2';transaction_id=$journal.transaction_id;
        task_id=$journal.task_id;intent_digest=$Record.IntentDigest;
        step_id=$Step.id;relative_path=$Step.relative_path;
        action=$Step.action;before_digest=$Step.before_digest;
        after_digest=$Step.after_digest}
    if (-not (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim' -AllowMissing) -PathType Leaf)) { return [pscustomobject]@{State='missing';Path=$relativePath;Expected=$expected} }
    return [pscustomobject]@{State=$(if (Test-HarnessKernelValueEqual -Left (Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim').Document -Right $expected) { 'own' } else { 'foreign' });Path=$relativePath;Expected=$expected}
}

function Enter-TransactionStepClaim {
    param([string]$WorkspaceRoot,[pscustomobject]$Record,[System.Collections.IDictionary]$Step,[switch]$AllowExisting)
    Assert-HarnessKernelCondition ($Record.Journal.transaction_id -cmatch '^txn_[0-9a-f]{32}$' -and `
        $Record.Journal.task_id -cmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$' -and `
        $Record.IntentDigest -cmatch '^sha256:[0-9a-f]{64}$') 'transaction step claim requires valid transaction intent'
    [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/locks" -Label 'task-state locks')
    $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step
    try {
        return [pscustomobject]@{Path=$ownership.Path;Digest=(Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $ownership.Path -Value $ownership.Expected -CurrentDigest missing);Created=$true}
    } catch {}
    $existing = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step
    Assert-HarnessKernelCondition ($existing.State -ceq 'own') 'transaction step publication claim is held by another transaction'
    $digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $existing.Path
    if ($digest -cne (Get-HarnessSha256Text -Content (ConvertTo-HarnessKernelJson -Value $existing.Expected))) { throw 'transaction step claim content is invalid' }
    if (-not $AllowExisting) { throw 'transaction step claim already exists; replay is required' }
    return [pscustomobject]@{Path=$existing.Path;Digest=$digest;Created=$false}
}

function Remove-TransactionStepClaim {
    param(
        [string]$WorkspaceRoot,
        [pscustomobject]$Record,
        [System.Collections.IDictionary]$Step,
        [pscustomobject]$Claim
    )
    $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step
    Assert-HarnessKernelCondition ($ownership.State -cne 'missing') 'transaction step claim disappeared before journal completion'
    Assert-HarnessKernelCondition ($ownership.State -ceq 'own') 'transaction step publication claim is held by another transaction'
    $digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $ownership.Path
    if ($null -ne $Claim -and $digest -cne [string]$Claim.Digest) { throw 'transaction step claim digest changed' }
    [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $ownership.Path -ExpectedDigest $digest)
}

function Assert-TransactionStepPostcondition {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Step)
    $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $Step.relative_path
    if ($(if ($Step.action -ceq 'write') { $current -cne $Step.after_digest } else { $null -ne $current })) { throw "completed transaction $($Step.action) postcondition changed: $($Step.relative_path)" }
}

function Get-TransactionJournalView {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Journal,[ValidateSet('pending','archive')][string]$Location='pending')
    Assert-HarnessKernelCondition (-not $Journal.Contains('expected_version') -or $null -eq $Journal.expected_version -or $Journal.expected_version.GetType() -in $script:HarnessIntegerTypes) 'transaction journal expected_version must be a positive integer'
    Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $Journal -Schema task-transaction.schema.json -Label 'transaction journal' -FailureMessage 'transaction journal format is unknown or hybrid'
    $Legacy = -not $Journal.Contains('workspace_identity')
    $prefix = if ($Legacy) { 'legacy ' } else { '' }
    $operation = $Journal.operation
    $taskId = $Journal.task_id
    $expectedVersion = [int64]$Journal.expected_version
    $targetVersion = if ($operation -ceq 'create') { [int64]1 } else { $expectedVersion + 1 }
    $validatorTransitionEvents = @{ready='requirement.resolved';running='execution.started';
        verifying='verification.started';blocked='requirement.blocked';
        paused='execution.paused';done='task.completed';
        failed='task.failed';cancelled='task.cancelled'}
    Assert-HarnessKernelCondition (-not $Legacy -or $Location -cne 'archive' -or $Journal.status -ceq 'recovered') 'legacy transaction archive status is invalid'
    Assert-HarnessKernelCondition ($Legacy -or $Journal.workspace_identity -ceq (Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot)) 'transaction journal workspace identity is invalid'
    if ($Journal.replay_command -match "[`r`n]") { throw "$($prefix)transaction journal replay command is invalid" }
    $trustedScript = [regex]::Escape((Join-Path (Split-Path -Parent $PSScriptRoot) 'task.ps1').Replace("'","''"))
    $match = [regex]::Match($Journal.replay_command,"^pwsh -File (?:'$trustedScript'|scripts/task\.ps1) replay -TransactionId $([regex]::Escape($Journal.transaction_id)) -WorkspaceRoot '(?<workspace>(?:[^'`r`n]|'')+)'$")
    if (-not $match.Success) { throw "$($prefix)transaction journal replay command is invalid" }
    try {
        Assert-HarnessKernelCondition ((Get-TaskStateWorkspaceIdentity -WorkspaceRoot $match.Groups['workspace'].Value.Replace("''", "'")) -ceq (Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot)) invalid
    } catch { throw "$($prefix)transaction journal replay command workspace is invalid" }
    $createdAt = [datetimeoffset]::MinValue
    Assert-HarnessKernelCondition ([datetimeoffset]::TryParse([string]$Journal.created_at,[ref]$createdAt)) "$($prefix)transaction journal created_at is invalid"
    Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $Journal -Schema task-transaction-operations.schema.json -Label 'transaction operation' -FailureMessage "$($prefix)transaction operation step contract is invalid"
    $contextKey = @{approve='approval_input_path';verify='evidence_input_path'}[$operation]
    if (-not $Legacy -and $contextKey) {
        Assert-HarnessKernelCondition ((Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $Journal.operation_context[$contextKey]) -ceq $Journal.operation_context[$contextKey]) "transaction $contextKey is not normalized"
    }
    $stepsById = [ordered]@{}
    $targetPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $fixedPaths = @{'task-state'="$($script:RuntimeRelative)/tasks/$taskId/task.json"
        'event-log'="$($script:RuntimeRelative)/tasks/$taskId/events.jsonl"
        'governed-plan'="docs/tasks/$taskId/plan.md"
        evidence="docs/tasks/$taskId/evidence.json"
        'current-pointer'="$($script:RuntimeRelative)/current.json"}
    foreach ($step in @($Journal.steps)) {
        $id = $step.id
        $stepsById[$id] = $step
        $normalized = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $step.relative_path
        Assert-HarnessKernelCondition ($targetPaths.Add($normalized)) "$($prefix)transaction journal contains a duplicate target path"
        $approvalPath = $id -ceq 'approval' -and $normalized -cmatch ("^\.assistant/runtime/tasks/" + [regex]::Escape($taskId) + "/approvals/apr_[A-Za-z0-9._-]+\.json$")
        Assert-HarnessKernelCondition (($fixedPaths.ContainsKey($id) -and $normalized -ceq $fixedPaths[$id]) -or $approvalPath) "$($prefix)transaction step path or action is invalid"
        if ($step.action -ceq 'write') {
            $content = Get-TransactionStepText -Step $step -Label "$($prefix)transaction step content"
            Assert-HarnessKernelCondition ($step.after_digest -ceq (Get-HarnessSha256Text -Content $content)) "$($prefix)transaction step content digest is invalid"
            if ($id -ceq 'event-log') { $eventLog = ConvertFrom-TaskEventLog -Text $content -Label "$($prefix)transaction event-log payload" }
        }
        if (-not $Legacy -and $null -ne $step.before_content_base64) {
            Assert-HarnessKernelCondition ($step.before_digest -ceq (Get-HarnessSha256Text -Content (Get-TransactionStepText -Step $step -Label "transaction $id preimage" -Property before_content_base64))) "transaction $id preimage digest is invalid"
        }
    }
    $task = Get-TransactionPayloadDocument -Step $stepsById['task-state'] -Label "$($prefix)transaction task-state payload" -Schema task-state.schema.json -TaskId $taskId -Version $targetVersion -VersionField version
    Assert-TaskStateDocument -RepoRoot $script:SchemaRoot -Task $task
    $beforeTask = $null
    if (-not $Legacy -and $operation -cne 'create') {
        $beforeTask = Get-TransactionPayloadDocument -Step $stepsById['task-state'] -Label 'transaction task-state preimage' -Schema task-state.schema.json -TaskId $taskId -Version $expectedVersion -VersionField version -Before
        Assert-TaskStateDocument -RepoRoot $script:SchemaRoot -Task $beforeTask
    }
    if ($operation -ceq 'create') {
        Assert-HarnessKernelCondition ($null -eq $stepsById['task-state'].before_digest) "$($prefix)create transaction task target must not already exist"
        if (-not $Legacy) {
            Assert-HarnessKernelCondition ($task.identity-ceq'new'-and$task.requirement_state-ceq'clear'-and$task.status-ceq'ready'-and `
                $null-eq$task.block_reason-and-not@($task.approvals).Count-and$null-eq$task.evidence_path) 'create transaction task-state payload is not canonical'
        }
    }
    $events = @($eventLog.Events)
    $previousVersion = [int64]0
    foreach ($event in $events) {
        Assert-HarnessKernelCondition ($event.task_id -ceq $taskId -and [int64]$event.task_version -ge $previousVersion -and [int64]$event.task_version -le $targetVersion) "$($prefix)transaction event-log payload does not match its task intent"
        $previousVersion = [int64]$event.task_version
    }
    Assert-HarnessKernelCondition ($previousVersion -eq $targetVersion) "$($prefix)transaction event-log payload does not reach its target version"
    $targetEvents = @($events | Where-Object { [int64]$_.task_version -eq $targetVersion })
    $prefixCount = $eventLog.Lines.Count - $targetEvents.Count
    Assert-HarnessKernelCondition ($(if ($null -eq $stepsById['event-log'].before_digest) { $null } else { $stepsById['event-log'].before_digest }) -ceq `
        $(if ($prefixCount) { Get-HarnessSha256Text -Content ((@($eventLog.Lines[0..($prefixCount - 1)]) -join [char]10) + [char]10) } else { $null })) "$($prefix)transaction event-log payload does not preserve its exact preimage prefix"
    $approval = if ($stepsById.Contains('approval')) { Get-TransactionPayloadDocument -Step $stepsById.approval -Label "$($prefix)transaction Approval payload" -Schema approval.schema.json -TaskId $taskId -Version $targetVersion } else { $null }
    $evidence = if ($stepsById.Contains('evidence')) { Get-TransactionPayloadDocument -Step $stepsById.evidence -Label "$($prefix)transaction Evidence payload" -Schema evidence.schema.json -TaskId $taskId -Version $expectedVersion } else { $null }
    if ($stepsById.Contains('current-pointer')) {
        $pointerStep = $stepsById['current-pointer']
        $beforePointer = if (-not $Legacy -and $null -ne $pointerStep.before_digest) { Get-TransactionPayloadDocument -Step $pointerStep -Label 'transaction current-pointer preimage' `
            -Schema current-pointer.schema.json -TaskId $taskId -Version $expectedVersion -Before } else { $null }
        if ($pointerStep.action -ceq 'write') {
                $pointer = Get-TransactionPayloadDocument -Step $pointerStep -Label "$($prefix)transaction current-pointer payload" -Schema current-pointer.schema.json -TaskId $taskId -Version $targetVersion
                if (-not $Legacy -and $Journal.operation_context.pointer_action -ceq 'updated' -and $pointer.activated_at -cne $beforePointer.activated_at) { throw 'transaction current-pointer activation identity changed' }
        }
        Assert-HarnessKernelCondition ($pointerStep.action -ceq $(if ($task.status -cin @('done','cancelled')) { 'delete' } else { 'write' })) "$($prefix)transaction current-pointer mutation does not match its task intent"
    }
    $event = $targetEvents[0]
    Assert-HarnessKernelCondition ($targetEvents.Count -eq $(if ($operation -ceq 'verify' -and $evidence.conclusion -cne 'partial') { 2 } else { 1 })) "$($prefix)$operation transaction payload intent is invalid"
    $valid = switch ($operation) {
        'create' {
            if ($stepsById.Contains('governed-plan')) {
                $plan = Get-TransactionStepText -Step $stepsById['governed-plan'] -Label "$($prefix)transaction governed-plan payload"
                if ([regex]::Matches($plan,"(?m)^- task_id:\s*$([regex]::Escape($taskId))\s*$").Count -ne 1 -or `
                    [regex]::Matches($plan,"(?m)^- contract_digest:\s*$([regex]::Escape($task.contract_digest))\s*$").Count -ne 1) { throw "$($prefix)create governed-plan payload does not match its task intent" }
            }
            $task.status-ceq'ready'-and$event.type-ceq'task.created'-and($Legacy-or `
                ([bool]$task.policies.plan_required-eq$stepsById.Contains('governed-plan')-and$event.payload.profile-ceq$task.execution_profile-and$event.payload.contract_digest-ceq$task.contract_digest))
        }
        'transition' {
            $from,$to = [string]$event.payload.from,[string]$event.payload.to
            if (-not $Legacy -and $from -ceq 'blocked' -and $to -ceq 'ready' -and $task.contract_digest -ceq $beforeTask.contract_digest) { throw 'transition revised Requirement intent is invalid' }
            $mutable=@('status','requirement_state','block_reason')+$(if($from-ceq'blocked'-and$to-ceq'ready'){@('contract_path','contract_digest')}else{@()})
            ($Legacy-or$beforeTask.status-ceq$from)-and@($script:Transitions[$from])-ccontains$to-and$task.status-ceq$to-and$event.type-ceq$validatorTransitionEvents[$to]
        }
        'resume' {
            $mutable=@('status')
            ($Legacy-or$beforeTask.status-cin@('ready','running','paused','failed'))-and$task.status-ceq'running'-and$event.type-ceq'execution.started'-and `
                $event.payload.to-ceq'running'-and($Legacy-or($event.payload.from-ceq$beforeTask.status-and$event.payload.source-ceq'resume-and-execute'))
        }
        'approve' {
            $approvalId,$approvalPath = [string]$approval.approval_id,[string]$stepsById.approval.relative_path
            $approvalTask = if($Legacy){$task}else{$beforeTask}
            $mutable=@('approvals')
            $approval.contract_digest-ceq$task.contract_digest-and$approval.status-ceq'granted'-and-not(Test-HarnessApprovalExpiry $approval $createdAt)-and `
                $null-eq$stepsById.approval.before_digest-and[bool]$approvalTask.policies.approval_required-and$approvalTask.requirement_state-ceq'clear'-and `
                $approvalTask.status-cnotin@('done','cancelled')-and[IO.Path]::GetFileName($approvalPath)-ceq"$approvalId.json"-and `
                $(if($Legacy){@($task.approvals)-ccontains$approvalId}else{Test-HarnessKernelValueEqual $task.approvals @(@($beforeTask.approvals)+$approvalId)})-and `
                $event.type-ceq'approval.granted'-and$event.payload.approval_id-ceq$approvalId-and$event.payload.approval_type-ceq$approval.approval_type-and `
                $event.payload.approval_path-ceq$approvalPath-and$event.payload.digest-ceq$stepsById.approval.after_digest
        }
        'verify' {
            $status = @{pass='done';fail='running';
                blocked='paused';partial='verifying'}[$evidence.conclusion]
            if($targetEvents.Count-eq2-and-not((Test-HarnessKernelFields $targetEvents[1] @{type=$validatorTransitionEvents[$status]})-and `
                (Test-HarnessKernelFields $targetEvents[1].payload @{source='evidence';conclusion=$evidence.conclusion}))){throw "$($prefix)verify transaction lifecycle event does not match its Evidence"}
            $mutable=@('status','evidence_path')
            ($Legacy-or$beforeTask.status-ceq'verifying')-and$task.contract_digest-ceq$evidence.contract_digest-and$task.status-ceq$status-and `
                $task.evidence_path-ceq$stepsById.evidence.relative_path-and$event.type-ceq'verification.recorded'-and `
                $event.payload.evidence_path-ceq$stepsById.evidence.relative_path-and$event.payload.digest-ceq$stepsById.evidence.after_digest-and `
                $event.payload.conclusion-ceq$evidence.conclusion-and$event.payload.from-ceq'verifying'-and$event.payload.to-ceq$status
        }
    }
    if(-not$Legacy-and$operation-cne'create'){
        foreach($field in @($beforeTask.Keys|Sort-Object|Where-Object{(@('version','updated_at')+@($mutable))-cnotcontains$_-and-not(Test-HarnessKernelValueEqual $beforeTask[$_] $task[$_])}|Select-Object -First 1)){throw "$operation transaction changed an unauthorized task-state field: $field"}
    }
    Assert-HarnessKernelCondition $valid "$($prefix)$operation transaction payload intent is invalid"
    $stepIds = @($Journal.steps.id)
    $completed = @($Journal.completed_steps)
    if ($completed.Count -gt $stepIds.Count -or -not (Test-HarnessKernelValueEqual -Left $completed -Right @($stepIds | Select-Object -First $completed.Count))) { throw "$($prefix)transaction journal completed_steps must be an ordered prefix" }
    $expectedFailed = if ($completed.Count -lt $stepIds.Count) { $stepIds[$completed.Count] } else { 'cleanup' }
    Assert-HarnessKernelCondition $(if($Journal.status-ceq'prepared'){$completed.Count-eq0-and$Journal.failed_step-ceq$expectedFailed-and[string]::IsNullOrEmpty($Journal.error)} `
        elseif($Journal.status-ceq'applying'){$completed.Count-gt0-and$Journal.failed_step-ceq$expectedFailed-and[string]::IsNullOrEmpty($Journal.error)} `
        elseif($Journal.status-ceq'failed'){$Journal.failed_step-ceq$expectedFailed-and-not[string]::IsNullOrWhiteSpace($Journal.error)} `
        else{$completed.Count-eq$stepIds.Count-and$Journal.failed_step-ceq''-and[string]::IsNullOrEmpty($Journal.error)}) "$($prefix)$($Journal.status) transaction journal progress is invalid"
    return [pscustomobject]@{Legacy=[bool]$Legacy;Prefix=$prefix;
        Journal=$Journal;Operation=$operation;
        StepsById=$stepsById;Task=$task;
        BeforeTask=$beforeTask;TargetEvents=$targetEvents;
        Approval=$approval;Evidence=$evidence}
}

function Read-TaskTransactionJournal {
    param(
        [string]$WorkspaceRoot,
        [string]$Path,
        [ValidateSet('pending','archive')][string]$Location
    )
    $journal=(Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $Path -Label "transaction $Location").Document
    $view=Get-TransactionJournalView -WorkspaceRoot $WorkspaceRoot -Journal $journal -Location $Location
    $intent=Get-TransactionIntentDigest -WorkspaceRoot $WorkspaceRoot -Journal $journal -Legacy:$view.Legacy
    if(-not$view.Legacy){Assert-HarnessKernelCondition ($journal.intent_digest -ceq $intent) 'transaction journal intent digest is invalid'}
    if($journal.transaction_id-cne[System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileName($Path))){throw "transaction journal identity does not match its $Location filename"}
    return [pscustomobject]@{Format=$(if($view.Legacy){'legacy'}else{'current'});Journal=$journal;
        IntentDigest=$intent;View=$view}
}

function Assert-TransactionReplayInputs {
    param(
        [string]$WorkspaceRoot,
        [pscustomobject]$View,
        [switch]$UseAuthorizedSnapshot
    )
    $Journal,$stepsById,$prefix,$task,$operation,$Legacy = $View.Journal,$View.StepsById,$View.Prefix,$View.Task,$View.Operation,$View.Legacy
    $replayAsOf = if ($UseAuthorizedSnapshot) { [datetimeoffset]::Parse([string]$Journal.created_at,[Globalization.CultureInfo]::InvariantCulture) } else { [datetimeoffset]::UtcNow }
    $beforeTask = $View.BeforeTask
    if ($operation -cin @('create','verify') -or ($operation -ceq 'transition' -and $(if ($Legacy) { $View.TargetEvents[-1].payload.from } else { $beforeTask.status }) -ceq 'blocked' -and $task.status -ceq 'ready')) {
        $contractTask = if (-not $Legacy -and $operation -ceq 'verify') { $beforeTask } else { $task }
        $contract = Resolve-HarnessRequirementContract -RepoRoot $script:SchemaRoot -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Journal.task_id) -Path ([string]$contractTask.contract_path)
        Assert-HarnessKernelCondition ($contract.Digest -ceq $contractTask.contract_digest) "$prefix$operation transaction Requirement Contract is stale"
    }

    if ($operation -ceq 'approve') {
        if ($Legacy) {
            if (Test-HarnessApprovalExpiry -Approval $View.Approval -AsOf $replayAsOf) { throw 'Approval is expired' }
        } else {
            $resolvedApproval = Resolve-HarnessApprovalInputCore -RepoRoot $script:SchemaRoot -WorkspaceRoot $WorkspaceRoot `
                -ApprovalPath ([string]$Journal.operation_context.approval_input_path) `
                -TaskId ([string]$Journal.task_id) -TargetTaskVersion ([int64]$Journal.expected_version + 1) `
                -ContractDigest ([string]$beforeTask.contract_digest) -AsOf $replayAsOf
            $approvalStep = $stepsById['approval']
            Assert-HarnessKernelCondition ($resolvedApproval.OutputPath -ceq $approvalStep.relative_path -and $resolvedApproval.Digest -ceq $approvalStep.after_digest -and `
                $resolvedApproval.Content -ceq (Get-TransactionStepText -Step $approvalStep -Label 'transaction Approval payload')) 'approve transaction input no longer matches its journal'
        }
    }

    if ($operation -ceq 'verify') {
        Assert-HarnessKernelCondition (-not $Legacy -or $UseAuthorizedSnapshot) 'legacy claim-free verify cannot be safely replayed because its original Evidence input path is unavailable; run verify again'
        $evidenceStep = $stepsById['evidence']
        if ($Legacy) {
            $beforeTask = $task.Clone()
            $beforeTask.version = [int64]$Journal.expected_version
            $beforeTask.status = 'verifying'
            $beforeTask.evidence_path = $null
        }
        $resolvedEvidence = Resolve-HarnessEvidenceCore -RepoRoot $script:SchemaRoot -WorkspaceRoot $WorkspaceRoot `
            -TaskId ([string]$Journal.task_id) -TaskVersion ([int64]$Journal.expected_version) `
            -ContractDigest ([string]$beforeTask.contract_digest) `
            -RequiredAcceptanceCount @($contract.Document.acceptance).Count `
            -EvidencePath $(if ($Legacy) { [string]$evidenceStep.relative_path } else { [string]$Journal.operation_context.evidence_input_path }) `
            -PinnedRevision $(if ($UseAuthorizedSnapshot) { [string]$View.Evidence.revision } else { '' })
        Assert-HarnessKernelCondition ($resolvedEvidence.OutputPath -ceq $evidenceStep.relative_path -and $resolvedEvidence.Digest -ceq $evidenceStep.after_digest -and `
            $resolvedEvidence.Content -ceq (Get-TransactionStepText -Step $evidenceStep -Label "$($prefix)transaction Evidence payload") -and `
            $resolvedEvidence.NextStatus -ceq $task.status) "$($prefix)verify transaction input no longer matches its journal"
        $replayGovernance = Assert-HarnessGovernanceReady -RepoRoot $script:SchemaRoot -WorkspaceRoot $WorkspaceRoot -Task $beforeTask -Evidence $resolvedEvidence
        if ([bool]$beforeTask.policies.approval_required -and $resolvedEvidence.NextStatus -ceq 'done') {
            [void](Assert-HarnessTaskApprovalCore -RepoRoot $script:SchemaRoot -WorkspaceRoot $WorkspaceRoot -Task $beforeTask -RequiredOperation $replayGovernance.ProtectedOperation -AsOf $replayAsOf)
        }
    }

    $current = Read-CurrentPointer -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/current.json"
    if (-not $stepsById.Contains('current-pointer')) {
        Assert-HarnessKernelCondition ($null -eq $current -or $current.task_id -cne $Journal.task_id) "$($prefix)transaction omitted the current-pointer mutation for the current task"
        return
    }
    if ($Legacy) { return }
    $pointerStep = $stepsById['current-pointer']
    $currentDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/current.json"
    Assert-HarnessKernelCondition (($null -eq $currentDigest -and ($null -eq $pointerStep.before_digest -or $pointerStep.action -ceq 'delete')) -or `
        $currentDigest -ceq $pointerStep.before_digest -or ($pointerStep.action -ceq 'write' -and $currentDigest -ceq $pointerStep.after_digest)) 'transaction current-pointer no longer matches its replay boundary'
}

function Invoke-TransactionStep {
    param(
        [string]$WorkspaceRoot,
        [pscustomobject]$Record,
        [System.Collections.IDictionary]$Step,
        [switch]$AllowExistingClaim,
        [switch]$AllowLegacyUnclaimedPostimage
    )
    $claim = Enter-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step -AllowExisting:$AllowExistingClaim
    $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $Step.relative_path
    if ($(if ($Step.action -ceq 'write') { $current -ceq $Step.after_digest } else { $null -eq $current })) {
        if ($claim.Created -and -not $AllowLegacyUnclaimedPostimage) {
            Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step -Claim $claim
            throw "transaction$(if ($Step.action -ceq 'write') { '' } else { ' delete' }) postimage exists without its publication claim: $($Step.relative_path)"
        }
        return $claim
    }
    if (-not $(if ($null -eq $Step.before_digest) { $null -eq $current } else { $current -ceq $Step.before_digest })) {
        if ($claim.Created) { Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step -Claim $claim }
        throw "transaction$(if ($Step.action -ceq 'write') { '' } else { ' delete' }) preimage changed: $($Step.relative_path)"
    }
    if ($Step.action -ceq 'write') {
        if ((Write-HarnessKernelBytesCas -WorkspaceRoot $WorkspaceRoot -Path $Step.relative_path `
            -Bytes ([Convert]::FromBase64String($Step.content_base64)) -SourceDigest $Step.after_digest `
            -CurrentDigest $(if ($null -eq $Step.before_digest) { 'missing' } else { $Step.before_digest })) -cne $Step.after_digest) { throw "transaction postimage mismatch: $($Step.relative_path)" }
    } else {
        [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $Step.relative_path -ExpectedDigest $Step.before_digest)
    }
    Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $Step
    Assert-HarnessKernelCondition ($env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_PUBLISH -cne '1') 'injected task-state fault after publication'
    return $claim
}

function Write-TaskTransactionProgress {
    param([string]$WorkspaceRoot,[string]$Path,[Collections.IDictionary]$Journal,[string]$ExpectedDigest,[string]$Status,[object[]]$Completed,[string]$FailedStep,[string]$ErrorText='')
    $Journal.status,$Journal.completed_steps,$Journal.failed_step,$Journal.error = $Status,@($Completed),$FailedStep,$ErrorText
    return Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $Path -Value $Journal -CurrentDigest $ExpectedDigest
}

function Invoke-TaskTransactionCompletion {
    param([string]$WorkspaceRoot,[pscustomobject]$Record,[string]$PendingPath,[string]$ArchivePath,[string]$PendingDigest,[switch]$Initial)
    $journal = $Record.Journal
    $steps = @($journal.steps)
    $completed = [Collections.Generic.List[string]]::new([string[]]@($journal.completed_steps))
    $legacy = $Record.Format -ceq 'legacy'
    $faultAfter,$faultBeforeRelease = [int]$(if($Initial){$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP-as[int]}else{0}),[int]$(if($Initial){$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_BEFORE_CLAIM_RELEASE-as[int]}else{0})
    try {
        $authorizedSnapshot = $false
        if (-not $Initial) {
            $authorizedSnapshot = $legacy -and $completed.Count -gt 0
            for ($index = 0; $index -lt $steps.Count; $index++) {
                $step = $steps[$index]
                $owner = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step
                Assert-HarnessKernelCondition ($owner.State -cne 'foreign') "$($Record.View.Prefix)transaction target is claimed by another transaction: $($step.relative_path)"
                Assert-HarnessKernelCondition ($owner.State -cne 'own' -or $index -le $completed.Count) "$($Record.View.Prefix)transaction has an out-of-order publication claim: $($step.relative_path)"
                if (-not $legacy) {
                    if ($index -eq 0 -and $owner.State -ceq 'own') { $authorizedSnapshot = $true }
                    if ($index -lt $completed.Count) { Assert-HarnessKernelCondition ($owner.State -ceq 'own') "completed transaction step lacks its own publication claim: $($step.relative_path)" }
                    continue
                }
                $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $step.relative_path
                $matchesBefore = if ($null -eq $step.before_digest) { $null -eq $current } else { $current -ceq $step.before_digest }
                $matchesAfter = if ($step.action -ceq 'write') { $current -ceq $step.after_digest } else { $null -eq $current }
                if ($index -eq 0 -and ($owner.State -ceq 'own' -or ($matchesAfter -and -not $matchesBefore))) { $authorizedSnapshot = $true }
                Assert-HarnessKernelCondition ($index -ge $completed.Count -or $matchesAfter) "legacy completed transaction step postcondition changed: $($step.relative_path)"
                Assert-HarnessKernelCondition ($index -ne $completed.Count -or $matchesBefore -or $matchesAfter) "legacy first unfinished transaction step is outside its replay boundary: $($step.relative_path)"
                Assert-HarnessKernelCondition ($index -le $completed.Count -or $matchesBefore) "legacy transaction suffix is published out of order: $($step.relative_path)"
            }
        }
        $preclaimDelay = if($Initial){[int]($env:DEV_HARNESS_TEST_TASK_STATE_PRECLAIM_DELAY_MS-as[int])}else{0}
        if ($preclaimDelay -gt 0) { Start-Sleep -Milliseconds ([Math]::Min($preclaimDelay,30000)) }
        Assert-TransactionReplayInputs -WorkspaceRoot $WorkspaceRoot -View $Record.View -UseAuthorizedSnapshot:$authorizedSnapshot
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        Assert-HarnessKernelCondition (-not$Initial-or$env:DEV_HARNESS_TEST_TASK_STATE_FAIL_BEFORE_FIRST_CLAIM-cne'1') 'injected task-state fault before first publication claim'
        for ($index = 0; $index -lt $steps.Count; $index++) {
            $step = $steps[$index]
            if ($index -lt $completed.Count) {
                if ($legacy) { [void](Enter-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step -AllowExisting) }
                Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
                continue
            }
            [void](Invoke-TransactionStep -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step -AllowExistingClaim:(-not $Initial) -AllowLegacyUnclaimedPostimage:$legacy)
            $completed.Add($step.id)
            $PendingDigest = Write-TaskTransactionProgress -WorkspaceRoot $WorkspaceRoot -Path $PendingPath -Journal $journal -ExpectedDigest $PendingDigest `
                -Status applying -Completed @($completed) -FailedStep $(if ($index + 1 -lt $steps.Count) { $steps[$index + 1].id } else { 'cleanup' })
            if ($faultBeforeRelease -gt 0 -and $completed.Count -eq $faultBeforeRelease) { throw "injected task-state fault before claim release after step $faultBeforeRelease" }
            if ($faultAfter -gt 0 -and $completed.Count -eq $faultAfter) { throw "injected task-state fault after step $faultAfter" }
        }
        $delay = if($Initial){[int]($env:DEV_HARNESS_TEST_TASK_STATE_DELAY_BEFORE_COMMIT_MS-as[int])}else{0}
        if ($delay -gt 0) { Start-Sleep -Milliseconds ([Math]::Min($delay,5000)) }
        foreach ($step in $steps) {
            Assert-HarnessKernelCondition ((Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step).State -ceq 'own') "$($Record.View.Prefix)transaction cannot commit without its own publication claim: $($step.relative_path)"
            Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
        }
        $PendingDigest = Write-TaskTransactionProgress -WorkspaceRoot $WorkspaceRoot -Path $PendingPath -Journal $journal -ExpectedDigest $PendingDigest -Status $(if ($Initial) { 'committed' } else { 'recovered' }) -Completed @($completed) -FailedStep ''
        [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes/archive" -Label 'transaction archive')
        [void](Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $ArchivePath -Value $journal -CurrentDigest 'missing')
        foreach ($step in $steps) {
            Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step -Claim $null
        }
        if (-not (Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $PendingPath -ExpectedDigest $PendingDigest)) { throw 'transaction journal disappeared before CAS cleanup' }
        return $completed.ToArray()
    } catch {
        $failure = $_.Exception.Message
        if ($Initial -and (Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $PendingPath) -ceq $PendingDigest) {
            [void](Write-TaskTransactionProgress -WorkspaceRoot $WorkspaceRoot -Path $PendingPath -Journal $journal -ExpectedDigest $PendingDigest -Status failed `
                -Completed @($completed) -FailedStep $(if ($completed.Count -lt $steps.Count) { $steps[$completed.Count].id } else { 'cleanup' }) -ErrorText $failure)
        }
        if ($Initial) { throw "$failure TransactionId=$($journal.transaction_id). Replay: $($journal.replay_command)" }
        throw
    }
}

function Invoke-HarnessTaskOperation {
    param([ValidateSet('create','transition','resume','approve','verify')][string]$Operation,[string]$RepoRoot,[string]$WorkspaceRoot,[string]$TaskId,[AllowNull()][Nullable[int]]$ExpectedVersion,
        [string]$ContractPath='',[string]$Profile='governed',[string[]]$Capabilities=@(),[switch]$ActivateCurrent,[string]$To='',[string]$Reason='',[switch]$EvidenceSatisfied,[string]$EvidencePath='',[string]$ApprovalPath='',[string]$ActorHost='codex',[string]$ActorModel='inherit')
    Assert-V2WriteProtocol
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    Assert-HarnessTaskId -TaskId $TaskId
    $paths = @{Task="$($script:RuntimeRelative)/tasks/$TaskId/task.json";Events="$($script:RuntimeRelative)/tasks/$TaskId/events.jsonl";Current="$($script:RuntimeRelative)/current.json"}
    if ($Operation -ceq 'create') {
        Import-Module (Join-Path $PSScriptRoot 'Harness.Protocol.psm1') -Force
        $admission = Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
        if ($admission.selected_protocol -cne 'v2') { throw "new-work-not-admitted: $($admission.reason)" }
        $contract = Resolve-HarnessRequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Path $ContractPath
        $policies = Get-TaskPolicyFlags -RepoRoot $RepoRoot -Profile $Profile -Capabilities $Capabilities
    }
    return Invoke-TaskStateLocked -WorkspaceRoot $WorkspaceRoot -Action {
        $current = Read-CurrentPointer -WorkspaceRoot $WorkspaceRoot -Path $paths.Current
        $isCurrent = $null -ne $current -and $current.task_id -ceq $TaskId
        $transactionId,$timestamp = ('txn_' + [guid]::NewGuid().ToString('N')),[datetimeoffset]::UtcNow.ToString('o')
        $beforeSteps,$afterSteps,$pointerAction,$operationContext = @(),@(),'unchanged',[ordered]@{}
        $eventPrefix,$extraEventText,$eventType = '','',''
        $resultFields = [ordered]@{operation=$(if ($Operation -ceq 'resume') { 'resume-and-execute' } else { $Operation });transaction_id=$transactionId}
        if ($Operation -ceq 'create') {
            $eventType = 'task.created'
            if (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -Label 'task state' -AllowMissing)) { throw "task already exists: $TaskId" }
            if ($ActivateCurrent -and $null -ne $current) { throw "current task is already active: $($current.task_id)" }
            $next = [ordered]@{schema_version='task-state/v2';task_id=$TaskId;
                version=1;status='ready';
                identity='new';intent='write';
                requirement_state='clear';execution_profile=$Profile;
                persistence='durable';contract_path=$contract.Path;
                contract_digest=$contract.Digest;block_reason=$null;
                policies=$policies;approvals=@();
                evidence_path=$null;created_at=$timestamp;
                updated_at=$timestamp}
            $eventPayload = [ordered]@{profile=$Profile;contract_digest=$contract.Digest}
            if ([bool]$policies.plan_required) {
                $plan = New-HarnessPlanArtifact -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractDigest $contract.Digest
                $afterSteps = @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'governed-plan' -RelativePath $plan.Path -Action write -Content $plan.Content)
            }
            if ($ActivateCurrent) { $pointerAction = 'activated' }
            $resultFields += [ordered]@{plan_action=$(if([bool]$policies.plan_required){'created'}else{'not-required'})}
        } else {
            $task = Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId
            if ([int]$task.version -ne $ExpectedVersion) { throw "ExpectedVersion mismatch: expected=$ExpectedVersion actual=$($task.version)" }
            if ($isCurrent -and [int]$current.task_version -ne $ExpectedVersion) { throw "current pointer version is stale; replay or repair before $(if ($Operation -ceq 'resume') { 'resume-and-execute' } else { $Operation })" }
            $next = $task.Clone()
            $next.version,$next.updated_at = ($ExpectedVersion + 1),$timestamp
            $eventPrefix = (Read-EventLog -WorkspaceRoot $WorkspaceRoot -Path $paths.Events).Text
            switch ($Operation) {
                'transition' {
                    $from = $task.status
                    if (@($script:Transitions[$from]) -cnotcontains $To) { throw "illegal task transition: $from -> $To" }
                    if ($EvidenceSatisfied) { throw '-EvidenceSatisfied was removed; use verify -Evidence' }
                    if ($To -ceq 'done') { throw 'done requires verify -Evidence' }
                    $next.status = $To
                    if ($To -ceq 'blocked') {
                        $next.requirement_state,$next.block_reason = 'blocked',$Reason
                    } elseif ($from -ceq 'blocked' -and $To -ceq 'ready') {
                        $contract = Resolve-HarnessRequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Path $ContractPath
                        if ($contract.Digest -ceq $task.contract_digest) { throw 'blocked -> ready requires a revised Contract digest' }
                        $next.requirement_state,$next.block_reason = 'clear',$null
                        $next.contract_path,$next.contract_digest = $contract.Path,$contract.Digest
                    }
                    $eventType,$eventPayload = $script:WriterTransitionEvents[$To],[ordered]@{from=$from;to=$To;reason=$Reason}
                }
                'resume' {
                    $eventType = 'execution.started'
                    if ($null -ne $current -and -not $isCurrent) { throw "another current task is active: $($current.task_id)" }
                    $next.status = 'running'
                    $eventPayload = [ordered]@{from=$task.status;to='running';source='resume-and-execute'}
                    $resultFields += [ordered]@{write_authorized=$true}
                }
                'approve' {
                    $eventType = 'approval.granted'
                    $approval = Resolve-HarnessApprovalInput -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -ApprovalPath $ApprovalPath -TaskId $TaskId -TargetTaskVersion ($ExpectedVersion + 1) -ContractDigest $task.contract_digest
                    $next.approvals = @(@($task.approvals) + $approval.Document.approval_id)
                    $eventPayload = [ordered]@{approval_id=$approval.Document.approval_id;approval_type=$approval.Document.approval_type;
                        approval_path=$approval.OutputPath;digest=$approval.Digest}
                    $beforeSteps = @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id approval -RelativePath $approval.OutputPath -Action write -Content $approval.Content)
                    $operationContext.approval_input_path = $approval.InputPath
                    $resultFields += [ordered]@{approval_id=$approval.Document.approval_id;approval_path=$approval.OutputPath;approval_digest=$approval.Digest}
                }
                'verify' {
                    $eventType = 'verification.recorded'
                    $contract = Resolve-HarnessRequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Path $task.contract_path
                    $evidence = Resolve-HarnessEvidence -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -TaskVersion $ExpectedVersion -ContractDigest $task.contract_digest -RequiredAcceptanceCount @($contract.Document.acceptance).Count -EvidencePath $EvidencePath
                    $governance = Assert-HarnessGovernanceReady -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $task -Evidence $evidence
                    $approval = $null
                    if ([bool]$task.policies.approval_required -and $evidence.NextStatus -ceq 'done') {
                        $approval = Assert-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $task -RequiredOperation $governance.ProtectedOperation
                    }
                    $next.status,$next.evidence_path = $evidence.NextStatus,$evidence.OutputPath
                    $planPath,$auditPath = $(if ($null -ne $governance.Plan) { $governance.Plan.Path } else { $null }),$(if ($null -ne $governance.Audit) { $governance.Audit.Path } else { $null })
                    $eventPayload = [ordered]@{evidence_path=$evidence.OutputPath;digest=$evidence.Digest;
                        conclusion=$evidence.Conclusion;from='verifying';
                        to=$evidence.NextStatus;plan_path=$planPath;
                        audit_path=$auditPath;approval_id=$(if ($null -ne $approval) { $approval.Document.approval_id } else { $null })}
                    if ($evidence.NextStatus -cne 'verifying') {
                        $extraEventText = (ConvertTo-HarnessKernelJson -Value (New-TaskEvent -EventId ('evt2_' + $transactionId.Substring(4)) -TaskId $TaskId -Version $next.version `
                            -Type $script:WriterTransitionEvents[$evidence.NextStatus] -Host $ActorHost -Model $ActorModel -Timestamp $timestamp `
                            -Payload ([ordered]@{source='evidence';conclusion=$evidence.Conclusion})) -Compress) + "`n"
                    }
                    $beforeSteps = @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id evidence -RelativePath $evidence.OutputPath -Action write -Content $evidence.Content)
                    $operationContext.evidence_input_path = $evidence.InputPath
                    $resultFields += [ordered]@{conclusion=$evidence.Conclusion;evidence_path=$evidence.OutputPath
                        evidence_digest=$evidence.Digest;plan_path=$planPath
                        audit_path=$auditPath}
                }
            }
            if ($Operation -ceq 'resume') { $pointerAction = if ($null -eq $current) { 'activated' } else { 'updated' } }
            elseif ($isCurrent) { $pointerAction = if ($next.status -cin @('done','cancelled')) { 'cleared' } else { 'updated' } }
        }
        $event = New-TaskEvent -EventId ('evt_' + $transactionId.Substring(4)) -TaskId $TaskId -Version $next.version -Type $eventType -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload $eventPayload
        if ($pointerAction -cne 'unchanged') {
            $afterSteps += @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id current-pointer -RelativePath $paths.Current `
                -Action $(if ($pointerAction -ceq 'cleared') { 'delete' } else { 'write' }) -Content $(if ($pointerAction -ceq 'cleared') { $null } else { ConvertTo-HarnessKernelJson -Value ([ordered]@{
                    schema_version='current-pointer/v1';task_id=$TaskId;task_version=[int]$next.version
                    activated_at=$(if ($pointerAction -ceq 'activated') { $next.updated_at } else { $current.activated_at })}) }))
        }
        $steps = @($beforeSteps + @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id task-state -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessKernelJson -Value $next)) + `
            @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id event-log -RelativePath $paths.Events -Action write -Content ($eventPrefix + (ConvertTo-HarnessKernelJson -Value $event -Compress) + "`n" + $extraEventText)) + $afterSteps)
        $operationContext.pointer_action = $pointerAction
        $journal = [ordered]@{transaction_id=$transactionId;operation=$Operation;
            task_id=$TaskId;expected_version=$ExpectedVersion
            workspace_identity=(Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot);operation_context=$operationContext;intent_digest=''
            status='prepared';completed_steps=@();
                failed_step=$steps[0].id;error=''
            replay_command="pwsh -File '$((Join-Path (Split-Path -Parent $PSScriptRoot) 'task.ps1') -replace "'","''")' replay -TransactionId $transactionId -WorkspaceRoot '$($WorkspaceRoot -replace "'","''")'";created_at=[datetimeoffset]::UtcNow.ToString('o');steps=@($steps)}
        $journal.intent_digest = Get-TransactionIntentDigest -Journal $journal
        [void](Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -ReservedPaths @($journal.steps.relative_path) -TransactionId $transactionId)
        $record = [pscustomobject]@{Format='current';Journal=$journal;IntentDigest=$journal.intent_digest
            View=$null}
        foreach ($step in @($journal.steps)) {
            if ((Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $record -Step $step).State -cne 'missing') { throw "transaction target has a pending publication claim; replay or repair before mutation: $($step.relative_path)" }
        }
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes')
        $pending,$archive = "$($script:RuntimeRelative)/failed-writes/$transactionId.json","$($script:RuntimeRelative)/failed-writes/archive/$transactionId.json"
        Assert-HarnessKernelCondition (-not (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $archive -Label 'transaction archive' -AllowMissing))) 'transaction archive already exists'
        $record.View = Get-TransactionJournalView -WorkspaceRoot $WorkspaceRoot -Journal $journal
        [void](Invoke-TaskTransactionCompletion -WorkspaceRoot $WorkspaceRoot -Record $record -PendingPath $pending -ArchivePath $archive -PendingDigest (Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $pending -Value $journal -CurrentDigest 'missing') -Initial)
        $resultFields += [ordered]@{pointer_action=$pointerAction;task=$next}
        return $resultFields
    }
}

function New-HarnessTaskState {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][string]$ContractPath,
        [ValidateSet('governed','critical')][string]$Profile='governed',[string[]]$Capabilities=@(),[switch]$ActivateCurrent,[string]$ActorHost='codex',[string]$ActorModel='inherit'
    )
    return Invoke-HarnessTaskOperation -Operation create @PSBoundParameters
}

function Get-HarnessTaskStatus {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId)
    $script:TaskStateWorkspaceIdentityCache.Clear()
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    Assert-HarnessTaskId -TaskId $TaskId
    $paths = @{Task="$($script:RuntimeRelative)/tasks/$TaskId/task.json";Events="$($script:RuntimeRelative)/tasks/$TaskId/events.jsonl";Current="$($script:RuntimeRelative)/current.json"}
    return Invoke-TaskStateLocked -WorkspaceRoot $WorkspaceRoot -Action {
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        $task = Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId
        $events,$current = (Read-EventLog -WorkspaceRoot $WorkspaceRoot -Path $paths.Events),(Read-CurrentPointer -WorkspaceRoot $WorkspaceRoot -Path $paths.Current)
        if ($null -ne $current -and $current.task_id -ceq $TaskId -and [int]$current.task_version -ne [int]$task.version) { throw 'current pointer task_version is stale' }
        return [ordered]@{operation='status';task=$task;
            event_count=$events.Count;is_current=$null-ne$current-and$current.task_id-ceq$TaskId
            current=$current;pending_transactions=@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId);side_effects=New-HarnessZeroSideEffects}
    }
}

function Set-HarnessTaskTransition {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,
        [Parameter(Mandatory)][ValidateSet('blocked','ready','running','verifying','paused','done','failed','cancelled')][string]$To,[string]$Reason='',[string]$ContractPath='',[switch]$EvidenceSatisfied,[string]$ActorHost='codex',[string]$ActorModel='inherit'
    )
    return Invoke-HarnessTaskOperation -Operation transition @PSBoundParameters
}

function Resume-HarnessTaskExecution {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$ExpectedVersion,
        [string]$ActorHost = 'codex',
        [string]$ActorModel = 'inherit'
    )
    return Invoke-HarnessTaskOperation -Operation resume @PSBoundParameters
}

function Set-HarnessTaskApproval {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ApprovalPath,[string]$ActorHost='codex',[string]$ActorModel='inherit'
    )
    return Invoke-HarnessTaskOperation -Operation approve @PSBoundParameters
}

function Set-HarnessTaskEvidence {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,
        [Parameter(Mandatory)][string]$EvidencePath,[string]$ActorHost='codex',[string]$ActorModel='inherit'
    )
    return Invoke-HarnessTaskOperation -Operation verify @PSBoundParameters
}

function Repair-HarnessTaskTransaction {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TransactionId)

    Assert-V2WriteProtocol
    if ($TransactionId -cnotmatch '^txn_[0-9a-f]{32}$') { throw 'invalid TransactionId' }
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $pending,$archive = "$($script:RuntimeRelative)/failed-writes/$TransactionId.json","$($script:RuntimeRelative)/failed-writes/archive/$TransactionId.json"
    $pendingPath,$archivePath = (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $pending -Label 'transaction journal' -AllowMissing),(Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $archive -Label 'transaction archive' -AllowMissing)

    return Invoke-TaskStateLocked -WorkspaceRoot $WorkspaceRoot -Action {
        $pendingExists = Test-Path -LiteralPath $pendingPath -PathType Leaf
        if (-not $pendingExists) { Assert-HarnessKernelCondition (Test-Path -LiteralPath $archivePath -PathType Leaf) "transaction journal not found: $TransactionId" }
        $record = Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $(if ($pendingExists) { $pending } else { $archive }) -Location $(if ($pendingExists) { 'pending' } else { 'archive' })
        $legacy,$prefix = [bool]$record.View.Legacy,$record.View.Prefix
        if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
            $archived = if ($pendingExists) { Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $archive -Location archive } else { $record }
            $owned = @($archived.Journal.steps | Where-Object { (Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $record -Step $_).State -ceq 'own' })
            if (-not $pendingExists) {
                Assert-HarnessKernelCondition (-not $owned.Count) "$($prefix)recovered transaction retains a publication claim owned by itself"
                return [ordered]@{operation='replay';transaction_id=$TransactionId;result='already-recovered'}
            }
            $journal,$pendingDigest = $record.Journal,(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $pending)
            if (-not ($archived.Format-ceq$record.Format-and$archived.Journal.task_id-ceq$journal.task_id-and$archived.IntentDigest-ceq$record.IntentDigest-and `
                ($legacy-or($archived.Journal.workspace_identity-ceq$journal.workspace_identity-and$archived.Journal.status-cin@('committed','recovered'))))) { throw "$($prefix)transaction archive does not match its pending journal" }
            foreach ($step in $owned) {
                Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
            }
            Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
            foreach ($step in $owned) {
                Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $record -Step $step -Claim $null
            }
            if (-not (Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $pending -ExpectedDigest $pendingDigest)) { throw 'transaction journal disappeared before CAS cleanup' }
            return [ordered]@{operation='replay';transaction_id=$TransactionId
                result='recovered';completed_steps=@($archived.Journal.completed_steps)}
        }

        return [ordered]@{operation='replay';transaction_id=$TransactionId
            result='recovered';completed_steps=@(Invoke-TaskTransactionCompletion -WorkspaceRoot $WorkspaceRoot -Record $record -PendingPath $pending -ArchivePath $archive -PendingDigest (Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $pending))}
    }
}

Export-ModuleMember -Function New-HarnessTaskState,Get-HarnessTaskStatus,Set-HarnessTaskTransition,Resume-HarnessTaskExecution,Set-HarnessTaskApproval,Set-HarnessTaskEvidence,Repair-HarnessTaskTransaction
