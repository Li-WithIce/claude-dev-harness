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
$readmePath = Join-Path $RepoRoot 'README.md'

foreach ($path in @($script:router,$runner,$PSCommandPath)) {
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
Check ($workflow -match '(?m)^\s*schedule:\s*$' -and $workflow -match '(?m)^\s*workflow_dispatch:\s*$') 'CI exposes nightly and manual release validation' 'CI lacks nightly or manual release validation'
Check ($workflow -match '(?m)^\s*pr-core:\s*$' -and $workflow -match '(?m)^\s*changed-optional:\s*$' -and $workflow -match '(?m)^\s*release-full:\s*$') 'CI declares PR core, changed optional, and release full jobs' 'CI job layering is incomplete'
Check ($workflow -match 'run-validation\.ps1 -Suite core' -and $workflow -match 'run-changed-optional-validation\.ps1' -and $workflow -match 'run-validation\.ps1 -Suite all') 'each CI layer delegates to the expected validation entry' 'CI layer commands are wrong'
Check ($workflow -match 'run-isolated-install-smoke\.ps1[^\r\n]+-Preset core' -and $workflow -match 'generate-v2-rollout-report\.ps1' -and $rolloutGenerator -match 'run-isolated-install-smoke\.ps1 -Preset core' -and $rolloutGenerator -match 'run-isolated-install-smoke\.ps1 -Preset full') 'PR and release jobs cover core/full install rollback' 'CI install rollback coverage is incomplete'
Check ($rolloutGenerator -match 'run-scenario-evals\.ps1 -Suite core' -and $rolloutGenerator -match 'benchmark-harness\.ps1 -Compare bare,v1,v2') 'release report runs behavior and performance gates' 'release report omits behavior or performance gates'

$validation = Get-Content -LiteralPath $validationPath -Raw -Encoding utf8
$coreBlock = [regex]::Match($validation,'(?s)\$coreScripts\s*=\s*@\((?<body>.*?)\r?\n\)').Groups['body'].Value
$optionalNames = @('verify-ask-codex.ps1','verify-codex-entry-autoload.ps1','verify-code-intel-provider-boundary.ps1','verify-context-provider-boundary.ps1','verify-context-provider-install-isolation.ps1','verify-memory-provider-boundary.ps1','verify-md-html-review-renderer.ps1','verify-provider-usage-recording.ps1','verify-render-review-html.ps1','verify-aiteamcode-skill-contract.ps1')
Check ($coreBlock -match 'run-scenario-evals\.ps1' -and $coreBlock -match 'verify-v2-ci-routing\.ps1') 'core suite includes behavior and CI routing gates' 'core suite omits PR-13 gates'
Check (@($optionalNames | Where-Object { $coreBlock -match [regex]::Escape($_) }).Count -eq 0) 'core suite excludes changed-path optional modules' 'core suite still runs optional heavy modules unconditionally'

$readme = Get-Content -LiteralPath $readmePath -Raw -Encoding utf8
Check ($readme -match 'PR core' -and $readme -match 'changed optional' -and $readme -match 'release full') 'README documents layered validation behavior' 'README CI documentation is stale'

foreach($item in $script:checks){Write-Output "[PASS] $item"}
foreach($item in $script:failures){Write-Output "[FAIL] $item"}
if($script:failures.Count){Write-Output "STATUS: FAIL ($($script:failures.Count) failed)";exit 1}
Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
exit 0
