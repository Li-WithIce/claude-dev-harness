[CmdletBinding()]
param([string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'tests/fixture-test-common.ps1')
$script:Checks=@();$script:Failures=@()
function Add-Check([string]$Message){$script:Checks += $Message}
function Add-Failure([string]$Message){$script:Failures += $Message}

# Generic process/transport checks extracted from the retained legacy verifier.
# This active verifier never imports legacy plans, stage writers or archived tests.
function Start-LifecyclePowerShell {
    param(
        [string]$HostPath,
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $HostPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath) + @($Arguments)) {
        $psi.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    return [pscustomobject]@{
        Process = $process
        StdOut = $process.StandardOutput.ReadToEndAsync()
        StdErr = $process.StandardError.ReadToEndAsync()
        Timer = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Complete-LifecyclePowerShell {
    param(
        [object]$Capture,
        [string]$Label,
        [int]$TimeoutMilliseconds = 10000
    )

    $outerTimedOut = $false
    $exitCode = -1
    $stdout = ''
    $stderr = ''
    try {
        if (-not $Capture.Process.WaitForExit($TimeoutMilliseconds)) {
            $outerTimedOut = $true
            try { $Capture.Process.Kill($true) } catch { Add-Failure "$Label watchdog tree kill failed: $($_.Exception.Message)" }
            try {
                if (-not $Capture.Process.WaitForExit(5000)) { Add-Failure "$Label watchdog root wait timed out" }
            } catch { Add-Failure "$Label watchdog root wait failed: $($_.Exception.Message)" }
        }
        if ($Capture.Process.HasExited) { $exitCode = $Capture.Process.ExitCode }
        $drain = [System.Threading.Tasks.Task]::WhenAll([System.Threading.Tasks.Task[]]@($Capture.StdOut, $Capture.StdErr))
        if (-not $drain.Wait(5000)) {
            Add-Failure "$Label watchdog stream drain timed out"
        } else {
            $stdout = $Capture.StdOut.GetAwaiter().GetResult()
            $stderr = $Capture.StdErr.GetAwaiter().GetResult()
        }
    } catch {
        Add-Failure "$Label watchdog failed: $($_.Exception.Message)"
    } finally {
        $Capture.Timer.Stop()
        try {
            if (-not $Capture.Process.HasExited) {
                $Capture.Process.Kill($true)
                if (-not $Capture.Process.WaitForExit(5000)) { Add-Failure "$Label final watchdog cleanup timed out" }
            }
        } catch [System.InvalidOperationException] {
        } catch {
            Add-Failure "$Label final watchdog cleanup failed: $($_.Exception.Message)"
        }
        $Capture.Process.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        OuterTimedOut = $outerTimedOut
        StdOut = $stdout.Trim()
        StdErr = $stderr.Trim()
        DurationMilliseconds = $Capture.Timer.ElapsedMilliseconds
    }
}

function Read-LifecycleIdentity {
    param(
        [string]$Path,
        [int]$TimeoutMilliseconds = 5000,
        [string[]]$RequiredProperties = @('token', 'root_pid', 'root_start_ticks', 'child_pid', 'child_start_ticks')
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $identity = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
                $complete = $true
                foreach ($property in $RequiredProperties) {
                    if ($null -eq $identity.PSObject.Properties[$property]) { $complete = $false; break }
                }
                if ($complete) { return $identity }
            } catch {
            }
        }
        Start-Sleep -Milliseconds 25
    }
    return $null
}

function New-DispatchRequestFile {
    param([object[]]$Parameters = @())

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-harness-skill-request-' + [guid]::NewGuid().ToString('N') + '.json')
    $document = [ordered]@{
        schema_version = 'invoke-harness-skill-dispatch/v1'
        parameters = @($Parameters)
    }
    [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 6 -Compress), [System.Text.UTF8Encoding]::new($false))
    return $path
}

function New-RawDispatchRequestFile {
    param([Parameter(Mandatory = $true)][string]$Json)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-harness-skill-request-' + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllText($path, $Json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Test-LifecycleProcessAlive {
    param([int]$ProcessId, [long]$StartTicks)

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        return $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks
    } catch [System.InvalidOperationException] {
        return $false
    } finally {
        $process.Dispose()
    }
}

function Stop-LifecycleProcess {
    param([int]$ProcessId, [long]$StartTicks, [string]$Label)

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return }
    try {
        if ($process.StartTime.ToUniversalTime().Ticks -eq $StartTicks) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) { Add-Failure "$Label cleanup timed out" }
        }
    } catch [System.InvalidOperationException] {
    } catch {
        Add-Failure "$Label cleanup failed: $($_.Exception.Message)"
    } finally {
        $process.Dispose()
    }
}

