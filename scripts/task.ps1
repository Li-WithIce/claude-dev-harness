[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = '',
    [string]$RequestFile = '',
    [string]$RepoRoot = '',
    [string]$WorkspaceRoot = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if ($Command -cne 'inspect') {
        throw "unsupported task command: $Command"
    }
    if ([string]::IsNullOrWhiteSpace($RequestFile)) {
        throw 'inspect requires -RequestFile'
    }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $WorkspaceRoot = $RepoRoot
    }
    $WorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path

    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Requirement.psm1') -Force -ErrorAction Stop
    $result = Invoke-RequirementInspection -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -RequestFile $RequestFile
    if ($AsJson) {
        Write-Output ($result | ConvertTo-Json -Depth 30 -Compress)
    } else {
        Write-Output ("requirement_state: {0}" -f $result.requirement_state)
        Write-Output ("blocking_decisions: {0}" -f @($result.blocking_decisions).Count)
        Write-Output ("contract_digest: {0}" -f $(if ($null -eq $result.contract) { 'none' } else { $result.contract.digest }))
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
