Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.CanonicalJson.psm1') -ErrorAction Stop

$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:Ordinal = [StringComparer]::Ordinal
$script:PathComparer = [StringComparer]::OrdinalIgnoreCase
$script:TemplateTargets = @('claude-global','codex-global','workspace-global','claude-settings','codex-settings','codex-hooks')

function ConvertTo-HarnessDistributionJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)

    $json = ConvertTo-Json -InputObject $Document -Depth 100 -Compress
    $bytes = Harness.CanonicalJson\ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $script:Utf8.GetBytes($json)
    return $script:Utf8.GetString($bytes)
}

function Get-DistributionDigest {
    param([System.Collections.IDictionary]$Document)

    return Harness.Hashing\Get-HarnessSha256Bytes -Bytes $script:Utf8.GetBytes((ConvertTo-HarnessDistributionJson -Document $Document))
}

function Assert-DistributionSchema {
    param([string]$RepoRoot,[System.Collections.IDictionary]$Document,[string]$Schema)

    $schemaPath = Harness.Path\Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path "schemas/$Schema.schema.json" -Label 'Distribution Schema' -MustExist File
    # Schema validation does not hash bytes. Canonical parsing and digesting are
    # separate checks; avoid canonicalizing an already parsed object again here.
    $json = ConvertTo-Json -InputObject $Document -Depth 100 -Compress
    try { $valid=Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { throw "Distribution input Schema validation failed ($Schema): $($_.Exception.Message)" }
    if (-not $valid) {
        throw "Distribution input failed Schema validation: $Schema"
    }
}

function Read-DistributionJson {
    param([string]$RepoRoot,[string]$Path,[string]$Schema)

    $full = Harness.Path\Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $Path -Label 'Distribution input' -MustExist File
    $bytes = [IO.File]::ReadAllBytes($full)
    $canonical = Harness.CanonicalJson\ConvertTo-HarnessCanonicalJsonBytes -JsonBytes $bytes
    $document = Harness.Path\ConvertFrom-HarnessJson -Json $script:Utf8.GetString($canonical)
    if ($document -isnot [System.Collections.IDictionary]) { throw "Distribution input must be an object: $Path" }
    Assert-DistributionSchema -RepoRoot $RepoRoot -Document $document -Schema $Schema
    return [pscustomobject]@{ Document=$document; Digest=(Harness.Hashing\Get-HarnessSha256Bytes -Bytes $canonical) }
}

function Test-DistributionPatternContains {
    param([string]$Pattern,[string]$Path)

    if ($Pattern.EndsWith('/**',[StringComparison]::Ordinal)) {
        return $Path.StartsWith($Pattern.Substring(0,$Pattern.Length-2),[StringComparison]::Ordinal)
    }
    return $Path -ceq $Pattern
}

function Test-DistributionPatternOverlap {
    param([string]$Left,[string]$Right)

    $leftTree = $Left.EndsWith('/**',[StringComparison]::Ordinal)
    $rightTree = $Right.EndsWith('/**',[StringComparison]::Ordinal)
    $leftBase = if ($leftTree) { $Left.Substring(0,$Left.Length-3) } else { $Left }
    $rightBase = if ($rightTree) { $Right.Substring(0,$Right.Length-3) } else { $Right }
    return $script:PathComparer.Equals($leftBase,$rightBase) -or
        ($leftTree -and $rightBase.StartsWith($leftBase + '/',[StringComparison]::OrdinalIgnoreCase)) -or
        ($rightTree -and $leftBase.StartsWith($rightBase + '/',[StringComparison]::OrdinalIgnoreCase))
}

function Get-DistributionManifests {
    param([string]$RepoRoot)

    # Consume published data, never import or execute the C2 catalog constructor.
    # The catalog binds the exact shipped Manifest set, including archive installs.
    $catalog = Read-DistributionJson -RepoRoot $RepoRoot -Path 'module-manifest-catalog.json' -Schema 'module-manifest-catalog-v1'
    $root = Harness.Path\Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path 'modules' -Label 'Distribution Manifest root' -MustExist Directory
    $physical = [Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -Force) {
        $relative = "modules/$($directory.Name)/module.manifest.json"
        [void](Harness.Path\Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $relative -Label 'Distribution Manifest' -MustExist File)
        [void]$physical.Add($relative)
    }
    $byId = [Collections.Generic.Dictionary[string,object]]::new($script:Ordinal)
    $inputs = [Collections.Generic.List[object]]::new()
    $owners = [Collections.Generic.List[object]]::new()
    foreach ($record in @($catalog.Document.source_manifests)) {
        $id = [string]$record.module_id
        $path = [string]$record.path
        if ($path -cne "modules/$id/module.manifest.json" -or -not $physical.Remove($path)) { throw 'Distribution Manifest set is duplicated or differs from its catalog' }
        $schema = if ([string]$record.schema_version -ceq 'harness-module/v1') { 'module-manifest-v1' } else { 'module-manifest' }
        $input = Read-DistributionJson -RepoRoot $RepoRoot -Path $path -Schema $schema
        $manifest = $input.Document
        if ([string]$manifest.module_id -cne $id -or [string]$manifest.schema_version -cne [string]$record.schema_version -or
            $input.Digest -cne [string]$record.digest -or -not $byId.TryAdd($id,$manifest)) {
            throw "Distribution Manifest identity or catalog digest differs: $id"
        }
        $inputs.Add([ordered]@{module_id=$id;path=$path;digest=$input.Digest})
        foreach ($pattern in @($manifest.ownership.owned_paths)) {
            foreach ($owner in $owners) {
                if (Test-DistributionPatternOverlap -Left $pattern -Right $owner.Pattern) { throw "Distribution Manifest ownership conflict: $id / $($owner.Id)" }
            }
            $owners.Add([pscustomobject]@{Id=$id;Pattern=[string]$pattern})
        }
        if ($manifest.schema_version -ceq 'harness-module/v1') {
            foreach ($request in @($manifest.package.install_assets)) {
                $requestBase = ([string]$request) -creplace '/\*\*$','/__distribution_asset__'
                if (@($manifest.ownership.owned_paths | Where-Object { Test-DistributionPatternContains -Pattern $_ -Path $requestBase }).Count -eq 0) {
                    throw "Distribution asset request is not owned: $id -> $request"
                }
            }
        }
    }
    $catalogIds = [Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($module in @($catalog.Document.modules)) {
        if (-not $catalogIds.Add([string]$module.module_id) -or -not $byId.ContainsKey([string]$module.module_id)) { throw 'Distribution catalog module identities differ from its Manifest inputs' }
    }
    if ($physical.Count -ne 0 -or $byId.Count -ne $catalogIds.Count) { throw 'Distribution Manifest set differs from its published catalog' }
    $visiting = [Collections.Generic.HashSet[string]]::new($script:Ordinal)
    $visited = [Collections.Generic.HashSet[string]]::new($script:Ordinal)
    function Visit-DistributionModule([string]$Id) {
        if (-not $byId.ContainsKey($Id)) { throw "Unknown Distribution module dependency: $Id" }
        if ($visited.Contains($Id)) { return }
        if (-not $visiting.Add($Id)) { throw "Distribution module dependency cycle: $Id" }
        foreach ($dependency in @($byId[$Id].dependencies.modules)) { Visit-DistributionModule -Id $dependency }
        [void]$visiting.Remove($Id)
        [void]$visited.Add($Id)
    }
    foreach ($id in $byId.Keys) { Visit-DistributionModule -Id $id }
    return [pscustomobject]@{ById=$byId;Inputs=@($inputs);CatalogDigest=$catalog.Digest}
}

function Get-DistributionTreeFiles {
    param([string]$RepoRoot,[string]$RelativeRoot)

    $root = Harness.Path\Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $RelativeRoot -Label 'Distribution skill directory' -MustExist Directory
    $files = [Collections.Generic.List[string]]::new()
    $directories = [Collections.Generic.Stack[string]]::new()
    $directories.Push($root)
    while ($directories.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $directories.Pop() -Force) {
            # Reject before descent: no link traversal while constructing desired state.
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Distribution skill source contains a reparse point' }
            if ($entry.PSIsContainer) { $directories.Push($entry.FullName) }
            else { $files.Add([IO.Path]::GetRelativePath($RepoRoot,$entry.FullName).Replace('\','/')) }
        }
    }
    $files.Sort($script:Ordinal)
    return @($files)
}

function Assert-DistributionAssetShape {
    param([System.Collections.IDictionary]$Asset)

    $source = [string]$Asset.source
    $target = [string]$Asset.target
    foreach ($path in @($source,$target) + @($Asset.files)) {
        foreach ($segment in ([string]$path).Split('/')) {
            if ($segment.EndsWith('.',[StringComparison]::Ordinal) -or $segment -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)') {
                throw 'Distribution asset path contains a Windows alias or device segment'
            }
        }
    }
    switch ([string]$Asset.kind) {
        'skill' {
            if ($target -cnotmatch '^[a-z][a-z0-9-]+$' -or $source -cne "skills/$target/SKILL.md") { throw 'Distribution skill mapping is invalid' }
            foreach ($file in @($Asset.files)) {
                if (-not ([string]$file).StartsWith("skills/$target/",[StringComparison]::Ordinal)) { throw 'Distribution skill support file escapes its explicit directory' }
            }
        }
        'hook' {
            if ($source -cnotmatch '^runtime-hooks/(?:claude|memory)/[a-z][a-z0-9-]+\.(?:ps1|js)$' -or $target -cne ($source.Split('/')[-1])) { throw 'Distribution hook mapping is invalid' }
        }
        'vault' {
            if (-not $source.StartsWith('vault-template/',[StringComparison]::Ordinal) -or $target -cne ($source.Substring(15) -creplace '\.template$','')) { throw 'Distribution vault mapping is invalid' }
        }
        'template' {
            if ($script:TemplateTargets -cnotcontains $target -or $source -cnotmatch '^agent-configs/(?:claude|codex|workspace)/[A-Za-z0-9._-]+\.template$') { throw 'Distribution host template mapping is invalid' }
        }
    }
    if (@($Asset.files) -cnotcontains $source) { throw 'Distribution asset source is absent from its file allowlist' }
    if ($Asset.kind -cne 'skill' -and @($Asset.files).Count -ne 1) { throw 'Only skill transport may explicitly include support files' }
    if ($Asset.kind -cne 'vault' -and $Asset.ownership -cne 'managed') { throw 'Distribution non-vault asset ownership must be managed' }
}

function Get-HarnessDistributionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('core','governed','full')][string]$Preset
    )

    $RepoRoot = Harness.Path\Resolve-HarnessWorkspaceRoot -WorkspaceRoot $RepoRoot
    $profileInput = Read-DistributionJson -RepoRoot $RepoRoot -Path "modules/distribution/profiles/$Preset.json" -Schema 'install-profile'
    $profile = $profileInput.Document
    if ($profile.profile_id -cne $Preset) { throw 'Install Profile id does not match the selected preset' }
    if (($Preset -ceq 'full') -ne ($profile.vault_profile -ceq 'full')) { throw 'Install Profile vault mode differs from the preset compatibility contract' }
    $manifests = Get-DistributionManifests -RepoRoot $RepoRoot
    $enabled = [Collections.Generic.HashSet[string]]::new($script:Ordinal)
    foreach ($module in @($profile.enabled_modules)) {
        $id = [string]$module.module_id
        if (-not $enabled.Add($id) -or -not $manifests.ById.ContainsKey($id)) { throw "Duplicate or unknown enabled Distribution module: $id" }
        foreach ($capability in @($manifests.ById[$id].requested_capabilities)) {
            if (@($module.allowed_capabilities) -cnotcontains $capability) { throw "Distribution capability request exceeds Profile allowlist: $id -> $capability" }
        }
    }
    foreach ($id in $enabled) {
        foreach ($dependency in @($manifests.ById[$id].dependencies.modules)) {
            if (-not $enabled.Contains($dependency)) { throw "Enabled Distribution module requires a disabled dependency: $id -> $dependency" }
        }
    }
    $ids = [Collections.Generic.HashSet[string]]::new($script:PathComparer)
    $targets = [Collections.Generic.HashSet[string]]::new($script:PathComparer)
    $sourcePaths = [Collections.Generic.HashSet[string]]::new($script:PathComparer)
    $assets = [Collections.Generic.List[object]]::new()
    $authorized = [Collections.Generic.List[object]]::new()
    foreach ($asset in @($profile.asset_allowlist)) {
        Assert-DistributionAssetShape -Asset $asset
        $targetKey = "$($asset.kind)/$($asset.target)"
        foreach ($otherTarget in $targets) {
            if ($targetKey.StartsWith($otherTarget + '/',[StringComparison]::OrdinalIgnoreCase) -or $otherTarget.StartsWith($targetKey + '/',[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Distribution asset target paths overlap as file and directory'
            }
        }
        if (-not $ids.Add([string]$asset.id) -or -not $targets.Add($targetKey)) { throw 'Distribution Profile contains duplicate or case-colliding assets/targets' }
        foreach ($file in @($asset.files)) {
            if (-not $sourcePaths.Add([string]$file)) { throw 'Distribution Profile file allowlists overlap or case-collide' }
        }
        $id = [string]$asset.module_id
        if (-not $manifests.ById.ContainsKey($id)) { throw "Distribution asset references an unknown module: $id" }
        $manifest = $manifests.ById[$id]
        if ($asset.origin -ceq 'module-request' -and $manifest.schema_version -cne 'harness-module/v1') { throw 'Only v1 Manifests declare install asset requests' }
        if (-not $enabled.Contains($id)) { continue }
        if ($asset.origin -ceq 'module-request') {
            if (@($manifest.package.install_assets | Where-Object { Test-DistributionPatternContains -Pattern $_ -Path $asset.source }).Count -eq 0) { continue }
            $authorized.Add([ordered]@{module_id=$id;path=[string]$asset.source})
        } elseif ($manifest.schema_version -ceq 'harness-module/v1') {
            # Existing exported hook transport is explicitly Profile-owned, not an
            # install_assets request or a permission inferred from default_activation.
            if ($asset.kind -cne 'hook' -or @($manifest.exports.hooks) -cnotcontains $asset.source) { throw 'Capability bootstrap transport must be an explicitly allowed exported hook' }
        }
        if ($manifest.schema_version -ceq 'harness-module/v1') {
            foreach ($file in @($asset.files)) {
                if (@(@($manifest.package.install_assets) + @($manifest.package.code) | Where-Object { Test-DistributionPatternContains -Pattern $_ -Path $file }).Count -eq 0) {
                    throw "Explicit capability transport file is not declared by its module: $id -> $file"
                }
            }
        }
        if ($asset.kind -ceq 'skill') {
            $actualFiles = @(Get-DistributionTreeFiles -RepoRoot $RepoRoot -RelativeRoot "skills/$($asset.target)")
            [string[]]$expectedFiles = @($asset.files)
            [Array]::Sort($expectedFiles,$script:Ordinal)
            if (($actualFiles -join "`n") -cne ($expectedFiles -join "`n")) { throw "Distribution skill file set differs from its explicit Profile allowlist: $($asset.target)" }
        }
        $files = [Collections.Generic.List[object]]::new()
        foreach ($file in @($asset.files)) {
            $full = Harness.Path\Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $file -Label 'Authorized Distribution source' -MustExist File
            $bytes = [IO.File]::ReadAllBytes($full)
            if ($file -match '\.(?:template|md|json|js|mjs|toml|txt|ps1|psm1|psd1|sh)$') {
                try { [void]$script:Utf8.GetString($bytes) }
                catch { throw "Distribution text source is not valid UTF-8: $file" }
            }
            $files.Add([ordered]@{path=[string]$file;sha256=(Harness.Hashing\Get-HarnessSha256Bytes -Bytes $bytes)})
        }
        $planned = [ordered]@{}
        foreach ($key in @('id','kind','origin','module_id','source','target','ownership')) { $planned[$key]=$asset[$key] }
        $planned.files = @($files)
        $assets.Add($planned)
    }
    $templateTargets = @($assets | Where-Object kind -CEQ 'template' | ForEach-Object target)
    if ($templateTargets.Count -ne $script:TemplateTargets.Count -or @($script:TemplateTargets | Where-Object { $templateTargets -cnotcontains $_ }).Count -ne 0) { throw 'Distribution plan is missing mandatory host templates' }
    foreach ($hook in @('pretooluse.ps1','codex-pretooluse-launcher.ps1','stop.js','workspace-resolver.js')) {
        if (@($assets | Where-Object { $_.kind -ceq 'hook' -and $_.target -ceq $hook }).Count -ne 1) { throw "Distribution plan is missing a mandatory hook: $hook" }
    }
    [string[]]$enabledIds = @($enabled)
    [Array]::Sort($enabledIds,$script:Ordinal)
    $plan = [ordered]@{
        schema_version='distribution-plan/v1'
        digest_algorithm='canonical-json/v1'
        profile_id=$Preset
        profile_digest=$profileInput.Digest
        catalog_digest=$manifests.CatalogDigest
        manifest_inputs=@($manifests.Inputs)
        enabled_modules=$enabledIds
        features=@($profile.features)
        vault_profile=[string]$profile.vault_profile
        system_skill=$true
        authorized_module_assets=@($authorized)
        assets=@($assets)
    }
    $plan.digest = Get-DistributionDigest -Document $plan
    Assert-DistributionSchema -RepoRoot $RepoRoot -Document $plan -Schema 'distribution-plan'
    return $plan
}

function Assert-HarnessDistributionPlanCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Plan)

    Assert-DistributionSchema -RepoRoot $RepoRoot -Document $Plan -Schema 'distribution-plan'
    $unsigned = [ordered]@{}
    foreach ($key in $Plan.Keys) { if ($key -cne 'digest') { $unsigned[$key]=$Plan[$key] } }
    if ([string]$Plan.digest -cne (Get-DistributionDigest -Document $unsigned)) { throw 'Distribution plan digest does not match its content' }
    $expected = Get-HarnessDistributionPlan -RepoRoot $RepoRoot -Preset $Plan.profile_id
    if ([string]$Plan.digest -cne [string]$expected.digest) { throw 'Distribution plan is stale or does not match current Profile authorization and source bytes' }
}

