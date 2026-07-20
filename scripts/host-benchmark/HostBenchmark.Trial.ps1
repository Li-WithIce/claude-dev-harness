function Remove-HostRawTrace {
    param([string]$TraceRoot,[Parameter(Mandatory)][string]$ResultRoot,[Parameter(Mandatory)][string]$SafetyRoot)
    # Release-qualification-only helper; not part of the installed core runtime.
    if ([string]::IsNullOrWhiteSpace($TraceRoot)) { return $true }
    try {
        $resolvedResult = [IO.Path]::GetFullPath($ResultRoot).TrimEnd('\')
        $resolvedTrace = [IO.Path]::GetFullPath($TraceRoot).TrimEnd('\')
        $resolvedSafety = [IO.Path]::GetFullPath($SafetyRoot).TrimEnd('\')
        $safePrefix = $resolvedResult + '\'
        $safetyPrefix = $resolvedSafety + '\'
        if (-not (Test-Path -LiteralPath $resolvedSafety -PathType Container) -or -not (Test-Path -LiteralPath $resolvedResult -PathType Container) -or -not $resolvedResult.StartsWith($safetyPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not $resolvedTrace.StartsWith($safePrefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedTrace) -cne 'otel-traces') { return $false }
        $safetyCursor = $resolvedResult
        while ($safetyCursor.Equals($resolvedSafety,[StringComparison]::OrdinalIgnoreCase) -or $safetyCursor.StartsWith($safetyPrefix,[StringComparison]::OrdinalIgnoreCase)) {
            $safetyItem = Get-Item -LiteralPath $safetyCursor -Force -ErrorAction Stop
            if (($safetyItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ($safetyCursor.Equals($resolvedSafety,[StringComparison]::OrdinalIgnoreCase)) { break }
            $safetyCursor = [IO.Path]::GetDirectoryName($safetyCursor)
        }
        $cursor = $resolvedTrace
        while (-not (Test-Path -LiteralPath $cursor)) {
            $cursor = [IO.Path]::GetDirectoryName($cursor)
            if ([string]::IsNullOrWhiteSpace($cursor) -or -not ($cursor.Equals($resolvedResult,[StringComparison]::OrdinalIgnoreCase) -or $cursor.StartsWith($safePrefix,[StringComparison]::OrdinalIgnoreCase))) { return $false }
        }
        while ($cursor.Equals($resolvedResult,[StringComparison]::OrdinalIgnoreCase) -or $cursor.StartsWith($safePrefix,[StringComparison]::OrdinalIgnoreCase)) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ($cursor.Equals($resolvedResult,[StringComparison]::OrdinalIgnoreCase)) { break }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
        if (Test-Path -LiteralPath $resolvedTrace) {
            if (-not (Test-Path -LiteralPath $resolvedTrace -PathType Container)) { return $false }
            [IO.Directory]::Delete($resolvedTrace,$true)
        }
        return -not (Test-Path -LiteralPath $resolvedTrace)
    } catch { return $false }
}

function Complete-HostPendingOtlpCleanup {
    param([Parameter(Mandatory)]$Pending)
    $collector = $Pending.collector
    if ($null -eq $collector) { return $false }
    if ($null -ne $collector.process) { [void](Stop-OtlpCollector -Collector $collector) }
    if ($null -ne $collector.process) { return $false }
    $removed = Remove-HostRawTrace -TraceRoot ([string]$Pending.trace_root) -ResultRoot ([string]$Pending.result_root) -SafetyRoot ([string]$Pending.safety_root)
    if (-not $removed) { return $false }
    if ($null -ne $Pending.trial_result) {
        $Pending.trial_result.raw_trace_deleted = $true
        $Pending.trial_result.post_trial_diagnostics = @($Pending.trial_result.post_trial_diagnostics | Where-Object { [string]$_ -cne 'otel-collector-cleanup-pending' })
        if ([string]$Pending.trial_result.diagnostic -ceq 'otel-collector-cleanup-pending') {
            $Pending.trial_result.status = $Pending.prior_status
            $Pending.trial_result.diagnostic = $Pending.prior_diagnostic
            $Pending.trial_result.completion_passed = [bool]$Pending.prior_completion_passed
        }
    }
    return $true
}

$script:HostIsolatedConfigSentinelText = "# isolated host benchmark sentinel`n"
$script:HostIsolatedConfigOwnerPrefix = '.host-config-sentinel-owner-v1-'
$script:HostIsolatedConfigStagingPrefix = '.host-config-sentinel-staging-v1-'
$script:HostIsolatedConfigStagedLeaf = 'config.toml.tmp'

function Test-HostExactUtf8File {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedText)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $actual = [IO.File]::ReadAllBytes($Path)
        $expected = [Text.UTF8Encoding]::new($false).GetBytes($ExpectedText)
        if ($actual.Length -ne $expected.Length) { return $false }
        for ($index=0; $index -lt $actual.Length; $index++) {
            if ($actual[$index] -ne $expected[$index]) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-HostPathAtOrBelow {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root)
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $pathFull.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase) -or $pathFull.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)
}

function Get-HostFileSystemIdentity {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full)) { throw 'host-benchmark-path-physical-identity-unavailable' }
    $fileIdOutput = @(& fsutil file queryFileID $full 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-path-physical-identity-unavailable' }
    $fileIdMatch = [regex]::Match(($fileIdOutput -join "`n"),'(?i)0x[0-9a-f]{32}')
    if (-not $fileIdMatch.Success) { throw 'host-benchmark-path-physical-identity-unavailable' }
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -match '^\\\\\?\\([A-Za-z]:\\)$') { $root = $Matches[1] }
    if ($root -notmatch '^[A-Za-z]:\\$') { throw 'host-benchmark-path-physical-identity-unavailable' }
    $volumeOutput = @(& mountvol $root /L 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-path-physical-identity-unavailable' }
    $volumeMatch = [regex]::Match(($volumeOutput -join "`n"),'(?i)\\\\\?\\Volume\{[0-9a-f-]{36}\}\\')
    if (-not $volumeMatch.Success) { throw 'host-benchmark-path-physical-identity-unavailable' }
    $nameOutput = @(& fsutil file queryFileNameById $volumeMatch.Value $fileIdMatch.Value 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-path-physical-identity-unavailable' }
    $pathMatch = [regex]::Match(($nameOutput -join "`n"),'(?i)\\\\\?\\(?:[A-Za-z]:\\|UNC\\|Volume\{[0-9a-f-]{36}\}\\)[^\r\n]+')
    if (-not $pathMatch.Success) { throw 'host-benchmark-path-physical-identity-unavailable' }
    $physicalPath = $pathMatch.Value.Trim()
    if ($physicalPath.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) {
        $physicalPath = '\\' + $physicalPath.Substring(8)
    } elseif ($physicalPath.StartsWith('\\?\',[StringComparison]::OrdinalIgnoreCase)) {
        $physicalPath = $physicalPath.Substring(4)
    }
    return [ordered]@{volume=$volumeMatch.Value.ToLowerInvariant();file_id=$fileIdMatch.Value.ToLowerInvariant();physical_path=$physicalPath}
}

function Get-HostPhysicalPathInfo {
    param([Parameter(Mandatory)][string]$Path,[switch]$AllowMissing,[switch]$RejectLinks)
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    $tail = [Collections.Generic.List[string]]::new()
    while (-not (Test-Path -LiteralPath $cursor)) {
        if (-not $AllowMissing) { throw 'host-benchmark-path-physical-identity-unavailable' }
        $leaf = [IO.Path]::GetFileName($cursor)
        if ([string]::IsNullOrWhiteSpace($leaf)) { throw 'host-benchmark-path-physical-identity-unavailable' }
        $tail.Insert(0,$leaf)
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { throw 'host-benchmark-path-physical-identity-unavailable' }
        $cursor = $parent
    }
    if ($tail.Count -gt 0 -and -not (Test-Path -LiteralPath $cursor -PathType Container)) { throw 'host-benchmark-path-physical-identity-unavailable' }
    if ($RejectLinks) {
        $probe = $cursor
        while (-not [string]::IsNullOrWhiteSpace($probe)) {
            $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)) { throw 'host-benchmark-path-link-alias-rejected' }
            $parent = [IO.Directory]::GetParent($probe)
            if ($null -eq $parent -or $parent.FullName.Equals($probe,[StringComparison]::OrdinalIgnoreCase)) { break }
            $probe = $parent.FullName
        }
    }
    $identity = Get-HostFileSystemIdentity -Path $cursor
    $physicalPath = [string]$identity.physical_path
    foreach ($segment in $tail) { $physicalPath = Join-Path $physicalPath $segment }
    return [ordered]@{volume=$identity.volume;file_id=$identity.file_id;physical_path=[IO.Path]::GetFullPath($physicalPath)}
}

function Enter-HostCodexHomeMutex {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1,600000)][int]$TimeoutMilliseconds = 10000,
        [string]$FailureCode = 'host-benchmark-auth-home-lock-timeout'
    )
    $physical = Get-HostPhysicalPathInfo -Path $Path -RejectLinks
    $lockBytes = [Text.UTF8Encoding]::new($false).GetBytes(('{0}|{1}' -f [string]$physical.volume,[string]$physical.file_id).ToLowerInvariant())
    $lockHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($lockBytes)).ToLowerInvariant()
    $mutex = [Threading.Mutex]::new($false,"Global\dev-harness.host-benchmark.$lockHash")
    $acquired = $false
    $abandoned = $false
    try { $acquired = $mutex.WaitOne($TimeoutMilliseconds) } catch [Threading.AbandonedMutexException] { $acquired = $true; $abandoned = $true }
    if (-not $acquired) { $mutex.Dispose(); throw $FailureCode }
    return [ordered]@{mutex=$mutex;acquired=$true;abandoned=$abandoned;name="Global\dev-harness.host-benchmark.$lockHash"}
}

function Exit-HostCodexHomeMutex {
    param([AllowNull()][System.Collections.IDictionary]$State)
    if ($null -eq $State) { return }
    try { if ([bool]$State.acquired) { [void]$State.mutex.ReleaseMutex() } } finally { $State.mutex.Dispose() }
}

function Get-HostIsolatedConfigOwnerMetadata {
    param([Parameter(Mandatory)][string]$Name)
    $pattern = '^' + [regex]::Escape($script:HostIsolatedConfigOwnerPrefix) + '(?<volume>[0-9a-f]{32})-(?<file>[0-9a-f]{32})-(?<run>[0-9a-f]{32})$'
    $match = [regex]::Match($Name,$pattern)
    if (-not $match.Success) { return $null }
    return [ordered]@{volume_hex=$match.Groups['volume'].Value;file_id=('0x' + $match.Groups['file'].Value);run_id=$match.Groups['run'].Value}
}

function Get-HostIdentityVolumeHex {
    param([Parameter(Mandatory)][string]$Volume)
    $match = [regex]::Match($Volume,'(?i)\{(?<id>[0-9a-f-]{36})\}')
    if (-not $match.Success) { throw 'host-benchmark-path-physical-identity-unavailable' }
    return $match.Groups['id'].Value.Replace('-','').ToLowerInvariant()
}

function Test-HostIdentityMatchesOwnerMetadata {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Identity,[Parameter(Mandatory)][System.Collections.IDictionary]$Metadata)
    return (Get-HostIdentityVolumeHex -Volume ([string]$Identity.volume)) -ceq [string]$Metadata.volume_hex -and [string]$Identity.file_id -ceq [string]$Metadata.file_id
}

