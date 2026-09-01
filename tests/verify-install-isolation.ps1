[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'fixture-test-common.ps1')

function Invoke-RepoScript {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [hashtable]$Arguments
    )

    $originalUserProfile = $env:USERPROFILE
    $originalLastExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $originalLastExitCodeValue = if ($null -ne $originalLastExitCode) { $originalLastExitCode.Value } else { $null }
    try {
        $env:USERPROFILE = $UserProfile
        $global:LASTEXITCODE = 0
        $output = @(& $ScriptPath @Arguments 2>&1)
        return [pscustomobject]@{
            Output   = $output
            ExitCode = (Get-LastExitCodeOrZero)
        }
    } finally {
        $env:USERPROFILE = $originalUserProfile
        if ($null -eq $originalLastExitCode) {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        } else {
            $global:LASTEXITCODE = $originalLastExitCodeValue
        }
    }
}

function Invoke-RepoScriptProcess {
    param(
        [string]$UserProfile,
        [string]$ScriptPath,
        [string[]]$Arguments,
        [int]$TimeoutMilliseconds = 120000
    )

    $child = Start-RepoProcess -UserProfile $UserProfile -ScriptPath $ScriptPath -Arguments $Arguments
    try {
        if (-not $child.Process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $child.Process.Kill($true)
            } catch {
            }
            throw "Timed out waiting for repo script: $ScriptPath"
        }
        $standardOutput = $child.StdOut.Result
        $standardError = $child.StdErr.Result
        return [pscustomobject]@{
            ExitCode = $child.Process.ExitCode
            Output   = @($standardOutput,$standardError | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
        }
    } finally {
        $child.Process.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = Get-NormalizedPath -Path $RepoRoot
. (Join-Path $RepoRoot 'scripts\install-transaction-common.ps1')
$scratchRoot = Join-Path $RepoRoot ('tmp\install-isolation-regression-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $scratchRoot) {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $scratchRoot | Out-Null

$checks = New-Object System.Collections.Generic.List[string]
$failures = New-Object System.Collections.Generic.List[string]

try {
$installSource = Get-Content -LiteralPath (Join-Path $RepoRoot 'install.ps1') -Raw -Encoding utf8
if ($installSource.Contains("if (`$pointerDigest -match '^[0-9a-f]{64}$' -and")) {
    $checks.Add('receipt retry skips pointer marker creation when both receipt and pointer are absent') | Out-Null
} else {
    $failures.Add('receipt retry must not pass the missing sentinel to pointer marker creation') | Out-Null
}
$transactionSources = $installSource + "`n" +
    (Get-Content -LiteralPath (Join-Path $RepoRoot 'uninstall.ps1') -Raw -Encoding utf8) + "`n" +
    (Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\install-transaction-common.ps1') -Raw -Encoding utf8)
$obsoleteTransactionSymbols = @(
    'manifest_backup_record_count',
    'manifest_restore_plan_digest',
    'Get-InstallManifestRestorePlanDigest',
    'Assert-InstallTransactionManifestPlanBinding',
    'ActiveInstallTransactionJournal',
    'recovery_phase'
)
$presentObsoleteSymbols = @($obsoleteTransactionSymbols | Where-Object { $transactionSources.Contains($_) })
if ($presentObsoleteSymbols.Count -eq 0) {
    $checks.Add('install transaction production code keeps one mutable restore plan and no recovery phase mirror') | Out-Null
} else {
    $failures.Add('obsolete install transaction mirrors remain: ' + ($presentObsoleteSymbols -join ', ')) | Out-Null
}
$digestDirectory = Join-Path $scratchRoot 'digest-directory-is-not-missing'
New-Item -ItemType Directory -Path $digestDirectory -Force | Out-Null
$digestRejectedDirectory = $false
try {
    [void](Get-InstallStateFileDigest -Path $digestDirectory)
} catch {
    $digestRejectedDirectory = $true
}
if ($digestRejectedDirectory) {
    $checks.Add('install state digest rejects an existing directory instead of treating it as a missing registry') | Out-Null
} else {
    $failures.Add('install state digest should distinguish a directory from a missing registry file') | Out-Null
}
$snapshotProbePath = Join-Path $scratchRoot 'text-snapshot-content-identity.json'
$snapshotProbeA = '{"state":"A"}'
$snapshotProbeB = '{"state":"B"}'
$snapshotProbeEncoding = [System.Text.UTF8Encoding]::new($true)
[System.IO.File]::WriteAllText($snapshotProbePath, $snapshotProbeA, $snapshotProbeEncoding)
$snapshotProbeScriptPath = Join-Path $scratchRoot 'text-snapshot-content-identity.ps1'
Write-Utf8Bom -Path $snapshotProbeScriptPath -Content @'
param([string]$CommonPath, [string]$Path)
$ErrorActionPreference = 'Stop'
. $CommonPath
$probeA = '{"state":"A"}'
$probeB = '{"state":"B"}'
$probeEncoding = New-Object System.Text.UTF8Encoding($true)
function Read-FileUtf8 {
    param([string]$Path)

    [System.IO.File]::WriteAllText($Path, $probeB, (New-Object System.Text.UTF8Encoding($false)))
    $content = [System.IO.File]::ReadAllText($Path)
    [System.IO.File]::WriteAllText($Path, $probeA, $probeEncoding)
    return $content
}
$snapshot = Read-InstallTextSnapshot -Path $Path
if ($PSVersionTable.PSVersion.Major -ne 5 -or
    $snapshot.Content -cne $probeA -or
    $snapshot.Content[0] -eq [char]0xFEFF -or
    -not (Test-InstallExactIdentityEqual -Left $snapshot.Identity -Right (Get-InstallManagedPathIdentity -Path $Path))) {
    throw 'text snapshot returned mismatched content and identity'
}
Write-Output 'SNAPSHOT_PROBE_PASS_PS5'
'@
$snapshotProbeOutput = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $snapshotProbeScriptPath `
    -CommonPath (Join-Path $RepoRoot 'scripts\install-transaction-common.ps1') -Path $snapshotProbePath 2>&1 | ForEach-Object { [string]$_ })
$snapshotProbeExit = $LASTEXITCODE
if ($snapshotProbeExit -eq 0 -and $snapshotProbeOutput -contains 'SNAPSHOT_PROBE_PASS_PS5') {
    $checks.Add('Windows PowerShell text snapshot binds UTF-8 content and exact identity to one read despite an A-to-B-to-A reader probe') | Out-Null
} else {
    $failures.Add('Windows PowerShell text snapshot must not return Content B with Identity A during an A-to-B-to-A reader probe: ' + ($snapshotProbeOutput -join ' | ')) | Out-Null
}
try {
    $emptyDirectoryIdentity = Get-InstallManagedPathIdentity -Path $digestDirectory
    if ([string]$emptyDirectoryIdentity.item_type -ne 'directory' -or [string]$emptyDirectoryIdentity.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'empty directory identity is invalid'
    }

    $transitionRoot = Join-Path $scratchRoot 'exact-path-transition'
    New-Item -ItemType Directory -Path $transitionRoot -Force | Out-Null
    $newDirectory = {
        param([string]$Path, [string]$Content)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Path 'state.txt'), $Content, (New-Object System.Text.UTF8Encoding($false)))
    }
    $target = Join-Path $transitionRoot 'target'
    & $newDirectory $target 'source'
    $sourceIdentity = Get-InstallManagedPathIdentity -Path $target
    $desiredTemplate = Join-Path $transitionRoot 'desired-template'
    & $newDirectory $desiredTemplate 'desired'
    $desiredIdentity = Get-InstallManagedPathIdentity -Path $desiredTemplate

    $sidecars = Get-InstallExactPathSidecarPaths -Path $target -DesiredIdentity $desiredIdentity
    Move-Item -LiteralPath $desiredTemplate -Destination $sidecars.Ready
    [void](Invoke-InstallExactPathTransition -Path $target -SourceIdentity $sourceIdentity -DesiredIdentity $desiredIdentity -RecoverOnly)
    if (-not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $target) -Right $desiredIdentity)) { throw 'source+ready did not converge' }

    Remove-Item -LiteralPath $target -Recurse -Force
    & $newDirectory $target 'source'
    & $newDirectory $desiredTemplate 'desired'
    $sidecars = Get-InstallExactPathSidecarPaths -Path $target -DesiredIdentity $desiredIdentity
    Move-Item -LiteralPath $target -Destination $sidecars.Old
    Move-Item -LiteralPath $desiredTemplate -Destination $sidecars.Ready
    [void](Invoke-InstallExactPathTransition -Path $target -SourceIdentity $sourceIdentity -DesiredIdentity $desiredIdentity -RecoverOnly)
    if (-not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $target) -Right $desiredIdentity) -or
        (Test-Path -LiteralPath $sidecars.Ready) -or (Test-Path -LiteralPath $sidecars.Old)) { throw 'ready+old did not converge' }

    Remove-Item -LiteralPath $target -Recurse -Force
    & $newDirectory $target 'desired'
    & $newDirectory $sidecars.Old 'source'
    [void](Invoke-InstallExactPathTransition -Path $target -SourceIdentity $sourceIdentity -DesiredIdentity $desiredIdentity -RecoverOnly)
    if (Test-Path -LiteralPath $sidecars.Old) { throw 'desired+old did not detach old' }

    Remove-Item -LiteralPath $target -Recurse -Force
    & $newDirectory $target 'source'
    $stageFailed = $false
    try {
        [void](Invoke-InstallExactPathTransition `
            -Path $target `
            -SourceIdentity $sourceIdentity `
            -DesiredIdentity $desiredIdentity `
            -MaterializeDesired { param($BuildPath) & $newDirectory $BuildPath 'wrong' })
    } catch {
        $stageFailed = $true
    }
    $sidecars = Get-InstallExactPathSidecarPaths -Path $target -DesiredIdentity $desiredIdentity
    if (-not $stageFailed -or
        -not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $target) -Right $sourceIdentity) -or
        (Test-Path -LiteralPath $sidecars.Ready) -or (Test-Path -LiteralPath $sidecars.Old)) { throw 'failed stage changed target or exposed a deterministic sidecar' }

    $crossTarget = Join-Path $transitionRoot 'cross-target'
    & $newDirectory $crossTarget 'directory-source'
    $crossSourceIdentity = Get-InstallManagedPathIdentity -Path $crossTarget
    $crossFileContent = 'file-desired'
    $crossFileIdentity = New-InstallExactFileIdentity -Content $crossFileContent
    [void](Invoke-InstallExactPathTransition `
        -Path $crossTarget `
        -SourceIdentity $crossSourceIdentity `
        -DesiredIdentity $crossFileIdentity `
        -MaterializeDesired { param($BuildPath) Write-InstallStateTextDurable -Path $BuildPath -Content $crossFileContent })
    if (-not (Test-Path -LiteralPath $crossTarget -PathType Leaf) -or
        (Get-Content -LiteralPath $crossTarget -Raw -Encoding utf8) -ne $crossFileContent) { throw 'directory-to-file transition failed' }
    [void](Invoke-InstallExactPathTransition `
        -Path $crossTarget `
        -SourceIdentity $crossFileIdentity `
        -DesiredIdentity $crossSourceIdentity `
        -MaterializeDesired { param($BuildPath) & $newDirectory $BuildPath 'directory-source' })
    if (-not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $crossTarget) -Right $crossSourceIdentity)) { throw 'file-to-directory transition failed' }

    $atomicSource = Join-Path $transitionRoot 'atomic-source.bin'
    $atomicTarget = Join-Path $transitionRoot 'atomic-target.bin'
    [System.IO.File]::WriteAllBytes($atomicSource, [byte[]](1,2,3,4))
    [System.IO.File]::WriteAllBytes($atomicTarget, [byte[]](9,8,7))
    Copy-InstallStateFileAtomic `
        -SourcePath $atomicSource `
        -Path $atomicTarget `
        -ExpectedCurrentIdentity (Get-InstallManagedPathIdentity -Path $atomicTarget) `
        -ExpectedDesiredIdentity (Get-InstallManagedPathIdentity -Path $atomicSource)
    if ((Get-FileHash -LiteralPath $atomicSource).Hash -ne (Get-FileHash -LiteralPath $atomicTarget).Hash) { throw 'same-type atomic file replace failed' }
    $atomicExpectedCurrent = Get-InstallManagedPathIdentity -Path $atomicTarget
    $atomicExpectedDesired = Get-InstallManagedPathIdentity -Path $atomicSource
    [System.IO.File]::WriteAllBytes($atomicTarget, [byte[]](7,7,7))
    $atomicTargetDriftRejected = $false
    try {
        Copy-InstallStateFileAtomic -SourcePath $atomicSource -Path $atomicTarget -ExpectedCurrentIdentity $atomicExpectedCurrent -ExpectedDesiredIdentity $atomicExpectedDesired
    } catch {
        $atomicTargetDriftRejected = $true
    }
    if (-not $atomicTargetDriftRejected -or [System.IO.File]::ReadAllBytes($atomicTarget)[0] -ne 7) { throw 'atomic file target drift was overwritten' }
    $atomicCurrentAfterDrift = Get-InstallManagedPathIdentity -Path $atomicTarget
    [System.IO.File]::WriteAllBytes($atomicSource, [byte[]](6,6,6))
    $atomicSourceDriftRejected = $false
    try {
        Copy-InstallStateFileAtomic -SourcePath $atomicSource -Path $atomicTarget -ExpectedCurrentIdentity $atomicCurrentAfterDrift -ExpectedDesiredIdentity $atomicExpectedDesired
    } catch {
        $atomicSourceDriftRejected = $true
    }
    if (-not $atomicSourceDriftRejected -or [System.IO.File]::ReadAllBytes($atomicTarget)[0] -ne 7) { throw 'atomic file source drift was published' }

    $atomicTextTarget = Join-Path $transitionRoot 'atomic-text.txt'
    [System.IO.File]::WriteAllText($atomicTextTarget, 'expected', (New-Object System.Text.UTF8Encoding($false)))
    $atomicTextExpected = Get-InstallManagedPathIdentity -Path $atomicTextTarget
    [System.IO.File]::WriteAllText($atomicTextTarget, 'user-drift', (New-Object System.Text.UTF8Encoding($false)))
    $atomicTextDriftRejected = $false
    try {
        Write-InstallStateTextAtomic -Path $atomicTextTarget -Content 'managed' -ExpectedCurrentDigest ([string]$atomicTextExpected.sha256)
    } catch {
        $atomicTextDriftRejected = $true
    }
    if (-not $atomicTextDriftRejected -or (Get-Content -LiteralPath $atomicTextTarget -Raw -Encoding utf8) -ne 'user-drift') { throw 'atomic text target drift was overwritten' }
    $atomicTextLinkTarget = Join-Path $transitionRoot 'atomic-text-link-target.txt'
    [System.IO.File]::WriteAllText($atomicTextLinkTarget, 'expected', (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $atomicTextTarget -Force
    try {
        New-Item -ItemType SymbolicLink -Path $atomicTextTarget -Target $atomicTextLinkTarget -ErrorAction Stop | Out-Null
        $atomicTextLinkRejected = $false
        try {
            Write-InstallStateTextAtomic -Path $atomicTextTarget -Content 'managed' -ExpectedCurrentDigest ([string]$atomicTextExpected.sha256)
        } catch {
            $atomicTextLinkRejected = $true
        }
        $atomicTextLink = Get-Item -LiteralPath $atomicTextTarget -Force
        if (-not $atomicTextLinkRejected -or -not [bool]($atomicTextLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or (Get-Content -LiteralPath $atomicTextLinkTarget -Raw -Encoding utf8) -ne 'expected') { throw 'atomic text accepted a same-content symbolic-link drift' }
    } catch [System.UnauthorizedAccessException] {
        # Symlink privilege is optional; exact identity validation remains covered by production-source review.
    }

    $deleteCutTarget = Join-Path $transitionRoot 'delete-cut.json'
    [System.IO.File]::WriteAllText($deleteCutTarget, 'registry-preimage', (New-Object System.Text.UTF8Encoding($false)))
    $deleteCutSource = Get-InstallManagedPathIdentity -Path $deleteCutTarget
    $deleteCutDesired = New-InstallExactMissingIdentity
    $deleteCutSidecars = Get-InstallExactPathSidecarPaths -Path $deleteCutTarget -DesiredIdentity $deleteCutDesired
    Move-Item -LiteralPath $deleteCutTarget -Destination $deleteCutSidecars.Old
    $deleteCutLock = [System.IO.File]::Open($deleteCutSidecars.Old, 'Open', 'Read', 'ReadWrite')
    try {
        $deleteCleanupBlocked = $false
        try {
            [void](Invoke-InstallExactPathTransition -Path $deleteCutTarget -SourceIdentity $deleteCutSource -DesiredIdentity $deleteCutDesired -RecoverOnly)
        } catch {
            $deleteCleanupBlocked = $true
        }
        if (-not $deleteCleanupBlocked -or -not (Test-Path -LiteralPath $deleteCutSidecars.Old) -or (Test-Path -LiteralPath $deleteCutTarget)) { throw 'blocked delete cleanup lost its recoverable old sidecar' }
    } finally {
        $deleteCutLock.Dispose()
    }
    [void](Invoke-InstallExactPathTransition -Path $deleteCutTarget -SourceIdentity $deleteCutSource -DesiredIdentity $deleteCutDesired -RecoverOnly)
    if ((Test-Path -LiteralPath $deleteCutTarget) -or (Test-Path -LiteralPath $deleteCutSidecars.Old)) { throw 'delete cleanup retry did not converge' }

    $treeLinkTarget = Join-Path $transitionRoot 'tree-link-target'
    $treeSource = Join-Path $transitionRoot 'tree-source'
    $treeCopy = Join-Path $transitionRoot 'tree-copy'
    New-Item -ItemType Directory -Path $treeLinkTarget,$treeSource -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $treeLinkTarget 'sentinel.txt'), 'keep')
    New-Item -ItemType Junction -Path (Join-Path $treeSource 'nested-link') -Target $treeLinkTarget | Out-Null
    $treeIdentity = Get-InstallManagedPathIdentity -Path $treeSource
    Copy-InstallExactDirectory -SourcePath $treeSource -Path $treeCopy
    $copiedLink = Get-Item -LiteralPath (Join-Path $treeCopy 'nested-link') -Force
    if (-not [bool]($copiedLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
        -not (Test-InstallExactIdentityEqual -Left $treeIdentity -Right (Get-InstallManagedPathIdentity -Path $treeCopy))) { throw 'exact directory copy dereferenced a nested link' }
    $treeLive = Join-Path $transitionRoot 'tree-live'
    & $newDirectory $treeLive 'installed-postimage'
    [void](Invoke-InstallExactPathTransition `
        -Path $treeLive `
        -SourceIdentity (Get-InstallManagedPathIdentity -Path $treeLive) `
        -DesiredIdentity $treeIdentity `
        -MaterializeDesired { param($BuildPath) Copy-InstallExactDirectory -SourcePath $treeCopy -Path $BuildPath })
    $restoredNestedLink = Get-Item -LiteralPath (Join-Path $treeLive 'nested-link') -Force
    if (-not [bool]($restoredNestedLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
        -not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $treeLive) -Right $treeIdentity)) { throw 'exact directory restore lost nested link topology' }
    $internalTree = Join-Path $transitionRoot 'internal-junction-tree'
    $internalTreeCopy = Join-Path $transitionRoot 'internal-junction-copy'
    New-Item -ItemType Directory -Path (Join-Path $internalTree 'real') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $internalTree 'internal-link') -Target (Join-Path $internalTree 'real') | Out-Null
    $internalJunctionRejected = $false
    try {
        Copy-InstallExactDirectory -SourcePath $internalTree -Path $internalTreeCopy
    } catch {
        $internalJunctionRejected = $true
    }
    $internalSourceLink = Get-Item -LiteralPath (Join-Path $internalTree 'internal-link') -Force
    if (-not $internalJunctionRejected -or -not [bool]($internalSourceLink.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { throw 'tree-internal junction was copied into a non-relocatable backup' }
    $relativeTree = Join-Path $transitionRoot 'relative-tree'
    $relativeTreeCopy = Join-Path $transitionRoot 'relative-tree-copy'
    New-Item -ItemType Directory -Path (Join-Path $relativeTree 'relative-target') -Force | Out-Null
    try {
        New-Item -ItemType SymbolicLink -Path (Join-Path $relativeTree 'relative-link') -Target 'relative-target' -ErrorAction Stop | Out-Null
        Copy-InstallExactDirectory -SourcePath $relativeTree -Path $relativeTreeCopy
        $relativeCopiedLink = Get-Item -LiteralPath (Join-Path $relativeTreeCopy 'relative-link') -Force
        if ([string]$relativeCopiedLink.Target -ne 'relative-target') { throw 'relative symbolic link target was rewritten' }
    } catch [System.UnauthorizedAccessException] {
        # Symlink privilege is optional on Windows; absolute junction coverage above remains mandatory.
    }

    $discardOrphan = Join-Path $transitionRoot ('.dev-harness-exact-' + [guid]::NewGuid().ToString('N') + '.discard')
    & $newDirectory $discardOrphan 'partial'
    if (Invoke-InstallExactPathTransition -Path $target -SourceIdentity $sourceIdentity -DesiredIdentity $desiredIdentity -RecoverOnly) { throw 'orphan discard was recognized as pending' }
    if (-not (Test-Path -LiteralPath $discardOrphan)) { throw 'orphan discard was claimed' }

    $missingIdentity = New-InstallExactMissingIdentity
    [void](Invoke-InstallExactPathTransition -Path $target -SourceIdentity $sourceIdentity -DesiredIdentity $missingIdentity)
    if ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath (Get-InstallExactPathSidecarPaths -Path $target -DesiredIdentity $missingIdentity).Old)) { throw 'desired missing did not converge' }

    $driftTarget = Join-Path $transitionRoot 'drift-target'
    & $newDirectory $driftTarget 'source'
    $driftSidecars = Get-InstallExactPathSidecarPaths -Path $driftTarget -DesiredIdentity $desiredIdentity
    & $newDirectory $driftSidecars.Ready 'wrong'
    $driftRejected = $false
    try {
        [void](Invoke-InstallExactPathTransition -Path $driftTarget -SourceIdentity $sourceIdentity -DesiredIdentity $desiredIdentity -RecoverOnly)
    } catch {
        $driftRejected = $true
    }
    if (-not $driftRejected -or
        -not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $driftTarget) -Right $sourceIdentity)) { throw 'drifted deterministic ready was not rejected before mutation' }

    $dualTarget = Join-Path $transitionRoot 'dual-target'
    $dualRecord = [ordered]@{
        path = $dualTarget
        existed = $false
        backup_path = $null
        item_type = 'missing'
        link_type = $null
        link_target = $null
        expected_postimage = $desiredIdentity
    }
    $dualInstallSidecars = Get-InstallExactPathSidecarPaths -Path $dualTarget -DesiredIdentity $desiredIdentity
    $dualRestoreSidecars = Get-InstallExactPathSidecarPaths -Path $dualTarget -DesiredIdentity $missingIdentity
    & $newDirectory $dualInstallSidecars.Ready 'desired'
    & $newDirectory $dualRestoreSidecars.Old 'desired'
    $dualRejected = $false
    try {
        Repair-InstallRestorePlanTransitions -Plan @([pscustomobject]@{ Record = $dualRecord }) -FailedInstall
    } catch {
        $dualRejected = $true
    }
    if (-not $dualRejected -or (Test-Path -LiteralPath $dualTarget) -or
        -not (Test-Path -LiteralPath $dualInstallSidecars.Ready) -or
        -not (Test-Path -LiteralPath $dualRestoreSidecars.Old)) { throw 'dual install/restore sidecars did not fail closed before mutation' }

    $preflightTargetA = Join-Path $transitionRoot 'preflight-a'
    $preflightTargetB = Join-Path $transitionRoot 'preflight-b'
    $preflightRecordA = [ordered]@{ path = $preflightTargetA; existed = $false; backup_path = $null; item_type = 'missing'; link_type = $null; link_target = $null; expected_postimage = $desiredIdentity }
    $preflightRecordB = [ordered]@{ path = $preflightTargetB; existed = $false; backup_path = $null; item_type = 'missing'; link_type = $null; link_target = $null; expected_postimage = $desiredIdentity }
    $preflightSidecarsA = Get-InstallExactPathSidecarPaths -Path $preflightTargetA -DesiredIdentity $desiredIdentity
    $preflightSidecarsB = Get-InstallExactPathSidecarPaths -Path $preflightTargetB -DesiredIdentity $desiredIdentity
    & $newDirectory $preflightSidecarsA.Ready 'desired'
    & $newDirectory $preflightSidecarsB.Ready 'wrong'
    $preflightRejected = $false
    try {
        Repair-InstallRestorePlanTransitions `
            -Plan @([pscustomobject]@{ Record = $preflightRecordA }, [pscustomobject]@{ Record = $preflightRecordB }) `
            -FailedInstall
    } catch {
        $preflightRejected = $true
    }
    if (-not $preflightRejected -or
        (Test-Path -LiteralPath $preflightTargetA) -or
        -not (Test-Path -LiteralPath $preflightSidecarsA.Ready)) { throw 'multi-record repair mutated an earlier action before later drift rejection' }

    $chainTarget = Join-Path $transitionRoot 'chain-target'
    $chainP0 = Join-Path $transitionRoot 'chain-p0'
    $chainP1 = Join-Path $transitionRoot 'chain-p1'
    & $newDirectory $chainP0 'p0'
    & $newDirectory $chainP1 'p1'
    & $newDirectory $chainTarget 'p2'
    $chainP0Identity = Get-InstallManagedPathIdentity -Path $chainP0
    $chainP1Identity = Get-InstallManagedPathIdentity -Path $chainP1
    $chainP2Identity = Get-InstallManagedPathIdentity -Path $chainTarget
    $chainR2 = [ordered]@{ path = $chainTarget; existed = $true; backup_path = $chainP1; item_type = 'directory'; link_type = $null; link_target = $null; expected_postimage = $chainP2Identity }
    $chainR1 = [ordered]@{ path = $chainTarget; existed = $true; backup_path = $chainP0; item_type = 'directory'; link_type = $null; link_target = $null; expected_postimage = $chainP1Identity }
    $chainSidecars = Get-InstallExactPathSidecarPaths -Path $chainTarget -DesiredIdentity $chainP1Identity
    & $newDirectory $chainSidecars.Ready 'p1'
    Repair-InstallRestorePlanTransitions `
        -Plan @([pscustomobject]@{ Record = $chainR2 }, [pscustomobject]@{ Record = $chainR1 }) `
        -ValidateProjectedPlan { param($Projected) if (-not (Test-InstallExactIdentityEqual -Left $Projected[$chainTarget] -Right $chainP1Identity)) { throw 'chain projection mismatch' } }
    if (-not (Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $chainTarget) -Right $chainP1Identity) -or
        (Test-Path -LiteralPath $chainSidecars.Ready)) { throw 'same-target chain sidecar key was not claimed by its first restore action' }

    $noOpSidecars = Get-InstallExactPathSidecarPaths -Path $chainTarget -DesiredIdentity $chainP1Identity
    & $newDirectory $noOpSidecars.Ready 'p1'
    $chainNoOp = [ordered]@{ path = $chainTarget; existed = $true; backup_path = $chainP1; item_type = 'directory'; link_type = $null; link_target = $null; expected_postimage = $chainP1Identity }
    $noOpRejected = $false
    try {
        Repair-InstallRestorePlanTransitions -Plan @([pscustomobject]@{ Record = $chainNoOp }) -FailedInstall
    } catch {
        $noOpRejected = $true
    }
    if (-not $noOpRejected -or -not (Test-Path -LiteralPath $noOpSidecars.Ready)) { throw 'no-op record sidecar was ignored or mutated' }

    $checks.Add('exact-path transition covers crash cuts, cross-type/file identities, nested links, drift, dual keys, projected preflight, same-target chain claims, and no-op sidecars') | Out-Null
} catch {
    $failures.Add("exact-path transition regression failed: $($_.Exception.Message)") | Out-Null
}

$snapshotBarrierRoot = Join-Path $scratchRoot 'semantic-install-snapshot-barrier'
$snapshotBarrierCases = @(
    [pscustomobject]@{
        Name = 'gitignore'
        Target = { param($UserProfile, $WorkspaceRoot) Join-Path $WorkspaceRoot '.gitignore' }
        Initial = "initial-A/`n"
        Drift = "external-B/`n"
        Anchor = '    Backup-IfNeeded -Path $gitIgnorePath -ExpectedPostimage $expectedPostimage'
    }
    [pscustomobject]@{
        Name = 'claude-settings'
        Target = { param($UserProfile, $WorkspaceRoot) Join-Path $UserProfile '.claude\settings.json' }
        Initial = '{"model":"A"}'
        Drift = '{"external":"B-claude"}'
        Anchor = '    Backup-IfNeeded -Path $claudeSettingsPath -ExpectedPostimage $claudeSettingsExpectedPostimage'
    }
    [pscustomobject]@{
        Name = 'codex-settings'
        Target = { param($UserProfile, $WorkspaceRoot) Join-Path $UserProfile '.codex\.claude\settings.local.json' }
        Initial = '{"model":"A"}'
        Drift = '{"external":"B-codex"}'
        Anchor = '    Write-ManagedInstallText -Path $codexSettingsPath -Content $codexSettingsMerge.Content -RecordBackup -ExpectedCurrentIdentity $codexSettingsMerge.Identity'
    }
)
$snapshotBarrierFailures = New-Object System.Collections.Generic.List[string]
foreach ($case in $snapshotBarrierCases) {
    $caseRoot = Join-Path $snapshotBarrierRoot $case.Name
    $userProfile = Join-Path $caseRoot 'user'
    $workspaceRoot = Join-Path $caseRoot 'workspace'
    $fixtureRoot = Join-Path $caseRoot 'fixture'
    $targetPath = & $case.Target $userProfile $workspaceRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath),$workspaceRoot -Force | Out-Null
    [System.IO.File]::WriteAllText($targetPath, $case.Initial, (New-Object System.Text.UTF8Encoding($false)))
    Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $fixtureRoot -RelativePath 'scripts\install-transaction-common.ps1'
    foreach ($moduleName in @('Harness.Hashing','Harness.Path','Harness.CanonicalJson','Harness.Distribution')) {
        Copy-RepoPathToFixture -SourceRoot $RepoRoot -FixtureRoot $fixtureRoot -RelativePath "scripts\lib\$moduleName.psm1"
    }
    $instrumentedSource = $installSource
    if (@($instrumentedSource.Split([string[]]@($case.Anchor), [System.StringSplitOptions]::None)).Count -ne 2) {
        $snapshotBarrierFailures.Add("$($case.Name): barrier anchor is not unique") | Out-Null
        continue
    }
    $escapedTarget = $targetPath.Replace("'", "''")
    $escapedDrift = $case.Drift.Replace("'", "''")
    $barrier = "    [System.IO.File]::WriteAllText('$escapedTarget', '$escapedDrift', (New-Object System.Text.UTF8Encoding(`$false)))"
    $instrumentedSource = $instrumentedSource.Replace($case.Anchor, ($barrier + [Environment]::NewLine + $case.Anchor))
    $instrumentedPath = Join-Path $fixtureRoot 'install.ps1'
    [System.IO.File]::WriteAllText($instrumentedPath, $instrumentedSource, (New-Object System.Text.UTF8Encoding($false)))
    $result = Invoke-RepoScriptProcess `
        -UserProfile $userProfile `
        -ScriptPath $instrumentedPath `
        -Arguments @('-WorkspaceRoot',$workspaceRoot,'-RepoRoot',$RepoRoot)
    $current = if (Test-Path -LiteralPath $targetPath -PathType Leaf) { Get-Content -LiteralPath $targetPath -Raw -Encoding utf8 } else { $null }
    if ($result.ExitCode -eq 0 -or $current -cne $case.Drift) {
        $snapshotBarrierFailures.Add(("{0}: exit={1}, preserved={2}, output={3}" -f $case.Name,$result.ExitCode,($current -ceq $case.Drift),($result.Output -replace '\r?\n',' | '))) | Out-Null
    }
}
if ($snapshotBarrierFailures.Count -eq 0) {
    $checks.Add('semantic install snapshot barrier rejects post-merge drift for gitignore, Claude settings, and Codex settings while preserving exact B') | Out-Null
} else {
    $failures.Add('semantic install snapshot CAS regression failed: ' + ($snapshotBarrierFailures -join '; ')) | Out-Null
}

$emptyRegistryRoot = Join-Path $scratchRoot 'existing-empty-registry-is-not-fresh-state'
$emptyRegistryUser = Join-Path $emptyRegistryRoot 'user'
$emptyRegistryWorkspace = Join-Path $emptyRegistryRoot 'workspace'
$emptyRegistryPath = Join-Path $emptyRegistryUser '.dev-harness\install-registry.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $emptyRegistryPath),$emptyRegistryWorkspace -Force | Out-Null
[System.IO.File]::WriteAllText($emptyRegistryPath, '{}', (New-Object System.Text.UTF8Encoding($false)))
$emptyRegistryHash = (Get-FileHash -LiteralPath $emptyRegistryPath -Algorithm SHA256).Hash
$emptyRegistryProcess = Start-RepoProcess -UserProfile $emptyRegistryUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$emptyRegistryWorkspace,'-RepoRoot',$RepoRoot)
[void]$emptyRegistryProcess.Process.WaitForExit(30000)
if ($emptyRegistryProcess.Process.HasExited -and
    $emptyRegistryProcess.Process.ExitCode -ne 0 -and
    (Get-FileHash -LiteralPath $emptyRegistryPath -Algorithm SHA256).Hash -eq $emptyRegistryHash -and
    -not (Test-Path -LiteralPath (Join-Path $emptyRegistryUser '.dev-harness\backups')) -and
    -not (Test-Path -LiteralPath (Join-Path $emptyRegistryWorkspace 'AGENTS.md')) -and
    -not (Test-Path -LiteralPath (Join-Path $emptyRegistryUser '.claude'))) {
    $checks.Add('install rejects an existing empty registry instead of silently creating fresh ownership state') | Out-Null
} else {
    $failures.Add('an existing empty registry must fail closed before backup, workspace, or user-global mutation') | Out-Null
}
$emptyRegistryProcess.Process.Dispose()

$stateReparseRoot = Join-Path $scratchRoot 'install-state-reparse-is-write-free'
$stateReparseUser = Join-Path $stateReparseRoot 'user'
$stateReparseWorkspace = Join-Path $stateReparseRoot 'workspace'
$stateReparseVictim = Join-Path $stateReparseRoot 'victim'
$stateReparsePath = Join-Path $stateReparseUser '.dev-harness'
New-Item -ItemType Directory -Path $stateReparseUser,$stateReparseWorkspace,$stateReparseVictim -Force | Out-Null
New-Item -ItemType Junction -Path $stateReparsePath -Target $stateReparseVictim | Out-Null
$stateReparseProcess = Start-RepoProcess -UserProfile $stateReparseUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$stateReparseWorkspace,'-RepoRoot',$RepoRoot)
[void]$stateReparseProcess.Process.WaitForExit(30000)
$stateReparseVictimWriteCount = @(Get-ChildItem -LiteralPath $stateReparseVictim -Force).Count
if ($stateReparseProcess.Process.HasExited -and
    $stateReparseProcess.Process.ExitCode -ne 0 -and
    $stateReparseVictimWriteCount -eq 0 -and
    -not (Test-Path -LiteralPath (Join-Path $stateReparseWorkspace 'AGENTS.md')) -and
    -not (Test-Path -LiteralPath (Join-Path $stateReparseUser '.claude'))) {
    $checks.Add('install rejects a reparse-backed .dev-harness state root before its first state or managed write') | Out-Null
} else {
    $failures.Add('install state, journal, and backup paths must not traverse a reparse point') | Out-Null
}
$stateReparseProcess.Process.Dispose()
Remove-Item -LiteralPath $stateReparsePath -Force -ErrorAction SilentlyContinue

$nestedVaultReparseRoot = Join-Path $scratchRoot 'core-entry-nested-reparse-is-write-free'
$nestedVaultReparseUser = Join-Path $nestedVaultReparseRoot 'user'
$nestedVaultReparseWorkspace = Join-Path $nestedVaultReparseRoot 'workspace'
$nestedVaultReparseVictim = Join-Path $nestedVaultReparseRoot 'victim'
$nestedVaultEntryParent = Join-Path $nestedVaultReparseWorkspace '.assistant'
$nestedVaultEntryPath = Join-Path $nestedVaultEntryParent 'entry'
New-Item -ItemType Directory -Path $nestedVaultReparseUser,$nestedVaultEntryParent,$nestedVaultReparseVictim -Force | Out-Null
$nestedVaultVictimFile = Join-Path $nestedVaultReparseVictim 'task.ps1'
[System.IO.File]::WriteAllText($nestedVaultVictimFile,"victim sentinel`n",(New-Object System.Text.UTF8Encoding($false)))
$nestedVaultVictimHash = (Get-FileHash -LiteralPath $nestedVaultVictimFile -Algorithm SHA256).Hash
New-Item -ItemType Junction -Path $nestedVaultEntryPath -Target $nestedVaultReparseVictim | Out-Null
$nestedVaultReparseProcess = Start-RepoProcess -UserProfile $nestedVaultReparseUser -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$nestedVaultReparseWorkspace,'-RepoRoot',$RepoRoot,'-Preset','core')
[void]$nestedVaultReparseProcess.Process.WaitForExit(30000)
$nestedVaultVictimItems = @(Get-ChildItem -LiteralPath $nestedVaultReparseVictim -Force)
if ($nestedVaultReparseProcess.Process.HasExited -and
    $nestedVaultReparseProcess.Process.ExitCode -ne 0 -and
    $nestedVaultVictimItems.Count -eq 1 -and
    (Get-FileHash -LiteralPath $nestedVaultVictimFile -Algorithm SHA256).Hash -eq $nestedVaultVictimHash -and
    -not (Test-Path -LiteralPath (Join-Path $nestedVaultReparseWorkspace '.assistant\entry\AGENTS.md')) -and
    -not (Test-Path -LiteralPath (Join-Path $nestedVaultReparseWorkspace 'AGENTS.md')) -and
    -not (Test-Path -LiteralPath (Join-Path $nestedVaultReparseUser '.dev-harness')) -and
    -not (Test-Path -LiteralPath (Join-Path $nestedVaultReparseUser '.claude'))) {
    $checks.Add('core install rejects a nested current entry junction without changing the external victim or retaining partial state') | Out-Null
} else {
    $failures.Add('current core task entry must use the managed reparse-safe transaction path') | Out-Null
}
$nestedVaultReparseProcess.Process.Dispose()
Remove-Item -LiteralPath $nestedVaultEntryPath -Force -ErrorAction SilentlyContinue

$vanishedPointerUser = Join-Path $scratchRoot 'vanished-pointer-user'
$vanishedPointerPath = Join-Path $scratchRoot 'vanished-pointer\active-install.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $vanishedPointerPath),$vanishedPointerUser -Force | Out-Null
[System.IO.File]::WriteAllText($vanishedPointerPath, '{"legacy":1}', (New-Object System.Text.UTF8Encoding($false)))
$vanishedPointerDigest = Get-InstallStateFileDigest -Path $vanishedPointerPath
Remove-Item -LiteralPath $vanishedPointerPath -Force
Set-LegacyPointerMigrationMarked -UserProfile $vanishedPointerUser -PointerPath $vanishedPointerPath -ExpectedPointerDigest $vanishedPointerDigest
[System.IO.File]::WriteAllText($vanishedPointerPath, '{"legacy":2}', (New-Object System.Text.UTF8Encoding($false)))
if (Test-LegacyPointerMigrationMarked -UserProfile $vanishedPointerUser -PointerPath $vanishedPointerPath) {
    $checks.Add('one-shot legacy marker survives pointer disappearance and later recreation') | Out-Null
} else {
    $failures.Add('imported legacy pointer disappearance must still leave a permanent one-shot marker') | Out-Null
}

$overlapCaseRoot = Join-Path $scratchRoot 'workspace-inside-managed-user-global-root'
$overlapUserProfile = Join-Path $overlapCaseRoot 'user'
$overlapWorkspace = Join-Path $overlapUserProfile '.claude\project'
New-Item -ItemType Directory -Path $overlapUserProfile -Force | Out-Null
$overlapProcess = Start-RepoProcess -UserProfile $overlapUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$overlapWorkspace,'-RepoRoot',$RepoRoot)
[void]$overlapProcess.Process.WaitForExit(30000)
if ($overlapProcess.Process.HasExited -and
    $overlapProcess.Process.ExitCode -ne 0 -and
    -not (Test-Path -LiteralPath (Join-Path $overlapUserProfile '.dev-harness')) -and
    -not (Test-Path -LiteralPath $overlapWorkspace)) {
    $checks.Add('install rejects a workspace nested inside a managed user-global root before mutation') | Out-Null
} else {
    $failures.Add('workspace/user-global overlap must fail before install state or workspace mutation') | Out-Null
}
$overlapProcess.Process.Dispose()

$junctionCaseRoot = Join-Path $scratchRoot 'junction-workspace-overlap'
$junctionUserProfile = Join-Path $junctionCaseRoot 'user'
$junctionTarget = Join-Path $junctionUserProfile '.claude\project'
$junctionWorkspace = Join-Path $junctionCaseRoot 'workspace-link'
New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
New-Item -ItemType Junction -Path $junctionWorkspace -Target $junctionTarget | Out-Null
$junctionProcess = Start-RepoProcess -UserProfile $junctionUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$junctionWorkspace,'-RepoRoot',$RepoRoot)
[void]$junctionProcess.Process.WaitForExit(30000)
if ($junctionProcess.Process.HasExited -and
    $junctionProcess.Process.ExitCode -ne 0 -and
    -not (Test-Path -LiteralPath (Join-Path $junctionUserProfile '.dev-harness')) -and
    -not (Test-Path -LiteralPath (Join-Path $junctionTarget 'AGENTS.md'))) {
    $checks.Add('install rejects a junction workspace that physically enters a managed user-global root') | Out-Null
} else {
    $failures.Add('junction workspace overlap must fail before install state or redirected target mutation') | Out-Null
}
$junctionProcess.Process.Dispose()

