[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Pass([string]$Message) { $script:Passes.Add($Message) | Out-Null }
function Fail([string]$Message) { $script:Failures.Add($Message) | Out-Null }
function Check([bool]$Condition, [string]$Success, [string]$Failure) { if ($Condition) { Pass $Success } else { Fail $Failure } }

function Write-BomText([string]$Path, [string]$Content) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($true))
}

function Write-NoBomText([string]$Path, [string]$Content) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function New-WorkspaceFixture([string]$Root, [string]$TaskId) {
    $taskDir = Join-Path $Root "docs\tasks\$TaskId"
    $mockHost = Join-Path $Root '.mock-host\codex.ps1'
    $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    $state = [ordered]@{
        schema_version = 'task-state/v2'; task_id = $TaskId; version = 1; status = 'ready'
        identity = 'new'; intent = 'write'; requirement_state = 'clear'; execution_profile = 'governed'
        persistence = 'durable'; contract_path = "docs/tasks/$TaskId/contract.json"
        contract_digest = ('sha256:' + ('a' * 64)); block_reason = $null
        policies = [ordered]@{ plan_required = $true; approval_required = $false; rollback_required = $true; independent_review_required = $false; verification_required = $true }
        approvals = @(); evidence_path = $null; created_at = $timestamp; updated_at = $timestamp
    }
    $contract = [ordered]@{ schema_version = 'requirement-contract/v1'; task_id = $TaskId; acceptance = @('model-neutral') }
    Write-BomText (Join-Path $taskDir 'plan.md') "---`ntask_id: $TaskId`nstage: PLAN`ntool: codex`nupdated: 2026-07-14`n---`n# Model Neutral Fixture`n"
    Write-NoBomText (Join-Path $taskDir 'contract.json') ($contract | ConvertTo-Json -Depth 10)
    Write-NoBomText (Join-Path $Root ".assistant\runtime\tasks\$TaskId\task.json") ($state | ConvertTo-Json -Depth 10)
    Write-NoBomText $mockHost @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$argv = [string[]]$args
$modelIndex = [Array]::IndexOf($argv, '-m')
$sessionIndex = [Array]::IndexOf($argv, '--')
if ($argv[0] -cne 'exec' -or $modelIndex -lt 0) { throw 'unexpected mock Host invocation' }
$record = [ordered]@{
    task = [Console]::In.ReadToEnd()
    workspace = [Environment]::CurrentDirectory
    session = $(if ($argv -ccontains 'resume' -and $sessionIndex -ge 0) { $argv[$sessionIndex + 1] } else { '' })
    model = $argv[$modelIndex + 1]
    readonly = ($argv -ccontains 'read-only' -or $argv -ccontains 'sandbox_mode="read-only"')
    discovered_host = [string](Get-Command codex -ErrorAction Stop).Path
}
[Console]::Out.WriteLine((@{type='thread.started';thread_id='fixture-session'} | ConvertTo-Json -Compress))
[Console]::Out.WriteLine((@{type='item.completed';item=@{type='agent_message';text=($record | ConvertTo-Json -Compress)}} | ConvertTo-Json -Depth 5 -Compress))
exit 0
'@
    return [pscustomobject]@{
        Root = $Root
        TaskId = $TaskId
        Contract = Join-Path $taskDir 'contract.json'
        State = Join-Path $Root ".assistant\runtime\tasks\$TaskId\task.json"
        Plan = Join-Path $taskDir 'plan.md'
        MockHost = $mockHost
    }
}

function Invoke-Carrier([object]$Fixture, [string]$Model, [string]$Session = '') {
    $outputPath = Join-Path $Fixture.Root ('host-output-' + [guid]::NewGuid().ToString('N') + '.json')
    $arguments = @('-Task',"model=$Model",'-Workspace',$Fixture.Root,'-Model',$Model,'-ReadOnly','-Isolated','-Quiet','-AgentOutputOnly','-Output',$outputPath,'-TimeoutSeconds','15')
    if (-not [string]::IsNullOrWhiteSpace($Session)) { $arguments += @('-Session',$Session) }
    $previousExecutable = $env:CODEX_EXECUTABLE
    $previousPath = $env:PATH
    $powerShellPath = (Get-Process -Id $PID).Path
    try {
        # Exercise discovery without any installed Codex or inherited PATH entry.
        $env:PATH = Split-Path -Parent $Fixture.MockHost
        $env:CODEX_EXECUTABLE = $Fixture.MockHost
        $output = @(& $powerShellPath -NoProfile -NonInteractive -File $script:CarrierPath @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $previousExecutable) { Remove-Item Env:CODEX_EXECUTABLE -ErrorAction Ignore } else { $env:CODEX_EXECUTABLE = $previousExecutable }
        if ($null -eq $previousPath) { Remove-Item Env:PATH -ErrorAction Ignore } else { $env:PATH = $previousPath }
    }
    if ($exitCode -ne 0) { throw ('model-neutrality carrier fixture failed: ' + ($output -join ' | ')) }
    $record = if ($exitCode -eq 0 -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        Get-Content -LiteralPath $outputPath -Raw -Encoding utf8 | ConvertFrom-Json
    } else { $null }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output; Record = $record }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$script:CarrierPath = Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
