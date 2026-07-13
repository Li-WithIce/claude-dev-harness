# 校验 spec.md / plan.md paired reading HTML 生成器的结构增强契约。
[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Add-Check {
    param([string]$Message)

    $script:Checks += $Message
}

function Add-Failure {
    param([string]$Message)

    $script:Failures += $Message
}

function Assert-Contains {
    param(
        [string]$Content,
        [string]$Needle,
        [string]$Description
    )

    if ($Content.Contains($Needle)) {
        Add-Check $Description
    } else {
        Add-Failure ("missing {0}: {1}" -f $Description, $Needle)
    }
}

function Assert-NotContains {
    param(
        [string]$Content,
        [string]$Needle,
        [string]$Description
    )

    if ($Content.Contains($Needle)) {
        Add-Failure ("unexpected {0}: {1}" -f $Description, $Needle)
    } else {
        Add-Check $Description
    }
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

    throw $lastError
}

$script:Checks = @()
$script:Failures = @()
$repoRootCandidate = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { Join-Path $PSScriptRoot '..' } else { $RepoRoot }
$repoRootResolved = (Resolve-Path -LiteralPath $repoRootCandidate).Path
$renderer = Join-Path $repoRootResolved 'scripts\render-review-html.ps1'
$fixture = Join-Path $repoRootResolved 'tests\fixtures\md-html\long-spec.md'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-render-review-html-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $source = Join-Path $tempRoot 'spec.md'
    Copy-Item -LiteralPath $fixture -Destination $source

    $firstOutput = Join-Path $tempRoot 'spec.review.html'
    $secondOutput = Join-Path $tempRoot 'spec.second.review.html'
    & $renderer -Source $source -Output $firstOutput -RepoRoot $repoRootResolved | Out-Null
    & $renderer -Source $source -Output $secondOutput -RepoRoot $repoRootResolved | Out-Null

    $firstContent = Get-Content -LiteralPath $firstOutput -Raw -Encoding utf8
    $secondContent = Get-Content -LiteralPath $secondOutput -Raw -Encoding utf8

    Assert-Contains -Content $firstContent -Needle 'Generated paired reading HTML' -Description 'source-of-truth banner'
    Assert-Contains -Content $firstContent -Needle '<nav class="review-toc">' -Description 'TOC navigation'
    Assert-Contains -Content $firstContent -Needle 'href="#raw-h-2-3-decisions"' -Description 'stable H2 anchor in TOC'
    Assert-Contains -Content $firstContent -Needle '<details class="source-section" id="raw-h-2-3-decisions">' -Description 'H2 source section wrapper'
    Assert-Contains -Content $firstContent -Needle '<div class="table-scroll"><table>' -Description 'table scroll wrapper'
    Assert-Contains -Content $firstContent -Needle '<code class="language-powershell">' -Description 'code language class'
    Assert-Contains -Content $firstContent -Needle 'data-visual-block="summary"' -Description 'summary visual block'
    Assert-Contains -Content $firstContent -Needle 'data-visual-block="decision-grid"' -Description 'decision visual block'
    Assert-Contains -Content $firstContent -Needle 'data-visual-block="risk-grid"' -Description 'risk visual block'
    Assert-NotContains -Content $firstContent -Needle '<!doctype' -Description 'no doctype wrapper'
    Assert-NotContains -Content $firstContent -Needle '<html' -Description 'no html wrapper'
    Assert-NotContains -Content $firstContent -Needle '<head>' -Description 'no head wrapper'
    Assert-NotContains -Content $firstContent -Needle '<head ' -Description 'no head wrapper with attributes'
    Assert-NotContains -Content $firstContent -Needle '<body' -Description 'no body wrapper'
    Assert-NotContains -Content $firstContent -Needle '<script' -Description 'no script tag'
    Assert-NotContains -Content $firstContent -Needle '<iframe' -Description 'no iframe tag'
    Assert-NotContains -Content $firstContent -Needle ' src="' -Description 'no external script asset'

    if ($firstContent -eq $secondContent) {
        Add-Check 'repeatable output for the same source'
    } else {
        Add-Failure 'renderer output should be deterministic for the same source'
    }

    Copy-Item -LiteralPath $fixture -Destination (Join-Path $tempRoot 'plan.md')
    $ambiguousOutput = Join-Path $tempRoot 'review.html'
    $ambiguityFailed = $false
    try {
        & $renderer -Source $source -Output $ambiguousOutput -RepoRoot $repoRootResolved | Out-Null
    } catch {
        $ambiguityFailed = $_.Exception.Message -like '*review.html is ambiguous*'
    }

    if ($ambiguityFailed) {
        Add-Check 'review.html is rejected when spec.md and plan.md both exist'
    } else {
        Add-Failure 'review.html should be rejected when spec.md and plan.md both exist'
    }
} finally {
    Remove-DirectoryWithRetry -Path $tempRoot
}

if ($script:Failures.Count -gt 0) {
    Write-Output 'STATUS: FAIL'
} else {
    Write-Output 'STATUS: PASS'
}
Write-Output ("RepoRoot: {0}" -f $repoRootResolved)
Write-Output ''
Write-Output 'Checks:'
if ($script:Checks.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Checks) {
        Write-Output ("- {0}" -f $item)
    }
}
Write-Output ''
Write-Output 'Errors:'
if ($script:Failures.Count -eq 0) {
    Write-Output '- none'
} else {
    foreach ($item in $script:Failures) {
        Write-Output ("- {0}" -f $item)
    }
}

if ($script:Failures.Count -gt 0) {
    exit 2
}

exit 0
