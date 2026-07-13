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

$entryContractPath = 'policies/entry-contract.md'
Need-Text $entryContractPath '`protocol_default`: `auto`'
Need-Text $entryContractPath '`auto_resolves_to`: `v1`'
Need-Text $entryContractPath '`v2_entry_activation`: `disabled`'
Need-Text $entryContractPath '`stage_chain`: `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST`'
Need-Text $entryContractPath '`plan.md` frontmatter is the sole stage truth'

Need-Text 'agent-configs/codex/AGENTS.md.template' 'Resolve the active workspace in this order: explicit `-WorkspaceRoot`'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'do not keep parallel runtime notes under `{CODEX_HOME}`'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'Resume inspects open `[writeback-fallback]` rows'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'Codex is a shared-pointer writer only when'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Shared memory vault: `{VAULT_PATH}`'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Resume first inspects open `[writeback-fallback]` rows'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Use `rg`, file reading, and manual inspection by default.'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Provider indexes and `codegraph sync` are opt-in and must not block routing'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'The executable workspace entry shim remains `.assistant\entry\AGENTS.md`'
Need-Text 'agent-configs/claude/CLAUDE.md.template' 'Call `/entry-router` at the start of each conversation.'
Need-Text 'agent-configs/claude/CLAUDE.md.template' 'Resolve the workspace via `DEV_HARNESS_WORKSPACE_ROOT`'
Need-Text 'agent-configs/claude/CLAUDE.md.template' 'Multi-step `mode=workflow` start/switch/pause may sync runtime'
Need-Text 'vault-template/entry/AGENTS.md.template' 'Stage advance: `pwsh -File .assistant\entry\advance-stage.ps1'
Need-Text 'vault-template/entry/AGENTS.md.template' 'Harness repo: `{REPO_ROOT}`; shared vault: `{VAULT_PATH}`.'
Need-Text 'vault-template/entry/AGENTS.md.template' '`TEST -> DONE`'
Need-Text 'skills/entry-router/SKILL.md' 'Entry-router is the default first hop for project-scoped development and read-only engineering requests'
Need-Text 'skills/entry-router/SKILL.md' 'Do not invoke other workflow skills before routing'
Need-Text 'skills/entry-router/SKILL.md' 'Ask exit criteria'
Need-Text 'skills/entry-router/SKILL.md' 'Recommended route: quick or workflow'
Need-Text 'skills/orchestrator/SKILL.md' 'iterative blocking clarification gate'
Need-Text 'skills/orchestrator/references/lite-writing-guide.md' 'ask cannot exit'
Need-Text 'vault-template/工作流/任务识别协议.md' 'ask cannot exit'

Reject-Regex 'agent-configs/workspace/AGENTS.md.template' 'PLAN\s*/\s*IMPLEMENT\s*/\s*REVIEW\s*/\s*TEST\s*/\s*SUMMARY' 'workspace AGENTS template should not present REVIEW/SUMMARY as workflow stages'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '(?m)^\s*-\s*REVIEW\b' 'workspace AGENTS template should not define REVIEW as a checklist stage'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '(?m)^\s*-\s*SUMMARY\b' 'workspace AGENTS template should not define SUMMARY as a checklist stage'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '同步初始化项目工作流、`codedb-mcp` 索引和 CodeGraph' 'workspace AGENTS template should not auto-bootstrap provider indexes'
Reject-Regex 'agent-configs/codex/AGENTS.md.template' 'Codex writes task artifacts under .* by default' 'Codex AGENTS template should not make task artifacts the default for quick/read-only work'
Reject-Regex 'agent-configs/codex/AGENTS.md.template' '(?m)^\s*- New items go to `运行时\\收件箱\.md` first\s*$' 'Codex AGENTS template should not send standalone quick/read-only items to the inbox'
Reject-Regex 'agent-configs/codex/AGENTS.md.template' 'updates shared pointer files only when the active workspace entry rules identify Codex as the active entry host' 'Codex AGENTS template should not let active host identity authorize pointer writes'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' 'resume-current.*switch-existing.*loads recovery runtime files first, then the current-stage skill' 'workspace template should not load stage skills for read-only existing-task inspection'
Reject-Regex 'agent-configs/claude/CLAUDE.md.template' 'resume-current.*switch-existing.*先加载恢复运行时文件，再加载当前 stage skill' 'Claude template should not load stage skills for read-only existing-task inspection'

$oldBroadSkillPattern = ('1%' + ' chance') + '|' + ('ABSOLUTELY ' + 'MUST')
$oldAskPattern = ('one minimal ' + 'question') + '|' + ('ask one ' + 'minimal') + '|' + ('one minimal clarification ' + 'question') + '|' + ('只问一个最小' + '澄清问题') + '|' + ('先问一个最小' + '澄清问题')
Reject-Regex 'skills/entry-router/SKILL.md' $oldBroadSkillPattern 'entry-router skill should not use obsolete broad skill invocation wording'
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
    Reject-Regex $path $oldAskPattern "$path should not use obsolete shallow ask wording"
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "- $_" }
    exit 1
}

Write-Output 'Codex entry autoload and workspace routing templates verified.'
