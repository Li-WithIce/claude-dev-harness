Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
$script:RolloutAtomicModule = Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -PassThru -ErrorAction Stop
. (Join-Path $PSScriptRoot '..\host-benchmark\HostBenchmark.Trial.ps1')

function Get-ReleaseSha256Bytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-ReleaseSha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return Get-ReleaseSha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Get-ReleaseFileDigest {
    param([Parameter(Mandatory)][string]$Path)
    return Get-ReleaseSha256Bytes -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Invoke-ReleaseGit {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git -C $RepoRoot @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "release qualification Git command failed: git $($Arguments -join ' ')" }
    return $output
}

function Test-ReleasePathAtOrBelow {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root)
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $pathFull.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -or $pathFull.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)
}

function Assert-ReleasePathHasNoReparseAncestor {
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw 'release-output-parent-unavailable' }
        $cursor = $parent
    }
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)) { throw 'release-output-link-alias-rejected' }
        $parentItem = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parentItem -or $parentItem.FullName.Equals($cursor,[StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = $parentItem.FullName
    }
}

function Resolve-HarnessReleaseArtifactPath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$OutputPath,
        [string[]]$EvidencePaths = @(),
        [string[]]$ProtectedRoots = @()
    )
    $root = (Resolve-Path -LiteralPath $RepoRoot).Path
    $target = if ([IO.Path]::IsPathRooted($OutputPath)) { [IO.Path]::GetFullPath($OutputPath) } else { [IO.Path]::GetFullPath((Join-Path $root $OutputPath)) }
    if (Test-Path -LiteralPath $target) { throw 'release-output-already-exists' }
    Assert-ReleasePathHasNoReparseAncestor -Path $target
    $physicalTarget = Get-HostPhysicalPathInfo -Path $target -AllowMissing -RejectLinks
    $physicalRoot = Get-HostPhysicalPathInfo -Path $root
    $gitDirectoryText = (@(Invoke-ReleaseGit -RepoRoot $root -Arguments @('rev-parse','--git-dir')) -join '').Trim()
    $gitDirectory = if ([IO.Path]::IsPathRooted($gitDirectoryText)) { [IO.Path]::GetFullPath($gitDirectoryText) } else { [IO.Path]::GetFullPath((Join-Path $root $gitDirectoryText)) }
    $physicalGitDirectory = Get-HostPhysicalPathInfo -Path $gitDirectory
    if ((Test-ReleasePathAtOrBelow -Path ([string]$physicalTarget.physical_path) -Root ([string]$physicalGitDirectory.physical_path)) -or (Test-ReleasePathAtOrBelow -Path ([string]$physicalGitDirectory.physical_path) -Root ([string]$physicalTarget.physical_path))) { throw 'release-output-overlaps-git-metadata' }
    foreach ($path in @($EvidencePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $inputPath = [IO.Path]::GetFullPath($path)
        $physicalInput = Get-HostPhysicalPathInfo -Path $inputPath -AllowMissing
        if ((Test-ReleasePathAtOrBelow -Path ([string]$physicalTarget.physical_path) -Root ([string]$physicalInput.physical_path)) -or (Test-ReleasePathAtOrBelow -Path ([string]$physicalInput.physical_path) -Root ([string]$physicalTarget.physical_path))) { throw 'release-output-overlaps-evidence-input' }
    }
    foreach ($path in @($ProtectedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $protected = [IO.Path]::GetFullPath($path)
        $physicalProtected = Get-HostPhysicalPathInfo -Path $protected -AllowMissing
        if ((Test-ReleasePathAtOrBelow -Path ([string]$physicalTarget.physical_path) -Root ([string]$physicalProtected.physical_path)) -or (Test-ReleasePathAtOrBelow -Path ([string]$physicalProtected.physical_path) -Root ([string]$physicalTarget.physical_path))) { throw 'release-output-overlaps-credential-home' }
    }
    if (Test-ReleasePathAtOrBelow -Path ([string]$physicalTarget.physical_path) -Root ([string]$physicalRoot.physical_path)) {
        $relative = [IO.Path]::GetRelativePath($root,$target).Replace('\','/')
        $null = @(& git -C $root ls-files --error-unmatch -- $relative 2>$null)
        if ($LASTEXITCODE -eq 0) { throw 'release-output-overlaps-tracked-source' }
        $null = @(& git -C $root check-ignore --no-index --quiet -- $relative 2>$null)
        if ($LASTEXITCODE -ne 0) { throw 'release-output-inside-source-must-be-ignored' }
    }
    return $target
}

function Resolve-ReleaseGitPath {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Argument)
    $value = (@(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('rev-parse',$Argument)) -join '').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'rollout-promotion-git-path-unavailable' }
    if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $value))
}

function Assert-ReleaseSingleLinkFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "rollout-promotion-$Label-not-file" }
    $links = @(& fsutil hardlink list $Path 2>$null | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0) { throw "rollout-promotion-$Label-physical-identity-unavailable" }
    if ($links.Count -ne 1) { throw "rollout-promotion-$Label-hardlink-rejected" }
}

function Assert-ReleaseSingleDataStreamFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    $streams = @(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop)
    if ($streams.Count -ne 1 -or [string]$streams[0].Stream -cne ':$DATA') { throw "rollout-promotion-$Label-alternate-stream-rejected" }
}

function Resolve-HarnessRolloutPromotionPaths {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ReportPath,
        [string[]]$ProtectedRoots = @()
    )

    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $workspace = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $physicalWorkspace = Get-HostPhysicalPathInfo -Path $workspace -RejectLinks
    $workspaceIdentity = ('{0}|{1}' -f [string]$physicalWorkspace.volume,[string]$physicalWorkspace.file_id).ToLowerInvariant()
    if (-not [IO.Path]::IsPathRooted($ReportPath)) { throw 'rollout-promotion-input-must-be-absolute' }
    $source = [IO.Path]::GetFullPath($ReportPath)
    Assert-ReleasePathHasNoReparseAncestor -Path $source
    Assert-ReleaseSingleLinkFile -Path $source -Label 'input'
    Assert-ReleaseSingleDataStreamFile -Path $source -Label 'input'
    $physicalSource = Get-HostPhysicalPathInfo -Path $source -RejectLinks

    $gitDirectory = Resolve-ReleaseGitPath -RepoRoot $repo -Argument '--git-dir'
    $gitCommonDirectory = Resolve-ReleaseGitPath -RepoRoot $repo -Argument '--git-common-dir'
    $forbidden = @($repo,$workspace,$gitDirectory,$gitCommonDirectory) + @($ProtectedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_) })
    foreach ($root in @($forbidden | Select-Object -Unique)) {
        if (Test-ReleasePathAtOrBelow -Path $source -Root $root) { throw 'rollout-promotion-input-overlaps-protected-root' }
        $physicalRoot = Get-HostPhysicalPathInfo -Path $root -AllowMissing
        if ((Test-ReleasePathAtOrBelow -Path ([string]$physicalSource.physical_path) -Root ([string]$physicalRoot.physical_path)) -or
            (Test-ReleasePathAtOrBelow -Path ([string]$physicalRoot.physical_path) -Root ([string]$physicalSource.physical_path))) {
            throw 'rollout-promotion-input-overlaps-protected-root'
        }
    }

    $targetDefinitions = [ordered]@{
        final = '.assistant/runtime/rollout/v2-eligibility.json'
        candidate = '.assistant/runtime/rollout/v2-canary-candidate.json'
        authorization = '.assistant/runtime/rollout/v2-canary-authorization.json'
        runtime_default = '.assistant/runtime/protocol-default.json'
    }
    $targets = [ordered]@{}
    foreach ($name in $targetDefinitions.Keys) {
        $relative = [string]$targetDefinitions[$name]
        $target = Resolve-HarnessContainedPath -WorkspaceRoot $workspace -Path $relative -Label "rollout $name target" -AllowMissing
        Assert-ReleasePathHasNoReparseAncestor -Path $target
        if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "rollout-promotion-$name-target-not-file" }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Assert-ReleaseSingleLinkFile -Path $target -Label "$name-target"
            Assert-ReleaseSingleDataStreamFile -Path $target -Label "$name-target"
        }
        $physicalTarget = Get-HostPhysicalPathInfo -Path $target -AllowMissing -RejectLinks
        if ([string]$physicalSource.volume -ceq [string]$physicalTarget.volume -and [string]$physicalSource.file_id -ceq [string]$physicalTarget.file_id) { throw "rollout-promotion-input-overlaps-$name-target" }
        foreach ($root in @(@($gitDirectory,$gitCommonDirectory) + @($ProtectedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))) {
            $physicalRoot = Get-HostPhysicalPathInfo -Path ([IO.Path]::GetFullPath($root)) -AllowMissing
            if ((Test-ReleasePathAtOrBelow -Path $target -Root $root) -or
                (Test-ReleasePathAtOrBelow -Path ([string]$physicalTarget.physical_path) -Root ([string]$physicalRoot.physical_path))) {
                throw "rollout-promotion-$name-target-overlaps-protected-root"
            }
        }
        $targets[$name] = [ordered]@{relative=$relative;path=$target}
    }
    return [ordered]@{
        source=$source
        final_target=[string]$targets.final.path;final_target_relative=[string]$targets.final.relative
        candidate_target=[string]$targets.candidate.path;candidate_target_relative=[string]$targets.candidate.relative
        authorization_target=[string]$targets.authorization.path;authorization_target_relative=[string]$targets.authorization.relative
        runtime_default_target=[string]$targets.runtime_default.path;runtime_default_target_relative=[string]$targets.runtime_default.relative
        workspace=$workspace;workspace_identity=$workspaceIdentity
    }
}

function Read-HarnessRolloutEvidenceArtifact {
    param(
        [Parameter(Mandatory)][string]$ArtifactPath,
        [AllowEmptyString()][string]$ExpectedDigest = '',
        [string[]]$ProtectedRoots = @(),
        [long]$MaximumBytes = 16MB
    )
    if (-not [IO.Path]::IsPathRooted($ArtifactPath)) { throw 'rollout-evidence-artifact-path-must-be-absolute' }
    $path = [IO.Path]::GetFullPath($ArtifactPath)
    Assert-ReleasePathHasNoReparseAncestor -Path $path
    Assert-ReleaseSingleLinkFile -Path $path -Label 'evidence-artifact'
    Assert-ReleaseSingleDataStreamFile -Path $path -Label 'evidence-artifact'
    $physical = Get-HostPhysicalPathInfo -Path $path -RejectLinks
    foreach ($root in @($ProtectedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $protected = [IO.Path]::GetFullPath($root)
        $physicalProtected = Get-HostPhysicalPathInfo -Path $protected -AllowMissing
        if ((Test-ReleasePathAtOrBelow -Path $path -Root $protected) -or
            (Test-ReleasePathAtOrBelow -Path ([string]$physical.physical_path) -Root ([string]$physicalProtected.physical_path)) -or
            (Test-ReleasePathAtOrBelow -Path ([string]$physicalProtected.physical_path) -Root ([string]$physical.physical_path))) {
            throw 'rollout-evidence-artifact-overlaps-protected-root'
        }
    }
    $info = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($info.Length -gt $MaximumBytes) { throw 'rollout-evidence-artifact-too-large' }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -gt $MaximumBytes) { throw 'rollout-evidence-artifact-too-large' }
    $digest = Get-ReleaseSha256Bytes -Bytes $bytes
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDigest) -and $digest -cne $ExpectedDigest) { throw 'rollout-evidence-artifact-digest-mismatch' }
    return [ordered]@{path=$path;bytes=$bytes;digest=$digest;physical=$physical}
}

function Get-HarnessPortableEvidenceProtectedRoots {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$ProtectedRoots = @()
    )
    $values = [Collections.Generic.List[string]]::new()
    foreach ($argument in @('--git-dir','--git-common-dir')) { $values.Add((Resolve-ReleaseGitPath -RepoRoot $RepoRoot -Argument $argument)) }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $values.Add((Join-Path $env:USERPROFILE '.codex')) }
    foreach ($name in @('CODEX_HOME','HOST_BENCHMARK_CODEX_HOME')) {
        $value = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $values.Add($value) }
    }
    foreach ($value in @($ProtectedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { $values.Add($value) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    return @($values | ForEach-Object { [IO.Path]::GetFullPath($_) } | Where-Object { $seen.Add($_) })
}

function Assert-HarnessPortableEvidenceSource {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource
    )
    Assert-ReleaseKeys -Value $ExpectedSource -Expected @('revision','commit_tree_oid','object_format','dirty','status_entry_count','status_digest','state_digest','state_basis') -Label 'portable evidence source'
    if ([string]$ExpectedSource.revision -cnotmatch '^[0-9a-f]{40,64}$' -or [string]$ExpectedSource.commit_tree_oid -cnotmatch '^[0-9a-f]{40,64}$' -or
        $ExpectedSource.dirty -isnot [bool] -or ($ExpectedSource.status_entry_count -isnot [int] -and $ExpectedSource.status_entry_count -isnot [long]) -or
        [long]$ExpectedSource.status_entry_count -lt 0 -or [string]$ExpectedSource.state_basis -cne 'git-revision-tree-status/v1') { throw 'portable evidence source shape is invalid' }
    Assert-ReleaseDigestValue -Value $ExpectedSource.status_digest -Label 'portable evidence source status'
    Assert-ReleaseDigestValue -Value $ExpectedSource.state_digest -Label 'portable evidence source state'
    $cleanStatusDigest = Get-ReleaseSha256Text -Text ''
    $cleanStateDigest = Get-ReleaseSha256Text -Text ("{0}`n{1}`n{2}`n" -f [string]$ExpectedSource.revision,[string]$ExpectedSource.commit_tree_oid,[string]$ExpectedSource.object_format)
    if ([bool]$ExpectedSource.dirty -or [long]$ExpectedSource.status_entry_count -ne 0 -or
        [string]$ExpectedSource.status_digest -cne $cleanStatusDigest -or [string]$ExpectedSource.state_digest -cne $cleanStateDigest) {
        throw 'portable evidence source is not clean'
    }
    $revision = (@(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('rev-parse','--verify','HEAD')) -join '').Trim()
    $tree = (@(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('rev-parse',"$revision`^{tree}")) -join '').Trim()
    $objectFormat = (@(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('rev-parse','--show-object-format')) -join '').Trim()
    if ($revision -cne [string]$ExpectedSource.revision -or $tree -cne [string]$ExpectedSource.commit_tree_oid -or $objectFormat -cne [string]$ExpectedSource.object_format) {
        throw 'portable evidence source identity changed'
    }
}

function Assert-InstalledDesktopStrictJsonElement {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -ceq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw 'duplicate JSON property' }
            Assert-InstalledDesktopStrictJsonElement -Element $property.Value
        }
    } elseif ($Element.ValueKind -ceq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-InstalledDesktopStrictJsonElement -Element $item }
    }
}

function ConvertFrom-InstalledDesktopEvidenceBytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $jsonDocument = $null
    try {
        if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { throw 'UTF-8 BOM is not allowed' }
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
        $options = [System.Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 100
        $options.AllowTrailingCommas = $false
        $options.CommentHandling = [System.Text.Json.JsonCommentHandling]::Disallow
        $jsonDocument = [System.Text.Json.JsonDocument]::Parse($text,$options)
        if ($jsonDocument.RootElement.ValueKind -cne [System.Text.Json.JsonValueKind]::Object) { throw 'root must be an object' }
        Assert-InstalledDesktopStrictJsonElement -Element $jsonDocument.RootElement
        $document = $text | ConvertFrom-HarnessJson -Depth 100 -ErrorAction Stop
        if ($document -isnot [Collections.IDictionary]) { throw 'root must be an object' }
        return $document
    } finally {
        if ($null -ne $jsonDocument) { $jsonDocument.Dispose() }
    }
}

function Assert-InstalledDesktopSanitizedContent {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) { Assert-InstalledDesktopSanitizedContent -Value $entry.Value }
        return
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Assert-InstalledDesktopSanitizedContent -Value $item }
        return
    }
    if ($Value -isnot [string]) { return }
    $text = [string]$Value
    if ($text.Length -gt 1024 -or $text -match '[\r\n]' -or $text -match '(?:[A-Za-z]:[\\/]|\\\\|/(?:home|Users|private|tmp|var)(?:/|$))' -or
        $text -match '(?i)(?:access[_-]?token|refresh[_-]?token|api[_-]?key|bearer\s+|authorization\s*:|cookie\s*:|password\s*:|credential\s*:|prompt\s*:|raw[ _-]?(?:trace|log)\s*:|thread[ _-]?id\s*:)') {
        throw 'installed Desktop report contains non-portable or sensitive content'
    }
}

function Assert-HarnessPortableAdditionalSanitizedContent {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) { Assert-HarnessPortableAdditionalSanitizedContent -Value $entry.Value }
        return
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Assert-HarnessPortableAdditionalSanitizedContent -Value $item }
        return
    }
    if ($Value -is [string] -and [string]$Value -match '(?i)raw[ _-]?(?:command|prompt)\s*:') { throw 'portable evidence contains raw command or prompt content' }
}

function Assert-InstalledDesktopProfileConfig {
    param([AllowNull()][object]$Value,[string]$Label)
    Assert-ReleaseKeys -Value $Value -Expected @('status','digest') -Label $Label
    if ([string]$Value.status -ceq 'absent') {
        if ($null -ne $Value.digest) { throw "$Label is invalid" }
    } elseif ([string]$Value.status -ceq 'present') {
        Assert-ReleaseDigestValue -Value $Value.digest -Label $Label
    } else { throw "$Label is invalid" }
}

function Test-InstalledDesktopProfileConfigEqual {
    param([Collections.IDictionary]$Left,[Collections.IDictionary]$Right)
    return [string]$Left.status -ceq [string]$Right.status -and [string]$Left.digest -ceq [string]$Right.digest
}

function ConvertTo-InstalledDesktopBaseHostReport {
    param([Parameter(Mandatory)][Collections.IDictionary]$Document)
    $copy = ($Document | ConvertTo-Json -Depth 100 -Compress) | ConvertFrom-HarnessJson -Depth 100
    $copy.schema_version = 'harness-host-benchmark-report/v2'
    foreach ($name in @('report_run_id','producer_identity','producer_mode','benchmark_path','qualification')) { [void]$copy.Remove($name) }
    [void]$copy.source.Remove('installed_inputs')
    foreach ($name in @('benchmark_path','host_surface','user_config_mode','profile_config','profile_config_consistent')) { [void]$copy.execution.Remove($name) }
    $copy.execution.codex_home = 'dedicated-config-isolated-auth-home-path-not-persisted'
    foreach ($name in @('measurement_passed_groups','measurement_passed')) { [void]$copy.performance.Remove($name) }
    foreach ($group in @($copy.groups)) {
        [void]$group.Remove('qualification')
        [void]$group.source.Remove('installed_inputs')
        foreach ($name in @('benchmark_path','host_surface','user_config_mode','profile_config','profile_config_consistent')) { [void]$group.execution.Remove($name) }
        $group.execution.codex_home = 'dedicated-config-isolated-auth-home-path-not-persisted'
        [void]$group.performance.Remove('measurement_passed')
        foreach ($protocol in @('bare','v1','v2')) {
            foreach ($trial in @($group.protocols[$protocol].trials)) { [void]$trial.Remove('installed_desktop') }
        }
    }
    if ([bool]$Document.performance.measurement_passed) {
        foreach ($group in @($copy.groups)) { $group.status='pass';$group.performance.eligible=$true }
        $copy.status='pass';$copy.performance.eligible=$true;$copy.performance.release_group_set.status='pass';$copy.performance.release_group_set.passed_groups=[long]@($copy.groups).Count
    }
    foreach ($group in @($copy.groups)) {
        $group.group_digest = $null
        $group.group_digest = Get-ReleaseSha256Text -Text ($group | ConvertTo-Json -Depth 100 -Compress)
    }
    $copy.report_digest = $null
    $copy.report_digest = Get-ReleaseSha256Text -Text ($copy | ConvertTo-Json -Depth 100 -Compress)
    return $copy
}

