Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -Force -ErrorAction Stop
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

function Get-HarnessManifestTrackedFilesForPattern {
    param(
        [string]$RepoRoot,
        [System.Collections.Generic.HashSet[string]]$TrackedFiles,
        [string]$Pattern,
        [string]$Label
    )

    [object[]]$matches = @()
    if ($Pattern.EndsWith('/**',[System.StringComparison]::Ordinal)) {
        $base = $Pattern.Substring(0,$Pattern.Length-3)
        [void](Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $base -Label $Label -MustExist Directory)
        $prefix = $base + '/'
        $matches = @($TrackedFiles | Where-Object { $_.StartsWith($prefix,[System.StringComparison]::Ordinal) })
    } else {
        Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $TrackedFiles -RelativePath $Pattern -Label $Label
        $matches = @($Pattern)
    }
    $sorted = @(Get-HarnessOrdinalStrings -Values $matches)
    if ($sorted.Count -eq 0) { throw "$Label resolves to zero tracked files: $Pattern" }
    foreach ($relativePath in $sorted) {
        Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $TrackedFiles -RelativePath $relativePath -Label $Label
    }
    return $sorted
}

function Test-HarnessManifestPathCoveredByPattern {
    param([string]$RelativePath, [string]$Pattern)

    if ($Pattern.EndsWith('/**',[System.StringComparison]::Ordinal)) {
        $base = $Pattern.Substring(0,$Pattern.Length-3)
        return $RelativePath.StartsWith($base + '/',[System.StringComparison]::Ordinal)
    }
    return $RelativePath -ceq $Pattern
}

function Assert-HarnessManifestWorktreeMatchesIndex {
    param([string]$RepoRoot, [string]$RelativePath, [string]$Label, [switch]$PassThruIndexBlob)

    $flags = Invoke-HarnessManifestGit -RepoRoot $RepoRoot -Arguments @('ls-files','-v','--stage','--',(':(literal)' + $RelativePath))
    if ($flags.ExitCode -ne 0 -or $flags.Lines.Count -ne 1) { throw "$Label index flag inspection failed: $RelativePath" }
    if ($flags.Lines[0] -cmatch '^[a-zS] ') {
        throw "$Label uses assume-unchanged or skip-worktree; index-bound source closure requires an unflagged path: $RelativePath"
    }
    $result = Invoke-HarnessManifestGit -RepoRoot $RepoRoot -Arguments @('diff','--quiet','--no-ext-diff','--',$RelativePath)
    if ($result.ExitCode -eq 1) { throw "$Label has unstaged bytes and cannot enter an index-bound source closure: $RelativePath" }
    if ($result.ExitCode -ne 0) { throw "$Label worktree/index comparison failed: $RelativePath" }
    if ($PassThruIndexBlob) {
        $entry = [regex]::Match($flags.Lines[0],'^H [0-9]{6} (?<blob>[0-9a-f]{40}|[0-9a-f]{64}) 0\t')
        if (-not $entry.Success) { throw "$Label has an invalid stage-zero index blob: $RelativePath" }
        return $entry.Groups['blob'].Value
    }
}

