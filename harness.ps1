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

    if (@($Results | Where-Object { $_.Status -eq 'WARN' }).Count -gt 0) {
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

    foreach ($candidate in @($env:CLAUDE_DEV_HARNESS_WORKSPACE_ROOT, $env:WORKSPACE_ROOT)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return [pscustomobject]@{
                Path   = (Get-NormalizedPath -Path $candidate)
                Source = 'env'
            }
        }
    }

    $cwd = Get-NormalizedPath -Path (Get-Location).Path
    $assistantRoot = Find-AncestorContaining -StartPath $cwd -ChildName '.assistant' -RepoRoot $RepoRoot
    if (-not [string]::IsNullOrWhiteSpace($assistantRoot)) {
        return [pscustomobject]@{
            Path   = $assistantRoot
            Source = 'assistant-ancestor'
        }
    }

    $gitRoot = Find-AncestorContaining -StartPath $cwd -ChildName '.git' -RepoRoot $RepoRoot
    if (-not [string]::IsNullOrWhiteSpace($gitRoot)) {
        return [pscustomobject]@{
            Path   = $gitRoot
            Source = 'git-ancestor'
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
