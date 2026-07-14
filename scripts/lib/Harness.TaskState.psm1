Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Evidence.psm1') -Force -ErrorAction Stop

$script:RuntimeRelative = '.assistant/runtime'
$script:Transitions = [ordered]@{
    blocked   = @('ready')
    ready     = @('running','cancelled')
    running   = @('verifying','blocked','failed','paused')
    verifying = @('done','running','paused','failed')
    paused    = @('running','verifying','cancelled')
    failed    = @('running')
    done      = @()
    cancelled = @()
}

function ConvertTo-HarnessJsonText {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 50) + "`n"
}

function ConvertTo-HarnessJsonLine {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 50 -Compress) + "`n"
}

function Assert-TaskStateExactKeys {
    param([System.Collections.IDictionary]$Value,[string[]]$Expected,[string]$Label)
    $actual = @($Value.Keys | ForEach-Object { [string]$_ })
    if (@($Expected | Where-Object { $actual -cnotcontains $_ }).Count -gt 0 -or @($actual | Where-Object { $Expected -cnotcontains $_ }).Count -gt 0) { throw "$Label keys are invalid" }
}

function Read-TaskStateJson {
    param([string]$WorkspaceRoot,[string]$Path,[string]$Label)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label $Label -MustExist File
    try { $value = Get-Content -LiteralPath $fullPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop } catch { throw "$Label is not valid JSON: $($_.Exception.Message)" }
    if ($value -isnot [System.Collections.IDictionary]) { throw "$Label must be a JSON object" }
    return $value
}

function Test-TaskStateSchema {
    param([object]$Value,[string]$SchemaPath,[string]$Label)
    try { $valid = Test-Json -Json ($Value | ConvertTo-Json -Depth 50 -Compress) -SchemaFile $SchemaPath -ErrorAction Stop -WarningAction SilentlyContinue } catch { throw "$Label schema validation failed: $($_.Exception.Message)" }
    if (-not $valid) { throw "$Label failed schema validation" }
}

function Get-TaskStatePaths {
    param([string]$TaskId)
    $taskRoot = "$($script:RuntimeRelative)/tasks/$TaskId"
    return [pscustomobject]@{
        Runtime=$script:RuntimeRelative
        TaskRoot=$taskRoot
        Task="$taskRoot/task.json"
        Events="$taskRoot/events.jsonl"
        Current="$($script:RuntimeRelative)/current.json"
        Failed="$($script:RuntimeRelative)/failed-writes"
        Archive="$($script:RuntimeRelative)/failed-writes/archive"
    }
}

function Get-TaskStateMutexName {
    param([string]$WorkspaceRoot,[string]$Suffix)
    $root = (Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot).ToLowerInvariant()
    $hash = (Get-HarnessSha256Text -Content $root).Substring(7,16)
    return "Global\dev-harness.v2.$hash.$Suffix"
}

