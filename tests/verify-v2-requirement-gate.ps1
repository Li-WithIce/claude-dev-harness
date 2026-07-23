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

function Test-KeySet {
    param([System.Collections.IDictionary]$Value, [string[]]$Expected)
    return @(Compare-Object @($Expected | Sort-Object) @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)).Count -eq 0
}

function Invoke-TaskProcess {
    param(
        [string]$TaskScript,
        [string]$RequestFile,
        [string]$TaskRepoRoot,
        [string]$WorkspaceRoot,
        [switch]$AsJson,
        [string]$Command = 'inspect'
    )

    $arguments = @($Command, '-RequestFile', $RequestFile, '-RepoRoot', $TaskRepoRoot, '-WorkspaceRoot', $WorkspaceRoot)
    if ($AsJson) { $arguments += '-AsJson' }
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
    return [pscustomobject]@{ Exited=$exited; ExitCode=$exitCode; StdOut=$stdout; StdErr=$stderr }
}

function Write-JsonRequest {
    param([string]$Path, [System.Collections.IDictionary]$Value)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
}

function New-ScenarioRequest {
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Case)
    $request = [ordered]@{}
    foreach ($key in $Base.Keys) { $request[$key] = $Base[$key] }
    foreach ($key in $Case.Keys) {
        if ($key -notin @('id','expected_state','expected')) { $request[$key] = $Case[$key] }
    }
    return $request
}

function Assert-ErrorWire {
    param([pscustomobject]$Result, [string]$Label)
    Assert-True -Condition ($Result.Exited -and $Result.ExitCode -eq 2 -and [string]::IsNullOrEmpty($Result.StdOut) -and -not [string]::IsNullOrWhiteSpace($Result.StdErr)) -Success ("{0} fails with exit 2 on stderr only" -f $Label) -Failure ("{0} wire mismatch: exit={1} stdout=[{2}] stderr=[{3}]" -f $Label,$Result.ExitCode,$Result.StdOut,$Result.StdErr)
}

$taskScript = Join-Path $RepoRoot 'scripts\task.ps1'
$modulePath = Join-Path $RepoRoot 'scripts\lib\Harness.Requirement.psm1'
$catalogPath = Join-Path $RepoRoot 'tests\scenarios\requirement-gate\inspect-cases.json'
$schemaPath = Join-Path $RepoRoot 'schemas\requirement-contract.schema.json'
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-v2-pr03-gate-' + [guid]::NewGuid().ToString('N'))
$statusBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)

