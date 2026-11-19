[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReceiptRoot,
    [Parameter(Mandatory)][string]$PwshPath,
    [ValidateSet('parent','leaf')][string]$Role = 'parent',
    [switch]$ExitParentAfterSpawn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$self = Get-Process -Id $PID
$receipt = [ordered]@{role=$Role;pid=$PID;start_ticks=$self.StartTime.ToUniversalTime().Ticks}
[IO.File]::WriteAllText((Join-Path $ReceiptRoot ($Role+'.json')),($receipt | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
if ($Role -ceq 'parent') {
    $info = [Diagnostics.ProcessStartInfo]@{FileName=$PwshPath;UseShellExecute=$false;CreateNoWindow=$true}
    foreach ($value in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-ReceiptRoot',$ReceiptRoot,'-PwshPath',$PwshPath,'-Role','leaf')) {
        $info.ArgumentList.Add($value)
    }
    if ($ExitParentAfterSpawn) { $info.ArgumentList.Add('-ExitParentAfterSpawn') }
    $child = [Diagnostics.Process]::Start($info)
    $child.Dispose()
    if ($ExitParentAfterSpawn) { return }
}
if ($ExitParentAfterSpawn) { [Console]::Out.Write('owned-leaf-ready'); [Console]::Out.Flush() }
Start-Sleep -Seconds 90
