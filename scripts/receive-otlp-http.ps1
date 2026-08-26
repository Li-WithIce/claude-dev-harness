#!/usr/bin/env pwsh
#requires -Version 7.3
[CmdletBinding()]
param(
    [ValidateRange(0,65535)][int]$Port = 0,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$StopPath,
    [ValidateRange(10,86400)][int]$TimeoutSeconds = 1800,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ParentProcessId,
    [Parameter(Mandatory)][string]$ExpectedClientIdentityPath,
    [ValidateRange(100,600000)][int]$ReadTimeoutMilliseconds = 30000,
    [ValidateRange(100,600000)][int]$WriteTimeoutMilliseconds = 30000,
    [ValidateRange(1,100000)][int]$MaxRequests = 10000,
    [ValidateRange(1,1099511627776)][int64]$MaxTotalBodyBytes = 268435456
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'lib\Harness.Hashing.psm1') -Force -ErrorAction Stop

function Test-ParentProcessAlive {
    try {
        $process = [Diagnostics.Process]::GetProcessById($ParentProcessId)
        return -not $process.HasExited
    } catch {
        return $false
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return (Get-HarnessSha256Bytes -Bytes $Bytes).Substring(7)
}

function Publish-ControlJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    $parent = [IO.Path]::GetDirectoryName($Path)
    $tempPath = Join-Path $parent ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path),[guid]::NewGuid().ToString('N'))
    $stream = $null
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Compress -Depth 10))
        $stream = [IO.FileStream]::new($tempPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [IO.File]::Move($tempPath,$Path)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}

$script:NetstatPath = $null

function Initialize-TcpOwnerLookup {
    if (-not $IsWindows) { throw 'OTLP client provenance is supported on Windows only.' }
    $candidate = Join-Path ([Environment]::SystemDirectory) 'netstat.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'Windows netstat.exe is unavailable for OTLP client provenance.' }
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Windows netstat.exe provenance lookup path is unsafe.' }
    $script:NetstatPath = [IO.Path]::GetFullPath($item.FullName)
}

function Invoke-NetstatTcpSnapshot {
    param([ValidateRange(100,5000)][int]$TimeoutMilliseconds = 1000)

    if ([string]::IsNullOrWhiteSpace($script:NetstatPath)) { throw 'OTLP TCP owner lookup is not initialized.' }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:NetstatPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-ano','-p','tcp')) { [void]$startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    $streamsDrained = $false
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    try {
        if (-not $process.Start()) { throw 'Windows netstat.exe TCP owner lookup did not start.' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { throw [TimeoutException]::new("Windows netstat.exe TCP owner lookup exceeded ${TimeoutMilliseconds}ms.") }
        $exitCode = $process.ExitCode
        $drainTask = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdoutTask,$stderrTask))
        if (-not $drainTask.Wait($TimeoutMilliseconds)) { throw [TimeoutException]::new("Windows netstat.exe output did not close within ${TimeoutMilliseconds}ms.") }
        $streamsDrained = $true
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($exitCode -ne 0) {
            $diagnostic = $stderr.Trim()
            if ($diagnostic.Length -gt 256) { $diagnostic = $diagnostic.Substring(0,256) }
            throw "Windows netstat.exe TCP owner lookup failed with exit code $exitCode. $diagnostic"
        }
        return @($stdout -split '\r?\n')
    } finally {
        if ($started) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    if (-not $process.WaitForExit(1000)) { throw 'netstat root did not exit within cleanup grace' }
                }
            } catch { $cleanupErrors.Add(('kill/wait netstat: ' + $_.Exception.Message)) }
            if (-not $streamsDrained -and $null -ne $stdoutTask -and $null -ne $stderrTask) {
                try {
                    $drainTask = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdoutTask,$stderrTask))
                    if (-not $drainTask.Wait(1000)) { throw 'netstat output did not close within cleanup grace' }
                } catch { $cleanupErrors.Add(('drain netstat: ' + $_.Exception.Message)) }
            }
        }
        try { $process.Dispose() } catch { $cleanupErrors.Add(('dispose netstat: ' + $_.Exception.Message)) }
        if ($cleanupErrors.Count -gt 0) { throw ('Windows netstat.exe cleanup failed: ' + ($cleanupErrors -join '; ')) }
    }
}