function Get-HarnessManifestIndexFiles {
    param([string]$RepoRoot, [string[]]$RelativePaths, [string]$ModuleId)

    $git = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $git
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $script:Utf8NoBom
    foreach ($argument in @('-c','core.fsmonitor=false','-C',$RepoRoot,'cat-file','--batch=%(objecttype) %(objectsize)')) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "Unable to start Git for index blobs: $ModuleId" }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $reader = [System.IO.BinaryReader]::new($process.StandardOutput.BaseStream)
        $files = [System.Collections.Generic.List[object]]::new()
        try {
            foreach ($relativePath in $RelativePaths) {
                # Keep each fail-closed index/worktree check immediately before its read.
                $blob = Assert-HarnessManifestWorktreeMatchesIndex -RepoRoot $RepoRoot -RelativePath $relativePath -Label "Capability source for $ModuleId" -PassThruIndexBlob
                # Address immutable objects; a long-lived cat-file must not cache :path index lookups.
                $process.StandardInput.WriteLine($blob)
                $process.StandardInput.Flush()
                $header = [System.Text.StringBuilder]::new()
                while (($next = $reader.ReadByte()) -ne 10) {
                    if ($next -gt 127 -or $header.Length -ge 128) { throw 'Invalid Git index blob header' }
                    [void]$header.Append([char]$next)
                }
                $match = [regex]::Match($header.ToString(),'^blob (0|[1-9][0-9]*)$')
                [int]$length = 0
                if (-not $match.Success -or -not [int]::TryParse($match.Groups[1].Value,[ref]$length)) {
                    throw "Unable to read Git index blob: $relativePath"
                }
                [byte[]]$bytes = $reader.ReadBytes($length)
                if ($bytes.Length -ne $length -or $reader.ReadByte() -ne 10) { throw 'Truncated Git index blob frame' }
                $files.Add([ordered]@{path=$relativePath;sha256=(Get-HarnessSha256Bytes -Bytes $bytes)})
            }
            $process.StandardInput.Close()
            if ($reader.BaseStream.ReadByte() -ne -1) { throw 'Unexpected trailing Git index blob output' }
        } finally { $reader.Dispose() }
        $process.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Unable to read Git index blobs: $ModuleId`: $($stderr.Trim())" }
        return @($files)
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Get-HarnessManifestCanonicalDigest {
    param([System.Collections.IDictionary]$Document)

    $json = $Document | ConvertTo-Json -Depth 100 -Compress
    return Harness.CanonicalJson\Get-HarnessCanonicalJsonSha256 -JsonBytes $script:Utf8NoBom.GetBytes($json)
}

function ConvertTo-HarnessManifestCanonicalOutput {
    param([System.Collections.IDictionary]$Document)

    $json = $Document | ConvertTo-Json -Depth 100 -Compress
    [byte[]]$canonicalBytes = Harness.CanonicalJson\ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $script:Utf8NoBom.GetBytes($json)
    [byte[]]$outputBytes = [byte[]]::new($canonicalBytes.Length + 1)
    [Array]::Copy($canonicalBytes,0,$outputBytes,0,$canonicalBytes.Length)
    $outputBytes[$outputBytes.Length-1] = 0x0A
    return [pscustomobject]@{
        CanonicalText=$script:Utf8NoBom.GetString($canonicalBytes)
        Bytes=$outputBytes
    }
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
    $schemaVersion = [string]$document.schema_version
    $schemaRelativePath = switch ($schemaVersion) {
        'harness-module/v0' { 'schemas\module-manifest.schema.json' }
        'harness-module/v1' { 'schemas\module-manifest-v1.schema.json' }
        default { throw "Unsupported Module Manifest schema_version: $RelativePath -> $schemaVersion" }
    }
    $schemaPath = Join-Path $RepoRoot $schemaRelativePath
    try { $valid = Test-Json -Json $canonicalText -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { throw "Module Manifest Schema validation failed: $RelativePath`: $($_.Exception.Message)" }
    if (-not $valid) { throw "Module Manifest failed Schema validation: $RelativePath" }
    return [pscustomobject]@{
        Path=$RelativePath
        Document=$document
        Digest=(Harness.CanonicalJson\Get-HarnessCanonicalJsonSha256 -JsonBytes $bytes)
        SchemaVersion=$schemaVersion
    }
}

