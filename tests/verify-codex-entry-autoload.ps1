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

$codexHooksPath = 'agent-configs/codex/hooks.shared.json.template'
Need-Text $codexHooksPath '"matcher": "^(Bash|apply_patch|Write|Edit|MultiEdit|NotebookEdit)$"'
Need-Text $codexHooksPath '"command": "{WINDOWS_POWERSHELL_EXE} -NoLogo -NoProfile -NonInteractive -Command . ''{CODEX_PRETOOLUSE_LAUNCHER_PS_LITERAL}''"'
Need-Text $codexHooksPath '"timeout": 15'
Need-Text 'runtime-hooks/claude/codex-pretooluse-launcher.ps1' "if (`$stdout.Trim() -cne '{}')"
Need-Text 'runtime-hooks/claude/codex-pretooluse-launcher.ps1' "permissionDecision = 'deny'"
Reject-Regex $codexHooksPath '(?i)\b(?:EncodedCommand|ExecutionPolicy|WindowStyle)\b' 'Codex Hook command must remain a transparent, unencoded launcher invocation'
Reject-Regex 'runtime-hooks/claude/codex-pretooluse-launcher.ps1' '(?i)\b(?:EncodedCommand|Invoke-Expression|FromBase64String|CreateNoWindow|WindowStyle)\b|ScriptBlock\s*\]\s*::\s*Create' 'Codex Hook launcher must not hide or dynamically evaluate its payload'
Need-Text 'README.md' 'direct `apply_patch` 严格解析全部 Add/Update/Delete/Move 目标'
Need-Text 'README.md' '持久化不等于披露'
Need-Text 'agent-configs/codex/README.md' '普通文件写入只把目标路径送入 core policy'
Need-Text 'docs/architecture/policy-engine.md' 'Persistence is not disclosure'
Need-Text 'agent-configs/workspace/AGENTS.md.template' '已更新指定生产配置文件；数据库和外部服务敏感字段未在报告中回显。'
Need-Text 'agent-configs/claude/CLAUDE.md.template' 'Authorized secrets may persist in the named production config; never disclose them.'

$entryContractPath = 'policies/entry-contract.md'
Need-Text $entryContractPath '`protocol_default`: `auto`'
Need-Text $entryContractPath '`auto_resolves_to`: `existing-artifact-or-gated-v2-new`'
Need-Text $entryContractPath '`v2_entry_activation`: `explicit-or-workspace-new-or-existing-v2-or-eligible-auto-new`'
Need-Text $entryContractPath 'first complete routing hop'
Need-Text $entryContractPath 'Selected v2 Direct loads no `entry-router`, `orchestrator`, lifecycle skill'
Need-Text $entryContractPath 'minimum focused checks covering all confirmed acceptance criteria'
Need-Text $entryContractPath 'Existing v2 may status/resume; v1 may load its shim.'
Need-Text $entryContractPath 'Only a detector-selected v1 request loads `entry-router`'
Need-Text $entryContractPath 'Read-only work performs zero writes'

