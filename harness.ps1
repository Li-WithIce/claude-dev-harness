[CmdletBinding()]
param(
    [string]$WorkspaceRoot = "",
    [string]$RepoRoot = "",
    [switch]$SkipStatus
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Convert-ToLineArray {
    param($Output)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Output)) {
        if ($null -eq $item) {
            continue
        }

        [void]$lines.Add(([string]$item))
    }

    return @($lines)
}

function Get-SectionItems {
    param(
        [string[]]$Lines,
        [string]$SectionName
    )

    $startIndex = -1
    for ($index = 0; $index -lt $Lines.Count; $index += 1) {
        if ($Lines[$index].Trim() -eq ("{0}:" -f $SectionName)) {
            $startIndex = $index + 1
            break
        }
    }

    if ($startIndex -lt 0) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[string]
    for ($index = $startIndex; $index -lt $Lines.Count; $index += 1) {
        $line = $Lines[$index].Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($items.Count -gt 0) {
                break
            }
            continue
        }

        if ($line -match '^[A-Za-z][A-Za-z /()_-]*:$') {
            break
        }

        if ($line -eq '- none') {
            continue
        }

        if ($line.StartsWith('- ')) {
            [void]$items.Add($line.Substring(2))
        }
    }

    return @($items)
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [hashtable]$Arguments
    )

    $output = @()
    $exitCode = 0

    try {
        $output = @(& $ScriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $output = @($_.Exception.Message)
        $exitCode = 2
    }

    $lines = Convert-ToLineArray -Output $output
    $text = $lines -join [Environment]::NewLine
    $status = if ($text -match '(?im)^STATUS:\s+(PASS|WARN|FAIL)\s*$') {
        $matches[1].ToUpperInvariant()
    } elseif ($exitCode -eq 0) {
        'PASS'
    } else {
        'FAIL'
    }

    return [pscustomobject]@{
        Name     = $Name
        Status   = $status
        ExitCode = $exitCode
        Checks   = @(Get-SectionItems -Lines $lines -SectionName 'Checks')
        Warnings = @(Get-SectionItems -Lines $lines -SectionName 'Warnings')
        Errors   = @(Get-SectionItems -Lines $lines -SectionName 'Errors')
        Highlights = @(Get-SectionItems -Lines $lines -SectionName 'Highlights')
        Next     = @(Get-SectionItems -Lines $lines -SectionName 'Recommended Next Step')
        Output   = $lines
    }
}