function Get-NetstatTcpOwnerProcessIds {
    param(
        [Parameter(Mandatory)][Net.IPAddress]$LocalAddress,
        [Parameter(Mandatory)][ValidateRange(1,65535)][int]$LocalPort,
        [Parameter(Mandatory)][Net.IPAddress]$RemoteAddress,
        [Parameter(Mandatory)][ValidateRange(1,65535)][int]$RemotePort
    )
    $expectedLocalEndpoint = '{0}:{1}' -f $LocalAddress.ToString(),$LocalPort.ToString([Globalization.CultureInfo]::InvariantCulture)
    $expectedRemoteEndpoint = '{0}:{1}' -f $RemoteAddress.ToString(),$RemotePort.ToString([Globalization.CultureInfo]::InvariantCulture)
    $lines = @(Invoke-NetstatTcpSnapshot)
    $owners = [Collections.Generic.HashSet[int]]::new()
    foreach ($entry in $lines) {
        $line = ([string]$entry).Trim()
        if (-not $line.StartsWith('TCP ',[StringComparison]::OrdinalIgnoreCase)) { continue }
        $fields = @($line -split '\s+')
        if ($fields.Count -ne 5 -or -not $fields[0].Equals('TCP',[StringComparison]::OrdinalIgnoreCase)) { throw 'Windows netstat.exe returned a malformed TCP owner row.' }
        if ([string]$fields[1] -cne $expectedLocalEndpoint -or [string]$fields[2] -cne $expectedRemoteEndpoint -or [string]$fields[3] -cne 'ESTABLISHED') { continue }
        $ownerProcessId = 0
        if (-not [int]::TryParse([string]$fields[4],[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$ownerProcessId) -or $ownerProcessId -le 0) { throw 'Windows netstat.exe returned an invalid TCP owner process id.' }
        [void]$owners.Add($ownerProcessId)
    }
    return @($owners | Sort-Object)
}

function Test-ExactMapKeys {
    param([Parameter(Mandatory)]$Map,[Parameter(Mandatory)][string[]]$Expected)
    $actual = @($Map.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    return $actual.Count -eq $wanted.Count -and @(Compare-Object $actual $wanted -SyncWindow 0).Count -eq 0
}

function Read-ClientIdentityRegistration {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$CollectorInstanceId,
        [Parameter(Mandatory)]$ExistingRegistrations
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0 -or $item.Length -gt 4096) { throw 'OTLP client identity file is invalid.' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $identity = [Text.UTF8Encoding]::new($false,$true).GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 5
    $keys = @('schema_version','collector_instance_id','round','process_id','start_time_filetime_utc')
    if (-not (Test-ExactMapKeys -Map $identity -Expected $keys) -or [string]$identity.schema_version -cne 'host-benchmark-otel-client/v1' -or [string]$identity.collector_instance_id -cne $CollectorInstanceId) { throw 'OTLP client identity contract is invalid.' }
    $round = [int64]$identity.round
    $processId = [int64]$identity.process_id
    $startFileTime = [int64]$identity.start_time_filetime_utc
    if ($round -lt 1 -or $round -gt 100000 -or $processId -lt 1 -or $processId -gt [int]::MaxValue -or $startFileTime -le 0) { throw 'OTLP client identity values are invalid.' }
    if ($ExistingRegistrations.Contains([string]$round)) { throw 'OTLP client identity round was registered more than once.' }
    foreach ($existing in @($ExistingRegistrations.Values)) {
        if ([int]$existing.process_id -eq [int]$processId -and [int64]$existing.start_time_filetime_utc -eq $startFileTime) { throw 'OTLP client process was reused across fresh rounds.' }
    }
    $process = [Diagnostics.Process]::GetProcessById([int]$processId)
    try {
        if ($process.HasExited -or $process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $startFileTime) { throw 'OTLP client process identity is stale.' }
        return [pscustomobject]@{
            round = [int]$round
            process_id = [int]$processId
            start_time_filetime_utc = $startFileTime
            identity_sha256 = Get-Sha256Hex -Bytes $bytes
            process = $process
        }
    } catch {
        $process.Dispose()
        throw
    }
}

function Register-PendingClientIdentity {
    param(
        [Parameter(Mandatory)][string]$IdentityPath,
        [Parameter(Mandatory)][string]$AcceptedPath,
        [Parameter(Mandatory)][string]$CollectorInstanceId,
        [Parameter(Mandatory)]$Registrations
    )
    if (-not (Test-Path -LiteralPath $IdentityPath -PathType Leaf)) { return }
    if (Test-Path -LiteralPath $AcceptedPath) { return }
    $registration = Read-ClientIdentityRegistration -Path $IdentityPath -CollectorInstanceId $CollectorInstanceId -ExistingRegistrations $Registrations
    $Registrations[[string]$registration.round] = $registration
    Publish-ControlJson -Path $AcceptedPath -Value ([ordered]@{
        schema_version = 'host-benchmark-otel-client-ack/v1'
        collector_instance_id = $CollectorInstanceId
        round = $registration.round
        identity_sha256 = $registration.identity_sha256
    })
}

function Test-RegisteredProcessAlive {
    param([Parameter(Mandatory)]$Registration)
    try {
        $Registration.process.Refresh()
        return -not $Registration.process.HasExited -and $Registration.process.StartTime.ToUniversalTime().ToFileTimeUtc() -eq [int64]$Registration.start_time_filetime_utc
    } catch { return $false }
}

function Get-ConnectionOwnerProcessId {
    param([Parameter(Mandatory)][Net.Sockets.TcpClient]$Client)
    $clientEndpoint = [Net.IPEndPoint]$Client.Client.RemoteEndPoint
    $collectorEndpoint = [Net.IPEndPoint]$Client.Client.LocalEndPoint
    if ($clientEndpoint.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $collectorEndpoint.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or -not [Net.IPAddress]::IsLoopback($clientEndpoint.Address) -or -not [Net.IPAddress]::IsLoopback($collectorEndpoint.Address)) { throw 'OTLP connection is not exact IPv4 loopback.' }
    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds(1000)
    do {
        $owners = @(Get-NetstatTcpOwnerProcessIds -LocalAddress $clientEndpoint.Address -LocalPort $clientEndpoint.Port -RemoteAddress $collectorEndpoint.Address -RemotePort $collectorEndpoint.Port)
        if ($owners.Count -gt 1) { throw 'OTLP connection owner lookup was ambiguous.' }
        if ($owners.Count -eq 1) { return [int]$owners[0] }
        Start-Sleep -Milliseconds 10
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'OTLP connection owner lookup returned no process.'
}

function Resolve-ConnectionRegistration {
    param([Parameter(Mandatory)][Net.Sockets.TcpClient]$Client,[Parameter(Mandatory)]$Registrations)
    if ($Registrations.Count -eq 0) { throw 'OTLP connection arrived before client identity registration.' }
    $ownerProcessId = Get-ConnectionOwnerProcessId -Client $Client
    $matches = @($Registrations.Values | Where-Object { [int]$_.process_id -eq $ownerProcessId -and (Test-RegisteredProcessAlive -Registration $_) })
    if ($matches.Count -ne 1) { throw 'OTLP connection owner does not match a registered Codex process.' }
    if (-not (Test-RegisteredProcessAlive -Registration $matches[0])) { throw 'OTLP client process exited during provenance validation.' }
    return $matches[0]
}

function Open-LockedTraceFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)]$OpenStreams)
    $stream = $null
    try {
        $stream = [IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $stream.Write($Bytes,0,$Bytes.Length)
        $stream.Flush($true)
        [void]$OpenStreams.Add($stream)
        $stream = $null
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-HttpRequest {
    param(
        [Parameter(Mandatory)][Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory)][ValidateRange(0,67108864)][int64]$MaxBodyBytes
    )

    $stream = $Client.GetStream()
    $stream.ReadTimeout = $ReadTimeoutMilliseconds
    $stream.WriteTimeout = $WriteTimeoutMilliseconds
    $headerBytes = [Collections.Generic.List[byte]]::new()
    $window = [Collections.Generic.Queue[byte]]::new(4)
    while ($headerBytes.Count -lt 65536) {
        $value = $stream.ReadByte()
        if ($value -lt 0) { throw 'OTLP connection closed before the HTTP headers completed.' }
        $byte = [byte]$value
        $headerBytes.Add($byte)
        $window.Enqueue($byte)
        if ($window.Count -gt 4) { [void]$window.Dequeue() }
        if ($window.Count -eq 4 -and (@($window) -join ',') -ceq '13,10,13,10') { break }
    }
    if ($headerBytes.Count -ge 65536) { throw 'OTLP HTTP headers exceeded the 64 KiB limit.' }
    $headerText = [Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = @($headerText -split "`r`n")
    $requestLine = @($lines[0] -split ' ')
    if ($requestLine.Count -ne 3 -or $requestLine[0] -cne 'POST' -or $requestLine[1] -cnotmatch '^/v1/traces/round-[1-9][0-9]*$' -or $requestLine[2] -cne 'HTTP/1.1') { throw 'OTLP collector accepts exact versioned trace POST endpoints only.' }
    $headers = [ordered]@{}
    foreach ($line in @($lines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $separator = $line.IndexOf(':')
        if ($separator -le 0) { throw 'Malformed OTLP HTTP header.' }
        $name = $line.Substring(0,$separator).Trim().ToLowerInvariant()
        if ($headers.Contains($name)) { throw 'Duplicate OTLP HTTP header.' }
        $headers[$name] = $line.Substring($separator+1).Trim()
    }
    if (-not $headers.Contains('content-length')) { throw 'OTLP collector requires Content-Length.' }
    if ($headers.Contains('transfer-encoding')) { throw 'OTLP collector does not accept Transfer-Encoding.' }
    if (-not $headers.Contains('content-type') -or [string]$headers['content-type'] -cne 'application/json') { throw 'OTLP collector requires Content-Type application/json.' }
    $length = [int64]0
    if (-not [int64]::TryParse([string]$headers['content-length'],[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture,[ref]$length) -or $length -gt $MaxBodyBytes) { throw 'OTLP request body exceeded the remaining byte limit.' }
    $body = [byte[]]::new([int]$length)
    $offset = 0
    while ($offset -lt $body.Length) {
        $read = $stream.Read($body,$offset,$body.Length-$offset)
        if ($read -le 0) { throw 'OTLP connection closed before the request body completed.' }
        $offset += $read
    }
    return [ordered]@{path=$requestLine[1];content_type=$headers['content-type'];body=$body;stream=$stream}
}

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ReadyPath = [IO.Path]::GetFullPath($ReadyPath)
$StopPath = [IO.Path]::GetFullPath($StopPath)
$ExpectedClientIdentityPath = [IO.Path]::GetFullPath($ExpectedClientIdentityPath)
$acceptedIdentityPath = $ExpectedClientIdentityPath + '.accepted'
if (@($OutputDirectory,$ReadyPath,$StopPath,$ExpectedClientIdentityPath,$acceptedIdentityPath | Select-Object -Unique).Count -ne 5) { throw 'OTLP collector control paths must be distinct.' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ReadyPath))
if (@(Get-ChildItem -LiteralPath $OutputDirectory -Force -ErrorAction Stop).Count -ne 0) { throw 'OTLP trace directory must be empty at collector start.' }
if ((Test-Path -LiteralPath $ExpectedClientIdentityPath) -or (Test-Path -LiteralPath $acceptedIdentityPath)) { throw 'OTLP client identity controls must not be stale.' }
if (-not (Test-ParentProcessAlive)) { throw 'OTLP collector parent process is not alive.' }
Initialize-TcpOwnerLookup
$collectorInstanceId = [guid]::NewGuid().ToString('N')
$registrations = [ordered]@{}
$openStreams = [Collections.Generic.List[IO.FileStream]]::new()
$manifestFiles = [Collections.Generic.List[object]]::new()
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
$manifestJson = $null
$listener.Start()
$boundPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
Publish-ControlJson -Path $ReadyPath -Value ([ordered]@{port=$boundPort;parent_process_id=$ParentProcessId;collector_instance_id=$collectorInstanceId;provenance='verified-owner-pid-start-time/v1'})
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
$requestNumber = 0
$totalBodyBytes = [int64]0
$pending = $listener.AcceptTcpClientAsync()
try {
    while ([DateTimeOffset]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $StopPath) -and (Test-ParentProcessAlive)) {
        Register-PendingClientIdentity -IdentityPath $ExpectedClientIdentityPath -AcceptedPath $acceptedIdentityPath -CollectorInstanceId $collectorInstanceId -Registrations $registrations
        if (-not $pending.Wait(50)) { continue }
        $client = $pending.Result
        $pending = $listener.AcceptTcpClientAsync()
        try {
            $registration = Resolve-ConnectionRegistration -Client $client -Registrations $registrations
            if ($requestNumber -ge $MaxRequests) { throw 'OTLP collector exceeded its cumulative request limit.' }
            $remainingBodyBytes = [Math]::Min([int64]67108864,$MaxTotalBodyBytes-$totalBodyBytes)
            $request = Read-HttpRequest -Client $client -MaxBodyBytes $remainingBodyBytes
            $roundMatch = [regex]::Match([string]$request.path,'^/v1/traces/round-([1-9][0-9]*)$')
            $round = [int]$roundMatch.Groups[1].Value
            if (-not $registrations.Contains([string]$round) -or [int]$registration.round -ne $round) { throw 'OTLP request round does not match the registered client process.' }
            $requestNumber++
            $totalBodyBytes += [int64]$request.body.Length
            $stemName = 'request-{0:d4}' -f $requestNumber
            $metaName = $stemName + '.meta.json'
            $bodyName = $stemName + '.json'
            $metaBytes = [Text.UTF8Encoding]::new($false).GetBytes(([ordered]@{path=$request.path;content_type=$request.content_type} | ConvertTo-Json -Compress))
            $bodyBytes = [byte[]]$request.body
            Open-LockedTraceFile -Path (Join-Path $OutputDirectory $metaName) -Bytes $metaBytes -OpenStreams $openStreams
            Open-LockedTraceFile -Path (Join-Path $OutputDirectory $bodyName) -Bytes $bodyBytes -OpenStreams $openStreams
            $manifestFiles.Add([ordered]@{name=$metaName;kind='meta';request_number=$requestNumber;round=$round;bytes=$metaBytes.Length;sha256=(Get-Sha256Hex -Bytes $metaBytes)})
            $manifestFiles.Add([ordered]@{name=$bodyName;kind='body';request_number=$requestNumber;round=$round;bytes=$bodyBytes.Length;sha256=(Get-Sha256Hex -Bytes $bodyBytes)})
            $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: 2`r`nConnection: close`r`n`r`n{}")
            $request.stream.Write($response,0,$response.Length)
            $request.stream.Flush()
        } finally {
            $client.Dispose()
        }
    }
    if (-not (Test-Path -LiteralPath $StopPath -PathType Leaf)) { throw 'OTLP collector ended without the parent stop signal.' }
    $registeredRounds = @($registrations.Keys | ForEach-Object { [int]$_ } | Sort-Object)
    $manifestJson = ([ordered]@{
        schema_version = 'host-benchmark-otel-manifest/v1'
        provenance = 'verified-owner-pid-start-time/v1'
        collector_instance_id = $collectorInstanceId
        registered_rounds = @($registeredRounds)
        request_count = $requestNumber
        files = @($manifestFiles.ToArray())
    } | ConvertTo-Json -Compress -Depth 10)
} finally {
    $listener.Stop()
    foreach ($stream in $openStreams) { try { $stream.Dispose() } catch {} }
    foreach ($registration in @($registrations.Values)) { try { $registration.process.Dispose() } catch {} }
}
if ($null -ne $manifestJson) { [Console]::Out.WriteLine($manifestJson) }
