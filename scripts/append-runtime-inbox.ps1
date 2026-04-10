[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string]$TaskId = "",
    [string]$Type = "",
    [string]$Status = "open",
    [string]$Summary = "",
    [string]$Payload = "-",
    [string]$Source = "manual"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'append-runtime-inbox.ps1'
& $scriptPath `
    -VaultRoot $VaultRoot `
    -TaskId $TaskId `
    -Type $Type `
    -Status $Status `
    -Summary $Summary `
    -Payload $Payload `
    -Source $Source
exit $LASTEXITCODE
