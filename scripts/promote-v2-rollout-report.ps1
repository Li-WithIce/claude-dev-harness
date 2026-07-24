[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$ReportPath,
    [switch]$AuthorizeCanary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)

function Get-RolloutRawDigest {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Test-RolloutBytesEqual {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Left,[Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) { if ($Left[$index] -ne $Right[$index]) { return $false } }
    return $true
}

function Write-RolloutAtomicBytes {
    param($AtomicModule,[string]$Workspace,[byte[]]$Bytes,[string]$Target,[string]$SourceDigest,[string]$CurrentDigest)
    return & $AtomicModule {
        param($WorkspaceRoot,$SourceBytes,$TargetPath,$ExpectedSource,$ExpectedCurrent)
        Write-HarnessAtomicBytes -WorkspaceRoot $WorkspaceRoot -SourceBytes $SourceBytes -Path $TargetPath -ExpectedSourceDigest $ExpectedSource -ExpectedCurrentDigest $ExpectedCurrent
    } $Workspace $Bytes $Target $SourceDigest $CurrentDigest
}

function Restore-RolloutTarget {
    param(
        $AtomicModule,
        [string]$Workspace,
        [string]$Target,
        [bool]$PreimageExists,
        [AllowEmptyCollection()][byte[]]$PreimageBytes,
        [string]$PreimageDigest,
        [string]$PublishedDigest,
        [string[]]$CreatedParents = @()
    )
    if (-not $PreimageExists) {
        & $AtomicModule { param($WorkspaceRoot,$TargetPath,$Digest) [void](Remove-HarnessFileIfDigestAtomic -WorkspaceRoot $WorkspaceRoot -Path $TargetPath -ExpectedDigest $Digest) } $Workspace $Target $PublishedDigest
        Remove-RolloutEmptyParents -Directories $CreatedParents
        return
    }
    [void](Write-RolloutAtomicBytes -AtomicModule $AtomicModule -Workspace $Workspace -Bytes $PreimageBytes -Target $Target -SourceDigest $PreimageDigest -CurrentDigest $PublishedDigest)
}

function Remove-RolloutEmptyParents {
    param([string[]]$Directories = @())
    foreach ($directory in $Directories) {
        try {
            if ((Test-Path -LiteralPath $directory -PathType Container) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) { [IO.Directory]::Delete($directory,$false) }
        } catch { }
    }
}

try {
    $protocolModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -PassThru -ErrorAction Stop
    $atomicModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Force -PassThru -ErrorAction Stop
    $evidenceModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.RolloutEvidence.psm1') -Force -PassThru -ErrorAction Stop
    $protectedRoots = [Collections.Generic.List[string]]::new()
    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) { $protectedRoots.Add((Join-Path $userProfile '.codex')) }
    foreach ($name in @('CODEX_HOME','HOST_BENCHMARK_CODEX_HOME')) {
        $value = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $protectedRoots.Add($value) }
    }
    $paths = & $evidenceModule {
        param($Root,$Workspace,$InputPath,$Protected)
        Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Workspace -ReportPath $InputPath -ProtectedRoots $Protected
    } $RepoRoot $WorkspaceRoot $ReportPath @($protectedRoots)
    $WorkspaceRoot = [string]$paths.workspace

    $sourceStateStart = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
    if ([bool]$sourceStateStart.dirty) { throw 'rollout-promotion-source-dirty' }
    $sourceInfo = Get-Item -LiteralPath $paths.source -Force -ErrorAction Stop
    if ($sourceInfo.Length -gt 4MB) { throw 'rollout-promotion-input-too-large' }
    $bytes = [IO.File]::ReadAllBytes([string]$paths.source)
    if ($bytes.Length -gt 4MB) { throw 'rollout-promotion-input-too-large' }
    $rawDigest = Get-RolloutRawDigest -Bytes $bytes
    try { $document = & $protocolModule { param($Bytes) ConvertFrom-HarnessRolloutJsonBytes -Bytes $Bytes -Kind report } $bytes }
    catch { throw 'rollout-promotion-report-invalid-json' }
    & $protocolModule {
        param($Root,$Document,$Authorize)
        Assert-HarnessRolloutRepositoryClean -RepoRoot $Root
        Assert-HarnessRolloutReport -RepoRoot $Root -Document $Document
        if ([string]$Document.schema_version -ceq 'rollout-eligibility/v1') { throw 'rollout-promotion-v1-historical-only' }
        if ([string]$Document.phase -ceq 'canary-candidate' -and -not $Authorize) { throw 'rollout-promotion-canary-authorization-required' }
        if ([string]$Document.phase -ceq 'final-default' -and $Authorize) { throw 'rollout-promotion-final-does-not-use-canary-authorization' }
    } $RepoRoot $document ([bool]$AuthorizeCanary)

    $authorizationDocument = $null
    $authorizationBytes = $null
    if ([string]$document.phase -ceq 'canary-candidate') {
        $authorizationDocument = & $protocolModule {
            param($Root,$Workspace,$Report) New-HarnessCanaryAuthorizationDocument -RepoRoot $Root -WorkspaceRoot $Workspace -Report $Report
        } $RepoRoot $WorkspaceRoot $document
        $authorizationBytes = [Text.UTF8Encoding]::new($false).GetBytes(($authorizationDocument | ConvertTo-Json -Depth 30 -Compress))
    }

    $publications = [Collections.Generic.List[object]]::new()
    $publications.Add([ordered]@{
        name='report';target=[string]$paths.target;relative=[string]$paths.target_relative
        bytes=$bytes;digest=$rawDigest;limit=4MB;published=$false;published_digest=$null
    })
    if ($null -ne $authorizationDocument) {
        $publications.Add([ordered]@{
            name='authorization';target=[string]$paths.authorization_target;relative=[string]$paths.authorization_target_relative
            bytes=$authorizationBytes;digest=(Get-RolloutRawDigest -Bytes $authorizationBytes);limit=64KB;published=$false;published_digest=$null
        })
    }

    $successOutput = [ordered]@{
        operation = 'promote-v2-rollout-report'
        status = 'pass'
        phase = [string]$document.phase
        target = [string]$paths.target_relative
        report_digest = [string]$document.report_digest
        file_digest = [string]$rawDigest
        source_revision = [string]$document.source_revision
        authorization_target = $(if ($null -eq $authorizationDocument) { $null } else { [string]$paths.authorization_target_relative })
        authorization_digest = $(if ($null -eq $authorizationDocument) { $null } else { [string]$authorizationDocument.authorization_digest })
    } | ConvertTo-Json -Depth 5 -Compress
    $mutexIdentity = [string]$paths.workspace_identity
    $mutexBytes = [Text.UTF8Encoding]::new($false).GetBytes($mutexIdentity)
    $mutexHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($mutexBytes)).ToLowerInvariant()
    $mutex = [Threading.Mutex]::new($false,"Global\dev-harness.rollout-promotion.$mutexHash")
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'rollout-promotion-lock-timeout' }
        $lockedPaths = & $evidenceModule {
            param($Root,$Workspace,$InputPath,$Protected)
            Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Workspace -ReportPath $InputPath -ProtectedRoots $Protected
        } $RepoRoot $WorkspaceRoot $ReportPath @($protectedRoots)
        if (-not ([string]$lockedPaths.source).Equals([string]$paths.source,[StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$lockedPaths.target).Equals([string]$paths.target,[StringComparison]::OrdinalIgnoreCase) -or
            -not ([string]$lockedPaths.authorization_target).Equals([string]$paths.authorization_target,[StringComparison]::OrdinalIgnoreCase) -or
            [string]$lockedPaths.workspace_identity -cne $mutexIdentity) { throw 'rollout-promotion-path-changed' }

        $createdParents=[Collections.Generic.List[string]]::new();$parentCursor=[IO.Path]::GetDirectoryName([string]$paths.target)
        while(-not(Test-Path -LiteralPath $parentCursor)){$createdParents.Add($parentCursor);$nextParent=[IO.Path]::GetDirectoryName($parentCursor);if([string]::IsNullOrWhiteSpace($nextParent)-or$nextParent-ceq$parentCursor){throw 'rollout-promotion-parent-unavailable'};$parentCursor=$nextParent}
        foreach ($record in $publications) {
            $record['preimage_exists'] = Test-Path -LiteralPath ([string]$record.target) -PathType Leaf
            if ([bool]$record.preimage_exists) {
                $preimageInfo = Get-Item -LiteralPath ([string]$record.target) -Force -ErrorAction Stop
                if ($preimageInfo.Length -gt [long]$record.limit) { throw "rollout-promotion-$($record.name)-target-too-large" }
                $preimageBytes = [IO.File]::ReadAllBytes([string]$record.target)
                if ($preimageBytes.Length -gt [long]$record.limit) { throw "rollout-promotion-$($record.name)-target-too-large" }
            } else { $preimageBytes = [byte[]]::new(0) }
            $record['preimage_bytes'] = $preimageBytes
            $record['preimage_digest'] = if ([bool]$record.preimage_exists) { Get-RolloutRawDigest -Bytes $preimageBytes } else { 'missing' }
        }
        try {
            foreach ($record in $publications) {
                $record.published_digest = Write-RolloutAtomicBytes -AtomicModule $atomicModule -Workspace $WorkspaceRoot -Bytes ([byte[]]$record.bytes) -Target ([string]$record.relative) -SourceDigest ([string]$record.digest) -CurrentDigest ([string]$record.preimage_digest)
                $record.published = $true
            }
            $publishedPaths = & $evidenceModule {
                param($Root,$Workspace,$InputPath,$Protected)
                Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Workspace -ReportPath $InputPath -ProtectedRoots $Protected
            } $RepoRoot $WorkspaceRoot $ReportPath @($protectedRoots)
            if (-not ([string]$publishedPaths.source).Equals([string]$paths.source,[StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$publishedPaths.target).Equals([string]$paths.target,[StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$publishedPaths.authorization_target).Equals([string]$paths.authorization_target,[StringComparison]::OrdinalIgnoreCase) -or
                [string]$publishedPaths.workspace_identity -cne $mutexIdentity) { throw 'rollout-promotion-published-path-changed' }
            foreach ($record in $publications) {
                $targetBytes = [IO.File]::ReadAllBytes([string]$record.target)
                if ([string]$record.published_digest -cne [string]$record.digest -or -not (Test-RolloutBytesEqual -Left ([byte[]]$record.bytes) -Right $targetBytes)) { throw "rollout-promotion-$($record.name)-byte-verification-failed" }
            }
            $sourceStateEnd = Get-HarnessReleaseSourceState -RepoRoot $RepoRoot
            if (-not (Test-HarnessReleaseSourceStable -Start $sourceStateStart -End $sourceStateEnd)) { throw 'rollout-promotion-source-changed' }

            $hadReportEnvironment = Test-Path Env:HARNESS_V2_ELIGIBILITY_REPORT
            $priorReportEnvironment = [Environment]::GetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',[EnvironmentVariableTarget]::Process)
            try {
                Remove-Item Env:HARNESS_V2_ELIGIBILITY_REPORT -ErrorAction SilentlyContinue
                $resolution = & $protocolModule {
                    param($Root,$Workspace)
                    Get-HarnessProtocolResolution -RepoRoot $Root -WorkspaceRoot $Workspace -RequestedProtocol auto
                } $RepoRoot $WorkspaceRoot
            } finally {
                if ($hadReportEnvironment) { [Environment]::SetEnvironmentVariable('HARNESS_V2_ELIGIBILITY_REPORT',$priorReportEnvironment,[EnvironmentVariableTarget]::Process) }
                else { Remove-Item Env:HARNESS_V2_ELIGIBILITY_REPORT -ErrorAction SilentlyContinue }
            }
            $expectedStatus = if ([string]$document.phase -ceq 'canary-candidate') { 'canary-authorized' } else { 'pass' }
            if ([string]$resolution.selected_protocol -cne 'v2' -or [string]$resolution.rollout_eligibility.status -cne $expectedStatus -or
                [string]$resolution.rollout_eligibility.phase -cne [string]$document.phase -or
                [string]$resolution.rollout_eligibility.report_digest -cne [string]$document.report_digest) { throw 'rollout-promotion-canonical-verification-failed' }
        } catch {
            $publishError = $_
            for ($index = $publications.Count - 1; $index -ge 0; $index--) {
                $record = $publications[$index]
                if ([bool]$record.published) {
                    Restore-RolloutTarget -AtomicModule $atomicModule -Workspace $WorkspaceRoot -Target ([string]$record.relative) -PreimageExists ([bool]$record.preimage_exists) -PreimageBytes ([byte[]]$record.preimage_bytes) -PreimageDigest ([string]$record.preimage_digest) -PublishedDigest ([string]$record.digest) -CreatedParents @($createdParents)
                }
            }
            Remove-RolloutEmptyParents -Directories @($createdParents)
            throw $publishError
        }
    } finally {
        if ($null -ne $mutex) {
            try { if ($acquired) { [void]$mutex.ReleaseMutex() } } finally { $mutex.Dispose() }
        }
    }
    Write-Output $successOutput
    exit 0
} catch {
    [Console]::Error.WriteLine('[ROLLOUT-PROMOTION] FAIL: ' + [string]$_.Exception.Message)
    exit 2
}
