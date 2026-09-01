param(
    [Parameter(Mandatory = $true)]
    [string]$VaultRoot,
    [string]$RepoRoot = '',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Join-Path $PSScriptRoot '..') 'skills\obsidian-memory\scripts\resolve-shared-memory-paths.ps1')

$script:Checks = @()
$script:Warnings = @()
$script:Errors = @()

function Add-Check {
    param([string]$Message)
    $script:Checks += $Message
}

function Add-Warning {
    param([string]$Message)
    $script:Warnings += $Message
}

function Add-Error {
    param([string]$Message)
    $script:Errors += $Message
}

function Get-YamlField {
    param(
        [string]$Path,
        [string]$Field
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $pattern = '^{0}:\s*(.+)$' -f [regex]::Escape($Field)
    $match = Select-String -LiteralPath $Path -Pattern $pattern -Encoding utf8 | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-InlineArrayValues {
    param(
        [string]$Path,
        [string]$Field
    )

    $rawValue = Get-YamlField -Path $Path -Field $Field
    if ([string]::IsNullOrWhiteSpace($rawValue)) {
        return @()
    }

    $trimmedValue = $rawValue.Trim()
    if (-not ($trimmedValue.StartsWith('[') -and $trimmedValue.EndsWith(']'))) {
        return @()
    }

    $inner = $trimmedValue.Substring(1, $trimmedValue.Length - 2)
    if ([string]::IsNullOrWhiteSpace($inner)) {
        return @()
    }

    return @(
        $inner.Split(',') |
            ForEach-Object { $_.Trim().Trim('"', '''', '`') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Test-HasConcreteArrayValue {
    param([string[]]$Values)

    foreach ($value in @($Values)) {
        if ($value -and $value -notmatch '^\s*<.+>\s*$') {
            return $true
        }
    }

    return $false
}

function Assert-RequiredSection {
    param(
        [string]$Path,
        [string]$Section
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Error ("missing file: {0}" -f $Path)
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ($content -match ("(?m)^{0}\s*$" -f [regex]::Escape($Section))) {
        Add-Check ("section present: {0} -> {1}" -f (Split-Path -Leaf $Path), $Section)
    } else {
        Add-Error ("{0} missing required section: {1}" -f $Path, $Section)
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
} else {
    $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
}

$VaultRoot = Resolve-SharedMemoryVaultRoot -VaultRoot $VaultRoot
try {
    $hasHistory = Test-LegacyMemoryHistoryPresent -VaultRoot $VaultRoot
} catch {
    if ($Json) {
        [ordered]@{status='FAIL';scope='historical-v1-only';checks=@();warnings=@();errors=@('invalid or unavailable historical boundary')} | ConvertTo-Json -Compress
    } else {
        Write-Output 'STATUS: FAIL'
        Write-Output 'Scope: historical-v1-only'
        Write-Output 'Reason: invalid or unavailable historical boundary.'
    }
    exit 1
}
if (-not $hasHistory) {
    if ($Json) {
        [ordered]@{status='NOT_APPLICABLE';scope='historical-v1-only';checks=@();warnings=@();errors=@()} | ConvertTo-Json -Compress
    } else {
        Write-Output 'STATUS: NOT_APPLICABLE'
        Write-Output 'Scope: historical-v1-only'
        Write-Output 'Reason: no retained v1 mirrors; v2 Runtime health was not checked.'
    }
    exit 0
}
try {
    $null = Assert-ProjectLocalVault -VaultRoot $VaultRoot
} catch {
    Add-Error $_.Exception.Message
}

$layersDocPath = Join-Path $RepoRoot 'docs\shared-memory-layers.md'
$protocolPath = Join-Path $VaultRoot '工作流\共享记忆协议.md'
$currentTaskPath = Join-Path $VaultRoot '运行时\当前任务.md'
$recoveryIndexPath = Join-Path $VaultRoot '运行时\恢复索引.md'
$interruptedPath = Join-Path $VaultRoot '运行时\中断任务.md'
$lockPath = Join-Path $VaultRoot '运行时\runtime.lock.json'

foreach ($section in @('## Layers', '## Writeback Ladder', '## Forbidden Reverse Edges')) {
    Assert-RequiredSection -Path $layersDocPath -Section $section
}

if (Test-Path -LiteralPath $protocolPath -PathType Leaf) {
    $protocolContent = Get-Content -LiteralPath $protocolPath -Raw -Encoding utf8
    if ($protocolContent.Contains('docs/shared-memory-layers.md')) {
        Add-Check '共享记忆协议引用了 docs/shared-memory-layers.md'
    } else {
        Add-Error ('共享记忆协议缺少对 docs/shared-memory-layers.md 的引用: {0}' -f $protocolPath)
    }
} else {
    Add-Error ('missing file: {0}' -f $protocolPath)
}

if (Test-Path -LiteralPath $currentTaskPath -PathType Leaf) {
    $entryHost = Get-YamlField -Path $currentTaskPath -Field 'entry_host'
    if ([string]::IsNullOrWhiteSpace($entryHost)) {
        Add-Warning ('当前任务缺少 entry_host，按 legacy fallback 处理: {0}' -f $currentTaskPath)
    } else {
        Add-Check ('当前任务 entry_host={0}' -f $entryHost)
    }
} else {
    Add-Error ('missing file: {0}' -f $currentTaskPath)
}

foreach ($target in @(
        @{ Path = $recoveryIndexPath; Label = '恢复索引' },
        @{ Path = $interruptedPath; Label = '中断任务' }
    )) {
    if (-not (Test-Path -LiteralPath $target.Path -PathType Leaf)) {
        Add-Error ('missing file: {0}' -f $target.Path)
        continue
    }

    $derivedFrom = Get-InlineArrayValues -Path $target.Path -Field 'derived_from'
    if (Test-HasConcreteArrayValue -Values $derivedFrom) {
        Add-Check ('{0} derived_from={1}' -f $target.Label, ($derivedFrom -join ', '))
    } else {
        Add-Error ('{0} 缺少可用 derived_from: {1}' -f $target.Label, $target.Path)
    }
}

if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
    try {
        $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding utf8 | ConvertFrom-Json
        $missingFields = @()
        foreach ($field in @('writer', 'task_id', 'locked_at', 'entry_host')) {
            if ($null -eq $lock.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$lock.$field)) {
                $missingFields += $field
            }
        }

        if ($missingFields.Count -eq 0) {
            Add-Check 'runtime.lock.json schema is complete'
        } else {
            Add-Error ('runtime.lock.json missing field(s): {0}' -f ($missingFields -join ', '))
        }
    } catch {
        Add-Error ('runtime.lock.json is malformed: {0}' -f $_.Exception.Message)
    }
}

$status = if ($script:Errors.Count -gt 0) {
    'FAIL'
} elseif ($script:Warnings.Count -gt 0) {
    'WARN'
} else {
    'PASS'
}

if ($Json) {
    $payload = [ordered]@{
        status   = $status
        scope    = 'historical-v1-only'
        repoRoot = $RepoRoot
        vaultRoot = $VaultRoot
        checks   = @($script:Checks)
        warnings = @($script:Warnings)
        errors   = @($script:Errors)
    }

    Write-Output ($payload | ConvertTo-Json -Depth 4 -Compress)
} else {
    Write-Output ('STATUS: {0}' -f $status)
    Write-Output 'Scope: historical-v1-only'
    Write-Output ('RepoRoot: {0}' -f $RepoRoot)
    Write-Output ('VaultRoot: {0}' -f $VaultRoot)
    Write-Output ''
    Write-Output 'Checks:'
    if ($script:Checks.Count -eq 0) {
        Write-Output '- none'
    } else {
        foreach ($item in $script:Checks) {
            Write-Output ('- {0}' -f $item)
        }
    }
    Write-Output ''
    Write-Output 'Warnings:'
    if ($script:Warnings.Count -eq 0) {
        Write-Output '- none'
    } else {
        foreach ($item in $script:Warnings) {
            Write-Output ('- {0}' -f $item)
        }
    }
    Write-Output ''
    Write-Output 'Errors:'
    if ($script:Errors.Count -eq 0) {
        Write-Output '- none'
    } else {
        foreach ($item in $script:Errors) {
            Write-Output ('- {0}' -f $item)
        }
    }
}

if ($script:Errors.Count -gt 0) {
    exit 1
}

exit 0