function Get-HarnessCapabilityPackageRecord {
    param(
        [string]$RepoRoot,
        [System.Collections.Generic.HashSet[string]]$TrackedFiles,
        [pscustomobject]$ManifestRecord
    )

    $manifest = $ManifestRecord.Document
    $moduleId = [string]$manifest.module_id
    Assert-HarnessManifestWorktreeMatchesIndex -RepoRoot $RepoRoot -RelativePath $ManifestRecord.Path -Label "Capability Manifest for $moduleId"

    $ownedFiles = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($pattern in @($manifest.ownership.owned_paths)) {
        foreach ($relativePath in @(Get-HarnessManifestTrackedFilesForPattern -RepoRoot $RepoRoot -TrackedFiles $TrackedFiles -Pattern ([string]$pattern) -Label "Capability ownership for $moduleId")) {
            [void]$ownedFiles.Add($relativePath)
        }
    }

    $roleNames = @('code','schemas','tests','install_assets')
    $roleFiles = [ordered]@{}
    $allRoleFiles = [System.Collections.Generic.Dictionary[string,string]]::new($script:Ordinal)
    foreach ($roleName in $roleNames) {
        $expanded = [System.Collections.Generic.List[string]]::new()
        foreach ($pattern in @($manifest.package[$roleName])) {
            foreach ($relativePath in @(Get-HarnessManifestTrackedFilesForPattern -RepoRoot $RepoRoot -TrackedFiles $TrackedFiles -Pattern ([string]$pattern) -Label "Capability package $roleName for $moduleId")) {
                if (-not $ownedFiles.Contains($relativePath)) { throw "Capability package file is not owned by its module: $moduleId/$roleName -> $relativePath" }
                if ($allRoleFiles.ContainsKey($relativePath)) { throw "Capability package file has multiple roles: $moduleId -> $relativePath ($($allRoleFiles[$relativePath]),$roleName)" }
                $allRoleFiles[$relativePath] = $roleName
                $expanded.Add($relativePath)
            }
        }
        $roleFiles[$roleName] = @(Get-HarnessOrdinalStrings -Values @($expanded))
    }

    foreach ($ownedFile in @(Get-HarnessOrdinalStrings -Values @($ownedFiles))) {
        if ($ownedFile -ceq $ManifestRecord.Path) { continue }
        if (-not $allRoleFiles.ContainsKey($ownedFile)) { throw "Owned capability file has no package role: $moduleId -> $ownedFile" }
    }

    foreach ($schemaPath in @($roleFiles.schemas)) {
        if ($schemaPath -cnotmatch '^schemas/.+\.json$') { throw "Capability Schema role is not a schemas/*.json file: $moduleId -> $schemaPath" }
    }
    foreach ($testPath in @($roleFiles.tests)) {
        if (-not $testPath.StartsWith('tests/',[System.StringComparison]::Ordinal)) { throw "Capability test role is outside tests/: $moduleId -> $testPath" }
    }
    $codeSet = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($codePath in @($roleFiles.code)) { [void]$codeSet.Add([string]$codePath) }
    foreach ($exportKind in @('commands','hooks','libraries')) {
        foreach ($exportPath in @($manifest.exports[$exportKind])) {
            $relativePath = [string]$exportPath
            Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $TrackedFiles -RelativePath $relativePath -Label "Capability export $exportKind for $moduleId"
            if (-not $codeSet.Contains($relativePath)) { throw "Capability export is not declared as code: $moduleId/$exportKind -> $relativePath" }
            if ($exportKind -ceq 'libraries' -and $relativePath -cnotmatch '\.psm1$') { throw "Capability library export is not a .psm1 file: $moduleId -> $relativePath" }
        }
    }
    $testSet = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($testPath in @($roleFiles.tests)) { [void]$testSet.Add([string]$testPath) }
    foreach ($ownerTest in @($manifest.validation.owner_tests)) {
        if (-not $testSet.Contains([string]$ownerTest)) { throw "Capability owner test is absent from package tests: $moduleId -> $ownerTest" }
    }

    $fileOutput = @(Get-HarnessManifestIndexFiles -RepoRoot $RepoRoot -RelativePaths @(Get-HarnessOrdinalStrings -Values @($allRoleFiles.Keys)) -ModuleId $moduleId)
    $withoutDigest = [ordered]@{
        schema_version='capability-source/v1'
        module_id=$moduleId
        module_version=[string]$manifest.module_version
        manifest_digest=[string]$ManifestRecord.Digest
        digest_algorithm='canonical-json/v1'
        source_basis='git-index-blob/v1'
        files=@($fileOutput)
    }
    $source = [ordered]@{}
    foreach ($key in $withoutDigest.Keys) { $source[$key] = $withoutDigest[$key] }
    $source.source_digest = Get-HarnessManifestCanonicalDigest -Document $withoutDigest
    $sourceJson = $source | ConvertTo-Json -Depth 100 -Compress
    try { $valid = Test-Json -Json $sourceJson -SchemaFile (Join-Path $RepoRoot 'schemas\capability-source.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { throw "Capability source Schema validation failed for $moduleId`: $($_.Exception.Message)" }
    if (-not $valid) { throw "Capability source failed Schema validation: $moduleId" }

    return [pscustomobject]@{
        RoleFiles=$roleFiles
        Source=$source
        Package=[ordered]@{
            code=@(Get-HarnessOrdinalStrings -Values @($manifest.package.code))
            schemas=@(Get-HarnessOrdinalStrings -Values @($manifest.package.schemas))
            tests=@(Get-HarnessOrdinalStrings -Values @($manifest.package.tests))
            install_assets=@(Get-HarnessOrdinalStrings -Values @($manifest.package.install_assets))
        }
        Exports=[ordered]@{
            commands=@(Get-HarnessOrdinalStrings -Values @($manifest.exports.commands))
            hooks=@(Get-HarnessOrdinalStrings -Values @($manifest.exports.hooks))
            libraries=@(Get-HarnessOrdinalStrings -Values @($manifest.exports.libraries))
        }
    }
}

function Get-HarnessCapabilitySourceCatalogRecord {
    param([string]$RepoRoot, [System.Collections.IDictionary]$CapabilityPackages)

    $sources = [System.Collections.Generic.List[object]]::new()
    $uniqueFiles = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    $fileReferenceCount = 0
    foreach ($moduleId in @(Get-HarnessOrdinalStrings -Values @($CapabilityPackages.Keys))) {
        $source = $CapabilityPackages[$moduleId].Source
        foreach ($file in @($source.files)) {
            $fileReferenceCount++
            if (-not $uniqueFiles.Add([string]$file.path)) { throw "Capability source file belongs to multiple modules: $($file.path)" }
        }
        $sources.Add($source)
    }
    $withoutDigest = [ordered]@{
        schema_version='capability-source-catalog/v1'
        generator_contract_version='module-manifest-generator/v1'
        digest_algorithm='canonical-json/v1'
        sources=@($sources)
        totals=[ordered]@{
            module_count=$sources.Count
            file_reference_count=$fileReferenceCount
            unique_file_count=$uniqueFiles.Count
        }
    }
    $catalog = [ordered]@{}
    foreach ($key in $withoutDigest.Keys) { $catalog[$key] = $withoutDigest[$key] }
    $catalog.catalog_digest = Get-HarnessManifestCanonicalDigest -Document $withoutDigest
    $output = ConvertTo-HarnessManifestCanonicalOutput -Document $catalog
    return [pscustomobject]@{Catalog=$catalog;CanonicalText=$output.CanonicalText;Bytes=$output.Bytes}
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
    $fixtureMode = $manifestRootRelative -match '^tests/fixtures/tk0[234](?:/|$)'
    if (-not $productionMode -and -not $fixtureMode) { throw 'ManifestRoot must be modules or a tracked tests/fixtures/tk02, tk03 or tk04 case' }
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
    $archivedTests = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    $capabilityPackages = [ordered]@{}
    $classificationOwners = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($byId.Keys))) {
        $record = $byId[$moduleId]
        $manifest = $record.Document
        $isV1 = [string]$record.SchemaVersion -ceq 'harness-module/v1'
        if ($isV1) {
            $classificationOwner = [string]$manifest.classification_owner
            if (-not $classificationOwners.Add($classificationOwner)) { throw "Capability classification_owner is duplicate: $classificationOwner" }
            $capabilityPackages[$moduleId] = Get-HarnessCapabilityPackageRecord -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -ManifestRecord $record
        }
        foreach ($pattern in @($manifest.ownership.owned_paths)) {
            $pathPattern = [string]$pattern
            if (-not (Test-HarnessManifestTrackedPath -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -Pattern $pathPattern)) { throw "Owned path is missing or untracked: $moduleId -> $pathPattern" }
            $ownership.Add([pscustomobject]@{ModuleId=$moduleId;Pattern=$pathPattern})
        }
        foreach ($pattern in @($manifest.ownership.watch_paths)) {
            $pathPattern = [string]$pattern
            if (-not (Test-HarnessManifestTrackedPath -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -Pattern $pathPattern)) { throw "Watch path is missing or untracked: $moduleId -> $pathPattern" }
        }
        $entrypoints = if ($isV1) {
            @($manifest.exports.commands) + @($manifest.exports.hooks) + @($manifest.exports.libraries)
        } else {
            @($manifest.entrypoints.commands) + @($manifest.entrypoints.hooks)
        }
        foreach ($entrypoint in $entrypoints) {
            Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -RelativePath ([string]$entrypoint) -Label "Module entrypoint for $moduleId"
        }
        foreach ($ownerTest in @($manifest.validation.owner_tests)) {
            $testPath = [string]$ownerTest
            Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -RelativePath $testPath -Label "Verifier owner reference for $moduleId"
            if ($testPath -cnotmatch '^tests/(?:verify-[A-Za-z0-9._-]+|run-scenario-evals)\.ps1$') { throw "owner_tests contains a non-verifier path: $moduleId -> $testPath" }
            if ($testOwners.ContainsKey($testPath)) { throw "Verifier has multiple owners: $testPath -> $($testOwners[$testPath]),$moduleId" }
            $testOwners[$testPath] = $moduleId
        }
        if ($manifest.validation.Contains('archived')) {
            if ($manifest.kind -cne 'legacy' -or $isV1 -or $manifest.default_activation -or $null -ne $manifest.validation.core_group) { throw 'Only an inactive legacy module without a CoreGroup may archive its owned tests' }
            foreach ($testPath in @($manifest.validation.archived)) {
                if (@($manifest.validation.owner_tests) -cnotcontains $testPath) { throw "Archived test is not owned by its declaring module: $testPath" }
                [void]$archivedTests.Add([string]$testPath)
            }
        }
        $coreValidationTests = [System.Collections.Generic.List[string]]::new()
        if ($isV1) {
            foreach ($group in $script:CoreGroups) {
                $coreGroupMap = $manifest.validation.core_groups
                if ($coreGroupMap -is [System.Collections.IDictionary] -and $coreGroupMap.Contains($group)) {
                    foreach ($testPath in @($coreGroupMap[$group])) { $coreValidationTests.Add([string]$testPath) }
                } else {
                    $property = $coreGroupMap.PSObject.Properties[$group]
                    if ($null -ne $property) { foreach ($testPath in @($property.Value)) { $coreValidationTests.Add([string]$testPath) } }
                }
            }
        }
        foreach ($testPath in @($manifest.validation.quick) + @($manifest.validation.changed) + @($manifest.validation.full) + @($coreValidationTests)) {
            Assert-HarnessManifestTrackedConcreteFile -RepoRoot $RepoRoot -TrackedFiles $trackedFiles -RelativePath ([string]$testPath) -Label "Validation reference for $moduleId"
        }
        if ($isV1) {
            $ownerTestSet = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
            foreach ($ownerTest in @($manifest.validation.owner_tests)) { [void]$ownerTestSet.Add([string]$ownerTest) }
            foreach ($coreTest in @($coreValidationTests)) {
                if (-not $ownerTestSet.Contains([string]$coreTest)) { throw "Capability CoreGroup test is not owned by its module: $moduleId -> $coreTest" }
            }
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

    if ($productionMode -and $capabilityPackages.Count -gt 0) {
        $expectedV1Modules = @('benchmark','harness-maintenance','md-html','memory','providers','release-evidence','team')
        $actualV1Modules = @(Get-HarnessOrdinalStrings -Values @($capabilityPackages.Keys))
        if (($actualV1Modules -join '|') -cne ($expectedV1Modules -join '|')) {
            throw "Production v1 capability set differs: expected=[$($expectedV1Modules -join ',')] actual=[$($actualV1Modules -join ',')]"
        }
        $expectedClassificationOwners = @('benchmark','engineering-validation','md-html','memory','providers','release-evidence','team')
        $actualClassificationOwners = @(Get-HarnessOrdinalStrings -Values @($classificationOwners))
        if (($actualClassificationOwners -join '|') -cne ($expectedClassificationOwners -join '|')) {
            throw "Production classification_owner set differs: expected=[$($expectedClassificationOwners -join ',')] actual=[$($actualClassificationOwners -join ',')]"
        }
        $moduleByClassificationOwner = [System.Collections.Generic.Dictionary[string,string]]::new($script:Ordinal)
        foreach ($moduleId in $actualV1Modules) {
            $moduleByClassificationOwner[[string]$byId[$moduleId].Document.classification_owner] = $moduleId
        }
        $classificationPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path 'kernel-component-classification.json' -Label 'Kernel component classification' -MustExist File
        $classification = Get-Content -LiteralPath $classificationPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        $c2Components = @($classification.components | Where-Object { [string]$_.layer -ceq 'c2-capability' })
        if ($c2Components.Count -ne 43) { throw "C2 classification count differs from the TK-07 contract: $($c2Components.Count)" }
        foreach ($component in $c2Components) {
            $owner = [string]$component.owner_candidate
            $path = [string]$component.path
            if (-not $moduleByClassificationOwner.ContainsKey($owner)) { throw "C2 classification owner has no v1 capability package: $owner -> $path" }
            $moduleId = $moduleByClassificationOwner[$owner]
            if (@($capabilityPackages[$moduleId].RoleFiles.code) -cnotcontains $path) {
                throw "C2 classified implementation is absent from package code: $owner/$moduleId -> $path"
            }
        }
    }

    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($byId.Keys))) {
        $manifest = $byId[$moduleId].Document
        foreach ($testPath in @($manifest.validation.quick) + @($manifest.validation.changed) + @($manifest.validation.full)) {
            if (-not $testOwners.ContainsKey([string]$testPath)) { throw "Validation test has no manifest owner: $moduleId -> $testPath" }
            if ($archivedTests.Contains([string]$testPath)) { throw "Archived compatibility test cannot appear in an active validation route: $testPath" }
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

    $hasV1 = $capabilityPackages.Count -gt 0
    $capabilitySourceResult = if ($hasV1) { Get-HarnessCapabilitySourceCatalogRecord -RepoRoot $RepoRoot -CapabilityPackages $capabilityPackages } else { $null }
    if ($hasV1) {
        try { $validCapabilitySources = Test-Json -Json $capabilitySourceResult.CanonicalText -SchemaFile (Join-Path $RepoRoot 'schemas\capability-source-catalog.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue }
        catch { throw "Generated Capability source catalog Schema validation failed: $($_.Exception.Message)" }
        if (-not $validCapabilitySources) { throw 'Generated Capability source catalog failed Schema validation' }
    }

    $coreGroups = [ordered]@{}
    foreach ($group in $script:CoreGroups) { $coreGroups[$group] = [System.Collections.Generic.List[string]]::new() }
    $quickTests = [System.Collections.Generic.List[string]]::new()
    $fullTests = [System.Collections.Generic.List[string]]::new()
    $optionalRoutes = [System.Collections.Generic.List[object]]::new()
    $moduleOutput = [System.Collections.Generic.List[object]]::new()
    $sourceOutput = [System.Collections.Generic.List[object]]::new()
    $v0ModuleCount = 0
    $v1ModuleCount = 0
    foreach ($moduleId in (Get-HarnessOrdinalStrings -Values @($byId.Keys))) {
        $record = $byId[$moduleId]
        $manifest = $record.Document
        $isV1 = [string]$record.SchemaVersion -ceq 'harness-module/v1'
        if ($isV1) { $v1ModuleCount++ } else { $v0ModuleCount++ }
        if ($hasV1) {
            $sourceOutput.Add([ordered]@{module_id=$moduleId;schema_version=[string]$record.SchemaVersion;path=$record.Path;digest=$record.Digest})
        } else {
            $sourceOutput.Add([ordered]@{module_id=$moduleId;path=$record.Path;digest=$record.Digest})
        }
        if ($isV1) {
            foreach ($group in $script:CoreGroups) {
                $coreGroupMap = $manifest.validation.core_groups
                if ($coreGroupMap -is [System.Collections.IDictionary] -and $coreGroupMap.Contains($group)) {
                    foreach ($testPath in @($coreGroupMap[$group])) { $coreGroups[$group].Add([string]$testPath) }
                } else {
                    $property = $coreGroupMap.PSObject.Properties[$group]
                    if ($null -ne $property) { foreach ($testPath in @($property.Value)) { $coreGroups[$group].Add([string]$testPath) } }
                }
            }
        } elseif ($null -ne $manifest.validation.core_group) {
            foreach ($testPath in @($manifest.validation.owner_tests)) { $coreGroups[[string]$manifest.validation.core_group].Add([string]$testPath) }
        }
        foreach ($testPath in @($manifest.validation.quick)) { $quickTests.Add([string]$testPath) }
        foreach ($testPath in @($manifest.validation.full)) { $fullTests.Add([string]$testPath) }

        $commonModule = [ordered]@{
            schema_version=[string]$record.SchemaVersion
            module_id=$moduleId
            kind=[string]$manifest.kind
            description=[string]$manifest.description
            default_activation=[bool]$manifest.default_activation
            dependencies=[ordered]@{kernel_api=[string]$manifest.dependencies.kernel_api;modules=@(Get-HarnessOrdinalStrings -Values @($manifest.dependencies.modules))}
            requested_capabilities=@(Get-HarnessOrdinalStrings -Values @($manifest.requested_capabilities))
            ownership=[ordered]@{owned_paths=@(Get-HarnessOrdinalStrings -Values @($manifest.ownership.owned_paths));watch_paths=@(Get-HarnessOrdinalStrings -Values @($manifest.ownership.watch_paths))}
        }
        if ($isV1) {
            $coreGroupOutput = [ordered]@{}
            foreach ($group in $script:CoreGroups) {
                $coreGroupMap = $manifest.validation.core_groups
                $hasGroup = $false
                [object[]]$groupValues = @()
                if ($coreGroupMap -is [System.Collections.IDictionary] -and $coreGroupMap.Contains($group)) {
                    $hasGroup = $true
                    $groupValues = @($coreGroupMap[$group])
                } else {
                    $property = $coreGroupMap.PSObject.Properties[$group]
                    if ($null -ne $property) { $hasGroup = $true; $groupValues = @($property.Value) }
                }
                if (-not $hasGroup) {
                    $coreGroupOutput[$group] = [object[]]@()
                } else {
                    $coreGroupOutput[$group] = [object[]]@(Get-HarnessOrdinalStrings -Values $groupValues)
                }
            }
            $normalizedModule = [ordered]@{
                schema_version=$commonModule.schema_version
                module_id=$commonModule.module_id
                module_version=[string]$manifest.module_version
                classification_owner=[string]$manifest.classification_owner
                kind=$commonModule.kind
                description=$commonModule.description
                default_activation=$commonModule.default_activation
                dependencies=$commonModule.dependencies
                requested_capabilities=$commonModule.requested_capabilities
                ownership=$commonModule.ownership
                package=$capabilityPackages[$moduleId].Package
                exports=$capabilityPackages[$moduleId].Exports
                validation=[ordered]@{
                    owner_tests=@($manifest.validation.owner_tests)
                    quick=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.quick))
                    core_groups=$coreGroupOutput
                    changed=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.changed))
                    full=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.full))
                }
                capability_source_digest=[string]$capabilityPackages[$moduleId].Source.source_digest
            }
        } else {
            $normalizedModule = [ordered]@{
                schema_version=$commonModule.schema_version
                module_id=$commonModule.module_id
                kind=$commonModule.kind
                description=$commonModule.description
                default_activation=$commonModule.default_activation
                dependencies=$commonModule.dependencies
                requested_capabilities=$commonModule.requested_capabilities
                ownership=$commonModule.ownership
                entrypoints=[ordered]@{commands=@(Get-HarnessOrdinalStrings -Values @($manifest.entrypoints.commands));hooks=@(Get-HarnessOrdinalStrings -Values @($manifest.entrypoints.hooks))}
                validation=[ordered]@{
                    owner_tests=@($manifest.validation.owner_tests)
                    quick=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.quick))
                    core_group=$(if($null-eq$manifest.validation.core_group){$null}else{[string]$manifest.validation.core_group})
                    changed=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.changed))
                    full=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.full))
                }
            }
        }
        if ($manifest.validation.Contains('archived')) { $normalizedModule.validation.archived = @(Get-HarnessOrdinalStrings -Values @($manifest.validation.archived)) }
        $moduleOutput.Add($normalizedModule)
        if (@($manifest.validation.changed).Count -gt 0) {
            $matchPaths = Get-HarnessOrdinalStrings -Values (@($manifest.ownership.owned_paths) + @($manifest.ownership.watch_paths) + @($manifest.validation.owner_tests) + @($record.Path))
            $optionalRoutes.Add([ordered]@{module_id=$moduleId;manifest_path=$record.Path;match_paths=@($matchPaths);tests=@(Get-HarnessOrdinalStrings -Values @($manifest.validation.changed))})
        }
    }
    foreach ($group in $script:CoreGroups) {
        if ($productionMode -and $coreGroups[$group].Count -eq 0) { throw "CoreGroup has no constructed tests: $group" }
        foreach ($testPath in $coreGroups[$group]) {
            if ($archivedTests.Contains([string]$testPath)) { throw "Archived compatibility test cannot appear in a CoreGroup: $group -> $testPath" }
        }
        $coreGroups[$group] = @($coreGroups[$group])
    }
    $quickOutput = @(Get-HarnessOrdinalStrings -Values @($quickTests))
    $fullOutput = @(Get-HarnessOrdinalStrings -Values @($fullTests))
    if ($productionMode) {
        $expectedFull = Get-HarnessOrdinalStrings -Values @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests') -Filter 'verify-*.ps1' -File | Where-Object { $_.Name -cne 'verify-installation.ps1' -and -not $archivedTests.Contains(('tests/' + $_.Name)) } | ForEach-Object { Get-HarnessRelativePath -WorkspaceRoot $RepoRoot -Path $_.FullName })
        if (($fullOutput -join '|') -cne ($expectedFull -join '|')) { throw 'Manifest full validation set does not equal every default full-suite verifier' }
    }
    $ownerOutput = [System.Collections.Generic.List[object]]::new()
    foreach ($testPath in (Get-HarnessOrdinalStrings -Values @($testOwners.Keys))) { $ownerOutput.Add([ordered]@{path=$testPath;module_id=$testOwners[$testPath]}) }

    $coreTestCount = 0
    foreach ($group in $script:CoreGroups) { $coreTestCount += @($coreGroups[$group]).Count }
    if ($hasV1) {
        $catalog = [ordered]@{
            schema_version='module-manifest-catalog/v1'
            generator_contract_version='module-manifest-generator/v1'
            manifest_root=$manifestRootRelative
            source_manifests=@($sourceOutput)
            modules=@($moduleOutput)
            capability_source_catalog_digest=[string]$capabilitySourceResult.Catalog.catalog_digest
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
                v0_module_count=$v0ModuleCount
                v1_module_count=$v1ModuleCount
                capability_source_count=$capabilitySourceResult.Catalog.totals.module_count
                capability_source_file_reference_count=$capabilitySourceResult.Catalog.totals.file_reference_count
                owner_test_count=$ownerOutput.Count
                core_test_count=$coreTestCount
                quick_test_count=$quickOutput.Count
                full_test_count=$fullOutput.Count
                optional_route_count=$optionalRoutes.Count
            }
        }
    } else {
        $catalog = [ordered]@{
            schema_version='module-manifest-catalog/v0'
            generator_contract_version='module-manifest-generator/v0'
            manifest_root=$manifestRootRelative
            source_manifests=@($sourceOutput)
            modules=@($moduleOutput | ForEach-Object {
                $copy = [ordered]@{}
                foreach ($key in $_.Keys) { if ($key -cne 'schema_version') { $copy[$key] = $_[$key] } }
                $copy
            })
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
    }
    if ($archivedTests.Count -gt 0) { $catalog.archived_tests = @(Get-HarnessOrdinalStrings -Values @($archivedTests)) }
    $catalogOutput = ConvertTo-HarnessManifestCanonicalOutput -Document $catalog
    $canonicalText = $catalogOutput.CanonicalText
    if ($productionMode) {
        $catalogSchema = if ($hasV1) { 'schemas\module-manifest-catalog-v1.schema.json' } else { 'schemas\module-manifest-catalog.schema.json' }
        try { $validCatalog = Test-Json -Json $canonicalText -SchemaFile (Join-Path $RepoRoot $catalogSchema) -ErrorAction Stop -WarningAction SilentlyContinue }
        catch { throw "Generated Manifest catalog Schema validation failed: $($_.Exception.Message)" }
        if (-not $validCatalog) { throw 'Generated Manifest catalog failed Schema validation' }
    }
    return [pscustomobject]@{
        Catalog=$catalog
        CanonicalText=$canonicalText
        Bytes=$catalogOutput.Bytes
        CapabilitySourceCatalog=$(if($hasV1){$capabilitySourceResult.Catalog}else{$null})
        CapabilitySourceCanonicalText=$(if($hasV1){$capabilitySourceResult.CanonicalText}else{$null})
        CapabilitySourceBytes=$(if($hasV1){$capabilitySourceResult.Bytes}else{$null})
    }
}

