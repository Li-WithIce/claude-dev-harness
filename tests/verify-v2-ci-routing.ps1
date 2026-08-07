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
$validationPath = Join-Path $RepoRoot 'scripts\run-validation.ps1'
$rolloutGeneratorPath = Join-Path $RepoRoot 'scripts\generate-v2-rollout-report.ps1'
$runnerBoundaryPath = Join-Path $RepoRoot 'scripts\assert-release-runner-boundary.ps1'
$receiptWriterPath = Join-Path $RepoRoot 'scripts\write-ordinary-ci-receipt.ps1'
$scenarioDocPath = Join-Path $RepoRoot 'docs\testing\scenario-evals.md'
$compatibilityPolicyPath = Join-Path $RepoRoot 'docs\release\compatibility-policy.md'
$readmePath = Join-Path $RepoRoot 'README.md'

foreach ($path in @($script:router,$runner,$runnerBoundaryPath,$receiptWriterPath,$PSCommandPath)) {
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
Check ((@($memory.modules) -join ',') -ceq 'memory' -and @($memory.tests) -ccontains 'verify-memory-provider-boundary.ps1') 'Memory changes select only Memory validation' 'Memory changed-path routing is wrong'
$team = Get-Route @('skills/workflow-team/SKILL.md')
Check ((@($team.modules) -join ',') -ceq 'team' -and @($team.tests) -ccontains 'verify-aiteamcode-skill-contract.ps1') 'Team changes select Team validation' 'Team changed-path routing is wrong'
$adapterDispatch = Get-Route @('scripts/invoke-harness-skill-dispatcher.ps1')
Check ((@($adapterDispatch.modules) -join ',') -ceq 'team' -and @($adapterDispatch.tests) -ccontains 'verify-aiteamcode-skill-contract.ps1') 'Harness adapter dispatcher changes select lifecycle validation' 'Harness adapter dispatcher change skipped lifecycle validation'
$html = Get-Route @('skills/md-html/SKILL.md')
Check ((@($html.modules) -join ',') -ceq 'md-html' -and @($html.tests).Count -eq 2) 'md-html changes select renderer validation' 'md-html changed-path routing is wrong'
$codex = Get-Route @('skills/codex/SKILL.md')
Check ((@($codex.modules) -join ',') -ceq 'codex-adapter' -and @($codex.tests) -ccontains 'verify-ask-codex.ps1') 'Codex adapter changes select adapter validation' 'Codex adapter changed-path routing is wrong'
$providers = Get-Route @('policies/context-provider-policy.json')
Check ((@($providers.modules) -join ',') -ceq 'providers' -and @($providers.tests).Count -eq 4) 'Provider changes select provider boundary validation' 'Provider changed-path routing is wrong'
$routing = Get-Route @('.github/workflows/validation.yml')
Check ($routing.run_all_optional -and @($routing.modules).Count -eq 5 -and @($routing.tests).Count -eq 12) 'routing-surface changes fail safe to every optional suite' 'routing-surface changes did not select all optional suites'

$workflow = Get-Content -LiteralPath $workflowPath -Raw -Encoding utf8
$rolloutGenerator = Get-Content -LiteralPath $rolloutGeneratorPath -Raw -Encoding utf8
$prCoreChecksBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'pr-core-checks'
$prCoreBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'pr-core'
$changedOptionalBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'changed-optional'
$releaseModelBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-model'
$releaseHostBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-host'
$releaseBlock = Get-WorkflowJobBlock -Text $workflow -JobId 'release-full'
$prCoreChecksJob = $prCoreChecksBlock.Value
$prCoreJob = $prCoreBlock.Value
$changedOptionalJob = $changedOptionalBlock.Value
$releaseModelJob = $releaseModelBlock.Value
$releaseHostJob = $releaseHostBlock.Value
$releaseJob = $releaseBlock.Value
$producerRunnerPattern = '(?ms)^\s*runs-on:\s*\r?\n\s*-\s*self-hosted\s*\r?\n\s*-\s*Windows\s*\r?\n\s*-\s*\$\{\{\s*vars\.THIN_V2_RELEASE_RUNNER\s*\}\}\s*$'
$aggregatorRunnerPattern = '(?ms)^\s*runs-on:\s*\r?\n\s*-\s*self-hosted\s*\r?\n\s*-\s*Windows\s*\r?\n\s*-\s*\$\{\{\s*vars\.THIN_V2_RELEASE_AGGREGATOR_RUNNER\s*\}\}\s*$'
$modelUpload = [regex]::Match($releaseModelJob,'(?ms)^      - name: Upload model evidence\s*$.*\z').Value
$hostUpload = [regex]::Match($releaseHostJob,'(?ms)^      - name: Upload host evidence\s*$.*\z').Value
$releaseUpload = [regex]::Match($releaseJob,'(?ms)^      - name: Upload rollout evidence\s*$.*\z').Value
$checkoutAction = 'actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5'
$uploadAction = 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
$downloadAction = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
$trustedRefs = @('refs/heads/main','refs/heads/codex/harness-distribution','refs/heads/codex/thin-harness-v2-refactor')
$trustedProducerCount = 0
foreach ($producer in @($releaseModelJob,$releaseHostJob)) {
    if ($producer -match $producerRunnerPattern -and
        $producer -match '(?m)^\s*HOST_BENCHMARK_CODEX_HOME:\s*\$\{\{\s*vars\.HOST_BENCHMARK_CODEX_HOME\s*\}\}\s*$' -and
        $producer -match '(?m)^\s*environment:\s*thin-v2-release\s*$' -and
        $producer -match '(?m)^\s*persist-credentials:\s*false\s*$' -and
        $producer -match '!cancelled\(\)' -and @($trustedRefs | Where-Object { $producer -notmatch [regex]::Escape($_) }).Count -eq 0 -and
        $producer -notmatch '(?i)secrets\.') { $trustedProducerCount++ }
}
Check ($workflow -match '(?m)^\s*schedule:\s*$' -and $workflow -match '(?m)^\s*workflow_dispatch:\s*$') 'CI exposes nightly and manual release validation' 'CI lacks nightly or manual release validation'
Check (@($prCoreChecksBlock,$prCoreBlock,$changedOptionalBlock,$releaseModelBlock,$releaseHostBlock,$releaseBlock | Where-Object Count -eq 1).Count -eq 6) 'CI declares each PR and release job exactly once' 'CI job layering is missing or duplicated'
Check (@([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($checkoutAction)))).Count -eq 6 -and @([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($uploadAction)))).Count -eq 6 -and @([regex]::Matches($workflow,('(?m)^        uses: {0}[ \t]*(?:#.*)?\r?$' -f [regex]::Escape($downloadAction)))).Count -eq 2 -and $workflow -notmatch '(?m)^\s*uses:\s*actions/(?:checkout|upload-artifact|download-artifact)@v\d+') 'every GitHub Action dependency is pinned to a verified full commit SHA' 'GitHub Action dependencies are movable or not pinned to the approved commits'
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
$producerBoundaryCount = 0
foreach ($producer in @($releaseModelJob,$releaseHostJob)) {
    $boundaryIndex = $producer.IndexOf('scripts/assert-release-runner-boundary.ps1',[StringComparison]::Ordinal)
    $producerWorkIndex = $producer.IndexOf('evidence directory',[StringComparison]::Ordinal)
    if ($producer -match '(?m)^\s*runner_account_digest:\s*\$\{\{\s*steps\.runner_boundary\.outputs\.runner_account_digest\s*\}\}\s*$' -and
        $producer -match '(?ms)^\s*- name: Assert credentialed producer runner boundary\s*$\r?\n\s*id:\s*runner_boundary\s*$.*?assert-release-runner-boundary\.ps1 -Mode producer\b' -and
        $boundaryIndex -ge 0 -and $producerWorkIndex -gt $boundaryIndex) { $producerBoundaryCount++ }
}
$aggregatorBoundaryIndex = $releaseJob.IndexOf('scripts/assert-release-runner-boundary.ps1',[StringComparison]::Ordinal)
$aggregatorDownloadIndex = $releaseJob.IndexOf('actions/download-artifact@',[StringComparison]::Ordinal)
$aggregatorGenerateIndex = $releaseJob.IndexOf('scripts/generate-v2-rollout-report.ps1',[StringComparison]::Ordinal)
Check ($producerBoundaryCount -eq 2 -and
    $releaseJob -match '(?m)^\s*MODEL_PRODUCER_ACCOUNT_DIGEST:\s*\$\{\{\s*needs\.release-model\.outputs\.runner_account_digest\s*\}\}\s*$' -and
    $releaseJob -match '(?m)^\s*HOST_PRODUCER_ACCOUNT_DIGEST:\s*\$\{\{\s*needs\.release-host\.outputs\.runner_account_digest\s*\}\}\s*$' -and
    $releaseJob -match 'assert-release-runner-boundary\.ps1 -Mode aggregator\b[^\r\n]+-ModelProducerAccountDigest \$env:MODEL_PRODUCER_ACCOUNT_DIGEST[^\r\n]+-HostProducerAccountDigest \$env:HOST_PRODUCER_ACCOUNT_DIGEST' -and
    $aggregatorBoundaryIndex -ge 0 -and $aggregatorDownloadIndex -gt $aggregatorBoundaryIndex -and $aggregatorGenerateIndex -gt $aggregatorBoundaryIndex) 'release producers publish account digests and the aggregator verifies both before consuming evidence' 'release account boundary is missing, unbound, or runs after evidence consumption'
