Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
$script:EvidenceModule = @(Import-Module (Join-Path $PSScriptRoot 'Harness.Evidence.psm1') -Force -PassThru -ErrorAction Stop)[-1]
Import-Module (Join-Path $PSScriptRoot 'Harness.Governance.psm1') -Force -ErrorAction Stop
$script:ApprovalModule = @(Import-Module (Join-Path $PSScriptRoot 'Harness.Approval.psm1') -Force -PassThru -ErrorAction Stop)[-1]
$script:AtomicWriteModule = @(Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -PassThru -ErrorAction Stop)[-1]

$script:RuntimeRelative = '.assistant/runtime'
$script:TaskStateWorkspaceIdentityCache = $null
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
    $expectedKeys = @($Expected | Where-Object { $null -ne $_ })
    if (@($expectedKeys | Where-Object { $actual -cnotcontains $_ }).Count -gt 0 -or @($actual | Where-Object { $expectedKeys -cnotcontains $_ }).Count -gt 0) { throw "$Label keys are invalid" }
}

function Read-TaskStateJson {
    param([string]$WorkspaceRoot,[string]$Path,[string]$Label)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label $Label -MustExist File
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.FileStream]::new($fullPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,$share,4096,[System.IO.FileOptions]::SequentialScan)
        try {
            $reader = [System.IO.StreamReader]::new($stream,[System.Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        $value = $text | ConvertFrom-HarnessJson -ErrorAction Stop
    } catch { throw "$Label is not valid JSON: $($_.Exception.Message)" }
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

function Reset-TaskStateWorkspaceIdentityCache {
    $script:TaskStateWorkspaceIdentityCache = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
}

function Get-TaskStateWorkspaceIdentity {
    param([string]$WorkspaceRoot)
    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ($null -eq $script:TaskStateWorkspaceIdentityCache) { Reset-TaskStateWorkspaceIdentityCache }
    if ($script:TaskStateWorkspaceIdentityCache.ContainsKey($root)) { return $script:TaskStateWorkspaceIdentityCache[$root] }
    $identity = Get-HarnessPhysicalPathIdentity -Path $root
    $script:TaskStateWorkspaceIdentityCache.Add($root,$identity)
    return $identity
}

function Assert-TaskStateWorkspaceIdentityCurrent {
    param([string]$WorkspaceRoot)
    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $expected = Get-TaskStateWorkspaceIdentity -WorkspaceRoot $root
    $actual = Get-HarnessPhysicalPathIdentity -Path $root
    if ($actual -cne $expected) { throw 'WorkspaceRoot physical identity changed during task-state operation' }
    if ([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_IDENTITY_RECHECK',[System.EnvironmentVariableTarget]::Process) -ceq '1') {
        throw 'injected task-state identity recheck failure'
    }
}

function Get-TaskStateMutexName {
    param([string]$WorkspaceRoot,[string]$Suffix)
    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $identity = Get-TaskStateWorkspaceIdentity -WorkspaceRoot $root
    $hash = (Get-HarnessSha256Text -Content $identity).Substring(7,16)
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
    Reset-TaskStateWorkspaceIdentityCache
}

function Assert-RequirementContractDocument {
    param([string]$RepoRoot,[string]$TaskId,[System.Collections.IDictionary]$Contract)
    Test-TaskStateSchema -Value $Contract -SchemaPath (Join-Path $RepoRoot 'schemas\requirement-contract.schema.json') -Label 'Contract'
    if ([string]$Contract.task_id -cne $TaskId) { throw 'Contract task_id does not match TaskId' }
    if (@($Contract.unresolved_product_decisions).Count -gt 0) { throw 'cannot create or resolve a task from a blocked Requirement Contract' }
    $withoutDigest = [ordered]@{}
    foreach ($key in @('schema_version','task_id','goal','acceptance','in_scope','out_of_scope','product_constraints','product_decisions','unresolved_product_decisions','source_authority')) { if ($Contract.Contains($key)) { $withoutDigest[$key]=$Contract[$key] } }
    $canonical = $withoutDigest | ConvertTo-Json -Depth 30 -Compress
    if ([string]$Contract.digest -cne (Get-HarnessSha256Text -Content $canonical)) { throw 'Contract digest does not match canonical content' }
}

function Get-RequirementContract {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$TaskId,[string]$ContractPath)
    $path = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $ContractPath -Label 'Contract' -MustExist File
    $contract = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'Contract'
    Assert-RequirementContractDocument -RepoRoot $RepoRoot -TaskId $TaskId -Contract $contract
    return [pscustomobject]@{ Document=$contract; Path=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $path); Digest=[string]$contract.digest }
}

function Get-TaskPolicyFlags {
    param([string]$RepoRoot,[string]$Profile,[string[]]$Capabilities)
    if ($Profile -cnotin @('governed','critical')) { throw 'durable task profile must be governed or critical' }
    $execution = Get-Content -LiteralPath (Join-Path $RepoRoot 'policies\execution-profiles.json') -Raw -Encoding utf8 | ConvertFrom-HarnessJson -ErrorAction Stop
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
    if ([string]$Task.persistence -cne 'durable' -or
        [string]$Task.execution_profile -cnotin @('governed','critical') -or
        [string]$Task.intent -cne 'write') {
        throw 'persisted task state has an invalid durable execution profile'
    }
    foreach ($key in @('contract_path','contract_digest','block_reason','approvals','evidence_path')) {
        if (-not $Task.Contains($key)) { throw "persisted task state is missing its $key invariant" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Task.contract_path) -or
        [string]$Task.contract_digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'persisted task state requires a bound Requirement Contract'
    }
    $capabilities = @()
    if ([string]$Task.execution_profile -ceq 'governed') {
        $capabilities = @(@('plan_required','approval_required','rollback_required','independent_review_required') | Where-Object { [bool]$Task.policies[$_] })
    }
    $expectedPolicies = Get-TaskPolicyFlags -RepoRoot $RepoRoot -Profile ([string]$Task.execution_profile) -Capabilities $capabilities
    if (-not (Test-TaskStateValueEqual -Left $Task.policies -Right $expectedPolicies)) {
        throw 'persisted task state policies do not match its execution profile'
    }
    if ([string]$Task.status -ceq 'blocked') {
        if ([string]$Task.requirement_state -cne 'blocked' -or [string]::IsNullOrWhiteSpace([string]$Task.block_reason)) { throw 'blocked task state is inconsistent' }
    } elseif ([string]$Task.requirement_state -cne 'clear' -or $null -ne $Task.block_reason) { throw 'clear task state is inconsistent' }
}

function Read-TaskStateDocument {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$Path,[string]$ExpectedTaskId)
    $task = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'task state'
    Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $task
    if ([string]$task.task_id -cne $ExpectedTaskId) { throw 'persisted task state task_id does not match its canonical path' }
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
        try { $event = $line | ConvertFrom-HarnessJson -ErrorAction Stop } catch { throw "event log contains invalid JSON: $($_.Exception.Message)" }
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
        $relativePath = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $file.FullName
        $record = Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Location pending
        if ([string]$record.Journal.task_id -ceq $TaskId) { $matches.Add([string]$record.Journal.transaction_id) }
    }
    return @($matches)
}

function Test-TaskStateExactKeySet {
    param([AllowNull()][object]$Value,[string[]]$Expected)
    if ($Value -isnot [System.Collections.IDictionary]) { return $false }
    $actual = @($Value.Keys | ForEach-Object { [string]$_ })
    return (@($Expected | Where-Object { $actual -cnotcontains $_ }).Count -eq 0 -and
        @($actual | Where-Object { $Expected -cnotcontains $_ }).Count -eq 0)
}

function Get-TransactionJournalFormat {
    param([System.Collections.IDictionary]$Journal)
    $currentJournalKeys = @('transaction_id','operation','task_id','expected_version','workspace_identity','operation_context','intent_digest','status','completed_steps','failed_step','error','replay_command','created_at','steps')
    $legacyJournalKeys = @('transaction_id','operation','task_id','expected_version','status','completed_steps','failed_step','error','replay_command','created_at','steps')
    $currentStepKeys = @('id','relative_path','action','before_digest','before_content_base64','after_digest','content_base64')
    $legacyStepKeys = @('id','relative_path','action','before_digest','after_digest','content_base64')
    $currentTop = Test-TaskStateExactKeySet -Value $Journal -Expected $currentJournalKeys
    $legacyTop = Test-TaskStateExactKeySet -Value $Journal -Expected $legacyJournalKeys
    if (-not $currentTop -and -not $legacyTop) { throw 'transaction journal format is unknown or hybrid' }
    $expectedStepKeys = if ($currentTop) { $currentStepKeys } else { $legacyStepKeys }
    foreach ($step in @($Journal.steps)) {
        if (-not (Test-TaskStateExactKeySet -Value $step -Expected $expectedStepKeys)) {
            throw 'transaction journal format is unknown or hybrid'
        }
    }
    return $(if ($currentTop) { 'current' } else { 'legacy' })
}

function New-TransactionStep {
    param([string]$WorkspaceRoot,[string]$Id,[string]$RelativePath,[ValidateSet('write','delete')][string]$Action,[AllowNull()][string]$Content)
    $before = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $RelativePath
    $beforeContentBase64 = $null
    if ($Id -cin @('task-state','current-pointer') -and $null -ne $before) {
        $beforePath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $RelativePath -Label "$Id transaction preimage" -MustExist File
        $beforeBytes = [System.IO.File]::ReadAllBytes($beforePath)
        $beforeText = [System.Text.UTF8Encoding]::new($false,$true).GetString($beforeBytes)
        if ((Get-HarnessSha256Text -Content $beforeText) -cne $before) { throw "$Id transaction preimage changed while preparing the journal" }
        $beforeContentBase64 = [Convert]::ToBase64String($beforeBytes)
    }
    if ($Action -ceq 'write') {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
        return [ordered]@{ id=$Id;relative_path=$RelativePath;action='write';before_digest=$before;before_content_base64=$beforeContentBase64;after_digest=(Get-HarnessSha256Text -Content $Content);content_base64=[Convert]::ToBase64String($bytes) }
    }
    if ($null -eq $before) { throw "delete transaction target does not exist: $RelativePath" }
    return [ordered]@{ id=$Id;relative_path=$RelativePath;action='delete';before_digest=$before;before_content_base64=$beforeContentBase64;after_digest=$null;content_base64=$null }
}

function Test-TaskStateIntegerValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $false }
    return ($Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64])
}

function Get-TaskReplayCommand {
    param([string]$WorkspaceRoot,[string]$TransactionId)
    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $quotedWorkspace = "'" + ($workspace -replace "'","''") + "'"
    $repoTaskScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'task.ps1'
    $quotedTaskScript = "'" + ($repoTaskScript -replace "'","''") + "'"
    return "pwsh -File $quotedTaskScript replay -TransactionId $TransactionId -WorkspaceRoot $quotedWorkspace"
}

function Get-TaskReplayCommandWorkspace {
    param([string]$WorkspaceRoot,[string]$TransactionId,[string]$ReplayCommand,[string]$Label)
    if ($ReplayCommand -match "[`r`n]") { throw "$Label replay command is invalid" }

    $quotedScriptPattern = "'(?<script>(?:[^'`r`n]|'')+)'"
    $quotedWorkspacePattern = "'(?<workspace>(?:[^'`r`n]|'')+)'"
    $transactionPattern = [regex]::Escape($TransactionId)
    $sourcePattern = '^pwsh -File ' + $quotedScriptPattern + ' replay -TransactionId ' + $transactionPattern + ' -WorkspaceRoot ' + $quotedWorkspacePattern + '$'
    $legacyPattern = '^pwsh -File scripts/task\.ps1 replay -TransactionId ' + $transactionPattern + ' -WorkspaceRoot ' + $quotedWorkspacePattern + '$'

    $recordedWorkspace = ''
    $sourceMatch = [regex]::Match($ReplayCommand,$sourcePattern)
    $legacyMatch = [regex]::Match($ReplayCommand,$legacyPattern)
    if ($sourceMatch.Success) {
        $scriptPath = $sourceMatch.Groups['script'].Value.Replace("''", "'")
        $expectedScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'task.ps1'
        if (-not [IO.Path]::IsPathFullyQualified($scriptPath)) { throw "$Label replay command is invalid" }
        try {
            if ((Resolve-Path -LiteralPath $scriptPath).Path -ine (Resolve-Path -LiteralPath $expectedScript).Path) { throw 'mismatch' }
        } catch {
            throw "$Label replay command is invalid"
        }
        $recordedWorkspace = $sourceMatch.Groups['workspace'].Value.Replace("''", "'")
    } elseif ($legacyMatch.Success) {
        $recordedWorkspace = $legacyMatch.Groups['workspace'].Value.Replace("''", "'")
    } else {
        throw "$Label replay command is invalid"
    }

    try {
        $recordedIdentity = Get-TaskStateWorkspaceIdentity -WorkspaceRoot $recordedWorkspace
        $actualIdentity = Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot
    } catch {
        throw "$Label replay command workspace cannot be verified"
    }
    if ($recordedIdentity -cne $actualIdentity) { throw "$Label replay command workspace is invalid" }
    return $recordedWorkspace
}

function Get-TransactionIntentDigest {
    param([System.Collections.IDictionary]$Journal)
    $canonicalSteps = @($Journal.steps | ForEach-Object {
        [ordered]@{
            id=[string]$_.id
            relative_path=[string]$_.relative_path
            action=[string]$_.action
            before_digest=$_.before_digest
            before_content_base64=$_.before_content_base64
            after_digest=$_.after_digest
            content_base64=$_.content_base64
        }
    })
    $intent = [ordered]@{
        transaction_id=[string]$Journal.transaction_id
        operation=[string]$Journal.operation
        task_id=[string]$Journal.task_id
        expected_version=$Journal.expected_version
        workspace_identity=[string]$Journal.workspace_identity
        operation_context=$Journal.operation_context
        replay_command=[string]$Journal.replay_command
        created_at=[string]$Journal.created_at
        steps=$canonicalSteps
    }
    return Get-HarnessSha256Text -Content (ConvertTo-HarnessJsonText -Value $intent)
}

function Get-TransactionStepContent {
    param([System.Collections.IDictionary]$Step,[string]$Label)
    try {
        $bytes = [Convert]::FromBase64String([string]$Step.content_base64)
        return [System.Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    } catch {
        throw "$Label is not valid base64-encoded UTF-8"
    }
}

function Get-TransactionStepBeforeContent {
    param([System.Collections.IDictionary]$Step,[string]$Label)
    if ($null -eq $Step.before_content_base64) { return $null }
    try {
        $bytes = [Convert]::FromBase64String([string]$Step.before_content_base64)
        return [System.Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    } catch {
        throw "$Label is not valid base64-encoded UTF-8"
    }
}

function ConvertFrom-TransactionStepJson {
    param([System.Collections.IDictionary]$Step,[string]$Label)
    $content = Get-TransactionStepContent -Step $Step -Label $Label
    try { $document = $content | ConvertFrom-HarnessJson -ErrorAction Stop } catch { throw "$Label is not valid JSON" }
    if ($document -isnot [System.Collections.IDictionary]) { throw "$Label must be a JSON object" }
    return $document
}

function ConvertFrom-TransactionStepBeforeJson {
    param([System.Collections.IDictionary]$Step,[string]$Label)
    $content = Get-TransactionStepBeforeContent -Step $Step -Label $Label
    if ($null -eq $content) { throw "$Label is missing" }
    try { $document = $content | ConvertFrom-HarnessJson -ErrorAction Stop } catch { throw "$Label is not valid JSON" }
    if ($document -isnot [System.Collections.IDictionary]) { throw "$Label must be a JSON object" }
    return $document
}

function Test-TaskStateValueEqual {
    param([AllowNull()][object]$Left,[AllowNull()][object]$Right)
    return (($Left | ConvertTo-Json -Depth 50 -Compress) -ceq ($Right | ConvertTo-Json -Depth 50 -Compress))
}

function Assert-TaskStateAllowedDelta {
    param([System.Collections.IDictionary]$Before,[System.Collections.IDictionary]$After,[string[]]$Allowed,[string]$Operation)
    $keys = @((@($Before.Keys) + @($After.Keys)) | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    foreach ($key in $keys) {
        if ($Allowed -ccontains $key) { continue }
        $beforeValue = if ($Before.Contains($key)) { $Before[$key] } else { $null }
        $afterValue = if ($After.Contains($key)) { $After[$key] } else { $null }
        if (-not (Test-TaskStateValueEqual -Left $beforeValue -Right $afterValue)) {
            throw "$Operation transaction changed an unauthorized task-state field: $key"
        }
    }
}

function Get-TransactionStepClaimPath {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Step)
    $target = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path) -Label 'transaction step claim target' -AllowMissing
    $pathKey = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $target
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $pathKey = $pathKey.ToLowerInvariant() }
    $digest = Get-HarnessSha256Text -Content $pathKey
    return "$($script:RuntimeRelative)/locks/step_$($digest.Substring(7)).json"
}

