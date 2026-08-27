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

$script:Utf8 = [System.Text.UTF8Encoding]::new($false, $true)
function Get-CanonicalBytes {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    [byte[]]$result = Harness.CanonicalJson\ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $script:Utf8.GetBytes($Json)
    Write-Output -NoEnumerate $result
}
function Get-CanonicalText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    return $script:Utf8.GetString((Get-CanonicalBytes -Json $Json))
}
function Test-CanonicalRejection {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [string]$Pattern = ''
    )
    try {
        $null = Harness.CanonicalJson\ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $Bytes
        return $false
    } catch {
        return [string]::IsNullOrWhiteSpace($Pattern) -or $_.Exception.Message -match $Pattern
    }
}

$canonicalRelative = 'scripts/lib/Harness.CanonicalJson.psm1'
$hashingRelative = 'scripts/lib/Harness.Hashing.psm1'
$canonicalPath = Join-Path $RepoRoot $canonicalRelative
$hashingPath = Join-Path $RepoRoot $hashingRelative
$testPath = Join-Path $RepoRoot 'tests/verify-canonical-json.ps1'
$parseFailures = [System.Collections.Generic.List[string]]::new()
foreach ($path in @($canonicalPath, $hashingPath, $testPath)) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { $parseFailures.Add("$path`: $(@($errors | ForEach-Object Message) -join '; ')") }
}
Check ($parseFailures.Count -eq 0) 'Canonical JSON, Hashing, and verifier PowerShell files parse' "PowerShell parse failures: $($parseFailures -join ' | ')"
Check (Test-FileHasUtf8Bom -Path $canonicalPath) 'Canonical JSON module follows the repository UTF-8 BOM convention' 'Canonical JSON module lacks the repository UTF-8 BOM'