function Assert-InstalledDesktopReport {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Document,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource
    )
    $topKeys = @('schema_version','generated_at_utc','source_revision','source_dirty','source_state_stable','source','execution','groups','performance','status','report_digest','report_run_id','producer_identity','producer_mode','benchmark_path','qualification')
    Assert-ReleaseKeys -Value $Document -Expected $topKeys -Label 'installed Desktop report'
    if ([string]$Document.schema_version -cne 'harness-installed-desktop-benchmark-report/v1' -or [string]$Document.report_run_id -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$Document.producer_identity -cne 'host-benchmark-installed-desktop/v1' -or [string]$Document.producer_mode -cnotin @('formal','test-only','diagnostic-smoke') -or
        [string]$Document.benchmark_path -cne 'installed-desktop-path' -or [string]$Document.status -cnotin @('pass','fail','unavailable')) { throw 'installed Desktop report identity is invalid' }
    Assert-ReleaseReportDigest -Document $Document
    Assert-InstalledDesktopSanitizedContent -Value $Document

    $sourceKeys = @('runner_digest','wrapper_digest','observation_schema_digest','otlp_collector_digest','atomic_write_module_digest','path_module_digest','otel_contract_digest','trial_helper_digest','installed_inputs','input_head_binding','execution_mode','commit_tree_oid','object_format','start','end')
    Assert-ReleaseKeys -Value $Document.source -Expected $sourceKeys -Label 'installed Desktop source'
    Assert-ReleaseKeys -Value $Document.source.installed_inputs -Expected @('install_digest','uninstall_digest','verification_digest','protocol_digest') -Label 'installed Desktop inputs'
    $installedInputs = [ordered]@{install_digest='install.ps1';uninstall_digest='uninstall.ps1';verification_digest='tests/verify-installation.ps1';protocol_digest='scripts/lib/Harness.Protocol.psm1'}
    foreach ($entry in $installedInputs.GetEnumerator()) { Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.installed_inputs[$entry.Key] -RelativePath ([string]$entry.Value) -Label ("installed Desktop {0}" -f $entry.Key) }

    $executionKeys = @('model','reasoning','groups','required_groups','trials_per_protocol_per_group','required_trials_per_protocol_per_group','group_order_strategy','max_fresh_sessions','fresh_workspace_per_trial','fresh_ephemeral_session_per_invocation','codex_home','duration_ms','benchmark_path','host_surface','user_config_mode','profile_config','profile_config_consistent')
    Assert-ReleaseKeys -Value $Document.execution -Expected $executionKeys -Label 'installed Desktop execution'
    Assert-InstalledDesktopProfileConfig -Value $Document.execution.profile_config -Label 'installed Desktop profile config'
    if ([string]$Document.execution.benchmark_path -cne 'installed-desktop-path' -or [string]$Document.execution.host_surface -cne 'installed-desktop-path' -or
        [string]$Document.execution.user_config_mode -cne 'loaded' -or [string]$Document.execution.codex_home -cne 'dedicated-installed-desktop-profile-path-not-persisted' -or
        $Document.execution.profile_config_consistent -isnot [bool]) { throw 'installed Desktop execution identity is invalid' }

    Assert-ReleaseKeys -Value $Document.performance -Expected @('release_group_set','eligible','measurement_passed_groups','measurement_passed') -Label 'installed Desktop performance'
    if ($Document.performance.measurement_passed -isnot [bool] -or $Document.performance.measurement_passed_groups -isnot [long]) { throw 'installed Desktop measurement status is invalid' }
    Assert-ReleaseKeys -Value $Document.qualification -Expected @('status','hard_result_contract','hook_trust','hook_callability','hook_observations_blocking','reason') -Label 'installed Desktop qualification'
    if ([string]$Document.qualification.hard_result_contract -cne 'installed-desktop-authoritative-observation/v1' -or [string]$Document.qualification.hook_trust -cne 'manual' -or
        [string]$Document.qualification.hook_callability -cne 'manual' -or $Document.qualification.hook_observations_blocking -isnot [bool] -or [bool]$Document.qualification.hook_observations_blocking) {
        throw 'installed Desktop qualification identity is invalid'
    }

    $groupKeys = @('group_index','group_run_id','group_root_digest','source_revision','source_dirty','source_state_stable','source','execution','protocols','performance','status','group_digest','qualification')
    $groupExecutionKeys = @('model','reasoning','trials_per_protocol','release_trials_required','max_fresh_sessions','fresh_workspace_per_trial','fresh_ephemeral_session_per_invocation','v1_comparator','bare_and_v2_start','semantic_task','host_turn_basis','successful_request_send_measurement','expected_codex_service_version','trial_order_strategy','actual_trial_order','cache_state','codex_home','sandbox','approval_policy','workspace_boundary','prompt_persisted','raw_command_persisted','thread_id_persisted','raw_trace_persisted','raw_trace_cleanup_confirmed','scratch_persisted','install_duration_included','duration_ms','benchmark_path','host_surface','user_config_mode','profile_config','profile_config_consistent')
    $trialKeys = @('trial_run_id','trial_root_digest','trial','runner_expected_trial','runner_evidence_passed','workspace_baseline_revision','status','diagnostic','completion_passed','outcome','reason_code','source_binding','workflow_contract','workflow_completed','v1_stage_journal','v1_target_journal','v1_validator_passed','fresh_sessions','host_turns','successful_request_sends','completed_agent_messages','total_duration_ms','sum_codex_process_duration_ms','first_useful_action_ms','tool_calls','loaded_skills','skill_file_command_matches','loaded_files','artifact_writes','runtime_writes','unexpected_writes','raw_trace_deleted','post_trial_diagnostics','tokens','installed_desktop')
    $desktopKeys = @('benchmark_path','host_surface','user_config_mode','workspace_config_loaded','profile_config','protocol_environment','install_status','verification_status','auth_unchanged','workspace_protocol_config','route_probe','cleanup_status','hook_installed','hook_trust','hook_callability')
    $routeKeys = @('requested_protocol','detected_protocol','selected_protocol','preference_source','default_source','reason','workspace_config_status','workspace_config_protocol','runtime_default_status','artifact_kind')
    $measurementPassedGroups = 0
    foreach ($group in @($Document.groups)) {
        Assert-ReleaseKeys -Value $group -Expected $groupKeys -Label 'installed Desktop group'
        if ([string]$group.status -cnotin @('pass','fail','unavailable') -or [string]$group.qualification.status -cnotin @('pass','fail','unavailable')) { throw 'installed Desktop group status is invalid' }
        Assert-HostBenchmarkGroupDigest -Group $group
        Assert-ReleaseKeys -Value $group.source -Expected $sourceKeys -Label 'installed Desktop group source'
        Assert-ReleaseKeys -Value $group.execution -Expected $groupExecutionKeys -Label 'installed Desktop group execution'
        Assert-InstalledDesktopProfileConfig -Value $group.execution.profile_config -Label 'installed Desktop group profile config'
        if (-not (Test-InstalledDesktopProfileConfigEqual -Left $Document.execution.profile_config -Right $group.execution.profile_config) -or
            ($group.source.installed_inputs | ConvertTo-Json -Compress) -cne ($Document.source.installed_inputs | ConvertTo-Json -Compress) -or
            [string]$group.execution.benchmark_path -cne 'installed-desktop-path' -or [string]$group.execution.host_surface -cne 'installed-desktop-path' -or
            [string]$group.execution.user_config_mode -cne 'loaded' -or [string]$group.execution.codex_home -cne 'dedicated-installed-desktop-profile-path-not-persisted' -or
            $group.execution.profile_config_consistent -isnot [bool]) { throw 'installed Desktop group binding is invalid' }
        Assert-ReleaseKeys -Value $group.performance -Expected @('release_trial_set','direct_latency','successful_request_send_reduction','eligible','measurement_passed') -Label 'installed Desktop group performance'
        Assert-ReleaseKeys -Value $group.qualification -Expected @('status','reason') -Label 'installed Desktop group qualification'
        if ($group.performance.measurement_passed -isnot [bool]) { throw 'installed Desktop group measurement status is invalid' }
        if ([bool]$group.performance.measurement_passed) { $measurementPassedGroups++ }
        foreach ($protocol in @('bare','v1','v2')) {
            Assert-ReleaseKeys -Value $group.protocols[$protocol] -Expected @('status','runner_contract_failures','trials','successful_request_sends','medians') -Label "installed Desktop $protocol record"
            foreach ($trial in @($group.protocols[$protocol].trials)) {
                Assert-ReleaseKeys -Value $trial -Expected $trialKeys -Label "installed Desktop $protocol trial"
                $desktop = $trial.installed_desktop
                Assert-ReleaseKeys -Value $desktop -Expected $desktopKeys -Label "installed Desktop $protocol observation"
                Assert-InstalledDesktopProfileConfig -Value $desktop.profile_config -Label "installed Desktop $protocol profile config"
                if (-not (Test-InstalledDesktopProfileConfigEqual -Left $Document.execution.profile_config -Right $desktop.profile_config) -or
                    [string]$desktop.benchmark_path -cne 'installed-desktop-path' -or [string]$desktop.host_surface -cne 'installed-desktop-path' -or [string]$desktop.user_config_mode -cne 'loaded' -or
                    [string]$desktop.protocol_environment -cne 'cleared' -or [string]$desktop.hook_trust -cne 'manual' -or [string]$desktop.hook_callability -cne 'manual') { throw "installed Desktop $protocol observation is invalid" }
                if ($protocol -ceq 'bare') {
                    if ($desktop.workspace_config_loaded -isnot [bool] -or [bool]$desktop.workspace_config_loaded -or [string]$desktop.install_status -cne 'not-applicable' -or [string]$desktop.verification_status -cne 'not-applicable' -or
                        [string]$desktop.cleanup_status -cne 'not-required' -or [string]$desktop.hook_installed -cne 'not-applicable' -or $null -ne $desktop.auth_unchanged -or $null -ne $desktop.workspace_protocol_config -or $null -ne $desktop.route_probe) { throw 'installed Desktop bare observation is invalid' }
                } else {
                    if ($desktop.workspace_config_loaded -isnot [bool] -or -not [bool]$desktop.workspace_config_loaded -or [string]$desktop.install_status -cne 'pass' -or [string]$desktop.verification_status -cne 'pass' -or
                        $desktop.auth_unchanged -isnot [bool] -or -not [bool]$desktop.auth_unchanged -or [string]$desktop.cleanup_status -cne 'passed' -or [string]$desktop.hook_installed -cne 'verified') { throw "installed Desktop $protocol hard result is invalid" }
                    Assert-ReleaseKeys -Value $desktop.route_probe -Expected $routeKeys -Label "installed Desktop $protocol route"
                    if ([string]$desktop.route_probe.selected_protocol -cne $protocol -or [string]$desktop.route_probe.runtime_default_status -cne 'not-read') { throw "installed Desktop $protocol route is invalid" }
                    if ($protocol -ceq 'v2') {
                        Assert-ReleaseKeys -Value $desktop.workspace_protocol_config -Expected @('status','new_task_protocol','preference_source','config_digest') -Label 'installed Desktop v2 workspace config'
                        Assert-ReleaseDigestValue -Value $desktop.workspace_protocol_config.config_digest -Label 'installed Desktop v2 workspace config'
                        if ([string]$desktop.workspace_protocol_config.status -cne 'pass' -or [string]$desktop.workspace_protocol_config.new_task_protocol -cne 'v2' -or [string]$desktop.workspace_protocol_config.preference_source -cne 'workspace-config' -or
                            [string]$desktop.route_probe.requested_protocol -cne 'v2' -or [string]$desktop.route_probe.detected_protocol -cne 'new' -or [string]$desktop.route_probe.preference_source -cne 'workspace-config' -or
                            [string]$desktop.route_probe.default_source -cne 'workspace-config' -or [string]$desktop.route_probe.reason -cne 'workspace-v2-new-task' -or [string]$desktop.route_probe.workspace_config_status -cne 'present' -or
                            [string]$desktop.route_probe.workspace_config_protocol -cne 'v2' -or [string]$desktop.route_probe.artifact_kind -cne 'new-task' -or [long]$trial.artifact_writes -ne 0 -or [long]$trial.runtime_writes -ne 0) {
                            throw 'installed Desktop v2 did not use workspace-owned explicit selection'
                        }
                    } elseif ($null -ne $desktop.workspace_protocol_config -or [string]$desktop.route_probe.requested_protocol -cne 'auto' -or [string]$desktop.route_probe.detected_protocol -cne 'v1' -or
                        [string]$desktop.route_probe.default_source -cne 'existing-artifact' -or [string]$desktop.route_probe.reason -cne 'existing-v1-plan' -or [string]$desktop.route_probe.artifact_kind -cne 'v1-plan') {
                        throw 'installed Desktop v1 artifact behavior is invalid'
                    }
                }
            }
        }
    }
    if ([long]$Document.performance.measurement_passed_groups -ne $measurementPassedGroups -or [bool]$Document.performance.measurement_passed -ne ($measurementPassedGroups -eq 3 -and @($Document.groups).Count -eq 3)) { throw 'installed Desktop measurement aggregate is invalid' }

    $base = ConvertTo-InstalledDesktopBaseHostReport -Document $Document
    Assert-HostBenchmarkReportV2 -RepoRoot $RepoRoot -Document $base -ExpectedSource $ExpectedSource
    $formal = [string]$Document.producer_mode -ceq 'formal'
    if ($formal) {
        if ([string]$Document.qualification.status -cne [string]$Document.status -or @($Document.groups | Where-Object { [string]$_.qualification.status -cne [string]$_.status }).Count -ne 0) { throw 'installed Desktop formal qualification status is inconsistent' }
        if ([string]$Document.status -ceq 'pass' -and (-not [bool]$Document.performance.measurement_passed -or -not [bool]$Document.performance.eligible -or -not [bool]$Document.execution.profile_config_consistent)) { throw 'installed Desktop formal pass lacks hard results' }
    } else {
        if ([string]$Document.qualification.status -cne 'unavailable' -or @($Document.groups | Where-Object { [string]$_.qualification.status -cne 'unavailable' }).Count -ne 0 -or [bool]$Document.performance.eligible) { throw 'installed Desktop non-formal result was promoted' }
    }
    $status = if (-not $formal -and [string]$Document.status -cne 'fail') { 'unavailable' } else { [string]$Document.status }
    $trialPayloadDigests = [Collections.Generic.List[string]]::new()
    foreach ($group in @($base.groups)) { foreach ($protocol in @('bare','v1','v2')) { foreach ($trial in @($group.protocols[$protocol].trials)) { $trialPayloadDigests.Add((Get-HostBenchmarkTrialPayloadDigest -Protocol $protocol -Trial $trial)) } } }
    return [ordered]@{
        status=$status;producer_identity=[string]$Document.producer_identity;source_revision=[string]$Document.source_revision;report_run_id=[string]$Document.report_run_id
        group_run_ids=@($Document.groups.group_run_id);group_root_digests=@($Document.groups.group_root_digest)
        trial_run_ids=@($Document.groups | ForEach-Object { @($_.protocols.bare.trials + $_.protocols.v1.trials + $_.protocols.v2.trials) } | ForEach-Object { [string]$_.trial_run_id })
        trial_root_digests=@($Document.groups | ForEach-Object { @($_.protocols.bare.trials + $_.protocols.v1.trials + $_.protocols.v2.trials) } | ForEach-Object { [string]$_.trial_root_digest })
        trial_payload_digests=@($trialPayloadDigests)
    }
}

function Read-InstalledDesktopRolloutEvidence {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Gate,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource,
        [string[]]$ProtectedRoots = @()
    )
    try {
        Assert-ReleaseKeys -Value $Gate -Expected @('status','evidence_contract','artifact_path','evidence_digest','source_revision','producer_identity') -Label 'installed Desktop gate'
        if ([string]$Gate.evidence_contract -cne 'harness-installed-desktop-benchmark-report/v1' -or [string]$Gate.source_revision -cne [string]$ExpectedSource.revision -or
            [string]::IsNullOrWhiteSpace([string]$Gate.producer_identity)) { throw 'installed Desktop gate binding is invalid' }
        $artifact = Read-HarnessRolloutEvidenceArtifact -ArtifactPath ([string]$Gate.artifact_path) -ExpectedDigest ([string]$Gate.evidence_digest) -ProtectedRoots $ProtectedRoots
        $document = ConvertFrom-InstalledDesktopEvidenceBytes -Bytes ([byte[]]$artifact.bytes)
        $result = Assert-InstalledDesktopReport -RepoRoot $RepoRoot -Document $document -ExpectedSource $ExpectedSource
        $physical = $artifact.physical
        $result['path'] = [string]$artifact.path
        $result['raw_digest'] = [string]$artifact.digest
        $result['volume'] = [string]$physical.volume
        $result['file_id'] = [string]$physical.file_id
        return $result
    } catch { throw [IO.InvalidDataException]::new('rollout-evidence-installed-report-invalid',$_.Exception) }
}

function Read-ModelRolloutEvidence {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Gate,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource,
        [string[]]$ProtectedRoots = @()
    )
    try {
        Assert-ReleaseKeys -Value $Gate -Expected @('status','evidence_contract','artifact_path','evidence_digest','source_revision','producer_identity') -Label 'model portable gate'
        if ([string]$Gate.evidence_contract -cne 'harness-model-eval-report/v2' -or [string]$Gate.source_revision -cne [string]$ExpectedSource.revision -or
            [string]::IsNullOrWhiteSpace([string]$Gate.producer_identity)) { throw 'model portable gate binding is invalid' }
        Assert-ReleaseDigestValue -Value $Gate.evidence_digest -Label 'model portable gate'
        $protected = Get-HarnessPortableEvidenceProtectedRoots -RepoRoot $RepoRoot -ProtectedRoots $ProtectedRoots
        $artifact = Read-HarnessRolloutEvidenceArtifact -ArtifactPath ([string]$Gate.artifact_path) -ExpectedDigest ([string]$Gate.evidence_digest) -ProtectedRoots $protected -MaximumBytes 4MB
        $document = ConvertFrom-InstalledDesktopEvidenceBytes -Bytes ([byte[]]$artifact.bytes)
        Assert-InstalledDesktopSanitizedContent -Value $document
        Assert-HarnessPortableAdditionalSanitizedContent -Value $document
        Assert-HarnessPortableEvidenceSource -RepoRoot $RepoRoot -ExpectedSource $ExpectedSource
        Assert-ModelEvalReport -RepoRoot $RepoRoot -Document $document -ExpectedSource $ExpectedSource
        if ([bool]$document.source_dirty -or -not [bool]$document.source_state_stable) { throw 'model portable source is not clean and stable' }
        return [ordered]@{
            status=[string]$document.status;producer_identity='model-eval/v2';source_revision=[string]$document.source_revision
            path=[string]$artifact.path;raw_digest=[string]$artifact.digest;volume=[string]$artifact.physical.volume;file_id=[string]$artifact.physical.file_id
        }
    } catch { throw [IO.InvalidDataException]::new('rollout-evidence-model-report-invalid',$_.Exception) }
}

function Assert-CognitiveHostGroupContract {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Group,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource
    )
    Assert-ReleaseBoolean -Value $Group.source_dirty -Label 'cognitive Host source dirty'
    Assert-ReleaseBoolean -Value $Group.source_state_stable -Label 'cognitive Host source stability'
    foreach ($name in @('trials_per_protocol','release_trials_required')) { [void](Assert-ReleaseInteger -Value $Group.execution[$name] -Label "cognitive Host $name" -Positive) }
    if ([bool]$Group.source_dirty -or -not [bool]$Group.source_state_stable -or [string]$Group.source_revision -cne [string]$ExpectedSource.revision -or
        [string]$Group.source.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or [string]$Group.source.object_format -cne [string]$ExpectedSource.object_format -or
        [string]$Group.execution.model -cne 'gpt-5.6-sol' -or [string]$Group.execution.reasoning -cne 'max' -or
        [long]$Group.execution.trials_per_protocol -ne 3 -or [long]$Group.execution.release_trials_required -ne 3 -or
        [string]$Group.execution.successful_request_send_measurement -cne 'codex-0.144.4-successful-websocket-send/v2' -or
        [string]$Group.execution.expected_codex_service_version -cne '0.144.4') { throw 'cognitive Host group contract is invalid' }
    foreach ($protocol in @('bare','v1','v2')) {
        $trials = @($Group.protocols[$protocol].trials)
        if ($trials.Count -ne 3 -or (@($trials | ForEach-Object { [long]$_.trial } | Sort-Object) -join ',') -cne '1,2,3') { throw 'cognitive Host trial set is incomplete' }
        foreach ($trial in $trials) {
            [void](Assert-ReleaseInteger -Value $trial.trial -Label 'cognitive Host trial number' -Positive)
            [void](Assert-ReleaseInteger -Value $trial.runner_expected_trial -Label 'cognitive Host expected trial number' -Positive)
            if ([long]$trial.runner_expected_trial -ne [long]$trial.trial -or [string]$trial.workspace_baseline_revision -cne [string]$ExpectedSource.revision -or
                [string]$trial.source_binding.status -cne 'bound' -or [string]$trial.source_binding.revision -cne [string]$ExpectedSource.revision -or
                [string]$trial.source_binding.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or [string]$trial.source_binding.verification -cne 'git-head-tree-clean/v1') {
                throw 'cognitive Host trial source binding is invalid'
            }
        }
    }
}

function Get-CognitiveHostDirectLatencyStatus {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Document,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource
    )
    $statuses = [Collections.Generic.List[string]]::new()
    foreach ($group in @($Document.groups)) {
        Assert-CognitiveHostGroupContract -Group $group -ExpectedSource $ExpectedSource
        $metric = $group.performance.direct_latency
        Assert-ReleaseNumberEquals -Actual $metric.threshold -Expected 1.25 -Label 'cognitive Host direct latency threshold'
        $available = $true
        $medians = @{}
        foreach ($protocol in @('bare','v2')) {
            $record = $group.protocols[$protocol]
            if ([string]$record.status -ceq 'unavailable') { $available = $false; continue }
            if ([string]$record.status -cne 'measured') { throw 'cognitive Host direct latency protocol status is invalid' }
            $values = [Collections.Generic.List[double]]::new()
            foreach ($trial in @($record.trials)) {
                if ([string]$trial.status -cne 'measured') { $available = $false; break }
                $values.Add((Assert-ReleaseNumber -Value $trial.total_duration_ms -Label "cognitive Host $protocol duration" -Positive))
            }
            if ($values.Count -eq 3) {
                $median = [math]::Round((Get-ReleaseMedian -Values @($values)),2)
                Assert-ReleaseNumberEquals -Actual $record.medians.total_duration_ms -Expected $median -Label "cognitive Host $protocol duration median"
                $medians[$protocol] = $median
            }
        }
        if (-not $available -or $medians.Count -ne 2) {
            if ([string]$metric.status -cne 'unavailable' -or $null -ne $metric.ratio) { throw 'cognitive Host direct latency availability is inconsistent' }
            $statuses.Add('unavailable')
            continue
        }
        $ratio = [math]::Round(([double]$medians.v2 / [double]$medians.bare),4)
        Assert-ReleaseNumberEquals -Actual $metric.ratio -Expected $ratio -Label 'cognitive Host direct latency ratio'
        $status = if ($ratio -le 1.25) { 'pass' } else { 'fail' }
        if ([string]$metric.status -cne $status) { throw 'cognitive Host direct latency status is inconsistent' }
        $statuses.Add($status)
    }
    if (@($statuses | Where-Object { $_ -ceq 'fail' }).Count -gt 0) { return 'fail' }
    if (@($statuses | Where-Object { $_ -ceq 'unavailable' }).Count -gt 0) { return 'unavailable' }
    if ($statuses.Count -ne 3) { throw 'cognitive Host direct latency group set is incomplete' }
    return 'pass'
}

