. (Join-Path $PSScriptRoot 'Harness.RuntimeKernel.ps1')

function Read-HarnessGovernanceText {
    param([string]$WorkspaceRoot,[string]$Path,[string]$Label)
    try { return (Read-HarnessKernelUtf8File -Path (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $Path -Label $Label -MustExist File) -Label $Label -AllowBom).Text }
    catch { throw "$Label is not valid UTF-8: $($_.Exception.Message)" }
}

function Get-HarnessGovernanceValue {
    param([string]$Text,[string]$Name,[string]$Label,[switch]$Section)
    $matches = [regex]::Matches($Text,$(if($Section){"(?ms)^## $([regex]::Escape($Name))\s*\r?\n(?<body>.*?)(?=^## |\z)"}else{"(?m)^- $([regex]::Escape($Name)):\s*(?<value>.+?)\s*$"}))
    if ($matches.Count -ne 1) { throw "$Label must contain exactly one $Name $(if($Section){'section'}else{'binding'})" }
    $value = $matches[0].Groups[$(if($Section){'body'}else{'value'})].Value.Trim()
    if ($Section -and [string]::IsNullOrWhiteSpace($value)) { throw "$Label $Name section is empty" }
    return $value
}

function New-HarnessPlanArtifact {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][string]$ContractDigest)
    $WorkspaceRoot = Resolve-HarnessWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $path = "docs/tasks/$TaskId/plan.md"
    if (Test-Path -LiteralPath (Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'governed plan' -AllowMissing)) { throw "governed plan already exists: $path" }
    $templatePath = Join-Path $RepoRoot 'templates\v2\plan.md.template'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw 'governed plan template is unavailable' }
    $content = [System.IO.File]::ReadAllText($templatePath,[System.Text.UTF8Encoding]::new($false,$true)).Replace('{{TASK_ID}}',$TaskId).Replace('{{CONTRACT_DIGEST}}',$ContractDigest)
    return [pscustomobject]@{Path=$path;Content=$content;Digest=(Get-HarnessSha256Text -Content $content)}
}

function Assert-HarnessPlanArtifact {
    param([Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,[Parameter(Mandatory)][string]$ContractDigest)
    $path = "docs/tasks/$TaskId/plan.md"
    $text = Read-HarnessGovernanceText -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'governed plan'
    foreach ($binding in ([ordered]@{task_id=$TaskId;contract_digest=$ContractDigest}).GetEnumerator()) {
        if ((Get-HarnessGovernanceValue -Text $text -Name $binding.Key -Label 'governed plan') -cne $binding.Value) { throw "governed plan $($binding.Key) is stale" }
    }
    if ($text -cmatch '<fill-[a-z0-9-]+>') { throw 'governed plan still contains fill placeholders' }
    foreach ($section in @('Goal','Scope','Implementation','Verification','Rollback')) { [void](Get-HarnessGovernanceValue -Text $text -Name $section -Label 'governed plan' -Section) }
    return [pscustomobject]@{Path=$path;Digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path)}
}

