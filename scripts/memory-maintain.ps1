[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
    [Console]::Error.WriteLine('v1-memory-maintain-flow-retired: invoke historical diagnostics explicitly; maintenance does not read a legacy flow.')
    exit 2
}

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
