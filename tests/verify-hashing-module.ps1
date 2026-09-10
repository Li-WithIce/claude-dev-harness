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
function Get-LegacyBytesSha256 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Get-LegacyTextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-LegacyBytesSha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}
function Get-LegacyFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$hashingRelative = 'scripts/lib/Harness.Hashing.psm1'
$atomicRelative = 'scripts/lib/Harness.AtomicWrite.psm1'
$requirementRelative = 'scripts/lib/Harness.Requirement.psm1'
$runtimeDefaultRelative = 'scripts/lib/Harness.RuntimeDefault.psm1'
$runtimeDefaultReaderRelative = 'scripts/lib/Harness.RuntimeDefaultReader.ps1'
$compatMigrationRelatives = @(
    'scripts/assert-release-runner-boundary.ps1',
    'scripts/generate-entry-contract.ps1',
    'scripts/get-kernel-tcb-inventory.ps1',
    'scripts/host-benchmark/HostBenchmark.Otel.ps1',
    'scripts/host-benchmark/HostBenchmark.Trial.ps1',
    'scripts/install-transaction-common.ps1',
    'scripts/lib/Harness.AdapterAction.psm1',
    'scripts/lib/Harness.ModelEval.psm1',
    'scripts/lib/Harness.RolloutEvidence.psm1',
    'scripts/promote-v2-rollout-report.ps1',
    'scripts/receive-otlp-http.ps1',
    'scripts/run-host-benchmark.ps1',
    'scripts/run-model-evals.ps1',
    'scripts/run-preset-lifecycle-qualification.ps1',
    'scripts/run-v1-stop-loss-qualification.ps1'
)
$hashingPath = Join-Path $RepoRoot $hashingRelative
$atomicPath = Join-Path $RepoRoot $atomicRelative
$expectedExports = @(
    'Get-HarnessFileSha256',
    'Get-HarnessNormalizedTextSha256',
    'Get-HarnessSha256Bytes',
    'Get-HarnessUtf8TextSha256'
)

$parseFailures = [System.Collections.Generic.List[string]]::new()
foreach ($relative in @($hashingRelative,$atomicRelative,$requirementRelative,$runtimeDefaultRelative,'tests/verify-hashing-module.ps1') + $compatMigrationRelatives) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $relative),[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) { $parseFailures.Add("${relative}: $(@($errors | ForEach-Object Message) -join '; ')") }
}
Check ($parseFailures.Count -eq 0) 'Hashing and TK-01B-Compat PowerShell files parse' "PowerShell parse failures: $($parseFailures -join ' | ')"
Check (Test-FileHasUtf8Bom -Path $hashingPath) 'canonical Hashing module follows the repository UTF-8 BOM convention' 'canonical Hashing module lacks the repository UTF-8 BOM'

