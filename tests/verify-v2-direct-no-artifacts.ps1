[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
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
    param([string]$Root)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $rootPath -Recurse -Force) {
        $relative = $item.FullName.Substring($rootPath.Length).TrimStart('\','/') -replace '\\','/'
        if ($item.PSIsContainer) { $entries.Add("D|$relative") } else { $entries.Add("F|$relative|$($item.Length)|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant())") }
    }
    return @($entries | Sort-Object)
}

function Merge-Case {
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Case)
    $routeInput = [ordered]@{}
    foreach ($key in $Base.Keys) { $routeInput[$key] = $Base[$key] }
    foreach ($key in $Case.Keys) { if ($key -notin @('id','expected')) { $routeInput[$key] = $Case[$key] } }
    return (($routeInput | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json -AsHashtable -Depth 30)
}

function Invoke-RouteCase {
    param([System.Collections.IDictionary]$RouteInput, [string]$PolicyRepoRoot = $RepoRoot)

    $previousProtocol = $env:HARNESS_PROTOCOL
    try {
        $env:HARNESS_PROTOCOL = [string]$RouteInput.protocol
        return Resolve-HarnessExecutionProfile -RepoRoot $PolicyRepoRoot -Identity $RouteInput.identity -Intent $RouteInput.intent -RequirementState $RouteInput.requirement_state -Persistence $RouteInput.persistence -RiskScores $RouteInput.risk_scores -CriticalTriggers @($RouteInput.critical_triggers) -ChangedPaths @($RouteInput.changed_paths) -CommandText $RouteInput.command_text -Environment $RouteInput.environment -RequestedAlias $RouteInput.requested_alias -Reversible ([bool]$RouteInput.reversible) -VerificationAvailable ([bool]$RouteInput.verification_available) -DurableArtifactsRequested ([bool]$RouteInput.durable_artifacts_requested) -ScopeExpanded ([bool]$RouteInput.scope_expanded) -ProductBlockerDiscovered ([bool]$RouteInput.product_blocker_discovered)
    } finally {
        $env:HARNESS_PROTOCOL = $previousProtocol
    }
}

function Test-Throws {
    param([scriptblock]$Action)
    try { [void](& $Action); return $false } catch { return $true }
}

$modulePath = Join-Path $RepoRoot 'scripts\lib\Harness.Policy.psm1'
$catalogPath = Join-Path $RepoRoot 'tests\scenarios\direct\route-cases.json'
$canonicalPath = Join-Path $RepoRoot 'policies\entry-contract.md'
$architecturePath = Join-Path $RepoRoot 'docs\architecture\policy-engine.md'
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-v2-pr04-direct-' + [guid]::NewGuid().ToString('N'))
$statusBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)

