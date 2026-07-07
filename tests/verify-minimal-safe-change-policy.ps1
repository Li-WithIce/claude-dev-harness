# Verify Minimal Safe Change policy.
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
Need 'docs/工作流/minimal-safe-change-policy.md' 'Minimal Safe Change Policy'
Need 'docs/工作流/minimal-safe-change-policy.md' 'trust-boundary validation'
Need 'docs/工作流/minimal-safe-change-policy.md' 'security'
Need 'docs/工作流/minimal-safe-change-policy.md' 'data-loss'
Need 'docs/工作流/minimal-safe-change-policy.md' 'accessibility'
Need 'docs/工作流/minimal-safe-change-policy.md' 'required verification'
Need 'skills/implement/references/minimal-safe-change-policy.md' 'Safety Floor'
Need 'skills/review/references/overengineering-checklist.md' 'Underengineering Check'
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Minimal Safe Change policy verified.'
