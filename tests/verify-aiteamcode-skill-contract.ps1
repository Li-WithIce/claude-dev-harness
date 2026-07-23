[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)
    $script:Failures += $Message
}

function New-IsolatedRepoFixture {
    param([string]$SourceRoot)

    $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-skill-contract-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'docs\tasks') -Force | Out-Null
    foreach ($relativePath in @(
        'scripts\advance-stage.ps1',
        'scripts\invoke-harness-skill.ps1',
        'scripts\invoke-harness-skill-dispatcher.ps1',
        'scripts\invoke-harness-skill-supervisor.ps1',
        'scripts\generate-skills-index.ps1',
        'scripts\lite-artifact-parser.ps1',
        'scripts\validate-lite-artifacts.ps1',
        'skills\obsidian-memory\scripts\resolve-shared-memory-paths.ps1',
        'skills\obsidian-memory\scripts\runtime-inbox-common.ps1',
        'skills\obsidian-memory\scripts\runtime-state-common.ps1',
        'agent-configs\profiles',
        'agent-configs\workflows',
        'skills\entry-router',
        'skills\plan',
        'skills\review',
        'skills\test'
    )) {
        Copy-RepoPathToFixture -SourceRoot $SourceRoot -FixtureRoot $fixtureRoot -RelativePath $relativePath
    }

    return $fixtureRoot
}

function New-PlanContent {
    param(
        [string]$TaskId,
        [string]$Stage = 'PLAN_REVIEW',
        [string]$Tool = 'codex',
        [switch]$IncludePlanReviewRun,
        [switch]$IncludeCodeReviewRun,
        [string[]]$ExtraFrontmatter = @()
    )

    $updatedDate = Get-Date -Format 'yyyy-MM-dd'
    $extra = if ($ExtraFrontmatter.Count -gt 0) {
        ($ExtraFrontmatter -join "`r`n") + "`r`n"
    } else {
        ""
    }

    $planReviewBlock = if ($IncludePlanReviewRun) {
@"
### Run 1 · 2026-04-25 10:00 · runner: harness-reviewer
- verdict: pass
- findings: none
- next: none
"@
    } else {
        ""
    }

    $implementationBlock = if ($IncludeCodeReviewRun) {
@"
### Run 1 · 2026-04-25 10:03 · runner: harness-implementer
- changed: adapter fixture implementation
- tests: targeted
- risks: none
- next: CODE_REVIEW
"@
    } else {
        ""
    }

    $codeReviewBlock = if ($IncludeCodeReviewRun) {
@"
### Run 1 · 2026-04-25 10:05 · runner: harness-reviewer
- verdict: pass
- findings: none
- next: none
"@
    } else {
        ""
    }

@"
---
task_id: $TaskId
stage: $Stage
tool: $Tool
${extra}updated: $updatedDate
---
# Skill Contract Fixture

## Clarification
- 验收标准: adapter output stays machine-readable.
- 非目标: no team preset bridge.
- 受影响目录: scripts/, tests/, skills/, agent-configs/
- 回滚策略: remove Phase 3 adapter artifacts.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- Add ACP-style skill adapter coverage.

## Verification
- ``pwsh -File tests/verify-aiteamcode-skill-contract.ps1``

## Risks
- none

## Plan Review
$planReviewBlock

## Implementation Notes
$implementationBlock

## Code Review
$codeReviewBlock

"@
}

function New-TaskWorkspace {
    param(
        [string]$TaskId,
        [string]$PlanContent,
        [string]$Label
    )

    $workspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("skill-contract-workspace-{0}-{1}" -f $Label, [guid]::NewGuid().ToString('N'))
    $taskDirectory = Join-Path $workspaceRoot ("docs\tasks\{0}" -f $TaskId)
    New-Item -ItemType Directory -Path $taskDirectory -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskDirectory 'plan.md') -Content $PlanContent
    return [pscustomobject]@{
        WorkspaceRoot = $workspaceRoot
        TaskDirectory = $taskDirectory
    }
}

function Invoke-PowerShellWithStreams {
    param([string[]]$Arguments)

    $streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-skill-contract-streams-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $streamRoot -Force | Out-Null
    $stdoutPath = Join-Path $streamRoot 'stdout.txt'
    $stderrPath = Join-Path $streamRoot 'stderr.txt'

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [System.IO.File]::ReadAllText($stdoutPath) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath) } else { '' }
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }
        $stdout = $stdout.Trim()
        $stderr = $stderr.Trim()
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

function Start-PowerShellWithStreams {
    param([string]$ScriptPath)

    $streamRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-skill-contract-streams-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $streamRoot -Force | Out-Null
    $stdoutPath = Join-Path $streamRoot 'stdout.txt'
    $stderrPath = Join-Path $streamRoot 'stderr.txt'
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-File', $ScriptPath
    ) -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    return [pscustomobject]@{
        Process = $process
        StreamRoot = $streamRoot
        StdOutPath = $stdoutPath
        StdErrPath = $stderrPath
    }
}

function Complete-PowerShellWithStreams {
    param(
        [object]$Capture,
        [int]$TimeoutMilliseconds = 10000
    )

    $completed = $Capture.Process.WaitForExit($TimeoutMilliseconds)
    if (-not $completed) {
        Stop-Process -Id $Capture.Process.Id -Force -ErrorAction SilentlyContinue
        $Capture.Process.WaitForExit()
    } else {
        $Capture.Process.WaitForExit()
    }

    $stdout = if (Test-Path -LiteralPath $Capture.StdOutPath -PathType Leaf) { [System.IO.File]::ReadAllText($Capture.StdOutPath).Trim() } else { '' }
    $stderr = if (Test-Path -LiteralPath $Capture.StdErrPath -PathType Leaf) { [System.IO.File]::ReadAllText($Capture.StdErrPath).Trim() } else { '' }
    $exitCode = if ($completed) { $Capture.Process.ExitCode } else { -1 }
    $Capture.Process.Dispose()

    return [pscustomobject]@{
        Completed = $completed
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Start-LifecyclePowerShell {
    param(
        [string]$HostPath,
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $HostPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $ScriptPath) + @($Arguments)) {
        $psi.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()
    return [pscustomobject]@{
        Process = $process
        StdOut = $process.StandardOutput.ReadToEndAsync()
        StdErr = $process.StandardError.ReadToEndAsync()
        Timer = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Complete-LifecyclePowerShell {
    param(
        [object]$Capture,
        [string]$Label,
        [int]$TimeoutMilliseconds = 10000
    )

    $outerTimedOut = $false
    $exitCode = -1
    $stdout = ''
    $stderr = ''
    try {
        if (-not $Capture.Process.WaitForExit($TimeoutMilliseconds)) {
            $outerTimedOut = $true
            try { $Capture.Process.Kill($true) } catch { Add-Failure "$Label watchdog tree kill failed: $($_.Exception.Message)" }
            try {
                if (-not $Capture.Process.WaitForExit(5000)) { Add-Failure "$Label watchdog root wait timed out" }
            } catch { Add-Failure "$Label watchdog root wait failed: $($_.Exception.Message)" }
        }
        if ($Capture.Process.HasExited) { $exitCode = $Capture.Process.ExitCode }
        $drain = [System.Threading.Tasks.Task]::WhenAll([System.Threading.Tasks.Task[]]@($Capture.StdOut, $Capture.StdErr))
        if (-not $drain.Wait(5000)) {
            Add-Failure "$Label watchdog stream drain timed out"
        } else {
            $stdout = $Capture.StdOut.GetAwaiter().GetResult()
            $stderr = $Capture.StdErr.GetAwaiter().GetResult()
        }
    } catch {
        Add-Failure "$Label watchdog failed: $($_.Exception.Message)"
    } finally {
        $Capture.Timer.Stop()
        try {
            if (-not $Capture.Process.HasExited) {
                $Capture.Process.Kill($true)
                if (-not $Capture.Process.WaitForExit(5000)) { Add-Failure "$Label final watchdog cleanup timed out" }
            }
        } catch [System.InvalidOperationException] {
        } catch {
            Add-Failure "$Label final watchdog cleanup failed: $($_.Exception.Message)"
        }
        $Capture.Process.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        OuterTimedOut = $outerTimedOut
        StdOut = $stdout.Trim()
        StdErr = $stderr.Trim()
        DurationMilliseconds = $Capture.Timer.ElapsedMilliseconds
    }
}

function New-AbandonedNamedMutex {
    param(
        [string]$HostPath,
        [string]$FixturePath,
        [string]$MutexName,
        [string]$Label
    )

    $keeper = [System.Threading.Mutex]::new($false, $MutexName)
    $readyEventName = 'dev-harness.skill-contract.mutex-ready.' + [guid]::NewGuid().ToString('N')
    $createdNew = $false
    $readyEvent = [System.Threading.EventWaitHandle]::new(
        $false,
        [System.Threading.EventResetMode]::ManualReset,
        $readyEventName,
        [ref]$createdNew
    )
    $capture = $null

    try {
        if (-not $createdNew) {
            throw "$Label readiness event already existed"
        }

        $capture = Start-LifecyclePowerShell -HostPath $HostPath -ScriptPath $FixturePath -Arguments @(
            '-MutexName', $MutexName,
            '-ReadyEventName', $readyEventName
        )
        if (-not $readyEvent.WaitOne(5000)) {
            try { $capture.Process.Kill() } catch [System.InvalidOperationException] {}
            $failedResult = Complete-LifecyclePowerShell -Capture $capture -Label $Label -TimeoutMilliseconds 5000
            $capture = $null
            throw "$Label did not acquire the named mutex: exit=$($failedResult.ExitCode) stderr=[$($failedResult.StdErr)]"
        }

        $capture.Process.Kill()
        $result = Complete-LifecyclePowerShell -Capture $capture -Label $Label -TimeoutMilliseconds 5000
        $capture = $null
        if ($result.OuterTimedOut) {
            throw "$Label did not terminate after acquiring the named mutex"
        }

        return $keeper
    } catch {
        $keeper.Dispose()
        throw
    } finally {
        if ($null -ne $capture) {
            try { $capture.Process.Kill() } catch [System.InvalidOperationException] {}
            $null = Complete-LifecyclePowerShell -Capture $capture -Label "$Label cleanup" -TimeoutMilliseconds 5000
        }
        $readyEvent.Dispose()
    }
}

function Read-LifecycleIdentity {
    param(
        [string]$Path,
        [int]$TimeoutMilliseconds = 5000,
        [string[]]$RequiredProperties = @('token', 'root_pid', 'root_start_ticks', 'child_pid', 'child_start_ticks')
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $identity = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
                $complete = $true
                foreach ($property in $RequiredProperties) {
                    if ($null -eq $identity.PSObject.Properties[$property]) { $complete = $false; break }
                }
                if ($complete) { return $identity }
            } catch {
            }
        }
        Start-Sleep -Milliseconds 25
    }
    return $null
}

function New-DispatchRequestFile {
    param([object[]]$Parameters = @())

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-harness-skill-request-' + [guid]::NewGuid().ToString('N') + '.json')
    $document = [ordered]@{
        schema_version = 'invoke-harness-skill-dispatch/v1'
        parameters = @($Parameters)
    }
    [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 6 -Compress), [System.Text.UTF8Encoding]::new($false))
    return $path
}

function New-RawDispatchRequestFile {
    param([Parameter(Mandatory = $true)][string]$Json)

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-harness-skill-request-' + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllText($path, $Json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Get-DispatchRequestResidue {
    param([string]$Token)

    return @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'invoke-harness-skill-request-*.json' -File -Force -ErrorAction SilentlyContinue | Where-Object {
            try { [System.IO.File]::ReadAllText($_.FullName).Contains($Token) } catch { $false }
        })
}

function Test-LifecycleProcessAlive {
    param([int]$ProcessId, [long]$StartTicks)

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        return $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks
    } catch [System.InvalidOperationException] {
        return $false
    } finally {
        $process.Dispose()
    }
}

function Stop-LifecycleProcess {
    param([int]$ProcessId, [long]$StartTicks, [string]$Label)

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return }
    try {
        if ($process.StartTime.ToUniversalTime().Ticks -eq $StartTicks) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) { Add-Failure "$Label cleanup timed out" }
        }
    } catch [System.InvalidOperationException] {
    } catch {
        Add-Failure "$Label cleanup failed: $($_.Exception.Message)"
    } finally {
        $process.Dispose()
    }
}

function Invoke-Adapter {
    param(
        [string]$AdapterPath,
        [string]$TaskId,
        [string]$Stage,
        [string]$Skill,
        [string]$Tool,
        [string]$ToolProfileId = '',
        [string]$WorkspaceRoot,
        [string]$Mode = 'readonly',
        [string]$PayloadJson = '{}'
    )

    $arguments = @(
        '-TaskId', $TaskId,
        '-Stage', $Stage,
        '-Skill', $Skill,
        '-Tool', $Tool
    )
    if (-not [string]::IsNullOrWhiteSpace($ToolProfileId)) {
        $arguments += @('-ToolProfileId', $ToolProfileId)
    }
    $arguments += @(
        '-WorkspaceRoot', $WorkspaceRoot,
        '-Mode', $Mode,
        '-PayloadJson', $PayloadJson
    )

    $hostPath = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
    $capture = Start-LifecyclePowerShell -HostPath $hostPath -ScriptPath $AdapterPath -Arguments $arguments
    $result = Complete-LifecyclePowerShell -Capture $capture -Label 'Invoke-Adapter' -TimeoutMilliseconds 1830000
    $combined = @($result.StdOut, $result.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        StdOut = $result.StdOut
        StdErr = $result.StdErr
        Combined = ($combined -join "`n")
    }
}

function Invoke-Validator {
    param(
        [string]$ValidatorPath,
        [string]$TaskId,
        [string]$RepoRoot
    )

    $output = @(& powershell.exe -NoProfile -File $ValidatorPath -TaskId $TaskId -RepoRoot $RepoRoot 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text = ($output -join "`n")
    }
}

function Invoke-GenerateSkillsIndex {
    param(
        [string]$ScriptPath,
        [string]$TaskId,
        [string]$Stage,
        [string]$BackendHint,
        [string]$RepoRoot
    )

    Push-Location $RepoRoot
    try {
        $output = @(& powershell.exe -NoProfile -File $ScriptPath -TaskId $TaskId -Stage $Stage -BackendHint $BackendHint 2>&1 | ForEach-Object { [string]$_ })
    } finally {
        Pop-Location
    }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
        Text = ($output -join "`n")
    }
}

