[CmdletBinding()]
param([string]$RepoRoot = "")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$failures = New-Object System.Collections.Generic.List[string]

function Read-RepoFile {
    param([string]$Path)

    $full = Join-Path $RepoRoot $Path
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $failures.Add("missing $Path") | Out-Null
        return ""
    }

    return Get-Content -LiteralPath $full -Raw -Encoding utf8
}

function Need-Text {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Message
    )

    if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $failures.Add($Message) | Out-Null
    }
}

function Reject-Regex {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    if ([regex]::IsMatch($Text, $Pattern)) {
        $failures.Add($Message) | Out-Null
    }
}

$matrixPath = 'docs/工作流/stage-discipline-matrix.md'
$matrix = Read-RepoFile -Path $matrixPath

foreach ($term in @(
        'Socratic Blocking Clarification',
        'Smallest Reversible Action',
        'First Principles',
        'Occam',
        'Bayes',
        'Coherence',
        'Evidence',
        'Minimal Safe Change',
        'Root-Cause',
        'Adversarial',
        'Feynman',
        'Future Maintainer'
    )) {
    Need-Text $matrix $term "$matrixPath should include discipline term: $term"
}

foreach ($stage in @('PLAN', 'PLAN_REVIEW', 'IMPLEMENT', 'CODE_REVIEW', 'TEST')) {
    Need-Text $matrix $stage "$matrixPath should mention canonical stage: $stage"
}

Need-Text $matrix 'PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST' "$matrixPath should include the canonical workflow chain"
Need-Text $matrix 'quick` is a lightweight route, not a stage' "$matrixPath should state quick is not a stage"
Need-Text $matrix 'ask` is an iterative blocking clarification route, not a stage' "$matrixPath should state ask is not a stage"
Need-Text $matrix 'DONE` is a frontmatter terminal state, not an executable stage' "$matrixPath should state DONE is terminal frontmatter"
Need-Text $matrix 'Handoff is a TEST/DONE communication discipline, not a stage' "$matrixPath should state Handoff is not a stage"
Need-Text $matrix 'Provider tools remain opt-in and advisory' "$matrixPath should keep providers opt-in/advisory"
Need-Text $matrix 'high-risk code or production areas increase evidence depth but do not grant workflow artifact or write authority' "$matrixPath should keep high-risk read-only work in quick"
Need-Text $matrix 'if mutation scope or risk expands' "$matrixPath should scope risk-based escalation to mutation"
Need-Text $matrix 'does not add frontmatter fields' "$matrixPath should not add frontmatter fields"
Need-Text $matrix 'does not create new hard validator gates' "$matrixPath should not add hard validation gates"

Reject-Regex $matrix '(?mi)^stage:\s*(ASK|QUICK|REVIEW|SUMMARY|HANDOFF)\b' "$matrixPath should not introduce non-canonical frontmatter stages"
Reject-Regex $matrix '(?m)^```text\r?\n(?:.*\r?\n)*?(ASK|QUICK|REVIEW|SUMMARY|HANDOFF)\s*->' "$matrixPath should not list non-canonical names in the workflow chain"
Reject-Regex $matrix 'Only use quick when scope and acceptance are clear, risk is low' "$matrixPath should not require low risk for pure read-only quick work"

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "- $_" }
    exit 1
}

Write-Output 'Stage Discipline Matrix verified.'