function New-TransactionStepClaimDocument {
    param([string]$TransactionId,[string]$TaskId,[string]$IntentDigest,[System.Collections.IDictionary]$Step)
    return [ordered]@{
        schema_version='task-step-claim/v2'
        transaction_id=$TransactionId
        task_id=$TaskId
        intent_digest=$IntentDigest
        step_id=[string]$Step.id
        relative_path=[string]$Step.relative_path
        action=[string]$Step.action
        before_digest=$Step.before_digest
        after_digest=$Step.after_digest
    }
}

function Assert-TransactionStepClaimShape {
    param([string]$WorkspaceRoot,[string]$ClaimPath,[System.Collections.IDictionary]$Claim)
    Assert-TaskStateExactKeys -Value $Claim -Expected @('schema_version','transaction_id','task_id','intent_digest','step_id','relative_path','action','before_digest','after_digest') -Label 'transaction step claim'
    if ([string]$Claim.schema_version -cne 'task-step-claim/v2' -or
        [string]$Claim.transaction_id -cnotmatch '^txn_[0-9a-f]{32}$' -or
        [string]$Claim.task_id -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$' -or
        [string]$Claim.intent_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$Claim.step_id) -or
        [string]$Claim.action -cnotin @('write','delete') -or
        ($null -ne $Claim.before_digest -and [string]$Claim.before_digest -cnotmatch '^sha256:[0-9a-f]{64}$') -or
        ($null -ne $Claim.after_digest -and [string]$Claim.after_digest -cnotmatch '^sha256:[0-9a-f]{64}$')) {
        throw 'transaction step claim identity is invalid'
    }
    $claimStep = [ordered]@{relative_path=[string]$Claim.relative_path}
    if ((Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $claimStep) -cne $ClaimPath) { throw 'transaction step claim target binding is invalid' }
}

function Assert-TransactionStepClaimDocument {
    param([string]$WorkspaceRoot,[string]$ClaimPath,[System.Collections.IDictionary]$Claim,[string]$TransactionId,[string]$TaskId,[string]$IntentDigest,[System.Collections.IDictionary]$Step)
    Assert-TransactionStepClaimShape -WorkspaceRoot $WorkspaceRoot -ClaimPath $ClaimPath -Claim $Claim
    $actualBefore = if ($null -eq $Claim.before_digest) { $null } else { [string]$Claim.before_digest }
    $expectedBefore = if ($null -eq $Step.before_digest) { $null } else { [string]$Step.before_digest }
    $actualAfter = if ($null -eq $Claim.after_digest) { $null } else { [string]$Claim.after_digest }
    $expectedAfter = if ($null -eq $Step.after_digest) { $null } else { [string]$Step.after_digest }
    if ([string]$Claim.transaction_id -cne $TransactionId -or
        [string]$Claim.task_id -cne $TaskId -or
        [string]$Claim.intent_digest -cne $IntentDigest -or
        [string]$Claim.step_id -cne [string]$Step.id -or
        [string]$Claim.relative_path -cne [string]$Step.relative_path -or
        [string]$Claim.action -cne [string]$Step.action -or
        $actualBefore -cne $expectedBefore -or
        $actualAfter -cne $expectedAfter) {
        throw 'transaction step publication claim is held by another transaction'
    }
}

function Get-TransactionStepClaimOwnership {
    param([string]$WorkspaceRoot,[string]$TransactionId,[string]$TaskId,[string]$IntentDigest,[System.Collections.IDictionary]$Step)
    $relativePath = Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $Step
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return [pscustomobject]@{State='missing';Path=$relativePath;Document=$null} }
    $document = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim'
    Assert-TransactionStepClaimShape -WorkspaceRoot $WorkspaceRoot -ClaimPath $relativePath -Claim $document
    $actualBefore = if ($null -eq $document.before_digest) { $null } else { [string]$document.before_digest }
    $expectedBefore = if ($null -eq $Step.before_digest) { $null } else { [string]$Step.before_digest }
    $actualAfter = if ($null -eq $document.after_digest) { $null } else { [string]$document.after_digest }
    $expectedAfter = if ($null -eq $Step.after_digest) { $null } else { [string]$Step.after_digest }
    $owned = [string]$document.transaction_id -ceq $TransactionId -and
        [string]$document.task_id -ceq $TaskId -and
        [string]$document.intent_digest -ceq $IntentDigest -and
        [string]$document.step_id -ceq [string]$Step.id -and
        [string]$document.relative_path -ceq [string]$Step.relative_path -and
        [string]$document.action -ceq [string]$Step.action -and
        $actualBefore -ceq $expectedBefore -and
        $actualAfter -ceq $expectedAfter
    return [pscustomobject]@{State=$(if($owned){'own'}else{'foreign'});Path=$relativePath;Document=$document}
}

function Enter-TransactionStepClaim {
    param([string]$WorkspaceRoot,[string]$TransactionId,[string]$TaskId,[string]$IntentDigest,[System.Collections.IDictionary]$Step,[switch]$AllowExisting)
    if ($TransactionId -cnotmatch '^txn_[0-9a-f]{32}$' -or
        $TaskId -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$' -or
        $IntentDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'transaction step claim requires valid transaction intent'
    }
    [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/locks" -Label 'task-state locks')
    $relativePath = Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $Step
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim' -AllowMissing
    $document = New-TransactionStepClaimDocument -TransactionId $TransactionId -TaskId $TaskId -IntentDigest $IntentDigest -Step $Step
    $content = ConvertTo-HarnessJsonText -Value $document
    $digest = Get-HarnessSha256Text -Content $content
    $temporaryPath = Join-Path ([System.IO.Path]::GetDirectoryName($fullPath)) ('.step-claim.{0}.{1}.tmp' -f $PID,[guid]::NewGuid().ToString('N'))
    $created = $false
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($content)
        $stream = [System.IO.FileStream]::new($temporaryPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,4096,[System.IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
        try {
            [System.IO.File]::Move($temporaryPath,$fullPath)
            $created = $true
        } catch [System.IO.IOException] {
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw }
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    }
    if (-not $created) {
        $existing = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim'
        Assert-TransactionStepClaimDocument -WorkspaceRoot $WorkspaceRoot -ClaimPath $relativePath -Claim $existing -TransactionId $TransactionId -TaskId $TaskId -IntentDigest $IntentDigest -Step $Step
        $existingDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $relativePath
        if ($existingDigest -cne $digest) { throw 'transaction step claim content is invalid' }
        if (-not $AllowExisting) { throw 'transaction step claim already exists; replay is required' }
    }
    return [pscustomobject]@{Path=$relativePath;Digest=$digest;Created=$created}
}

function Remove-TransactionStepClaim {
    param(
        [string]$WorkspaceRoot,
        [string]$TransactionId,
        [string]$TaskId,
        [string]$IntentDigest,
        [System.Collections.IDictionary]$Step,
        [pscustomobject]$Claim,
        [switch]$AllowMissing
    )
    $relativePath = if ($null -ne $Claim) { [string]$Claim.Path } else { Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $Step }
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) {
        if ($AllowMissing) { return }
        throw 'transaction step claim disappeared before journal completion'
    }
    $document = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Label 'transaction step claim'
    Assert-TransactionStepClaimDocument -WorkspaceRoot $WorkspaceRoot -ClaimPath $relativePath -Claim $document -TransactionId $TransactionId -TaskId $TaskId -IntentDigest $IntentDigest -Step $Step
    $digest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $relativePath
    if ($null -ne $Claim -and $digest -cne [string]$Claim.Digest) { throw 'transaction step claim digest changed' }
    [void](& $script:AtomicWriteModule {
        param($Root,$Path,$Expected)
        Remove-HarnessFileIfDigestAtomic -WorkspaceRoot $Root -Path $Path -ExpectedDigest $Expected
    } $WorkspaceRoot $relativePath $digest)
}

function Assert-TransactionStepPostcondition {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Step)
    $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path)
    if ([string]$Step.action -ceq 'write') {
        if ($current -cne [string]$Step.after_digest) { throw "completed transaction write postcondition changed: $($Step.relative_path)" }
        return
    }
    if ($null -ne $current) { throw "completed transaction delete postcondition changed: $($Step.relative_path)" }
}

