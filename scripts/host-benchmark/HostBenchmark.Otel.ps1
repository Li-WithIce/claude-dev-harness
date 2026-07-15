function Start-OtlpCollector {
    param([Parameter(Mandatory)][string]$CollectorPath,[Parameter(Mandatory)][string]$ResultRoot,[Parameter(Mandatory)][int]$TimeoutSeconds)
    # Release-qualification-only helper; not part of the installed core runtime.
    $traceRoot = Join-Path $ResultRoot 'otel-traces'
    $readyPath = Join-Path $ResultRoot 'otel-ready.json'
    $stopPath = Join-Path $ResultRoot 'otel-stop'
    $identityPath = Join-Path $ResultRoot 'otel-client-identity.json'
    $acceptedPath = $identityPath + '.accepted'
    [void][IO.Directory]::CreateDirectory($traceRoot)
    $controlPaths = @($identityPath,$acceptedPath,$readyPath,$stopPath)
    $process = $null
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if (@(Get-ChildItem -LiteralPath $traceRoot -Force -ErrorAction Stop).Count -ne 0) { throw 'collector trace root is not empty' }
        if (-not (Remove-OtlpControlFiles -Paths $controlPaths)) { throw 'collector controls could not be initialized' }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$CollectorPath,'-Port','0','-OutputDirectory',$traceRoot,'-ReadyPath',$readyPath,'-StopPath',$stopPath,'-TimeoutSeconds',[string]$TimeoutSeconds,'-ParentProcessId',[string]$PID,'-ExpectedClientIdentityPath',$identityPath)) { $startInfo.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
        while ([DateTimeOffset]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $readyPath -PathType Leaf) -and -not $process.HasExited) { Start-Sleep -Milliseconds 50 }
        if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf) -or $process.HasExited) { throw 'collector did not become ready' }
        $ready = [IO.File]::ReadAllText($readyPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 5
        $port = [int]$ready.port
        $instanceId = [string]$ready.collector_instance_id
        if ($port -le 0 -or $port -gt 65535 -or [int]$ready.parent_process_id -ne $PID -or $instanceId -cnotmatch '^[0-9a-f]{32}$' -or [string]$ready.provenance -cne 'verified-owner-pid-start-time/v1') { throw 'collector returned an invalid identity' }
        return [ordered]@{
            status='measured';process=$process;trace_root=$traceRoot;ready_path=$readyPath;stop_path=$stopPath
            identity_path=$identityPath;accepted_path=$acceptedPath;port=$port;collector_instance_id=$instanceId
            provenance='verified-owner-pid-start-time/v1';stdout_task=$stdoutTask;stderr_task=$stderrTask;manifest=$null;cleanup_pending=$false
        }
    } catch {
        $processExited = $null -eq $process
        if ($null -ne $process) {
            $processExited = Confirm-OtlpProcessExit -Process $process -Kill
            if ($processExited) {
                try { if ($null -ne $stdoutTask) { $null = $stdoutTask.GetAwaiter().GetResult() } } catch {}
                try { if ($null -ne $stderrTask) { $null = $stderrTask.GetAwaiter().GetResult() } } catch {}
                $process.Dispose()
                $process = $null
                $stdoutTask = $null
                $stderrTask = $null
            }
        }
        if ($processExited) { [void](Remove-OtlpControlFiles -Paths $controlPaths) }
        return [ordered]@{status='unavailable';process=$process;trace_root=$traceRoot;ready_path=$readyPath;stop_path=$stopPath;identity_path=$identityPath;accepted_path=$acceptedPath;port=$null;collector_instance_id=$null;stdout_task=$stdoutTask;stderr_task=$stderrTask;manifest=$null;cleanup_pending=$null-ne$process;reason=$(if($null-eq$process){'otel-collector-start-failed'}else{'otel-collector-start-cleanup-failed'})}
    }
}

$script:HostPendingOtlpCollectors = [Collections.Generic.List[object]]::new()