function Resolve-HarnessAuditArtifact {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][int]$TaskVersion,[Parameter(Mandatory)][string]$ContractDigest,[Parameter(Mandatory)][object]$Evidence,
        [ValidateSet('isolated-context','different-actor')][string]$RequiredIndependence='isolated-context'
    )
    $path = "docs/tasks/$TaskId/audit.md"
    $text = Read-HarnessGovernanceText -WorkspaceRoot $WorkspaceRoot -Path $path -Label 'independent audit'
    foreach ($binding in ([ordered]@{task_id=$TaskId;task_version=[string]$TaskVersion;contract_digest=$ContractDigest}).GetEnumerator()) {
        if ((Get-HarnessGovernanceValue -Text $text -Name $binding.Key -Label 'independent audit') -cne $binding.Value) { throw "independent audit $($binding.Key) is stale" }
    }
    if ((Get-HarnessGovernanceValue -Text $text -Name 'verdict' -Label 'independent audit') -cne 'pass') { throw 'independent audit verdict must be pass' }
    if ((Get-HarnessGovernanceValue -Text $text -Name 'reviewer_participated' -Label 'independent audit') -cne 'false') { throw 'independent reviewer participated in implementation' }

    $recordMatches = [regex]::Matches($text,'(?ms)^<!-- harness-audit-record:start -->\s*\r?\n(?<json>.*?)\r?\n<!-- harness-audit-record:end -->\s*$')
    if ($recordMatches.Count -ne 1) { throw 'independent audit must contain exactly one machine record' }
    try { $record = $recordMatches[0].Groups['json'].Value | ConvertFrom-HarnessJson -ErrorAction Stop }
    catch { throw "independent audit record is not valid JSON: $($_.Exception.Message)" }
    Assert-HarnessKernelTextFields -Value $record -Fields @('implementer_actor_id','reviewer_actor_id','reviewer_context_id','reviewer_base_model') -Label 'independent audit record'
    Assert-HarnessKernelSchema -RepoRoot $RepoRoot -Value $record -Schema 'audit-record.schema.json' -Label 'independent audit record' -Depth 20
    if ([string]$record.evidence_digest -cne [string]$Evidence.Digest) { throw 'independent audit evidence_digest is stale' }
    if ($RequiredIndependence -ceq 'different-actor' -and [string]$record.independence_level -cne 'different-actor') { throw 'Critical task requires a different-actor audit' }

    $evidenceRecords = @($Evidence.Document.records)
    foreach ($evidenceRecord in $evidenceRecords) {
        try { Assert-HarnessKernelTextFields -Value $evidenceRecord.actor -Fields @('actor_id','context_id') -Label 'evidence actor' }
        catch { throw 'independent audit requires actor_id and context_id on every Evidence record' }
    }
    $actors,$contexts = @($evidenceRecords.actor.actor_id | Sort-Object -CaseSensitive -Unique),@($evidenceRecords.actor.context_id | Sort-Object -CaseSensitive -Unique)
    if ($actors.Count -ne 1 -or $contexts.Count -ne 1) { throw 'independent audit requires one implementer actor and context in Evidence' }
    $implementerActor,$implementerContext = @($actors)[0],@($contexts)[0]
    if ($RequiredIndependence -ceq 'different-actor' -and $Evidence.Document.Contains('dry_run')) {
        if ([string]$Evidence.Document.dry_run.actor.actor_id -ceq $implementerActor) { throw 'Critical dry-run executor actor must differ from the implementer actor' }
        if ([string]$Evidence.Document.dry_run.actor.context_id -ceq $implementerContext) { throw 'Critical dry-run executor context must differ from the implementer context' }
    }
    if ([string]$record.implementer_actor_id -cne $implementerActor) { throw 'independent audit implementer_actor_id does not match Evidence' }
    if ([string]$record.reviewer_context_id -ceq $implementerContext) { throw 'independent reviewer context must differ from implementer context' }
    if ([string]$record.independence_level -ceq 'different-actor' -and [string]$record.reviewer_actor_id -ceq $implementerActor) { throw 'different-actor audit requires a different reviewer actor' }

    $findings = Get-HarnessGovernanceValue -Text $text -Name 'Findings' -Label 'independent audit' -Section
    if ($findings -cne '- none') {
        foreach ($line in @($findings -split "\r?\n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $finding = [regex]::Match($line,'^- (?<severity>P[0-3]):\s*.+?\s*\|\s*evidence_path=(?<path>[^|]+?)\s*\|\s*evidence_digest=(?<digest>sha256:[0-9a-f]{64})\s*$')
            if (-not $finding.Success) { throw 'independent audit finding must contain structured file evidence' }
            if ($finding.Groups['severity'].Value -cin @('P0','P1')) { throw 'independent audit pass cannot contain a blocking finding' }
            $evidencePath = $finding.Groups['path'].Value.Trim()
            [void](Resolve-HarnessContainedPath -WorkspaceRoot $WorkspaceRoot -Path $evidencePath -Label 'audit finding evidence' -MustExist File)
            if ((Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $evidencePath) -cne $finding.Groups['digest'].Value) { throw 'independent audit finding evidence digest mismatch' }
        }
    }
    [void](Get-HarnessGovernanceValue -Text $text -Name 'Evidence' -Label 'independent audit' -Section)
    return [pscustomobject]@{Path=$path;Digest=(Get-HarnessFileDigest -WorkspaceRoot $WorkspaceRoot -Path $path);Record=$record}
}

function Assert-HarnessGovernanceReady {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$WorkspaceRoot,[Parameter(Mandatory)][System.Collections.IDictionary]$Task,[Parameter(Mandatory)][object]$Evidence)
    $plan,$audit,$protectedOperation = $null,$null,$null
    if ($(if ($Task.policies.Contains('dry_run_required')) { [bool]$Task.policies.dry_run_required } else { [string]$Task.execution_profile -ceq 'critical' }) -and [string]$Evidence.NextStatus -ceq 'done') {
        if (-not $Evidence.Document.Contains('dry_run') -or [int]$Evidence.Document.dry_run.exit_code -ne 0) { throw 'dry-run Evidence is required before Critical task completion' }
        Assert-HarnessKernelTextFields -Value $Evidence.Document.dry_run -Fields command -Label 'dry-run'
        if($null-eq$Evidence.ProtectedOperation){throw 'protected_operation is required before Critical task completion'}
        $protectedOperation=$Evidence.ProtectedOperation
        $identity,$dryRun=[string]$protectedOperation.identity,$Evidence.Document.dry_run
        if([string]$protectedOperation.approval_type-ceq'none'){throw 'Critical protected_operation requires an Approval type'}
        if(-not$dryRun.Contains('operation_identity')-or[string]$dryRun.operation_identity-cne$identity){throw 'Critical dry-run is not bound to protected_operation'}
        if(@($dryRun.covers).Count-eq0-or@($dryRun.covers)-cnotcontains$identity){throw 'Critical dry-run covers must include protected_operation identity'}
        if(-not@($Evidence.Document.records|Where-Object{(Test-HarnessKernelFields $_ @{type='command';exit_code=0;operation_identity=$identity})-and@($_.covers)-ccontains$identity}).Count){throw 'Critical completion requires successful execution Evidence bound to protected_operation'}
    }
    if ([bool]$Task.policies.plan_required) { $plan = Assert-HarnessPlanArtifact -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Task.task_id) -ContractDigest ([string]$Task.contract_digest) }
    if ([bool]$Task.policies.independent_review_required) {
        $audit = Resolve-HarnessAuditArtifact -RepoRoot $RepoRoot -WorkspaceRoot $WorkspaceRoot -TaskId ([string]$Task.task_id) -TaskVersion ([int]$Task.version) `
            -ContractDigest ([string]$Task.contract_digest) -Evidence $Evidence -RequiredIndependence $(if([string]$Task.execution_profile-ceq'critical'){'different-actor'}else{'isolated-context'})
    }
    return [pscustomobject]@{Plan=$plan;Audit=$audit;ProtectedOperation=$protectedOperation}
}

Export-ModuleMember -Function New-HarnessPlanArtifact,Assert-HarnessPlanArtifact,Resolve-HarnessAuditArtifact,Assert-HarnessGovernanceReady
