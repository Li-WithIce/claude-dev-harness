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
function Read-StrictJson {
    param([string]$RelativePath)
    $fullPath = Join-Path $RepoRoot $RelativePath
    $text = [IO.File]::ReadAllText($fullPath, [Text.UTF8Encoding]::new($false, $true))
    return $text | ConvertFrom-Json -AsHashtable -Depth 100
}
function Get-OrdinalStrings {
    param([object[]]$Values)
    [string[]]$result = @($Values | ForEach-Object { [string]$_ })
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return $result
}

$manifestRelative = 'modules/legacy-v1/module.manifest.json'
$manifestPath = Join-Path $RepoRoot $manifestRelative
$classificationPath = Join-Path $RepoRoot 'kernel-component-classification.json'
$schemaPath = Join-Path $RepoRoot 'schemas/module-manifest.schema.json'
Check (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'legacy-v1 Manifest exists' 'legacy-v1 Manifest is missing'
Check (Test-Path -LiteralPath $classificationPath -PathType Leaf) 'component classification exists' 'component classification is missing'

$manifestText = [IO.File]::ReadAllText($manifestPath, [Text.UTF8Encoding]::new($false, $true))
try { $manifestSchemaValid = Test-Json -Json $manifestText -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue } catch { $manifestSchemaValid = $false }
Check $manifestSchemaValid 'legacy-v1 Manifest satisfies harness-module/v0' 'legacy-v1 Manifest failed Schema validation'

$manifest = Read-StrictJson -RelativePath $manifestRelative
Check ([string]$manifest.schema_version -ceq 'harness-module/v0' -and [string]$manifest.module_id -ceq 'legacy-v1' -and [string]$manifest.kind -ceq 'legacy' -and -not [bool]$manifest.default_activation) 'legacy-v1 is explicit and inactive by declaration' 'legacy-v1 identity, kind, Schema version, or default activation drifted'

$expectedPaths = @(
    'scripts/advance-stage.ps1',
    'scripts/lite-artifact-parser.ps1',
    'scripts/migrate-task-v1-to-v2.ps1',
    'scripts/validate-lite-artifacts.ps1'
)
$manifestLegacyPaths = Get-OrdinalStrings -Values @($manifest.ownership.owned_paths | Where-Object { [string]$_ -clike 'scripts/*' })
Check (($manifestLegacyPaths -join '|') -ceq ($expectedPaths -join '|')) 'Manifest names exactly the four active v1 compatibility paths' "legacy-v1 owned path set drifted: $($manifestLegacyPaths -join ', ')"
$missingFiles = @($expectedPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_) -PathType Leaf) })
Check ($missingFiles.Count -eq 0) 'all four Sunset-gated compatibility files remain present' "TK-02 removed active v1 files: $($missingFiles -join ', ')"

$classification = Read-StrictJson -RelativePath 'kernel-component-classification.json'
$legacyEntries = @($classification.components | Where-Object { [string]$_.layer -ceq 'legacy-v1' })
$classifiedPaths = Get-OrdinalStrings -Values @($legacyEntries | ForEach-Object { $_.path })
Check (($classifiedPaths -join '|') -ceq ($expectedPaths -join '|')) 'classification and Manifest agree on the exact legacy-v1 set' "legacy-v1 classification set drifted: $($classifiedPaths -join ', ')"

$expectedTargets = [ordered]@{
    'scripts/advance-stage.ps1' = 'v1-sunset/V1S-08'
    'scripts/lite-artifact-parser.ps1' = 'v1-sunset/V1S-09'
    'scripts/migrate-task-v1-to-v2.ps1' = 'v1-sunset/V1S-10'
    'scripts/validate-lite-artifacts.ps1' = 'v1-sunset/V1S-09'
}
$invalidEntries = @($legacyEntries | Where-Object {
    [string]$_.owner_candidate -cne 'legacy-v1' -or
    [bool]$_.tcb_included -or
    [string]$_.legacy_status -cne 'sunset-gated' -or
    [string]$_.migration_target -cne $expectedTargets[[string]$_.path]
})
Check ($invalidEntries.Count -eq 0) 'legacy-v1 remains outside the TCB and bound to explicit Sunset gates' 'legacy-v1 classification status or Sunset target drifted'

$requested = Get-OrdinalStrings -Values @($manifest.requested_capabilities)
Check ($requested.Count -gt 0 -and -not $requested.Contains('kernel-policy-write')) 'legacy capability declarations remain requests, not Kernel Policy authority' 'legacy-v1 requested an invalid Kernel Policy write capability'

if ($failures.Count -gt 0) {
    Write-Output "STATUS: FAIL ($($failures.Count) failures)"
    foreach ($failure in $failures) { Write-Output "- $failure" }
    exit 1
}

Write-Output 'STATUS: PASS'
Write-Output 'TK-02 legacy-v1 Manifest marker checks passed; no Sunset action was performed.'
exit 0
