$script:TaskStateModule = Import-Module (Join-Path $PSScriptRoot 'Harness.TaskState.psm1') -Force -PassThru -ErrorAction Stop

function Import-HarnessV1TaskState {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Contract,[Parameter(Mandatory)][string]$SourcePlanPath,
        [Parameter(Mandatory)][string]$SourcePlanDigest,[Parameter(Mandatory)][ValidateSet('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST')][string]$SourceStage,
        [Parameter(Mandatory)][string]$DryRunDigest,[string[]]$ImportedHistorySections=@(),[string]$ActorHost='migration',
        [string]$ActorModel='inherit')
    $arguments = $PSBoundParameters
    return & $script:TaskStateModule {
        param($Arguments)
        $RepoRoot = [string]$Arguments.RepoRoot
        $WorkspaceRoot = [string]$Arguments.WorkspaceRoot
        $TaskId = [string]$Arguments.TaskId
        $Contract = $Arguments.Contract
        $SourcePlanPath = [string]$Arguments.SourcePlanPath
        $SourcePlanDigest = [string]$Arguments.SourcePlanDigest
        $SourceStage = [string]$Arguments.SourceStage
        $DryRunDigest = [string]$Arguments.DryRunDigest
        $ImportedHistorySections = @($Arguments.ImportedHistorySections)
        $ActorHost = if ($Arguments.ContainsKey('ActorHost')) { [string]$Arguments.ActorHost } else { 'migration' }
        $ActorModel = if ($Arguments.ContainsKey('ActorModel')) { [string]$Arguments.ActorModel } else { 'inherit' }
        Assert-V2WriteProtocol
        $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
        Assert-HarnessTaskId -TaskId $TaskId
        if ($SourcePlanDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or $DryRunDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'migration digest is invalid' }
        $sourceRelative=Get-HarnessRelativePath -WorkspaceRoot $WorkspaceRoot -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $SourcePlanPath -Label 'v1 source plan' -MustExist File)
        if ((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $sourceRelative) -cne $SourcePlanDigest) { throw 'v1 source plan digest changed before migration' }
        $contractBody = Select-HarnessKernelKeys -Value $Contract -Keys @('schema_version','task_id','goal','acceptance','in_scope','out_of_scope','product_constraints','product_decisions','unresolved_product_decisions','source_authority')
        Assert-HarnessKernelSchema -RepoRoot $script:SchemaRoot -Value $Contract -Schema requirement-contract.schema.json -Label 'Contract'
        Assert-HarnessKernelCondition ([string]$Contract.task_id -ceq $TaskId -and -not @($Contract.unresolved_product_decisions).Count -and [string]$Contract.digest -ceq (Get-HarnessSha256Text -Content ($contractBody | ConvertTo-Json -Depth 30 -Compress))) 'Contract failed migration validation'
        $policies = Get-TaskPolicyFlags -RepoRoot $RepoRoot -Profile governed -Capabilities @()
        $paths = Get-TaskStatePaths -TaskId $TaskId
        return Invoke-TaskStateLocked -WorkspaceRoot $WorkspaceRoot -Action {
            $targetRoot=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $paths.TaskRoot -Label 'v2 migration target' -AllowMissing
            if (Test-Path -LiteralPath $targetRoot) { throw "v2 task already exists: $TaskId" }
            if (@(Get-PendingTransactions -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId).Count -gt 0) { throw 'task has a pending transaction; replay it before migration' }

            $timestamp=[datetimeoffset]::UtcNow.ToString('o')
            $task=[ordered]@{schema_version='task-state/v2';task_id=$TaskId;version=1;status='paused';identity='existing';intent='write';requirement_state='clear';execution_profile='governed';persistence='durable';contract_path="$($paths.TaskRoot)/contract.json";contract_digest=[string]$Contract.digest;block_reason=$null;policies=$policies;approvals=@();evidence_path=$null;created_at=$timestamp;updated_at=$timestamp}
            Assert-TaskStateDocument -RepoRoot $RepoRoot -Task $task
            $event=New-TaskEvent -EventId ('evt_'+[guid]::NewGuid().ToString('N')) -TaskId $TaskId -Version 1 -Type 'task.created' -Host $ActorHost -Model $ActorModel -Timestamp $timestamp -Payload ([ordered]@{profile='governed';contract_digest=[string]$Contract.digest
                import_note=[ordered]@{source_protocol='v1';source_stage=$SourceStage;source_plan_path=$sourceRelative;source_plan_digest=$SourcePlanDigest
                    dry_run_digest=$DryRunDigest;history_sections=@($ImportedHistorySections);imported_as='reference-only';capability_state_inferred=$false}})
            $contractText=ConvertTo-HarnessKernelJson -Value $Contract
            $taskText=ConvertTo-HarnessKernelJson -Value $task
            $eventText=(ConvertTo-HarnessKernelJson -Value $event -Compress)+"`n"

            Assert-TaskStateWorkspaceIdentityCurrent -WorkspaceRoot $WorkspaceRoot
            $parentPaths=@(@('.assistant','.assistant/runtime','.assistant/runtime/tasks')|ForEach-Object{Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $_ -Label 'migration parent' -AllowMissing})
            $createdParents=[System.Collections.Generic.List[string]]::new()
            for($index=0;$index-lt$parentPaths.Count;$index++){if(-not(Test-Path -LiteralPath $parentPaths[$index])){$createdParents.Insert(0,$parentPaths[$index])}}
            $stageRoot=$null
            try {
                [void](New-HarnessContainedDirectory -WorkspaceRoot $WorkspaceRoot -Path '.assistant/runtime/tasks' -Label 'v2 task parent')
                $stageRelative=".assistant/runtime/tasks/.migration-$TaskId-$([guid]::NewGuid().ToString('N'))"
                $stageRoot=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $stageRelative -Label 'migration staging directory' -AllowMissing
                [void][System.IO.Directory]::CreateDirectory($stageRoot)
                [void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path "$stageRelative/contract.json" -Content $contractText)
                [void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path "$stageRelative/task.json" -Content $taskText)
                [void](Write-HarnessAtomicText -WorkspaceRoot $WorkspaceRoot -Path "$stageRelative/events.jsonl" -Content $eventText)
                Assert-HarnessKernelCondition ((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path (Join-Path $stageRelative 'contract.json')) -ceq (Get-HarnessSha256Text -Content $contractText) -and
                    (Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path (Join-Path $stageRelative 'task.json')) -ceq (Get-HarnessSha256Text -Content $taskText) -and
                    (Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path (Join-Path $stageRelative 'events.jsonl')) -ceq (Get-HarnessSha256Text -Content $eventText)) 'migration staging verification failed'
                if ([System.Environment]::GetEnvironmentVariable('DEV_HARNESS_TEST_MIGRATION_FAIL_BEFORE_PUBLISH') -ceq '1') { throw 'injected migration failure before publish' }
                if ((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $sourceRelative) -cne $SourcePlanDigest) { throw 'v1 source plan changed while migration was staged' }
                [System.IO.Directory]::Move($stageRoot,$targetRoot)
                $stageRoot=$null
            } catch {
                if ($null-ne$stageRoot-and(Test-Path -LiteralPath $stageRoot -PathType Container)) {
                    $verifiedStage=Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $stageRoot -Label 'migration cleanup target' -MustExist Directory
                    if (-not [System.IO.Path]::GetFileName($verifiedStage).StartsWith(".migration-$TaskId-",[System.StringComparison]::Ordinal)) { throw 'migration cleanup target is invalid' }
                    [System.IO.Directory]::Delete($verifiedStage,$true)
                }
                foreach ($path in $createdParents) {
                    if ((Test-Path -LiteralPath $path -PathType Container) -and @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) {
                        [IO.Directory]::Delete($path,$false)
                    }
                }
                throw
            }
            return [ordered]@{operation='import-v1';source_plan_path=$sourceRelative;source_plan_digest=$SourcePlanDigest;dry_run_digest=$DryRunDigest;pointer_action='unchanged';task=$task}
        }
    } $arguments
}

Export-ModuleMember -Function Import-HarnessV1TaskState
