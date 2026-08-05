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

function Add-Check {
    param([string]$Message)
    $script:checks.Add($Message)
}

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Success,
        [string]$Failure
    )

    if ($Condition) {
        Add-Check $Success
    } else {
        Add-Failure $Failure
    }
}

function Test-KeySet {
    param(
        [System.Collections.IDictionary]$Value,
        [string[]]$Expected
    )

    return @(Compare-Object -ReferenceObject @($Expected | Sort-Object) -DifferenceObject @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)).Count -eq 0
}

function Read-JsonHashtable {
    param([string]$Path)

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Test-AgainstSchema {
    param(
        [object]$Document,
        [string]$SchemaPath
    )

    try {
        $json = $Document | ConvertTo-Json -Depth 30 -Compress
        return [bool](Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop -WarningAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Resolve-DecisionOwner {
    param(
        [System.Collections.IDictionary]$Policy,
        [string]$Category
    )

    if ([string]$Policy['default_unknown_owner'] -cne 'product') {
        throw 'decision policy default owner is not fail closed'
    }

    $owners = @($Policy['categories'].Keys | Where-Object { @($Policy['categories'][$_]) -ccontains $Category })
    if ($owners.Count -gt 1) {
        throw "decision category '$Category' has multiple owners"
    }
    if ($owners.Count -eq 1) {
        return [string]$owners[0]
    }

    return 'product'
}

$statusBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
$schemaRoot = Join-Path $RepoRoot 'schemas'
$policyRoot = Join-Path $RepoRoot 'policies'
$catalogPath = Join-Path $RepoRoot 'tests\fixtures\v2\policy-contract-cases.json'

Assert-True -Condition (Test-FileHasUtf8Bom -Path $PSCommandPath) -Success 'policy verifier has UTF-8 BOM' -Failure 'policy verifier must have UTF-8 BOM'
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
Assert-True -Condition (@($parseErrors).Count -eq 0) -Success 'policy verifier parses as PowerShell' -Failure 'policy verifier has PowerShell parse errors'

$expectedSchemaFiles = @(
    'approval.schema.json',
    'audit-record.schema.json',
    'current-pointer.schema.json',
    'event.schema.json',
    'evidence.schema.json',
    'ordinary-ci-receipt.schema.json',
    'protected-actions-overlay.schema.json',
    'model-eval-observation.schema.json',
    'preset-lifecycle-report.schema.json',
    'protocol-config.schema.json',
    'release-isolation-report.schema.json',
    'release-runner-observation.schema.json',
    'requirement-contract.schema.json',
    'rollout-canary-authorization.schema.json',
    'rollout-eligibility-v2.schema.json',
    'rollout-evidence-set.schema.json',
    'rollout-observed-host-context.schema.json',
    'rollout-review-payload.schema.json',
    'rollout-review-receipt.schema.json',
    'runtime-default-decision.schema.json',
    'task-state.schema.json',
    'v1-stop-loss-report.schema.json'
)
$actualSchemaFiles = @(Get-ChildItem -LiteralPath $schemaRoot -Filter '*.json' -File | Select-Object -ExpandProperty Name | Sort-Object)
Assert-True -Condition (@(Compare-Object $expectedSchemaFiles $actualSchemaFiles).Count -eq 0) -Success 'schema set contains the canonical and approved extension contracts' -Failure 'schema set drifted beyond the approved contracts'

$catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
$expectedCases = @('approval', 'audit-record', 'current-pointer', 'event', 'evidence', 'requirement-contract', 'task-state')
$actualCases = @($catalog.cases | ForEach-Object { [string]$_.name } | Sort-Object)
Assert-True -Condition (@(Compare-Object $expectedCases $actualCases).Count -eq 0) -Success 'fixture catalog has one pair for every schema' -Failure 'fixture catalog does not cover every schema'

foreach ($fixtureCase in $catalog.cases) {
    $schemaPath = Join-Path $schemaRoot ([string]$fixtureCase.schema)
    $schemaDocument = Read-JsonHashtable -Path $schemaPath
    Assert-True -Condition ([string]$schemaDocument['$schema'] -ceq 'http://json-schema.org/draft-07/schema#' -and $schemaDocument['additionalProperties'] -eq $false) -Success ("{0} is strict Draft 7" -f $fixtureCase.name) -Failure ("{0} must be strict Draft 7" -f $fixtureCase.name)
    Assert-True -Condition (Test-AgainstSchema -Document $fixtureCase.valid -SchemaPath $schemaPath) -Success ("{0} valid fixture passes" -f $fixtureCase.name) -Failure ("{0} valid fixture failed schema validation" -f $fixtureCase.name)
    Assert-True -Condition (-not (Test-AgainstSchema -Document $fixtureCase.invalid -SchemaPath $schemaPath)) -Success ("{0} invalid fixture fails closed" -f $fixtureCase.name) -Failure ("{0} invalid fixture was accepted" -f $fixtureCase.name)

    $extra = ($fixtureCase.valid | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
    $extra | Add-Member -NotePropertyName unexpected_policy_override -NotePropertyValue $true
    Assert-True -Condition (-not (Test-AgainstSchema -Document $extra -SchemaPath $schemaPath)) -Success ("{0} rejects unknown top-level fields" -f $fixtureCase.name) -Failure ("{0} accepted an unknown top-level field" -f $fixtureCase.name)

    $wrongVersion = ($fixtureCase.valid | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
    $wrongVersion | Add-Member -NotePropertyName schema_version -NotePropertyValue 'unsupported/v999' -Force
    Assert-True -Condition (-not (Test-AgainstSchema -Document $wrongVersion -SchemaPath $schemaPath)) -Success ("{0} rejects unauthorized schema versions" -f $fixtureCase.name) -Failure ("{0} accepted an unauthorized schema version" -f $fixtureCase.name)
}

$targetedInvalidFixtures = @(
    [pscustomobject]@{ label = 'repo-only Requirement authority'; fixture = 'requirement-repo-only.invalid.json'; schema = 'requirement-contract.schema.json' },
    [pscustomobject]@{ label = 'mixed Evidence record'; fixture = 'evidence-mixed-record.invalid.json'; schema = 'evidence.schema.json' }
)
foreach ($targeted in $targetedInvalidFixtures) {
    $document = Get-Content -LiteralPath (Join-Path $RepoRoot ('tests\fixtures\v2\' + $targeted.fixture)) -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    Assert-True -Condition (-not (Test-AgainstSchema -Document $document -SchemaPath (Join-Path $schemaRoot $targeted.schema))) -Success ("{0} fixture fails closed" -f $targeted.label) -Failure ("{0} fixture was accepted" -f $targeted.label)
}

$eventCase = @($catalog.cases | Where-Object { [string]$_.name -ceq 'event' })[0]
$eventWithActorDrift = ($eventCase.valid | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
$eventWithActorDrift.actor | Add-Member -NotePropertyName permission_override -NotePropertyValue $true
Assert-True -Condition (-not (Test-AgainstSchema -Document $eventWithActorDrift -SchemaPath (Join-Path $schemaRoot 'event.schema.json'))) -Success 'fixed nested objects reject unknown fields' -Failure 'event actor accepted an unknown nested field'

$evidenceCase = @($catalog.cases | Where-Object { [string]$_.name -ceq 'evidence' })[0]
$passingEvidenceWithGap = ($evidenceCase.valid | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
$passingEvidenceWithGap.gaps = @([pscustomobject]@{ id = 'AC-2'; status = 'not-verified'; reason = 'No environment' })
Assert-True -Condition (-not (Test-AgainstSchema -Document $passingEvidenceWithGap -SchemaPath (Join-Path $schemaRoot 'evidence.schema.json'))) -Success 'Evidence pass rejects unresolved gaps' -Failure 'Evidence pass accepted an unresolved gap'

$evidenceWithDryRun = ($evidenceCase.valid | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
$evidenceWithDryRun | Add-Member -NotePropertyName dry_run -NotePropertyValue ([pscustomobject]@{type='command';command='fixture --dry-run';cwd='.';exit_code=0;executed_at='2026-07-22T00:00:00Z';evidence_path='.harness/evidence/dry-run.txt';digest=('sha256:'+('1'*64));covers=@();actor=[pscustomobject]@{host='controlled-executor';model='inherit';actor_id='executor-fixture';context_id='execution-fixture'}})
Assert-True -Condition (Test-AgainstSchema -Document $evidenceWithDryRun -SchemaPath (Join-Path $schemaRoot 'evidence.schema.json')) -Success 'Evidence accepts a strict actor-bound dry-run object' -Failure 'valid structured dry-run Evidence failed schema validation'
$dryRunWithoutIdentity = ($evidenceWithDryRun | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
$dryRunWithoutIdentity.dry_run.actor.PSObject.Properties.Remove('actor_id')
Assert-True -Condition (-not (Test-AgainstSchema -Document $dryRunWithoutIdentity -SchemaPath (Join-Path $schemaRoot 'evidence.schema.json'))) -Success 'dry-run Evidence requires executor identity' -Failure 'dry-run Evidence accepted a missing executor identity'
foreach ($field in @('command','host','backend','model','actor_id','context_id')) {
    $dryRunWithWhitespace = ($evidenceWithDryRun | ConvertTo-Json -Depth 30 -Compress) | ConvertFrom-Json
    if ($field -ceq 'command') { $dryRunWithWhitespace.dry_run.command = ' ' }
    elseif ($field -ceq 'backend') { $dryRunWithWhitespace.dry_run.actor | Add-Member -NotePropertyName backend -NotePropertyValue "`t" }
    else { $dryRunWithWhitespace.dry_run.actor.$field = "`t" }
    Assert-True -Condition (-not (Test-AgainstSchema -Document $dryRunWithWhitespace -SchemaPath (Join-Path $schemaRoot 'evidence.schema.json'))) -Success "dry-run Evidence rejects whitespace-only $field" -Failure "dry-run Evidence accepted whitespace-only $field"
}

$allContractText = @(Get-ChildItem -LiteralPath $policyRoot,$schemaRoot -Filter '*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 }) -join [Environment]::NewLine
Assert-True -Condition ($allContractText -notmatch '"(?:task/v2|evidence/v2|risk-rules/v1|execution-profiles/v1)"') -Success 'contracts contain no conflicting or unauthorized public versions' -Failure 'contracts contain a conflicting or unauthorized public version'

$decision = Read-JsonHashtable -Path (Join-Path $policyRoot 'decision-rights.json')
$decisionTopKeys = @('schema_version', 'categories', 'default_unknown_owner', 'agent_decision_constraints')
$decisionCategoryKeys = @('product', 'architecture', 'agent')
$decisionConstraintKeys = @('must_be_reversible', 'must_not_change_external_behavior', 'must_follow_repo_conventions', 'must_be_verified')
Assert-True -Condition (Test-KeySet -Value $decision -Expected $decisionTopKeys) -Success 'decision policy top-level keys are exact' -Failure 'decision policy top-level keys drifted'
Assert-True -Condition ([string]$decision['schema_version'] -ceq 'decision-rights/v1' -and (Test-KeySet -Value $decision['categories'] -Expected $decisionCategoryKeys) -and (Test-KeySet -Value $decision['agent_decision_constraints'] -Expected $decisionConstraintKeys)) -Success 'decision policy shape and version are canonical' -Failure 'decision policy shape or version is invalid'
$allCategories = @($decisionCategoryKeys | ForEach-Object { @($decision['categories'][$_]) })
$duplicateCategories = @($allCategories | Group-Object | Where-Object { $_.Count -gt 1 })
Assert-True -Condition ($duplicateCategories.Count -eq 0) -Success 'decision categories have one owner each' -Failure 'decision categories overlap across owners'
Assert-True -Condition ((Resolve-DecisionOwner -Policy $decision -Category 'private_naming') -ceq 'agent' -and (Resolve-DecisionOwner -Policy $decision -Category 'future_unknown_category') -ceq 'product') -Success 'known agent decisions resolve narrowly and unknown decisions fail closed to product' -Failure 'decision owner resolution is not fail closed'
$badDecision = (Get-Content -LiteralPath (Join-Path $policyRoot 'decision-rights.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
$badDecision['default_unknown_owner'] = 'agent'
$badOwnerRejected = $false
try {
    [void](Resolve-DecisionOwner -Policy $badDecision -Category 'future_unknown_category')
} catch {
    $badOwnerRejected = $true
}
Assert-True -Condition $badOwnerRejected -Success 'invalid decision default owner is rejected' -Failure 'invalid decision default owner widened agent authority'

$risk = Read-JsonHashtable -Path (Join-Path $policyRoot 'risk-rules.json')
Assert-True -Condition (Test-KeySet -Value $risk -Expected @('dimensions', 'profile_thresholds', 'critical_triggers', 'overrides')) -Success 'risk policy top-level keys are exact and unversioned' -Failure 'risk policy keys drifted or invented a public version'
$dimensionSummary = @($risk['dimensions'] | ForEach-Object { "{0}:{1}-{2}" -f $_['id'],$_['min_score'],$_['max_score'] })
$expectedDimensions = @(
    'user_visible_behavior:0-3',
    'data_integrity:0-3',
    'authorization_and_security:0-3',
    'external_side_effects:0-3',
    'blast_radius:0-3',
    'rollback:0-3',
    'verification_coverage:0-3'
)
Assert-True -Condition (@(Compare-Object $expectedDimensions $dimensionSummary).Count -eq 0) -Success 'risk dimensions are complete and bounded 0..3' -Failure 'risk dimension set or bounds are wrong'
$thresholdSummary = @($risk['profile_thresholds'] | ForEach-Object { "{0}:{1}-{2}" -f $_['profile'],$_['min_total'],$_['max_total'] })
Assert-True -Condition (($thresholdSummary -join ',') -ceq 'direct:0-4,governed:5-8,critical:9-21') -Success 'risk score bands are contiguous and canonical' -Failure 'risk score bands have a gap, overlap, or wrong profile'
$expectedCriticalTriggers = @(
    'authorization_or_security_boundary',
    'money_billing_refund_or_settlement',
    'production_database_destructive_migration',
    'irreversible_user_data_change',
    'production_release_or_infrastructure',
    'breaking_public_api_change',
    'sensitive_data_export_or_compliance',
    'destructive_git_history_operation',
    'large_scale_automation_without_dry_run',
    'unverified_production_impact'
)
Assert-True -Condition (@(Compare-Object $expectedCriticalTriggers @($risk['critical_triggers'])).Count -eq 0) -Success 'risk policy contains every canonical Critical trigger' -Failure 'risk policy Critical trigger set is incomplete or expanded'
$overrides = $risk['overrides']
Assert-True -Condition ([string]$overrides['requirement_blocked_state'] -ceq 'blocked' -and [string]$overrides['read_only_profile'] -ceq 'inspect' -and [string]$overrides['durable_minimum_profile'] -ceq 'governed' -and [string]$overrides['critical_trigger_profile'] -ceq 'critical' -and $overrides['multiple_files_alone_escalate'] -eq $false) -Success 'risk overrides preserve blocked, read-only, durable, critical, and multi-file rules' -Failure 'risk override semantics drifted'

$execution = Read-JsonHashtable -Path (Join-Path $policyRoot 'execution-profiles.json')
Assert-True -Condition (Test-KeySet -Value $execution -Expected @('profiles', 'legacy_aliases')) -Success 'execution profile policy top-level keys are exact and unversioned' -Failure 'execution profile policy drifted or invented a public version'
$profiles = $execution['profiles']
Assert-True -Condition (Test-KeySet -Value $profiles -Expected @('inspect', 'direct', 'governed', 'critical')) -Success 'execution policy contains exactly four profiles' -Failure 'execution policy must contain only inspect, direct, governed, and critical'
foreach ($profileName in @('inspect', 'direct', 'governed', 'critical')) {
    Assert-True -Condition (Test-KeySet -Value $profiles[$profileName] -Expected @('allowed_intents', 'allowed_persistence', 'minimum_capabilities', 'configurable_capabilities', 'writes_task_state', 'writes_task_artifacts', 'current_pointer_policy')) -Success ("{0} profile keys are exact" -f $profileName) -Failure ("{0} profile keys drifted" -f $profileName)
}
Assert-True -Condition ($profiles['inspect']['writes_task_state'] -eq $false -and $profiles['inspect']['writes_task_artifacts'] -eq $false -and $profiles['direct']['writes_task_state'] -eq $false -and $profiles['direct']['writes_task_artifacts'] -eq $false) -Success 'Inspect and Direct default to zero task-state and artifact writes' -Failure 'Inspect or Direct gained durable writes'
Assert-True -Condition (@($profiles['governed']['minimum_capabilities']) -ccontains 'durable_artifacts_required' -and @($profiles['governed']['configurable_capabilities']) -ccontains 'approval_required') -Success 'Governed keeps durable minimums and policy-composed capabilities' -Failure 'Governed capabilities were prematurely fixed or weakened'
$criticalRequired = @('plan_required', 'approval_required', 'rollback_required', 'independent_review_required', 'verification_required', 'durable_artifacts_required', 'dry_run_required')
Assert-True -Condition (@(Compare-Object $criticalRequired @($profiles['critical']['minimum_capabilities'])).Count -eq 0) -Success 'Critical requires every mandatory capability' -Failure 'Critical profile is missing a mandatory capability'
Assert-True -Condition (-not $profiles.Contains('ask') -and [string]$execution['legacy_aliases']['ask_requirement_state'] -ceq 'blocked') -Success 'Ask remains a blocked requirement state, not a fifth profile' -Failure 'Ask was modeled as an execution profile'

$protected = Read-JsonHashtable -Path (Join-Path $policyRoot 'protected-actions.json')
Assert-True -Condition (Test-KeySet -Value $protected -Expected @('schema_version', 'rules') -and [string]$protected['schema_version'] -ceq 'protected-actions/v1') -Success 'protected action policy shape and version are canonical' -Failure 'protected action policy shape or version is invalid'
$protectedIds = @($protected['rules'] | ForEach-Object { [string]$_['id'] })
Assert-True -Condition (@(Compare-Object @('production-database-destructive', 'authorization-path-change') $protectedIds).Count -eq 0) -Success 'PR-01 contains only the two plan-defined protected rules' -Failure 'protected rules are missing or expanded beyond PR-01'
foreach ($rule in $protected['rules']) {
    Assert-True -Condition (Test-KeySet -Value $rule -Expected @('id', 'match', 'requires_profile', 'requires_approval', 'requires_dry_run', 'requires_independent_review')) -Success ("protected rule {0} keys are exact" -f $rule['id']) -Failure ("protected rule {0} keys drifted" -f $rule['id'])
    Assert-True -Condition ([string]$rule['requires_profile'] -in @('governed', 'critical') -and $rule['requires_independent_review'] -eq $true) -Success ("protected rule {0} only escalates requirements" -f $rule['id']) -Failure ("protected rule {0} weakens requirements or declares safety" -f $rule['id'])
}
$productionRule = @($protected['rules'] | Where-Object { [string]$_['id'] -ceq 'production-database-destructive' })[0]
Assert-True -Condition ([string]$productionRule['requires_profile'] -ceq 'critical' -and [string]$productionRule['requires_approval'] -ceq 'production' -and $productionRule['requires_dry_run'] -eq $true) -Success 'production destructive database actions require Critical, approval, and dry-run' -Failure 'production destructive database protection is incomplete'
$overlaySchemaPath = Join-Path $schemaRoot 'protected-actions-overlay.schema.json'
$validOverlay = [ordered]@{schema_version='protected-actions-overlay/v1';rules=@([ordered]@{id='project-payment-path';match=[ordered]@{path_globs=@('**/payments/**');environment='staging'};requires_profile='governed';requires_approval='architecture';requires_dry_run=$false;requires_independent_review=$true})}
$invalidOverlay = ($validOverlay | ConvertTo-Json -Depth 20) | ConvertFrom-Json -AsHashtable -Depth 20
$invalidOverlay.rules[0].requires_profile = 'direct'
Assert-True -Condition ((Test-Path $overlaySchemaPath -PathType Leaf) -and (Test-Json -Json ($validOverlay|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $overlaySchemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) -Success 'project protected-action overlay has a strict valid schema contract' -Failure 'valid protected-action overlay contract is unavailable'
Assert-True -Condition (-not (Test-Json -Json ($invalidOverlay|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $overlaySchemaPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) -Success 'protected-action overlay cannot weaken a rule to Direct' -Failure 'protected-action overlay accepted a weakened Direct rule'

$malformedRejected = $false
try {
    [void]('{"broken":' | ConvertFrom-Json -ErrorAction Stop)
} catch {
    $malformedRejected = $true
}
Assert-True -Condition $malformedRejected -Success 'malformed JSON fails closed' -Failure 'malformed JSON was accepted'

$statusAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
Assert-True -Condition (@(Compare-Object $statusBefore $statusAfter).Count -eq 0) -Success 'policy verification performs no repository or runtime writes' -Failure 'policy verification changed repository state'

foreach ($check in $script:checks) {
    Write-Output ("[PASS] {0}" -f $check)
}
foreach ($failure in $script:failures) {
    Write-Output ("[FAIL] {0}" -f $failure)
}

if ($script:failures.Count -gt 0) {
    Write-Output ("STATUS: FAIL ({0} failed)" -f $script:failures.Count)
    exit 1
}

Write-Output ("STATUS: PASS ({0} checks)" -f $script:checks.Count)
exit 0