try {
    New-Item -ItemType Directory -Path (Join-Path $scratchRoot '.assistant\runtime') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $scratchRoot 'docs\tasks\legacy') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $scratchRoot '.assistant\runtime\current.json'), '{"sentinel":true}', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $scratchRoot 'docs\tasks\legacy\plan.md'), "legacy sentinel`n", (New-Object System.Text.UTF8Encoding($false)))
    $workspaceBefore = Get-TreeSnapshot -Root $scratchRoot

    foreach ($scriptPath in @($modulePath,$PSCommandPath)) {
        Assert-True -Condition (Test-FileHasUtf8Bom -Path $scriptPath) -Success ("{0} has UTF-8 BOM" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} must have UTF-8 BOM" -f (Split-Path -Leaf $scriptPath))
        $tokens=$null; $parseErrors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
        Assert-True -Condition (@($parseErrors).Count -eq 0) -Success ("{0} parses as PowerShell" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} has PowerShell parse errors" -f (Split-Path -Leaf $scriptPath))
    }
    Import-Module $modulePath -Force -ErrorAction Stop
    $exports = @((Get-Module Harness.Policy).ExportedFunctions.Keys)
    Assert-True -Condition ($exports.Count -eq 1 -and $exports[0] -ceq 'Resolve-HarnessExecutionProfile') -Success 'policy module exports only the profile selector' -Failure 'policy module exported an unplanned surface'

    $canonical = (Get-Content -LiteralPath $canonicalPath -Raw -Encoding utf8) -replace "`r`n?","`n"
    Assert-True -Condition ($canonical -match '`auto_resolves_to`:\s*`existing-v2-or-admitted-v2-new-task`' -and $canonical -match '`v2_entry_activation`:\s*`v2-only-with-new-work-admission`' -and $canonical -match 'new_work=paused') -Success 'entry contract preserves artifact-first Runtime Default routing' -Failure 'entry contract protocol default widened or became ambiguous'
    $entryRouterSkill = Get-Content -LiteralPath (Join-Path $RepoRoot 'skills\entry-router\SKILL.md') -Raw -Encoding utf8
    Assert-True -Condition ($canonical -match 'Selected v2 Direct loads no `entry-router`, `orchestrator`, lifecycle skill, Memory, Team, or Provider' -and $canonical -match 'No task/runtime/current/lifecycle writes' -and $canonical -match 'Legacy lifecycle and shim loading are retired' -and $entryRouterSkill -match 'V1 compatibility entry router' -and $entryRouterSkill -match 'Never load for selected v2 Direct') -Success 'Direct entry avoids v1 lifecycle skills and durable harness writes' -Failure 'Direct entry gained a v1 lifecycle or persistence dependency'
    Assert-True -Condition ($canonical -match 'actual commands/results, self-review, gaps' -and $canonical -match '`not_run`/unavailable is not pass') -Success 'Direct response requires actual commands, results, self-review, and gaps without false pass' -Failure 'Direct evidence summary permits missing or false evidence'
    $architecture = Get-Content -LiteralPath $architecturePath -Raw -Encoding utf8
    Assert-True -Condition ($architecture -match 'Harness\.Policy\.psm1' -and $architecture -match 'Missing, malformed, unknown, or semantically weaker policy fails closed' -and $architecture -match 'no task/runtime/current state' -and $architecture -match 'Explicit v1 is retired') -Success 'policy engine architecture documents canonical authority, Direct zero-write, and rollback' -Failure 'policy engine architecture artifact is missing or contradicts the implementation contract'

    $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    Assert-True -Condition ([string]$catalog.schema_version -ceq 'direct-route-scenarios/v1' -and @($catalog.cases).Count -eq 19) -Success 'Direct scenario catalog declares nineteen route cases' -Failure 'Direct scenario catalog version or case count drifted'
    foreach ($case in $catalog.cases) {
        $routeInput = Merge-Case -Base $catalog.base -Case $case
        $expected = $case.expected
        if ($expected.Contains('error')) {
            Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $routeInput }) -Success "$($case.id) is rejected" -Failure "$($case.id) was admitted"
            continue
        }
        $result = Invoke-RouteCase -RouteInput $routeInput
        $matches = $true
        foreach ($key in $expected.Keys) {
            if ($key -cin @('trigger','capability')) { continue }
            if ($null -eq $expected[$key]) { $matches = $matches -and $null -eq $result[$key] } else { $matches = $matches -and $result[$key] -ceq $expected[$key] }
        }
        if ($expected.Contains('trigger')) { $matches = $matches -and @($result.triggers) -ccontains [string]$expected.trigger }
        if ($expected.Contains('capability')) { $matches = $matches -and @($result.required_capabilities) -ccontains [string]$expected.capability }
        Assert-True -Condition $matches -Success ("{0} selects the expected fail-closed route" -f $case.id) -Failure ("{0} route mismatch: {1}" -f $case.id,($result | ConvertTo-Json -Depth 10 -Compress))

        $zeroSideEffects = $result.side_effects.task_state_writes -eq 0 -and $result.side_effects.runtime_writes -eq 0 -and $result.side_effects.artifact_writes -eq 0 -and $result.side_effects.external_writes -eq 0
        Assert-True -Condition $zeroSideEffects -Success ("{0} policy selection performs zero writes" -f $case.id) -Failure ("{0} reported a write" -f $case.id)
        if ([string]$result.handoff -ceq 'main-agent') {
            $summary = $result.evidence_summary
            Assert-True -Condition ([string]$summary.format -ceq 'direct-response' -and $summary.persisted -eq $false -and $summary.actual_results_only -eq $true -and @(Compare-Object @('changes','focused_verification','self_review','remaining_gaps') @($summary.required_sections)).Count -eq 0) -Success ("{0} carries the ephemeral Direct evidence contract" -f $case.id) -Failure ("{0} Direct evidence contract drifted" -f $case.id)
        } else {
            Assert-True -Condition ($null -eq $result.evidence_summary) -Success ("{0} does not fabricate a Direct evidence summary" -f $case.id) -Failure ("{0} emitted Direct evidence before a Direct handoff" -f $case.id)
        }
    }

    $baseInput = Merge-Case -Base $catalog.base -Case $catalog.cases[0]
    $unknownTrigger = Merge-Case -Base $catalog.base -Case $catalog.cases[0]
    $unknownTrigger.critical_triggers = @('invented_trigger')
    Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $unknownTrigger }) -Success 'unknown Critical triggers fail closed' -Failure 'unknown Critical trigger was accepted'
    $missingScore = Merge-Case -Base $catalog.base -Case $catalog.cases[0]
    $missingScore.risk_scores.Remove('rollback')
    Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $missingScore }) -Success 'missing risk dimensions fail closed' -Failure 'incomplete risk scores were accepted'
    $badScore = Merge-Case -Base $catalog.base -Case $catalog.cases[0]
    $badScore.risk_scores.rollback = 4
    Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $badScore }) -Success 'out-of-range risk scores fail closed' -Failure 'out-of-range risk score was accepted'
    $badProtocol = Merge-Case -Base $catalog.base -Case $catalog.cases[0]
    $badProtocol.protocol = 'V2'
    Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $badProtocol }) -Success 'unknown protocol casing fails closed' -Failure 'invalid HARNESS_PROTOCOL was accepted'
    $combinedProtected = Merge-Case -Base $catalog.base -Case $catalog.cases[0]
    $combinedProtected.command_text = 'DELETE FROM customer'
    $combinedProtected.environment = 'production'
    $combinedProtected.changed_paths = @('src/auth/authorize.ps1')
    $combinedResult = Invoke-RouteCase -RouteInput $combinedProtected
    Assert-True -Condition ([string]$combinedResult.approval_policy -ceq 'production' -and @($combinedResult.triggers) -ccontains 'protected:production-database-destructive' -and @($combinedResult.triggers) -ccontains 'protected:authorization-path-change') -Success 'none plus one Approval type preserves the single required type' -Failure 'none plus one Approval type changed or lost the required type'

    $workspaceAfter = Get-TreeSnapshot -Root $scratchRoot
    Assert-True -Condition (@(Compare-Object $workspaceBefore $workspaceAfter -SyncWindow 0).Count -eq 0) -Success 'Direct policy selection creates no task/runtime/artifact content' -Failure 'Direct policy selection changed workspace content'

    $fixtureRepo = Join-Path $scratchRoot 'fixture-repo'
    foreach ($relativePath in @('policies/execution-profiles.json','policies/risk-rules.json','policies/protected-actions.json')) { Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $fixtureRepo -RelativePath $relativePath }
    $badPolicy = Get-Content -LiteralPath (Join-Path $fixtureRepo 'policies\risk-rules.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $badPolicy.overrides.multiple_files_alone_escalate = $true
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'policies\risk-rules.json'),($badPolicy|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
    Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $baseInput -PolicyRepoRoot $fixtureRepo }) -Success 'unsafe policy mutation fails closed' -Failure 'unsafe risk policy mutation was accepted'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'policies\risk-rules.json') -Destination (Join-Path $fixtureRepo 'policies\risk-rules.json') -Force
    $conflictingProtected = Get-Content -LiteralPath (Join-Path $fixtureRepo 'policies\protected-actions.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $conflictingProtected.rules[1].requires_approval = 'architecture'
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'policies\protected-actions.json'),($conflictingProtected|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
    Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $combinedProtected -PolicyRepoRoot $fixtureRepo }) -Success 'classification rejects different Approval types from matched rules' -Failure 'classification selected the last matched Approval type'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'policies\protected-actions.json') -Destination (Join-Path $fixtureRepo 'policies\protected-actions.json') -Force
    $badProtected = Get-Content -LiteralPath (Join-Path $fixtureRepo 'policies\protected-actions.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $badProtected.rules[1].requires_independent_review = 'false'
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'policies\protected-actions.json'),($badProtected|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
    Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $baseInput -PolicyRepoRoot $fixtureRepo }) -Success 'non-boolean protected requirements fail closed' -Failure 'unsafe protected rule type was accepted'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'policies\protected-actions.json') -Destination (Join-Path $fixtureRepo 'policies\protected-actions.json') -Force
    $badExecution = Get-Content -LiteralPath (Join-Path $fixtureRepo 'policies\execution-profiles.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $badExecution.profiles.critical.minimum_capabilities = @('verification_required')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'policies\execution-profiles.json'),($badExecution|ConvertTo-Json -Depth 20),(New-Object System.Text.UTF8Encoding($false)))
    Assert-True -Condition (Test-Throws { Invoke-RouteCase -RouteInput $baseInput -PolicyRepoRoot $fixtureRepo }) -Success 'weakened Critical capabilities fail closed' -Failure 'weakened Critical policy was accepted'
} finally {
    Remove-Module Harness.Policy -ErrorAction SilentlyContinue
    Remove-DirectoryWithRetry -Path $scratchRoot
}

$statusAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Assert-True -Condition (@(Compare-Object $statusBefore $statusAfter).Count -eq 0) -Success 'Direct verification leaves Git worktree state unchanged' -Failure 'Direct verification changed Git worktree state'

foreach ($check in $script:checks) { Write-Output ("[PASS] {0}" -f $check) }
foreach ($failure in $script:failures) { Write-Output ("[FAIL] {0}" -f $failure) }
if ($script:failures.Count -gt 0) { Write-Output ("STATUS: FAIL ({0} failed)" -f $script:failures.Count); exit 1 }
Write-Output ("STATUS: PASS ({0} checks)" -f $script:checks.Count)
exit 0
