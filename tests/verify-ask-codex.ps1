param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
. (Join-Path $RepoRoot 'tests\fixture-test-common.ps1')

$script:checks = [System.Collections.Generic.List[string]]::new()
$script:failures = [System.Collections.Generic.List[string]]::new()
$script:cleanupIdentities = [System.Collections.Generic.List[object]]::new()

function Add-Check { param([string]$Message) $script:checks.Add($Message) }
function Add-Failure { param([string]$Message) $script:failures.Add($Message) }

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Test-StringSequenceEqual {
    param([object[]]$Actual, [string[]]$Expected)

    if (@($Actual).Count -ne $Expected.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$Actual[$index] -cne $Expected[$index]) { return $false }
    }
    return $true
}

function Get-TreeSnapshot {
    param([string]$Root)

    $rows = foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName) {
        $relative = [System.IO.Path]::GetRelativePath($Root, $item.FullName)
        if ($item.PSIsContainer) {
            'D|{0}' -f $relative
        } else {
            'F|{0}|{1}' -f $relative, (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
    }
    return ($rows -join "`n")
}

function Start-AskCodex {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments,
        [hashtable]$Environment,
        [string]$WorkingDirectory,
        [string]$HostPath = (Get-Process -Id $PID).Path
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $HostPath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments) {
        $psi.ArgumentList.Add($argument)
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            [void]$psi.Environment.Remove([string]$entry.Key)
        } else {
            $psi.Environment[[string]$entry.Key] = [string]$entry.Value
        }
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    return [pscustomobject]@{
        Process = $process
        StdOut = $process.StandardOutput.ReadToEndAsync()
        StdErr = $process.StandardError.ReadToEndAsync()
    }
}

function Complete-AskCodex {
    param(
        [object]$Capture,
        [string]$Label,
        [int]$TimeoutMilliseconds = 15000
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
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Invoke-AskCodex {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments,
        [hashtable]$Environment,
        [string]$WorkingDirectory,
        [string]$Label,
        [string]$HostPath = (Get-Process -Id $PID).Path,
        [int]$TimeoutMilliseconds = 15000
    )

    $capture = Start-AskCodex -ScriptPath $ScriptPath -Arguments $Arguments -Environment $Environment -WorkingDirectory $WorkingDirectory -HostPath $HostPath
    return Complete-AskCodex -Capture $capture -Label $Label -TimeoutMilliseconds $TimeoutMilliseconds
}

function Read-MockRecord {
    param([string]$CaptureRoot, [string]$CaseId)

    $path = Join-Path $CaptureRoot ($CaseId + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json)
}

function Get-OutputPath {
    param([string]$StdOut)

    $line = @($StdOut -split "`r?`n" | Where-Object { $_ -like 'output_path=*' } | Select-Object -Last 1)
    if ($line.Count -eq 0) { return '' }
    return $line[0].Substring('output_path='.Length)
}

function Test-ProcessIdentityAlive {
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

function Stop-ProcessIdentity {
    param([int]$ProcessId, [long]$StartTicks, [string]$Label)

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return }
    try {
        if ($process.StartTime.ToUniversalTime().Ticks -eq $StartTicks) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) { Add-Failure "$Label cleanup timed out" }
        }
    } catch [System.InvalidOperationException] {
        return
    } catch {
        Add-Failure "$Label cleanup failed: $($_.Exception.Message)"
    } finally {
        $process.Dispose()
    }
}

function Get-EnvironmentSnapshot {
    param([string[]]$Names)

    $snapshot = @{}
    foreach ($name in $Names) {
        $snapshot[$name] = [System.Environment]::GetEnvironmentVariable($name, [System.EnvironmentVariableTarget]::Process)
    }
    return $snapshot
}

function Restore-EnvironmentSnapshot {
    param([hashtable]$Snapshot)

    foreach ($entry in $Snapshot.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [System.EnvironmentVariableTarget]::Process)
    }
}

function Test-EnvironmentSnapshotEqual {
    param([hashtable]$Left, [hashtable]$Right)

    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($key in $Left.Keys) {
        if (-not $Right.ContainsKey($key) -or [string]$Left[$key] -cne [string]$Right[$key]) { return $false }
    }
    return $true
}

$scriptPath = Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
$legacyScriptPath = Join-Path $RepoRoot 'skills\codex\scripts\ask_codex.ps1'
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dev-harness-ask-codex-' + [guid]::NewGuid().ToString('N'))
$environmentNames = @('PATH', 'USERPROFILE', 'CODEX_HOME', 'TEMP', 'TMP', 'CODEX_CA_CERTIFICATE', 'ASK_CODEX_NATIVE_RECORDER', 'ASK_CODEX_OBSERVED_NATIVE_MODE', 'ASK_CODEX_TEST_CASE', 'ASK_CODEX_TEST_MODE', 'ASK_CODEX_TEST_CAPTURE_ROOT', 'ASK_CODEX_TEST_IDENTITY', 'ASK_CODEX_TEST_MARKER', 'ASK_CODEX_TEST_TOKEN', 'ASK_CODEX_CMD_MARKER')
$originalEnvironment = Get-EnvironmentSnapshot -Names $environmentNames

