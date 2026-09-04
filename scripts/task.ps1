[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = '',
    [string]$RequestFile = '',
    [string]$TaskId = '',
    [string]$Contract = '',
    [ValidateSet('governed', 'critical')][string]$Profile = 'governed',
    [string[]]$Capabilities = @(),
    [Nullable[int]]$ExpectedVersion = $null,
    [ValidateSet('blocked', 'ready', 'running', 'verifying', 'paused', 'done', 'failed', 'cancelled')][string]$To = 'ready',
    [string]$Reason = '',
    [switch]$ActivateCurrent,
    [switch]$EvidenceSatisfied,
    [string]$Evidence = '',
    [string]$Approval = '',
    [string]$TransactionId = '',
    [string]$ActorHost = 'codex',
    [string]$ActorModel = 'inherit',
    [string]$RepoRoot = '',
    [string]$WorkspaceRoot = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Split-Path -Parent $PSScriptRoot}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
    . (Join-Path $RepoRoot 'scripts\lib\Harness.RuntimeKernel.ps1')
    if([string]::IsNullOrWhiteSpace($WorkspaceRoot)){$WorkspaceRoot=$RepoRoot}
    $WorkspaceRoot=(Resolve-Path -LiteralPath $WorkspaceRoot).Path
    if($EvidenceSatisfied){throw '-EvidenceSatisfied was removed; use verify -Evidence'}
    if($Command-ceq'resume'-or($Command-ceq'status'-and[string]::IsNullOrWhiteSpace($TaskId))){
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Recovery.psm1') -Force -ErrorAction Stop
    }elseif($Command-cnotin @('inspect','replay')){
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Protocol.psm1') -Force -ErrorAction Stop
    }

    if($Command-cin @('enable-v2','reset-auto','disable-v2')){
        $result=Set-HarnessWorkspaceProtocolConfig -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -NewTaskProtocol $(if($Command-ceq'reset-auto'){'auto'}else{'v2'}) -PauseNewWork:($Command-ceq'disable-v2')
    }elseif($Command-ceq'protocol'){
        $result=Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    }elseif($Command-ceq'inspect'){
        if([string]::IsNullOrWhiteSpace($RequestFile)){throw 'inspect requires -RequestFile'}
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Requirement.psm1') -Force -ErrorAction Stop
        $result=Invoke-RequirementInspection -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -RequestFile $RequestFile
    }elseif($Command-ceq'status'-and[string]::IsNullOrWhiteSpace($TaskId)){
        $result=Get-HarnessRecoveryIndex -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot
    }elseif($Command-ceq'resume'){
        $result=Get-HarnessResumeClarification -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    }else{
        if($Command-cne'replay'){
            $protocol=Get-HarnessProtocolResolution -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
            if([string]$protocol.selected_protocol-cne'v2'){
                throw "new-work-not-admitted: $($protocol.reason); recover existing v2 tasks or explicitly repair admission"
            }
        }
        $env:HARNESS_PROTOCOL='v2'
        Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.TaskState.psm1') -Force -ErrorAction Stop
        $required=@{create=@($Contract,' and -Contract');verify=@($Evidence,' and -Evidence');approve=@($Approval,' and -Approval')}
        if($Command-cin @('create','verify','approve','transition','resume-and-execute') -and ([string]::IsNullOrWhiteSpace($TaskId) -or ($required.ContainsKey($Command)-and[string]::IsNullOrWhiteSpace([string]$required[$Command][0])))){
            throw "$Command requires -TaskId$(if($required.ContainsKey($Command)){$required[$Command][1]}else{''})"
        }
        $arguments=@{
            RepoRoot=$RepoRoot
            WorkspaceRoot=$WorkspaceRoot
            TaskId=$TaskId
            ActorHost=$ActorHost
            ActorModel=$ActorModel
        }
        if($Command-cin @('transition','verify','approve','resume-and-execute')){
            $version=$ExpectedVersion
            if($null-eq$version){
                $version=[int](Get-HarnessTaskStatus -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId).task.version
                $names=@('DEV_HARNESS_TEST_TASK_CLI_VERSION_READY_EVENT','DEV_HARNESS_TEST_TASK_CLI_VERSION_RELEASE_EVENT')|ForEach-Object{[Environment]::GetEnvironmentVariable($_,[EnvironmentVariableTarget]::Process)}
                if(@($names|Where-Object{[string]::IsNullOrWhiteSpace($_)}).Count-eq1){throw 'task CLI version test barrier requires both event names'}
                if(-not[string]::IsNullOrWhiteSpace($names[0])){
                    $events=@($names|ForEach-Object{[Threading.EventWaitHandle]::OpenExisting($_)})
                    try{
                        [void]$events[0].Set()
                        if(-not$events[1].WaitOne(10000)){throw 'task CLI version test barrier timed out'}
                    }finally{
                        $events|ForEach-Object{$_.Dispose()}
                    }
                }
            }
            $arguments.ExpectedVersion=[int]$version
        }
        switch($Command){
            'create' {$result=New-HarnessTaskState @arguments -ContractPath $Contract -Profile $Profile -Capabilities $Capabilities -ActivateCurrent:$ActivateCurrent}
            'status' {$result=Get-HarnessTaskStatus -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId}
            'transition' {$result=Set-HarnessTaskTransition @arguments -To $To -Reason $Reason -ContractPath $Contract -EvidenceSatisfied:$EvidenceSatisfied}
            'verify' {$result=Set-HarnessTaskEvidence @arguments -EvidencePath $Evidence}
            'approve' {$result=Set-HarnessTaskApproval @arguments -ApprovalPath $Approval}
            'resume-and-execute' {$result=Resume-HarnessTaskExecution @arguments}
            'replay' {
                if([string]::IsNullOrWhiteSpace($TransactionId)){throw 'replay requires -TransactionId'}
                $result=Repair-HarnessTaskTransaction -WorkspaceRoot $WorkspaceRoot -TransactionId $TransactionId
            }
            default {throw "unsupported task command: $Command"}
        }
    }

    if($AsJson){
        Write-Output ($result|ConvertTo-Json -Depth 30 -Compress)
        exit 0
    }
    $taskProjection=@('operation=operation','task_id=task.task_id','version=task.version','status=task.status')
    $projectionMap=@{
        inspect=@('requirement_state=requirement_state','blocking_decisions=blocking_decisions|count','contract_digest=contract.digest|none')
        config=@('operation=operation','action=action','new_task_protocol=new_task_protocol','new_work=new_work','path=path')
        protocol=@('task_id=task_id|none','requested_protocol=requested_protocol','detected_protocol=detected_protocol','selected_protocol=selected_protocol','new_task_admission=new_task_admission',
            'preference_source=preference_source','default_source=default_source','reason=reason','workspace_config=workspace_config.new_task_protocol','runtime_default=runtime_default_decision.status')
        recovery=@('current_task=current.task_id|none','recoverable_tasks=tasks|count','terminal_tasks=terminal_task_count','runtime_writes=side_effects.runtime_writes')
        status=@('task_id=task.task_id','status=task.status','is_current=is_current|bool','pending_transactions=pending_transactions|count')
        resume=@('requirement_state=requirement_state','write_authorized=write_authorized|bool','blocking_decision=blocking_decision')
        replay=@('transaction_id=transaction_id','result=result')
        create=$taskProjection+@('pointer_action=pointer_action')
        transition=$taskProjection+@('pointer_action=pointer_action')
        verify=$taskProjection+@('conclusion=conclusion','evidence_path=evidence_path','pointer_action=pointer_action')
        approve=$taskProjection+@('approval_id=approval_id','approval_path=approval_path','pointer_action=pointer_action')
        'resume-and-execute'=$taskProjection+@('write_authorized=write_authorized|bool','pointer_action=pointer_action')
    }
    Write-HarnessKernelProjection $result $projectionMap[$(if($Command-cin @('enable-v2','reset-auto','disable-v2')){'config'}elseif($Command-ceq'status'-and[string]$result.operation-ceq'recovery-index'){'recovery'}else{$Command})]
    if($Command-ceq'protocol'-and-not[string]::IsNullOrWhiteSpace([string]$result.warning)){Write-Output ('warning: {0}' -f $result.warning)}
    if($Command-ceq'protocol'){Write-Output 'runtime_writes: 0'}
    exit 0
}catch{
    $message=[string]$_.Exception.Message
    $conflict=[regex]::Match($message,'^ExpectedVersion mismatch: expected=\d+ actual=(?<actual>\d+)$')
    if($null-eq$ExpectedVersion-and$conflict.Success){
        if($AsJson){
            [Console]::Error.WriteLine(([ordered]@{error='task-version-conflict';current_version=[int]$conflict.Groups['actual'].Value;writes=0}|ConvertTo-Json -Compress))
        }else{
            [Console]::Error.WriteLine("task-version-conflict; current_version=$([int]$conflict.Groups['actual'].Value); task changed concurrently, reread and retry")
        }
    }else{
        [Console]::Error.WriteLine($message)
    }
    exit 2
}