function Enter-TaskStateMutex {
    param([string]$Name,[int]$TimeoutMilliseconds=10000)
    $mutex = [System.Threading.Mutex]::new($false,$Name)
    try {
        try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "timed out waiting for task-state mutex: $Name" }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Exit-TaskStateMutex {
    param([System.Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { [void]$Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Assert-V2WriteProtocol {
    $protocol = [System.Environment]::GetEnvironmentVariable('HARNESS_PROTOCOL',[System.EnvironmentVariableTarget]::Process)
    if ($protocol -cne 'v2') { throw 'task-state writes require explicit HARNESS_PROTOCOL=v2' }
}

function Get-RequirementContract {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$TaskId,[string]$ContractPath)
    $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $ContractPath -Label 'Contract' -MustExist File
    $contract = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'Contract'
    Test-TaskStateSchema -Value $contract -SchemaPath (Join-Path $RepoRoot 'schemas\requirement-contract.schema.json') -Label 'Contract'
    if ([string]$contract.task_id -cne $TaskId) { throw 'Contract task_id does not match TaskId' }
    if (@($contract.unresolved_product_decisions).Count -gt 0) { throw 'cannot create or resolve a task from a blocked Requirement Contract' }
    $withoutDigest = [ordered]@{}
    foreach ($key in @('schema_version','task_id','goal','acceptance','in_scope','out_of_scope','product_constraints','product_decisions','unresolved_product_decisions','source_authority')) { if ($contract.Contains($key)) { $withoutDigest[$key]=$contract[$key] } }
    $canonical = $withoutDigest | ConvertTo-Json -Depth 30 -Compress
    if ([string]$contract.digest -cne (Get-HarnessSha256Text -Content $canonical)) { throw 'Contract digest does not match canonical content' }
    return [pscustomobject]@{ Document=$contract; Path=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $path); Digest=[string]$contract.digest }
}

function Get-TaskPolicyFlags {
    param([string]$RepoRoot,[string]$Profile,[string[]]$Capabilities)
    if ($Profile -cnotin @('governed','critical')) { throw 'durable task profile must be governed or critical' }
    $execution = Get-Content -LiteralPath (Join-Path $RepoRoot 'policies\execution-profiles.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    $profilePolicy = $execution.profiles[$Profile]
    $allowed = @($profilePolicy.minimum_capabilities) + @($profilePolicy.configurable_capabilities)
    foreach ($capability in $Capabilities) { if ($allowed -cnotcontains $capability) { throw "capability is not allowed for ${Profile}: $capability" } }
    $selected = @($profilePolicy.minimum_capabilities) + @($Capabilities)
    if ($selected -cnotcontains 'verification_required' -or $selected -cnotcontains 'durable_artifacts_required') { throw 'durable task policy is missing mandatory capabilities' }
    return [ordered]@{
        plan_required=$selected -ccontains 'plan_required'
        approval_required=$selected -ccontains 'approval_required'
        rollback_required=$selected -ccontains 'rollback_required'
        independent_review_required=$selected -ccontains 'independent_review_required'
        verification_required=$selected -ccontains 'verification_required'
    }
}

function Assert-TaskStateDocument {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Task)
    Test-TaskStateSchema -Value $Task -SchemaPath (Join-Path $RepoRoot 'schemas\task-state.schema.json') -Label 'task state'
    if ([string]$Task.persistence -cne 'durable' -or [string]$Task.execution_profile -cnotin @('governed','critical')) { throw 'persisted task state has an ephemeral profile' }
    if ([string]$Task.status -ceq 'blocked') {
        if ([string]$Task.requirement_state -cne 'blocked' -or [string]::IsNullOrWhiteSpace([string]$Task.block_reason)) { throw 'blocked task state is inconsistent' }
    } elseif ([string]$Task.requirement_state -cne 'clear' -or $null -ne $Task.block_reason) { throw 'clear task state is inconsistent' }
}

function Read-TaskStateDocument {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$Path)
    $task = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'task state'
    Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $task
    return $task
}

function Assert-CurrentPointerDocument {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Pointer)
    Test-TaskStateSchema -Value $Pointer -SchemaPath (Join-Path $RepoRoot 'schemas\current-pointer.schema.json') -Label 'current pointer'
}

function Read-CurrentPointer {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$Path)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'current pointer' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return $null }
    $pointer = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $fullPath -Label 'current pointer'
    Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer
    return $pointer
}

function Read-EventLog {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$Path)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'event log' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return [pscustomobject]@{ Text=''; Count=0 } }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'event log is not a file' }
    try { $text = [System.IO.File]::ReadAllText($fullPath,[System.Text.UTF8Encoding]::new($false,$true)) } catch { throw "event log is not valid UTF-8: $($_.Exception.Message)" }
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n",[System.StringComparison]::Ordinal)) { throw 'event log must end with a newline' }
    $lines = @()
    if ($text.Length -gt 0) { $lines = @($text.Substring(0,$text.Length-1) -split "`n" | ForEach-Object { $_.TrimEnd("`r") }) }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { throw 'event log contains a blank line' }
        try { $event = $line | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop } catch { throw "event log contains invalid JSON: $($_.Exception.Message)" }
        Test-TaskStateSchema -Value $event -SchemaPath (Join-Path $RepoRoot 'schemas\event.schema.json') -Label 'event'
    }
    return [pscustomobject]@{ Text=$text; Count=$lines.Count }
}

