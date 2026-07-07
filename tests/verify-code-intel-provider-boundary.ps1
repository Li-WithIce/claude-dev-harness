# Verify code-intel provider boundary.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$failures = New-Object System.Collections.Generic.List[string]
function Need($Path, $Needle) {
    $full = Join-Path $RepoRoot $Path
    if (-not (Test-Path -LiteralPath $full)) { $failures.Add("missing $Path") | Out-Null; return }
    if ((Get-Content -LiteralPath $full -Raw -Encoding utf8) -notmatch [regex]::Escape($Needle)) { $failures.Add("$Path missing $Needle") | Out-Null }
}
Need 'docs/工具/codegraph-provider.md' 'optional'
Need 'docs/工具/codegraph-provider.md' 'advisory-only'
Need 'docs/工具/codegraph-provider.md' 'stale'
Need 'docs/工具/codegraph-provider.md' 'fallback'
Need 'docs/工具/codegraph-provider.md' 'telemetry'
Need 'skills/plan/references/code-intel-routing.md' 'current repo files'
Need 'skills/review/references/code-intel-review.md' 'must not decide'
Need '.gitignore' '/.codegraph/'
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Code-intel provider boundary verified.'
