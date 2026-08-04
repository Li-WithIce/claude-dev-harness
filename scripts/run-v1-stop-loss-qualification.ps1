[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('formal','test-only','diagnostic-smoke')][string]$ProducerMode = 'formal',
    [ValidateSet('','environment-v1-new-task','disable-v2-new-task','existing-v1-artifact','existing-v2-artifact','lifecycle','cleanup')][string]$TestFailureProbe = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not [string]::IsNullOrWhiteSpace($TestFailureProbe) -and $ProducerMode -cne 'test-only') { throw 'TestFailureProbe requires ProducerMode test-only' }

$rolloutModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
$atomicModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Force -PassThru -ErrorAction Stop
$powerShellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
$paths = [ordered]@{
    producer = [IO.Path]::GetFullPath($PSCommandPath)
    task_entry = Join-Path $RepoRoot 'scripts\task.ps1'
    advance_stage = Join-Path $RepoRoot 'scripts\advance-stage.ps1'
    protocol_module = Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1'
    task_state_module = Join-Path $RepoRoot 'scripts\lib\Harness.TaskState.psm1'
    atomic_write = Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1'
    path = Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1'
    schema = Join-Path $RepoRoot 'schemas\v1-stop-loss-report.schema.json'
}
foreach ($path in $paths.Values) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required v1 stop-loss input is missing: $path" } }
if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { throw 'USERPROFILE is required for v1 stop-loss qualification' }
$mainUserProfile = [IO.Path]::GetFullPath($env:USERPROFILE)

function Get-V1StopLossBytesDigest {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-V1StopLossTextDigest {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-V1StopLossBytesDigest -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Get-V1StopLossFileDigest {
    param([Parameter(Mandatory)][string]$Path)
    return Get-V1StopLossBytesDigest -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Get-V1StopLossFileSnapshot {
    param([Parameter(Mandatory)][string[]]$Paths)
    $snapshot = [ordered]@{}
    foreach ($path in @($Paths | Sort-Object -Unique)) {
        $full = [IO.Path]::GetFullPath($path)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            $snapshot[$full] = "file|$([long]$item.Length)|$(Get-V1StopLossFileDigest -Path $full)"
        } elseif (Test-Path -LiteralPath $full) { $snapshot[$full] = 'non-file' }
        else { $snapshot[$full] = 'missing' }
    }
    return $snapshot
}

function Test-V1StopLossSnapshotEqual {
    param([Parameter(Mandatory)][Collections.IDictionary]$Left,[Parameter(Mandatory)][Collections.IDictionary]$Right)
    if (@(Compare-Object @($Left.Keys | Sort-Object) @($Right.Keys | Sort-Object)).Count -ne 0) { return $false }
    foreach ($path in $Left.Keys) { if ([string]$Left[$path] -cne [string]$Right[$path]) { return $false } }
    return $true
}

function Get-V1StopLossTreeSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    $snapshot = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $snapshot }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Force -File -Recurse -ErrorAction Stop | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Root,$file.FullName).Replace('\','/')
        $snapshot[$relative] = Get-V1StopLossFileDigest -Path $file.FullName
    }
    return $snapshot
}

function Get-V1StopLossUnexpectedWriteCount {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Before,
        [Parameter(Mandatory)][Collections.IDictionary]$After,
        [string[]]$Allowed = @()
    )
    $allowedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Allowed) { [void]$allowedSet.Add($path.Replace('\','/')) }
    $names = @(@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)
    return [long]@($names | Where-Object {
        if ($allowedSet.Contains([string]$_)) { return $false }
        return -not $Before.Contains($_) -or -not $After.Contains($_) -or [string]$Before[$_] -cne [string]$After[$_]
    }).Count
}

function Join-V1StopLossOutputBytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$StdOut,[Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$StdErr)
    $stream = [IO.MemoryStream]::new()
    try { $stream.Write($StdOut,0,$StdOut.Length); $stream.WriteByte(0); $stream.Write($StdErr,0,$StdErr.Length); return $stream.ToArray() }
    finally { $stream.Dispose() }
}

function Invoke-V1StopLossProcess {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ProfileRoot,
        [AllowNull()][string]$Protocol
    )
    $stdout = [IO.MemoryStream]::new(); $stderr = [IO.MemoryStream]::new(); $process = [Diagnostics.Process]::new()
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $powerShellPath
        $startInfo.WorkingDirectory = $RepoRoot
        $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true; $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
        $startInfo.Environment['USERPROFILE'] = $ProfileRoot
        $startInfo.Environment['CODEX_HOME'] = Join-Path $ProfileRoot '.codex'
        foreach ($name in @('HARNESS_PROTOCOL','HOST_BENCHMARK_CODEX_HOME','HARNESS_V2_ELIGIBILITY_REPORT','DEV_HARNESS_WORKSPACE_ROOT','WORKSPACE_ROOT','OBSIDIAN_VAULT','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_API_KEY')) { [void]$startInfo.Environment.Remove($name) }
        if ($null -ne $Protocol) { $startInfo.Environment['HARNESS_PROTOCOL'] = $Protocol }
        foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$ScriptPath) + $Arguments) { [void]$startInfo.ArgumentList.Add([string]$argument) }
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'v1 stop-loss child process did not start' }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout); $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        if (-not $process.WaitForExit(90000)) { $process.Kill($true); throw 'v1 stop-loss child process timed out' }
        [Threading.Tasks.Task]::WaitAll(@($stdoutTask,$stderrTask))
        $stdoutBytes = $stdout.ToArray(); $stderrBytes = $stderr.ToArray()
        $document = $null
        if ($process.ExitCode -eq 0 -and $stdoutBytes.Length -gt 0) {
            try { $document = [Text.UTF8Encoding]::new($false,$true).GetString($stdoutBytes).Trim() | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -ErrorAction Stop } catch { $document = $null }
        }
        return [ordered]@{exit_code=[long]$process.ExitCode;stdout=$stdoutBytes;stderr=$stderrBytes;output=(Join-V1StopLossOutputBytes -StdOut $stdoutBytes -StdErr $stderrBytes);document=$document}
    } catch {
        $errorBytes = [Text.UTF8Encoding]::new($false).GetBytes('child-process-failure')
        return [ordered]@{exit_code=70L;stdout=[byte[]]@();stderr=$errorBytes;output=(Join-V1StopLossOutputBytes -StdOut ([byte[]]@()) -StdErr $errorBytes);document=$null}
    } finally { $process.Dispose(); $stdout.Dispose(); $stderr.Dispose() }
}