function Get-CognitiveHostRequestReductionStatus {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Document,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource
    )
    $statuses = [Collections.Generic.List[string]]::new()
    foreach ($group in @($Document.groups)) {
        Assert-CognitiveHostGroupContract -Group $group -ExpectedSource $ExpectedSource
        $metric = $group.performance.successful_request_send_reduction
        Assert-ReleaseNumberEquals -Actual $metric.threshold -Expected 0.60 -Label 'cognitive Host request reduction threshold'
        $available = $true
        $medians = @{}
        foreach ($protocol in @('v1','v2')) {
            $record = $group.protocols[$protocol]
            if ([string]$record.status -cnotin @('measured','unavailable')) { throw 'cognitive Host request-send protocol status is invalid' }
            $values = [Collections.Generic.List[double]]::new()
            foreach ($trial in @($record.trials)) {
                $measurement = $trial.successful_request_sends
                if ([string]$measurement.basis -cne 'codex-0.144.4-successful-websocket-send/v2') { throw 'cognitive Host request-send basis is invalid' }
                if ([string]$measurement.status -ceq 'unavailable') {
                    if ($null -ne $measurement.value) { throw 'cognitive Host unavailable request-send value is invalid' }
                    $available = $false
                    continue
                }
                if ([string]$measurement.status -cne 'measured' -or [string]$measurement.service_version -cne '0.144.4' -or [string]$measurement.transport -cne 'responses_websocket') {
                    throw 'cognitive Host request-send identity is invalid'
                }
                $value = Assert-ReleaseInteger -Value $measurement.value -Label "cognitive Host $protocol request sends" -Positive
                $perSession = @($measurement.per_session_counts)
                foreach ($count in $perSession) { [void](Assert-ReleaseInteger -Value $count -Label "cognitive Host $protocol per-session request sends" -Positive) }
                if ($perSession.Count -ne [long]$trial.fresh_sessions -or [long](($perSession | Measure-Object -Sum).Sum) -ne $value) { throw 'cognitive Host request-send count is inconsistent' }
                $values.Add([double]$value)
            }
            if ($values.Count -eq 3 -and [string]$record.status -ceq 'measured') {
                $median = [math]::Round((Get-ReleaseMedian -Values @($values)),2)
                if ([string]$record.successful_request_sends.status -cne 'measured' -or [string]$record.successful_request_sends.basis -cne 'codex-0.144.4-successful-websocket-send/v2') { throw 'cognitive Host request-send aggregate is invalid' }
                Assert-ReleaseNumberEquals -Actual $record.successful_request_sends.median -Expected $median -Label "cognitive Host $protocol request-send median"
                Assert-ReleaseNumberEquals -Actual $record.medians.successful_request_sends -Expected $median -Label "cognitive Host $protocol duplicated request-send median"
                $medians[$protocol] = $median
            } else {
                $available = $false
                if ([string]$record.successful_request_sends.status -cne 'unavailable' -or $null -ne $record.successful_request_sends.median) { throw 'cognitive Host request-send availability is inconsistent' }
            }
        }
        if (-not $available -or $medians.Count -ne 2) {
            if ([string]$metric.status -cne 'unavailable' -or $null -ne $metric.reduction) { throw 'cognitive Host request reduction availability is inconsistent' }
            $statuses.Add('unavailable')
            continue
        }
        if ([double]$medians.v1 -le 0) { throw 'cognitive Host v1 request-send median is invalid' }
        $reduction = [math]::Round((([double]$medians.v1 - [double]$medians.v2) / [double]$medians.v1),4)
        Assert-ReleaseNumberEquals -Actual $metric.reduction -Expected $reduction -Label 'cognitive Host request reduction'
        $status = if ($reduction -ge 0.60) { 'pass' } else { 'fail' }
        if ([string]$metric.status -cne $status) { throw 'cognitive Host request reduction status is inconsistent' }
        $statuses.Add($status)
    }
    if (@($statuses | Where-Object { $_ -ceq 'fail' }).Count -gt 0) { return 'fail' }
    if (@($statuses | Where-Object { $_ -ceq 'unavailable' }).Count -gt 0) { return 'unavailable' }
    if ($statuses.Count -ne 3) { throw 'cognitive Host request reduction group set is incomplete' }
    return 'pass'
}

function Read-CognitiveHostRolloutEvidence {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Gates,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource,
        [string[]]$ProtectedRoots = @()
    )
    try {
        $normalizedPath = ''
        $digest = ''
        foreach ($name in $Names) {
            $gate = $Gates[$name]
            Assert-ReleaseKeys -Value $gate -Expected @('status','evidence_contract','artifact_path','evidence_digest','source_revision','producer_identity') -Label 'cognitive Host portable gate'
            if ([string]$gate.evidence_contract -cne 'harness-host-benchmark-report/v2' -or [string]$gate.source_revision -cne [string]$ExpectedSource.revision -or
                [string]::IsNullOrWhiteSpace([string]$gate.producer_identity) -or -not [IO.Path]::IsPathRooted([string]$gate.artifact_path)) { throw 'cognitive Host portable gate binding is invalid' }
            Assert-ReleaseDigestValue -Value $gate.evidence_digest -Label 'cognitive Host portable gate'
            $path = [IO.Path]::GetFullPath([string]$gate.artifact_path)
            if ([string]::IsNullOrWhiteSpace($normalizedPath)) { $normalizedPath = $path; $digest = [string]$gate.evidence_digest }
            elseif (-not $path.Equals($normalizedPath,[StringComparison]::OrdinalIgnoreCase) -or [string]$gate.evidence_digest -cne $digest) { throw 'cognitive Host Gates do not bind one Artifact' }
        }
        $protected = Get-HarnessPortableEvidenceProtectedRoots -RepoRoot $RepoRoot -ProtectedRoots $ProtectedRoots
        $artifact = Read-HarnessRolloutEvidenceArtifact -ArtifactPath $normalizedPath -ExpectedDigest $digest -ProtectedRoots $protected -MaximumBytes 16MB
        $document = ConvertFrom-InstalledDesktopEvidenceBytes -Bytes ([byte[]]$artifact.bytes)
        Assert-InstalledDesktopSanitizedContent -Value $document
        Assert-HarnessPortableAdditionalSanitizedContent -Value $document
        Assert-HarnessPortableEvidenceSource -RepoRoot $RepoRoot -ExpectedSource $ExpectedSource
        Assert-HostBenchmarkReportV2 -RepoRoot $RepoRoot -Document $document -ExpectedSource $ExpectedSource
        if ([bool]$document.source_dirty -or -not [bool]$document.source_state_stable -or @($document.groups).Count -ne 3) { throw 'cognitive Host portable source or group set is invalid' }
        return [ordered]@{
            g02_status=[string]$document.status
            g05_status=(Get-CognitiveHostDirectLatencyStatus -Document $document -ExpectedSource $ExpectedSource)
            g06_status=(Get-CognitiveHostRequestReductionStatus -Document $document -ExpectedSource $ExpectedSource)
            producer_identity='host-benchmark-cognitive/v2';source_revision=[string]$document.source_revision
            path=[string]$artifact.path;raw_digest=[string]$artifact.digest;volume=[string]$artifact.physical.volume;file_id=[string]$artifact.physical.file_id
        }
    } catch { throw [IO.InvalidDataException]::new('rollout-evidence-cognitive-host-report-invalid',$_.Exception) }
}

function Assert-PresetLifecycleSanitizedContent {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) { Assert-PresetLifecycleSanitizedContent -Value $entry.Value }
        return
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Assert-PresetLifecycleSanitizedContent -Value $item }
        return
    }
    if ($Value -isnot [string]) { return }
    $text = [string]$Value
    if ($text.Length -gt 1024 -or $text -match '[\r\n]' -or $text -match '(?:[A-Za-z]:[\\/]|\\\\|/(?:home|Users|private|tmp|var)(?:/|$))' -or
        $text -match '(?i)(?:access[_-]?token|refresh[_-]?token|api[_-]?key|bearer\s+|authorization\s*:|cookie\s*:|password\s*:|credential\s*:|prompt\s*:|raw[ _-]?(?:output|trace|log)\s*:|thread[ _-]?id\s*:)') {
        throw 'preset lifecycle report contains non-portable or sensitive content'
    }
}

function ConvertFrom-PresetLifecycleEvidenceBytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return ConvertFrom-InstalledDesktopEvidenceBytes -Bytes $Bytes
}

function Assert-PresetLifecycleUtcDate {
    param([object]$Value,[string]$Label)
    try { $parsed = [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None) }
    catch { throw "$Label timestamp is invalid" }
    if ($parsed.Offset -ne [TimeSpan]::Zero) { throw "$Label timestamp is not UTC" }
    return $parsed
}

function Assert-PresetLifecycleStage {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Stage,
        [Parameter(Mandatory)][string]$ExpectedName
    )
    Assert-ReleaseKeys -Value $Stage -Expected @('stage','status','exit_code','started_at_utc','ended_at_utc','duration_ms','command_digest','output_digest','reason') -Label "preset lifecycle $ExpectedName stage"
    if ([string]$Stage.stage -cne $ExpectedName -or [string]$Stage.status -cnotin @('pass','fail','not_run')) { throw "preset lifecycle $ExpectedName stage identity is invalid" }
    $started = Assert-PresetLifecycleUtcDate -Value $Stage.started_at_utc -Label "preset lifecycle $ExpectedName start"
    $ended = Assert-PresetLifecycleUtcDate -Value $Stage.ended_at_utc -Label "preset lifecycle $ExpectedName end"
    if ($ended -lt $started) { throw "preset lifecycle $ExpectedName time order is invalid" }
    $duration = Assert-ReleaseInteger -Value $Stage.duration_ms -Label "preset lifecycle $ExpectedName duration" -NonNegative
    $expectedDuration = [long][Math]::Round(($ended - $started).TotalMilliseconds,0,[MidpointRounding]::AwayFromZero)
    if ($duration -ne $expectedDuration) { throw "preset lifecycle $ExpectedName duration is inconsistent" }
    Assert-ReleaseDigestValue -Value $Stage.command_digest -Label "preset lifecycle $ExpectedName command"
    Assert-ReleaseDigestValue -Value $Stage.output_digest -Label "preset lifecycle $ExpectedName output"
    if ([string]::IsNullOrWhiteSpace([string]$Stage.reason)) { throw "preset lifecycle $ExpectedName reason is invalid" }
    if ([string]$Stage.status -ceq 'pass') {
        if ($Stage.exit_code -isnot [long] -or [long]$Stage.exit_code -ne 0) { throw "preset lifecycle $ExpectedName pass exit code is invalid" }
    } elseif ([string]$Stage.status -ceq 'fail') {
        if ($Stage.exit_code -isnot [long] -or [long]$Stage.exit_code -eq 0) { throw "preset lifecycle $ExpectedName failure exit code is invalid" }
    } elseif ($null -ne $Stage.exit_code) { throw "preset lifecycle $ExpectedName not-run exit code is invalid" }
}

function Assert-PresetLifecycleReport {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Document,
        [Collections.IDictionary]$ExpectedSource = $null,
        [AllowEmptyString()][string]$ExpectedPreset = '',
        [switch]$AllowNonFormalSource
    )
    $topKeys = @('schema_version','generated_at_utc','source_revision','source_dirty','source_state_stable','source','preset','report_run_id','producer_identity','producer_mode','execution','stages','results','status','reason','report_digest')
    Assert-ReleaseKeys -Value $Document -Expected $topKeys -Label 'preset lifecycle report'
    $schemaPath = Join-Path $RepoRoot 'schemas\preset-lifecycle-report.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf) -or
        -not (Test-Json -Json ($Document | ConvertTo-Json -Depth 100 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) {
        throw 'preset lifecycle report schema validation failed'
    }
    if ([string]$Document.schema_version -cne 'harness-preset-lifecycle-report/v1' -or
        [string]$Document.report_run_id -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$Document.producer_identity -cne 'preset-lifecycle-qualification/v1' -or
        [string]$Document.producer_mode -cnotin @('formal','test-only','diagnostic-smoke') -or
        [string]$Document.preset -cnotin @('core','governed','full') -or
        [string]$Document.status -cnotin @('pass','fail','unavailable')) { throw 'preset lifecycle report identity is invalid' }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPreset) -and [string]$Document.preset -cne $ExpectedPreset) { throw 'preset lifecycle report preset does not match its Gate' }
    [void](Assert-PresetLifecycleUtcDate -Value $Document.generated_at_utc -Label 'preset lifecycle report')
    Assert-ReleaseReportDigest -Document $Document
    Assert-PresetLifecycleSanitizedContent -Value $Document

    Assert-ReleaseKeys -Value $Document.source -Expected @('commit_tree_oid','object_format','start','end','input_digests') -Label 'preset lifecycle source'
    Assert-ReleaseKeys -Value $Document.source.input_digests -Expected @('install_digest','uninstall_digest','verification_digest','producer_digest','atomic_write_digest','path_digest') -Label 'preset lifecycle inputs'
    $inputPaths = [ordered]@{
        install_digest='install.ps1'
        uninstall_digest='uninstall.ps1'
        verification_digest='tests/verify-installation.ps1'
        producer_digest='scripts/run-preset-lifecycle-qualification.ps1'
        atomic_write_digest='scripts/lib/Harness.AtomicWrite.psm1'
        path_digest='scripts/lib/Harness.Path.psm1'
    }
    foreach ($entry in $inputPaths.GetEnumerator()) { Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.input_digests[$entry.Key] -RelativePath ([string]$entry.Value) -Label ("preset lifecycle {0}" -f $entry.Key) }
    Assert-ReleaseSourceStateShape -Value $Document.source.start -Label 'preset lifecycle source start'
    Assert-ReleaseSourceStateShape -Value $Document.source.end -Label 'preset lifecycle source end'
    if ([string]$Document.source_revision -cne [string]$Document.source.start.revision -or
        [string]$Document.source.commit_tree_oid -cne [string]$Document.source.start.commit_tree_oid -or
        [string]$Document.source.object_format -cne [string]$Document.source.start.object_format -or
        [bool]$Document.source_dirty -ne ([bool]$Document.source.start.dirty -or [bool]$Document.source.end.dirty)) { throw 'preset lifecycle source binding is invalid' }
    $stable = Test-HarnessReleaseSourceStable -Start $Document.source.start -End $Document.source.end
    if ([bool]$Document.source_state_stable -ne $stable) { throw 'preset lifecycle source stability is inconsistent' }
    if ($null -ne $ExpectedSource) {
        Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.start -Expected $ExpectedSource -Label 'preset lifecycle source start'
        Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.end -Expected $ExpectedSource -Label 'preset lifecycle source end'
        if ([string]$Document.source_revision -cne [string]$ExpectedSource.revision -or [string]$Document.source.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or [string]$Document.source.object_format -cne [string]$ExpectedSource.object_format) { throw 'preset lifecycle source does not match the qualified source' }
    }
    if (-not $AllowNonFormalSource -and ([bool]$Document.source_dirty -or -not [bool]$Document.source_state_stable)) { throw 'preset lifecycle source is not clean and stable' }

    Assert-ReleaseKeys -Value $Document.execution -Expected @('sequence_contract','effective_preset','isolated_workspace','isolated_profile','workspace_identity_digest','profile_identity_digest','duration_ms','raw_output_persisted','auth_bytes_persisted','private_paths_persisted') -Label 'preset lifecycle execution'
    if ([string]$Document.execution.sequence_contract -cne 'install-verify-update-verify-uninstall-cleanup/v1' -or
        [string]$Document.execution.effective_preset -cne [string]$Document.preset -or
        $Document.execution.isolated_workspace -isnot [bool] -or -not [bool]$Document.execution.isolated_workspace -or
        $Document.execution.isolated_profile -isnot [bool] -or -not [bool]$Document.execution.isolated_profile -or
        $Document.execution.raw_output_persisted -isnot [bool] -or [bool]$Document.execution.raw_output_persisted -or
        $Document.execution.auth_bytes_persisted -isnot [bool] -or [bool]$Document.execution.auth_bytes_persisted -or
        $Document.execution.private_paths_persisted -isnot [bool] -or [bool]$Document.execution.private_paths_persisted) { throw 'preset lifecycle execution identity is invalid' }
    Assert-ReleaseDigestValue -Value $Document.execution.workspace_identity_digest -Label 'preset lifecycle workspace identity'
    Assert-ReleaseDigestValue -Value $Document.execution.profile_identity_digest -Label 'preset lifecycle profile identity'
    [void](Assert-ReleaseInteger -Value $Document.execution.duration_ms -Label 'preset lifecycle execution duration' -Positive)

    $stageNames = @('install','verify-after-install','update','verify-after-update','uninstall','cleanup')
    if (@($Document.stages).Count -ne $stageNames.Count) { throw 'preset lifecycle stage count is invalid' }
    for ($index=0; $index -lt $stageNames.Count; $index++) { Assert-PresetLifecycleStage -Stage $Document.stages[$index] -ExpectedName $stageNames[$index] }
    if ([string]$Document.stages[0].status -ceq 'not_run' -or [string]$Document.stages[4].status -ceq 'not_run' -or [string]$Document.stages[5].status -ceq 'not_run') { throw 'preset lifecycle required attempt was not recorded' }
    if ([string]$Document.stages[0].status -ceq 'fail') {
        if (@($Document.stages[1..3] | Where-Object { [string]$_.status -cne 'not_run' }).Count -gt 0) { throw 'preset lifecycle install failure did not block dependent stages' }
    } else {
        if ([string]$Document.stages[1].status -ceq 'not_run') { throw 'preset lifecycle verify-after-install was not attempted' }
        if ([string]$Document.stages[1].status -ceq 'fail') {
            if (@($Document.stages[2..3] | Where-Object { [string]$_.status -cne 'not_run' }).Count -gt 0) { throw 'preset lifecycle verification failure did not block update stages' }
        } else {
            if ([string]$Document.stages[2].status -ceq 'not_run') { throw 'preset lifecycle update was not attempted' }
            if ([string]$Document.stages[2].status -ceq 'fail' -and [string]$Document.stages[3].status -cne 'not_run') { throw 'preset lifecycle update failure did not block verification' }
            if ([string]$Document.stages[2].status -ceq 'pass' -and [string]$Document.stages[3].status -ceq 'not_run') { throw 'preset lifecycle verify-after-update was not attempted' }
        }
    }
    Assert-ReleaseKeys -Value $Document.results -Expected @('all_required_stages_passed','preset_consistent','auth_unchanged','unrelated_user_config_unchanged','cleanup_no_residue','installation_verified','update_verified') -Label 'preset lifecycle results'
    foreach ($name in @($Document.results.Keys)) { Assert-ReleaseBoolean -Value $Document.results[$name] -Label "preset lifecycle result $name" }
    $allStagesPassed = @($Document.stages | Where-Object { [string]$_.status -cne 'pass' }).Count -eq 0
    $hasFailedStage = @($Document.stages | Where-Object { [string]$_.status -ceq 'fail' }).Count -gt 0
    if ([bool]$Document.results.all_required_stages_passed -ne $allStagesPassed -or
        [bool]$Document.results.installation_verified -ne ([string]$Document.stages[1].status -ceq 'pass') -or
        [bool]$Document.results.update_verified -ne ([string]$Document.stages[3].status -ceq 'pass') -or
        ([string]$Document.stages[5].status -ceq 'pass' -and -not [bool]$Document.results.cleanup_no_residue)) { throw 'preset lifecycle result aggregate is inconsistent' }
    $formal = [string]$Document.producer_mode -ceq 'formal'
    $allResultsPassed = @($Document.results.Keys | Where-Object { -not [bool]$Document.results[$_] }).Count -eq 0
    $sourceUnchanged = [string]$Document.source.start.revision -ceq [string]$Document.source.end.revision -and [string]$Document.source.start.commit_tree_oid -ceq [string]$Document.source.end.commit_tree_oid -and [string]$Document.source.start.object_format -ceq [string]$Document.source.end.object_format -and [string]$Document.source.start.state_digest -ceq [string]$Document.source.end.state_digest
    $operationalPass = $allStagesPassed -and $allResultsPassed -and $sourceUnchanged
    $derivedStatus = if (-not $operationalPass) { 'fail' } elseif (-not $formal) { 'unavailable' } elseif (-not [bool]$Document.source_dirty -and [bool]$Document.source_state_stable) { 'pass' } else { 'fail' }
    $derivedReason = if ($derivedStatus -ceq 'pass') { 'all-required-stages-passed' } elseif ($derivedStatus -ceq 'unavailable') { 'non-formal-producer-mode' } else { 'lifecycle-stage-or-result-failure' }
    if ([string]$Document.status -cne $derivedStatus -or [string]$Document.reason -cne $derivedReason -or ($hasFailedStage -and $derivedStatus -cne 'fail')) { throw 'preset lifecycle aggregate status is inconsistent' }

    return [ordered]@{
        status=$derivedStatus
        producer_identity=[string]$Document.producer_identity
        source_revision=[string]$Document.source_revision
        commit_tree_oid=[string]$Document.source.commit_tree_oid
        object_format=[string]$Document.source.object_format
        preset=[string]$Document.preset
        report_run_id=[string]$Document.report_run_id
        workspace_identity_digest=[string]$Document.execution.workspace_identity_digest
        profile_identity_digest=[string]$Document.execution.profile_identity_digest
    }
}

function Read-PresetLifecycleRolloutEvidence {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Gate,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource,
        [Parameter(Mandatory)][string]$ExpectedPreset,
        [string[]]$ProtectedRoots = @()
    )
    try {
        Assert-ReleaseKeys -Value $Gate -Expected @('status','evidence_contract','artifact_path','evidence_digest','source_revision','producer_identity') -Label 'preset lifecycle gate'
        if ([string]$Gate.evidence_contract -cne 'harness-preset-lifecycle-report/v1' -or [string]$Gate.source_revision -cne [string]$ExpectedSource.revision -or
            [string]::IsNullOrWhiteSpace([string]$Gate.producer_identity)) { throw 'preset lifecycle gate binding is invalid' }
        $artifact = Read-HarnessRolloutEvidenceArtifact -ArtifactPath ([string]$Gate.artifact_path) -ExpectedDigest ([string]$Gate.evidence_digest) -ProtectedRoots $ProtectedRoots -MaximumBytes 1MB
        $document = ConvertFrom-PresetLifecycleEvidenceBytes -Bytes ([byte[]]$artifact.bytes)
        $result = Assert-PresetLifecycleReport -RepoRoot $RepoRoot -Document $document -ExpectedSource $ExpectedSource -ExpectedPreset $ExpectedPreset
        $result['path'] = [string]$artifact.path
        $result['raw_digest'] = [string]$artifact.digest
        $result['volume'] = [string]$artifact.physical.volume
        $result['file_id'] = [string]$artifact.physical.file_id
        return $result
    } catch { throw [IO.InvalidDataException]::new('rollout-evidence-lifecycle-report-invalid',$_.Exception) }
}