function New-TaskEvent {
    param([string]$RepoRoot,[string]$EventId,[string]$TaskId,[int]$Version,[string]$Type,[string]$Host,[string]$Model,[string]$Timestamp,[System.Collections.IDictionary]$Payload)
    $event = [ordered]@{ schema_version='event/v1';event_id=$EventId;task_id=$TaskId;task_version=$Version;type=$Type;actor=[ordered]@{host=$Host;model=$Model};occurred_at=$Timestamp;payload=$Payload }
    Test-TaskStateSchema -Value $event -SchemaPath (Join-Path $RepoRoot 'schemas\event.schema.json') -Label 'event'
    return $event
}

function Get-TransitionEventType {
    param([string]$From,[string]$To)
    if ($To -ceq 'ready') { return 'requirement.resolved' }
    if ($To -ceq 'running') { return 'execution.started' }
    if ($To -ceq 'verifying') { return 'verification.started' }
    if ($To -ceq 'blocked') { return 'requirement.blocked' }
    if ($To -ceq 'paused') { return 'execution.paused' }
    if ($To -ceq 'done') { return 'task.completed' }
    if ($To -ceq 'failed') { return 'task.failed' }
    if ($To -ceq 'cancelled') { return 'task.cancelled' }
    throw "no event type for transition: $From -> $To"
}

function Get-PendingTransactions {
    param([string]$WorkspaceRoot,[string]$TaskId)
    $root = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes' -AllowMissing
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter 'txn_*.json' -File) {
        try { $journal = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop } catch { throw "transaction journal is invalid: $($file.Name)" }
        if ([string]$journal.task_id -ceq $TaskId) { $matches.Add([string]$journal.transaction_id) }
    }
    return @($matches)
}

function New-TransactionStep {
    param([string]$WorkspaceRoot,[string]$Id,[string]$RelativePath,[ValidateSet('write','delete')][string]$Action,[AllowNull()][string]$Content)
    $before = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $RelativePath
    if ($Action -ceq 'write') {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
        return [ordered]@{ id=$Id;relative_path=$RelativePath;action='write';before_digest=$before;after_digest=(Get-HarnessSha256Text -Content $Content);content_base64=[Convert]::ToBase64String($bytes) }
    }
    if ($null -eq $before) { throw "delete transaction target does not exist: $RelativePath" }
    return [ordered]@{ id=$Id;relative_path=$RelativePath;action='delete';before_digest=$before;after_digest=$null;content_base64=$null }
}

