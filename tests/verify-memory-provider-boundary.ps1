# Verify memory provider boundary.
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
Need 'docs/工具/agentmemory-sidecar.md' 'read-only historical recall'
Need 'docs/工具/agentmemory-sidecar.md' 'Must not write `.assistant/运行时/*`'
Need 'docs/工具/agentmemory-sidecar.md' 'Must not promote wisdom directly'
Need 'docs/工具/agentmemory-sidecar.md' 'WSL2 may be the practical fast path'
Need 'docs/工具/agentmemory-sidecar.md' 'Harness install/update must not run `agentmemory connect`'
Need 'docs/工具/agentmemory-sidecar.md' 'not a replacement for `.assistant` or `docs/tasks`'
Need 'skills/orchestrator/references/memory-provider-boundary.md' 'agentmemory is read-only historical recall'
Need 'skills/orchestrator/references/memory-provider-boundary.md' 'WSL2 as the practical fast path'
Need 'skills/obsidian-memory/SKILL.md' 'agentmemory Compatibility'
Need 'skills/obsidian-memory/SKILL.md' 'harness install/update 不运行 `agentmemory connect`'
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Memory provider boundary verified.'