function Confirm-OtlpProcessExit {
    param([Parameter(Mandatory)]$Process,[switch]$Kill,[int]$TimeoutMilliseconds=10000)
    try { if ($Process.HasExited) { return $true } } catch { return $false }
    if ($Kill) { try { $Process.Kill($true) } catch {} }
    try {
        if ($Process.HasExited) { return $true }
        if (-not $Process.WaitForExit($TimeoutMilliseconds)) { return $false }
        return $Process.HasExited
    } catch {
        try { return $Process.HasExited } catch { return $false }
    }
}

function Remove-OtlpControlFiles {
    param([string[]]$Paths)
    $removed = $true
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try {
            if (Test-Path -LiteralPath $path) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $removed = $false; continue }
                [IO.File]::Delete([IO.Path]::GetFullPath($path))
            }
        } catch { $removed = $false }
    }
    return $removed
}

function Stop-OtlpCollector {
    param([Parameter(Mandatory)]$Collector)
    if ($null -eq $Collector.process) { return $false }
    $process = $Collector.process
    $success = $false
    $processExited = $false
    try {
        if ([string]$Collector.status -cne 'measured') { throw 'collector was unavailable before stop' }
        if ($process.HasExited) { throw 'collector exited before the parent stop signal' }
        $stopBytes = [Text.UTF8Encoding]::new($false).GetBytes('stop')
        $stopStream = [IO.FileStream]::new([string]$Collector.stop_path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stopStream.Write($stopBytes,0,$stopBytes.Length); $stopStream.Flush($true) } finally { $stopStream.Dispose() }
        if (-not (Confirm-OtlpProcessExit -Process $process)) { throw 'collector did not stop within the bounded grace period' }
        $processExited = $true
        $stdout = $Collector.stdout_task.GetAwaiter().GetResult()
        $null = $Collector.stderr_task.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'collector exited unsuccessfully' }
        $lines = @($stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -ne 1) { throw 'collector manifest channel was not exact' }
        $manifest = $lines[0] | ConvertFrom-Json -AsHashtable -Depth 20
        if ([string]$manifest.schema_version -cne 'host-benchmark-otel-manifest/v1' -or [string]$manifest.provenance -cne [string]$Collector.provenance -or [string]$manifest.collector_instance_id -cne [string]$Collector.collector_instance_id) { throw 'collector manifest identity is invalid' }
        $Collector.manifest = $manifest
        $success = $true
    } catch {
        $processExited = Confirm-OtlpProcessExit -Process $process -Kill
        if ($processExited) {
            try { if ($null -ne $Collector.stdout_task) { $null = $Collector.stdout_task.GetAwaiter().GetResult() } } catch {}
            try { if ($null -ne $Collector.stderr_task) { $null = $Collector.stderr_task.GetAwaiter().GetResult() } } catch {}
        }
    } finally {
        if ($processExited) {
            $controlRemoved = Remove-OtlpControlFiles -Paths @([string]$Collector.identity_path,[string]$Collector.accepted_path,[string]$Collector.ready_path,[string]$Collector.stop_path)
            if (-not $controlRemoved) { $success = $false }
            $process.Dispose()
            $Collector.process = $null
            $Collector.stdout_task = $null
            $Collector.stderr_task = $null
            $Collector.cleanup_pending = $false
        } else {
            $success = $false
            $Collector.cleanup_pending = $true
        }
    }
    return $success
}