function ConvertFrom-V1StopLossEvidenceBytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return ConvertFrom-InstalledDesktopEvidenceBytes -Bytes $Bytes
}

function Assert-V1StopLossSanitizedContent {
    param([AllowNull()][object]$Value)
    Assert-InstalledDesktopSanitizedContent -Value $Value
    Assert-HarnessPortableAdditionalSanitizedContent -Value $Value
}

function Assert-V1StopLossRouteProbe {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Probe,
        [Parameter(Mandatory)][Collections.IDictionary]$Expected
    )
    $keys = @('probe','status','exit_code','requested_protocol','detected_protocol','selected_protocol','preference_source','reason_code','expected_write_kind','unexpected_writes','artifact_digest_before','artifact_digest_after','command_digest','output_digest')
    Assert-ReleaseKeys -Value $Probe -Expected $keys -Label "v1 stop-loss $($Expected.probe) probe"
    if ([string]$Probe.probe -cne [string]$Expected.probe -or [string]$Probe.status -cnotin @('pass','fail','not_run') -or
        [string]$Probe.requested_protocol -cne [string]$Expected.requested_protocol -or [string]$Probe.expected_write_kind -cne [string]$Expected.expected_write_kind) {
        throw "v1 stop-loss $($Expected.probe) probe identity is invalid"
    }
    [void](Assert-ReleaseInteger -Value $Probe.unexpected_writes -Label "v1 stop-loss $($Expected.probe) unexpected writes" -NonNegative)
    Assert-ReleaseDigestValue -Value $Probe.command_digest -Label "v1 stop-loss $($Expected.probe) command"
    Assert-ReleaseDigestValue -Value $Probe.output_digest -Label "v1 stop-loss $($Expected.probe) output"
    foreach ($name in @('artifact_digest_before','artifact_digest_after')) { if ($null -ne $Probe[$name]) { Assert-ReleaseDigestValue -Value $Probe[$name] -Label "v1 stop-loss $($Expected.probe) $name" } }
    if ([string]$Probe.reason_code -cnotmatch '^[a-z0-9][a-z0-9-]{0,127}$') { throw "v1 stop-loss $($Expected.probe) reason is invalid" }
    if ([string]$Probe.status -ceq 'pass') {
        if ($Probe.exit_code -isnot [long] -or [long]$Probe.exit_code -ne 0 -or
            [string]$Probe.detected_protocol -cne [string]$Expected.detected_protocol -or [string]$Probe.selected_protocol -cne [string]$Expected.selected_protocol -or
            [string]$Probe.preference_source -cne [string]$Expected.preference_source -or [string]$Probe.reason_code -cne [string]$Expected.reason_code -or
            [long]$Probe.unexpected_writes -ne 0) { throw "v1 stop-loss $($Expected.probe) pass result is invalid" }
        if ([bool]$Expected.existing_artifact) {
            Assert-ReleaseDigestValue -Value $Probe.artifact_digest_before -Label "v1 stop-loss $($Expected.probe) artifact before"
            Assert-ReleaseDigestValue -Value $Probe.artifact_digest_after -Label "v1 stop-loss $($Expected.probe) artifact after"
            if ([string]$Probe.artifact_digest_before -cne [string]$Probe.artifact_digest_after) { throw "v1 stop-loss $($Expected.probe) changed its existing Artifact" }
        } elseif ($null -ne $Probe.artifact_digest_before -or $null -ne $Probe.artifact_digest_after) { throw "v1 stop-loss $($Expected.probe) unexpectedly reported an Artifact" }
    } elseif ([string]$Probe.status -ceq 'fail') {
        if ($Probe.exit_code -isnot [long] -or [long]$Probe.exit_code -eq 0) { throw "v1 stop-loss $($Expected.probe) failure exit code is invalid" }
    } elseif ($null -ne $Probe.exit_code) { throw "v1 stop-loss $($Expected.probe) not-run exit code is invalid" }
}

function Assert-V1StopLossReport {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Document,
        [Collections.IDictionary]$ExpectedSource = $null,
        [switch]$AllowNonFormalSource
    )
    $topKeys = @('schema_version','generated_at_utc','source_revision','source_dirty','source_state_stable','source','report_run_id','producer_identity','producer_mode','execution','route_probes','lifecycle','results','status','reason','report_digest')
    Assert-ReleaseKeys -Value $Document -Expected $topKeys -Label 'v1 stop-loss report'
    $schemaPath = Join-Path $RepoRoot 'schemas\v1-stop-loss-report.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf) -or
        -not (Test-Json -Json ($Document | ConvertTo-Json -Depth 100 -Compress) -SchemaFile $schemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) {
        throw 'v1 stop-loss report schema validation failed'
    }
    if ([string]$Document.schema_version -cne 'harness-v1-stop-loss-report/v1' -or [string]$Document.report_run_id -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$Document.producer_identity -cne 'v1-stop-loss-qualification/v1' -or [string]$Document.producer_mode -cnotin @('formal','test-only','diagnostic-smoke') -or
        [string]$Document.status -cnotin @('pass','fail','unavailable')) { throw 'v1 stop-loss report identity is invalid' }
    [void](Assert-PresetLifecycleUtcDate -Value $Document.generated_at_utc -Label 'v1 stop-loss report')
    Assert-ReleaseReportDigest -Document $Document
    Assert-V1StopLossSanitizedContent -Value $Document

    Assert-ReleaseKeys -Value $Document.source -Expected @('commit_tree_oid','object_format','start','end','input_digests') -Label 'v1 stop-loss source'
    $inputPaths = [ordered]@{
        producer_digest='scripts/run-v1-stop-loss-qualification.ps1'
        task_entry_digest='scripts/task.ps1'
        advance_stage_digest='scripts/advance-stage.ps1'
        protocol_module_digest='scripts/lib/Harness.Protocol.psm1'
        task_state_module_digest='scripts/lib/Harness.TaskState.psm1'
        atomic_write_digest='scripts/lib/Harness.AtomicWrite.psm1'
        path_digest='scripts/lib/Harness.Path.psm1'
    }
    Assert-ReleaseKeys -Value $Document.source.input_digests -Expected @($inputPaths.Keys) -Label 'v1 stop-loss inputs'
    foreach ($entry in $inputPaths.GetEnumerator()) { Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.input_digests[$entry.Key] -RelativePath ([string]$entry.Value) -Label ("v1 stop-loss {0}" -f $entry.Key) }
    Assert-ReleaseSourceStateShape -Value $Document.source.start -Label 'v1 stop-loss source start'
    Assert-ReleaseSourceStateShape -Value $Document.source.end -Label 'v1 stop-loss source end'
    if ([string]$Document.source_revision -cne [string]$Document.source.start.revision -or [string]$Document.source.commit_tree_oid -cne [string]$Document.source.start.commit_tree_oid -or
        [string]$Document.source.object_format -cne [string]$Document.source.start.object_format -or
        [bool]$Document.source_dirty -ne ([bool]$Document.source.start.dirty -or [bool]$Document.source.end.dirty)) { throw 'v1 stop-loss source binding is invalid' }
    $sourceStable = Test-HarnessReleaseSourceStable -Start $Document.source.start -End $Document.source.end
    if ([bool]$Document.source_state_stable -ne $sourceStable) { throw 'v1 stop-loss source stability is inconsistent' }
    if ($null -ne $ExpectedSource) {
        Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.start -Expected $ExpectedSource -Label 'v1 stop-loss source start'
        Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.end -Expected $ExpectedSource -Label 'v1 stop-loss source end'
        Assert-HarnessPortableEvidenceSource -RepoRoot $RepoRoot -ExpectedSource $ExpectedSource
    }
    if (-not $AllowNonFormalSource -and ([bool]$Document.source_dirty -or -not [bool]$Document.source_state_stable)) { throw 'v1 stop-loss source is not clean and stable' }

    Assert-ReleaseKeys -Value $Document.execution -Expected @('sequence_contract','isolated_workspace','isolated_profile','workspace_identity_digest','profile_identity_digest','duration_ms','raw_output_persisted','auth_bytes_persisted','private_paths_persisted') -Label 'v1 stop-loss execution'
    if ([string]$Document.execution.sequence_contract -cne 'environment-v1-disable-v2-existing-v1-existing-v2-v1-lifecycle/v1' -or
        $Document.execution.isolated_workspace -isnot [bool] -or -not [bool]$Document.execution.isolated_workspace -or $Document.execution.isolated_profile -isnot [bool] -or -not [bool]$Document.execution.isolated_profile -or
        $Document.execution.raw_output_persisted -isnot [bool] -or [bool]$Document.execution.raw_output_persisted -or $Document.execution.auth_bytes_persisted -isnot [bool] -or [bool]$Document.execution.auth_bytes_persisted -or
        $Document.execution.private_paths_persisted -isnot [bool] -or [bool]$Document.execution.private_paths_persisted) { throw 'v1 stop-loss execution identity is invalid' }
    Assert-ReleaseDigestValue -Value $Document.execution.workspace_identity_digest -Label 'v1 stop-loss workspace identity'
    Assert-ReleaseDigestValue -Value $Document.execution.profile_identity_digest -Label 'v1 stop-loss profile identity'
    [void](Assert-ReleaseInteger -Value $Document.execution.duration_ms -Label 'v1 stop-loss duration' -Positive)

    $routeExpectations = @(
        [ordered]@{probe='environment-v1-new-task';requested_protocol='v1';detected_protocol='new';selected_protocol='v1';preference_source='HARNESS_PROTOCOL';reason_code='explicit-v1-new-task';expected_write_kind='none';existing_artifact=$false},
        [ordered]@{probe='disable-v2-new-task';requested_protocol='v1';detected_protocol='new';selected_protocol='v1';preference_source='workspace-config';reason_code='workspace-v1-new-task';expected_write_kind='workspace-protocol-config';existing_artifact=$false},
        [ordered]@{probe='existing-v1-artifact';requested_protocol='v2';detected_protocol='v1';selected_protocol='v1';preference_source='existing-artifact';reason_code='existing-v1-plan';expected_write_kind='none';existing_artifact=$true},
        [ordered]@{probe='existing-v2-artifact';requested_protocol='v1';detected_protocol='v2';selected_protocol='v2';preference_source='existing-artifact';reason_code='existing-v2-task-state';expected_write_kind='none';existing_artifact=$true}
    )
    if (@($Document.route_probes).Count -ne 4) { throw 'v1 stop-loss route probe count is invalid' }
    for ($index=0; $index -lt 4; $index++) { Assert-V1StopLossRouteProbe -Probe $Document.route_probes[$index] -Expected $routeExpectations[$index] }

    $lifecycle = $Document.lifecycle
    Assert-ReleaseKeys -Value $lifecycle -Expected @('status','initial_stage','final_stage','stage_sequence','transition_count','plan_digest_before','plan_digest_after','test_report_digest','unexpected_writes','reason') -Label 'v1 stop-loss lifecycle'
    if ([string]$lifecycle.status -cnotin @('pass','fail','not_run')) { throw 'v1 stop-loss lifecycle status is invalid' }
    [void](Assert-ReleaseInteger -Value $lifecycle.transition_count -Label 'v1 stop-loss lifecycle transition count' -NonNegative)
    [void](Assert-ReleaseInteger -Value $lifecycle.unexpected_writes -Label 'v1 stop-loss lifecycle unexpected writes' -NonNegative)
    foreach ($name in @('plan_digest_before','plan_digest_after','test_report_digest')) { if ($null -ne $lifecycle[$name]) { Assert-ReleaseDigestValue -Value $lifecycle[$name] -Label "v1 stop-loss lifecycle $name" } }
    $expectedStages = @('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')
    $lifecyclePassed = [string]$lifecycle.status -ceq 'pass' -and [string]$lifecycle.initial_stage -ceq 'PLAN' -and [string]$lifecycle.final_stage -ceq 'DONE' -and
        (@($lifecycle.stage_sequence) -join '>') -ceq ($expectedStages -join '>') -and [long]$lifecycle.transition_count -eq 5 -and [long]$lifecycle.unexpected_writes -eq 0 -and [string]$lifecycle.reason -ceq 'lifecycle-pass'
    if ([string]$lifecycle.status -ceq 'pass') {
        foreach ($name in @('plan_digest_before','plan_digest_after','test_report_digest')) { Assert-ReleaseDigestValue -Value $lifecycle[$name] -Label "v1 stop-loss lifecycle $name" }
        if (-not $lifecyclePassed) { throw 'v1 stop-loss passing lifecycle is invalid' }
    } elseif ([string]$lifecycle.status -ceq 'not_run' -and ($null -ne $lifecycle.initial_stage -or $null -ne $lifecycle.final_stage -or @($lifecycle.stage_sequence).Count -ne 0 -or [long]$lifecycle.transition_count -ne 0 -or [string]$lifecycle.reason -cne 'not-run')) { throw 'v1 stop-loss not-run lifecycle is invalid' }

    $resultNames = @('environment_v1_selects_v1','disable_v2_selects_v1','existing_v1_artifact_remains_v1','existing_v2_artifact_remains_v2','existing_artifacts_unchanged_by_routing','v1_lifecycle_reaches_done','v1_stage_order_exact','runtime_default_untouched','auth_unchanged','unrelated_user_config_unchanged','cleanup_no_residue')
    Assert-ReleaseKeys -Value $Document.results -Expected $resultNames -Label 'v1 stop-loss results'
    foreach ($name in $resultNames) { Assert-ReleaseBoolean -Value $Document.results[$name] -Label "v1 stop-loss result $name" }
    $routePasses = @($Document.route_probes | ForEach-Object { [string]$_.status -ceq 'pass' })
    $derivedResults = [ordered]@{
        environment_v1_selects_v1=$routePasses[0]
        disable_v2_selects_v1=$routePasses[1]
        existing_v1_artifact_remains_v1=$routePasses[2]
        existing_v2_artifact_remains_v2=$routePasses[3]
        existing_artifacts_unchanged_by_routing=($routePasses[2] -and $routePasses[3] -and [string]$Document.route_probes[2].artifact_digest_before -ceq [string]$Document.route_probes[2].artifact_digest_after -and [string]$Document.route_probes[3].artifact_digest_before -ceq [string]$Document.route_probes[3].artifact_digest_after)
        v1_lifecycle_reaches_done=$lifecyclePassed
        v1_stage_order_exact=$lifecyclePassed
    }
    foreach ($name in $derivedResults.Keys) { if ([bool]$Document.results[$name] -ne [bool]$derivedResults[$name]) { throw "v1 stop-loss result $name is inconsistent" } }
    $hasUnavailable = @($Document.route_probes | Where-Object { [string]$_.status -ceq 'not_run' }).Count -gt 0 -or [string]$lifecycle.status -ceq 'not_run'
    $hasFailure = @($Document.route_probes | Where-Object { [string]$_.status -ceq 'fail' }).Count -gt 0 -or [string]$lifecycle.status -ceq 'fail' -or (-not $hasUnavailable -and @($resultNames | Where-Object { -not [bool]$Document.results[$_] }).Count -gt 0)
    $operationalPass = -not $hasFailure -and -not $hasUnavailable
    $derivedStatus = if ($hasFailure) { 'fail' } elseif ($hasUnavailable) { 'unavailable' } elseif ([string]$Document.producer_mode -cne 'formal') { 'unavailable' } elseif (-not [bool]$Document.source_dirty -and [bool]$Document.source_state_stable -and $operationalPass) { 'pass' } else { 'fail' }
    $derivedReason = if ($derivedStatus -ceq 'pass') { 'all-stop-loss-checks-passed' } elseif ($operationalPass -and [string]$Document.producer_mode -cne 'formal') { 'non-formal-producer-mode' } else { 'route-or-lifecycle-result-failure' }
    if ([string]$Document.status -cne $derivedStatus -or [string]$Document.reason -cne $derivedReason) { throw 'v1 stop-loss aggregate status is inconsistent' }

    return [ordered]@{status=$derivedStatus;producer_identity='v1-stop-loss-qualification/v1';source_revision=[string]$Document.source_revision;report_run_id=[string]$Document.report_run_id}
}

function Read-V1StopLossRolloutEvidence {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][Collections.IDictionary]$Gate,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedSource,
        [string[]]$ProtectedRoots = @()
    )
    try {
        Assert-ReleaseKeys -Value $Gate -Expected @('status','evidence_contract','artifact_path','evidence_digest','source_revision','producer_identity') -Label 'v1 stop-loss gate'
        if ([string]$Gate.evidence_contract -cne 'harness-v1-stop-loss-report/v1' -or [string]$Gate.source_revision -cne [string]$ExpectedSource.revision -or [string]::IsNullOrWhiteSpace([string]$Gate.producer_identity)) { throw 'v1 stop-loss gate binding is invalid' }
        $userProtected = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { @() } else { @('.claude','.agents','.dev-harness' | ForEach-Object { Join-Path $env:USERPROFILE $_ }) }
        $protected = Get-HarnessPortableEvidenceProtectedRoots -RepoRoot $RepoRoot -ProtectedRoots (@($ProtectedRoots) + $userProtected)
        $artifact = Read-HarnessRolloutEvidenceArtifact -ArtifactPath ([string]$Gate.artifact_path) -ExpectedDigest ([string]$Gate.evidence_digest) -ProtectedRoots $protected -MaximumBytes 1MB
        $document = ConvertFrom-V1StopLossEvidenceBytes -Bytes ([byte[]]$artifact.bytes)
        return Assert-V1StopLossReport -RepoRoot $RepoRoot -Document $document -ExpectedSource $ExpectedSource
    } catch { throw [IO.InvalidDataException]::new('rollout-evidence-v1-stop-loss-report-invalid',$_.Exception) }
}