$hashingModule = $null
$atomicModule = $null
$scratch = Join-Path $RepoRoot ('tmp/hashing-contract-' + [guid]::NewGuid().ToString('N'))
try {
    $hashingModule = @(Import-Module $hashingPath -Force -PassThru -ErrorAction Stop)[-1]
    $actualExports = @($hashingModule.ExportedFunctions.Keys | Sort-Object -CaseSensitive)
    Check (($actualExports -join '|') -ceq ($expectedExports -join '|')) 'Hashing exports exactly the four TK-01A functions' "Hashing exports drifted: $($actualExports -join ', ')"

    Check ((Harness.Hashing\Get-HarnessSha256Bytes -Bytes ([byte[]]::new(0))) -ceq 'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') 'empty byte-array known vector matches SHA-256' 'empty byte-array digest drifted'
    Check ((Harness.Hashing\Get-HarnessUtf8TextSha256 -Text 'hello') -ceq 'sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824') 'ASCII UTF-8 text known vector matches SHA-256' 'ASCII text digest drifted'
    Check ((Harness.Hashing\Get-HarnessUtf8TextSha256 -Text 'Harness 雪') -ceq 'sha256:ed6cd3e4f2f8ab0bb1425de94155e96354ba45cfc64e4516389dd3594f6a81c3') 'non-ASCII UTF-8 text known vector matches SHA-256' 'non-ASCII text digest drifted'
    Check ((Harness.Hashing\Get-HarnessUtf8TextSha256 -Text "alpha`r`nbeta") -ceq 'sha256:4854aaef74503959fd26363306e2ef967a9d50bdda90d033a3a4acacbbd57547') 'exact UTF-8 text hashing preserves CRLF' 'exact UTF-8 text hashing normalized CRLF'

    $singleLf = 'sha256:01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b'
    Check ((Harness.Hashing\Get-HarnessNormalizedTextSha256 -Text '') -ceq $singleLf -and (Harness.Hashing\Get-HarnessNormalizedTextSha256 -Text "`r`n`r`n`r") -ceq $singleLf) 'NormalizedText maps empty and newline-only text to exactly one LF' 'NormalizedText empty or newline-only bytes drifted'
    Check ((Harness.Hashing\Get-HarnessNormalizedTextSha256 -Text "alpha`r`nbeta`r`n`r") -ceq 'sha256:e49c81e2d2f84e259d40e2fb8192f3bcd198b355184845d76d8f58807d0d78ee') 'NormalizedText converts CRLF and lone CR and appends one LF' 'NormalizedText mixed-newline digest drifted'
    $spaceTabDigest = 'sha256:ed0d8b9d705c7e66d3a5971e81ca42cb97ac314485bf98679e473021d8142947'
    Check ((Harness.Hashing\Get-HarnessNormalizedTextSha256 -Text "alpha `t`r`n`r") -ceq $spaceTabDigest -and (Harness.Hashing\Get-HarnessNormalizedTextSha256 -Text "alpha `t") -ceq $spaceTabDigest) 'NormalizedText preserves trailing spaces and Tabs while trimming only CR and LF' 'NormalizedText removed a space or Tab or appended the wrong LF count'

    [void][IO.Directory]::CreateDirectory($scratch)
    $bomFile = Join-Path $scratch 'bom-abc.bin'
    [IO.File]::WriteAllBytes($bomFile,[byte[]](0xEF,0xBB,0xBF,0x61,0x62,0x63))
    Check ((Harness.Hashing\Get-HarnessFileSha256 -Path $bomFile) -ceq 'sha256:1c28dc3f1f804a1ad9c9b4b4cf5e2658d16ad4ed08e3020d04a8d2865018947c') 'file hashing preserves exact BOM-bearing bytes' 'file hashing stripped or changed BOM-bearing bytes'
    $missingRejected = $false
    try { $null = Harness.Hashing\Get-HarnessFileSha256 -Path (Join-Path $scratch 'missing.bin') } catch { $missingRejected = $_.Exception.Message -match 'not a file' }
    Check $missingRejected 'canonical file hashing rejects a missing file' 'canonical file hashing accepted a missing file or failed ambiguously'

    $atomicModule = @(Import-Module $atomicPath -Force -PassThru -ErrorAction Stop)[-1]
    $hashingModule = @(Import-Module $hashingPath -Force -PassThru -ErrorAction Stop)[-1]
    $atomicExports = @($atomicModule.ExportedFunctions.Keys | Sort-Object -CaseSensitive)
    Check (($atomicExports -join '|') -ceq 'Get-HarnessFileDigest|Get-HarnessSha256Text|Remove-HarnessFileIfDigest|Write-HarnessAtomicText') 'AtomicWrite preserves its exact compatibility export surface' "AtomicWrite export surface drifted: $($atomicExports -join ', ')"
    Check ((Harness.AtomicWrite\Get-HarnessSha256Text -Content "alpha`r`nbeta") -ceq (Get-LegacyTextSha256 -Text "alpha`r`nbeta")) 'legacy AtomicWrite text API preserves exact UTF-8 digest semantics' 'legacy AtomicWrite text digest changed'
    $missingCompatibilityPath = [IO.Path]::GetRelativePath($RepoRoot,(Join-Path $scratch 'missing-compat.bin')).Replace([char]92,[char]47)
    Check ($null -eq (Harness.AtomicWrite\Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $missingCompatibilityPath)) 'legacy AtomicWrite file API preserves missing-file null semantics' 'legacy AtomicWrite missing-file behavior changed'

    $fixtureFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests/fixtures') -File -Recurse | Sort-Object FullName)
    $fixtureMismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($fixture in $fixtureFiles) {
        $relative = [IO.Path]::GetRelativePath($RepoRoot,$fixture.FullName).Replace([char]92,[char]47)
        $legacyDigest = Get-LegacyFileSha256 -Path $fixture.FullName
        $canonicalDigest = Harness.Hashing\Get-HarnessFileSha256 -Path $fixture.FullName
        $compatibilityDigest = Harness.AtomicWrite\Get-HarnessFileDigest -WorkspaceRoot $RepoRoot -Path $relative
        if ($legacyDigest -cne $canonicalDigest -or $legacyDigest -cne $compatibilityDigest) { $fixtureMismatches.Add($relative) }
    }
    Check ($fixtureFiles.Count -gt 0 -and $fixtureMismatches.Count -eq 0) "all $($fixtureFiles.Count) existing fixture file digests match the pre-TK-01A formula" "fixture digest regression: $($fixtureMismatches -join ', ')"

    $legacyTextVectors = @('',"`n","`r`n","alpha","alpha`r`nbeta",'Harness 雪',"trailing `t ")
    $textMismatches = @($legacyTextVectors | Where-Object { (Harness.Hashing\Get-HarnessUtf8TextSha256 -Text $_) -cne (Get-LegacyTextSha256 -Text $_) })
    Check ($textMismatches.Count -eq 0) 'canonical UTF-8 text hashing matches every pre-TK-01A text formula vector' 'one or more pre-TK-01A text digests changed'

    $legacyByteVectors = @([byte[]]::new(0),[byte[]](0x00),[byte[]](0xEF,0xBB,0xBF,0x61),[Text.UTF8Encoding]::new($false).GetBytes('Harness 雪'))
    $byteMismatches = @($legacyByteVectors | Where-Object { (Harness.Hashing\Get-HarnessSha256Bytes -Bytes $_) -cne (Get-LegacyBytesSha256 -Bytes $_) })
    Check ($byteMismatches.Count -eq 0) 'canonical byte hashing matches every pre-TK-01B raw formula vector' 'one or more pre-TK-01B raw byte digests changed'
    Check ((Harness.Hashing\Get-HarnessUtf8TextSha256 -Text 'legacy-bare').Substring(7) -ceq (Get-LegacyTextSha256 -Text 'legacy-bare').Substring(7) -and
        (Harness.Hashing\Get-HarnessFileSha256 -Path $bomFile).Substring(7) -ceq (Get-LegacyFileSha256 -Path $bomFile).Substring(7)) 'legacy bare lowercase hexadecimal representations remain byte-identical' 'a legacy bare hexadecimal representation changed'

    $hashingSource = [IO.File]::ReadAllText($hashingPath)
    $atomicSource = [IO.File]::ReadAllText($atomicPath)
    $requirementSource = [IO.File]::ReadAllText((Join-Path $RepoRoot $requirementRelative))
    $runtimeDefaultSource = [IO.File]::ReadAllText((Join-Path $RepoRoot $runtimeDefaultRelative)) + [IO.File]::ReadAllText((Join-Path $RepoRoot $runtimeDefaultReaderRelative))
    $runtimeKernelSource = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/lib/Harness.RuntimeKernel.ps1'))
    Check ($hashingSource -notmatch '(?i)canonical.?json|ConvertTo-Json|digest_algorithm') 'Hashing module contains no canonical JSON or object-digest algorithm' 'Hashing module leaked TK-01B-New behavior'
    Check ($atomicSource.Contains("Harness.Hashing.psm1",[StringComparison]::Ordinal) -and $atomicSource -notmatch '\bGet-FileHash\b|Security\.Cryptography\.SHA256') 'AtomicWrite delegates raw SHA-256 to canonical Hashing' 'AtomicWrite retains a parallel raw SHA-256 implementation'
    Check ($requirementSource.Contains('Harness.RuntimeKernel.ps1',[StringComparison]::Ordinal) -and $runtimeKernelSource.Contains("Harness.Hashing.psm1",[StringComparison]::Ordinal) -and $requirementSource.Contains('ConvertTo-Json -Depth 30 -Compress',[StringComparison]::Ordinal) -and $requirementSource -notmatch '\bGet-FileHash\b|Security\.Cryptography\.SHA256|UTF8Encoding') 'Requirement preserves JSON bytes and delegates only final hashing' 'Requirement serialization changed or direct SHA-256 remained'
    Check ($runtimeDefaultSource.Contains('Harness.RuntimeKernel.ps1',[StringComparison]::Ordinal) -and $runtimeKernelSource.Contains("Harness.Hashing.psm1",[StringComparison]::Ordinal) -and $runtimeDefaultSource.Contains("'scripts/lib/Harness.Hashing.psm1'",[StringComparison]::Ordinal) -and $runtimeDefaultSource -notmatch 'Security\.Cryptography\.SHA256|\bHashData\b') 'RuntimeDefault binds Hashing into Source Identity and delegates final hashing' 'RuntimeDefault source binding or SHA-256 delegation is incomplete'

    $missingCompatImports = @($compatMigrationRelatives | Where-Object {
        $source = [IO.File]::ReadAllText((Join-Path $RepoRoot $_))
        $direct = $source.Contains('Harness.Hashing.psm1',[StringComparison]::Ordinal) -and $source.Contains('Import-Module',[StringComparison]::Ordinal)
        $shared = $source.Contains('Harness.RuntimeKernel.ps1',[StringComparison]::Ordinal) -and $runtimeKernelSource.Contains('Harness.Hashing.psm1',[StringComparison]::Ordinal)
        -not ($direct -or $shared)
    })
    Check ($missingCompatImports.Count -eq 0) 'every second-wave production caller has a static Hashing dependency' "TK-01B-Compat Hashing dependency is missing: $($missingCompatImports -join ', ')"

    $productionPaths = @((Join-Path $RepoRoot 'harness.ps1')) + @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -File -Recurse | Where-Object { $_.Extension -cin @('.ps1','.psm1') } | ForEach-Object FullName)
    $directShaViolations = [Collections.Generic.List[string]]::new()
    foreach ($path in $productionPaths) {
        $relative = [IO.Path]::GetRelativePath($RepoRoot,$path).Replace([char]92,[char]47)
        if ($relative -ceq $hashingRelative) { continue }
        $source = [IO.File]::ReadAllText($path)
        if ($source -match '(?i)\bGet-FileHash\b|Security\.Cryptography\.SHA256|Cryptography\.SHA256|\.ComputeHash\s*\(|::HashData\s*\(') { $directShaViolations.Add($relative) }
    }
    Check ($directShaViolations.Count -eq 0) 'Harness.Hashing is the only production PowerShell SHA-256 implementation' "parallel production SHA-256 implementation remains: $($directShaViolations -join ', ')"

    $runHostSource = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/run-host-benchmark.ps1'))
    $runModelSource = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/run-model-evals.ps1'))
    $presetSource = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/run-preset-lifecycle-qualification.ps1'))
    $v1Source = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/run-v1-stop-loss-qualification.ps1'))
    Check ($runHostSource.Contains('$hashingPath',[StringComparison]::Ordinal) -and $runHostSource.Contains('$sourceInputPaths',[StringComparison]::Ordinal) -and
        $runModelSource.Contains('$hashingPath',[StringComparison]::Ordinal) -and $runModelSource.Contains('$sourceInputPaths',[StringComparison]::Ordinal) -and
        $presetSource.Contains('$hashingScript',[StringComparison]::Ordinal) -and $presetSource.Contains('$inputFiles',[StringComparison]::Ordinal) -and
        $v1Source.Contains("hashing = Join-Path `$RepoRoot 'scripts\lib\Harness.Hashing.psm1'",[StringComparison]::Ordinal)) 'standalone benchmark, model, lifecycle, and v1 source closures bind Hashing' 'a standalone producer source closure omitted Hashing'
} finally {
    if ($null -ne $atomicModule) { Remove-Module $atomicModule.Name -Force -ErrorAction Ignore }
    if ($null -ne $hashingModule) { Remove-Module $hashingModule.Name -Force -ErrorAction Ignore }
    if (Test-Path -LiteralPath $scratch) { Remove-DirectoryWithRetry -Path $scratch }
}

if ($failures.Count -gt 0) {
    Write-Output "STATUS: FAIL ($($failures.Count) failures)"
    foreach ($failure in $failures) { Write-Output "- $failure" }
    exit 1
}

Write-Output 'STATUS: PASS'
Write-Output 'Hashing contract and TK-01B-Compat digest compatibility checks passed.'
exit 0
