[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$script:checks = [Collections.Generic.List[string]]::new()
$script:failures = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Pass,[string]$Fail) { if ($Condition) { $script:checks.Add($Pass) } else { $script:failures.Add($Fail) } }
function Get-BytesDigest([byte[]]$Bytes) { return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-TextDigest([string]$Text) { return Get-BytesDigest ([Text.UTF8Encoding]::new($false).GetBytes($Text)) }
function Get-FileDigest([string]$Path) { return Get-BytesDigest ([IO.File]::ReadAllBytes($Path)) }
function Test-Utf8Bom([string]$Path) { $bytes=[IO.File]::ReadAllBytes($Path);return $bytes.Length-ge3-and$bytes[0]-eq0xEF-and$bytes[1]-eq0xBB-and$bytes[2]-eq0xBF }
function Get-FileSnapshot([string[]]$Paths) {
    $result=[ordered]@{}
    foreach($path in @($Paths|Sort-Object -Unique)){
        $full=[IO.Path]::GetFullPath($path)
        if(Test-Path -LiteralPath $full -PathType Leaf){$item=Get-Item -LiteralPath $full -Force;$result[$full]="file:$($item.Length):$(Get-FileDigest $full)"}
        elseif(Test-Path -LiteralPath $full){$result[$full]='non-file'}else{$result[$full]='missing'}
    }
    return $result
}
function Test-SnapshotEqual([Collections.IDictionary]$Left,[Collections.IDictionary]$Right) {
    if(@(Compare-Object @($Left.Keys|Sort-Object) @($Right.Keys|Sort-Object)).Count-ne0){return $false}
    foreach($key in $Left.Keys){if([string]$Left[$key]-cne[string]$Right[$key]){return $false}}
    return $true
}
function Test-ReportDigest([Collections.IDictionary]$Report) {
    $copy=($Report|ConvertTo-Json -Depth 100 -Compress)|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    $actual=[string]$copy.report_digest;$copy.report_digest=$null
    return $actual-ceq(Get-TextDigest ($copy|ConvertTo-Json -Depth 100 -Compress))
}
function Test-SourceSame([Collections.IDictionary]$Left,[Collections.IDictionary]$Right) {
    return [string]$Left.revision-ceq[string]$Right.revision-and[string]$Left.commit_tree_oid-ceq[string]$Right.commit_tree_oid-and[string]$Left.object_format-ceq[string]$Right.object_format-and[bool]$Left.dirty-eq[bool]$Right.dirty-and[long]$Left.status_entry_count-eq[long]$Right.status_entry_count-and[string]$Left.status_digest-ceq[string]$Right.status_digest-and[string]$Left.state_digest-ceq[string]$Right.state_digest
}

$producerPath=Join-Path $RepoRoot 'scripts\run-preset-lifecycle-qualification.ps1'
$modulePath=Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1'
$schemaPath=Join-Path $RepoRoot 'schemas\preset-lifecycle-report.schema.json'
$smokePath=Join-Path $RepoRoot 'scripts\run-isolated-install-smoke.ps1'
$powerShellPath=(Get-Process -Id $PID -ErrorAction Stop).Path
$module=Import-Module $modulePath -Force -PassThru -ErrorAction Stop

foreach($path in @($PSCommandPath,$producerPath,$modulePath)){
    Check (Test-Utf8Bom $path) "$(Split-Path -Leaf $path) has UTF-8 BOM" "$(Split-Path -Leaf $path) must have UTF-8 BOM"
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    Check (@($errors).Count-eq0) "$(Split-Path -Leaf $path) parses as PowerShell" "$(Split-Path -Leaf $path) has PowerShell parse errors"
}
$schema=Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -Depth 100
Check ([string]$schema['$schema']-ceq'http://json-schema.org/draft-07/schema#'-and$schema.additionalProperties-eq$false) 'preset lifecycle schema is strict Draft 7' 'preset lifecycle schema is not strict Draft 7'
$smokeText=Get-Content -LiteralPath $smokePath -Raw -Encoding utf8
Check ($smokeText.Contains('Smoke summary:')-and-not$smokeText.Contains('harness-preset-lifecycle-report/v1')) 'isolated install smoke remains console-only deterministic preflight' 'isolated install smoke was promoted into formal lifecycle evidence'

$mainProfile=[IO.Path]::GetFullPath($env:USERPROFILE)
$protectedFiles=[Collections.Generic.List[string]]::new()
$codexRoots=[Collections.Generic.List[string]]::new();$codexRoots.Add((Join-Path $mainProfile '.codex'))
if(-not[string]::IsNullOrWhiteSpace($env:CODEX_HOME)){$custom=[IO.Path]::GetFullPath($env:CODEX_HOME);if($custom-notin$codexRoots){$codexRoots.Add($custom)}}
foreach($root in $codexRoots){foreach($name in @('auth.json','hooks.json','config.toml','managed_config.toml')){$protectedFiles.Add((Join-Path $root $name))}}
$protectedFiles.Add((Join-Path $mainProfile '.claude\settings.json'));$protectedFiles.Add((Join-Path $mainProfile '.dev-harness\install-registry.json'))
$protectedBefore=Get-FileSnapshot @($protectedFiles)
$sourceBefore=Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('thin-v2-preset-lifecycle-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)

try {
    foreach($preset in @('core','governed','full')){
        $outputPath=Join-Path $temp "$preset-diagnostic.json"
        $console=@(& $powerShellPath -NoLogo -NoProfile -NonInteractive -File $producerPath -RepoRoot $RepoRoot -Preset $preset -OutputPath $outputPath -ProducerMode diagnostic-smoke 2>&1|ForEach-Object{[string]$_})
        $exitCode=$LASTEXITCODE
        Check ($exitCode-eq0-and(Test-Path -LiteralPath $outputPath -PathType Leaf)) "$preset diagnostic-smoke writes a report" "$preset diagnostic-smoke failed to write a report"
        if(-not(Test-Path -LiteralPath $outputPath -PathType Leaf)){continue}
        $bytes=[IO.File]::ReadAllBytes($outputPath);$raw=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);$report=$raw|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        $adapterResult=& $module {param($Root,$Document,$Preset)Assert-PresetLifecycleReport -RepoRoot $Root -Document $Document -ExpectedPreset $Preset -AllowNonFormalSource} $RepoRoot $report $preset
        Check (-not(Test-Utf8Bom $outputPath)-and(Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) "$preset diagnostic report is UTF-8 no-BOM and schema-valid" "$preset diagnostic report encoding or schema is invalid"
        Check ([string]$report.status-ceq'unavailable'-and[string]$report.reason-ceq'non-formal-producer-mode'-and[string]$adapterResult.status-ceq'unavailable') "$preset diagnostic success remains unavailable" "$preset diagnostic success was promoted or misclassified"
        Check ((@($report.stages|ForEach-Object{[string]$_.stage})-join'|')-ceq'install|verify-after-install|update|verify-after-update|uninstall|cleanup') "$preset diagnostic stage order is exact" "$preset diagnostic stage order drifted"
        Check (@($report.stages|Where-Object{[string]$_.status-cne'pass'-or[long]$_.exit_code-ne0}).Count-eq0) "$preset diagnostic stages record passing Exit Codes" "$preset diagnostic stage status and Exit Codes disagree"
        Check ([bool]$report.results.auth_unchanged-and[bool]$report.results.unrelated_user_config_unchanged-and[bool]$report.results.cleanup_no_residue-and[bool]$report.results.preset_consistent-and[bool]$report.results.installation_verified-and[bool]$report.results.update_verified) "$preset diagnostic lifecycle results are complete" "$preset diagnostic lifecycle results are incomplete"
        Check (-not(Test-Path -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) ("dev-harness-preset-lifecycle-$($report.report_run_id)")))-and[bool]$report.execution.isolated_workspace-and[bool]$report.execution.isolated_profile) "$preset diagnostic workspace/profile are isolated and removed" "$preset diagnostic left isolated residue"
        Check (-not[bool]$report.execution.raw_output_persisted-and-not[bool]$report.execution.auth_bytes_persisted-and-not[bool]$report.execution.private_paths_persisted-and$raw-notmatch'(?i)(authorization\s*:|bearer\s+|access[_-]?token|refresh[_-]?token|raw[ _-]?(?:output|trace|log)\s*:)' ) "$preset diagnostic report persists no raw output or credential content" "$preset diagnostic report persisted private content"
        Check (Test-ReportDigest $report) "$preset diagnostic report_digest recomputes" "$preset diagnostic report_digest mismatch"
        Check ((Test-SourceSame $report.source.start $report.source.end)-and(Test-SourceSame $sourceBefore $report.source.start)) "$preset diagnostic producer preserves Source state" "$preset diagnostic producer changed Source state"
        Check (($console-join"`n")-notmatch'(?i)(authorization\s*:|bearer\s+|access[_-]?token|refresh[_-]?token|password\s*:)' -and -not(($console-join"`n").Contains($mainProfile))) "$preset diagnostic console is sanitized" "$preset diagnostic console exposed private content"
    }

    $failureStages=@('install','verify-after-install','update','verify-after-update','uninstall','cleanup')
    for($index=0;$index-lt$failureStages.Count;$index++){
        $stageName=$failureStages[$index];$outputPath=Join-Path $temp "failure-$index.json"
        $null=@(& $powerShellPath -NoLogo -NoProfile -NonInteractive -File $producerPath -RepoRoot $RepoRoot -Preset core -OutputPath $outputPath -ProducerMode test-only -TestFailureStage $stageName 2>&1)
        $exitCode=$LASTEXITCODE
        Check ($exitCode-ne0-and(Test-Path -LiteralPath $outputPath -PathType Leaf)) "test-only $stageName failure writes a failing report" "test-only $stageName failure did not persist fail-closed evidence"
        if(-not(Test-Path -LiteralPath $outputPath -PathType Leaf)){continue}
        $report=Get-Content -LiteralPath $outputPath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        $adapterResult=& $module {param($Root,$Document)Assert-PresetLifecycleReport -RepoRoot $Root -Document $Document -ExpectedPreset core -AllowNonFormalSource} $RepoRoot $report
        Check ([string]$report.status-ceq'fail'-and[string]$adapterResult.status-ceq'fail'-and[string]$report.stages[$index].status-ceq'fail'-and[long]$report.stages[$index].exit_code-ne0) "test-only $stageName remains fail with a nonzero Exit Code" "test-only $stageName failure was promoted or lost"
        Check ([string]$report.stages[4].status-cne'not_run'-and[string]$report.stages[5].status-cne'not_run') "test-only $stageName still attempts uninstall and cleanup" "test-only $stageName skipped uninstall or cleanup"
        if($index-eq0){Check (@($report.stages[1..3]|Where-Object{[string]$_.status-cne'not_run'}).Count-eq0) 'install failure records dependent stages as not_run' 'install failure forged a dependent Stage pass'}
        elseif($index-eq1){Check (@($report.stages[2..3]|Where-Object{[string]$_.status-cne'not_run'}).Count-eq0) 'verify-after-install failure records update stages as not_run' 'verify-after-install failure forged an update Stage pass'}
        elseif($index-eq2){Check ([string]$report.stages[3].status-ceq'not_run') 'update failure records verify-after-update as not_run' 'update failure forged verify-after-update pass'}
        Check (-not(Test-Path -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) ("dev-harness-preset-lifecycle-$($report.report_run_id)")))) "test-only $stageName leaves no residue" "test-only $stageName left residue"
    }

    $existingPath=Join-Path $temp 'existing.json';[IO.File]::WriteAllText($existingPath,'sentinel',[Text.UTF8Encoding]::new($false))
    $null=@(& $powerShellPath -NoLogo -NoProfile -NonInteractive -File $producerPath -RepoRoot $RepoRoot -Preset core -OutputPath $existingPath -ProducerMode diagnostic-smoke 2>&1);Check ($LASTEXITCODE-ne0-and([IO.File]::ReadAllText($existingPath)-ceq'sentinel')) 'Producer refuses to overwrite an existing OutputPath' 'Producer overwrote an existing OutputPath'
    foreach($rejectedPath in @((Join-Path $RepoRoot '.git\preset-lifecycle-output.json'),(Join-Path $RepoRoot 'tests\preset-lifecycle-output.json'),(Join-Path $mainProfile '.codex\preset-lifecycle-output.json'))){
        $null=@(& $powerShellPath -NoLogo -NoProfile -NonInteractive -File $producerPath -RepoRoot $RepoRoot -Preset core -OutputPath $rejectedPath -ProducerMode diagnostic-smoke 2>&1)
        Check ($LASTEXITCODE-ne0-and-not(Test-Path -LiteralPath $rejectedPath)) 'Producer rejects Git/source/protected OutputPath overlap' 'Producer accepted a protected OutputPath'
    }
    $adsBase=Join-Path $temp 'ads-base.json';[IO.File]::WriteAllText($adsBase,'sentinel',[Text.UTF8Encoding]::new($false));$adsOutput=$adsBase+':lifecycle'
    $null=@(& $powerShellPath -NoLogo -NoProfile -NonInteractive -File $producerPath -RepoRoot $RepoRoot -Preset core -OutputPath $adsOutput -ProducerMode diagnostic-smoke 2>&1);Check ($LASTEXITCODE-ne0-and-not(Test-Path -LiteralPath $adsOutput)) 'Producer rejects alternate-stream OutputPath aliases' 'Producer accepted an alternate-stream OutputPath alias'
    $reparseTarget=Join-Path $temp 'output-target';[void][IO.Directory]::CreateDirectory($reparseTarget);$reparseAlias=Join-Path $temp 'output-alias';[void](New-Item -ItemType Junction -Path $reparseAlias -Target $reparseTarget -ErrorAction Stop)
    try{$reparseOutput=Join-Path $reparseAlias 'report.json';$null=@(& $powerShellPath -NoLogo -NoProfile -NonInteractive -File $producerPath -RepoRoot $RepoRoot -Preset core -OutputPath $reparseOutput -ProducerMode diagnostic-smoke 2>&1);Check ($LASTEXITCODE-ne0-and-not(Test-Path -LiteralPath $reparseOutput)) 'Producer rejects a reparse OutputPath alias' 'Producer accepted a reparse OutputPath alias'}finally{Remove-Item -LiteralPath $reparseAlias -Force}

    $sourceAfter=Get-HarnessReleaseSourceState -RepoRoot $RepoRoot;$protectedAfter=Get-FileSnapshot @($protectedFiles)
    Check (Test-SourceSame $sourceBefore $sourceAfter) 'all producer tests preserve repository Source state' 'producer tests changed repository Source state'
    Check (Test-SnapshotEqual $protectedBefore $protectedAfter) 'all producer tests preserve main Auth and user configuration bytes' 'producer tests changed main Auth or user configuration bytes'
    $runtimeFiles=@('scripts\lib\Harness.Protocol.psm1','scripts\lib\Harness.RuntimeDefault.psm1','.assistant\entry\task.ps1')
    Check (@($runtimeFiles|Where-Object{(Get-Content -LiteralPath (Join-Path $RepoRoot $_) -Raw -Encoding utf8)-match'preset-lifecycle-report'}).Count-eq0) 'Runtime Core, status entry, and Runtime Default do not read lifecycle evidence' 'Runtime Core or status started reading lifecycle evidence'
} finally {
    Remove-Module Harness.RolloutEvidence,Harness.Protocol -ErrorAction Ignore
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
}

foreach($item in $script:checks){Write-Output "[PASS] $item"}
foreach($item in $script:failures){Write-Output "[FAIL] $item"}
if($script:failures.Count-gt0){Write-Output "STATUS: FAIL ($($script:failures.Count) failed)";exit 1}
Write-Output "STATUS: PASS ($($script:checks.Count) checks)"
exit 0
