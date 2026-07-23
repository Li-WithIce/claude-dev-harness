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
    'skills/orchestrator/references/runbook.md',
    'vault-template/工作流/任务识别协议.md',
    'skills/md-html/SKILL.md',
    'README.md'
)

foreach ($path in $routingFiles) {
    Need-Text $path 'iterative blocking clarification'
}

$entryContractPath = 'policies/entry-contract.md'
foreach ($caseId in @(
        'new-readonly',
        'new-bounded-mutation',
        'new-durable-risky',
        'new-ambiguous',
        'bare-resume',
        'active-status',
        'resume-execute',
        'inactive-status',
        'durable-unowned'
    )) {
    Need-Text 'skills/entry-router/SKILL.md' ('`{0}`' -f $caseId)
}
Need-Text $entryContractPath 'Only a detector-selected v1 request loads `entry-router`'
Need-Text $entryContractPath 'An unresolved Requirement or product decision blocks every write and enters Ask'
$publicScopeRule = '- A public-contract change found outside confirmed scope stays unresolved until the user explicitly confirms this change; continuation alone enters Ask and authorizes no write.'
$entryContractText = Read-RepoFile -Path $entryContractPath
$publicScopePattern = '(?m)^' + [regex]::Escape($publicScopeRule) + '\r?$'
$commentRelocation = $entryContractText.Replace($publicScopeRule, ('<!-- {0} -->' -f $publicScopeRule))
if (@([regex]::Matches($entryContractText, $publicScopePattern)).Count -ne 1 -or [regex]::IsMatch($commentRelocation, $publicScopePattern)) {
    $failures.Add("$entryContractPath must contain one active public-scope Ask bullet and reject comment relocation") | Out-Null
}
Need-Text $entryContractPath 'Read-only work performs zero writes'
Need-Text 'skills/entry-router/SKILL.md' 'route identity does not broaden requested action'
Need-Text 'skills/entry-router/SKILL.md' 'read-only inspect/status 保持 minimal context 和零写'
Need-Text 'skills/entry-router/SKILL.md' '交互式归属或读写歧义直接 `ask`，不写 inbox'
Need-Text 'skills/entry-router/SKILL.md' '`quick`：只加载入口规则'
Need-Text 'skills/entry-router/SKILL.md' '`workflow`：加载本 skill + `orchestrator`'

Need-Text 'skills/entry-router/SKILL.md' 'Remain in ask until all blocking uncertainties are resolved'
Need-Text 'skills/entry-router/SKILL.md' 'after every user answer'
Need-Text 'skills/entry-router/SKILL.md' 'Recommended route: quick or workflow'
Need-Text 'skills/entry-router/SKILL.md' 'Why this route is safe'
Need-Text 'skills/orchestrator/SKILL.md' 'until all blocking requirements are resolved'
Need-Text 'skills/orchestrator/SKILL.md' 'route to `quick` or `workflow`'
Need-Text 'skills/orchestrator/references/lite-writing-guide.md' 'ask cannot exit'
Need-Text 'README.md' 'not enter quick/workflow/PLAN/IMPLEMENT'
Need-Text 'docs/工作流/stage-discipline-matrix.md' 'high-risk code or production areas increase evidence depth but do not grant workflow artifact or write authority'

