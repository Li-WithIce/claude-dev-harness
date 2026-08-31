[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [System.Collections.Generic.List[string]]::new()
$script:failures = [System.Collections.Generic.List[string]]::new()
function Check { param([bool]$Condition,[string]$Pass,[string]$Fail) if($Condition){$script:checks.Add($Pass)}else{$script:failures.Add($Fail)} }
function Get-WorkflowJobBlock {
    param([string]$Text,[string]$JobId)
    $pattern = '(?ms)^  {0}:[ \t]*\r?$.*?(?=^  [A-Za-z0-9_-]+:[ \t]*\r?$|\z)' -f [regex]::Escape($JobId)
    $matches = [regex]::Matches($Text,$pattern)
    return [pscustomobject]@{ Count=$matches.Count; Value=$(if($matches.Count -eq 1){$matches[0].Value}else{''}) }
}
function Get-Route {
    param([string[]]$Paths)
    $output = @(& $script:router -RepoRoot $RepoRoot -ChangedPaths $Paths -ListOnly -AsJson)
    if ($LASTEXITCODE -ne 0) { throw "CI router failed for paths: $($Paths -join ',')" }
    return (($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop)
}

$script:router = Join-Path $RepoRoot 'scripts\run-changed-optional-validation.ps1'
$runner = Join-Path $RepoRoot 'tests\run-scenario-evals.ps1'
$datasetPath = Join-Path $RepoRoot 'tests\evals\core-scenarios.json'
$workflowPath = Join-Path $RepoRoot '.github\workflows\validation.yml'
$fullValidationWorkflowPath = Join-Path $RepoRoot '.github\workflows\full-validation.yml'
$validationPath = Join-Path $RepoRoot 'scripts\run-validation.ps1'
$rolloutGeneratorPath = Join-Path $RepoRoot 'scripts\generate-v2-rollout-report.ps1'
$runnerBoundaryPath = Join-Path $RepoRoot 'scripts\assert-release-runner-boundary.ps1'
$receiptWriterPath = Join-Path $RepoRoot 'scripts\write-ordinary-ci-receipt.ps1'
$fullReceiptWriterPath = Join-Path $RepoRoot 'scripts\write-release-full-receipt.ps1'
$capabilityBindingWriterPath = Join-Path $RepoRoot 'scripts\write-capability-source-binding.ps1'
$scenarioDocPath = Join-Path $RepoRoot 'docs\testing\scenario-evals.md'
$compatibilityPolicyPath = Join-Path $RepoRoot 'docs\release\compatibility-policy.md'
$readmePath = Join-Path $RepoRoot 'README.md'
$manifestCatalogPath = Join-Path $RepoRoot 'module-manifest-catalog.json'

foreach ($path in @($script:router,$runner,$runnerBoundaryPath,$receiptWriterPath,$fullReceiptWriterPath,$capabilityBindingWriterPath,$PSCommandPath)) {
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0) "$(Split-Path -Leaf $path) parses" "$(Split-Path -Leaf $path) has parse errors"
    Check (Test-FileHasUtf8Bom -Path $path) "$(Split-Path -Leaf $path) has UTF-8 BOM" "$(Split-Path -Leaf $path) must have UTF-8 BOM"
}

$datasetRaw = Get-Content -LiteralPath $datasetPath -Raw -Encoding utf8
$dataset = $datasetRaw | ConvertFrom-Json -AsHashtable -Depth 60
$ids = @($dataset.cases | ForEach-Object { [string]$_.id })
$semantic = @($dataset.cases | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.semantic_intent) -or @($_.paraphrases).Count -lt 2 })
Check ([string]$dataset.schema_version -ceq 'harness-scenario-evals/v1' -and $ids.Count -eq 20 -and @($ids|Sort-Object -Unique).Count -eq 20) 'core eval dataset has twenty unique behavior cases' 'core eval dataset identity or case count drifted'
Check ($semantic.Count -eq 0 -and $datasetRaw -notmatch '(?i)"(?:prompt|prompt_text|raw_prompt)"\s*:') 'eval cases use semantic intents with paraphrases instead of exact prompt fields' 'eval dataset depends on exact prompt fields or lacks paraphrases'
Check (@($dataset.cases | Where-Object { $_.critical }).Count -ge 8) 'eval dataset marks hard-safety cases explicitly' 'eval dataset lost critical safety coverage'

$core = Get-Route @('src/core.ps1')
Check (@($core.modules).Count -eq 0 -and @($core.tests).Count -eq 0 -and -not $core.run_all_optional) 'ordinary core changes select no optional suite' 'ordinary core change selected optional validation'
$memory = Get-Route @('skills/obsidian-memory/SKILL.md')
Check ((@($memory.modules) -join ',') -ceq 'memory' -and @($memory.tests).Count -eq 9 -and @($memory.tests) -ccontains 'verify-memory-provider-boundary.ps1') 'Memory changes select only complete Memory validation' 'Memory changed-path routing is wrong or incomplete'
$team = Get-Route @('skills/workflow-team/SKILL.md')
Check ((@($team.modules) -join ',') -ceq 'team' -and @($team.tests).Count -eq 3 -and @($team.tests) -ccontains 'verify-aiteamcode-skill-contract.ps1') 'Team changes select complete Team validation' 'Team changed-path routing is wrong or incomplete'
$adapterDispatch = Get-Route @('scripts/invoke-harness-skill-dispatcher.ps1')
Check ((@($adapterDispatch.modules) -join ',') -ceq 'harness-maintenance,team' -and @($adapterDispatch.tests) -ccontains 'verify-aiteamcode-skill-contract.ps1' -and @($adapterDispatch.tests) -ccontains 'verify-thin-adapters.ps1') 'Harness adapter dispatcher changes select lifecycle and thin-adapter validation' 'Harness adapter dispatcher change skipped lifecycle or thin-adapter validation'
$html = Get-Route @('skills/md-html/SKILL.md')
Check ((@($html.modules) -join ',') -ceq 'md-html' -and @($html.tests).Count -eq 2) 'md-html changes select renderer validation' 'md-html changed-path routing is wrong'
$codex = Get-Route @('skills/codex/SKILL.md')
Check ((@($codex.modules) -join ',') -ceq 'codex-adapter' -and @($codex.tests) -ccontains 'verify-ask-codex.ps1') 'Codex adapter changes select adapter validation' 'Codex adapter changed-path routing is wrong'
$providers = Get-Route @('scripts/audit-context-provider-usage.ps1')
Check ((@($providers.modules) -join ',') -ceq 'providers' -and @($providers.tests).Count -eq 7) 'Provider changes select complete provider validation' 'Provider changed-path routing is wrong or incomplete'
$maintenance = Get-Route @('scripts/get-repo-inventory.ps1')
Check ((@($maintenance.modules) -join ',') -ceq 'harness-maintenance' -and @($maintenance.tests).Count -eq 9 -and @($maintenance.tests) -ccontains 'verify-capability-extraction.ps1' -and @($maintenance.tests) -ccontains 'verify-thin-adapters.ps1') 'Harness maintenance changes select the complete construction verifier set' 'Harness maintenance routing is wrong or incomplete'
$routing = Get-Route @('.github/workflows/validation.yml')
Check ($routing.run_all_optional -and @($routing.modules).Count -eq 8 -and @($routing.tests).Count -eq 38) 'routing-surface changes fail safe to every optional verifier' 'routing-surface changes did not select all optional verifiers'
$legacy = Get-Route @('scripts/advance-stage.ps1')
Check ((@($legacy.modules) -join ',') -ceq 'legacy-v1' -and (@($legacy.tests) -join ',') -ceq 'verify-v1-manifest-marker.ps1') 'legacy-v1 changes select only the explicit marker contract' 'legacy-v1 changed-path routing is wrong or expanded into Sunset'
$fullValidationRouting = Get-Route @('.github/workflows/full-validation.yml')
$allOptionalModules = @($routing.modules | Sort-Object -CaseSensitive -Unique)
$allOptionalTests = @($routing.tests | Sort-Object -CaseSensitive -Unique)
$fullValidationModules = @($fullValidationRouting.modules | Sort-Object -CaseSensitive -Unique)
$fullValidationTests = @($fullValidationRouting.tests | Sort-Object -CaseSensitive -Unique)
Check ($fullValidationRouting.run_all_optional -and @($fullValidationRouting.modules).Count -eq $fullValidationModules.Count -and @($fullValidationRouting.tests).Count -eq $fullValidationTests.Count -and ($fullValidationModules -join '|') -ceq ($allOptionalModules -join '|') -and ($fullValidationTests -join '|') -ceq ($allOptionalTests -join '|')) 'full-validation changes fail safe to the complete current optional verifier set' 'full-validation changes do not select the complete current optional verifier set'