function Assert-TransactionJournal {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Journal)
    Assert-TaskStateExactKeys -Value $Journal -Expected @('transaction_id','operation','task_id','expected_version','workspace_identity','operation_context','intent_digest','status','completed_steps','failed_step','error','replay_command','created_at','steps') -Label 'transaction journal'
    if ([string]$Journal.transaction_id -cnotmatch '^txn_[0-9a-f]{32}$' -or
        [string]$Journal.task_id -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$' -or
        [string]$Journal.operation -cnotin @('create','transition','verify','approve','resume') -or
        [string]$Journal.status -cnotin @('prepared','applying','failed','committed','recovered')) {
        throw 'transaction journal identity, operation, or status is invalid'
    }
    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if ([string]$Journal.workspace_identity -cne (Get-TaskStateWorkspaceIdentity -WorkspaceRoot $workspace)) { throw 'transaction journal workspace identity is invalid' }
    [void](Get-TaskReplayCommandWorkspace -WorkspaceRoot $WorkspaceRoot -TransactionId ([string]$Journal.transaction_id) -ReplayCommand ([string]$Journal.replay_command) -Label 'transaction journal')
    $createdAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Journal.created_at,[ref]$createdAt)) { throw 'transaction journal created_at is invalid' }
    $operation = [string]$Journal.operation
    if ($Journal.operation_context -isnot [System.Collections.IDictionary]) { throw 'transaction operation_context must be an object' }
    $contextKeys = switch ($operation) {
        'approve' { @('approval_input_path','pointer_action') }
        'verify' { @('evidence_input_path','pointer_action') }
        default { @('pointer_action') }
    }
    Assert-TaskStateExactKeys -Value $Journal.operation_context -Expected $contextKeys -Label 'transaction operation_context'
    foreach ($contextKey in @($contextKeys | Where-Object { $_ -cne 'pointer_action' })) {
        $contextPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$Journal.operation_context[$contextKey]) -Label "transaction $contextKey" -AllowMissing
        if ((Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $contextPath) -cne [string]$Journal.operation_context[$contextKey]) {
            throw "transaction $contextKey is not normalized"
        }
    }
    if ($operation -ceq 'create') {
        if ($null -ne $Journal.expected_version) { throw 'create transaction expected_version must be null' }
        $targetVersion = [int64]1
    } else {
        if (-not (Test-TaskStateIntegerValue -Value $Journal.expected_version) -or
            [int64]$Journal.expected_version -lt 1 -or
            [int64]$Journal.expected_version -ge [int]::MaxValue) {
            throw 'transaction expected_version must be a positive integer'
        }
        $targetVersion = [int64]$Journal.expected_version + 1
    }
    if (@($Journal.steps).Count -lt 2 -or @($Journal.steps).Count -gt 4) { throw 'transaction journal has an invalid step count' }
    $stepIds = [System.Collections.Generic.List[string]]::new()
    $targetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $stepsById = [ordered]@{}
    $normalizedById = [ordered]@{}
    $contentById = [ordered]@{}
    $allowedPaths = @(
        "$($script:RuntimeRelative)/current.json",
        "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/task.json",
        "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/events.jsonl",
        "docs/tasks/$($Journal.task_id)/plan.md",
        "docs/tasks/$($Journal.task_id)/evidence.json"
    )
    foreach ($step in @($Journal.steps)) {
        Assert-TaskStateExactKeys -Value $step -Expected @('id','relative_path','action','before_digest','before_content_base64','after_digest','content_base64') -Label 'transaction step'
        if ([string]::IsNullOrWhiteSpace([string]$step.id) -or $stepIds.Contains([string]$step.id)) { throw 'transaction step id is missing or duplicated' }
        $stepIds.Add([string]$step.id)
        $stepsById[[string]$step.id] = $step
        $resolved = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$step.relative_path) -Label 'transaction step' -AllowMissing
        $normalized = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $resolved
        $normalizedById[[string]$step.id] = $normalized
        if (-not $targetPaths.Add($normalized)) { throw 'transaction journal contains a duplicate target path' }
        $isApprovalPath=$normalized-cmatch("^\.assistant/runtime/tasks/"+[regex]::Escape([string]$Journal.task_id)+"/approvals/apr_[A-Za-z0-9._-]+\.json$")
        if (($allowedPaths -cnotcontains $normalized -and -not $isApprovalPath) -or [string]$step.action -cnotin @('write','delete')) { throw 'transaction step path or action is invalid' }
        if ($null -ne $step.before_digest -and [string]$step.before_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'transaction step preimage digest is invalid' }
        if ([string]$step.action -ceq 'write') {
            $content = Get-TransactionStepContent -Step $step -Label 'transaction step content'
            $contentById[[string]$step.id] = $content
            if ([string]$step.after_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$step.after_digest -cne (Get-HarnessSha256Text -Content $content)) { throw 'transaction step content digest is invalid' }
        } elseif ($normalized -cne "$($script:RuntimeRelative)/current.json" -or [string]$step.before_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or $null -ne $step.after_digest -or $null -ne $step.content_base64) { throw 'delete transaction step is invalid' }
        $requiresEmbeddedPreimage = ([string]$step.id -ceq 'task-state' -and $operation -cne 'create') -or
            ([string]$step.id -ceq 'current-pointer' -and $null -ne $step.before_digest)
        if ($requiresEmbeddedPreimage) {
            $beforeContent = Get-TransactionStepBeforeContent -Step $step -Label "transaction $($step.id) preimage"
            if ($null -eq $beforeContent -or [string]$step.before_digest -cne (Get-HarnessSha256Text -Content $beforeContent)) { throw "transaction $($step.id) preimage digest is invalid" }
        } elseif ($null -ne $step.before_content_base64) {
            throw 'transaction step has an unexpected embedded preimage'
        }
    }
    $stepSignature = @($stepIds) -join ','
    $validSignatures = switch ($operation) {
        'create' { @('task-state,event-log','task-state,event-log,governed-plan','task-state,event-log,current-pointer','task-state,event-log,governed-plan,current-pointer') }
        'transition' { @('task-state,event-log','task-state,event-log,current-pointer') }
        'resume' { @('task-state,event-log,current-pointer') }
        'approve' { @('approval,task-state,event-log','approval,task-state,event-log,current-pointer') }
        'verify' { @('evidence,task-state,event-log','evidence,task-state,event-log,current-pointer') }
    }
    if ($validSignatures -cnotcontains $stepSignature) { throw 'transaction operation step contract is invalid' }
    foreach ($id in @($stepIds)) {
        $step = $stepsById[$id]
        $expectedPath = switch ($id) {
            'task-state' { "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/task.json" }
            'event-log' { "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/events.jsonl" }
            'governed-plan' { "docs/tasks/$($Journal.task_id)/plan.md" }
            'evidence' { "docs/tasks/$($Journal.task_id)/evidence.json" }
            'current-pointer' { "$($script:RuntimeRelative)/current.json" }
            'approval' { $null }
            default { throw 'transaction operation step contract is invalid' }
        }
        if ($id -ceq 'approval') {
            if ([string]$normalizedById[$id] -cnotmatch ("^\.assistant/runtime/tasks/"+[regex]::Escape([string]$Journal.task_id)+"/approvals/apr_[A-Za-z0-9._-]+\.json$")) { throw 'transaction operation step path is invalid' }
        } elseif ([string]$normalizedById[$id] -cne $expectedPath) {
            throw 'transaction operation step path is invalid'
        }
        if ($id -cne 'current-pointer' -and [string]$step.action -cne 'write') { throw 'transaction operation step action is invalid' }
        if ($id -ceq 'current-pointer' -and [string]$step.action -ceq 'delete' -and $operation -cnotin @('transition','verify')) { throw 'transaction operation step action is invalid' }
    }
    $taskDocument = ConvertFrom-TransactionStepJson -Step $stepsById['task-state'] -Label 'transaction task-state payload'
    $schemaRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Test-TaskStateSchema -Value $taskDocument -SchemaPath (Join-Path $schemaRoot 'schemas\task-state.schema.json') -Label 'transaction task-state payload'
    Assert-TaskStateDocument -RepoRoot $schemaRoot -Task $taskDocument
    if ([string]$taskDocument.schema_version -cne 'task-state/v2' -or
        [string]$taskDocument.task_id -cne [string]$Journal.task_id -or
        -not (Test-TaskStateIntegerValue -Value $taskDocument.version) -or
        [int64]$taskDocument.version -ne $targetVersion) {
        throw 'transaction task-state payload does not match its task intent'
    }
    $beforeTaskDocument = $null
    if ($operation -ceq 'create') {
        $taskStep = $stepsById['task-state']
        $selectedCapabilities = @()
        if ([string]$taskDocument.execution_profile -ceq 'governed') {
            $selectedCapabilities = @(@('plan_required','approval_required','rollback_required','independent_review_required') | Where-Object { [bool]$taskDocument.policies[$_] })
        }
        $expectedPolicies = Get-TaskPolicyFlags -RepoRoot $schemaRoot -Profile ([string]$taskDocument.execution_profile) -Capabilities $selectedCapabilities
        if ($null -ne $taskStep.before_digest -or
            $null -ne $taskStep.before_content_base64 -or
            [string]$taskDocument.identity -cne 'new' -or
            [string]$taskDocument.intent -cne 'write' -or
            [string]$taskDocument.persistence -cne 'durable' -or
            [string]$taskDocument.execution_profile -cnotin @('governed','critical') -or
            [string]$taskDocument.requirement_state -cne 'clear' -or
            [string]$taskDocument.status -cne 'ready' -or
            $null -ne $taskDocument.block_reason -or
            [string]::IsNullOrWhiteSpace([string]$taskDocument.contract_path) -or
            [string]$taskDocument.contract_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            @($taskDocument.approvals).Count -ne 0 -or
            $null -ne $taskDocument.evidence_path -or
            -not (Test-TaskStateValueEqual -Left $taskDocument.policies -Right $expectedPolicies)) {
            throw 'create transaction task-state payload is not canonical'
        }
        foreach ($step in @($Journal.steps)) {
            if ($null -ne $step.before_digest) { throw 'create transaction targets must not already exist' }
        }
    } else {
        $beforeTaskDocument = ConvertFrom-TransactionStepBeforeJson -Step $stepsById['task-state'] -Label 'transaction task-state preimage'
        Test-TaskStateSchema -Value $beforeTaskDocument -SchemaPath (Join-Path $schemaRoot 'schemas\task-state.schema.json') -Label 'transaction task-state preimage'
        Assert-TaskStateDocument -RepoRoot $schemaRoot -Task $beforeTaskDocument
        if ([string]$beforeTaskDocument.task_id -cne [string]$Journal.task_id -or
            -not (Test-TaskStateIntegerValue -Value $beforeTaskDocument.version) -or
            [int64]$beforeTaskDocument.version -ne [int64]$Journal.expected_version) {
            throw 'transaction task-state preimage does not match its task intent'
        }
    }
    $eventContent = [string]$contentById['event-log']
    if ($eventContent.Length -eq 0 -or -not $eventContent.EndsWith("`n",[System.StringComparison]::Ordinal)) { throw 'transaction event-log payload is invalid' }
    $eventLines = @($eventContent.Substring(0,$eventContent.Length-1) -split "`n")
    $previousEventVersion = [int64]0
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($rawLine in $eventLines) {
        $line = $rawLine.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line)) { throw 'transaction event-log payload is invalid' }
        try { $event = $line | ConvertFrom-HarnessJson -ErrorAction Stop } catch { throw 'transaction event-log payload is not valid JSONL' }
        Test-TaskStateSchema -Value $event -SchemaPath (Join-Path $schemaRoot 'schemas\event.schema.json') -Label 'transaction event payload'
        if ($event -isnot [System.Collections.IDictionary] -or
            [string]$event.schema_version -cne 'event/v1' -or
            [string]$event.task_id -cne [string]$Journal.task_id -or
            -not (Test-TaskStateIntegerValue -Value $event.task_version) -or
            [int64]$event.task_version -lt 1 -or
            [int64]$event.task_version -lt $previousEventVersion -or
            [int64]$event.task_version -gt $targetVersion) {
            throw 'transaction event-log payload does not match its task intent'
        }
        $previousEventVersion = [int64]$event.task_version
        $events.Add($event)
    }
    if ($previousEventVersion -ne $targetVersion) { throw 'transaction event-log payload does not reach its target version' }
    if ($stepsById.Contains('approval')) {
        $approvalDocument = ConvertFrom-TransactionStepJson -Step $stepsById['approval'] -Label 'transaction Approval payload'
        Test-TaskStateSchema -Value $approvalDocument -SchemaPath (Join-Path $schemaRoot 'schemas\approval.schema.json') -Label 'transaction Approval payload'
        if ([string]$approvalDocument.schema_version -cne 'approval/v1' -or
            [string]$approvalDocument.task_id -cne [string]$Journal.task_id -or
            -not (Test-TaskStateIntegerValue -Value $approvalDocument.task_version) -or
            [int64]$approvalDocument.task_version -ne $targetVersion) {
            throw 'transaction Approval payload does not match its task intent'
        }
    }
    if ($stepsById.Contains('evidence')) {
        $evidenceDocument = ConvertFrom-TransactionStepJson -Step $stepsById['evidence'] -Label 'transaction Evidence payload'
        Test-TaskStateSchema -Value $evidenceDocument -SchemaPath (Join-Path $schemaRoot 'schemas\evidence.schema.json') -Label 'transaction Evidence payload'
        if ([string]$evidenceDocument.schema_version -cne 'evidence/v1' -or
            [string]$evidenceDocument.task_id -cne [string]$Journal.task_id -or
            -not (Test-TaskStateIntegerValue -Value $evidenceDocument.task_version) -or
            [int64]$evidenceDocument.task_version -ne [int64]$Journal.expected_version) {
            throw 'transaction Evidence payload does not match its task intent'
        }
    }
    $pointerBeforeDocument = $null
    $pointerDocument = $null
    if ($stepsById.Contains('current-pointer')) {
        $pointerStep = $stepsById['current-pointer']
        if ($null -ne $pointerStep.before_digest) {
            $pointerBeforeDocument = ConvertFrom-TransactionStepBeforeJson -Step $pointerStep -Label 'transaction current-pointer preimage'
            Test-TaskStateSchema -Value $pointerBeforeDocument -SchemaPath (Join-Path $schemaRoot 'schemas\current-pointer.schema.json') -Label 'transaction current-pointer preimage'
            if ($operation -ceq 'create' -or
                [string]$pointerBeforeDocument.task_id -cne [string]$Journal.task_id -or
                [int64]$pointerBeforeDocument.task_version -ne [int64]$Journal.expected_version) {
                throw 'transaction current-pointer preimage does not match its task intent'
            }
        } elseif ($operation -cin @('transition','approve','verify')) {
            throw 'transaction current-pointer preimage is missing'
        }
        if ([string]$pointerStep.action -ceq 'write') {
            $pointerDocument = ConvertFrom-TransactionStepJson -Step $pointerStep -Label 'transaction current-pointer payload'
            Test-TaskStateSchema -Value $pointerDocument -SchemaPath (Join-Path $schemaRoot 'schemas\current-pointer.schema.json') -Label 'transaction current-pointer payload'
            if ([string]$pointerDocument.schema_version -cne 'current-pointer/v1' -or
                [string]$pointerDocument.task_id -cne [string]$Journal.task_id -or
                -not (Test-TaskStateIntegerValue -Value $pointerDocument.task_version) -or
                [int64]$pointerDocument.task_version -ne $targetVersion -or
                [string]$taskDocument.status -cin @('done','cancelled')) {
                throw 'transaction current-pointer payload does not match its task intent'
            }
        } elseif ([string]$taskDocument.status -cnotin @('done','cancelled')) {
            throw 'transaction current-pointer delete does not match a terminal task intent'
        }
    }
    $pointerActionIntent = [string]$Journal.operation_context.pointer_action
    $hasPointerStep = $stepsById.Contains('current-pointer')
    $isPointerWrite = $hasPointerStep -and [string]$stepsById['current-pointer'].action -ceq 'write'
    $isPointerDelete = $hasPointerStep -and [string]$stepsById['current-pointer'].action -ceq 'delete'
    $hasPointerPreimage = $hasPointerStep -and $null -ne $stepsById['current-pointer'].before_digest
    $validPointerIntent = switch ($operation) {
        'create' {
            ($pointerActionIntent -ceq 'unchanged' -and -not $hasPointerStep) -or
            ($pointerActionIntent -ceq 'activated' -and $isPointerWrite -and -not $hasPointerPreimage)
        }
        'transition' {
            ($pointerActionIntent -ceq 'unchanged' -and -not $hasPointerStep) -or
            ($pointerActionIntent -ceq 'updated' -and $isPointerWrite -and $hasPointerPreimage) -or
            ($pointerActionIntent -ceq 'cleared' -and $isPointerDelete -and $hasPointerPreimage)
        }
        'resume' {
            ($pointerActionIntent -ceq 'activated' -and $isPointerWrite -and -not $hasPointerPreimage) -or
            ($pointerActionIntent -ceq 'updated' -and $isPointerWrite -and $hasPointerPreimage)
        }
        'approve' {
            ($pointerActionIntent -ceq 'unchanged' -and -not $hasPointerStep) -or
            ($pointerActionIntent -ceq 'updated' -and $isPointerWrite -and $hasPointerPreimage)
        }
        'verify' {
            ($pointerActionIntent -ceq 'unchanged' -and -not $hasPointerStep) -or
            ($pointerActionIntent -ceq 'updated' -and $isPointerWrite -and $hasPointerPreimage) -or
            ($pointerActionIntent -ceq 'cleared' -and $isPointerDelete -and $hasPointerPreimage)
        }
    }
    if (-not $validPointerIntent) { throw 'transaction pointer_action does not match its current-pointer step' }
    if ($pointerActionIntent -ceq 'updated' -and
        $operation -cin @('transition','approve','verify') -and
        [string]$pointerDocument.activated_at -cne [string]$pointerBeforeDocument.activated_at) {
        throw 'transaction current-pointer activation identity changed'
    }
    $targetEvents = @($events | Where-Object { [int64]$_.task_version -eq $targetVersion })
    $eventPrefixCount = $eventLines.Count - $targetEvents.Count
    if ($eventPrefixCount -lt 0) { throw 'transaction event-log suffix is invalid' }
    $eventPrefix = if ($eventPrefixCount -eq 0) { '' } else { (@($eventLines[0..($eventPrefixCount-1)]) -join "`n") + "`n" }
    $eventPrefixDigest = if ($eventPrefixCount -eq 0) { $null } else { Get-HarnessSha256Text -Content $eventPrefix }
    $recordedEventBeforeDigest = if ($null -eq $stepsById['event-log'].before_digest) { $null } else { [string]$stepsById['event-log'].before_digest }
    if ($recordedEventBeforeDigest -cne $eventPrefixDigest) { throw 'transaction event-log payload does not preserve its exact preimage prefix' }
    if ($operation -ceq 'create') {
        $hasGovernedPlan = $stepsById.Contains('governed-plan')
        if ([string]$taskDocument.status -cne 'ready' -or
            $targetEvents.Count -ne 1 -or
            [string]$targetEvents[0].type -cne 'task.created' -or
            [string]$targetEvents[0].payload.profile -cne [string]$taskDocument.execution_profile -or
            [string]$targetEvents[0].payload.contract_digest -cne [string]$taskDocument.contract_digest -or
            [bool]$taskDocument.policies.plan_required -ne $hasGovernedPlan) {
            throw 'create transaction payload intent is invalid'
        }
        if ($hasGovernedPlan) {
            $planContent = [string]$contentById['governed-plan']
            $taskBinding = [regex]::Matches($planContent,"(?m)^- task_id:\s*$([regex]::Escape([string]$Journal.task_id))\s*$")
            $digestBinding = [regex]::Matches($planContent,"(?m)^- contract_digest:\s*$([regex]::Escape([string]$taskDocument.contract_digest))\s*$")
            if ($taskBinding.Count -ne 1 -or $digestBinding.Count -ne 1) { throw 'create governed-plan payload does not match its task intent' }
        }
    } elseif ($operation -ceq 'transition') {
        if ($targetEvents.Count -ne 1 -or [string]$taskDocument.status -ceq 'done') { throw 'transition transaction event suffix is invalid' }
        $transitionEvent = $targetEvents[0]
        $from = [string]$transitionEvent.payload.from
        $to = [string]$transitionEvent.payload.to
        $allowedTaskChanges = @('version','status','requirement_state','block_reason','updated_at')
        if ($from -ceq 'blocked' -and $to -ceq 'ready') { $allowedTaskChanges += @('contract_path','contract_digest') }
        Assert-TaskStateAllowedDelta -Before $beforeTaskDocument -After $taskDocument -Allowed $allowedTaskChanges -Operation 'transition'
        if ($to -cne [string]$taskDocument.status -or
            [string]$beforeTaskDocument.status -cne $from -or
            -not $script:Transitions.Contains($from) -or
            @($script:Transitions[$from]) -cnotcontains $to -or
            [string]$transitionEvent.type -cne (Get-TransitionEventType -From $from -To $to)) {
            throw 'transition transaction payload intent is invalid'
        }
        if ($from -ceq 'blocked' -and $to -ceq 'ready' -and
            ([string]$taskDocument.contract_digest -ceq [string]$beforeTaskDocument.contract_digest -or
            [string]$taskDocument.requirement_state -cne 'clear' -or
            $null -ne $taskDocument.block_reason)) {
            throw 'transition revised Requirement intent is invalid'
        }
        if ($stepsById.Contains('current-pointer') -and
            [string]$stepsById['current-pointer'].action -ceq 'delete' -and
            [string]$taskDocument.status -cne 'cancelled') {
            throw 'transition current-pointer delete requires a cancelled task'
        }
    } elseif ($operation -ceq 'resume') {
        Assert-TaskStateAllowedDelta -Before $beforeTaskDocument -After $taskDocument -Allowed @('version','status','updated_at') -Operation 'resume'
        if ($targetEvents.Count -ne 1 -or
            [string]$taskDocument.status -cne 'running' -or
            [string]$beforeTaskDocument.status -cne [string]$targetEvents[0].payload.from -or
            [string]$targetEvents[0].type -cne 'execution.started' -or
            [string]$targetEvents[0].payload.source -cne 'resume-and-execute' -or
            [string]$targetEvents[0].payload.to -cne 'running' -or
            [string]$targetEvents[0].payload.from -cnotin @('ready','running','paused','failed')) {
            throw 'resume transaction payload intent is invalid'
        }
    } elseif ($operation -ceq 'approve') {
        Assert-TaskStateAllowedDelta -Before $beforeTaskDocument -After $taskDocument -Allowed @('version','approvals','updated_at') -Operation 'approve'
        if ($targetEvents.Count -ne 1 -or [string]$targetEvents[0].type -cne 'approval.granted') { throw 'approve transaction event suffix is invalid' }
        $approvalId = [string]$approvalDocument.approval_id
        $approvalPath = [string]$normalizedById['approval']
        $approvalEvent = $targetEvents[0]
        $expectedApprovals = @(@($beforeTaskDocument.approvals) + @($approvalId))
        $approvedAt = [datetimeoffset]::MinValue
        $expiresAt = [datetimeoffset]::MaxValue
        $approvedAtValid = [datetimeoffset]::TryParse([string]$approvalDocument.approved_at,[ref]$approvedAt)
        $expiresAtValid = $null -eq $approvalDocument.expires_at -or [datetimeoffset]::TryParse([string]$approvalDocument.expires_at,[ref]$expiresAt)
        if ($null -ne $stepsById['approval'].before_digest -or
            -not [bool]$beforeTaskDocument.policies.approval_required -or
            [string]$beforeTaskDocument.requirement_state -cne 'clear' -or
            [string]$beforeTaskDocument.status -cin @('done','cancelled') -or
            -not $approvedAtValid -or $approvedAt -gt $createdAt -or
            -not $expiresAtValid -or ($null -ne $approvalDocument.expires_at -and $expiresAt -le $createdAt) -or
            [System.IO.Path]::GetFileName($approvalPath) -cne "$approvalId.json" -or
            -not (Test-TaskStateValueEqual -Left @($taskDocument.approvals) -Right $expectedApprovals) -or
            [string]$approvalDocument.contract_digest -cne [string]$taskDocument.contract_digest -or
            [string]$approvalDocument.status -cne 'granted' -or
            [string]$approvalEvent.payload.approval_id -cne $approvalId -or
            [string]$approvalEvent.payload.approval_type -cne [string]$approvalDocument.approval_type -or
            [string]$approvalEvent.payload.approval_path -cne $approvalPath -or
            [string]$approvalEvent.payload.digest -cne [string]$stepsById['approval'].after_digest) {
            throw 'approve transaction payload intent is invalid'
        }
    } elseif ($operation -ceq 'verify') {
        Assert-TaskStateAllowedDelta -Before $beforeTaskDocument -After $taskDocument -Allowed @('version','status','evidence_path','updated_at') -Operation 'verify'
        $statusByConclusion = @{pass='done';fail='running';blocked='paused';partial='verifying'}
        $conclusion = [string]$evidenceDocument.conclusion
        $expectedStatus = [string]$statusByConclusion[$conclusion]
        $expectedEventCount = if ($conclusion -ceq 'partial') { 1 } else { 2 }
        if ([string]::IsNullOrWhiteSpace($expectedStatus) -or
            [string]$beforeTaskDocument.status -cne 'verifying' -or
            [string]$taskDocument.status -cne $expectedStatus -or
            [string]$taskDocument.evidence_path -cne [string]$normalizedById['evidence'] -or
            [string]$evidenceDocument.contract_digest -cne [string]$taskDocument.contract_digest -or
            $targetEvents.Count -ne $expectedEventCount) {
            throw 'verify transaction payload intent is invalid'
        }
        $recordedEvent = $targetEvents[0]
        if ([string]$recordedEvent.type -cne 'verification.recorded' -or
            [string]$recordedEvent.payload.evidence_path -cne [string]$normalizedById['evidence'] -or
            [string]$recordedEvent.payload.digest -cne [string]$stepsById['evidence'].after_digest -or
            [string]$recordedEvent.payload.conclusion -cne $conclusion -or
            [string]$recordedEvent.payload.from -cne 'verifying' -or
            [string]$recordedEvent.payload.to -cne $expectedStatus) {
            throw 'verify transaction recorded event does not match its Evidence'
        }
        if ($expectedEventCount -eq 2) {
            $lifecycleEvent = $targetEvents[1]
            if ([string]$lifecycleEvent.type -cne (Get-TransitionEventType -From 'verifying' -To $expectedStatus) -or
                [string]$lifecycleEvent.payload.source -cne 'evidence' -or
                [string]$lifecycleEvent.payload.conclusion -cne $conclusion) {
                throw 'verify transaction lifecycle event does not match its Evidence'
            }
        }
        if ($stepsById.Contains('current-pointer')) {
            $pointerAction = [string]$stepsById['current-pointer'].action
            if (($expectedStatus -ceq 'done' -and $pointerAction -cne 'delete') -or
                ($expectedStatus -cne 'done' -and $pointerAction -cne 'write')) {
                throw 'verify current-pointer action does not match its Evidence'
            }
        }
    }
    if ([string]$Journal.intent_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or
        [string]$Journal.intent_digest -cne (Get-TransactionIntentDigest -Journal $Journal)) {
        throw 'transaction journal intent digest is invalid'
    }
    $completedIds = @($Journal.completed_steps | ForEach-Object { [string]$_ })
    if ($completedIds.Count -gt $stepIds.Count) { throw 'transaction journal completed_steps must be an ordered prefix' }
    for ($index=0;$index -lt $completedIds.Count;$index++) {
        if ($completedIds[$index] -cne $stepIds[$index]) { throw 'transaction journal completed_steps must be an ordered prefix' }
    }
    $expectedFailedStep = if ($completedIds.Count -lt $stepIds.Count) { $stepIds[$completedIds.Count] } else { 'cleanup' }
    $status = [string]$Journal.status
    $failedStep = [string]$Journal.failed_step
    $errorText = [string]$Journal.error
    if ($status -ceq 'prepared') {
        if ($completedIds.Count -ne 0 -or $failedStep -cne $expectedFailedStep -or -not [string]::IsNullOrEmpty($errorText)) { throw 'prepared transaction journal progress is invalid' }
    } elseif ($status -ceq 'applying') {
        if ($completedIds.Count -eq 0 -or $failedStep -cne $expectedFailedStep -or -not [string]::IsNullOrEmpty($errorText)) { throw 'applying transaction journal progress is invalid' }
    } elseif ($status -ceq 'failed') {
        if ($failedStep -cne $expectedFailedStep -or [string]::IsNullOrWhiteSpace($errorText)) { throw 'failed transaction journal progress is invalid' }
    } elseif ($completedIds.Count -ne $stepIds.Count -or $failedStep -cne '' -or -not [string]::IsNullOrEmpty($errorText)) {
        throw 'completed transaction journal progress is invalid'
    }
}

