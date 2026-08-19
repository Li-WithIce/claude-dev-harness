# Ordinary runtime status. Release qualification has a separate maintenance entry.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [string]$RepoRoot = "",
    [string]$UserProfileRoot = "",
    [switch]$ProbeHostDetails
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -ErrorAction Stop
    $hostCapabilitiesModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.HostCapabilities.psm1') -Force -PassThru -ErrorAction Stop
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot

    try {
        $protectedModule = Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.ProtectedAction.psm1') -Force -PassThru -ErrorAction Stop
        $null = & $protectedModule { param($Root, $Workspace) Read-HarnessProtectedPolicy -RepoRoot $Root -WorkspaceRoot $Workspace } $RepoRoot $WorkspaceRoot
        $protectedPolicy = [ordered]@{ status = 'verified'; reason = 'core-and-overlay-policy-valid' }
    } catch {
        $protectedPolicy = [ordered]@{
            status = $(if ($_.Exception.Message -match 'unavailable') { 'unavailable' } else { 'invalid' })
            reason = 'protected-policy-check-failed'
        }
    }

    $previousGitOptionalLocks = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS', [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', '0', [EnvironmentVariableTarget]::Process)
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -ErrorAction Stop
        $resolution = Get-HarnessProtocolResolution -WorkspaceRoot $WorkspaceRoot -RepoRoot $RepoRoot
    } finally {
        [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', $previousGitOptionalLocks, [EnvironmentVariableTarget]::Process)
    }
    $requiredCapabilities = @($resolution.runtime_default_decision.required_capabilities)
    $hostCapabilities = if ($ProbeHostDetails) {
        & $hostCapabilitiesModule { param($Root,$Required) Get-HarnessHostCapabilities -RepoRoot $Root -RequiredCapabilities $Required -ProbeHostDetails } $RepoRoot $requiredCapabilities
    } elseif ($null -ne $resolution.runtime_default_decision.host_capabilities) {
        $resolution.runtime_default_decision.host_capabilities
    } else {
        & $hostCapabilitiesModule { param($Root,$Required) Get-HarnessHostCapabilities -RepoRoot $Root -RequiredCapabilities $Required } $RepoRoot $requiredCapabilities
    }

    $warnings = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    if ([string]$protectedPolicy.status -cne 'verified') {
        $errors.Add("Protected Action policy is $($protectedPolicy.status): $($protectedPolicy.reason)")
    }
    if ([string]$resolution.selected_protocol -ceq 'v1') {
        $warnings.Add("New tasks select v1: $($resolution.reason)")
    }
    if ([string]$resolution.detected_protocol -ceq 'new' -and
        [string]$resolution.requested_protocol -ceq 'auto' -and
        [string]$resolution.runtime_default_decision.status -cin @('invalid','unavailable')) {
        $warnings.Add("Runtime Default Decision is $($resolution.runtime_default_decision.status): $($resolution.runtime_default_decision.reason)")
    }

    $status = if ($errors.Count -gt 0) { 'FAIL' } elseif ($warnings.Count -gt 0) { 'WARN' } else { 'PASS' }
    Write-Output ("STATUS: {0}" -f $status)
    Write-Output ("RepoRoot: {0}" -f $RepoRoot)
    Write-Output ("WorkspaceRoot: {0}" -f $WorkspaceRoot)
    Write-Output ("host_product: {0}" -f $hostCapabilities.product)
    Write-Output ("host_version_actual: {0}" -f $hostCapabilities.actual_version)
    Write-Output ("host_details_probed: {0}" -f ([string][bool]$ProbeHostDetails).ToLowerInvariant())
    Write-Output ("capability_observation: {0}" -f $hostCapabilities.observation_status)
    foreach ($name in @($hostCapabilities.capabilities.Keys)) {
        Write-Output ("capability_{0}: {1}" -f $name, ([string]$hostCapabilities.capabilities[$name]).ToLowerInvariant())
    }
    Write-Output ("selected_protocol: {0}" -f $resolution.selected_protocol)
    Write-Output ("preference_source: {0}" -f $resolution.preference_source)
    Write-Output ("default_source: {0}" -f $resolution.default_source)
    Write-Output ("protocol_reason: {0}" -f $resolution.reason)
    Write-Output ("runtime_default: {0}" -f $resolution.runtime_default_decision.status)
    Write-Output ("runtime_default_reason: {0}" -f $resolution.runtime_default_decision.reason)
    Write-Output ("workspace_config: {0}" -f $resolution.workspace_config.status)
    Write-Output ("workspace_protocol: {0}" -f $(if ($null -eq $resolution.workspace_config.new_task_protocol) { 'not-read' } else { $resolution.workspace_config.new_task_protocol }))
    Write-Output ("existing_artifact: {0}" -f $resolution.detected_protocol)
    Write-Output ("protected_policy: {0}" -f $protectedPolicy.status)
    Write-Output ''
    Write-Output 'Warnings:'
    if ($warnings.Count -eq 0) { Write-Output '- none' } else { foreach ($warning in $warnings) { Write-Output ("- {0}" -f $warning) } }
    Write-Output ''
    Write-Output 'Errors:'
    if ($errors.Count -eq 0) { Write-Output '- none' } else { foreach ($errorItem in $errors) { Write-Output ("- {0}" -f $errorItem) } }

    switch ($status) {
        'PASS' { exit 0 }
        'WARN' { exit 1 }
        default { exit 2 }
    }
} catch {
    Write-Output 'STATUS: FAIL'
    Write-Output ("Error: {0}" -f $_.Exception.Message)
    exit 2
}
