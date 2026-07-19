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
$scenarioDocPath = Join-Path $RepoRoot 'docs\testing\scenario-evals.md'
$readmePath = Join-Path $RepoRoot 'README.md'

foreach ($path in @($script:router,$runner,$runnerBoundaryPath,$PSCommandPath)) {
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
$releaseModelJob = [regex]::Match($workflow,'(?ms)^  release-model:\s*$.*?(?=^  release-host:\s*$)').Value
$releaseHostJob = [regex]::Match($workflow,'(?ms)^  release-host:\s*$.*?(?=^  release-full:\s*$)').Value
$releaseJob = [regex]::Match($workflow,'(?ms)^  release-full:\s*$.*\z').Value
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
Check ($workflow -match '(?m)^\s*pr-core:\s*$' -and $workflow -match '(?m)^\s*changed-optional:\s*$' -and $workflow -match '(?m)^\s*release-model:\s*$' -and $workflow -match '(?m)^\s*release-host:\s*$' -and $workflow -match '(?m)^\s*release-full:\s*$') 'CI declares PR core, changed optional, split release producers, and release full jobs' 'CI job layering is incomplete'
Check (@([regex]::Matches($workflow,[regex]::Escape($checkoutAction))).Count -eq 5 -and @([regex]::Matches($workflow,[regex]::Escape($uploadAction))).Count -eq 3 -and @([regex]::Matches($workflow,[regex]::Escape($downloadAction))).Count -eq 2 -and $workflow -notmatch 'actions/(?:checkout|upload-artifact|download-artifact)@v\d+') 'every GitHub Action dependency is pinned to a verified full commit SHA' 'GitHub Action dependencies are movable or not pinned to the approved commits'
Check ($workflow -match 'run-validation\.ps1 -Suite core' -and $workflow -match 'run-changed-optional-validation\.ps1' -and $rolloutGenerator -match 'run-validation\.ps1 -Suite all') 'each CI layer delegates to the expected validation entry' 'CI layer commands are wrong'
Check ($workflow -match 'run-isolated-install-smoke\.ps1[^\r\n]+-Preset core' -and $workflow -match 'generate-v2-rollout-report\.ps1' -and $rolloutGenerator -match 'run-isolated-install-smoke\.ps1 -Preset core' -and $rolloutGenerator -match 'run-isolated-install-smoke\.ps1 -Preset full') 'PR and release jobs cover core/full install rollback' 'CI install rollback coverage is incomplete'
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
Check ($releaseModelJob -match '(?m)^\s*timeout-minutes:\s*120\s*$' -and $releaseHostJob -match '(?m)^\s*timeout-minutes:\s*180\s*$' -and $releaseJob -match '(?m)^\s*timeout-minutes:\s*120\s*$' -and @($releaseModelJob,$releaseHostJob,$releaseJob | Where-Object { $_ -match '(?m)^\s*fetch-depth:\s*0\s*$' }).Count -eq 3) 'release producers and aggregator use full checkout with bounded 120/180/120-minute budgets' 'release checkout depth or timeout budgets are wrong'
Check ($releaseModelJob -notmatch '(?m)^\s*continue-on-error:' -and $releaseModelJob -match 'run-model-evals\.ps1[^\r\n]+-TimeoutSeconds 120[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+model-eval\.json' -and $releaseModelJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\model' -and $releaseModelJob -match 'Model evidence directory already exists') 'release model producer bounds real sessions and refuses stale evidence directories' 'release model producer contract is incomplete'
Check ($releaseHostJob -notmatch '(?m)^\s*continue-on-error:' -and $releaseHostJob -match '(?m)^\s*needs:\s*release-model\s*$' -and $releaseHostJob -match 'run-host-benchmark\.ps1[^\r\n]+-TimeoutSeconds 900[^\r\n]+-CodexHome \$env:HOST_BENCHMARK_CODEX_HOME[^\r\n]+-Groups 3[^\r\n]+-Trials 3[^\r\n]+host-benchmark\.json' -and $releaseHostJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\host' -and $releaseHostJob -match 'Host evidence directory already exists') 'release host producer runs three independent 3x3 groups after model and refuses stale directories' 'release host producer contract is incomplete'
Check ($releaseJob -match '!cancelled\(\)' -and $releaseJob -notmatch 'always\(\)' -and $releaseJob -match '(?ms)^\s*needs:\s*\r?\n\s*- release-model\s*\r?\n\s*- release-host' -and @([regex]::Matches($releaseJob,[regex]::Escape($downloadAction))).Count -eq 2 -and $releaseJob -match 'generate-v2-rollout-report\.ps1[^\r\n]+-ModelEvalReportPath[^\r\n]+model-eval\.json[^\r\n]+-HostBenchmarkReportPath[^\r\n]+host-benchmark\.json[^\r\n]+v2-rollout-eligibility\.json[^\r\n]+-RequireEligible' -and $releaseJob -match 'GITHUB_RUN_ID-\$env:GITHUB_RUN_ATTEMPT\\aggregate') 'release aggregator runs after failed producers unless cancelled and consumes a fresh fixed evidence directory' 'release aggregator can resist cancellation, reuse stale evidence, or emit a non-eligible successful release'
Check ($modelUpload -match [regex]::Escape($uploadAction) -and $modelUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and @([regex]::Matches($modelUpload,'(?m)^\s+path:\s*\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/model-eval\.json\s*$')).Count -eq 1 -and $hostUpload -match [regex]::Escape($uploadAction) -and $hostUpload -match '(?m)^\s*if-no-files-found:\s*error\s*$' -and @([regex]::Matches($hostUpload,'(?m)^\s+path:\s*\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/host-benchmark\.json\s*$')).Count -eq 1) 'release producers upload exactly one fresh evidence JSON or fail' 'release producer artifact scope is wrong'
Check ($releaseUpload -match '!cancelled\(\)' -and $releaseUpload -match [regex]::Escape($uploadAction) -and $releaseUpload -match '(?m)^\s*if-no-files-found:\s*warn\s*$' -and @([regex]::Matches($releaseUpload,'(?m)^\s+\$\{\{ env\.RELEASE_EVIDENCE_ROOT \}\}/[a-z0-9-]+\.json\s*$')).Count -eq 3 -and ($modelUpload + $hostUpload + $releaseUpload) -notmatch '(?i)auth\.json|CODEX_ACCESS_TOKEN|OPENAI_API_KEY|secrets\.') 'final artifact scope is limited to three fresh sanitized JSON paths without credential transport' 'release artifact scope or credential boundary is unsafe'
Check ($rolloutGenerator -match 'ModelEvalReportPath' -and $rolloutGenerator -match 'HostBenchmarkReportPath' -and $rolloutGenerator -match 'run-validation\.ps1 -Suite all' -and $rolloutGenerator -notmatch 'run-scenario-evals\.ps1 -Suite core' -and $rolloutGenerator -notmatch 'benchmark-harness\.ps1 -Compare bare,v1,v2') 'rollout eligibility consumes real reports while deterministic eval and fixture replay remain non-release evidence' 'rollout eligibility still substitutes deterministic or fixture evidence for real qualification'

$validation = Get-Content -LiteralPath $validationPath -Raw -Encoding utf8
$coreBlock = [regex]::Match($validation,'(?s)\$coreScripts\s*=\s*@\((?<body>.*?)\r?\n\)').Groups['body'].Value
$optionalNames = @('verify-ask-codex.ps1','verify-codex-entry-autoload.ps1','verify-code-intel-provider-boundary.ps1','verify-context-provider-boundary.ps1','verify-context-provider-install-isolation.ps1','verify-memory-provider-boundary.ps1','verify-md-html-review-renderer.ps1','verify-provider-usage-recording.ps1','verify-render-review-html.ps1','verify-aiteamcode-skill-contract.ps1')
Check ($coreBlock -match 'run-scenario-evals\.ps1' -and $coreBlock -match 'verify-v2-ci-routing\.ps1') 'core suite includes behavior and CI routing gates' 'core suite omits PR-13 gates'
Check (@($optionalNames | Where-Object { $coreBlock -match [regex]::Escape($_) }).Count -eq 0) 'core suite excludes changed-path optional modules' 'core suite still runs optional heavy modules unconditionally'

$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding utf8
$scenarioDoc = Get-Content -LiteralPath $scenarioDocPath -Raw -Encoding utf8
Check ($readme -match 'PR core' -and $readme -match 'changed optional' -and $readme -match 'release full') 'README documents layered validation behavior' 'README CI documentation is stale'
Check ($readme -match 'PowerShell 7\.3\+' -and $readme -match 'Codex CLI/service `0\.144\.4`' -and $readme -match 'model/host/聚合 job 上限分别为 120/180/120 分钟') 'README documents exact release-runner prerequisites and split budgets' 'README release-runner prerequisites or split budgets are incomplete'
Check ($readme -match 'THIN_V2_RELEASE_RUNNER.*repository/org-level variable.*environment-level variable' -and $readme -match 'THIN_V2_RELEASE_AGGREGATOR_RUNNER.*repository/org-level variable') 'README keeps both runs-on selectors at repository/org scope instead of the later job environment scope' 'README does not document the GitHub Actions runner-selector variable scopes'
Check ($scenarioDoc -match '(?s)run-host-benchmark\.ps1.*?-Groups 3.*?-Trials 3.*?host-benchmark\.json') 'scenario eval guide invokes three independent host groups instead of a flat trial count' 'scenario eval guide omits the release host group count'

foreach($item in $script:checks){Write-Output "[PASS] $item"}
foreach($item in $script:failures){Write-Output "[FAIL] $item"}
if($script:failures.Count){Write-Output "STATUS: FAIL ($($script:failures.Count) failed)";exit 1}
Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
exit 0
