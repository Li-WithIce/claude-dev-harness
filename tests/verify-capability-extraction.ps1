[CmdletBinding()]
param([string]$RepoRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
function Check {
    param([bool]$Condition,[string]$Success,[string]$Failure)
    if ($Condition) { Write-Output "[PASS] $Success" } else { Write-Output "[FAIL] $Failure"; $failures.Add($Failure) }
}
function Test-ConstructionFailure {
    param([string]$ManifestRoot,[string]$Pattern)
    try {
        $null = Harness.ModuleManifest\Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot -ManifestRoot $ManifestRoot
        return $false
    } catch { return $_.Exception.Message -match $Pattern }
}
function Test-BytesEqual {
    param([byte[]]$Left,[byte[]]$Right)
    return $Left.Length -eq $Right.Length -and [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}
function Get-IndexBlobSha256 {
    param([string]$RelativePath)
    $git = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $git
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-c','core.fsmonitor=false','-C',$RepoRoot,'show',(':' + $RelativePath))) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'unable to start Git fixture hash' }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $hash = [Security.Cryptography.SHA256]::Create()
        try { [byte[]]$digest = $hash.ComputeHash($process.StandardOutput.BaseStream) } finally { $hash.Dispose() }
        $process.WaitForExit(); $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Git fixture hash failed: $($stderr.Trim())" }
        return 'sha256:' + [Convert]::ToHexString($digest).ToLowerInvariant()
    } finally { $process.Dispose() }
}

$modulePath = Join-Path $RepoRoot 'scripts/lib/Harness.ModuleManifest.psm1'
$consumerPath = Join-Path $RepoRoot 'scripts/lib/Harness.CapabilitySource.psm1'
$writerPath = Join-Path $RepoRoot 'scripts/write-capability-source-binding.ps1'
$generatorPath = Join-Path $RepoRoot 'scripts/get-module-manifest-catalog.ps1'
$catalogPath = Join-Path $RepoRoot 'module-manifest-catalog.json'
$sourceCatalogPath = Join-Path $RepoRoot 'capability-source-catalog.json'
$bindingSchemaPath = Join-Path $RepoRoot 'schemas/capability-source-binding.schema.json'
$required = @(
    $modulePath,$consumerPath,$writerPath,$generatorPath,$catalogPath,$sourceCatalogPath,$bindingSchemaPath,
    (Join-Path $RepoRoot 'schemas/module-manifest-v1.schema.json'),
    (Join-Path $RepoRoot 'schemas/module-manifest-catalog-v1.schema.json'),
    (Join-Path $RepoRoot 'schemas/capability-source.schema.json'),
    (Join-Path $RepoRoot 'schemas/capability-source-catalog.schema.json')
)
Check (@($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0) 'TK-04 Manifest v1, source closure, and binding files exist' 'one or more TK-04 contract files are missing'

$parseFailures = [System.Collections.Generic.List[string]]::new()
foreach ($path in @($modulePath,$consumerPath,$writerPath,$generatorPath,$PSCommandPath)) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) { $parseFailures.Add("$path`: $(@($errors).Message -join '; ')") }
}
Check ($parseFailures.Count -eq 0) 'all TK-04 PowerShell files parse' "TK-04 PowerShell parse failures: $($parseFailures -join ' | ')"
$bomFailures = @(@($consumerPath,$writerPath,$PSCommandPath) | Where-Object { -not (Test-FileHasUtf8Bom -Path $_) })
Check ($bomFailures.Count -eq 0) 'new TK-04 PowerShell files follow the UTF-8 BOM convention' "TK-04 PowerShell BOM failures: $($bomFailures -join ', ')"