function Get-LegacyTransactionIntentDigest {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Journal)
    $steps = @($Journal.steps | ForEach-Object {
        [ordered]@{
            id=[string]$_.id
            relative_path=[string]$_.relative_path
            action=[string]$_.action
            before_digest=$_.before_digest
            after_digest=$_.after_digest
            content_base64=$_.content_base64
        }
    })
    $intent = [ordered]@{
        format='task-transaction/legacy-v1'
        workspace_identity=(Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot)
        transaction_id=[string]$Journal.transaction_id
        operation=[string]$Journal.operation
        task_id=[string]$Journal.task_id
        expected_version=$Journal.expected_version
        replay_command=[string]$Journal.replay_command
        created_at=[string]$Journal.created_at
        steps=$steps
    }
    return Get-HarnessSha256Text -Content (ConvertTo-HarnessJsonText -Value $intent)
}

function Assert-LegacyTransactionJournal {
    param(
        [string]$WorkspaceRoot,
        [System.Collections.IDictionary]$Journal,
        [ValidateSet('pending','archive')][string]$Location
    )
    if ((Get-TransactionJournalFormat -Journal $Journal) -cne 'legacy') { throw 'transaction journal is not an exact legacy journal' }
    if ([string]$Journal.transaction_id -cnotmatch '^txn_[0-9a-f]{32}$' -or
        [string]$Journal.task_id -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$' -or
        [string]$Journal.operation -cnotin @('create','transition','verify','approve','resume') -or
        [string]$Journal.status -cnotin @('prepared','applying','failed','recovered')) {
        throw 'legacy transaction journal identity, operation, or status is invalid'
    }
    if ($Location -ceq 'archive' -and [string]$Journal.status -cne 'recovered') {
        throw 'legacy transaction archive status is invalid'
    }
    $createdAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Journal.created_at,[ref]$createdAt)) { throw 'legacy transaction journal created_at is invalid' }
    $operation = [string]$Journal.operation
    if ($operation -ceq 'create') {
        if ($null -ne $Journal.expected_version) { throw 'legacy create transaction expected_version must be null' }
        $targetVersion = [int64]1
    } else {
        if (-not (Test-TaskStateIntegerValue -Value $Journal.expected_version) -or
            [int64]$Journal.expected_version -lt 1 -or
            [int64]$Journal.expected_version -ge [int]::MaxValue) {
            throw 'legacy transaction expected_version must be a positive integer'
        }
        $targetVersion = [int64]$Journal.expected_version + 1
    }
    [void](Get-TaskReplayCommandWorkspace -WorkspaceRoot $WorkspaceRoot -TransactionId ([string]$Journal.transaction_id) -ReplayCommand ([string]$Journal.replay_command) -Label 'legacy transaction journal')
    if (@($Journal.steps).Count -lt 2 -or @($Journal.steps).Count -gt 4) { throw 'legacy transaction journal has an invalid step count' }

    $stepIds = [System.Collections.Generic.List[string]]::new()
    $targetPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $stepsById = [ordered]@{}
    $normalizedById = [ordered]@{}
    $contentById = [ordered]@{}
    $allowedPaths = @(
        "$($script:RuntimeRelative)/current.json",
        "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/task.json",
        "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/events.jsonl",
        "docs/tasks/$($Journal.task_id)/plan.md",
        "docs/tasks/$($Journal.task_id)/evidence.json"
    )
    foreach ($step in @($Journal.steps)) {
        $id = [string]$step.id
        if ([string]::IsNullOrWhiteSpace($id) -or $stepIds.Contains($id)) { throw 'legacy transaction step id is missing or duplicated' }
        $stepIds.Add($id);$stepsById[$id]=$step
        $resolved = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$step.relative_path) -Label 'legacy transaction step' -AllowMissing
        $normalized = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $resolved
        $normalizedById[$id]=$normalized
        if (-not $targetPaths.Add($normalized)) { throw 'legacy transaction journal contains a duplicate target path' }
        $isApprovalPath = $normalized -cmatch ("^\.assistant/runtime/tasks/" + [regex]::Escape([string]$Journal.task_id) + "/approvals/apr_[A-Za-z0-9._-]+\.json$")
        if (($allowedPaths -cnotcontains $normalized -and -not $isApprovalPath) -or [string]$step.action -cnotin @('write','delete')) { throw 'legacy transaction step path or action is invalid' }
        if ($null -ne $step.before_digest -and [string]$step.before_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'legacy transaction step preimage digest is invalid' }
        if ([string]$step.action -ceq 'write') {
            $content = Get-TransactionStepContent -Step $step -Label 'legacy transaction step content'
            $contentById[$id]=$content
            if ([string]$step.after_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$step.after_digest -cne (Get-HarnessSha256Text -Content $content)) { throw 'legacy transaction step content digest is invalid' }
        } elseif ($normalized -cne "$($script:RuntimeRelative)/current.json" -or [string]$step.before_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or $null -ne $step.after_digest -or $null -ne $step.content_base64) {
            throw 'legacy delete transaction step is invalid'
        }
    }
    $signature = @($stepIds) -join ','
    $validSignatures = switch ($operation) {
        'create' { @('task-state,event-log','task-state,event-log,governed-plan','task-state,event-log,current-pointer','task-state,event-log,governed-plan,current-pointer') }
        'transition' { @('task-state,event-log','task-state,event-log,current-pointer') }
        'resume' { @('task-state,event-log,current-pointer') }
        'approve' { @('approval,task-state,event-log','approval,task-state,event-log,current-pointer') }
        'verify' { @('evidence,task-state,event-log','evidence,task-state,event-log,current-pointer') }
    }
    if ($validSignatures -cnotcontains $signature) { throw 'legacy transaction operation step contract is invalid' }
    foreach ($id in @($stepIds)) {
        $expectedPath = switch ($id) {
            'task-state' { "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/task.json" }
            'event-log' { "$($script:RuntimeRelative)/tasks/$($Journal.task_id)/events.jsonl" }
            'governed-plan' { "docs/tasks/$($Journal.task_id)/plan.md" }
            'evidence' { "docs/tasks/$($Journal.task_id)/evidence.json" }
            'current-pointer' { "$($script:RuntimeRelative)/current.json" }
            'approval' { $null }
            default { throw 'legacy transaction operation step contract is invalid' }
        }
        if ($id -ceq 'approval') {
            if ([string]$normalizedById[$id] -cnotmatch ("^\.assistant/runtime/tasks/" + [regex]::Escape([string]$Journal.task_id) + "/approvals/apr_[A-Za-z0-9._-]+\.json$")) { throw 'legacy transaction operation step path is invalid' }
        } elseif ([string]$normalizedById[$id] -cne $expectedPath) { throw 'legacy transaction operation step path is invalid' }
        if ($id -cne 'current-pointer' -and [string]$stepsById[$id].action -cne 'write') { throw 'legacy transaction operation step action is invalid' }
        if ($id -ceq 'current-pointer' -and [string]$stepsById[$id].action -ceq 'delete' -and $operation -cnotin @('transition','verify')) { throw 'legacy transaction operation step action is invalid' }
    }

    $schemaRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $taskDocument = ConvertFrom-TransactionStepJson -Step $stepsById['task-state'] -Label 'legacy transaction task-state payload'
    Test-TaskStateSchema -Value $taskDocument -SchemaPath (Join-Path $schemaRoot 'schemas\task-state.schema.json') -Label 'legacy transaction task-state payload'
    Assert-TaskStateDocument -RepoRoot $schemaRoot -Task $taskDocument
    if ([string]$taskDocument.task_id -cne [string]$Journal.task_id -or -not (Test-TaskStateIntegerValue -Value $taskDocument.version) -or [int64]$taskDocument.version -ne $targetVersion) {
        throw 'legacy transaction task-state payload does not match its task intent'
    }
    if ($operation -ceq 'create' -and $null -ne $stepsById['task-state'].before_digest) { throw 'legacy create transaction task target must not already exist' }

    $eventContent = [string]$contentById['event-log']
    if ($eventContent.Length -eq 0 -or -not $eventContent.EndsWith("`n",[System.StringComparison]::Ordinal)) { throw 'legacy transaction event-log payload is invalid' }
    $eventLines = @($eventContent.Substring(0,$eventContent.Length-1) -split "`n")
    $events = [System.Collections.Generic.List[object]]::new();$previousEventVersion=[int64]0
    foreach ($rawLine in $eventLines) {
        $line=$rawLine.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line)) { throw 'legacy transaction event-log payload is invalid' }
        try { $event=$line|ConvertFrom-HarnessJson -ErrorAction Stop } catch { throw 'legacy transaction event-log payload is not valid JSONL' }
        Test-TaskStateSchema -Value $event -SchemaPath (Join-Path $schemaRoot 'schemas\event.schema.json') -Label 'legacy transaction event payload'
        if ([string]$event.task_id -cne [string]$Journal.task_id -or -not (Test-TaskStateIntegerValue -Value $event.task_version) -or [int64]$event.task_version -lt $previousEventVersion -or [int64]$event.task_version -gt $targetVersion) { throw 'legacy transaction event-log payload does not match its task intent' }
        $previousEventVersion=[int64]$event.task_version;$events.Add($event)
    }
    if ($previousEventVersion -ne $targetVersion) { throw 'legacy transaction event-log payload does not reach its target version' }
    $targetEvents=@($events|Where-Object{[int64]$_.task_version-eq$targetVersion})
    $prefixCount=$eventLines.Count-$targetEvents.Count
    $prefix=if($prefixCount-eq0){''}else{(@($eventLines[0..($prefixCount-1)])-join"`n")+"`n"}
    $prefixDigest=if($prefixCount-eq0){$null}else{Get-HarnessSha256Text -Content $prefix}
    $recordedPrefix=if($null-eq$stepsById['event-log'].before_digest){$null}else{[string]$stepsById['event-log'].before_digest}
    if($recordedPrefix-cne$prefixDigest){throw 'legacy transaction event-log payload does not preserve its exact preimage prefix'}

    $pointerDocument=$null
    if($stepsById.Contains('current-pointer')-and[string]$stepsById['current-pointer'].action-ceq'write'){
        $pointerDocument=ConvertFrom-TransactionStepJson -Step $stepsById['current-pointer'] -Label 'legacy transaction current-pointer payload'
        Test-TaskStateSchema -Value $pointerDocument -SchemaPath (Join-Path $schemaRoot 'schemas\current-pointer.schema.json') -Label 'legacy transaction current-pointer payload'
        if([string]$pointerDocument.task_id-cne[string]$Journal.task_id-or[int64]$pointerDocument.task_version-ne$targetVersion-or[string]$taskDocument.status-cin@('done','cancelled')){throw 'legacy transaction current-pointer payload does not match its task intent'}
    }
    if($stepsById.Contains('approval')){
        $approvalStep=$stepsById['approval']
        $approvalPath=[string]$normalizedById['approval']
        $approval=ConvertFrom-TransactionStepJson -Step $approvalStep -Label 'legacy transaction Approval payload'
        Test-TaskStateSchema -Value $approval -SchemaPath (Join-Path $schemaRoot 'schemas\approval.schema.json') -Label 'legacy transaction Approval payload'
        $approvalEvents=@($targetEvents|Where-Object{[string]$_.type-ceq'approval.granted'})
        $approvedAt=[datetimeoffset]::MinValue;$expiresAt=[datetimeoffset]::MaxValue
        if($targetEvents.Count-ne1-or$approvalEvents.Count-ne1-or$null-ne$approvalStep.before_digest-or-not[bool]$taskDocument.policies.approval_required-or[string]$taskDocument.requirement_state-cne'clear'-or[string]$taskDocument.status-cin@('done','cancelled')-or[string]$approval.task_id-cne[string]$Journal.task_id-or[int64]$approval.task_version-ne$targetVersion-or[string]$approval.contract_digest-cne[string]$taskDocument.contract_digest-or[string]$approval.status-cne'granted'-or[IO.Path]::GetFileName($approvalPath)-cne"$([string]$approval.approval_id).json"-or@($taskDocument.approvals|Where-Object{[string]$_-ceq[string]$approval.approval_id}).Count-ne1-or-not[datetimeoffset]::TryParse([string]$approval.approved_at,[ref]$approvedAt)-or$approvedAt-gt$createdAt-or($null-ne$approval.expires_at-and(-not[datetimeoffset]::TryParse([string]$approval.expires_at,[ref]$expiresAt)-or$expiresAt-le$createdAt))){throw 'legacy approve transaction payload intent is invalid'}
        $approvalEvent=$approvalEvents[0]
        if([string]$approvalEvent.payload.approval_id-cne[string]$approval.approval_id-or[string]$approvalEvent.payload.approval_type-cne[string]$approval.approval_type-or[string]$approvalEvent.payload.approval_path-cne$approvalPath-or[string]$approvalEvent.payload.digest-cne[string]$approvalStep.after_digest){throw 'legacy approve transaction payload intent is invalid'}
    }
    if($stepsById.Contains('evidence')){
        $evidence=ConvertFrom-TransactionStepJson -Step $stepsById['evidence'] -Label 'legacy transaction Evidence payload'
        Test-TaskStateSchema -Value $evidence -SchemaPath (Join-Path $schemaRoot 'schemas\evidence.schema.json') -Label 'legacy transaction Evidence payload'
        $statusByConclusion=@{pass='done';fail='running';blocked='paused';partial='verifying'};$expectedStatus=[string]$statusByConclusion[[string]$evidence.conclusion]
        if([string]$evidence.task_id-cne[string]$Journal.task_id-or[int64]$evidence.task_version-ne[int64]$Journal.expected_version-or[string]$evidence.contract_digest-cne[string]$taskDocument.contract_digest-or[string]$taskDocument.evidence_path-cne[string]$normalizedById['evidence']-or[string]$taskDocument.status-cne$expectedStatus-or@($targetEvents|Where-Object{[string]$_.type-ceq'verification.recorded'}).Count-ne1){throw 'legacy verify transaction payload intent is invalid'}
    }
    if($operation-ceq'create'){
        if($targetEvents.Count-ne1-or[string]$targetEvents[0].type-cne'task.created'-or[string]$taskDocument.status-cne'ready'){throw 'legacy create transaction payload intent is invalid'}
        if($stepsById.Contains('governed-plan')){
            $plan=[string]$contentById['governed-plan']
            if([regex]::Matches($plan,"(?m)^- task_id:\s*$([regex]::Escape([string]$Journal.task_id))\s*$").Count-ne1-or[regex]::Matches($plan,"(?m)^- contract_digest:\s*$([regex]::Escape([string]$taskDocument.contract_digest))\s*$").Count-ne1){throw 'legacy create governed-plan payload does not match its task intent'}
        }
    }elseif($operation-ceq'transition'){
        if($targetEvents.Count-ne1){throw 'legacy transition transaction event suffix is invalid'}
        $from=[string]$targetEvents[0].payload.from;$to=[string]$targetEvents[0].payload.to
        if($to-cne[string]$taskDocument.status-or-not$script:Transitions.Contains($from)-or@($script:Transitions[$from])-cnotcontains$to-or[string]$targetEvents[0].type-cne(Get-TransitionEventType -From $from -To $to)){throw 'legacy transition transaction payload intent is invalid'}
    }elseif($operation-ceq'resume'){
        if($targetEvents.Count-ne1-or[string]$targetEvents[0].type-cne'execution.started'-or[string]$targetEvents[0].payload.to-cne'running'-or[string]$taskDocument.status-cne'running'){throw 'legacy resume transaction payload intent is invalid'}
    }

    $completedIds=@($Journal.completed_steps|ForEach-Object{[string]$_})
    if($completedIds.Count-gt$stepIds.Count){throw 'legacy transaction journal completed_steps must be an ordered prefix'}
    for($index=0;$index-lt$completedIds.Count;$index++){if($completedIds[$index]-cne$stepIds[$index]){throw 'legacy transaction journal completed_steps must be an ordered prefix'}}
    $expectedFailed=if($completedIds.Count-lt$stepIds.Count){$stepIds[$completedIds.Count]}else{'cleanup'}
    $status=[string]$Journal.status;$failed=[string]$Journal.failed_step;$errorText=[string]$Journal.error
    if($status-ceq'prepared'){
        if($completedIds.Count-ne0-or$failed-cne$expectedFailed-or-not[string]::IsNullOrEmpty($errorText)){throw 'legacy prepared transaction journal progress is invalid'}
    }elseif($status-ceq'applying'){
        if($completedIds.Count-eq0-or$failed-cne$expectedFailed-or-not[string]::IsNullOrEmpty($errorText)){throw 'legacy applying transaction journal progress is invalid'}
    }elseif($status-ceq'failed'){
        if($failed-cne$expectedFailed-or[string]::IsNullOrWhiteSpace($errorText)){throw 'legacy failed transaction journal progress is invalid'}
    }elseif($completedIds.Count-ne$stepIds.Count-or$failed-cne''-or-not[string]::IsNullOrEmpty($errorText)){
        throw 'legacy recovered transaction journal progress is invalid'
    }
}

