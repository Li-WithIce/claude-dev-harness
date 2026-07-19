[CmdletBinding()]
param(
    [string]$ManifestPath = "",
    [string]$RecoveryManifestPath = "",
    [string]$WorkspaceRoot = "",
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'scripts\install-transaction-common.ps1')

function Read-JsonObject {
    param([string]$Path)

    $raw = Read-FileUtf8 -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return ConvertFrom-InstallJson -Json $raw
}

function Write-InstallRegistry {
    param([string]$Path, $Registry, [Parameter(Mandatory = $true)][string]$ExpectedCurrentDigest)
    $Registry['updated_at'] = Get-Date -Format 's'
    Write-InstallStateTextAtomic -Path $Path -Content (ConvertTo-Json -InputObject $Registry -Depth 50) -ExpectedCurrentDigest $ExpectedCurrentDigest
}

function Get-BackupRecordScope {
    param(
        $Record,
        $Manifest
    )

    foreach ($userGlobalRoot in @($Manifest['claude_home'], $Manifest['codex_home'], $Manifest['agents_home'])) {
        if (-not [string]::IsNullOrWhiteSpace($userGlobalRoot) -and
            (Test-PathWithinRoot -Path $Record['path'] -RootPath $userGlobalRoot)) {
            return 'user-global'
        }
    }

    if ($Record['scope'] -in @('workspace', 'user-global')) {
        return [string]$Record['scope']
    }

    if (Test-PathWithinRoot -Path $Record['path'] -RootPath $Manifest['workspace_root']) {
        return 'workspace'
    }

    throw "Cannot classify backup outside workspace and managed user-global roots: $($Record['path'])"
}

