# Verify experimental provider docs.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$failures = New-Object System.Collections.Generic.List[string]
$doc = Get-Content -LiteralPath (Join-Path $RepoRoot 'docs/实验/codedb-mcp-provider.md') -Raw -Encoding utf8
foreach ($needle in @('experimental','disabled','no vendor','license','no auto-register','advisory-only')) {
    if ($doc -notmatch [regex]::Escape($needle)) { $failures.Add("codedb doc missing $needle") | Out-Null }
}
if ((Get-Content -LiteralPath (Join-Path $RepoRoot '.gitignore') -Raw -Encoding utf8) -notmatch [regex]::Escape('/.codedb-mcp/')) { $failures.Add('.gitignore should ignore .codedb-mcp') | Out-Null }
$workflow = Get-Content -LiteralPath (Join-Path $RepoRoot 'agent-configs/workflows/harness-lite.yaml') -Raw -Encoding utf8
if ($workflow -match 'codedb') { $failures.Add('codedb should not enter workflow descriptor') | Out-Null }
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Experimental provider docs verified.'