function Read-TaskTransactionJournal {
    param(
        [string]$WorkspaceRoot,
        [string]$Path,
        [ValidateSet('pending','archive')][string]$Location
    )
    $journal=Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $Path -Label "transaction $Location"
    $format=Get-TransactionJournalFormat -Journal $journal
    if($format-ceq'current'){
        Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $journal
        $intent=[string]$journal.intent_digest
    }else{
        Assert-LegacyTransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $journal -Location $Location
        $intent=Get-LegacyTransactionIntentDigest -WorkspaceRoot $WorkspaceRoot -Journal $journal
    }
    $expectedId=[System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileName($Path))
    if([string]$journal.transaction_id-cne$expectedId){throw "transaction journal identity does not match its $Location filename"}
    return [pscustomobject]@{Format=$format;Journal=$journal;IntentDigest=$intent}
}

function Assert-TransactionReplayInputs {
    param(
        [string]$WorkspaceRoot,
        [System.Collections.IDictionary]$Journal,
        [switch]$UseAuthorizedSnapshot
    )
    $schemaRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $stepsById = [ordered]@{}
    foreach ($step in @($Journal.steps)) { $stepsById[[string]$step.id] = $step }
    $taskDocument = ConvertFrom-TransactionStepJson -Step $stepsById['task-state'] -Label 'transaction task-state payload'
    $operation = [string]$Journal.operation
    $replayAsOf = if ($UseAuthorizedSnapshot) {
        [datetimeoffset]::Parse([string]$Journal.created_at,[Globalization.CultureInfo]::InvariantCulture)
    } else {
        [datetimeoffset]::UtcNow
    }

    if ($operation -ceq 'create') {
        $contract = Get-RequirementContract -RepoRoot $schemaRoot -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Journal.task_id) -ContractPath ([string]$taskDocument.contract_path)
        if ([string]$contract.Digest -cne [string]$taskDocument.contract_digest) {
            throw 'create transaction Requirement Contract is stale'
        }
    } else {
        $beforeTaskDocument = ConvertFrom-TransactionStepBeforeJson -Step $stepsById['task-state'] -Label 'transaction task-state preimage'
    }

    if ($operation -ceq 'transition' -and
        [string]$beforeTaskDocument.status -ceq 'blocked' -and
        [string]$taskDocument.status -ceq 'ready') {
        $contract = Get-RequirementContract -RepoRoot $schemaRoot -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Journal.task_id) -ContractPath ([string]$taskDocument.contract_path)
        if ([string]$contract.Digest -cne [string]$taskDocument.contract_digest) {
            throw 'transition Requirement Contract is stale'
        }
    }

    if ($operation -ceq 'approve') {
        $resolvedApproval = & $script:ApprovalModule {
            param($Root,$Workspace,$Path,$Task,$Version,$Digest,$AsOf)
            Resolve-HarnessApprovalInputCore -RepoRoot $Root -WorkspaceRoot $Workspace -ApprovalPath $Path -TaskId $Task -TargetTaskVersion $Version -ContractDigest $Digest -AsOf $AsOf
        } $schemaRoot $WorkspaceRoot ([string]$Journal.operation_context.approval_input_path) ([string]$Journal.task_id) ([int64]$Journal.expected_version + 1) ([string]$beforeTaskDocument.contract_digest) $replayAsOf
        $approvalStep = $stepsById['approval']
        $approvalContent = Get-TransactionStepContent -Step $approvalStep -Label 'transaction Approval payload'
        if ([string]$resolvedApproval.OutputPath -cne [string]$approvalStep.relative_path -or
            [string]$resolvedApproval.Digest -cne [string]$approvalStep.after_digest -or
            [string]$resolvedApproval.Content -cne $approvalContent) {
            throw 'approve transaction input no longer matches its journal'
        }
    }

    if ($operation -ceq 'verify') {
        $contract = Get-RequirementContract -RepoRoot $schemaRoot -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Journal.task_id) -ContractPath ([string]$beforeTaskDocument.contract_path)
        if ([string]$contract.Digest -cne [string]$beforeTaskDocument.contract_digest) {
            throw 'verify transaction Requirement Contract is stale'
        }
        $evidenceStep = $stepsById['evidence']
        $evidenceContent = Get-TransactionStepContent -Step $evidenceStep -Label 'transaction Evidence payload'
        $journalEvidence = $evidenceContent | ConvertFrom-HarnessJson -ErrorAction Stop
        $pinnedRevision = if ($UseAuthorizedSnapshot) { [string]$journalEvidence.revision } else { '' }
        $resolvedEvidence = & $script:EvidenceModule {
            param($Root,$Workspace,$Task,$Version,$Digest,$AcceptanceCount,$Path,$PinnedRevision)
            Resolve-HarnessEvidenceCore -RepoRoot $Root -WorkspaceRoot $Workspace -TaskId $Task -TaskVersion $Version -ContractDigest $Digest -RequiredAcceptanceCount $AcceptanceCount -EvidencePath $Path -PinnedRevision $PinnedRevision
        } $schemaRoot $WorkspaceRoot ([string]$Journal.task_id) ([int64]$Journal.expected_version) ([string]$beforeTaskDocument.contract_digest) @($contract.Document.acceptance).Count ([string]$Journal.operation_context.evidence_input_path) $pinnedRevision
        if ([string]$resolvedEvidence.OutputPath -cne [string]$evidenceStep.relative_path -or
            [string]$resolvedEvidence.Digest -cne [string]$evidenceStep.after_digest -or
            [string]$resolvedEvidence.Content -cne $evidenceContent -or
            [string]$resolvedEvidence.NextStatus -cne [string]$taskDocument.status) {
            throw 'verify transaction input no longer matches its journal'
        }
        [void](Assert-HarnessGovernanceReady -RepoRoot $schemaRoot -WorkspaceRoot $WorkspaceRoot -Task $beforeTaskDocument -Evidence $resolvedEvidence)
        if ([bool]$beforeTaskDocument.policies.approval_required -and [string]$resolvedEvidence.NextStatus -ceq 'done') {
            [void](& $script:ApprovalModule {
                param($Root,$Workspace,$Task,$AsOf)
                Assert-HarnessTaskApprovalCore -RepoRoot $Root -WorkspaceRoot $Workspace -Task $Task -AsOf $AsOf
            } $schemaRoot $WorkspaceRoot $beforeTaskDocument $replayAsOf)
        }
    }

    $pointerAction = [string]$Journal.operation_context.pointer_action
    $currentPath = "$($script:RuntimeRelative)/current.json"
    $current = Read-CurrentPointer -RepoRoot $schemaRoot -WorkspaceRoot $WorkspaceRoot -Path $currentPath
    if ($pointerAction -ceq 'unchanged') {
        if ($null -ne $current -and [string]$current.task_id -ceq [string]$Journal.task_id) {
            throw 'transaction omitted the current-pointer mutation for the current task'
        }
        return
    }

    $pointerStep = $stepsById['current-pointer']
    $currentDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $currentPath
    $matchesBefore = if ($null -eq $pointerStep.before_digest) {
        $null -eq $currentDigest
    } else {
        $currentDigest -ceq [string]$pointerStep.before_digest
    }
    $matchesAfter = if ([string]$pointerStep.action -ceq 'write') {
        $currentDigest -ceq [string]$pointerStep.after_digest
    } else {
        $null -eq $currentDigest
    }
    if (-not $matchesBefore -and -not $matchesAfter) {
        throw 'transaction current-pointer no longer matches its replay boundary'
    }
}

function Invoke-TransactionStep {
    param(
        [string]$WorkspaceRoot,
        [string]$TransactionId,
        [string]$TaskId,
        [string]$IntentDigest,
        [System.Collections.IDictionary]$Step,
        [switch]$AllowExistingClaim,
        [switch]$AllowLegacyUnclaimedPostimage
    )
    $claim = Enter-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $TaskId -IntentDigest $IntentDigest -Step $Step -AllowExisting:$AllowExistingClaim
    $current = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$Step.relative_path)
    if ([string]$Step.action -ceq 'write') {
        if ($current -ceq [string]$Step.after_digest) {
            if ($claim.Created -and -not $AllowLegacyUnclaimedPostimage) {
                Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $TaskId -IntentDigest $IntentDigest -Step $Step -Claim $claim
                throw "transaction postimage exists without its publication claim: $($Step.relative_path)"
            }
            return [pscustomobject]@{Result='already-applied';Claim=$claim}
        }
        if ($current -cne $Step.before_digest) {
            if ($claim.Created) { Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $TaskId -IntentDigest $IntentDigest -Step $Step -Claim $claim }
            throw "transaction preimage changed: $($Step.relative_path)"
        }
        $bytes = [Convert]::FromBase64String([string]$Step.content_base64)
        $expectedCurrent = if ($null -eq $Step.before_digest) { 'missing' } else { [string]$Step.before_digest }
        $written = & $script:AtomicWriteModule {
            param($Root,$Bytes,$Path,$ExpectedSource,$ExpectedCurrent)
            Write-HarnessAtomicBytes -WorkspaceRoot $Root -SourceBytes $Bytes -Path $Path -ExpectedSourceDigest $ExpectedSource -ExpectedCurrentDigest $ExpectedCurrent
        } $WorkspaceRoot $bytes ([string]$Step.relative_path) ([string]$Step.after_digest) $expectedCurrent
        if ($written -cne [string]$Step.after_digest) { throw "transaction postimage mismatch: $($Step.relative_path)" }
        Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $Step
        if ([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_PUBLISH',[System.EnvironmentVariableTarget]::Process) -ceq '1') {
            throw 'injected task-state fault after publication'
        }
        return [pscustomobject]@{Result='applied';Claim=$claim}
    }
    if ($null -eq $current) {
        if ($claim.Created -and -not $AllowLegacyUnclaimedPostimage) {
            Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $TaskId -IntentDigest $IntentDigest -Step $Step -Claim $claim
            throw "transaction delete postimage exists without its publication claim: $($Step.relative_path)"
        }
        return [pscustomobject]@{Result='already-applied';Claim=$claim}
    }
    if ($current -cne [string]$Step.before_digest) {
        if ($claim.Created) { Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $TaskId -IntentDigest $IntentDigest -Step $Step -Claim $claim }
        throw "transaction delete preimage changed: $($Step.relative_path)"
    }
    [void](& $script:AtomicWriteModule {
        param($Root,$Path,$Expected)
        Remove-HarnessFileIfDigestAtomic -WorkspaceRoot $Root -Path $Path -ExpectedDigest $Expected
    } $WorkspaceRoot ([string]$Step.relative_path) ([string]$Step.before_digest))
    Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $Step
    if ([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_PUBLISH',[System.EnvironmentVariableTarget]::Process) -ceq '1') {
        throw 'injected task-state fault after publication'
    }
    return [pscustomobject]@{Result='applied';Claim=$claim}
}

function Assert-NoOverlappingPendingTransaction {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Journal)
    $root = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes' -AllowMissing
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    $candidateClaims = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($step in @($Journal.steps)) { [void]$candidateClaims.Add((Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $step)) }
    foreach ($file in Get-ChildItem -LiteralPath $root -Filter 'txn_*.json' -File) {
        $relativePath = Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $file.FullName
        $record = Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $relativePath -Location pending
        $pending = $record.Journal
        if ([string]$pending.transaction_id -ceq [string]$Journal.transaction_id) { throw 'transaction journal is already pending' }
        foreach ($step in @($pending.steps)) {
            $claimPath = Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $step
            if ($candidateClaims.Contains($claimPath)) {
                throw "transaction target is reserved by pending transaction $($pending.transaction_id): $($step.relative_path)"
            }
        }
    }
}

