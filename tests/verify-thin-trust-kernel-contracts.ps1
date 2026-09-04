[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
function Add-Failure { param([string]$Message) $failures.Add($Message) }
function Check {
    param([bool]$Condition, [string]$Success, [string]$Failure)
    if ($Condition) { Write-Output "[PASS] $Success" } else { Write-Output "[FAIL] $Failure"; Add-Failure $Failure }
}
function Read-Text { param([string]$Path) return [IO.File]::ReadAllText((Join-Path $RepoRoot $Path), [Text.UTF8Encoding]::new($false, $true)) }
function Get-LfNormalizedSha256 {
    param([string]$Path)
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    [void][Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $normalized = [System.Collections.Generic.List[byte]]::new($bytes.Length)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 0x0D) {
            if ($index + 1 -lt $bytes.Length -and $bytes[$index + 1] -eq 0x0A) { $index++ }
            $normalized.Add(0x0A)
        } else {
            $normalized.Add($bytes[$index])
        }
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($normalized.ToArray())).ToLowerInvariant()
}
function Test-JsonAgainstSchema {
    param([string]$Path, [string]$SchemaPath)
    try {
        return Test-Json -Json (Read-Text -Path $Path) -SchemaFile (Join-Path $RepoRoot $SchemaPath) -ErrorAction Stop -WarningAction SilentlyContinue
    } catch { return $false }
}
function Get-OrdinalStrings {
    param([object[]]$Values)
    [string[]]$result = @($Values | ForEach-Object { [string]$_ })
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
}
function Test-OrdinalSorted {
    param([string[]]$Values)
    for ($index = 1; $index -lt $Values.Count; $index++) {
        if ([StringComparer]::Ordinal.Compare($Values[$index - 1], $Values[$index]) -ge 0) { return $false }
    }
    return $true
}

$requiredFiles = @(
    'docs/architecture/declarative-distribution.md',
    'schemas/install-profile.schema.json',
    'schemas/distribution-plan.schema.json',
    'scripts/get-distribution-plan.ps1',
    'scripts/lib/Harness.Distribution.psm1',
    'tests/verify-declarative-distribution.ps1',
    'docs/architecture/thin-trust-kernel.md',
    'docs/architecture/hashing-contract.md',
    'docs/architecture/canonical-json-contract.md',
    'docs/architecture/capability-source.md',
    'docs/architecture/module-manifest.md',
    'docs/architecture/v1-sunset-contract.md',
    'docs/architecture/entry-contract-policy-parity.md',
    'docs/architecture/dependency-enforcement-model.md',
    'kernel-tcb-roots.json',
    'kernel-tcb-inventory.json',
    'kernel-component-classification.json',
    'adapter-inventory.json',
    'capability-source-catalog.json',
    'module-manifest-catalog.json',
    'schemas/kernel-tcb-roots.schema.json',
    'schemas/kernel-tcb.schema.json',
    'schemas/kernel-component-classification.schema.json',
    'schemas/adapter-inventory.schema.json',
    'schemas/adapter-kernel-api.schema.json',
    'schemas/capability-source-binding.schema.json',
    'schemas/capability-source-catalog.schema.json',
    'schemas/capability-source.schema.json',
    'schemas/module-manifest-catalog-v1.schema.json',
    'schemas/module-manifest-catalog.schema.json',
    'schemas/module-manifest-v1.schema.json',
    'schemas/module-manifest.schema.json',
    'scripts/get-kernel-tcb-inventory.ps1',
    'scripts/get-adapter-inventory.ps1',
    'scripts/get-module-manifest-catalog.ps1',
    'scripts/lib/Harness.CapabilitySource.psm1',
    'scripts/lib/Harness.CanonicalJson.psm1',
    'scripts/lib/Harness.Hashing.psm1',
    'scripts/lib/Harness.ModuleManifest.psm1',
    'scripts/write-capability-source-binding.ps1',
    'tests/verify-capability-extraction.ps1',
    'tests/verify-canonical-json.ps1',
    'tests/verify-hashing-module.ps1',
    'tests/verify-kernel-tcb-inventory.ps1',
    'tests/verify-module-manifest-catalog.ps1',
    'tests/verify-thin-trust-kernel-contracts.ps1',
    'tests/verify-thin-adapters.ps1',
    'tests/verify-v1-manifest-marker.ps1'
)
foreach ($path in $requiredFiles) {
    Check (Test-Path -LiteralPath (Join-Path $RepoRoot $path) -PathType Leaf) "$path exists" "$path is missing"
}

