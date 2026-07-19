[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Check {
    param([bool]$Condition,[string]$Pass,[string]$Fail)
    if ($Condition) { $script:checks++; Write-Output "[PASS] $Pass" } else { $script:failures.Add($Fail) }
}

$pathModule = Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1'
Import-Module $pathModule -Force -ErrorAction Stop
Check ($null -ne (Get-Command ConvertFrom-HarnessJson -Module Harness.Path -ErrorAction SilentlyContinue)) `
    'shared JSON parser is exported by Harness.Path' `
    'shared JSON parser is not exported by Harness.Path'

$json = @'
{
  // Date-like strings must not become DateTime on PowerShell 7.3 or 7.4.
  "iso_z": "2026-07-19T01:02:03Z",
  "iso_offset": "2026-07-19T09:02:03+08:00",
  "plain_date": "2026-07-19",
  "int64": 9223372036854775807,
  "fraction": 1.25,
  "A": 1,
  "a": 2,
  "duplicate": "first",
  "tail": true,
  "duplicate": "last",
  "nested": { "when": "2026-07-19T01:02:03Z" },
  "items": ["2026-07-19T01:02:03Z", null, false],
}
'@
$value = $json | ConvertFrom-HarnessJson -Depth 32
Check ($value -is [System.Collections.IDictionary]) 'root JSON object remains a dictionary' 'root JSON object did not remain a dictionary'
Check (@($value.iso_z,$value.iso_offset,$value.plain_date,$value.nested.when,$value.items[0] | Where-Object { $_ -isnot [string] }).Count -eq 0) `
    'date-like values remain strings at every depth' `
    'a date-like JSON string was coerced to a date type'
Check ($value.int64 -is [long] -and $value.int64 -eq [long]::MaxValue) 'Int64 JSON numbers preserve their type and value' 'Int64 JSON number changed type or value'
Check ($value.fraction -is [double] -and $value.fraction -eq 1.25) 'fractional JSON numbers use Double semantics' 'fractional JSON number changed type or value'
Check ($value.Contains('A') -and $value.Contains('a') -and $value.A -eq 1 -and $value.a -eq 2) `
    'case-distinct JSON keys remain distinct' `
    'case-distinct JSON keys collided'
$keys = @($value.Keys | ForEach-Object { [string]$_ })
$tailIndex = [Array]::IndexOf($keys,'tail')
$duplicateIndex = [Array]::IndexOf($keys,'duplicate')
Check ([string]$value.duplicate -ceq 'last' -and $tailIndex -ge 0 -and $duplicateIndex -eq ($tailIndex + 1)) `
    'an exact duplicate key keeps its last value and last-occurrence order' `
    'exact duplicate key semantics drifted'
Check ($value.items -is [object[]] -and $value.items.Count -eq 3 -and $null -eq $value.items[1] -and $value.items[2] -eq $false) `
    'arrays, null, and booleans retain JSON semantics' `
    'array, null, or boolean JSON semantics drifted'

$single = '["2026-07-19T01:02:03Z"]' | ConvertFrom-HarnessJson
Check ($single -is [string] -and $single -ceq '2026-07-19T01:02:03Z') `
    'a root array keeps native ConvertFrom-Json enumeration semantics' `
    'root array enumeration or date-string semantics drifted'
$blank = '   ' | ConvertFrom-HarnessJson
Check ($null -eq $blank) 'blank JSON input keeps native null semantics' 'blank JSON input did not return null'
$oversizedIntegerRejected = $false
try { [void]('9223372036854775808' | ConvertFrom-HarnessJson) } catch { $oversizedIntegerRejected = $_.Exception.Message -match 'Int64 range' }
Check $oversizedIntegerRejected 'integers that old PowerShell cannot safely re-serialize fail closed' 'an oversized integer could be corrupted by downstream ConvertTo-Json'
$malformedRejected = $false
try { [void]('{"broken":' | ConvertFrom-HarnessJson) } catch { $malformedRejected = $true }
Check $malformedRejected 'malformed JSON is rejected' 'malformed JSON was accepted'
$depthRejected = $false
try { [void]('{"a":{"b":{"c":1}}}' | ConvertFrom-HarnessJson -Depth 2) } catch { $depthRejected = $true }
Check $depthRejected 'configured JSON depth is enforced' 'configured JSON depth was ignored'

$productionPaths = @(
    'scripts/lib/Harness.Approval.psm1','scripts/lib/Harness.Evidence.psm1','scripts/lib/Harness.Governance.psm1',
    'scripts/lib/Harness.ProtectedAction.psm1','scripts/lib/Harness.Protocol.psm1','scripts/lib/Harness.Recovery.psm1',
    'scripts/lib/Harness.RolloutEvidence.psm1','scripts/lib/Harness.TaskState.psm1','scripts/promote-v2-rollout-report.ps1'
)
$dateKindHits = @(
    foreach ($relative in $productionPaths) {
        Select-String -LiteralPath (Join-Path $RepoRoot $relative) -Pattern '-DateKind\s+String' -AllMatches
    }
)
Check ($dateKindHits.Count -eq 0) 'PowerShell 7.5-only DateKind is absent from the v2 production readers' 'a v2 production reader still requires PowerShell 7.5 DateKind'

Write-Output "JSON compatibility checks: $checks"
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Output "- FAIL: $failure" }
    exit 1
}
Write-Output "STATUS: PASS ($checks checks)"
