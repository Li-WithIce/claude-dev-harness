[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Convert-CodePointsToString {
    param([int[]]$CodePoints)

    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function Get-PowerShellHostPath {
    try {
        $currentHostPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not [string]::IsNullOrWhiteSpace($currentHostPath) -and (Test-Path -LiteralPath $currentHostPath -PathType Leaf)) {
            return (Get-NormalizedPath -Path $currentHostPath)
        }
    } catch {
        # Fall through to explicit discovery.
    }

    foreach ($commandName in @('pwsh', 'powershell.exe')) {
        try {
            $command = Get-Command $commandName -ErrorAction Stop | Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace($command.Source)) {
                return (Get-NormalizedPath -Path $command.Source)
            }
        } catch {
            # Try the next candidate.
        }
    }

    throw 'Unable to locate a PowerShell host executable for verify-promote-runtime-inbox.ps1'
}

function Invoke-PromoteInbox {
    param(
        [string]$VaultRoot,
        [hashtable]$Arguments = @{},
        [string]$WorkingDirectory = ''
    )

    $scriptPath = Join-Path $RepoRoot 'scripts\promote-runtime-inbox.ps1'
    $hostPath = Get-PowerShellHostPath
    $argumentList = @('-NoProfile')
    if ((Split-Path -Leaf $hostPath) -ieq 'powershell.exe') {
        $argumentList += @('-ExecutionPolicy', 'Bypass')
    }
    $argumentList += @('-File', $scriptPath)
    if (-not [string]::IsNullOrWhiteSpace($VaultRoot)) {
        $argumentList += @('-VaultRoot', $VaultRoot)
    }

    foreach ($entry in $Arguments.GetEnumerator()) {
        $argumentList += ('-{0}' -f [string]$entry.Key)
        $argumentList += [string]$entry.Value
    }

    $originalLocation = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $originalLocation = (Get-Location).Path
            Set-Location -LiteralPath $WorkingDirectory
        }

        $output = @(& $hostPath @argumentList 2>&1)
        return [pscustomobject]@{
            Output   = @($output | ForEach-Object { [string]$_ })
            ExitCode = $LASTEXITCODE
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($originalLocation)) {
            Set-Location -LiteralPath $originalLocation
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$tmpRoot = Join-Path $RepoRoot 'tmp\runtime-inbox-promotion-regression'
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$runtimeDirName = Convert-CodePointsToString -CodePoints @(36816, 34892, 26102)
$inboxFileName = Convert-CodePointsToString -CodePoints @(25910, 20214, 31665, 46, 109, 100)
$interruptedFileName = Convert-CodePointsToString -CodePoints @(20013, 26029, 20219, 21153, 46, 109, 100)

$caseRoot = Join-Path $tmpRoot 'promote-runtime-inbox'
if (Test-Path -LiteralPath $caseRoot) {
    Remove-Item -LiteralPath $caseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
$workspaceRoot = Join-Path $caseRoot 'workspace'
$vaultRoot = Join-Path $workspaceRoot '.assistant'
$runtimeDir = Join-Path $vaultRoot $runtimeDirName
$orchestrationDir = Join-Path $vaultRoot 'orchestration'
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
New-Item -ItemType Directory -Path $orchestrationDir -Force | Out-Null

$inboxPath = Join-Path $runtimeDir $inboxFileName
$currentFlowPath = Join-Path $orchestrationDir 'current-flow.md'
$initialFlow = @(
    'schema_version: 2.2'
    'task_id: active-task'
    'task_name: Active Task'
    'stage: PLAN'
    'entry_tool: Codex'
    'current_doc: docs/tasks/active-task/plan.md'
) -join "`r`n"
Set-Content -LiteralPath $currentFlowPath -Value $initialFlow -Encoding utf8

$inboxContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-04-03'
    'updated: 2026-04-03 10:05:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    '| 2026-04-03 10:05:00 | orchestrator-bootstrap | unknown | inbox-first | open | Queue workflow stabilization work | User asked to keep current task active but remember this follow-up. |'
    '| 2026-04-03 10:06:00 | orchestrator-bootstrap | unknown | inbox-first | open | Clarify whether the new request should replace the active task | The routing decision conflicts with the current plan. |'
) -join "`r`n"
Set-Content -LiteralPath $inboxPath -Value $inboxContent -Encoding utf8

$interruptResult = Invoke-PromoteInbox `
    -VaultRoot $vaultRoot `
    -Arguments @{
        WorkspaceRoot  = $workspaceRoot
        Target         = 'interrupted-task'
        CreatedAt      = '2026-04-03 10:05:00'
        TargetTaskId   = 'workflow-stability-followup'
        TargetTaskName = 'Workflow Stability Follow-up'
        EntryHost      = 'codex'
        Priority       = 'P1'
        TaskStage      = 'PLAN'
        NextStep       = 'Draft the workflow stabilization plan.'
    }
$interruptedPath = Join-Path $runtimeDir $interruptedFileName
$taskStatePath = Join-Path (Join-Path $runtimeDir 'tasks') 'workflow-stability-followup.md'
$primaryArtifactPath = Join-Path $workspaceRoot 'docs\tasks\workflow-stability-followup\plan.md'
$postInterruptInbox = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
$interruptedContent = Get-Content -LiteralPath $interruptedPath -Raw -Encoding utf8
$taskStateContent = Get-Content -LiteralPath $taskStatePath -Raw -Encoding utf8
$primaryArtifactContent = Get-Content -LiteralPath $primaryArtifactPath -Raw -Encoding utf8
$interruptOutput = $interruptResult.Output -join [Environment]::NewLine

if ($interruptResult.ExitCode -ne 0) {
    Add-Failure 'promote-runtime-inbox should return exit code 0 when routing an inbox item into interrupted-task'
} else {
    Add-Check 'promote-runtime-inbox returns exit code 0 when routing an inbox item into interrupted-task'
}

if ($interruptOutput -notmatch 'STATUS:\s+PASS' -or $interruptOutput -notmatch 'Target:\s+interrupted-task') {
    Add-Failure 'promote-runtime-inbox should report STATUS: PASS and the interrupted-task target after promotion'
} else {
    Add-Check 'promote-runtime-inbox reports STATUS: PASS and the interrupted-task target after promotion'
}

if ($interruptedContent -notmatch '\|\s*P1\s*\|\s*.+?\s*\|\s*Workflow Stability Follow-up\s*\|\s*workflow-stability-followup\s*\|\s*PLAN\s*\|\s*Draft the workflow stabilization plan\.\s*\|') {
    Add-Failure 'promote-runtime-inbox should append or upsert the interrupted-task row'
} else {
    Add-Check 'promote-runtime-inbox appends or upserts the interrupted-task row'
}

if ($taskStateContent -notmatch 'schema_version:\s+task-runtime/v1\.1') {
    Add-Failure 'promote-runtime-inbox should create a task-runtime/v1.1 state file for interrupted-task promotion'
} else {
    Add-Check 'promote-runtime-inbox creates a task-runtime/v1.1 state file for interrupted-task promotion'
}

if ($taskStateContent -notmatch 'entry_host:\s+codex') {
    Add-Failure 'promote-runtime-inbox should persist entry_host into the promoted task runtime when interrupted-task promotion supplies one'
} else {
    Add-Check 'promote-runtime-inbox persists entry_host into the promoted task runtime when interrupted-task promotion supplies one'
}

if ($taskStateContent -notmatch 'primary_artifact:\s+docs/tasks/workflow-stability-followup/plan\.md') {
    Add-Failure 'promote-runtime-inbox should point the created task state at the default plan artifact'
} else {
    Add-Check 'promote-runtime-inbox points the created task state at the default plan artifact'
}

if ($primaryArtifactContent -notmatch [regex]::Escape('Queue workflow stabilization work')) {
    Add-Failure 'promote-runtime-inbox should seed the primary artifact with the inbox summary'
} else {
    Add-Check 'promote-runtime-inbox seeds the primary artifact with the inbox summary'
}

if ($postInterruptInbox -notmatch '\|\s*2026-04-03 10:05:00\s*\|\s*orchestrator-bootstrap\s*\|\s*unknown\s*\|\s*inbox-first\s*\|\s*cleared\s*\|') {
    Add-Failure 'promote-runtime-inbox should clear the routed interrupted-task inbox row'
} else {
    Add-Check 'promote-runtime-inbox clears the routed interrupted-task inbox row'
}

if ($postInterruptInbox -notmatch [regex]::Escape('Promoted to interrupted-task workflow-stability-followup.')) {
    Add-Failure 'promote-runtime-inbox should append a promotion note when routing to interrupted-task'
} else {
    Add-Check 'promote-runtime-inbox appends a promotion note when routing to interrupted-task'
}

$decisionResult = Invoke-PromoteInbox `
    -VaultRoot $vaultRoot `
    -Arguments @{
        WorkspaceRoot = $workspaceRoot
        Target        = 'decision-needed'
        CreatedAt     = '2026-04-03 10:06:00'
    }
$decisionPath = Join-Path $orchestrationDir 'decision-needed.md'
$decisionContent = Get-Content -LiteralPath $decisionPath -Raw -Encoding utf8
$postDecisionInbox = Get-Content -LiteralPath $inboxPath -Raw -Encoding utf8
$decisionOutput = $decisionResult.Output -join [Environment]::NewLine

if ($decisionResult.ExitCode -ne 0) {
    Add-Failure 'promote-runtime-inbox should return exit code 0 when routing an inbox item into decision-needed'
} else {
    Add-Check 'promote-runtime-inbox returns exit code 0 when routing an inbox item into decision-needed'
}

if ($decisionOutput -notmatch 'STATUS:\s+PASS' -or $decisionOutput -notmatch 'Target:\s+decision-needed') {
    Add-Failure 'promote-runtime-inbox should report STATUS: PASS and the decision-needed target after promotion'
} else {
    Add-Check 'promote-runtime-inbox reports STATUS: PASS and the decision-needed target after promotion'
}

if ($decisionContent -notmatch 'task_id:\s+active-task') {
    Add-Failure 'promote-runtime-inbox should default decision-needed task_id to the active current-flow task'
} else {
    Add-Check 'promote-runtime-inbox defaults decision-needed task_id to the active current-flow task'
}

if ($decisionContent -notmatch 'status:\s+open') {
    Add-Failure 'promote-runtime-inbox should create an open decision-needed.md'
} else {
    Add-Check 'promote-runtime-inbox creates an open decision-needed.md'
}

if ($decisionContent -notmatch [regex]::Escape('Clarify whether the new request should replace the active task')) {
    Add-Failure 'promote-runtime-inbox should carry the inbox summary into decision-needed.md'
} else {
    Add-Check 'promote-runtime-inbox carries the inbox summary into decision-needed.md'
}

if ($postDecisionInbox -notmatch '\|\s*2026-04-03 10:06:00\s*\|\s*orchestrator-bootstrap\s*\|\s*unknown\s*\|\s*inbox-first\s*\|\s*cleared\s*\|') {
    Add-Failure 'promote-runtime-inbox should clear the routed decision-needed inbox row'
} else {
    Add-Check 'promote-runtime-inbox clears the routed decision-needed inbox row'
}

if ($postDecisionInbox -notmatch [regex]::Escape('Promoted to decision-needed.md for task active-task.')) {
    Add-Failure 'promote-runtime-inbox should append a promotion note when routing to decision-needed'
} else {
    Add-Check 'promote-runtime-inbox appends a promotion note when routing to decision-needed'
}

$externalCaseRoot = Join-Path $tmpRoot 'promote-runtime-inbox-external-vault'
if (Test-Path -LiteralPath $externalCaseRoot) {
    Remove-Item -LiteralPath $externalCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $externalCaseRoot -Force | Out-Null
$externalWorkspaceRoot = Join-Path $externalCaseRoot 'workspace'
$externalVaultRoot = Join-Path (Join-Path $externalCaseRoot 'shared-vault') '.assistant'
$externalRuntimeDir = Join-Path $externalVaultRoot $runtimeDirName
$externalOrchestrationDir = Join-Path $externalVaultRoot 'orchestration'
New-Item -ItemType Directory -Path $externalWorkspaceRoot -Force | Out-Null
New-Item -ItemType Directory -Path $externalRuntimeDir -Force | Out-Null
New-Item -ItemType Directory -Path $externalOrchestrationDir -Force | Out-Null

$externalCurrentFlowPath = Join-Path $externalOrchestrationDir 'current-flow.md'
Set-Content -LiteralPath $externalCurrentFlowPath -Value $initialFlow -Encoding utf8

$externalInboxPath = Join-Path $externalRuntimeDir $inboxFileName
$externalInboxContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-04-03'
    'updated: 2026-04-03 11:00:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    '| 2026-04-03 11:00:00 | orchestrator-bootstrap | unknown | inbox-first | open | Route follow-up into the current workspace docs tree | Shared vault is external, but artifacts must stay in the active workspace. |'
) -join "`r`n"
Set-Content -LiteralPath $externalInboxPath -Value $externalInboxContent -Encoding utf8

$externalInterruptResult = Invoke-PromoteInbox `
    -VaultRoot $externalVaultRoot `
    -Arguments @{
        WorkspaceRoot  = $externalWorkspaceRoot
        Target         = 'interrupted-task'
        CreatedAt      = '2026-04-03 11:00:00'
        TargetTaskId   = 'external-vault-followup'
        TargetTaskName = 'External Vault Follow-up'
        Priority       = 'P2'
        TaskStage      = 'PLAN'
        NextStep       = 'Draft the follow-up plan inside the active workspace.'
    }
$externalTaskStatePath = Join-Path (Join-Path $externalRuntimeDir 'tasks') 'external-vault-followup.md'
$externalArtifactPath = Join-Path $externalWorkspaceRoot 'docs\tasks\external-vault-followup\plan.md'
$wrongArtifactPath = Join-Path (Split-Path -Parent $externalVaultRoot) 'docs\tasks\external-vault-followup\plan.md'
$externalTaskStateContent = Get-Content -LiteralPath $externalTaskStatePath -Raw -Encoding utf8

if ($externalInterruptResult.ExitCode -ne 0) {
    Add-Failure 'promote-runtime-inbox should return exit code 0 when promoting from an external shared vault'
} else {
    Add-Check 'promote-runtime-inbox returns exit code 0 when promoting from an external shared vault'
}

if (-not (Test-Path -LiteralPath $externalArtifactPath -PathType Leaf)) {
    Add-Failure 'promote-runtime-inbox should create promoted artifacts inside the active workspace when the shared vault is external'
} else {
    Add-Check 'promote-runtime-inbox creates promoted artifacts inside the active workspace when the shared vault is external'
}

if (Test-Path -LiteralPath $wrongArtifactPath -PathType Leaf) {
    Add-Failure 'promote-runtime-inbox should not create docs artifacts under the external shared-vault parent directory'
} else {
    Add-Check 'promote-runtime-inbox does not create docs artifacts under the external shared-vault parent directory'
}

if ($externalTaskStateContent -notmatch [regex]::Escape("workspace: $externalWorkspaceRoot")) {
    Add-Failure 'promote-runtime-inbox should persist the active workspace root into the created task state when the shared vault is external'
} else {
    Add-Check 'promote-runtime-inbox persists the active workspace root into the created task state when the shared vault is external'
}

$wrapperCaseRoot = Join-Path $tmpRoot 'promote-runtime-inbox-wrapper-cwd'
if (Test-Path -LiteralPath $wrapperCaseRoot) {
    Remove-Item -LiteralPath $wrapperCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $wrapperCaseRoot -Force | Out-Null
$wrapperWorkspaceRoot = Join-Path $wrapperCaseRoot 'workspace'
$wrapperVaultRoot = Join-Path $wrapperWorkspaceRoot '.assistant'
$wrapperRuntimeDir = Join-Path $wrapperVaultRoot $runtimeDirName
$wrapperOrchestrationDir = Join-Path $wrapperVaultRoot 'orchestration'
New-Item -ItemType Directory -Path $wrapperRuntimeDir -Force | Out-Null
New-Item -ItemType Directory -Path $wrapperOrchestrationDir -Force | Out-Null

$wrapperCurrentFlowPath = Join-Path $wrapperOrchestrationDir 'current-flow.md'
Set-Content -LiteralPath $wrapperCurrentFlowPath -Value $initialFlow -Encoding utf8

$wrapperInboxPath = Join-Path $wrapperRuntimeDir $inboxFileName
$wrapperInboxContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-04-03'
    'updated: 2026-04-03 12:00:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    '| 2026-04-03 12:00:00 | manual-test | unknown | inbox-first | open | Promote from workspace cwd without explicit workspace root | The repo wrapper should use the active workspace instead of the repo root. |'
) -join "`r`n"
Set-Content -LiteralPath $wrapperInboxPath -Value $wrapperInboxContent -Encoding utf8

$wrapperPromoteResult = Invoke-PromoteInbox `
    -VaultRoot '' `
    -WorkingDirectory $wrapperWorkspaceRoot `
    -Arguments @{
        Target         = 'interrupted-task'
        CreatedAt      = '2026-04-03 12:00:00'
        TargetTaskId   = 'cwd-wrapper-followup'
        TargetTaskName = 'Cwd Wrapper Follow-up'
        Priority       = 'P2'
        TaskStage      = 'PLAN'
        NextStep       = 'Draft the follow-up plan from the workspace cwd.'
    }
$wrapperTaskStatePath = Join-Path (Join-Path $wrapperRuntimeDir 'tasks') 'cwd-wrapper-followup.md'
$wrapperArtifactPath = Join-Path $wrapperWorkspaceRoot 'docs\tasks\cwd-wrapper-followup\plan.md'
$wrongWrapperArtifactPath = Join-Path $RepoRoot 'docs\tasks\cwd-wrapper-followup\plan.md'
$wrapperTaskStateContent = Get-Content -LiteralPath $wrapperTaskStatePath -Raw -Encoding utf8

if ($wrapperPromoteResult.ExitCode -ne 0) {
    Add-Failure 'promote-runtime-inbox wrapper should return exit code 0 when run from the workspace cwd without an explicit workspace root'
} else {
    Add-Check 'promote-runtime-inbox wrapper returns exit code 0 when run from the workspace cwd without an explicit workspace root'
}

if (-not (Test-Path -LiteralPath $wrapperArtifactPath -PathType Leaf)) {
    Add-Failure 'promote-runtime-inbox wrapper should create promoted artifacts inside the cwd workspace when WorkspaceRoot is omitted'
} else {
    Add-Check 'promote-runtime-inbox wrapper creates promoted artifacts inside the cwd workspace when WorkspaceRoot is omitted'
}

if (Test-Path -LiteralPath $wrongWrapperArtifactPath -PathType Leaf) {
    Add-Failure 'promote-runtime-inbox wrapper should not create promoted artifacts under the repo root when WorkspaceRoot is omitted'
} else {
    Add-Check 'promote-runtime-inbox wrapper does not create promoted artifacts under the repo root when WorkspaceRoot is omitted'
}

if ($wrapperTaskStateContent -notmatch [regex]::Escape("workspace: $wrapperWorkspaceRoot")) {
    Add-Failure 'promote-runtime-inbox wrapper should persist the cwd workspace root into the created task state when WorkspaceRoot is omitted'
} else {
    Add-Check 'promote-runtime-inbox wrapper persists the cwd workspace root into the created task state when WorkspaceRoot is omitted'
}

$literalCaseRoot = Join-Path $tmpRoot 'promote-runtime-inbox-literal-summary'
if (Test-Path -LiteralPath $literalCaseRoot) {
    Remove-Item -LiteralPath $literalCaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $literalCaseRoot -Force | Out-Null
$literalWorkspaceRoot = Join-Path $literalCaseRoot 'workspace'
$literalVaultRoot = Join-Path $literalWorkspaceRoot '.assistant'
$literalRuntimeDir = Join-Path $literalVaultRoot $runtimeDirName
$literalOrchestrationDir = Join-Path $literalVaultRoot 'orchestration'
New-Item -ItemType Directory -Path $literalRuntimeDir -Force | Out-Null
New-Item -ItemType Directory -Path $literalOrchestrationDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $literalOrchestrationDir 'current-flow.md') -Value $initialFlow -Encoding utf8

$literalInboxPath = Join-Path $literalRuntimeDir $inboxFileName
$literalInboxContent = @(
    '---'
    'tags: [runtime, inbox]'
    'created: 2026-04-03'
    'updated: 2026-04-03 13:00:00'
    'schema_version: runtime-inbox/v1.0'
    '---'
    ''
    '# Runtime Inbox'
    ''
    '| created_at | source | task_id | type | status | summary | payload |'
    '|------------|--------|---------|------|--------|---------|---------|'
    '| 2026-04-03 13:00:00 | manual-test | task-a | inbox-first | open | Need [docs] follow-up | payload a |'
    '| 2026-04-03 13:01:00 | manual-test | task-b | inbox-first | open | Need d follow-up | payload b |'
) -join "`r`n"
Set-Content -LiteralPath $literalInboxPath -Value $literalInboxContent -Encoding utf8

$literalPromoteResult = Invoke-PromoteInbox `
    -VaultRoot $literalVaultRoot `
    -Arguments @{
        WorkspaceRoot  = $literalWorkspaceRoot
        Target         = 'interrupted-task'
        SummaryContains = '[docs]'
        TargetTaskId   = 'literal-summary-followup'
        TargetTaskName = 'Literal Summary Follow-up'
        Priority       = 'P2'
        TaskStage      = 'PLAN'
        NextStep       = 'Follow the docs-specific branch.'
    }
$literalPromoteOutput = $literalPromoteResult.Output -join [Environment]::NewLine
$literalPostInbox = Get-Content -LiteralPath $literalInboxPath -Raw -Encoding utf8
$literalTaskStatePath = Join-Path (Join-Path $literalRuntimeDir 'tasks') 'literal-summary-followup.md'
$literalArtifactPath = Join-Path $literalWorkspaceRoot 'docs\tasks\literal-summary-followup\plan.md'

if ($literalPromoteResult.ExitCode -ne 0) {
    Add-Failure 'promote-runtime-inbox should treat SummaryContains as a literal substring and promote a unique row containing square brackets'
} else {
    Add-Check 'promote-runtime-inbox treats SummaryContains as a literal substring and promotes a unique row containing square brackets'
}

if ($literalPromoteOutput -notmatch 'STATUS:\s+PASS') {
    Add-Failure 'promote-runtime-inbox should report STATUS: PASS when SummaryContains includes literal wildcard-like characters'
} else {
    Add-Check 'promote-runtime-inbox reports STATUS: PASS when SummaryContains includes literal wildcard-like characters'
}

if (-not (Test-Path -LiteralPath $literalTaskStatePath -PathType Leaf) -or -not (Test-Path -LiteralPath $literalArtifactPath -PathType Leaf)) {
    Add-Failure 'promote-runtime-inbox should create promoted artifacts for the row whose summary literally contains [docs]'
} else {
    Add-Check 'promote-runtime-inbox creates promoted artifacts for the row whose summary literally contains [docs]'
}

if ($literalPostInbox -notmatch '\|\s*2026-04-03 13:00:00\s*\|\s*manual-test\s*\|\s*task-a\s*\|\s*inbox-first\s*\|\s*cleared\s*\|\s*Need \[docs\] follow-up\s*\|') {
    Add-Failure 'promote-runtime-inbox should clear only the row whose summary literally contains [docs]'
} else {
    Add-Check 'promote-runtime-inbox clears only the row whose summary literally contains [docs]'
}

if ($literalPostInbox -notmatch '\|\s*2026-04-03 13:01:00\s*\|\s*manual-test\s*\|\s*task-b\s*\|\s*inbox-first\s*\|\s*open\s*\|\s*Need d follow-up\s*\|') {
    Add-Failure 'promote-runtime-inbox should leave non-matching rows untouched when SummaryContains includes literal wildcard-like characters'
} else {
    Add-Check 'promote-runtime-inbox leaves non-matching rows untouched when SummaryContains includes literal wildcard-like characters'
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ('- {0}' -f $item)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ('- {0}' -f $failure)
}

exit 1
