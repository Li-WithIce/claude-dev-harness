[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$beginMarker = '<!-- BEGIN GENERATED ENTRY CONTRACT -->'
$endMarker = '<!-- END GENERATED ENTRY CONTRACT -->'
$sourceRelativePath = 'policies/entry-contract.md'
$targetRelativePaths = @(
    'agent-configs/workspace/AGENTS.md.template',
    'agent-configs/claude/CLAUDE.md.template',
    'vault-template/entry/AGENTS.md.template'
)
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function ConvertTo-Lf {
    param([string]$Text)

    return ($Text -replace "`r`n?", "`n")
}

function Read-Utf8File {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
    return [pscustomobject]@{
        Bytes = $bytes
        HasBom = $hasBom
        Text = $text
    }
}

function Test-BytesEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

$resolvedRepoRoot = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoRoot).Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$rootPrefix = $resolvedRepoRoot + [System.IO.Path]::DirectorySeparatorChar
$sourcePath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot $sourceRelativePath))
if (-not $sourcePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Canonical entry contract is missing or outside RepoRoot: $sourceRelativePath"
}

$sourceState = Read-Utf8File -Path $sourcePath
if ($sourceState.HasBom) {
    throw "Canonical entry contract must be UTF-8 without BOM: $sourceRelativePath"
}
$sourceBody = (ConvertTo-Lf -Text $sourceState.Text).TrimEnd([char[]]"`r`n")
if ([string]::IsNullOrWhiteSpace($sourceBody)) {
    throw "Canonical entry contract is empty: $sourceRelativePath"
}
foreach ($reservedMarker in @($beginMarker, $endMarker, '<!-- source-sha256:')) {
    if ($sourceBody.Contains($reservedMarker, [System.StringComparison]::Ordinal)) {
        throw "Canonical entry contract contains a reserved generated marker: $reservedMarker"
    }
}
$sourceBytes = $utf8NoBom.GetBytes($sourceBody + "`n")
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $sourceHash = ([System.BitConverter]::ToString($sha256.ComputeHash($sourceBytes))).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha256.Dispose()
}
$generatedBody = "<!-- source-sha256: $sourceHash -->`n$sourceBody"

$plans = @()
foreach ($relativePath in $targetRelativePaths) {
    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot $relativePath))
    if (-not $targetPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        throw "Allowlisted entry template is missing or outside RepoRoot: $relativePath"
    }

    $state = Read-Utf8File -Path $targetPath
    $text = ConvertTo-Lf -Text $state.Text
    $beginMatches = [regex]::Matches($text, [regex]::Escape($beginMarker))
    $endMatches = [regex]::Matches($text, [regex]::Escape($endMarker))
    if ($beginMatches.Count -ne 1 -or $endMatches.Count -ne 1 -or $endMatches[0].Index -le $beginMatches[0].Index) {
        throw "Entry template must contain one ordered marker pair: $relativePath"
    }

    $before = $text.Substring(0, $beginMatches[0].Index + $beginMarker.Length)
    $after = $text.Substring($endMatches[0].Index)
    $desiredText = ($before + "`n" + $generatedBody + "`n" + $after).TrimEnd([char[]]"`r`n") + "`n"
    $desiredBytes = $utf8NoBom.GetBytes($desiredText)
    $plans += [pscustomobject]@{
        RelativePath = $relativePath
        Path = $targetPath
        OriginalBytes = $state.Bytes
        DesiredText = $desiredText
        DesiredBytes = $desiredBytes
        IsCurrent = (Test-BytesEqual -Left $state.Bytes -Right $desiredBytes)
    }
}

$drifted = @($plans | Where-Object { -not $_.IsCurrent })
if ($Check) {
    if ($drifted.Count -gt 0) {
        throw ("Generated entry contract drift: " + (($drifted | ForEach-Object { $_.RelativePath }) -join ', '))
    }
    Write-Host ("STATUS: PASS ({0} allowlisted templates are current)" -f $plans.Count)
    exit 0
}

foreach ($plan in $plans) {
    $currentBytes = [System.IO.File]::ReadAllBytes($plan.Path)
    if (-not (Test-BytesEqual -Left $currentBytes -Right $plan.OriginalBytes)) {
        throw "Entry template changed during generation; no files were written: $($plan.RelativePath)"
    }
}

