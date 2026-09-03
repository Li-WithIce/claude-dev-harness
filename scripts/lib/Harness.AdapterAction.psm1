Import-Module (Join-Path $PSScriptRoot 'Harness.ProtectedAction.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.ControlledWrite.psm1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')

function Assert-HarnessApplyPatchRelativePath {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path) -or $Path -cne $Path.Trim() -or $Path.IndexOfAny([char[]]@(0,10,13)) -ge 0) { throw 'direct apply_patch input contains an invalid target path' }
    if ($Path.StartsWith('/',[StringComparison]::Ordinal) -or $Path.StartsWith('\',[StringComparison]::Ordinal) -or $Path -cmatch '^[A-Za-z]:' -or $Path.Contains(':')) { throw 'direct apply_patch input requires a relative target path' }
    $invalid = @([regex]::Split($Path,'[\\/]') | Where-Object {
        [string]::IsNullOrEmpty($_) -or $_ -cin @('.','..') -or $_.IndexOfAny([char[]](0..31 + @(60,62,34,124,63,42))) -ge 0 -or $_.EndsWith('.',[StringComparison]::Ordinal) -or $_.EndsWith(' ',[StringComparison]::Ordinal)
    } | Select-Object -First 1)
    if ($invalid.Count) { throw 'direct apply_patch input contains an invalid target path' }
}

function Get-HarnessApplyPatchChangedPaths {
    param([Parameter(Mandatory)][string]$PatchText)

    $text = $PatchText.Replace("`r`n","`n")
    if ($text.Contains([char]13)) { throw 'direct apply_patch input has an invalid patch envelope' }
    if ($text.EndsWith("`n`n",[StringComparison]::Ordinal)) { throw 'direct apply_patch input has an invalid patch envelope' }
    $lines = $text.TrimEnd([char]10).Split([char]10)
    if ($lines.Count -lt 2 -or $lines[0].Trim() -cne '*** Begin Patch' -or $lines[-1].Trim() -cne '*** End Patch') { throw 'direct apply_patch input has an invalid patch envelope' }

    $paths,$keys,$mode,$state,$environmentSeen = [Collections.Generic.List[string]]::new(),[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase),'','none',$false

    for ($index = 1; $index -lt $lines.Count - 1; $index++) {
        $line = [string]$lines[$index]
        $trimmed = $line.Trim()
        if (-not $mode -and $trimmed.StartsWith('*** Environment ID:',[StringComparison]::Ordinal)) {
            if ($environmentSeen -or [string]::IsNullOrWhiteSpace($trimmed.Substring(19))) { throw 'direct apply_patch input contains an invalid Environment ID directive' }
            $environmentSeen = $true
            continue
        }

        $header = if ($mode -ceq 'Update File') { $line.TrimEnd() } else { $trimmed }
        $match = [regex]::Match($header,'^\*\*\* (?<mode>Add File|Update File|Delete File): (?<path>.*)$')
        if ($match.Success) {
            if ($mode -ceq 'Update File' -and $state -cnotin @('have','eof')) { throw 'direct apply_patch input contains an empty Update File hunk' }
            $mode = $match.Groups['mode'].Value
            $path = $match.Groups['path'].Value
            Assert-HarnessApplyPatchRelativePath -Path $path
            if ($keys.Add($path.Replace('/','\'))) { $paths.Add($path) }
            $state = 'none'
            continue
        }

        if ($mode -ceq 'Add File' -and $line.StartsWith('+',[StringComparison]::Ordinal)) { continue }
        if ($mode -cne 'Update File') { throw 'direct apply_patch input contains an invalid patch hunk' }
        if ($state -ceq 'eof' -and [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($state -ceq 'eof') { throw 'direct apply_patch input contains content after End of File' }
        if ($header -ceq '*** End of File') {
            if ($state -cne 'have') { throw 'direct apply_patch input contains an invalid End of File directive' }
            $state = 'eof'
            continue
        }

        $move = [regex]::Match($header,'^\*\*\* Move to: (?<path>.*)$')
        if ($move.Success) {
            if ($state -cne 'none') { throw 'direct apply_patch input contains an invalid Move to directive' }
            $path = $move.Groups['path'].Value
            Assert-HarnessApplyPatchRelativePath -Path $path
            if ($keys.Add($path.Replace('/','\'))) { $paths.Add($path) }
            $state = 'moved'
            continue
        }
        if ($header -ceq '@@' -or $header.StartsWith('@@ ',[StringComparison]::Ordinal)) {
            if ($state -ceq 'need') { throw 'direct apply_patch input contains an empty Update File chunk' }
            $state = 'need'
            continue
        }
        if ($header.StartsWith('*** ',[StringComparison]::Ordinal)) { throw 'direct apply_patch input contains an unsupported patch directive' }
        if ($line.Length -eq 0 -or $line[0] -in @(' ','+','-')) {
            $state = 'have'
            continue
        }
        throw 'direct apply_patch input contains an invalid Update File hunk'
    }
    if ($mode -ceq 'Update File' -and $state -cnotin @('have','eof')) { throw 'direct apply_patch input contains an empty Update File hunk' }
    if (-not $paths.Count) { throw 'direct apply_patch input is missing a file operation' }
    return $paths.ToArray()
}

function Invoke-HarnessAdapterPreflightAction {
    param([Parameter(Mandatory)][string]$RepoRoot,[AllowEmptyString()][string]$WorkspaceRoot='',[AllowEmptyString()][string]$WorkspaceRootFallback='',
        [ValidateSet('','default','bypassPermissions')][string]$PermissionMode='',[ValidateSet('read-only','write')][string]$SessionMode='write',
        [ValidateSet('read','write')][string]$ActionMode='write',[ValidateSet('shell','apply_patch','file_mutation','normalized_action')][string]$ActionKind,
        [AllowEmptyString()][string]$ShellText='',[AllowEmptyString()][string]$PatchText='',[AllowEmptyCollection()][string[]]$ChangedPaths=@(),
        [AllowEmptyString()][string]$TaskId='',[Nullable[int]]$ExpectedVersion=$null,[AllowEmptyString()][string]$Environment='',[bool]$DryRun=$false,
        [AllowEmptyString()][string]$UserInstruction='')

    $repoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
    $primaryRoot = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { '' } else { Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot }
    $fallbackRoot = if ([string]::IsNullOrWhiteSpace($WorkspaceRootFallback)) { '' } else { Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRootFallback }
    Assert-HarnessKernelCondition (-not $primaryRoot -or -not $fallbackRoot -or $primaryRoot.Equals($fallbackRoot,[StringComparison]::OrdinalIgnoreCase)) 'Codex PreToolUse cwd conflicts with DEV_HARNESS_WORKSPACE_ROOT'
    $workspaceRoot,$paths,$commandText = $(if ($primaryRoot) { $primaryRoot } elseif ($fallbackRoot) { $fallbackRoot } else { throw 'Codex PreToolUse input is missing cwd and DEV_HARNESS_WORKSPACE_ROOT' }),[string[]]@($ChangedPaths),''
    switch ($ActionKind) {
        'shell' {
            Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace($ShellText) -and -not $PatchText -and -not $paths.Count) 'shell preflight action shape is invalid'
            $commandText = $ShellText
            Assert-HarnessKernelCondition (-not [regex]::IsMatch($commandText,'(?i)(?<![A-Za-z0-9_])(?:apply_patch|applypatch)(?![A-Za-z0-9_])')) 'Bash shell-form apply_patch is denied because Codex PreToolUse does not expose the effective tool workdir or environment identity'
        }
        'apply_patch' {
            Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace($PatchText) -and -not $ShellText -and -not $paths.Count) 'apply_patch preflight action shape is invalid'
            $paths = [string[]]@(Get-HarnessApplyPatchChangedPaths -PatchText $PatchText)
        }
        'file_mutation' {
            Assert-HarnessKernelCondition (-not $ShellText -and -not $PatchText -and $paths.Count -gt 0) 'file mutation preflight action shape is invalid'
        }
        'normalized_action' {
            if ($PatchText) { throw 'normalized preflight action must not carry patch_text' }
            $commandText = $ShellText
        }
    }
    if ($ActionKind -cne 'shell') {
        $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $paths = [string[]]@($paths | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { throw 'file mutation input is missing target path' }
            $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $workspaceRoot -Path $_ -Label 'file mutation target' -AllowMissing
            Assert-HarnessKernelCondition (-not (Test-Path -LiteralPath $fullPath -PathType Container)) 'file mutation target must not be a directory'
            if ($identities.Add($fullPath)) { [string]$_ }
        })
    }

    return New-HarnessAdapterResponse -Operation preflight_action -Value (Assert-HarnessProtectedAction -RepoRoot $repoRoot -WorkspaceRoot $workspaceRoot `
        -SessionMode $SessionMode -ActionMode $ActionMode -TaskId $TaskId -ExpectedVersion $ExpectedVersion `
        -CommandText $commandText -ChangedPaths $paths -Environment $Environment `
        -DryRun:$DryRun -UserInstruction $UserInstruction) -Keys @('allowed','protected','matched_rules','required_scopes','approval_id','operation_identity','protected_operation')
}

function Invoke-HarnessAdapterControlledWrite {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[AllowEmptyString()][string]$Environment='',
        [Parameter(Mandatory)][string]$TargetPath,[Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][ValidatePattern('^(?:missing|sha256:[0-9a-f]{64})$')][string]$ExpectedCurrentSha256,
        [AllowEmptyString()][string]$TaskId='',[Nullable[int]]$ExpectedVersion=$null,[AllowEmptyString()][string]$ExecutionProfile='',
        [AllowEmptyString()][string]$ContractPath='',[AllowEmptyString()][string]$ContractDigest='',[AllowEmptyString()][string]$ApprovalId='',
        [Nullable[bool]]$DryRun=$null)

    return New-HarnessAdapterResponse -Operation controlled_write -Value (Invoke-HarnessControlledWrite -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot `
        -Environment $Environment -Path $TargetPath -Content $Content `
        -ExpectedSourceDigest (Get-HarnessUtf8TextSha256 -Text $Content) `
        -ExpectedCurrentDigest $ExpectedCurrentSha256 -TaskId $TaskId `
        -ExpectedVersion $ExpectedVersion -ExecutionProfile $ExecutionProfile `
        -ContractPath $ContractPath -ContractDigest $ContractDigest `
        -ApprovalId $ApprovalId -DryRun $DryRun) -Keys @('written','dry_run','path','digest','protected','matched_rules','approval_id','operation_identity','protected_operation')
}

Export-ModuleMember -Function Invoke-HarnessAdapterPreflightAction,Invoke-HarnessAdapterControlledWrite