$concurrentCaseRoot = Join-Path $scratchRoot 'concurrent-installs-share-one-transaction-lock'
$concurrentUserProfile = Join-Path $concurrentCaseRoot 'user'
$concurrentWorkspaceA = Join-Path $concurrentCaseRoot 'workspace-a'
$concurrentWorkspaceB = Join-Path $concurrentCaseRoot 'workspace-b'
New-Item -ItemType Directory -Path $concurrentUserProfile,$concurrentWorkspaceA,$concurrentWorkspaceB -Force | Out-Null
$heldInstallMutex = Enter-InstallTransactionMutex -UserProfile $concurrentUserProfile
$concurrentProcesses = @()
try {
    $concurrentProcesses = @(
        Start-RepoProcess -UserProfile $concurrentUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$concurrentWorkspaceA,'-RepoRoot',$RepoRoot)
        Start-RepoProcess -UserProfile $concurrentUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$concurrentWorkspaceB,'-RepoRoot',$RepoRoot)
    )
    $exitedWhileLocked = @($concurrentProcesses | Where-Object { $_.Process.WaitForExit(500) }).Count
    $concurrentRegistryPath = Join-Path $concurrentUserProfile '.dev-harness\install-registry.json'
    if ($exitedWhileLocked -eq 0 -and
        -not (Test-Path -LiteralPath $concurrentRegistryPath) -and
        -not (Test-Path -LiteralPath (Join-Path $concurrentWorkspaceA 'AGENTS.md')) -and
        -not (Test-Path -LiteralPath (Join-Path $concurrentWorkspaceB 'AGENTS.md'))) {
        $checks.Add('concurrent installs wait for the USERPROFILE transaction mutex before any workspace or registry mutation') | Out-Null
    } else {
        $failures.Add('concurrent installs should remain write-free while the USERPROFILE transaction mutex is held') | Out-Null
    }
} finally {
    Exit-InstallTransactionMutex -Mutex $heldInstallMutex
}

