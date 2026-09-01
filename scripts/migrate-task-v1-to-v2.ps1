[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TaskId,
    [Parameter(Mandatory)][ValidateSet('PLAN','PLAN_REVIEW','IMPLEMENT','CODE_REVIEW','TEST')][string]$ExpectedV1Stage,
    [switch]$DryRun,
    [string]$ExpectedDryRunDigest = '',
    [switch]$ConfirmMigration,
    [string]$RepoRoot = '',
    [string]$WorkspaceRoot = '',
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-V1PlanValidation {
    param([string]$ValidatorPath,[string]$RepoRoot,[string]$WorkspaceRoot,[string]$TaskId)
    $shell = (Get-Process -Id $PID).Path
    $output = @(& $shell -NoProfile -NonInteractive -File $ValidatorPath -TaskId $TaskId -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "v1 plan validation failed: $($output -join ' | ')" }
}

function Get-V1CurrentTaskId {
    param([string]$WorkspaceRoot)
    $path = Join-Path $WorkspaceRoot '.assistant\运行时\当前任务.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $text = [System.IO.File]::ReadAllText($path,[System.Text.UTF8Encoding]::new($false,$true))
    $match = [regex]::Match($text,'(?m)^task_id:\s*([^\s#]+)\s*$')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim('`','"',"'")
}

function Get-V1HistoryReferences {
    param([string]$WorkspaceRoot,[string]$TaskId,[object[]]$Sections)
    $references = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        [pscustomobject]@{Stage='PLAN_REVIEW';Section='Plan Review'},
        [pscustomobject]@{Stage='IMPLEMENT';Section='Implementation Notes'},
        [pscustomobject]@{Stage='CODE_REVIEW';Section='Code Review'}
    )) {
        $section = @($Sections | Where-Object { $_.Name -ceq $entry.Section } | Select-Object -First 1)
        if ($section.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$section[0].VisibleContent)) {
            $references.Add(("{0}:docs/tasks/{1}/plan.md#{2}" -f $entry.Stage,$TaskId,$entry.Section))
        }
    }
    $testRelative = "docs/tasks/$TaskId/test.md"
    $testPath = Join-Path $WorkspaceRoot ($testRelative.Replace('/','\'))
    if (Test-Path -LiteralPath $testPath -PathType Leaf) {
        $references.Add(("TEST:{0}:{1}" -f $testRelative,(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $testRelative)))
    }
    return @($references)
}

function New-MigrationContract {
    param([string]$TaskId,[string]$Title,[string]$PlanPath,[string]$PlanDigest,[string]$Stage)
    $body = [ordered]@{
        schema_version='requirement-contract/v1'
        task_id=$TaskId
        goal=("Continue the user-confirmed v1 task '{0}' under v2 without rewriting v1 history." -f $Title)
        acceptance=@(
            "Satisfy the acceptance and verification recorded in $PlanPath.",
            "Preserve the source v1 plan at digest $PlanDigest."
        )
        in_scope=@("The user-confirmed scope recorded in $PlanPath.")
        out_of_scope=@('Rewriting or deleting the source v1 task history.')
        product_constraints=@(
            'The source v1 plan remains the immutable migration reference.',
            'Migration does not infer v2 capability completion from v1 stage history.'
        )
        product_decisions=@(
            [ordered]@{key='source_v1_stage';value=$Stage;source='user-confirmed explicit migration'},
            [ordered]@{key='source_v1_plan_digest';value=$PlanDigest;source='repository evidence'}
        )
        unresolved_product_decisions=@()
        source_authority=@('user-confirmed','project-policy','repo-evidence')
    }
    $contract=[ordered]@{}
    foreach($key in $body.Keys){$contract[$key]=$body[$key]}
    $contract.digest=Get-HarnessSha256Text -Content ($body|ConvertTo-Json -Depth 30 -Compress)
    return $contract
}

function Get-MigrationMaterial {
    param([string]$RepoRoot,[string]$WorkspaceRoot,[string]$TaskId,[string]$ExpectedStage)
    $resolution=Get-HarnessLegacyMigrationSource -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    if ([string]$resolution.detected_protocol -cne 'v1') { throw "migration requires an existing v1 task; detected=$($resolution.detected_protocol)" }
    if ([string]$resolution.v1_stage -cne $ExpectedStage) { throw "ExpectedV1Stage mismatch: expected=$ExpectedStage actual=$($resolution.v1_stage)" }
    if ((Get-V1CurrentTaskId -WorkspaceRoot $WorkspaceRoot) -ceq $TaskId) { throw 'active v1 task cannot be migrated; pause or switch away first' }
    Invoke-V1PlanValidation -ValidatorPath (Join-Path $RepoRoot 'scripts\validate-lite-artifacts.ps1') -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId
    $planPath=[string]$resolution.v1_plan_path
    $planTarget=Join-Path $WorkspaceRoot ($planPath.Replace('/','\'))
    $planText=[System.IO.File]::ReadAllText($planTarget,[System.Text.UTF8Encoding]::new($false,$true))
    $frontmatter=Get-LiteFrontmatter -Content $planText
    $sections=@(Get-LiteSections -Content $frontmatter.Body)
    if ((Get-LiteUserConfirmationStatus -Sections $sections) -cne 'confirmed') { throw 'v1 migration requires User Confirmation status: confirmed' }
    $titleMatch=[regex]::Match($frontmatter.Body,'(?m)^#\s+(.+?)\s*$')
    $title=if($titleMatch.Success){$titleMatch.Groups[1].Value.Trim()}else{$TaskId}
    $history=@(Get-V1HistoryReferences -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -Sections $sections)
    $contract=New-MigrationContract -TaskId $TaskId -Title $title -PlanPath $planPath -PlanDigest ([string]$resolution.v1_plan_digest) -Stage $ExpectedStage
    $reportBody=[ordered]@{
        schema_version='v1-migration-dry-run/v1'
        task_id=$TaskId
        source_protocol='v1'
        source_stage=$ExpectedStage
        source_plan_path=$planPath
        source_plan_digest=[string]$resolution.v1_plan_digest
        source_confirmation='confirmed'
        target_protocol='v2'
        target_status='paused'
        target_contract_digest=[string]$contract.digest
        imported_history=@($history)
        source_preservation='immutable-reference'
    }
    $report=[ordered]@{}
    foreach($key in $reportBody.Keys){$report[$key]=$reportBody[$key]}
    $report.dry_run_digest=Get-HarnessSha256Text -Content ($reportBody|ConvertTo-Json -Depth 30 -Compress)
    return [pscustomobject]@{Resolution=$resolution;Contract=$contract;Report=$report;History=$history}
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot=Split-Path -Parent $PSScriptRoot }
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot=$RepoRoot }
    $WorkspaceRoot=(Resolve-Path -LiteralPath $WorkspaceRoot).Path
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.Path.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $RepoRoot 'modules\legacy-v1\Harness.LegacyMigration.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.AtomicWrite.psm1') -Force -ErrorAction Stop
    . (Join-Path $RepoRoot 'scripts\lite-artifact-parser.ps1')
    if ($TaskId -cnotmatch '^(?!(?:none|idle|unknown)$)[a-z0-9][a-z0-9-]{0,63}$') { throw "invalid task id: $TaskId" }

    $material=Get-MigrationMaterial -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ExpectedStage $ExpectedV1Stage
    if ($DryRun) {
        $result=[ordered]@{operation='migration-dry-run';report=$material.Report;side_effects=[ordered]@{v1_writes=0;v2_writes=0}}
    } else {
        if (-not $ConfirmMigration) { throw 'formal migration requires -ConfirmMigration' }
        if ($ExpectedDryRunDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'formal migration requires -ExpectedDryRunDigest from a successful dry-run' }
        if ($ExpectedDryRunDigest -cne [string]$material.Report.dry_run_digest) { throw 'dry-run digest mismatch; rerun -DryRun and review the new report' }
        $mutex=[System.Threading.Mutex]::new($false,("Global\dev-harness.plan-md.{0}" -f $TaskId))
        $acquired=$false
        try {
            try{$acquired=$mutex.WaitOne(10000)}catch [System.Threading.AbandonedMutexException]{$acquired=$true}
            if(-not$acquired){throw "timed out waiting for v1 task lock: $TaskId"}
            $lockedMaterial=Get-MigrationMaterial -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId $TaskId -ExpectedStage $ExpectedV1Stage
            if ([string]$lockedMaterial.Report.dry_run_digest -cne $ExpectedDryRunDigest) { throw 'v1 task changed after dry-run; rerun -DryRun' }
            $taskStateModule=Import-Module (Join-Path $RepoRoot 'scripts\lib\Harness.TaskState.psm1') -Force -PassThru -ErrorAction Stop
            $oldProtocol=$env:HARNESS_PROTOCOL
            try {
                $env:HARNESS_PROTOCOL='v2'
                $importArguments=@{
                    RepoRoot=$RepoRoot
                    WorkspaceRoot=$WorkspaceRoot
                    TaskId=$TaskId
                    Contract=$lockedMaterial.Contract
                    SourcePlanPath=[string]$lockedMaterial.Resolution.v1_plan_path
                    SourcePlanDigest=[string]$lockedMaterial.Resolution.v1_plan_digest
                    SourceStage=$ExpectedV1Stage
                    DryRunDigest=$ExpectedDryRunDigest
                    ImportedHistorySections=@($lockedMaterial.History)
                }
                $result=& $taskStateModule { param($Arguments) Import-HarnessV1TaskState @Arguments } $importArguments
            } finally {
                if($null-eq$oldProtocol){Remove-Item Env:HARNESS_PROTOCOL -ErrorAction Ignore}else{$env:HARNESS_PROTOCOL=$oldProtocol}
            }
        } finally {
            if($null-ne$mutex){if($acquired){[void]$mutex.ReleaseMutex()};$mutex.Dispose()}
        }
    }

    if($AsJson){$result|ConvertTo-Json -Depth 30 -Compress}
    elseif($DryRun){
        "operation: $($result.operation)"
        "task_id: $TaskId"
        "source_stage: $ExpectedV1Stage"
        "source_plan_digest: $($result.report.source_plan_digest)"
        "target_contract_digest: $($result.report.target_contract_digest)"
        "dry_run_digest: $($result.report.dry_run_digest)"
        'writes: 0'
    }else{
        "operation: $($result.operation)"
        "task_id: $($result.task.task_id)"
        "status: $($result.task.status)"
        "dry_run_digest: $($result.dry_run_digest)"
        'v1_plan_action: preserved'
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
