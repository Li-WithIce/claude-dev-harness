param(
    [string]$VaultRoot = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'resolve-shared-memory-paths.ps1')
$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
$checkScript = Join-Path $scriptRoot 'check-shared-memory.ps1'

if (-not (Test-Path -LiteralPath $checkScript)) {
    Write-Output "STATUS: FAIL"
    Write-Output "Missing checker: $checkScript"
    exit 2
}

if ([string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
    & $checkScript -VaultRoot $VaultRoot
} else {
    & $checkScript -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
}
$exitCode = $LASTEXITCODE

Write-Output ""
switch ($exitCode) {
    0 {
        Write-Output "Next:"
        Write-Output "- Shared memory is healthy. No action needed."
    }
    1 {
        Write-Output "Next:"
        Write-Output "- Review warnings above."
        Write-Output "- Check runtime files under $VaultRoot\运行时."
    }
    2 {
        Write-Output "Next:"
        Write-Output "- Fix missing or invalid files first."
        Write-Output "- Re-run run-memory-health.ps1 after repair."
    }
    default {
        Write-Output "Next:"
        Write-Output "- Checker ended unexpectedly. Review script output above."
    }
}

exit $exitCode