function Read-HarnessDistributionSourceText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Plan,[Parameter(Mandatory)][string]$Source)

    $records = @($Plan.assets | ForEach-Object files | Where-Object { $_.path -ceq $Source })
    if ($records.Count -ne 1) { throw 'Source is not one exact file in the Distribution plan' }
    $path = Harness.Path\Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $Source -Label 'Planned Distribution source' -MustExist File
    $bytes = [IO.File]::ReadAllBytes($path)
    if ((Harness.Hashing\Get-HarnessSha256Bytes -Bytes $bytes) -cne [string]$records[0].sha256) { throw 'Distribution source bytes changed after planning' }
    $text = $script:Utf8.GetString($bytes)
    if ($text.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)) { $text=$text.Substring(1) }
    return $text
}

function Assert-HarnessDistributionSkillSourcesCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Plan)

    # A consumer-side freshness check, not an alternative authorization API.
    # The installer calls this only after constructing and validating the Plan.
    foreach ($asset in @($Plan.assets | Where-Object kind -CEQ 'skill')) {
        [string[]]$expected = @($asset.files | ForEach-Object path)
        [Array]::Sort($expected,$script:Ordinal)
        $actual = @(Get-DistributionTreeFiles -RepoRoot $RepoRoot -RelativeRoot "skills/$($asset.target)")
        if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'Distribution skill source set changed before linking' }
        foreach ($file in @($asset.files)) {
            $path=Harness.Path\Resolve-HarnessContainedPath -WorkspaceRoot $RepoRoot -Path $file.path -Label 'Planned skill source' -MustExist File
            if ((Harness.Hashing\Get-HarnessFileSha256 -Path $path) -cne [string]$file.sha256) { throw 'Distribution skill source bytes changed before linking' }
        }
    }
}

Export-ModuleMember -Function Get-HarnessDistributionPlan,Assert-HarnessDistributionPlanCurrent,ConvertTo-HarnessDistributionJson,Read-HarnessDistributionSourceText,Assert-HarnessDistributionSkillSourcesCurrent
