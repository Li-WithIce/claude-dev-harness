# Verify context provider boundary.
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
Need 'docs/工作流/context-provider-boundary.md' 'Provider output is evidence candidate, not workflow truth.'
Need 'docs/工作流/context-provider-boundary.md' 'advisory context providers'
Need 'docs/工作流/context-provider-boundary.md' 'Only after the user explicitly authorizes memory write'
Need 'docs/工作流/context-provider-boundary.md' 'iterative blocking clarification gate'
Need 'docs/工作流/context-provider-boundary.md' 'write `.assistant/运行时/*`'
Need 'docs/工作流/context-provider-boundary.md' 'decide TEST pass/fail'
Need 'docs/工作流/context-provider-boundary.md' 'fallback'
Need 'docs/工作流/provider-authority-order.md' 'Provider output'
Need 'skills/orchestrator/references/context-provider-boundary.md' 'advisory-only'
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Context provider boundary verified.'
