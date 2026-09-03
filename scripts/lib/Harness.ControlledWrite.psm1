Import-Module (Join-Path $PSScriptRoot 'Harness.ProtectedAction.psm1') -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')
$script:ProtectedActionModule = @(Get-Module Harness.ProtectedAction)[-1]

function Assert-HarnessControlledPreimage {
    param([string]$WorkspaceRoot,[string]$Path,[string]$ExpectedCurrentDigest)
    $actual=Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $Path
    if($(if($ExpectedCurrentDigest-ceq'missing'){$null-ne$actual}else{$null-eq$actual-or$actual-cne$ExpectedCurrentDigest})){throw 'controlled write target digest changed before authorization'}
}

function Assert-HarnessControlledGovernanceBinding {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$TargetRelative,[string]$TaskId,[Nullable[int]]$ExpectedVersion,
        [string]$ExecutionProfile,[string]$ContractPath,[string]$ContractDigest,[string]$ApprovalId,
        [Nullable[bool]]$DryRun,$Guard)
    if([string]::IsNullOrWhiteSpace($TaskId)-or$null-eq$ExpectedVersion-or[string]::IsNullOrWhiteSpace($ExecutionProfile)-or[string]::IsNullOrWhiteSpace($ContractPath)-or[string]::IsNullOrWhiteSpace($ContractDigest)-or[string]::IsNullOrWhiteSpace($ApprovalId)-or$null-eq$DryRun){throw 'protected controlled write requires explicit task, version, profile, Contract, Approval, and dry-run metadata'}
    $task=& $script:ProtectedActionModule {param($Root,$Workspace,$Id)Read-HarnessProtectedTask -RepoRoot $Root -WorkspaceRoot $Workspace -TaskId $Id} $RepoRoot $WorkspaceRoot $TaskId
    if([int]$task.version-ne[int]$ExpectedVersion){throw "controlled write task version is stale: expected=$ExpectedVersion actual=$($task.version)"}
    if([string]$task.execution_profile-cne$ExecutionProfile){throw 'controlled write execution profile does not match the task'}
    if([string]$task.contract_digest-cne$ContractDigest){throw 'controlled write Contract digest does not match the task'}
    $taskContractRelative=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$task.contract_path) -Label 'controlled write task Contract' -MustExist File)).Replace('\','/')
    if($taskContractRelative-cne(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $ContractPath -Label 'controlled write Contract binding' -MustExist File)).Replace('\','/')){throw 'controlled write Contract path does not match the task'}
    if($TargetRelative-ceq$taskContractRelative){throw 'controlled writer cannot modify the Contract authorizing its request'}
    if($ApprovalId-cne$(if($null-eq$Guard.approval_id){'none'}else{[string]$Guard.approval_id})){throw 'controlled write Approval binding does not match the authorization result'}
}

function Invoke-HarnessControlledWrite {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,[Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')][string]$ExpectedSourceDigest,
        [Parameter(Mandatory)][ValidatePattern('^(?:missing|sha256:[0-9a-f]{64})$')][string]$ExpectedCurrentDigest,[string]$Environment='',
        [string]$TaskId='',[Nullable[int]]$ExpectedVersion=$null,[string]$ExecutionProfile='',[string]$ContractPath='',
        [string]$ContractDigest='',[string]$ApprovalId='',
        [Nullable[bool]]$DryRun=$null)
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if([string]::IsNullOrWhiteSpace($Path)-or[IO.Path]::IsPathRooted($Path)){throw 'controlled write path must be a non-empty workspace-relative path'}
    if($Path.Contains(':')){throw 'controlled writer refuses alternate data stream paths'}
    $relative=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'controlled write target' -AllowMissing)).Replace('\','/')
    $lower=$relative.ToLowerInvariant()
    if($lower -ceq 'agents.md'-or$lower -ceq '.assistant'-or$lower.StartsWith('.assistant/')-or$lower -ceq '.codex'-or$lower.StartsWith('.codex/')-or$lower -ceq '.git'-or$lower.StartsWith('.git/')-or$lower -ceq 'docs/tasks'-or$lower.StartsWith('docs/tasks/')){throw "controlled writer refuses Harness control path: $relative"}
    $physicalRepo=Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $RepoRoot
    $physicalTarget=[IO.Path]::GetFullPath((Join-Path (Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $WorkspaceRoot) $relative))
    if($physicalTarget.Equals($physicalRepo,[StringComparison]::OrdinalIgnoreCase)-or$physicalTarget.StartsWith($physicalRepo.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'controlled writer cannot modify its RepoRoot trust boundary'}
    if((Get-HarnessSha256Text -Content $Content)-cne$ExpectedSourceDigest){throw 'controlled write source digest does not match content'}
    $workspaceIdentity=Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot
    $writerMutex=$null
    $taskMutex=$null
    try{
        $writerMutex=Enter-HarnessKernelMutex -Name (Get-HarnessKernelMutexName -WorkspaceIdentity $workspaceIdentity -Suffix 'writer') -Label 'controlled-write'
        if((Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot)-cne$workspaceIdentity){throw 'WorkspaceRoot physical identity changed during controlled write'}
        Assert-HarnessControlledPreimage -WorkspaceRoot $WorkspaceRoot -Path $relative -ExpectedCurrentDigest $ExpectedCurrentDigest
        if(-not[string]::IsNullOrWhiteSpace($TaskId)){$taskMutex=Enter-HarnessKernelMutex -Name (Get-HarnessKernelMutexName -WorkspaceIdentity $workspaceIdentity -Suffix state) -Label 'controlled-write'}
        $guardArgs=@{RepoRoot=$RepoRoot;WorkspaceRoot=$WorkspaceRoot;SessionMode='write';ActionMode='write';ChangedPaths=@($relative);Environment=$Environment;TaskId=$TaskId;ExpectedVersion=$ExpectedVersion}
        if($DryRun-eq$true){$guardArgs.DryRun=$true}
        $guard=Assert-HarnessProtectedAction @guardArgs
        if([bool]$guard.protected){
            Assert-HarnessControlledGovernanceBinding -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TargetRelative $relative -TaskId $TaskId -ExpectedVersion $ExpectedVersion -ExecutionProfile $ExecutionProfile -ContractPath $ContractPath -ContractDigest $ContractDigest -ApprovalId $ApprovalId -DryRun $DryRun -Guard $guard
        }elseif(-not[string]::IsNullOrWhiteSpace($TaskId)-or$null-ne$ExpectedVersion-or-not[string]::IsNullOrWhiteSpace($ExecutionProfile)-or-not[string]::IsNullOrWhiteSpace($ContractPath)-or-not[string]::IsNullOrWhiteSpace($ContractDigest)-or-not[string]::IsNullOrWhiteSpace($ApprovalId)){
            throw 'ordinary controlled write must not carry protected governance metadata'
        }
        if($DryRun-eq$true){
            Assert-HarnessControlledPreimage -WorkspaceRoot $WorkspaceRoot -Path $relative -ExpectedCurrentDigest $ExpectedCurrentDigest
            return [ordered]@{written=$false;dry_run=$true;path=$relative;digest=$ExpectedSourceDigest;protected=[bool]$guard.protected;matched_rules=@($guard.matched_rules);approval_id=$guard.approval_id;operation_identity=$guard.operation_identity;protected_operation=$guard.protected_operation}
        }
        if((Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot)-cne$workspaceIdentity){throw 'WorkspaceRoot physical identity changed during controlled write'}
        $finalGuard=Assert-HarnessProtectedAction @guardArgs
        if(($guard|ConvertTo-Json -Depth 20 -Compress)-cne($finalGuard|ConvertTo-Json -Depth 20 -Compress)){throw 'controlled write authorization changed before publish'}
        if([bool]$finalGuard.protected){Assert-HarnessControlledGovernanceBinding -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TargetRelative $relative -TaskId $TaskId -ExpectedVersion $ExpectedVersion -ExecutionProfile $ExecutionProfile -ContractPath $ContractPath -ContractDigest $ContractDigest -ApprovalId $ApprovalId -DryRun $DryRun -Guard $finalGuard}
        $digest=Write-HarnessKernelBytesCas -WorkspaceRoot $WorkspaceRoot -Path $relative -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Content)) -SourceDigest $ExpectedSourceDigest -CurrentDigest $ExpectedCurrentDigest
        return [ordered]@{written=$true;dry_run=$false;path=$relative;digest=$digest;protected=[bool]$finalGuard.protected;matched_rules=@($finalGuard.matched_rules);approval_id=$finalGuard.approval_id;operation_identity=$finalGuard.operation_identity;protected_operation=$finalGuard.protected_operation}
    }finally{
        Exit-HarnessKernelMutex -Mutex $taskMutex
        Exit-HarnessKernelMutex -Mutex $writerMutex
    }
}

Export-ModuleMember -Function Invoke-HarnessControlledWrite
