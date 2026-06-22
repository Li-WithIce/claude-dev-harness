[CmdletBinding()]
param(
    [string]$TaskId = '',
    [string]$Phase = '',
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-InvocationFailure {
    param([string]$Message)

    Write-Output 'STATUS: FAIL'
    Write-Output 'Errors:'
    Write-Output ("- {0}" -f $Message)
    exit 2
}

function Resolve-RepoRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        if (-not (Test-Path -LiteralPath $RequestedRoot -PathType Container)) {
            Write-InvocationFailure -Message ("RepoRoot does not exist: {0}" -f $RequestedRoot)
        }

        return (Resolve-Path -LiteralPath $RequestedRoot).Path
    }

    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Normalize-RepoRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $normalized = $Path.Trim().Trim('"').Trim("'") -replace '\\', '/'
    while ($normalized.StartsWith('./')) {
        $normalized = $normalized.Substring(2)
    }

    return $normalized.TrimStart('/')
}

function Read-YamlScalar {
    param([string]$Value)

    $trimmed = $Value.Trim()
    if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or
        ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
        return $trimmed.Substring(1, [Math]::Max(0, $trimmed.Length - 2))
    }

    return $trimmed
}

function Convert-ContextEntry {
    param([hashtable]$Entry)

    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($Entry['Phase'])) {
        return $null
    }

    return [pscustomobject]@{
        Phase = [string]$Entry['Phase']
        File = Normalize-RepoRelativePath -Path ([string]$Entry['File'])
        Reason = [string]$Entry['Reason']
        Required = [string]$Entry['Required']
        Notes = [string]$Entry['Notes']
    }
}

function Read-ContextManifest {
    param([string]$ManifestPath)

    $entries = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in (Get-Content -LiteralPath $ManifestPath -Encoding utf8)) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^\s*-\s*phase:\s*(.*?)\s*$') {
            $converted = Convert-ContextEntry -Entry $current
            if ($null -ne $converted) {
                [void]$entries.Add($converted)
            }

            $current = @{
                Phase = Read-YamlScalar -Value $Matches[1]
                File = ''
                Reason = ''
                Required = ''
                Notes = ''
            }
            continue
        }

        if ($null -eq $current) {
            continue
        }

        if ($line -match '^\s+(file|reason|required|notes):\s*(.*?)\s*$') {
            $key = (Get-Culture).TextInfo.ToTitleCase($Matches[1])
            $current[$key] = Read-YamlScalar -Value $Matches[2]
        }
    }

    $last = Convert-ContextEntry -Entry $current
    if ($null -ne $last) {
        [void]$entries.Add($last)
    }

    return @($entries.ToArray())
}

if ([string]::IsNullOrWhiteSpace($TaskId)) {
    Write-InvocationFailure -Message 'TaskId is required'
}

if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    Write-InvocationFailure -Message ("TaskId is not a safe task directory name: {0}" -f $TaskId)
}

if ([string]::IsNullOrWhiteSpace($Phase)) {
    Write-InvocationFailure -Message 'Phase is required'
}

if ($Phase -notmatch '^[A-Za-z0-9_:-]+$') {
    Write-InvocationFailure -Message ("Phase contains unsupported characters: {0}" -f $Phase)
}

$repoRootResolved = Resolve-RepoRoot -RequestedRoot $RepoRoot
$manifestPath = Join-Path (Join-Path (Join-Path $repoRootResolved 'docs\tasks') $TaskId) 'context-manifest.yaml'
$phaseNormalized = $Phase.Trim().ToUpperInvariant()
$warnings = New-Object System.Collections.Generic.List[string]
$recommendations = @()

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $entries = @(Read-ContextManifest -ManifestPath $manifestPath)
    $recommendations = @($entries | Where-Object { $_.Phase.Trim().ToUpperInvariant() -eq $phaseNormalized })

    if ($recommendations.Count -eq 0) {
        [void]$warnings.Add(("no matching phase entries found in context-manifest.yaml for phase: {0}" -f $Phase))
    }

    foreach ($entry in $recommendations) {
        if ([string]::IsNullOrWhiteSpace($entry.File)) {
            [void]$warnings.Add(("context entry for phase {0} has an empty file" -f $entry.Phase))
            continue
        }

        $candidate = Join-Path $repoRootResolved ($entry.File -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            [void]$warnings.Add(("missing suggested file: {0}" -f $entry.File))
        }
    }
} else {
    [void]$warnings.Add('context-manifest.yaml is missing; advisory preflight skipped')
}

Write-Output 'STATUS: PASS'
Write-Output ("TaskId: {0}" -f $TaskId)
Write-Output ("Phase: {0}" -f $Phase)
Write-Output ("Manifest: {0}" -f $manifestPath)
Write-Output 'Mode: advisory-only; this command does not call advance-stage, change skills_whitelist, or inject context.'
Write-Output ''
Write-Output 'Recommendations:'
if ($recommendations.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($entry in $recommendations) {
        Write-Output ("- file: {0}" -f $entry.File)
        Write-Output ("  required: {0}" -f $entry.Required)
        Write-Output ("  reason: {0}" -f $entry.Reason)
        Write-Output ("  notes: {0}" -f $entry.Notes)
    }
}

Write-Output ''
Write-Output 'Warnings:'
if ($warnings.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($warning in $warnings) {
        Write-Output ("- {0}" -f $warning)
    }
}

exit 0
