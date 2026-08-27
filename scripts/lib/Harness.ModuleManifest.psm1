Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.CanonicalJson.psm1') -Force -ErrorAction Stop

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$script:Ordinal = [System.StringComparer]::Ordinal
$script:OrdinalIgnoreCase = [System.StringComparer]::OrdinalIgnoreCase
$script:CoreGroups = @('entry-lifecycle','evaluation-release','install-evidence','governance-approval','harness-contracts')

function Get-HarnessOrdinalStrings {
    param([AllowEmptyCollection()][object[]]$Values)

    $set = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($value in @($Values)) { [void]$set.Add([string]$value) }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $set) { $list.Add($value) }
    $list.Sort($script:Ordinal)
    return @($list)
}

function Test-HarnessManifestByteSequenceEqual {
    param([byte[]]$Left, [byte[]]$Right)

    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Invoke-HarnessManifestGit {
    param([string]$RepoRoot, [string[]]$Arguments)

    $git = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $output = @(& $git -c core.fsmonitor=false -c core.safecrlf=false -C $RepoRoot @Arguments 2>$null)
    return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Lines=@($output | ForEach-Object { ([string]$_).Replace('\','/').TrimEnd("`r") }) }
}

function Test-HarnessManifestTrackedFile {
    param(
        [System.Collections.Generic.HashSet[string]]$TrackedFiles,
        [string]$RelativePath
    )

    return $TrackedFiles.Contains($RelativePath)
}

function Test-HarnessManifestTrackedPath {
    param(
        [string]$RepoRoot,
        [System.Collections.Generic.HashSet[string]]$TrackedFiles,
        [string]$Pattern
    )

    $base = if ($Pattern.EndsWith('/**',[System.StringComparison]::Ordinal)) { $Pattern.Substring(0,$Pattern.Length-3) } else { $Pattern }
    $full = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $base -Label 'Manifest ownership path' -MustExist Any
    if (Test-Path -LiteralPath $full -PathType Leaf) { return Test-HarnessManifestTrackedFile -TrackedFiles $TrackedFiles -RelativePath $base }
    $prefix = $base + '/'
    foreach ($trackedFile in $TrackedFiles) {
        if ($trackedFile.StartsWith($prefix,[System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Assert-HarnessManifestTrackedConcreteFile {
    param(
        [string]$RepoRoot,
        [System.Collections.Generic.HashSet[string]]$TrackedFiles,
        [string]$RelativePath,
        [string]$Label
    )

    [void](Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $RelativePath -Label $Label -MustExist File)
    if (-not (Test-HarnessManifestTrackedFile -TrackedFiles $TrackedFiles -RelativePath $RelativePath)) { throw "$Label is not one exact tracked regular file: $RelativePath" }
}

function Test-HarnessManifestPatternOverlap {
    param([string]$Left, [string]$Right)

    $leftTree = $Left.EndsWith('/**',[System.StringComparison]::Ordinal)
    $rightTree = $Right.EndsWith('/**',[System.StringComparison]::Ordinal)
    $leftBase = if ($leftTree) { $Left.Substring(0,$Left.Length-3) } else { $Left }
    $rightBase = if ($rightTree) { $Right.Substring(0,$Right.Length-3) } else { $Right }
    if (-not $leftTree -and -not $rightTree) { return $script:OrdinalIgnoreCase.Equals($leftBase,$rightBase) }
    if ($leftTree -and $rightTree) {
        return $script:OrdinalIgnoreCase.Equals($leftBase,$rightBase) -or
            $rightBase.StartsWith($leftBase + '/',[System.StringComparison]::OrdinalIgnoreCase) -or
            $leftBase.StartsWith($rightBase + '/',[System.StringComparison]::OrdinalIgnoreCase)
    }
    $treeBase = if ($leftTree) { $leftBase } else { $rightBase }
    $exact = if ($leftTree) { $rightBase } else { $leftBase }
    return $script:OrdinalIgnoreCase.Equals($treeBase,$exact) -or $exact.StartsWith($treeBase + '/',[System.StringComparison]::OrdinalIgnoreCase)
}

function Get-HarnessManifestDocument {
    param(
        [string]$RepoRoot,
        [System.Collections.Generic.HashSet[string]]$TrackedFiles,
        [string]$RelativePath
    )

    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $RelativePath -Label 'Module Manifest' -MustExist File
    if (-not (Test-HarnessManifestTrackedFile -TrackedFiles $TrackedFiles -RelativePath $RelativePath)) { throw "Module Manifest is not tracked: $RelativePath" }
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($fullPath)
    try { [byte[]]$canonicalBytes = Harness.CanonicalJson\ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $bytes }
    catch { throw "Module Manifest is not strict canonicalizable JSON: $RelativePath`: $($_.Exception.Message)" }
    $canonicalText = $script:Utf8NoBom.GetString($canonicalBytes)
    try { $document = ConvertFrom-HarnessJson -Json $canonicalText }
    catch { throw "Module Manifest is not valid JSON: $RelativePath`: $($_.Exception.Message)" }
    $schemaPath = Join-Path $RepoRoot 'schemas\module-manifest.schema.json'
    try { $valid = Test-Json -Json $canonicalText -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { throw "Module Manifest Schema validation failed: $RelativePath`: $($_.Exception.Message)" }
    if (-not $valid) { throw "Module Manifest failed Schema validation: $RelativePath" }
    return [pscustomobject]@{
        Path=$RelativePath
        Document=$document
        Digest=(Harness.CanonicalJson\Get-HarnessCanonicalJsonSha256 -JsonBytes $bytes)
    }
}

function Assert-HarnessManifestDependencies {
    param([System.Collections.IDictionary]$ById)

    $dependents = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]]::new($script:Ordinal)
    $inDegree = [System.Collections.Generic.Dictionary[string,int]]::new($script:Ordinal)
    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($ById.Keys))) {
        $dependents[$moduleId] = [System.Collections.Generic.List[string]]::new()
        $inDegree[$moduleId] = 0
    }
    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($ById.Keys))) {
        foreach ($dependency in @($ById[$moduleId].Document.dependencies.modules)) {
            $dependencyId = [string]$dependency
            if (-not $ById.Contains($dependencyId)) { throw "Module dependency does not exist: $moduleId -> $dependencyId" }
            $inDegree[$moduleId] = $inDegree[$moduleId] + 1
            $dependents[$dependencyId].Add($moduleId)
        }
    }
    $ready = [System.Collections.Generic.List[string]]::new()
    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($ById.Keys))) { if ($inDegree[$moduleId] -eq 0) { $ready.Add($moduleId) } }
    $visited = 0
    while ($ready.Count -gt 0) {
        $ready.Sort($script:Ordinal)
        $current = $ready[0]
        $ready.RemoveAt(0)
        $visited++
        foreach ($dependent in @($dependents[$current])) {
            $inDegree[$dependent] = $inDegree[$dependent] - 1
            if ($inDegree[$dependent] -eq 0) { $ready.Add($dependent) }
        }
    }
    if ($visited -ne $ById.Count) { throw 'Module dependency graph contains a cycle' }
}

function Get-HarnessModuleManifestCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ManifestRoot = 'modules'
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $manifestRootRelative = $ManifestRoot.Replace('\','/').Trim('/')
    $productionMode = $manifestRootRelative -ceq 'modules'
    $fixtureMode = $manifestRootRelative -match '^tests/fixtures/tk02(?:/|$)'
    if (-not $productionMode -and -not $fixtureMode) { throw 'ManifestRoot must be modules or a tracked tests/fixtures/tk02 case' }
    $manifestRootPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $manifestRootRelative -Label 'Manifest root' -MustExist Directory
    $trackedResult = Invoke-HarnessManifestGit -RepoRoot $RepoRoot -Arguments @('ls-files')
    if ($trackedResult.ExitCode -ne 0) { throw 'Unable to enumerate tracked repository files' }
    $trackedFiles = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($trackedFile in @($trackedResult.Lines)) { [void]$trackedFiles.Add([string]$trackedFile) }

    $physicalPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $manifestRootPath -Filter 'module.manifest.json' -File -Recurse | Sort-Object FullName)) {
        $relative = Get-HarnessRelativePath -WorkspaceRoot $RepoRoot -Path $file.FullName
        if ($relative -cnotmatch ('^' + [regex]::Escape($manifestRootRelative) + '/[^/]+/module\.manifest\.json$')) { throw "Module Manifest must be exactly one directory below ManifestRoot: $relative" }
        [void](Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $relative -Label 'Module Manifest' -MustExist File)
        if (-not (Test-HarnessManifestTrackedFile -TrackedFiles $trackedFiles -RelativePath $relative)) { throw "Module Manifest is not tracked: $relative" }
        $physicalPaths.Add($relative)
    }
    if ($physicalPaths.Count -eq 0) { throw 'ManifestRoot contains no module.manifest.json files' }
    $manifestPrefix = $manifestRootRelative + '/'
    $trackedManifestPaths = Get-HarnessOrdinalStrings -Values @($trackedFiles | Where-Object { $_.StartsWith($manifestPrefix,[System.StringComparison]::Ordinal) -and $_ -clike '*/module.manifest.json' })
    $physicalSorted = Get-HarnessOrdinalStrings -Values @($physicalPaths)
    if (($trackedManifestPaths -join '|') -cne ($physicalSorted -join '|')) { throw 'Tracked and physical Module Manifest sets differ' }

    $byId = [ordered]@{}
    $idCaseSet = [System.Collections.Generic.HashSet[string]]::new($script:OrdinalIgnoreCase)
    foreach ($manifestPath in $physicalSorted) {
        $record = Get-HarnessManifestDocument -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -RelativePath $manifestPath
        $moduleId = [string]$record.Document.module_id
        if (-not $idCaseSet.Add($moduleId)) { throw "Module id is duplicate or case-colliding: $moduleId" }
        $folder = Split-Path -Leaf (Split-Path -Parent $manifestPath)
        if ($folder -cne $moduleId) { throw "Module id must match its manifest directory: $manifestPath" }
        $byId[$moduleId] = $record
    }
    Assert-HarnessManifestDependencies -ById $byId

    $ownership = [System.Collections.Generic.List[object]]::new()
    $testOwners = [System.Collections.Generic.Dictionary[string,string]]::new($script:OrdinalIgnoreCase)
    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($byId.Keys))) {
        $manifest = $byId[$moduleId].Document
        foreach ($pattern in @($manifest.ownership.owned_paths)) {
            $pathPattern = [string]$pattern
            if (-not (Test-HarnessManifestTrackedPath -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -Pattern $pathPattern)) { throw "Owned path is missing or untracked: $moduleId -> $pathPattern" }
            $ownership.Add([pscustomobject]@{ModuleId=$moduleId;Pattern=$pathPattern})
        }
        foreach ($pattern in @($manifest.ownership.watch_paths)) {
            $pathPattern = [string]$pattern
            if (-not (Test-HarnessManifestTrackedPath -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -Pattern $pathPattern)) { throw "Watch path is missing or untracked: $moduleId -> $pathPattern" }
        }
        foreach ($entrypoint in @($manifest.entrypoints.commands) + @($manifest.entrypoints.hooks)) {
            Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -RelativePath ([string]$entrypoint) -Label "Module entrypoint for $moduleId"
        }
        foreach ($ownerTest in @($manifest.validation.owner_tests)) {
            $testPath = [string]$ownerTest
            Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -RelativePath $testPath -Label "Verifier owner reference for $moduleId"
            if ($testPath -cnotmatch '^tests/(?:verify-[A-Za-z0-9._-]+|run-scenario-evals)\.ps1$') { throw "owner_tests contains a non-verifier path: $moduleId -> $testPath" }
            if ($testOwners.ContainsKey($testPath)) { throw "Verifier has multiple owners: $testPath -> $($testOwners[$testPath]),$moduleId" }
            $testOwners[$testPath] = $moduleId
        }
        foreach ($testPath in @($manifest.validation.quick) + @($manifest.validation.changed) + @($manifest.validation.full)) {
            Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -RelativePath ([string]$testPath) -Label "Validation reference for $moduleId"
        }
    }

    for ($leftIndex = 0; $leftIndex -lt $ownership.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $ownership.Count; $rightIndex++) {
            $left = $ownership[$leftIndex]
            $right = $ownership[$rightIndex]
            if (Test-HarnessManifestPatternOverlap -Left $left.Pattern -Right $right.Pattern) {
                throw "Owned paths overlap: $($left.ModuleId):$($left.Pattern) <> $($right.ModuleId):$($right.Pattern)"
            }
        }
    }

    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($byId.Keys))) {
        $manifest = $byId[$moduleId].Document
        foreach ($testPath in @($manifest.validation.quick) + @($manifest.validation.changed) + @($manifest.validation.full)) {
            if (-not $testOwners.ContainsKey([string]$testPath)) { throw "Validation test has no manifest owner: $moduleId -> $testPath" }
        }
    }

    if ($productionMode) {
        $repositoryVerifiers = Get-HarnessOrdinalStrings -Values @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests') -Filter 'verify-*.ps1' -File | ForEach-Object { Get-HarnessRelativePath -WorkspaceRoot $RepoRoot -Path $_.FullName })
        $ownedVerifiers = Get-HarnessOrdinalStrings -Values @($testOwners.Keys | Where-Object { $_ -clike 'tests/verify-*.ps1' })
        if (($repositoryVerifiers -join '|') -cne ($ownedVerifiers -join '|')) {
            $missing = @($repositoryVerifiers | Where-Object { $ownedVerifiers -cnotcontains $_ })
            $extra = @($ownedVerifiers | Where-Object { $repositoryVerifiers -cnotcontains $_ })
            throw "Verifier ownership coverage differs: missing=[$($missing -join ',')] extra=[$($extra -join ',')]"
        }
    }

    $coreGroups = [ordered]@{}
    foreach ($group in $script:CoreGroups) { $coreGroups[$group] = [System.Collections.Generic.List[string]]::new() }
    $quickTests = [System.Collections.Generic.List[string]]::new()
    $fullTests = [System.Collections.Generic.List[string]]::new()
    $optionalRoutes = [System.Collections.Generic.List[object]]::new()
    $moduleOutput = [System.Collections.Generic.List[object]]::new()
    $sourceOutput = [System.Collections.Generic.List[object]]::new()
    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($byId.Keys))) {
        $record = $byId[$moduleId]
        $manifest = $record.Document
        $sourceOutput.Add([ordered]@{module_id=$moduleId;path=$record.Path;digest=$record.Digest})
        if ($null -ne $manifest.validation.core_group) {
            foreach ($testPath in @($manifest.validation.owner_tests)) { $coreGroups[[string]$manifest.validation.core_group].Add([string]$testPath) }
        }
        foreach ($testPath in @($manifest.validation.quick)) { $quickTests.Add([string]$testPath) }
        foreach ($testPath in @($manifest.validation.full)) { $fullTests.Add([string]$testPath) }
        $normalizedModule = [ordered]@{
            module_id=$moduleId
            kind=[string]$manifest.kind
            description=[string]$manifest.description
            default_activation=[bool]$manifest.default_activation
            dependencies=[ordered]@{kernel_api=[string]$manifest.dependencies.kernel_api;modules=@(Get-HarnessOrdinalStrings -Values @($manifest.dependencies.modules))}
            requested_capabilities=@(Get-HarnessOrdinalStrings -Values @($manifest.requested_capabilities))
            ownership=[ordered]@{owned_paths=@(Get-HarnessOrdinalStrings -Values @($manifest.ownership.owned_paths));watch_paths=@(Get-HarnessOrdinalStrings -Values @($manifest.ownership.watch_paths))}
            entrypoints=[ordered]@{commands=@(Get-HarnessOrdinalStrings -Values @($manifest.entrypoints.commands));hooks=@(Get-HarnessOrdinalStrings -Values @($manifest.entrypoints.hooks))}
            validation=[ordered]@{
                owner_tests=@($manifest.validation.owner_tests)
                quick=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.quick))
                core_group=$(if($null-eq$manifest.validation.core_group){$null}else{[string]$manifest.validation.core_group})
                changed=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.changed))
                full=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.full))
            }
        }
        $moduleOutput.Add($normalizedModule)
        if (@($manifest.validation.changed).Count -gt 0) {
            $matchPaths = Get-HarnessOrdinalStrings -Values (@($manifest.ownership.owned_paths) + @($manifest.ownership.watch_paths) + @($manifest.validation.owner_tests) + @($record.Path))
            $optionalRoutes.Add([ordered]@{module_id=$moduleId;manifest_path=$record.Path;match_paths=@($matchPaths);tests=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.changed))})
        }
    }
    foreach ($group in $script:CoreGroups) {
        if ($productionMode -and $coreGroups[$group].Count -eq 0) { throw "CoreGroup has no constructed tests: $group" }
        $coreGroups[$group] = @($coreGroups[$group])
    }
    $quickOutput = @(Get-HarnessOrdinalStrings -Values @($quickTests))
    $fullOutput = @(Get-HarnessOrdinalStrings -Values @($fullTests))
    if ($productionMode) {
        $expectedFull = Get-HarnessOrdinalStrings -Values @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests') -Filter 'verify-*.ps1' -File | Where-Object Name -cne 'verify-installation.ps1' | ForEach-Object { Get-HarnessRelativePath -WorkspaceRoot $RepoRoot -Path $_.FullName })
        if (($fullOutput -join '|') -cne ($expectedFull -join '|')) { throw 'Manifest full validation set does not equal every default full-suite verifier' }
    }
    $ownerOutput = [System.Collections.Generic.List[object]]::new()
    foreach ($testPath in (Get-HarnessOrdinalStrings -Values @($testOwners.Keys))) { $ownerOutput.Add([ordered]@{path=$testPath;module_id=$testOwners[$testPath]}) }

    $coreTestCount = 0
    foreach ($group in $script:CoreGroups) { $coreTestCount += @($coreGroups[$group]).Count }
    $catalog = [ordered]@{
        schema_version='module-manifest-catalog/v0'
        generator_contract_version='module-manifest-generator/v0'
        manifest_root=$manifestRootRelative
        source_manifests=@($sourceOutput)
        modules=@($moduleOutput)
        core_groups=$coreGroups
        quick_tests=@($quickOutput)
        full_tests=@($fullOutput)
        optional_routes=@($optionalRoutes)
        test_owners=@($ownerOutput)
        unresolved_dependencies=@()
        ownership_conflicts=@()
        totals=[ordered]@{
            manifest_count=$sourceOutput.Count
            module_count=$moduleOutput.Count
            owner_test_count=$ownerOutput.Count
            core_test_count=$coreTestCount
            quick_test_count=$quickOutput.Count
            full_test_count=$fullOutput.Count
            optional_route_count=$optionalRoutes.Count
        }
    }
    $catalogJson = $catalog | ConvertTo-Json -Depth 100 -Compress
    [byte[]]$canonicalBytes = Harness.CanonicalJson\ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $script:Utf8NoBom.GetBytes($catalogJson)
    $canonicalText = $script:Utf8NoBom.GetString($canonicalBytes)
    if ($productionMode) {
        try { $validCatalog = Test-Json -Json $canonicalText -SchemaFile (Join-Path $RepoRoot 'schemas\module-manifest-catalog.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue }
        catch { throw "Generated Manifest catalog Schema validation failed: $($_.Exception.Message)" }
        if (-not $validCatalog) { throw 'Generated Manifest catalog failed Schema validation' }
    }
    [byte[]]$outputBytes = [byte[]]::new($canonicalBytes.Length + 1)
    [Array]::Copy($canonicalBytes,0,$outputBytes,0,$canonicalBytes.Length)
    $outputBytes[$outputBytes.Length-1] = 0x0A
    return [pscustomobject]@{Catalog=$catalog;CanonicalText=$canonicalText;Bytes=$outputBytes}
}

function Assert-HarnessModuleManifestCatalogCurrent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ManifestRoot = 'modules',
        [string]$CatalogPath = 'module-manifest-catalog.json'
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $result = Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot -ManifestRoot $ManifestRoot
    $catalogFullPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $CatalogPath -Label 'Module Manifest catalog' -MustExist File
    $actualBytes = [System.IO.File]::ReadAllBytes($catalogFullPath)
    if (-not (Test-HarnessManifestByteSequenceEqual -Left $actualBytes -Right $result.Bytes)) {
        throw 'Module Manifest catalog does not match generated bytes'
    }
    return $result
}

Export-ModuleMember -Function Get-HarnessModuleManifestCatalog,Assert-HarnessModuleManifestCatalogCurrent
