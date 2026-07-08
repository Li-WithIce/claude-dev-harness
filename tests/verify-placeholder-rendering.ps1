[CmdletBinding()]
param([string]$RepoRoot = "")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$failures = New-Object System.Collections.Generic.List[string]

function Test-ScopedPath {
    param([string]$Path)

    $normalized = $Path -replace '\\', '/'
    $extension = [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()

    if ($normalized -eq 'README.md' -or $normalized -eq 'CONTRIBUTING.md' -or $normalized -eq 'CHANGELOG.md') {
        return $true
    }

    if ($normalized.StartsWith('docs/tasks/')) {
        return $normalized -eq 'docs/tasks/README.md'
    }

    if ($normalized.StartsWith('docs/')) {
        return $extension -eq '.md'
    }

    if ($normalized.StartsWith('skills/')) {
        return $extension -eq '.md'
    }

    if ($normalized.StartsWith('agent-configs/')) {
        return @('.md', '.template') -contains $extension
    }

    if ($normalized.StartsWith('vault-template/')) {
        return @('.md', '.template') -contains $extension
    }

    return $false
}

function Add-Failure {
    param(
        [string]$Path,
        [int]$LineNumber,
        [string]$Reason,
        [string]$Line
    )

    $failures.Add(('{0}:{1}: {2}: {3}' -f $Path, $LineNumber, $Reason, $Line.Trim())) | Out-Null
}

function Test-Line {
    param(
        [string]$Path,
        [int]$LineNumber,
        [string]$Line
    )

    if ([regex]::IsMatch($Line, 'docs[\\/]tasks[\\/]{2,}')) {
        Add-Failure -Path $Path -LineNumber $LineNumber -Reason 'double slash after docs/tasks' -Line $Line
    }

    if ([regex]::IsMatch($Line, 'docs[\\/]tasks[\\/]`?<(?:task-id|task_id|id)>`?')) {
        Add-Failure -Path $Path -LineNumber $LineNumber -Reason 'angle-bracket task path placeholder' -Line $Line
    }

    if ([regex]::IsMatch($Line, '-TaskId\s+`?<(?:task-id|task_id|id)>`?')) {
        Add-Failure -Path $Path -LineNumber $LineNumber -Reason 'angle-bracket TaskId placeholder' -Line $Line
    }

    $trimmed = $Line.TrimEnd()
    if ([regex]::IsMatch($trimmed, '(?:^|[\s`])-TaskId\s*$')) {
        Add-Failure -Path $Path -LineNumber $LineNumber -Reason 'bare TaskId argument' -Line $Line
    }

    if ([regex]::IsMatch($trimmed, '(?:^|[\s`])-TaskId\s+(?:#|```|`$)')) {
        Add-Failure -Path $Path -LineNumber $LineNumber -Reason 'TaskId argument without a value' -Line $Line
    }

    if ([regex]::IsMatch($trimmed, '(?:^|[\s`])-TaskId\s+-[A-Za-z]')) {
        Add-Failure -Path $Path -LineNumber $LineNumber -Reason 'TaskId argument followed by another switch' -Line $Line
    }
}

$trackedFiles = @(& git -C $RepoRoot ls-files 2>$null | ForEach-Object { [string]$_ })
if ($LASTEXITCODE -ne 0) {
    throw "git ls-files failed"
}

foreach ($path in ($trackedFiles | Where-Object { Test-ScopedPath -Path $_ } | Sort-Object -Unique)) {
    $fullPath = Join-Path $RepoRoot $path
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $fullPath -Encoding utf8) {
        $lineNumber += 1
        Test-Line -Path $path -LineNumber $lineNumber -Line $line
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "- $_" }
    exit 1
}

Write-Output 'Placeholder rendering verified.'
