$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')
. (Join-Path $PSScriptRoot 'Harness.RuntimeDefaultReader.ps1')

function Get-HarnessRuntimeSourceRevision {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $output = @((Invoke-HarnessGit -WorkspaceRoot (Resolve-Path -LiteralPath $RepoRoot).Path -Arguments @('rev-parse','HEAD') -FailureReason 'runtime-default-source-revision-unavailable').Lines)
    Assert-HarnessKernelCondition ($output.Count -eq 1 -and $output[0] -cmatch '^[0-9a-f]{40,64}$') 'runtime-default-source-revision-unavailable'
    return $output[0]
}

function New-HarnessRuntimeDefaultDecisionDocument {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][ValidateSet('workspace-canary','release-default')][string]$Scope,[ValidateSet('v2')][string]$NewTaskProtocol = 'v2',
        [string]$SourceRevision = '',[string]$DecisionId = '',[datetimeoffset]$IssuedAtUtc = [datetimeoffset]::UtcNow,
        [Nullable[datetimeoffset]]$ExpiresAtUtc = $null,
        [string[]]$RequiredCapabilities = @('workspace_protocol_config'))

    $sourceIdentity = Get-HarnessRuntimeSourceIdentity -RepoRoot $RepoRoot
    if ([string]::IsNullOrWhiteSpace($SourceRevision)) { $SourceRevision = [string]$sourceIdentity.revision }
    if ([string]::IsNullOrWhiteSpace($DecisionId)) { $DecisionId = 'rtd_' + [guid]::NewGuid().ToString('N') }
    if ($Scope -ceq 'workspace-canary' -and $null -eq $ExpiresAtUtc) { throw 'runtime-default-canary-expiry-required' }
    if ($Scope -ceq 'release-default' -and $null -ne $ExpiresAtUtc) { throw 'runtime-default-release-expiry-forbidden' }
    $document = [ordered]@{schema_version = 'harness-runtime-default/v1'
        new_task_protocol = $NewTaskProtocol
        scope = $Scope
        source_revision = $SourceRevision
        source_identity = $sourceIdentity
        decision_id = $DecisionId
        issued_at_utc = $IssuedAtUtc.ToUniversalTime().ToString('o')
        expires_at_utc = $(if ($null -eq $ExpiresAtUtc) { $null } else { ([datetimeoffset]$ExpiresAtUtc).ToUniversalTime().ToString('o') })
        workspace_identity_digest = $(if ($Scope -ceq 'workspace-canary') { Get-HarnessRuntimeWorkspaceIdentityDigest -WorkspaceRoot $WorkspaceRoot } else { $null })
        required_capabilities = @($RequiredCapabilities)
        decision_digest = ''}
    $document.decision_digest = Get-HarnessRuntimeDefaultDecisionDigest -Document $document
    [void](Assert-HarnessRuntimeDefaultDecision -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Document $document -AsOfUtc $IssuedAtUtc -ObservedSourceIdentity $sourceIdentity)
    return $document
}

Export-ModuleMember -Function Get-HarnessRuntimeDefaultDecision,New-HarnessRuntimeDefaultDecisionDocument,Get-HarnessRuntimeDefaultDecisionDigest,Get-HarnessRuntimeSourceRevision,Get-HarnessRuntimeSourceIdentity,Get-HarnessRuntimeWorkspaceIdentityDigest,Assert-HarnessRuntimeDefaultDecision