function Write-V1StopLossBomText {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($true))
}

function New-V1StopLossPlanText {
    param([Parameter(Mandatory)][string]$TaskId)
    return @"
---
task_id: $TaskId
stage: PLAN
tool: codex
updated: 2026-08-04
---
# V1 Stop-loss Qualification

## Clarification
- 验收标准: isolated v1 task reaches DONE through every canonical stage.
- 非目标: no product behavior.
- 受影响目录: isolated fixture only.
- 回滚策略: delete the isolated fixture.
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- exercise the frozen v1 stage path.

## Verification
- ``pwsh -NoProfile -File scripts/advance-stage.ps1``

## Risks
- isolated fixture only.

## Plan Review

## Implementation Notes

## Code Review

"@
}

function Set-V1StopLossPlanSection {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$NextName,[Parameter(Mandatory)][string]$Body)
    $text = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    $pattern = "(?ms)^## $([regex]::Escape($Name))\s*.*?(?=^## $([regex]::Escape($NextName))\s*)"
    $updated = [regex]::Replace($text,$pattern,("## {0}`r`n`r`n{1}`r`n`r`n" -f $Name,$Body),1)
    if ($updated -ceq $text) { throw "v1 stop-loss section replacement failed: $Name" }
    Write-V1StopLossBomText -Path $Path -Content $updated
}

function Get-V1StopLossPlanStage {
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    $match = [regex]::Match($text,'(?m)^stage:\s*(PLAN|PLAN_REVIEW|IMPLEMENT|CODE_REVIEW|TEST|DONE)\s*$')
    return $(if ($match.Success) { $match.Groups[1].Value } else { $null })
}

function New-V1StopLossV2TaskDocument {
    param([Parameter(Mandatory)][string]$TaskId)
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    return [ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='ready';identity='existing';intent='write';requirement_state='clear';execution_profile='direct';persistence='ephemeral';policies=[ordered]@{plan_required=$false;approval_required=$false;rollback_required=$false;independent_review_required=$false;verification_required=$true};created_at=$now;updated_at=$now}
}

function New-V1StopLossNotRunProbe {
    param([string]$Name,[string]$Requested,[string]$WriteKind)
    return [ordered]@{probe=$Name;status='not_run';exit_code=$null;requested_protocol=$Requested;detected_protocol=$null;selected_protocol=$null;preference_source=$null;reason_code='not-run';expected_write_kind=$WriteKind;unexpected_writes=0L;artifact_digest_before=$null;artifact_digest_after=$null;command_digest=(Get-V1StopLossTextDigest -Text "task.ps1|$Name");output_digest=(Get-V1StopLossBytesDigest -Bytes ([byte[]]@()))}
}