function Write-MockCodexSkill {
    param(
        [string]$SkillRoot,
        [string]$Marker
    )

    $scriptPath = Join-Path $SkillRoot 'codex\scripts\invoke_codex.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $scriptPath) -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path (Split-Path -Parent $scriptPath) 'lifecycle-descendant.ps1') -Content @'
[CmdletBinding()]
param(
    [string]$MarkerPath,
    [string]$Token
)

Start-Sleep -Milliseconds 4000
[System.IO.File]::WriteAllText($MarkerPath, $Token, [System.Text.UTF8Encoding]::new($false))
Start-Sleep -Milliseconds 4000
'@
    Write-Utf8Bom -Path $scriptPath -Content @"
[CmdletBinding()]
param(
    [string]`$Task,
    [string]`$Workspace,
    [string[]]`$File,
    [string]`$Session,
    [string]`$Model,
    [string]`$Reasoning = 'medium',
    [switch]`$ReadOnly,
    [string]`$Output,
    [int]`$TimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$utf8 = [System.Text.UTF8Encoding]::new(`$false)
`$callerDispatcher = [string]`$MyInvocation.ScriptName
`$lifecycleParts = @(`$Task -split '::')
if (`$lifecycleParts.Count -eq 4 -and `$lifecycleParts[0] -ceq 'outer-natural') {
    if ([string]::IsNullOrWhiteSpace(`$callerDispatcher) -or
        -not (Test-Path -LiteralPath `$callerDispatcher -PathType Leaf) -or
        (Split-Path -Leaf `$callerDispatcher) -cne 'invoke-harness-skill-dispatcher.ps1') {
        throw 'target was not entered through the tracked dispatcher'
    }
    `$self = Get-Process -Id `$PID
    try { `$selfStartTicks = `$self.StartTime.ToUniversalTime().Ticks } finally { `$self.Dispose() }
    `$childPsi = [System.Diagnostics.ProcessStartInfo]::new()
    `$childPsi.FileName = (Get-Process -Id `$PID).Path
    `$childPsi.UseShellExecute = `$false
    foreach (`$argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path `$PSScriptRoot 'lifecycle-descendant.ps1'), '-MarkerPath', `$lifecycleParts[2], '-Token', `$lifecycleParts[3])) {
        `$childPsi.ArgumentList.Add([string]`$argument)
    }
    `$child = [System.Diagnostics.Process]::Start(`$childPsi)
    try {
        `$lifecycleIdentity = [ordered]@{
            token = `$lifecycleParts[3]
            root_pid = `$PID
            root_start_ticks = `$selfStartTicks
            child_pid = `$child.Id
            child_start_ticks = `$child.StartTime.ToUniversalTime().Ticks
            dispatcher_path = `$callerDispatcher
            dispatcher_tracked = `$true
            backend_output = `$Output
        }
        [System.IO.File]::WriteAllText(`$lifecycleParts[1], (`$lifecycleIdentity | ConvertTo-Json -Compress), `$utf8)
    } finally {
        `$child.Dispose()
    }
}
if (`$lifecycleParts.Count -eq 6 -and `$lifecycleParts[0] -ceq 'outer-abort') {
    if ([string]::IsNullOrWhiteSpace(`$callerDispatcher) -or
        -not (Test-Path -LiteralPath `$callerDispatcher -PathType Leaf) -or
        (Split-Path -Leaf `$callerDispatcher) -cne 'invoke-harness-skill-dispatcher.ps1') {
        throw 'target was not entered through the tracked dispatcher'
    }
    `$self = Get-Process -Id `$PID
    `$parent = `$null
    try {
        `$selfStartTicks = `$self.StartTime.ToUniversalTime().Ticks
        `$parent = `$self.Parent
        `$supervisorPid = `$parent.Id
        `$supervisorStartTicks = `$parent.StartTime.ToUniversalTime().Ticks
    } finally {
        if (`$null -ne `$parent) { `$parent.Dispose() }
        `$self.Dispose()
    }
    [System.IO.File]::WriteAllText(`$Output, ('sensitive-abort-output-' + `$lifecycleParts[5]), `$utf8)
    `$identity = [ordered]@{
        token = `$lifecycleParts[5]
        root_pid = `$PID
        root_start_ticks = `$selfStartTicks
        supervisor_pid = `$supervisorPid
        supervisor_start_ticks = `$supervisorStartTicks
        child_pid = 0
        child_start_ticks = 0
        dispatcher_path = `$callerDispatcher
        dispatcher_tracked = `$true
        backend_output = `$Output
    }
    [System.IO.File]::WriteAllText(`$lifecycleParts[1], (`$identity | ConvertTo-Json -Compress), `$utf8)
    `$readyEvent = [System.Threading.EventWaitHandle]::OpenExisting(`$lifecycleParts[2])
    `$releaseEvent = [System.Threading.EventWaitHandle]::OpenExisting(`$lifecycleParts[3])
    try {
        `$readyEvent.Set() | Out-Null
        if (-not `$releaseEvent.WaitOne(15000)) { throw 'outer abort mock release timed out' }
    } finally {
        `$readyEvent.Dispose()
        `$releaseEvent.Dispose()
    }
    `$childPsi = [System.Diagnostics.ProcessStartInfo]::new()
    `$childPsi.FileName = (Get-Process -Id `$PID).Path
    `$childPsi.UseShellExecute = `$false
    foreach (`$argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path `$PSScriptRoot 'lifecycle-descendant.ps1'), '-MarkerPath', `$lifecycleParts[4], '-Token', `$lifecycleParts[5])) {
        `$childPsi.ArgumentList.Add([string]`$argument)
    }
    `$child = [System.Diagnostics.Process]::Start(`$childPsi)
    try {
        `$identity.child_pid = `$child.Id
        `$identity.child_start_ticks = `$child.StartTime.ToUniversalTime().Ticks
        [System.IO.File]::WriteAllText(`$lifecycleParts[1], (`$identity | ConvertTo-Json -Compress), `$utf8)
    } finally {
        `$child.Dispose()
    }
    Write-Output 'outer abort target exited with code 7'
    exit 7
}
`$record = [ordered]@{
    marker = '$Marker'
    task = `$Task
    workspace = `$Workspace
    file = @(`$File)
    session = `$Session
    model = `$Model
    reasoning = `$Reasoning
    read_only = `$ReadOnly.IsPresent
    output = `$Output
    timeout_seconds = `$TimeoutSeconds
    host_major = `$PSVersionTable.PSVersion.Major
    host_version = `$PSVersionTable.PSVersion.ToString()
    caller_dispatcher = `$callerDispatcher
    dispatcher_tracked = (-not [string]::IsNullOrWhiteSpace(`$callerDispatcher) -and
        (Test-Path -LiteralPath `$callerDispatcher -PathType Leaf) -and
        (Split-Path -Leaf `$callerDispatcher) -ceq 'invoke-harness-skill-dispatcher.ps1')
    frame_probe = if (`$lifecycleParts.Count -eq 4 -and `$lifecycleParts[0] -ceq 'outer-natural') {
        `$builder = [System.Text.StringBuilder]::new(131072)
        for (`$i = 0; `$i -lt 16384; `$i++) { [void]`$builder.Append(('{0:X8}' -f ((`$i * 2654435761L) % 4294967296L))) }
        `$builder.ToString()
    } else { '' }
}
if (`$Task.StartsWith('barrier=')) {
    `$barrierNames = @(`$Task.Substring(8) -split '\|', 2)
    `$readyEvent = [System.Threading.EventWaitHandle]::OpenExisting(`$barrierNames[0])
    `$releaseEvent = [System.Threading.EventWaitHandle]::OpenExisting(`$barrierNames[1])
    try {
        `$readyEvent.Set() | Out-Null
        if (-not `$releaseEvent.WaitOne(15000)) {
            throw 'mock backend barrier timed out'
        }
    } finally {
        `$readyEvent.Dispose()
        `$releaseEvent.Dispose()
    }
}
if (`$Task -ceq 'direct-exit-124') {
    Write-Output ('mock target failed backend_temp={0}' -f `$Output)
    exit 124
}
[System.IO.File]::WriteAllText(`$Output, ((`$record | ConvertTo-Json -Depth 5 -Compress)), `$utf8)
Write-Output 'session_id=mock-session'
Write-Output ('output_path={0}' -f `$Output)
if (`$Task -ceq 'partial-output-exit-7') {
    Write-Output ('backend_temp={0}' -f `$Output)
    exit 7
}
"@
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$mutexAbandonFixturePath = Join-Path $RepoRoot 'tests\fixtures\aiteamcode-skill-contract-abandon-mutex.ps1'
if (-not (Test-Path -LiteralPath $mutexAbandonFixturePath -PathType Leaf)) {
    throw "Missing mutex-abandon fixture: $mutexAbandonFixturePath"
}
$fixtureRoot = New-IsolatedRepoFixture -SourceRoot $RepoRoot
$advancePath = Join-Path $fixtureRoot 'scripts\advance-stage.ps1'
$adapterPath = Join-Path $fixtureRoot 'scripts\invoke-harness-skill.ps1'
$dispatcherPath = Join-Path $fixtureRoot 'scripts\invoke-harness-skill-dispatcher.ps1'
$supervisorPath = Join-Path $fixtureRoot 'scripts\invoke-harness-skill-supervisor.ps1'
$liteParserPath = Join-Path $fixtureRoot 'scripts\lite-artifact-parser.ps1'
$validatorPath = Join-Path $fixtureRoot 'scripts\validate-lite-artifacts.ps1'
$skillsIndexPath = Join-Path $fixtureRoot 'scripts\generate-skills-index.ps1'
$taskBase = Join-Path $fixtureRoot 'docs\tasks'
$script:Checks = @()
$script:Failures = @()
$cleanupPaths = @($fixtureRoot)
$cleanupIdentities = [System.Collections.Generic.List[object]]::new()
$lifecycleAssertionsPassed = $false
$originalUserProfile = $env:USERPROFILE
$adapterText = Read-FileUtf8 -Path $adapterPath
$dispatcherText = Read-FileUtf8 -Path $dispatcherPath
$supervisorText = Read-FileUtf8 -Path $supervisorPath
if ($adapterText -notmatch 'invoke-harness-skill-wrapper-' -and
    $adapterText -notmatch 'ConvertTo-PowerShellLiteral' -and
    ($adapterText + $supervisorText + $dispatcherText) -notmatch 'ExecutionPolicy|CreateNoWindow|EncodedCommand|Invoke-Expression|ScriptBlock\]::Create' -and
    $adapterText -match 'invoke-harness-skill-request-' -and $adapterText -match '-RequestPath \$requestPath' -and
    $dispatcherText -match 'System\.Text\.Json\.JsonDocument.*::Parse' -and
    $dispatcherText -match 'Assert-RawJsonObjectKeys' -and $dispatcherText -match 'StringComparer\]::Ordinal' -and
    $dispatcherText -match 'ConvertFrom-Json -AsHashtable' -and $dispatcherText -match 'invoke-harness-skill-dispatch/v1' -and
    $dispatcherText -match '(?s)Delete\(\$resolvedRequestPath\).*& \$resolvedTargetPath @targetParameters' -and
    $supervisorText -match 'Base64 is byte framing.*never evaluated or executed') {
    Add-Check 'tracked dispatcher uses Ordinal raw-key JSON validation and deletes request data before target entry without generated scripts, hidden windows, or executable Base64'
} else {
    Add-Failure 'tracked dispatcher transparency contract is incomplete'
}
try {
    $ownerRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-owner-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += $ownerRoot
    New-Item -ItemType Directory -Path $ownerRoot -Force | Out-Null
    $ownerChildPath = Join-Path $ownerRoot 'descendant.ps1'
    Write-Utf8Bom -Path $ownerChildPath -Content @'
[CmdletBinding()]
param([string]$MarkerPath, [string]$Token)
Start-Sleep -Milliseconds 4000
[System.IO.File]::WriteAllText($MarkerPath, $Token, [System.Text.UTF8Encoding]::new($false))
Start-Sleep -Milliseconds 4000
'@
    $ownerHost = (Get-Command pwsh -CommandType Application -ErrorAction Stop).Source
    foreach ($ownerCase in @(
            [pscustomobject]@{ Name = 'natural'; TimeoutSeconds = 10; RootSleep = '$null'; ExpectedExit = 0; OutputCount = 768 }
            [pscustomobject]@{ Name = 'timeout'; TimeoutSeconds = 2; RootSleep = 'Start-Sleep -Seconds 30'; ExpectedExit = 124; OutputCount = 8 }
        )) {
        $caseRoot = Join-Path $ownerRoot $ownerCase.Name
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $identityPath = Join-Path $caseRoot 'identity.json'
        $markerPath = Join-Path $caseRoot 'late.marker'
        $backendOutputPath = Join-Path $caseRoot 'backend-output.tmp'
        $targetPath = Join-Path $caseRoot 'target.ps1'
        $ownerRequestPath = New-DispatchRequestFile
        $cleanupPaths += $ownerRequestPath
        $token = [guid]::NewGuid().ToString('N')
        $identityLiteral = "'" + $identityPath.Replace("'", "''") + "'"
        $markerLiteral = "'" + $markerPath.Replace("'", "''") + "'"
        $backendOutputLiteral = "'" + $backendOutputPath.Replace("'", "''") + "'"
        $childLiteral = "'" + $ownerChildPath.Replace("'", "''") + "'"
        $tokenLiteral = "'" + $token.Replace("'", "''") + "'"
        Write-Utf8Bom -Path $targetPath -Content @"
`$ErrorActionPreference = 'Stop'
`$utf8 = [System.Text.UTF8Encoding]::new(`$false)
for (`$i = 0; `$i -lt $($ownerCase.OutputCount); `$i++) {
    [Console]::Out.WriteLine(('owner-stdout-{0:D4}-' -f `$i) + ('o' * 160))
    [Console]::Error.WriteLine(('owner-stderr-{0:D4}-' -f `$i) + ('e' * 160))
}
`$self = Get-Process -Id `$PID
try { `$selfTicks = `$self.StartTime.ToUniversalTime().Ticks } finally { `$self.Dispose() }
`$psi = [System.Diagnostics.ProcessStartInfo]::new()
`$psi.FileName = (Get-Process -Id `$PID).Path
`$psi.UseShellExecute = `$false
foreach (`$argument in @('-NoProfile', '-NonInteractive', '-File', $childLiteral, '-MarkerPath', $markerLiteral, '-Token', $tokenLiteral)) { `$psi.ArgumentList.Add([string]`$argument) }
`$child = [System.Diagnostics.Process]::Start(`$psi)
try {
    `$identity = [ordered]@{ token = $tokenLiteral; root_pid = `$PID; root_start_ticks = `$selfTicks; child_pid = `$child.Id; child_start_ticks = `$child.StartTime.ToUniversalTime().Ticks }
    [System.IO.File]::WriteAllText($identityLiteral, (`$identity | ConvertTo-Json -Compress), `$utf8)
} finally { `$child.Dispose() }
[System.IO.File]::WriteAllText($backendOutputLiteral, 'owner-backend-result', `$utf8)
$($ownerCase.RootSleep)
exit 0
"@
        $ownerCapture = Start-LifecyclePowerShell -HostPath $ownerHost -ScriptPath $supervisorPath -Arguments @('-TargetScriptPath', $targetPath, '-RequestPath', $ownerRequestPath, '-OutputPath', $backendOutputPath, '-TimeoutSeconds', [string]$ownerCase.TimeoutSeconds)
        $ownerResult = Complete-LifecyclePowerShell -Capture $ownerCapture -Label ("owner {0}" -f $ownerCase.Name) -TimeoutMilliseconds 10000
        $ownerIdentity = Read-LifecycleIdentity -Path $identityPath
        if ($null -ne $ownerIdentity -and [string]$ownerIdentity.token -ceq $token) {
            $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$ownerIdentity.root_pid; Ticks = [long]$ownerIdentity.root_start_ticks; Label = "owner $($ownerCase.Name) root" })
            $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$ownerIdentity.child_pid; Ticks = [long]$ownerIdentity.child_start_ticks; Label = "owner $($ownerCase.Name) child" })
        }
        $rootAlive = $null -ne $ownerIdentity -and (Test-LifecycleProcessAlive -ProcessId ([int]$ownerIdentity.root_pid) -StartTicks ([long]$ownerIdentity.root_start_ticks))
        $childAlive = $null -ne $ownerIdentity -and (Test-LifecycleProcessAlive -ProcessId ([int]$ownerIdentity.child_pid) -StartTicks ([long]$ownerIdentity.child_start_ticks))
        $ownerExpectedTail = '{0:D4}' -f ($ownerCase.OutputCount - 1)
        if ($ownerResult.ExitCode -eq $ownerCase.ExpectedExit -and
            -not $ownerResult.OuterTimedOut -and
            $null -ne $ownerIdentity -and [string]$ownerIdentity.token -ceq $token -and
            -not $rootAlive -and -not $childAlive -and
            -not (Test-Path -LiteralPath $markerPath) -and -not (Test-Path -LiteralPath $backendOutputPath) -and -not (Test-Path -LiteralPath $ownerRequestPath) -and
            $ownerResult.StdOut -match ('owner-stdout-{0}-' -f $ownerExpectedTail) -and
            $ownerResult.StdErr -match ('owner-stderr-{0}-' -f $ownerExpectedTail)) {
            Add-Check ("owner {0} drains both streams, closes the exact target tree, and preserves bounded exit semantics" -f $ownerCase.Name)
        } else {
            Add-Failure ("owner {0} failed: exit={1} outer_timeout={2} duration_ms={3} root_alive={4} child_alive={5} marker={6} stdout_tail={7} stderr_tail={8}" -f $ownerCase.Name,$ownerResult.ExitCode,$ownerResult.OuterTimedOut,$ownerResult.DurationMilliseconds,$rootAlive,$childAlive,(Test-Path -LiteralPath $markerPath),($ownerResult.StdOut.Substring([Math]::Max(0,$ownerResult.StdOut.Length-120))),($ownerResult.StdErr.Substring([Math]::Max(0,$ownerResult.StdErr.Length-120))))
        }
    }

    $rawGuardRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-dispatch-guard-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $rawGuardRoot -Force | Out-Null
    $cleanupPaths += $rawGuardRoot
    foreach ($rawGuardName in @('top-duplicate', 'entry-duplicate', 'top-case-variant', 'entry-case-variant', 'parameter-name-case-override')) {
        $rawGuardCaseRoot = Join-Path $rawGuardRoot $rawGuardName
        New-Item -ItemType Directory -Path $rawGuardCaseRoot -Force | Out-Null
        $rawGuardTargetPath = Join-Path $rawGuardCaseRoot 'target.ps1'
        $rawGuardMarkerPath = Join-Path $rawGuardCaseRoot 'target-entered.marker'
        $rawGuardOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-dispatch-output-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $rawGuardMarkerLiteral = "'" + $rawGuardMarkerPath.Replace("'", "''") + "'"
        $rawGuardOutputLiteral = "'" + $rawGuardOutputPath.Replace("'", "''") + "'"
        Write-Utf8Bom -Path $rawGuardTargetPath -Content @"
[System.IO.File]::WriteAllText($rawGuardMarkerLiteral, 'entered', [System.Text.UTF8Encoding]::new(`$false))
[System.IO.File]::WriteAllText($rawGuardOutputLiteral, 'unexpected-output', [System.Text.UTF8Encoding]::new(`$false))
exit 0
"@
        $rawGuardOutputJson = $rawGuardOutputPath | ConvertTo-Json -Compress
        $rawGuardValidOutputEntry = '{"name":"Output","kind":"string","value":' + $rawGuardOutputJson + '}'
        $rawGuardJson = switch ($rawGuardName) {
            'top-duplicate' {
                '{"schema_version":"invoke-harness-skill-dispatch/v1","schema_version":"invoke-harness-skill-dispatch/v1","parameters":[' + $rawGuardValidOutputEntry + ']}'
            }
            'entry-duplicate' {
                '{"schema_version":"invoke-harness-skill-dispatch/v1","parameters":[{"name":"Output","name":"Output","kind":"string","value":' + $rawGuardOutputJson + '}]}'
            }
            'top-case-variant' {
                '{"Schema_version":"invoke-harness-skill-dispatch/v1","parameters":[' + $rawGuardValidOutputEntry + ']}'
            }
            'entry-case-variant' {
                '{"schema_version":"invoke-harness-skill-dispatch/v1","parameters":[{"Name":"Output","kind":"string","value":' + $rawGuardOutputJson + '}]}'
            }
            'parameter-name-case-override' {
                '{"schema_version":"invoke-harness-skill-dispatch/v1","parameters":[{"name":"Task","kind":"string","value":"trusted"},{"name":"task","kind":"string","value":"override"},' + $rawGuardValidOutputEntry + ']}'
            }
        }
        $rawGuardRequestPath = New-RawDispatchRequestFile -Json $rawGuardJson
        $cleanupPaths += @($rawGuardRequestPath, $rawGuardOutputPath)
        $rawGuardCapture = Start-LifecyclePowerShell -HostPath $ownerHost -ScriptPath $supervisorPath -Arguments @(
            '-TargetScriptPath', $rawGuardTargetPath,
            '-RequestPath', $rawGuardRequestPath,
            '-OutputPath', $rawGuardOutputPath,
            '-TimeoutSeconds', '10'
        )
        $rawGuardResult = Complete-LifecyclePowerShell -Capture $rawGuardCapture -Label ("dispatcher guard $rawGuardName") -TimeoutMilliseconds 10000
        if ($rawGuardResult.ExitCode -ne 0 -and
            -not $rawGuardResult.OuterTimedOut -and
            -not (Test-Path -LiteralPath $rawGuardMarkerPath) -and
            -not (Test-Path -LiteralPath $rawGuardOutputPath) -and
            -not (Test-Path -LiteralPath $rawGuardRequestPath)) {
            Add-Check ("dispatcher guard {0} is rejected before target entry and supervisor removes request data" -f $rawGuardName)
        } else {
            Add-Failure ("dispatcher guard {0} failed closed contract: exit={1} timeout={2} marker={3} output={4} request={5} stdout=[{6}] stderr=[{7}]" -f $rawGuardName,$rawGuardResult.ExitCode,$rawGuardResult.OuterTimedOut,(Test-Path -LiteralPath $rawGuardMarkerPath),(Test-Path -LiteralPath $rawGuardOutputPath),(Test-Path -LiteralPath $rawGuardRequestPath),$rawGuardResult.StdOut,$rawGuardResult.StdErr)
        }
    }

    $taskA1 = 'skill-contract-a1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA1 = New-TaskWorkspace -TaskId $taskA1 -PlanContent (New-PlanContent -TaskId $taskA1 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun) -Label 'a1'
    $workspaceA1 = $fixtureA1.WorkspaceRoot
    $taskA1Dir = $fixtureA1.TaskDirectory
    $cleanupPaths += $workspaceA1
    $planA1Path = Join-Path $taskA1Dir 'plan.md'
    $planA1Hash = (Get-FileHash -LiteralPath $planA1Path -Algorithm SHA256).Hash
    $a1Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA1 -Stage 'PLAN_REVIEW' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceA1
    $a1Json = Assert-SingleLineJson -JsonText $a1Result.StdOut -Label 'A1'
    $a1Plan = Read-FileUtf8 -Path $planA1Path
    $orchestratorSkill = Read-FileUtf8 -Path (Join-Path $RepoRoot 'skills\orchestrator\SKILL.md')
    if ($a1Result.ExitCode -ne 0 -and
        $null -ne $a1Json -and -not $a1Json.ok -and $a1Json.status -eq 'rejected' -and
        (($a1Json.errors -join ' ') -match 'whitelist') -and
        $planA1Hash -eq (Get-FileHash -LiteralPath $planA1Path -Algorithm SHA256).Hash -and
        $a1Plan -notmatch '(?m)^- invocation:' -and
        $orchestratorSkill.Contains('`review` / `test` 直接加载现有 Markdown stage skill') -and
        -not $orchestratorSkill.Contains('markdown-fallback')) {
        Add-Check 'A1 review/test bypass the adapter and the orchestrator routes directly to Markdown stage skills'
    } else {
        Add-Failure ("A1 adapter retirement contract failed, got stdout=[{0}] stderr=[{1}]" -f $a1Result.StdOut, $a1Result.StdErr)
    }

    $taskA2 = 'skill-contract-a2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA2 = New-TaskWorkspace -TaskId $taskA2 -PlanContent (New-PlanContent -TaskId $taskA2 -Stage 'IMPLEMENT' -Tool 'claudecode') -Label 'a2'
    $workspaceA2 = $fixtureA2.WorkspaceRoot
    $taskA2Dir = $fixtureA2.TaskDirectory
    $cleanupPaths += $workspaceA2
    $a2Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA2 -Stage 'IMPLEMENT' -Skill 'implement' -Tool 'claudecode' -WorkspaceRoot $workspaceA2
    $a2Json = Assert-SingleLineJson -JsonText $a2Result.StdOut -Label 'A2'
    if ($a2Result.ExitCode -ne 0 -and $null -ne $a2Json -and -not $a2Json.ok -and $a2Result.StdErr -match 'adapter refuses side-effect skills') {
        Add-Check 'A2 implement is explicitly rejected by the adapter'
    } else {
        Add-Failure ("A2 implement rejection failed, got stdout=[{0}] stderr=[{1}]" -f $a2Result.StdOut, $a2Result.StdErr)
    }

    $taskA3 = 'skill-contract-a3-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA3 = New-TaskWorkspace -TaskId $taskA3 -PlanContent (New-PlanContent -TaskId $taskA3 -Stage 'PLAN' -Tool 'claudecode') -Label 'a3'
    $workspaceA3 = $fixtureA3.WorkspaceRoot
    $taskA3Dir = $fixtureA3.TaskDirectory
    $cleanupPaths += $workspaceA3
    $a3Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA3 -Stage 'PLAN' -Skill 'nonexistent' -Tool 'codex' -WorkspaceRoot $workspaceA3
    $a3Json = Assert-SingleLineJson -JsonText $a3Result.StdOut -Label 'A3'
    if ($a3Result.ExitCode -ne 0 -and $null -ne $a3Json -and -not $a3Json.ok -and (($a3Json.errors -join ' ') -match 'whitelist')) {
        Add-Check 'A3 whitelist rejects unknown skills'
    } else {
        Add-Failure ("A3 whitelist rejection failed, got stdout=[{0}] stderr=[{1}]" -f $a3Result.StdOut, $a3Result.StdErr)
    }

    $taskA4 = 'skill-contract-a4-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA4 = New-TaskWorkspace -TaskId $taskA4 -PlanContent (New-PlanContent -TaskId $taskA4 -Stage 'PLAN' -Tool 'claudecode') -Label 'a4'
    $workspaceA4 = $fixtureA4.WorkspaceRoot
    $taskA4Dir = $fixtureA4.TaskDirectory
    $cleanupPaths += $workspaceA4
    $a4Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA4 -Stage 'PLAN' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceA4 -Mode 'writable'
    $a4Json = Assert-SingleLineJson -JsonText $a4Result.StdOut -Label 'A4'
    if ($a4Result.ExitCode -ne 0 -and $null -ne $a4Json -and -not $a4Json.ok -and $a4Result.StdErr -match 'only supports readonly mode') {
        Add-Check 'A4 codex writable mode is rejected'
    } else {
        Add-Failure ("A4 codex mode rejection failed, got stdout=[{0}] stderr=[{1}]" -f $a4Result.StdOut, $a4Result.StdErr)
    }

    $taskA5 = 'skill-contract-a5-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA5 = New-TaskWorkspace -TaskId $taskA5 -PlanContent (New-PlanContent -TaskId $taskA5 -Stage 'PLAN' -Tool 'codex') -Label 'a5'
    $workspaceA5 = $fixtureA5.WorkspaceRoot
    $taskA5Dir = $fixtureA5.TaskDirectory
    $cleanupPaths += $workspaceA5
    $planA5Path = Join-Path $taskA5Dir 'plan.md'
    $planA5Hash = (Get-FileHash -LiteralPath $planA5Path -Algorithm SHA256).Hash
    $identityCasesOk = $true
    foreach ($invalidTaskId in @('none', 'idle', 'unknown', 'Invalid_Id')) {
        $identityResult = Invoke-Adapter -AdapterPath $adapterPath -TaskId $invalidTaskId -Stage 'PLAN' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceA5
        $identityJson = Assert-SingleLineJson -JsonText $identityResult.StdOut -Label ("A5 {0}" -f $invalidTaskId)
        if ($identityResult.ExitCode -eq 0 -or $null -eq $identityJson -or $identityJson.ok -or (($identityJson.errors -join ' ') -notmatch 'TaskId')) {
            $identityCasesOk = $false
        }
    }
    $maliciousTool = "codex`r`n- attacker-controlled: yes`r`n#"
    $toolIdentityResult = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA5 -Stage 'PLAN' -Skill 'review' -Tool $maliciousTool -WorkspaceRoot $workspaceA5
    $toolIdentityJson = Assert-SingleLineJson -JsonText $toolIdentityResult.StdOut -Label 'A5 malicious Tool'
    $toolIdentityRejected = $toolIdentityResult.ExitCode -ne 0 -and
        $null -ne $toolIdentityJson -and
        -not $toolIdentityJson.ok -and
        (($toolIdentityJson.errors -join ' ') -match 'Unsupported Tool')
    $maliciousSkill = "`r`nreview"
    $skillIdentityResult = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA5 -Stage 'PLAN' -Skill $maliciousSkill -Tool 'codex' -WorkspaceRoot $workspaceA5
    $skillIdentityJson = Assert-SingleLineJson -JsonText $skillIdentityResult.StdOut -Label 'A5 malicious Skill'
    $skillIdentityRejected = $skillIdentityResult.ExitCode -ne 0 -and
        $null -ne $skillIdentityJson -and
        -not $skillIdentityJson.ok -and
        (($skillIdentityJson.errors -join ' ') -match 'whitelist')
    if ($identityCasesOk -and
        $toolIdentityRejected -and
        $skillIdentityRejected -and
        $planA5Hash -eq (Get-FileHash -LiteralPath $planA5Path -Algorithm SHA256).Hash -and
        (Read-FileUtf8 -Path $planA5Path) -notmatch 'attacker-controlled' -and
        @(Get-ChildItem -LiteralPath $taskA5Dir -File -Force).Count -eq 1) {
        Add-Check 'A5 invalid task/tool identities return one error JSON line and write nothing'
    } else {
        Add-Failure 'A5 task/tool identity rejection was not machine-readable or mutated the canonical task directory'
    }

    $taskA6 = 'skill-contract-a6-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA6 = New-TaskWorkspace -TaskId $taskA6 -PlanContent (New-PlanContent -TaskId $taskA6 -Stage 'PLAN' -Tool 'codex') -Label 'a6'
    $workspaceA6 = $fixtureA6.WorkspaceRoot
    $taskA6Dir = $fixtureA6.TaskDirectory
    $obsoleteWrapperA6 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-obsolete-artifact-root-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $cleanupPaths += @($workspaceA6, $obsoleteWrapperA6)
    $planA6Path = Join-Path $taskA6Dir 'plan.md'
    $planA6Hash = (Get-FileHash -LiteralPath $planA6Path -Algorithm SHA256).Hash
    Write-Utf8Bom -Path $obsoleteWrapperA6 -Content @"
& '$adapterPath' -TaskId '$taskA6' -Stage 'PLAN' -Skill 'review' -Tool 'codex' -WorkspaceRoot '$workspaceA6' -ArtifactRoot '$taskA6Dir'
if (`$?) { exit 0 }
exit 1
"@
    $a6Result = Invoke-PowerShellWithStreams -Arguments @('-NoProfile', '-File', $obsoleteWrapperA6)
    if ($a6Result.ExitCode -ne 0 -and
        $a6Result.Combined -match 'ArtifactRoot' -and
        $planA6Hash -eq (Get-FileHash -LiteralPath $planA6Path -Algorithm SHA256).Hash -and
        @(Get-ChildItem -LiteralPath $taskA6Dir -File -Force).Count -eq 1) {
        Add-Check 'A6 removed ArtifactRoot parameter is rejected by binding before any write'
    } else {
        Add-Failure ("A6 obsolete ArtifactRoot binding contract failed: exit={0} output=[{1}]" -f $a6Result.ExitCode, $a6Result.Combined)
    }

    $taskA7 = 'skill-contract-a7-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA7 = New-TaskWorkspace -TaskId $taskA7 -PlanContent (New-PlanContent -TaskId $taskA7 -Stage 'PLAN' -Tool 'codex') -Label 'a7-real'
    $workspaceA7 = $fixtureA7.WorkspaceRoot
    $taskA7Dir = $fixtureA7.TaskDirectory
    $workspaceAliasA7 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-a7-alias-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += @($workspaceAliasA7, $workspaceA7)
    New-Item -ItemType Junction -Path $workspaceAliasA7 -Target $workspaceA7 | Out-Null
    $planA7Path = Join-Path $taskA7Dir 'plan.md'
    $planA7Hash = (Get-FileHash -LiteralPath $planA7Path -Algorithm SHA256).Hash
    $a7Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA7 -Stage 'PLAN' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceAliasA7
    $a7Json = Assert-SingleLineJson -JsonText $a7Result.StdOut -Label 'A7'
    if ($a7Result.ExitCode -ne 0 -and
        $null -ne $a7Json -and
        -not $a7Json.ok -and
        (($a7Json.errors -join ' ') -match 'reparse point') -and
        $planA7Hash -eq (Get-FileHash -LiteralPath $planA7Path -Algorithm SHA256).Hash -and
        @(Get-ChildItem -LiteralPath $taskA7Dir -File -Force).Count -eq 1) {
        Add-Check 'A7 workspace junction is rejected before any task write'
    } else {
        Add-Failure ("A7 workspace junction rejection failed: exit={0} stdout=[{1}] stderr=[{2}]" -f $a7Result.ExitCode, $a7Result.StdOut, $a7Result.StdErr)
    }

    $taskA8 = 'skill-contract-a8-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $workspaceA8 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-workspace-a8-' + [guid]::NewGuid().ToString('N'))
    $taskTargetA8 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-task-a8-target-' + [guid]::NewGuid().ToString('N'))
    $taskAliasA8 = Join-Path $workspaceA8 ("docs\tasks\{0}" -f $taskA8)
    $cleanupPaths += @($taskAliasA8, $workspaceA8, $taskTargetA8)
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskAliasA8) -Force | Out-Null
    New-Item -ItemType Directory -Path $taskTargetA8 -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskTargetA8 'plan.md') -Content (New-PlanContent -TaskId $taskA8 -Stage 'PLAN' -Tool 'codex')
    New-Item -ItemType Junction -Path $taskAliasA8 -Target $taskTargetA8 | Out-Null
    $planA8Path = Join-Path $taskTargetA8 'plan.md'
    $planA8Hash = (Get-FileHash -LiteralPath $planA8Path -Algorithm SHA256).Hash
    $a8Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA8 -Stage 'PLAN' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceA8
    $a8Json = Assert-SingleLineJson -JsonText $a8Result.StdOut -Label 'A8'
    if ($a8Result.ExitCode -ne 0 -and
        $null -ne $a8Json -and
        -not $a8Json.ok -and
        (($a8Json.errors -join ' ') -match 'reparse point') -and
        $planA8Hash -eq (Get-FileHash -LiteralPath $planA8Path -Algorithm SHA256).Hash -and
        @(Get-ChildItem -LiteralPath $taskTargetA8 -File -Force).Count -eq 1) {
        Add-Check 'A8 task-directory junction is rejected before any task write'
    } else {
        Add-Failure ("A8 task junction rejection failed: exit={0} stdout=[{1}] stderr=[{2}]" -f $a8Result.ExitCode, $a8Result.StdOut, $a8Result.StdErr)
    }

    $taskA9 = 'skill-contract-a9-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA9 = New-TaskWorkspace -TaskId $taskA9 -PlanContent (New-PlanContent -TaskId $taskA9 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun) -Label 'a9'
    $workspaceA9 = $fixtureA9.WorkspaceRoot
    $taskA9Dir = $fixtureA9.TaskDirectory
    $cleanupPaths += $workspaceA9
    $planA9Path = Join-Path $taskA9Dir 'plan.md'
    $planA9Hash = (Get-FileHash -LiteralPath $planA9Path -Algorithm SHA256).Hash
    $a9Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA9 -Stage 'CODE_REVIEW' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceA9
    $a9Json = Assert-SingleLineJson -JsonText $a9Result.StdOut -Label 'A9'
    if ($a9Result.ExitCode -ne 0 -and
        $null -ne $a9Json -and
        -not $a9Json.ok -and
        (($a9Json.errors -join ' ') -match 'Stage does not match plan frontmatter') -and
        $planA9Hash -eq (Get-FileHash -LiteralPath $planA9Path -Algorithm SHA256).Hash -and
        @(Get-ChildItem -LiteralPath $taskA9Dir -File -Force).Count -eq 1) {
        Add-Check 'A9 caller stage mismatch is rejected before delegation or trace mutation'
    } else {
        Add-Failure ("A9 stage authority rejection failed: exit={0} stdout=[{1}] stderr=[{2}]" -f $a9Result.ExitCode, $a9Result.StdOut, $a9Result.StdErr)
    }

    $taskA10 = 'skill-contract-a10-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA10 = New-TaskWorkspace -TaskId $taskA10 -PlanContent (New-PlanContent -TaskId $taskA10 -Stage 'BANANA' -Tool 'codex') -Label 'a10'
    $workspaceA10 = $fixtureA10.WorkspaceRoot
    $taskA10Dir = $fixtureA10.TaskDirectory
    $cleanupPaths += $workspaceA10
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceA10 '.assistant\skills') -Marker 'invalid-stage-must-not-run'
    $planA10Path = Join-Path $taskA10Dir 'plan.md'
    $planA10Hash = (Get-FileHash -LiteralPath $planA10Path -Algorithm SHA256).Hash
    $a10Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA10 -Stage 'BANANA' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceA10
    $a10Json = Assert-SingleLineJson -JsonText $a10Result.StdOut -Label 'A10'
    if ($a10Result.ExitCode -ne 0 -and
        $null -ne $a10Json -and
        -not $a10Json.ok -and
        (($a10Json.errors -join ' ') -match 'Stage is not canonical') -and
        $planA10Hash -eq (Get-FileHash -LiteralPath $planA10Path -Algorithm SHA256).Hash -and
        @(Get-ChildItem -LiteralPath $taskA10Dir -Filter 'codex-*.md' -File -Force).Count -eq 0 -and
        (Read-FileUtf8 -Path $planA10Path) -notmatch '(?m)^- invocation:') {
        Add-Check 'A10 non-canonical matching caller/plan stages are rejected before backend, artifact, or trace writes'
    } else {
        Add-Failure ("A10 invalid-stage rejection failed: exit={0} stdout=[{1}] stderr=[{2}] files={3}" -f $a10Result.ExitCode, $a10Result.StdOut, $a10Result.StdErr, (@(Get-ChildItem -LiteralPath $taskA10Dir -File -Force).Name -join ','))
    }

    $taskA11 = 'skill-contract-a11-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA11 = New-TaskWorkspace -TaskId $taskA11 -PlanContent (New-PlanContent -TaskId $taskA11 -Stage 'CODE_REVIEW' -Tool 'codex' -IncludeCodeReviewRun) -Label 'a11'
    $workspaceA11 = $fixtureA11.WorkspaceRoot
    $taskA11Dir = $fixtureA11.TaskDirectory
    $cleanupPaths += $workspaceA11
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceA11 '.assistant\skills') -Marker 'invalid-profile-or-payload-must-not-run'
    $planA11Path = Join-Path $taskA11Dir 'plan.md'
    $planA11Hash = (Get-FileHash -LiteralPath $planA11Path -Algorithm SHA256).Hash
    $a11Cases = @(
        [pscustomobject]@{ Label = 'invalid profile syntax'; Profile = 'bad/profile'; Payload = '{"task":"x"}'; Pattern = 'Unsupported tool profile name' }
        [pscustomobject]@{ Label = 'profile backend mismatch'; Profile = 'harness-default-claude'; Payload = '{"task":"x"}'; Pattern = 'does not match Tool' }
        [pscustomobject]@{ Label = 'array payload'; Profile = ''; Payload = '["not","an","object"]'; Pattern = 'must encode a JSON object' }
        [pscustomobject]@{ Label = 'numeric task'; Profile = ''; Payload = '{"task":42}'; Pattern = 'task must be a string' }
        [pscustomobject]@{ Label = 'object file'; Profile = ''; Payload = '{"task":"x","file":{"bad":true}}'; Pattern = 'file must be a string or an array of strings' }
        [pscustomobject]@{ Label = 'missing task'; Profile = ''; Payload = '{}'; Pattern = 'task is required' }
    )
    $a11Rejected = $true
    $a11Diagnostics = @()
    foreach ($case in $a11Cases) {
        $caseResult = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA11 -Stage 'CODE_REVIEW' -Skill 'codex' -Tool 'codex' -ToolProfileId $case.Profile -WorkspaceRoot $workspaceA11 -PayloadJson $case.Payload
        $caseJson = Assert-SingleLineJson -JsonText $caseResult.StdOut -Label ("A11 {0}" -f $case.Label)
        if ($caseResult.ExitCode -eq 0 -or $null -eq $caseJson -or $caseJson.ok -or (($caseJson.errors -join ' ') -notmatch $case.Pattern)) {
            $a11Rejected = $false
            $a11Diagnostics += ("{0}: exit={1} stdout=[{2}] stderr=[{3}]" -f $case.Label, $caseResult.ExitCode, $caseResult.StdOut, $caseResult.StdErr)
        }
    }
    foreach ($stubCase in @(
            [pscustomobject]@{ Label = 'review invalid profile'; Skill = 'review'; Profile = 'definitely-missing'; Pattern = 'Missing tool profile descriptor' }
            [pscustomobject]@{ Label = 'test profile backend mismatch'; Skill = 'test'; Profile = 'harness-default-claude'; Pattern = 'does not match Tool' }
        )) {
        $stubResult = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA11 -Stage 'CODE_REVIEW' -Skill $stubCase.Skill -Tool 'codex' -ToolProfileId $stubCase.Profile -WorkspaceRoot $workspaceA11
        $stubJson = Assert-SingleLineJson -JsonText $stubResult.StdOut -Label ("A11 {0}" -f $stubCase.Label)
        if ($stubResult.ExitCode -eq 0 -or $null -eq $stubJson -or $stubJson.ok -or (($stubJson.errors -join ' ') -notmatch $stubCase.Pattern)) {
            $a11Rejected = $false
            $a11Diagnostics += ("{0}: exit={1} stdout=[{2}] stderr=[{3}]" -f $stubCase.Label, $stubResult.ExitCode, $stubResult.StdOut, $stubResult.StdErr)
        }
    }
    if ($a11Rejected -and
        $planA11Hash -eq (Get-FileHash -LiteralPath $planA11Path -Algorithm SHA256).Hash -and
        @(Get-ChildItem -LiteralPath $taskA11Dir -Filter 'codex-*.md' -File -Force).Count -eq 0 -and
        (Read-FileUtf8 -Path $planA11Path) -notmatch '(?m)^- invocation:') {
        Add-Check 'A11 invalid profiles and payload shapes fail before backend, artifact, or trace writes'
    } else {
        Add-Failure ("A11 invalid profile/payload rejection was not machine-readable or mutated canonical task state: {0}" -f ($a11Diagnostics -join ' | '))
    }

    $taskA12 = 'skill-contract-a12-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureA12 = New-TaskWorkspace -TaskId $taskA12 -PlanContent (New-PlanContent -TaskId $taskA12 -Stage 'CODE_REVIEW' -Tool 'banana' -IncludeCodeReviewRun) -Label 'a12'
    $workspaceA12 = $fixtureA12.WorkspaceRoot
    $taskA12Dir = $fixtureA12.TaskDirectory
    $cleanupPaths += $workspaceA12
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceA12 '.assistant\skills') -Marker 'invalid-plan-tool-must-not-run'
    $planA12Path = Join-Path $taskA12Dir 'plan.md'
    $planA12Hash = (Get-FileHash -LiteralPath $planA12Path -Algorithm SHA256).Hash
    $a12Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskA12 -Stage 'CODE_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceA12 -PayloadJson '{"task":"must not run"}'
    $a12Json = Assert-SingleLineJson -JsonText $a12Result.StdOut -Label 'A12'
    if ($a12Result.ExitCode -ne 0 -and
        $null -ne $a12Json -and
        -not $a12Json.ok -and
        (($a12Json.errors -join ' ') -match 'Plan tool is not canonical') -and
        $planA12Hash -eq (Get-FileHash -LiteralPath $planA12Path -Algorithm SHA256).Hash -and
        @(Get-ChildItem -LiteralPath $taskA12Dir -Filter 'codex-*.md' -File -Force).Count -eq 0 -and
        (Read-FileUtf8 -Path $planA12Path) -notmatch '(?m)^- invocation:') {
        Add-Check 'A12 a non-canonical plan tool is rejected before backend, artifact, or trace writes'
    } else {
        Add-Failure 'A12 invalid plan tool reached delegation or mutated canonical task state'
    }

    $taskB1 = 'skill-contract-b1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureB1 = New-TaskWorkspace -TaskId $taskB1 -PlanContent (New-PlanContent -TaskId $taskB1 -Stage 'PLAN_REVIEW' -Tool 'claudecode' -IncludePlanReviewRun) -Label 'b1'
    $workspaceB1 = $fixtureB1.WorkspaceRoot
    $taskB1Dir = $fixtureB1.TaskDirectory
    $cleanupPaths += $workspaceB1
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceB1 '.assistant\skills') -Marker 'project'
    $ownerRootB1 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-b1-owner-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $ownerRootB1 -Force | Out-Null
    $cleanupPaths += $ownerRootB1
    $identityB1Path = Join-Path $ownerRootB1 'identity.json'
    $markerB1Path = Join-Path $ownerRootB1 'late.marker'
    $tokenB1 = [guid]::NewGuid().ToString('N')
    $payloadB1 = [ordered]@{
        task = ('outer-natural::{0}::{1}::{2}' -f $identityB1Path,$markerB1Path,$tokenB1)
        file = @('docs/tasks/example/plan.md')
        session = 'resume-123'
        model = 'gpt-5.5/xhigh'
        reasoning = 'high'
    } | ConvertTo-Json -Compress
    $timerB1 = [System.Diagnostics.Stopwatch]::StartNew()
    $b1Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskB1 -Stage 'PLAN_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceB1 -PayloadJson $payloadB1
    $timerB1.Stop()
    $b1Json = Assert-SingleLineJson -JsonText $b1Result.StdOut -Label 'B1'
    $b1Record = if ($null -ne $b1Json -and $b1Json.artifact_paths.Count -eq 1) { Read-FileUtf8 -Path $b1Json.artifact_paths[0] } else { '' }
    $b1RecordObject = if ([string]::IsNullOrWhiteSpace($b1Record)) { $null } else { $b1Record | ConvertFrom-Json }
    $b1FrameHash = ''
    if ($null -ne $b1RecordObject) {
        $b1Sha = [System.Security.Cryptography.SHA256]::Create()
        try { $b1FrameHash = [System.BitConverter]::ToString($b1Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$b1RecordObject.frame_probe))).Replace('-', '') } finally { $b1Sha.Dispose() }
    }
    $identityB1 = Read-LifecycleIdentity -Path $identityB1Path
    if ($null -ne $identityB1 -and [string]$identityB1.token -ceq $tokenB1) {
        $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$identityB1.root_pid; Ticks = [long]$identityB1.root_start_ticks; Label = 'B1 target root' })
        $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$identityB1.child_pid; Ticks = [long]$identityB1.child_start_ticks; Label = 'B1 inherited-pipe child' })
    }
    $b1RootAlive = $null -ne $identityB1 -and (Test-LifecycleProcessAlive -ProcessId ([int]$identityB1.root_pid) -StartTicks ([long]$identityB1.root_start_ticks))
    $b1ChildAlive = $null -ne $identityB1 -and (Test-LifecycleProcessAlive -ProcessId ([int]$identityB1.child_pid) -StartTicks ([long]$identityB1.child_start_ticks))
    $b1Plan = Read-FileUtf8 -Path (Join-Path $taskB1Dir 'plan.md')
    $b1TraceCount = [regex]::Matches($b1Plan, '(?m)^- invocation: skill=codex mode=adapter tool=codex ok=True status=delegated\s*$').Count
    $b1BackendTemp = if ($null -eq $b1RecordObject) { '' } else { [string]$b1RecordObject.output }
    $b1Dispatcher = if ($null -eq $b1RecordObject) { '' } else { [string]$b1RecordObject.caller_dispatcher }
    $b1RequestResidue = @(Get-DispatchRequestResidue -Token $tokenB1)
    if ($b1Result.ExitCode -eq 0 -and
        $null -ne $b1Json -and
        $b1Json.ok -and
        $b1Json.status -eq 'delegated' -and
        ($b1Json.handoff -eq 'session_id=mock-session') -and
        $b1Json.artifact_paths.Count -eq 1 -and
        (Test-Path -LiteralPath $b1Json.artifact_paths[0] -PathType Leaf) -and
        $b1Record -match '"marker":"project"' -and
        $b1Record -match '"reasoning":"high"' -and
        $b1Record -match '"model":"gpt-5\.5/xhigh"' -and
        $null -ne $b1RecordObject -and
        [version]$b1RecordObject.host_version -ge [version]'7.3' -and
        [int]$b1RecordObject.timeout_seconds -eq 1800 -and
        ([string]$b1RecordObject.frame_probe).Length -eq 131072 -and $b1FrameHash -ceq 'A19450B60164270A21FB489E8478D7C1CA99CA07C3190D10977BB77542983BAC' -and
        $b1RecordObject.dispatcher_tracked -eq $true -and
        $b1TraceCount -eq 1 -and
        $null -ne $identityB1 -and [string]$identityB1.token -ceq $tokenB1 -and
        -not $b1RootAlive -and -not $b1ChildAlive -and
        -not (Test-Path -LiteralPath $markerB1Path) -and
        -not [string]::IsNullOrWhiteSpace($b1Dispatcher) -and $b1Dispatcher -ceq $dispatcherPath -and (Test-Path -LiteralPath $b1Dispatcher -PathType Leaf) -and
        $b1RequestResidue.Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($b1BackendTemp) -and -not (Test-Path -LiteralPath $b1BackendTemp)) {
        Add-Check 'B1 Windows PowerShell full adapter reaches the tracked PS7 dispatcher, closes inherited-pipe descendants, removes request data, and preserves artifact/trace semantics'
    } else {
        Add-Failure ("B1 supervisor wiring failed: duration_ms={0} root_alive={1} child_alive={2} marker={3} traces={4} stdout=[{5}] stderr=[{6}] record=[{7}]" -f $timerB1.ElapsedMilliseconds,$b1RootAlive,$b1ChildAlive,(Test-Path -LiteralPath $markerB1Path),$b1TraceCount,$b1Result.StdOut,$b1Result.StdErr,$b1Record)
    }

    $taskB2 = 'skill-contract-b2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureB2 = New-TaskWorkspace -TaskId $taskB2 -PlanContent (New-PlanContent -TaskId $taskB2 -Stage 'PLAN' -Tool 'codex') -Label 'b2'
    $workspaceB2 = $fixtureB2.WorkspaceRoot
    $taskB2Dir = $fixtureB2.TaskDirectory
    $parkedTaskB2 = $taskB2Dir + '-parked'
    $outsideB2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-b2-outside-' + [guid]::NewGuid().ToString('N'))
    $wrapperB2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-b2-wrapper-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $cleanupPaths += @($taskB2Dir, $parkedTaskB2, $workspaceB2, $outsideB2, $wrapperB2)
    New-Item -ItemType Directory -Path $outsideB2 -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $outsideB2 'sentinel.txt'), 'outside-must-stay-unchanged', (New-Object System.Text.UTF8Encoding($false)))
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceB2 '.assistant\skills') -Marker 'junction-swap'
    $eventIdB2 = [guid]::NewGuid().ToString('N')
    $readyNameB2 = 'dev-harness.skill-contract.b2.ready.' + $eventIdB2
    $releaseNameB2 = 'dev-harness.skill-contract.b2.release.' + $eventIdB2
    $createdB2 = $false
    $readyEventB2 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $readyNameB2, [ref]$createdB2)
    $releaseEventB2 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $releaseNameB2, [ref]$createdB2)
    Write-Utf8Bom -Path $wrapperB2 -Content @"
