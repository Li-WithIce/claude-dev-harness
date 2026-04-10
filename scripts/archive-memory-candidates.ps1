[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string[]]$TerminalStatuses = @("promoted", "rejected", "archived")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'archive-memory-candidates.ps1'
& $scriptPath -VaultRoot $VaultRoot -TerminalStatuses $TerminalStatuses
exit $LASTEXITCODE
