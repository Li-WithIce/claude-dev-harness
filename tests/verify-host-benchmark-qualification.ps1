[CmdletBinding()]
param([string]$RepoRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$failures = [Collections.Generic.List[string]]::new()
$checks = 0
$script:hostBenchmarkTemplateRoot = ''
function Check([bool]$Condition,[string]$Message) {
    if ($Condition) { $script:checks++ } else { $script:failures.Add($Message) }
}
function Invoke-Git {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git -C $Root @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' | ')" }
    return $output
}
function Invoke-HostGit {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string[]]$Arguments)
    return @(Invoke-Git -Root $Root -Arguments $Arguments)
}
function Write-Utf8 {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Get-DirectoryContentDigest {
    param([Parameter(Mandatory)][string]$Root)
    $lines = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relative`:$hash"
    })
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n"))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Initialize-GitFixture {
    param([Parameter(Mandatory)][string]$Root)
    [void][IO.Directory]::CreateDirectory($Root)
    [void](Invoke-Git $Root @('init','--quiet'))
}
function Commit-GitFixture {
    param([Parameter(Mandatory)][string]$Root)
    [void](Invoke-Git $Root @('add','--all'))
    [void](Invoke-Git $Root @('-c','user.name=Harness Test','-c','user.email=harness@example.invalid','commit','--quiet','--no-gpg-sign','-m','fixture'))
}
function Invoke-FixtureRunner {
    param([string]$Fixture,[string]$OutputRoot,[string]$Mode,[int]$Trials)
    $outputPath = Join-Path $OutputRoot ("report-$Mode-$Trials.json")
    $logPath = Join-Path $OutputRoot ("order-$Mode-$Trials.txt")
    $oldMode = $env:HOST_BENCHMARK_TEST_MODE
    $oldLog = $env:HOST_BENCHMARK_TEST_LOG
    $oldTemplate = $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT
    try {
        if ([string]::IsNullOrWhiteSpace($script:hostBenchmarkTemplateRoot)) { throw 'host benchmark fixture templates are not initialized' }
        $env:HOST_BENCHMARK_TEST_MODE = $Mode
        $env:HOST_BENCHMARK_TEST_LOG = $logPath
        $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT = $script:hostBenchmarkTemplateRoot
        $lines = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $Fixture 'scripts\run-host-benchmark.ps1') -RepoRoot $Fixture -OutputPath $outputPath -Trials $Trials -MaxRoundTrips 1 -TimeoutSeconds 30 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $oldMode) { Remove-Item Env:HOST_BENCHMARK_TEST_MODE -ErrorAction Ignore } else { $env:HOST_BENCHMARK_TEST_MODE = $oldMode }
        if ($null -eq $oldLog) { Remove-Item Env:HOST_BENCHMARK_TEST_LOG -ErrorAction Ignore } else { $env:HOST_BENCHMARK_TEST_LOG = $oldLog }
        if ($null -eq $oldTemplate) { Remove-Item Env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT -ErrorAction Ignore } else { $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT = $oldTemplate }
    }
    $report = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { [IO.File]::ReadAllText($outputPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -Depth 80 } else { $null }
    $order = if (Test-Path -LiteralPath $logPath -PathType Leaf) { @([IO.File]::ReadAllLines($logPath,[Text.UTF8Encoding]::new($false,$true))) } else { @() }
    return [pscustomobject]@{ExitCode=$exitCode;Output=$lines;Report=$report;Order=$order}
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('hbq-' + [guid]::NewGuid().ToString('N').Substring(0,8))
try {
    [void][IO.Directory]::CreateDirectory($scratch)
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -ErrorAction Stop
    . (Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1')
    . (Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1')

    Check ((Resolve-HostTrialStatus -Protocol v2 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 1 -HostTurns 0 -ObservationComplete $false -WorkflowCompleted $true -DirectContractPassed $false -V1ContractPassed $true -Complete $false) -ceq 'unavailable') 'Direct wrapper failure was misclassified as a known contract failure'
    Check ((Resolve-HostTrialStatus -Protocol v1 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 1 -HostTurns 0 -ObservationComplete $false -WorkflowCompleted $false -DirectContractPassed $true -V1ContractPassed $false -Complete $false) -ceq 'unavailable') 'v1 wrapper failure was misclassified as a known contract failure'
    Check ((Resolve-HostTrialStatus -Protocol v2 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 2 -HostTurns 1 -ObservationComplete $false -WorkflowCompleted $true -DirectContractPassed $false -V1ContractPassed $true -Complete $false) -ceq 'fail') 'observed Direct session overrun was hidden by unavailable execution'
    Check ((Resolve-HostTrialStatus -Protocol v1 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 5 -HostTurns 5 -ObservationComplete $true -WorkflowCompleted $true -DirectContractPassed $true -V1ContractPassed $false -Complete $false) -ceq 'fail') 'completed invalid v1 workflow was hidden by unavailable measurement'
    Check ((Resolve-HostTrialStatus -Protocol v1 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 6 -HostTurns 5 -ObservationComplete $false -WorkflowCompleted $false -DirectContractPassed $true -V1ContractPassed $false -Complete $false) -ceq 'fail') 'partial v1 session overrun was hidden by unavailable execution'
    Check ((Resolve-HostTrialStatus -Protocol v1 -InvocationUnavailable $true -ContractFailure $false -WriteBoundaryPassed $true -SourceBindingFailure $false -FreshSessions 5 -HostTurns 6 -ObservationComplete $false -WorkflowCompleted $false -DirectContractPassed $true -V1ContractPassed $false -Complete $false) -ceq 'fail') 'partial v1 turn overrun was hidden by unavailable execution'

    $authHome = Join-Path $scratch 'dedicated-auth-home'
    Write-Utf8 (Join-Path $authHome 'auth.json') '{}'
    [void][IO.Directory]::CreateDirectory((Join-Path $authHome 'cache'))
    Check ((Assert-HostCodexHomeLayout -Path $authHome) -ceq (Resolve-Path -LiteralPath $authHome).Path) 'minimal dedicated auth-home layout was rejected'
    Write-Utf8 (Join-Path $authHome 'unexpected.txt') 'x'
    $extraRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome } catch { $extraRejected = $_.Exception.Message -like 'host-benchmark-auth-home-*' }
    Check $extraRejected 'unexpected dedicated auth-home file was accepted'
    Remove-Item -LiteralPath (Join-Path $authHome 'unexpected.txt') -Force

    $junctionTarget = Join-Path $scratch 'junction-target'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    $junctionPath = Join-Path $authHome 'cache\linked'
    [void](New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop)
    $descendantJunctionRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $authHome } catch { $descendantJunctionRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-reparse-point' }
    Check $descendantJunctionRejected 'descendant auth-home junction was accepted'
    Remove-Item -LiteralPath $junctionPath -Force

    $linkedAuthTarget = Join-Path $scratch 'linked-auth-target'
    Write-Utf8 (Join-Path $linkedAuthTarget 'auth.json') '{}'
    $linkedAuthHome = Join-Path $scratch 'linked-auth-home'
    [void](New-Item -ItemType Junction -Path $linkedAuthHome -Target $linkedAuthTarget -ErrorAction Stop)
    $rootJunctionRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $linkedAuthHome } catch { $rootJunctionRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-reparse-point' }
    Check $rootJunctionRejected 'root auth-home junction was accepted'
    Remove-Item -LiteralPath $linkedAuthHome -Force

    $hardlinkTarget = Join-Path $scratch 'hardlink-auth-target.json'
    Write-Utf8 $hardlinkTarget '{}'
    $hardlinkHome = Join-Path $scratch 'hardlink-auth-home'
    [void][IO.Directory]::CreateDirectory($hardlinkHome)
    [void](New-Item -ItemType HardLink -Path (Join-Path $hardlinkHome 'auth.json') -Target $hardlinkTarget -ErrorAction Stop)
    $hardlinkRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $hardlinkHome } catch { $hardlinkRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-linked-credential' }
    Check $hardlinkRejected 'hard-linked auth credential was accepted'

    $hardlinkStateTarget = Join-Path $scratch 'hardlink-state-target.json'
    Write-Utf8 $hardlinkStateTarget '{}'
    $hardlinkStateHome = Join-Path $scratch 'hardlink-state-home'
    Write-Utf8 (Join-Path $hardlinkStateHome 'auth.json') '{}'
    [void](New-Item -ItemType HardLink -Path (Join-Path $hardlinkStateHome 'models_cache.json') -Target $hardlinkStateTarget -ErrorAction Stop)
    $hardlinkStateRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $hardlinkStateHome } catch { $hardlinkStateRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-linked-credential' }
    Check $hardlinkStateRejected 'hard-linked top-level Codex state file was accepted'

    $hardlinkNestedTarget = Join-Path $scratch 'hardlink-nested-target.json'
    Write-Utf8 $hardlinkNestedTarget '{}'
    $hardlinkNestedHome = Join-Path $scratch 'hardlink-nested-home'
    Write-Utf8 (Join-Path $hardlinkNestedHome 'auth.json') '{}'
    [void][IO.Directory]::CreateDirectory((Join-Path $hardlinkNestedHome 'cache'))
    [void](New-Item -ItemType HardLink -Path (Join-Path $hardlinkNestedHome 'cache\state.json') -Target $hardlinkNestedTarget -ErrorAction Stop)
    $hardlinkNestedRejected = $false
    try { $null = Assert-HostCodexHomeLayout -Path $hardlinkNestedHome } catch { $hardlinkNestedRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-linked-credential' }
    Check $hardlinkNestedRejected 'hard-linked nested Codex state file was accepted'

    $traceSafetyRoot = Join-Path $scratch 'trace-safety'
    $traceResultRoot = Join-Path $traceSafetyRoot 'results'
    $externalTraceRoot = Join-Path $scratch 'external-trace'
    [void][IO.Directory]::CreateDirectory($traceResultRoot)
    Write-Utf8 (Join-Path $externalTraceRoot 'trace.json') 'private'
    $traceJunction = Join-Path $traceResultRoot 'otel-traces'
    [void](New-Item -ItemType Junction -Path $traceJunction -Target $externalTraceRoot -ErrorAction Stop)
    $traceRemoved = Remove-HostRawTrace -TraceRoot $traceJunction -ResultRoot $traceResultRoot -SafetyRoot $traceSafetyRoot
    Check (-not $traceRemoved -and (Test-Path -LiteralPath $traceJunction) -and (Test-Path -LiteralPath (Join-Path $externalTraceRoot 'trace.json') -PathType Leaf)) 'raw-trace junction was deleted or falsely attested as removed'
    Remove-Item -LiteralPath $traceJunction -Force

    $oldCodexHome = $env:CODEX_HOME
    $unrelatedScratch = Join-Path $scratch 'unrelated-scratch'
    [void][IO.Directory]::CreateDirectory($unrelatedScratch)
    try {
        $env:CODEX_HOME = $authHome
        $realHomeRejected = $false
        try { $null = Assert-HostCodexHome -Path $authHome -RepoRoot $RepoRoot -ScratchRoot $unrelatedScratch } catch { $realHomeRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-dedicated' }
        Check $realHomeRejected 'current Codex home was accepted as a dedicated benchmark home'

        $authAlias = Join-Path $scratch 'auth-home-alias'
        [void](New-Item -ItemType Junction -Path $authAlias -Target $authHome -ErrorAction Stop)
        try {
            $env:CODEX_HOME = $authAlias
            $aliasHomeRejected = $false
            try { $null = Assert-HostCodexHome -Path $authHome -RepoRoot $RepoRoot -ScratchRoot $unrelatedScratch } catch { $aliasHomeRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-not-dedicated' }
            Check $aliasHomeRejected 'physical alias of the current Codex home was accepted as dedicated'
        } finally {
            Remove-Item -LiteralPath $authAlias -Force
        }
    } finally {
        if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction Ignore } else { $env:CODEX_HOME = $oldCodexHome }
    }
    $fakeRepoRoot = Join-Path $scratch 'fake-repo-root'
    $repoAuthHome = Join-Path $fakeRepoRoot 'benchmark-auth-home'
    Write-Utf8 (Join-Path $repoAuthHome 'auth.json') '{}'
    $repoHomeRejected = $false
    try { $null = Assert-HostCodexHome -Path $repoAuthHome -RepoRoot $fakeRepoRoot -ScratchRoot $unrelatedScratch } catch { $repoHomeRejected = $_.Exception.Message -ceq 'host-benchmark-auth-home-unsafe-location' }
    Check $repoHomeRejected 'repository-local Codex auth home was accepted'

    $pathFixture = Join-Path $scratch 'workspace-paths'
    Initialize-GitFixture $pathFixture
    Write-Utf8 (Join-Path $pathFixture '.gitignore') "ignored/`n"
    Write-Utf8 (Join-Path $pathFixture 'baseline.txt') 'baseline'
    Write-Utf8 (Join-Path $pathFixture 'staged-only.txt') 'baseline'
    Commit-GitFixture $pathFixture
    $pathBaseline = (@(Invoke-Git $pathFixture @('rev-parse','HEAD')) -join '').Trim()
    Write-Utf8 (Join-Path $pathFixture ' src\value.txt') 'leading-space'
    Write-Utf8 (Join-Path $pathFixture 'ignored\evidence.txt') 'ignored'
    Write-Utf8 (Join-Path $pathFixture 'staged-only.txt') 'index-only'
    [void](Invoke-Git $pathFixture @('add','--','staged-only.txt'))
    Write-Utf8 (Join-Path $pathFixture 'staged-only.txt') 'baseline'
    $workspaceChanges = @(Get-HostWorkspaceChanges -Workspace $pathFixture -BaselineRevision $pathBaseline)
    Check ($workspaceChanges -ccontains ' src/value.txt') 'workspace diff normalized away a leading-space path'
    Check ($workspaceChanges -ccontains 'ignored/evidence.txt') 'workspace diff omitted an ignored write'
    Check ($workspaceChanges -ccontains 'staged-only.txt') 'workspace diff omitted a staged-only write'
    [void](Invoke-Git $pathFixture @('update-index','--assume-unchanged','baseline.txt'))
    Write-Utf8 (Join-Path $pathFixture 'baseline.txt') 'assume-hidden'
    $assumeChanges = @(Get-HostWorkspaceChanges -Workspace $pathFixture -BaselineRevision $pathBaseline)
    Check ($assumeChanges -ccontains '__git_index_flag__/baseline.txt') 'workspace evidence omitted an assume-unchanged index flag'
    [void](Invoke-Git $pathFixture @('update-index','--no-assume-unchanged','baseline.txt'))
    Write-Utf8 (Join-Path $pathFixture 'baseline.txt') 'baseline'
    [void](Invoke-Git $pathFixture @('update-index','--skip-worktree','baseline.txt'))
    Write-Utf8 (Join-Path $pathFixture 'baseline.txt') 'skip-hidden'
    $skipChanges = @(Get-HostWorkspaceChanges -Workspace $pathFixture -BaselineRevision $pathBaseline)
    Check ($skipChanges -ccontains '__git_index_flag__/baseline.txt') 'workspace evidence omitted a skip-worktree index flag'

    $hookFixture = Join-Path $scratch 'hook-baseline'
    Initialize-GitFixture $hookFixture
    Write-Utf8 (Join-Path $hookFixture 'baseline.txt') 'baseline'
    $null = Initialize-HostWorkspaceBaseline -Workspace $hookFixture
    $localHooksPath = (@(Invoke-Git $hookFixture @('config','--local','--get','core.hooksPath')) -join '').Trim()
    Check ($localHooksPath -ceq 'NUL') 'workspace baseline did not disable inherited Git hooks'

    $runtimeWorkspace = Join-Path $scratch 'runtime-done'
    $runtimeRoot = Join-Path $runtimeWorkspace '.assistant\运行时'
    [void][IO.Directory]::CreateDirectory((Join-Path $runtimeRoot 'tasks'))
    $runtimeTaskId = 'host-benchmark-fixed-workflow'
    $idleContent = New-CanonicalCurrentTaskContent -TaskId 'none' -TaskName '无' -Stage '空闲' -CurrentDoc 'none' -Tool 'none' -EntryHost 'unknown' -NextStep '等待新任务' -Writer 'advance-stage'
    $mirrorContent = New-CanonicalTaskRuntimeContent -TaskId $runtimeTaskId -TaskName 'Fixed Host Benchmark Workflow' -Stage 'DONE' -WorkspaceRoot $runtimeWorkspace -PrimaryArtifact "docs/tasks/$runtimeTaskId/test.md" -Tool 'none' -EntryHost 'codex' -Writer 'advance-stage'
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '当前任务.md'),$idleContent,[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $runtimeRoot "tasks\$runtimeTaskId.md"),$mirrorContent,[Text.UTF8Encoding]::new($true))
    $idleState = Get-CanonicalCurrentTaskState -Path (Join-Path $runtimeRoot '当前任务.md')
    $runtimeRecords = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory (Join-Path $runtimeRoot 'tasks'))
    $recoveryContent = New-CanonicalRecoveryIndexContent -CurrentTask $idleState -TaskRecords $runtimeRecords
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '恢复索引.md'),$recoveryContent,[Text.UTF8Encoding]::new($true))
    Check (Test-V1RuntimeState -Workspace $runtimeWorkspace -TaskId $runtimeTaskId -ExpectedStage 'DONE') 'canonical DONE idle pointer was rejected'
    $nonIdleContent = New-CanonicalCurrentTaskContent -TaskId $runtimeTaskId -TaskName 'Fixed Host Benchmark Workflow' -Stage 'DONE' -CurrentDoc "docs/tasks/$runtimeTaskId/test.md" -Tool 'none' -EntryHost 'codex' -NextStep 'done' -Writer 'advance-stage'
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '当前任务.md'),$nonIdleContent,[Text.UTF8Encoding]::new($true))
    Check (-not (Test-V1RuntimeState -Workspace $runtimeWorkspace -TaskId $runtimeTaskId -ExpectedStage 'DONE')) 'non-idle DONE pointer was accepted'
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '当前任务.md'),$idleContent,[Text.UTF8Encoding]::new($true))
    $badRecovery = $recoveryContent.Replace(('- task_id: ' + [char]96 + 'none' + [char]96),('- task_id: ' + [char]96 + 'wrong-task' + [char]96))
    [IO.File]::WriteAllText((Join-Path $runtimeRoot '恢复索引.md'),$badRecovery,[Text.UTF8Encoding]::new($true))
    Check (-not (Test-V1RuntimeState -Workspace $runtimeWorkspace -TaskId $runtimeTaskId -ExpectedStage 'DONE')) 'recovery index with the wrong current task was accepted'

    $snapshotRepo = Join-Path $scratch 'snapshot-source'
    Initialize-GitFixture $snapshotRepo
    Write-Utf8 (Join-Path $snapshotRepo 'baseline.txt') 'baseline'
    Commit-GitFixture $snapshotRepo
    $cleanStatus = @(Invoke-Git $snapshotRepo @('-c','core.quotepath=false','status','--porcelain=v1','--untracked-files=all'))
    $chinesePath = Join-Path $snapshotRepo '目录\未跟踪.txt'
    Write-Utf8 $chinesePath '甲'
    $dirtyStatus = @(Invoke-Git $snapshotRepo @('-c','core.quotepath=false','status','--porcelain=v1','--untracked-files=all'))
    Check ($cleanStatus.Count -eq 0) 'committed source fixture was not clean'
    Check ($dirtyStatus.Count -eq 1 -and ($dirtyStatus -join '') -match '目录/未跟踪\.txt') 'Git source preflight did not detect a Chinese untracked path'
    Remove-Item -LiteralPath (Join-Path $snapshotRepo '目录') -Recurse -Force

    $bindingClone = Join-Path $scratch 'source-binding-clone'
    $cloneOutput = @(& git clone --no-local --no-checkout --quiet -- $snapshotRepo $bindingClone 2>&1 | ForEach-Object { [string]$_ })
    Check ($LASTEXITCODE -eq 0) 'native independent source clone failed'
    $revision = (@(Invoke-Git $snapshotRepo @('rev-parse','HEAD')) -join '').Trim()
    $tree = (@(Invoke-Git $snapshotRepo @('rev-parse',"$revision`^{tree}")) -join '').Trim()
    [void](Invoke-Git $bindingClone @('-c','core.hooksPath=NUL','checkout','--quiet','--detach',$revision,'--'))
    $cloneRevision = (@(Invoke-Git $bindingClone @('rev-parse','HEAD')) -join '').Trim()
    $cloneTree = (@(Invoke-Git $bindingClone @('rev-parse',"$cloneRevision`^{tree}")) -join '').Trim()
    Check ($cloneRevision -ceq $revision -and $cloneTree -ceq $tree -and @(Invoke-Git $bindingClone @('status','--porcelain=v1','--untracked-files=all')).Count -eq 0) 'native checkout did not bind revision, tree, and clean state'
    Write-Utf8 (Join-Path $bindingClone '.gitignore') "ignored/`n"
    [void](Invoke-Git $bindingClone @('add','.gitignore'))
    [void](Invoke-Git $bindingClone @('-c','user.name=Harness Test','-c','user.email=harness@example.invalid','commit','--quiet','--no-gpg-sign','-m','ignore-rule'))
    Write-Utf8 (Join-Path $bindingClone 'ignored\tamper.txt') 'tamper'
    Check (@(Invoke-Git $bindingClone @('status','--porcelain=v1','--untracked-files=all')).Count -eq 0 -and @(Invoke-Git $bindingClone @('ls-files','--others','--ignored','--exclude-standard','--')).Count -eq 1) 'ignored source tamper fixture did not distinguish normal status from ignored enumeration'
    [IO.File]::AppendAllText((Join-Path $bindingClone 'baseline.txt'),'tamper',[Text.UTF8Encoding]::new($false))
    Check (@(Invoke-Git $bindingClone @('status','--porcelain=v1','--untracked-files=all')).Count -gt 0) 'native source binding did not detect checkout tamper'

    $fixture = Join-Path $scratch 'runner-source'
    Initialize-GitFixture $fixture
    foreach ($relative in @('scripts\lib','scripts\host-benchmark','skills\codex\scripts','schemas\host-benchmark')) { [void][IO.Directory]::CreateDirectory((Join-Path $fixture $relative)) }
    foreach ($relative in @('scripts\run-host-benchmark.ps1','scripts\host-benchmark\HostBenchmark.Otel.ps1','scripts\lib\Harness.AtomicWrite.psm1','scripts\lib\Harness.Path.psm1','schemas\host-benchmark\observation.schema.json')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination (Join-Path $fixture $relative)
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1') -Destination (Join-Path $fixture 'scripts\host-benchmark\HostBenchmark.Trial.Real.ps1')
    Write-Utf8 (Join-Path $fixture '.gitignore') ".assistant/`n"
    Write-Utf8 (Join-Path $fixture 'install.ps1') "throw 'fixture install must not execute'`n"
    Write-Utf8 (Join-Path $fixture 'scripts\receive-otlp-http.ps1') "throw 'fixture collector must not execute'`n"
    Write-Utf8 (Join-Path $fixture 'skills\codex\scripts\invoke_codex.ps1') "throw 'fixture wrapper must not execute'`n"
    $stub = @'
. (Join-Path $PSScriptRoot 'HostBenchmark.Trial.Real.ps1')

function Write-StubUtf8 {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Initialize-StubTrialEvidence {
    param([string]$Protocol,[int]$Trial,[hashtable]$Named,[string]$Mode)
    $trialRoot = Join-Path ([string]$Named.ScratchRoot) ("$Protocol-$Trial")
    if ($Mode -ceq 'missing-workspace' -and $Protocol -ceq 'v2' -and $Trial -eq 1) { return '' }
    $workspace = Join-Path $trialRoot 'workspace'
    [void][IO.Directory]::CreateDirectory($trialRoot)
    $templateName = if ($Protocol -ceq 'v1') { 'workspace-v1' } else { 'workspace-direct' }
    $workspaceTemplate = Join-Path $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT $templateName
    Copy-Item -LiteralPath $workspaceTemplate -Destination $workspace -Recurse -Force -ErrorAction Stop
    $baseline = (@(Invoke-HostGit -Root $workspace -Arguments @('rev-parse','HEAD')) -join '').Trim()
    Write-StubUtf8 (Join-Path $workspace 'src\value.txt') 'beta'
    if ($Mode -ceq 'wrong-target-bytes' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        Write-StubUtf8 (Join-Path $workspace 'src\value.txt') "beta`n"
    }
    if ($Mode -ceq 'advanced-head' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        [void](Invoke-HostGit -Root $workspace -Arguments @('add','--','src/value.txt'))
        [void](Invoke-HostGit -Root $workspace -Arguments @('commit','--quiet','--no-gpg-sign','-m','unexpected model commit'))
    }
    if ($Mode -ceq 'linked-target' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        $externalTarget = Join-Path $trialRoot 'external-value.txt'
        Write-StubUtf8 $externalTarget 'beta'
        Remove-Item -LiteralPath (Join-Path $workspace 'src\value.txt') -Force
        [void](New-Item -ItemType HardLink -Path (Join-Path $workspace 'src\value.txt') -Target $externalTarget -ErrorAction Stop)
    }
    if ($Mode -ceq 'junction-target' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        $externalSource = Join-Path $trialRoot 'external-src'
        Write-StubUtf8 (Join-Path $externalSource 'value.txt') 'beta'
        Remove-Item -LiteralPath (Join-Path $workspace 'src') -Recurse -Force
        [void](New-Item -ItemType Junction -Path (Join-Path $workspace 'src') -Target $externalSource -ErrorAction Stop)
    }
    if ($Protocol -ceq 'v1') {
        Write-StubUtf8 (Join-Path $workspace 'docs\tasks\host-benchmark-fixed-workflow\plan.md') 'stage: DONE'
        Write-StubUtf8 (Join-Path $workspace 'docs\tasks\host-benchmark-fixed-workflow\test.md') 'STATUS: PASS'
        if ($Mode -ceq 'wrong-artifact-path') {
            Write-StubUtf8 (Join-Path $workspace 'docs\tasks\host-benchmark-fixed-workflow\unexpected.json') '{}'
        } else {
            Write-StubUtf8 (Join-Path $workspace 'docs\tasks\host-benchmark-fixed-workflow\skill-manifest.json') '{}'
        }
        Write-StubUtf8 (Join-Path $workspace '.assistant\运行时\当前任务.md') 'done current'
        Write-StubUtf8 (Join-Path $workspace '.assistant\运行时\恢复索引.md') 'done index'
        Write-StubUtf8 (Join-Path $workspace '.assistant\运行时\tasks\host-benchmark-fixed-workflow.md') 'done task'
    }
    $v2Artifact = $Protocol -ceq 'v2' -and (
        $Mode -ceq 'v2-artifact' -or
        $Mode -ceq 'unavailable-completed-violation' -or
        ($Mode -ceq 'same-protocol-mixed' -and $Trial -eq 2) -or
        ($Mode -ceq 'same-record-mixed' -and $Trial -eq 1)
    )
    if ($v2Artifact) { Write-StubUtf8 (Join-Path $workspace 'docs\tasks\unexpected\plan.md') 'unexpected' }
    if ($Mode -ceq 'staged-only' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        Write-StubUtf8 (Join-Path $workspace 'staged-only.txt') 'index-only'
        [void](Invoke-HostGit -Root $workspace -Arguments @('add','--','staged-only.txt'))
        Write-StubUtf8 (Join-Path $workspace 'staged-only.txt') 'baseline'
    }
    if ($Mode -ceq 'hidden-index-flag' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
        [void](Invoke-HostGit -Root $workspace -Arguments @('update-index','--assume-unchanged','staged-only.txt'))
        Write-StubUtf8 (Join-Path $workspace 'staged-only.txt') 'hidden unexpected write'
    }
    if ([Convert]::ToBoolean($Named.SourceBindingRequired)) {
        $sourceRoot = Join-Path $trialRoot 'source'
        Copy-Item -LiteralPath (Join-Path $env:HOST_BENCHMARK_TEST_TEMPLATE_ROOT 'source') -Destination $sourceRoot -Recurse -Force -ErrorAction Stop
        $templateRevision = (@(Invoke-HostGit -Root $sourceRoot -Arguments @('rev-parse','HEAD')) -join '').Trim()
        if ($templateRevision -cne [string]$Named.SourceRevision) { throw 'fixture source template revision mismatch' }
        if ($Mode -ceq 'ignored-source' -and $Protocol -ceq 'v2' -and $Trial -eq 1) {
            Write-StubUtf8 (Join-Path $sourceRoot '.assistant\tamper.txt') 'ignored source tamper'
        }
    }
    return $baseline
}
function Invoke-HostTrial {
    param(
        [Parameter(Mandatory)][string]$Protocol,
        [Parameter(Mandatory)][int]$Trial,
        [Parameter(ValueFromRemainingArguments=$true)][object[]]$Remaining
    )
    $named = @{}
    for ($index=0; $index -lt $Remaining.Count; $index++) {
        $item = [string]$Remaining[$index]
        if ($item.StartsWith('-') -and $index + 1 -lt $Remaining.Count) { $named[$item.TrimStart('-')] = $Remaining[++$index] }
    }
    [IO.File]::AppendAllText($env:HOST_BENCHMARK_TEST_LOG,("{0}{1}`n" -f $Protocol,$Trial),[Text.UTF8Encoding]::new($false))
    $mode = [string]$env:HOST_BENCHMARK_TEST_MODE
    if ($mode -ceq 'exception' -and $Protocol -ceq 'v2' -and $Trial -eq 1) { throw 'host-benchmark-auth-home-unavailable' }
    $baseline = Initialize-StubTrialEvidence -Protocol $Protocol -Trial $Trial -Named $named -Mode $mode
    $unavailable = $mode -cin @('unavailable','unavailable-completed-violation','unavailable-direct-sessions') -and $Protocol -ceq 'v2' -and $Trial -eq 1
    $sendUnavailable = $mode -cin @('unavailable','unavailable-completed-violation','unavailable-direct-sessions','send-unavailable','mixed-fail-unavailable','same-protocol-mixed','same-record-mixed') -and $Protocol -ceq 'v2' -and $Trial -eq 1
    $v2Artifact = $Protocol -ceq 'v2' -and ($mode -cin @('v2-artifact','unavailable-completed-violation') -or ($mode -ceq 'same-protocol-mixed' -and $Trial -eq 2) -or ($mode -ceq 'same-record-mixed' -and $Trial -eq 1))
    $artifactWrites = if ($v2Artifact) { 1 } elseif ($Protocol -ceq 'v1') { 3 } else { 0 }
    $runtimeWrites = if ($Protocol -ceq 'v1') { 3 } else { 0 }
    $requests = if ($Protocol -ceq 'v1') { 10 } elseif ($Protocol -ceq 'v2') { 2 } else { 4 }
    $duration = if ($Protocol -ceq 'v1') { 500 } elseif ($Protocol -ceq 'v2' -and $mode -ceq 'latency-fail') { 200 } elseif ($Protocol -ceq 'v2') { 110 } else { 100 }
    $revision = [string]$named.SourceRevision
    $tree = [string]$named.SourceCommitTree
    if ($mode -ceq 'bad-source' -and $Protocol -ceq 'v2') { $revision = '0' * 40 }
    $freshSessions = if ($Protocol -ceq 'v1') { 5 } else { 1 }
    if ($mode -cin @('direct-sessions','unavailable-direct-sessions') -and $Protocol -ceq 'v2') { $freshSessions = 2 }
    $journal = if ($Protocol -ceq 'v1') { @('PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE') } else { @() }
    if ($mode -ceq 'v1-journal' -and $Protocol -ceq 'v1') { $journal = @('PLAN_REVIEW','IMPLEMENT','TEST','DONE') }
    $targetJournal = if ($Protocol -ceq 'v1') { @('alpha','alpha','beta','beta','beta') } else { @() }
    if ($mode -cin @('v1-target','mixed-fail-unavailable') -and $Protocol -ceq 'v1') { $targetJournal = @('alpha','beta','beta','beta','beta') }
    $recordTrial = if ($mode -ceq 'wrong-trial-number' -and $Protocol -ceq 'v2' -and $Trial -eq 1) { 2 } else { $Trial }
    return [ordered]@{
        trial=$recordTrial;workspace_baseline_revision=$baseline;status=$(if($unavailable){'unavailable'}else{'measured'});diagnostic=$(if($unavailable){'otel-trace-missing'}else{$null});completion_passed=(-not $unavailable);outcome='completed';reason_code='completed'
        workflow_contract=$(if($Protocol-ceq'v1'){'confirmed-plan-to-done'}else{'new-task'});workflow_completed=$true;fresh_sessions=$freshSessions
        v1_stage_journal=$journal;v1_target_journal=$targetJournal;v1_validator_passed=$true
        source_binding=[ordered]@{status='bound';revision=$revision;commit_tree_oid=$tree;verification='git-head-tree-clean/v1';reason='fixture source binding'}
        host_turns=[ordered]@{status='measured';value=$(if($Protocol-ceq'v1'){5}else{1});basis='codex-jsonl-turn.started';reason='fixture'}
        successful_request_sends=[ordered]@{status=$(if($sendUnavailable){'unavailable'}else{'measured'});value=$(if($sendUnavailable){$null}else{$requests});basis='codex-0.144.4-successful-websocket-send/v2';reason='fixture'}
        completed_agent_messages=1;total_duration_ms=$duration;sum_codex_process_duration_ms=$duration;first_useful_action_ms=10
        tool_calls=[ordered]@{command=1;mcp=0;web_search=0;file_change=1;total=2}
        loaded_skills=[ordered]@{status='unavailable';value=$null;reason='fixture'};skill_file_command_matches=[ordered]@{status='measured';value=0;reason='fixture'};loaded_files=[ordered]@{status='unavailable';value=$null;reason='fixture'}
        artifact_writes=$artifactWrites;runtime_writes=$runtimeWrites;unexpected_writes=0;raw_trace_deleted=$(if($mode-ceq'raw-trace' -and $Protocol-ceq'v2'){$false}else{$true});post_trial_diagnostics=@()
        tokens=[ordered]@{status='measured';input=1;cached_input=0;output=1}
    }
}
'@
    Write-Utf8 (Join-Path $fixture 'scripts\host-benchmark\HostBenchmark.Trial.ps1') $stub
    Commit-GitFixture $fixture

    $templateRoot = Join-Path $scratch 'trial-templates'
    foreach ($templateName in @('workspace-direct','workspace-v1')) {
        $workspaceTemplate = Join-Path $templateRoot $templateName
        Initialize-GitFixture $workspaceTemplate
        [void](Invoke-Git $workspaceTemplate @('config','core.hooksPath','NUL'))
        [void](Invoke-Git $workspaceTemplate @('config','core.longpaths','true'))
        [void](Invoke-Git $workspaceTemplate @('config','user.name','Harness Fixture'))
        [void](Invoke-Git $workspaceTemplate @('config','user.email','harness-fixture@example.invalid'))
        Write-Utf8 (Join-Path $workspaceTemplate 'src\value.txt') 'alpha'
        Write-Utf8 (Join-Path $workspaceTemplate 'staged-only.txt') 'baseline'
        if ($templateName -ceq 'workspace-v1') {
            Write-Utf8 (Join-Path $workspaceTemplate 'docs\tasks\host-benchmark-fixed-workflow\plan.md') 'stage: PLAN'
            Write-Utf8 (Join-Path $workspaceTemplate '.assistant\运行时\当前任务.md') 'initial current'
            Write-Utf8 (Join-Path $workspaceTemplate '.assistant\运行时\恢复索引.md') 'initial index'
            Write-Utf8 (Join-Path $workspaceTemplate '.assistant\运行时\tasks\host-benchmark-fixed-workflow.md') 'initial task'
        }
        Commit-GitFixture $workspaceTemplate
    }
    $sourceTemplate = Join-Path $templateRoot 'source'
    $templateCloneOutput = @(& git -c core.longpaths=true clone --no-local --no-checkout --quiet -- $fixture $sourceTemplate 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "fixture source template clone failed: $($templateCloneOutput -join ' | ')" }
    [void](Invoke-Git $sourceTemplate @('config','core.longpaths','true'))
    $fixtureRevision = (@(Invoke-Git $fixture @('rev-parse','HEAD')) -join '').Trim()
    [void](Invoke-Git $sourceTemplate @('-c','core.hooksPath=NUL','checkout','--quiet','--detach',$fixtureRevision,'--'))
    $script:hostBenchmarkTemplateRoot = $templateRoot
    $templateDigestBefore = Get-DirectoryContentDigest -Root $templateRoot
    $copyProbe = Join-Path $scratch 'template-copy-probe'
    Copy-Item -LiteralPath (Join-Path $templateRoot 'workspace-direct') -Destination $copyProbe -Recurse -Force
    $templateIdentity = Get-HostFileSystemIdentity -Path (Join-Path $templateRoot 'workspace-direct\src\value.txt')
    $copyIdentity = Get-HostFileSystemIdentity -Path (Join-Path $copyProbe 'src\value.txt')
    Check ([string]$templateIdentity.volume -cne [string]$copyIdentity.volume -or [string]$templateIdentity.file_id -cne [string]$copyIdentity.file_id) 'workspace template copy reused the source file identity'
    Write-Utf8 (Join-Path $copyProbe 'src\value.txt') 'beta'
    Check (Test-HostExactUtf8File -Path (Join-Path $templateRoot 'workspace-direct\src\value.txt') -ExpectedText 'alpha') 'workspace template changed through a copied trial file'
    Remove-Item -LiteralPath $copyProbe -Recurse -Force

    $authBytesBefore = [IO.File]::ReadAllBytes((Join-Path $authHome 'auth.json'))
    $overlapOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $fixture 'scripts\run-host-benchmark.ps1') -RepoRoot $fixture -OutputPath (Join-Path $authHome 'auth.json') -CodexHome $authHome -Trials 1 -MaxRoundTrips 1 -TimeoutSeconds 30 2>&1 | ForEach-Object { [string]$_ })
    $overlapExit = $LASTEXITCODE
    $authBytesAfter = [IO.File]::ReadAllBytes((Join-Path $authHome 'auth.json'))
    Check ($overlapExit -ne 0 -and ($overlapOutput -join "`n") -match 'must not overlap the dedicated Codex home' -and [Convert]::ToHexString($authBytesAfter) -ceq [Convert]::ToHexString($authBytesBefore)) 'report output was allowed to overlap or replace the dedicated auth home'

    $outputAlias = Join-Path $scratch 'output-auth-alias'
    [void](New-Item -ItemType Junction -Path $outputAlias -Target $authHome -ErrorAction Stop)
    try {
        $aliasOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $fixture 'scripts\run-host-benchmark.ps1') -RepoRoot $fixture -OutputPath (Join-Path $outputAlias 'auth.json') -CodexHome $authHome -Trials 1 -MaxRoundTrips 1 -TimeoutSeconds 30 2>&1 | ForEach-Object { [string]$_ })
        $aliasExit = $LASTEXITCODE
        $authBytesAfterAlias = [IO.File]::ReadAllBytes((Join-Path $authHome 'auth.json'))
        Check ($aliasExit -ne 0 -and ($aliasOutput -join "`n") -match 'link-alias-rejected|must not overlap' -and [Convert]::ToHexString($authBytesAfterAlias) -ceq [Convert]::ToHexString($authBytesBefore)) 'physical output alias reached or replaced the dedicated auth home'
    } finally {
        Remove-Item -LiteralPath $outputAlias -Force
    }

    $externalScratch = Join-Path $scratch 'external-scratch-target'
    Write-Utf8 (Join-Path $externalScratch 'marker.txt') 'preserve'
    $scratchJunction = Join-Path $fixture '.assistant'
    [void](New-Item -ItemType Junction -Path $scratchJunction -Target $externalScratch -ErrorAction Stop)
    try {
        $junctionOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $fixture 'scripts\run-host-benchmark.ps1') -RepoRoot $fixture -OutputPath (Join-Path $scratch 'scratch-junction-report.json') -Trials 1 -MaxRoundTrips 1 -TimeoutSeconds 30 2>&1 | ForEach-Object { [string]$_ })
        $junctionExit = $LASTEXITCODE
        Check ($junctionExit -ne 0 -and ($junctionOutput -join "`n") -match 'reparse point' -and (Test-Path -LiteralPath (Join-Path $externalScratch 'marker.txt') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $externalScratch '运行时'))) 'scratch junction escaped the repository or modified its external target'
    } finally {
        Remove-Item -LiteralPath $scratchJunction -Force
    }

    $pass = Invoke-FixtureRunner $fixture $scratch 'pass' 3
    $expectedOrder = @('bare1','v11','v21','v12','v22','bare2','v23','bare3','v13')
    $passQualified = $pass.ExitCode -eq 0 -and $null -ne $pass.Report -and [bool]$pass.Report.performance.eligible
    Check $passQualified 'clean 3x3 fixture did not qualify'
    Check (@(Compare-Object $expectedOrder $pass.Order -SyncWindow 0).Count -eq 0) '3x3 rotating execution order changed'
    Check (@($pass.Report.execution.actual_trial_order).Count -eq 9) '3x3 report omitted execution-order records'
    Check ([string]$pass.Report.source.execution_mode -ceq 'clean-commit-clone' -and [string]$pass.Report.source.commit_tree_oid -match '^[0-9a-f]{40,64}$') 'clean report omitted native commit source identity'
    Check ([bool]$pass.Report.source.input_head_binding.start -and [bool]$pass.Report.source.input_head_binding.end) 'clean report did not bind live execution inputs to HEAD blobs'

    foreach ($case in @(
        [pscustomobject]@{Mode='wrong-target-bytes';Message='Runner accepted non-exact target bytes reported as complete'},
        [pscustomobject]@{Mode='advanced-head';Message='Runner accepted a model-created workspace commit'},
        [pscustomobject]@{Mode='ignored-source';Message='Runner accepted ignored tamper in the independent source checkout'},
        [pscustomobject]@{Mode='linked-target';Message='Runner accepted a hard-linked target outside the workspace'},
        [pscustomobject]@{Mode='junction-target';Message='Runner accepted a junction-backed target outside the workspace'},
        [pscustomobject]@{Mode='hidden-index-flag';Message='Runner accepted a write hidden by an unsafe Git index flag'}
    )) {
        $result = Invoke-FixtureRunner $fixture $scratch $case.Mode 1
        $v2Trial = if ($null -eq $result.Report) { $null } else { @($result.Report.protocols.v2.trials)[0] }
        Check ($result.ExitCode -eq 1 -and $null -ne $v2Trial -and -not [bool]$v2Trial.runner_evidence_passed) $case.Message
    }

    $single = Invoke-FixtureRunner $fixture $scratch 'single' 1
    Check ($single.ExitCode -eq 1 -and $null -ne $single.Report -and -not [bool]$single.Report.performance.eligible -and [string]$single.Report.status -ceq 'fail') 'Trials=1 was allowed to satisfy release eligibility'

    foreach ($case in @(
        [pscustomobject]@{Mode='v2-artifact';Protocol='v2';Message='v2 artifact write was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='bad-source';Protocol='v2';Message='source identity mismatch was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='raw-trace';Protocol='v2';Message='retained raw trace was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='v1-journal';Protocol='v1';Message='invalid v1 stage journal was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='v1-target';Protocol='v1';Message='invalid v1 target timing was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='direct-sessions';Protocol='v2';Message='multi-session Direct trial was allowed to satisfy release eligibility'},
        [pscustomobject]@{Mode='missing-workspace';Protocol='v2';Message='self-reported trial without workspace evidence was accepted'},
        [pscustomobject]@{Mode='wrong-artifact-path';Protocol='v1';Message='same artifact count with a wrong path was accepted'},
        [pscustomobject]@{Mode='staged-only';Protocol='v2';Message='staged-only unexpected write was accepted'},
        [pscustomobject]@{Mode='wrong-trial-number';Protocol='v2';Message='trial record number was not bound to the outer trial'}
    )) {
        $result = Invoke-FixtureRunner $fixture $scratch $case.Mode 1
        $protocolRecord = if ($null -eq $result.Report) { $null } else { $result.Report.protocols.([string]$case.Protocol) }
        Check ($result.ExitCode -eq 1 -and $null -ne $protocolRecord -and [int]$protocolRecord.runner_contract_failures -gt 0 -and -not [bool]$result.Report.performance.eligible) $case.Message
    }

    $unavailable = Invoke-FixtureRunner $fixture $scratch 'unavailable' 3
    Check ($unavailable.ExitCode -eq 2 -and $null -ne $unavailable.Report -and -not [bool]$unavailable.Report.performance.eligible -and [string]$unavailable.Report.status -ceq 'unavailable') 'request measurement unavailable did not deterministically exit 2'
    $sendUnavailable = Invoke-FixtureRunner $fixture $scratch 'send-unavailable' 3
    Check ($sendUnavailable.ExitCode -eq 2 -and $null -ne $sendUnavailable.Report -and [string]$sendUnavailable.Report.status -ceq 'unavailable') 'mislabeled request-send unavailability was not promoted to exit 2'
    $mixedFailure = Invoke-FixtureRunner $fixture $scratch 'mixed-fail-unavailable' 3
    Check ($mixedFailure.ExitCode -eq 1 -and $null -ne $mixedFailure.Report -and [string]$mixedFailure.Report.status -ceq 'fail') 'known contract failure was masked by an unavailable measurement'
    $sameProtocolFailure = Invoke-FixtureRunner $fixture $scratch 'same-protocol-mixed' 3
    Check ($sameProtocolFailure.ExitCode -eq 1 -and $null -ne $sameProtocolFailure.Report -and [string]$sameProtocolFailure.Report.status -ceq 'fail') 'same-protocol contract failure was masked by an unavailable measurement'
    $sameRecordFailure = Invoke-FixtureRunner $fixture $scratch 'same-record-mixed' 3
    Check ($sameRecordFailure.ExitCode -eq 1 -and $null -ne $sameRecordFailure.Report -and [string]$sameRecordFailure.Report.status -ceq 'fail') 'same-record contract failure was masked by an unavailable measurement'
    $unavailableCompletedFailure = Invoke-FixtureRunner $fixture $scratch 'unavailable-completed-violation' 3
    Check ($unavailableCompletedFailure.ExitCode -eq 1 -and $null -ne $unavailableCompletedFailure.Report -and [string]$unavailableCompletedFailure.Report.status -ceq 'fail') 'completed contract violation was masked by unavailable request measurement status'
    $unavailableDirectFailure = Invoke-FixtureRunner $fixture $scratch 'unavailable-direct-sessions' 3
    Check ($unavailableDirectFailure.ExitCode -eq 1 -and $null -ne $unavailableDirectFailure.Report -and [string]$unavailableDirectFailure.Report.status -ceq 'fail' -and [bool]$unavailableDirectFailure.Report.protocols.v2.trials[0].runner_evidence_passed -and [int]$unavailableDirectFailure.Report.protocols.v2.trials[0].fresh_sessions -eq 2 -and -not [bool]$unavailableDirectFailure.Report.protocols.v2.trials[0].completion_passed) 'Direct session overrun with valid disk evidence was masked by unavailable request measurement status'

    $exception = Invoke-FixtureRunner $fixture $scratch 'exception' 3
    Check ($exception.ExitCode -eq 2 -and $null -ne $exception.Report -and [string]$exception.Report.status -ceq 'unavailable' -and (@($exception.Report.protocols.v2.trials | Where-Object {$_.diagnostic -ceq 'isolated-auth-home-unavailable'}).Count -eq 1)) 'trial exception did not produce a sanitized unavailable report'

    $dirtyPath = Join-Path $fixture '目录\未跟踪.txt'
    Write-Utf8 $dirtyPath '诊断'
    $dirty = Invoke-FixtureRunner $fixture $scratch 'latency-fail' 3
    Check ($dirty.ExitCode -eq 2 -and $null -ne $dirty.Report -and [bool]$dirty.Report.source_dirty -and -not [bool]$dirty.Report.source_state_stable -and -not [bool]$dirty.Report.performance.eligible -and [string]$dirty.Report.status -ceq 'unavailable' -and [string]$dirty.Report.performance.direct_latency.status -ceq 'fail' -and [string]$dirty.Report.source.execution_mode -ceq 'live-dirty-diagnostic') 'dirty source with a diagnostic latency failure was not kept unavailable'
    Remove-Item -LiteralPath (Join-Path $fixture '目录') -Recurse -Force

    $hiddenInput = Join-Path $fixture 'scripts\host-benchmark\HostBenchmark.Otel.ps1'
    [void](Invoke-Git $fixture @('update-index','--assume-unchanged','scripts/host-benchmark/HostBenchmark.Otel.ps1'))
    [IO.File]::AppendAllText($hiddenInput,"`n# hidden execution-input tamper`n",[Text.UTF8Encoding]::new($false))
    $hiddenSource = Invoke-FixtureRunner $fixture $scratch 'pass' 3
    Check ($hiddenSource.ExitCode -eq 2 -and $null -ne $hiddenSource.Report -and [bool]$hiddenSource.Report.source_dirty -and -not [bool]$hiddenSource.Report.source.input_head_binding.start -and [string]$hiddenSource.Report.status -ceq 'unavailable') 'assume-unchanged live execution input was not detected independently from Git status'
    Check ((Get-DirectoryContentDigest -Root $templateRoot) -ceq $templateDigestBefore) 'shared qualification templates changed during trial execution'
} finally {
    if (Test-Path -LiteralPath $scratch -PathType Container) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

Write-Output "Host benchmark qualification checks: $checks"
if ($failures.Count) { $failures | ForEach-Object { Write-Output "- FAIL: $_" }; exit 1 }
Write-Output "STATUS: PASS ($checks checks)"
exit 0
