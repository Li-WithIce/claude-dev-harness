[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$script:checks = [System.Collections.Generic.List[string]]::new()
$script:failures = [System.Collections.Generic.List[string]]::new()

function Add-Check {
    param([string]$Message)
    $script:checks.Add($Message)
}

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Success,
        [string]$Failure
    )

    if ($Condition) {
        Add-Check $Success
    } else {
        Add-Failure $Failure
    }
}

function Invoke-Benchmark {
    param(
        [string[]]$Protocols,
        [string]$OutputPath = ''
    )

    $arguments = @{
        RepoRoot = $RepoRoot
        Compare = $Protocols
        Iterations = 2
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $arguments['OutputPath'] = $OutputPath
    }
    return Invoke-RepoScript -UserProfile $env:USERPROFILE -ScriptPath $script:benchmarkPath -Arguments $arguments -WorkingDirectory $RepoRoot
}

$script:benchmarkPath = Join-Path $RepoRoot 'scripts\benchmark-harness.ps1'
$fixturePath = Join-Path $RepoRoot 'tests\scenarios\baseline\clear-low-risk-single-file.json'
$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('thin-v2-pr00-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $scratchRoot | Out-Null

    foreach ($scriptPath in @($script:benchmarkPath, $PSCommandPath)) {
        Assert-True -Condition (Test-FileHasUtf8Bom -Path $scriptPath) -Success ("{0} has UTF-8 BOM" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} must have UTF-8 BOM" -f (Split-Path -Leaf $scriptPath))
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True -Condition (@($parseErrors).Count -eq 0) -Success ("{0} parses as PowerShell" -f (Split-Path -Leaf $scriptPath)) -Failure ("{0} has PowerShell parse errors" -f (Split-Path -Leaf $scriptPath))
    }

    $fixtureRaw = Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8
    $fixture = $fixtureRaw | ConvertFrom-Json
    Assert-True -Condition ([string]$fixture.schema_version -ceq 'harness-benchmark-scenario/v1') -Success 'baseline fixture uses the canonical schema' -Failure 'baseline fixture schema is invalid'
    Assert-True -Condition ([bool]$fixture.source.contains_full_prompt -eq $false) -Success 'baseline fixture declares that no full prompt is stored' -Failure 'baseline fixture must not store a full prompt'
    Assert-True -Condition ($fixtureRaw -notmatch '(?i)(?:[a-z]:[\\/]|/(?:users|home)/|authorization\s*:\s*bearer|sk-[a-z0-9_-]{16,})') -Success 'baseline fixture is free of private paths and credential-like text' -Failure 'baseline fixture contains private or credential-like text'

    $statusBefore = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
    $first = Invoke-Benchmark -Protocols @('v1')
    Assert-True -Condition ($first.ExitCode -eq 0) -Success 'v1 benchmark exits successfully' -Failure ("v1 benchmark failed: {0}" -f ($first.Output -join [Environment]::NewLine))
    $firstText = $first.Output -join [Environment]::NewLine
    $firstReport = Assert-SingleLineJson -JsonText $firstText -Label 'v1 benchmark'

    if ($null -ne $firstReport) {
        Assert-True -Condition ([string]$firstReport.schema_version -ceq 'harness-benchmark/v1') -Success 'benchmark report uses the canonical schema' -Failure 'benchmark report schema is invalid'
        Assert-True -Condition ([string]$firstReport.baseline.branch -ceq 'codex/harness-distribution' -and [string]$firstReport.baseline.commit -ceq 'aee525f6b3b0638f11bf6ab278482aa5b8c79d11') -Success 'benchmark report records the base branch and commit' -Failure 'benchmark report baseline identity is wrong'
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$firstReport.environment.powershell_version) -and -not [string]::IsNullOrWhiteSpace([string]$firstReport.environment.windows_version) -and [string]$firstReport.environment.install_profile -ceq 'auto') -Success 'benchmark report records PowerShell, Windows, and install profile' -Failure 'benchmark report environment metadata is incomplete'
        Assert-True -Condition ([int]$firstReport.inventory.skill_directories -gt 0 -and [int]$firstReport.inventory.verify_scripts -gt 0) -Success 'benchmark report includes repository inventory' -Failure 'benchmark report inventory is incomplete'

        $v1Comparisons = @($firstReport.comparisons)
        Assert-True -Condition ($v1Comparisons.Count -eq 1 -and [string]$v1Comparisons[0].protocol -ceq 'v1') -Success 'v1 benchmark emits one v1 comparison' -Failure 'v1 benchmark comparison set is wrong'
        if ($v1Comparisons.Count -eq 1) {
            $metrics = $v1Comparisons[0].metrics
            $metricNames = @('model_turns', 'tool_calls', 'loaded_files', 'loaded_skills', 'artifact_writes', 'runtime_writes', 'direct_latency_ms', 'total_duration_ms')
            $present = @($metricNames | Where-Object { $null -ne $metrics.PSObject.Properties[$_] })
            Assert-True -Condition ($present.Count -eq $metricNames.Count) -Success 'benchmark report includes every required metric' -Failure 'benchmark report is missing required metrics'
            Assert-True -Condition ([string]$metrics.model_turns.status -ceq 'unavailable' -and $null -eq $metrics.model_turns.value -and [string]$metrics.tool_calls.status -ceq 'unavailable') -Success 'uncaptured host metrics remain unavailable' -Failure 'uncaptured host metrics must not be presented as measured'
            Assert-True -Condition ([string]$metrics.loaded_files.status -ceq 'simulated' -and [string]$metrics.total_duration_ms.status -ceq 'measured') -Success 'fixture counts and replay duration retain honest status labels' -Failure 'benchmark metric status labels are misleading'
            Assert-True -Condition ([string]$metrics.direct_latency_ms.status -ceq 'unavailable') -Success 'uncaptured Direct host latency remains unavailable' -Failure 'Direct latency was inferred from a fixture'
        }

        Assert-True -Condition (-not [bool]$firstReport.performance_regression.eligible -and [string]$firstReport.performance_regression.direct_latency.status -ceq 'unavailable') -Success 'missing bare/v2 Direct latency fails performance eligibility' -Failure 'missing Direct latency was treated as eligible'

        Assert-True -Condition ($firstText -notmatch [regex]::Escape($RepoRoot) -and $firstText -notmatch [regex]::Escape($env:USERPROFILE) -and $firstText -notmatch '(?i)"prompt"\s*:') -Success 'benchmark report omits repo paths, user paths, and full prompt fields' -Failure 'benchmark report leaks a private path or prompt field'
    }

    $second = Invoke-Benchmark -Protocols @('v1')
    $secondReport = Assert-SingleLineJson -JsonText ($second.Output -join [Environment]::NewLine) -Label 'repeated v1 benchmark'
    Assert-True -Condition ($second.ExitCode -eq 0 -and $null -ne $secondReport -and [int]$secondReport.summary.comparison_count -eq 1) -Success 'the same v1 scenario can be repeated' -Failure 'repeated v1 benchmark did not produce the same report shape'

    $matrix = Invoke-Benchmark -Protocols @('bare,v1,v2')
    $matrixReport = Assert-SingleLineJson -JsonText ($matrix.Output -join [Environment]::NewLine) -Label 'comparison matrix benchmark'
    $matrixProtocols = if ($null -eq $matrixReport) { @() } else { @($matrixReport.comparisons | ForEach-Object { [string]$_.protocol }) }
    Assert-True -Condition ($matrix.ExitCode -eq 0 -and ($matrixProtocols -join ',') -ceq 'bare,v1,v2') -Success 'comma-delimited bare, v1, and v2 comparisons are normalized' -Failure 'comparison matrix parsing is wrong'
    if ($null -ne $matrixReport) {
        $v2 = @($matrixReport.comparisons | Where-Object { [string]$_.protocol -ceq 'v2' } | Select-Object -First 1)
        Assert-True -Condition ($v2.Count -eq 1 -and [string]$v2[0].metrics.model_turns.status -ceq 'unavailable') -Success 'missing protocol observations remain unavailable' -Failure 'missing protocol observations must not be presented as measured'
        Assert-True -Condition ([string]$matrixReport.performance_regression.local_fixture_replay.status -ceq 'measured' -and -not [bool]$matrixReport.performance_regression.eligible -and [string]$matrixReport.performance_regression.direct_latency.status -ceq 'unavailable') -Success 'benchmark separates measured replay diagnostics from unavailable rollout latency' -Failure 'benchmark conflated fixture replay with Direct performance eligibility'
    }

    $outputPath = Join-Path $scratchRoot 'benchmark.json'
    $written = Invoke-Benchmark -Protocols @('v1') -OutputPath $outputPath
    $writtenText = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Get-Content -LiteralPath $outputPath -Raw -Encoding utf8 } else { '' }
    Assert-True -Condition ($written.ExitCode -eq 0 -and $writtenText -ceq ($written.Output -join [Environment]::NewLine)) -Success 'explicit OutputPath writes only the emitted report' -Failure 'explicit OutputPath did not contain the emitted report'

    $invalid = Start-RepoProcess -UserProfile $env:USERPROFILE -ScriptPath $script:benchmarkPath -Arguments @('-RepoRoot', $RepoRoot, '-Compare', 'unknown', '-Iterations', '1')
    $invalidExited = $invalid.Process.WaitForExit(30000)
    if ($invalidExited) {
        [void]$invalid.StdOut.GetAwaiter().GetResult()
        [void]$invalid.StdErr.GetAwaiter().GetResult()
    }
    Assert-True -Condition ($invalidExited -and $invalid.Process.ExitCode -ne 0) -Success 'unknown comparisons fail closed' -Failure 'unknown comparisons should fail with a non-zero exit code'
    if (-not $invalid.Process.HasExited) {
        $invalid.Process.Kill($true)
        [void]$invalid.Process.WaitForExit(5000)
    }
    $invalid.Process.Dispose()

    $statusAfter = @(& git -C $RepoRoot status --porcelain --untracked-files=all)
    $statusDiff = @(Compare-Object -ReferenceObject $statusBefore -DifferenceObject $statusAfter)
    Assert-True -Condition ($statusDiff.Count -eq 0) -Success 'default benchmark runs do not write repository artifacts or runtime state' -Failure 'benchmark run changed repository status'
} finally {
    Remove-DirectoryWithRetry -Path $scratchRoot
}

foreach ($check in $script:checks) {
    Write-Output ("[PASS] {0}" -f $check)
}
foreach ($failure in $script:failures) {
    Write-Output ("[FAIL] {0}" -f $failure)
}

if ($script:failures.Count -gt 0) {
    Write-Output ("STATUS: FAIL ({0} failed)" -f $script:failures.Count)
    exit 1
}

Write-Output ("STATUS: PASS ({0} checks)" -f $script:checks.Count)
exit 0
