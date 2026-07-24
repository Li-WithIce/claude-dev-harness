Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
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

    $targetRelative = '.assistant/runtime/rollout/v2-eligibility.json'
    $target = Resolve-HarnessContainedPath -WorkspaceRoot $workspace -Path $targetRelative -Label 'rollout promotion target' -AllowMissing
    Assert-ReleasePathHasNoReparseAncestor -Path $target
    if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'rollout-promotion-target-not-file' }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Assert-ReleaseSingleLinkFile -Path $target -Label 'target'
        Assert-ReleaseSingleDataStreamFile -Path $target -Label 'target'
    }
    $physicalTarget = Get-HostPhysicalPathInfo -Path $target -AllowMissing -RejectLinks
    if ([string]$physicalSource.volume -ceq [string]$physicalTarget.volume -and [string]$physicalSource.file_id -ceq [string]$physicalTarget.file_id) { throw 'rollout-promotion-input-overlaps-target' }
    foreach ($root in @(@($gitDirectory,$gitCommonDirectory) + @($ProtectedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))) {
        $physicalRoot = Get-HostPhysicalPathInfo -Path ([IO.Path]::GetFullPath($root)) -AllowMissing
        if ((Test-ReleasePathAtOrBelow -Path $target -Root $root) -or
            (Test-ReleasePathAtOrBelow -Path ([string]$physicalTarget.physical_path) -Root ([string]$physicalRoot.physical_path))) {
            throw 'rollout-promotion-target-overlaps-protected-root'
        }
    }
    $authorizationTargetRelative = '.assistant/runtime/rollout/canary-authorization.json'
    $authorizationTarget = Resolve-HarnessContainedPath -WorkspaceRoot $workspace -Path $authorizationTargetRelative -Label 'rollout Canary authorization target' -AllowMissing
    Assert-ReleasePathHasNoReparseAncestor -Path $authorizationTarget
    if ((Test-Path -LiteralPath $authorizationTarget) -and -not (Test-Path -LiteralPath $authorizationTarget -PathType Leaf)) { throw 'rollout-promotion-authorization-target-not-file' }
    if (Test-Path -LiteralPath $authorizationTarget -PathType Leaf) {
        Assert-ReleaseSingleLinkFile -Path $authorizationTarget -Label 'authorization-target'
        Assert-ReleaseSingleDataStreamFile -Path $authorizationTarget -Label 'authorization-target'
    }
    $physicalAuthorizationTarget = Get-HostPhysicalPathInfo -Path $authorizationTarget -AllowMissing -RejectLinks
    foreach ($root in @(@($gitDirectory,$gitCommonDirectory) + @($ProtectedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))) {
        $physicalRoot = Get-HostPhysicalPathInfo -Path ([IO.Path]::GetFullPath($root)) -AllowMissing
        if ((Test-ReleasePathAtOrBelow -Path $authorizationTarget -Root $root) -or
            (Test-ReleasePathAtOrBelow -Path ([string]$physicalAuthorizationTarget.physical_path) -Root ([string]$physicalRoot.physical_path))) {
            throw 'rollout-promotion-authorization-target-overlaps-protected-root'
        }
    }
    return [ordered]@{
        source=$source;target=$target;target_relative=$targetRelative
        authorization_target=$authorizationTarget;authorization_target_relative=$authorizationTargetRelative
        workspace=$workspace;workspace_identity=$workspaceIdentity
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