function Invoke-TaskStateTransaction {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Journal)
    Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $Journal
    Assert-NoOverlappingPendingTransaction -WorkspaceRoot $WorkspaceRoot -Journal $Journal
    foreach ($step in @($Journal.steps)) {
        $claimPath = Get-TransactionStepClaimPath -WorkspaceRoot $WorkspaceRoot -Step $step
        $claimFullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $claimPath -Label 'transaction step claim' -AllowMissing
        if (Test-Path -LiteralPath $claimFullPath) { throw "transaction target has a pending publication claim; replay or repair before mutation: $($step.relative_path)" }
    }
    Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
    [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes" -Label 'failed writes')
    [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/locks" -Label 'task-state locks')
    $journalPath = "$($script:RuntimeRelative)/failed-writes/$($Journal.transaction_id).json"
    $archivePath = "$($script:RuntimeRelative)/failed-writes/archive/$($Journal.transaction_id).json"
    if (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $archivePath -Label 'transaction archive' -AllowMissing)) {
        throw 'transaction archive already exists'
    }
    $completed = [System.Collections.Generic.List[string]]::new()
    $claims = [System.Collections.Generic.List[object]]::new()
    foreach ($id in @($Journal.completed_steps)) { $completed.Add([string]$id) }
    $lastDigest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $journalPath -Content (ConvertTo-HarnessJsonText -Value $Journal)
    $faultAfter = 0
    [void][int]::TryParse([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_AFTER_STEP'),[ref]$faultAfter)
    $faultBeforeClaimRelease = 0
    [void][int]::TryParse([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_BEFORE_CLAIM_RELEASE'),[ref]$faultBeforeClaimRelease)
    try {
        $preclaimReadyEventName = [System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_PRECLAIM_READY_EVENT',[System.EnvironmentVariableTarget]::Process)
        $preclaimReleaseEventName = [System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_PRECLAIM_RELEASE_EVENT',[System.EnvironmentVariableTarget]::Process)
        $hasPreclaimReadyEvent = -not [string]::IsNullOrWhiteSpace($preclaimReadyEventName)
        $hasPreclaimReleaseEvent = -not [string]::IsNullOrWhiteSpace($preclaimReleaseEventName)
        if ($hasPreclaimReadyEvent -xor $hasPreclaimReleaseEvent) {
            throw 'task-state preclaim test barrier requires both DEV_HARNESS_TEST_TASK_STATE_PRECLAIM_READY_EVENT and DEV_HARNESS_TEST_TASK_STATE_PRECLAIM_RELEASE_EVENT'
        }
        if ($hasPreclaimReadyEvent) {
            if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw 'task-state preclaim test barrier requires Windows named events' }
            $preclaimReadyEvent = $null
            $preclaimReleaseEvent = $null
            try {
                $preclaimReadyEvent = [System.Threading.EventWaitHandle]::OpenExisting($preclaimReadyEventName)
                $preclaimReleaseEvent = [System.Threading.EventWaitHandle]::OpenExisting($preclaimReleaseEventName)
                [void]$preclaimReadyEvent.Set()
                if (-not $preclaimReleaseEvent.WaitOne(30000)) { throw 'task-state preclaim test barrier release timed out after 30000 ms' }
            } finally {
                if ($null -ne $preclaimReleaseEvent) { $preclaimReleaseEvent.Dispose() }
                if ($null -ne $preclaimReadyEvent) { $preclaimReadyEvent.Dispose() }
            }
        }
        Assert-TransactionReplayInputs -WorkspaceRoot $WorkspaceRoot -Journal $Journal
        if ([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_FAIL_BEFORE_FIRST_CLAIM') -ceq '1') {
            throw 'injected task-state fault before first publication claim'
        }
        for ($index=0;$index -lt @($Journal.steps).Count;$index++) {
            $step = @($Journal.steps)[$index]
            $stepResult = Invoke-TransactionStep -WorkspaceRoot $WorkspaceRoot -TransactionId ([string]$Journal.transaction_id) -TaskId ([string]$Journal.task_id) -IntentDigest ([string]$Journal.intent_digest) -Step $step
            $claims.Add([pscustomobject]@{Step=$step;Claim=$stepResult.Claim})
            if (-not $completed.Contains([string]$step.id)) { $completed.Add([string]$step.id) }
            $Journal.status='applying';$Journal.completed_steps=@($completed);$Journal.failed_step=$(if($index+1 -lt @($Journal.steps).Count){[string]@($Journal.steps)[$index+1].id}else{'cleanup'});$Journal.error=''
            $lastDigest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $journalPath -Content (ConvertTo-HarnessJsonText -Value $Journal)
            if ($faultBeforeClaimRelease -gt 0 -and $completed.Count -eq $faultBeforeClaimRelease) { throw "injected task-state fault before claim release after step $faultBeforeClaimRelease" }
            if ($faultAfter -gt 0 -and $completed.Count -eq $faultAfter) { throw "injected task-state fault after step $faultAfter" }
        }
        $delayBeforeCommit = 0
        [void][int]::TryParse([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_TASK_STATE_DELAY_BEFORE_COMMIT_MS'),[ref]$delayBeforeCommit)
        if ($delayBeforeCommit -gt 0) { Start-Sleep -Milliseconds ([Math]::Min($delayBeforeCommit,5000)) }
        foreach ($step in @($Journal.steps)) {
            Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
        }
        $Journal.status='committed';$Journal.completed_steps=@($completed);$Journal.failed_step='';$Journal.error=''
        [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes/archive" -Label 'transaction archive')
        [void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $archivePath -Content (ConvertTo-HarnessJsonText -Value $Journal))
        foreach ($claimRecord in $claims) {
            Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId ([string]$Journal.transaction_id) -TaskId ([string]$Journal.task_id) -IntentDigest ([string]$Journal.intent_digest) -Step $claimRecord.Step -Claim $claimRecord.Claim
        }
        [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $journalPath -ExpectedDigest $lastDigest)
        return [pscustomobject]@{ TransactionId=[string]$Journal.transaction_id;CompletedSteps=@($completed) }
    } catch {
        $failure = $_.Exception.Message
        $actualDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $journalPath
        if ($actualDigest -ceq $lastDigest) {
            $Journal.status='failed';$Journal.completed_steps=@($completed);$Journal.failed_step=$(if($completed.Count -lt @($Journal.steps).Count){[string]@($Journal.steps)[$completed.Count].id}else{'cleanup'});$Journal.error=$failure
            [void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $journalPath -Content (ConvertTo-HarnessJsonText -Value $Journal))
        }
        throw "$failure TransactionId=$($Journal.transaction_id). Replay: $($Journal.replay_command)"
    }
}

function New-TaskTransaction {
    param(
        [string]$WorkspaceRoot,
        [string]$TransactionId,
        [string]$Operation,
        [string]$TaskId,
        [AllowNull()][object]$ExpectedVersion,
        [object[]]$Steps,
        [System.Collections.IDictionary]$OperationContext = ([ordered]@{})
    )
    $journal = [ordered]@{
        transaction_id=$TransactionId
        operation=$Operation
        task_id=$TaskId
        expected_version=$ExpectedVersion
        workspace_identity=(Get-TaskStateWorkspaceIdentity -WorkspaceRoot $WorkspaceRoot)
        operation_context=$OperationContext
        intent_digest=''
        status='prepared'
        completed_steps=@()
        failed_step=[string]$Steps[0].id
        error=''
        replay_command=(Get-TaskReplayCommand -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId)
        created_at=[datetimeoffset]::UtcNow.ToString('o')
        steps=$Steps
    }
    $journal.intent_digest = Get-TransactionIntentDigest -Journal $journal
    return $journal
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
        $planAction='not-required'
        if ([bool]$policies.plan_required) {
            $plan=New-HarnessPlanArtifact -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractDigest $contract.Digest
            $steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'governed-plan' -RelativePath $plan.Path -Action write -Content $plan.Content));$planAction='created'
        }
        $pointerAction='unchanged'
        if ($ActivateCurrent) {
            $pointer=[ordered]@{schema_version='current-pointer/v1';task_id=$TaskId;task_version=1;activated_at=$timestamp};Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer
            $steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action write -Content (ConvertTo-HarnessJsonText -Value $pointer)));$pointerAction='activated'
        }
        $journal=New-TaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -Operation 'create' -TaskId $TaskId -ExpectedVersion $null -Steps @($steps) -OperationContext ([ordered]@{pointer_action=$pointerAction})
        $transaction=Invoke-TaskStateTransaction -WorkspaceRoot $WorkspaceRoot -Journal $journal
        return [ordered]@{operation='create';transaction_id=$transaction.TransactionId;pointer_action=$pointerAction;plan_action=$planAction;task=$task}
    } finally { Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex }
}

function Write-HarnessMigrationFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    $stream = [System.IO.FileStream]::new($Path,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,4096,[System.IO.FileOptions]::WriteThrough)
    try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
}

function Remove-HarnessEmptyMigrationParents {
    param([string[]]$Paths)
    foreach ($path in @($Paths)) {
        if ((Test-Path -LiteralPath $path -PathType Container) -and @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) {
            [System.IO.Directory]::Delete($path,$false)
        }
    }
}

function Import-HarnessV1TaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Contract,
        [Parameter(Mandatory)][string]$SourcePlanPath,
        [Parameter(Mandatory)][string]$SourcePlanDigest,
        [Parameter(Mandatory)][ValidateSet('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST')][string]$SourceStage,
        [Parameter(Mandatory)][string]$DryRunDigest,
        [string[]]$ImportedHistorySections=@(),
        [string]$ActorHost='migration',
        [string]$ActorModel='inherit'
    )
    Assert-V2WriteProtocol
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot;Assert-HarnessTaskId -TaskId $TaskId
    if ($SourcePlanDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or $DryRunDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'migration digest is invalid' }
    $sourceTarget=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $SourcePlanPath -Label 'v1 source plan' -MustExist File
    $sourceRelative=Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $sourceTarget
    if ((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $sourceRelative) -cne $SourcePlanDigest) { throw 'v1 source plan digest changed before migration' }
    Assert-RequirementContractDocument -RepoRoot $RepoRoot -TaskId $TaskId -Contract $Contract
    $policies=Get-TaskPolicyFlags -RepoRoot $RepoRoot -Profile 'governed' -Capabilities @()
    $paths=Get-TaskStatePaths -TaskId $TaskId
    $taskMutex=$null
    try {
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$TaskId")
        $targetRoot=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $paths.TaskRoot -Label 'v2 migration target' -AllowMissing
        if (Test-Path -LiteralPath $targetRoot) { throw "v2 task already exists: $TaskId" }
        if (@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId).Count -gt 0) { throw 'task has a pending transaction; replay it before migration' }

        $timestamp=[datetimeoffset]::UtcNow.ToString('o')
        $contractPath="$($paths.TaskRoot)/contract.json"
        $task=[ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='paused';identity='existing';intent='write';requirement_state='clear';execution_profile='governed';persistence='durable';contract_path=$contractPath;contract_digest=[string]$Contract.digest;block_reason=$null;policies=$policies;approvals=@();evidence_path=$null;created_at=$timestamp;updated_at=$timestamp}
        Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $task
        $event=New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt_'+[guid]::NewGuid().ToString('N')) -TaskId $TaskId -Version 1 -Type 'task.created' -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{
            profile='governed'
            contract_digest=[string]$Contract.digest
            import_note=[ordered]@{
                source_protocol='v1'
                source_stage=$SourceStage
                source_plan_path=$sourceRelative
                source_plan_digest=$SourcePlanDigest
                dry_run_digest=$DryRunDigest
                history_sections=@($ImportedHistorySections)
                imported_as='reference-only'
                capability_state_inferred=$false
            }
        })
        $contractText=ConvertTo-HarnessJsonText -Value $Contract
        $taskText=ConvertTo-HarnessJsonText -Value $task
        $eventText=ConvertTo-HarnessJsonLine -Value $event

        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        $parentRelatives=@('.assistant','.assistant/runtime','.assistant/runtime/tasks')
        $parentPaths=@($parentRelatives|ForEach-Object{Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $_ -Label 'migration parent' -AllowMissing})
        $createdParents=[System.Collections.Generic.List[string]]::new()
        for($index=0;$index-lt$parentPaths.Count;$index++){if(-not(Test-Path -LiteralPath $parentPaths[$index])){$createdParents.Insert(0,$parentPaths[$index])}}
        $stageRoot=$null
        try {
            [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path '.assistant/runtime/tasks' -Label 'v2 task parent')
            $stageRelative=".assistant/runtime/tasks/.migration-$TaskId-$([guid]::NewGuid().ToString('N'))"
            $stageRoot=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $stageRelative -Label 'migration staging directory' -AllowMissing
            [void][System.IO.Directory]::CreateDirectory($stageRoot)
            Write-HarnessMigrationFile -Path (Join-Path $stageRoot 'contract.json') -Content $contractText
            Write-HarnessMigrationFile -Path (Join-Path $stageRoot 'task.json') -Content $taskText
            Write-HarnessMigrationFile -Path (Join-Path $stageRoot 'events.jsonl') -Content $eventText
            if ((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path (Join-Path $stageRelative 'contract.json')) -cne (Get-HarnessSha256Text -Content $contractText) -or
                (Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path (Join-Path $stageRelative 'task.json')) -cne (Get-HarnessSha256Text -Content $taskText) -or
                (Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path (Join-Path $stageRelative 'events.jsonl')) -cne (Get-HarnessSha256Text -Content $eventText)) { throw 'migration staging verification failed' }
            if ([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_MIGRATION_FAIL_BEFORE_PUBLISH') -ceq '1') { throw 'injected migration failure before publish' }
            if ((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $sourceRelative) -cne $SourcePlanDigest) { throw 'v1 source plan changed while migration was staged' }
            [System.IO.Directory]::Move($stageRoot,$targetRoot)
            $stageRoot=$null
        } catch {
            if ($null-ne$stageRoot-and(Test-Path -LiteralPath $stageRoot -PathType Container)) {
                $verifiedStage=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $stageRoot -Label 'migration cleanup target' -MustExist Directory
                if (-not [System.IO.Path]::GetFileName($verifiedStage).StartsWith(".migration-$TaskId-",[System.StringComparison]::Ordinal)) { throw 'migration cleanup target is invalid' }
                [System.IO.Directory]::Delete($verifiedStage,$true)
            }
            Remove-HarnessEmptyMigrationParents -Paths @($createdParents)
            throw
        }
        return [ordered]@{operation='import-v1';source_plan_path=$sourceRelative;source_plan_digest=$SourcePlanDigest;dry_run_digest=$DryRunDigest;pointer_action='unchanged';task=$task}
    } finally { Exit-TaskStateMutex -Mutex $taskMutex }
}

function Get-HarnessTaskStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId)
    Reset-TaskStateWorkspaceIdentityCache;$WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot;Assert-HarnessTaskId -TaskId $TaskId;$paths=Get-TaskStatePaths -TaskId $TaskId
    $taskMutex=$null;$currentMutex=$null
    try {
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$TaskId");$currentMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        $task=Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId;$events=Read-EventLog -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Events;$current=Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current;$pending=@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId)
        if ($null -ne $current -and [string]$current.task_id -ceq $TaskId -and [int]$current.task_version -ne [int]$task.version) { throw 'current pointer task_version is stale' }
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
        $task=Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId
        if ([int]$task.version -ne $ExpectedVersion) { throw "ExpectedVersion mismatch: expected=$ExpectedVersion actual=$($task.version)" }
        $from=[string]$task.status;if (@($script:Transitions[$from]) -cnotcontains $To) { throw "illegal task transition: $from -> $To" }
        if ($To -ceq 'blocked' -and [string]::IsNullOrWhiteSpace($Reason)) { throw 'blocked transition requires -Reason' }
        if ($from -ceq 'blocked' -and $To -ceq 'ready' -and [string]::IsNullOrWhiteSpace($ContractPath)) { throw 'blocked -> ready requires a revised -Contract' }
        if ($EvidenceSatisfied) { throw '-EvidenceSatisfied was removed; use verify -Evidence' }
        if ($To -ceq 'done') { throw 'done requires verify -Evidence' }
        $current=Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current;$isCurrent=$null -ne $current -and [string]$current.task_id -ceq $TaskId
        if ($isCurrent -and [int]$current.task_version -ne $ExpectedVersion) { throw 'current pointer version is stale; replay or repair before transition' }
        $next=(ConvertTo-HarnessJsonText -Value $task)|ConvertFrom-HarnessJson -ErrorAction Stop;$next.version=$ExpectedVersion+1;$next.status=$To;$next.updated_at=[datetimeoffset]::UtcNow.ToString('o')
        if ($To -ceq 'blocked') {$next.requirement_state='blocked';$next.block_reason=$Reason}
        elseif ($from -ceq 'blocked' -and $To -ceq 'ready') {$contract=Get-RequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractPath $ContractPath;if($contract.Digest -ceq [string]$task.contract_digest){throw 'blocked -> ready requires a revised Contract digest'};$next.requirement_state='clear';$next.block_reason=$null;$next.contract_path=$contract.Path;$next.contract_digest=$contract.Digest}
        Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $next
        $transactionId='txn_'+[guid]::NewGuid().ToString('N');$timestamp=[string]$next.updated_at;$event=New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt_'+$transactionId.Substring(4)) -TaskId $TaskId -Version ([int]$next.version) -Type (Get-TransitionEventType -From $from -To $To) -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{from=$from;to=$To;reason=$Reason})
        $events=Read-EventLog -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Events;$eventText=$events.Text+(ConvertTo-HarnessJsonLine -Value $event)
        $steps=[System.Collections.Generic.List[object]]::new();$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'task-state' -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessJsonText -Value $next)));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'event-log' -RelativePath $paths.Events -Action write -Content $eventText));$pointerAction='unchanged'
        if ($isCurrent) {
            if ($To -cin @('done','cancelled')) {$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action delete -Content $null));$pointerAction='cleared'}
            else {$pointer=[ordered]@{schema_version='current-pointer/v1';task_id=$TaskId;task_version=[int]$next.version;activated_at=[string]$current.activated_at};Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer;$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action write -Content (ConvertTo-HarnessJsonText -Value $pointer)));$pointerAction='updated'}
        }
        $journal=New-TaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -Operation 'transition' -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Steps @($steps) -OperationContext ([ordered]@{pointer_action=$pointerAction})
        $transaction=Invoke-TaskStateTransaction -WorkspaceRoot $WorkspaceRoot -Journal $journal
        return [ordered]@{operation='transition';transaction_id=$transaction.TransactionId;pointer_action=$pointerAction;task=$next}
    } finally {Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex}
}