Check ($releaseModelJob -match '(?m)^\s*timeout-minutes:\s*120\s*$' -and $releaseHostJob -match '(?m)^\s*timeout-minutes:\s*240\s*$' -and @([regex]::Matches($releaseHostJob,'(?m)^\s*timeout-minutes:\s*\d+\s*$')).Count -eq 1 -and $releaseJob -match '(?m)^\s*timeout-minutes:\s*120\s*$' -and @($releaseModelJob,$releaseHostJob,$releaseJob | Where-Object { $_ -match '(?m)^\s*fetch-depth:\s*0\s*$' }).Count -eq 3) 'release producers and aggregator use full checkout with bounded 120/240/120-minute budgets' 'release checkout depth or timeout budgets are wrong'
Check ($releaseModelJob -notmatch '(?m)^\s*continue-on-error:' -and $releaseModelJob -match 'run-model-evals\.ps1[^\r\n]+-TimeoutSeconds 120[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+model-eval\.json' -and $releaseModelJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\model' -and $releaseModelJob -match 'Model evidence directory already exists') 'release model producer bounds real sessions and refuses stale evidence directories' 'release model producer contract is incomplete'
Check ($releaseHostJob -notmatch '(?m)^\s*continue-on-error:' -and $releaseHostJob -match '(?m)^\s*needs:\s*release-model\s*$' -and $releaseHostJob -match 'run-host-benchmark\.ps1[^\r\n]+-TimeoutSeconds 900[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+-Groups 3[^\r\n]+-Trials 3[^\r\n]+host-benchmark\.json' -and $releaseHostJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\host' -and $releaseHostJob -match 'Host evidence directory already exists') 'release host producer runs three independent 3x3 groups after model and refuses stale directories' 'release host producer contract is incomplete'
Check ($releaseJob -match '!cancelled\(\)' -and $releaseJob -notmatch 'always\(\)' -and $releaseJob -match '(?ms)^\s*needs:\s*\r?\n\s*- release-model\s*\r?\n\s*- release-host' -and @([regex]::Matches($releaseJob,[regex]::Escape($downloadAction))).Count -eq 2 -and $releaseJob -match 'generate-v2-rollout-report\.ps1[^\r\n]+-ModelEvalReportPath[^\r\n]+model-eval\.json[^\r\n]+-HostBenchmarkReportPath[^\r\n]+host-benchmark\.json[^\r\n]+v2-rollout-eligibility\.json[^\r\n]+-RequireEligible' -and $releaseJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\aggregate') 'release aggregator runs after failed producers unless cancelled and consumes a fresh fixed evidence directory' 'release aggregator can resist cancellation, reuse stale evidence, or emit a non-eligible successful release'
Check ($modelUpload -match [regex]::Escape($uploadAction) -and $modelUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and @([regex]::Matches($modelUpload,'(?m)^\s+path:\s*\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/model-eval\.json\s*$')).Count -eq 1 -and $hostUpload -match [regex]::Escape($uploadAction) -and $hostUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and @([regex]::Matches($hostUpload,'(?m)^\s+path:\s*\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/host-benchmark\.json\s*$')).Count -eq 1) 'release producers upload exactly one fresh evidence JSON or fail' 'release producer artifact scope is wrong'
Check ($releaseUpload -match '!cancelled\(\)' -and $releaseUpload -match [regex]::Escape($uploadAction) -and $releaseUpload -match '(?m)^\s*if-no-files-found:\s*warn\s*$' -and @([regex]::Matches($releaseUpload,'(?m)^\s+\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/[a-z0-9-]+\.json\s*$')).Count -eq 3 -and ($modelUpload + $hostUpload + $releaseUpload) -notmatch '(?i)auth\.json|CODEX_ACCESS_TOKEN|OPENAI_API_KEY|secrets\.') 'final artifact scope is limited to three fresh sanitized JSON paths without credential transport' 'release artifact scope or credential boundary is unsafe'
Check ($rolloutGenerator -match 'GateEvidencePath' -and $rolloutGenerator -match 'Read-RolloutInputDocument -Path \$GateEvidencePath -Kind evidence-set' -and $rolloutGenerator -match 'Assert-HarnessRolloutEvidenceSetProvenance' -and $rolloutGenerator -match 'rollout-evidence-provenance-unverified' -and $rolloutGenerator -match 'rollout-v1-evidence-inputs-are-historical-only' -and $rolloutGenerator -notmatch 'run-validation\.ps1 -Suite all' -and $rolloutGenerator -notmatch 'run-isolated-install-smoke\.ps1' -and $rolloutGenerator -notmatch 'run-scenario-evals\.ps1 -Suite core' -and $rolloutGenerator -notmatch 'benchmark-harness\.ps1 -Compare bare,v1,v2') 'DP-02A rollout generation accepts only the strict normalized evidence set and rejects legacy/proxy aggregation' 'rollout generation can still authorize from legacy, lifecycle-smoke, deterministic, or fixture inputs'

$validation = Get-Content -LiteralPath $validationPath -Raw -Encoding utf8
$validationTokens=$null;$validationErrors=$null
$validationAst=[System.Management.Automation.Language.Parser]::ParseFile($validationPath,[ref]$validationTokens,[ref]$validationErrors)
$expectedCoreScripts = @(
    'verify-adversarial-review-gate.ps1','verify-entry-routing-clarification.ps1','verify-v2-entry-contract.ps1','verify-v2-protocol-config.ps1','verify-runtime-qualification-decoupling.ps1','verify-v2-direct-no-artifacts.ps1',
    'verify-v2-requirement-gate.ps1','verify-v2-json-compat.ps1','verify-v2-task-state.ps1','verify-v2-model-neutrality.ps1',
    'verify-v1-v2-coexistence.ps1','verify-v1-to-v2-migration.ps1','verify-v2-default-flip.ps1','verify-v2-runtime-memory-decoupling.ps1',
    'run-scenario-evals.ps1','verify-model-eval-runner.ps1','verify-rollout-evidence.ps1','verify-exact-head-engineering-evidence.ps1','verify-v1-stop-loss-qualification.ps1','verify-host-benchmark-runner.ps1',
    'verify-host-benchmark-otel.ps1','verify-host-benchmark-qualification.ps1','verify-release-runner-boundary.ps1','verify-release-isolation-qualification.ps1','verify-release-producer-receipts.ps1','verify-ordinary-ci-receipt.ps1','verify-v2-ci-routing.ps1',
    'verify-v2-install-presets.ps1','verify-preset-lifecycle-qualification.ps1','verify-v2-evidence.ps1',
    'verify-v2-governed-audit.ps1','verify-v2-approval.ps1','verify-v2-readonly-zero-write.ps1',
    'verify-harness-entry.ps1','verify-lite-artifact-validator.ps1','verify-lite-footprint.ps1','verify-minimal-safe-change-policy.ps1',
    'verify-no-node-install-dependency.ps1','verify-placeholder-rendering.ps1','verify-workflow-contracts.ps1','verify-workflow-descriptor.ps1',
    'verify-shared-memory-layers.ps1','verify-stage-discipline-matrix.ps1','verify-release-validation.ps1','verify-runtime-state-contract.ps1',
    'verify-skill-manifest.ps1','verify-task-artifact-drift-audit.ps1','verify-tool-profile.ps1'
)
$expectedGroupSizes = [ordered]@{'entry-lifecycle'=14;'evaluation-release'=13;'install-evidence'=3;'governance-approval'=3;'harness-contracts'=15}
$coreGroupAssignments = @($validationAst.FindAll({param($node)$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$coreScriptGroups'},$true))
$coreGroupNames=[Collections.Generic.List[string]]::new();$coreGroupSizes=[Collections.Generic.List[int]]::new();$actualCoreScripts=[Collections.Generic.List[string]]::new();$coreShapeValid=$validationErrors.Count -eq 0 -and $coreGroupAssignments.Count -eq 1
if($coreShapeValid){
    $hashes=@($coreGroupAssignments[0].Right.FindAll({param($node)$node -is [System.Management.Automation.Language.HashtableAst]},$true));$coreShapeValid=$hashes.Count -eq 1
    if($coreShapeValid){foreach($pair in $hashes[0].KeyValuePairs){
        try{$name=[string]$pair.Item1.SafeGetValue();$members=@($pair.Item2.SafeGetValue())}catch{$coreShapeValid=$false;break}
        if($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or [string]::IsNullOrWhiteSpace($name) -or @($members | Where-Object {$_ -isnot [string] -or $_ -cnotmatch '^[a-z0-9-]+\.ps1$'}).Count){$coreShapeValid=$false;break}
        $coreGroupNames.Add($name);$coreGroupSizes.Add($members.Count);foreach($member in $members){$actualCoreScripts.Add([string]$member)}
    }}
}
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
$optionalNames = @('verify-ask-codex.ps1','verify-codex-entry-autoload.ps1','verify-code-intel-provider-boundary.ps1','verify-context-provider-boundary.ps1','verify-context-provider-install-isolation.ps1','verify-memory-provider-boundary.ps1','verify-md-html-review-renderer.ps1','verify-provider-usage-recording.ps1','verify-render-review-html.ps1','verify-aiteamcode-skill-contract.ps1')
Check ($coreShapeValid -and ($coreGroupNames -join '|') -ceq (@($expectedGroupSizes.Keys) -join '|') -and ($coreGroupSizes -join '|') -ceq (@($expectedGroupSizes.Values) -join '|') -and $actualCoreScripts.Count -eq 48 -and @($actualCoreScripts | Sort-Object -CaseSensitive -Unique).Count -eq 48 -and ($actualCoreScripts -join '|') -ceq ($expectedCoreScripts -join '|') -and @($actualCoreScripts | Where-Object {-not(Test-Path -LiteralPath (Join-Path $RepoRoot "tests\$_") -PathType Leaf)}).Count -eq 0) 'five core groups contain the exact forty-eight unique scripts in registered order' 'core group shape, boundary, membership, uniqueness, order, or files drifted'
Check ($flattenValid -and $groupSelectionValid -and $coreGroupDefault -ceq 'all' -and ($coreGroupAllowed -join '|') -ceq ((@('all')+$expectedCoreGroups) -join '|') -and $validation -match "'-CoreGroup',\`$CoreGroup" -and $validation -match "\`$Suite -ne 'core'.*\`$CoreGroup -ne 'all'") 'CoreGroup defaults to the full legacy suite, bridges safely, and rejects non-core use' 'CoreGroup parameter, flattening, bridge, or selection contract drifted'
Check (@($optionalNames | Where-Object {$actualCoreScripts -ccontains $_}).Count -eq 0) 'core suite excludes changed-path optional modules' 'core suite still runs optional heavy modules unconditionally'

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
