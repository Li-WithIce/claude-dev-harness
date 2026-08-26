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
    'docs/architecture/thin-trust-kernel.md',
    'docs/architecture/hashing-contract.md',
    'docs/architecture/module-manifest.md',
    'docs/architecture/v1-sunset-contract.md',
    'docs/architecture/entry-contract-policy-parity.md',
    'docs/architecture/dependency-enforcement-model.md',
    'kernel-tcb-roots.json',
    'kernel-tcb-inventory.json',
    'kernel-component-classification.json',
    'schemas/kernel-tcb-roots.schema.json',
    'schemas/kernel-tcb.schema.json',
    'schemas/kernel-component-classification.schema.json',
    'schemas/module-manifest.schema.json',
    'scripts/get-kernel-tcb-inventory.ps1',
    'scripts/lib/Harness.Hashing.psm1',
    'tests/verify-hashing-module.ps1',
    'tests/verify-kernel-tcb-inventory.ps1',
    'tests/verify-thin-trust-kernel-contracts.ps1'
)
foreach ($path in $requiredFiles) {
    Check (Test-Path -LiteralPath (Join-Path $RepoRoot $path) -PathType Leaf) "$path exists" "$path is missing"
}

$powerShellPaths = @(
    'scripts/get-kernel-tcb-inventory.ps1',
    'scripts/lib/Harness.Hashing.psm1',
    'tests/verify-hashing-module.ps1',
    'tests/verify-kernel-tcb-inventory.ps1',
    'tests/verify-thin-trust-kernel-contracts.ps1'
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
    'kernel-tcb-roots.json',
    'kernel-tcb-inventory.json',
    'kernel-component-classification.json',
    'schemas/kernel-tcb-roots.schema.json',
    'schemas/kernel-tcb.schema.json',
    'schemas/kernel-component-classification.schema.json',
    'schemas/module-manifest.schema.json'
) + @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\tk00') -Filter '*.json' -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName) })
$jsonBomFailures = @($jsonPaths | Where-Object {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $RepoRoot $_))
    $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
})
Check ($jsonBomFailures.Count -eq 0) 'all architecture JSON files are UTF-8 without BOM' "JSON BOM failures: $($jsonBomFailures -join ', ')"

Check (Test-JsonAgainstSchema -Path 'kernel-tcb-roots.json' -SchemaPath 'schemas/kernel-tcb-roots.schema.json') 'kernel roots document satisfies its strict Schema' 'kernel roots document is invalid'
Check (Test-JsonAgainstSchema -Path 'kernel-tcb-inventory.json' -SchemaPath 'schemas/kernel-tcb.schema.json') 'kernel inventory satisfies its strict Schema' 'kernel inventory is invalid'
Check (Test-JsonAgainstSchema -Path 'kernel-component-classification.json' -SchemaPath 'schemas/kernel-component-classification.schema.json') 'component classification satisfies its strict Schema' 'component classification is invalid'

$manifestSchema = 'schemas/module-manifest.schema.json'
Check (Test-JsonAgainstSchema -Path 'tests/fixtures/tk00/module-manifest-valid.json' -SchemaPath $manifestSchema) 'valid Manifest Phase 0 fixture passes' 'valid Manifest Phase 0 fixture was rejected'
$invalidManifests = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests\fixtures\tk00') -Filter 'module-manifest-invalid-*.json' -File | Sort-Object Name)
$acceptedInvalid = @($invalidManifests | Where-Object { Test-JsonAgainstSchema -Path ([IO.Path]::GetRelativePath($RepoRoot, $_.FullName)) -SchemaPath $manifestSchema } | ForEach-Object Name)
Check ($invalidManifests.Count -ge 10 -and $acceptedInvalid.Count -eq 0) 'all critical invalid Manifest fixtures fail Schema validation' "invalid Manifest fixtures were accepted or missing: $($acceptedInvalid -join ', ')"

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
    'scripts/lib/Harness.Hashing.psm1',
    'Runtime transitive executable LOC < 3000',
    'Entry Contract <= 80 lines and <= 1200 tokens',
    'new module central-file modifications = 0',
    'active Runtime protocol = v2 only',
    'active v1 Runtime reader = 0',
    'status writes = 0',
    '6151'
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
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts\lib') -Filter '*.psm1' -File | ForEach-Object { 'scripts/lib/' + $_.Name }) +
    @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'runtime-hooks') -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace([char]92, [char]47) })
