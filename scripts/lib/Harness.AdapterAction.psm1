Import-Module (Join-Path $PSScriptRoot 'Harness.ProtectedAction.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.ControlledWrite.psm1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')

function Get-HarnessApplyPatchChangedPaths {
    param([Parameter(Mandatory)][string]$PatchText)

    $text = $PatchText.Replace("`r`n","`n")
    if ($text.Contains([char]13) -or $text.EndsWith("`n`n",[StringComparison]::Ordinal)) { throw 'direct apply_patch input has an invalid patch envelope' }
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

        $target = [regex]::Match($(if ($mode -ceq 'Update File') { $line.TrimEnd() } else { $trimmed }),'^\*\*\* (?:(?<mode>Add File|Update File|Delete File)|(?<move>Move to)): (?<path>.*)$')
        if ($target.Success) {
            if ($target.Groups['move'].Success) {
                if ($mode -cne 'Update File') { throw 'direct apply_patch input contains an invalid patch hunk' }
                if ($state -ceq 'eof') { throw 'direct apply_patch input contains content after End of File' }
                if ($state -cne 'none') { throw 'direct apply_patch input contains an invalid Move to directive' }
                $state = 'moved'
            } else {
                if ($mode -ceq 'Update File' -and $state -cnotin @('have','eof')) { throw 'direct apply_patch input contains an empty Update File hunk' }
                $mode = $target.Groups['mode'].Value
                $state = 'none'
            }
            $path = $target.Groups['path'].Value
            if ([string]::IsNullOrEmpty($path) -or $path -cne $path.Trim() -or $path.IndexOfAny([char[]]@(0,10,13)) -ge 0) { throw 'direct apply_patch input contains an invalid target path' }
            $driveAbsolute = [IO.Path]::IsPathFullyQualified($path) -and $path -cmatch '^[A-Za-z]:[\\/]'
            if ((-not $driveAbsolute -and ($path.StartsWith('/',[StringComparison]::Ordinal) -or $path.StartsWith('\',[StringComparison]::Ordinal) -or $path.Contains(':'))) -or ($driveAbsolute -and $path.Substring(2).Contains(':'))) {
                throw 'direct patch target must be relative or a fully qualified Windows drive path'
            }
            $componentPath = if ($driveAbsolute) { $path.Substring(3) } else { $path }
            if (@([regex]::Split($componentPath,'[\\/]') | Where-Object {
                [string]::IsNullOrEmpty($_) -or $_ -cin @('.','..') -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $_.IndexOfAny([char[]](0..31 + @(60,62,34,124,63,42))) -ge 0 -or $_.EndsWith('.',[StringComparison]::Ordinal) -or $_.EndsWith(' ',[StringComparison]::Ordinal)
            } | Select-Object -First 1).Count) { throw 'direct apply_patch input contains an invalid target path' }
            if ($keys.Add($path.Replace('/','\'))) { $paths.Add($path) }
            continue
        }

        if ($mode -ceq 'Add File' -and $line.StartsWith('+',[StringComparison]::Ordinal)) { continue }
        if ($mode -cne 'Update File') { throw 'direct apply_patch input contains an invalid patch hunk' }
        if ($state -ceq 'eof' -and [string]::IsNullOrWhiteSpace($line)) { continue }
        if ($state -ceq 'eof') { throw 'direct apply_patch input contains content after End of File' }
        if ($line.TrimEnd() -ceq '*** End of File') {
            if ($state -cne 'have') { throw 'direct apply_patch input contains an invalid End of File directive' }
            $state = 'eof'
            continue
        }

        if ($line.TrimEnd() -ceq '@@' -or $line.TrimEnd().StartsWith('@@ ',[StringComparison]::Ordinal)) {
            if ($state -ceq 'need') { throw 'direct apply_patch input contains an empty Update File chunk' }
            $state = 'need'
            continue
        }
        if ($line.TrimEnd().StartsWith('*** ',[StringComparison]::Ordinal)) { throw 'direct apply_patch input contains an unsupported patch directive' }
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

function Test-HarnessShellPatchInvocation {
    param([string]$Text)

    $keyword = '(?i)(?<![A-Za-z0-9_])(?:apply_patch|applypatch)(?![A-Za-z0-9_])'
    # Removing delimiters here only detects potential calls; it never proves safety.
    $potential = $Text -replace '[''"\\`]', ''
    if ($Text -notmatch $keyword -and $potential -notmatch $keyword) { return $false }

    # No trusted dialect: recognize static argument data, not shell programs.
    # Even quoted data is bounded: no whitespace, control operators, interpolation
    # or dialect-dependent escaping. Quotes never hide executable-looking syntax.
    $argument = '''[A-Za-z0-9_./:\\#-]*''|"[A-Za-z0-9_./:#-]*"|[A-Za-z0-9_./:-]+'
    $command = '(?<command>rg|grep|Select-String|echo|printf|Write-Output|Write-Host|Get-Content|cat|type|Out-String)'
    $shape = '\A[ \t]*' + $command + '(?:[ \t]+(?<data>' + $argument + '))+[ \t]*(?:\r?\n)?\z'
    $literal = [regex]::Match($Text,$shape)
    if (-not $literal.Success) { return $true }

    $remaining = $Text
    $data = $literal.Groups['data'].Captures
    for ($index = $data.Count - 1; $index -ge 0; $index--) {
        $value = $data[$index].Value
        if ($value[0] -in @([char]39,[char]34)) { $value = $value.Substring(1,$value.Length - 2) }
        # Only known data options; e.g. a search preprocessor is not a data argument.
        if ($value.StartsWith('-') -and $value -cnotin @('--','-n','-i','-F','-e','--fixed-strings','--line-number','-Pattern','-Path','-LiteralPath')) {
            return $true
        }
        $remaining = $remaining.Remove($data[$index].Index,$data[$index].Length).Insert($data[$index].Index,' ')
    }
    # This removes only the keyword refusal. The untouched command still reaches policy.
    return $remaining -match $keyword
}

function Invoke-HarnessAdapterPreflightAction {
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

    $preflightStage = 'workspace'
    try {
        $repoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
        $primaryRoot = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { '' } else { Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot }
        $fallbackRoot = if ([string]::IsNullOrWhiteSpace($WorkspaceRootFallback)) { '' } else { Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRootFallback }
        Assert-HarnessKernelCondition (-not $primaryRoot -or -not $fallbackRoot -or $primaryRoot.Equals($fallbackRoot,[StringComparison]::OrdinalIgnoreCase)) 'Codex PreToolUse cwd conflicts with DEV_HARNESS_WORKSPACE_ROOT'
        $workspaceRoot,$paths,$commandText = $(if ($primaryRoot) { $primaryRoot } elseif ($fallbackRoot) { $fallbackRoot } else { throw 'Codex PreToolUse input is missing cwd and DEV_HARNESS_WORKSPACE_ROOT' }),[string[]]@($ChangedPaths),$ShellText
        $kind = $ActionKind.ToLowerInvariant()
        $preflightStage = 'action-input'
        if ($kind -cin @('shell','apply_patch')) {
            $isShell = $kind -ceq 'shell'
            $requiredText,$otherText = if ($isShell) { $ShellText,$PatchText } else { $PatchText,$ShellText }
            Assert-HarnessKernelCondition (-not [string]::IsNullOrWhiteSpace($requiredText) -and -not $otherText -and -not $paths.Count) "$kind preflight action shape is invalid"
            if ($isShell) {
                Assert-HarnessKernelCondition (-not (Test-HarnessShellPatchInvocation -Text $commandText)) 'Bash shell-form apply_patch is denied because Codex PreToolUse does not expose the effective tool workdir or environment identity'
            } else {
                if (-not $primaryRoot) { throw 'direct patch requires a bound host cwd' }
                $paths = [string[]]@(Get-HarnessApplyPatchChangedPaths -PatchText $PatchText)
            }
        } elseif ($kind -ceq 'file_mutation') {
            Assert-HarnessKernelCondition (-not $ShellText -and -not $PatchText -and $paths.Count -gt 0) 'file mutation preflight action shape is invalid'
        } elseif ($kind -ceq 'normalized_action' -and $PatchText) { throw 'normalized preflight action must not carry patch_text' }
        $preflightStage = 'target'
        if ($ActionKind -cne 'shell') {
            $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $paths = [string[]]@($paths | ForEach-Object {
                if ([string]::IsNullOrWhiteSpace($_)) { throw 'file mutation input is missing target path' }
                # Direct host cwd equals the checked authorization root; the existing resolver performs the single resolution.
                $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $workspaceRoot -Path $_ -Label 'file mutation target' -AllowMissing
                Assert-HarnessKernelCondition (-not (Test-Path -LiteralPath $fullPath -PathType Container)) 'file mutation target must not be a directory'
                if ($identities.Add($fullPath)) { $fullPath }
            })
        }

        $preflightStage = 'policy'
        return New-HarnessAdapterResponse -Operation preflight_action -Value (Assert-HarnessProtectedAction -RepoRoot $repoRoot -WorkspaceRoot $workspaceRoot `
            -SessionMode $SessionMode -ActionMode $ActionMode -TaskId $TaskId -ExpectedVersion $ExpectedVersion `
            -CommandText $commandText -ChangedPaths $paths -Environment $Environment `
            -DryRun:$DryRun -UserInstruction $UserInstruction) -Keys @('allowed','protected','matched_rules','required_scopes','approval_id','operation_identity','protected_operation')
    } catch {
        $_.Exception.Data['harness_preflight_stage'] = $preflightStage
        throw
    }
}

function Invoke-HarnessAdapterControlledWrite {
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

    return New-HarnessAdapterResponse -Operation controlled_write -Value (Invoke-HarnessControlledWrite -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot `
        -Environment $Environment -Path $TargetPath -Content $Content `
        -ExpectedSourceDigest (Get-HarnessUtf8TextSha256 -Text $Content) `
        -ExpectedCurrentDigest $ExpectedCurrentSha256 -TaskId $TaskId `
        -ExpectedVersion $ExpectedVersion -ExecutionProfile $ExecutionProfile `
        -ContractPath $ContractPath -ContractDigest $ContractDigest `
        -ApprovalId $ApprovalId -DryRun $DryRun) -Keys @('written','dry_run','path','digest','protected','matched_rules','approval_id','operation_identity','protected_operation')
}

Export-ModuleMember -Function Invoke-HarnessAdapterPreflightAction,Invoke-HarnessAdapterControlledWrite