function Test-HostWorkspaceChangePathsSafe {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string[]]$Paths,[Parameter(Mandatory)][object]$PathModule)
    try {
        foreach ($relative in $Paths) {
            if ($relative.StartsWith('__git_index_flag__/',[StringComparison]::Ordinal)) { return $false }
            $resolved = & $PathModule { param($Root,$Path) Resolve-HarnessContainedPath -WorkspaceRoot $Root -Path $Path -Label 'host benchmark changed path' -MustExist File } $Workspace $relative
            $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
            if ($item.PSIsContainer -or -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Resolve-HostTrialStatus {
    param(
        [Parameter(Mandatory)][ValidateSet('bare','v1','v2')][string]$Protocol,
        [bool]$InvocationUnavailable,
        [bool]$ContractFailure,
        [bool]$WriteBoundaryPassed,
        [bool]$SourceBindingFailure,
        [int]$FreshSessions,
        [int]$HostTurns,
        [bool]$ObservationComplete,
        [bool]$WorkflowCompleted,
        [bool]$DirectContractPassed,
        [bool]$V1ContractPassed,
        [bool]$Complete
    )
    $directObservedFailure = $Protocol -cne 'v1' -and ($FreshSessions -gt 1 -or $HostTurns -gt 1 -or ($ObservationComplete -and -not $DirectContractPassed))
    $v1ObservedFailure = $Protocol -ceq 'v1' -and (
        $FreshSessions -gt 5 -or
        $HostTurns -gt 5 -or
        (($ObservationComplete -or $WorkflowCompleted) -and -not $V1ContractPassed)
    )
    $knownFailure = $ContractFailure -or -not $WriteBoundaryPassed -or $SourceBindingFailure -or $directObservedFailure -or $v1ObservedFailure
    if ($knownFailure) { return 'fail' }
    if ($InvocationUnavailable) { return 'unavailable' }
    if ($Complete) { return 'measured' }
    return 'fail'
}

function Assert-HostCodexHomeLayout {
    param([AllowEmptyString()][string]$Path,[switch]$AllowUserConfig,[switch]$AllowInstalledAssets,[switch]$AllowNativeSystemSkills,[switch]$AllowIsolatedHostConfig)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'host-benchmark-auth-home-unavailable' }
    if ($AllowIsolatedHostConfig -and ($AllowUserConfig -or $AllowInstalledAssets)) { throw 'host-benchmark-auth-home-not-isolated' }
    $absolute = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $probe = $absolute
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'host-benchmark-auth-home-reparse-point' }
        $parent = [IO.Directory]::GetParent($probe)
        if ($null -eq $parent -or $parent.FullName.Equals($probe,[StringComparison]::OrdinalIgnoreCase)) { break }
        $probe = $parent.FullName
    }
    $resolved = (Resolve-Path -LiteralPath $absolute).Path.TrimEnd('\')
    $allowedFiles = @('auth.json','models_cache.json','version.json','installation_id','.codex-global-state.json','.codex-global-state.json.bak')
    $allowedDirectories = @('log','tmp','sqlite','cache')
    if ($AllowUserConfig) {
        $allowedFiles += @('config.toml','.personality_migration')
        $allowedDirectories += @('plugins','.claude')
    }
    if ($AllowInstalledAssets) {
        $allowedFiles += @('AGENTS.md','hooks.json','managed_config.toml')
        $allowedDirectories += '.claude'
    }
    $stack = [Collections.Generic.Stack[string]]::new()
    $isolatedConfigSeen = $false
    $isolatedOwnerPath = ''
    $isolatedOwnerMetadata = $null
    foreach ($child in @(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop)) {
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'host-benchmark-auth-home-reparse-point'
        }
        if (-not $child.PSIsContainer -and -not [string]::IsNullOrWhiteSpace([string]$child.LinkType)) { throw 'host-benchmark-auth-home-linked-credential' }
        if ($AllowIsolatedHostConfig -and -not $child.PSIsContainer -and [string]$child.Name -ceq 'config.toml') {
            if (($child.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0 -or -not (Test-HostExactUtf8File -Path $child.FullName -ExpectedText $script:HostIsolatedConfigSentinelText)) { throw 'host-benchmark-auth-home-not-isolated' }
            $isolatedConfigSeen = $true
            continue
        }
        $ownerMetadata = Get-HostIsolatedConfigOwnerMetadata -Name ([string]$child.Name)
        if ($AllowIsolatedHostConfig -and $child.PSIsContainer -and $null -ne $ownerMetadata) {
            if (-not [string]::IsNullOrWhiteSpace($isolatedOwnerPath) -or -not [string]::IsNullOrWhiteSpace([string]$child.LinkType) -or @(Get-ChildItem -LiteralPath $child.FullName -Force -ErrorAction Stop).Count -ne 0) { throw 'host-benchmark-auth-home-not-isolated' }
            $isolatedOwnerPath = $child.FullName
            $isolatedOwnerMetadata = $ownerMetadata
            continue
        }
        if (($AllowUserConfig -or $AllowNativeSystemSkills) -and $child.PSIsContainer -and [string]$child.Name -ceq 'skills') {
            $skillEntries = @(Get-ChildItem -LiteralPath $child.FullName -Force -ErrorAction Stop)
            if ($AllowNativeSystemSkills -and -not $AllowUserConfig -and ($skillEntries.Count -ne 1 -or [string]$skillEntries[0].Name -cne '.system')) { throw 'host-benchmark-auth-home-not-isolated' }
            foreach ($skill in $skillEntries) {
                $managedSkill = [string]$skill.Name -cin @('entry-router','orchestrator','plan','implement','review','test','spec')
                $linked = ($skill.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                if ([string]$skill.Name -ceq '.system' -and $skill.PSIsContainer -and -not $linked) {
                    if ($AllowNativeSystemSkills -and -not $AllowUserConfig) {
                        $nativeSystemDirectories = @('imagegen','openai-docs','plugin-creator','skill-creator','skill-installer')
                        $nativeSystemEntries = @(Get-ChildItem -LiteralPath $skill.FullName -Force -ErrorAction Stop)
                        if ($nativeSystemEntries.Count -ne 6) { throw 'host-benchmark-auth-home-not-isolated' }
                        foreach ($nativeSystemEntry in $nativeSystemEntries) {
                            if (($nativeSystemEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'host-benchmark-auth-home-reparse-point' }
                            if (-not $nativeSystemEntry.PSIsContainer -and -not [string]::IsNullOrWhiteSpace([string]$nativeSystemEntry.LinkType)) { throw 'host-benchmark-auth-home-linked-credential' }
                            if ([string]$nativeSystemEntry.Name -ceq '.codex-system-skills.marker') {
                                if ($nativeSystemEntry.PSIsContainer -or -not (Test-HostExactUtf8File -Path $nativeSystemEntry.FullName -ExpectedText "406e58b4e35d949e`n")) { throw 'host-benchmark-auth-home-not-isolated' }
                            } elseif (-not $nativeSystemEntry.PSIsContainer -or [string]$nativeSystemEntry.Name -cnotin $nativeSystemDirectories) {
                                throw 'host-benchmark-auth-home-not-isolated'
                            } elseif (-not (Test-Path -LiteralPath (Join-Path $nativeSystemEntry.FullName 'SKILL.md') -PathType Leaf)) {
                                throw 'host-benchmark-auth-home-not-isolated'
                            }
                        }
                    }
                    $stack.Push($skill.FullName)
                } elseif ($AllowInstalledAssets -and $managedSkill -and $skill.PSIsContainer -and $linked) {
                    continue
                } else { throw 'host-benchmark-auth-home-not-isolated' }
            }
            continue
        }
        if ($child.PSIsContainer) {
            if ([string]$child.Name -cnotin $allowedDirectories) { throw 'host-benchmark-auth-home-not-isolated' }
            $stack.Push($child.FullName)
        } elseif ([string]$child.Name -cnotin $allowedFiles -and [string]$child.Name -notmatch '^(?:state|goals|logs|memories)_[0-9]+\.sqlite(?:-(?:shm|wal))?$') {
            throw 'host-benchmark-auth-home-not-isolated'
        }
    }
    if ($AllowIsolatedHostConfig -and -not $isolatedConfigSeen) { throw 'host-benchmark-auth-home-not-isolated' }
    if ($AllowIsolatedHostConfig -and -not [string]::IsNullOrWhiteSpace($isolatedOwnerPath)) {
        $configIdentity = Get-HostFileSystemIdentity -Path (Join-Path $resolved 'config.toml')
        if (-not (Test-HostIdentityMatchesOwnerMetadata -Identity $configIdentity -Metadata $isolatedOwnerMetadata)) { throw 'host-benchmark-auth-home-not-isolated' }
    }
    while ($stack.Count -gt 0) {
        foreach ($child in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'host-benchmark-auth-home-reparse-point'
            }
            if (-not $child.PSIsContainer -and -not [string]::IsNullOrWhiteSpace([string]$child.LinkType)) { throw 'host-benchmark-auth-home-linked-credential' }
            if ($child.PSIsContainer) { $stack.Push($child.FullName) }
        }
    }
    $authPath = Join-Path $resolved 'auth.json'
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) { throw 'host-benchmark-auth-home-not-logged-in' }
    $authItem = Get-Item -LiteralPath $authPath -Force -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace([string]$authItem.LinkType)) { throw 'host-benchmark-auth-home-linked-credential' }
    return $resolved
}