$expectedPaths = Get-OrdinalStrings -Values @($expectedPaths | Select-Object -Unique)
$componentSorted = Get-OrdinalStrings -Values $componentPaths
$missingComponents = @(Compare-Object $expectedPaths $componentSorted -PassThru | Where-Object SideIndicator -eq '<=')
$extraComponents = @(Compare-Object $expectedPaths $componentSorted -PassThru | Where-Object SideIndicator -eq '=>')
$duplicateComponents = @($componentPaths | Group-Object -CaseSensitive | Where-Object Count -gt 1 | ForEach-Object Name)
$staleComponents = @($componentPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_) -PathType Leaf) })
Check ($missingComponents.Count -eq 0 -and $extraComponents.Count -eq 0 -and $duplicateComponents.Count -eq 0 -and $staleComponents.Count -eq 0 -and (Test-OrdinalSorted -Values $componentPaths)) 'classification dynamically covers every target exactly once with no stale path' "classification coverage drifted: missing=$($missingComponents -join ',') extra=$($extraComponents -join ',') duplicate=$($duplicateComponents -join ',') stale=$($staleComponents -join ',')"
Check (@($classification.components | Where-Object { [string]$_.layer -ceq 'k0-trust-primitive' -and [string]$_.path -cin @('scripts/lib/Harness.Path.psm1','scripts/lib/Harness.AtomicWrite.psm1','scripts/lib/Harness.Hashing.psm1') }).Count -eq 3) 'Path, AtomicWrite, and Hashing are the three canonical K0 components' 'canonical K0 component ownership drifted'
$rolloutClassification = @($classification.components | Where-Object { [string]$_.path -ceq 'scripts/lib/Harness.RolloutEvidence.psm1' })
Check ($rolloutClassification.Count -eq 1 -and [string]$rolloutClassification[0].layer -ceq 'c2-capability' -and -not [bool]$rolloutClassification[0].tcb_included) 'RolloutEvidence is honestly classified as C2 and outside Runtime TCB' 'RolloutEvidence classification drifted into Runtime Kernel'
Check (@($classification.components | Where-Object { [string]$_.layer -ceq 'c2-capability' -and [bool]$_.tcb_included }).Count -eq 0) 'no C2 capability is included in the measured Kernel TCB' 'a C2 capability leaked into TCB inclusion'

$entryContractPath = Join-Path $RepoRoot 'policies\entry-contract.md'
$entryContractDigest = Get-LfNormalizedSha256 -Path $entryContractPath
$entryContractLines = @(Get-Content -LiteralPath $entryContractPath).Count
$entryContractBytes = [Text.Encoding]::UTF8.GetByteCount([IO.File]::ReadAllText($entryContractPath))
Check ($entryContractDigest -ceq '346224d62f82926a11bac09335e97766c08b813b71774a714abea924e49ff93e' -and $entryContractLines -eq 15 -and $entryContractBytes -eq 1852) 'TK-00 leaves the canonical Entry Contract byte-for-byte unchanged' 'Entry Contract content, lines, or bytes changed during TK-00'
Check ((Get-LfNormalizedSha256 -Path (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1')) -ceq '774b55f8095b65f289a78adda04e6ee8752ead48a36653384119a393423e27de') 'TK-00 leaves canonical Harness.Path unchanged across checkout line endings' 'Harness.Path changed during TK-00'
$atomicWriteText = Read-Text -Path 'scripts/lib/Harness.AtomicWrite.psm1'
Check ($atomicWriteText.Contains("Harness.Hashing.psm1",[StringComparison]::Ordinal) -and $thinText.Contains('scripts/lib/Harness.Hashing.psm1',[StringComparison]::Ordinal)) 'TK-01A installs Hashing as the canonical K0 dependency of AtomicWrite' 'canonical Hashing ownership or AtomicWrite dependency is missing'
$trackedRealManifests = @(& git -C $RepoRoot ls-files -- '*module.manifest.json')
Check ($trackedRealManifests.Count -eq 0) 'TK-00 creates no real module.manifest.json' 'a real tracked module.manifest.json was created in TK-00'

$validationText = Read-Text -Path 'scripts/run-validation.ps1'
$routingText = Read-Text -Path 'scripts/run-changed-optional-validation.ps1'
Check (@([regex]::Matches($validationText, "'verify-hashing-module\.ps1'")).Count -eq 1 -and @([regex]::Matches($validationText, "'verify-kernel-tcb-inventory\.ps1'")).Count -eq 1 -and @([regex]::Matches($validationText, "'verify-thin-trust-kernel-contracts\.ps1'")).Count -eq 1) 'Hashing and TK-00 verifiers are registered exactly once in central validation' 'architecture verifier registration is missing or duplicated'
$routingTokens = @('docs/architecture/*', 'kernel-tcb-*.json', 'kernel-component-classification.json', 'schemas/*kernel*', 'schemas/module-manifest.schema.json', 'scripts/get-kernel-tcb-inventory.ps1', 'scripts/lib/Harness.Hashing.psm1', 'tests/verify-hashing-module.ps1', 'tests/verify-*kernel*')
$missingRouting = @($routingTokens | Where-Object { -not $routingText.Contains($_, [StringComparison]::Ordinal) })
Check ($missingRouting.Count -eq 0) 'changed-path routing covers every architecture and Hashing surface' "changed-path routing omissions: $($missingRouting -join ', ')"

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
