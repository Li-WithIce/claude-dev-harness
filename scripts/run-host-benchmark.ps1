#!/usr/bin/env pwsh
#requires -Version 7.3
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$OutputPath = '',
    [ValidateRange(1,10)][int]$Trials = 3,
    [ValidateRange(1,12)][int]$MaxRoundTrips = 8,
    [string]$Model = 'gpt-5.6-sol',
    [ValidateSet('max')][string]$Reasoning = 'max',
    [ValidateRange(30,3600)][int]$TimeoutSeconds = 900,
    [switch]$ValidateOnly,
    [switch]$KeepScratch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-TaggedFileHash {
    param([Parameter(Mandatory)][string]$Path)
    return 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextHash {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Write-AtomicJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    $parent = [IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($parent)
    $temporary = Join-Path $parent ('.host-benchmark-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$Path,$true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    $snapshot = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Root,$file.FullName).Replace('\','/')
        if ($relative -ceq '.git' -or $relative.StartsWith('.git/',[StringComparison]::Ordinal)) { continue }
        $snapshot[$relative] = Get-TaggedFileHash $file.FullName
    }
    return $snapshot
}

function Get-ChangedPaths {
    param([Collections.IDictionary]$Before,[Collections.IDictionary]$After)
    $names = @($Before.Keys) + @($After.Keys) | Sort-Object -Unique
    return @($names | Where-Object {
        -not $Before.Contains($_) -or -not $After.Contains($_) -or [string]$Before[$_] -cne [string]$After[$_]
    })
}

function Get-Median {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $middle = [math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle-1] + [double]$sorted[$middle]) / 2
}

function Get-ReportDigest {
    param([Collections.IDictionary]$Report)
    $payload = [ordered]@{}
    foreach ($key in $Report.Keys) {
        if ([string]$key -cne 'report_digest') { $payload[$key] = $Report[$key] }
    }
    return Get-TextHash (($payload | ConvertTo-Json -Depth 30 -Compress))
}

function Invoke-HostTrial {
    param(
        [Parameter(Mandatory)][ValidateSet('bare','v1','v2')][string]$Protocol,
        [Parameter(Mandatory)][int]$Trial,
        [Parameter(Mandatory)][string]$ScratchRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Reasoning,
        [Parameter(Mandatory)][int]$MaxRoundTrips,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $trialRoot = Join-Path $ScratchRoot ("$Protocol-$Trial")
    $workspace = Join-Path $trialRoot 'workspace'
    $userRoot = Join-Path $trialRoot 'user'
    $resultRoot = Join-Path $trialRoot 'results'
    [void][IO.Directory]::CreateDirectory((Join-Path $workspace 'src'))
    [void][IO.Directory]::CreateDirectory($userRoot)
    [void][IO.Directory]::CreateDirectory($resultRoot)
    [IO.File]::WriteAllText((Join-Path $workspace 'src\value.txt'),'alpha',[Text.UTF8Encoding]::new($false))
    @(& git -C $workspace init --quiet 2>&1) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "host benchmark git init failed for $Protocol" }
    if ($Protocol -eq 'bare') {
        [IO.File]::WriteAllText((Join-Path $workspace 'AGENTS.md'),"# Bare Host Benchmark`nExecute the authorized workspace task directly. This workspace intentionally has no harness lifecycle. Do not search outside this workspace for rules or skills.`n",[Text.UTF8Encoding]::new($false))
    }

    $savedEnvironment = [ordered]@{}
    foreach ($name in @('USERPROFILE','HARNESS_PROTOCOL','DEV_HARNESS_WORKSPACE_ROOT','WORKSPACE_ROOT')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
    }
    try {
        $env:USERPROFILE = $userRoot
        Remove-Item Env:DEV_HARNESS_WORKSPACE_ROOT,Env:WORKSPACE_ROOT -ErrorAction SilentlyContinue
        if ($Protocol -ne 'bare') {
            $installOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'install.ps1') -WorkspaceRoot $workspace -RepoRoot $RepoRoot -Preset core 2>&1 | ForEach-Object { [string]$_ })
            if ($LASTEXITCODE -ne 0) { throw "host benchmark install failed for $Protocol" }
        }
        $before = Get-TreeSnapshot $workspace
        $duration = 0.0
        $firstUsefulAction = $null
        $turns = 0
        $commandCalls = 0
        $mcpCalls = 0
        $webCalls = 0
        $fileCalls = 0
        $skillLoads = 0
        $inputTokens = [long]0
        $cachedInputTokens = [long]0
        $outputTokens = [long]0
        $tokenStatus = 'measured'
        $freshSessions = 0
        $modelRoundTrips = 0
        $invocationUnavailable = $false
        $diagnostic = $null
        $lastReason = 'execution_failed'
        $observationComplete = $false

        for ($round = 1; $round -le $MaxRoundTrips; $round++) {
            $freshSessions++
            $responsePath = Join-Path $resultRoot ("response-$round.json")
            $telemetryPath = Join-Path $resultRoot ("telemetry-$round.json")
            $task = @'
Work only inside this workspace. The user explicitly authorizes this complete, reversible, private one-file task and all normal harness stage transitions needed to finish it. Change only src/value.txt from exactly alpha to exactly beta. If a harness task for this request already exists, continue it instead of creating another task. Do not ask about scope, acceptance, rollback, or authorization: they are fully confirmed here. Run a real verification command that succeeds only when the file content is exactly beta. Do not change another user file; harness-required task/runtime records are allowed. Return only schema-valid JSON. Set task_completed and verification_passed true only after the exact file check has actually passed.
'@
            if ($Protocol -eq 'bare') { Remove-Item Env:HARNESS_PROTOCOL -ErrorAction SilentlyContinue } else { $env:HARNESS_PROTOCOL = $Protocol }
            if ($null -eq $savedEnvironment['USERPROFILE']) { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = [string]$savedEnvironment['USERPROFILE'] }
            $wrapperOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File $WrapperPath -Task $task -Workspace $workspace -Model $Model -Reasoning $Reasoning -Sandbox danger-full-access -ApprovalPolicy never -Ephemeral -AgentOutputOnly -Quiet -Isolated -OutputSchema $SchemaPath -Output $responsePath -TelemetryOutput $telemetryPath -TimeoutSeconds $TimeoutSeconds 2>&1 | ForEach-Object { [string]$_ })
            $wrapperExit = $LASTEXITCODE
            if ($wrapperExit -ne 0 -or -not (Test-Path -LiteralPath $responsePath -PathType Leaf) -or -not (Test-Path -LiteralPath $telemetryPath -PathType Leaf)) {
                $invocationUnavailable = $true
                $diagnostic = 'wrapper-exit-' + $wrapperExit
                $lastReason = 'execution_failed'
                break
            }
            try {
                $rawObservation = [IO.File]::ReadAllText($responsePath,[Text.UTF8Encoding]::new($false,$true))
                if (-not (Test-Json -Json $rawObservation -SchemaFile $SchemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) { throw 'invalid observation schema' }
                $observation = $rawObservation | ConvertFrom-Json -AsHashtable -Depth 20
                $telemetry = [IO.File]::ReadAllText($telemetryPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 20
                if ([string]$telemetry.schema_version -cne 'codex-invocation-telemetry/v1' -or [string]$telemetry.model -cne $Model -or [string]$telemetry.reasoning -cne $Reasoning -or -not [bool]$telemetry.ephemeral -or [string]$telemetry.sandbox -cne 'danger-full-access' -or [string]$telemetry.approval_policy -cne 'never') { throw 'invalid telemetry identity' }
            } catch {
                $invocationUnavailable = $true
                $diagnostic = 'invalid-wrapper-output'
                $lastReason = 'execution_failed'
                break
            }
            $duration += [double]$telemetry.duration_ms
            if ($round -eq 1) { $firstUsefulAction = $telemetry.first_useful_action_ms }
            $turns += [int]$telemetry.model_turns
            $modelRoundTrips += [int]$telemetry.agent_messages
            $commandCalls += [int]$telemetry.tool_calls.command
            $mcpCalls += [int]$telemetry.tool_calls.mcp
            $webCalls += [int]$telemetry.tool_calls.web_search
            $fileCalls += [int]$telemetry.tool_calls.file_change
            $skillLoads += [int]$telemetry.lifecycle_skill_loads
            if ([string]$telemetry.tokens.status -ceq 'measured') {
                $inputTokens += [long]$telemetry.tokens.input
                if ($null -ne $telemetry.tokens.cached_input) { $cachedInputTokens += [long]$telemetry.tokens.cached_input }
                $outputTokens += [long]$telemetry.tokens.output
            } else { $tokenStatus = 'unavailable' }
            $lastReason = [string]$observation.reason_code
            $targetExact = (Test-Path -LiteralPath (Join-Path $workspace 'src\value.txt') -PathType Leaf) -and [IO.File]::ReadAllText((Join-Path $workspace 'src\value.txt')) -ceq 'beta'
            if ($targetExact -and [bool]$observation.task_completed -and [bool]$observation.verification_executed -and [bool]$observation.verification_passed) {
                $observationComplete = $true
                break
            }
        }

        $after = Get-TreeSnapshot $workspace
        $changed = @(Get-ChangedPaths -Before $before -After $after)
        $artifactWrites = @($changed | Where-Object { $_.StartsWith('docs/tasks/',[StringComparison]::Ordinal) }).Count
        $runtimeWrites = @($changed | Where-Object { $_.StartsWith('.assistant/runtime/',[StringComparison]::Ordinal) -or $_.StartsWith('.assistant/运行时/',[StringComparison]::Ordinal) }).Count
        $unexpectedWrites = @($changed | Where-Object {
            $_ -cne 'src/value.txt' -and
            -not $_.StartsWith('docs/tasks/',[StringComparison]::Ordinal) -and
            -not $_.StartsWith('.assistant/runtime/',[StringComparison]::Ordinal) -and
            -not $_.StartsWith('.assistant/运行时/',[StringComparison]::Ordinal)
        }).Count
        $targetPassed = (Test-Path -LiteralPath (Join-Path $workspace 'src\value.txt') -PathType Leaf) -and [IO.File]::ReadAllText((Join-Path $workspace 'src\value.txt')) -ceq 'beta'
        $complete = $observationComplete -and $targetPassed -and $unexpectedWrites -eq 0
        $status = if ($invocationUnavailable) { 'unavailable' } elseif ($complete) { 'measured' } else { 'fail' }
        return [ordered]@{
            trial = $Trial
            status = $status
            diagnostic = $diagnostic
            completion_passed = $complete
            reason_code = $lastReason
            fresh_sessions = $freshSessions
            model_roundtrips = $modelRoundTrips
            model_roundtrip_basis = 'completed-agent-message-events'
            total_duration_ms = [math]::Round($duration,2)
            first_useful_action_ms = $firstUsefulAction
            model_turns = $turns
            tool_calls = [ordered]@{command=$commandCalls;mcp=$mcpCalls;web_search=$webCalls;file_change=$fileCalls;total=$commandCalls+$mcpCalls+$webCalls+$fileCalls}
            loaded_skills = [ordered]@{status='measured';value=$skillLoads;reason='Aggregate lifecycle SKILL.md command loads from sanitized host telemetry.'}
            loaded_files = [ordered]@{status='unavailable';value=$null;reason='Sanitized telemetry intentionally does not persist command paths or file names.'}
            artifact_writes = $artifactWrites
            runtime_writes = $runtimeWrites
            unexpected_writes = $unexpectedWrites
            tokens = [ordered]@{status=$tokenStatus;input=$(if($tokenStatus-ceq'measured'){$inputTokens}else{$null});cached_input=$(if($tokenStatus-ceq'measured'){$cachedInputTokens}else{$null});output=$(if($tokenStatus-ceq'measured'){$outputTokens}else{$null})}
        }
    } finally {
        foreach ($entry in $savedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key,$entry.Value,[EnvironmentVariableTarget]::Process)
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ($Model -cne 'gpt-5.6-sol') { throw 'Release host benchmark requires gpt-5.6-sol.' }
$wrapperPath = Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
$schemaPath = Join-Path $RepoRoot 'schemas\host-benchmark-observation.schema.json'
$installPath = Join-Path $RepoRoot 'install.ps1'
foreach ($path in @($wrapperPath,$schemaPath,$installPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required host benchmark input is missing: $path" }
}
$schemaText = [IO.File]::ReadAllText($schemaPath,[Text.UTF8Encoding]::new($false,$true))
$null = $schemaText | ConvertFrom-Json -AsHashtable -Depth 30 -ErrorAction Stop
if ($ValidateOnly) { Write-Output 'STATUS: PASS (host benchmark definition only; no model session executed)'; exit 0 }

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ('thin-v2-host-benchmark-' + [guid]::NewGuid().ToString('N') + '.json') }
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path (Get-Location).Path $OutputPath }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$scratchBase = Join-Path $RepoRoot '.assistant\运行时\release-qualification'
[void][IO.Directory]::CreateDirectory($scratchBase)
$scratchRoot = Join-Path $scratchBase ('thin-v2-host-benchmark-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratchRoot)
$records = [ordered]@{}
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    foreach ($protocol in @('bare','v1','v2')) {
        $trialRecords = [Collections.Generic.List[object]]::new()
        for ($trial=1; $trial -le $Trials; $trial++) {
            Write-Output ("[HOST] protocol={0} trial={1}/{2}" -f $protocol,$trial,$Trials)
            $trialRecords.Add((Invoke-HostTrial -Protocol $protocol -Trial $trial -ScratchRoot $scratchRoot -RepoRoot $RepoRoot -WrapperPath $wrapperPath -SchemaPath $schemaPath -Model $Model -Reasoning $Reasoning -MaxRoundTrips $MaxRoundTrips -TimeoutSeconds $TimeoutSeconds))
        }
        $all = @($trialRecords)
        $protocolStatus = if (@($all | Where-Object { [string]$_.status -ceq 'unavailable' }).Count -gt 0) { 'unavailable' } elseif (@($all | Where-Object { [string]$_.status -cne 'measured' }).Count -gt 0) { 'fail' } else { 'measured' }
        $records[$protocol] = [ordered]@{
            status = $protocolStatus
            trials = $all
            medians = [ordered]@{
                total_duration_ms = $(if($protocolStatus-ceq'measured'){[math]::Round((Get-Median @($all.total_duration_ms)),2)}else{$null})
                first_useful_action_ms = $(if($protocolStatus-ceq'measured' -and @($all.first_useful_action_ms | Where-Object {$null-ne$_}).Count-eq$Trials){[math]::Round((Get-Median @($all.first_useful_action_ms)),2)}else{$null})
                model_roundtrips = $(if($protocolStatus-ceq'measured'){[math]::Round((Get-Median @($all.model_roundtrips)),2)}else{$null})
                fresh_sessions = $(if($protocolStatus-ceq'measured'){[math]::Round((Get-Median @($all.fresh_sessions)),2)}else{$null})
                model_turns = $(if($protocolStatus-ceq'measured'){[math]::Round((Get-Median @($all.model_turns)),2)}else{$null})
                tool_calls = $(if($protocolStatus-ceq'measured'){[math]::Round((Get-Median @($all.tool_calls.total)),2)}else{$null})
            }
        }
    }
} finally {
    $timer.Stop()
    if (-not $KeepScratch -and (Test-Path -LiteralPath $scratchRoot -PathType Container)) {
        $resolvedScratch = [IO.Path]::GetFullPath($scratchRoot)
        $safePrefix = [IO.Path]::GetFullPath($scratchBase).TrimEnd('\') + '\'
        if (-not $resolvedScratch.StartsWith($safePrefix,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolvedScratch).StartsWith('thin-v2-host-benchmark-',[StringComparison]::Ordinal)) { throw 'Refusing to remove unsafe host benchmark scratch path.' }
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}

$direct = [ordered]@{status='unavailable';ratio=$null;threshold=1.25;reason='Measured complete bare and v2 host trials are required.'}
$roundtrip = [ordered]@{status='unavailable';reduction=$null;threshold=0.60;reason='Measured complete v1 and v2 host trials are required.'}
if ([string]$records.bare.status -ceq 'measured' -and [string]$records.v2.status -ceq 'measured' -and [double]$records.bare.medians.total_duration_ms -gt 0) {
    $ratio = [math]::Round(([double]$records.v2.medians.total_duration_ms / [double]$records.bare.medians.total_duration_ms),4)
    $direct = [ordered]@{status=$(if($ratio-le1.25){'pass'}else{'fail'});ratio=$ratio;threshold=1.25;reason='Ratio of measured median complete-task v2 and bare host duration.'}
}
if ([string]$records.v1.status -ceq 'measured' -and [string]$records.v2.status -ceq 'measured' -and [double]$records.v1.medians.model_roundtrips -gt 0) {
    $reduction = [math]::Round((([double]$records.v1.medians.model_roundtrips-[double]$records.v2.medians.model_roundtrips)/[double]$records.v1.medians.model_roundtrips),4)
    $roundtrip = [ordered]@{status=$(if($reduction-ge0.60){'pass'}else{'fail'});reduction=$reduction;threshold=0.60;reason='Reduction in measured median fresh-session roundtrips from v1 to v2.'}
}
$revision = (& git -C $RepoRoot rev-parse HEAD).Trim()
$dirty = -not [string]::IsNullOrWhiteSpace((@(& git -C $RepoRoot status --porcelain=v1 --untracked-files=no) -join "`n"))
$unavailable = @($records.Values | Where-Object { [string]$_.status -ceq 'unavailable' }).Count -gt 0
$eligible = -not $dirty -and [string]$direct.status -ceq 'pass' -and [string]$roundtrip.status -ceq 'pass'
$report = [ordered]@{
    schema_version = 'harness-host-benchmark-report/v1'
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    source_revision = $revision
    source_dirty = $dirty
    source = [ordered]@{runner_digest=Get-TaggedFileHash $PSCommandPath;wrapper_digest=Get-TaggedFileHash $wrapperPath;observation_schema_digest=Get-TaggedFileHash $schemaPath}
    execution = [ordered]@{model=$Model;reasoning=$Reasoning;trials_per_protocol=$Trials;max_fresh_sessions=$MaxRoundTrips;fresh_workspace_per_trial=$true;fresh_ephemeral_session_per_invocation=$true;model_roundtrip_basis='completed-agent-message-events';model_roundtrip_limit='Codex JSONL exposes completed agent messages but not underlying API request count';sandbox='danger-full-access';approval_policy='never';workspace_boundary='dedicated-ignored-nested-git-root';prompt_persisted=$false;raw_command_persisted=$false;thread_id_persisted=$false;install_duration_included=$false;duration_ms=[math]::Round($timer.Elapsed.TotalMilliseconds,2)}
    protocols = $records
    performance = [ordered]@{direct_latency=$direct;model_roundtrip_reduction=$roundtrip;eligible=$eligible}
    status = $(if($unavailable){'unavailable'}elseif($eligible){'pass'}else{'fail'})
    report_digest = $null
}
$report.report_digest = Get-ReportDigest $report
Write-AtomicJson -Path $OutputPath -Value $report
Write-Output "HOST_BENCHMARK_STATUS=$($report.status)`nHOST_BENCHMARK_DIRECT_RATIO=$($direct.ratio)`nHOST_BENCHMARK_ROUNDTRIP_REDUCTION=$($roundtrip.reduction)`nHOST_BENCHMARK_REPORT=$OutputPath"
if ([string]$report.status -ceq 'unavailable') { Write-Output '[UNAVAILABLE] one or more real host trials were unavailable'; exit 2 }
if (-not $eligible) { exit 1 }
exit 0