Need-Text 'agent-configs/codex/AGENTS.md.template' 'Resolve the active workspace in this order: explicit `-WorkspaceRoot`'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'Read the resolved workspace''s `AGENTS.md` first'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'the Harness runtime are authoritative'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'Use `.assistant\entry\task.ps1 status` for read-only v2 recovery'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'Existing v1 tasks may use their compatibility runtime files'
Need-Text 'agent-configs/codex/AGENTS.md.template' 'Codex is a shared-pointer writer only when'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Harness runtime lives under `{VAULT_PATH}`'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Use `.assistant\entry\task.ps1 status` only for an explicit recovery/status request after protocol selection'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'v1 recovery files remain compatibility inputs only for existing v1 tasks'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Use `rg`, file reading, and manual inspection only when directly relevant.'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Optional providers are never required for core routing'
Need-Text 'agent-configs/workspace/AGENTS.md.template' 'Only a detector-selected v1 workflow reads the executable `.assistant\entry\AGENTS.md` shim; selected v2 never reads it.'
Need-Text 'agent-configs/claude/CLAUDE.md.template' '`/entry-router`: selected v1 only; never v2 Direct.'
Need-Text 'agent-configs/claude/CLAUDE.md.template' 'Resolve the workspace via `DEV_HARNESS_WORKSPACE_ROOT`'
Need-Text 'agent-configs/claude/CLAUDE.md.template' 'Multi-step `mode=workflow` start/switch/pause may sync runtime'
Need-Text 'agent-configs/claude/CLAUDE.md.template' '<!-- BEGIN GENERATED ENTRY CONTRACT -->'
Need-Text 'agent-configs/claude/CLAUDE.md.template' '`protocol_default`: `auto`'
Need-Text 'agent-configs/claude/CLAUDE.md.template' 'Only a detector-selected v1 request loads `entry-router`'
Need-Text 'vault-template/entry/AGENTS.md.template' 'Stage advance: `pwsh -File .assistant\entry\advance-stage.ps1'
Need-Text 'vault-template/entry/AGENTS.md.template' 'Harness repo: `{REPO_ROOT}`; shared vault: `{VAULT_PATH}`.'
Need-Text 'vault-template/entry/AGENTS.md.template' '`TEST -> DONE`'
Need-Text 'skills/entry-router/SKILL.md' 'Entry-router is the default first hop for project-scoped development and read-only engineering requests'
Need-Text 'skills/entry-router/SKILL.md' 'Do not invoke other workflow skills before routing'
Need-Text 'skills/entry-router/SKILL.md' '| `new-readonly` | clear standalone project read-only request | `quick` | `none` | `none` |'
Need-Text 'skills/entry-router/SKILL.md' 'Ask exit criteria'
Need-Text 'skills/entry-router/SKILL.md' 'Recommended route: quick or workflow'
Need-Text 'skills/orchestrator/SKILL.md' '唯一阶段真相源：`docs/tasks/{task_id}/plan.md` frontmatter'
Need-Text 'skills/orchestrator/SKILL.md' 'iterative blocking clarification gate'
Need-Text 'skills/orchestrator/references/lite-writing-guide.md' 'ask cannot exit'
Need-Text 'vault-template/工作流/任务识别协议.md' 'ask cannot exit'

Reject-Regex 'agent-configs/workspace/AGENTS.md.template' 'PLAN\s*/\s*IMPLEMENT\s*/\s*REVIEW\s*/\s*TEST\s*/\s*SUMMARY' 'workspace AGENTS template should not present REVIEW/SUMMARY as workflow stages'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '(?m)^\s*-\s*REVIEW\b' 'workspace AGENTS template should not define REVIEW as a checklist stage'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '(?m)^\s*-\s*SUMMARY\b' 'workspace AGENTS template should not define SUMMARY as a checklist stage'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '同步初始化项目工作流、`codedb-mcp` 索引和 CodeGraph' 'workspace AGENTS template should not auto-bootstrap provider indexes'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '\|\s*`new-readonly`\s*\||Ask exit criteria|Clarification ledger|resume-current/readonly|inbox-first' 'workspace template should contain only the short protocol bootstrap, not full v1 routing'
Reject-Regex 'agent-configs/codex/AGENTS.md.template' 'BEGIN GENERATED ENTRY CONTRACT|`protocol_default`|\|\s*`new-readonly`\s*\|' 'Codex global AGENTS must remain a host-only overlay'
Reject-Regex 'agent-configs/claude/CLAUDE.md.template' '\|\s*`new-readonly`\s*\||Ask exit criteria|Clarification ledger|resume-current/readonly|inbox-first' 'Claude global entry should carry only the short bootstrap, not the full v1 contract'
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
        'agent-configs/codex/hooks.shared.json.template',
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