function Assert-HarnessModuleManifestCatalogCurrent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ManifestRoot = 'modules',
        [string]$CatalogPath = 'module-manifest-catalog.json',
        [string]$CapabilitySourceCatalogPath = 'capability-source-catalog.json'
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $result = Get-HarnessModuleManifestCatalog -RepoRoot $RepoRoot -ManifestRoot $ManifestRoot
    $catalogFullPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $CatalogPath -Label 'Module Manifest catalog' -MustExist File
    $actualBytes = [System.IO.File]::ReadAllBytes($catalogFullPath)
    if (-not (Test-HarnessManifestByteSequenceEqual -Left $actualBytes -Right $result.Bytes)) {
        throw 'Module Manifest catalog does not match generated bytes'
    }
    if ($null -ne $result.CapabilitySourceBytes) {
        $capabilitySourceFullPath = Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $CapabilitySourceCatalogPath -Label 'Capability source catalog' -MustExist File
        $actualCapabilitySourceBytes = [System.IO.File]::ReadAllBytes($capabilitySourceFullPath)
        if (-not (Test-HarnessManifestByteSequenceEqual -Left $actualCapabilitySourceBytes -Right $result.CapabilitySourceBytes)) {
            throw 'Capability source catalog does not match generated bytes'
        }
    }
    return $result
}

Export-ModuleMember -Function Get-HarnessModuleManifestCatalog,Assert-HarnessModuleManifestCatalogCurrent