$powerShellPaths = @(
    'scripts/get-distribution-plan.ps1',
    'scripts/lib/Harness.Distribution.psm1',
    'tests/verify-declarative-distribution.ps1',
    'scripts/get-adapter-inventory.ps1',
    'scripts/get-kernel-tcb-inventory.ps1',
    'scripts/get-module-manifest-catalog.ps1',
    'scripts/lib/Harness.CapabilitySource.psm1',
    'scripts/lib/Harness.CanonicalJson.psm1',
    'scripts/lib/Harness.Hashing.psm1',
    'scripts/lib/Harness.ModuleManifest.psm1',
    'scripts/write-capability-source-binding.ps1',
    'tests/verify-capability-extraction.ps1',
    'tests/verify-canonical-json.ps1',
    'tests/verify-hashing-module.ps1',
    'tests/verify-kernel-tcb-inventory.ps1',
    'tests/verify-module-manifest-catalog.ps1',
    'tests/verify-thin-trust-kernel-contracts.ps1',
    'tests/verify-thin-adapters.ps1',
    'tests/verify-v1-manifest-marker.ps1'
) + @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\tk00\tcb') -File | Where-Object { $_.Extension -cin @('.ps1', '.psm1') } | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName) })
$parseFailures = [System.Collections.Generic.List[string]]::new()
$bomFailures = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $powerShellPaths) {
    $fullPath = Join-Path $RepoRoot $relative
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { $parseFailures.Add("${relative}: $(@($errors | ForEach-Object Message) -join '; ')") }
    if (-not (Test-FileHasUtf8Bom -Path $fullPath)) { $bomFailures.Add($relative) }
}
Check ($parseFailures.Count -eq 0) 'all architecture PowerShell files parse' "PowerShell parse failures: $($parseFailures -join ' | ')"
Check ($bomFailures.Count -eq 0) 'all architecture PowerShell files follow the UTF-8 BOM convention' "PowerShell BOM failures: $($bomFailures -join ', ')"

$jsonPaths = @(
    'schemas/install-profile.schema.json',
    'schemas/distribution-plan.schema.json',
    'modules/distribution/profiles/core.json',
    'modules/distribution/profiles/governed.json',
    'modules/distribution/profiles/full.json',
    'adapter-inventory.json',
    'kernel-tcb-roots.json',
    'kernel-tcb-inventory.json',
    'kernel-component-classification.json',
    'capability-source-catalog.json',
    'module-manifest-catalog.json',
    'schemas/kernel-tcb-roots.schema.json',
    'schemas/kernel-tcb.schema.json',
    'schemas/kernel-component-classification.schema.json',
    'schemas/adapter-inventory.schema.json',
    'schemas/adapter-kernel-api.schema.json',
    'schemas/capability-source-binding.schema.json',
    'schemas/capability-source-catalog.schema.json',
    'schemas/capability-source.schema.json',
    'schemas/module-manifest-catalog-v1.schema.json',
    'schemas/module-manifest-catalog.schema.json',
    'schemas/module-manifest-v1.schema.json',
    'schemas/module-manifest.schema.json'
) + @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'modules') -Filter 'module.manifest.json' -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName) }) +
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\tk00') -Filter '*.json' -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName) }) +
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\tk02') -Filter '*.json' -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName) }) +
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\tk04') -Filter '*.json' -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName) })
$jsonBomFailures = @($jsonPaths | Where-Object {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $RepoRoot $_))
    $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
})
Check ($jsonBomFailures.Count -eq 0) 'all architecture JSON files are UTF-8 without BOM' "JSON BOM failures: $($jsonBomFailures -join ', ')"