function Assert-TransactionJournal {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Journal)
    Assert-TaskStateExactKeys -Value $Journal -Expected @('transaction_id','operation','task_id','expected_version','status','completed_steps','failed_step','error','replay_command','created_at','steps') -Label 'transaction journal'
    if ([string]$Journal.transaction_id -cnotmatch '^txn_[0-9a-f]{32}$' -or [string]$Journal.task_id -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$' -or [string]$Journal.operation -cnotin @('create','transition','verify') -or [string]$Journal.status -cnotin @('prepared','applying','failed','recovered')) { throw 'transaction journal identity, operation, or status is invalid' }
    if (@($Journal.steps).Count -lt 2 -or @($Journal.steps).Count -gt 4) { throw 'transaction journal has an invalid step count' }
    $stepIds = [System.Collections.Generic.List[string]]::new()
    $allowedPaths = @(
        "$($script:RuntimeRelative)/current.json",
        "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/task.json",
        "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/events.jsonl",
        "docs/tasks/$($Journal.task_id)/evidence.json"
    )
    foreach ($step in @($Journal.steps)) {
        Assert-TaskStateExactKeys -Value $step -Expected @('id','relative_path','action','before_digest','after_digest','content_base64') -Label 'transaction step'
        if ([string]::IsNullOrWhiteSpace([string]$step.id) -or $stepIds.Contains([string]$step.id)) { throw 'transaction step id is missing or duplicated' }
        $stepIds.Add([string]$step.id)
        $resolved = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$step.relative_path) -Label 'transaction step' -AllowMissing
        $normalized = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $resolved
        if ($allowedPaths -cnotcontains $normalized -or [string]$step.action -cnotin @('write','delete')) { throw 'transaction step path or action is invalid' }
        if ($null -ne $step.before_digest -and [string]$step.before_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'transaction step preimage digest is invalid' }
        if ([string]$step.action -ceq 'write') {
            try { $content = (New-Object System.Text.UTF8Encoding($false)).GetString([Convert]::FromBase64String([string]$step.content_base64)) } catch { throw 'transaction step content is invalid' }
            if ([string]$step.after_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$step.after_digest -cne (Get-HarnessSha256Text -Content $content)) { throw 'transaction step content digest is invalid' }
        } elseif ($normalized -cne "$($script:RuntimeRelative)/current.json" -or [string]$step.before_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or $null -ne $step.after_digest -or $null -ne $step.content_base64) { throw 'delete transaction step is invalid' }
    }
    if (@($Journal.completed_steps | Where-Object { $stepIds -cnotcontains [string]$_ }).Count -gt 0) { throw 'transaction journal completed_steps is invalid' }
    if ([string]$Journal.failed_step -cnotin @($stepIds + @('cleanup',''))) { throw 'transaction journal failed_step is invalid' }
}

function Invoke-TransactionStep {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Step)
    $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path)
    if ([string]$Step.action -ceq 'write') {
        if ($current -ceq [string]$Step.after_digest) { return 'already-applied' }
        if ($current -cne $Step.before_digest) { throw "transaction preimage changed: $($Step.relative_path)" }
        $content = (New-Object System.Text.UTF8Encoding($false)).GetString([Convert]::FromBase64String([string]$Step.content_base64))
        $written = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path) -Content $content
        if ($written -cne [string]$Step.after_digest) { throw "transaction postimage mismatch: $($Step.relative_path)" }
        return 'applied'
    }
    if ($null -eq $current) { return 'already-applied' }
    if ($current -cne [string]$Step.before_digest) { throw "transaction delete preimage changed: $($Step.relative_path)" }
    [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path) -ExpectedDigest ([string]$Step.before_digest))
    return 'applied'
}

