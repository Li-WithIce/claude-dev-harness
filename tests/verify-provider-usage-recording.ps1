# Verify provider usage recording and audit script.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$failures = New-Object System.Collections.Generic.List[string]
$doc = Get-Content -LiteralPath (Join-Path $RepoRoot 'docs/工具/provider-usage-recording.md') -Raw -Encoding utf8
foreach ($needle in @('provider_context','Do not write frontmatter','advisory-only')) {
    if ($doc -notmatch [regex]::Escape($needle)) { $failures.Add("provider usage doc missing $needle") | Out-Null }
}
$script = Join-Path $RepoRoot 'scripts/audit-context-provider-usage.ps1'
if (-not (Test-Path -LiteralPath $script)) { $failures.Add('missing audit-context-provider-usage.ps1') | Out-Null }
$output = @(& pwsh -NoProfile -NonInteractive -File $script -TaskDir 'missing-provider-audit-dir' 2>&1)
if ($LASTEXITCODE -ne 0) { $failures.Add('provider usage audit should be advisory by default') | Out-Null }
$scriptText = Get-Content -LiteralPath $script -Raw -Encoding utf8
foreach ($needle in @('provider says safe','no callers so safe','agentmemory confirms current stage')) {
    if ($scriptText -notmatch [regex]::Escape($needle)) { $failures.Add("audit script missing phrase $needle") | Out-Null }
}
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Provider usage recording verified.'
