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
$script:TransitionEvents = @{ready='requirement.resolved';running='execution.started';verifying='verification.started';blocked='requirement.blocked';paused='execution.paused';done='task.completed';failed='task.failed';cancelled='task.cancelled'}

function Get-TaskStatePaths {
    param([string]$TaskId)
    $taskRoot = "$($script:RuntimeRelative)/tasks/$TaskId"
    return [pscustomobject]@{TaskRoot=$taskRoot;Task="$taskRoot/task.json";Events="$taskRoot/events.jsonl";Current="$($script:RuntimeRelative)/current.json"}
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
    Assert-HarnessKernelCondition ([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_IDENTITY_RECHECK',[System.EnvironmentVariableTarget]::Process) -cne '1') 'injected task-state identity recheck failure'
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
    if ([System.Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[System.EnvironmentVariableTarget]::Process) -cne 'v2') { throw 'task-state writes require explicit HARNESS_PROTOCOL=v2' }
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
    Assert-HarnessKernelCondition ([string]$Task.persistence -ceq 'durable' -and [string]$Task.execution_profile -cin @('governed','critical') -and [string]$Task.intent -ceq 'write' -and -not @(@('contract_path','contract_digest','block_reason','approvals','evidence_path') | Where-Object { -not $Task.Contains($_) }).Count) 'persisted task state has an invalid durable execution profile or invariant set'
    Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace([string]$Task.contract_path) -and [string]$Task.contract_digest -cmatch '^sha256:[0-9a-f]{64}$') 'persisted task state requires a bound Requirement Contract'
    $expectedPolicies = Get-TaskPolicyFlags -RepoRoot $RepoRoot -Profile ([string]$Task.execution_profile) `
        -Capabilities @($Task.policies.Keys | Where-Object { [bool]$Task.policies[$_] })
    Assert-HarnessKernelCondition (-not @($expectedPolicies.Keys | Where-Object {
        [bool]$(if ($_ -ceq 'dry_run_required' -and -not $Task.policies.Contains($_)) { [string]$Task.execution_profile -ceq 'critical' } else { $Task.policies[$_] }) -ne [bool]$expectedPolicies[$_]
    }).Count) 'persisted task state policies do not match its execution profile'
    $blocked = [string]$Task.status -ceq 'blocked'
    Assert-HarnessKernelCondition (($blocked -and [string]$Task.requirement_state -ceq 'blocked' -and -not [string]::IsNullOrWhiteSpace([string]$Task.block_reason)) -or (-not $blocked -and [string]$Task.requirement_state -ceq 'clear' -and $null -eq $Task.block_reason)) 'persisted task Requirement state is inconsistent'
}

function Read-TaskStateDocument {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$Path,[string]$ExpectedTaskId)
    $task = (Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'task state').Document
    Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $task
    if ([string]$task.task_id -cne $ExpectedTaskId) { throw 'persisted task state task_id does not match its canonical path' }
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
    return [pscustomobject]@{Text=$Text;Count=$lines.Count;Lines=$lines;Events=@($lines | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { throw "$Label contains a blank line" }
        try { $event = $_ | ConvertFrom-HarnessJson -ErrorAction Stop } catch { throw "$Label contains invalid JSON: $($_.Exception.Message)" }
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
    return [ordered]@{ schema_version='event/v1';event_id=$EventId;task_id=$TaskId;task_version=$Version;type=$Type;actor=[ordered]@{host=$Host;model=$Model};occurred_at=$Timestamp;payload=$Payload }
}

function Get-PendingTransactions {
    param([string]$WorkspaceRoot,[string]$TaskId)
    $root = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes' -AllowMissing
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Filter 'txn_*.json' -File | ForEach-Object {
        $record = Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path (Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $_.FullName) -Location pending
        if ([string]$record.Journal.task_id -ceq $TaskId) { [string]$record.Journal.transaction_id }
    })
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

function Get-TaskReplayCommand {
    param([string]$WorkspaceRoot,[string]$TransactionId)
    return "pwsh -File '$((Join-Path (Split-Path -Parent $PSScriptRoot) 'task.ps1') -replace "'","''")' replay -TransactionId $TransactionId -WorkspaceRoot '$((Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot) -replace "'","''")'"
}

function Get-TaskReplayCommandWorkspace {
    param([string]$WorkspaceRoot,[string]$TransactionId,[string]$ReplayCommand,[string]$Label)
    if ($ReplayCommand -match "[`r`n]") { throw "$Label replay command is invalid" }
    $quoted = "(?:[^'`r`n]|'')+"
    $match,$workspacePhase = [regex]::Match($ReplayCommand,"^pwsh -File (?:'(?<script>$quoted)'|(?<legacy>scripts/task\.ps1)) replay -TransactionId $([regex]::Escape($TransactionId)) -WorkspaceRoot '(?<workspace>$quoted)'$"),$false
    if (-not $match.Success) { throw "$Label replay command is invalid" }
    try {
        if ($match.Groups['script'].Success) {
            $scriptPath = $match.Groups['script'].Value.Replace("''", "'")
            Assert-HarnessKernelCondition ([IO.Path]::IsPathFullyQualified($scriptPath) -and (Resolve-Path -LiteralPath $scriptPath).Path -ieq (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'task.ps1')).Path) invalid
        }
        $recordedWorkspace = $match.Groups['workspace'].Value.Replace("''", "'")
        $workspacePhase = $true
        Assert-HarnessKernelCondition ((Get-TaskStateWorkspaceIdentity -WorkspaceRoot $recordedWorkspace) -ceq (Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot)) invalid
    } catch {
        throw "$Label replay command$(if($workspacePhase){' workspace'}else{''}) is invalid"
    }
    return $recordedWorkspace
}

function Get-TransactionIntentDigest {
    param([System.Collections.IDictionary]$Journal,[string]$WorkspaceRoot='',[switch]$Legacy)
    $stepKeys = @('id','relative_path','action','before_digest') + $(if ($Legacy) { @() } else { @('before_content_base64') }) + @('after_digest','content_base64')
    $keys = @('transaction_id','operation','task_id','expected_version') + $(if ($Legacy) { @() } else { @('workspace_identity','operation_context') }) + @('replay_command','created_at')
    $intent = Select-HarnessKernelKeys -Value $Journal -Keys $keys
    if ($Legacy) {
        $intent.Insert(0,'workspace_identity',(Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot))
        $intent.Insert(0,'format','task-transaction/legacy-v1')
    }
    $intent.steps = @($Journal.steps | ForEach-Object { Select-HarnessKernelKeys -Value $_ -Keys $stepKeys })
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
    try { $document = $content | ConvertFrom-HarnessJson -ErrorAction Stop }
    catch { throw "$Label is not valid JSON" }
    if ($document -isnot [System.Collections.IDictionary]) { throw "$Label must be a JSON object" }
    Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $document -Schema $Schema -Label $Label
    Assert-HarnessKernelCondition ([string]$document.task_id -ceq $TaskId -and [int64]$document[$VersionField] -eq $Version) "$Label does not match its task intent"
    return $document
}

function Get-TransactionStepClaimPath {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Step)
    $pathKey = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path) -Label 'transaction step claim target' -AllowMissing)
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $pathKey = $pathKey.ToLowerInvariant() }
    return "$($script:RuntimeRelative)/locks/step_$((Get-HarnessSha256Text -Content $pathKey).Substring(7)).json"
}

function Get-TransactionStepClaimOwnership {
    param([string]$WorkspaceRoot,[pscustomobject]$Record,[System.Collections.IDictionary]$Step)
    $journal = $Record.Journal
    $relativePath = Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $Step
    $expected = [ordered]@{schema_version='task-step-claim/v2';transaction_id=[string]$journal.transaction_id;task_id=[string]$journal.task_id;intent_digest=[string]$Record.IntentDigest;step_id=[string]$Step.id;relative_path=[string]$Step.relative_path;action=[string]$Step.action;before_digest=$Step.before_digest;after_digest=$Step.after_digest}
    if (-not (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim' -AllowMissing) -PathType Leaf)) { return [pscustomobject]@{State='missing';Path=$relativePath;Expected=$expected} }
    return [pscustomobject]@{State=$(if (Test-HarnessKernelValueEqual -Left (Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim').Document -Right $expected) { 'own' } else { 'foreign' });Path=$relativePath;Expected=$expected}
}

function Enter-TransactionStepClaim {
    param([string]$WorkspaceRoot,[pscustomobject]$Record,[System.Collections.IDictionary]$Step,[switch]$AllowExisting)
    Assert-HarnessKernelCondition ([string]$Record.Journal.transaction_id -cmatch '^txn_[0-9a-f]{32}$' -and [string]$Record.Journal.task_id -cmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$' -and [string]$Record.IntentDigest -cmatch '^sha256:[0-9a-f]{64}$') 'transaction step claim requires valid transaction intent'
    [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/locks" -Label 'task-state locks')
    $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step
    try {
        $digest = Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $ownership.Path -Value $ownership.Expected -CurrentDigest missing
        return [pscustomobject]@{Path=$ownership.Path;Digest=$digest;Created=$true}
    } catch {}
    $existing = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step
    Assert-HarnessKernelCondition ([string]$existing.State -ceq 'own') 'transaction step publication claim is held by another transaction'
    $digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $existing.Path
    if ($digest -cne (Get-HarnessSha256Text -Content (ConvertTo-HarnessKernelJson -Value $existing.Expected))) { throw 'transaction step claim content is invalid' }
    if (-not $AllowExisting) { throw 'transaction step claim already exists; replay is required' }
    return [pscustomobject]@{Path=$existing.Path;Digest=$digest;Created=$false}
}

function Remove-TransactionStepClaim {
    param([string]$WorkspaceRoot,[pscustomobject]$Record,[System.Collections.IDictionary]$Step,[pscustomobject]$Claim)
    $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step
    Assert-HarnessKernelCondition ([string]$ownership.State -cne 'missing') 'transaction step claim disappeared before journal completion'
    Assert-HarnessKernelCondition ([string]$ownership.State -ceq 'own') 'transaction step publication claim is held by another transaction'
    $digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $ownership.Path
    if ($null -ne $Claim -and $digest -cne [string]$Claim.Digest) { throw 'transaction step claim digest changed' }
    [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $ownership.Path -ExpectedDigest $digest)
}

function Assert-TransactionStepPostcondition {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Step)
    $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path)
    $write = [string]$Step.action -ceq 'write'
    if (($write -and $current -cne [string]$Step.after_digest) -or (-not $write -and $null -ne $current)) { throw "completed transaction $(if($write){'write'}else{'delete'}) postcondition changed: $($Step.relative_path)" }
}

function Get-TransactionJournalView {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Journal,[ValidateSet('pending','archive')][string]$Location='pending')
    Assert-HarnessKernelCondition (-not $Journal.Contains('expected_version') -or $null -eq $Journal.expected_version -or (Test-HarnessKernelInteger -Value $Journal.expected_version)) 'transaction journal expected_version must be a positive integer'
    Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $Journal -Schema task-transaction.schema.json -Label 'transaction journal' -FailureMessage 'transaction journal format is unknown or hybrid'
    $Legacy,$prefix = (-not $Journal.Contains('workspace_identity')),$(if ($Journal.Contains('workspace_identity')) { '' } else { 'legacy ' })
    Assert-HarnessKernelCondition (-not $Legacy -or $Location -cne 'archive' -or [string]$Journal.status -ceq 'recovered') 'legacy transaction archive status is invalid'
    Assert-HarnessKernelCondition ($Legacy -or [string]$Journal.workspace_identity -ceq (Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot)) 'transaction journal workspace identity is invalid'
    [void](Get-TaskReplayCommandWorkspace -WorkspaceRoot $WorkspaceRoot -TransactionId ([string]$Journal.transaction_id) -ReplayCommand ([string]$Journal.replay_command) -Label "$($prefix)transaction journal")
    $createdAt = [datetimeoffset]::MinValue
    Assert-HarnessKernelCondition ([datetimeoffset]::TryParse([string]$Journal.created_at,[ref]$createdAt)) "$($prefix)transaction journal created_at is invalid"
    $operation = [string]$Journal.operation
    Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $Journal -Schema task-transaction-operations.schema.json -Label 'transaction operation' -FailureMessage "$($prefix)transaction operation step contract is invalid"
    if (-not $Legacy) {
        foreach ($key in @(@{approve='approval_input_path';verify='evidence_input_path'}[$operation])) {
            if (-not $key) { continue }
            Assert-HarnessKernelCondition ((Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$Journal.operation_context[$key]) -Label "transaction $key" -AllowMissing)) -ceq [string]$Journal.operation_context[$key]) "transaction $key is not normalized"
        }
    }
    $targetVersion,$stepsById,$targetPaths = $(if ($operation -ceq 'create') { [int64]1 } else { [int64]$Journal.expected_version + 1 }),[ordered]@{},[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $fixedPaths = @{'task-state'="$($script:RuntimeRelative)/tasks/$($Journal.task_id)/task.json"
        'event-log'="$($script:RuntimeRelative)/tasks/$($Journal.task_id)/events.jsonl"
        'governed-plan'="docs/tasks/$($Journal.task_id)/plan.md"
        evidence="docs/tasks/$($Journal.task_id)/evidence.json"
        'current-pointer'="$($script:RuntimeRelative)/current.json"}
    foreach ($step in @($Journal.steps)) {
        $id = [string]$step.id
        $stepsById[$id] = $step
        $normalized = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$step.relative_path) -Label "$($prefix)transaction step" -AllowMissing)
        Assert-HarnessKernelCondition ($targetPaths.Add($normalized)) "$($prefix)transaction journal contains a duplicate target path"
        $approvalPath = $id -ceq 'approval' -and $normalized -cmatch ("^\.assistant/runtime/tasks/" + [regex]::Escape([string]$Journal.task_id) + "/approvals/apr_[A-Za-z0-9._-]+\.json$")
        Assert-HarnessKernelCondition (($fixedPaths.ContainsKey($id) -and $normalized -ceq [string]$fixedPaths[$id]) -or $approvalPath) "$($prefix)transaction step path or action is invalid"
        if ([string]$step.action -ceq 'write') {
            $content = Get-TransactionStepText -Step $step -Label "$($prefix)transaction step content"
            if ($id -ceq 'event-log') { $eventText = $content }
            Assert-HarnessKernelCondition ([string]$step.after_digest -cmatch '^sha256:[0-9a-f]{64}$' -and [string]$step.after_digest -ceq (Get-HarnessSha256Text -Content $content)) "$($prefix)transaction step content digest is invalid"
        }
        if (-not $Legacy -and $null -ne $step.before_content_base64) {
            Assert-HarnessKernelCondition ([string]$step.before_digest -ceq (Get-HarnessSha256Text -Content (Get-TransactionStepText -Step $step -Label "transaction $id preimage" -Property before_content_base64))) "transaction $id preimage digest is invalid"
        }
    }
    $task = Get-TransactionPayloadDocument -Step $stepsById['task-state'] -Label "$($prefix)transaction task-state payload" -Schema task-state.schema.json -TaskId $Journal.task_id -Version $targetVersion -VersionField version
    Assert-TaskStateDocument -RepoRoot $script:SchemaRoot -Task $task
    $beforeTask = $null
    if (-not $Legacy -and $operation -cne 'create') {
        $beforeTask = Get-TransactionPayloadDocument -Step $stepsById['task-state'] -Label 'transaction task-state preimage' -Schema task-state.schema.json -TaskId $Journal.task_id -Version $Journal.expected_version -VersionField version -Before
        Assert-TaskStateDocument -RepoRoot $script:SchemaRoot -Task $beforeTask
    }
    if ($operation -ceq 'create') {
        Assert-HarnessKernelCondition ($null -eq $stepsById['task-state'].before_digest) "$($prefix)create transaction task target must not already exist"
        if (-not $Legacy) {
            Assert-HarnessKernelCondition ([string]$task.identity -ceq 'new' -and [string]$task.requirement_state -ceq 'clear' -and [string]$task.status -ceq 'ready' -and `
                $null -eq $task.block_reason -and -not @($task.approvals).Count -and $null -eq $task.evidence_path) 'create transaction task-state payload is not canonical'
        }
    }
    $eventLog = ConvertFrom-TaskEventLog -Text $eventText -Label "$($prefix)transaction event-log payload"
    Assert-HarnessKernelCondition ($eventLog.Count -gt 0) "$($prefix)transaction event-log payload is invalid"
    $events,$previousVersion = @($eventLog.Events),[int64]0
    foreach ($event in $events) {
        Assert-HarnessKernelCondition ([string]$event.task_id -ceq [string]$Journal.task_id -and [int64]$event.task_version -ge $previousVersion -and [int64]$event.task_version -le $targetVersion) "$($prefix)transaction event-log payload does not match its task intent"
        $previousVersion = [int64]$event.task_version
    }
    Assert-HarnessKernelCondition ($previousVersion -eq $targetVersion) "$($prefix)transaction event-log payload does not reach its target version"
    $targetEvents = @($events | Where-Object { [int64]$_.task_version -eq $targetVersion })
    $prefixCount = $eventLog.Lines.Count - $targetEvents.Count
    $prefixDigest = if ($prefixCount) { Get-HarnessSha256Text -Content ((@($eventLog.Lines[0..($prefixCount - 1)]) -join [char]10) + [char]10) } else { $null }
    Assert-HarnessKernelCondition ($(if ($null -eq $stepsById['event-log'].before_digest) { $null } else { [string]$stepsById['event-log'].before_digest }) -ceq $prefixDigest) "$($prefix)transaction event-log payload does not preserve its exact preimage prefix"
    $approval = if ($stepsById.Contains('approval')) { Get-TransactionPayloadDocument -Step $stepsById.approval -Label "$($prefix)transaction Approval payload" -Schema approval.schema.json -TaskId $Journal.task_id -Version $targetVersion } else { $null }
    $evidence = if ($stepsById.Contains('evidence')) { Get-TransactionPayloadDocument -Step $stepsById.evidence -Label "$($prefix)transaction Evidence payload" -Schema evidence.schema.json -TaskId $Journal.task_id -Version $Journal.expected_version } else { $null }
    if ($stepsById.Contains('current-pointer')) {
        $pointerStep = $stepsById['current-pointer']
        $beforePointer = if (-not $Legacy -and $null -ne $pointerStep.before_digest) { Get-TransactionPayloadDocument -Step $pointerStep -Label 'transaction current-pointer preimage' -Schema current-pointer.schema.json -TaskId $Journal.task_id -Version $Journal.expected_version -Before } else { $null }
        if ([string]$pointerStep.action -ceq 'write') {
                $pointer = Get-TransactionPayloadDocument -Step $pointerStep -Label "$($prefix)transaction current-pointer payload" -Schema current-pointer.schema.json -TaskId $Journal.task_id -Version $targetVersion
                if (-not $Legacy -and [string]$Journal.operation_context.pointer_action -ceq 'updated' -and
                    [string]$pointer.activated_at -cne [string]$beforePointer.activated_at) { throw 'transaction current-pointer activation identity changed' }
        }
        Assert-HarnessKernelCondition ([string]$pointerStep.action -ceq $(if ([string]$task.status -cin @('done','cancelled')) { 'delete' } else { 'write' })) "$($prefix)transaction current-pointer mutation does not match its task intent"
    }
    $event = $targetEvents[0]
    if (-not $Legacy -and $operation -cne 'create') {
        $allowedDelta = @{transition=@('version','status','requirement_state','block_reason','updated_at');resume=@('version','status','updated_at');approve=@('version','approvals','updated_at');verify=@('version','status','evidence_path','updated_at')}[$operation]
        if ($operation -ceq 'transition' -and [string]$event.payload.from -ceq 'blocked' -and [string]$event.payload.to -ceq 'ready') { $allowedDelta += @('contract_path','contract_digest') }
        $changed = @($beforeTask.Keys | Sort-Object | Where-Object { $allowedDelta -cnotcontains $_ -and -not (Test-HarnessKernelValueEqual -Left $beforeTask[$_] -Right $task[$_]) } | Select-Object -First 1)
        if ($changed.Count) { throw "$operation transaction changed an unauthorized task-state field: $($changed[0])" }
    }
    switch ($operation) {
        'create' {
            Assert-HarnessKernelCondition ($targetEvents.Count -eq 1 -and (Test-HarnessKernelFields $task @{status='ready'}) -and (Test-HarnessKernelFields $event @{type='task.created'}) -and
                ($Legacy -or ((Test-HarnessKernelFields $event.payload @{profile=$task.execution_profile;contract_digest=$task.contract_digest}) -and [bool]$task.policies.plan_required -eq $stepsById.Contains('governed-plan')))) "$($prefix)create transaction payload intent is invalid"
            if ($stepsById.Contains('governed-plan')) {
                $plan = Get-TransactionStepText -Step $stepsById['governed-plan'] -Label "$($prefix)transaction governed-plan payload"
                if ([regex]::Matches($plan,"(?m)^- task_id:\s*$([regex]::Escape([string]$Journal.task_id))\s*$").Count -ne 1 -or [regex]::Matches($plan,"(?m)^- contract_digest:\s*$([regex]::Escape([string]$task.contract_digest))\s*$").Count -ne 1) { throw "$($prefix)create governed-plan payload does not match its task intent" }
            }
        }
        'transition' {
            $from,$to = [string]$event.payload.from,[string]$event.payload.to
            Assert-HarnessKernelCondition ($targetEvents.Count -eq 1 -and (Test-HarnessKernelFields $event @{type=$script:TransitionEvents[$to]}) -and (Test-HarnessKernelFields $task @{status=$to}) -and ($Legacy -or [string]$beforeTask.status -ceq $from) -and $script:Transitions.Contains($from) -and @($script:Transitions[$from]) -ccontains $to) "$($prefix)transition transaction payload intent is invalid"
            if (-not $Legacy -and $from -ceq 'blocked' -and $to -ceq 'ready' -and [string]$task.contract_digest -ceq [string]$beforeTask.contract_digest) { throw 'transition revised Requirement intent is invalid' }
        }
        'resume' {
            Assert-HarnessKernelCondition ($targetEvents.Count -eq 1 -and (Test-HarnessKernelFields $event @{type='execution.started'}) -and (Test-HarnessKernelFields $event.payload @{to='running'}) -and (Test-HarnessKernelFields $task @{status='running'}) -and
                ($Legacy -or ((Test-HarnessKernelFields $beforeTask @{status=$event.payload.from}) -and (Test-HarnessKernelFields $event.payload @{source='resume-and-execute'}) -and [string]$event.payload.from -cin @('ready','running','paused','failed')))) "$($prefix)resume transaction payload intent is invalid"
        }
        'approve' {
            $approvalId,$approvalPath = [string]$approval.approval_id,[string]$stepsById.approval.relative_path
            Assert-HarnessKernelCondition ($targetEvents.Count -eq 1 -and (Test-HarnessKernelFields $approval @{contract_digest=$task.contract_digest;status='granted'}) -and (Test-HarnessKernelFields $event @{type='approval.granted'}) -and (Test-HarnessKernelFields $event.payload @{approval_id=$approvalId;approval_type=$approval.approval_type;approval_path=$approvalPath;digest=$stepsById.approval.after_digest}) -and
                -not (Test-HarnessApprovalExpiry $approval $createdAt) -and $null -eq $stepsById.approval.before_digest -and [bool]$(if($Legacy){$task}else{$beforeTask}).policies.approval_required -and [string]$(if($Legacy){$task}else{$beforeTask}).requirement_state -ceq 'clear' -and [string]$(if($Legacy){$task}else{$beforeTask}).status -cnotin @('done','cancelled') -and [IO.Path]::GetFileName($approvalPath) -ceq "$approvalId.json" -and
                $(if($Legacy){@($task.approvals|Where-Object{[string]$_-ceq$approvalId}).Count-eq1}else{Test-HarnessKernelValueEqual @($task.approvals) @(@($beforeTask.approvals)+$approvalId)})) "$($prefix)approve transaction payload intent is invalid"
        }
        'verify' {
            $status = @{pass='done';fail='running';blocked='paused';partial='verifying'}[[string]$evidence.conclusion]
            Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace($status) -and ($Legacy -or [string]$beforeTask.status -ceq 'verifying') -and (Test-HarnessKernelFields $task @{status=$status;evidence_path=$stepsById.evidence.relative_path;contract_digest=$evidence.contract_digest}) -and $targetEvents.Count -eq $(if([string]$evidence.conclusion -ceq 'partial'){1}else{2}) -and
                (Test-HarnessKernelFields $event @{type='verification.recorded'}) -and (Test-HarnessKernelFields $event.payload @{evidence_path=$stepsById.evidence.relative_path;digest=$stepsById.evidence.after_digest;conclusion=$evidence.conclusion;from='verifying';to=$status})) "$($prefix)verify transaction payload intent is invalid"
            if ($targetEvents.Count -eq 2 -and (-not (Test-HarnessKernelFields $targetEvents[1] @{type=$script:TransitionEvents[$status]}) -or -not (Test-HarnessKernelFields $targetEvents[1].payload @{source='evidence';conclusion=$evidence.conclusion}))) { throw "$($prefix)verify transaction lifecycle event does not match its Evidence" }
        }
    }
    $stepIds = @($Journal.steps.id)
    $completed = @($Journal.completed_steps | ForEach-Object { [string]$_ })
    if ($completed.Count -gt $stepIds.Count -or -not (Test-HarnessKernelValueEqual -Left $completed -Right @($stepIds | Select-Object -First $completed.Count))) { throw "$($prefix)transaction journal completed_steps must be an ordered prefix" }
    $expectedFailed = if ($completed.Count -lt $stepIds.Count) { $stepIds[$completed.Count] } else { 'cleanup' }
    $status,$failed,$errorText = [string]$Journal.status,[string]$Journal.failed_step,[string]$Journal.error
    $valid = if ($status -ceq 'prepared') { $completed.Count -eq 0 -and $failed -ceq $expectedFailed -and [string]::IsNullOrEmpty($errorText) } elseif ($status -ceq 'applying') { $completed.Count -gt 0 -and $failed -ceq $expectedFailed -and [string]::IsNullOrEmpty($errorText) } elseif ($status -ceq 'failed') { $failed -ceq $expectedFailed -and -not [string]::IsNullOrWhiteSpace($errorText) } else { $completed.Count -eq $stepIds.Count -and $failed -ceq '' -and [string]::IsNullOrEmpty($errorText) }
    if (-not $valid) { throw "$($prefix)$status transaction journal progress is invalid" }
    return [pscustomobject]@{Legacy=[bool]$Legacy;Prefix=$prefix;Journal=$Journal;Operation=$operation;StepsById=$stepsById;Task=$task;BeforeTask=$beforeTask;TargetEvents=$targetEvents;Approval=$approval;Evidence=$evidence}
}

