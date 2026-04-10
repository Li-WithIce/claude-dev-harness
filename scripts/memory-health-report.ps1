[CmdletBinding()]
param(
    [string]$VaultRoot = "",
    [string]$OutputPath = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\resolve-obsidian-memory-script.ps1"

$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
$scriptPath = Resolve-ObsidianMemoryScript -ScriptName 'write-memory-health-report.ps1'
$invokeArgs = @{
    VaultRoot = $VaultRoot
}
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $invokeArgs.OutputPath = $OutputPath
}
if (-not [string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
    $invokeArgs.OrchestratorFlowPath = $OrchestratorFlowPath
}

& $scriptPath @invokeArgs
exit $LASTEXITCODE