foreach ($child in $concurrentProcesses) {
    [void]$child.Process.WaitForExit(60000)
}
$concurrentExitCodes = @($concurrentProcesses | ForEach-Object { $_.Process.ExitCode })
$concurrentRegistry = if (Test-Path -LiteralPath $concurrentRegistryPath) {
    Get-Content -LiteralPath $concurrentRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
} else {
    $null
}
$concurrentWorkspaceCount = if ($null -ne $concurrentRegistry) { @($concurrentRegistry.workspaces.PSObject.Properties).Count } else { 0 }
if (@($concurrentExitCodes | Where-Object { $_ -eq 0 }).Count -eq 2 -and $concurrentWorkspaceCount -eq 2) {
    $checks.Add('two concurrent installs preserve both workspace registry entries') | Out-Null
} else {
    $concurrentErrors = @($concurrentProcesses | ForEach-Object { $_.StdErr.Result }) -join ' | '
    $failures.Add(("concurrent installs should both succeed and preserve two registry entries, exits={0}, workspaces={1}, errors={2}" -f ($concurrentExitCodes -join ','),$concurrentWorkspaceCount,$concurrentErrors)) | Out-Null
}
foreach ($child in $concurrentProcesses) {
    $child.Process.Dispose()
}

$timeoutCaseRoot = Join-Path $scratchRoot 'install-timeout-is-write-free'
$timeoutUserProfile = Join-Path $timeoutCaseRoot 'user'
$timeoutWorkspace = Join-Path $timeoutCaseRoot 'workspace'
New-Item -ItemType Directory -Path $timeoutUserProfile,$timeoutWorkspace -Force | Out-Null
$heldTimeoutMutex = Enter-InstallTransactionMutex -UserProfile $timeoutUserProfile
$timeoutProcess = $null
try {
    $timeoutProcess = Start-RepoProcess -UserProfile $timeoutUserProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @('-WorkspaceRoot',$timeoutWorkspace,'-RepoRoot',$RepoRoot)
[void]$timeoutProcess.Process.WaitForExit(20000)
    $timeoutRegistryPath = Join-Path $timeoutUserProfile '.dev-harness\install-registry.json'
    if ($timeoutProcess.Process.HasExited -and
        $timeoutProcess.Process.ExitCode -ne 0 -and
        -not (Test-Path -LiteralPath $timeoutRegistryPath) -and
        -not (Test-Path -LiteralPath (Join-Path $timeoutWorkspace 'AGENTS.md')) -and
        -not (Test-Path -LiteralPath (Join-Path $timeoutUserProfile '.claude'))) {
        $checks.Add('install transaction lock timeout fails closed without workspace, registry, or user-global writes') | Out-Null
    } else {
        $failures.Add('timed-out install should fail before any workspace, registry, or user-global mutation') | Out-Null
    }
} finally {
    Exit-InstallTransactionMutex -Mutex $heldTimeoutMutex
}
if ($null -ne $timeoutProcess) {
    $timeoutProcess.Process.Dispose()
}

