Import-Module (Join-Path $PSScriptRoot 'Harness.ProtectedAction.psm1') -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')
$script:ProtectedActionModule = @(Get-Module Harness.ProtectedAction)[-1]

function Assert-HarnessControlledPreimage {
    param([string]$WorkspaceRoot,[string]$Path,[string]$ExpectedCurrentDigest)
    if($(if($ExpectedCurrentDigest-ceq'missing'){$null-ne(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $Path)}else{$ExpectedCurrentDigest-cne(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $Path)})){throw 'controlled write target digest changed before authorization'}
}

function Assert-HarnessControlledGovernanceBinding {
    param(
        [string]$RepoRoot,[string]$WorkspaceRoot,[string]$TargetRelative,[string]$TaskId,[Nullable[int]]$ExpectedVersion,
        [string]$ExecutionProfile,[string]$ContractPath,[string]$ContractDigest,[string]$ApprovalId,
        [Nullable[bool]]$DryRun,$Guard
    )
    if(@($TaskId,$ExecutionProfile,$ContractPath,$ContractDigest,$ApprovalId).Where({[string]::IsNullOrWhiteSpace([string]$_)}).Count-or$null-eq$ExpectedVersion-or$null-eq$DryRun){throw 'protected controlled write requires explicit task, version, profile, Contract, Approval, and dry-run metadata'}
    $task=& $script:ProtectedActionModule {param($Root,$Workspace,$Id)Read-HarnessProtectedTask -RepoRoot $Root -WorkspaceRoot $Workspace -TaskId $Id} $RepoRoot $WorkspaceRoot $TaskId
    if([int]$task.version-ne[int]$ExpectedVersion){throw "controlled write task version is stale: expected=$ExpectedVersion actual=$($task.version)"}
    if([string]$task.execution_profile-cne$ExecutionProfile){throw 'controlled write execution profile does not match the task'}
    if([string]$task.contract_digest-cne$ContractDigest){throw 'controlled write Contract digest does not match the task'}
    $taskContractRelative=Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$task.contract_path) -Label 'controlled write task Contract' -MustExist File)
    if($taskContractRelative-cne(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $ContractPath -Label 'controlled write Contract binding' -MustExist File))){throw 'controlled write Contract path does not match the task'}
    if($TargetRelative-ceq$taskContractRelative){throw 'controlled writer cannot modify the Contract authorizing its request'}
    if($ApprovalId-cne$(if($null-eq$Guard.approval_id){'none'}else{[string]$Guard.approval_id})){throw 'controlled write Approval binding does not match the authorization result'}
}