function Invoke-TaskStateTransaction {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Journal)
    Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $Journal
    [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes')
    [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/locks" -Label 'task-state locks')
    $journalPath = "$($script:RuntimeRelative)/failed-writes/$($Journal.transaction_id).json"
    $completed = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($Journal.completed_steps)) { $completed.Add([string]$id) }
    $lastDigest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $journalPath -Content (ConvertTo-HarnessJsonText -Value $Journal)
    $faultAfter = 0
    [void][int]::TryParse([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP'),[ref]$faultAfter)
    try {
        for ($index=0;$index -lt @($Journal.steps).Count;$index++) {
            $step = @($Journal.steps)[$index]
            [void](Invoke-TransactionStep -WorkspaceRoot $WorkspaceRoot -Step $step)
            if (-not $completed.Contains([string]$step.id)) { $completed.Add([string]$step.id) }
            $Journal.status='applying';$Journal.completed_steps=@($completed);$Journal.failed_step=$(if($index+1 -lt @($Journal.steps).Count){[string]@($Journal.steps)[$index+1].id}else{'cleanup'});$Journal.error=''
            $lastDigest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $journalPath -Content (ConvertTo-HarnessJsonText -Value $Journal)
            if ($faultAfter -gt 0 -and $completed.Count -eq $faultAfter) { throw "injected task-state fault after step $faultAfter" }
        }
        [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $journalPath -ExpectedDigest $lastDigest)
        return [pscustomobject]@{ TransactionId=[string]$Journal.transaction_id;CompletedSteps=@($completed) }
    } catch {
        $failure = $_.Exception.Message
        $actualDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $journalPath
        if ($actualDigest -ceq $lastDigest) {
            $Journal.status='failed';$Journal.completed_steps=@($completed);$Journal.error=$failure
            [void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $journalPath -Content (ConvertTo-HarnessJsonText -Value $Journal))
        }
        throw "$failure TransactionId=$($Journal.transaction_id). Replay: $($Journal.replay_command)"
    }
}

function New-TaskTransaction {
    param([string]$WorkspaceRoot,[string]$TransactionId,[string]$Operation,[string]$TaskId,[AllowNull()][object]$ExpectedVersion,[object[]]$Steps)
    $quotedWorkspace = "'" + ($WorkspaceRoot -replace "'","''") + "'"
    $replayCommand = "pwsh -File scripts/task.ps1 replay -TransactionId $TransactionId -WorkspaceRoot $quotedWorkspace"
    return [ordered]@{ transaction_id=$TransactionId;operation=$Operation;task_id=$TaskId;expected_version=$ExpectedVersion;status='prepared';completed_steps=@();failed_step=[string]$Steps[0].id;error='';replay_command=$replayCommand;created_at=[datetimeoffset]::UtcNow.ToString('o');steps=$Steps }
}

function New-HarnessTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][string]$ContractPath,
        [ValidateSet('governed','critical')][string]$Profile='governed',[string[]]$Capabilities=@(),[switch]$ActivateCurrent,[string]$ActorHost='codex',[string]$ActorModel='inherit'
    )
    Assert-V2WriteProtocol
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot;Assert-HarnessTaskId -TaskId $TaskId
    $contract=Get-RequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractPath $ContractPath
    $policies=Get-TaskPolicyFlags -RepoRoot $RepoRoot -Profile $Profile -Capabilities $Capabilities
    $paths=Get-TaskStatePaths -TaskId $TaskId
    $taskMutex=$null;$currentMutex=$null
    try {
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$TaskId")
        $currentMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        if (@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId).Count -gt 0) { throw 'task has a pending transaction; replay it before create' }
        $taskPath=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -Label 'task state' -AllowMissing
        if (Test-Path -LiteralPath $taskPath) { throw "task already exists: $TaskId" }
        $current=Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current
        if ($ActivateCurrent -and $null -ne $current) { throw "current task is already active: $($current.task_id)" }
        $timestamp=[datetimeoffset]::UtcNow.ToString('o')
        $task=[ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='ready';identity='new';intent='write';requirement_state='clear';execution_profile=$Profile;persistence='durable';contract_path=$contract.Path;contract_digest=$contract.Digest;block_reason=$null;policies=$policies;approvals=@();evidence_path=$null;created_at=$timestamp;updated_at=$timestamp}
        Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $task
        $transactionId='txn_'+[guid]::NewGuid().ToString('N');$eventId='evt_'+$transactionId.Substring(4)
        $event=New-TaskEvent -RepoRoot $RepoRoot -EventId $eventId -TaskId $TaskId -Version 1 -Type 'task.created' -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{profile=$Profile;contract_digest=$contract.Digest})
        $steps=[System.Collections.Generic.List[object]]::new();$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'task-state' -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessJsonText -Value $task)));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'event-log' -RelativePath $paths.Events -Action write -Content (ConvertTo-HarnessJsonLine -Value $event)))
        $pointerAction='unchanged'
        if ($ActivateCurrent) {
            $pointer=[ordered]@{schema_version='current-pointer/v1';task_id=$TaskId;task_version=1;activated_at=$timestamp};Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer
            $steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action write -Content (ConvertTo-HarnessJsonText -Value $pointer)));$pointerAction='activated'
        }
        $journal=New-TaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -Operation 'create' -TaskId $TaskId -ExpectedVersion $null -Steps @($steps)
        $transaction=Invoke-TaskStateTransaction -WorkspaceRoot $WorkspaceRoot -Journal $journal
        return [ordered]@{operation='create';transaction_id=$transaction.TransactionId;pointer_action=$pointerAction;task=$task}
    } finally { Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex }
}