$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$fullValidationWorkflow = Get-Content -LiteralPath $fullValidationWorkflowPath -Raw -Encoding utf8
$rolloutGenerator = Get-Content -LiteralPath $rolloutGeneratorPath -Raw -Encoding utf8
$prCoreChecksBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'pr-core-checks'
$prCoreBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'pr-core'
$changedOptionalBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'changed-optional'
$releaseModelBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-model'
$releaseHostBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-host'
$releaseBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-full'
$allVerifiersBlock = Get-WorkflowJobBlock -Text $fullValidationWorkflow -JobId 'all-verifiers'
$presetSmokeBlock = Get-WorkflowJobBlock -Text $fullValidationWorkflow -JobId 'preset-smoke'
$prCoreChecksJob = $prCoreChecksBlock.Value
$prCoreJob = $prCoreBlock.Value
$changedOptionalJob = $changedOptionalBlock.Value
$releaseModelJob = $releaseModelBlock.Value
$releaseHostJob = $releaseHostBlock.Value
$releaseJob = $releaseBlock.Value
$allVerifiersJob = $allVerifiersBlock.Value
$presetSmokeJob = $presetSmokeBlock.Value
$producerRunnerPattern = '(?ms)^\s*runs-on:\s*\r?\n\s*-\s*self-hosted\s*\r?\n\s*-\s*Windows\s*\r?\n\s*-\s*\$\{\{\s*vars\.THIN_V2_RELEASE_RUNNER\s*\}\}\s*$'
$aggregatorRunnerPattern = '(?ms)^\s*runs-on:\s*\r?\n\s*-\s*self-hosted\s*\r?\n\s*-\s*Windows\s*\r?\n\s*-\s*\$\{\{\s*vars\.THIN_V2_RELEASE_AGGREGATOR_RUNNER\s*\}\}\s*$'
$modelUpload = [regex]::Match($releaseModelJob,'(?ms)^      - name: Upload model evidence\s*$.*\z').Value
$hostUpload = [regex]::Match($releaseHostJob,'(?ms)^      - name: Upload host evidence\s*$.*\z').Value
$currentReleaseUpload = [regex]::Match($releaseJob,'(?ms)^      - name: Upload current rollout evidence\s*$.*?(?=^      - name:|\z)').Value
$legacyReleaseUpload = [regex]::Match($releaseJob,'(?ms)^      - name: Upload legacy rollout evidence\s*$.*\z').Value
$checkoutAction = 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5'
$uploadAction = 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
$downloadAction = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
$trustedRefs = @('refs/heads/main','refs/heads/codex/harness-distribution','refs/heads/codex/thin-harness-v2-refactor')
$defaultPromotionRef = 'refs/heads/codex/harness-v2-default-promotion'
$defaultPromotionCondition = "github.event_name == 'workflow_dispatch' && github.ref == '$defaultPromotionRef'"
$pushBlock = [regex]::Match($workflow,'(?ms)^  push:\s*\r?$.*?(?=^  schedule:\s*\r?$)').Value
$fullTriggerMatches = [regex]::Matches($fullValidationWorkflow,'(?ms)^on:[ \t]*\r?$.*?(?=^[A-Za-z][A-Za-z0-9_-]*:[ \t]*\r?$|\z)')
$fullTriggerBlock = if($fullTriggerMatches.Count -eq 1){$fullTriggerMatches[0].Value}else{''}
$fullPermissionsMatches = [regex]::Matches($fullValidationWorkflow,'(?ms)^permissions:[ \t]*\r?$.*?(?=^[A-Za-z][A-Za-z0-9_-]*:[ \t]*\r?$|\z)')
$fullPermissionsBlock = if($fullPermissionsMatches.Count -eq 1){$fullPermissionsMatches[0].Value}else{''}
$fullCheckoutAction = 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5'
$modelBundlePaths = @([regex]::Matches($modelUpload,'(?m)^\s+\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/(?<name>[a-z0-9-]+\.json)\s*$') | ForEach-Object { $_.Groups['name'].Value })
$hostBundlePaths = @([regex]::Matches($hostUpload,'(?m)^\s+\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/(?<name>[a-z0-9-]+\.json)\s*$') | ForEach-Object { $_.Groups['name'].Value })
$currentBundlePaths = @([regex]::Matches($currentReleaseUpload,'(?m)^\s+\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/(?<name>[a-z0-9-]+\.json)\s*$') | ForEach-Object { $_.Groups['name'].Value })
$expectedModelBundlePaths = @('model-runner-observation.json','model-eval.json','release-model-receipt.json','model-capability-source-binding.json')
$expectedHostBundlePaths = @('host-runner-observation.json','cognitive-host.json','installed-desktop-primary.json','installed-desktop-distinct.json','lifecycle-core.json','lifecycle-governed.json','lifecycle-full.json','v1-stop-loss.json','release-host-receipt.json','host-capability-source-binding.json')
$expectedCurrentBundlePaths = @('aggregator-runner-observation.json','release-isolation.json','exact-head-engineering.json','release-full-receipt.json','full-capability-source-binding.json')
$trustedProducerCount = 0
foreach ($producer in @($releaseModelJob,$releaseHostJob)) {
    if ($producer -match $producerRunnerPattern -and
        $producer -match '(?m)^\s*HOST_BENCHMARK_CODEX_HOME:\s*\$\{\{\s*vars\.HOST_BENCHMARK_CODEX_HOME\s*\}\}\s*$' -and
        $producer -match '(?m)^\s*environment:\s*thin-v2-release\s*$' -and
        $producer -match '(?m)^\s*persist-credentials:\s*false\s*$' -and
        $producer -match '!cancelled\(\)' -and @($trustedRefs | Where-Object { $producer -notmatch [regex]::Escape($_) }).Count -eq 0 -and
        $producer -notmatch '(?i)secrets\.') { $trustedProducerCount++ }
}
Check ($workflow -match '(?m)^\s*schedule:\s*$' -and $workflow -match '(?m)^\s*workflow_dispatch:\s*$' -and $workflow -match '(?ms)^      engineering_ci_run_id:.*?^        required: true\s*$.*?^        type: string\s*$' -and $workflow -match '(?ms)^      engineering_review_comment_id:.*?^        required: true\s*$.*?^        type: string\s*$') 'CI exposes nightly and required-input manual release validation' 'CI lacks nightly or strict manual release validation'
Check (@($prCoreChecksBlock,$prCoreBlock,$changedOptionalBlock,$releaseModelBlock,$releaseHostBlock,$releaseBlock | Where-Object Count -eq 1).Count -eq 6) 'CI declares each PR and release job exactly once' 'CI job layering is missing or duplicated'
Check (@(@($releaseModelJob,$releaseHostJob,$releaseJob) | Where-Object { $_ -match [regex]::Escape($defaultPromotionCondition) }).Count -eq 3 -and @([regex]::Matches($workflow,[regex]::Escape($defaultPromotionCondition))).Count -eq 3 -and $pushBlock -notmatch [regex]::Escape($defaultPromotionRef) -and @(@($releaseModelJob,$releaseHostJob,$releaseJob) | Where-Object { $_ -match "github.event_name != 'pull_request'" }).Count -eq 3) 'Default Promotion routes model, host, and release-full only through workflow_dispatch' 'Default Promotion manual release routing or push guard drifted'
Check (@([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($checkoutAction)))).Count -eq 6 -and @([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($uploadAction)))).Count -eq 7 -and @([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($downloadAction)))).Count -eq 4 -and $workflow -notmatch '(?m)^\s*uses:\s*actions/(?:checkout|upload-artifact|download-artifact)@v\d+') 'every GitHub Action dependency is pinned to a verified full commit SHA' 'GitHub Action dependencies are movable or not pinned to the approved commits'
$fullScheduleMatches = [regex]::Matches($fullTriggerBlock,'(?m)^  schedule:[ \t]*\r?$')
$fullDispatchMatches = [regex]::Matches($fullTriggerBlock,'(?m)^  workflow_dispatch:[ \t]*\r?$')
$fullCronMatches = [regex]::Matches($fullTriggerBlock,"(?m)^    - cron:[ \t]*'43 4 \* \* \*'[ \t]*\r?$")
Check ($fullTriggerMatches.Count -eq 1 -and $fullScheduleMatches.Count -eq 1 -and $fullCronMatches.Count -eq 1 -and $fullDispatchMatches.Count -eq 1 -and $fullTriggerBlock -notmatch '(?m)^    inputs:[ \t]*\r?$' -and $fullTriggerBlock -notmatch '(?m)^  (?:pull_request|push|repository_dispatch|workflow_run):') 'full-validation exposes only fixed daily schedule and input-free manual dispatch' 'full-validation trigger set, cron, or manual input boundary drifted'
Check ($allVerifiersBlock.Count -eq 1 -and $presetSmokeBlock.Count -eq 1 -and (Get-WorkflowJobBlock -Text $fullValidationWorkflow -JobId 'release-model').Count -eq 0 -and (Get-WorkflowJobBlock -Text $fullValidationWorkflow -JobId 'release-host').Count -eq 0 -and (Get-WorkflowJobBlock -Text $fullValidationWorkflow -JobId 'release-full').Count -eq 0) 'full-validation declares the two engineering jobs exactly once without release jobs' 'full-validation job layering is missing, duplicated, or includes release jobs'
$allVerifierCommand = '(?m)^        run: >[ \t]*\r?\n          pwsh -NoLogo -NoProfile -NonInteractive[ \t]*\r?\n          -File scripts/run-validation\.ps1[ \t]*\r?\n          -Suite all[ \t]*\r?\n          -CheckTimeoutSeconds 900[ \t]*\r?$'
Check (@([regex]::Matches($allVerifiersJob,$allVerifierCommand)).Count -eq 1 -and $allVerifiersJob -match '(?m)^    runs-on:[ \t]*windows-latest[ \t]*\r?$' -and $allVerifiersJob -match '(?m)^    timeout-minutes:[ \t]*180[ \t]*\r?$' -and $allVerifiersJob -notmatch '(?i)-CoreGroup|-WorkspaceRoot|continue-on-error') 'all-verifiers runs the exact unmasked Suite all command on windows-latest' 'all-verifiers command, timeout, runner, or failure semantics drifted'
$presetMatrixPattern = '(?m)^    strategy:[ \t]*\r?\n^      fail-fast:[ \t]*false[ \t]*\r?\n^      matrix:[ \t]*\r?\n^        preset:[ \t]*\r?\n(?<items>(?:^          - (?<preset>[a-z]+)[ \t]*\r?(?:\n|\z))+)(?=^    runs-on:[ \t])'
$presetMatrixMatches = [regex]::Matches($presetSmokeJob,$presetMatrixPattern)
$presetMatrixValues = if($presetMatrixMatches.Count -eq 1){@($presetMatrixMatches[0].Groups['preset'].Captures | ForEach-Object Value)}else{@()}
$presetSmokeCommand = '(?m)^        run: >[ \t]*\r?\n          pwsh -NoLogo -NoProfile -NonInteractive[ \t]*\r?\n          -File scripts/run-isolated-install-smoke\.ps1[ \t]*\r?\n          -RepoRoot \$PWD[ \t]*\r?\n          -Preset \$\{\{ matrix\.preset \}\}[ \t]*\r?$'
Check ($presetMatrixMatches.Count -eq 1 -and ($presetMatrixValues -join '|') -ceq 'core|governed|full' -and @($presetMatrixValues | Sort-Object -CaseSensitive -Unique).Count -eq 3 -and @([regex]::Matches($presetSmokeJob,$presetSmokeCommand)).Count -eq 1 -and $presetSmokeJob -match '(?m)^    runs-on:[ \t]*windows-latest[ \t]*\r?$' -and $presetSmokeJob -match '(?m)^    timeout-minutes:[ \t]*90[ \t]*\r?$' -and $presetSmokeJob -notmatch '(?i)continue-on-error') 'preset-smoke runs the exact core governed full matrix without masked failures' 'preset-smoke matrix, command, timeout, runner, or failure semantics drifted'
$fullCheckoutJobs = @(@($allVerifiersJob,$presetSmokeJob) | Where-Object { @([regex]::Matches($_,('(?m)^        uses: {0}[ \t]*\r?$' -f [regex]::Escape($fullCheckoutAction)))).Count -eq 1 -and @([regex]::Matches($_,'(?m)^          fetch-depth:[ \t]*0[ \t]*\r?$')).Count -eq 1 -and @([regex]::Matches($_,'(?m)^          persist-credentials:[ \t]*false[ \t]*\r?$')).Count -eq 1 })
Check ($fullCheckoutJobs.Count -eq 2 -and @([regex]::Matches($fullValidationWorkflow,'(?m)^\s*uses:[ \t]+')).Count -eq 2 -and $fullValidationWorkflow -notmatch '(?m)^\s*uses:\s*actions/checkout@(?:v\d+|main)\s*$') 'full-validation checkout steps use the approved immutable SHA without persisted credentials' 'full-validation Action pin or checkout safety drifted'
Check ($fullPermissionsMatches.Count -eq 1 -and $fullPermissionsBlock -match '(?ms)^permissions:[ \t]*\r?\n  contents:[ \t]*read[ \t]*\r?\n(?:[ \t]*\r?\n)*$' -and $fullValidationWorkflow -notmatch '(?im)^\s*[A-Za-z-]+:\s*write\s*$' -and $fullValidationWorkflow -notmatch '(?im)secrets\.|vars\.THIN_V2_RELEASE_|THIN_V2_RELEASE_(?:RUNNER|AGGREGATOR_RUNNER)|HOST_BENCHMARK_CODEX_HOME|thin-v2-release|self-hosted|^\s*environment:|release-(?:model|host|full)|CODEX_API_KEY|OPENAI_API_KEY|CODEX_ACCESS_TOKEN|auth\.json') 'full-validation is contents-read engineering CI with no release or credential surface' 'full-validation permissions, release isolation, or credential boundary drifted'
$expectedCoreGroups = @('entry-lifecycle','evaluation-release','install-evidence','governance-approval','harness-contracts')
$matrixPattern = '(?m)^    strategy:[ \t]*\r?\n^      fail-fast:[ \t]*false[ \t]*\r?\n^      matrix:[ \t]*\r?\n^        core_group:[ \t]*\r?\n(?<items>(?:^          - (?<group>[a-z0-9-]+)[ \t]*\r?(?:\n|\z))+)(?=^    runs-on:[ \t])'
$matrixMatches = [regex]::Matches($prCoreChecksJob,$matrixPattern)
$matrixGroups = if($matrixMatches.Count -eq 1){@($matrixMatches[0].Groups['group'].Captures | ForEach-Object Value)}else{@()}
Check ($matrixMatches.Count -eq 1 -and ($matrixGroups -join '|') -ceq ($expectedCoreGroups -join '|') -and @($matrixGroups | Sort-Object -CaseSensitive -Unique).Count -eq 5 -and $prCoreChecksJob -notmatch '(?m)^\s{4,8}continue-on-error:') 'PR core matrix runs five exact groups without fail-fast or masked failures' 'PR core matrix groups, fail-fast, or failure semantics are unsafe'
Check ($prCoreChecksJob -match '(?m)^        run:\s+pwsh -NoLogo -NoProfile -NonInteractive -File scripts/run-validation\.ps1 -Suite core -CoreGroup \$\{\{ matrix\.core_group \}\} -CheckTimeoutSeconds 600\s*$' -and $prCoreChecksJob -notmatch 'run-isolated-install-smoke\.ps1' -and $prCoreJob -notmatch 'run-validation\.ps1 -Suite core') 'core shards and rollback gate delegate only their assigned work' 'core validation or rollback work is duplicated across jobs'
$ordinaryJobs = @($prCoreChecksJob,$prCoreJob,$changedOptionalJob)
$exactHeadJobs = @($ordinaryJobs | Where-Object {
    $_ -match '(?m)^\s*ref:\s*\$\{\{\s*github\.event\.pull_request\.head\.sha\s*\}\}\s*$' -and
    $_ -match '(?m)^\s*persist-credentials:\s*false\s*$'
})
$receiptJobs = @($ordinaryJobs | Where-Object {
    $_ -match 'scripts/write-ordinary-ci-receipt\.ps1' -and
    $_ -match '-ExpectedHeadSha \$env:PR_HEAD_SHA' -and
    $_ -match '-BaseSha \$env:PR_BASE_SHA' -and
    $_ -match '(?m)^\s*path:\s*\$\{\{ env\.ORDINARY_RECEIPT_ROOT \}\}/ordinary-ci-receipt\.json\s*$' -and
    $_ -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and
    $_ -match '(?m)^\s*retention-days:\s*14\s*$'
})
Check ($exactHeadJobs.Count -eq 3) 'every ordinary PR job checks out the exact pull request head without persisted credentials' 'an ordinary PR job validates a merge ref, another revision, or persisted credentials'
Check ($receiptJobs.Count -eq 3 -and @([regex]::Matches($workflow,'scripts/write-ordinary-ci-receipt\.ps1')).Count -eq 3 -and $workflow -match 'thin-v2-pr-core-\$\{\{ matrix\.core_group \}\}-\$\{\{ github\.event\.pull_request\.head\.sha \}\}' -and $workflow -match 'thin-v2-pr-core-aggregate-\$\{\{ github\.event\.pull_request\.head\.sha \}\}' -and $workflow -match 'thin-v2-pr-changed-optional-\$\{\{ github\.event\.pull_request\.head\.sha \}\}') 'ordinary PR jobs upload one fixed exact-head machine receipt without raw logs' 'ordinary PR receipt generation, naming, or upload scope is unsafe'
$guardPattern = '(?ms)^    steps:[ \t]*\r?\n^      - name: Require all core groups to pass[ \t]*\r?\n^        shell: pwsh[ \t]*\r?\n^        env:[ \t]*\r?\n^          CORE_CHECKS_RESULT: \$\{\{[ \t]*needs\.pr-core-checks\.result[ \t]*\}\}[ \t]*\r?\n^        run: \|[ \t]*\r?\n^          if \(\$env:CORE_CHECKS_RESULT -cne ''success''\) \{[ \t]*\r?\n^              throw "PR core checks did not succeed: \$env:CORE_CHECKS_RESULT"[ \t]*\r?\n^          \}[ \t]*\r?\n(?:^[ \t]*\r?\n)?(?=^      - name: Check out repository[ \t]*\r?$)'
$guardMatches = [regex]::Matches($prCoreJob,$guardPattern)
$guardIndex = $prCoreJob.IndexOf('Require all core groups to pass',[StringComparison]::Ordinal)
$checkoutIndex = $prCoreJob.IndexOf('Check out repository',[StringComparison]::Ordinal)
$rollbackIndex = $prCoreJob.IndexOf('Core installation rollback',[StringComparison]::Ordinal)
Check (@([regex]::Matches($prCoreJob,'(?m)^    needs:[ \t]*pr-core-checks[ \t]*\r?$')).Count -eq 1 -and @([regex]::Matches($prCoreJob,'(?m)^    if:[ \t]*\$\{\{[ \t]*always\(\)[ \t]*&&[ \t]*github\.event_name[ \t]*==[ \t]*''pull_request''[ \t]*\}\}[ \t]*\r?$')).Count -eq 1 -and $guardMatches.Count -eq 1 -and $guardIndex -ge 0 -and $checkoutIndex -gt $guardIndex -and $rollbackIndex -gt $checkoutIndex -and $prCoreJob -notmatch '(?m)^\s{4,8}continue-on-error:') 'required pr-core fails closed before checkout and rollback when any shard is not successful' 'required pr-core can become skipped-success, mask a shard failure, or run rollback before its guard'
Check ($changedOptionalBlock.Value -match 'run-changed-optional-validation\.ps1' -and $rolloutGenerator -match 'GateEvidencePath' -and $rolloutGenerator -notmatch 'run-validation\.ps1 -Suite all') 'optional validation remains delegated while DP-02A Generator consumes only normalized evidence' 'optional validation or DP-02A Generator entry is wrong'
Check ($prCoreJob -match 'run-isolated-install-smoke\.ps1[^\r\n]+-Preset core' -and $workflow -match 'generate-v2-rollout-report\.ps1' -and $rolloutGenerator -notmatch 'run-isolated-install-smoke\.ps1') 'PR retains core rollback while DP-02A rejects lifecycle-smoke substitution in release evidence' 'PR rollback coverage or DP-02A lifecycle boundary is incomplete'
Check ($trustedProducerCount -eq 2 -and $releaseJob -match $aggregatorRunnerPattern -and $releaseJob -match '(?m)^\s*environment:\s*thin-v2-release\s*$' -and $releaseJob -match '(?m)^\s*persist-credentials:\s*false\s*$' -and $releaseJob -notmatch 'HOST_BENCHMARK_CODEX_HOME' -and $releaseJob -notmatch '(?i)secrets\.') 'credentialed producers and credential-blind aggregator use separate dedicated runner labels' 'release runner, trusted-ref, environment, or credential-blind aggregator boundary is unsafe'
$modelPrepareIndex = $releaseModelJob.IndexOf('Prepare model evidence directory',[StringComparison]::Ordinal)
$modelBoundaryIndex = $releaseModelJob.IndexOf('scripts/assert-release-runner-boundary.ps1',[StringComparison]::Ordinal)
$modelWorkIndex = $releaseModelJob.IndexOf('scripts/run-model-evals.ps1',[StringComparison]::Ordinal)
$hostPrepareIndex = $releaseHostJob.IndexOf('Prepare host evidence directory',[StringComparison]::Ordinal)
$hostBoundaryIndex = $releaseHostJob.IndexOf('scripts/assert-release-runner-boundary.ps1',[StringComparison]::Ordinal)
$hostWorkIndex = $releaseHostJob.IndexOf('scripts/run-host-benchmark.ps1',[StringComparison]::Ordinal)
$producerBoundaryValid = @(@($releaseModelJob,$releaseHostJob) | Where-Object { $_ -match '(?m)^\s*runner_account_digest:\s*\$\{\{\s*steps\.runner_boundary\.outputs\.runner_account_digest\s*\}\}\s*$' }).Count -eq 2 -and
    $releaseModelJob -match 'assert-release-runner-boundary\.ps1 -Mode producer\b[^\r\n]+-RunId \$env:GITHUB_RUN_ID[^\r\n]+-RunAttempt \$env:GITHUB_RUN_ATTEMPT[^\r\n]+-RepoRoot \$PWD[^\r\n]+-Role model-producer[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+model-runner-observation\.json[^\r\n]+-ProducerMode formal' -and
    $releaseHostJob -match 'assert-release-runner-boundary\.ps1 -Mode producer\b[^\r\n]+-RunId \$env:GITHUB_RUN_ID[^\r\n]+-RunAttempt \$env:GITHUB_RUN_ATTEMPT[^\r\n]+-RepoRoot \$PWD[^\r\n]+-Role host-producer[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+host-runner-observation\.json[^\r\n]+-ProducerMode formal' -and
    $modelPrepareIndex -ge 0 -and $modelBoundaryIndex -gt $modelPrepareIndex -and $modelWorkIndex -gt $modelBoundaryIndex -and
    $hostPrepareIndex -ge 0 -and $hostBoundaryIndex -gt $hostPrepareIndex -and $hostWorkIndex -gt $hostBoundaryIndex
