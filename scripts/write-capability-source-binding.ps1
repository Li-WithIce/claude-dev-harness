[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][ValidateSet('model','host','full')][string]$Kind,
    [Parameter(Mandatory)][string]$ArtifactRoot,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40,64}$')][string]$SourceRevision,
    [ValidateSet('formal','test-only')][string]$ProducerMode = 'formal',
    [string]$ModelBindingPath = '',
    [string]$HostBindingPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ArtifactRoot = (Resolve-Path -LiteralPath $ArtifactRoot).Path

Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.CapabilitySource.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.CanonicalJson.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Hashing.psm1') -Force -ErrorAction Stop

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false,$true)
$script:Ordinal = [System.StringComparer]::Ordinal
$script:PathComparer = if ($IsWindows) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
$script:BindingSchemaPath = Join-Path $RepoRoot 'schemas\capability-source-binding.schema.json'
$script:BindingSourceClosure = $null

function Get-Definition {
    param([string]$BindingKind)

    switch ($BindingKind) {
        'model' {
            return [pscustomobject]@{
                FileName='model-capability-source-binding.json'
                Modules=@('benchmark','release-evidence')
                Artifacts=@('model-eval.json','model-runner-observation.json','release-model-receipt.json')
            }
        }
        'host' {
            return [pscustomobject]@{
                FileName='host-capability-source-binding.json'
                Modules=@('benchmark','release-evidence')
                Artifacts=@(
                    'cognitive-host.json',
                    'host-runner-observation.json',
                    'installed-desktop-distinct.json',
                    'installed-desktop-primary.json',
                    'lifecycle-core.json',
                    'lifecycle-full.json',
                    'lifecycle-governed.json',
                    'release-host-receipt.json',
                    'v1-stop-loss.json'
                )
            }
        }
        'full' {
            return [pscustomobject]@{
                FileName='full-capability-source-binding.json'
                Modules=@('release-evidence')
                Artifacts=@(
                    'aggregator-runner-observation.json',
                    'exact-head-engineering.json',
                    'release-full-receipt.json',
                    'release-isolation.json'
                )
            }
        }
    }
}

function Get-CanonicalRecord {
    param([System.Collections.IDictionary]$Document)

    $json = $Document | ConvertTo-Json -Depth 100 -Compress
    [byte[]]$canonicalBytes = ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $script:Utf8NoBom.GetBytes($json)
    return [pscustomobject]@{
        Text=$script:Utf8NoBom.GetString($canonicalBytes)
        Digest=(Get-HarnessSha256Bytes -Bytes $canonicalBytes)
    }
}

function Get-RequiredSourceClosure {
    param([string[]]$ModuleId)

    if ($null -eq $script:BindingSourceClosure) { throw 'binding source closure is not initialized' }
    $byId = [System.Collections.Generic.Dictionary[string,object]]::new($script:Ordinal)
    foreach ($source in @($script:BindingSourceClosure.Sources)) { $byId[[string]$source.module_id] = $source }
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ModuleId) {
        if (-not $byId.ContainsKey($id)) { throw "binding Capability source is unavailable: $id" }
        $selected.Add($byId[$id])
    }
    return [pscustomobject]@{CatalogDigest=[string]$script:BindingSourceClosure.CatalogDigest;Sources=@($selected)}
}

function Test-ByteSequenceEqual {
    param([byte[]]$Left,[byte[]]$Right)
    return $Left.Length -eq $Right.Length -and [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right)
}

function Resolve-ExpectedArtifactPath {
    param([string]$FileName,[string]$Label)

    $path = Join-Path $ArtifactRoot $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Label is missing: $FileName" }
    $item = Get-Item -LiteralPath $path -Force
    if ($item -isnot [System.IO.FileInfo] -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label must be a regular non-reparse file: $FileName"
    }
    $resolved = (Resolve-Path -LiteralPath $path).Path
    if (-not $script:PathComparer.Equals($resolved,[System.IO.Path]::GetFullPath($path))) { throw "$Label escaped ArtifactRoot: $FileName" }
    return $resolved
}