Check (Test-JsonAgainstSchema -Path 'kernel-tcb-roots.json' -SchemaPath 'schemas/kernel-tcb-roots.schema.json') 'kernel roots document satisfies its strict Schema' 'kernel roots document is invalid'
Check (Test-JsonAgainstSchema -Path 'kernel-tcb-inventory.json' -SchemaPath 'schemas/kernel-tcb.schema.json') 'kernel inventory satisfies its strict Schema' 'kernel inventory is invalid'
Check (Test-JsonAgainstSchema -Path 'kernel-component-classification.json' -SchemaPath 'schemas/kernel-component-classification.schema.json') 'component classification satisfies its strict Schema' 'component classification is invalid'
Check (Test-JsonAgainstSchema -Path 'module-manifest-catalog.json' -SchemaPath 'schemas/module-manifest-catalog-v1.schema.json') 'mixed Manifest catalog satisfies its strict v1 Schema' 'mixed Manifest catalog is invalid'
Check (Test-JsonAgainstSchema -Path 'capability-source-catalog.json' -SchemaPath 'schemas/capability-source-catalog.schema.json') 'Capability source catalog satisfies its strict Schema' 'Capability source catalog is invalid'

$manifestSchema = 'schemas/module-manifest.schema.json'
Check (Test-JsonAgainstSchema -Path 'tests/fixtures/tk00/module-manifest-valid.json' -SchemaPath $manifestSchema) 'valid Manifest Phase 0 fixture passes' 'valid Manifest Phase 0 fixture was rejected'
$invalidManifests = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\tk00') -Filter 'module-manifest-invalid-*.json' -File | Sort-Object Name)
$acceptedInvalid = @($invalidManifests | Where-Object { Test-JsonAgainstSchema -Path ([IO.Path]::GetRelativePath($RepoRoot, $_.FullName)) -SchemaPath $manifestSchema } | ForEach-Object Name)
Check ($invalidManifests.Count -ge 10 -and $acceptedInvalid.Count -eq 0) 'all critical invalid Manifest fixtures fail Schema validation' "invalid Manifest fixtures were accepted or missing: $($acceptedInvalid -join ', ')"
$productionManifests = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'modules') -Filter 'module.manifest.json' -File -Recurse | Sort-Object FullName)
$invalidProductionManifests = @($productionManifests | Where-Object {
    $relative = [IO.Path]::GetRelativePath($RepoRoot, $_.FullName)
    $document = Read-Text -Path $relative | ConvertFrom-Json -Depth 20
    $schema = if ([string]$document.schema_version -ceq 'harness-module/v1') { 'schemas/module-manifest-v1.schema.json' } else { $manifestSchema }
    -not (Test-JsonAgainstSchema -Path $relative -SchemaPath $schema)
} | ForEach-Object FullName)
$v1ProductionCount = @($productionManifests | Where-Object { (Read-Text -Path ([IO.Path]::GetRelativePath($RepoRoot,$_.FullName)) | ConvertFrom-Json -Depth 20).schema_version -ceq 'harness-module/v1' }).Count
Check ($productionManifests.Count -eq 13 -and $v1ProductionCount -eq 7 -and $invalidProductionManifests.Count -eq 0) 'all 13 real Manifests satisfy their frozen v0 or v1 source Schema, with exactly seven v1 Capabilities' "real Manifest inventory or Schema validity drifted: $($invalidProductionManifests -join ', ')"

$manifestText = Read-Text -Path 'docs/architecture/module-manifest.md'
$manifestRequirements = @(
    'harness-module/v0',
    'requested_capabilities intersect profile.allowed_capabilities',
    'entry-lifecycle',
    'evaluation-release',
    'install-evidence',
    'governance-approval',
    'harness-contracts',
    'A Manifest can never self-authorize',
    'tracked regular file',
    'execute zero tests'
)
$missingManifestRequirements = @($manifestRequirements | Where-Object { -not $manifestText.Contains($_, [StringComparison]::Ordinal) })
Check ($missingManifestRequirements.Count -eq 0) 'Manifest contract freezes authorization, ownership, discovery, and five CoreGroups' "Manifest contract omissions: $($missingManifestRequirements -join ', ')"

