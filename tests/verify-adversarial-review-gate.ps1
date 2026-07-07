# Verify adversarial review gate docs.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$failures = New-Object System.Collections.Generic.List[string]
function Assert-Contains($Path, $Needle) {
    $full = Join-Path $RepoRoot $Path
    if (-not (Test-Path -LiteralPath $full)) { $failures.Add("missing $Path") | Out-Null; return }
    $content = Get-Content -LiteralPath $full -Raw -Encoding utf8
    if ($content -notmatch [regex]::Escape($Needle)) { $failures.Add("$Path missing $Needle") | Out-Null }
}
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'Adversarial Review Gate'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'at least five adversarial review rounds'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'Workflow Core Defender'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'must not advance'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'must not introduce a new stage'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'must not add frontmatter fields'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'not a parsed workflow stage'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'do not count or parse per-task adversarial review rounds'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'Future work may add an advisory or strict parser'
Assert-Contains 'skills/review/references/adversarial-review-gate.md' 'Scope Creep Defender'
Assert-Contains 'skills/review/references/adversarial-review-gate.md' 'advance-stage.ps1'
Assert-Contains 'skills/review/references/adversarial-review-gate.md' 'latest `- verdict:` only'
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Adversarial review gate contract verified.'
