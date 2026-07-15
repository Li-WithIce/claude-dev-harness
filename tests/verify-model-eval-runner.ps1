[CmdletBinding()]
param([string]$RepoRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path $RepoRoot).Path
$failures = [Collections.Generic.List[string]]::new(); $checks = 0
function Check([bool]$Condition,[string]$Message) { if($Condition){$script:checks++}else{$script:failures.Add($Message)} }

$runner = Join-Path $RepoRoot 'scripts\run-model-evals.ps1'
$module = Join-Path $RepoRoot 'scripts\lib\Harness.ModelEval.psm1'
$wrapper = Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
$schema = Join-Path $RepoRoot 'schemas\model-eval-observation.schema.json'
$datasetPath = Join-Path $RepoRoot 'tests\evals\core-scenarios.json'
foreach($path in @($runner,$module,$wrapper,$schema,$datasetPath)) { Check (Test-Path $path -PathType Leaf) "missing model-eval contract: $path" }
foreach($path in @($runner,$module,$wrapper)) {
    $tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
    Check ($errors.Count -eq 0) "PowerShell parse failed: $path"
}
$dataset = Get-Content $datasetPath -Raw -Encoding utf8 | ConvertFrom-Json
Check ([string]$dataset.schema_version -ceq 'harness-scenario-evals/v1') 'scenario schema changed'
Check (@($dataset.cases).Count -eq 20) 'model eval must keep 20 semantic cases'
Check (@($dataset.cases.paraphrases).Count -eq 40) 'model eval must keep 40 paraphrases'
Check (@($dataset.cases | Where-Object {[string]::IsNullOrWhiteSpace($_.model_context)}).Count -eq 0) 'every model case needs non-answer context'
$valid='{"schema_version":"harness-model-observation/v1","action":"inspect","ask_required":false,"profile":"inspect","write_authorized":false,"completion_allowed":false,"verification_status":"pending","selected_protocol":"none","required_capabilities":[],"lifecycle_skills_loaded":0,"unauthorized_scope_change":false,"reason_code":"read-only-inspection"}'
Check (Test-Json -Json $valid -SchemaFile $schema -ErrorAction Stop -WarningAction SilentlyContinue) 'valid model observation rejected'
$invalid=$valid -replace '"unauthorized_scope_change":false,',''
Check (-not (Test-Json -Json $invalid -SchemaFile $schema -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) 'missing model observation field accepted'
$runnerText=Get-Content $runner -Raw -Encoding utf8; $moduleText=Get-Content $module -Raw -Encoding utf8; $wrapperText=Get-Content $wrapper -Raw -Encoding utf8
Check ($runnerText -match "gpt-5\.6-sol" -and $runnerText -match "ValidateSet\('max'\)" -and $moduleText -match '-Ephemeral' -and $moduleText -match '-ReadOnly' -and $moduleText -match '-Isolated') 'release identity/isolation contract missing'
Check ($moduleText -match 'Read-only intent always uses profile=inspect') 'model rules must preserve the read-only Inspect override'
Check ($runnerText -match 'prompt_persisted=\$false' -and $runnerText -match 'raw_command_persisted=\$false' -and $runnerText -match 'thread_id_persisted=\$false') 'sanitized report declarations missing'
Check ($wrapperText -match 'codex-invocation-telemetry/v1' -and $wrapperText -match 'model_reasoning_effort' -and $wrapperText -match 'OutputSchema') 'wrapper telemetry/structured output contract missing'
$output=@(& pwsh -NoLogo -NoProfile -File $runner -RepoRoot $RepoRoot -ValidateOnly 2>&1 | ForEach-Object {[string]$_}); $exit=$LASTEXITCODE
Check ($exit -eq 0 -and ($output -join "`n") -match 'definition only; no model session executed') 'definition-only runner validation failed or claimed a model run'
Write-Output "Model eval runner checks: $checks"
if($failures.Count){$failures|ForEach-Object{Write-Output "- FAIL: $_"};exit 1}
Write-Output "STATUS: PASS ($checks checks)"
