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
        Write-Output '- Historical diagnostic completed; preserve its STATUS above. This is not v2 Runtime health.'
    }
    1 {
        Write-Output "Next:"
        Write-Output "- Review warnings above."
        Write-Output '- Inspect retained history only if explicitly needed; do not use it for task recovery.'
    }
    2 {
        Write-Output "Next:"
        Write-Output '- Check the explicitly selected historical input or optional Memory installation.'
        Write-Output '- Do not repair or reconstruct retired lifecycle mirrors.'
    }
    default {
        Write-Output "Next:"
        Write-Output "- Checker ended unexpectedly. Review script output above."
    }
}

exit $exitCode