function New-V1StopLossProbeRecord {
    param(
        [string]$Name,[string]$Requested,[string]$WriteKind,[Collections.IDictionary]$ProcessResult,[Collections.IDictionary]$Expected,
        [long]$UnexpectedWrites,[AllowNull()][object]$ArtifactBefore,[AllowNull()][object]$ArtifactAfter,[string]$CommandIdentity
    )
    $document = $ProcessResult.document
    $matches = $ProcessResult.exit_code -eq 0 -and $null -ne $document -and [string]$document.detected_protocol -ceq [string]$Expected.detected_protocol -and
        [string]$document.selected_protocol -ceq [string]$Expected.selected_protocol -and [string]$document.preference_source -ceq [string]$Expected.preference_source -and
        [string]$document.reason -ceq [string]$Expected.reason_code -and $UnexpectedWrites -eq 0
    if ([bool]$Expected.existing_artifact) { $matches = $matches -and $null -ne $ArtifactBefore -and [string]$ArtifactBefore -ceq [string]$ArtifactAfter }
    else { $matches = $matches -and $null -eq $ArtifactBefore -and $null -eq $ArtifactAfter }
    if ($TestFailureProbe -ceq $Name) { $matches = $false }
    $exitCode = if ($matches) { 0L } elseif ($ProcessResult.exit_code -ne 0) { [long]$ProcessResult.exit_code } else { 86L }
    return [ordered]@{
        probe=$Name;status=$(if($matches){'pass'}else{'fail'});exit_code=$exitCode;requested_protocol=$Requested
        detected_protocol=$(if($null-ne$document){[string]$document.detected_protocol}else{$null});selected_protocol=$(if($null-ne$document){[string]$document.selected_protocol}else{$null})
        preference_source=$(if($null-ne$document){[string]$document.preference_source}else{$null});reason_code=$(if($null-ne$document-and[string]$document.reason-match'^[a-z0-9][a-z0-9-]{0,127}$'){[string]$document.reason}else{'probe-result-invalid'})
        expected_write_kind=$WriteKind;unexpected_writes=$UnexpectedWrites;artifact_digest_before=$ArtifactBefore;artifact_digest_after=$ArtifactAfter
        command_digest=(Get-V1StopLossTextDigest -Text $CommandIdentity);output_digest=(Get-V1StopLossBytesDigest -Bytes ([byte[]]$ProcessResult.output))
    }
}

function Invoke-V1StopLossLifecycle {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ProfileRoot)
    $taskId = 'v1-stop-loss-lifecycle'
    $planPath = Join-Path $WorkspaceRoot "docs\tasks\$taskId\plan.md"
    $testPath = Join-Path $WorkspaceRoot "docs\tasks\$taskId\test.md"
    try {
        Write-V1StopLossBomText -Path $planPath -Content (New-V1StopLossPlanText -TaskId $taskId)
        $planBefore = Get-V1StopLossFileDigest -Path $planPath
        $treeBefore = Get-V1StopLossTreeSnapshot -Root $WorkspaceRoot
        $sequence = [Collections.Generic.List[string]]::new(); $sequence.Add('PLAN')
        $transitionCount = 0L
        $baseArguments = @('-TaskId',$taskId,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$WorkspaceRoot,'-VaultRoot',(Join-Path $WorkspaceRoot '.assistant'))
        foreach ($stage in @('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST')) {
            if ($stage -ceq 'PLAN_REVIEW') {
                Set-V1StopLossPlanSection -Path $planPath -Name 'Plan Review' -NextName 'Implementation Notes' -Body "### Run 1 · 2026-08-04 00:00 · runner: qualification`r`n- verdict: pass`r`n- findings: none`r`n- next: IMPLEMENT"
            } elseif ($stage -ceq 'IMPLEMENT') {
                Set-V1StopLossPlanSection -Path $planPath -Name 'Implementation Notes' -NextName 'Code Review' -Body "### Run 1 · 2026-08-04 00:01 · runner: qualification`r`n- changed: isolated fixture only`r`n- tests: v1 stage transition`r`n- risks: none`r`n- next: CODE_REVIEW"
            } elseif ($stage -ceq 'CODE_REVIEW') {
                $text = [IO.File]::ReadAllText($planPath,[Text.UTF8Encoding]::new($false,$true))
                $updated = [regex]::Replace($text,'(?ms)^## Code Review\s*\z',"## Code Review`r`n`r`n### Run 1 · 2026-08-04 00:02 · runner: qualification`r`n- verdict: pass`r`n- findings: none`r`n- next: TEST`r`n")
                if ($updated -ceq $text) { throw 'v1 stop-loss Code Review update failed' }
                Write-V1StopLossBomText -Path $planPath -Content $updated
            } elseif ($stage -ceq 'TEST') {
                Write-V1StopLossBomText -Path $testPath -Content @"
# Test Report

## Summary
- isolated v1 stop-loss lifecycle.

## Scope
- isolated v1 task.

## Inputs Reviewed
- plan.md

## Test Approach
- execute the canonical v1 stage command.

## Findings
- none.

## Evidence
- command: run-v1-stop-loss-qualification
- exit_code: 0
- executed_at: 2026-08-04T00:03:00+00:00
- revision: 0000000
- evidence_path: docs/tasks/$taskId/test.md

## Risks / Gaps
- isolated fixture only.

## Conclusion
pass

## Handoff
- delivery: fixture complete
- follow_up: none
"@
            }
            $process = Invoke-V1StopLossProcess -ScriptPath $paths.advance_stage -Arguments (@('-ExpectedStage',$stage) + $baseArguments) -WorkspaceRoot $WorkspaceRoot -ProfileRoot $ProfileRoot -Protocol 'v1'
            if ($process.exit_code -ne 0) { throw 'v1 stop-loss lifecycle transition failed' }
            $transitionCount++
            $nextStage = Get-V1StopLossPlanStage -Path $planPath
            if ([string]::IsNullOrWhiteSpace($nextStage)) { throw 'v1 stop-loss lifecycle stage is unavailable' }
            $sequence.Add($nextStage)
        }
        $treeAfter = Get-V1StopLossTreeSnapshot -Root $WorkspaceRoot
        $allowed = @($treeAfter.Keys | Where-Object { $_ -like "docs/tasks/$taskId/*" -or $_ -like '.assistant/*' })
        $unexpected = Get-V1StopLossUnexpectedWriteCount -Before $treeBefore -After $treeAfter -Allowed $allowed
        $passed = $transitionCount -eq 5 -and ($sequence -join '>') -ceq 'PLAN>PLAN_REVIEW>IMPLEMENT>CODE_REVIEW>TEST>DONE' -and $unexpected -eq 0 -and $TestFailureProbe -cne 'lifecycle'
        return [ordered]@{status=$(if($passed){'pass'}else{'fail'});initial_stage='PLAN';final_stage=[string]$sequence[$sequence.Count-1];stage_sequence=@($sequence);transition_count=$transitionCount;plan_digest_before=$planBefore;plan_digest_after=(Get-V1StopLossFileDigest -Path $planPath);test_report_digest=(Get-V1StopLossFileDigest -Path $testPath);unexpected_writes=$unexpected;reason=$(if($passed){'lifecycle-pass'}else{'lifecycle-failure'})}
    } catch {
        $stage = $(if(Test-Path -LiteralPath $planPath -PathType Leaf){Get-V1StopLossPlanStage -Path $planPath}else{$null})
        return [ordered]@{status='fail';initial_stage=$(if($null-ne$stage){'PLAN'}else{$null});final_stage=$stage;stage_sequence=$(if($null-ne$stage){@('PLAN')}else{@()});transition_count=0L;plan_digest_before=$(if(Test-Path -LiteralPath $planPath -PathType Leaf){Get-V1StopLossFileDigest -Path $planPath}else{$null});plan_digest_after=$(if(Test-Path -LiteralPath $planPath -PathType Leaf){Get-V1StopLossFileDigest -Path $planPath}else{$null});test_report_digest=$(if(Test-Path -LiteralPath $testPath -PathType Leaf){Get-V1StopLossFileDigest -Path $testPath}else{$null});unexpected_writes=1L;reason='lifecycle-failure'}
    }
}

