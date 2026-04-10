[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace).Path
$geminiMdPath = Join-Path $resolvedWorkspace "GEMINI.md"
$created = $false

if (-not (Test-Path -LiteralPath $geminiMdPath) -or $Force) {
    $content = @"
# GEMINI.md

## Project Overview
- Describe the repository goal here.

## Working Rules
- Prefer small, reviewable changes.
- Reuse existing patterns before introducing new abstractions.
- Ask before destructive commands or broad refactors.

## Common Commands
- Install:
- Test:
- Lint:
- Build:

## Validation
- Run focused checks for changed code before finishing.
- Call out risks, assumptions, and follow-up verification.

## Boundaries
- Files or directories that should be treated carefully:
- Areas that require explicit approval:
"@
    Set-Content -Path $geminiMdPath -Value $content -Encoding UTF8
    $created = $true
}

[pscustomobject]@{
    workspace = $resolvedWorkspace
    gemini_md_path = $geminiMdPath
    created = $created
} | ConvertTo-Json -Depth 5
