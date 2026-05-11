# 校验 paired reading HTML 生成器是否真正做结构重组，而不是普通 Markdown 渲染。
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
        [string]$Message
    )

    if ($Content.Contains($Needle)) {
        Add-Check $Message
    } else {
        Add-Failure ("missing expected output: {0}" -f $Needle)
    }
}

function Assert-NotMatches {
    param(
        [string]$Content,
        [string]$Pattern,
        [string]$Message
    )

    if ($Content -match $Pattern) {
        Add-Failure ('forbidden output matched {0}' -f $Pattern)
    } else {
        Add-Check $Message
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$script:RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$script:Checks = @()
$script:Failures = @()

$sourcePath = Join-Path $script:RepoRoot 'tests\fixtures\md-html\long-spec.md'
$outputRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-md-html-' + [guid]::NewGuid().ToString('N'))
$outputPath = Join-Path $outputRoot 'review.html'
New-Item -ItemType Directory -Path $outputRoot | Out-Null

try {
    & (Join-Path $script:RepoRoot 'scripts\render-review-html.ps1') -SourcePath $sourcePath -OutputPath $outputPath -Force | Out-Null
    if ((Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) -and $LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) {
        Add-Failure ("render-review-html.ps1 exited with {0}" -f $LASTEXITCODE)
    }

    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        Add-Check 'review.html was generated'
    } else {
        Add-Failure 'review.html should be generated'
    }

    $content = Get-Content -LiteralPath $outputPath -Raw -Encoding utf8

    Assert-Contains -Content $content -Needle 'data-review-template="md-html-review-v1"' -Message 'fixed review template marker exists'
    Assert-Contains -Content $content -Needle 'data-visual-block="summary"' -Message 'summary visual block exists'
    Assert-Contains -Content $content -Needle 'data-visual-block="architecture-flow"' -Message 'architecture flow visual block exists'
    Assert-Contains -Content $content -Needle 'data-visual-block="decision-grid"' -Message 'decision grid visual block exists'
    Assert-Contains -Content $content -Needle 'data-visual-block="risk-grid"' -Message 'risk grid visual block exists'
    Assert-Contains -Content $content -Needle 'data-visual-block="checkpoints"' -Message 'checkpoint visual block exists'
    Assert-Contains -Content $content -Needle 'data-visual-block="collapsible-source"' -Message 'collapsible source block exists'
    Assert-Contains -Content $content -Needle '<details class="source-section"' -Message 'collapsible details are used without JavaScript'
    Assert-Contains -Content $content -Needle 'class="flow-list"' -Message 'flow list is generated'
    Assert-Contains -Content $content -Needle 'class="decision-grid"' -Message 'decision cards are generated'
    Assert-Contains -Content $content -Needle 'class="risk-grid"' -Message 'risk cards are generated'

    Assert-NotMatches -Content $content -Pattern '(?i)<!doctype|<html\b|<head\b|<body\b|</html>|</head>|</body>' -Message 'output stays an HTML fragment'
    Assert-NotMatches -Content $content -Pattern '(?i)<script\b|</script>|<iframe\b|</iframe>' -Message 'output has no script or iframe'
    Assert-NotMatches -Content $content -Pattern '(?i)\s(src|href)=\x22https?://|\s(src|href)=\x27https?://' -Message 'output has no external JS/CSS resource'
    Assert-NotMatches -Content $content -Pattern '(?i)@import|document\.|querySelector|addEventListener' -Message 'output has no hidden JavaScript behavior'
} finally {
    if (Test-Path -LiteralPath $outputRoot) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
    }
}

if ($script:Failures.Count -gt 0) {
    Write-Output 'STATUS: FAIL'
} else {
    Write-Output 'STATUS: PASS'
}
Write-Output ("RepoRoot: {0}" -f $script:RepoRoot)
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
