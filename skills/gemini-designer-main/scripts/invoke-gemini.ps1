[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    [ValidateSet("text", "json", "stream-json")]
    [string]$OutputFormat = "text",

    [ValidateSet("plan", "default", "auto_edit", "yolo")]
    [string]$ApprovalMode = "plan",

    [string]$Model,

    [string[]]$IncludeDirectories
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace).Path
$geminiCommand = Get-Command gemini -ErrorAction SilentlyContinue
if (-not $geminiCommand) {
    throw "Gemini CLI was not found. Install it with: npm install -g @google/gemini-cli"
}

$args = @("-p", $Prompt, "--output-format", $OutputFormat, "--approval-mode", $ApprovalMode)
if ($Model) {
    $args += @("-m", $Model)
}
if ($IncludeDirectories -and $IncludeDirectories.Count -gt 0) {
    $args += @("--include-directories", ($IncludeDirectories -join ","))
}

$stdoutLines = @()
$exitCode = 0

Push-Location $resolvedWorkspace
try {
    $nativeErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $stdoutLines = & gemini @args 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $nativeErrorPreference
    Pop-Location
}

$usedCachedCredentials = $false
$cleanStdoutLines = foreach ($line in $stdoutLines) {
    if ($line -eq "Loaded cached credentials.") {
        $usedCachedCredentials = $true
        continue
    }
    $line
}
$stdoutText = (($cleanStdoutLines -join "`n").Trim())

[pscustomobject]@{
    ok = ($exitCode -eq 0)
    exit_code = $exitCode
    workspace = $resolvedWorkspace
    prompt = $Prompt
    output_format = $OutputFormat
    approval_mode = $ApprovalMode
    used_cached_credentials = $usedCachedCredentials
    capacity_warning = ($stdoutText -match "MODEL_CAPACITY_EXHAUSTED|No capacity available|RESOURCE_EXHAUSTED")
    stdout = $stdoutText
} | ConvertTo-Json -Depth 5
