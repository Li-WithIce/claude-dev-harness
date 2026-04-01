[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'maintain-shared-memory.ps1'
$invokeArgs = @{
    VaultRoot = $VaultRoot
}
if (-not [string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
    $invokeArgs.OrchestratorFlowPath = $OrchestratorFlowPath
}

& $scriptPath @invokeArgs
exit $LASTEXITCODE
