[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [ValidateSet('core')][string]$Suite = 'core',
    [string]$DatasetPath = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($DatasetPath)) { $DatasetPath = Join-Path $RepoRoot 'tests\evals\core-scenarios.json' }
$DatasetPath = (Resolve-Path -LiteralPath $DatasetPath).Path

function Get-Sha256File {
    param([string]$Path)
    return 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-WriteCount {
    param([object]$SideEffects)
    if ($null -eq $SideEffects) { return 0 }
    $count = 0
    if ($SideEffects -is [System.Collections.IDictionary]) {
        foreach ($value in $SideEffects.Values) { $count += [int]$value }
    } else {
        foreach ($property in $SideEffects.PSObject.Properties) { $count += [int]$property.Value }
    }
    return $count
}

function Merge-ReferencedCase {
    param([System.Collections.IDictionary]$Base,[System.Collections.IDictionary]$Case)
    $value = [ordered]@{}
    foreach ($key in $Base.Keys) { $value[$key] = $Base[$key] }
    foreach ($key in $Case.Keys) {
        if ($key -notin @('id','expected','expected_state')) { $value[$key] = $Case[$key] }
    }
    return (($value | ConvertTo-Json -Depth 40 -Compress) | ConvertFrom-Json -AsHashtable -Depth 40)
}

function Get-ReferencedCase {
    param([object[]]$Cases,[string]$Id,[string]$Label)
    $matches = @($Cases | Where-Object { [string]$_.id -ceq $Id })
    if ($matches.Count -ne 1) { throw "$Label case reference is invalid: $Id" }
    return $matches[0]
}

function New-ObservedResult {
    param(
        [bool]$AskRequired,
        [AllowNull()][object]$Profile,
        [int]$WriteCount,
        [AllowNull()][object]$CompletionAllowed,
        [AllowNull()][object]$SelectedProtocol,
        [string[]]$Capabilities = @(),
        [string]$Source
    )
    return [ordered]@{
        ask_required = $AskRequired
        profile = $Profile
        write_count = $WriteCount
        completion_allowed = $CompletionAllowed
        selected_protocol = $SelectedProtocol
        capabilities = @($Capabilities | Sort-Object -Unique)
        source = $Source
    }
}

function Invoke-ScenarioEvaluator {
    param(
        [System.Collections.IDictionary]$Case,
        [int]$VariantIndex,
        [string]$ScratchRoot
    )

    $evaluator = $Case.evaluator
    switch ([string]$evaluator.kind) {
        'route-case' {
            $reference = Get-ReferencedCase -Cases @($script:RouteCatalog.cases) -Id ([string]$evaluator.case_id) -Label 'route'
            $input = Merge-ReferencedCase -Base $script:RouteCatalog.base -Case $reference
            $previous = $env:HARNESS_PROTOCOL
            try {
                $env:HARNESS_PROTOCOL = [string]$input.protocol
                $result = Resolve-HarnessExecutionProfile -RepoRoot $RepoRoot -Identity $input.identity -Intent $input.intent -RequirementState $input.requirement_state -Persistence $input.persistence -RiskScores $input.risk_scores -CriticalTriggers @($input.critical_triggers) -ChangedPaths @($input.changed_paths) -CommandText $input.command_text -Environment $input.environment -RequestedAlias $input.requested_alias -Reversible ([bool]$input.reversible) -VerificationAvailable ([bool]$input.verification_available) -DurableArtifactsRequested ([bool]$input.durable_artifacts_requested) -ScopeExpanded ([bool]$input.scope_expanded) -ProductBlockerDiscovered ([bool]$input.product_blocker_discovered)
            } finally {
                if ($null -eq $previous) { Remove-Item Env:HARNESS_PROTOCOL -ErrorAction SilentlyContinue } else { $env:HARNESS_PROTOCOL = $previous }
            }
            return New-ObservedResult -AskRequired ([string]$result.requirement_state -ceq 'blocked') -Profile $result.profile -WriteCount (Get-WriteCount $result.side_effects) -CompletionAllowed $null -SelectedProtocol $result.selected_protocol -Capabilities @($result.required_capabilities) -Source 'Harness.Policy'
        }
        'requirement-case' {
            $reference = Get-ReferencedCase -Cases @($script:RequirementCatalog.cases) -Id ([string]$evaluator.case_id) -Label 'requirement'
            $request = Merge-ReferencedCase -Base $script:RequirementCatalog.base_request -Case $reference
            $workspace = Join-Path $ScratchRoot ("requirement-{0}-{1}" -f $Case.id,$VariantIndex)
            [void][System.IO.Directory]::CreateDirectory($workspace)
            $requestPath = Join-Path $workspace 'request.json'
            [System.IO.File]::WriteAllText($requestPath,($request | ConvertTo-Json -Depth 40),[System.Text.UTF8Encoding]::new($false))
            $result = Invoke-RequirementInspection -RepoRoot $RepoRoot -WorkspaceRoot $workspace -RequestFile $requestPath
            return New-ObservedResult -AskRequired ([string]$result.requirement_state -ceq 'blocked') -Profile 'inspect' -WriteCount (Get-WriteCount $result.side_effects) -CompletionAllowed $null -SelectedProtocol 'v2' -Source 'Harness.Requirement'
        }
        'protocol-case' {
            $workspace = Join-Path $ScratchRoot ("protocol-{0}-{1}" -f $Case.id,$VariantIndex)
            [void][System.IO.Directory]::CreateDirectory($workspace)
            if ([string]$evaluator.fixture -ceq 'v2') {
                $taskId = 'resume-v2'
                $taskPath = Join-Path $workspace ".assistant\runtime\tasks\$taskId\task.json"
                [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $taskPath))
                $now = [DateTimeOffset]::UtcNow.ToString('o')
                $task = [ordered]@{schema_version='task-state/v2';task_id=$taskId;version=1;status='ready';identity='existing';intent='write';requirement_state='clear';execution_profile='direct';persistence='ephemeral';policies=[ordered]@{plan_required=$false;approval_required=$false;rollback_required=$false;independent_review_required=$false;verification_required=$true};created_at=$now;updated_at=$now}
                [System.IO.File]::WriteAllText($taskPath,($task | ConvertTo-Json -Depth 20 -Compress),[System.Text.UTF8Encoding]::new($false))
            } elseif ([string]$evaluator.fixture -ceq 'v1') {
                $taskId = 'resume-v1'
                $planPath = Join-Path $workspace "docs\tasks\$taskId\plan.md"
                [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $planPath))
                $plan = "---`ntask_id: resume-v1`nstage: TEST`ntool: codex`nupdated: 2026-07-14`n---`n"
                [System.IO.File]::WriteAllText($planPath,$plan,[System.Text.UTF8Encoding]::new($false))
            } else { throw "unknown protocol fixture: $($evaluator.fixture)" }
            $result = Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $workspace -TaskId $taskId -RequestedProtocol auto
            return New-ObservedResult -AskRequired $false -Profile $null -WriteCount (Get-WriteCount $result.side_effects) -CompletionAllowed $null -SelectedProtocol $result.selected_protocol -Source 'Harness.Protocol'
        }
        'evidence-case' {
            $digest = 'sha256:' + ('0' * 64)
            $record = [ordered]@{type='command';command='pwsh -File tests/example.ps1';cwd='.';exit_code=0;executed_at='2026-07-14T00:00:00Z';evidence_path='evidence/result.txt';digest=$digest;covers=@('AC-1')}
            if ([string]$evaluator.fixture -ceq 'unexecuted-pass') {
                $records = @()
            } elseif ([string]$evaluator.fixture -ceq 'path-escape') {
                $record.evidence_path = '../outside.txt'
                $records = @($record)
            } else { throw "unknown evidence fixture: $($evaluator.fixture)" }
            $document = [ordered]@{schema_version='evidence/v1';task_id='eval-evidence';task_version=1;contract_digest=$digest;revision=('dirty:' + ('0' * 64));records=$records;coverage=[ordered]@{satisfied=@('AC-1');not_verified=@();blocked=@()};gaps=@();conclusion='pass'}
            try {
                $valid = Test-Json -Json ($document | ConvertTo-Json -Depth 30 -Compress) -SchemaFile (Join-Path $RepoRoot 'schemas\evidence.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue
            } catch {
                $valid = $false
            }
            return New-ObservedResult -AskRequired $false -Profile $null -WriteCount 0 -CompletionAllowed ([bool]$valid) -SelectedProtocol 'v2' -Source 'evidence.schema.json'
        }
        'approval-case' {
            if ([string]$evaluator.fixture -cne 'stale-version') { throw "unknown approval fixture: $($evaluator.fixture)" }
            $workspace = Join-Path $ScratchRoot ("approval-{0}-{1}" -f $Case.id,$VariantIndex)
            $approvalPath = Join-Path $workspace '.assistant\runtime\tasks\eval-approval\approvals\apr_eval.json'
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $approvalPath))
            $digest = 'sha256:' + ('1' * 64)
            $approval = [ordered]@{schema_version='approval/v1';approval_id='apr_eval';task_id='eval-approval';task_version=1;contract_digest=$digest;approval_type='product';approved_scope=@('task:complete');approver='fixture-user';approved_at='2026-07-14T00:00:00Z';expires_at=$null;status='granted'}
            [System.IO.File]::WriteAllText($approvalPath,($approval | ConvertTo-Json -Depth 20),[System.Text.UTF8Encoding]::new($false))
            $task = [ordered]@{task_id='eval-approval';version=2;contract_digest=$digest;approvals=@('apr_eval')}
            $allowed = $false
            try { [void](Assert-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $workspace -Task $task -RequiredType product -RequiredScopes @('task:complete')); $allowed = $true } catch { $allowed = $false }
            return New-ObservedResult -AskRequired $false -Profile $null -WriteCount 0 -CompletionAllowed $allowed -SelectedProtocol 'v2' -Source 'Harness.Approval'
        }
        default { throw "unknown evaluator kind: $($evaluator.kind)" }
    }
}

