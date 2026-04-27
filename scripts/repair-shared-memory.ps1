[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string]$EntryHost = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'repair-shared-memory.ps1'
& $scriptPath -VaultRoot $VaultRoot -EntryHost $EntryHost
exit $LASTEXITCODE
