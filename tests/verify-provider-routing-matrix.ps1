# Verify provider routing matrix.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$content = Get-Content -LiteralPath (Join-Path $RepoRoot 'docs/工具/provider-routing-matrix.md') -Raw -Encoding utf8
$needles = @('Direct','Ask','Governed','Implementation','Policy-required review','Verification','advisory','not a new stage','context.ps1 recall/read')
$missing = @($needles | Where-Object { $content -notmatch [regex]::Escape($_) })
if ($missing.Count -gt 0) { $missing | ForEach-Object { Write-Output "- routing matrix missing $_" }; exit 1 }
Write-Output 'Provider routing matrix verified.'