function Assert-HarnessRolloutEvidenceSetProvenance {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Gates,
        [AllowEmptyString()][string]$RepoRoot = '',
        [System.Collections.IDictionary]$ExpectedSource = $null,
        [string[]]$ProtectedRoots = @()
    )
    $modelName = 'DP-G01-MODEL40'
    $cognitiveNames = @('DP-G02-COGNITIVE-HOST-3X3','DP-G05-V2-BARE-1.25','DP-G06-REQUEST-SEND-REDUCTION')
    $installedNames = @('DP-G03-INSTALLED-DESKTOP-HOST-3X3','DP-G07-DISTINCT-INSTALLED-DESKTOP-GATE')
    $v1StopLossName = 'DP-G14-V1-STOP-LOSS'
    $lifecyclePresets = [ordered]@{
        'DP-G18-CORE-LIFECYCLE'='core'
        'DP-G19-GOVERNED-LIFECYCLE'='governed'
        'DP-G20-FULL-LIFECYCLE'='full'
    }
    $lifecycleNames = @($lifecyclePresets.Keys)
    $adapted = $false
    if ($Gates.Contains($modelName)) {
        if ([string]::IsNullOrWhiteSpace($RepoRoot) -or $null -eq $ExpectedSource) { throw 'rollout-evidence-model-report-invalid' }
        $model = Read-ModelRolloutEvidence -RepoRoot $RepoRoot -Gate $Gates[$modelName] -ExpectedSource $ExpectedSource -ProtectedRoots $ProtectedRoots
        $Gates[$modelName].status = [string]$model.status
        $Gates[$modelName].producer_identity = [string]$model.producer_identity
        $adapted = $true
    }
    $cognitivePresent = @($cognitiveNames | Where-Object { $Gates.Contains($_) })
    if ($cognitivePresent.Count -gt 0) {
        if ($cognitivePresent.Count -ne 3 -or [string]::IsNullOrWhiteSpace($RepoRoot) -or $null -eq $ExpectedSource) { throw 'rollout-evidence-cognitive-gate-set-incomplete' }
        $cognitive = Read-CognitiveHostRolloutEvidence -RepoRoot $RepoRoot -Gates $Gates -Names $cognitiveNames -ExpectedSource $ExpectedSource -ProtectedRoots $ProtectedRoots
        $Gates[$cognitiveNames[0]].status = [string]$cognitive.g02_status
        $Gates[$cognitiveNames[1]].status = [string]$cognitive.g05_status
        $Gates[$cognitiveNames[2]].status = [string]$cognitive.g06_status
        foreach ($name in $cognitiveNames) { $Gates[$name].producer_identity = [string]$cognitive.producer_identity }
        $adapted = $true
    }
    $installedPresent = @($installedNames | Where-Object { $Gates.Contains($_) })
    if ($installedPresent.Count -gt 0) {
        if ($installedPresent.Count -ne 2 -or [string]::IsNullOrWhiteSpace($RepoRoot) -or $null -eq $ExpectedSource) { throw 'rollout-evidence-installed-report-invalid' }
        $installed = @(
            Read-InstalledDesktopRolloutEvidence -RepoRoot $RepoRoot -Gate $Gates[$installedNames[0]] -ExpectedSource $ExpectedSource -ProtectedRoots $ProtectedRoots
            Read-InstalledDesktopRolloutEvidence -RepoRoot $RepoRoot -Gate $Gates[$installedNames[1]] -ExpectedSource $ExpectedSource -ProtectedRoots $ProtectedRoots
        )
        if ($installed.Count -ne 2 -or [string]$installed[0].path -ceq [string]$installed[1].path -or [string]$installed[0].raw_digest -ceq [string]$installed[1].raw_digest -or
            ([string]$installed[0].volume -ceq [string]$installed[1].volume -and [string]$installed[0].file_id -ceq [string]$installed[1].file_id) -or
            [string]$installed[0].report_run_id -ceq [string]$installed[1].report_run_id -or [string]$installed[0].source_revision -cne [string]$installed[1].source_revision) {
            throw 'rollout-evidence-installed-reports-not-distinct'
        }
        foreach ($property in @('group_run_ids','group_root_digests','trial_run_ids','trial_root_digests','trial_payload_digests')) {
            if (@($installed[0][$property] | Where-Object { $_ -cin @($installed[1][$property]) }).Count -gt 0) { throw 'rollout-evidence-installed-reports-not-distinct' }
        }
        for ($index=0; $index -lt 2; $index++) {
            $gate = $Gates[$installedNames[$index]]
            $gate.status = [string]$installed[$index].status
            $gate.producer_identity = [string]$installed[$index].producer_identity
        }
        $adapted = $true
    }
    if ($Gates.Contains($v1StopLossName)) {
        if ([string]::IsNullOrWhiteSpace($RepoRoot) -or $null -eq $ExpectedSource) { throw 'rollout-evidence-v1-stop-loss-report-invalid' }
        $v1StopLoss = Read-V1StopLossRolloutEvidence -RepoRoot $RepoRoot -Gate $Gates[$v1StopLossName] -ExpectedSource $ExpectedSource -ProtectedRoots $ProtectedRoots
        $Gates[$v1StopLossName].status = [string]$v1StopLoss.status
        $Gates[$v1StopLossName].producer_identity = [string]$v1StopLoss.producer_identity
        $adapted = $true
    }
    $lifecyclePresent = @($lifecycleNames | Where-Object { $Gates.Contains($_) })
    if ($lifecyclePresent.Count -gt 0) {
        if ($lifecyclePresent.Count -ne 3 -or [string]::IsNullOrWhiteSpace($RepoRoot) -or $null -eq $ExpectedSource) { throw 'rollout-evidence-lifecycle-gate-set-incomplete' }
        $lifecycle = [Collections.Generic.List[object]]::new()
        foreach ($name in $lifecycleNames) {
            $lifecycle.Add((Read-PresetLifecycleRolloutEvidence -RepoRoot $RepoRoot -Gate $Gates[$name] -ExpectedSource $ExpectedSource -ExpectedPreset ([string]$lifecyclePresets[$name]) -ProtectedRoots $ProtectedRoots))
        }
        for ($left=0; $left -lt $lifecycle.Count; $left++) {
            for ($right=$left+1; $right -lt $lifecycle.Count; $right++) {
                if ([string]$lifecycle[$left].path -ieq [string]$lifecycle[$right].path -or
                    [string]$lifecycle[$left].raw_digest -ceq [string]$lifecycle[$right].raw_digest -or
                    ([string]$lifecycle[$left].volume -ceq [string]$lifecycle[$right].volume -and [string]$lifecycle[$left].file_id -ceq [string]$lifecycle[$right].file_id) -or
                    [string]$lifecycle[$left].report_run_id -ceq [string]$lifecycle[$right].report_run_id -or
                    [string]$lifecycle[$left].workspace_identity_digest -ceq [string]$lifecycle[$right].workspace_identity_digest -or
                    [string]$lifecycle[$left].profile_identity_digest -ceq [string]$lifecycle[$right].profile_identity_digest -or
                    [string]$lifecycle[$left].source_revision -cne [string]$lifecycle[$right].source_revision -or
                    [string]$lifecycle[$left].commit_tree_oid -cne [string]$lifecycle[$right].commit_tree_oid -or
                    [string]$lifecycle[$left].object_format -cne [string]$lifecycle[$right].object_format) {
                    throw 'rollout-evidence-lifecycle-reports-not-distinct'
                }
            }
        }
        for ($index=0; $index -lt $lifecycleNames.Count; $index++) {
            $gate = $Gates[$lifecycleNames[$index]]
            $gate.status = [string]$lifecycle[$index].status
            $gate.producer_identity = [string]$lifecycle[$index].producer_identity
        }
        $adapted = $true
    }
    $adaptedNames = @($modelName,$v1StopLossName) + $cognitiveNames + $installedNames + $lifecycleNames
    foreach ($name in @($Gates.Keys | Where-Object { $_ -cnotin $adaptedNames } | Sort-Object)) {
        $gate = $Gates[$name]
        if ($gate -isnot [System.Collections.IDictionary] -or
            [string]::IsNullOrWhiteSpace([string]$gate.artifact_path) -or
            [string]::IsNullOrWhiteSpace([string]$gate.producer_identity) -or
            [string]$gate.evidence_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'rollout-evidence-provenance-unverified' }
        [void](Read-HarnessRolloutEvidenceArtifact -ArtifactPath ([string]$gate.artifact_path) -ExpectedDigest ([string]$gate.evidence_digest) -ProtectedRoots $ProtectedRoots)
        throw "rollout-evidence-provenance-unwired-$name"
    }
    if ($adapted) { return $true }
    throw 'rollout-evidence-provenance-unverified'
}

function Test-HarnessRolloutPromotionPathSnapshot {
    param([System.Collections.IDictionary]$Left,[System.Collections.IDictionary]$Right)
    foreach ($name in @('source','final_target','candidate_target','authorization_target','runtime_default_target','workspace','workspace_identity')) {
        if (-not ([string]$Left[$name]).Equals([string]$Right[$name],[StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Test-HarnessRolloutBytesEqual {
    param([byte[]]$Left,[byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) { if ($Left[$index] -ne $Right[$index]) { return $false } }
    return $true
}

function Get-HarnessRolloutPublicationPreimage {
    param([string]$Path,[long]$Limit,[string]$Name)
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $bytes = if ($exists) {
        $info = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($info.Length -gt $Limit) { throw "rollout-promotion-$Name-target-too-large" }
        $value = [IO.File]::ReadAllBytes($Path)
        if ($value.Length -gt $Limit) { throw "rollout-promotion-$Name-target-too-large" }
        $value
    } else { [byte[]]::new(0) }
    return [ordered]@{exists=$exists;bytes=$bytes;digest=$(if($exists){Get-ReleaseSha256Bytes -Bytes $bytes}else{'missing'})}
}

function Write-HarnessRolloutPublicationBytes {
    param([string]$WorkspaceRoot,[string]$Path,[byte[]]$Bytes,[string]$SourceDigest,[string]$CurrentDigest)
    return & $script:RolloutAtomicModule {
        param($Root,$Target,$Value,$ExpectedSource,$ExpectedCurrent)
        Write-HarnessAtomicBytes -WorkspaceRoot $Root -Path $Target -SourceBytes $Value -ExpectedSourceDigest $ExpectedSource -ExpectedCurrentDigest $ExpectedCurrent
    } $WorkspaceRoot $Path $Bytes $SourceDigest $CurrentDigest
}

function Remove-HarnessRolloutPublicationFile {
    param([string]$WorkspaceRoot,[string]$Path,[string]$ExpectedDigest)
    return & $script:RolloutAtomicModule {
        param($Root,$Target,$Digest)
        Remove-HarnessFileIfDigestAtomic -WorkspaceRoot $Root -Path $Target -ExpectedDigest $Digest
    } $WorkspaceRoot $Path $ExpectedDigest
}

function Restore-HarnessRolloutPublicationRecord {
    param([string]$WorkspaceRoot,[System.Collections.IDictionary]$Record)
    if (-not $Record.Contains('published_digest')) { throw 'rollout-promotion-rollback-published-digest-missing' }
    $exists = Test-Path -LiteralPath ([string]$Record.path) -PathType Leaf
    $publishedDigest = [string]$Record.published_digest
    $currentDigest = if ($exists) { Get-ReleaseFileDigest -Path ([string]$Record.path) } else { 'missing' }
    if ($currentDigest -cne $publishedDigest) { throw "rollout-promotion-rollback-cas-mismatch-$($Record.name)" }
    if ([bool]$Record.preimage.exists) {
        [void](Write-HarnessRolloutPublicationBytes -WorkspaceRoot $WorkspaceRoot -Path ([string]$Record.relative) -Bytes ([byte[]]$Record.preimage.bytes) -SourceDigest ([string]$Record.preimage.digest) -CurrentDigest $publishedDigest)
    } elseif ($exists) {
        [void](Remove-HarnessRolloutPublicationFile -WorkspaceRoot $WorkspaceRoot -Path ([string]$Record.relative) -ExpectedDigest $publishedDigest)
    }
}

function Remove-HarnessRolloutCreatedParents {
    param([string]$WorkspaceRoot,[string[]]$Directories)
    $workspace = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\')
    foreach ($directory in @($Directories | Sort-Object Length -Descending -Unique)) {
        try {
            $full = [IO.Path]::GetFullPath($directory).TrimEnd('\')
            if ($full.StartsWith($workspace + '\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Container) -and @(Get-ChildItem -LiteralPath $full -Force).Count -eq 0) { [IO.Directory]::Delete($full,$false) }
        } catch { }
    }
}

function Invoke-HarnessRolloutPublicationTransaction {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][ValidateSet('canary-candidate','final-default')][string]$Phase,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$ReportBytes,
        [Parameter(Mandatory)][string]$ExpectedReportDigest,
        [AllowEmptyCollection()][byte[]]$AuthorizationBytes = [byte[]]::new(0),
        [AllowEmptyString()][string]$ExpectedAuthorizationDigest = '',
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$DecisionBytes,
        [Parameter(Mandatory)][string]$ExpectedDecisionDigest,
        [string[]]$ProtectedRoots = @(),
        [System.Collections.IDictionary]$SourceStateStart = $null,
        $ProtocolModule = $null,
        [int]$FaultAfterMutation = 0,
        [switch]$SkipCanonicalResolutionForStructuralTest
    )
    if ($ExpectedReportDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'rollout-promotion-expected-report-digest-invalid' }
    if ($Phase -ceq 'canary-candidate' -and $AuthorizationBytes.Length -eq 0) { throw 'rollout-promotion-canary-authorization-required' }
    if ($Phase -ceq 'canary-candidate' -and $ExpectedAuthorizationDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'rollout-promotion-expected-authorization-digest-invalid' }
    if ($Phase -ceq 'final-default' -and -not [string]::IsNullOrWhiteSpace($ExpectedAuthorizationDigest)) { throw 'rollout-promotion-unexpected-authorization-digest' }
    if ($DecisionBytes.Length -eq 0 -or $ExpectedDecisionDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'rollout-promotion-runtime-decision-invalid' }
    try { $decisionDocument = [Text.UTF8Encoding]::new($false,$true).GetString($DecisionBytes) | ConvertFrom-HarnessJson -Depth 20 }
    catch { throw 'rollout-promotion-runtime-decision-invalid' }
    if ($decisionDocument -isnot [Collections.IDictionary] -or [string]$decisionDocument.decision_digest -cne $ExpectedDecisionDigest) {
        throw 'rollout-promotion-runtime-decision-invalid'
    }
    $expectedDecisionBytesDigest = Get-ReleaseSha256Bytes -Bytes $DecisionBytes
    $paths = Resolve-HarnessRolloutPromotionPaths -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -ReportPath $ReportPath -ProtectedRoots $ProtectedRoots
    $sourceBytes = [IO.File]::ReadAllBytes([string]$paths.source)
    if (-not (Test-HarnessRolloutBytesEqual -Left $sourceBytes -Right $ReportBytes)) { throw 'rollout-promotion-input-bytes-changed' }
    $workspace = [string]$paths.workspace
    $mutexHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes([string]$paths.workspace_identity))).ToLowerInvariant()
    $mutex = [Threading.Mutex]::new($false,"Global\dev-harness.rollout-promotion.$mutexHash")
    $acquired = $false
    $createdParents = [Collections.Generic.List[string]]::new()
    $mutated = [Collections.Generic.List[object]]::new()
    try {
        try { $acquired = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'rollout-promotion-lock-timeout' }
        $locked = Resolve-HarnessRolloutPromotionPaths -RepoRoot $RepoRoot -WorkspaceRoot $workspace -ReportPath $ReportPath -ProtectedRoots $ProtectedRoots
        if (-not (Test-HarnessRolloutPromotionPathSnapshot -Left $paths -Right $locked)) { throw 'rollout-promotion-path-changed' }
        if (-not (Test-HarnessRolloutBytesEqual -Left ([IO.File]::ReadAllBytes([string]$locked.source)) -Right $ReportBytes)) { throw 'rollout-promotion-input-bytes-changed' }
        $records = [ordered]@{
            final = [ordered]@{name='final';path=[string]$paths.final_target;relative=[string]$paths.final_target_relative;limit=4MB;preimage=$null}
            candidate = [ordered]@{name='candidate';path=[string]$paths.candidate_target;relative=[string]$paths.candidate_target_relative;limit=4MB;preimage=$null}
            authorization = [ordered]@{name='authorization';path=[string]$paths.authorization_target;relative=[string]$paths.authorization_target_relative;limit=64KB;preimage=$null}
            runtime_default = [ordered]@{name='runtime-default';path=[string]$paths.runtime_default_target;relative=[string]$paths.runtime_default_target_relative;limit=64KB;preimage=$null}
        }
        foreach ($record in $records.Values) {
            $record.preimage = Get-HarnessRolloutPublicationPreimage -Path ([string]$record.path) -Limit ([long]$record.limit) -Name ([string]$record.name)
        }
        if ($Phase -ceq 'canary-candidate' -and [bool]$records.final.preimage.exists) { throw 'rollout-promotion-final-already-canonical' }
        foreach ($record in $records.Values) {
            $cursor = [IO.Path]::GetDirectoryName([string]$record.path)
            while (-not (Test-Path -LiteralPath $cursor)) {
                $createdParents.Add($cursor)
                $parent = [IO.Path]::GetDirectoryName($cursor)
                if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw 'rollout-promotion-parent-unavailable' }
                $cursor = $parent
            }
        }
        $operations = if ($Phase -ceq 'canary-candidate') {
            @(
                [ordered]@{record=$records.candidate;action='write';bytes=$ReportBytes},
                [ordered]@{record=$records.authorization;action='write';bytes=$AuthorizationBytes},
                [ordered]@{record=$records.runtime_default;action='write';bytes=$DecisionBytes}
            )
        } else {
            @(
                [ordered]@{record=$records.final;action='write';bytes=$ReportBytes},
                [ordered]@{record=$records.runtime_default;action='write';bytes=$DecisionBytes},
                [ordered]@{record=$records.candidate;action='delete';bytes=[byte[]]::new(0)},
                [ordered]@{record=$records.authorization;action='delete';bytes=[byte[]]::new(0)}
            )
        }
        $mutationCount = 0
        try {
            foreach ($operation in $operations) {
                $record = $operation.record
                if ([string]$operation.action -ceq 'write') {
                    $digest = Get-ReleaseSha256Bytes -Bytes ([byte[]]$operation.bytes)
                    [void](Write-HarnessRolloutPublicationBytes -WorkspaceRoot $workspace -Path ([string]$record.relative) -Bytes ([byte[]]$operation.bytes) -SourceDigest $digest -CurrentDigest ([string]$record.preimage.digest))
                    $record['published_digest'] = $digest
                    $mutated.Add($record)
                    $mutationCount++
                } elseif ([bool]$record.preimage.exists) {
                    [void](Remove-HarnessRolloutPublicationFile -WorkspaceRoot $workspace -Path ([string]$record.relative) -ExpectedDigest ([string]$record.preimage.digest))
                    $record['published_digest'] = 'missing'
                    $mutated.Add($record)
                    $mutationCount++
                }
                if ($FaultAfterMutation -gt 0 -and $mutationCount -eq $FaultAfterMutation) { throw 'rollout-promotion-structural-test-fault' }
            }
            $published = Resolve-HarnessRolloutPromotionPaths -RepoRoot $RepoRoot -WorkspaceRoot $workspace -ReportPath $ReportPath -ProtectedRoots $ProtectedRoots
            if (-not (Test-HarnessRolloutPromotionPathSnapshot -Left $paths -Right $published)) { throw 'rollout-promotion-published-path-changed' }
            if ($Phase -ceq 'canary-candidate') {
                if ((Get-ReleaseFileDigest -Path ([string]$paths.candidate_target)) -cne (Get-ReleaseSha256Bytes -Bytes $ReportBytes) -or
                    (Get-ReleaseFileDigest -Path ([string]$paths.authorization_target)) -cne (Get-ReleaseSha256Bytes -Bytes $AuthorizationBytes) -or
                    (Get-ReleaseFileDigest -Path ([string]$paths.runtime_default_target)) -cne $expectedDecisionBytesDigest -or
                    (Test-Path -LiteralPath ([string]$paths.final_target))) { throw 'rollout-promotion-candidate-byte-verification-failed' }
            } elseif ((Get-ReleaseFileDigest -Path ([string]$paths.final_target)) -cne (Get-ReleaseSha256Bytes -Bytes $ReportBytes) -or
                (Get-ReleaseFileDigest -Path ([string]$paths.runtime_default_target)) -cne $expectedDecisionBytesDigest -or
                (Test-Path -LiteralPath ([string]$paths.candidate_target)) -or (Test-Path -LiteralPath ([string]$paths.authorization_target))) { throw 'rollout-promotion-final-state-verification-failed' }
            if ($null -ne $SourceStateStart) {
                $sourceStateEnd = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
                if (-not (Test-HarnessReleaseSourceStable -Start $SourceStateStart -End $sourceStateEnd)) { throw 'rollout-promotion-source-changed' }
            }
            if (-not $SkipCanonicalResolutionForStructuralTest) {
                if ($null -eq $ProtocolModule) { throw 'rollout-promotion-canonical-verification-context-missing' }
                $resolution = & $ProtocolModule {
                    param($Root,$Workspace)
                    Get-HarnessProtocolResolution -RepoRoot $Root -WorkspaceRoot $Workspace -RequestedProtocol auto
                } $RepoRoot $workspace
                $runtimeDefault = $resolution.runtime_default_decision
                $expectedScope = if ($Phase -ceq 'canary-candidate') { 'workspace-canary' } else { 'release-default' }
                if ([string]$resolution.selected_protocol -cne 'v2' -or [string]$runtimeDefault.status -cne 'valid' -or
                    [string]$runtimeDefault.scope -cne $expectedScope -or [string]$runtimeDefault.decision_digest -cne $ExpectedDecisionDigest) {
                    throw 'rollout-promotion-canonical-verification-failed'
                }
            }
        } catch {
            $publishError = $_
            $rollbackFailures = [Collections.Generic.List[string]]::new()
            for ($index = $mutated.Count - 1; $index -ge 0; $index--) {
                try { Restore-HarnessRolloutPublicationRecord -WorkspaceRoot $workspace -Record $mutated[$index] }
                catch { $rollbackFailures.Add([string]$_.Exception.Message) }
            }
            Remove-HarnessRolloutCreatedParents -WorkspaceRoot $workspace -Directories @($createdParents)
            if ($rollbackFailures.Count -gt 0) { throw ('rollout-promotion-rollback-failed: ' + (@($rollbackFailures) -join '; ')) }
            throw $publishError
        }
        return [ordered]@{
            workspace=$workspace;phase=$Phase
            final_target=[string]$paths.final_target_relative
            candidate_target=[string]$paths.candidate_target_relative
            authorization_target=[string]$paths.authorization_target_relative
            runtime_default_target=[string]$paths.runtime_default_target_relative
        }
    } finally {
        if ($null -ne $mutex) {
            try { if ($acquired) { [void]$mutex.ReleaseMutex() } } finally { $mutex.Dispose() }
        }
    }
}

function Write-HarnessReleaseArtifact {
    param([Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    if (Test-Path -LiteralPath $Target) { throw 'release-output-already-exists' }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Target))
    [void][IO.Directory]::CreateDirectory($parent)
    Assert-ReleasePathHasNoReparseAncestor -Path $Target
    $null = Get-HostPhysicalPathInfo -Path $Target -AllowMissing -RejectLinks
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary,$Content,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$Target,$false)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-HarnessReleaseExitCode {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Gates,[Parameter(Mandatory)][bool]$Eligible,[bool]$RequireEligible)
    if (@($Gates.Keys | Where-Object { [string]$Gates[$_].status -cin @('fail','blocked') }).Count -gt 0) { return 1 }
    if ($RequireEligible -and -not $Eligible) { return 3 }
    return 0
}

function Get-HarnessReleaseSourceState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $revision = (@(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('rev-parse','--verify','HEAD')) -join '').Trim()
    $tree = (@(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('rev-parse',"$revision`^{tree}")) -join '').Trim()
    $objectFormat = (@(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('rev-parse','--show-object-format')) -join '').Trim()
    if ($revision -cnotmatch '^[0-9a-f]{40,64}$' -or $tree -cnotmatch '^[0-9a-f]{40,64}$') { throw 'release qualification source identity is invalid' }

    $entries = [Collections.Generic.List[string]]::new()
    foreach ($line in @(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('-c','core.quotepath=false','status','--porcelain=v1','--untracked-files=all'))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { $entries.Add([string]$line) }
    }
    foreach ($line in @(Invoke-ReleaseGit -RepoRoot $RepoRoot -Arguments @('-c','core.quotepath=false','ls-files','-v','--'))) {
        if ([string]$line -cnotmatch '^H ') { $entries.Add('IF ' + [string]$line) }
    }
    $statusText = @($entries | Sort-Object) -join "`n"
    return [ordered]@{
        revision = $revision
        commit_tree_oid = $tree
        object_format = $objectFormat
        dirty = $entries.Count -gt 0
        status_entry_count = $entries.Count
        status_digest = Get-ReleaseSha256Text -Text $statusText
        state_digest = Get-ReleaseSha256Text -Text ("{0}`n{1}`n{2}`n{3}" -f $revision,$tree,$objectFormat,$statusText)
        state_basis = 'git-revision-tree-status/v1'
    }
}

function Test-HarnessReleaseSourceStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Start,
        [Parameter(Mandatory)][System.Collections.IDictionary]$End
    )
    return -not [bool]$Start.dirty -and -not [bool]$End.dirty -and
        [string]$Start.revision -ceq [string]$End.revision -and
        [string]$Start.commit_tree_oid -ceq [string]$End.commit_tree_oid -and
        [string]$Start.object_format -ceq [string]$End.object_format -and
        [string]$Start.state_digest -ceq [string]$End.state_digest
}

