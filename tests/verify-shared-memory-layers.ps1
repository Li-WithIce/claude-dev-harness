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

    throw 'Unable to locate a PowerShell host executable for verify-shared-memory-layers.ps1'
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Remove-DirectoryWithRetry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 200
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Add-Failure ("cleanup failed for {0}: {1}" -f $Path, $lastError.Exception.Message)
    }
}

function New-LayersFixture {
    param([string]$CaseRoot)

    $repoFixtureRoot = Join-Path $CaseRoot 'repo'
    $vaultRoot = Join-Path $repoFixtureRoot '.assistant'

    Write-Utf8Bom -Path (Join-Path $repoFixtureRoot 'docs\shared-memory-layers.md') -Content @"
## Layers

| Layer | Path | Writer | Truth |
|-------|------|--------|-------|
| artifact | docs/tasks/<task-id>/ | entry agent | authoritative |

## Writeback Ladder

1. plan.md
2. task runtime

## Forbidden Reverse Edges

- team board -> vault
"@

    Write-Utf8Bom -Path (Join-Path $vaultRoot '工作流\共享记忆协议.md') -Content @"
# 共享记忆协议

- 参见 docs/shared-memory-layers.md
"@

    Write-Utf8Bom -Path (Join-Path $vaultRoot '运行时\当前任务.md') -Content @"
---
updated: 2026-04-27 10:00:00
task_id: sample-task
entry_host: claudecode
writer: advance-stage
---

# 当前任务

| 项目 | 值 |
|------|-----|
| task_id | `sample-task` |
| 任务 | Sample Task |
| 状态 | PLAN |
| 当前文档 | docs/tasks/sample-task/plan.md |
| 下一步 | Continue |
"@

    Write-Utf8Bom -Path (Join-Path $vaultRoot '运行时\恢复索引.md') -Content @"
---
tags: [运行时, 恢复索引]
updated: 2026-04-27 10:00:00
derived_from: [运行时/当前任务.md, 运行时/tasks/, 运行时/中断任务.md]
schema_version: recovery-index/v1.1
---

# 恢复索引
"@

    Write-Utf8Bom -Path (Join-Path $vaultRoot '运行时\中断任务.md') -Content @"
---
updated: 2026-04-27 10:00:00
derived_from: [运行时/tasks/]
---

# 中断任务
"@

    Write-Utf8Bom -Path (Join-Path $vaultRoot '运行时\tasks\sample-task.md') -Content @"
---
schema_version: task-runtime/v1.1
task_id: sample-task
task_name: Sample Task
primary_artifact: docs/tasks/sample-task/plan.md
entry_host: claudecode
---
"@

    Write-Utf8Bom -Path (Join-Path $vaultRoot '运行时\runtime.lock.json') -Content (@{
            writer = 'repair-shared-memory'
            task_id = 'sample-task'
            locked_at = '2026-04-27T10:00:00Z'
            entry_host = 'team-leader'
        } | ConvertTo-Json -Depth 3)

    return [pscustomobject]@{
        RepoRoot = $repoFixtureRoot
        VaultRoot = $vaultRoot
        LayersDocPath = Join-Path $repoFixtureRoot 'docs\shared-memory-layers.md'
        CurrentTaskPath = Join-Path $vaultRoot '运行时\当前任务.md'
        RecoveryIndexPath = Join-Path $vaultRoot '运行时\恢复索引.md'
        InterruptedPath = Join-Path $vaultRoot '运行时\中断任务.md'
        LockPath = Join-Path $vaultRoot '运行时\runtime.lock.json'
    }
}