foreach ($path in @('skills/entry-router/SKILL.md')) {
    Need-Text $path 'standalone project-scoped read-only'
    Need-Text $path 'route identity does not broaden requested action'
    Need-Text $path 'ambiguous read/write'
}
foreach ($example in @(
        '`review this module, no edits` -> quick',
        '`review production auth, no edits` -> quick with stronger evidence',
        '`review and fix typo` -> 按低风险 mutation 可 quick',
        '`review and apply cross-module/high-risk fix` -> workflow',
        '`write audit.md` / `append Code Review Run` -> workflow',
        '`report active task foo status` -> resume/switch 且保持只读',
        '`看看问题，有问题就处理` -> ask'
    )) {
    Need-Text 'skills/entry-router/SKILL.md' $example
}
Need-Text 'skills/entry-router/SKILL.md' '只读 status/review 不 replay、不 sync、不加载 stage skill'
Need-Text 'skills/entry-router/SKILL.md' '只读检查 inactive task 不改 current/mirror'
Need-Text 'skills/entry-router/SKILL.md' '交互式归属或读写歧义直接 `ask`，不写 inbox'
Need-Text 'skills/entry-router/SKILL.md' 'pure read-only/no-edit 的方案审查仍 quick'
Need-Text 'skills/entry-router/SKILL.md' '`刚才做到哪里了 / what were we doing / status` 只做只读关联和三段式摘要'
Need-Text 'skills/entry-router/SKILL.md' '只读恢复查询不重放'
Need-Text 'vault-template/工作流/任务识别协议.md' 'read-only inspect/status 不 replay、不 sync'
Need-Text 'vault-template/工作流/任务识别协议.md' '交互式归属或读写歧义先 `ask`，不写 `收件箱.md`'
Need-Text 'vault-template/工作流/恢复协议.md' '`刚才做到哪里了` / `what were we doing` / status：只读恢复查询'
Need-Text 'vault-template/工作流/恢复协议.md' '明确继续执行 write-authorized workflow'
Need-Text 'vault-template/工作流/恢复协议.md' '只读查询报告 stale'
Need-Text 'vault-template/工作流/恢复协议.md' '不加载 stage skill'
Need-Text 'skills/md-html/SKILL.md' '普通 review/test 结果本身不升级'
foreach ($path in @(
        'skills/entry-router/SKILL.md',
        'skills/orchestrator/SKILL.md',
        'skills/orchestrator/references/runbook.md',
        'skills/orchestrator/references/lite-writing-guide.md',
        'vault-template/entry/AGENTS.md.template',
        'vault-template/工作流/任务识别协议.md',
        'skills/md-html/SKILL.md',
        'README.md'
    )) {
    Reject-Regex $path '用户要求 workflow / 留痕 / review / test / 计划|user asks for workflow / durable notes / review / test / planning|需要计划、留痕、review、test|`走 workflow` / `留痕` / `review` / `test`|偏 `workflow`：.*review.*test|需要 review/test 时进 harness|Clarification 协议族.*仍走 `new-task mode=workflow`' "$path should not route blanket review/test nouns to workflow"
    Reject-Regex $path '`直接改` / `快修` 偏 `quick`|偏 `quick`：.*直接改.*快修' "$path should not route mutation by override words alone"
    Reject-Regex $path '信息不足且无法判断归属时，先.*写入收件箱|仍不确定(?s:.*?)先写 `收件箱\.md`' "$path should ask interactive ambiguity before any inbox write"
    Reject-Regex $path 'resume-current.*switch-existing.*(?:then|再) load.*current-stage skill|resume-current.*switch-existing.*再加载当前 stage skill' "$path should not load a stage skill for read-only existing-task inspection"
}
$inboxRecoveryContracts = @(
    'open inbox + existing docs/tasks/{task_id}/plan.md -> switch-existing',
    'quick success -> exact triage',
    'new workflow -> validator -> background SyncOnly -> exact triage',
    'ask/pending/failure -> inbox row remains open',
    'create/triage crash -> inbox row remains open',
    'unknown inbox row -> deterministic route_task_id; task_plan_exists -> switch-existing, otherwise new-task'
)
foreach ($contract in $inboxRecoveryContracts) {
    Need-Text 'skills/entry-router/SKILL.md' $contract
}
Need-Text 'skills/orchestrator/SKILL.md' 'machine contracts 以 `entry-router` 为唯一来源'

foreach ($path in @('vault-template/工作流/共享记忆协议.md', 'vault-template/工作流/写回协议.md')) {
    Need-Text $path 'runtime.lock.json` 仅是 repair 期间的瞬时诊断文件，不是锁真相源'
    Need-Text $path '-RowId <row_id> -SetStatus cleared'
    Need-Text $path 'actionable/durable'
    Need-Text $path 'write-authorized'
    Need-Text $path 'read-only inspect/status 零写'
    Reject-Regex $path '写共享运行时前先检查 `运行时/runtime\.lock\.json`|超过 30 分钟未释放的锁视为过期|30 分钟未释放视为过期' "$path should not treat runtime.lock.json as lock authority"
}
Reject-Regex 'vault-template/工作流/写回协议.md' '当一个请求预计需要多步完成时' 'writeback protocol should not authorize writes merely because a request is multi-step'
Reject-Regex 'vault-template/工作流/写回协议.md' '若 Codex 不是当前入口 host，则只写任务工作区' 'non-entry Codex writes should require explicit write-authorized workflow intent'
Reject-Regex 'vault-template/工作流/共享记忆协议.md' '未被选为入口 host 的 Codex.*只写任务级文档' 'shared-memory protocol should not authorize task writes from host identity alone'
Reject-Regex 'vault-template/工作流/恢复协议.md' '(?m)^\s*- 判定当前 stage 后，只加载对应 stage skill' 'read-only recovery should not load a stage skill'