function Assert-ReleaseKeys {
    param([object]$Value,[string[]]$Expected,[string]$Label)
    if ($Value -isnot [System.Collections.IDictionary]) { throw "$Label is not an object" }
    $actual = @($Value.Keys | ForEach-Object { [string]$_ })
    if (@(Compare-Object @($Expected | Sort-Object) @($actual | Sort-Object)).Count -ne 0) { throw "$Label field set is invalid" }
}

function Assert-ReleaseDigestValue {
    param([object]$Value,[string]$Label)
    if ([string]$Value -cnotmatch '^sha256:[0-9a-f]{64}$') { throw "$Label digest is invalid" }
}

function Assert-ReleaseDate {
    param([object]$Value,[string]$Label)
    try { [void][DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture) }
    catch { throw "$Label timestamp is invalid" }
}

function Assert-ReleaseReportDigest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document)
    Assert-ReleaseDigestValue -Value $Document.report_digest -Label 'report'
    $saved = $Document.report_digest
    try {
        $Document.report_digest = $null
        $canonical = $Document | ConvertTo-Json -Depth 100 -Compress
        $actual = Get-ReleaseSha256Text -Text $canonical
    } finally {
        $Document.report_digest = $saved
    }
    if ([string]$saved -cne $actual) { throw 'report digest mismatch' }
}

function Assert-ReleaseCurrentFileDigest {
    param([string]$RepoRoot,[object]$Value,[string]$RelativePath,[string]$Label)
    Assert-ReleaseDigestValue -Value $Value -Label $Label
    $path = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Label input is missing" }
    if ([string]$Value -cne (Get-ReleaseFileDigest -Path $path)) { throw "$Label input digest is stale" }
}

function Assert-ReleaseSourceStateShape {
    param([object]$Value,[string]$Label)
    Assert-ReleaseKeys -Value $Value -Expected @('revision','commit_tree_oid','object_format','dirty','status_entry_count','status_digest','state_digest','state_basis') -Label $Label
    if ([string]$Value.revision -cnotmatch '^[0-9a-f]{40,64}$' -or [string]$Value.commit_tree_oid -cnotmatch '^[0-9a-f]{40,64}$') { throw "$Label identity is invalid" }
    if ($Value.dirty -isnot [bool] -or $Value.status_entry_count -isnot [long] -or [long]$Value.status_entry_count -lt 0) { throw "$Label dirty state is invalid" }
    Assert-ReleaseDigestValue -Value $Value.status_digest -Label "$Label status"
    Assert-ReleaseDigestValue -Value $Value.state_digest -Label "$Label state"
    if ([string]$Value.state_basis -cne 'git-revision-tree-status/v1') { throw "$Label basis is invalid" }
}

function Assert-ReleaseSourceStateMatchesExpected {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Value,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-ReleaseSourceStateShape -Value $Value -Label $Label
    foreach ($name in @('revision','commit_tree_oid','object_format','status_digest','state_digest','state_basis')) {
        if ([string]$Value[$name] -cne [string]$Expected[$name]) { throw "$Label does not match the qualified source" }
    }
    if ([bool]$Value.dirty -ne [bool]$Expected.dirty -or [long]$Value.status_entry_count -ne [long]$Expected.status_entry_count) { throw "$Label does not match the qualified source" }
}

function Get-ReleaseMedian {
    param([Parameter(Mandatory)][double[]]$Values)
    if ($Values.Count -eq 0) { throw 'release evidence median requires at least one value' }
    $ordered = @($Values | Sort-Object)
    $middle = [int][math]::Floor($ordered.Count / 2)
    if (($ordered.Count % 2) -eq 1) { return [double]$ordered[$middle] }
    return ([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2
}

function Assert-ReleaseNumber {
    param([object]$Value,[string]$Label,[switch]$Positive,[switch]$NonNegative)
    if ($Value -isnot [long] -and $Value -isnot [double]) { throw "$Label is not numeric" }
    $number = [double]$Value
    if (-not [double]::IsFinite($number) -or ($Positive -and $number -le 0) -or ($NonNegative -and $number -lt 0)) { throw "$Label is invalid" }
    return $number
}

function Assert-ReleaseInteger {
    param([object]$Value,[string]$Label,[switch]$Positive,[switch]$NonNegative)
    if ($Value -isnot [long] -or ($Positive -and [long]$Value -le 0) -or ($NonNegative -and [long]$Value -lt 0)) { throw "$Label is not an integer" }
    return [long]$Value
}

function Assert-ReleaseBoolean {
    param([object]$Value,[string]$Label)
    if ($Value -isnot [bool]) { throw "$Label is not a boolean" }
}

function Assert-ReleaseNumberEquals {
    param([object]$Actual,[double]$Expected,[string]$Label)
    $number = Assert-ReleaseNumber -Value $Actual -Label $Label
    if ([math]::Abs($number - $Expected) -gt 0.0000001) { throw "$Label is inconsistent" }
}

function Read-ReleaseEvidenceReport {
    param([AllowEmptyString()][string]$Path,[string]$Kind)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [ordered]@{exists=$false;document=$null;evidence_digest=(Get-ReleaseSha256Text -Text "$Kind-report-missing");reason="$Kind-report-missing"}
    }
    try { $fullPath = [IO.Path]::GetFullPath($Path) }
    catch { return [ordered]@{exists=$false;document=$null;evidence_digest=(Get-ReleaseSha256Text -Text "$Kind-report-path-invalid");reason="$Kind-report-path-invalid"} }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return [ordered]@{exists=$false;document=$null;evidence_digest=(Get-ReleaseSha256Text -Text "$Kind-report-missing");reason="$Kind-report-missing"}
    }
    $bytes = $null
    try {
        $bytes = [IO.File]::ReadAllBytes($fullPath)
        $digest = Get-ReleaseSha256Bytes -Bytes $bytes
        $json = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document = $json | ConvertFrom-HarnessJson -Depth 100 -ErrorAction Stop
        return [ordered]@{exists=$true;document=$document;evidence_digest=$digest;reason=$null}
    } catch {
        $digest = if ($null -ne $bytes) { Get-ReleaseSha256Bytes -Bytes $bytes } else { Get-ReleaseSha256Text -Text "$Kind-report-read-failed" }
        return [ordered]@{exists=$true;document=$null;evidence_digest=$digest;reason="$Kind-report-invalid-json"}
    }
}