function Initialize-HostIsolatedConfigSentinel {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $configPath = Join-Path $resolved 'config.toml'
    $journalEntries = @(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigOwnerPrefix,[StringComparison]::Ordinal) -or $_.Name.StartsWith($script:HostIsolatedConfigStagingPrefix,[StringComparison]::Ordinal) })
    if ($journalEntries.Count -ne 0) { throw 'host-benchmark-auth-home-config-sentinel-recovery-required' }
    if (Test-Path -LiteralPath $configPath) {
        $null = Assert-HostCodexHomeLayout -Path $resolved -AllowNativeSystemSkills -AllowIsolatedHostConfig
        $identity = Get-HostFileSystemIdentity -Path $configPath
        return [ordered]@{path=$configPath;created_by_runner=$false;volume=$identity.volume;file_id=$identity.file_id}
    }
    $null = Assert-HostCodexHomeLayout -Path $resolved -AllowNativeSystemSkills
    $runId = [guid]::NewGuid().ToString('N')
    $stagingPath = Join-Path $resolved ($script:HostIsolatedConfigStagingPrefix + $runId)
    $ownerPath = ''
    $journalPath = $stagingPath
    $journalIdentity = $null
    $tempPath = Join-Path $stagingPath $script:HostIsolatedConfigStagedLeaf
    $tempIdentity = $null
    try {
        [void][IO.Directory]::CreateDirectory($stagingPath)
        $journalIdentity = Get-HostFileSystemIdentity -Path $stagingPath
        $stagingItem = Get-Item -LiteralPath $stagingPath -Force -ErrorAction Stop
        if (($stagingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$stagingItem.LinkType) -or @(Get-ChildItem -LiteralPath $stagingPath -Force -ErrorAction Stop).Count -ne 0) { throw 'staging-marker-invalid' }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($script:HostIsolatedConfigSentinelText)
        $stream = [IO.FileStream]::new($tempPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $tempIdentity = Get-HostFileSystemIdentity -Path $tempPath
        [IO.File]::SetAttributes($tempPath,([IO.File]::GetAttributes($tempPath) -bor [IO.FileAttributes]::ReadOnly))
        $tempItem = Get-Item -LiteralPath $tempPath -Force -ErrorAction Stop
        if (($tempItem.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0 -or ($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$tempItem.LinkType) -or -not (Test-HostExactUtf8File -Path $tempPath -ExpectedText $script:HostIsolatedConfigSentinelText)) { throw 'temp-sentinel-invalid' }
        $ownerName = $script:HostIsolatedConfigOwnerPrefix + (Get-HostIdentityVolumeHex -Volume ([string]$tempIdentity.volume)) + '-' + ([string]$tempIdentity.file_id).Substring(2) + '-' + $runId
        $ownerPath = Join-Path $resolved $ownerName
        $state = [ordered]@{path=$configPath;created_by_runner=$true;volume=$tempIdentity.volume;file_id=$tempIdentity.file_id;owner_path=$ownerPath;owner_volume=$journalIdentity.volume;owner_file_id=$journalIdentity.file_id}
        [IO.Directory]::Move($stagingPath,$ownerPath)
        $journalPath = $ownerPath
        $tempPath = Join-Path $ownerPath $script:HostIsolatedConfigStagedLeaf
        [IO.File]::Move($tempPath,$configPath,$false)
        return $state
    } catch {
        $cleanupFailed = $false
        if (Test-Path -LiteralPath $journalPath -PathType Container) {
            try {
                $journalItem = Get-Item -LiteralPath $journalPath -Force -ErrorAction Stop
                $currentJournalIdentity = Get-HostFileSystemIdentity -Path $journalPath
                $sameJournalIdentity = $null -eq $journalIdentity -or ([string]$currentJournalIdentity.volume -ceq [string]$journalIdentity.volume -and [string]$currentJournalIdentity.file_id -ceq [string]$journalIdentity.file_id)
                $entries = @(Get-ChildItem -LiteralPath $journalPath -Force -ErrorAction Stop)
                if (-not $sameJournalIdentity -or ($journalItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$journalItem.LinkType) -or $entries.Count -gt 1 -or ($entries.Count -eq 1 -and ($entries[0].PSIsContainer -or [string]$entries[0].Name -cne $script:HostIsolatedConfigStagedLeaf -or ($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$entries[0].LinkType)))) { throw 'journal-changed' }
                if ($entries.Count -eq 1) {
                    $currentTempIdentity = Get-HostFileSystemIdentity -Path $entries[0].FullName
                    if ($null -ne $tempIdentity -and ([string]$currentTempIdentity.volume -cne [string]$tempIdentity.volume -or [string]$currentTempIdentity.file_id -cne [string]$tempIdentity.file_id)) { throw 'temp-sentinel-changed' }
                    $attributes = [IO.File]::GetAttributes($entries[0].FullName)
                    $writableAttributes = [IO.FileAttributes]([int]$attributes -band (-bnot [int][IO.FileAttributes]::ReadOnly))
                    if ([int]$writableAttributes -eq 0) { $writableAttributes = [IO.FileAttributes]::Normal }
                    [IO.File]::SetAttributes($entries[0].FullName,$writableAttributes)
                    [IO.File]::Delete($entries[0].FullName)
                }
                [IO.Directory]::Delete($journalPath,$false)
            } catch { $cleanupFailed = $true }
        }
        if (Test-Path -LiteralPath $journalPath) { $cleanupFailed = $true }
        if ($cleanupFailed) { throw 'host-benchmark-auth-home-config-sentinel-cleanup-failed' }
        throw 'host-benchmark-auth-home-not-isolated'
    }
}

function Recover-HostIsolatedConfigSentinel {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $journals = @(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop | Where-Object { $_.Name.StartsWith($script:HostIsolatedConfigOwnerPrefix,[StringComparison]::Ordinal) -or $_.Name.StartsWith($script:HostIsolatedConfigStagingPrefix,[StringComparison]::Ordinal) })
    if ($journals.Count -eq 0) { return $false }
    if ($journals.Count -ne 1) { throw 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    $journal = $journals[0]
    $metadata = Get-HostIsolatedConfigOwnerMetadata -Name ([string]$journal.Name)
    $stagingMatch = [regex]::Match([string]$journal.Name,('^' + [regex]::Escape($script:HostIsolatedConfigStagingPrefix) + '[0-9a-f]{32}$'))
    if (($null -eq $metadata -and -not $stagingMatch.Success) -or -not $journal.PSIsContainer -or ($journal.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$journal.LinkType)) { throw 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    $journalIdentity = Get-HostFileSystemIdentity -Path $journal.FullName
    $contents = @(Get-ChildItem -LiteralPath $journal.FullName -Force -ErrorAction Stop)
    $configPath = Join-Path $resolved 'config.toml'
    $configExists = Test-Path -LiteralPath $configPath
    if ($contents.Count -gt 1 -or ($contents.Count -eq 1 -and ($contents[0].PSIsContainer -or [string]$contents[0].Name -cne $script:HostIsolatedConfigStagedLeaf -or ($contents[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$contents[0].LinkType)))) { throw 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    if ($stagingMatch.Success -and $configExists) { throw 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    if ($null -ne $metadata -and $configExists -and $contents.Count -ne 0) { throw 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    $sentinelPath = if ($contents.Count -eq 1) { $contents[0].FullName } elseif ($configExists) { $configPath } else { '' }
    if ($null -ne $metadata -and -not [string]::IsNullOrWhiteSpace($sentinelPath)) {
        $sentinel = Get-Item -LiteralPath $sentinelPath -Force -ErrorAction Stop
        $sentinelIdentity = Get-HostFileSystemIdentity -Path $sentinelPath
        if ($sentinel.PSIsContainer -or ($sentinel.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$sentinel.LinkType) -or -not (Test-HostExactUtf8File -Path $sentinelPath -ExpectedText $script:HostIsolatedConfigSentinelText) -or -not (Test-HostIdentityMatchesOwnerMetadata -Identity $sentinelIdentity -Metadata $metadata)) { throw 'host-benchmark-auth-home-config-sentinel-recovery-failed' }
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace($sentinelPath)) {
            $attributes = [IO.File]::GetAttributes($sentinelPath)
            $writableAttributes = [IO.FileAttributes]([int]$attributes -band (-bnot [int][IO.FileAttributes]::ReadOnly))
            if ([int]$writableAttributes -eq 0) { $writableAttributes = [IO.FileAttributes]::Normal }
            [IO.File]::SetAttributes($sentinelPath,$writableAttributes)
            [IO.File]::Delete($sentinelPath)
            if (Test-Path -LiteralPath $sentinelPath) { throw 'sentinel-delete-failed' }
        }
        $currentJournal = Get-Item -LiteralPath $journal.FullName -Force -ErrorAction Stop
        $currentJournalIdentity = Get-HostFileSystemIdentity -Path $journal.FullName
        if ([string]$currentJournalIdentity.volume -cne [string]$journalIdentity.volume -or [string]$currentJournalIdentity.file_id -cne [string]$journalIdentity.file_id -or ($currentJournal.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$currentJournal.LinkType) -or @(Get-ChildItem -LiteralPath $journal.FullName -Force -ErrorAction Stop).Count -ne 0) { throw 'journal-changed' }
        [IO.Directory]::Delete($journal.FullName,$false)
        if (Test-Path -LiteralPath $journal.FullName) { throw 'journal-delete-failed' }
    } catch { throw 'host-benchmark-auth-home-config-sentinel-cleanup-failed' }
    $null = Assert-HostCodexHomeLayout -Path $resolved -AllowNativeSystemSkills
    return $true
}

function Complete-HostIsolatedConfigSentinel {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $configPath = [IO.Path]::GetFullPath([string]$State.path)
    try {
        $identity = Get-HostFileSystemIdentity -Path $configPath
        if ([string]$identity.volume -cne [string]$State.volume -or [string]$identity.file_id -cne [string]$State.file_id) { throw 'changed' }
        $codexHome = [IO.Path]::GetDirectoryName($configPath)
        $null = Assert-HostCodexHomeLayout -Path $codexHome -AllowNativeSystemSkills -AllowIsolatedHostConfig
        if ([bool]$State.created_by_runner) {
            $ownerPath = [IO.Path]::GetFullPath([string]$State.owner_path)
            $owner = Get-Item -LiteralPath $ownerPath -Force -ErrorAction Stop
            $ownerIdentity = Get-HostFileSystemIdentity -Path $ownerPath
            if (-not $owner.PSIsContainer -or ($owner.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$owner.LinkType) -or @(Get-ChildItem -LiteralPath $ownerPath -Force -ErrorAction Stop).Count -ne 0 -or [string]$ownerIdentity.volume -cne [string]$State.owner_volume -or [string]$ownerIdentity.file_id -cne [string]$State.owner_file_id) { throw 'changed' }
        }
    } catch { throw 'host-benchmark-auth-home-config-sentinel-changed' }
    if (-not [bool]$State.created_by_runner) { return $true }
    try {
        $attributes = [IO.File]::GetAttributes($configPath)
        $writableAttributes = [IO.FileAttributes]([int]$attributes -band (-bnot [int][IO.FileAttributes]::ReadOnly))
        if ([int]$writableAttributes -eq 0) { $writableAttributes = [IO.FileAttributes]::Normal }
        [IO.File]::SetAttributes($configPath,$writableAttributes)
        [IO.File]::Delete($configPath)
        if (Test-Path -LiteralPath $configPath) { throw 'delete-failed' }
        $owner = Get-Item -LiteralPath $ownerPath -Force -ErrorAction Stop
        $ownerIdentity = Get-HostFileSystemIdentity -Path $ownerPath
        if (($owner.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$owner.LinkType) -or @(Get-ChildItem -LiteralPath $ownerPath -Force -ErrorAction Stop).Count -ne 0 -or [string]$ownerIdentity.volume -cne [string]$State.owner_volume -or [string]$ownerIdentity.file_id -cne [string]$State.owner_file_id) { throw 'owner-marker-changed' }
        [IO.Directory]::Delete($ownerPath,$false)
        if (Test-Path -LiteralPath $ownerPath) { throw 'owner-delete-failed' }
    } catch {
        try {
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                $identity = Get-HostFileSystemIdentity -Path $configPath
                if ([string]$identity.volume -ceq [string]$State.volume -and [string]$identity.file_id -ceq [string]$State.file_id -and (Test-HostExactUtf8File -Path $configPath -ExpectedText $script:HostIsolatedConfigSentinelText)) {
                    [IO.File]::SetAttributes($configPath,([IO.File]::GetAttributes($configPath) -bor [IO.FileAttributes]::ReadOnly))
                }
            }
        } catch {}
        throw 'host-benchmark-auth-home-config-sentinel-cleanup-failed'
    }
    return $true
}

function Assert-HostCodexHome {
    param(
        [AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ScratchRoot,
        [switch]$AllowUserConfig,
        [switch]$AllowInstalledAssets,
        [switch]$AllowNativeSystemSkills,
        [switch]$AllowIsolatedHostConfig
    )
    $resolved = Assert-HostCodexHomeLayout -Path $Path -AllowUserConfig:$AllowUserConfig -AllowInstalledAssets:$AllowInstalledAssets -AllowNativeSystemSkills:$AllowNativeSystemSkills -AllowIsolatedHostConfig:$AllowIsolatedHostConfig
    $resolvedPhysical = Get-HostPhysicalPathInfo -Path $resolved -RejectLinks
    foreach ($unsafeRoot in @($RepoRoot,$ScratchRoot)) {
        $unsafePhysical = Get-HostPhysicalPathInfo -Path $unsafeRoot -RejectLinks
        if ((Test-HostPathAtOrBelow -Path ([string]$resolvedPhysical.physical_path) -Root ([string]$unsafePhysical.physical_path)) -or (Test-HostPathAtOrBelow -Path ([string]$unsafePhysical.physical_path) -Root ([string]$resolvedPhysical.physical_path))) { throw 'host-benchmark-auth-home-unsafe-location' }
    }
    $candidateAuthIdentity = Get-HostFileSystemIdentity -Path (Join-Path $resolved 'auth.json')
    $candidateAuthDigest = (Get-FileHash -LiteralPath (Join-Path $resolved 'auth.json') -Algorithm SHA256 -ErrorAction Stop).Hash
    $defaultHome = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) { '' } else { Join-Path $env:USERPROFILE '.codex' }
    foreach ($unsafeHome in @([Environment]::GetEnvironmentVariable('CODEX_HOME',[EnvironmentVariableTarget]::Process),$defaultHome)) {
        if (-not [string]::IsNullOrWhiteSpace($unsafeHome) -and [IO.Path]::GetFullPath($unsafeHome).TrimEnd('\').Equals($resolved,[StringComparison]::OrdinalIgnoreCase)) { throw 'host-benchmark-auth-home-not-dedicated' }
        if (-not [string]::IsNullOrWhiteSpace($unsafeHome)) {
            $unsafeAuth = Join-Path $unsafeHome 'auth.json'
            if (Test-Path -LiteralPath $unsafeAuth -PathType Leaf) {
                $unsafeItem = Get-Item -LiteralPath $unsafeAuth -Force -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace([string]$unsafeItem.LinkType)) { throw 'host-benchmark-auth-home-not-dedicated' }
                $unsafeIdentity = Get-HostFileSystemIdentity -Path $unsafeAuth
                $sameAuth = [string]$unsafeIdentity.volume -ceq [string]$candidateAuthIdentity.volume -and [string]$unsafeIdentity.file_id -ceq [string]$candidateAuthIdentity.file_id
                $sameAuthBytes = [string](Get-FileHash -LiteralPath $unsafeAuth -Algorithm SHA256 -ErrorAction Stop).Hash -ceq [string]$candidateAuthDigest
                $unsafePhysicalHome = [IO.Path]::GetDirectoryName([string]$unsafeIdentity.physical_path)
                if ($sameAuth -or $sameAuthBytes -or (Test-HostPathAtOrBelow -Path ([string]$resolvedPhysical.physical_path) -Root $unsafePhysicalHome) -or (Test-HostPathAtOrBelow -Path $unsafePhysicalHome -Root ([string]$resolvedPhysical.physical_path))) { throw 'host-benchmark-auth-home-not-dedicated' }
            }
        }
    }
    $savedHome = [Environment]::GetEnvironmentVariable('USERPROFILE',[EnvironmentVariableTarget]::Process)
    $savedUnixHome = [Environment]::GetEnvironmentVariable('HOME',[EnvironmentVariableTarget]::Process)
    $savedCodexHome = [Environment]::GetEnvironmentVariable('CODEX_HOME',[EnvironmentVariableTarget]::Process)
    $credentialVariables = @('CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_API_KEY','CODEX_EXECUTABLE','CODEX_THREAD_ID','CODEX_INTERNAL_ORIGINATOR_OVERRIDE','CODEX_SHELL')
    $savedCredentials = [ordered]@{}
    try {
        foreach ($name in $credentialVariables) {
            $savedCredentials[$name] = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable($name,$null,[EnvironmentVariableTarget]::Process)
        }
        $env:USERPROFILE = if ($AllowUserConfig -or $AllowInstalledAssets) { [IO.Path]::GetDirectoryName($resolved) } else { $resolved }
        if ($AllowUserConfig -or $AllowInstalledAssets) { $env:HOME = $env:USERPROFILE }
        $env:CODEX_HOME = $resolved
        $status = @(& codex login status 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-auth-home-not-logged-in' }
        $null = Assert-HostCodexHomeLayout -Path $resolved -AllowUserConfig:$AllowUserConfig -AllowInstalledAssets:$AllowInstalledAssets -AllowNativeSystemSkills:$AllowNativeSystemSkills -AllowIsolatedHostConfig:$AllowIsolatedHostConfig
    } finally {
        [Environment]::SetEnvironmentVariable('USERPROFILE',$savedHome,[EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('HOME',$savedUnixHome,[EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('CODEX_HOME',$savedCodexHome,[EnvironmentVariableTarget]::Process)
        foreach ($entry in $savedCredentials.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key,$entry.Value,[EnvironmentVariableTarget]::Process) }
    }
    return $resolved
}

function Get-InstalledDesktopProfileRoot {
    param([Parameter(Mandatory)][string]$CodexHome)
    $resolved = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
    if ([IO.Path]::GetFileName($resolved) -cne '.codex') { throw 'host-benchmark-installed-profile-invalid' }
    $profileRoot = [IO.Path]::GetDirectoryName($resolved)
    if ([string]::IsNullOrWhiteSpace($profileRoot) -or -not (Test-Path -LiteralPath $profileRoot -PathType Container)) { throw 'host-benchmark-installed-profile-invalid' }
    $profileItem = Get-Item -LiteralPath $profileRoot -Force -ErrorAction Stop
    if (($profileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'host-benchmark-installed-profile-reparse-point' }
    return $profileRoot
}

function Get-InstalledDesktopUserConfigBinding {
    param([Parameter(Mandatory)][string]$CodexHome)
    $configPath = Join-Path $CodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $configPath)) { return [ordered]@{status='absent';digest=$null} }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'host-benchmark-installed-config-invalid' }
    $item = Get-Item -LiteralPath $configPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$item.LinkType) -or $item.Length -gt 1MB) { throw 'host-benchmark-installed-config-invalid' }
    return [ordered]@{status='present';digest=('sha256:' + (Get-FileHash -LiteralPath $configPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant())}
}

function Test-InstalledDesktopUserConfigBinding {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Expected,[Parameter(Mandatory)][System.Collections.IDictionary]$Actual)
    return [string]$Expected.status -ceq [string]$Actual.status -and [string]$Expected.digest -ceq [string]$Actual.digest
}

function Assert-InstalledDesktopProfileReady {
    param([Parameter(Mandatory)][string]$CodexHome)
    $profileRoot = Get-InstalledDesktopProfileRoot -CodexHome $CodexHome
    $null = Assert-HostCodexHomeLayout -Path $CodexHome -AllowUserConfig
    $null = Get-InstalledDesktopUserConfigBinding -CodexHome $CodexHome
    foreach ($relative in @('AGENTS.md','hooks.json','managed_config.toml')) {
        if (Test-Path -LiteralPath (Join-Path $CodexHome $relative)) { throw 'host-benchmark-installed-profile-not-clean' }
    }
    foreach ($container in @((Join-Path $CodexHome '.claude'),(Join-Path $profileRoot '.claude'),(Join-Path $profileRoot '.agents'))) {
        if (-not (Test-Path -LiteralPath $container)) { continue }
        if (-not (Test-Path -LiteralPath $container -PathType Container)) { throw 'host-benchmark-installed-profile-not-clean' }
        $rootItem = Get-Item -LiteralPath $container -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or @((Get-ChildItem -LiteralPath $container -Force -Recurse -ErrorAction Stop) | Where-Object { -not $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -ne 0) { throw 'host-benchmark-installed-profile-not-clean' }
    }
    $stateRoot = Join-Path $profileRoot '.dev-harness'
    foreach ($name in @('install-transaction.json','uninstall-transaction.json')) {
        if (Test-Path -LiteralPath (Join-Path $stateRoot $name) -PathType Leaf) { throw 'host-benchmark-installed-profile-transaction-pending' }
    }
    $registryPath = Join-Path $stateRoot 'install-registry.json'
    if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
        try { $registry = [IO.File]::ReadAllText($registryPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 50 } catch { throw 'host-benchmark-installed-profile-registry-invalid' }
        if ($registry -isnot [Collections.IDictionary] -or $registry.workspaces -isnot [Collections.IDictionary] -or @($registry.workspaces.Keys).Count -ne 0) { throw 'host-benchmark-installed-profile-not-clean' }
    }
    return $profileRoot
}

function Test-InstalledDesktopWorkspaceRegistered {
    param([Parameter(Mandatory)][string]$CodexHome,[Parameter(Mandatory)][string]$Workspace)
    $profileRoot = Get-InstalledDesktopProfileRoot -CodexHome $CodexHome
    $registryPath = Join-Path $profileRoot '.dev-harness\install-registry.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { return $false }
    try { $registry = [IO.File]::ReadAllText($registryPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 50 } catch { throw 'host-benchmark-installed-profile-registry-invalid' }
    if ($registry -isnot [Collections.IDictionary] -or $registry.workspaces -isnot [Collections.IDictionary]) { throw 'host-benchmark-installed-profile-registry-invalid' }
    $expected = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
    foreach ($entry in @($registry.workspaces.Values)) {
        if ($entry -isnot [Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$entry.workspace_root)) { throw 'host-benchmark-installed-profile-registry-invalid' }
        if ([IO.Path]::GetFullPath([string]$entry.workspace_root).TrimEnd('\').Equals($expected,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-InstalledDesktopPendingRecovery {
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $profileRoot = Get-InstalledDesktopProfileRoot -CodexHome $CodexHome
    $journalPath = Join-Path $profileRoot '.dev-harness\install-transaction.json'
    if (-not (Test-Path -LiteralPath $journalPath)) { return $null }
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { throw 'host-benchmark-installed-recovery-invalid' }
    try { $journal = [IO.File]::ReadAllText($journalPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 50 } catch { throw 'host-benchmark-installed-recovery-invalid' }
    if ($journal -isnot [Collections.IDictionary] -or [string]$journal.schema_version -cne 'install-transaction/v1.1') { throw 'host-benchmark-installed-recovery-invalid' }
    $expectedProfile = [IO.Path]::GetFullPath($profileRoot).TrimEnd('\')
    $expectedWorkspace = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
    $expectedRepo = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
    try {
        $journalProfile = [IO.Path]::GetFullPath([string]$journal.user_profile).TrimEnd('\')
        $journalWorkspace = [IO.Path]::GetFullPath([string]$journal.workspace_root).TrimEnd('\')
        $journalRepo = [IO.Path]::GetFullPath([string]$journal.repo_root).TrimEnd('\')
        $manifestPath = [IO.Path]::GetFullPath([string]$journal.manifest_path)
    } catch { throw 'host-benchmark-installed-recovery-invalid' }
    if (-not $journalProfile.Equals($expectedProfile,[StringComparison]::OrdinalIgnoreCase) -or -not $journalWorkspace.Equals($expectedWorkspace,[StringComparison]::OrdinalIgnoreCase) -or -not $journalRepo.Equals($expectedRepo,[StringComparison]::OrdinalIgnoreCase)) { throw 'host-benchmark-installed-recovery-invalid' }
    $backupRoot = Join-Path $profileRoot '.dev-harness\backups'
    if (-not (Test-HostPathAtOrBelow -Path $manifestPath -Root $backupRoot) -or (Split-Path -Leaf $manifestPath) -cne 'install-manifest.json' -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'host-benchmark-installed-recovery-invalid' }
    $manifestPhysical = Get-HostPhysicalPathInfo -Path $manifestPath -RejectLinks
    $backupPhysical = Get-HostPhysicalPathInfo -Path $backupRoot -RejectLinks
    if (-not (Test-HostPathAtOrBelow -Path ([string]$manifestPhysical.physical_path) -Root ([string]$backupPhysical.physical_path))) { throw 'host-benchmark-installed-recovery-invalid' }
    return [ordered]@{manifest_path=$manifestPath}
}

function Invoke-InstalledDesktopTrialRecovery {
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Recovery
    )
    $profileRoot = Get-InstalledDesktopProfileRoot -CodexHome $CodexHome
    $saved = [ordered]@{}
    foreach ($name in @('USERPROFILE','HOME','CODEX_HOME')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process) }
    try {
        $before = (Get-FileHash -LiteralPath (Join-Path $CodexHome 'auth.json') -Algorithm SHA256 -ErrorAction Stop).Hash
        $env:USERPROFILE = $profileRoot
        $env:HOME = $profileRoot
        $env:CODEX_HOME = $CodexHome
        $output = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'uninstall.ps1') -RecoveryManifestPath ([string]$Recovery.manifest_path) -RepoRoot $RepoRoot 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-installed-recovery-failed' }
        $after = (Get-FileHash -LiteralPath (Join-Path $CodexHome 'auth.json') -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($after -cne $before) { throw 'host-benchmark-installed-recovery-changed-auth' }
        $null = Assert-InstalledDesktopProfileReady -CodexHome $CodexHome
        return $true
    } finally {
        foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key,$entry.Value,[EnvironmentVariableTarget]::Process) }
    }
}

function Invoke-InstalledDesktopTrialCleanup {
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $profileRoot = Get-InstalledDesktopProfileRoot -CodexHome $CodexHome
    $saved = [ordered]@{}
    foreach ($name in @('USERPROFILE','HOME','CODEX_HOME')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process) }
    try {
        $before = (Get-FileHash -LiteralPath (Join-Path $CodexHome 'auth.json') -Algorithm SHA256 -ErrorAction Stop).Hash
        $env:USERPROFILE = $profileRoot
        $env:HOME = $profileRoot
        $env:CODEX_HOME = $CodexHome
        $output = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'uninstall.ps1') -WorkspaceRoot $Workspace -RepoRoot $RepoRoot 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-installed-uninstall-failed' }
        $after = (Get-FileHash -LiteralPath (Join-Path $CodexHome 'auth.json') -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($after -cne $before) { throw 'host-benchmark-installed-uninstall-changed-auth' }
        $null = Assert-InstalledDesktopProfileReady -CodexHome $CodexHome
        return $true
    } finally {
        foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key,$entry.Value,[EnvironmentVariableTarget]::Process) }
    }
}

function Invoke-InstalledDesktopRolloutPromotion {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Workspace,
        [AllowEmptyString()][string]$EligibilityReportPath
    )
    if ([string]::IsNullOrWhiteSpace($EligibilityReportPath)) { throw 'host-benchmark-installed-rollout-report-missing' }
    if (-not [IO.Path]::IsPathRooted($EligibilityReportPath) -or -not (Test-Path -LiteralPath $EligibilityReportPath -PathType Leaf)) { throw 'host-benchmark-installed-rollout-report-unavailable' }
    $output = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'scripts\promote-v2-rollout-report.ps1') -RepoRoot $RepoRoot -WorkspaceRoot $Workspace -ReportPath $EligibilityReportPath 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-installed-rollout-promotion-failed' }
    try { $result = ($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 20 } catch { throw 'host-benchmark-installed-rollout-promotion-invalid' }
    if ([string]$result.status -cne 'pass' -or [string]$result.source_revision -cnotmatch '^[0-9a-f]{40,64}$' -or [string]$result.report_digest -cnotmatch '^sha256:[0-9a-f]{64}$' -or [string]$result.file_digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'host-benchmark-installed-rollout-promotion-invalid' }
    return $result
}

function Invoke-InstalledDesktopInstall {
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $profileRoot = Get-InstalledDesktopProfileRoot -CodexHome $CodexHome
    $authPath = Join-Path $CodexHome 'auth.json'
    $before = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256 -ErrorAction Stop).Hash
    $configBefore = Get-InstalledDesktopUserConfigBinding -CodexHome $CodexHome
    $installCommandOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'install.ps1') -WorkspaceRoot $Workspace -RepoRoot $RepoRoot -Preset core 2>&1 | ForEach-Object { [string]$_ })
    $installExit = $LASTEXITCODE
    try {
        $afterInstall = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $configAfterInstall = Get-InstalledDesktopUserConfigBinding -CodexHome $CodexHome
    } catch { throw 'host-benchmark-installed-install-profile-integrity-failed' }
    if ($afterInstall -cne $before) { throw 'host-benchmark-installed-install-changed-auth' }
    if (-not (Test-InstalledDesktopUserConfigBinding -Expected $configBefore -Actual $configAfterInstall)) { throw 'host-benchmark-installed-install-changed-config' }
    if ($installExit -ne 0) { throw 'host-benchmark-installed-install-failed' }
    $null = Assert-HostCodexHomeLayout -Path $CodexHome -AllowUserConfig -AllowInstalledAssets
    $verifyOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'tests\verify-installation.ps1') -WorkspaceRoot $Workspace -RepoRoot $RepoRoot -UserProfileRoot $profileRoot -Scope All 2>&1 | ForEach-Object { [string]$_ })
    $verifyExit = $LASTEXITCODE
    try {
        $afterVerify = (Get-FileHash -LiteralPath $authPath -Algorithm SHA256 -ErrorAction Stop).Hash
        $configAfterVerify = Get-InstalledDesktopUserConfigBinding -CodexHome $CodexHome
    } catch { throw 'host-benchmark-installed-verification-profile-integrity-failed' }
    if ($afterVerify -cne $before) { throw 'host-benchmark-installed-verification-changed-auth' }
    if (-not (Test-InstalledDesktopUserConfigBinding -Expected $configBefore -Actual $configAfterVerify)) { throw 'host-benchmark-installed-verification-changed-config' }
    if ($verifyExit -ne 0 -or ($verifyOutput -join "`n") -cnotmatch '(?m)^STATUS: PASS\s*$') { throw 'host-benchmark-installed-verification-failed' }
    return [ordered]@{install_status='pass';verification_status='pass';auth_unchanged=$true}
}

function Invoke-InstalledDesktopRouteProbe {
    param(
        [Parameter(Mandatory)][ValidateSet('v1','v2')][string]$Protocol,
        [Parameter(Mandatory)][string]$Workspace
    )
    foreach ($name in @('HARNESS_PROTOCOL','HARNESS_V2_ELIGIBILITY_REPORT','DEV_HARNESS_WORKSPACE_ROOT','WORKSPACE_ROOT')) {
        if ($null -ne [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)) { throw 'host-benchmark-installed-protocol-environment-leaked' }
    }
    $shim = Join-Path $Workspace '.assistant\entry\task.ps1'
    if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) { throw 'host-benchmark-installed-task-shim-missing' }
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$shim,'protocol','-AsJson')
    if ($Protocol -ceq 'v1') { $arguments += @('-TaskId','host-benchmark-fixed-workflow') }
    $output = @(& pwsh @arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-installed-route-probe-failed' }
    try { $route = ($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 20 } catch { throw 'host-benchmark-installed-route-probe-invalid' }
    $valid = [string]$route.requested_protocol -ceq 'auto'
    if ($Protocol -ceq 'v2') {
        $valid = $valid -and [string]$route.detected_protocol -ceq 'new' -and [string]$route.selected_protocol -ceq 'v2' -and [string]$route.reason -ceq 'eligible-rollout-report' -and [string]$route.rollout_eligibility.status -ceq 'pass'
    } else {
        $valid = $valid -and [string]$route.detected_protocol -ceq 'v1' -and [string]$route.selected_protocol -ceq 'v1' -and [string]$route.reason -ceq 'existing-v1-plan' -and [string]$route.rollout_eligibility.status -ceq 'not-required'
    }
    if (-not $valid) { throw 'host-benchmark-installed-route-probe-mismatch' }
    return [ordered]@{
        requested_protocol=[string]$route.requested_protocol
        detected_protocol=[string]$route.detected_protocol
        selected_protocol=[string]$route.selected_protocol
        reason=[string]$route.reason
        rollout_status=[string]$route.rollout_eligibility.status
        report_digest=$route.rollout_eligibility.report_digest
    }
}

function Initialize-HostWorkspaceBaseline {
    param([Parameter(Mandatory)][string]$Workspace)
    [void](Invoke-HostGit -Root $Workspace -Arguments @('config','core.hooksPath','NUL'))
    [void](Invoke-HostGit -Root $Workspace -Arguments @('config','core.longpaths','true'))
    [void](Invoke-HostGit -Root $Workspace -Arguments @('config','user.name','Harness Benchmark'))
    [void](Invoke-HostGit -Root $Workspace -Arguments @('config','user.email','harness-benchmark@example.invalid'))
    [void](Invoke-HostGit -Root $Workspace -Arguments @('add','--all','--force','--','.'))
    [void](Invoke-HostGit -Root $Workspace -Arguments @('commit','--quiet','--no-gpg-sign','-m','host benchmark baseline'))
    return (@(Invoke-HostGit -Root $Workspace -Arguments @('rev-parse','HEAD')) -join '').Trim()
}

function Get-HostWorkspaceChanges {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$BaselineRevision)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($arguments in @(
        @('-c','core.quotepath=false','diff',$BaselineRevision,'--name-only','--'),
        @('-c','core.quotepath=false','diff','--cached',$BaselineRevision,'--name-only','--'),
        @('-c','core.quotepath=false','ls-files','--others','--exclude-standard','--'),
        @('-c','core.quotepath=false','ls-files','--others','--ignored','--exclude-standard','--')
    )) {
        foreach ($path in @(Invoke-HostGit -Root $Workspace -Arguments $arguments)) {
            $normalized = ([string]$path).Replace('\','/')
            if ($normalized.Length -gt 0) { [void]$paths.Add($normalized) }
        }
    }
    foreach ($line in @(Invoke-HostGit -Root $Workspace -Arguments @('-c','core.quotepath=false','ls-files','-v','--'))) {
        $entry = [string]$line
        if ($entry -cnotmatch '^H ') {
            $path = if ($entry.Length -gt 2) { $entry.Substring(2).Replace('\','/') } else { 'unknown' }
            [void]$paths.Add('__git_index_flag__/' + $path)
        }
    }
    return @($paths | Sort-Object)
}

function Initialize-V1FixedWorkflowFixture {
    param([Parameter(Mandatory)][string]$Workspace)
    $taskId = 'host-benchmark-fixed-workflow'
    $taskRoot = Join-Path $Workspace "docs\tasks\$taskId"
    [void][IO.Directory]::CreateDirectory($taskRoot)
    $planPath = Join-Path $taskRoot 'plan.md'
    $updated = Get-Date -Format 'yyyy-MM-dd'
    $plan = @"
---
task_id: $taskId
stage: PLAN
tool: codex
tool_profile: harness-default-codex
model: inherit
updated: $updated
---
# Fixed Host Benchmark Workflow

## Clarification
- 验收标准: src/value.txt 的精确 UTF-8 字节由 alpha 改为 beta，并由真实命令验证。
- 非目标: 不改动其他用户文件，不迁移协议，不执行生产操作。
- 受影响目录: src/value.txt 与当前任务所需的 v1 artifact/runtime。
- 回滚策略: 删除隔离 benchmark workspace；不影响真实工作区。
- ui: not-applicable

## User Confirmation
- status: confirmed

## Plan
- 使用既有五阶段 v1 workflow 完成已授权的单文件可逆修改。

## Verification
- 使用真实字节检查确认 src/value.txt 只包含 beta。

## Risks
- none

## Plan Review

## Implementation Notes

## Code Review
"@
    [IO.File]::WriteAllText($planPath,$plan,[Text.UTF8Encoding]::new($true))
    $advance = Join-Path $Workspace '.assistant\entry\advance-stage.ps1'
    $output = @(& pwsh -NoLogo -NoProfile -NonInteractive -File $advance -TaskId $taskId -ExpectedStage PLAN -SyncOnly -ActivateCurrent 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw 'host-benchmark v1 fixture activation failed' }
    return [ordered]@{task_id=$taskId;plan_path=$planPath}
}

function Get-V1FixedWorkflowStage {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$TaskId)
    $resolution = Get-HarnessProtocolResolution -WorkspaceRoot $Workspace -RepoRoot $RepoRoot -TaskId $TaskId -RequestedProtocol v1
    if ([string]$resolution.detected_protocol -cne 'v1' -or [string]$resolution.selected_protocol -cne 'v1') { throw 'host-benchmark v1 artifact resolution failed' }
    return [string]$resolution.v1_stage
}

function Get-V1FixedWorkflowNextStage {
    param([Parameter(Mandatory)][string]$Stage)
    $stages = @('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST','DONE')
    $index = [array]::IndexOf($stages,$Stage)
    if ($index -lt 0 -or $index -ge ($stages.Count - 1)) { return '' }
    return $stages[$index + 1]
}

function Test-V1FixedWorkflowComplete {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$TaskId)
    return (Get-V1FixedWorkflowStage -Workspace $Workspace -RepoRoot $RepoRoot -TaskId $TaskId) -ceq 'DONE'
}

function Test-V1RuntimeState {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][string]$ExpectedStage)
    try {
        $runtimeRoot = Join-Path $Workspace '.assistant\运行时'
        $current = Get-CanonicalCurrentTaskState -Path (Join-Path $runtimeRoot '当前任务.md')
        $records = @(Get-CanonicalTaskRuntimeRecords -TasksDirectory (Join-Path $runtimeRoot 'tasks') | Where-Object { [string]$_.TaskId -ceq $TaskId })
        if ($records.Count -ne 1 -or -not [bool]$records[0].IsValid -or [string]$records[0].Stage -cne $ExpectedStage) { return $false }
        if ($ExpectedStage -ceq 'DONE') {
            if ([string]$current.SchemaVersion -cne 'current-task-pointer/v1.1' -or [string]$current.TaskId -cne 'none' -or [string]$current.TaskName -cne '无' -or [string]$current.Stage -cne '空闲' -or [string]$current.CurrentDoc -cne 'none' -or [string]$current.Tool -cne 'none' -or [string]$current.EntryHost -cne 'unknown' -or [string]$current.NextStep -cne '等待新任务' -or [string]$current.Writer -cne 'advance-stage') { return $false }
        } elseif ([string]$current.SchemaVersion -cne 'current-task-pointer/v1.1' -or [string]$current.TaskId -cne $TaskId -or [string]$current.Stage -cne $ExpectedStage) { return $false }
        $indexPath = Join-Path $runtimeRoot '恢复索引.md'
        if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { return $false }
        $indexText = [IO.File]::ReadAllText($indexPath,[Text.UTF8Encoding]::new($false,$true))
        $indexLines = @($indexText -split '\r?\n')
        $taskLine = '- task_id: ' + [char]96 + [string]$current.TaskId + [char]96
        return $indexLines -ccontains 'schema_version: recovery-index/v1.1' -and
            $indexLines -ccontains 'writer: advance-stage' -and
            $indexLines -ccontains $taskLine -and
            $indexLines -ccontains ('- 状态: ' + [string]$current.Stage) -and
            $indexLines -ccontains ('- 当前文档: ' + [string]$current.CurrentDoc) -and
            $indexLines -ccontains '## 未完成任务 Top 3' -and
            $indexLines -ccontains '- 无'
    } catch { return $false }
}

function Invoke-HostTrial {
    param(
        [Parameter(Mandatory)][ValidateSet('bare','v1','v2')][string]$Protocol,
        [Parameter(Mandatory)][int]$Trial,
        [Parameter(Mandatory)][string]$ScratchRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$CollectorPath,
        [string]$CodexHome = '',
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Reasoning,
        [Parameter(Mandatory)][int]$MaxRoundTrips,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$ExpectedCodexVersion,
        [bool]$SourceBindingRequired = $false,
        [string]$SourceRevision = '',
        [string]$SourceCommitTree = '',
        [ValidateSet('cognitive-fast-path','installed-desktop-path')][string]$BenchmarkPath = 'cognitive-fast-path',
        [AllowEmptyString()][string]$EligibilityReportPath = '',
        [AllowEmptyString()][string]$ExpectedRolloutReportDigest = '',
        [AllowEmptyString()][string]$ExpectedRolloutFileDigest = ''
    )
    $installedMode = $BenchmarkPath -ceq 'installed-desktop-path'
    $trialRoot = Join-Path $ScratchRoot ("$Protocol-$Trial")
    $workspace = Join-Path $trialRoot 'workspace'
    $userRoot = Join-Path $trialRoot 'user'
    $resultRoot = Join-Path $trialRoot 'results'
    [void][IO.Directory]::CreateDirectory((Join-Path $workspace 'src'))
    [void][IO.Directory]::CreateDirectory($userRoot)
    [void][IO.Directory]::CreateDirectory($resultRoot)
    if ($installedMode) {
        $profileRoot = Assert-InstalledDesktopProfileReady -CodexHome $CodexHome
        $profileConfigBinding = Get-InstalledDesktopUserConfigBinding -CodexHome $CodexHome
        $profilePhysical = Get-HostPhysicalPathInfo -Path $profileRoot -RejectLinks
        foreach ($unsafeRoot in @($RepoRoot,$ScratchRoot)) {
            $unsafePhysical = Get-HostPhysicalPathInfo -Path $unsafeRoot -RejectLinks
            if ((Test-HostPathAtOrBelow -Path ([string]$profilePhysical.physical_path) -Root ([string]$unsafePhysical.physical_path)) -or (Test-HostPathAtOrBelow -Path ([string]$unsafePhysical.physical_path) -Root ([string]$profilePhysical.physical_path))) { throw 'host-benchmark-installed-profile-unsafe-location' }
        }
        $CodexHome = Assert-HostCodexHome -Path $CodexHome -RepoRoot $RepoRoot -ScratchRoot $ScratchRoot -AllowUserConfig
        if (-not (Get-InstalledDesktopProfileRoot -CodexHome $CodexHome).Equals($profileRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'host-benchmark-installed-profile-invalid' }
        $null = Assert-InstalledDesktopProfileReady -CodexHome $CodexHome
    } else {
        $CodexHome = Assert-HostCodexHome -Path $CodexHome -RepoRoot $RepoRoot -ScratchRoot $ScratchRoot -AllowNativeSystemSkills -AllowIsolatedHostConfig
    }
    $sourceBinding = [ordered]@{status='diagnostic';revision=$SourceRevision;commit_tree_oid=$SourceCommitTree;verification='live-dirty-diagnostic';reason='Dirty live source is diagnostic-only and cannot satisfy release eligibility.'}
    if ($SourceBindingRequired) {
        if ($SourceRevision -cnotmatch '^[0-9a-f]{40,64}$' -or $SourceCommitTree -cnotmatch '^[0-9a-f]{40,64}$') { throw 'host-benchmark-source-identity-invalid' }
        $trialSourceRoot = Join-Path $trialRoot 'source'
        $cloneOutput = @(& git -c core.longpaths=true clone --no-local --no-checkout --quiet -- $RepoRoot $trialSourceRoot 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw 'host-benchmark-source-clone-failed' }
        [void](Invoke-HostGit -Root $trialSourceRoot -Arguments @('config','core.longpaths','true'))
        [void](Invoke-HostGit -Root $trialSourceRoot -Arguments @('-c','core.hooksPath=NUL','checkout','--quiet','--detach',$SourceRevision,'--'))
        $sourceState = Get-HostGitState -Root $trialSourceRoot -IncludeIgnored
        if ([string]$sourceState.revision -cne $SourceRevision -or [string]$sourceState.commit_tree_oid -cne $SourceCommitTree -or [bool]$sourceState.dirty) { throw 'host-benchmark-source-checkout-mismatch' }
        $RepoRoot = $trialSourceRoot
        $WrapperPath = Join-Path $RepoRoot 'skills\codex\scripts\invoke_codex.ps1'
        $SchemaPath = Join-Path $RepoRoot 'schemas\host-benchmark\observation.schema.json'
        $CollectorPath = Join-Path $RepoRoot 'scripts\receive-otlp-http.ps1'
        $sourceBinding = [ordered]@{status='pending';revision=$SourceRevision;commit_tree_oid=$SourceCommitTree;verification='git-head-tree-clean/v1';reason='Trial uses an independent exact commit checkout.'}
    }
    $pathModule = @(Get-Module Harness.Path -All | Select-Object -Last 1)
    if ($pathModule.Count -ne 1) { throw 'host-benchmark-path-module-unavailable' }
    $pathModule = $pathModule[0]
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $workspace 'src\value.txt'),'alpha',[Text.UTF8Encoding]::new($false))
    [void](Invoke-HostGit -Root $workspace -Arguments @('init','--quiet'))
    if ($Protocol -eq 'bare') {
        $bareRules = @"
# Bare Host Benchmark
Execute the authorized workspace task directly. This workspace intentionally has no harness lifecycle. Do not search outside this workspace for rules or skills.
"@
        [IO.File]::WriteAllText((Join-Path $workspace 'AGENTS.md'),$bareRules,[Text.UTF8Encoding]::new($false))
    }
    $savedEnvironment = [ordered]@{}
    foreach ($name in @('USERPROFILE','HOME','CODEX_HOME','HARNESS_PROTOCOL','HARNESS_V2_ELIGIBILITY_REPORT','DEV_HARNESS_WORKSPACE_ROOT','WORKSPACE_ROOT','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_API_KEY','CODEX_EXECUTABLE','CODEX_THREAD_ID','CODEX_INTERNAL_ORIGINATOR_OVERRIDE','CODEX_SHELL')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
    }
    $collector = $null
    $trialResult = $null
    $installedDesktop = [ordered]@{
        benchmark_path=$BenchmarkPath
        host_surface=$(if($installedMode){'codex-cli-host-equivalent'}else{'codex-cli-isolated'})
        user_config_mode=$(if($installedMode){'loaded'}else{'ignored'})
        profile_config=$(if($installedMode){$profileConfigBinding}else{$null})
        protocol_environment=$(if($installedMode){'cleared'}else{'explicit-or-cleared'})
        install_status=$(if($installedMode -and $Protocol -cne 'bare'){'pending'}else{'not-applicable'})
        verification_status=$(if($installedMode -and $Protocol -cne 'bare'){'pending'}else{'not-applicable'})
        auth_unchanged=$(if($installedMode -and $Protocol -cne 'bare'){$false}else{$null})
        route_probe=$null
        rollout_promotion=$null
        cleanup_status=$(if($installedMode -and $Protocol -cne 'bare'){'pending'}else{'not-required'})
        hook_installed=$(if($installedMode -and $Protocol -cne 'bare'){'pending'}else{'not-applicable'})
        hook_trust='unknown'
        hook_callability='unknown'
    }
    try {
        if ($installedMode) {
            $env:USERPROFILE = $profileRoot
            $env:HOME = $profileRoot
            $env:CODEX_HOME = $CodexHome
            Remove-Item Env:HARNESS_PROTOCOL,Env:HARNESS_V2_ELIGIBILITY_REPORT,Env:DEV_HARNESS_WORKSPACE_ROOT,Env:WORKSPACE_ROOT,Env:CODEX_API_KEY,Env:CODEX_ACCESS_TOKEN,Env:OPENAI_API_KEY,Env:CODEX_EXECUTABLE,Env:CODEX_THREAD_ID,Env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE,Env:CODEX_SHELL -ErrorAction SilentlyContinue
        } else {
            $env:USERPROFILE = $userRoot
            Remove-Item Env:CODEX_HOME,Env:HARNESS_V2_ELIGIBILITY_REPORT,Env:DEV_HARNESS_WORKSPACE_ROOT,Env:WORKSPACE_ROOT,Env:CODEX_API_KEY,Env:CODEX_ACCESS_TOKEN,Env:OPENAI_API_KEY,Env:CODEX_EXECUTABLE,Env:CODEX_THREAD_ID,Env:CODEX_INTERNAL_ORIGINATOR_OVERRIDE,Env:CODEX_SHELL -ErrorAction SilentlyContinue
            if ($Protocol -eq 'bare') { Remove-Item Env:HARNESS_PROTOCOL -ErrorAction SilentlyContinue } else { $env:HARNESS_PROTOCOL = $Protocol }
        }
        if ($installedMode -and $Protocol -ne 'bare') {
            $installedDesktop.rollout_promotion = Invoke-InstalledDesktopRolloutPromotion -RepoRoot $RepoRoot -Workspace $workspace -EligibilityReportPath $EligibilityReportPath
            if ([string]$installedDesktop.rollout_promotion.report_digest -cne $ExpectedRolloutReportDigest -or [string]$installedDesktop.rollout_promotion.file_digest -cne $ExpectedRolloutFileDigest) { throw 'host-benchmark-installed-rollout-binding-changed' }
            $installResult = Invoke-InstalledDesktopInstall -CodexHome $CodexHome -Workspace $workspace -RepoRoot $RepoRoot
            $installedDesktop.install_status = [string]$installResult.install_status
            $installedDesktop.verification_status = [string]$installResult.verification_status
            $installedDesktop.auth_unchanged = [bool]$installResult.auth_unchanged
            $installedDesktop.hook_installed = 'verified'
        } elseif (-not $installedMode -and $Protocol -ne 'bare') {
            $installOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'install.ps1') -WorkspaceRoot $workspace -RepoRoot $RepoRoot -Preset core 2>&1 | ForEach-Object { [string]$_ })
            if ($LASTEXITCODE -ne 0) { throw "host benchmark install failed for $Protocol" }
        }
        if ($Protocol -ceq 'v1') {
            $runtimeCommonPath = Join-Path $RepoRoot 'skills\obsidian-memory\scripts\runtime-state-common.ps1'
            if (-not (Test-Path -LiteralPath $runtimeCommonPath -PathType Leaf)) { throw 'canonical runtime helper is missing from the trial source' }
            . $runtimeCommonPath
        }
        $v1Fixture = if ($Protocol -ceq 'v1') { Initialize-V1FixedWorkflowFixture -Workspace $workspace } else { $null }
        if ($installedMode -and $Protocol -ne 'bare') { $installedDesktop.route_probe = Invoke-InstalledDesktopRouteProbe -Protocol $Protocol -Workspace $workspace }
        $workspaceBaseline = Initialize-HostWorkspaceBaseline -Workspace $workspace
        if (-not $installedMode) { $env:CODEX_HOME = $CodexHome }
        $collector = Start-OtlpCollector -CollectorPath $CollectorPath -ResultRoot $resultRoot -TimeoutSeconds ([math]::Min(86400,($MaxRoundTrips*$TimeoutSeconds)+120))
        $trialTimer = [Diagnostics.Stopwatch]::StartNew()
        $codexProcessDuration = 0.0
        $firstUsefulAction = $null
        $hostTurns = 0
        $commandCalls = 0
        $mcpCalls = 0
        $webCalls = 0
        $fileCalls = 0
        $skillLoads = 0
        $inputTokens = [long]0
        $cachedInputTokens = [long]0
        $outputTokens = [long]0
        $tokenStatus = 'measured'
        $freshSessions = 0
        $agentMessages = 0
        $invocationUnavailable = $false
        $contractFailure = $false
        $diagnostic = $null
        $lastReason = 'execution_failed'
        $lastOutcome = 'failed'
        $observationComplete = $false
        $v1StageJournal = [Collections.Generic.List[string]]::new()
        $v1TargetJournal = [Collections.Generic.List[string]]::new()
        for ($round = 1; $round -le $MaxRoundTrips; $round++) {
            $freshSessions++
            $responsePath = Join-Path $resultRoot ("response-$round.json")
            $telemetryPath = Join-Path $resultRoot ("telemetry-$round.json")
            $v1StageBefore = if ($Protocol -ceq 'v1') { Get-V1FixedWorkflowStage -Workspace $workspace -RepoRoot $RepoRoot -TaskId ([string]$v1Fixture.task_id) } else { '' }
            $v1ExpectedStage = if ($Protocol -ceq 'v1') { Get-V1FixedWorkflowNextStage -Stage $v1StageBefore } else { '' }
            if ($Protocol -ceq 'v1' -and [string]::IsNullOrWhiteSpace($v1ExpectedStage)) {
                $contractFailure = $true
                $diagnostic = 'v1-invalid-start-stage'
                break
            }
            $routeContext = if ($Protocol -ceq 'v1') {
                "The confirmed task host-benchmark-fixed-workflow already exists at docs/tasks/host-benchmark-fixed-workflow/plan.md and is the active current task. This fresh host turn may perform only current stage $v1StageBefore and advance exactly once to $v1ExpectedStage; do not execute $v1ExpectedStage or a later stage in this turn. Do not route it as quick and do not create another task. Unless the required next stage is DONE, return outcome in_progress, task_completed false, and reason_code stage_boundary after that one transition."
            } else { 'This is a new task and no harness task artifact exists for it.' }
            $task = @"
Work only inside this workspace. The user explicitly authorizes this complete, reversible, private one-file task and all normal harness stage transitions needed to finish it. $routeContext Change only src/value.txt from exactly alpha to exactly beta. Do not ask about scope, acceptance, rollback, or authorization: they are fully confirmed here. Run a real verification command that succeeds only when the file content is exactly beta. Do not change another user file; harness-required task/runtime records are allowed. Return only schema-valid JSON. Set task_completed and verification_passed true only after the exact file check has actually passed and, for the fixed v1 comparator, its plan stage is DONE.
"@
            $otelArguments = @()
            if ([string]$collector.status -ceq 'measured') {
                $otelArguments = @(
                    '-OtelTraceEndpoint',("http://127.0.0.1:{0}/v1/traces/round-{1}" -f $collector.port,$round),
                    '-OtelClientIdentityPath',[string]$collector.identity_path,
                    '-OtelCollectorInstanceId',[string]$collector.collector_instance_id
                )
            }
            $invocationOffsetMs = $trialTimer.Elapsed.TotalMilliseconds
            $wrapperArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$WrapperPath,'-Task',$task,'-Workspace',$workspace,'-Model',$Model,'-Reasoning',$Reasoning,'-Sandbox','danger-full-access','-ApprovalPolicy','never','-Ephemeral','-AgentOutputOnly','-Quiet')
            if ($installedMode) { $wrapperArguments += '-LoadUserConfig' } else { $wrapperArguments += '-Isolated' }
            $wrapperArguments += @('-OutputSchema',$SchemaPath,'-Output',$responsePath,'-TelemetryOutput',$telemetryPath)
            $wrapperArguments += $otelArguments
            $wrapperArguments += @('-TimeoutSeconds',$TimeoutSeconds)
            $wrapperOutput = @(& pwsh @wrapperArguments 2>&1 | ForEach-Object { [string]$_ })
            $wrapperExit = $LASTEXITCODE
            if ($wrapperExit -ne 0 -or -not (Test-Path -LiteralPath $responsePath -PathType Leaf) -or -not (Test-Path -LiteralPath $telemetryPath -PathType Leaf)) {
                $invocationUnavailable = $true
                $diagnostic = 'wrapper-exit-' + $wrapperExit
                $lastReason = 'execution_failed'
                break
            }
            try {
                $rawObservation = [IO.File]::ReadAllText($responsePath,[Text.UTF8Encoding]::new($false,$true))
                if (-not (Test-Json -Json $rawObservation -SchemaFile $SchemaPath -ErrorAction Stop -WarningAction SilentlyContinue)) { throw 'invalid observation schema' }
                $observation = $rawObservation | ConvertFrom-Json -AsHashtable -Depth 20
                $telemetry = [IO.File]::ReadAllText($telemetryPath,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json -AsHashtable -Depth 20
                $otelEnabled = [string]$collector.status -ceq 'measured'
                $userConfigIdentityValid = if ($installedMode) { $telemetry.Contains('user_config_mode') -and [string]$telemetry.user_config_mode -ceq 'loaded' } else { -not $telemetry.Contains('user_config_mode') }
                if ([string]$telemetry.schema_version -cne 'codex-invocation-telemetry/v1' -or [string]$telemetry.model -cne $Model -or [string]$telemetry.reasoning -cne $Reasoning -or -not [bool]$telemetry.ephemeral -or [string]$telemetry.sandbox -cne 'danger-full-access' -or [string]$telemetry.approval_policy -cne 'never' -or -not $userConfigIdentityValid -or [bool]$telemetry.otel_trace.enabled -ne $otelEnabled) { throw 'invalid telemetry identity' }
                if ($otelEnabled -and ([string]$telemetry.otel_trace.contract -cne 'codex-0.144.4-successful-websocket-send/v2' -or [string]$telemetry.otel_trace.provenance -cne 'verified-owner-pid-start-time/v1')) { throw 'invalid OTel telemetry contract' }
            } catch {
                $invocationUnavailable = $true
                $diagnostic = 'invalid-wrapper-output'
                $lastReason = 'execution_failed'
                break
            }
            $codexProcessDuration += [double]$telemetry.duration_ms
            if ($null -eq $firstUsefulAction -and $null -ne $telemetry.first_useful_action_ms) { $firstUsefulAction = [math]::Round(($invocationOffsetMs + [double]$telemetry.first_useful_action_ms),2) }
            $hostTurns += [int]$telemetry.model_turns
            $agentMessages += [int]$telemetry.agent_messages
            $commandCalls += [int]$telemetry.tool_calls.command
            $mcpCalls += [int]$telemetry.tool_calls.mcp
            $webCalls += [int]$telemetry.tool_calls.web_search
            $fileCalls += [int]$telemetry.tool_calls.file_change
            $skillLoads += [int]$telemetry.lifecycle_skill_loads
            if ([string]$telemetry.tokens.status -ceq 'measured') {
                $inputTokens += [long]$telemetry.tokens.input
                if ($null -ne $telemetry.tokens.cached_input) { $cachedInputTokens += [long]$telemetry.tokens.cached_input }
                $outputTokens += [long]$telemetry.tokens.output
            } else { $tokenStatus = 'unavailable' }
            $lastReason = [string]$observation.reason_code
            $lastOutcome = [string]$observation.outcome
            if ($Protocol -ceq 'v1') {
                $v1StageAfter = Get-V1FixedWorkflowStage -Workspace $workspace -RepoRoot $RepoRoot -TaskId ([string]$v1Fixture.task_id)
                $isIntermediate = $v1ExpectedStage -cne 'DONE'
                $v1TargetAfter = if (Test-HostExactUtf8File -Path (Join-Path $workspace 'src\value.txt') -ExpectedText 'alpha') { 'alpha' } elseif (Test-HostExactUtf8File -Path (Join-Path $workspace 'src\value.txt') -ExpectedText 'beta') { 'beta' } else { 'invalid' }
                $v1TargetJournal.Add($v1TargetAfter)
                $v1ExpectedTarget = if ($v1ExpectedStage -cin @('PLAN_REVIEW','IMPLEMENT')) { 'alpha' } else { 'beta' }
                if ($v1StageAfter -cne $v1ExpectedStage -or $v1TargetAfter -cne $v1ExpectedTarget -or -not (Test-V1RuntimeState -Workspace $workspace -TaskId ([string]$v1Fixture.task_id) -ExpectedStage $v1ExpectedStage) -or ($isIntermediate -and ([bool]$observation.task_completed -or $lastOutcome -cne 'in_progress' -or $lastReason -cne 'stage_boundary')) -or (-not $isIntermediate -and ($lastOutcome -cne 'completed' -or $lastReason -cne 'completed'))) {
                    $contractFailure = $true
                    $diagnostic = 'v1-stage-boundary-violation'
                    break
                }
                $v1StageJournal.Add($v1StageAfter)
            }
            $targetExact = Test-HostExactUtf8File -Path (Join-Path $workspace 'src\value.txt') -ExpectedText 'beta'
            $workflowComplete = $Protocol -cne 'v1' -or (Test-V1FixedWorkflowComplete -Workspace $workspace -RepoRoot $RepoRoot -TaskId ([string]$v1Fixture.task_id))
            if ($targetExact -and $workflowComplete -and $lastOutcome -ceq 'completed' -and $lastReason -ceq 'completed' -and [bool]$observation.task_completed -and [bool]$observation.verification_executed -and [bool]$observation.verification_passed) {
                $observationComplete = $true
                break
            }
        }
        $trialTimer.Stop()
        $collectorStopped = Stop-OtlpCollector -Collector $collector
        $manifestValidation = if ([string]$collector.status -ceq 'measured' -and $collectorStopped) {
            Test-OtlpTraceManifest -TraceRoot ([string]$collector.trace_root) -Manifest $collector.manifest -ExpectedInstanceId ([string]$collector.collector_instance_id) -FreshSessions $freshSessions
        } else { $null }
        $modelMeasurement = if ([string]$collector.status -cne 'measured') {
            [ordered]@{status='unavailable';value=$null;basis='codex-0.144.4-successful-websocket-send/v2';reason=[string]$collector.reason}
        } elseif (-not $collectorStopped) {
            [ordered]@{status='unavailable';value=$null;basis='codex-0.144.4-successful-websocket-send/v2';reason='otel-collector-stop-failed'}
        } elseif ([string]$manifestValidation.status -cne 'measured') {
            [ordered]@{status='unavailable';value=$null;basis='codex-0.144.4-successful-websocket-send/v2';reason=[string]$manifestValidation.reason}
        } else {
            Get-CodexOtelModelRequests -TraceRoot ([string]$collector.trace_root) -FreshSessions $freshSessions -Model $Model -ExpectedVersion $ExpectedCodexVersion
        }
        if ([string]$modelMeasurement.status -ceq 'unavailable') {
            $invocationUnavailable = $true
            if ($null -eq $diagnostic) { $diagnostic = [string]$modelMeasurement.reason }
        }
        $v1ValidatorPassed = $Protocol -cne 'v1'
        if ($Protocol -ceq 'v1' -and (Test-V1FixedWorkflowComplete -Workspace $workspace -RepoRoot $RepoRoot -TaskId ([string]$v1Fixture.task_id))) {
            $validatorPath = Join-Path $workspace '.assistant\entry\validate-lite-artifacts.ps1'
            if (Test-Path -LiteralPath $validatorPath -PathType Leaf) {
                $validatorOutput = @(& pwsh -NoLogo -NoProfile -NonInteractive -File $validatorPath -TaskId ([string]$v1Fixture.task_id) 2>&1 | ForEach-Object { [string]$_ })
                $v1ValidatorPassed = $LASTEXITCODE -eq 0 -and ($validatorOutput -join "`n") -match '(?m)^STATUS: PASS\s*$'
            }
        }
        $changed = @(Get-HostWorkspaceChanges -Workspace $workspace -BaselineRevision $workspaceBaseline)
        $safeChangedPaths = Test-HostWorkspaceChangePathsSafe -Workspace $workspace -Paths $changed -PathModule $pathModule
        $artifactAllowlist = @('docs/tasks/host-benchmark-fixed-workflow/plan.md','docs/tasks/host-benchmark-fixed-workflow/test.md','docs/tasks/host-benchmark-fixed-workflow/skill-manifest.json')
        $requiredArtifacts = @('docs/tasks/host-benchmark-fixed-workflow/plan.md','docs/tasks/host-benchmark-fixed-workflow/test.md')
        $runtimeAllowlist = @('.assistant/运行时/当前任务.md','.assistant/运行时/恢复索引.md','.assistant/运行时/tasks/host-benchmark-fixed-workflow.md')
        $artifactChanges = @($changed | Where-Object { $_.StartsWith('docs/tasks/',[StringComparison]::Ordinal) })
        $artifactWrites = $artifactChanges.Count
        $v1ArtifactBoundaryPassed = $Protocol -cne 'v1' -or (@($artifactChanges | Where-Object { $_ -cnotin $artifactAllowlist }).Count -eq 0 -and @($requiredArtifacts | Where-Object { $_ -cnotin $artifactChanges }).Count -eq 0)
        $runtimeWrites = @($changed | Where-Object { $_.StartsWith('.assistant/runtime/',[StringComparison]::Ordinal) -or $_.StartsWith('.assistant/运行时/',[StringComparison]::Ordinal) }).Count
        $unexpectedWrites = @($changed | Where-Object {
            if ($_ -ceq 'src/value.txt') { return $false }
            if ($Protocol -ceq 'v1' -and ($_ -cin $artifactAllowlist -or $_ -cin $runtimeAllowlist)) { return $false }
            return $true
        }).Count
        $targetPassed = Test-HostExactUtf8File -Path (Join-Path $workspace 'src\value.txt') -ExpectedText 'beta'
        $workflowCompleted = $Protocol -cne 'v1' -or (Test-V1FixedWorkflowComplete -Workspace $workspace -RepoRoot $RepoRoot -TaskId ([string]$v1Fixture.task_id))
        $writeBoundaryPassed = $unexpectedWrites -eq 0 -and $safeChangedPaths
        $directContractPassed = $Protocol -ceq 'v1' -or ($freshSessions -eq 1 -and $hostTurns -eq 1 -and $artifactWrites -eq 0 -and $runtimeWrites -eq 0)
        $v1ContractPassed = $Protocol -cne 'v1' -or ($freshSessions -eq 5 -and $hostTurns -eq 5 -and ($v1StageJournal -join '>') -ceq 'PLAN_REVIEW>IMPLEMENT>CODE_REVIEW>TEST>DONE' -and ($v1TargetJournal -join '>') -ceq 'alpha>alpha>beta>beta>beta' -and $v1ValidatorPassed -and $v1ArtifactBoundaryPassed -and $artifactWrites -in @(2,3) -and $runtimeWrites -eq 3)
        $installedContractPassed = -not $installedMode -or ($Protocol -ceq 'bare') -or (
            [string]$installedDesktop.install_status -ceq 'pass' -and
            [string]$installedDesktop.verification_status -ceq 'pass' -and
            [bool]$installedDesktop.auth_unchanged -and
            [string]$installedDesktop.hook_installed -ceq 'verified' -and
            [string]$installedDesktop.route_probe.requested_protocol -ceq 'auto' -and
            [string]$installedDesktop.route_probe.selected_protocol -ceq $Protocol
        )
        if (-not $writeBoundaryPassed -and $null -eq $diagnostic) { $diagnostic = 'write-boundary-violation' }
        elseif (-not $directContractPassed -and $null -eq $diagnostic) { $diagnostic = 'direct-single-session-contract-violation' }
        elseif (-not $v1ContractPassed -and $null -eq $diagnostic) { $diagnostic = 'v1-fixed-workflow-contract-violation' }
        elseif (-not $installedContractPassed -and $null -eq $diagnostic) { $diagnostic = 'installed-desktop-contract-violation' }
        if (-not $installedContractPassed) { $contractFailure = $true }
        $complete = $observationComplete -and $targetPassed -and $workflowCompleted -and $writeBoundaryPassed -and $directContractPassed -and $v1ContractPassed -and $installedContractPassed
        if ($SourceBindingRequired) {
            $sourceStateAfter = Get-HostGitState -Root $RepoRoot -IncludeIgnored
            if ([string]$sourceStateAfter.revision -ceq $SourceRevision -and [string]$sourceStateAfter.commit_tree_oid -ceq $SourceCommitTree -and -not [bool]$sourceStateAfter.dirty) {
                $sourceBinding.status = 'bound'
                $sourceBinding.reason = 'Trial source remained at the exact clean commit checkout.'
            } else {
                $sourceBinding.status = 'unavailable'
                $sourceBinding.reason = 'The independent commit checkout changed during execution.'
                $invocationUnavailable = $true
                $diagnostic = 'source-binding-mismatch'
            }
        }
        $status = Resolve-HostTrialStatus -Protocol $Protocol -InvocationUnavailable $invocationUnavailable -ContractFailure $contractFailure -WriteBoundaryPassed $writeBoundaryPassed -SourceBindingFailure ($SourceBindingRequired -and [string]$sourceBinding.status -cne 'bound') -FreshSessions $freshSessions -HostTurns $hostTurns -ObservationComplete $observationComplete -WorkflowCompleted $workflowCompleted -DirectContractPassed $directContractPassed -V1ContractPassed $v1ContractPassed -Complete $complete
        $trialResult = [ordered]@{
            trial=$Trial;status=$status;diagnostic=$diagnostic;completion_passed=($complete -and -not $invocationUnavailable);outcome=$lastOutcome;reason_code=$lastReason;source_binding=$sourceBinding;workspace_baseline_revision=$workspaceBaseline
            workflow_contract=$(if($Protocol-ceq'v1'){'confirmed-plan-to-done'}else{'new-task'});workflow_completed=$workflowCompleted
            v1_stage_journal=@($v1StageJournal);v1_target_journal=@($v1TargetJournal);v1_validator_passed=$v1ValidatorPassed
            fresh_sessions=$freshSessions
            host_turns=[ordered]@{status='measured';value=$hostTurns;basis='codex-jsonl-turn.started';reason='Counts outer Codex host turns only; it is not an API/model request count.'}
            successful_request_sends=$modelMeasurement;completed_agent_messages=$agentMessages
            total_duration_ms=[math]::Round($trialTimer.Elapsed.TotalMilliseconds,2);sum_codex_process_duration_ms=[math]::Round($codexProcessDuration,2);first_useful_action_ms=$firstUsefulAction
            tool_calls=[ordered]@{command=$commandCalls;mcp=$mcpCalls;web_search=$webCalls;file_change=$fileCalls;total=$commandCalls+$mcpCalls+$webCalls+$fileCalls}
            loaded_skills=[ordered]@{status='unavailable';value=$null;reason='Sanitized host telemetry does not expose authoritative runtime skill identities.'}
            skill_file_command_matches=[ordered]@{status='measured';value=$skillLoads;reason='Diagnostic count of host-visible command paths matching SKILL.md; not a loaded-skill count.'}
            loaded_files=[ordered]@{status='unavailable';value=$null;reason='Sanitized telemetry intentionally does not persist command paths or file names.'}
            artifact_writes=$artifactWrites;runtime_writes=$runtimeWrites;unexpected_writes=$unexpectedWrites;raw_trace_deleted=$false;post_trial_diagnostics=@()
            tokens=[ordered]@{status=$tokenStatus;input=$(if($tokenStatus-ceq'measured'){$inputTokens}else{$null});cached_input=$(if($tokenStatus-ceq'measured'){$cachedInputTokens}else{$null});output=$(if($tokenStatus-ceq'measured'){$outputTokens}else{$null})}
        }
        if ($installedMode) { $trialResult['installed_desktop'] = $installedDesktop }
    } finally {
        if ($null -ne $collector -and $null -ne $collector.process) { [void](Stop-OtlpCollector -Collector $collector) }
        $pendingCleanup = $null
        if ($null -ne $collector -and $null -ne $collector.process) {
            $pendingCleanup = [ordered]@{
                collector=$collector;trace_root=[string]$collector.trace_root;result_root=$resultRoot;safety_root=$trialRoot;trial_result=$trialResult
                prior_status=$(if($null-ne$trialResult){[string]$trialResult.status}else{$null});prior_diagnostic=$(if($null-ne$trialResult){$trialResult.diagnostic}else{$null});prior_completion_passed=$(if($null-ne$trialResult){[bool]$trialResult.completion_passed}else{$false})
            }
            [void]$script:HostPendingOtlpCollectors.Add($pendingCleanup)
        }
        $finalTraceRemoved = if ($null -eq $collector) { $true } elseif ($null -ne $collector.process) { $false } else { Remove-HostRawTrace -TraceRoot ([string]$collector.trace_root) -ResultRoot $resultRoot -SafetyRoot $trialRoot }
        $authLayoutValid = $true
        $profileConfigStable = $true
        try {
            if ($installedMode -and $Protocol -cne 'bare') { $null = Assert-HostCodexHomeLayout -Path $CodexHome -AllowUserConfig -AllowInstalledAssets }
            elseif ($installedMode) { $null = Assert-InstalledDesktopProfileReady -CodexHome $CodexHome }
            else { $null = Assert-HostCodexHomeLayout -Path $CodexHome -AllowNativeSystemSkills -AllowIsolatedHostConfig }
        } catch { $authLayoutValid = $false }
        if ($installedMode) {
            try { $profileConfigStable = Test-InstalledDesktopUserConfigBinding -Expected $profileConfigBinding -Actual (Get-InstalledDesktopUserConfigBinding -CodexHome $CodexHome) } catch { $profileConfigStable = $false }
        }
        if ($null -ne $trialResult) {
            $trialResult.raw_trace_deleted = $finalTraceRemoved
            $postTrialDiagnostics = [Collections.Generic.List[string]]::new()
            if (-not $finalTraceRemoved) {
                $cleanupDiagnostic = if ($null -ne $pendingCleanup) { 'otel-collector-cleanup-pending' } else { 'otel-trace-delete-failed' }
                $postTrialDiagnostics.Add($cleanupDiagnostic)
                if ([string]$trialResult.status -cne 'fail') {
                    $trialResult.status = 'unavailable'
                    $trialResult.diagnostic = $cleanupDiagnostic
                }
                $trialResult.completion_passed = $false
            }
            if (-not $authLayoutValid) {
                $authDiagnostic = if ($installedMode) { 'installed-desktop-profile-changed' } else { 'isolated-auth-home-changed' }
                $postTrialDiagnostics.Add($authDiagnostic)
                if ([string]$trialResult.status -cne 'fail') {
                    $trialResult.status = 'unavailable'
                    $trialResult.diagnostic = $authDiagnostic
                }
                $trialResult.completion_passed = $false
            }
            if (-not $profileConfigStable) {
                $postTrialDiagnostics.Add('installed-desktop-config-changed')
                if ([string]$trialResult.status -cne 'fail') {
                    $trialResult.status = 'unavailable'
                    $trialResult.diagnostic = 'installed-desktop-config-changed'
                }
                $trialResult.completion_passed = $false
            }
            $trialResult.post_trial_diagnostics = @($postTrialDiagnostics)
        }
        foreach ($entry in $savedEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key,$entry.Value,[EnvironmentVariableTarget]::Process) }
    }
    return $trialResult
}