$thinText = Read-Text -Path 'docs/architecture/thin-trust-kernel.md'
$thinHeadings = @(
    '## Status and purpose',
    '## Two trust paths',
    '## K0 — Trust Primitives',
    '## K1 — Runtime Trust Kernel',
    '## D1 — Distribution Reconciler',
    '## C2 — Capability Modules',
    '## A3 — Host Adapters',
    '## legacy-v1',
    '## Dependency directions',
    '## Reproducible TCB inventory',
    '## Executable LOC contract',
    '## Runtime TCB budget ratchet',
    '## Terminal SLOs'
)
$missingThinHeadings = @($thinHeadings | Where-Object { -not $thinText.Contains($_, [StringComparison]::Ordinal) })
$thinTokens = @(
    'scripts/lib/Harness.Path.psm1',
    'scripts/lib/Harness.AtomicWrite.psm1',
    'scripts/lib/Harness.CanonicalJson.psm1',
    'scripts/lib/Harness.Hashing.psm1',
    'scripts/lib/Harness.ModuleManifest.psm1',
    'Runtime transitive executable LOC < 3000',
    'Entry Contract <= 80 lines and <= 1200 tokens',
    'new module central-file modifications = 0',
    'active Runtime protocol = v2 only',
    'active v1 Runtime reader = 0',
    'status writes = 0',
    '2999'
)
$missingThinTokens = @($thinTokens | Where-Object { -not $thinText.Contains($_, [StringComparison]::Ordinal) })
Check ($missingThinHeadings.Count -eq 0 -and $missingThinTokens.Count -eq 0) 'Thin Trust Kernel document freezes layers, paths, budget, and terminal SLOs' "Thin Trust Kernel omissions: $($missingThinHeadings + $missingThinTokens -join ', ')"
Check ($thinText -notmatch '(?m)^\|\s*(?:scripts|runtime-hooks)/') 'human architecture summary does not duplicate the complete classification table' 'architecture document contains a second complete manual classification table'

$sunsetText = Read-Text -Path 'docs/architecture/v1-sunset-contract.md'
$sunsetRows = [regex]::Matches($sunsetText, '(?m)^\| V1S-(?<id>\d{2}) \|.*\| (?<status>not_met|partial|met) \|\s*$')
$sunsetIds = @($sunsetRows | ForEach-Object { $_.Groups['id'].Value })
Check ($sunsetRows.Count -eq 10 -and ($sunsetIds -join '|') -ceq '01|02|03|04|05|06|07|08|09|10') 'v1 Sunset defines V1S-01 through V1S-10 with allowed current statuses' 'v1 Sunset gate set or status vocabulary drifted'
Check ($sunsetText.Contains('user must separately authorize', [StringComparison]::Ordinal) -and $sunsetText.Contains('TK-00 does not execute Sunset', [StringComparison]::Ordinal)) 'v1 Sunset remains contract-only and separately authorized' 'v1 Sunset text implies execution or date-based authorization'

$parityText = Read-Text -Path 'docs/architecture/entry-contract-policy-parity.md'
$parityRows = [regex]::Matches($parityText, '(?m)^\| EC-(?<id>\d{2}) \|.*\| (?<status>enforced|partially_enforced|prose_only|not_applicable) \|')
$parityIds = @($parityRows | ForEach-Object { $_.Groups['id'].Value })
Check ($parityRows.Count -eq 13 -and ($parityIds -join '|') -ceq '01|02|03|04|05|06|07|08|09|10|11|12|13') 'Entry Contract parity maps EC-01 through EC-13 with the closed status vocabulary' 'Entry Contract parity rules or statuses drifted'
Check ($parityText.Contains('Tests and documentation are evidence of a contract, not enforcement.', [StringComparison]::Ordinal) -and $parityText.Contains('No TK-00 rule is marked eligible for removal.', [StringComparison]::Ordinal)) 'parity contract does not mislabel tests or prose as enforcement' 'parity contract overstates enforcement or removal eligibility'