try {
    $tokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -eq 0 -and $scriptAst.ScriptRequirements.RequiredPSVersion -ge [version]'7.3') {
        Add-Check 'wrapper requires PowerShell 7.3+ before using standard native argument passing'
    } else {
        Add-Failure 'wrapper must require PowerShell 7.3+ with no parse errors'
    }
    $legacyText = Get-Content -LiteralPath $legacyScriptPath -Raw -Encoding utf8
    if ($legacyText -match [regex]::Escape("Join-Path `$PSScriptRoot 'invoke_codex.ps1'") -and $legacyText -notmatch 'function Invoke-CodexProcess') {
        Add-Check 'legacy ask_codex PowerShell entry is a thin invoke_codex compatibility shim'
    } else {
        Add-Failure 'legacy ask_codex PowerShell entry should delegate to invoke_codex without duplicating the implementation'
    }
    $skillText = Get-Content -LiteralPath (Join-Path $RepoRoot 'skills\codex\SKILL.md') -Raw -Encoding utf8
    $windowsOptionsMatch = [regex]::Match($skillText, '(?ms)^### Windows PowerShell options\s*(.*?)(?=^## |^### |\z)')
    $bashOptionsMatch = [regex]::Match($skillText, '(?ms)^### Bash options\s*(.*?)(?=^## |^### |\z)')
    if ($skillText -match '(?m)^### Bash options\s*$' -and
        $skillText -match '(?m)^### Windows PowerShell options\s*$' -and
        $skillText -match 'The Windows PowerShell wrapper reports success only when Codex exits with code 0 and emits an agent response' -and
        $skillText -match '(?m)^### Bash resume limitations\s*$' -and
        $skillText -match [regex]::Escape('-File @(') -and
        $windowsOptionsMatch.Success -and $windowsOptionsMatch.Groups[1].Value -notmatch 'default: workspace-write via full-auto' -and
        $bashOptionsMatch.Success -and $bashOptionsMatch.Groups[1].Value -notmatch '--ephemeral') {
        Add-Check 'skill contract separates Bash and Windows options, defaults, and output guarantees'
    } else {
        Add-Failure 'skill contract still overstates cross-platform options, defaults, or output guarantees'
    }

    $workspace = Join-Path $scratchRoot 'workspace 中文 & spaces'
    $callerRoot = Join-Path $scratchRoot 'caller output root'
    $mockBin = Join-Path $scratchRoot 'mock bin with spaces'
    $captureRoot = Join-Path $scratchRoot 'captures'
    $userProfile = Join-Path $scratchRoot 'user profile'
    $codexHome = Join-Path $scratchRoot 'source codex home'
    $tempRoot = Join-Path $scratchRoot 'process temp'
    foreach ($directory in @($workspace, $callerRoot, $mockBin, $captureRoot, $userProfile, $codexHome, $tempRoot)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $workspaceSentinel = Join-Path $workspace 'sentinel.txt'
    Write-Utf8NoBom -Path $workspaceSentinel -Content 'workspace-must-remain-byte-identical'
    $authSecret = 'auth-secret-' + [guid]::NewGuid().ToString('N')
    Write-Utf8NoBom -Path (Join-Path $codexHome 'auth.json') -Content ('{"token":"' + $authSecret + '"}')
    $caSentinel = Join-Path $scratchRoot 'caller-ca.pem'
    Write-Utf8NoBom -Path $caSentinel -Content 'caller-owned-ca'
    $cmdMarker = Join-Path $scratchRoot 'unsafe-cmd.marker'

    $nativeRecorderSourcePath = Join-Path $scratchRoot 'native-recorder.cs'
    $nativeRecorderPath = Join-Path $scratchRoot 'native-recorder.exe'
    Write-Utf8NoBom -Path $nativeRecorderSourcePath -Content @'
using System;
using System.IO;
using System.Text;

public static class NativeRecorder
{
    private static readonly Encoding Utf8 = new UTF8Encoding(false);

    private static string Env(string name)
    {
        return Environment.GetEnvironmentVariable(name) ?? "";
    }

    private static string Json(string value)
    {
        var result = new StringBuilder("\"");
        foreach (char character in value ?? "")
        {
            switch (character)
            {
                case '\\': result.Append("\\\\"); break;
                case '"': result.Append("\\\""); break;
                case '\r': result.Append("\\r"); break;
                case '\n': result.Append("\\n"); break;
                case '\t': result.Append("\\t"); break;
                default:
                    if (character < 32) result.Append("\\u" + ((int)character).ToString("x4"));
                    else result.Append(character);
                    break;
            }
        }
        return result.Append('"').ToString();
    }

    private static string JsonArray(string[] values)
    {
        return "[" + string.Join(",", Array.ConvertAll(values, Json)) + "]";
    }

    public static int Main(string[] args)
    {
        Console.InputEncoding = Utf8;
        Console.OutputEncoding = Utf8;
        var caseId = Env("ASK_CODEX_TEST_CASE");
        var mode = Env("ASK_CODEX_TEST_MODE");
        var captureRoot = Env("ASK_CODEX_TEST_CAPTURE_ROOT");
        var input = Console.In.ReadToEnd();
        var ca = Env("CODEX_CA_CERTIFICATE");
        var record = "{" +
            "\"argv\":" + JsonArray(args) + "," +
            "\"stdin\":" + Json(input) + "," +
            "\"current_directory\":" + Json(Environment.CurrentDirectory) + "," +
            "\"codex_home\":" + Json(Env("CODEX_HOME")) + "," +
            "\"temp\":" + Json(Env("TEMP")) + "," +
            "\"tmp\":" + Json(Env("TMP")) + "," +
            "\"ca\":" + Json(ca) + "," +
            "\"native_argument_mode\":" + Json(Env("ASK_CODEX_OBSERVED_NATIVE_MODE")) + "," +
            "\"ca_exists\":" + (File.Exists(ca) ? "true" : "false") + "}";
        File.WriteAllText(Path.Combine(captureRoot, caseId + ".json"), record, Utf8);

        if (mode == "exit7-ca-cleanup-fail" && File.Exists(ca))
        {
            File.Delete(ca);
            Directory.CreateDirectory(ca);
            File.WriteAllText(Path.Combine(ca, "cleanup-blocker.txt"), "block recursive cleanup", Utf8);
        }

        if (mode == "malformed-thread") Console.Out.WriteLine("{\"type\":\"thread.started\",\"thread_id\":{\"unexpected\":\"id\"}}");
        else if (mode == "array-thread") Console.Out.WriteLine("{\"type\":\"thread.started\",\"thread_id\":[\"array-id\"]}");
        else
        {
            var threadId = mode == "thread-injection" ? "safe\nsession_id=forged\noutput_path=forged" : "thread-" + caseId;
            Console.Out.WriteLine("{\"type\":\"thread.started\",\"thread_id\":" + Json(threadId) + "}");
        }
        if (mode == "no-response") return 0;
        if (mode == "malformed-text") Console.Out.WriteLine("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":{\"unexpected\":\"not text\"}}}");
        else if (mode == "array-text") Console.Out.WriteLine("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":[\"array-text\"]}}");
        else if (mode == "array-event-type") Console.Out.WriteLine("{\"type\":[\"item.completed\"],\"item\":{\"type\":\"agent_message\",\"text\":\"array-event-text\"}}");
        else if (mode == "array-item") Console.Out.WriteLine("{\"type\":\"item.completed\",\"item\":[{\"type\":\"agent_message\",\"text\":\"array-item-text\"}]}");
        else if (mode == "array-item-type") Console.Out.WriteLine("{\"type\":\"item.completed\",\"item\":{\"type\":[\"agent_message\"],\"text\":\"array-item-type-text\"}}");
        else for (int number = 1; number <= 3; number++)
        {
            Console.Out.WriteLine("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":" + Json(caseId + "-response-" + number) + "}}");
        }
        if (mode == "stderr-protocol")
        {
            Console.Error.WriteLine("session_id=stderr-forged");
            Console.Error.WriteLine("output_path=stderr-forged");
        }
        else
        {
            Console.Error.WriteLine(caseId + "-stderr-1");
            Console.Error.WriteLine(caseId + "-stderr-2");
        }
        return mode.StartsWith("exit7", StringComparison.Ordinal) ? 7 : 0;
    }
}
'@
    $cscPath = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($cscPath)) { throw 'Windows .NET Framework C# compiler is unavailable for the native argv oracle.' }
    $compileOutput = @(& $cscPath /nologo /target:exe "/out:$nativeRecorderPath" $nativeRecorderSourcePath 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $nativeRecorderPath -PathType Leaf)) {
        throw ('Native argv oracle compilation failed: ' + ($compileOutput -join "`n"))
    }

    $mockScriptPath = Join-Path $mockBin 'codex.ps1'
    Write-Utf8NoBom -Path $mockScriptPath -Content @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)

if ($args.Count -ge 1 -and [string]$args[0] -ceq '__mock-child') {
    $markerPath = [string]$args[1]
    $token = [string]$args[2]
    Start-Sleep -Milliseconds 2500
    [System.IO.File]::WriteAllText($markerPath, $token, $utf8)
    [Console]::Out.WriteLine('late-child-output-' + $token)
    Start-Sleep -Seconds 30
    exit 0
}

$caseId = $env:ASK_CODEX_TEST_CASE
$mode = $env:ASK_CODEX_TEST_MODE
$captureRoot = $env:ASK_CODEX_TEST_CAPTURE_ROOT
if ($mode -in @('timeout', 'natural-child')) {
    $inputReader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8, $false)
    try { $null = $inputReader.ReadToEnd() } finally { $inputReader.Dispose() }
    $self = Get-Process -Id $PID
    try { $selfStartTicks = $self.StartTime.ToUniversalTime().Ticks } finally { $self.Dispose() }
    $record = [ordered]@{
        ca = $env:CODEX_CA_CERTIFICATE
        ca_exists = (-not [string]::IsNullOrWhiteSpace($env:CODEX_CA_CERTIFICATE) -and (Test-Path -LiteralPath $env:CODEX_CA_CERTIFICATE -PathType Leaf))
    }
    [System.IO.File]::WriteAllText((Join-Path $captureRoot ($caseId + '.json')), ($record | ConvertTo-Json -Depth 8 -Compress), $utf8)
    $childPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $childPsi.FileName = (Get-Process -Id $PID).Path
    $childPsi.UseShellExecute = $false
    $childPsi.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '__mock-child', $env:ASK_CODEX_TEST_MARKER, $env:ASK_CODEX_TEST_TOKEN)) {
        $childPsi.ArgumentList.Add($argument)
    }
    $child = [System.Diagnostics.Process]::Start($childPsi)
    try {
        $identity = [ordered]@{
            token = $env:ASK_CODEX_TEST_TOKEN
            root_pid = $PID
            root_start_ticks = $selfStartTicks
            child_pid = $child.Id
            child_start_ticks = $child.StartTime.ToUniversalTime().Ticks
        }
        [System.IO.File]::WriteAllText($env:ASK_CODEX_TEST_IDENTITY, ($identity | ConvertTo-Json -Compress), $utf8)
    } finally {
        $child.Dispose()
    }
    [Console]::Out.WriteLine((@{ type = 'thread.started'; thread_id = ('thread-' + $caseId) } | ConvertTo-Json -Compress))
    if ($mode -ceq 'natural-child') {
        [Console]::Out.WriteLine((@{ type = 'item.completed'; item = @{ type = 'agent_message'; text = ($caseId + '-response') } } | ConvertTo-Json -Depth 5 -Compress))
        exit 0
    }
    while ($true) { Start-Sleep -Seconds 1 }
}