function Test-IsHarnessHookCommand {
    param(
        [string]$Command,
        [string]$ClaudeHome,
        [System.Collections.Generic.HashSet[string]]$ManagedCommands
    )

    if ([string]::IsNullOrWhiteSpace($Command) -or [string]::IsNullOrWhiteSpace($ClaudeHome)) {
        return $false
    }
    if ($null -ne $ManagedCommands -and $ManagedCommands.Contains($Command.Trim())) {
        return $true
    }
    $preToolPath = Join-Path $ClaudeHome 'hooks-memory\pretooluse.ps1'
    $preToolCommand = 'pwsh -NoProfile -NonInteractive -File "{0}"' -f $preToolPath
    $quotedPreToolCommand = "pwsh -NoProfile -NonInteractive -File '{0}'" -f $preToolPath.Replace("'", "''")
    $windowsPowerShell = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe'
    $codexLauncherPath = Join-Path $ClaudeHome 'hooks-memory\codex-pretooluse-launcher.ps1'
    $codexLauncherCommand = '{0} -NoLogo -NoProfile -NonInteractive -Command . ''{1}''' -f $windowsPowerShell,$codexLauncherPath.Replace("'", "''")
    $pipelineCodexLauncherCommand = '{0} -NoLogo -NoProfile -NonInteractive -Command . ''{1}'' -PipelineInput $input' -f $windowsPowerShell,$codexLauncherPath.Replace("'", "''")
    $legacyCodexLauncherCommand = '{0} -NoLogo -NoProfile -NonInteractive -File "{1}"' -f $windowsPowerShell,$codexLauncherPath
    if ($Command.Trim().Equals($preToolCommand, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Command.Trim().Equals($quotedPreToolCommand, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Command.Trim().Equals($codexLauncherCommand, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Command.Trim().Equals($pipelineCodexLauncherCommand, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Command.Trim().Equals($legacyCodexLauncherCommand, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    foreach ($hookName in @('userpromptsubmit.js','stop.js','posttooluse.js')) {
        $expectedCommand = 'node "{0}"' -f (Join-Path $ClaudeHome "hooks-memory\$hookName")
        if ($Command.Trim().Equals($expectedCommand, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-SemanticManagedHookCommands {
    param([Parameter(Mandatory = $true)]$Identity)

    $commands = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ownedHooks = @($Identity['managed_hooks'])
    if ($Identity.Contains('preimage_managed_hooks')) {
        $ownedHooks += @($Identity['preimage_managed_hooks'])
    }
    foreach ($ownedHook in $ownedHooks) {
        $command = [string]$ownedHook['hook']['command']
        if ([string]::IsNullOrWhiteSpace($command)) {
            throw 'Semantic hook identity contains an empty managed command'
        }
        [void]$commands.Add($command.Trim())
    }
    return ,$commands
}

function Remove-HarnessHooksFromSettings {
    param(
        $Settings,
        [string]$ClaudeHome,
        [System.Collections.Generic.HashSet[string]]$ManagedCommands
    )

    $result = if ($null -eq $Settings) { [ordered]@{} } else { ConvertTo-NormalizedObject -Value $Settings }
    if (-not $result.Contains('hooks') -or -not ($result['hooks'] -is [System.Collections.IDictionary])) {
        return $result
    }

    $hooks = ConvertTo-NormalizedObject -Value $result['hooks']
    foreach ($eventName in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'PostToolUse')) {
        if (-not $hooks.Contains($eventName)) {
            continue
        }
        $sections = New-Object System.Collections.ArrayList
        foreach ($section in @($hooks[$eventName])) {
            if (-not ($section -is [System.Collections.IDictionary]) -or -not $section.Contains('hooks')) {
                [void]$sections.Add((ConvertTo-NormalizedObject -Value $section))
                continue
            }

            $preservedHooks = New-Object System.Collections.ArrayList
            $removedManagedHook = $false
            foreach ($hook in @($section['hooks'])) {
                $command = if ($hook -is [System.Collections.IDictionary] -and $hook.Contains('command')) { [string]$hook['command'] } else { '' }
                if (Test-IsHarnessHookCommand -Command $command -ClaudeHome $ClaudeHome -ManagedCommands $ManagedCommands) {
                    $removedManagedHook = $true
                } else {
                    [void]$preservedHooks.Add((ConvertTo-NormalizedObject -Value $hook))
                }
            }
            if (-not $removedManagedHook) {
                [void]$sections.Add((ConvertTo-NormalizedObject -Value $section))
            } elseif ($preservedHooks.Count -gt 0) {
                $preservedSection = ConvertTo-NormalizedObject -Value $section
                $preservedSection['hooks'] = $preservedHooks
                [void]$sections.Add($preservedSection)
            }
        }
        if ($sections.Count -gt 0) {
            $hooks[$eventName] = $sections
        } else {
            $hooks.Remove($eventName)
        }
    }

    if ($hooks.Count -gt 0) {
        $result['hooks'] = $hooks
    } else {
        $result.Remove('hooks')
    }
    return $result
}

function Add-BaselineHarnessHooks {
    param(
        $Settings,
        $Baseline,
        [string]$ClaudeHome,
        [System.Collections.Generic.HashSet[string]]$ManagedCommands
    )

    if ($null -eq $Baseline -or -not $Baseline.Contains('hooks') -or -not ($Baseline['hooks'] -is [System.Collections.IDictionary])) {
        return $Settings
    }
    if (-not $Settings.Contains('hooks') -or -not ($Settings['hooks'] -is [System.Collections.IDictionary])) {
        $Settings['hooks'] = [ordered]@{}
    }

    foreach ($eventName in @('PreToolUse', 'UserPromptSubmit', 'Stop', 'PostToolUse')) {
        if (-not $Baseline['hooks'].Contains($eventName)) {
            continue
        }
        $sections = New-Object System.Collections.ArrayList
        foreach ($section in @(if ($Settings['hooks'].Contains($eventName)) { @($Settings['hooks'][$eventName]) } else { @() })) {
            [void]$sections.Add((ConvertTo-NormalizedObject -Value $section))
        }
        foreach ($baselineSection in @($Baseline['hooks'][$eventName])) {
            if (-not ($baselineSection -is [System.Collections.IDictionary]) -or -not $baselineSection.Contains('hooks')) {
                continue
            }
            $managedHooks = New-Object System.Collections.ArrayList
            foreach ($hook in @($baselineSection['hooks'])) {
                $command = if ($hook -is [System.Collections.IDictionary] -and $hook.Contains('command')) { [string]$hook['command'] } else { '' }
                if (Test-IsHarnessHookCommand -Command $command -ClaudeHome $ClaudeHome -ManagedCommands $ManagedCommands) {
                    [void]$managedHooks.Add((ConvertTo-NormalizedObject -Value $hook))
                }
            }
            if ($managedHooks.Count -gt 0) {
                $restoredSection = ConvertTo-NormalizedObject -Value $baselineSection
                $restoredSection['hooks'] = $managedHooks
                [void]$sections.Add($restoredSection)
            }
        }
        if ($sections.Count -gt 0) {
            $Settings['hooks'][$eventName] = $sections
        }
    }
    return $Settings
}

function Restore-ClaudeSettingsSemantic {
    param(
        $Record,
        $Manifest
    )

    $currentSnapshot = Read-InstallTextSnapshot -Path $Record['path']
    if ([string]$currentSnapshot.Identity['item_type'] -eq 'missing') {
        return $false
    }
    $currentRaw = $currentSnapshot.Content
    if ([string]::IsNullOrWhiteSpace($currentRaw)) {
        return $true
    }

    $baseline = if ([bool]$Record['existed']) { Read-JsonObject -Path $Record['backup_path'] } else { $null }
    $current = ConvertFrom-InstallJson -Json $currentRaw
    $managedCommands = Get-SemanticManagedHookCommands -Identity $Record['expected_postimage']
    $result = Remove-HarnessHooksFromSettings -Settings $current -ClaudeHome $Manifest['claude_home'] -ManagedCommands $managedCommands
    $result = Add-BaselineHarnessHooks -Settings $result -Baseline $baseline -ClaudeHome $Manifest['claude_home'] -ManagedCommands $managedCommands
    if ([bool]$Record['existed'] -and $null -ne $baseline -and
        (ConvertTo-InstallJson -Value $result -Depth 100 -Compress) -eq (ConvertTo-InstallJson -Value $baseline -Depth 100 -Compress)) {
        Copy-InstallStateFileAtomic `
            -SourcePath $Record['backup_path'] `
            -Path $Record['path'] `
            -ExpectedCurrentIdentity $currentSnapshot.Identity `
            -ExpectedDesiredIdentity (Get-InstallBackupRecordPreimageIdentity -Record $Record)
        return $true
    }
    if ($result.Count -eq 0 -and -not [bool]$Record['existed']) {
        [void](Invoke-InstallExactPathTransition -Path $Record['path'] -SourceIdentity $currentSnapshot.Identity -DesiredIdentity (New-InstallExactMissingIdentity))
        return $false
    }

    Write-InstallStateTextAtomic -Path $Record['path'] -Content (ConvertTo-InstallJson -Value $result -Depth 100) -ExpectedCurrentDigest ([string]$currentSnapshot.Identity['sha256'])
    return $true
}

function Test-ClaudeSettingsSemanticRestoreComplete {
    param(
        $Record,
        $Manifest
    )

    try {
        $currentSnapshot = Read-InstallTextSnapshot -Path $Record['path']
        if ([string]$currentSnapshot.Identity['item_type'] -eq 'missing') {
            return -not [bool]$Record['existed']
        }
        if ([string]::IsNullOrWhiteSpace($currentSnapshot.Content)) {
            return $false
        }

        $baseline = if ([bool]$Record['existed']) { Read-JsonObject -Path $Record['backup_path'] } else { $null }
        $current = ConvertFrom-InstallJson -Json $currentSnapshot.Content
        $managedCommands = Get-SemanticManagedHookCommands -Identity $Record['expected_postimage']
        $result = Remove-HarnessHooksFromSettings -Settings $current -ClaudeHome $Manifest['claude_home'] -ManagedCommands $managedCommands
        $result = Add-BaselineHarnessHooks -Settings $result -Baseline $baseline -ClaudeHome $Manifest['claude_home'] -ManagedCommands $managedCommands
        $resultJson = ConvertTo-InstallJson -Value $result -Depth 100 -Compress

        if ([bool]$Record['existed'] -and $null -ne $baseline -and
            $resultJson -eq (ConvertTo-InstallJson -Value $baseline -Depth 100 -Compress)) {
            return Test-InstallExactIdentityEqual `
                -Left $currentSnapshot.Identity `
                -Right (Get-InstallBackupRecordPreimageIdentity -Record $Record)
        }
        if ($result.Count -eq 0 -and -not [bool]$Record['existed']) {
            return $false
        }
        return $resultJson -eq (ConvertTo-InstallJson -Value $current -Depth 100 -Compress)
    } catch {
        return $false
    }
}

function Get-WorkspaceGitIgnoreRestoreProjection {
    param(
        $Record,
        [string]$CurrentRaw
    )

    $managedComment = '# dev-harness workspace artifacts'
    $legacyManagedComment = '# claude-dev-harness workspace artifacts'
    $requiredEntries = @('.assistant/','AGENTS.md','.claude')
    $baselineRaw = if ([bool]$Record['existed']) { Read-FileUtf8 -Path $Record['backup_path'] } else { $null }
    $baselineLines = if ($null -eq $baselineRaw) { @() } else { @([regex]::Split($baselineRaw, '\r?\n')) }
    $baselineTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $baselineLines) {
        [void]$baselineTokens.Add($line.Trim())
    }
    $introducedEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $requiredEntries) {
        if (-not $baselineTokens.Contains($entry)) {
            [void]$introducedEntries.Add($entry)
        }
    }
    $removedEntries = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $baselineHasManaged = $baselineTokens.Contains($managedComment)
    $baselineHasLegacy = $baselineTokens.Contains($legacyManagedComment)
    $currentLines = @([regex]::Split($currentRaw, '\r?\n'))
    $currentHasLegacy = @($currentLines | Where-Object { $_.Trim().Equals($legacyManagedComment, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    $commentDeltaUndone = $false
    $resultLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $currentLines) {
        $trimmed = $line.Trim()
        if ($introducedEntries.Contains($trimmed) -and -not $removedEntries.Contains($trimmed)) {
            [void]$removedEntries.Add($trimmed)
            continue
        }

        if (-not $commentDeltaUndone -and $trimmed.Equals($managedComment, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (-not $baselineHasManaged -and -not $baselineHasLegacy) {
                $commentDeltaUndone = $true
                continue
            }
            if (-not $baselineHasManaged -and $baselineHasLegacy) {
                if (-not $currentHasLegacy) {
                    [void]$resultLines.Add($legacyManagedComment)
                }
                $commentDeltaUndone = $true
                continue
            }
        }
        [void]$resultLines.Add($line)
    }

    if ($baselineHasManaged -and $baselineHasLegacy -and -not $currentHasLegacy) {
        $currentHasManaged = @($currentLines | Where-Object { $_.Trim().Equals($managedComment, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ($currentHasManaged) {
            [void]$resultLines.Add($legacyManagedComment)
        }
    }

    $newline = if ($currentRaw -match "`r`n") { "`r`n" } else { "`n" }
    $resultRaw = ($resultLines -join $newline).TrimEnd([char[]]@("`r", "`n"))
    if ([bool]$Record['existed'] -and
        $resultRaw -eq $baselineRaw.TrimEnd([char[]]@("`r", "`n"))) {
        return [pscustomobject]@{ ItemType = 'file'; Content = $baselineRaw }
    }
    if ([string]::IsNullOrWhiteSpace($resultRaw) -and -not [bool]$Record['existed']) {
        return [pscustomobject]@{ ItemType = 'missing'; Content = $null }
    }

    return [pscustomobject]@{ ItemType = 'file'; Content = ($resultRaw + $newline) }
}

function Restore-WorkspaceGitIgnoreSemantic {
    param($Record)

    $currentSnapshot = Read-InstallTextSnapshot -Path $Record['path']
    if ([string]$currentSnapshot.Identity['item_type'] -eq 'missing') {
        return $false
    }
    $projection = Get-WorkspaceGitIgnoreRestoreProjection -Record $Record -CurrentRaw $currentSnapshot.Content
    if ([string]$projection.ItemType -eq 'missing') {
        [void](Invoke-InstallExactPathTransition -Path $Record['path'] -SourceIdentity $currentSnapshot.Identity -DesiredIdentity (New-InstallExactMissingIdentity))
        return $false
    }

    Write-InstallStateTextAtomic -Path $Record['path'] -Content $projection.Content -ExpectedCurrentDigest ([string]$currentSnapshot.Identity['sha256'])
    return $true
}

function Test-WorkspaceGitIgnoreSemanticRestoreComplete {
    param($Record)

    try {
        $currentSnapshot = Read-InstallTextSnapshot -Path $Record['path']
        if ([string]$currentSnapshot.Identity['item_type'] -eq 'missing') {
            return -not [bool]$Record['existed']
        }
        $projection = Get-WorkspaceGitIgnoreRestoreProjection -Record $Record -CurrentRaw $currentSnapshot.Content
        return [string]$projection.ItemType -eq 'file' -and $currentSnapshot.Content -ceq [string]$projection.Content
    } catch {
        return $false
    }
}

function Test-InstallJsonValueEqual {
    param($Left, $Right)

    if ($null -eq $Left -or $null -eq $Right) {
        return $null -eq $Left -and $null -eq $Right
    }
    if ($Left -is [System.Collections.IDictionary] -or $Right -is [System.Collections.IDictionary]) {
        if (-not ($Left -is [System.Collections.IDictionary]) -or -not ($Right -is [System.Collections.IDictionary])) {
            return $false
        }
        [string[]]$leftKeys = @($Left.Keys | ForEach-Object { [string]$_ })
        [string[]]$rightKeys = @($Right.Keys | ForEach-Object { [string]$_ })
        [array]::Sort($leftKeys,[System.StringComparer]::Ordinal)
        [array]::Sort($rightKeys,[System.StringComparer]::Ordinal)
        if (($leftKeys -join "`n") -cne ($rightKeys -join "`n")) {
            return $false
        }
        foreach ($key in $leftKeys) {
            if (-not (Test-InstallJsonValueEqual -Left $Left[$key] -Right $Right[$key])) {
                return $false
            }
        }
        return $true
    }
    $leftIsList = $Left -is [System.Collections.IList] -and -not ($Left -is [string])
    $rightIsList = $Right -is [System.Collections.IList] -and -not ($Right -is [string])
    if ($leftIsList -or $rightIsList) {
        if (-not $leftIsList -or -not $rightIsList -or $Left.Count -ne $Right.Count) {
            return $false
        }
        for ($index = 0; $index -lt $Left.Count; $index++) {
            if (-not (Test-InstallJsonValueEqual -Left $Left[$index] -Right $Right[$index])) {
                return $false
            }
        }
        return $true
    }
    if ($Left.GetType() -ne $Right.GetType()) {
        return $false
    }
    if ($Left -is [string]) {
        return $Left -ceq $Right
    }
    return $Left.Equals($Right)
}

function Test-WorkspaceGitIgnorePostimage {
    param(
        [string]$Path,
        $Identity
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $lines = @([regex]::Split((Read-FileUtf8 -Path $Path), '\r?\n'))
    $getCount = {
        param([string]$ExpectedLine)
        return @($lines | Where-Object {
            $_.Trim().Equals($ExpectedLine, [System.StringComparison]::OrdinalIgnoreCase)
        }).Count
    }
    foreach ($delta in @($Identity['line_delta'])) {
        switch ([string]$delta['operation']) {
            'add' {
                if ((& $getCount ([string]$delta['line'])) -ne [int]$delta['expected_count']) { return $false }
            }
            'remove' {
                if ((& $getCount ([string]$delta['line'])) -ne 0) { return $false }
            }
            'replace' {
                if ((& $getCount ([string]$delta['from'])) -ne 0 -or
                    (& $getCount ([string]$delta['to'])) -ne [int]$delta['expected_to_count']) { return $false }
            }
            default { return $false }
        }
    }
    return $true
}

function Test-ClaudeSettingsPostimage {
    param(
        [string]$Path,
        $Identity
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        $settings = Read-JsonObject -Path $Path
    } catch {
        return $false
    }
    if (-not ($settings -is [System.Collections.IDictionary]) -or
        -not ($settings['hooks'] -is [System.Collections.IDictionary])) {
        return $false
    }
    $hooks = $settings['hooks']
    foreach ($expected in @($Identity['managed_hooks'])) {
        $eventName = [string]$expected['event']
        if (-not $hooks.Contains($eventName) -or -not ($hooks[$eventName] -is [System.Collections.IList])) {
            return $false
        }
        $expectedCommand = [string]$expected['hook']['command']
        $commandCount = 0
        foreach ($event in $hooks.Values) {
            if (-not ($event -is [System.Collections.IList])) { return $false }
            foreach ($section in @($event)) {
                if (-not ($section -is [System.Collections.IDictionary]) -or
                    -not ($section['hooks'] -is [System.Collections.IList])) { return $false }
                foreach ($hook in @($section['hooks'])) {
                    if ($hook -is [System.Collections.IDictionary] -and
                        [string]$hook['command'] -eq $expectedCommand) {
                        $commandCount++
                    }
                }
            }
        }
        if ($commandCount -ne [int]$expected['multiplicity']) {
            return $false
        }

        $exactCount = 0
        foreach ($section in @($hooks[$eventName])) {
            $sectionIdentity = [ordered]@{}
            foreach ($key in $section.Keys) {
                if ([string]$key -ne 'hooks') {
                    $sectionIdentity[[string]$key] = $section[$key]
                }
            }
            if (-not (Test-InstallJsonValueEqual -Left $sectionIdentity -Right $expected['section'])) {
                continue
            }
            foreach ($hook in @($section['hooks'])) {
                if (Test-InstallJsonValueEqual -Left $hook -Right $expected['hook']) {
                    $exactCount++
                }
            }
        }
        if ($exactCount -ne [int]$expected['multiplicity']) {
            return $false
        }
    }
    return $true
}

function Test-ExpectedPostimageAtPath {
    param(
        [string]$Path,
        $Identity
    )

    Assert-InstallExpectedPostimageShape -Identity $Identity -Label "Expected postimage for $Path"
    if ([string]$Identity['mode'] -eq 'exact') {
        return Test-InstallExactIdentityEqual -Left (Get-InstallManagedPathIdentity -Path $Path) -Right $Identity
    }
    switch ([string]$Identity['contract']) {
        'workspace-gitignore/v1' { return Test-WorkspaceGitIgnorePostimage -Path $Path -Identity $Identity }
        'claude-settings/v1' { return Test-ClaudeSettingsPostimage -Path $Path -Identity $Identity }
        default { return $false }
    }
}

function Test-BackupPreimageMatchesExpectedPostimage {
    param(
        $PreviousRecord,
        $ExpectedIdentity
    )

    if ([string]$ExpectedIdentity['mode'] -eq 'exact') {
        return Test-InstallExactIdentityEqual `
            -Left (Get-InstallBackupRecordPreimageIdentity -Record $PreviousRecord) `
            -Right $ExpectedIdentity
    }
    if (-not [bool]$PreviousRecord['existed'] -or [string]$PreviousRecord['item_type'] -ne 'file') {
        return $false
    }
    $preimagePath = [string]$PreviousRecord['backup_path']
    switch ([string]$ExpectedIdentity['contract']) {
        'workspace-gitignore/v1' { return Test-WorkspaceGitIgnorePostimage -Path $preimagePath -Identity $ExpectedIdentity }
        'claude-settings/v1' { return Test-ClaudeSettingsPostimage -Path $preimagePath -Identity $ExpectedIdentity }
        default { return $false }
    }
}

function Get-InstallRestorePlan {
    param(
        [string[]]$WorkspaceManifestPaths,
        [string[]]$GlobalManifestPaths,
        [bool]$RestoreUserGlobal,
        $ManifestCache,
        $ReleasedTargetHistory = @{}
    )

    $plan = New-Object System.Collections.Generic.List[object]
    for ($manifestIndex = @($WorkspaceManifestPaths).Count - 1; $manifestIndex -ge 0; $manifestIndex--) {
        $manifestPath = Get-NormalizedPath -Path $WorkspaceManifestPaths[$manifestIndex]
        $manifest = $ManifestCache[$manifestPath]
        $records = @($manifest['backups'])
        [array]::Reverse($records)
        foreach ($record in $records) {
            if ((Get-BackupRecordScope -Record $record -Manifest $manifest) -eq 'workspace') {
                $plan.Add([pscustomobject]@{ Record = $record; Manifest = $manifest; Scope = 'workspace' }) | Out-Null
            }
        }
    }
    if ($RestoreUserGlobal) {
        for ($manifestIndex = @($GlobalManifestPaths).Count - 1; $manifestIndex -ge 0; $manifestIndex--) {
            $manifestPath = Get-NormalizedPath -Path $GlobalManifestPaths[$manifestIndex]
            $manifest = $ManifestCache[$manifestPath]
            $records = @($manifest['backups'])
            [array]::Reverse($records)
            foreach ($record in $records) {
                $targetPath = Get-NormalizedPath -Path $record['path']
                $isReleasedHistory = $ReleasedTargetHistory -is [System.Collections.IDictionary] -and
                    $ReleasedTargetHistory.Contains($targetPath) -and
                    @($ReleasedTargetHistory[$targetPath]) -contains $manifestPath
                if (-not $isReleasedHistory -and
                    (Get-BackupRecordScope -Record $record -Manifest $manifest) -eq 'user-global') {
                    $plan.Add([pscustomobject]@{ Record = $record; Manifest = $manifest; Scope = 'user-global' }) | Out-Null
                }
            }
        }
    }
    return $plan.ToArray()
}

function Assert-InstallRestorePlanChain {
    param([object[]]$Plan)

    $chains = @{}
    foreach ($entry in $Plan) {
        $targetPath = Get-NormalizedPath -Path $entry.Record['path']
        if (-not $chains.ContainsKey($targetPath)) {
            $chains[$targetPath] = New-Object System.Collections.Generic.List[object]
        }
        $chains[$targetPath].Add($entry) | Out-Null
    }
    foreach ($chain in $chains.Values) {
        for ($index = 1; $index -lt $chain.Count; $index++) {
            if (-not (Test-BackupPreimageMatchesExpectedPostimage `
                    -PreviousRecord $chain[$index - 1].Record `
                    -ExpectedIdentity $chain[$index].Record['expected_postimage'])) {
                throw "Install restore chain identity mismatch: $($chain[$index].Record['path'])"
            }
        }
    }
}

function Get-InstallRestorePlanPrefix {
    param(
        [object[]]$Plan,
        [switch]$RequireInitial,
        $ProjectedExactIdentities = @{}
    )

    Assert-InstallRestorePlanChain -Plan $Plan
    $targets = @($Plan | ForEach-Object { Get-NormalizedPath -Path $_.Record['path'] } | Select-Object -Unique)
    $matchingPrefixes = New-Object System.Collections.Generic.List[int]
    $maximumPrefix = if ($RequireInitial) { 0 } else { @($Plan).Count }
    for ($prefix = 0; $prefix -le $maximumPrefix; $prefix++) {
        $matches = $true
        foreach ($targetPath in $targets) {
            $nextEntry = $null
            $lastAppliedEntry = $null
            for ($index = 0; $index -lt @($Plan).Count; $index++) {
                $entry = $Plan[$index]
                if ((Get-NormalizedPath -Path $entry.Record['path']) -ne $targetPath) { continue }
                if ($index -lt $prefix) {
                    $lastAppliedEntry = $entry
                } elseif ($null -eq $nextEntry) {
                    $nextEntry = $entry
                }
            }
            $hasProjectedIdentity = $ProjectedExactIdentities -is [System.Collections.IDictionary] -and
                $ProjectedExactIdentities.Contains($targetPath)
            if ($null -ne $nextEntry) {
                $nextIdentity = $nextEntry.Record['expected_postimage']
                $matchesNext = if ($hasProjectedIdentity) {
                    [string]$nextIdentity['mode'] -eq 'exact' -and
                        (Test-InstallExactIdentityEqual -Left $ProjectedExactIdentities[$targetPath] -Right $nextIdentity)
                } else {
                    Test-ExpectedPostimageAtPath -Path $targetPath -Identity $nextIdentity
                }
                if (-not $matchesNext) {
                    $matches = $false
                    break
                }
            } else {
                $currentIdentity = if ($hasProjectedIdentity) {
                    $ProjectedExactIdentities[$targetPath]
                } else {
                    Get-InstallManagedPathIdentity -Path $targetPath
                }
                $lastPostimage = $lastAppliedEntry.Record['expected_postimage']
                $matchesCompletedRestore = if ([string]$lastPostimage['mode'] -eq 'semantic') {
                    if ($hasProjectedIdentity) {
                        $false
                    } else {
                        switch ([string]$lastPostimage['contract']) {
                            'claude-settings/v1' {
                                Test-ClaudeSettingsSemanticRestoreComplete -Record $lastAppliedEntry.Record -Manifest $lastAppliedEntry.Manifest
                            }
                            'workspace-gitignore/v1' {
                                Test-WorkspaceGitIgnoreSemanticRestoreComplete -Record $lastAppliedEntry.Record
                            }
                            default { $false }
                        }
                    }
                } else {
                    $finalPreimage = Get-InstallBackupRecordPreimageIdentity -Record $lastAppliedEntry.Record
                    Test-InstallExactIdentityEqual -Left $currentIdentity -Right $finalPreimage
                }
                if (-not $matchesCompletedRestore) {
                    $matches = $false
                    break
                }
            }
        }
        if ($matches) { $matchingPrefixes.Add($prefix) | Out-Null }
    }
    if ($matchingPrefixes.Count -gt 1) {
        $minimumPrefix = ($matchingPrefixes | Measure-Object -Minimum).Minimum
        $maximumMatchingPrefix = ($matchingPrefixes | Measure-Object -Maximum).Maximum
        $equivalentNoOps = $true
        for ($index = $minimumPrefix; $index -lt $maximumMatchingPrefix; $index++) {
            if (-not (Test-BackupPreimageMatchesExpectedPostimage `
                    -PreviousRecord $Plan[$index].Record `
                    -ExpectedIdentity $Plan[$index].Record['expected_postimage'])) {
                $equivalentNoOps = $false
                break
            }
        }
        if ($equivalentNoOps) {
            return [int]$maximumMatchingPrefix
        }
    }
    if ($matchingPrefixes.Count -ne 1) {
        throw "Install restore plan is not at one unambiguous legal prefix (matches=$($matchingPrefixes.Count))"
    }
    return $matchingPrefixes[0]
}

function Invoke-InstallRestorePlan {
    param(
        [object[]]$Plan,
        [int]$StartIndex = 0
    )

    for ($index = $StartIndex; $index -lt @($Plan).Count; $index++) {
        $entry = $Plan[$index]
        $targetPath = [string]$entry.Record['path']
        if (Restore-BackupRecord -Record $entry.Record -Manifest $entry.Manifest) {
            $script:Restored += $targetPath
        } else {
            $script:Removed += $targetPath
        }
    }
}

function Restore-BackupRecord {
    param(
        $Record,
        $Manifest
    )

    $targetPath = $Record['path']
    $backupPath = $Record['backup_path']
    $itemType = $Record['item_type']
    $linkType = $Record['link_type']
    $linkTarget = $Record['link_target']
    $existed = [bool]$Record['existed']

    if ($itemType -notin @('missing','file','directory','link')) {
        throw "Unsupported backup item_type '$itemType': $targetPath"
    }

    if ((Get-NormalizedPath -Path $targetPath) -eq (Get-NormalizedPath -Path (Join-Path $Manifest['workspace_root'] '.gitignore'))) {
        return Restore-WorkspaceGitIgnoreSemantic -Record $Record
    }
    if ([string]$Record['expected_postimage']['mode'] -eq 'semantic' -and
        [string]$Record['expected_postimage']['contract'] -eq 'claude-settings/v1') {
        $hookSettingsTargets = @(
            Get-NormalizedPath -Path (Join-Path $Manifest['claude_home'] 'settings.json')
            Get-NormalizedPath -Path (Join-Path $Manifest['codex_home'] 'hooks.json')
        )
        if ((Get-NormalizedPath -Path $targetPath) -notin $hookSettingsTargets) {
            throw "Hook settings semantic contract is bound to an invalid restore target: $targetPath"
        }
        return Restore-ClaudeSettingsSemantic -Record $Record -Manifest $Manifest
    }

    $sourceIdentity = $Record['expected_postimage']
    $desiredIdentity = Get-InstallBackupRecordPreimageIdentity -Record $Record
    if ([string]$sourceIdentity['mode'] -ne 'exact') {
        throw "Exact restore requires an exact postimage identity: $targetPath"
    }
    if ($itemType -eq 'file' -and [string]$sourceIdentity['item_type'] -in @('missing','file')) {
        Copy-InstallStateFileAtomic -SourcePath $backupPath -Path $targetPath -ExpectedCurrentIdentity $sourceIdentity -ExpectedDesiredIdentity $desiredIdentity
        return $true
    }

    $materializer = switch ($itemType) {
        'missing' { $null }
        'file' {
            { param($BuildPath) Copy-InstallStateFileAtomic -SourcePath $backupPath -Path $BuildPath -ExpectedCurrentIdentity (New-InstallExactMissingIdentity) -ExpectedDesiredIdentity $desiredIdentity }.GetNewClosure()
        }
        'directory' {
            $copyInstallExactDirectory = Get-Command Copy-InstallExactDirectory -CommandType Function
            { param($BuildPath) & $copyInstallExactDirectory -SourcePath $backupPath -Path $BuildPath }.GetNewClosure()
        }
        'link' {
            {
                param($BuildPath)
                New-Item -ItemType $linkType -Path $BuildPath -Target $linkTarget | Out-Null
            }.GetNewClosure()
        }
    }
    [void](Invoke-InstallExactPathTransition `
        -Path $targetPath `
        -SourceIdentity $sourceIdentity `
        -DesiredIdentity $desiredIdentity `
        -MaterializeDesired $materializer)
    return $existed
}

function Read-InstallManifest {
    param([string]$Path)

    $normalizedPath = Get-NormalizedPath -Path $Path
    $manifest = Read-JsonObject -Path $normalizedPath
    if ($null -eq $manifest) {
        throw "Missing install manifest: $normalizedPath"
    }

    return $manifest
}

function Set-ManifestTransactionStatusBatch {
    param(
        [string[]]$ManifestPaths,
        [string]$Status
    )

    $snapshots = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($manifestPath in @($ManifestPaths | Select-Object -Unique)) {
            $normalizedPath = Get-NormalizedPath -Path $manifestPath
            $raw = Read-FileUtf8 -Path $normalizedPath
            $manifest = ConvertFrom-InstallJson -Json $raw
            [void]$snapshots.Add([pscustomobject]@{ Path = $normalizedPath; Raw = $raw })
            $manifest['transaction_status'] = $Status
            $manifest[($Status + '_at')] = Get-Date -Format 's'
            Write-InstallStateTextAtomic -Path $normalizedPath -Content (ConvertTo-Json -InputObject $manifest -Depth 100)
        }
        return $snapshots.ToArray()
    } catch {
        for ($index = $snapshots.Count - 1; $index -ge 0; $index--) {
            Write-InstallStateTextAtomic -Path $snapshots[$index].Path -Content $snapshots[$index].Raw
        }
        throw
    }
}

function Restore-ManifestTransactionStatusBatch {
    param([object[]]$Snapshots)

    for ($index = @($Snapshots).Count - 1; $index -ge 0; $index--) {
        Write-InstallStateTextAtomic -Path $Snapshots[$index].Path -Content $Snapshots[$index].Raw
    }
}

function Mark-LegacyPointerIfConsumed {
    param(
        [string]$PointerPath,
        [string[]]$ConsumedManifestPaths,
        $ExpectedManifestPlanDigests
    )

    $receiptMarkerIntents = [ordered]@{}
    foreach ($manifestPath in @($ConsumedManifestPaths | Select-Object -Unique)) {
        $manifest = Read-InstallManifest -Path $manifestPath
        if (-not $manifest.Contains('legacy_rebaseline_receipt')) {
            continue
        }
        if (-not ($ExpectedManifestPlanDigests -is [System.Collections.IDictionary])) {
            throw 'Legacy rebaseline receipt requires manifest-plan digest bindings'
        }
        $manifestDigestKey = Get-InstallManifestDigestRegistryKey -ManifestPath $manifestPath
        $expectedManifestPlanDigest = [string]$ExpectedManifestPlanDigests[$manifestDigestKey]
        if ($expectedManifestPlanDigest -notmatch '^[0-9a-f]{64}$' -or
            (Get-InstallManifestPlanDigest -Manifest $manifest) -ne $expectedManifestPlanDigest) {
            throw "Legacy rebaseline receipt manifest changed after uninstall planning: $manifestPath"
        }
        $receipt = $manifest['legacy_rebaseline_receipt']
        if (-not ($receipt -is [System.Collections.IDictionary]) -or
            [string]$receipt['contract'] -ne 'legacy_rebaseline/v1' -or
            [string]$receipt['legacy_pointer_sha256'] -notmatch '^(missing|[0-9a-f]{64})$') {
            throw "Consumed legacy rebaseline receipt is invalid: $manifestPath"
        }
        $manifestRepoRoot = Get-NormalizedPath -Path $manifest['repo_root']
        if ([string]::IsNullOrWhiteSpace($manifestRepoRoot)) {
            throw "Consumed legacy rebaseline receipt manifest has no RepoRoot: $manifestPath"
        }
        $expectedReceiptPointerPath = Get-NormalizedPath -Path (Join-Path $manifestRepoRoot 'backups\active-install.json')
        $receiptPointerPath = Get-NormalizedPath -Path $receipt['legacy_pointer_path']
        if ($receiptPointerPath -ne $expectedReceiptPointerPath) {
            throw "Consumed legacy rebaseline receipt pointer path does not match its manifest RepoRoot: $manifestPath"
        }
        $receiptPointerDigest = [string]$receipt['legacy_pointer_sha256']
        if ($receiptMarkerIntents.Contains($receiptPointerPath) -and
            [string]$receiptMarkerIntents[$receiptPointerPath] -ne $receiptPointerDigest) {
            throw "Consumed legacy rebaseline receipts disagree for pointer path: $receiptPointerPath"
        }
        $receiptMarkerIntents[$receiptPointerPath] = $receiptPointerDigest
    }
    foreach ($receiptPointerPath in @($receiptMarkerIntents.Keys)) {
        $receiptPointerDigest = [string]$receiptMarkerIntents[$receiptPointerPath]
        if ($receiptPointerDigest -match '^[0-9a-f]{64}$') {
            Assert-LegacyPointerMigrationMarkerWritable -UserProfile $env:USERPROFILE -PointerPath $receiptPointerPath
        }
    }
    foreach ($receiptPointerPath in @($receiptMarkerIntents.Keys)) {
        $receiptPointerDigest = [string]$receiptMarkerIntents[$receiptPointerPath]
        if ($receiptPointerDigest -match '^[0-9a-f]{64}$') {
            Set-LegacyPointerMigrationMarked `
                -UserProfile $env:USERPROFILE `
                -PointerPath $receiptPointerPath `
                -ExpectedPointerDigest $receiptPointerDigest
        }
    }

    $normalizedInvokingPointerPath = Get-NormalizedPath -Path $PointerPath
    if ($receiptMarkerIntents.Contains($normalizedInvokingPointerPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $PointerPath -PathType Leaf)) {
        return
    }
    $pointerDigest = Get-InstallStateFileDigest -Path $PointerPath
    try {
        $pointer = Read-JsonObject -Path $PointerPath
        $pointerManifestPath = Get-NormalizedPath -Path $pointer['manifest_path']
    } catch {
        Write-Warning "Ignoring unreadable legacy active-install pointer: $PointerPath"
        return
    }
    if ((Get-InstallStateFileDigest -Path $PointerPath) -ne $pointerDigest) {
        throw "Legacy active-install pointer changed while being read: $PointerPath"
    }

    $normalizedConsumedPaths = @($ConsumedManifestPaths | ForEach-Object { Get-NormalizedPath -Path $_ })
    if ($normalizedConsumedPaths -contains $pointerManifestPath) {
        Assert-LegacyPointerMigrationMarkerWritable -UserProfile $env:USERPROFILE -PointerPath $PointerPath
        Set-LegacyPointerMigrationMarked `
            -UserProfile $env:USERPROFILE `
            -PointerPath $PointerPath `
            -ExpectedPointerDigest $pointerDigest
    }
}

function Assert-ManagedBackupTarget {
    param(
        [string]$TargetPath,
        [string]$Scope,
        [string]$ItemType,
        [bool]$Existed,
        $Manifest
    )

    $target = Get-NormalizedPath -Path $TargetPath
    $hasManagedTargetPlan = $Manifest -is [System.Collections.IDictionary] -and $Manifest.Contains('managed_backup_targets')
    if ($hasManagedTargetPlan) {
        if (-not ($Manifest['managed_backup_targets'] -is [System.Collections.IList])) {
            throw 'Install manifest managed backup target plan must be an array'
        }
        $plannedTargets = @($Manifest['managed_backup_targets'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        if ($plannedTargets -notcontains $target) {
            throw "Backup target is absent from the committed managed target plan: $target"
        }
    }
    if ($Scope -eq 'workspace') {
        $workspaceRoot = Get-NormalizedPath -Path $Manifest['workspace_root']
        if ($target -in @(
            Get-NormalizedPath -Path (Join-Path $workspaceRoot '.gitignore')
            Get-NormalizedPath -Path (Join-Path $workspaceRoot 'AGENTS.md')
        )) {
            return
        }

        $vaultRoot = Get-NormalizedPath -Path $Manifest['vault_path']
        if ($target -eq $vaultRoot -or -not (Test-PathWithinRoot -Path $target -RootPath $vaultRoot)) {
            throw "Workspace backup target is not Harness-managed: $target"
        }
        $relativeTarget = $target.Substring($vaultRoot.TrimEnd('\').Length).TrimStart('\')
        $minimalTargets = @(
            'entry\AGENTS.md'
            'entry\advance-stage.ps1'
            'entry\task.ps1'
            'entry\validate-lite-artifacts.ps1'
            '运行时\tasks\.gitkeep'
        )
        if ([string]$Manifest['effective_vault_profile'] -eq 'minimal') {
            if ($relativeTarget -notin $minimalTargets) {
                throw "Minimal vault backup target is not Harness-managed: $target"
            }
            return
        }
        if ($hasManagedTargetPlan) {
            return
        }

        $templateRoot = Join-Path $Manifest['repo_root'] 'vault-template'
        $sourceCandidates = @(
            Join-Path $templateRoot $relativeTarget
            Join-Path $templateRoot ($relativeTarget + '.template')
        )
        if (@($sourceCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 0) {
            throw "Full vault backup target has no managed template source: $target"
        }
        return
    }

    $claudeHome = Get-NormalizedPath -Path $Manifest['claude_home']
    $codexHome = Get-NormalizedPath -Path $Manifest['codex_home']
    $agentsHome = Get-NormalizedPath -Path $Manifest['agents_home']
    $exactTargets = @(
        Join-Path $claudeHome 'CLAUDE.md'
        Join-Path $claudeHome 'settings.json'
        Join-Path $claudeHome 'hooks-memory'
        Join-Path $codexHome 'AGENTS.md'
        Join-Path $codexHome 'managed_config.toml'
        Join-Path $codexHome 'hooks.json'
        Join-Path $codexHome '.claude\settings.local.json'
    ) | ForEach-Object { Get-NormalizedPath -Path $_ }
    if ($target -in $exactTargets) {
        return
    }

    foreach ($userHome in @($claudeHome,$codexHome,$agentsHome)) {
        $skillsRoot = Get-NormalizedPath -Path (Join-Path $userHome 'skills')
        if ($target -eq $skillsRoot) {
            if ($Existed -and $ItemType -eq 'link') {
                return
            }
            throw "Skills root backup is allowed only for an existing link: $target"
        }
        if ((Get-NormalizedPath -Path (Split-Path -Parent $target)) -eq $skillsRoot) {
            return
        }
    }
    throw "User-global backup target is not Harness-managed: $target"
}

function Assert-ManifestBackupBoundaries {
    param(
        $Manifest,
        [string[]]$RequiredRestoreScopes = @('workspace','user-global')
    )

    if (-not ($Manifest -is [System.Collections.IDictionary])) {
        throw 'Install manifest must be a JSON object'
    }
    if ([string]$Manifest['schema_version'] -eq 'install-manifest/v1.1') {
        throw 'LIVE_UPDATE_REQUIRED: legacy-install-state'
    }
    if ([string]$Manifest['schema_version'] -ne 'install-manifest/v1.2' -or
        [string]$Manifest['postimage_identity_contract'] -ne 'v1') {
        throw "Unsupported install manifest postimage contract: $($Manifest['schema_version'])"
    }
    $manifestWorkspace = Get-NormalizedPath -Path $Manifest['workspace_root']
    [void](Assert-InstallStatePathHasNoReparsePoint -Path $manifestWorkspace -Label 'Manifest WorkspaceRoot')
    [void](Assert-InstallStatePathHasNoReparsePoint -Path $Manifest['backup_root'] -Label 'Manifest backup root')
    $manifestUserProfile = Get-NormalizedPath -Path $env:USERPROFILE
    $userGlobalRoots = @(
        Get-NormalizedPath -Path $Manifest['claude_home']
        Get-NormalizedPath -Path $Manifest['codex_home']
        Get-NormalizedPath -Path $Manifest['agents_home']
    )
    $expectedUserGlobalRoots = @(
        Get-NormalizedPath -Path (Join-Path $manifestUserProfile '.claude')
        Get-NormalizedPath -Path (Join-Path $manifestUserProfile '.codex')
        Get-NormalizedPath -Path (Join-Path $manifestUserProfile '.agents')
    )
    for ($rootIndex = 0; $rootIndex -lt $expectedUserGlobalRoots.Count; $rootIndex++) {
        if ($userGlobalRoots[$rootIndex] -ne $expectedUserGlobalRoots[$rootIndex]) {
            throw "Install manifest user-global root does not match current USERPROFILE: $($userGlobalRoots[$rootIndex])"
        }
    }
    $backupPayloadIntegrityContract = [string]$Manifest['backup_payload_integrity_contract']
    if (-not [string]::IsNullOrWhiteSpace($backupPayloadIntegrityContract) -and
        $backupPayloadIntegrityContract -ne 'sha256-v1') {
        throw "Unsupported backup payload integrity contract: $backupPayloadIntegrityContract"
    }

    $seenTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($Manifest['backups'])) {
        if (-not ($record -is [System.Collections.IDictionary])) {
            throw 'Install manifest backup record must be a JSON object'
        }
        if ([string]::IsNullOrWhiteSpace([string]$record['path'])) {
            throw 'Install manifest backup record is missing path'
        }
        if (-not $record.Contains('expected_postimage')) {
            throw "Install manifest backup record is missing expected postimage: $($record['path'])"
        }
        Assert-InstallExpectedPostimageShape `
            -Identity $record['expected_postimage'] `
            -Label "Expected postimage for $($record['path'])"
        if (-not [string]::IsNullOrWhiteSpace([string]$record['scope']) -and
            [string]$record['scope'] -notin @('workspace','user-global')) {
            throw "Unsupported backup scope '$($record['scope'])': $($record['path'])"
        }
        $scope = Get-BackupRecordScope -Record $record -Manifest $Manifest
        $targetPath = Get-NormalizedPath -Path $record['path']
        if ([string]$record['expected_postimage']['mode'] -eq 'semantic' -and
            [string]$record['expected_postimage']['contract'] -eq 'claude-settings/v1') {
            $hookSettingsTargets = @(
                Get-NormalizedPath -Path (Join-Path $Manifest['claude_home'] 'settings.json')
                Get-NormalizedPath -Path (Join-Path $Manifest['codex_home'] 'hooks.json')
            )
            if ($targetPath -notin $hookSettingsTargets) {
                throw "Hook settings semantic contract is bound to an invalid backup target: $targetPath"
            }
        }
        if ($scope -eq 'workspace') {
            [void](Assert-InstallStatePathHasNoReparsePoint -Path $targetPath -Label 'Workspace restore target')
        }
        if (-not $seenTargets.Add($targetPath)) {
            throw "Install manifest contains duplicate backup target: $targetPath"
        }
        if ($scope -eq 'workspace' -and -not (Test-PathWithinRoot -Path $targetPath -RootPath $manifestWorkspace)) {
            throw "Workspace backup escapes workspace root: $targetPath"
        }
        if ($scope -eq 'user-global' -and
            @($userGlobalRoots | Where-Object { Test-PathWithinRoot -Path $targetPath -RootPath $_ }).Count -eq 0) {
            throw "User-global backup escapes managed user-global roots: $targetPath"
        }

        if (-not ($record['existed'] -is [bool])) {
            throw "Backup record existed must be boolean: $targetPath"
        }
        $itemType = [string]$record['item_type']
        if ($itemType -notin @('missing','file','directory','link')) {
            throw "Unsupported backup item_type '$itemType': $targetPath"
        }
        if ($scope -eq 'user-global') {
            $expectedPostimageAllowsFinalLink = [string]$record['expected_postimage']['mode'] -eq 'exact' -and
                [string]$record['expected_postimage']['item_type'] -eq 'link'
            [void](Assert-InstallStatePathHasNoReparsePoint `
                -Path $targetPath `
                -Label 'User-global restore target' `
                -AllowFinalReparsePoint:($itemType -in @('link','missing') -or $expectedPostimageAllowsFinalLink))
        }
        if ($RequiredRestoreScopes -contains $scope -and
            $itemType -in @('file','directory') -and
            [string]::IsNullOrWhiteSpace($backupPayloadIntegrityContract)) {
            throw "Backup payload integrity contract is required before restoring legacy payload: $targetPath"
        }
        if ($RequiredRestoreScopes -contains $scope) {
            Assert-ManagedBackupTarget `
                -TargetPath $targetPath `
                -Scope $scope `
                -ItemType $itemType `
                -Existed ([bool]$record['existed']) `
                -Manifest $Manifest
        }

        if (-not [bool]$record['existed']) {
            if ($itemType -ne 'missing' -or
                -not [string]::IsNullOrWhiteSpace([string]$record['backup_path']) -or
                -not [string]::IsNullOrWhiteSpace([string]$record['link_target']) -or
                -not [string]::IsNullOrWhiteSpace([string]$record['backup_payload_sha256'])) {
                throw "Non-existing backup record has inconsistent payload metadata: $targetPath"
            }
            continue
        }
        if ($itemType -eq 'missing') {
            throw "Existing backup record cannot use item_type missing: $targetPath"
        }
        if ($itemType -eq 'link') {
            if ([string]$record['link_type'] -notin @('Junction','SymbolicLink') -or
                [string]::IsNullOrWhiteSpace([string]$record['link_target']) -or
                -not [string]::IsNullOrWhiteSpace([string]$record['backup_path']) -or
                -not [string]::IsNullOrWhiteSpace([string]$record['backup_payload_sha256'])) {
                throw "Link backup is missing its target: $targetPath"
            }
            $linkTarget = [string]$record['link_target']
            $resolvedLinkTarget = if ([System.IO.Path]::IsPathRooted($linkTarget)) {
                Get-NormalizedPath -Path $linkTarget
            } else {
                Get-NormalizedPath -Path (Join-Path (Split-Path -Parent $targetPath) $linkTarget)
            }
            if ($RequiredRestoreScopes -contains $scope) {
                if (-not (Test-Path -LiteralPath $resolvedLinkTarget)) {
                    throw "Link backup target is unavailable: $resolvedLinkTarget"
                }
                if ([string]$record['link_type'] -eq 'Junction' -and
                    -not (Test-Path -LiteralPath $resolvedLinkTarget -PathType Container)) {
                    throw "Junction backup target is not a directory: $resolvedLinkTarget"
                }
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($record['backup_path'])) {
            throw "Missing backup payload path: $targetPath"
        }
        $backupPath = Get-NormalizedPath -Path $record['backup_path']
        [void](Assert-InstallStatePathHasNoReparsePoint -Path $backupPath -Label 'Backup payload path')
        if (-not (Test-PathWithinRoot -Path $backupPath -RootPath $Manifest['backup_root'])) {
            throw "Backup payload escapes backup root: $targetPath"
        }
        $expectedPathType = if ($itemType -eq 'file') { 'Leaf' } else { 'Container' }
        if (-not (Test-Path -LiteralPath $backupPath -PathType $expectedPathType)) {
            throw "Missing backup payload: $backupPath"
        }
        if ($backupPayloadIntegrityContract -eq 'sha256-v1') {
            $expectedPayloadDigest = [string]$record['backup_payload_sha256']
            if ($expectedPayloadDigest -notmatch '^[0-9a-f]{64}$' -or
                (Get-InstallBackupPayloadDigest -Path $backupPath -ItemType $itemType) -ne $expectedPayloadDigest) {
                throw "Backup payload digest mismatch: $backupPath"
            }
        }
        if ($targetPath -eq (Get-NormalizedPath -Path (Join-Path $Manifest['claude_home'] 'settings.json'))) {
            $baselineSettings = Read-JsonObject -Path $backupPath
            if (-not ($baselineSettings -is [System.Collections.IDictionary]) -or
                ($baselineSettings.Contains('hooks') -and -not ($baselineSettings['hooks'] -is [System.Collections.IDictionary]))) {
                throw "Claude settings backup must be a JSON object with an object hooks field: $backupPath"
            }
            if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
                $currentSettings = Read-JsonObject -Path $targetPath
                if (-not ($currentSettings -is [System.Collections.IDictionary]) -or
                    ($currentSettings.Contains('hooks') -and -not ($currentSettings['hooks'] -is [System.Collections.IDictionary]))) {
                    throw "Claude settings must be a JSON object with an object hooks field: $targetPath"
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Manifest['generated_repo_system_path']) -and
        -not (Test-PathWithinRoot -Path $Manifest['generated_repo_system_path'] -RootPath $Manifest['repo_root'])) {
        throw "Generated system path escapes repo root: $($Manifest['generated_repo_system_path'])"
    }
}

function Assert-WorkspaceManifestIdentity {
    param(
        [string]$ManifestPath,
        $Manifest,
        [string]$ExpectedWorkspaceRoot,
        [string]$RegistryPath
    )

    [void](Assert-InstallStatePathHasNoReparsePoint -Path $ManifestPath -Label 'Install manifest path')
    if ((Get-NormalizedPath -Path $Manifest['workspace_root']) -ne (Get-NormalizedPath -Path $ExpectedWorkspaceRoot)) {
        throw "Install manifest workspace does not match registry entry: $ManifestPath"
    }

    $schemaVersion = [string]$Manifest['schema_version']
    if ($schemaVersion -eq 'install-manifest/v1.1') {
        throw 'LIVE_UPDATE_REQUIRED: legacy-install-state'
    }
    if ($schemaVersion -ne 'install-manifest/v1.2' -or
        [string]$Manifest['postimage_identity_contract'] -ne 'v1') {
        throw "Unsupported install manifest schema: $schemaVersion"
    }
    if ((Get-NormalizedPath -Path $Manifest['registry_path']) -ne (Get-NormalizedPath -Path $RegistryPath)) {
        throw "Install manifest registry path does not match current USERPROFILE registry: $ManifestPath"
    }
    $expectedBackupRoot = Join-Path $env:USERPROFILE '.dev-harness\backups'
    $manifestBackupRoot = Get-NormalizedPath -Path $Manifest['backup_root']
    if (-not (Test-PathWithinRoot -Path $manifestBackupRoot -RootPath $expectedBackupRoot) -or
        (Get-NormalizedPath -Path $ManifestPath) -ne (Get-NormalizedPath -Path (Join-Path $manifestBackupRoot 'install-manifest.json'))) {
        throw "Install manifest backup ownership is outside the current USERPROFILE: $ManifestPath"
    }
    if ((Get-NormalizedPath -Path $Manifest['vault_path']) -ne (Get-NormalizedPath -Path (Join-Path $ExpectedWorkspaceRoot '.assistant'))) {
        throw "Install manifest vault path does not match workspace: $ManifestPath"
    }
    [void](Get-InstallReleasedBackupTargetPaths -Manifest $Manifest)
}

function Assert-NormalInstallManifestStatus {
    param(
        $Manifest,
        [string]$ManifestPath
    )

    $transactionStatus = [string]$Manifest['transaction_status']
    if ($transactionStatus -ne 'committed') {
        throw "Normal uninstall requires a committed install manifest; use -RecoveryManifestPath for a failed transaction: $ManifestPath"
    }
}

function Assert-RegisteredManifestIdentity {
    param(
        $Entry,
        [string]$WorkspaceKey,
        [string]$ManifestPath,
        $Manifest,
        [string]$RegistryPath
    )

    if (-not ($Entry -is [System.Collections.IDictionary])) {
        throw "Workspace registry entry must be an object: $WorkspaceKey"
    }
    $entryWorkspace = Get-NormalizedPath -Path $Entry['workspace_root']
    if ((Get-WorkspaceRegistryKey -Path $entryWorkspace) -ne $WorkspaceKey) {
        throw "Workspace registry key/entry identity mismatch: $WorkspaceKey"
    }

    Assert-WorkspaceManifestIdentity `
        -ManifestPath $ManifestPath `
        -Manifest $Manifest `
        -ExpectedWorkspaceRoot $entryWorkspace `
        -RegistryPath $RegistryPath

    $manifestRepo = Get-NormalizedPath -Path $Manifest['repo_root']
    $entryRepo = Get-NormalizedPath -Path $Entry['repo_root']
    if ($manifestRepo -ne $entryRepo) {
        throw "Install manifest repo owner does not match registry entry: $ManifestPath"
    }
    Assert-NormalInstallManifestStatus `
        -Manifest $Manifest `
        -ManifestPath $ManifestPath
}

function Assert-RegisteredWorkspaceSelection {
    param(
        $Entry,
        [string]$WorkspaceKey,
        [string]$WorkspaceRoot,
        [string]$ManifestPath,
        $Manifest,
        [string]$RegistryPath,
        [string]$RepoRoot
    )

    $entryWorkspace = Get-NormalizedPath -Path $Entry['workspace_root']
    if ($entryWorkspace -ne (Get-NormalizedPath -Path $WorkspaceRoot)) {
        throw "Workspace registry key/entry identity mismatch: $WorkspaceKey"
    }

    $entryManifestPaths = @($Entry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    if ($entryManifestPaths.Count -eq 0 -or $entryManifestPaths[-1] -ne (Get-NormalizedPath -Path $ManifestPath)) {
        throw "Selected manifest is not the latest manifest owned by workspace: $entryWorkspace"
    }

    Assert-RegisteredManifestIdentity `
        -Entry $Entry `
        -WorkspaceKey $WorkspaceKey `
        -ManifestPath $ManifestPath `
        -Manifest $Manifest `
        -RegistryPath $RegistryPath

    $entryRepo = Get-NormalizedPath -Path $Entry['repo_root']
    $invokingRepo = Get-NormalizedPath -Path $RepoRoot
    if ($entryRepo -ne $invokingRepo) {
        throw "Install manifest repo owner does not match registry entry and invoking repo: $ManifestPath"
    }
}

function Get-RegisteredManifestOwner {
    param(
        [string]$ManifestPath,
        $Workspaces,
        [string]$RegistryPath
    )

    $normalizedManifestPath = Get-NormalizedPath -Path $ManifestPath
    $manifest = Read-InstallManifest -Path $normalizedManifestPath
    $workspaceRoot = Get-NormalizedPath -Path $manifest['workspace_root']
    $workspaceKey = Get-WorkspaceRegistryKey -Path $workspaceRoot
    if (-not $Workspaces.Contains($workspaceKey)) {
        throw "Global owner manifest has no registered workspace: $normalizedManifestPath"
    }
    $entry = $Workspaces[$workspaceKey]
    Assert-RegisteredWorkspaceSelection `
        -Entry $entry `
        -WorkspaceKey $workspaceKey `
        -WorkspaceRoot $workspaceRoot `
        -ManifestPath $normalizedManifestPath `
        -Manifest $manifest `
        -RegistryPath $RegistryPath `
        -RepoRoot $entry['repo_root']
    return [pscustomobject]@{
        ManifestPath = $normalizedManifestPath
        Manifest = $manifest
        WorkspaceKey = $workspaceKey
        WorkspaceRoot = $workspaceRoot
        RepoRoot = (Get-NormalizedPath -Path $entry['repo_root'])
    }
}

function Refresh-InstallRegistryManifestDigests {
    param($Registry)

    $digests = [ordered]@{}
    foreach ($manifestPath in @($Registry['global_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ } | Select-Object -Unique)) {
        $digests[(Get-InstallManifestDigestRegistryKey -ManifestPath $manifestPath)] = Get-InstallStateFileDigest -Path $manifestPath
    }
    $Registry['manifest_digests'] = $digests
    $Registry['manifest_integrity_contract'] = 'sha256-v1'
}

function Assert-GlobalHistoryState {
    param(
        [string[]]$GlobalHistory,
        $Workspaces,
        $Registry,
        [string]$RegistryPath,
        [bool]$RequireManifestIntegrity,
        [string[]]$RetiredManifestHistory
    )

    if ($GlobalHistory.Count -eq 0) {
        throw 'Install registry has workspaces but no user-global owner history'
    }
    $historyIndexes = @{}
    for ($historyIndex = 0; $historyIndex -lt $GlobalHistory.Count; $historyIndex++) {
        $historyPath = Get-NormalizedPath -Path $GlobalHistory[$historyIndex]
        if ($historyIndexes.ContainsKey($historyPath)) {
            throw "Install registry global history contains a duplicate manifest: $historyPath"
        }
        $historyIndexes[$historyPath] = $historyIndex
    }

    $registeredRepoSkillRoots = @()
    $manifestOwners = @{}
    foreach ($workspaceEntry in $Workspaces.GetEnumerator()) {
        $entry = $workspaceEntry.Value
        if (-not ($entry -is [System.Collections.IDictionary])) {
            throw "Workspace registry entry must be an object: $($workspaceEntry.Key)"
        }
        $entryWorkspace = Get-NormalizedPath -Path $entry['workspace_root']
        if ((Get-WorkspaceRegistryKey -Path $entryWorkspace) -ne [string]$workspaceEntry.Key) {
            throw "Workspace registry key/entry identity mismatch: $($workspaceEntry.Key)"
        }
        $entryManifestPaths = @($entry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        if ($entryManifestPaths.Count -eq 0) {
            throw "Workspace registry entry has no install manifests: $entryWorkspace"
        }
        $previousHistoryIndex = -1
        foreach ($entryManifestPath in $entryManifestPaths) {
            if ($manifestOwners.ContainsKey($entryManifestPath)) {
                throw "Install manifest is registered by more than one workspace: $entryManifestPath"
            }
            if (-not $historyIndexes.ContainsKey($entryManifestPath)) {
                throw "Registered workspace manifest is missing from global history: $entryManifestPath"
            }
            $currentHistoryIndex = [int]$historyIndexes[$entryManifestPath]
            if ($currentHistoryIndex -le $previousHistoryIndex) {
                throw "Workspace manifest order disagrees with global history: $entryWorkspace"
            }
            $previousHistoryIndex = $currentHistoryIndex
            Assert-InstallManifestRegistryDigest `
                -Registry $Registry `
                -ManifestPath $entryManifestPath `
                -RequireManifestIntegrity $RequireManifestIntegrity
            $manifest = Read-InstallManifest -Path $entryManifestPath
            Assert-RegisteredManifestIdentity `
                -Entry $entry `
                -WorkspaceKey ([string]$workspaceEntry.Key) `
                -ManifestPath $entryManifestPath `
                -Manifest $manifest `
                -RegistryPath $RegistryPath
            $manifestOwners[$entryManifestPath] = [string]$workspaceEntry.Key
        }
        $registeredRepoSkillRoots += Get-NormalizedPath -Path (Join-Path $entry['repo_root'] 'skills')
    }

    $previousRetiredHistoryIndex = -1
    foreach ($retiredManifestPath in @($RetiredManifestHistory)) {
        $normalizedRetiredPath = Get-NormalizedPath -Path $retiredManifestPath
        if ([string]::IsNullOrWhiteSpace($normalizedRetiredPath) -or $manifestOwners.ContainsKey($normalizedRetiredPath)) {
            throw "Retired manifest ownership is empty or duplicates an active owner: $retiredManifestPath"
        }
        if (-not $historyIndexes.ContainsKey($normalizedRetiredPath)) {
            throw "Retired manifest is missing from global history: $normalizedRetiredPath"
        }
        $currentHistoryIndex = [int]$historyIndexes[$normalizedRetiredPath]
        if ($currentHistoryIndex -le $previousRetiredHistoryIndex) {
            throw 'Retired manifest order disagrees with global history'
        }
        $previousRetiredHistoryIndex = $currentHistoryIndex

        Assert-InstallManifestRegistryDigest `
            -Registry $Registry `
            -ManifestPath $normalizedRetiredPath `
            -RequireManifestIntegrity $RequireManifestIntegrity
        $retiredManifest = Read-InstallManifest -Path $normalizedRetiredPath
        $retiredWorkspace = Get-NormalizedPath -Path $retiredManifest['workspace_root']
        $retiredRepo = Get-NormalizedPath -Path $retiredManifest['repo_root']
        if ([string]::IsNullOrWhiteSpace($retiredWorkspace) -or [string]::IsNullOrWhiteSpace($retiredRepo)) {
            throw "Retired install manifest is missing workspace or repo identity: $normalizedRetiredPath"
        }
        Assert-WorkspaceManifestIdentity `
            -ManifestPath $normalizedRetiredPath `
            -Manifest $retiredManifest `
            -ExpectedWorkspaceRoot $retiredWorkspace `
            -RegistryPath $RegistryPath
        Assert-NormalInstallManifestStatus `
            -Manifest $retiredManifest `
            -ManifestPath $normalizedRetiredPath
        $manifestOwners[$normalizedRetiredPath] = 'retired'
    }
    foreach ($historyPath in $historyIndexes.Keys) {
        if (-not $manifestOwners.ContainsKey($historyPath)) {
            throw "Global history manifest has no registered workspace owner: $historyPath"
        }
    }

    $activeOwner = Get-RegisteredManifestOwner -ManifestPath $GlobalHistory[-1] -Workspaces $Workspaces -RegistryPath $RegistryPath
    $activeRepoSkills = Get-NormalizedPath -Path (Join-Path $activeOwner.RepoRoot 'skills')
    foreach ($hostSkillsRoot in @(
        Join-Path $activeOwner.Manifest['claude_home'] 'skills'
        Join-Path $activeOwner.Manifest['codex_home'] 'skills'
        Join-Path $activeOwner.Manifest['agents_home'] 'skills'
    )) {
        if (-not (Test-Path -LiteralPath $hostSkillsRoot -PathType Container)) {
            continue
        }
        foreach ($entry in Get-ChildItem -LiteralPath $hostSkillsRoot -Force) {
            $target = Get-JunctionTarget -Path $entry.FullName
            if ([string]::IsNullOrWhiteSpace($target)) {
                continue
            }
            $isRegisteredHarnessLink = @($registeredRepoSkillRoots | Where-Object { Test-PathWithinRoot -Path $target -RootPath $_ }).Count -gt 0
            if ($isRegisteredHarnessLink -and -not (Test-PathWithinRoot -Path $target -RootPath $activeRepoSkills)) {
                throw "User-global managed link disagrees with registry active owner: $($entry.FullName)"
            }
        }
    }
    return $activeOwner
}

function Assert-RecoveryManifestIdentity {
    param(
        [string]$ManifestPath,
        $Manifest,
        $Registry,
        [string]$RegistryPath,
        [string]$RepoRoot
    )

    if ([string]$Manifest['schema_version'] -eq 'install-manifest/v1.1') {
        throw 'LIVE_UPDATE_REQUIRED: legacy-install-state'
    }
    if ([string]$Manifest['schema_version'] -ne 'install-manifest/v1.2' -or
        [string]$Manifest['postimage_identity_contract'] -ne 'v1') {
        throw "Recovery requires install-manifest/v1.2 with postimage identity: $ManifestPath"
    }
    if ([string]$Manifest['transaction_status'] -notin @('failed','in-progress','committed')) {
        throw "Recovery manifest is not an unregistered recoverable transaction: $ManifestPath"
    }
    if ((Get-NormalizedPath -Path $Manifest['registry_path']) -ne (Get-NormalizedPath -Path $RegistryPath)) {
        throw "Recovery manifest registry path does not match current USERPROFILE: $ManifestPath"
    }
    if ((Get-NormalizedPath -Path $Manifest['repo_root']) -ne (Get-NormalizedPath -Path $RepoRoot)) {
        throw "Recovery manifest repo owner does not match invoking repo: $ManifestPath"
    }

    $recoveryWorkspace = Get-NormalizedPath -Path $Manifest['workspace_root']
    Assert-WorkspaceManifestIdentity `
        -ManifestPath $ManifestPath `
        -Manifest $Manifest `
        -ExpectedWorkspaceRoot $recoveryWorkspace `
        -RegistryPath $RegistryPath
    $recoveryWorkspaceKey = Get-WorkspaceRegistryKey -Path $recoveryWorkspace
    if ($null -ne $Registry -and
        $Registry['workspaces'] -is [System.Collections.IDictionary] -and
        $Registry['workspaces'].Contains($recoveryWorkspaceKey)) {
        $recoveryEntry = $Registry['workspaces'][$recoveryWorkspaceKey]
        if ((Get-NormalizedPath -Path $recoveryEntry['workspace_root']) -ne $recoveryWorkspace -or
            (Get-NormalizedPath -Path $recoveryEntry['repo_root']) -ne (Get-NormalizedPath -Path $Manifest['repo_root'])) {
            throw "Recovery manifest does not match the registered workspace owner: $ManifestPath"
        }
    }

    $expectedBackupRoot = Join-Path $env:USERPROFILE '.dev-harness\backups'
    $manifestBackupRoot = Get-NormalizedPath -Path $Manifest['backup_root']
    if (-not (Test-PathWithinRoot -Path $manifestBackupRoot -RootPath $expectedBackupRoot) -or
        -not (Test-PathWithinRoot -Path $ManifestPath -RootPath $manifestBackupRoot)) {
        throw "Recovery manifest backup ownership is outside the current USERPROFILE: $ManifestPath"
    }

    $registeredManifestPaths = @()
    if ($null -ne $Registry -and $Registry['workspaces'] -is [System.Collections.IDictionary]) {
        foreach ($entry in $Registry['workspaces'].Values) {
            $registeredManifestPaths += @($entry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        }
        $registeredManifestPaths += @($Registry['global_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    }
    if ($registeredManifestPaths -contains (Get-NormalizedPath -Path $ManifestPath)) {
        throw "Recovery manifest is already registered as a committed install: $ManifestPath"
    }

    $expectedDigest = [string]$Manifest['registry_preimage_sha256']
    if ($expectedDigest -notmatch '^(missing|[0-9a-f]{64})$' -or
        (Get-InstallStateFileDigest -Path $RegistryPath) -ne $expectedDigest) {
        throw "Recovery manifest registry preimage no longer matches current state: $ManifestPath"
    }
}

function Test-NormalizedPathSequenceEqual {
    param(
        [object[]]$Left,
        [object[]]$Right
    )

    $leftPaths = @($Left | ForEach-Object { Get-NormalizedPath -Path $_ })
    $rightPaths = @($Right | ForEach-Object { Get-NormalizedPath -Path $_ })
    if ($leftPaths.Count -ne $rightPaths.Count) {
        return $false
    }
    for ($index = 0; $index -lt $leftPaths.Count; $index++) {
        if (-not $leftPaths[$index].Equals($rightPaths[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Test-StringSetEqual {
    param(
        [object[]]$Left,
        [object[]]$Right
    )

    $leftValues = @($Left | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    $rightValues = @($Right | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    return ($leftValues.Count -eq $rightValues.Count) -and (($leftValues -join "`n") -eq ($rightValues -join "`n"))
}

function Assert-UninstallJournalDerivedState {
    param(
        $Journal,
        $Registry,
        [string]$RegistryPath,
        [string]$ExpectedRepoRoot
    )

    foreach ($arrayField in @(
        'remaining_workspace_keys',
        'workspace_manifest_paths',
        'global_manifest_paths',
        'fully_consumed_manifest_paths',
        'updated_global_history',
        'updated_retired_manifest_history'
    )) {
        if (-not ($Journal[$arrayField] -is [System.Collections.IList])) {
            throw "Uninstall journal field must be an array: $arrayField"
        }
    }
    if (-not ($Journal['restore_user_global'] -is [bool])) {
        throw 'Uninstall journal restore_user_global must be a boolean'
    }
    [object[]]$journalReleasedTargetHistory = @()
    if ($Journal.Contains('released_target_history')) {
        $journalReleasedTargetHistory = @($Journal['released_target_history'])
    }
    if (-not ($journalReleasedTargetHistory -is [System.Collections.IList])) {
        throw 'Uninstall journal released_target_history must be an array'
    }

    $workspaces = [ordered]@{}
    $globalHistory = @()
    $retiredManifestHistory = @()
    [object[]]$registryReleasedTargetHistory = @()
    if ($null -ne $Registry) {
        if ([string]$Registry['schema_version'] -ne 'install-registry/v1.1' -or
            -not ($Registry['workspaces'] -is [System.Collections.IDictionary])) {
            throw "Uninstall journal registry preimage is invalid: $RegistryPath"
        }
        [void](Get-InstallRegistryReleasedTargetHistoryMap -Registry $Registry -ExpectedUserProfile $env:USERPROFILE)
        if ($Registry.Contains('released_target_history')) {
            $registryReleasedTargetHistory = @($Registry['released_target_history'])
        }
        $workspaces = $Registry['workspaces']
        if ($null -ne $Registry['global_manifest_history'] -and
            -not ($Registry['global_manifest_history'] -is [System.Collections.IList])) {
            throw "Uninstall journal registry global history is invalid: $RegistryPath"
        }
        $globalHistory = @($Registry['global_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        Assert-InstallRegistryReleaseMarkerCoverage `
            -Registry $Registry `
            -ExpectedUserProfile $env:USERPROFILE `
            -ManifestPaths $globalHistory

        $historyOwnershipContract = [string]$Registry['history_ownership_contract']
        if ($historyOwnershipContract -ne 'v1') {
            throw "Unsupported install registry history ownership contract: $historyOwnershipContract"
        }
        if (-not ($Registry['retired_manifest_history'] -is [System.Collections.IList])) {
            throw "Invalid install registry retired history array: $RegistryPath"
        } else {
            $retiredManifestHistory = @($Registry['retired_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        }
    }
    if (-not (Test-InstallJsonValueEqual -Left $journalReleasedTargetHistory -Right $registryReleasedTargetHistory)) {
        throw 'Uninstall journal released target history does not match the registry preimage'
    }

    $workspaceKey = [string]$Journal['workspace_key']
    if ([string]::IsNullOrWhiteSpace($workspaceKey)) {
        throw 'Uninstall journal workspace key is empty'
    }
    $registered = $workspaces.Contains($workspaceKey)
    $workspaceManifestPaths = @()
    $globalManifestPaths = @()
    $updatedGlobalHistory = @()
    $updatedRetiredManifestHistory = @($retiredManifestHistory)
    $restoreUserGlobal = $true
    $remainingWorkspaceKeys = @()
    $registryAction = 'none'

    if ($registered) {
        $entry = $workspaces[$workspaceKey]
        if (-not ($entry -is [System.Collections.IDictionary])) {
            throw "Workspace registry entry must be an object: $workspaceKey"
        }
        $entryWorkspaceRoot = Get-NormalizedPath -Path $entry['workspace_root']
        if ((Get-WorkspaceRegistryKey -Path $entryWorkspaceRoot) -ne $workspaceKey) {
            throw "Workspace registry key/entry identity mismatch: $workspaceKey"
        }
        if ((Get-NormalizedPath -Path $entry['repo_root']) -ne (Get-NormalizedPath -Path $ExpectedRepoRoot)) {
            throw "Uninstall journal workspace owner does not match invoking repo: $workspaceKey"
        }
        $workspaceManifestPaths = @($entry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        if ($workspaceManifestPaths.Count -eq 0) {
            throw "Workspace registry entry has no install manifests: $entryWorkspaceRoot"
        }
        foreach ($path in $workspaceManifestPaths) {
            $manifest = Read-InstallManifest -Path $path
            Assert-WorkspaceManifestIdentity `
                -ManifestPath $path `
                -Manifest $manifest `
                -ExpectedWorkspaceRoot $entryWorkspaceRoot `
                -RegistryPath $RegistryPath
            if ((Get-NormalizedPath -Path $manifest['repo_root']) -ne (Get-NormalizedPath -Path $entry['repo_root'])) {
                throw "Install manifest repo owner does not match registry entry: $path"
            }
        }

        if ($globalHistory.Count -eq 0) {
            throw 'Install registry has workspaces but no user-global owner history'
        }
        $activeManifestPath = $globalHistory[-1]
        $activeManifest = Read-InstallManifest -Path $activeManifestPath
        $activeWorkspaceKey = Get-WorkspaceRegistryKey -Path $activeManifest['workspace_root']
        if (-not $workspaces.Contains($activeWorkspaceKey)) {
            throw "Global owner manifest has no registered workspace: $activeManifestPath"
        }
        $activeEntryPaths = @($workspaces[$activeWorkspaceKey]['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        if ($activeEntryPaths.Count -eq 0 -or $activeEntryPaths[-1] -ne $activeManifestPath) {
            throw "Global owner manifest is not the latest registered owner: $activeManifestPath"
        }

        $remainingWorkspaceKeys = @($workspaces.Keys | Where-Object { [string]$_ -ne $workspaceKey } | ForEach-Object { [string]$_ })
        $remainingWorkspaceCount = $remainingWorkspaceKeys.Count
        $registryAction = if ($remainingWorkspaceCount -eq 0) { 'delete' } else { 'write' }
        $updatedGlobalHistory = @($globalHistory)
        $restoreUserGlobal = $remainingWorkspaceCount -eq 0
        if ($remainingWorkspaceCount -eq 0) {
            $globalManifestPaths = if ($globalHistory.Count -gt 0) { @($globalHistory) } else { @($workspaceManifestPaths) }
        } elseif ($activeWorkspaceKey -eq $workspaceKey) {
            $handoffIndex = -1
            for ($historyIndex = $globalHistory.Count - 2; $historyIndex -ge 0; $historyIndex--) {
                $candidatePath = $globalHistory[$historyIndex]
                $candidateManifest = Read-InstallManifest -Path $candidatePath
                $candidateKey = Get-WorkspaceRegistryKey -Path $candidateManifest['workspace_root']
                if ($candidateKey -eq $workspaceKey -or -not $workspaces.Contains($candidateKey)) {
                    continue
                }
                $candidateEntry = $workspaces[$candidateKey]
                $candidateEntryPaths = @($candidateEntry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
                if ($candidateEntryPaths.Count -eq 0 -or $candidateEntryPaths[-1] -ne $candidatePath) {
                    continue
                }
                if (-not (Test-Path -LiteralPath (Join-Path $candidateEntry['repo_root'] 'skills') -PathType Container)) {
                    throw "Remaining user-global owner repo is unavailable: $($candidateEntry['repo_root'])"
                }
                $handoffIndex = $historyIndex
                break
            }
            if ($handoffIndex -lt 0) {
                throw 'No valid remaining workspace can own user-global assets'
            }
            $restoreUserGlobal = $true
            $globalManifestPaths = @($globalHistory[($handoffIndex + 1)..($globalHistory.Count - 1)])
            $updatedGlobalHistory = @($globalHistory[0..$handoffIndex])
        }

        if ($remainingWorkspaceCount -gt 0) {
            $retiredCandidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($path in @($retiredManifestHistory + $workspaceManifestPaths)) {
                [void]$retiredCandidates.Add((Get-NormalizedPath -Path $path))
            }
            $updatedRetiredManifestHistory = @($updatedGlobalHistory | Where-Object { $retiredCandidates.Contains($_) })
        }
    } else {
        if ($workspaces.Count -gt 0 -or $globalHistory.Count -gt 0 -or $retiredManifestHistory.Count -gt 0) {
            throw 'Unregistered uninstall journal cannot resume while registry ownership state exists'
        }
        $journalWorkspacePaths = @($Journal['workspace_manifest_paths'])
        if ($journalWorkspacePaths.Count -ne 1) {
            throw 'Unregistered uninstall journal must contain exactly one workspace manifest'
        }
        $selectedPath = Get-NormalizedPath -Path $journalWorkspacePaths[0]
        $selectedManifest = Read-InstallManifest -Path $selectedPath
        $selectedWorkspaceRoot = Get-NormalizedPath -Path $selectedManifest['workspace_root']
        if ((Get-WorkspaceRegistryKey -Path $selectedWorkspaceRoot) -ne $workspaceKey -or
            (Get-NormalizedPath -Path $selectedManifest['repo_root']) -ne (Get-NormalizedPath -Path $ExpectedRepoRoot)) {
            throw "Unregistered uninstall journal identity mismatch: $selectedPath"
        }
        Assert-WorkspaceManifestIdentity `
            -ManifestPath $selectedPath `
            -Manifest $selectedManifest `
            -ExpectedWorkspaceRoot $selectedWorkspaceRoot `
            -RegistryPath $RegistryPath
        $workspaceManifestPaths = @($selectedPath)
        $globalManifestPaths = @($selectedPath)
    }

    $candidateConsumedManifestPaths = @($workspaceManifestPaths + $globalManifestPaths | ForEach-Object { Get-NormalizedPath -Path $_ } | Select-Object -Unique)
    if ($registered -and $remainingWorkspaceKeys.Count -gt 0) {
        $retainedHistoryPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $updatedGlobalHistory) { [void]$retainedHistoryPaths.Add($path) }
        $fullyConsumedManifestPaths = @($candidateConsumedManifestPaths | Where-Object { -not $retainedHistoryPaths.Contains($_) })
    } else {
        $fullyConsumedManifestPaths = @($candidateConsumedManifestPaths)
    }

    if ($registered) {
        $fullyConsumedPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $fullyConsumedManifestPaths) { [void]$fullyConsumedPathSet.Add($path) }
        $transactionStatusContract = [string]$Registry['transaction_status_contract']
        if ($transactionStatusContract -ne 'v1') {
            throw "Unsupported install registry transaction status contract: $transactionStatusContract"
        }
        $manifestIntegrityContract = [string]$Registry['manifest_integrity_contract']
        if ($manifestIntegrityContract -ne 'sha256-v1') {
            throw "Unsupported install registry manifest integrity contract: $manifestIntegrityContract"
        }
        $requireManifestIntegrity = $manifestIntegrityContract -eq 'sha256-v1'
        if ($null -eq $Registry['manifest_digests']) {
            if ($requireManifestIntegrity) {
                throw "Install registry is missing manifest digests: $RegistryPath"
            }
            $Registry['manifest_digests'] = [ordered]@{}
        } elseif (-not ($Registry['manifest_digests'] -is [System.Collections.IDictionary])) {
            throw "Invalid install registry manifest digest map: $RegistryPath"
        }

        foreach ($workspaceEntry in $workspaces.GetEnumerator()) {
            $ownedEntry = $workspaceEntry.Value
            if (-not ($ownedEntry -is [System.Collections.IDictionary])) {
                throw "Workspace registry entry must be an object: $($workspaceEntry.Key)"
            }
            $ownedWorkspaceRoot = Get-NormalizedPath -Path $ownedEntry['workspace_root']
            if ((Get-WorkspaceRegistryKey -Path $ownedWorkspaceRoot) -ne [string]$workspaceEntry.Key) {
                throw "Workspace registry key/entry identity mismatch: $($workspaceEntry.Key)"
            }
            $ownedManifestPaths = @($ownedEntry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
            if ($ownedManifestPaths.Count -eq 0) {
                throw "Workspace registry entry has no install manifests: $ownedWorkspaceRoot"
            }
            foreach ($ownedManifestPath in $ownedManifestPaths) {
                $ownedManifest = Read-InstallManifest -Path $ownedManifestPath
                Assert-WorkspaceManifestIdentity `
                    -ManifestPath $ownedManifestPath `
                    -Manifest $ownedManifest `
                    -ExpectedWorkspaceRoot $ownedWorkspaceRoot `
                    -RegistryPath $RegistryPath
                if ((Get-NormalizedPath -Path $ownedManifest['repo_root']) -ne (Get-NormalizedPath -Path $ownedEntry['repo_root'])) {
                    throw "Install manifest repo owner does not match registry entry: $ownedManifestPath"
                }
                if ($fullyConsumedPathSet.Contains($ownedManifestPath) -and
                    [string]$ownedManifest['transaction_status'] -eq 'uninstalled') {
                    continue
                }
                Assert-NormalInstallManifestStatus `
                    -Manifest $ownedManifest `
                    -ManifestPath $ownedManifestPath
                Assert-InstallManifestRegistryDigest `
                    -Registry $Registry `
                    -ManifestPath $ownedManifestPath `
                    -RequireManifestIntegrity $requireManifestIntegrity
            }
        }
        foreach ($retiredManifestPath in $retiredManifestHistory) {
            $retiredManifest = Read-InstallManifest -Path $retiredManifestPath
            $retiredWorkspaceRoot = Get-NormalizedPath -Path $retiredManifest['workspace_root']
            Assert-WorkspaceManifestIdentity `
                -ManifestPath $retiredManifestPath `
                -Manifest $retiredManifest `
                -ExpectedWorkspaceRoot $retiredWorkspaceRoot `
                -RegistryPath $RegistryPath
            if ($fullyConsumedPathSet.Contains($retiredManifestPath) -and
                [string]$retiredManifest['transaction_status'] -eq 'uninstalled') {
                continue
            }
            Assert-NormalInstallManifestStatus `
                -Manifest $retiredManifest `
                -ManifestPath $retiredManifestPath
            Assert-InstallManifestRegistryDigest `
                -Registry $Registry `
                -ManifestPath $retiredManifestPath `
                -RequireManifestIntegrity $requireManifestIntegrity
        }
    }

    if ([string]$Journal['registry_action'] -ne $registryAction -or
        [bool]$Journal['restore_user_global'] -ne $restoreUserGlobal -or
        -not (Test-StringSetEqual -Left @($Journal['remaining_workspace_keys']) -Right $remainingWorkspaceKeys) -or
        -not (Test-NormalizedPathSequenceEqual -Left @($Journal['workspace_manifest_paths']) -Right $workspaceManifestPaths) -or
        -not (Test-NormalizedPathSequenceEqual -Left @($Journal['global_manifest_paths']) -Right $globalManifestPaths) -or
        -not (Test-NormalizedPathSequenceEqual -Left @($Journal['fully_consumed_manifest_paths']) -Right $fullyConsumedManifestPaths) -or
        -not (Test-NormalizedPathSequenceEqual -Left @($Journal['updated_global_history']) -Right $updatedGlobalHistory) -or
        -not (Test-NormalizedPathSequenceEqual -Left @($Journal['updated_retired_manifest_history']) -Right $updatedRetiredManifestHistory)) {
        throw 'Uninstall journal derived state does not match the registry preimage'
    }
    $expectedLegacyPointerPath = Get-NormalizedPath -Path (Join-Path $ExpectedRepoRoot 'backups\active-install.json')
    if ((Get-NormalizedPath -Path $Journal['legacy_pointer_path']) -ne $expectedLegacyPointerPath) {
        throw 'Uninstall journal legacy pointer path does not match invoking repo'
    }

    if (-not ($Journal['manifest_plan_digests'] -is [System.Collections.IDictionary])) {
        throw 'Uninstall journal is missing manifest plan digests'
    }
    $expectedDigestKeys = @($candidateConsumedManifestPaths | ForEach-Object { Get-InstallManifestDigestRegistryKey -ManifestPath $_ })
    if (-not (Test-StringSetEqual -Left @($Journal['manifest_plan_digests'].Keys) -Right $expectedDigestKeys)) {
        throw 'Uninstall journal manifest plan digest keys do not match the derived plan'
    }
    if (-not ($Journal['registry_owned_manifest_plan_digests'] -is [System.Collections.IDictionary])) {
        throw 'Uninstall journal is missing registry-owned manifest plan digests'
    }
    $expectedOwnedManifestPaths = if ($registered) { @($globalHistory) } else { @() }
    $expectedOwnedDigestKeys = @($expectedOwnedManifestPaths | ForEach-Object { Get-InstallManifestDigestRegistryKey -ManifestPath $_ })
    if (-not (Test-StringSetEqual -Left @($Journal['registry_owned_manifest_plan_digests'].Keys) -Right $expectedOwnedDigestKeys)) {
        throw 'Uninstall journal registry-owned digest keys do not match the registry preimage'
    }
    foreach ($path in $expectedOwnedManifestPaths) {
        $manifest = Read-InstallManifest -Path $path
        $digestKey = Get-InstallManifestDigestRegistryKey -ManifestPath $path
        $expectedPlanDigest = [string]$Journal['registry_owned_manifest_plan_digests'][$digestKey]
        if ($expectedPlanDigest -notmatch '^[0-9a-f]{64}$' -or
            (Get-InstallManifestPlanDigest -Manifest $manifest) -ne $expectedPlanDigest) {
            throw "Uninstall journal registry-owned manifest plan digest mismatch: $path"
        }
    }
}

function Test-UninstallJournalRegistryCommitted {
    param(
        $Journal,
        [string]$RegistryPath
    )

    $action = [string]$Journal['registry_action']
    if ($action -eq 'none') {
        return $false
    }
    if (-not ($Journal['fully_consumed_manifest_paths'] -is [System.Collections.IList]) -or
        -not ($Journal['manifest_plan_digests'] -is [System.Collections.IDictionary]) -or
        -not ($Journal['registry_owned_manifest_plan_digests'] -is [System.Collections.IDictionary])) {
        return $false
    }
    [object[]]$journalReleasedTargetHistory = @()
    if ($Journal.Contains('released_target_history')) {
        $journalReleasedTargetHistory = @($Journal['released_target_history'])
    }
    if (-not ($journalReleasedTargetHistory -is [System.Collections.IList])) {
        return $false
    }
    $fullyConsumedManifestPaths = @($Journal['fully_consumed_manifest_paths'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    if ($fullyConsumedManifestPaths.Count -eq 0 -and $action -ne 'write') {
        return $false
    }
    $consumedPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $fullyConsumedManifestPaths) {
        if (-not $consumedPathSet.Add($path)) {
            return $false
        }
        $manifest = Read-InstallManifest -Path $path
        $digestKey = Get-InstallManifestDigestRegistryKey -ManifestPath $path
        $expectedPlanDigest = [string]$Journal['manifest_plan_digests'][$digestKey]
        if ([string]$manifest['transaction_status'] -ne 'uninstalled' -or
            $expectedPlanDigest -notmatch '^[0-9a-f]{64}$' -or
            (Get-InstallManifestPlanDigest -Manifest $manifest) -ne $expectedPlanDigest) {
            return $false
        }
    }
    $preimageOwnedManifestPaths = @(
        @($Journal['updated_global_history']) +
        @($Journal['global_manifest_paths']) +
        @($Journal['workspace_manifest_paths']) |
            ForEach-Object { Get-NormalizedPath -Path $_ } |
            Select-Object -Unique
    )
    $expectedOwnedDigestKeys = @($preimageOwnedManifestPaths | ForEach-Object { Get-InstallManifestDigestRegistryKey -ManifestPath $_ })
    if (-not (Test-StringSetEqual -Left @($Journal['registry_owned_manifest_plan_digests'].Keys) -Right $expectedOwnedDigestKeys)) {
        return $false
    }
    foreach ($path in $preimageOwnedManifestPaths) {
        $manifest = Read-InstallManifest -Path $path
        $digestKey = Get-InstallManifestDigestRegistryKey -ManifestPath $path
        $expectedPlanDigest = [string]$Journal['registry_owned_manifest_plan_digests'][$digestKey]
        if ($expectedPlanDigest -notmatch '^[0-9a-f]{64}$' -or
            (Get-InstallManifestPlanDigest -Manifest $manifest) -ne $expectedPlanDigest) {
            return $false
        }
    }
    $journalReleaseRegistry = [ordered]@{
        released_target_history = @($journalReleasedTargetHistory)
    }
    try {
        [void](Get-InstallRegistryReleasedTargetHistoryMap `
            -Registry $journalReleaseRegistry `
            -ExpectedUserProfile $env:USERPROFILE)
        Assert-InstallRegistryReleaseMarkerCoverage `
            -Registry $journalReleaseRegistry `
            -ExpectedUserProfile $env:USERPROFILE `
            -ManifestPaths $preimageOwnedManifestPaths
    } catch {
        return $false
    }
    if ($action -eq 'delete') {
        return -not (Test-Path -LiteralPath $RegistryPath)
    }
    if ($action -ne 'write') {
        throw "Unsupported uninstall journal registry action: $action"
    }
    $expectedPostimageStatusContract = [string]$Journal['postimage_transaction_status_contract']
    if ($expectedPostimageStatusContract -ne 'v1' -or
        [string]$Journal['postimage_history_ownership_contract'] -ne 'v1' -or
        [string]$Journal['postimage_manifest_integrity_contract'] -ne 'sha256-v1') {
        return $false
    }
    $currentRegistry = Read-JsonObject -Path $RegistryPath
    if ($null -eq $currentRegistry -or
        [string]$currentRegistry['schema_version'] -ne 'install-registry/v1.1' -or
        [string]$currentRegistry['transaction_status_contract'] -ne $expectedPostimageStatusContract -or
        [string]$currentRegistry['history_ownership_contract'] -ne [string]$Journal['postimage_history_ownership_contract'] -or
        [string]$currentRegistry['manifest_integrity_contract'] -ne [string]$Journal['postimage_manifest_integrity_contract'] -or
        -not ($currentRegistry['workspaces'] -is [System.Collections.IDictionary]) -or
        -not ($currentRegistry['manifest_digests'] -is [System.Collections.IDictionary]) -or
        -not ($currentRegistry['global_manifest_history'] -is [System.Collections.IList]) -or
        -not ($currentRegistry['retired_manifest_history'] -is [System.Collections.IList])) {
        return $false
    }
    [void](Get-InstallRegistryReleasedTargetHistoryMap -Registry $currentRegistry -ExpectedUserProfile $env:USERPROFILE)
    Assert-InstallRegistryReleaseMarkerCoverage `
        -Registry $currentRegistry `
        -ExpectedUserProfile $env:USERPROFILE `
        -ManifestPaths @($currentRegistry['global_manifest_history'])
    [object[]]$currentReleasedTargetHistory = @()
    if ($currentRegistry.Contains('released_target_history')) {
        $currentReleasedTargetHistory = @($currentRegistry['released_target_history'])
    }
    if (-not (Test-InstallJsonValueEqual -Left $journalReleasedTargetHistory -Right $currentReleasedTargetHistory)) {
        return $false
    }
    $expectedCurrentDigestKeys = @($currentRegistry['global_manifest_history'] | ForEach-Object { Get-InstallManifestDigestRegistryKey -ManifestPath $_ })
    if (-not (Test-StringSetEqual -Left @($currentRegistry['manifest_digests'].Keys) -Right $expectedCurrentDigestKeys)) {
        return $false
    }
    $currentKeys = @($currentRegistry['workspaces'].Keys | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedKeys = @($Journal['remaining_workspace_keys'] | ForEach-Object { [string]$_ } | Sort-Object)
    if (($currentKeys -join "`n") -ne ($expectedKeys -join "`n")) {
        return $false
    }
    if ($currentRegistry['workspaces'].Contains([string]$Journal['workspace_key']) -or
        -not (Test-NormalizedPathSequenceEqual -Left @($currentRegistry['global_manifest_history']) -Right @($Journal['updated_global_history'])) -or
        -not (Test-NormalizedPathSequenceEqual -Left @($currentRegistry['retired_manifest_history']) -Right @($Journal['updated_retired_manifest_history']))) {
        return $false
    }

    $workspaceManifestPaths = @($Journal['workspace_manifest_paths'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    if ($workspaceManifestPaths.Count -eq 0) {
        return $false
    }
    foreach ($path in $workspaceManifestPaths) {
        $manifest = Read-InstallManifest -Path $path
        $digestKey = Get-InstallManifestDigestRegistryKey -ManifestPath $path
        $expectedPlanDigest = [string]$Journal['manifest_plan_digests'][$digestKey]
        if ((Get-WorkspaceRegistryKey -Path $manifest['workspace_root']) -ne [string]$Journal['workspace_key'] -or
            (Get-NormalizedPath -Path $manifest['repo_root']) -ne (Get-NormalizedPath -Path $Journal['repo_root']) -or
            $expectedPlanDigest -notmatch '^[0-9a-f]{64}$' -or
            (Get-InstallManifestPlanDigest -Manifest $manifest) -ne $expectedPlanDigest) {
            return $false
        }
    }

    [void](Assert-GlobalHistoryState `
        -GlobalHistory @($currentRegistry['global_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ }) `
        -Workspaces $currentRegistry['workspaces'] `
        -Registry $currentRegistry `
        -RegistryPath $RegistryPath `
        -RequireManifestIntegrity $true `
        -RetiredManifestHistory @($currentRegistry['retired_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ }))
    return $true
}

function Resume-UninstallTransaction {
    param(
        [string]$JournalPath,
        [string]$ExpectedRepoRoot
    )

    $journal = Read-JsonObject -Path $JournalPath
    if ([string]$journal['schema_version'] -eq 'uninstall-transaction/v1.0') {
        throw "LIVE_UPDATE_REQUIRED: legacy-install-state; manual recovery is required for legacy uninstall transaction: $JournalPath"
    }
    if ($null -eq $journal -or
        [string]$journal['schema_version'] -ne 'uninstall-transaction/v1.1' -or
        [string]$journal['registry_schema_version'] -ne 'install-registry/v1.1' -or
        [string]$journal['manifest_schema_version'] -ne 'install-manifest/v1.2' -or
        [string]$journal['postimage_identity_contract'] -ne 'v1') {
        throw "Unsupported or unreadable uninstall transaction journal: $JournalPath"
    }
    $expectedUserProfile = Get-NormalizedPath -Path $env:USERPROFILE
    if ((Get-NormalizedPath -Path $journal['user_profile']) -ne $expectedUserProfile) {
        throw "Uninstall journal USERPROFILE mismatch: $JournalPath"
    }
    if ((Get-NormalizedPath -Path $journal['repo_root']) -ne (Get-NormalizedPath -Path $ExpectedRepoRoot)) {
        throw "Uninstall journal RepoRoot mismatch: $JournalPath"
    }
    $registryPath = Get-NormalizedPath -Path $journal['registry_path']
    if ($registryPath -ne (Get-NormalizedPath -Path (Join-Path $env:USERPROFILE '.dev-harness\install-registry.json'))) {
        throw "Uninstall journal registry path mismatch: $JournalPath"
    }
    $registryPreimageDigest = [string]$journal['registry_preimage_sha256']
    $currentRegistryDigest = Get-InstallStateFileDigest -Path $registryPath
    if ($currentRegistryDigest -ne $registryPreimageDigest) {
        if (Test-UninstallJournalRegistryCommitted -Journal $journal -RegistryPath $registryPath) {
            if ([string]$journal['registry_action'] -eq 'delete') { [void](Invoke-InstallExactPathTransition -Path $registryPath -SourceIdentity ([ordered]@{ mode = 'exact'; item_type = 'file'; sha256 = $registryPreimageDigest }) -DesiredIdentity (New-InstallExactMissingIdentity) -RecoverOnly) }
            Remove-Item -LiteralPath $JournalPath -Force
            return [pscustomobject]@{ Restored = @(); Removed = @(); KeptGenerated = @(); AlreadyCommitted = $true }
        }
        throw "Uninstall journal registry preimage no longer matches current state: $JournalPath"
    }

    $resumeRegistry = Read-JsonObject -Path $registryPath
    Assert-UninstallJournalDerivedState `
        -Journal $journal `
        -Registry $resumeRegistry `
        -RegistryPath $registryPath `
        -ExpectedRepoRoot $ExpectedRepoRoot

    $workspaceManifestPaths = @($journal['workspace_manifest_paths'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    $globalManifestPaths = @($journal['global_manifest_paths'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    $fullyConsumedManifestPaths = @($journal['fully_consumed_manifest_paths'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    $restoreUserGlobal = [bool]$journal['restore_user_global']
    $workspacePathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $globalPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $workspaceManifestPaths) {
        if (-not $workspacePathSet.Add($path)) { throw "Uninstall journal contains a duplicate workspace manifest: $path" }
    }
    foreach ($path in $globalManifestPaths) {
        if (-not $globalPathSet.Add($path)) { throw "Uninstall journal contains a duplicate global manifest: $path" }
    }
    $plannedPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($workspaceManifestPaths + $globalManifestPaths)) { [void]$plannedPathSet.Add($path) }
    $fullyConsumedPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $fullyConsumedManifestPaths) {
        if (-not $fullyConsumedPathSet.Add($path) -or -not $plannedPathSet.Contains($path)) {
            throw "Uninstall journal contains an unplanned or duplicate consumed manifest: $path"
        }
    }
    if (-not ($journal['manifest_plan_digests'] -is [System.Collections.IDictionary])) {
        throw "Uninstall journal is missing manifest plan digests: $JournalPath"
    }
    $resumeManifestIntegrityRequired = $null -ne $resumeRegistry -and
        [string]$resumeRegistry['manifest_integrity_contract'] -eq 'sha256-v1'

    $manifestCache = @{}
    foreach ($path in @($workspaceManifestPaths + $globalManifestPaths | Select-Object -Unique)) {
        $manifest = Read-InstallManifest -Path $path
        $digestKey = Get-InstallManifestDigestRegistryKey -ManifestPath $path
        $expectedPlanDigest = [string]$journal['manifest_plan_digests'][$digestKey]
        if ($expectedPlanDigest -notmatch '^[0-9a-f]{64}$' -or
            (Get-InstallManifestPlanDigest -Manifest $manifest) -ne $expectedPlanDigest) {
            throw "Uninstall journal manifest plan digest mismatch: $path"
        }
        if ([string]$manifest['transaction_status'] -ne 'uninstalled' -and
            $null -ne $resumeRegistry -and $resumeRegistry['manifest_digests'] -is [System.Collections.IDictionary]) {
            Assert-InstallManifestRegistryDigest `
                -Registry $resumeRegistry `
                -ManifestPath $path `
                -RequireManifestIntegrity $resumeManifestIntegrityRequired
        }
        $requiredScopes = @()
        if ($workspacePathSet.Contains($path)) { $requiredScopes += 'workspace' }
        if ($restoreUserGlobal -and $globalPathSet.Contains($path)) { $requiredScopes += 'user-global' }
        Assert-WorkspaceManifestIdentity `
            -ManifestPath $path `
            -Manifest $manifest `
            -ExpectedWorkspaceRoot (Get-NormalizedPath -Path $manifest['workspace_root']) `
            -RegistryPath $registryPath
        Assert-ManifestBackupBoundaries -Manifest $manifest -RequiredRestoreScopes $requiredScopes
        $manifestCache[$path] = $manifest
    }
    foreach ($path in $fullyConsumedManifestPaths) {
        Assert-InstallStateTextTargetWritable -Path $path
    }
    $restorePlan = @(Get-InstallRestorePlan `
        -WorkspaceManifestPaths $workspaceManifestPaths `
        -GlobalManifestPaths $globalManifestPaths `
        -RestoreUserGlobal $restoreUserGlobal `
        -ManifestCache $manifestCache `
        -ReleasedTargetHistory (Get-InstallRegistryReleasedTargetHistoryMap -Registry $resumeRegistry -ExpectedUserProfile $env:USERPROFILE))
    $resumeProjectionValidator = { param($Projected, $ProjectedPlan) [void](Get-InstallRestorePlanPrefix -Plan $ProjectedPlan -ProjectedExactIdentities $Projected) }
    Repair-InstallRestorePlanTransitions -Plan $restorePlan -ValidateProjectedPlan $resumeProjectionValidator
    $restorePrefix = Get-InstallRestorePlanPrefix -Plan $restorePlan

    Mark-LegacyPointerIfConsumed `
        -PointerPath (Get-NormalizedPath -Path $journal['legacy_pointer_path']) `
        -ConsumedManifestPaths @($workspaceManifestPaths + $globalManifestPaths) `
        -ExpectedManifestPlanDigests $journal['manifest_plan_digests']

    $script:Restored = @()
    $script:Removed = @()
    $keptGenerated = @()
    Invoke-InstallRestorePlan -Plan $restorePlan -StartIndex $restorePrefix
    if ($restoreUserGlobal) {
        foreach ($path in @($globalManifestPaths | Select-Object -Unique)) {
            $manifest = $manifestCache[$path]
            $generatedSystemPath = [string]$manifest['generated_repo_system_path']
            if ([string]::IsNullOrWhiteSpace($generatedSystemPath)) { continue }
            $generatedSystemPath = Get-NormalizedPath -Path $generatedSystemPath
            if (-not (Test-PathWithinRoot -Path $generatedSystemPath -RootPath $manifest['repo_root'])) {
                throw "Generated system path escapes repo root: $generatedSystemPath"
            }
            $dependentSystemLinks = @(@(
                Join-Path $manifest['claude_home'] 'skills\.system'
                Join-Path $manifest['codex_home'] 'skills\.system'
                Join-Path $manifest['agents_home'] 'skills\.system'
            ) | Where-Object { (Get-JunctionTarget -Path $_) -eq $generatedSystemPath })
            if ($dependentSystemLinks.Count -gt 0) {
                $keptGenerated += $generatedSystemPath
            } else {
                Remove-PathIfExists -Path $generatedSystemPath
            }
        }
    }

    $statusSnapshots = @(Set-ManifestTransactionStatusBatch -ManifestPaths $fullyConsumedManifestPaths -Status 'uninstalled')
    try {
        $registryAction = [string]$journal['registry_action']
        if ($registryAction -eq 'delete') {
            [void](Invoke-InstallExactPathTransition -Path $registryPath -SourceIdentity ([ordered]@{ mode = 'exact'; item_type = 'file'; sha256 = $registryPreimageDigest }) -DesiredIdentity (New-InstallExactMissingIdentity))
        } elseif ($registryAction -eq 'write') {
            $resumeRegistry = Read-JsonObject -Path $registryPath
            [void]$resumeRegistry['workspaces'].Remove([string]$journal['workspace_key'])
            $resumeRegistry['global_manifest_history'] = @($journal['updated_global_history'])
            $resumeRegistry['retired_manifest_history'] = @($journal['updated_retired_manifest_history'])
            $resumeRegistry['history_ownership_contract'] = 'v1'
            Refresh-InstallRegistryManifestDigests -Registry $resumeRegistry
            Write-InstallRegistry -Path $registryPath -Registry $resumeRegistry -ExpectedCurrentDigest $registryPreimageDigest
        } elseif ($registryAction -ne 'none') {
            throw "Unsupported uninstall journal registry action: $registryAction"
        }
    } catch {
        if ($registryAction -ne 'delete' -or [string]((Get-InstallManagedPathIdentity -Path $registryPath)['item_type']) -ne 'missing') { Restore-ManifestTransactionStatusBatch -Snapshots $statusSnapshots }
        throw
    }
    Remove-Item -LiteralPath $JournalPath -Force
    return [pscustomobject]@{
        Restored = @($script:Restored)
        Removed = @($script:Removed)
        KeptGenerated = @($keptGenerated)
        AlreadyCommitted = $false
    }
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    throw 'USERPROFILE is required for uninstall.ps1'
}
$selectorCount = @(@($WorkspaceRoot, $ManifestPath, $RecoveryManifestPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
$pendingUninstallJournalPath = Join-Path $env:USERPROFILE '.dev-harness\uninstall-transaction.json'
if ($selectorCount -gt 1) {
    throw 'Provide exactly one of -WorkspaceRoot, -ManifestPath, or -RecoveryManifestPath; implicit active-install uninstall is disabled'
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$RepoRoot = Get-NormalizedPath -Path $RepoRoot
$installTransactionMutex = Enter-InstallTransactionMutex -UserProfile $env:USERPROFILE
try {
$uninstallJournalPath = $pendingUninstallJournalPath
$installStateRoot = Join-Path $env:USERPROFILE '.dev-harness'
$pendingInstallJournalPath = Join-Path $installStateRoot 'install-transaction.json'
$registryPath = Join-Path $installStateRoot 'install-registry.json'
foreach ($installStatePath in @(
    $installStateRoot,
    $uninstallJournalPath,
    $pendingInstallJournalPath,
    $registryPath,
    (Join-Path $installStateRoot 'backups')
)) {
    [void](Assert-InstallStatePathHasNoReparsePoint -Path $installStatePath -Label 'Install state path')
}
if ($selectorCount -eq 0 -and -not (Test-Path -LiteralPath $pendingUninstallJournalPath -PathType Leaf)) {
    throw 'Provide exactly one of -WorkspaceRoot, -ManifestPath, or -RecoveryManifestPath; implicit active-install uninstall is disabled'
}
if (Test-Path -LiteralPath $uninstallJournalPath -PathType Leaf) {
    $resumeResult = Resume-UninstallTransaction `
        -JournalPath $uninstallJournalPath `
        -ExpectedRepoRoot $RepoRoot
    Write-Output 'Resumed pending uninstall transaction:'
    Write-Output ('- restored_count: {0}' -f @($resumeResult.Restored).Count)
    Write-Output ('- removed_generated_count: {0}' -f @($resumeResult.Removed).Count)
    Write-Output ('- kept_generated_count: {0}' -f @($resumeResult.KeptGenerated).Count)
    Write-Output ('- registry_already_committed: {0}' -f [bool]$resumeResult.AlreadyCommitted)
    return
}
$pendingInstallJournal = $null
if (Test-Path -LiteralPath $pendingInstallJournalPath -PathType Leaf) {
    $pendingInstallJournal = Read-JsonObject -Path $pendingInstallJournalPath
    if ([string]$pendingInstallJournal['schema_version'] -eq 'install-transaction/v1.0') {
        throw "LIVE_UPDATE_REQUIRED: legacy-install-state; manual recovery is required for legacy install transaction: $pendingInstallJournalPath"
    }
    if ($null -eq $pendingInstallJournal -or
        [string]$pendingInstallJournal['schema_version'] -ne 'install-transaction/v1.1' -or
        [string]$pendingInstallJournal['registry_schema_version'] -ne 'install-registry/v1.1' -or
        [string]$pendingInstallJournal['manifest_schema_version'] -ne 'install-manifest/v1.2' -or
        [string]$pendingInstallJournal['postimage_identity_contract'] -ne 'v1' -or
        (Get-NormalizedPath -Path $pendingInstallJournal['user_profile']) -ne (Get-NormalizedPath -Path $env:USERPROFILE) -or
        (Get-NormalizedPath -Path $pendingInstallJournal['repo_root']) -ne $RepoRoot -or
        (Get-NormalizedPath -Path $pendingInstallJournal['registry_path']) -ne (Get-NormalizedPath -Path $registryPath)) {
        throw "Unsupported or mismatched pending install transaction: $pendingInstallJournalPath"
    }
    $pendingRecoveryManifestPath = Get-NormalizedPath -Path $pendingInstallJournal['manifest_path']
    $pendingManifest = Read-InstallManifest -Path $pendingRecoveryManifestPath
    if ([string]$pendingManifest['schema_version'] -ne 'install-manifest/v1.2' -or
        [string]$pendingManifest['postimage_identity_contract'] -ne 'v1' -or
        (Get-NormalizedPath -Path $pendingManifest['repo_root']) -ne $RepoRoot -or
        (Get-NormalizedPath -Path $pendingManifest['workspace_root']) -ne (Get-NormalizedPath -Path $pendingInstallJournal['workspace_root']) -or
        [string]$pendingManifest['registry_preimage_sha256'] -ne [string]$pendingInstallJournal['registry_preimage_sha256']) {
        throw "Pending install journal does not match its manifest identity: $pendingInstallJournalPath"
    }
    Assert-WorkspaceManifestIdentity `
        -ManifestPath $pendingRecoveryManifestPath `
        -Manifest $pendingManifest `
        -ExpectedWorkspaceRoot $pendingInstallJournal['workspace_root'] `
        -RegistryPath $registryPath
    $pendingStatus = [string]$pendingManifest['transaction_status']
    $pendingRegistry = Read-JsonObject -Path $registryPath
    if ($pendingStatus -eq 'recovered') {
        $pendingPreimageDigest = [string]$pendingInstallJournal['registry_preimage_sha256']
        if ($pendingPreimageDigest -notmatch '^(missing|[0-9a-f]{64})$' -or
            (Get-InstallStateFileDigest -Path $registryPath) -ne $pendingPreimageDigest) {
            throw "Recovered install transaction registry preimage mismatch: $pendingInstallJournalPath"
        }
        $requestedRecoveredCleanup = -not [string]::IsNullOrWhiteSpace($RecoveryManifestPath) -and
            (Get-NormalizedPath -Path $RecoveryManifestPath) -eq $pendingRecoveryManifestPath
        Remove-Item -LiteralPath $pendingInstallJournalPath -Force
        $pendingInstallJournal = $null
        if ($requestedRecoveredCleanup) {
            Write-Output 'Recovery summary:'
            Write-Output ('- manifest: {0}' -f $pendingRecoveryManifestPath)
            Write-Output '- already_recovered: True'
            Write-Output '- registry_changed: False'
            return
        }
    } elseif ($pendingStatus -eq 'committed') {
        $requestedCommittedRollback = -not [string]::IsNullOrWhiteSpace($RecoveryManifestPath) -and
            (Get-NormalizedPath -Path $RecoveryManifestPath) -eq $pendingRecoveryManifestPath
        $pendingRegistryPreimageDigest = [string]$pendingInstallJournal['registry_preimage_sha256']
        $registryStillMatchesPreimage = $pendingRegistryPreimageDigest -match '^(missing|[0-9a-f]{64})$' -and
            (Get-InstallStateFileDigest -Path $registryPath) -eq $pendingRegistryPreimageDigest
        if (-not ($requestedCommittedRollback -and $registryStillMatchesPreimage)) {
        $pendingExpectedStatusContract = [string]$pendingInstallJournal['postimage_transaction_status_contract']
        if ($pendingExpectedStatusContract -ne 'v1' -or
            [string]$pendingInstallJournal['postimage_history_ownership_contract'] -ne 'v1' -or
            [string]$pendingInstallJournal['postimage_manifest_integrity_contract'] -ne 'sha256-v1') {
            throw "Pending install transaction is missing its committed postimage contract: $pendingInstallJournalPath"
        }
        if ($null -eq $pendingRegistry -or
            [string]$pendingRegistry['schema_version'] -ne 'install-registry/v1.1' -or
            [string]$pendingRegistry['history_ownership_contract'] -ne [string]$pendingInstallJournal['postimage_history_ownership_contract'] -or
            [string]$pendingRegistry['manifest_integrity_contract'] -ne [string]$pendingInstallJournal['postimage_manifest_integrity_contract'] -or
            [string]$pendingRegistry['transaction_status_contract'] -ne $pendingExpectedStatusContract -or
            -not ($pendingRegistry['workspaces'] -is [System.Collections.IDictionary]) -or
            -not ($pendingRegistry['global_manifest_history'] -is [System.Collections.IList]) -or
            -not ($pendingRegistry['retired_manifest_history'] -is [System.Collections.IList]) -or
            -not ($pendingRegistry['manifest_digests'] -is [System.Collections.IDictionary])) {
            throw "Pending install transaction registry is not a committed postimage: $pendingInstallJournalPath"
        }
        $pendingWorkspaceKey = Get-WorkspaceRegistryKey -Path $pendingInstallJournal['workspace_root']
        if (-not $pendingRegistry['workspaces'].Contains($pendingWorkspaceKey)) {
            throw "Pending install transaction workspace is not registered: $pendingInstallJournalPath"
        }
        $pendingEntry = $pendingRegistry['workspaces'][$pendingWorkspaceKey]
        if (-not ($pendingEntry -is [System.Collections.IDictionary])) {
            throw "Pending install transaction workspace entry is invalid: $pendingInstallJournalPath"
        }
        $pendingEntryPaths = @($pendingEntry['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        $pendingGlobalHistory = @($pendingRegistry['global_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        if ((Get-NormalizedPath -Path $pendingEntry['workspace_root']) -ne (Get-NormalizedPath -Path $pendingInstallJournal['workspace_root']) -or
            (Get-NormalizedPath -Path $pendingEntry['repo_root']) -ne $RepoRoot -or
            $pendingEntryPaths.Count -eq 0 -or $pendingEntryPaths[-1] -ne $pendingRecoveryManifestPath -or
            $pendingGlobalHistory.Count -eq 0 -or $pendingGlobalHistory[-1] -ne $pendingRecoveryManifestPath) {
            throw "Pending install transaction owner or history does not match its committed postimage: $pendingInstallJournalPath"
        }
        $pendingExpectedDigestKeys = @($pendingGlobalHistory | ForEach-Object { Get-InstallManifestDigestRegistryKey -ManifestPath $_ })
        if (-not (Test-StringSetEqual -Left @($pendingRegistry['manifest_digests'].Keys) -Right $pendingExpectedDigestKeys)) {
            throw "Pending install transaction registry digest keys do not match owner history: $pendingInstallJournalPath"
        }
        Assert-InstallManifestRegistryDigest `
            -Registry $pendingRegistry `
            -ManifestPath $pendingRecoveryManifestPath `
            -RequireManifestIntegrity $true
        [void](Assert-GlobalHistoryState `
            -GlobalHistory $pendingGlobalHistory `
            -Workspaces $pendingRegistry['workspaces'] `
            -Registry $pendingRegistry `
            -RegistryPath $registryPath `
            -RequireManifestIntegrity $true `
            -RetiredManifestHistory @($pendingRegistry['retired_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ }))
        if (-not [string]::IsNullOrWhiteSpace([string]$pendingInstallJournal['legacy_pointer_import_digest'])) {
            $pendingExpectedLegacyPointerPath = Get-NormalizedPath -Path (Join-Path $pendingInstallJournal['repo_root'] 'backups\active-install.json')
            if ([string]$pendingInstallJournal['legacy_pointer_import_digest'] -notmatch '^[0-9a-f]{64}$' -or
                (Get-NormalizedPath -Path $pendingInstallJournal['legacy_pointer_path']) -ne $pendingExpectedLegacyPointerPath) {
                throw "Pending install transaction legacy pointer identity is invalid: $pendingInstallJournalPath"
            }
            Set-LegacyPointerMigrationMarked `
                -UserProfile $env:USERPROFILE `
                -PointerPath $pendingInstallJournal['legacy_pointer_path'] `
                -ExpectedPointerDigest $pendingInstallJournal['legacy_pointer_import_digest']
        }
        Remove-Item -LiteralPath $pendingInstallJournalPath -Force
        $pendingInstallJournal = $null
        }
    } elseif ([string]::IsNullOrWhiteSpace($RecoveryManifestPath) -or
        (Get-NormalizedPath -Path $RecoveryManifestPath) -ne $pendingRecoveryManifestPath) {
        throw "A pending install transaction must be recovered first. Run uninstall.ps1 -RecoveryManifestPath '$pendingRecoveryManifestPath'"
    }
}
$registry = Read-JsonObject -Path $registryPath
$retiredManifestHistory = @()
$releasedTargetHistory = @{}
if ($null -ne $registry) {
    $schemaVersion = [string]$registry['schema_version']
    if ($schemaVersion -notin @('install-registry/v1.0','install-registry/v1.1') -or
        -not ($registry['workspaces'] -is [System.Collections.IDictionary]) -or
        -not ($registry['global_manifest_history'] -is [System.Collections.IList])) {
        throw "Unsupported or malformed install registry: $registryPath"
    }
    $modernFields = @('transaction_status_contract','history_ownership_contract','manifest_integrity_contract','retired_manifest_history','manifest_digests')
    $presentModernFields = @($modernFields | Where-Object { $registry.Contains($_) })
    if ($schemaVersion -eq 'install-registry/v1.0') {
        if ($presentModernFields.Count -notin @(0, $modernFields.Count)) {
            throw "Legacy install registry contains a partial modern contract: $registryPath"
        }
        $ownedManifestPaths = @($registry['global_manifest_history'])
        foreach ($entry in $registry['workspaces'].Values) {
            if (-not ($entry -is [System.Collections.IDictionary]) -or
                -not ($entry['manifests'] -is [System.Collections.IList])) {
                throw "Legacy install registry workspace entry is invalid: $registryPath"
            }
            $ownedManifestPaths += @($entry['manifests'])
        }
        foreach ($manifestPath in @($ownedManifestPaths | Select-Object -Unique)) {
            $ownedManifest = Read-InstallManifest -Path $manifestPath
            if ([string]$ownedManifest['schema_version'] -ne 'install-manifest/v1.2') {
                throw 'LIVE_UPDATE_REQUIRED: legacy-install-state'
            }
        }
        if ($ownedManifestPaths.Count -gt 0 -and $presentModernFields.Count -ne $modernFields.Count) {
            throw "Legacy install registry cannot validate modern manifest integrity: $registryPath"
        }
        $registry['schema_version'] = 'install-registry/v1.1'
    } elseif ($presentModernFields.Count -ne $modernFields.Count) {
        throw "Modern install registry is missing required contract state: $registryPath"
    }
    if ([string]$registry['transaction_status_contract'] -ne 'v1' -or
        [string]$registry['history_ownership_contract'] -ne 'v1' -or
        [string]$registry['manifest_integrity_contract'] -ne 'sha256-v1' -or
        -not ($registry['retired_manifest_history'] -is [System.Collections.IList]) -or
        -not ($registry['manifest_digests'] -is [System.Collections.IDictionary])) {
        throw "Modern install registry contract is invalid: $registryPath"
    }
    $retiredManifestHistory = @($registry['retired_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ })
    $releasedTargetHistory = Get-InstallRegistryReleasedTargetHistoryMap -Registry $registry -ExpectedUserProfile $env:USERPROFILE
    Assert-InstallRegistryReleaseMarkerCoverage `
        -Registry $registry `
        -ExpectedUserProfile $env:USERPROFILE `
        -ManifestPaths @($registry['global_manifest_history'])
}
$workspaces = if ($null -ne $registry) { $registry['workspaces'] } else { [ordered]@{} }
$manifestIntegrityRequired = $null -ne $registry

if (-not [string]::IsNullOrWhiteSpace($RecoveryManifestPath)) {
    $RecoveryManifestPath = Get-NormalizedPath -Path $RecoveryManifestPath
    $recoveryManifest = Read-InstallManifest -Path $RecoveryManifestPath
    Assert-RecoveryManifestIdentity `
        -ManifestPath $RecoveryManifestPath `
        -Manifest $recoveryManifest `
        -Registry $registry `
        -RegistryPath $registryPath `
        -RepoRoot $RepoRoot
    Assert-ManifestBackupBoundaries -Manifest $recoveryManifest
    Assert-InstallStateTextTargetWritable -Path $RecoveryManifestPath
    $recoveryManifestCache = @{
        (Get-NormalizedPath -Path $RecoveryManifestPath) = $recoveryManifest
    }
    $recoveryRestorePlan = @(Get-InstallRestorePlan `
        -WorkspaceManifestPaths @($RecoveryManifestPath) `
        -GlobalManifestPaths @($RecoveryManifestPath) `
        -RestoreUserGlobal $true `
        -ManifestCache $recoveryManifestCache `
        -ReleasedTargetHistory $releasedTargetHistory)
    if ($null -ne $pendingInstallJournal) {
        Assert-InstallStateTextTargetWritable -Path $pendingInstallJournalPath
    }
    $recoveryProjectionValidator = { param($Projected, $ProjectedPlan) [void](Get-InstallRestorePlanPrefix -Plan $ProjectedPlan -ProjectedExactIdentities $Projected) }
    Repair-InstallRestorePlanTransitions -Plan $recoveryRestorePlan -FailedInstall -ValidateProjectedPlan $recoveryProjectionValidator
    $recoveryRestorePrefix = Get-InstallRestorePlanPrefix -Plan $recoveryRestorePlan

    $script:Restored = @()
    $script:Removed = @()
    Invoke-InstallRestorePlan -Plan $recoveryRestorePlan -StartIndex $recoveryRestorePrefix
    $recoveryManifest['transaction_status'] = 'recovered'
    Write-InstallStateTextAtomic -Path $RecoveryManifestPath -Content (ConvertTo-Json -InputObject $recoveryManifest -Depth 100)
    if ($null -ne $pendingInstallJournal) {
        Remove-Item -LiteralPath $pendingInstallJournalPath -Force
    }

    Write-Output 'Recovery summary:'
    Write-Output ('- manifest: {0}' -f $RecoveryManifestPath)
    Write-Output ('- restored_count: {0}' -f @($script:Restored).Count)
    Write-Output ('- removed_generated_count: {0}' -f @($script:Removed).Count)
    Write-Output '- registry_changed: False'
    return
}

$registered = $false
$workspaceKey = $null
$workspaceManifestPaths = @()
$selectedManifest = $null
$selectedEntry = $null

if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = Get-NormalizedPath -Path $WorkspaceRoot
    $workspaceKey = Get-WorkspaceRegistryKey -Path $WorkspaceRoot
    if (-not $workspaces.Contains($workspaceKey)) {
        throw "Workspace is not registered for this USERPROFILE: $WorkspaceRoot"
    }

    $registered = $true
    $selectedEntry = $workspaces[$workspaceKey]
    $workspaceManifestPaths = @($workspaces[$workspaceKey]['manifests'])
    if ($workspaceManifestPaths.Count -eq 0) {
        throw "Workspace registry entry has no install manifests: $WorkspaceRoot"
    }
    $ManifestPath = Get-NormalizedPath -Path $workspaceManifestPaths[-1]
    $selectedManifest = Read-InstallManifest -Path $ManifestPath
} else {
    $ManifestPath = Get-NormalizedPath -Path $ManifestPath
    $selectedManifest = Read-InstallManifest -Path $ManifestPath
    $WorkspaceRoot = Get-NormalizedPath -Path $selectedManifest['workspace_root']
    $workspaceKey = Get-WorkspaceRegistryKey -Path $WorkspaceRoot

    if ($workspaces.Contains($workspaceKey)) {
        $registeredPaths = @($workspaces[$workspaceKey]['manifests'] | ForEach-Object { Get-NormalizedPath -Path $_ })
        if ($registeredPaths.Count -eq 0 -or $registeredPaths[-1] -ne $ManifestPath) {
            throw "Only the latest registered manifest may select a workspace uninstall: $ManifestPath"
        }
        $registered = $true
        $selectedEntry = $workspaces[$workspaceKey]
        $workspaceManifestPaths = @($registeredPaths)
    } elseif ($workspaces.Count -gt 0) {
        throw 'Refusing an unregistered manifest while other workspaces still share user-global assets'
    } else {
        $workspaceManifestPaths = @($ManifestPath)
    }
}

Assert-NormalInstallManifestStatus `
    -Manifest $selectedManifest `
    -ManifestPath $ManifestPath

if ($registered) {
    Assert-RegisteredWorkspaceSelection `
        -Entry $selectedEntry `
        -WorkspaceKey $workspaceKey `
        -WorkspaceRoot $WorkspaceRoot `
        -ManifestPath $ManifestPath `
        -Manifest $selectedManifest `
        -RegistryPath $registryPath `
        -RepoRoot $RepoRoot
} else {
    Assert-WorkspaceManifestIdentity `
        -ManifestPath $ManifestPath `
        -Manifest $selectedManifest `
        -ExpectedWorkspaceRoot $WorkspaceRoot `
        -RegistryPath $registryPath
    if ((Get-NormalizedPath -Path $selectedManifest['repo_root']) -ne (Get-NormalizedPath -Path $RepoRoot)) {
        throw "Unregistered install manifest repo owner does not match invoking repo: $ManifestPath"
    }
    if (@(Get-InstallReleasedBackupTargetPaths -Manifest $selectedManifest).Count -gt 0) {
        throw "Unregistered release manifest requires install registry evidence: $ManifestPath"
    }
}

$remainingWorkspaceCount = if ($registered) { $workspaces.Count - 1 } else { 0 }
$globalHistory = @()
if ($registered) {
    $globalHistory = @($registry['global_manifest_history'] | ForEach-Object { Get-NormalizedPath -Path $_ })
}
$updatedGlobalHistory = @($globalHistory)
$activeOwner = $null
if ($registered) {
    $activeOwner = Assert-GlobalHistoryState `
        -GlobalHistory $globalHistory `
        -Workspaces $workspaces `
        -Registry $registry `
        -RegistryPath $registryPath `
        -RequireManifestIntegrity $manifestIntegrityRequired `
        -RetiredManifestHistory $retiredManifestHistory
}
$restoreUserGlobal = (-not $registered) -or $remainingWorkspaceCount -eq 0
$globalManifestPaths = @()
if ($registered -and $remainingWorkspaceCount -eq 0) {
    if ($globalHistory.Count -gt 0) {
        $globalManifestPaths = @($globalHistory)
    } else {
        $globalManifestPaths = @($workspaceManifestPaths)
    }
} elseif ($restoreUserGlobal) {
    $globalManifestPaths = @($workspaceManifestPaths)
} elseif ($registered) {
    if ($activeOwner.WorkspaceKey -eq $workspaceKey) {
        $handoffIndex = -1
        for ($historyIndex = $globalHistory.Count - 2; $historyIndex -ge 0; $historyIndex--) {
            $candidatePath = $globalHistory[$historyIndex]
            $candidateManifest = Read-InstallManifest -Path $candidatePath
            $candidateKey = Get-WorkspaceRegistryKey -Path $candidateManifest['workspace_root']
            if ($candidateKey -eq $workspaceKey -or -not $workspaces.Contains($candidateKey)) {
                continue
            }

            $handoffOwner = Get-RegisteredManifestOwner `
                -ManifestPath $candidatePath `
                -Workspaces $workspaces `
                -RegistryPath $registryPath
            if (-not (Test-Path -LiteralPath (Join-Path $handoffOwner.RepoRoot 'skills') -PathType Container)) {
                throw "Remaining user-global owner repo is unavailable: $($handoffOwner.RepoRoot)"
            }
            $handoffIndex = $historyIndex
            break
        }
        if ($handoffIndex -lt 0) {
            throw 'No valid remaining workspace can own user-global assets'
        }

        $restoreUserGlobal = $true
        $globalManifestPaths = @($globalHistory[($handoffIndex + 1)..($globalHistory.Count - 1)])
        $updatedGlobalHistory = @($globalHistory[0..$handoffIndex])
    }
}

$updatedRetiredManifestHistory = @($retiredManifestHistory)
if ($registered -and $remainingWorkspaceCount -gt 0) {
    $retiredCandidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($retiredManifestPath in $retiredManifestHistory) {
        [void]$retiredCandidates.Add((Get-NormalizedPath -Path $retiredManifestPath))
    }
    foreach ($workspaceManifestPath in $workspaceManifestPaths) {
        [void]$retiredCandidates.Add((Get-NormalizedPath -Path $workspaceManifestPath))
    }
    $updatedRetiredManifestHistory = @($updatedGlobalHistory | Where-Object {
        $retiredCandidates.Contains((Get-NormalizedPath -Path $_))
    })
}

$manifestCache = @{}
$normalizedWorkspaceManifestPaths = @($workspaceManifestPaths | ForEach-Object { Get-NormalizedPath -Path $_ })
$normalizedGlobalManifestPaths = @($globalManifestPaths | ForEach-Object { Get-NormalizedPath -Path $_ })
foreach ($path in @($workspaceManifestPaths + $globalManifestPaths | Select-Object -Unique)) {
    $normalizedPath = Get-NormalizedPath -Path $path
    $manifest = Read-InstallManifest -Path $normalizedPath
    $requiredRestoreScopes = @()
    if ($normalizedWorkspaceManifestPaths -contains $normalizedPath) {
        $requiredRestoreScopes += 'workspace'
    }
    if ($restoreUserGlobal -and $normalizedGlobalManifestPaths -contains $normalizedPath) {
        $requiredRestoreScopes += 'user-global'
    }
    Assert-ManifestBackupBoundaries `
        -Manifest $manifest `
        -RequiredRestoreScopes $requiredRestoreScopes
    $manifestCache[$normalizedPath] = $manifest
}

$candidateConsumedManifestPaths = @($workspaceManifestPaths + $globalManifestPaths | ForEach-Object { Get-NormalizedPath -Path $_ } | Select-Object -Unique)
if ($registered -and $remainingWorkspaceCount -gt 0) {
    $retainedHistoryPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($retainedPath in $updatedGlobalHistory) {
        [void]$retainedHistoryPaths.Add((Get-NormalizedPath -Path $retainedPath))
    }
    $fullyConsumedManifestPaths = @($candidateConsumedManifestPaths | Where-Object {
        -not $retainedHistoryPaths.Contains((Get-NormalizedPath -Path $_))
    })
} else {
    $fullyConsumedManifestPaths = @($candidateConsumedManifestPaths)
}
foreach ($consumedManifestPath in $fullyConsumedManifestPaths) {
    Assert-InstallStateTextTargetWritable -Path $consumedManifestPath
}
$restorePlan = @(Get-InstallRestorePlan `
    -WorkspaceManifestPaths $workspaceManifestPaths `
    -GlobalManifestPaths $globalManifestPaths `
    -RestoreUserGlobal $restoreUserGlobal `
    -ManifestCache $manifestCache `
    -ReleasedTargetHistory $releasedTargetHistory)
[void](Get-InstallRestorePlanPrefix -Plan $restorePlan -RequireInitial)

$legacyActiveInstallPath = Join-Path $RepoRoot 'backups\active-install.json'
$registryAction = 'none'
$remainingWorkspaceKeys = @()
if ($registered) {
    $remainingWorkspaceKeys = @($workspaces.Keys | Where-Object { [string]$_ -ne $workspaceKey } | ForEach-Object { [string]$_ })
    $registryAction = if ($remainingWorkspaceKeys.Count -eq 0) { 'delete' } else { 'write' }
}
$manifestPlanDigests = [ordered]@{}
foreach ($manifestPath in @($workspaceManifestPaths + $globalManifestPaths | ForEach-Object { Get-NormalizedPath -Path $_ } | Select-Object -Unique)) {
    $manifestPlanDigests[(Get-InstallManifestDigestRegistryKey -ManifestPath $manifestPath)] = `
        Get-InstallManifestPlanDigest -Manifest $manifestCache[$manifestPath]
}
$registryOwnedManifestPlanDigests = [ordered]@{}
if ($registered) {
    foreach ($manifestPath in @($globalHistory | ForEach-Object { Get-NormalizedPath -Path $_ } | Select-Object -Unique)) {
        $ownedManifest = if ($manifestCache.ContainsKey($manifestPath)) {
            $manifestCache[$manifestPath]
        } else {
            Read-InstallManifest -Path $manifestPath
        }
        $registryOwnedManifestPlanDigests[(Get-InstallManifestDigestRegistryKey -ManifestPath $manifestPath)] = `
            Get-InstallManifestPlanDigest -Manifest $ownedManifest
    }
}
$postimageTransactionStatusContract = if ($registryAction -eq 'write') { [string]$registry['transaction_status_contract'] } else { $null }
$postimageHistoryOwnershipContract = if ($registryAction -eq 'write') { 'v1' } else { $null }
$postimageManifestIntegrityContract = if ($registryAction -eq 'write') { 'sha256-v1' } else { $null }
$uninstallJournal = [ordered]@{
    schema_version = 'uninstall-transaction/v1.1'
    registry_schema_version = 'install-registry/v1.1'
    manifest_schema_version = 'install-manifest/v1.2'
    postimage_identity_contract = 'v1'
    prepared_at = (Get-Date -Format 's')
    user_profile = (Get-NormalizedPath -Path $env:USERPROFILE)
    repo_root = $RepoRoot
    registry_path = $registryPath
    registry_preimage_sha256 = (Get-InstallStateFileDigest -Path $registryPath)
    registry_action = $registryAction
    postimage_transaction_status_contract = $postimageTransactionStatusContract
    postimage_history_ownership_contract = $postimageHistoryOwnershipContract
    postimage_manifest_integrity_contract = $postimageManifestIntegrityContract
    workspace_key = $workspaceKey
    remaining_workspace_keys = @($remainingWorkspaceKeys)
    workspace_manifest_paths = @($workspaceManifestPaths)
    global_manifest_paths = @($globalManifestPaths)
    fully_consumed_manifest_paths = @($fullyConsumedManifestPaths)
    manifest_plan_digests = $manifestPlanDigests
    registry_owned_manifest_plan_digests = $registryOwnedManifestPlanDigests
    restore_user_global = [bool]$restoreUserGlobal
    updated_global_history = @($updatedGlobalHistory)
    updated_retired_manifest_history = @($updatedRetiredManifestHistory)
    released_target_history = @($(if ($null -ne $registry -and $registry.Contains('released_target_history')) { $registry['released_target_history'] } else { @() }))
    legacy_pointer_path = $legacyActiveInstallPath
}
Write-InstallStateTextAtomic `
    -Path $uninstallJournalPath `
    -Content (ConvertTo-Json -InputObject $uninstallJournal -Depth 100)
Mark-LegacyPointerIfConsumed `
    -PointerPath $legacyActiveInstallPath `
    -ConsumedManifestPaths @($workspaceManifestPaths + $globalManifestPaths) `
    -ExpectedManifestPlanDigests $manifestPlanDigests

$script:Restored = @()
$script:Removed = @()
$keptGenerated = @()

Invoke-InstallRestorePlan -Plan $restorePlan

if ($restoreUserGlobal) {
    foreach ($path in @($globalManifestPaths | Select-Object -Unique)) {
        $manifest = $manifestCache[(Get-NormalizedPath -Path $path)]
        $generatedSystemPath = $manifest['generated_repo_system_path']
        if ([string]::IsNullOrWhiteSpace($generatedSystemPath)) {
            continue
        }

        $generatedSystemPath = Get-NormalizedPath -Path $generatedSystemPath
        if (-not (Test-PathWithinRoot -Path $generatedSystemPath -RootPath $manifest['repo_root'])) {
            throw "Generated system path escapes repo root: $generatedSystemPath"
        }
        $dependentSystemLinks = @(@(
            Join-Path $manifest['claude_home'] 'skills\.system'
            Join-Path $manifest['codex_home'] 'skills\.system'
            Join-Path $manifest['agents_home'] 'skills\.system'
        ) | Where-Object { (Get-JunctionTarget -Path $_) -eq $generatedSystemPath })

        if ($dependentSystemLinks.Count -gt 0) {
            $keptGenerated += $generatedSystemPath
        } else {
            Remove-PathIfExists -Path $generatedSystemPath
        }
    }
}

$manifestStatusSnapshots = @(Set-ManifestTransactionStatusBatch `
    -ManifestPaths $fullyConsumedManifestPaths `
    -Status 'uninstalled')
try {
    if ($registered) {
        $workspaces.Remove($workspaceKey)
        if ($workspaces.Count -eq 0) {
            [void](Invoke-InstallExactPathTransition -Path $registryPath -SourceIdentity ([ordered]@{ mode = 'exact'; item_type = 'file'; sha256 = [string]$uninstallJournal['registry_preimage_sha256'] }) -DesiredIdentity (New-InstallExactMissingIdentity))
        } else {
            $registry['global_manifest_history'] = @($updatedGlobalHistory)
            $registry['retired_manifest_history'] = @($updatedRetiredManifestHistory)
            $registry['history_ownership_contract'] = 'v1'
            Refresh-InstallRegistryManifestDigests -Registry $registry
            Write-InstallRegistry -Path $registryPath -Registry $registry -ExpectedCurrentDigest ([string]$uninstallJournal['registry_preimage_sha256'])
        }
    }
} catch {
    if ($registryAction -ne 'delete' -or [string]((Get-InstallManagedPathIdentity -Path $registryPath)['item_type']) -ne 'missing') { Restore-ManifestTransactionStatusBatch -Snapshots $manifestStatusSnapshots }
    throw
}
Remove-Item -LiteralPath $uninstallJournalPath -Force

$restored = @($script:Restored)
$removed = @($script:Removed)

Write-Output 'Uninstall summary:'
Write-Output ('- manifest: {0}' -f $ManifestPath)
Write-Output ('- restored_count: {0}' -f @($restored).Count)
Write-Output ('- removed_generated_count: {0}' -f @($removed).Count)
Write-Output ('- kept_generated_count: {0}' -f @($keptGenerated).Count)
Write-Output ('- shared_user_global_restored: {0}' -f $restoreUserGlobal)
if (@($restored).Count -gt 0) {
    Write-Output '- restored paths:'
    foreach ($path in $restored) {
        Write-Output ('  {0}' -f $path)
    }
}
if (@($removed).Count -gt 0) {
    Write-Output '- removed generated paths:'
    foreach ($path in $removed) {
        Write-Output ('  {0}' -f $path)
    }
}
if (@($keptGenerated).Count -gt 0) {
    Write-Output '- kept generated paths still referenced by host links:'
    foreach ($path in $keptGenerated) {
        Write-Output ('  {0}' -f $path)
    }
}
} finally {
    Exit-InstallTransactionMutex -Mutex $installTransactionMutex
}