$supervisorPath=Join-Path $RepoRoot 'scripts/invoke-harness-skill-supervisor.ps1'
$dispatcherPath=Join-Path $RepoRoot 'scripts/invoke-harness-skill-dispatcher.ps1'
$cleanupPaths=@()
$cleanupIdentities=[Collections.Generic.List[object]]::new()
try {
    $ownerRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-owner-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $ownerRoot
    New-Item -ItemType Directory -Path $ownerRoot -Force | Out-Null
    $ownerChildPath = Join-Path $ownerRoot 'descendant.ps1'
    Write-Utf8Bom -Path $ownerChildPath -Content @'
[CmdletBinding()]
param([string]$MarkerPath, [string]$Token)
Start-Sleep -Milliseconds 4000
[System.IO.File]::WriteAllText($MarkerPath, $Token, [System.Text.UTF8Encoding]::new($false))
Start-Sleep -Milliseconds 4000
'@
    $ownerHost = (@(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0]).Source
    foreach ($ownerCase in @(
            [pscustomobject]@{ Name = 'natural'; TimeoutSeconds = 10; RootSleep = '$null'; ExpectedExit = 0; OutputCount = 768 }
            [pscustomobject]@{ Name = 'timeout'; TimeoutSeconds = 2; RootSleep = 'Start-Sleep -Seconds 30'; ExpectedExit = 124; OutputCount = 8 }
        )) {
        $caseRoot = Join-Path $ownerRoot $ownerCase.Name
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $identityPath = Join-Path $caseRoot 'identity.json'
        $markerPath = Join-Path $caseRoot 'late.marker'
        $backendOutputPath = Join-Path $caseRoot 'backend-output.tmp'
        $targetPath = Join-Path $caseRoot 'target.ps1'
        $ownerRequestPath = New-DispatchRequestFile
        $cleanupPaths += $ownerRequestPath
        $token = [guid]::NewGuid().ToString('N')
        $identityLiteral = "'" + $identityPath.Replace("'", "''") + "'"
        $markerLiteral = "'" + $markerPath.Replace("'", "''") + "'"
        $backendOutputLiteral = "'" + $backendOutputPath.Replace("'", "''") + "'"
        $childLiteral = "'" + $ownerChildPath.Replace("'", "''") + "'"
        $tokenLiteral = "'" + $token.Replace("'", "''") + "'"
        Write-Utf8Bom -Path $targetPath -Content @"
`$ErrorActionPreference = 'Stop'
`$utf8 = [System.Text.UTF8Encoding]::new(`$false)
for (`$i = 0; `$i -lt $($ownerCase.OutputCount); `$i++) {
    [Console]::Out.WriteLine(('owner-stdout-{0:D4}-' -f `$i) + ('o' * 160))
    [Console]::Error.WriteLine(('owner-stderr-{0:D4}-' -f `$i) + ('e' * 160))
}
`$self = Get-Process -Id `$PID
try { `$selfTicks = `$self.StartTime.ToUniversalTime().Ticks } finally { `$self.Dispose() }
`$psi = [System.Diagnostics.ProcessStartInfo]::new()
`$psi.FileName = (Get-Process -Id `$PID).Path
`$psi.UseShellExecute = `$false
foreach (`$argument in @('-NoProfile', '-NonInteractive', '-File', $childLiteral, '-MarkerPath', $markerLiteral, '-Token', $tokenLiteral)) { `$psi.ArgumentList.Add([string]`$argument) }
`$child = [System.Diagnostics.Process]::Start(`$psi)
try {
    `$identity = [ordered]@{ token = $tokenLiteral; root_pid = `$PID; root_start_ticks = `$selfTicks; child_pid = `$child.Id; child_start_ticks = `$child.StartTime.ToUniversalTime().Ticks }
    [System.IO.File]::WriteAllText($identityLiteral, (`$identity | ConvertTo-Json -Compress), `$utf8)
} finally { `$child.Dispose() }
[System.IO.File]::WriteAllText($backendOutputLiteral, 'owner-backend-result', `$utf8)
$($ownerCase.RootSleep)
exit 0
"@
        $ownerCapture = Start-LifecyclePowerShell -HostPath $ownerHost -ScriptPath $supervisorPath -Arguments @('-TargetScriptPath', $targetPath, '-RequestPath', $ownerRequestPath, '-OutputPath', $backendOutputPath, '-TimeoutSeconds', [string]$ownerCase.TimeoutSeconds)
        $ownerResult = Complete-LifecyclePowerShell -Capture $ownerCapture -Label ("owner {0}" -f $ownerCase.Name) -TimeoutMilliseconds 10000
        $ownerIdentity = Read-LifecycleIdentity -Path $identityPath
        if ($null -ne $ownerIdentity -and [string]$ownerIdentity.token -ceq $token) {
            $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$ownerIdentity.root_pid; Ticks = [long]$ownerIdentity.root_start_ticks; Label = "owner $($ownerCase.Name) root" })
            $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$ownerIdentity.child_pid; Ticks = [long]$ownerIdentity.child_start_ticks; Label = "owner $($ownerCase.Name) child" })
        }
        $rootAlive = $null -ne $ownerIdentity -and (Test-LifecycleProcessAlive -ProcessId ([int]$ownerIdentity.root_pid) -StartTicks ([long]$ownerIdentity.root_start_ticks))
        $childAlive = $null -ne $ownerIdentity -and (Test-LifecycleProcessAlive -ProcessId ([int]$ownerIdentity.child_pid) -StartTicks ([long]$ownerIdentity.child_start_ticks))
        $ownerExpectedTail = '{0:D4}' -f ($ownerCase.OutputCount - 1)
        if ($ownerResult.ExitCode -eq $ownerCase.ExpectedExit -and
            -not $ownerResult.OuterTimedOut -and
            $null -ne $ownerIdentity -and [string]$ownerIdentity.token -ceq $token -and
            -not $rootAlive -and -not $childAlive -and
            -not (Test-Path -LiteralPath $markerPath) -and -not (Test-Path -LiteralPath $backendOutputPath) -and -not (Test-Path -LiteralPath $ownerRequestPath) -and
            $ownerResult.StdOut -match ('owner-stdout-{0}-' -f $ownerExpectedTail) -and
            $ownerResult.StdErr -match ('owner-stderr-{0}-' -f $ownerExpectedTail)) {
            Add-Check ("owner {0} drains both streams, closes the exact target tree, and preserves bounded exit semantics" -f $ownerCase.Name)
        } else {
            Add-Failure ("owner {0} failed: exit={1} outer_timeout={2} duration_ms={3} root_alive={4} child_alive={5} marker={6} stdout_tail={7} stderr_tail={8}" -f $ownerCase.Name,$ownerResult.ExitCode,$ownerResult.OuterTimedOut,$ownerResult.DurationMilliseconds,$rootAlive,$childAlive,(Test-Path -LiteralPath $markerPath),($ownerResult.StdOut.Substring([Math]::Max(0,$ownerResult.StdOut.Length-120))),($ownerResult.StdErr.Substring([Math]::Max(0,$ownerResult.StdErr.Length-120))))
        }
    }

    $rawGuardRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-dispatch-guard-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $rawGuardRoot -Force | Out-Null
    $cleanupPaths += $rawGuardRoot
    foreach ($rawGuardName in @('top-duplicate', 'entry-duplicate', 'top-case-variant', 'entry-case-variant', 'parameter-name-case-override')) {
        $rawGuardCaseRoot = Join-Path $rawGuardRoot $rawGuardName
        New-Item -ItemType Directory -Path $rawGuardCaseRoot -Force | Out-Null
        $rawGuardTargetPath = Join-Path $rawGuardCaseRoot 'target.ps1'
        $rawGuardMarkerPath = Join-Path $rawGuardCaseRoot 'target-entered.marker'
        $rawGuardOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-dispatch-output-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $rawGuardMarkerLiteral = "'" + $rawGuardMarkerPath.Replace("'", "''") + "'"
        $rawGuardOutputLiteral = "'" + $rawGuardOutputPath.Replace("'", "''") + "'"
        Write-Utf8Bom -Path $rawGuardTargetPath -Content @"
[System.IO.File]::WriteAllText($rawGuardMarkerLiteral, 'entered', [System.Text.UTF8Encoding]::new(`$false))
[System.IO.File]::WriteAllText($rawGuardOutputLiteral, 'unexpected-output', [System.Text.UTF8Encoding]::new(`$false))
exit 0
"@
        $rawGuardOutputJson = $rawGuardOutputPath | ConvertTo-Json -Compress
        $rawGuardValidOutputEntry = '{"name":"Output","kind":"string","value":' + $rawGuardOutputJson + '}'
        $rawGuardJson = switch ($rawGuardName) {
            'top-duplicate' {
                '{"schema_version":"invoke-harness-skill-dispatch/v1","schema_version":"invoke-harness-skill-dispatch/v1","parameters":[' + $rawGuardValidOutputEntry + ']}'
            }
            'entry-duplicate' {
                '{"schema_version":"invoke-harness-skill-dispatch/v1","parameters":[{"name":"Output","name":"Output","kind":"string","value":' + $rawGuardOutputJson + '}]}'
            }
            'top-case-variant' {
                '{"Schema_version":"invoke-harness-skill-dispatch/v1","parameters":[' + $rawGuardValidOutputEntry + ']}'
            }
            'entry-case-variant' {
                '{"schema_version":"invoke-harness-skill-dispatch/v1","parameters":[{"Name":"Output","kind":"string","value":' + $rawGuardOutputJson + '}]}'
            }
            'parameter-name-case-override' {
                '{"schema_version":"invoke-harness-skill-dispatch/v1","parameters":[{"name":"Task","kind":"string","value":"trusted"},{"name":"task","kind":"string","value":"override"},' + $rawGuardValidOutputEntry + ']}'
            }
        }
        $rawGuardRequestPath = New-RawDispatchRequestFile -Json $rawGuardJson
        $cleanupPaths += @($rawGuardRequestPath, $rawGuardOutputPath)
        $rawGuardCapture = Start-LifecyclePowerShell -HostPath $ownerHost -ScriptPath $supervisorPath -Arguments @(
            '-TargetScriptPath', $rawGuardTargetPath,
            '-RequestPath', $rawGuardRequestPath,
            '-OutputPath', $rawGuardOutputPath,
            '-TimeoutSeconds', '10'
        )
        $rawGuardResult = Complete-LifecyclePowerShell -Capture $rawGuardCapture -Label ("dispatcher guard $rawGuardName") -TimeoutMilliseconds 10000
        if ($rawGuardResult.ExitCode -ne 0 -and
            -not $rawGuardResult.OuterTimedOut -and
            -not (Test-Path -LiteralPath $rawGuardMarkerPath) -and
            -not (Test-Path -LiteralPath $rawGuardOutputPath) -and
            -not (Test-Path -LiteralPath $rawGuardRequestPath)) {
            Add-Check ("dispatcher guard {0} is rejected before target entry and supervisor removes request data" -f $rawGuardName)
        } else {
            Add-Failure ("dispatcher guard {0} failed closed contract: exit={1} timeout={2} marker={3} output={4} request={5} stdout=[{6}] stderr=[{7}]" -f $rawGuardName,$rawGuardResult.ExitCode,$rawGuardResult.OuterTimedOut,(Test-Path -LiteralPath $rawGuardMarkerPath),(Test-Path -LiteralPath $rawGuardOutputPath),(Test-Path -LiteralPath $rawGuardRequestPath),$rawGuardResult.StdOut,$rawGuardResult.StdErr)
        }
    }
    $literalRoot=Join-Path ([IO.Path]::GetTempPath()) ('tk03-transport-literal-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($literalRoot);$cleanupPaths+=$literalRoot
    $literalTarget=Join-Path $literalRoot 'target.ps1';$literalOutput=Join-Path $literalRoot 'output.bin'
    Write-Utf8Bom -Path $literalTarget -Content @'
param([string]$Task,[string[]]$File,[switch]$ReadOnly,[int]$TimeoutSeconds,[string]$Output)
$record=[ordered]@{task=$Task;files=@($File);read_only=[bool]$ReadOnly;timeout=$TimeoutSeconds}
[IO.File]::WriteAllText($Output,($record|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
'@
    $literalTask='literal 中文 ''quotes'' "double"; $env:IGNORED; & never-execute'
    $literalFiles=@('space path/a.txt','中文/b.txt')
    $request=New-DispatchRequestFile @(
        [ordered]@{name='Task';kind='string';value=$literalTask},
        [ordered]@{name='File';kind='string-array';value=$literalFiles},
        [ordered]@{name='ReadOnly';kind='switch';value=$true},
        [ordered]@{name='TimeoutSeconds';kind='int32';value=37},
        [ordered]@{name='Output';kind='string';value=$literalOutput}
    )
    $cleanupPaths+=$request
    $capture=Start-LifecyclePowerShell -HostPath $ownerHost -ScriptPath $supervisorPath -Arguments @('-TargetScriptPath',$literalTarget,'-RequestPath',$request,'-OutputPath',$literalOutput,'-TimeoutSeconds','10')
    $result=Complete-LifecyclePowerShell -Capture $capture -Label 'literal transport'
    $frames=@($result.StdOut -split "\r?\n" | Where-Object { $_.StartsWith('__DEV_HARNESS_BACKEND_OUTPUT_BASE64__=') })
    $actual=$null
    if($frames.Count -eq 1){
        $frame=$frames[0].Substring('__DEV_HARNESS_BACKEND_OUTPUT_BASE64__='.Length)
        try{$actual=[Text.UTF8Encoding]::new($false,$true).GetString([Convert]::FromBase64String($frame))|ConvertFrom-Json}catch{}
    }
    if($result.ExitCode -eq 0 -and $null -ne $actual -and $actual.task -ceq $literalTask -and ($actual.files -join '|') -ceq ($literalFiles -join '|') -and $actual.read_only -and $actual.timeout -eq 37 -and -not(Test-Path -LiteralPath $request) -and -not(Test-Path -LiteralPath $literalOutput)){
        Add-Check 'typed parameters are literal data and one frame returns the exact result with request/output cleanup'
    }else{Add-Failure 'typed literal transport, frame count or cleanup failed'}

    foreach($case in @('empty','binary','large','missing','failed')){
        $caseRoot=Join-Path $literalRoot $case;[void][IO.Directory]::CreateDirectory($caseRoot)
        $target=Join-Path $caseRoot 'target.ps1';$output=Join-Path $caseRoot 'output.bin'
        [byte[]]$expected=@()
        if($case -ceq 'binary'){$expected=@(0,255,195,40,13,10,239,187,191)}elseif($case -cne 'empty'){$expected=[Text.UTF8Encoding]::new($false).GetBytes(('中文 CRLF'+[char]13+[char]10)*16384)}
        $encoded=[Convert]::ToBase64String($expected)
        $exit=if($case -ceq 'failed'){7}else{0}
        $targetText=@'
param([string]$Output,[string]$Task,[switch]$ReadOnly,[int]$TimeoutSeconds)
if(-not $ReadOnly){[IO.File]::WriteAllBytes($Output,[Convert]::FromBase64String($Task))}
exit $TimeoutSeconds
'@
        Write-Utf8Bom -Path $target -Content $targetText
        $records=@([ordered]@{name='Output';kind='string';value=$output},[ordered]@{name='Task';kind='string';value=$encoded},[ordered]@{name='TimeoutSeconds';kind='int32';value=$exit})
        if($case -ceq 'missing'){$records+=([ordered]@{name='ReadOnly';kind='switch';value=$true})}
        $request=New-DispatchRequestFile $records;$cleanupPaths+=$request
        $capture=Start-LifecyclePowerShell -HostPath $ownerHost -ScriptPath $supervisorPath -Arguments @('-TargetScriptPath',$target,'-RequestPath',$request,'-OutputPath',$output,'-TimeoutSeconds','10')
        $result=Complete-LifecyclePowerShell -Capture $capture -Label ("framing "+$case)
        $frames=@($result.StdOut -split "\r?\n" | Where-Object { $_.StartsWith('__DEV_HARNESS_BACKEND_OUTPUT_BASE64__=') })
        $valid=if($case -ceq 'missing'){$result.ExitCode -ne 0 -and $frames.Count -eq 0}elseif($case -ceq 'failed'){$result.ExitCode -eq 7 -and $frames.Count -eq 0}else{$result.ExitCode -eq 0 -and $frames.Count -eq 1 -and $frames[0].Substring('__DEV_HARNESS_BACKEND_OUTPUT_BASE64__='.Length) -ceq $encoded}
        if($valid -and -not $result.OuterTimedOut -and -not(Test-Path -LiteralPath $request) -and -not(Test-Path -LiteralPath $output)){Add-Check "$case byte framing and bounded cleanup"}else{Add-Failure "$case byte framing or bounded cleanup failed: exit=$($result.ExitCode), frames=$($frames.Count)"}
    }
} finally {
    foreach($identity in $cleanupIdentities){Stop-LifecycleProcess -ProcessId $identity.Id -StartTicks $identity.Ticks -Label $identity.Label}
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    foreach($path in $cleanupPaths){
        $resolved=[IO.Path]::GetFullPath($path)
        if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase)){throw 'transport cleanup escaped fixture temp root'}
        if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Force -Recurse}
    }
}
foreach($check in $script:Checks){"[PASS] $check"}
foreach($failure in $script:Failures){"[FAIL] $failure"}
if($script:Failures.Count){exit 1}
"STATUS: PASS ($($script:Checks.Count) transport checks; legacy lifecycle not_run)"
