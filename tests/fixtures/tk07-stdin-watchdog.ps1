[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImplementationRoot,
    [ValidateSet('normal','no-read','early-close','shared-deadline')][string]$Mode = 'no-read',
    [ValidateSet('pwsh','windows_powershell')][string]$HostName = 'pwsh'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pwsh = (Get-Process -Id $PID).Path
$hostPath = if ($HostName -ceq 'pwsh') { $pwsh } else { Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe' }
$receiptRoot = Join-Path $env:TEMP ('stdin-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($receiptRoot)
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $hostPath
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
$info.Environment['TEMP'] = $env:TEMP
$info.Environment['TMP'] = $env:TMP
foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'tk07-process-stdin.ps1'),
    '-RepoRoot',$ImplementationRoot,'-ReceiptRoot',$receiptRoot,'-PwshPath',$pwsh,'-Mode',$Mode,'-TimeoutMilliseconds','5000')) {
    $info.ArgumentList.Add($arg)
}
$started = [DateTimeOffset]::UtcNow
$process = [Diagnostics.Process]::Start($info)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
$watchdog = -not $process.WaitForExit(12000)
$observed = [DateTimeOffset]::UtcNow
$receiptPath = Join-Path $receiptRoot 'child.json'
$child = if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json } else { $null }
$aliveBeforeSafety = $false
if ($null -ne $child) {
    $owned = Get-Process -Id $child.pid -ErrorAction SilentlyContinue
    if ($null -ne $owned) {
        $aliveBeforeSafety = $owned.StartTime.ToUniversalTime().Ticks -eq [long]$child.start_ticks
        $owned.Dispose()
    }
}
if ($watchdog) { $process.Kill($true); [void]$process.WaitForExit(5000) }
if ($aliveBeforeSafety) {
    $owned = Get-Process -Id $child.pid -ErrorAction SilentlyContinue
    if ($null -ne $owned) {
        try { if ($owned.StartTime.ToUniversalTime().Ticks -eq [long]$child.start_ticks) { $owned.Kill($true); [void]$owned.WaitForExit(5000) } }
        finally { $owned.Dispose() }
    }
}
$streamsFinished = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)
$text = if ($streamsFinished) { $stdout.GetAwaiter().GetResult() } else { '' }
$errorText = if ($streamsFinished) { $stderr.GetAwaiter().GetResult() } else { 'watchdog stdout/stderr drain not complete' }
$probe = if (-not [string]::IsNullOrWhiteSpace($text)) { $text | ConvertFrom-Json } else { $null }
$exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
$process.Dispose()
[ordered]@{
    host=$HostName;mode=$Mode;implementation_root=$ImplementationRoot;started_at=$started.ToString('o');observed_at=$observed.ToString('o')
    watchdog_required=$watchdog;watchdog_limit_ms=12000;driver_exit_code=$exitCode
    child_ready=($null -ne $child);child_alive_before_safety_cleanup=$aliveBeforeSafety
    child_started_before_product_timeout=($null -ne $child -and ([DateTimeOffset]$child.ready_utc-$started).TotalMilliseconds -lt 5000)
    receipt_root=$receiptRoot;temp=$env:TEMP;tmp=$env:TMP;probe=$probe;stderr=$errorText
    interpretation=$(if($watchdog){'FAIL: product did not return; outer watchdog cleanup is not product success'}else{'Product returned; evaluate probe assertions'})
} | ConvertTo-Json -Depth 8
