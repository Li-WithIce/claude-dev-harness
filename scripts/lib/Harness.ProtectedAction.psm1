. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')

$script:PolicyModule = Import-Module (Join-Path $PSScriptRoot 'Harness.Policy.psm1') -Force -PassThru -ErrorAction Stop

function Read-HarnessProtectedPolicy {
    param([string]$RepoRoot,[string]$WorkspaceRoot)
    if(-not(Test-Path -LiteralPath (Join-Path $RepoRoot 'policies\protected-actions.json') -PathType Leaf)){throw 'protected action policy is unavailable'}
    try{$policy=& $script:PolicyModule {param($Root)(Read-ExecutionPolicies -RepoRoot $Root).Protected} $RepoRoot}catch{throw "protected action policy is invalid: $($_.Exception.Message)"}
    $overlayPath = Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path '.assistant/policies/protected-actions.local.json' -Label 'protected action overlay' -AllowMissing
    if (Test-Path -LiteralPath $overlayPath) {
        if (-not (Test-Path -LiteralPath $overlayPath -PathType Leaf)) { throw 'protected action overlay is invalid: path is not a file' }
        try { $overlay = Read-HarnessKernelJsonPath -Path $overlayPath -Label 'protected action overlay' } catch { throw "protected action overlay is invalid: $($_.Exception.Message)" }
        $overlaySchema = Join-Path $RepoRoot 'schemas\protected-actions-overlay.schema.json'
        try { $overlayValid = Test-Json -Json ($overlay | ConvertTo-Json -Depth 30 -Compress) -SchemaFile $overlaySchema -ErrorAction Stop -WarningAction SilentlyContinue } catch { throw "protected action overlay schema is unavailable: $($_.Exception.Message)" }
        if (-not $overlayValid) { throw 'protected action overlay failed schema validation' }
        $knownIds = [Collections.Generic.HashSet[string]]::new([string[]]@($policy.rules|ForEach-Object{[string]$_.id}),[StringComparer]::Ordinal)
        foreach ($rule in @($overlay.rules)) {
            if($rule.match.Contains('command_regex')){try{[void][regex]::new([string]$rule.match.command_regex)}catch{throw 'protected action overlay is invalid: command_regex'}}
            if (-not $knownIds.Add([string]$rule.id)) { throw 'protected action overlay rule id collides with another rule' }
            $policy.rules += @($rule)
        }
    }
    return $policy
}

function Read-HarnessProtectedTask {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$TaskId)
    Assert-HarnessTaskId -TaskId $TaskId
    try{
        $task=(Read-HarnessKernelJson -WorkspaceRoot $WorkspaceRoot -Path ".assistant/runtime/tasks/$TaskId/task.json" -Label 'protected task' -RepoRoot $RepoRoot -Schema task-state.schema.json -Depth 30).Document
    }catch{throw "protected task is invalid: $($_.Exception.Message)"}
    if([string]$task.task_id-cne$TaskId){throw 'protected task task_id does not match its canonical path'}
    try{$contract=Resolve-HarnessRequirementContract -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Path $task.contract_path -Label 'protected task Contract'}catch{
        $detail=$_.Exception.Message
        throw $(if($detail-match'digest does not match canonical content'){'protected task Contract digest is stale'}else{"protected task Contract is invalid: $detail"})
    }
    if([string]$task.contract_digest-cne[string]$contract.Digest){throw 'protected task Contract digest is stale'}
    return $task
}

