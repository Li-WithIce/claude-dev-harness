[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
function Check {
    param([bool]$Condition, [string]$Success, [string]$Failure)
    if ($Condition) { Write-Output "[PASS] $Success" } else { Write-Output "[FAIL] $Failure"; $failures.Add($Failure) }
}
function Get-OrdinalStrings {
    param([object[]]$Values)
    [string[]]$result = @($Values | ForEach-Object { [string]$_ })
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
}
function Test-ConstructionFailure {
    param([string]$ManifestRoot, [string]$Pattern)
    try {
        $null = Harness.ModuleManifest\Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot -ManifestRoot $ManifestRoot
        return $false
    } catch {
        return $_.Exception.Message -match $Pattern
    }
}
function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    return $Left.Length -eq $Right.Length -and [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

$modulePath = Join-Path $RepoRoot 'scripts/lib/Harness.ModuleManifest.psm1'
$generatorPath = Join-Path $RepoRoot 'scripts/get-module-manifest-catalog.ps1'
$catalogPath = Join-Path $RepoRoot 'module-manifest-catalog.json'
$capabilitySourceCatalogPath = Join-Path $RepoRoot 'capability-source-catalog.json'
$catalogSchemaPath = Join-Path $RepoRoot 'schemas/module-manifest-catalog-v1.schema.json'
$capabilitySourceCatalogSchemaPath = Join-Path $RepoRoot 'schemas/capability-source-catalog.schema.json'
$sourceSchemaPath = Join-Path $RepoRoot 'schemas/module-manifest.schema.json'
$sourceV1SchemaPath = Join-Path $RepoRoot 'schemas/module-manifest-v1.schema.json'
$attributesPath = Join-Path $RepoRoot '.gitattributes'
$testPath = Join-Path $RepoRoot 'tests/verify-module-manifest-catalog.ps1'
$requiredFiles = @($modulePath,$generatorPath,$catalogPath,$capabilitySourceCatalogPath,$catalogSchemaPath,$capabilitySourceCatalogSchemaPath,$sourceSchemaPath,$sourceV1SchemaPath,$attributesPath,$testPath)
Check (@($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0) 'Manifest generator, v0/v1 Schemas, dual catalogs, and verifier exist' 'one or more Manifest construction files are missing'

$parseFailures = [System.Collections.Generic.List[string]]::new()
foreach ($path in @($modulePath,$generatorPath,$testPath)) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) { $parseFailures.Add("$path`: $(@($errors | ForEach-Object Message) -join '; ')") }
}
Check ($parseFailures.Count -eq 0) 'all TK-02 PowerShell files parse' "TK-02 PowerShell parse failures: $($parseFailures -join ' | ')"
$bomFailures = @(@($modulePath,$generatorPath,$testPath) | Where-Object { -not (Test-FileHasUtf8Bom -Path $_) })
Check ($bomFailures.Count -eq 0) 'all TK-02 PowerShell files follow the UTF-8 BOM convention' "TK-02 PowerShell BOM failures: $($bomFailures -join ', ')"

$manifestModule = $null
$canonicalModule = $null
try {
    $manifestModule = @(Import-Module $modulePath -Force -PassThru -ErrorAction Stop)[-1]
    $exports = @($manifestModule.ExportedFunctions.Keys | Sort-Object -CaseSensitive)
    Check (($exports -join '|') -ceq 'Assert-HarnessModuleManifestCatalogCurrent|Get-HarnessModuleManifestCatalog') 'Manifest module exports exactly its two construction functions' "Manifest module exports drifted: $($exports -join ', ')"

    $result = Harness.ModuleManifest\Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot
    $repeat = Harness.ModuleManifest\Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot
    Check (Test-BytesEqual -Left $result.Bytes -Right $repeat.Bytes) 'repeated construction is byte-for-byte deterministic' 'Manifest construction output changed between identical runs'

    $expectedModules = @('benchmark','codex-adapter','distribution','entry-kernel','harness-maintenance','legacy-v1','md-html','memory','providers','release-evidence','task-governance','team','thin-trust-kernel')
    $actualModules = @($result.Catalog.modules | ForEach-Object { [string]$_.module_id })
    Check (($actualModules -join '|') -ceq ($expectedModules -join '|')) 'catalog contains the exact 13 mixed-version modules in ordinal order' "module discovery or ordering drifted: $($actualModules -join ', ')"

    $totals = $result.Catalog.totals
    Check ($totals.manifest_count -eq 13 -and $totals.module_count -eq 13 -and $totals.v0_module_count -eq 6 -and $totals.v1_module_count -eq 7 -and $totals.capability_source_count -eq 7 -and $totals.capability_source_file_reference_count -eq 174 -and $totals.owner_test_count -eq 87 -and $totals.core_test_count -eq 56 -and $totals.quick_test_count -eq 1 -and $totals.full_test_count -eq 85 -and $totals.optional_route_count -eq 8) 'catalog totals include the TK-06 D1 verifier: 87 owners, 56 core checks, 85 full checks, and 8 routes' "catalog totals drifted: $($totals | ConvertTo-Json -Compress)"
    Check (@($result.Catalog.unresolved_dependencies).Count -eq 0 -and @($result.Catalog.ownership_conflicts).Count -eq 0) 'constructed catalog has no unresolved dependency or ownership conflict' 'catalog contains unresolved dependencies or ownership conflicts'

    $expectedGroupNames = @('entry-lifecycle','evaluation-release','install-evidence','governance-approval','harness-contracts')
    $actualGroupNames = @($result.Catalog.core_groups.Keys)
    $groupCounts = @($expectedGroupNames | ForEach-Object { @($result.Catalog.core_groups[$_]).Count })
    Check (($actualGroupNames -join '|') -ceq ($expectedGroupNames -join '|') -and ($groupCounts -join '|') -ceq '14|14|4|3|21') 'five stable CoreGroups include TK-06 with exact 14/14/4/3/21 membership' "CoreGroup names or counts drifted: names=$($actualGroupNames -join ',') counts=$($groupCounts -join ',')"
    Check (@($result.Catalog.quick_tests).Count -eq 1 -and [string]$result.Catalog.quick_tests[0] -ceq 'tests/verify-lite-footprint.ps1') 'quick validation derives only verify-lite-footprint' 'quick validation selection drifted'

    $full = Get-OrdinalStrings -Values @($result.Catalog.full_tests)
    $expectedFull = Get-OrdinalStrings -Values @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests') -Filter 'verify-*.ps1' -File | Where-Object Name -cne 'verify-installation.ps1' | ForEach-Object { 'tests/' + $_.Name })
    Check (($full -join '|') -ceq ($expectedFull -join '|')) 'full validation derives every default verifier and excludes only installed-workspace verification' 'full validation set differs from repository verifier inventory'

    $ownerPaths = @($result.Catalog.test_owners | ForEach-Object { [string]$_.path })
    $duplicateOwners = @($ownerPaths | Group-Object -CaseSensitive | Where-Object Count -ne 1)
    Check ($ownerPaths.Count -eq 87 -and $duplicateOwners.Count -eq 0 -and $ownerPaths -ccontains 'tests/verify-capability-extraction.ps1' -and $ownerPaths -ccontains 'tests/verify-installation.ps1' -and $ownerPaths -ccontains 'tests/run-scenario-evals.ps1' -and $ownerPaths -ccontains 'tests/verify-thin-adapters.ps1' -and $ownerPaths -ccontains 'tests/verify-declarative-distribution.ps1') 'every verifier and scenario runner has exactly one owner' 'verifier ownership is incomplete, duplicated, or missing special runners'

    $routeModules = @($result.Catalog.optional_routes | ForEach-Object { [string]$_.module_id })
    $optionalTests = Get-OrdinalStrings -Values @($result.Catalog.optional_routes | ForEach-Object { @($_.tests) } | Select-Object -Unique)
    $coreTests = Get-OrdinalStrings -Values @($expectedGroupNames | ForEach-Object { @($result.Catalog.core_groups[$_]) } | Select-Object -Unique)
    $coreOverlap = @($optionalTests | Where-Object { $coreTests -ccontains $_ })
    Check (($routeModules -join '|') -ceq 'codex-adapter|harness-maintenance|legacy-v1|md-html|memory|providers|team|thin-trust-kernel' -and $optionalTests.Count -eq 38 -and $coreOverlap.Count -eq 8) 'optional routing derives 8 domains, 38 unique checks, and 8 intentional core overlaps' "optional route topology drifted: modules=$($routeModules -join ',') tests=$($optionalTests.Count) overlap=$($coreOverlap.Count)"

    $validFixture = Harness.ModuleManifest\Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot -ManifestRoot 'tests/fixtures/tk02/valid'
    Check ($validFixture.Catalog.schema_version -ceq 'module-manifest-catalog/v0' -and $null -eq $validFixture.CapabilitySourceCatalog -and $validFixture.Catalog.totals.module_count -eq 2 -and @($validFixture.Catalog.unresolved_dependencies).Count -eq 0) 'all-v0 fixture remains byte-contract compatible without a source catalog' 'valid v0 Manifest dependency fixture changed contract or failed construction'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk02/missing-dependency' -Pattern 'does not exist') 'missing module dependency fails construction' 'missing dependency fixture did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk02/missing-reference' -Pattern 'does not exist|tracked regular file') 'missing verifier reference fails construction' 'missing verifier reference fixture did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk02/invalid-schema' -Pattern 'Schema') 'invalid source Schema fails construction' 'invalid source Schema fixture did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk02/duplicate-id' -Pattern 'duplicate') 'duplicate module id fails construction before directory aliasing' 'duplicate module id fixture did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk02/cycle' -Pattern 'cycle') 'dependency cycle fails construction' 'dependency cycle fixture did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk02/overlap' -Pattern 'Owned paths overlap') 'multiple primary path owners fail construction' 'owned-path overlap fixture did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk02/multi-owner' -Pattern 'multiple owners') 'multiple verifier owners fail construction' 'verifier ownership fixture did not fail closed'

    $canonicalModule = @(Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.CanonicalJson.psm1') -Force -PassThru -ErrorAction Stop)[-1]
    $sourceDigestsValid = $true
    foreach ($source in @($result.Catalog.source_manifests)) {
        [byte[]]$sourceBytes = [IO.File]::ReadAllBytes((Join-Path $RepoRoot ([string]$source.path)))
        $digest = Harness.CanonicalJson\Get-HarnessCanonicalJsonSha256 -JsonBytes $sourceBytes
        if ($digest -cne [string]$source.digest) { $sourceDigestsValid = $false; break }
    }
    Check $sourceDigestsValid 'every source Manifest digest uses canonical-json/v1 bytes' 'one or more source Manifest digests do not match canonical-json/v1'

    [byte[]]$trackedBytes = [IO.File]::ReadAllBytes($catalogPath)
    [byte[]]$trackedCapabilitySourceBytes = [IO.File]::ReadAllBytes($capabilitySourceCatalogPath)
    Check (Test-BytesEqual -Left $trackedBytes -Right $result.Bytes) 'tracked catalog matches generated bytes exactly' 'tracked catalog is stale or non-deterministic'
    Check (Test-BytesEqual -Left $trackedCapabilitySourceBytes -Right $result.CapabilitySourceBytes) 'tracked Capability source catalog matches generated bytes exactly' 'tracked Capability source catalog is stale or non-deterministic'
    $noBom = $trackedBytes.Length -lt 3 -or -not ($trackedBytes[0] -eq 0xEF -and $trackedBytes[1] -eq 0xBB -and $trackedBytes[2] -eq 0xBF)
    $oneLf = $trackedBytes.Length -gt 0 -and $trackedBytes[-1] -eq 0x0A -and ($trackedBytes.Length -eq 1 -or $trackedBytes[-2] -ne 0x0A)
    Check ($noBom -and $oneLf) 'catalog is UTF-8 without BOM and ends with exactly one LF' 'catalog encoding or terminal newline contract drifted'
    $attributesText = [IO.File]::ReadAllText($attributesPath)
    $catalogLfRules = @([regex]::Matches($attributesText,'(?m)^/module-manifest-catalog\.json text eol=lf\r?$'))
    $capabilitySourceLfRules = @([regex]::Matches($attributesText,'(?m)^/capability-source-catalog\.json text eol=lf\r?$'))
    Check ($catalogLfRules.Count -eq 1 -and $capabilitySourceLfRules.Count -eq 1) 'Git checkout pins both generated catalogs to LF bytes' 'one or both catalogs are not protected from Windows checkout CRLF conversion'
    $catalogText = [Text.UTF8Encoding]::new($false,$true).GetString($trackedBytes)
    try { $catalogSchemaValid = Test-Json -Json $catalogText -SchemaFile $catalogSchemaPath -ErrorAction Stop -WarningAction SilentlyContinue } catch { $catalogSchemaValid = $false }
    $capabilitySourceCatalogText = [Text.UTF8Encoding]::new($false,$true).GetString($trackedCapabilitySourceBytes)
    try { $capabilitySourceSchemaValid = Test-Json -Json $capabilitySourceCatalogText -SchemaFile $capabilitySourceCatalogSchemaPath -ErrorAction Stop -WarningAction SilentlyContinue } catch { $capabilitySourceSchemaValid = $false }
    Check ($catalogSchemaValid -and $capabilitySourceSchemaValid) 'both tracked catalogs satisfy their strict Schemas' 'one or both tracked catalogs failed Schema validation'

    $catalogWriteTimeBefore = (Get-Item -LiteralPath $catalogPath).LastWriteTimeUtc.Ticks
    $powerShell = (Get-Process -Id $PID -ErrorAction Stop).Path
    $checkOutput = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File $generatorPath -RepoRoot $RepoRoot -Check 2>&1)
    $checkExit = $LASTEXITCODE
    [byte[]]$trackedBytesAfterCheck = [IO.File]::ReadAllBytes($catalogPath)
    [byte[]]$trackedCapabilitySourceBytesAfterCheck = [IO.File]::ReadAllBytes($capabilitySourceCatalogPath)
    $catalogWriteTimeAfter = (Get-Item -LiteralPath $catalogPath).LastWriteTimeUtc.Ticks
    Check ($checkExit -eq 0 -and ($checkOutput -join "`n") -match 'STATUS: PASS' -and (Test-BytesEqual -Left $trackedBytes -Right $trackedBytesAfterCheck) -and (Test-BytesEqual -Left $trackedCapabilitySourceBytes -Right $trackedCapabilitySourceBytesAfterCheck) -and $catalogWriteTimeBefore -eq $catalogWriteTimeAfter) 'generator -Check validates dual tracked bytes with zero writes' 'generator -Check failed or rewrote a tracked catalog'

    $alternateRelative = 'tests/fixtures/tk02/alternate-catalog-output.json'
    $alternateFullPath = Join-Path $RepoRoot $alternateRelative
    if (Test-Path -LiteralPath $alternateFullPath) { throw "unexpected alternate catalog fixture exists: $alternateRelative" }
    Push-Location (Split-Path -Parent $RepoRoot)
    try {
        $alternateOutput = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File $generatorPath -RepoRoot $RepoRoot -OutputPath $alternateRelative -AsJson 2>&1)
        $alternateExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Check ($alternateExit -eq 0 -and ($alternateOutput -join "`n") -ceq $result.CanonicalText -and -not (Test-Path -LiteralPath $alternateFullPath)) 'generator is cwd-independent and -AsJson leaves an alternate contained output path absent' 'generator changed with cwd, emitted different canonical bytes, or wrote during -AsJson'

    $staleRejected = $false
    try { $null = Harness.ModuleManifest\Assert-HarnessModuleManifestCatalogCurrent -RepoRoot $RepoRoot -CatalogPath 'tests/fixtures/tk02/stale-catalog.json' }
    catch { $staleRejected = $_.Exception.Message -match 'does not match generated bytes' }
    Check $staleRejected 'stale tracked catalog bytes fail closed' 'stale catalog fixture was accepted or failed ambiguously'

    $moduleSource = [IO.File]::ReadAllText($modulePath)
    Check ($moduleSource.Contains('Harness.CanonicalJson.psm1',[StringComparison]::Ordinal) -and $moduleSource.Contains('Get-HarnessCanonicalJsonSha256',[StringComparison]::Ordinal) -and $moduleSource -notmatch '(?i)Harness\.(?:Policy|Approval|ControlledWrite)|\b(?:Install|Uninstall)-Harness|default_activation\s*-eq\s*\$true') 'Manifest construction adopts canonical-json/v1 without becoming authorization' 'Manifest construction added an authorization or activation path'
    Check ($moduleSource.Contains('OrdinalIgnoreCase',[StringComparison]::Ordinal) -and $moduleSource.Contains('Resolve-HarnessContainedPath',[StringComparison]::Ordinal) -and $moduleSource.Contains('Tracked and physical Module Manifest sets differ',[StringComparison]::Ordinal)) 'construction binds case-collision, physical-containment, and tracked-set guards' 'case-collision, reparse-containment, or tracked-set guard is missing'
} finally {
    if ($null -ne $canonicalModule) { Remove-Module $canonicalModule.Name -Force -ErrorAction Ignore }
    if ($null -ne $manifestModule) { Remove-Module $manifestModule.Name -Force -ErrorAction Ignore }
}

if ($failures.Count -gt 0) {
    Write-Output "STATUS: FAIL ($($failures.Count) failures)"
    foreach ($failure in $failures) { Write-Output "- $failure" }
    exit 1
}

Write-Output 'STATUS: PASS'
Write-Output 'TK-02 Manifest v0 discovery, ownership, dependency, routing, and catalog checks passed.'
exit 0
