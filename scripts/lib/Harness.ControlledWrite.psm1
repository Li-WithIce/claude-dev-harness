Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Harness.Path.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.AtomicWrite.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'Harness.ProtectedAction.psm1') -ErrorAction Stop
$script:AtomicWriteModule = Get-Module -Name Harness.AtomicWrite -ErrorAction Stop

function Test-HarnessControlledPathAtOrBelow {
    param([string]$Path,[string]$Root)
    $candidate=[IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $boundary=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    return $candidate.Equals($boundary,[StringComparison]::OrdinalIgnoreCase)-or$candidate.StartsWith($boundary+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
}

function Assert-HarnessControlledTarget {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)-or[IO.Path]::IsPathRooted($Path)){throw 'controlled write path must be a non-empty workspace-relative path'}
    $full=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label 'controlled write target' -AllowMissing
    $relative=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $full).Replace('\','/')
    $lower=$relative.ToLowerInvariant()
    if($lower -ceq 'agents.md'-or$lower -ceq '.assistant'-or$lower.StartsWith('.assistant/')-or$lower -ceq '.codex'-or$lower.StartsWith('.codex/')-or$lower -ceq '.git'-or$lower.StartsWith('.git/')-or$lower -ceq 'docs/tasks'-or$lower.StartsWith('docs/tasks/')){throw "controlled writer refuses Harness control path: $relative"}
    $physicalWorkspace=Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $physicalRepo=Resolve-HarnessToolCompatibleWorkspaceRoot -WorkspaceRoot $RepoRoot
    $physicalTarget=[IO.Path]::GetFullPath((Join-Path $physicalWorkspace $relative))
    if(Test-HarnessControlledPathAtOrBelow -Path $physicalTarget -Root $physicalRepo){throw 'controlled writer cannot modify its RepoRoot trust boundary'}
    return [pscustomobject]@{FullPath=$full;RelativePath=$relative}
}

function Get-HarnessControlledMutexName {
    param([string]$WorkspaceIdentity,[string]$Suffix)
    $hash=(Get-HarnessSha256Text -Content $WorkspaceIdentity).Substring(7,16)
    return "Global\dev-harness.v2.$hash.$Suffix"
}

function Enter-HarnessControlledMutex {
    param([string]$Name,[int]$TimeoutMilliseconds=10000)
    $mutex=[Threading.Mutex]::new($false,$Name)
    try{
        try{$acquired=$mutex.WaitOne($TimeoutMilliseconds)}catch [Threading.AbandonedMutexException]{$acquired=$true}
        if(-not$acquired){throw "timed out waiting for controlled-write mutex: $Name"}
        return $mutex
    }catch{$mutex.Dispose();throw}
}

function Exit-HarnessControlledMutex {
    param([Threading.Mutex]$Mutex)
    if($null-eq$Mutex){return}
    try{[void]$Mutex.ReleaseMutex()}finally{$Mutex.Dispose()}
}

function Read-HarnessControlledTask {
    param([string]$WorkspaceRoot,[string]$TaskId)
    Assert-HarnessTaskId -TaskId $TaskId
    $relative=".assistant/runtime/tasks/$TaskId/task.json"
    $path=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $relative -Label 'controlled write task' -MustExist File
    try{$task=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-HarnessJson -ErrorAction Stop}catch{throw "controlled write task is invalid: $($_.Exception.Message)"}
    if([string]$task.task_id-cne$TaskId){throw 'controlled write task_id does not match its canonical path'}
    return $task
}