function Get-HarnessTaskStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId)
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot;Assert-HarnessTaskId -TaskId $TaskId;$paths=Get-TaskStatePaths -TaskId $TaskId
    $taskMutex=$null;$currentMutex=$null
    try {
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$TaskId");$currentMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        $task=Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task;$events=Read-EventLog -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Events;$current=Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current;$pending=@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId)
        return [ordered]@{operation='status';task=$task;event_count=$events.Count;is_current=($null -ne $current -and [string]$current.task_id -ceq $TaskId);current=$current;pending_transactions=$pending;side_effects=[ordered]@{task_state_writes=0;runtime_writes=0;artifact_writes=0;external_writes=0}}
    } finally {Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex}
}

function Set-HarnessTaskTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,
        [Parameter(Mandatory)][ValidateSet('blocked','ready','running','verifying','paused','done','failed','cancelled')][string]$To,[string]$Reason='',[string]$ContractPath='',[switch]$EvidenceSatisfied,[string]$ActorHost='codex',[string]$ActorModel='inherit'
    )
    Assert-V2WriteProtocol;$WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot;Assert-HarnessTaskId -TaskId $TaskId;$paths=Get-TaskStatePaths -TaskId $TaskId
    $taskMutex=$null;$currentMutex=$null
    try {
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$TaskId");$currentMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        if (@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId).Count -gt 0) { throw 'task has a pending transaction; replay it before transition' }
        $task=Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task
        if ([int]$task.version -ne $ExpectedVersion) { throw "ExpectedVersion mismatch: expected=$ExpectedVersion actual=$($task.version)" }
        $from=[string]$task.status;if (@($script:Transitions[$from]) -cnotcontains $To) { throw "illegal task transition: $from -> $To" }
        if ($To -ceq 'blocked' -and [string]::IsNullOrWhiteSpace($Reason)) { throw 'blocked transition requires -Reason' }
        if ($from -ceq 'blocked' -and $To -ceq 'ready' -and [string]::IsNullOrWhiteSpace($ContractPath)) { throw 'blocked -> ready requires a revised -Contract' }
        if ($EvidenceSatisfied) { throw '-EvidenceSatisfied was removed; use verify -Evidence' }
        if ($To -ceq 'done') { throw 'done requires verify -Evidence' }
        $current=Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current;$isCurrent=$null -ne $current -and [string]$current.task_id -ceq $TaskId
        if ($isCurrent -and [int]$current.task_version -ne $ExpectedVersion) { throw 'current pointer version is stale; replay or repair before transition' }
        $next=(ConvertTo-HarnessJsonText -Value $task)|ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop;$next.version=$ExpectedVersion+1;$next.status=$To;$next.updated_at=[datetimeoffset]::UtcNow.ToString('o')
        if ($To -ceq 'blocked') {$next.requirement_state='blocked';$next.block_reason=$Reason}
        elseif ($from -ceq 'blocked' -and $To -ceq 'ready') {$contract=Get-RequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractPath $ContractPath;if($contract.Digest -ceq [string]$task.contract_digest){throw 'blocked -> ready requires a revised Contract digest'};$next.requirement_state='clear';$next.block_reason=$null;$next.contract_path=$contract.Path;$next.contract_digest=$contract.Digest}
        Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $next
        $transactionId='txn_'+[guid]::NewGuid().ToString('N');$timestamp=[string]$next.updated_at;$event=New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt_'+$transactionId.Substring(4)) -TaskId $TaskId -Version ([int]$next.version) -Type (Get-TransitionEventType -From $from -To $To) -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{from=$from;to=$To;reason=$Reason})
        $events=Read-EventLog -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Events;$eventText=$events.Text+(ConvertTo-HarnessJsonLine -Value $event)
        $steps=[System.Collections.Generic.List[object]]::new();$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'task-state' -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessJsonText -Value $next)));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'event-log' -RelativePath $paths.Events -Action write -Content $eventText));$pointerAction='unchanged'
        if ($isCurrent) {
            if ($To -ceq 'done') {$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action delete -Content $null));$pointerAction='cleared'}
            else {$pointer=[ordered]@{schema_version='current-pointer/v1';task_id=$TaskId;task_version=[int]$next.version;activated_at=[string]$current.activated_at};Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer;$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action write -Content (ConvertTo-HarnessJsonText -Value $pointer)));$pointerAction='updated'}
        }
        $journal=New-TaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -Operation 'transition' -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Steps @($steps)
        $transaction=Invoke-TaskStateTransaction -WorkspaceRoot $WorkspaceRoot -Journal $journal
        return [ordered]@{operation='transition';transaction_id=$transaction.TransactionId;pointer_action=$pointerAction;task=$next}
    } finally {Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex}
}

