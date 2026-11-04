Import-Module (Join-Path $PSScriptRoot 'Harness.Protocol.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.ProtectedAction.psm1') -Force -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')

function Get-HarnessSessionWorkspaceGrantPath {
    param([string]$SessionId)
    Assert-HarnessKernelCondition ($SessionId -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') 'session workspace session_id is invalid'
    return ".assistant/runtime/session-workspaces/$((Get-HarnessSha256Text -Content $SessionId).Substring(7)).json"
}

function Get-HarnessSessionWorkspaceIdentity {
    param([string]$RepoRoot,[string]$Path)
    $root = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $Path
    [void](Resolve-HarnessContainedPath -WorkspaceRoot $root -Path '.assistant/entry/task.ps1' -Label 'session workspace v2 entry' -MustExist File)
    $protocol = Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $root
    Assert-HarnessKernelCondition ($protocol.selected_protocol -ceq 'v2' -and $protocol.new_task_admission -ceq 'enabled') 'session workspace requires installed v2 admission'
    return [ordered]@{path=$root;identity=(Get-HarnessPhysicalPathIdentity -Path $root)}
}

function Get-HarnessSessionWorkspaceRoots {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$SessionId='')
    if ([string]::IsNullOrWhiteSpace($SessionId)) { return @() }
    $path = Get-HarnessSessionWorkspaceGrantPath -SessionId $SessionId
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'session workspace grant' -AllowMissing
    if (-not (Test-Path -LiteralPath $fullPath)) { return @() }
    $grant = (Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'session workspace grant' -MaximumBytes 65536 -RepoRoot $RepoRoot -Schema session-workspaces.schema.json).Document
    Assert-HarnessKernelCondition ($grant.session_id -ceq $SessionId) 'session workspace session binding is stale'
    $primary = Get-HarnessSessionWorkspaceIdentity -RepoRoot $RepoRoot -Path $WorkspaceRoot
    Assert-HarnessKernelCondition ($grant.primary.path.Equals($primary.path,[StringComparison]::OrdinalIgnoreCase) -and $grant.primary.identity -ceq $primary.identity) 'session workspace primary identity is stale'
    Assert-HarnessKernelCondition ($null -eq $grant.expires_at -or [datetimeoffset]::Parse($grant.expires_at) -gt [datetimeoffset]::UtcNow) 'session workspace grant is expired'
    foreach ($workspace in $grant.workspaces) {
        $identity = Get-HarnessSessionWorkspaceIdentity -RepoRoot $RepoRoot -Path $workspace.path
        Assert-HarnessKernelCondition (Test-HarnessKernelFields $workspace $identity) 'session workspace target identity is stale'
        $identity.path
    }
}