& '$adapterPath' -TaskId '$taskB2' -Stage 'PLAN' -Skill 'codex' -Tool 'codex' -WorkspaceRoot '$workspaceB2' -PayloadJson '{"task":"barrier=$readyNameB2|$releaseNameB2"}'
exit `$LASTEXITCODE
"@
    $captureB2 = Start-PowerShellWithStreams -ScriptPath $wrapperB2
    $cleanupPaths += $captureB2.StreamRoot
    $backendReadyB2 = $readyEventB2.WaitOne(10000)
    if ($backendReadyB2) {
        Move-Item -LiteralPath $taskB2Dir -Destination $parkedTaskB2
        New-Item -ItemType Junction -Path $taskB2Dir -Target $outsideB2 | Out-Null
    }
    $releaseEventB2.Set() | Out-Null
    $resultB2 = Complete-PowerShellWithStreams -Capture $captureB2
    $jsonB2 = Assert-SingleLineJson -JsonText $resultB2.StdOut -Label 'B2'
    $outsideSentinelB2 = Read-FileUtf8 -Path (Join-Path $outsideB2 'sentinel.txt')
    if ($backendReadyB2 -and
        $resultB2.ExitCode -ne 0 -and
        $null -ne $jsonB2 -and
        -not $jsonB2.ok -and
        (($jsonB2.errors -join ' ') -match 'reparse point') -and
        @(Get-ChildItem -LiteralPath $outsideB2 -File -Force).Count -eq 1 -and
        $outsideSentinelB2 -eq 'outside-must-stay-unchanged') {
        Add-Check 'B2 task-directory junction swap after backend start fails without outside writes'
    } else {
        Add-Failure ("B2 junction-swap publish guard failed: ready={0} exit={1} stdout=[{2}] stderr=[{3}]" -f $backendReadyB2, $resultB2.ExitCode, $resultB2.StdOut, $resultB2.StdErr)
    }
    $readyEventB2.Dispose()
    $releaseEventB2.Dispose()

    $taskB3 = 'skill-contract-b3-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureB3 = New-TaskWorkspace -TaskId $taskB3 -PlanContent (New-PlanContent -TaskId $taskB3 -Stage 'CODE_REVIEW' -Tool 'codex' -IncludeCodeReviewRun) -Label 'b3'
    $workspaceB3 = $fixtureB3.WorkspaceRoot
    $taskB3Dir = $fixtureB3.TaskDirectory
    $wrapperB3A = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-b3-a-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $wrapperB3B = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-b3-b-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $cleanupPaths += @($workspaceB3, $wrapperB3A, $wrapperB3B)
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceB3 '.assistant\skills') -Marker 'concurrent'
    $eventIdB3 = [guid]::NewGuid().ToString('N')
    $readyNameB3A = 'dev-harness.skill-contract.b3.ready-a.' + $eventIdB3
    $readyNameB3B = 'dev-harness.skill-contract.b3.ready-b.' + $eventIdB3
    $releaseNameB3 = 'dev-harness.skill-contract.b3.release.' + $eventIdB3
    $createdB3 = $false
    $readyEventB3A = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $readyNameB3A, [ref]$createdB3)
    $readyEventB3B = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $readyNameB3B, [ref]$createdB3)
    $releaseEventB3 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $releaseNameB3, [ref]$createdB3)
    Write-Utf8Bom -Path $wrapperB3A -Content @"
& '$adapterPath' -TaskId '$taskB3' -Stage 'CODE_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot '$workspaceB3' -PayloadJson '{"task":"barrier=$readyNameB3A|$releaseNameB3"}'
exit `$LASTEXITCODE
"@
    Write-Utf8Bom -Path $wrapperB3B -Content @"
