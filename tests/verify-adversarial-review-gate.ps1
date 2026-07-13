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
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'Risk-Driven Adversarial Review Playbook'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'not a fixed-count machine gate'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'Workflow Core Defender'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'reviewer_identity'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'evidence_digest'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'does not introduce a workflow stage'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'does not count free-form adversarial rounds'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'exactly one `- verdict: pass | revise`'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'Latest `pass` is rejected'
Assert-Contains 'docs/工作流/adversarial-review-gate.md' 'Historical contradictions remain append-only history'
Assert-Contains 'skills/review/references/adversarial-review-gate.md' 'Scope Creep Defender'
Assert-Contains 'skills/review/references/adversarial-review-gate.md' 'advance-stage.ps1'
Assert-Contains 'skills/review/references/adversarial-review-gate.md' 'exactly one `- verdict: pass | revise`'
Assert-Contains 'skills/review/references/adversarial-review-gate.md' 'latest `pass` with `P0`/`P1`'
Assert-Contains 'skills/review/SKILL.md' '联合校验唯一的 verdict、唯一 findings 形态及二者一致性'
Assert-Contains 'skills/orchestrator/references/lite-writing-guide.md' '`pass + P0/P1` 拒绝'
Assert-Contains 'skills/orchestrator/references/state-templates.md' '- findings: none'
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Adversarial review gate contract verified.'
