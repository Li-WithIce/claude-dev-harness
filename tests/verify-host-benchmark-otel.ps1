[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$otelPath = Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Otel.ps1'
$trialPath = Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1'
$collectorPath = Join-Path $RepoRoot 'scripts\receive-otlp-http.ps1'
$wrapperPath = Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
. $otelPath
. $trialPath

$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check([bool]$Condition,[string]$Message) {
    if ($Condition) { $script:checks++ } else { $script:failures.Add($Message) }
}
function Write-Utf8NoBom([string]$Path,[string]$Content) {
    [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))
}
function New-OtlpAttribute([string]$Name,[string]$Kind,$Value) {
    $typedValue = [ordered]@{}
    $typedValue[$Kind] = $Value
    return [ordered]@{key=$Name;value=$typedValue}
}
function New-OtlpPair {
    param(
        [char]$TraceCharacter,
        [char]$OuterCharacter,
        [char]$ChildCharacter,
        [bool]$Warmup = $false,
        [ValidateSet('true','false')][string]$Success = 'true',
        [string]$ParentSpanId = '',
        [string]$Duration = '8'
    )
    $traceId = ((@([string]$TraceCharacter) * 32) -join '')
    $outerId = ((@([string]$OuterCharacter) * 16) -join '')
    $childId = ((@([string]$ChildCharacter) * 16) -join '')
    if ([string]::IsNullOrEmpty($ParentSpanId)) { $ParentSpanId = $outerId }
    $eventAttributes = [Collections.Generic.List[object]]::new()
    foreach ($attribute in @(
        (New-OtlpAttribute 'event.name' 'stringValue' 'codex.websocket_request'),
        (New-OtlpAttribute 'success' 'stringValue' $Success),
        (New-OtlpAttribute 'model' 'stringValue' 'gpt-5.6-sol'),
        (New-OtlpAttribute 'app.version' 'stringValue' '0.144.4'),
        (New-OtlpAttribute 'duration_ms' 'stringValue' $Duration),
        (New-OtlpAttribute 'auth.connection_reused' 'boolValue' $false)
    )) { [void]$eventAttributes.Add($attribute) }
    if ($Success -ceq 'false') { [void]$eventAttributes.Add((New-OtlpAttribute 'error.message' 'stringValue' 'fixture send failure')) }
    $outer = [ordered]@{
        traceId = $traceId
        spanId = $outerId
        parentSpanId = ''
        name = 'model_client.stream_responses_websocket'
        attributes = @(
            (New-OtlpAttribute 'model' 'stringValue' 'gpt-5.6-sol'),
            (New-OtlpAttribute 'wire_api' 'stringValue' 'responses'),
            (New-OtlpAttribute 'transport' 'stringValue' 'responses_websocket'),
            (New-OtlpAttribute 'api.path' 'stringValue' 'responses'),
            (New-OtlpAttribute 'websocket.warmup' 'boolValue' $Warmup)
        )
        events = @()
    }
    $child = [ordered]@{
        traceId = $traceId
        spanId = $childId
        parentSpanId = $ParentSpanId
        name = 'responses_websocket.stream_request'
        attributes = @(
            (New-OtlpAttribute 'transport' 'stringValue' 'responses_websocket'),
            (New-OtlpAttribute 'api.path' 'stringValue' 'responses')
        )
        events = @([ordered]@{name='unstable-source-location';attributes=@($eventAttributes)})
    }
    return @($outer,$child)
}
function Write-OtlpRequest {
    param([string]$Root,[int]$Number,[object[]]$Spans,[string]$ServiceName='codex_exec',[string]$ServiceVersion='0.144.4',[int]$Round=1)
    [void][IO.Directory]::CreateDirectory($Root)
    $stem = Join-Path $Root ('request-{0:d4}' -f $Number)
    Write-Utf8NoBom "$stem.meta.json" ([ordered]@{path="/v1/traces/round-$Round";content_type='application/json'} | ConvertTo-Json -Compress)
    $payload = [ordered]@{
        resourceSpans = @([ordered]@{
            resource = [ordered]@{attributes=@(
                (New-OtlpAttribute 'service.name' 'stringValue' $ServiceName),
                (New-OtlpAttribute 'service.version' 'stringValue' $ServiceVersion)
            )}
            scopeSpans = @([ordered]@{spans=@($Spans)})
        })
    }
    Write-Utf8NoBom "$stem.json" ($payload | ConvertTo-Json -Compress -Depth 100)
}
function Get-FixtureResult([string]$Root) {
    return Get-CodexOtelModelRequests -TraceRoot $Root -FreshSessions 1 -Model 'gpt-5.6-sol' -ExpectedVersion '0.144.4'
}
function Register-TestOtlpIdentity {
    param([Parameter(Mandatory)]$Collector,[Parameter(Mandatory)][int]$ProcessId,[Parameter(Mandatory)][int64]$StartFileTime,[int]$Round=1)
    $identityText = ([ordered]@{
        schema_version='host-benchmark-otel-client/v1';collector_instance_id=[string]$Collector.collector_instance_id;round=$Round
        process_id=$ProcessId;start_time_filetime_utc=$StartFileTime
    } | ConvertTo-Json -Compress)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($identityText)
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $tempPath = [string]$Collector.identity_path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    Write-Utf8NoBom $tempPath $identityText
    [IO.File]::Move($tempPath,[string]$Collector.identity_path)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while ([DateTimeOffset]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath ([string]$Collector.accepted_path) -PathType Leaf)) { Start-Sleep -Milliseconds 20 }
    if (-not (Test-Path -LiteralPath ([string]$Collector.accepted_path) -PathType Leaf)) { return $false }
    try {
        $ack = [IO.File]::ReadAllText([string]$Collector.accepted_path,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 5
        $valid = [string]$ack.schema_version -ceq 'host-benchmark-otel-client-ack/v1' -and [string]$ack.collector_instance_id -ceq [string]$Collector.collector_instance_id -and [int]$ack.round -eq $Round -and [string]$ack.identity_sha256 -ceq $digest
        [IO.File]::Delete([string]$Collector.identity_path)
        [IO.File]::Delete([string]$Collector.accepted_path)
        return $valid -and -not (Test-Path -LiteralPath ([string]$Collector.identity_path)) -and -not (Test-Path -LiteralPath ([string]$Collector.accepted_path))
    } catch { return $false }
}
function Invoke-TestOtlpPost {
    param([Parameter(Mandatory)][int]$Port)
    $client = [Net.Http.HttpClient]::new()
    $content = [Net.Http.ByteArrayContent]::new([Text.Encoding]::UTF8.GetBytes('{"resourceSpans":[]}'))
    $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
    try {
        $response = $client.PostAsync("http://127.0.0.1:$Port/v1/traces/round-1",$content).GetAwaiter().GetResult()
        try { return [int]$response.StatusCode } finally { $response.Dispose() }
    } catch { return -1 }
    finally { $content.Dispose(); $client.Dispose() }
}

