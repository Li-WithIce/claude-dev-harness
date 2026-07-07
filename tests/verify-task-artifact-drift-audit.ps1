# Verify task artifact drift audit script.
[CmdletBinding()]
param([string]$RepoRoot = "")
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$failures = New-Object System.Collections.Generic.List[string]
$script = Join-Path $RepoRoot 'scripts/audit-task-artifact-drift.ps1'
if (-not (Test-Path -LiteralPath $script)) { $failures.Add('missing audit-task-artifact-drift.ps1') | Out-Null }
$text = Get-Content -LiteralPath $script -Raw -Encoding utf8
foreach ($needle in @('TaskDir','Mode','Advisory','Strict')) {
    if ($text -notmatch [regex]::Escape($needle)) { $failures.Add("artifact drift audit missing $needle") | Out-Null }
}
$output = @(& pwsh -NoProfile -NonInteractive -File $script -TaskDir 'missing-artifact-drift-dir' -Mode Advisory 2>&1)
if ($LASTEXITCODE -ne 0) { $failures.Add('artifact drift audit should not hard fail in Advisory mode') | Out-Null }
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Task artifact drift audit verified.'