function Set-HarnessTaskEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,
        [Parameter(Mandatory)][string]$EvidencePath,[string]$ActorHost='codex',[string]$ActorModel='inherit'
    )
    Assert-V2WriteProtocol;$WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot;Assert-HarnessTaskId -TaskId $TaskId;$paths=Get-TaskStatePaths -TaskId $TaskId
    $taskMutex=$null;$currentMutex=$null
    try{
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$TaskId");$currentMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        if(@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId).Count-gt 0){throw 'task has a pending transaction; replay it before verify'}
        $task=Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task
        if([int]$task.version-ne$ExpectedVersion){throw "ExpectedVersion mismatch: expected=$ExpectedVersion actual=$($task.version)"}
        if([string]$task.status-cne'verifying'){throw "verify requires task status verifying; actual=$($task.status)"}
        $contract=Get-RequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractPath ([string]$task.contract_path)
        if($contract.Digest-cne[string]$task.contract_digest){throw 'task Contract digest is stale'}
        $evidence=Resolve-HarnessEvidence -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -TaskVersion $ExpectedVersion -ContractDigest ([string]$task.contract_digest) -RequiredAcceptanceCount @($contract.Document.acceptance).Count -EvidencePath $EvidencePath
        $current=Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current;$isCurrent=$null-ne$current-and[string]$current.task_id-ceq$TaskId
        if($isCurrent-and[int]$current.task_version-ne$ExpectedVersion){throw 'current pointer version is stale; replay or repair before verify'}
        $next=(ConvertTo-HarnessJsonText -Value $task)|ConvertFrom-Json -AsHashtable -DateKind String;$next.version=$ExpectedVersion+1;$next.status=$evidence.NextStatus;$next.evidence_path=$evidence.OutputPath;$next.updated_at=[datetimeoffset]::UtcNow.ToString('o');Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $next
        $transactionId='txn_'+[guid]::NewGuid().ToString('N');$timestamp=[string]$next.updated_at;$events=Read-EventLog -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Events
        $recorded=New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt_'+$transactionId.Substring(4)) -TaskId $TaskId -Version ([int]$next.version) -Type 'verification.recorded' -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{evidence_path=$evidence.OutputPath;digest=$evidence.Digest;conclusion=$evidence.Conclusion;from='verifying';to=$evidence.NextStatus})
        $eventText=$events.Text+(ConvertTo-HarnessJsonLine -Value $recorded)
        if($evidence.NextStatus-cne'verifying'){$transition=New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt2_'+$transactionId.Substring(4)) -TaskId $TaskId -Version ([int]$next.version) -Type (Get-TransitionEventType -From 'verifying' -To $evidence.NextStatus) -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{source='evidence';conclusion=$evidence.Conclusion});$eventText+=(ConvertTo-HarnessJsonLine -Value $transition)}
        $steps=[Collections.Generic.List[object]]::new();$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'evidence' -RelativePath $evidence.OutputPath -Action write -Content $evidence.Content));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'task-state' -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessJsonText -Value $next)));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'event-log' -RelativePath $paths.Events -Action write -Content $eventText));$pointerAction='unchanged'
        if($isCurrent){if($evidence.NextStatus-ceq'done'){$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action delete -Content $null));$pointerAction='cleared'}else{$pointer=[ordered]@{schema_version='current-pointer/v1';task_id=$TaskId;task_version=[int]$next.version;activated_at=[string]$current.activated_at};Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer;$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action write -Content (ConvertTo-HarnessJsonText -Value $pointer)));$pointerAction='updated'}}
        $journal=New-TaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -Operation 'verify' -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Steps @($steps);$transaction=Invoke-TaskStateTransaction -WorkspaceRoot $WorkspaceRoot -Journal $journal
        return [ordered]@{operation='verify';transaction_id=$transaction.TransactionId;conclusion=$evidence.Conclusion;evidence_path=$evidence.OutputPath;evidence_digest=$evidence.Digest;pointer_action=$pointerAction;task=$next}
    }finally{Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex}
}

