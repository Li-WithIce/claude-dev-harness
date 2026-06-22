# 校验 context-preflight helper 只输出 advisory 建议，不写入运行时或改变 normal miss exit code。
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-Check {
    param([string]$Message)

    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)

    $script:Failures += $Message
}

function Write-Utf8Bom {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($true)))
}

function Remove-DirectoryWithRetry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_
            Start-Sleep -Milliseconds 200
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Add-Failure ("cleanup failed for {0}: {1}" -f $Path, $lastError.Exception.Message)
    }
}

function Invoke-Preflight {
    param([string[]]$Arguments)

    $runnerCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    $runner = if ($null -ne $runnerCommand) {
        $runnerCommand.Source
    } else {
        'powershell.exe'
    }

    $output = @(& $runner -NoProfile -ExecutionPolicy Bypass -File $script:PreflightPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
        Text = ($output -join "`n")
    }
}

$sourceRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
} else {
    (Resolve-Path -LiteralPath $RepoRoot).Path
}
$script:PreflightPath = Join-Path $sourceRoot 'scripts\context-preflight.ps1'
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-context-preflight-' + [guid]::NewGuid().ToString('N'))

$script:Checks = @()
$script:Failures = @()

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

    $taskId = 'demo-context'
    $manifestPath = Join-Path $fixtureRoot "docs\tasks\$taskId\context-manifest.yaml"
    $targetPath = Join-Path $fixtureRoot 'docs\inputs\design.md'
    Write-Utf8Bom -Path $targetPath -Content "# Design`r`n"
    Write-Utf8Bom -Path $manifestPath -Content @"
schema_version: context-manifest/v1
summary: "Demo context manifest"
contexts:
  - phase: IMPLEMENT
    file: docs/inputs/design.md
    reason: "Read implementation design"
    required: true
    notes: "Primary input"
  - phase: TEST
    file: docs/inputs/test.md
    reason: "Read test notes"
    required: false
    notes: ""
"@

    $manifestHashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $targetHashBefore = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash

    $matchingResult = Invoke-Preflight -Arguments @('-TaskId', $taskId, '-Phase', 'IMPLEMENT', '-RepoRoot', $fixtureRoot)
    if ($matchingResult.ExitCode -eq 0 -and
        $matchingResult.Text -match 'STATUS: PASS' -and
        $matchingResult.Text -match 'Recommendations:' -and
        $matchingResult.Text -match 'docs/inputs/design.md' -and
        $matchingResult.Text -match 'Read implementation design' -and
        $matchingResult.Text -match 'Warnings:\s*\n- none') {
        Add-Check 'matching phase prints advisory recommendations'
    } else {
        Add-Failure ("matching phase should print recommendation without warnings, got: {0}" -f ($matchingResult.Output -join ' | '))
    }

    $manifestHashAfter = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $targetHashAfter = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
    if ($manifestHashBefore -eq $manifestHashAfter -and $targetHashBefore -eq $targetHashAfter) {
        Add-Check 'context-preflight does not modify manifest or suggested file'
    } else {
        Add-Failure 'context-preflight should not modify manifest or suggested file'
    }

    $missingManifestResult = Invoke-Preflight -Arguments @('-TaskId', 'missing-context', '-Phase', 'IMPLEMENT', '-RepoRoot', $fixtureRoot)
    if ($missingManifestResult.ExitCode -eq 0 -and
        $missingManifestResult.Text -match 'context-manifest.yaml is missing; advisory preflight skipped') {
        Add-Check 'missing manifest is advisory exit zero'
    } else {
        Add-Failure ("missing manifest should be advisory exit zero, got: {0}" -f ($missingManifestResult.Output -join ' | '))
    }

    $noPhaseResult = Invoke-Preflight -Arguments @('-TaskId', $taskId, '-Phase', 'CODE_REVIEW', '-RepoRoot', $fixtureRoot)
    if ($noPhaseResult.ExitCode -eq 0 -and
        $noPhaseResult.Text -match 'no matching phase entries found') {
        Add-Check 'no matching phase is advisory exit zero'
    } else {
        Add-Failure ("no matching phase should be advisory exit zero, got: {0}" -f ($noPhaseResult.Output -join ' | '))
    }

    $missingFileResult = Invoke-Preflight -Arguments @('-TaskId', $taskId, '-Phase', 'TEST', '-RepoRoot', $fixtureRoot)
    if ($missingFileResult.ExitCode -eq 0 -and
        $missingFileResult.Text -match 'missing suggested file: docs/inputs/test.md') {
        Add-Check 'missing suggested file is advisory exit zero'
    } else {
        Add-Failure ("missing suggested file should be advisory exit zero, got: {0}" -f ($missingFileResult.Output -join ' | '))
    }

    $missingTaskIdResult = Invoke-Preflight -Arguments @('-Phase', 'IMPLEMENT', '-RepoRoot', $fixtureRoot)
    if ($missingTaskIdResult.ExitCode -ne 0 -and
        $missingTaskIdResult.Text -match 'STATUS: FAIL' -and
        $missingTaskIdResult.Text -match 'TaskId is required') {
        Add-Check 'missing TaskId is invocation failure'
    } else {
        Add-Failure ("missing TaskId should fail invocation, got: {0}" -f ($missingTaskIdResult.Output -join ' | '))
    }
} finally {
    Remove-DirectoryWithRetry -Path $fixtureRoot
}

Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($check in $script:Checks) {
        Write-Output ("- {0}" -f $check)
    }
}

Write-Output ''
Write-Output 'Failures:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
    exit 0
}

foreach ($failure in $script:Failures) {
    Write-Output ("- {0}" -f $failure)
}

exit 1
