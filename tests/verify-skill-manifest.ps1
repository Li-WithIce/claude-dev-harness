[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-FileUtf8 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding utf8)
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

function Copy-RepoPathToFixture {
    param(
        [string]$SourceRoot,
        [string]$FixtureRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    $destinationPath = Join-Path $FixtureRoot $RelativePath
    $destinationParent = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
}

function New-IsolatedRepoFixture {
    param([string]$SourceRoot)

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-skill-manifest-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    foreach ($relativePath in @(
        'scripts\advance-stage.ps1',
        'scripts\generate-skills-index.ps1',
        'scripts\validate-lite-artifacts.ps1',
        'agent-configs\profiles',
        'agent-configs\workflows',
        'skills\entry-router',
        'skills\plan',
        'skills\review'
    )) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath $relativePath
    }

    return $fixtureRoot
}

function New-PlanContent {
    param(
        [string]$TaskId,
        [string]$Stage = 'PLAN',
        [string]$Tool = 'claudecode'
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'
@"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
updated: $updatedDate
---
# Skill Manifest Fixture

## Clarification
- 验收标准: skill manifest writes as a best-effort per-task artifact.
- 非目标: no team preset bridge.
- 受影响目录: scripts/, tests/, agent-configs/
- 回滚策略: remove Phase 3 manifest output.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- Advance the fixture task once.

## Verification
- ``pwsh -File tests/verify-skill-manifest.ps1``

## Risks
- none

## Plan Review

## Implementation Notes

## Code Review

"@
}

function Invoke-AdvanceStageWithStreams {
    param(
        [string]$AdvancePath,
        [string]$TaskId,
        [string]$Tool,
        [string]$VaultRoot,
        [string]$RepoRoot
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $AdvancePath,
        '-TaskId', $TaskId,
        '-Tool', $Tool,
        '-VaultRoot', $VaultRoot,
        '-RepoRoot', $RepoRoot
    )

    $streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-skill-manifest-streams-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $streamRoot -Force | Out-Null
    $stdoutPath = Join-Path $streamRoot 'stdout.txt'
    $stderrPath = Join-Path $streamRoot 'stderr.txt'

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = ([string](Read-FileUtf8 -Path $stdoutPath)).Trim()
        $stderr = ([string](Read-FileUtf8 -Path $stderrPath)).Trim()
        $combined = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $combined += $stdout
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $combined += $stderr
        }

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Combined = ($combined -join "`n")
        }
    } finally {
        Remove-DirectoryWithRetry -Path $streamRoot
    }
}

function Get-WorkflowStageSkills {
    param(
        [string]$WorkflowPath,
        [string]$Stage
    )

    $currentStage = ''
    foreach ($line in (Get-Content -LiteralPath $WorkflowPath -Encoding utf8)) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^\s{2}([A-Z_]+):\s*$') {
            $currentStage = $Matches[1]
            continue
        }

        if ($currentStage -eq $Stage -and $line -match '^\s{4}skills_whitelist:\s*\[(.*)\]\s*$') {
            $items = @()
            foreach ($item in ($Matches[1] -split ',')) {
                $trimmed = $item.Trim().Trim('"').Trim("'")
                if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                    $items += $trimmed
                }
            }
            return $items
        }
    }

    return @()
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $RepoRoot
$advancePath = Join-Path $fixtureRoot 'scripts\advance-stage.ps1'
$workflowPath = Join-Path $fixtureRoot 'agent-configs\workflows\harness-lite.yaml'
$script:Checks = @()
$script:Failures = @()
$cleanupPaths = @($fixtureRoot)

