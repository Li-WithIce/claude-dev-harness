param(
    [string]$VaultRoot = "",
    [string]$OutputPath = "",
    [string]$OrchestratorFlowPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

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

Write-Utf8Bom -Path $OutputPath -Content $report

Write-Output "STATUS: PASS"
Write-Output "Report: $OutputPath"
Write-Output "SourceStatus: $status"
exit 0