$env:ASK_CODEX_OBSERVED_NATIVE_MODE = [string]$PSNativeCommandArgumentPassing
& $env:ASK_CODEX_NATIVE_RECORDER @args
exit $LASTEXITCODE
'@

    $mockCmdPath = Join-Path $mockBin 'codex.cmd'
    Write-Utf8NoBom -Path $mockCmdPath -Content "@echo off`r`n> \"%ASK_CODEX_CMD_MARKER%\" echo unsafe-cmd-fallback`r`nexit /b 93`r`n"
    $mockPath = $mockBin + [System.IO.Path]::PathSeparator + $env:PATH
    $cmdOnlyBin = Join-Path $scratchRoot 'cmd-only bin'
    [System.IO.Directory]::CreateDirectory($cmdOnlyBin) | Out-Null
    Copy-Item -LiteralPath $mockCmdPath -Destination (Join-Path $cmdOnlyBin 'codex.cmd') -Force
    $cmdOnlyPath = $cmdOnlyBin + [System.IO.Path]::PathSeparator + $env:PATH
    $nativeBin = Join-Path $scratchRoot 'native bin with spaces'
    [System.IO.Directory]::CreateDirectory($nativeBin) | Out-Null
    Copy-Item -LiteralPath $nativeRecorderPath -Destination (Join-Path $nativeBin 'codex.exe') -Force
    $nativePath = $nativeBin + [System.IO.Path]::PathSeparator + $env:PATH

    $resumeDriverPath = Join-Path $scratchRoot 'invoke-resume.ps1'
    Write-Utf8NoBom -Path $resumeDriverPath -Content @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$parameters = @{
    Task = $env:ASK_CODEX_DRIVER_TASK
    Workspace = $env:ASK_CODEX_DRIVER_WORKSPACE
    Session = $env:ASK_CODEX_DRIVER_SESSION
    Model = $env:ASK_CODEX_DRIVER_MODEL
    ReadOnly = $true
    Ephemeral = $true
    Output = $env:ASK_CODEX_DRIVER_OUTPUT
    TimeoutSeconds = [int]$env:ASK_CODEX_DRIVER_TIMEOUT
}
& $env:ASK_CODEX_DRIVER_TARGET @parameters
'@

    $fileDriverPath = Join-Path $scratchRoot 'invoke-files.ps1'
    Write-Utf8NoBom -Path $fileDriverPath -Content @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$parameters = @{
    Task = $env:ASK_CODEX_DRIVER_TASK
    Workspace = $env:ASK_CODEX_DRIVER_WORKSPACE
    File = @($env:ASK_CODEX_DRIVER_FILE_A, $env:ASK_CODEX_DRIVER_FILE_B)
    Output = $env:ASK_CODEX_DRIVER_OUTPUT
    TimeoutSeconds = [int]$env:ASK_CODEX_DRIVER_TIMEOUT
}
& $env:ASK_CODEX_DRIVER_TARGET @parameters
'@

    function New-CaseEnvironment {
        param(
            [string]$CaseId,
            [string]$Mode = 'success',
            [switch]$WithoutCa,
            [string]$IdentityPath = '',
            [string]$MarkerPath = '',
            [string]$Token = ''
        )

        return @{
            PATH = $mockPath
            USERPROFILE = $userProfile
            CODEX_HOME = $codexHome
            TEMP = $tempRoot
            TMP = $tempRoot
            CODEX_CA_CERTIFICATE = $(if ($WithoutCa) { $null } else { $caSentinel })
            ASK_CODEX_NATIVE_RECORDER = $nativeRecorderPath
            ASK_CODEX_OBSERVED_NATIVE_MODE = $null
            ASK_CODEX_TEST_CASE = $CaseId
            ASK_CODEX_TEST_MODE = $Mode
            ASK_CODEX_TEST_CAPTURE_ROOT = $captureRoot
            ASK_CODEX_TEST_IDENTITY = $IdentityPath
            ASK_CODEX_TEST_MARKER = $MarkerPath
            ASK_CODEX_TEST_TOKEN = $Token
            ASK_CODEX_CMD_MARKER = $cmdMarker
        }
    }

    $ps5Case = 'ps5-gate'
    $ps5Output = Join-Path $callerRoot 'ps5-must-not-exist.md'
    $ps5Before = Get-TreeSnapshot -Root $workspace
    $ps5Result = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'must not run', '-Workspace', $workspace, '-Output', $ps5Output) -Environment (New-CaseEnvironment -CaseId $ps5Case) -WorkingDirectory $callerRoot -HostPath 'powershell.exe' -Label $ps5Case
    if ($ps5Result.ExitCode -ne 0 -and -not $ps5Result.OuterTimedOut -and
        (Get-TreeSnapshot -Root $workspace) -ceq $ps5Before -and
        -not (Test-Path -LiteralPath $ps5Output) -and
        $null -eq (Read-MockRecord -CaptureRoot $captureRoot -CaseId $ps5Case)) {
        Add-Check 'PowerShell 5.1 fails at the version gate before workspace, output, or backend effects'
    } else {
        Add-Failure "PowerShell 5.1 gate was not zero-side-effect: exit=$($ps5Result.ExitCode) stdout=[$($ps5Result.StdOut)] stderr=[$($ps5Result.StdErr)]"
    }

    $workspaceBefore = Get-TreeSnapshot -Root $workspace
    $newCase = 'new-argv'
    $newOutput = Join-Path $scratchRoot 'outputs\new.md'
    $newInjectionMarker = Join-Path $scratchRoot 'new-injection.marker'
    $newTask = "中文 stdin：请保持参数边界`n  第二行  保留`t制表符"
    $newModel = 'model "quoted" tail\ & echo injected > "' + $newInjectionMarker + '" & rem | < >'
    $newArguments = @('-Task', $newTask, '-Workspace', $workspace, '-Model', $newModel, '-ReadOnly', '-Ephemeral', '-Output', $newOutput, '-TimeoutSeconds', '5')
    $newResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments $newArguments -Environment (New-CaseEnvironment -CaseId $newCase) -WorkingDirectory $callerRoot -Label $newCase
    $newRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $newCase
    $expectedNewArgs = @('exec', '--ignore-user-config', '--cd', $workspace, '--skip-git-repo-check', '--json', '-c', 'model_reasoning_effort="medium"', '--sandbox', 'read-only', '-m', $newModel, '--ephemeral', '-')
    $newContent = if (Test-Path -LiteralPath $newOutput -PathType Leaf) { Get-Content -LiteralPath $newOutput -Raw -Encoding utf8 } else { '' }
    if ($newResult.ExitCode -eq 0 -and -not $newResult.OuterTimedOut -and $null -ne $newRecord -and
        (Test-StringSequenceEqual -Actual @($newRecord.argv) -Expected $expectedNewArgs) -and
        [string]$newRecord.stdin -ceq $newTask -and
        [string]$newRecord.current_directory -ceq $workspace -and
        [string]$newRecord.codex_home -ceq $codexHome -and
        [string]$newRecord.temp -ceq $tempRoot -and [string]$newRecord.tmp -ceq $tempRoot -and
        [string]$newRecord.ca -ceq $caSentinel -and $newRecord.ca_exists -eq $true -and
        $newContent.Contains($newCase + '-response-1') -and $newContent.Contains($newCase + '-response-3') -and
        -not (Test-Path -LiteralPath $newInjectionMarker) -and -not (Test-Path -LiteralPath $cmdMarker)) {
        Add-Check 'new session preserves structured special argv, UTF-8 stdin, environment, and complete JSONL output'
    } else {
        $newRecordText = if ($null -eq $newRecord) { '<missing>' } else { $newRecord | ConvertTo-Json -Depth 8 -Compress }
        Add-Failure "new session behavior mismatch: exit=$($newResult.ExitCode) outer_timeout=$($newResult.OuterTimedOut) record=[$newRecordText] stdout=[$($newResult.StdOut)] stderr=[$($newResult.StdErr)]"
    }

    $structuredCase = 'structured-telemetry'
    $structuredOutput = Join-Path $scratchRoot 'outputs\structured.json'
    $structuredTelemetry = Join-Path $scratchRoot 'outputs\structured.telemetry.json'
    $structuredSchema = Join-Path $scratchRoot 'structured-output.schema.json'
    Write-Utf8NoBom -Path $structuredSchema -Content '{"type":"object","additionalProperties":false,"required":["value"],"properties":{"value":{"type":"string"}}}'
    $structuredModel = 'gpt-5.6-sol'
    $structuredArgs = @('-Task','structured result','-Workspace',$workspace,'-Model',$structuredModel,'-Reasoning','max','-ReadOnly','-ApprovalPolicy','never','-Ephemeral','-Isolated','-AgentOutputOnly','-Quiet','-OutputSchema',$structuredSchema,'-Output',$structuredOutput,'-TelemetryOutput',$structuredTelemetry,'-TimeoutSeconds','5')
    $structuredResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments $structuredArgs -Environment (New-CaseEnvironment -CaseId $structuredCase) -WorkingDirectory $callerRoot -Label $structuredCase
    $structuredRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $structuredCase
    $isolationFeatures = @('plugins','remote_plugin','apps','browser_use','computer_use','memories','multi_agent','multi_agent_v2','enable_fanout','in_app_browser','image_generation')
    $expectedStructuredArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @('-a','never','exec','--ignore-user-config')) { $expectedStructuredArgs.Add($value) }
    foreach ($feature in $isolationFeatures) { $expectedStructuredArgs.Add('--disable'); $expectedStructuredArgs.Add($feature) }
    foreach ($value in @('--cd',$workspace,'--skip-git-repo-check','--json','-c','model_reasoning_effort="max"','--sandbox','read-only','-m',$structuredModel,'--ephemeral','--output-schema',$structuredSchema,'-')) { $expectedStructuredArgs.Add($value) }
    $structuredTelemetryValue = if (Test-Path -LiteralPath $structuredTelemetry -PathType Leaf) { Get-Content -LiteralPath $structuredTelemetry -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
    $structuredContent = if (Test-Path -LiteralPath $structuredOutput -PathType Leaf) { Get-Content -LiteralPath $structuredOutput -Raw -Encoding utf8 } else { '' }
    if ($structuredResult.ExitCode -eq 0 -and $null -ne $structuredRecord -and
        (Test-StringSequenceEqual -Actual @($structuredRecord.argv) -Expected $expectedStructuredArgs.ToArray()) -and
        $null -ne $structuredTelemetryValue -and [string]$structuredTelemetryValue.schema_version -ceq 'codex-invocation-telemetry/v1' -and
        [string]$structuredTelemetryValue.model -ceq $structuredModel -and [string]$structuredTelemetryValue.reasoning -ceq 'max' -and
        [bool]$structuredTelemetryValue.ephemeral -and [string]$structuredTelemetryValue.sandbox -ceq 'read-only' -and [string]$structuredTelemetryValue.approval_policy -ceq 'never' -and
        [int]$structuredTelemetryValue.agent_messages -eq 3 -and [string]$structuredTelemetryValue.tokens.status -ceq 'unavailable' -and
        $structuredResult.StdOut -match '(?m)^telemetry_path=' -and
        $structuredContent.Trim() -ceq ($structuredCase + '-response-3')) {
        Add-Check 'isolated max session preserves structured-output argv and publishes sanitized aggregate telemetry'
    } else {
        Add-Failure "structured telemetry contract failed: exit=$($structuredResult.ExitCode) record=[$($structuredRecord | ConvertTo-Json -Depth 8 -Compress)] telemetry=[$($structuredTelemetryValue | ConvertTo-Json -Depth 8 -Compress)] stderr=[$($structuredResult.StdErr)]"
    }
    $observedNativeMode = if ($null -eq $newRecord) { '' } else { [string]$newRecord.native_argument_mode }
    if ($observedNativeMode -ceq 'Standard') {
        Add-Check 'PowerShell shim observes Standard native argument passing at runtime'
    } else {
        Add-Failure "PowerShell shim native argument mode was not Standard: [$observedNativeMode]"
    }

    $legacyCase = 'legacy-shim'
    $legacyOutput = Join-Path $scratchRoot 'outputs\legacy-shim.md'
    $legacyResult = Invoke-AskCodex -ScriptPath $legacyScriptPath -Arguments @('-Task', 'legacy compatibility', '-Workspace', $workspace, '-Output', $legacyOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $legacyCase) -WorkingDirectory $callerRoot -Label $legacyCase
    $legacyRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $legacyCase
    $legacyContent = if (Test-Path -LiteralPath $legacyOutput -PathType Leaf) { Get-Content -LiteralPath $legacyOutput -Raw -Encoding utf8 } else { '' }
    if ($legacyResult.ExitCode -eq 0 -and $null -ne $legacyRecord -and $legacyContent.Contains($legacyCase + '-response-1')) {
        Add-Check 'legacy ask_codex PowerShell shim preserves the canonical success protocol'
    } else {
        Add-Failure "legacy ask_codex shim failed: exit=$($legacyResult.ExitCode) stdout=[$($legacyResult.StdOut)] stderr=[$($legacyResult.StdErr)]"
    }

    $fileCase = 'file-array-binding'
    $fileA = Join-Path $workspace 'priority  one.txt'
    $fileB = Join-Path $workspace 'priority two.txt'
    Write-Utf8NoBom -Path $fileA -Content 'one'
    Write-Utf8NoBom -Path $fileB -Content 'two'
    $fileOutput = Join-Path $scratchRoot 'outputs\files.md'
    $fileEnvironment = New-CaseEnvironment -CaseId $fileCase
    $fileEnvironment.ASK_CODEX_DRIVER_TARGET = $scriptPath
    $fileEnvironment.ASK_CODEX_DRIVER_TASK = 'PowerShell file array binding'
    $fileEnvironment.ASK_CODEX_DRIVER_WORKSPACE = $workspace
    $fileEnvironment.ASK_CODEX_DRIVER_FILE_A = $fileA
    $fileEnvironment.ASK_CODEX_DRIVER_FILE_B = $fileB
    $fileEnvironment.ASK_CODEX_DRIVER_OUTPUT = $fileOutput
    $fileEnvironment.ASK_CODEX_DRIVER_TIMEOUT = '5'
    $fileResult = Invoke-AskCodex -ScriptPath $fileDriverPath -Arguments @() -Environment $fileEnvironment -WorkingDirectory $callerRoot -Label $fileCase
    $fileRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $fileCase
    if ($fileResult.ExitCode -eq 0 -and $null -ne $fileRecord -and
        [string]$fileRecord.stdin -match [regex]::Escape($fileA) -and
        [string]$fileRecord.stdin -match [regex]::Escape($fileB) -and
        (Test-Path -LiteralPath $fileOutput -PathType Leaf)) {
        Add-Check 'PowerShell File array binds once and includes both priority paths in the prompt'
    } else {
        Add-Failure "PowerShell File array contract failed: exit=$($fileResult.ExitCode) record=[$($fileRecord | ConvertTo-Json -Depth 8 -Compress)] stderr=[$($fileResult.StdErr)]"
    }
    [System.IO.File]::Delete($fileA)
    [System.IO.File]::Delete($fileB)

    $resumeCase = 'resume-readonly'
    $resumeOutput = Join-Path $scratchRoot 'outputs\resume.md'
    $resumeInjectionMarker = Join-Path $scratchRoot 'resume-injection.marker'
    $resumeTask = "继续处理中文 follow-up prompt`n  保留  缩进`t与制表符"
    $resumeSession = '--last & echo injected > "' + $resumeInjectionMarker + '" & rem'
    $resumeModel = 'resume model "quoted" tail\'
    $resumeEnvironment = New-CaseEnvironment -CaseId $resumeCase
    $resumeEnvironment.ASK_CODEX_DRIVER_TARGET = $scriptPath
    $resumeEnvironment.ASK_CODEX_DRIVER_TASK = $resumeTask
    $resumeEnvironment.ASK_CODEX_DRIVER_WORKSPACE = $workspace
    $resumeEnvironment.ASK_CODEX_DRIVER_SESSION = $resumeSession
    $resumeEnvironment.ASK_CODEX_DRIVER_MODEL = $resumeModel
    $resumeEnvironment.ASK_CODEX_DRIVER_OUTPUT = $resumeOutput
    $resumeEnvironment.ASK_CODEX_DRIVER_TIMEOUT = '5'
    $resumeResult = Invoke-AskCodex -ScriptPath $resumeDriverPath -Arguments @() -Environment $resumeEnvironment -WorkingDirectory $callerRoot -Label $resumeCase
    $resumeRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $resumeCase
    $expectedResumeArgs = @('exec', '--ignore-user-config', 'resume', '--json', '--skip-git-repo-check', '-c', 'model_reasoning_effort="medium"', '-c', 'sandbox_mode="read-only"', '-m', $resumeModel, '--ephemeral', '--', $resumeSession, '-')
    if ($resumeResult.ExitCode -eq 0 -and -not $resumeResult.OuterTimedOut -and $null -ne $resumeRecord -and
        (Test-StringSequenceEqual -Actual @($resumeRecord.argv) -Expected $expectedResumeArgs) -and
        [string]$resumeRecord.stdin -ceq $resumeTask -and
        $resumeResult.StdOut.Contains('session_id=thread-' + $resumeCase) -and
        -not (@($resumeRecord.argv) -contains '--sandbox') -and -not (@($resumeRecord.argv) -contains '--cd') -and
        -not (Test-Path -LiteralPath $resumeInjectionMarker) -and -not (Test-Path -LiteralPath $cmdMarker)) {
        Add-Check 'resume keeps readonly config, model/ephemeral, option terminator, leading-dash session, and stdin prompt'
    } else {
        $resumeRecordText = if ($null -eq $resumeRecord) { '<missing>' } else { $resumeRecord | ConvertTo-Json -Depth 8 -Compress }
        Add-Failure "resume behavior mismatch: exit=$($resumeResult.ExitCode) record=[$resumeRecordText] stdout=[$($resumeResult.StdOut)] stderr=[$($resumeResult.StdErr)]"
    }

    $nativeCase = 'direct-native-exe'
    $nativeOutput = Join-Path $scratchRoot 'outputs\native.md'
    $nativeTask = 'direct native UTF-8 stdin'
    $nativeModel = 'native model "quoted" tail\ & literal'
    $nativeEnvironment = New-CaseEnvironment -CaseId $nativeCase
    $nativeEnvironment.PATH = $nativePath
    $nativeResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', $nativeTask, '-Workspace', $workspace, '-Model', $nativeModel, '-ReadOnly', '-Ephemeral', '-Output', $nativeOutput, '-TimeoutSeconds', '5') -Environment $nativeEnvironment -WorkingDirectory $callerRoot -Label $nativeCase
    $nativeRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $nativeCase
    $expectedNativeArgs = @('exec', '--ignore-user-config', '--cd', $workspace, '--skip-git-repo-check', '--json', '-c', 'model_reasoning_effort="medium"', '--sandbox', 'read-only', '-m', $nativeModel, '--ephemeral', '-')
    if ($nativeResult.ExitCode -eq 0 -and -not $nativeResult.OuterTimedOut -and $null -ne $nativeRecord -and
        (Test-StringSequenceEqual -Actual @($nativeRecord.argv) -Expected $expectedNativeArgs) -and
        [string]$nativeRecord.stdin -ceq $nativeTask -and
        (Test-Path -LiteralPath $nativeOutput -PathType Leaf) -and
        -not (Test-Path -LiteralPath $cmdMarker)) {
        Add-Check 'direct native executable branch preserves structured argv and UTF-8 stdin'
    } else {
        $nativeRecordText = if ($null -eq $nativeRecord) { '<missing>' } else { $nativeRecord | ConvertTo-Json -Depth 8 -Compress }
        Add-Failure "direct native executable mismatch: exit=$($nativeResult.ExitCode) record=[$nativeRecordText] stdout=[$($nativeResult.StdOut)] stderr=[$($nativeResult.StdErr)]"
    }

    $cmdOnlyCase = 'cmd-only-rejection'
    $cmdOnlyOutput = Join-Path $scratchRoot 'outputs\cmd-only.md'
    $cmdOnlyEnvironment = New-CaseEnvironment -CaseId $cmdOnlyCase
    $cmdOnlyEnvironment.PATH = $cmdOnlyPath
    $cmdOnlyResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'reject cmd shim', '-Workspace', $workspace, '-Output', $cmdOnlyOutput, '-TimeoutSeconds', '5') -Environment $cmdOnlyEnvironment -WorkingDirectory $callerRoot -Label $cmdOnlyCase
    if ($cmdOnlyResult.ExitCode -ne 0 -and -not $cmdOnlyResult.OuterTimedOut -and
        $cmdOnlyResult.StdErr -match 'Unsafe shell shim is not supported' -and
        -not (Test-Path -LiteralPath $cmdOnlyOutput) -and
        -not (Test-Path -LiteralPath $cmdMarker) -and
        $null -eq (Read-MockRecord -CaptureRoot $captureRoot -CaseId $cmdOnlyCase)) {
        Add-Check 'cmd-only PATH selection fails closed before backend or output effects'
    } else {
        Add-Failure "cmd-only rejection failed: exit=$($cmdOnlyResult.ExitCode) marker=$(Test-Path -LiteralPath $cmdMarker) stdout=[$($cmdOnlyResult.StdOut)] stderr=[$($cmdOnlyResult.StdErr)]"
    }

    $missingOutput = Join-Path $scratchRoot 'outputs\must-not-exist.md'
    $exitNewResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'exit seven new', '-Workspace', $workspace, '-Output', $missingOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId 'exit7-new' -Mode 'exit7') -WorkingDirectory $callerRoot -Label 'exit7-new'
    if ($exitNewResult.ExitCode -ne 0 -and -not $exitNewResult.OuterTimedOut -and
        -not (Test-Path -LiteralPath $missingOutput) -and
        $exitNewResult.StdErr -match 'exited with code 7' -and
        $exitNewResult.StdOut -notmatch '(?m)^(session_id|output_path)=') {
        Add-Check 'new session exit 7 remains failure despite valid thread and agent output'
    } else {
        Add-Failure "new exit7 published or disguised failure: exit=$($exitNewResult.ExitCode) stdout=[$($exitNewResult.StdOut)] stderr=[$($exitNewResult.StdErr)]"
    }

    $existingOutput = Join-Path $scratchRoot 'outputs\existing.bin'
    $existingBytes = [byte[]](0, 255, 17, 34, 128, 10)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $existingOutput)) | Out-Null
    [System.IO.File]::WriteAllBytes($existingOutput, $existingBytes)
    $exitResumeEnvironment = New-CaseEnvironment -CaseId 'exit7-resume' -Mode 'exit7'
    $exitResumeEnvironment.ASK_CODEX_DRIVER_TARGET = $scriptPath
    $exitResumeEnvironment.ASK_CODEX_DRIVER_TASK = 'exit seven resume'
    $exitResumeEnvironment.ASK_CODEX_DRIVER_WORKSPACE = $workspace
    $exitResumeEnvironment.ASK_CODEX_DRIVER_SESSION = 'resume-existing'
    $exitResumeEnvironment.ASK_CODEX_DRIVER_MODEL = ''
    $exitResumeEnvironment.ASK_CODEX_DRIVER_OUTPUT = $existingOutput
    $exitResumeEnvironment.ASK_CODEX_DRIVER_TIMEOUT = '5'
    $exitResumeResult = Invoke-AskCodex -ScriptPath $resumeDriverPath -Arguments @() -Environment $exitResumeEnvironment -WorkingDirectory $callerRoot -Label 'exit7-resume'
    $existingAfter = [System.IO.File]::ReadAllBytes($existingOutput)
    if ($exitResumeResult.ExitCode -ne 0 -and -not $exitResumeResult.OuterTimedOut -and
        [System.Convert]::ToBase64String($existingAfter) -ceq [System.Convert]::ToBase64String($existingBytes) -and
        $exitResumeResult.StdOut -notmatch '(?m)^(session_id|output_path)=') {
        Add-Check 'resume exit 7 preserves the exact pre-existing Output bytes'
    } else {
        Add-Failure "resume exit7 changed pre-existing Output: exit=$($exitResumeResult.ExitCode) stdout=[$($exitResumeResult.StdOut)] stderr=[$($exitResumeResult.StdErr)]"
    }

    $overwriteCase = 'success-overwrite'
    $overwriteOutput = Join-Path $scratchRoot 'outputs\success-overwrite.md'
    Write-Utf8NoBom -Path $overwriteOutput -Content 'old-success-content'
    $overwriteResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'replace existing output on success', '-Workspace', $workspace, '-Output', $overwriteOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $overwriteCase) -WorkingDirectory $callerRoot -Label $overwriteCase
    $overwriteContent = if (Test-Path -LiteralPath $overwriteOutput -PathType Leaf) { Get-Content -LiteralPath $overwriteOutput -Raw -Encoding utf8 } else { '' }
    $overwriteTemps = @(Get-ChildItem -LiteralPath (Split-Path -Parent $overwriteOutput) -Filter ('.{0}.*.tmp' -f [System.IO.Path]::GetFileName($overwriteOutput)) -File -Force -ErrorAction SilentlyContinue)
    if ($overwriteResult.ExitCode -eq 0 -and -not $overwriteResult.OuterTimedOut -and
        $overwriteContent.Contains($overwriteCase + '-response-1') -and
        -not $overwriteContent.Contains('old-success-content') -and
        $overwriteTemps.Count -eq 0 -and
        $overwriteResult.StdOut -match '(?m)^output_path=') {
        Add-Check 'successful invocation atomically replaces an existing Output and leaves no temp file'
    } else {
        Add-Failure "successful existing Output replacement failed: exit=$($overwriteResult.ExitCode) content=[$overwriteContent] temps=$($overwriteTemps.Count) stdout=[$($overwriteResult.StdOut)] stderr=[$($overwriteResult.StdErr)]"
    }

    $lockedCase = 'locked-publish'
    $lockedOutput = Join-Path $scratchRoot 'outputs\locked-publish.md'
    $lockedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('locked-original-content')
    [System.IO.File]::WriteAllBytes($lockedOutput, $lockedBytes)
    $lockedStream = [System.IO.FileStream]::new($lockedOutput, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    try {
        $lockedResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'locked output publish failure', '-Workspace', $workspace, '-Output', $lockedOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $lockedCase) -WorkingDirectory $callerRoot -Label $lockedCase
    } finally {
        $lockedStream.Dispose()
    }
    $lockedAfter = [System.IO.File]::ReadAllBytes($lockedOutput)
    $lockedTemps = @(Get-ChildItem -LiteralPath (Split-Path -Parent $lockedOutput) -Filter ('.{0}.*.tmp' -f [System.IO.Path]::GetFileName($lockedOutput)) -File -Force -ErrorAction SilentlyContinue)
    if ($lockedResult.ExitCode -ne 0 -and -not $lockedResult.OuterTimedOut -and
        [System.Convert]::ToBase64String($lockedAfter) -ceq [System.Convert]::ToBase64String($lockedBytes) -and
        $lockedTemps.Count -eq 0 -and
        $lockedResult.StdOut -notmatch '(?m)^(session_id|output_path)=') {
        Add-Check 'locked destination publish failure preserves old bytes, removes temp, and emits no success protocol'
    } else {
        Add-Failure "locked destination atomic failure contract broke: exit=$($lockedResult.ExitCode) temps=$($lockedTemps.Count) stdout=[$($lockedResult.StdOut)] stderr=[$($lockedResult.StdErr)]"
    }

    $noResponseOutput = Join-Path $scratchRoot 'outputs\no-response.md'
    $noResponseResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'no response', '-Workspace', $workspace, '-Output', $noResponseOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId 'no-response' -Mode 'no-response') -WorkingDirectory $callerRoot -Label 'no-response'
    if ($noResponseResult.ExitCode -ne 0 -and -not $noResponseResult.OuterTimedOut -and
        -not (Test-Path -LiteralPath $noResponseOutput) -and
        $noResponseResult.StdErr -match 'without an agent response' -and
        $noResponseResult.StdOut -notmatch '(?m)^(session_id|output_path)=') {
        Add-Check 'exit 0 without an agent response fails before Output publication'
    } else {
        Add-Failure "no-response path was not fail-closed: exit=$($noResponseResult.ExitCode) stdout=[$($noResponseResult.StdOut)] stderr=[$($noResponseResult.StdErr)]"
    }

    $schemaCases = @(
        [pscustomobject]@{ Name = 'malformed-text'; Error = 'agent message text must be a string'; Check = 'object agent text fails before Output publication' },
        [pscustomobject]@{ Name = 'malformed-thread'; Error = 'thread_id must be a string'; Check = 'object thread id fails before Output or protocol publication' },
        [pscustomobject]@{ Name = 'array-text'; Error = 'agent message text must be a string'; Check = 'array agent text cannot collapse into a response' },
        [pscustomobject]@{ Name = 'array-thread'; Error = 'thread_id must be a string'; Check = 'array thread id cannot collapse into a session' },
        [pscustomobject]@{ Name = 'array-event-type'; Error = 'event type must be a string'; Check = 'array event discriminator cannot select a completed item' },
        [pscustomobject]@{ Name = 'array-item'; Error = 'without an agent response'; Check = 'array item cannot collapse into an agent message' },
        [pscustomobject]@{ Name = 'array-item-type'; Error = 'item type must be a string'; Check = 'array item discriminator cannot select an agent message' }
    )
    foreach ($case in $schemaCases) {
        $caseOutput = Join-Path $scratchRoot ('outputs\' + $case.Name + '.md')
        $caseResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', ('reject schema ' + $case.Name), '-Workspace', $workspace, '-Output', $caseOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $case.Name -Mode $case.Name) -WorkingDirectory $callerRoot -Label $case.Name
        if ($caseResult.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $caseOutput) -and
            $caseResult.StdErr -match $case.Error -and
            $caseResult.StdOut -notmatch '(?m)^(session_id|output_path)=') {
            Add-Check $case.Check
        } else {
            Add-Failure "malformed schema $($case.Name) was accepted: exit=$($caseResult.ExitCode) output=$(Test-Path -LiteralPath $caseOutput) stdout=[$($caseResult.StdOut)] stderr=[$($caseResult.StdErr)]"
        }
    }

    $threadInjectionOutput = Join-Path $scratchRoot 'outputs\thread-injection.md'
    $threadInjectionResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'reject protocol thread id', '-Workspace', $workspace, '-Output', $threadInjectionOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId 'thread-injection' -Mode 'thread-injection') -WorkingDirectory $callerRoot -Label 'thread-injection'
    if ($threadInjectionResult.ExitCode -ne 0 -and -not $threadInjectionResult.OuterTimedOut -and
        -not (Test-Path -LiteralPath $threadInjectionOutput) -and
        $threadInjectionResult.StdErr -match 'control character' -and
        $threadInjectionResult.StdOut -notmatch '(?m)^(session_id|output_path)=') {
        Add-Check 'JSONL thread id control characters fail before Output or protocol publication'
    } else {
        Add-Failure "thread protocol injection was not rejected: exit=$($threadInjectionResult.ExitCode) output=$(Test-Path -LiteralPath $threadInjectionOutput) stdout=[$($threadInjectionResult.StdOut)] stderr=[$($threadInjectionResult.StdErr)]"
    }

    $sessionInjectionCase = 'session-control'
    $sessionInjectionOutput = Join-Path $scratchRoot 'outputs\session-control.md'
    $sessionInjectionEnvironment = New-CaseEnvironment -CaseId $sessionInjectionCase
    $sessionInjectionEnvironment.ASK_CODEX_DRIVER_TARGET = $scriptPath
    $sessionInjectionEnvironment.ASK_CODEX_DRIVER_TASK = 'reject session control'
    $sessionInjectionEnvironment.ASK_CODEX_DRIVER_WORKSPACE = $workspace
    $sessionInjectionEnvironment.ASK_CODEX_DRIVER_SESSION = "safe`nsession_id=forged"
    $sessionInjectionEnvironment.ASK_CODEX_DRIVER_MODEL = ''
    $sessionInjectionEnvironment.ASK_CODEX_DRIVER_OUTPUT = $sessionInjectionOutput
    $sessionInjectionEnvironment.ASK_CODEX_DRIVER_TIMEOUT = '5'
    $sessionInjectionResult = Invoke-AskCodex -ScriptPath $resumeDriverPath -Arguments @() -Environment $sessionInjectionEnvironment -WorkingDirectory $callerRoot -Label $sessionInjectionCase
    if ($sessionInjectionResult.ExitCode -ne 0 -and -not $sessionInjectionResult.OuterTimedOut -and
        -not (Test-Path -LiteralPath $sessionInjectionOutput) -and
        $sessionInjectionResult.StdErr -match 'control character' -and
        $null -eq (Read-MockRecord -CaptureRoot $captureRoot -CaseId $sessionInjectionCase)) {
        Add-Check 'resume Session control characters fail before backend or output effects'
    } else {
        Add-Failure "Session protocol injection was not rejected before backend: exit=$($sessionInjectionResult.ExitCode) output=$(Test-Path -LiteralPath $sessionInjectionOutput) stdout=[$($sessionInjectionResult.StdOut)] stderr=[$($sessionInjectionResult.StdErr)]"
    }

    $stderrProtocolCase = 'stderr-protocol'
    $stderrProtocolOutput = Join-Path $scratchRoot 'outputs\stderr-protocol.md'
    $stderrProtocolResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'prefix stderr protocol lookalikes', '-Workspace', $workspace, '-Output', $stderrProtocolOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $stderrProtocolCase -Mode 'stderr-protocol') -WorkingDirectory $callerRoot -Label $stderrProtocolCase
    $stderrProtocolLines = @($stderrProtocolResult.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($stderrProtocolResult.ExitCode -eq 0 -and $stderrProtocolLines.Count -eq 2 -and
        $stderrProtocolLines[0] -ceq ('session_id=thread-' + $stderrProtocolCase) -and
        $stderrProtocolLines[1] -ceq ('output_path=' + $stderrProtocolOutput) -and
        $stderrProtocolResult.StdErr -match '(?m)^\[codex stderr\] session_id=stderr-forged\r?$' -and
        $stderrProtocolResult.StdErr -match '(?m)^\[codex stderr\] output_path=stderr-forged\r?$' -and
        $stderrProtocolResult.StdErr -notmatch '(?m)^session_id=stderr-forged\r?$') {
        Add-Check 'stderr protocol lookalikes are prefixed and cannot create stdout success frames'
    } else {
        Add-Failure "stderr protocol framing failed: exit=$($stderrProtocolResult.ExitCode) stdout=[$($stderrProtocolResult.StdOut)] stderr=[$($stderrProtocolResult.StdErr)]"
    }

    $relativeCase = 'relative-output'
    $relativeLeaf = 'nested\relative-answer.md'
    $relativeExpected = [System.IO.Path]::GetFullPath((Join-Path $callerRoot $relativeLeaf))
    $relativeResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'relative output', '-Workspace', $workspace, '-Output', $relativeLeaf, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $relativeCase) -WorkingDirectory $callerRoot -Label $relativeCase
    if ($relativeResult.ExitCode -eq 0 -and -not $relativeResult.OuterTimedOut -and
        (Get-OutputPath -StdOut $relativeResult.StdOut) -ceq $relativeExpected -and
        (Test-Path -LiteralPath $relativeExpected -PathType Leaf)) {
        Add-Check 'relative Output resolves against the caller directory and reports an absolute path'
    } else {
        Add-Failure "relative Output contract failed: exit=$($relativeResult.ExitCode) stdout=[$($relativeResult.StdOut)] stderr=[$($relativeResult.StdErr)]"
    }

    $caCase = 'ca-cleanup'
    $caBefore = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'dev-harness-codex-ca-*.pem' -File -Force | ForEach-Object { $_.FullName })
    $caOutput = Join-Path $scratchRoot 'outputs\ca.md'
    $caResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'ca cleanup', '-Workspace', $workspace, '-Output', $caOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $caCase -WithoutCa) -WorkingDirectory $callerRoot -Label $caCase
    $caRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $caCase
    $caValue = if ($null -eq $caRecord) { '' } else { [string]$caRecord.ca }
    $caUnderTemp = -not [string]::IsNullOrWhiteSpace($caValue) -and
        [System.IO.Path]::GetFullPath($caValue).StartsWith([System.IO.Path]::GetFullPath($tempRoot) + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    $caAfter = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'dev-harness-codex-ca-*.pem' -File -Force | ForEach-Object { $_.FullName })
    if ($caResult.ExitCode -eq 0 -and $null -ne $caRecord -and $caRecord.ca_exists -eq $true -and
        $caUnderTemp -and
        -not (Test-Path -LiteralPath $caValue) -and
        $caBefore.Count -eq $caAfter.Count) {
        Add-Check 'generated CA is child-only, system-temp scoped, and deleted after success'
    } else {
        Add-Failure "temporary CA lifecycle failed: exit=$($caResult.ExitCode) ca=[$caValue] before=$($caBefore.Count) after=$($caAfter.Count) stderr=[$($caResult.StdErr)]"
    }

    $caExitCase = 'ca-exit7-cleanup'
    $caExitOutput = Join-Path $scratchRoot 'outputs\ca-exit7.md'
    $caExitBefore = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'dev-harness-codex-ca-*.pem' -File -Force)
    $caExitResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'ca exit cleanup', '-Workspace', $workspace, '-Output', $caExitOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $caExitCase -Mode 'exit7' -WithoutCa) -WorkingDirectory $callerRoot -Label $caExitCase
    $caExitRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $caExitCase
    $caExitPath = if ($null -eq $caExitRecord) { '' } else { [string]$caExitRecord.ca }
    $caExitAfter = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'dev-harness-codex-ca-*.pem' -File -Force)
    if ($caExitResult.ExitCode -ne 0 -and $null -ne $caExitRecord -and $caExitRecord.ca_exists -eq $true -and
        -not [string]::IsNullOrWhiteSpace($caExitPath) -and -not (Test-Path -LiteralPath $caExitPath) -and
        $caExitBefore.Count -eq $caExitAfter.Count -and -not (Test-Path -LiteralPath $caExitOutput) -and
        $caExitResult.StdErr -match 'exited with code 7') {
        Add-Check 'generated CA is deleted when Codex exits nonzero'
    } else {
        Add-Failure "generated CA exit7 cleanup failed: exit=$($caExitResult.ExitCode) ca=[$caExitPath] before=$($caExitBefore.Count) after=$($caExitAfter.Count) stderr=[$($caExitResult.StdErr)]"
    }

    $caFailureCase = 'ca-cleanup-failure'
    $caFailureOutput = Join-Path $scratchRoot 'outputs\ca-cleanup-failure.md'
    $caFailureResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'ca cleanup failure aggregation', '-Workspace', $workspace, '-Output', $caFailureOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $caFailureCase -Mode 'exit7-ca-cleanup-fail' -WithoutCa) -WorkingDirectory $callerRoot -Label $caFailureCase
    $caFailureRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $caFailureCase
    $caFailurePath = if ($null -eq $caFailureRecord) { '' } else { [string]$caFailureRecord.ca }
    if ($caFailureResult.ExitCode -ne 0 -and $null -ne $caFailureRecord -and
        -not (Test-Path -LiteralPath $caFailureOutput) -and
        $caFailureResult.StdErr -match 'exited with code 7' -and
        $caFailureResult.StdErr -match 'CA cleanup failure' -and
        -not [string]::IsNullOrWhiteSpace($caFailurePath) -and
        (Test-Path -LiteralPath $caFailurePath -PathType Container)) {
        Add-Check 'CA cleanup failure preserves the primary exit error and adds cleanup diagnostics'
    } else {
        Add-Failure "CA cleanup aggregation lost diagnostics: exit=$($caFailureResult.ExitCode) ca=[$caFailurePath] stdout=[$($caFailureResult.StdOut)] stderr=[$($caFailureResult.StdErr)]"
    }

    $inProcessSnapshot = Get-EnvironmentSnapshot -Names $environmentNames
    $originalConsoleError = [Console]::Error
    $capturedConsoleError = [System.IO.StringWriter]::new()
    try {
        [Console]::SetError($capturedConsoleError)
        $inProcessValues = New-CaseEnvironment -CaseId 'env-success'
        foreach ($entry in $inProcessValues.GetEnumerator()) {
            [System.Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [System.EnvironmentVariableTarget]::Process)
        }
        $expectedEnvironment = Get-EnvironmentSnapshot -Names @('CODEX_HOME', 'TEMP', 'TMP', 'CODEX_CA_CERTIFICATE')
        $successThrew = $false
        try {
            & $scriptPath -Task 'environment success' -Workspace $workspace -Output (Join-Path $scratchRoot 'outputs\env-success.md') -TimeoutSeconds 5 *> $null
        } catch { $successThrew = $true }
        $afterSuccessEnvironment = Get-EnvironmentSnapshot -Names @('CODEX_HOME', 'TEMP', 'TMP', 'CODEX_CA_CERTIFICATE')

        $env:ASK_CODEX_TEST_CASE = 'env-failure'
        $env:ASK_CODEX_TEST_MODE = 'exit7'
        $failureThrew = $false
        try {
            & $scriptPath -Task 'environment failure' -Workspace $workspace -Output (Join-Path $scratchRoot 'outputs\env-failure.md') -TimeoutSeconds 5 *> $null
        } catch { $failureThrew = $true }
        $afterFailureEnvironment = Get-EnvironmentSnapshot -Names @('CODEX_HOME', 'TEMP', 'TMP', 'CODEX_CA_CERTIFICATE')

        $successEnvironmentSame = Test-EnvironmentSnapshotEqual -Left $afterSuccessEnvironment -Right $expectedEnvironment
        $failureEnvironmentSame = Test-EnvironmentSnapshotEqual -Left $afterFailureEnvironment -Right $expectedEnvironment
        if (-not $successThrew -and $failureThrew -and $successEnvironmentSame -and $failureEnvironmentSame) {
            Add-Check 'caller CODEX_HOME/TEMP/TMP/CA environment is byte-equivalent after success and failure'
        } else {
            Add-Failure "caller environment changed: success_threw=$successThrew failure_threw=$failureThrew success_same=$successEnvironmentSame failure_same=$failureEnvironmentSame"
        }
    } finally {
        [Console]::SetError($originalConsoleError)
        $capturedConsoleError.Dispose()
        Restore-EnvironmentSnapshot -Snapshot $inProcessSnapshot
    }

    $scriptCopyRoot = Join-Path $scratchRoot 'copied production skill'
    $scriptCopyPath = Join-Path $scriptCopyRoot 'scripts\ask_codex.ps1'
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $scriptCopyPath)) | Out-Null
    Copy-Item -LiteralPath $scriptPath -Destination $scriptCopyPath -Force
    $defaultCaptureA = Start-AskCodex -ScriptPath $scriptCopyPath -Arguments @('-Task', 'default A', '-Workspace', $workspace, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId 'default-a') -WorkingDirectory $callerRoot
    $defaultCaptureB = Start-AskCodex -ScriptPath $scriptCopyPath -Arguments @('-Task', 'default B', '-Workspace', $workspace, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId 'default-b') -WorkingDirectory $callerRoot
    $defaultA = Complete-AskCodex -Capture $defaultCaptureA -Label 'default-a'
    $defaultB = Complete-AskCodex -Capture $defaultCaptureB -Label 'default-b'
    $defaultPathA = Get-OutputPath -StdOut $defaultA.StdOut
    $defaultPathB = Get-OutputPath -StdOut $defaultB.StdOut
    $defaultContentA = if (-not [string]::IsNullOrWhiteSpace($defaultPathA) -and (Test-Path -LiteralPath $defaultPathA -PathType Leaf)) { Get-Content -LiteralPath $defaultPathA -Raw -Encoding utf8 } else { '' }
    $defaultContentB = if (-not [string]::IsNullOrWhiteSpace($defaultPathB) -and (Test-Path -LiteralPath $defaultPathB -PathType Leaf)) { Get-Content -LiteralPath $defaultPathB -Raw -Encoding utf8 } else { '' }
    if ($defaultA.ExitCode -eq 0 -and $defaultB.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($defaultPathA) -and -not [string]::IsNullOrWhiteSpace($defaultPathB) -and
        $defaultPathA -cne $defaultPathB -and
        $defaultContentA.Contains('default-a-response-1') -and $defaultContentB.Contains('default-b-response-1')) {
        Add-Check 'concurrent default outputs use distinct files without cross-overwrite'
    } else {
        Add-Failure "concurrent default output collision: a_exit=$($defaultA.ExitCode) b_exit=$($defaultB.ExitCode) a=[$defaultPathA] b=[$defaultPathB]"
    }

    $naturalCase = 'natural-child'
    $naturalIdentityPath = Join-Path $captureRoot ($naturalCase + '.identity.json')
    $naturalMarkerPath = Join-Path $captureRoot ($naturalCase + '.late.marker')
    $naturalToken = [guid]::NewGuid().ToString('N')
    $naturalOutput = Join-Path $scratchRoot 'outputs\natural-child.md'
    $naturalResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'natural exit tree close', '-Workspace', $workspace, '-Output', $naturalOutput, '-TimeoutSeconds', '5') -Environment (New-CaseEnvironment -CaseId $naturalCase -Mode 'natural-child' -IdentityPath $naturalIdentityPath -MarkerPath $naturalMarkerPath -Token $naturalToken) -WorkingDirectory $callerRoot -Label $naturalCase -TimeoutMilliseconds 12000
    $naturalIdentity = if (Test-Path -LiteralPath $naturalIdentityPath -PathType Leaf) { Get-Content -LiteralPath $naturalIdentityPath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
    if ($null -ne $naturalIdentity -and [string]$naturalIdentity.token -ceq $naturalToken) {
        $script:cleanupIdentities.Add([pscustomobject]@{ Id = [int]$naturalIdentity.root_pid; Ticks = [long]$naturalIdentity.root_start_ticks; Label = 'natural root' })
        $script:cleanupIdentities.Add([pscustomobject]@{ Id = [int]$naturalIdentity.child_pid; Ticks = [long]$naturalIdentity.child_start_ticks; Label = 'natural child' })
    }
    Start-Sleep -Milliseconds 3000
    $naturalRootAlive = $null -ne $naturalIdentity -and (Test-ProcessIdentityAlive -ProcessId ([int]$naturalIdentity.root_pid) -StartTicks ([long]$naturalIdentity.root_start_ticks))
    $naturalChildAlive = $null -ne $naturalIdentity -and (Test-ProcessIdentityAlive -ProcessId ([int]$naturalIdentity.child_pid) -StartTicks ([long]$naturalIdentity.child_start_ticks))
    $naturalContent = if (Test-Path -LiteralPath $naturalOutput -PathType Leaf) { Get-Content -LiteralPath $naturalOutput -Raw -Encoding utf8 } else { '' }
    if ($naturalResult.ExitCode -eq 0 -and -not $naturalResult.OuterTimedOut -and
        $null -ne $naturalIdentity -and [string]$naturalIdentity.token -ceq $naturalToken -and
        -not $naturalRootAlive -and -not $naturalChildAlive -and
        -not (Test-Path -LiteralPath $naturalMarkerPath) -and
        $naturalContent.Contains($naturalCase + '-response')) {
        Add-Check 'natural root exit closes the exact inherited-pipe descendant tree before publishing output'
    } else {
        Add-Failure "natural tree close failed: exit=$($naturalResult.ExitCode) outer_timeout=$($naturalResult.OuterTimedOut) root_alive=$naturalRootAlive child_alive=$naturalChildAlive marker=$(Test-Path -LiteralPath $naturalMarkerPath) stdout=[$($naturalResult.StdOut)] stderr=[$($naturalResult.StdErr)]"
    }

    $timeoutCase = 'timeout-tree'
    $timeoutIdentityPath = Join-Path $captureRoot ($timeoutCase + '.identity.json')
    $timeoutMarkerPath = Join-Path $captureRoot ($timeoutCase + '.late.marker')
    $timeoutToken = [guid]::NewGuid().ToString('N')
    $timeoutOutput = Join-Path $scratchRoot 'outputs\timeout.md'
    $timeoutCaBefore = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'dev-harness-codex-ca-*.pem' -File -Force)
    $timeoutResult = Invoke-AskCodex -ScriptPath $scriptPath -Arguments @('-Task', 'timeout tree', '-Workspace', $workspace, '-Output', $timeoutOutput, '-TimeoutSeconds', '1') -Environment (New-CaseEnvironment -CaseId $timeoutCase -Mode 'timeout' -WithoutCa -IdentityPath $timeoutIdentityPath -MarkerPath $timeoutMarkerPath -Token $timeoutToken) -WorkingDirectory $callerRoot -Label $timeoutCase -TimeoutMilliseconds 12000
    $timeoutIdentity = if (Test-Path -LiteralPath $timeoutIdentityPath -PathType Leaf) { Get-Content -LiteralPath $timeoutIdentityPath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
    $timeoutRecord = Read-MockRecord -CaptureRoot $captureRoot -CaseId $timeoutCase
    $timeoutCaPath = if ($null -eq $timeoutRecord) { '' } else { [string]$timeoutRecord.ca }
    $timeoutCaAfter = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'dev-harness-codex-ca-*.pem' -File -Force)
    if ($null -ne $timeoutIdentity -and [string]$timeoutIdentity.token -ceq $timeoutToken) {
        $script:cleanupIdentities.Add([pscustomobject]@{ Id = [int]$timeoutIdentity.root_pid; Ticks = [long]$timeoutIdentity.root_start_ticks; Label = 'timeout root' })
        $script:cleanupIdentities.Add([pscustomobject]@{ Id = [int]$timeoutIdentity.child_pid; Ticks = [long]$timeoutIdentity.child_start_ticks; Label = 'timeout child' })
    }
    Start-Sleep -Milliseconds 3000
    $timeoutRootAlive = $null -ne $timeoutIdentity -and (Test-ProcessIdentityAlive -ProcessId ([int]$timeoutIdentity.root_pid) -StartTicks ([long]$timeoutIdentity.root_start_ticks))
    $timeoutChildAlive = $null -ne $timeoutIdentity -and (Test-ProcessIdentityAlive -ProcessId ([int]$timeoutIdentity.child_pid) -StartTicks ([long]$timeoutIdentity.child_start_ticks))
    if ($timeoutResult.ExitCode -ne 0 -and -not $timeoutResult.OuterTimedOut -and
        $null -ne $timeoutIdentity -and [string]$timeoutIdentity.token -ceq $timeoutToken -and
        -not $timeoutRootAlive -and -not $timeoutChildAlive -and
        -not (Test-Path -LiteralPath $timeoutMarkerPath) -and -not (Test-Path -LiteralPath $timeoutOutput) -and
        $null -ne $timeoutRecord -and $timeoutRecord.ca_exists -eq $true -and
        -not [string]::IsNullOrWhiteSpace($timeoutCaPath) -and -not (Test-Path -LiteralPath $timeoutCaPath) -and
        $timeoutCaBefore.Count -eq $timeoutCaAfter.Count -and
        $timeoutResult.StdErr -match 'timed out') {
        Add-Check 'timeout is bounded, kills the exact inherited-pipe tree, and cleans generated CA/output/marker residue'
    } else {
        Add-Failure "timeout tree cleanup failed: exit=$($timeoutResult.ExitCode) outer_timeout=$($timeoutResult.OuterTimedOut) root_alive=$timeoutRootAlive child_alive=$timeoutChildAlive marker=$(Test-Path -LiteralPath $timeoutMarkerPath) stdout=[$($timeoutResult.StdOut)] stderr=[$($timeoutResult.StdErr)]"
    }

    $workspaceAfter = Get-TreeSnapshot -Root $workspace
    $workspaceContainsSecret = $false
    foreach ($file in Get-ChildItem -LiteralPath $workspace -Recurse -File -Force) {
        try {
            if ((Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8).Contains($authSecret)) { $workspaceContainsSecret = $true }
        } catch {}
    }
    if ($workspaceAfter -ceq $workspaceBefore -and
        -not $workspaceContainsSecret -and
        -not (Test-Path -LiteralPath (Join-Path $workspace '.tmp\codex-home\auth.json')) -and
        (Get-Content -LiteralPath (Join-Path $codexHome 'auth.json') -Raw -Encoding utf8).Contains($authSecret)) {
        Add-Check 'readonly calls leave workspace byte-identical and never copy or expose source auth'
    } else {
        Add-Failure 'workspace/auth boundary changed during production-wrapper probes'
    }
} catch {
    Add-Failure ('verifier threw: ' + $_.Exception.Message)
} finally {
    Restore-EnvironmentSnapshot -Snapshot $originalEnvironment
    foreach ($identity in $script:cleanupIdentities) {
        Stop-ProcessIdentity -ProcessId $identity.Id -StartTicks $identity.Ticks -Label $identity.Label
    }
    Remove-DirectoryWithRetry -Path $scratchRoot
}

Write-Output 'Ask Codex behavior checks:'
foreach ($check in $script:checks) { Write-Output ('- PASS: ' + $check) }
if ($script:failures.Count -gt 0) {
    foreach ($failure in $script:failures) { Write-Output ('- FAIL: ' + $failure) }
    exit 1
}
Write-Output ("STATUS: PASS ({0} checks)" -f $script:checks.Count)
