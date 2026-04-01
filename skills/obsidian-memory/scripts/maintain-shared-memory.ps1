param(
    [string]$VaultRoot = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'resolve-shared-memory-paths.ps1')
$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath

function Invoke-Step {
    param(
        [string]$Name,
        [string]$Path,
        [string]$VaultRoot,
        [string]$OrchestratorFlowPath
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Name = $Name
            ExitCode = 2
            Output = @("Missing script: $Path")
        }
    }

    if ([string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
        $output = @(& $Path -VaultRoot $VaultRoot 2>&1 | ForEach-Object { $_.ToString() })
    } else {
        $output = @(& $Path -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath 2>&1 | ForEach-Object { $_.ToString() })
    }
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        Name = $Name
        ExitCode = $exitCode
        Output = $output
    }
}

function Get-StepStatus {
    param([int]$ExitCode)

    switch ($ExitCode) {
        0 { return 'PASS' }
        1 { return 'WARN' }
        default { return 'FAIL' }
    }
}

$repairScript = Join-Path $scriptRoot 'repair-shared-memory.ps1'
$archiveScript = Join-Path $scriptRoot 'archive-memory-candidates.ps1'
$reportScript = Join-Path $scriptRoot 'write-memory-health-report.ps1'
$healthScript = Join-Path $scriptRoot 'run-memory-health.ps1'

$steps = @(
    Invoke-Step -Name 'repair' -Path $repairScript -VaultRoot $VaultRoot -OrchestratorFlowPath ''
    Invoke-Step -Name 'archive' -Path $archiveScript -VaultRoot $VaultRoot -OrchestratorFlowPath ''
    Invoke-Step -Name 'report' -Path $reportScript -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
)

$preHealthFailure = $steps | Where-Object { $_.ExitCode -gt 1 } | Select-Object -First 1
if ($null -ne $preHealthFailure) {
    Write-Output 'STATUS: FAIL'
    Write-Output ('VaultRoot: {0}' -f $VaultRoot)
    Write-Output ''
    Write-Output 'Steps:'
    foreach ($step in $steps) {
        Write-Output ('- {0}: {1} (exit={2})' -f $step.Name, (Get-StepStatus -ExitCode $step.ExitCode), $step.ExitCode)
    }
    Write-Output ''
    Write-Output ('FailureStep: {0}' -f $preHealthFailure.Name)
    foreach ($line in $preHealthFailure.Output) {
        Write-Output ('  {0}' -f $line)
    }
    exit 2
}

$healthStep = Invoke-Step -Name 'health' -Path $healthScript -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
$allSteps = @($steps + $healthStep)
$finalStatus = Get-StepStatus -ExitCode $healthStep.ExitCode

$reportLine = ($steps | Where-Object { $_.Name -eq 'report' } | Select-Object -First 1).Output |
    Where-Object { $_ -like 'Report:*' } |
    Select-Object -First 1
$archiveLine = ($steps | Where-Object { $_.Name -eq 'archive' } | Select-Object -First 1).Output |
    Where-Object { $_ -like 'Archived:*' } |
    Select-Object -First 1

Write-Output ('STATUS: {0}' -f $finalStatus)
Write-Output ('VaultRoot: {0}' -f $VaultRoot)
Write-Output ''
Write-Output 'Steps:'
foreach ($step in $allSteps) {
    Write-Output ('- {0}: {1} (exit={2})' -f $step.Name, (Get-StepStatus -ExitCode $step.ExitCode), $step.ExitCode)
}
Write-Output ''
Write-Output 'Summary:'
if ($null -ne $archiveLine) {
    Write-Output ('- {0}' -f $archiveLine)
}
if ($null -ne $reportLine) {
    Write-Output ('- {0}' -f $reportLine)
}
Write-Output ('- Final health status: {0}' -f $finalStatus)
Write-Output ''
Write-Output 'Health Output:'
foreach ($line in $healthStep.Output) {
    Write-Output $line
}

exit $healthStep.ExitCode
