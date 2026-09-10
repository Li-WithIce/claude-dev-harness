[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MutexName,

    [Parameter(Mandatory)]
    [string]$ReadyEventName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mutex = $null
$readyEvent = $null
$ownsMutex = $false
try {
    $mutex = [System.Threading.Mutex]::OpenExisting($MutexName)
    $readyEvent = [System.Threading.EventWaitHandle]::OpenExisting($ReadyEventName)
    if (-not $mutex.WaitOne(5000)) {
        throw "Timed out waiting for named mutex: $MutexName"
    }
    $ownsMutex = $true
    $readyEvent.Set() | Out-Null
    Start-Sleep -Seconds 30
} finally {
    if ($ownsMutex) {
        $mutex.ReleaseMutex()
    }
    if ($null -ne $readyEvent) {
        $readyEvent.Dispose()
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}