function Get-ArtifactRecords {
    param([string[]]$FileNames)

    $seen = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($fileName in $FileNames) {
        if (-not $seen.Add($fileName)) { throw "duplicate bundle artifact path: $fileName" }
        $path = Resolve-ExpectedArtifactPath -FileName $fileName -Label 'bundle artifact'
        $records.Add([ordered]@{path=$fileName;sha256=(Get-HarnessFileSha256 -Path $path)})
    }
    return @($records)
}

function Assert-FormalSource {
    $head = (& git -c core.fsmonitor=false -C $RepoRoot rev-parse HEAD 2>&1)
    if ($LASTEXITCODE -ne 0 -or @($head).Count -ne 1) { throw 'unable to resolve formal source HEAD' }
    if ([string]$head[0] -cne $SourceRevision) { throw 'formal source revision does not match HEAD' }
    & git -c core.fsmonitor=false -C $RepoRoot diff --quiet --no-ext-diff
    if ($LASTEXITCODE -ne 0) { throw 'formal source has unstaged tracked changes' }
    & git -c core.fsmonitor=false -C $RepoRoot diff --cached --quiet --no-ext-diff
    if ($LASTEXITCODE -ne 0) { throw 'formal source has staged changes' }
}

function Assert-BindingArtifact {
    param(
        [string]$Path,
        [string]$ExpectedKind,
        [string]$ExpectedRevision
    )

    $definition = Get-Definition -BindingKind $ExpectedKind
    $expectedPath = Join-Path $ArtifactRoot $definition.FileName
    $actualPath = (Resolve-Path -LiteralPath $Path).Path
    if (-not $script:PathComparer.Equals($actualPath,(Resolve-Path -LiteralPath $expectedPath).Path)) { throw "unexpected $ExpectedKind binding path" }

    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($actualPath)
    if ($bytes.Length -lt 2 -or $bytes[-1] -ne 0x0A -or $bytes[-2] -eq 0x0A) { throw "$ExpectedKind binding must end with exactly one LF" }
    [byte[]]$jsonBytes = [byte[]]::new($bytes.Length - 1)
    [Array]::Copy($bytes,0,$jsonBytes,0,$jsonBytes.Length)
    [byte[]]$canonicalBytes = ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $jsonBytes
    if (-not (Test-ByteSequenceEqual -Left $jsonBytes -Right $canonicalBytes)) { throw "$ExpectedKind binding is not canonical-json/v1 output" }
    $json = $script:Utf8NoBom.GetString($jsonBytes)
    try { $document = ConvertFrom-HarnessJson -Json $json }
    catch { throw "$ExpectedKind binding is invalid JSON: $($_.Exception.Message)" }
    try { $schemaValid = Test-Json -Json $json -SchemaFile $script:BindingSchemaPath -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { throw "$ExpectedKind binding Schema validation failed: $($_.Exception.Message)" }
    if (-not $schemaValid) { throw "$ExpectedKind binding failed Schema validation" }
    if ([string]$document.binding_kind -cne $ExpectedKind -or [string]$document.source_revision -cne $ExpectedRevision) { throw "$ExpectedKind binding identity mismatch" }

    $withoutDigest = [ordered]@{}
    foreach ($key in @($document.Keys)) {
        if ([string]$key -cne 'binding_digest') { $withoutDigest[[string]$key] = $document[$key] }
    }
    $digest = (Get-CanonicalRecord -Document $withoutDigest).Digest
    if ($digest -cne [string]$document.binding_digest) { throw "$ExpectedKind binding digest mismatch" }

    $closure = Get-RequiredSourceClosure -ModuleId $definition.Modules
    if ([string]$document.source_catalog_digest -cne [string]$closure.CatalogDigest) { throw "$ExpectedKind binding source catalog mismatch" }
    $actualSources = @($document.module_sources | ForEach-Object { "{0}|{1}" -f [string]$_.module_id,[string]$_.source_digest })
    $expectedSources = @($closure.Sources | ForEach-Object { "{0}|{1}" -f [string]$_.module_id,[string]$_.source_digest })
    if (($actualSources -join "`n") -cne ($expectedSources -join "`n")) { throw "$ExpectedKind binding module source mismatch" }

    $actualArtifacts = @($document.artifacts | ForEach-Object { "{0}|{1}" -f [string]$_.path,[string]$_.sha256 })
    $expectedArtifacts = @(Get-ArtifactRecords -FileNames $definition.Artifacts | ForEach-Object { "{0}|{1}" -f [string]$_.path,[string]$_.sha256 })
    if (($actualArtifacts -join "`n") -cne ($expectedArtifacts -join "`n")) { throw "$ExpectedKind binding artifact digest mismatch" }
    return $document
}

$definition = Get-Definition -BindingKind $Kind
$expectedOutput = [System.IO.Path]::GetFullPath((Join-Path $ArtifactRoot $definition.FileName))
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
if (-not $script:PathComparer.Equals($resolvedOutput,$expectedOutput)) { throw "binding output must be $($definition.FileName) under ArtifactRoot" }
if ($ProducerMode -ceq 'formal') { Assert-FormalSource }
$script:BindingSourceClosure = Get-HarnessCapabilitySourceClosure -RepoRoot $RepoRoot -ModuleId @('benchmark','release-evidence')

if ($Kind -ceq 'full') {
    if ([string]::IsNullOrWhiteSpace($ModelBindingPath)) { $ModelBindingPath = Join-Path $ArtifactRoot 'model-capability-source-binding.json' }
    if ([string]::IsNullOrWhiteSpace($HostBindingPath)) { $HostBindingPath = Join-Path $ArtifactRoot 'host-capability-source-binding.json' }
    $null = Assert-BindingArtifact -Path $ModelBindingPath -ExpectedKind model -ExpectedRevision $SourceRevision
    $null = Assert-BindingArtifact -Path $HostBindingPath -ExpectedKind host -ExpectedRevision $SourceRevision
} elseif (-not [string]::IsNullOrWhiteSpace($ModelBindingPath) -or -not [string]::IsNullOrWhiteSpace($HostBindingPath)) {
    throw 'upstream binding paths are accepted only for full binding'
}

$closure = Get-RequiredSourceClosure -ModuleId $definition.Modules
$withoutDigest = [ordered]@{
    schema_version='capability-source-binding/v1'
    binding_kind=$Kind
    source_revision=$SourceRevision
    source_catalog_digest=[string]$closure.CatalogDigest
    digest_algorithm='canonical-json/v1'
    module_sources=@($closure.Sources)
    artifacts=@(Get-ArtifactRecords -FileNames $definition.Artifacts)
}
$binding = [ordered]@{}
foreach ($key in $withoutDigest.Keys) { $binding[$key] = $withoutDigest[$key] }
$binding.binding_digest = (Get-CanonicalRecord -Document $withoutDigest).Digest
$canonical = Get-CanonicalRecord -Document $binding
try { $schemaValid = Test-Json -Json $canonical.Text -SchemaFile $script:BindingSchemaPath -ErrorAction Stop -WarningAction SilentlyContinue }
catch { throw "Capability source binding Schema validation failed: $($_.Exception.Message)" }
if (-not $schemaValid) { throw 'Capability source binding failed Schema validation' }

$rawDigest = Write-HarnessAtomicText -WorkspaceRoot $ArtifactRoot -Path $definition.FileName -Content ($canonical.Text + "`n")
Write-Output "Capability source binding written: kind=$Kind; modules=$(@($binding.module_sources).Count); artifacts=$(@($binding.artifacts).Count); digest=$($binding.binding_digest); raw=$rawDigest"
exit 0