function Set-HarnessSessionWorkspaceGrant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AdditionalWorkspaceRoots,
        [Parameter(Mandatory)][string]$TaskWorkspaceRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$ExpectedVersion,
        [Parameter(Mandatory)][ValidatePattern('^(?:missing|sha256:[0-9a-f]{64})$')][string]$ExpectedCurrentDigest,
        [switch]$DryRun
    )
    $path = Get-HarnessSessionWorkspaceGrantPath -SessionId $SessionId
    $primary = Get-HarnessSessionWorkspaceIdentity -RepoRoot $RepoRoot -Path $WorkspaceRoot
    $workspaces = @(foreach ($root in $AdditionalWorkspaceRoots) { Get-HarnessSessionWorkspaceIdentity -RepoRoot $RepoRoot -Path $root })
    Assert-HarnessKernelCondition ($workspaces.Count -le 16) 'session workspace target count exceeds limit'
    $seen = @($primary)
    foreach ($workspace in $workspaces) {
        foreach ($other in $seen) {
            $relative = [IO.Path]::GetRelativePath($other.path,$workspace.path)
            $reverse = [IO.Path]::GetRelativePath($workspace.path,$other.path)
            Assert-HarnessKernelCondition ($workspace.identity -cne $other.identity -and $relative -match '^\.\.[\\/]|^[A-Za-z]:' -and $reverse -match '^\.\.[\\/]|^[A-Za-z]:') 'session workspace roots must not overlap'
        }
        $seen += @($workspace)
    }
    $authorityRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $TaskWorkspaceRoot
    $authorityIdentity = Get-HarnessPhysicalPathIdentity -Path $authorityRoot
    $mutex = Enter-HarnessKernelMutex -Name (Get-HarnessKernelMutexName -WorkspaceIdentity $authorityIdentity -Suffix state) -Label session-workspace-authority
    $grantMutex = $null
    try {
        $task = & (Get-Module Harness.ProtectedAction) { param($Repo,$Root,$Id) Read-HarnessProtectedTask -RepoRoot $Repo -WorkspaceRoot $Root -TaskId $Id } $RepoRoot $authorityRoot $TaskId
        Assert-HarnessKernelCondition ([int]$task.version -eq $ExpectedVersion -and $task.requirement_state -ceq 'clear' -and $task.execution_profile -ceq 'critical' -and $task.status -cin @('running','verifying')) 'session workspace requires a current clear Critical task'
        Assert-HarnessKernelCondition (-not @($task.policies.Keys | Where-Object { $task.policies[$_] -ne $true }).Count) 'session workspace requires Critical policy flags'
        $intent = [ordered]@{
            session_id=$SessionId
            primary=$primary
            workspaces=$workspaces
            expected_current_digest=$ExpectedCurrentDigest
        }
        $operation = New-HarnessProtectedOperation -TaskVersion $ExpectedVersion -ContractDigest $task.contract_digest -Environment workspace -ActionCategory protected-write `
            -Targets @($path) -ApprovalType architecture -ApprovalScope @('rule:session-workspace-registration',"command_digest:$(Get-HarnessSha256Text -Content (ConvertTo-HarnessKernelJson -Value $intent -Compress))","path:$path")
        $approval = Assert-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $authorityRoot -Task $task -RequiredOperation $operation
        $grant = [ordered]@{
            schema_version='session-workspaces/v1'
            session_id=$SessionId
            primary=$primary
            workspaces=$workspaces
            task_id=$TaskId
            task_version=$ExpectedVersion
            contract_digest=$task.contract_digest
            approval_id=$approval.Document.approval_id
            registered_at=[datetimeoffset]::UtcNow.ToString('o')
            expires_at=$approval.Document.expires_at
        }
        Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $grant -Schema session-workspaces.schema.json -Label 'session workspace grant'
        $grantMutex = Enter-HarnessKernelMutex -Name (Get-HarnessKernelMutexName -WorkspaceIdentity $primary.identity -Suffix session-workspaces) -Label session-workspaces
        $currentDigest = Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path
        if ($null -eq $currentDigest) { $currentDigest = 'missing' }
        Assert-HarnessKernelCondition ($currentDigest -ceq $ExpectedCurrentDigest) 'session workspace grant current digest is stale'
        foreach ($workspace in $seen) {
            Assert-HarnessKernelCondition ($workspace.identity -ceq (Get-HarnessPhysicalPathIdentity -Path $workspace.path)) 'session workspace identity changed before registration'
        }
        Assert-HarnessKernelCondition ($authorityIdentity -ceq (Get-HarnessPhysicalPathIdentity -Path $authorityRoot)) 'session workspace authority identity changed before registration'
        $finalApproval = Assert-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $authorityRoot -Task $task -RequiredOperation $operation
        Assert-HarnessKernelCondition ($finalApproval.Digest -ceq $approval.Digest) 'session workspace Approval changed before registration'
        if (-not $DryRun) {
            [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path '.assistant/runtime/session-workspaces' -Label 'session workspace registry')
            [void](Write-HarnessKernelJsonCas -WorkspaceRoot $WorkspaceRoot -Path $path -Value $grant -CurrentDigest $ExpectedCurrentDigest)
        }
        return [ordered]@{
            written=(-not [bool]$DryRun)
            dry_run=[bool]$DryRun
            path=$path
            operation_identity=$operation.identity
            grant=$grant
        }
    } finally {
        Exit-HarnessKernelMutex -Mutex $grantMutex
        Exit-HarnessKernelMutex -Mutex $mutex
    }
}

Export-ModuleMember -Function Get-HarnessSessionWorkspaceRoots,Set-HarnessSessionWorkspaceGrant