foreach ($path in @(
        'skills/entry-router/SKILL.md',
        'skills/obsidian-memory/SKILL.md',
        'vault-template/工作流/共享记忆协议.md',
        'vault-template/工作流/写回协议.md',
        'README.md'
    )) {
    Need-Text $path '已授权'
    Reject-Regex $path '新事项先写|新事项先进入|先写入 \[\[运行时/收件箱\]\]|当收到尚未整理的新事项' "$path should not write interactive ambiguity to inbox before ask"
}
Need-Text 'skills/obsidian-memory/SKILL.md' 'read-only inspect/status 零写'
foreach ($path in @(
        'skills/entry-router/SKILL.md',
        'skills/obsidian-memory/SKILL.md',
        'skills/orchestrator/SKILL.md',
        'skills/workflow-team/SKILL.md',
        'docs/工作流/single-writer-precompact.md',
        'docs/工作流/context-provider-boundary.md',
        'vault-template/工作流/共享记忆协议.md',
        'vault-template/工作流/写回协议.md',
        'vault-template/工作流/记忆管理协议.md',
        'README.md'
    )) {
    if ($path -eq 'docs/工作流/context-provider-boundary.md') {
        Need-Text $path 'user explicitly authorizes memory write'
    } else {
        Need-Text $path '用户明确'
    }
    Reject-Regex $path '未确认(?:的)?稳定(?:记忆)?偏好先写|未确认(?:的)?稳定记忆候选先写|pending wisdom 不直接落到.*先走收件箱|如需提交 pending wisdom，先走' "$path should not auto-write memory candidates from read-only work"
}
Need-Text 'skills/entry-router/SKILL.md' '裸 `恢复一下 / resume` 走 ask'
Need-Text 'README.md' '裸“恢复一下”/`resume` 若意图不明则 ask'

foreach ($path in @(
        'skills/entry-router/SKILL.md',
        'skills/orchestrator/SKILL.md',
        'skills/orchestrator/references/lite-writing-guide.md',
        'skills/orchestrator/references/runbook.md',
        'skills/md-html/SKILL.md',
        'vault-template/entry/AGENTS.md.template',
        'vault-template/工作流/任务识别协议.md',
        'agent-configs/workspace/AGENTS.md.template',
        'agent-configs/codex/AGENTS.md.template',
        'agent-configs/claude/CLAUDE.md.template',
        'README.md'
    )) {
    Reject-Regex $path '只问一个最小澄清问题|先问一个最小澄清问题|一次只问一个最小问题|只问一个最小问题|only one minimal question|ask one minimal question|one minimal clarification question' "$path should not use shallow one-question ask wording"
    Reject-Regex $path '(?mi)^stage:\s*ASK\b' "$path should not introduce ASK as a frontmatter stage"
}

foreach ($path in @(
        'skills/entry-router/SKILL.md',
        'vault-template/entry/AGENTS.md.template',
        'agent-configs/workspace/AGENTS.md.template',
        'agent-configs/codex/AGENTS.md.template',
        'agent-configs/claude/CLAUDE.md.template',
        'README.md'
    )) {
    Reject-Regex $path '1% chance|ABSOLUTELY MUST invoke|Invoke relevant or requested skills BEFORE any response or action|Even a 1% chance' "$path should not use broad pre-routing skill invocation wording"
}

Reject-Regex 'skills/orchestrator/references/lite-writing-guide.md' 'PLAN\s*->\s*ASK|ASK\s*->\s*PLAN|PLAN\s*->\s*IMPLEMENT\s*->\s*REVIEW\s*->\s*TEST\s*->\s*SUMMARY' 'lite writing guide should not list ASK or legacy stage chains'
Reject-Regex 'agent-configs/workspace/AGENTS.md.template' '(?m)^\s*-\s*(ASK|QUICK|REVIEW|SUMMARY|HANDOFF)\b' 'workspace template should not list non-canonical workflow stages'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "- $_" }
    exit 1
}

Write-Output 'Entry routing clarification gate verified.'