$dependencyText = Read-Text -Path 'docs/architecture/dependency-enforcement-model.md'
$controlTokens = @('## Dependency direction', '## Install asset authorization', '## Runtime enforcement', 'git grep` is not an', 'Hook is a guardrail, not an operating-system sandbox')
$missingControlTokens = @($controlTokens | Where-Object { -not $dependencyText.Contains($_, [StringComparison]::Ordinal) })
Check ($missingControlTokens.Count -eq 0) 'dependency, install authorization, and Runtime enforcement remain distinct controls' "control model omissions: $($missingControlTokens -join ', ')"

$classification = Read-Text -Path 'kernel-component-classification.json' | ConvertFrom-Json -AsHashtable -Depth 100
$componentPaths = @($classification.components | ForEach-Object { [string]$_.path })
$expectedPaths = @(
    'harness.ps1',
    'install.ps1',
    'uninstall.ps1',
    'tests/fixture-test-common.ps1',
    'tests/verify-installation.ps1'
) + @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -Filter '*.ps1' -File | ForEach-Object { 'scripts/' + $_.Name }) +
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts\lib') -Filter '*.ps1' -File | ForEach-Object { 'scripts/lib/' + $_.Name }) +
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts\lib') -Filter '*.psm1' -File | ForEach-Object { 'scripts/lib/' + $_.Name }) +
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'modules') -Filter '*.psm1' -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace([char]92, [char]47) }) +
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'runtime-hooks') -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace([char]92, [char]47) })
$expectedPaths = Get-OrdinalStrings -Values @($expectedPaths | Select-Object -Unique)
$componentSorted = Get-OrdinalStrings -Values $componentPaths
$missingComponents = @(Compare-Object $expectedPaths $componentSorted -PassThru | Where-Object SideIndicator -eq '<=')
$extraComponents = @(Compare-Object $expectedPaths $componentSorted -PassThru | Where-Object SideIndicator -eq '=>')
$duplicateComponents = @($componentPaths | Group-Object -CaseSensitive | Where-Object Count -gt 1 | ForEach-Object Name)
$staleComponents = @($componentPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_) -PathType Leaf) })
Check ($missingComponents.Count -eq 0 -and $extraComponents.Count -eq 0 -and $duplicateComponents.Count -eq 0 -and $staleComponents.Count -eq 0 -and (Test-OrdinalSorted -Values $componentPaths)) 'classification dynamically covers every target exactly once with no stale path' "classification coverage drifted: missing=$($missingComponents -join ',') extra=$($extraComponents -join ',') duplicate=$($duplicateComponents -join ',') stale=$($staleComponents -join ',')"
Check (@($classification.components | Where-Object { [string]$_.layer -ceq 'k0-trust-primitive' -and [string]$_.path -cin @('scripts/lib/Harness.Path.psm1','scripts/lib/Harness.AtomicWrite.psm1','scripts/lib/Harness.CanonicalJson.psm1','scripts/lib/Harness.Hashing.psm1') }).Count -eq 4) 'Path, AtomicWrite, CanonicalJson, and Hashing are the four canonical K0 components' 'canonical K0 component ownership drifted'
$canonicalClassification = @($classification.components | Where-Object { [string]$_.path -ceq 'scripts/lib/Harness.CanonicalJson.psm1' })
Check ($canonicalClassification.Count -eq 1 -and [string]$canonicalClassification[0].layer -ceq 'k0-trust-primitive' -and [bool]$canonicalClassification[0].tcb_included) 'TK-06 explicitly adopts CanonicalJson on the Distribution trust path' 'CanonicalJson classification or current TCB reachability drifted'
$rolloutClassification = @($classification.components | Where-Object { [string]$_.path -ceq 'scripts/lib/Harness.RolloutEvidence.psm1' })
Check ($rolloutClassification.Count -eq 1 -and [string]$rolloutClassification[0].layer -ceq 'c2-capability' -and -not [bool]$rolloutClassification[0].tcb_included) 'RolloutEvidence is honestly classified as C2 and outside Runtime TCB' 'RolloutEvidence classification drifted into Runtime Kernel'
$manifestConstructionPaths = @('scripts/get-module-manifest-catalog.ps1','scripts/lib/Harness.CapabilitySource.psm1','scripts/lib/Harness.ModuleManifest.psm1')
$manifestConstructionClassification = @($classification.components | Where-Object { [string]$_.path -cin $manifestConstructionPaths })
Check ($manifestConstructionClassification.Count -eq 3 -and @($manifestConstructionClassification | Where-Object { [string]$_.layer -cne 'c2-capability' -or [bool]$_.tcb_included -or [string]$_.owner_candidate -cne 'engineering-validation' }).Count -eq 0) 'Manifest generator, constructor, and source consumer are C2 engineering components outside Runtime TCB' 'Manifest construction classification leaked into Runtime TCB or another owner'
Check (@($classification.components | Where-Object { [string]$_.layer -ceq 'c2-capability' }).Count -eq 43) 'classification contains the earlier C2 paths plus the TK-07 validation-process helper' 'C2 classification count drifted'
Check (@($classification.components | Where-Object { [string]$_.layer -ceq 'c2-capability' -and [bool]$_.tcb_included }).Count -eq 0) 'no C2 capability is included in the measured Kernel TCB' 'a C2 capability leaked into TCB inclusion'