function Assert-ModelEvalReport {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedSource
    )
    Assert-ReleaseKeys -Value $Document -Expected @('schema_version','generated_at','source_revision','source_dirty','source_state_stable','source','execution','status','hard_gate_passed','metrics','cases','report_digest') -Label 'model report'
    if ([string]$Document.schema_version -cne 'harness-model-eval-report/v2') { throw 'model report schema is invalid' }
    Assert-ReleaseDate -Value $Document.generated_at -Label 'model report'
    Assert-ReleaseReportDigest -Document $Document
    if ([string]$Document.source_revision -cne [string]$ExpectedSource.revision) { throw 'model report revision is stale' }
    if ($Document.source_dirty -isnot [bool] -or $Document.source_state_stable -isnot [bool] -or $Document.hard_gate_passed -isnot [bool]) { throw 'model report boolean field is invalid' }
    if ([string]$Document.status -cnotin @('pass','fail','unavailable')) { throw 'model report status is invalid' }

    $sourceKeys = @('dataset_digest','observation_schema_digest','runner_digest','wrapper_digest','module_digest','credential_guard_digest','input_head_binding','commit_tree_oid','object_format','start','end')
    Assert-ReleaseKeys -Value $Document.source -Expected $sourceKeys -Label 'model report source'
    Assert-ReleaseKeys -Value $Document.source.input_head_binding -Expected @('start','end','basis') -Label 'model report input binding'
    if ($Document.source.input_head_binding.start -isnot [bool] -or $Document.source.input_head_binding.end -isnot [bool] -or [string]$Document.source.input_head_binding.basis -cne 'git-hash-object-equals-revision-blob/v1') { throw 'model report input binding is invalid' }
    Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.start -Expected $ExpectedSource -Label 'model report source start'
    Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.end -Expected $ExpectedSource -Label 'model report source end'
    if ([string]$Document.source.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or [string]$Document.source.object_format -cne [string]$ExpectedSource.object_format) { throw 'model report source tree is stale' }
    if ([string]$Document.source.start.revision -cne [string]$Document.source_revision -or [string]$Document.source.end.revision -cne [string]$Document.source_revision) { throw 'model report source states disagree' }
    Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.dataset_digest -RelativePath 'tests/evals/core-scenarios.json' -Label 'model dataset'
    Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.observation_schema_digest -RelativePath 'schemas/model-eval-observation.schema.json' -Label 'model observation schema'
    Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.runner_digest -RelativePath 'scripts/run-model-evals.ps1' -Label 'model runner'
    Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.wrapper_digest -RelativePath 'skills/codex/scripts/invoke_codex.ps1' -Label 'model wrapper'
    Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.module_digest -RelativePath 'scripts/lib/Harness.ModelEval.psm1' -Label 'model module'
    Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source.credential_guard_digest -RelativePath 'scripts/host-benchmark/HostBenchmark.Trial.ps1' -Label 'model credential guard'

    Assert-ReleaseKeys -Value $Document.execution -Expected @('model','reasoning','expected_codex_cli_version','session_isolation','ephemeral','sandbox','prompt_persisted','raw_command_persisted','thread_id_persisted','codex_home','codex_home_layout_stable') -Label 'model report execution'
    foreach ($name in @('ephemeral','prompt_persisted','raw_command_persisted','thread_id_persisted','codex_home_layout_stable')) { Assert-ReleaseBoolean -Value $Document.execution[$name] -Label "model report execution $name" }
    if ([string]$Document.execution.model -cne 'gpt-5.6-sol' -or [string]$Document.execution.reasoning -cne 'max' -or [string]$Document.execution.expected_codex_cli_version -cne '0.144.4' -or
        [string]$Document.execution.session_isolation -cne 'fresh-workspace-per-paraphrase' -or -not [bool]$Document.execution.ephemeral -or
        [string]$Document.execution.sandbox -cne 'read-only' -or [bool]$Document.execution.prompt_persisted -or
        [bool]$Document.execution.raw_command_persisted -or [bool]$Document.execution.thread_id_persisted -or
        [string]$Document.execution.codex_home -cne 'dedicated-config-isolated-auth-home-path-not-persisted') { throw 'model report execution identity is invalid' }

    $metricKeys = @('total','passed','failed','unavailable','missed_ask','critical_missed_ask','unnecessary_ask','product_inference_violation','read_only_write','false_pass','scope_expansion','lifecycle_skill_loads','model_turns','tool_calls','input_tokens','output_tokens','token_observations')
    Assert-ReleaseKeys -Value $Document.metrics -Expected $metricKeys -Label 'model report metrics'
    foreach ($name in $metricKeys) { [void](Assert-ReleaseInteger -Value $Document.metrics[$name] -Label "model report metric $name" -NonNegative) }
    $cases = @($Document.cases)
    if ([int]$Document.metrics.total -ne 40 -or $cases.Count -ne 40) { throw 'model report does not contain 40 sessions' }
    $dataset = [IO.File]::ReadAllText((Join-Path $RepoRoot 'tests/evals/core-scenarios.json'),[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 40 -ErrorAction Stop
    $datasetCases = @{}
    foreach ($datasetCase in @($dataset.cases)) {
        $datasetId = [string]$datasetCase.id
        if ([string]::IsNullOrWhiteSpace($datasetId) -or $datasetCases.ContainsKey($datasetId) -or @($datasetCase.paraphrases).Count -ne 2) { throw 'model dataset case identity is invalid' }
        $datasetCases[$datasetId] = $datasetCase
    }
    $expectedIds = @($datasetCases.Keys | Sort-Object)
    $actualIds = [Collections.Generic.List[string]]::new()
    $caseKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $passCount = 0; $failCount = 0; $unavailableCount = 0
    [long]$lifecycleSkillLoads = 0; [long]$modelTurns = 0; [long]$toolCalls = 0
    [long]$inputTokens = 0; [long]$outputTokens = 0; [long]$tokenObservations = 0
    foreach ($case in $cases) {
        Assert-ReleaseKeys -Value $case -Expected @('case_id','variant','paraphrase_digest','status','failures','workspace_write_count','observed','telemetry') -Label 'model report case'
        [void](Assert-ReleaseInteger -Value $case.variant -Label 'model report case variant' -Positive)
        [void](Assert-ReleaseInteger -Value $case.workspace_write_count -Label 'model report workspace write count' -NonNegative)
        if ([string]$case.case_id -cnotin $expectedIds -or [int]$case.variant -notin @(1,2)) { throw 'model report case identity is invalid' }
        $caseKey = '{0}:{1}' -f [string]$case.case_id,[int]$case.variant
        if (-not $caseKeys.Add($caseKey)) { throw 'model report contains a duplicate session' }
        $actualIds.Add([string]$case.case_id)
        Assert-ReleaseDigestValue -Value $case.paraphrase_digest -Label 'model paraphrase'
        $datasetCase = $datasetCases[[string]$case.case_id]
        $paraphrase = [string]@($datasetCase.paraphrases)[[int]$case.variant - 1]
        if ([string]$case.paraphrase_digest -cne (Get-ReleaseSha256Text -Text $paraphrase)) { throw 'model report paraphrase binding is invalid' }
        if ([int]$case.workspace_write_count -ne 0) { throw 'model report contains a workspace write' }
        switch ([string]$case.status) {
            'pass' { $passCount++ }
            'fail' { $failCount++ }
            'unavailable' { $unavailableCount++ }
            default { throw 'model report case status is invalid' }
        }
        if ([string]$case.status -ceq 'pass') {
            $observationJson = $case.observed | ConvertTo-Json -Depth 20 -Compress
            if (-not (Test-Json -Json $observationJson -SchemaFile (Join-Path $RepoRoot 'schemas/model-eval-observation.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue)) { throw 'model report observation is invalid' }
            $expected = $datasetCase.expected
            $observed = $case.observed
            $expectedAsk = [bool]$expected.ask_required
            if (-not $expected.Contains('action') -or -not $expected.Contains('write_authorized_now') -or [string]$observed.action -cne [string]$expected.action -or [bool]$observed.write_authorized_now -ne [bool]$expected.write_authorized_now) { throw 'model report observation action authorization disagrees with the dataset' }
            if ([bool]$observed.ask_required -ne $expectedAsk) { throw 'model report observation Ask decision disagrees with the dataset' }
            if ($expectedAsk -and [bool]$observed.write_authorized_now) { throw 'model report observation authorizes a blocked write' }
            if ($expected.Contains('read_only') -and [bool]$expected.read_only -and [bool]$observed.write_authorized_now) { throw 'model report observation authorizes a read-only write' }
            if (-not $expectedAsk -and $expected.Contains('profile')) {
                $expectedProfile = if ($null -eq $expected.profile) { 'none' } else { [string]$expected.profile }
                if ([string]$observed.profile -cne $expectedProfile) { throw 'model report observation profile disagrees with the dataset' }
            }
            if ($expected.Contains('selected_protocol') -and [string]$observed.selected_protocol -cne [string]$expected.selected_protocol) { throw 'model report observation protocol disagrees with the dataset' }
            if ($expected.Contains('completion_allowed')) {
                $expectedCompletion = [bool]$expected.completion_allowed
                if ([bool]$observed.completion_allowed -ne $expectedCompletion) { throw 'model report observation completion decision disagrees with the dataset' }
                if (-not $expectedCompletion -and [string]$observed.verification_status -ceq 'pass') { throw 'model report observation claims unverified completion' }
            }
            if ($expected.Contains('required_capability') -and [string]$expected.required_capability -notin @($observed.required_capabilities)) { throw 'model report observation omits a required capability' }
            if ($expected.Contains('profile') -and [string]$expected.profile -ceq 'direct' -and [int]$observed.lifecycle_skills_loaded -ne 0) { throw 'model report observation loads a lifecycle skill for Direct' }
            if ([bool]$observed.unauthorized_scope_change) { throw 'model report observation declares an unauthorized scope change' }
            $telemetry = $case.telemetry
            Assert-ReleaseKeys -Value $telemetry -Expected @('schema_version','status','model','reasoning','sandbox','approval_policy','ephemeral','duration_ms','first_useful_action_ms','model_turns','agent_messages','tool_calls','lifecycle_skill_loads','otel_trace','tokens','output_schema','codex_cli_version') -Label 'model report telemetry'
            Assert-ReleaseKeys -Value $telemetry.tool_calls -Expected @('command','mcp','web_search','file_change') -Label 'model report telemetry tool calls'
            Assert-ReleaseKeys -Value $telemetry.tokens -Expected @('status','input','cached_input','output') -Label 'model report telemetry tokens'
            Assert-ReleaseKeys -Value $telemetry.otel_trace -Expected @('enabled','contract','provenance') -Label 'model report telemetry OTLP'
            Assert-ReleaseKeys -Value $telemetry.output_schema -Expected @('enabled','digest') -Label 'model report telemetry output schema'
            foreach ($booleanField in @('ephemeral')) { Assert-ReleaseBoolean -Value $telemetry[$booleanField] -Label "model report telemetry $booleanField" }
            Assert-ReleaseBoolean -Value $telemetry.otel_trace.enabled -Label 'model report telemetry OTLP enabled'
            Assert-ReleaseBoolean -Value $telemetry.output_schema.enabled -Label 'model report telemetry output schema enabled'
            foreach ($integerField in @('model_turns','agent_messages','lifecycle_skill_loads')) { [void](Assert-ReleaseInteger -Value $telemetry[$integerField] -Label "model report telemetry $integerField" -NonNegative) }
            foreach ($integerField in @('command','mcp','web_search','file_change')) { [void](Assert-ReleaseInteger -Value $telemetry.tool_calls[$integerField] -Label "model report telemetry tool call $integerField" -NonNegative) }
            [void](Assert-ReleaseNumber -Value $telemetry.duration_ms -Label 'model report telemetry duration' -Positive)
            [void](Assert-ReleaseNumber -Value $telemetry.first_useful_action_ms -Label 'model report telemetry first useful action' -NonNegative)
            if ([string]$telemetry.schema_version -cne 'codex-invocation-telemetry/v2' -or [string]$telemetry.codex_cli_version -cne '0.144.4' -or [string]$telemetry.status -cne 'measured' -or
                [string]$telemetry.model -cne 'gpt-5.6-sol' -or [string]$telemetry.reasoning -cne 'max' -or [string]$telemetry.sandbox -cne 'read-only' -or [string]$telemetry.approval_policy -cne 'default' -or
                -not [bool]$telemetry.ephemeral -or [double]$telemetry.duration_ms -le 0 -or [bool]$telemetry.otel_trace.enabled -or
                -not [bool]$telemetry.output_schema.enabled -or [string]$telemetry.output_schema.digest -cne [string]$Document.source.observation_schema_digest) { throw 'model report telemetry identity is invalid' }
            $lifecycleSkillLoads += [long]$telemetry.lifecycle_skill_loads
            $modelTurns += [long]$telemetry.model_turns
            $caseToolCalls = [long]$telemetry.tool_calls.command + [long]$telemetry.tool_calls.mcp + [long]$telemetry.tool_calls.web_search + [long]$telemetry.tool_calls.file_change
            if ([long]$telemetry.lifecycle_skill_loads -ne 0 -or $caseToolCalls -ne 0 -or [long]$telemetry.model_turns -ne 1 -or [long]$telemetry.agent_messages -ne 1) { throw 'passing model report contains a multi-subject or tool-using session' }
            $toolCalls += $caseToolCalls
            if ([string]$telemetry.tokens.status -ceq 'measured') {
                foreach ($integerField in @('input','cached_input','output')) { [void](Assert-ReleaseInteger -Value $telemetry.tokens[$integerField] -Label "model report telemetry token $integerField" -NonNegative) }
                $inputTokens += [long]$telemetry.tokens.input; $outputTokens += [long]$telemetry.tokens.output; $tokenObservations++
            } elseif ([string]$telemetry.tokens.status -cne 'unavailable') { throw 'model report telemetry token status is invalid' }
        } elseif ($null -ne $case.observed -or $null -ne $case.telemetry) {
            throw 'non-passing model report session retains observation payload'
        }
    }
    if (@(Compare-Object $expectedIds @($actualIds | Sort-Object -Unique)).Count -ne 0) { throw 'model report scenario coverage is incomplete' }
    if ([int]$Document.metrics.passed -ne $passCount -or [int]$Document.metrics.failed -ne $failCount -or [int]$Document.metrics.unavailable -ne $unavailableCount) { throw 'model report counters disagree with sessions' }
    if ([bool]$Document.hard_gate_passed -ne ([string]$Document.status -ceq 'pass')) { throw 'model report hard gate disagrees with status' }

    if ([string]$Document.status -ceq 'pass') {
        if ([bool]$Document.source_dirty -or -not [bool]$Document.source_state_stable -or -not [bool]$Document.execution.codex_home_layout_stable -or
            -not [bool]$Document.source.input_head_binding.start -or -not [bool]$Document.source.input_head_binding.end -or
            [bool]$Document.source.start.dirty -or [bool]$Document.source.end.dirty -or
            [string]$Document.source.start.state_digest -cne [string]$Document.source.end.state_digest) { throw 'passing model report is not clean and source-stable' }
        foreach ($name in @('failed','unavailable','missed_ask','critical_missed_ask','unnecessary_ask','product_inference_violation','read_only_write','false_pass','scope_expansion')) {
            if ([long]$Document.metrics[$name] -ne 0) { throw "passing model report has nonzero $name" }
        }
        if ([int]$Document.metrics.passed -ne 40 -or @($cases | Where-Object { [string]$_.status -cne 'pass' -or @($_.failures).Count -ne 0 -or $null -eq $_.observed -or $null -eq $_.telemetry }).Count -ne 0) { throw 'passing model report contains an invalid session' }
        if ([long]$Document.metrics.lifecycle_skill_loads -ne $lifecycleSkillLoads -or [long]$Document.metrics.model_turns -ne $modelTurns -or
            [long]$Document.metrics.tool_calls -ne $toolCalls -or [long]$Document.metrics.input_tokens -ne $inputTokens -or
            [long]$Document.metrics.output_tokens -ne $outputTokens -or [long]$Document.metrics.token_observations -ne $tokenObservations) { throw 'passing model report aggregate telemetry is inconsistent' }
        if ([long]$Document.metrics.lifecycle_skill_loads -ne 0 -or [long]$Document.metrics.tool_calls -ne 0 -or [long]$Document.metrics.model_turns -ne 40) { throw 'passing model report violates single-subject execution' }
    }
}

function Assert-HostBenchmarkReportShape {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Document,[switch]$V2TrialIdentity)

    $sourceKeys = @('runner_digest','wrapper_digest','observation_schema_digest','otlp_collector_digest','atomic_write_module_digest','path_module_digest','otel_contract_digest','trial_helper_digest','input_head_binding','execution_mode','commit_tree_oid','object_format','start','end')
    $executionKeys = @('model','reasoning','trials_per_protocol','release_trials_required','max_fresh_sessions','fresh_workspace_per_trial','fresh_ephemeral_session_per_invocation','v1_comparator','bare_and_v2_start','semantic_task','host_turn_basis','successful_request_send_measurement','expected_codex_service_version','trial_order_strategy','actual_trial_order','cache_state','codex_home','sandbox','approval_policy','workspace_boundary','prompt_persisted','raw_command_persisted','thread_id_persisted','raw_trace_persisted','raw_trace_cleanup_confirmed','scratch_persisted','install_duration_included','duration_ms')
    $trialKeys = @('trial','runner_expected_trial','runner_evidence_passed','workspace_baseline_revision','status','diagnostic','completion_passed','outcome','reason_code','source_binding','workflow_contract','workflow_completed','v1_stage_journal','v1_target_journal','v1_validator_passed','fresh_sessions','host_turns','successful_request_sends','completed_agent_messages','total_duration_ms','sum_codex_process_duration_ms','first_useful_action_ms','tool_calls','loaded_skills','skill_file_command_matches','loaded_files','artifact_writes','runtime_writes','unexpected_writes','raw_trace_deleted','post_trial_diagnostics','tokens')
    if ($V2TrialIdentity) { $trialKeys = @('trial_run_id','trial_root_digest') + $trialKeys }

    Assert-ReleaseKeys -Value $Document.source -Expected $sourceKeys -Label 'host report source'
    Assert-ReleaseKeys -Value $Document.source.input_head_binding -Expected @('start','end','basis') -Label 'host report input binding'
    Assert-ReleaseKeys -Value $Document.execution -Expected $executionKeys -Label 'host report execution'
    foreach ($entry in @($Document.execution.actual_trial_order)) {
        Assert-ReleaseKeys -Value $entry -Expected @('sequence','protocol','trial') -Label 'host report trial order entry'
    }
    Assert-ReleaseKeys -Value $Document.protocols -Expected @('bare','v1','v2') -Label 'host report protocols'
    foreach ($protocol in @('bare','v1','v2')) {
        $record = $Document.protocols[$protocol]
        Assert-ReleaseKeys -Value $record -Expected @('status','runner_contract_failures','trials','successful_request_sends','medians') -Label "host report $protocol"
        Assert-ReleaseKeys -Value $record.successful_request_sends -Expected @('status','median','basis','reason') -Label "host report $protocol request aggregate"
        Assert-ReleaseKeys -Value $record.medians -Expected @('total_duration_ms','sum_codex_process_duration_ms','first_useful_action_ms','fresh_sessions','host_turns','successful_request_sends','tool_calls','skill_file_command_matches') -Label "host report $protocol medians"
        foreach ($trial in @($record.trials)) {
            Assert-ReleaseKeys -Value $trial -Expected $trialKeys -Label "host report $protocol trial"
            Assert-ReleaseKeys -Value $trial.source_binding -Expected @('status','revision','commit_tree_oid','verification','reason') -Label "host report $protocol source binding"
            Assert-ReleaseKeys -Value $trial.host_turns -Expected @('status','value','basis','reason') -Label "host report $protocol host turns"
            $requestKeys = if ([string]$trial.successful_request_sends.status -ceq 'measured') {
                @('status','value','basis','service_version','transport','per_session_counts','reason')
            } elseif ([string]$trial.successful_request_sends.status -ceq 'unavailable') {
                @('status','value','basis','reason')
            } else {
                throw "host report $protocol request status is invalid"
            }
            Assert-ReleaseKeys -Value $trial.successful_request_sends -Expected $requestKeys -Label "host report $protocol request sends"
            Assert-ReleaseKeys -Value $trial.tool_calls -Expected @('command','mcp','web_search','file_change','total') -Label "host report $protocol tool calls"
            Assert-ReleaseKeys -Value $trial.loaded_skills -Expected @('status','value','reason') -Label "host report $protocol loaded skills"
            Assert-ReleaseKeys -Value $trial.skill_file_command_matches -Expected @('status','value','reason') -Label "host report $protocol skill matches"
            Assert-ReleaseKeys -Value $trial.loaded_files -Expected @('status','value','reason') -Label "host report $protocol loaded files"
            Assert-ReleaseKeys -Value $trial.tokens -Expected @('status','input','cached_input','output') -Label "host report $protocol tokens"
        }
    }
    Assert-ReleaseKeys -Value $Document.performance -Expected @('release_trial_set','direct_latency','successful_request_send_reduction','eligible') -Label 'host report performance'
    Assert-ReleaseKeys -Value $Document.performance.release_trial_set -Expected @('status','required_trials_per_protocol','reason') -Label 'host release trial gate'
    Assert-ReleaseKeys -Value $Document.performance.direct_latency -Expected @('status','ratio','threshold','reason') -Label 'host direct latency gate'
    Assert-ReleaseKeys -Value $Document.performance.successful_request_send_reduction -Expected @('status','reduction','threshold','reason') -Label 'host request reduction gate'
}

function Assert-HostBenchmarkReport {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedSource,
        [ValidateRange(0,2)][int]$ExpectedOrderOffset = 0,
        [switch]$V2TrialIdentity
    )
    Assert-ReleaseKeys -Value $Document -Expected @('schema_version','generated_at_utc','source_revision','source_dirty','source_state_stable','source','execution','protocols','performance','status','report_digest') -Label 'host report'
    if ([string]$Document.schema_version -cne 'harness-host-benchmark-report/v1') { throw 'host report schema is invalid' }
    Assert-ReleaseDate -Value $Document.generated_at_utc -Label 'host report'
    Assert-ReleaseReportDigest -Document $Document
    if ([string]$Document.source_revision -cne [string]$ExpectedSource.revision) { throw 'host report revision is stale' }
    if ($Document.source_dirty -isnot [bool] -or $Document.source_state_stable -isnot [bool] -or [string]$Document.status -cnotin @('pass','fail','unavailable')) { throw 'host report status fields are invalid' }
    Assert-HostBenchmarkReportShape -Document $Document -V2TrialIdentity:$V2TrialIdentity
    if ($Document.performance.eligible -isnot [bool]) { throw 'host report eligibility is invalid' }

    $sourceDigestMap = [ordered]@{
        runner_digest='scripts/run-host-benchmark.ps1'
        wrapper_digest='skills/codex/scripts/invoke_codex.ps1'
        observation_schema_digest='schemas/host-benchmark/observation.schema.json'
        otlp_collector_digest='scripts/receive-otlp-http.ps1'
        atomic_write_module_digest='scripts/lib/Harness.AtomicWrite.psm1'
        path_module_digest='scripts/lib/Harness.Path.psm1'
        otel_contract_digest='scripts/host-benchmark/HostBenchmark.Otel.ps1'
        trial_helper_digest='scripts/host-benchmark/HostBenchmark.Trial.ps1'
    }
    foreach ($entry in $sourceDigestMap.GetEnumerator()) {
        if (-not $Document.source.Contains([string]$entry.Key)) { throw "host report source is missing $($entry.Key)" }
        Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source[$entry.Key] -RelativePath ([string]$entry.Value) -Label ("host {0}" -f $entry.Key)
    }
    if ([string]$Document.source.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or [string]$Document.source.object_format -cne [string]$ExpectedSource.object_format) { throw 'host report source tree is stale' }
    Assert-ReleaseKeys -Value $Document.source.input_head_binding -Expected @('start','end','basis') -Label 'host report input binding'
    if ($Document.source.input_head_binding.start -isnot [bool] -or $Document.source.input_head_binding.end -isnot [bool] -or [string]$Document.source.input_head_binding.basis -cne 'git-hash-object-equals-revision-blob/v1') { throw 'host report input binding is invalid' }
    Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.start -Expected $ExpectedSource -Label 'host report source start'
    Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.end -Expected $ExpectedSource -Label 'host report source end'
    if ([string]$Document.source.start.revision -cne [string]$Document.source_revision -or [string]$Document.source.end.revision -cne [string]$Document.source_revision) { throw 'host report source states disagree' }

    if ([string]$Document.status -ceq 'pass') {
        if ([bool]$Document.source_dirty -or -not [bool]$Document.source_state_stable -or -not [bool]$Document.source.input_head_binding.start -or -not [bool]$Document.source.input_head_binding.end -or
            [bool]$Document.source.start.dirty -or [bool]$Document.source.end.dirty -or [int]$Document.source.start.status_entry_count -ne 0 -or [int]$Document.source.end.status_entry_count -ne 0 -or
            [string]$Document.source.start.revision -cne [string]$ExpectedSource.revision -or [string]$Document.source.end.revision -cne [string]$ExpectedSource.revision -or
            [string]$Document.source.start.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or [string]$Document.source.end.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or
            [string]$Document.source.start.object_format -cne [string]$ExpectedSource.object_format -or [string]$Document.source.end.object_format -cne [string]$ExpectedSource.object_format -or
            [string]$Document.source.start.state_digest -cne [string]$Document.source.end.state_digest -or [string]$Document.source.execution_mode -cne 'clean-commit-clone') { throw 'passing host report is not clean and source-stable' }

        $executionKeys = @('model','reasoning','trials_per_protocol','release_trials_required','max_fresh_sessions','fresh_workspace_per_trial','fresh_ephemeral_session_per_invocation','v1_comparator','bare_and_v2_start','semantic_task','host_turn_basis','successful_request_send_measurement','expected_codex_service_version','trial_order_strategy','actual_trial_order','cache_state','codex_home','sandbox','approval_policy','workspace_boundary','prompt_persisted','raw_command_persisted','thread_id_persisted','raw_trace_persisted','raw_trace_cleanup_confirmed','scratch_persisted','install_duration_included','duration_ms')
        Assert-ReleaseKeys -Value $Document.execution -Expected $executionKeys -Label 'passing host report execution'
        foreach ($name in @('fresh_workspace_per_trial','fresh_ephemeral_session_per_invocation','prompt_persisted','raw_command_persisted','thread_id_persisted','raw_trace_persisted','raw_trace_cleanup_confirmed','scratch_persisted','install_duration_included')) { Assert-ReleaseBoolean -Value $Document.execution[$name] -Label "passing host report execution $name" }
        foreach ($name in @('trials_per_protocol','release_trials_required','max_fresh_sessions')) { [void](Assert-ReleaseInteger -Value $Document.execution[$name] -Label "passing host report execution $name" -Positive) }
        if ([string]$Document.execution.model -cne 'gpt-5.6-sol' -or [string]$Document.execution.reasoning -cne 'max' -or [int]$Document.execution.trials_per_protocol -ne 3 -or [int]$Document.execution.release_trials_required -ne 3 -or [int]$Document.execution.max_fresh_sessions -ne 8 -or
            -not [bool]$Document.execution.fresh_workspace_per_trial -or -not [bool]$Document.execution.fresh_ephemeral_session_per_invocation -or
            [string]$Document.execution.v1_comparator -cne 'confirmed-plan-to-done-one-stage-per-host-turn' -or [string]$Document.execution.bare_and_v2_start -cne 'new-task' -or [string]$Document.execution.semantic_task -cne 'change exact private file bytes and verify' -or
            [string]$Document.execution.host_turn_basis -cne 'codex-jsonl-turn.started' -or [string]$Document.execution.successful_request_send_measurement -cne 'codex-0.144.4-successful-websocket-send/v2' -or [string]$Document.execution.expected_codex_service_version -cne '0.144.4' -or
            [string]$Document.execution.trial_order_strategy -cne 'round-interleaved-rotating-start' -or [string]$Document.execution.cache_state -cne 'shared-dedicated-auth-home-and-host-cache-not-cleared-between-trials' -or
            [string]$Document.execution.codex_home -cne 'dedicated-config-isolated-auth-home-path-not-persisted' -or [string]$Document.execution.sandbox -cne 'danger-full-access' -or [string]$Document.execution.approval_policy -cne 'never' -or
            [string]$Document.execution.workspace_boundary -cne 'dedicated-ignored-nested-git-root' -or [bool]$Document.execution.prompt_persisted -or [bool]$Document.execution.raw_command_persisted -or [bool]$Document.execution.thread_id_persisted -or
            [bool]$Document.execution.raw_trace_persisted -or -not [bool]$Document.execution.raw_trace_cleanup_confirmed -or [bool]$Document.execution.scratch_persisted -or [bool]$Document.execution.install_duration_included) { throw 'passing host report execution identity is invalid' }
        [void](Assert-ReleaseNumber -Value $Document.execution.duration_ms -Label 'passing host report duration' -Positive)
        $protocolNames = @('bare','v1','v2')
        $expectedOrder = [Collections.Generic.List[string]]::new()
        $sequence = 0
        for ($trial=1; $trial -le 3; $trial++) {
            $rotation = ($ExpectedOrderOffset + $trial - 1) % $protocolNames.Count
            for ($offset=0; $offset -lt $protocolNames.Count; $offset++) {
                $sequence++
                $expectedOrder.Add(('{0}:{1}:{2}' -f $sequence,$protocolNames[($rotation + $offset) % $protocolNames.Count],$trial))
            }
        }
        $actualOrder = @($Document.execution.actual_trial_order | ForEach-Object {
            Assert-ReleaseKeys -Value $_ -Expected @('sequence','protocol','trial') -Label 'passing host report trial order entry'
            [void](Assert-ReleaseInteger -Value $_.sequence -Label 'passing host report trial order sequence' -Positive)
            [void](Assert-ReleaseInteger -Value $_.trial -Label 'passing host report trial order trial' -Positive)
            '{0}:{1}:{2}' -f [long]$_.sequence,[string]$_.protocol,[long]$_.trial
        })
        if (($actualOrder -join ',') -cne ($expectedOrder -join ',')) { throw 'passing host report trial order is invalid' }

        $protocolMedians = @{}
        foreach ($protocol in @('bare','v1','v2')) {
            $record = $Document.protocols[$protocol]
            Assert-ReleaseKeys -Value $record -Expected @('status','runner_contract_failures','trials','successful_request_sends','medians') -Label "passing host report $protocol"
            [void](Assert-ReleaseInteger -Value $record.runner_contract_failures -Label "passing host report $protocol runner failures" -NonNegative)
            $trials = @($record.trials)
            if ([string]$record.status -cne 'measured' -or [int]$record.runner_contract_failures -ne 0 -or $trials.Count -ne 3 -or (@($trials | ForEach-Object { [int]$_.trial } | Sort-Object) -join ',') -cne '1,2,3') { throw "passing host report $protocol trial set is invalid" }
            $durations = [Collections.Generic.List[double]]::new(); $processDurations = [Collections.Generic.List[double]]::new(); $firstActions = [Collections.Generic.List[double]]::new()
            $freshSessions = [Collections.Generic.List[double]]::new(); $hostTurns = [Collections.Generic.List[double]]::new(); $requestSends = [Collections.Generic.List[double]]::new(); $toolCalls = [Collections.Generic.List[double]]::new(); $skillMatches = [Collections.Generic.List[double]]::new()
            foreach ($trial in $trials) {
                $trialKeys = @('trial','runner_expected_trial','runner_evidence_passed','workspace_baseline_revision','status','diagnostic','completion_passed','outcome','reason_code','source_binding','workflow_contract','workflow_completed','v1_stage_journal','v1_target_journal','v1_validator_passed','fresh_sessions','host_turns','successful_request_sends','completed_agent_messages','total_duration_ms','sum_codex_process_duration_ms','first_useful_action_ms','tool_calls','loaded_skills','skill_file_command_matches','loaded_files','artifact_writes','runtime_writes','unexpected_writes','raw_trace_deleted','post_trial_diagnostics','tokens')
                if ($V2TrialIdentity) { $trialKeys = @('trial_run_id','trial_root_digest') + $trialKeys }
                Assert-ReleaseKeys -Value $trial -Expected $trialKeys -Label "passing host report $protocol trial"
                foreach ($name in @('runner_evidence_passed','completion_passed','workflow_completed','v1_validator_passed','raw_trace_deleted')) { Assert-ReleaseBoolean -Value $trial[$name] -Label "passing host report $protocol trial $name" }
                foreach ($name in @('trial','runner_expected_trial','fresh_sessions','completed_agent_messages','artifact_writes','runtime_writes','unexpected_writes')) { [void](Assert-ReleaseInteger -Value $trial[$name] -Label "passing host report $protocol trial $name" -NonNegative) }
                if ([int]$trial.runner_expected_trial -ne [int]$trial.trial -or -not [bool]$trial.runner_evidence_passed -or [string]$trial.status -cne 'measured' -or
                    -not [bool]$trial.completion_passed -or [string]$trial.outcome -cne 'completed' -or [string]$trial.reason_code -cne 'completed' -or -not [bool]$trial.workflow_completed -or
                    [int]$trial.unexpected_writes -ne 0 -or -not [bool]$trial.raw_trace_deleted -or @($trial.post_trial_diagnostics).Count -ne 0 -or
                    [string]$trial.workspace_baseline_revision -cnotmatch '^[0-9a-f]{40,64}$') { throw "passing host report $protocol contains an invalid trial" }
                Assert-ReleaseKeys -Value $trial.source_binding -Expected @('status','revision','commit_tree_oid','verification','reason') -Label "passing host report $protocol source binding"
                if ([string]$trial.source_binding.status -cne 'bound' -or [string]$trial.source_binding.revision -cne [string]$ExpectedSource.revision -or [string]$trial.source_binding.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or [string]$trial.source_binding.verification -cne 'git-head-tree-clean/v1') { throw "passing host report $protocol trial source binding is invalid" }
                Assert-ReleaseKeys -Value $trial.host_turns -Expected @('status','value','basis','reason') -Label "passing host report $protocol host turns"
                Assert-ReleaseKeys -Value $trial.successful_request_sends -Expected @('status','value','basis','service_version','transport','per_session_counts','reason') -Label "passing host report $protocol request sends"
                [void](Assert-ReleaseInteger -Value $trial.host_turns.value -Label "passing host report $protocol host turns" -Positive)
                [void](Assert-ReleaseInteger -Value $trial.successful_request_sends.value -Label "passing host report $protocol request sends" -Positive)
                $sessionSendCounts = @($trial.successful_request_sends.per_session_counts)
                foreach ($count in $sessionSendCounts) { [void](Assert-ReleaseInteger -Value $count -Label "passing host report $protocol per-session request sends" -Positive) }
                if ([string]$trial.host_turns.status -cne 'measured' -or [string]$trial.host_turns.basis -cne 'codex-jsonl-turn.started' -or [string]$trial.successful_request_sends.status -cne 'measured' -or
                    [string]$trial.successful_request_sends.basis -cne 'codex-0.144.4-successful-websocket-send/v2' -or [string]$trial.successful_request_sends.service_version -cne '0.144.4' -or
                    [string]$trial.successful_request_sends.transport -cne 'responses_websocket' -or $sessionSendCounts.Count -ne [int]$trial.fresh_sessions -or
                    [long](($sessionSendCounts | Measure-Object -Sum).Sum) -ne [long]$trial.successful_request_sends.value) { throw "passing host report $protocol trial measurement identity is invalid" }
                if ($protocol -ceq 'v1') {
                    if ([string]$trial.workflow_contract -cne 'confirmed-plan-to-done' -or [int]$trial.fresh_sessions -ne 5 -or [int]$trial.host_turns.value -ne 5 -or
                        (@($trial.v1_stage_journal) -join '>') -cne 'PLAN_REVIEW>IMPLEMENT>CODE_REVIEW>TEST>DONE' -or (@($trial.v1_target_journal) -join '>') -cne 'alpha>alpha>beta>beta>beta' -or
                        -not [bool]$trial.v1_validator_passed -or [int]$trial.artifact_writes -notin @(2,3) -or [int]$trial.runtime_writes -ne 3) { throw 'passing host report v1 workflow contract is invalid' }
                } elseif ([string]$trial.workflow_contract -cne 'new-task' -or [int]$trial.fresh_sessions -ne 1 -or [int]$trial.host_turns.value -ne 1 -or [int]$trial.artifact_writes -ne 0 -or [int]$trial.runtime_writes -ne 0) { throw "passing host report $protocol Direct contract is invalid" }
                Assert-ReleaseKeys -Value $trial.tool_calls -Expected @('command','mcp','web_search','file_change','total') -Label "passing host report $protocol tool calls"
                foreach ($name in @('command','mcp','web_search','file_change','total')) { [void](Assert-ReleaseInteger -Value $trial.tool_calls[$name] -Label "passing host report $protocol tool call $name" -NonNegative) }
                $computedToolCalls = [long]$trial.tool_calls.command + [long]$trial.tool_calls.mcp + [long]$trial.tool_calls.web_search + [long]$trial.tool_calls.file_change
                if ($computedToolCalls -ne [long]$trial.tool_calls.total -or $computedToolCalls -lt 0) { throw "passing host report $protocol tool calls are inconsistent" }
                Assert-ReleaseKeys -Value $trial.skill_file_command_matches -Expected @('status','value','reason') -Label "passing host report $protocol skill matches"
                if ([string]$trial.skill_file_command_matches.status -cne 'measured') { throw "passing host report $protocol skill measurement is invalid" }
                [void](Assert-ReleaseInteger -Value $trial.skill_file_command_matches.value -Label "passing host report $protocol skill matches" -NonNegative)
                Assert-ReleaseKeys -Value $trial.loaded_skills -Expected @('status','value','reason') -Label "passing host report $protocol loaded skills"
                Assert-ReleaseKeys -Value $trial.loaded_files -Expected @('status','value','reason') -Label "passing host report $protocol loaded files"
                if ([string]$trial.loaded_skills.status -cne 'unavailable' -or $null -ne $trial.loaded_skills.value -or [string]$trial.loaded_files.status -cne 'unavailable' -or $null -ne $trial.loaded_files.value) { throw "passing host report $protocol sanitized diagnostics are invalid" }
                Assert-ReleaseKeys -Value $trial.tokens -Expected @('status','input','cached_input','output') -Label "passing host report $protocol tokens"
                if ([string]$trial.tokens.status -cnotin @('measured','unavailable')) { throw "passing host report $protocol token status is invalid" }
                if ([string]$trial.tokens.status -ceq 'measured') {
                    foreach ($tokenName in @('input','cached_input','output')) { [void](Assert-ReleaseInteger -Value $trial.tokens[$tokenName] -Label "passing host report $protocol $tokenName tokens" -NonNegative) }
                }
                $durations.Add((Assert-ReleaseNumber -Value $trial.total_duration_ms -Label "passing host report $protocol duration" -Positive))
                $processDurations.Add((Assert-ReleaseNumber -Value $trial.sum_codex_process_duration_ms -Label "passing host report $protocol process duration" -Positive))
                if ($null -ne $trial.first_useful_action_ms) { $firstActions.Add((Assert-ReleaseNumber -Value $trial.first_useful_action_ms -Label "passing host report $protocol first useful action" -NonNegative)) }
                $freshSessions.Add([double]$trial.fresh_sessions); $hostTurns.Add((Assert-ReleaseNumber -Value $trial.host_turns.value -Label "passing host report $protocol host turns" -Positive))
                $requestSends.Add((Assert-ReleaseNumber -Value $trial.successful_request_sends.value -Label "passing host report $protocol request sends" -Positive))
                $toolCalls.Add([double]$computedToolCalls); $skillMatches.Add((Assert-ReleaseNumber -Value $trial.skill_file_command_matches.value -Label "passing host report $protocol skill matches" -NonNegative))
            }
            Assert-ReleaseKeys -Value $record.successful_request_sends -Expected @('status','median','basis','reason') -Label "passing host report $protocol request aggregate"
            Assert-ReleaseKeys -Value $record.medians -Expected @('total_duration_ms','sum_codex_process_duration_ms','first_useful_action_ms','fresh_sessions','host_turns','successful_request_sends','tool_calls','skill_file_command_matches') -Label "passing host report $protocol medians"
            $totalMedian = [math]::Round((Get-ReleaseMedian -Values @($durations)),2)
            $sendMedian = [math]::Round((Get-ReleaseMedian -Values @($requestSends)),2)
            if ([string]$record.successful_request_sends.status -cne 'measured' -or [string]$record.successful_request_sends.basis -cne 'codex-0.144.4-successful-websocket-send/v2') { throw "passing host report $protocol request aggregate identity is invalid" }
            Assert-ReleaseNumberEquals -Actual $record.successful_request_sends.median -Expected $sendMedian -Label "passing host report $protocol request median"
            Assert-ReleaseNumberEquals -Actual $record.medians.total_duration_ms -Expected $totalMedian -Label "passing host report $protocol duration median"
            Assert-ReleaseNumberEquals -Actual $record.medians.sum_codex_process_duration_ms -Expected ([math]::Round((Get-ReleaseMedian -Values @($processDurations)),2)) -Label "passing host report $protocol process median"
            Assert-ReleaseNumberEquals -Actual $record.medians.fresh_sessions -Expected ([math]::Round((Get-ReleaseMedian -Values @($freshSessions)),2)) -Label "passing host report $protocol session median"
            Assert-ReleaseNumberEquals -Actual $record.medians.host_turns -Expected ([math]::Round((Get-ReleaseMedian -Values @($hostTurns)),2)) -Label "passing host report $protocol turn median"
            Assert-ReleaseNumberEquals -Actual $record.medians.successful_request_sends -Expected $sendMedian -Label "passing host report $protocol duplicated request median"
            Assert-ReleaseNumberEquals -Actual $record.medians.tool_calls -Expected ([math]::Round((Get-ReleaseMedian -Values @($toolCalls)),2)) -Label "passing host report $protocol tool median"
            Assert-ReleaseNumberEquals -Actual $record.medians.skill_file_command_matches -Expected ([math]::Round((Get-ReleaseMedian -Values @($skillMatches)),2)) -Label "passing host report $protocol skill median"
            if ($firstActions.Count -eq 3) { Assert-ReleaseNumberEquals -Actual $record.medians.first_useful_action_ms -Expected ([math]::Round((Get-ReleaseMedian -Values @($firstActions)),2)) -Label "passing host report $protocol first action median" }
            elseif ($null -ne $record.medians.first_useful_action_ms) { throw "passing host report $protocol first action median is inconsistent" }
            $protocolMedians[$protocol] = [ordered]@{duration=$totalMedian;request_sends=$sendMedian}
        }

        Assert-ReleaseKeys -Value $Document.performance.release_trial_set -Expected @('status','required_trials_per_protocol','reason') -Label 'passing host release trial gate'
        Assert-ReleaseKeys -Value $Document.performance.direct_latency -Expected @('status','ratio','threshold','reason') -Label 'passing host direct latency gate'
        Assert-ReleaseKeys -Value $Document.performance.successful_request_send_reduction -Expected @('status','reduction','threshold','reason') -Label 'passing host request reduction gate'
        [void](Assert-ReleaseInteger -Value $Document.performance.release_trial_set.required_trials_per_protocol -Label 'passing host release trial count' -Positive)
        $directRatio = [math]::Round(([double]$protocolMedians.v2.duration / [double]$protocolMedians.bare.duration),4)
        $requestReduction = [math]::Round((([double]$protocolMedians.v1.request_sends - [double]$protocolMedians.v2.request_sends) / [double]$protocolMedians.v1.request_sends),4)
        [void](Assert-ReleaseNumber -Value $Document.performance.direct_latency.threshold -Label 'passing host direct latency threshold' -Positive)
        [void](Assert-ReleaseNumber -Value $Document.performance.successful_request_send_reduction.threshold -Label 'passing host request reduction threshold' -Positive)
        if ([string]$Document.performance.release_trial_set.status -cne 'pass' -or [int]$Document.performance.release_trial_set.required_trials_per_protocol -ne 3 -or
            [string]$Document.performance.direct_latency.status -cne $(if($directRatio -le 1.25){'pass'}else{'fail'}) -or [double]$Document.performance.direct_latency.threshold -ne 1.25 -or
            [string]$Document.performance.successful_request_send_reduction.status -cne $(if($requestReduction -ge 0.60){'pass'}else{'fail'}) -or [double]$Document.performance.successful_request_send_reduction.threshold -ne 0.60 -or
            -not [bool]$Document.performance.eligible) { throw 'passing host report performance gates are invalid' }
        Assert-ReleaseNumberEquals -Actual $Document.performance.direct_latency.ratio -Expected $directRatio -Label 'passing host direct latency ratio'
        Assert-ReleaseNumberEquals -Actual $Document.performance.successful_request_send_reduction.reduction -Expected $requestReduction -Label 'passing host request reduction'
    }
}

function Assert-HostBenchmarkGroupDigest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Group)
    Assert-ReleaseDigestValue -Value $Group.group_digest -Label 'host benchmark group'
    $saved = $Group.group_digest
    try {
        $Group.group_digest = $null
        $actual = Get-ReleaseSha256Text -Text ($Group | ConvertTo-Json -Depth 100 -Compress)
    } finally {
        $Group.group_digest = $saved
    }
    if ([string]$saved -cne [string]$actual) { throw 'host benchmark group digest mismatch' }
}

