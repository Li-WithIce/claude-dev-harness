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
        [string]$Path,
        [string]$Needle
    )

    $text = Read-RepoFile -Path $Path
    if ($text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $failures.Add("$Path missing $Needle") | Out-Null
    }
}

function Reject-Regex {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Message
    )

    $text = Read-RepoFile -Path $Path
    if ([regex]::IsMatch($text, $Pattern)) {
        $failures.Add($Message) | Out-Null
    }
}

$routingFiles = @(
    'skills/entry-router/SKILL.md',
    'skills/orchestrator/SKILL.md',
    'skills/orchestrator/references/lite-writing-guide.md',
    'vault-template/entry/AGENTS.md.template',
    'vault-template/工作流/任务识别协议.md',
    'agent-configs/workspace/AGENTS.md.template',
    'agent-configs/codex/AGENTS.md.template',
    'agent-configs/claude/CLAUDE.md.template',
    'README.md'
)

foreach ($path in $routingFiles) {
    Need-Text $path 'iterative blocking clarification'
}

Need-Text 'skills/entry-router/SKILL.md' 'Remain in ask until all blocking uncertainties are resolved'
Need-Text 'skills/entry-router/SKILL.md' 'after every user answer'
Need-Text 'skills/entry-router/SKILL.md' 'Recommended route: quick or workflow'
Need-Text 'skills/entry-router/SKILL.md' 'Why this route is safe'
Need-Text 'vault-template/entry/AGENTS.md.template' 'Remain in ask until all blocking uncertainties are resolved'
Need-Text 'skills/orchestrator/SKILL.md' 'until all blocking requirements are resolved'
Need-Text 'skills/orchestrator/SKILL.md' 'route to `quick` or `workflow`'
Need-Text 'skills/orchestrator/references/lite-writing-guide.md' 'ask cannot exit'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Recommended route: quick or workflow'
Need-Text 'README.md' 'not enter quick/workflow/PLAN/IMPLEMENT'

foreach ($path in @(
        'skills/entry-router/SKILL.md',
        'skills/orchestrator/SKILL.md',
        'skills/orchestrator/references/lite-writing-guide.md',
        'skills/md-html/SKILL.md',
        'vault-template/entry/AGENTS.md.template',
        'vault-template/工作流/任务识别协议.md',
        'agent-configs/workspace/AGENTS.md.template',
        'agent-configs/codex/AGENTS.md.template',
        'agent-configs/claude/CLAUDE.md.template',
        'README.md'
    )) {
    Reject-Regex $path '只问一个最小澄清问题|先问一个最小澄清问题|only one minimal question|ask one minimal question' "$path should not use shallow one-question ask wording"
    Reject-Regex $path '(?mi)^stage:\s*ASK\b' "$path should not introduce ASK as a frontmatter stage"
}

Reject-Regex 'skills/orchestrator/references/lite-writing-guide.md' 'PLAN\s*->\s*ASK|ASK\s*->\s*PLAN|PLAN\s*->\s*IMPLEMENT\s*->\s*REVIEW\s*->\s*TEST\s*->\s*SUMMARY' 'lite writing guide should not list ASK or legacy stage chains'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '(?m)^\s*-\s*(ASK|QUICK|REVIEW|SUMMARY|HANDOFF)\b' 'workspace template should not list non-canonical workflow stages'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "- $_" }
    exit 1
}

Write-Output 'Entry routing clarification gate verified.'