$adapterKernelPath = Join-Path $RepoRoot 'scripts\lib\Harness.AdapterDelegation.psm1'
$script:Passes = [Collections.Generic.List[string]]::new()
$script:Failures = [Collections.Generic.List[string]]::new()
$repoBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('harness-model-neutral-' + [guid]::NewGuid().ToString('N'))

try {
    $taskSchemaPath = Join-Path $RepoRoot 'schemas\task-state.schema.json'
    $taskSchema = Get-Content -LiteralPath $taskSchemaPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Check ($taskSchema.additionalProperties -eq $false -and -not $taskSchema.properties.Contains('model') -and -not $taskSchema.properties.Contains('tool')) `
        'task-state schema excludes model/tool and rejects unknown business fields' 'task-state schema admits model/tool business fields'

    $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    $validState = [ordered]@{ schema_version='task-state/v2';task_id='neutral-schema';version=1;status='ready';identity='new';intent='write';requirement_state='clear';execution_profile='direct';persistence='ephemeral';contract_path=$null;contract_digest=$null;block_reason=$null;policies=[ordered]@{plan_required=$false;approval_required=$false;rollback_required=$false;independent_review_required=$false;verification_required=$true};approvals=@();evidence_path=$null;created_at=$timestamp;updated_at=$timestamp }
    $withModel = [ordered]@{}; foreach ($key in $validState.Keys) { $withModel[$key] = $validState[$key] }; $withModel.model = 'host-model-a'
    $withTool = [ordered]@{}; foreach ($key in $validState.Keys) { $withTool[$key] = $validState[$key] }; $withTool.tool = 'codex'
    $validJson = $validState | ConvertTo-Json -Depth 20 -Compress
    $modelJson = $withModel | ConvertTo-Json -Depth 20 -Compress
    $toolJson = $withTool | ConvertTo-Json -Depth 20 -Compress
    Check ((Test-Json -Json $validJson -SchemaFile $taskSchemaPath -WarningAction SilentlyContinue) -and
        -not (Test-Json -Json $modelJson -SchemaFile $taskSchemaPath -WarningAction SilentlyContinue -ErrorAction SilentlyContinue) -and
        -not (Test-Json -Json $toolJson -SchemaFile $taskSchemaPath -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)) `
        'task-state schema accepts neutral state and rejects injected model/tool fixtures' 'task-state model/tool rejection fixture failed'

    foreach ($schemaName in @('event','evidence')) {
        $schema = Get-Content -LiteralPath (Join-Path $RepoRoot "schemas\$schemaName.schema.json") -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $actor = $schema.definitions.actor
        Check ($actor.required -contains 'host' -and $actor.required -contains 'model' -and $actor.properties.Contains('backend')) `
            "$schemaName actor carries host/model/backend execution metadata" "$schemaName actor metadata is incomplete"
    }

    foreach ($profileName in @('harness-default-codex','harness-default-claude')) {
        $profileText = Get-Content -LiteralPath (Join-Path $RepoRoot "agent-configs\profiles\$profileName.yaml") -Raw -Encoding utf8
        Check ($profileText -match '(?m)^model:\s*inherit\s*$') "$profileName inherits the host model" "$profileName still pins a concrete model"
    }
    $adapterKernelText = Get-Content -LiteralPath $adapterKernelPath -Raw -Encoding utf8
    Check ((Test-Path -LiteralPath $script:CarrierPath -PathType Leaf) -and $adapterKernelText -match 'v1-delegation-retired') `
        'standalone Codex carrier remains available while the Stage delegation ABI is retired' 'carrier availability or legacy delegation retirement is missing'
    Check ((Test-Path (Join-Path $RepoRoot 'skills\codex\scripts\ask_codex.ps1')) -and (Test-Path (Join-Path $RepoRoot 'skills\codex\scripts\ask_codex.sh'))) `
        'legacy ask_codex compatibility shims remain present' 'legacy ask_codex compatibility shim is missing'

    $fixtureA = New-WorkspaceFixture -Root (Join-Path $tempRoot 'workspace-a') -TaskId 'model-neutral-a'
    $fixtureB = New-WorkspaceFixture -Root (Join-Path $tempRoot 'workspace-b') -TaskId 'model-neutral-b'
    $aContractHash = (Get-FileHash -LiteralPath $fixtureA.Contract -Algorithm SHA256).Hash
    $aStateHash = (Get-FileHash -LiteralPath $fixtureA.State -Algorithm SHA256).Hash
    $bContractHash = (Get-FileHash -LiteralPath $fixtureB.Contract -Algorithm SHA256).Hash
    $bStateHash = (Get-FileHash -LiteralPath $fixtureB.State -Algorithm SHA256).Hash
    $aPlanHash = (Get-FileHash -LiteralPath $fixtureA.Plan -Algorithm SHA256).Hash
    $bPlanHash = (Get-FileHash -LiteralPath $fixtureB.Plan -Algorithm SHA256).Hash

    $aFirst = Invoke-Carrier -Fixture $fixtureA -Model 'host-model/one' -Session 'workspace-a-session'
    $aSecond = Invoke-Carrier -Fixture $fixtureA -Model 'host-model/two' -Session 'workspace-a-session'
    $bFirst = Invoke-Carrier -Fixture $fixtureB -Model 'host-model/three'
    Check ($aFirst.Record.discovered_host -ceq $fixtureA.MockHost -and
        $aSecond.Record.discovered_host -ceq $fixtureA.MockHost -and
        $bFirst.Record.discovered_host -ceq $fixtureB.MockHost) `
        'carrier command discovery uses only each owned fake Host without installed Codex' 'carrier command discovery escaped the fake Host fixture'
    $aFirstSessionProperty = if ($null -eq $aFirst.Record) { $null } else { $aFirst.Record.PSObject.Properties['session'] }
    $aSecondSessionProperty = if ($null -eq $aSecond.Record) { $null } else { $aSecond.Record.PSObject.Properties['session'] }
    $aFirstSession = if ($null -eq $aFirstSessionProperty) { '' } else { [string]$aFirstSessionProperty.Value }
    $aSecondSession = if ($null -eq $aSecondSessionProperty) { '' } else { [string]$aSecondSessionProperty.Value }
    $bSessionProperty = if ($null -eq $bFirst.Record) { $null } else { $bFirst.Record.PSObject.Properties['session'] }
    $bSession = if ($null -eq $bSessionProperty) { '' } else { [string]$bSessionProperty.Value }
    Check ($aFirst.ExitCode -eq 0 -and $aSecond.ExitCode -eq 0 -and
        $aFirst.Record.model -ceq 'host-model/one' -and $aSecond.Record.model -ceq 'host-model/two') `
        'host model override reaches the standalone carrier without changing its contract' 'host model override did not reach the standalone carrier'
    Check ($bFirst.ExitCode -eq 0 -and $bFirst.Record.workspace -ceq $fixtureB.Root -and [string]::IsNullOrEmpty($bSession)) `
        'workspace B starts without inheriting workspace A resume session' 'workspace B inherited another workspace resume session'
    Check ($aFirstSession -ceq 'workspace-a-session' -and $aSecondSession -ceq 'workspace-a-session' -and $aFirst.Record.workspace -ceq $fixtureA.Root) `
        'explicit resume session remains scoped to its requested workspace fixture' 'explicit resume session lost its workspace scope'
    Check ($aFirst.ExitCode -eq 0 -and $aSecond.ExitCode -eq 0 -and $bFirst.ExitCode -eq 0 -and $aFirst.Record.readonly -and $aSecond.Record.readonly -and $bFirst.Record.readonly) `
        'new and resumed carrier calls preserve read-only mode' 'carrier model/session handling weakened read-only mode'
    Check ($aContractHash -ceq (Get-FileHash $fixtureA.Contract -Algorithm SHA256).Hash -and
        $aStateHash -ceq (Get-FileHash $fixtureA.State -Algorithm SHA256).Hash -and
        $bContractHash -ceq (Get-FileHash $fixtureB.Contract -Algorithm SHA256).Hash -and
        $bStateHash -ceq (Get-FileHash $fixtureB.State -Algorithm SHA256).Hash -and
        $aPlanHash -ceq (Get-FileHash $fixtureA.Plan -Algorithm SHA256).Hash -and
        $bPlanHash -ceq (Get-FileHash $fixtureB.Plan -Algorithm SHA256).Hash) `
        'model switching and resume leave Contract, task state, and retained plan byte-identical' 'carrier model/resume handling migrated Contract, task state, or retained plan'
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if (-not $resolvedTemp.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedTemp) -cnotmatch '^harness-model-neutral-[0-9a-f]{32}$') { throw 'model fixture cleanup escaped its root' }
    if (Test-Path -LiteralPath $resolvedTemp) { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue }
}

$repoAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Check (@(Compare-Object $repoBefore $repoAfter).Count -eq 0) 'model-neutrality verifier performs no repository writes' 'model-neutrality verifier changed repository state'
foreach ($item in $script:Passes) { "[PASS] $item" }
foreach ($item in $script:Failures) { "[FAIL] $item" }
if ($script:Failures.Count) { "STATUS: FAIL ($($script:Failures.Count) failed)"; exit 1 }
"STATUS: PASS ($($script:Passes.Count) checks)"
exit 0