function Test-OtlpTraceManifest {
    param(
        [Parameter(Mandatory)][string]$TraceRoot,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ExpectedInstanceId,
        [Parameter(Mandatory)][ValidateRange(1,100000)][int]$FreshSessions
    )
    try {
        if ([string]$Manifest.schema_version -cne 'host-benchmark-otel-manifest/v1' -or [string]$Manifest.provenance -cne 'verified-owner-pid-start-time/v1' -or [string]$Manifest.collector_instance_id -cne $ExpectedInstanceId) { throw 'manifest identity mismatch' }
        $registeredRounds = @($Manifest.registered_rounds | ForEach-Object { [int]$_ })
        $expectedRounds = @(1..$FreshSessions)
        if ($registeredRounds.Count -ne $expectedRounds.Count -or @(Compare-Object $registeredRounds $expectedRounds -SyncWindow 0).Count -ne 0) { throw 'manifest round registration mismatch' }
        $requestCount = [int]$Manifest.request_count
        if ($requestCount -lt 0) { throw 'manifest request count is invalid' }
        $entries = @($Manifest.files)
        if ($entries.Count -ne (2 * $requestCount)) { throw 'manifest file count is invalid' }
        $expectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $requests = @{}
        foreach ($entry in $entries) {
            $entryKeys = @($entry.Keys | ForEach-Object { [string]$_ } | Sort-Object)
            $requiredKeys = @('bytes','kind','name','request_number','round','sha256') | Sort-Object
            if ($entryKeys.Count -ne $requiredKeys.Count -or @(Compare-Object $entryKeys $requiredKeys -SyncWindow 0).Count -ne 0) { throw 'manifest file entry shape is invalid' }
            $number = [int]$entry.request_number
            $round = [int]$entry.round
            $kind = [string]$entry.kind
            $name = [string]$entry.name
            $expectedStem = 'request-{0:d4}' -f $number
            $expectedName = if ($kind -ceq 'meta') { $expectedStem + '.meta.json' } elseif ($kind -ceq 'body') { $expectedStem + '.json' } else { throw 'manifest file kind is invalid' }
            if ($number -lt 1 -or $number -gt $requestCount -or $round -lt 1 -or $round -gt $FreshSessions -or $name -cne $expectedName -or [int64]$entry.bytes -lt 0 -or [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not $expectedNames.Add($name)) { throw 'manifest file identity is invalid' }
            $path = Join-Path $TraceRoot $name
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -ne [int64]$entry.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$entry.sha256) { throw 'manifest file digest is invalid' }
            if (-not $requests.ContainsKey([string]$number)) { $requests[[string]$number] = [ordered]@{round=$round;kinds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)} }
            if ([int]$requests[[string]$number].round -ne $round -or -not $requests[[string]$number].kinds.Add($kind)) { throw 'manifest request pairing is invalid' }
        }
        if ($requestCount -gt 0) {
            foreach ($number in 1..$requestCount) {
                if (-not $requests.ContainsKey([string]$number) -or $requests[[string]$number].kinds.Count -ne 2) { throw 'manifest request pair is incomplete' }
            }
        }
        $actualItems = @(Get-ChildItem -LiteralPath $TraceRoot -Force -ErrorAction Stop)
        if (@($actualItems | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw 'trace root contains an unexpected directory or link' }
        $actualNames = @($actualItems | ForEach-Object { $_.Name } | Sort-Object)
        $manifestNames = @($expectedNames | Sort-Object)
        if ($actualNames.Count -ne $manifestNames.Count -or @(Compare-Object $actualNames $manifestNames -SyncWindow 0).Count -ne 0) { throw 'trace root differs from the authenticated manifest' }
        return [ordered]@{status='measured';reason=$null;provenance='verified-owner-pid-start-time/v1'}
    } catch {
        return [ordered]@{status='unavailable';reason='otel-trace-manifest-invalid';provenance='verified-owner-pid-start-time/v1'}
    }
}
function Get-OtlpAttribute {
    param([object[]]$Attributes,[Parameter(Mandatory)][string]$Name)
    $matches = @($Attributes | Where-Object { [string]$_.key -ceq $Name })
    if ($matches.Count -ne 1 -or $null -eq $matches[0].value) { return $null }
    $kinds = @()
    foreach ($kind in @('stringValue','boolValue','intValue','doubleValue')) {
        $property = $matches[0].value.PSObject.Properties[$kind]
        if ($null -ne $property) { $kinds += [pscustomobject]@{kind=$kind;value=$property.Value} }
    }
    if ($kinds.Count -ne 1) { return $null }
    if ([string]$kinds[0].kind -ceq 'stringValue' -and $kinds[0].value -isnot [string]) { return $null }
    if ([string]$kinds[0].kind -ceq 'boolValue' -and $kinds[0].value -isnot [bool]) { return $null }
    return $kinds[0]
}
function Get-OtlpAttributeValue {
    param([object[]]$Attributes,[Parameter(Mandatory)][string]$Name)
    $attribute = Get-OtlpAttribute -Attributes $Attributes -Name $Name
    if ($null -eq $attribute) { return $null }
    return $attribute.value
}
function Test-OtlpAttribute {
    param([object[]]$Attributes,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$Kind,[Parameter(Mandatory)]$Expected)
    $attribute = Get-OtlpAttribute -Attributes $Attributes -Name $Name
    return $null -ne $attribute -and [string]$attribute.kind -ceq $Kind -and [object]::Equals($attribute.value,$Expected)
}
function Get-CodexOtelModelRequests {
    param([Parameter(Mandatory)][string]$TraceRoot,[Parameter(Mandatory)][ValidateRange(1,12)][int]$FreshSessions,[Parameter(Mandatory)][string]$Model,[Parameter(Mandatory)][string]$ExpectedVersion)
    $contract = 'codex-0.144.4-successful-websocket-send/v2'
    if ($ExpectedVersion -cne '0.144.4') { return [ordered]@{status='unavailable';value=$null;basis=$contract;reason='otel-service-version-unsupported'} }
    $metaFiles = @(Get-ChildItem -LiteralPath $TraceRoot -Filter 'request-*.meta.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($metaFiles.Count -eq 0) { return [ordered]@{status='unavailable';value=$null;basis=$contract;reason='otel-trace-missing'} }
    $counts = [ordered]@{}
    $spansByRound = [ordered]@{}
    for ($round=1; $round -le $FreshSessions; $round++) {
        $counts[[string]$round] = 0
        $spansByRound[[string]$round] = @{}
    }
    $serviceNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $spanRounds = @{}
    try {
        foreach ($metaFile in $metaFiles) {
            $meta = [IO.File]::ReadAllText($metaFile.FullName,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -Depth 10
            $pathMatch = [regex]::Match([string]$meta.path,'^/v1/traces/round-([1-9][0-9]*)$')
            if (-not $pathMatch.Success) { throw 'otel-trace-path-unsupported' }
            $round = [int]$pathMatch.Groups[1].Value
            if ($round -gt $FreshSessions) { throw 'otel-trace-round-unknown' }
            if ([string]$meta.content_type -cne 'application/json') { throw 'otel-trace-content-type-unsupported' }
            $bodyPath = $metaFile.FullName.Substring(0,$metaFile.FullName.Length-'.meta.json'.Length) + '.json'
            if (-not (Test-Path -LiteralPath $bodyPath -PathType Leaf)) { throw 'otel-trace-body-missing' }
            $payload = [IO.File]::ReadAllText($bodyPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -Depth 100
            foreach ($resourceSpans in @($payload.resourceSpans)) {
                foreach ($scopeSpans in @($resourceSpans.scopeSpans)) {
                    foreach ($span in @($scopeSpans.spans)) {
                        $traceValue = $span.PSObject.Properties['traceId'].Value
                        $spanValue = $span.PSObject.Properties['spanId'].Value
                        $parentProperty = $span.PSObject.Properties['parentSpanId']
                        $parentValue = if ($null -eq $parentProperty) { '' } else { $parentProperty.Value }
                        if ($traceValue -isnot [string] -or $spanValue -isnot [string] -or $parentValue -isnot [string]) { throw 'otel-span-identity-invalid' }
                        $traceId = [string]$traceValue
                        $spanId = [string]$spanValue
                        $parentSpanId = [string]$parentValue
                        if ($traceId -cnotmatch '^[0-9a-f]{32}$' -or $traceId -ceq '00000000000000000000000000000000') { throw 'otel-trace-id-invalid' }
                        if ($spanId -cnotmatch '^[0-9a-f]{16}$' -or $spanId -ceq '0000000000000000') { throw 'otel-span-id-invalid' }
                        if ($parentSpanId.Length -gt 0 -and ($parentSpanId -cnotmatch '^[0-9a-f]{16}$' -or $parentSpanId -ceq '0000000000000000')) { throw 'otel-parent-span-id-invalid' }
                        $key = "$traceId`:$spanId"
                        if ($spanRounds.ContainsKey($key) -and [int]$spanRounds[$key] -ne $round) { throw 'otel-span-cross-round-conflict' }
                        $spanRounds[$key] = $round
                        $scopeProperty = $scopeSpans.PSObject.Properties['scope']
                        $scope = if ($null -eq $scopeProperty) { $null } else { $scopeProperty.Value }
                        $signature = ([ordered]@{resource=$resourceSpans.resource;scope=$scope;span=$span} | ConvertTo-Json -Compress -Depth 100)
                        $roundSpans = $spansByRound[[string]$round]
                        if ($roundSpans.ContainsKey($key)) {
                            if ([string]$roundSpans[$key].signature -cne $signature) { throw 'otel-span-duplicate-conflict' }
                            continue
                        }
                        $roundSpans[$key] = [pscustomobject]@{
                            key = $key
                            trace_id = $traceId
                            span_id = $spanId
                            parent_span_id = $parentSpanId
                            resource_attributes = @($resourceSpans.resource.attributes)
                            span = $span
                            signature = $signature
                        }
                    }
                }
            }
        }

        foreach ($round in 1..$FreshSessions) {
            $outerSpans = @{}
            $childSpans = [Collections.Generic.List[object]]::new()
            foreach ($record in @($spansByRound[[string]$round].Values)) {
                $spanName = [string]$record.span.name
                $apiPath = Get-OtlpAttribute -Attributes @($record.span.attributes) -Name 'api.path'
                $isOuter = $spanName -ceq 'model_client.stream_responses_websocket'
                $isChild = $spanName -ceq 'responses_websocket.stream_request'
                if (-not $isOuter -and -not $isChild) {
                    if ($null -ne $apiPath -and [string]$apiPath.kind -ceq 'stringValue' -and [string]$apiPath.value -ceq 'responses' -and $spanName -like 'model_client.stream*') { throw 'otel-model-transport-unsupported' }
                    continue
                }

                $serviceName = Get-OtlpAttribute -Attributes @($record.resource_attributes) -Name 'service.name'
                $serviceVersion = Get-OtlpAttribute -Attributes @($record.resource_attributes) -Name 'service.version'
                if ($null -eq $serviceName -or [string]$serviceName.kind -cne 'stringValue' -or [string]::IsNullOrWhiteSpace([string]$serviceName.value) -or
                    $null -eq $serviceVersion -or [string]$serviceVersion.kind -cne 'stringValue' -or [string]$serviceVersion.value -cne $ExpectedVersion) { throw 'otel-trace-contract-mismatch' }
                [void]$serviceNames.Add([string]$serviceName.value)

                if ($isOuter) {
                    $warmup = Get-OtlpAttribute -Attributes @($record.span.attributes) -Name 'websocket.warmup'
                    if (-not (Test-OtlpAttribute -Attributes @($record.span.attributes) -Name 'api.path' -Kind 'stringValue' -Expected 'responses') -or
                        -not (Test-OtlpAttribute -Attributes @($record.span.attributes) -Name 'transport' -Kind 'stringValue' -Expected 'responses_websocket') -or
                        -not (Test-OtlpAttribute -Attributes @($record.span.attributes) -Name 'wire_api' -Kind 'stringValue' -Expected 'responses') -or
                        -not (Test-OtlpAttribute -Attributes @($record.span.attributes) -Name 'model' -Kind 'stringValue' -Expected $Model) -or
                        $null -eq $warmup -or [string]$warmup.kind -cne 'boolValue') { throw 'otel-trace-contract-mismatch' }
                    $outerSpans[$record.key] = [pscustomobject]@{record=$record;warmup=[bool]$warmup.value}
                } else {
                    if (-not (Test-OtlpAttribute -Attributes @($record.span.attributes) -Name 'api.path' -Kind 'stringValue' -Expected 'responses') -or
                        -not (Test-OtlpAttribute -Attributes @($record.span.attributes) -Name 'transport' -Kind 'stringValue' -Expected 'responses_websocket')) { throw 'otel-trace-contract-mismatch' }
                    [void]$childSpans.Add($record)
                }
            }

            $childrenByParent = @{}
            foreach ($child in $childSpans) {
                $parentKey = "$($child.trace_id)`:$($child.parent_span_id)"
                if ([string]::IsNullOrEmpty([string]$child.parent_span_id) -or -not $outerSpans.ContainsKey($parentKey)) { throw 'otel-websocket-send-orphan' }
                if (-not $childrenByParent.ContainsKey($parentKey)) { $childrenByParent[$parentKey] = [Collections.Generic.List[object]]::new() }
                [void]$childrenByParent[$parentKey].Add($child)
            }

            foreach ($outerKey in @($outerSpans.Keys)) {
                $children = @($childrenByParent[$outerKey])
                if ($children.Count -eq 0) { throw 'otel-websocket-send-missing' }
                if ($children.Count -ne 1) { throw 'otel-trace-contract-mismatch' }
                $events = @()
                foreach ($event in @($children[0].span.events)) {
                    if (Test-OtlpAttribute -Attributes @($event.attributes) -Name 'event.name' -Kind 'stringValue' -Expected 'codex.websocket_request') { $events += $event }
                }
                if ($events.Count -ne 1) { throw 'otel-trace-contract-mismatch' }
                $success = Get-OtlpAttribute -Attributes @($events[0].attributes) -Name 'success'
                if ($null -eq $success -or [string]$success.kind -cne 'stringValue' -or @('true','false') -cnotcontains [string]$success.value) { throw 'otel-trace-contract-mismatch' }
                if ([string]$success.value -ceq 'false') { throw 'otel-websocket-send-failed' }
                $duration = Get-OtlpAttribute -Attributes @($events[0].attributes) -Name 'duration_ms'
                $connectionReused = Get-OtlpAttribute -Attributes @($events[0].attributes) -Name 'auth.connection_reused'
                $errorAttributes = @($events[0].attributes | Where-Object { [string]$_.key -ceq 'error.message' })
                if (-not (Test-OtlpAttribute -Attributes @($events[0].attributes) -Name 'model' -Kind 'stringValue' -Expected $Model) -or
                    -not (Test-OtlpAttribute -Attributes @($events[0].attributes) -Name 'app.version' -Kind 'stringValue' -Expected $ExpectedVersion) -or
                    $null -eq $duration -or [string]$duration.kind -cne 'stringValue' -or [string]$duration.value -cnotmatch '^[0-9]+(?:\.[0-9]+)?$' -or
                    $null -eq $connectionReused -or [string]$connectionReused.kind -cne 'boolValue' -or
                    $errorAttributes.Count -ne 0) { throw 'otel-trace-contract-mismatch' }
                if (-not [bool]$outerSpans[$outerKey].warmup) { $counts[[string]$round] = [int]$counts[[string]$round] + 1 }
            }
            if ([int]$counts[[string]$round] -lt 1) { throw 'otel-successful-send-missing' }
        }
        if ($serviceNames.Count -ne 1) { throw 'otel-service-name-inconsistent' }
        $values = @(1..$FreshSessions | ForEach-Object { [int]$counts[[string]$_] })
        return [ordered]@{status='measured';value=[int](($values | Measure-Object -Sum).Sum);basis=$contract;service_version=$ExpectedVersion;transport='responses_websocket';per_session_counts=$values;reason='Count of version-bound successful non-warmup Responses WebSocket send events.'}
    } catch {
        $reason = if ($_.Exception.Message -match '^otel-[a-z0-9-]+$') { $_.Exception.Message } else { 'otel-trace-invalid' }
        return [ordered]@{status='unavailable';value=$null;basis=$contract;reason=$reason}
    }
}