$testFailAfterReplace = 0
$testFaultValue = [string]$env:DEV_HARNESS_TEST_ENTRY_CONTRACT_FAIL_AFTER_REPLACE
if (-not [string]::IsNullOrWhiteSpace($testFaultValue)) {
    if (-not [int]::TryParse($testFaultValue, [ref]$testFailAfterReplace) -or $testFailAfterReplace -lt 1) {
        throw 'DEV_HARNESS_TEST_ENTRY_CONTRACT_FAIL_AFTER_REPLACE must be a positive integer'
    }
}

$operationId = [guid]::NewGuid().ToString('N')
$prepared = [System.Collections.Generic.List[object]]::new()
$published = [System.Collections.Generic.List[object]]::new()
$keepRecoveryBackups = $false
try {
    foreach ($plan in $drifted) {
        $directory = Split-Path -Parent $plan.Path
        $leaf = Split-Path -Leaf $plan.Path
        $tempPath = Join-Path $directory ('.{0}.{1}.entry-contract.tmp' -f $leaf, $operationId)
        $backupPath = Join-Path $directory ('.{0}.{1}.entry-contract.bak' -f $leaf, $operationId)
        $rollbackDiscardPath = Join-Path $directory ('.{0}.{1}.entry-contract.rollback' -f $leaf, $operationId)
        [System.IO.File]::WriteAllBytes($tempPath, $plan.DesiredBytes)
        $stagedBytes = [System.IO.File]::ReadAllBytes($tempPath)
        if (-not (Test-BytesEqual -Left $stagedBytes -Right $plan.DesiredBytes)) {
            throw "Staged entry template verification failed before publish: $($plan.RelativePath)"
        }
        $prepared.Add([pscustomobject]@{
            Plan = $plan
            TempPath = $tempPath
            BackupPath = $backupPath
            RollbackDiscardPath = $rollbackDiscardPath
        })
    }

    foreach ($item in $prepared) {
        $currentBytes = [System.IO.File]::ReadAllBytes($item.Plan.Path)
        if (-not (Test-BytesEqual -Left $currentBytes -Right $item.Plan.OriginalBytes)) {
            throw "Entry template changed before atomic publish: $($item.Plan.RelativePath)"
        }
        [System.IO.File]::Replace($item.TempPath, $item.Plan.Path, $item.BackupPath, $true)
        $published.Add($item)
        if ($testFailAfterReplace -eq $published.Count) {
            throw ("Injected entry-contract publish failure after {0} replacement(s)" -f $published.Count)
        }
    }
}
catch {
    $publishFailure = $_.Exception.Message
    $rollbackFailures = [System.Collections.Generic.List[string]]::new()
    for ($index = $published.Count - 1; $index -ge 0; $index--) {
        $item = $published[$index]
        try {
            if (-not (Test-Path -LiteralPath $item.BackupPath -PathType Leaf)) {
                throw 'atomic backup is missing'
            }
            [System.IO.File]::Replace($item.BackupPath, $item.Plan.Path, $item.RollbackDiscardPath, $true)
            $restoredBytes = [System.IO.File]::ReadAllBytes($item.Plan.Path)
            if (-not (Test-BytesEqual -Left $restoredBytes -Right $item.Plan.OriginalBytes)) {
                throw 'restored bytes do not match the pre-publish snapshot'
            }
            [System.IO.File]::Delete($item.RollbackDiscardPath)
        }
        catch {
            $rollbackFailures.Add(("{0}: {1}" -f $item.Plan.RelativePath, $_.Exception.Message))
        }
    }
    if ($rollbackFailures.Count -gt 0) {
        $keepRecoveryBackups = $true
        throw ("Entry contract publish failed ({0}); rollback also failed ({1}). Recovery backups were retained." -f $publishFailure, ($rollbackFailures -join '; '))
    }
    throw ("Entry contract publish failed; all published targets were rolled back: {0}" -f $publishFailure)
}
finally {
    foreach ($item in $prepared) {
        if (Test-Path -LiteralPath $item.TempPath -PathType Leaf) {
            [System.IO.File]::Delete($item.TempPath)
        }
        if (-not $keepRecoveryBackups -and (Test-Path -LiteralPath $item.BackupPath -PathType Leaf)) {
            [System.IO.File]::Delete($item.BackupPath)
        }
        if (-not $keepRecoveryBackups -and (Test-Path -LiteralPath $item.RollbackDiscardPath -PathType Leaf)) {
            [System.IO.File]::Delete($item.RollbackDiscardPath)
        }
    }
}

Write-Host ("STATUS: PASS ({0} updated, {1} already current)" -f $drifted.Count, ($plans.Count - $drifted.Count))