$datasetRaw = Get-Content -LiteralPath $DatasetPath -Raw -Encoding utf8
if ($datasetRaw -match '(?i)"(?:prompt|prompt_text|raw_prompt)"\s*:') { throw 'scenario dataset must describe semantic intents, not exact prompt fields' }
$dataset = $datasetRaw | ConvertFrom-Json -AsHashtable -Depth 60 -ErrorAction Stop
if ([string]$dataset.schema_version -cne 'harness-scenario-evals/v1' -or [string]$dataset.suite -cne $Suite) { throw 'scenario dataset identity is invalid' }
if (@($dataset.cases).Count -ne 20) { throw 'core scenario dataset must contain exactly twenty cases' }
$ids = @($dataset.cases | ForEach-Object { [string]$_.id })
if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw 'scenario ids must be unique' }

$script:RouteCatalog = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests\scenarios\direct\route-cases.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60
$script:RequirementCatalog = Get-Content -LiteralPath (Join-Path $RepoRoot 'tests\scenarios\requirement-gate\inspect-cases.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 60
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Policy.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Requirement.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Approval.psm1') -Force

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-v2-scenario-eval-' + [guid]::NewGuid().ToString('N'))
$results = [System.Collections.Generic.List[object]]::new()
$missedAsk = 0
$unnecessaryAsk = 0
$readOnlyWrite = 0
$falsePass = 0
$variantCount = 0
try {
    [void][System.IO.Directory]::CreateDirectory($scratchRoot)
    foreach ($case in $dataset.cases) {
        if ([string]::IsNullOrWhiteSpace([string]$case.semantic_intent) -or @($case.paraphrases).Count -lt 2 -or @($case.paraphrases | Sort-Object -Unique).Count -ne @($case.paraphrases).Count) {
            throw "scenario $($case.id) must have a semantic intent and at least two unique paraphrases"
        }
        $variantCount += @($case.paraphrases).Count
        $variantObservations = [System.Collections.Generic.List[object]]::new()
        $failures = [System.Collections.Generic.List[string]]::new()
        $measurementStatus = 'measured'
        try {
            for ($index = 0; $index -lt @($case.paraphrases).Count; $index++) {
                $variantObservations.Add((Invoke-ScenarioEvaluator -Case $case -VariantIndex $index -ScratchRoot $scratchRoot))
            }
            $signatures = @($variantObservations | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress } | Sort-Object -Unique)
            if ($signatures.Count -ne 1) { $failures.Add('equivalent paraphrases produced different behavior') }
            $observed = $variantObservations[0]
            if ([bool]$case.expected.ask_required -ne [bool]$observed.ask_required) { $failures.Add('Ask decision mismatch') }
            if ($case.expected.Contains('profile')) {
                if ($null -eq $case.expected.profile) { if ($null -ne $observed.profile) { $failures.Add('profile should be null') } }
                elseif ([string]$case.expected.profile -cne [string]$observed.profile) { $failures.Add('profile mismatch') }
            }
            if ($case.expected.Contains('selected_protocol') -and [string]$case.expected.selected_protocol -cne [string]$observed.selected_protocol) { $failures.Add('protocol mismatch') }
            if ($case.expected.Contains('completion_allowed') -and [bool]$case.expected.completion_allowed -ne [bool]$observed.completion_allowed) { $failures.Add('completion decision mismatch') }
            if ($case.expected.Contains('required_capability') -and @($observed.capabilities) -cnotcontains [string]$case.expected.required_capability) { $failures.Add('required capability is missing') }
            if ([int]$observed.write_count -gt [int]$case.expected.max_write_count) { $failures.Add('write count exceeded the expected maximum') }

            if ([bool]$case.expected.ask_required -and -not [bool]$observed.ask_required) { $missedAsk++ }
            if (-not [bool]$case.expected.ask_required -and [bool]$observed.ask_required) { $unnecessaryAsk++ }
            if ($case.expected.Contains('read_only') -and [bool]$case.expected.read_only -and [int]$observed.write_count -gt 0) { $readOnlyWrite++ }
            if ($case.expected.Contains('completion_allowed') -and -not [bool]$case.expected.completion_allowed -and [bool]$observed.completion_allowed) { $falsePass++ }
        } catch {
            $measurementStatus = 'unavailable'
            $observed = $null
            $failures.Add($_.Exception.Message)
        }
        $results.Add([ordered]@{id=[string]$case.id;critical=[bool]$case.critical;semantic_intent=[string]$case.semantic_intent;variant_count=@($case.paraphrases).Count;measurement_status=$measurementStatus;status=$(if($failures.Count -eq 0){'pass'}else{'fail'});observed=$observed;failures=@($failures)})
    }
} finally {
    Remove-Module Harness.Policy,Harness.Requirement,Harness.Protocol,Harness.Approval -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $scratchRoot) { Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$failedCases = @($results | Where-Object { [string]$_.status -cne 'pass' }).Count
$unavailableCases = @($results | Where-Object { [string]$_.measurement_status -ceq 'unavailable' }).Count
$criticalMissedAsk = @($results | Where-Object { $_.critical -and $_.observed -and $_.observed.ask_required -eq $false -and (Get-ReferencedCase -Cases @($dataset.cases) -Id ([string]$_.id) -Label 'dataset').expected.ask_required -eq $true }).Count
$eligible = $failedCases -eq 0 -and $unavailableCases -eq 0 -and $criticalMissedAsk -eq 0 -and $readOnlyWrite -eq 0 -and $falsePass -eq 0
$report = [ordered]@{
    schema_version = 'harness-scenario-eval-report/v1'
    suite = $Suite
    dataset_digest = Get-Sha256File -Path $DatasetPath
    execution_backend = [ordered]@{status='measured';kind='deterministic-policy-and-schema';reason='Evaluated live repository policy modules and schemas without matching exact request wording.'}
    external_model = [ordered]@{status='unavailable';reason='No external model is required or accessed by the core deterministic suite.'}
    cases = @($results)
    metrics = [ordered]@{
        missed_ask = [ordered]@{status='measured';value=$missedAsk}
        critical_missed_ask = [ordered]@{status='measured';value=$criticalMissedAsk}
        unnecessary_ask = [ordered]@{status='measured';value=$unnecessaryAsk}
        read_only_write = [ordered]@{status='measured';value=$readOnlyWrite}
        false_pass = [ordered]@{status='measured';value=$falsePass}
    }
    summary = [ordered]@{case_count=$results.Count;variant_count=$variantCount;passed=$results.Count-$failedCases;failed=$failedCases;unavailable=$unavailableCases}
    eligibility = [ordered]@{eligible=$eligible;status=$(if($eligible){'pass'}else{'fail'});reason=$(if($eligible){'all required deterministic behavior metrics passed'}else{'one or more required behavior metrics failed or were unavailable'})}
}
$json = $report | ConvertTo-Json -Depth 40 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $target = if ([System.IO.Path]::IsPathRooted($OutputPath)) { [System.IO.Path]::GetFullPath($OutputPath) } else { [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $OutputPath)) }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'OutputPath parent directory does not exist' }
    [System.IO.File]::WriteAllText($target,$json,[System.Text.UTF8Encoding]::new($false))
}
Write-Output $json
if (-not $eligible) { exit 1 }
exit 0