try {
    $vaultRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-skill-manifest-vault-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $vaultRoot
    New-Item -ItemType Directory -Path (Join-Path $vaultRoot '运行时\tasks') -Force | Out-Null

    $taskE1 = 'skill-manifest-e1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskE1Dir = Join-Path (Join-Path $fixtureRoot 'docs\tasks') $taskE1
    New-Item -ItemType Directory -Path $taskE1Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskE1Dir 'plan.md') -Content (New-PlanContent -TaskId $taskE1)
    $e1Result = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskE1 -Tool 'codex' -VaultRoot $vaultRoot -RepoRoot $fixtureRoot
    $manifestPath = Join-Path $taskE1Dir 'skill-manifest.json'
    $manifestText = Read-FileUtf8 -Path $manifestPath
    $manifest = if ([string]::IsNullOrWhiteSpace($manifestText)) { $null } else { $manifestText | ConvertFrom-Json }
    $vaultManifestCount = @(Get-ChildItem -LiteralPath $vaultRoot -Recurse -Filter 'skill-manifest.json' -File -ErrorAction SilentlyContinue).Count
    if ($e1Result.ExitCode -eq 0 -and
        $e1Result.StdOut -eq 'PLAN_REVIEW | codex' -and
        $null -ne $manifest -and
        $manifest.version -eq 1 -and
        $manifest.task_id -eq $taskE1 -and
        $manifest.stage -eq 'PLAN_REVIEW' -and
        $manifest.tool -eq 'codex' -and
        $manifest.available_commands.Count -eq 1 -and
        $manifest.available_commands[0].name -eq 'review' -and
        -not [string]::IsNullOrWhiteSpace([string]$manifest.available_commands[0].description) -and
        -not [string]::IsNullOrWhiteSpace([string]$manifest.generated_at) -and
        $vaultManifestCount -eq 0) {
        Add-Check 'E1 manifest writes to docs/tasks/<task-id>/skill-manifest.json and never to .assistant'
    } else {
        Add-Failure ("E1 manifest positive case failed, got stdout=[{0}] stderr=[{1}] manifest=[{2}] vaultCount=[{3}]" -f $e1Result.StdOut, $e1Result.StdErr, $manifestText, $vaultManifestCount)
    }

    $expectedSkills = @(Get-WorkflowStageSkills -WorkflowPath $workflowPath -Stage 'PLAN_REVIEW' | Sort-Object)
    $actualSkills = @($manifest.available_commands | ForEach-Object { $_.name } | Sort-Object)
    if ((@($expectedSkills) -join '|') -eq ((@($actualSkills)) -join '|')) {
        Add-Check 'E2 manifest available_commands matches harness-lite workflow whitelist'
    } else {
        Add-Failure ("E2 available_commands mismatch, expected=[{0}] actual=[{1}]" -f ($expectedSkills -join ', '), ($actualSkills -join ', '))
    }

    $taskE3 = 'skill-manifest-e3-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskE3Dir = Join-Path (Join-Path $fixtureRoot 'docs\tasks') $taskE3
    New-Item -ItemType Directory -Path $taskE3Dir -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskE3Dir 'plan.md') -Content (New-PlanContent -TaskId $taskE3)
    $lockedManifestPath = Join-Path $taskE3Dir 'skill-manifest.json'
    [System.IO.File]::WriteAllText($lockedManifestPath, 'locked', (New-Object System.Text.UTF8Encoding($false)))
    $lockStream = [System.IO.File]::Open($lockedManifestPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $e3Result = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskE3 -Tool 'codex' -VaultRoot $vaultRoot -RepoRoot $fixtureRoot
    } finally {
        $lockStream.Dispose()
    }
    if ($e3Result.ExitCode -eq 0 -and
        $e3Result.StdOut -eq 'PLAN_REVIEW | codex' -and
        $e3Result.StdErr -match 'skill-manifest write skipped') {
        Add-Check 'E3 manifest write failures degrade to stderr diagnostics without blocking stage advance'
    } else {
        Add-Failure ("E3 write-failure downgrade failed, got stdout=[{0}] stderr=[{1}]" -f $e3Result.StdOut, $e3Result.StdErr)
    }

    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Add-Check 'E4 per-task manifest can be removed cleanly as part of task-level rollback'
    } else {
        Add-Failure 'E4 manifest rollback failed because the per-task file still exists'
    }

    $taskE5 = 'skill-manifest-e5-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskE5Dir = Join-Path (Join-Path $fixtureRoot 'docs\tasks') $taskE5
    New-Item -ItemType Directory -Path $taskE5Dir -Force | Out-Null
    $e5Plan = New-PlanContent -TaskId $taskE5 -Stage 'PLAN_REVIEW' -Tool 'codex'
    $e5Plan = $e5Plan -replace '(?m)^## Plan Review\s*', "## Plan Review`r`n### Run 1 · 2026-04-25 10:00 · runner: harness-reviewer`r`n- verdict: revise`r`n- findings: none`r`n- next: route back to PLAN`r`n"
    Write-Utf8Bom -Path (Join-Path $taskE5Dir 'plan.md') -Content $e5Plan
    $e5Result = Invoke-AdvanceStageWithStreams -AdvancePath $advancePath -TaskId $taskE5 -Tool 'codex' -VaultRoot $vaultRoot -RepoRoot $fixtureRoot
    $e5ManifestPath = Join-Path $taskE5Dir 'skill-manifest.json'
    $e5ManifestText = Read-FileUtf8 -Path $e5ManifestPath
    $e5Manifest = if ([string]::IsNullOrWhiteSpace($e5ManifestText)) { $null } else { $e5ManifestText | ConvertFrom-Json }
    $e5CommandNames = @()
    $e5EntryRouterCommand = $null
    if ($null -ne $e5Manifest) {
        $e5CommandNames = @($e5Manifest.available_commands | ForEach-Object { $_.name })
        $e5EntryRouterCommand = @($e5Manifest.available_commands | Where-Object { $_.name -eq 'entry-router' } | Select-Object -First 1)
    }
    if ($e5Result.ExitCode -eq 0 -and
        $e5Result.StdOut -eq 'PLAN | codex' -and
        $null -ne $e5Manifest -and
        $e5Manifest.stage -eq 'PLAN' -and
        $e5CommandNames -contains 'plan' -and
        $e5CommandNames -contains 'entry-router' -and
        $e5CommandNames -notcontains 'using-superpowers' -and
        $null -ne $e5EntryRouterCommand -and
        ([string]$e5EntryRouterCommand.description) -match 'Canonical entry router') {
        Add-Check 'E5 entry-router is discovered in default PLAN skill manifest'
    } else {
        Add-Failure ("E5 entry-router manifest discoverability failed, got stdout=[{0}] stderr=[{1}] manifest=[{2}]" -f $e5Result.StdOut, $e5Result.StdErr, $e5ManifestText)
    }

    $taskE6 = 'skill-manifest-e6-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskE6Dir = Join-Path (Join-Path $fixtureRoot 'docs\tasks') $taskE6
    New-Item -ItemType Directory -Path $taskE6Dir -Force | Out-Null
    $e6OutputPath = Join-Path $taskE6Dir 'skills-index.md'
    $e6Output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixtureRoot 'scripts\generate-skills-index.ps1') -TaskId $taskE6 -Stage 'PLAN' -BackendHint 'codex' -OutputPath $e6OutputPath 2>&1 | ForEach-Object { [string]$_ })
    $e6ExitCode = $LASTEXITCODE
    $e6IndexText = Read-FileUtf8 -Path $e6OutputPath
    if ($e6ExitCode -eq 0 -and
        $e6IndexText -match '# Skills available at PLAN \(backend hint: codex\)' -and
        $e6IndexText -match '\*\*plan\*\*' -and
        $e6IndexText -match '\*\*entry-router\*\*' -and
        $e6IndexText -match 'Canonical entry router' -and
        $e6IndexText -notmatch 'using-superpowers') {
        Add-Check 'E6 generate-skills-index uses entry-router for default PLAN commands'
    } else {
        Add-Failure ("E6 PLAN skills-index should use entry-router, got exit={0} output=[{1}] index=[{2}]" -f $e6ExitCode, ($e6Output -join ' | '), $e6IndexText)
    }
} finally {
    foreach ($path in $cleanupPaths) {
        Remove-DirectoryWithRetry -Path $path
    }
}

Write-Output 'Checks:'
foreach ($check in $script:Checks) {
    Write-Output ('- {0}' -f $check)
}
Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($failure in $script:Failures) {
        Write-Output ('- {0}' -f $failure)
    }
    exit 1
}