function Assert-HarnessProtectedAction {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,
        [ValidateSet('read-only','write')][string]$SessionMode='write',[ValidateSet('read','write')][string]$ActionMode='read',
        [string]$TaskId='',[Nullable[int]]$ExpectedVersion=$null,[string]$CommandText='',[string[]]$ChangedPaths=@(),[string]$Environment='',[switch]$DryRun,[string]$UserInstruction=''
    )
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if($SessionMode-ceq'read-only'-and$ActionMode-ceq'write'){throw 'read-only session cannot invoke a write tool'}
    if($ActionMode-ceq'read'){return [ordered]@{allowed=$true;protected=$false;matched_rules=@();required_scopes=@();approval_id=$null;operation_identity=$null;protected_operation=$null}}
    $policy=Read-HarnessProtectedPolicy -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
    $normalizedPaths=@($ChangedPaths|ForEach-Object{
        $resolved=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $_ -Label 'protected action path' -AllowMissing
        (Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $resolved).Replace('\','/')
    })
    $matched,$scopes=[Collections.Generic.List[object]]::new(),[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($rule in @($policy.rules)){
        $match=Resolve-HarnessProtectedRuleMatch -Rule $rule -CommandText $CommandText -Paths @($normalizedPaths) -Environment $Environment -RequireTrustedEnvironment
        if($null-eq$match){continue}
        $matched.Add($rule)
        [void]$scopes.Add("rule:$($rule.id)")
        if($rule.match.Contains('command_regex')){[void]$scopes.Add("command_digest:$((Get-HarnessSha256Text -Content $CommandText))")}
        if($rule.match.Contains('environment')){[void]$scopes.Add("environment:$Environment")}
        foreach($path in $match.Paths){[void]$scopes.Add("path:$path")}
        if($rule.requires_dry_run-eq$true){[void]$scopes.Add('dry-run:true')}
    }
    if($matched.Count-eq0){return [ordered]@{allowed=$true;protected=$false;matched_rules=@();required_scopes=@();approval_id=$null;operation_identity=$null;protected_operation=$null}}
    $requiredTypes=@($matched|ForEach-Object{[string]$_.requires_approval}|Where-Object{$_-cne'none'}|Sort-Object -Unique)
    if($requiredTypes.Count-gt1){throw 'matched protected rules require conflicting Approval types'}
    $requiredType=$(if($requiredTypes.Count-eq1){[string]$requiredTypes[0]}else{''})
    if([string]::IsNullOrWhiteSpace($TaskId)-or$null-eq$ExpectedVersion){throw 'protected write requires TaskId and ExpectedVersion'}
    $task=Read-HarnessProtectedTask -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    if([int]$task.version-ne[int]$ExpectedVersion){throw "protected task version is stale: expected=$ExpectedVersion actual=$($task.version)"}
    if([string]$task.requirement_state-cne'clear'){throw 'protected write requires a clear Requirement'}
    if(@($matched|Where-Object requires_independent_review -eq $true).Count-and-not[bool]$task.policies.independent_review_required){throw 'protected write requires independent review policy'}
    if(@($matched|Where-Object requires_dry_run -eq $true).Count-and-not$DryRun){throw 'protected write requires dry-run'}
    $requiredProfile=$(if(@($matched.requires_profile)-ccontains'critical'){'critical'}else{'governed'})
    if(@{governed=1;critical=2}[[string]$task.execution_profile]-lt@{governed=1;critical=2}[$requiredProfile]){throw 'protected write task profile is insufficient'}
    $operation=New-HarnessProtectedOperation -TaskVersion ([int]$task.version) -ContractDigest ([string]$task.contract_digest) -Environment $(if([string]::IsNullOrWhiteSpace($Environment)){'workspace'}else{$Environment}) -ActionCategory protected-write -Targets $(if($normalizedPaths.Count){@($normalizedPaths)}else{@('workspace')}) -ApprovalType $(if([string]::IsNullOrWhiteSpace($requiredType)){'none'}else{$requiredType}) -ApprovalScope @($scopes)
    $approval=if([string]::IsNullOrWhiteSpace($requiredType)){$null}else{
        if(-not[bool]$task.policies.approval_required){throw 'protected write requires approval policy'}
        Assert-HarnessTaskApproval -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Task $task -RequiredOperation $operation
    }
    return [ordered]@{allowed=$true;protected=$true;matched_rules=@($matched|ForEach-Object{[string]$_.id});required_scopes=@($scopes|Sort-Object);approval_id=$(if($null-ne$approval){[string]$approval.Document.approval_id}else{$null});operation_identity=[string]$operation.identity;protected_operation=$operation}
}

Export-ModuleMember -Function Assert-HarnessProtectedAction