$legacyCaseRoot = Join-Path $scratchRoot 'real-legacy-rebaseline-stack'
$legacyRepoRoot = Join-Path $legacyCaseRoot 'repo'
$legacyUserProfile = Join-Path $legacyCaseRoot 'user'
$legacyWorkspace = Join-Path $legacyCaseRoot 'workspace'
$legacyForeignUserProfile = Join-Path $legacyCaseRoot 'foreign-user'
$legacyForeignWorkspace = Join-Path $legacyCaseRoot 'foreign-workspace'
New-Item -ItemType Directory -Path $legacyRepoRoot,$legacyUserProfile,$legacyWorkspace,$legacyForeignUserProfile,$legacyForeignWorkspace -Force | Out-Null
foreach ($fixtureSource in @('install.ps1','uninstall.ps1','scripts','skills','vault-template','agent-configs','runtime-hooks','modules','schemas','module-manifest-catalog.json')) {
    Copy-Item `
        -LiteralPath (Join-Path $RepoRoot $fixtureSource) `
        -Destination (Join-Path $legacyRepoRoot $fixtureSource) `
        -Recurse `
        -Force
}
$legacyHookTemplatePath = Join-Path $legacyRepoRoot 'agent-configs\claude\settings.local.shared.json.template'
$legacyPostToolSourcePath = Join-Path $legacyRepoRoot 'runtime-hooks\claude\posttooluse.js'
$currentHookTemplateRaw = Get-Content -LiteralPath $legacyHookTemplatePath -Raw -Encoding utf8
$legacyHookTemplate = $currentHookTemplateRaw | ConvertFrom-Json
$legacyHookTemplate | Add-Member -NotePropertyName PostToolUse -NotePropertyValue @(
    [ordered]@{
        matcher = 'Write|Edit|MultiEdit'
        hooks = @([ordered]@{ type = 'command'; command = 'node "{CLAUDE_HOME}\hooks-memory\posttooluse.js"'; timeout = 10 })
    }
) -Force
[System.IO.File]::WriteAllText(
    $legacyHookTemplatePath,
    ($legacyHookTemplate | ConvertTo-Json -Depth 20),
    (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText(
    $legacyPostToolSourcePath,
    'process.stdin.resume(); process.stdout.write("{}\n");',
    (New-Object System.Text.UTF8Encoding($false)))

$foreignSentinels = [ordered]@{
    (Join-Path $legacyForeignUserProfile '.claude\CLAUDE.md') = 'foreign claude sentinel'
    (Join-Path $legacyForeignUserProfile '.codex\AGENTS.md') = 'foreign codex sentinel'
    (Join-Path $legacyForeignWorkspace 'AGENTS.md') = 'foreign workspace sentinel'
    (Join-Path $legacyForeignWorkspace '.gitignore') = 'foreign gitignore sentinel'
}
foreach ($foreignSentinel in $foreignSentinels.GetEnumerator()) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $foreignSentinel.Key) -Force | Out-Null
    [System.IO.File]::WriteAllText($foreignSentinel.Key, $foreignSentinel.Value, (New-Object System.Text.UTF8Encoding($false)))
}
$global:LASTEXITCODE = 73
$foreignInstallResult = Invoke-RepoScript -UserProfile $legacyForeignUserProfile -ScriptPath (Join-Path $legacyRepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $legacyForeignWorkspace
    RepoRoot      = $legacyRepoRoot
    VaultProfile  = 'full'
}
$foreignInstallRestoredExitCode = Get-LastExitCodeOrZero
$global:LASTEXITCODE = 0
$foreignRegistryPath = Join-Path $legacyForeignUserProfile '.dev-harness\install-registry.json'
$foreignRegistry = Get-Content -LiteralPath $foreignRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
$foreignWorkspaceEntry = @($foreignRegistry.workspaces.PSObject.Properties | Select-Object -First 1)[0].Value
$foreignModernManifestPath = [string]@($foreignWorkspaceEntry.manifests)[-1]
$foreignModernManifest = Get-Content -LiteralPath $foreignModernManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
$foreignModernBackupRoot = [string]$foreignModernManifest.backup_root
$legacyPointerBackupRoot = Join-Path $legacyRepoRoot 'backups\legacy-pointer-foreign'
New-Item -ItemType Directory -Path (Split-Path -Parent $legacyPointerBackupRoot) -Force | Out-Null
Copy-Item -LiteralPath $foreignModernBackupRoot -Destination $legacyPointerBackupRoot -Recurse -Force
$legacyPointerManifestPath = Join-Path $legacyPointerBackupRoot 'install-manifest.json'
$legacyPointerManifest = Get-Content -LiteralPath $legacyPointerManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
$legacyPointerManifest.installed_at = '2026-01-01T00:00:00+00:00'
$foreignCodexHooksPath = Get-NormalizedPath -Path (Join-Path $legacyForeignUserProfile '.codex\hooks.json')
$foreignManagedConfigPath = Get-NormalizedPath -Path (Join-Path $legacyForeignUserProfile '.codex\managed_config.toml')
$foreignHookRecords = @($legacyPointerManifest.backups | Where-Object {
        (Get-NormalizedPath -Path $_.path) -eq $foreignCodexHooksPath
    })
$foreignManagedConfigRecords = @($legacyPointerManifest.backups | Where-Object {
        (Get-NormalizedPath -Path $_.path) -eq $foreignManagedConfigPath
    })
if ($foreignHookRecords.Count -ne 1 -or
    $foreignManagedConfigRecords.Count -ne 0 -or
    [bool]$foreignHookRecords[0].existed -or
    [string]$foreignHookRecords[0].item_type -ne 'missing') {
    throw 'foreign legacy pointer fixture requires one missing-state Codex hook record and no managed_config record'
}
$foreignHookRecords[0].path = $foreignManagedConfigPath
if (@($legacyPointerManifest.backups | Where-Object {
            (Get-NormalizedPath -Path $_.path) -eq $foreignCodexHooksPath
        }).Count -ne 0 -or
    @($legacyPointerManifest.backups | Where-Object {
            (Get-NormalizedPath -Path $_.path) -eq $foreignManagedConfigPath
        }).Count -ne 1) {
    throw 'foreign legacy pointer fixture did not replace its Codex hook record with managed_config'
}
$legacyPointerUserGlobalRecords = @($legacyPointerManifest.backups | Where-Object { $_.scope -eq 'user-global' } | Select-Object -First 6)
$legacyPointerWorkspaceRecords = @($legacyPointerManifest.backups | Where-Object { $_.scope -eq 'workspace' } | Select-Object -First 2)
if ($foreignInstallResult.ExitCode -ne 0 -or
    $foreignInstallRestoredExitCode -ne 73 -or
    $legacyPointerUserGlobalRecords.Count -ne 6 -or
    $legacyPointerWorkspaceRecords.Count -ne 2 -or
    @($legacyPointerUserGlobalRecords | Where-Object {
            (Get-NormalizedPath -Path $_.path) -eq $foreignManagedConfigPath
        }).Count -ne 1) {
    throw 'foreign legacy pointer fixture requires one successful install, exact LASTEXITCODE restoration, six global records, and two workspace records'
}
$checks.Add('Invoke-RepoScript restores the exact preexisting global LASTEXITCODE value') | Out-Null
$legacyPointerManifest.backup_root = $legacyPointerBackupRoot
$legacyPointerManifest.backups = @($legacyPointerUserGlobalRecords + $legacyPointerWorkspaceRecords)
foreach ($legacyPointerRecord in @($legacyPointerManifest.backups)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$legacyPointerRecord.backup_path)) {
        $pointerPayloadRelativePath = [System.IO.Path]::GetRelativePath($foreignModernBackupRoot, [string]$legacyPointerRecord.backup_path)
        $legacyPointerRecord.backup_path = Join-Path $legacyPointerBackupRoot $pointerPayloadRelativePath
    }
    foreach ($pointerRecordField in @('expected_postimage','backup_payload_sha256','scope','ownership')) {
        [void]$legacyPointerRecord.PSObject.Properties.Remove($pointerRecordField)
    }
}
foreach ($pointerManifestField in @('schema_version','postimage_identity_contract','transaction_status','backup_payload_integrity_contract','managed_backup_targets','registry_path','registry_preimage_sha256','requested_preset','effective_preset','preset_source','feature_ownership','user_profile','codex_hook_pwsh_executable','released_backup_targets','released_backup_manifest_paths')) {
    [void]$legacyPointerManifest.PSObject.Properties.Remove($pointerManifestField)
}
[System.IO.File]::WriteAllText(
    $legacyPointerManifestPath,
    ($legacyPointerManifest | ConvertTo-Json -Depth 100),
    (New-Object System.Text.UTF8Encoding($false)))
Remove-Item -LiteralPath $legacyForeignUserProfile,$legacyForeignWorkspace -Recurse -Force

$legacyWarmupResult = Invoke-RepoScript -UserProfile $legacyUserProfile -ScriptPath (Join-Path $legacyRepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $legacyWorkspace
    RepoRoot      = $legacyRepoRoot
    VaultProfile  = 'full'
}
$legacyEarliestExactPath = Join-Path $legacyWorkspace 'AGENTS.md'
$legacyEarliestExactContent = 'legacy earliest exact sentinel'
[System.IO.File]::WriteAllText($legacyEarliestExactPath, $legacyEarliestExactContent, (New-Object System.Text.UTF8Encoding($false)))
$legacyEarliestMissingPath = Join-Path $legacyWorkspace '.assistant\entry\task.ps1'
if (-not (Test-Path -LiteralPath $legacyEarliestMissingPath -PathType Leaf)) {
    throw 'legacy rebaseline fixture warm-up did not create its missing-state target'
}
Remove-Item -LiteralPath $legacyEarliestMissingPath -Force
$legacyLayerResults = @(1..3 | ForEach-Object {
        Invoke-RepoScript -UserProfile $legacyUserProfile -ScriptPath (Join-Path $legacyRepoRoot 'install.ps1') -Arguments @{
            WorkspaceRoot = $legacyWorkspace
            RepoRoot      = $legacyRepoRoot
            VaultProfile  = 'full'
        }
    })
$legacySeedResults = @($legacyWarmupResult) + @($legacyLayerResults)
$legacyRegistryPath = Join-Path $legacyUserProfile '.dev-harness\install-registry.json'
$legacyRegistry = Get-Content -LiteralPath $legacyRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
$legacyWorkspaceEntry = @($legacyRegistry.workspaces.PSObject.Properties | Select-Object -First 1)[0].Value
$legacyAllCurrentManifestPaths = @($legacyWorkspaceEntry.manifests)
if (@($legacySeedResults | Where-Object { $_.ExitCode -ne 0 }).Count -ne 0 -or $legacyAllCurrentManifestPaths.Count -ne 4) {
    throw 'legacy rebaseline fixture requires one warm-up plus three successful current-profile installs'
}
$legacyWarmupManifestPath = $legacyAllCurrentManifestPaths[0]
$legacyManifestPaths = @($legacyAllCurrentManifestPaths | Select-Object -Skip 1)
$legacyWorkspaceEntry.manifests = $legacyManifestPaths
$legacyRegistry.global_manifest_history = $legacyManifestPaths
$legacyCodexHooksPath = Get-NormalizedPath -Path (Join-Path $legacyUserProfile '.codex\hooks.json')
$legacyManagedConfigPath = Get-NormalizedPath -Path (Join-Path $legacyUserProfile '.codex\managed_config.toml')
$legacyManagedConfigBaselineContent = "# external Codex policy before Harness ownership`r`n[features]`r`nhooks = false`r`n"
$legacyManagedConfigContent = "# Managed by install.ps1`r`nallow_managed_hooks_only = true`r`n[features]`r`nhooks = true`r`n"
$legacyManagedConfigUserContent = "# user changed Codex policy after Harness release`r`n[features]`r`nhooks = false`r`n"
if (-not (Test-Path -LiteralPath $legacyCodexHooksPath -PathType Leaf) -or
    (Test-Path -LiteralPath $legacyManagedConfigPath)) {
    throw 'legacy rebaseline fixture requires one current Codex hooks file and no managed_config target before conversion'
}
Remove-Item -LiteralPath $legacyCodexHooksPath -Force
[System.IO.File]::WriteAllText(
    $legacyManagedConfigPath,
    $legacyManagedConfigContent,
    (New-Object System.Text.UTF8Encoding($false)))