function Read-TaskTransactionJournal {
    param([string]$WorkspaceRoot,[string]$Path,[ValidateSet('pending','archive')][string]$Location)
    $journal=(Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $Path -Label "transaction $Location").Document
    $view=Get-TransactionJournalView -WorkspaceRoot $WorkspaceRoot -Journal $journal -Location $Location
    $intent=Get-TransactionIntentDigest -WorkspaceRoot $WorkspaceRoot -Journal $journal -Legacy:$view.Legacy
    if(-not$view.Legacy){Assert-HarnessKernelCondition ([string]$journal.intent_digest -ceq $intent) 'transaction journal intent digest is invalid'}
    if([string]$journal.transaction_id-cne[System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileName($Path))){throw "transaction journal identity does not match its $Location filename"}
    return [pscustomobject]@{Format=$(if($view.Legacy){'legacy'}else{'current'});Journal=$journal;IntentDigest=$intent;View=$view}
}

function Assert-TransactionReplayInputs {
    param([string]$WorkspaceRoot,[pscustomobject]$View,[switch]$UseAuthorizedSnapshot)
    $Journal,$stepsById,$prefix,$task,$operation,$Legacy = $View.Journal,$View.StepsById,$View.Prefix,$View.Task,$View.Operation,$View.Legacy
    $replayAsOf = if ($UseAuthorizedSnapshot) { [datetimeoffset]::Parse([string]$Journal.created_at,[Globalization.CultureInfo]::InvariantCulture) } else { [datetimeoffset]::UtcNow }
    $beforeTask = $View.BeforeTask
    if ($operation -cin @('create','verify') -or ($operation -ceq 'transition' -and
        $(if ($Legacy) { [string]$View.TargetEvents[-1].payload.from } else { [string]$beforeTask.status }) -ceq 'blocked' -and [string]$task.status -ceq 'ready')) {
        $contractTask = if (-not $Legacy -and $operation -ceq 'verify') { $beforeTask } else { $task }
        $contract = Resolve-HarnessRequirementContract -RepoRoot $script:SchemaRoot -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Journal.task_id) -Path ([string]$contractTask.contract_path)
        Assert-HarnessKernelCondition ([string]$contract.Digest -ceq [string]$contractTask.contract_digest) "$prefix$operation transaction Requirement Contract is stale"
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
            $expected = @{OutputPath=$approvalStep.relative_path;Digest=$approvalStep.after_digest;Content=(Get-TransactionStepText -Step $approvalStep -Label 'transaction Approval payload')}
            Assert-HarnessKernelCondition (Test-HarnessKernelFields $resolvedApproval $expected) 'approve transaction input no longer matches its journal'
        }
    }

    if ($operation -ceq 'verify') {
        Assert-HarnessKernelCondition (-not $Legacy -or $UseAuthorizedSnapshot) 'legacy claim-free verify cannot be safely replayed because its original Evidence input path is unavailable; run verify again'
        $evidenceStep = $stepsById['evidence']
        $evidenceContent = Get-TransactionStepText -Step $evidenceStep -Label "$($prefix)transaction Evidence payload"
        if ($Legacy) {
            $beforeTask = (ConvertTo-HarnessKernelJson -Value $task) | ConvertFrom-HarnessJson -ErrorAction Stop
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
        $expected = @{OutputPath=$evidenceStep.relative_path;Digest=$evidenceStep.after_digest;Content=$evidenceContent;NextStatus=$task.status}
        Assert-HarnessKernelCondition (Test-HarnessKernelFields $resolvedEvidence $expected) "$($prefix)verify transaction input no longer matches its journal"
        $replayGovernance = Assert-HarnessGovernanceReady -RepoRoot $script:SchemaRoot -WorkspaceRoot $WorkspaceRoot -Task $beforeTask -Evidence $resolvedEvidence
        if ([bool]$beforeTask.policies.approval_required -and [string]$resolvedEvidence.NextStatus -ceq 'done') {
            [void](Assert-HarnessTaskApprovalCore -RepoRoot $script:SchemaRoot -WorkspaceRoot $WorkspaceRoot `
                -Task $beforeTask -RequiredOperation $replayGovernance.ProtectedOperation -AsOf $replayAsOf)
        }
    }

    $current = Read-CurrentPointer -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/current.json"
    if ($Legacy -and $stepsById.Contains('current-pointer')) { return }
    if ($Legacy -or [string]$Journal.operation_context.pointer_action -ceq 'unchanged') {
        Assert-HarnessKernelCondition ($null -eq $current -or [string]$current.task_id -cne [string]$Journal.task_id) "$($prefix)transaction omitted the current-pointer mutation for the current task"
        return
    }
    $pointerStep = $stepsById['current-pointer']
    $currentDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/current.json"
    Assert-HarnessKernelCondition (($null -eq $currentDigest -and ($null -eq $pointerStep.before_digest -or [string]$pointerStep.action -ceq 'delete')) -or `
        $currentDigest -ceq [string]$pointerStep.before_digest -or ([string]$pointerStep.action -ceq 'write' -and $currentDigest -ceq [string]$pointerStep.after_digest)) 'transaction current-pointer no longer matches its replay boundary'
}

function Invoke-TransactionStep {
    param([string]$WorkspaceRoot,[pscustomobject]$Record,[System.Collections.IDictionary]$Step,[switch]$AllowExistingClaim,[switch]$AllowLegacyUnclaimedPostimage)
    $claim = Enter-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step -AllowExisting:$AllowExistingClaim
    $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path)
    $write = [string]$Step.action -ceq 'write'
    $verb = if ($write) { '' } else { ' delete' }
    if ($(if ($write) { $current -ceq [string]$Step.after_digest } else { $null -eq $current })) {
        if ($claim.Created -and -not $AllowLegacyUnclaimedPostimage) {
            Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step -Claim $claim
            throw "transaction$verb postimage exists without its publication claim: $($Step.relative_path)"
        }
        return [pscustomobject]@{Result='already-applied';Claim=$claim}
    }
    if (-not $(if ($null -eq $Step.before_digest) { $null -eq $current } else { $current -ceq [string]$Step.before_digest })) {
        if ($claim.Created) { Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $Step -Claim $claim }
        throw "transaction$verb preimage changed: $($Step.relative_path)"
    }
    if ($write) {
        if ((Write-HarnessKernelBytesCas -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path) `
            -Bytes ([Convert]::FromBase64String([string]$Step.content_base64)) -SourceDigest ([string]$Step.after_digest) `
            -CurrentDigest $(if ($null -eq $Step.before_digest) { 'missing' } else { [string]$Step.before_digest })) -cne [string]$Step.after_digest) { throw "transaction postimage mismatch: $($Step.relative_path)" }
    } else {
        [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path) -ExpectedDigest ([string]$Step.before_digest))
    }
    Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $Step
    Assert-HarnessKernelCondition ([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_PUBLISH',[System.EnvironmentVariableTarget]::Process) -cne '1') 'injected task-state fault after publication'
    return [pscustomobject]@{Result='applied';Claim=$claim}
}

function Write-TaskTransactionProgress {
    param([string]$WorkspaceRoot,[string]$Path,[Collections.IDictionary]$Journal,[string]$ExpectedDigest,[string]$Status,[object[]]$Completed,[string]$FailedStep,[string]$ErrorText='')
    $Journal.status,$Journal.completed_steps,$Journal.failed_step,$Journal.error = $Status,@($Completed),$FailedStep,$ErrorText
    return Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $Path -Value $Journal -CurrentDigest $ExpectedDigest
}

function Invoke-TaskTransactionCompletion {
    param([string]$WorkspaceRoot,[pscustomobject]$Record,[string]$PendingPath,[string]$ArchivePath,[string]$PendingDigest,[switch]$Initial,[switch]$AuthorizedSnapshot)
    $journal = $Record.Journal
    $steps = @($journal.steps)
    $completed = [Collections.Generic.List[string]]::new([string[]]@($journal.completed_steps))
    $legacy = [string]$Record.Format -ceq 'legacy'
    $faultAfter,$faultBeforeRelease = $(if ($Initial) { [int]([Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP') -as [int]) } else { 0 }),$(if ($Initial) { [int]([Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_BEFORE_CLAIM_RELEASE') -as [int]) } else { 0 })
    try {
        if ($Initial) {
            $preclaimDelay = [int]([Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_PRECLAIM_DELAY_MS') -as [int])
            if ($preclaimDelay -gt 0) { Start-Sleep -Milliseconds ([Math]::Min($preclaimDelay,30000)) }
        }
        Assert-TransactionReplayInputs -WorkspaceRoot $WorkspaceRoot -View $Record.View -UseAuthorizedSnapshot:$AuthorizedSnapshot
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        if ($Initial) {
            Assert-HarnessKernelCondition ([Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_BEFORE_FIRST_CLAIM') -cne '1') 'injected task-state fault before first publication claim'
        }
        if ($legacy) {
            for ($index = 0; $index -lt $completed.Count; $index++) {
                $step = $steps[$index]
                [void](Enter-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step -AllowExisting)
                Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
            }
        }
        for ($index = $completed.Count; $index -lt $steps.Count; $index++) {
            $step = $steps[$index]
            [void](Invoke-TransactionStep -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step -AllowExistingClaim:(-not $Initial) -AllowLegacyUnclaimedPostimage:$legacy)
            $completed.Add([string]$step.id)
            $PendingDigest = Write-TaskTransactionProgress -WorkspaceRoot $WorkspaceRoot -Path $PendingPath -Journal $journal -ExpectedDigest $PendingDigest -Status applying -Completed @($completed) -FailedStep $(if ($index + 1 -lt $steps.Count) { [string]$steps[$index + 1].id } else { 'cleanup' })
            if ($faultBeforeRelease -gt 0 -and $completed.Count -eq $faultBeforeRelease) { throw "injected task-state fault before claim release after step $faultBeforeRelease" }
            if ($faultAfter -gt 0 -and $completed.Count -eq $faultAfter) { throw "injected task-state fault after step $faultAfter" }
        }
        if ($Initial) {
            $delay = [int]([Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_DELAY_BEFORE_COMMIT_MS') -as [int])
            if ($delay -gt 0) { Start-Sleep -Milliseconds ([Math]::Min($delay,5000)) }
        }
        foreach ($step in $steps) {
            Assert-HarnessKernelCondition ([string](Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step).State -ceq 'own') "$($Record.View.Prefix)transaction cannot commit without its own publication claim: $($step.relative_path)"
            Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
        }
        $PendingDigest = Write-TaskTransactionProgress -WorkspaceRoot $WorkspaceRoot -Path $PendingPath -Journal $journal -ExpectedDigest $PendingDigest -Status $(if ($Initial) { 'committed' } else { 'recovered' }) -Completed @($completed) -FailedStep ''
        [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes/archive" -Label 'transaction archive')
        [void](Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $ArchivePath -Value $journal -CurrentDigest 'missing')
        foreach ($step in $steps) {
            Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $Record -Step $step -Claim $null
        }
        if (-not (Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $PendingPath -ExpectedDigest $PendingDigest)) { throw 'transaction journal disappeared before CAS cleanup' }
        return [pscustomobject]@{TransactionId=[string]$journal.transaction_id;CompletedSteps=@($completed)}
    } catch {
        $failure = $_.Exception.Message
        if ($Initial -and (Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $PendingPath) -ceq $PendingDigest) {
            [void](Write-TaskTransactionProgress -WorkspaceRoot $WorkspaceRoot -Path $PendingPath -Journal $journal -ExpectedDigest $PendingDigest -Status failed `
                -Completed @($completed) -FailedStep $(if ($completed.Count -lt $steps.Count) { [string]$steps[$completed.Count].id } else { 'cleanup' }) -ErrorText $failure)
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
    $paths = Get-TaskStatePaths -TaskId $TaskId
    if ($Operation -ceq 'create') {
        Import-Module (Join-Path $PSScriptRoot 'Harness.Protocol.psm1') -Force
        $admission = Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
        if ($admission.selected_protocol -cne 'v2') { throw "new-work-not-admitted: $($admission.reason)" }
        $contract = Resolve-HarnessRequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Path $ContractPath
        $policies = Get-TaskPolicyFlags -RepoRoot $RepoRoot -Profile $Profile -Capabilities $Capabilities
    }
    return Invoke-TaskStateLocked -WorkspaceRoot $WorkspaceRoot -Action {
        $current = Read-CurrentPointer -WorkspaceRoot $WorkspaceRoot -Path $paths.Current
        $isCurrent = $null -ne $current -and [string]$current.task_id -ceq $TaskId
        $transactionId,$timestamp = ('txn_' + [guid]::NewGuid().ToString('N')),[datetimeoffset]::UtcNow.ToString('o')
        $beforeSteps,$afterSteps,$pointerAction,$operationContext,$planAction = @(),@(),'unchanged',[ordered]@{},'not-required'
        $eventPrefix,$extraEventText = '',''
        if ($Operation -ceq 'create') {
            if (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -Label 'task state' -AllowMissing)) { throw "task already exists: $TaskId" }
            if ($ActivateCurrent -and $null -ne $current) { throw "current task is already active: $($current.task_id)" }
            $next = [ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='ready';identity='new';intent='write';requirement_state='clear';execution_profile=$Profile;persistence='durable';contract_path=$contract.Path;contract_digest=$contract.Digest;block_reason=$null;policies=$policies;approvals=@();evidence_path=$null;created_at=$timestamp;updated_at=$timestamp}
            $eventType,$eventPayload = 'task.created',[ordered]@{profile=$Profile;contract_digest=$contract.Digest}
            if ([bool]$policies.plan_required) {
                $plan = New-HarnessPlanArtifact -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractDigest $contract.Digest
                $afterSteps = @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'governed-plan' -RelativePath $plan.Path -Action write -Content $plan.Content)
                $planAction = 'created'
            }
            if ($ActivateCurrent) { $pointerAction = 'activated' }
        } else {
            $task = Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId
            if ([int]$task.version -ne $ExpectedVersion) { throw "ExpectedVersion mismatch: expected=$ExpectedVersion actual=$($task.version)" }
            if ($isCurrent -and [int]$current.task_version -ne $ExpectedVersion) { throw "current pointer version is stale; replay or repair before $(if ($Operation -ceq 'resume') { 'resume-and-execute' } else { $Operation })" }
            $next = (ConvertTo-HarnessKernelJson -Value $task) | ConvertFrom-HarnessJson -ErrorAction Stop
            $next.version,$next.updated_at = ($ExpectedVersion + 1),[datetimeoffset]::UtcNow.ToString('o')
            $timestamp = [string]$next.updated_at
            $eventPrefix = (Read-EventLog -WorkspaceRoot $WorkspaceRoot -Path $paths.Events).Text
            switch ($Operation) {
                'transition' {
                    $from = [string]$task.status
                    if (@($script:Transitions[$from]) -cnotcontains $To) { throw "illegal task transition: $from -> $To" }
                    if ($EvidenceSatisfied) { throw '-EvidenceSatisfied was removed; use verify -Evidence' }
                    if ($To -ceq 'done') { throw 'done requires verify -Evidence' }
                    $next.status = $To
                    if ($To -ceq 'blocked') {
                        $next.requirement_state,$next.block_reason = 'blocked',$Reason
                    } elseif ($from -ceq 'blocked' -and $To -ceq 'ready') {
                        $contract = Resolve-HarnessRequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Path $ContractPath
                        if ($contract.Digest -ceq [string]$task.contract_digest) { throw 'blocked -> ready requires a revised Contract digest' }
                        $next.requirement_state,$next.block_reason = 'clear',$null
                        $next.contract_path,$next.contract_digest = $contract.Path,$contract.Digest
                    }
                    $eventType,$eventPayload = $script:TransitionEvents[$To],[ordered]@{from=$from;to=$To;reason=$Reason}
                }
                'resume' {
                    if ($null -ne $current -and -not $isCurrent) { throw "another current task is active: $($current.task_id)" }
                    $next.status = 'running'
                    $eventType,$eventPayload = 'execution.started',[ordered]@{from=[string]$task.status;to='running';source='resume-and-execute'}
                }
                'approve' {
                    $approval = Resolve-HarnessApprovalInput -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -ApprovalPath $ApprovalPath -TaskId $TaskId -TargetTaskVersion ($ExpectedVersion + 1) -ContractDigest $task.contract_digest
                    $next.approvals = @(@($task.approvals) + [string]$approval.Document.approval_id)
                    $eventType,$eventPayload = 'approval.granted',[ordered]@{approval_id=[string]$approval.Document.approval_id;approval_type=[string]$approval.Document.approval_type;approval_path=$approval.OutputPath;digest=$approval.Digest}
                    $beforeSteps = @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id approval -RelativePath $approval.OutputPath -Action write -Content $approval.Content)
                    $operationContext.approval_input_path = [string]$approval.InputPath
                }
                'verify' {
                    $contract = Resolve-HarnessRequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Path $task.contract_path
                    $evidence = Resolve-HarnessEvidence -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -TaskVersion $ExpectedVersion -ContractDigest $task.contract_digest -RequiredAcceptanceCount @($contract.Document.acceptance).Count -EvidencePath $EvidencePath
                    $governance = Assert-HarnessGovernanceReady -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $task -Evidence $evidence
                    $approval = $null
                    if ([bool]$task.policies.approval_required -and [string]$evidence.NextStatus -ceq 'done') {
                        $approval = Assert-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $task -RequiredOperation $governance.ProtectedOperation
                    }
                    $next.status,$next.evidence_path = $evidence.NextStatus,$evidence.OutputPath
                    $planPath,$auditPath = $(if ($null -ne $governance.Plan) { $governance.Plan.Path } else { $null }),$(if ($null -ne $governance.Audit) { $governance.Audit.Path } else { $null })
                    $eventType,$eventPayload = 'verification.recorded',[ordered]@{evidence_path=$evidence.OutputPath;digest=$evidence.Digest;conclusion=$evidence.Conclusion;from='verifying';to=$evidence.NextStatus;plan_path=$planPath;audit_path=$auditPath;approval_id=$(if ($null -ne $approval) { [string]$approval.Document.approval_id } else { $null })}
                    if ($evidence.NextStatus -cne 'verifying') {
                        $extraEventText = (ConvertTo-HarnessKernelJson -Value (New-TaskEvent -EventId ('evt2_' + $transactionId.Substring(4)) -TaskId $TaskId -Version $next.version `
                            -Type $script:TransitionEvents[$evidence.NextStatus] -Host $ActorHost -Model $ActorModel -Timestamp $timestamp `
                            -Payload ([ordered]@{source='evidence';conclusion=$evidence.Conclusion})) -Compress) + "`n"
                    }
                    $beforeSteps = @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id evidence -RelativePath $evidence.OutputPath -Action write -Content $evidence.Content)
                    $operationContext.evidence_input_path = [string]$evidence.InputPath
                }
            }
            if ($Operation -ceq 'resume') { $pointerAction = if ($null -eq $current) { 'activated' } else { 'updated' } }
            elseif ($isCurrent) { $pointerAction = if ([string]$next.status -cin @('done','cancelled')) { 'cleared' } else { 'updated' } }
        }
        $event = New-TaskEvent -EventId ('evt_' + $transactionId.Substring(4)) -TaskId $TaskId -Version $next.version -Type $eventType -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload $eventPayload
        $eventText = $eventPrefix + (ConvertTo-HarnessKernelJson -Value $event -Compress) + "`n" + $extraEventText
        $steps = [Collections.Generic.List[object]]@($beforeSteps + @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id task-state -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessKernelJson -Value $next)) + @(New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id event-log -RelativePath $paths.Events -Action write -Content $eventText) + $afterSteps)
        if ($pointerAction -cne 'unchanged') {
            if ($pointerAction -ceq 'cleared') {
                [void]$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id current-pointer -RelativePath $paths.Current -Action delete -Content $null))
            } else {
                    [void]$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id current-pointer -RelativePath $paths.Current -Action write `
                        -Content (ConvertTo-HarnessKernelJson -Value ([ordered]@{schema_version='current-pointer/v1';task_id=$TaskId;task_version=[int]$next.version;activated_at=$(if ($pointerAction -ceq 'activated') { [string]$next.updated_at } else { [string]$current.activated_at })}))))
            }
        }
        $operationContext.pointer_action = $pointerAction
        $journal = [ordered]@{transaction_id=$transactionId;operation=$Operation;task_id=$TaskId;expected_version=$ExpectedVersion
            workspace_identity=(Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot);operation_context=$operationContext;intent_digest=''
            status='prepared';completed_steps=@();failed_step=[string]$steps[0].id;error=''
            replay_command=(Get-TaskReplayCommand -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId);created_at=[datetimeoffset]::UtcNow.ToString('o');steps=@($steps)}
        $journal.intent_digest = Get-TransactionIntentDigest -Journal $journal
        $failedWrites = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes' -AllowMissing
        $candidatePaths = [Collections.Generic.HashSet[string]]::new([string[]]@($journal.steps.relative_path),[StringComparer]::OrdinalIgnoreCase)
        if (Test-Path -LiteralPath $failedWrites -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $failedWrites -Filter 'txn_*.json' -File) {
                $pendingJournal = (Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path (Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $file.FullName) -Location pending).Journal
                if ([string]$pendingJournal.transaction_id -ceq $transactionId) { throw 'transaction journal is already pending' }
                $overlap = @($pendingJournal.steps | Where-Object { $candidatePaths.Contains([string]$_.relative_path) } | Select-Object -First 1)
                if ($overlap.Count) { throw "transaction target is reserved by pending transaction $($pendingJournal.transaction_id): $($overlap[0].relative_path)" }
            }
        }
        foreach ($step in @($journal.steps)) {
            if (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path (Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $step) `
                -Label 'transaction step claim' -AllowMissing)) { throw "transaction target has a pending publication claim; replay or repair before mutation: $($step.relative_path)" }
        }
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes')
        $pending,$archive = "$($script:RuntimeRelative)/failed-writes/$transactionId.json","$($script:RuntimeRelative)/failed-writes/archive/$transactionId.json"
        Assert-HarnessKernelCondition (-not (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $archive -Label 'transaction archive' -AllowMissing))) 'transaction archive already exists'
        $record = [pscustomobject]@{Format='current';Journal=$journal;IntentDigest=[string]$journal.intent_digest;View=(Get-TransactionJournalView -WorkspaceRoot $WorkspaceRoot -Journal $journal)}
        $transaction = Invoke-TaskTransactionCompletion -WorkspaceRoot $WorkspaceRoot -Record $record -PendingPath $pending -ArchivePath $archive `
            -PendingDigest (Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $pending -Value $journal -CurrentDigest 'missing') -Initial
        switch ($Operation) {
            create { return [ordered]@{operation='create';transaction_id=$transaction.TransactionId;pointer_action=$pointerAction;plan_action=$planAction;task=$next} }
            transition { return [ordered]@{operation='transition';transaction_id=$transaction.TransactionId;pointer_action=$pointerAction;task=$next} }
            resume { return [ordered]@{operation='resume-and-execute';transaction_id=$transaction.TransactionId;write_authorized=$true;pointer_action=$pointerAction;task=$next} }
            approve { return [ordered]@{operation='approve';transaction_id=$transaction.TransactionId;approval_id=[string]$approval.Document.approval_id;approval_path=$approval.OutputPath;approval_digest=$approval.Digest;pointer_action=$pointerAction;task=$next} }
            verify { return [ordered]@{operation='verify';transaction_id=$transaction.TransactionId;conclusion=$evidence.Conclusion;evidence_path=$evidence.OutputPath;evidence_digest=$evidence.Digest;plan_path=$planPath;audit_path=$auditPath;pointer_action=$pointerAction;task=$next} }
        }
    }
}

function New-HarnessTaskState {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ContractPath,[ValidateSet('governed','critical')][string]$Profile='governed',[string[]]$Capabilities=@(),
        [switch]$ActivateCurrent,[string]$ActorHost='codex',[string]$ActorModel='inherit')
    return Invoke-HarnessTaskOperation -Operation create @PSBoundParameters
}

function Get-HarnessTaskStatus {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId)
    $script:TaskStateWorkspaceIdentityCache.Clear()
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    Assert-HarnessTaskId -TaskId $TaskId
    $paths = Get-TaskStatePaths -TaskId $TaskId
    return Invoke-TaskStateLocked -WorkspaceRoot $WorkspaceRoot -Action {
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        $task = Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId
        $events,$current = (Read-EventLog -WorkspaceRoot $WorkspaceRoot -Path $paths.Events),(Read-CurrentPointer -WorkspaceRoot $WorkspaceRoot -Path $paths.Current)
        if ($null -ne $current -and [string]$current.task_id -ceq $TaskId -and [int]$current.task_version -ne [int]$task.version) { throw 'current pointer task_version is stale' }
        return [ordered]@{operation='status';task=$task;event_count=$events.Count;is_current=$null-ne$current-and[string]$current.task_id-ceq$TaskId
            current=$current;pending_transactions=@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId);side_effects=New-HarnessZeroSideEffects}
    }
}

function Set-HarnessTaskTransition {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,
        [Parameter(Mandatory)][ValidateSet('blocked','ready','running','verifying','paused','done','failed','cancelled')][string]$To,[string]$Reason='',[string]$ContractPath='',[switch]$EvidenceSatisfied,[string]$ActorHost='codex',[string]$ActorModel='inherit')
    return Invoke-HarnessTaskOperation -Operation transition @PSBoundParameters
}

function Resume-HarnessTaskExecution {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,[string]$ActorHost='codex',[string]$ActorModel='inherit')
    return Invoke-HarnessTaskOperation -Operation resume @PSBoundParameters
}

function Set-HarnessTaskApproval {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,[Parameter(Mandatory)][string]$ApprovalPath,[string]$ActorHost='codex',[string]$ActorModel='inherit')
    return Invoke-HarnessTaskOperation -Operation approve @PSBoundParameters
}

function Set-HarnessTaskEvidence {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,[Parameter(Mandatory)][string]$EvidencePath,[string]$ActorHost='codex',[string]$ActorModel='inherit')
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
        $legacy,$prefix = ([string]$record.Format -ceq 'legacy'),$(if ([string]$record.Format -ceq 'legacy') { 'legacy ' } else { '' })
        if (-not $pendingExists) {
            foreach ($step in @($record.Journal.steps)) {
                $owner = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $record -Step $step
                Assert-HarnessKernelCondition ([string]$owner.State -cne 'own') "$($prefix)recovered transaction retains a publication claim owned by itself"
            }
            return [ordered]@{operation='replay';transaction_id=$TransactionId;result='already-recovered'}
        }

        $journal,$pendingDigest = $record.Journal,(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $pending)

        if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
            $archived = Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $archive -Location archive
            $archiveMatches = [string]$archived.Format -ceq [string]$record.Format -and [string]$archived.Journal.task_id -ceq [string]$journal.task_id -and [string]$archived.IntentDigest -ceq [string]$record.IntentDigest -and ($legacy -or ([string]$archived.Journal.workspace_identity -ceq [string]$journal.workspace_identity -and [string]$archived.Journal.status -cin @('committed','recovered')))
            if (-not $archiveMatches) { throw "$($prefix)transaction archive does not match its pending journal" }
            $owned = @($archived.Journal.steps | Where-Object {
                if ([string](Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $record -Step $_).State -cne 'own') { return $false }
                Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $_
                return $true
            })
            Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
            foreach ($step in $owned) {
                Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -Record $record -Step $step -Claim $null
            }
            if (-not (Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $pending -ExpectedDigest $pendingDigest)) { throw 'transaction journal disappeared before CAS cleanup' }
            return [ordered]@{operation='replay';transaction_id=$TransactionId;result='recovered';completed_steps=@($archived.Journal.completed_steps)}
        }

        $steps = @($journal.steps)
        $completed = [Collections.Generic.List[string]]::new([string[]]@($journal.completed_steps))
        $authorizedSnapshot = $legacy -and $completed.Count -gt 0

        for ($index = 0; $index -lt $steps.Count; $index++) {
            $step = $steps[$index]
            $owner = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -Record $record -Step $step
            Assert-HarnessKernelCondition ([string]$owner.State -cne 'foreign') "$($prefix)transaction target is claimed by another transaction: $($step.relative_path)"
            Assert-HarnessKernelCondition ([string]$owner.State -cne 'own' -or $index -le $completed.Count) "$($prefix)transaction has an out-of-order publication claim: $($step.relative_path)"

            if (-not $legacy) {
                if ($index -eq 0 -and [string]$owner.State -ceq 'own') { $authorizedSnapshot = $true }
                if ($index -lt $completed.Count) {
                    Assert-HarnessKernelCondition ([string]$owner.State -ceq 'own') "completed transaction step lacks its own publication claim: $($step.relative_path)"
                    Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
                }
                continue
            }

            $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$step.relative_path)
            $matchesBefore = if ($null -eq $step.before_digest) { $null -eq $current } else { $current -ceq [string]$step.before_digest }
            $matchesAfter = if ([string]$step.action -ceq 'write') { $current -ceq [string]$step.after_digest } else { $null -eq $current }
            if ($index -eq 0 -and ([string]$owner.State -ceq 'own' -or ($matchesAfter -and -not $matchesBefore))) {
                $authorizedSnapshot = $true
            }
            Assert-HarnessKernelCondition ($index -ge $completed.Count -or $matchesAfter) "legacy completed transaction step postcondition changed: $($step.relative_path)"
            Assert-HarnessKernelCondition ($index -ne $completed.Count -or $matchesBefore -or $matchesAfter) "legacy first unfinished transaction step is outside its replay boundary: $($step.relative_path)"
            Assert-HarnessKernelCondition ($index -le $completed.Count -or $matchesBefore) "legacy transaction suffix is published out of order: $($step.relative_path)"
        }

        $completedSteps = (Invoke-TaskTransactionCompletion -WorkspaceRoot $WorkspaceRoot -Record $record -PendingPath $pending -ArchivePath $archive -PendingDigest $pendingDigest -AuthorizedSnapshot:$authorizedSnapshot).CompletedSteps
        return [ordered]@{operation='replay';transaction_id=$TransactionId;result='recovered';completed_steps=@($completedSteps)}
    }
}

Export-ModuleMember -Function New-HarnessTaskState,Get-HarnessTaskStatus,Set-HarnessTaskTransition,Resume-HarnessTaskExecution,Set-HarnessTaskApproval,Set-HarnessTaskEvidence,Repair-HarnessTaskTransaction