& '$adapterPath' -TaskId '$taskB3' -Stage 'CODE_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot '$workspaceB3' -PayloadJson '{"task":"barrier=$readyNameB3B|$releaseNameB3"}'
exit `$LASTEXITCODE
"@
    $captureB3A = Start-PowerShellWithStreams -ScriptPath $wrapperB3A
    $captureB3B = Start-PowerShellWithStreams -ScriptPath $wrapperB3B
    $cleanupPaths += @($captureB3A.StreamRoot, $captureB3B.StreamRoot)
    $bothReadyB3 = $readyEventB3A.WaitOne(10000) -and $readyEventB3B.WaitOne(10000)
    $releaseEventB3.Set() | Out-Null
    $resultB3A = Complete-PowerShellWithStreams -Capture $captureB3A
    $resultB3B = Complete-PowerShellWithStreams -Capture $captureB3B
    $jsonB3A = Assert-SingleLineJson -JsonText $resultB3A.StdOut -Label 'B3A'
    $jsonB3B = Assert-SingleLineJson -JsonText $resultB3B.StdOut -Label 'B3B'
    $artifactsB3 = @(Get-ChildItem -LiteralPath $taskB3Dir -Filter 'codex-*.md' -File -Force)
    $contentB3A = if ($null -ne $jsonB3A -and $jsonB3A.artifact_paths.Count -eq 1) { Read-FileUtf8 -Path $jsonB3A.artifact_paths[0] } else { '' }
    $contentB3B = if ($null -ne $jsonB3B -and $jsonB3B.artifact_paths.Count -eq 1) { Read-FileUtf8 -Path $jsonB3B.artifact_paths[0] } else { '' }
    $validatorB3 = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskB3 -RepoRoot $workspaceB3
    $traceCountB3 = [regex]::Matches((Read-FileUtf8 -Path (Join-Path $taskB3Dir 'plan.md')), '(?m)^- invocation: skill=codex mode=adapter tool=codex ok=True status=delegated\s*$').Count
    if ($bothReadyB3 -and $resultB3A.ExitCode -eq 0 -and $resultB3B.ExitCode -eq 0 -and
        $null -ne $jsonB3A -and $jsonB3A.ok -and $null -ne $jsonB3B -and $jsonB3B.ok -and
        $jsonB3A.artifact_paths[0] -cne $jsonB3B.artifact_paths[0] -and
        $artifactsB3.Count -eq 2 -and
        $contentB3A -match [regex]::Escape($readyNameB3A) -and
        $contentB3B -match [regex]::Escape($readyNameB3B) -and
        $traceCountB3 -eq 2 -and
        $validatorB3.ExitCode -eq 0) {
        Add-Check 'B3 concurrent reviewers ignore canonical invocation-line generation changes and publish distinct artifacts/traces'
    } else {
        Add-Failure ("B3 concurrent publish failed: ready={0} a_exit={1} b_exit={2} artifacts={3} traces={4} validator=[{5}]" -f $bothReadyB3, $resultB3A.ExitCode, $resultB3B.ExitCode, $artifactsB3.Count, $traceCountB3, $validatorB3.Text)
    }
    $readyEventB3A.Dispose()
    $readyEventB3B.Dispose()
    $releaseEventB3.Dispose()

    $taskB4 = 'skill-contract-b4-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureB4 = New-TaskWorkspace -TaskId $taskB4 -PlanContent (New-PlanContent -TaskId $taskB4 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun) -Label 'b4'
    $workspaceB4 = $fixtureB4.WorkspaceRoot
    $taskB4Dir = $fixtureB4.TaskDirectory
    $cleanupPaths += $workspaceB4
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceB4 '.assistant\skills') -Marker 'partial-output'
    $planB4Path = Join-Path $taskB4Dir 'plan.md'
    $planB4Hash = (Get-FileHash -LiteralPath $planB4Path -Algorithm SHA256).Hash
    $b4Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskB4 -Stage 'PLAN_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceB4 -PayloadJson '{"task":"partial-output-exit-7"}'
    $b4Json = Assert-SingleLineJson -JsonText $b4Result.StdOut -Label 'B4'
    $backendTempB4 = if ($b4Result.StdErr -match '(?m)^backend_temp=(.+?)\r?$') { $Matches[1] } else { '' }
    $planB4 = Read-FileUtf8 -Path $planB4Path
    if ($b4Result.ExitCode -ne 0 -and
        $null -ne $b4Json -and
        -not $b4Json.ok -and
        $b4Json.status -eq 'error' -and
        @($b4Json.artifact_paths).Count -eq 0 -and
        @(Get-ChildItem -LiteralPath $taskB4Dir -Filter 'codex-*.md' -File -Force).Count -eq 0 -and
        $planB4Hash -eq (Get-FileHash -LiteralPath $planB4Path -Algorithm SHA256).Hash -and
        $planB4 -notmatch '(?m)^- invocation:' -and
        -not [string]::IsNullOrWhiteSpace($backendTempB4) -and
        -not (Test-Path -LiteralPath $backendTempB4)) {
        Add-Check 'B4 partial backend output followed by exit 7 publishes no artifact/trace and cleans its assigned temp file'
    } else {
        Add-Failure ("B4 nonzero backend commit boundary failed: exit={0} stdout=[{1}] stderr=[{2}] backend_temp=[{3}]" -f $b4Result.ExitCode, $b4Result.StdOut, $b4Result.StdErr, $backendTempB4)
    }

    $taskB5 = 'skill-contract-b5-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureB5 = New-TaskWorkspace -TaskId $taskB5 -PlanContent (New-PlanContent -TaskId $taskB5 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun) -Label 'b5'
    $workspaceB5 = $fixtureB5.WorkspaceRoot
    $taskB5Dir = $fixtureB5.TaskDirectory
    $cleanupPaths += $workspaceB5
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceB5 '.assistant\skills') -Marker 'exit-124'
    $planB5Path = Join-Path $taskB5Dir 'plan.md'
    $planB5Hash = (Get-FileHash -LiteralPath $planB5Path -Algorithm SHA256).Hash
    $b5Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskB5 -Stage 'PLAN_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceB5 -PayloadJson '{"task":"direct-exit-124"}'
    $b5Json = Assert-SingleLineJson -JsonText $b5Result.StdOut -Label 'B5'
    $backendTempB5 = if ($b5Result.StdErr -match '(?m)backend_temp=(.+?)\r?$') { $Matches[1].Trim() } else { '' }
    $planB5 = Read-FileUtf8 -Path $planB5Path
    if ($b5Result.ExitCode -eq 1 -and
        $null -ne $b5Json -and -not $b5Json.ok -and $b5Json.status -eq 'error' -and
        (($b5Json.errors -join ' ') -match 'codex adapter exited with code 124') -and
        $b5Result.StdErr -match 'codex adapter exited with code 124' -and
        @($b5Json.artifact_paths).Count -eq 0 -and
        @(Get-ChildItem -LiteralPath $taskB5Dir -Filter 'codex-*.md' -File -Force).Count -eq 0 -and
        $planB5Hash -eq (Get-FileHash -LiteralPath $planB5Path -Algorithm SHA256).Hash -and
        $planB5 -notmatch '(?m)^- invocation:' -and
        -not [string]::IsNullOrWhiteSpace($backendTempB5) -and -not (Test-Path -LiteralPath $backendTempB5)) {
        Add-Check 'B5 target exit 124 maps to error JSON/process exit 1 with code diagnostics and zero artifact/trace/temp commit'
    } else {
        Add-Failure ("B5 exit-124 mapping failed: exit={0} stdout=[{1}] stderr=[{2}] backend_temp=[{3}]" -f $b5Result.ExitCode,$b5Result.StdOut,$b5Result.StdErr,$backendTempB5)
    }

    $taskB6 = 'skill-contract-b6-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureB6 = New-TaskWorkspace -TaskId $taskB6 -PlanContent (New-PlanContent -TaskId $taskB6 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun) -Label 'b6'
    $workspaceB6 = $fixtureB6.WorkspaceRoot
    $taskB6Dir = $fixtureB6.TaskDirectory
    $ownerRootB6 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-b6-owner-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $ownerRootB6 -Force | Out-Null
    $cleanupPaths += @($workspaceB6, $ownerRootB6)
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceB6 '.assistant\skills') -Marker 'outer-abort'
    $identityB6Path = Join-Path $ownerRootB6 'identity.json'
    $markerB6Path = Join-Path $ownerRootB6 'late.marker'
    $outerWrapperB6 = Join-Path $ownerRootB6 'outer.ps1'
    $tokenB6 = [guid]::NewGuid().ToString('N')
    $eventIdB6 = [guid]::NewGuid().ToString('N')
    $readyNameB6 = 'dev-harness.skill-contract.b6.ready.' + $eventIdB6
    $releaseNameB6 = 'dev-harness.skill-contract.b6.release.' + $eventIdB6
    $createdB6 = $false
    $readyEventB6 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $readyNameB6, [ref]$createdB6)
    $releaseEventB6 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $releaseNameB6, [ref]$createdB6)
    $payloadB6 = [ordered]@{ task = ('outer-abort::{0}::{1}::{2}::{3}::{4}' -f $identityB6Path,$readyNameB6,$releaseNameB6,$markerB6Path,$tokenB6) } | ConvertTo-Json -Compress
    $payloadLiteralB6 = "'" + $payloadB6.Replace("'", "''") + "'"
    Write-Utf8Bom -Path $outerWrapperB6 -Content @"
& '$adapterPath' -TaskId '$taskB6' -Stage 'PLAN_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot '$workspaceB6' -PayloadJson $payloadLiteralB6
exit `$LASTEXITCODE
"@
    $planB6Path = Join-Path $taskB6Dir 'plan.md'
    $planB6Hash = (Get-FileHash -LiteralPath $planB6Path -Algorithm SHA256).Hash
    $captureB6 = Start-LifecyclePowerShell -HostPath (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source -ScriptPath $outerWrapperB6
    $readyB6 = $false
    $rootOnlyKilledB6 = $false
    $backendCreatedBeforeKillB6 = $false
    $requestAbsentBeforeKillB6 = $false
    $supervisorAliveBeforeKillB6 = $false
    $supervisorAliveAfterOuterKillB6 = $false
    $identityB6 = $null
    try {
        $readyB6 = $readyEventB6.WaitOne(10000)
        $identityB6 = Read-LifecycleIdentity -Path $identityB6Path -RequiredProperties @('token','root_pid','root_start_ticks','supervisor_pid','supervisor_start_ticks','dispatcher_path','dispatcher_tracked','backend_output')
        $backendCreatedBeforeKillB6 = $null -ne $identityB6 -and
            (Test-Path -LiteralPath ([string]$identityB6.backend_output) -PathType Leaf) -and
            (Read-FileUtf8 -Path ([string]$identityB6.backend_output)) -ceq ('sensitive-abort-output-' + $tokenB6)
        $requestAbsentBeforeKillB6 = @(Get-DispatchRequestResidue -Token $tokenB6).Count -eq 0
        $supervisorAliveBeforeKillB6 = $null -ne $identityB6 -and
            [int]$identityB6.supervisor_pid -ne $captureB6.Process.Id -and
            (Test-LifecycleProcessAlive -ProcessId ([int]$identityB6.supervisor_pid) -StartTicks ([long]$identityB6.supervisor_start_ticks))
        if ($readyB6 -and $null -ne $identityB6 -and
            [string]$identityB6.token -ceq $tokenB6 -and $identityB6.dispatcher_tracked -eq $true -and
            [string]$identityB6.dispatcher_path -ceq $dispatcherPath -and
            $backendCreatedBeforeKillB6 -and $requestAbsentBeforeKillB6 -and $supervisorAliveBeforeKillB6) {
            $captureB6.Process.Kill()
            $rootOnlyKilledB6 = $captureB6.Process.WaitForExit(5000)
            $supervisorAliveAfterOuterKillB6 = $rootOnlyKilledB6 -and
                (Test-LifecycleProcessAlive -ProcessId ([int]$identityB6.supervisor_pid) -StartTicks ([long]$identityB6.supervisor_start_ticks))
        }
    } catch {
        Add-Failure ("B6 root-only abort injection failed: {0}" -f $_.Exception.Message)
    } finally {
        $releaseEventB6.Set() | Out-Null
    }
    $outerResultB6 = Complete-LifecyclePowerShell -Capture $captureB6 -Label 'B6 outer abort' -TimeoutMilliseconds 5000
    $identityTimerB6 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($identityTimerB6.ElapsedMilliseconds -lt 5000) {
        $candidateB6 = Read-LifecycleIdentity -Path $identityB6Path -TimeoutMilliseconds 100 -RequiredProperties @('token','root_pid','root_start_ticks','supervisor_pid','supervisor_start_ticks','child_pid','child_start_ticks','dispatcher_path','dispatcher_tracked','backend_output')
        if ($null -ne $candidateB6 -and [int]$candidateB6.child_pid -gt 0 -and [long]$candidateB6.child_start_ticks -gt 0) {
            $identityB6 = $candidateB6
            break
        }
        Start-Sleep -Milliseconds 25
    }
    if ($null -ne $identityB6 -and [string]$identityB6.token -ceq $tokenB6) {
        $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$identityB6.supervisor_pid; Ticks = [long]$identityB6.supervisor_start_ticks; Label = 'B6 orphaned supervisor' })
        $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$identityB6.root_pid; Ticks = [long]$identityB6.root_start_ticks; Label = 'B6 target root' })
        if ([int]$identityB6.child_pid -gt 0) {
            $cleanupIdentities.Add([pscustomobject]@{ Id = [int]$identityB6.child_pid; Ticks = [long]$identityB6.child_start_ticks; Label = 'B6 inherited-pipe child' })
        }
    }
    $shutdownTimerB6 = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $supervisorAliveB6 = $null -ne $identityB6 -and (Test-LifecycleProcessAlive -ProcessId ([int]$identityB6.supervisor_pid) -StartTicks ([long]$identityB6.supervisor_start_ticks))
        $rootAliveB6 = $null -ne $identityB6 -and (Test-LifecycleProcessAlive -ProcessId ([int]$identityB6.root_pid) -StartTicks ([long]$identityB6.root_start_ticks))
        $childAliveB6 = $null -ne $identityB6 -and [int]$identityB6.child_pid -gt 0 -and (Test-LifecycleProcessAlive -ProcessId ([int]$identityB6.child_pid) -StartTicks ([long]$identityB6.child_start_ticks))
        if (-not $supervisorAliveB6 -and -not $rootAliveB6 -and -not $childAliveB6) { break }
        Start-Sleep -Milliseconds 25
    } while ($shutdownTimerB6.ElapsedMilliseconds -lt 5000)
    $supervisorExitedB6 = -not $supervisorAliveB6
    $rootAliveB6 = $null -ne $identityB6 -and (Test-LifecycleProcessAlive -ProcessId ([int]$identityB6.root_pid) -StartTicks ([long]$identityB6.root_start_ticks))
    $childAliveB6 = $null -ne $identityB6 -and [int]$identityB6.child_pid -gt 0 -and (Test-LifecycleProcessAlive -ProcessId ([int]$identityB6.child_pid) -StartTicks ([long]$identityB6.child_start_ticks))
    $backendTempB6 = if ($null -eq $identityB6) { '' } else { [string]$identityB6.backend_output }
    $dispatcherB6 = if ($null -eq $identityB6) { '' } else { [string]$identityB6.dispatcher_path }
    $requestResidueB6 = @(Get-DispatchRequestResidue -Token $tokenB6)
    $planB6 = Read-FileUtf8 -Path $planB6Path
    if ($readyB6 -and $rootOnlyKilledB6 -and $backendCreatedBeforeKillB6 -and
        $supervisorAliveBeforeKillB6 -and $supervisorAliveAfterOuterKillB6 -and $supervisorExitedB6 -and
        -not $outerResultB6.OuterTimedOut -and
        $null -ne $identityB6 -and [string]$identityB6.token -ceq $tokenB6 -and
        [int]$identityB6.child_pid -gt 0 -and -not $rootAliveB6 -and -not $childAliveB6 -and
        -not (Test-Path -LiteralPath $markerB6Path) -and
        -not [string]::IsNullOrWhiteSpace($dispatcherB6) -and $dispatcherB6 -ceq $dispatcherPath -and (Test-Path -LiteralPath $dispatcherB6 -PathType Leaf) -and
        $requestResidueB6.Count -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($backendTempB6) -and -not (Test-Path -LiteralPath $backendTempB6) -and
        @(Get-ChildItem -LiteralPath $taskB6Dir -Filter 'codex-*.md' -File -Force).Count -eq 0 -and
        $planB6Hash -eq (Get-FileHash -LiteralPath $planB6Path -Algorithm SHA256).Hash -and
        $planB6 -notmatch '(?m)^- invocation:') {
        Add-Check 'B6 request data is gone while the backend runs, and root-only PS5 abort leaves the orphaned PS7 supervisor to close its target tree with zero-commit residue'
    } else {
        Add-Failure ("B6 orphan supervisor cleanup failed: ready={0} root_killed={1} output_created={2} request_absent_while_running={3} supervisor_before={4} supervisor_after_outer={5} supervisor_exited={6} outer_timeout={7} target_alive={8} child_alive={9} marker={10} dispatcher=[{11}] request_residue={12} backend_temp=[{13}]" -f $readyB6,$rootOnlyKilledB6,$backendCreatedBeforeKillB6,$requestAbsentBeforeKillB6,$supervisorAliveBeforeKillB6,$supervisorAliveAfterOuterKillB6,$supervisorExitedB6,$outerResultB6.OuterTimedOut,$rootAliveB6,$childAliveB6,(Test-Path -LiteralPath $markerB6Path),$dispatcherB6,$requestResidueB6.Count,$backendTempB6)
    }
    $readyEventB6.Dispose()
    $releaseEventB6.Dispose()

    $frameRepo = New-IsolatedRepoFixture -SourceRoot $RepoRoot
    $cleanupPaths += $frameRepo
    $frameAdapterPath = Join-Path $frameRepo 'scripts\invoke-harness-skill.ps1'
    $frameSupervisorPath = Join-Path $frameRepo 'scripts\invoke-harness-skill-supervisor.ps1'
    Write-Utf8Bom -Path $frameSupervisorPath -Content @'
