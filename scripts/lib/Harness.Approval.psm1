Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop

function ConvertTo-HarnessApprovalJson {
    param([Parameter(Mandatory)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 30) + "`n"
}

function Test-HarnessApprovalSchema {
    param([string]$RepoRoot,[object]$Value,[string]$Label)
    try { $valid = Test-Json -Json ($Value | ConvertTo-Json -Depth 30 -Compress) -SchemaFile (Join-Path $RepoRoot 'schemas\approval.schema.json') -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { throw "$Label schema validation failed: $($_.Exception.Message)" }
    if (-not $valid) { throw "$Label failed schema validation" }
}

function Read-HarnessApprovalJson {
    param([string]$WorkspaceRoot,[string]$Path,[string]$Label)
    $fullPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label $Label -MustExist File
    try { $value = [System.IO.File]::ReadAllText($fullPath,[System.Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-HarnessJson -ErrorAction Stop }
    catch { throw "$Label is not valid UTF-8 JSON: $($_.Exception.Message)" }
    if ($value -isnot [System.Collections.IDictionary]) { throw "$Label must be a JSON object" }
    return [pscustomobject]@{Document=$value;Path=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $fullPath)}
}

function Test-HarnessApprovalExpiry {
    param(
        [System.Collections.IDictionary]$Approval,
        [datetimeoffset]$AsOf = [datetimeoffset]::UtcNow
    )
    try { $approvedAt = [datetimeoffset]::Parse([string]$Approval.approved_at,[Globalization.CultureInfo]::InvariantCulture) }
    catch { throw 'Approval approved_at is invalid' }
    if ($approvedAt -gt $AsOf) { throw 'Approval approved_at is in the future' }
    if ($null -eq $Approval.expires_at) { return $false }
    try { $expiresAt = [datetimeoffset]::Parse([string]$Approval.expires_at,[Globalization.CultureInfo]::InvariantCulture) }
    catch { throw 'Approval expires_at is invalid' }
    if ($expiresAt -le $approvedAt) { throw 'Approval expires_at must be later than approved_at' }
    return $expiresAt -le $AsOf
}

function Resolve-HarnessApprovalInputCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ApprovalPath,
        [Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$TargetTaskVersion,[Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][datetimeoffset]$AsOf
    )
    $loaded = Read-HarnessApprovalJson -WorkspaceRoot $WorkspaceRoot -Path $ApprovalPath -Label 'Approval input';$approval=$loaded.Document
    Test-HarnessApprovalSchema -RepoRoot $RepoRoot -Value $approval -Label 'Approval input'
    if ([string]$approval.task_id -cne $TaskId) { throw 'Approval task_id does not match TaskId' }
    if ([int]$approval.task_version -ne $TargetTaskVersion) { throw "Approval task_version must bind the post-import version: expected=$TargetTaskVersion actual=$($approval.task_version)" }
    if ([string]$approval.contract_digest -cne $ContractDigest) { throw 'Approval contract_digest is stale' }
    if ([string]$approval.status -cne 'granted') { throw 'only a granted Approval can be imported' }
    if (Test-HarnessApprovalExpiry -Approval $approval -AsOf $AsOf) { throw 'Approval is expired' }
    $outputPath = ".assistant/runtime/tasks/$TaskId/approvals/$($approval.approval_id).json"
    $content = ConvertTo-HarnessApprovalJson -Value $approval
    return [pscustomobject]@{Document=$approval;InputPath=$loaded.Path;OutputPath=$outputPath;Content=$content;Digest=(Get-HarnessSha256Text -Content $content)}
}

function Resolve-HarnessApprovalInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$ApprovalPath,
        [Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][int]$TargetTaskVersion,[Parameter(Mandatory)][string]$ContractDigest
    )
    return Resolve-HarnessApprovalInputCore -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -ApprovalPath $ApprovalPath -TaskId $TaskId -TargetTaskVersion $TargetTaskVersion -ContractDigest $ContractDigest -AsOf ([datetimeoffset]::UtcNow)
}

function Assert-HarnessTaskApprovalCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Task,
        [string]$RequiredType='',[string[]]$RequiredScopes=@(),
        [Parameter(Mandatory)][datetimeoffset]$AsOf
    )
    foreach ($approvalId in @($Task.approvals)) {
        $path = ".assistant/runtime/tasks/$($Task.task_id)/approvals/$approvalId.json"
        $loaded = Read-HarnessApprovalJson -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'task Approval';$approval=$loaded.Document
        Test-HarnessApprovalSchema -RepoRoot $RepoRoot -Value $approval -Label 'task Approval'
        if ([string]$approval.approval_id -cne [string]$approvalId -or [string]$approval.task_id -cne [string]$Task.task_id) { throw 'task Approval identity is invalid' }
        if ([string]$approval.status -cne 'granted' -or (Test-HarnessApprovalExpiry -Approval $approval -AsOf $AsOf)) { continue }
        if ([int]$approval.task_version -ne [int]$Task.version -or [string]$approval.contract_digest -cne [string]$Task.contract_digest) { continue }
        if (-not [string]::IsNullOrWhiteSpace($RequiredType) -and [string]$approval.approval_type -cne $RequiredType) { continue }
        $scopes = @($approval.approved_scope)
        if (@($RequiredScopes | Where-Object { $scopes -cnotcontains $_ }).Count -gt 0) { continue }
        return [pscustomobject]@{Path=$loaded.Path;Document=$approval;Digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $loaded.Path)}
    }
    throw ("no current granted Approval covers the required task version, Contract, type, and scope; required_type={0}; required_scopes={1}" -f $RequiredType,($RequiredScopes -join ','))
}

function Assert-HarnessTaskApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Task,
        [string]$RequiredType='',[string[]]$RequiredScopes=@()
    )
    return Assert-HarnessTaskApprovalCore -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $Task -RequiredType $RequiredType -RequiredScopes $RequiredScopes -AsOf ([datetimeoffset]::UtcNow)
}

Export-ModuleMember -Function Resolve-HarnessApprovalInput,Assert-HarnessTaskApproval
