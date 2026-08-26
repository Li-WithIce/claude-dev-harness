[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string[]]$ChangedPaths = @(),
    [string]$ChangedPathsFile = '',
    [switch]$ListOnly,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if (-not [string]::IsNullOrWhiteSpace($ChangedPathsFile)) {
    $resolvedList = (Resolve-Path -LiteralPath $ChangedPathsFile).Path
    $ChangedPaths += @(Get-Content -LiteralPath $resolvedList -Encoding utf8)
}
$normalizedPaths = @($ChangedPaths | ForEach-Object {
    $path = ([string]$_).Trim().Replace('\','/').TrimStart('/')
    if ($path.StartsWith('./',[System.StringComparison]::Ordinal)) { $path = $path.Substring(2) }
    $path
} | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

$definitions = @(
    [ordered]@{name='memory';patterns=@('skills/obsidian-memory/*','scripts/*memory*','scripts/*runtime-inbox*','tests/verify-*memory*','tests/verify-*runtime-inbox*','.assistant/*memory*','vault-template/*memory*');tests=@('verify-archive-memory-candidates.ps1','verify-memory-health-report.ps1','verify-memory-maintain.ps1','verify-memory-provider-boundary.ps1','verify-repair-shared-memory.ps1','verify-runtime-inbox.ps1','verify-shared-memory-layers.ps1','verify-triage-runtime-inbox.ps1','verify-v2-runtime-memory-decoupling.ps1')},
    [ordered]@{name='team';patterns=@('skills/workflow-team/*','scripts/*team*','scripts/invoke-harness-skill*.ps1','tests/verify-aiteamcode-*','tests/verify-team-*');tests=@('verify-aiteamcode-skill-contract.ps1','verify-team-orchestration.ps1','verify-team-preset.ps1')},
    [ordered]@{name='md-html';patterns=@('skills/md-html/*','scripts/*render*html*','tests/verify-md-html-*','tests/verify-render-review-html.ps1');tests=@('verify-md-html-review-renderer.ps1','verify-render-review-html.ps1')},
    [ordered]@{name='codex-adapter';patterns=@('skills/codex/*','scripts/invoke_codex.ps1','scripts/ask_codex.ps1','agent-configs/codex/*','tests/verify-ask-codex.ps1','tests/verify-codex-entry-autoload.ps1');tests=@('verify-ask-codex.ps1','verify-codex-entry-autoload.ps1')},
    [ordered]@{name='providers';patterns=@('policies/*provider*','scripts/*provider*','scripts/lib/*Provider*','tests/verify-*provider*','agent-configs/*provider*');tests=@('verify-code-intel-provider-boundary.ps1','verify-context-provider-boundary.ps1','verify-context-provider-install-isolation.ps1','verify-context-provider-vnext.ps1','verify-experimental-provider-docs.ps1','verify-provider-routing-matrix.ps1','verify-provider-usage-recording.ps1')},
    [ordered]@{name='thin-trust-kernel';patterns=@('docs/architecture/*','kernel-tcb-*.json','kernel-component-classification.json','schemas/*kernel*','schemas/module-manifest.schema.json','scripts/get-kernel-tcb-inventory.ps1','scripts/lib/Harness.Hashing.psm1','tests/fixtures/tk00/*','tests/verify-hashing-module.ps1','tests/verify-*kernel*');tests=@('verify-hashing-module.ps1','verify-kernel-tcb-inventory.ps1','verify-thin-trust-kernel-contracts.ps1')},
    [ordered]@{name='harness-maintenance';patterns=@('install.ps1','uninstall.ps1','runtime-hooks/*','schemas/*','scripts/benchmark-harness.ps1','scripts/install-transaction-common.ps1','scripts/lite-artifact-parser.ps1','scripts/update-managed-assets.ps1','scripts/validate-lite-artifacts.ps1','tests/fixtures/v2/*','tests/verify-change-contract.ps1','tests/verify-install-isolation.ps1','tests/verify-runtime-hooks.ps1','tests/verify-uninstall-isolation.ps1','tests/verify-update-managed-assets.ps1','tests/verify-v2-baseline-benchmark.ps1','tests/verify-v2-policy-contracts.ps1');tests=@('verify-change-contract.ps1','verify-install-isolation.ps1','verify-runtime-hooks.ps1','verify-uninstall-isolation.ps1','verify-update-managed-assets.ps1','verify-v2-baseline-benchmark.ps1','verify-v2-policy-contracts.ps1')}
)
$routingSurfaces = @('.github/workflows/*','scripts/run-validation.ps1','scripts/run-changed-optional-validation.ps1','tests/verify-v2-ci-routing.ps1','install.ps1','uninstall.ps1','scripts/run-isolated-install-smoke.ps1')

function Test-AnyPattern {
    param([string]$Path,[string[]]$Patterns)
    foreach ($pattern in $Patterns) { if ($Path -like $pattern) { return $true } }
    return $false
}

$runAll = @($normalizedPaths | Where-Object { Test-AnyPattern -Path $_ -Patterns $routingSurfaces }).Count -gt 0
$selectedModules = [System.Collections.Generic.List[string]]::new()
$selectedTests = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($definition in $definitions) {
    $matched = $runAll -or @($normalizedPaths | Where-Object { Test-AnyPattern -Path $_ -Patterns @($definition.patterns) }).Count -gt 0
    if (-not $matched) { continue }
    $selectedModules.Add([string]$definition.name)
    foreach ($test in $definition.tests) { [void]$selectedTests.Add([string]$test) }
}
$testNames = @($selectedTests | Sort-Object)
foreach ($testName in $testNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "tests\$testName") -PathType Leaf)) { throw "optional verifier is missing: $testName" }
}
$route = [ordered]@{schema_version='harness-ci-routing/v1';changed_path_count=$normalizedPaths.Count;run_all_optional=$runAll;modules=@($selectedModules);tests=$testNames}
if ($ListOnly) {
    if ($AsJson) { Write-Output ($route | ConvertTo-Json -Depth 10 -Compress) } else { $route }
    exit 0
}

if ($testNames.Count -eq 0) {
    Write-Output 'STATUS: PASS (0 optional modules selected)'
    exit 0
}
$powerShell = (Get-Process -Id $PID).Path
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($testName in $testNames) {
    Write-Output ("[RUN ] {0}" -f $testName)
    & $powerShell -NoLogo -NoProfile -NonInteractive -File (Join-Path $RepoRoot "tests\$testName")
    if ($LASTEXITCODE -eq 0) { Write-Output ("[PASS] {0}" -f $testName) } else { $failures.Add($testName); Write-Output ("[FAIL] {0} (exit {1})" -f $testName,$LASTEXITCODE) }
}
if ($failures.Count -gt 0) { Write-Output ("STATUS: FAIL ({0} optional verifiers failed)" -f $failures.Count); exit 1 }
Write-Output ("STATUS: PASS ({0} optional verifiers)" -f $testNames.Count)
exit 0