$protectedRoots = [Collections.Generic.List[string]]::new()
foreach ($root in @((Join-Path $mainUserProfile '.codex'),(Join-Path $mainUserProfile '.claude'),(Join-Path $mainUserProfile '.agents'),(Join-Path $mainUserProfile '.dev-harness'))) { $protectedRoots.Add([IO.Path]::GetFullPath($root)) }
$codexRoots = [Collections.Generic.List[string]]::new(); $codexRoots.Add([IO.Path]::GetFullPath((Join-Path $mainUserProfile '.codex')))
foreach ($name in @('CODEX_HOME','HOST_BENCHMARK_CODEX_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($value)) { $full = [IO.Path]::GetFullPath($value); if ($full -notin $codexRoots) { $codexRoots.Add($full); $protectedRoots.Add($full) } }
}
$authPaths = [Collections.Generic.List[string]]::new(); $configPaths = [Collections.Generic.List[string]]::new()
foreach ($root in $codexRoots) { $authPaths.Add((Join-Path $root 'auth.json')); foreach ($name in @('hooks.json','config.toml','managed_config.toml')) { $configPaths.Add((Join-Path $root $name)) } }
$configPaths.Add((Join-Path $mainUserProfile '.claude\settings.json')); $configPaths.Add((Join-Path $mainUserProfile '.dev-harness\install-registry.json'))
$mainRuntimePaths = @((Join-Path $RepoRoot '.assistant\runtime\protocol-default.json'),(Join-Path $RepoRoot '.assistant\runtime\current.json'))
$authBefore = Get-V1StopLossFileSnapshot -Paths @($authPaths); $configBefore = Get-V1StopLossFileSnapshot -Paths @($configPaths); $mainRuntimeBefore = Get-V1StopLossFileSnapshot -Paths $mainRuntimePaths

$targetPath = & $rolloutModule { param($Root,$Requested,$Inputs,$Protected) Resolve-HarnessReleaseArtifactPath -RepoRoot $Root -OutputPath $Requested -EvidencePaths $Inputs -ProtectedRoots $Protected } $RepoRoot $OutputPath @($paths.Values) @($protectedRoots)
$pathRoot = [IO.Path]::GetPathRoot($targetPath)
if ($targetPath.Substring($pathRoot.Length).Contains(':')) { throw 'v1 stop-loss output alternate stream is rejected' }

$reportRunId = [guid]::NewGuid().ToString('N')
$scratchParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$scratchRoot = Join-Path $scratchParent "dev-harness-v1-stop-loss-$reportRunId"
if (([IO.Path]::GetFullPath($targetPath)).StartsWith(([IO.Path]::GetFullPath($scratchRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'v1 stop-loss output overlaps the isolated execution root' }
$workspaceBase = Join-Path $scratchRoot 'workspaces'; $profileRoot = Join-Path $scratchRoot 'profile'
$workspaceIdentityDigest = Get-V1StopLossTextDigest -Text "v1-stop-loss-workspaces/v1|$reportRunId|$workspaceBase"
$profileIdentityDigest = Get-V1StopLossTextDigest -Text "v1-stop-loss-profile/v1|$reportRunId|$profileRoot"
$sourceStart = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
$started = [DateTimeOffset]::UtcNow
$probes = [ordered]@{}
$lifecycle = [ordered]@{status='not_run';initial_stage=$null;final_stage=$null;stage_sequence=@();transition_count=0L;plan_digest_before=$null;plan_digest_after=$null;test_report_digest=$null;unexpected_writes=0L;reason='not-run'}
$isolatedControlPaths = [Collections.Generic.List[string]]::new()
$cleanupNoResidue = $false

try {
    [void][IO.Directory]::CreateDirectory($workspaceBase); [void][IO.Directory]::CreateDirectory($profileRoot); [void][IO.Directory]::CreateDirectory((Join-Path $profileRoot '.codex'))
    $expectations = [ordered]@{
        environment=[ordered]@{detected_protocol='new';selected_protocol='v1';preference_source='HARNESS_PROTOCOL';reason_code='explicit-v1-new-task';existing_artifact=$false}
        disable=[ordered]@{detected_protocol='new';selected_protocol='v1';preference_source='workspace-config';reason_code='workspace-v1-new-task';existing_artifact=$false}
        existing_v1=[ordered]@{detected_protocol='v1';selected_protocol='v1';preference_source='existing-artifact';reason_code='existing-v1-plan';existing_artifact=$true}
        existing_v2=[ordered]@{detected_protocol='v2';selected_protocol='v2';preference_source='existing-artifact';reason_code='existing-v2-task-state';existing_artifact=$true}
    }

    $workspace = Join-Path $workspaceBase 'environment-v1'; [void][IO.Directory]::CreateDirectory($workspace)
    foreach ($relative in @('.assistant\runtime\protocol-default.json','.assistant\runtime\current.json')) { $isolatedControlPaths.Add((Join-Path $workspace $relative)) }
    $before = Get-V1StopLossTreeSnapshot -Root $workspace
    $process = Invoke-V1StopLossProcess -ScriptPath $paths.task_entry -Arguments @('protocol','-TaskId','environment-v1-new-task','-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') -WorkspaceRoot $workspace -ProfileRoot $profileRoot -Protocol 'v1'
    $unexpected = Get-V1StopLossUnexpectedWriteCount -Before $before -After (Get-V1StopLossTreeSnapshot -Root $workspace)
    $probes.environment = New-V1StopLossProbeRecord -Name 'environment-v1-new-task' -Requested 'v1' -WriteKind 'none' -ProcessResult $process -Expected $expectations.environment -UnexpectedWrites $unexpected -ArtifactBefore $null -ArtifactAfter $null -CommandIdentity 'task.ps1 protocol|new-task|HARNESS_PROTOCOL=v1'

    $workspace = Join-Path $workspaceBase 'disable-v2'; [void][IO.Directory]::CreateDirectory($workspace)
    foreach ($relative in @('.assistant\runtime\protocol-default.json','.assistant\runtime\current.json')) { $isolatedControlPaths.Add((Join-Path $workspace $relative)) }
    $before = Get-V1StopLossTreeSnapshot -Root $workspace
    $disable = Invoke-V1StopLossProcess -ScriptPath $paths.task_entry -Arguments @('disable-v2','-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') -WorkspaceRoot $workspace -ProfileRoot $profileRoot -Protocol $null
    $route = Invoke-V1StopLossProcess -ScriptPath $paths.task_entry -Arguments @('protocol','-TaskId','disable-v2-new-task','-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') -WorkspaceRoot $workspace -ProfileRoot $profileRoot -Protocol $null
    $route.output = Join-V1StopLossOutputBytes -StdOut ([byte[]]$disable.output) -StdErr ([byte[]]$route.output)
    if ($disable.exit_code -ne 0 -and $route.exit_code -eq 0) { $route.exit_code = [long]$disable.exit_code }
    $configRelative = '.assistant/config/protocol.json'; $after = Get-V1StopLossTreeSnapshot -Root $workspace
    $unexpected = Get-V1StopLossUnexpectedWriteCount -Before $before -After $after -Allowed @($configRelative)
    if (-not $after.Contains($configRelative)) { $unexpected++ }
    $probes.disable = New-V1StopLossProbeRecord -Name 'disable-v2-new-task' -Requested 'v1' -WriteKind 'workspace-protocol-config' -ProcessResult $route -Expected $expectations.disable -UnexpectedWrites $unexpected -ArtifactBefore $null -ArtifactAfter $null -CommandIdentity 'task.ps1 disable-v2; task.ps1 protocol|new-task|HARNESS_PROTOCOL=cleared'

    $workspace = Join-Path $workspaceBase 'existing-v1'; [void][IO.Directory]::CreateDirectory($workspace)
    foreach ($relative in @('.assistant\runtime\protocol-default.json','.assistant\runtime\current.json')) { $isolatedControlPaths.Add((Join-Path $workspace $relative)) }
    $setup = Invoke-V1StopLossProcess -ScriptPath $paths.task_entry -Arguments @('enable-v2','-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') -WorkspaceRoot $workspace -ProfileRoot $profileRoot -Protocol $null
    $taskId = 'existing-v1-artifact'; $artifactPath = Join-Path $workspace "docs\tasks\$taskId\plan.md"; Write-V1StopLossBomText -Path $artifactPath -Content (New-V1StopLossPlanText -TaskId $taskId)
    $artifactBefore = Get-V1StopLossFileDigest -Path $artifactPath; $before = Get-V1StopLossTreeSnapshot -Root $workspace
    $process = Invoke-V1StopLossProcess -ScriptPath $paths.task_entry -Arguments @('protocol','-TaskId',$taskId,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') -WorkspaceRoot $workspace -ProfileRoot $profileRoot -Protocol 'v2'
    if ($setup.exit_code -ne 0 -and $process.exit_code -eq 0) { $process.exit_code = [long]$setup.exit_code }
    $artifactAfter = Get-V1StopLossFileDigest -Path $artifactPath; $unexpected = Get-V1StopLossUnexpectedWriteCount -Before $before -After (Get-V1StopLossTreeSnapshot -Root $workspace)
    $probes.existing_v1 = New-V1StopLossProbeRecord -Name 'existing-v1-artifact' -Requested 'v2' -WriteKind 'none' -ProcessResult $process -Expected $expectations.existing_v1 -UnexpectedWrites $unexpected -ArtifactBefore $artifactBefore -ArtifactAfter $artifactAfter -CommandIdentity 'task.ps1 enable-v2 setup; task.ps1 protocol|existing-v1|HARNESS_PROTOCOL=v2'

    $workspace = Join-Path $workspaceBase 'existing-v2'; [void][IO.Directory]::CreateDirectory($workspace)
    foreach ($relative in @('.assistant\runtime\protocol-default.json','.assistant\runtime\current.json')) { $isolatedControlPaths.Add((Join-Path $workspace $relative)) }
    $setup = Invoke-V1StopLossProcess -ScriptPath $paths.task_entry -Arguments @('disable-v2','-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') -WorkspaceRoot $workspace -ProfileRoot $profileRoot -Protocol $null
    $taskId = 'existing-v2-artifact'; $artifactPath = Join-Path $workspace ".assistant\runtime\tasks\$taskId\task.json"; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($artifactPath))
    $v2Document = New-V1StopLossV2TaskDocument -TaskId $taskId; $v2Json = $v2Document | ConvertTo-Json -Depth 30 -Compress
    if (-not (Test-Json -Json $v2Json -SchemaFile (Join-Path $RepoRoot 'schemas\task-state.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue)) { throw 'strict v2 task fixture failed current Schema' }
    [IO.File]::WriteAllText($artifactPath,$v2Json,[Text.UTF8Encoding]::new($false))
    $artifactBefore = Get-V1StopLossFileDigest -Path $artifactPath; $before = Get-V1StopLossTreeSnapshot -Root $workspace
    $process = Invoke-V1StopLossProcess -ScriptPath $paths.task_entry -Arguments @('protocol','-TaskId',$taskId,'-RepoRoot',$RepoRoot,'-WorkspaceRoot',$workspace,'-AsJson') -WorkspaceRoot $workspace -ProfileRoot $profileRoot -Protocol 'v1'
    if ($setup.exit_code -ne 0 -and $process.exit_code -eq 0) { $process.exit_code = [long]$setup.exit_code }
    $artifactAfter = Get-V1StopLossFileDigest -Path $artifactPath; $unexpected = Get-V1StopLossUnexpectedWriteCount -Before $before -After (Get-V1StopLossTreeSnapshot -Root $workspace)
    $probes.existing_v2 = New-V1StopLossProbeRecord -Name 'existing-v2-artifact' -Requested 'v1' -WriteKind 'none' -ProcessResult $process -Expected $expectations.existing_v2 -UnexpectedWrites $unexpected -ArtifactBefore $artifactBefore -ArtifactAfter $artifactAfter -CommandIdentity 'task.ps1 disable-v2 setup; task.ps1 protocol|existing-v2|HARNESS_PROTOCOL=v1'

    $workspace = Join-Path $workspaceBase 'v1-lifecycle'; [void][IO.Directory]::CreateDirectory($workspace)
    foreach ($relative in @('.assistant\runtime\protocol-default.json','.assistant\runtime\current.json')) { $isolatedControlPaths.Add((Join-Path $workspace $relative)) }
    $lifecycle = Invoke-V1StopLossLifecycle -WorkspaceRoot $workspace -ProfileRoot $profileRoot
} finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratchRoot)
    try {
        if (-not $resolvedScratch.StartsWith($scratchParent+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedScratch) -cne "dev-harness-v1-stop-loss-$reportRunId") { throw 'v1 stop-loss cleanup target is invalid' }
        if ([IO.Directory]::Exists($resolvedScratch)) { [IO.Directory]::Delete($resolvedScratch,$true) }
        $cleanupNoResidue = -not (Test-Path -LiteralPath $resolvedScratch)
        if ($TestFailureProbe -ceq 'cleanup') { $cleanupNoResidue = $false }
    } catch { $cleanupNoResidue = $false }
}

$ended = [DateTimeOffset]::UtcNow
$sourceEnd = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
$authAfter = Get-V1StopLossFileSnapshot -Paths @($authPaths); $configAfter = Get-V1StopLossFileSnapshot -Paths @($configPaths); $mainRuntimeAfter = Get-V1StopLossFileSnapshot -Paths $mainRuntimePaths
$authUnchanged = Test-V1StopLossSnapshotEqual -Left $authBefore -Right $authAfter
$configUnchanged = Test-V1StopLossSnapshotEqual -Left $configBefore -Right $configAfter
$runtimeDefaultUntouched = (Test-V1StopLossSnapshotEqual -Left $mainRuntimeBefore -Right $mainRuntimeAfter) -and @($isolatedControlPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0
$routeProbes = @($probes.environment,$probes.disable,$probes.existing_v1,$probes.existing_v2)
$expectedStages = 'PLAN>PLAN_REVIEW>IMPLEMENT>CODE_REVIEW>TEST>DONE'
$results = [ordered]@{
    environment_v1_selects_v1=([string]$routeProbes[0].status -ceq 'pass')
    disable_v2_selects_v1=([string]$routeProbes[1].status -ceq 'pass')
    existing_v1_artifact_remains_v1=([string]$routeProbes[2].status -ceq 'pass')
    existing_v2_artifact_remains_v2=([string]$routeProbes[3].status -ceq 'pass')
    existing_artifacts_unchanged_by_routing=([string]$routeProbes[2].artifact_digest_before -ceq [string]$routeProbes[2].artifact_digest_after -and [string]$routeProbes[3].artifact_digest_before -ceq [string]$routeProbes[3].artifact_digest_after)
    v1_lifecycle_reaches_done=([string]$lifecycle.status -ceq 'pass' -and [string]$lifecycle.final_stage -ceq 'DONE')
    v1_stage_order_exact=([string]$lifecycle.status -ceq 'pass' -and (@($lifecycle.stage_sequence) -join '>') -ceq $expectedStages)
    runtime_default_untouched=$runtimeDefaultUntouched
    auth_unchanged=$authUnchanged
    unrelated_user_config_unchanged=$configUnchanged
    cleanup_no_residue=$cleanupNoResidue
}
$allResults = @($results.Keys | Where-Object { -not [bool]$results[$_] }).Count -eq 0
$sourceStable = Test-HarnessReleaseSourceStable -Start $sourceStart -End $sourceEnd
$sourceDirty = [bool]$sourceStart.dirty -or [bool]$sourceEnd.dirty
$sourceUnchanged = [string]$sourceStart.revision -ceq [string]$sourceEnd.revision -and [string]$sourceStart.commit_tree_oid -ceq [string]$sourceEnd.commit_tree_oid -and [string]$sourceStart.object_format -ceq [string]$sourceEnd.object_format -and [string]$sourceStart.state_digest -ceq [string]$sourceEnd.state_digest
$operationalPass = @($routeProbes | Where-Object { [string]$_.status -cne 'pass' }).Count -eq 0 -and [string]$lifecycle.status -ceq 'pass' -and $allResults -and $sourceUnchanged
$status = if (-not $operationalPass) { 'fail' } elseif ($ProducerMode -cne 'formal') { 'unavailable' } elseif (-not $sourceDirty -and $sourceStable) { 'pass' } else { 'fail' }
$reason = if ($status -ceq 'pass') { 'all-stop-loss-checks-passed' } elseif ($status -ceq 'unavailable') { 'non-formal-producer-mode' } else { 'route-or-lifecycle-result-failure' }
$inputDigests = [ordered]@{
    producer_digest=Get-V1StopLossFileDigest -Path $paths.producer
    task_entry_digest=Get-V1StopLossFileDigest -Path $paths.task_entry
    advance_stage_digest=Get-V1StopLossFileDigest -Path $paths.advance_stage
    protocol_module_digest=Get-V1StopLossFileDigest -Path $paths.protocol_module
    task_state_module_digest=Get-V1StopLossFileDigest -Path $paths.task_state_module
    atomic_write_digest=Get-V1StopLossFileDigest -Path $paths.atomic_write
    path_digest=Get-V1StopLossFileDigest -Path $paths.path
}
$report = [ordered]@{
    schema_version='harness-v1-stop-loss-report/v1';generated_at_utc=[DateTimeOffset]::UtcNow.ToString('o');source_revision=[string]$sourceStart.revision;source_dirty=$sourceDirty;source_state_stable=$sourceStable
    source=[ordered]@{commit_tree_oid=[string]$sourceStart.commit_tree_oid;object_format=[string]$sourceStart.object_format;start=$sourceStart;end=$sourceEnd;input_digests=$inputDigests}
    report_run_id=$reportRunId;producer_identity='v1-stop-loss-qualification/v1';producer_mode=$ProducerMode
    execution=[ordered]@{sequence_contract='environment-v1-disable-v2-existing-v1-existing-v2-v1-lifecycle/v1';isolated_workspace=$true;isolated_profile=$true;workspace_identity_digest=$workspaceIdentityDigest;profile_identity_digest=$profileIdentityDigest;duration_ms=[long][Math]::Max(1,[Math]::Round(($ended-$started).TotalMilliseconds,0,[MidpointRounding]::AwayFromZero));raw_output_persisted=$false;auth_bytes_persisted=$false;private_paths_persisted=$false}
    route_probes=$routeProbes;lifecycle=$lifecycle;results=$results;status=$status;reason=$reason;report_digest=$null
}
$report.report_digest = Get-V1StopLossTextDigest -Text ($report | ConvertTo-Json -Depth 100 -Compress)
$json = $report | ConvertTo-Json -Depth 100 -Compress
$expectedBytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
$validated = & $rolloutModule { param($Bytes) ConvertFrom-V1StopLossEvidenceBytes -Bytes $Bytes } $expectedBytes
[void](& $rolloutModule { param($Root,$Document,$AllowNonFormal) Assert-V1StopLossReport -RepoRoot $Root -Document $Document -AllowNonFormalSource:$AllowNonFormal } $RepoRoot $validated ($ProducerMode -cne 'formal'))
$writeRoot = [IO.Path]::GetDirectoryName($targetPath)
while (-not (Test-Path -LiteralPath $writeRoot -PathType Container)) { $parent = [IO.Path]::GetDirectoryName($writeRoot); if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $writeRoot) { throw 'v1 stop-loss output parent is unavailable' }; $writeRoot = $parent }
$writtenDigest = Write-HarnessAtomicText -WorkspaceRoot $writeRoot -Path $targetPath -Content $json
if ([string]$writtenDigest -cne (Get-V1StopLossBytesDigest -Bytes $expectedBytes)) { throw 'v1 stop-loss atomic write digest mismatch' }
[void](& $rolloutModule { param($Path) Assert-ReleaseSingleLinkFile -Path $Path -Label 'v1-stop-loss-output'; Assert-ReleaseSingleDataStreamFile -Path $Path -Label 'v1-stop-loss-output' } $targetPath)
$actualBytes = [IO.File]::ReadAllBytes($targetPath)
if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($expectedBytes,$actualBytes)) { throw 'v1 stop-loss output bytes changed after write' }
$reopened = & $rolloutModule { param($Bytes) ConvertFrom-V1StopLossEvidenceBytes -Bytes $Bytes } $actualBytes
[void](& $rolloutModule { param($Root,$Document,$AllowNonFormal) Assert-V1StopLossReport -RepoRoot $Root -Document $Document -AllowNonFormalSource:$AllowNonFormal } $RepoRoot $reopened ($ProducerMode -cne 'formal'))

Write-Output 'V1 stop-loss qualification summary:'
Write-Output ("- producer_mode: {0}" -f $ProducerMode)
foreach ($probe in $routeProbes) { Write-Output ("- {0}: {1}" -f $probe.probe,$probe.status) }
Write-Output ("- lifecycle: {0}" -f $lifecycle.status)
Write-Output ("- status: {0}" -f $status)
Write-Output ("- report_digest: {0}" -f $report.report_digest)
if ($status -ceq 'fail') { exit 1 }
exit 0
