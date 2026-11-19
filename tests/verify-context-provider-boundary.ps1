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
Need 'docs/工作流/context-provider-boundary.md' 'create/change v2 task state, Evidence, Approval or shared pointers'
Need 'docs/工作流/context-provider-boundary.md' 'decide verification pass/fail'
Need 'docs/工作流/context-provider-boundary.md' 'current files and `rg`/Read/manual inspection'
Need 'docs/工作流/context-provider-boundary.md' 'writes no task artifacts or shared pointers'
Need 'docs/工作流/provider-authority-order.md' '.assistant/runtime/tasks/{task_id}/task.json'
foreach ($path in @('docs/工作流/context-provider-boundary.md','docs/工作流/provider-authority-order.md','docs/governed-work.md')) {
    $text = Get-Content -LiteralPath (Join-Path $RepoRoot $path) -Raw
    if ($text -match 'Workflow stays `PLAN|frontmatter is the only stage truth|已有 v1 task 继续使用五阶段|HARNESS_PROTOCOL=v1` 只影响') { $failures.Add("$path presents retired v1 as current") }
}
Need 'docs/工作流/provider-authority-order.md' 'Provider output'
Need 'skills/orchestrator/references/context-provider-boundary.md' 'advisory-only'
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Context provider boundary verified.'
