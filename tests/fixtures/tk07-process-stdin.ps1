[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ReceiptRoot,
    [Parameter(Mandatory)][string]$PwshPath,
    [ValidateSet('normal','no-read','early-close','shared-deadline')][string]$Mode = 'no-read',
    [int]$TimeoutMilliseconds = 5000,
    [switch]$Child
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ($Child) {
    [void][IO.Directory]::CreateDirectory($ReceiptRoot)
    $self = Get-Process -Id $PID
    $receipt = @{pid=$PID;start_ticks=$self.StartTime.ToUniversalTime().Ticks;temp=$env:TEMP;tmp=$env:TMP;ready_utc=[DateTimeOffset]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText((Join-Path $ReceiptRoot 'child.json'),($receipt | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if ($Mode -ceq 'no-read') { Start-Sleep -Seconds 60; exit 0 }
    if ($Mode -ceq 'early-close') { [Console]::OpenStandardInput().Close(); exit 0 }
    if ($Mode -ceq 'shared-deadline') { Start-Sleep -Milliseconds 2000 }
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false,$true)
    $text = [Console]::In.ReadToEnd()
    [IO.File]::WriteAllText((Join-Path $ReceiptRoot 'input-complete.json'),(@{characters=$text.Length;at=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if ($Mode -ceq 'shared-deadline') { Start-Sleep -Milliseconds 4000 }
    [Console]::Out.Write($text)
    [Console]::Error.Write('stderr-中文')
    exit 0
}

. (Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeKernel.ps1')
$inputText = if ($Mode -ceq 'normal') { ('中文 café 😀' + "`n") * 8192 } else { 'x' * (8 * 1024 * 1024) }
$timer = [Diagnostics.Stopwatch]::StartNew()
$result = Invoke-HarnessKernelProcess -FilePath $PwshPath -WorkingDirectory $RepoRoot -Arguments @(
    '-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-RepoRoot',$RepoRoot,'-ReceiptRoot',$ReceiptRoot,
    '-PwshPath',$PwshPath,'-Mode',$Mode,'-Child') -TimeoutMilliseconds $TimeoutMilliseconds -StandardInput $inputText
$timer.Stop()
$receiptPath = Join-Path $ReceiptRoot 'child.json'
$receipt = if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json } else { $null }
$alive = $false
if ($null -ne $receipt) {
    $owned = Get-Process -Id ([int]$receipt.pid) -ErrorAction SilentlyContinue
    if ($null -ne $owned) {
        $alive = $owned.StartTime.ToUniversalTime().Ticks -eq [long]$receipt.start_ticks
        $owned.Dispose()
    }
}
# This observation precedes the outer watchdog's separate final safety cleanup.
[ordered]@{
    mode=$Mode;host_version=$PSVersionTable.PSVersion.ToString();elapsed_ms=$timer.ElapsedMilliseconds
    timeout_ms=$TimeoutMilliseconds;complete=$result.Complete;exit_code=$result.ExitCode
    stdout_matches=($result.StdOut -ceq $inputText);stderr_matches=($result.StdErr -ceq 'stderr-中文')
    failure_output_empty=(-not $result.StdOut -and -not $result.StdErr);input_characters=$inputText.Length
    input_delivered=(Test-Path -LiteralPath (Join-Path $ReceiptRoot 'input-complete.json'))
    child_ready=($null -ne $receipt);child_alive_before_safety_cleanup=$alive
    temp=$env:TEMP;tmp=$env:TMP;child_temp=$(if($null -ne $receipt){$receipt.temp}else{$null});child_tmp=$(if($null -ne $receipt){$receipt.tmp}else{$null})
} | ConvertTo-Json -Compress
