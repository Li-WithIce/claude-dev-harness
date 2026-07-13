param(
    [string]$VaultRoot = "",
    [string]$OutputPath = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'resolve-shared-memory-paths.ps1')
$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath
$checkScript = Join-Path $scriptRoot 'check-shared-memory.ps1'

if (-not (Test-Path -LiteralPath $checkScript)) {
    throw "Missing checker: $checkScript"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Join-Path $VaultRoot '运行时') '记忆体检报告.md'
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$outputLines = if ([string]::IsNullOrWhiteSpace($OrchestratorFlowPath)) {
    @(& $checkScript -VaultRoot $VaultRoot 2>&1 | ForEach-Object { $_.ToString() })
} else {
    @(& $checkScript -VaultRoot $VaultRoot -OrchestratorFlowPath $OrchestratorFlowPath 2>&1 | ForEach-Object { $_.ToString() })
}
$exitCode = $LASTEXITCODE
$statusLine = $outputLines | Where-Object { $_ -like 'STATUS:*' } | Select-Object -First 1
$status = if ($null -ne $statusLine) { $statusLine -replace '^STATUS:\s*', '' } else { 'UNKNOWN' }
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$report = @(
    '---'
    'tags: [运行时, 记忆, 体检]'
    "created: $timestamp"
    "updated: $timestamp"
    '---'
    ''
    '# 记忆体检报告'
    ''
    '## Meta'
    ''
    "- **vault_root**: $VaultRoot"
    "- **status**: $status"
    "- **generated_at**: $timestamp"
    "- **source_script**: $checkScript"
    ''
    '## Summary'
    ''
    "- 状态: $status"
    "- exit_code: $exitCode"
    ''
    '## Raw Output'
    ''
    '```text'
    ($outputLines -join [Environment]::NewLine)
    '```'
) -join [Environment]::NewLine

[System.IO.File]::WriteAllText($OutputPath, $report, (New-Object System.Text.UTF8Encoding($true)))

Write-Output ("STATUS: {0}" -f $(if ($exitCode -eq 0) { 'PASS' } elseif ($exitCode -eq 1) { 'WARN' } else { 'FAIL' }))
Write-Output "Report: $OutputPath"
Write-Output "SourceStatus: $status"
Write-Output "SourceExitCode: $exitCode"
exit $exitCode