function Invoke-LayersCheck {
    param(
        [string]$RepoRoot,
        [string]$VaultRoot
    )

    $scriptPath = Join-Path $script:RepoRoot 'scripts\check-shared-memory-layers.ps1'
    $hostPath = Get-PowerShellHostPath
    $argumentList = @('-NoProfile')
    if ((Split-Path -Leaf $hostPath) -ieq 'powershell.exe') {
        $argumentList += @('-ExecutionPolicy', 'Bypass')
    }
    $argumentList += @(
        '-File', $scriptPath,
        '-RepoRoot', $RepoRoot,
        '-VaultRoot', $VaultRoot
    )

    $output = @(& $hostPath @argumentList 2>&1)
    return [pscustomobject]@{
        Output = @($output | ForEach-Object { [string]$_ })
        ExitCode = $LASTEXITCODE
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$script:RepoRoot = Get-NormalizedPath -Path $RepoRoot
$script:Checks = @()
$script:Failures = @()
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-shared-memory-layers-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

try {
    $caseL1 = New-LayersFixture -CaseRoot (Join-Path $scratchRoot 'l1-complete')
    $resultL1 = Invoke-LayersCheck -RepoRoot $caseL1.RepoRoot -VaultRoot $caseL1.VaultRoot
    $outputL1 = $resultL1.Output -join [Environment]::NewLine
    if ($resultL1.ExitCode -ne 0 -or $outputL1 -notmatch '(?im)^Errors:\s*$' -or $outputL1 -notmatch '(?im)^- none\s*$') {
        Add-Failure 'L1 should pass when layers doc, protocol reference, entry_host, derived_from, and lock schema are complete'
    } else {
        Add-Check 'L1 passes when layers doc, protocol reference, entry_host, derived_from, and lock schema are complete'
    }

    $caseL2 = New-LayersFixture -CaseRoot (Join-Path $scratchRoot 'l2-missing-section')
    $layersWithoutSection = (Get-Content -LiteralPath $caseL2.LayersDocPath -Raw -Encoding utf8) -replace [regex]::Escape('## Writeback Ladder'), '## Missing Ladder'
    Write-Utf8Bom -Path $caseL2.LayersDocPath -Content $layersWithoutSection
    $resultL2 = Invoke-LayersCheck -RepoRoot $caseL2.RepoRoot -VaultRoot $caseL2.VaultRoot
    $outputL2 = $resultL2.Output -join [Environment]::NewLine
    if ($resultL2.ExitCode -eq 0 -or $outputL2 -notmatch [regex]::Escape('missing required section: ## Writeback Ladder')) {
        Add-Failure 'L2 should fail with a concrete missing-section error when docs/shared-memory-layers.md loses a required heading'
    } else {
        Add-Check 'L2 fails with a concrete missing-section error when docs/shared-memory-layers.md loses a required heading'
    }

    $caseL3 = New-LayersFixture -CaseRoot (Join-Path $scratchRoot 'l3-legacy-current-task')
    $currentWithoutEntryHost = (Get-Content -LiteralPath $caseL3.CurrentTaskPath -Raw -Encoding utf8) -replace "(?m)^entry_host:\s*.+\r?\n", ''
    Write-Utf8Bom -Path $caseL3.CurrentTaskPath -Content $currentWithoutEntryHost
    $resultL3 = Invoke-LayersCheck -RepoRoot $caseL3.RepoRoot -VaultRoot $caseL3.VaultRoot
    $outputL3 = $resultL3.Output -join [Environment]::NewLine
    if ($resultL3.ExitCode -ne 0 -or $outputL3 -notmatch [regex]::Escape('当前任务缺少 entry_host，按 legacy fallback 处理')) {
        Add-Failure 'L3 should warn, not fail, when 当前任务.md is still on the legacy no-entry_host shape'
    } else {
        Add-Check 'L3 warns, not fails, when 当前任务.md is still on the legacy no-entry_host shape'
    }

    $caseL4 = New-LayersFixture -CaseRoot (Join-Path $scratchRoot 'l4-missing-derived-from')
    $recoveryWithoutDerivedFrom = (Get-Content -LiteralPath $caseL4.RecoveryIndexPath -Raw -Encoding utf8) -replace "(?m)^derived_from:\s*.+\r?\n", ('derived_from: [<path>]' + "`r`n")
    Write-Utf8Bom -Path $caseL4.RecoveryIndexPath -Content $recoveryWithoutDerivedFrom
    $resultL4 = Invoke-LayersCheck -RepoRoot $caseL4.RepoRoot -VaultRoot $caseL4.VaultRoot
    $outputL4 = $resultL4.Output -join [Environment]::NewLine
    if ($resultL4.ExitCode -eq 0 -or $outputL4 -notmatch [regex]::Escape('恢复索引 缺少可用 derived_from')) {
        Add-Failure 'L4 should fail when 恢复索引.md lacks a concrete derived_from source list'
    } else {
        Add-Check 'L4 fails when 恢复索引.md lacks a concrete derived_from source list'
    }

    $caseL5 = New-LayersFixture -CaseRoot (Join-Path $scratchRoot 'l5-lock-missing-entry-host')
    Write-Utf8Bom -Path $caseL5.LockPath -Content (@{
            writer = 'repair-shared-memory'
            task_id = 'sample-task'
            locked_at = '2026-04-27T10:00:00Z'
        } | ConvertTo-Json -Depth 3)
    $resultL5 = Invoke-LayersCheck -RepoRoot $caseL5.RepoRoot -VaultRoot $caseL5.VaultRoot
    $outputL5 = $resultL5.Output -join [Environment]::NewLine
    if ($resultL5.ExitCode -eq 0 -or $outputL5 -notmatch [regex]::Escape('runtime.lock.json missing field(s): entry_host')) {
        Add-Failure 'L5 should fail when runtime.lock.json omits the required entry_host field'
    } else {
        Add-Check 'L5 fails when runtime.lock.json omits the required entry_host field'
    }

    $caseL6 = New-LayersFixture -CaseRoot (Join-Path $scratchRoot 'l6-rendered-vault-template')
    $templateProtocolPath = Join-Path $script:RepoRoot 'vault-template\工作流\共享记忆协议.md'
    $renderedProtocol = (Get-Content -LiteralPath $templateProtocolPath -Raw -Encoding utf8).
        Replace('{REPO_ROOT}', $caseL6.RepoRoot).
        Replace('{VAULT_PATH}', $caseL6.VaultRoot).
        Replace('{CLAUDE_HOME}', 'C:\Users\fixture\.claude').
        Replace('{CODEX_HOME}', 'C:\Users\fixture\.codex')
    Write-Utf8Bom -Path (Join-Path $caseL6.VaultRoot '工作流\共享记忆协议.md') -Content $renderedProtocol
    $resultL6 = Invoke-LayersCheck -RepoRoot $caseL6.RepoRoot -VaultRoot $caseL6.VaultRoot
    $outputL6 = $resultL6.Output -join [Environment]::NewLine
    if ($resultL6.ExitCode -ne 0 -or $outputL6 -notmatch [regex]::Escape('共享记忆协议引用了 docs/shared-memory-layers.md')) {
        Add-Failure 'L6 should pass when 共享记忆协议.md is rendered from the vault template'
    } else {
        Add-Check 'L6 passes when 共享记忆协议.md is rendered from the vault template'
    }
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
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
