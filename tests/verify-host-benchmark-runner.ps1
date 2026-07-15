[CmdletBinding()]
param([string]$RepoRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$failures=[Collections.Generic.List[string]]::new();$checks=0
function Check([bool]$Condition,[string]$Message){if($Condition){$script:checks++}else{$script:failures.Add($Message)}}
$runner=Join-Path $RepoRoot 'scripts\run-host-benchmark.ps1'
$schema=Join-Path $RepoRoot 'schemas\host-benchmark-observation.schema.json'
$wrapper=Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
foreach($path in @($runner,$schema,$wrapper)){Check (Test-Path -LiteralPath $path -PathType Leaf) "missing host benchmark contract: $path"}
foreach($path in @($runner,$PSCommandPath)){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null;Check (@($errors).Count-eq0) "PowerShell parse failed: $path"}
$valid='{"schema_version":"host-benchmark-observation/v1","outcome":"completed","task_completed":true,"verification_executed":true,"verification_passed":true,"reason_code":"completed"}'
Check (Test-Json -Json $valid -SchemaFile $schema -ErrorAction Stop -WarningAction SilentlyContinue) 'valid host observation rejected'
$invalid=$valid -replace ',"verification_passed":true',''
Check (-not(Test-Json -Json $invalid -SchemaFile $schema -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) 'missing host observation field accepted'
$text=Get-Content -LiteralPath $runner -Raw -Encoding utf8
$wrapperText=Get-Content -LiteralPath $wrapper -Raw -Encoding utf8
Check ($text-match"gpt-5\.6-sol"-and$text-match"ValidateSet\('max'\)"-and$text-match'-Ephemeral'-and$text-match'-Isolated'-and$text-match'-Sandbox danger-full-access'-and$text-match'-ApprovalPolicy never') 'release model/max/fresh isolation contract missing'
Check ($text-match"@\('bare','v1','v2'\)"-and$text-match'HARNESS_PROTOCOL = \$Protocol'-and$text-match'fresh_ephemeral_session_per_invocation=\$true') 'bare/v1/v2 fresh-session comparison contract missing'
Check ($text-match'install_duration_included=\$false'-and$text-match'total_duration_ms'-and$text-match'first_useful_action_ms'-and$text-match'model_roundtrips'-and$text-match'loaded_files'-and$text-match'artifact_writes'-and$text-match'runtime_writes'-and$text-match'tokens') 'required host metrics or latency boundary missing'
Check ($text-match'ratio-le1\.25'-and$text-match'reduction-ge0\.60'-and$text-match"status='unavailable'"-and$text-match'not \$dirty') 'measured performance thresholds or fail-closed source rule missing'
Check ($text-match'prompt_persisted=\$false'-and$text-match'raw_command_persisted=\$false'-and$text-match'thread_id_persisted=\$false'-and$text-match'report_digest') 'sanitized source-bound report contract missing'
Check ($text-match'modelRoundTrips \+= \[int\]\$telemetry\.agent_messages'-and$text-match"model_roundtrip_basis = 'completed-agent-message-events'"-and$text-match'model_roundtrip_limit') 'host-visible model roundtrip measurement basis or limitation missing'
Check ($text-match"savedEnvironment\['USERPROFILE'\]"-and$text-match"diagnostic = 'wrapper-exit-'"-and$wrapperText-match'--ignore-user-config') 'installer isolation and authenticated model-host boundary missing'
Check ($text-match"\.assistant\\运行时\\release-qualification"-and$text-match'git -C \$workspace init --quiet'-and$text-match'workspace intentionally has no harness lifecycle'-and$text-match'Refusing to remove unsafe host benchmark scratch path') 'writable-root isolated workspace, bare boundary, and safe cleanup contract missing'
$output=@(& pwsh -NoLogo -NoProfile -NonInteractive -File $runner -RepoRoot $RepoRoot -ValidateOnly 2>&1|ForEach-Object{[string]$_});$exit=$LASTEXITCODE
Check ($exit-eq0-and($output-join"`n")-match'definition only; no model session executed') 'definition-only host runner failed or claimed a model run'
Write-Output "Host benchmark runner checks: $checks"
if($failures.Count){$failures|ForEach-Object{Write-Output "- FAIL: $_"};exit 1}
Write-Output "STATUS: PASS ($checks checks)"
