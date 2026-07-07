# Verify context provider vNext guard.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$docPath = Join-Path $RepoRoot 'docs/实验/context-provider-vNext.md'
$content = Get-Content -LiteralPath $docPath -Raw -Encoding utf8
$needles = @('Do not add a new skill until','manifest','footprint','stage whitelist','profile','README inventory','skills/code-intel/SKILL.md','skills/memory-provider/SKILL.md')
$missing = @($needles | Where-Object { $content -notmatch [regex]::Escape($_) })
if ($missing.Count -gt 0) { $missing | ForEach-Object { Write-Output "- vNext missing $_" }; exit 1 }
if (Test-Path -LiteralPath (Join-Path $RepoRoot 'skills/code-intel')) { Write-Output '- skills/code-intel should not exist yet'; exit 1 }
if (Test-Path -LiteralPath (Join-Path $RepoRoot 'skills/memory-provider')) { Write-Output '- skills/memory-provider should not exist yet'; exit 1 }
Write-Output 'Context provider vNext guard verified.'
