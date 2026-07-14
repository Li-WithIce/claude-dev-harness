[CmdletBinding()]
param(
    [string]$RepoRoot = '',

    [string[]]$Compare = @('v1'),

    [string]$ScenarioRoot = '',

    [ValidateSet('auto', 'minimal', 'full')]
    [string]$InstallProfile = 'auto',

    [ValidateRange(1, 100)]
    [int]$Iterations = 5,

    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RootPath {
    param(
        [string]$RequestedPath,
        [string]$DefaultPath
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { $DefaultPath } else { $RequestedPath }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Resolve-PathFromRepo {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Invoke-GitText {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0} failed with exit code {1}" -f ($Arguments -join ' '), $LASTEXITCODE)
    }

    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Assert-SafeFixtureText {
    param(
        [string]$Raw,
        [string]$Name
    )

    if ($Raw -match '(?i)"(?:prompt|prompt_text|raw_prompt|user_profile|repo_root|machine_name|hostname|password|secret|token|cookie)"\s*:') {
        throw "Scenario '$Name' contains a forbidden sensitive or full-prompt field."
    }
    if ($Raw -match '(?i)(?:[a-z]:[\\/]|\\\\[^\\/\s]+[\\/]|/(?:users|home)/)') {
        throw "Scenario '$Name' contains an absolute private path."
    }
    if ($Raw -match '(?i)(?:authorization\s*:\s*bearer|sk-[a-z0-9_-]{16,})') {
        throw "Scenario '$Name' contains credential-like text."
    }
}

function New-UnavailableMetric {
    param([string]$Reason)

    return [ordered]@{
        status = 'unavailable'
        value = $null
        reason = $Reason
    }
}

function ConvertTo-Metric {
    param(
        [object]$Observation,
        [string]$MetricName,
        [string]$ScenarioId,
        [string]$Protocol
    )

    if ($null -eq $Observation) {
        return (New-UnavailableMetric -Reason "No $Protocol observation exists in this fixture.")
    }

    $property = $Observation.PSObject.Properties[$MetricName]
    if ($null -eq $property) {
        throw "Scenario '$ScenarioId' protocol '$Protocol' is missing metric '$MetricName'."
    }

    $metric = $property.Value
    $status = [string]$metric.status
    $reason = [string]$metric.reason
    if ($status -notin @('measured', 'simulated', 'unavailable')) {
        throw "Scenario '$ScenarioId' metric '$MetricName' has invalid status '$status'."
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
        throw "Scenario '$ScenarioId' metric '$MetricName' must explain its status."
    }

    $value = $metric.value
    if ($status -eq 'unavailable') {
        if ($null -ne $value) {
            throw "Scenario '$ScenarioId' unavailable metric '$MetricName' must have a null value."
        }
    } elseif ($null -eq $value -or $value -is [bool] -or [double]$value -lt 0) {
        throw "Scenario '$ScenarioId' metric '$MetricName' must have a non-negative numeric value."
    }

    return [ordered]@{
        status = $status
        value = $value
        reason = $reason
    }
}

function ConvertTo-OptionalMetric {
    param(
        [object]$Observation,
        [string]$MetricName,
        [string]$ScenarioId,
        [string]$Protocol
    )

    if ($null -eq $Observation -or $null -eq $Observation.PSObject.Properties[$MetricName]) {
        return (New-UnavailableMetric -Reason "No measured $MetricName observation exists for $Protocol in scenario $ScenarioId.")
    }
    return ConvertTo-Metric -Observation $Observation -MetricName $MetricName -ScenarioId $ScenarioId -Protocol $Protocol
}

function Get-Median {
    param([double[]]$Values)

    $sorted = @($Values | Sort-Object)
    $middle = [math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [double]$sorted[$middle]
    }

    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

$repoRootResolved = Resolve-RootPath -RequestedPath $RepoRoot -DefaultPath (Join-Path $PSScriptRoot '..')
$scenarioRootResolved = if ([string]::IsNullOrWhiteSpace($ScenarioRoot)) {
    Join-Path $repoRootResolved 'tests\scenarios\baseline'
} else {
    Resolve-PathFromRepo -Path $ScenarioRoot -Root $repoRootResolved
}
$scenarioRootResolved = Resolve-RootPath -RequestedPath $scenarioRootResolved -DefaultPath $scenarioRootResolved

$protocols = [System.Collections.Generic.List[string]]::new()
foreach ($item in $Compare) {
    foreach ($token in ([string]$item -split ',')) {
        $normalized = $token.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }
        if ($normalized -notin @('bare', 'v1', 'v2')) {
            throw "Unsupported comparison '$normalized'. Allowed values: bare, v1, v2."
        }
        if (-not $protocols.Contains($normalized)) {
            $protocols.Add($normalized)
        }
    }
}
if ($protocols.Count -eq 0) {
    throw 'At least one comparison is required.'
}

$scenarioFiles = @(Get-ChildItem -LiteralPath $scenarioRootResolved -Filter '*.json' -File -Recurse | Sort-Object FullName)
if ($scenarioFiles.Count -eq 0) {
    throw 'No benchmark scenario fixtures were found.'
}

$scenarioRecords = [System.Collections.Generic.List[object]]::new()
$baselineBranch = ''
$baselineCommit = ''
$baselineTag = ''
foreach ($scenarioFile in $scenarioFiles) {
    $raw = Get-Content -LiteralPath $scenarioFile.FullName -Raw -Encoding utf8
    Assert-SafeFixtureText -Raw $raw -Name $scenarioFile.Name
    $scenario = $raw | ConvertFrom-Json
    if ([string]$scenario.schema_version -cne 'harness-benchmark-scenario/v1') {
        throw "Scenario '$($scenarioFile.Name)' has an unsupported schema version."
    }
    if ([string]::IsNullOrWhiteSpace([string]$scenario.scenario_id)) {
        throw "Scenario '$($scenarioFile.Name)' is missing scenario_id."
    }
    if ([string]$scenario.baseline.commit -notmatch '^[0-9a-f]{40}$') {
        throw "Scenario '$($scenarioFile.Name)' has an invalid baseline commit."
    }
    if ([string]::IsNullOrWhiteSpace([string]$scenario.baseline.branch) -or [string]::IsNullOrWhiteSpace([string]$scenario.baseline.tag)) {
        throw "Scenario '$($scenarioFile.Name)' is missing baseline branch or tag."
    }

    if ([string]::IsNullOrWhiteSpace($baselineCommit)) {
        $baselineBranch = [string]$scenario.baseline.branch
        $baselineCommit = [string]$scenario.baseline.commit
        $baselineTag = [string]$scenario.baseline.tag
    } elseif ($baselineBranch -cne [string]$scenario.baseline.branch -or $baselineCommit -cne [string]$scenario.baseline.commit -or $baselineTag -cne [string]$scenario.baseline.tag) {
        throw 'All benchmark scenarios must use the same baseline identity.'
    }

    $scenarioRecords.Add([pscustomobject]@{
        File = $scenarioFile.FullName
        Scenario = $scenario
    })
}

$resolvedBaselineCommit = Invoke-GitText -Root $repoRootResolved -Arguments @('rev-parse', "$baselineCommit^{commit}")
if ($resolvedBaselineCommit -cne $baselineCommit) {
    throw 'The fixture baseline commit does not resolve to the declared commit.'
}

$tagOutput = @(& git -C $repoRootResolved rev-parse --verify "refs/tags/$baselineTag^{commit}" 2>$null)
$tagVerified = $LASTEXITCODE -eq 0 -and (($tagOutput -join '').Trim() -ceq $baselineCommit)
$branchOutput = @(& git -C $repoRootResolved rev-parse --verify "refs/heads/$baselineBranch^{commit}" 2>$null)
$branchVerified = $LASTEXITCODE -eq 0 -and (($branchOutput -join '').Trim() -ceq $baselineCommit)

$inventoryScript = Join-Path $repoRootResolved 'scripts\get-repo-inventory.ps1'
$inventoryJson = @(& $inventoryScript -RepoRoot $repoRootResolved -AsJson)
if ($LASTEXITCODE -ne 0) {
    throw 'Repository inventory failed.'
}
$inventory = ($inventoryJson -join [Environment]::NewLine) | ConvertFrom-Json

$metricNames = @('model_turns', 'tool_calls', 'loaded_files', 'loaded_skills', 'artifact_writes', 'runtime_writes')
$optionalMetricNames = @('direct_latency_ms')
$comparisons = [System.Collections.Generic.List[object]]::new()
foreach ($record in $scenarioRecords) {
    foreach ($protocol in $protocols) {
        $protocolProperty = $record.Scenario.protocols.PSObject.Properties[$protocol]
        $observation = if ($null -eq $protocolProperty) { $null } else { $protocolProperty.Value }
        $metrics = [ordered]@{}
        foreach ($metricName in $metricNames) {
            $metrics[$metricName] = ConvertTo-Metric -Observation $observation -MetricName $metricName -ScenarioId ([string]$record.Scenario.scenario_id) -Protocol $protocol
        }
        foreach ($metricName in $optionalMetricNames) {
            $metrics[$metricName] = ConvertTo-OptionalMetric -Observation $observation -MetricName $metricName -ScenarioId ([string]$record.Scenario.scenario_id) -Protocol $protocol
        }

        $samples = [System.Collections.Generic.List[double]]::new()
        for ($iteration = 0; $iteration -lt $Iterations; $iteration++) {
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $replayed = (Get-Content -LiteralPath $record.File -Raw -Encoding utf8) | ConvertFrom-Json
            [void]$replayed.PSObject.Properties['scenario_id'].Value
            [void]$replayed.protocols.PSObject.Properties[$protocol]
            $timer.Stop()
            $samples.Add($timer.Elapsed.TotalMilliseconds)
        }
        $metrics['total_duration_ms'] = [ordered]@{
            status = 'measured'
            value = [math]::Round((Get-Median -Values $samples.ToArray()), 3)
            reason = 'Median local fixture replay duration; this is not host-model latency.'
        }

        $comparisons.Add([pscustomobject]@{
            protocol = $protocol
            scenario_id = [string]$record.Scenario.scenario_id
            metrics = $metrics
        })
    }
}

$statusCounts = [ordered]@{ measured = 0; simulated = 0; unavailable = 0 }
foreach ($comparison in $comparisons) {
    foreach ($metricName in @($metricNames + $optionalMetricNames + 'total_duration_ms')) {
        $status = [string]$comparison.metrics[$metricName].status
        $statusCounts[$status] = [int]$statusCounts[$status] + 1
    }
}

$bareComparison = @($comparisons | Where-Object { [string]$_.protocol -ceq 'bare' } | Select-Object -First 1)
$v2Comparison = @($comparisons | Where-Object { [string]$_.protocol -ceq 'v2' } | Select-Object -First 1)
$localReplay = [ordered]@{status='unavailable';ratio=$null;threshold=1.25;reason='bare and v2 comparisons are both required for a local replay ratio'}
$directLatency = [ordered]@{status='unavailable';ratio=$null;threshold=1.25;reason='measured bare and v2 Direct host latency observations are required'}
if ($bareComparison.Count -eq 1 -and $v2Comparison.Count -eq 1) {
    $bareReplay = [double]$bareComparison[0].metrics.total_duration_ms.value
    $v2Replay = [double]$v2Comparison[0].metrics.total_duration_ms.value
    if ($bareReplay -gt 0) {
        $localRatio = [math]::Round($v2Replay / $bareReplay, 4)
        $localReplay = [ordered]@{status='measured';ratio=$localRatio;threshold=1.25;reason='Diagnostic local fixture replay ratio; never treated as Direct host latency or rollout evidence.'}
    }
    $bareLatency = $bareComparison[0].metrics.direct_latency_ms
    $v2Latency = $v2Comparison[0].metrics.direct_latency_ms
    if ([string]$bareLatency.status -ceq 'measured' -and [string]$v2Latency.status -ceq 'measured' -and [double]$bareLatency.value -gt 0) {
        $directRatio = [math]::Round(([double]$v2Latency.value / [double]$bareLatency.value),4)
        $directLatency = [ordered]@{status=$(if($directRatio -le 1.25){'pass'}else{'fail'});ratio=$directRatio;threshold=1.25;reason='Ratio of measured v2 and bare Direct host latency observations.'}
    } elseif ([string]$bareLatency.status -ceq 'simulated' -or [string]$v2Latency.status -ceq 'simulated') {
        $directLatency = [ordered]@{status='simulated';ratio=$null;threshold=1.25;reason='Simulated Direct latency cannot authorize rollout.'}
    }
}
$performanceEligible = [string]$directLatency.status -ceq 'pass'

$runner = if ([string]$env:GITHUB_ACTIONS -eq 'true') { 'github-actions' } else { 'local' }
$report = [ordered]@{
    schema_version = 'harness-benchmark/v1'
    generated_at_utc = [DateTime]::UtcNow.ToString('o')
    baseline = [ordered]@{
        branch = $baselineBranch
        commit = $baselineCommit
        tag = $baselineTag
        branch_target_verified = $branchVerified
        tag_target_verified = $tagVerified
    }
    environment = [ordered]@{
        powershell_version = $PSVersionTable.PSVersion.ToString()
        windows_version = [System.Environment]::OSVersion.VersionString
        runner = $runner
        install_profile = $InstallProfile
    }
    inventory = $inventory
    comparisons = [object[]]$comparisons.ToArray()
    performance_regression = [ordered]@{
        direct_latency = $directLatency
        local_fixture_replay = $localReplay
        eligible = $performanceEligible
        status = $(if($performanceEligible){'pass'}else{'fail'})
        reason = $(if($performanceEligible){'measured Direct latency meets the v2-to-bare threshold'}else{'Direct performance is failed, simulated, or unavailable; rollout must remain fail closed'})
    }
    summary = [ordered]@{
        scenario_count = $scenarioRecords.Count
        comparison_count = $comparisons.Count
        iterations = $Iterations
        metric_status_counts = $statusCounts
    }
}

$json = $report | ConvertTo-Json -Depth 12 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutputPath = Resolve-PathFromRepo -Path $OutputPath -Root $repoRootResolved
    $outputParent = Split-Path -Parent $resolvedOutputPath
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        throw 'OutputPath parent directory does not exist.'
    }
    [System.IO.File]::WriteAllText($resolvedOutputPath, $json, [System.Text.UTF8Encoding]::new($false))
}

Write-Output $json
exit 0
