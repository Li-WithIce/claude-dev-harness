Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.CanonicalJson.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.ModuleManifest.psm1') -Force -ErrorAction Stop

$script:Ordinal = [System.StringComparer]::Ordinal

function Get-HarnessCapabilitySourceClosure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ModuleId
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $requested = [System.Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($id in $ModuleId) {
        if ($id -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "invalid capability module id: $id" }
        if (-not $requested.Add($id)) { throw "duplicate capability module id: $id" }
    }

    $construction = Harness.ModuleManifest\Assert-HarnessModuleManifestCatalogCurrent -RepoRoot $RepoRoot
    if ($null -eq $construction.CapabilitySourceCatalog) { throw 'capability source catalog is unavailable' }

    $byId = [System.Collections.Generic.Dictionary[string,object]]::new($script:Ordinal)
    foreach ($source in @($construction.CapabilitySourceCatalog.sources)) {
        $id = [string]$source.module_id
        if (-not $byId.TryAdd($id,$source)) { throw "duplicate capability source record: $id" }
    }

    [string[]]$orderedIds = @($requested)
    [Array]::Sort($orderedIds,$script:Ordinal)
    $sources = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $orderedIds) {
        if (-not $byId.ContainsKey($id)) { throw "capability source record does not exist: $id" }
        $source = $byId[$id]
        $sources.Add([ordered]@{
            module_id=$id
            source_digest=[string]$source.source_digest
        })
    }

    return [pscustomobject]@{
        CatalogDigest=[string]$construction.CapabilitySourceCatalog.catalog_digest
        Sources=@($sources)
    }
}

Export-ModuleMember -Function Get-HarnessCapabilitySourceClosure
