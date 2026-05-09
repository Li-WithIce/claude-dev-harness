#!/usr/bin/env powershell
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,

    [Alias('t')]
    [string]$TaskText,

    [Alias('w')]
    [string]$Workspace = (Get-Location).Path,

    [Alias('f')]
    [string[]]$File,

    [ValidateSet("text", "json", "stream-json")]
    [string]$OutputFormat = "text",

    [ValidateSet("plan", "default", "auto_edit", "yolo")]
    [string]$ApprovalMode = "plan",

    [string]$Model,

    [string[]]$IncludeDirectories,

    [switch]$EnsureProjectSetup,

    [Alias('o')]
    [string]$Output,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-Usage {
    @'
Usage:
  ask_gemini.ps1 <task> [options]
  ask_gemini.ps1 -Task <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -Task, -t <text>             Alias for positional task

File context (optional, repeatable):
  -File, -f <path>             Priority file path

Options:
  -Workspace, -w <path>        Workspace directory (default: current directory)
  -OutputFormat <format>       Gemini CLI output format: text, json, stream-json
  -ApprovalMode <mode>         Gemini CLI approval mode: plan, default, auto_edit, yolo
  -Model <name>                Model override
  -IncludeDirectories <paths>  Extra include-directories entries
  -EnsureProjectSetup          Create GEMINI.md when missing
  -Output, -o <path>           Output file path
  -Help                        Show this help

Output (on success):
  output_path=<file>           Path to generated report

Examples:
  ask_gemini.ps1 "Generate a test report" -f docs/tasks/task/spec.md -f docs/tasks/task/plan.md
  ask_gemini.ps1 "Re-check the current task" -ApprovalMode plan -o docs/tasks/task/test.md
'@
}

function Normalize-Text {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    return $Text.Trim()
}

function Resolve-FileRef {
    param(
        [string]$WorkspacePath,
        [string]$RawPath
    )

    $cleaned = Normalize-Text $RawPath
    if ([string]::IsNullOrWhiteSpace($cleaned)) {
        return $null
    }

    $cleaned = $cleaned -replace '#L\d+$', ''
    $cleaned = $cleaned -replace ':\d+(-\d+)?$', ''

    if (-not [System.IO.Path]::IsPathRooted($cleaned)) {
        $cleaned = Join-Path $WorkspacePath $cleaned
    }

    if (-not (Test-Path -LiteralPath $cleaned)) {
        throw "Context file not found: $cleaned"
    }

    return (Resolve-Path -LiteralPath $cleaned).Path
}

function Append-FileContext {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$FilePath
    )

    $content = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine("===== BEGIN FILE: $FilePath =====")
    [void]$Builder.AppendLine($content)
    [void]$Builder.AppendLine("===== END FILE: $FilePath =====")
}

function Remove-OuterCodeFences {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $trimmed = $Text.Trim()
    if ($trimmed -notmatch '^```') {
        return $trimmed
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $trimmed -split "`r?`n" | ForEach-Object { [void]$lines.Add($_) }

    if ($lines.Count -gt 0 -and $lines[0] -match '^```') {
        $lines.RemoveAt(0)
    }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -match '^```$') {
        $lines.RemoveAt($lines.Count - 1)
    }

    return ($lines -join "`n").Trim()
}

function Write-File-NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

if ($Help) {
    Show-Usage
    exit 0
}

if ([string]::IsNullOrEmpty($Task) -and -not [string]::IsNullOrEmpty($TaskText)) {
    $Task = $TaskText
}

$Task = Normalize-Text $Task
if ([string]::IsNullOrWhiteSpace($Task)) {
    throw "Request text is empty. Pass a positional arg or -Task."
}

if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    throw "Workspace does not exist: $Workspace"
}
$resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace).Path

$skillDir = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($Output)) {
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $runtimeDir = Join-Path $skillDir ".runtime\gemini-test"
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }
    $Output = Join-Path $runtimeDir "$timestamp-test-report.md"
}

$outputDir = Split-Path $Output -Parent
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$scriptDir = $PSScriptRoot
if ($EnsureProjectSetup) {
    & (Join-Path $scriptDir "bootstrap-gemini-project.ps1") -Workspace $resolvedWorkspace | Out-Null
}

