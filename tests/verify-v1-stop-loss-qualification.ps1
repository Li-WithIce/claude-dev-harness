[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

# TK-03 active contract: historical G14 data remains readable, but current
# Runtime must never restore the retired v1 route/lifecycle. The original
# producer/lifecycle verifier below is retained verbatim and is not executed.
$retirementChecks = 0
function Assert-Retirement([bool]$Condition,[string]$Label) {
    if (-not $Condition) { throw "TK-03 stop-loss retirement check failed: $Label" }
    $script:retirementChecks++
    Write-Output "[PASS] $Label"
}
function Complete-RetirementProcess($Handle) {
    try {
        if (-not $Handle.Process.WaitForExit(30000)) { $Handle.Process.Kill($true); throw 'retirement fixture process timed out' }
        return [ordered]@{code=$Handle.Process.ExitCode;output=$Handle.StdOut.GetAwaiter().GetResult().Trim();error=$Handle.StdErr.GetAwaiter().GetResult().Trim()}
    } finally { $Handle.Process.Dispose() }
}
function Invoke-RetirementTask([string[]]$Arguments) {
    return Complete-RetirementProcess (Start-RepoProcess -UserProfile $retirementProfile -WorkingDirectory $retirementWorkspace -ScriptPath (Join-Path $RepoRoot 'scripts/task.ps1') -Arguments ($Arguments + @('-RepoRoot',$RepoRoot,'-WorkspaceRoot',$retirementWorkspace,'-AsJson')))
}
function Get-RetirementSnapshot {
    return (@(Get-ChildItem -LiteralPath $retirementWorkspace -Force -Recurse | ForEach-Object {
        $value=if($_.PSIsContainer){'directory'}else{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
        [IO.Path]::GetRelativePath($retirementWorkspace,$_.FullName)+'|'+$value
    } | Sort-Object) -join "`n")
}
$retirementParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
$retirementName='tk03-stop-loss-retirement-'+[guid]::NewGuid().ToString('N')
$retirementRoot=Join-Path $retirementParent $retirementName
$retirementWorkspace=Join-Path $retirementRoot 'workspace'
$retirementProfile=Join-Path $retirementRoot 'profile'
$retirementProtocol=$env:HARNESS_PROTOCOL
try {
    [void][IO.Directory]::CreateDirectory($retirementWorkspace)
    [void][IO.Directory]::CreateDirectory($retirementProfile)
    $compatSchema=Get-Content -LiteralPath (Join-Path $RepoRoot 'schemas/v1-stop-loss-report.schema.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $fixedObjects=@($compatSchema,$compatSchema.properties.source,$compatSchema.properties.source.properties.input_digests,$compatSchema.properties.execution,$compatSchema.properties.lifecycle,$compatSchema.properties.results,$compatSchema.definitions.sourceState,$compatSchema.definitions.routeProbe)
    Assert-Retirement ([string]$compatSchema['$schema'] -ceq 'http://json-schema.org/draft-07/schema#' -and @($fixedObjects | Where-Object {$_.additionalProperties -ne $false}).Count -eq 0) 'historical G14 Schema remains strict Draft 7'
    Assert-Retirement (@($compatSchema.definitions.nullableDigest.oneOf).Count -eq 2 -and [string]$compatSchema.definitions.nullableDigest.oneOf[0]['$ref'] -ceq '#/definitions/digest' -and [string]$compatSchema.definitions.nullableDigest.oneOf[1].type -ceq 'null') 'historical nullableDigest remains exactly digest-or-null'
    $nullableSchema=[ordered]@{'$schema'='http://json-schema.org/draft-07/schema#';definitions=$compatSchema.definitions;'$ref'='#/definitions/nullableDigest'} | ConvertTo-Json -Depth 100 -Compress
    foreach($scalar in @('null',('"sha256:'+('0'*64)+'"'))) {
        Assert-Retirement (Test-Json -Json $scalar -Schema $nullableSchema -ErrorAction Stop) 'historical null and SHA-256 scalar bytes remain accepted'
    }
    Assert-Retirement (-not (Test-Json -Json '"not-a-digest"' -Schema $nullableSchema -ErrorAction SilentlyContinue)) 'historical nullableDigest still rejects arbitrary strings'
    $compatModule=Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.RolloutEvidence.psm1') -Force -PassThru
    $expected=[ordered]@{probe='existing-v1-artifact';requested_protocol='v2';detected_protocol='v1';selected_protocol='v1';preference_source='existing-artifact';reason_code='existing-v1-plan';expected_write_kind='none';existing_artifact=$true}
    $digest='sha256:'+('0'*64)
    $probe=[ordered]@{probe='existing-v1-artifact';status='pass';exit_code=0L;requested_protocol='v2';detected_protocol='v1';selected_protocol='v1';preference_source='existing-artifact';reason_code='existing-v1-plan';expected_write_kind='none';unexpected_writes=0L;artifact_digest_before=$digest;artifact_digest_after=$digest;command_digest=$digest;output_digest=$digest}
    & $compatModule {param($P,$E) Assert-V1StopLossRouteProbe -Probe $P -Expected $E} $probe $expected
    Assert-Retirement $true 'historical portable probe reader still interprets its v1 contract as historical v1'
    foreach($field in @('artifact_digest_before','artifact_digest_after')) {
        $probe[$field]='not-a-digest';$rejected=$false
        try { & $compatModule {param($P,$E) Assert-V1StopLossRouteProbe -Probe $P -Expected $E} $probe $expected } catch { $rejected=$true }
        $probe[$field]=$digest
        Assert-Retirement $rejected "portable historical reader rejects invalid $field"
    }
    $probe.selected_protocol='v2';$rejected=$false
    try { & $compatModule {param($P,$E) Assert-V1StopLossRouteProbe -Probe $P -Expected $E} $probe $expected } catch { $rejected=$true }
    Assert-Retirement $rejected 'historical v1 probe is not silently reinterpreted as a v2 pass'

    $env:HARNESS_PROTOCOL='v1';$before=Get-RetirementSnapshot
    $retired=Invoke-RetirementTask @('protocol')
    Assert-Retirement ($retired.code -eq 2 -and $retired.error -match 'v1-protocol-retired' -and (Get-RetirementSnapshot) -ceq $before) 'current explicit v1 new-task route rejects without writes'
    $env:HARNESS_PROTOCOL='auto'
    $current=Invoke-RetirementTask @('protocol')
    Assert-Retirement ($current.code -eq 0 -and ($current.output|ConvertFrom-Json).selected_protocol -ceq 'v2' -and (Get-RetirementSnapshot) -ceq $before) 'current auto selects v2 without creating a task or mirror'
    $paused=Invoke-RetirementTask @('disable-v2')
    Assert-Retirement ($paused.code -eq 0) 'disable-v2 pauses new work successfully'
    $configPath=Join-Path $retirementWorkspace '.assistant/config/protocol.json'
    $configText=Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    $config=$configText|ConvertFrom-Json
    $pausePaths=@(Get-ChildItem -LiteralPath $retirementWorkspace -Recurse -Force | ForEach-Object {[IO.Path]::GetRelativePath($retirementWorkspace,$_.FullName).Replace('\','/')} | Sort-Object)
    Assert-Retirement ($config.new_work -ceq 'paused' -and (Test-Json -Json $configText -SchemaFile (Join-Path $RepoRoot 'schemas/protocol-config-v2.schema.json')) -and ($pausePaths -join "`n") -ceq (@('.assistant','.assistant/config','.assistant/config/protocol.json') -join "`n")) 'stop-loss writes only v2 pause config, not a v1 fallback or runtime mirror'
    $before=Get-RetirementSnapshot;$env:HARNESS_PROTOCOL='v2'
    $blocked=Invoke-RetirementTask @('create','-TaskId','blocked-stop-loss','-Contract','absent.json')
    Assert-Retirement ($blocked.code -ne 0 -and $blocked.error -match 'new-work-not-admitted' -and (Get-RetirementSnapshot) -ceq $before) 'explicit v2 cannot bypass pause and creates no new task'
    $plan=Join-Path $retirementWorkspace 'docs/tasks/retired-stop-loss/plan.md'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($plan))
    [IO.File]::WriteAllText($plan,'locked historical plan sentinel',[Text.UTF8Encoding]::new($false))
    $before=Get-RetirementSnapshot
    $lock=[IO.File]::Open($plan,'Open','ReadWrite','None')
    try {
        $legacy=Invoke-RetirementTask @('protocol','-TaskId','retired-stop-loss')
        Assert-Retirement ($legacy.code -eq 2 -and $legacy.error -match 'legacy-task-requires-explicit-migration') 'existing locked v1 history requests explicit migration without being read'
        $stage=Complete-RetirementProcess (Start-RepoProcess -UserProfile $retirementProfile -WorkingDirectory $retirementWorkspace -ScriptPath (Join-Path $RepoRoot 'scripts/advance-stage.ps1') -Arguments @('-RepoRoot',$RepoRoot,'-WorkspaceRoot',$retirementWorkspace,'-TaskId','retired-stop-loss','-ExpectedStage','PLAN'))
        Assert-Retirement ($stage.code -eq 2 -and $stage.error -match 'v1-lifecycle-retired') 'the first retired lifecycle transition rejects before reading the locked plan'
    } finally { $lock.Dispose() }
    Assert-Retirement ((Get-RetirementSnapshot) -ceq $before) 'legacy route and lifecycle rejection preserve every fixture byte and directory'
    Write-Output "STATUS: PASS ($retirementChecks current retirement/historical compatibility checks; G14 producer and successful v1 lifecycle not_run)"
} finally {
    if($null -eq $retirementProtocol){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$retirementProtocol}
    Remove-Module Harness.RolloutEvidence -ErrorAction Ignore
    $contained=[IO.Path]::GetFullPath($retirementRoot)
    if(-not $contained.StartsWith($retirementParent+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($contained) -cne $retirementName){throw 'retirement fixture cleanup escaped its root'}
    if(Test-Path -LiteralPath $contained){Remove-Item -LiteralPath $contained -Recurse -Force}
}
exit 0

# Retained historical implementation below. Successful v1 qualification is
# not part of TK-03 active validation; full report/digest compatibility remains
# covered independently by verify-rollout-evidence.ps1.
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
    Check (@($schema.definitions.nullableDigest.oneOf).Count -eq 2 -and [string]$schema.definitions.nullableDigest.oneOf[0]['$ref'] -ceq '#/definitions/digest' -and [string]$schema.definitions.nullableDigest.oneOf[1].type -ceq 'null') 'nullableDigest is exactly digest-or-null' 'nullableDigest still accepts unconstrained strings'

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
    Check ($null -eq $document.route_probes[0].artifact_digest_before -and [string]$document.lifecycle.plan_digest_before -match '^sha256:[0-9a-f]{64}$') 'valid null and sha256 nullable digests continue to pass the Schema and Adapter' 'valid nullable digest forms regressed'
    $nullableCases = @(
        [ordered]@{name='lifecycle.plan_digest_before';apply={param($d)$d.lifecycle.plan_digest_before='not-a-digest'}},
        [ordered]@{name='lifecycle.plan_digest_after';apply={param($d)$d.lifecycle.plan_digest_after='not-a-digest'}},
        [ordered]@{name='lifecycle.test_report_digest';apply={param($d)$d.lifecycle.test_report_digest='not-a-digest'}},
        [ordered]@{name='route.artifact_digest_before';apply={param($d)$d.route_probes[2].artifact_digest_before='not-a-digest'}},
        [ordered]@{name='route.artifact_digest_after';apply={param($d)$d.route_probes[2].artifact_digest_after='not-a-digest'}}
    )
    foreach ($case in $nullableCases) {
        $invalid = ($document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        & $case.apply $invalid
        $invalid.report_digest = $null
        $invalid.report_digest = Get-TextDigest ($invalid | ConvertTo-Json -Depth 100 -Compress)
        $invalidJson = $invalid | ConvertTo-Json -Depth 100 -Compress
        $schemaRejected = -not (Test-Json -Json $invalidJson -SchemaFile $schemaPath -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
        $adapterRejected = $false
        try {
            $invalidDocument = & $module { param($Value) ConvertFrom-V1StopLossEvidenceBytes -Bytes $Value } ([Text.UTF8Encoding]::new($false).GetBytes($invalidJson))
            [void](& $module { param($Root,$Value) Assert-V1StopLossReport -RepoRoot $Root -Document $Value -AllowNonFormalSource } $RepoRoot $invalidDocument)
        } catch { $adapterRejected = $true }
        Check ($schemaRejected -and $adapterRejected) "$($case.name) rejects not-a-digest in both Schema and Adapter" "$($case.name) accepted not-a-digest"
    }

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