$canonicalModule = $null
$hashingModule = $null
try {
    $canonicalModule = @(Import-Module $canonicalPath -Force -PassThru -ErrorAction Stop)[-1]
    $hashingModule = @(Import-Module $hashingPath -Force -PassThru -ErrorAction Stop)[-1]
    $canonicalExports = @($canonicalModule.ExportedFunctions.Keys | Sort-Object -CaseSensitive)
    $hashingExports = @($hashingModule.ExportedFunctions.Keys | Sort-Object -CaseSensitive)
    Check (($canonicalExports -join '|') -ceq 'ConvertTo-HarnessCanonicalJsonBytes|Get-HarnessCanonicalJsonSha256') 'Canonical JSON exports exactly the approved two functions' "Canonical JSON exports drifted: $($canonicalExports -join ', ')"
    Check (($hashingExports -join '|') -ceq 'Get-HarnessFileSha256|Get-HarnessNormalizedTextSha256|Get-HarnessSha256Bytes|Get-HarnessUtf8TextSha256') 'Hashing remains an exact four-function primitive' "Hashing exports drifted: $($hashingExports -join ', ')"

    [byte[]]$emptyObjectBytes = Get-CanonicalBytes -Json " `r`n { } `t"
    Check ($emptyObjectBytes -is [byte[]] -and ($emptyObjectBytes -join ',') -ceq '123,125') 'empty object emits exactly the byte array 7B 7D' 'empty object output type or bytes drifted'
    Check ($emptyObjectBytes.Length -eq 2 -and -not ($emptyObjectBytes.Length -ge 3 -and $emptyObjectBytes[0] -eq 0xEF -and $emptyObjectBytes[1] -eq 0xBB -and $emptyObjectBytes[2] -eq 0xBF) -and $emptyObjectBytes[-1] -ne 0x0A) 'canonical output has no BOM or terminal LF' 'canonical output added a BOM or terminal LF'

    $nestedA = '{"z":0,"b":[{"z":0,"a":true},2,1],"a":null}'
    $nestedB = '{"a":null,"b":[{"a":true,"z":0},2.0,1e0],"z":-0}'
    $nestedExpected = '{"a":null,"b":[{"a":true,"z":0},2,1],"z":0}'
    Check ((Get-CanonicalText -Json $nestedA) -ceq $nestedExpected -and (Get-CanonicalText -Json $nestedB) -ceq $nestedExpected) 'recursive object ordering converges while array order remains unchanged' 'nested object ordering, numeric normalization, or array ordering drifted'

    $rfcSortInput = '{"\u20ac":"Euro Sign","\r":"Carriage Return","\ufb33":"Hebrew Letter Dalet With Dagesh","1":"One","\ud83d\ude00":"Emoji: Grinning Face","\u0080":"Control","\u00f6":"Latin Small Letter O With Diaeresis"}'
    $rfcSortExpected = '{"\r":"Carriage Return","1":"One","' + [char]0x0080 + '":"Control","ö":"Latin Small Letter O With Diaeresis","€":"Euro Sign","😀":"Emoji: Grinning Face","דּ":"Hebrew Letter Dalet With Dagesh"}'
    Check ((Get-CanonicalText -Json $rfcSortInput) -ceq $rfcSortExpected) 'RFC 8785 UTF-16 property-order vector matches exactly' 'RFC 8785 UTF-16 property ordering drifted'

    $stringInput = '"€\u000F\n雪\/\"\\\ud83d\ude00"'
    $stringExpected = '"€\u000f\n雪/\"\\😀"'
    Check ((Get-CanonicalText -Json $stringInput) -ceq $stringExpected) 'JCS strings use lowercase control escapes and preserve slash and Unicode' 'JCS string escaping, slash handling, or Unicode preservation drifted'

    $composed = Get-CanonicalText -Json '"é"'
    $decomposed = Get-CanonicalText -Json '"e\u0301"'
    $decomposedExpected = '"e' + [char]0x0301 + '"'
    Check ([StringComparer]::Ordinal.Equals($composed, '"é"') -and
        [StringComparer]::Ordinal.Equals($decomposed, $decomposedExpected) -and
        -not [StringComparer]::Ordinal.Equals($composed, $decomposed)) 'Unicode normalization forms are preserved as distinct byte sequences' 'canonical JSON normalized or merged distinct Unicode sequences'
    Check ((Get-CanonicalText -Json '"\ud83d\ude00"') -ceq '"😀"' -and (Get-CanonicalText -Json '"😀"') -ceq '"😀"') 'escaped and raw astral Unicode converge to the same scalar bytes' 'astral Unicode escape handling drifted'

    Check ((Get-CanonicalText -Json '{"a":1,"A":2}') -ceq '{"A":2,"a":1}') 'property names remain case-sensitive and use ordinal ordering' 'case-sensitive property ordering drifted'
    Check (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('{"a":1,"\u0061":2}') -Pattern 'duplicate') 'duplicate decoded property names are rejected' 'escaped duplicate property names were accepted or failed ambiguously'
    Check (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('{"outer":{"x":1,"x":2}}') -Pattern 'duplicate') 'nested duplicate property names are rejected' 'nested duplicate property names were accepted or failed ambiguously'

    $numberInput = '{"d":9007199254740991,"c":-0,"b":1e0,"a":1.0}'
    $numberExpected = '{"a":1,"b":1,"c":0,"d":9007199254740991}'
    Check ((Get-CanonicalText -Json $numberInput) -ceq $numberExpected -and
        (Get-CanonicalText -Json '-9007199254740991.0') -ceq '-9007199254740991' -and
        (Get-CanonicalText -Json '1E+0') -ceq '1') 'binary64 safe integers emit canonical decimal values including minus zero' 'safe integer parsing or canonical decimal output drifted'
    Check (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('1.5') -Pattern 'safe integer') 'fractional binary64 values are rejected' 'fractional value was accepted or failed ambiguously'
    Check (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('9007199254740992') -Pattern 'safe integer') 'positive unsafe integers are rejected' 'positive unsafe integer was accepted or failed ambiguously'
    Check (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('-9007199254740992') -Pattern 'safe integer') 'negative unsafe integers are rejected' 'negative unsafe integer was accepted or failed ambiguously'
    Check (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('1e400') -Pattern 'finite') 'non-finite binary64 results are rejected' 'non-finite binary64 result was accepted or failed ambiguously'

    [byte[]]$bomInput = @(0xEF,0xBB,0xBF) + $script:Utf8.GetBytes('{}')
    Check (Test-CanonicalRejection -Bytes $bomInput -Pattern 'BOM') 'UTF-8 BOM input is rejected' 'BOM-bearing input was accepted or failed ambiguously'
    Check (Test-CanonicalRejection -Bytes ([byte[]](0x22,0xC3,0x28,0x22)) -Pattern 'UTF-8') 'malformed UTF-8 input is rejected' 'malformed UTF-8 was accepted or failed ambiguously'
    Check (Test-CanonicalRejection -Bytes ([byte[]]::new(0)) -Pattern 'invalid') 'empty input is rejected as invalid JSON' 'empty input was accepted or failed ambiguously'
    Check ((Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('{"a":1,}') -Pattern 'invalid') -and
        (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('{"a":1/*comment*/}') -Pattern 'invalid')) 'trailing commas and comments are rejected' 'non-strict JSON syntax was accepted or failed ambiguously'
    Check ((Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('"\uD800"') -Pattern 'lone high-surrogate') -and
        (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes('"\uDEAD"') -Pattern 'lone low-surrogate')) 'lone surrogate escapes are rejected before lossy parsing' 'lone surrogate escape was accepted or failed ambiguously'

    $depth64 = ('[' * 64) + '0' + (']' * 64)
    $depth65 = ('[' * 65) + '0' + (']' * 65)
    Check ((Get-CanonicalText -Json $depth64) -ceq $depth64) 'nesting depth 64 is accepted exactly' 'depth-64 JSON failed or changed'
    Check (Test-CanonicalRejection -Bytes $script:Utf8.GetBytes($depth65) -Pattern 'invalid') 'nesting depth 65 is rejected' 'depth-65 JSON was accepted or failed ambiguously'

    $digestInputA = $script:Utf8.GetBytes('{"b":1.0,"a":"雪"}')
    $digestInputB = $script:Utf8.GetBytes('{ "a" : "雪", "b" : 1e0 }')
    $knownDigest = 'sha256:46b7a65cbee9e5a96cd669ceabac4f48e00eabcdb9259a39c45245098a72802f'
    Check ((Harness.CanonicalJson\Get-HarnessCanonicalJsonSha256 -JsonBytes $digestInputA) -ceq $knownDigest -and
        (Harness.CanonicalJson\Get-HarnessCanonicalJsonSha256 -JsonBytes $digestInputB) -ceq $knownDigest) 'canonical JSON digest matches the exact known vector and reordered input' 'canonical JSON known digest or convergence drifted'

    $canonicalSource = [System.IO.File]::ReadAllText($canonicalPath)
    $hashingSource = [System.IO.File]::ReadAllText($hashingPath)
    Check ($canonicalSource.Contains("Harness.Hashing.psm1", [StringComparison]::Ordinal) -and
        $canonicalSource.Contains('Harness.Hashing\Get-HarnessSha256Bytes', [StringComparison]::Ordinal) -and
        $canonicalSource -notmatch '(?i)Security\.Cryptography\.SHA256|\bGet-FileHash\b|::HashData\s*\(|\.ComputeHash\s*\(') 'Canonical JSON delegates its final digest only to Harness.Hashing' 'Canonical JSON contains a parallel SHA-256 implementation or lacks its dependency'
    Check ($canonicalSource.Contains('[byte[]]$JsonBytes', [StringComparison]::Ordinal) -and
        $canonicalSource -notmatch '(?i)ConvertFrom-Json|ConvertTo-Json|Utf8JsonWriter') 'Canonical JSON accepts raw bytes and owns a deterministic serializer' 'Canonical JSON added a lossy PowerShell-object or default-writer path'
    Check ($hashingSource -notmatch '(?i)canonical.?json|ConvertTo-Json|digest_algorithm') 'Hashing remains free of canonical JSON behavior' 'Hashing gained a fifth object-digest responsibility'
    Check ((Harness.Hashing\Get-HarnessUtf8TextSha256 -Text 'hello') -ceq 'sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824') 'historical Hashing known vector remains unchanged' 'historical Hashing behavior changed'
} finally {
    if ($null -ne $canonicalModule) { Remove-Module $canonicalModule.Name -Force -ErrorAction Ignore }
    if ($null -ne $hashingModule) { Remove-Module $hashingModule.Name -Force -ErrorAction Ignore }
}

if ($failures.Count -gt 0) {
    Write-Output "STATUS: FAIL ($($failures.Count) failures)"
    foreach ($failure in $failures) { Write-Output "- $failure" }
    exit 1
}

Write-Output 'STATUS: PASS'
Write-Output 'TK-01B-New canonical-json/v1 contract checks passed.'
exit 0
