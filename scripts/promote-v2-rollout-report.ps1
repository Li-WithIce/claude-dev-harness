[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$ReportPath
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
    $pathModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -PassThru -ErrorAction Stop
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
    try {
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $document = & $pathModule { param($Json) $Json | ConvertFrom-HarnessJson -ErrorAction Stop } $text
    } catch { throw 'rollout-promotion-report-invalid-json' }
    & $protocolModule {
        param($Root,$Document)
        Assert-HarnessRolloutRepositoryClean -RepoRoot $Root
        Assert-HarnessRolloutReport -RepoRoot $Root -Document $Document
        if (-not [bool]$Document.eligible) { throw 'rollout-promotion-report-ineligible' }
    } $RepoRoot $document

    $successOutput = [ordered]@{
        operation = 'promote-v2-rollout-report'
        status = 'pass'
        target = [string]$paths.target_relative
        report_digest = [string]$document.report_digest
        file_digest = [string]$rawDigest
        source_revision = [string]$document.source_revision
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
            [string]$lockedPaths.workspace_identity -cne $mutexIdentity) { throw 'rollout-promotion-path-changed' }

        $createdParents=[Collections.Generic.List[string]]::new();$parentCursor=[IO.Path]::GetDirectoryName([string]$paths.target)
        while(-not(Test-Path -LiteralPath $parentCursor)){$createdParents.Add($parentCursor);$nextParent=[IO.Path]::GetDirectoryName($parentCursor);if([string]::IsNullOrWhiteSpace($nextParent)-or$nextParent-ceq$parentCursor){throw 'rollout-promotion-parent-unavailable'};$parentCursor=$nextParent}
        $preimageExists = Test-Path -LiteralPath $paths.target -PathType Leaf
        if ($preimageExists) {
            $preimageInfo = Get-Item -LiteralPath $paths.target -Force -ErrorAction Stop
            if ($preimageInfo.Length -gt 4MB) { throw 'rollout-promotion-target-too-large' }
            $preimageBytes = [IO.File]::ReadAllBytes([string]$paths.target)
            if ($preimageBytes.Length -gt 4MB) { throw 'rollout-promotion-target-too-large' }
        } else {
            $preimageBytes = [byte[]]::new(0)
        }
        $preimageDigest = if ($preimageExists) { Get-RolloutRawDigest -Bytes $preimageBytes } else { 'missing' }
        $published = $false
        try {
            $publishedDigest = Write-RolloutAtomicBytes -AtomicModule $atomicModule -Workspace $WorkspaceRoot -Bytes $bytes -Target ([string]$paths.target_relative) -SourceDigest $rawDigest -CurrentDigest $preimageDigest
            $published = $true
            $publishedPaths = & $evidenceModule {
                param($Root,$Workspace,$InputPath,$Protected)
                Resolve-HarnessRolloutPromotionPaths -RepoRoot $Root -WorkspaceRoot $Workspace -ReportPath $InputPath -ProtectedRoots $Protected
            } $RepoRoot $WorkspaceRoot $ReportPath @($protectedRoots)
            if (-not ([string]$publishedPaths.source).Equals([string]$paths.source,[StringComparison]::OrdinalIgnoreCase) -or
                -not ([string]$publishedPaths.target).Equals([string]$paths.target,[StringComparison]::OrdinalIgnoreCase) -or
                [string]$publishedPaths.workspace_identity -cne $mutexIdentity) { throw 'rollout-promotion-published-path-changed' }
            $targetBytes = [IO.File]::ReadAllBytes([string]$paths.target)
            if ($publishedDigest -cne $rawDigest -or -not (Test-RolloutBytesEqual -Left $bytes -Right $targetBytes)) { throw 'rollout-promotion-byte-verification-failed' }
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
            if ([string]$resolution.selected_protocol -cne 'v2' -or [string]$resolution.rollout_eligibility.status -cne 'pass' -or
                [string]$resolution.rollout_eligibility.report_digest -cne [string]$document.report_digest) { throw 'rollout-promotion-canonical-verification-failed' }
        } catch {
            $publishError = $_
            if ($published) {
                Restore-RolloutTarget -AtomicModule $atomicModule -Workspace $WorkspaceRoot -Target ([string]$paths.target_relative) -PreimageExists $preimageExists -PreimageBytes $preimageBytes -PreimageDigest $preimageDigest -PublishedDigest $rawDigest -CreatedParents @($createdParents)
            } else {
                Remove-RolloutEmptyParents -Directories @($createdParents)
            }
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
