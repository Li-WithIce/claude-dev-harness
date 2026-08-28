Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.Hashing.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.ProtectedAction.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.ControlledWrite.psm1') -Force -ErrorAction Stop

function Test-HarnessShellApplyPatchInvocation {
    param([Parameter(Mandatory)][string]$CommandText)

    return [regex]::IsMatch($CommandText,'(?i)(?<![A-Za-z0-9_])(?:apply_patch|applypatch)(?![A-Za-z0-9_])')
}

function Assert-HarnessApplyPatchRelativePath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path) -or $Path -cne $Path.Trim() -or
        $Path.IndexOfAny([char[]]@(0,10,13)) -ge 0) {
        throw 'direct apply_patch input contains an invalid target path'
    }
    if ($Path.StartsWith('/',[StringComparison]::Ordinal) -or
        $Path.StartsWith('\',[StringComparison]::Ordinal) -or
        $Path -cmatch '^[A-Za-z]:' -or $Path.Contains(':')) {
        throw 'direct apply_patch input requires a relative target path'
    }
    foreach ($segment in [regex]::Split($Path,'[\\/]')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.' -or $segment -ceq '..' -or
            $segment.IndexOfAny([char[]](0..31 + @(60,62,34,124,63,42))) -ge 0 -or
            $segment.EndsWith('.',[StringComparison]::Ordinal) -or
            $segment.EndsWith(' ',[StringComparison]::Ordinal)) {
            throw 'direct apply_patch input contains an invalid target path'
        }
    }
}