$manifestModule = $null
$consumerModule = $null
$canonicalModule = $null
$tempRoot = ''
try {
    $consumerModule = @(Import-Module $consumerPath -Force -PassThru -ErrorAction Stop)[-1]
    $manifestModule = @(Import-Module $modulePath -Force -PassThru -ErrorAction Stop)[-1]
    $canonicalModule = @(Import-Module (Join-Path $RepoRoot 'scripts/lib/Harness.CanonicalJson.psm1') -Force -PassThru -ErrorAction Stop)[-1]
    Check ((@($consumerModule.ExportedFunctions.Keys | Sort-Object -CaseSensitive) -join '|') -ceq 'Get-HarnessCapabilitySourceClosure') 'Capability source consumer exports exactly one read-only closure function' 'Capability source consumer export surface drifted'

    $result = Harness.ModuleManifest\Assert-HarnessModuleManifestCatalogCurrent -RepoRoot $RepoRoot
    $expectedV1 = @('benchmark','harness-maintenance','md-html','memory','providers','release-evidence','team')
    $actualV1 = @($result.Catalog.modules | Where-Object { [string]$_.schema_version -ceq 'harness-module/v1' } | ForEach-Object { [string]$_.module_id })
    Check (($actualV1 -join '|') -ceq ($expectedV1 -join '|') -and $result.Catalog.totals.v0_module_count -eq 6 -and $result.Catalog.totals.v1_module_count -eq 7) 'mixed catalog contains the exact seven C2 v1 modules and six compatibility v0 modules' "mixed production module set drifted: $($actualV1 -join ', ')"
    Check ($result.Catalog.schema_version -ceq 'module-manifest-catalog/v1' -and $result.CapabilitySourceCatalog.schema_version -ceq 'capability-source-catalog/v1' -and @($result.CapabilitySourceCatalog.sources).Count -eq 7) 'production emits the v1 mixed catalog and seven-source closure' 'production catalog or source closure contract drifted'
    Check ([string]$result.Catalog.capability_source_catalog_digest -ceq [string]$result.CapabilitySourceCatalog.catalog_digest) 'Manifest catalog binds the exact Capability source catalog digest' 'Manifest catalog source closure digest is not bound'

    $classification = Get-Content -LiteralPath (Join-Path $RepoRoot 'kernel-component-classification.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
    $c2 = @($classification.components | Where-Object { [string]$_.layer -ceq 'c2-capability' })
    $packageCode = @($result.Catalog.modules | Where-Object { [string]$_.schema_version -ceq 'harness-module/v1' } | ForEach-Object { @($_.package.code) })
    $missingC2 = @($c2 | Where-Object {
        $path = [string]$_.path
        @($packageCode | Where-Object {
            $pattern = [string]$_
            $path -ceq $pattern -or ($pattern.EndsWith('/**',[StringComparison]::Ordinal) -and $path.StartsWith($pattern.Substring(0,$pattern.Length-3) + '/',[StringComparison]::Ordinal))
        }).Count -eq 0
    })
    $missingC2Paths = @($missingC2 | ForEach-Object { [string]$_.path })
    Check ($c2.Count -eq 41 -and $missingC2.Count -eq 0) 'all 41 C2 implementation paths belong to one of the seven v1 Capability packages' "C2 package coverage drifted: count=$($c2.Count) missing=$($missingC2Paths -join ',')"

    $sourceFiles = @($result.CapabilitySourceCatalog.sources | ForEach-Object { @($_.files) })
    $duplicates = @($sourceFiles.path | Group-Object -CaseSensitive | Where-Object Count -ne 1)
    $indexDigestsMatch = $true
    foreach ($file in $sourceFiles) {
        if ([string]$file.sha256 -cne (Get-IndexBlobSha256 -RelativePath ([string]$file.path))) { $indexDigestsMatch = $false; break }
    }
    Check ($duplicates.Count -eq 0 -and $indexDigestsMatch) 'Capability source closure is disjoint and hashes raw Git index blob bytes' 'Capability source paths overlap or a raw index blob digest differs'

    $sourceDigestsMatch = $true
    foreach ($source in @($result.CapabilitySourceCatalog.sources)) {
        $withoutDigest = [ordered]@{}
        foreach ($key in @($source.Keys)) { if ([string]$key -cne 'source_digest') { $withoutDigest[[string]$key] = $source[$key] } }
        $json = $withoutDigest | ConvertTo-Json -Depth 100 -Compress
        $digest = Harness.CanonicalJson\Get-HarnessCanonicalJsonSha256 -JsonBytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
        if ($digest -cne [string]$source.source_digest) { $sourceDigestsMatch = $false; break }
    }
    Check $sourceDigestsMatch 'every source_digest canonically binds version, Manifest digest, and raw file digests' 'one or more Capability source digests are not canonical-json/v1'

    $mixed = Harness.ModuleManifest\Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot -ManifestRoot 'tests/fixtures/tk04/mixed'
    Check ($mixed.Catalog.totals.v0_module_count -eq 1 -and $mixed.Catalog.totals.v1_module_count -eq 1 -and @($mixed.CapabilitySourceCatalog.sources).Count -eq 1) 'tracked mixed fixture preserves v0 while closing only the v1 package' 'mixed v0/v1 fixture construction drifted'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk04/invalid-role-overlap' -Pattern 'multiple roles') 'package role overlap fails construction' 'package role overlap did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk04/invalid-incomplete' -Pattern 'no package role') 'owned file omitted from package roles fails construction' 'incomplete Capability package did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk04/invalid-export' -Pattern 'not declared as code') 'export outside the code role fails construction' 'non-code Capability export did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk04/missing-path' -Pattern 'does not exist|missing or untracked') 'missing or untracked owned path fails construction' 'missing Capability path did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk04/duplicate-owner' -Pattern 'classification_owner is duplicate') 'duplicate classification_owner fails construction' 'duplicate Capability classification owner did not fail closed'
    Check (Test-ConstructionFailure -ManifestRoot 'tests/fixtures/tk04/invalid-schema' -Pattern 'Schema') 'bad version and unknown field fixtures fail strict Schema validation' 'invalid v1 Manifest Schema fixture was accepted'

    $staleRejected = $false
    try { $null = Harness.ModuleManifest\Assert-HarnessModuleManifestCatalogCurrent -RepoRoot $RepoRoot -CapabilitySourceCatalogPath 'tests/fixtures/tk04/stale-source-catalog.json' }
    catch { $staleRejected = $_.Exception.Message -match 'Capability source catalog does not match generated bytes' }
    Check $staleRejected 'stale Capability source catalog bytes fail closed' 'stale Capability source catalog was accepted or failed ambiguously'

    $sensitivityPath = Join-Path $RepoRoot 'tests/fixtures/tk04/stale-source-catalog.json'
    [byte[]]$sensitivityBytes = [IO.File]::ReadAllBytes($sensitivityPath)
    $unstagedRejected = $false
    try {
        [IO.File]::WriteAllBytes($sensitivityPath,@($sensitivityBytes + [byte]0x20))
        try { $null = Harness.ModuleManifest\Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot }
        catch { $unstagedRejected = $_.Exception.Message -match 'unstaged bytes' }
    } finally { [IO.File]::WriteAllBytes($sensitivityPath,$sensitivityBytes) }
    Check $unstagedRejected 'unstaged package-byte changes cannot enter an index-bound source closure' 'Capability source construction accepted unstaged package bytes'

    [byte[]]$catalogBefore = [IO.File]::ReadAllBytes($catalogPath)
    [byte[]]$sourceBefore = [IO.File]::ReadAllBytes($sourceCatalogPath)
    $catalogTime = (Get-Item -LiteralPath $catalogPath).LastWriteTimeUtc.Ticks
    $sourceTime = (Get-Item -LiteralPath $sourceCatalogPath).LastWriteTimeUtc.Ticks
    $powerShell = (Get-Process -Id $PID -ErrorAction Stop).Path
    $checkOutput = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File $generatorPath -RepoRoot $RepoRoot -Check 2>&1)
    $checkExit = $LASTEXITCODE
    Check ($checkExit -eq 0 -and ($checkOutput -join "`n") -match 'STATUS: PASS' -and
        (Test-BytesEqual $catalogBefore ([IO.File]::ReadAllBytes($catalogPath))) -and
        (Test-BytesEqual $sourceBefore ([IO.File]::ReadAllBytes($sourceCatalogPath))) -and
        $catalogTime -eq (Get-Item -LiteralPath $catalogPath).LastWriteTimeUtc.Ticks -and
        $sourceTime -eq (Get-Item -LiteralPath $sourceCatalogPath).LastWriteTimeUtc.Ticks) 'dual-catalog -Check performs zero writes' 'dual-catalog -Check failed or mutated tracked output'

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('harness-tk04-binding-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempRoot)
    $allArtifacts = @(
        'model-eval.json','model-runner-observation.json','release-model-receipt.json',
        'cognitive-host.json','host-runner-observation.json','installed-desktop-distinct.json','installed-desktop-primary.json',
        'lifecycle-core.json','lifecycle-full.json','lifecycle-governed.json','release-host-receipt.json','v1-stop-loss.json',
        'aggregator-runner-observation.json','exact-head-engineering.json','release-full-receipt.json','release-isolation.json'
    )
    foreach ($name in $allArtifacts) { [IO.File]::WriteAllText((Join-Path $tempRoot $name),'{}',[Text.UTF8Encoding]::new($false)) }
    $revision = [string]@(& git -c core.fsmonitor=false -C $RepoRoot rev-parse HEAD)[0]
    foreach ($kind in @('model','host')) {
        $output = Join-Path $tempRoot "$kind-capability-source-binding.json"
        $writerOutput = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File $writerPath -RepoRoot $RepoRoot -Kind $kind -ArtifactRoot $tempRoot -OutputPath $output -SourceRevision $revision -ProducerMode test-only 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "$kind binding fixture failed: $($writerOutput -join ' | ')" }
    }
    $fullPath = Join-Path $tempRoot 'full-capability-source-binding.json'
    $fullOutput = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File $writerPath -RepoRoot $RepoRoot -Kind full -ArtifactRoot $tempRoot -OutputPath $fullPath -SourceRevision $revision -ProducerMode test-only 2>&1)
    $fullExit = $LASTEXITCODE
    $bindingSchemaValid = $fullExit -eq 0
    foreach ($kind in @('model','host','full')) {
        $path = Join-Path $tempRoot "$kind-capability-source-binding.json"
        try { if (-not (Test-Json -Json ([IO.File]::ReadAllText($path)) -SchemaFile $bindingSchemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) { $bindingSchemaValid = $false } }
        catch { $bindingSchemaValid = $false }
    }
    Check $bindingSchemaValid 'model, host, and full bundle sidecars satisfy the strict binding Schema' "Capability source binding fixture failed: $($fullOutput -join ' | ')"

    [IO.File]::WriteAllText((Join-Path $tempRoot 'model-eval.json'),'{"tampered":true}',[Text.UTF8Encoding]::new($false))
    $tamperOutput = @(& $powerShell -NoLogo -NoProfile -NonInteractive -File $writerPath -RepoRoot $RepoRoot -Kind full -ArtifactRoot $tempRoot -OutputPath $fullPath -SourceRevision $revision -ProducerMode test-only 2>&1)
    Check ($LASTEXITCODE -ne 0 -and ($tamperOutput -join "`n") -match 'artifact digest mismatch') 'full binding rejects a tampered upstream bundle artifact' 'full binding accepted a tampered upstream artifact or failed ambiguously'

    $bindingText = [IO.File]::ReadAllText((Join-Path $tempRoot 'model-capability-source-binding.json'))
    Check ($bindingText -notmatch '(?i)[A-Z]:[\\/]|\\\\' -and $bindingText.Contains('canonical-json/v1',[StringComparison]::Ordinal)) 'binding sidecars contain only portable artifact names and an explicit digest algorithm' 'binding sidecar leaked an absolute path or omitted digest_algorithm'

    $oldContractPaths = @(
        'schemas/release-model-receipt.schema.json','schemas/release-host-receipt.schema.json','schemas/release-full-receipt.schema.json',
        'scripts/write-release-producer-receipt.ps1','scripts/write-release-full-receipt.ps1'
    )
    $oldDrift = @(& git -c core.fsmonitor=false -C $RepoRoot diff --name-only 56a81e39477d2991bdd1dd34a6ac3ef6994b99ba -- $oldContractPaths)
    Check ($oldDrift.Count -eq 0) 'historical Release receipt Schemas and writers remain byte-compatible' "historical Release contract bytes changed: $($oldDrift -join ', ')"

    $newSource = [IO.File]::ReadAllText($consumerPath) + "`n" + [IO.File]::ReadAllText($writerPath)
    $runtimeImports = @(rg -l 'Harness\.CapabilitySource|write-capability-source-binding' (Join-Path $RepoRoot 'runtime') (Join-Path $RepoRoot 'runtime-hooks') (Join-Path $RepoRoot 'install.ps1') (Join-Path $RepoRoot 'scripts/install-transaction-common.ps1') 2>$null)
    Check ($newSource -notmatch '(?i)Harness\.(?:Policy|Approval|ControlledWrite)|kernel-policy-write|default_activation\s*=\s*true' -and $runtimeImports.Count -eq 0) 'Capability extraction adds no Runtime, install, or authorization authority' 'Capability extraction leaked into Runtime/install or added authorization behavior'
} finally {
    if (-not [string]::IsNullOrWhiteSpace($tempRoot) -and (Test-Path -LiteralPath $tempRoot -PathType Container)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    if ($null -ne $canonicalModule) { Remove-Module $canonicalModule.Name -Force -ErrorAction Ignore }
    if ($null -ne $consumerModule) { Remove-Module $consumerModule.Name -Force -ErrorAction Ignore }
    if ($null -ne $manifestModule) { Remove-Module $manifestModule.Name -Force -ErrorAction Ignore }
}

if ($failures.Count -gt 0) {
    Write-Output "STATUS: FAIL ($($failures.Count) failures)"
    foreach ($failure in $failures) { Write-Output "- $failure" }
    exit 1
}
Write-Output 'STATUS: PASS'
Write-Output 'TK-04 Capability package extraction, source closure, and Release binding checks passed.'
exit 0
