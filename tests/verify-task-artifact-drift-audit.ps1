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
if ($text -notmatch [regex]::Escape('affected_paths should describe implementation paths')) { $failures.Add('artifact drift audit missing affected_paths warning') | Out-Null }

$tempTaskRoot = Join-Path $RepoRoot ('.tmp-artifact-drift-test-' + [guid]::NewGuid().ToString('N'))
Push-Location $RepoRoot
try {
    $output = @(& pwsh -NoProfile -NonInteractive -File $script -TaskDir 'missing-artifact-drift-dir' -Mode Advisory 2>&1)
    if ($LASTEXITCODE -ne 0) { $failures.Add('artifact drift audit should not hard fail in Advisory mode') | Out-Null }

    $taskDir = Join-Path $tempTaskRoot 'demo'
    New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
    Set-Content -LiteralPath (Join-Path $taskDir 'plan.md') -Encoding utf8 -Value @'
# Demo

## Change Contract
- change_type: enhance
- affected_paths:
  - docs/tasks/demo/plan.md

## Plan
- artifacts: [README.md]
- Demo task.
'@
    $relativeTemp = Split-Path -Leaf $tempTaskRoot
    $output = @(& pwsh -NoProfile -NonInteractive -File $script -TaskDir $relativeTemp -Mode Advisory 2>&1)
    if ($LASTEXITCODE -ne 0) { $failures.Add('artifact drift audit affected_paths warning should remain advisory') | Out-Null }
    if (($output -join "`n") -notmatch [regex]::Escape('affected_paths should describe implementation paths')) {
        $failures.Add('artifact drift audit did not warn on docs/tasks affected_paths') | Out-Null
    }
} finally {
    try { Pop-Location }
    finally {
        if (Test-Path -LiteralPath $tempTaskRoot) { Remove-Item -LiteralPath $tempTaskRoot -Recurse -Force }
    }
}
if ($failures.Count -gt 0) { $failures | ForEach-Object { Write-Output "- $_" }; exit 1 }
Write-Output 'Task artifact drift audit verified.'