function Get-OverallStatus {
    param([object[]]$Results)

    if (@($Results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) {
        return 'FAIL'
    }

    if (@($Results | Where-Object { $_.Status -eq 'WARN' -and $_.Name -cne 'harness-status.ps1' }).Count -gt 0) {
        return 'WARN'
    }

    return 'PASS'
}

function Test-PathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    $normalizedPath = Get-NormalizedPath -Path $Path
    $normalizedRoot = Get-NormalizedPath -Path $Root
    if ([string]::IsNullOrWhiteSpace($normalizedPath) -or [string]::IsNullOrWhiteSpace($normalizedRoot)) {
        return $false
    }

    return (
        $normalizedPath.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith($normalizedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Find-AncestorContaining {
    param(
        [string]$StartPath,
        [string]$ChildName,
        [string]$RepoRoot
    )

    $candidateRoot = Get-NormalizedPath -Path $StartPath
    while (-not [string]::IsNullOrWhiteSpace($candidateRoot)) {
        if (Test-Path -LiteralPath (Join-Path $candidateRoot $ChildName)) {
            if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not $candidateRoot.Equals($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $candidateRoot
            }
        }

        $parent = Split-Path -Parent $candidateRoot
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidateRoot) {
            break
        }

        $candidateRoot = $parent
    }

    return $null
}

function Get-GitFileWorkspaceKind {
    param([Parameter(Mandatory = $true)][string]$GitRoot)

    $gitMarker = Join-Path $GitRoot '.git'
    if (-not (Test-Path -LiteralPath $gitMarker -PathType Leaf)) {
        throw "Cannot classify gitfile workspace because .git is not a file: $GitRoot"
    }

    $gitEnvironmentNames = @('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR')
    $savedGitEnvironment = [ordered]@{}
    $presentGitEnvironment = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($name in $gitEnvironmentNames) {
            if (Test-Path -LiteralPath "Env:$name") {
                [void]$presentGitEnvironment.Add($name)
                $savedGitEnvironment[$name] = (Get-Item -LiteralPath "Env:$name").Value
            }
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
        try {
            $metadata = @(& git -C $GitRoot rev-parse --path-format=absolute --git-dir --git-common-dir 2>$null)
            $gitExitCode = $LASTEXITCODE
            $superprojectMetadata = @(& git -C $GitRoot rev-parse --path-format=absolute --show-superproject-working-tree 2>$null)
            $superprojectExitCode = $LASTEXITCODE
        } catch {
            throw "Unable to classify gitfile workspace safely. Pass -WorkspaceRoot explicitly. GitRoot=$GitRoot"
        }
    } finally {
        foreach ($name in $gitEnvironmentNames) {
            if ($presentGitEnvironment.Contains($name)) {
                Set-Item -LiteralPath "Env:$name" -Value ([string]$savedGitEnvironment[$name])
            } else {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }
    if ($gitExitCode -ne 0 -or $metadata.Count -ne 2 -or
        $superprojectExitCode -ne 0 -or $superprojectMetadata.Count -gt 1) {
        throw "Unable to classify gitfile workspace safely. Pass -WorkspaceRoot explicitly. GitRoot=$GitRoot"
    }

    try {
        $gitDirectory = Get-NormalizedPath -Path ([string]$metadata[0]).Trim()
        $commonDirectory = Get-NormalizedPath -Path ([string]$metadata[1]).Trim()
    } catch {
        throw "Unable to classify gitfile workspace safely. Pass -WorkspaceRoot explicitly. GitRoot=$GitRoot"
    }
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container) -or
        -not (Test-Path -LiteralPath $commonDirectory -PathType Container)) {
        throw "Unable to classify gitfile workspace safely. Pass -WorkspaceRoot explicitly. GitRoot=$GitRoot"
    }

    $superprojectRoot = if ($superprojectMetadata.Count -eq 1) { ([string]$superprojectMetadata[0]).Trim() } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($superprojectRoot)) {
        try {
            $superprojectRoot = Get-NormalizedPath -Path $superprojectRoot
        } catch {
            throw "Unable to classify gitfile workspace safely. Pass -WorkspaceRoot explicitly. GitRoot=$GitRoot"
        }
        if (-not (Test-Path -LiteralPath $superprojectRoot -PathType Container)) {
            throw "Unable to classify gitfile workspace safely. Pass -WorkspaceRoot explicitly. GitRoot=$GitRoot"
        }
        return 'submodule'
    }

    if ($gitDirectory.Equals($commonDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'independent'
    }
    return 'linked-worktree'
}

function Resolve-WorkspaceRoot {
    param(
        [string]$ExplicitWorkspaceRoot,
        [string]$RepoRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitWorkspaceRoot)) {
        return [pscustomobject]@{
            Path   = (Get-NormalizedPath -Path $ExplicitWorkspaceRoot)
            Source = 'explicit'
        }
    }

    foreach ($candidate in @($env:DEV_HARNESS_WORKSPACE_ROOT, $env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT, $env:WORKSPACE_ROOT)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return [pscustomobject]@{
                Path   = (Get-NormalizedPath -Path $candidate)
                Source = 'env'
            }
        }
    }

    $cwd = Get-NormalizedPath -Path (Get-Location).Path
    $assistantRoot = Find-AncestorContaining -StartPath $cwd -ChildName '.assistant' -RepoRoot $RepoRoot
    $gitRoot = Find-AncestorContaining -StartPath $cwd -ChildName '.git' -RepoRoot $RepoRoot

    # 取更近的 marker：
    # - 没有 .assistant 祖先时，git root 优先（fresh git bootstrap）。
    # - git root 是 .assistant 祖先的真子目录（更深）时，独立 repo 和 linked worktree 各自 bootstrap；
    #   submodule 继续属于父 workspace。gitfile 必须由 Git 的 git-dir/common-dir 成功分类，否则 fail closed。
    $gitRootKind = $null
    if (-not [string]::IsNullOrWhiteSpace($gitRoot)) {
        $gitMarker = Join-Path $gitRoot '.git'
        if (Test-Path -LiteralPath $gitMarker -PathType Container) {
            $gitRootKind = 'independent'
        } elseif (Test-Path -LiteralPath $gitMarker -PathType Leaf) {
            $gitRootKind = Get-GitFileWorkspaceKind -GitRoot $gitRoot
        } else {
            throw "Unable to classify git workspace safely. Pass -WorkspaceRoot explicitly. GitRoot=$gitRoot"
        }
    }
    $gitRootOwnsWorkspace = $gitRootKind -in @('independent','linked-worktree')
    $gitRootIsNearer = (-not [string]::IsNullOrWhiteSpace($gitRoot)) -and (
        [string]::IsNullOrWhiteSpace($assistantRoot) -or (
            $gitRootOwnsWorkspace -and
            (Test-PathWithinRoot -Path $gitRoot -Root $assistantRoot) -and
            -not $gitRoot.Equals($assistantRoot, [System.StringComparison]::OrdinalIgnoreCase)
        )
    )
    if ($gitRootIsNearer) {
        return [pscustomobject]@{
            Path   = $gitRoot
            Source = 'git-ancestor'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($assistantRoot)) {
        return [pscustomobject]@{
            Path   = $assistantRoot
            Source = 'assistant-ancestor'
        }
    }

    if (-not (Test-PathWithinRoot -Path $cwd -Root $RepoRoot)) {
        return [pscustomobject]@{
            Path   = $cwd
            Source = 'cwd'
        }
    }

    return $null
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    $RepoRoot = Get-NormalizedPath -Path $RepoRoot
    $workspaceInfo = Resolve-WorkspaceRoot -ExplicitWorkspaceRoot $WorkspaceRoot -RepoRoot $RepoRoot
    if ($null -eq $workspaceInfo -or [string]::IsNullOrWhiteSpace($workspaceInfo.Path)) {
        throw 'Unable to infer WorkspaceRoot. Run this command from the target project folder, or pass -WorkspaceRoot explicitly.'
    }

    $WorkspaceRoot = $workspaceInfo.Path
    $hadAssistant = Test-Path -LiteralPath (Join-Path $WorkspaceRoot '.assistant') -PathType Container
    $mode = if ($hadAssistant) { 'update-existing-workspace' } else { 'bootstrap-workspace' }

    $results = @()
    $updateResult = Invoke-Step -Name 'update-managed-assets.ps1' -ScriptPath (Join-Path $RepoRoot 'scripts\update-managed-assets.ps1') -Arguments @{
        WorkspaceRoot = $WorkspaceRoot
        RepoRoot      = $RepoRoot
    }
    $results += $updateResult

    $statusScriptPath = Join-Path $RepoRoot 'scripts\harness-status.ps1'
    if ($updateResult.Status -ne 'FAIL' -and -not $SkipStatus -and (Test-Path -LiteralPath $statusScriptPath -PathType Leaf)) {
        $statusResult = Invoke-Step -Name 'harness-status.ps1' -ScriptPath $statusScriptPath -Arguments @{
            WorkspaceRoot = $WorkspaceRoot
            RepoRoot      = $RepoRoot
        }
        $results += $statusResult
    }

    $overallStatus = Get-OverallStatus -Results $results

    Write-Output ("STATUS: {0}" -f $overallStatus)
    Write-Output ("Mode: {0}" -f $mode)
    Write-Output ("WorkspaceRoot: {0}" -f $WorkspaceRoot)
    Write-Output ("WorkspaceRootSource: {0}" -f $workspaceInfo.Source)
    Write-Output ("RepoRoot: {0}" -f $RepoRoot)
    Write-Output ''
    Write-Output 'Steps:'
    foreach ($result in $results) {
        Write-Output ("- {0}: {1}" -f $result.Name, $result.Status)
    }
    if ($SkipStatus -or -not (Test-Path -LiteralPath $statusScriptPath -PathType Leaf)) {
        Write-Output '- harness-status.ps1: SKIP'
    }
    Write-Output ''
    Write-Output 'Highlights:'
    foreach ($result in $results) {
        $highlights = @($result.Errors) + @($result.Warnings)
        if ($highlights.Count -eq 0) {
            $highlights = @($result.Highlights) + @($result.Next) + @($result.Checks)
        }

        if ($highlights.Count -eq 0) {
            Write-Output ("- {0}: none" -f $result.Name)
            continue
        }

        Write-Output ("- {0}: {1}" -f $result.Name, $highlights[0])
    }

    switch ($overallStatus) {
        'PASS' { exit 0 }
        'WARN' { exit 1 }
        default { exit 2 }
    }
} catch {
    Write-Output 'STATUS: FAIL'
    Write-Output ("Error: {0}" -f $_.Exception.Message)
    exit 2
}