[CmdletBinding()]
param(
    [string]$TargetScriptPath,
    [string]$RequestPath,
    [string]$OutputPath,
    [int]$TimeoutSeconds
)
$request = [System.IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
$taskEntry = @($request.parameters | Where-Object { [string]$_.name -ceq 'Task' })
$task = if ($taskEntry.Count -eq 1) { [string]$taskEntry[0].value } else { '' }
if ($task.StartsWith('frame-case=zero::', [System.StringComparison]::Ordinal)) { exit 0 }
if ($task.StartsWith('frame-case=two::', [System.StringComparison]::Ordinal)) {
    [Console]::Out.WriteLine('__DEV_HARNESS_BACKEND_OUTPUT_BASE64__=YQ==')
    [Console]::Out.WriteLine('__DEV_HARNESS_BACKEND_OUTPUT_BASE64__=Yg==')
    exit 0
}
if ($task.StartsWith('frame-case=invalid::', [System.StringComparison]::Ordinal)) {
    [Console]::Out.WriteLine('__DEV_HARNESS_BACKEND_OUTPUT_BASE64__=not-base64')
    exit 0
}
if ($task.StartsWith('frame-case=cleanup::', [System.StringComparison]::Ordinal)) {
    [System.IO.File]::SetAttributes($RequestPath, [System.IO.FileAttributes]::ReadOnly)
    exit 0
}
exit 99
'@
    foreach ($frameCase in @(
            [pscustomobject]@{ Name = 'zero'; Pattern = 'expected exactly one backend output frame, got 0' }
            [pscustomobject]@{ Name = 'two'; Pattern = 'expected exactly one backend output frame, got 2' }
            [pscustomobject]@{ Name = 'invalid'; Pattern = 'backend output frame is not valid Base64' }
            [pscustomobject]@{ Name = 'cleanup'; Pattern = 'Adapter dispatch request cleanup failed' }
        )) {
        $frameTask = 'skill-contract-frame-' + $frameCase.Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $frameFixture = New-TaskWorkspace -TaskId $frameTask -PlanContent (New-PlanContent -TaskId $frameTask -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun) -Label ('frame-' + $frameCase.Name)
        $frameWorkspace = $frameFixture.WorkspaceRoot
        $frameTaskDir = $frameFixture.TaskDirectory
        $cleanupPaths += $frameWorkspace
        Write-MockCodexSkill -SkillRoot (Join-Path $frameWorkspace '.assistant\skills') -Marker ('frame-' + $frameCase.Name)
        $framePlanPath = Join-Path $frameTaskDir 'plan.md'
        $framePlanHash = (Get-FileHash -LiteralPath $framePlanPath -Algorithm SHA256).Hash
        $framePayloadTask = 'frame-case={0}::{1}' -f $frameCase.Name,[guid]::NewGuid().ToString('N')
        $frameResult = Invoke-Adapter -AdapterPath $frameAdapterPath -TaskId $frameTask -Stage 'PLAN_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $frameWorkspace -PayloadJson (([ordered]@{ task = $framePayloadTask }) | ConvertTo-Json -Compress)
        $frameJson = Assert-SingleLineJson -JsonText $frameResult.StdOut -Label ('frame ' + $frameCase.Name)
        $framePlan = Read-FileUtf8 -Path $framePlanPath
        $frameRequestResidue = @(Get-DispatchRequestResidue -Token $framePayloadTask)
        $frameCleanupStateOk = if ($frameCase.Name -ceq 'cleanup') {
            $frameRequestResidue.Count -eq 1 -and (($frameRequestResidue[0].Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0)
        } else {
            $frameRequestResidue.Count -eq 0
        }
        if ($frameResult.ExitCode -eq 1 -and $null -ne $frameJson -and -not $frameJson.ok -and $frameJson.status -eq 'error' -and
            (($frameJson.errors -join ' ') -match [regex]::Escape($frameCase.Pattern)) -and $frameResult.StdErr -match [regex]::Escape($frameCase.Pattern) -and
            @($frameJson.artifact_paths).Count -eq 0 -and @(Get-ChildItem -LiteralPath $frameTaskDir -Filter 'codex-*.md' -File -Force).Count -eq 0 -and
            $frameCleanupStateOk -and $framePlanHash -eq (Get-FileHash -LiteralPath $framePlanPath -Algorithm SHA256).Hash -and $framePlan -notmatch '(?m)^- invocation:') {
            Add-Check ("frame {0} fails closed before artifact/trace commit" -f $frameCase.Name)
        } else {
            Add-Failure ("frame {0} fail-closed contract failed: exit={1} request_residue={2} stdout=[{3}] stderr=[{4}]" -f $frameCase.Name,$frameResult.ExitCode,$frameRequestResidue.Count,$frameResult.StdOut,$frameResult.StdErr)
        }
        foreach ($residue in $frameRequestResidue) {
            try {
                [System.IO.File]::SetAttributes($residue.FullName, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($residue.FullName)
            } catch {
                Add-Failure ("frame {0} request residue cleanup failed: {1}" -f $frameCase.Name,$_.Exception.Message)
            }
        }
    }

    $taskC1 = 'skill-contract-c1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureC1 = New-TaskWorkspace -TaskId $taskC1 -PlanContent (New-PlanContent -TaskId $taskC1 -Stage 'PLAN' -Tool 'claudecode' -ExtraFrontmatter @('skills_dir: custom/ignored')) -Label 'c1'
    $workspaceC1 = $fixtureC1.WorkspaceRoot
    $taskC1Dir = $fixtureC1.TaskDirectory
    $userProfileC1 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-user-c1-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += @($workspaceC1, $userProfileC1)
    New-Item -ItemType Directory -Path $userProfileC1 -Force | Out-Null
    Write-MockCodexSkill -SkillRoot (Join-Path $workspaceC1 '.assistant\skills') -Marker 'project'
    Write-MockCodexSkill -SkillRoot (Join-Path $userProfileC1 '.codex\skills') -Marker 'user'
    $env:USERPROFILE = $userProfileC1
    $payloadC1 = '{"task":"Prefer project-level skill root"}'
    $c1Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskC1 -Stage 'PLAN' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceC1 -PayloadJson $payloadC1
    $c1Json = Assert-SingleLineJson -JsonText $c1Result.StdOut -Label 'C1'
    $c1Record = if ($null -ne $c1Json -and $c1Json.artifact_paths.Count -eq 1) { Read-FileUtf8 -Path $c1Json.artifact_paths[0] } else { '' }
    if ($c1Result.ExitCode -eq 0 -and
        $null -ne $c1Json -and
        $c1Json.ok -and
        $c1Record -match '"marker":"project"' -and
        $c1Result.StdErr -match 'task-level skills_dir is reserved in Phase 3 and ignored') {
        Add-Check 'C1 project-level skills override user-level and task-level skills_dir stays reserved'
    } else {
        Add-Failure ("C1 skill scope resolution failed, got stdout=[{0}] stderr=[{1}] record=[{2}]" -f $c1Result.StdOut, $c1Result.StdErr, $c1Record)
    }

    $taskC2 = 'skill-contract-c2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureC2 = New-TaskWorkspace -TaskId $taskC2 -PlanContent (New-PlanContent -TaskId $taskC2 -Stage 'PLAN' -Tool 'codex') -Label 'c2'
    $workspaceC2 = $fixtureC2.WorkspaceRoot
    $taskC2Dir = $fixtureC2.TaskDirectory
    $userProfileC2 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-user-c2-' + [guid]::NewGuid().ToString('N'))
    $cleanupPaths += @($workspaceC2, $userProfileC2)
    New-Item -ItemType Directory -Path $userProfileC2 -Force | Out-Null
    Write-MockCodexSkill -SkillRoot (Join-Path $userProfileC2 '.codex\skills') -Marker 'user'
    $env:USERPROFILE = $userProfileC2
    $payloadC2 = '{"task":"Use backend-aware codex user-level skill root"}'
    $c2Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskC2 -Stage 'PLAN' -Skill 'codex' -Tool 'codex' -WorkspaceRoot $workspaceC2 -PayloadJson $payloadC2
    $c2Json = Assert-SingleLineJson -JsonText $c2Result.StdOut -Label 'C2'
    $c2Record = if ($null -ne $c2Json -and $c2Json.artifact_paths.Count -eq 1) { Read-FileUtf8 -Path $c2Json.artifact_paths[0] } else { '' }
    if ($c2Result.ExitCode -eq 0 -and
        $null -ne $c2Json -and
        $c2Json.ok -and
        $c2Record -match '"marker":"user"' -and
        $c2Record -match '"task":"Use backend-aware codex user-level skill root"') {
        Add-Check 'C2 codex adapter resolves backend-aware user-level skills without project-level overrides'
    } else {
        Add-Failure ("C2 backend-aware codex fallback failed, got stdout=[{0}] stderr=[{1}] record=[{2}]" -f $c2Result.StdOut, $c2Result.StdErr, $c2Record)
    }

    $taskD3 = 'skill-contract-d3-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureD3 = New-TaskWorkspace -TaskId $taskD3 -PlanContent (New-PlanContent -TaskId $taskD3 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun) -Label 'd3'
    $workspaceD3 = $fixtureD3.WorkspaceRoot
    $taskD3Dir = $fixtureD3.TaskDirectory
    $cleanupPaths += $workspaceD3
    $planBeforeHashD3 = (Get-FileHash -LiteralPath (Join-Path $taskD3Dir 'plan.md') -Algorithm SHA256).Hash
    $d3Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskD3 -Stage 'PLAN_REVIEW' -Skill 'test-runner' -Tool 'codex' -WorkspaceRoot $workspaceD3
    $d3Json = Assert-SingleLineJson -JsonText $d3Result.StdOut -Label 'D3'
    $planAfterHashD3 = (Get-FileHash -LiteralPath (Join-Path $taskD3Dir 'plan.md') -Algorithm SHA256).Hash
    $d3Plan = Read-FileUtf8 -Path (Join-Path $taskD3Dir 'plan.md')
    $d3Validator = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskD3 -RepoRoot $workspaceD3
    if ($d3Result.ExitCode -ne 0 -and
        $null -ne $d3Json -and
        -not $d3Json.ok -and
        (($d3Json.errors -join ' ') -match 'whitelist') -and
        $planBeforeHashD3 -eq $planAfterHashD3 -and
        $d3Plan -notmatch '- invocation:' -and
        $d3Validator.ExitCode -eq 0) {
        Add-Check 'D3 rejected adapter path leaves plan.md unchanged (no invocation trace) even with a Run block'
    } else {
        Add-Failure ("D3 rejected-path trace suppression failed, got stdout=[{0}] stderr=[{1}] validator=[{2}]" -f $d3Result.StdOut, $d3Result.StdErr, $d3Validator.Text)
    }

    $taskD4 = 'skill-contract-d4-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskD4Dir = Join-Path $taskBase $taskD4
    $planD4Path = Join-Path $taskD4Dir 'plan.md'
    $vaultD4 = Join-Path $fixtureRoot '.assistant'
    $adapterWrapperD4 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-adapter-d4-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $advanceWrapperD4 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-advance-d4-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $cleanupPaths += @($vaultD4, $adapterWrapperD4, $advanceWrapperD4)
    New-Item -ItemType Directory -Path $taskD4Dir -Force | Out-Null
    New-Item -ItemType Directory -Path $vaultD4 -Force | Out-Null
    Write-MockCodexSkill -SkillRoot (Join-Path $fixtureRoot '.assistant\skills') -Marker 'd4-lock'
    Write-Utf8Bom -Path $planD4Path -Content (New-PlanContent -TaskId $taskD4 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun)
    $eventIdD4 = [guid]::NewGuid().ToString('N')
    $readyNameD4 = 'dev-harness.skill-contract.d4.ready.' + $eventIdD4
    $releaseNameD4 = 'dev-harness.skill-contract.d4.release.' + $eventIdD4
    $createdD4 = $false
    $readyEventD4 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $readyNameD4, [ref]$createdD4)
    $releaseEventD4 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $releaseNameD4, [ref]$createdD4)
    Write-Utf8Bom -Path $adapterWrapperD4 -Content @"
& '$adapterPath' -TaskId '$taskD4' -Stage 'PLAN_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot '$fixtureRoot' -PayloadJson '{"task":"barrier=$readyNameD4|$releaseNameD4"}'
exit `$LASTEXITCODE
"@
    Write-Utf8Bom -Path $advanceWrapperD4 -Content @"
`$ErrorActionPreference = 'Stop'
try {
    & '$advancePath' -TaskId '$taskD4' -ExpectedStage 'PLAN_REVIEW' -VaultRoot '$vaultD4' -RepoRoot '$fixtureRoot' -WorkspaceRoot '$fixtureRoot'
    exit 0
} catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    exit 1
}
"@

    . $liteParserPath
    $planMutexCommand = Get-Command -Name Get-LitePlanMutexName -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $planMutexCommand) {
        Add-Failure 'D4 canonical plan mutex helper Get-LitePlanMutexName is missing'
    } else {
        $planMutex = New-Object System.Threading.Mutex($false, (Get-LitePlanMutexName -TaskId $taskD4))
        $hasPlanMutex = $false
        $adapterCapture = $null
        $advanceCapture = $null
        try {
            try {
                $hasPlanMutex = $planMutex.WaitOne(5000)
            } catch [System.Threading.AbandonedMutexException] {
                $hasPlanMutex = $true
            }
            if (-not $hasPlanMutex) {
                Add-Failure 'D4 failed to acquire the canonical plan mutex for forced interleaving'
            } else {
                $adapterCapture = Start-PowerShellWithStreams -ScriptPath $adapterWrapperD4
                $advanceCapture = Start-PowerShellWithStreams -ScriptPath $advanceWrapperD4
                $cleanupPaths += @($adapterCapture.StreamRoot, $advanceCapture.StreamRoot)
                Start-Sleep -Milliseconds 500
                $planWhileHeld = Read-FileUtf8 -Path $planD4Path
                if (-not $readyEventD4.WaitOne(0) -and
                    -not $adapterCapture.Process.HasExited -and
                    -not $advanceCapture.Process.HasExited -and
                    $planWhileHeld -match '(?m)^stage: PLAN_REVIEW\s*$' -and
                    $planWhileHeld -notmatch '(?m)^- invocation:' -and
                    @(Get-ChildItem -LiteralPath $taskD4Dir -Filter 'codex-*.md' -File -Force).Count -eq 0) {
                    Add-Check 'D4 TaskId plan mutex blocks adapter backend and stage advance before release'
                } else {
                    Add-Failure ("D4 initial mutex boundary failed: backend_started={0} adapter_exited={1} advance_exited={2}" -f `
                        $readyEventD4.WaitOne(0),
                        $adapterCapture.Process.HasExited,
                        $advanceCapture.Process.HasExited)
                }
            }
        } finally {
            if ($hasPlanMutex) {
                $planMutex.ReleaseMutex() | Out-Null
            }
            $planMutex.Dispose()
        }

        if ($null -ne $adapterCapture -and $null -ne $advanceCapture) {
            for ($attempt = 0; $attempt -lt 100; $attempt++) {
                if ($readyEventD4.WaitOne(100) -or ($adapterCapture.Process.HasExited -and $advanceCapture.Process.HasExited)) {
                    break
                }
            }
            $releaseEventD4.Set() | Out-Null
            $adapterD4 = Complete-PowerShellWithStreams -Capture $adapterCapture
            $advanceD4 = Complete-PowerShellWithStreams -Capture $advanceCapture
            $adapterJsonD4 = Assert-SingleLineJson -JsonText $adapterD4.StdOut -Label 'D4 adapter'
            $finalPlanD4 = Read-FileUtf8 -Path $planD4Path
            $validatorD4 = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskD4 -RepoRoot $fixtureRoot
            $traceCountD4 = [regex]::Matches($finalPlanD4, '(?m)^- invocation: skill=codex mode=adapter tool=codex ok=True status=delegated\s*$').Count
            $artifactsD4 = @(Get-ChildItem -LiteralPath $taskD4Dir -Filter 'codex-*.md' -File -Force)
            $adapterWonD4 = $adapterD4.ExitCode -eq 0 -and $null -ne $adapterJsonD4 -and $adapterJsonD4.ok -and $artifactsD4.Count -eq 1 -and $traceCountD4 -eq 1
            $advanceWonD4 = $adapterD4.ExitCode -ne 0 -and $null -ne $adapterJsonD4 -and -not $adapterJsonD4.ok -and $artifactsD4.Count -eq 0 -and $traceCountD4 -eq 0
            if ($adapterD4.Completed -and
                $advanceD4.Completed -and
                $advanceD4.ExitCode -eq 0 -and
                $finalPlanD4 -match '(?m)^stage: IMPLEMENT\s*$' -and
                $validatorD4.ExitCode -eq 0 -and
                ($adapterWonD4 -or $advanceWonD4)) {
                Add-Check 'D4 release serializes adapter publish or stage advance without a lost update'
            } else {
                Add-Failure ("D4 serialized writers failed after release: adapter_exit={0} advance_exit={1} artifacts={2} trace_count={3} advance_stdout=[{4}] advance_stderr=[{5}] validator=[{6}]" -f `
                    $adapterD4.ExitCode,
                    $advanceD4.ExitCode,
                    $artifactsD4.Count,
                    $traceCountD4,
                    $advanceD4.StdOut,
                    $advanceD4.StdErr,
                    $validatorD4.Text)
            }
        }
        $readyEventD4.Dispose()
        $releaseEventD4.Dispose()
    }

    $taskD5 = 'skill-contract-d5-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $fixtureD5 = New-TaskWorkspace -TaskId $taskD5 -PlanContent (New-PlanContent -TaskId $taskD5 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun) -Label 'd5'
    $workspaceD5 = $fixtureD5.WorkspaceRoot
    $cleanupPaths += $workspaceD5
    $abandonedMutexD5 = New-AbandonedNamedMutex -HostPath $ownerHost -FixturePath $mutexAbandonFixturePath -MutexName (Get-LitePlanMutexName -TaskId $taskD5) -Label 'D5 abandoned mutex fixture'
    try {
        $d5Result = Invoke-Adapter -AdapterPath $adapterPath -TaskId $taskD5 -Stage 'PLAN_REVIEW' -Skill 'review' -Tool 'codex' -WorkspaceRoot $workspaceD5
    } finally {
        $abandonedMutexD5.Dispose()
    }
    $d5Json = Assert-SingleLineJson -JsonText $d5Result.StdOut -Label 'D5'
    $d5Plan = Read-FileUtf8 -Path (Join-Path $fixtureD5.TaskDirectory 'plan.md')
    if ($d5Result.ExitCode -ne 0 -and
        $null -ne $d5Json -and -not $d5Json.ok -and $d5Json.status -eq 'rejected' -and
        (($d5Json.errors -join ' ') -match 'whitelist') -and
        $d5Plan -notmatch '(?m)^- invocation:') {
        Add-Check 'D5 adapter recovers an abandoned shared plan mutex before rejecting a retired skill'
    } else {
        Add-Failure ("D5 abandoned adapter mutex recovery failed: exit={0} stdout=[{1}] stderr=[{2}]" -f $d5Result.ExitCode, $d5Result.StdOut, $d5Result.StdErr)
    }

    $taskD6 = 'skill-contract-d6-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskD6Dir = Join-Path $taskBase $taskD6
    $vaultD6 = Join-Path $fixtureRoot '.assistant'
    $wrapperD6 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-advance-d6-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $cleanupPaths += @($vaultD6, $wrapperD6)
    New-Item -ItemType Directory -Path $taskD6Dir -Force | Out-Null
    New-Item -ItemType Directory -Path $vaultD6 -Force | Out-Null
    Write-Utf8Bom -Path (Join-Path $taskD6Dir 'plan.md') -Content (New-PlanContent -TaskId $taskD6 -Stage 'PLAN_REVIEW' -Tool 'codex' -IncludePlanReviewRun)
    Write-Utf8Bom -Path $wrapperD6 -Content @"
`$ErrorActionPreference = 'Stop'
try {
    & '$advancePath' -TaskId '$taskD6' -ExpectedStage 'PLAN_REVIEW' -VaultRoot '$vaultD6' -RepoRoot '$fixtureRoot' -WorkspaceRoot '$fixtureRoot'
    exit 0
} catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    exit 1
}
"@
    $abandonedMutexD6 = New-AbandonedNamedMutex -HostPath $ownerHost -FixturePath $mutexAbandonFixturePath -MutexName (Get-LitePlanMutexName -TaskId $taskD6) -Label 'D6 abandoned mutex fixture'
    try {
        $d6Result = Invoke-PowerShellWithStreams -Arguments @('-NoProfile', '-File', $wrapperD6)
    } finally {
        $abandonedMutexD6.Dispose()
    }
    $d6Plan = Read-FileUtf8 -Path (Join-Path $taskD6Dir 'plan.md')
    if ($d6Result.ExitCode -eq 0 -and $d6Plan -match '(?m)^stage: IMPLEMENT\s*$') {
        Add-Check 'D6 stage advance recovers an abandoned shared plan mutex on its first attempt'
    } else {
        Add-Failure ("D6 abandoned advance mutex recovery failed: exit={0} stdout=[{1}] stderr=[{2}]" -f $d6Result.ExitCode, $d6Result.StdOut, $d6Result.StdErr)
    }

    $lockD7A = $null
    $lockD7B = $null
    try {
        $lockD7A = Enter-LitePlanMutex -TaskId ('skill-contract-d7-a-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $lockD7B = Enter-LitePlanMutex -TaskId ('skill-contract-d7-b-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) -TimeoutMilliseconds 0
        $runtimeMutexName = Get-CanonicalRuntimeMutexName
        $planMutexParameters = (Get-Command Get-LitePlanMutexName -CommandType Function).Parameters
        if ($runtimeMutexName -ceq 'Global\dev-harness.runtime' -and
            $planMutexParameters.ContainsKey('TaskId') -and
            -not $planMutexParameters.ContainsKey('PlanPath')) {
            Add-Check 'D7 different TaskIds can hold plan locks concurrently while path aliases cannot split plan/runtime identities'
        } else {
            Add-Failure 'D7 runtime path aliases produced different mutex identities'
        }
    } catch {
        Add-Failure ("D7 mutex identity contract failed: {0}" -f $_.Exception.Message)
    } finally {
        Exit-LitePlanMutex -Mutex $lockD7B
        Exit-LitePlanMutex -Mutex $lockD7A
    }

    $taskD8 = 'skill-contract-d8-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskD8Dir = Join-Path $taskBase $taskD8
    $planD8Path = Join-Path $taskD8Dir 'plan.md'
    $vaultD8 = Join-Path $fixtureRoot '.assistant'
    $wrapperD8 = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-contract-adapter-d8-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $cleanupPaths += @($vaultD8, $wrapperD8)
    New-Item -ItemType Directory -Path $taskD8Dir -Force | Out-Null
    New-Item -ItemType Directory -Path $vaultD8 -Force | Out-Null
    Write-MockCodexSkill -SkillRoot (Join-Path $fixtureRoot '.assistant\skills') -Marker 'd8-aba'
    $planD8 = New-PlanContent -TaskId $taskD8 -Stage 'CODE_REVIEW' -Tool 'codex' -IncludePlanReviewRun
    $planD8Tail = @"
## Implementation Notes
### Run 1 · 2026-04-25 10:03 · runner: harness-implementer
- changed: baseline before review
- tests: fixture
- risks: none
- next: CODE_REVIEW

## Code Review
### Run 1 · 2026-04-25 10:05 · runner: harness-reviewer
- verdict: revise
- findings:
  - P1: refresh implementation evidence
- next: IMPLEMENT
"@
    $planD8 = [regex]::Replace($planD8, '(?ms)^## Implementation Notes\s*.*\z', $planD8Tail)
    Write-Utf8Bom -Path $planD8Path -Content $planD8
    $eventIdD8 = [guid]::NewGuid().ToString('N')
    $readyNameD8 = 'dev-harness.skill-contract.d8.ready.' + $eventIdD8
    $releaseNameD8 = 'dev-harness.skill-contract.d8.release.' + $eventIdD8
    $createdD8 = $false
    $readyEventD8 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $readyNameD8, [ref]$createdD8)
    $releaseEventD8 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $releaseNameD8, [ref]$createdD8)
    Write-Utf8Bom -Path $wrapperD8 -Content @"
& '$adapterPath' -TaskId '$taskD8' -Stage 'CODE_REVIEW' -Skill 'codex' -Tool 'codex' -WorkspaceRoot '$fixtureRoot' -PayloadJson '{"task":"barrier=$readyNameD8|$releaseNameD8"}'
exit `$LASTEXITCODE
"@
    $captureD8 = Start-PowerShellWithStreams -ScriptPath $wrapperD8
    $cleanupPaths += $captureD8.StreamRoot
    $backendReadyD8 = $readyEventD8.WaitOne(10000)
    $advanceD8ToImplement = [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'backend did not start' }
    $advanceD8ToReview = [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'backend did not start' }
    try {
        if ($backendReadyD8) {
            $advanceD8ToImplement = Invoke-PowerShellWithStreams -Arguments @(
                '-NoProfile', '-File', $advancePath,
                '-TaskId', $taskD8, '-ExpectedStage', 'CODE_REVIEW',
                '-VaultRoot', $vaultD8, '-RepoRoot', $fixtureRoot, '-WorkspaceRoot', $fixtureRoot
            )
            if ($advanceD8ToImplement.ExitCode -eq 0) {
                $freshImplementation = @"
### Run 2 · 2026-04-25 10:10 · runner: harness-implementer
- changed: addressed review finding
- tests: fixture
- risks: none
- next: CODE_REVIEW

"@
                $planMutationMutexD8 = Enter-LitePlanMutex -TaskId $taskD8
                try {
                    $implementPlanD8 = Read-FileUtf8 -Path $planD8Path
                    $implementPlanD8 = $implementPlanD8 -replace '(?m)^## Code Review\s*$', ($freshImplementation + '## Code Review')
                    Write-LiteUtf8BomAtomic -Path $planD8Path -Content $implementPlanD8
                } finally {
                    Exit-LitePlanMutex -Mutex $planMutationMutexD8
                }
                $advanceD8ToReview = Invoke-PowerShellWithStreams -Arguments @(
                    '-NoProfile', '-File', $advancePath,
                    '-TaskId', $taskD8, '-ExpectedStage', 'IMPLEMENT',
                    '-VaultRoot', $vaultD8, '-RepoRoot', $fixtureRoot, '-WorkspaceRoot', $fixtureRoot
                )
            }
        }
    } finally {
        $releaseEventD8.Set() | Out-Null
    }
    $adapterD8 = Complete-PowerShellWithStreams -Capture $captureD8
    $adapterJsonD8 = Assert-SingleLineJson -JsonText $adapterD8.StdOut -Label 'D8 adapter'
    $finalPlanD8 = Read-FileUtf8 -Path $planD8Path
    $artifactsD8 = @(Get-ChildItem -LiteralPath $taskD8Dir -Filter 'codex-*.md' -File -Force)
    $traceCountD8 = [regex]::Matches($finalPlanD8, '(?m)^- invocation:').Count
    $validatorD8 = Invoke-Validator -ValidatorPath $validatorPath -TaskId $taskD8 -RepoRoot $fixtureRoot
    if ($backendReadyD8 -and
        $advanceD8ToImplement.ExitCode -eq 0 -and
        $advanceD8ToReview.ExitCode -eq 0 -and
        $adapterD8.ExitCode -ne 0 -and
        $null -ne $adapterJsonD8 -and
        -not $adapterJsonD8.ok -and
        $adapterJsonD8.status -eq 'error' -and
        $adapterJsonD8.artifact_paths.Count -eq 0 -and
        (($adapterJsonD8.errors -join ' ') -match 'generation changed') -and
        $finalPlanD8 -match '(?m)^stage: CODE_REVIEW\s*$' -and
        $artifactsD8.Count -eq 0 -and
        $traceCountD8 -eq 0 -and
        $validatorD8.ExitCode -eq 0) {
        Add-Check 'D8 CODE_REVIEW -> IMPLEMENT -> CODE_REVIEW ABA rejects the stale backend with one error JSON line and zero artifact/trace'
    } else {
        Add-Failure ("D8 same-stage ABA guard failed: ready={0} to_implement={1} to_review={2} adapter_exit={3} artifacts={4} traces={5} stdout=[{6}] stderr=[{7}] validator=[{8}]" -f `
            $backendReadyD8,
            $advanceD8ToImplement.ExitCode,
            $advanceD8ToReview.ExitCode,
            $adapterD8.ExitCode,
            $artifactsD8.Count,
            $traceCountD8,
            $adapterD8.StdOut,
            $adapterD8.StdErr,
            $validatorD8.Text)
    }
    $readyEventD8.Dispose()
    $releaseEventD8.Dispose()

    $taskE1 = 'skill-contract-e1-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskE1Dir = Join-Path $taskBase $taskE1
    New-Item -ItemType Directory -Path $taskE1Dir -Force | Out-Null
    $e1Result = Invoke-GenerateSkillsIndex -ScriptPath $skillsIndexPath -TaskId $taskE1 -Stage 'TEST' -BackendHint 'kimi' -RepoRoot $fixtureRoot
    $skillsIndexDoc = Read-FileUtf8 -Path (Join-Path $taskE1Dir 'skills-index.md')
    if ($e1Result.ExitCode -eq 0 -and
        $skillsIndexDoc -match '^<!-- generated at ' -and
        $skillsIndexDoc -match '# Skills available at TEST \(backend hint: kimi\)' -and
        $skillsIndexDoc -match '\*\*test\*\*' -and
        $skillsIndexDoc -notmatch '\*\*test-runner\*\*') {
        Add-Check 'E1 generate-skills-index emits workflow-backed markdown with skill descriptions'
    } else {
        Add-Failure ("E1 generate-skills-index failed, got output=[{0}] doc=[{1}]" -f $e1Result.Text, $skillsIndexDoc)
    }

    $taskE2 = 'skill-contract-e2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskE2Dir = Join-Path $taskBase $taskE2
    New-Item -ItemType Directory -Path $taskE2Dir -Force | Out-Null
    $e2Result = Invoke-GenerateSkillsIndex -ScriptPath $skillsIndexPath -TaskId $taskE2 -Stage 'PLAN' -BackendHint 'codex' -RepoRoot $fixtureRoot
    $planSkillsIndexDoc = Read-FileUtf8 -Path (Join-Path $taskE2Dir 'skills-index.md')
    if ($e2Result.ExitCode -eq 0 -and
        $planSkillsIndexDoc -match '# Skills available at PLAN \(backend hint: codex\)' -and
        $planSkillsIndexDoc -match '\*\*plan\*\*' -and
        $planSkillsIndexDoc -match '\*\*entry-router\*\*' -and
        $planSkillsIndexDoc -match 'V1 compatibility entry router' -and
        $planSkillsIndexDoc -notmatch '\*\*using-superpowers\*\*') {
        Add-Check 'E2 PLAN skills-index exposes the v1 compatibility entry-router without using-superpowers'
    } else {
        Add-Failure ("E2 PLAN skills-index should expose the v1 compatibility entry-router and not using-superpowers, got output=[{0}] doc=[{1}]" -f $e2Result.Text, $planSkillsIndexDoc)
    }
    $lifecycleAssertionsPassed = $script:Failures.Count -eq 0
} finally {
    $env:USERPROFILE = $originalUserProfile
    if (-not $lifecycleAssertionsPassed) {
        foreach ($identity in $cleanupIdentities) {
            Stop-LifecycleProcess -ProcessId $identity.Id -StartTicks $identity.Ticks -Label $identity.Label
        }
    }
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
