[CmdletBinding()]
param(
    [string]$Workspace = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$resolvedWorkspace = $null
try {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace).Path
} catch {
}

$geminiCommand = Get-Command gemini -ErrorAction SilentlyContinue
$geminiPath = $null
$geminiVersion = $null

if ($geminiCommand) {
    $geminiPath = $geminiCommand.Source
    try {
        $geminiVersion = ((& gemini --version 2>&1 | Select-Object -First 1) | Out-String).Trim()
    } catch {
        $geminiVersion = $null
    }
}

$homeGemini = Join-Path $env:USERPROFILE ".gemini"
$oauthCredsPath = Join-Path $homeGemini "oauth_creds.json"
$googleAccountsPath = Join-Path $homeGemini "google_accounts.json"
$settingsPath = Join-Path $homeGemini "settings.json"
$trustedFoldersPath = Join-Path $homeGemini "trustedFolders.json"

$authSources = @()
if ($env:GEMINI_API_KEY) {
    $authSources += "GEMINI_API_KEY"
}
if ($env:GOOGLE_API_KEY) {
    $authSources += "GOOGLE_API_KEY"
}
if (Test-Path -LiteralPath $oauthCredsPath) {
    $authSources += "oauth_creds.json"
}
if (Test-Path -LiteralPath $googleAccountsPath) {
    $authSources += "google_accounts.json"
}

$workspaceTrusted = $null
if ($resolvedWorkspace -and (Test-Path -LiteralPath $trustedFoldersPath)) {
    try {
        $trustedFolders = Get-Content -Path $trustedFoldersPath -Raw | ConvertFrom-Json
        $workspaceTrusted = $false
        foreach ($property in $trustedFolders.PSObject.Properties) {
            if ($resolvedWorkspace.StartsWith($property.Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $workspaceTrusted = $true
                break
            }
        }
    } catch {
        $workspaceTrusted = $null
    }
}

$geminiMdPath = $null
$geminiMdExists = $false
if ($resolvedWorkspace) {
    $geminiMdPath = Join-Path $resolvedWorkspace "GEMINI.md"
    $geminiMdExists = Test-Path -LiteralPath $geminiMdPath
}

[pscustomobject]@{
    workspace = $resolvedWorkspace
    gemini_md_path = $geminiMdPath
    gemini_md_exists = $geminiMdExists
    gemini_path = $geminiPath
    gemini_version = $geminiVersion
    auth_sources = $authSources
    oauth_creds_path = $oauthCredsPath
    oauth_creds_exists = (Test-Path -LiteralPath $oauthCredsPath)
    settings_path = $settingsPath
    settings_exists = (Test-Path -LiteralPath $settingsPath)
    trusted_folders_path = $trustedFoldersPath
    trusted_folders_exists = (Test-Path -LiteralPath $trustedFoldersPath)
    workspace_trusted = $workspaceTrusted
} | ConvertTo-Json -Depth 5