$legacyManifestDocuments = @()
for ($manifestIndex = 0; $manifestIndex -lt $legacyManifestPaths.Count; $manifestIndex++) {
    $legacyManifest = Get-Content -LiteralPath $legacyManifestPaths[$manifestIndex] -Raw -Encoding utf8 | ConvertFrom-Json
    $legacyManifest.schema_version = 'install-manifest/v1.1'
    $legacyManifest.installed_at = ([datetimeoffset]'2026-01-01T00:00:01+00:00').AddSeconds($manifestIndex).ToString('o')
    $legacyHookRecords = @($legacyManifest.backups | Where-Object {
            (Get-NormalizedPath -Path $_.path) -eq $legacyCodexHooksPath
        })
    $legacyManagedConfigRecords = @($legacyManifest.backups | Where-Object {
            (Get-NormalizedPath -Path $_.path) -eq $legacyManagedConfigPath
        })
    if ($legacyHookRecords.Count -ne 1 -or
        $legacyManagedConfigRecords.Count -ne 0 -or
        -not [bool]$legacyHookRecords[0].existed -or
        [string]$legacyHookRecords[0].item_type -ne 'file' -or
        -not (Test-Path -LiteralPath ([string]$legacyHookRecords[0].backup_path) -PathType Leaf)) {
        throw 'legacy rebaseline fixture requires one restorable Codex hook record and no managed_config record per active manifest'
    }
    $legacyHookRecords[0].path = $legacyManagedConfigPath
    [System.IO.File]::WriteAllText(
        [string]$legacyHookRecords[0].backup_path,
        $(if ($manifestIndex -eq 0) { $legacyManagedConfigBaselineContent } else { $legacyManagedConfigContent }),
        (New-Object System.Text.UTF8Encoding($false)))
    if (@($legacyManifest.backups | Where-Object {
                (Get-NormalizedPath -Path $_.path) -eq $legacyCodexHooksPath
            }).Count -ne 0 -or
        @($legacyManifest.backups | Where-Object {
                (Get-NormalizedPath -Path $_.path) -eq $legacyManagedConfigPath
            }).Count -ne 1) {
        throw 'legacy rebaseline fixture did not replace its Codex hook record with managed_config'
    }
    foreach ($legacyManifestField in @('postimage_identity_contract','transaction_status','backup_payload_integrity_contract','managed_backup_targets','registry_preimage_sha256','requested_preset','effective_preset','preset_source','feature_ownership','user_profile','codex_hook_pwsh_executable','released_backup_targets','released_backup_manifest_paths')) {
        [void]$legacyManifest.PSObject.Properties.Remove($legacyManifestField)
    }
    foreach ($legacyBackupRecord in @($legacyManifest.backups)) {
        [void]$legacyBackupRecord.PSObject.Properties.Remove('expected_postimage')
        [void]$legacyBackupRecord.PSObject.Properties.Remove('backup_payload_sha256')
    }
    [System.IO.File]::WriteAllText(
        $legacyManifestPaths[$manifestIndex],
        ($legacyManifest | ConvertTo-Json -Depth 100),
        (New-Object System.Text.UTF8Encoding($false)))
    $legacyManifestDocuments += $legacyManifest
}

$legacySourceHistory = $legacyManifestPaths
$legacyExpectedSyntheticRecordCount = @($legacyManifestDocuments[0].backups).Count
$legacyEarliestExactRecord = @($legacyManifestDocuments[0].backups | Where-Object {
        (Get-NormalizedPath -Path $_.path) -eq (Get-NormalizedPath -Path $legacyEarliestExactPath)
    })
$legacyEarliestMissingRecord = @($legacyManifestDocuments[0].backups | Where-Object {
        (Get-NormalizedPath -Path $_.path) -eq (Get-NormalizedPath -Path $legacyEarliestMissingPath)
    })
if ($legacyEarliestExactRecord.Count -ne 1 -or
    -not [bool]$legacyEarliestExactRecord[0].existed -or
    [string]$legacyEarliestExactRecord[0].item_type -ne 'file' -or
    (Get-Content -LiteralPath $legacyEarliestExactRecord[0].backup_path -Raw -Encoding utf8) -cne $legacyEarliestExactContent -or
    $legacyEarliestMissingRecord.Count -ne 1 -or
    [bool]$legacyEarliestMissingRecord[0].existed -or
    [string]$legacyEarliestMissingRecord[0].item_type -ne 'missing') {
    throw 'legacy rebaseline fixture did not capture its earliest exact and missing preimages'
}
$legacyPointerAbsorbedUserGlobalCount = 0
$legacyPointerSkippedForeignUserGlobalCount = 6
$legacyPointerSkippedWorkspaceCount = 2
$legacyTargetContractDigests = @($legacyManifestDocuments | ForEach-Object {
        $targetContract = @($_.backups | ForEach-Object {
                [ordered]@{
                    path = [string]$_.path
                    scope = [string]$_.scope
                    ownership = [string]$_.ownership
                }
            })
        Get-InstallStateIdentityHash -Value (ConvertTo-Json -InputObject $targetContract -Depth 10 -Compress)
    })
if ($legacyExpectedSyntheticRecordCount -eq 0 -or
    @($legacyManifestDocuments | Where-Object { @($_.backups).Count -ne $legacyExpectedSyntheticRecordCount }).Count -ne 0 -or
    @($legacyTargetContractDigests | Select-Object -Unique).Count -ne 1) {
    throw 'legacy rebaseline fixture requires three current-profile manifests with one stable ordered target contract'
}
$legacyRegistry.schema_version = 'install-registry/v1.0'
foreach ($modernRegistryField in @('transaction_status_contract','history_ownership_contract','manifest_integrity_contract','retired_manifest_history','manifest_digests','released_target_history')) {
    [void]$legacyRegistry.PSObject.Properties.Remove($modernRegistryField)
}
[System.IO.File]::WriteAllText(
    $legacyRegistryPath,
    ($legacyRegistry | ConvertTo-Json -Depth 100),
    (New-Object System.Text.UTF8Encoding($false)))

$sameProfilePointerBackupRoot = Join-Path $legacyRepoRoot 'backups\legacy-pointer-current'
Copy-Item -LiteralPath ([string]$legacyManifestDocuments[0].backup_root) -Destination $sameProfilePointerBackupRoot -Recurse -Force
$sameProfilePointerManifestPath = Join-Path $sameProfilePointerBackupRoot 'install-manifest.json'
$sameProfilePointerManifest = Get-Content -LiteralPath $sameProfilePointerManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
$sameProfileSourceBackupRoot = [string]$sameProfilePointerManifest.backup_root
$sameProfilePointerManifest.backup_root = $sameProfilePointerBackupRoot
foreach ($sameProfilePointerRecord in @($sameProfilePointerManifest.backups)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$sameProfilePointerRecord.backup_path)) {
        $sameProfilePayloadRelativePath = [System.IO.Path]::GetRelativePath($sameProfileSourceBackupRoot, [string]$sameProfilePointerRecord.backup_path)
        $sameProfilePointerRecord.backup_path = Join-Path $sameProfilePointerBackupRoot $sameProfilePayloadRelativePath
    }
    foreach ($pointerRecordField in @('scope','ownership')) {
        [void]$sameProfilePointerRecord.PSObject.Properties.Remove($pointerRecordField)
    }
}
foreach ($pointerManifestField in @('schema_version','registry_path')) {
    [void]$sameProfilePointerManifest.PSObject.Properties.Remove($pointerManifestField)
}
[System.IO.File]::WriteAllText(
    $sameProfilePointerManifestPath,
    ($sameProfilePointerManifest | ConvertTo-Json -Depth 100),
    (New-Object System.Text.UTF8Encoding($false)))

$legacyPointerPath = Join-Path $legacyRepoRoot 'backups\active-install.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $legacyPointerPath) -Force | Out-Null
$legacyForeignPointerContent = [ordered]@{
    manifest_path = $legacyPointerManifestPath
    workspace_root = $legacyForeignWorkspace
    repo_root = [string]$legacyPointerManifest.repo_root
    vault_path = [string]$legacyPointerManifest.vault_path
    installed_at = [string]$legacyPointerManifest.installed_at
    requested_vault_profile = [string]$legacyPointerManifest.requested_vault_profile
    effective_vault_profile = [string]$legacyPointerManifest.effective_vault_profile
} | ConvertTo-Json -Depth 10
$legacySameProfilePointerContent = [ordered]@{
    manifest_path = $sameProfilePointerManifestPath
    workspace_root = $legacyWorkspace
    repo_root = [string]$sameProfilePointerManifest.repo_root
    vault_path = [string]$sameProfilePointerManifest.vault_path
    installed_at = [string]$sameProfilePointerManifest.installed_at
    requested_vault_profile = [string]$sameProfilePointerManifest.requested_vault_profile
    effective_vault_profile = [string]$sameProfilePointerManifest.effective_vault_profile
} | ConvertTo-Json -Depth 10
$legacyRegisteredManifest = $legacyManifestDocuments[-1]
$legacyRegisteredPointerContent = [ordered]@{
    manifest_path = [string]$legacyManifestPaths[-1]
    workspace_root = [string]$legacyRegisteredManifest.workspace_root
    repo_root = [string]$legacyRegisteredManifest.repo_root
    vault_path = [string]$legacyRegisteredManifest.vault_path
    installed_at = [string]$legacyRegisteredManifest.installed_at
    requested_vault_profile = [string]$legacyRegisteredManifest.requested_vault_profile
    effective_vault_profile = [string]$legacyRegisteredManifest.effective_vault_profile
} | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($legacyPointerPath, $legacySameProfilePointerContent, (New-Object System.Text.UTF8Encoding($false)))
$legacyInactiveManifestPaths = @($legacyWarmupManifestPath + $legacyManifestPaths + $legacyPointerManifestPath + $sameProfilePointerManifestPath)

$legacyTargetPaths = @($legacyManifestDocuments | ForEach-Object { @($_.backups).path }) + @($legacyCodexHooksPath) | Sort-Object -Unique
$legacyInstallStateRoot = Join-Path $legacyUserProfile '.dev-harness'
$legacyBackupsRoot = Join-Path $legacyUserProfile '.dev-harness\backups'
$legacyRepoBackupsRoot = Join-Path $legacyRepoRoot 'backups'
$legacyMarkerPath = Get-LegacyPointerMigrationMarkerPath -UserProfile $legacyUserProfile -PointerPath $legacyPointerPath
$getLegacyTargetState = {
    $targetIdentities = @($legacyTargetPaths | ForEach-Object {
            [ordered]@{
                path = (Get-NormalizedPath -Path $_)
                identity = (Get-InstallManagedPathIdentity -Path $_)
            }
        })
    return Get-InstallStateIdentityHash -Value (ConvertTo-Json -InputObject $targetIdentities -Depth 30 -Compress)
}
$getLegacyFixtureState = {
    $state = [ordered]@{
        registry_sha256 = Get-InstallStateFileDigest -Path $legacyRegistryPath
        pointer_sha256 = Get-InstallStateFileDigest -Path $legacyPointerPath
        marker_sha256 = Get-InstallStateFileDigest -Path $legacyMarkerPath
        backup_root_count = @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count
        backup_tree_sha256 = Get-InstallBackupPayloadDigest -Path $legacyBackupsRoot -ItemType 'directory'
        repo_backups_tree_sha256 = Get-InstallBackupPayloadDigest -Path $legacyRepoBackupsRoot -ItemType 'directory'
        install_state_tree_sha256 = Get-InstallBackupPayloadDigest -Path $legacyInstallStateRoot -ItemType 'directory'
        targets_sha256 = & $getLegacyTargetState
    }
    return Get-InstallStateIdentityHash -Value (ConvertTo-Json -InputObject $state -Depth 10 -Compress)
}

[System.IO.File]::WriteAllText(
    $legacyHookTemplatePath,
    $currentHookTemplateRaw,
    (New-Object System.Text.UTF8Encoding($false)))
Remove-Item -LiteralPath $legacyPostToolSourcePath -Force
$legacyInstallScript = Join-Path $legacyRepoRoot 'install.ps1'
$legacyStateBeforeSameProfilePointer = & $getLegacyFixtureState
$legacySameProfilePointerResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot,'-RebaselineLegacyInstallState')
if ($legacySameProfilePointerResult.ExitCode -ne 0 -and
    $legacySameProfilePointerResult.Output -match '(?i)History-external pointer for the current profile is unsupported' -and
    (& $getLegacyFixtureState) -eq $legacyStateBeforeSameProfilePointer) {
    $checks.Add('history-external pointer for the current profile fails closed as unsupported') | Out-Null
} else {
    $failures.Add(("history-external pointer for the current profile must not be folded into modern uninstall history; exit={0}; state_same={1}; output={2}" -f $legacySameProfilePointerResult.ExitCode,((& $getLegacyFixtureState) -eq $legacyStateBeforeSameProfilePointer),($legacySameProfilePointerResult.Output -replace '\r?\n',' | '))) | Out-Null
}
[System.IO.File]::WriteAllText($legacyPointerPath, $legacyRegisteredPointerContent, (New-Object System.Text.UTF8Encoding($false)))
$legacyStateBeforeRegisteredPointer = & $getLegacyFixtureState
$legacyRegisteredPointerResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot,'-RebaselineLegacyInstallState')
if ($legacyRegisteredPointerResult.ExitCode -eq 0 -and
    $legacyRegisteredPointerResult.Output -match '(?im)^STATUS:\s+REBASELINE_PLAN_REQUIRED\s*$' -and
    $legacyRegisteredPointerResult.Output -match '(?im)^SourceManifestCount:\s*3\s*$' -and
    $legacyRegisteredPointerResult.Output -match '(?im)^PointerSkippedExtinctWorkspaceCount:\s*0\s*$' -and
    $legacyRegisteredPointerResult.Output -match '(?im)^PointerSkippedForeignUserGlobalCount:\s*0\s*$' -and
    (& $getLegacyFixtureState) -eq $legacyStateBeforeRegisteredPointer) {
    $checks.Add('registered-history pointer reuses active legacy history without adding or skipping a source') | Out-Null
} else {
    $failures.Add('registered-history pointer should produce a read-only plan over the active legacy history') | Out-Null
}
[System.IO.File]::WriteAllText($legacyPointerPath, $legacyForeignPointerContent, (New-Object System.Text.UTF8Encoding($false)))

$legacyStateBeforeDefault = & $getLegacyFixtureState
$legacyDefaultResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot)
if ($legacyDefaultResult.ExitCode -ne 0 -and
    $legacyDefaultResult.Output -match 'LIVE_UPDATE_REQUIRED' -and
    $legacyDefaultResult.Output -match 'legacy-install-state' -and
    (& $getLegacyFixtureState) -eq $legacyStateBeforeDefault) {
    $checks.Add('ordinary install rejects a real legacy stack without registry, target, backup, pointer, or marker mutation') | Out-Null
} else {
    $failures.Add(("ordinary install must reject a real legacy stack before mutation; exit={0}; state_same={1}; output={2}" -f $legacyDefaultResult.ExitCode,((& $getLegacyFixtureState) -eq $legacyStateBeforeDefault),($legacyDefaultResult.Output -replace '\r?\n',' | '))) | Out-Null
}

$missingPayloadRecord = @($legacyManifestDocuments[1].backups | Where-Object {
        $_.item_type -eq 'file' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.backup_path) -and
        (Test-Path -LiteralPath $_.backup_path -PathType Leaf)
    } | Select-Object -First 1)