function Resume-HarnessTaskExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$ExpectedVersion,
        [string]$ActorHost = 'codex',
        [string]$ActorModel = 'inherit'
    )

    Assert-V2WriteProtocol
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    Assert-HarnessTaskId -TaskId $TaskId
    $paths = Get-TaskStatePaths -TaskId $TaskId
    $taskMutex = $null
    $currentMutex = $null
    try {
        $taskMutex = Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$TaskId")
        $currentMutex = Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        $task = Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId
        if ([int]$task.version -ne $ExpectedVersion) {
            throw "ExpectedVersion mismatch: expected=$ExpectedVersion actual=$($task.version)"
        }
        if ([string]$task.requirement_state -cne 'clear') {
            throw 'blocked Requirement cannot resume execution'
        }
        if ([string]$task.status -cnotin @('ready','running','paused','failed')) {
            throw "task status cannot resume execution: $($task.status)"
        }
        $current = Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current
        if ($null -ne $current -and [string]$current.task_id -cne $TaskId) {
            throw "another current task is active: $($current.task_id)"
        }
        if ($null -ne $current -and [int]$current.task_version -ne $ExpectedVersion) {
            throw 'current pointer version is stale; replay or repair before resume-and-execute'
        }

        $next = (ConvertTo-HarnessJsonText -Value $task) | ConvertFrom-HarnessJson -ErrorAction Stop
        $next.version = $ExpectedVersion + 1
        $next.status = 'running'
        $next.updated_at = [datetimeoffset]::UtcNow.ToString('o')
        Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $next

        $transactionId = 'txn_' + [guid]::NewGuid().ToString('N')
        $timestamp = [string]$next.updated_at
        $events = Read-EventLog -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Events
        $event = New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt_' + $transactionId.Substring(4)) -TaskId $TaskId -Version ([int]$next.version) -Type 'execution.started' -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{ from=[string]$task.status;to='running';source='resume-and-execute' })
        $pointer = [ordered]@{ schema_version='current-pointer/v1';task_id=$TaskId;task_version=[int]$next.version;activated_at=$timestamp }
        Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer
        $steps = [System.Collections.Generic.List[object]]::new()
        $steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'task-state' -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessJsonText -Value $next)))
        $steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'event-log' -RelativePath $paths.Events -Action write -Content ($events.Text + (ConvertTo-HarnessJsonLine -Value $event))))
        $steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action write -Content (ConvertTo-HarnessJsonText -Value $pointer)))
        $pointerAction = if ($null -eq $current) { 'activated' } else { 'updated' }
        $journal = New-TaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -Operation 'resume' -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Steps @($steps) -OperationContext ([ordered]@{pointer_action=$pointerAction})
        $transaction = Invoke-TaskStateTransaction -WorkspaceRoot $WorkspaceRoot -Journal $journal
        return [ordered]@{
            operation = 'resume-and-execute'
            transaction_id = $transaction.TransactionId
            write_authorized = $true
            pointer_action = $pointerAction
            task = $next
        }
    } finally {
        Exit-TaskStateMutex -Mutex $currentMutex
        Exit-TaskStateMutex -Mutex $taskMutex
    }
}

function Set-HarnessTaskApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$ExpectedVersion,
        [Parameter(Mandatory)][string]$ApprovalPath,[string]$ActorHost='codex',[string]$ActorModel='inherit'
    )
    Assert-V2WriteProtocol;$WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot;Assert-HarnessTaskId -TaskId $TaskId;$paths=Get-TaskStatePaths -TaskId $TaskId
    $taskMutex=$null;$currentMutex=$null
    try{
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$TaskId");$currentMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        $task=Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId
        if([int]$task.version-ne$ExpectedVersion){throw "ExpectedVersion mismatch: expected=$ExpectedVersion actual=$($task.version)"}
        if(-not[bool]$task.policies.approval_required){throw 'task policy does not allow Approval import'}
        if([string]$task.requirement_state-cne'clear'){throw 'blocked Requirement cannot accept Approval'}
        if([string]$task.status-cin@('done','cancelled')){throw 'terminal task cannot accept Approval'}
        $approval=Resolve-HarnessApprovalInput -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -ApprovalPath $ApprovalPath -TaskId $TaskId -TargetTaskVersion ($ExpectedVersion+1) -ContractDigest ([string]$task.contract_digest)
        if(@($task.approvals)-ccontains[string]$approval.Document.approval_id){throw 'Approval is already attached to task'}
        $approvalTarget=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $approval.OutputPath -Label 'task Approval' -AllowMissing
        if(Test-Path -LiteralPath $approvalTarget){throw 'Approval record already exists'}
        $current=Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current;$isCurrent=$null-ne$current-and[string]$current.task_id-ceq$TaskId
        if($isCurrent-and[int]$current.task_version-ne$ExpectedVersion){throw 'current pointer version is stale; replay or repair before approve'}
        $next=(ConvertTo-HarnessJsonText -Value $task)|ConvertFrom-HarnessJson;$next.version=$ExpectedVersion+1;$next.approvals=@(@($task.approvals)+@([string]$approval.Document.approval_id));$next.updated_at=[datetimeoffset]::UtcNow.ToString('o');Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $next
        $transactionId='txn_'+[guid]::NewGuid().ToString('N');$timestamp=[string]$next.updated_at;$events=Read-EventLog -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Events
        $event=New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt_'+$transactionId.Substring(4)) -TaskId $TaskId -Version ([int]$next.version) -Type 'approval.granted' -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{approval_id=[string]$approval.Document.approval_id;approval_type=[string]$approval.Document.approval_type;approval_path=$approval.OutputPath;digest=$approval.Digest})
        $steps=[Collections.Generic.List[object]]::new();$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'approval' -RelativePath $approval.OutputPath -Action write -Content $approval.Content));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'task-state' -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessJsonText -Value $next)));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'event-log' -RelativePath $paths.Events -Action write -Content ($events.Text+(ConvertTo-HarnessJsonLine -Value $event))));$pointerAction='unchanged'
        if($isCurrent){$pointer=[ordered]@{schema_version='current-pointer/v1';task_id=$TaskId;task_version=[int]$next.version;activated_at=[string]$current.activated_at};Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer;$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action write -Content (ConvertTo-HarnessJsonText -Value $pointer)));$pointerAction='updated'}
        $journal=New-TaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -Operation 'approve' -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Steps @($steps) -OperationContext ([ordered]@{approval_input_path=[string]$approval.InputPath;pointer_action=$pointerAction});$transaction=Invoke-TaskStateTransaction -WorkspaceRoot $WorkspaceRoot -Journal $journal
        return [ordered]@{operation='approve';transaction_id=$transaction.TransactionId;approval_id=[string]$approval.Document.approval_id;approval_path=$approval.OutputPath;approval_digest=$approval.Digest;pointer_action=$pointerAction;task=$next}
    }finally{Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex}
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
        $task=Read-TaskStateDocument -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Task -ExpectedTaskId $TaskId
        if([int]$task.version-ne$ExpectedVersion){throw "ExpectedVersion mismatch: expected=$ExpectedVersion actual=$($task.version)"}
        if([string]$task.status-cne'verifying'){throw "verify requires task status verifying; actual=$($task.status)"}
        $contract=Get-RequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ContractPath ([string]$task.contract_path)
        if($contract.Digest-cne[string]$task.contract_digest){throw 'task Contract digest is stale'}
        $evidence=Resolve-HarnessEvidence -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -TaskVersion $ExpectedVersion -ContractDigest ([string]$task.contract_digest) -RequiredAcceptanceCount @($contract.Document.acceptance).Count -EvidencePath $EvidencePath
        $governance=Assert-HarnessGovernanceReady -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $task -Evidence $evidence
        $approval=$null;if([bool]$task.policies.approval_required-and[string]$evidence.NextStatus-ceq'done'){$approval=Assert-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $task}
        $current=Read-CurrentPointer -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Current;$isCurrent=$null-ne$current-and[string]$current.task_id-ceq$TaskId
        if($isCurrent-and[int]$current.task_version-ne$ExpectedVersion){throw 'current pointer version is stale; replay or repair before verify'}
        $next=(ConvertTo-HarnessJsonText -Value $task)|ConvertFrom-HarnessJson;$next.version=$ExpectedVersion+1;$next.status=$evidence.NextStatus;$next.evidence_path=$evidence.OutputPath;$next.updated_at=[datetimeoffset]::UtcNow.ToString('o');Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $next
        $transactionId='txn_'+[guid]::NewGuid().ToString('N');$timestamp=[string]$next.updated_at;$events=Read-EventLog -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $paths.Events
        $recorded=New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt_'+$transactionId.Substring(4)) -TaskId $TaskId -Version ([int]$next.version) -Type 'verification.recorded' -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{evidence_path=$evidence.OutputPath;digest=$evidence.Digest;conclusion=$evidence.Conclusion;from='verifying';to=$evidence.NextStatus;plan_path=$(if($null-ne$governance.Plan){$governance.Plan.Path}else{$null});audit_path=$(if($null-ne$governance.Audit){$governance.Audit.Path}else{$null});approval_id=$(if($null-ne$approval){[string]$approval.Document.approval_id}else{$null})})
        $eventText=$events.Text+(ConvertTo-HarnessJsonLine -Value $recorded)
        if($evidence.NextStatus-cne'verifying'){$transition=New-TaskEvent -RepoRoot $RepoRoot -EventId ('evt2_'+$transactionId.Substring(4)) -TaskId $TaskId -Version ([int]$next.version) -Type (Get-TransitionEventType -From 'verifying' -To $evidence.NextStatus) -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{source='evidence';conclusion=$evidence.Conclusion});$eventText+=(ConvertTo-HarnessJsonLine -Value $transition)}
        $steps=[Collections.Generic.List[object]]::new();$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'evidence' -RelativePath $evidence.OutputPath -Action write -Content $evidence.Content));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'task-state' -RelativePath $paths.Task -Action write -Content (ConvertTo-HarnessJsonText -Value $next)));$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'event-log' -RelativePath $paths.Events -Action write -Content $eventText));$pointerAction='unchanged'
        if($isCurrent){if($evidence.NextStatus-ceq'done'){$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action delete -Content $null));$pointerAction='cleared'}else{$pointer=[ordered]@{schema_version='current-pointer/v1';task_id=$TaskId;task_version=[int]$next.version;activated_at=[string]$current.activated_at};Assert-CurrentPointerDocument -RepoRoot $RepoRoot -Pointer $pointer;$steps.Add((New-TransactionStep -WorkspaceRoot $WorkspaceRoot -Id 'current-pointer' -RelativePath $paths.Current -Action write -Content (ConvertTo-HarnessJsonText -Value $pointer)));$pointerAction='updated'}}
        $journal=New-TaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $transactionId -Operation 'verify' -TaskId $TaskId -ExpectedVersion $ExpectedVersion -Steps @($steps) -OperationContext ([ordered]@{evidence_input_path=[string]$evidence.InputPath;pointer_action=$pointerAction});$transaction=Invoke-TaskStateTransaction -WorkspaceRoot $WorkspaceRoot -Journal $journal
        return [ordered]@{operation='verify';transaction_id=$transaction.TransactionId;conclusion=$evidence.Conclusion;evidence_path=$evidence.OutputPath;evidence_digest=$evidence.Digest;plan_path=$(if($null-ne$governance.Plan){$governance.Plan.Path}else{$null});audit_path=$(if($null-ne$governance.Audit){$governance.Audit.Path}else{$null});pointer_action=$pointerAction;task=$next}
    }finally{Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex}
}

function Write-TaskTransactionJournalCas {
    param(
        [string]$WorkspaceRoot,
        [string]$Path,
        [System.Collections.IDictionary]$Journal,
        [string]$ExpectedCurrentDigest
    )
    $content=ConvertTo-HarnessJsonText -Value $Journal
    $bytes=[System.Text.UTF8Encoding]::new($false).GetBytes($content)
    $digest=Get-HarnessSha256Text -Content $content
    return & $script:AtomicWriteModule {
        param($Root,$Source,$Target,$SourceDigest,$CurrentDigest)
        Write-HarnessAtomicBytes -WorkspaceRoot $Root -SourceBytes $Source -Path $Target -ExpectedSourceDigest $SourceDigest -ExpectedCurrentDigest $CurrentDigest
    } $WorkspaceRoot $bytes $Path $digest $ExpectedCurrentDigest
}

function Remove-TaskTransactionJournalCas {
    param([string]$WorkspaceRoot,[string]$Path,[string]$ExpectedDigest)
    $removed=& $script:AtomicWriteModule {
        param($Root,$Target,$Digest)
        Remove-HarnessFileIfDigestAtomic -WorkspaceRoot $Root -Path $Target -ExpectedDigest $Digest
    } $WorkspaceRoot $Path $ExpectedDigest
    if(-not$removed){throw 'transaction journal disappeared before CAS cleanup'}
}

function Assert-LegacyTransactionReplayInputs {
    param(
        [string]$WorkspaceRoot,
        [System.Collections.IDictionary]$Journal,
        [switch]$UseAuthorizedSnapshot
    )
    $schemaRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $stepsById=[ordered]@{};foreach($step in @($Journal.steps)){$stepsById[[string]$step.id]=$step}
    $task=ConvertFrom-TransactionStepJson -Step $stepsById['task-state'] -Label 'legacy transaction task-state payload'
    $operation=[string]$Journal.operation
    $createdAt=[datetimeoffset]::Parse([string]$Journal.created_at,[Globalization.CultureInfo]::InvariantCulture)
    $replayAsOf=$(if($UseAuthorizedSnapshot){$createdAt}else{[datetimeoffset]::UtcNow})
    $mustResolveContract=[string]$Journal.operation-ceq'create'-or[string]$Journal.operation-ceq'verify'
    if($operation-ceq'transition'){
        $eventContent=Get-TransactionStepContent -Step $stepsById['event-log'] -Label 'legacy transaction event-log payload'
        $events=@($eventContent.TrimEnd("`r","`n")-split"`n"|ForEach-Object{$_|ConvertFrom-HarnessJson})
        $targetEvent=@($events|Where-Object{[int64]$_.task_version-eq[int64]$task.version})[-1]
        $mustResolveContract=[string]$targetEvent.payload.from-ceq'blocked'-and[string]$targetEvent.payload.to-ceq'ready'
    }
    if($mustResolveContract){
        $contract=Get-RequirementContract -RepoRoot $schemaRoot -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Journal.task_id) -ContractPath ([string]$task.contract_path)
        if([string]$contract.Digest-cne[string]$task.contract_digest){throw 'legacy transaction Requirement Contract is stale'}
    }
    if($operation-ceq'approve'){
        $approval=ConvertFrom-TransactionStepJson -Step $stepsById['approval'] -Label 'legacy transaction Approval payload'
        $expired=& $script:ApprovalModule {
            param($Value,$AsOf)
            Test-HarnessApprovalExpiry -Approval $Value -AsOf $AsOf
        } $approval $replayAsOf
        if($expired){throw 'Approval is expired'}
    }
    if($operation-ceq'verify'){
        if(-not$UseAuthorizedSnapshot){
            throw 'legacy claim-free verify cannot be safely replayed because its original Evidence input path is unavailable; run verify again'
        }
        $evidenceStep=$stepsById['evidence']
        $evidenceContent=Get-TransactionStepContent -Step $evidenceStep -Label 'legacy transaction Evidence payload'
        $journalEvidence=$evidenceContent|ConvertFrom-HarnessJson -ErrorAction Stop
        $resolvedEvidence=& $script:EvidenceModule {
            param($Root,$Workspace,$Task,$Version,$Digest,$AcceptanceCount,$Path,$PinnedRevision)
            Resolve-HarnessEvidenceCore -RepoRoot $Root -WorkspaceRoot $Workspace -TaskId $Task -TaskVersion $Version -ContractDigest $Digest -RequiredAcceptanceCount $AcceptanceCount -EvidencePath $Path -PinnedRevision $PinnedRevision
        } $schemaRoot $WorkspaceRoot ([string]$Journal.task_id) ([int64]$Journal.expected_version) ([string]$task.contract_digest) @($contract.Document.acceptance).Count ([string]$evidenceStep.relative_path) ([string]$journalEvidence.revision)
        if([string]$resolvedEvidence.OutputPath-cne[string]$evidenceStep.relative_path-or
            [string]$resolvedEvidence.Digest-cne[string]$evidenceStep.after_digest-or
            [string]$resolvedEvidence.Content-cne$evidenceContent-or
            [string]$resolvedEvidence.NextStatus-cne[string]$task.status){
            throw 'legacy verify transaction input no longer matches its journal'
        }
        $beforeTask=[ordered]@{};foreach($key in $task.Keys){$beforeTask[$key]=$task[$key]}
        $beforeTask.version=[int64]$Journal.expected_version
        $beforeTask.status='verifying'
        $beforeTask.evidence_path=$null
        [void](Assert-HarnessGovernanceReady -RepoRoot $schemaRoot -WorkspaceRoot $WorkspaceRoot -Task $beforeTask -Evidence $resolvedEvidence)
        if([bool]$beforeTask.policies.approval_required-and[string]$resolvedEvidence.NextStatus-ceq'done'){
            [void](& $script:ApprovalModule {
                param($Root,$Workspace,$Task,$AsOf)
                Assert-HarnessTaskApprovalCore -RepoRoot $Root -WorkspaceRoot $Workspace -Task $Task -AsOf $AsOf
            } $schemaRoot $WorkspaceRoot $beforeTask $replayAsOf)
        }
    }
    if(-not$stepsById.Contains('current-pointer')){
        $current=Read-CurrentPointer -RepoRoot $schemaRoot -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/current.json"
        if($null-ne$current-and[string]$current.task_id-ceq[string]$Journal.task_id){throw 'legacy transaction omitted the current-pointer mutation for the current task'}
    }
}