function ConvertTo-ReleaseCanonicalJson {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = [Collections.Generic.List[string]]::new()
        [string[]]$keys = @($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys,[StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $keyJson = ConvertTo-Json -InputObject $key -Compress
            $parts.Add(('{0}:{1}' -f $keyJson,(ConvertTo-ReleaseCanonicalJson -Value $Value[$key])))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $parts = [Collections.Generic.List[string]]::new()
        foreach ($item in $Value) { $parts.Add((ConvertTo-ReleaseCanonicalJson -Value $item)) }
        return '[' + ($parts -join ',') + ']'
    }
    return ConvertTo-Json -InputObject $Value -Compress
}

function Get-HostBenchmarkTrialPayloadDigest {
    param(
        [Parameter(Mandatory)][ValidateSet('bare','v1','v2')][string]$Protocol,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Trial
    )
    $payloadKeys = @('trial','runner_expected_trial','runner_evidence_passed','workspace_baseline_revision','status','diagnostic','completion_passed','outcome','reason_code','source_binding','workflow_contract','workflow_completed','v1_stage_journal','v1_target_journal','v1_validator_passed','fresh_sessions','host_turns','successful_request_sends','completed_agent_messages','total_duration_ms','sum_codex_process_duration_ms','first_useful_action_ms','tool_calls','loaded_skills','skill_file_command_matches','loaded_files','artifact_writes','runtime_writes','unexpected_writes','raw_trace_deleted','post_trial_diagnostics','tokens')
    Assert-ReleaseKeys -Value $Trial -Expected (@('trial_run_id','trial_root_digest') + $payloadKeys) -Label 'host benchmark v2 trial'
    $payload = [ordered]@{}
    foreach ($key in $payloadKeys) { $payload[$key] = $Trial[$key] }
    $canonical = ConvertTo-ReleaseCanonicalJson -Value $payload
    return Get-ReleaseSha256Text -Text ("{0}`n{1}" -f $Protocol,$canonical)
}

function Assert-HostBenchmarkReportV2 {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Document,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedSource
    )
    Assert-ReleaseKeys -Value $Document -Expected @('schema_version','generated_at_utc','source_revision','source_dirty','source_state_stable','source','execution','groups','performance','status','report_digest') -Label 'host report v2'
    if ([string]$Document.schema_version -cne 'harness-host-benchmark-report/v2') { throw 'host report schema is invalid' }
    Assert-ReleaseDate -Value $Document.generated_at_utc -Label 'host report v2'
    Assert-ReleaseReportDigest -Document $Document
    if ([string]$Document.source_revision -cne [string]$ExpectedSource.revision) { throw 'host report revision is stale' }
    if ($Document.source_dirty -isnot [bool] -or $Document.source_state_stable -isnot [bool] -or $Document.performance.eligible -isnot [bool] -or [string]$Document.status -cnotin @('pass','fail','unavailable')) { throw 'host report v2 status fields are invalid' }

    $sourceKeys = @('runner_digest','wrapper_digest','observation_schema_digest','otlp_collector_digest','atomic_write_module_digest','path_module_digest','otel_contract_digest','trial_helper_digest','input_head_binding','execution_mode','commit_tree_oid','object_format','start','end')
    Assert-ReleaseKeys -Value $Document.source -Expected $sourceKeys -Label 'host report v2 source'
    Assert-ReleaseKeys -Value $Document.source.input_head_binding -Expected @('start','end','basis') -Label 'host report v2 input binding'
    $sourceDigestMap = [ordered]@{
        runner_digest='scripts/run-host-benchmark.ps1';wrapper_digest='skills/codex/scripts/invoke_codex.ps1';observation_schema_digest='schemas/host-benchmark/observation.schema.json'
        otlp_collector_digest='scripts/receive-otlp-http.ps1';atomic_write_module_digest='scripts/lib/Harness.AtomicWrite.psm1';path_module_digest='scripts/lib/Harness.Path.psm1'
        otel_contract_digest='scripts/host-benchmark/HostBenchmark.Otel.ps1';trial_helper_digest='scripts/host-benchmark/HostBenchmark.Trial.ps1'
    }
    foreach ($entry in $sourceDigestMap.GetEnumerator()) { Assert-ReleaseCurrentFileDigest -RepoRoot $RepoRoot -Value $Document.source[$entry.Key] -RelativePath ([string]$entry.Value) -Label ("host v2 {0}" -f $entry.Key) }
    if ([string]$Document.source.commit_tree_oid -cne [string]$ExpectedSource.commit_tree_oid -or [string]$Document.source.object_format -cne [string]$ExpectedSource.object_format) { throw 'host report v2 source tree is stale' }
    if ($Document.source.input_head_binding.start -isnot [bool] -or $Document.source.input_head_binding.end -isnot [bool] -or [string]$Document.source.input_head_binding.basis -cne 'git-hash-object-equals-revision-blob/v1') { throw 'host report v2 input binding is invalid' }
    Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.start -Expected $ExpectedSource -Label 'host report v2 source start'
    Assert-ReleaseSourceStateMatchesExpected -Value $Document.source.end -Expected $ExpectedSource -Label 'host report v2 source end'

    $executionKeys = @('model','reasoning','groups','required_groups','trials_per_protocol_per_group','required_trials_per_protocol_per_group','group_order_strategy','max_fresh_sessions','fresh_workspace_per_trial','fresh_ephemeral_session_per_invocation','codex_home','duration_ms')
    Assert-ReleaseKeys -Value $Document.execution -Expected $executionKeys -Label 'host report v2 execution'
    foreach ($name in @('groups','required_groups','trials_per_protocol_per_group','required_trials_per_protocol_per_group','max_fresh_sessions')) { [void](Assert-ReleaseInteger -Value $Document.execution[$name] -Label "host report v2 execution $name" -Positive) }
    foreach ($name in @('fresh_workspace_per_trial','fresh_ephemeral_session_per_invocation')) { Assert-ReleaseBoolean -Value $Document.execution[$name] -Label "host report v2 execution $name" }
    [void](Assert-ReleaseNumber -Value $Document.execution.duration_ms -Label 'host report v2 duration' -Positive)
    if ([string]$Document.execution.model -cne 'gpt-5.6-sol' -or [string]$Document.execution.reasoning -cne 'max' -or [int]$Document.execution.required_groups -ne 3 -or
        [int]$Document.execution.required_trials_per_protocol_per_group -ne 3 -or [int]$Document.execution.max_fresh_sessions -ne 8 -or
        [string]$Document.execution.group_order_strategy -cne 'independent-groups-round-interleaved-rotating-start' -or
        -not [bool]$Document.execution.fresh_workspace_per_trial -or -not [bool]$Document.execution.fresh_ephemeral_session_per_invocation -or
        [string]$Document.execution.codex_home -cne 'dedicated-config-isolated-auth-home-path-not-persisted') { throw 'host report v2 execution identity is invalid' }

    $groups = @($Document.groups)
    if ($groups.Count -ne [int]$Document.execution.groups) { throw 'host report v2 group count is inconsistent' }
    $groupIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $groupRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $trialIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $trialRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $trialPayloads = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $passedGroups = 0; $failedGroups = 0; $unavailableGroups = 0
    for ($index=0; $index -lt $groups.Count; $index++) {
        $group = $groups[$index]
        Assert-ReleaseKeys -Value $group -Expected @('group_index','group_run_id','group_root_digest','source_revision','source_dirty','source_state_stable','source','execution','protocols','performance','status','group_digest') -Label 'host benchmark group'
        [void](Assert-ReleaseInteger -Value $group.group_index -Label 'host benchmark group index' -Positive)
        if ([int]$group.group_index -ne ($index + 1) -or [string]$group.group_run_id -cnotmatch '^[0-9a-f]{32}$') { throw 'host benchmark group identity is invalid' }
        Assert-ReleaseDigestValue -Value $group.group_root_digest -Label 'host benchmark group root'
        if (-not $groupIds.Add([string]$group.group_run_id) -or -not $groupRoots.Add([string]$group.group_root_digest)) { throw 'host benchmark groups are not independent' }
        Assert-HostBenchmarkGroupDigest -Group $group
        foreach ($protocol in @('bare','v1','v2')) {
            foreach ($trial in @($group.protocols[$protocol].trials)) {
                if ([string]$trial.trial_run_id -cnotmatch '^[0-9a-f]{32}$') { throw 'host benchmark trial run id is invalid' }
                Assert-ReleaseDigestValue -Value $trial.trial_root_digest -Label 'host benchmark trial root'
                if (-not $trialIds.Add([string]$trial.trial_run_id) -or -not $trialRoots.Add([string]$trial.trial_root_digest)) { throw 'host benchmark trial identity was reused' }
                $payloadDigest = Get-HostBenchmarkTrialPayloadDigest -Protocol $protocol -Trial $trial
                if (-not $trialPayloads.Add($payloadDigest)) { throw 'host benchmark trial normalized payload was reused' }
            }
        }
        $legacy = [ordered]@{
            schema_version='harness-host-benchmark-report/v1';generated_at_utc=$Document.generated_at_utc
            source_revision=$group.source_revision;source_dirty=$group.source_dirty;source_state_stable=$group.source_state_stable;source=$group.source
            execution=$group.execution;protocols=$group.protocols;performance=$group.performance;status=$group.status;report_digest=$null
        }
        $legacy.report_digest = Get-ReleaseSha256Text -Text ($legacy | ConvertTo-Json -Depth 100 -Compress)
        Assert-HostBenchmarkReport -RepoRoot $RepoRoot -Document $legacy -ExpectedSource $ExpectedSource -ExpectedOrderOffset $index -V2TrialIdentity
        if ([string]$group.source_revision -cne [string]$Document.source_revision) { throw 'host benchmark group source revision is inconsistent' }
        switch ([string]$group.status) { 'pass' { $passedGroups++ } 'fail' { $failedGroups++ } 'unavailable' { $unavailableGroups++ } default { throw 'host benchmark group status is invalid' } }
    }

    Assert-ReleaseKeys -Value $Document.performance -Expected @('release_group_set','eligible') -Label 'host report v2 performance'
    Assert-ReleaseKeys -Value $Document.performance.release_group_set -Expected @('status','required_groups','required_trials_per_protocol_per_group','passed_groups','reason') -Label 'host report v2 group gate'
    foreach ($name in @('required_groups','required_trials_per_protocol_per_group','passed_groups')) { [void](Assert-ReleaseInteger -Value $Document.performance.release_group_set[$name] -Label "host report v2 group gate $name" -NonNegative) }
    $configurationFailure = [int]$Document.execution.groups -ne 3 -or [int]$Document.execution.trials_per_protocol_per_group -ne 3
    $computedEligible = -not [bool]$Document.source_dirty -and [bool]$Document.source_state_stable -and -not $configurationFailure -and $groups.Count -eq 3 -and $passedGroups -eq 3
    $computedStatus = if ($configurationFailure -or $failedGroups -gt 0 -or [bool]$Document.source_dirty) { 'fail' } elseif ($unavailableGroups -gt 0 -or -not [bool]$Document.source_state_stable) { 'unavailable' } elseif ($computedEligible) { 'pass' } else { 'fail' }
    if ([int]$Document.performance.release_group_set.required_groups -ne 3 -or [int]$Document.performance.release_group_set.required_trials_per_protocol_per_group -ne 3 -or
        [int]$Document.performance.release_group_set.passed_groups -ne $passedGroups -or [string]$Document.performance.release_group_set.status -cne $(if($computedEligible){'pass'}else{$computedStatus}) -or
        [bool]$Document.performance.eligible -ne $computedEligible -or [string]$Document.status -cne $computedStatus) { throw 'host report v2 aggregate group gate is inconsistent' }
    if ($computedEligible -and ([bool]$Document.source_dirty -or -not [bool]$Document.source_state_stable -or -not [bool]$Document.source.input_head_binding.start -or -not [bool]$Document.source.input_head_binding.end -or [string]$Document.source.execution_mode -cne 'clean-commit-clone')) { throw 'passing host report v2 is not clean and source-stable' }
}

function Get-HarnessReleaseEvidenceGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('model','host')][string]$Kind,
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][string]$ReportPath = '',
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedSource
    )
    $command = if ($Kind -ceq 'model') {
        'scripts/run-model-evals.ps1 -Model gpt-5.6-sol -Reasoning max'
    } else {
        'scripts/run-host-benchmark.ps1 -Groups 3 -Trials 3 -Model gpt-5.6-sol -Reasoning max'
    }
    $input = Read-ReleaseEvidenceReport -Path $ReportPath -Kind $Kind
    if (-not [bool]$input.exists) {
        return [ordered]@{status='unavailable';evidence_digest=[string]$input.evidence_digest;command=$command;reason=[string]$input.reason}
    }
    if ($null -eq $input.document) {
        return [ordered]@{status='fail';evidence_digest=[string]$input.evidence_digest;command=$command;reason=[string]$input.reason}
    }
    try {
        if ([bool]$ExpectedSource.dirty) { throw 'release qualification source is dirty' }
        if ($Kind -ceq 'model') { Assert-ModelEvalReport -RepoRoot $RepoRoot -Document $input.document -ExpectedSource $ExpectedSource }
        else {
            if ([string]$input.document.schema_version -ceq 'harness-host-benchmark-report/v1') {
                Assert-HostBenchmarkReport -RepoRoot $RepoRoot -Document $input.document -ExpectedSource $ExpectedSource
                return [ordered]@{status='unavailable';evidence_digest=[string]$input.evidence_digest;command=$command;reason='host-report-insufficient-independent-groups'}
            }
            Assert-HostBenchmarkReportV2 -RepoRoot $RepoRoot -Document $input.document -ExpectedSource $ExpectedSource
        }
        $status = [string]$input.document.status
        return [ordered]@{status=$status;evidence_digest=[string]$input.evidence_digest;command=$command;reason=("$Kind-report-$status")}
    } catch {
        return [ordered]@{status='fail';evidence_digest=[string]$input.evidence_digest;command=$command;reason=("$Kind-report-invalid: " + [string]$_.Exception.Message)}
    }
}

Export-ModuleMember -Function Get-HarnessReleaseSourceState,Test-HarnessReleaseSourceStable,Get-HarnessReleaseEvidenceGate