function Assert-HarnessControlledGovernanceBinding {
    param(
        [string]$WorkspaceRoot,[string]$TargetRelative,[string]$TaskId,[Nullable[int]]$ExpectedVersion,
        [string]$ExecutionProfile,[string]$ContractPath,[string]$ContractDigest,[string]$ApprovalId,
        [Nullable[bool]]$DryRun,$Guard
    )
    if([string]::IsNullOrWhiteSpace($TaskId)-or$null-eq$ExpectedVersion-or[string]::IsNullOrWhiteSpace($ExecutionProfile)-or[string]::IsNullOrWhiteSpace($ContractPath)-or[string]::IsNullOrWhiteSpace($ContractDigest)-or[string]::IsNullOrWhiteSpace($ApprovalId)-or$null-eq$DryRun){throw 'protected controlled write requires explicit task, version, profile, Contract, Approval, and dry-run metadata'}
    $task=Read-HarnessControlledTask -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    if([int]$task.version-ne[int]$ExpectedVersion){throw "controlled write task version is stale: expected=$ExpectedVersion actual=$($task.version)"}
    if([string]$task.execution_profile-cne$ExecutionProfile){throw 'controlled write execution profile does not match the task'}
    if([string]$task.contract_digest-cne$ContractDigest){throw 'controlled write Contract digest does not match the task'}
    $taskContractFull=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path ([string]$task.contract_path) -Label 'controlled write task Contract' -MustExist File
    $inputContractFull=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $ContractPath -Label 'controlled write Contract binding' -MustExist File
    $taskContractRelative=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $taskContractFull).Replace('\','/')
    $inputContractRelative=(Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path $inputContractFull).Replace('\','/')
    if($taskContractRelative-cne$inputContractRelative){throw 'controlled write Contract path does not match the task'}
    if($TargetRelative-ceq$taskContractRelative){throw 'controlled writer cannot modify the Contract authorizing its request'}
    $expectedApproval=$(if($null-eq$Guard.approval_id){'none'}else{[string]$Guard.approval_id})
    if($ApprovalId-cne$expectedApproval){throw 'controlled write Approval binding does not match the authorization result'}
}

function Invoke-HarnessControlledWrite {
    [CmdletBinding()]
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
    $target=Assert-HarnessControlledTarget -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -Path $Path
    $sourceBytes=[Text.UTF8Encoding]::new($false).GetBytes($Content)
    if((Get-HarnessSha256Text -Content $Content)-cne$ExpectedSourceDigest){throw 'controlled write source digest does not match content'}
    $workspaceIdentity=Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot
    $writerMutex=$null;$taskMutex=$null
    try{
        $writerMutex=Enter-HarnessControlledMutex -Name (Get-HarnessControlledMutexName -WorkspaceIdentity $workspaceIdentity -Suffix 'writer')
        if((Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot)-cne$workspaceIdentity){throw 'WorkspaceRoot physical identity changed during controlled write'}
        if(-not[string]::IsNullOrWhiteSpace($TaskId)){$taskMutex=Enter-HarnessControlledMutex -Name (Get-HarnessControlledMutexName -WorkspaceIdentity $workspaceIdentity -Suffix "task.$TaskId")}
        $guardArgs=@{RepoRoot=$RepoRoot;WorkspaceRoot=$WorkspaceRoot;SessionMode='write';ActionMode='write';ChangedPaths=@($target.RelativePath);Environment=$Environment;TaskId=$TaskId;ExpectedVersion=$ExpectedVersion}
        if($DryRun-eq$true){$guardArgs.DryRun=$true}
        $guard=Assert-HarnessProtectedAction @guardArgs
        if([bool]$guard.protected){
            Assert-HarnessControlledGovernanceBinding -WorkspaceRoot $WorkspaceRoot -TargetRelative $target.RelativePath -TaskId $TaskId -ExpectedVersion $ExpectedVersion -ExecutionProfile $ExecutionProfile -ContractPath $ContractPath -ContractDigest $ContractDigest -ApprovalId $ApprovalId -DryRun $DryRun -Guard $guard
        }elseif(-not[string]::IsNullOrWhiteSpace($TaskId)-or$null-ne$ExpectedVersion-or-not[string]::IsNullOrWhiteSpace($ExecutionProfile)-or-not[string]::IsNullOrWhiteSpace($ContractPath)-or-not[string]::IsNullOrWhiteSpace($ContractDigest)-or-not[string]::IsNullOrWhiteSpace($ApprovalId)){
            throw 'ordinary controlled write must not carry protected governance metadata'
        }
        if($DryRun-eq$true){return [ordered]@{written=$false;dry_run=$true;path=$target.RelativePath;digest=$ExpectedSourceDigest;protected=[bool]$guard.protected;matched_rules=@($guard.matched_rules);approval_id=$guard.approval_id}}
        if((Get-HarnessPhysicalPathIdentity -Path $WorkspaceRoot)-cne$workspaceIdentity){throw 'WorkspaceRoot physical identity changed during controlled write'}
        $finalGuard=Assert-HarnessProtectedAction @guardArgs
        if(($guard|ConvertTo-Json -Depth 20 -Compress)-cne($finalGuard|ConvertTo-Json -Depth 20 -Compress)){throw 'controlled write authorization changed before publish'}
        if([bool]$finalGuard.protected){Assert-HarnessControlledGovernanceBinding -WorkspaceRoot $WorkspaceRoot -TargetRelative $target.RelativePath -TaskId $TaskId -ExpectedVersion $ExpectedVersion -ExecutionProfile $ExecutionProfile -ContractPath $ContractPath -ContractDigest $ContractDigest -ApprovalId $ApprovalId -DryRun $DryRun -Guard $finalGuard}
        $digest=& $script:AtomicWriteModule {param($Root,$Bytes,$TargetPath,$SourceDigest,$CurrentDigest) Write-HarnessAtomicBytes -WorkspaceRoot $Root -SourceBytes $Bytes -Path $TargetPath -ExpectedSourceDigest $SourceDigest -ExpectedCurrentDigest $CurrentDigest} $WorkspaceRoot $sourceBytes $target.RelativePath $ExpectedSourceDigest $ExpectedCurrentDigest
        return [ordered]@{written=$true;dry_run=$false;path=$target.RelativePath;digest=$digest;protected=[bool]$finalGuard.protected;matched_rules=@($finalGuard.matched_rules);approval_id=$finalGuard.approval_id}
    }finally{
        Exit-HarnessControlledMutex -Mutex $taskMutex
        Exit-HarnessControlledMutex -Mutex $writerMutex
    }
}

Export-ModuleMember -Function Invoke-HarnessControlledWrite