try {
    New-Item -ItemType Directory -Path (Join-Path $scratchRoot 'evidence') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $scratchRoot 'evidence\helper.txt'), "Invoke-ExistingHelper`n", (New-Object System.Text.UTF8Encoding($false)))

    foreach ($scriptPath in @($taskScript, $modulePath, $PSCommandPath)) {
        Assert-True -Condition (Test-FileHasUtf8Bom -Path $scriptPath) -Success ("{0} has UTF-8 BOM" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} must have UTF-8 BOM" -f (Split-Path -Leaf $scriptPath))
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True -Condition (@($parseErrors).Count -eq 0) -Success ("{0} parses as PowerShell" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} has PowerShell parse errors" -f (Split-Path -Leaf $scriptPath))
    }

    $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    Assert-True -Condition ([string]$catalog.schema_version -ceq 'requirement-gate-scenarios/v1' -and @($catalog.cases).Count -eq 11) -Success 'scenario catalog declares eleven requirement-gate cases' -Failure 'scenario catalog version or case count drifted'
    $scenarioResults = @{}
    $requestPaths = @{}

    foreach ($case in $catalog.cases) {
        $request = New-ScenarioRequest -Base $catalog.base_request -Case $case
        $requestPath = Join-Path $scratchRoot ("{0}.json" -f $case.id)
        Write-JsonRequest -Path $requestPath -Value $request
        $requestPaths[[string]$case.id] = $requestPath
        $run = Invoke-TaskProcess -TaskScript $taskScript -RequestFile $requestPath -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson
        $singleLine = -not [string]::IsNullOrWhiteSpace($run.StdOut) -and $run.StdOut -notmatch "`r|`n"
        $result = $null
        try { $result = $run.StdOut | ConvertFrom-Json -AsHashtable -Depth 50 -ErrorAction Stop } catch {}
        $scenarioResults[[string]$case.id] = $result

        Assert-True -Condition ($run.Exited -and $run.ExitCode -eq 0 -and [string]::IsNullOrEmpty($run.StdErr) -and $singleLine -and $null -ne $result) -Success ("{0} returns one JSON line with exit 0" -f $case.id) -Failure ("{0} process wire failed: exit={1} stderr=[{2}]" -f $case.id,$run.ExitCode,$run.StdErr)
        if ($null -eq $result) { continue }

        Assert-True -Condition ([string]$result.requirement_state -ceq [string]$case.expected_state) -Success ("{0} resolves to {1}" -f $case.id,$case.expected_state) -Failure ("{0} resolved to {1}, expected {2}" -f $case.id,$result.requirement_state,$case.expected_state)
        Assert-True -Condition (Test-KeySet -Value $result -Expected @('command','analysis_profile','requirement_state','confirmed_requirement','contract','blocking_decisions','ask_batch','decision_analysis','repo_evidence','side_effects')) -Success ("{0} uses the stable inspect result keys" -f $case.id) -Failure ("{0} result keys drifted" -f $case.id)
        Assert-True -Condition ([string]$result.command -ceq 'inspect' -and [string]$result.analysis_profile -ceq 'inspect') -Success ("{0} remains in Inspect profile" -f $case.id) -Failure ("{0} escaped Inspect profile" -f $case.id)
        Assert-True -Condition ($result.side_effects.task_state_writes -eq 0 -and $result.side_effects.runtime_writes -eq 0 -and $result.side_effects.artifact_writes -eq 0 -and $result.side_effects.external_writes -eq 0) -Success ("{0} reports zero side effects" -f $case.id) -Failure ("{0} reported a side effect" -f $case.id)

        if ($case.expected.Contains('blockers')) {
            Assert-True -Condition (@($result.blocking_decisions).Count -eq [int]$case.expected.blockers) -Success ("{0} blocker count is exact" -f $case.id) -Failure ("{0} blocker count is wrong" -f $case.id)
        }
        if ($case.expected.Contains('questions')) {
            $questionCount = if ($null -eq $result.ask_batch) { 0 } else { @($result.ask_batch.questions).Count }
            Assert-True -Condition ($questionCount -eq [int]$case.expected.questions) -Success ("{0} Ask batch count is exact" -f $case.id) -Failure ("{0} Ask batch count is wrong" -f $case.id)
            $authorizationSafe = $null -eq $result.ask_batch -or @($result.ask_batch.questions | Where-Object { $_.recommendation_is_authorization -ne $false }).Count -eq 0
            Assert-True -Condition $authorizationSafe -Success ("{0} recommendations never authorize a decision" -f $case.id) -Failure ("{0} recommendation was treated as authorization" -f $case.id)
        }
        if ($case.expected.Contains('product')) {
            Assert-True -Condition (@($result.decision_analysis.product).Count -eq [int]$case.expected.product) -Success ("{0} product analysis count is exact" -f $case.id) -Failure ("{0} product analysis count is wrong" -f $case.id)
        }
        if ($case.expected.Contains('agent')) {
            Assert-True -Condition (@($result.decision_analysis.agent).Count -eq [int]$case.expected.agent) -Success ("{0} resolves the reversible agent choice" -f $case.id) -Failure ("{0} did not resolve the agent choice" -f $case.id)
        }
        if ($case.expected.Contains('conflicts')) {
            Assert-True -Condition (@($result.decision_analysis.conflicts).Count -eq [int]$case.expected.conflicts) -Success ("{0} conflict count is exact" -f $case.id) -Failure ("{0} conflict count is wrong" -f $case.id)
        }
        if ($case.expected.Contains('reason')) {
            Assert-True -Condition (@($result.blocking_decisions.reason) -ccontains [string]$case.expected.reason) -Success ("{0} exposes the expected blocker reason" -f $case.id) -Failure ("{0} omitted blocker reason {1}" -f $case.id,$case.expected.reason)
        }
        if ($case.expected.Contains('repo_status')) {
            Assert-True -Condition (@($result.repo_evidence.status) -ccontains [string]$case.expected.repo_status) -Success ("{0} checks repository evidence before Ask" -f $case.id) -Failure ("{0} repository evidence status is wrong" -f $case.id)
        }
        if ($case.expected.Contains('conflict_type')) {
            Assert-True -Condition (@($result.decision_analysis.conflicts.type) -ccontains [string]$case.expected.conflict_type) -Success ("{0} records lower-authority legacy disagreement" -f $case.id) -Failure ("{0} omitted the legacy disagreement" -f $case.id)
        }
        if ($case.expected.Contains('deferred')) {
            Assert-True -Condition (@($result.ask_batch.deferred) -ccontains [string]$case.expected.deferred) -Success ("{0} defers dependent or overflow questions" -f $case.id) -Failure ("{0} deferred set is wrong" -f $case.id)
        }

        if ([string]$result.requirement_state -ceq 'clear') {
            $contractJson = $result.contract | ConvertTo-Json -Depth 30 -Compress
            $contractValid = Test-Json -Json $contractJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            Assert-True -Condition ($null -ne $result.contract -and $null -eq $result.ask_batch -and $contractValid -and [string]$result.contract.digest -cmatch '^sha256:[0-9a-f]{64}$') -Success ("{0} derives a valid requirement-contract/v1" -f $case.id) -Failure ("{0} clear result has an invalid contract or Ask batch" -f $case.id)
        } else {
            Assert-True -Condition ($null -eq $result.contract -and $null -ne $result.ask_batch) -Success ("{0} emits Ask without deriving a contract" -f $case.id) -Failure ("{0} blocked result derived a contract or omitted Ask" -f $case.id)
        }
    }

    $deterministicFirst = Invoke-TaskProcess -TaskScript $taskScript -RequestFile $requestPaths['clear-explicit-product-decision'] -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson
    $deterministicSecond = Invoke-TaskProcess -TaskScript $taskScript -RequestFile $requestPaths['clear-explicit-product-decision'] -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson
    Assert-True -Condition ($deterministicFirst.StdOut -ceq $deterministicSecond.StdOut) -Success 'identical clear requests produce byte-identical JSON and digest' -Failure 'identical clear requests are nondeterministic'

    $caseConflict = New-ScenarioRequest -Base $catalog.base_request -Case $catalog.cases[0]
    $caseConflict.decisions[0].sources = @(
        [ordered]@{ authority='approved-spec'; source_id='spec-a'; value='Admin' },
        [ordered]@{ authority='approved-spec'; source_id='spec-b'; value='admin' }
    )
    $caseConflictPath = Join-Path $scratchRoot 'case-conflict.json'; Write-JsonRequest -Path $caseConflictPath -Value $caseConflict
    $caseConflictRun = Invoke-TaskProcess -TaskScript $taskScript -RequestFile $caseConflictPath -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson
    $caseConflictResult = $caseConflictRun.StdOut | ConvertFrom-Json -AsHashtable -Depth 50 -ErrorAction Stop
    Assert-True -Condition ($caseConflictRun.ExitCode -eq 0 -and [string]$caseConflictResult.requirement_state -ceq 'blocked' -and @($caseConflictResult.blocking_decisions | Where-Object { $_.reason -ceq 'peer-authority-conflict' }).Count -eq 1) -Success 'case-distinct peer values fail closed as a conflict' -Failure 'case-distinct peer values were silently merged'

    $caseKeys = New-ScenarioRequest -Base $catalog.base_request -Case $catalog.cases[0]
    $caseKeys.decisions = @(
        [ordered]@{ key='Role'; category='authorization_semantics'; question='Upper key?'; impact='Changes authorization.'; options=@('a'); recommended='a'; depends_on=@(); sources=@() },
        [ordered]@{ key='role'; category='authorization_semantics'; question='Lower key?'; impact='Changes authorization.'; options=@('b'); recommended='b'; depends_on=@(); sources=@() }
    )
    $caseKeysPath = Join-Path $scratchRoot 'case-keys.json'; Write-JsonRequest -Path $caseKeysPath -Value $caseKeys
    $caseKeysRun = Invoke-TaskProcess -TaskScript $taskScript -RequestFile $caseKeysPath -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson
    $caseKeysResult = $caseKeysRun.StdOut | ConvertFrom-Json -AsHashtable -Depth 50 -ErrorAction Stop
    $caseKeySet = @($caseKeysResult.ask_batch.questions | ForEach-Object { [string]$_.key })
    Assert-True -Condition ($caseKeysRun.ExitCode -eq 0 -and @($caseKeysResult.blocking_decisions).Count -eq 2 -and $caseKeySet -ccontains 'Role' -and $caseKeySet -ccontains 'role') -Success 'case-distinct decision keys remain independent' -Failure 'case-distinct decision keys collided'

    foreach ($id in @('clear-explicit-product-decision','blocked-critical-product-semantics')) {
        $human = Invoke-TaskProcess -TaskScript $taskScript -RequestFile $requestPaths[$id] -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot
        $lines = @($human.StdOut -split "`r?`n")
        Assert-True -Condition ($human.ExitCode -eq 0 -and [string]::IsNullOrEmpty($human.StdErr) -and $lines.Count -eq 3 -and $lines[0] -match '^requirement_state: (?:clear|blocked)$' -and $lines[1] -match '^blocking_decisions: \d+$' -and $lines[2] -match '^contract_digest: (?:none|sha256:[0-9a-f]{64})$') -Success ("{0} has the stable three-line human output" -f $id) -Failure ("{0} human output drifted: {1}" -f $id,$human.StdOut)
    }

    $malformedPath = Join-Path $scratchRoot 'malformed.json'
    [System.IO.File]::WriteAllText($malformedPath, '{"broken":', (New-Object System.Text.UTF8Encoding($false)))
    Assert-ErrorWire -Result (Invoke-TaskProcess -TaskScript $taskScript -RequestFile $malformedPath -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson) -Label 'malformed JSON'

    $unknownField = New-ScenarioRequest -Base $catalog.base_request -Case $catalog.cases[0]
    $unknownField['unexpected'] = $true
    $unknownPath = Join-Path $scratchRoot 'unknown-field.json'; Write-JsonRequest -Path $unknownPath -Value $unknownField
    Assert-ErrorWire -Result (Invoke-TaskProcess -TaskScript $taskScript -RequestFile $unknownPath -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson) -Label 'unknown envelope field'

    $scalarArray = New-ScenarioRequest -Base $catalog.base_request -Case $catalog.cases[0]
    $scalarArray['acceptance'] = 'not-an-array'
    $scalarPath = Join-Path $scratchRoot 'scalar-array.json'; Write-JsonRequest -Path $scalarPath -Value $scalarArray
    Assert-ErrorWire -Result (Invoke-TaskProcess -TaskScript $taskScript -RequestFile $scalarPath -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson) -Label 'scalar array drift'

    $outsideRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-v2-pr03-outside-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Write-JsonRequest -Path $outsideRoot -Value $catalog.base_request
        Assert-ErrorWire -Result (Invoke-TaskProcess -TaskScript $taskScript -RequestFile $outsideRoot -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson) -Label 'RequestFile containment escape'
    } finally { Remove-Item -LiteralPath $outsideRoot -Force -ErrorAction SilentlyContinue }

    $badRepoCheck = New-ScenarioRequest -Base $catalog.base_request -Case $catalog.cases[0]
    $badRepoCheck['repo_checks'] = @([ordered]@{ id='escape'; path='..\outside.txt'; contains='x' })
    $badRepoPath = Join-Path $scratchRoot 'bad-repo-check.json'; Write-JsonRequest -Path $badRepoPath -Value $badRepoCheck
    Assert-ErrorWire -Result (Invoke-TaskProcess -TaskScript $taskScript -RequestFile $badRepoPath -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson) -Label 'repo evidence containment escape'

    Assert-ErrorWire -Result (Invoke-TaskProcess -TaskScript $taskScript -RequestFile $requestPaths['clear-explicit-product-decision'] -TaskRepoRoot $RepoRoot -WorkspaceRoot $scratchRoot -AsJson -Command 'run') -Label 'unsupported command'

    $fixtureRepo = Join-Path $scratchRoot 'fixture-repo'
    foreach ($relativePath in @('scripts/task.ps1','scripts/lib/Harness.Requirement.psm1','policies/decision-rights.json','schemas/requirement-contract.schema.json')) {
        Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $fixtureRepo -RelativePath $relativePath
    }
    $fixturePolicy = Join-Path $fixtureRepo 'policies\decision-rights.json'
    [System.IO.File]::WriteAllText($fixturePolicy, '{"broken":', (New-Object System.Text.UTF8Encoding($false)))
    Assert-ErrorWire -Result (Invoke-TaskProcess -TaskScript (Join-Path $fixtureRepo 'scripts\task.ps1') -RequestFile $requestPaths['clear-explicit-product-decision'] -TaskRepoRoot $fixtureRepo -WorkspaceRoot $scratchRoot -AsJson) -Label 'malformed decision policy'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'policies\decision-rights.json') -Destination $fixturePolicy -Force
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'schemas\requirement-contract.schema.json'), '{"broken":', (New-Object System.Text.UTF8Encoding($false)))
    Assert-ErrorWire -Result (Invoke-TaskProcess -TaskScript (Join-Path $fixtureRepo 'scripts\task.ps1') -RequestFile $requestPaths['clear-explicit-product-decision'] -TaskRepoRoot $fixtureRepo -WorkspaceRoot $scratchRoot -AsJson) -Label 'malformed contract schema'
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

$statusAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Assert-True -Condition (@(Compare-Object $statusBefore $statusAfter).Count -eq 0) -Success 'requirement-gate verification leaves repository state unchanged' -Failure 'requirement-gate verification changed repository state'

foreach ($check in $script:checks) { Write-Output ("[PASS] {0}" -f $check) }
foreach ($failure in $script:failures) { Write-Output ("[FAIL] {0}" -f $failure) }
if ($script:failures.Count -gt 0) {
    Write-Output ("STATUS: FAIL ({0} failed)" -f $script:failures.Count)
    exit 1
}
Write-Output ("STATUS: PASS ({0} checks)" -f $script:checks.Count)
exit 0