$aggregatorBoundaryIndex = $releaseJob.IndexOf('scripts/assert-release-runner-boundary.ps1',[StringComparison]::Ordinal)
$aggregatorDownloadIndex = $releaseJob.IndexOf('actions/download-artifact@',[StringComparison]::Ordinal)
$aggregatorObservationIndex = $releaseJob.IndexOf("aggregator-runner-observation.json",[StringComparison]::Ordinal)
$releaseFullReceiptIndex = $releaseJob.IndexOf('scripts/write-release-full-receipt.ps1',[StringComparison]::Ordinal)
$releaseFullBindingIndex = $releaseJob.IndexOf('scripts/write-capability-source-binding.ps1',[StringComparison]::Ordinal)
Check ($producerBoundaryValid -and
    $releaseJob -match '(?m)^\s*MODEL_PRODUCER_ACCOUNT_DIGEST:\s*\$\{\{\s*needs\.release-model\.outputs\.runner_account_digest\s*\}\}\s*$' -and
    $releaseJob -match '(?m)^\s*HOST_PRODUCER_ACCOUNT_DIGEST:\s*\$\{\{\s*needs\.release-host\.outputs\.runner_account_digest\s*\}\}\s*$' -and
    $releaseJob -match 'assert-release-runner-boundary\.ps1 -Mode aggregator\b[^\r\n]+-ModelProducerAccountDigest \$env:MODEL_PRODUCER_ACCOUNT_DIGEST[^\r\n]+-HostProducerAccountDigest \$env:HOST_PRODUCER_ACCOUNT_DIGEST' -and
    $aggregatorDownloadIndex -ge 0 -and $aggregatorObservationIndex -gt $aggregatorDownloadIndex -and $releaseFullReceiptIndex -gt $aggregatorObservationIndex) 'release producers publish account digests and the current aggregator binds both after fail-closed downloads' 'release account boundary or current aggregation order is missing or unbound'