if ($missingPayloadRecord.Count -ne 1) {
    throw 'legacy rebaseline fixture requires one restorable file payload'
}
$missingPayloadPath = [string]$missingPayloadRecord[0].backup_path
$missingPayloadStash = Join-Path $legacyCaseRoot 'missing-payload.stash'
Move-Item -LiteralPath $missingPayloadPath -Destination $missingPayloadStash -Force
try {
    $legacyStateBeforeMissingPayload = & $getLegacyFixtureState
    $legacyMissingPayloadResult = Invoke-RepoScriptProcess `
        -UserProfile $legacyUserProfile `
        -ScriptPath $legacyInstallScript `
        -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot,'-RebaselineLegacyInstallState')
    if ($legacyMissingPayloadResult.ExitCode -ne 0 -and
        $legacyMissingPayloadResult.Output -notmatch '(?im)^STATUS:\s+REBASELINE_PLAN_REQUIRED\s*$' -and
        $legacyMissingPayloadResult.Output -match '(?i)(backup payload.*missing|missing.*backup payload)' -and
        (& $getLegacyFixtureState) -eq $legacyStateBeforeMissingPayload) {
        $checks.Add('legacy rebaseline rejects a missing backup payload before mutation') | Out-Null
    } else {
        $failures.Add('legacy rebaseline must reject a missing backup payload before producing an apply plan') | Out-Null
    }
} finally {
    Move-Item -LiteralPath $missingPayloadStash -Destination $missingPayloadPath -Force
}

$legacyStateBeforePlan = & $getLegacyFixtureState
$legacyPlanResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot,'-RebaselineLegacyInstallState')
$legacyDigestMatch = [regex]::Match($legacyPlanResult.Output, '(?im)^RebaselinePlanDigest:\s*([0-9a-f]{64})\s*$')
$legacyPlanDigest = if ($legacyDigestMatch.Success) { $legacyDigestMatch.Groups[1].Value } else { '' }
$legacyPlanCountsMatch =
    $legacyPlanResult.Output -match '(?im)^SourceManifestCount:\s*4\s*$' -and
    $legacyPlanResult.Output -match ("(?im)^SyntheticBackupRecordCount:\s*{0}\s*$" -f $legacyExpectedSyntheticRecordCount) -and
    $legacyPlanResult.Output -match ("(?im)^PointerAbsorbedUserGlobalCount:\s*{0}\s*$" -f $legacyPointerAbsorbedUserGlobalCount) -and
    $legacyPlanResult.Output -match ("(?im)^PointerSkippedForeignUserGlobalCount:\s*{0}\s*$" -f $legacyPointerSkippedForeignUserGlobalCount) -and
    $legacyPlanResult.Output -match ("(?im)^PointerSkippedExtinctWorkspaceCount:\s*{0}\s*$" -f $legacyPointerSkippedWorkspaceCount)
if ($legacyPlanResult.ExitCode -eq 0 -and
    $legacyPlanResult.Output -match '(?im)^STATUS:\s+REBASELINE_PLAN_REQUIRED\s*$' -and
    $legacyDigestMatch.Success -and
    $legacyPlanCountsMatch -and
    (& $getLegacyFixtureState) -eq $legacyStateBeforePlan) {
    $checks.Add('legacy rebaseline plan-only returns a digest and receipt counts without mutation') | Out-Null
} else {
    $failures.Add(("legacy rebaseline plan-only must be digest-bound, count-complete, and read-only; exit={0}; digest={1}; counts={2}; state_same={3}; output={4}" -f $legacyPlanResult.ExitCode,$legacyDigestMatch.Success,$legacyPlanCountsMatch,((& $getLegacyFixtureState) -eq $legacyStateBeforePlan),($legacyPlanResult.Output -replace '\r?\n',' | '))) | Out-Null
}

$legacyWrongDigest = '0' * 64
$legacyStateBeforeWrongDigest = & $getLegacyFixtureState
$legacyWrongDigestResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot,'-RebaselineLegacyInstallState','-ExpectedRebaselinePlanDigest',$legacyWrongDigest)
if ($legacyWrongDigestResult.ExitCode -ne 0 -and (& $getLegacyFixtureState) -eq $legacyStateBeforeWrongDigest) {
    $checks.Add('legacy rebaseline rejects a wrong expected digest before mutation') | Out-Null
} else {
    $failures.Add('wrong legacy rebaseline digest must fail before registry, target, backup, pointer, or marker mutation') | Out-Null
}

$legacyApplyResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot,'-RebaselineLegacyInstallState','-ExpectedRebaselinePlanDigest',$legacyPlanDigest) `
    -TimeoutMilliseconds 180000
$legacyApplyCountsMatch =
    $legacyApplyResult.Output -match '(?im)^SourceManifestCount:\s*4\s*$' -and
    $legacyApplyResult.Output -match ("(?im)^SyntheticBackupRecordCount:\s*{0}\s*$" -f $legacyExpectedSyntheticRecordCount) -and
    $legacyApplyResult.Output -match ("(?im)^PointerAbsorbedUserGlobalCount:\s*{0}\s*$" -f $legacyPointerAbsorbedUserGlobalCount) -and
    $legacyApplyResult.Output -match ("(?im)^PointerSkippedForeignUserGlobalCount:\s*{0}\s*$" -f $legacyPointerSkippedForeignUserGlobalCount) -and
    $legacyApplyResult.Output -match ("(?im)^PointerSkippedExtinctWorkspaceCount:\s*{0}\s*$" -f $legacyPointerSkippedWorkspaceCount)
$modernRegistry = Get-Content -LiteralPath $legacyRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
$modernWorkspaceEntry = @($modernRegistry.workspaces.PSObject.Properties | Select-Object -First 1)[0].Value
$modernActiveManifestPaths = @($modernWorkspaceEntry.manifests)
$modernGlobalManifestPaths = @($modernRegistry.global_manifest_history)
$modernActiveManifests = @($modernActiveManifestPaths | ForEach-Object {
        Get-Content -LiteralPath $_ -Raw -Encoding utf8 | ConvertFrom-Json
    })
$syntheticManifests = @($modernActiveManifests | Where-Object { $null -ne $_.PSObject.Properties['legacy_rebaseline_receipt'] })
$syntheticReceipt = if ($syntheticManifests.Count -eq 1) { $syntheticManifests[0].legacy_rebaseline_receipt } else { $null }
$modernReleasedManagedConfigEntries = @($modernRegistry.released_target_history | Where-Object {
        (Get-NormalizedPath -Path $_.path) -eq $legacyManagedConfigPath
    })
$modernHistoryContainsLegacy = @($modernActiveManifestPaths + $modernGlobalManifestPaths | Where-Object { $legacyInactiveManifestPaths -contains $_ }).Count -ne 0
$modernRegistryFields = @($modernRegistry.PSObject.Properties.Name)
$modernHistoryValid =
    $modernRegistry.schema_version -eq 'install-registry/v1.1' -and
    $modernRegistry.transaction_status_contract -eq 'v1' -and
    $modernRegistry.history_ownership_contract -eq 'v1' -and
    $modernRegistry.manifest_integrity_contract -eq 'sha256-v1' -and
    $modernRegistryFields -contains 'retired_manifest_history' -and
    $modernRegistryFields -contains 'manifest_digests' -and
    $modernReleasedManagedConfigEntries.Count -eq 1 -and
    (ConvertTo-Json -InputObject $modernActiveManifestPaths -Compress) -eq (ConvertTo-Json -InputObject $modernGlobalManifestPaths -Compress) -and
    -not $modernHistoryContainsLegacy -and
    @($modernActiveManifests | Where-Object {
            $_.schema_version -ne 'install-manifest/v1.2' -or
            $_.transaction_status -ne 'committed' -or
            @($_.backups | Where-Object { $null -eq $_.PSObject.Properties['expected_postimage'] }).Count -ne 0
        }).Count -eq 0
$syntheticReceiptValid =
    $null -ne $syntheticReceipt -and
    $syntheticReceipt.contract -eq 'legacy_rebaseline/v1' -and
    $syntheticReceipt.plan_digest -eq $legacyPlanDigest -and
    $syntheticReceipt.source_payload_set_sha256 -match '^[0-9a-f]{64}$' -and
    [int]$syntheticReceipt.source_manifest_count -eq 4 -and
    [int]$syntheticReceipt.synthetic_backup_record_count -eq $legacyExpectedSyntheticRecordCount -and
    [int]$syntheticReceipt.pointer_absorbed_user_global_count -eq $legacyPointerAbsorbedUserGlobalCount -and
    [int]$syntheticReceipt.pointer_skipped_foreign_user_global_count -eq $legacyPointerSkippedForeignUserGlobalCount -and
    [int]$syntheticReceipt.pointer_skipped_extinct_workspace_count -eq $legacyPointerSkippedWorkspaceCount
$legacyMarkerContentAfterApply = if (Test-Path -LiteralPath $legacyMarkerPath -PathType Leaf) {
    [System.IO.File]::ReadAllText($legacyMarkerPath).Trim()
} else { '' }
if ($legacyApplyResult.ExitCode -eq 0 -and
    $legacyApplyResult.Output -match '(?im)^STATUS:\s+REBASELINE_COMMITTED\s*$' -and
    $legacyApplyCountsMatch -and
    $modernHistoryValid -and
    $syntheticReceiptValid -and
    (Test-Path -LiteralPath $legacyCodexHooksPath -PathType Leaf) -and
    (Test-Path -LiteralPath $legacyManagedConfigPath -PathType Leaf) -and
    ([System.IO.File]::ReadAllText($legacyManagedConfigPath) -ceq $legacyManagedConfigBaselineContent) -and
    $legacyMarkerContentAfterApply -eq [string]$syntheticReceipt.legacy_pointer_sha256) {
    $checks.Add('digest-bound rebaseline publishes one modern synthetic receipt, releases legacy managed_config, and installs Codex hooks') | Out-Null
} else {
    throw ("digest-bound rebaseline should publish the synthetic receipt, release managed_config, install Codex hooks, skip foreign pointer records, and continue install; exit={0}; counts={1}; history={2}; receipt={3}; output={4}" -f $legacyApplyResult.ExitCode,$legacyApplyCountsMatch,$modernHistoryValid,$syntheticReceiptValid,($legacyApplyResult.Output -replace '\r?\n',' | '))
}
[System.IO.File]::WriteAllText(
    $legacyManagedConfigPath,
    $legacyManagedConfigUserContent,
    (New-Object System.Text.UTF8Encoding($false)))

$legacyTargetStateAfterApply = & $getLegacyTargetState
$legacyBackupRootCountAfterApply = @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count
$legacyPointerDigestAfterApply = Get-InstallStateFileDigest -Path $legacyPointerPath
Remove-Item -LiteralPath $legacyMarkerPath -Force
New-Item -ItemType Directory -Path $legacyMarkerPath -Force | Out-Null
$markerBlockRegistryDigest = Get-InstallStateFileDigest -Path $legacyRegistryPath
$markerBlockTargetState = & $getLegacyTargetState
$markerBlockBackupRootCount = @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count
try {
    $legacyMarkerBlockedResult = Invoke-RepoScriptProcess `
        -UserProfile $legacyUserProfile `
        -ScriptPath $legacyInstallScript `
        -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot)
} finally {
    Remove-Item -LiteralPath $legacyMarkerPath -Recurse -Force
}
if ($legacyMarkerBlockedResult.ExitCode -ne 0 -and
    (Get-InstallStateFileDigest -Path $legacyRegistryPath) -eq $markerBlockRegistryDigest -and
    (& $getLegacyTargetState) -eq $markerBlockTargetState -and
    @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count -eq $markerBlockBackupRootCount -and
    -not (Test-Path -LiteralPath (Join-Path $legacyUserProfile '.dev-harness\install-transaction.json'))) {
    $checks.Add('receipt retry fails closed before install mutation when its pointer marker cannot be written') | Out-Null
} else {
    $failures.Add('receipt retry must not continue when its pointer marker preflight fails') | Out-Null
}

$legacyOrdinaryRetryResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot) `
    -TimeoutMilliseconds 180000
$ordinaryRetryRegistry = Get-Content -LiteralPath $legacyRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
$ordinaryRetryWorkspaceEntry = @($ordinaryRetryRegistry.workspaces.PSObject.Properties | Select-Object -First 1)[0].Value
$ordinaryRetryActiveManifestPaths = @($ordinaryRetryWorkspaceEntry.manifests)
$ordinaryRetryMarkerContent = if (Test-Path -LiteralPath $legacyMarkerPath -PathType Leaf) {
    [System.IO.File]::ReadAllText($legacyMarkerPath).Trim()
} else { '' }
if ($legacyOrdinaryRetryResult.ExitCode -eq 0 -and
    $ordinaryRetryActiveManifestPaths.Count -eq ($modernActiveManifestPaths.Count + 1) -and
    (ConvertTo-Json -InputObject @($ordinaryRetryActiveManifestPaths | Select-Object -First $modernActiveManifestPaths.Count) -Compress) -eq
        (ConvertTo-Json -InputObject $modernActiveManifestPaths -Compress) -and
    @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count -eq ($legacyBackupRootCountAfterApply + 1) -and
    (& $getLegacyTargetState) -eq $legacyTargetStateAfterApply -and
    $ordinaryRetryMarkerContent -eq $legacyPointerDigestAfterApply) {
    $checks.Add('ordinary retry after a committed receipt recreates the missing pointer marker and continues install') | Out-Null
} else {
    $failures.Add('ordinary retry should recreate a missing pointer marker before continuing install') | Out-Null
}

$legacyBrokenPointerContent = '{"broken":'
[System.IO.File]::WriteAllText(
    $legacyPointerPath,
    $legacyBrokenPointerContent,
    (New-Object System.Text.UTF8Encoding($false)))
$legacyBrokenPointerDigest = Get-InstallStateFileDigest -Path $legacyPointerPath
$legacyBackupRootCountBeforeMarkerRetry = @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count
$legacyMarkerDigestBeforeMarkerRetry = Get-InstallStateFileDigest -Path $legacyMarkerPath
$legacyMarkerRetryResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot) `
    -TimeoutMilliseconds 180000
$markerRetryRegistry = Get-Content -LiteralPath $legacyRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
$markerRetryWorkspaceEntry = @($markerRetryRegistry.workspaces.PSObject.Properties | Select-Object -First 1)[0].Value
$markerRetryActiveManifestPaths = @($markerRetryWorkspaceEntry.manifests)
if ($legacyMarkerRetryResult.ExitCode -eq 0 -and
    $markerRetryActiveManifestPaths.Count -eq ($ordinaryRetryActiveManifestPaths.Count + 1) -and
    (ConvertTo-Json -InputObject @($markerRetryActiveManifestPaths | Select-Object -First $ordinaryRetryActiveManifestPaths.Count) -Compress) -eq
        (ConvertTo-Json -InputObject $ordinaryRetryActiveManifestPaths -Compress) -and
    @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count -eq ($legacyBackupRootCountBeforeMarkerRetry + 1) -and
    (& $getLegacyTargetState) -eq $legacyTargetStateAfterApply -and
    (Get-InstallStateFileDigest -Path $legacyPointerPath) -eq $legacyBrokenPointerDigest -and
    (Get-InstallStateFileDigest -Path $legacyMarkerPath) -eq $legacyMarkerDigestBeforeMarkerRetry) {
    $checks.Add('a valid pointer marker takes precedence over a subsequently corrupted legacy pointer during ordinary install') | Out-Null
} else {
    $failures.Add(("ordinary install should trust its durable pointer marker instead of reparsing a retired pointer; exit={0}; output={1}" -f $legacyMarkerRetryResult.ExitCode,($legacyMarkerRetryResult.Output -replace '\r?\n',' | '))) | Out-Null
}

$legacyBackupRootCountBeforeDigestRetry = @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count
$legacyMarkerDigestBeforeDigestRetry = Get-InstallStateFileDigest -Path $legacyMarkerPath
$legacyRetryResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot,'-RebaselineLegacyInstallState','-ExpectedRebaselinePlanDigest',$legacyPlanDigest) `
    -TimeoutMilliseconds 180000
$retryRegistry = Get-Content -LiteralPath $legacyRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
$retryWorkspaceEntry = @($retryRegistry.workspaces.PSObject.Properties | Select-Object -First 1)[0].Value
$retryActiveManifestPaths = @($retryWorkspaceEntry.manifests)
$retryGlobalManifestPaths = @($retryRegistry.global_manifest_history)
$retryActiveManifests = @($retryActiveManifestPaths | ForEach-Object {
        Get-Content -LiteralPath $_ -Raw -Encoding utf8 | ConvertFrom-Json
    })
$retryReceiptCount = @($retryActiveManifests | Where-Object {
        $null -ne $_.PSObject.Properties['legacy_rebaseline_receipt'] -and
        $_.legacy_rebaseline_receipt.plan_digest -eq $legacyPlanDigest
    }).Count
$retryContainsLegacy = @($retryActiveManifestPaths + $retryGlobalManifestPaths | Where-Object { $legacyInactiveManifestPaths -contains $_ }).Count -ne 0
$retryPreservesActivePrefix =
    $retryActiveManifestPaths.Count -eq ($markerRetryActiveManifestPaths.Count + 1) -and
    (ConvertTo-Json -InputObject @($retryActiveManifestPaths | Select-Object -First $markerRetryActiveManifestPaths.Count) -Compress) -eq
        (ConvertTo-Json -InputObject $markerRetryActiveManifestPaths -Compress)
$retryHistoryValid = @($retryActiveManifests | Where-Object {
        $_.schema_version -ne 'install-manifest/v1.2' -or
        $_.transaction_status -ne 'committed' -or
        @($_.backups | Where-Object { $null -eq $_.PSObject.Properties['expected_postimage'] }).Count -ne 0
    }).Count -eq 0
if ($legacyRetryResult.ExitCode -eq 0 -and
    $legacyRetryResult.Output -match '(?im)^STATUS:\s+REBASELINE_ALREADY_COMMITTED\s*$' -and
    $legacyRetryResult.Output -match ("(?im)^RebaselinePlanDigest:\s*{0}\s*$" -f $legacyPlanDigest) -and
    $retryReceiptCount -eq 1 -and
    $retryPreservesActivePrefix -and
    $retryHistoryValid -and
    (ConvertTo-Json -InputObject $retryActiveManifestPaths -Compress) -eq (ConvertTo-Json -InputObject $retryGlobalManifestPaths -Compress) -and
    @(Get-ChildItem -LiteralPath $legacyBackupsRoot -Directory -Force).Count -eq ($legacyBackupRootCountBeforeDigestRetry + 1) -and
    (& $getLegacyTargetState) -eq $legacyTargetStateAfterApply -and
    (Get-InstallStateFileDigest -Path $legacyPointerPath) -eq $legacyBrokenPointerDigest -and
    (Get-InstallStateFileDigest -Path $legacyMarkerPath) -eq $legacyMarkerDigestBeforeDigestRetry -and
    -not $retryContainsLegacy) {
    $checks.Add('digest-bound retry trusts the durable marker, reuses one receipt, and adds only the expected modern install layer') | Out-Null
} else {
    $failures.Add(("repeating a committed rebaseline digest should safely retry without duplicating its receipt or reactivating legacy history; exit={0}; receipt_count={1}; prefix={2}; history={3}; legacy={4}; output={5}" -f $legacyRetryResult.ExitCode,$retryReceiptCount,$retryPreservesActivePrefix,$retryHistoryValid,$retryContainsLegacy,($legacyRetryResult.Output -replace '\r?\n',' | '))) | Out-Null
}

$legacyClaudeSettingsPath = Join-Path $legacyUserProfile '.claude\settings.json'
$legacyClaudeSettings = Get-Content -LiteralPath $legacyClaudeSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
$legacyClaudeSettings | Add-Member -NotePropertyName 'lifecycle_user_sentinel' -NotePropertyValue 'preserve-me' -Force
[System.IO.File]::WriteAllText(
    $legacyClaudeSettingsPath,
    ($legacyClaudeSettings | ConvertTo-Json -Depth 100),
    (New-Object System.Text.UTF8Encoding($false)))
$legacyInstallJournalPath = Join-Path $legacyUserProfile '.dev-harness\install-transaction.json'
$legacyUninstallJournalPath = Join-Path $legacyUserProfile '.dev-harness\uninstall-transaction.json'
Remove-Item -LiteralPath $legacyMarkerPath -Force
New-Item -ItemType Directory -Path $legacyMarkerPath -Force | Out-Null
$legacyRegistryDigestBeforeUninstallMarkerFailure = Get-InstallStateFileDigest -Path $legacyRegistryPath
$legacyTargetStateBeforeUninstallMarkerFailure = & $getLegacyTargetState
$legacyBackupsDigestBeforeUninstallMarkerFailure = Get-InstallBackupPayloadDigest -Path $legacyBackupsRoot -ItemType 'directory'
try {
    $legacyMarkerBlockedUninstallResult = Invoke-RepoScriptProcess `
        -UserProfile $legacyUserProfile `
        -ScriptPath (Join-Path $legacyRepoRoot 'uninstall.ps1') `
        -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot) `
        -TimeoutMilliseconds 180000
    $legacyMarkerBlockedUninstallKeptDirectory = Test-Path -LiteralPath $legacyMarkerPath -PathType Container
} finally {
    Remove-Item -LiteralPath $legacyMarkerPath -Recurse -Force
}
if ($legacyMarkerBlockedUninstallResult.ExitCode -ne 0 -and
    (Get-InstallStateFileDigest -Path $legacyRegistryPath) -eq $legacyRegistryDigestBeforeUninstallMarkerFailure -and
    (& $getLegacyTargetState) -eq $legacyTargetStateBeforeUninstallMarkerFailure -and
    (Get-InstallBackupPayloadDigest -Path $legacyBackupsRoot -ItemType 'directory') -eq $legacyBackupsDigestBeforeUninstallMarkerFailure -and
    (Test-Path -LiteralPath $legacyUninstallJournalPath -PathType Leaf) -and
    $legacyMarkerBlockedUninstallKeptDirectory) {
    $checks.Add('receipt marker failure leaves a durable uninstall journal and performs zero restore mutation') | Out-Null
} else {
    $failures.Add(("uninstall must journal then fail closed before restore when receipt marker publication is blocked; exit={0}; registry={1}; targets={2}; backups={3}; journal={4}; output={5}" -f $legacyMarkerBlockedUninstallResult.ExitCode,((Get-InstallStateFileDigest -Path $legacyRegistryPath) -eq $legacyRegistryDigestBeforeUninstallMarkerFailure),((& $getLegacyTargetState) -eq $legacyTargetStateBeforeUninstallMarkerFailure),((Get-InstallBackupPayloadDigest -Path $legacyBackupsRoot -ItemType 'directory') -eq $legacyBackupsDigestBeforeUninstallMarkerFailure),(Test-Path -LiteralPath $legacyUninstallJournalPath -PathType Leaf),($legacyMarkerBlockedUninstallResult.Output -replace '\r?\n',' | '))) | Out-Null
}

$legacyUninstallResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath (Join-Path $legacyRepoRoot 'uninstall.ps1') `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot) `
    -TimeoutMilliseconds 180000
$legacySettingsAfterUninstall = if (Test-Path -LiteralPath $legacyClaudeSettingsPath -PathType Leaf) {
    Get-Content -LiteralPath $legacyClaudeSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json
} else { $null }
$legacyExactAfterUninstall = if (Test-Path -LiteralPath $legacyEarliestExactPath -PathType Leaf) {
    Get-Content -LiteralPath $legacyEarliestExactPath -Raw -Encoding utf8
} else { $null }
$legacyMarkerContentAfterUninstall = if (Test-Path -LiteralPath $legacyMarkerPath -PathType Leaf) {
    [System.IO.File]::ReadAllText($legacyMarkerPath).Trim()
} else { '' }
$legacyManagedConfigAfterUninstall = if (Test-Path -LiteralPath $legacyManagedConfigPath -PathType Leaf) {
    [System.IO.File]::ReadAllText($legacyManagedConfigPath)
} else { $null }
if ($legacyUninstallResult.ExitCode -eq 0 -and
    $legacyExactAfterUninstall -ceq $legacyEarliestExactContent -and
    -not (Test-Path -LiteralPath $legacyEarliestMissingPath) -and
    -not (Test-Path -LiteralPath $legacyCodexHooksPath) -and
    $legacyManagedConfigAfterUninstall -ceq $legacyManagedConfigUserContent -and
    $null -ne $legacySettingsAfterUninstall -and
    [string]$legacySettingsAfterUninstall.lifecycle_user_sentinel -eq 'preserve-me' -and
    -not (Test-Path -LiteralPath $legacyRegistryPath) -and
    -not (Test-Path -LiteralPath $legacyInstallJournalPath) -and
    -not (Test-Path -LiteralPath $legacyUninstallJournalPath) -and
    $legacyMarkerContentAfterUninstall -eq $legacyPointerDigestAfterApply) {
    $checks.Add('resumed synthetic full uninstall removes Codex hooks, preserves released managed_config, restores safe baselines, and converges journals') | Out-Null
} else {
    $failures.Add(("synthetic full uninstall should remove Codex hooks, preserve released managed_config, restore its oldest safe baseline, and leave a reusable pointer marker; exit={0}; exact={1}; missing={2}; hooks={3}; managed_config={4}; semantic={5}; registry={6}; install_journal={7}; uninstall_journal={8}; marker={9}; output={10}" -f $legacyUninstallResult.ExitCode,($legacyExactAfterUninstall -ceq $legacyEarliestExactContent),(-not (Test-Path -LiteralPath $legacyEarliestMissingPath)),(-not (Test-Path -LiteralPath $legacyCodexHooksPath)),($legacyManagedConfigAfterUninstall -ceq $legacyManagedConfigUserContent),($null -ne $legacySettingsAfterUninstall -and [string]$legacySettingsAfterUninstall.lifecycle_user_sentinel -eq 'preserve-me'),(Test-Path -LiteralPath $legacyRegistryPath),(Test-Path -LiteralPath $legacyInstallJournalPath),(Test-Path -LiteralPath $legacyUninstallJournalPath),($legacyMarkerContentAfterUninstall -eq $legacyPointerDigestAfterApply),($legacyUninstallResult.Output -replace '\r?\n',' | '))) | Out-Null
}

$legacyFreshInstallResult = Invoke-RepoScriptProcess `
    -UserProfile $legacyUserProfile `
    -ScriptPath $legacyInstallScript `
    -Arguments @('-WorkspaceRoot',$legacyWorkspace,'-RepoRoot',$legacyRepoRoot) `
    -TimeoutMilliseconds 180000
$legacyFreshRegistry = if (Test-Path -LiteralPath $legacyRegistryPath -PathType Leaf) {
    Get-Content -LiteralPath $legacyRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
} else { $null }
if ($legacyFreshInstallResult.ExitCode -eq 0 -and
    $null -ne $legacyFreshRegistry -and
    [string]$legacyFreshRegistry.schema_version -eq 'install-registry/v1.1' -and
    (Test-Path -LiteralPath $legacyCodexHooksPath -PathType Leaf) -and
    (Test-Path -LiteralPath $legacyManagedConfigPath -PathType Leaf) -and
    ([System.IO.File]::ReadAllText($legacyManagedConfigPath) -ceq $legacyManagedConfigUserContent) -and
    -not (Test-Path -LiteralPath $legacyInstallJournalPath) -and
    -not (Test-Path -LiteralPath $legacyUninstallJournalPath) -and
    (Test-LegacyPointerMigrationMarked -UserProfile $legacyUserProfile -PointerPath $legacyPointerPath)) {
    $checks.Add('fresh reinstall reuses the durable pointer marker, reinstalls Codex hooks, and preserves released managed_config') | Out-Null
} else {
    $failures.Add(("fresh reinstall should not reactivate the retired legacy pointer or reclaim managed_config; exit={0}; registry={1}; hooks={2}; managed_config={3}; install_journal={4}; uninstall_journal={5}; output={6}" -f $legacyFreshInstallResult.ExitCode,($null -ne $legacyFreshRegistry),(Test-Path -LiteralPath $legacyCodexHooksPath -PathType Leaf),((Test-Path -LiteralPath $legacyManagedConfigPath -PathType Leaf) -and ([System.IO.File]::ReadAllText($legacyManagedConfigPath) -ceq $legacyManagedConfigUserContent)),(Test-Path -LiteralPath $legacyInstallJournalPath),(Test-Path -LiteralPath $legacyUninstallJournalPath),($legacyFreshInstallResult.Output -replace '\r?\n',' | '))) | Out-Null
}

$caseRoot = Join-Path $scratchRoot 'host-only-system-skill-does-not-pollute-repo'
$workspaceRoot = Join-Path $caseRoot 'workspace'
$userProfile = Join-Path $caseRoot 'user'
New-Item -ItemType Directory -Path $workspaceRoot,$userProfile -Force | Out-Null

$codexConfigPath = Join-Path $userProfile '.codex\config.toml'
$codexConfigSentinel = @'
# user-owned codex config
model = "user-private-model"

[projects.'D:\private-project']
trust_level = "trusted"
'@
New-Item -ItemType Directory -Path (Split-Path -Parent $codexConfigPath) -Force | Out-Null
Set-Content -LiteralPath $codexConfigPath -Value $codexConfigSentinel -Encoding utf8
$codexConfigHashBefore = (Get-FileHash -LiteralPath $codexConfigPath -Algorithm SHA256).Hash

$localSystemSkillPath = Join-Path $userProfile '.claude\skills\.system\custom-local-skill'
New-Item -ItemType Directory -Path $localSystemSkillPath -Force | Out-Null
Set-Content -LiteralPath (Join-Path $localSystemSkillPath 'SKILL.md') -Value '# local only' -Encoding utf8

$installResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

if ($installResult.ExitCode -ne 0) {
    $failures.Add('install.ps1 should succeed when a host-only local system skill exists') | Out-Null
} else {
    $checks.Add('install.ps1 succeeds when a host-only local system skill exists') | Out-Null
}

$freshContractValid = $false
try {
    $freshRegistryPath = Join-Path $userProfile '.dev-harness\install-registry.json'
    $freshRegistry = Get-Content -LiteralPath $freshRegistryPath -Raw -Encoding utf8 | ConvertFrom-Json
    $freshWorkspaceEntry = @($freshRegistry.workspaces.PSObject.Properties | Select-Object -First 1)[0].Value
    $freshManifestPath = [string]@($freshWorkspaceEntry.manifests)[-1]
    $freshManifest = Get-Content -LiteralPath $freshManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $freshBackupRecords = @($freshManifest.backups)
    $freshRegistryFields = @($freshRegistry.PSObject.Properties.Name)
    $freshContractValid = `
        $freshRegistry.schema_version -eq 'install-registry/v1.1' -and `
        $freshRegistry.transaction_status_contract -eq 'v1' -and `
        $freshRegistry.history_ownership_contract -eq 'v1' -and `
        $freshRegistry.manifest_integrity_contract -eq 'sha256-v1' -and `
        $freshRegistryFields -contains 'retired_manifest_history' -and `
        $freshRegistryFields -contains 'manifest_digests' -and `
        $freshManifest.schema_version -eq 'install-manifest/v1.2' -and `
        $freshManifest.postimage_identity_contract -eq 'v1' -and `
        $freshBackupRecords.Count -gt 0 -and `
        @($freshBackupRecords | Where-Object { $_.PSObject.Properties.Name -notcontains 'expected_postimage' }).Count -eq 0 -and `
        -not (Test-Path -LiteralPath (Join-Path $userProfile '.dev-harness\install-transaction.json'))
} catch {
    $freshContractValid = $false
}
if ($freshContractValid) {
    $checks.Add('fresh install persists registry v1.1, manifest v1.2, and expected postimage identities before clearing its journal') | Out-Null
} else {
    $failures.Add('fresh install should persist the complete registry, manifest, and expected-postimage contract') | Out-Null
}

$repoSystemPollutionPath = Join-Path $RepoRoot 'skills\.system\custom-local-skill'
if (Test-Path -LiteralPath $repoSystemPollutionPath) {
    $failures.Add('install.ps1 should not copy host-only local system skills into repo-local skills/.system') | Out-Null
} else {
    $checks.Add('install.ps1 does not copy host-only local system skills into repo-local skills/.system') | Out-Null
}

if (-not (Test-Path -LiteralPath (Join-Path $localSystemSkillPath 'SKILL.md') -PathType Leaf)) {
    $failures.Add('install.ps1 should preserve the original host-only local system skill') | Out-Null
} else {
    $checks.Add('install.ps1 preserves the original host-only local system skill') | Out-Null
}

$codexConfigHashAfter = (Get-FileHash -LiteralPath $codexConfigPath -Algorithm SHA256).Hash
if ($codexConfigHashAfter -ne $codexConfigHashBefore) {
    $failures.Add('install.ps1 should not modify %USERPROFILE%\.codex\config.toml') | Out-Null
} else {
    $checks.Add('install.ps1 leaves %USERPROFILE%\.codex\config.toml unchanged') | Out-Null
}

$verifyResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}

$verifyOutput = $verifyResult.Output -join [Environment]::NewLine
if ($verifyResult.ExitCode -ne 0 -or $verifyOutput -notmatch '(?im)^STATUS:\s+PASS\s*$') {
    $failures.Add('verify-installation.ps1 should pass after installing with a host-only local system skill') | Out-Null
} else {
    $checks.Add('verify-installation.ps1 passes after installing with a host-only local system skill') | Out-Null
}

$workspaceAgentsPath = Join-Path $workspaceRoot 'AGENTS.md'
$workspaceAgentsRaw = Get-Content -LiteralPath $workspaceAgentsPath -Raw -Encoding utf8
try {
    [System.IO.File]::WriteAllText($workspaceAgentsPath, ($workspaceAgentsRaw + "`n# drift"), (New-Object System.Text.UTF8Encoding($false)))
    $workspaceAgentsAuditResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot      = $RepoRoot
    }
    $workspaceAgentsAuditOutput = $workspaceAgentsAuditResult.Output -join [Environment]::NewLine
} finally {
    [System.IO.File]::WriteAllText($workspaceAgentsPath, $workspaceAgentsRaw, (New-Object System.Text.UTF8Encoding($false)))
}
$workspaceAgentsMarkerCount = [regex]::Matches($workspaceAgentsAuditOutput, '(?im)^- LIVE_UPDATE_REQUIRED:').Count
if ($workspaceAgentsAuditResult.ExitCode -eq 1 -and
    $workspaceAgentsAuditOutput -match '(?im)^STATUS:\s+LIVE_UPDATE_REQUIRED\s*$' -and
    $workspaceAgentsAuditOutput -match '(?ms)^Warnings:\r?\n- LIVE_UPDATE_REQUIRED: workspace-agents-template-drift\r?\n\r?\nErrors:\r?\n- none(?:\r?\n|$)' -and
    $workspaceAgentsMarkerCount -eq 1) {
    $checks.Add('verify-installation detects installed workspace root AGENTS drift with only the existing template marker') | Out-Null
} else {
    $failures.Add('installed workspace root AGENTS-only drift should emit only LIVE_UPDATE_REQUIRED: workspace-agents-template-drift') | Out-Null
}

$workspaceAgentsRestoreResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}
$workspaceAgentsRestoreOutput = $workspaceAgentsRestoreResult.Output -join [Environment]::NewLine
if ($workspaceAgentsRestoreResult.ExitCode -eq 0 -and $workspaceAgentsRestoreOutput -match '(?im)^STATUS:\s+PASS\s*$') {
    $checks.Add('verify-installation returns to PASS after restoring installed workspace root AGENTS') | Out-Null
} else {
    $failures.Add('verify-installation should return to PASS after restoring installed workspace root AGENTS') | Out-Null
}

$retiredEntryAgentsPath = Join-Path $workspaceRoot '.assistant\entry\AGENTS.md'
if (Test-Path -LiteralPath $retiredEntryAgentsPath) { throw 'current installation recreated the retired lifecycle shim' }
$workspaceTaskShimPath = Join-Path $workspaceRoot '.assistant\entry\task.ps1'
$workspaceTaskShimRaw = Get-Content -LiteralPath $workspaceTaskShimPath -Raw -Encoding utf8
try {
    [System.IO.File]::WriteAllText($workspaceTaskShimPath, ($workspaceTaskShimRaw + "`n# drift"), (New-Object System.Text.UTF8Encoding($false)))
    $entryAgentsAuditResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot      = $RepoRoot
    }
    $entryAgentsAuditOutput = $entryAgentsAuditResult.Output -join [Environment]::NewLine
} finally {
    [System.IO.File]::WriteAllText($workspaceTaskShimPath, $workspaceTaskShimRaw, (New-Object System.Text.UTF8Encoding($false)))
}
$entryAgentsMarkerCount = [regex]::Matches($entryAgentsAuditOutput, '(?im)^- LIVE_UPDATE_REQUIRED:').Count
if ($entryAgentsAuditResult.ExitCode -eq 1 -and
    $entryAgentsAuditOutput -match '(?im)^STATUS:\s+LIVE_UPDATE_REQUIRED\s*$' -and
    $entryAgentsAuditOutput -match '(?ms)^Warnings:\r?\n- LIVE_UPDATE_REQUIRED: shim-template-drift\r?\n\r?\nErrors:\r?\n- none(?:\r?\n|$)' -and
    $entryAgentsMarkerCount -eq 1) {
    $checks.Add('verify-installation reports only the existing shim template drift marker when the current task entry alone drifts') | Out-Null
} else {
    $failures.Add('current task entry-only drift should emit only LIVE_UPDATE_REQUIRED: shim-template-drift') | Out-Null
}

$entryAgentsRestoreResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot      = $RepoRoot
}
$entryAgentsRestoreOutput = $entryAgentsRestoreResult.Output -join [Environment]::NewLine
if ($entryAgentsRestoreResult.ExitCode -eq 0 -and $entryAgentsRestoreOutput -match '(?im)^STATUS:\s+PASS\s*$') {
    $checks.Add('verify-installation returns to PASS after restoring the current task entry') | Out-Null
} else {
    $failures.Add('verify-installation should return to PASS after restoring the current task entry') | Out-Null
}

$freshRegistryRaw = Get-Content -LiteralPath $freshRegistryPath -Raw -Encoding utf8
try {
    $legacyAuditRegistry = $freshRegistryRaw | ConvertFrom-Json
    $legacyAuditRegistry.schema_version = 'install-registry/v1.0'
    [System.IO.File]::WriteAllText($freshRegistryPath, ($legacyAuditRegistry | ConvertTo-Json -Depth 100), (New-Object System.Text.UTF8Encoding($false)))
    $legacyAuditResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot      = $RepoRoot
    }
    $legacyAuditOutput = $legacyAuditResult.Output -join [Environment]::NewLine
} finally {
    [System.IO.File]::WriteAllText($freshRegistryPath, $freshRegistryRaw, (New-Object System.Text.UTF8Encoding($false)))
}
if ($legacyAuditResult.ExitCode -eq 1 -and
    $legacyAuditOutput -match '(?im)^STATUS:\s+LIVE_UPDATE_REQUIRED\s*$' -and
    $legacyAuditOutput -match '(?im)^- LIVE_UPDATE_REQUIRED: legacy-install-state\s*$') {
    $checks.Add('verify-installation reports the exact legacy install-state rollout blocker') | Out-Null
} else {
    $failures.Add('legacy registry audit should emit LIVE_UPDATE_REQUIRED: legacy-install-state') | Out-Null
}

$codexAgentsPath = Join-Path $userProfile '.codex\AGENTS.md'
$codexAgentsRaw = Get-Content -LiteralPath $codexAgentsPath -Raw -Encoding utf8
try {
    [System.IO.File]::WriteAllText($codexAgentsPath, ($codexAgentsRaw + "`n# drift"), (New-Object System.Text.UTF8Encoding($false)))
    $codexAgentsAuditResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot      = $RepoRoot
    }
    $codexAgentsAuditOutput = $codexAgentsAuditResult.Output -join [Environment]::NewLine
} finally {
    [System.IO.File]::WriteAllText($codexAgentsPath, $codexAgentsRaw, (New-Object System.Text.UTF8Encoding($false)))
}
if ($codexAgentsAuditResult.ExitCode -eq 1 -and
    $codexAgentsAuditOutput -match '(?im)^STATUS:\s+LIVE_UPDATE_REQUIRED\s*$' -and
    $codexAgentsAuditOutput -match '(?im)^- LIVE_UPDATE_REQUIRED: codex-agents-template-drift\s*$') {
    $checks.Add('verify-installation reports the exact Codex AGENTS template drift rollout blocker') | Out-Null
} else {
    $failures.Add('Codex AGENTS drift audit should emit LIVE_UPDATE_REQUIRED: codex-agents-template-drift') | Out-Null
}

$claudeGlobalPath = Join-Path $userProfile '.claude\CLAUDE.md'
$claudeGlobalContent = Get-Content -LiteralPath $claudeGlobalPath -Raw -Encoding utf8
if ($claudeGlobalContent -notmatch [regex]::Escape($workspaceRoot) -and $claudeGlobalContent -match 'DEV_HARNESS_WORKSPACE_ROOT' -and $claudeGlobalContent -match '\.assistant') {
    $checks.Add('global Claude instructions resolve the workspace dynamically without an install-time workspace path') | Out-Null
} else {
    $failures.Add('global Claude instructions should not embed the install-time workspace path') | Out-Null
}

$userPreferencesPath = Join-Path $workspaceRoot '.assistant\配置\用户偏好.md'
$projectConventionsPath = Join-Path $workspaceRoot '.assistant\工作流\项目约定.md'
New-Item -ItemType Directory -Path (Split-Path -Parent $userPreferencesPath),(Split-Path -Parent $projectConventionsPath) -Force | Out-Null
[System.IO.File]::WriteAllText($userPreferencesPath, '# user preferences sentinel', (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($projectConventionsPath, '# project conventions sentinel', (New-Object System.Text.UTF8Encoding($false)))
$preferencesHashBefore = (Get-FileHash -LiteralPath $userPreferencesPath -Algorithm SHA256).Hash
$conventionsHashBefore = (Get-FileHash -LiteralPath $projectConventionsPath -Algorithm SHA256).Hash
$fullInstallResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'install.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot = $RepoRoot
    VaultProfile = 'full'
}
if ($fullInstallResult.ExitCode -eq 0 -and
    (Get-FileHash -LiteralPath $userPreferencesPath -Algorithm SHA256).Hash -eq $preferencesHashBefore -and
    (Get-FileHash -LiteralPath $projectConventionsPath -Algorithm SHA256).Hash -eq $conventionsHashBefore) {
    $checks.Add('full install preserves user-owned preferences and project conventions') | Out-Null
} else {
    $failures.Add('full install should preserve user-owned preferences and project conventions') | Out-Null
}

$workspaceSharedMemoryProtocolPath = Join-Path $workspaceRoot '.assistant\工作流\共享记忆协议.md'
$workspaceSharedMemoryProtocolBytes = [System.IO.File]::ReadAllBytes($workspaceSharedMemoryProtocolPath)
try {
    $driftBytes = [System.Text.Encoding]::UTF8.GetBytes("`nDRIFT-LINE")
    [System.IO.File]::WriteAllBytes($workspaceSharedMemoryProtocolPath, @($workspaceSharedMemoryProtocolBytes + $driftBytes))
    $protocolAuditResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
        WorkspaceRoot = $workspaceRoot
        RepoRoot      = $RepoRoot
    }
    $protocolAuditOutput = $protocolAuditResult.Output -join [Environment]::NewLine
} finally {
    [System.IO.File]::WriteAllBytes($workspaceSharedMemoryProtocolPath, $workspaceSharedMemoryProtocolBytes)
}
$protocolMarkerCount = [regex]::Matches($protocolAuditOutput, '(?im)^- LIVE_UPDATE_REQUIRED:').Count
if ($protocolAuditResult.ExitCode -eq 1 -and
    $protocolAuditOutput -match '(?im)^STATUS:\s+LIVE_UPDATE_REQUIRED\s*$' -and
    $protocolAuditOutput -match '(?ms)^Warnings:\r?\n- LIVE_UPDATE_REQUIRED: shim-template-drift\r?\n\r?\nErrors:\r?\n- none(?:\r?\n|$)' -and
    $protocolMarkerCount -eq 1) {
    $checks.Add('verify-installation reports current full-vault protocol drift with the existing single managed-asset marker') | Out-Null
} else {
    $failures.Add('current full-vault protocol drift should emit only LIVE_UPDATE_REQUIRED: shim-template-drift') | Out-Null
}
$protocolRestoreResult = Invoke-RepoScript -UserProfile $userProfile -ScriptPath (Join-Path $RepoRoot 'tests\verify-installation.ps1') -Arguments @{
    WorkspaceRoot = $workspaceRoot
    RepoRoot = $RepoRoot
}
if ($protocolRestoreResult.ExitCode -eq 0 -and ($protocolRestoreResult.Output -join [Environment]::NewLine) -match '(?im)^STATUS:\s+PASS\s*$') {
    $checks.Add('verify-installation returns to PASS after restoring the full-vault protocol bytes') | Out-Null
} else {
    $failures.Add('restored full-vault protocol should return exact installation verification to PASS') | Out-Null
}
} finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}

Write-Output 'Checks:'
if ($checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($check in $checks) {
        Write-Output ('- {0}' -f $check)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $failures) {
    Write-Output ('- {0}' -f $failure)
}

Write-Output ''
Write-Output 'Install Output:'
if ($installResult.Output.Count -eq 0) {
    Write-Output '- none'
} else {
    $installResult.Output | ForEach-Object { Write-Output ([string]$_) }
}

Write-Output ''
Write-Output 'Verify Output:'
if ($verifyResult.Output.Count -eq 0) {
    Write-Output '- none'
} else {
    $verifyResult.Output | ForEach-Object { Write-Output ([string]$_) }
}

exit 1
