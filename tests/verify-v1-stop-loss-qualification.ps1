[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [Collections.Generic.List[string]]::new(); $script:failures = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Pass,[string]$Fail) { if ($Condition) { $script:checks.Add($Pass) } else { $script:failures.Add($Fail) } }
function Get-BytesDigest([byte[]]$Bytes) { return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-TextDigest([string]$Text) { return Get-BytesDigest ([Text.UTF8Encoding]::new($false).GetBytes($Text)) }
function Complete($Handle,[int]$TimeoutMilliseconds = 120000) {
    if (-not $Handle.Process.WaitForExit($TimeoutMilliseconds)) { $Handle.Process.Kill($true); throw 'v1 stop-loss verifier process timeout' }
    $result = [pscustomobject]@{ExitCode=$Handle.Process.ExitCode;StdOut=$Handle.StdOut.GetAwaiter().GetResult().Trim();StdErr=$Handle.StdErr.GetAwaiter().GetResult().Trim()}
    $Handle.Process.Dispose(); return $result
}

$producerPath = Join-Path $RepoRoot 'scripts\run-v1-stop-loss-qualification.ps1'
$modulePath = Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1'
$schemaPath = Join-Path $RepoRoot 'schemas\v1-stop-loss-report.schema.json'
$repoBefore = @(& git -C $RepoRoot -c core.quotepath=false status --porcelain=v1 --untracked-files=all)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('v1-stop-loss-verifier-' + [guid]::NewGuid().ToString('N'))
$outputPath = Join-Path $temp 'report.json'
try {
    [void][IO.Directory]::CreateDirectory($temp)
    foreach ($path in @($producerPath,$modulePath,$PSCommandPath)) {
        $tokens=$null; $errors=$null; [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        Check (@($errors).Count -eq 0) "$(Split-Path -Leaf $path) parses" "$(Split-Path -Leaf $path) has parse errors"
        Check (Test-FileHasUtf8Bom -Path $path) "$(Split-Path -Leaf $path) has UTF-8 BOM" "$(Split-Path -Leaf $path) lacks UTF-8 BOM"
    }
    $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100
    $strictObjects = @($schema,$schema.properties.source,$schema.properties.source.properties.input_digests,$schema.properties.execution,$schema.properties.lifecycle,$schema.properties.results,$schema.definitions.sourceState,$schema.definitions.routeProbe)
    Check ([string]$schema['$schema'] -ceq 'http://json-schema.org/draft-07/schema#' -and @($strictObjects | Where-Object { $_.additionalProperties -ne $false }).Count -eq 0) 'v1 stop-loss Schema is strict Draft 7 at every fixed object' 'v1 stop-loss Schema is not strict Draft 7'

    $run = Complete (Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $producerPath -Arguments @('-RepoRoot',$RepoRoot,'-OutputPath',$outputPath,'-ProducerMode','diagnostic-smoke'))
    Check ($run.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($run.StdErr) -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) 'diagnostic-smoke writes one report successfully' "diagnostic-smoke failed: $($run.StdErr)"
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw 'diagnostic-smoke did not create its report' }
    $bytes = [IO.File]::ReadAllBytes($outputPath)
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    $document = $text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    Check (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -and (Test-Json -Json $text -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) 'diagnostic report is BOM-less UTF-8 and passes the strict Schema' 'diagnostic report encoding or Schema is invalid'
    Check ([string]$document.producer_mode -ceq 'diagnostic-smoke' -and [string]$document.status -ceq 'unavailable' -and [string]$document.reason -ceq 'non-formal-producer-mode') 'diagnostic success remains unavailable and cannot claim formal pass' 'diagnostic success was promoted or misclassified'

    $expectedProbes = @('environment-v1-new-task','disable-v2-new-task','existing-v1-artifact','existing-v2-artifact')
    Check (@($document.route_probes).Count -eq 4 -and (@($document.route_probes.probe) -join '|') -ceq ($expectedProbes -join '|') -and @($document.route_probes | Where-Object { [string]$_.status -cne 'pass' -or [long]$_.exit_code -ne 0 -or [long]$_.unexpected_writes -ne 0 }).Count -eq 0) 'diagnostic-smoke completes the four ordered real Route Probes' 'one or more Route Probes failed, reordered, or wrote unexpectedly'
    Check ([string]$document.route_probes[0].requested_protocol -ceq 'v1' -and [string]$document.route_probes[0].detected_protocol -ceq 'new' -and [string]$document.route_probes[0].selected_protocol -ceq 'v1' -and [string]$document.route_probes[0].preference_source -ceq 'HARNESS_PROTOCOL') 'HARNESS_PROTOCOL=v1 selects v1 for a new task' 'environment v1 stop-loss did not select v1'
    Check ([string]$document.route_probes[1].expected_write_kind -ceq 'workspace-protocol-config' -and [string]$document.route_probes[1].detected_protocol -ceq 'new' -and [string]$document.route_probes[1].selected_protocol -ceq 'v1' -and [string]$document.route_probes[1].preference_source -ceq 'workspace-config') 'disable-v2 selects v1 with only the declared Workspace config write' 'disable-v2 stop-loss evidence is invalid'
    Check ([string]$document.route_probes[2].requested_protocol -ceq 'v2' -and [string]$document.route_probes[2].detected_protocol -ceq 'v1' -and [string]$document.route_probes[2].selected_protocol -ceq 'v1' -and [string]$document.route_probes[2].preference_source -ceq 'existing-artifact') 'Existing v1 remains v1 under explicit v2' 'explicit v2 overrode Existing v1'
    Check ([string]$document.route_probes[3].requested_protocol -ceq 'v1' -and [string]$document.route_probes[3].detected_protocol -ceq 'v2' -and [string]$document.route_probes[3].selected_protocol -ceq 'v2' -and [string]$document.route_probes[3].preference_source -ceq 'existing-artifact') 'Existing v2 remains v2 under explicit v1' 'explicit v1 downgraded Existing v2'
    Check ([string]$document.route_probes[2].artifact_digest_before -ceq [string]$document.route_probes[2].artifact_digest_after -and [string]$document.route_probes[3].artifact_digest_before -ceq [string]$document.route_probes[3].artifact_digest_after) 'protocol queries leave both Existing Artifacts byte-identical' 'protocol query migrated or changed an Existing Artifact'

    $expectedStages = @('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')
    Check ([string]$document.lifecycle.status -ceq 'pass' -and [string]$document.lifecycle.initial_stage -ceq 'PLAN' -and [string]$document.lifecycle.final_stage -ceq 'DONE' -and (@($document.lifecycle.stage_sequence) -join '|') -ceq ($expectedStages -join '|') -and [long]$document.lifecycle.transition_count -eq 5 -and [long]$document.lifecycle.unexpected_writes -eq 0) 'diagnostic-smoke completes the exact real v1 PLAN-to-DONE lifecycle' 'v1 lifecycle did not reach DONE in canonical order'
    Check (@($document.results.Keys | Where-Object { -not [bool]$document.results[$_] }).Count -eq 0) 'runtime default, Auth, unrelated config, cleanup, routing, and lifecycle results all hold' 'one or more stop-loss result assertions failed'
    Check ([string]$document.source.start.revision -ceq [string]$document.source.end.revision -and [string]$document.source.start.commit_tree_oid -ceq [string]$document.source.end.commit_tree_oid -and [string]$document.source.start.state_digest -ceq [string]$document.source.end.state_digest) 'Producer leaves the source revision, tree, and working state unchanged' 'Producer changed its source state'

    $savedDigest = [string]$document.report_digest; $document.report_digest = $null; $recomputed = Get-TextDigest ($document | ConvertTo-Json -Depth 100 -Compress); $document.report_digest = $savedDigest
    Check ($savedDigest -ceq $recomputed) 'report_digest recomputes from canonical BOM-less JSON' 'report_digest does not match the report'
    $forbidden = '(?:[A-Za-z]:[\\/]|\\\\|/(?:home|Users|private|tmp|var)(?:/|$)|(?i:access[_-]?token|refresh[_-]?token|api[_-]?key|bearer\s+|authorization\s*:|cookie\s*:|password\s*:|credential\s*:|raw[ _-]?(?:output|trace|log)\s*:|^#\s|^##\s))'
    Check ($text -notmatch $forbidden) 'report persists no private path, credential, raw output, Plan body, or Test body' 'report contains private, credential, raw, Plan, or Test content'
    $scratchPath = Join-Path ([IO.Path]::GetTempPath()) ("dev-harness-v1-stop-loss-{0}" -f $document.report_run_id)
    Check (-not (Test-Path -LiteralPath $scratchPath)) 'diagnostic scratch Workspace/Profile is removed' 'diagnostic scratch residue remains'

    $module = Import-Module $modulePath -Force -PassThru -ErrorAction Stop
    $validated = & $module { param($Bytes) ConvertFrom-V1StopLossEvidenceBytes -Bytes $Bytes } $bytes
    $derived = & $module { param($Root,$Document) Assert-V1StopLossReport -RepoRoot $Root -Document $Document -AllowNonFormalSource } $RepoRoot $validated
    Check ([string]$derived.status -ceq 'unavailable' -and [string]$derived.producer_identity -ceq 'v1-stop-loss-qualification/v1') 'portable validator reopens and derives non-formal authority from report content' 'portable validator did not derive the diagnostic report correctly'

    $existing = Complete (Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $producerPath -Arguments @('-RepoRoot',$RepoRoot,'-OutputPath',$outputPath,'-ProducerMode','diagnostic-smoke')) 30000
    Check ($existing.ExitCode -ne 0 -and $existing.StdErr -match 'release-output-already-exists') 'Producer refuses to overwrite an existing OutputPath before execution' 'Producer overwrote or accepted an existing OutputPath'
    $guardOutput = Join-Path $temp 'guard.json'
    $guard = Complete (Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $producerPath -Arguments @('-RepoRoot',$RepoRoot,'-OutputPath',$guardOutput,'-ProducerMode','diagnostic-smoke','-TestFailureProbe','lifecycle')) 30000
    Check ($guard.ExitCode -ne 0 -and $guard.StdErr -match 'TestFailureProbe requires ProducerMode test-only' -and -not (Test-Path -LiteralPath $guardOutput)) 'failure injection is restricted to test-only mode' 'diagnostic/formal mode accepted failure injection'
} finally {
    Remove-Module Harness.RolloutEvidence -ErrorAction Ignore
    Remove-DirectoryWithRetry -Path $temp
}

$repoAfter = @(& git -C $RepoRoot -c core.quotepath=false status --porcelain=v1 --untracked-files=all)
Check (@(Compare-Object $repoBefore $repoAfter).Count -eq 0) 'verifier and Producer perform no repository writes' 'verifier or Producer changed repository state'
foreach ($item in $script:checks) { Write-Output "[PASS] $item" }
foreach ($item in $script:failures) { Write-Output "[FAIL] $item" }
if ($script:failures.Count -gt 0) { Write-Output "STATUS: FAIL ($($script:failures.Count) failed)"; exit 1 }
Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
exit 0