$envInfo = & (Join-Path $scriptDir "check-gemini-env.ps1") -Workspace $resolvedWorkspace | ConvertFrom-Json
if (-not $envInfo.gemini_path) {
    $diag = @{ status = "preflight_failed"; tool = "gemini"; reason = "Gemini CLI not found in PATH"; suggestion = "Install with: npm install -g @google/gemini-cli" } | ConvertTo-Json -Compress
    Write-Output $diag
    throw "Gemini CLI is not installed. Install it with: npm install -g @google/gemini-cli"
}
if (-not $envInfo.auth_sources -or $envInfo.auth_sources.Count -eq 0) {
    $diag = @{ status = "preflight_failed"; tool = "gemini"; reason = "No auth source detected"; suggestion = "Start 'gemini' and complete Google login, or set GEMINI_API_KEY / GOOGLE_API_KEY" } | ConvertTo-Json -Compress
    Write-Output $diag
    throw "Gemini CLI has no detected auth source. Start 'gemini' and complete Google login, or set GEMINI_API_KEY / GOOGLE_API_KEY."
}

$promptBuilder = New-Object System.Text.StringBuilder
[void]$promptBuilder.AppendLine("Task:")
[void]$promptBuilder.AppendLine($Task)
[void]$promptBuilder.AppendLine("")
[void]$promptBuilder.AppendLine("Instructions:")
[void]$promptBuilder.AppendLine("- You are a software testing and validation reviewer.")
[void]$promptBuilder.AppendLine("- Work only from the evidence in the task text and attached files.")
[void]$promptBuilder.AppendLine("- Never claim a command, test run, or manual validation happened unless it is explicitly present in the inputs.")
[void]$promptBuilder.AppendLine("- Produce a markdown report only. Do not wrap the whole response in code fences.")
[void]$promptBuilder.AppendLine("- The report must contain these exact headings:")
[void]$promptBuilder.AppendLine("  # Test Report")
[void]$promptBuilder.AppendLine("  ## Summary")
[void]$promptBuilder.AppendLine("  ## Scope")
[void]$promptBuilder.AppendLine("  ## Inputs Reviewed")
[void]$promptBuilder.AppendLine("  ## Test Approach")
[void]$promptBuilder.AppendLine("  ## Findings")
[void]$promptBuilder.AppendLine("  ## Risks / Gaps")
[void]$promptBuilder.AppendLine("  ## Conclusion")
[void]$promptBuilder.AppendLine("  ## Handoff")
[void]$promptBuilder.AppendLine("- Under '## Conclusion', output exactly one lowercase word on the first non-empty line: pass, fail, or blocked.")
[void]$promptBuilder.AppendLine("- Choose blocked when evidence is insufficient, inputs conflict, or execution cannot be validated confidently.")
[void]$promptBuilder.AppendLine("- Respond in the same language as the task text when practical.")

if ($File -and $File.Count -gt 0) {
    foreach ($fileRef in $File) {
        $resolvedFile = Resolve-FileRef -WorkspacePath $resolvedWorkspace -RawPath $fileRef
        Append-FileContext -Builder $promptBuilder -FilePath $resolvedFile
    }
}

$invokeResult = & (Join-Path $scriptDir "invoke-gemini.ps1") `
    -Workspace $resolvedWorkspace `
    -Prompt $promptBuilder.ToString() `
    -OutputFormat $OutputFormat `
    -ApprovalMode $ApprovalMode `
    -Model $Model `
    -IncludeDirectories $IncludeDirectories | ConvertFrom-Json

if (-not $invokeResult.ok) {
    throw "Gemini CLI exited with code $($invokeResult.exit_code). Output: $($invokeResult.stdout)"
}
if ($invokeResult.capacity_warning) {
    throw "Gemini CLI returned a model capacity warning. Output: $($invokeResult.stdout)"
}

$content = Remove-OuterCodeFences -Text (Normalize-Text $invokeResult.stdout)
if ([string]::IsNullOrWhiteSpace($content)) {
    throw "Gemini CLI returned empty output."
}

Write-File-NoBom -Path $Output -Content $content
Write-Output "output_path=$Output"
