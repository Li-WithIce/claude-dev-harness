[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [System.Collections.Generic.List[string]]::new()
$script:failures = [System.Collections.Generic.List[string]]::new()
function Add-Check { param([string]$Message) $script:checks.Add($Message) }
function Add-Failure { param([string]$Message) $script:failures.Add($Message) }
function Assert-True {
    param([bool]$Condition, [string]$Success, [string]$Failure)
    if ($Condition) { Add-Check $Success } else { Add-Failure $Failure }
}

function Get-TreeSnapshot {
    param([string]$Root, [switch]$ExcludeGit)

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $rootPath -Recurse -Force) {
        $relative = $item.FullName.Substring($rootPath.Length).TrimStart('\','/') -replace '\\','/'
        if ($ExcludeGit -and ($relative -ceq '.git' -or $relative.StartsWith('.git/', [System.StringComparison]::Ordinal))) { continue }
        if ($item.PSIsContainer) {
            $entries.Add("D|$relative")
        } else {
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $entries.Add("F|$relative|$($item.Length)|$hash")
        }
    }
    return @($entries | Sort-Object)
}

function Invoke-Inspect {
    param([string]$TaskScript, [string]$RequestFile, [string]$WorkspaceRoot)

    $arguments = @('inspect','-RequestFile',$RequestFile,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$WorkspaceRoot,'-AsJson')
    $started = Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $TaskScript -Arguments $arguments
    $exited = $started.Process.WaitForExit(30000)
    if (-not $exited) {
        $started.Process.Kill($true)
        [void]$started.Process.WaitForExit(5000)
    }
    $stdout = $started.StdOut.GetAwaiter().GetResult().TrimEnd("`r", "`n")
    $stderr = $started.StdErr.GetAwaiter().GetResult().TrimEnd("`r", "`n")
    $exitCode = if ($started.Process.HasExited) { $started.Process.ExitCode } else { -1 }
    $started.Process.Dispose()
    $json = $null
    try { $json = $stdout | ConvertFrom-Json -AsHashtable -Depth 50 -ErrorAction Stop } catch {}
    return [pscustomobject]@{ Exited=$exited; ExitCode=$exitCode; StdOut=$stdout; StdErr=$stderr; Json=$json }
}

function Write-Json {
    param([string]$Path, [System.Collections.IDictionary]$Value)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
}

$taskScript = Join-Path $RepoRoot 'scripts\task.ps1'
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-v2-pr03-zero-write-' + [guid]::NewGuid().ToString('N'))
$statusBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
$repoBefore = Get-TreeSnapshot -Root $RepoRoot -ExcludeGit

try {
    foreach ($relativeDirectory in @('evidence','.assistant\运行时','docs\tasks\legacy-task')) {
        New-Item -ItemType Directory -Path (Join-Path $scratchRoot $relativeDirectory) -Force | Out-Null
    }
    [System.IO.File]::WriteAllText((Join-Path $scratchRoot 'evidence\policy.txt'), "admin-only`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $scratchRoot '.assistant\运行时\当前任务.md'), "legacy sentinel`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $scratchRoot 'docs\tasks\legacy-task\plan.md'), "legacy plan sentinel`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $scratchRoot 'task.json'), '{"legacy":true}', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $scratchRoot 'current.json'), '{"legacy":true}', (New-Object System.Text.UTF8Encoding($false)))

    $base = [ordered]@{
        task_id='zero-write-inspect'
        goal='Inspect without mutating workspace or repository state.'
        acceptance=@('No file changes occur.')
        in_scope=@('Requirement analysis only')
        out_of_scope=@('Task creation','Runtime writes')
        product_constraints=@('Existing v1 state remains untouched.')
        source_authority=@('current-user-message')
        decisions=@()
        repo_checks=@([ordered]@{ id='policy'; path='evidence/policy.txt'; contains='admin-only' })
        ask=[ordered]@{ style='dependency-aware'; max_independent_questions_per_turn=5 }
    }
    $clear = [ordered]@{}; foreach ($key in $base.Keys) { $clear[$key] = $base[$key] }
    $clear.decisions = @([ordered]@{
        key='roles'; category='authorization_semantics'; question='Which roles may act?'; impact='Changes authorization.'
        options=@('admin-only'); recommended='admin-only'; depends_on=@()
        sources=@([ordered]@{ authority='current-user-message'; source_id='message-1'; value='admin-only' })
    })
    $blocked = [ordered]@{}; foreach ($key in $base.Keys) { $blocked[$key] = $base[$key] }
    $blocked.decisions = @([ordered]@{
        key='retention'; category='data_retention_and_deletion'; question='How long is data retained?'; impact='Changes retention and deletion.'
        options=@('30-days','90-days'); recommended='90-days'; depends_on=@(); sources=@()
    })
    $clearPath = Join-Path $scratchRoot 'clear.json'; Write-Json -Path $clearPath -Value $clear
    $blockedPath = Join-Path $scratchRoot 'blocked.json'; Write-Json -Path $blockedPath -Value $blocked

    $workspaceBefore = Get-TreeSnapshot -Root $scratchRoot
    $clearRun = Invoke-Inspect -TaskScript $taskScript -RequestFile $clearPath -WorkspaceRoot $scratchRoot
    $blockedRun = Invoke-Inspect -TaskScript $taskScript -RequestFile $blockedPath -WorkspaceRoot $scratchRoot
    $workspaceAfter = Get-TreeSnapshot -Root $scratchRoot

    Assert-True -Condition ($clearRun.Exited -and $clearRun.ExitCode -eq 0 -and [string]::IsNullOrEmpty($clearRun.StdErr) -and $null -ne $clearRun.Json -and [string]$clearRun.Json.requirement_state -ceq 'clear') -Success 'clear Inspect completes read-only with exit 0' -Failure ("clear Inspect failed: exit={0} stderr=[{1}]" -f $clearRun.ExitCode,$clearRun.StdErr)
    Assert-True -Condition ($blockedRun.Exited -and $blockedRun.ExitCode -eq 0 -and [string]::IsNullOrEmpty($blockedRun.StdErr) -and $null -ne $blockedRun.Json -and [string]$blockedRun.Json.requirement_state -ceq 'blocked') -Success 'blocked Inspect completes read-only with exit 0' -Failure ("blocked Inspect failed: exit={0} stderr=[{1}]" -f $blockedRun.ExitCode,$blockedRun.StdErr)
    foreach ($run in @($clearRun,$blockedRun)) {
        if ($null -eq $run.Json) { continue }
        Assert-True -Condition ($run.Json.side_effects.task_state_writes -eq 0 -and $run.Json.side_effects.runtime_writes -eq 0 -and $run.Json.side_effects.artifact_writes -eq 0 -and $run.Json.side_effects.external_writes -eq 0) -Success ("{0} result declares zero side effects" -f $run.Json.requirement_state) -Failure ("{0} result reported a side effect" -f $run.Json.requirement_state)
    }
    Assert-True -Condition (@(Compare-Object $workspaceBefore $workspaceAfter -SyncWindow 0).Count -eq 0) -Success 'Inspect leaves every workspace file and directory byte-identical' -Failure 'Inspect created, removed, or changed workspace content'
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $scratchRoot '.assistant\运行时\当前任务.md') -Raw -Encoding utf8) -ceq "legacy sentinel`n") -Success 'Inspect preserves existing runtime pointer content' -Failure 'Inspect changed existing runtime pointer content'
    Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $scratchRoot 'docs\tasks\legacy-task\plan.md') -Raw -Encoding utf8) -ceq "legacy plan sentinel`n") -Success 'Inspect preserves existing v1 task artifacts' -Failure 'Inspect changed existing v1 task artifacts'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $scratchRoot 'docs\tasks\zero-write-inspect'))) -Success 'Inspect creates no task artifact directory' -Failure 'Inspect created a task artifact directory'
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

$repoAfter = Get-TreeSnapshot -Root $RepoRoot -ExcludeGit
$statusAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Assert-True -Condition (@(Compare-Object $repoBefore $repoAfter -SyncWindow 0).Count -eq 0) -Success 'Inspect leaves every non-git repository path byte-identical' -Failure 'Inspect changed repository content, including ignored paths'
Assert-True -Condition (@(Compare-Object $statusBefore $statusAfter).Count -eq 0) -Success 'Inspect leaves Git worktree status unchanged' -Failure 'Inspect changed Git worktree status'

foreach ($check in $script:checks) { Write-Output ("[PASS] {0}" -f $check) }
foreach ($failure in $script:failures) { Write-Output ("[FAIL] {0}" -f $failure) }
if ($script:failures.Count -gt 0) {
    Write-Output ("STATUS: FAIL ({0} failed)" -f $script:failures.Count)
    exit 1
}
Write-Output ("STATUS: PASS ({0} checks)" -f $script:checks.Count)
exit 0
