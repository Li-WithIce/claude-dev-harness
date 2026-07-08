# Verify Codex automatic entry and workspace routing templates.
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
    if ($text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
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

$codexConfigPath = 'agent-configs/codex/config.shared.toml.template'
$codexConfig = Read-RepoFile -Path $codexConfigPath

foreach ($skill in @('entry-router', 'orchestrator', 'plan', 'implement', 'review', 'test')) {
    $blockPattern = ('(?ms)\[\[skills\.config\]\]\s*path\s*=\s*"\{{CODEX_HOME\}}\\\\skills\\\\{0}\\\\SKILL\.md"\s*enabled\s*=\s*true' -f [regex]::Escape($skill))
    if (-not [regex]::IsMatch($codexConfig, $blockPattern)) {
        $failures.Add("$codexConfigPath should enable core harness skill: $skill") | Out-Null
    }

    $disabledPattern = ('(?ms)\[\[skills\.config\]\]\s*path\s*=\s*"\{{CODEX_HOME\}}\\\\skills\\\\{0}\\\\SKILL\.md"\s*enabled\s*=\s*false' -f [regex]::Escape($skill))
    if ([regex]::IsMatch($codexConfig, $disabledPattern)) {
        $failures.Add("$codexConfigPath should not disable core harness skill: $skill") | Out-Null
    }
}

foreach ($skill in @('workflow-team', 'codegraph', 'agentmemory', 'codedb-mcp', 'memory-provider', 'code-intel', 'using-superpowers')) {
    $enabledPattern = ('(?ms)\[\[skills\.config\]\]\s*path\s*=\s*"[^"]*\\\\{0}\\\\SKILL\.md"\s*enabled\s*=\s*true' -f [regex]::Escape($skill))
    if ([regex]::IsMatch($codexConfig, $enabledPattern)) {
        $failures.Add("$codexConfigPath should not default-enable optional/provider/team skill: $skill") | Out-Null
    }
}

Need-Text 'agent-configs/codex/AGENTS.md.template' 'entry-router` is the default auto-entry skill'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'must not bypass `plan.md` frontmatter stage truth'
Need-Text 'agent-configs/workspace/AGENTS.md.template' '.assistant\entry\AGENTS.md'
Need-Text 'agent-configs/workspace/AGENTS.md.template' '`quick`, `workflow`, or `ask`'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'summaries are user-facing responses, not workflow stages'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Provider indexes are opt-in.'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'explicit provider opt-in'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'CodeGraph, codedb-mcp, or agentmemory'
Need-Text 'agent-configs/workspace/AGENTS.md.template' '`rg` / read / manual inspection'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Provider absence must never block `quick`, `workflow`, or `ask` routing.'

foreach ($stage in @('PLAN', 'PLAN_REVIEW', 'IMPLEMENT', 'CODE_REVIEW', 'TEST')) {
    Need-Text 'agent-configs/workspace/AGENTS.md.template' $stage
}

Reject-Regex 'agent-configs/workspace/AGENTS.md.template' 'PLAN\s*/\s*IMPLEMENT\s*/\s*REVIEW\s*/\s*TEST\s*/\s*SUMMARY' 'workspace AGENTS template should not present REVIEW/SUMMARY as workflow stages'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '(?m)^\s*-\s*REVIEW\b' 'workspace AGENTS template should not define REVIEW as a checklist stage'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '(?m)^\s*-\s*SUMMARY\b' 'workspace AGENTS template should not define SUMMARY as a checklist stage'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '同步初始化项目工作流、`codedb-mcp` 索引和 CodeGraph' 'workspace AGENTS template should not auto-bootstrap provider indexes'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "- $_" }
    exit 1
}

Write-Output 'Codex entry autoload and workspace routing templates verified.'