$entryContractPath = Join-Path $RepoRoot 'policies\entry-contract.md'
$entryContractDigest = Get-LfNormalizedSha256 -Path $entryContractPath
$entryContractLines = @(Get-Content -LiteralPath $entryContractPath).Count
$entryContractBytes = [Text.Encoding]::UTF8.GetByteCount([IO.File]::ReadAllText($entryContractPath))
Check ($entryContractDigest -ceq '4838491707510140a0c698ac26d0faa8b45d6dde90d03427dc78006f0643396c' -and $entryContractLines -eq 16 -and $entryContractBytes -eq 2052) 'TK-03 freezes the explicitly confirmed v2-only Entry Contract' 'Entry Contract differs from the confirmed TK-03 admission boundary'
Check ((Get-LfNormalizedSha256 -Path (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1')) -ceq '6a3e0abef8a96cee16c388e3bc584376484ee676289d3fdf0ba0bc1d7fcd6363') 'TK-07 binds the simplified canonical Harness.Path source across checkout line endings' 'Harness.Path differs from the TK-07 canonical source'
$atomicWriteText = Read-Text -Path 'scripts/lib/Harness.AtomicWrite.psm1'
Check ($atomicWriteText.Contains("Harness.Hashing.psm1",[StringComparison]::Ordinal) -and $thinText.Contains('scripts/lib/Harness.Hashing.psm1',[StringComparison]::Ordinal)) 'TK-01A installs Hashing as the canonical K0 dependency of AtomicWrite' 'canonical Hashing ownership or AtomicWrite dependency is missing'
$canonicalText = Read-Text -Path 'docs/architecture/canonical-json-contract.md'
Check ($canonicalText.Contains('canonical-json/v1',[StringComparison]::Ordinal) -and $canonicalText.Contains('-9007199254740991',[StringComparison]::Ordinal) -and $canonicalText.Contains('UTF-8 without a BOM',[StringComparison]::Ordinal) -and $canonicalText.Contains('TK-02 is', [StringComparison]::Ordinal) -and $canonicalText.Contains('TK-06 explicitly adopts', [StringComparison]::Ordinal) -and $canonicalText.Contains('distribution-plan/v1',[StringComparison]::Ordinal)) 'canonical-json/v1 retains its algorithm and records explicit D1 adoption without historical migration' 'canonical-json/v1 architecture or adoption boundary is incomplete'
$trackedRealManifests = @(& git -C $RepoRoot ls-files -- 'modules/*/module.manifest.json')
$expectedRealManifests = @($productionManifests | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot,$_.FullName).Replace([char]92,[char]47) } | Sort-Object -CaseSensitive)
Check ($trackedRealManifests.Count -eq 13 -and (($trackedRealManifests | Sort-Object -CaseSensitive) -join '|') -ceq ($expectedRealManifests -join '|')) 'TK-04 tracks exactly the 13 real mixed-version module.manifest.json inputs' 'real tracked Manifest discovery set drifted'

$validationText = Read-Text -Path 'scripts/run-validation.ps1'
$routingText = Read-Text -Path 'scripts/run-changed-optional-validation.ps1'
$catalog = Read-Text -Path 'module-manifest-catalog.json' | ConvertFrom-Json -AsHashtable -Depth 100
$thinRoute = @($catalog.optional_routes | Where-Object { [string]$_.module_id -ceq 'thin-trust-kernel' })
$thinRouteTests = if ($thinRoute.Count -eq 1) { @($thinRoute[0].tests | ForEach-Object { Split-Path -Leaf ([string]$_) }) } else { @() }
$expectedThinRouteTests = @('verify-canonical-json.ps1','verify-hashing-module.ps1','verify-kernel-tcb-inventory.ps1','verify-module-manifest-catalog.ps1','verify-thin-trust-kernel-contracts.ps1')
$validationCatalogIndex = $validationText.IndexOf('Assert-HarnessModuleManifestCatalogCurrent',[StringComparison]::Ordinal)
$validationRunIndex = $validationText.IndexOf('Add-GitCheck -Checks',[StringComparison]::Ordinal)
$routingCatalogIndex = $routingText.IndexOf('Assert-HarnessModuleManifestCatalogCurrent',[StringComparison]::Ordinal)
$routingRunIndex = $routingText.IndexOf('foreach ($testName in $testNames)',[StringComparison]::Ordinal)
Check ($validationText.Contains('Catalog.core_groups',[StringComparison]::Ordinal) -and $validationText.Contains('Catalog.quick_tests',[StringComparison]::Ordinal) -and $validationText.Contains('Catalog.full_tests',[StringComparison]::Ordinal) -and $validationCatalogIndex -ge 0 -and $validationRunIndex -gt $validationCatalogIndex) 'central validation derives all suites after fail-closed catalog construction' 'central validation contains a manual suite table or schedules checks before catalog construction'
Check ($routingText.Contains('Catalog.optional_routes',[StringComparison]::Ordinal) -and $routingText -notmatch '\[ordered\]@\{name=' -and $routingCatalogIndex -ge 0 -and $routingRunIndex -gt $routingCatalogIndex -and ($thinRouteTests -join '|') -ceq ($expectedThinRouteTests -join '|')) 'changed-path routing derives the exact thin-kernel route after fail-closed construction' 'changed-path routing contains a manual module table, wrong thin-kernel route, or unsafe execution order'

$tkPaths = @($requiredFiles + $jsonPaths + $powerShellPaths + @(
    'tests/fixtures/tk00/module-manifest-valid.json',
    'docs/architecture/module-manifest.md',
    'docs/architecture/v1-sunset-contract.md',
    'docs/architecture/entry-contract-policy-parity.md',
    'docs/architecture/dependency-enforcement-model.md'
) | Select-Object -Unique)
$absoluteLeaks = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $tkPaths) {
    $fullPath = Join-Path $RepoRoot $relative
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
    $text = [IO.File]::ReadAllText($fullPath)
    if ($text -match '(?i)(?:^|[\s''"=])[A-Z]:[\\/]' -or $text -match '(?i)(?:^|[\s''"=])\\\\[A-Za-z0-9._-]+[\\/]') { $absoluteLeaks.Add($relative) }
}
Check ($absoluteLeaks.Count -eq 0) 'architecture tracked artifacts contain no absolute local or UNC path' "absolute path leaks: $($absoluteLeaks -join ', ')"

if ($failures.Count -gt 0) {
    Write-Output "STATUS: FAIL ($($failures.Count) failures)"
    foreach ($failure in $failures) { Write-Output "- $failure" }
    exit 1
}

Write-Output 'STATUS: PASS'
Write-Output "Thin Trust Kernel contracts passed; components=$($classification.components.Count); manifest_invalid_fixtures=$($invalidManifests.Count)"
exit 0