function Repair-LegacyHarnessTaskTransaction {
    param([string]$WorkspaceRoot,[string]$TransactionId,[string]$Pending,[string]$Archive)
    $pendingPath=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Pending -Label 'legacy transaction journal' -AllowMissing
    $archivePath=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Archive -Label 'legacy transaction archive' -AllowMissing
    $initialRecord=$null
    if(Test-Path -LiteralPath $pendingPath -PathType Leaf){
        try{$initialRecord=Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $Pending -Location pending}
        catch{if(Test-Path -LiteralPath $pendingPath -PathType Leaf){throw}}
    }
    if($null-eq$initialRecord-and(Test-Path -LiteralPath $archivePath -PathType Leaf)){
        $initialRecord=Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $Archive -Location archive
    }
    if($null-eq$initialRecord){throw "transaction journal not found: $TransactionId"}
    if([string]$initialRecord.Format-cne'legacy'){throw 'transaction journal format changed before legacy replay'}
    $taskId=[string]$initialRecord.Journal.task_id;$initialIntent=[string]$initialRecord.IntentDigest
    $taskMutex=$null;$currentMutex=$null
    try{
        $taskMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$taskId")
        $currentMutex=Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')
        if(-not(Test-Path -LiteralPath $pendingPath -PathType Leaf)){
            if(-not(Test-Path -LiteralPath $archivePath -PathType Leaf)){throw 'legacy transaction journal disappeared without a durable commit marker'}
            $archiveRecord=Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $Archive -Location archive
            if([string]$archiveRecord.Format-cne'legacy'-or[string]$archiveRecord.Journal.task_id-cne$taskId-or[string]$archiveRecord.IntentDigest-cne$initialIntent){throw 'legacy transaction archive identity changed while acquiring its mutex'}
            foreach($step in @($archiveRecord.Journal.steps)){
                $ownership=Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest $initialIntent -Step $step
                if([string]$ownership.State-ceq'own'){throw 'legacy recovered transaction retains a publication claim owned by itself'}
            }
            return [ordered]@{operation='replay';transaction_id=$TransactionId;result='already-recovered'}
        }
        $record=Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $Pending -Location pending
        if([string]$record.Format-cne'legacy'-or[string]$record.Journal.task_id-cne$taskId-or[string]$record.IntentDigest-cne$initialIntent){throw 'legacy transaction journal identity changed while acquiring its mutex'}
        $journal=$record.Journal;$pendingDigest=Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $Pending
        if(Test-Path -LiteralPath $archivePath -PathType Leaf){
            $archiveRecord=Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $Archive -Location archive
            if([string]$archiveRecord.Format-cne'legacy'-or[string]$archiveRecord.Journal.task_id-cne$taskId-or[string]$archiveRecord.IntentDigest-cne$initialIntent){throw 'legacy transaction archive does not match its pending journal'}
            $owned=[System.Collections.Generic.List[object]]::new()
            foreach($step in @($archiveRecord.Journal.steps)){
                $ownership=Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest $initialIntent -Step $step
                if([string]$ownership.State-ceq'own'){Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step;$owned.Add($step)}
            }
            Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
            foreach($step in $owned){Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest $initialIntent -Step $step -Claim $null}
            Remove-TaskTransactionJournalCas -WorkspaceRoot $WorkspaceRoot -Path $Pending -ExpectedDigest $pendingDigest
            return [ordered]@{operation='replay';transaction_id=$TransactionId;result='recovered';completed_steps=@($archiveRecord.Journal.completed_steps)}
        }

        $steps=@($journal.steps);$completed=[System.Collections.Generic.List[string]]::new();foreach($id in @($journal.completed_steps)){$completed.Add([string]$id)}
        $useAuthorizedSnapshot=$completed.Count-gt0
        for($index=0;$index-lt$steps.Count;$index++){
            $step=$steps[$index]
            $ownership=Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest $initialIntent -Step $step
            if([string]$ownership.State-ceq'foreign'){throw "legacy transaction target is claimed by another transaction: $($step.relative_path)"}
            if([string]$ownership.State-ceq'own'-and$index-gt$completed.Count){throw "legacy transaction has an out-of-order publication claim: $($step.relative_path)"}
            $current=Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path ([string]$step.relative_path)
            $matchesBefore=if($null-eq$step.before_digest){$null-eq$current}else{$current-ceq[string]$step.before_digest}
            $matchesAfter=if([string]$step.action-ceq'write'){$current-ceq[string]$step.after_digest}else{$null-eq$current}
            if($index-eq0-and([string]$ownership.State-ceq'own'-or($matchesAfter-and-not$matchesBefore))){$useAuthorizedSnapshot=$true}
            if($index-lt$completed.Count){if(-not$matchesAfter){throw "legacy completed transaction step postcondition changed: $($step.relative_path)"}}
            elseif($index-eq$completed.Count){if(-not$matchesBefore-and-not$matchesAfter){throw "legacy first unfinished transaction step is outside its replay boundary: $($step.relative_path)"}}
            elseif(-not$matchesBefore){throw "legacy transaction suffix is published out of order: $($step.relative_path)"}
        }
        Assert-LegacyTransactionReplayInputs -WorkspaceRoot $WorkspaceRoot -Journal $journal -UseAuthorizedSnapshot:$useAuthorizedSnapshot
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
        $claims=[System.Collections.Generic.List[object]]::new()
        for($index=0;$index-lt$completed.Count;$index++){
            $step=$steps[$index]
            $claim=Enter-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest $initialIntent -Step $step -AllowExisting
            Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
            $claims.Add([pscustomobject]@{Step=$step;Claim=$claim})
        }
        for($index=$completed.Count;$index-lt$steps.Count;$index++){
            $step=$steps[$index]
            $result=Invoke-TransactionStep -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest $initialIntent -Step $step -AllowExistingClaim -AllowLegacyUnclaimedPostimage
            $claims.Add([pscustomobject]@{Step=$step;Claim=$result.Claim});$completed.Add([string]$step.id)
            $journal.status='applying';$journal.completed_steps=@($completed);$journal.failed_step=$(if($index+1-lt$steps.Count){[string]$steps[$index+1].id}else{'cleanup'});$journal.error=''
            $pendingDigest=Write-TaskTransactionJournalCas -WorkspaceRoot $WorkspaceRoot -Path $Pending -Journal $journal -ExpectedCurrentDigest $pendingDigest
        }
        foreach($step in $steps){
            $ownership=Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest $initialIntent -Step $step
            if([string]$ownership.State-cne'own'){throw "legacy transaction cannot commit without its own publication claim: $($step.relative_path)"}
            Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
        }
        $journal.status='recovered';$journal.completed_steps=@($completed);$journal.failed_step='';$journal.error=''
        $pendingDigest=Write-TaskTransactionJournalCas -WorkspaceRoot $WorkspaceRoot -Path $Pending -Journal $journal -ExpectedCurrentDigest $pendingDigest
        [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes/archive" -Label 'transaction archive')
        [void](Write-TaskTransactionJournalCas -WorkspaceRoot $WorkspaceRoot -Path $Archive -Journal $journal -ExpectedCurrentDigest 'missing')
        foreach($claimRecord in $claims){Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest $initialIntent -Step $claimRecord.Step -Claim $claimRecord.Claim}
        Remove-TaskTransactionJournalCas -WorkspaceRoot $WorkspaceRoot -Path $Pending -ExpectedDigest $pendingDigest
        return [ordered]@{operation='replay';transaction_id=$TransactionId;result='recovered';completed_steps=@($completed)}
    }finally{Exit-TaskStateMutex -Mutex $currentMutex;Exit-TaskStateMutex -Mutex $taskMutex}
}

function Repair-HarnessTaskTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TransactionId)
    Assert-V2WriteProtocol
    if ($TransactionId -cnotmatch '^txn_[0-9a-f]{32}$') { throw 'invalid TransactionId' }
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $pending = "$($script:RuntimeRelative)/failed-writes/$TransactionId.json"
    $archive = "$($script:RuntimeRelative)/failed-writes/archive/$TransactionId.json"
    $pendingPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $pending -Label 'transaction journal' -AllowMissing
    $archivePath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $archive -Label 'transaction archive' -AllowMissing

    $formatProbe=$null
    if(Test-Path -LiteralPath $pendingPath -PathType Leaf){
        try{$formatProbe=Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $pending -Location pending}
        catch{if(Test-Path -LiteralPath $pendingPath -PathType Leaf){throw}}
    }
    if($null-eq$formatProbe-and(Test-Path -LiteralPath $archivePath -PathType Leaf)){
        $formatProbe=Read-TaskTransactionJournal -WorkspaceRoot $WorkspaceRoot -Path $archive -Location archive
    }
    if($null-ne$formatProbe-and[string]$formatProbe.Format-ceq'legacy'){
        return Repair-LegacyHarnessTaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -Pending $pending -Archive $archive
    }

    $journal = $null
    if (Test-Path -LiteralPath $pendingPath -PathType Leaf) {
        try {
            $journal = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $pending -Label 'transaction journal'
        } catch {
            if (Test-Path -LiteralPath $pendingPath -PathType Leaf) { throw }
        }
    }
    if ($null -eq $journal -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        $archivedJournal = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $archive -Label 'transaction archive'
        Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $archivedJournal
        if ([string]$archivedJournal.transaction_id -cne $TransactionId -or
            [string]$archivedJournal.status -cnotin @('committed','recovered')) {
            throw 'transaction archive identity or status is invalid'
        }
        foreach ($step in @($archivedJournal.steps)) {
            $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId ([string]$archivedJournal.task_id) -IntentDigest ([string]$archivedJournal.intent_digest) -Step $step
            if ([string]$ownership.State -ceq 'own') {
                throw 'committed transaction retains a publication claim owned by itself'
            }
        }
        return [ordered]@{operation='replay';transaction_id=$TransactionId;result='already-recovered'}
    }
    if ($null -eq $journal) {
        throw "transaction journal not found: $TransactionId"
    }

    Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $journal
    if ([string]$journal.transaction_id -cne $TransactionId) {
        throw 'transaction journal identity does not match TransactionId'
    }
    $taskId = [string]$journal.task_id
    $initialIntentDigest = [string]$journal.intent_digest
    $taskMutex = $null
    $currentMutex = $null
    try {
        $taskMutex = Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix "task.$taskId")
        $currentMutex = Enter-TaskStateMutex -Name (Get-TaskStateMutexName -WorkspaceRoot $WorkspaceRoot -Suffix 'current')

        if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) {
            if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
                throw 'transaction journal disappeared without a durable commit marker'
            }
            $archivedJournal = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $archive -Label 'transaction archive'
            Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $archivedJournal
            if ([string]$archivedJournal.transaction_id -cne $TransactionId -or
                [string]$archivedJournal.task_id -cne $taskId -or
                [string]$archivedJournal.intent_digest -cne $initialIntentDigest -or
                [string]$archivedJournal.status -cnotin @('committed','recovered')) {
                throw 'transaction archive identity changed while acquiring its mutex'
            }
            foreach ($step in @($archivedJournal.steps)) {
                $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest ([string]$archivedJournal.intent_digest) -Step $step
                if ([string]$ownership.State -ceq 'own') {
                    throw 'committed transaction retains a publication claim owned by itself'
                }
            }
            return [ordered]@{operation='replay';transaction_id=$TransactionId;result='already-recovered'}
        }

        $journal = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $pending -Label 'transaction journal'
        Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $journal
        if ([string]$journal.transaction_id -cne $TransactionId -or
            [string]$journal.task_id -cne $taskId -or
            [string]$journal.intent_digest -cne $initialIntentDigest) {
            throw 'transaction journal identity changed while acquiring its mutex'
        }
        $pendingDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $pending

        if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
            $archivedJournal = Read-TaskStateJson -WorkspaceRoot $WorkspaceRoot -Path $archive -Label 'transaction archive'
            Assert-TransactionJournal -WorkspaceRoot $WorkspaceRoot -Journal $archivedJournal
            if ([string]$archivedJournal.transaction_id -cne $TransactionId -or
                [string]$archivedJournal.task_id -cne $taskId -or
                [string]$archivedJournal.intent_digest -cne [string]$journal.intent_digest -or
                [string]$archivedJournal.workspace_identity -cne [string]$journal.workspace_identity -or
                [string]$archivedJournal.status -cnotin @('committed','recovered')) {
                throw 'transaction archive does not match its pending journal'
            }
            $ownedArchiveSteps = [System.Collections.Generic.List[object]]::new()
            foreach ($step in @($archivedJournal.steps)) {
                $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest ([string]$archivedJournal.intent_digest) -Step $step
                if ([string]$ownership.State -ceq 'own') {
                    Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
                    $ownedArchiveSteps.Add($step)
                }
            }
            Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
            foreach ($step in $ownedArchiveSteps) {
                Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest ([string]$archivedJournal.intent_digest) -Step $step -Claim $null
            }
            [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $pending -ExpectedDigest $pendingDigest)
            return [ordered]@{operation='replay';transaction_id=$TransactionId;result='recovered';completed_steps=@($archivedJournal.completed_steps)}
        }

        $steps = @($journal.steps)
        $completed = [System.Collections.Generic.List[string]]::new()
        foreach ($id in @($journal.completed_steps)) { $completed.Add([string]$id) }
        $firstStepOwn = $false
        for ($index=0;$index -lt $steps.Count;$index++) {
            $step = $steps[$index]
            $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest ([string]$journal.intent_digest) -Step $step
            if ([string]$ownership.State -ceq 'own') {
                if ($index -gt $completed.Count) {
                    throw "out-of-order publication claim is not the completed prefix or first unfinished step: $($step.relative_path)"
                }
                if ($index -eq 0) { $firstStepOwn = $true }
            }
            if ($index -lt $completed.Count) {
                if ([string]$ownership.State -cne 'own') {
                    throw "completed transaction step lacks its own publication claim: $($step.relative_path)"
                }
                Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
            } elseif ([string]$ownership.State -ceq 'foreign') {
                throw "unfinished transaction target is claimed by another transaction: $($step.relative_path)"
            }
        }
        Assert-TransactionReplayInputs -WorkspaceRoot $WorkspaceRoot -Journal $journal -UseAuthorizedSnapshot:$firstStepOwn
        Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot

        for ($index=$completed.Count;$index -lt $steps.Count;$index++) {
            $step = $steps[$index]
            [void](Invoke-TransactionStep -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest ([string]$journal.intent_digest) -Step $step -AllowExistingClaim)
            $completed.Add([string]$step.id)
            $journal.status = 'applying'
            $journal.completed_steps = @($completed)
            $journal.failed_step = $(if ($index + 1 -lt $steps.Count) { [string]$steps[$index + 1].id } else { 'cleanup' })
            $journal.error = ''
            $pendingDigest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $pending -Content (ConvertTo-HarnessJsonText -Value $journal)
        }

        foreach ($step in $steps) {
            $ownership = Get-TransactionStepClaimOwnership -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest ([string]$journal.intent_digest) -Step $step
            if ([string]$ownership.State -cne 'own') {
                throw "transaction cannot commit without its own publication claim: $($step.relative_path)"
            }
            Assert-TransactionStepPostcondition -WorkspaceRoot $WorkspaceRoot -Step $step
        }

        $journal.status = 'recovered'
        $journal.completed_steps = @($completed)
        $journal.failed_step = ''
        $journal.error = ''
        $pendingDigest = Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $pending -Content (ConvertTo-HarnessJsonText -Value $journal)
        [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path "$($script:RuntimeRelative)/failed-writes/archive" -Label 'transaction archive')
        [void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path $archive -Content (ConvertTo-HarnessJsonText -Value $journal))

        foreach ($step in $steps) {
            Remove-TransactionStepClaim -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId -TaskId $taskId -IntentDigest ([string]$journal.intent_digest) -Step $step -Claim $null
        }
        [void](Remove-HarnessFileIfDigest -WorkspaceRoot $WorkspaceRoot -Path $pending -ExpectedDigest $pendingDigest)
        return [ordered]@{operation='replay';transaction_id=$TransactionId;result='recovered';completed_steps=@($completed)}
    } finally {
        Exit-TaskStateMutex -Mutex $currentMutex
        Exit-TaskStateMutex -Mutex $taskMutex
    }
}

Export-ModuleMember -Function New-HarnessTaskState,Get-HarnessTaskStatus,Set-HarnessTaskTransition,Resume-HarnessTaskExecution,Set-HarnessTaskApproval,Set-HarnessTaskEvidence,Repair-HarnessTaskTransaction