function Repair-HarnessTaskTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TransactionId)
    Assert-V2WriteProtocol;if($TransactionId -cnotmatch '^txn_[0-9a-f]{32}$'){throw 'invalid TransactionId'};$WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $pending="$($script:RuntimeRelative)/failed-writes/$TransactionId.json";$archive="$($script:RuntimeRelative)/failed-writes/archive/$TransactionId.json";$pendingPath=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $pending -Label 'transaction journal' -AllowMissing;$archivePath=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $archive -Label 'transaction archive' -AllowMissing
    if (-not (Test-Path -LiteralPath $pendingPath) -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {return [ordered]@{operation='replay';transaction_id=$TransactionId;result='already-recovered'}}
    if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)){throw "transaction journal not found: $TransactionId"}
    $journal=Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $pendingPath -Label 'transaction journal';Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $journal;$taskId=[string]$journal.task_id
    $taskMutex=$null;$currentMutex=$null
    try {
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$taskId");$currentMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        $journal=Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $pending -Label 'transaction journal';Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $journal;$completed=[System.Collections.Generic.List[string]]::new();foreach($id in @($journal.completed_steps)){$completed.Add([string]$id)}
        foreach($step in @($journal.steps)){[void](Invoke-TransactionStep -WorkspaceRoot $WorkspaceRoot -Step $step);if(-not $completed.Contains([string]$step.id)){$completed.Add([string]$step.id)};$journal.status='applying';$journal.completed_steps=@($completed);$journal.failed_step='cleanup';$journal.error='';[void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $pending -Content (ConvertTo-HarnessJsonText -Value $journal))}
        $journal.status='recovered';$journal.completed_steps=@($completed);$journal.failed_step='';$journal.error='';[void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes/archive" -Label 'transaction archive');[void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $archive -Content (ConvertTo-HarnessJsonText -Value $journal));$digest=Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $pending;[void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $pending -ExpectedDigest $digest)
        return [ordered]@{operation='replay';transaction_id=$TransactionId;result='recovered';completed_steps=@($completed)}
    }finally{Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex}
}

Export-ModuleMember -Function New-HarnessTaskState,Get-HarnessTaskStatus,Set-HarnessTaskTransition,Set-HarnessTaskEvidence,Repair-HarnessTaskTransaction