function Get-HarnessApplyPatchChangedPaths {
    param([Parameter(Mandatory)][string]$PatchText)

    $normalized = $PatchText.Replace("`r`n","`n")
    if ($normalized.Contains("`r")) { throw 'direct apply_patch input has an invalid patch envelope' }
    if ($normalized.EndsWith("`n",[StringComparison]::Ordinal)) { $normalized = $normalized.Substring(0,$normalized.Length - 1) }
    $lines = $normalized.Split([char]10)
    if ($lines.Count -lt 2 -or $lines[0].Trim() -cne '*** Begin Patch' -or
        $lines[$lines.Count - 1].Trim() -cne '*** End Patch') {
        throw 'direct apply_patch input has an invalid patch envelope'
    }

    $paths = [Collections.Generic.List[string]]::new()
    $pathKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $operation = 'none'
    $environmentSeen = $false
    $moveSeen = $false
    $updateStarted = $false
    $updateContentSeen = $false
    $updateNeedsContent = $false
    $endOfFileSeen = $false
    $fileOperationCount = 0
    for ($index = 1; $index -lt $lines.Count - 1; $index++) {
        $line = [string]$lines[$index]
        $trimmed = $line.Trim()
        if ($operation -ceq 'none' -and
            $trimmed.StartsWith('*** Environment ID:',[StringComparison]::Ordinal)) {
            if ($environmentSeen) { throw 'direct apply_patch input contains a duplicate Environment ID directive' }
            if ([string]::IsNullOrWhiteSpace($trimmed.Substring('*** Environment ID:'.Length))) {
                throw 'direct apply_patch input contains an empty Environment ID directive'
            }
            $environmentSeen = $true
            continue
        }

        $headerLine = if ($operation -ceq 'Update File') { $line.TrimEnd() } else { $trimmed }
        if ($headerLine -ceq '*** Begin Patch' -or $headerLine -ceq '*** End Patch') {
            throw 'direct apply_patch input has an invalid patch envelope'
        }
        $fileMatch = [regex]::Match($headerLine,'^\*\*\* (?<operation>Add File|Update File|Delete File): (?<path>.*)$')
        if ($fileMatch.Success) {
            if ($operation -ceq 'Update File' -and (-not $updateContentSeen -or $updateNeedsContent)) {
                throw 'direct apply_patch input contains an empty Update File hunk'
            }
            $operation = $fileMatch.Groups['operation'].Value
            $path = [string]$fileMatch.Groups['path'].Value
            Assert-HarnessApplyPatchRelativePath -Path $path
            $moveSeen = $false
            $updateStarted = $false
            $updateContentSeen = $false
            $updateNeedsContent = $false
            $endOfFileSeen = $false
            $fileOperationCount++
            if ($pathKeys.Add($path.Replace('/','\'))) { $paths.Add($path) }
            continue
        }

        if ($operation -ceq 'Update File') {
            if ($headerLine -ceq '*** End of File') {
                if ($endOfFileSeen -or -not $updateContentSeen -or $updateNeedsContent) {
                    throw 'direct apply_patch input contains an invalid End of File directive'
                }
                $endOfFileSeen = $true
                continue
            }
            $moveMatch = [regex]::Match($headerLine,'^\*\*\* Move to: (?<path>.*)$')
            if ($moveMatch.Success) {
                if ($moveSeen -or $updateStarted -or $endOfFileSeen) {
                    throw 'direct apply_patch input contains an invalid Move to directive'
                }
                $path = [string]$moveMatch.Groups['path'].Value
                Assert-HarnessApplyPatchRelativePath -Path $path
                $moveSeen = $true
                if ($pathKeys.Add($path.Replace('/','\'))) { $paths.Add($path) }
                continue
            }
            if ($endOfFileSeen) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                throw 'direct apply_patch input contains content after End of File'
            }
            if ($headerLine.StartsWith('*** ',[StringComparison]::Ordinal)) {
                throw 'direct apply_patch input contains an unsupported patch directive'
            }
            if ($headerLine -ceq '@@' -or $headerLine.StartsWith('@@ ',[StringComparison]::Ordinal)) {
                if ($updateNeedsContent) {
                    throw 'direct apply_patch input contains an empty Update File chunk'
                }
                $updateStarted = $true
                $updateNeedsContent = $true
                continue
            }
            if ($line.Length -eq 0 -or $line.StartsWith(' ',[StringComparison]::Ordinal) -or
                $line.StartsWith('+',[StringComparison]::Ordinal) -or
                $line.StartsWith('-',[StringComparison]::Ordinal)) {
                $updateStarted = $true
                $updateContentSeen = $true
                $updateNeedsContent = $false
                continue
            }
            throw 'direct apply_patch input contains an invalid Update File hunk'
        }

        if ($trimmed -ceq '*** End of File') { throw 'direct apply_patch input contains an invalid End of File directive' }
        if ($trimmed.StartsWith('*** Move to:',[StringComparison]::Ordinal)) {
            throw 'direct apply_patch input contains an invalid Move to directive'
        }
        if ($trimmed.StartsWith('*** ',[StringComparison]::Ordinal)) {
            throw 'direct apply_patch input contains an unsupported patch directive'
        }
        if ($operation -ceq 'Add File' -and $line.StartsWith('+',[StringComparison]::Ordinal)) { continue }
        throw 'direct apply_patch input contains an invalid patch hunk'
    }
    if ($operation -ceq 'Update File' -and (-not $updateContentSeen -or $updateNeedsContent)) {
        throw 'direct apply_patch input contains an empty Update File hunk'
    }
    if ($fileOperationCount -eq 0) { throw 'direct apply_patch input is missing a file operation' }
    return $paths.ToArray()
}

function Resolve-HarnessAdapterMutationPaths {
    param(
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths
    )

    $result = [Collections.Generic.List[string]]::new()
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { throw 'file mutation input is missing target path' }
        $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'file mutation target' -AllowMissing
        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            throw 'file mutation target must not be a directory'
        }
        if ($identities.Add($fullPath)) { $result.Add($path) }
    }
    return $result.ToArray()
}

function Resolve-HarnessAdapterActionWorkspace {
    param([string]$Primary,[string]$Fallback)

    $primaryRoot = if ([string]::IsNullOrWhiteSpace($Primary)) { '' } else { Resolve-HarnessWorkspaceRoot -WorkspaceRoot $Primary }
    $fallbackRoot = if ([string]::IsNullOrWhiteSpace($Fallback)) { '' } else { Resolve-HarnessWorkspaceRoot -WorkspaceRoot $Fallback }
    if ($primaryRoot -and $fallbackRoot -and
        -not $primaryRoot.Equals($fallbackRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Codex PreToolUse cwd conflicts with DEV_HARNESS_WORKSPACE_ROOT'
    }
    $workspace = if ($primaryRoot) { $primaryRoot } else { $fallbackRoot }
    if (-not $workspace) { throw 'Codex PreToolUse input is missing cwd and DEV_HARNESS_WORKSPACE_ROOT' }
    return $workspace
}

function Invoke-HarnessAdapterPreflightAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][string]$WorkspaceRoot='',
        [AllowEmptyString()][string]$WorkspaceRootFallback='',
        [ValidateSet('','default','bypassPermissions')][string]$PermissionMode='',
        [ValidateSet('read-only','write')][string]$SessionMode='write',
        [ValidateSet('read','write')][string]$ActionMode='write',
        [ValidateSet('shell','apply_patch','file_mutation','normalized_action')][string]$ActionKind,
        [AllowEmptyString()][string]$ShellText='',
        [AllowEmptyString()][string]$PatchText='',
        [AllowEmptyCollection()][string[]]$ChangedPaths=@(),
        [AllowEmptyString()][string]$TaskId='',
        [Nullable[int]]$ExpectedVersion=$null,
        [AllowEmptyString()][string]$Environment='',
        [bool]$DryRun=$false,
        [AllowEmptyString()][string]$UserInstruction=''
    )

    $repoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
    $workspaceRoot = Resolve-HarnessAdapterActionWorkspace -Primary $WorkspaceRoot -Fallback $WorkspaceRootFallback
    $paths = [string[]]@($ChangedPaths)
    $commandText = ''
    switch ($ActionKind) {
        'shell' {
            if ([string]::IsNullOrWhiteSpace($ShellText) -or $PatchText -or $paths.Count) {
                throw 'shell preflight action shape is invalid'
            }
            $commandText = $ShellText
            if (Test-HarnessShellApplyPatchInvocation -CommandText $commandText) {
                throw 'Bash shell-form apply_patch is denied because Codex PreToolUse does not expose the effective tool workdir or environment identity'
            }
        }
        'apply_patch' {
            if ([string]::IsNullOrWhiteSpace($PatchText) -or $ShellText -or $paths.Count) {
                throw 'apply_patch preflight action shape is invalid'
            }
            $paths = [string[]]@(Resolve-HarnessAdapterMutationPaths -WorkspaceRoot $workspaceRoot -Paths (Get-HarnessApplyPatchChangedPaths -PatchText $PatchText))
        }
        'file_mutation' {
            if ($ShellText -or $PatchText -or $paths.Count -eq 0) {
                throw 'file mutation preflight action shape is invalid'
            }
            $paths = [string[]]@(Resolve-HarnessAdapterMutationPaths -WorkspaceRoot $workspaceRoot -Paths $paths)
        }
        'normalized_action' {
            if ($PatchText) { throw 'normalized preflight action must not carry patch_text' }
            $commandText = $ShellText
            $paths = [string[]]@(Resolve-HarnessAdapterMutationPaths -WorkspaceRoot $workspaceRoot -Paths $paths)
        }
    }

    $guard = Assert-HarnessProtectedAction -RepoRoot $repoRoot -WorkspaceRoot $workspaceRoot `
        -SessionMode $SessionMode -ActionMode $ActionMode -TaskId $TaskId -ExpectedVersion $ExpectedVersion `
        -CommandText $commandText -ChangedPaths $paths -Environment $Environment `
        -DryRun:$DryRun -UserInstruction $UserInstruction
    $response = [ordered]@{
        schema_version = 'adapter-kernel-api/v1'
        message_type = 'response'
        body = [ordered]@{
            operation = 'preflight_action'
            allowed = [bool]$guard.allowed
            protected = [bool]$guard.protected
            matched_rules = @($guard.matched_rules)
            required_scopes = @($guard.required_scopes)
            approval_id = $guard.approval_id
            operation_identity = $guard.operation_identity
            protected_operation = $guard.protected_operation
        }
    }
    return $response
}

function Invoke-HarnessAdapterControlledWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [AllowEmptyString()][string]$Environment='',
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][ValidatePattern('^(?:missing|sha256:[0-9a-f]{64})$')][string]$ExpectedCurrentSha256,
        [AllowEmptyString()][string]$TaskId='',
        [Nullable[int]]$ExpectedVersion=$null,
        [AllowEmptyString()][string]$ExecutionProfile='',
        [AllowEmptyString()][string]$ContractPath='',
        [AllowEmptyString()][string]$ContractDigest='',
        [AllowEmptyString()][string]$ApprovalId='',
        [Nullable[bool]]$DryRun=$null
    )

    $result = Invoke-HarnessControlledWrite -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot `
        -Environment $Environment -Path $TargetPath -Content $Content `
        -ExpectedSourceDigest (Get-HarnessUtf8TextSha256 -Text $Content) `
        -ExpectedCurrentDigest $ExpectedCurrentSha256 -TaskId $TaskId `
        -ExpectedVersion $ExpectedVersion -ExecutionProfile $ExecutionProfile `
        -ContractPath $ContractPath -ContractDigest $ContractDigest `
        -ApprovalId $ApprovalId -DryRun $DryRun
    $response = [ordered]@{
        schema_version = 'adapter-kernel-api/v1'
        message_type = 'response'
        body = [ordered]@{
            operation = 'controlled_write'
            written = [bool]$result.written
            dry_run = [bool]$result.dry_run
            path = [string]$result.path
            digest = [string]$result.digest
            protected = [bool]$result.protected
            matched_rules = @($result.matched_rules)
            approval_id = $result.approval_id
            operation_identity = $result.operation_identity
            protected_operation = $result.protected_operation
        }
    }
    return $response
}

Export-ModuleMember -Function Invoke-HarnessAdapterPreflightAction,Invoke-HarnessAdapterControlledWrite
