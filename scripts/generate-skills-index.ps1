[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskId,

    [Parameter(Mandatory = $true)]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [string]$BackendHint,

    [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Split-InlineYamlList {
    param([string]$Value)

    $normalized = $Value.Trim()
    if ($normalized -notmatch '^\[(.*)\]$') {
        throw "Unsupported inline YAML list: $Value"
    }

    $inner = $Matches[1].Trim()
    if ([string]::IsNullOrWhiteSpace($inner)) {
        return @()
    }

    $items = @()
    foreach ($item in ($inner -split ',')) {
        $trimmed = $item.Trim().Trim('"').Trim("'")
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $items += $trimmed
        }
    }

    return $items
}

function Get-WorkflowDescriptor {
    param([string]$RepoRoot)

    $descriptorPath = Join-Path (Join-Path $RepoRoot 'agent-configs\workflows') 'harness-lite.yaml'
    if (-not (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        throw "Missing workflow descriptor: $descriptorPath"
    }

    $descriptor = [ordered]@{
        Stages = [ordered]@{}
    }
    $currentStage = ''
    foreach ($line in (Get-Content -LiteralPath $descriptorPath -Encoding utf8)) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -match '^\s{2}([A-Z_]+):\s*$') {
            $currentStage = $Matches[1]
            $descriptor.Stages[$currentStage] = [ordered]@{
                SkillsWhitelist = @()
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($currentStage)) {
            continue
        }

        if ($line -match '^\s{4}skills_whitelist:\s*(.+?)\s*$') {
            $descriptor.Stages[$currentStage]['SkillsWhitelist'] = @(Split-InlineYamlList -Value $Matches[1])
        }
    }

    return [pscustomobject]$descriptor
}

function Get-SkillDescription {
    param(
        [string]$RepoRoot,
        [string]$SkillName
    )

    $skillPath = Join-Path (Join-Path (Join-Path $RepoRoot 'skills') $SkillName) 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        return 'description unavailable'
    }

    $lines = Get-Content -LiteralPath $skillPath -Encoding utf8
    $insideFrontmatter = $false
    $frontmatterCount = 0
    foreach ($line in $lines) {
        if ($line -eq '---') {
            $frontmatterCount++
            if ($frontmatterCount -eq 1) {
                $insideFrontmatter = $true
                continue
            }

            break
        }

        if ($insideFrontmatter -and $line -match '^description:\s*(.+?)\s*$') {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return 'description unavailable'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $repoRoot ("docs/tasks/{0}/skills-index.md" -f $TaskId)
} else {
    [System.IO.Path]::GetFullPath($OutputPath)
}

$descriptor = Get-WorkflowDescriptor -RepoRoot $repoRoot
if (-not $descriptor.Stages.Contains($Stage)) {
    throw "Workflow descriptor does not define stage: $Stage"
}

$skills = @($descriptor.Stages[$Stage]['SkillsWhitelist'])
$lines = @()
$lines += "<!-- generated at $((Get-Date).ToUniversalTime().ToString('o')) -->"
$lines += "# Skills available at $Stage (backend hint: $BackendHint)"
$lines += ''
foreach ($skillName in $skills) {
    $description = Get-SkillDescription -RepoRoot $repoRoot -SkillName $skillName
    $lines += "- **$skillName** — $description"
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

Write-Utf8NoBom -Path $resolvedOutputPath -Content ($lines -join "`n")
Write-Output $resolvedOutputPath
