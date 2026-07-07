# Verify providers are not installed or registered by harness scripts.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$failures = New-Object System.Collections.Generic.List[string]
$scriptPaths = @('install.ps1','harness.ps1','scripts/update-managed-assets.ps1','scripts/run-validation.ps1','uninstall.ps1')
$patterns = @('codegraph install','agentmemory connect','codedb mcp add','codedb mcp register','mcp add codedb','mcp register')
foreach ($path in $scriptPaths) {
    $full = Join-Path $RepoRoot $path
    if (-not (Test-Path -LiteralPath $full)) { $failures.Add("missing $path") | Out-Null; continue }
    $content = Get-Content -LiteralPath $full -Raw -Encoding utf8
    foreach ($pattern in $patterns) {
        if ($content.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $failures.Add("$path should not contain provider auto action: $pattern") | Out-Null
        }
    }
}
$boundary = Get-Content -LiteralPath (Join-Path $RepoRoot 'docs/工作流/context-provider-boundary.md') -Raw -Encoding utf8
if ($boundary -notmatch 'must not run `codegraph install`') { $failures.Add('boundary doc should forbid provider auto-install') | Out-Null }
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Context provider install isolation verified.'
