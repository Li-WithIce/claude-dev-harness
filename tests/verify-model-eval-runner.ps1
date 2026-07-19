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
$credentialGuard = Join-Path $RepoRoot 'scripts\host-benchmark\HostBenchmark.Trial.ps1'
$schema = Join-Path $RepoRoot 'schemas\model-eval-observation.schema.json'
$datasetPath = Join-Path $RepoRoot 'tests\evals\core-scenarios.json'
foreach($path in @($runner,$module,$wrapper,$credentialGuard,$schema,$datasetPath)) { Check (Test-Path $path -PathType Leaf) "missing model-eval contract: $path" }
foreach($path in @($runner,$module,$wrapper)) {
    $tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
    Check ($errors.Count -eq 0) "PowerShell parse failed: $path"
}
$dataset = Get-Content $datasetPath -Raw -Encoding utf8 | ConvertFrom-Json
Check ([string]$dataset.schema_version -ceq 'harness-scenario-evals/v1') 'scenario schema changed'
Check (@($dataset.cases).Count -eq 20) 'model eval must keep 20 semantic cases'
Check (@($dataset.cases.paraphrases).Count -eq 40) 'model eval must keep 40 paraphrases'
Check (@($dataset.cases | Where-Object {[string]::IsNullOrWhiteSpace($_.model_context)}).Count -eq 0) 'every model case needs non-answer context'
$valid='{"schema_version":"harness-model-observation/v1","action":"inspect","ask_required":false,"profile":"inspect","write_authorized_now":false,"completion_allowed":false,"verification_status":"pending","selected_protocol":"none","required_capabilities":[],"lifecycle_skills_loaded":0,"unauthorized_scope_change":false,"reason_code":"read-only-inspection"}'
Check (Test-Json -Json $valid -SchemaFile $schema -ErrorAction Stop -WarningAction SilentlyContinue) 'valid model observation rejected'
$invalid=$valid -replace '"unauthorized_scope_change":false,',''
Check (-not (Test-Json -Json $invalid -SchemaFile $schema -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) 'missing model observation field accepted'
$runnerText=Get-Content $runner -Raw -Encoding utf8; $moduleText=Get-Content $module -Raw -Encoding utf8; $wrapperText=Get-Content $wrapper -Raw -Encoding utf8
Check ($runnerText -match "gpt-5\.6-sol" -and $runnerText -match "ValidateSet\('max'\)" -and $moduleText -match '-Ephemeral' -and $moduleText -match '-ReadOnly' -and $moduleText -match '-Isolated') 'release identity/isolation contract missing'
Check ($runnerText -match "expectedCodexVersion\s*=\s*'0\.144\.4'" -and $runnerText -match 'harness-model-eval-report/v2' -and $runnerText -match 'expected_codex_cli_version=\$expectedCodexVersion' -and $moduleText -match '-ExpectedCodexVersion \$ExpectedCodexVersion') 'release model eval is not bound to Codex CLI 0.144.4'
Check ($runnerText -match '\[string\]\$CodexHome' -and $runnerText -match 'Real model eval requires an explicit dedicated -CodexHome' -and $runnerText -match 'Assert-HostCodexHome' -and $runnerText -match 'HostBenchmark\.Trial\.ps1') 'dedicated logged-in Codex home guard is missing'
Check ($runnerText -match 'Test-ModelEvalReportPath' -and $runnerText -match 'Model eval output must not overlap the dedicated Codex home' -and $runnerText -match 'Get-HostPhysicalPathInfo') 'model report path is not isolated from source and credential storage'
Check ($moduleText -match "'USERPROFILE','CODEX_HOME','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_API_KEY','CODEX_EXECUTABLE','CODEX_THREAD_ID','CODEX_INTERNAL_ORIGINATOR_OVERRIDE','CODEX_SHELL'" -and $moduleText -match 'SetEnvironmentVariable\(''CODEX_HOME'',\$CodexHome' -and $moduleText -match 'savedEnvironment\.GetEnumerator') 'per-session credential environment isolation/restore is missing'
Check ($moduleText -match 'Read-only intent always uses profile=inspect') 'model rules must preserve the read-only Inspect override'
Check ($runnerText -match 'prompt_persisted=\$false' -and $runnerText -match 'raw_command_persisted=\$false' -and $runnerText -match 'thread_id_persisted=\$false') 'sanitized report declarations missing'
Check ($moduleText -match '\$result\.observed\s*=\s*\$null' -and $moduleText -match '\$result\.telemetry\s*=\s*\$null' -and $runnerText -match '\$persistedObserved\s*=\s*if \(\$status -ceq ''pass''\)' -and $runnerText -match '\$persistedTelemetry\s*=\s*if \(\$status -ceq ''pass''\)') 'non-passing model sessions can retain observation or telemetry payloads'
Check ($runnerText -match 'source_state_stable' -and $runnerText -match 'input_head_binding' -and $runnerText -match 'credential_guard_digest' -and $runnerText -match 'report_digest=\$null' -and $moduleText -match "status','--porcelain=v1','--untracked-files=all" -and $moduleText -match "ls-files','-v'" -and $runnerText -match 'git-hash-object-equals-revision-blob/v1') 'clean source/head binding or report digest contract missing'
Check ($runnerText -match '\$hard = \$modelHard -and \$sourceStable -and -not \$sourceDirty') 'dirty or unstable source can still satisfy the model hard gate'
Check ($runnerText -match "codex_home='dedicated-config-isolated-auth-home-path-not-persisted'" -and $runnerText -notmatch 'codex_home=\$CodexHome') 'report may persist the dedicated Codex home path'
Check ($wrapperText -match 'codex-invocation-telemetry/v2' -and $wrapperText -match 'codex_cli_version' -and $wrapperText -match "ValidateSet\('0\.144\.4'\)" -and $wrapperText -match 'model_reasoning_effort' -and $wrapperText -match 'OutputSchema') 'version-bound wrapper telemetry/structured output contract missing'

Import-Module $module -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('model-eval-source-contract-' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    & git -C $fixture init --quiet; if($LASTEXITCODE -ne 0){throw 'fixture git init failed'}
    $tracked = Join-Path $fixture 'tracked.txt'
    [IO.File]::WriteAllText($tracked,'clean',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture '.gitignore'),"ignored/`n",[Text.UTF8Encoding]::new($false))
    & git -C $fixture add -- tracked.txt .gitignore; if($LASTEXITCODE -ne 0){throw 'fixture git add failed'}
    & git -C $fixture -c user.name='Model Eval Test' -c user.email='model-eval@test.invalid' commit --quiet -m baseline; if($LASTEXITCODE -ne 0){throw 'fixture git commit failed'}
    $clean = Get-ModelEvalGitState -Root $fixture
    Check (-not [bool]$clean.dirty -and [string]$clean.revision -match '^[0-9a-f]{40,64}$' -and [string]$clean.commit_tree_oid -match '^[0-9a-f]{40,64}$') 'clean source identity was not captured'
    Check (Test-ModelEvalGitFileMatchesRevision -Root $fixture -Path $tracked -Revision ([string]$clean.revision)) 'tracked input was not bound to its HEAD blob'
    Check (-not (Test-ModelEvalReportPath -Root $fixture -Path (Join-Path $fixture 'report.json')) -and (Test-ModelEvalReportPath -Root $fixture -Path (Join-Path $fixture 'ignored\report.json')) -and (Test-ModelEvalReportPath -Root $fixture -Path (Join-Path ([IO.Path]::GetTempPath()) 'outside-model-report.json'))) 'model report path did not reject a non-ignored source output while allowing ignored/external output'
    [IO.File]::WriteAllText($tracked,'changed',[Text.UTF8Encoding]::new($false))
    Check (-not (Test-ModelEvalGitFileMatchesRevision -Root $fixture -Path $tracked -Revision ([string]$clean.revision))) 'modified tracked input still matched its HEAD blob'
    [IO.File]::WriteAllText($tracked,'clean',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture 'untracked.txt'),'untracked',[Text.UTF8Encoding]::new($false))
    Check ([bool](Get-ModelEvalGitState -Root $fixture).dirty) 'untracked source input was not detected'
    [IO.File]::Delete((Join-Path $fixture 'untracked.txt'))
    & git -C $fixture update-index --assume-unchanged -- tracked.txt; if($LASTEXITCODE -ne 0){throw 'fixture index flag failed'}
    Check ([bool](Get-ModelEvalGitState -Root $fixture).dirty) 'Git index flag was not detected independently from porcelain status'
    & git -C $fixture update-index --no-assume-unchanged -- tracked.txt; if($LASTEXITCODE -ne 0){throw 'fixture index flag restore failed'}
} finally { if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force} }

$digestFixture = [ordered]@{schema_version='digest-test/v1';nested=[ordered]@{value=1};report_digest=$null}
$digest = Get-ModelEvalReportDigest -Document $digestFixture
$digestFixture.report_digest = $digest
Check ($digest -match '^sha256:[0-9a-f]{64}$' -and (Get-ModelEvalReportDigest -Document $digestFixture) -ceq $digest) 'report digest is not canonical with report_digest=null'
$output=@(& pwsh -NoLogo -NoProfile -File $runner -RepoRoot $RepoRoot -ValidateOnly 2>&1 | ForEach-Object {[string]$_}); $exit=$LASTEXITCODE
Check ($exit -eq 0 -and ($output -join "`n") -match 'definition only; no model session executed') 'definition-only runner validation failed or claimed a model run'
Write-Output "Model eval runner checks: $checks"
if($failures.Count){$failures|ForEach-Object{Write-Output "- FAIL: $_"};exit 1}
Write-Output "STATUS: PASS ($checks checks)"