Check ($releaseModelJob -match '(?m)^\s*timeout-minutes:\s*120\s*$' -and $releaseHostJob -match '(?m)^\s*timeout-minutes:\s*240\s*$' -and @([regex]::Matches($releaseHostJob,'(?m)^\s*timeout-minutes:\s*\d+\s*$')).Count -eq 1 -and $releaseJob -match '(?m)^\s*timeout-minutes:\s*120\s*$' -and @($releaseModelJob,$releaseHostJob,$releaseJob | Where-Object { $_ -match '(?m)^\s*fetch-depth:\s*0\s*$' }).Count -eq 3) 'release producers and aggregator use full checkout with bounded 120/240/120-minute budgets' 'release checkout depth or timeout budgets are wrong'
Check ($releaseModelJob -notmatch '(?m)^\s*continue-on-error:' -and $releaseModelJob -match 'run-model-evals\.ps1[^\r\n]+-TimeoutSeconds 120[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+model-eval\.json' -and @([regex]::Matches($releaseModelJob,'scripts/write-release-producer-receipt\.ps1')).Count -eq 1 -and @([regex]::Matches($releaseModelJob,'scripts/write-capability-source-binding\.ps1')).Count -eq 1 -and $releaseModelJob -match 'write-release-producer-receipt\.ps1[^\r\n]+-Kind model[^\r\n]+model-runner-observation\.json[^\r\n]+-ModelReportPath[^\r\n]+model-eval\.json[^\r\n]+release-model-receipt\.json[^\r\n]+-CheckoutSha \$env:GITHUB_SHA[^\r\n]+-Conclusion success[^\r\n]+-ProducerMode formal' -and $releaseModelJob -match 'write-capability-source-binding\.ps1[^\r\n]+-Kind model[^\r\n]+model-capability-source-binding\.json[^\r\n]+-SourceRevision \$env:GITHUB_SHA[^\r\n]+-ProducerMode formal' -and $releaseModelJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\model' -and $releaseModelJob -match 'Model evidence directory already exists') 'release model producer writes the formal G09 receipt and Capability source sidecar from fresh bounded evidence' 'release model producer, G09 writer, or source binding is incomplete'
Check ($releaseHostJob -notmatch '(?m)^\s*continue-on-error:' -and $releaseHostJob -match '(?m)^\s*needs:\s*release-model\s*$' -and @([regex]::Matches($releaseHostJob,'scripts/run-host-benchmark\.ps1')).Count -eq 3 -and @([regex]::Matches($releaseHostJob,'-BenchmarkPath cognitive-fast-path')).Count -eq 1 -and @([regex]::Matches($releaseHostJob,'-BenchmarkPath installed-desktop-path')).Count -eq 2 -and @([regex]::Matches($releaseHostJob,"installed-desktop-primary\.json'")).Count -eq 2 -and @([regex]::Matches($releaseHostJob,"installed-desktop-distinct\.json'")).Count -eq 2 -and @([regex]::Matches($releaseHostJob,'scripts/run-preset-lifecycle-qualification\.ps1')).Count -eq 3 -and @('core','governed','full' | Where-Object { @([regex]::Matches($releaseHostJob,("-Preset {0}\b" -f $_))).Count -eq 1 }).Count -eq 3 -and @([regex]::Matches($releaseHostJob,'scripts/run-v1-stop-loss-qualification\.ps1')).Count -eq 1 -and @([regex]::Matches($releaseHostJob,'scripts/write-release-producer-receipt\.ps1')).Count -eq 1 -and @([regex]::Matches($releaseHostJob,'scripts/write-capability-source-binding\.ps1')).Count -eq 1 -and $releaseHostJob -match 'write-release-producer-receipt\.ps1[^\r\n]+-Kind host[^\r\n]+host-runner-observation\.json[^\r\n]+cognitive-host\.json[^\r\n]+installed-desktop-primary\.json[^\r\n]+installed-desktop-distinct\.json[^\r\n]+release-host-receipt\.json[^\r\n]+-CheckoutSha \$env:GITHUB_SHA[^\r\n]+-Conclusion success[^\r\n]+-ProducerMode formal' -and $releaseHostJob -match 'write-capability-source-binding\.ps1[^\r\n]+-Kind host[^\r\n]+host-capability-source-binding\.json[^\r\n]+-SourceRevision \$env:GITHUB_SHA[^\r\n]+-ProducerMode formal' -and $releaseHostJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\host' -and $releaseHostJob -match 'Host evidence directory already exists' -and $releaseHostJob -notmatch '(?i)Fixture|ValidateOnly|diagnostic-smoke|EligibilityReportPath') 'release host producer writes distinct 3x3, lifecycle, G14, formal G10, and Capability source sidecar once' 'release host producer, distinct output, lifecycle, G14, G10, or source binding is incomplete'
Check ($releaseJob -match '!cancelled\(\)' -and $releaseJob -notmatch 'always\(\)' -and $releaseJob -match '(?ms)^\s*needs:\s*\r?\n\s*- release-model\s*\r?\n\s*- release-host' -and @([regex]::Matches($releaseJob,[regex]::Escape($downloadAction))).Count -eq 4 -and
    $releaseJob -match 'write-release-full-receipt\.ps1[^\r\n]+exact-head-engineering\.json[^\r\n]+release-isolation\.json[^\r\n]+release-model-receipt\.json[^\r\n]+release-host-receipt\.json[^\r\n]+v1-stop-loss\.json[^\r\n]+lifecycle-core\.json[^\r\n]+lifecycle-governed\.json[^\r\n]+lifecycle-full\.json[^\r\n]+aggregator-runner-observation\.json[^\r\n]+release-full-receipt\.json' -and
    @([regex]::Matches($releaseJob,'scripts/write-capability-source-binding\.ps1')).Count -eq 1 -and $releaseFullBindingIndex -gt $releaseFullReceiptIndex -and $releaseJob -match 'write-capability-source-binding\.ps1[^\r\n]+-Kind full[^\r\n]+full-capability-source-binding\.json[^\r\n]+-SourceRevision \$env:GITHUB_SHA[^\r\n]+-ProducerMode formal[^\r\n]+model-capability-source-binding\.json[^\r\n]+host-capability-source-binding\.json' -and
    $releaseJob -match '(?s)Legacy full validation.*?generate-v2-rollout-report\.ps1[^\r\n]+-ModelEvalReportPath[^\r\n]+-HostBenchmarkReportPath' -and $releaseJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\aggregate') 'release-full wires strict G11 aggregation while preserving an explicit legacy-only path' 'release-full G11 or legacy boundary is incomplete'
Check ($modelUpload -match [regex]::Escape($uploadAction) -and $modelUpload -match '\$\{\{ success\(\)' -and $modelUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and ($modelBundlePaths -join '|') -ceq ($expectedModelBundlePaths -join '|') -and $hostUpload -match [regex]::Escape($uploadAction) -and $hostUpload -match '\$\{\{ success\(\)' -and $hostUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and ($hostBundlePaths -join '|') -ceq ($expectedHostBundlePaths -join '|')) 'release producers upload exact fresh 4-file and 10-file bundles only after successful source binding' 'release producer artifact bundle or failure semantics are wrong'
Check ($currentReleaseUpload -match [regex]::Escape($uploadAction) -and $currentReleaseUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and ($currentBundlePaths -join '|') -ceq ($expectedCurrentBundlePaths -join '|') -and
    $legacyReleaseUpload -match '!cancelled\(\)' -and $legacyReleaseUpload -match [regex]::Escape($uploadAction) -and $legacyReleaseUpload -match '(?m)^\s*if-no-files-found:\s*warn\s*$' -and @([regex]::Matches($legacyReleaseUpload,'(?m)^\s+\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/[a-z0-9-]+\.json\s*$')).Count -eq 3 -and
    ($modelUpload + $hostUpload + $currentReleaseUpload + $legacyReleaseUpload) -notmatch '(?i)auth\.json|CODEX_ACCESS_TOKEN|OPENAI_API_KEY|secrets\.') 'release artifact scopes contain exact current and legacy sanitized JSON bundles without credential transport' 'release artifact scope or credential boundary is unsafe'
Check ($rolloutGenerator -match 'GateEvidencePath' -and $rolloutGenerator -match 'Read-RolloutInputDocument -Path \$GateEvidencePath -Kind evidence-set' -and $rolloutGenerator -match 'Assert-HarnessRolloutEvidenceSetProvenance' -and $rolloutGenerator -match 'rollout-evidence-provenance-unverified' -and $rolloutGenerator -match 'rollout-v1-evidence-inputs-are-historical-only' -and $rolloutGenerator -notmatch 'run-validation\.ps1 -Suite all' -and $rolloutGenerator -notmatch 'run-isolated-install-smoke\.ps1' -and $rolloutGenerator -notmatch 'run-scenario-evals\.ps1 -Suite core' -and $rolloutGenerator -notmatch 'benchmark-harness\.ps1 -Compare bare,v1,v2') 'DP-02A rollout generation accepts only the strict normalized evidence set and rejects legacy/proxy aggregation' 'rollout generation can still authorize from legacy, lifecycle-smoke, deterministic, or fixture inputs'

$validation = Get-Content -LiteralPath $validationPath -Raw -Encoding utf8
$routerSource = Get-Content -LiteralPath $script:router -Raw -Encoding utf8
$validationTokens=$null;$validationErrors=$null
$validationAst=[System.Management.Automation.Language.Parser]::ParseFile($validationPath,[ref]$validationTokens,[ref]$validationErrors)
$manifestCatalogText = Get-Content -LiteralPath $manifestCatalogPath -Raw -Encoding utf8
$manifestCatalog = $manifestCatalogText | ConvertFrom-Json -AsHashtable -Depth 100
$expectedGroupNames = @('entry-lifecycle','evaluation-release','install-evidence','governance-approval','harness-contracts')
$expectedGroupSizes = @(14,14,4,3,21)
$catalogGroupKeys = @($manifestCatalog.core_groups.Keys | Sort-Object -CaseSensitive)
$coreGroupNames = @($expectedGroupNames)
$coreGroupSizes = @($coreGroupNames | ForEach-Object { @($manifestCatalog.core_groups[$_]).Count })
$actualCoreScripts = [Collections.Generic.List[string]]::new()
foreach ($groupName in $coreGroupNames) {
    foreach ($testPath in @($manifestCatalog.core_groups[$groupName])) { $actualCoreScripts.Add((Split-Path -Leaf ([string]$testPath))) }
}
$catalogShapeValid = [string]$manifestCatalog.schema_version -ceq 'module-manifest-catalog/v1' -and @($manifestCatalog.modules).Count -eq 13 -and $manifestCatalog.totals.v0_module_count -eq 6 -and $manifestCatalog.totals.v1_module_count -eq 7 -and $manifestCatalog.totals.capability_source_count -eq 7 -and @($manifestCatalog.optional_routes).Count -eq 8 -and ($catalogGroupKeys -join '|') -ceq ((@($expectedGroupNames | Sort-Object -CaseSensitive)) -join '|')
$validationCatalogIndex = $validation.IndexOf('Assert-HarnessModuleManifestCatalogCurrent',[StringComparison]::Ordinal)
$validationFirstCheckIndex = $validation.IndexOf('Add-GitCheck -Checks',[StringComparison]::Ordinal)
$routerCatalogIndex = $routerSource.IndexOf('Assert-HarnessModuleManifestCatalogCurrent',[StringComparison]::Ordinal)
$routerExecutionIndex = $routerSource.IndexOf('foreach ($testName in $testNames)',[StringComparison]::Ordinal)
$verifierLiterals = @([regex]::Matches($validation,"'(?<name>verify-[a-z0-9-]+\.ps1)'") | ForEach-Object { $_.Groups['name'].Value } | Sort-Object -CaseSensitive -Unique)
$allowedValidationVerifierLiterals = @('verify-capability-extraction.ps1','verify-host-benchmark-qualification.ps1','verify-installation.ps1','verify-v2-approval.ps1','verify-v2-ci-routing.ps1','verify-v2-evidence.ps1','verify-v2-governed-audit.ps1','verify-v2-install-presets.ps1')
$unexpectedVerifierLiterals = @($verifierLiterals | Where-Object { $_ -cnotin $allowedValidationVerifierLiterals })
$catalogDerivationValid = $validationErrors.Count -eq 0 -and $catalogShapeValid -and
    $validation.Contains('Catalog.core_groups',[StringComparison]::Ordinal) -and
    $validation.Contains('Catalog.quick_tests',[StringComparison]::Ordinal) -and
    $validation.Contains('Catalog.full_tests',[StringComparison]::Ordinal) -and
    $routerSource.Contains('Catalog.optional_routes',[StringComparison]::Ordinal) -and
    $routerSource -notmatch '\[ordered\]@\{name=' -and
    $unexpectedVerifierLiterals.Count -eq 0 -and
    $validationCatalogIndex -ge 0 -and $validationFirstCheckIndex -gt $validationCatalogIndex -and
    $routerCatalogIndex -ge 0 -and $routerExecutionIndex -gt $routerCatalogIndex
$coreScriptAssignments = @($validationAst.FindAll({param($node)$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$coreScripts'},$true))
$flattenValid = $coreScriptAssignments.Count -eq 1 -and (($coreScriptAssignments[0].Right.Extent.Text -replace '\s','') -ceq '@($coreScriptGroups.Values|ForEach-Object{$_})')
$scriptNameAssignments = @($validationAst.FindAll({param($node)$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$scriptNames'},$true))
$namedGroupAssignments = @($scriptNameAssignments | Where-Object { (($_.Right.Extent.Text -replace '\s','') -ceq '@($coreScriptGroups[$CoreGroup])') })
$groupSelectionValid = $false
if($scriptNameAssignments.Count -eq 4 -and $namedGroupAssignments.Count -eq 1){
    $namedGroupAssignment = $namedGroupAssignments[0]
    $coreGroupIf = $namedGroupAssignment.Parent.Parent
    if($coreGroupIf -is [System.Management.Automation.Language.IfStatementAst] -and
        $coreGroupIf.Clauses.Count -eq 1 -and
        (($coreGroupIf.Clauses[0].Item1.Extent.Text -replace '\s','') -ceq '$CoreGroup-eq''all''') -and
        $null -ne $coreGroupIf.ElseClause -and
        [object]::ReferenceEquals($namedGroupAssignment.Parent,$coreGroupIf.ElseClause) -and
        @($coreGroupIf.ElseClause.Statements).Count -eq 1){
        $suiteIf = $coreGroupIf.Parent.Parent
        $groupSelectionValid = $suiteIf -is [System.Management.Automation.Language.IfStatementAst] -and
            $suiteIf.Clauses.Count -eq 2 -and
            (($suiteIf.Clauses[1].Item1.Extent.Text -replace '\s','') -ceq '$Suite-eq''core''') -and
            [object]::ReferenceEquals($coreGroupIf.Parent,$suiteIf.Clauses[1].Item2) -and
            @($suiteIf.Clauses[1].Item2.Statements).Count -eq 1
    }
}
$coreGroupParameters = @($validationAst.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -ceq 'CoreGroup'})
$coreGroupValidateSet = @()
if($coreGroupParameters.Count -eq 1){
    $coreGroupValidateSet = @($coreGroupParameters[0].Attributes | Where-Object {$_.TypeName.FullName -ceq 'ValidateSet'})
}
$coreGroupAllowed = @()
if($coreGroupValidateSet.Count -eq 1){
    $coreGroupAllowed = @($coreGroupValidateSet[0].PositionalArguments | ForEach-Object {$_.SafeGetValue()})
}
$coreGroupDefault = if($coreGroupParameters.Count -eq 1){$coreGroupParameters[0].DefaultValue.SafeGetValue()}else{''}
$optionalCoreOverlap = @($routing.tests | Where-Object {$actualCoreScripts -ccontains $_})
Check ($catalogDerivationValid -and ($coreGroupNames -join '|') -ceq ($expectedGroupNames -join '|') -and ($coreGroupSizes -join '|') -ceq ($expectedGroupSizes -join '|') -and $actualCoreScripts.Count -eq 56 -and @($actualCoreScripts | Sort-Object -CaseSensitive -Unique).Count -eq 56 -and @($actualCoreScripts | Where-Object {-not(Test-Path -LiteralPath (Join-Path $RepoRoot "tests\$_") -PathType Leaf)}).Count -eq 0) 'five core groups derive the exact fifty-six unique scripts from the tracked catalog' 'catalog derivation, CoreGroup boundary, membership, uniqueness, order, or files drifted'
Check (@($manifestCatalog.core_groups['install-evidence']) -ccontains 'tests/verify-declarative-distribution.ps1') 'TK-06 declarative Distribution validation belongs to install-evidence' 'TK-06 Distribution verifier is missing from its core owner group'
Check ($flattenValid -and $groupSelectionValid -and $coreGroupDefault -ceq 'all' -and ($coreGroupAllowed -join '|') -ceq ((@('all')+$expectedCoreGroups) -join '|') -and $validation -match "'-CoreGroup',\`$CoreGroup" -and $validation -match "\`$Suite -ne 'core'.*\`$CoreGroup -ne 'all'") 'CoreGroup defaults to the full legacy suite, bridges safely, and rejects non-core use' 'CoreGroup parameter, flattening, bridge, or selection contract drifted'
Check (($optionalCoreOverlap -join '|') -ceq 'verify-canonical-json.ps1|verify-hashing-module.ps1|verify-kernel-tcb-inventory.ps1|verify-module-manifest-catalog.ps1|verify-shared-memory-layers.ps1|verify-thin-adapters.ps1|verify-thin-trust-kernel-contracts.ps1|verify-v2-runtime-memory-decoupling.ps1') 'optional routes reuse only the eight established lightweight and architecture contract verifiers' 'optional routes unexpectedly duplicate core verifier work'
$verifierInventory = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests') -Filter 'verify-*.ps1' -File | Select-Object -ExpandProperty Name | Sort-Object -CaseSensitive -Unique)
$ordinaryCiVerifiers = @(@($actualCoreScripts | Where-Object { $_ -clike 'verify-*.ps1' }) + @($routing.tests) + 'verify-installation.ps1' | Sort-Object -CaseSensitive -Unique)
Check (($ordinaryCiVerifiers -join '|') -ceq ($verifierInventory -join '|')) 'ordinary PR CI has a traceable route for every repository verifier' 'one or more repository verifiers have no traceable ordinary PR CI route'

$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding utf8
$scenarioDoc = Get-Content -LiteralPath $scenarioDocPath -Raw -Encoding utf8
$compatibilityPolicy = Get-Content -LiteralPath $compatibilityPolicyPath -Raw -Encoding utf8
Check ($readme -match '普通 PR.*pr-core-checks' -and $readme -match 'changed.optional' -and $readme -match 'docs/release/default-promotion-gates\.md') 'README documents ordinary layered validation and delegates release details' 'README CI documentation is stale'
Check ($readme -notmatch 'Codex CLI/service `0\.144\.4`' -and $compatibilityPolicy -match 'PowerShell 7\.3\+' -and $compatibilityPolicy -match 'Codex CLI/service `0\.144\.4`' -and @([regex]::Matches($compatibilityPolicy,'configured model/host/aggregate budgets remain 120/240/120 minutes')).Count -eq 1 -and $compatibilityPolicy -notmatch '120/180/120') 'exact release prerequisites stay in release policy and out of ordinary README' 'release prerequisite documentation crossed the Runtime/Qualification boundary'
Check ($compatibilityPolicy -match 'THIN_V2_RELEASE_RUNNER.*repository/org-level variables, not environment-level variables' -and $compatibilityPolicy -match 'THIN_V2_RELEASE_AGGREGATOR_RUNNER') 'release policy keeps both runs-on selectors at repository/org scope' 'release policy does not document the GitHub Actions runner-selector variable scopes'
Check ($scenarioDoc -match '(?s)run-host-benchmark\.ps1.*?-Groups 3.*?-Trials 3.*?host-benchmark\.json') 'scenario eval guide invokes three independent host groups instead of a flat trial count' 'scenario eval guide omits the release host group count'
Check (@([regex]::Matches($scenarioDoc,'preserve the 120/240/120-minute budgets')).Count -eq 1 -and $scenarioDoc -notmatch '120/180/120') 'scenario eval guide preserves the measured release-host budget for later wiring' 'scenario eval guide release budgets are stale'
Check (@([regex]::Matches($compatibilityPolicy,'configured model/host/aggregate budgets remain 120/240/120 minutes')).Count -eq 1 -and $compatibilityPolicy -notmatch '120/180/120') 'compatibility policy preserves the measured release-host budget for later wiring' 'compatibility policy release budgets are stale'

foreach($item in $script:checks){Write-Output "[PASS] $item"}
foreach($item in $script:failures){Write-Output "[FAIL] $item"}
if($script:failures.Count){Write-Output "STATUS: FAIL ($($script:failures.Count) failed)";exit 1}
Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
exit 0
