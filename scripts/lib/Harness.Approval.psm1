Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -Force -ErrorAction Stop

function ConvertTo-HarnessProtectedOperationArray {
    param([string[]]$Values,[ValidateSet('target','scope')][string]$Kind)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in @($Values)) {
        if ([string]::IsNullOrWhiteSpace([string]$raw)) { throw "protected operation $Kind must not be blank" }
        $value = ([string]$raw).Trim().Replace('\','/')
        if ($Kind -ceq 'target') {
            if ([IO.Path]::IsPathRooted($value) -or $value.Contains(':') -or @($value -split '/' | Where-Object { $_ -ceq '..' }).Count -gt 0) { throw 'protected operation target is invalid' }
        } elseif ($value -cnotmatch '^(?:rule:[a-z0-9][a-z0-9-]{0,63}|command_digest:sha256:[0-9a-f]{64}|environment:[a-z0-9][a-z0-9._-]{0,63}|path:.+|dry-run:true)$') {
            throw 'protected operation Approval scope is invalid'
        }
        if (-not $seen.Add($value)) { throw "protected operation $Kind values must be unique" }
        $result.Add($value)
    }
    if ($result.Count -eq 0) { throw "protected operation $Kind values must not be empty" }
    $array = $result.ToArray();[Array]::Sort($array,[StringComparer]::Ordinal)
    return $array
}

function New-HarnessProtectedOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$TaskVersion,
        [Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][ValidateSet('protected-write')][string]$ActionCategory,
        [Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)][ValidateSet('none','product','architecture','production')][string]$ApprovalType,
        [Parameter(Mandatory)][string[]]$ApprovalScope
    )
    if ($TaskVersion -lt 1) { throw 'protected operation task_version is invalid' }
    if ($ContractDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'protected operation Contract digest is invalid' }
    $normalizedEnvironment = $Environment.Trim().ToLowerInvariant()
    if ($normalizedEnvironment -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$') { throw 'protected operation environment is invalid' }
    $normalizedTargets = @(ConvertTo-HarnessProtectedOperationArray -Values $Targets -Kind target)
    $normalizedScopes = @(ConvertTo-HarnessProtectedOperationArray -Values $ApprovalScope -Kind scope)
    $identityInput = [ordered]@{
        task_version=$TaskVersion
        contract_digest=$ContractDigest
        environment=$normalizedEnvironment
        action_category=$ActionCategory
        targets=$normalizedTargets
        approval_type=$ApprovalType
        approval_scope=$normalizedScopes
    }
    $identity = Get-HarnessSha256Text -Content ("dev-harness:protected-operation:v1`n" + ($identityInput | ConvertTo-Json -Depth 20 -Compress))
    return [ordered]@{schema_version='protected-operation/v1';environment=$normalizedEnvironment;action_category=$ActionCategory;targets=$normalizedTargets;approval_type=$ApprovalType;approval_scope=$normalizedScopes;identity=$identity}
}

function Resolve-HarnessProtectedOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$TaskVersion,
        [Parameter(Mandatory)][string]$ContractDigest,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Operation,
        [string]$Label='protected operation'
    )
    $expectedKeys=@('schema_version','environment','action_category','targets','approval_type','approval_scope','identity')
    $actualKeys=@($Operation.Keys|ForEach-Object{[string]$_})
    if(@($expectedKeys|Where-Object{$actualKeys-cnotcontains$_}).Count-or@($actualKeys|Where-Object{$expectedKeys-cnotcontains$_}).Count){throw "$Label keys are invalid"}
    if([string]$Operation.schema_version-cne'protected-operation/v1'){throw "$Label schema_version is invalid"}
    $resolved=New-HarnessProtectedOperation -TaskVersion $TaskVersion -ContractDigest $ContractDigest -Environment ([string]$Operation.environment) -ActionCategory ([string]$Operation.action_category) -Targets @($Operation.targets) -ApprovalType ([string]$Operation.approval_type) -ApprovalScope @($Operation.approval_scope)
    if(($Operation|ConvertTo-Json -Depth 20 -Compress)-cne($resolved|ConvertTo-Json -Depth 20 -Compress)){throw "$Label is not canonical or its identity is invalid"}
    return $resolved
}

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
    if ($approval.Contains('protected_operation')) {
        $operation=Resolve-HarnessProtectedOperation -TaskVersion ([int]$approval.task_version) -ContractDigest ([string]$approval.contract_digest) -Operation $approval.protected_operation -Label 'Approval protected_operation'
        if ([string]$approval.approval_type -cne [string]$operation.approval_type -or @($operation.approval_scope|Where-Object{@($approval.approved_scope)-cnotcontains$_}).Count -gt 0) { throw 'Approval protected_operation type or scope is inconsistent' }
    }
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
        [string]$RequiredType='',[string[]]$RequiredScopes=@(),[AllowNull()][System.Collections.IDictionary]$RequiredOperation=$null,
        [Parameter(Mandatory)][datetimeoffset]$AsOf
    )
    $expectedOperation=$null
    if($null-ne$RequiredOperation){
        $expectedOperation=Resolve-HarnessProtectedOperation -TaskVersion ([int]$Task.version) -ContractDigest ([string]$Task.contract_digest) -Operation $RequiredOperation -Label 'required protected_operation'
        if(-not[string]::IsNullOrWhiteSpace($RequiredType)-and$RequiredType-cne[string]$expectedOperation.approval_type){throw 'required Approval type conflicts with protected_operation'}
        $RequiredType=[string]$expectedOperation.approval_type;$RequiredScopes=@($expectedOperation.approval_scope)
    }
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
        $approvalOperation=$null
        if($approval.Contains('protected_operation')){$approvalOperation=Resolve-HarnessProtectedOperation -TaskVersion ([int]$approval.task_version) -ContractDigest ([string]$approval.contract_digest) -Operation $approval.protected_operation -Label 'task Approval protected_operation'}
        if($null-ne$expectedOperation-and($null-eq$approvalOperation-or[string]$approvalOperation.identity-cne[string]$expectedOperation.identity)){continue}
        return [pscustomobject]@{Path=$loaded.Path;Document=$approval;Digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $loaded.Path);ProtectedOperation=$approvalOperation}
    }
    throw ("no current granted Approval covers the required task version, Contract, type, and scope; required_type={0}; required_scopes={1}" -f $RequiredType,($RequiredScopes -join ','))
}

function Assert-HarnessTaskApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Task,
        [string]$RequiredType='',[string[]]$RequiredScopes=@(),[AllowNull()][System.Collections.IDictionary]$RequiredOperation=$null
    )
    return Assert-HarnessTaskApprovalCore -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $Task -RequiredType $RequiredType -RequiredScopes $RequiredScopes -RequiredOperation $RequiredOperation -AsOf ([datetimeoffset]::UtcNow)
}

Export-ModuleMember -Function New-HarnessProtectedOperation,Resolve-HarnessProtectedOperation,Resolve-HarnessApprovalInput,Assert-HarnessTaskApproval