function Invoke-HarnessControlledWrite {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')][string]$ExpectedSourceDigest,
        [Parameter(Mandatory)][ValidatePattern('^(?:missing|sha256:[0-9a-f]{64})$')][string]$ExpectedCurrentDigest,
        [string]$Environment='',
        [string]$TaskId='',
        [Nullable[int]]$ExpectedVersion=$null,
        [string]$ExecutionProfile='',
        [string]$ContractPath='',
        [string]$ContractDigest='',
        [string]$ApprovalId='',
        [Nullable[bool]]$DryRun=$null
    )
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
    $WorkspaceRoot=Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    if([string]::IsNullOrWhiteSpace($Path)-or[IO.Path]::IsPathRooted($Path)){throw 'controlled write path must be a non-empty workspace-relative path'}
    if($Path.Contains(':')){throw 'controlled writer refuses alternate data stream paths'}
    $relative=Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $Path
    if($relative.ToLowerInvariant()-ceq'agents.md'-or@('.assistant','.codex','.git','docs/tasks').Where({$relative.ToLowerInvariant()-ceq$_-or$relative.ToLowerInvariant().StartsWith("$_/")}).Count){throw "controlled writer refuses Harness control path: $relative"}
    $physicalRepo=Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $RepoRoot
    $physicalTarget=[IO.Path]::GetFullPath((Join-Path (Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $WorkspaceRoot) $relative))
    if($physicalTarget.Equals($physicalRepo,[StringComparison]::OrdinalIgnoreCase)-or `
        $physicalTarget.StartsWith($physicalRepo.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'controlled writer cannot modify its RepoRoot trust boundary'}
    if((Get-HarnessSha256Text -Content $Content)-cne$ExpectedSourceDigest){throw 'controlled write source digest does not match content'}
    $workspaceIdentity=Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot
    $writerMutex,$taskMutex=$null,$null
    try{
        $writerMutex=Enter-HarnessKernelMutex -Name (Get-HarnessKernelMutexName -WorkspaceIdentity $workspaceIdentity -Suffix 'writer') -Label 'controlled-write'
        if((Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot)-cne$workspaceIdentity){throw 'WorkspaceRoot physical identity changed during controlled write'}
        Assert-HarnessControlledPreimage -WorkspaceRoot $WorkspaceRoot -Path $relative -ExpectedCurrentDigest $ExpectedCurrentDigest
        if(-not[string]::IsNullOrWhiteSpace($TaskId)){$taskMutex=Enter-HarnessKernelMutex -Name (Get-HarnessKernelMutexName -WorkspaceIdentity $workspaceIdentity -Suffix state) -Label 'controlled-write'}
        $guardArgs=@{RepoRoot=$RepoRoot;WorkspaceRoot=$WorkspaceRoot;
            SessionMode='write';ActionMode='write';
            ChangedPaths=@($relative);Environment=$Environment;
            TaskId=$TaskId;ExpectedVersion=$ExpectedVersion}
        $bindingArgs=@{RepoRoot=$RepoRoot;WorkspaceRoot=$WorkspaceRoot;TargetRelative=$relative
            TaskId=$TaskId;ExpectedVersion=$ExpectedVersion;ExecutionProfile=$ExecutionProfile
            ContractPath=$ContractPath;ContractDigest=$ContractDigest;ApprovalId=$ApprovalId
            DryRun=$DryRun}
        if($DryRun-eq$true){$guardArgs.DryRun=$true}
        $guard=Assert-HarnessProtectedAction @guardArgs
        if([bool]$guard.protected){
            Assert-HarnessControlledGovernanceBinding @bindingArgs -Guard $guard
        }elseif(-not[string]::IsNullOrWhiteSpace($TaskId)-or$null-ne$ExpectedVersion-or-not[string]::IsNullOrWhiteSpace($ExecutionProfile)-or-not[string]::IsNullOrWhiteSpace($ContractPath)-or-not[string]::IsNullOrWhiteSpace($ContractDigest)-or-not[string]::IsNullOrWhiteSpace($ApprovalId)){
            throw 'ordinary controlled write must not carry protected governance metadata'
        }
        $response=[ordered]@{written=$false;dry_run=$true;path=$relative
            digest=$ExpectedSourceDigest;protected=[bool]$guard.protected;matched_rules=@($guard.matched_rules)
            approval_id=$guard.approval_id;operation_identity=$guard.operation_identity;protected_operation=$guard.protected_operation}
        if($DryRun-eq$true){
            Assert-HarnessControlledPreimage -WorkspaceRoot $WorkspaceRoot -Path $relative -ExpectedCurrentDigest $ExpectedCurrentDigest
            return $response
        }
        if((Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot)-cne$workspaceIdentity){throw 'WorkspaceRoot physical identity changed during controlled write'}
        $finalGuard=Assert-HarnessProtectedAction @guardArgs
        if(-not(Test-HarnessKernelValueEqual -Left $guard -Right $finalGuard)){throw 'controlled write authorization changed before publish'}
        if([bool]$finalGuard.protected){Assert-HarnessControlledGovernanceBinding @bindingArgs -Guard $finalGuard}
        $response.written,$response.dry_run,$response.digest=$true,$false,(Write-HarnessKernelBytesCas -WorkspaceRoot $WorkspaceRoot -Path $relative -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Content)) -SourceDigest $ExpectedSourceDigest -CurrentDigest $ExpectedCurrentDigest)
        return $response
    }finally{
        Exit-HarnessKernelMutex -Mutex $taskMutex
        Exit-HarnessKernelMutex -Mutex $writerMutex
    }
}

Export-ModuleMember -Function Invoke-HarnessControlledWrite
