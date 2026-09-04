# Ordinary runtime status. Release qualification has a separate maintenance entry.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,
    [string]$RepoRoot = "",
    [string]$UserProfileRoot = "",
    [switch]$ProbeHostDetails
)

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
    . (Join-Path $RepoRoot 'scripts\lib\Harness.RuntimeKernel.ps1')
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot

    try {
        $null = & (Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.ProtectedAction.psm1') -Force -PassThru -ErrorAction Stop) { param($Root, $Workspace) Read-HarnessProtectedPolicy -RepoRoot $Root -WorkspaceRoot $Workspace } $RepoRoot $WorkspaceRoot
        $protectedPolicy = [ordered]@{ status = 'verified'; reason = 'core-and-overlay-policy-valid' }
    } catch {
        $protectedPolicy = [ordered]@{status = $(if ($_.Exception.Message -match 'unavailable') { 'unavailable' } else { 'invalid' })
            reason = 'protected-policy-check-failed'}
    }

    $previousGitOptionalLocks = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS', [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', '0', [EnvironmentVariableTarget]::Process)
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -ErrorAction Stop
        $resolution = Get-HarnessProtocolResolution -WorkspaceRoot $WorkspaceRoot -RepoRoot $RepoRoot
    } finally {
        [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', $previousGitOptionalLocks, [EnvironmentVariableTarget]::Process)
    }
    $hostCapabilities = if ($ProbeHostDetails -or $null -eq $resolution.runtime_default_decision.host_capabilities) {
        Get-HarnessHostCapabilities -RepoRoot $RepoRoot -RequiredCapabilities @($resolution.runtime_default_decision.required_capabilities) -ProbeHostDetails:$ProbeHostDetails
    } else {
        $resolution.runtime_default_decision.host_capabilities
    }

    $warnings,$errors = [Collections.Generic.List[string]]::new(),[Collections.Generic.List[string]]::new()
    if ([string]$protectedPolicy.status -cne 'verified') { $errors.Add("Protected Action policy is $($protectedPolicy.status): $($protectedPolicy.reason)") }
    if ($null -eq $resolution.selected_protocol) { $warnings.Add("New work is stopped: $($resolution.reason)") }
    if ([string]$resolution.detected_protocol -ceq 'new' -and [string]$resolution.requested_protocol -ceq 'auto' -and [string]$resolution.runtime_default_decision.status -cin @('invalid','unavailable')) {
        $warnings.Add("Runtime Default Decision is $($resolution.runtime_default_decision.status): $($resolution.runtime_default_decision.reason)")
    }

    $projection = [pscustomobject]@{summary=[pscustomobject]@{status=$(if ($errors.Count -gt 0) { 'FAIL' } elseif ($warnings.Count -gt 0) { 'WARN' } else { 'PASS' });RepoRoot=$RepoRoot;WorkspaceRoot=$WorkspaceRoot
        host_details_probed=[bool]$ProbeHostDetails;workspace_protocol=$(if ($null -eq $resolution.workspace_config.new_task_protocol) { 'not-read' } else { $resolution.workspace_config.new_task_protocol })}
        host=$hostCapabilities;resolution=$resolution;policy=$protectedPolicy}
    Write-HarnessKernelProjection $projection @('STATUS=summary.status','RepoRoot=summary.RepoRoot','WorkspaceRoot=summary.WorkspaceRoot',
        'host_product=host.product','host_version_actual=host.actual_version','host_details_probed=summary.host_details_probed|bool','capability_observation=host.observation_status')
    foreach ($name in @($hostCapabilities.capabilities.Keys)) {
        Write-Output ("capability_{0}: {1}" -f $name, ([string]$hostCapabilities.capabilities[$name]).ToLowerInvariant())
    }
    Write-HarnessKernelProjection $projection @('selected_protocol=resolution.selected_protocol','new_task_admission=resolution.new_task_admission','preference_source=resolution.preference_source','default_source=resolution.default_source',
        'protocol_reason=resolution.reason','runtime_default=resolution.runtime_default_decision.status','runtime_default_reason=resolution.runtime_default_decision.reason','workspace_config=resolution.workspace_config.status',
        'workspace_protocol=summary.workspace_protocol','existing_artifact=resolution.detected_protocol','protected_policy=policy.status')
    foreach ($section in ([ordered]@{Warnings=$warnings;Errors=$errors}).GetEnumerator()) {
        Write-Output ''
        Write-Output "$($section.Key):"
        if (-not $section.Value.Count) {
            Write-Output '- none'
            continue
        }
        foreach ($item in $section.Value) { Write-Output ("- {0}" -f $item) }
    }

    exit @('PASS','WARN','FAIL').IndexOf($projection.summary.status)
} catch {
    Write-Output 'STATUS: FAIL'
    Write-Output ("Error: {0}" -f $_.Exception.Message)
    exit 2
}
