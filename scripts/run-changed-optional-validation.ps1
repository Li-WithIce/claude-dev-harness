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
$manifestModulePath = Join-Path $RepoRoot 'scripts\lib\Harness.ModuleManifest.psm1'
Import-Module $manifestModulePath -Force -ErrorAction Stop
$manifestCatalog = Assert-HarnessModuleManifestCatalogCurrent -RepoRoot $RepoRoot

if (-not [string]::IsNullOrWhiteSpace($ChangedPathsFile)) {
    $resolvedList = (Resolve-Path -LiteralPath $ChangedPathsFile).Path
    $ChangedPaths += @(Get-Content -LiteralPath $resolvedList -Encoding utf8)
}
$normalizedPaths = @($ChangedPaths | ForEach-Object {
    $path = ([string]$_).Trim().Replace('\','/').TrimStart('/')
    if ($path.StartsWith('./',[System.StringComparison]::Ordinal)) { $path = $path.Substring(2) }
    $path
} | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

$definitions = @($manifestCatalog.Catalog.optional_routes | ForEach-Object {
    [ordered]@{
        name = [string]$_.module_id
        patterns = @($_.match_paths)
        tests = @($_.tests | ForEach-Object { Split-Path -Leaf ([string]$_) })
    }
})
$routingSurfaces = @('.github/workflows/*','capability-source-catalog.json','module-manifest-catalog.json','modules/*/module.manifest.json','schemas/capability-source*.json','schemas/module-manifest*.json','scripts/get-module-manifest-catalog.ps1','scripts/lib/Harness.CapabilitySource.psm1','scripts/lib/Harness.ModuleManifest.psm1','scripts/run-validation.ps1','scripts/run-changed-optional-validation.ps1','scripts/write-capability-source-binding.ps1','tests/verify-v2-ci-routing.ps1','install.ps1','uninstall.ps1','scripts/run-isolated-install-smoke.ps1')

function Test-AnyPattern {
    param([string]$Path,[string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        $candidate = [string]$pattern
        if ($candidate.EndsWith('/**',[StringComparison]::Ordinal)) {
            $base = $candidate.Substring(0,$candidate.Length-3)
            if ($Path -ceq $base -or $Path.StartsWith($base + '/',[StringComparison]::Ordinal)) { return $true }
        } elseif ($Path -ceq $candidate) {
            return $true
        }
    }
    return $false
}

function Test-AnyRoutingSurface {
    param([string]$Path,[string[]]$Patterns)
    foreach ($pattern in $Patterns) { if ($Path -like $pattern) { return $true } }
    return $false
}

$runAll = @($normalizedPaths | Where-Object { Test-AnyRoutingSurface -Path $_ -Patterns $routingSurfaces }).Count -gt 0
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