$stuckProcess = [pscustomobject]@{HasExited=$false;kill_calls=0;wait_calls=0}
$stuckProcess | Add-Member ScriptMethod Kill { param([bool]$EntireProcessTree) $this.kill_calls++; throw 'simulated kill failure' }
$stuckProcess | Add-Member ScriptMethod WaitForExit { param([int]$TimeoutMilliseconds) $this.wait_calls++; return $false }
Check (-not (Confirm-OtlpProcessExit -Process $stuckProcess -Kill -TimeoutMilliseconds 1) -and $stuckProcess.kill_calls -eq 1 -and $stuckProcess.wait_calls -eq 1) 'failed kill/wait was not preserved as a pending collector cleanup'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dev-harness-otel-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$collectors = [Collections.Generic.List[object]]::new()
try {
    $pendingSafetyRoot = Join-Path $tempRoot 'pending-final-cleanup'
    $pendingResultRoot = Join-Path $pendingSafetyRoot 'result'
    $pendingTraceRoot = Join-Path $pendingResultRoot 'otel-traces'
    [void][IO.Directory]::CreateDirectory($pendingTraceRoot)
    Write-Utf8NoBom (Join-Path $pendingTraceRoot 'request-0001.json') '{}'
    $pendingTrialResult = [ordered]@{status='unavailable';diagnostic='otel-collector-cleanup-pending';completion_passed=$false;raw_trace_deleted=$false;post_trial_diagnostics=@('otel-collector-cleanup-pending')}
    $pendingCleanup = [ordered]@{collector=[ordered]@{process=$null};trace_root=$pendingTraceRoot;result_root=$pendingResultRoot;safety_root=$pendingSafetyRoot;trial_result=$pendingTrialResult;prior_status='unavailable';prior_diagnostic='otel-collector-stop-failed';prior_completion_passed=$false}
    $pendingCompleted = Complete-HostPendingOtlpCleanup -Pending $pendingCleanup
    Check ($pendingCompleted -and -not (Test-Path -LiteralPath $pendingTraceRoot) -and [bool]$pendingTrialResult.raw_trace_deleted -and [string]$pendingTrialResult.diagnostic -ceq 'otel-collector-stop-failed' -and @($pendingTrialResult.post_trial_diagnostics).Count -eq 0) 'final pending cleanup did not delete raw trace independently of scratch retention'

    $startFailureRoot = Join-Path $tempRoot 'collector-start-failure'
    [void][IO.Directory]::CreateDirectory($startFailureRoot)
    $startFailureCollector = Start-OtlpCollector -CollectorPath (Join-Path $tempRoot 'missing-receiver.ps1') -ResultRoot $startFailureRoot -TimeoutSeconds 1
    [void]$collectors.Add($startFailureCollector)
    Check ([string]$startFailureCollector.status -ceq 'unavailable' -and $null -eq $startFailureCollector.process -and -not [bool]$startFailureCollector.cleanup_pending) 'exited collector start failure did not release its process handle'
    Check (-not (Test-Path -LiteralPath $startFailureCollector.ready_path) -and -not (Test-Path -LiteralPath $startFailureCollector.stop_path) -and -not (Test-Path -LiteralPath $startFailureCollector.identity_path) -and -not (Test-Path -LiteralPath $startFailureCollector.accepted_path)) 'exited collector start failure left control files behind'

    $successRoot = Join-Path $tempRoot 'success'
    $successSpans = @(
        New-OtlpPair -TraceCharacter '1' -OuterCharacter 'a' -ChildCharacter 'b' -Warmup $true
        New-OtlpPair -TraceCharacter '2' -OuterCharacter 'c' -ChildCharacter 'd'
    )
    Write-OtlpRequest -Root $successRoot -Number 1 -Spans $successSpans
    $result = Get-FixtureResult $successRoot
    Check ([string]$result.status -ceq 'measured' -and [int]$result.value -eq 1) 'successful child send was not measured or warmup was counted'
    Check ([string]$result.basis -ceq 'codex-0.144.4-successful-websocket-send/v2') 'OTel parser returned the wrong contract id'

    $duplicateRoot = Join-Path $tempRoot 'duplicate'
    $duplicateSpans = @(New-OtlpPair -TraceCharacter '3' -OuterCharacter 'e' -ChildCharacter 'f')
    Write-OtlpRequest -Root $duplicateRoot -Number 1 -Spans $duplicateSpans
    Write-OtlpRequest -Root $duplicateRoot -Number 2 -Spans $duplicateSpans
    $result = Get-FixtureResult $duplicateRoot
    Check ([string]$result.status -ceq 'measured' -and [int]$result.value -eq 1) 'identical repeated OTLP batches were double counted'

    $crossRoundRoot = Join-Path $tempRoot 'cross-round-duplicate'
    $crossRoundSpans = @(New-OtlpPair -TraceCharacter 'a' -OuterCharacter 'b' -ChildCharacter 'c')
    Write-OtlpRequest -Root $crossRoundRoot -Number 1 -Spans $crossRoundSpans -Round 1
    Write-OtlpRequest -Root $crossRoundRoot -Number 2 -Spans $crossRoundSpans -Round 2
    $result = Get-CodexOtelModelRequests -TraceRoot $crossRoundRoot -FreshSessions 2 -Model 'gpt-5.6-sol' -ExpectedVersion '0.144.4'
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-span-cross-round-conflict') 'cross-round duplicate span identity was counted twice'

    $conflictRoot = Join-Path $tempRoot 'duplicate-conflict'
    Write-OtlpRequest -Root $conflictRoot -Number 1 -Spans @(New-OtlpPair -TraceCharacter '4' -OuterCharacter '1' -ChildCharacter '2' -Duration '8')
    Write-OtlpRequest -Root $conflictRoot -Number 2 -Spans @(New-OtlpPair -TraceCharacter '4' -OuterCharacter '1' -ChildCharacter '2' -Duration '9')
    $result = Get-FixtureResult $conflictRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-span-duplicate-conflict') 'conflicting duplicate span was not fail closed'

    $failedRoot = Join-Path $tempRoot 'failed-send'
    Write-OtlpRequest -Root $failedRoot -Number 1 -Spans @(New-OtlpPair -TraceCharacter '5' -OuterCharacter '3' -ChildCharacter '4' -Success 'false')
    $result = Get-FixtureResult $failedRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-websocket-send-failed') 'failed WebSocket send did not make the metric unavailable'

    $orphanRoot = Join-Path $tempRoot 'orphan'
    $orphanParent = ((@('9') * 16) -join '')
    Write-OtlpRequest -Root $orphanRoot -Number 1 -Spans @(New-OtlpPair -TraceCharacter '6' -OuterCharacter '5' -ChildCharacter '6' -ParentSpanId $orphanParent)
    $result = Get-FixtureResult $orphanRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-websocket-send-orphan') 'orphan WebSocket child span was accepted'

    $badIdRoot = Join-Path $tempRoot 'bad-id'
    $badIdSpans = @(New-OtlpPair -TraceCharacter '7' -OuterCharacter '7' -ChildCharacter '8')
    $badIdSpans[0].traceId = 'not-a-trace-id'
    Write-OtlpRequest -Root $badIdRoot -Number 1 -Spans $badIdSpans
    $result = Get-FixtureResult $badIdRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-trace-id-invalid') 'invalid OTLP trace id was accepted'

    $uppercaseIdRoot = Join-Path $tempRoot 'uppercase-id'
    $uppercaseIdSpans = @(New-OtlpPair -TraceCharacter 'b' -OuterCharacter 'd' -ChildCharacter 'e')
    $uppercaseIdSpans[0].traceId = ([string]$uppercaseIdSpans[0].traceId).ToUpperInvariant()
    Write-OtlpRequest -Root $uppercaseIdRoot -Number 1 -Spans $uppercaseIdSpans
    $result = Get-FixtureResult $uppercaseIdRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-trace-id-invalid') 'non-canonical uppercase OTLP id was accepted'

    $wrongExpectedVersion = Get-CodexOtelModelRequests -TraceRoot $successRoot -FreshSessions 1 -Model 'gpt-5.6-sol' -ExpectedVersion '0.145.0'
    Check ([string]$wrongExpectedVersion.status -ceq 'unavailable' -and [string]$wrongExpectedVersion.reason -ceq 'otel-service-version-unsupported') 'parser contract accepted a non-0.144.4 expected version'

    $serviceVersionRoot = Join-Path $tempRoot 'service-version-mismatch'
    Write-OtlpRequest -Root $serviceVersionRoot -Number 1 -Spans @(New-OtlpPair -TraceCharacter 'c' -OuterCharacter 'f' -ChildCharacter '1') -ServiceVersion '0.145.0'
    $result = Get-FixtureResult $serviceVersionRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-trace-contract-mismatch') 'trace with mismatched service.version was accepted'

    $durationRoot = Join-Path $tempRoot 'bad-duration'
    $durationSpans = @(New-OtlpPair -TraceCharacter 'd' -OuterCharacter '2' -ChildCharacter '3')
    (@($durationSpans[1].events[0].attributes | Where-Object { $_.key -ceq 'duration_ms' }))[0].value.stringValue = 'not-a-duration'
    Write-OtlpRequest -Root $durationRoot -Number 1 -Spans $durationSpans
    $result = Get-FixtureResult $durationRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-trace-contract-mismatch') 'nonnumeric duration_ms was accepted'

    $boolTypeRoot = Join-Path $tempRoot 'bad-bool-type'
    $boolTypeSpans = @(New-OtlpPair -TraceCharacter 'e' -OuterCharacter '4' -ChildCharacter '5')
    (@($boolTypeSpans[0].attributes | Where-Object { $_.key -ceq 'websocket.warmup' }))[0].value.boolValue = 'false'
    Write-OtlpRequest -Root $boolTypeRoot -Number 1 -Spans $boolTypeSpans
    $result = Get-FixtureResult $boolTypeRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-trace-contract-mismatch') 'string-valued websocket.warmup was accepted as bool'

    $duplicateErrorRoot = Join-Path $tempRoot 'duplicate-error-attribute'
    $duplicateErrorSpans = @(New-OtlpPair -TraceCharacter 'f' -OuterCharacter '6' -ChildCharacter '7')
    $duplicateErrorSpans[1].events[0].attributes += @(
        (New-OtlpAttribute 'error.message' 'stringValue' 'unexpected-one'),
        (New-OtlpAttribute 'error.message' 'stringValue' 'unexpected-two')
    )
    Write-OtlpRequest -Root $duplicateErrorRoot -Number 1 -Spans $duplicateErrorSpans
    $result = Get-FixtureResult $duplicateErrorRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-trace-contract-mismatch') 'duplicate success-event error.message attributes were treated as absent'

    $serviceRoot = Join-Path $tempRoot 'service-name-conflict'
    $serviceSpans = @(New-OtlpPair -TraceCharacter '8' -OuterCharacter '9' -ChildCharacter 'a')
    Write-OtlpRequest -Root $serviceRoot -Number 1 -Spans @($serviceSpans[0]) -ServiceName 'codex_exec'
    Write-OtlpRequest -Root $serviceRoot -Number 2 -Spans @($serviceSpans[1]) -ServiceName 'Codex Desktop'
    $result = Get-FixtureResult $serviceRoot
    Check ([string]$result.status -ceq 'unavailable' -and [string]$result.reason -ceq 'otel-service-name-inconsistent') 'inconsistent nonempty service.name values were accepted'

    $collectorRoot = Join-Path $tempRoot 'collector-authorized'
    [void][IO.Directory]::CreateDirectory($collectorRoot)
    Write-Utf8NoBom (Join-Path $collectorRoot 'otel-ready.json') '{"port":65535,"parent_process_id":1}'
    Write-Utf8NoBom (Join-Path $collectorRoot 'otel-stop') 'stale'
    $collector = Start-OtlpCollector -CollectorPath $collectorPath -ResultRoot $collectorRoot -TimeoutSeconds 30
    [void]$collectors.Add($collector)
    Check ([string]$collector.status -ceq 'measured') 'OTLP receiver did not become ready'
    $stopped = $false
    if ([string]$collector.status -ceq 'measured') {
        try {
            $currentProcess = Get-Process -Id $PID
            $registered = Register-TestOtlpIdentity -Collector $collector -ProcessId $PID -StartFileTime $currentProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
            $currentProcess.Dispose()
            Check $registered 'OTLP receiver did not acknowledge an exact pre-prompt client identity'
            $statusCode = if ($registered) { Invoke-TestOtlpPost -Port $collector.port } else { -1 }
            Check ($statusCode -eq 200) 'OTLP receiver did not accept a POST from the registered process'
            $metaFiles = @(Get-ChildItem -LiteralPath $collector.trace_root -Filter 'request-*.meta.json' -File)
            Check ($metaFiles.Count -eq 1) 'OTLP receiver did not persist exactly one request metadata file'
            if ($metaFiles.Count -eq 1) {
                $meta = Get-Content -LiteralPath $metaFiles[0].FullName -Raw -Encoding utf8 | ConvertFrom-Json
                Check ([string]$meta.path -ceq '/v1/traces/round-1' -and [string]$meta.content_type -ceq 'application/json') 'OTLP receiver persisted a non-exact path or content type'
            }
            $bodyPath = Join-Path $collector.trace_root 'request-0001.json'
            $writeBlocked = $false
            try { $tamperStream = [IO.FileStream]::new($bodyPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite); $tamperStream.Dispose() } catch { $writeBlocked = $true }
            Check $writeBlocked 'collector did not hold its trace file against in-flight write/delete tampering'
        } catch {
            $failures.Add("OTLP receiver POST failed: $($_.Exception.Message)")
        } finally {
            $stopped = Stop-OtlpCollector -Collector $collector
        }
        Check $stopped 'OTLP receiver did not stop cleanly'
        Check ($null -eq $collector.process) 'OTLP collector process handle was not disposed after stop'
        if ($stopped) {
            $manifestResult = Test-OtlpTraceManifest -TraceRoot $collector.trace_root -Manifest $collector.manifest -ExpectedInstanceId $collector.collector_instance_id -FreshSessions 1
            Check ([string]$manifestResult.status -ceq 'measured') 'collector stdout manifest did not authenticate the exact trace file set'
            Check (-not (Test-Path -LiteralPath $collector.ready_path) -and -not (Test-Path -LiteralPath $collector.stop_path) -and -not (Test-Path -LiteralPath $collector.identity_path) -and -not (Test-Path -LiteralPath $collector.accepted_path)) 'collector left PID-bearing or identity control files behind'
            Write-Utf8NoBom (Join-Path $collector.trace_root 'request-0001.json') '{"resourceSpans":[{"tampered":true}]}'
            $tampered = Test-OtlpTraceManifest -TraceRoot $collector.trace_root -Manifest $collector.manifest -ExpectedInstanceId $collector.collector_instance_id -FreshSessions 1
            Check ([string]$tampered.status -ceq 'unavailable') 'post-collector trace modification was not rejected by the authenticated manifest'
            Write-Utf8NoBom (Join-Path $collector.trace_root 'request-0001.json') '{"resourceSpans":[]}'
            Write-Utf8NoBom (Join-Path $collector.trace_root 'request-9999.json') '{}'
            $extraFile = Test-OtlpTraceManifest -TraceRoot $collector.trace_root -Manifest $collector.manifest -ExpectedInstanceId $collector.collector_instance_id -FreshSessions 1
            Check ([string]$extraFile.status -ceq 'unavailable') 'extra trace files were not rejected by the authenticated manifest'
        }
    }

    $injectionRoot = Join-Path $tempRoot 'collector-child-injection'
    [void][IO.Directory]::CreateDirectory($injectionRoot)
    $injectionCollector = Start-OtlpCollector -CollectorPath $collectorPath -ResultRoot $injectionRoot -TimeoutSeconds 30
    [void]$collectors.Add($injectionCollector)
    Check ([string]$injectionCollector.status -ceq 'measured') 'child-injection collector did not become ready'
    if ([string]$injectionCollector.status -ceq 'measured') {
        try {
            $currentProcess = Get-Process -Id $PID
            $registeredParent = $currentProcess.Parent
            Check ($null -ne $registeredParent -and -not $registeredParent.HasExited) 'test host has no live parent process for the child-injection seam'
            $registered = $false
            if ($null -ne $registeredParent -and -not $registeredParent.HasExited) {
                $registered = Register-TestOtlpIdentity -Collector $injectionCollector -ProcessId $registeredParent.Id -StartFileTime $registeredParent.StartTime.ToUniversalTime().ToFileTimeUtc()
            }
            $currentProcess.Dispose()
            if ($null -ne $registeredParent) { $registeredParent.Dispose() }
            Check $registered 'child-injection collector did not register the test process parent'
            $childStatus = if ($registered) { Invoke-TestOtlpPost -Port $injectionCollector.port } else { -1 }
            Check ($childStatus -ne 200) 'a child of the registered process injected an accepted OTLP request'
            if (-not $injectionCollector.process.HasExited) { [void]$injectionCollector.process.WaitForExit(5000) }
            Check ($injectionCollector.process.HasExited -and $injectionCollector.process.ExitCode -ne 0) 'owner mismatch did not fail the collector closed'
            $collectorError = $injectionCollector.stderr_task.GetAwaiter().GetResult()
            Check ($collectorError -match 'owner does not match a registered Codex process') 'child injection did not fail for the expected owner-provenance reason'
            Check (@(Get-ChildItem -LiteralPath $injectionCollector.trace_root -Force).Count -eq 0) 'unauthorized child injection wrote a trace artifact'
        } finally {
            $injectionStopped = Stop-OtlpCollector -Collector $injectionCollector
        }
        Check (-not $injectionStopped) 'collector with an unauthorized child connection was reported as measured'
        Check ($null -eq $injectionCollector.process) 'failed collector stop did not dispose the exited process handle'
        Check (-not (Test-Path -LiteralPath $injectionCollector.ready_path) -and -not (Test-Path -LiteralPath $injectionCollector.stop_path) -and -not (Test-Path -LiteralPath $injectionCollector.identity_path) -and -not (Test-Path -LiteralPath $injectionCollector.accepted_path)) 'failed collector stop left PID-bearing or identity control files behind'
    }

    $receiverText = Get-Content -LiteralPath $collectorPath -Raw -Encoding utf8
    Check ($receiverText -match "\^/v1/traces/round-\[1-9\]\[0-9\]\*\$" -and $receiverText -match "content-type.*application/json" -and $receiverText -match 'ReadTimeout' -and $receiverText -match 'WriteTimeout' -and $receiverText -match 'MaxRequests' -and $receiverText -match 'MaxTotalBodyBytes' -and $receiverText -match 'ExpectedClientIdentityPath' -and $receiverText -match '\[Environment\]::SystemDirectory' -and $receiverText -match 'netstat\.exe' -and $receiverText -match "@\('-ano','-p','tcp'\)" -and $receiverText -match 'ProcessStartInfo' -and $receiverText -match 'ArgumentList\.Add' -and $receiverText -match 'WaitForExit\(\$TimeoutMilliseconds\)' -and $receiverText -match 'Kill\(\$true\)' -and $receiverText -match 'owner lookup exceeded' -and $receiverText -match 'expectedLocalEndpoint' -and $receiverText -match 'expectedRemoteEndpoint' -and $receiverText -match '\$owners\.Count -gt 1' -and $receiverText -match '\$owners\.Count -eq 1' -and $receiverText -match 'owner lookup returned no process' -and $receiverText -match 'start_time_filetime_utc' -and $receiverText -match 'FileMode\]::CreateNew' -and $receiverText -match 'FileShare\]::Read') 'bounded provenance-bound receiver contract is incomplete'
    Check ($receiverText -notmatch '(?i)Add-Type|DllImport|GetExtendedTcpTable|Marshal\.|Get-NetTCPConnection' -and $receiverText -notmatch '(?i)ExecutionPolicy|Bypass|CreateNoWindow') 'receiver owner lookup is dynamically compiled, opaque, or policy-bypassing'

    $savedPath = $env:PATH
    try {
        $env:PATH = ''
        $hostPath = (Get-Process -Id $PID).Path
        $invalidEndpoints = @(
            'http://localhost:4318/v1/traces/round-1',
            'https://127.0.0.1:4318/v1/traces/round-1',
            'http://127.0.0.1:4318/v1/traces/round-0',
            'http://127.0.0.1:4318/V1/traces/round-1',
            'http://127.0.0.1:4318/v1/traces/round-1?unexpected=1'
        )
        for ($index=0; $index -lt $invalidEndpoints.Count; $index++) {
            $outputPath = Join-Path $tempRoot ("invalid-endpoint-$index.md")
            $output = @(& $hostPath -NoLogo -NoProfile -NonInteractive -File $wrapperPath -Task 'must not invoke a model' -Workspace $RepoRoot -Output $outputPath -OtelTraceEndpoint $invalidEndpoints[$index] 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
            Check ($exitCode -ne 0 -and ($output -join "`n") -match 'OtelTraceEndpoint must be an absolute loopback HTTP URL') "invalid OTLP endpoint was not rejected before model lookup: $($invalidEndpoints[$index])"
            Check (-not (Test-Path -LiteralPath $outputPath)) "invalid OTLP endpoint created an output artifact: $($invalidEndpoints[$index])"
        }
        $missingIdentityOutput = Join-Path $tempRoot 'missing-identity.md'
        $missingIdentity = @(& $hostPath -NoLogo -NoProfile -NonInteractive -File $wrapperPath -Task 'must not invoke a model' -Workspace $RepoRoot -Output $missingIdentityOutput -OtelTraceEndpoint 'http://127.0.0.1:4318/v1/traces/round-1' 2>&1 | ForEach-Object { [string]$_ })
        Check ($LASTEXITCODE -ne 0 -and ($missingIdentity -join "`n") -match 'must be provided together' -and -not (Test-Path -LiteralPath $missingIdentityOutput)) 'valid OTLP endpoint without process identity controls reached model lookup or wrote output'
    } finally {
        $env:PATH = $savedPath
    }
} finally {
    foreach ($collector in $collectors) {
        if ($null -ne $collector.process -and -not $collector.process.HasExited) {
            try { $collector.process.Kill($true); $collector.process.WaitForExit() } catch {}
        }
        if ($null -ne $collector.process) { $collector.process.Dispose() }
    }
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($systemTemp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTemp) -like 'dev-harness-otel-test-*') {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output "Host benchmark OTel checks: $checks"
if ($failures.Count) {
    $failures | ForEach-Object { Write-Output "- FAIL: $_" }
    exit 1
}
Write-Output "STATUS: PASS ($checks checks)"
exit 0
